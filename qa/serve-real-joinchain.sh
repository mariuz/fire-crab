#!/bin/sh
# A CHAIN of joins - three tables and more - answered from the pages.
#
#   SELECT ... FROM a JOIN b ON ... [LEFT] JOIN c ON ... [WHERE ...]
#              [GROUP BY ...] [ORDER BY ...]
#
# The FROM clause used to refuse a second JOIN outright. It parses into
# one step per join now, and the rows are FOLDED: each step joins
# everything accumulated so far with the next table, so the second ON may
# name either of the first two - which is what makes a chain different
# from two independent joins.
#
#   qa/serve-real-joinchain.sh <clean-db-path> [port]
#
# Expects the join scratch db (qa/mkjoindb.sh builds it). Three of its
# properties carry this gate:
#
#   * EMP has three rows with no department (two NULL keys and one
#     dangling), so an INNER first step drops them and a LEFT one keeps
#     them - and what the SECOND step then does with those padded rows is
#     the thing a chain gets wrong: their DEPT columns are NULL, so they
#     cannot match REGION either.
#   * REGION 50 belongs to no department, so the second step has
#     something of its own to drop.
#   * Every kind combination below therefore has a different row count,
#     and the counts are what the checks compare.
#
# node-firebird drives fire-crab; isql answers the same queries from the
# same file; the texts must be identical.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-joinchain.sh <clean-db-path> [port]}"
PORT="${2:-4525}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
fail=0
ran=0

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-joinchain.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0
while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

node_q() {
    FC_DB="$DB" FC_PORT="$PORT" FC_Q="$1" timeout 30 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR");db.detach();process.exit(0);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);});});' 2>/dev/null
}
isql_q() {
    printf 'SET HEADING OFF;\n%s\n' "$1" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}
compare() { # <label> <sql for fire-crab> <sql for isql>
    ran=$((ran + 1))
    a=$(node_q "$2")
    b=$(isql_q "$3")
    if [ "$a" = "$b" ]; then
        echo "OK   $1 ($(printf '%s\n' "$a" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$b" > /tmp/fc-jc-isql.txt
        printf '%s\n' "$a" > /tmp/fc-jc-crab.txt
        diff /tmp/fc-jc-isql.txt /tmp/fc-jc-crab.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

E="EMP E JOIN DEPT D ON E.DEPT_ID = D.ID"

# --- the row COUNTS, which is where a mis-folded chain shows -----------
compare "three tables, all INNER" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID;"
compare "INNER then LEFT" \
    "SELECT COUNT(*) FROM $E LEFT JOIN REGION R ON D.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM $E LEFT JOIN REGION R ON D.REGION_ID = R.ID;"
# the padded rows of a LEFT first step have NULL department columns, so
# they cannot match REGION either - an inner second step drops them again
compare "LEFT then INNER" \
    "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID JOIN REGION R ON D.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID JOIN REGION R ON D.REGION_ID = R.ID;"
compare "LEFT then LEFT keeps them all" \
    "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID LEFT JOIN REGION R ON D.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID LEFT JOIN REGION R ON D.REGION_ID = R.ID;"
compare "a RIGHT second step brings the unreferenced region back" \
    "SELECT COUNT(*) FROM $E RIGHT JOIN REGION R ON D.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM $E RIGHT JOIN REGION R ON D.REGION_ID = R.ID;"

# --- the second ON may name EITHER earlier table ------------------------
compare "the second ON names the FIRST table" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON E.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON E.REGION_ID = R.ID;"
compare "an AND across all three" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID AND E.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID AND E.REGION_ID = R.ID;"

# --- rows, projections and the clauses around them ---------------------
compare "columns from all three tables" \
    "SELECT E.ID, R.NAME FROM $E JOIN REGION R ON D.REGION_ID = R.ID ORDER BY E.ID" \
    "SELECT E.ID || '|' || R.NAME FROM $E JOIN REGION R ON D.REGION_ID = R.ID ORDER BY E.ID;"
compare "a WHERE over the third table" \
    "SELECT E.ID FROM $E JOIN REGION R ON D.REGION_ID = R.ID WHERE R.NAME = 'North' ORDER BY E.ID" \
    "SELECT E.ID FROM $E JOIN REGION R ON D.REGION_ID = R.ID WHERE R.NAME = 'North' ORDER BY E.ID;"
compare "GROUP BY a column of the third" \
    "SELECT R.NAME, COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID GROUP BY R.NAME ORDER BY 1" \
    "SELECT R.NAME || '|' || COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID GROUP BY R.NAME ORDER BY 1;"
compare "an aggregate over the chain" \
    "SELECT SUM(E.SALARY) FROM $E JOIN REGION R ON D.REGION_ID = R.ID" \
    "SELECT SUM(E.SALARY) FROM $E JOIN REGION R ON D.REGION_ID = R.ID;"
compare "ORDER BY a qualified column of the third" \
    "SELECT E.ID FROM $E JOIN REGION R ON D.REGION_ID = R.ID ORDER BY R.NAME, E.ID" \
    "SELECT CAST(E.ID AS VARCHAR(12)) FROM $E JOIN REGION R ON D.REGION_ID = R.ID ORDER BY R.NAME, E.ID;"

# --- FOUR tables, to show the fold is not special-cased at three -------
compare "four tables in one chain" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID JOIN REGION R2 ON R.ID = R2.ID" \
    "SELECT COUNT(*) FROM $E JOIN REGION R ON D.REGION_ID = R.ID JOIN REGION R2 ON R.ID = R2.ID;"

# --- CROSS JOIN and the comma list, which are the same step -----------
compare "CROSS JOIN is a cartesian product" \
    "SELECT COUNT(*) FROM DEPT D CROSS JOIN REGION R" \
    "SELECT COUNT(*) FROM DEPT D CROSS JOIN REGION R;"
compare "a comma list says the same thing" \
    "SELECT COUNT(*) FROM DEPT D, REGION R" \
    "SELECT COUNT(*) FROM DEPT D, REGION R;"
compare "a comma list with a WHERE is the old-style join" \
    "SELECT COUNT(*) FROM DEPT D, REGION R WHERE D.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM DEPT D, REGION R WHERE D.REGION_ID = R.ID;"
compare "three items in a comma list" \
    "SELECT COUNT(*) FROM DEPT D, REGION R, J1" \
    "SELECT COUNT(*) FROM DEPT D, REGION R, J1;"
compare "a CROSS after an ON-join" \
    "SELECT COUNT(*) FROM $E CROSS JOIN REGION R" \
    "SELECT COUNT(*) FROM $E CROSS JOIN REGION R;"
compare "a CROSS before one" \
    "SELECT COUNT(*) FROM DEPT D CROSS JOIN REGION R JOIN EMP E ON E.DEPT_ID = D.ID" \
    "SELECT COUNT(*) FROM DEPT D CROSS JOIN REGION R JOIN EMP E ON E.DEPT_ID = D.ID;"
# a comma ITEM may be a join, and its ON sees only that item's tables
compare "a comma item that is itself a join" \
    "SELECT COUNT(*) FROM DEPT D, REGION R JOIN EMP E ON E.REGION_ID = R.ID" \
    "SELECT COUNT(*) FROM DEPT D, REGION R JOIN EMP E ON E.REGION_ID = R.ID;"

# --- NATURAL JOIN: the condition comes from the NAMES ------------------
# NL and NR share K and G, so the derived condition has two terms; only
# one pair agrees on both, and the row whose shared columns are NULL
# never joins, because NULL = NULL is UNKNOWN.
compare "NATURAL JOIN derives its condition" \
    "SELECT COUNT(*) FROM NL NATURAL JOIN NR" \
    "SELECT COUNT(*) FROM NL NATURAL JOIN NR;"
compare "the shared columns appear ONCE in *" \
    "SELECT * FROM NL NATURAL JOIN NR" \
    "SELECT NL.K || '|' || NL.G || '|' || NL.LONLY || '|' || NR.RONLY FROM NL NATURAL JOIN NR;"
compare "a bare shared name is not ambiguous" \
    "SELECT K FROM NL NATURAL JOIN NR" \
    "SELECT K FROM NL NATURAL JOIN NR;"
compare "and the qualified one still reaches the other side" \
    "SELECT NR.K FROM NL NATURAL JOIN NR" \
    "SELECT NR.K FROM NL NATURAL JOIN NR;"
compare "a bare shared name in the WHERE" \
    "SELECT COUNT(*) FROM NL NATURAL JOIN NR WHERE K = 1" \
    "SELECT COUNT(*) FROM NL NATURAL JOIN NR WHERE K = 1;"
compare "NATURAL LEFT keeps the unmatched left rows" \
    "SELECT COUNT(*) FROM NL NATURAL LEFT JOIN NR" \
    "SELECT COUNT(*) FROM NL NATURAL LEFT JOIN NR;"
compare "NATURAL FULL keeps both sides" \
    "SELECT COUNT(*) FROM NL NATURAL FULL JOIN NR" \
    "SELECT COUNT(*) FROM NL NATURAL FULL JOIN NR;"
# in an OUTER natural join the merged column shows whichever side has a
# value - the preserved side may be the PADDED one
compare "the merged column in a NATURAL RIGHT join" \
    "SELECT * FROM NL NATURAL RIGHT JOIN NR" \
    "SELECT COALESCE(CAST(NL.K AS VARCHAR(12)),CAST(NR.K AS VARCHAR(12))) || '|' || COALESCE(CAST(NL.G AS VARCHAR(12)),CAST(NR.G AS VARCHAR(12)),'<null>') || '|' || COALESCE(NL.LONLY,'<null>') || '|' || NR.RONLY FROM NL NATURAL RIGHT JOIN NR;"
# sharing NO column name makes it a cross join (probed)
compare "NATURAL with nothing in common is a cross join" \
    "SELECT COUNT(*) FROM NL NATURAL JOIN REGION" \
    "SELECT COUNT(*) FROM NL NATURAL JOIN REGION;"

# --- refusals ----------------------------------------------------------
# ... and naming a table from ANOTHER item in that ON is an error on
# both: the join binds tighter than the comma, so D is not in scope
a=$(node_q "SELECT COUNT(*) FROM DEPT D, REGION R JOIN EMP E ON E.DEPT_ID = D.ID")
b=$(isql_q "SELECT COUNT(*) FROM DEPT D, REGION R JOIN EMP E ON E.DEPT_ID = D.ID;")
ran=$((ran + 1))
case "$a" in
    ERR*) case "$b" in
              *rror*|*SQLSTATE*) echo "OK   an item's ON cannot name another item's table, on either" ;;
              *) echo "DIFF the engine answered the cross-item ON: [$b]"; fail=1 ;;
          esac ;;
    *) echo "DIFF fire-crab answered a cross-item ON: [$a]"; fail=1 ;;
esac
# a NATURAL kind keyword that is not one
r=$(node_q "SELECT COUNT(*) FROM NL NATURAL BOGUS JOIN NR")
ran=$((ran + 1))
case "$r" in
    ERR*) echo "OK   an unknown NATURAL join kind is refused" ;;
    *) echo "DIFF NATURAL BOGUS answered: [$r]"; fail=1 ;;
esac
# two sides sharing a qualifier cannot be told apart
r=$(node_q "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID JOIN REGION D ON D.REGION_ID = D.ID")
ran=$((ran + 1))
case "$r" in
    ERR*) echo "OK   a repeated qualifier is refused" ;;
    *) echo "DIFF repeated qualifier answered: [$r]"; fail=1 ;;
esac
# an ambiguous bare name across THREE tables
r=$(node_q "SELECT ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID JOIN REGION R ON D.REGION_ID = R.ID")
ran=$((ran + 1))
case "$r" in
    ERR*) echo "OK   a bare name on three tables is ambiguous, and refused" ;;
    *) echo "DIFF ambiguous bare name answered: [$r]"; fail=1 ;;
esac

# --- the WHOLE fetch of a chain STREAMS a base row at a time ------------
# A bare chain (no FIRST/ORDER BY) is served by a RESUMABLE JOIN CURSOR
# that folds each base row through every part - never materialising the
# intermediate join - so reading part of a big chain costs O(fetched), not
# O(product). These pin its correctness: a chain whose parts are theta or
# unindexed-equi (no index probe) routes THROUGH the cursor, and its rows
# must be the engine's. The projection is one column, so node's `|`-joined
# text and isql's are the same shape; the row ORDER of an unordered join is
# the driver's, which the two engines need not share, so the MULTISETS are
# compared (sorted), which is what "the same rows" means without an ORDER BY.
chain_ms() { # <label> <sql> - same SQL both sides, MULTISET (sorted) compare
    ran=$((ran + 1))
    a=$(node_q "$2" | sort)
    b=$(isql_q "$2;" | sort)
    if [ "$a" = "$b" ]; then
        echo "OK   $1 ($(printf '%s\n' "$a" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$b" > /tmp/fc-jc-isql.txt
        printf '%s\n' "$a" > /tmp/fc-jc-crab.txt
        diff /tmp/fc-jc-isql.txt /tmp/fc-jc-crab.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}
# a THREE-table THETA chain: neither part is indexed, so both fold in the
# cursor (a theta ON never has a probe)
chain_ms "a three-table theta chain streams" \
    "SELECT E.ID FROM EMP E JOIN DEPT D ON E.SALARY > D.ID JOIN REGION R ON E.REGION_ID > R.ID"
# an unindexed-equi first step (both keyed on the non-PK REGION_ID = hash)
# then a theta second step
chain_ms "an unindexed-equi then theta chain streams" \
    "SELECT E.ID FROM EMP E JOIN DEPT D ON E.REGION_ID = D.REGION_ID JOIN REGION R ON E.SALARY > R.ID"
# LEFT then LEFT over the same unindexed keys keeps the unmatched base rows
chain_ms "a LEFT-LEFT unindexed chain pads and streams" \
    "SELECT E.ID FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.REGION_ID LEFT JOIN REGION R ON E.SALARY > R.ID"
# a trailing RIGHT: the inner parts fold, then the last part's mirror emits
# the REGION rows nothing reached
chain_ms "a chain ending in a RIGHT streams matches then the mirror" \
    "SELECT R.NAME FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.REGION_ID RIGHT JOIN REGION R ON E.SALARY > R.ID"
# a WHERE above the whole streamed chain
chain_ms "a WHERE above the whole streamed chain" \
    "SELECT E.ID FROM EMP E JOIN DEPT D ON E.SALARY > D.ID JOIN REGION R ON E.REGION_ID > R.ID WHERE E.ID < 20"
# an INDEXED first step (DEPT's PK) folds through the cursor too: the
# probe walks the index on the FROZEN image per accumulated row, so an
# indexed part no longer sends the whole fetch back to the materialiser
chain_ms "an indexed then theta chain streams" \
    "SELECT E.ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID JOIN REGION R ON E.SALARY > R.ID"

if [ "$ran" -lt 39 ]; then
    echo "DIFF only $ran checks ran (expected at least 39) - did one silently skip?"
    fail=1
fi
exit $fail
