#!/bin/bash
# The server answers OUTER equi-joins. fire-crab, as a server, answers:
#   FROM t1 [a] LEFT|RIGHT|FULL [OUTER] JOIN t2 [b] ON <col> = <col> [AND ...]
#        [WHERE ...] [ORDER BY ...],  plus a lone COUNT(*) over any of them
# from the pages: partnerless preserved-side rows are emitted once with
# the other side NULL-padded, and the WHERE filter runs on the PADDED
# row - SQL's join-then-filter order, which is what makes
# `WHERE <right col> IS NULL` on a LEFT join the classic anti-join.
# node-firebird drives fire-crab; isql answers the same queries from the
# same file; results must be identical. NULL join keys never match (so
# they surface as padded rows), text keys stay pad-insensitive, and a
# non-empty anti-join is asserted so the outer path is provably
# exercised, not vacuously green.
#
#   qa/serve-real-outerjoin.sh <clean-db-path> [port]
#
# Expects the join scratch db: EMP(ID, DEPT_ID, REGION_ID, SALARY, NAME)
# with NULL and dangling DEPT_IDs, DEPT(ID, REGION_ID, NAME) with one
# department no employee references, J1(K CHAR)/J2(K2 VARCHAR) with
# duplicate and NULL keys.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-outerjoin.sh <clean-db-path> [port]}"
PORT="${2:-4056}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-outerjoin.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

node_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("CONN_ERR");db.detach();process.exit(1);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
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

isql_q() { # one query; rows as col|col|..., NULL as <null>, no blank lines
    printf 'SET HEADING OFF;\n%s\n' "$1" | run_isql | strip | grep -v '^$'
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     want: $3"
        echo "     got:  $2"
        fail=1
    fi
}

# LEFT: every EMP kept, missing/dangling departments NULL-padded.
# NOTE (from the INNER-join gate): node-firebird keys row objects by
# column TITLE, so selecting two columns with the same name (E.ID+D.ID,
# E.NAME+D.NAME) loses one CLIENT-side against any server - the queries
# here select title-distinct columns (SALARY identifies an EMP uniquely).
check "LEFT JOIN, ordered" \
    "$(node_run "SELECT E.ID, E.SALARY, D.NAME FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID")" \
    "$(isql_q "SELECT E.ID || '|' || E.SALARY || '|' || COALESCE(TRIM(D.NAME),'<null>') FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.ID;")"
check "COUNT over LEFT JOIN" \
    "$(node_run "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID")" \
    "$(isql_q "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID;" | tr -d ' ')"

# the anti-join: WHERE on the padded right side, and it must be non-empty
anti=$(node_run "SELECT E.ID FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID IS NULL ORDER BY E.ID")
check "anti-join (WHERE right IS NULL)" "$anti" \
    "$(isql_q "SELECT E.ID FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID WHERE D.ID IS NULL ORDER BY E.ID;" | tr -d ' ')"
if [ "$anti" = "<no rows>" ] || [ -z "$anti" ]; then
    echo "DIFF anti-join is non-empty (outer path exercised)"; fail=1
else
    echo "OK   anti-join is non-empty (outer path exercised)"
fi

# WHERE on a left column still filters padded rows like any others
check "LEFT JOIN + WHERE on left col" \
    "$(node_run "SELECT E.ID, D.NAME FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID WHERE E.ID > 90 ORDER BY E.ID")" \
    "$(isql_q "SELECT E.ID || '|' || COALESCE(TRIM(D.NAME),'<null>') FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID WHERE E.ID > 90 ORDER BY E.ID;")"

# RIGHT: every DEPT kept - the department nobody references gets NULL emps
check "RIGHT JOIN, ordered" \
    "$(node_run "SELECT D.ID, D.NAME, E.SALARY FROM EMP E RIGHT JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY D.ID, E.SALARY")" \
    "$(isql_q "SELECT D.ID || '|' || TRIM(D.NAME) || '|' || COALESCE(CAST(E.SALARY AS VARCHAR(12)),'<null>') FROM EMP E RIGHT JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY D.ID, E.SALARY;")"
check "COUNT over RIGHT JOIN" \
    "$(node_run "SELECT COUNT(*) FROM EMP E RIGHT JOIN DEPT D ON E.DEPT_ID = D.ID")" \
    "$(isql_q "SELECT COUNT(*) FROM EMP E RIGHT JOIN DEPT D ON E.DEPT_ID = D.ID;" | tr -d ' ')"

# FULL: both sides preserved; lowercase + explicit OUTER keyword
check "FULL OUTER JOIN, ordered" \
    "$(node_run "select E.SALARY, D.NAME from EMP E full outer join DEPT D on E.DEPT_ID = D.ID order by E.SALARY, D.NAME")" \
    "$(isql_q "SELECT COALESCE(CAST(E.SALARY AS VARCHAR(12)),'<null>') || '|' || COALESCE(TRIM(D.NAME),'<null>') FROM EMP E FULL OUTER JOIN DEPT D ON E.DEPT_ID = D.ID ORDER BY E.SALARY, D.NAME;")"
check "COUNT over FULL JOIN" \
    "$(node_run "SELECT COUNT(*) FROM EMP E FULL JOIN DEPT D ON E.DEPT_ID = D.ID")" \
    "$(isql_q "SELECT COUNT(*) FROM EMP E FULL JOIN DEPT D ON E.DEPT_ID = D.ID;" | tr -d ' ')"

# two-key LEFT: both equalities must hold for a match
check "two-key LEFT JOIN" \
    "$(node_run "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID AND E.REGION_ID = D.REGION_ID")" \
    "$(isql_q "SELECT COUNT(*) FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID AND E.REGION_ID = D.REGION_ID;" | tr -d ' ')"
check "two-key anti-join rows" \
    "$(node_run "SELECT E.ID FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID AND E.REGION_ID = D.REGION_ID WHERE D.ID IS NULL ORDER BY E.ID")" \
    "$(isql_q "SELECT E.ID FROM EMP E LEFT JOIN DEPT D ON E.DEPT_ID = D.ID AND E.REGION_ID = D.REGION_ID WHERE D.ID IS NULL ORDER BY E.ID;" | tr -d ' ')"

# CHAR vs VARCHAR keys with NULLs and duplicates: NULL keys pad, text
# keys compare pad-insensitively; sorted in the shell (duplicate keys
# make row order within ties unspecified on both sides)
check "text-key LEFT JOIN (CHAR = VARCHAR, NULL keys pad)" \
    "$(node_run "SELECT J1.K, J1.V, J2.W FROM J1 LEFT JOIN J2 ON J1.K = J2.K2" | sort)" \
    "$(isql_q "SELECT COALESCE(TRIM(J1.K),'<null>') || '|' || J1.V || '|' || COALESCE(CAST(J2.W AS VARCHAR(12)),'<null>') FROM J1 LEFT JOIN J2 ON J1.K = J2.K2;" | sort)"

# unsupported shapes still FALL BACK (the fixed scalar), never wrong rows
check "CROSS JOIN falls back" \
    "$(node_run "SELECT COUNT(*) FROM EMP E CROSS JOIN DEPT D")" "4242"
exit $fail
