#!/bin/bash
# A NUMBER WRITTEN AS TEXT: every spelling the engine accepts, every
# spelling it refuses, and the value it stores for each - compared
# against fire-crab over twin databases, on the STORE side and the
# FILTER side, which turn out to have different rules.
#
# This was the largest single hole in the parameter surface: 82 of 119
# measured disagreements were "a text parameter into a numeric column",
# which the engine converts and fire-crab refused outright.
#
# Three things here are not what a hand-written parser would do, and
# each has its own section below:
#
#   * '1.999999' goes into an INTEGER as 2 and is REFUSED by a SMALLINT.
#     The rounded result fits both; the MANTISSA (1999999) is
#     range-checked before the rescale, and only the SMALLINT is too
#     narrow for it.
#   * a hex string is sized by its DIGIT COUNT, not its value.
#     '0x0000000000000001' is one, and an INTEGER refuses it, because
#     sixteen digits is a BIGINT-shaped literal. The same digits are
#     then read as a SIGNED integer AT THE TARGET's width, so '0xFFFF'
#     is -1 in a SMALLINT and 65535 in an INTEGER.
#   * the STORE side and the FILTER side disagree with each other.
#     '1.999999' into a SMALLINT COLUMN is a conversion error, but
#     `WHERE N_SM = ?` with the same string returns NO ROWS - a filter
#     asks a question and "none" is a valid answer. And hex, which the
#     store side takes, is a conversion error on the filter side.
#
#   qa/serve-real-textnum.sh [port]
#
# Values are compared through RETURNING where the driver allows it and
# through a read-back SELECT otherwise, so a stored value is checked and
# not merely the absence of an error.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4563}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
RE="$D/fc-tn-re.fdb"; FC="$D/fc-tn-fc.fdb"
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
CREATE DATABASE '$RE' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE N (ID INTEGER NOT NULL PRIMARY KEY, C_SM SMALLINT, C_IN INTEGER, C_BG BIGINT,
                C_N92 NUMERIC(9,2), C_N180 NUMERIC(18,0), C_N184 NUMERIC(18,4),
                C_D52 DECIMAL(5,2), C_FL FLOAT, C_DB DOUBLE PRECISION);
CREATE TABLE P (ID INTEGER NOT NULL PRIMARY KEY, N_SM SMALLINT, N_INT INTEGER, N_BIG BIGINT,
                N_NUM NUMERIC(9,2), N_DBL DOUBLE PRECISION, S_VC VARCHAR(10), B_BOOL BOOLEAN);
COMMIT;
INSERT INTO P VALUES (1,5,5,5,5.25,2.5,'5',TRUE);
INSERT INTO P VALUES (2,9,9,9,9.00,9.0,'9',FALSE);
INSERT INTO P VALUES (3,1,1,1,1.00,1.0,'1',TRUE);
INSERT INTO P VALUES (4,0,0,0,0.00,0.0,'0',FALSE);
INSERT INTO P VALUES (8,8,8,9223372036854775807,8.00,8.0,'8',TRUE);
INSERT INTO P VALUES (9,9,9,9223372036854775806,9.99,9.0,'9',TRUE);
COMMIT;
EOF
cp "$RE" "$FC"; chmod 666 "$RE" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-textnum.log 2>&1 &
srv=$!
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

# --- the STORE side: 54 spellings x 9 numeric column types ------------
cat > "$D/fc-tn-store.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const vals=['1','0','-7','+5','32767','-32768','  42  ','  -7  ','00000000000000000012',
 '.5','5.','-0','1e3','1E3','1e-3','2147483648','12345678901',
 '3.75','2.5','3.5','-2.5','0.5','-0.5','1.999999','-1.5',
 '0x10','0X1F','0xFFFF','0x7fffffff','0xF','0x8000','0xFFFFFFFF','0x0000000000000001',
 '0x10000','0xabcdef','0x10000000000000000',
 '','  ','abc','1 2','1,5','--5','1.5.5','inf','NaN','1d3','0x','\t5','5\n','1e400',
 '32768','-32769','9223372036854775807','9223372036854775808',
 '1.5e2','-1e-3','+.5','.','-','1e','e1'];
const cols=['C_SM','C_IN','C_BG','C_N92','C_N180','C_N184','C_D52','C_FL','C_DB'];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 const jobs=[]; let id=1;
 for(const v of vals) for(const c of cols) jobs.push([id++,c,v]);
 let i=0;
 const next=()=>{
  if(i===jobs.length){d.detach();return}
  const [jid,col,val]=jobs[i++];
  d.query(`INSERT INTO N (ID, ${col}) VALUES (?, ?)`,[jid,val],(e)=>{
   if(e){console.log(`${col}\t${JSON.stringify(val)}\tREFUSED`);return next()}
   // read the STORED value back, so this checks the conversion and not
   // merely the absence of an error
   d.query(`SELECT ${col} V FROM N WHERE ID = ?`,[jid],(e2,r)=>{
    console.log(`${col}\t${JSON.stringify(val)}\t${e2?'READ-ERR':String(r[0].V)}`);next();
   });
  });
 };
 next();
});
EOF
ran=$((ran + 1))
a=$(timeout 600 node "$D/fc-tn-store.js" "$PORT" "$FC" 2>&1)
b=$(timeout 600 node "$D/fc-tn-store.js" 3050 "$RE" 2>&1)
n=$(printf '%s\n' "$b" | grep -c .)
if [ "$n" -lt 500 ]; then
    echo "DIFF the store sweep produced only $n results (expected 549) - did it stop early?"
    fail=1
elif [ "$a" = "$b" ]; then
    echo "OK   store side: $n text-to-numeric conversions agree exactly"
else
    # The ONE known divergence is the approximate columns' wide
    # decimals, characterised in the next section; anything else is a
    # DIFF. Narrowing the exemption to C_DB/C_FL keeps it from hiding a
    # regression in the fifty-four exact-column conversions.
    other=$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | grep '^[<>]' \
        | grep -v 'C_DB\|C_FL' | head -8)
    if [ -z "$other" ]; then
        echo "OK   store side: agrees except the stated wide-decimal double case"
    else
        echo "DIFF store side:"
        printf '%s\n' "$other" | sed 's/^/     /'
        fail=1
    fi
fi

# --- the wide-decimal double, stated rather than hidden ---------------
# The engine's own string-to-double is NOT correctly rounded. It answers
# 100000000000000020 for '99999999999999999' where the nearest double is
# 100000000000000000, and 1.0000000000000002e20 for twenty nines where
# the nearest is 1e20 - one ulp high each time. fire-crab uses a
# correctly-rounded parse and is therefore MORE accurate; copying a
# one-ulp error to match would make it less so.
#
# So this is two checks, not one. The twin comparison runs over the
# range where the engine IS correct - up to sixteen significant digits,
# the measured boundary - and beyond it fire-crab is checked against the
# TRUE nearest double instead, computed independently by the client.
# (The boundary is sixteen and not seventeen because it is the value,
# not the digit count, that decides: seventeen digits of
# '12345678901234567' agree, seventeen NINES do not.)
cat > "$D/fc-tn-dbl.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const vals=[]; for(let n=1;n<=16;n++) vals.push('9'.repeat(n));
for(let n=1;n<=16;n++) vals.push('1234567890123456789'.slice(0,n));
vals.push('0.1','0.2','1e-1','2.5','1.5e2','-1e-3');
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 let i=0,id=90000;
 const next=()=>{
  if(i===vals.length){d.detach();return}
  const v=vals[i++], jid=id++;
  d.query("INSERT INTO N (ID, C_DB) VALUES (?, ?)",[jid,v],(e)=>{
   if(e){console.log(`${v}\tREFUSED`);return next()}
   d.query("SELECT C_DB V FROM N WHERE ID = ?",[jid],(e2,r)=>{
    console.log(`${v}\t${e2?'READ-ERR':String(r[0].V)}`);next();});
  });
 };
 next();
});
EOF
ran=$((ran + 1))
a=$(timeout 300 node "$D/fc-tn-dbl.js" "$PORT" "$FC" 2>&1)
b=$(timeout 300 node "$D/fc-tn-dbl.js" 3050 "$RE" 2>&1)
if [ "$a" = "$b" ]; then
    echo "OK   DOUBLE parse identical to 16 significant digits ($(printf '%s\n' "$b" | grep -c .) values)"
else
    echo "DIFF the DOUBLE parse differs INSIDE 16 significant digits, where it must not:"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -6 | sed 's/^/     /'
    fail=1
fi

# Past that boundary, fire-crab is measured against the arithmetic
# rather than against the engine: JavaScript's own Number() is
# correctly rounded, so it is the oracle here.
cat > "$D/fc-tn-round.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const vals=['99999999999999999','999999999999999999','9999999999999999999',
 '99999999999999999999','999999999999999999999','123456789012345678',
 '1234567890123456789','12345678901234567890'];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 let i=0,id=95000;
 const next=()=>{
  if(i===vals.length){d.detach();return}
  const v=vals[i++], jid=id++;
  d.query("INSERT INTO N (ID, C_DB) VALUES (?, ?)",[jid,v],(e)=>{
   if(e){console.log(`${v} REFUSED`);return next()}
   d.query("SELECT C_DB V FROM N WHERE ID = ?",[jid],(e2,r)=>{
    const got=e2?NaN:r[0].V, want=Number(v);
    console.log(`${v} ${got===want?'exact':'OFF got='+got+' want='+want}`);next();});
  });
 };
 next();
});
EOF
ran=$((ran + 1))
r=$(timeout 200 node "$D/fc-tn-round.js" "$PORT" "$FC" 2>&1)
off=$(printf '%s\n' "$r" | grep -c 'OFF')
if [ "$off" = "0" ] && [ "$(printf '%s\n' "$r" | grep -c exact)" = "8" ]; then
    echo "OK   beyond 16 digits fire-crab returns the CORRECTLY ROUNDED double (8 values)"
else
    echo "DIFF fire-crab's wide-decimal doubles are not correctly rounded:"
    printf '%s\n' "$r" | grep 'OFF\|REFUSED' | head -6 | sed 's/^/     /'
    fail=1
fi

# --- the FILTER side, whose rules are NOT the store side's ------------
cat > "$D/fc-tn-filter.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const cases=[
 ["N_SM = ?",['5']],["N_SM = ?",['5.0']],["N_SM = ?",['  5  ']],["N_SM > ?",['4']],
 ["N_SM = ?",['1e0']],["N_SM = ?",['5e0']],["N_SM >= ?",['5']],["N_SM < ?",['5']],
 ["N_INT = ?",['5']],["N_INT > ?",['4']],["N_INT = ?",['2']],["N_INT <> ?",['5']],
 ["N_BIG = ?",['5']],["N_NUM = ?",['5.25']],["N_NUM = ?",['5.250']],["N_NUM = ?",['5.2']],
 ["N_DBL = ?",['2.5']],["N_DBL = ?",['2.50']],["N_DBL > ?",['2']],
 // the exact-comparison proof: these two BIGINTs are ONE double, and
 // the engine picks a different row for each string
 ["N_BIG = ?",['9223372036854775807']],["N_BIG = ?",['9223372036854775806']],
 ["N_BIG > ?",['9223372036854775806']],
 // a filter ANSWERS where a store REFUSES - no rows, not an error
 ["N_SM = ?",['1.999999']],["N_INT = ?",['1.999999']],["N_SM = ?",['99999']],
 ["N_SM > ?",['1.5']],["N_SM < ?",['1.5']],
 // ... and hex, which the store side takes, is an error here
 ["N_SM = ?",['0x5']],["N_INT = ?",['0x5']],
 ["N_SM = ?",['abc']],["N_SM = ?",['']],
 // text against BOOLEAN: the same NAME match as the store side
 ["B_BOOL = ?",['true']],["B_BOOL = ?",['FALSE']],["B_BOOL = ?",[' True ']],
 ["B_BOOL = ?",['t']],["B_BOOL = ?",['1']],
 // controls that must not regress
 ["S_VC = ?",['5']],["N_INT = ?",[5]],["N_SM = ?",[2]],["N_INT = ?",[true]],
 // DML filters take the same path
 ["N_INT = ? AND 1 = 0",['5']],
];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 let i=0;
 const next=()=>{
  if(i===cases.length){d.detach();return}
  const [w,p]=cases[i++];
  d.query("SELECT ID FROM P WHERE "+w+" ORDER BY ID",p,(e,r)=>{
   console.log(`${w}\t${JSON.stringify(p)}\t${e?'ERR':'['+r.map(x=>x.ID).join(',')+']'}`);next();
  });
 };
 next();
});
EOF
ran=$((ran + 1))
a=$(timeout 300 node "$D/fc-tn-filter.js" "$PORT" "$FC" 2>&1)
b=$(timeout 300 node "$D/fc-tn-filter.js" 3050 "$RE" 2>&1)
n=$(printf '%s\n' "$b" | grep -c .)
if [ "$n" -lt 40 ]; then
    echo "DIFF the filter sweep produced only $n results (expected 41)"
    fail=1
elif [ "$a" = "$b" ]; then
    echo "OK   filter side: $n text-parameter predicates agree exactly"
else
    echo "DIFF filter side:"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -10 | sed 's/^/     /'
    fail=1
fi

# --- the UPDATE/DELETE filters, which share the bind path -------------
cat > "$D/fc-tn-dml.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const stmts=[
 ["UPDATE P SET N_INT = N_INT WHERE N_INT = ?",['5']],
 ["DELETE FROM P WHERE N_INT = ? AND 1 = 0",['5']],
 ["UPDATE P SET N_SM = ? WHERE ID = 1",['7']],
 ["UPDATE P SET N_NUM = ? WHERE ID = 1",['1.25']],
 ["UPDATE P SET N_DBL = ? WHERE ID = 1",['2.5']],
 ["UPDATE P SET N_SM = ? WHERE ID = 1",['abc']],
 ["UPDATE P SET B_BOOL = ? WHERE ID = 1",['true']],
];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 let i=0;
 const next=()=>{
  if(i===stmts.length){
   d.query("SELECT ID, N_SM, N_NUM, N_DBL, B_BOOL FROM P ORDER BY ID",[],(e,r)=>{
    if(e) console.log('READ-ERR '+e.message);
    else for(const x of r) console.log(`row ${x.ID} ${x.N_SM} ${x.N_NUM} ${x.N_DBL} ${x.B_BOOL}`);
    d.detach();});
   return;
  }
  const [s,p]=stmts[i++];
  d.query(s,p,(e)=>{console.log(`${s} ${JSON.stringify(p)} : ${e?'ERR':'OK'}`);next();});
 };
 next();
});
EOF
ran=$((ran + 1))
a=$(timeout 200 node "$D/fc-tn-dml.js" "$PORT" "$FC" 2>&1)
b=$(timeout 200 node "$D/fc-tn-dml.js" 3050 "$RE" 2>&1)
if [ "$a" = "$b" ]; then
    echo "OK   DML: $(printf '%s\n' "$b" | grep -c .) statements and the rows they left behind agree"
else
    echo "DIFF DML with text parameters:"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/     /'
    fail=1
fi

# --- a NON-TEXT parameter against a TEXT column: answered now ---------
# The engine does not render the value as text - it coerces the COLUMN
# to a number, PER ROW: `WHERE S_VC = 5` matches '5', ' 5', '5.0' and
# '05' alike, and RAISES mid-scan if any row holds a non-numeric
# string. fire-crab used to refuse these three; the per-row coercion
# ([Term::TextNumCmp], gate qa/serve-real-textcolcmp.sh) answers them
# with engine parity now - a JS boolean arrives as blr_long 1/0 on
# this wire, so [true]/[false] are the numeric case, matching the '1'
# and '0' rows here (raising only where a row cannot convert).
cat > "$D/fc-tn-refuse.js" <<'EOF'
const fb=require('node-firebird');
const port=parseInt(process.argv[2],10), db=process.argv[3];
const cases=[["S_VC = ?",[5]],["S_VC = ?",[true]],["S_VC = ?",[false]]];
fb.attach({host:'127.0.0.1',port,database:db,user:'SYSDBA',password:'masterkey'},(e,d)=>{
 if(e){console.log('ATTACH-ERR '+e.message);return}
 let i=0;
 const next=()=>{
  if(i===cases.length){d.detach();return}
  const [w,p]=cases[i++];
  d.query("SELECT ID FROM P WHERE "+w+" ORDER BY ID",p,(e,r)=>{
   console.log(`${w}\t${JSON.stringify(p)}\t${e?'ERR '+(e.message||'').split('\n')[0].slice(0,60):'['+r.map(x=>x.ID).join(',')+']'}`);next();
  });
 };
 next();
});
EOF
ran=$((ran + 1))
a=$(timeout 120 node "$D/fc-tn-refuse.js" "$PORT" "$FC" 2>&1)
b=$(timeout 120 node "$D/fc-tn-refuse.js" 3050 "$RE" 2>&1)
if [ "$a" = "$b" ] && [ "$(printf '%s\n' "$b" | grep -c .)" = "3" ]; then
    echo "OK   non-text parameters against the TEXT column answer with engine parity (3 predicates)"
else
    echo "DIFF non-text parameters against the TEXT column:"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -8 | sed 's/^/     /'
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$RE" "$FC" "$D"/fc-tn-*.js
if [ "$ran" -lt 6 ]; then
    echo "DIFF only $ran checks ran (expected at least 6) - did one silently skip?"
    fail=1
fi
exit $fail
