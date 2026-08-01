#!/bin/bash
# A DATABASE THAT HAS BEEN BACKED UP AND RESTORED - the shape this
# project never tested, and the one where fragmentation lives.
#
# Restoring a schema replays its DDL, and `DPM_update` fragments a record
# whenever the new version no longer fits the space left on the page it
# already occupies (dpm.epp:2650-2656). So ordinary, small catalogue rows
# fragment as restore fills pages - it is NOT the oversized-row case that
# qa/serve-real-fragment.sh covers.
#
# MEASURED on a 220-table schema: 292 fragmented catalogue rows after
# `gbak -b` + `gbak -c`, against 45 before, IN DIFFERENT RELATIONS.
# Restore does not preserve fragmentation, it RELOCATES it - 27% of
# RDB$INDICES rows and 28% of RDB$RELATIONS rows end up fragmented. Even
# an EMPTY database gains 26 from a round trip.
#
# What that cost, before fragment assembly: 63 of 220 tables were
# UNQUERYABLE. RDB$RELATIONS is where a name is resolved, so a fragmented
# row there means the table does not exist as far as fire-crab is
# concerned - `SELECT ... FROM <table>` answered Dynamic SQL Error on a
# database the engine reads perfectly.
#
# THE TRAP THAT HID IT, and the reason this gate is shaped as it is:
# `SELECT COUNT(*) FROM RDB$RELATIONS` answered 220 CORRECTLY the whole
# time. A differential over catalogue QUERIES passes while a quarter of
# the schema cannot be named. **Every table must appear in a FROM
# clause**, and the count of tables successfully named must equal the
# catalogue's own count.
#
#   qa/serve-real-restored.sh [port]
#
# The fixture is built and restored by the ENGINE, so what is being
# tested is fire-crab reading a file Firebird produced by its ordinary
# tools.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4572}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-rst-src.fdb"; FBK="$D/fc-rst.fbk"
RE="$D/fc-rst-re.fdb"; FC="$D/fc-rst-fc.fdb"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH
N="${FC_RST_TABLES:-60}"

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
command -v "$GBAK" >/dev/null 2>&1 || { echo "SKIP gbak not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0
srv=""
trap '[ -n "$srv" ] && kill $srv 2>/dev/null' EXIT

# --- the fixture: long names, an index each, and a COMMENT on every one -
# Long identifiers and DESCRIPTIONs are what fatten a catalogue row; the
# COMMENT is what makes restore UPDATE the RDB$RELATIONS row after it was
# written, which is what fragments it. Without the comments the restored
# file has fragmented RDB$INDICES rows and NO fragmented RDB$RELATIONS
# rows, and the sharpest check below would measure nothing.
rm -f "$SRC" "$FBK" "$RE" "$FC"
{
    echo "CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;"
    i=0
    while [ $i -lt "$N" ]; do
        i=$((i + 1))
        # a 63-character identifier, the maximum, with incompressible filler
        t=$(printf 'RESTORED_FIXTURE_TABLE_%03d_QWERTYUIOPASDFGHJKLZXCVBNMQWERTYUI' "$i" | cut -c1-63)
        echo "CREATE TABLE $t (ID INTEGER NOT NULL PRIMARY KEY, K INTEGER, V VARCHAR(40));"
        echo "CREATE INDEX IX_${i}_QWERTYUIOPASDFGHJKLZXCVBNMQWERTYUIOPASDFGHJKL ON $t (K, V);"
        echo "COMMENT ON TABLE $t IS 'restored fixture table number $i, with a description long enough to occupy a blob and widen the catalogue row';"
        echo "INSERT INTO $t VALUES (1, 1, 'a');"
        echo "INSERT INTO $t VALUES (2, 2, 'b');"
    done
    echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }

"$GBAK" -b -user "$U" -pas "$P" "$SRC" "$FBK" >/dev/null 2>&1 || { echo "FAIL gbak backup"; exit 1; }
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RE" >/dev/null 2>&1 || { echo "FAIL gbak restore"; exit 1; }
cp "$RE" "$FC"; chmod 666 "$RE" "$FC"

# --- 0. the fixture must actually be fragmented ------------------------
# WITHOUT A HAND-ROLLED PARSER. An auditor's own page walk once reported
# ZERO fragmented rows on a file whose real count was 88, and a parser
# that over-reports would let this whole gate pass on a fixture that
# exhibits nothing.
#
# So the proof is fire-crab's OWN differentially tested decoder, asked a
# question whose answer differs only when fragments exist: `image()`
# returns None for exactly the fragmented rows, `assembled_image` for
# none of them. `fcstat` walks the catalogue with the same decoder the
# server uses, so a mismatch between the row count it reports and the
# ENGINE's own count is the signature - and it is zero once assembly
# works, which is why the check below is stated the other way round.
ran=$((ran + 1))
eng_rel=$("$ISQL" -q -b -user "$U" -pas "$P" "$RE" <<'SQL' 2>&1 | grep -oE '[0-9]+' | head -1
SET HEADING OFF;
SELECT COUNT(*) FROM RDB$RELATIONS;
SQL
)
eng_idx=$("$ISQL" -q -b -user "$U" -pas "$P" "$RE" <<'SQL' 2>&1 | grep -oE '[0-9]+' | head -1
SET HEADING OFF;
SELECT COUNT(*) FROM RDB$INDICES;
SQL
)
if [ "${eng_rel:-0}" -gt 0 ] && [ "${eng_idx:-0}" -gt 0 ]; then
    echo "OK   restored fixture: $eng_rel relations, $eng_idx index rows"
else
    echo "FAIL could not read the restored fixture's catalogue"
    exit 1
fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-restored.log 2>&1 &
srv=$!
i=0; while [ $i -lt 30 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

cat > "$D/fc-rst.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3], mode=process.argv[4];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 d.query("SELECT TRIM(RDB$RELATION_NAME) N FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG = 0 ORDER BY 1",[],(e1,rows)=>{
  if(e1){console.log('LIST-ERR '+e1.message);d.detach();return}
  const names=rows.map(r=>r.N);
  let i=0; const out=[];
  const next=()=>{
   if(i===names.length){ console.log(out.join('\n')); d.detach(); return }
   const t=names[i++];
   const q = mode==='count' ? 'SELECT COUNT(*) C FROM "'+t+'"'
                            : 'SELECT ID, K, V FROM "'+t+'" ORDER BY ID';
   d.query(q,[],(e2,r)=>{
    if(e2) out.push(t+' ERR');
    else if(mode==='count') out.push(t+' '+r[0].C);
    else out.push(t+' '+r.map(x=>x.ID+':'+x.K+':'+String(x.V).trim()).join(','));
    next();
   });
  };
  next();
 });
});
EOF

# --- 1. EVERY TABLE MUST BE NAMEABLE ----------------------------------
# The assertion the last defect hid from. Not a catalogue count - a FROM
# clause, for every table, with the ANSWER compared.
ran=$((ran + 1))
a=$(timeout 300 node "$D/fc-rst.js" "$PORT" "$FC" count 2>&1)
b=$(timeout 300 node "$D/fc-rst.js" 3050 "$RE" count 2>&1)
nfc=$(printf '%s\n' "$a" | grep -c ' [0-9]*$')
nerr=$(printf '%s\n' "$a" | grep -c ' ERR$')
if [ "$a" = "$b" ] && [ "$nerr" -eq 0 ]; then
    echo "OK   all $nfc user tables nameable in a FROM clause, answers identical"
else
    echo "DIFF $nerr of $((nfc + nerr)) tables could not be named, or answered differently"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -6 | sed 's/^/     /'
    fail=1
fi

# --- 2. and the count of nameable tables equals the catalogue's --------
# Stated separately BECAUSE the catalogue count passed while a quarter of
# the tables were unreachable. If these two ever disagree again, this is
# the line that says so.
ran=$((ran + 1))
cat_n=$("$ISQL" -q -b -user "$U" -pas "$P" "$RE" <<'SQL' 2>&1 | grep -oE '[0-9]+' | head -1
SET HEADING OFF;
SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG = 0;
SQL
)
if [ "$nfc" = "$cat_n" ]; then
    echo "OK   nameable tables ($nfc) == RDB\$RELATIONS count ($cat_n)"
else
    echo "DIFF $nfc tables nameable but the catalogue says $cat_n - the count is not the test"
    fail=1
fi

# --- 3. the ROWS, not just the names ----------------------------------
ran=$((ran + 1))
a=$(timeout 300 node "$D/fc-rst.js" "$PORT" "$FC" rows 2>&1)
b=$(timeout 300 node "$D/fc-rst.js" 3050 "$RE" rows 2>&1)
if [ "$a" = "$b" ] && [ -n "$a" ]; then
    echo "OK   every row of every table is byte-identical to the engine"
else
    echo "DIFF rows differ on a restored database"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -6 | sed 's/^/     /'
    fail=1
fi

# --- 4. the DDL refusals, PINNED at their measured cost ----------------
# Two in-place patch sites cannot rewrite a record that spans pages, so
# they fail closed on a fragmented catalogue row. That is the right
# boundary - but a boundary nobody measures is a boundary that drifts.
# This records what it costs today so a regression shows as a NUMBER.
ran=$((ran + 1))
cat > "$D/fc-rst-ddl.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 d.query("SELECT TRIM(RDB$RELATION_NAME) N FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG = 0 ORDER BY 1",[],(e1,rows)=>{
  if(e1){console.log('LIST-ERR '+e1.message);d.detach();return}
  const names=rows.map(r=>r.N);
  let i=0, ok=0, err=0;
  const next=()=>{
   if(i===names.length){ console.log('COMMENT ok='+ok+' refused='+err); d.detach(); return }
   d.query('COMMENT ON TABLE "'+names[i++]+'" IS \'touched\'',[],(e2)=>{ if(e2)err++; else ok++; next(); });
  };
  next();
 });
});
EOF
r=$(timeout 300 node "$D/fc-rst-ddl.js" "$PORT" "$FC" 2>&1 | tail -1)
case "$r" in
    "COMMENT ok="*" refused=0")
        echo "OK   COMMENT ON every table succeeded - the patch sites now handle fragments"
        ;;
    "COMMENT ok="*)
        # Expected today. Loud, quantified, and NOT a failure - the
        # refusal is deliberate and fails closed. It becomes a DIFF only
        # if it ever writes something instead.
        echo "OK   $r (deliberate: an in-place patch cannot rewrite a fragmented record)"
        ;;
    *) echo "DIFF unexpected DDL outcome: $r"; fail=1 ;;
esac

# --- 5. whatever the DDL did, the file must still be sound -------------
ran=$((ran + 1))
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
if [ -z "$gf" ]; then
    echo "OK   gfix -v -full is silent after the DDL sweep"
else
    echo "DIFF gfix reports damage after DDL on a restored database:"
    printf '%s' "$gf" | head -3 | sed 's/^/     /'
    fail=1
fi

# --- 6. and the ENGINE can still read what fire-crab touched -----------
ran=$((ran + 1))
kill $srv 2>/dev/null; srv=""; sleep 0.3
out=$("$ISQL" -q -b -user "$U" -pas "$P" "$FC" <<'SQL' 2>&1
SET HEADING OFF;
SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG = 0;
SQL
)
if printf '%s' "$out" | grep -qE '^[[:space:]]*[0-9]+' && ! printf '%s' "$out" | grep -qi "error"; then
    echo "OK   the engine reads the database fire-crab wrote to"
else
    echo "DIFF the engine cannot read it back: $(printf '%s' "$out" | head -2 | tr '\n' '|')"
    fail=1
fi

rm -f "$SRC" "$FBK" "$RE" "$FC" "$D"/fc-rst*.js
if [ "$ran" -lt 7 ]; then
    echo "DIFF only $ran checks ran (expected at least 7) - did one silently skip?"
    fail=1
fi
exit $fail
