#!/bin/bash
# The Services manager, differentially tested in BOTH directions with the
# engine's own tool in the loop:
#
#   1. OUR DECODER vs THE ENGINE'S CLIENT, same real server. fcsvc asks
#      the live service manager for the same items fbsvcmgr asks for, and
#      the decoded values must be identical. Any item whose SHAPE we get
#      wrong (string where the engine writes a bare 4-byte number, or the
#      reverse) misreads the rest of the buffer, so agreement on a
#      multi-item request is a strong statement about the grammar.
#
#   2. THE ENGINE'S CLIENT vs OUR SERVER. `fbsvcmgr` - a C++ tool with the
#      engine's own decoder - attaches to fcwire's service manager and
#      prints its answers, including the isc_info_svc_svr_db_info CLUSTER
#      (bare tag, two numerics, dbnames, isc_info_flag_end). Nothing of
#      fire-crab's is in the reading path.
#
#   3. THE TRUNCATION BOUNDARY, measured on the live engine. INF_put_item
#      tests `ptr + length + 4 >= end`, so an answer of n bytes needs
#      n + 5 of buffer and the last byte is never written. The gate asks
#      the real server with n+4 and n+5 and requires truncated / whole -
#      then requires fire-crab's encoder to break at the same place.
#
#   4. THE GRAMMARS, from bytes captured in this run. fbsvcmgr's real
#      attach SPB and query buffers are traced off fcwire and fed back to
#      `fcsvc parse`, so the byte pins are re-derived rather than trusted.
#
#   5. THE ACTION REFUSAL. A service ACTION (backup, sweep, stats) is a
#      request to DO something. fire-crab runs none, so it must refuse:
#      the same action must succeed against the real server and fail
#      against ours. An empty success would be a backup that never
#      happened.
#
#   qa/svc-info.sh [port]
#
# Needs the live server on 3050 and fbsvcmgr on PATH.

set -u
FCSVC="${FCSVC:-$(dirname "$0")/../target/release/fcsvc}"
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FBSVCMGR="${FBSVCMGR:-fbsvcmgr}"
PORT="${1:-4538}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
# a database the SERVER's own user can open (files under /tmp/fbhandson
# belong to the developer, and the real server cannot read them)
REALDB="${FC_REAL_DB:-/opt/firebird/examples/empbuild/employee.fdb}"
TRACE=/tmp/fc-svc-gate.log

command -v "$FBSVCMGR" >/dev/null 2>&1 || { echo "SKIP fbsvcmgr not found"; exit 0; }
fail=0

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$TRACE" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

svcmgr() { # <port> <args...>
    p="$1"; shift
    timeout 30 "$FBSVCMGR" "localhost/$p:service_mgr" user "$U" password "$P" "$@" 2>&1
}
val() { awk -v k="$1" '$1 == k {$1=""; sub(/^ /,""); print}'; }

# ------------------------------------- 1. our decoder vs fbsvcmgr's ------
eng=$(svcmgr "$REAL" -info_server_version -info_implementation -info_get_env \
                     -info_get_env_lock -info_user_dbpath)
ours=$("$FCSVC" info 127.0.0.1 "$REAL" server_version implementation get_env \
                                       get_env_lock user_dbpath 2>&1)
check_pair() { # <label> <fbsvcmgr-prefix> <fcsvc-item>
    e=$(printf '%s\n' "$eng" | sed -n "s/^$2: //p")
    o=$(printf '%s\n' "$ours" | val "$3")
    if [ -n "$e" ] && [ "$e" = "$o" ]; then
        echo "OK   $1 decoded identically by fbsvcmgr and fcsvc ($o)"
    else
        echo "DIFF $1: fbsvcmgr [$e] fcsvc [$o]"; fail=1
    fi
}
check_pair "server version"  "Server version"        server_version
check_pair "implementation"  "Server implementation" implementation
check_pair "server root"     "Server root"           get_env
check_pair "lock directory"  "Path to lock files"    get_env_lock
check_pair "security db"     "Security database"     user_dbpath

# the numeric items: shape, not just value - a string reading of
# isc_info_svc_version would consume the next item's bytes
n=$("$FCSVC" info 127.0.0.1 "$REAL" version running stdin 2>&1)
if [ "$(printf '%s\n' "$n" | val version)" = "2" ] &&
   [ "$(printf '%s\n' "$n" | val running)" = "0" ]; then
    echo "OK   numeric items decode as bare 4-byte values (version 2, running 0)"
else
    echo "DIFF numeric items: [$(printf '%s' "$n" | tr '\n' ' ')]"; fail=1
fi

# the CLUSTER, from the real server
c=$("$FCSVC" info 127.0.0.1 "$REAL" svr_db_info 2>&1)
eng=$(svcmgr "$REAL" -info_svr_db_info)
eng_att=$(printf '%s\n' "$eng" | sed -n 's/.*Number of attachments: //p')
our_att=$(printf '%s\n' "$c" | val num_att)
if [ "$(printf '%s\n' "$c" | head -1)" = "svr_db_info" ] &&
   [ "$(printf '%s\n' "$c" | tail -1)" = "flag_end" ] &&
   [ -n "$eng_att" ] && [ "$eng_att" = "$our_att" ]; then
    echo "OK   svr_db_info cluster: bare tag, numerics, flag_end; attachments $our_att = fbsvcmgr's"
else
    echo "DIFF cluster: fcsvc [$(printf '%s' "$c" | tr '\n' ' ')] fbsvcmgr att [$eng_att]"; fail=1
fi

# ------------------------------- 2. the engine's client vs our server ----
mine=$(svcmgr "$PORT" -info_server_version -info_implementation -info_get_env \
                      -info_get_env_lock -info_user_dbpath -info_svr_db_info)
case "$mine" in
    *"Server version:"*"Server implementation:"*"Number of databases:"*)
        echo "OK   fbsvcmgr reads fire-crab's service manager, cluster included"
        printf '%s\n' "$mine" | sed 's/^/     | /' ;;
    *) echo "DIFF fbsvcmgr against fire-crab: [$(printf '%s' "$mine" | tr '\n' ' ')]"; fail=1 ;;
esac
# and our own client agrees with fbsvcmgr about our own server
o=$("$FCSVC" info 127.0.0.1 "$PORT" server_version 2>&1 | val server_version)
e=$(printf '%s\n' "$mine" | sed -n 's/^Server version: //p')
if [ -n "$o" ] && [ "$o" = "$e" ]; then
    echo "OK   two independent decoders read fire-crab's answer the same way"
else
    echo "DIFF our server's version: fbsvcmgr [$e] fcsvc [$o]"; fail=1
fi

# --------------------------------- 3. the truncation boundary -----------
ver=$("$FCSVC" info 127.0.0.1 "$REAL" server_version 2>&1 | val server_version)
n=${#ver}
short=$("$FCSVC" info-buffer 127.0.0.1 "$REAL" $((n + 4)) server_version --raw 2>&1)
long=$("$FCSVC" info-buffer 127.0.0.1 "$REAL" $((n + 5)) server_version --raw 2>&1)
case "$short:$long" in
    0201*:37*)
        echo "OK   the ENGINE truncates a $n-byte answer at $((n + 4)) bytes and fits at $((n + 5))"
        echo "     (INF_put_item's test is >=, so the buffer's last byte is never used)" ;;
    *) echo "DIFF engine truncation: n=$n at n+4 [${short:0:8}] at n+5 [${long:0:8}]"; fail=1 ;;
esac
# fire-crab's own encoder, offline, on its own answer
own=$("$FCSVC" info 127.0.0.1 "$PORT" server_version 2>&1 | val server_version)
m=${#own}
os=$("$FCSVC" answer 37 $((m + 4)))
ol=$("$FCSVC" answer 37 $((m + 5)))
if [ "$os" = "0201" ] && [ "${ol:0:2}" = "37" ]; then
    echo "OK   fire-crab's encoder breaks at the same place (truncated at m+4, whole at m+5)"
else
    echo "DIFF fire-crab truncation: at m+4 [$os] at m+5 [${ol:0:8}]"; fail=1
fi
# and over the wire, through our server
ws=$("$FCSVC" info-buffer 127.0.0.1 "$PORT" $((m + 4)) server_version --raw 2>&1)
if [ "${ws:0:4}" = "0201" ]; then
    echo "OK   the same boundary holds over the wire (isc_info_truncated + isc_info_end)"
else
    echo "DIFF our server's truncation over the wire: [${ws:0:8}]"; fail=1
fi

# an item NEITHER implements: both must refuse, with the same code. The
# engine's query2 `default:` arm raises isc_wish_list (335544378) rather
# than skipping the item or answering a marker - so this is the one place
# where "not implemented" is itself a converted behaviour.
er=$("$FCSVC" info 127.0.0.1 "$REAL" get_license 2>&1)
em=$("$FCSVC" info 127.0.0.1 "$PORT" get_license 2>&1)
case "$er:$em" in
    *"gds 335544378"*:*"gds 335544378"*)
        echo "OK   an unimplemented item draws isc_wish_list from BOTH servers" ;;
    *) echo "DIFF get_license: real [$er] fire-crab [$em]"; fail=1 ;;
esac

# ------------------------------- 4. grammars, from this run's bytes -----
# pick the SPB whose process_name is fbsvcmgr ("fbsvcmgr" in hex): the
# trace also holds fcsvc's own attaches, and a gate that grabs the last
# one would be checking our bytes against our parser
spb=$(grep -o 'spb=[0-9a-f]*' "$TRACE" | grep 66627376636d6772 | tail -1 | cut -d= -f2)
if [ -z "$spb" ]; then
    echo "DIFF no attach SPB captured from fbsvcmgr"; fail=1
else
    p=$("$FCSVC" parse attach "$spb" 2>&1)
    if printf '%s\n' "$p" | grep -q "^VERSION 2$" &&
       printf '%s\n' "$p" | grep -q "user_name 6 SYSDBA" &&
       printf '%s\n' "$p" | grep -q "process_name .* /opt/firebird/bin/fbsvcmgr"; then
        echo "OK   fbsvcmgr's real attach SPB parses under the SpbAttach grammar"
        printf '%s\n' "$p" | sed 's/^/     | /'
    else
        echo "DIFF parsing fbsvcmgr's SPB: [$(printf '%s' "$p" | tr '\n' ' ')]"; fail=1
    fi
fi
# fire-crab's own attach SPB, as it arrived at the server and was traced:
# a round trip through the wire, re-parsed
mine_spb=$(grep -o 'spb=[0-9a-f]*' "$TRACE" | grep -v 66627376636d6772 | tail -1 | cut -d= -f2)
if [ -n "$mine_spb" ]; then
    mp=$("$FCSVC" parse attach "$mine_spb" 2>&1)
    if printf '%s\n' "$mp" | grep -q "client_version 9 fire-crab"; then
        echo "OK   fire-crab's own attach SPB survives the wire and re-parses"
    else
        echo "DIFF our own SPB: [$(printf '%s' "$mp" | tr '\n' ' ')]"; fail=1
    fi
fi
send=$(grep -o 'send=[0-9a-f]*' "$TRACE" | tail -1 | cut -d= -f2)
recv=$(grep -o 'recv=[0-9a-f]*' "$TRACE" | tail -1 | cut -d= -f2)
sp=$("$FCSVC" parse send "$send" 2>&1)
rp=$("$FCSVC" parse receive "$recv" 2>&1)
if printf '%s\n' "$sp" | grep -q "^64 tag_64 4 1 " && [ "$(printf '%s\n' "$rp" | wc -l)" -ge 1 ]; then
    echo "OK   the send buffer's 2-byte lengths and the receive buffer's bare tags both parse"
    echo "     send=$send recv=$recv"
else
    echo "DIFF send/recv grammars: send [$(printf '%s' "$sp" | tr '\n' ' ')] recv [$(printf '%s' "$rp" | tr '\n' ' ')]"
    fail=1
fi
# the teeth: reading a send buffer under the WRONG grammar must not
# silently produce plausible items
wrong=$("$FCSVC" parse attach "$send" 2>&1)
if [ "$(printf '%s\n' "$wrong" | head -1)" != "$(printf '%s\n' "$sp" | head -1)" ]; then
    echo "OK   the same bytes read under another grammar are NOT the same items"
else
    echo "DIFF the grammars are indistinguishable on this buffer"; fail=1
fi

# ------------------------------------------ 5. the action refusal -------
# ~~fire-crab refuses the action (isc_wish_list)~~ - STALE: the service
# manager RUNS db_stats now (qa/svc-stats.sh gates the report text line
# for line against local gstat), so this pin flips to the new truth:
# both servers ANSWER, with the same header-report shape
a=$(svcmgr "$PORT" action_db_stats dbname "$REALDB" sts_hdr_pages)
case "$a" in
    *"Database "*|*"Checksum"*|*"Generation"*)
        echo "OK   fire-crab RUNS a db_stats action (the svc-stats gate owns the text)" ;;
    *) echo "DIFF fire-crab's db_stats answer: [$(printf '%s' "$a" | tr '\n' ' ' | cut -c1-120)]"
       fail=1 ;;
esac
r=$(svcmgr "$REAL" action_db_stats dbname "$REALDB" sts_hdr_pages)
case "$r" in
    *"Database "*|*"Checksum"*|*"Generation"*)
        echo "OK   the real server answers the same action with the same report shape" ;;
    *) echo "DIFF the real server did not run db_stats: [$(printf '%s' "$r" | tr '\n' ' ' | cut -c1-120)]"
       fail=1 ;;
esac

exit $fail
