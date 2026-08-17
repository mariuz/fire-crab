#!/bin/bash
# TWO-PHASE COMMIT and the LIMBO it leaves - `op_prepare2`, and what a
# database owes a transaction that died between its two phases.
#
# isql cannot speak 2PC, so the client here is qa/fb2pc.c compiled
# against libfbclient: start, write, PREPARE (op_prepare2 - the client
# always sends the message form), and exit WITHOUT resolving. The laws
# this gate holds, each measured against the live engine first:
#
#   * the prepared transaction SURVIVES the death of its process -
#     `gfix -list` names it, `isc_info_limbo` (16) answers one cluster
#     per id;
#   * a reader that MEETS a limbo record RAISES `isc_rec_in_limbo`
#     naming the transaction (SQLSTATE HY000) - the row is neither
#     there nor not-there until somebody resolves it; committed rows
#     BEFORE it in the scan still arrive;
#   * gbak dies on the same law rather than writing a backup that
#     silently lacks the unresolved rows;
#   * a statement under a PREPARED transaction refuses with "no
#     transaction for request", and the limbo survives the refusal;
#   * `isc_reconnect_transaction` + commit makes the rows real;
#     + rollback makes them vanish (gfix -commit/-rollback ride the
#     same two ops);
#   * reconnecting an id that is NOT in limbo answers the engine's own
#     pair: "transaction is not in limbo" + "transaction N is in an
#     ill-defined state".
#
# SKIPS (not fails) when no cc/libfbclient is available to build the rig.
#
#   qa/serve-real-limbo.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4724}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-limbo-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

RIG="$D/fc-fb2pc"
if ! cc -o "$RIG" "$(dirname "$0")/fb2pc.c" \
        -I/opt/firebird/include -L/opt/firebird/lib -lfbclient \
        -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "SKIP: cannot build the 2PC rig (cc/libfbclient missing)"
    exit 0
fi

mkdb() { # <path>
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T2PC (ID INTEGER, V VARCHAR(10));
CREATE TABLE TIX (ID INTEGER, V VARCHAR(10));
CREATE INDEX IX_TIX ON TIX (ID);
COMMIT;
INSERT INTO TIX VALUES (0, 'settled');
INSERT INTO T2PC VALUES (0, 'settled');
COMMIT;
EOF
    chmod 666 "$1"
}
EDB="$D/fc-limbo-e.fdb"
FDB="$D/fc-limbo-f.fdb"
mkdb "$EDB"; mkdb "$FDB"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB" "$RIG" "$D"/fc-limbo-*.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
E="localhost:$EDB"
F="127.0.0.1/$PORT:$FDB"

# --- 1. prepare, die, and be found --------------------------------------------
eout=$("$RIG" limbo "$E" 2>&1); eid=$(printf '%s' "$eout" | awk '/^transaction id/{print $3}')
fout=$("$RIG" limbo "$F" 2>&1); fid=$(printf '%s' "$fout" | awk '/^transaction id/{print $3}')
check "the rig prepares and exits unresolved on both" \
    "$(printf '%s' "$eout" | tail -1)/$(printf '%s' "$fout" | tail -1)" \
    "exiting unresolved/exiting unresolved"
check "gfix -list names the limbo transaction (engine)" \
    "$("$GFIX" -list -user "$U" -pas "$P" "$E" 2>&1)" "Transaction $eid is in limbo."
check "gfix -list names the limbo transaction (fire-crab)" \
    "$("$GFIX" -list -user "$U" -pas "$P" "$F" 2>&1)" "Transaction $fid is in limbo."
check "isc_info_limbo answers the id, one cluster" \
    "$("$RIG" info "$F" 2>&1)" "item 16 len 4 value $fid"

# --- 2. the reader's law -------------------------------------------------------
rd() { printf 'SET HEADING OFF;\nSELECT ID, V FROM T2PC;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '; }
check "a reader meeting the limbo row raises, settled rows first" \
    "$(rd "$F" | sed "s/transaction $fid/transaction N/")" \
    "$(rd "$E" | sed "s/transaction $eid/transaction N/")"
gb() { "$GBAK" -b -se localhost:service_mgr -user "$U" -pas "$P" "$1" "$D/fc-limbo-x.fbk" 2>&1 | head -1; }
gbf() { "$GBAK" -b -se "127.0.0.1/$PORT:service_mgr" -user "$U" -pas "$P" "$1" "$D/fc-limbo-x.fbk" 2>&1 | head -1; }
check "gbak dies on the limbo record too" \
    "$(gbf "$FDB" | sed "s/transaction $fid/transaction N/")" \
    "$(gb "$EDB" | sed "s/transaction $eid/transaction N/")"

# --- 3. a statement under a PREPARED transaction ------------------------------
check "a statement after prepare refuses, both servers" \
    "$("$RIG" stmt "$F" 2>&1 | tail -1)" "$("$RIG" stmt "$E" 2>&1 | tail -1)"
sid=$("$RIG" info "$F" 2>&1 | tail -1 | awk '{print $NF}')
"$RIG" resolve "$F" "$sid" r >/dev/null 2>&1 # clean up the stmt leftover
sid=$("$RIG" info "$E" 2>&1 | tail -1 | awk '{print $NF}')
"$RIG" resolve "$E" "$sid" r >/dev/null 2>&1

# --- 4. resolution -------------------------------------------------------------
check "reconnect + COMMIT makes the row real (fire-crab)" \
    "$("$RIG" resolve "$F" "$fid" c 2>&1)" "resolved $fid: committed"
check "reconnect + COMMIT makes the row real (engine)" \
    "$("$RIG" resolve "$E" "$eid" c 2>&1)" "resolved $eid: committed"
check "...and the committed rows now read identically" "$(rd "$F")" "$(rd "$E")"
# a second limbo, resolved the other way
"$RIG" limbo "$E" >/dev/null 2>&1; eid2=$("$RIG" info "$E" | tail -1 | awk '{print $NF}')
"$RIG" limbo "$F" >/dev/null 2>&1; fid2=$("$RIG" info "$F" | tail -1 | awk '{print $NF}')
check "gfix -rollback resolves through the same ops (fire-crab)" \
    "$("$GFIX" -rollback "$fid2" -user "$U" -pas "$P" "$F" 2>&1; echo "rc=$?")" \
    "$("$GFIX" -rollback "$eid2" -user "$U" -pas "$P" "$E" 2>&1; echo "rc=$?")"
check "...the rolled-back row is gone and the list is empty, both" \
    "$(rd "$F")|$("$GFIX" -list -user "$U" -pas "$P" "$F" 2>&1)" \
    "$(rd "$E")|$("$GFIX" -list -user "$U" -pas "$P" "$E" 2>&1)"

# --- 5. every reader meets the law: COUNT, aggregates, DML, the index ---------
# fresh limbo rows - one in the plain table, one in the INDEXED one
"$RIG" limbo "$E" >/dev/null 2>&1
"$RIG" limbo "$F" >/dev/null 2>&1
FB2PC_INSERT="INSERT INTO TIX (ID, V) VALUES (5, 'lp')" "$RIG" limbo "$E" >/dev/null 2>&1
FB2PC_INSERT="INSERT INTO TIX (ID, V) VALUES (5, 'lp')" "$RIG" limbo "$F" >/dev/null 2>&1
qn() { # <conn> <sql> - normalized (the ids differ per server)
    printf 'SET HEADING OFF;
%s
' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        tr -s ' 
' ' ' | sed 's/transaction [0-9]*/transaction N/'
}
for sql in 'SELECT COUNT(*) FROM T2PC;' 'SELECT MAX(ID) FROM T2PC;'     "UPDATE T2PC SET V='y' WHERE ID=0;" 'DELETE FROM T2PC WHERE ID=99;'; do
    check "the law holds for: $sql" "$(qn "$F" "$sql")" "$(qn "$E" "$sql")"
done
# THE INDEX NARROWS WHAT IS READ, AND LIMBO RAISES ONLY WHEN READ:
# a probe away from the limbo key answers, a probe at it or a range
# crossing it raises - measured, and the exact seam of W1's sentence
for sql in 'SELECT V FROM TIX WHERE ID = 0;' 'SELECT V FROM TIX WHERE ID = 5;'     'SELECT V FROM TIX WHERE ID > 2;'; do
    check "the index law holds for: $sql" "$(qn "$F" "$sql")" "$(qn "$E" "$sql")"
done

# --- 6. the refusal for an id that is not in limbo -----------------------------
check "reconnecting a non-limbo id answers the engine's own pair" \
    "$("$RIG" resolve "$F" 999999 c 2>&1 | tail -2)" \
    "$("$RIG" resolve "$E" 999999 c 2>&1 | tail -2)"

echo "ran $ran checks"
exit $fail
