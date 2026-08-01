#!/bin/bash
# CHARACTER SETS: a text column's width is in CHARACTERS, and its bytes
# are not the same number.
#
# fire-crab read only the byte half of a text descriptor. In a database
# created DEFAULT CHARACTER SET UTF8 - the ordinary case - a CHAR(5) is
# twenty bytes on disk, and that cost two things at once:
#
#   READING   SELECT C5 handed back TWENTY characters where the engine
#             hands back five, on rows the ENGINE had written.
#             OCTET_LENGTH and CHAR_LENGTH answered 20 and 20 against
#             the engine's 5 and 5.
#   WRITING   an eleven-character parameter into VARCHAR(10) was
#             ACCEPTED, because eleven bytes fit in forty. The engine
#             refuses it - and could not afterwards READ the row
#             fire-crab wrote: SELECT through isql failed with "string
#             right truncation, expected length 10, actual 19".
#
# The second is the one that matters. A row the reference implementation
# cannot read is worse than any missing feature, so this gate checks it
# LAST and checks it with the engine's own tool, against fire-crab's own
# database file.
#
#   qa/serve-real-charset.sh [port]
#
# Four character sets, chosen for their widths: UTF8 (4 bytes/char),
# UNICODE_FSS (3), WIN1252 and NONE (1). A gate with only UTF8 columns
# would pass on code that divided everything by four.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4562}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
RE="$D/fc-cs-re.fdb"; FC="$D/fc-cs-fc.fdb"
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
CREATE DATABASE '$RE' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY,
                C5 CHAR(5), V10 VARCHAR(10),
                N5 CHAR(5) CHARACTER SET NONE,
                W5 CHAR(5) CHARACTER SET WIN1252,
                U3 CHAR(5) CHARACTER SET UNICODE_FSS,
                NV VARCHAR(10) CHARACTER SET NONE);
COMMIT;
-- written by the ENGINE, so the read checks below are reading rows
-- fire-crab did not produce
INSERT INTO T VALUES (1, 'abc', 'abc', 'abc', 'abc', 'abc', 'abc');
INSERT INTO T VALUES (2, '12345', '1234567890', '12345', '12345', '12345', '1234567890');
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO T VALUES (4, '', '', '', '', '', '');
COMMIT;
EOF
cp "$RE" "$FC"; chmod 666 "$RE" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-charset.log 2>&1 &
srv=$!
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

# --- 1. the bytes-per-character table is a CLAIM about the engine -----
# crates/ods/src/intl.rs hardcodes RDB$BYTES_PER_CHARACTER. If the
# engine ever disagrees, that table is wrong and every width computed
# from it is wrong, so the claim is checked against the catalogue rather
# than trusted.
ran=$((ran + 1))
want=$("$ISQL" -q -b -user "$U" -pas "$P" "$RE" <<'EOF' 2>&1 | awk 'NF==2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {print $1":"$2}' | sort -n
SELECT RDB$CHARACTER_SET_ID, RDB$BYTES_PER_CHARACTER FROM RDB$CHARACTER_SETS ORDER BY 1;
EOF
)
got=""
for pair in $want; do
    id=${pair%%:*}; bpc=${pair##*:}
    mine=1
    case "$id" in
        3) mine=3 ;;
        4|69) mine=4 ;;
        5|6|44|56|57|67|68) mine=2 ;;
    esac
    [ "$mine" = "$bpc" ] || got="$got $id(engine=$bpc,intl.rs=$mine)"
done
if [ -z "$got" ]; then
    echo "OK   bytes-per-character table agrees with RDB\$CHARACTER_SETS ($(printf '%s\n' $want | wc -l) sets)"
else
    echo "DIFF intl.rs bytes_per_char disagrees with the engine:$got"
    fail=1
fi

# --- 2. reading: values, and the two length functions -----------------
cat > "$D/fc-cs-read.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const q=process.argv[4];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 d.query(q,[],(e,r)=>{
  if(e){console.log('ERR '+e.message)}
  else for(const row of (r||[])){
    console.log(Object.keys(row).map(k=>{
      const v=row[k];
      if(v===null) return k+'=NULL';
      if(Buffer.isBuffer(v)) return k+'=buf:'+v.toString('hex');
      if(typeof v==='string') return k+'='+JSON.stringify(v)+'/'+v.length;
      return k+'='+v;
    }).join(' '));
  }
  d.detach();
 });
});
EOF

read_both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(timeout 60 node "$D/fc-cs-read.js" "$PORT" "$FC" "$2" 2>&1)
    b=$(timeout 60 node "$D/fc-cs-read.js" 3050 "$RE" "$2" 2>&1)
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire: $(printf '%s' "$a" | head -4 | tr '\n' '|')"
        echo "     engine: $(printf '%s' "$b" | head -4 | tr '\n' '|')"
        fail=1
    fi
}

read_both "CHAR(5) UTF8 is five characters, not twenty" \
    "SELECT ID, C5 FROM T ORDER BY ID"
read_both "VARCHAR(10) UTF8" "SELECT ID, V10 FROM T ORDER BY ID"
read_both "CHAR(5) NONE" "SELECT ID, N5 FROM T ORDER BY ID"
read_both "CHAR(5) WIN1252" "SELECT ID, W5 FROM T ORDER BY ID"
read_both "CHAR(5) UNICODE_FSS is five, not fifteen" \
    "SELECT ID, U3 FROM T ORDER BY ID"
read_both "VARCHAR(10) NONE" "SELECT ID, NV FROM T ORDER BY ID"
read_both "every text column at once" \
    "SELECT ID, C5, V10, N5, W5, U3, NV FROM T ORDER BY ID"
read_both "CHAR_LENGTH counts characters" \
    "SELECT ID, CHAR_LENGTH(C5) A, CHAR_LENGTH(U3) B, CHAR_LENGTH(N5) C FROM T ORDER BY ID"
read_both "OCTET_LENGTH of a padded CHAR" \
    "SELECT ID, OCTET_LENGTH(C5) A, OCTET_LENGTH(U3) B FROM T ORDER BY ID"
read_both "TRIM removes the padding the width implies" \
    "SELECT ID, TRIM(C5) A, TRIM(U3) B FROM T ORDER BY ID"
read_both "concatenation of two padded CHARs" \
    "SELECT ID, C5 || U3 A FROM T ORDER BY ID"
read_both "a CHAR compared against a literal" \
    "SELECT ID FROM T WHERE C5 = 'abc  ' ORDER BY ID"
read_both "UPPER over a padded CHAR" \
    "SELECT ID, UPPER(C5) A FROM T ORDER BY ID"

# --- 3. writing: the declared width is in CHARACTERS -------------------
cat > "$D/fc-cs-write.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const cases=[
 [101,'C5','12345'],[102,'C5','123456'],[103,'C5','äbcde'],[104,'C5','ääääää'],
 [105,'C5','äääää'],[106,'C5',''],[107,'C5','a'],
 [110,'V10','1234567890'],[111,'V10','12345678901'],[112,'V10','2020-02-29 11:22:33'],
 [113,'V10','ääääääääää'],[114,'V10','äääääääääää'],
 [120,'N5','12345'],[121,'N5','123456'],
 [122,'W5','12345'],[123,'W5','123456'],
 [124,'U3','12345'],[125,'U3','123456'],[126,'U3','äbcde'],[127,'U3','ääääää'],
 [130,'NV','1234567890'],[131,'NV','12345678901'],
];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 let i=0;
 const next=()=>{
  if(i===cases.length){d.detach();return}
  const [id,col,val]=cases[i++];
  d.query(`INSERT INTO T (ID, ${col}) VALUES (?, ?)`,[id,val],(e)=>{
   console.log(`${id} ${col} ${val.length}ch ${Buffer.byteLength(val)}b : ${e?'REFUSED':'STORED'}`);
   next();
  });
 };
 next();
});
EOF
ran=$((ran + 1))
a=$(timeout 120 node "$D/fc-cs-write.js" "$PORT" "$FC" 2>&1)
b=$(timeout 120 node "$D/fc-cs-write.js" 3050 "$RE" 2>&1)
if [ "$a" = "$b" ]; then
    echo "OK   accept/refuse over $(printf '%s' "$a" | wc -l) over-long parameters"
else
    echo "DIFF accept/refuse on over-long text parameters"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -12 | sed 's/^/     /'
    fail=1
fi

# --- 4. the rows fire-crab wrote, read by the ENGINE -------------------
# The check the whole gate exists for. fire-crab's own database file,
# opened by the real engine through its own tool: if a stored value
# overflows its declared character width, this is where it shows, as
# "string right truncation" on the way OUT.
ran=$((ran + 1))
kill $srv 2>/dev/null; srv=""; sleep 0.3
out=$("$ISQL" -q -b -user "$U" -pas "$P" "$FC" <<'EOF' 2>&1
SELECT ID, C5, V10, N5, W5, U3, NV FROM T ORDER BY ID;
EOF
)
if printf '%s' "$out" | grep -qi "truncation\|SQLSTATE\|error"; then
    echo "DIFF the ENGINE cannot read back what fire-crab wrote:"
    printf '%s' "$out" | grep -i "truncation\|SQLSTATE\|error" | head -4 | sed 's/^/     /'
    fail=1
else
    echo "OK   the engine reads every row fire-crab wrote ($(printf '%s' "$out" | grep -c '^') lines)"
fi

# The same file, checked structurally - a mis-sized text field would
# also show as a corrupt record here.
ran=$((ran + 1))
gf=$(gfix -v -full -user "$U" -pas "$P" "$FC" 2>&1)
if [ -z "$gf" ]; then
    echo "OK   gfix -v -full is silent on fire-crab's database"
else
    echo "DIFF gfix reports damage: $(printf '%s' "$gf" | head -3 | tr '\n' '|')"
    fail=1
fi

# --- 5. the one deliberate divergence, stated rather than hidden -------
# The engine ACCEPTS a text value of exactly 4x the declared character
# length and SILENTLY TRUNCATES it: CHAR(5) <- 20 characters stores
# "abcde". It is content-independent and reproducible (CHAR(3)<-12,
# CHAR(8)<-32, VARCHAR(5)<-20) and it is an engine buffer-sizing bug.
# fire-crab refuses instead. Copying it would mean silently storing a
# value nobody asked for, so this gate ASSERTS the divergence rather
# than pretending it is absent - if fire-crab ever starts truncating
# silently, this check fails.
ran=$((ran + 1))
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >>/tmp/fc-serve-charset.log 2>&1 &
srv=$!
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The SECOND start needs the same liveness assertion as the first, and
# more than the first: `nc -z` answers "something is listening", and if
# this restart lost the race with its own predecessor's shutdown - or
# the port went to anyone else - the check below would run against that
# server and report a pass it never measured.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire did not restart for the truncation check - port $PORT taken?"
    exit 1
}
cat > "$D/fc-cs-quirk.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 d.query("INSERT INTO T (ID, C5) VALUES (?, ?)",[900,'abcdefghijklmnopqrst'],(e)=>{
  console.log(e?'REFUSED':'STORED');d.detach();
 });
});
EOF
q=$(timeout 60 node "$D/fc-cs-quirk.js" "$PORT" "$FC" 2>&1)
if [ "$q" = "REFUSED" ]; then
    echo "OK   the engine's silent 4x truncation is deliberately NOT copied"
else
    echo "DIFF fire-crab took a 20-character value into CHAR(5): $q"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$RE" "$FC" "$D"/fc-cs-*.js
if [ "$ran" -lt 18 ]; then
    echo "DIFF only $ran checks ran (expected at least 18) - did one silently skip?"
    fail=1
fi
exit $fail
