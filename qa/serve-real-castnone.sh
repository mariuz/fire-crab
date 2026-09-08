#!/bin/bash
# AN UNQUALIFIED CAST TO A STRING UNDER A BYTE-CARRIER ATTACHMENT CARRIES
# THE SOURCE'S RAW BYTES.
#
# `CAST(x AS VARCHAR(n))` with no CHARACTER SET takes the ATTACHMENT's
# charset (measured: under a UTF8 attachment it describes charset 4;
# under NONE - isql's default - charset 0). A NONE result is a byte
# carrier, so the source's stored bytes travel untransliterated:
# `CAST(<utf8 'café'> AS VARCHAR(20))` is 5 octets and `char_length` 5,
# not the 4 real chars. fire-crab used to keep the decoded string and the
# row encoder's carrier path then dropped é to a single byte (4 octets).
# The fix moves the value into the attachment charset via the engine's
# CVT_move (real -> byte-carrier is a raw byte copy); a real attachment
# is left exactly as before (the row encoder already transliterates the
# decoded string into it). A CAST, unlike a comparison, DOES validate the
# other direction: a byte-carrier source into UTF8 whose bytes are not
# UTF-8 raises 22000.
#
# Held against the live engine: values, char/octet lengths, and describe.
#
# Usage: qa/serve-real-castnone.sh [port]   (default 4144)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4144}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/castnone-eng.fdb"; FC="$D/castnone-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/castnone-build.log 2>&1 <<'SQL'
create table t (id int, u varchar(20) character set utf8, w varchar(20) character set win1252,
                o char(6) character set octets, b blob sub_type text character set utf8);
commit;
insert into t values (1,'café','café',x'636166C3A9','café');
insert into t values (2,'中','中',x'414243','中');
commit;
SQL
if grep -qi error /tmp/castnone-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/castnone-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castnone.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { local ch="" ; [ -n "${4:-}" ] && ch="-ch $4"; local r; \
    r=$(printf 'set list on;\n%s\n' "$3" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|malformed\|error'; then echo "REFUSE"; \
    else printf '%s' "$r" | grep -iE '^(OL|CL|N) ' | tr -d ' \n'; fi; }
agree() { # <label> <sql> [client-charset]
    local e f
    e=$(sig "127.0.0.1/3050:$ENG" x "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" x "$2" "${3:-}")
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

echo "-- NONE attachment: raw-byte passthrough (char_length counts bytes) --"
agree "cast(u) café"        "select octet_length(cast(u as varchar(20))) ol, char_length(cast(u as varchar(20))) cl from t where id=1;"
agree "cast(b) café blob"   "select octet_length(cast(b as varchar(20))) ol, char_length(cast(b as varchar(20))) cl from t where id=1;"
agree "cast(w) café"        "select octet_length(cast(w as varchar(20))) ol, char_length(cast(w as varchar(20))) cl from t where id=1;"
agree "cast(u) 中 (3-byte)"  "select octet_length(cast(u as varchar(20))) ol, char_length(cast(u as varchar(20))) cl from t where id=2;"
agree "explicit NONE == bare" "select octet_length(cast(u as varchar(20) character set none)) ol, char_length(cast(u as varchar(20) character set none)) cl from t where id=1;"
agree "explicit UTF8 cast"   "select octet_length(cast(u as varchar(20) character set utf8)) ol, char_length(cast(u as varchar(20) character set utf8)) cl from t where id=1;"
echo "-- regression: real attachments unchanged --"
agree "cast(u) café @UTF8"   "select octet_length(cast(u as varchar(20))) ol, char_length(cast(u as varchar(20))) cl from t where id=1;" UTF8
agree "cast(w) café @WIN1252" "select octet_length(cast(w as varchar(20))) ol, char_length(cast(w as varchar(20))) cl from t where id=1;" WIN1252
echo "-- CAST validates carrier->real (raises) where comparison does not --"
agree "cast(o x'..C3A9' AS UTF8) ok" "select char_length(cast(o as varchar(6) character set utf8)) cl from t where id=1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS castnone" || echo "FAIL castnone"
exit $fail
