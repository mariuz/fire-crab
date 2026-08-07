#!/bin/bash
# `gfix -shut` / `-online`: THE MODE LADDER, THE WAIT, AND THE KICK.
#
# `hdr_shutdown_mode` is one byte at offset 25 (none 0, multi 1, single
# 2, full 3) - and as with the read-only bit, the byte is not the work.
# What had to be measured, and what this gate holds:
#
#   * THE LADDER IS STRICT IN BOTH DIRECTIONS: `-shut` must tighten
#     (none < multi < single < full), `-online` must loosen, and the
#     SAME mode again is REFUSED - although shut.cpp's `same_mode` reads
#     as if it silently succeeds ("gbak relies on that"), this build's
#     IGNORE_SAME_MODE is compiled false. The refusal is
#     `isc_bad_shutdown_mode` with the file QUOTED BY THE TEMPLATE.
#   * a bare `gfix -shut -force 0` (no mode word) is MULTI, and a bare
#     `gfix -online` is NORMAL - the latter arrives as mode bits 0x00
#     and is normalized at DPB-parse time (jrd.cpp:7187), not refused.
#   * FULL refuses every attach (`isc_shutdown` naming the file) -
#     including a non-mode gfix like `-buffers` - EXCEPT an attach
#     carrying `-shut`/`-online`, which is how the database ever comes
#     back. SINGLE allows ONE attachment: the second is refused with the
#     same vector, and even `gfix -online` is that second attach while
#     the slot is held (measured; the ladder never gets to run).
#   * the maintenance attachment can WRITE - single-user maintenance is
#     what gfix -sweep and gbak restore run under.
#   * THE FORCE KICK: `-shut <mode> -force 0` succeeds immediately with
#     attachments present, and each of their NEXT statements answers
#     SQLSTATE 08003, `connection shutdown` / `-Database is shutdown.`
#     (isc_att_shutdown + isc_att_shut_db_down) - measured on a held
#     isql. The kicked attachment no longer occupies the single slot.
#   * `-attach N` / `-tran N` with a stayer FAIL - "database shutdown
#     unsuccessful" (isc_shutfail) - and the header is UNTOUCHED.
#
# THE TWO SERVERS GET THEIR OWN DATABASE FILE (a shutdown is a property
# of the file), and every error that names the file is compared with the
# name normalized to <db>.
#
#   qa/serve-real-shutdown.sh [port]

set -u
# A KICKED isql exits, and a later write to its fifo would then kill THIS
# script with SIGPIPE (exactly what section 6 provokes on purpose). With
# the signal ignored the write fails with EPIPE instead, which the
# guarded printfs absorb.
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GSTAT="${GSTAT:-gstat}"
PORT="${1:-4716}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-shutdown-engine.fdb"
DBF="$D/fc-shutdown-crab.fdb"
LOG="/tmp/fc-serve-shutdown-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

build() { # <path>
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
COMMIT;
EOF
}
rm -f "$DBE" "$DBF"
build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D"/fc-shutdown*.fifo "$D"/fc-shutdown-held-*.txt' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

ECONN="127.0.0.1/$REAL:$DBE"
FCONN="127.0.0.1/$PORT:$DBF"

norm() { # <side: E|F> - normalize this side's own path
    if [ "$1" = E ]; then sed "s|$DBE|<db>|g"; else sed "s|$DBF|<db>|g"; fi
}
sql() { # <side> <conn> <sql>
    printf '%s\n' "$3" | timeout 30 "$ISQL" -q -b -user "$U" -pas "$P" "$2" 2>&1 |
        norm "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}
both() { # <label> <sql>
    local e c
    e=$(sql E "$ECONN" "$2"); c=$(sql F "$FCONN" "$2")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi
}
gfix_both() { # <switch...>
    local eo ec ro rc
    eo=$("$GFIX" "$@" -user "$U" -pas "$P" "$ECONN" 2>&1 | norm E | tr '\n' '|'); ro=$?
    ec=$("$GFIX" "$@" -user "$U" -pas "$P" "$FCONN" 2>&1 | norm F | tr '\n' '|'); rc=$?
    ran=$((ran + 1))
    if [ "$eo|rc=$ro" = "$ec|rc=$rc" ]; then
        echo "OK   gfix $* [rc=$ro] [$eo]"
    else
        echo "DIFF gfix $*"
        echo "     engine: rc=$ro [$eo]"
        echo "     fc:     rc=$rc [$ec]"
        fail=1
    fi
}
attrs_both() { # <label> - the header attributes, OFFLINE gstat as oracle
    local e c
    e=$("$GSTAT" -h -user "$U" -pas "$P" "$DBE" 2>&1 | sed -n 's/^[[:space:]]*Attributes[[:space:]]*//p')
    c=$("$GSTAT" -h -user "$U" -pas "$P" "$DBF" 2>&1 | sed -n 's/^[[:space:]]*Attributes[[:space:]]*//p')
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: [$e]"; echo "     fc:     [$c]"; fail=1; fi
}
# fifo-held attachments, one per side (fd 9 engine, fd 8 fire-crab)
hold_e() { rm -f "$D/fc-shutdown-e.fifo"; mkfifo "$D/fc-shutdown-e.fifo"
    ( timeout 90 "$ISQL" -q -user "$U" -pas "$P" "$ECONN" <"$D/fc-shutdown-e.fifo" >"$D/fc-shutdown-held-e.txt" 2>&1 ) & eh=$!
    exec 9>"$D/fc-shutdown-e.fifo"; printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' >&9; sleep 2; }
hold_f() { rm -f "$D/fc-shutdown-f.fifo"; mkfifo "$D/fc-shutdown-f.fifo"
    ( timeout 90 "$ISQL" -q -user "$U" -pas "$P" "$FCONN" <"$D/fc-shutdown-f.fifo" >"$D/fc-shutdown-held-f.txt" 2>&1 ) & fh=$!
    exec 8>"$D/fc-shutdown-f.fifo"; printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' >&8; sleep 2; }
unhold_e() { { printf 'QUIT;\n' >&9; } 2>/dev/null; exec 9>&- 2>/dev/null; wait $eh 2>/dev/null; rm -f "$D/fc-shutdown-e.fifo"; }
unhold_f() { { printf 'QUIT;\n' >&8; } 2>/dev/null; exec 8>&- 2>/dev/null; wait $fh 2>/dev/null; rm -f "$D/fc-shutdown-f.fifo"; }

# --- 1. THE LADDER, tightening -------------------------------------------
gfix_both -shut multi -force 0
attrs_both "...multi-user maintenance on both"
gfix_both -shut multi -force 0     # same mode: refused
gfix_both -shut single -force 0
attrs_both "...single-user maintenance on both"
gfix_both -shut multi -force 0     # backward: refused
gfix_both -shut full -force 0
attrs_both "...full shutdown on both"
gfix_both -shut full -force 0      # same mode: refused
gfix_both -shut single -force 0    # backward: refused

# --- 2. FULL: every attach refused, except the mode switches --------------
both "an attach under FULL is refused, naming the file" "SET HEADING OFF;
SELECT COUNT(*) FROM T;"
gfix_both -buffers 500             # a non-mode gfix attach: same refusal

# --- 3. THE LADDER, loosening ---------------------------------------------
gfix_both -online single
attrs_both "...back to single"
both "the maintenance attachment can SELECT" "SET HEADING OFF;
SELECT COUNT(*) FROM T;"
both "...and WRITE (maintenance is for writing)" "INSERT INTO T VALUES (2, 20);
COMMIT;
SET HEADING OFF;
SELECT COUNT(*) FROM T;"
gfix_both -online multi
attrs_both "...multi"
gfix_both -online single           # backward: refused
gfix_both -online                  # bare online = NORMAL
attrs_both "...and online again"
gfix_both -online                  # same mode: refused
gfix_both -online multi            # online cannot shut: refused

# --- 4. the legacy bare -shut is MULTI ------------------------------------
gfix_both -shut -force 0
attrs_both "a bare -shut -force 0 lands in multi"
gfix_both -online

# --- 5. SINGLE holds ONE attachment ---------------------------------------
gfix_both -shut single -force 0
hold_e; hold_f
both "a SECOND attach under SINGLE is refused" "SET HEADING OFF;
SELECT COUNT(*) FROM T;"
gfix_both -online                  # ...and -online IS a second attach
unhold_e; unhold_f
gfix_both -online
attrs_both "...online once the slot is free"

# --- 6. THE FORCE KICK ------------------------------------------------------
# Both servers: hold an attachment, force-shut, and compare what the HELD
# attachment's next statement answers - the vector is the check.
hold_e; hold_f
gfix_both -shut single -force 0
attrs_both "...the mode changed under the holders"
sleep 1
{ printf 'SELECT COUNT(*) FROM T;\n' >&9; } 2>/dev/null
{ printf 'SELECT COUNT(*) FROM T;\n' >&8; } 2>/dev/null
sleep 2
unhold_e; unhold_f
ran=$((ran + 1))
he=$(norm E <"$D/fc-shutdown-held-e.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|')
hf=$(norm F <"$D/fc-shutdown-held-f.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|')
if [ "$he" = "$hf" ]; then echo "OK   the kicked attachment's next statement [$he]"
else echo "DIFF the kicked attachment's next statement"; echo "     engine: $he"; echo "     fc:     $hf"; fail=1; fi
both "...and the kicked holder does not occupy the single slot" "SET HEADING OFF;
SELECT COUNT(*) FROM T;"
gfix_both -online

# --- 7. -attach N / -tran N with a stayer: shutfail, header untouched ------
hold_e; hold_f
gfix_both -shut single -attach 2
attrs_both "...the failed -attach wrote nothing"
{ printf 'SET AUTODDL OFF;\nINSERT INTO T VALUES (70, 1);\n' >&9; } 2>/dev/null
{ printf 'SET AUTODDL OFF;\nINSERT INTO T VALUES (70, 1);\n' >&8; } 2>/dev/null
sleep 1
gfix_both -shut single -tran 2
attrs_both "...the failed -tran wrote nothing either"
{ printf 'ROLLBACK;\n' >&9; } 2>/dev/null
{ printf 'ROLLBACK;\n' >&8; } 2>/dev/null
unhold_e; unhold_f

# --- 8. TEETH ---------------------------------------------------------------
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1 | tr -d ' \n')
if [ -z "$v" ]; then echo "OK   gfix -v -full accepts fire-crab's file"
else echo "DIFF gfix -v -full: [$v]"; fail=1; fi
both "teeth: ordinary work once online" "INSERT INTO T VALUES (3, 30);
COMMIT;
SET HEADING OFF;
SELECT COUNT(*) || '/' || SUM(V) FROM T;"

echo "ran $ran checks"
exit $fail
