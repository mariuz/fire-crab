#!/bin/bash
# The OIT/OAT/OST bookkeeping `gstat -h` reads - fire-crab and the engine
# driven through the SAME node scenarios on twin files, headers compared.
#
# The engine recomputes the three "Oldest" header fields in
# TRA_update_oldest: OIT at a transaction's START (so after an
# all-committed history it lands on the LAST id - the starting
# transaction is itself active - and that transaction's own commit does
# not advance it past its own id), OAT/OST at start AND end (one past
# the last id when nothing is active). fire-crab now maintains the same
# law at begin_active_tx / commit_tx / kill_tx / prepare_tx.
#
# RAW ids cannot be twinned: node-firebird burns internal transactions
# against the engine that fire-crab serves without ids, and the two
# servers store `hdr_next_transaction` one display slot apart (engine:
# next-to-assign; fire-crab: last-assigned). What IS pinned is the LAW,
# as offsets from the last assigned id:
#
#     (last - OIT,  OAT - last,  OST - OAT)
#
# per side: the engine shows (0 1 0) after a plain committed workload,
# fire-crab (0 0 0) - one display slot apart BY DESIGN, because the
# engine's validation (pag.cpp 266) reads the fields by its own
# convention and an fc OAT past its stored next field would read as
# corruption on every engine-side open (measured exactly that way:
# gfix -v on an fc-written file raised "next transaction older than
# oldest active transaction (266)" until the clamp).
#
# Two knowingly-divergent scenarios are PINNED per side too:
#   * a rolled-back writer: the engine undoes it and marks it COMMITTED
#     (rollback via undo log), so its OIT moves past; fire-crab's
#     rollback-by-state leaves tra_dead (the engine's own no-undo path)
#     and OIT PINS there at the next begin. gstat-only divergence,
#     recorded in the roadmap.
#   * a read-only transaction: the engine burns an id; fire-crab
#     allocates lazily on first write, so the header does not move.
#
#   qa/serve-real-oldesttx.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GSTAT="${GSTAT:-gstat}"
PORT="${1:-4774}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
BASE="$D/fc-oldest-base.fdb"
A="$D/fc-oldest-crab.fdb"
B="$D/fc-oldest-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
command -v "$GSTAT" >/dev/null 2>&1 || { echo "SKIP gstat not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }
CREATE DATABASE '$BASE' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER);
COMMIT;
EOF
chmod 666 "$BASE"

DRIVER=$(mktemp /tmp/fc-oldest-XXXX.js)
trap 'rm -f "$DRIVER"' EXIT
cat > "$DRIVER" <<'EOF'
// env: FC_DB, FC_PORT, FC_SCEN - run one transaction scenario, then exit
const F=require("node-firebird");
function tx(db, sqls, endMode, cb){
  db.transaction(F.ISOLATION_REPEATABLE_READ, (e,tr)=>{
    if(e){console.log("TXERR",e.message);process.exit(1);}
    let i=0;
    const next=()=>{
      if(i>=sqls.length){ (endMode==="commit"?tr.commit:tr.rollback).call(tr,()=>cb()); return; }
      tr.query(sqls[i++],(e2)=>{ if(e2){console.log("QERR",e2.message);process.exit(1);} next(); });
    };
    next();
  });
}
F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
          user:"SYSDBA",password:"masterkey"},(e,db)=>{
  if(e){console.log("CONN_ERR",e.message);process.exit(1);}
  const done=()=>db.detach(()=>process.exit(0));
  switch(process.env.FC_SCEN){
    case "commits3":
      tx(db,["INSERT INTO T VALUES (1)"],"commit",()=>
      tx(db,["INSERT INTO T VALUES (2)"],"commit",()=>
      tx(db,["INSERT INTO T VALUES (3)"],"commit",done))); break;
    case "deadlast":
      tx(db,["INSERT INTO T VALUES (1)"],"commit",()=>
      tx(db,["UPDATE T SET ID=99 WHERE ID=1"],"rollback",done)); break;
    case "deadmid": // a dead writer, then a committed one after it
      tx(db,["INSERT INTO T VALUES (1)"],"rollback",()=>
      tx(db,["INSERT INTO T VALUES (2)"],"commit",done)); break;
    case "readonly":
      tx(db,["SELECT COUNT(*) FROM T"],"commit",done); break;
    default: console.log("BADSCEN"); process.exit(1);
  }
});
EOF

# gstat -h fields as "OIT OAT OST NEXT"
fields() { "$GSTAT" -h "$1" | grep -E "Oldest transaction|Oldest active|Oldest snapshot|Next transaction" | awk '{print $NF}' | tr '\n' ' '; }

# the LAW as offsets from the LAST ASSIGNED id: "last-OIT OAT-last OST-OAT".
# engine stores next-to-assign (last = NEXT-1), fire-crab last-assigned
# (last = NEXT). The two sides land ONE DISPLAY SLOT apart by design:
# fire-crab must keep OAT <= its stored next field, because the engine's
# validation (pag.cpp 266) reads the fields by ITS convention and an OAT
# past the stored next reads as corruption - so "nothing active" is
# OAT = next+1-as-the-engine-sees-it on the engine's own file and
# OAT = stored-next on fire-crab's. Each scenario therefore pins BOTH
# sides' triples, derived from the same probed semantics.
offsets() { # <db> <engine|crab>
    set -- $(fields "$1") "$2"
    oit=$1; oat=$2; ost=$3; next=$4
    if [ "$5" = engine ]; then last=$((next - 1)); else last=$next; fi
    echo "$((last - oit)) $((oat - last)) $((ost - oat))"
}

scen() { # <scenario> - run on BOTH sides, fresh twin files
    cp "$BASE" "$A"; cp "$BASE" "$B"; chmod 666 "$A" "$B"
    "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-oldesttx.log 2>&1 &
    srv=$!
    i=0; while [ $i -lt 20 ]; do
        command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
        i=$((i + 1)); sleep 0.1
    done
    kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT taken?"; exit 1; }
    FC_DB="$A" FC_PORT="$PORT" FC_SCEN="$1" timeout 60 node "$DRIVER"
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
    FC_DB="$B" FC_PORT="$REAL" FC_SCEN="$1" timeout 60 node "$DRIVER"
    sleep 0.2
}

law() { # <label> <scenario> <crab-triple> <engine-triple>
    ran=$((ran + 1))
    scen "$2"
    a=$(offsets "$A" crab)
    b=$(offsets "$B" engine)
    if [ "$a" = "$3" ] && [ "$b" = "$4" ]; then
        echo "OK   $1: fc ($a), engine ($b)"
    else
        echo "DIFF $1"
        echo "     fcwire: ($a) expected ($3)   raw: $(fields "$A")"
        echo "     engine: ($b) expected ($4)   raw: $(fields "$B")"
        fail=1
    fi
}

law "an all-committed history: OIT at the last id, nothing active" \
    "commits3" "0 0 0" "0 1 0"
law "a dead FINAL writer: same shape (OIT was written at its begin)" \
    "deadlast" "0 0 0" "0 1 0"

# --- the two recorded divergences, pinned per side ---------------------
# a dead writer with a commit AFTER it: the next begin recomputes OIT and
# fire-crab PINS it at the dead id (tra_dead stays interesting), where
# the engine has undone-and-committed the rollback and moves past. The
# dead id here is last-1 (the commit after it is last), so the fc triple
# is (1 0 0) against the engine's (0 1 0).
ran=$((ran + 1))
scen "deadmid"
a=$(offsets "$A" crab)
b=$(offsets "$B" engine)
if [ "$a" = "1 0 0" ] && [ "$b" = "0 1 0" ]; then
    echo "OK   a dead mid-history writer: fc pins OIT at it (1 0 0), the engine's undo moves past (0 1 0)"
else
    echo "DIFF dead mid-history writer: fc ($a) expected (1 0 0), engine ($b) expected (0 1 0)"
    fail=1
fi

# a read-only transaction: fire-crab allocates its id lazily on first
# write, so the header does not move at all; the engine burns ids. The
# fc header must equal the BASELINE's, byte for byte in these fields.
ran=$((ran + 1))
scen "readonly"
a=$(fields "$A")
base=$(fields "$BASE")
b=$(offsets "$B" engine)
if [ "$a" = "$base" ] && [ "$b" = "0 1 0" ]; then
    echo "OK   a read-only transaction: fc header untouched (lazy id), engine law holds ($b)"
else
    echo "DIFF read-only: fc [$a] vs baseline [$base]; engine ($b) expected (0 1 0)"
    fail=1
fi

# --- sanity: the ordering invariant the loader checks ------------------
# OIT <= OAT <= OST is what ods::tra's header sanity asserts; a violation
# here would poison every later open of the file.
ran=$((ran + 1))
set -- $(fields "$A")
if [ "$1" -le "$2" ] && [ "$2" -le "$3" ]; then
    echo "OK   OIT <= OAT <= OST on the fc-written file"
else
    echo "DIFF ordering: OIT=$1 OAT=$2 OST=$3"
    fail=1
fi

rm -f "$A" "$B" "$BASE"
if [ "$ran" -lt 5 ]; then
    echo "DIFF only $ran checks ran (expected at least 5) - did one silently skip?"
    fail=1
fi
exit $fail
