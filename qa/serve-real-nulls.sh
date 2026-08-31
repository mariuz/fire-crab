#!/bin/bash
# Where NULL sits: the ordering clause and the null-safe comparison, both
# checked against the REAL engine as a twin (the same driver, the same
# statement, two servers, two identical databases).
#
#   1. ORDER BY's default null placement. It is not "first" or "last" - it
#      is LOW: NULLs sort below every value, so they come FIRST ascending
#      and LAST descending. Probed, and the reason `NULLS FIRST` is not a
#      no-op on a descending key.
#   2. `NULLS FIRST` / `NULLS LAST`, which state a POSITION that does not
#      flip with the direction - so the four combinations are four
#      different orders, and a converter that treats the clause as
#      "reverse the default" gets two of them wrong.
#   3. `IS [NOT] DISTINCT FROM`, the null-safe comparison: NULL is a VALUE
#      to it. `A IS DISTINCT FROM 5` returns the NULL rows, which is what
#      makes it different from `A <> 5` - and different from
#      `NOT (A = 5)`, which drops them.
#
#   qa/serve-real-nulls.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666 so
# the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4345}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-nulls-crab.fdb"
B="$D/fc-nulls-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NAME VARCHAR(10), OTHER INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10, 'a', 10);
INSERT INTO T VALUES (2, NULL, 'b', 7);
INSERT INTO T VALUES (3, 5, NULL, NULL);
INSERT INTO T VALUES (4, NULL, 'd', NULL);
INSERT INTO T VALUES (5, 5, 'e', 5);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nulls.log 2>&1 &
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
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
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

# --- 1. the DEFAULT placement: NULLs are LOW ---------------------------
both "ORDER BY asc puts NULLs FIRST" "SELECT ID FROM T ORDER BY AMT, ID"
both "ORDER BY desc puts NULLs LAST" "SELECT ID FROM T ORDER BY AMT DESC, ID"

# --- 2. the four explicit combinations ---------------------------------
both "asc NULLS LAST" "SELECT ID FROM T ORDER BY AMT NULLS LAST, ID"
both "asc NULLS FIRST" "SELECT ID FROM T ORDER BY AMT NULLS FIRST, ID"
both "desc NULLS FIRST" "SELECT ID FROM T ORDER BY AMT DESC NULLS FIRST, ID"
both "desc NULLS LAST" "SELECT ID FROM T ORDER BY AMT DESC NULLS LAST, ID"
both "a second key carries its own placement" \
     "SELECT ID FROM T ORDER BY AMT NULLS LAST, OTHER DESC NULLS FIRST, ID"
both "the placement applies to a text column too" \
     "SELECT ID FROM T ORDER BY NAME NULLS LAST, ID"
both "ORDER BY an ordinal with NULLS LAST" "SELECT AMT, ID FROM T ORDER BY 1 NULLS LAST, 2"

# --- ORDER BY <expression> ---------------------------------------------
# the key is computed per row, so it can be arithmetic, a call or a CASE -
# and it carries the same direction and NULLS clauses a column key does
both "ORDER BY arithmetic" "SELECT ID FROM T ORDER BY AMT + 1, ID"
both "ORDER BY a CASE (the null-first idiom)" \
     "SELECT ID FROM T ORDER BY CASE WHEN AMT IS NULL THEN 1 ELSE 0 END, ID"
both "ORDER BY a function call with a NULLS clause" \
     "SELECT ID FROM T ORDER BY UPPER(NAME) NULLS LAST, ID"
both "ORDER BY an expression, DESC and NULLS LAST" \
     "SELECT ID FROM T ORDER BY AMT * 2 DESC NULLS LAST, ID"
both "an expression key beside a column key" \
     "SELECT ID FROM T ORDER BY OTHER DESC, AMT + OTHER NULLS FIRST, ID"

# --- 3. IS [NOT] DISTINCT FROM -----------------------------------------
both "IS DISTINCT FROM a value keeps the NULL rows" \
     "SELECT ID FROM T WHERE AMT IS DISTINCT FROM 5 ORDER BY ID"
both "IS NOT DISTINCT FROM a value" \
     "SELECT ID FROM T WHERE AMT IS NOT DISTINCT FROM 5 ORDER BY ID"
both "IS DISTINCT FROM NULL is IS NOT NULL" \
     "SELECT ID FROM T WHERE AMT IS DISTINCT FROM NULL ORDER BY ID"
both "IS NOT DISTINCT FROM NULL is IS NULL" \
     "SELECT ID FROM T WHERE AMT IS NOT DISTINCT FROM NULL ORDER BY ID"
both "column against column, NULL = NULL" \
     "SELECT ID FROM T WHERE AMT IS NOT DISTINCT FROM OTHER ORDER BY ID"
both "column against column, negated" \
     "SELECT ID FROM T WHERE AMT IS DISTINCT FROM OTHER ORDER BY ID"
both "a column against ITSELF is never distinct" \
     "SELECT ID FROM T WHERE NAME IS NOT DISTINCT FROM NAME ORDER BY ID"

# and the discriminator: the plain operators are NOT the same predicate
both "<> drops the NULL rows where IS DISTINCT FROM keeps them" \
     "SELECT ID FROM T WHERE AMT <> 5 ORDER BY ID"
both "NOT (=) drops them too" \
     "SELECT ID FROM T WHERE NOT (AMT = 5) ORDER BY ID"

# --- refusals ----------------------------------------------------------
r=$(query "SELECT ID FROM T ORDER BY AMT NULLS SIDEWAYS" "$PORT" "$A")
case "$r" in
    ERR*) echo "OK   a bad NULLS position is refused, not guessed" ;;
    *) echo "DIFF NULLS SIDEWAYS answered: [$r]"; fail=1 ;;
esac
# an ORDER BY expression this server cannot resolve refuses the statement
# rather than sorting by something else
r=$(query "SELECT ID FROM T ORDER BY NOSUCH(AMT)" "$PORT" "$A")
case "$r" in
    ERR*) echo "OK   an unresolvable ORDER BY expression is refused" ;;
    *) echo "DIFF unknown ORDER BY function answered: [$r]"; fail=1 ;;
esac

# --- a NULL-valued RIGHT SIDE is NULL however it is spelled -------------
# `IS [NOT] DISTINCT FROM` was desugared to IS NULL / IS NOT NULL only for
# a BARE NULL token. Parenthesise it - `IS DISTINCT FROM (NULL)` - or cast
# it, and the rewrite did not fire; the predicate fell through to the
# ordinary value comparison and came back EXACTLY INVERTED, returning the
# NULL rows where the engine returns the others. That is the quiet kind of
# wrong answer: any query builder that wraps its operands in parentheses
# had its NULL-matching silently reversed, with no error anywhere.
both "IS DISTINCT FROM (NULL)" \
    "SELECT ID FROM T WHERE AMT IS DISTINCT FROM (NULL) ORDER BY ID"
both "IS NOT DISTINCT FROM (NULL)" \
    "SELECT ID FROM T WHERE AMT IS NOT DISTINCT FROM (NULL) ORDER BY ID"
both "IS DISTINCT FROM a CAST NULL" \
    "SELECT ID FROM T WHERE AMT IS DISTINCT FROM CAST(NULL AS INTEGER) ORDER BY ID"
both "IS NOT DISTINCT FROM a parenthesised CAST NULL" \
    "SELECT ID FROM T WHERE AMT IS NOT DISTINCT FROM (CAST(NULL AS INTEGER)) ORDER BY ID"
both "a text CAST NULL" \
    "SELECT ID FROM T WHERE NAME IS NOT DISTINCT FROM CAST(NULL AS VARCHAR(10)) ORDER BY ID"
# the controls: neither parentheses alone nor a NULL alone is the trigger
both "control: a bare NULL" \
    "SELECT ID FROM T WHERE AMT IS DISTINCT FROM NULL ORDER BY ID"
both "control: a bare NULL under NOT" \
    "SELECT ID FROM T WHERE AMT IS NOT DISTINCT FROM NULL ORDER BY ID"
both "control: parenthesised NON-null" \
    "SELECT ID FROM T WHERE AMT IS DISTINCT FROM (5) ORDER BY ID"
both "control: parenthesised NON-null under NOT" \
    "SELECT ID FROM T WHERE AMT IS NOT DISTINCT FROM (5) ORDER BY ID"

# --- a correlated subquery answers per OUTER ROW, or it refuses ---------
# An EXISTS whose correlation this server cannot express used to fall back
# to evaluating the subquery as UNCORRELATED and pushing ONE verdict for
# every row. Only EQUALITY pairs are recognised as a correlation, so the
# two commonest inequality idioms answered nonsense with no error:
#
#   NOT EXISTS (SELECT 1 FROM t x WHERE x.id > t.id)   -- "the last row"
#       answered EVERY row instead of one
#   (SELECT COUNT(*) FROM t x WHERE x.id < t.id)       -- a running count
#       answered 0 for every row
#
# They REFUSE now, which is a boundary rather than a wrong answer. The
# equality forms below must keep ANSWERING - the refusal must not have
# been bought by giving up the shapes that worked.
both "correlated EXISTS on equality" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T X WHERE X.AMT = T.AMT) ORDER BY ID"
both "correlated NOT EXISTS on equality" \
    "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM T X WHERE X.ID = T.ID) ORDER BY ID"
both "an uncorrelated EXISTS still folds" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T WHERE AMT = 10) ORDER BY ID"
both "an uncorrelated NOT EXISTS over no rows" \
    "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM T WHERE AMT = 999) ORDER BY ID"

# the recorded boundary: it must REFUSE, and must never answer a constant
ran_boundary() { # <label> <sql>
    local r
    r=$(query "$2" "$PORT" "$A")
    case "$r" in
        ERR*) echo "OK   refuses cleanly (recorded boundary): $1" ;;
        *) echo "DIFF $1 ANSWERED [$r] - an unexpressible correlation must refuse,"
           echo "     never fold to one verdict for every row. If this now answers,"
           echo "     check it against the engine and move it into the block above."
           fail=1 ;;
    esac
}
ran_boundary "NOT EXISTS with an inequality correlation" \
    "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM T X WHERE X.ID > T.ID) ORDER BY ID"
ran_boundary "EXISTS with an inequality correlation" \
    "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T X WHERE X.ID > T.ID) ORDER BY ID"

rm -f "$A" "$B"
exit $fail
