#!/bin/bash
# The row-locking / optimizer clauses a SELECT may carry - `FOR UPDATE
# [OF ...]`, `WITH LOCK [SKIP LOCKED]`, `OPTIMIZE FOR ...`. This
# single-snapshot server does not act on them (it holds one read view
# and picks its own plan), but their ROWS are the plain query's, so it
# strips them and answers. FOR UPDATE and OPTIMIZE are lenient (the
# engine takes them over a view, CTE, join or aggregate too); WITH LOCK
# is valid ONLY over a single physical table with no aggregate - the
# engine's -104 otherwise - so fc refuses it in every other shape rather
# than answer a row the engine never returns.
#
# Both servers run the same statements; the rows are compared, and the
# WITH-LOCK refusals are checked to fire on both.
#
#   qa/serve-real-rowlock.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4893}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-rowlock-crab.fdb"; B="$D/fc-rowlock-engine.fdb"
LOG="/tmp/fc-serve-rowlock-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

for db in "127.0.0.1/$REAL:$B" "127.0.0.1/$PORT:$A"; do
    "$ISQL" -q -user "$U" -pas "$P" "$db" <<'EOF' >/dev/null 2>&1
CREATE TABLE T (ID INTEGER, V INTEGER);
INSERT INTO T VALUES (1, 10); INSERT INTO T VALUES (2, 20); INSERT INTO T VALUES (3, 30);
CREATE VIEW VW AS SELECT ID, V FROM T;
COMMIT;
EOF
done
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/rl.sql" 2>&1 | norm; }

cat > "$D/rl.sql" <<'SQL'
SET LIST ON;
SELECT ID FROM T WHERE ID = 1 WITH LOCK;
SELECT ID FROM T ORDER BY ID FOR UPDATE;
SELECT ID FROM T ORDER BY ID FOR UPDATE WITH LOCK;
SELECT ID FROM T ORDER BY ID FOR UPDATE OF V;
SELECT ID FROM T ORDER BY ID ROWS 2 FOR UPDATE WITH LOCK;
SELECT ID FROM T WHERE ID = 1 WITH LOCK SKIP LOCKED;
SELECT ID FROM T ORDER BY ID OPTIMIZE FOR FIRST ROWS;
SELECT ID FROM T ORDER BY ID WITH LOCK;
SELECT ID FROM VW ORDER BY ID FOR UPDATE;
WITH C AS (SELECT ID FROM T) SELECT ID FROM C ORDER BY ID FOR UPDATE;
SELECT COUNT(*) AS C FROM T OPTIMIZE FOR FIRST ROWS;
SQL
check "FOR UPDATE / WITH LOCK / OPTIMIZE - the rows are the plain query's" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# WITH LOCK where the engine refuses (-104): fc must refuse too, not answer
for q in "SELECT COUNT(*) FROM T WITH LOCK" \
         "WITH C AS (SELECT ID FROM T) SELECT ID FROM C WITH LOCK" \
         "SELECT ID FROM VW WITH LOCK"; do
    printf 'SET LIST ON;\n%s;\n' "$q" > "$D/rl.sql"
    e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/rl.sql" 2>&1 | grep -ci error)
    c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/rl.sql" 2>&1 | grep -ci error)
    ran=$((ran + 1))
    if [ "$e" != "0" ] && [ "$c" != "0" ]; then echo "OK   WITH LOCK refused on both: ${q:0:40}"
    else echo "DIFF WITH LOCK (eng-errs=$e fc-errs=$c): $q"; fail=1; fi
done

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
