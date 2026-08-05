#!/bin/bash
# THE CONCURRENCY ORACLE - what two attachments do to each other.
#
# Every other gate in this suite compares ONE session's answers, and that
# is why none of them has ever said anything about W4. A lock manager
# decides what happens when two attachments touch the same row; a
# single-session differential cannot ask the question, so the answer has
# gone unmeasured while `lck` sat converted-and-not-wired and the roadmap
# said concurrency was "correct rather than accidentally correct".
#
# IT IS NEITHER. Measured here, the finding is not that the lock manager
# is missing - it is that THERE IS NOTHING FOR A LOCK MANAGER TO
# ARBITRATE. `load_database` does `std::fs::read(path)` into an owned
# `Vec<u8>`, once per connection thread, so every attachment holds a
# PRIVATE FULL-FILE COPY and its flush writes that copy's pages back.
# Two attachments are two databases that happen to share a filename.
#
# What follows from that, and what this gate pins:
#
#   * an attachment opened BEFORE another's commit never sees it - not a
#     stale cache, a frozen image, for the life of the connection;
#   * one opened AFTER does see it, and the engine reading the file sees
#     it too, so the write is DURABLE and correctly on disk;
#   * two attachments writing at once each flush their own image, and
#     one side's committed rows are silently GONE - with `gfix -v -full`
#     calling the result perfectly valid, because it is: it is one
#     writer's consistent image, whole, having overwritten the other's.
#
# THE ENGINE'S SIDE OF EVERY CHECK IS ASSERTED TOO, and that is the point
# of the file: the engine BLOCKS the second writer (default WAIT), so its
# behaviour is the target these divergences are measured against. If the
# engine's half ever stops holding, the premise is wrong and the
# divergences below mean nothing.
#
# THE ORDER THIS PUTS THE ROADMAP IN. W4 (the lock manager participating)
# cannot be started: a lock manager arbitrates access to a SHARED
# resource and there is not one yet. Its prerequisite is W2's READ PATH -
# "the server still slices the image directly rather than fetching
# through buffers" - which the roadmap lists as an independent item.
# Shared buffers first, then locking over them.
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
COMMIT;
EOF
    chmod 666 "$1"
}

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-conc.log 2>&1 &
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

rows_by_who() { # <db> - what the ENGINE finds in the file afterwards
    printf 'SET HEADING OFF;\nSELECT WHO || COUNT(*) FROM W GROUP BY WHO ORDER BY 1;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        tr -d ' ' | grep -v '^$' | tr '\n' ','
}

# --- 1. THE ENGINE'S LAWS, which are the target ------------------------
# If these ever stop holding, every divergence below is measured against
# the wrong thing and means nothing.
make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
eng_vis=$(FC_PORT="$REAL" FC_DB="$B" timeout 60 node -e "$VIS" 2>/dev/null)
check "ENGINE: writer sees its own write, others see it too" "$eng_vis" "555|555|555"

make_db "$B" || { echo "FAIL scratch engine db"; exit 1; }
eng_cw=$(FC_PORT="$REAL" FC_DB="$B" timeout 90 node -e "$CW" 2>/dev/null)
check "ENGINE: both writers' statements are accepted" "$eng_cw" "20/20"
check "ENGINE: and BOTH sides' rows are in the file" \
      "$(rows_by_who "$B")" "A10,B10,"

# --- 2. FIRE-CRAB: the same probes, and what they answer ---------------
# RECORDED DIVERGENCES, not passing behaviour. Each one is written as the
# value fire-crab GIVES with the engine's value named in the label, so
# the day any of them changes this gate says so.
make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
fc_vis=$(FC_PORT="$PORT" FC_DB="$A" timeout 60 node -e "$VIS" 2>/dev/null)
# W4 DIVERGENCE: the middle field is the engine's 555.
check "fc: an attachment opened BEFORE the commit never sees it (engine: 555)" \
      "$fc_vis" "555|100|555"

make_db "$A" || { echo "FAIL scratch crab db"; exit 1; }
fc_cw=$(FC_PORT="$PORT" FC_DB="$A" timeout 90 node -e "$CW" 2>/dev/null)
check "fc: every statement is accepted, as on the engine" "$fc_cw" "20/20"
# W4 DIVERGENCE: the engine has A10,B10 - here one image overwrote the
# other, and which one wins is a race, so the check is that exactly ONE
# side survived rather than which.
lost=$(rows_by_who "$A")
ran=$((ran + 1))
case "$lost" in
    "A10,B10,") echo "DIFF fc kept BOTH writers' rows - the shared image landed?"; fail=1 ;;
    "A10,"|"B10,") echo "OK   fc: one attachment's committed rows are GONE (engine: A10,B10) [$lost]" ;;
    *) echo "DIFF fc lost more than one side's rows: [$lost]"; fail=1 ;;
esac
# ...and the file is STRUCTURALLY VALID, which is what makes this silent:
# it is one writer's consistent image, whole, over the top of the other's
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
check "fc: and gfix calls the result perfectly valid" \
      "$(printf '%s' "$val" | tr -d ' \n')" ""

# --- 3. THE ORACLE'S OWN TEETH -----------------------------------------
# A gate that cannot fail is a source of false confidence, and this one
# asserts a NEGATIVE ("the rows are gone"), which is the easiest kind to
# fake. So: the same probe against the ENGINE must produce the OPPOSITE
# result, and it did, above - checks 2 and 3 are that assertion. This one
# proves the probe can see rows at all.
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

echo "ran $ran checks"
exit $fail
