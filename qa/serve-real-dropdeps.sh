#!/bin/bash
# DROP TABLE dependency enforcement - a VIEW that reads a table blocks its
# DROP, as the engine's deferred dependency scan does. Probed: "unsuccessful
# metadata update / cannot delete / TABLE @1 / there are N dependencies" where
# N is the DISTINCT dependent views (the engine counts views whenever any
# exist, recompiling procedures instead); dropping the views first frees the
# table; a standalone table drops. Both databases engine-built; isql on both
# servers, which auto-commits each statement so the engine's refusal (it
# defers to COMMIT) and fire-crab's (at execute) read identically. gfix
# validates fire-crab's file.
# Boundaries (recorded): a table whose ONLY dependents are procedures, or a
# PRIMARY KEY referenced by a FOREIGN KEY, is refused by the engine but
# dropped by fire-crab (its dependency model is view-based; procedure
# recompilation and FK/PK back-references are a later slice).
#
#   qa/serve-real-dropdeps.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4894}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-dropdeps-crab.fdb"
B="$D/fc-dropdeps-engine.fdb"
LOG="/tmp/fc-serve-dropdeps-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(5), W INTEGER);
CREATE TABLE STAND (X INTEGER);
CREATE TABLE PAR (ID INTEGER NOT NULL PRIMARY KEY);
CREATE TABLE CHI (ID INTEGER, PARID INTEGER, CONSTRAINT FK FOREIGN KEY (PARID) REFERENCES PAR(ID));
CREATE TABLE PONLY (ID INTEGER, W INTEGER);
COMMIT;
CREATE VIEW V1 AS SELECT ID, V FROM T;
CREATE VIEW V2 AS SELECT ID, W FROM T;
SET TERM ^;
CREATE PROCEDURE PR RETURNS (S INTEGER) AS BEGIN SELECT SUM(W) FROM PONLY INTO :S; SUSPEND; END^
SET TERM ;^
COMMIT;
EOF
    chmod 666 "$1"; }
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
run() { printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | norm; }
FC="127.0.0.1/$PORT:$A"; EN="127.0.0.1/$REAL:$B"
# 1. DROP TABLE T (two views) is refused with "there are 2 dependencies", T survives; STAND drops.
q1="DROP TABLE T; DROP TABLE STAND; COMMIT; SET LIST ON; SELECT RDB\$RELATION_NAME AS R FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME IN ('T','STAND') ORDER BY 1;"
check "DROP TABLE with two dependent views is refused (N=2); a standalone table drops" "$(run "$FC" "$q1")" "$(run "$EN" "$q1")"
# 2. drop the two views, then the table drops cleanly
q2="DROP VIEW V1; DROP VIEW V2; COMMIT; DROP TABLE T; COMMIT; SET LIST ON; SELECT COUNT(*) AS C FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='T';"
check "dropping the views first frees the table" "$(run "$FC" "$q2")" "$(run "$EN" "$q2")"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
# Boundary: a PRIMARY KEY used by a FOREIGN KEY - engine refuses, fc drops
eb=$(run "$EN" "DROP TABLE PAR; COMMIT; SELECT COUNT(*) AS C FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='PAR';")
cb=$(run "$FC" "DROP TABLE PAR; COMMIT; SELECT COUNT(*) AS C FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='PAR';")
ran=$((ran + 1))
if [ "$eb" != "$cb" ] && [ "${eb#*FOREIGN KEY}" != "$eb" ]; then
    echo "OK   boundary: a PK referenced by a FK is refused by the engine, dropped by fc"
else echo "DIFF boundary MOVED: FK parent"; echo "     engine: $eb"; echo "     fc: $cb"; fail=1; fi
# Boundary: a table whose only dependent is a procedure - engine refuses, fc drops
eb=$(run "$EN" "DROP TABLE PONLY; COMMIT; SELECT COUNT(*) AS C FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='PONLY';")
cb=$(run "$FC" "DROP TABLE PONLY; COMMIT; SELECT COUNT(*) AS C FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='PONLY';")
ran=$((ran + 1))
if [ "$eb" != "$cb" ] && [ "${eb#*dependencies}" != "$eb" ]; then
    echo "OK   boundary: a procedure-only dependent is refused by the engine, dropped by fc"
else echo "DIFF boundary MOVED: procedure-only"; echo "     engine: $eb"; echo "     fc: $cb"; fail=1; fi
echo "ran $ran checks"
exit $fail
