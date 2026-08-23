#!/bin/bash
# A NUMERIC / DECIMAL signature on a stored PROCEDURE - fixed-point params
# and outputs, exercised over the wire. fc used to gate a procedure out of
# the exe path (and refuse its describe) unless every parameter and column
# was a plain col_kind; a NUMERIC(p,s) param or RETURNS column fell through.
# The procedure gate now also admits an exact-numeric descriptor, describe
# emits sqltype 496/580 with the declared scale and subtype 1, bind_proc_args
# rescales/round-checks a numeric argument to the parameter's scale (22003
# past width), and a decimal literal in the call args (10.55) now parses to
# a scaled value - it used to fall through parse_call_args and refuse the
# whole selectable-procedure statement.
#
# Covered: SELECT ... FROM P(numeric literals), a NUMERIC-returning SUSPEND
# loop, INTEGER-in / NUMERIC-out and text-in / NUMERIC coercion, division
# widening the scale, EXECUTE PROCEDURE, a negative decimal, and the
# describe (subtype 1). Both servers run the same queries and the rows and
# describe are compared; the ENGINE runs the BLR fc stored.
#
#   qa/serve-real-numproc.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4924}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-numproc-crab.fdb"; B="$D/fc-numproc-engine.fdb"
LOG="/tmp/fc-serve-numproc-$PORT.log"
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
enorm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At procedure/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE PROCEDURE PADD(A NUMERIC(9,2), B NUMERIC(9,2)) RETURNS (R NUMERIC(9,2)) AS BEGIN R = A + B; SUSPEND; END^
CREATE PROCEDURE PMUL(A INTEGER) RETURNS (R NUMERIC(9,2)) AS BEGIN R = A * 1.5; SUSPEND; END^
CREATE PROCEDURE PROWS(N NUMERIC(9,2)) RETURNS (V NUMERIC(9,2)) AS DECLARE I INTEGER; BEGIN I = 1; WHILE (I <= 3) DO BEGIN V = N * I; SUSPEND; I = I + 1; END END^
CREATE PROCEDURE PDIV(A NUMERIC(9,2)) RETURNS (R NUMERIC(18,4)) AS BEGIN R = A / 3; SUSPEND; END^
CREATE PROCEDURE PNARROW(A NUMERIC(4,2)) RETURNS (R NUMERIC(4,2)) AS BEGIN R = A; SUSPEND; END^
CREATE PROCEDURE PI(X INTEGER) RETURNS (Y INTEGER) AS BEGIN Y = X; SUSPEND; END^
CREATE PROCEDURE PT(X VARCHAR(20)) RETURNS (Y VARCHAR(20)) AS BEGIN Y = X; SUSPEND; END^
CREATE PROCEDURE PC(X CHAR(8)) RETURNS (Y VARCHAR(20)) AS BEGIN Y = '[' || X || ']'; SUSPEND; END^
CREATE PROCEDURE PEXE(X INTEGER) RETURNS (Y INTEGER) AS BEGIN Y = X * 10; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the NUMERIC-signature procedures build on both" "$c" "$e"

cat > "$D/np.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PADD(10.55, 20.30);
SELECT R FROM PADD('5.5', 3);
SELECT R FROM PADD(-1.25, 0.25);
SELECT R FROM PADD(1.5e2, 1);
SELECT R FROM PADD(1e-2, 2e-2);
SELECT R FROM PMUL(4);
SELECT V FROM PROWS(2.50);
SELECT R FROM PDIV(10.00);
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/np.sql" 2>&1 | norm; }
check "numeric-literal / scientific / text / negative args, INT->NUMERIC, SUSPEND loop, widening /" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# EXECUTE PROCEDURE returns the singleton output row
cat > "$D/np.sql" <<'SQL'
SET LIST ON;
EXECUTE PROCEDURE PADD(1.10, 2.20);
EXECUTE PROCEDURE PMUL(6);
SQL
check "EXECUTE PROCEDURE with numeric args" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# a value past the parameter width raises 22003 (the At-procedure frame fc
# omits is stripped from the engine's message)
cat > "$D/np.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PNARROW(999.99);
SQL
aof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/np.sql" 2>&1 | enorm; }
check "a numeric arg past the parameter width raises 22003" \
    "$(aof "127.0.0.1/$PORT:$A")" "$(aof "127.0.0.1/$REAL:$B")"

# a DECIMAL literal argument handed to an EXISTING non-numeric procedure:
# the engine's CVT rounds half-away into an INTEGER parameter (22003 past
# width) and renders into a text parameter (a CHAR pads); a non-selectable
# procedure raises the byte-exact -104 whose BLR offset counts the decimal
# literal as a LONG. (Before this slice parse_call_args refused the whole
# statement here; the shared decimal arm now makes fc answer as the engine.)
cat > "$D/np.sql" <<'SQL'
SET LIST ON;
SELECT Y FROM PI(1.5);
SELECT Y FROM PI(2.5);
SELECT Y FROM PI(-1.5);
EXECUTE PROCEDURE PI(3.7);
SELECT Y FROM PT(1.50);
SELECT Y FROM PT(.5);
SELECT Y FROM PC(1.5);
EXECUTE PROCEDURE PEXE(1.5);
SQL
check "a decimal arg rounds into INTEGER / renders into TEXT (CVT) on a non-numeric proc" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

# a decimal past the INTEGER width, and the -104 offset of a non-selectable
# procedure called with a decimal literal
cat > "$D/np.sql" <<'SQL'
SET LIST ON;
SELECT Y FROM PI(99999999999.5);
SELECT Y FROM PEXE(1.5);
SQL
check "22003 past the INTEGER width; the -104 offset counts a decimal as a LONG" \
    "$(aof "127.0.0.1/$PORT:$A")" "$(aof "127.0.0.1/$REAL:$B")"

# the describe of a NUMERIC procedure output
cat > "$D/np.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT R FROM PADD(1.00, 1.00);
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/np.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "NUMERIC procedure-output describe (scale -2, subtype 1)" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# the ENGINE runs fc's stored procedures
kill $srv 2>/dev/null; wait $srv 2>/dev/null
cat > "$D/np.sql" <<'SQL'
SET LIST ON;
SELECT R FROM PADD(12.34, 5.66);
SELECT R FROM PDIV(10.00);
SQL
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/np.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/np.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored NUMERIC procedures" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 18.00"; then echo "OK   PADD(12.34,5.66)=18.00 via fc's stored BLR"; else
    echo "DIFF PADD did not compute: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
