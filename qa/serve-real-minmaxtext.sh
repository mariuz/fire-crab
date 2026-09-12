#!/bin/bash
# MIN/MAX OVER A TEXT EXPRESSION DESCRIBES AT THE EXPRESSION'S REAL WIDTH
# AND CHARSET - NOT A VARCHAR(32765)/NONE CATCH-ALL.
#
# MIN/MAX describe what their source describes: for a text COLUMN they
# keep the column's own descriptor (already correct), and for a text
# EXPRESSION the aggregate descriptor IS the expression's projection
# descriptor. fire-crab defaulted a text-expression source to
# VARCHAR(32765) charset NONE - so MAX(s||'!') announced a 32765-wide
# NONE column where the engine announces VARCHAR(11) UTF8 (the concat
# width 10+1, the operand/attachment charset). The VALUE was already
# correct; a wrong announced width and charset can mis-drive a client's
# buffer sizing and transliteration.
#
# The describe now reuses build_expr_col_from (the same projection
# describe SELECT <expr> uses), so MIN/MAX of a concat / UPPER /
# SUBSTRING / TRIM / LEFT / CASE / COALESCE over text announces exactly
# what the projected expression does - width per function, and the same
# charset (operand, or the attachment under a real-charset attach). A
# plain text COLUMN MIN/MAX, numeric MIN/MAX, and SUM/AVG are unchanged.
# Held against the live engine under UTF8 and WIN1252 attachments.
#
# RECORDED, not here (pre-existing, inherited from the projection path):
# an ASCII-operand concat under a NONE attachment announces charset NONE
# where the engine keeps ASCII (SELECT a||'!' has the same gap); and
# MIN/MAX over an INTEGER EXPRESSION (e.g. char_length) announces INT64
# where the engine keeps LONG (the numeric-expr width arm, untouched).
#
# Usage: qa/serve-real-minmaxtext.sh [port]   (default 4158)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4158}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/minmaxtext-eng.fdb"; FC="$D/minmaxtext-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/minmaxtext-build.log 2>&1 <<'SQL'
create table t(s varchar(10) character set utf8, w varchar(8) character set win1252,
               a varchar(6) character set ascii, n varchar(10), c char(5) character set utf8);
commit;
insert into t values ('ab','ab','ab','ab','ab');
insert into t values ('cd','cd','cd','cd','cd');
insert into t values ('ax','ax','ax','ax','ax');
commit;
SQL
if grep -qi error /tmp/minmaxtext-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/minmaxtext-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-minmaxtext.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { local ch=""; [ -n "${3:-}" ] && ch="-ch $3"; printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^01: sqltype|^X ' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" "$2" "${3:-}"); if [ "$e" = "$f" ]; then echo "OK   [${3:-NONE}] $1"; else echo "FAIL [${3:-NONE}] $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }

echo "-- the fix: MIN/MAX over a text expression, real width + charset (UTF8 attach) --"
agree "MAX(s||lit)"      "select max(s||'!') x from t;" UTF8
agree "MIN(s||lit)"      "select min(s||'!') x from t;" UTF8
agree "MAX(UPPER(s))"    "select max(upper(s)) x from t;" UTF8
agree "MAX(SUBSTRING 1 3)" "select max(substring(s from 1 for 3)) x from t;" UTF8
agree "MAX(LEFT s 4)"    "select max(left(s,4)) x from t;" UTF8
agree "MAX(s||s)"        "select max(s||s) x from t;" UTF8
agree "MAX(TRIM s)"      "select max(trim(s)) x from t;" UTF8
agree "MAX(CHAR c||lit)" "select max(c||'!') x from t;" UTF8
agree "MAX(WIN w||lit)"  "select max(w||'!') x from t;" UTF8
agree "MAX(ASCII a||lit)" "select max(a||'!') x from t;" UTF8
agree "MAX(NONE n||lit)" "select max(n||'!') x from t;" UTF8
agree "MAX(COALESCE)"    "select max(coalesce(s,'xx')) x from t;" UTF8
agree "MAX(CASE text)"   "select max(case when s>'a' then s else 'zz' end) x from t;" UTF8
echo "-- WIN1252 attachment --"
agree "MAX(s||lit) @WIN" "select max(s||'!') x from t;" WIN1252
agree "MAX(w||lit) @WIN" "select max(w||'!') x from t;" WIN1252
agree "MAX(a||lit) @WIN" "select max(a||'!') x from t;" WIN1252
echo "-- controls that must stay unchanged --"
agree "MAX(s) col (UTF8)" "select max(s) x from t;" UTF8
agree "MIN(s) col (UTF8)" "select min(s) x from t;" UTF8
agree "MAX(c) CHAR col"   "select max(c) x from t;" UTF8
agree "MAX(s) col @WIN"   "select max(s) x from t;" WIN1252
agree "MAX numeric expr"  "select max(char_length(s)*10) x from t;" UTF8
agree "SUM numeric"       "select sum(char_length(s)) x from t;" UTF8

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS minmaxtext" || echo "FAIL minmaxtext"
exit $fail
