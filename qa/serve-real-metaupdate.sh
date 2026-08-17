#!/bin/bash
# The no-meta-update wrapper for a DUPLICATE create - the DDL error
# family CREATE PROCEDURE and DROP left generic. A duplicate is the one
# reason shape shared across every object type: the engine answers
# `unsuccessful metadata update / -<VERB> "PUBLIC"."NAME" failed /
# -<Object> "PUBLIC"."NAME" already exists`, and fire-crab emits the
# same three gds items now - isql renders identical text AND the same
# SQLSTATE (42S01 for a table, 42000 otherwise), because the SQLSTATE
# follows the reason code.
#
# DROP-of-a-missing name: the reasons are irregular per type - an
# exception carries no name, a sequence is the generator's "is not
# defined", a procedure names it, and a table nests isc_sqlerr(-607) +
# "Invalid command" + "Table @1 does not exist" - all four matched.
#
#   qa/serve-real-metaupdate.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4733}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
EDB="$D/fc-mu-e.fdb"; FDB="$D/fc-mu-f.fdb"
rm -f "$EDB" "$FDB"
for c in "localhost:$EDB" "$FDB"; do "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$c' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER);
CREATE EXCEPTION E_X 'a';
CREATE SEQUENCE SQ;
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE P AS BEGIN EXIT; END^
SET TERM ; ^
COMMIT;
EOF
done
chmod 666 "$EDB" "$FDB" 2>/dev/null
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-mu-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { check "$1" "$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | tr -s ' \n' ' ')" "$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | tr -s ' \n' ' ')"; }

both "a duplicate TABLE - full no-meta-update vector, SQLSTATE 42S01" "CREATE TABLE T (X INTEGER);"
both "a duplicate EXCEPTION" "CREATE EXCEPTION E_X 'b';"
both "a duplicate SEQUENCE" "CREATE SEQUENCE SQ;"
both "a duplicate PROCEDURE" "SET TERM ^ ; CREATE PROCEDURE P AS BEGIN EXIT; END^ SET TERM ; ^"

# DROP of a missing name - the reasons are irregular per type, and
# three of them are carried now (exception carries no name, sequence is
# the generator's "is not defined", procedure names it)
both "a missing EXCEPTION - full vector" "DROP EXCEPTION NOPE;"
both "a missing SEQUENCE - generator is-not-defined" "DROP SEQUENCE NOPE;"
both "a missing PROCEDURE - names it" "DROP PROCEDURE NOPE;"
# DROP TABLE's reason is the ONE nested shape - isc_sqlerr(-607) +
# "Invalid command" + "Table @1 does not exist" (42S02) - carried now,
# so the whole DROP-missing family is byte-matched
both "a missing TABLE - the nested -607 vector, SQLSTATE 42S02" "DROP TABLE NOPE;"

echo "ran $ran checks"
exit $fail
