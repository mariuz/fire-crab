#!/bin/bash
# `gfix -sweep`: THE WRITE HALF OF GARBAGE COLLECTION.
#
# `crates/ods/src/gc.rs` predicted for a year what the engine's sweep
# would remove (qa/diff-sweep.sh holds that prediction); this gate holds
# the other half - fire-crab PERFORMING the sweep on its own file, with
# the engine as the reader of record afterwards.
#
# THE DESIGN: each server builds THE SAME HISTORY through ITSELF on its
# own file - committed updates (a back chain), a rolled-back insert, a
# rolled-back update, a committed delete - and then sweeps its own file
# with `gfix -sweep`. The BEFORE version counts legitimately differ
# (the engine backs a rollback out at ROLLBACK time through its undo
# log, so its garbage is smaller; fire-crab's rollback is two TIP bits
# and all its garbage waits for the sweep) - the AFTER counts must be
# EQUAL, and the rows must read identically THROUGH THE ENGINE.
#
# Laws measured before writing the converted sweep, and held here:
#   * versions collapse to the live count; rows unchanged;
#   * the TIP's DEAD ENTRIES STAY DEAD - a sweep advances
#     `hdr_oldest_transaction` PAST them, it does not rewrite history;
#   * on fire-crab's side OIT = OAT = OST = next afterwards (the engine
#     lands OAT/OST at next too; its OIT sits just below, on its own
#     sweep transaction - fire-crab burns no id);
#   * a sweep on a READ-ONLY database refuses with the engine's own
#     pair: "Unable to run sweep / -Database in read only state";
#   * an ACTIVE transaction someone still HOLDS is not touched - its
#     uncommitted row survives the sweep and commits afterwards.
#
# RECORDED BOUNDARY: a relation whose pages carry BLOB records is left
# whole (freeing a version without freeing its blobs leaks them; the
# blob walk is its own slice). The engine collects those too, so the
# blob table's version count is asserted to DIFFER after the sweeps.
#
#   qa/serve-real-gfixsweep.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GSTAT="${GSTAT:-gstat}"
PORT="${1:-4717}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-gfixsweep-engine.fdb"
DBF="$D/fc-gfixsweep-crab.fdb"
LOG="/tmp/fc-serve-gfixsweep-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

build() { # <path>
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, S BLOB SUB_TYPE TEXT);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
INSERT INTO B VALUES (1, 'blob one');
COMMIT;
UPDATE B SET S = 'blob two' WHERE ID = 1;
COMMIT;
UPDATE B SET S = 'blob three' WHERE ID = 1;
COMMIT;
EOF
}
# The BLOB garbage is built through the ENGINE on both files, before any
# server holds them: the gate wants IDENTICAL histories on the two files
# (fcwire does take a blob UPDATE now - qa/serve-real-blobupdate.sh -
# but a history written by two servers is not the same history).
rm -f "$DBE" "$DBF"
build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D"/fc-gfixsweep*.fifo' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

ECONN="127.0.0.1/$REAL:$DBE"
FCONN="127.0.0.1/$PORT:$DBF"

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1 [$2]"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
run_on() { # <conn> <sql>
    printf '%s\n' "$2" | timeout 30 "$ISQL" -q -b -user "$U" -pas "$P" "$1" >/dev/null 2>&1
}
relid() { # <file> <name>
    printf 'SET HEADING OFF;\nSELECT RDB$RELATION_ID FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = %s;\n' "'$2'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d ' \n'
}
history() { # <conn> - the same garbage on both sides
    run_on "$1" "UPDATE T SET V = 21 WHERE ID = 2;
COMMIT;
UPDATE T SET V = 22 WHERE ID = 2;
COMMIT;"
    run_on "$1" "SET AUTODDL OFF;
INSERT INTO T VALUES (3, 30);
ROLLBACK;"
    run_on "$1" "SET AUTODDL OFF;
UPDATE T SET V = 99 WHERE ID = 1;
ROLLBACK;"
    run_on "$1" "INSERT INTO T VALUES (4, 40);
COMMIT;
DELETE FROM T WHERE ID = 4;
COMMIT;"
}
history "$ECONN"
history "$FCONN"

relT=$(relid "$DBE" T); relB=$(relid "$DBE" B)
# relation ids are the same on both files (identical DDL order)
et_before=$("$FCSTAT" versions "$DBE" "$relT"); ft_before=$("$FCSTAT" versions "$DBF" "$relT")
echo "note before the sweeps: T versions engine=$et_before fc=$ft_before (differ by design - the engine backs rollbacks out through its undo log at ROLLBACK time)"

# rc must be captured from GFIX, not from the tr behind the pipe
sweep_on() { # <conn> -> "output|rc=N"
    local out rc
    out=$("$GFIX" -sweep -user "$U" -pas "$P" "$1" 2>&1); rc=$?
    printf '%s|rc=%s' "$(printf '%s' "$out" | tr '\n' '|')" "$rc"
}

# --- 1. each server sweeps its own file ------------------------------------
check "gfix -sweep answers the same on both" "$(sweep_on "$FCONN")" "$(sweep_on "$ECONN")"

# --- 1a. THE HEADER LAW, read OFFLINE and read FIRST: any engine attach to
# the file after this (isql reading rows below) starts transactions of its
# own and moves OAT/OST/next - the law is the SWEEP's postcondition, not a
# permanent state of the file.
hdr() { "$GSTAT" -h -user "$U" -pas "$P" "$1" 2>&1 | sed -n "s/^[[:space:]]*$2[[:space:]]*//p"; }
ran=$((ran + 1))
oit=$(hdr "$DBF" "Oldest transaction"); nxt=$(hdr "$DBF" "Next transaction")
oat=$(hdr "$DBF" "Oldest active"); ost=$(hdr "$DBF" "Oldest snapshot")
if [ "$oit" = "$nxt" ] && [ "$oat" = "$nxt" ] && [ "$ost" = "$nxt" ]; then
    echo "OK   fc header law: OIT = OAT = OST = next ($nxt)"
else
    echo "DIFF fc header after sweep: OIT=$oit OAT=$oat OST=$ost next=$nxt"; fail=1
fi

# --- 2. the swept files agree ------------------------------------------------
check "T's versions collapse to the same count" \
    "$("$FCSTAT" versions "$DBF" "$relT")" "$("$FCSTAT" versions "$DBE" "$relT")"
rows() { printf 'SET HEADING OFF;\nSELECT ID, V FROM T ORDER BY ID;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '; }
check "the ENGINE reads the same rows from both swept files" "$(rows "$DBF")" "$(rows "$DBE")"
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1 | tr -d ' \n')
if [ -z "$v" ]; then echo "OK   gfix -v -full accepts fire-crab's swept file"
else echo "DIFF gfix -v -full: [$v]"; fail=1; fi

# --- 3. the TIP keeps its history, the header moves past it ----------------
dead() { "$FCSTAT" tip "$1" 2>/dev/null | sed -n 's/^[[:space:]]*dead[[:space:]]*//p'; }
ran=$((ran + 1))
fd=$(dead "$DBF")
if [ "$fd" -ge 2 ] 2>/dev/null; then
    echo "OK   the dead TIP entries STAY dead on fire-crab's file ($fd)"
else
    echo "DIFF dead TIP entries: [$fd] - a sweep must not rewrite history"; fail=1
fi
# --- 4. RECORDED BOUNDARY: the blob table is left whole ---------------------
eb=$("$FCSTAT" versions "$DBE" "$relB"); fb=$("$FCSTAT" versions "$DBF" "$relB")
ran=$((ran + 1))
if [ "$fb" -gt "$eb" ] 2>/dev/null; then
    echo "OK   boundary: the blob relation is left whole (engine $eb, fc $fb)"
else
    echo "DIFF boundary MOVED: blob relation versions engine=$eb fc=$fb"
    echo "     (if fire-crab collects blobs now, this check must become an equality)"
    fail=1
fi
# ...but its ROWS are correct on both
brows() { printf 'SET HEADING OFF;\nSELECT b.ID, CAST(b.S AS VARCHAR(20)) FROM B b;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '; }
check "...and the blob table's rows read identically" "$(brows "$DBF")" "$(brows "$DBE")"

# --- 5. a HELD active transaction is not touched, on EITHER server ----------
held_survives() { # <conn>
    local fifo="$D/fc-gfixsweep.fifo"
    rm -f "$fifo"; mkfifo "$fifo"
    ( timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" <"$fifo" >/dev/null 2>&1 ) & local h=$!
    exec 8>"$fifo"
    printf 'SET AUTODDL OFF;\nINSERT INTO T VALUES (5, 50);\n' >&8; sleep 2
    "$GFIX" -sweep -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    { printf 'COMMIT;\nQUIT;\n' >&8; } 2>/dev/null; exec 8>&- 2>/dev/null; wait $h 2>/dev/null; rm -f "$fifo"
    printf 'SET HEADING OFF;\nSELECT V FROM T WHERE ID = 5;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d ' \n'
}
check "ENGINE: an open transaction's row survives its sweep" "$(held_survives "$ECONN")" "50"
check "fc: an open transaction's row survives its sweep" "$(held_survives "$FCONN")" "50"

# --- 6. a sweep on a READ-ONLY database refuses with the engine's pair ------
"$GFIX" -mode read_only -user "$U" -pas "$P" "$ECONN" >/dev/null 2>&1
"$GFIX" -mode read_only -user "$U" -pas "$P" "$FCONN" >/dev/null 2>&1
check "sweep on a read-only database" "$(sweep_on "$FCONN")" "$(sweep_on "$ECONN")"
"$GFIX" -mode read_write -user "$U" -pas "$P" "$ECONN" >/dev/null 2>&1
"$GFIX" -mode read_write -user "$U" -pas "$P" "$FCONN" >/dev/null 2>&1

# --- 7. TEETH: a second sweep finds nothing, and work goes on ---------------
before2=$("$FCSTAT" versions "$DBF" "$relT")
"$GFIX" -sweep -user "$U" -pas "$P" "$FCONN" >/dev/null 2>&1
check "a second sweep is a no-op" "$("$FCSTAT" versions "$DBF" "$relT")" "$before2"
got=$(printf 'INSERT INTO T VALUES (6, 60);\nCOMMIT;\nSET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$FCONN" 2>&1 | tr -d ' \n')
eng=$(printf 'INSERT INTO T VALUES (6, 60);\nCOMMIT;\nSET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$ECONN" 2>&1 | tr -d ' \n')
check "teeth: ordinary work after the sweep" "$got" "$eng"

echo "ran $ran checks"
exit $fail
