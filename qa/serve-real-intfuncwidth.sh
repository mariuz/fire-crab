#!/bin/bash
# Integer builtins keep their own width through a MOD literal and a MIN/MAX
# fold - matching the engine, where fire-crab announced the 8-byte default.
#
# Two describe-only width gaps, both "INT64 where the engine says LONG":
#  * MOD over an integer LITERAL: int_func_form read the dividend's width
#    only from a COLUMN (src_dtype), so MOD(10, 3) fell to the 8-byte
#    default (BIGINT) where the engine types the INTEGER literal LONG. It
#    now reads an integer literal's natural width (INTEGER < 2^31, else
#    BIGINT; INT128 stays), matching MOD(<column>) which was already right.
#  * MIN/MAX over an integer FUNCTION expression: the aggregate width came
#    from result_width_bytes, which knew arithmetic and the conditionals
#    but not the integer builtins - so MAX(CHAR_LENGTH(s)) announced INT64
#    where the bare CHAR_LENGTH(s) (and the engine's fold) is LONG.
#    result_width_bytes now consults int_func_form for a builtin, so the
#    two agree and a wrapping fold keeps the builtin's width.
# Value and scale are unchanged. Held against the live engine.
#
# Usage: qa/serve-real-intfuncwidth.sh [port]   (default 4167)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4167}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/intfw-eng.fdb"; FC="$D/intfw-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/intfw-build.log 2>&1 <<'SQL'
create table t(id integer, s varchar(20), si smallint, ii integer, bi bigint);
commit;
insert into t values (1, 'hello', 10, 100, 1000);
insert into t values (2, 'worldly', 20, 200, 2000);
commit;
SQL
if grep -qi error /tmp/intfw-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/intfw-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-intfw.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^01: sqltype|^X ' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }

echo "-- MOD over an integer literal: INTEGER literal -> LONG, wide literal -> BIGINT --"
agree "mod(10,3) -> LONG"          "select mod(10,3) x from t;"
agree "mod(2147483648,3) -> BIGINT" "select mod(2147483648,3) x from t;"
agree "mod(ii,3) col (control)"    "select mod(ii,3) x from t;"
agree "mod(si,3) SMALLINT col"     "select mod(si,3) x from t;"
agree "mod(bi,3) BIGINT col"       "select mod(bi,3) x from t;"
echo "-- MIN/MAX over an integer function keeps the function's own width --"
agree "max(char_length(s)) -> LONG" "select max(char_length(s)) x from t;"
agree "min(char_length(s)) -> LONG" "select min(char_length(s)) x from t;"
agree "max(octet_length(s)) -> LONG" "select max(octet_length(s)) x from t;"
agree "max(position('l' in s)) -> LONG" "select max(position('l' in s)) x from t;"
agree "max(sign(ii)) -> SMALLINT"   "select max(sign(ii)) x from t;"
agree "max(mod(ii,3)) -> LONG"      "select max(mod(ii,3)) x from t;"
agree "max(abs(si)) -> LONG"        "select max(abs(si)) x from t;"
echo "-- controls: bare functions, arithmetic wrap, plain integer folds --"
agree "char_length(s) bare"        "select char_length(s) x from t;"
agree "char_length(s)+0 arith"     "select char_length(s)+0 x from t;"
agree "mod(10,3)+0 arith"          "select mod(10,3)+0 x from t;"
agree "coalesce(char_length(s),0)" "select coalesce(char_length(s),0) x from t;"
agree "max(ii) plain INTEGER"      "select max(ii) x from t;"
agree "max(bi) plain BIGINT"       "select max(bi) x from t;"
agree "max(si) plain SMALLINT"     "select max(si) x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS intfuncwidth" || echo "FAIL intfuncwidth"
exit $fail
