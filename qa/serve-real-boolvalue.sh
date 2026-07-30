#!/bin/bash
# A CONDITION used as a VALUE - `SELECT B AND C`, `SELECT ID > 2` -
# against the REAL engine as a twin: the same driver, the same statement,
# two servers, two identical databases.
#
# In Firebird every predicate is also an expression of type BOOLEAN, so
# the two grammars this server keeps apart - the WHERE parser and the
# select-list expression parser - meet in the select list. What makes it
# worth its own gate is that the values a condition takes are THREE, and
# the fold is Kleene's rather than the two-valued one a WHERE clause can
# get away with:
#
#   * `FALSE AND UNKNOWN` is FALSE, not UNKNOWN - a decided dominant
#     value wins. The fixture has a row with a NULL B and a FALSE C for
#     exactly that case, and its `B AND C` must come back FALSE.
#   * `TRUE OR UNKNOWN` is TRUE, symmetrically.
#   * `NOT UNKNOWN` is UNKNOWN.
#
#   A WHERE clause collapses all three of those to "row excluded", so
#   none of them is visible until the condition is a value. Every check
#   here therefore reads the VALUE, not a row count.
#
# The column NAME is a law too: every boolean-valued expression describes
# as BOOL, whatever produced it - `B AND C`, `ID > 2`, `NOT B`,
# `B IS NULL`, `ID BETWEEN 1 AND 2`, `ID IN (1, 2)`. A bare column keeps
# its own name, which it does by never becoming a condition in the select
# list.
#
#   qa/serve-real-boolvalue.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4485}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-bv-crab.fdb"
B="$D/fc-bv-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# row 3 is (NULL, FALSE) and row 4 is (TRUE, NULL): one for each half of
# the Kleene rule, so an implementation that answered NULL whenever an
# operand was NULL fails on row 3, and one that answered FALSE fails on 4
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, B BOOLEAN, C BOOLEAN, NAME VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, TRUE,  TRUE,  'aa');
INSERT INTO T VALUES (2, FALSE, TRUE,  'bb');
INSERT INTO T VALUES (3, NULL,  FALSE, 'cc');
INSERT INTO T VALUES (4, TRUE,  NULL,  'dd');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-boolvalue.log 2>&1 &
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
# every row, and the VALUE - the column name is compared too, which is
# how the BOOL naming law is checked without a separate probe
val() { # <expression>
    both "$1" "SELECT ID, $1 FROM T ORDER BY ID"
}
where() { # <label> <predicate>
    both "$1" "SELECT ID FROM T WHERE $2 ORDER BY ID"
}

# --- 1. the Kleene fold, which only a VALUE can show -------------------
val "B AND C"
val "B OR C"
val "NOT B"
val "B AND NOT C"
val "NOT (B OR C)"

# --- 2. any predicate is a value ---------------------------------------
val "ID > 2"
val "ID = 2"
val "ID <> 2"
val "B IS NULL"
val "B IS NOT NULL"
val "B = C"
val "NAME = 'aa'"
val "ID BETWEEN 2 AND 3"
val "ID NOT BETWEEN 2 AND 3"
val "ID IN (1, 2)"
val "ID NOT IN (1, 2)"

# --- 3. mixed, parenthesised, nested -----------------------------------
val "(ID > 2) AND B"
val "(ID > 2) OR (NAME = 'aa')"
val "B AND (ID > 1 OR C)"
val "NOT (ID BETWEEN 2 AND 3)"
# the parenthesised ARITHMETIC that must not be read as a group
val "(ID + 1) > 2"
val "(ID + 1) * 2"

# --- 4. a condition where a condition was already allowed --------------
# these went through the same parser before; they are here because the
# bare-boolean rule is new inside it
both "CASE WHEN a bare boolean" \
     "SELECT ID, CASE WHEN B THEN 1 ELSE 0 END FROM T ORDER BY ID"
both "IIF on a bare boolean" "SELECT ID, IIF(B, 1, 0) FROM T ORDER BY ID"
both "CASE WHEN a BETWEEN" \
     "SELECT ID, CASE WHEN ID BETWEEN 2 AND 3 THEN 'y' ELSE 'n' END FROM T ORDER BY ID"
both "IIF on an IN" "SELECT ID, IIF(ID IN (1, 4), 'y', 'n') FROM T ORDER BY ID"

# --- 5. the value flows on -------------------------------------------
both "ORDER BY a condition" "SELECT ID FROM T ORDER BY B AND C, ID"
both "GROUP BY a condition" \
     "SELECT B AND C, COUNT(*) FROM T GROUP BY B AND C ORDER BY 1"
both "a bare column keeps its OWN name" "SELECT B FROM T WHERE ID = 1"
both "and an aliased one takes the alias" "SELECT B AND C AS X FROM T WHERE ID = 1"

# --- 6. LIKE is a condition, so LIKE is a VALUE ------------------------
val "NAME LIKE 'a%'"
val "NAME NOT LIKE 'a%'"
val "NAME LIKE '_a'"
val "NAME LIKE 'A%'"
both "LIKE with an ESCAPE as a value" \
     "SELECT ID, NAME LIKE 'a#%' ESCAPE '#' FROM T ORDER BY ID"
val "B AND (NAME LIKE 'a%')"
val "NOT (NAME LIKE 'a%')"
both "LIKE inside a CASE condition" \
     "SELECT ID, CASE WHEN NAME LIKE 'a%' THEN 1 ELSE 0 END FROM T ORDER BY ID"
# ... and the WHERE clause's own LIKE is unchanged
both "LIKE still filters" "SELECT ID FROM T WHERE NAME LIKE 'a%' ORDER BY ID"
both "NOT LIKE still filters" "SELECT ID FROM T WHERE NAME NOT LIKE 'a%' ORDER BY ID"

# --- 7. a CONDITION as a comparison SIDE -------------------------------
# the other direction of the same duality: if a predicate is a value,
# then `(ID > 2) = TRUE` is a comparison between two booleans
where "a parenthesised condition against TRUE" "(ID > 2) = TRUE"
where "against FALSE" "(ID > 2) = FALSE"
where "a boolean comparison as a side" "(B = TRUE) = TRUE"
where "a LIKE as a side" "(NAME LIKE 'a%') = TRUE"
where "negated with <>" "(ID > 2) <> TRUE"
# a parenthesised group NOT followed by a comparison is still a group
where "an ordinary parenthesised group" "(ID > 1) AND (ID < 4)"
where "a group of boolean columns" "(B OR C) AND ID > 1"
where "and parenthesised ARITHMETIC is an operand" "(ID + 1) > 2"

# --- 8. the ordinary expressions are untouched -------------------------
both "arithmetic still parses as arithmetic" \
     "SELECT ID, ID + 1, ID - 1, ID * 2 FROM T ORDER BY ID"
both "and the WHERE grammar is unchanged" \
     "SELECT ID FROM T WHERE (ID + 1) > 2 AND NAME LIKE 'b%' ORDER BY ID"

# --- refusals ----------------------------------------------------------
# a non-boolean column is not a condition, in either grammar
ran=$((ran + 1))
r=$(query "SELECT CASE WHEN NAME THEN 1 ELSE 0 END FROM T" "$PORT" "$A")
case "$r" in
    ERR*) echo "OK   a text column is not a CASE condition" ;;
    *) echo "DIFF CASE WHEN NAME answered: [$r]"; fail=1 ;;
esac

rm -f "$A" "$B"
# A COUNT of what actually ran. A mistyped helper name is a shell
# "command not found" that does not touch `fail`, so eight checks once
# vanished from this gate while it still reported success. Counting them
# turns a silent skip into a visible failure.
if [ "$ran" -lt 51 ]; then
    echo "DIFF only $ran checks ran (expected at least 51) - did one silently skip?"
    fail=1
fi
exit $fail
