#!/bin/bash
# A DECIMAL RESULT IS DESCRIBED AS DECIMAL - NOT MIS-READ AS TEXT UNDER A
# REAL-CHARSET ATTACHMENT (WHICH MADE THE ROW UN-FETCHABLE).
#
# fire-crab ran its text-charset resolver (`resolve_text_cs`) over every
# non-BLOB column at describe time. A numeric's `sub_type` is not a
# charset ttype - for NUMERIC it is 1, for DECIMAL it is 2 - and the
# resolver's "plain column of a real charset" branch read that 2 as a
# charset id (charset_id(2)=2), so under a real-charset attachment it
# rewrote the DECIMAL slot to (att.id, characters x bytes-per-char):
# DECIMAL(9,2) under UTF8 became sqltype LONG subtype 4 len 16 instead
# of subtype 2 len 4. The value bytes stayed the native width, so the
# CLIENT then failed the fetch with a message-length error (expected 6,
# encountered 18) - the row could not be read at all. NUMERIC (subtype
# 1) escaped because charset_id(1)=1 is not a real charset, and a NONE
# attachment escaped because att.id is 0 - which is why isql's default
# (NONE) attach never exposed it.
#
# The fix runs the text resolver ONLY for text wires (CHAR/VARCHAR);
# every numeric, temporal, boolean, DECFLOAT and BLOB keeps its own
# sub_type and length. Held against the live engine for DECIMAL of each
# backing (LONG/INT64/INT128) as a column, a CAST, arithmetic, negation
# and a SUM, under UTF8, WIN1252 and NONE - and, as the regression
# guard, real-charset CHAR/VARCHAR columns and text expressions must
# still resolve to the attachment charset.
#
# Usage: qa/serve-real-decdesc.sh [port]   (default 4149)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4149}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/decdesc-eng.fdb"; FC="$D/decdesc-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/decdesc-build.log 2>&1 <<'SQL'
create table t(
  n2 numeric(9,2),
  d1 decimal(4,2), d2 decimal(9,2), d3 decimal(18,2), d4 decimal(19,2), d5 decimal(38,2),
  u varchar(6) character set utf8, w varchar(6) character set win1252, c char(3) character set utf8);
commit;
insert into t values (12.34, 1.23, 12.34, 12.34, 12.34, 12.34, 'abc', 'abc', 'xy');
commit;
SQL
if grep -qi error /tmp/decdesc-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/decdesc-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-decdesc.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# the full SQLDA line AND the value row (or the fetch error) together -
# a wrong describe len shows up as a message-length error on the row
sig() { local ch=""; [ -n "${3:-}" ] && ch="-ch $3"; \
    printf 'set list on;\nset sqlda_display on;\n%s\n' "$2" \
    | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -iE 'sqltype|message length|^X |^[DNUWC][0-9]? ' | sed 's/  */ /g'; }
agree() { # <label> <sql> [charset]
    local e f
    e=$(sig "127.0.0.1/3050:$ENG" "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" "$2" "${3:-}")
    if [ "$e" = "$f" ]; then echo "OK   [${3:-NONE}] $1"; else echo "FAIL [${3:-NONE}] $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi
}

echo "-- the bug: DECIMAL columns describe subtype 2 + native len, and FETCH, under UTF8 --"
agree "decimal(4,2) col"   "select d1 from t;" UTF8
agree "decimal(9,2) col"   "select d2 from t;" UTF8
agree "decimal(18,2) col"  "select d3 from t;" UTF8
agree "decimal(19,2) col"  "select d4 from t;" UTF8
agree "decimal(38,2) col"  "select d5 from t;" UTF8
echo "-- every shape that inherits a DECIMAL type --"
agree "cast decimal(9,2)"  "select cast(12.34 as decimal(9,2)) x from t;" UTF8
agree "cast decimal(19,4)" "select cast(12.34 as decimal(19,4)) x from t;" UTF8
agree "decimal arith d2+d2" "select d2+d2 x from t;" UTF8
agree "decimal negate -d2" "select -d2 x from t;" UTF8
agree "sum(decimal(18,2))" "select sum(d3) x from t;" UTF8
echo "-- other attachments --"
agree "decimal(9,2) @WIN1252"  "select d2 from t;" WIN1252
agree "decimal(18,2) @WIN1252" "select d3 from t;" WIN1252
agree "decimal(9,2) @NONE"     "select d2 from t;" ""
echo "-- controls: NUMERIC (subtype 1) unchanged --"
agree "numeric(9,2) @UTF8"     "select n2 from t;" UTF8
agree "numeric arith @UTF8"    "select n2+n2 x from t;" UTF8
echo "-- regression: real-charset text still resolves to the attachment charset --"
agree "utf8 varchar col @UTF8"    "select u from t;" UTF8
agree "win1252 varchar col @UTF8" "select w from t;" UTF8
agree "utf8 char col @WIN1252"    "select c from t;" WIN1252
agree "win1252 col @NONE"         "select w from t;" ""
agree "upper(u) expr @UTF8"       "select upper(u) x from t;" UTF8
agree "cast varchar(5) @UTF8"     "select cast('ab' as varchar(5)) x from t;" UTF8

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS decdesc" || echo "FAIL decdesc"
exit $fail
