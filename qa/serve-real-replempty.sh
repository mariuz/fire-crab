#!/bin/bash
# REPLACE WITH AN EMPTY SEARCH STRING RETURNS THE SOURCE UNCHANGED, SO
# ITS DESCRIBED WIDTH IS THE SOURCE WIDTH - NOT DOUBLED.
#
# REPLACE(s, find, repl) grows the described width by how much longer the
# replacement is than what it replaces, once per possible occurrence. An
# EMPTY find matches nothing - the engine returns the source unchanged -
# so the result cannot grow. fire-crab computed the occurrence count as
# source_width / max(find_width, 1); with an empty find that divisor
# became 1, so the growth was replacement_width * source_width and the
# announced VARCHAR width doubled: REPLACE(VARCHAR(10) UTF8, '', 'X')
# described 80 bytes where the engine describes 40. The value was already
# the source unchanged; this fixes the announced width (an over-wide
# describe mis-sizes a client buffer). Guarding an empty find to zero
# growth leaves every non-empty-search case exactly as it was.
#
# Usage: qa/serve-real-replempty.sh [port]   (default 4159)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4159}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/replempty-eng.fdb"; FC="$D/replempty-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/replempty-build.log 2>&1 <<'SQL'
create table t(s varchar(10), u varchar(10) character set utf8, w varchar(8) character set win1252);
commit;
insert into t values ('aaa','aaa','aaa');
commit;
SQL
if grep -qi error /tmp/replempty-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/replempty-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-replempty.log 2>&1 &
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

echo "-- the fix: an empty search returns the source unchanged, source width --"
agree "replace(lit,'',X)"     "select replace('aaa','','X') x from t;" UTF8
agree "replace(s,'',X)"       "select replace(s,'','X') x from t;" UTF8
agree "replace(u,'',Z)"       "select replace(u,'','Z') x from t;" UTF8
agree "replace(w,'',Z)"       "select replace(w,'','Z') x from t;" UTF8
agree "replace(s,'',longer)"  "select replace(s,'','abcde') x from t;" UTF8
agree "replace(s,'',X) @NONE" "select replace(s,'','X') x from t;" ""
agree "replace(s,'',X) @WIN"  "select replace(s,'','X') x from t;" WIN1252
agree "replace(s,'','')"      "select replace(s,'','') x from t;" UTF8
echo "-- non-empty search: growth per occurrence, unchanged --"
agree "replace(s,a,XX)"       "select replace(s,'a','XX') x from t;" UTF8
agree "replace(s,a,X)"        "select replace(s,'a','X') x from t;" UTF8
agree "replace(s,ab,'')"      "select replace(s,'ab','') x from t;" UTF8
agree "replace(s,x,abcde)"    "select replace(s,'x','abcde') x from t;" UTF8
agree "replace(s,aa,bbbb)"    "select replace(s,'aa','bbbb') x from t;" UTF8
agree "replace(s,abc,z)"      "select replace(s,'abc','z') x from t;" UTF8
agree "replace(u,a,ZZ) @UTF8" "select replace(u,'a','ZZ') x from t;" UTF8

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS replempty" || echo "FAIL replempty"
exit $fail
