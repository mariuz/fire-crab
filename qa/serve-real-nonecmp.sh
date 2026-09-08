#!/bin/bash
# A REAL-CHARSET TEXT COLUMN COMPARED TO A BYTE-CARRIER LITERAL COMPARES
# IN BYTE SPACE, so a matching row is not silently dropped.
#
# isql's default attachment is effectively NONE, so a text literal
# arrives as one char per octet: `'café'` is five carrier octets, not
# four Unicode chars. The engine compares a NONE/OCTETS operand against
# a real-charset column by reading the carrier's OCTETS as the column's
# charset (byte space), so `WHERE u = 'café'` MATCHES a UTF8 column -
# and, crucially, it NEVER validates or raises: `WHERE u = x'…FF'`
# (bytes that do not spell UTF-8) is simply 0 rows, where the same bytes
# through a CAST are 22000. fire-crab used to compare the carrier chars
# against the column's real chars and return 0 rows - a qualifying row
# silently vanished, and every operator (=, <>, <, >, BETWEEN, IN) was
# affected.
#
# The fix reinterprets the literal once at prepare (`decode_text` of the
# carrier octets in the column's charset); a bad-byte literal stays a
# carrier string that equals no real value - the engine's no-match /
# no-raise. Held against the live engine under the NONE attachment
# (truth) and, as a regression guard, under UTF8 and WIN1252.
#
# Usage: qa/serve-real-nonecmp.sh [port]   (default 4143)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4143}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nonecmp-eng.fdb"; FC="$D/nonecmp-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/nonecmp-build.log 2>&1 <<'SQL'
create table t (id int, u varchar(20) character set utf8, w varchar(20) character set win1252);
commit;
insert into t values (1,'café','café');
insert into t values (2,'abc','abc');
insert into t values (3,'niño','niño');
insert into t values (4,'Zürich','Zürich');
commit;
SQL
if grep -qi error /tmp/nonecmp-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/nonecmp-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nonecmp.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the rows/value, or REFUSE, under an optional client charset ($4)
sig() { local ch="" ; [ -n "${4:-}" ] && ch="-ch $4"; local r; \
    r=$(printf 'set list on;\n%s\n' "$3" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|malformed\|error'; then echo "REFUSE"; \
    else printf '%s' "$r" | grep -iE '^(N|ID) ' | tr -d ' \n'; fi; }
agree() { # <label> <sql> [client-charset]
    local e f
    e=$(sig "127.0.0.1/3050:$ENG" x "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" x "$2" "${3:-}")
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

echo "-- NONE attachment (default): the byte-space comparison --"
agree "u = 'café'"          "select count(*) n from t where u='café';"
agree "u = 'niño'"          "select count(*) n from t where u='niño';"
agree "u = 'Zürich'"        "select count(*) n from t where u='Zürich';"
agree "u = 'abc' (ascii)"   "select count(*) n from t where u='abc';"
agree "u <> 'café'"         "select count(*) n from t where u<>'café';"
agree "u > 'café'"          "select count(*) n from t where u>'café';"
agree "u <= 'café'"         "select count(*) n from t where u<='café';"
agree "u BETWEEN"           "select count(*) n from t where u between 'café' and 'niño';"
agree "u IN (café,abc)"     "select count(*) n from t where u in ('café','abc');"
agree "ids where u='café'"  "select id from t where u='café';"
agree "w = 'café' (win1252)" "select count(*) n from t where w='café';"
echo "-- the no-raise inversion: bad bytes are 0 rows, never an error --"
agree "u = x'636166FF'"     "select count(*) n from t where u=x'636166FF';"
agree "u = x'FF'"           "select count(*) n from t where u=x'FF';"
echo "-- regression: real attachments must be unchanged --"
agree "u='café' @UTF8"      "select count(*) n from t where u='café';" UTF8
agree "u='abc' @UTF8"       "select count(*) n from t where u='abc';" UTF8
agree "w='café' @WIN1252"   "select count(*) n from t where w='café';" WIN1252
agree "u ordering @UTF8"    "select id from t where u>'café' order by id;" UTF8

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS nonecmp" || echo "FAIL nonecmp"
exit $fail
