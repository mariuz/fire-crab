#!/bin/bash
# A CONDITIONAL (COALESCE/CASE/DECODE/IIF) THAT MIXES NUMERIC AND TEXT
# BRANCHES UNIFIES TO TEXT, and a numeric operand concatenated with text
# renders to its digits at the engine's width.
#
# fire-crab used to keep the NUMERIC type for a mixed conditional (text
# wins in the engine's DataTypeUtil::makeFromList), so COALESCE(<int>,
# 'xnone') came back as 0 - the string branch silently coerced to a
# number. It also announced the character result at the VARCHAR maximum
# (32765) instead of the engine's render width, for both mixed
# conditionals and `<numeric> || <text>` concatenation.
#
# Values are read against the engine over a fixture the engine built and
# copied byte-identically; the described type and length are read from
# SET SQLDA_DISPLAY through both servers and must match.
#
# Usage: qa/serve-real-condtext.sh [port]   (default 4137)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4137}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/condtext-eng.fdb"; FC="$D/condtext-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/condtext-build.log 2>&1 <<'SQL'
create table t (id integer, a integer, b integer, s varchar(20), n numeric(9,2));
commit;
insert into t values (1, 10, 20, 'x', 1.5);
insert into t values (2, null, 5, 'y', null);
insert into t values (5, null, null, 'z', 9.99);
commit;
SQL
if grep -qi error /tmp/condtext-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/condtext-build.log; exit 1; fi
cp "$ENG" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-condtext.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
val() { "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/[[:space:]]*$//'; }
desc() { printf 'set sqlda_display on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -i 'sqltype:' | head -1 | grep -o 'sqltype: [0-9]* [A-Za-z]*.*len: [0-9]*'; }

both_val() { # <label> <query>
    local a b
    a=$(val "127.0.0.1/3050:$ENG" <<< "$2"); b=$(val "127.0.0.1/$PORT:$FC" <<< "$2")
    if [ "$a" = "$b" ]; then echo "OK   value: $1"; else echo "FAIL value: $1"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/     /'; fail=1; fi
}
both_desc() { # <label> <query>
    local a b
    a=$(desc "127.0.0.1/3050:$ENG" "$2"); b=$(desc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$a" = "$b" ]; then echo "OK   desc:  $1 [$a]"; else echo "FAIL desc:  $1"; echo "     eng: $a"; echo "     fc : $b"; fail=1; fi
}

for spec in \
  "coalesce int+text            @@select coalesce(a,'xnone') c from t order by id;" \
  "coalesce int+int+text        @@select coalesce(a,b,s) c from t order by id;" \
  "coalesce text+int            @@select coalesce(s,a) c from t order by id;" \
  "coalesce numeric+text        @@select coalesce(n,s) c from t order by id;" \
  "case int/text                @@select case when id=1 then a else s end c from t order by id;" \
  "decode int/text              @@select decode(id,1,a,s) c from t order by id;" \
  "iif int/text                 @@select iif(id=1,a,s) c from t order by id;" \
  "concat text and int          @@select s||id c from t order by id;" \
  "concat int and int           @@select a||b c from t where id=1;" \
  "concat text and numeric      @@select s||n c from t order by id;" \
  "pure numeric coalesce        @@select coalesce(a,b) c from t order by id;" ; do
  label=${spec%%@@*}; q=${spec#*@@}
  both_val "$label" "$q"
  both_desc "$label" "$q"
done

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS condtext" || echo "FAIL condtext"
exit $fail
