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
# A FOLD (section 7): a global aggregate or a GROUP BY whose WHERE calls
# filters lazily as above and then folds; a call inside an aggregate's
# argument or a GROUP BY key runs per kept row, lazily over the whole
# argument (`SUM(IIF(ID = 2, 0, FZ(ID)))` never runs FZ(2)), and the fold
# reads each row's values back - so its tie order (a LIST's, read off the
# fields the statement references, a WHERE-only one included) and its
# grouping order are the plain fold's; a call over an aggregate or a key
# in HAVING, the ORDER BY or the select list runs over the folded row.
# The lone-aggregate fast path stands aside for a calling WHERE: over an
# EMPTY table its prepare-time probe "succeeded" and left a plan that
# could not run the call.
#
# UPDATE / DELETE (section 8): a WHERE that calls only PURE functions
# (judged from their source: no relation read or write, no SQL, no
# generator, context or event, and their callees the same) runs its calls
# in a PRE-PASS over the target walk's own candidates - the same index
# range, written order - and the walk that writes reads each record's
# values by its (page, slot); an UPDATE's SET values that call run there
# too, for the rows the WHERE keeps (a `?` argument typed by the function's
# declared input), RETURNING over it too, and a pure call IN the RETURNING
# list (UPDATE, DELETE, INSERT) runs per returned row after the write. An
# impure call refuses (8b): the engine's calls see the statement's own
# earlier writes (`DELETE FROM T WHERE ID < FC()`, FC counting T, deletes
# one row of three), which no pre-pass reproduces.
#
# THE MEMO (section 9): a PURE call in any other shape - a derived table,
# a join, a UNION branch, an IN / EXISTS / scalar subquery, correlated or
# not - runs the plan through its ordinary row machinery with every call
# answered from a memo keyed by (function, argument values); a pass that
# reaches an unanswered call records it, the calls run (a raise is kept,
# and surfaces only if the final pass reaches it), the plan runs again -
# each pass a fresh execution, so no subquery cache keeps a placeholder's
# answer (one did: the first build answered a scalar subquery NULL). An
# impure call there refuses (9b). A condition over a derived source or a
# CTE and a join's ON are routers of their own; each lexes calls too.
#
# A window over a NAVIGATED key, and ROWS ?, refuse - recorded (section 6).
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
CREATE TABLE G (ID INTEGER, K VARCHAR(5), C CHAR(3), N NUMERIC(9,2));
CREATE SEQUENCE GS;
COMMIT;
INSERT INTO G VALUES (5, 'zz', 'b', 2.25);
INSERT INTO G VALUES (1, 'a', 'b', 1.10);
INSERT INTO G VALUES (7, 'zz', 'a', NULL);
INSERT INTO G VALUES (2, 'M', 'a', 3.00);
INSERT INTO G VALUES (4, 'a', 'c', -1.50);
INSERT INTO G VALUES (3, 'zz', 'c', 0.75);
INSERT INTO G VALUES (6, NULL, 'b', 2.00);
INSERT INTO G VALUES (8, 'M', NULL, 9.99);
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
CREATE FUNCTION FC RETURNS INTEGER AS BEGIN RETURN (SELECT COUNT(*) FROM T); END^
CREATE FUNCTION FN (X INTEGER) RETURNS INTEGER AS BEGIN IF (X IS NULL) THEN RETURN -1; RETURN F1(X) + 1; END^
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
  // a BLOB value (a LIST) arrives as a reader: read it in the SAME
  // transaction, before the rollback, as its text
  const rd=(tr,v)=>new Promise(res=>{if(typeof v!=="function")return res(v);
    v(tr,(e,n,em)=>{if(e)return res("BLOBERR");const b=[];em.on("data",c=>b.push(c));em.on("end",()=>res(Buffer.concat(b).toString()));});});
  // (a singleton INSERT .. RETURNING row arrives as an object, not a list)
  const fmt=async(tr,r)=>{if(r&&!Array.isArray(r))r=[r];if(!r||!r.length)return "(none)";const o=[];
    for(const x of r){const vs=[];for(const v0 of Object.values(x)){const v=await rd(tr,v0);vs.push(v===null?"NULL":(v instanceof Date?v.toISOString():v));}o.push(vs.join());}
    return o.join(";");};
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P),async(e2,r1)=>{
        const d=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("ok "+await fmt(tr,r1));
        tr.query(process.env.FC_RB,[],async(e3,r)=>{const rb=e3?"ERR":await fmt(tr,r);tr.rollback(()=>{console.log(d+" | rb="+rb);db.detach();process.exit(0);});});
      });
    });
  });' 2>/dev/null; }
# the input describe, through isql (it prints the INPUT message for a
# statement it cannot then bind)
# (rolled back: isql EXECUTES the statement it describes, and a DML cell
# would otherwise commit its write into every later cell's table)
dsc() { printf 'SET SQLDA_DISPLAY ON;\nSET TERM ^;\n%s^\nROLLBACK^\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }
RB0="SELECT 1 FROM RDB\$DATABASE"
both() { # <label> <sql> <json> [read-back]
    ran=$((ran + 1))
    local rb="${4:-$RB0}" ev fv ed fd
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$rb"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ] || [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then echo "FAIL $1 [the cell never ran: eng=$ev]"; fail=1
    # (a DML with no parameter has no describe line at all)
    elif [ -z "$ed" ] && [ "${2%% *}" = SELECT ]; then echo "FAIL $1 [the ENGINE printed no describe]"; fail=1
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
both     "6 a call inside an IN subquery - PROMOTED (the memo)"     "SELECT ID FROM T WHERE ID IN (SELECT ID FROM T WHERE F1(ID) > 3) ORDER BY ID" '[]'
both     "6 a call inside a correlated EXISTS - PROMOTED (the memo)" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T T2 WHERE F1(T2.ID) = T.ID * 2 AND T2.ID > 1) ORDER BY ID" '[]'
both     "6 a derived table - PROMOTED (the memo)"                  "SELECT ID FROM (SELECT ID FROM T WHERE F1(ID) > 3) ORDER BY ID" '[]'
both     "6 a join - PROMOTED (the memo)"                           "SELECT T.ID FROM T JOIN TI ON TI.ID = T.ID WHERE F1(T.ID) > 3 ORDER BY 1" '[]'
both     "6 a UNION branch - PROMOTED (the memo)"                   "SELECT ID FROM T WHERE F1(ID) > 3 UNION ALL SELECT 9 $R" '[]'
eng_only "6 ROWS ? - a bound window"          "SELECT ID FROM T WHERE F1(ID) > ? ROWS ?" '[1, 1]'
eng_only "6 FIRST over a NAVIGATED key"       "SELECT FIRST 1 ID FROM TI WHERE ID > 2 AND FZ(ID) > 0 ORDER BY ID" '[]'

echo "--- 7 a FOLD: a call in the WHERE, an aggregate's argument, a key, HAVING,"
echo "      the ORDER BY and the select list over the folded rows"
both "7 COUNT(*) F1>3" "SELECT COUNT(*) FROM T WHERE F1(ID) > 3" '[]'
both "7 SUM/MIN/MAX" "SELECT SUM(ID), MIN(V), MAX(N), COUNT(N) FROM T WHERE F1(ID) > 2" '[]'
both "7 COUNT ? " "SELECT COUNT(*) FROM T WHERE F1(ID) > ?" '[3]'
both "7 COUNT order raise" "SELECT COUNT(*) FROM T WHERE FZ(ID) > 0 AND ID <> 2" '[]'
both "7 COUNT order ok" "SELECT COUNT(*) FROM T WHERE ID <> 2 AND FZ(ID) > 0" '[]'
both "7 COUNT empty" "SELECT COUNT(*) FROM E WHERE FZ(2) > 0" '[]'
both "7 COUNT keyed" "SELECT COUNT(*) FROM TI WHERE FZ(ID) > 0 AND ID = 1" '[]'
both "7 GROUP BY" "SELECT ID FROM T WHERE F1(ID) > 3 GROUP BY ID" '[]'
both "7 GROUP BY V count" "SELECT V, COUNT(*) FROM T WHERE F1(ID) >= 2 GROUP BY V ORDER BY V DESC" '[]'
both "7 HAVING" "SELECT V, COUNT(*) FROM T WHERE F1(ID) >= 2 GROUP BY V HAVING COUNT(*) > 0 ORDER BY 1" '[]'
both "7 SUM(F1)" "SELECT SUM(F1(ID)) FROM T" '[]'
both "7 GROUP BY F1" "SELECT F1(ID), COUNT(*) FROM T GROUP BY F1(ID)" '[]'
both "7 HAVING F" "SELECT V FROM T GROUP BY V HAVING F1(COUNT(*)) = 2" '[]'
both "7 agg raise in arg" "SELECT SUM(FZ(ID)) FROM T" '[]'
both "7 COUNT empty col" "SELECT COUNT(*) FROM E WHERE FZ(ID) > 0" '[]'
both "7 COUNT T const" "SELECT COUNT(*) FROM T WHERE F1(2) > 0" '[]'
both "7 COUNT T const raise" "SELECT COUNT(*) FROM T WHERE FZ(2) > 0" '[]'
both "7 MAX E const" "SELECT MAX(ID) FROM E WHERE FZ(2) > 0" '[]'
both "7 ID E const" "SELECT ID FROM E WHERE FZ(2) > 0" '[]'
both "7 G K no order" "SELECT K, COUNT(*), SUM(N) FROM G WHERE F1(ID) > 2 GROUP BY K" '[]'
both "7 G C no order" "SELECT C, MAX(ID), AVG(N) FROM G WHERE F1(ID) <> 6 GROUP BY C" '[]'
both "7 G two keys" "SELECT C, K, COUNT(*) FROM G WHERE F1(ID) > 0 GROUP BY C, K" '[]'
both "7 G LIST ties" "SELECT LIST(K) FROM G WHERE F1(ID) > 2 AND C <> 'q'" '[]'
both "7 G LIST group" "SELECT C, LIST(ID) FROM G WHERE F1(ID) > 0 GROUP BY C" '[]'
both "7 G COUNT DISTINCT" "SELECT COUNT(DISTINCT K), COUNT(K), MIN(K) FROM G WHERE F1(ID) > 3" '[]'
both "7 G having order" "SELECT K, SUM(ID) FROM G WHERE F1(ID) > 0 GROUP BY K HAVING SUM(ID) > 3 ORDER BY 2 DESC" '[]'
both "7 G FIRST" "SELECT FIRST 2 K, COUNT(*) FROM G WHERE F1(ID) > 0 GROUP BY K ORDER BY K" '[]'
both "7 G SKIP" "SELECT SKIP 1 K FROM G WHERE F1(ID) > 0 GROUP BY K" '[]'
both "7 G DISTINCT" "SELECT DISTINCT COUNT(*) FROM G WHERE F1(ID) > 0 GROUP BY C" '[]'
both "7 G raise" "SELECT K, COUNT(*) FROM G WHERE FZ(ID) > 0 AND ID <> 2 GROUP BY K" '[]'
both "7 G raise avoided" "SELECT K, COUNT(*) FROM G WHERE ID <> 2 AND FZ(ID) > -100 GROUP BY K ORDER BY 1" '[]'
both "7 G having ?" "SELECT K, COUNT(*) FROM G WHERE F1(ID) > ? GROUP BY K HAVING COUNT(*) > ? ORDER BY 1" '[4, 1]'
both "7 G expr key" "SELECT ID / 3, COUNT(*) FROM G WHERE F1(ID) > 2 GROUP BY ID / 3" '[]'
both "7 G F2 text" "SELECT C, COUNT(*) FROM G WHERE F2(K, ID) STARTING WITH 'zz' GROUP BY C" '[]'
both "7 G empty fold" "SELECT COUNT(*), SUM(N), LIST(K) FROM G WHERE F1(ID) > 100" '[]'
both "7 G empty group" "SELECT K, COUNT(*) FROM G WHERE F1(ID) > 100 GROUP BY K" '[]'
both "7 G no-fn control" "SELECT K, COUNT(*), SUM(N) FROM G WHERE ID > 1 GROUP BY K" '[]'
both "7 G COUNT DISTINCT" "SELECT COUNT(DISTINCT K) AS A, COUNT(K) AS B, MIN(K) AS M2 FROM G WHERE F1(ID) > 3" '[]'
both "7 G ? in proj" "SELECT K, COUNT(*) + CAST(? AS INTEGER) FROM G WHERE F1(ID) > ? GROUP BY K ORDER BY 1" '[10, 4]'
both "7 G LIST where-field ties" "SELECT LIST(C, '|') FROM G WHERE F1(ID) > 0 AND N > -5" '[]'
both "7 G LIST ctl" "SELECT LIST(K) FROM G WHERE ID > 2 AND C <> 'q'" '[]'
both "7 G LIST distinct" "SELECT C, LIST(DISTINCT K) FROM G WHERE F1(ID) > 1 GROUP BY C" '[]'
both "7 agg IIF lazy" "SELECT SUM(IIF(ID = 2, 0, FZ(ID))) FROM T" '[]'
both "7 COUNT(F) nulls" "SELECT COUNT(F1(N)) AS A, COUNT(*) AS B FROM T" '[]'
both "7 GROUP BY F2 key" "SELECT F2(C, 1), COUNT(*) FROM G GROUP BY F2(C, 1)" '[]'
both "7 G SUM F1 by K" "SELECT K, SUM(F1(ID)) FROM G GROUP BY K" '[]'
both "7 G MAX F2" "SELECT C, MAX(F2(K, ID)) FROM G GROUP BY C" '[]'
both "7 G LIST F2" "SELECT C, LIST(F2(K, ID)) FROM G WHERE ID > 1 GROUP BY C" '[]'
both "7 G LIST F2 global" "SELECT LIST(F2(K, ID), '/') FROM G WHERE F1(ID) > 4" '[]'
both "7 G HAVING F sum" "SELECT K, SUM(ID) FROM G GROUP BY K HAVING F1(SUM(ID)) > 12 ORDER BY 1" '[]'
both "7 G proj F over agg" "SELECT K, F1(COUNT(*)) FROM G GROUP BY K ORDER BY 1" '[]'
both "7 G proj F over key" "SELECT C, F2(C, COUNT(*)) FROM G GROUP BY C" '[]'
both "7 G order F" "SELECT K, COUNT(*) FROM G GROUP BY K ORDER BY F1(COUNT(*)) DESC, 1" '[]'
both "7 G HAVING raise" "SELECT K FROM G GROUP BY K HAVING FZ(COUNT(*)) > 0" '[]'
both "7 G proj raise" "SELECT K, FZ(COUNT(*)) FROM G GROUP BY K" '[]'
both "7 G expr key F" "SELECT F1(ID) / 4, COUNT(*) FROM G GROUP BY F1(ID) / 4" '[]'
both "7 G key raise" "SELECT FZ(ID), COUNT(*) FROM G GROUP BY FZ(ID)" '[]'
both "7 G avg F1 N" "SELECT C, AVG(F1(N)) FROM G GROUP BY C" '[]'
both "7 G ? in arg" "SELECT SUM(F1(ID) + CAST(? AS INTEGER)) FROM G" '[100]'
both "7 G call ? arg" "SELECT SUM(F1(?)) FROM G" '[3]'
both "7 G HAVING key call" "SELECT C FROM G GROUP BY C HAVING F2(C, 1) <> 'b  -1'" '[]'
both "7 G HAVING call ?" "SELECT K FROM G GROUP BY K HAVING F1(COUNT(*)) > ?" '[3]'
both "7 G HAVING order lazy" "SELECT K FROM G GROUP BY K HAVING COUNT(*) > 2 OR FZ(COUNT(*)) > 0" '[]'
both "7 G HAVING order raise" "SELECT K FROM G GROUP BY K HAVING FZ(COUNT(*)) > 0 OR COUNT(*) > 2" '[]'

echo "--- 8 UPDATE / DELETE whose WHERE calls a PURE function: a pre-pass, then the writes"
# (DML refused at prepare until 2026-10-03.) Each cell runs and reads back
# in one rolled-back transaction.
RT="SELECT ID, V FROM T ORDER BY ID"
both "8 UPDATE .. WHERE F1(ID) > 3"                 "UPDATE T SET V = 'x' WHERE F1(ID) > 3" '[]' "$RT"
both "8 UPDATE .. WHERE F1(ID) > ? - a bound ?"     "UPDATE T SET V = 'x' WHERE F1(ID) > ?" '[3]' "$RT"
both "8 DELETE .. WHERE F1(ID) = 4"                 "DELETE FROM T WHERE F1(ID) = 4" '[]' "$RT"
both "8 written order: ID <> 2 AND FZ(ID) > 0"      "DELETE FROM T WHERE ID <> 2 AND FZ(ID) > 0" '[]' "$RT"
both "8 written order: FZ(ID) > 0 AND ID <> 2 raises" "DELETE FROM T WHERE FZ(ID) > 0 AND ID <> 2" '[]' "$RT"
both "8 an OR, a NULL argument"                     "DELETE FROM T WHERE FN(N) = -1 OR F1(ID) = 2" '[]' "$RT"
both "8 a pure function calling a pure one"         "UPDATE T SET N = 0 WHERE FN(ID) = 5" '[]' "SELECT ID, N FROM T ORDER BY ID"
both "8 the index range bounds the calls"           "DELETE FROM TI WHERE FZ(ID) > 0 AND ID = 1" '[]' "SELECT ID FROM TI ORDER BY ID"
both "8 a text call"                                "UPDATE T SET V = 'y' WHERE F2(V, ID) = 'b-2'" '[]' "$RT"
both "8 nothing matches"                            "DELETE FROM T WHERE F1(ID) > 100" '[]' "$RT"
both "8 SET V = F2(V, ID) - a call in the SET list" "UPDATE T SET V = F2(V, ID) WHERE ID = 2" '[]' "$RT"
both "8 SET ID = F1(ID) WHERE F1(ID) < 5 - both"    "UPDATE T SET ID = F1(ID) WHERE F1(ID) < 5" '[]' "$RT"
both "8 SET N = FZ(ID) raises at row 2"            "UPDATE T SET N = FZ(ID)" '[]' "SELECT ID, N FROM T ORDER BY ID"
both "8 SET under IIF never runs FZ(2)"            "UPDATE T SET N = IIF(ID = 2, 0, FZ(ID))" '[]' "SELECT ID, N FROM T ORDER BY ID"
both "8 SET simultaneous: both read the old row"   "UPDATE T SET N = F1(ID), V = F2(V, ID) WHERE ID <> 2" '[]' "SELECT ID, V, N FROM T ORDER BY ID"
# a `?` argument takes the function's declared input type, as in a SELECT
# (refused at prepare until 2026-10-03, recorded in 8b)
both "8 SET with a bound ? argument"               "UPDATE T SET V = F2(V, ?) WHERE ID = ?" '[7, 1]' "$RT"
both "8 SET F1(?) + ID - arithmetic over the call" "UPDATE T SET N = F1(?) + ID WHERE ID < 3" '[5]' "SELECT ID, N FROM T ORDER BY ID"
both "8 SET F2(?, ?) - both arguments bound"       "UPDATE T SET V = F2(?, ?) WHERE ID = 3" '["q", 9]' "$RT"
# RETURNING over a DML whose WHERE / SET calls: the rows the pre-passed
# walk touched (refused until 2026-10-03, recorded in 8b)
both "8 UPDATE .. WHERE F1(ID) = 2 RETURNING ID, V" "UPDATE T SET V = 'q' WHERE F1(ID) = 2 RETURNING ID, V" '[]' "$RT"
both "8 SET call RETURNING OLD.V, NEW.V"           "UPDATE T SET V = F2(V, ID) WHERE ID = 3 RETURNING OLD.V AS O, NEW.V AS NV" '[]' "$RT"
both "8 DELETE .. WHERE F1(ID) = 4 RETURNING ID"    "DELETE FROM T WHERE F1(ID) = 4 RETURNING ID, N" '[]' "$RT"
# a call IN the RETURNING list: run per returned row, after the write (a
# raise undoes the write) - the cursor form and INSERT's singleton form
both "8 RETURNING F1(ID)"                          "UPDATE T SET V = 'r' WHERE ID = 1 RETURNING F1(ID)" '[]' "$RT"
both "8 RETURNING a lazy IIF over FZ"              "UPDATE T SET V = 'w' RETURNING ID, IIF(ID = 2, 0, FZ(ID))" '[]' "$RT"
both "8 RETURNING FZ(2) raises, the write undone"  "UPDATE T SET V = 'w' WHERE ID = 2 RETURNING FZ(ID)" '[]' "$RT"
both "8 INSERT .. VALUES RETURNING calls (singleton)" "INSERT INTO T (ID, V) VALUES (7, 'g') RETURNING F1(ID), F2(V, ID)" '[]' "$RT"
both "8 INSERT .. VALUES RETURNING FZ(2) raises"   "INSERT INTO T (ID, V) VALUES (2, 'k') RETURNING FZ(ID)" '[]' "$RT"
both "8 INSERT .. SELECT RETURNING F1"             "INSERT INTO T (ID, V) SELECT ID + 10, V FROM T RETURNING F1(ID)" '[]' "$RT"
both "8 CONTROL - a DML with no call"               "UPDATE T SET V = 'z' WHERE ID = 3" '[]' "$RT"
both "8 CONTROL - a SELECT after the DML lexed a call" "SELECT ID FROM T WHERE ID = 1" '[]'
echo "--- 8b RECORDED - an IMPURE function: the engine's calls see the statement's own writes"
# `DELETE FROM T WHERE ID < FC()`, FC counting T: the engine deletes ONE
# row of three (the count falls as rows go); a pre-pass cannot reproduce it
eng_only "8b DELETE .. WHERE ID < FC() - FC reads the target" "DELETE FROM T WHERE ID < FC()" '[]'
eng_only "8b an IMPURE call in a RETURNING list"     "UPDATE T SET N = 1 WHERE ID = 1 RETURNING FC()" '[]'

echo "--- 9 THE MEMO: a PURE call in any other shape - derived tables, joins,"
echo "      UNION branches, subqueries - answered from (function, arguments)"
both "9 derived: a call in the select list"         "SELECT D.ID FROM (SELECT ID, F1(ID) AS X FROM T) D WHERE D.X > 3 ORDER BY 1" '[]'
both "9 derived: written order, the raise avoided"  "SELECT D.ID FROM (SELECT ID FROM T WHERE ID <> 2 AND FZ(ID) > 0) D" '[]'
both "9 derived: written order, the raise"          "SELECT D.ID FROM (SELECT ID FROM T WHERE FZ(ID) > 0 AND ID <> 2) D" '[]'
both "9 join: a call over the joined side"          "SELECT T.ID, F1(TI.ID) FROM T JOIN TI ON TI.ID = T.ID ORDER BY 1" '[]'
both "9 join: a text call in the WHERE"             "SELECT T.ID FROM T JOIN TI ON TI.ID = T.ID WHERE F2(T.V, TI.ID) = 'b-2'" '[]'
both "9 UNION: calls in both branches"              "SELECT F1(ID) FROM T UNION SELECT F1(ID) + 1 FROM TI ORDER BY 1" '[]'
both "9 UNION ALL: a NULL argument"                 "SELECT F1(N) FROM T UNION ALL SELECT 0 $R" '[]'
both "9 a scalar subquery over a fold"              "SELECT ID, (SELECT F1(MAX(ID)) FROM T) AS M FROM T ORDER BY 1" '[]'
both "9 a correlated scalar subquery"               "SELECT ID, (SELECT MAX(B.ID) FROM T B WHERE F1(B.ID) < A.ID * 3) AS M FROM T A ORDER BY 1" '[]'
both "9 IN: written-order raise inside"             "SELECT ID FROM T WHERE ID IN (SELECT ID FROM T WHERE FZ(ID) > 0 AND ID <> 2)" '[]'
both "9 IN: the raise avoided inside"               "SELECT ID FROM T WHERE ID IN (SELECT ID FROM T WHERE ID <> 2 AND FZ(ID) > 0)" '[]'
both "9 a lazy IIF in a derived select list"        "SELECT D.R FROM (SELECT IIF(ID = 2, 0, FZ(ID)) AS R FROM T) D ORDER BY 1" '[]'
both "9 a nested call in a join"                    "SELECT T.ID, FN(T.ID) FROM T JOIN TI ON TI.ID = T.ID WHERE FN(TI.ID) > 4 ORDER BY 1" '[]'
both "9 a bound ? argument in a derived table"      "SELECT D.ID FROM (SELECT ID FROM T WHERE F1(ID) > ?) D ORDER BY 1" '[3]'
# the routers of their own (recorded in 9b until 2026-10-03): a condition
# over a derived source or a CTE, and a join's ON
both "9 the WHERE over a derived table"             "SELECT D.ID FROM (SELECT ID FROM T) D WHERE F1(D.ID) > 2 ORDER BY 1" '[]'
both "9 ...written order there, the raise"          "SELECT D.ID FROM (SELECT ID FROM T) D WHERE FZ(D.ID) > 0 AND D.ID <> 2" '[]'
both "9 the WHERE over a CTE"                       "WITH C AS (SELECT ID FROM T) SELECT ID FROM C WHERE F1(ID) > 2 ORDER BY 1" '[]'
both "9 HAVING over a derived table"                "SELECT V, COUNT(*) FROM (SELECT ID, V FROM T) D GROUP BY V HAVING F1(COUNT(*)) = 2 ORDER BY 1" '[]'
both "9 a call in a LEFT JOIN's ON"                 "SELECT T.ID, TI.ID FROM T LEFT JOIN TI ON F1(TI.ID) = T.ID ORDER BY 1, 2" '[]'
both "9 an inner join's ON beside a key"            "SELECT T.ID, TI.ID FROM T JOIN TI ON TI.ID = T.ID AND F1(TI.ID) > 2 ORDER BY 1" '[]'
both "9 a LEFT JOIN's ON, written order"            "SELECT T.ID, TI.ID FROM T LEFT JOIN TI ON TI.ID = T.ID AND TI.ID <> 2 AND FZ(TI.ID) > 0 ORDER BY 1" '[]'
both "9 a RIGHT JOIN's ON"                          "SELECT T.ID, TI.ID FROM T RIGHT JOIN TI ON F1(T.ID) = TI.ID ORDER BY 2" '[]'
echo "--- 9b RECORDED"
# an IMPURE call outside the per-row runners' shapes refuses at prepare -
# the memo answers a call once per argument list, a reading function's
# answer may move between rows
eng_only "9b an impure call in a derived table"     "SELECT D.ID FROM (SELECT ID FROM T WHERE ID < FC()) D" '[]'

echo "--- 10 a GENERATOR column beside a call: drawn per delivered row, before the select list"
# (a generator is not transactional: every cell's draws - and its describe
# run's - persist, identically on both twins, so the read-back shows them)
RG="SELECT GEN_ID(GS, 0) FROM RDB\$DATABASE"
both "10 GEN_ID(GS, 0) beside F1(1)"               "SELECT GEN_ID(GS, 0) AS G, F1(1) AS F $R" '[]' "$RG"
both "10 GEN_ID(GS, 1) per row beside F1(ID)"      "SELECT ID, GEN_ID(GS, 1) AS G, F1(ID) AS F FROM T ORDER BY ID" '[]' "$RG"
both "10 NEXT VALUE FOR beside a WHERE call"       "SELECT ID, NEXT VALUE FOR GS AS G FROM T WHERE F1(ID) > 3 ORDER BY ID" '[]' "$RG"
both "10 the raise avoided: draws for kept rows"   "SELECT ID, GEN_ID(GS, 1) AS G FROM T WHERE ID <> 2 AND FZ(ID) > 0" '[]' "$RG"
both "10 the WHERE raises: no draw delivered"      "SELECT ID, GEN_ID(GS, 1) AS G FROM T WHERE FZ(ID) > 0 AND ID <> 2" '[]' "$RG"
eng_only "10 RECORDED - a generator inside a call's argument" "SELECT ID, F1(GEN_ID(GS, 1)) AS G FROM T ORDER BY ID" '[]'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-fnwhere-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 204 on the 2026-10-03 binary, 204 OK
if [ "$ran" -lt 204 ]; then echo "FAIL only $ran checks ran (floor 204) - cells went missing"; fail=1; fi
exit $fail
