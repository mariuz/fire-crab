#!/bin/bash
# COMMIT RETAIN / ROLLBACK RETAIN - the work ends, the transaction does
# not (tra.cpp TRA_commit with retaining_flag -> retain_context): the
# handle, the snapshot, the open cursors and prepared statements stay;
# the savepoints go (tra.cpp:2573); the committed ids keep counting for
# the transaction ahead of its unchanged snapshot (TBM_SET
# tra_commit_sub_trans, read by TRA_snapshot_state); a retain that did no
# work burns no id (tra.cpp:457, the fast path). Both the SQL spelling
# (isql ships it as a statement) and the wire ops op_commit_retaining
# (50) / op_rollback_retaining (86) (node-firebird's commitRetaining /
# rollbackRetaining) are driven against the engine and fire-crab alike.
#
#   qa/serve-real-retain.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GSTAT="${GSTAT:-gstat}"
PORT="${1:-4822}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-retain-engine.fdb"; DBF="$D/fc-retain-crab.fdb"
LOG="/tmp/fc-serve-retain-$PORT.log"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH
fail=0; ran=0
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"

build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER);
COMMIT;
EOF
}
rm -f "$DBE" "$DBF"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

run() { printf 'SET HEADING OFF;\n%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'; }
eng() { run "127.0.0.1/$REAL:$DBE" "$1"; }
crab() { run "127.0.0.1/$PORT:$DBF" "$1"; }
both() { local e c; e=$(eng "$2"); c=$(crab "$2"); ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"; else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

# --- 1. the SQL spelling ---------------------------------------------
both "COMMIT RETAIN keeps the work, the later ROLLBACK takes only what followed" \
    "INSERT INTO T VALUES (1); COMMIT RETAIN; INSERT INTO T VALUES (2); ROLLBACK; SELECT * FROM T;"
both "ROLLBACK RETAIN drops the work, the transaction goes on" \
    "INSERT INTO T VALUES (3); ROLLBACK RETAIN; INSERT INTO T VALUES (4); COMMIT; SELECT * FROM T ORDER BY ID;"
both "every savepoint dies with a retain (isc_invalid_savepoint)" \
    "SAVEPOINT S; INSERT INTO T VALUES (5); COMMIT RETAIN; ROLLBACK TO SAVEPOINT S; SELECT COUNT(*) FROM T;"
both "COMMIT WORK RETAIN SNAPSHOT is the same statement" \
    "INSERT INTO T VALUES (6); COMMIT WORK RETAIN SNAPSHOT; SELECT COUNT(*) FROM T; COMMIT;"
both "a retain that did no work, then work, then COMMIT" \
    "COMMIT RETAIN; INSERT INTO T VALUES (7); COMMIT RETAIN; COMMIT; SELECT COUNT(*) FROM T;"

# --- 2. the wire ops and the snapshot law (two attachments) -----------
# A (concurrency) counts; B inserts and commits; A still counts the old
# number (its snapshot is kept), commits its own row with
# op_commit_retaining and sees it (tra_commit_sub_trans), then
# op_rollback_retaining undoes only what followed.
cat > "$D/fc-retain.js" <<'EOF'
const F=require("node-firebird"); const [db,port]=[process.env.DB,+process.env.PORT];
const o={host:"127.0.0.1",port,database:db,user:"SYSDBA",password:"masterkey"};
const P=(f)=>new Promise((res,rej)=>f((e,r)=>e?rej(e):res(r)));
(async()=>{ const out=[];
 const a=await P(cb=>F.attach(o,cb)); const b=await P(cb=>F.attach(o,cb));
 const ta=await P(cb=>a.transaction(F.ISOLATION_REPEATABLE_READ,cb));
 const cnt=async(t,w)=>{ try{ const r=await P(cb=>t.query("SELECT COUNT(*) AS N FROM T"+(w||""),[],cb)); return r[0].N;}catch(e){return "ERR";} };
 out.push("A0="+await cnt(ta));
 const tb=await P(cb=>b.transaction(F.ISOLATION_READ_COMMITTED,cb)); await P(cb=>tb.query("INSERT INTO T VALUES (100)",[],cb)); await P(cb=>tb.commit(cb));
 out.push("A1="+await cnt(ta));
 await P(cb=>ta.query("INSERT INTO T VALUES (101)",[],cb));
 try{ await P(cb=>ta.commitRetaining(cb)); out.push("cr=ok"); }catch(e){ out.push("cr=ERR"); }
 out.push("A2="+await cnt(ta)); out.push("own="+await cnt(ta," WHERE ID=101"));
 await P(cb=>ta.query("INSERT INTO T VALUES (102)",[],cb));
 try{ await P(cb=>ta.rollbackRetaining(cb)); out.push("rr=ok"); }catch(e){ out.push("rr=ERR"); }
 out.push("undone="+await cnt(ta," WHERE ID=102")); out.push("still="+await cnt(ta," WHERE ID=101"));
 await P(cb=>ta.commit(cb)); const tc=await P(cb=>b.transaction(F.ISOLATION_READ_COMMITTED,cb)); out.push("final="+await cnt(tc)); await P(cb=>tc.commit(cb));
 console.log(out.join(" ")); process.exit(0); })().catch(e=>{console.log("FATAL "+e.message.split("\n")[0]);process.exit(1);});
EOF
e=$(DB="$DBE" PORT="$REAL" timeout 60 node "$D/fc-retain.js" 2>&1); c=$(DB="$DBF" PORT="$PORT" timeout 60 node "$D/fc-retain.js" 2>&1)
check "op_commit_retaining / op_rollback_retaining under a kept snapshot: [$e]" "$c" "$e"
rm -f "$D/fc-retain.js"

# --- 3. Next advances only for a retain that did work -----------------
nxt() { "$GSTAT" -h -user "$U" -pas "$P" "$1" 2>/dev/null | awk '/Next transaction/ {print $3}'; }
b=$(nxt "$DBF")
crab "INSERT INTO T VALUES (8); COMMIT RETAIN; INSERT INTO T VALUES (9); COMMIT RETAIN; COMMIT RETAIN; COMMIT RETAIN; COMMIT;" >/dev/null
a=$(nxt "$DBF")
check "fc: two working retains burn two ids, two empty ones none (Next $b -> $a)" "$(( a - b ))" "2"

# --- 4. coverage ------------------------------------------------------
ran=$((ran + 1))
n=$(grep -c 'RETAIN: ids' "$LOG")
if [ "$n" -ge 8 ]; then echo "OK   coverage: $n retaining ends in the trace"; else echo "DIFF coverage: [$n] retaining ends"; fail=1; fi
echo "ran $ran checks"
exit $fail
