#!/bin/bash
# THE ENGINE'S TEXT FORM OF A NON-FINITE DOUBLE, in both directions.
#
# OUTPUT: a non-finite double renders LOWER CASE and SHORT - `nan`,
# `inf`, `-inf`.  This server rendered `NaN`, `Infinity`, `-Infinity`,
# and that is NOT cosmetic: `CAST(? AS VARCHAR(30)) = 'inf'` is TRUE on
# the engine and was FALSE here, `CHAR_LENGTH` of it is 3 and not 8, a
# CHAR(10) pads `inf       ` and not `Infinity  `, and the round's
# refuter counted ELEVEN routers the text reaches, TWO OF THEM
# ROW-MUTATING (a stored VARCHAR column and a trigger's computed text).
#
# INPUT: the engine accepts NO non-finite spelling as a number and raises
# 22018 for every one - `D = 'Infinity'`, `D = 'inf'`, `D = 'nan'`,
# `D < 'Infinity'`.  This server accepted them all, because Rust's own
# f64 parser reads `nan` / `inf` / `infinity` in any case; and
# `D = 'nan'` then answered EVERY ROW, since the NaN it had parsed
# compared equal to everything.  The sibling paths were already right
# ([text_to_approx] ends with `d.is_finite()`, and a TEXT *bind* refuses)
# - the LITERAL arm was the one that was not.
#
# AND A WRITTEN CAST TO TEXT ABSORBS THE NaN, by rendering it: past the
# cast there is no double left, only the string `nan`, and the
# comparison above it is an ordinary text comparison.  Measured over all
# six operators and both operand orders - the engine's answers are
# exactly what comparing the literal string `nan` gives.
#
# EVERY CELL COMPARES THE VALUE *AND* THE WHOLE DESCRIBE.  A non-finite
# is written "#NaN" / "#Inf" / "#-Inf" in the JSON binds; node-firebird
# sends all three as blr_double.  `panic_free` at the end is what makes
# an ERR above mean "refused" rather than "crashed".
#
# Usage: qa/serve-real-nonfinitetext.sh [port]   (default 4441)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4441}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nonfinitetext-eng.fdb"; FC="$D/nonfinitetext-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/nonfinitetext-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, SM SMALLINT, NM NUMERIC(9,2), N18 NUMERIC(18,1),
                BI BIGINT, H INT128, D DOUBLE PRECISION, FL FLOAT, S VARCHAR(20));
CREATE TABLE TI (ID INTEGER NOT NULL PRIMARY KEY, SM SMALLINT, NM NUMERIC(9,2), N18 NUMERIC(18,1),
                BI BIGINT, H INT128, D DOUBLE PRECISION, FL FLOAT, S VARCHAR(20));
CREATE TABLE TE (ID INTEGER, SM SMALLINT, NM NUMERIC(9,2), N18 NUMERIC(18,1),
                BI BIGINT, H INT128, D DOUBLE PRECISION, FL FLOAT, S VARCHAR(20));
CREATE TABLE TN (ID INTEGER, D DOUBLE PRECISION, FL FLOAT, N INTEGER, NM NUMERIC(9,2));
CREATE TABLE TNI (ID INTEGER NOT NULL PRIMARY KEY, D DOUBLE PRECISION, FL FLOAT, N INTEGER, NM NUMERIC(9,2));
CREATE TABLE U (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, D DOUBLE PRECISION);
COMMIT;
INSERT INTO T VALUES (-3, -3, -2.50, -2.5, -3, -3, -2.5, -2.5, '-3');
INSERT INTO T VALUES (0, 0, 0.00, 0.0, 0, 0, 0, 0, '0');
INSERT INTO T VALUES (1, 1, 7.24, 1.0, 1, 1, 1, 1, '1');
INSERT INTO T VALUES (2, 2, 2.50, 2.5, 2, 2, 2.5, 2.675, '2.5');
INSERT INTO T VALUES (3, 3, 2.49, 2.4, 3, 3, 3, 3, '3');
INSERT INTO T VALUES (9, 9, 1234567.01, 900719925474099.3, 9, 9, 9, 9, '9');
INSERT INTO TI SELECT * FROM T;
INSERT INTO TE SELECT * FROM T;
INSERT INTO TN VALUES (1, 1.5, 1.5, 1, 1.50);
INSERT INTO TN VALUES (2, NULL, NULL, NULL, NULL);
INSERT INTO TN VALUES (3, -2.5, -2.5, -2, -2.50);
INSERT INTO TNI SELECT * FROM TN;
INSERT INTO U VALUES (1, 1, 1);
INSERT INTO U VALUES (2, 2, 2.5);
INSERT INTO U VALUES (3, 3, 3);
COMMIT;
CREATE INDEX TI_SM ON TI (SM);
CREATE INDEX TI_NM ON TI (NM);
CREATE INDEX TI_N18 ON TI (N18);
CREATE INDEX TI_BI ON TI (BI);
CREATE INDEX TI_H ON TI (H);
CREATE INDEX TI_D ON TI (D);
CREATE INDEX TI_FL ON TI (FL);
CREATE INDEX TI_S ON TI (S);
CREATE INDEX TNI_D ON TNI (D);
CREATE INDEX TNI_FL ON TNI (FL);
CREATE INDEX TNI_N ON TNI (N);
CREATE INDEX TNI_NM ON TNI (NM);
COMMIT;
CREATE INDEX TE_D0 ON TE COMPUTED BY (D + 0);
CREATE INDEX TE_ID0 ON TE COMPUTED BY (ID + 0);
COMMIT;
CREATE VIEW V1 AS SELECT ID, SM, NM, N18, BI, H, D, FL, S FROM T;
CREATE VIEW VI AS SELECT ID, SM, NM, N18, BI, H, D, FL, S FROM TI;
COMMIT;
SQL
if grep -qi error /tmp/nonfinitetext-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/nonfinitetext-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
# SENTINEL - the fixture must really be there, or every cell below would
# compare empty with empty and print OK (the defect `serve-real-list.sh`
# carried unnoticed until 2026-09-20)
for cs in "127.0.0.1/$REAL:$ENG" "127.0.0.1/$REAL:$ENG"; do :; done
n=$(echo "SET HEADING OFF; SELECT COUNT(*) FROM T;" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d ' \n')
[ "$n" = "6" ] || { echo "FAIL fixture did not load: COUNT(*) FROM T = [$n], expected 6"; exit 1; }

SRVLOG="/tmp/fc-serve-nonfinitetext-$PORT.log"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$SRVLOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
LOST='const lost=e=>/was lost|ECONNRESET|EPIPE|Connection is closed|socket hang up/i.test(String((e&&e.message)||e));'
RV='const rv=v=>v==="#NaN"?NaN:v==="#Inf"?Infinity:v==="#-Inf"?-Infinity:v;'
FMT='const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":v).join()).join(";");'
q() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e "$LOST$RV$FMT"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,JSON.parse(process.env.FC_P).map(rv),(e2,r)=>{
      if(e2){if(lost(e2)){console.log("CONN_ERR");process.exit(1);}console.log("ERR");db.detach();process.exit(0);}
      console.log(fmt(r));db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
run() { local n=0 r; while [ $n -lt 8 ]; do r=$(q "$1" "$2" "$3" "$4")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
qtx() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_RB="$5" timeout 25 node -e "$LOST$RV$FMT"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      if(et){console.log("CONN_ERR");process.exit(1);}
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P).map(rv),(e2,r)=>{
        if(e2&&lost(e2)){console.log("CONN_ERR");process.exit(1);}
        const dml=e2?"ERR":fmt(r);
        tr.query(process.env.FC_RB,[],(e3,r2)=>{
          if(e3&&lost(e3)){console.log("CONN_ERR");process.exit(1);}
          const rb=e3?"ERR":fmt(r2);
          tr.rollback(()=>{console.log("dml="+dml+" rb="+rb);db.detach();process.exit(0);});
        });
      });
    });
  });' 2>/dev/null; }
runtx() { local n=0 r; while [ $n -lt 8 ]; do r=$(qtx "$1" "$2" "$3" "$4" "$5")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }

# the value AND the whole describe must match
both() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] && [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - that is a both_refuse cell]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - the value agrees, the announcement does not)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the VALUE is right and the ANNOUNCEMENT is not - recorded, self-expiring
desc_differs() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$fv" ]; then
        echo "FAIL $1 - the VALUE diverged, which this cell does not cover"
        echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" = "$fd" ]; then
        echo "FAIL $1 - THE DESCRIBE GAP IS CLOSED; promote this cell to \`both\`"; fail=1
    else echo "OK   $1 (recorded describe gap)"; fi
}
# the engine ANSWERS and this server refuses - here always because the
# ENGINE ITSELF HAS TWO ANSWERS and this server will not pick one
eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE no longer answers; the boundary moved"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS SERVER ANSWERS [$fv] where it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
both_refuse() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" != ERR ]; then echo "FAIL $1 - the ENGINE answered [$ev]"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    else echo "OK   both refuse: $1"; fi
}
# a DML + read-back in a rolled-back transaction
dml_rb() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE refused the DML [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (the RETURNING rows or the read-back)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $1 [$ev] (rolled back)"; fi
}
# the engine WRITES and this server refuses - its rows must be untouched
dml_rb_eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then
        echo "FAIL $1 - the ENGINE refused the DML [$ev]; the boundary moved"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then
        echo "FAIL $1 - THIS SERVER PERFORMED THE DML [$fv]; it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}

echo "-- 1. OUTPUT: how a non-finite double RENDERS --"
both             "1 CAST(? AS VARCHAR(30)) [NaN] -> nan, lower case and short (engine nan)" "SELECT CAST(? AS VARCHAR(30)) X FROM RDB\$DATABASE" '["#NaN"]'
both             "1 CAST(? AS CHAR(10)) [NaN] - padded to the CHAR width (engine nan + blanks)" "SELECT CAST(? AS CHAR(10)) X FROM RDB\$DATABASE" '["#NaN"]'
both             "1 CAST(? AS VARCHAR(30)) [+Inf] -> inf, lower case and short (engine inf)" "SELECT CAST(? AS VARCHAR(30)) X FROM RDB\$DATABASE" '["#Inf"]'
both             "1 CAST(? AS CHAR(10)) [+Inf] - padded to the CHAR width (engine inf + blanks)" "SELECT CAST(? AS CHAR(10)) X FROM RDB\$DATABASE" '["#Inf"]'
both             "1 CAST(? AS VARCHAR(30)) [-Inf] -> -inf, lower case and short (engine -inf)" "SELECT CAST(? AS VARCHAR(30)) X FROM RDB\$DATABASE" '["#-Inf"]'
both             "1 CAST(? AS CHAR(10)) [-Inf] - padded to the CHAR width (engine -inf + blanks)" "SELECT CAST(? AS CHAR(10)) X FROM RDB\$DATABASE" '["#-Inf"]'
both             "1 CONTROL CAST(? AS VARCHAR(30)) [2.5] - a finite value is untouched (engine 2.500000000000000)" "SELECT CAST(? AS VARCHAR(30)) X FROM RDB\$DATABASE" '[2.5]'

echo "-- 2. ...and the VERDICT and the LENGTH it decides --"
# The whole point: the spelling is read back by SQL, not just printed.
both             "2 CAST(? AS VARCHAR(30)) = 'inf' [NaN] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) = 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#NaN"]'
both             "2 CAST(? AS VARCHAR(30)) <> 'inf' [NaN] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) <> 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#NaN"]'
both             "2 CAST(? AS VARCHAR(30)) < 'inf' [NaN] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) < 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#NaN"]'
both             "2 CAST(? AS VARCHAR(30)) > 'inf' [NaN] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) > 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#NaN"]'
both             "2 CAST(? AS VARCHAR(30)) <= 'inf' [NaN] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) <= 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#NaN"]'
both             "2 CAST(? AS VARCHAR(30)) >= 'inf' [NaN] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) >= 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#NaN"]'
both             "2 CAST(? AS VARCHAR(30)) = 'inf' [+Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) = 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#Inf"]'
both             "2 CAST(? AS VARCHAR(30)) <> 'inf' [+Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) <> 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#Inf"]'
both             "2 CAST(? AS VARCHAR(30)) < 'inf' [+Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) < 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#Inf"]'
both             "2 CAST(? AS VARCHAR(30)) > 'inf' [+Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) > 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#Inf"]'
both             "2 CAST(? AS VARCHAR(30)) <= 'inf' [+Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) <= 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#Inf"]'
both             "2 CAST(? AS VARCHAR(30)) >= 'inf' [+Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) >= 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#Inf"]'
both             "2 CAST(? AS VARCHAR(30)) = 'inf' [-Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) = 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#-Inf"]'
both             "2 CAST(? AS VARCHAR(30)) <> 'inf' [-Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) <> 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#-Inf"]'
both             "2 CAST(? AS VARCHAR(30)) < 'inf' [-Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) < 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#-Inf"]'
both             "2 CAST(? AS VARCHAR(30)) > 'inf' [-Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) > 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#-Inf"]'
both             "2 CAST(? AS VARCHAR(30)) <= 'inf' [-Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) <= 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#-Inf"]'
both             "2 CAST(? AS VARCHAR(30)) >= 'inf' [-Inf] - a WRITTEN TEXT CAST absorbs the value and this is an ordinary text comparison" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) >= 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#-Inf"]'
both             "2 CAST(? AS VARCHAR(30)) = S [NaN] - the cast against a text COLUMN (engine (none))" "SELECT ID FROM T WHERE CAST(? AS VARCHAR(30)) = S ORDER BY ID" '["#NaN"]'
both             "2 S < CAST(? AS VARCHAR(30)) [NaN] - the column written first (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE S < CAST(? AS VARCHAR(30)) ORDER BY ID" '["#NaN"]'
both             "2 CAST(? AS CHAR(3)) = 'inf' [+Inf] - through CHAR (engine 1)" "SELECT CASE WHEN CAST(? AS CHAR(3)) = 'inf' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '["#Inf"]'
both             "2 CONTROL CAST(? AS VARCHAR(30)) = '2.500000000000000' [2.5] - a finite value through the same router (engine 1)" "SELECT CASE WHEN CAST(? AS VARCHAR(30)) = '2.500000000000000' THEN 1 ELSE 0 END X FROM RDB\$DATABASE" '[2.5]'

echo "-- 3. INPUT: a non-finite SPELLING is not a number to this engine --"
both_refuse      "3 D = 'Infinity' - the engine raises 22018; this server used to ANSWER" "SELECT ID FROM T WHERE D = 'Infinity' ORDER BY ID" '[]'
both_refuse      "3 D = 'inf' - the engine raises 22018; this server used to ANSWER" "SELECT ID FROM T WHERE D = 'inf' ORDER BY ID" '[]'
both_refuse      "3 D = 'nan' - the engine raises 22018; this server used to ANSWER" "SELECT ID FROM T WHERE D = 'nan' ORDER BY ID" '[]'
both_refuse      "3 D = 'NaN' - the engine raises 22018; this server used to ANSWER" "SELECT ID FROM T WHERE D = 'NaN' ORDER BY ID" '[]'
both_refuse      "3 D = '-inf' - the engine raises 22018; this server used to ANSWER" "SELECT ID FROM T WHERE D = '-inf' ORDER BY ID" '[]'
both_refuse      "3 D = '+INF' - the engine raises 22018; this server used to ANSWER" "SELECT ID FROM T WHERE D = '+INF' ORDER BY ID" '[]'
both_refuse      "3 D = 'infinity' - the engine raises 22018; this server used to ANSWER" "SELECT ID FROM T WHERE D = 'infinity' ORDER BY ID" '[]'
both_refuse      "3 D < 'Infinity' - the ordering operators too" "SELECT ID FROM T WHERE D < 'Infinity' ORDER BY ID" '[]'
both_refuse      "3 D > 'nan' - ...and this one used to answer EVERY ROW, the NaN comparing equal to everything" "SELECT ID FROM T WHERE D > 'nan' ORDER BY ID" '[]'
both_refuse      "3 CAST('inf' AS DOUBLE PRECISION) - the CAST path was already right" "SELECT CAST('inf' AS DOUBLE PRECISION) X FROM RDB\$DATABASE" '[]'
both_refuse      "3 CAST('nan' AS DOUBLE PRECISION) - likewise" "SELECT CAST('nan' AS DOUBLE PRECISION) X FROM RDB\$DATABASE" '[]'
both_refuse      "3 D = ? ['inf'] - a TEXT BIND was already right too" "SELECT ID FROM T WHERE D = ? ORDER BY ID" '["inf"]'
both             "3 CONTROL D = '2.5' - an ordinary numeric text is unaffected (engine 2)" "SELECT ID FROM T WHERE D = '2.5' ORDER BY ID" '[]'
both             "3 CONTROL D > '2.4' (engine 2;3;9)" "SELECT ID FROM T WHERE D > '2.4' ORDER BY ID" '[]'
both             "3 CONTROL CAST('2.5' AS DOUBLE PRECISION) (engine 2.5)" "SELECT CAST('2.5' AS DOUBLE PRECISION) X FROM RDB\$DATABASE" '[]'

# the server's stderr log is the ONE place a PANIC shows
panic_free() {
    ran=$((ran + 1))
    local n
    n=$(grep -ac 'panicked at' "$SRVLOG" 2>/dev/null); [ -n "$n" ] || n=0
    if ! kill -0 $srv 2>/dev/null; then
        echo "FAIL the server DIED during the run"; fail=1
    elif [ "$n" != 0 ]; then
        echo "FAIL the server PANICKED $n time(s) - an ERR above may be a crash, not a refusal"
        grep -a 'panicked at' "$SRVLOG" | head -5 | sed 's/^/     /'; fail=1
    else echo "OK   no panic in $SRVLOG and the server is still up"; fi
}
panic_free

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN, never typed.
if [ "$ran" -lt 45 ]; then
    echo "FAIL only $ran checks ran; 45 were measured - cells went missing"; fail=1
fi
exit $fail
