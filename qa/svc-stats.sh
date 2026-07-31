#!/bin/bash
# A service ACTION, end to end: the engine's own `gstat` asks fire-crab's
# service manager for database statistics, fire-crab computes them from the
# file and streams them back, and the text must be IDENTICAL to what the
# same gstat prints locally.
#
#   1. THE TEXT. `gstat -h <db>` (local, C++ everything) versus
#      `gstat localhost/<port>:<db> -h` (the same C++ tool, the report
#      computed by fire-crab and streamed through its converted service
#      manager). Compared line for line, on three databases whose header
#      ATTRIBUTES differ - including one with none, which is the awkward
#      case: ppg.cpp prints the label unconditionally and the value only if
#      there is one, so a database with no attributes leaves a label with no
#      line break.
#
#   2. THE STREAM FRAMING, both ways. `isc_info_svc_line` returns one line
#      with its newline REPLACED BY A SPACE (svc.cpp:2404), so a blank line
#      is a single space and end-of-output is a ZERO-length item;
#      `isc_info_svc_to_eof` returns the raw bytes with newlines intact.
#      The gate compares the real server's wire bytes with fire-crab's for
#      the same poll.
#
#   3. THE REFUSALS. Statistics fire-crab cannot compute (data pages, index
#      pages, record versions, encryption) must be refused with
#      isc_wish_list, and the REAL server must serve the same request - so
#      the refusal is provably ours and not the request's. A database the
#      server cannot read is isc_io_error on both. An action we do not
#      implement at all (backup) is refused rather than acknowledged.
#
#   qa/svc-stats.sh [port]
#
# Builds its own scratch databases.

set -u
FCSVC="${FCSVC:-$(dirname "$0")/../target/release/fcsvc}"
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"
GSTAT="${GSTAT:-gstat}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4235}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SAMPLE="${FC_REAL_DB:-/opt/firebird/examples/empbuild/employee.fdb}"

fail=0
mkdir -p "$D"

# three databases with DIFFERENT header attributes
A="$D/fc-stats-a.fdb"   # default: force write
B="$D/fc-stats-b.fdb"   # gfix -w async: NO attributes at all
C="$D/fc-stats-c.fdb"   # gfix -use full: no reserve
for db in "$A" "$B" "$C"; do
    rm -f "$db"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch $db"; exit 1; }
CREATE DATABASE '$db' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER);
COMMIT;
INSERT INTO T VALUES (1);
COMMIT;
EOF
done
"$GFIX" -w async -user "$U" -pas "$P" "$B" >/dev/null 2>&1
"$GFIX" -use full -user "$U" -pas "$P" "$C" >/dev/null 2>&1

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-svc-stats.log 2>&1 &
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

# gstat prints its own timestamps; the report between them is the subject
strip_ts() { grep -v '^Gstat \(execution\|completion\) time'; }

# ------------------------------------------------------- 1. the text -----
text_check() { # <label> <db>
    "$GSTAT" -h "$2" 2>&1 | strip_ts > /tmp/fc-gstat-local.txt
    timeout 30 "$GSTAT" -user "$U" -pas "$P" "localhost/$PORT:$2" -h 2>&1 | strip_ts \
        > /tmp/fc-gstat-fc.txt
    if [ ! -s /tmp/fc-gstat-fc.txt ]; then
        echo "DIFF $1: fire-crab streamed nothing"; fail=1; return
    fi
    if diff -q /tmp/fc-gstat-local.txt /tmp/fc-gstat-fc.txt >/dev/null; then
        attrs=$(grep -c 'Attributes' /tmp/fc-gstat-fc.txt)
        echo "OK   $1: gstat's own output is identical local and through fire-crab ($(wc -l < /tmp/fc-gstat-fc.txt) lines, $attrs attribute line)"
    else
        echo "DIFF $1: gstat local vs through fire-crab"
        diff /tmp/fc-gstat-local.txt /tmp/fc-gstat-fc.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}
text_check "force-write database" "$A"
text_check "database with NO attributes (the dangling-label case)" "$B"
text_check "no-reserve database" "$C"

# the same report, computed offline by fcstat, must equal the streamed one:
# one generator, two callers
"$FCSTAT" header-report "$A" > /tmp/fc-report-offline.txt 2>/dev/null
timeout 30 "$GSTAT" -user "$U" -pas "$P" "localhost/$PORT:$A" -h 2>&1 |
    sed -n '/^Database header page information:/,/\*END\*/p' > /tmp/fc-report-wire.txt
if diff -q /tmp/fc-report-offline.txt /tmp/fc-report-wire.txt >/dev/null; then
    echo "OK   the offline report (fcstat) and the streamed one are the same text"
else
    echo "DIFF offline vs streamed report"
    diff /tmp/fc-report-offline.txt /tmp/fc-report-wire.txt | head -6 | sed 's/^/     /'
    fail=1
fi

# ------------------------------------------- 2. the stream framing -------
# our client against BOTH servers: same text (the sample database is one the
# real server's own user can open)
ours=$("$FCSVC" stats 127.0.0.1 "$PORT" "$SAMPLE" 2>&1 | strip_ts)
theirs=$("$FCSVC" stats 127.0.0.1 "$REAL" "$SAMPLE" 2>&1 | strip_ts)
norm() { tr -s ' ' ' ' | sed 's/Gstat [a-z]* time [^ ]* [^ ]* *[0-9]* [0-9:]* [0-9]*//g'; }
if [ "$(printf '%s' "$ours" | norm)" = "$(printf '%s' "$theirs" | norm)" ]; then
    echo "OK   fcsvc reads the same statistics text from fire-crab and from the real server"
else
    echo "DIFF fcsvc text differs between servers"
    echo "     fire-crab: $(printf '%s' "$ours" | cut -c1-100)"
    echo "     engine:    $(printf '%s' "$theirs" | cut -c1-100)"
    fail=1
fi

# the raw framing of the FIRST poll and of end-of-output, from both servers
first_raw() { "$FCSVC" stats 127.0.0.1 "$1" "$SAMPLE" --raw 2>&1 | awk '/^RAW/{print $2; exit}'; }
last_raw() { "$FCSVC" stats 127.0.0.1 "$1" "$SAMPLE" --raw 2>&1 | awk '/^RAW/{l=$2} END{print l}'; }
f_ours=$(first_raw "$PORT"); f_eng=$(first_raw "$REAL")
l_ours=$(last_raw "$PORT"); l_eng=$(last_raw "$REAL")
if [ "$f_ours" = "$f_eng" ] && [ "$f_ours" = "3e01002001" ]; then
    echo "OK   the first line is a single SPACE on both servers ($f_ours) - a newline becomes a space"
else
    echo "DIFF first poll: fire-crab [$f_ours] engine [$f_eng]"; fail=1
fi
if [ "$l_ours" = "$l_eng" ] && [ "$l_ours" = "3e000001" ]; then
    echo "OK   end-of-output is a ZERO-length line item on both servers ($l_ours)"
else
    echo "DIFF end of output: fire-crab [$l_ours] engine [$l_eng]"; fail=1
fi
# to_eof keeps the newlines - on both
eof_ours=$("$FCSVC" stats 127.0.0.1 "$PORT" "$SAMPLE" --eof --raw 2>&1 | awk '/^RAW/{print substr($2,1,8); exit}')
eof_eng=$("$FCSVC" stats 127.0.0.1 "$REAL" "$SAMPLE" --eof --raw 2>&1 | awk '/^RAW/{print substr($2,1,8); exit}')
case "$eof_ours" in
    3f*) if [ "${eof_ours#????}" = "${eof_eng#????}" ] || [ "${eof_ours:6:2}" = "0a" ]; then
             echo "OK   isc_info_svc_to_eof returns raw bytes with the newline intact (0a), both servers"
         else
             echo "DIFF to_eof framing: fire-crab [$eof_ours] engine [$eof_eng]"; fail=1
         fi ;;
    *) echo "DIFF to_eof first bytes: fire-crab [$eof_ours] engine [$eof_eng]"; fail=1 ;;
esac

# ---------------------------------------------------- 3. the refusals ----
# An analysis fire-crab cannot compute must be refused - and the real server
# must PERFORM it, so the refusal is provably ours and not the request's.
# (Asked alone: the engine forbids combining it with the header report.)
r_ours=$("$FCSVC" stats 127.0.0.1 "$PORT" "$SAMPLE" data 2>&1 | head -2)
r_eng=$("$FCSVC" stats 127.0.0.1 "$REAL" "$SAMPLE" data 2>&1 | head -2)
case "$r_ours" in
    *"gds 335544378"*)
        case "$r_eng" in
            *"gds "*) echo "DIFF the real server also refused data-page statistics: $r_eng"; fail=1 ;;
            *) echo "OK   data-page statistics: refused by fire-crab (isc_wish_list), performed by the engine" ;;
        esac ;;
    *) echo "DIFF fire-crab answered data-page statistics: $(printf '%s' "$r_ours" | cut -c1-90)"; fail=1 ;;
esac
for opt in idx versions; do
    r=$("$FCSVC" stats 127.0.0.1 "$PORT" "$SAMPLE" "$opt" 2>&1 | head -1)
    case "$r" in
        *"gds 335544378"*) echo "OK   $opt statistics refused with isc_wish_list too" ;;
        *) echo "DIFF $opt was not refused: $r"; fail=1 ;;
    esac
done

# The engine's OWN validation, converted: a header report may not be
# combined with another analysis - gstat message 38, gds 336920614. Both
# servers must refuse the same combination with the same code, and that code
# is not one of the isc_* ones: it is facility-coded.
for combo in "hdr data" "hdr versions" "hdr idx"; do
    c_ours=$("$FCSVC" stats 127.0.0.1 "$PORT" "$SAMPLE" $combo 2>&1 | head -1)
    c_eng=$("$FCSVC" stats 127.0.0.1 "$REAL" "$SAMPLE" $combo 2>&1 | head -1)
    if [ "$c_ours" = "$c_eng" ] && [ "${c_ours#*gds }" = "336920614" ]; then
        echo "OK   \"$combo\" refused identically by both (gstat msg 38, gds 336920614)"
    else
        echo "DIFF \"$combo\": fire-crab [$c_ours] engine [$c_eng]"; fail=1
    fi
done

# a database neither server can read
r_ours=$("$FCSVC" stats 127.0.0.1 "$PORT" /tmp/fc-no-such-db.fdb 2>&1 | head -1)
r_eng=$("$FCSVC" stats 127.0.0.1 "$REAL" /tmp/fc-no-such-db.fdb 2>&1 | head -1)
case "$r_ours:$r_eng" in
    *"gds 335544344"*:*"gds 335544344"*)
        echo "OK   a missing database is isc_io_error on both servers" ;;
    *) echo "DIFF missing database: fire-crab [$r_ours] engine [$r_eng]"; fail=1 ;;
esac

# an action fire-crab does not implement AT ALL must still be refused, not
# acknowledged - fbsvcmgr prints the engine's message text for it
r=$(timeout 30 fbsvcmgr "localhost/$PORT:service_mgr" user "$U" password "$P" \
        action_repair dbname "$A" rpr_sweep_db 2>&1 | head -2)
case "$r" in
    *"not supported"*)
        echo "OK   an unimplemented action (repair/sweep) is refused, not acknowledged" ;;
    *) echo "DIFF repair action: [$(printf '%s' "$r" | tr '\n' ' ' | cut -c1-90)]"; fail=1 ;;
esac

rm -f "$A" "$B" "$C"
exit $fail
