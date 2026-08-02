#!/bin/bash
# THE CLIENT'S DECLARED OUTPUT BLR IS A CONTRACT, and the engine enforces
# it PER ROW.
#
# libfbclient declares every text output slot with its charset
# (blr_varying2), so isql never sees any of this. node-firebird declares
# bare blr_varying, which the engine resolves to the ATTACHMENT charset:
# under the driver's default UTF8 attachment a VARCHAR(6) NONE slot
# declared at 6 bytes holds floor(6/4) = ONE character. The engine's rule
# (cvt.cpp:507-533, probed differentially):
#
#   FITS       deliver; trailing blanks TRIM SILENTLY down to the cap and
#              pad back (a VARCHAR of two spaces answers ONE space)
#   OVERFLOWS  the ROW raises "string right truncation, expected length
#              {cap}, actual {untrimmed chars}" - a CHAR counts its
#              blank padding: CHAR(5) holding 'ab' raises (1, 5)
#   TRANSLIT   a real charset != destination transliterates with NO
#              length enforcement at all (WIN1252 'abcdef' passes a
#              declared-6 slot)
#
# node-firebird 2.11.0 declares the described byte length and TRIPS all
# of this; the patched 2.14.1 widens its declarations (issue #422) and
# sees none of it. fire-crab used to discard the out-BLR entirely and
# deliver everything - every line below is the differential proof that it
# now enforces exactly what the engine enforces, through BOTH drivers.
#
#   qa/serve-real-outblr.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4574}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
RE="$D/fc-ob-re.fdb"; FC="$D/fc-ob-fc.fdb"
# the two drivers this gate is ABOUT: stock 2.11.0 (byte-length
# declarations, trips the capacity rule) and patched 2.14.1 (widened
# declarations, must keep seeing plain rows)
N211="${N211:-/home/ubuntu/conceptual-architecture-for-firebird-paper/samples/nodejs/node_modules}"
N214="${N214:-${NODE_PATH:-/home/ubuntu/work}}"

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
NODE_PATH="$N211" node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird 2.11.0 not found"; exit 0; }
NODE_PATH="$N214" node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird 2.14.1 not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0
srv=""
trap '[ -n "$srv" ] && kill $srv 2>/dev/null' EXIT

rm -f "$RE" "$FC"
# T3: 250 rows, one over-cap value at row 205 - past the driver's
# 200-row fetch batch, so the error lands MID-CURSOR after a full batch
{
    cat <<EOF
CREATE DATABASE '$RE' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY,
                V6 VARCHAR(6), C5 CHAR(5),
                U6 VARCHAR(6) CHARACTER SET UTF8,
                W6 VARCHAR(6) CHARACTER SET WIN1252,
                I INTEGER);
CREATE TABLE T2 (ID INTEGER NOT NULL PRIMARY KEY,
                 V3 VARCHAR(3),
                 O6 VARCHAR(6) CHARACTER SET OCTETS,
                 WC5 CHAR(5) CHARACTER SET WIN1252);
CREATE TABLE T3 (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(6));
CREATE TABLE TR (ID INTEGER NOT NULL PRIMARY KEY, V6 VARCHAR(6));
COMMIT;
INSERT INTO T VALUES (1, 'a',      'a',  'abcdef', 'ab',     7);
INSERT INTO T VALUES (2, 'ab',     'ab', NULL,     NULL,     NULL);
INSERT INTO T VALUES (3, 'abcdef', '',   NULL,     'abcdef', NULL);
INSERT INTO T VALUES (4, NULL,     NULL, NULL,     NULL,     NULL);
INSERT INTO T VALUES (5, '',       NULL, NULL,     NULL,     NULL);
INSERT INTO T VALUES (6, '  ',     NULL, NULL,     NULL,     NULL);
INSERT INTO T VALUES (7, 'a     ', NULL, NULL,     NULL,     NULL);
INSERT INTO T2 VALUES (1, 'a', x'4142', 'ab');
INSERT INTO T2 VALUES (2, '',  NULL,    NULL);
COMMIT;
EOF
    i=1
    while [ $i -le 250 ]; do
        if [ $i -eq 205 ]; then v=xx; else v=a; fi
        echo "INSERT INTO T3 VALUES ($i, '$v');"
        i=$((i + 1))
    done
    echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }
cp "$RE" "$FC"; chmod 666 "$RE" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-outblr.log 2>&1 &
srv=$!
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

# One statement, every row printed as ROWn col=value/len, a mid-cursor
# error as "ERR(after N rows) message" - the shape both comparison rules
# below normalise
cat > "$D/fc-ob-rows.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const q=process.argv[4], enc=process.argv[5]||'UTF8';
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey',encoding:enc},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 let n=0;
 d.sequentially(q,[],(row)=>{
  n++;
  console.log('ROW'+n+' '+Object.keys(row).map(k=>{
   const v=row[k];
   if(v===null) return k+'=NULL';
   if(Buffer.isBuffer(v)) return k+'=buf:'+v.toString('hex');
   if(typeof v==='string') return k+'='+JSON.stringify(v)+'/'+v.length;
   return k+'='+v;
  }).join(' '));
 },(err)=>{
  if(err) console.log('ERR(after '+n+' rows) '+String(err.message).replace(/\n/g,' '));
  d.detach();
 });
});
EOF

# The comparison the engine's wire behaviour dictates: rows before the
# error must MATCH EXACTLY, the error itself on its first 50 characters
# (the vector renders identically, the tail may carry driver framing)
norm() { sed -E 's/^(ERR\(after [0-9]+ rows\) .{50}).*$/\1/'; }

# <label> <sql> - the same statement through BOTH drivers against BOTH
# servers: 2.11.0 must hit the same error at the same point, 2.14.1 must
# keep its plain rows
chk() {
    ran=$((ran + 1))
    a=$(NODE_PATH="$N211" timeout 60 node "$D/fc-ob-rows.js" "$PORT" "$FC" "$2" 2>&1)
    b=$(NODE_PATH="$N211" timeout 60 node "$D/fc-ob-rows.js" 3050 "$RE" "$2" 2>&1)
    c=$(NODE_PATH="$N214" timeout 60 node "$D/fc-ob-rows.js" "$PORT" "$FC" "$2" 2>&1)
    d=$(NODE_PATH="$N214" timeout 60 node "$D/fc-ob-rows.js" 3050 "$RE" "$2" 2>&1)
    if [ "$(printf '%s' "$a" | norm)" = "$(printf '%s' "$b" | norm)" ] && [ "$c" = "$d" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire/2.11: $(printf '%s' "$a" | tail -3 | tr '\n' '|')"
        echo "     engine/2.11: $(printf '%s' "$b" | tail -3 | tr '\n' '|')"
        echo "     fcwire/2.14: $(printf '%s' "$c" | tail -3 | tr '\n' '|')"
        echo "     engine/2.14: $(printf '%s' "$d" | tail -3 | tr '\n' '|')"
        fail=1
    fi
}

# --- the capacity rule, case by probed case --------------------------
chk "a value under the cap delivers" \
    "SELECT V6 FROM T WHERE ID = 1"
chk "one over the cap raises (1, 2) on the row" \
    "SELECT V6 FROM T WHERE ID = 2"
chk "the full declared width raises (1, 6)" \
    "SELECT V6 FROM T WHERE ID = 3"
chk "NULL delivers - only its bitmap bit travels" \
    "SELECT V6 FROM T WHERE ID = 4"
chk "the empty string delivers" \
    "SELECT V6 FROM T WHERE ID = 5"
chk "zero rows deliver zero rows" \
    "SELECT V6 FROM T WHERE ID = 999"
chk "two stored blanks trim to the cap: ONE blank back" \
    "SELECT V6 FROM T WHERE ID = 6"
chk "trailing blanks trim silently: 'a     ' answers 'a'" \
    "SELECT V6 FROM T WHERE ID = 7"
chk "CHAR under the cap delivers trimmed" \
    "SELECT C5 FROM T WHERE ID = 1"
chk "CHAR counts its padding: 'ab' raises (1, 5)" \
    "SELECT C5 FROM T WHERE ID = 2"
chk "an empty CHAR answers one blank" \
    "SELECT C5 FROM T WHERE ID = 3"
chk "VARCHAR(3) has cap ZERO: 'a' raises (0, 1)" \
    "SELECT V3 FROM T2 WHERE ID = 1"
chk "... and the empty string still fits cap zero" \
    "SELECT V3 FROM T2 WHERE ID = 2"
chk "the mid-cursor raise lands after the 200-row batch" \
    "SELECT V FROM T3 ORDER BY ID"
chk "a UTF8 column is immune - its bytes are chars x 4" \
    "SELECT U6 FROM T WHERE ID = 1"
chk "a real charset transliterates with NO enforcement" \
    "SELECT W6 FROM T WHERE ID = 3"
chk "a transliterated CHAR keeps its full padded width" \
    "SELECT WC5 FROM T2 WHERE ID = 1"
chk "OCTETS is capacity-checked like NONE: (1, 2)" \
    "SELECT O6 FROM T2 WHERE ID = 1"
chk "an expression keeps its column's charset: UPPER raises" \
    "SELECT UPPER(V6) A FROM T WHERE ID = 2"
chk "a literal is ATTACHMENT-charset: 'ab' delivers" \
    "SELECT 'ab' A FROM RDB\$DATABASE"
chk "a NONE column mixed with a literal takes the attachment" \
    "SELECT V6 || 'x' A FROM T WHERE ID = 2"
chk "a user CAST is attachment-charset too" \
    "SELECT CAST('ab' AS VARCHAR(6)) A FROM RDB\$DATABASE"
chk "a non-text slot has no capacity rule" \
    "SELECT I FROM T WHERE ID = 1"

# --- expression widths over a MULTIBYTE source column ----------------
# probed with SQLDA_DISPLAY: the engine's expression widths are
# CHARACTER counts scaled by the RESULT charset's bytes-per-character -
# SUBSTRING(U6 FROM 1 FOR 3) describes 12 bytes UTF8 (not 3), LPAD/RPAD
# to 8 describe 32, U6 || 'x' describes 28 (7 chars x 4, not 100), and
# a FOR count past the source caps at the source's width (FOR 100 over
# VARCHAR(6) describes 24). fire-crab used to announce the raw
# character count as bytes and spuriously raised through 2.11.0.
chk "SUBSTRING FOR n over UTF8 is n chars x 4: delivers" \
    "SELECT SUBSTRING(U6 FROM 1 FOR 3) A FROM T WHERE ID = 1"
chk "LPAD over UTF8 describes 8 chars x 4: delivers" \
    "SELECT LPAD(U6, 8, 'x') A FROM T WHERE ID = 1"
chk "RPAD over UTF8 describes 8 chars x 4: delivers" \
    "SELECT RPAD(U6, 8, 'x') A FROM T WHERE ID = 1"
chk "U6 || 'x' is 7 chars x 4 = 28 bytes, not 100" \
    "SELECT U6 || 'x' A FROM T WHERE ID = 1"
chk "a FOR count past the source caps at its width" \
    "SELECT SUBSTRING(U6 FROM 1 FOR 100) A FROM T WHERE ID = 1"
chk "a NONE source stays NONE: SUBSTRING raises (0, 3)" \
    "SELECT SUBSTRING(V6 FROM 1 FOR 3) A FROM T WHERE ID = 3"

# --- 2.11.0 under a NONE attachment: single-byte dest, no checks ------
ran=$((ran + 1))
a=$(NODE_PATH="$N211" timeout 60 node "$D/fc-ob-rows.js" "$PORT" "$FC" "SELECT V6, C5 FROM T WHERE ID IN (1, 2, 7) ORDER BY ID" NONE 2>&1)
b=$(NODE_PATH="$N211" timeout 60 node "$D/fc-ob-rows.js" 3050 "$RE" "SELECT V6, C5 FROM T WHERE ID IN (1, 2, 7) ORDER BY ID" NONE 2>&1)
if [ "$a" = "$b" ]; then
    echo "OK   a NONE attachment delivers full padded values, no raises"
else
    echo "DIFF NONE attachment"
    echo "     fcwire: $(printf '%s' "$a" | tr '\n' '|')"
    echo "     engine: $(printf '%s' "$b" | tr '\n' '|')"
    fail=1
fi

# --- INSERT .. RETURNING: the singleton row is checked too, and the ---
# refused row must NOT persist (the driver rolls its transaction back)
cat > "$D/fc-ob-ret.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey',encoding:'UTF8'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 d.query("INSERT INTO TR (ID, V6) VALUES (900, 'ab') RETURNING V6",[],(err,r)=>{
  if(err) console.log('ERR '+String(err.message).replace(/\n/g,' '));
  else console.log('STORED '+JSON.stringify(r));
  d.detach();
 });
});
EOF
ran=$((ran + 1))
a=$(NODE_PATH="$N211" timeout 60 node "$D/fc-ob-ret.js" "$PORT" "$FC" 2>&1)
b=$(NODE_PATH="$N211" timeout 60 node "$D/fc-ob-ret.js" 3050 "$RE" 2>&1)
an=$(printf '%s' "$a" | sed -E 's/^(ERR .{50}).*$/\1/')
bn=$(printf '%s' "$b" | sed -E 's/^(ERR .{50}).*$/\1/')
if [ "$an" = "$bn" ] && printf '%s' "$a" | grep -q '^ERR'; then
    echo "OK   INSERT .. RETURNING 'ab' raises through 2.11.0"
else
    echo "DIFF INSERT .. RETURNING"
    echo "     fcwire: $a"
    echo "     engine: $b"
    fail=1
fi
ran=$((ran + 1))
a=$(NODE_PATH="$N214" timeout 60 node "$D/fc-ob-rows.js" "$PORT" "$FC" "SELECT COUNT(*) C FROM TR" 2>&1)
b=$(NODE_PATH="$N214" timeout 60 node "$D/fc-ob-rows.js" 3050 "$RE" "SELECT COUNT(*) C FROM TR" 2>&1)
if [ "$a" = "$b" ] && printf '%s' "$a" | grep -q 'C=0'; then
    echo "OK   ... and the refused row did NOT persist (COUNT 0 on both)"
else
    echo "DIFF refused RETURNING row persisted"
    echo "     fcwire: $a"
    echo "     engine: $b"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$RE" "$FC" "$D"/fc-ob-*.js
if [ "$ran" -lt 32 ]; then
    echo "DIFF only $ran checks ran (expected 32) - did one silently skip?"
    fail=1
fi
exit $fail
