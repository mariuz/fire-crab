#!/bin/bash
# A TEXT-mixed DECFLOAT CONDITIONAL (COALESCE/CASE/IIF/DECODE with a decfloat
# branch beside a CHAR/VARCHAR branch) folds to VARYING with the decfloat
# rendered to text - matching the engine, where fire-crab refused.
#
# TEXT wins over DECFLOAT (the measured precedence), so the result is
# VARYING (448), sub_type 0, scale 0, order-independent - even beside a CHAR
# branch (VARYING, not TEXT). The decfloat branch contributes a FIXED
# character render width: DECFLOAT(16) = 23 ("-9.999999999999999E+384"),
# DECFLOAT(34) = 42; the result char width is the MAX over all branches
# (decfloat 23/42 vs each text branch's declared char count), and df34
# anywhere forces 42. The decfloat is charset-NEUTRAL (announces NONE); the
# resolved charset is the text branch's, and len is bytes = chars *
# bytes-per-char of the winning charset. The decfloat value renders to its
# canonical string (Value::render). A NULL decfloat branch is transparent.
#
# This is a clean reuse of the working numeric-beside-text conditional path:
# conditional_type stops refusing when a text branch is present, text_form
# gives a decfloat operand the 23/42 render width, and value_of renders a
# surviving decfloat branch to text.
#
# DEFERRED (unchanged): TEXT-mixed decfloat UNIONs (the union path has no
# numeric-to-text typing yet - a separate slice); NULLIF(decfloat, text)
# keeps its DECFLOAT(16) first-operand type and its value comparison is a
# separate pre-existing surface; `<decfloat> || <text>` concatenation still
# refuses (a distinct resolve gate).
#
# Usage: qa/serve-real-decfloattextcond.sh [port]   (default 4173)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4173}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dftxt-eng.fdb"; FC="$D/dftxt-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dftxt-build.log 2>&1 <<'SQL'
create table t(id int, d16 decfloat(16), d34 decfloat(34), s varchar(10), s5 varchar(5), c char(8),
               su varchar(10) character set utf8, sw varchar(10) character set win1252);
commit;
insert into t values (1, 1.5, 2.5, 'abc', 'de', 'ch', 'uu', 'ww');
commit;
SQL
if grep -qi error /tmp/dftxt-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dftxt-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dftxt.log 2>&1 &
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
vc() { printf "cast(%s as varchar(60))" "$1"; }

echo "-- describe: VARYING, width 23/42, order-independent, CHAR -> VARYING --"
agree "COALESCE(d16,s) 23"   "select coalesce(d16,s) x from t;"
agree "COALESCE(s,d16) 23"   "select coalesce(s,d16) x from t;"
agree "COALESCE(d34,s) 42"   "select coalesce(d34,s) x from t;"
agree "COALESCE(d16,c CHAR)" "select coalesce(d16,c) x from t;"
agree "COALESCE(d16,s5) 23"  "select coalesce(d16,s5) x from t;"
agree "COALESCE(d16,vc50) 50" "select coalesce(d16,cast(s as varchar(50))) x from t;"
agree "COALESCE(d16,d34,s) 42" "select coalesce(d16,d34,s) x from t;"
echo "-- charset: text branch decides, len = bytes --"
agree "COALESCE(d16,su UTF8) 92" "select coalesce(d16,su) x from t;"
agree "COALESCE(d16,sw WIN1252)" "select coalesce(d16,sw) x from t;"
agree "COALESCE(d34,su UTF8) 168" "select coalesce(d34,su) x from t;"
echo "-- forms: CASE / IIF / DECODE --"
agree "CASE d16 else s"  "select case when id=1 then d16 else s end x from t;"
agree "IIF d34 s"        "select iif(id=1,d34,s) x from t;"
agree "DECODE d16 s"     "select decode(id,1,d16,s) x from t;"
echo "-- value: decfloat rendered to its canonical string --"
agree "d16 -> 1.5"   "select $(vc "coalesce(d16,s)") x from t;"
agree "d34 -> 2.5"   "select $(vc "coalesce(d34,s)") x from t;"
agree "null d16 -> text branch" "select $(vc "coalesce(cast(null as decfloat(16)), s)") x from t;"
agree "1/3 df34 render" "select $(vc "coalesce(cast(1 as decfloat(34))/cast(3 as decfloat(34)), s)") x from t;"
agree "negative df34"   "select $(vc "coalesce(-d34, s)") x from t;"
echo "-- controls: no-text decfloat mixes still fold DECFLOAT (not text) --"
agree "COALESCE(d16,int) df16"  "select coalesce(d16,5) x from t;"
agree "COALESCE(d16,d34) df34"  "select coalesce(d16,d34) x from t;"
agree "COALESCE(i,s) numeric-text (unchanged)" "select coalesce(id,s) x from t;"
agree "COALESCE(s,s5) all-text (unchanged)" "select coalesce(s,s5) x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS decfloattextcond" || echo "FAIL decfloattextcond"
exit $fail
