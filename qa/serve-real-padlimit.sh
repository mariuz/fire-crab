#!/bin/bash
# LPAD / RPAD ENFORCE FIREBIRD'S VARCHAR-RESULT BYTE LIMIT.
#
# An LPAD/RPAD result is a VARCHAR whose declared byte width is the pad
# length N times the SOURCE charset's bytes-per-character. When that
# exceeds 65535 the engine raises SQLSTATE 54000 "Implementation limit
# exceeded" AT PREPARE - even wrapped in CHAR_LENGTH (which otherwise
# consumes the string). fire-crab built the over-long string and
# answered a confident value with the wrong cardinality (1 row where the
# engine errors). The boundary is charset-exact:
#   NONE / single-byte source : N <= 65535 answers, N >= 65536 raises
#   UTF8 (4 bytes/char)        : N <= 16383 answers, N >= 16384 raises
# Fixed by refusing the LPAD/RPAD when a literal N makes N x bytes/char
# exceed 65535, so the refusal propagates through any enclosing
# expression. Held against the live engine; a "raise" row asserts BOTH
# servers refuse (fire-crab's class may differ from 54000, but it must
# not silently answer).
#
# Usage: qa/serve-real-padlimit.sh [port]   (default 4152)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4152}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/padlimit.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set UTF8;" \
    | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-padlimit.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"; fail=0
# a value, or the word RAISE
sig() { local ch=""; [ -n "$3" ] && ch="-ch $3"; local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "RAISE"; else printf '%s' "$r" | grep -iE '^C ' | tr -d ' \n' | sed 's/^C//'; fi; }
agree() { local ch="${4:-}"; local e f; e=$(sig "$E" "$2" "$ch"); f=$(sig "$F" "$2" "$ch"); \
    [ "$e" = "$f" ] && echo "OK   $1 [$e]" || { echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }

echo "-- NONE attachment (1 byte/char): cap N = 65535 --"
agree "N=65535 answers"  "select char_length(lpad('Hi',65535,'*')) c from rdb\$database;" x ""
agree "N=65536 raises"   "select char_length(lpad('Hi',65536,'*')) c from rdb\$database;" x ""
agree "RPAD N=65536 raises" "select char_length(rpad('Hi',65536,'*')) c from rdb\$database;" x ""
echo "-- UTF8 attachment (4 bytes/char): cap N = 16383 --"
agree "N=16383 answers"  "select char_length(lpad('Hi',16383,'*')) c from rdb\$database;" x UTF8
agree "N=16384 raises"   "select char_length(lpad('Hi',16384,'*')) c from rdb\$database;" x UTF8
agree "N=40000 raises"   "select char_length(lpad('Hi',40000,'*')) c from rdb\$database;" x UTF8
agree "direct (not wrapped) raises" "select octet_length(lpad('Hi',40000,'*')) c from rdb\$database;" x UTF8
echo "-- controls: ordinary pads unchanged --"
agree "LPAD 10 (2-arg)"  "select char_length(lpad('Hi',10)) c from rdb\$database;" x UTF8
agree "LPAD 10 '*'"      "select char_length(lpad('Hi',10,'*')) c from rdb\$database;" x UTF8
agree "RPAD 8000"        "select char_length(rpad('Hi',8000,'x')) c from rdb\$database;" x UTF8
agree "LPAD 65535 NONE"  "select char_length(lpad('Hi',65535,'*')) c from rdb\$database;" x ""

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS padlimit" || echo "FAIL padlimit"
exit $fail
