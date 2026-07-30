#!/bin/bash
# COLUMN ALIASES in the select list - `SELECT NAME AS X` - against the
# REAL engine as a twin: the same driver, the same statement, two
# servers, two identical databases.
#
# An alias is the only part of a result a client is guaranteed to key on,
# and it had been dropped for the one item type where it is most often
# written: a plain COLUMN. `SELECT NAME AS X` described the column as
# NAME, `SELECT NAME X` (no AS) refused outright, and an aggregate with
# an alias (`SELECT COUNT(*) AS N`) refused too - the alias was split off
# AFTER the aggregate parser had already failed on the whole text.
# Expressions honoured their aliases, which is what made the gap easy to
# miss: the shape people test first was the shape that worked.
#
# Nothing here is about values. Every check compares the KEYS of the
# returned objects, which is what a driver builds from the describe:
#
#   1. `AS X` and a bare trailing `X` on a column, an expression, an
#      aggregate and a grouped column.
#   2. A quoted alias keeps its case; an unquoted one folds up, the way
#      every unquoted identifier does.
#   3. Two items over the SAME column with different aliases are TWO
#      output columns - the case that catches a rename done by lookup
#      rather than positionally.
#   4. `ORDER BY <alias>` and `GROUP BY <alias>`: the engine resolves an
#      alias in both, and a real column of that name wins over one.
#   5. An unaliased item keeps the name it had - a column its own, an
#      aggregate its function, an expression its default.
#
#   qa/serve-real-colalias.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4495}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-alias-crab.fdb"
B="$D/fc-alias-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NAME VARCHAR(10), AMT NUMERIC(9,2), G INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 'aa', 10.50, 1);
INSERT INTO T VALUES (2, 'bb', 20.25, 1);
INSERT INTO T VALUES (3, 'cc', 5.00,  2);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-colalias.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

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

# --- 1. AS, and the bare trailing alias --------------------------------
both "a column with AS" "SELECT NAME AS X FROM T WHERE ID = 1"
both "a column with a BARE alias" "SELECT NAME X FROM T WHERE ID = 1"
both "two columns, two aliases" "SELECT ID AS X, NAME AS Y FROM T WHERE ID = 1"
both "one aliased, one not" "SELECT ID AS X, NAME FROM T WHERE ID = 1"
both "an expression with AS" "SELECT ID + 1 AS X FROM T WHERE ID = 1"
both "an expression with a bare alias" "SELECT ID + 1 X FROM T WHERE ID = 1"
both "an aggregate with AS" "SELECT COUNT(*) AS N FROM T"
both "two aggregates, two aliases" "SELECT SUM(AMT) AS S, COUNT(*) AS N FROM T"
both "an aggregate with a bare alias" "SELECT COUNT(*) N FROM T"
both "a scaled numeric column" "SELECT AMT AS A FROM T WHERE ID = 1"
both "a boolean-valued expression" "SELECT ID > 2 AS X FROM T WHERE ID = 1"

# --- 2. quoting decides the case ---------------------------------------
both "a quoted alias keeps its case" 'SELECT NAME AS "x" FROM T WHERE ID = 1'
both "an unquoted one folds up" "SELECT NAME AS x FROM T WHERE ID = 1"
both "a quoted alias with a space" 'SELECT NAME AS "my col" FROM T WHERE ID = 1'

# --- 3. the same column twice ------------------------------------------
both "two aliases over ONE column are two columns" \
     "SELECT ID AS ID2, ID AS ID3 FROM T WHERE ID = 1"
both "and one of them unaliased" "SELECT ID, ID AS ID3 FROM T WHERE ID = 1"

# --- 4. ORDER BY and GROUP BY resolve an alias -------------------------
both "ORDER BY an alias" "SELECT ID AS X FROM T ORDER BY X"
both "ORDER BY an alias, descending" "SELECT ID AS X FROM T ORDER BY X DESC"
both "ORDER BY a column beside an alias" \
     "SELECT ID AS X, NAME FROM T ORDER BY NAME, X"
both "GROUP BY an alias" "SELECT G AS X, COUNT(*) FROM T GROUP BY X ORDER BY 1"
both "GROUP BY the column, ORDER BY the alias" \
     "SELECT G AS X, COUNT(*) FROM T GROUP BY G ORDER BY X"
both "GROUP BY an alias over an EXPRESSION" \
     "SELECT UPPER(NAME) AS U, COUNT(*) FROM T GROUP BY U ORDER BY 1"
# a real column of that name wins over an alias, which is what makes a
# shadowing alias harmless
both "a shadowing alias does not steal the ORDER BY" \
     "SELECT ID AS NAME, NAME AS ID FROM T ORDER BY NAME"

# --- 5. the unaliased names are unchanged ------------------------------
both "a plain column keeps its own name" "SELECT ID, NAME FROM T WHERE ID = 1"
both "an aggregate keeps its function name" "SELECT COUNT(*), SUM(AMT) FROM T"
both "an expression keeps its default name" "SELECT ID + 1 FROM T WHERE ID = 1"
both "SELECT * is unchanged" "SELECT * FROM T WHERE ID = 1"
both "a grouped column keeps its name" \
     "SELECT G, COUNT(*) FROM T GROUP BY G ORDER BY 1"

# --- refusals ----------------------------------------------------------
# a bare alias must not swallow a shape this parser does not know: three
# space-separated identifiers are not "expression alias"
for bad in "SELECT ID NAME AMT FROM T" "SELECT AS X FROM T"; do
    a=$(query "$bad" "$PORT" "$A")
    b=$(query "$bad" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   [$bad] is refused by both" ;;
        *) echo "DIFF [$bad]: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done

rm -f "$A" "$B"
exit $fail
