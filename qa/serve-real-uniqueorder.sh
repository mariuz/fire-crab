#!/bin/bash
# UNIQUE/PK enforcement ORDER and the 23000 status vectors - the write
# path's own slice. Two probed laws drive it:
#
#   1. the engine enforces UNIQUE/PK row at a time DURING the write
#      walk, in RECORD-NUMBER order (not index order - probed with a
#      physically-reordered table, and with a forced index PLAN), each
#      row judged against a state where the statement's earlier rows
#      are already rewritten. `UPDATE W SET ID = ID + 1` on 5,6,7,8
#      refuses naming the FIRST colliding write's NEW key; the same
#      shift on physically DESCENDING rows succeeds entirely.
#   2. every constraint refusal ships a specific 23000 status vector
#      (unique-constraint vs bare-unique-index take different primary
#      codes; FK names the child's constraint both directions; NOT
#      NULL; CHECK with the trigger stack item) - with PRE-QUOTED args,
#      captured raw from the live wire.
#
# The differential is the engine, statement by statement: it creates
# two identical fixtures; fire-crab runs the matrix against one, the
# engine (wire server, port 3050) runs the IDENTICAL matrix on the
# other; verdicts AND raw status vectors (via a node full-status hook)
# must match. Durable state is re-read THROUGH THE ENGINE from the file
# fire-crab wrote, gfix -v -full validates it at the destructive
# points, and gbak round-trips it at the end.
#
#   qa/serve-real-uniqueorder.sh [port]
#
# Needs node (node-firebird on NODE_PATH) and the engine's own wire
# server listening on 3050 for the vector differential.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4773}"
ENGPORT="${ENGPORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-uo-work.fdb"; REF="$D/fc-uo-ref.fdb"
FBK="$D/fc-uo-work.fbk"; RST="$D/fc-uo-rst.fdb"
VJS="$D/fc-uo-vec.js"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
command -v nc >/dev/null 2>&1 && ! nc -z 127.0.0.1 "$ENGPORT" 2>/dev/null && {
    echo "SKIP engine wire server not reachable on port $ENGPORT (the vector differential needs it)"
    exit 0
}
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# --- the two identical fixtures, both created by the engine ------------
SCHEMA="CREATE TABLE W (ID INT NOT NULL PRIMARY KEY);
CREATE TABLE W2 (ID INT NOT NULL PRIMARY KEY);
CREATE TABLE S (ID INT NOT NULL PRIMARY KEY);
CREATE TABLE U (ID INT, CONSTRAINT U_UN UNIQUE (ID));
CREATE TABLE X (ID INT);
CREATE UNIQUE INDEX X_IDX ON X (ID);
CREATE TABLE M (A INT, B INT, CONSTRAINT M_UN UNIQUE (A, B));
CREATE TABLE SRC (ID INT);
CREATE TABLE TN (NAME VARCHAR(10) NOT NULL PRIMARY KEY);
CREATE TABLE MASTER (ID INT NOT NULL PRIMARY KEY);
CREATE TABLE DETAIL (CID INT, MID INT, CONSTRAINT C_FK FOREIGN KEY (MID) REFERENCES MASTER (ID));
CREATE TABLE K (ID INT, CONSTRAINT K_CHK CHECK (ID < 10));
COMMIT;
INSERT INTO W VALUES (1); INSERT INTO W VALUES (2); INSERT INTO W VALUES (3);
INSERT INTO W VALUES (5); INSERT INTO W VALUES (6); INSERT INTO W VALUES (7);
INSERT INTO W VALUES (8);
INSERT INTO W2 VALUES (8); INSERT INTO W2 VALUES (7); INSERT INTO W2 VALUES (6);
INSERT INTO W2 VALUES (5);
INSERT INTO S VALUES (1); INSERT INTO S VALUES (2);
INSERT INTO U VALUES (1);
INSERT INTO X VALUES (1);
INSERT INTO M VALUES (1, 2); INSERT INTO M VALUES (1, NULL);
INSERT INTO SRC VALUES (100); INSERT INTO SRC VALUES (101);
INSERT INTO SRC VALUES (101); INSERT INTO SRC VALUES (102);
INSERT INTO TN VALUES ('abc');
INSERT INTO MASTER VALUES (1); INSERT INTO MASTER VALUES (2);
INSERT INTO MASTER VALUES (3);
INSERT INTO DETAIL VALUES (10, 3);
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SCHEMA
EOF
    # the vector differential attaches through the engine's OWN wire
    # server, which runs as another user: it must be able to open both
    # files (embedded isql created them 0660 as this user)
    chmod 666 "$f"
done

# --- the full-status probe: node-firebird's callback hook exposes the
# --- RAW status vector items (gdscode + params), exactly as they ride
# --- the wire - the engine's args arrive PRE-QUOTED and the comparison
# --- keeps them verbatim. PREFIX=n keeps only the first n items (the
# --- CHECK comparison uses 1: fc may say the trigger differently).
cat > "$VJS" <<'JS'
const cb = require("node-firebird/lib/callback");
const orig = cb.doCallback;
let lastStatus = null;
cb.doCallback = function (obj, callback) {
  if (obj && typeof obj === "object" && obj.status) lastStatus = obj.status;
  return orig(obj, function (err, res) {
    if (err && lastStatus) { err.fullStatus = lastStatus; lastStatus = null; }
    if (callback) callback(err, res);
  });
};
const F = require("node-firebird");
F.attach({host:"127.0.0.1", port:+process.env.PORT, database:process.env.DB,
          user:"SYSDBA", password:"masterkey"}, (e, db) => {
  if (e) { console.log("CONN_ERR"); process.exit(1); }
  db.query(process.env.STMT, (qe) => {
    if (qe) {
      let v = qe.fullStatus || [];
      const n = +(process.env.PREFIX || 0);
      if (n > 0) v = v.slice(0, n);
      console.log("ERR " + JSON.stringify(v));
    } else console.log("OK");
    db.detach(); process.exit(0);
  });
});
JS

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-uo.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST" "$VJS"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "something is listening" is not "OUR server is listening": if the port
# was taken, every check below measures the other server. Fatal.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
vec_once() { # <port> <db> <stmt> [prefix]
    PORT="$1" DB="$2" STMT="$3" PREFIX="${4:-0}" timeout 20 node "$VJS" 2>/dev/null
}
vec_run() { # <port> <db> <stmt> [prefix] - retries connection races
    n=0
    while [ $n -lt 10 ]; do
        r=$(vec_once "$1" "$2" "$3" "${4:-0}")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

# Run one statement on BOTH sides (fc on the work copy, engine on the
# ref copy - the states advance in lockstep) and compare the verdict
# AND, on a refusal, the raw vector (prefix) byte for byte. The wanted
# vector is the ENGINE'S OWN, never hard-coded - INTEG numbering varies
# with creation order.
both() { # <label> <stmt> [prefix]
    got=$(vec_run "$PORT" "$WORK" "$2" "${3:-0}")
    want=$(vec_run "$ENGPORT" "$REF" "$2" "${3:-0}")
    check "$1 [$2]" "$got" "$want"
}

col() { # <file> <query> - one column, space-joined, engine's own read
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^$' | tr '\n' ' ' | strip
SET HEADING OFF;
$2;
SQL
}
gfix_clean() { # <label>
    v=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
    check "gfix -v -full clean: $1" "$(printf '%s' "$v" | strip)" ""
}

# --- 1. the shift up: refused at the FIRST colliding write, naming its
# ---    NEW key - the enforcement-order law itself
both "1. shift up refuses (recno order, first collision's NEW key)" \
     "UPDATE W SET ID = ID + 1 WHERE ID >= 5"
# --- 2. durably nothing happened: the ENGINE re-reads fc's file -------
check "2. refused shift left W untouched (engine reads fc's file)" \
      "$(col "$WORK" "SELECT ID FROM W ORDER BY ID")" "1 2 3 5 6 7 8"
gfix_clean "after the refused shift"
# --- 3. the shift DOWN passes: each write frees its old key first -----
both "3. shift down passes (each write frees its key first)" \
     "UPDATE W SET ID = ID - 1 WHERE ID >= 5"
check "3b. shift down landed durably (engine read)" \
      "$(col "$WORK" "SELECT ID FROM W ORDER BY ID")" "1 2 3 4 5 6 7"
# --- 4. THE WALK-ORDER CHECK: rows stored physically DESCENDING, the
# ---    same shift up passes entirely - record-number order, not key
# ---    order (P3)
both "4. shift up on physically-descending rows passes (walk order law)" \
     "UPDATE W2 SET ID = ID + 1 WHERE ID >= 5"
check "4b. descending shift landed durably (engine read)" \
      "$(col "$WORK" "SELECT ID FROM W2 ORDER BY ID")" "6 7 8 9"
gfix_clean "after the descending shift"
# --- 5. the two-row swap: refused at the first write - no deferral ----
both "5. swap SET ID = 3 - ID refuses at the first write" \
     "UPDATE S SET ID = 3 - ID"
# --- 6/7. plain INSERT dup, and the same through the execute2
# ---      RETURNING arm - both full-vector matches
both "6. INSERT dup refuses with the PK vector" \
     "INSERT INTO W VALUES (5)"
both "7. the same vector through the execute2 RETURNING arm" \
     "INSERT INTO W (ID) VALUES (5) RETURNING ID"
# --- 8. INSERT..SELECT with an internal dup: first-dup-in-output-order
# ---    key, and the statement is ATOMIC
both "8. INSERT..SELECT internal dup names the first dup in output order" \
     "INSERT INTO W SELECT ID FROM SRC"
check "8b. INSERT..SELECT rolled back whole (no 100/102 in fc's file)" \
      "$(col "$WORK" "SELECT ID FROM W WHERE ID IN (100, 102)")" ""
gfix_clean "after the atomic rollback"
# --- 9. DELETE + re-INSERT of the same key: accepted - a stale entry
# ---    whose record is gone is not a duplicate (and this moves 5
# ---    physically LAST, arming check 10)
both "9a. DELETE frees the key" "DELETE FROM W WHERE ID = 5"
both "9b. the freed key re-inserts" "INSERT INTO W VALUES (5)"
# --- 10. the reshuffled table: 5 now sits physically last, so recno
# ---     order is 6,7,5 and the collision is 6->7 - an index-plan walk
# ---     that enforced in KEY order would name ("ID" = 6) instead (P10)
both "10. shift up on the reshuffled table names the recno-order key" \
     "UPDATE W SET ID = ID + 1 WHERE ID >= 5"
# --- 11/12. constraint vs bare unique index: different primary codes --
both "11. UNIQUE CONSTRAINT dup names U_UN (isc_unique_key_violation)" \
     "INSERT INTO U VALUES (1)"
both "12. bare UNIQUE INDEX dup names X_IDX (isc_no_dup - other code)" \
     "INSERT INTO X VALUES (1)"
# --- 13/14/15. compound keys: full, partial-NULL (ENFORCED), all-NULL
# ---           (exempt, twice)
both "13. compound dup key text (A, B)" "INSERT INTO M VALUES (1, 2)"
both "14. partial-NULL compound dup IS refused, NULL bare in the key" \
     "INSERT INTO M VALUES (1, NULL)"
both "15a. all-NULL key exempt (first)" "INSERT INTO M VALUES (NULL, NULL)"
both "15b. all-NULL key exempt (again)" "INSERT INTO M VALUES (NULL, NULL)"
# --- 16. a text key prints single-quoted --------------------------------
both "16. text key dup prints ('abc')" "INSERT INTO TN VALUES ('abc')"
# --- 17. SET ID = ID: no key changes, no violation ----------------------
both "17. SET ID = ID passes (no-change writes exempt)" \
     "UPDATE W SET ID = ID"
# --- 18/19. FK both directions: the CHILD's constraint and table, the
# ---        failing side's key columns
both "18. FK child insert names C_FK + the child's own key columns" \
     "INSERT INTO DETAIL VALUES (11, 999)"
both "19. FK parent delete names C_FK + the PARENT row's key" \
     "DELETE FROM MASTER WHERE ID = 3"
# --- 20. NOT NULL -------------------------------------------------------
both "20. NOT NULL refusal ships isc_not_valid with *** null ***" \
     "INSERT INTO W VALUES (NULL)"
# --- 21. CHECK: first vector item only (the trigger stack item is
# ---     compared leniently - fc may omit it)
both "21. CHECK refusal ships isc_check_constraint" \
     "INSERT INTO K VALUES (11)" 1
# --- 22. epilogue: final contents equal table by table, then gbak/gfix -
kill $srv 2>/dev/null; wait $srv 2>/dev/null

dump() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'W|'||ID FROM W ORDER BY ID;
SELECT 'W2|'||ID FROM W2 ORDER BY ID;
SELECT 'S|'||ID FROM S ORDER BY ID;
SELECT 'U|'||ID FROM U ORDER BY ID;
SELECT 'X|'||ID FROM X ORDER BY ID;
SELECT 'M|'||COALESCE(A,-1)||'|'||COALESCE(B,-1) FROM M ORDER BY 1;
SELECT 'TN|'||NAME FROM TN ORDER BY NAME;
SELECT 'MA|'||ID FROM MASTER ORDER BY ID;
SELECT 'D|'||CID||'|'||COALESCE(MID,-1) FROM DETAIL ORDER BY CID;
SELECT 'K|'||ID FROM K ORDER BY ID;
SQL
}
work_d=$(dump "$WORK")
check "22. final contents match the engine, table by table" \
      "$work_d" "$(dump "$REF")"
case "$work_d" in
    *"W2|9"*"M|-1|-1"*) echo "OK   the allowed writes really landed (W2 shifted, all-NULL rows stored)" ;;
    *) echo "DIFF the content comparison was vacuous"; echo "     $work_d"; fail=1 ;;
esac

if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-uo-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-uo-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-uo-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-uo-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-uo-restore.log | head; fail=1
fi
gfix_clean "final (fc's raw file)"

exit $fail
