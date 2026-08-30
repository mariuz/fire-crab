#!/bin/bash
# CREATE TABLE with DECFLOAT and TIME/TIMESTAMP WITH TIME ZONE columns - the
# column types that fell to Plan::Refused. Probed: the catalog (RDB$FIELD_TYPE
# 24/25/28/29, length 8/16/8/12, precision 16/34 for DECFLOAT, no sub_type),
# the describe, and the record layout - a DECFLOAT value inserted through fc
# round-trips, and a value the ENGINE writes into fc's table (including the
# time-zone types) is read back byte-identically by both. gfix validates it.
# Boundary (recorded): a TIME/TIMESTAMP WITH TIME ZONE *literal* in an INSERT
# through fc refuses (the value-literal parser, a separate DML gap) - the gate
# lets the ENGINE write those values into fc's table.
#
#   qa/serve-real-coltypes.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4892}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-coltypes-crab.fdb"
B="$D/fc-coltypes-engine.fdb"
LOG="/tmp/fc-serve-coltypes-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"
fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr-$(basename "$0" .sh)" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
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
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# create the table + insert a DECFLOAT row (NULL for the tz types) through each server
mk() { cat <<'SQL'
CREATE TABLE CT (ID INTEGER, D16 DECFLOAT(16), D34 DECFLOAT, D34B DECFLOAT(34), TZ TIME WITH TIME ZONE, TSZ TIMESTAMP WITH TIME ZONE);
COMMIT;
INSERT INTO CT VALUES (1, 1.5, 12345.6789, -0.0001, NULL, NULL);
INSERT INTO CT VALUES (2, -9.99, 98765.4321, 3.5, NULL, NULL);
COMMIT;
SQL
}
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
cat_q="SET LIST ON; SELECT rf.RDB\$FIELD_NAME AS C, f.RDB\$FIELD_TYPE AS FT, f.RDB\$FIELD_LENGTH AS LEN, f.RDB\$FIELD_SCALE AS SCL, f.RDB\$FIELD_SUB_TYPE AS SUB, f.RDB\$FIELD_PRECISION AS PREC FROM RDB\$RELATION_FIELDS rf JOIN RDB\$FIELDS f ON f.RDB\$FIELD_NAME = rf.RDB\$FIELD_SOURCE WHERE rf.RDB\$RELATION_NAME = 'CT' ORDER BY rf.RDB\$FIELD_POSITION;"
e=$(printf '%s\n' "$cat_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(printf '%s\n' "$cat_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "the catalog (field type / length / precision) for DECFLOAT and the tz types" "$c" "$e"
desc_q="SET SQLDA_DISPLAY ON; SELECT D16, D34, D34B, TZ, TSZ FROM CT WHERE ID = 1;"
e=$(printf '%s\n' "$desc_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep sqltype | norm)
c=$(printf '%s\n' "$desc_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep sqltype | norm)
check "the describe of the columns" "$c" "$e"
rows_q="SELECT ID, D16, D34, D34B FROM CT ORDER BY ID;"
e=$(printf '%s\n' "$rows_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(printf '%s\n' "$rows_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "DECFLOAT values inserted through fc round-trip" "$c" "$e"
# a tz literal in an INSERT works since the tzdml slice - run the SAME
# insert on BOTH so the row batteries below stay twins (the refusal
# this used to pin is CLOSED)
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<'SQL' >/dev/null 2>&1
INSERT INTO CT VALUES (9, 1, 1, 1, TIME '10:20:30 +02:00', NULL);
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<'SQL' >/dev/null 2>&1
INSERT INTO CT VALUES (9, 1, 1, 1, TIME '10:20:30 +02:00', NULL);
COMMIT;
SQL
ran=$((ran + 1))
tzr=$(printf 'SET LIST ON; SELECT TZ FROM CT WHERE ID = 9;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
tze=$(printf 'SET LIST ON; SELECT TZ FROM CT WHERE ID = 9;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
if [ "$tzr" = "$tze" ]; then echo "OK   a WITH TIME ZONE literal INSERT through fc round-trips (the tzdml slice closed the old refusal)"
else echo "DIFF tz literal insert: fc [$tzr] engine [$tze]"; fail=1; fi
# the ENGINE writes tz values into fc's table (proving the record layout), then
# BOTH engines read the same content back
"$ISQL" -q -user "$U" -pas "$P" "$A" <<'SQL' >/dev/null 2>&1
INSERT INTO CT VALUES (3, 7, 7, 7, TIME '10:20:30 +02:00', TIMESTAMP '2025-08-21 10:20:30.1234 +02:00');
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "$B" <<'SQL' >/dev/null 2>&1
INSERT INTO CT VALUES (3, 7, 7, 7, TIME '10:20:30 +02:00', TIMESTAMP '2025-08-21 10:20:30.1234 +02:00');
COMMIT;
SQL
read_q="SELECT ID, D16, D34, TZ, TSZ FROM CT ORDER BY ID;"
# the ENGINE reads fc's file vs the engine's own file
e=$(printf '%s\n' "$read_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$read_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's table (tz values it wrote into fc's own layout)" "$c" "$e"
# and fc itself reads the tz values the engine wrote
cf=$(printf '%s\n' "$read_q" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "fc reads the tz values back from its own table" "$cf" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
