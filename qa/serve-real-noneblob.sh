#!/bin/bash
# A LITERAL ASSIGNED TO A TEXT BLOB MOVES BY THE CHARSET ASSIGNMENT
# MATRIX - A NONE COLUMN KEEPS THE RAW OCTETS, NOT A DOUBLE-ENCODING.
#
# The engine moves a literal into a text blob the way it moves it into a
# VARCHAR: a BYTE COPY whenever either the attachment or the column is a
# byte carrier (NONE/OCTETS), a real transcode only when BOTH are real
# charsets. So 'café' (5 octets on the wire) into a NONE text blob stays
# 5 octets under any attachment; UTF8 -> WIN1252 collapses é to one byte
# (4), WIN1252 -> UTF8 widens it (7).
#
# fire-crab encoded the literal in the COLUMN's charset directly, which
# double-encoded a NONE column: INSERT 'café' stored 7 octets
# (63 61 66 C3 83 C2 A9) where the engine stores 5 (63 61 66 C3 A9) -
# durable corruption a later read could never recover. It also described
# a NONE text blob's charset as the attachment's (4/UTF8) instead of the
# column's 0/NONE. Both are the same defect - echoing the connection
# charset instead of honoring the assignment matrix - and both are
# fixed: a byte carrier on either side is a byte copy (write) / keeps the
# stored charset (describe). Held against the live engine across the
# NONE / UTF8 / WIN1252 attachment x column-charset matrix, for the
# stored octets AND the described charset, with the real-transcode and
# binary-blob cases as controls.
#
# Usage: qa/serve-real-noneblob.sh [port]   (default 4152)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4152}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/noneblob-eng.fdb"; FC="$D/noneblob-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/noneblob-build.log 2>&1 <<'SQL'
create table bn(id int, t blob sub_type text);
create table bu(id int, t blob sub_type text character set utf8);
create table bw(id int, t blob sub_type text character set win1252);
create table bin(id int, b blob sub_type binary);
commit;
SQL
if grep -qi error /tmp/noneblob-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/noneblob-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-noneblob.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
run() { "$ISQL" -q ${3:+-ch $3} -user "$U" -pas "$P" "$1" >/dev/null 2>&1 <<< "$2"; }
val() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^(O|H) ' | tr -d ' \n'; }
csof() { printf 'set sqlda_display on;\n%s\n' "$3" | "$ISQL" -q ${4:+-ch $4} -user "$U" -pas "$P" "$1" 2>&1 | grep -oiE 'charset: [0-9]+' | head -1; }

# write-then-read: same DML on both, compare stored octets+hex
wrote() { # <label> <insert-sql> <read-sql> [attach]
    run "127.0.0.1/3050:$ENG" "$2" "${4:-}"; run "127.0.0.1/$PORT:$FC" "$2" "${4:-}"
    local e f; e=$(val "127.0.0.1/3050:$ENG" "$3"); f=$(val "127.0.0.1/$PORT:$FC" "$3")
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=$e fc=$f"; fail=1; fi
}
descr() { # <label> <select> [attach]
    local e f; e=$(csof "127.0.0.1/3050:$ENG" x "$2" "${3:-}"); f=$(csof "127.0.0.1/$PORT:$FC" x "$2" "${3:-}")
    if [ "$e" = "$f" ]; then echo "OK   describe $1 [$e]"; else echo "FAIL describe $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

echo "-- the bug: 'café' into a NONE text blob keeps 5 raw octets, any attach --"
wrote "NONE-attach -> NONE col" "insert into bn values (1,'café');" "select octet_length(t) o, cast(t as varchar(20) character set octets) h from bn where id=1;"
wrote "UTF8-attach -> NONE col" "insert into bn values (2,'café');" "select octet_length(t) o, cast(t as varchar(20) character set octets) h from bn where id=2;" UTF8
wrote "WIN1252-attach -> NONE col" "insert into bn values (3,'café');" "select octet_length(t) o, cast(t as varchar(20) character set octets) h from bn where id=3;" WIN1252
wrote "UPDATE a NONE blob" "update bn set t='niño' where id=1;" "select octet_length(t) o, cast(t as varchar(20) character set octets) h from bn where id=1;"
echo "-- controls: a real->real move IS transcoded --"
wrote "UTF8-attach -> WIN1252 col (4)" "insert into bw values (1,'café');" "select octet_length(t) o, cast(t as varchar(20) character set octets) h from bw where id=1;" UTF8
wrote "WIN1252-attach -> UTF8 col (7)" "insert into bu values (1,'café');" "select octet_length(t) o, cast(t as varchar(20) character set octets) h from bu where id=1;" WIN1252
wrote "UTF8-attach -> UTF8 col (5)" "insert into bu values (2,'café');" "select octet_length(t) o, cast(t as varchar(20) character set octets) h from bu where id=2;" UTF8
echo "-- controls: binary blob + ascii unchanged --"
wrote "binary blob raw" "insert into bin values (1,'café');" "select octet_length(b) o, cast(b as varchar(20) character set octets) h from bin where id=1;"
wrote "ascii into NONE col" "insert into bn values (9,'hello');" "select octet_length(t) o from bn where id=9;"
echo "-- describe: a NONE text blob is charset 0 under any attach; real blobs echo a real attach --"
descr "NONE col @NONE"    "select t from bn;"
descr "NONE col @UTF8"    "select t from bn;" UTF8
descr "NONE col @WIN1252" "select t from bn;" WIN1252
descr "UTF8 col @NONE"    "select t from bu;"
descr "UTF8 col @WIN1252" "select t from bu;" WIN1252
descr "WIN1252 col @UTF8" "select t from bw;" UTF8

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS noneblob" || echo "FAIL noneblob"
exit $fail
