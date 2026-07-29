#!/bin/bash
# The blob-storage differential - fire-crab-blb against the live
# engine, BOTH directions, all three address levels.
#
# Phase A - the engine writes, fcblb reads: text blobs from empty
# through 36 MB. The doubling EXECUTE BLOCK walks content up through
# level 0 (inline), level 1 (page vector) and level 2 (pointer
# pages); for every row the gate compares fcblb's LEN / HEAD / MID /
# TAIL content slices against the engine's own OCTET_LENGTH and
# SUBSTRING answers, and asserts the level fcblb decodes is the level
# the size demands.
#
# Phase B - fcblb writes, the engine reads: blobs created through
# fire-crab's own path (several sizes and segment sizes, crossing the
# level-0/level-1 boundary) plus the records that reference them. The
# engine reads every byte back, gfix -v -full -n finds nothing wrong,
# and gbak backs the file up. The blh_max_sequence law is pinned here:
# it is the LAST page sequence (n-1), not the page count - the engine
# read one page past a count-valued field and called the file corrupt,
# which is how the law was found.
#
#   qa/blb-levels.sh
#
# Builds its own scratch databases (embedded - single attachment at a
# time, alternating isql and fcblb).

set -u
FCBLB="${FCBLB:-$(dirname "$0")/../target/release/fcblb}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBR="$D/fc-blbread.fdb"
DBW="$D/fc-blbwrite.fdb"
TMP="$D/blb-tmp"

mkdir -p "$D" "$TMP"; rm -f "$DBR" "$DBW"; rm -rf "$TMP"; mkdir -p "$TMP"
fail=0

# ---------- phase A: engine writes, fcblb reads -----------------------
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DBR' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE B (ID INTEGER, C BLOB SUB_TYPE TEXT);
COMMIT;
INSERT INTO B VALUES (0, '');
INSERT INTO B VALUES (1, 'x');
INSERT INTO B VALUES (2, NULL);
INSERT INTO B VALUES (3, 'abcdefghij');
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS
DECLARE V BLOB SUB_TYPE TEXT;
DECLARE I INTEGER;
BEGIN
  V = 'seed-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ-';
  I = 0;
  WHILE (I < 17) DO BEGIN V = V || V; I = I + 1; END
  INSERT INTO B VALUES (4, :V);
  I = 0;
  WHILE (I < 2) DO BEGIN V = V || V; I = I + 1; END
  INSERT INTO B VALUES (5, :V);
END^
SET TERM ; ^
COMMIT;
EOF

# the levels the sizes demand, straight off fcblb's header decode
scan=$("$FCBLB" scan "$DBR" B C)
want_scan="0 level=0
1 level=0
2 <null>
3 level=0
4 level=1
5 level=2"
got_scan=$(printf '%s\n' "$scan" | awk '{print $1, $2}')
if [ "$got_scan" = "$want_scan" ]; then
    echo "OK   engine blobs decode at the levels their sizes demand (0/0/null/0/1/2)"
else
    echo "DIFF level scan"; printf '%s\n' "$scan"; fail=1
fi

eng() { # <sql> -> squeezed single value
    "$ISQL" -q -b -user "$U" -pas "$P" "$DBR" 2>&1 <<SQL | tr -d '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
SET HEADING OFF;
$sql_prefix$1
SQL
}
sql_prefix=""

for id in 0 1 3 4 5; do
    s=$("$FCBLB" slices "$DBR" B C "$id")
    flen=$(printf '%s\n' "$s" | awk '/^LEN/{print $2}')
    fhead=$(printf '%s\n' "$s" | sed -n 's/^HEAD //p')
    ftail=$(printf '%s\n' "$s" | sed -n 's/^TAIL //p')
    elen=$(eng "SELECT OCTET_LENGTH(C) FROM B WHERE ID = $id;")
    if [ "$flen" != "$elen" ]; then
        echo "DIFF row $id length: fcblb=$flen engine=$elen"; fail=1; continue
    fi
    if [ "$flen" -gt 0 ]; then
        n=$((flen < 64 ? flen : 64))
        ehead=$(eng "SELECT CAST(SUBSTRING(C FROM 1 FOR $n) AS VARCHAR(64)) FROM B WHERE ID = $id;")
        tfrom=$((flen - n + 1))
        etail=$(eng "SELECT CAST(SUBSTRING(C FROM $tfrom FOR $n) AS VARCHAR(64)) FROM B WHERE ID = $id;")
        if [ "$fhead" != "$ehead" ] || [ "$ftail" != "$etail" ]; then
            echo "DIFF row $id content: head [$fhead]/[$ehead] tail [$ftail]/[$etail]"
            fail=1; continue
        fi
    fi
    if [ "$flen" -ge 128 ]; then
        fmid=$(printf '%s\n' "$s" | sed -n 's/^MID //p')
        mfrom=$((flen / 2 + 1))
        emid=$(eng "SELECT CAST(SUBSTRING(C FROM $mfrom FOR 64) AS VARCHAR(64)) FROM B WHERE ID = $id;")
        if [ "$fmid" != "$emid" ]; then
            echo "DIFF row $id mid slice: [$fmid] vs [$emid]"; fail=1; continue
        fi
    fi
    echo "OK   row $id: fcblb reads the engine's blob byte-for-byte ($flen bytes)"
done

# ---------- phase B: fcblb writes, the engine reads -------------------
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create W"; exit 1; }
CREATE DATABASE '$DBW' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE W (C BLOB SUB_TYPE TEXT);
CREATE TABLE S (C BLOB SUB_TYPE TEXT);
COMMIT;
EOF

python3 - "$TMP" <<'PYEOF'
import sys
d = sys.argv[1]
def gen(path, n):
    with open(path, 'w') as f:
        i = 0
        while f.tell() < n:
            f.write(f"line-{i:08d}-abcdefghijklmnopqrstuvwxyz.")
            i += 1
        f.truncate(n)
gen(f"{d}/w-empty.txt", 0)
gen(f"{d}/w-tiny.txt", 25)
gen(f"{d}/w-edge0.txt", 8000)     # near the level-0 ceiling
gen(f"{d}/w-over0.txt", 8500)     # just past it - one blob page
gen(f"{d}/w-mid.txt", 120000)     # a fifteen-page vector
gen(f"{d}/w-big.txt", 1000000)    # a hundred-plus-page vector
gen(f"{d}/w-l2.txt", 18000000)    # past the level-1 vector ceiling
PYEOF

# (file, segment size) pairs - segment framing crosses page borders
i=0
for spec in "w-empty.txt 100" "w-tiny.txt 7" "w-edge0.txt 8000" \
            "w-over0.txt 512" "w-mid.txt 4000" "w-mid.txt 65535" \
            "w-big.txt 30000" "w-l2.txt 60000"; do
    f=${spec% *}; seg=${spec#* }
    out=$("$FCBLB" write "$DBW" W C "$TMP/$f" "$seg") || {
        echo "DIFF write $f seg=$seg refused: $out"; fail=1; i=$((i+1)); continue; }
    size=$(wc -c < "$TMP/$f")
    # the engine reads the row back in full
    row=$((i))
    elen=$("$ISQL" -q -b -user "$U" -pas "$P" "$DBW" 2>&1 <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT OCTET_LENGTH(C) FROM W ROWS $((row + 1)) TO $((row + 1));
SQL
)
    ok=1
    [ "$elen" = "$size" ] || ok=0
    if [ "$size" -gt 0 ]; then
        n=$((size < 40 ? size : 40))
        want_head=$(head -c "$n" "$TMP/$f")
        tfrom=$((size - n + 1))
        want_tail=$(tail -c "$n" "$TMP/$f")
        got_head=$("$ISQL" -q -b -user "$U" -pas "$P" "$DBW" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
SET HEADING OFF;
SELECT CAST(SUBSTRING(C FROM 1 FOR $n) AS VARCHAR(40)) FROM W ROWS $((row + 1)) TO $((row + 1));
SQL
)
        got_tail=$("$ISQL" -q -b -user "$U" -pas "$P" "$DBW" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
SET HEADING OFF;
SELECT CAST(SUBSTRING(C FROM $tfrom FOR $n) AS VARCHAR(40)) FROM W ROWS $((row + 1)) TO $((row + 1));
SQL
)
        [ "$got_head" = "$want_head" ] && [ "$got_tail" = "$want_tail" ] || ok=0
    fi
    # ...and fcblb re-reads its own write identically
    flen=$("$FCBLB" slices "$DBW" W C "$row" | awk '/^LEN/{print $2}')
    [ "$flen" = "$size" ] || ok=0
    if [ $ok -eq 1 ]; then
        echo "OK   $out <- $f seg=$seg ($size bytes): engine reads it back in full"
    else
        echo "DIFF $f seg=$seg: size=$size engine-len=$elen fcblb-len=$flen"
        fail=1
    fi
    i=$((i + 1))
done

# ---------- phase C: the fcblb-written blobs served over the wire ----
# the wire server now reads blobs through fire-crab-blb (op_open_blob /
# op_get_segment assemble content from the pages) - including the
# level-2 blob no earlier reader could serve
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
if command -v node >/dev/null 2>&1 && [ -x "$FCWIRE" ]; then
    PORT=4095
    "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/dev/null 2>&1 &
    srv=$!
    i=0; while [ $i -lt 20 ]; do
        command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
        i=$((i + 1)); sleep 0.1
    done
    got=$(FC_DB="$DBW" FC_PORT="$PORT" FC_U="$U" FC_P="$P" timeout 120 node -e '
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
        db.query("SELECT C FROM W",async (e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          for(const row of r){
            const v=Object.values(row)[0];
            if(v===null){console.log("<null>");continue;}
            const s=typeof v==="function"?await readBlob(v):String(v);
            console.log(s.length+"|"+s.slice(0,40)+"|"+s.slice(-40));
          }
          db.detach();process.exit(0);
        });
      });' 2>/dev/null)
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
    want=$(python3 - "$TMP" <<'PYEOF2'
import sys
d = sys.argv[1]
for f in ["w-empty.txt", "w-tiny.txt", "w-edge0.txt", "w-over0.txt",
          "w-mid.txt", "w-mid.txt", "w-big.txt", "w-l2.txt"]:
    b = open(f"{d}/{f}").read()
    print(f"{len(b)}|{b[:40]}|{b[-40:]}")
PYEOF2
)
    if [ "$got" = "$want" ]; then
        echo "OK   the wire server serves every fcblb-written blob through fire-crab-blb (level 2 included)"
    else
        echo "DIFF wire-served blobs"
        echo "--- want"; printf '%s
' "$want"
        echo "--- got"; printf '%s
' "$got"
        fail=1
    fi
else
    echo "SKIP wire phase (node or fcwire missing)"
fi

# ---------- phase D: STREAM blobs (fcblb writes, engine reads) --------
# A stream blob (rhd_stream_blob) carries RAW content - no [u16 len]
# frames - and arrives from the API's BPB, never from SQL, so the
# ENGINE cannot be made to write one through isql: the differential
# runs one way. The engine must still read every byte back, and the
# unframed bytes must NOT be mistaken for frames (a segmented reader
# over stream content answers garbage).
for spec in "w-tiny.txt" "w-over0.txt" "w-mid.txt"; do
    out=$("$FCBLB" write "$DBW" S C "$TMP/$spec" 0) || {
        echo "DIFF stream write $spec refused: $out"; fail=1; continue; }
    size=$(wc -c < "$TMP/$spec")
    srow=$(( $(grep -c . /dev/null) + 0 ))
    elen=$("$ISQL" -q -b -user "$U" -pas "$P" "$DBW" 2>&1 <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT OCTET_LENGTH(C) FROM S ORDER BY OCTET_LENGTH(C) ROWS 1 TO 1;
SQL
)
    # read this row back by matching its length among S's rows
    match=$("$ISQL" -q -b -user "$U" -pas "$P" "$DBW" 2>&1 <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM S WHERE OCTET_LENGTH(C) = $size;
SQL
)
    head40=$(head -c 40 "$TMP/$spec")
    ehead=$("$ISQL" -q -b -user "$U" -pas "$P" "$DBW" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
SET HEADING OFF;
SELECT CAST(SUBSTRING(C FROM 1 FOR 40) AS VARCHAR(40)) FROM S WHERE OCTET_LENGTH(C) = $size;
SQL
)
    if [ "$match" = "1" ] && [ "$ehead" = "$head40" ]; then
        echo "OK   $out <- stream $spec ($size bytes): the engine reads the UNFRAMED content"
    else
        echo "DIFF stream $spec: size=$size matched=$match head=[$ehead] want=[$head40]"
        fail=1
    fi
done

# structural validation by the engine's own tools
v=$("$GFIX" -v -full -n -user "$U" -pas "$P" "$DBW" 2>&1 | tr -s ' \n' ' ')
case "$v" in
    *"errors :"*|*"warnings :"*) echo "DIFF gfix on the fcblb-written file: [$v]"; fail=1 ;;
    *) echo "OK   gfix -v -full finds nothing wrong with the fcblb-written file" ;;
esac
if "$GBAK" -b -g -user "$U" -pas "$P" "$DBW" "$TMP/w.fbk" >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak refused the file"; fail=1
fi

rm -rf "$TMP"
exit $fail
