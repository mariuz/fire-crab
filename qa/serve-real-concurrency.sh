#!/bin/bash
# THE CONCURRENCY ORACLE - what two attachments do to each other.
#
# Every other gate in this suite compares ONE session's answers, and that
# is why none of them had ever said anything about W4. A lock manager
# decides what happens when two attachments touch the same row; a
# single-session differential cannot ask the question.
#
# WHAT THIS GATE FOUND WHEN IT WAS WRITTEN. Not a missing lock manager -
# nothing for one to arbitrate. `load_database` did `std::fs::read(path)`
# into an owned `Vec<u8>` once per connection thread, so every attachment
# held a PRIVATE FULL-FILE COPY and its flush wrote that copy's pages
# back. Two attachments were two databases that happened to share a
# filename: an attachment opened before another's commit never saw it,
# and 20 concurrent inserts across two attachments left 10 rows, because
# one side's image landed whole over the top of the other's - under a
# file `gfix -v -full` then called perfectly valid, since it was.
#
# WHAT IT PINS NOW, on both servers, with the engine's answers as the
# target:
#
#   * an uncommitted row is INVISIBLE - a transaction stays
#     `tra_active` in the TIP until COMMIT flips the two bits, and every
#     record walk takes the newest version whose transaction it counts;
#   * a writer that wants a row ANOTHER TRANSACTION IS HOLDING waits
#     for that transaction and then applies its write to what it finds -
#     the engine's WAIT and re-read, arbitrated through `fire_crab_lck`:
#     the holder keeps an exclusive lock on its own transaction id
#     (`LCK_tra`) and the waiter parks on it;
#   * a writer that wants an UNRELATED row does not wait at all, which
#     is what a database-wide write side used to cost;
#   * and two transactions waiting on each other are a DEADLOCK, denied
#     by the lock table's wait-for scan rather than left to hang.
#
# THE ENGINE'S SIDE OF EVERY CHECK IS ASSERTED TOO, and that is the point
# of the file: the divergences are only meaningful against a target that
# still holds. If the engine's half ever stops holding, the premise is
# wrong and what follows means nothing.
#
# AND THE COVERAGE HALF. A subsystem wired in but never used passes every
# behaviour gate, so the last section reads the pool's own counters out
# of the server log: attachments that found the image already resident,
# and writers that had to WAIT for another. Both non-zero is what makes
# the checks above evidence about the pool rather than about one process
# that happened to be alone.
#
#   qa/serve-real-concurrency.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4694}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-conc-crab.fdb"
B="$D/fc-conc-engine.fdb"
LOG=/tmp/fc-serve-conc.log

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE V (ID INTEGER, BAL INTEGER);
CREATE TABLE W (ID INTEGER, WHO VARCHAR(4));
COMMIT;
INSERT INTO V VALUES (1, 100);
INSERT INTO V VALUES (2, 200);
COMMIT;
EOF
    chmod 666 "$1"
}

# FC_SRV_TRACE is on for the COVERAGE section at the bottom - the pool
# prints its counters with the rest of the attach trace.
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1
    fi
}

# --- the visibility probe ----------------------------------------------
# A writes and commits; B was attached BEFORE, C attaches AFTER.
VIS='const F=require("node-firebird");
const o=()=>({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
              user:"SYSDBA",password:"masterkey"});
const at=()=>new Promise(r=>F.attach(o(),(e,d)=>r(e?null:d)));
const q=(d,s)=>new Promise(r=>d.query(s,(e,x)=>r(e?"ERR":(x&&x[0]?String(x[0].BAL):"none"))));
(async()=>{
  const A=await at(), B=await at();
  if(!A||!B){console.log("ATTACH_FAIL");process.exit(0);}
  await q(A,"UPDATE V SET BAL=555 WHERE ID=1");
  const self=await q(A,"SELECT BAL FROM V WHERE ID=1");
  const before=await q(B,"SELECT BAL FROM V WHERE ID=1");
  const C=await at();
  const after=await q(C,"SELECT BAL FROM V WHERE ID=1");
  console.log(self+"|"+before+"|"+after);
  process.exit(0);})();'

# --- the concurrent-writer probe ---------------------------------------
# Both attach BEFORE either writes, then insert distinct rows at once.
CW='const F=require("node-firebird");
const Q=String.fromCharCode(39);
const o=()=>({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
              user:"SYSDBA",password:"masterkey"});
const at=()=>new Promise(r=>F.attach(o(),(e,d)=>r(e?null:d)));
const q=(d,s)=>new Promise(r=>d.query(s,e=>r(e?"ERR":"ok")));
(async()=>{
  const A=await at(), B=await at();
  if(!A||!B){console.log("ATTACH_FAIL");process.exit(0);}
  const jobs=[];
  for(let i=0;i<10;i++) jobs.push(q(A,"INSERT INTO W VALUES ("+i+", "+Q+"A"+Q+")"));
  for(let i=100;i<110;i++) jobs.push(q(B,"INSERT INTO W VALUES ("+i+", "+Q+"B"+Q+")"));
  const r=await Promise.all(jobs);
  console.log(r.filter(x=>x==="ok").length+"/"+r.length);
  process.exit(0);})();'

# --- the OPEN-TRANSACTION probe ----------------------------------------
# A opens an explicit transaction, inserts row 1 and HOLDS it for two
# seconds. While it is held, B (a second attachment) asks two questions:
#
#   * can it SEE the uncommitted row? - no: the transaction is
#     `tra_active` in the TIP and the version walk steps past it;
#   * how long does its own insert of a DIFFERENT row take? - no time at
#     all, because nothing about an unrelated row is contended.
#
# The answer is "<visible>|<fast|waited>", with the wait threshold at
# one second against a hold of two, and both servers must give it.
HOLD='const F=require("node-firebird");
const Q=String.fromCharCode(39);
const o=()=>({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
              user:"SYSDBA",password:"masterkey"});
const at=()=>new Promise(r=>F.attach(o(),(e,d)=>r(e?null:d)));
const tx=(d)=>new Promise(r=>d.transaction(F.ISOLATION_READ_COMMITTED,(e,t)=>r(e?null:t)));
const tq=(t,s)=>new Promise(r=>t.query(s,e=>r(e?"ERR":"ok")));
const cm=(t)=>new Promise(r=>t.commit(()=>r()));
const cnt=(d,s)=>new Promise(r=>d.query(s,(e,x)=>r(e?"ERR":String(x[0].N))));
const q=(d,s)=>new Promise(r=>d.query(s,e=>r(e?"ERR":"ok")));
(async()=>{
  const A=await at(), B=await at();
  if(!A||!B){console.log("ATTACH_FAIL");process.exit(0);}
  const t=await tx(A);
  if(!t){console.log("TX_FAIL");process.exit(0);}
  await tq(t,"INSERT INTO W VALUES (1, "+Q+"A"+Q+")");
  // release the transaction two seconds from now, whatever B is doing
  const held=new Promise(r=>setTimeout(async()=>{await cm(t);r();},2000));
  const dirty=await cnt(B,"SELECT COUNT(*) AS N FROM W WHERE ID=1");
  const t0=Date.now();
  await q(B,"INSERT INTO W VALUES (2, "+Q+"B"+Q+")");
  const took=Date.now()-t0;
  await held;
  console.log(dirty+"|"+(took<1000?"fast":"waited"));
  process.exit(0);})();'

# --- the ROW-CONFLICT probe ---------------------------------------------
# A holds a transaction that has updated row 1. B updates THE SAME ROW.
# The engine makes B wait for A and then applies B's write to what it
# finds; fire-crab does the same through the lock table - A holds an
# exclusive lock on its own transaction id, B parks on it, and when A
# commits B wakes, re-reads the row and writes.
#
# The answer is "<fast|waited>|<final value>": B must be held up for
# about as long as A holds, and its value must be the one that lands.
ROWCONF='const F=require("node-firebird");
const o=()=>({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
              user:"SYSDBA",password:"masterkey"});
const at=()=>new Promise(r=>F.attach(o(),(e,d)=>r(e?null:d)));
const tx=(d)=>new Promise(r=>d.transaction(F.ISOLATION_READ_COMMITTED,(e,t)=>r(e?null:t)));
const tq=(t,s)=>new Promise(r=>t.query(s,e=>r(e?"ERR":"ok")));
const cm=(t)=>new Promise(r=>t.commit(()=>r()));
const q=(d,s)=>new Promise(r=>d.query(s,e=>r(e?"ERR":"ok")));
const val=(d)=>new Promise(r=>d.query("SELECT BAL FROM V WHERE ID=1",(e,x)=>r(e?"ERR":String(x[0].BAL))));
(async()=>{
  const A=await at(), B=await at();
  if(!A||!B){console.log("ATTACH_FAIL");process.exit(0);}
  const t=await tx(A);
  if(!t){console.log("TX_FAIL");process.exit(0);}
  await tq(t,"UPDATE V SET BAL=111 WHERE ID=1");
  const held=new Promise(r=>setTimeout(async()=>{await cm(t);r();},2000));
  const t0=Date.now();
  const r1=await q(B,"UPDATE V SET BAL=222 WHERE ID=1");
  const took=Date.now()-t0;
  await held;
  console.log((took<1000?"fast":"waited")+"|"+(r1==="ok"?await val(B):r1));
  process.exit(0);})();'

# --- the DEADLOCK probe -------------------------------------------------
# A takes row 1 and B takes row 2, then each asks for the other's. One
# of them cannot be allowed to wait: the engine denies it (SQLSTATE
# 40001) and fire-crab denies it from the same wait-for graph, through
# `fire_crab_lck`'s deadlock scan. The answer is how many of the two
# second statements failed - exactly one, on both servers.
DEADLOCK='const F=require("node-firebird");
const o=()=>({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
              user:"SYSDBA",password:"masterkey"});
const at=()=>new Promise(r=>F.attach(o(),(e,d)=>r(e?null:d)));
const tx=(d)=>new Promise(r=>d.transaction(F.ISOLATION_READ_COMMITTED,(e,t)=>r(e?null:t)));
const tq=(t,s)=>new Promise(r=>t.query(s,e=>r(e?"ERR":"ok")));
const rb=(t)=>new Promise(r=>t.rollback(()=>r()));
(async()=>{
  const A=await at(), B=await at();
  if(!A||!B){console.log("ATTACH_FAIL");process.exit(0);}
  const ta=await tx(A), tb=await tx(B);
  if(!ta||!tb){console.log("TX_FAIL");process.exit(0);}
  await tq(ta,"UPDATE V SET BAL=11 WHERE ID=1");
  await tq(tb,"UPDATE V SET BAL=22 WHERE ID=2");
  // THE LOSER IS ROLLED BACK, or the winner waits for a transaction
  // nobody ever ends - the engine denies one side and leaves the other
  // parked, which is the behaviour being measured
  let failed=0;
  const arm=(t,s)=>tq(t,s).then(r=>{ if(r==="ERR"){ failed++; return rb(t); } });
  await Promise.all([arm(ta,"UPDATE V SET BAL=12 WHERE ID=2"),
                     arm(tb,"UPDATE V SET BAL=21 WHERE ID=1")]);
  console.log("failed="+failed);
  await rb(ta).catch(()=>{}); await rb(tb).catch(()=>{});
  process.exit(0);})();'

rows_by_who() { # <db> - what the ENGINE finds in the file afterwards
    printf 'SET HEADING OFF;\nSELECT WHO || COUNT(*) FROM W GROUP BY WHO ORDER BY 1;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        tr -d ' ' | grep -v '^$' | tr '\n' ','
}

# --- 1. THE ENGINE'S LAWS, which are the target ------------------------
# If these ever stop holding, every check below is measured against the
# wrong thing and means nothing.
make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
eng_vis=$(FC_PORT="$REAL" FC_DB="$B" timeout 60 node -e "$VIS" 2>/dev/null)
check "ENGINE: writer sees its own write, others see it too" "$eng_vis" "555|555|555"

make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
eng_cw=$(FC_PORT="$REAL" FC_DB="$B" timeout 90 node -e "$CW" 2>/dev/null)
check "ENGINE: both writers' statements are accepted" "$eng_cw" "20/20"
check "ENGINE: and BOTH sides' rows are in the file" \
      "$(rows_by_who "$B")" "A10,B10,"

make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
eng_hold=$(FC_PORT="$REAL" FC_DB="$B" timeout 90 node -e "$HOLD" 2>/dev/null)
check "ENGINE: an uncommitted row is invisible, and an unrelated write does not block" \
      "$eng_hold" "0|fast"

make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
eng_conf=$(FC_PORT="$REAL" FC_DB="$B" timeout 90 node -e "$ROWCONF" 2>/dev/null)
check "ENGINE: a writer WAITS for the transaction holding its row, then writes" \
      "$eng_conf" "waited|222"

make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
eng_dead=$(FC_PORT="$REAL" FC_DB="$B" timeout 90 node -e "$DEADLOCK" 2>/dev/null)
check "ENGINE: two transactions waiting on each other - exactly one is denied" \
      "$eng_dead" "failed=1"

# --- 2. FIRE-CRAB: the same probes -------------------------------------
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
fc_vis=$(FC_PORT="$PORT" FC_DB="$A" timeout 60 node -e "$VIS" 2>/dev/null)
check "fc: every attachment sees a committed write, whenever it attached" \
      "$fc_vis" "555|555|555"

make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
fc_cw=$(FC_PORT="$PORT" FC_DB="$A" timeout 90 node -e "$CW" 2>/dev/null)
check "fc: every statement is accepted, as on the engine" "$fc_cw" "20/20"
check "fc: and BOTH writers' rows are in the file - one image, not two" \
      "$(rows_by_who "$A")" "A10,B10,"
# ...and it is still a file the engine's own validator accepts
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
check "fc: and gfix finds nothing wrong with the result" \
      "$(printf '%s' "$val" | tr -d ' \n')" ""

# --- 3. AN OPEN TRANSACTION, AND WHO IT HOLDS UP ------------------------
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
fc_hold=$(FC_PORT="$PORT" FC_DB="$A" timeout 90 node -e "$HOLD" 2>/dev/null)
# The engine's own answer, both fields: the uncommitted row is invisible
# (the transaction is `tra_active` and the walk steps past its version),
# and an UNRELATED writer is not held up at all - the write side covers
# one statement now, not a transaction.
check "fc: an uncommitted row is invisible, and an unrelated writer is not held up" \
      "$fc_hold" "$eng_hold"

make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
fc_conf=$(FC_PORT="$PORT" FC_DB="$A" timeout 90 node -e "$ROWCONF" 2>/dev/null)
check "fc: a writer WAITS for the transaction holding its row, then writes" \
      "$fc_conf" "$eng_conf"

make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
fc_dead=$(FC_PORT="$PORT" FC_DB="$A" timeout 90 node -e "$DEADLOCK" 2>/dev/null)
check "fc: two transactions waiting on each other - exactly one is denied" \
      "$fc_dead" "$eng_dead"

# --- 3b. THE ENGINE READS THE OPEN TRANSACTION -------------------------
# The check above is fire-crab agreeing with itself. This one asks the
# ENGINE what is in the file while fire-crab holds a transaction open:
# the row is already ON THE PAGES (every statement flushes), so what
# hides it is the TIP entry alone - and the engine reads that TIP with
# its own code. If the state fire-crab writes were not the state the
# engine understands, this is where it shows.
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
engine_count() { # what the ENGINE finds in the file right now
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM W WHERE ID = 42;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null | tr -d ' \n'
}
FC_PORT="$PORT" FC_DB="$A" timeout 60 node -e '
const F=require("node-firebird");
const Q=String.fromCharCode(39);
const o={host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
         user:"SYSDBA",password:"masterkey"};
F.attach(o,(e,d)=>{ if(e){process.exit(1);}
  d.transaction(F.ISOLATION_READ_COMMITTED,(e2,t)=>{ if(e2){process.exit(1);}
    t.query("INSERT INTO W VALUES (42, "+Q+"A"+Q+")",()=>{
      // hold it open, then commit
      setTimeout(()=>t.commit(()=>process.exit(0)), 4000); }); }); });' \
  >/dev/null 2>&1 &
holder=$!
sleep 2
check "the ENGINE does not see fire-crab's uncommitted row" "$(engine_count "$A")" "0"
wait $holder 2>/dev/null
check "...and sees it the moment fire-crab commits" "$(engine_count "$A")" "1"

# --- 4. THE ORACLE'S OWN TEETH -----------------------------------------
# A gate that cannot fail is a source of false confidence. Sections 1
# and 2 are the same probes against both servers, so a probe that
# measured nothing would have to fool the engine too; this one proves
# the row-counting probe can tell rows apart at all.
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
one=$(FC_PORT="$PORT" FC_DB="$A" timeout 30 node -e '
const F=require("node-firebird");
const Q=String.fromCharCode(39);
const o=()=>({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
              user:"SYSDBA",password:"masterkey"});
F.attach(o(),(e,d)=>{ if(e){console.log("ERR");process.exit(0);}
  d.query("INSERT INTO W VALUES (1, "+Q+"A"+Q+")",()=>{
    d.query("INSERT INTO W VALUES (2, "+Q+"B"+Q+")",()=>{
      console.log("done"); process.exit(0); }); }); });' 2>/dev/null)
check "teeth: ONE attachment writing both sides keeps both" \
      "$(rows_by_who "$A")" "A1,B1,"

# --- 5. COVERAGE: the pool was actually on the path --------------------
# The behaviour checks above would all pass against a server that still
# gave every attachment its own copy IF the probes never overlapped. The
# pool's own counters are what say they did: `shared` counts attachments
# that found the image already resident, `write-waits` counts writers
# that queued behind another.
pool=$(grep '\[srv\] pool:' "$LOG" | tail -1)
shared=$(printf '%s' "$pool" | sed -n 's/.*shared \([0-9]*\).*/\1/p')
waits=$(printf '%s' "$pool" | sed -n 's/.*write-waits \([0-9]*\).*/\1/p')
ran=$((ran + 1))
if [ -n "${shared:-}" ] && [ "${shared:-0}" -gt 0 ]; then
    echo "OK   coverage: attachments shared a resident image [$pool]"
else
    echo "DIFF coverage: nothing was shared - the pool is not on the path [$pool]"; fail=1
fi
ran=$((ran + 1))
if [ -n "${waits:-}" ] && [ "${waits:-0}" -gt 0 ]; then
    echo "OK   coverage: writers queued behind one another [write-waits $waits]"
else
    echo "DIFF coverage: no writer ever waited - the write side is not being taken"; fail=1
fi

# ...and the LOCK TABLE's own counters, for the same reason: the checks
# above would pass against a server that never enqueued anything if its
# probes never actually met.
locks=$(grep '\[srv\] locks:' "$LOG" | tail -1)
waits=$(printf '%s' "$locks" | sed -n 's/.*waits \([0-9]*\).*/\1/p')
deads=$(printf '%s' "$locks" | sed -n 's/.*deadlocks \([0-9]*\).*/\1/p')
ran=$((ran + 1))
if [ -n "${waits:-}" ] && [ "${waits:-0}" -gt 0 ]; then
    echo "OK   coverage: writers parked on a transaction lock [$locks]"
else
    echo "DIFF coverage: nothing ever waited on a transaction [$locks]"; fail=1
fi
ran=$((ran + 1))
if [ -n "${deads:-}" ] && [ "${deads:-0}" -gt 0 ]; then
    echo "OK   coverage: the wait-for scan denied a cycle [deadlocks $deads]"
else
    echo "DIFF coverage: no deadlock was ever detected [$locks]"; fail=1
fi

echo "ran $ran checks"
exit $fail
