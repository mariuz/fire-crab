#!/bin/bash
# A STORED FUNCTION CALLED IN A WHERE - and in an ORDER BY, and under
# FIRST / SKIP / ROWS.
#
# Every `WHERE F(..)` refused at prepare: the WHERE tokenizer lexed a call
# into one expression token for BUILT-IN names only, so `F1(` read as a
# column and the predicate did not parse.  Under a client SELECT's prepare
# the OUTERMOST table projection's WHERE now lexes a stored call too, and
# the per-row runner evaluates the filter LAZILY: a call runs when the
# conjunct walk reaches it and never otherwise.  Measured on 2182 and
# pinned below:
#
#  - WRITTEN ORDER decides which calls run: `ID <> 2 AND FZ(ID) > 0` is
#    [3] where FZ(2) divides by zero; `FZ(ID) > 0 AND ID <> 2` raises.
#  - A CALL IS NEVER AN INVARIANT: `WHERE FZ(2) > 0` over an EMPTY table
#    answers no row and no raise (where `1/0 = 1` raises before the scan);
#    `1 = 0 AND FZ(2) > 0` and `FZ(2) > 0 AND 1 = 0` answer no row.
#  - THE INDEX RANGE bounds the calls: `TI WHERE FZ(ID) > 0 AND ID = 1`
#    over a keyed ID answers no row - FZ(2) is never reached; the same
#    with `ID = ?` and `ID BETWEEN 1 AND 1`.  fcopt reads no call, so the
#    gate text swaps each call conjunct for an unindexable `<col> <> 0` -
#    which the engine weighs identically (SORT NATURAL under ORDER BY ID
#    alone, SORT INDEX beside `ID > 0`) - where DROPPING it navigated.
#  - A SORT KEY over a call is computed per kept row, and FIRST / SKIP /
#    ROWS cut the window before the select list runs (after the unique
#    sort under DISTINCT, which projects every kept row); an unsorted window
#    stops the scan (`FIRST 1 .. WHERE FZ(ID) < 0` answers [1]).
#
# A call inside a subquery, a derived table, a view, a join, an
# aggregate, GROUP BY or UNION, and a window over a NAVIGATED
# key, refuse at prepare - recorded (section 6).  So does DML: only a
# client SELECT arms the tokenizer.
#
# Usage: qa/serve-real-fnwhere.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4586}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/fnwhere-eng.fdb"; FC="$D/fnwhere-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P';"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, V VARCHAR(20), N NUMERIC(9,2));
CREATE TABLE E (ID INTEGER);
CREATE TABLE TI (ID INTEGER PRIMARY KEY);
COMMIT;
INSERT INTO T VALUES (1, 'a', 1.50);
INSERT INTO T VALUES (2, 'b', 10);
INSERT INTO T VALUES (3, 'c', NULL);
INSERT INTO TI VALUES (1);
INSERT INTO TI VALUES (2);
INSERT INTO TI VALUES (3);
COMMIT;
SET TERM ^;
CREATE FUNCTION F1 (X INTEGER) RETURNS INTEGER AS BEGIN RETURN X * 2; END^
CREATE FUNCTION F2 (S VARCHAR(10), K INTEGER) RETURNS VARCHAR(30) AS BEGIN RETURN S || '-' || K; END^
CREATE FUNCTION FZ (X INTEGER) RETURNS INTEGER AS BEGIN RETURN 6 / (X - 2); END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/fnwhere-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/fnwhere-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/fnwhere-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-fnwhere-$PORT.log" 2>&1 & srv=$!
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

echo "--- 1 a stored function in a WHERE answers"
both "1 F1(ID) > 3"                           "SELECT ID FROM T WHERE F1(ID) > 3 ORDER BY ID" '[]'
both "1 F1(ID) > ? - the ? typed by the call's INTEGER result" "SELECT ID FROM T WHERE F1(ID) > ? ORDER BY ID" '[3]'
both "1 F1(ID) = 4 - two columns"             "SELECT ID, V FROM T WHERE F1(ID) = 4" '[]'
both "1 ID > 1 AND F1(ID) < 6"                "SELECT ID FROM T WHERE ID > 1 AND F1(ID) < 6 ORDER BY ID" '[]'
both "1 F1(ID) < 6 OR ID = 3"                 "SELECT ID FROM T WHERE F1(ID) < 6 OR ID = 3 ORDER BY ID" '[]'
both "1 F2(V, ID) = 'b-2' - text, and a describe under NONE" "SELECT ID FROM T WHERE F2(V, ID) = 'b-2'" '[]'
both "1 F1(N) IS NULL - a NULL argument"      "SELECT ID FROM T WHERE F1(N) IS NULL" '[]'
both "1 F1(N) > 2 - NUMERIC into INTEGER"     "SELECT ID FROM T WHERE F1(N) > 2 ORDER BY ID" '[]'
both "1 F1(ID) in the list AND the WHERE"     "SELECT F1(ID) FROM T WHERE F1(ID) > 3 ORDER BY ID" '[]'
both "1 F1(?) = 4 - a ? argument in a WHERE"  "SELECT ID FROM T WHERE F1(?) = 4 ORDER BY ID" '[2]'
both "1 BETWEEN"                              "SELECT ID FROM T WHERE F1(ID) BETWEEN 3 AND 5" '[]'
both "1 IN list"                              "SELECT ID FROM T WHERE F1(ID) IN (2, 6) ORDER BY ID" '[]'
both "1 F1(F1(ID)) - a nested call"           "SELECT ID FROM T WHERE F1(F1(ID)) > 5 ORDER BY ID" '[]'
both "1 ID = F1(1) - a call on the right"     "SELECT ID FROM T WHERE ID = F1(1)" '[]'
both "1 ID = F1(1) over a keyed column"       "SELECT ID FROM TI WHERE ID = F1(1)" '[]'

echo "--- 2 written order; a call is never an invariant"
both "2 FZ(ID) > 0 - row 2 divides by zero"   "SELECT ID FROM T WHERE FZ(ID) > 0 ORDER BY ID" '[]'
both "2 ID <> 2 AND FZ(ID) > 0 - never reached" "SELECT ID FROM T WHERE ID <> 2 AND FZ(ID) > 0 ORDER BY ID" '[]'
both "2 FZ(ID) > 0 AND ID <> 2 - reached first" "SELECT ID FROM T WHERE FZ(ID) > 0 AND ID <> 2 ORDER BY ID" '[]'
both "2 ID = 2 OR FZ(ID) > 0 - the OR stops"  "SELECT ID FROM T WHERE ID = 2 OR FZ(ID) > 0 ORDER BY ID" '[]'
both "2 FZ(ID) > 0 OR ID = 2"                 "SELECT ID FROM T WHERE FZ(ID) > 0 OR ID = 2 ORDER BY ID" '[]'
both "2 NOT (FZ(ID) <= 0)"                    "SELECT ID FROM T WHERE NOT (FZ(ID) <= 0) ORDER BY ID" '[]'
both "2 FZ(2) > 0 over an EMPTY table - no raise" "SELECT ID FROM E WHERE FZ(2) > 0" '[]'
both "2 FZ(2) > 0 AND 1 = 0"                  "SELECT ID FROM T WHERE FZ(2) > 0 AND 1 = 0" '[]'
both "2 1 = 0 AND FZ(2) > 0"                  "SELECT ID FROM T WHERE 1 = 0 AND FZ(2) > 0" '[]'
both "2 ID = 9 AND FZ(2) > 0 - no row reaches it" "SELECT ID FROM T WHERE ID = 9 AND FZ(2) > 0" '[]'
both "2 ID = NULL AND FZ(2) > 0 - UNKNOWN walks on" "SELECT ID FROM T WHERE ID = NULL AND FZ(2) > 0" '[]'

echo "--- 3 the index range bounds the calls"
both "3 FZ(ID) > 0 AND ID = 1"                "SELECT ID FROM TI WHERE FZ(ID) > 0 AND ID = 1" '[]'
both "3 ID = 1 AND FZ(ID) > 0"                "SELECT ID FROM TI WHERE ID = 1 AND FZ(ID) > 0" '[]'
both "3 ID = 2 AND FZ(ID) > 0 - in range, raises" "SELECT ID FROM TI WHERE ID = 2 AND FZ(ID) > 0" '[]'
both "3 FZ(ID) > 0 AND ID < 2"                "SELECT ID FROM TI WHERE FZ(ID) > 0 AND ID < 2" '[]'
both "3 FZ(ID) > 0 AND ID = ? - a ?-keyed band" "SELECT ID FROM TI WHERE FZ(ID) > 0 AND ID = ?" '[1]'
both "3 FZ(ID) <> 0 AND ID BETWEEN 1 AND 1"   "SELECT ID FROM TI WHERE FZ(ID) <> 0 AND ID BETWEEN 1 AND 1" '[]'
both "3 FZ(ID) > 0 AND ID = 1 AND FZ(ID) < 0" "SELECT ID FROM TI WHERE FZ(ID) > 0 AND ID = 1 AND FZ(ID) < 0" '[]'
both "3 FZ(ID) < 0 OR ID = 1 - an OR keeps the scan" "SELECT ID FROM TI WHERE FZ(ID) < 0 OR ID = 1" '[]'
both "3 ID > 2 AND FZ(ID) > 0 ORDER BY ID"    "SELECT ID FROM TI WHERE ID > 2 AND FZ(ID) > 0 ORDER BY ID" '[]'
both "3 ID > 0 AND FZ(ID) <> 0 ORDER BY ID - SORT INDEX" "SELECT ID FROM TI WHERE ID > 0 AND FZ(ID) <> 0 ORDER BY ID" '[]'
both "3 FIRST 1 .. FZ(ID) < 0 ORDER BY ID - SORT NATURAL, every row" "SELECT FIRST 1 ID FROM TI WHERE FZ(ID) < 0 ORDER BY ID" '[]'

echo "--- 4 ORDER BY over a call; FIRST / SKIP / ROWS"
both "4 ORDER BY F1(ID) DESC"                 "SELECT ID FROM T ORDER BY F1(ID) DESC" '[]'
both "4 ORDER BY 2 DESC - the call's item"    "SELECT ID, F1(ID) FROM T ORDER BY 2 DESC" '[]'
both "4 WHERE and ORDER BY 2 over the call"   "SELECT ID, F1(ID) FROM T WHERE F1(ID) > 2 ORDER BY 2 DESC" '[]'
both "4 WHERE F1, ORDER BY F1(ID) DESC"       "SELECT ID FROM T WHERE F1(ID) > 3 ORDER BY F1(ID) DESC" '[]'
both "4 ORDER BY F2(V, ID) DESC NULLS FIRST"  "SELECT ID FROM T ORDER BY F2(V, ID) DESC NULLS FIRST" '[]'
both "4 ORDER BY F1(N) NULLS FIRST, ID DESC"  "SELECT ID FROM T ORDER BY F1(N) NULLS FIRST, ID DESC" '[]'
both "4 ORDER BY FZ(ID) - every row's key"    "SELECT ID FROM T ORDER BY FZ(ID)" '[]'
both "4 WHERE ID <> 2 ORDER BY FZ(ID) DESC - kept rows' keys only" "SELECT ID FROM T WHERE ID <> 2 ORDER BY FZ(ID) DESC" '[]'
both "4 WHERE F1, ORDER BY V DESC"            "SELECT ID FROM T WHERE F1(ID) > 3 ORDER BY V DESC" '[]'
both "4 FIRST 1 F1(ID)"                       "SELECT FIRST 1 F1(ID) FROM T" '[]'
both "4 FIRST 1 .. WHERE F1 ORDER BY ID DESC" "SELECT FIRST 1 ID FROM T WHERE F1(ID) > 1 ORDER BY ID DESC" '[]'
both "4 FIRST 1 .. WHERE FZ(ID) < 0 - the scan stops" "SELECT FIRST 1 ID FROM T WHERE FZ(ID) < 0" '[]'
both "4 FIRST 1 SKIP 1 .. FZ(ID) <> 0 - reaches row 2" "SELECT FIRST 1 SKIP 1 ID FROM T WHERE FZ(ID) <> 0" '[]'
both "4 FIRST 2 ID, FZ(ID) ORDER BY ID DESC - the list on delivered rows" "SELECT FIRST 2 ID, FZ(ID) FROM T ORDER BY ID DESC" '[]'
both "4 FIRST 1 ID, FZ(ID)"                   "SELECT FIRST 1 ID, FZ(ID) FROM T" '[]'
both "4 FIRST 0 - no row, no call"            "SELECT FIRST 0 ID FROM T WHERE FZ(ID) > 0" '[]'
both "4 ROWS 1"                               "SELECT ID FROM T WHERE F1(ID) > 3 ROWS 1" '[]'
both "4 OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY" "SELECT ID FROM T WHERE F1(ID) > 1 OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY" '[]'
both "4 FIRST 1 / 2 .. TI WHERE FZ(ID) <> 0 - unsorted" "SELECT FIRST 2 ID FROM TI WHERE FZ(ID) <> 0" '[]'

echo "--- 4b DISTINCT: every kept row's list runs, then the unique sort, then the window"
both "4b DISTINCT V .. WHERE F1(ID) > 3"       "SELECT DISTINCT V FROM T WHERE F1(ID) > 3" '[]'
both "4b DISTINCT F1(ID) / 4"                  "SELECT DISTINCT F1(ID) / 4 FROM T" '[]'
both "4b DISTINCT .. ORDER BY 1 DESC"          "SELECT DISTINCT F1(ID) / 4 FROM T ORDER BY 1 DESC" '[]'
both "4b DISTINCT FZ(ID) - raises"             "SELECT DISTINCT FZ(ID) FROM T" '[]'
both "4b DISTINCT .. ID <> 2 AND FZ(ID) <> 0"  "SELECT DISTINCT ID FROM T WHERE ID <> 2 AND FZ(ID) <> 0" '[]'
both "4b FIRST 1 DISTINCT F1(ID) / 4"          "SELECT FIRST 1 DISTINCT F1(ID) / 4 FROM T" '[]'
both "4b FIRST 1 DISTINCT .. FZ(ID) < 0 - DISTINCT does not stop the scan" "SELECT FIRST 1 DISTINCT ID FROM T WHERE FZ(ID) < 0" '[]'
both "4b DISTINCT F2(V, 1)"                    "SELECT DISTINCT F2(V, 1) FROM T" '[]'
both "4b DISTINCT F1(N) - a NULL among them"   "SELECT DISTINCT F1(N) FROM T" '[]'
both "4b DISTINCT 1 .. WHERE F1(ID) > 1"       "SELECT DISTINCT 1 FROM T WHERE F1(ID) > 1" '[]'
both "4b DISTINCT two items, a ?"              "SELECT DISTINCT F1(ID) / 4, V FROM T WHERE F1(ID) > ?" '[1]'

echo "--- 5 CONTROLS: a select-list condition still parses as it did"
# the first build lexed a call in EVERY condition of a select prepare, and
# an IIF's condition then refused under a NONE attachment (the isql
# describe below) where the previous binary answered - caught on it
both "5 CONTROL IIF(F2(V, ID) = 'b-2', 1, 0)" "SELECT ID, IIF(F2(V, ID) = 'b-2', 1, 0) FROM T ORDER BY ID" '[]'
both "5 CONTROL IIF(F2(V, ID) = V, 1, 0)"     "SELECT ID, IIF(F2(V, ID) = V, 1, 0) FROM T ORDER BY ID" '[]'
both "5 CONTROL CASE WHEN F1(ID) > 3"         "SELECT ID, CASE WHEN F1(ID) > 3 THEN 'y' ELSE 'n' END FROM T ORDER BY ID" '[]'
both "5 CONTROL a built-in in a WHERE"        "SELECT ID FROM T WHERE UPPER(V) = 'B'" '[]'
both "5 CONTROL a keyed WHERE"                "SELECT ID FROM TI WHERE ID = 2" '[]'

echo "--- 6 RECORDED - the engine answers, this server refuses at prepare"
eng_only "6 COUNT(*) .. WHERE F1(ID) > 3"     "SELECT COUNT(*) FROM T WHERE F1(ID) > 3" '[]'
eng_only "6 GROUP BY"                         "SELECT ID FROM T WHERE F1(ID) > 3 GROUP BY ID" '[]'
eng_only "6 a call inside an IN subquery"     "SELECT ID FROM T WHERE ID IN (SELECT ID FROM T WHERE F1(ID) > 3) ORDER BY ID" '[]'
eng_only "6 a call inside a correlated EXISTS" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T T2 WHERE F1(T2.ID) = T.ID * 2 AND T2.ID > 1) ORDER BY ID" '[]'
eng_only "6 a derived table"                  "SELECT ID FROM (SELECT ID FROM T WHERE F1(ID) > 3) ORDER BY ID" '[]'
eng_only "6 a join"                           "SELECT T.ID FROM T JOIN TI ON TI.ID = T.ID WHERE F1(T.ID) > 3 ORDER BY 1" '[]'
eng_only "6 a UNION branch"                   "SELECT ID FROM T WHERE F1(ID) > 3 UNION ALL SELECT 9 $R" '[]'
eng_only "6 ROWS ? - a bound window"          "SELECT ID FROM T WHERE F1(ID) > ? ROWS ?" '[1, 1]'
eng_only "6 FIRST over a NAVIGATED key"       "SELECT FIRST 1 ID FROM TI WHERE ID > 2 AND FZ(ID) > 0 ORDER BY ID" '[]'
eng_only "6 UPDATE .. WHERE F1(ID) > 3 - DML is not armed" "UPDATE T SET V = V WHERE F1(ID) > 3" '[]'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-fnwhere-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 83 on the 2026-10-03 binary, 83 OK
if [ "$ran" -lt 83 ]; then echo "FAIL only $ran checks ran (floor 83) - cells went missing"; fail=1; fi
exit $fail
