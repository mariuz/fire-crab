#!/bin/bash
# A BOUND NaN AGAINST A TEXT COLUMN, AND THE ACCESS PATH THAT DECIDES IT.
#
# The engine converts the column's text to a number, and the NaN is the
# LESSER whichever side it is written on: `S > ?` and `? < S` [NaN] are
# TRUE, `S < ?` / `? > S` FALSE, `=` FALSE, `<>` TRUE.  But `>` / `>=`
# SPLIT on the access path - on a heap SCAN they are TRUE for every
# convertible row, and through an INDEX on S the range stops below the
# NaN key and they are FALSE.  This server kept the indexed reading
# everywhere, so on a column with no index `UPDATE .. WHERE S > ?` [NaN]
# changed every row on the engine and NONE here (roadmap item (c)).
#
# Now `>` / `>=` take the heap answer where NO index LEADS with the
# column - read straight from the index root page, so an index this
# server cannot otherwise read still counts (unindexed_fids) - and keep
# the indexed reading wherever an index could be ranged.  The compound
# index `(T, S)` is the discriminating case: S is not its leading
# segment, so the engine scans and every row is TRUE.
#
# Rows go in through SQL; the NaN comes in as a bound parameter, spelled
# "#NaN" in the JSON and revived to a real NaN in the driver.
#
# Usage: qa/serve-real-nantext.sh [port]   (default 4563)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4563}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nantext-eng.fdb"; FC="$D/nantext-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P';"
  cat <<'SQL'
CREATE TABLE SV (ID INTEGER, S VARCHAR(20), D DOUBLE PRECISION);
CREATE TABLE SI (ID INTEGER, S VARCHAR(20), D DOUBLE PRECISION);
CREATE INDEX SI_S ON SI (S);
CREATE TABLE SC (ID INTEGER, S VARCHAR(20), T VARCHAR(20));
CREATE INDEX SC_TS ON SC (T, S);
CREATE TABLE CKD (ID INTEGER, D DOUBLE PRECISION CHECK (D < 100));
COMMIT;
INSERT INTO SV VALUES (1, '1.5', 1.5);
INSERT INTO SV VALUES (2, '-7', -7);
INSERT INTO SV VALUES (3, '1e10', 3);
INSERT INTO SI SELECT * FROM SV;
INSERT INTO SC SELECT ID, S, S FROM SV;
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/nantext-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/nantext-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/nantext-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-nantext-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
RV='const rv=v=>v==="#NaN"?NaN:v==="#Inf"?Infinity:v==="#-Inf"?-Infinity:v;'
# the statement, then a READ-BACK, in one transaction that is ROLLED BACK
qrb() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_RB="$5" timeout 25 node -e "$RV"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":v).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P).map(rv),(e2,r1)=>{
        const d=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("ok "+fmt(r1));
        tr.query(process.env.FC_RB,[],(e3,r)=>{tr.rollback(()=>{console.log(d+" | rb="+(e3?"ERR":fmt(r)));db.detach();process.exit(0);});});
      });
    });
  });' 2>/dev/null; }
RB0="SELECT 1 FROM RDB\$DATABASE"
# both sides answer, and identically - an empty or CONN_ERR engine side is
# a cell that measured nothing, not an agreement
both() { # <label> <sql> <json> [read-back]
    ran=$((ran + 1))
    local rb="${4:-$RB0}" ev fv
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$rb"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$rb")
    if [ -z "$ev" ] || [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then echo "FAIL $1 [the cell never ran: eng=$ev]"; fail=1
    elif [ "${ev#ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE raised [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
both_err() { # <label> <sql> <json> <read-back> - BOTH raise, the SAME text, the same rows left
    ran=$((ran + 1))
    local ev fv
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$4"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$4")
    if [ "${ev#ERR}" = "$ev" ]; then echo "FAIL $1 - the ENGINE no longer raises [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
eng_only() { # the engine answers, this server refuses - recorded
    ran=$((ran + 1))
    local ev fv
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$RB0"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$RB0")
    if [ "${ev#ok}" = "$ev" ]; then echo "FAIL $1 - the ENGINE no longer answers [$ev]"; fail=1
    elif [ "${fv#ERR Dynamic SQL Error}" = "$fv" ]; then echo "FAIL $1 - this server moved [$fv]; promote if it matches [$ev]"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
N='["#NaN"]'

echo "--- 1 NO index on S: the engine SCANS, and the NaN is the LESSER whichever side it is written on"
for op in ">" ">=" "<" "<=" "=" "<>"; do
    both "1 SV: S $op ?"   "SELECT ID FROM SV WHERE S $op ? ORDER BY ID" "$N"
    both "1 SV: ? $op S"   "SELECT ID FROM SV WHERE ? $op S ORDER BY ID" "$N"
done
both "1 SV: S BETWEEN ? AND '9'"  "SELECT ID FROM SV WHERE S BETWEEN ? AND '9' ORDER BY ID" "$N"
both "1 SV: S || '' > ? - the expression path (agreed before)" "SELECT ID FROM SV WHERE S || '' > ? ORDER BY ID" "$N"

echo "--- 2 an index LEADS with S: the engine RANGES, and > / >= stop below the NaN"
for op in ">" ">=" "<" "<>"; do
    both "2 SI: S $op ?"   "SELECT ID FROM SI WHERE S $op ? ORDER BY ID" "$N"
done
both "2 SI: ? < S"         "SELECT ID FROM SI WHERE ? < S ORDER BY ID" "$N"

echo "--- 3 S is the SECOND segment of (T, S): no index leads with it, so the engine scans"
for op in ">" ">=" "<" "<>"; do
    both "3 SC: S $op ?"   "SELECT ID FROM SC WHERE S $op ? ORDER BY ID" "$N"
done

echo "--- 4 DML follows each path (rolled back, read back)"
both "4 UPDATE SV .. WHERE S > ? - every row (was NONE here)"  "UPDATE SV SET D = 0 WHERE S > ?" "$N" "SELECT ID, D FROM SV ORDER BY ID"
both "4 DELETE FROM SV WHERE S >= ? - every row"                "DELETE FROM SV WHERE S >= ?" "$N" "SELECT ID FROM SV ORDER BY ID"
both "4 UPDATE SI .. WHERE S > ? - no row (the indexed half)"   "UPDATE SI SET D = 0 WHERE S > ?" "$N" "SELECT ID, D FROM SI ORDER BY ID"
both "4 UPDATE SC .. WHERE S > ? - every row (second segment)"  "UPDATE SC SET T = 'x' WHERE S > ?" "$N" "SELECT ID, T FROM SC ORDER BY ID"

echo "--- 5 neighbours re-measured 2026-10-03 (roadmap items (c) and (d), both already right)"
both "5 a CHECK (D < 100) STORES a NaN"       "INSERT INTO CKD (ID, D) VALUES (1, ?)" "$N" "SELECT ID, D FROM CKD"
both_err "5 ..and raises for +Infinity"       "INSERT INTO CKD (ID, D) VALUES (1, ?)" '["#Inf"]' "SELECT ID, D FROM CKD"
both "5 a stored NaN's text is 'nan'"         "UPDATE SV SET S = CAST(? AS VARCHAR(20)) WHERE ID = 1" "$N" "SELECT ID, S FROM SV ORDER BY ID"
both "5 ..+Infinity's is 'inf'"               "UPDATE SV SET S = CAST(? AS VARCHAR(20)) WHERE ID = 1" '["#Inf"]' "SELECT ID, S FROM SV ORDER BY ID"
both "5 ..-Infinity's is '-inf'"              "UPDATE SV SET S = CAST(? AS VARCHAR(20)) WHERE ID = 1" '["#-Inf"]' "SELECT ID, S FROM SV ORDER BY ID"
both "5 CONTROL a finite bind: S > ? [2.5]"   "SELECT ID FROM SV WHERE S > ? ORDER BY ID" '[2.5]'

echo "--- 6 RECORDED: the shapes this server still refuses"
eng_only "6 IIF(S > ?, 1, 0) [NaN]"                 "SELECT ID, IIF(S > ?, 1, 0) FROM SV ORDER BY ID" "$N"
eng_only "6 S > CAST(? AS DOUBLE PRECISION) [NaN]"  "SELECT ID FROM SV WHERE S > CAST(? AS DOUBLE PRECISION) ORDER BY ID" "$N"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-nantext-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 36 on the 2026-10-03 binary, 36 OK
if [ "$ran" -lt 36 ]; then echo "FAIL only $ran checks ran (floor 36) - cells went missing"; fail=1; fi
exit $fail
