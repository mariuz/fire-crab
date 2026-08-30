#!/bin/bash
# ALTER VIEW <name> AS <select> - the view's definition is replaced but its
# RELATION ID survives (probed 129 -> 129), the fields and auto-domains fresh.
# Probed: the relation id and dbkey length are unchanged, the field list and
# the rows follow the new SELECT, and a widened then narrowed view round-trips.
# A missing view is "unsuccessful metadata update / ALTER VIEW @1 failed /
# view @1 not found". Both databases engine-built; isql on both servers, the
# catalog and rows compared; the ENGINE reads fc's altered view and gfix
# validates the file.
# Boundaries (recorded): a SELECT this server cannot compile refuses
# generically (as CREATE VIEW does); ALTER VIEW of a TABLE answers view-not-found on fc
# where the engine compiles the new definition against the table and fails
# -206 (both are ALTER VIEW failed).
#
#   qa/serve-real-alterview.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4891}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-alterview-crab.fdb"
B="$D/fc-alterview-engine.fdb"
LOG="/tmp/fc-serve-alterview-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"
fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr-$(basename "$0" .sh)" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(5), B INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 'a', 10);
INSERT INTO T VALUES (2, 'b', 20);
COMMIT;
CREATE VIEW VW AS SELECT ID, V FROM T;
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | grep -v 'BLOB display' | tr '\n' '|'; }
script() { cat <<'SQL'
SET LIST ON;
SELECT RDB$RELATION_ID AS RID, RDB$DBKEY_LENGTH AS DBK FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'VW';
ALTER VIEW VW AS SELECT ID, V, B FROM T;
COMMIT;
SELECT RDB$RELATION_ID AS RID2, RDB$DBKEY_LENGTH AS DBK2 FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'VW';
SELECT RDB$FIELD_NAME, RDB$FIELD_POSITION, RDB$FIELD_SOURCE, RDB$BASE_FIELD FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'VW' ORDER BY 2;
SET LIST OFF;
SELECT ID, V, B FROM VW ORDER BY ID;
ALTER VIEW VW AS SELECT ID AS ONLY_ID FROM T;
COMMIT;
SET LIST ON;
SELECT RDB$RELATION_ID AS RID3 FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'VW';
SELECT RDB$FIELD_NAME FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'VW' ORDER BY RDB$FIELD_POSITION;
SET LIST OFF;
SELECT ONLY_ID FROM VW ORDER BY ONLY_ID;
SQL
}
e=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "ALTER VIEW replaces the definition, the relation id survives" "$c" "$e"
e=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$REAL:$B" "ALTER VIEW NOPE AS SELECT ID FROM T" 2>&1 | norm)
c=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "ALTER VIEW NOPE AS SELECT ID FROM T" 2>&1 | norm)
check "ALTER VIEW of a missing view: ALTER VIEW failed / view not found" "$c" "$e"
# Boundary: ALTER VIEW of a TABLE - engine compiles the definition and fails
# -206, fc refuses generically
eb=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$REAL:$B" "ALTER VIEW T AS SELECT ID FROM T" 2>&1 | norm)
cb=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "ALTER VIEW T AS SELECT ID FROM T" 2>&1 | norm)
ran=$((ran + 1))
if [ "$eb" != "$cb" ] && [ "${eb#*-206}" != "$eb" ] && [ "${cb#*336068662}" != "$cb" ]; then
    echo "OK   boundary: ALTER VIEW of a table - fc answers view-not-found where the engine compiles and fails -206"
else
    echo "DIFF boundary MOVED: ALTER VIEW of a table"; echo "     engine: $eb"; echo "     fc:     $cb"; fail=1
fi
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's altered file"; else echo "DIFF gfix: $gf"; fail=1; fi
# the ENGINE reads fc's final view (ONLY_ID) and its one column
script2() { cat <<'SQL'
SET LIST ON;
SELECT RDB$RELATION_ID, RDB$RELATION_TYPE FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'VW';
SELECT RDB$FIELD_NAME FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'VW' ORDER BY RDB$FIELD_POSITION;
SET LIST OFF;
SELECT ONLY_ID FROM VW ORDER BY ONLY_ID;
SQL
}
e=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's altered view" "$c" "$e"
echo "ran $ran checks"
exit $fail
