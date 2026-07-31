#!/bin/bash
# A VIEW used as a SIDE of a JOIN - against the REAL engine as a twin:
# the same driver, the same statement, two servers, two identical
# databases.
#
# A view was already expanded when it stood alone in the FROM: its name
# was swapped for its base table and its own WHERE was ANDed into the
# outer one. That rewrite is sound for one table and WRONG the moment
# there is a second, for two separate reasons, and this gate exists to
# hold both of them down.
#
#   1. WHERE the view's predicate goes depends on whether that side can
#      be NULL-PADDED. `DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID` must
#      keep every department, padding the ones with no qualifying
#      employee. Push `SALARY > 150` into the OUTER where and the padded
#      row - whose SALARY is NULL - is thrown away, and the LEFT join has
#      quietly become an inner one. The predicate belongs in that step's
#      ON, which is what filters the view's rows BEFORE the padding.
#      The fixture's department 3 has exactly one employee and that
#      employee is below the threshold, so this is the row that tells the
#      two placements apart - a fixture where every department either
#      qualifies or is empty would pass either way.
#
#   2. An UNALIASED view still owns its name as a qualifier: in
#      `FROM VEMP JOIN DEPT ON VEMP.DEPT_ID = DEPT.ID` the ON says VEMP,
#      not EMP. So the base table takes the VIEW's name as its alias, and
#      the substitution must happen in TABLE position only - a rewrite
#      that also renamed the qualifier produced `EMP VEMP.DEPT_ID`.
#
# The refusals are checked too, because each is a shape whose rewrite is
# not merely harder but different in kind: a view with RENAMED columns
# needs every reference rewritten rather than the table name; a view over
# a JOIN has no single base table to become; and a RIGHT or FULL join
# makes an EARLIER side nullable, so which side a predicate belongs to
# stops being a local question.
#
#   qa/serve-real-viewjoin.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4541}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-vjoin-crab.fdb"
B="$D/fc-vjoin-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# EMP 1 is below the view's threshold and shares its department with a
# row above it; EMP 4 is the ONLY employee of department 3 and is below
# it, so department 3 is padded by a LEFT join through the view and
# present through the base table; EMP 5 has a NULL key, which never
# joins; department 4 has no employees at all.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMP (ID INTEGER, DEPT_ID INTEGER, SALARY INTEGER, NAME VARCHAR(6));
CREATE TABLE DEPT (ID INTEGER, DNAME VARCHAR(6));
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 'a');
INSERT INTO EMP VALUES (2, 1, 200, 'b');
INSERT INTO EMP VALUES (3, 2, 300, 'c');
INSERT INTO EMP VALUES (4, 3,  50, 'd');
INSERT INTO EMP VALUES (5, NULL, 400, 'e');
INSERT INTO DEPT VALUES (1, 'one');
INSERT INTO DEPT VALUES (2, 'two');
INSERT INTO DEPT VALUES (3, 'three');
INSERT INTO DEPT VALUES (4, 'four');
COMMIT;
CREATE VIEW VEMP AS SELECT ID, DEPT_ID, SALARY, NAME FROM EMP WHERE SALARY > 150;
CREATE VIEW VDEPT AS SELECT ID, DNAME FROM DEPT;
CREATE VIEW VREN AS SELECT ID AS EID, DEPT_ID AS DID, NAME AS ENAME FROM EMP;
CREATE VIEW VJOIN AS
  SELECT E.ID, E.NAME, D.DNAME FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID;
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-viewjoin.log 2>&1 &
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

query() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(query "$2" "$PORT" "$A")
    case "$r" in
        ERR*) echo "OK   refused: $1" ;;
        *) echo "DIFF $1 answered: [$r]"; fail=1 ;;
    esac
}

# --- 0. the controls ---------------------------------------------------
# the view alone, and the join without one: if either of these moves the
# rest of the gate is measuring the wrong thing
both "the view alone" "SELECT COUNT(*) FROM VEMP"
both "the join without a view" \
     "SELECT COUNT(*) FROM EMP E JOIN DEPT D ON E.DEPT_ID = D.ID"

# --- 1. a view on either side of an INNER join -------------------------
both "a view on the LEFT" \
     "SELECT COUNT(*) FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID"
both "a view on the RIGHT" \
     "SELECT COUNT(*) FROM EMP E JOIN VDEPT V ON E.DEPT_ID = V.ID"
both "a view on BOTH sides" \
     "SELECT COUNT(*) FROM VEMP V JOIN VDEPT D ON V.DEPT_ID = D.ID"
both "and the rows, not just the count" \
     "SELECT V.ID, V.NAME FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID ORDER BY V.ID"

# --- 2. the UNALIASED view, which keeps its own name as a qualifier ----
both "an unaliased view in a join" \
     "SELECT COUNT(*) FROM VEMP JOIN DEPT ON VEMP.DEPT_ID = DEPT.ID"
both "... and its columns project" \
     "SELECT VEMP.ID FROM VEMP JOIN DEPT ON VEMP.DEPT_ID = DEPT.ID ORDER BY VEMP.ID"
both "... with a WHERE naming it" \
     "SELECT VEMP.ID FROM VEMP JOIN DEPT ON VEMP.DEPT_ID = DEPT.ID
      WHERE VEMP.SALARY > 250 ORDER BY VEMP.ID"
both "an unaliased view on the RIGHT" \
     "SELECT COUNT(*) FROM EMP E JOIN VDEPT ON E.DEPT_ID = VDEPT.ID"

# --- 3. the OUTER join, which is where the placement shows -------------
# department 3's only employee is below the view's threshold, so the
# padded row exists ONLY if the predicate was applied inside the join
both "a view on the PADDED side of a LEFT join" \
     "SELECT COUNT(*) FROM DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID"
both "... and the padding is visible" \
     "SELECT D.ID, V.ID FROM DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID ORDER BY D.ID, V.ID"
both "... the padded row's own column is NULL" \
     "SELECT D.ID, V.SALARY FROM DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID
      ORDER BY D.ID, V.SALARY"
both "a view on the PRESERVED side of a LEFT join" \
     "SELECT COUNT(*) FROM VEMP V LEFT JOIN DEPT D ON V.DEPT_ID = D.ID"
both "... and its rows" \
     "SELECT V.ID, D.ID FROM VEMP V LEFT JOIN DEPT D ON V.DEPT_ID = D.ID ORDER BY V.ID"
both "an extra ON condition beside the view's own" \
     "SELECT COUNT(*) FROM DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID AND V.SALARY > 250"
both "an outer join with a WHERE on the preserved side" \
     "SELECT COUNT(*) FROM DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID WHERE D.ID < 4"

# --- 4. the other join spellings ---------------------------------------
both "CROSS JOIN" "SELECT COUNT(*) FROM VEMP V CROSS JOIN DEPT D"
both "the comma list" "SELECT COUNT(*) FROM VEMP V, DEPT D WHERE V.DEPT_ID = D.ID"
both "a three-table chain through a view" \
     "SELECT COUNT(*) FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID
      JOIN DEPT D2 ON D2.ID = D.ID"
both "two views in one chain" \
     "SELECT COUNT(*) FROM VEMP V JOIN VDEPT D ON V.DEPT_ID = D.ID
      JOIN DEPT D2 ON D2.ID = D.ID"

# --- 5. what the rewritten query flows into ----------------------------
both "a WHERE on the view's own column" \
     "SELECT COUNT(*) FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID WHERE V.SALARY > 250"
both "a WHERE on the other side" \
     "SELECT COUNT(*) FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID WHERE D.ID = 1"
both "an aggregate over the join" \
     "SELECT SUM(V.SALARY), COUNT(*) FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID"
both "GROUP BY over the join" \
     "SELECT D.ID, COUNT(*) FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID
      GROUP BY D.ID ORDER BY D.ID"
both "GROUP BY with a HAVING" \
     "SELECT D.ID, COUNT(*) FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID
      GROUP BY D.ID HAVING COUNT(*) > 0 ORDER BY D.ID"
both "ORDER BY a view column" \
     "SELECT V.ID FROM VEMP V JOIN DEPT D ON V.DEPT_ID = D.ID ORDER BY V.SALARY DESC"

# --- 6. the refusals ---------------------------------------------------
# each of these is a rewrite of a different kind, not a harder one
refuses "a view with RENAMED columns in a join" \
        "SELECT COUNT(*) FROM VREN V JOIN DEPT D ON V.DID = D.ID"
refuses "a view over a JOIN" "SELECT COUNT(*) FROM VJOIN"
refuses "a view over a join, in a join" \
        "SELECT COUNT(*) FROM VJOIN V JOIN DEPT D ON V.ID = D.ID"
refuses "a RIGHT join with a view" \
        "SELECT COUNT(*) FROM DEPT D RIGHT JOIN VEMP V ON V.DEPT_ID = D.ID"
refuses "a FULL join with a view" \
        "SELECT COUNT(*) FROM DEPT D FULL JOIN VEMP V ON V.DEPT_ID = D.ID"

rm -f "$A" "$B"
# A COUNT of what actually ran: a mistyped helper name is a shell
# "command not found" that never touches `fail`.
if [ "$ran" -lt 32 ]; then
    echo "DIFF only $ran checks ran (expected at least 32) - did one silently skip?"
    fail=1
fi
exit $fail
