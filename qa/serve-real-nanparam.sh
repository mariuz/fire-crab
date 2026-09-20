#!/bin/bash
# A NaN COMPARISON IS DECIDED BY THE WRITTEN ORDER AND THE OTHER SIDE'S
# CLASS - the chunk that narrows an OVER-REFUSAL.
#
# Until 2026-09-20 this server refused almost every comparison whose
# parameter was bound a NaN.  The refusal was recorded as a boundary
# ("a NaN has no single engine order"), and that was half true: the
# engine's order is not a total order, but it is DETERMINED, and the
# access path matters for exactly ONE shape.  Measured over 72 cells -
# six operators x both WRITTEN ORDERS x DOUBLE / FLOAT / INTEGER /
# SMALLINT / BIGINT / INT128 / NUMERIC(9,2) / NUMERIC(18,1), each on a
# HEAP twin, an INDEXED twin and an EXPRESSION-INDEX twin - plus 39 more
# over a table with NULL rows:
#
#   * WHICH OPERAND IS THE LESSER.  Against a DOUBLE PRECISION side THE
#     FIRST-WRITTEN OPERAND IS THE LESSER, so the verdict FLIPS when the
#     same term is written the other way round: `D < ?` is every row and
#     `? < D` is none of them on the indexed twin.  Against a FLOAT
#     (single) or an EXACT side the NaN is ALWAYS the lesser.
#     [parse_leaf] rewrites `? op X` into `X mirror(op) ?`, so ONE term
#     carries both spellings and [RawTerm::mirrored] is the only thing
#     that tells them apart - which is why this law could not be written
#     before that flag existed.
#
#   * WHETHER EVERY ACCESS PATH AGREES.  A FALSE verdict always does: an
#     emptied index range cannot turn a row that does not match into one
#     that does.  A TRUE verdict does too, EXCEPT ON A LOWER BOUND
#     (`>` / `>=` as the term is stored), where the engine's index range
#     over a NaN is empty or partial and its scan is not - `ID > ?` [NaN]
#     is every row on a heap and NONE on the indexed twin, and `BI > ?`
#     is every row against `1;2;3;9`.  THOSE, AND ONLY THOSE, REFUSE.
#
# THE PREVIOUS BINARY read a NaN as EQUAL to everything
# (`partial_cmp().unwrap_or(Equal)`), which is the engine's verdict on
# some of these and wrong on the rest; the binary before this chunk
# refused 64 of the 72 outright.
#
# EVERY CELL IS EMITTED TWICE, once on the heap twin T and once on the
# INDEXED twin TI, because the split is the whole question - a cell that
# runs on one table only cannot see it.  A NULL row is carried in TN/TNI
# for the same reason: the verdict must be UNKNOWN there, not the
# constant, and a fixture without NULLs cannot tell.
#
# INSTRUMENT: node-firebird sends NaN and +-Infinity as blr_double; they
# are written "#NaN" / "#Inf" / "#-Inf" in the JSON binds.  A server
# PANIC reaches node as an ordinary query error - the same word as a
# refusal - so `panic_free` at the end is what makes every ERR above
# mean "refused" rather than "crashed".
#
# Usage: qa/serve-real-nanparam.sh [port]   (default 4417)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4417}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nanparam-eng.fdb"; FC="$D/nanparam-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/nanparam-build.log 2>&1 <<SQL
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
if grep -qi error /tmp/nanparam-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/nanparam-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
# SENTINEL - the fixture must really be there, or every cell below would
# compare empty with empty and print OK (the defect `serve-real-list.sh`
# carried unnoticed until 2026-09-20)
for cs in "127.0.0.1/$REAL:$ENG" "127.0.0.1/$REAL:$ENG"; do :; done
n=$(echo "SET HEADING OFF; SELECT COUNT(*) FROM T;" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d ' \n')
[ "$n" = "6" ] || { echo "FAIL fixture did not load: COUNT(*) FROM T = [$n], expected 6"; exit 1; }

SRVLOG="/tmp/fc-serve-nanparam-$PORT.log"
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

# EVERY FLOAT (single-precision) CELL BELOW IS A `desc_differs`, NOT A
# `both`: its VALUE is the engine's on every path, and the SLOT is
# announced `480 DOUBLE len 8` here where the engine says `482 FLOAT
# len 4`.  That gap is OLDER THAN THIS CHUNK - `qa/serve-real-dblparam.sh`
# records it for an ordinary bind too - and the helper goes red the day it
# closes, which is the signal to promote these back to `both`.
echo "-- 1. THE ORDER LAW: the column written FIRST --"
both             "1 D < ? [NaN] -> -3;0;1;2;3;9 on the heap AND indexed (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D < ? ORDER BY ID" '["#NaN"]'
both             "1 TI.D < ? [NaN] -> -3;0;1;2;3;9 (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE D < ? ORDER BY ID" '["#NaN"]'
both             "1 D <= ? [NaN] -> -3;0;1;2;3;9 on the heap AND indexed (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D <= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.D <= ? [NaN] -> -3;0;1;2;3;9 (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE D <= ? ORDER BY ID" '["#NaN"]'
both             "1 D > ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE D > ? ORDER BY ID" '["#NaN"]'
both             "1 TI.D > ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE D > ? ORDER BY ID" '["#NaN"]'
both             "1 D >= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE D >= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.D >= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE D >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP D = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE D = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP D <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D <> ? ORDER BY ID" '["#NaN"]'
desc_differs     "1 FL < ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE FL < ? ORDER BY ID" '["#NaN"]'
desc_differs     "1 TI.FL < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE FL < ? ORDER BY ID" '["#NaN"]'
desc_differs     "1 FL <= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE FL <= ? ORDER BY ID" '["#NaN"]'
desc_differs     "1 TI.FL <= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE FL <= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 FL > ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE FL > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.FL > ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE FL > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 FL >= ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE FL >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.FL >= ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE FL >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP FL = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE FL = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP FL <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE FL <> ? ORDER BY ID" '["#NaN"]'
both             "1 ID < ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '["#NaN"]'
both             "1 TI.ID < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ID < ? ORDER BY ID" '["#NaN"]'
both             "1 ID <= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE ID <= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.ID <= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ID <= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 ID > ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.ID > ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 ID >= ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE ID >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.ID >= ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE ID >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP ID = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP ID <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID <> ? ORDER BY ID" '["#NaN"]'
both             "1 SM < ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE SM < ? ORDER BY ID" '["#NaN"]'
both             "1 TI.SM < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE SM < ? ORDER BY ID" '["#NaN"]'
both             "1 SM <= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE SM <= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.SM <= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE SM <= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 SM > ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE SM > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.SM > ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE SM > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 SM >= ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE SM >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.SM >= ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE SM >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP SM = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE SM = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP SM <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE SM <> ? ORDER BY ID" '["#NaN"]'
both             "1 BI < ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE BI < ? ORDER BY ID" '["#NaN"]'
both             "1 TI.BI < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE BI < ? ORDER BY ID" '["#NaN"]'
both             "1 BI <= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE BI <= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.BI <= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE BI <= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 BI > ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed 1;2;3;9 - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE BI > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.BI > ? [NaN] - the indexed half of that split (engine 1;2;3;9)" "SELECT ID FROM TI WHERE BI > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 BI >= ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed 0;1;2;3;9 - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE BI >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.BI >= ? [NaN] - the indexed half of that split (engine 0;1;2;3;9)" "SELECT ID FROM TI WHERE BI >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP BI = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE BI = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP BI <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE BI <> ? ORDER BY ID" '["#NaN"]'
both             "1 H < ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE H < ? ORDER BY ID" '["#NaN"]'
both             "1 TI.H < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE H < ? ORDER BY ID" '["#NaN"]'
both             "1 H <= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE H <= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.H <= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE H <= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 H > ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed 1;2;3;9 - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE H > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.H > ? [NaN] - the indexed half of that split (engine 1;2;3;9)" "SELECT ID FROM TI WHERE H > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 H >= ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed 0;1;2;3;9 - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE H >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.H >= ? [NaN] - the indexed half of that split (engine 0;1;2;3;9)" "SELECT ID FROM TI WHERE H >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP H = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE H = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP H <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE H <> ? ORDER BY ID" '["#NaN"]'
both             "1 NM < ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE NM < ? ORDER BY ID" '["#NaN"]'
both             "1 TI.NM < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE NM < ? ORDER BY ID" '["#NaN"]'
both             "1 NM <= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE NM <= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.NM <= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE NM <= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 NM > ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE NM > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.NM > ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE NM > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 NM >= ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed (none) - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE NM >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.NM >= ? [NaN] - the indexed half of that split (engine (none))" "SELECT ID FROM TI WHERE NM >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP NM = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE NM = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP NM <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE NM <> ? ORDER BY ID" '["#NaN"]'
both             "1 N18 < ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE N18 < ? ORDER BY ID" '["#NaN"]'
both             "1 TI.N18 < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE N18 < ? ORDER BY ID" '["#NaN"]'
both             "1 N18 <= ? [NaN] -> (none) on the heap AND indexed (engine (none))" "SELECT ID FROM T WHERE N18 <= ? ORDER BY ID" '["#NaN"]'
both             "1 TI.N18 <= ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE N18 <= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 N18 > ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed 1;2;3;9 - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE N18 > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.N18 > ? [NaN] - the indexed half of that split (engine 1;2;3;9)" "SELECT ID FROM TI WHERE N18 > ? ORDER BY ID" '["#NaN"]'
eng_only         "1 N18 >= ? [NaN] - the engine SPLITS: heap -3;0;1;2;3;9, indexed 0;1;2;3;9 - a TRUE verdict on a LOWER BOUND, the one shape an index range answers differently" "SELECT ID FROM T WHERE N18 >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 TI.N18 >= ? [NaN] - the indexed half of that split (engine 0;1;2;3;9)" "SELECT ID FROM TI WHERE N18 >= ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP N18 = ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine (none))" "SELECT ID FROM T WHERE N18 = ? ORDER BY ID" '["#NaN"]'
eng_only         "1 CAP N18 <> ? [NaN] - an EQUALITY is one tree with an IN list, and an IN list with a NaN is a RANGE on a DOUBLE column and a ZERO on a SMALLINT one (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE N18 <> ? ORDER BY ID" '["#NaN"]'

echo "-- 2. THE SAME TERMS WRITTEN THE OTHER WAY ROUND --"
# [parse_leaf] rewrites `? op X` into `X mirror(op) ?`, so ONE term carries
# both spellings and only [RawTerm::mirrored] tells them apart.  Against a
# DOUBLE side the verdict FLIPS here; against every other side it does not,
# because a NaN is the lesser there whichever way it is written.
eng_only         "2 ? < D [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? < D ORDER BY ID" '["#NaN"]'
eng_only         "2 ? < TI.D [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? < D ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= D [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? <= D ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= TI.D [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? <= D ORDER BY ID" '["#NaN"]'
both             "2 ? > D [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? > D ORDER BY ID" '["#NaN"]'
both             "2 ? > TI.D [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? > D ORDER BY ID" '["#NaN"]'
both             "2 ? >= D [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? >= D ORDER BY ID" '["#NaN"]'
both             "2 ? >= TI.D [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? >= D ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? = D [NaN] - the capped equality, mirrored (engine (none))" "SELECT ID FROM T WHERE ? = D ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? <> D [NaN] - the capped equality, mirrored (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ? <> D ORDER BY ID" '["#NaN"]'
eng_only         "2 ? < FL [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? < FL ORDER BY ID" '["#NaN"]'
eng_only         "2 ? < TI.FL [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? < FL ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= FL [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? <= FL ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= TI.FL [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? <= FL ORDER BY ID" '["#NaN"]'
desc_differs     "2 ? > FL [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? > FL ORDER BY ID" '["#NaN"]'
desc_differs     "2 ? > TI.FL [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? > FL ORDER BY ID" '["#NaN"]'
desc_differs     "2 ? >= FL [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? >= FL ORDER BY ID" '["#NaN"]'
desc_differs     "2 ? >= TI.FL [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? >= FL ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? = FL [NaN] - the capped equality, mirrored (engine (none))" "SELECT ID FROM T WHERE ? = FL ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? <> FL [NaN] - the capped equality, mirrored (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ? <> FL ORDER BY ID" '["#NaN"]'
eng_only         "2 ? < ID [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? < ID ORDER BY ID" '["#NaN"]'
eng_only         "2 ? < TI.ID [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? < ID ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= ID [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? <= ID ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= TI.ID [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? <= ID ORDER BY ID" '["#NaN"]'
both             "2 ? > ID [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? > ID ORDER BY ID" '["#NaN"]'
both             "2 ? > TI.ID [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? > ID ORDER BY ID" '["#NaN"]'
both             "2 ? >= ID [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? >= ID ORDER BY ID" '["#NaN"]'
both             "2 ? >= TI.ID [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? >= ID ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? = ID [NaN] - the capped equality, mirrored (engine (none))" "SELECT ID FROM T WHERE ? = ID ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? <> ID [NaN] - the capped equality, mirrored (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ? <> ID ORDER BY ID" '["#NaN"]'
eng_only         "2 ? < NM [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? < NM ORDER BY ID" '["#NaN"]'
eng_only         "2 ? < TI.NM [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? < NM ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= NM [NaN] - the engine SPLITS (heap -3;0;1;2;3;9, indexed (none))" "SELECT ID FROM T WHERE ? <= NM ORDER BY ID" '["#NaN"]'
eng_only         "2 ? <= TI.NM [NaN] - the indexed half (engine (none))" "SELECT ID FROM TI WHERE ? <= NM ORDER BY ID" '["#NaN"]'
both             "2 ? > NM [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? > NM ORDER BY ID" '["#NaN"]'
both             "2 ? > TI.NM [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? > NM ORDER BY ID" '["#NaN"]'
both             "2 ? >= NM [NaN] -> (none) (engine (none))" "SELECT ID FROM T WHERE ? >= NM ORDER BY ID" '["#NaN"]'
both             "2 ? >= TI.NM [NaN] -> (none) (engine (none))" "SELECT ID FROM TI WHERE ? >= NM ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? = NM [NaN] - the capped equality, mirrored (engine (none))" "SELECT ID FROM T WHERE ? = NM ORDER BY ID" '["#NaN"]'
eng_only         "2 CAP ? <> NM [NaN] - the capped equality, mirrored (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ? <> NM ORDER BY ID" '["#NaN"]'

echo "-- 3. A NULL ROW: the verdict must be UNKNOWN there, not the constant --"
# A constant term would take the NULL row with every TRUE verdict.  The
# engine does not, and neither does this server: the verdict is spelled as
# a comparison against -Infinity, which is UNKNOWN on a NULL exactly as
# the engine's is.  A fixture without NULLs cannot tell the two apart -
# these 15 cells are the ones that can.
eng_only         "3 TN.D <> ? [NaN] -> engine 1;3, NOT 1;2;3 (engine 1;3) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TN WHERE D <> ? ORDER BY ID" '["#NaN"]'
eng_only         "3 TNI.D <> ? [NaN] -> engine 1;3 indexed (engine 1;3) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TNI WHERE D <> ? ORDER BY ID" '["#NaN"]'
both             "3 TN.D < ? [NaN] -> 1;3 - a TRUE verdict skips the NULL row (engine 1;3)" "SELECT ID FROM TN WHERE D < ? ORDER BY ID" '["#NaN"]'
both             "3 TNI.D < ? [NaN] -> 1;3 (engine 1;3)" "SELECT ID FROM TNI WHERE D < ? ORDER BY ID" '["#NaN"]'
both             "3 TN.D <= ? [NaN] -> 1;3 (engine 1;3)" "SELECT ID FROM TN WHERE D <= ? ORDER BY ID" '["#NaN"]'
eng_only         "3 TN.D = ? [NaN] -> engine (none) (engine (none)) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TN WHERE D = ? ORDER BY ID" '["#NaN"]'
both             "3 TN.D > ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TN WHERE D > ? ORDER BY ID" '["#NaN"]'
eng_only         "3 TN.N <> ? [NaN] -> engine 1;3 - an exact column with a NULL row (engine 1;3) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TN WHERE N <> ? ORDER BY ID" '["#NaN"]'
eng_only         "3 TNI.N <> ? [NaN] -> engine 1;3 indexed (engine 1;3) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TNI WHERE N <> ? ORDER BY ID" '["#NaN"]'
both             "3 TN.N < ? [NaN] -> (none) (engine (none))" "SELECT ID FROM TN WHERE N < ? ORDER BY ID" '["#NaN"]'
eng_only         "3 TN.NM <> ? [NaN] -> engine 1;3 (engine 1;3) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TN WHERE NM <> ? ORDER BY ID" '["#NaN"]'
eng_only         "3 TN.FL <> ? [NaN] -> engine 1;3 (engine 1;3) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TN WHERE FL <> ? ORDER BY ID" '["#NaN"]'
eng_only         "3 ? <> TN.D [NaN] -> engine 1;3 mirrored (engine 1;3) - CAPPED: an equality is one tree with an IN list"  "SELECT ID FROM TN WHERE ? <> D ORDER BY ID" '["#NaN"]'
both             "3 ? > TN.D [NaN] -> (none) mirrored (engine (none))" "SELECT ID FROM TN WHERE ? > D ORDER BY ID" '["#NaN"]'
eng_only         "3 TN.N > ? [NaN] - the SPLIT still refuses over a NULL row too (engine heap 1;3, indexed (none))" "SELECT ID FROM TN WHERE N > ? ORDER BY ID" '["#NaN"]'
both             "3 CONTROL TN.D IS NULL -> 2 (engine 2)" "SELECT ID FROM TN WHERE D IS NULL ORDER BY ID" '[]'
both             "3 CONTROL TN.D > ? [0] - an ordinary bind over the same rows (engine 1)" "SELECT ID FROM TN WHERE D > ? ORDER BY ID" '[0]'
both             "3 CONTROL TN.N <> ? [1] - an ordinary bind skips the NULL row too (engine 3)" "SELECT ID FROM TN WHERE N <> ? ORDER BY ID" '[1]'

echo "-- 4. CONTROLS: what must not have moved --"
both             "4 CONTROL D > ? [2.4] - an ordinary double bind (engine 2;3;9)" "SELECT ID FROM T WHERE D > ? ORDER BY ID" '[2.4]'
both             "4 CONTROL ID > ? [2] - an integer message (engine 3;9)" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '[2]'
both             "4 CONTROL D > ? [+Inf] - Infinity has an ordinary total order (engine (none))" "SELECT ID FROM T WHERE D > ? ORDER BY ID" '["#Inf"]'
both             "4 CONTROL D < ? [+Inf] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D < ? ORDER BY ID" '["#Inf"]'
both             "4 CONTROL D > ? [-Inf] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D > ? ORDER BY ID" '["#-Inf"]'
both             "4 CONTROL TI.D > ? [-Inf] - indexed, and it does NOT split (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE D > ? ORDER BY ID" '["#-Inf"]'
both             "4 CONTROL ID < ? [+Inf] - an exact column against Infinity (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '["#Inf"]'
both             "4 CONTROL TI.ID > ? [-Inf] - indexed (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '["#-Inf"]'
both             "4 CONTROL a written CAST absorbs the NaN as 0: ID = CAST(? AS INTEGER) [NaN] (engine 0)" "SELECT ID FROM T WHERE ID = CAST(? AS INTEGER) ORDER BY ID" '["#NaN"]'
both             "4 CONTROL TI.ID = CAST(? AS INTEGER) [NaN] - indexed (engine 0)" "SELECT ID FROM TI WHERE ID = CAST(? AS INTEGER) ORDER BY ID" '["#NaN"]'

echo "-- 4b. THE `IN`-LIST BOUNDARY, pinned so it fails loudly --"
# THE ENGINE\'S `IN` IS NOT THE `OR` IT DESUGARS TO, for a NaN, and it is
# not one alternative law but at least two.  Measured 2026-09-20 over
# five literals in both written positions, three-item lists, and with
# `PLAN (M NATURAL)` forced so it is NOT an access-path effect:
#   * a DOUBLE column turns the list into a RANGE whose open end the NaN
#     sets and WHICH END DEPENDS ON WHERE IN THE LIST IT SITS -
#     `D IN (?, 1)` is `D <= 1`, `D IN (1, ?)` is `D >= 1`, and
#     `D NOT IN (?, 1)` is `D > 1` - THREE rows where the OR expansion
#     `D <> ? AND D <> 1` gives five;
#   * a SMALLINT column instead ABSORBS the NaN AS ZERO, so `SM IN (?, 1)`
#     is `SM IN (0, 1)` and takes the SM = 0 row - while INTEGER and
#     BIGINT with the same unscaled literal do NOT, and DO once the
#     literal carries a scale, and NUMERIC(18,1) never does though
#     NUMERIC(9,2) always does.  NEITHER DTYPE NOR SCALE EXPLAINS THE SET.
# So the construct is refused rather than modelled, and these cells go RED
# THE DAY THIS SERVER ANSWERS ONE - which is the only honest way to hold a
# boundary nobody has characterised.
eng_only         "4b BOUNDARY D IN (?, 1) [NaN] - the engine reads a RANGE, not an equality (engine heap -3;0;1, indexed 1)" "SELECT ID FROM T WHERE D IN (?, 1) ORDER BY ID" '["#NaN"]'
eng_only         "4b BOUNDARY D IN (1, ?) [NaN] - the other written position, the other open end (engine 1;2;3;9)" "SELECT ID FROM T WHERE D IN (1, ?) ORDER BY ID" '["#NaN"]'
eng_only         "4b BOUNDARY D NOT IN (?, 1) [NaN] - the engine gives D > 1; the OR expansion would give five rows (engine 2;3;9)" "SELECT ID FROM T WHERE D NOT IN (?, 1) ORDER BY ID" '["#NaN"]'
eng_only         "4b BOUNDARY SM IN (?, 1) [NaN] - a SMALLINT absorbs the NaN as ZERO and takes the SM = 0 row (engine 0;1)" "SELECT ID FROM T WHERE SM IN (?, 1) ORDER BY ID" '["#NaN"]'
eng_only         "4b BOUNDARY NM IN (?, 7.24) [NaN] - NUMERIC(9,2) absorbs it too (engine 0;1)" "SELECT ID FROM T WHERE NM IN (?, 7.24) ORDER BY ID" '["#NaN"]'
eng_only         "4b BOUNDARY ID IN (?, 1) [NaN] - an INTEGER with an UNSCALED literal does NOT absorb, and still refuses: the boundary is uncharacterised, not safe (engine heap 1)" "SELECT ID FROM T WHERE ID IN (?, 1) ORDER BY ID" '["#NaN"]'
eng_only         "4b BOUNDARY ID IN (?, 1.0) [NaN] - ...and the SAME column with a SCALED literal DOES absorb (engine 0;1)" "SELECT ID FROM T WHERE ID IN (?, 1.0) ORDER BY ID" '["#NaN"]'
# ...and the CONTROLS that say the boundary is about the NaN and the list,
# not about `IN`: an ordinary bind and an Infinity go through untouched,
# and a SINGLE-item list is the bare equality, which the cap already holds.
both             "4b CONTROL D IN (?, 99) [2.5] - an ordinary bind through the same list (engine 2)" "SELECT ID FROM T WHERE D IN (?, 99) ORDER BY ID" '[2.5]'
both             "4b CONTROL D IN (?, 1) [+Inf] - an Infinity has an ordinary order and reads as the equality (engine 1)" "SELECT ID FROM T WHERE D IN (?, 1) ORDER BY ID" '["#Inf"]'
both             "4b CONTROL ID IN (?, 3) [2] - an integer message (engine 3)" "SELECT ID FROM T WHERE ID IN (?, 3) ORDER BY ID" '[2]'

echo "-- 5. DML, where a wrong answer MUTATES ROWS --"
# The refuter measured 401 DML cells.  The law predicts every engine
# answer among them, and the two halves show up here as they do nowhere
# else: the shapes the engine answers one way on EVERY path are rows this
# server may now touch, and the shapes whose index range differs are rows
# it must leave alone.  `DELETE FROM MI WHERE BI > ?` [NaN] removes SIX
# rows on a heap and FOUR through the index - which is why that one
# refuses rather than picking a side.
dml_rb           "5 UPDATE U SET N = 77 WHERE D < ? [NaN] - a TRUE verdict on a DOUBLE side, every path agrees (engine dml=(none) rb=1,77;2,77;3,77)" "UPDATE U SET N = 77 WHERE D < ?" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 UPDATE U SET N = 77 WHERE D > ? [NaN] - the FALSE verdict touches nothing (engine dml=(none) rb=1,1;2,2;3,3)" "UPDATE U SET N = 77 WHERE D > ?" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 DELETE FROM U WHERE D > ? [NaN] - FALSE, so no row goes (engine dml=(none) rb=1,1;2,2;3,3)" "DELETE FROM U WHERE D > ?" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 DELETE FROM U WHERE D < ? [NaN] - TRUE on a DOUBLE side: every row goes (engine dml=(none) rb=(none))" "DELETE FROM U WHERE D < ?" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 UPDATE U SET N = 77 WHERE ? > D [NaN] - mirrored, FALSE (engine dml=(none) rb=1,1;2,2;3,3)" "UPDATE U SET N = 77 WHERE ? > D" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 UPDATE U SET N = 77 WHERE NOT (D > ?) [NaN] - NOT of a FALSE verdict takes every row (engine dml=(none) rb=1,77;2,77;3,77)" "UPDATE U SET N = 77 WHERE NOT (D > ?)" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 UPDATE U SET N = 77 WHERE ID < ? [NaN] - an EXACT side, FALSE (engine dml=(none) rb=1,1;2,2;3,3)" "UPDATE U SET N = 77 WHERE ID < ?" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 DELETE FROM U WHERE ID <= ? [NaN] - exact, FALSE (engine dml=(none) rb=1,1;2,2;3,3)" "DELETE FROM U WHERE ID <= ?" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 UPDATE U SET N = 77 WHERE ? >= ID [NaN] - exact, mirrored, FALSE (engine dml=(none) rb=1,1;2,2;3,3)" "UPDATE U SET N = 77 WHERE ? >= ID" '["#NaN"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
# ...and the SPLIT half, where the rows must be left alone
dml_rb_eng_only  "5 DELETE FROM TI WHERE BI > ? [NaN] - the engine removes SIX rows on the heap and FOUR through the index; this server touches none (engine dml=(none) rb=(none) on the heap reading)" "DELETE FROM TI WHERE BI > ?" '["#NaN"]' "SELECT ID AS A FROM TI ORDER BY ID"
dml_rb_eng_only  "5 DELETE FROM TI WHERE ID >= ? [NaN] - the same, an INTEGER key whose range is EMPTY over a NaN" "DELETE FROM TI WHERE ID >= ?" '["#NaN"]' "SELECT ID AS A FROM TI ORDER BY ID"
dml_rb_eng_only  "5 UPDATE TI SET SM = 7 WHERE ? < D [NaN] - the DOUBLE-side twin: the written order flips a DML outcome" "UPDATE TI SET SM = 7 WHERE ? < D" '["#NaN"]' "SELECT ID AS A, SM AS B FROM TI ORDER BY ID"
# CONTROLS: an ordinary bind and an Infinity through the same statements
dml_rb           "5 CONTROL UPDATE U SET N = 77 WHERE D > ? [2] - an ordinary bind (engine dml=(none) rb=1,1;2,2;3,77)" "UPDATE U SET N = 77 WHERE D > ?" '[2]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 CONTROL DELETE FROM U WHERE D > ? [+Inf] - Infinity has an ordinary order (engine dml=(none) rb=1,1;2,2;3,3)" "DELETE FROM U WHERE D > ?" '["#Inf"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb           "5 CONTROL DELETE FROM U WHERE D > ? [-Inf] - every row goes (engine dml=(none) rb=(none))" "DELETE FROM U WHERE D > ?" '["#-Inf"]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"

# the server's stderr log is the ONE place a PANIC shows: a panicked
# connection thread closes its socket (node reads *Connection to Firebird
# server was lost*, which every cell above records as ERR - the same word
# as a refusal) while the PROCESS survives, so an ERR alone cannot tell a
# refusal from a crash
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
if [ "$ran" -lt 174 ]; then
    echo "FAIL only $ran checks ran; 174 were measured - cells went missing"; fail=1
fi
exit $fail
