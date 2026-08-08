#!/bin/bash
# A procedure's OUTPUT PARAMETERS describe their DECLARED types.
#
# fire-crab used to announce every output as BIGINT (581/8): the VALUES
# agreed, the widths a client renders did not - visible the moment a
# procedure has two output columns, because isql draws each column at
# the width the describe announces. The engine announces what the DDL
# declared, and so does this server now (proc_out_col rides wire_for,
# the same descriptor-to-wire mapping every table column uses).
#
# Two teeth marks this gate keeps bitten:
#   * RDB$FIELD_LENGTH is the PAYLOAD; a record descriptor's VARYING
#     length carries the 2-byte count word on top, and the describe
#     subtracts it back - without the normalization a VARCHAR(7)
#     output announced as 5 and isql drew the column a width short;
#   * TEXT OUTPUT parameters ride now (the interpreter's variables have
#     been Value slots all along); text INPUTS stay refused - the call
#     sites parse integer literals and NULL, and a silently coerced
#     text argument would be a wrong answer.
#
#   qa/serve-real-procdescribe.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4728}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-procdescribe-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

mkdb() {
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 'one');
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE PMIX RETURNS (A INTEGER, B VARCHAR(7), C SMALLINT, D BIGINT) AS
BEGIN
  A = 1; B = 'x'; C = 2; D = 3;
  SUSPEND;
END^
CREATE PROCEDURE PTXT RETURNS (S VARCHAR(9)) AS
BEGIN
  S = 'from-body';
  SUSPEND;
END^
CREATE PROCEDURE PTIN (S VARCHAR(5)) RETURNS (N INTEGER) AS
BEGIN
  N = 1;
  SUSPEND;
END^
SET TERM ; ^
COMMIT;
EOF
}
EDB="$D/fc-pdesc-e.fdb"
FDB="$D/fc-pdesc-f.fdb"
rm -f "$EDB" "$FDB"
mkdb "localhost:$EDB"
mkdb "$FDB"
chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
E="localhost:$EDB"
F="127.0.0.1/$PORT:$FDB"
run() { printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1; }

# --- 1. the widths ARE the check: full isql output, headers included -----------
check "SELECT * FROM a mixed-type procedure renders identically" \
    "$(run "$F" 'SELECT * FROM PMIX;')" "$(run "$E" 'SELECT * FROM PMIX;')"
check "EXECUTE PROCEDURE renders identically too" \
    "$(run "$F" 'EXECUTE PROCEDURE PMIX;')" "$(run "$E" 'EXECUTE PROCEDURE PMIX;')"
check "a projection keeps its columns' own types (B, C)" \
    "$(run "$F" 'SELECT B, C FROM PMIX;')" "$(run "$E" 'SELECT B, C FROM PMIX;')"
check "...and an alias keeps the type (probed field/alias split)" \
    "$(run "$F" 'SELECT B AS BB FROM PMIX;')" "$(run "$E" 'SELECT B AS BB FROM PMIX;')"

# --- 2. a TEXT output parameter rides now ---------------------------------------
check "a text output arrives with its declared width" \
    "$(run "$F" 'SELECT * FROM PTXT;')" "$(run "$E" 'SELECT * FROM PTXT;')"
check "...through EXECUTE PROCEDURE as well" \
    "$(run "$F" 'EXECUTE PROCEDURE PTXT;')" "$(run "$E" 'EXECUTE PROCEDURE PTXT;')"

# --- 3. the boundary: a text INPUT still refuses ---------------------------------
out=$(run "$F" "SELECT * FROM PTIN('ab');" | head -2 | tr -s ' \n' ' ')
check "boundary: a text INPUT parameter refuses rather than coerces" \
    "$out" "Statement failed, SQLSTATE = 42000 Dynamic SQL Error "

echo "ran $ran checks"
exit $fail
