#!/bin/bash
# A SELECTABLE `EXECUTE BLOCK RETURNS (...) AS ... SUSPEND ... END` - an
# anonymous procedure run as a statement, its SUSPENDed rows the result
# set. fc ran plain (non-returning) blocks already; this adds the
# RETURNS form: the body is interpreted and its rows served like a
# selectable procedure's, the columns described from the RETURNS clause
# (an empty table/owner, the engine's shape). Both servers run the same
# blocks; the rows, the describe and an in-body error's position are
# compared.
#
# Boundaries (recorded): input parameters (`EXECUTE BLOCK (p type = ?)
# ...`) need a client message and are not taken; a block that names an
# object the compiler cannot resolve (an undefined EXCEPTION) refuses on
# both, fc generically.
#
#   qa/serve-real-execblock.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4894}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-execblock-crab.fdb"; B="$D/fc-execblock-engine.fdb"
LOG="/tmp/fc-serve-execblock-$PORT.log"
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
CREATE TABLE T (ID INTEGER);
INSERT INTO T VALUES (10); INSERT INTO T VALUES (20); INSERT INTO T VALUES (30);
COMMIT;
EOF
done

rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/eb.sql" 2>&1 | norm; }

cat > "$D/eb.sql" <<'SQL'
SET LIST ON;
SET TERM ^;
EXECUTE BLOCK RETURNS (N INTEGER) AS DECLARE I INTEGER; BEGIN I = 0; WHILE (I < 3) DO BEGIN I = I + 1; N = I * 10; SUSPEND; END END^
EXECUTE BLOCK RETURNS (S INTEGER) AS BEGIN FOR SELECT ID FROM T ORDER BY ID INTO :S DO SUSPEND; END^
EXECUTE BLOCK RETURNS (A INTEGER, B VARCHAR(5)) AS BEGIN A = 1; B = 'hi'; SUSPEND; A = 2; B = 'yo'; SUSPEND; END^
SET TERM ;^
SQL
check "EXECUTE BLOCK RETURNS - WHILE, FOR SELECT and a multi-column block" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# the describe: the RETURNS columns, an empty table/owner (the engine's shape)
cat > "$D/eb.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SET TERM ^;
EXECUTE BLOCK RETURNS (N INTEGER, S VARCHAR(10)) AS BEGIN N = 1; S = 'hi'; SUSPEND; END^
SET TERM ;^
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/eb.sql" 2>&1 | grep -iE "sqltype|name:|table:" | norm; }
check "EXECUTE BLOCK RETURNS describe (columns, empty table)" "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# an in-body runtime error carries the block position
cat > "$D/eb.sql" <<'SQL'
SET TERM ^;
EXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = 1 / 0; SUSPEND; END^
SET TERM ;^
SQL
check "an in-body error carries 'At block line: L, col: C'" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# a plain (non-returning) block still runs and writes
cat > "$D/eb.sql" <<'SQL'
SET TERM ^;
EXECUTE BLOCK AS BEGIN INSERT INTO T (ID) VALUES (99); END^
SET TERM ;^
SET LIST ON;
SELECT COUNT(*) AS C FROM T WHERE ID = 99;
SQL
check "a plain EXECUTE BLOCK still runs (and writes)" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
