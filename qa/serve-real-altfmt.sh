#!/bin/bash
# A RECORD WRITTEN BEFORE AN ALTER IS PRESENTED THROUGH THE FORMAT THAT
# DESCRIBES IT NOW - the type/width/overflow cases (F2, F3, F4), beyond
# the scale case the wire read already handled.
#
# Built BY THE ENGINE and copied byte-identically to both servers; read
# through the engine and through fire-crab, they must agree.
#
#   DT  ALTER H TYPE TIMESTAMP after a DATE row (F3): the old row keeps
#       its day at midnight, not the epoch; EXTRACT parts agree.
#   CW  ALTER B TYPE CHAR(10) after a CHAR(4) row (F4): CHAR_LENGTH,
#       OCTET_LENGTH and concatenation see the WIDER declared width, not
#       the stored one (a bare SELECT already agreed - the wire pads to
#       the describe width - so the length functions are what pin it).
#   OV  ALTER N TYPE NUMERIC(18,4) after a BIGINT row holding 9e17 (F2):
#       the rescale overflows, and both raise 22003 numeric value is out
#       of range through a selectable procedure rather than answering a
#       wrong number.
#
# Usage: qa/serve-real-altfmt.sh [port]   (default 4134)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4134}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/altfmt-eng.fdb"; FC="$D/altfmt-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }

BUILD=$(mktemp "$D/altfmt-build.XXXXXX.sql")
cat > "$BUILD" <<'SQL'
create table dt (id integer, h date);
commit;
insert into dt values (1, date'2020-03-04');
commit;
alter table dt alter h type timestamp;
commit;
insert into dt values (2, timestamp'2021-05-06 01:02:03');
commit;
create table cw (id integer, b char(4));
commit;
insert into cw values (1, 'ab');
commit;
alter table cw alter b type char(10);
commit;
insert into cw values (2, 'wxyz');
commit;
create table ov (id integer, n bigint);
commit;
insert into ov values (1, 900000000000000000);
commit;
alter table ov alter n type numeric(18,4);
commit;
set term ^;
create procedure pov returns (o numeric(18,4)) as begin for select n from ov order by id into :o do suspend; end^
set term ;^
commit;
SQL
"$ISQL" -q -user "$U" -pas "$P" -i "$BUILD" "127.0.0.1/3050:$ENG" >/tmp/altfmt-build.log 2>&1
if grep -qi "error" /tmp/altfmt-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/altfmt-build.log; exit 1; fi
rm -f "$BUILD"
cp "$ENG" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-altfmt.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
Q=$(mktemp "$D/altfmt-q.XXXXXX.sql")
cat > "$Q" <<'SQL'
select id, h from dt order by id;
select id, extract(hour from h) hh, extract(year from h) yy from dt where id = 1;
select id, char_length(b) l, octet_length(b) o from cw order by id;
select id, char_length(b || 'X') l from cw order by id;
select o from pov;
SQL
# the engine tags the 22003 with the procedure's line/col; strip that so
# the SQLSTATE and message are what is compared, not the source position
clean() { "$ISQL" -q -user "$U" -pas "$P" -i "$Q" "$1" 2>&1 | sed 's/[[:space:]]*$//;/^-At procedure/d;/^After line/d'; }
a=$(clean "127.0.0.1/3050:$ENG")
b=$(clean "127.0.0.1/$PORT:$FC")
if [ "$a" = "$b" ]; then
    echo "OK   DATE->TIMESTAMP, CHAR widening and the rescale overflow present as the engine does"
else
    echo "FAIL the presentations diverge"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20 | sed 's/^/     /'; fail=1
fi
rm -f "$Q"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS altfmt" || echo "FAIL altfmt"
exit $fail
