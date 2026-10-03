#!/bin/bash
# A STORED FUNCTION CALLED WITH A `?`, AND A PARAMETER DECLARED NOT NULL.
#
# 1. `SELECT F1(?)` refused: a `?` inside a stored function's argument list
#    was INVISIBLE to the parameter walkers (raw_has_param and
#    renumber_raw_params had no UserFn arm), so the call never numbered it
#    and took the sink-less resolver.  A bare `?` argument is now typed as
#    the parameter's DECLARED type - measured: F1(?) over X INTEGER is
#    LONG, F2(?, ?) is VARYING(10) then LONG, F3(?) over a NOT NULL
#    NUMERIC(9,2) is LONG scale -2 subtype 1 WITHOUT Nullable - and the
#    bound value is substituted before the call runs per row.
#
# 2. PRE-EXISTING, and a wrong answer: a routine parameter declared NOT
#    NULL was never enforced.  `SELECT F3(NULL)` answered NULL and `SELECT
#    F3(N) FROM T` delivered a call over a NULL row, where the engine raises
#    `Validation error for variable "N", value "*** null ***"` with the
#    routine's frame `At function "PUBLIC"."F3"`.  The catalog's
#    RDB$NULL_FLAG now rides on the parameter's descriptor; the call
#    refuses a NULL there, as the argument enters the frame.
#
# Usage: qa/serve-real-fnparam.sh [port]   (default 4583)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4583}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/fnparam-eng.fdb"; FC="$D/fnparam-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P';"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, V VARCHAR(20), N NUMERIC(9,2));
COMMIT;
INSERT INTO T VALUES (1, 'a', 1.50);
INSERT INTO T VALUES (2, 'b', 10);
INSERT INTO T VALUES (3, 'c', NULL);
COMMIT;
SET TERM ^;
CREATE FUNCTION F1 (X INTEGER) RETURNS INTEGER AS BEGIN RETURN X * 2; END^
CREATE FUNCTION F2 (S VARCHAR(10), K INTEGER) RETURNS VARCHAR(30) AS BEGIN RETURN S || '-' || K; END^
CREATE FUNCTION F3 (N NUMERIC(9,2) NOT NULL, D DATE = CURRENT_DATE) RETURNS NUMERIC(18,2) AS BEGIN RETURN N * 3; END^
CREATE FUNCTION F4 (B BOOLEAN, S VARCHAR(5) = 'd') RETURNS VARCHAR(20) AS BEGIN RETURN IIF(B, S, 'no'); END^
CREATE PROCEDURE PN (X INTEGER NOT NULL, Y INTEGER) RETURNS (R INTEGER) AS BEGIN R = COALESCE(X, -1) + COALESCE(Y, 0); SUSPEND; END^
CREATE PROCEDURE PE (X INTEGER NOT NULL) AS BEGIN UPDATE T SET N = :X WHERE ID = 1; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/fnparam-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/fnparam-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/fnparam-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-fnparam-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
# the statement and a READ-BACK in ONE transaction that is ROLLED BACK, so
# a writing block leaves nothing for the next cell
qrb() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_RB="$5" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":(v instanceof Date?v.toISOString():v)).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r1)=>{
        const d=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("ok "+fmt(r1));
        tr.query(process.env.FC_RB,[],(e3,r)=>{tr.rollback(()=>{console.log(d+" | rb="+(e3?"ERR":fmt(r)));db.detach();process.exit(0);});});
      });
    });
  });' 2>/dev/null; }
# the input describe, through isql (it prints the INPUT message for a
# statement it cannot then bind)
dsc() { printf 'SET SQLDA_DISPLAY ON;\nSET TERM ^;\n%s^\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }
RB0="SELECT 1 FROM RDB\$DATABASE"
both() { # <label> <sql> <json> [read-back]
    ran=$((ran + 1))
    local rb="${4:-$RB0}" ev fv ed fd
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$rb"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ] || [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then echo "FAIL $1 [the cell never ran: eng=$ev]"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 [the ENGINE printed no describe]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1 (DESCRIBE)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
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
R="FROM RDB\$DATABASE"

echo "--- 1 a STORED FUNCTION's bare ? argument is its parameter's DECLARED type"
both "1 F1(?) over X INTEGER"                 "SELECT F1(?) $R" '[21]'
both "1 F2(?, ?) - VARCHAR(10) then INTEGER"  "SELECT F2(?, ?) $R" '["x",7]'
both "1 F2(?, 9) - a ? beside a literal"      "SELECT F2(?, 9) $R" '["y"]'
both "1 F3(?) over NUMERIC(9,2) NOT NULL - the slot is NOT NULL" "SELECT F3(?) $R" '["1.25"]'
both "1 F4(?) - BOOLEAN, the defaulted tail omitted" "SELECT F4(?) $R" '[true]'
both "1 F4(?, ?)"                             "SELECT F4(?, ?) $R" '[true,"zz"]'
both "1 F1(?) [NULL] - a nullable parameter"  "SELECT F1(?) $R" '[null]'
both "1 F1(?) ['12'] - text into INTEGER"     "SELECT F1(?) $R" '["12"]'
both "1 F1(?) ['abc'] - the conversion error" "SELECT F1(?) $R" '["abc"]'
both "1 F2(?, 1) - a VARCHAR(10) truncation"  "SELECT F2(?, 1) $R" '["abcdefghijklmn"]'
both "1 F1(?) per row, beside a column"       "SELECT ID, F1(?) AS A FROM T ORDER BY ID" '[5]'
both "1 F1(?) beside a WHERE ?"               "SELECT ID, F1(?) AS A FROM T WHERE ID > ? ORDER BY ID" '[5,1]'

echo "--- 2 a parameter declared NOT NULL REFUSES a NULL argument - literal, column or bound"
both "2 F3(NULL)"                              "SELECT F3(NULL) $R" '[]'
both "2 F3(CAST(NULL AS NUMERIC(9,2)))"        "SELECT F3(CAST(NULL AS NUMERIC(9,2))) $R" '[]'
both "2 F3(?) [NULL]"                          "SELECT F3(?) $R" '[null]'
both "2 F3(N) over a NULL row"                 "SELECT F3(N) AS A FROM T ORDER BY ID" '[]'
both "2 F3(N) where no row is NULL"            "SELECT F3(N) AS A FROM T WHERE N IS NOT NULL ORDER BY ID" '[]'
both "2 inside an EXECUTE BLOCK - both frames" "EXECUTE BLOCK RETURNS (R NUMERIC(18,2)) AS BEGIN R = F3(NULL); SUSPEND; END" '[]'
both "2 CONTROL a selectable procedure's NOT NULL input" "SELECT R FROM PN(NULL, 1)" '[]'
both "2 CONTROL ..its nullable input takes NULL"         "SELECT R FROM PN(1, NULL)" '[]'
both "2 CONTROL ..bound"                                 "SELECT R FROM PN(?, 1)" '[null]'
both "2 CONTROL EXECUTE PROCEDURE PE(?) [NULL]"          "EXECUTE PROCEDURE PE(?)" '[null]' "SELECT ID, N FROM T ORDER BY ID"

echo "--- 3 RECORDED"
eng_only "3 F1(F1(?)) - a ? under a nested call"   "SELECT F1(F1(?)) $R" '[3]'
eng_only "3 F1(? + 1) - a ? under arithmetic"      "SELECT F1(? + 1) $R" '[3]'
eng_only "3 a stored function in a WHERE at all"   "SELECT ID FROM T WHERE F1(ID) > 3 ORDER BY ID" '[]'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-fnparam-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 26 on the 2026-10-03 binary, 26 OK
if [ "$ran" -lt 26 ]; then echo "FAIL only $ran checks ran (floor 26) - cells went missing"; fail=1; fi
exit $fail
