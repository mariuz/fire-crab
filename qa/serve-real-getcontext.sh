#!/bin/bash
# RDB$GET_CONTEXT('SYSTEM', key): THE DETERMINISTIC KEYS ANSWER, AN
# UNKNOWN KEY RAISES, AND A VALID-BUT-DEFERRED KEY IS NULL - NOT NULL
# FOR EVERYTHING.
#
# fire-crab answered only six SYSTEM keys and returned NULL for every
# other - including ones with a fixed value the engine always gives
# (EFFECTIVE_USER=SYSDBA, CURRENT_ROLE=NONE, LOCK_TIMEOUT=-1,
# READ_ONLY=FALSE, SESSION_IDLE_TIMEOUT/STATEMENT_TIMEOUT=0,
# WIRE_COMPRESSED=FALSE, DECFLOAT_ROUND=HALF_UP, the EXT_CONN_POOL
# defaults) - and it returned NULL for a genuinely UNKNOWN key where the
# engine RAISES (isc_ctx_var_not_found, SQLSTATE HY000).
#
# The keys whose value is unconditionally fire-crab's own truth (a
# single SYSDBA login, no role, no timeouts, no wire compression, the
# DECFLOAT / ext-conn-pool defaults, a read/write default transaction)
# now match the engine exactly. An unknown key raises the engine's own
# message. A key that is VALID but bound to this connection/transaction/
# database (DB_NAME, SESSION_ID, TRANSACTION_ID, CLIENT_*, WIRE_ENCRYPTED,
# DB_GUID, ...) answers NULL rather than raise or fabricate a value - a
# recorded divergence pending a session/tx thread-local. RDB$SET_CONTEXT
# / GET of USER_SESSION was already correct and is a regression control.
#
# Usage: qa/serve-real-getcontext.sh [port]   (default 4153)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4153}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/getcontext-eng.fdb"; FC="$D/getcontext-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-getcontext.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# a SYSTEM key's value, or RAISE:<message-tail>, or <NULL>
getctx() { local r; r=$(printf "set list on;\nselect coalesce(rdb\$get_context('SYSTEM','%s'),'<NULL>') r from rdb\$database;\n" "$2" \
    | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1); \
    if printf '%s' "$r" | grep -qiE 'SQLSTATE|not found|error|failed'; then \
        printf 'RAISE:%s' "$(printf '%s' "$r" | grep -iE 'not found in namespace' | sed 's/^ *//' | head -1)"; \
    else printf '%s' "$r" | grep -iE '^R ' | sed 's/^R//;s/^ *//' | head -1; fi; }

matches() { # <key> : deterministic - eng and fc must agree
    local e f; e=$(getctx "127.0.0.1/3050:$ENG" "$1"); f=$(getctx "127.0.0.1/$PORT:$FC" "$1")
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}
fc_null() { # <key> : valid-but-deferred - fc must be NULL (not raise), engine returns a value
    local f; f=$(getctx "127.0.0.1/$PORT:$FC" "$1")
    if [ "$f" = "<NULL>" ]; then echo "OK   $1 fc=NULL (valid, deferred)"; else echo "FAIL $1 fc=[$f] (want NULL, not raise/value)"; fail=1; fi
}

echo "-- deterministic keys: fc now matches the engine --"
for k in ENGINE_VERSION CURRENT_USER EFFECTIVE_USER CURRENT_ROLE NETWORK_PROTOCOL \
         ISOLATION_LEVEL LOCK_TIMEOUT READ_ONLY SESSION_IDLE_TIMEOUT STATEMENT_TIMEOUT \
         WIRE_COMPRESSED DECFLOAT_ROUND DECFLOAT_TRAPS SEARCH_PATH CURRENT_SCHEMA \
         EXT_CONN_POOL_SIZE EXT_CONN_POOL_LIFETIME EXT_CONN_POOL_IDLE_COUNT EXT_CONN_POOL_ACTIVE_COUNT; do
    matches "$k"
done
echo "-- an unknown SYSTEM key RAISES the engine's own message (both) --"
for k in DATABASE_NAME REPLICA GDS_VERSION FOOBAR NOPE; do
    matches "$k"
done
echo "-- valid-but-deferred keys: fc answers NULL (honest), never a raise --"
for k in REPLICA_MODE DB_NAME SESSION_ID TRANSACTION_ID CLIENT_ADDRESS CLIENT_HOST \
         CLIENT_PID CLIENT_PROCESS WIRE_ENCRYPTED WIRE_CRYPT_PLUGIN DB_FILE_ID DB_GUID \
         SNAPSHOT_NUMBER GLOBAL_CN; do
    fc_null "$k"
done
echo "-- REPLICA_MODE is a VALID key: NULL on BOTH, must not raise --"
matches "REPLICA_MODE"
echo "-- SET/GET USER_SESSION round-trip (regression) --"
gs() { printf "set list on;\n%s\n" "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^(S|G) ' | tr -d ' \n'; }
SQL="select rdb\$set_context('USER_SESSION','v','42') s from rdb\$database;
select rdb\$get_context('USER_SESSION','v') g from rdb\$database;
select rdb\$set_context('USER_SESSION','v','99') s from rdb\$database;
select rdb\$get_context('USER_SESSION','missing') g from rdb\$database;"
e=$(gs "127.0.0.1/3050:$ENG" "$SQL"); f=$(gs "127.0.0.1/$PORT:$FC" "$SQL")
[ "$e" = "$f" ] && echo "OK   SET/GET round-trip [$f]" || { echo "FAIL SET/GET eng=[$e] fc=[$f]"; fail=1; }
echo "-- SQL keyword regression (not GET_CONTEXT) --"
kw() { printf "set list on;\nselect current_user u, current_role r from rdb\$database;\n" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^(U|R) ' | tr -d ' \n'; }
e=$(kw "127.0.0.1/3050:$ENG"); f=$(kw "127.0.0.1/$PORT:$FC")
[ "$e" = "$f" ] && echo "OK   CURRENT_USER/ROLE keywords [$f]" || { echo "FAIL keywords eng=[$e] fc=[$f]"; fail=1; }

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS getcontext" || echo "FAIL getcontext"
exit $fail
