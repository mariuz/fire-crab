#!/bin/bash
# A RECORD TOO BIG FOR A PAGE, which fire-crab could not read at all.
#
# Firebird stores a record that does not fit one page as a HEAD carrying
# `rhd_incomplete` plus continuation fragments, chained by
# `rhdf_f_page`/`rhdf_f_line`. That header is NINE BYTES LONGER than an
# ordinary one - data at 22, not 13 - and fire-crab chose its offset on
# LONG_TRANUM alone, so every fragment's payload began ON THE POINTER.
# The RLE decoder rejected the result, so the row was simply DROPPED.
#
# What that cost, all measured:
#
#   * 17 of 69 indexes invisible to the optimizer on a 99-relation
#     database - `WHERE K = 5` planned NATURAL where the engine planned
#     INDEX, because the RDB$INDEX_SEGMENTS rows naming them were
#     fragmented;
#   * 63 of 220 TABLES unqueryable after an ordinary gbak backup and
#     restore - `RDB$RELATIONS` is where names are resolved, so a
#     fragmented row there means the table does not exist as far as
#     fire-crab is concerned;
#   * CREATE INDEX silently omitting fragmented rows into an index the
#     REAL engine then reads and finds nothing in.
#
# WHY NO GATE EVER CAUGHT IT: nothing here fragments. Every fixture is a
# handful of small rows. This gate exists to make a record fragment ON
# PURPOSE, and doing that is harder than it sounds - two earlier attempts
# failed:
#
#   1. `LPAD('', 4000, 'x')` COMPRESSES AWAY. The record RLE collapses a
#      run of equal bytes, so the row fits after all. The payload here is
#      `RPAD('', n, 'ab')` - "abab..." - which the codec cannot touch
#      (sqz.cpp needs three equal bytes in a row).
#   2. `PAGE_SIZE 4096` IS NOT 4096. Firebird 6 clamps silently to
#      MIN_PAGE_SIZE (ods.h:228 = 8192), so an "8 KB row in a 4 KB page"
#      experiment produces no fragments whatsoever. That one cost an hour.
#
# The threshold is dpm.epp:2383-2392:
#     max_data = page_size - sizeof(data_page)(28) - RHD_SIZE(13)
#     packed length > max_data  ->  store_big_record()
# which at 8192 is 8151 bytes. This gate brackets it from both sides.
#
#   qa/serve-real-fragment.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4565}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
RE="$D/fc-frag-re.fdb"; FC="$D/fc-frag-fc.fdb"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0
srv=""
trap '[ -n "$srv" ] && kill $srv 2>/dev/null' EXIT

rm -f "$RE" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }
CREATE DATABASE '$RE' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET NONE;
-- BELOW the threshold: one page, no fragment. The control.
CREATE TABLE SMALL (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(8000) CHARACTER SET OCTETS);
-- ABOVE it: every row fragments.
CREATE TABLE BIG (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(8146) CHARACTER SET OCTETS);
-- Two long columns, so the row needs more than one continuation.
CREATE TABLE HUGE (ID INTEGER NOT NULL PRIMARY KEY,
                   A VARCHAR(8000) CHARACTER SET OCTETS,
                   B VARCHAR(8000) CHARACTER SET OCTETS,
                   C VARCHAR(8000) CHARACTER SET OCTETS);
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER; BEGIN
  I = 0;
  WHILE (I < 5) DO BEGIN
    I = I + 1;
    -- RPAD with a TWO-character pattern: "abab..." defeats the record
    -- RLE, which is what makes the row physically large.
    INSERT INTO SMALL VALUES (:I, RPAD('', 8000, 'ab'));
    INSERT INTO BIG   VALUES (:I, RPAD('', 8146, 'ab'));
    INSERT INTO HUGE  VALUES (:I, RPAD('', 8000, 'ab'),
                                  RPAD('', 8000, 'cd'),
                                  RPAD('', 8000, 'ef'));
  END
END^
SET TERM ; ^
COMMIT;
-- an UPDATE on a fragmented row, so a back version fragments too
UPDATE BIG SET V = RPAD('', 8146, 'xy') WHERE ID = 3;
COMMIT;
EOF
cp "$RE" "$FC"; chmod 666 "$RE" "$FC"

# --- 0. the fixture must actually fragment, or this gate proves nothing -
ran=$((ran + 1))
frags=$(python3 - "$FC" <<'PY' 2>/dev/null
import sys, struct
f = open(sys.argv[1], 'rb').read()
ps = struct.unpack_from('<H', f, 16)[0]
if ps < 1024: ps = 8192
inc = 0
for off in range(0, len(f) - ps + 1, ps):
    if f[off] != 5:  # pag_data
        continue
    count = struct.unpack_from('<H', f, off + 22)[0]
    for i in range(count):
        o, l = struct.unpack_from('<HH', f, off + 24 + i * 4)
        if l == 0 or o + 12 > ps:
            continue
        fl = struct.unpack_from('<H', f, off + o + 10)[0]
        if fl & 8:   # rhd_incomplete
            inc += 1
print(inc)
PY
)
if [ "${frags:-0}" -ge 10 ]; then
    echo "OK   the fixture fragments: $frags records carry rhd_incomplete"
else
    echo "FAIL the fixture produced only ${frags:-0} fragmented records - it proves nothing."
    echo "     (PAGE_SIZE below 8192 is silently clamped; RPAD with one repeated"
    echo "      character compresses away. Both make a 'big' row fit on a page.)"
    exit 1
fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fragment.log 2>&1 &
srv=$!
i=0; while [ $i -lt 30 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

cat > "$D/fc-frag.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3], q=process.argv[4];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 d.query(q,[],(e2,r)=>{
  if(e2){console.log('ERR '+e2.message.split('\n')[0]);d.detach();return}
  for(const row of (r||[]))
    console.log(Object.keys(row).map(k=>{
      const v=row[k];
      if(v===null) return k+'=NULL';
      if(typeof v==='string') return k+'=len'+v.length+':'+v.slice(0,8);
      if(Buffer.isBuffer(v)) return k+'=buf'+v.length+':'+v.slice(0,4).toString('hex');
      return k+'='+v;
    }).join(' '));
  d.detach();
 });
});
EOF

both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(timeout 60 node "$D/fc-frag.js" "$PORT" "$FC" "$2" 2>&1)
    b=$(timeout 60 node "$D/fc-frag.js" 3050 "$RE" "$2" 2>&1)
    if [ "$a" = "$b" ] && [ -n "$a" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire: $(printf '%s' "$a" | head -3 | tr '\n' '|')"
        echo "     engine: $(printf '%s' "$b" | head -3 | tr '\n' '|')"
        fail=1
    fi
}

# --- 1. the rows themselves ------------------------------------------
# THE CHECK THAT WOULD HAVE CAUGHT ALL OF IT. Before assembly these
# returned ZERO rows from fire-crab and five from the engine.
both "every fragmented row is returned"        "SELECT ID FROM BIG ORDER BY ID"
both "and its VALUE is whole, not truncated"   "SELECT ID, OCTET_LENGTH(V) L FROM BIG ORDER BY ID"
both "a multi-fragment row (three long columns)" \
     "SELECT ID, OCTET_LENGTH(A) LA, OCTET_LENGTH(B) LB, OCTET_LENGTH(C) LC FROM HUGE ORDER BY ID"
both "the unfragmented control is unaffected"  "SELECT ID, OCTET_LENGTH(V) L FROM SMALL ORDER BY ID"
both "COUNT over a fragmented table"           "SELECT COUNT(*) C FROM BIG"
# reads the fragmented column to DECIDE the row, not merely to return it.
# (STARTING WITH would be the natural test and is not in this predicate
# parser - an unrelated gap, recorded in the roadmap rather than papered
# over by picking a shape that happens to work.)
both "a predicate that READS the fragmented column" \
     "SELECT ID FROM BIG WHERE V IS NOT NULL ORDER BY ID"
# the row that was UPDATEd - its back version fragments too, and a
# fragmented back version used to break the MVCC walk and drop the row
both "the updated row (a fragmented BACK version)" \
     "SELECT ID, OCTET_LENGTH(V) L FROM BIG WHERE ID = 3"

# --- 2. name resolution, which is where this hurt most ----------------
# A fragmented RDB$RELATIONS row means the table DOES NOT EXIST as far as
# fire-crab is concerned. The trap: `SELECT COUNT(*) FROM RDB$RELATIONS`
# answers CORRECTLY even then, so a gate that only diffs catalogue
# queries passes while tables are unreachable. The table must be named in
# a FROM clause.
both "every user table is reachable BY NAME"  \
     "SELECT COUNT(*) C FROM SMALL"
both "... and the catalogue agrees on how many there are" \
     "SELECT COUNT(*) C FROM RDB\$RELATIONS WHERE RDB\$SYSTEM_FLAG = 0"

# --- 3. fire-crab's own writes stay readable BY THE ENGINE -------------
ran=$((ran + 1))
w=$(timeout 60 node -e '
const fb=require("node-firebird");
fb.attach({host:"127.0.0.1",port:+process.argv[1],database:process.argv[2],
           user:"SYSDBA",password:"masterkey"},(e,d)=>{
 if(e){console.log("ATTACH-ERR");return}
 d.query("INSERT INTO BIG (ID, V) VALUES (99, ?)",["ab".repeat(4073)],(e2)=>{
  console.log(e2?("REFUSED "+e2.message.split("\n")[0]):"STORED");d.detach();});
});' "$PORT" "$FC" 2>&1)
case "$w" in
    STORED)
        out=$("$ISQL" -q -b -user "$U" -pas "$P" "$FC" <<'SQL' 2>&1
SET HEADING OFF;
SELECT ID || '|' || OCTET_LENGTH(V) FROM BIG WHERE ID = 99;
SQL
)
        if printf '%s' "$out" | grep -q "99|8146"; then
            echo "OK   the engine reads back the fragmented row fire-crab wrote"
        else
            echo "DIFF the engine cannot read fire-crab's fragmented row: $(printf '%s' "$out" | head -2 | tr '\n' '|')"
            fail=1
        fi
        ;;
    REFUSED*)
        # Refusing to WRITE a record that would fragment is a defensible
        # boundary - it is a cross-page store fire-crab does not do. It
        # is asserted here so it cannot silently become a bad write.
        echo "OK   writing a would-be-fragmented row is refused, not half-done"
        ;;
    *) echo "DIFF unexpected write outcome: $w"; fail=1 ;;
esac

# --- 4. and the file is still structurally sound ----------------------
ran=$((ran + 1))
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
if [ -z "$gf" ]; then
    echo "OK   gfix -v -full is silent on the database fire-crab touched"
else
    echo "DIFF gfix reports damage: $(printf '%s' "$gf" | head -3 | tr '\n' '|')"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$RE" "$FC" "$D/fc-frag.js"
if [ "$ran" -lt 12 ]; then
    echo "DIFF only $ran checks ran (expected at least 12) - did one silently skip?"
    fail=1
fi
exit $fail
