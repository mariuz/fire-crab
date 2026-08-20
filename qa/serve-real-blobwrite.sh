#!/bin/bash
# BLOB WRITES OVER THE WIRE: a client builds a blob with op_create_blob2
# (57) / op_create_blob (34), fills it with op_batch_segments (44 -
# [u16 LE len][bytes]* per packet, node-firebird's way) or op_put_segment
# (37 - one raw segment, libfbclient's), closes it, and binds the id it
# got back as a blr_quad parameter. Until the store the blob is
# TEMPORARY (blb.cpp BLB_temporary / tra_blobs: relation 0, the id in
# the number); the INSERT MATERIALISES it into the relation's own pages
# (blb::move - "the only place in the engine where blobs are
# materialized") and the record carries the permanent id. A blob never
# stored dies with the transaction; op_cancel_blob drops it at once.
#
# Before this, a blr_quad parameter DROPPED THE CONNECTION ("undecodable
# input-message BLR") and no blob op but open/get/close existed.
#
# The same node script runs against the engine and fire-crab on twin
# files; then the ENGINE reads every blob fire-crab wrote (content and
# length, the 30,000-byte level-1 blob's tail included), validates the
# file and backs it up.
#
#   qa/serve-real-blobwrite.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4826}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-blobwrite-engine.fdb"; DBF="$D/fc-blobwrite-crab.fdb"
LOG="/tmp/fc-serve-blobwrite-$PORT.log"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH
fail=0; ran=0
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE BL (ID INTEGER, T BLOB SUB_TYPE TEXT, B BLOB SUB_TYPE BINARY);
COMMIT;
EOF
}
rm -f "$DBE" "$DBF" "$D/fc-blobwrite.fbk"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D/fc-blobwrite.fbk" "$D/fc-blobwrite.js"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
engf() { printf 'SET HEADING OFF;\n%s\n' "$1" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DBF" 2>&1 |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g' | grep -v '^$' | tr '\n' '|'; }

cat > "$D/fc-blobwrite.js" <<'EOF'
const F=require("node-firebird"); const [db,port]=[process.env.DB,+process.env.PORT];
const o={host:"127.0.0.1",port,database:db,user:"SYSDBA",password:"masterkey"};
const P=(f)=>new Promise((res,rej)=>f((e,r)=>e?rej(e):res(r)));
const rd=(f)=>new Promise((res,rej)=>{ if(!f) return res(null); f((e,name,em)=>{ if(e) return rej(e); const chunks=[]; em.on("data",c=>chunks.push(Buffer.from(c))); em.on("end",()=>res(Buffer.concat(chunks))); }); });
(async()=>{ const out=[]; const d=await P(cb=>F.attach(o,cb));
 const big=Buffer.alloc(30000); for(let i=0;i<big.length;i++) big[i]=97+(i%26);
 const bin=Buffer.from([0,1,2,255,254,10,13,0,7]);
 const ins=async(id,t,b)=>{ try{ await P(cb=>d.query("INSERT INTO BL (ID, T, B) VALUES (?, ?, ?)",[id,t,b],cb)); return "ok"; }catch(e){ return "ERR "+e.message.split("\n")[0]; } };
 out.push("ins1="+await ins(1,Buffer.from("hello blob"),bin));
 out.push("ins2="+await ins(2,big,null));
 out.push("ins3="+await ins(3,Buffer.alloc(0),Buffer.from("x")));
 // a blob built and then the statement rolled back: nothing stored
 const t=await P(cb=>d.transaction(F.ISOLATION_READ_COMMITTED,cb));
 try{ await P(cb=>t.query("INSERT INTO BL (ID, T, B) VALUES (?, ?, ?)",[4,Buffer.from("gone"),null],cb)); }catch(e){ out.push("ins4=ERR"); }
 await P(cb=>t.rollback(cb));
 try{ const r=await P(cb=>d.query("SELECT ID, T, B FROM BL ORDER BY ID",[],cb));
   for(const row of r){ const tb=await rd(row.T); const bb=await rd(row.B);
     out.push("row"+row.ID+" T="+(tb?tb.length+":"+tb.slice(0,5).toString()+":"+tb.slice(-3).toString():"null")+" B="+(bb?bb.toString("hex"):"null")); } }
 catch(e){ out.push("sel=ERR "+e.message.split("\n")[0]); }
 d.detach(()=>{ console.log(out.join(" ")); process.exit(0); }); })().catch(e=>{console.log("FATAL "+e.message.split("\n")[0]);process.exit(1);});
EOF
e=$(DB="$DBE" PORT="$REAL" timeout 120 node "$D/fc-blobwrite.js" 2>&1); c=$(DB="$DBF" PORT="$PORT" timeout 120 node "$D/fc-blobwrite.js" 2>&1)
check "node writes three blobs and reads them back - engine and fc agree [$e]" "$c" "$e"
check "the ENGINE reads the blobs fc wrote: lengths and content" \
    "$(engf "SELECT ID, OCTET_LENGTH(T), CAST(SUBSTRING(T FROM 1 FOR 10) AS VARCHAR(10)), OCTET_LENGTH(B) FROM BL ORDER BY ID;")" \
    "1 10 hello blob 9|2 30000 abcdefghij <null>|3 0 1|"
check "...the level-1 blob's tail, off the engine's reader" \
    "$(engf "SELECT CAST(SUBSTRING(T FROM 29991 FOR 10) AS VARCHAR(10)) FROM BL WHERE ID = 2;")" "mnopqrstuv|"
check "...the binary bytes, off the engine's reader" \
    "$(engf "SELECT CAST(B AS VARCHAR(9) CHARACTER SET OCTETS) FROM BL WHERE ID = 1;")" "000102FFFE0A0D0007|"
check "...and the rolled-back insert's blob is not there" "$(engf "SELECT COUNT(*) FROM BL WHERE ID = 4;")" "0|"
ran=$((ran + 1)); g=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1)
if [ -z "$g" ]; then echo "OK   gfix -v -full finds nothing on fc's file"; else echo "DIFF gfix: $g"; fail=1; fi
ran=$((ran + 1)); if "$GBAK" -b -user "$U" -pas "$P" "$DBF" "$D/fc-blobwrite.fbk" >/dev/null 2>&1; then
    echo "OK   gbak -b carries fc's file"; else echo "DIFF gbak -b failed"; fail=1; fi
ran=$((ran + 1)); n=$(grep -c 'materialised into relation' "$LOG")
if [ "$n" -ge 4 ]; then echo "OK   coverage: $n temp blobs materialised at the store"; else echo "DIFF coverage: [$n] materialised"; fail=1; fi
echo "ran $ran checks"
exit $fail
