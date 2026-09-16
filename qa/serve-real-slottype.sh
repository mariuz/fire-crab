#!/bin/bash
# A `?` INSIDE a DML value expression converts AT ITS SLOT, before the
# arithmetic - not after it.
#
# The engine reads the driver's value at the slot the describe announced
# and evaluates from there, so `(I) VALUES (? * 2)` bound 1.6 is 2 * 2 =
# 4. fire-crab spliced the raw value and computed 3.2, storing 3 - a
# SILENT wrong store, and the same for every exact destination.
#
# The describe is the DESTINATION's own type, pushed down the tree
# (SQLDA_DISPLAY: `(N) VALUES (? * 2)` over NUMERIC(9,2) announces LONG
# scale -2), with two overrides the engine's PASS1_set_parameter_type
# makes: a CAST types its own operand, and COALESCE types from its other
# arguments (`COALESCE(?, 0)` is a plain INTEGER - 2^40 overflows it).
#
# THE MULTIPLY ASYMMETRY, measured cell by cell into NUMERIC(9,2) with
# 1.115 bound: the LEFT operand of a multiply converts at SCALE 0 while
# everything else takes the destination's scale -
#
#     ? * 2    -> 2.00   (the value became 1)      2 * ?  -> 2.24
#     ? * 2.0  -> 2.00                             ? / 2  -> 0.56
#     ? + 0    -> 1.12                             ? - 0  -> 1.12
#
# and into NUMERIC(9,4) `? * 2` bound 1.11115 is 2.0000. `? * ?`,
# `? * <column>`, `(? * 2) + 0` and `? * 2 * 2` follow the same LEFT-operand
# rule; a DOUBLE destination keeps its double (2.23). The DESCRIBE still
# announces the destination's scale in every one of those, so the slot
# published and the conversion applied genuinely differ.
#
# Usage: qa/serve-real-slottype.sh [port]   (default 4193)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4193}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/slot-eng.fdb"; FC="$D/slot-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/slot-build.log 2>&1 <<'SQL'
CREATE TABLE T (ID INTEGER, I INTEGER, N NUMERIC(9,2), N4 NUMERIC(9,4), DP DOUBLE PRECISION, DF DECFLOAT(34), D16 DECFLOAT(16), BI BIGINT, SM SMALLINT);
CREATE TABLE U (ID INTEGER, I INTEGER, N NUMERIC(9,2), DF DECFLOAT(34));
INSERT INTO U VALUES (1, 2, 1.00, 1);
CREATE TABLE MG (ID INTEGER, I INTEGER, N NUMERIC(9,2), DF DECFLOAT(34));
INSERT INTO MG VALUES (1, 10, 10.00, 10);
INSERT INTO MG VALUES (2, 10, 10.00, 10);
INSERT INTO MG VALUES (3, 10, 10.00, 10);
INSERT INTO MG VALUES (4, 10, 10.00, 10);
INSERT INTO MG VALUES (5, 10, 10.00, 10);
INSERT INTO MG VALUES (6, 10, 10.00, 10);
INSERT INTO MG VALUES (7, 10, 10.00, 10);
INSERT INTO MG VALUES (8, 10, 10.00, 10);
COMMIT;
SQL
if grep -qi error /tmp/slot-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/slot-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-slot.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
run() { # <port> <db> <sql> <json>
    FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR "+String(e2.message||e2).replace(/\n/g," | ").trim());db.detach();process.exit(0);}
          if(!r||!r.length){console.log("(ok)");db.detach();process.exit(0);}
          console.log(r.map(x=>Object.values(x).join()).join(";"));db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
# a DML statement on both, then the STORED value read back through isql
# (node cannot describe a DECFLOAT projection - it answers -804)
stored() { # <conn> <col> <id> <table>
    printf 'SET LIST ON;\nSELECT %s FROM %s WHERE ID = %s;\n' "$2" "$4" "$3" \
        | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -a "^$2 " | sed 's/  */ /g'
}
both() { # <label> <sql> <json> <col> <id> [table, default T]
    local e f se sf tbl="${6:-T}"
    e=$(run 3050 "$ENG" "$2" "$3"); f=$(run "$PORT" "$FC" "$2" "$3")
    se=$(stored "127.0.0.1/3050:$ENG" "$4" "$5" "$tbl"); sf=$(stored "127.0.0.1/$PORT:$FC" "$4" "$5" "$tbl")
    if [ "$e" = "$f" ] && [ "$se" = "$sf" ]; then echo "OK   $1 [$3] => $e / $se"
    else echo "DIFF $1 [$3]"; echo "     eng: $e / $se"; echo "     fc:  $f / $sf"; fail=1; fi
}

echo "-- the value converts at its slot, BEFORE the arithmetic --"
both "INTEGER dest, ? * 2"        "INSERT INTO T (ID, I) VALUES (1, ? * 2)"   '[1.6]'     I  1
both "BIGINT dest, ? * 2"         "INSERT INTO T (ID, BI) VALUES (2, ? * 2)"  '[1.6]'     BI 2
both "INTEGER dest, ? + 1"        "INSERT INTO T (ID, I) VALUES (3, ? + 1)"   '[2.5]'     I  3
both "INTEGER dest, ? / 3"        "INSERT INTO T (ID, I) VALUES (4, ? / 3)"   '[10]'      I  4
both "SMALLINT dest, ? * 2"       "INSERT INTO T (ID, SM) VALUES (5, ? * 2)"  '[1.6]'     SM 5

echo "-- the MULTIPLY asymmetry: only the LEFT operand converts at scale 0 --"
both "NUMERIC(9,2), ? * 2"        "INSERT INTO T (ID, N) VALUES (10, ? * 2)"  '[1.115]'   N  10
both "NUMERIC(9,2), 2 * ?"        "INSERT INTO T (ID, N) VALUES (11, 2 * ?)"  '[1.115]'   N  11
both "NUMERIC(9,2), ? * 2.0"      "INSERT INTO T (ID, N) VALUES (12, ? * 2.0)" '[1.115]'  N  12
both "NUMERIC(9,2), ? / 2"        "INSERT INTO T (ID, N) VALUES (13, ? / 2)"  '[1.115]'   N  13
both "NUMERIC(9,2), ? + 0"        "INSERT INTO T (ID, N) VALUES (14, ? + 0)"  '[1.115]'   N  14
both "NUMERIC(9,2), ? - 0"        "INSERT INTO T (ID, N) VALUES (15, ? - 0)"  '[1.115]'   N  15
both "NUMERIC(9,4), ? * 2"        "INSERT INTO T (ID, N4) VALUES (16, ? * 2)" '[1.11115]' N4 16
both "NUMERIC(9,2), ? * 2 * 2"    "INSERT INTO T (ID, N) VALUES (17, ? * 2 * 2)" '[1.115]' N 17
both "NUMERIC(9,2), (? * 2) + 0"  "INSERT INTO T (ID, N) VALUES (18, (? * 2) + 0)" '[1.115]' N 18
both "NUMERIC(9,2), ? * ?"        "INSERT INTO T (ID, N) VALUES (19, ? * ?)"  '[1.115, 2]' N 19
both "NUMERIC(9,2), bare ?"       "INSERT INTO T (ID, N) VALUES (20, ?)"      '[1.115]'   N  20

echo "-- an APPROXIMATE destination keeps its double --"
both "DOUBLE dest, ? * 2"         "INSERT INTO T (ID, DP) VALUES (30, ? * 2)" '[1.115]'   DP 30
both "DOUBLE dest, ? / 3"         "INSERT INTO T (ID, DP) VALUES (31, ? / 3)" '[10]'      DP 31

echo "-- a DECFLOAT destination: the arithmetic is decimal --"
both "DECFLOAT(34), ? / 3"        "INSERT INTO T (ID, DF) VALUES (40, ? / 3)" '[10]'      DF 40
both "DECFLOAT(34), ? * 3"        "INSERT INTO T (ID, DF) VALUES (41, ? * 3)" '[0.1]'     DF 41
both "DECFLOAT(34), bare ?"       "INSERT INTO T (ID, DF) VALUES (42, ?)"     '[10]'      DF 42
both "DECFLOAT(16), ? / 3"        "INSERT INTO T (ID, D16) VALUES (43, ? / 3)" '[10]'     D16 43

echo "-- COALESCE types from its OTHER arguments, and overflows there --"
both "COALESCE(?, 0) fits"        "INSERT INTO T (ID, I) VALUES (50, COALESCE(?, 0))" '[7]' I 50
both "COALESCE(?, 0) 2^40"        "INSERT INTO T (ID, I) VALUES (51, COALESCE(?, 0))" '[1099511627776]' I 51
both "COALESCE(?, 0) NULL"        "INSERT INTO T (ID, I) VALUES (52, COALESCE(?, 0))" '[null]' I 52

echo "-- UPDATE ... SET takes the same law --"
both "UPDATE SET N = ? * 2"       "UPDATE U SET N = ? * 2 WHERE ID = 1"       '[1.115]'   N  1 U
both "UPDATE SET N = 2 * ?"       "UPDATE U SET N = 2 * ? WHERE ID = 1"       '[1.115]'   N  1 U
both "UPDATE SET I = ? * 2"       "UPDATE U SET I = ? * 2 WHERE ID = 1"       '[1.6]'     I  1 U
both "UPDATE SET DF = ? / 3"      "UPDATE U SET DF = ? / 3 WHERE ID = 1"      '[10]'      DF 1 U

echo "-- a MERGE takes the same law, in both branches --"
# each check matches its OWN seeded row, so one never reads another's write
mg() { printf 'MERGE INTO MG USING (SELECT %s AS K FROM RDB$DATABASE) S ON MG.ID = S.K WHEN MATCHED THEN UPDATE SET %s' "$1" "$2"; }
mgi() { printf 'MERGE INTO MG USING (SELECT %s AS K FROM RDB$DATABASE) S ON MG.ID = S.K WHEN NOT MATCHED THEN INSERT (ID, %s) VALUES (S.K, %s)' "$1" "$2" "$3"; }
both "MERGE UPDATE I = ? * 2"     "$(mg 1 'I = ? * 2')"   '[1.6]'     I  1 MG
both "MERGE UPDATE N = ? * 2"     "$(mg 2 'N = ? * 2')"   '[1.115]'   N  2 MG
both "MERGE UPDATE N = 2 * ?"     "$(mg 3 'N = 2 * ?')"   '[1.115]'   N  3 MG
both "MERGE UPDATE N = ? / 2"     "$(mg 4 'N = ? / 2')"   '[1.115]'   N  4 MG
both "MERGE UPDATE N = ? + 0"     "$(mg 5 'N = ? + 0')"   '[1.115]'   N  5 MG
both "MERGE UPDATE DF = ? / 3"    "$(mg 6 'DF = ? / 3')"  '[10]'      DF 6 MG
both "MERGE UPDATE DF = ? * 3"    "$(mg 7 'DF = ? * 3')"  '[0.1]'     DF 7 MG
both "MERGE UPDATE N = ? (bare)"  "$(mg 8 'N = ?')"       '[1.115]'   N  8 MG
both "MERGE INSERT I = ? * 2"     "$(mgi 101 I '? * 2')"  '[1.6]'     I  101 MG
both "MERGE INSERT N = ? * 2"     "$(mgi 102 N '? * 2')"  '[1.115]'   N  102 MG
both "MERGE INSERT N = 2 * ?"     "$(mgi 103 N '2 * ?')"  '[1.115]'   N  103 MG
both "MERGE INSERT DF = ? / 3"    "$(mgi 104 DF '? / 3')" '[10]'      DF 104 MG
both "MERGE INSERT DF = ? * 3"    "$(mgi 105 DF '? * 3')" '[0.1]'     DF 105 MG
echo "-- ... and a marker in the ON / WHEN-AND still COMPARES, never converts --"
both "MERGE ON param + SET param"  "MERGE INTO MG USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON MG.ID = S.K AND MG.I = ? WHEN MATCHED THEN UPDATE SET N = ?" '[10, 5]' N 1 MG
both "MERGE WHEN-AND param"        "MERGE INTO MG USING (SELECT 2 AS K FROM RDB\$DATABASE) S ON MG.ID = S.K WHEN MATCHED AND MG.I = ? THEN UPDATE SET N = ? * 2" '[10, 1.115]' N 2 MG

echo "-- recorded refusals (fire-crab only) --"
# COALESCE types its parameter from its OTHER arguments, which MERGE's
# text-based typing does not reproduce - admitting the shape STORED
# 1.1000000000000001 where the engine stores 1, so it refuses instead
refuses "MERGE UPDATE DF = COALESCE(?, 0)" "MERGE INTO MG USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON MG.ID = S.K WHEN MATCHED THEN UPDATE SET DF = COALESCE(?, 0)" '[1.1]'
refuses "MERGE UPDATE I = COALESCE(?, 0)"  "MERGE INTO MG USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON MG.ID = S.K WHEN MATCHED THEN UPDATE SET I = COALESCE(?, 0)" '[1099511627776]'

[ $fail -eq 0 ] && echo "PASS serve-real-slottype" || { echo "FAIL serve-real-slottype"; exit 1; }
