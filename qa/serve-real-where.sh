#!/bin/sh
# The server filters rows with a WHERE clause. fire-crab, as a server,
# answers SELECT <cols>/COUNT(*) FROM <table> WHERE <predicate> from the
# pages: it walks the relation's records, decodes each, evaluates the
# predicate (comparisons =/<>/</<=/>/>= on integer and text columns,
# combined with AND/OR, plus IS [NOT] NULL) and returns only the matching
# rows. node-firebird drives it, and every result set must equal isql's.
#
#   qa/serve-real-where.sh <clean-db-path> [port]
#
# The battery runs against whichever of these tables the database has:
#   EMP(ID, DEPT_ID, SALARY, NAME), DEPT(ID, NAME)   - value/AND/OR/text
#   a table with nullable columns                    - IS [NOT] NULL
# Both sides are pipe-joined, strings trimmed, sorted, compared verbatim.
# Use a clean (gbak-restored) database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-where.sh <clean-db-path> [port]}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }
has_table() { [ "$(run_isql <<EOF | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='$1';
EOF
)" != "0" ]; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-where.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

# strip leading/trailing whitespace per line so isql's right-aligned
# integer columns compare equal to node's bare values (test data has no
# values with significant leading/trailing spaces).
strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

node_query_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" node -e '
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("ATTACH_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("QUERY_ERR "+e2.message);db.detach();process.exit(1);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}

# retry on a transient attach failure (occasional first-connect reset)
node_rows() {
    n=0
    while [ $n -lt 4 ]; do
        r=$(node_query_once "$1")
        case "$r" in
            ATTACH_ERR*) n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip | sort; return ;;
        esac
    done
    echo "ATTACH_ERR"
}

fail=0
compare() { # <label> <node-query> <isql-select-body>
    fc=$(node_rows "$2")
    is=$(run_isql <<EOF | strip | grep -v '^$' | sort
SET HEADING OFF;
$3;
EOF
)
    if [ "$fc" = "$is" ]; then
        echo "OK   $1 ($(printf '%s\n' "$fc" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$is" > /tmp/fc-where-is.txt; printf '%s\n' "$fc" > /tmp/fc-where-fc.txt
        diff /tmp/fc-where-is.txt /tmp/fc-where-fc.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

if has_table EMP; then
    compare "EMP =" \
      "SELECT ID, NAME FROM EMP WHERE ID = 5" \
      "SELECT ID || '|' || TRIM(NAME) FROM EMP WHERE ID = 5"
    compare "EMP >= AND <" \
      "SELECT ID FROM EMP WHERE ID >= 100 AND ID < 110" \
      "SELECT ID FROM EMP WHERE ID >= 100 AND ID < 110"
    compare "EMP <>" \
      "SELECT ID FROM EMP WHERE DEPT_ID <> 2" \
      "SELECT ID FROM EMP WHERE DEPT_ID <> 2"
    compare "EMP OR" \
      "SELECT ID FROM EMP WHERE ID = 1 OR ID = 2000" \
      "SELECT ID FROM EMP WHERE ID = 1 OR ID = 2000"
    compare "EMP AND-OR precedence" \
      "SELECT ID FROM EMP WHERE DEPT_ID = 2 AND ID < 25 OR ID = 500" \
      "SELECT ID FROM EMP WHERE DEPT_ID = 2 AND ID < 25 OR ID = 500"
    compare "EMP text =" \
      "SELECT ID FROM EMP WHERE NAME = 'emp 42'" \
      "SELECT ID FROM EMP WHERE NAME = 'emp 42'"
    compare "EMP lowercase kw" \
      "select ID from EMP where DEPT_ID = 3 and ID <= 44" \
      "SELECT ID FROM EMP WHERE DEPT_ID = 3 AND ID <= 44"
    compare "EMP COUNT(*) WHERE" \
      "SELECT COUNT(*) FROM EMP WHERE DEPT_ID = 2" \
      "SELECT COUNT(*) FROM EMP WHERE DEPT_ID = 2"
fi

if has_table DEPT; then
    compare "DEPT text >=" \
      "SELECT ID FROM DEPT WHERE NAME >= 'dept 5'" \
      "SELECT ID FROM DEPT WHERE NAME >= 'dept 5'"
fi

# IS [NOT] NULL against any user table that has a nullable column with NULLs
nulltab=$(run_isql <<'EOF' | awk 'NF==1 && $1!=""{print;exit}'
SET HEADING OFF;
SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS
WHERE COALESCE(RDB$SYSTEM_FLAG,0)=0 AND RDB$VIEW_BLR IS NULL AND RDB$RELATION_NAME='T';
EOF
)
if [ -n "$nulltab" ]; then
    compare "T IS NULL" \
      "SELECT A FROM T WHERE A IS NULL" \
      "SELECT COALESCE(CAST(A AS VARCHAR(12)),'<null>') FROM T WHERE A IS NULL"
    compare "T IS NOT NULL" \
      "SELECT A FROM T WHERE A IS NOT NULL" \
      "SELECT A FROM T WHERE A IS NOT NULL"
    compare "T int > with nulls" \
      "SELECT A FROM T WHERE A > 1" \
      "SELECT A FROM T WHERE A > 1"
fi

exit $fail
