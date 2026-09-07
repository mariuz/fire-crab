#!/bin/bash
# A SELECTABLE PROCEDURE OR FUNCTION PRESENTS AN OLD-FORMAT RECORD THROUGH
# THE FORMAT THAT DESCRIBES IT (the F1 defect).
#
# The PSQL execution path (crates/exe) read every record at the NEWEST
# format's descriptors, so a row written before an ALTER came back through
# a procedure or function with the wrong scale, its fields at the wrong
# offsets, or a NULL where a later DEFAULT belongs - while a plain client
# SELECT over the same file, which decodes each record under its own
# format, read it right. The divergence is body-shape dependent: a body
# `exe` can carry (a bare FOR SELECT ... INTO, a scalar subquery) hit the
# wrong path; one it declines fell back to the source interpreter and was
# right. So the fixtures use exactly the shapes `exe` carries.
#
# Built BY THE ENGINE and copied byte-identically to both servers; the
# procedures and the function are read through the engine and through
# fire-crab and must agree. Three ALTERs, each a different loss the
# newest-descriptors-only decode caused:
#   JX  - ALTER N TYPE NUMERIC(9,2) after INTEGER rows: SCALE
#   OFS - ALTER A TYPE BIGINT after INTEGER rows: OFFSETS (the old image is
#         shorter than the new extent; both fields came back 0)
#   ADF - ADD DFT INTEGER DEFAULT 99 NOT NULL after rows: the DEFAULT
#         SECTION (a NULL in a NOT NULL column)
#
# Usage: qa/serve-real-procfmt.sh [port]   (default 4133)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4133}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/procfmt-eng.fdb"; FC="$D/procfmt-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }

BUILD=$(mktemp "$D/procfmt-build.XXXXXX.sql")
cat > "$BUILD" <<'SQL'
create table jx (id integer, n integer);
commit;
insert into jx values (1,700);
insert into jx values (2,7);
commit;
alter table jx alter n type numeric(9,2);
commit;
insert into jx values (3,7.00);
commit;
set term ^;
create procedure pjx returns (o numeric(9,2)) as begin for select n from jx order by id into :o do suspend; end^
create function fn2 (k integer) returns numeric(9,2) as begin return (select n from jx where id = :k); end^
set term ;^
commit;
create table ofs (a integer, b integer);
commit;
insert into ofs values (11,22);
commit;
alter table ofs alter a type bigint;
commit;
insert into ofs values (33,44);
commit;
set term ^;
create procedure pof returns (x bigint, y integer) as begin for select a, b from ofs order by a into :x, :y do suspend; end^
set term ;^
commit;
create table adf (id integer, val integer);
commit;
insert into adf values (1,7);
commit;
alter table adf add dft integer default 99 not null;
commit;
insert into adf (id, val, dft) values (2,8,5);
commit;
set term ^;
create procedure padf returns (i integer, dd integer) as begin for select id, dft from adf order by id into :i, :dd do suspend; end^
set term ;^
commit;
SQL
"$ISQL" -q -user "$U" -pas "$P" -i "$BUILD" "127.0.0.1/3050:$ENG" >/tmp/procfmt-build.log 2>&1
if grep -qi "error" /tmp/procfmt-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/procfmt-build.log; exit 1; fi
rm -f "$BUILD"
cp "$ENG" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-procfmt.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
Q=$(mktemp "$D/procfmt-q.XXXXXX.sql")
cat > "$Q" <<'SQL'
select o from pjx;
select x, y from pof;
select i, dd from padf;
select fn2(1) a, fn2(2) b from rdb$database;
SQL
one() { # <label> <isql query file> <server db>
    "$ISQL" -q -user "$U" -pas "$P" -i "$2" "$3" 2>&1 | sed 's/[[:space:]]*$//'
}
a=$(one x "$Q" "127.0.0.1/3050:$ENG")
b=$(one x "$Q" "127.0.0.1/$PORT:$FC")
if [ "$a" = "$b" ]; then
    echo "OK   a selectable procedure and function present old-format rows as the engine does"
else
    echo "FAIL the procedure/function reads diverge"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20 | sed 's/^/     /'; fail=1
fi
rm -f "$Q"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS procfmt" || echo "FAIL procfmt"
exit $fail
