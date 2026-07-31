#!/bin/sh
# AGGREGATES and GROUP BY over a JOIN. fire-crab, as a server, answers:
#   SELECT <keys and aggregates> FROM t1 [a] JOIN t2 [b] ON <col> = <col>
#          [WHERE ...] [GROUP BY ...] [HAVING ...] [ORDER BY ...]
# by folding the COMBINED rows with the same machinery a single
# relation's grouping uses - only the input differs.
#
#   qa/serve-real-joingroup.sh <clean-db-path> [port]
#
# Expects the join scratch db (qa/mkjoindb.sh builds it): EMP with NULL
# and DANGLING department keys, DEPT with a department no employee
# references. Both matter here - every aggregate below is over the INNER
# join, so the three unmatched employees must not be in any total, and
# the empty department must not be a group.
#
# node-firebird drives fire-crab; isql answers the same queries from the
# same file; the texts must be identical. Results are compared IN ORDER
# where the query orders them, and the aggregate VALUES are what carry
# the meaning: a join that emitted a row too many would still produce
# plausible-looking groups, and only the totals would say so.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-joingroup.sh <clean-db-path> [port]}"
PORT="${2:-4515}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
fail=0

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-joingroup.log 2>&1 &
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

node_q() { # <sql> - values joined by |, one row per line
    FC_DB="$DB" FC_PORT="$PORT" FC_Q="$1" timeout 25 node -e '
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
isql_q() { # <sql producing one concatenated column per row>
    printf 'SET HEADING OFF;\n%s\n' "$1" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}
compare() { # <label> <sql for fire-crab> <sql for isql>
    a=$(node_q "$2")
    b=$(isql_q "$3")
    if [ "$a" = "$b" ]; then
        echo "OK   $1 ($(printf '%s\n' "$a" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$b" > /tmp/fc-jg-isql.txt
        printf '%s\n' "$a" > /tmp/fc-jg-crab.txt
        diff /tmp/fc-jg-isql.txt /tmp/fc-jg-crab.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

# --- the whole join as ONE group ---------------------------------------
compare "SUM over a join" \
    "SELECT SUM(E.SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT SUM(E.SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID;"
compare "MIN/MAX/COUNT together" \
    "SELECT MIN(E.SALARY) AS A, MAX(E.SALARY) AS B, COUNT(*) AS C FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT MIN(E.SALARY) || '|' || MAX(E.SALARY) || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID;"
# the two counts are ALIASED apart: this driver keys a row by column
# name, so two columns both titled COUNT would clobber each other
compare "COUNT of a column counts non-NULLs" \
    "SELECT COUNT(E.DEPT_ID) AS C1, COUNT(*) AS C2 FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT COUNT(E.DEPT_ID) || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID;"
compare "AVG over a join" \
    "SELECT AVG(E.SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT AVG(E.SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID;"
# an UNQUALIFIED aggregate argument, and a WHERE narrowing the join
compare "unqualified argument + WHERE" \
    "SELECT SUM(SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID = 3" \
    "SELECT SUM(SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID = 3;"

# --- GROUP BY a column of either side -----------------------------------
# `D.ID` is the case that needs the qualified spelling: BOTH tables have
# an ID, so the bare name is ambiguous and only the qualifier resolves it
compare "GROUP BY a qualified key" \
    "SELECT D.ID, COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY 1" \
    "SELECT D.ID || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY 1;"
compare "GROUP BY with a SUM per group" \
    "SELECT D.ID, SUM(E.SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY 1" \
    "SELECT D.ID || '|' || SUM(E.SALARY) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY 1;"
# DEPT_ID is a column of EMP only, so the bare name means one side
compare "GROUP BY an unambiguous column, bare" \
    "SELECT DEPT_ID, COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY DEPT_ID ORDER BY 1" \
    "SELECT DEPT_ID || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY DEPT_ID ORDER BY 1;"
# ... and an AMBIGUOUS bare name refuses on both: REGION_ID is a column
# of each side, so only a qualifier can mean one of them
amb=$(node_q "SELECT REGION_ID, COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY REGION_ID")
eng=$(isql_q "SELECT REGION_ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY REGION_ID;" 2>&1)
case "$amb" in
    ERR*) case "$eng" in
              *Ambiguous*) echo "OK   an ambiguous bare key refuses on both" ;;
              *) echo "DIFF the engine did not call REGION_ID ambiguous: [$eng]"; fail=1 ;;
          esac ;;
    *) echo "DIFF fire-crab answered an ambiguous key: [$amb]"; fail=1 ;;
esac
compare "GROUP BY a column of the LEFT side" \
    "SELECT E.DEPT_ID, COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY E.DEPT_ID ORDER BY 1" \
    "SELECT E.DEPT_ID || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY E.DEPT_ID ORDER BY 1;"
compare "GROUP BY with a WHERE" \
    "SELECT D.ID, COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE E.SALARY > 3000 GROUP BY D.ID ORDER BY 1" \
    "SELECT D.ID || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE E.SALARY > 3000 GROUP BY D.ID ORDER BY 1;"

# --- HAVING filters the GROUPS, not the rows ---------------------------
compare "HAVING over a join" \
    "SELECT D.ID, COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID HAVING COUNT(*) > 14 ORDER BY 1" \
    "SELECT D.ID || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID HAVING COUNT(*) > 14 ORDER BY 1;"
compare "HAVING on an aggregate not in the select list" \
    "SELECT D.ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID HAVING SUM(E.SALARY) > 48000 ORDER BY 1" \
    "SELECT CAST(D.ID AS VARCHAR(12)) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID HAVING SUM(E.SALARY) > 48000 ORDER BY 1;"

# --- ORDER BY over the grouped output ----------------------------------
compare "ORDER BY the aggregate, descending" \
    "SELECT D.ID, COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY 2 DESC, 1" \
    "SELECT D.ID || '|' || COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY COUNT(*) DESC, D.ID;"

# --- an OUTER join folds the PADDED rows -------------------------------
# the three employees with no department (two NULL keys and one dangling)
# are padded rows in a LEFT join, so they form a NULL group - which is
# exactly the difference between an inner and an outer fold
# ordered by the KEY itself on both sides: ordering the reference by its
# rendered text would put '<null>' after the digits, where the DATE-less
# NULL key sorts first
compare "GROUP BY over a LEFT join, NULL group included" \
    "SELECT D.ID, COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY 1" \
    "SELECT COALESCE(CAST(D.ID AS VARCHAR(12)),'<null>') || '|' || COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID GROUP BY D.ID ORDER BY D.ID;"
compare "COUNT(col) over a LEFT join ignores the padding" \
    "SELECT COUNT(D.ID) AS C1, COUNT(*) AS C2 FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT COUNT(D.ID) || '|' || COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID;"

# --- teeth -------------------------------------------------------------
# the inner fold must EXCLUDE the three unmatched employees; if the join
# leaked them the totals above would differ from these
compare "the inner join's row count is the joined one" \
    "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID;"
compare "and the LEFT join keeps them" \
    "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID;"

exit $fail
