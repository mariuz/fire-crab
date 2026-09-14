#!/bin/bash
# DECFLOAT concatenation (the || operator) matches the engine, where
# fire-crab refused a decfloat operand at prepare.
#
# `<decfloat> || <anything>` (either order) is VARYING (448), scale 0,
# sub_type 0 - the decfloat renders to its canonical string. WIDTH = sum of
# the two operands' text CHAR-widths (decfloat contributes 23 for
# DECFLOAT(16), 42 for DECFLOAT(34)), times bytes-per-char for a multibyte
# result charset. CHARSET = the text operand's (first-real-wins; the
# decfloat announces NONE). VALUE = each operand rendered and joined; a NULL
# operand makes the result NULL (width still the summed declared widths).
#
# The describe width (text_form decfloat arm) and the Concat eval render
# (Value::render) were already in place from the TEXT-mixed conditional
# chunk; the only refuse was the Concat arm of type_of, which required both
# operands to be typeable (a decfloat has no ExprType). It now skips a
# decfloat operand's type_of the same way the CAST arm does, so a decfloat
# concat operand is accepted; a genuinely untypeable operand (text/temporal
# mix, bare double literal) still refuses.
#
# Usage: qa/serve-real-decfloatconcat.sh [port]   (default 4174)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4174}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfcat-eng.fdb"; FC="$D/dfcat-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfcat-build.log 2>&1 <<'SQL'
create table t(id int, d16 decfloat(16), d34 decfloat(34), s varchar(10), c char(5), su varchar(10) character set utf8);
commit;
insert into t values (1, 1.5, 2.5, 'ab', 'cd', 'ef');
commit;
SQL
if grep -qi error /tmp/dfcat-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfcat-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfcat.log 2>&1 &
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
vc() { printf "cast(%s as varchar(80))" "$1"; }

echo "-- describe: VARYING, width = sum of char widths (df16=23, df34=42), both orders --"
agree "d16 || lit -> 24"   "select d16 || 'x' x from t;"
agree "lit || d16 -> 24"   "select 'x' || d16 x from t;"
agree "d34 || lit -> 43"   "select d34 || 'x' x from t;"
agree "d34 || s -> 52"     "select d34 || s x from t;"
agree "s || d34 -> 52"     "select s || d34 x from t;"
agree "d16 || d34 -> 65"   "select d16 || d34 x from t;"
agree "d16 || 5 -> 34"     "select d16 || 5 x from t;"
agree "d16 || c CHAR -> 28" "select d16 || c x from t;"
agree "d16 || 'x' || 'y' -> 25" "select d16 || 'x' || 'y' x from t;"
echo "-- charset: text operand decides; UTF8 -> *4 byte width --"
agree "d16 || su UTF8 -> 132 cs4" "select d16 || su x from t;"
agree "su || d16 UTF8"     "select su || d16 x from t;"
echo "-- value: canonical decfloat string concatenated --"
agree "d16 || lit val"     "select $(vc "d16 || 'x'") x from t;"
agree "lit || d16 val"     "select $(vc "'x' || d16") x from t;"
agree "d34 || s val"       "select $(vc "d34 || s") x from t;"
agree "d16 || d34 val"     "select $(vc "d16 || d34") x from t;"
agree "d16 || 5 val"       "select $(vc "d16 || 5") x from t;"
agree "chained val"        "select $(vc "d16 || 'x' || 'y'") x from t;"
agree "1/3 df34 || lit"    "select $(vc "cast(1 as decfloat(34))/cast(3 as decfloat(34)) || '!'") x from t;"
echo "-- NULL operand -> NULL value, declared width --"
agree "d16 || null"        "select d16 || cast(null as varchar(4)) x from t;"
echo "-- controls: non-decfloat concat unchanged --"
agree "s || c text"        "select s || c x from t;"
agree "5 || 'x' int-text"  "select 5 || 'x' x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS decfloatconcat" || echo "FAIL decfloatconcat"
exit $fail
