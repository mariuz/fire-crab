#!/bin/bash
# PREDICATE-SURFACE COMPLETION - the three refusals the fallible-fold
# slice left named:
#
#   CASE inside WHERE      the tokenizer lexes the CASE .. END SPAN by
#                          balancing the KEYWORDS (nested CASEs nest,
#                          an 'end' inside a string literal is skipped)
#                          and hands it to the expression parser whole
#   ? against expressions  WHERE UPPER(S) = ? claims its slot with a
#                          bind descriptor SYNTHESIZED from the
#                          expression's type (text -> VARCHAR, integer
#                          -> BIGINT, numeric -> BIGINT at the scale);
#                          at execute the arrived value substitutes as
#                          a literal and the term evaluates three-valued
#   expressions in JOINs   WHERE over a join takes expression sides
#                          against a synthetic combined-row view (bare
#                          unambiguous names; an ambiguous name refuses
#                          rather than guessing a side)
#
# THE DIFFERENTIAL: isql compares CASE and join shapes value for value;
# the parameter phase drives node-firebird (the reference third-party
# binder) through fire-crab and compares against the engine running the
# literal-substituted statement.
#
#   qa/serve-real-predfull.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4492}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-predfull.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE EMP (
  ID INTEGER NOT NULL PRIMARY KEY,
  DEPT_ID INTEGER,
  SAL INTEGER,
  NM VARCHAR(10),
  RATE NUMERIC(9,2)
);
CREATE TABLE DEPT (
  DID INTEGER NOT NULL PRIMARY KEY,
  DNAME VARCHAR(10),
  BUDGET INTEGER
);
COMMIT;
INSERT INTO EMP VALUES (1, 1, 100, 'ann', 12.50);
INSERT INTO EMP VALUES (2, 1, 200, 'bob', 1.25);
INSERT INTO EMP VALUES (3, 2, 50,  'cyd', -3.00);
INSERT INTO EMP VALUES (4, NULL, NULL, NULL, NULL);
INSERT INTO EMP VALUES (5, 2, 300, 'the end', 0.05);
INSERT INTO DEPT VALUES (1, 'eng', 500);
INSERT INTO DEPT VALUES (2, 'ops', 100);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-predfull.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

fail=0
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# --- CASE inside WHERE --------------------------------------------------
same "searched CASE as a filter"    "SELECT ID FROM EMP WHERE CASE WHEN SAL > 150 THEN 1 ELSE 0 END = 1 ORDER BY ID"
same "simple CASE as a filter"      "SELECT ID FROM EMP WHERE CASE DEPT_ID WHEN 1 THEN 'eng' ELSE 'other' END = 'eng' ORDER BY ID"
same "nested CASE in WHERE"         "SELECT ID FROM EMP WHERE CASE WHEN SAL > 100 THEN CASE WHEN SAL > 250 THEN 2 ELSE 1 END ELSE 0 END = 2 ORDER BY ID"
same "an 'end' inside a literal"    "SELECT ID FROM EMP WHERE CASE WHEN NM = 'the end' THEN 1 ELSE 0 END = 1 ORDER BY ID"
same "CASE beside classic terms"    "SELECT ID FROM EMP WHERE CASE WHEN SAL > 150 THEN 1 ELSE 0 END = 1 AND ID < 9 ORDER BY ID"
same "CASE with UNKNOWN rows"       "SELECT ID FROM EMP WHERE CASE WHEN SAL > 0 THEN 'y' ELSE 'n' END = 'y' ORDER BY ID"
same "CASE vs expression side"      "SELECT ID FROM EMP WHERE CASE WHEN SAL > 150 THEN SAL ELSE 0 END = SAL ORDER BY ID"

# --- expressions in JOIN predicates ------------------------------------
same "join + arithmetic WHERE"      "SELECT EMP.ID FROM EMP JOIN DEPT ON EMP.DEPT_ID = DEPT.DID WHERE SAL + BUDGET > 550 ORDER BY 1"
same "join + function WHERE"        "SELECT EMP.ID FROM EMP JOIN DEPT ON EMP.DEPT_ID = DEPT.DID WHERE UPPER(DNAME) = 'ENG' ORDER BY 1"
same "join + col-vs-col WHERE"      "SELECT EMP.ID FROM EMP JOIN DEPT ON EMP.DEPT_ID = DEPT.DID WHERE SAL > BUDGET ORDER BY 1"
same "join + CASE WHERE"            "SELECT EMP.ID FROM EMP JOIN DEPT ON EMP.DEPT_ID = DEPT.DID WHERE CASE WHEN BUDGET > 200 THEN 1 ELSE 0 END = 1 ORDER BY 1"
same "join + scaled arithmetic"     "SELECT EMP.ID FROM EMP JOIN DEPT ON EMP.DEPT_ID = DEPT.DID WHERE RATE * 2 > 2 ORDER BY 1"
same "outer join + expr WHERE"      "SELECT EMP.ID FROM EMP LEFT JOIN DEPT ON EMP.DEPT_ID = DEPT.DID WHERE COALESCE(BUDGET, 0) < 200 ORDER BY 1"

# --- ? against expression sides (node binds, engine runs literals) -----
strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" FC_PARAMS="${2:-[]}" \
    timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      const params=eval(process.env.FC_PARAMS);
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,params,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
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
        r=$(node_once "$1" "${2:-[]}")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}
en_lit() { # engine runs the literal-substituted statement
    printf 'SET HEADING OFF;\n%s;\n' "$1" |
        "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | strip | grep -v '^$' | tr '\n' '~'
}
bindcheck() { # <label> <fc-sql-with-?> <js-params> <engine-literal-sql>
    got=$(node_run "$2" "$3" | tr '\n' '~')
    want=$(en_lit "$4" | sed 's/  */|/g')
    # engine rows come back space-separated; normalise both to |
    got=$(printf '%s' "$got")
    if [ "$got" = "$want" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     want: $want"; echo "     got:  $got"; fail=1
    fi
}
bindcheck "text param vs UPPER"     "SELECT ID FROM EMP WHERE UPPER(NM) = ? ORDER BY ID" "['ANN']" "SELECT ID FROM EMP WHERE UPPER(NM) = 'ANN' ORDER BY ID"
bindcheck "int param vs arithmetic" "SELECT ID FROM EMP WHERE SAL + 1 = ? ORDER BY ID" "[101]" "SELECT ID FROM EMP WHERE SAL + 1 = 101 ORDER BY ID"
bindcheck "int param vs CHAR_LENGTH" "SELECT ID FROM EMP WHERE CHAR_LENGTH(NM) = ? ORDER BY ID" "[3]" "SELECT ID FROM EMP WHERE CHAR_LENGTH(NM) = 3 ORDER BY ID"
bindcheck "param vs CASE"           "SELECT ID FROM EMP WHERE CASE WHEN SAL > 150 THEN 1 ELSE 0 END = ? ORDER BY ID" "[1]" "SELECT ID FROM EMP WHERE CASE WHEN SAL > 150 THEN 1 ELSE 0 END = 1 ORDER BY ID"
bindcheck "param beside classics"   "SELECT ID FROM EMP WHERE UPPER(NM) = ? AND ID < 9 ORDER BY ID" "['BOB']" "SELECT ID FROM EMP WHERE UPPER(NM) = 'BOB' AND ID < 9 ORDER BY ID"
# a NULL parameter makes the comparison UNKNOWN - zero rows
got=$(node_run "SELECT ID FROM EMP WHERE UPPER(NM) = ? ORDER BY ID" "[null]")
if [ "$got" = "<no rows>" ]; then
    echo "OK   NULL param against an expression is UNKNOWN"
else
    echo "DIFF NULL param gave [$got], want <no rows>"; fail=1
fi

# --- teeth: the span lexer's two traps, pinned -------------------------
v=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM EMP WHERE CASE WHEN NM = %s THEN 1 ELSE 0 END = 1;\n' "'the end'" |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$v" = "1" ]; then
    echo "OK   teeth: a literal 'the end' does not close the CASE span"
else
    echo "DIFF the literal-end trap gave [$v], want 1"; fail=1
fi

exit $fail
