#!/bin/bash
# A FLOAT compared with a FLOAT, an EXACT numeric or a TEXT value compares in
# SINGLE precision - both operands cast to FLOAT - as the engine does. Against
# a DOUBLE it compares in double, against a DECFLOAT in decimal.
#
# Measured against the live engine: `WHERE FL = 2.675` over a FLOAT column
# storing 2.675 matches (the literal casts to the same single), and so do
# 0.1, 1.1, 100.005, '2.675', 2.67500001, and 16777217 against the stored
# 16777216. fire-crab widened the column to double and compared there, so
# every one of those answered NO ROW, and every ordered form moved with it
# (`FL >= 2.675` dropped the 2.675 row, `FL <> 1.1` kept the 1.1 row).
# The FLOAT-typed expressions follow the same rule: CAST(.. AS FLOAT),
# -FL, ABS(FL), COALESCE(FL, 0), IIF(.., FL, 0), NULLIF(FL, 0), MIN(FL), a
# UNION of two FLOAT branches, an IN / ANY / EXISTS against an exact
# column. The DOUBLE-typed ones do NOT: FL * 1, FL / 1, SUM / AVG, a
# conditional with a DOUBLE branch, and a bound DOUBLE parameter all compare
# in double (no row for 2.675) - while a bound TEXT or INTEGER parameter
# compares in single. ROUND(FL, n) is an exact value in the engine and
# matches either way.
#
# Usage: qa/serve-real-floatcmp.sh [port]   (default 4178)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4178}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/flcmp-eng.fdb"; FC="$D/flcmp-fc.fdb"
HAVE_NODE=1
command -v node >/dev/null 2>&1 && node -e 'require("node-firebird")' 2>/dev/null || HAVE_NODE=0
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/flcmp-build.log 2>&1 <<'SQL'
CREATE TABLE TF (ID INTEGER, FL FLOAT, DP DOUBLE PRECISION, I INTEGER, N NUMERIC(9,3), BI BIGINT, I128 INT128, D16 DECFLOAT(16), VC VARCHAR(20), G INTEGER);
INSERT INTO TF VALUES (1, 2.675, 2.675, 2, 2.675, 2, 2, 2.675, '2.675', 1);
INSERT INTO TF VALUES (2, 0.1, 0.1, 0, 0.100, 0, 0, 0.1, '0.1', 1);
INSERT INTO TF VALUES (3, 1.1, 1.1, 1, 1.100, 1, 1, 1.1, '1.1', 2);
INSERT INTO TF VALUES (4, 16777217, 16777217, 16777217, 16777.217, 16777217, 16777217, 16777217, '16777217', 2);
INSERT INTO TF VALUES (5, 100.005, 100.005, 100, 100.005, 100, 100, 100.005, '100.005', 3);
INSERT INTO TF VALUES (6, -2.675, -2.675, -2, -2.675, -2, -2, -2.675, '-2.675', 3);
INSERT INTO TF VALUES (7, 3.4e38, 3.4e38, NULL, NULL, NULL, NULL, NULL, '3.4e38', 4);
INSERT INTO TF VALUES (8, 0.3, 0.30000001192092896, 0, 0.300, 0, 0, 0.3, '0.3', 4);
INSERT INTO TF VALUES (9, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 5);
INSERT INTO TF VALUES (10, 7, 7, 7, 7.000, 7, 7, 7, '7', 5);
CREATE TABLE TX (ID INTEGER, FL FLOAT, DP DOUBLE PRECISION, VC VARCHAR(40));
INSERT INTO TX VALUES (1, 100, 100, '1e2');
INSERT INTO TX VALUES (2, 9.2233720e18, 9.2233720e18, '9223372036854775807');
INSERT INTO TX VALUES (3, 0.1, 0.1, '0.1000000000000000000001');
INSERT INTO TX VALUES (4, 0.1, 0.1, ' 0.1 ');
INSERT INTO TX VALUES (5, 0.1, 0.1, '+0.1');
INSERT INTO TX VALUES (6, 2.5, 2.5, '2.5E0');
INSERT INTO TX VALUES (7, 0.1, 0.1, '.1');
INSERT INTO TX VALUES (8, 1e19, 1e19, '10000000000000000000');
INSERT INTO TX VALUES (9, 0.1, 0.1, '1e-1');
INSERT INTO TX VALUES (10, 1.5e-7, 1.5e-7, '1.5e-7');
INSERT INTO TX VALUES (11, 3.4e20, 3.4e20, '3.4e20');
INSERT INTO TX VALUES (12, 3.4e38, 3.4e38, '340000000000000000000000000000000000000');
INSERT INTO TX VALUES (13, 1e10, 1e10, '1e10');
INSERT INTO TX VALUES (14, 12345.678, 12345.678, '12345.678');
CREATE TABLE T2 (ID INTEGER, DP DOUBLE PRECISION, FL FLOAT, N NUMERIC(18,4));
INSERT INTO T2 VALUES (1, 2.675, 2.675, 2.675);
INSERT INTO T2 VALUES (8, 0.30000001192092896, 0.3, 0.3);
INSERT INTO T2 VALUES (3, 1.1, 1.1, 1.1);
COMMIT;
SQL
if grep -qi error /tmp/flcmp-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/flcmp-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-flcmp.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
q() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -a -v '^$' | sed 's/[[:space:]][[:space:]]*/ /g' | tr '\n' '|'; }
agree() { # <label> <sql>
    local e f
    e=$(q "127.0.0.1/3050:$ENG" "$2"); f=$(q "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     eng: $e"; echo "     fc:  $f"; fail=1; fi
}
ids() { agree "$1" "SELECT ID FROM TF WHERE $2 ORDER BY ID;"; }

echo "-- FLOAT vs an exact literal: single precision --"
for lit in 2.675 0.1 1.1 0.3 100.005 -2.675 16777217 16777216 7 2.67500001 2.6750001 2.6749999523162842 3.4e38; do
    ids "FL = $lit" "FL = $lit"
done
ids "FL > 2.675"               "FL > 2.675"
ids "FL >= 2.675"              "FL >= 2.675"
ids "FL < 0.1"                 "FL < 0.1"
ids "FL <= 0.1"                "FL <= 0.1"
ids "FL <> 1.1"                "FL <> 1.1"
ids "FL BETWEEN 1.1 AND 2.675" "FL BETWEEN 1.1 AND 2.675"
ids "FL IN (0.1, 2.675, 100.005)" "FL IN (0.1, 2.675, 100.005)"
ids "FL NOT IN (0.1, 2.675)"   "FL NOT IN (0.1, 2.675)"
ids "2.675 = FL (left)"        "2.675 = FL"
ids "FL = 2.675 OR FL = 1.1"   "FL = 2.675 OR FL = 1.1"
ids "NOT (FL <> 2.675)"        "NOT (FL <> 2.675)"
ids "FL IS NOT DISTINCT FROM 2.675" "FL IS NOT DISTINCT FROM 2.675"
echo "-- FLOAT vs a text literal: the text casts to single --"
ids "FL = '2.675'"             "FL = '2.675'"
ids "FL = '0.1'"               "FL = '0.1'"
ids "FL > '0.1'"               "FL > '0.1'"
echo "-- the text decides per value: a PLAIN decimal meets the FLOAT in single, an EXPONENT or too-wide text in double --"
agree "TX FL = VC (text column, per row)" "SELECT ID FROM TX WHERE FL = VC ORDER BY ID;"
agree "TX DP = VC (double column control)" "SELECT ID FROM TX WHERE DP = VC ORDER BY ID;"
for lit in "'0.1000000000000000000001'" "' 0.1 '" "'.1'" "'+0.1'" "'1e-1'" "'1.5e-7'" "'3.4e20'" "'10000000000000000000'" "'340000000000000000000000000000000000000'" "'1e10'" "'2.5E0'" "'12345.678'"; do
    agree "TX FL = $lit" "SELECT ID FROM TX WHERE FL = $lit ORDER BY ID;"
done
agree "TX FL > '0.1'" "SELECT ID FROM TX WHERE FL > '0.1' ORDER BY ID;"
echo "-- FLOAT vs a column --"
ids "FL = I"     "FL = I"
ids "FL = N"     "FL = N"
ids "FL = BI"    "FL = BI"
ids "FL = I128"  "FL = I128"
ids "FL = VC"    "FL = VC"
ids "FL = DP (double)"   "FL = DP"
ids "FL = D16 (decimal)" "FL = D16"
echo "-- FLOAT-typed expressions compare in single --"
ids "-FL = -2.675"                "-FL = -2.675"
ids "ABS(FL) = 2.675"             "ABS(FL) = 2.675"
ids "COALESCE(FL, 0) = 2.675"     "COALESCE(FL, 0) = 2.675"
ids "IIF(ID > 0, FL, 0) = 2.675"  "IIF(ID > 0, FL, 0) = 2.675"
ids "NULLIF(FL, 0) = 2.675"       "NULLIF(FL, 0) = 2.675"
ids "CAST(FL AS FLOAT) = 2.675"   "CAST(FL AS FLOAT) = 2.675"
ids "CAST(DP AS FLOAT) = 2.675"   "CAST(DP AS FLOAT) = 2.675"
echo "-- DOUBLE-typed expressions compare in double (no 2.675 row) --"
ids "FL + 0 = 2.675"                 "FL + 0 = 2.675"
ids "FL * 1 = 2.675"                 "FL * 1 = 2.675"
ids "FL / 1 = 2.675"                 "FL / 1 = 2.675"
ids "FL = 2.675e0 (double literal)"  "FL = 2.675e0"
ids "FL = CAST(2.675 AS DOUBLE PRECISION)" "FL = CAST(2.675 AS DOUBLE PRECISION)"
ids "CAST(FL AS DOUBLE PRECISION) = 2.675" "CAST(FL AS DOUBLE PRECISION) = 2.675"
ids "IIF(ID > 0, FL, DP) = 2.675"    "IIF(ID > 0, FL, DP) = 2.675"
ids "ROUND(FL, 3) = 2.675 (exact)"   "ROUND(FL, 3) = 2.675"
echo "-- the verdict as a value: CASE / IIF / NULLIF / a boolean --"
agree "NULLIF(FL, 2.675)"            "SELECT ID, NULLIF(FL, 2.675) FROM TF WHERE ID IN (1, 3) ORDER BY ID;"
agree "CASE FL WHEN 2.675"           "SELECT ID, CASE FL WHEN 2.675 THEN 'hit' ELSE 'miss' END FROM TF WHERE ID IN (1, 3) ORDER BY ID;"
agree "IIF(FL = 1.1, ..)"            "SELECT ID, IIF(FL = 1.1, 'hit', 'miss') FROM TF WHERE ID IN (1, 3) ORDER BY ID;"
agree "FL = 2.675 as a boolean"      "SELECT ID, FL = 2.675 FROM TF WHERE ID IN (1, 3) ORDER BY ID;"
echo "-- through derived tables, UNION, aggregates, subqueries, joins --"
agree "derived FL = 2.675"           "SELECT ID FROM (SELECT ID, FL FROM TF) Q WHERE FL = 2.675 ORDER BY ID;"
agree "CTE FL = 1.1"                 "WITH C AS (SELECT ID, FL FROM TF) SELECT ID FROM C WHERE FL = 1.1 ORDER BY ID;"
agree "UNION ALL FLOAT/FLOAT"        "SELECT ID FROM (SELECT ID, FL FROM TF UNION ALL SELECT ID, FL FROM TF) Q WHERE FL = 2.675 ORDER BY ID;"
agree "UNION ALL FLOAT/DOUBLE"       "SELECT ID FROM (SELECT ID, FL FROM TF UNION ALL SELECT ID, DP FROM TF) Q WHERE FL = 2.675 ORDER BY ID;"
agree "HAVING MIN(FL) = 0.1"         "SELECT G FROM TF GROUP BY G HAVING MIN(FL) = 0.1 ORDER BY G;"
agree "HAVING MAX(FL) = 1.1"         "SELECT G FROM TF GROUP BY G HAVING MAX(FL) = 1.1 ORDER BY G;"
agree "HAVING SUM(FL) = 2.775 (double)" "SELECT G FROM TF GROUP BY G HAVING SUM(FL) = 2.775 ORDER BY G;"
agree "HAVING AVG(FL) (double)"      "SELECT G FROM TF GROUP BY G HAVING AVG(FL) = 1.3875 ORDER BY G;"
agree "derived MIN(FL) = 2.675"      "SELECT ID FROM (SELECT ID, MIN(FL) M FROM TF GROUP BY ID) Q WHERE M = 2.675 ORDER BY ID;"
agree "FL = (SELECT FL)"             "SELECT ID FROM TF WHERE FL = (SELECT FL FROM T2 WHERE ID = 1) ORDER BY ID;"
agree "FL = (SELECT DP) double"      "SELECT ID FROM TF WHERE FL = (SELECT DP FROM T2 WHERE ID = 1) ORDER BY ID;"
agree "FL = (SELECT N) single"       "SELECT ID FROM TF WHERE FL = (SELECT N FROM T2 WHERE ID = 3) ORDER BY ID;"
agree "FL IN (SELECT N)"             "SELECT ID FROM TF WHERE FL IN (SELECT N FROM T2) ORDER BY ID;"
agree "FL = ANY (SELECT N)"          "SELECT ID FROM TF WHERE FL = ANY (SELECT N FROM T2) ORDER BY ID;"
agree "EXISTS correlated N = FL"     "SELECT ID FROM TF A WHERE EXISTS (SELECT 1 FROM T2 B WHERE B.N = A.FL) ORDER BY ID;"
agree "JOIN ON FL = DP (double)"     "SELECT A.ID FROM TF A JOIN T2 B ON A.FL = B.DP ORDER BY A.ID;"
agree "JOIN ON FL = FL"              "SELECT A.ID FROM TF A JOIN T2 B ON A.FL = B.FL ORDER BY A.ID;"
agree "JOIN ON FL = N (single)"      "SELECT A.ID FROM TF A JOIN T2 B ON A.FL = B.N ORDER BY A.ID;"
echo "-- DML filters --"
agree "UPDATE .. WHERE FL = 1.1"     "UPDATE TF SET G = 77 WHERE FL = 1.1; SELECT ID FROM TF WHERE G = 77 ORDER BY ID;"
agree "DELETE .. WHERE FL = 0.1"     "DELETE FROM TF WHERE FL = 0.1; SELECT COUNT(*) FROM TF;"
echo "-- regression controls: ordering, arithmetic, the render --"
agree "ORDER BY FL"                  "SELECT ID FROM TF ORDER BY FL, ID;"
agree "FL - 2.675 value"             "SELECT ID, FL - 2.675 FROM TF WHERE ID = 1;"
agree "DISTINCT FL"                  "SELECT COUNT(DISTINCT FL) FROM TF;"
agree "DP = 2.675 (double col)"      "SELECT ID FROM TF WHERE DP = 2.675 ORDER BY ID;"
agree "DP = 0.3 (double col)"        "SELECT ID FROM TF WHERE DP = 0.3 ORDER BY ID;"

if [ $HAVE_NODE = 1 ]; then
    echo "-- bound parameters: a DOUBLE compares in double, a TEXT or INTEGER in single --"
    node_at() { # <port> <db> <query> <json-params>
        FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
          process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(1);}
            db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
              if(e2){console.log("ERR "+String(e2.message||e2).split("\n")[0]);db.detach();process.exit(0);}
              console.log(r&&r.length?r.map(x=>Object.values(x).join()).join(";"):"(none)");db.detach();process.exit(0);
            });
          });' 2>/dev/null
    }
    both() {
        local e f
        e=$(node_at 3050 "$ENG" "$2" "$3"); f=$(node_at "$PORT" "$FC" "$2" "$3")
        if [ "$e" = "$f" ]; then echo "OK   $1 [$3]"; else echo "DIFF $1 [$3]"; echo "     eng: $e"; echo "     fc:  $f"; fail=1; fi
    }
    for p in '[2.675]' '["2.675"]' '[16777217]' '[0.1]' '["0.1"]' '[7]' '["1.1"]'; do
        both "FL = ?"  "SELECT ID FROM TF WHERE FL = ? ORDER BY ID" "$p"
        both "FL > ?"  "SELECT ID FROM TF WHERE FL > ? ORDER BY ID" "$p"
        both "derived FL = ?" "SELECT ID FROM (SELECT ID, FL FROM TF) Q WHERE FL = ? ORDER BY ID" "$p"
        both "DP = ? (double col)" "SELECT ID FROM TF WHERE DP = ? ORDER BY ID" "$p"
    done
fi

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS floatcmp" || echo "FAIL floatcmp"
exit $fail
