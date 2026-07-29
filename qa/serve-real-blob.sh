#!/bin/bash
# The server serves BLOB CONTENT over the wire. Blob columns are
# described SQL_BLOB, rows carry the 8-byte on-disk blob id, and the
# client fetches the content through the blob ops - op_open_blob(2) /
# op_get_segment / op_close_blob - which fire-crab answers by assembling
# the blob from the pages through fire-crab-blb (levels 0, 1 AND 2,
# segment framing stripped for segmented blobs, raw for stream blobs).
# This is the first differential on blob CONTENT (diff-rows compared
# only blob presence): node-firebird's assembled text must equal what
# isql reads through the engine - including a >page-size level-1 blob
# checked by length, head and tail, an empty blob, a NULL blob, and a
# SYSTEM blob (RDB$TRIGGERS.RDB$TRIGGER_SOURCE, decoded through the
# inc-24 computed system format).
#
#   qa/serve-real-blob.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4061}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/blobwire_src.fdb"; CLEAN="$DIR/blobwire_clean.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE B (ID INTEGER, T BLOB SUB_TYPE TEXT);
SET TERM ^;
CREATE TRIGGER TRG_B FOR B BEFORE DELETE AS BEGIN END^
SET TERM ;^
COMMIT;
INSERT INTO B VALUES (1, 'hello blob world');
INSERT INTO B VALUES (2, NULL);
INSERT INTO B VALUES (3, '');
INSERT INTO B VALUES (4, CAST(LPAD('', 30000, 'abcdefghij') AS BLOB SUB_TYPE TEXT));
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/blobwire.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/blobwire.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-blob.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# rows printed col|col|...; blob cells arrive as FETCH FUNCTIONS in the
# classic node-firebird API - the harness invokes each (the driver then
# runs op_open_blob/op_get_segment/op_close_blob against fire-crab) and
# prints the assembled text; FC_SLICE prints length/head/tail instead
node_once() {
    FC_DB="$CLEAN" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" FC_SLICE="${2:-}" timeout 20 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      const readBlob=(fn)=>new Promise((res,rej)=>{
        fn((err,name,e)=>{
          if(err){rej(err);return;}
          const chunks=[];
          e.on("data",(c)=>chunks.push(Buffer.isBuffer(c)?c:Buffer.from(c)));
          e.on("end",()=>res(Buffer.concat(chunks).toString("utf8")));
          e.on("error",rej);
        });
      });
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,async (e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          try{
            if(!r||r.length===0)console.log("<no rows>");
            else for(const row of r){
              const vals=[];
              for(const v of Object.values(row)){
                if(v===null){vals.push("<null>");continue;}
                const s=typeof v==="function"?await readBlob(v)
                       :Buffer.isBuffer(v)?v.toString("utf8"):String(v);
                vals.push(process.env.FC_SLICE?s.length+"|"+s.slice(0,60)+"|"+s.slice(-60)
                                              :s.replace(/\s+$/,""));
              }
              console.log(vals.join("|"));
            }
          }catch(e3){console.log("CONN_ERR");db.detach();process.exit(1);}
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1" "${2:-}")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

isql_q() {
    printf 'SET HEADING OFF;\n%s\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$CLEAN" | strip | grep -v '^$'
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     want: $3"
        echo "     got:  $2"
        fail=1
    fi
}

# small blobs: content, NULL and empty - fetched through the blob ops
check "blob content, NULL and empty" \
    "$(node_run "SELECT ID, T FROM B WHERE ID < 4 ORDER BY ID")" \
    "$(isql_q "SELECT ID || '|' || COALESCE(CAST(T AS VARCHAR(80)), '<null>') FROM B WHERE ID < 4 ORDER BY ID;")"

# the level-1 blob: 30000 bytes across multiple blob pages - length,
# head and tail must survive the page-vector assembly
check "level-1 blob: length, head, tail" \
    "$(node_run "SELECT T FROM B WHERE ID = 4" slice)" \
    "$(isql_q "SELECT CHAR_LENGTH(T) || '|' || CAST(SUBSTRING(T FROM 1 FOR 60) AS VARCHAR(60)) || '|' || CAST(SUBSTRING(T FROM 29941 FOR 60) AS VARCHAR(60)) FROM B WHERE ID = 4;")"

# SELECT * expands the blob column like any other
check "SELECT * with a blob column" \
    "$(node_run "SELECT * FROM B WHERE ID = 1")" \
    "$(isql_q "SELECT ID || '|' || CAST(T AS VARCHAR(80)) FROM B WHERE ID = 1;")"

# a SYSTEM blob: the trigger source, through the computed system format
check "system blob (RDB\$TRIGGER_SOURCE)" \
    "$(node_run "SELECT RDB\$TRIGGER_SOURCE FROM RDB\$TRIGGERS WHERE RDB\$TRIGGER_NAME = 'TRG_B'")" \
    "$(isql_q "SELECT CAST(RDB\$TRIGGER_SOURCE AS VARCHAR(200)) FROM RDB\$TRIGGERS WHERE RDB\$TRIGGER_NAME = 'TRG_B';")"

exit $fail
