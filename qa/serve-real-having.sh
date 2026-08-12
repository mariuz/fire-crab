#!/bin/sh
# The server filters grouped output with HAVING. fire-crab, as a server,
# answers:
#   SELECT <keys and aggregates> FROM <t> [WHERE ...] GROUP BY <cols>
#          HAVING <pred> [ORDER BY ...]
#   SELECT <aggregates> FROM <t> HAVING <pred>       (one global group)
# from the pages - the HAVING predicate is evaluated on each group's
# computed output row (comparisons, AND/OR, IS [NOT] NULL) and may name
# aggregates that are NOT in the select list (computed as hidden items)
# or any grouping column. A named aggregate may carry a FILTER clause -
# `COUNT(*) FILTER (WHERE c)`, `SUM(x) FILTER (...)`, `COUNT(DISTINCT x)
# FILTER (...)` - folded as its own hidden item over the CASE the filter
# rewrites to, exactly as a filtered select-list aggregate is. node-fire
# bird drives it and results must equal isql's - including queries where
# HAVING rejects every group (zero rows, compared via a <no rows>
# sentinel).
#
#   qa/serve-real-having.sh <clean-db-path> [port]
#
# The battery runs against whichever of these tables the database has:
#   EMP(ID, DEPT_ID, SALARY, NAME)  - NULL keys/values
#   T(A, C) nullable                - all-NULL aggregate groups
# Use a clean (gbak-restored) database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-having.sh <clean-db-path> [port]}"
PORT="${2:-4527}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }
has_table() { [ "$(run_isql <<EOF | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='$1';
EOF
)" != "0" ]; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-having.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
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

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# rows in order (no sort), string values right-trimmed. A zero-row result
# prints the <no rows> sentinel - a legitimate HAVING outcome that must
# stay distinguishable from a transient connection failure (whose output
# is empty and retried). Any failure prints CONN_ERR for the retry loop.
node_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("CONN_ERR");db.detach();process.exit(1);}
          if(r.length===0)console.log("<no rows>");
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
# retry while the result failed or came back empty (a reset can yield either)
node_ordered() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
compare() { # <label> <node-query> <isql-select-body>  (compared in order)
    fc=$(node_ordered "$2")
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING OFF;
$3;
EOF
)
    [ -z "$is" ] && is="<no rows>"
    if [ "$fc" = "$is" ]; then
        echo "OK   $1 ($(printf '%s\n' "$fc" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$is" > /tmp/fc-hv-is.txt; printf '%s\n' "$fc" > /tmp/fc-hv-fc.txt
        diff /tmp/fc-hv-is.txt /tmp/fc-hv-fc.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

NK="COALESCE(CAST(DEPT_ID AS VARCHAR(12)),'<null>')"
if has_table EMP; then
    # HAVING on the selected aggregate
    compare "HAVING COUNT(*)" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) > 13 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) > 13 ORDER BY DEPT_ID"
    # HAVING on an aggregate NOT in the select list (a hidden item)
    compare "HAVING hidden aggregate" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING SUM(SALARY) > 190000 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING SUM(SALARY) > 190000 ORDER BY DEPT_ID"
    # ...even with no aggregate selected at all
    compare "HAVING on key-only projection" \
        "SELECT DEPT_ID FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) >= 13 ORDER BY DEPT_ID" \
        "SELECT $NK FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) >= 13 ORDER BY DEPT_ID"
    # HAVING on a grouping column, and the NULL-key group via IS NULL
    compare "HAVING on group key" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING DEPT_ID >= 2 ORDER BY DEPT_ID" \
        "SELECT DEPT_ID || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING DEPT_ID >= 2 ORDER BY DEPT_ID"
    compare "HAVING key IS NULL" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING DEPT_ID IS NULL" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING DEPT_ID IS NULL"
    # AND/OR compose (AND binds tighter), mixing keys and aggregates
    compare "HAVING with AND/OR" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING DEPT_ID IS NULL OR COUNT(*) > 3 AND MIN(SALARY) > 1000 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING DEPT_ID IS NULL OR COUNT(*) > 3 AND MIN(SALARY) > 1000 ORDER BY DEPT_ID"
    # WHERE filters rows before grouping, HAVING filters groups after
    compare "WHERE + HAVING" \
        "SELECT DEPT_ID, SUM(SALARY) FROM EMP WHERE ID <= 50 GROUP BY DEPT_ID HAVING SUM(SALARY) > 45000 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || SUM(SALARY) FROM EMP WHERE ID <= 50 GROUP BY DEPT_ID HAVING SUM(SALARY) > 45000 ORDER BY DEPT_ID"
    # HAVING that rejects every group: zero rows on both sides
    compare "HAVING rejects all groups" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) > 100000" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) > 100000"
    # one global group: HAVING keeps or rejects the single output row
    compare "global HAVING keeps the row" \
        "SELECT COUNT(*) FROM EMP HAVING COUNT(*) > 50" \
        "SELECT COUNT(*) FROM EMP HAVING COUNT(*) > 50"
    compare "global HAVING rejects the row" \
        "SELECT COUNT(*), MAX(SALARY) FROM EMP HAVING COUNT(*) > 100000" \
        "SELECT COUNT(*) || '|' || MAX(SALARY) FROM EMP HAVING COUNT(*) > 100000"
    # lowercase keywords
    compare "lowercase having" \
        "select dept_id, count(*) from emp group by dept_id having count(*) > 13 order by 1" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) > 13 ORDER BY DEPT_ID"
    # a FILTER on the HAVING aggregate: only the accepted rows fold
    compare "HAVING COUNT(*) FILTER" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) FILTER (WHERE SALARY > 1000) > 5 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) FILTER (WHERE SALARY > 1000) > 5 ORDER BY DEPT_ID"
    # a filtered aggregate NOT in the select list (a hidden filtered item)
    compare "HAVING SUM FILTER hidden" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING SUM(SALARY) FILTER (WHERE ID <= 50) > 20000 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING SUM(SALARY) FILTER (WHERE ID <= 50) > 20000 ORDER BY DEPT_ID"
    # COUNT(DISTINCT x) FILTER in HAVING - the distinct fold over the CASE
    compare "HAVING COUNT(DISTINCT) FILTER" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(DISTINCT SALARY) FILTER (WHERE SALARY > 1000) >= 2 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(DISTINCT SALARY) FILTER (WHERE SALARY > 1000) >= 2 ORDER BY DEPT_ID"
    # a filtered aggregate composed with a plain one under AND
    compare "HAVING FILTER AND plain" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) FILTER (WHERE SALARY > 1000) >= 1 AND COUNT(*) > 3 ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID HAVING COUNT(*) FILTER (WHERE SALARY > 1000) >= 1 AND COUNT(*) > 3 ORDER BY DEPT_ID"
    # one global group with a filtered HAVING aggregate
    compare "global HAVING FILTER" \
        "SELECT COUNT(*) FROM EMP HAVING COUNT(*) FILTER (WHERE SALARY > 1000) > 10" \
        "SELECT COUNT(*) FROM EMP HAVING COUNT(*) FILTER (WHERE SALARY > 1000) > 10"
fi
if has_table T; then
    # IS NULL on an aggregate: groups whose values are all NULL
    compare "HAVING aggregate IS NULL" \
        "SELECT A, COUNT(*) FROM T GROUP BY A HAVING SUM(C) IS NULL ORDER BY A" \
        "SELECT COALESCE(CAST(A AS VARCHAR(12)),'<null>') || '|' || COUNT(*) FROM T GROUP BY A HAVING SUM(C) IS NULL ORDER BY A"
fi
exit $fail
