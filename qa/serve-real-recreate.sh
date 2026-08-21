#!/bin/bash
# RECREATE <kind> - DROP the object if it exists (of the CREATE's kind), then
# CREATE. The CREATE is planned at prepare, so a bad definition refuses before
# anything is dropped (as the engine does). Probed: RECREATE TABLE / EXCEPTION
# / VIEW / PROCEDURE / FUNCTION / SEQUENCE replace an existing object and its
# rows/message/body, and RECREATE of a name that does not yet exist is a plain
# CREATE. Both databases engine-built; isql on both servers, the catalog and
# results compared; the ENGINE reads fc's file and gfix validates it.
# Boundaries (recorded): a view whose SELECT this server cannot compile refuses
# generically where the engine says "RECREATE VIEW failed / -206"; and this
# server's DROP TABLE does not enforce dependencies, so RECREATE TABLE over a
# table a view depends on succeeds where the engine refuses (pre-existing, not
# RECREATE-specific) - the gate recreates only standalone tables.
#
#   qa/serve-real-recreate.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4890}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-recreate-crab.fdb"
B="$D/fc-recreate-engine.fdb"
LOG="/tmp/fc-serve-recreate-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"
fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(5));
CREATE TABLE STANDALONE (X INTEGER, Y INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 'a');
INSERT INTO T VALUES (2, 'b');
INSERT INTO STANDALONE VALUES (7, 8);
COMMIT;
CREATE EXCEPTION EX 'old message';
CREATE SEQUENCE SQ;
SET TERM ^;
CREATE PROCEDURE PR RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; END^
CREATE FUNCTION FN (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A; END^
SET TERM ;^
CREATE VIEW VW AS SELECT ID FROM T;
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
RECREATE TABLE STANDALONE (P INTEGER, Q BIGINT, R DATE);
RECREATE TABLE NEWT (A INTEGER, B VARCHAR(3));
COMMIT;
SELECT RDB$RELATION_NAME, RDB$FIELD_NAME, RDB$FIELD_POSITION FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME IN ('STANDALONE', 'NEWT') ORDER BY 1, 3;
SELECT COUNT(*) AS SROWS FROM STANDALONE;
RECREATE EXCEPTION EX 'new message';
RECREATE EXCEPTION EX2 'brand new';
COMMIT;
SELECT RDB$EXCEPTION_NAME, RDB$MESSAGE FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME IN ('EX', 'EX2') ORDER BY 1;
RECREATE VIEW VW AS SELECT ID, V FROM T;
COMMIT;
SELECT RDB$FIELD_NAME, RDB$FIELD_POSITION FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'VW' ORDER BY 2;
SET LIST OFF;
SELECT ID, V FROM VW ORDER BY ID;
SET TERM ^;
RECREATE PROCEDURE PR RETURNS (Y INTEGER) AS BEGIN Y = 99; SUSPEND; END^
RECREATE FUNCTION FN (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 3; END^
SET TERM ;^
COMMIT;
SELECT Y FROM PR;
SELECT FN(4) FROM RDB$DATABASE;
RECREATE SEQUENCE SQ;
COMMIT;
SET LIST ON;
SELECT RDB$GENERATOR_NAME FROM RDB$GENERATORS WHERE RDB$GENERATOR_NAME = 'SQ';
SQL
}
e=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "RECREATE across TABLE / EXCEPTION / VIEW / PROCEDURE / FUNCTION / SEQUENCE" "$c" "$e"
# RECREATE of a name that does not exist is a plain CREATE - the vectors agree
e=$("$D/sqlerr" "127.0.0.1/$REAL:$B" "RECREATE TABLE FRESH (A INTEGER)" "RECREATE EXCEPTION FRESHX 'hi'" "RECREATE SEQUENCE FRESHSQ" 2>&1 | norm)
c=$("$D/sqlerr" "127.0.0.1/$PORT:$A" "RECREATE TABLE FRESH (A INTEGER)" "RECREATE EXCEPTION FRESHX 'hi'" "RECREATE SEQUENCE FRESHSQ" 2>&1 | norm)
check "RECREATE of a new name is a plain CREATE (vectors)" "$c" "$e"
# Boundary: a view SELECT this server cannot compile refuses generically
eb=$("$D/sqlerr" "127.0.0.1/$REAL:$B" "RECREATE VIEW VW AS SELECT NOPE FROM T" 2>&1 | norm)
cb=$("$D/sqlerr" "127.0.0.1/$PORT:$A" "RECREATE VIEW VW AS SELECT NOPE FROM T" 2>&1 | norm)
ran=$((ran + 1))
if [ "$eb" != "$cb" ] && [ "${eb#*336397301}" != "$eb" ] && [ "${cb#*335544569}" != "$cb" ]; then
    echo "OK   boundary: an uncompilable view SELECT refuses generically (engine RECREATE VIEW failed / -206)"
else
    echo "DIFF boundary MOVED: RECREATE VIEW uncompilable"; echo "     engine: $eb"; echo "     fc:     $cb"; fail=1
fi
# gfix validates fc's file, and the ENGINE reads what fc recreated
gf=$(gfix -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's recreated file"; else echo "DIFF gfix: $gf"; fail=1; fi
script2() { cat <<'SQL'
SET LIST ON;
SELECT RDB$RELATION_NAME, RDB$FIELD_NAME FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME IN ('STANDALONE', 'NEWT', 'VW') ORDER BY 1, RDB$FIELD_POSITION;
SELECT RDB$EXCEPTION_NAME, RDB$MESSAGE FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME IN ('EX', 'EX2') ORDER BY 1;
SET LIST OFF;
SELECT ID, V FROM VW ORDER BY ID;
SELECT Y FROM PR;
SELECT FN(4) FROM RDB$DATABASE;
SQL
}
e=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's recreated catalog and runs its procedure/function" "$c" "$e"
echo "ran $ran checks"
exit $fail
