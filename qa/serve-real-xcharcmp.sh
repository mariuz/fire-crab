#!/bin/bash
# CROSS-CHARSET TEXT COMPARISON IN BYTE SPACE for the EXPRESSION-path
# operand shapes - a text BLOB, a hex literal, an OCTETS/NONE column, a
# column-vs-column pair - and the byte-space PATTERN operators.
#
# The engine reconciles a byte-carrier (NONE/OCTETS/hex, or a literal
# under a byte-carrier attachment) meeting a real charset by comparing
# OCTETS: the real operand re-spelled as the carrier of its OWN charset
# bytes, the carrier operand verbatim, no transliteration and no raise.
# The literal fast path already did this; this extends it to the
# operands that reach the expression comparison path, plus the NONE
# column that a double-`to_carrier` lift had corrupted:
#
#   * a NONE column vs a literal (`n = 'café'`) - the double-lift is gone
#   * a text BLOB vs a literal / another column (`b = 'café'`, `u = b`)
#   * a hex literal (`u = x'636166C3A9'`), valid bytes match, bad bytes
#     are 0 rows with NO error (a CAST of the same bytes would raise)
#   * an OCTETS column vs a real literal under a real attachment
#   * column vs column across charsets (`u = o`, `u = n`)
#   * STARTING WITH / CONTAINING / SIMILAR TO of a real text COLUMN with
#     a carrier pattern - all ANSWER (LIKE, whose engine behavior SPLITS
#     raise/answer, and the blob pattern operators are a recorded gap).
#
# Real-vs-real pairs (`u = w`) are untouched. Held against the live
# engine under NONE (truth) and UTF8 (regression).
#
# Usage: qa/serve-real-xcharcmp.sh [port]   (default 4145)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4145}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/xcharcmp-eng.fdb"; FC="$D/xcharcmp-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/xcharcmp-build.log 2>&1 <<'SQL'
create table t (id int, u varchar(20) character set utf8, w varchar(20) character set win1252,
                o char(8) character set octets, n char(8) character set none, b blob sub_type text character set utf8);
commit;
insert into t values (1,'café','café',x'636166C3A9',x'636166C3A9','café');
insert into t values (2,'abc','abc',x'616263',x'616263','abc');
insert into t values (3,'niño','niño',x'6E69C3B16F',x'6E69C3B16F','niño');
insert into t values (4,'Zürich','Zürich',x'5AC3BC72696368',x'5AC3BC72696368','Zürich');
commit;
SQL
if grep -qi error /tmp/xcharcmp-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/xcharcmp-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-xcharcmp.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { local ch=""; [ -n "${4:-}" ] && ch="-ch $4"; local r; \
    r=$(printf 'set list on;\n%s\n' "$3" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|malformed\|error'; then echo "REFUSE"; \
    else printf '%s' "$r" | grep -iE '^(N|ID) ' | tr -d ' \n'; fi; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" x "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" x "$2" "${3:-}"); \
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi; }

echo "-- NONE column vs literal (double-lift gone), NONE attachment --"
agree "n = 'café'"          "select count(*) n from t where n='café';"
agree "n <> 'café'"         "select count(*) n from t where n<>'café';"
agree "n IN (café,abc)"     "select count(*) n from t where n in ('café','abc');"
echo "-- text BLOB vs literal / column, NONE attachment --"
agree "b = 'café'"          "select count(*) n from t where b='café';"
agree "b <> 'café'"         "select count(*) n from t where b<>'café';"
agree "b > 'café'"          "select count(*) n from t where b>'café';"
agree "b IN (café,abc)"     "select count(*) n from t where b in ('café','abc');"
agree "ids b = 'café'"      "select id from t where b='café';"
echo "-- hex literal, NONE attachment (bad bytes: 0 rows, no raise) --"
agree "u = x'636166C3A9'"   "select count(*) n from t where u=x'636166C3A9';"
agree "u = x'636166E9'"     "select count(*) n from t where u=x'636166E9';"
agree "u = x'636166FF'"     "select count(*) n from t where u=x'636166FF';"
agree "x'636166C3A9' = u"   "select count(*) n from t where x'636166C3A9'=u;"
echo "-- OCTETS column vs a REAL literal, UTF8 attachment --"
agree "o = 'café' @UTF8"    "select count(*) n from t where o='café';" UTF8
echo "-- column vs column across charsets --"
agree "u = o"               "select count(*) n from t where u=o;"
agree "u = n"               "select count(*) n from t where u=n;"
agree "u = b"               "select count(*) n from t where u=b;"
agree "u = w (real pair)"   "select count(*) n from t where u=w;"
agree "u = o @UTF8"         "select count(*) n from t where u=o;" UTF8
echo "-- pattern operators on a text column, NONE attachment --"
agree "u STARTING 'café'"   "select count(*) n from t where u starting with 'café';"
agree "u STARTING 'niño'"   "select count(*) n from t where u starting with 'niño';"
agree "u CONTAINING 'café'" "select count(*) n from t where u containing 'café';"
agree "u CONTAINING 'é'"    "select count(*) n from t where u containing 'é';"
agree "u SIMILAR 'café%'"   "select count(*) n from t where u similar to 'café%';"
agree "u SIMILAR '%é%'"     "select count(*) n from t where u similar to '%é%';"
echo "-- regression: real attachments unchanged --"
agree "b='café' @UTF8"      "select count(*) n from t where b='café';" UTF8
agree "u STARTING café @UTF8" "select count(*) n from t where u starting with 'café';" UTF8
agree "u=w @UTF8"           "select count(*) n from t where u=w;" UTF8

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS xcharcmp" || echo "FAIL xcharcmp"
exit $fail
