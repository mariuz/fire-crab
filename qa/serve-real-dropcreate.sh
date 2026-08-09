#!/bin/bash
# DROP PROCEDURE, and the systemic fix it uncovered: DROP then CREATE
# the same name, for EVERY catalog object.
#
# fire-crab could not re-create any dropped object - "duplicate key in
# unique index" - because a delete leaves its index entry for the GC
# to clear (as the engine's does), and the unique-index INSERT refused
# against that ghost without checking whether its record was still
# live. The engine's own duplicate scan skips deleted versions; now so
# does fire-crab's (btw::recno_is_live). A LIVE duplicate still
# refuses.
#
# Differential against the engine: each cycle answers the same, and a
# genuine duplicate errors on both.
#
#   qa/serve-real-dropcreate.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4732}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
EDB="$D/fc-dc-e.fdb"; FDB="$D/fc-dc-f.fdb"
rm -f "$EDB" "$FDB"
for c in "localhost:$EDB" "$FDB"; do "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$c' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
done
chmod 666 "$EDB" "$FDB" 2>/dev/null
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dc-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { check "$1" "$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | tr -s ' \n' ' ')" "$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | tr -s ' \n' ' ')"; }

both "an EXCEPTION drops and re-creates under the same name" \
    "CREATE EXCEPTION E_X 'a'; COMMIT; DROP EXCEPTION E_X; COMMIT; CREATE EXCEPTION E_X 'b'; COMMIT;"
both "a SEQUENCE does" \
    "CREATE SEQUENCE SQ; COMMIT; DROP SEQUENCE SQ; COMMIT; CREATE SEQUENCE SQ; COMMIT;"
both "a TABLE does" \
    "CREATE TABLE TT (X INTEGER); COMMIT; DROP TABLE TT; COMMIT; CREATE TABLE TT (Y INTEGER); COMMIT;"
both "...and the re-created table takes rows" \
    "INSERT INTO TT (Y) VALUES (7); COMMIT; SELECT Y FROM TT;"
both "a PROCEDURE drops and re-creates" \
    "SET TERM ^ ; CREATE PROCEDURE PP (A INTEGER) RETURNS (S INTEGER) AS BEGIN S = A; SUSPEND; END^ SET TERM ; ^ COMMIT; DROP PROCEDURE PP; COMMIT; SET TERM ^ ; CREATE PROCEDURE PP (A INTEGER) RETURNS (S INTEGER) AS BEGIN S = A + 1; SUSPEND; END^ SET TERM ; ^ COMMIT;"
both "...and the re-created procedure runs (new body)" \
    "SELECT * FROM PP(10);"
# both these REFUSE on both servers; fire-crab's vector is generic
# where the engine ships its no-meta-update wrapper (a separate,
# recorded DDL-vector family), so the check is "both refuse", not the
# text
refuses() { printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -c "Statement failed"; }
check "DROP PROCEDURE of a missing name refuses on both" \
    "$(refuses "$F" "DROP PROCEDURE NOSUCH;")" "$(refuses "$E" "DROP PROCEDURE NOSUCH;")"
# a LIVE duplicate must still refuse - the fix must not open that door
check "a genuine duplicate EXCEPTION still refuses on both" \
    "$(refuses "$F" "CREATE EXCEPTION E_D 'a'; CREATE EXCEPTION E_D 'b';")" \
    "$(refuses "$E" "CREATE EXCEPTION E_D 'a'; CREATE EXCEPTION E_D 'b';")"

echo "ran $ran checks"
exit $fail
