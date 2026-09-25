#!/bin/bash
# CAST(... AS INT128), AND THE CONVERSION ERRORS OF A NON-NUMERIC SOURCE.
#
# `CAST(x AS INT128)` was refused in EVERY case: the cast grammar's
# keyword scan stopped at the digits and read `INT` followed by a stray
# `128`.  INT128 is the INT128-backed exact at scale 0 with sub_type 0 -
# the descriptor NUMERIC(38,0) has with sub_type 1 - so it now takes the
# NUMERIC arm, which already carries the i128 range, the text / double /
# DECFLOAT conversions and the INT128 arithmetic ranks.
#
# Two error classes this server answered with a BARE "Dynamic SQL Error",
# measured on engine 2182 and matched:
#
#   * a BOOLEAN or a temporal cast to ANY number (INTEGER, BIGINT,
#     SMALLINT, NUMERIC, INT128, DOUBLE, FLOAT) is 22018 on the SOURCE's
#     text - `"BOOLEAN"` for a boolean, the rendered DATE / TIME, and a
#     TIMESTAMP spelled `01-JAN-2020 10:00:00.0000` (CVT's own format);
#   * a DECIMAL text too wide for a 16-byte target (2^127, a 41-digit
#     number, '1.5e40') is 22003 out of range, not a 22018 spelling error.
#
# Usage: qa/serve-real-int128type.sh [port]   (default 4479)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4479}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/int128type-eng.fdb"; FC="$D/int128type-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, I INT128, N NUMERIC(38,0), V VARCHAR(50), B BOOLEAN, D DATE);
INSERT INTO T VALUES (1, 170141183460469231731687303715884105727, 5, '12345678901234567890123', TRUE, '2020-01-01');
INSERT INTO T VALUES (2, -7, -5, '-2.5', FALSE, '2021-06-30');
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL, NULL);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/int128type-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/int128type-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/int128type-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-int128type-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the describe: type, length, charset, nullability
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the same describe
dsame() { # <label> <select>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ]; then echo "FAIL $1 - the engine printed no describe"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# both raise, with DIFFERENT errors - recorded (the class is right)
err_differs() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" = "$ev" ] || [ "${fv#*SQLSTATE}" = "$fv" ]; then
        echo "FAIL $1 - both must raise (eng=[$ev] fc=[$fv])"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THE ERRORS NOW AGREE; promote the cell"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:90}], this server [${fv:0:90}])"; fi
}
DUAL='FROM RDB$DATABASE'
E22003='Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range'
conv() { echo "Statement failed, SQLSTATE = 22018|conversion error from string \"$1\""; }

echo "--- 1. CAST(... AS INT128) (it refused in every case)"
pin  "1 an integer, a rounded decimal both ways" "SELECT CAST(1 AS INT128), CAST(1.5 AS INT128), CAST(-2.5 AS INT128) $DUAL;" "CAST CAST CAST|1 2 -3"
pin  "1 the top of the range, from text" "SELECT CAST('170141183460469231731687303715884105727' AS INT128) $DUAL;" "CAST|170141183460469231731687303715884105727"
pin  "1 ...and the bottom" "SELECT CAST('-170141183460469231731687303715884105728' AS INT128) $DUAL;" "CAST|-170141183460469231731687303715884105728"
pin  "1 2^127 is out of range (22003, not a spelling error)" "SELECT CAST('170141183460469231731687303715884105728' AS INT128) $DUAL;" "CAST|$E22003"
pin  "1 a double past 2^64 is exact" "SELECT CAST(1e20 AS INT128), CAST(2.5e0 AS INT128) $DUAL;" "CAST CAST|100000000000000000000 3"
# a double past 2^127 is 22003 on both - the engine FOLDS the constant and
# raises at PREPARE (no column header), this server at EXECUTE, as its
# NUMERIC(38,0) arm always has: the phase is recorded, the error pinned
ran=$((ran + 1))
ev=$(sess "127.0.0.1/$REAL:$ENG" "SELECT CAST(1e39 AS INT128) $DUAL;"); fv=$(sess "127.0.0.1/$PORT:$FC" "SELECT CAST(1e39 AS INT128) $DUAL;")
if [ "$ev" = "$E22003" ] && [ "${fv#CAST|}" = "$E22003" ]; then echo "OK   1 a double past 2^127 is 22003 (engine at prepare, this server at execute - recorded)"
else echo "FAIL 1 a double past 2^127"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1; fi
pin  "1 NULL" "SELECT CAST(NULL AS INT128) $DUAL;" "CAST|<null>"
pin  "1 garbage text is 22018" "SELECT CAST('x' AS INT128) $DUAL;" "CAST|$(conv x)"
pin  "1 half away from zero, and from a DECFLOAT" "SELECT CAST(7.49 AS INT128), CAST(-7.5 AS INT128), CAST(CAST(3 AS DECFLOAT(34)) AS INT128) $DUAL;" "CAST CAST CAST|7 -8 3"
pin  "1 arithmetic past BIGINT stays INT128" "SELECT CAST(9223372036854775807 AS INT128) + 1, CAST(12345678901234567890 AS INT128) * 10 $DUAL;" "ADD MULTIPLY|9223372036854775808 123456789012345678900"
pin  "1 its text" "SELECT CAST(CAST(5 AS INT128) AS VARCHAR(50)), CAST(-5 AS INT128) || '' $DUAL;" "CAST CONCATENATION|5 -5"
dsame "1 describe: 32752 INT128 len 16 sub_type 0, and INT128 arithmetic" \
      "SELECT CAST(1 AS INT128), CAST(1 AS INT128) + 1, CAST(1 AS INT128) * CAST(2 AS INT128), -CAST(1 AS INT128) $DUAL;"
dsame "1 ...beside NUMERIC(38,0)'s sub_type 1" "SELECT CAST(1 AS NUMERIC(38,0)), CAST(1 AS INT128) $DUAL;"

echo "--- 2. OVER A TABLE"
pin  "2 a column into INT128" "SELECT ID, CAST(N AS INT128), CAST(V AS INT128) FROM T WHERE ID < 3 ORDER BY ID;" "ID CAST CAST|1 5 12345678901234567890123|2 -5 -3"
pin  "2 in WHERE" "SELECT ID FROM T WHERE CAST(V AS INT128) > 1000 ORDER BY ID;" "ID|1"
pin  "2 against the INT128 column" "SELECT ID FROM T WHERE I = CAST('170141183460469231731687303715884105727' AS INT128);" "ID|1"
pin  "2 INSERT ... CAST, read back" "INSERT INTO T (ID, I) VALUES (9, CAST('-9999999999' AS INT128)); SELECT I FROM T WHERE ID = 9; ROLLBACK;" "I|-9999999999"
# RECORDED: an INSERT whose value is a CAST to a 16-byte exact PAST the
# i64 range refuses (NUMERIC(38,0) as well, before this round too) - the
# DML value path carries no 128-bit wire value; the engine stores it
ran=$((ran + 1))
fv=$(sess "127.0.0.1/$PORT:$FC" "INSERT INTO T (ID, I) VALUES (9, CAST('-99999999999999999999' AS INT128)); ROLLBACK;")
case "$fv" in *"SQLSTATE"*) echo "OK   2 recorded: an over-i64 INT128 CAST as an INSERT value refuses here (the engine stores it)";;
    *) echo "FAIL 2 the over-i64 INSERT answered [$fv] - promote the cell"; fail=1;; esac
pin  "2 NULL rows" "SELECT CAST(N AS INT128) FROM T WHERE ID = 3;" "CAST|<null>"

echo "--- 3. A NON-NUMERIC SOURCE CAST TO A NUMBER: 22018 on its text (bare errors before)"
pin  "3 BOOLEAN into INTEGER names its TYPE" "SELECT CAST(TRUE AS INTEGER) $DUAL;" "CAST|$(conv BOOLEAN)"
pin  "3 ...into NUMERIC(38,0)" "SELECT CAST(TRUE AS NUMERIC(38,0)) $DUAL;" "CAST|$(conv BOOLEAN)"
pin  "3 ...into INT128" "SELECT CAST(TRUE AS INT128) $DUAL;" "CAST|$(conv BOOLEAN)"
pin  "3 ...into DOUBLE PRECISION" "SELECT CAST(TRUE AS DOUBLE PRECISION) $DUAL;" "CAST|$(conv BOOLEAN)"
pin  "3 ...into FLOAT" "SELECT CAST(FALSE AS FLOAT) $DUAL;" "CAST|$(conv BOOLEAN)"
pin  "3 ...a BOOLEAN column" "SELECT CAST(B AS BIGINT) FROM T WHERE ID = 1;" "CAST|$(conv BOOLEAN)"
pin  "3 a DATE is its rendered text" "SELECT CAST(DATE '2020-01-01' AS INTEGER) $DUAL;" "CAST|$(conv 2020-01-01)"
pin  "3 ...into NUMERIC(9,2)" "SELECT CAST(DATE '2020-01-01' AS NUMERIC(9,2)) $DUAL;" "CAST|$(conv 2020-01-01)"
pin  "3 ...into INT128" "SELECT CAST(D AS INT128) FROM T WHERE ID = 2;" "CAST|$(conv 2021-06-30)"
pin  "3 a TIME" "SELECT CAST(TIME '10:00:00' AS INTEGER) $DUAL;" "CAST|$(conv 10:00:00.0000)"
pin  "3 a TIMESTAMP is CVT's DD-MON-YYYY" "SELECT CAST(TIMESTAMP '2020-01-01 10:00:00' AS BIGINT) $DUAL;" "CAST|$(conv '01-JAN-2020 10:00:00.0000')"
pin  "3 ...and a zoned one" "SELECT CAST(TIMESTAMP '2020-01-01 10:00:00 UTC' AS INTEGER) $DUAL;" "CAST|$(conv '01-JAN-2020 10:00:00.0000 UTC')"
pin  "3 CONTROL a text still names itself" "SELECT CAST('abc' AS INTEGER) $DUAL;" "CAST|$(conv abc)"

echo "--- 4. A DECIMAL TOO WIDE FOR A 16-BYTE TARGET IS 22003"
pin  "4 2^127 into NUMERIC(38,0)" "SELECT CAST('170141183460469231731687303715884105728' AS NUMERIC(38,0)) $DUAL;" "CAST|$E22003"
pin  "4 41 digits" "SELECT CAST('99999999999999999999999999999999999999999' AS NUMERIC(38,0)) $DUAL;" "CAST|$E22003"
pin  "4 ...signed, with a fraction, at scale 2" "SELECT CAST('-99999999999999999999999999999999999999999.5' AS NUMERIC(38,2)) $DUAL;" "CAST|$E22003"
pin  "4 an exponent spelling" "SELECT CAST('1.5e40' AS NUMERIC(38,0)) $DUAL;" "CAST|$E22003"
pin  "4 CONTROL BIGINT and INTEGER were right already" "SELECT CAST('9223372036854775808' AS BIGINT) $DUAL;" "CAST|$E22003"
pin  "4 CONTROL a bad spelling is still 22018" "SELECT CAST('12x' AS NUMERIC(38,0)) $DUAL;" "CAST|$(conv 12x)"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-int128type-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 39 ]; then echo "FAIL only $ran checks ran (floor 39)"; fail=1; fi
exit $fail
