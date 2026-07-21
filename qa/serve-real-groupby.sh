#!/bin/sh
# The server groups (GROUP BY) and aggregates per group. fire-crab, as a
# server, answers:
#   SELECT <keys and aggregates> FROM <t> [WHERE ...] GROUP BY <cols|ordinals>
#          [ORDER BY <cols|ordinals> [ASC|DESC]]
#   SELECT <aggregate list> FROM <t> [WHERE ...]          (one global group)
# from the pages - filtering, bucketing the rows by the key columns (NULL
# keys form one group), computing COUNT(*)/COUNT(col)/MIN/MAX/SUM per
# bucket. node-firebird drives it and results must equal isql's.
#
#   qa/serve-real-groupby.sh <clean-db-path> [port]
#
# The battery runs against whichever of these tables the database has:
#   EMP(ID, DEPT_ID, SALARY, NAME)  - group keys + NULL keys/values
#   DEPT(ID, NAME)                  - text group keys
#   T(A, C) nullable                - NULL bucketing, SUM over NULLs
# Grouped results with ORDER BY are compared IN ORDER; the one query
# without ORDER BY is compared sorted (the engine does not promise an
# order there). Use a clean (gbak-restored) database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-groupby.sh <clean-db-path> [port]}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }
has_table() { [ "$(run_isql <<EOF | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='$1';
EOF
)" != "0" ]; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-groupby.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# rows in order (no sort), string values right-trimmed. Any failure
# (attach/query error, uncaught exception, or timeout) prints CONN_ERR so
# the caller can retry - occasional first-connect resets are transient.
node_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("CONN_ERR");db.detach();process.exit(1);}
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
compare() { # <label> <node-query> <isql-select-body> [sorted]  (in order unless sorted)
    fc=$(node_ordered "$2")
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING OFF;
$3;
EOF
)
    if [ "${4:-}" = "sorted" ]; then
        fc=$(printf '%s\n' "$fc" | sort)
        is=$(printf '%s\n' "$is" | sort)
    fi
    if [ "$fc" = "$is" ] && [ -n "$fc" ]; then
        echo "OK   $1 ($(printf '%s\n' "$fc" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$is" > /tmp/fc-gb-is.txt; printf '%s\n' "$fc" > /tmp/fc-gb-fc.txt
        diff /tmp/fc-gb-is.txt /tmp/fc-gb-fc.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

NK="COALESCE(CAST(DEPT_ID AS VARCHAR(12)),'<null>')"
if has_table EMP; then
    # key + COUNT(*), the NULL key bucket ordered first (NULLs low, ASC)
    compare "GROUP BY key + COUNT(*)" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
    # the full aggregate battery per group, over a NULLable value column.
    # (COUNT(*) and COUNT(col) never share a query here: the engine titles
    # both output columns COUNT, and node-firebird keys rows by alias, so
    # one would clobber the other client-side - against any server.)
    compare "COUNT/MIN/MAX/SUM per group" \
        "SELECT DEPT_ID, COUNT(*), MIN(SALARY), MAX(SALARY), SUM(SALARY) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) || '|' || MIN(SALARY) || '|' || MAX(SALARY) || '|' || SUM(SALARY) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
    # COUNT(col) counts only the non-null values in each bucket
    compare "COUNT(col) per group" \
        "SELECT DEPT_ID, COUNT(SALARY) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(SALARY) FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
    # WHERE filters before grouping
    compare "WHERE + GROUP BY" \
        "SELECT DEPT_ID, COUNT(*), SUM(SALARY) FROM EMP WHERE ID <= 50 GROUP BY DEPT_ID ORDER BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) || '|' || SUM(SALARY) FROM EMP WHERE ID <= 50 GROUP BY DEPT_ID ORDER BY DEPT_ID"
    # GROUP BY with no aggregate = the distinct keys
    compare "GROUP BY without aggregate" \
        "SELECT DEPT_ID FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID" \
        "SELECT $NK FROM EMP GROUP BY DEPT_ID ORDER BY DEPT_ID"
    # ordinals + lowercase keywords; fire-crab ORDER BY 2 sorts the COUNT
    compare "ordinals, lowercase" \
        "select dept_id, count(*) from emp where dept_id is not null group by 1 order by 2 desc, 1" \
        "SELECT DEPT_ID || '|' || COUNT(*) FROM EMP WHERE DEPT_ID IS NOT NULL GROUP BY DEPT_ID ORDER BY COUNT(*) DESC, DEPT_ID"
    # no ORDER BY: content must match, order is not promised
    compare "GROUP BY without ORDER BY" \
        "SELECT DEPT_ID, COUNT(*) FROM EMP GROUP BY DEPT_ID" \
        "SELECT $NK || '|' || COUNT(*) FROM EMP GROUP BY DEPT_ID" sorted
    # one global group: a multi-aggregate projection with no GROUP BY
    compare "global multi-aggregate" \
        "SELECT MIN(SALARY), MAX(SALARY), SUM(SALARY), COUNT(*) FROM EMP" \
        "SELECT MIN(SALARY) || '|' || MAX(SALARY) || '|' || SUM(SALARY) || '|' || COUNT(*) FROM EMP"
    # ...and over an empty set: one row, NULL aggregates, COUNT 0
    compare "global aggregates, empty set" \
        "SELECT MIN(SALARY), MAX(SALARY), COUNT(*) FROM EMP WHERE ID > 1000000" \
        "SELECT COALESCE(CAST(MIN(SALARY) AS VARCHAR(12)),'<null>') || '|' || COALESCE(CAST(MAX(SALARY) AS VARCHAR(12)),'<null>') || '|' || COUNT(*) FROM EMP WHERE ID > 1000000"
fi
if has_table DEPT; then
    # text group keys
    compare "text GROUP BY key" \
        "SELECT NAME, COUNT(ID) FROM DEPT GROUP BY NAME ORDER BY NAME" \
        "SELECT TRIM(NAME) || '|' || COUNT(ID) FROM DEPT GROUP BY NAME ORDER BY NAME"
fi
if has_table T; then
    # NULL keys form ONE group; SUM/COUNT skip NULL values inside it
    compare "NULL keys bucket together" \
        "SELECT A, COUNT(C), SUM(C) FROM T GROUP BY A ORDER BY A" \
        "SELECT COALESCE(CAST(A AS VARCHAR(12)),'<null>') || '|' || COUNT(C) || '|' || COALESCE(CAST(SUM(C) AS VARCHAR(12)),'<null>') FROM T GROUP BY A ORDER BY A"
fi
exit $fail
