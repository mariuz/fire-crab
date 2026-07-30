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
# NATURAL JOIN joins on every shared NAME - a different rule, refused
r=$(node_q "SELECT COUNT(*) FROM DEPT NATURAL JOIN REGION")
ran=$((ran + 1))
case "$r" in
    ERR*) echo "OK   NATURAL JOIN is refused (it joins on shared NAMES)" ;;
    *) echo "DIFF NATURAL JOIN answered: [$r]"; fail=1 ;;
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

if [ "$ran" -lt 24 ]; then
    echo "DIFF only $ran checks ran (expected at least 24) - did one silently skip?"
    fail=1
fi
exit $fail
