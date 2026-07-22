#!/bin/sh
# The server answers INNER equi-joins. fire-crab, as a server, answers:
#   SELECT <cols|*> FROM t1 [a1] [INNER] JOIN t2 [a2]
#          ON <col> = <col> [AND ...] [WHERE ...] [ORDER BY ...]
#   SELECT COUNT(*) FROM t1 JOIN t2 ON ...          [WHERE ...]
# from the pages - both relations' committed records decoded, the ON
# equality pairs matched (NULL never joins), the combined rows filtered,
# sorted and projected through bare or table-qualified column names.
# node-firebird drives it and results must equal isql's.
#
#   qa/serve-real-join.sh <clean-db-path> [port]
#
# The battery expects the tables of the join scratch db:
#   DEPT(ID, REGION_ID, NAME)              - 8 rows, one with no employees
#   EMP(ID, DEPT_ID, REGION_ID, SALARY, NAME)
#     - 100 rows; NULL DEPT_IDs and a dangling DEPT_ID (no DEPT row),
#       both of which an INNER join must exclude
#   J1(K CHAR(10), V) / J2(K2 VARCHAR(10), W)
#     - text join keys incl. duplicates (mini cross products), NULLs and
#       CHAR-vs-VARCHAR trailing-blank padding
# Use a clean (gbak-restored) database.
# NOTE: never select two same-named columns (E.NAME + D.NAME) in one
# query - the engine titles both NAME and node-firebird keys rows by
# alias, so one clobbers the other client-side, against any server.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-join.sh <clean-db-path> [port]}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-join.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# rows in order (no sort), string values right-trimmed; zero rows print a
# sentinel (distinguishable from a transient failure, which is retried)
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
compare() { # <label> <node-query> <isql-select-body> [sorted]
    fc=$(node_ordered "$2")
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING OFF;
$3;
EOF
)
    [ -z "$is" ] && is="<no rows>"
    if [ "${4:-}" = "sorted" ]; then
        fc=$(printf '%s\n' "$fc" | sort)
        is=$(printf '%s\n' "$is" | sort)
    fi
    if [ "$fc" = "$is" ]; then
        echo "OK   $1 ($(printf '%s\n' "$fc" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$is" > /tmp/fc-jn-is.txt; printf '%s\n' "$fc" > /tmp/fc-jn-fc.txt
        diff /tmp/fc-jn-is.txt /tmp/fc-jn-fc.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

# the basic equi-join: NULL DEPT_IDs and the dangling DEPT_ID must drop out
compare "aliased equi-join" \
    "SELECT E.ID, D.NAME FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID" \
    "SELECT E.ID || '|' || TRIM(D.NAME) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID"
# qualified by table name, no aliases; ORDER BY ordinal
compare "table-name qualifiers" \
    "SELECT EMP.ID, DEPT.NAME FROM EMP JOIN DEPT ON EMP.DEPT_ID = DEPT.ID ORDER BY 1" \
    "SELECT EMP.ID || '|' || TRIM(DEPT.NAME) FROM EMP JOIN DEPT ON EMP.DEPT_ID = DEPT.ID ORDER BY EMP.ID"
# bare columns where unambiguous; ORDER BY a column that is NOT selected
compare "bare columns, unselected sort key" \
    "SELECT SALARY, DEPT_ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID" \
    "SELECT SALARY || '|' || DEPT_ID FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID"
# WHERE mixes columns of both sides on the combined row
compare "join + WHERE both sides" \
    "SELECT E.ID, D.NAME FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE SALARY > 3000 AND D.ID >= 2 ORDER BY E.ID" \
    "SELECT E.ID || '|' || TRIM(D.NAME) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE SALARY > 3000 AND D.ID >= 2 ORDER BY E.ID"
# two AND-ed ON equalities (NULL REGION_IDs must not join either)
compare "two-key ON" \
    "SELECT E.ID, D.NAME FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID AND E.REGION_ID = D.REGION_ID ORDER BY E.ID" \
    "SELECT E.ID || '|' || TRIM(D.NAME) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID AND E.REGION_ID = D.REGION_ID ORDER BY E.ID"
# COUNT(*) over a join, alone and with a WHERE
compare "COUNT(*) over join" \
    "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID" \
    "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID"
compare "COUNT(*) over join + WHERE" \
    "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID = 3" \
    "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID = 3"
# text keys: duplicates give mini cross products, NULLs never join, and
# the CHAR(10) key equals the VARCHAR key despite trailing blanks (bare
# ON operand: K2 is unambiguous)
compare "text-key join (CHAR vs VARCHAR)" \
    "SELECT V, W FROM J1 JOIN J2 ON J1.K = K2 ORDER BY V, W" \
    "SELECT V || '|' || W FROM J1 JOIN J2 ON J1.K = K2 ORDER BY V, W"
# SELECT * on a join: all left columns then all right, declared order
compare "SELECT * over join" \
    "SELECT * FROM J1 JOIN J2 ON J1.K = K2 ORDER BY V, W" \
    "SELECT TRIM(J1.K) || '|' || V || '|' || TRIM(K2) || '|' || W FROM J1 JOIN J2 ON J1.K = K2 ORDER BY V, W"
# lowercase, with the INNER keyword
compare "lowercase inner join" \
    "select e.id, d.name from emp e inner join dept d on e.dept_id = d.id where e.id <= 20 order by e.id" \
    "SELECT E.ID || '|' || TRIM(D.NAME) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE E.ID <= 20 ORDER BY E.ID"
# no ORDER BY: content equality, order not promised
compare "join without ORDER BY" \
    "SELECT E.ID, D.NAME FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID = 5" \
    "SELECT E.ID || '|' || TRIM(D.NAME) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID = 5" sorted
exit $fail
