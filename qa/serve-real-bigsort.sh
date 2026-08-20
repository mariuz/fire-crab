#!/bin/bash
# THE EXTERNAL SORT (sort.cpp's shape: runs written when a memory budget
# is spent, merged at the end). fire-crab's ORDER BY, GROUP BY and
# DISTINCT used to hold every row in RAM - DISTINCT quadratically. Now a
# set over FC_SORT_MEMORY goes through `crate::extsort`: the buffer
# sorted (stably, by the same comparator as before) and written as a run
# under FC_TEMP_DIR (unlinked on creation, like TempFile), the runs
# merged with ties broken by run then position - so the order is the
# comparator's, ties in RECORD order, identical spilled or not.
#
# The engine's tie order past one 128 KB run is a merge artefact
# (measured: 780-row chunks per tie group at 200k rows) that its own
# gates never pin; this one compares on TOTAL keys, and checks fc's
# tie rule against itself small vs large.
#
# 300,000 rows built on the engine (an EXECUTE BLOCK loop), the file
# copied for fire-crab; the server runs with a 2 MB budget so every
# query spills; results compared by digest, coverage by the trace and
# by the temp directory being empty afterwards.
#
#   qa/serve-real-bigsort.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4841}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-bigsort-engine.fdb"; DBF="$D/fc-bigsort-crab.fdb"
LOG="/tmp/fc-serve-bigsort-$PORT.log"
TMP="$D/fc-bigsort-tmp"
fail=0; ran=0
mkdir -p "$D" "$TMP"; rm -f "$TMP"/fc_sort_* "$DBE" "$DBF"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DBE' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE BS (ID INTEGER, K INTEGER, S VARCHAR(40), N INTEGER);
COMMIT;
EOF
"$GFIX" -write async -user "$U" -pas "$P" "$DBE" 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$DBE" <<'EOF' >/dev/null 2>&1 || { echo "FAIL fill"; exit 1; }
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 300000) DO BEGIN
    INSERT INTO BS VALUES (:I, MOD(:I * 7919, 1000), LPAD('', 30, UUID_TO_CHAR(GEN_UUID())), IIF(MOD(:I, 97) = 0, NULL, MOD(:I, 13)));
    I = I + 1;
  END
END^
SET TERM ;^
COMMIT;
EOF
chmod 666 "$DBE"; cp "$DBE" "$DBF"; chmod 666 "$DBF"
FC_SRV_TRACE=1 FC_SORT_MEMORY=2000000 FC_TEMP_DIR="$TMP" "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -rf "$DBE" "$DBF" "$TMP"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
q() { printf 'SET HEADING OFF;\n%s\n' "$2" | timeout 600 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g' | grep -v '^$'; }
digest() { q "$1" "$2" | md5sum | cut -c1-16; }
both() { local e c; e=$(digest "127.0.0.1/$REAL:$DBE" "$2"); c=$(digest "127.0.0.1/$PORT:$DBF" "$2"); ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"; else echo "DIFF $1: engine $e fc $c"; fail=1; fi; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

both "ORDER BY a total key, 300k rows in order" "SELECT ID, K FROM BS ORDER BY K, ID;"
both "...descending" "SELECT ID, K FROM BS ORDER BY K DESC, ID DESC;"
both "...a text key" "SELECT S, ID FROM BS ORDER BY S, ID;"
both "...NULLS FIRST (the ascending default) and NULLS LAST" "SELECT N, ID FROM BS ORDER BY N, ID; SELECT N, ID FROM BS ORDER BY N DESC NULLS LAST, ID;"
both "GROUP BY over the set" "SELECT K, COUNT(*), SUM(ID), MIN(S) FROM BS GROUP BY K ORDER BY K;"
both "...by two keys with NULLs" "SELECT N, K, COUNT(*) FROM BS GROUP BY N, K ORDER BY N, K;"
both "DISTINCT over the set" "SELECT DISTINCT K FROM BS ORDER BY K; SELECT DISTINCT N FROM BS ORDER BY N; SELECT COUNT(*) FROM (SELECT DISTINCT K, N FROM BS) X;"
both "aggregates" "SELECT COUNT(*), COUNT(DISTINCT K), MIN(ID), MAX(ID), SUM(ID) FROM BS;"
both "FIRST and SKIP after the sort" "SELECT FIRST 20 ID, K FROM BS ORDER BY K, ID; SELECT FIRST 20 SKIP 299980 ID, K FROM BS ORDER BY K, ID;"
# ties: fc's rule is RECORD order, and the same small and large
small=$(q "127.0.0.1/$PORT:$DBF" "SELECT FIRST 5 ID FROM BS WHERE ID < 3000 AND K = 0 ORDER BY K;" | tr '\n' ' ')
large=$(q "127.0.0.1/$PORT:$DBF" "SELECT FIRST 5 ID FROM BS WHERE K = 0 ORDER BY K;" | tr '\n' ' ')
check "fc's tie order is record order, spilled or not" "$small|$large" "0 1000 2000 |0 1000 2000 3000 4000 "
ran=$((ran + 1)); spilled=$(grep -cE 'sort( cursor)?: rows=300000 runs=[2-9][0-9]*' "$LOG")
if [ "$spilled" -ge 6 ]; then echo "OK   coverage: $spilled sorts spilled to runs (2 MB budget)"; else echo "DIFF coverage: [$spilled] spilled sorts"; fail=1; fi
ran=$((ran + 1)); left=$(ls "$TMP" 2>/dev/null | wc -l)
if [ "$left" = "0" ]; then echo "OK   coverage: no run file survives in $TMP"; else echo "DIFF coverage: $left run files left"; fail=1; fi
echo "ran $ran checks"
exit $fail
