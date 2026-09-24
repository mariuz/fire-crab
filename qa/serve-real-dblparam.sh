#!/bin/bash
# A DOUBLE MESSAGE BOUND TO AN EXACT SLOT - a JS fraction (a blr_double
# message) bound to an INTEGER / SMALLINT / BIGINT / NUMERIC / INT128
# parameter.  The engine ANNOUNCES the slot exact (`ID > ?` describes
# sqltype 496 LONG, `BI > ?` 580 INT64, `H2 > ?` 32752 INT128) and then
# COMPARES THE DOUBLE, unrounded: `ID = ?` [2.5] takes NONE where a
# rounded bound would take row 2 or 3, `ID > ?` [2.9999999] takes 3;9
# where a rounded bound takes 9 alone, `SM >= ?` [1e-300] skips the
# SM = 0 row, and `ID < ?` [3000000000.5] never raises.  The previous committed
# binary (/tmp/fcwire-prev-c34c1c8) describes every one of these and then
# fails at EXECUTE with a generic *Dynamic SQL Error* - in every
# comparison router, in HAVING, in DML WHERE and in every procedure
# argument - while the CAST and the plain store already answer.
#
# THE LAW THE FIRST DESIGN GOT WRONG, measured here on both tables:
# an index on an INT64 / INT128 / NUMERIC(18,x) / NUMERIC(38,x) column
# ROUNDS the double to the key's scale to build its bound and then
# re-checks each row as a double, so the INDEXED and the SCANNED answers
# DIFFER - `BI > ?` [2.5] is 3;9 on T and 9 on TI, `N18 = ?`
# [900719925474099.25] is 9 on T and none on TI.  SHORT- and LONG-backed
# keys (INTEGER, SMALLINT, NUMERIC(9,2), NUMERIC(4,1)) are DOUBLE keys
# and do not round.  Every section 1 cell is therefore emitted TWICE,
# once per table, and each label carries BOTH measured answers; the wide
# cells whose two answers differ are `eng_only` - this server must refuse
# them rather than pick one of the engine's two answers.
# An index COMPUTED BY (ID + 0) rounds the same way (table TE), which is
# why an INT64-TYPED EXPRESSION side (ID + 0, ID * 1, ABS(ID),
# CAST(ID AS BIGINT), NM + 0) is refused while a LONG-typed one
# (COALESCE(ID, 0), -ID) is answered.
#
# NaN HAS NO SINGLE ENGINE ORDER, so every NaN comparison is refused:
# against a DOUBLE column cmp(D, NaN) = cmp(NaN, D) = -1 (so `D < ?` is
# true and `D > ?` is false in BOTH operand orders) while `D IN (?, 99)`
# takes every row; against an EXACT column NaN sorts BELOW everything on
# a scan - and the INDEXED answer is the opposite (`TI.ID > ?` [NaN] is
# none where `T.ID > ?` is every row).  A cast the engine converts at
# absorbs the NaN by the platform's cast and those cells ARE answered.  On the previous
# binary the DOUBLE-column NaN cells are WRONG ANSWERS, including a
# wrong DELETE: value_cmp's approx arm does partial_cmp().unwrap_or(Equal),
# which makes NaN equal to everything.
#
# THE STORE LAW IS A DIFFERENT LAW from the compare: scale to the target,
# add (0.5 + 1e-14) away from zero, truncate, then range-check - 2.5 -> 3,
# -2.5 -> -3, 7.245 -> 7.25 into NUMERIC(9,2) and 7.2 into NUMERIC(18,1),
# NaN -> the C++ cast of the ENGINE's platform (undefined in C++, so the
# hardware decides): 0 on ARM, where these cells were first measured, and
# on x86-64 the "integer indefinite" - INT32_MIN for an INTEGER-backed
# target, INT64_MIN for a BIGINT one, 22003 for a SMALLINT one.  The cells
# compare against the LIVE engine, so they hold on either; the labels
# carry the ARM numbers.  +-Infinity and an overflow -> 22003.  2147483647.4 fits an
# INTEGER and does NOT fit a NUMERIC(9,2).  A runtime INT128 value below
# 2^53 takes the same eps law (10.075 -> 10.07), where the double LITERAL
# spelling does not.
#
# MEASURED SURPRISES pinned here: UPDATE OR INSERT ... MATCHING compares
# the RAW double against the key and then INSERTS the ROUNDED value, so
# [0.6] and [2.5] raise a PRIMARY KEY violation where a convert-first
# reading would UPDATE row 1 / row 3; and NULLIF compares the raw client
# double before its slot converts it (`NULLIF(?, 3)` [3.4] is 3, not
# NULL) - the previous binary answers NULL and WRITES NULL.
#
# THE ROUTER DOES NOT KNOW ITS KEYS (section 11E, added 2026-09-20 by
# READING the code, not by a gate): `Predicate::keys_known` was written,
# carried through the bind and the invariant strip, documented at length -
# and never READ by any decision.  Its comment claimed the router paths
# refuse; they did not.  A JOIN's combined row, a derived table, a CTE, a
# UNION leg and a view build their filter without reading a catalog, so
# `Predicate::keys` is EMPTY there, and the `(?)` rung read that empty list
# as "no index leads with this column" and answered the SCAN reading where
# the engine gives the INDEX one - SEVEN WRONG ANSWERS, all of them also
# wrong on the previous binary.  The rung now refuses wherever the path is
# UNKNOWN, which is the policy the BARE `?` spelling always had.  The cost
# is four shapes the previous binary answered CORRECTLY (a JOIN, a view, a
# derived table and a CTE over a HEAP relation on a wide column) and they
# are gated here as `11E COST` cells, not quietly dropped.
#
# EVERY `both` CELL COMPARES THE VALUE *AND* THE WHOLE DESCRIBE (every
# input and output slot), and every DML cell runs inside a transaction
# that is ROLLED BACK after a read-back, so a binary that writes the
# wrong row cannot pollute the cells after it.  Binds are chosen so a
# rounded reading is a DIFFERENT row set: the fixture carries rows at
# -3, 0, 1, 2, 3, 9 and the bounds sit on the half (2.5, -2.5, 0.5,
# 2.495, 7.235, 2.9999999, 1e-300).
#
# INSTRUMENT: node-firebird sends a JS fraction as a blr_double message,
# an integer as an integer message, and cannot send an integral double at
# or past 2^31 (it goes as Int64 and hangs); NaN and +-Infinity travel as
# blr_double and are written "#NaN" / "#Inf" / "#-Inf" in the JSON binds.
# It also collapses duplicate column names (every read-back column is
# ALIASED) and misreads an INT128 column (every INT128 read-back is CAST
# to VARCHAR).  A row whose columns are all NULL prints as NULL, never as
# an empty line, so a NULLIF control cannot be mistaken for a lost cell.
#
# Usage: qa/serve-real-dblparam.sh [port]   (default 4385)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4385}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dblparam-eng.fdb"; FC="$D/dblparam-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/dblparam-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NN INTEGER NOT NULL, SM SMALLINT, NM NUMERIC(9,2),
                N18 NUMERIC(18,1), N41 NUMERIC(4,1), BI BIGINT, H INT128,
                H2 NUMERIC(38,2), D DOUBLE PRECISION, FL FLOAT, S VARCHAR(20));
CREATE TABLE TI (ID INTEGER NOT NULL PRIMARY KEY, NN INTEGER NOT NULL, SM SMALLINT, NM NUMERIC(9,2),
                N18 NUMERIC(18,1), N41 NUMERIC(4,1), BI BIGINT, H INT128,
                H2 NUMERIC(38,2), D DOUBLE PRECISION, FL FLOAT, S VARCHAR(20));
CREATE TABLE W (ID INTEGER, N INTEGER, SM SMALLINT, BI BIGINT, NM NUMERIC(9,2),
                N18 NUMERIC(18,1), N41 NUMERIC(4,1), H INT128, H2 NUMERIC(38,2),
                D DOUBLE PRECISION, FL FLOAT);
CREATE TABLE U (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, NM NUMERIC(9,2), BI BIGINT, D DOUBLE PRECISION);
COMMIT;
CREATE INDEX TI_SM ON TI (SM);
CREATE INDEX TI_NM ON TI (NM);
CREATE INDEX TI_N18 ON TI (N18);
CREATE INDEX TI_N41 ON TI (N41);
CREATE INDEX TI_BI ON TI (BI);
CREATE INDEX TI_H ON TI (H);
CREATE INDEX TI_H2 ON TI (H2);
CREATE INDEX TI_D ON TI (D);
CREATE INDEX TI_FL ON TI (FL);
CREATE INDEX TI_NN ON TI (NN);
CREATE INDEX TI_S ON TI (S);
COMMIT;
INSERT INTO T VALUES (-3, 4, -3, -2.50, -2.5, -2.5, -3, -3, -2.50, -2.5, -2.5, '-3');
INSERT INTO T VALUES (0, 1, 0, 0.00, 0.0, 0.0, 0, 0, 0.00, 0, 0, '0');
INSERT INTO T VALUES (1, 1, 1, 7.24, 1.0, 1.0, 1, 1, 1.00, 1, 1, '1');
INSERT INTO T VALUES (2, 2, 2, 2.50, 2.5, 2.5, 2, 2, 2.50, 2.5, 2.675, '2.5');
INSERT INTO T VALUES (3, 3, 3, 2.49, 2.4, 2.4, 3, 3, 2.49, 3, 3, '3');
INSERT INTO T VALUES (9, 9, 9, 1234567.01, 900719925474099.3, 9.0, 9, 9, 9.00, 9, 9, '9');
INSERT INTO TI SELECT * FROM T;
INSERT INTO W VALUES (1, 1, 1, 1, 1.00, 1.0, 1.0, 1, 1.00, 1, 1);
INSERT INTO W VALUES (2, 2, 2, 2, 2.00, 2.0, 2.0, 2, 2.00, 2, 2);
INSERT INTO U VALUES (1, 1, 1.00, 1, 1);
INSERT INTO U VALUES (2, 2, 2.50, 2, 2.5);
INSERT INTO U VALUES (3, 3, 2.49, 3, 3);
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE P1 (A INTEGER, B NUMERIC(9,2)) RETURNS (RA INTEGER, RB NUMERIC(9,2))
AS BEGIN RA = A; RB = B; SUSPEND; END^
CREATE PROCEDURE P2 (A BIGINT, B SMALLINT) RETURNS (RA BIGINT, RB SMALLINT)
AS BEGIN RA = A; RB = B; SUSPEND; END^
SET TERM ; ^
COMMIT;
CREATE TABLE TE (ID INTEGER, NN INTEGER NOT NULL, SM SMALLINT, NM NUMERIC(9,2),
                N18 NUMERIC(18,1), N41 NUMERIC(4,1), BI BIGINT, H INT128,
                H2 NUMERIC(38,2), D DOUBLE PRECISION, FL FLOAT, S VARCHAR(20));
COMMIT;
INSERT INTO TE SELECT * FROM T;
COMMIT;
CREATE INDEX TE_ID0 ON TE COMPUTED BY (ID + 0);
CREATE INDEX TE_BI0 ON TE COMPUTED BY (BI + 0);
CREATE INDEX TE_NM0 ON TE COMPUTED BY (NM + 0);
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE P3 (A INTEGER, B NUMERIC(9,2))
AS BEGIN INSERT INTO W (ID, N, NM) VALUES (8, :A, :B); END^
SET TERM ; ^
COMMIT;
CREATE TABLE CKD (ID INTEGER, N INTEGER CHECK (N <> 3));
CREATE TABLE TRD (ID INTEGER, N INTEGER, C COMPUTED BY (N * 2), SEEN VARCHAR(40));
COMMIT;
INSERT INTO CKD VALUES (1, 1);
COMMIT;
SET TERM ^ ;
CREATE TRIGGER TRD_BI FOR TRD ACTIVE BEFORE INSERT POSITION 0
AS BEGIN NEW.SEEN = 'N=' || CAST(NEW.N AS VARCHAR(20)); END^
SET TERM ; ^
COMMIT;
CREATE TABLE MBH (ID INTEGER, N INTEGER, SM SMALLINT, BI BIGINT, H INT128, NM NUMERIC(9,2));
CREATE TABLE MBI (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, SM SMALLINT, BI BIGINT, H INT128, NM NUMERIC(9,2));
COMMIT;
CREATE INDEX MBI_BI ON MBI (BI);
CREATE INDEX MBI_SM ON MBI (SM);
CREATE INDEX MBI_NM ON MBI (NM);
COMMIT;
INSERT INTO MBH VALUES (1, 100, 1, 1, 1, 1.00);
INSERT INTO MBH VALUES (2, 200, 2, 2, 2, 2.50);
INSERT INTO MBH VALUES (3, 300, 3, 3, 3, 2.49);
INSERT INTO MBI SELECT * FROM MBH;
COMMIT;
CREATE VIEW V1 AS SELECT ID, NN, SM, NM, N18, N41, BI, H, H2, D, FL, S FROM T;
CREATE VIEW VI AS SELECT ID, NN, SM, NM, N18, N41, BI, H, H2, D, FL, S FROM TI;
COMMIT;
SQL
if grep -qi error /tmp/dblparam-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dblparam-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

SRVLOG="/tmp/fc-serve-dblparam-$PORT.log"
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
# JSON carries no NaN and no Infinity: the binds spell them
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
# the DML and its read-back in ONE transaction, ROLLED BACK on both servers
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
# the ERROR VECTOR, not the word ERR: node-firebird hands back the
# gdscode, so a 22003 *numeric value is out of range* (335544321) can be
# told apart from the generic *Dynamic SQL Error* (335544569) that this
# server used to answer with.  Used by the two `both raise` helpers, and
# a rolled-back transaction for the DML one.
gds() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_TX="${5:-}" timeout 25 node -e "$LOST$RV"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird"); const done=e=>{console.log(e?("gds="+(e.gdscode||"?")):"gds=none");};
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    const p=JSON.parse(process.env.FC_P).map(rv);
    if(process.env.FC_TX){
      db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
        if(et){console.log("CONN_ERR");process.exit(1);}
        tr.query(process.env.FC_Q,p,(e2)=>{
          if(e2&&lost(e2)){console.log("CONN_ERR");process.exit(1);}
          done(e2); tr.rollback(()=>{db.detach();process.exit(0);});
        });
      });
    } else {
      db.query(process.env.FC_Q,p,(e2)=>{
        if(e2&&lost(e2)){console.log("CONN_ERR");process.exit(1);}
        done(e2); db.detach(); process.exit(0);
      });
    }
  });' 2>/dev/null; }
rungds() { local n=0 r; while [ $n -lt 8 ]; do r=$(gds "$1" "$2" "$3" "$4" "${5:-}")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
# EVERY slot of the describe, input and output, on one line
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }

# value AND describe must both match
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
# the engine ANSWERS and this server refuses - a recorded design boundary
# (a wide key the engine would round, a NaN whose order is path-dependent)
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
# both servers PREPARE (describe lines on both, and equal) and both RAISE
# at execute - the engine's 22003 *numeric value is out of range*
both_err() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 - the ENGINE did not prepare it; that is a both_refuse cell"; fail=1
    elif [ "$ev" != ERR ]; then echo "FAIL $1 - the ENGINE answered [$ev]"; fail=1
    elif [ -z "$fd" ]; then
        echo "FAIL $1 - THIS server refused at PREPARE where the engine prepares and raises at execute"; fail=1
    elif [ "$fv" != ERR ]; then
        echo "FAIL $1 - THIS server ANSWERED [$fv] where the engine raises at execute"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - both raise, the announcement differs)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else
        local eg fg
        eg=$(rungds "$REAL" "$ENG" "$2" "$js"); fg=$(rungds "$PORT" "$FC" "$2" "$js")
        if [ "$eg" != "$fg" ]; then
            echo "FAIL $1 (the error VECTOR differs - both raise, the gdscode does not match)"
            echo "     eng=[$eg] fc=[$fg]"; fail=1
        else echo "OK   $1 (both prepare, both raise at execute; $eg)"; fi
    fi
}
# the VALUE is right and the ANNOUNCEMENT is not - recorded, and it says
# so when that stops being true
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
# a DML + read-back in a rolled-back transaction: the RETURNING rows, the
# read-back and the describe must all agree
dml_rb() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE refused the DML [$ev]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value - RETURNING rows or the read-back)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE of the DML)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev] (rolled back)"; fi
}
# a DML whose VALUE and read-back agree while the ANNOUNCEMENT does not -
# recorded, and it says so when that stops being true.  This server
# announces every INPUT slot Nullable by deliberate policy (libfbclient
# renders the raw buffer instead of `<null>` for a NOT NULL
# announcement), so a slot the engine describes NOT NULL differs here in
# that one word and in nothing else.
dml_rb_desc_differs() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE refused the DML [$ev]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 - the VALUE diverged, which this cell does not cover"
        echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" = "$fd" ]; then
        echo "FAIL $1 - THE DESCRIBE GAP IS CLOSED; promote this cell to \`dml_rb\`"; fail=1
    else echo "OK   $1 [$ev] (rolled back; recorded describe gap)"; fi
}
# both servers RAISE the DML at execute inside the rolled-back
# transaction and the read-backs agree - the rows are untouched on both
dml_rb_both_err() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="$4" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not raise [$ev]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ -z "$fd" ]; then
        echo "FAIL $1 - THIS server refused at PREPARE where the engine prepares and raises at execute"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then echo "FAIL $1 - THIS server did not raise [$fv]"; fail=1
    elif [ "${ev#*rb=}" != "${fv#*rb=}" ]; then
        echo "FAIL $1 (the read-back after the raise differs)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else
        local eg fg
        eg=$(rungds "$REAL" "$ENG" "$2" "$js" tx); fg=$(rungds "$PORT" "$FC" "$2" "$js" tx)
        if [ "$eg" != "$fg" ]; then
            echo "FAIL $1 (the error VECTOR differs - both raise, the gdscode does not match)"
            echo "     eng=[$eg] fc=[$fg]"; fail=1
        else echo "OK   $1 [$ev] (both raise; rolled back; $eg)"; fi
    fi
}
# the engine WRITES and this server refuses - a recorded boundary whose
# rows must stay untouched here (a NaN WHERE, a wide-key WHERE)
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


# A RECORDED DIVERGENCE, pinned on BOTH sides: the engine's answer and
# this server's, each stated.  It fails when they start AGREEING (promote
# it), when either side moves, and when either side refuses - a wrong
# answer cannot be a green cell, and a cell that cannot say WHICH wrong
# answer is not a record of anything.
divergence() { # <label> <sql> <json> <engine-answer> <this-server-answer>
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] || [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: a side refused] eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ev" = "$fv" ]; then
        echo "FAIL $1 - THE TWO NOW AGREE [$ev]; promote this cell to \`both\`"; fail=1
    elif [ "$ev" != "$4" ] || [ "$fv" != "$5" ]; then
        echo "FAIL $1 - a recorded answer MOVED"
        echo "     engine: want [$4] got [$ev]"; echo "     fcwire: want [$5] got [$fv]"; fail=1
    else echo "OK   recorded divergence: $1 (engine [$ev], this server [$fv])"; fi
}
# the DML twin: both sides perform the statement inside a rolled-back
# transaction and the two READ-BACKS are each pinned
dml_divergence() { # <label> <sql> <json> <read-back> <engine-rb> <this-server-rb>
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$4"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$4")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = "$fv" ]; then
        echo "FAIL $1 - THE TWO NOW AGREE [$ev]; promote this cell to \`dml_rb\`"; fail=1
    elif [ "$ev" != "$5" ] || [ "$fv" != "$6" ]; then
        echo "FAIL $1 - a recorded answer MOVED"
        echo "     engine: want [$5] got [$ev]"; echo "     fcwire: want [$6] got [$fv]"; fail=1
    else echo "OK   recorded divergence: $1 (engine [$ev], this server [$fv])"; fi
}

echo "-- 1. COMPARE AS A DOUBLE on the UNINDEXED table T --"
both             "ID = ? [2.5] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '[2.5]'
both             "ID <> ? [2.5] (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID <> ? ORDER BY ID" '[2.5]'
both             "ID < ? [2.5] (engine T -3;0;1;2 | TI -3;0;1;2)" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '[2.5]'
both             "ID <= ? [2.5] (engine T -3;0;1;2 | TI -3;0;1;2)" "SELECT ID FROM T WHERE ID <= ? ORDER BY ID" '[2.5]'
both             "ID > ? [2.5] (engine T 3;9 | TI 3;9)" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '[2.5]'
both             "ID >= ? [2.5] (engine T 3;9 | TI 3;9)" "SELECT ID FROM T WHERE ID >= ? ORDER BY ID" '[2.5]'
both             "? < ID [2.5] - the reversed operand order (engine T 3;9 | TI 3;9)" "SELECT ID FROM T WHERE ? < ID ORDER BY ID" '[2.5]'
both             "? >= ID [2.5] - reversed (engine T -3;0;1;2 | TI -3;0;1;2)" "SELECT ID FROM T WHERE ? >= ID ORDER BY ID" '[2.5]'
both             "ID BETWEEN ? AND ? [1.5, 2.5] (engine T 2 | TI 2)" "SELECT ID FROM T WHERE ID BETWEEN ? AND ? ORDER BY ID" '[1.5, 2.5]'
both             "ID IN (?, 9) [2.5] (engine T 9 | TI 9)" "SELECT ID FROM T WHERE ID IN (?, 9) ORDER BY ID" '[2.5]'
both             "ID NOT IN (?, 9) [2.5] (engine T -3;0;1;2;3 | TI -3;0;1;2;3)" "SELECT ID FROM T WHERE ID NOT IN (?, 9) ORDER BY ID" '[2.5]'
both             "ID IS DISTINCT FROM ? [2.5] (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID IS DISTINCT FROM ? ORDER BY ID" '[2.5]'
both             "NOT (ID < ?) [2.5] (engine T 3;9 | TI 3;9)" "SELECT ID FROM T WHERE NOT (ID < ?) ORDER BY ID" '[2.5]'
both             "ID > ? [2.9999999] - a bound rounded to 3 answers 9 alone (engine T 3;9 | TI 3;9)" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '[2.9999999]'
both             "ID = ? [2.9999999] - a rounded bound takes row 3 (engine T (none) | TI (none))" "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '[2.9999999]'
both             "ID >= ? [-2.5] - a rounded bound takes the -3 row (engine T 0;1;2;3;9 | TI 0;1;2;3;9)" "SELECT ID FROM T WHERE ID >= ? ORDER BY ID" '[-2.5]'
both             "ID = ? [-2.5] - a rounded bound takes the -3 row (engine T (none) | TI (none))" "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '[-2.5]'
both             "ID < ? [1e-300] - no underflow (engine T -3;0 | TI -3;0)" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '[1e-300]'
both             "ID < ? [3000000000.5] - out of range NEVER raises in a compare (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '[3000000000.5]'
both             "ID > ? [3000000000.5] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '[3000000000.5]'
both             "ID < ? [2147483647.4] (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '[2147483647.4]'
both             "ID < ? [2147483647.6] - the STORE law raises 22003 on this value (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '[2147483647.6]'
both             "ID < ? [+Inf] (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID < ? ORDER BY ID" '["#Inf"]'
both             "ID > ? [+Inf] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '["#Inf"]'
both             "ID > ? [-Inf] (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '["#-Inf"]'
both             "SM >= ? [2.4] - a rounded bound takes row 2 as well (engine T 3;9 | TI 3;9)" "SELECT ID FROM T WHERE SM >= ? ORDER BY ID" '[2.4]'
eng_only         "SM = ? [0.5] - a SHORT-backed EQUALITY refuses: an IN list at this width CONVERTS the bound double and a written equality does not, and both are one tree (section 11D; engine T (none) | TI (none))" "SELECT ID FROM T WHERE SM = ? ORDER BY ID" '[0.5]'
both             "SM >= ? [1e-300] - a rounded bound takes the SM = 0 row (engine T 1;2;3;9 | TI 1;2;3;9)" "SELECT ID FROM T WHERE SM >= ? ORDER BY ID" '[1e-300]'
both             "SM > ? [-2.5] (engine T 0;1;2;3;9 | TI 0;1;2;3;9)" "SELECT ID FROM T WHERE SM > ? ORDER BY ID" '[-2.5]'
both             "NM > ? [7.235] - rounding to the NUMERIC(9,2) scale answers 9 alone (engine T 1;9 | TI 1;9)" "SELECT ID FROM T WHERE NM > ? ORDER BY ID" '[7.235]'
both             "NM = ? [2.495] - a scale-2 rounded bound takes row 2 (engine T (none) | TI (none))" "SELECT ID FROM T WHERE NM = ? ORDER BY ID" '[2.495]'
both             "? = NM [2.495] - reversed (engine T (none) | TI (none))" "SELECT ID FROM T WHERE ? = NM ORDER BY ID" '[2.495]'
both             "NM > ? [7.245] (engine T 9 | TI 9)" "SELECT ID FROM T WHERE NM > ? ORDER BY ID" '[7.245]'
both             "NM BETWEEN ? AND ? [2.495, 7.235] (engine T 2 | TI 2)" "SELECT ID FROM T WHERE NM BETWEEN ? AND ? ORDER BY ID" '[2.495, 7.235]'
both             "NM IN (?, 9) [2.495] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE NM IN (?, 9) ORDER BY ID" '[2.495]'
both             "N41 > ? [2.45] - NUMERIC(4,1) is a SHORT key (engine T 2;9 | TI 2;9)" "SELECT ID FROM T WHERE N41 > ? ORDER BY ID" '[2.45]'
eng_only         "N41 = ? [2.45] - the SHORT-backed equality (section 11D; engine T (none) | TI (none))" "SELECT ID FROM T WHERE N41 = ? ORDER BY ID" '[2.45]'
both             "NN > ? [2.5] - the NOT NULL column (engine T -3;3;9 | TI -3;3;9)" "SELECT ID FROM T WHERE NN > ? ORDER BY ID" '[2.5]'
both             "NN = ? [3.5] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE NN = ? ORDER BY ID" '[3.5]'
both             "N18 = ? [2.5] - a value the INT64 key holds exactly (engine T 2 | TI 2)" "SELECT ID FROM T WHERE N18 = ? ORDER BY ID" '[2.5]'
both             "N18 <= ? [2.4] - exact at scale 1 (engine T -3;0;1;3 | TI -3;0;1;3)" "SELECT ID FROM T WHERE N18 <= ? ORDER BY ID" '[2.4]'
both             "H2 > ? [2.49] - INT128 at scale 2, exact (engine T 2;9 | TI 2;9)" "SELECT ID FROM T WHERE H2 > ? ORDER BY ID" '[2.49]'
both             "H2 >= ? [2.49] (engine T 2;3;9 | TI 2;3;9)" "SELECT ID FROM T WHERE H2 >= ? ORDER BY ID" '[2.49]'
both             "H2 = ? [2.5] (engine T 2 | TI 2)" "SELECT ID FROM T WHERE H2 = ? ORDER BY ID" '[2.5]'
both             "BI < ? [+Inf] - an infinite bound is exact for a wide key (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE BI < ? ORDER BY ID" '["#Inf"]'
both             "BI > ? [+Inf] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE BI > ? ORDER BY ID" '["#Inf"]'
both             "N18 >= ? [-Inf] (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE N18 >= ? ORDER BY ID" '["#-Inf"]'
both             "H2 < ? [+Inf] (engine T -3;0;1;2;3;9 | TI -3;0;1;2;3;9)" "SELECT ID FROM T WHERE H2 < ? ORDER BY ID" '["#Inf"]'
eng_only         "BI > ? [2.5] - INT64: the index ROUNDS the bound (engine T 3;9 | TI 9)" "SELECT ID FROM T WHERE BI > ? ORDER BY ID" '[2.5]'
eng_only         "BI >= ? [-2.5] (engine T 0;1;2;3;9 | TI 0;1;2;3;9)" "SELECT ID FROM T WHERE BI >= ? ORDER BY ID" '[-2.5]'
eng_only         "BI = ? [2.5] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE BI = ? ORDER BY ID" '[2.5]'
eng_only         "BI IN (?, 99) [2.5] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE BI IN (?, 99) ORDER BY ID" '[2.5]'
eng_only         "BI > ? OR ID = 99 [2.5] (engine T 3;9 | TI 9)" "SELECT ID FROM T WHERE BI > ? OR ID = 99 ORDER BY ID" '[2.5]'
eng_only         "BI BETWEEN ? AND ? [1.5, 2.5] (engine T 2 | TI 2)" "SELECT ID FROM T WHERE BI BETWEEN ? AND ? ORDER BY ID" '[1.5, 2.5]'
eng_only         "N18 > ? [2.45] (engine T 2;9 | TI 9)" "SELECT ID FROM T WHERE N18 > ? ORDER BY ID" '[2.45]'
eng_only         "N18 = ? [900719925474099.25] - a double compare matches the stored .3 (engine T 9 | TI (none))" "SELECT ID FROM T WHERE N18 = ? ORDER BY ID" '[900719925474099.2]'
eng_only         "H > ? [2.5] - INT128 (engine T 3;9 | TI 9)" "SELECT ID FROM T WHERE H > ? ORDER BY ID" '[2.5]'
eng_only         "H = ? [2.5] (engine T (none) | TI (none))" "SELECT ID FROM T WHERE H = ? ORDER BY ID" '[2.5]'
eng_only         "H2 > ? [2.495] (engine T 2;9 | TI 9)" "SELECT ID FROM T WHERE H2 > ? ORDER BY ID" '[2.495]'
eng_only         "? < BI [2.5] - reversed (engine T 3;9 | TI 9)" "SELECT ID FROM T WHERE ? < BI ORDER BY ID" '[2.5]'

echo "-- 2. the SAME statements on the INDEXED table TI (each label carries T | TI) --"
both             "ID = ? [2.5] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE ID = ? ORDER BY ID" '[2.5]'
both             "ID <> ? [2.5] (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID <> ? ORDER BY ID" '[2.5]'
both             "ID < ? [2.5] (engine TI -3;0;1;2 | T -3;0;1;2)" "SELECT ID FROM TI WHERE ID < ? ORDER BY ID" '[2.5]'
both             "ID <= ? [2.5] (engine TI -3;0;1;2 | T -3;0;1;2)" "SELECT ID FROM TI WHERE ID <= ? ORDER BY ID" '[2.5]'
both             "ID > ? [2.5] (engine TI 3;9 | T 3;9)" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '[2.5]'
both             "ID >= ? [2.5] (engine TI 3;9 | T 3;9)" "SELECT ID FROM TI WHERE ID >= ? ORDER BY ID" '[2.5]'
both             "? < ID [2.5] - the reversed operand order (engine TI 3;9 | T 3;9)" "SELECT ID FROM TI WHERE ? < ID ORDER BY ID" '[2.5]'
both             "? >= ID [2.5] - reversed (engine TI -3;0;1;2 | T -3;0;1;2)" "SELECT ID FROM TI WHERE ? >= ID ORDER BY ID" '[2.5]'
both             "ID BETWEEN ? AND ? [1.5, 2.5] (engine TI 2 | T 2)" "SELECT ID FROM TI WHERE ID BETWEEN ? AND ? ORDER BY ID" '[1.5, 2.5]'
both             "ID IN (?, 9) [2.5] (engine TI 9 | T 9)" "SELECT ID FROM TI WHERE ID IN (?, 9) ORDER BY ID" '[2.5]'
both             "ID NOT IN (?, 9) [2.5] (engine TI -3;0;1;2;3 | T -3;0;1;2;3)" "SELECT ID FROM TI WHERE ID NOT IN (?, 9) ORDER BY ID" '[2.5]'
both             "ID IS DISTINCT FROM ? [2.5] (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID IS DISTINCT FROM ? ORDER BY ID" '[2.5]'
both             "NOT (ID < ?) [2.5] (engine TI 3;9 | T 3;9)" "SELECT ID FROM TI WHERE NOT (ID < ?) ORDER BY ID" '[2.5]'
both             "ID > ? [2.9999999] - a bound rounded to 3 answers 9 alone (engine TI 3;9 | T 3;9)" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '[2.9999999]'
both             "ID = ? [2.9999999] - a rounded bound takes row 3 (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE ID = ? ORDER BY ID" '[2.9999999]'
both             "ID >= ? [-2.5] - a rounded bound takes the -3 row (engine TI 0;1;2;3;9 | T 0;1;2;3;9)" "SELECT ID FROM TI WHERE ID >= ? ORDER BY ID" '[-2.5]'
both             "ID = ? [-2.5] - a rounded bound takes the -3 row (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE ID = ? ORDER BY ID" '[-2.5]'
both             "ID < ? [1e-300] - no underflow (engine TI -3;0 | T -3;0)" "SELECT ID FROM TI WHERE ID < ? ORDER BY ID" '[1e-300]'
both             "ID < ? [3000000000.5] - out of range NEVER raises in a compare (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID < ? ORDER BY ID" '[3000000000.5]'
both             "ID > ? [3000000000.5] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '[3000000000.5]'
both             "ID < ? [2147483647.4] (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID < ? ORDER BY ID" '[2147483647.4]'
both             "ID < ? [2147483647.6] - the STORE law raises 22003 on this value (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID < ? ORDER BY ID" '[2147483647.6]'
both             "ID < ? [+Inf] (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID < ? ORDER BY ID" '["#Inf"]'
both             "ID > ? [+Inf] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '["#Inf"]'
both             "ID > ? [-Inf] (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '["#-Inf"]'
both             "SM >= ? [2.4] - a rounded bound takes row 2 as well (engine TI 3;9 | T 3;9)" "SELECT ID FROM TI WHERE SM >= ? ORDER BY ID" '[2.4]'
eng_only         "SM = ? [0.5] - the SHORT-backed equality, indexed (section 11D; engine TI (none) | T (none))" "SELECT ID FROM TI WHERE SM = ? ORDER BY ID" '[0.5]'
both             "SM >= ? [1e-300] - a rounded bound takes the SM = 0 row (engine TI 1;2;3;9 | T 1;2;3;9)" "SELECT ID FROM TI WHERE SM >= ? ORDER BY ID" '[1e-300]'
both             "SM > ? [-2.5] (engine TI 0;1;2;3;9 | T 0;1;2;3;9)" "SELECT ID FROM TI WHERE SM > ? ORDER BY ID" '[-2.5]'
both             "NM > ? [7.235] - rounding to the NUMERIC(9,2) scale answers 9 alone (engine TI 1;9 | T 1;9)" "SELECT ID FROM TI WHERE NM > ? ORDER BY ID" '[7.235]'
both             "NM = ? [2.495] - a scale-2 rounded bound takes row 2 (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE NM = ? ORDER BY ID" '[2.495]'
both             "? = NM [2.495] - reversed (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE ? = NM ORDER BY ID" '[2.495]'
both             "NM > ? [7.245] (engine TI 9 | T 9)" "SELECT ID FROM TI WHERE NM > ? ORDER BY ID" '[7.245]'
both             "NM BETWEEN ? AND ? [2.495, 7.235] (engine TI 2 | T 2)" "SELECT ID FROM TI WHERE NM BETWEEN ? AND ? ORDER BY ID" '[2.495, 7.235]'
both             "NM IN (?, 9) [2.495] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE NM IN (?, 9) ORDER BY ID" '[2.495]'
both             "N41 > ? [2.45] - NUMERIC(4,1) is a SHORT key (engine TI 2;9 | T 2;9)" "SELECT ID FROM TI WHERE N41 > ? ORDER BY ID" '[2.45]'
eng_only         "N41 = ? [2.45] - the SHORT-backed equality, indexed (section 11D; engine TI (none) | T (none))" "SELECT ID FROM TI WHERE N41 = ? ORDER BY ID" '[2.45]'
both             "NN > ? [2.5] - the NOT NULL column (engine TI -3;3;9 | T -3;3;9)" "SELECT ID FROM TI WHERE NN > ? ORDER BY ID" '[2.5]'
both             "NN = ? [3.5] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE NN = ? ORDER BY ID" '[3.5]'
both             "N18 = ? [2.5] - a value the INT64 key holds exactly (engine TI 2 | T 2)" "SELECT ID FROM TI WHERE N18 = ? ORDER BY ID" '[2.5]'
both             "N18 <= ? [2.4] - exact at scale 1 (engine TI -3;0;1;3 | T -3;0;1;3)" "SELECT ID FROM TI WHERE N18 <= ? ORDER BY ID" '[2.4]'
both             "H2 > ? [2.49] - INT128 at scale 2, exact (engine TI 2;9 | T 2;9)" "SELECT ID FROM TI WHERE H2 > ? ORDER BY ID" '[2.49]'
both             "H2 >= ? [2.49] (engine TI 2;3;9 | T 2;3;9)" "SELECT ID FROM TI WHERE H2 >= ? ORDER BY ID" '[2.49]'
both             "H2 = ? [2.5] (engine TI 2 | T 2)" "SELECT ID FROM TI WHERE H2 = ? ORDER BY ID" '[2.5]'
both             "BI < ? [+Inf] - an infinite bound is exact for a wide key (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE BI < ? ORDER BY ID" '["#Inf"]'
both             "BI > ? [+Inf] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE BI > ? ORDER BY ID" '["#Inf"]'
both             "N18 >= ? [-Inf] (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE N18 >= ? ORDER BY ID" '["#-Inf"]'
both             "H2 < ? [+Inf] (engine TI -3;0;1;2;3;9 | T -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE H2 < ? ORDER BY ID" '["#Inf"]'
eng_only         "BI > ? [2.5] - INT64: the index ROUNDS the bound (engine TI 9 | T 3;9)" "SELECT ID FROM TI WHERE BI > ? ORDER BY ID" '[2.5]'
eng_only         "BI >= ? [-2.5] (engine TI 0;1;2;3;9 | T 0;1;2;3;9)" "SELECT ID FROM TI WHERE BI >= ? ORDER BY ID" '[-2.5]'
eng_only         "BI = ? [2.5] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE BI = ? ORDER BY ID" '[2.5]'
eng_only         "BI IN (?, 99) [2.5] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE BI IN (?, 99) ORDER BY ID" '[2.5]'
eng_only         "BI > ? OR ID = 99 [2.5] (engine TI 9 | T 3;9)" "SELECT ID FROM TI WHERE BI > ? OR ID = 99 ORDER BY ID" '[2.5]'
eng_only         "BI BETWEEN ? AND ? [1.5, 2.5] (engine TI 2 | T 2)" "SELECT ID FROM TI WHERE BI BETWEEN ? AND ? ORDER BY ID" '[1.5, 2.5]'
eng_only         "N18 > ? [2.45] (engine TI 9 | T 2;9)" "SELECT ID FROM TI WHERE N18 > ? ORDER BY ID" '[2.45]'
eng_only         "N18 = ? [900719925474099.25] - a double compare matches the stored .3 (engine TI (none) | T 9)" "SELECT ID FROM TI WHERE N18 = ? ORDER BY ID" '[900719925474099.2]'
eng_only         "H > ? [2.5] - INT128 (engine TI 9 | T 3;9)" "SELECT ID FROM TI WHERE H > ? ORDER BY ID" '[2.5]'
eng_only         "H = ? [2.5] (engine TI (none) | T (none))" "SELECT ID FROM TI WHERE H = ? ORDER BY ID" '[2.5]'
eng_only         "H2 > ? [2.495] (engine TI 9 | T 2;9)" "SELECT ID FROM TI WHERE H2 > ? ORDER BY ID" '[2.495]'
eng_only         "? < BI [2.5] - reversed (engine TI 9 | T 3;9)" "SELECT ID FROM TI WHERE ? < BI ORDER BY ID" '[2.5]'

echo "-- 3. an EXPRESSION side (an INT64-typed one may carry an expression index) --"
eng_only         "ID + 0 > ? [2.5] - an INT64 expression: an expression index rounds it (engine 3;9)" "SELECT ID FROM T WHERE ID + 0 > ? ORDER BY ID" '[2.5]'
eng_only         "ID + 0 = ? [2.5] (engine (none))" "SELECT ID FROM T WHERE ID + 0 = ? ORDER BY ID" '[2.5]'
eng_only         "NM + 0 = ? [2.495] - INT64 scale -2 (engine (none))" "SELECT ID FROM T WHERE NM + 0 = ? ORDER BY ID" '[2.495]'
eng_only         "NM + 0 > ? [7.235] (engine 1;9)" "SELECT ID FROM T WHERE NM + 0 > ? ORDER BY ID" '[7.235]'
eng_only         "ID * 1 > ? [2.5] (engine 3;9)" "SELECT ID FROM T WHERE ID * 1 > ? ORDER BY ID" '[2.5]'
eng_only         "ABS(ID) > ? [2.5] - INT64 (engine -3;3;9)" "SELECT ID FROM T WHERE ABS(ID) > ? ORDER BY ID" '[2.5]'
eng_only         "CAST(ID AS BIGINT) > ? [2.5] (engine 3;9)" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) > ? ORDER BY ID" '[2.5]'
eng_only         "ID + 0 > ? [2.5] on the INDEXED table (engine 3;9)" "SELECT ID FROM TI WHERE ID + 0 > ? ORDER BY ID" '[2.5]'
eng_only         "TE: an index COMPUTED BY (ID + 0) ROUNDS the bound [2.5] (engine 9)" "SELECT ID FROM TE WHERE ID + 0 > ? ORDER BY ID" '[2.5]'
eng_only         "TE: an index COMPUTED BY (BI + 0) [2.5] (engine 9)" "SELECT ID FROM TE WHERE BI + 0 > ? ORDER BY ID" '[2.5]'
eng_only         "TE: an index COMPUTED BY (NM + 0) [7.235] (engine 9)" "SELECT ID FROM TE WHERE NM + 0 > ? ORDER BY ID" '[7.235]'
both             "COALESCE(ID, 0) > ? [2.5] - a LONG expression (engine 3;9)" "SELECT ID FROM T WHERE COALESCE(ID, 0) > ? ORDER BY ID" '[2.5]'
both             "COALESCE(ID, 0) = ? [2.5] (engine (none))" "SELECT ID FROM T WHERE COALESCE(ID, 0) = ? ORDER BY ID" '[2.5]'
both             "COALESCE(ID, 0) > ? [2.5] on the INDEXED table (engine 3;9)" "SELECT ID FROM TI WHERE COALESCE(ID, 0) > ? ORDER BY ID" '[2.5]'
both             "-ID > ? [-2.5] - a LONG expression (engine -3;0;1;2)" "SELECT ID FROM T WHERE -ID > ? ORDER BY ID" '[-2.5]'
both             "CAST(ID AS SMALLINT) > ? [2.5] (engine 3;9)" "SELECT ID FROM T WHERE CAST(ID AS SMALLINT) > ? ORDER BY ID" '[2.5]'

echo "-- 4. HAVING and a GROUP BY key --"
both             "HAVING SUM(ID) > ? [11.5] - an aggregate is never keyed (engine 12)" "SELECT SUM(ID) X FROM T HAVING SUM(ID) > ?" '[11.5]'
both             "HAVING SUM(ID) > ? [12.5] (engine (none))" "SELECT SUM(ID) X FROM T HAVING SUM(ID) > ?" '[12.5]'
both             "HAVING COUNT(*) > 0.5 - a double LITERAL, no parameter (engine 6)" "SELECT COUNT(*) X FROM T HAVING COUNT(*) > 0.5" '[]'
both             "HAVING COUNT(*) > ? [5.5] (engine 6)" "SELECT COUNT(*) X FROM T HAVING COUNT(*) > ?" '[5.5]'
both             "HAVING MAX(ID) > ? [8.5] (engine 9)" "SELECT MAX(ID) X FROM T HAVING MAX(ID) > ?" '[8.5]'
both             "HAVING MAX(ID) > ? [9.5] (engine (none))" "SELECT MAX(ID) X FROM T HAVING MAX(ID) > ?" '[9.5]'
both             "HAVING SUM(BI) > ? [11.5] - a WIDE aggregate is still never keyed (engine 12)" "SELECT SUM(BI) X FROM T HAVING SUM(BI) > ?" '[11.5]'
both             "HAVING SUM(ID) > ? [3000000000.5] - no raise (engine (none))" "SELECT SUM(ID) X FROM T HAVING SUM(ID) > ?" '[3000000000.5]'
both             "a grouped NARROW key: GROUP BY ID HAVING ID > ? [2.5] (engine 3;9)" "SELECT ID FROM T GROUP BY ID HAVING ID > ? ORDER BY ID" '[2.5]'
both             "a grouped narrow key on the INDEXED table (engine 3;9)" "SELECT ID FROM TI GROUP BY ID HAVING ID > ? ORDER BY ID" '[2.5]'
eng_only         "a grouped WIDE key: GROUP BY BI HAVING BI > ? [2.5] (engine 3;9)" "SELECT BI FROM T GROUP BY BI HAVING BI > ? ORDER BY BI" '[2.5]'

echo "-- 5. the routers: JOIN, derived, CTE, UNION, EXISTS, IN --"
both             "JOIN WHERE: A.ID > ? [2.5] (engine 3)" "SELECT A.ID FROM T A JOIN U B ON A.ID = B.ID WHERE A.ID > ? ORDER BY A.ID" '[2.5]'
both             "JOIN ON: ... AND A.ID > ? [1.5] (engine 2;3)" "SELECT A.ID FROM T A JOIN U B ON A.ID = B.ID AND A.ID > ? ORDER BY A.ID" '[1.5]'
both             "JOIN ON over the INDEXED table: AND A.ID > ? [1.5] (engine 2;3)" "SELECT A.ID FROM TI A JOIN U B ON A.ID = B.ID AND A.ID > ? ORDER BY A.ID" '[1.5]'
eng_only         "JOIN WHERE on a WIDE column: A.BI > ? [2.5] (engine 3)" "SELECT A.ID FROM T A JOIN U B ON A.ID = B.ID WHERE A.BI > ? ORDER BY A.ID" '[2.5]'
both             "a derived table: X.ID > ? [2.5] (engine 3;9)" "SELECT X.ID FROM (SELECT ID FROM T) X WHERE X.ID > ? ORDER BY X.ID" '[2.5]'
# the VALUE is this chunk's and now agrees; the ANNOUNCEMENT is a
# pre-existing prepare-time gap outside it, RE-MEASURED 2026-09-20 on all
# three: the INPUT slot of a `?` compared with a NOT NULL column read
# THROUGH A DERIVED TABLE is announced `496 LONG Nullable` here and `496
# LONG` by the engine, on the previous binary (/tmp/fcwire-prev-0e5a8f4)
# exactly as on this one - the literal twin `X.ID > 2` and the undecorated
# `TI.ID > ?` (section 2) both agree, so it is the derived wrap that drops
# the flag, not this chunk.  Recorded rather than typed shut; the helper
# FAILS the day the gap closes.
desc_differs     "a derived table over the INDEXED table - the value agrees, the '?' slot is announced Nullable where the engine says NOT NULL (engine 3;9)" "SELECT X.ID FROM (SELECT ID FROM TI) X WHERE X.ID > ? ORDER BY X.ID" '[2.5]'
eng_only         "a derived table on a WIDE column: X.BI > ? [2.5] (engine 9)" "SELECT X.ID FROM (SELECT ID, BI FROM TI) X WHERE X.BI > ? ORDER BY X.ID" '[2.5]'
both             "a CTE: WITH Q AS (...) WHERE Q.ID > ? [2.5] (engine 3;9)" "WITH Q AS (SELECT ID FROM T) SELECT Q.ID FROM Q WHERE Q.ID > ? ORDER BY Q.ID" '[2.5]'
both             "a UNION branch: the second branch carries the ? (engine -3;3;9)" "SELECT ID FROM T WHERE ID < -2 UNION ALL SELECT ID FROM T WHERE ID > ?" '[2.5]'
both             "an EXISTS body: B.ID > ? [2.4] (engine 3)" "SELECT ID FROM T A WHERE EXISTS (SELECT 1 FROM U B WHERE B.ID = A.ID AND B.ID > ?) ORDER BY ID" '[2.4]'
both             "an IN subquery body: B.ID > ? [1.5] (engine 2;3)" "SELECT ID FROM T WHERE ID IN (SELECT B.ID FROM U B WHERE B.ID > ?) ORDER BY ID" '[1.5]'
# NOT A DOUBLE-BIND CELL AT ALL, re-measured 2026-09-20: a `?` inside a
# SCALAR SUBQUERY IN THE SELECT LIST is refused at PREPARE (SQLSTATE
# 42000, no describe at all) for EVERY bind type - the same statement
# bound the INTEGER 2, and the `B.ID > ?` twin bound 2, refuse identically
# on this binary and on /tmp/fcwire-prev-0e5a8f4.  That select-list
# CorrSub sink is a different router from the WHERE one this chunk fixes
# (the `EXISTS` and `IN` bodies two cells above ARE bound and answer), so
# the boundary is recorded here rather than moved.
eng_only         "a correlated scalar subquery in the SELECT LIST - refused at prepare for every bind type, integer included (engine -3,0;0,0;1,0;2,1;3,1;9,0)" "SELECT ID, (SELECT COUNT(*) FROM U B WHERE B.ID = A.ID AND B.D > ?) K FROM T A ORDER BY ID" '[2.4]'

echo "-- 6. DML WHERE (rolled back, with a read-back) --"
dml_rb           "UPDATE U SET N = 99 WHERE ID > ? [2.5] (engine dml=(none) rb=1,1,1;2,2,2.5;3,99,2.49)" "UPDATE U SET N = 99 WHERE ID > ?" '[2.5]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "UPDATE U SET N = 99 WHERE ID = ? [2.5] - no row (engine dml=(none) rb=1,1,1;2,2,2.5;3,3,2.49)" "UPDATE U SET N = 99 WHERE ID = ?" '[2.5]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "DELETE FROM U WHERE ID > ? [1.5] (engine dml=(none) rb=1,1,1)" "DELETE FROM U WHERE ID > ?" '[1.5]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "DELETE FROM U WHERE NM = ? [2.495] (engine dml=(none) rb=1,1,1;2,2,2.5;3,3,2.49)" "DELETE FROM U WHERE NM = ?" '[2.495]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "INSERT INTO U SELECT .. FROM T WHERE ID > ? [2.5] (engine dml=(none) rb=1,1,1;2,2,2.5;3,3,2.49;13,5,NULL;19,5,NULL)" "INSERT INTO U (ID, N) SELECT ID + 10, 5 FROM T WHERE ID > ?" '[2.5]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "UPDATE OR INSERT MATCHING (ID) [4.5] - the INSERT rounds to 5 (engine dml=(none) rb=1,1,1;2,2,2.5;3,3,2.49;5,77,NULL)" "UPDATE OR INSERT INTO U (ID, N) VALUES (?, 77) MATCHING (ID)" '[4.5]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "UPDATE OR INSERT MATCHING (ID) [0.4] - the INSERT rounds to 0 (engine dml=(none) rb=0,77,NULL;1,1,1;2,2,2.5;3,3,2.49)" "UPDATE OR INSERT INTO U (ID, N) VALUES (?, 77) MATCHING (ID)" '[0.4]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb_both_err  "UPDATE OR INSERT MATCHING (ID) [0.6] - MATCHING compares the RAW double (no match), then INSERTs the ROUNDED 1 (engine dml=ERR Violation of PRIMARY or UNIQUE KEY constraint ''INTEG_6'' on table ''PUBLIC'.'U'', Problematic key value is ('ID' = 1) rb=1,1,1;2,2,2.5;3,3,2.)" "UPDATE OR INSERT INTO U (ID, N) VALUES (?, 77) MATCHING (ID)" '[0.6]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb_both_err  "UPDATE OR INSERT MATCHING (ID) [2.5] - the same law at 3 (engine dml=ERR Violation of PRIMARY or UNIQUE KEY constraint ''INTEG_6'' on table ''PUBLIC'.'U'', Problematic key value is ('ID' = 3) rb=1,1,1;2,2,2.5;3,3,2.)" "UPDATE OR INSERT INTO U (ID, N) VALUES (?, 77) MATCHING (ID)" '[2.5]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb_eng_only  "UPDATE U SET N = 99 WHERE BI > ? [2.5] - a WIDE where (engine dml=(none) rb=1,1,1;2,2,2.5;3,99,2.49)" "UPDATE U SET N = 99 WHERE BI > ?" '[2.5]' "SELECT ID, N, NM FROM U ORDER BY ID"

echo "-- 7. STORES into every exact type, and procedure arguments --"
dml_rb           "UPDATE W SET N = ? [2.5] - INTEGER, half away from zero (engine dml=(none) rb=1,3,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N = ? WHERE ID = 1" '[2.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N = ? [2.4] (engine dml=(none) rb=1,2,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N = ? WHERE ID = 1" '[2.4]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N = ? [-2.5] (engine dml=(none) rb=1,-3,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N = ? WHERE ID = 1" '[-2.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N = ? [0.5] (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N = ? WHERE ID = 1" '[0.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N = ? [1e-300] (engine dml=(none) rb=1,0,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N = ? WHERE ID = 1" '[1e-300]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N = ? [2147483647.4] - INTEGER takes it (engine dml=(none) rb=1,2147483647,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N = ? WHERE ID = 1" '[2147483647.4]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET SM = ? [2.5] - SMALLINT (engine dml=(none) rb=1,1,3,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET SM = ? WHERE ID = 1" '[2.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET SM = ? [-0.5] (engine dml=(none) rb=1,1,-1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET SM = ? WHERE ID = 1" '[-0.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET BI = ? [2.5] - BIGINT (engine dml=(none) rb=1,1,1,3,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET BI = ? WHERE ID = 1" '[2.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET BI = ? [3000000000.5] - BIGINT takes it (engine dml=(none) rb=1,1,1,3000000001,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET BI = ? WHERE ID = 1" '[3000000000.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET NM = ? [7.245] - NUMERIC(9,2) (engine dml=(none) rb=1,1,1,1,7.25,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET NM = ? WHERE ID = 1" '[7.245]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET NM = ? [7.255] (engine dml=(none) rb=1,1,1,1,7.26,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET NM = ? WHERE ID = 1" '[7.255]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N18 = ? [7.245] - NUMERIC(18,1) (engine dml=(none) rb=1,1,1,1,1.00,7.2,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N18 = ? WHERE ID = 1" '[7.245]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N18 = ? [7.255] (engine dml=(none) rb=1,1,1,1,1.00,7.3,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N18 = ? WHERE ID = 1" '[7.255]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N41 = ? [7.245] - NUMERIC(4,1) (engine dml=(none) rb=1,1,1,1,1.00,1.0,7.2,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N41 = ? WHERE ID = 1" '[7.245]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET H = ? [2.5] - INT128 (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,3,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET H = ? WHERE ID = 1" '[2.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET H2 = ? [10.075] - INT128 at scale 2: the RUNTIME eps law (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,10.07;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET H2 = ? WHERE ID = 1" '[10.075]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET H2 = ? [0.0049999999999999994] (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,0.01;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET H2 = ? WHERE ID = 1" '[0.004999999999999999]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET N = ? [NaN] - a NaN store writes the platform cast (ARM 0, x86 INT32_MIN) (engine dml=(none) rb=1,0,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET N = ? WHERE ID = 1" '["#NaN"]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET NM = ? [NaN] (engine dml=(none) rb=1,1,1,1,0.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET NM = ? WHERE ID = 1" '["#NaN"]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "UPDATE W SET BI = ? [NaN] (engine dml=(none) rb=1,1,1,0,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00)" "UPDATE W SET BI = ? WHERE ID = 1" '["#NaN"]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "INSERT INTO W: six exact slots at once [2.5, 2.5, 2.5, 7.245, 7.245, 7.245] (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00;5,3,3,3,7.25,7.2,7.2,NULL,NULL)" "INSERT INTO W (ID, N, SM, BI, NM, N18, N41) VALUES (5, ?, ?, ?, ?, ?, ?)" '[2.5, 2.5, 2.5, 7.245, 7.245, 7.245]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "INSERT .. RETURNING NM [7.255] (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00;6,NULL,NULL,NULL,7.26,NULL,NULL,NULL,NULL)" "INSERT INTO W (ID, NM) VALUES (6, ?) RETURNING NM" '[7.255]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb_both_err  "UPDATE W SET N = ? [2147483647.6] - 22003 out of range (engine dml=ERR Arithmetic exception, numeric overflow, or string truncation, numeric value is out of range rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.)" "UPDATE W SET N = ? WHERE ID = 1" '[2147483647.6]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb_both_err  "UPDATE W SET N = ? [3000000000.5] - 22003 (engine dml=ERR Arithmetic exception, numeric overflow, or string truncation, numeric value is out of range rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.)" "UPDATE W SET N = ? WHERE ID = 1" '[3000000000.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb_both_err  "UPDATE W SET SM = ? [40000.5] - 22003 (engine dml=ERR Arithmetic exception, numeric overflow, or string truncation, numeric value is out of range rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.)" "UPDATE W SET SM = ? WHERE ID = 1" '[40000.5]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb_both_err  "UPDATE W SET NM = ? [2147483647.4] - NUMERIC(9,2) refuses what INTEGER takes (engine dml=ERR Arithmetic exception, numeric overflow, or string truncation, numeric value is out of range rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.)" "UPDATE W SET NM = ? WHERE ID = 1" '[2147483647.4]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb_both_err  "UPDATE W SET N = ? [+Inf] - 22003 (engine dml=ERR Arithmetic exception, numeric overflow, or string truncation, numeric value is out of range rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.)" "UPDATE W SET N = ? WHERE ID = 1" '["#Inf"]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb_both_err  "UPDATE W SET N = ? [-Inf] - 22003 (engine dml=ERR Arithmetic exception, numeric overflow, or string truncation, numeric value is out of range rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.)" "UPDATE W SET N = ? WHERE ID = 1" '["#-Inf"]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb_both_err  "INSERT INTO W (N) VALUES (?) [+Inf] - 22003 (engine dml=ERR Arithmetic exception, numeric overflow, or string truncation, numeric value is out of range rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.)" "INSERT INTO W (ID, N) VALUES (7, ?)" '["#Inf"]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "EXECUTE PROCEDURE P3(?, ?) [2.5, 7.245] - the argument conversion on the EXECUTE path (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00;8,3,NULL,NULL,7.25,NULL,NULL,NULL,NULL)" "EXECUTE PROCEDURE P3(?, ?)" '[2.5, 7.245]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "EXECUTE PROCEDURE P3(?, ?) [-2.5, 7.255] (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00;8,-3,NULL,NULL,7.26,NULL,NULL,NULL,NULL)" "EXECUTE PROCEDURE P3(?, ?)" '[-2.5, 7.255]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
dml_rb           "EXECUTE PROCEDURE P3(?, ?) [NaN, NaN] - a NaN argument stores the platform cast (engine dml=(none) rb=1,1,1,1,1.00,1.0,1.0,1,1.00;2,2,2,2,2.00,2.0,2.0,2,2.00;8,0,NULL,NULL,0.00,NULL,NULL,NULL,NULL)" "EXECUTE PROCEDURE P3(?, ?)" '["#NaN", "#NaN"]' "SELECT ID, CAST(N AS VARCHAR(40)) VN, CAST(SM AS VARCHAR(40)) VS, CAST(BI AS VARCHAR(40)) VB, CAST(NM AS VARCHAR(40)) VM, CAST(N18 AS VARCHAR(40)) V18, CAST(N41 AS VARCHAR(40)) V41, CAST(H AS VARCHAR(50)) VH, CAST(H2 AS VARCHAR(50)) VH2 FROM W ORDER BY ID"
both             "a selectable procedure: SELECT FROM P1(?, ?) [2.5, 7.245] (engine 3,7.25)" "SELECT RA, RB FROM P1(?, ?)" '[2.5, 7.245]'
both             "SELECT FROM P1(?, ?) [2.4, 7.255] (engine 2,7.26)" "SELECT RA, RB FROM P1(?, ?)" '[2.4, 7.255]'
both             "SELECT FROM P1(?, ?) [-2.5, -7.245] (engine -3,-7.25)" "SELECT RA, RB FROM P1(?, ?)" '[-2.5, -7.245]'
both             "SELECT FROM P1(?, 1) [2147483647.4] - INTEGER takes it (engine 2147483647,1)" "SELECT RA, RB FROM P1(?, 1)" '[2147483647.4]'
both             "SELECT FROM P2(?, ?) [2.5, 2.5] - BIGINT and SMALLINT inputs (engine 3,3)" "SELECT RA, RB FROM P2(?, ?)" '[2.5, 2.5]'
both             "a procedure argument [NaN, NaN] converts by the platform cast (ARM engine 0,0)" "SELECT RA, RB FROM P1(?, ?)" '["#NaN", "#NaN"]'
both             "WHERE over a procedure's output: RA < ? [3.5] (engine 3)" "SELECT RA FROM P1(3, 1) WHERE RA < ?" '[3.5]'
both_err         "P1(1, ?) [2147483647.4] - 22003 out of range for NUMERIC(9,2) (engine ERR Arithmetic exception, numeric overflow, or string trunca)" "SELECT RA, RB FROM P1(1, ?)" '[2147483647.4]'
both_err         "P1(?, 1) [+Inf] - 22003 (engine ERR Arithmetic exception, numeric overflow, or string trunca)" "SELECT RA, RB FROM P1(?, 1)" '["#Inf"]'
both_err         "P1(?, 1) [3000000000.5] - 22003 (engine ERR Arithmetic exception, numeric overflow, or string trunca)" "SELECT RA, RB FROM P1(?, 1)" '[3000000000.5]'

echo "-- 8. +-Infinity and NaN against DOUBLE / FLOAT columns and expressions --"
both             "D < ? [+Inf] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D < ? ORDER BY ID" '["#Inf"]'
both             "D = ? [+Inf] (engine (none))" "SELECT ID FROM T WHERE D = ? ORDER BY ID" '["#Inf"]'
both             "D > ? [-Inf] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D > ? ORDER BY ID" '["#-Inf"]'
both             "D + 0 < ? [+Inf] - an expression side (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D + 0 < ? ORDER BY ID" '["#Inf"]'
desc_differs     "FL < ? [+Inf] - a FLOAT column: the VALUE agrees and the FLOAT slot is announced DOUBLE (480) where the engine says FLOAT (482) - the same recorded gap as the section 9 control (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE FL < ? ORDER BY ID" '["#Inf"]'
both             "TI.D < ? [+Inf] - indexed (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE D < ? ORDER BY ID" '["#Inf"]'
eng_only         "D = ? [NaN] (engine (none))" "SELECT ID FROM T WHERE D = ? ORDER BY ID" '["#NaN"]'
eng_only         "D <> ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D <> ? ORDER BY ID" '["#NaN"]'
both             "D < ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D < ? ORDER BY ID" '["#NaN"]'
both             "D <= ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D <= ? ORDER BY ID" '["#NaN"]'
both             "D > ? [NaN] (engine (none))" "SELECT ID FROM T WHERE D > ? ORDER BY ID" '["#NaN"]'
both             "D >= ? [NaN] (engine (none))" "SELECT ID FROM T WHERE D >= ? ORDER BY ID" '["#NaN"]'
eng_only         "? < D [NaN] - reversed (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ? < D ORDER BY ID" '["#NaN"]'
eng_only         "? = D [NaN] - reversed (engine (none))" "SELECT ID FROM T WHERE ? = D ORDER BY ID" '["#NaN"]'
both             "D + 0 < ? [NaN] - an expression side (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D + 0 < ? ORDER BY ID" '["#NaN"]'
both             "D BETWEEN ? AND 99 [NaN] (engine (none))" "SELECT ID FROM T WHERE D BETWEEN ? AND 99 ORDER BY ID" '["#NaN"]'
eng_only         "D IN (?, 99) [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D IN (?, 99) ORDER BY ID" '["#NaN"]'
eng_only         "D IS DISTINCT FROM ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D IS DISTINCT FROM ? ORDER BY ID" '["#NaN"]'
both             "TI.D < ? [NaN] - indexed (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE D < ? ORDER BY ID" '["#NaN"]'
both             "TI.D > ? [NaN] - indexed (engine (none))" "SELECT ID FROM TI WHERE D > ? ORDER BY ID" '["#NaN"]'
eng_only         "FL = ? [NaN] (engine (none))" "SELECT ID FROM T WHERE FL = ? ORDER BY ID" '["#NaN"]'
eng_only         "FL > ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE FL > ? ORDER BY ID" '["#NaN"]'
eng_only         "ID > ? [NaN] - an EXACT column (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '["#NaN"]'
eng_only         "ID = ? [NaN] (engine (none))" "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '["#NaN"]'
eng_only         "ID <> ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID <> ? ORDER BY ID" '["#NaN"]'
eng_only         "NM >= ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE NM >= ? ORDER BY ID" '["#NaN"]'
eng_only         "BI > ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE BI > ? ORDER BY ID" '["#NaN"]'
eng_only         "TI.ID > ? [NaN] - the LONG index answers the OTHER WAY from the scan (engine (none))" "SELECT ID FROM TI WHERE ID > ? ORDER BY ID" '["#NaN"]'
eng_only         "ID + 0 > ? [NaN] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID + 0 > ? ORDER BY ID" '["#NaN"]'
eng_only         "HAVING SUM(ID) > ? [NaN] (engine 12)" "SELECT SUM(ID) X FROM T HAVING SUM(ID) > ?" '["#NaN"]'
both             "ID > CAST(? AS INTEGER) [NaN] - a written cast ABSORBS the NaN, by the platform cast (ARM engine 1;2;3;9, x86 every row)" "SELECT ID FROM T WHERE ID > CAST(? AS INTEGER) ORDER BY ID" '["#NaN"]'
both             "ID = CAST(? AS INTEGER) [NaN] (engine 0)" "SELECT ID FROM T WHERE ID = CAST(? AS INTEGER) ORDER BY ID" '["#NaN"]'
both             "ID > ? + 0 [NaN] - an operand rung absorbs it (engine 1;2;3;9)" "SELECT ID FROM T WHERE ID > ? + 0 ORDER BY ID" '["#NaN"]'
dml_rb           "DELETE FROM U WHERE D < ? [NaN] - a WRONG DELETE on the previous binary (engine dml=(none) rb=(none))" "DELETE FROM U WHERE D < ?" '["#NaN"]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "UPDATE U SET N = 99 WHERE D >= ? [NaN] (engine dml=(none) rb=1,1,1;2,2,2.5;3,3,2.49)" "UPDATE U SET N = 99 WHERE D >= ?" '["#NaN"]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "DELETE FROM U WHERE D < ? [+Inf] (engine dml=(none) rb=(none))" "DELETE FROM U WHERE D < ?" '["#Inf"]' "SELECT ID, N, NM FROM U ORDER BY ID"

echo "-- 9. CONTROLS: what the previous binary already answers --"
both             "CONTROL CAST(? AS INTEGER) [2.5] (engine 3)" "SELECT CAST(? AS INTEGER) X FROM RDB\$DATABASE" '[2.5]'
both             "CONTROL CAST(? AS INTEGER) [2.4] (engine 2)" "SELECT CAST(? AS INTEGER) X FROM RDB\$DATABASE" '[2.4]'
both             "CONTROL CAST(? AS INTEGER) [-2.5] (engine -3)" "SELECT CAST(? AS INTEGER) X FROM RDB\$DATABASE" '[-2.5]'
both             "CONTROL CAST(? AS NUMERIC(9,2)) [7.245] (engine 7.25)" "SELECT CAST(? AS NUMERIC(9,2)) X FROM RDB\$DATABASE" '[7.245]'
both             "CONTROL CAST(? AS NUMERIC(9,2)) [7.255] (engine 7.26)" "SELECT CAST(? AS NUMERIC(9,2)) X FROM RDB\$DATABASE" '[7.255]'
both             "CONTROL CAST(? AS BIGINT) [2.5] (engine 3)" "SELECT CAST(? AS BIGINT) X FROM RDB\$DATABASE" '[2.5]'
both             "CONTROL CAST(? AS SMALLINT) [2.5] (engine 3)" "SELECT CAST(? AS SMALLINT) X FROM RDB\$DATABASE" '[2.5]'
both             "CONTROL an INTEGRAL bind: ID = ? [2] - an integer message (engine 2)" "SELECT ID FROM T WHERE ID = ? ORDER BY ID" '[2]'
both             "CONTROL an integral bind: ID > ? [2] (engine 3;9)" "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '[2]'
both             "CONTROL ID > CAST(? AS DOUBLE PRECISION) [2.5] (engine 3;9)" "SELECT ID FROM T WHERE ID > CAST(? AS DOUBLE PRECISION) ORDER BY ID" '[2.5]'
both             "CONTROL BI > CAST(? AS DOUBLE PRECISION) [2.5] - the scan path (engine 3;9)" "SELECT ID FROM T WHERE BI > CAST(? AS DOUBLE PRECISION) ORDER BY ID" '[2.5]'
both             "CONTROL a correlated EXISTS: B.D > ? [2.4] (engine 2;3)" "SELECT ID FROM T A WHERE EXISTS (SELECT 1 FROM U B WHERE B.ID = A.ID AND B.D > ?) ORDER BY ID" '[2.4]'
both             "CONTROL D = ? [2.5] - an approximate column already takes a double (engine 2)" "SELECT ID FROM T WHERE D = ? ORDER BY ID" '[2.5]'
both             "CONTROL D > ? [2.4] (engine 2;3;9)" "SELECT ID FROM T WHERE D > ? ORDER BY ID" '[2.4]'
desc_differs     "CONTROL FL > ? [2.6] - the VALUE agrees; the FLOAT slot is announced DOUBLE (480) where the engine says FLOAT (482) - a recorded describe gap outside this chunk (engine 2;3;9)" "SELECT ID FROM T WHERE FL > ? ORDER BY ID" '[2.6]'
dml_rb           "CONTROL UPDATE U SET NM = ? WHERE ID = 1 [7.255] (engine dml=(none) rb=1,1,7.26;2,2,2.5;3,3,2.49)" "UPDATE U SET NM = ? WHERE ID = 1" '[7.255]' "SELECT ID, N, NM FROM U ORDER BY ID"
dml_rb           "CONTROL UPDATE U SET D = ? WHERE ID = 1 [2.5] (engine dml=(none) rb=1,1,1;2,2,2.5;3,3,2.49)" "UPDATE U SET D = ? WHERE ID = 1" '[2.5]' "SELECT ID, N, NM FROM U ORDER BY ID"

echo "-- 10. PINS: the raw-compare positions and the value positions --"
eng_only         "PIN NULLIF(?, 3) [3.4] - NULLIF compares the RAW client double (engine 3)" "SELECT NULLIF(?, 3) X FROM RDB\$DATABASE" '[3.4]'
eng_only         "PIN NULLIF(3, ?) [2.5] (engine 3)" "SELECT NULLIF(3, ?) X FROM RDB\$DATABASE" '[2.5]'
eng_only         "PIN NULLIF(ID, ?) IS NULL [2.5] (engine (none))" "SELECT ID FROM T WHERE NULLIF(ID, ?) IS NULL ORDER BY ID" '[2.5]'
both             "PIN CONTROL NULLIF(?, 3) [3] - an integer message (engine NULL)" "SELECT NULLIF(?, 3) X FROM RDB\$DATABASE" '[3]'
both             "PIN CONTROL NULLIF(?, 3) [2] (engine 2)" "SELECT NULLIF(?, 3) X FROM RDB\$DATABASE" '[2]'
both             "PIN CONTROL NULLIF(CAST(? AS INTEGER), 3) [2.5] (engine NULL)" "SELECT NULLIF(CAST(? AS INTEGER), 3) X FROM RDB\$DATABASE" '[2.5]'
eng_only         "PIN MAXVALUE(?, -2) [NaN] - a value position that does NOT convert (engine -2)" "SELECT MAXVALUE(?, -2) X FROM RDB\$DATABASE" '["#NaN"]'
eng_only         "PIN COALESCE(?, 5) = 0 [NaN] - a value position that DOES convert (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE COALESCE(?, 5) = 0 ORDER BY ID" '["#NaN"]'
both             "PIN IIF(ID > ?, 1, 0) = 1 [2.5] (engine 3;9)" "SELECT ID FROM T WHERE IIF(ID > ?, 1, 0) = 1 ORDER BY ID" '[2.5]'
both             "PIN IIF(BI > ?, 1, 0) = 1 [2.5] - an index is never matched inside IIF (engine 3;9)" "SELECT ID FROM T WHERE IIF(BI > ?, 1, 0) = 1 ORDER BY ID" '[2.5]'
both             "PIN IIF(BI > ?, 1, 0) = 1 [2.5] on the INDEXED table (engine 3;9)" "SELECT ID FROM TI WHERE IIF(BI > ?, 1, 0) = 1 ORDER BY ID" '[2.5]'
dml_rb_eng_only  "PIN UPDATE U SET N = NULLIF(?, 3) WHERE ID = 1 [2.5] - a wrong WRITE on the previous binary (engine dml=(none) rb=1,3,1;2,2,2.5;3,3,2.49)" "UPDATE U SET N = NULLIF(?, 3) WHERE ID = 1" '[2.5]' "SELECT ID, N, NM FROM U ORDER BY ID"

echo "-- 11. THE WHOLE-SIDE RUNG \`(?)\`: THE SOURCE WIDTH AND THE ACCESS PATH --"
# 11A. A SHORT- OR LONG-BACKED KEY IS A DOUBLE KEY and never rounds, so
# the parenthesised whole side answers the SAME rows scanned and indexed.
# EVERY CELL IN 11A IS A FLOOR CELL: /tmp/fcwire-prev-0e5a8f4 answers all
# of them exactly like the engine, and round 1 of this chunk refused every
# one (163 such binds measured 2026-09-20).  They are here so a future
# round cannot lose them again.
both             "FLOOR T.ID > (?) [2.5] - INTEGER, heap (engine 3;9)" "SELECT ID FROM T WHERE ID > (?) ORDER BY ID" '[2.5]'
both             "FLOOR TI.ID > (?) [2.5] - INTEGER, INDEXED: the same rows (engine 3;9)" "SELECT ID FROM TI WHERE ID > (?) ORDER BY ID" '[2.5]'
both             "FLOOR T.SM > (?) [2.5] - SMALLINT (engine 3;9)" "SELECT ID FROM T WHERE SM > (?) ORDER BY ID" '[2.5]'
both             "FLOOR TI.SM > (?) [2.5] - SMALLINT, INDEXED (engine 3;9)" "SELECT ID FROM TI WHERE SM > (?) ORDER BY ID" '[2.5]'
both             "FLOOR T.NM > (?) [2.495] - NUMERIC(9,2), LONG-backed (engine 1;2;9)" "SELECT ID FROM T WHERE NM > (?) ORDER BY ID" '[2.495]'
both             "FLOOR TI.NM > (?) [2.495] - NUMERIC(9,2), INDEXED (engine 1;2;9)" "SELECT ID FROM TI WHERE NM > (?) ORDER BY ID" '[2.495]'
both             "FLOOR T.N41 > (?) [2.45] - NUMERIC(4,1), SHORT-backed (engine 2;9)" "SELECT ID FROM T WHERE N41 > (?) ORDER BY ID" '[2.45]'
both             "FLOOR TI.N41 > (?) [2.45] - NUMERIC(4,1), INDEXED (engine 2;9)" "SELECT ID FROM TI WHERE N41 > (?) ORDER BY ID" '[2.45]'
both             "FLOOR T (?) < ID [2.5] - the reversed spelling (engine 3;9)" "SELECT ID FROM T WHERE (?) < ID ORDER BY ID" '[2.5]'
both             "FLOOR TI (?) < ID [2.5] - reversed, INDEXED (engine 3;9)" "SELECT ID FROM TI WHERE (?) < ID ORDER BY ID" '[2.5]'
both             "FLOOR T.ID = (?) [2.5] (engine (none))" "SELECT ID FROM T WHERE ID = (?) ORDER BY ID" '[2.5]'
both             "FLOOR T.ID <> (?) [2.5] (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE ID <> (?) ORDER BY ID" '[2.5]'
both             "FLOOR T.ID BETWEEN (?) AND 8 [2.5] (engine 3)" "SELECT ID FROM T WHERE ID BETWEEN (?) AND 8 ORDER BY ID" '[2.5]'
both             "FLOOR TI.ID BETWEEN -8 AND (?) [2.5] - the upper bound, INDEXED (engine -3;0;1;2)" "SELECT ID FROM TI WHERE ID BETWEEN -8 AND (?) ORDER BY ID" '[2.5]'
both             "FLOOR T NOT (ID > (?)) [2.5] (engine -3;0;1;2)" "SELECT ID FROM T WHERE NOT (ID > (?)) ORDER BY ID" '[2.5]'
both             "FLOOR T.ID > (?) OR ID = 1 [2.5] (engine 1;3;9)" "SELECT ID FROM T WHERE ID > (?) OR ID = 1 ORDER BY ID" '[2.5]'
both             "FLOOR T.SM = (?) [2.5] - the whole-side spelling still compares as a double (engine (none))" "SELECT ID FROM T WHERE SM = (?) ORDER BY ID" '[2.5]'
both             "FLOOR JOIN A.SM > (?) [2.5] (engine 3;9)" "SELECT A.ID FROM T A JOIN T B ON A.ID = B.ID WHERE A.SM > (?) ORDER BY A.ID" '[2.5]'
both             "FLOOR derived NM > (?) [2.495] (engine 1;2;9)" "SELECT X.ID FROM (SELECT ID, NM FROM T) X WHERE X.NM > (?) ORDER BY X.ID" '[2.495]'
both             "FLOOR CTE N41 > (?) [2.45] (engine 2;9)" "WITH X AS (SELECT ID, N41 FROM T) SELECT ID FROM X WHERE N41 > (?) ORDER BY ID" '[2.45]'
both             "FLOOR view ID > (?) [2.5] (engine 3;9)" "SELECT ID FROM V1 WHERE ID > (?) ORDER BY ID" '[2.5]'
both             "FLOOR a selectable procedure's output: RA < (?) [1.5] (engine 1)" "SELECT RA FROM P1(1, 1) WHERE RA < (?)" '[1.5]'
both             "FLOOR HAVING SUM(ID) > (?) [2.5] - an aggregate is never an index key (engine 3,3;9,9)" "SELECT NN, SUM(ID) AS S FROM T GROUP BY NN HAVING SUM(ID) > (?) ORDER BY NN" '[2.5]'
dml_rb           "FLOOR UPDATE U SET N = 77 WHERE ID > (?) [2.5] (engine dml=(none) rb=1,1;2,2;3,77)" "UPDATE U SET N = 77 WHERE ID > (?)" '[2.5]' "SELECT ID, N FROM U ORDER BY ID"
dml_rb           "FLOOR DELETE FROM U WHERE NM > (?) [2.495] (engine dml=(none) rb=1;3)" "DELETE FROM U WHERE NM > (?)" '[2.495]' "SELECT ID FROM U ORDER BY ID"
both             "FLOOR an INTEGER bind through the same rung: TI.BI > (?) [2] (engine 3;9)" "SELECT ID FROM TI WHERE BI > (?) ORDER BY ID" '[2]'

# 11B. AN INT64-BACKED KEY IS THE ONE WIDTH WHOSE INDEX BOUND ROUNDS, so
# the rung is decided BY THE ACCESS PATH: an unkeyed plain column is a
# SCAN and compares as a double (floor cells), a KEYED one and an
# EXPRESSION side (which may carry an index COMPUTED BY) refuse.
both             "FLOOR T.BI > (?) [2.5] - BIGINT on the HEAP: the scan compares as a double (engine 3;9)" "SELECT ID FROM T WHERE BI > (?) ORDER BY ID" '[2.5]'
both             "FLOOR T.N18 > (?) [2.45] - NUMERIC(18,1) on the heap (engine 2;9)" "SELECT ID FROM T WHERE N18 > (?) ORDER BY ID" '[2.45]'
eng_only         "11E COST JOIN A.BI > (?) [2.5] over the HEAP - a floor cell of round 2 that round 13 gave up: the router cannot see that no index leads with BI (engine 3;9)" "SELECT A.ID FROM T A JOIN T B ON A.ID = B.ID WHERE A.BI > (?) ORDER BY A.ID" '[2.5]'
eng_only         "11E COST view V1.BI > (?) [2.5] over the HEAP - the other floor cell round 13 gave up (engine 3;9)" "SELECT ID FROM V1 WHERE BI > (?) ORDER BY ID" '[2.5]'
dml_rb           "FLOOR UPDATE U SET N = 77 WHERE BI > (?) [2.5] - BI is not a key of U (engine dml=(none) rb=1,1;2,2;3,77)" "UPDATE U SET N = 77 WHERE BI > (?)" '[2.5]' "SELECT ID, N FROM U ORDER BY ID"
eng_only         "TI.BI > (?) [2.5] - the INDEX BOUND ROUNDS 2.5 to 3 and the heap does not (engine 9, heap 3;9)" "SELECT ID FROM TI WHERE BI > (?) ORDER BY ID" '[2.5]'
eng_only         "TI.N18 > (?) [2.45] - the same at scale 1 (engine 9, heap 2;9)" "SELECT ID FROM TI WHERE N18 > (?) ORDER BY ID" '[2.45]'
eng_only         "TI.BI <> (?) [2.5] - a keyed column refuses whatever the operator (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE BI <> (?) ORDER BY ID" '[2.5]'
eng_only         "TE.BI + 0 > (?) [2.5] - an INDEX COMPUTED BY (BI + 0) rounds it (engine 9)" "SELECT ID FROM TE WHERE BI + 0 > (?) ORDER BY ID" '[2.5]'
eng_only         "TE.ID + 0 > (?) [2.5] - arithmetic widens a LONG column to INT64 and the computed index rounds (engine 9)" "SELECT ID FROM TE WHERE ID + 0 > (?) ORDER BY ID" '[2.5]'
eng_only         "T.ID > -? [2.5] - a NEGATED whole-side chain refuses at prepare on both binaries (engine 0;1;2;3;9)" "SELECT ID FROM T WHERE ID > -? ORDER BY ID" '[2.5]'

# 11C. PROMOTED 2026-09-20 by the NaN chunk (`qa/serve-real-nanparam.sh`):
# the cells below that RECORDED A REFUSAL now ANSWER, with the engine's own
# answer on every access path.  The refusal was never a law - the engine's
# NaN order is DETERMINED, by the WRITTEN ORDER of the term and the other
# side's CLASS - and `mirrored` is what finally told the two spellings
# apart.  What still refuses here is the one shape that genuinely splits
# (a TRUE verdict on a LOWER BOUND, where an index range over a NaN is
# empty) and the two EQUALITY operators, which are one tree with an `IN`
# list the engine reads as a range or a zero-conversion.
#
# 11C. THE NaN ORDER, re-measured over the whole matrix (596 + 1344
# three-way cells, 2026-09-20).  The engine has TWO orders and the OTHER
# side's precision picks which: against a DOUBLE side THE FIRST OPERAND IS
# THE LESSER whichever way round it is written, against a SINGLE (FLOAT)
# or EXACT side a NaN sorts BELOW everything.  The previous binary read a
# NaN as EQUAL to everything, which is the engine's verdict on some
# operators and not others - and \`? op X\` is MIRRORED into \`X mirror(op)
# ?\` at parse, so ONE term carries both spellings and only an operator
# whose BOTH spellings agree can be answered.  These are floor cells.
desc_differs     "FLOOR FL < ? [NaN] - a SINGLE side, both spellings FALSE; the FLOAT slot is announced DOUBLE (480) where the engine says FLOAT (482), the section 9 gap (engine (none))" "SELECT ID FROM T WHERE FL < ? ORDER BY ID" '["#NaN"]'
desc_differs     "FLOOR TI.FL < ? [NaN] - indexed; the same FLOAT-slot describe gap (engine (none))" "SELECT ID FROM TI WHERE FL < ? ORDER BY ID" '["#NaN"]'
desc_differs     "FLOOR ? > FL [NaN] - the same term, written the other way; the FLOAT-slot describe gap (engine (none))" "SELECT ID FROM T WHERE ? > FL ORDER BY ID" '["#NaN"]'
desc_differs     "FLOOR ABS(FL) < ? [NaN] - ABS keeps SINGLE precision; the FLOAT-slot describe gap (engine (none))" "SELECT ID FROM T WHERE ABS(FL) < ? ORDER BY ID" '["#NaN"]'
both             "FLOOR (?) > D [NaN] - the written order survives a whole-side rung (engine (none))" "SELECT ID FROM T WHERE (?) > D ORDER BY ID" '["#NaN"]'
both             "FLOOR (?) > ID [NaN] - an EXACT side, indexed (engine (none))" "SELECT ID FROM TI WHERE (?) > ID ORDER BY ID" '["#NaN"]'
desc_differs     "FLOOR IIF(? > FL, 1, 0) = 1 [NaN] - an IIF condition keeps its order; the FLOAT-slot describe gap (engine (none))" "SELECT ID FROM T WHERE IIF(? > FL, 1, 0) = 1 ORDER BY ID" '["#NaN"]'
both             "FLOOR D + 0 > (?) [NaN] - arithmetic is DOUBLE by construction (engine (none))" "SELECT ID FROM T WHERE D + 0 > (?) ORDER BY ID" '["#NaN"]'
both             "FLOOR D + 0 <= (?) [NaN] - the TRUE verdict, an UPPER bound an index cannot narrow (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D + 0 <= (?) ORDER BY ID" '["#NaN"]'
both             "FLOOR TI.FL + 0 > (?) [NaN] - FLOAT arithmetic widens to DOUBLE (engine (none))" "SELECT ID FROM TI WHERE FL + 0 > (?) ORDER BY ID" '["#NaN"]'
both             "D <= ? [NaN] - ANSWERED NOW: every row here and NONE for the mirror twin \`? >= D\`, one term (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D <= ? ORDER BY ID" '["#NaN"]'
both             "? >= D [NaN] - that mirror twin (engine (none))" "SELECT ID FROM T WHERE ? >= D ORDER BY ID" '["#NaN"]'
both             "TI.D <= ? [NaN] - indexed (engine -3;0;1;2;3;9)" "SELECT ID FROM TI WHERE D <= ? ORDER BY ID" '["#NaN"]'
eng_only         "FL >= ? [NaN] - a SINGLE side's TRUE verdict is a LOWER bound and the indexed twin answers none (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE FL >= ? ORDER BY ID" '["#NaN"]'
eng_only         "D IN (?, 99) [NaN] - the engine's IN is not its \`=\` (engine -3;0;1;2;3;9)" "SELECT ID FROM T WHERE D IN (?, 99) ORDER BY ID" '["#NaN"]'
eng_only         "D NOT IN (?, 99) [NaN] (engine (none))" "SELECT ID FROM T WHERE D NOT IN (?, 99) ORDER BY ID" '["#NaN"]'
both             "D BETWEEN 0 AND ? [NaN] (engine 0;1;2;3;9)" "SELECT ID FROM T WHERE D BETWEEN 0 AND ? ORDER BY ID" '["#NaN"]'
both             "D + 0 > ? [NaN] - ANSWERED NOW: the BARE spelling: its mirror twin \`? < D + 0\` is every row (engine (none))" "SELECT ID FROM T WHERE D + 0 > ? ORDER BY ID" '["#NaN"]'
both             "ABS(D) > ? [NaN] (engine (none))" "SELECT ID FROM T WHERE ABS(D) > ? ORDER BY ID" '["#NaN"]'
eng_only         "TI.ID > CAST(? AS DOUBLE PRECISION) [NaN] - an explicit cast carries no side precision (engine (none))" "SELECT ID FROM TI WHERE ID > CAST(? AS DOUBLE PRECISION) ORDER BY ID" '["#NaN"]'

# 11D. A SHORT-BACKED COLUMN CONVERTS A BOUND DOUBLE INSIDE A MULTI-ITEM
# \`IN\` LIST and compares it as a double everywhere else - and an \`IN\`
# desugars into the same OR of equalities a written \`SM = ? OR SM = 99\`
# builds, which does NOT convert.  One tree, two engine answers: the
# EQUALITY refuses (round 1 answered it, wrongly, where the floor binary
# refused).  Every other operator is unaffected.
eng_only         "SM IN (?, 99) [2.5] - a SMALLINT IN list ROUNDS 2.5 to 3 (engine 3)" "SELECT ID FROM T WHERE SM IN (?, 99) ORDER BY ID" '[2.5]'
eng_only         "N41 IN (?, 99) [2.45] - NUMERIC(4,1) rounds to 2.5 (engine 2)" "SELECT ID FROM T WHERE N41 IN (?, 99) ORDER BY ID" '[2.45]'
eng_only         "SM NOT IN (?, 99) [2.5] - NOT IN desugars into the same equalities (engine -3;0;1;2;9)" "SELECT ID FROM T WHERE SM NOT IN (?, 99) ORDER BY ID" '[2.5]'
eng_only         "SM = ? [2.5] - the equality this server cannot tell from the IN list (engine (none))" "SELECT ID FROM T WHERE SM = ? ORDER BY ID" '[2.5]'
both             "SM > ? [2.5] - every other operator compares as a double at this width (engine 3;9)" "SELECT ID FROM T WHERE SM > ? ORDER BY ID" '[2.5]'
both             "N41 <= ? [2.45] (engine -3;0;1;3)" "SELECT ID FROM T WHERE N41 <= ? ORDER BY ID" '[2.45]'
both             "11D CONTRAST SM = ? [2] - an exact bind is unaffected (engine 2)" "SELECT ID FROM T WHERE SM = ? ORDER BY ID" '[2]'
both             "11D CONTRAST ID IN (?, 99) [2.5] - a LONG-backed IN list does NOT convert (engine (none))" "SELECT ID FROM T WHERE ID IN (?, 99) ORDER BY ID" '[2.5]'

echo "-- 11E. THE ROUTER PATH DOES NOT KNOW ITS KEYS --"
# A JOIN's combined row, a derived table, a CTE, a UNION leg and a view
# all build their filter WITHOUT reading a catalog, so `Predicate::keys`
# is EMPTY there.  Until round 13 the rung read that empty list as "no
# index leads with this column" and answered the SCAN reading - which is
# the engine's answer over a heap and NOT its answer over an indexed
# twin.  Measured 2026-09-20, SEVEN WRONG ANSWERS, every one of them also
# wrong on /tmp/fcwire-prev-0e5a8f4 (so pre-existing, not a regression):
# a derived table, a CTE, a view, a JOIN and a UNION leg over `BI > (?)`
# [2.5], and the same at scale 1 for `N18 > (?)` [2.45].
#
# The rung now refuses wherever the path is UNKNOWN, which is exactly the
# policy the BARE `?` spelling has always had - it marks
# `ColKind::WideExact` from the column's WIDTH alone, so `X.BI > ?`
# refuses through every router and `T.BI > ?` refuses even on the heap
# (section 1).  One policy for two spellings of one comparison.
#
# THE COST IS REAL AND IT IS HERE: the two `11E COST` cells in 11B above,
# plus the derived and CTE twins below, are shapes the previous binary
# answered CORRECTLY and this one refuses - a router over a HEAP relation,
# where the scan reading is right and nothing here can tell.  Four
# capabilities traded for seven wrong answers.  Recovering them means
# teaching the router retrievals their relation's keys, which is a chunk
# of its own and is ranked in the roadmap.
eng_only         "11E a derived table over the INDEXED twin: X.BI > (?) [2.5] (engine 9, the heap 3;9)" "SELECT X.ID FROM (SELECT ID, BI FROM TI) X WHERE X.BI > (?) ORDER BY X.ID" '[2.5]'
eng_only         "11E a CTE over the INDEXED twin: Q.BI > (?) [2.5] (engine 9)" "WITH Q AS (SELECT ID, BI FROM TI) SELECT ID FROM Q WHERE BI > (?) ORDER BY ID" '[2.5]'
eng_only         "11E a VIEW over the INDEXED twin: VI.BI > (?) [2.5] (engine 9)" "SELECT ID FROM VI WHERE BI > (?) ORDER BY ID" '[2.5]'
eng_only         "11E a JOIN over the INDEXED twin: A.BI > (?) [2.5] (engine 9)" "SELECT A.ID FROM TI A JOIN TI B ON A.ID = B.ID WHERE A.BI > (?) ORDER BY A.ID" '[2.5]'
eng_only         "11E a UNION leg over the INDEXED twin: BI > (?) [2.5] (engine 9;-99)" "SELECT ID FROM TI WHERE BI > (?) UNION ALL SELECT -99 FROM RDB\$DATABASE" '[2.5]'
eng_only         "11E scale 1: a derived table over the INDEXED twin, X.N18 > (?) [2.45] (engine 9)" "SELECT X.ID FROM (SELECT ID, N18 FROM TI) X WHERE X.N18 > (?) ORDER BY X.ID" '[2.45]'
eng_only         "11E scale 1: a CTE over the INDEXED twin, Q.N18 > (?) [2.45] (engine 9)" "WITH Q AS (SELECT ID, N18 FROM TI) SELECT ID FROM Q WHERE N18 > (?) ORDER BY ID" '[2.45]'
eng_only         "11E COST a derived table over the HEAP: X.BI > (?) [2.5] - right before round 13, refused now (engine 3;9)" "SELECT X.ID FROM (SELECT ID, BI FROM T) X WHERE X.BI > (?) ORDER BY X.ID" '[2.5]'
eng_only         "11E COST a CTE over the HEAP: Q.BI > (?) [2.5] - the same (engine 3;9)" "WITH Q AS (SELECT ID, BI FROM T) SELECT ID FROM Q WHERE BI > (?) ORDER BY ID" '[2.5]'
# THE REFUSAL IS ABOUT THE ROUNDING, so a bound the key HOLDS EXACTLY
# still answers through every router - and so does every NARROW column,
# whose key is a DOUBLE key and never rounds.  These are the controls
# that keep the refusal from quietly growing into "a router refuses".
both             "11E CONTROL an integral bind through the router: derived X.BI > (?) over TI [2] (engine 3;9)" "SELECT X.ID FROM (SELECT ID, BI FROM TI) X WHERE X.BI > (?) ORDER BY X.ID" '[2]'
desc_differs     "11E CONTROL derived X.ID > (?) over TI [2.5] - INTEGER is a DOUBLE key and the VALUE agrees; the slot is announced Nullable where the engine says NOT NULL, the SAME pre-existing derived-wrap gap section 5 records (engine 3;9)" "SELECT X.ID FROM (SELECT ID FROM TI) X WHERE X.ID > (?) ORDER BY X.ID" '[2.5]'
both             "11E CONTROL derived X.NM > (?) over TI [2.495] - NUMERIC(9,2), LONG-backed (engine 1;2;9)" "SELECT X.ID FROM (SELECT ID, NM FROM TI) X WHERE X.NM > (?) ORDER BY X.ID" '[2.495]'
both             "11E CONTROL view VI.N41 > (?) [2.45] - NUMERIC(4,1), SHORT-backed (engine 2;9)" "SELECT ID FROM VI WHERE N41 > (?) ORDER BY ID" '[2.45]'
both             "11E CONTROL JOIN A.SM > (?) [2.5] over the INDEXED twin (engine 3;9)" "SELECT A.ID FROM TI A JOIN TI B ON A.ID = B.ID WHERE A.SM > (?) ORDER BY A.ID" '[2.5]'
both             "11E CONTROL a CTE over the HEAP on a NARROW column: Q.ID > (?) [2.5] (engine 3;9)" "WITH Q AS (SELECT ID FROM T) SELECT ID FROM Q WHERE ID > (?) ORDER BY ID" '[2.5]'
# ...and the KNOWN paths - a single-table retrieval, an UPDATE and a
# DELETE all call `with_keys`, so the precise rule still holds there and
# round 13 must not have touched them.
both             "11E CONTROL the KNOWN path, heap: T.BI > (?) [2.5] (engine 3;9)" "SELECT ID FROM T WHERE BI > (?) ORDER BY ID" '[2.5]'
eng_only         "11E PIN the KNOWN path, indexed: TI.BI > (?) [2.5] refuses (engine 9)" "SELECT ID FROM TI WHERE BI > (?) ORDER BY ID" '[2.5]'
dml_rb           "11E CONTROL the KNOWN path, UPDATE: U SET N = 77 WHERE BI > (?) [2.5] (engine dml=(none) rb=1,1;2,2;3,77)" "UPDATE U SET N = 77 WHERE BI > (?)" '[2.5]' "SELECT ID, N FROM U ORDER BY ID"

echo "-- 12. MERGE IS A DIFFERENT ROUTER, and its CONDITION never saw this law --"
# COUNT THE ROUTERS.  MERGE DESUGARS its ON predicate and its WHEN MATCHED
# AND condition into the TEXT of a per-row UPDATE / DELETE, so the `?` is
# gone before the predicate is planned and the double's reading goes with
# it - the value is spelled as a decimal literal, which an INT64-backed
# key compares EXACTLY.  Found by the round-13 refuter, measured
# 2026-09-20: FOUR ROW-MUTATING WRONG ANSWERS on the indexed target, every
# one of them wrong on /tmp/fcwire-prev-0e5a8f4 too, while the plain
# `UPDATE .. WHERE BI > ?` twin already refused.
#
# The condition now refuses a double the key's scale cannot hold, and that
# costs NOTHING against its own sibling: the plain DML twin refuses this
# bind on the HEAP as well (measured), because a bare `?` marks
# `ColKind::WideExact` from the column's WIDTH alone.
dml_rb_eng_only  "12 MERGE INTO MBI ON T.BI > ? [2.5] DELETE - the engine's indexed bound rounds to 3 and matches NOTHING; this server used to DELETE row 3 (engine dml=(none) rb=1,100;2,200;3,300)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.BI > ? WHEN MATCHED THEN DELETE" '[2.5]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb_eng_only  "12 MERGE INTO MBI ON T.BI > ? [2.5] UPDATE - the UPDATE arm of the same hole (engine dml=(none) rb=1,100;2,200;3,300)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.BI > ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.5]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb_eng_only  "12 MERGE INTO MBI ON 1=1 WHEN MATCHED AND T.BI > ? [2.5] - the WHEN MATCHED AND clause is a SECOND router (engine dml=(none) rb=1,100;2,200;3,300)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON 1=1 WHEN MATCHED AND T.BI > ? THEN UPDATE SET N = 999" '[2.5]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb_eng_only  "12 MERGE INTO MBI USING MBH S ON T.ID = S.ID AND T.BI > ? [2.5] - the MULTI-ROW source form, a THIRD spelling (engine dml=(none) rb=1,100;2,200;3,300)" "MERGE INTO MBI T USING MBH S ON T.ID = S.ID AND T.BI > ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.5]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb_eng_only  "12 MERGE INTO TI ON T.H2 > ? [2.495] - the scaled INT128 key NUMERIC(38,2) rounds 2.495 to 2.50 (engine dml=(none) rb=-3,4;0,1;1,1;2,2;3,3;9,7)" "MERGE INTO TI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.H2 > ? WHEN MATCHED THEN UPDATE SET NN = 7" '[2.495]' "SELECT ID AS A, NN AS B FROM TI ORDER BY ID"
dml_rb_eng_only  "12 COST MERGE INTO MBH ON T.BI > ? [2.5] over the HEAP - right before round 13 and refused now; its plain-UPDATE twin refuses this bind on the heap too (engine dml=(none) rb=1,100;2,200;3,999)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.BI > ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
# ...and the CONTROLS: everything MERGE already did right must still work.
dml_rb           "12 CONTROL MERGE INTO MBI ON T.BI > ? [2] - an INTEGER message is untouched (engine dml=(none) rb=1,100;2,200;3,999)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.BI > ? WHEN MATCHED THEN UPDATE SET N = 999" '[2]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb           "12 CONTROL MERGE INTO MBI ON T.BI > ? [2.0] - an INTEGRAL double: the key holds it exactly (engine dml=(none) rb=1,100;2,200;3,999)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.BI > ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.0]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb           "12 CONTROL MERGE INTO MBI ON T.SM > ? [2.5] - a SHORT-backed key is a DOUBLE key (engine dml=(none) rb=1,100;2,200;3,999)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.SM > ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.5]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb           "12 CONTROL MERGE INTO MBI ON T.NM > ? [2.495] - NUMERIC(9,2), LONG-backed (engine dml=(none) rb=1,100;2,999;3,300)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.NM > ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.495]' "SELECT ID AS A, N AS B FROM MBI ORDER BY ID"
dml_rb           "12 CONTROL MERGE INTO MBI SET NM = ? [7.245] - the STORE arm keeps its own law, eps and all (engine dml=(none) rb=1,1.00;2,7.25;3,2.49)" "MERGE INTO MBI T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.ID = ? WHEN MATCHED THEN UPDATE SET NM = ?" '[2, 7.245]' "SELECT ID AS A, CAST(NM AS VARCHAR(20)) AS B FROM MBI ORDER BY ID"
dml_rb           "12 CONTROL MERGE INTO MBH WHEN NOT MATCHED THEN INSERT .. VALUES (?) [7.245] - the INSERT arm is a VALUE position, not a condition (engine dml=(none) rb=1,1.00;2,2.50;3,2.49;99,7.25)" "MERGE INTO MBH T USING (SELECT 99 AS X FROM RDB\$DATABASE) S ON T.ID = S.X WHEN NOT MATCHED THEN INSERT (ID, N, NM) VALUES (99, 5, ?)" '[7.245]' "SELECT ID AS A, CAST(NM AS VARCHAR(20)) AS B FROM MBH ORDER BY ID"

echo "-- 13. A NUMERIC FUNCTION'S '?' IS A DOUBLE SLOT, NOT THE DESTINATION'S --"
# Measured on the engine's own input SQLDA 2026-09-20: the `?` argument
# of ABS, SIGN, ROUND, ROUND(?,n), TRUNC, TRUNC(?,n), FLOOR, CEIL and
# CEILING is announced `sqltype 480 DOUBLE len 8` - THE DESTINATION PLAYS
# NO PART, exactly as it plays none in a CONDITION.  This server passed
# the destination down instead, so the value CONVERTED BEFORE THE
# FUNCTION READ IT and the fraction the function exists to inspect was
# already gone.
#
# IT BYPASSED CONSTRAINTS - the worst shape this chunk turned up, and the
# first two cells are exactly that: a row COMMITTED where the engine has
# none.  Every cell here was wrong on /tmp/fcwire-prev-0e5a8f4 too, so
# none is a regression; the rule simply never existed.
dml_rb_both_err  "13 INSERT INTO CKD (ID, N) VALUES (5, FLOOR(?)) [3.5] - the engine's FLOOR(3.5) = 3 fires CHECK (N <> 3); this server rounded to 4 first and COMMITTED THE ROW" "INSERT INTO CKD (ID, N) VALUES (5, FLOOR(?))" '[3.5]' "SELECT ID AS A, N AS B FROM CKD ORDER BY ID"
dml_rb_both_err  "13 INSERT INTO CKD (ID, N) VALUES (5, TRUNC(?)) [3.9] - the TRUNC spelling of the same bypass" "INSERT INTO CKD (ID, N) VALUES (5, TRUNC(?))" '[3.9]' "SELECT ID AS A, N AS B FROM CKD ORDER BY ID"
dml_rb_both_err  "13 INSERT INTO U (ID, N) VALUES (FLOOR(?), 5) [3.5] - FLOOR(3.5) = 3 collides with the PRIMARY KEY; this server inserted a new key 4" "INSERT INTO U (ID, N) VALUES (FLOOR(?), 5)" '[3.5]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb_both_err  "13 INSERT INTO U (ID, N) VALUES (TRUNC(?), 5) [3.9] - the TRUNC spelling" "INSERT INTO U (ID, N) VALUES (TRUNC(?), 5)" '[3.9]' "SELECT ID AS A, N AS B FROM U ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET N = FLOOR(?) [2.5] -> 2, not 3" "UPDATE W SET N = FLOOR(?) WHERE ID = 1" '[2.5]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET N = TRUNC(?) [2.9] -> 2, not 3" "UPDATE W SET N = TRUNC(?) WHERE ID = 1" '[2.9]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET N = CEIL(?) [2.1] -> 3, not 2 (this one errs the OTHER way)" "UPDATE W SET N = CEIL(?) WHERE ID = 1" '[2.1]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET N = CEILING(?) [2.1] -> 3 - the long spelling is the same function" "UPDATE W SET N = CEILING(?) WHERE ID = 1" '[2.1]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET N = SIGN(?) [0.4] -> 1, not 0 - A SIGN FLIPPED TO ZERO" "UPDATE W SET N = SIGN(?) WHERE ID = 1" '[0.4]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET BI = SIGN(?) [-0.4] -> -1, not 0 - the mirror" "UPDATE W SET BI = SIGN(?) WHERE ID = 1" '[-0.4]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET N = ROUND(?, 1) [2.45] -> 3 (ROUND(2.45,1) = 2.5), not 2" "UPDATE W SET N = ROUND(?, 1) WHERE ID = 1" '[2.45]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET SM = FLOOR(?) [2.5] -> 2 - SMALLINT" "UPDATE W SET SM = FLOOR(?) WHERE ID = 1" '[2.5]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 UPDATE W SET N = ABS(?) [2.5] -> 3 - ABS is the one whose VALUE cannot split (rounding commutes with it), so it pins the DESCRIBE half alone" "UPDATE W SET N = ABS(?) WHERE ID = 1" '[2.5]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 INSERT INTO TRD (ID, N) VALUES (5, SIGN(?)) [0.4] - the wrong value used to travel through a BEFORE trigger and a COMPUTED column: three columns from one bind" "INSERT INTO TRD (ID, N) VALUES (5, SIGN(?))" '[0.4]' "SELECT ID AS A, N AS B, C AS D, SEEN AS E FROM TRD ORDER BY ID"
# THE SCALED DESTINATIONS WERE ALREADY RIGHT BY LUCK - rounding 2.5 into
# NUMERIC(9,2) is 2.50 and FLOOR sees the same fraction - and they stay
# right, because the function now reads the double and its RESULT meets
# the destination's store law afterwards.  These are floor cells.
dml_rb_desc_differs "13 FLOOR UPDATE W SET NM = FLOOR(?) [2.5] - NUMERIC(9,2)" "UPDATE W SET NM = FLOOR(?) WHERE ID = 1" '[2.5]' "SELECT ID AS A, CAST(NM AS VARCHAR(30)) AS B, CAST(N18 AS VARCHAR(30)) AS C, CAST(N41 AS VARCHAR(30)) AS D, CAST(H2 AS VARCHAR(40)) AS E FROM W ORDER BY ID"
dml_rb_desc_differs "13 FLOOR UPDATE W SET N18 = TRUNC(?) [2.9] - NUMERIC(18,1)" "UPDATE W SET N18 = TRUNC(?) WHERE ID = 1" '[2.9]' "SELECT ID AS A, CAST(NM AS VARCHAR(30)) AS B, CAST(N18 AS VARCHAR(30)) AS C, CAST(N41 AS VARCHAR(30)) AS D, CAST(H2 AS VARCHAR(40)) AS E FROM W ORDER BY ID"
dml_rb_desc_differs "13 FLOOR UPDATE W SET N41 = FLOOR(?) [2.5] - NUMERIC(4,1)" "UPDATE W SET N41 = FLOOR(?) WHERE ID = 1" '[2.5]' "SELECT ID AS A, CAST(NM AS VARCHAR(30)) AS B, CAST(N18 AS VARCHAR(30)) AS C, CAST(N41 AS VARCHAR(30)) AS D, CAST(H2 AS VARCHAR(40)) AS E FROM W ORDER BY ID"
dml_rb_desc_differs "13 FLOOR UPDATE W SET NM = ROUND(?, 1) [2.45] - the scaled ROUND" "UPDATE W SET NM = ROUND(?, 1) WHERE ID = 1" '[2.45]' "SELECT ID AS A, CAST(NM AS VARCHAR(30)) AS B, CAST(N18 AS VARCHAR(30)) AS C, CAST(N41 AS VARCHAR(30)) AS D, CAST(H2 AS VARCHAR(40)) AS E FROM W ORDER BY ID"
dml_rb_desc_differs "13 FLOOR UPDATE W SET H2 = CEIL(?) [2.1] - NUMERIC(38,2): the INT128 CAP keeps this one on the destination's own slot and it is RIGHT there" "UPDATE W SET H2 = CEIL(?) WHERE ID = 1" '[2.1]' "SELECT ID AS A, CAST(NM AS VARCHAR(30)) AS B, CAST(N18 AS VARCHAR(30)) AS C, CAST(N41 AS VARCHAR(30)) AS D, CAST(H2 AS VARCHAR(40)) AS E FROM W ORDER BY ID"
# THE CAP, stated as a divergence rather than swapped for a regression:
# the DML store path refuses an APPROXIMATE source for an INT128 column
# at prepare, so typing this slot DOUBLE turned three cells the previous
# binary answered EXACTLY like the engine into refusals.  The INT128
# widths therefore keep the destination's slot, and the one wrong answer
# that leaves is pinned here on both sides.
dml_divergence   "13 CAP UPDATE W SET H = CEIL(?) [2.1] - an INT128 destination still converts first" "UPDATE W SET H = CEIL(?) WHERE ID = 1" '[2.1]' "SELECT ID AS A, CAST(H AS VARCHAR(40)) AS B FROM W ORDER BY ID" "dml=(none) rb=1,3;2,2" "dml=(none) rb=1,2;2,2"
# ...and the CONTROLS: an INTEGER message and the plain store are
# untouched, which is what says the change is about the DOUBLE and not
# about the function.
dml_rb_desc_differs "13 CONTROL UPDATE W SET N = FLOOR(?) [2] - an integer message" "UPDATE W SET N = FLOOR(?) WHERE ID = 1" '[2]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 CONTROL UPDATE W SET N = SIGN(?) [2] - an integer message" "UPDATE W SET N = SIGN(?) WHERE ID = 1" '[2]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb_desc_differs "13 CONTROL UPDATE W SET N = ABS(?) [-2] - an integer message" "UPDATE W SET N = ABS(?) WHERE ID = 1" '[-2]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb           "13 CONTROL UPDATE W SET N = ? [2.5] - the PLAIN store still takes the destination's slot, eps law and all" "UPDATE W SET N = ? WHERE ID = 1" '[2.5]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"
dml_rb           "13 CONTROL UPDATE W SET N = ? * 2 [1.6] - the ARITHMETIC rung still converts at its slot FIRST (2 * 2 = 4)" "UPDATE W SET N = ? * 2 WHERE ID = 1" '[1.6]' "SELECT ID AS A, CAST(N AS VARCHAR(30)) AS B, CAST(SM AS VARCHAR(30)) AS C, CAST(BI AS VARCHAR(30)) AS D FROM W ORDER BY ID"

echo "-- 14. WHAT ROUND 13 MEASURED AND DID NOT FIX --"
# A HAVING TERM OVER A GROUP BY **KEY** IS INDEX-MATCHABLE, unlike one
# over an aggregate, and the engine's answer splits on it exactly as a
# plain WHERE does.  [resolve_having] declares its fold row key-free
# because an aggregate is never an index key (section 11E's floor cell
# depends on that), and that declaration is too coarse for a grouped KEY.
# Pinned on BOTH sides rather than left to be rediscovered: a wrong answer
# cannot be a green cell, and a cell that cannot say WHICH wrong answer is
# not a record of anything.  Identical on /tmp/fcwire-prev-0e5a8f4.
divergence       "14 GROUP BY ID, BI HAVING BI > (?) [2.5] over the INDEXED twin - the engine takes the index bound (9); this server takes the scan reading" "SELECT ID FROM TI GROUP BY ID, BI HAVING BI > (?) ORDER BY ID" '[2.5]' "9" "3;9"
divergence       "14 GROUP BY ID, N18 HAVING N18 > (?) [2.45] - the same at scale 1" "SELECT ID FROM TI GROUP BY ID, N18 HAVING N18 > (?) ORDER BY ID" '[2.45]' "9" "2;9"
dml_divergence   "14 INSERT INTO W (ID) SELECT ID FROM TI GROUP BY ID, BI HAVING BI > (?) [2.5] - the ROW-MUTATING spelling: this server inserts the extra row" "INSERT INTO W (ID) SELECT ID FROM TI GROUP BY ID, BI HAVING BI > (?)" '[2.5]' "SELECT ID AS A FROM W WHERE ID > 2 ORDER BY ID" "dml=(none) rb=9" "dml=(none) rb=3;9"
both             "14 CONTROL the HEAP twin of the same statement answers on both (engine 3;9)" "SELECT ID FROM T GROUP BY ID, BI HAVING BI > (?) ORDER BY ID" '[2.5]'
both             "14 CONTROL a NARROW group key is a DOUBLE key and never splits: GROUP BY ID, SM HAVING SM > (?) [2.5] (engine 3;9)" "SELECT ID FROM TI GROUP BY ID, SM HAVING SM > (?) ORDER BY ID" '[2.5]'
# ...and the one 11E cost the round-13 refuter found that section 11E did
# not gate: a SELECTABLE PROCEDURE'S OUTPUT STREAM HAS NO INDEX AT ALL, so
# the engine cannot split on it and the refusal here is pure over-refusal -
# recorded, not hidden.  Its INTEGER-output twin is a section-11A floor
# cell and still answers, which is what isolates the cause to the WIDTH.
eng_only         "11E COST a selectable procedure's BIGINT output: RA < (?) [2.5] - the stream has no index, so nothing can split; the router simply cannot say so (engine 2)" "SELECT RA FROM P2(2, 1) WHERE RA < (?)" '[2.5]'
both             "11E CONTROL the INTEGER-output twin still answers: P1(2, 1) RA < (?) [2.5] (engine 2)" "SELECT RA FROM P1(2, 1) WHERE RA < (?)" '[2.5]'

echo "-- 15. A PANIC THAT WORE A REFUSAL\'S CLOTHES, and the MERGE operator matrix --"
# AN UNNUMBERED SLOT IS `usize::MAX`, and `i + 1` WRAPPED TO 0 in a release
# build: `resize(0)` then `sink[usize::MAX]` PANICKED the connection
# thread, which reaches node as *Connection to Firebird server was lost* -
# i.e. as an ordinary query error, the same word as a refusal.  Measured
# 2026-09-20 on BOTH binaries; it now refuses at prepare.  `panic_free`
# below is what makes these cells mean anything: without it an ERR from a
# crash and an ERR from a refusal are the same string.
eng_only         "15 SUM(CAST(? AS INTEGER)) OVER () [2] - PANICKED the previous binary\'s connection thread; refuses here (engine -3,12;0,12;1,12;2,12;3,12;9,12)" "SELECT ID, SUM(CAST(? AS INTEGER)) OVER () S FROM T ORDER BY ID" '[2]'
eng_only         "15 SUM(CAST(? AS INTEGER)) OVER () [2.5] - the double bind of the same shape (engine -3,18;0,18;1,18;2,18;3,18;9,18)" "SELECT ID, SUM(CAST(? AS INTEGER)) OVER () S FROM T ORDER BY ID" '[2.5]'
eng_only         "15 COUNT(CAST(? AS INTEGER)) OVER () [2] (engine -3,6;0,6;1,6;2,6;3,6;9,6)" "SELECT ID, COUNT(CAST(? AS INTEGER)) OVER () S FROM T ORDER BY ID" '[2]'
eng_only         "15 MAX(CAST(? AS INTEGER)) OVER (ORDER BY ID) [2] (engine -3,2;0,2;1,2;2,2;3,2;9,2)" "SELECT ID, MAX(CAST(? AS INTEGER)) OVER (ORDER BY ID) S FROM T ORDER BY ID" '[2]'
both             "15 CONTROL SUM(ID) OVER () - the same window with no parameter (engine -3,12;0,12;1,12;2,12;3,12;9,12)" "SELECT ID, SUM(ID) OVER () S FROM T ORDER BY ID" '[]'
both             "15 CONTROL SUM(CAST(? AS INTEGER)) GROUPED - the non-window twin still answers (engine 1,4;2,2;3,2;4,2;9,2)" "SELECT NN, SUM(CAST(? AS INTEGER)) S FROM T GROUP BY NN ORDER BY NN" '[2]'
# THE MERGE MATRIX, measured across every operator on the HEAP target: the
# plain `UPDATE .. WHERE` twin ALREADY refuses each one, so section 12\'s
# guard makes the two routers agree rather than taking a capability the
# sibling router had.  Both halves are gated so the claim cannot rot.
dml_rb_eng_only  "15 MERGE MBH ON T.BI <> ? [2.5] refuses (engine dml=(none) rb=1,999;2,999;3,999)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.BI <> ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb_eng_only  "15 ...and its PLAIN TWIN refuses the same bind: UPDATE MBH SET N = 999 WHERE BI <> ? [2.5] (engine dml=(none) rb=1,999;2,999;3,999)" "UPDATE MBH SET N = 999 WHERE BI <> ?" '[2.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb_eng_only  "15 MERGE MBH ON T.BI = ? [2.5] refuses (engine dml=(none) rb=1,100;2,200;3,300)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.BI = ? WHEN MATCHED THEN UPDATE SET N = 999" '[2.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb_eng_only  "15 ...and its PLAIN TWIN: UPDATE MBH SET N = 999 WHERE BI = ? [2.5] (engine dml=(none) rb=1,100;2,200;3,300)" "UPDATE MBH SET N = 999 WHERE BI = ?" '[2.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"

echo "-- 16. A MERGE CONDITION THAT COMPUTES WITH ITS PARAMETER --"
# MERGE desugars its condition into TEXT (section 12), and the previous
# chunk\'s law says a `?` that is an OPERAND OF ARITHMETIC is CONVERTED AT
# ITS SLOT before the arithmetic runs, while a whole side is read as it
# arrived.  Spelling the operand as its raw value computes from the wrong
# number.  Measured 2026-09-20 and both ROW-MUTATING, both wrong on the
# previous binary too: `ON T.ID > ? + 0` [1.5] matched row 2 as well as
# row 3 where the engine rounds 1.5 to 2 and matches row 3 alone, and
# `ON T.ID = ? + 0` [2.5] matched NOTHING where the engine rounds to 3 and
# DELETES row 3 - **and then ran the NOT MATCHED branch and INSERTED a row
# the engine never inserts**, two divergences from one statement.
dml_rb_eng_only  "16 MERGE MBH USING U ON T.ID = S.ID AND T.ID > ? + 0 [1.5] - the engine rounds the operand to 2 (engine dml=(none) rb=1,100;2,200;3,999)" "MERGE INTO MBH T USING U S ON T.ID = S.ID AND T.ID > ? + 0 WHEN MATCHED THEN UPDATE SET N = 999" '[1.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb_eng_only  "16 MERGE MBH ON T.ID = ? + 0 WHEN MATCHED DELETE WHEN NOT MATCHED INSERT [2.5] - the engine deletes row 3; this server matched nothing and INSERTED (55,55) (engine dml=(none) rb=1,100;2,200)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.ID = ? + 0 WHEN MATCHED THEN DELETE WHEN NOT MATCHED THEN INSERT (ID, N) VALUES (55, 55)" '[2.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
# ...and the CONTROLS that say the refusal is about the CONVERSION and not
# about arithmetic, a condition, or MERGE.
dml_rb           "16 CONTROL MERGE MBH ON T.ID = ? + 0 [2] - an INTEGER message needs no conversion (engine dml=(none) rb=1,100;2,999;3,300)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.ID = ? + 0 WHEN MATCHED THEN UPDATE SET N = 999" '[2]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb           "16 CONTROL MERGE MBH ON T.ID = ? + 0 [2.0] - an INTEGRAL double the slot holds exactly (engine dml=(none) rb=1,100;2,999;3,300)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.ID = ? + 0 WHEN MATCHED THEN UPDATE SET N = 999" '[2.0]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb           "16 CONTROL MERGE MBH ON T.NM = ? + 0.00 [2.50] - a SCALE the slot holds (engine dml=(none) rb=1,100;2,999;3,300)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.NM = ? + 0.00 WHEN MATCHED THEN UPDATE SET N = 999" '[2.50]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb           "16 CONTROL MERGE MBH SET N = ? + 1 [2.5] - a VALUE position converts at its slot and is untouched (engine dml=(none) rb=1,4;2,200;3,300)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? + 1" '[2.5]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"
dml_rb           "16 CONTROL MERGE MBH ON T.ID = ? [1] - a BARE whole side with no arithmetic at all (engine dml=(none) rb=1,999;2,200;3,300)" "MERGE INTO MBH T USING (SELECT 1 AS X FROM RDB\$DATABASE) S ON T.ID = ? WHEN MATCHED THEN UPDATE SET N = 999" '[1]' "SELECT ID AS A, N AS B FROM MBH ORDER BY ID"

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
# THE FLOOR IS COUNTED FROM A MEASURED RUN, never typed. It catches what
# a pass/fail tally cannot: cells SILENTLY DISAPPEARING - an early
# `exit`, a helper renamed, a `node` that stopped resolving.
if [ "$ran" -lt 422 ]; then
    echo "FAIL only $ran checks ran; 422 were measured - cells went missing"; fail=1
fi
exit $fail

