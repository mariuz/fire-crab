#!/bin/bash
# THE AUTH TAIL: the wire-crypt plugins ChaCha64 / ChaCha / Arc4 (the
# server announces its offer and a server-generated IV per ChaCha
# variant in the accept keys; the client picks the first of ITS list the
# server named; the key is SHA-256 of the SRP session key, the IV the
# plugin's specific data - src/plugins/crypt/chacha/ChaCha.cpp), wire
# COMPRESSION (pflag_compress on the protocol, echoed on the accept; one
# zlib stream each way below the encryption, sync-flushed per packet -
# this side inflates and sends stored blocks), and Legacy_Auth (the
# client's DES crypt of the password under "9z", verified through the C
# library's crypt; no session key, so the wire stays clear).
#
# A default libfbclient (WireCryptPlugin = ChaCha64, ChaCha, Arc4) now
# talks ChaCha64 to fire-crab, as it does to the engine: every other
# gate runs over it. Here each variant is forced in turn - the server
# narrowed with FC_WIRE_CRYPT, the client with a firebird.conf of its own
# (FIREBIRD=<dir>) - and the answers compared with the engine's where the
# engine takes the same client (it does not take a Legacy_Auth one: its
# AuthServer is Srp256 - recorded; nor does it compress: WireCompression
# is off in its firebird.conf - the client still answers, uncompressed).
#
#   qa/serve-real-wirecrypt.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4863}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-wirecrypt-engine.fdb"; DBF="$D/fc-wirecrypt-crab.fdb"
fail=0; ran=0
mkdir -p "$D"
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<SQL >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(40));
COMMIT;
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INTEGER = 1; BEGIN WHILE (I <= 2000) DO BEGIN INSERT INTO T VALUES (:I, 'row ' || :I || ' of the compressible kind'); I = I + 1; END END^
SET TERM ;^
COMMIT;
SQL
}
rm -f "$DBE" "$DBF"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
# client configurations
for c in default arc4 zlib legacy; do mkdir -p "$D/wc-cli-$c"; done
: > "$D/wc-cli-default/firebird.conf"
printf 'WireCryptPlugin = Arc4\n' > "$D/wc-cli-arc4/firebird.conf"
printf 'WireCompression = true\n' > "$D/wc-cli-zlib/firebird.conf"
printf 'AuthClient = Legacy_Auth\nWireCrypt = Enabled\n' > "$D/wc-cli-legacy/firebird.conf"
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
Q='SET HEADING OFF; SELECT COUNT(*), SUM(ID), MAX(V) FROM T; SELECT V FROM T WHERE ID = 1234; INSERT INTO T VALUES (9001, '"'"'over the wire'"'"'); SELECT V FROM T WHERE ID = 9001; ROLLBACK;'
run() { # <conf-dir or -> <conn>
    local conf="$1"; shift
    if [ "$conf" = "-" ]; then printf '%s\n' "$Q" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1; else
        FIREBIRD="$conf" printf '%s\n' "$Q" | FIREBIRD="$conf" timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1; fi | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g' | grep -v '^$\|firebird.msg' | tr '\n' '|'; }
start() { # <env...>
    LOG="/tmp/fc-serve-wirecrypt-$PORT.log"
    env "$@" FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
    srv=$!
    i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
    kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
}
stop() { kill $srv 2>/dev/null; wait $srv 2>/dev/null; }
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
ENG=$(run - "127.0.0.1/$REAL:$DBE")

# 1. the default client: ChaCha64 on both servers
start FC_UNUSED=1
check "default client: the rows over ChaCha64 [$ENG]" "$(run - "127.0.0.1/$PORT:$DBF")" "$ENG"
check "...the server traced ChaCha64" "$(grep -c 'op_crypt plugin=ChaCha64' "$LOG")" "1"
# 2. a client that speaks Arc4 only
check "an Arc4-only client" "$(run "$D/wc-cli-arc4" "127.0.0.1/$PORT:$DBF")" "$ENG"
check "...the server traced Arc4" "$(grep -c 'op_crypt plugin=Arc4' "$LOG")" "1"
# 3. compression: the client asks, the server grants, the rows come inflated
check "a compressing client (engine side uncompressed: WireCompression off there)" "$(run "$D/wc-cli-zlib" "127.0.0.1/$PORT:$DBF")" "$ENG"
check "...the server traced compress=true" "$(grep -c 'compress=true' "$LOG")" "1"
# 4. Legacy_Auth: the engine refuses such a client (AuthServer = Srp256); fc takes it
LEG=$(run "$D/wc-cli-legacy" "127.0.0.1/$PORT:$DBF")
check "a Legacy_Auth client (recorded: the engine's AuthServer has no Legacy_Auth)" "$LEG" "$ENG"
check "...the server traced the legacy credential" "$(grep -c 'Legacy_Auth: authenticated' "$LOG")" "1"
BAD=$(printf 'SELECT 1 FROM RDB$DATABASE;\n' | FIREBIRD="$D/wc-cli-legacy" timeout 20 "$ISQL" -q -user "$U" -pas wrong "127.0.0.1/$PORT:$DBF" 2>&1 | grep -o "Your user name and password are not defined" | head -1)
check "...a wrong Legacy password is isc_login" "$BAD" "Your user name and password are not defined"
stop
# 5. the server narrowed to ChaCha (16-byte IV) and to Arc4
start FC_WIRE_CRYPT=ChaCha
check "server offers ChaCha only: the default client takes it" "$(run - "127.0.0.1/$PORT:$DBF")" "$ENG"
check "...traced ChaCha" "$(grep -c 'op_crypt plugin=ChaCha ' "$LOG")" "1"
stop
start FC_WIRE_CRYPT=Arc4
check "server offers Arc4 only" "$(run - "127.0.0.1/$PORT:$DBF")" "$ENG"
check "...traced Arc4" "$(grep -c 'op_crypt plugin=Arc4' "$LOG")" "1"
stop
start FC_WIRE_COMPRESS=0
check "server declines compression: the client still answers" "$(run "$D/wc-cli-zlib" "127.0.0.1/$PORT:$DBF")" "$ENG"
check "...traced compress=false" "$(grep -c 'compress=false' "$LOG")" "1"
stop
echo "ran $ran checks"
exit $fail
