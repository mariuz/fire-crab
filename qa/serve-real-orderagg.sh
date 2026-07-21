#!/bin/sh
# The server sorts (ORDER BY) and aggregates (MIN/MAX/SUM/COUNT). fire-crab,
# as a server, answers:
#   SELECT <cols> FROM <t> [WHERE ...] ORDER BY <cols|ordinals> [ASC|DESC]
#   SELECT MIN|MAX|SUM|COUNT(col)/COUNT(*) FROM <t> [WHERE ...]
# from the pages - collecting matching rows and sorting them (NULLs first
# ascending, as the engine does), or walking and accumulating the
# aggregate. node-firebird drives it and results must equal isql's.
#
#   qa/serve-real-orderagg.sh <clean-db-path> [port]
#
# ORDER BY results are compared IN ORDER (the point is the order), so the
# test queries sort by a total key (a unique column, or a multi-key ending
# in one). Aggregates compare a single value. Use a clean db.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-orderagg.sh <clean-db-path> [port]}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }
has_table() { [ "$(run_isql <<EOF | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='$1';
EOF
)" != "0" ]; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-orderagg.log 2>&1 &
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
compare() { # <label> <node-query> <isql-select-body>   (compared IN ORDER)
    fc=$(node_ordered "$2")
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING OFF;
$3;
EOF
)
    if [ "$fc" = "$is" ] && [ -n "$fc" ]; then
        echo "OK   $1 ($(printf '%s\n' "$fc" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$is" > /tmp/fc-oa-is.txt; printf '%s\n' "$fc" > /tmp/fc-oa-fc.txt
        diff /tmp/fc-oa-is.txt /tmp/fc-oa-fc.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

if has_table EMP; then
    # aggregates
    compare "MIN(SALARY)"       "SELECT MIN(SALARY) FROM EMP"                 "SELECT MIN(SALARY) FROM EMP"
    compare "MAX(ID)"           "SELECT MAX(ID) FROM EMP"                     "SELECT MAX(ID) FROM EMP"
    compare "SUM(DEPT_ID) WHERE" "SELECT SUM(DEPT_ID) FROM EMP WHERE ID <= 10" "SELECT SUM(DEPT_ID) FROM EMP WHERE ID <= 10"
    compare "COUNT(NAME)"       "SELECT COUNT(NAME) FROM EMP"                 "SELECT COUNT(NAME) FROM EMP"
    # ORDER BY (total keys)
    compare "ORDER BY ID DESC"  "SELECT ID FROM EMP ORDER BY ID DESC"        "SELECT ID FROM EMP ORDER BY ID DESC"
    # COALESCE keeps the isql concatenation from nulling the whole row on
    # a NULL DEPT_ID (node prints such a row as id|<null>)
    compare "ORDER BY 2 key"    "SELECT ID, DEPT_ID FROM EMP WHERE ID <= 30 ORDER BY DEPT_ID DESC, ID" \
                                "SELECT ID || '|' || COALESCE(CAST(DEPT_ID AS VARCHAR(12)),'<null>') FROM EMP WHERE ID <= 30 ORDER BY DEPT_ID DESC, ID"
    compare "ORDER BY text"     "SELECT NAME, ID FROM EMP WHERE ID <= 15 ORDER BY NAME, ID" \
                                "SELECT TRIM(NAME) || '|' || ID FROM EMP WHERE ID <= 15 ORDER BY NAME, ID"
fi
if has_table DEPT; then
    # fire-crab ORDER BY 1 = the 1st projected column (ID); isql ORDER BY 1
    # would order by the concatenated expression, so order by ID explicitly
    compare "DEPT ORDER BY ordinal" "SELECT ID, NAME FROM DEPT ORDER BY 1 DESC" \
                                    "SELECT ID || '|' || TRIM(NAME) FROM DEPT ORDER BY ID DESC"
fi
# NULL ordering (Firebird: NULLs first ASC, last DESC) on a nullable table
if has_table T; then
    compare "T ORDER BY A asc (nulls first)"  "SELECT A, C FROM T ORDER BY A, C" \
        "SELECT COALESCE(CAST(A AS VARCHAR(12)),'<null>') || '|' || COALESCE(CAST(C AS VARCHAR(12)),'<null>') FROM T ORDER BY A, C"
    compare "T ORDER BY A desc (nulls last)"  "SELECT A, C FROM T ORDER BY A DESC, C" \
        "SELECT COALESCE(CAST(A AS VARCHAR(12)),'<null>') || '|' || COALESCE(CAST(C AS VARCHAR(12)),'<null>') FROM T ORDER BY A DESC, C"
    compare "SUM(A) skips nulls"  "SELECT SUM(A) FROM T"  "SELECT COALESCE(CAST(SUM(A) AS VARCHAR(12)),'<null>') FROM T"
fi
exit $fail
