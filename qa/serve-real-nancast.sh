#!/bin/bash
# A NaN CONVERTED TO AN EXACT TYPE IS THE ENGINE PLATFORM'S C++ CAST.
#
# CVT's `(SLONG)` / `(SINT64)` of a NaN double is undefined in C++, so the
# hardware decides.  The gates that pinned "a NaN stores 0" were written
# against an ARM engine, where `fcvtzs` saturates NaN to 0.  On x86-64
# `cvttsd2si` answers the "integer indefinite", and the engine answers:
#
#   INTEGER, NUMERIC(p<=9)      INT32_MIN, scaled    (-21474836.48 at scale 2)
#   BIGINT, NUMERIC(10..18)     INT64_MIN, scaled
#   SMALLINT, NUMERIC(p<=4)     22003 - INT32_MIN fails the SMALLINT range
#   INT128, NUMERIC(19..38)     -0x7fffffff7fffffff7fffffff80000000, at
#                               every scale (the indefinite per 32-bit word)
#   ROUND(D, n)                 INT64_MIN at scale n (CVT_get_int64)
#   MOD(D, 3)                   -2 = INT64_MIN mod 3
#
# This server answered 0 for every one of them - the ARM law - on every
# platform; it now reproduces the cast of the platform it is BUILT for
# (`nan_exact`).  And two answers that are the same on every platform:
# arithmetic over a NaN PROPAGATES it (`D + 1` is NaN; only an INFINITE
# result is the overflow) and `CAST(D AS FLOAT)` narrows it - both raised
# 22003 here.
#
# Every cell compares this server with the LIVE engine; on x86-64 the
# engine is ALSO pinned to the law above, so a cell cannot pass by both
# sides drifting together.  node-firebird binds the NaN (SQL text cannot
# spell one) and renders a NaN double as null.
#
# Usage: qa/serve-real-nancast.sh [port]   (default 4478)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4478}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nancast-eng.fdb"; FC="$D/nancast-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable"; exit 0; }
ARCH=$(uname -m)

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE W (ID INTEGER, SM SMALLINT, N INTEGER, BI BIGINT, N92 NUMERIC(9,2), N184 NUMERIC(18,4), N382 NUMERIC(38,2), N42 NUMERIC(4,2), DP DOUBLE PRECISION);
COMMIT;
INSERT INTO W (ID, N92) VALUES (1, 1.5);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/nancast-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/nancast-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/nancast-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-nancast-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

# the cells: <label>|<sql>|<number of NaN binds>|<x86-64 engine answer>
# (an empty pin = compared with the engine only).  The UPDATEs run in ONE
# transaction first, so the SELECT after them reads the stored NaN values.
CELLS='
store SMALLINT|UPDATE W SET SM = ? WHERE ID = 1|1|ERR 22003
store INTEGER|UPDATE W SET N = ? WHERE ID = 1|1|ok
store BIGINT|UPDATE W SET BI = ? WHERE ID = 1|1|ok
store NUMERIC(9,2)|UPDATE W SET N92 = ? WHERE ID = 1|1|ok
store NUMERIC(18,4)|UPDATE W SET N184 = ? WHERE ID = 1|1|ok
store NUMERIC(4,2)|UPDATE W SET N42 = ? WHERE ID = 1|1|ERR 22003
store DOUBLE|UPDATE W SET DP = ? WHERE ID = 1|1|ok
read back the stores|SELECT SM, N, BI, N92, N184, N42 FROM W|0|[{"SM":null,"N":-2147483648,"BI":-9223372036854776000,"N92":-21474836.48,"N184":-922337203685477.6,"N42":null}]
CAST(? AS SMALLINT)|SELECT CAST(? AS SMALLINT) AS X FROM RDB$DATABASE|1|ERR 22003
CAST(? AS INTEGER)|SELECT CAST(? AS INTEGER) AS X FROM RDB$DATABASE|1|[{"X":-2147483648}]
CAST(? AS BIGINT)|SELECT CAST(? AS BIGINT) AS X FROM RDB$DATABASE|1|[{"X":-9223372036854776000}]
CAST(? AS NUMERIC(4,2))|SELECT CAST(? AS NUMERIC(4,2)) AS X FROM RDB$DATABASE|1|ERR 22003
CAST(? AS NUMERIC(9,2))|SELECT CAST(? AS NUMERIC(9,2)) AS X FROM RDB$DATABASE|1|[{"X":-21474836.48}]
CAST(? AS DECIMAL(9,0))|SELECT CAST(? AS DECIMAL(9,0)) AS X FROM RDB$DATABASE|1|[{"X":-2147483648}]
CAST(? AS NUMERIC(18,4))|SELECT CAST(? AS NUMERIC(18,4)) AS X FROM RDB$DATABASE|1|[{"X":-922337203685477.6}]
CAST(? AS NUMERIC(18,0))|SELECT CAST(? AS NUMERIC(18,0)) AS X FROM RDB$DATABASE|1|[{"X":-9223372036854776000}]
CAST(? AS NUMERIC(38,2)) - the INT128 indefinite|SELECT CAST(? AS NUMERIC(38,2)) AS X FROM RDB$DATABASE|1|[{"X":"-1701411834208551504653317628801098711.04"}]
CAST(? AS NUMERIC(38,0))|SELECT CAST(? AS NUMERIC(38,0)) AS X FROM RDB$DATABASE|1|[{"X":"-170141183420855150465331762880109871104"}]
a stored NaN: CAST(DP AS INTEGER)|SELECT CAST(DP AS INTEGER) AS X FROM W|0|[{"X":-2147483648}]
a stored NaN: CAST(DP AS BIGINT)|SELECT CAST(DP AS BIGINT) AS X FROM W|0|[{"X":-9223372036854776000}]
a stored NaN: CAST(DP AS SMALLINT)|SELECT CAST(DP AS SMALLINT) AS X FROM W|0|ERR 22003
a stored NaN: CAST(DP AS NUMERIC(9,2))|SELECT CAST(DP AS NUMERIC(9,2)) AS X FROM W|0|[{"X":-21474836.48}]
a stored NaN: CAST(DP AS NUMERIC(38,2))|SELECT CAST(DP AS NUMERIC(38,2)) AS X FROM W|0|[{"X":"-1701411834208551504653317628801098711.04"}]
a stored NaN: CAST(DP * 2 AS INTEGER)|SELECT CAST(DP * 2 AS INTEGER) AS X FROM W|0|[{"X":-2147483648}]
ROUND(DP, 0) - CVT_get_int64|SELECT ROUND(DP, 0) AS X FROM W|0|[{"X":-9223372036854776000}]
ROUND(DP, 2)|SELECT ROUND(DP, 2) AS X FROM W|0|[{"X":-92233720368547760}]
MOD(DP, 3) - INT64_MIN mod 3|SELECT MOD(DP, 3) AS X FROM W|0|[{"X":-2}]
arithmetic PROPAGATES a NaN: DP + 1 (it raised)|SELECT DP + 1 AS X FROM W|0|[{"X":null}]
DP * 2, DP / 2, -DP, 1 / DP|SELECT DP * 2 AS A, DP / 2 AS B, -DP AS C, 1 / DP AS E FROM W|0|[{"A":null,"B":null,"C":null,"E":null}]
DP - DP, DP + N92, ABS(DP) + 1|SELECT DP - DP AS A, DP + N92 AS B, ABS(DP) + 1 AS C FROM W|0|[{"A":null,"B":null,"C":null}]
DP / 0 is still the divide-by-zero|SELECT DP / 0 AS X FROM W|0|ERR 22003
CAST(DP AS FLOAT) narrows the NaN (it raised)|SELECT CAST(DP AS FLOAT) AS X FROM W|0|[{"X":null}]
the math functions over a NaN|SELECT SQRT(DP) AS A, EXP(DP) AS B, LN(DP) AS C, SIN(DP) AS E, POWER(DP, 2) AS F FROM W|0|[{"A":null,"B":null,"C":null,"E":null,"F":null}]
its text|SELECT CAST(DP AS VARCHAR(30)) AS A FROM W|0|[{"A":"nan"}]
CONTROL SIGN and a comparison|SELECT SIGN(DP) AS A, IIF(DP > 0, 1, 0) AS B FROM W|0|[{"A":0,"B":0}]
CONTROL a NaN compared with a written INTEGER cast|SELECT ID FROM W WHERE N = CAST(? AS INTEGER)|1|[{"ID":1}]
'
# one node run per server: every cell in order, one line each
runall() { # <port> <db>
    FC_PORT="$1" FC_DB="$2" FC_CELLS="$CELLS" timeout 60 node -e '
const F=require("node-firebird");
const cells=process.env.FC_CELLS.split("\n").filter(l=>l.trim()).map(l=>l.split("|"));
F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,d)=>{
 if(e){console.log("CONN_ERR");process.exit(1);}
 d.transaction(F.ISOLATION_READ_COMMITTED,(e,tx)=>{let i=0;const next=()=>{
  if(i>=cells.length){tx.rollback(()=>d.detach());return;}
  const [lab,sql,nb]=cells[i++];const binds=Array(+nb).fill(NaN);
  tx.query(sql,binds,(e,r)=>{
   let out;
   if(e){const m=String(e.message);out=/numeric overflow|out of range|divide|division/i.test(m)?"ERR 22003":"ERR "+m.slice(0,40);}
   else out=r===undefined?"ok":JSON.stringify(r);
   console.log(out);next();});};next();});});' 2>&1
}
ev=$(runall "$REAL" "$ENG"); fv=$(runall "$PORT" "$FC")
fail=0; ran=0
n=0
while IFS='|' read -r lab sql nb pin; do
    [ -n "$lab" ] || continue
    n=$((n + 1)); ran=$((ran + 1))
    e=$(printf '%s\n' "$ev" | sed -n "${n}p"); f=$(printf '%s\n' "$fv" | sed -n "${n}p")
    if [ "$ARCH" = x86_64 ] && [ -n "$pin" ] && [ "$e" != "$pin" ]; then
        echo "FAIL $n $lab - THE ENGINE ANSWERS [$e], not the x86-64 law [$pin]"; fail=1
    elif [ -z "$e" ]; then echo "FAIL $n $lab - the engine printed nothing"; fail=1
    elif [ "$e" != "$f" ]; then echo "FAIL $n $lab"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1
    else echo "OK   $n $lab [$e]"; fi
done <<< "$CELLS"

ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-nancast-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks ($ARCH)"
if [ "$ran" -lt 37 ]; then echo "FAIL only $ran checks ran (floor 37)"; fail=1; fi
exit $fail
