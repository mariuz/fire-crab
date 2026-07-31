#!/bin/bash
# THE WIDTH AND FORM OF A TEXT EXPRESSION - against the REAL engine as a
# twin: the same driver, the same statement, two servers, two identical
# databases.
#
# A text result is not just "some text". It has a declared WIDTH, and a
# CHAR-formed one PADS shorter values to it - so this decides a VALUE,
# not only a describe. fire-crab announced VARCHAR(32765) for every text
# expression and padded nothing, so `CASE WHEN ... THEN 'other' ELSE
# 'isnull' END` answered `'other'` where the engine answers `'other '`.
#
# The rules, probed with `SET SQLDA_DISPLAY ON` before any code:
#
#   'abc'                            -> TEXT(3)     a LITERAL is CHAR
#   CASE .. 'other' .. 'isnull' ..   -> TEXT(6)     the WIDEST branch
#   COALESCE('ab', 'cdef')           -> TEXT(4)
#   CASE .. NAME .. 'isnull' ..      -> VARYING(6)  one VARYING branch
#   COALESCE(NAME, 'zzzzzzzzzz')     -> VARYING(10)  makes it VARYING
#
# So: the WIDTH is the maximum over the branches, and the FORM is VARYING
# if ANY branch is varying, else CHAR - and only a CHAR result pads.
#
# The padding is applied by wrapping the expression in the CAST that
# already implements it, rather than by a second code path: `CAST(x AS
# CHAR(n))` has padded correctly since the CAST increment, and a law is
# better enforced once than twice.
#
# Every check compares a value whose padding is VISIBLE - the branches
# have DIFFERENT widths, so a result that is not padded to the widest one
# differs in the string itself. A fixture of equal-width branches would
# pass either way, which is exactly why the increment that found this law
# could not check it and said so instead.
#
#   qa/serve-real-textwidth2.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4549}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-tw-crab.fdb"
B="$D/fc-tw-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# a CHAR column and a VARCHAR column of the same width, so the FORM of a
# branch can be varied without varying its width
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V VARCHAR(6), C CHAR(6), W VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 'ab', 'ab', 'abc');
INSERT INTO T VALUES (2, 'abcdef', 'abcdef', 'abcdefghij');
INSERT INTO T VALUES (3, NULL, NULL, NULL);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-textwidth2.log 2>&1 &
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
              // the PADDING is the point, so nothing is trimmed and the
              // string is shown with its bounds
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

# fire-crab against ISQL, for shapes this driver cannot decode from the
# ENGINE (a CHAR column, or several text columns in one row, come back
# from the engine itself as `string right truncation`). The padding is
# still what is compared - isql prints the value at its declared width.
vs_isql() { # <label> <sql> <isql select body>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A" \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
             try{console.log(JSON.parse(s).map(r=>Object.values(r).map(v=>v===null?"<null>":String(v)).join("|")).join(" "))}
             catch(e){console.log("PARSE_ERR")}})' 2>/dev/null)
    b=$("$ISQL" -q -b -user "$U" -pas "$P" "$B" <<EOF 2>&1 | sed 's/[[:space:]]*$//' | grep -v '^$' | paste -sd' '
SET HEADING OFF;
$3;
EOF
)
    if [ "$a" = "$b" ] && [ -n "$a" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     isql:   $b"
        fail=1
    fi
}

# --- 1. a LITERAL is a CHAR -------------------------------------------
both "a bare literal" "SELECT 'abc' FROM T WHERE ID = 1"
both "two literals of different widths" "SELECT 'ab', 'abcd' FROM T WHERE ID = 1"
vs_isql "a literal beside a column, against isql" \
        "SELECT V || '#' || 'abcd' FROM T WHERE ID = 1" \
        "SELECT V || '#' || 'abcd' FROM T WHERE ID = 1"

# --- 2. a conditional takes its WIDEST branch -------------------------
# the branches differ in width, so an unpadded answer differs visibly
both "CASE over two literals" \
     "SELECT CASE WHEN 1=1 THEN 'ab' ELSE 'abcdef' END FROM T WHERE ID = 1"
both "... the other branch taken" \
     "SELECT CASE WHEN 1=0 THEN 'ab' ELSE 'abcdef' END FROM T WHERE ID = 1"
both "a simple CASE" \
     "SELECT CASE ID WHEN 1 THEN 'ab' ELSE 'abcdef' END FROM T WHERE ID = 1"
both "three branches" \
     "SELECT CASE ID WHEN 1 THEN 'a' WHEN 2 THEN 'ab' ELSE 'abcdefg' END FROM T ORDER BY ID"
both "no ELSE: the unmatched row is NULL" \
     "SELECT ID, CASE ID WHEN 1 THEN 'ab' WHEN 2 THEN 'abcdef' END FROM T ORDER BY ID"
both "IIF over two literals" "SELECT IIF(ID = 1, 'ab', 'abcdef') FROM T ORDER BY ID"
both "COALESCE over two literals" "SELECT COALESCE('ab', 'cdef') FROM T WHERE ID = 1"
both "DECODE over literals of different widths" \
     "SELECT DECODE(ID, 1, 'ab', 'abcdef') FROM T ORDER BY ID"

# --- 3. one VARYING branch makes the whole thing VARYING --------------
both "CASE with a VARCHAR branch" \
     "SELECT CASE WHEN 1=1 THEN V ELSE 'abcdef' END FROM T WHERE ID = 1"
both "... with the literal branch taken" \
     "SELECT CASE WHEN 1=0 THEN V ELSE 'abcdef' END FROM T WHERE ID = 1"
both "COALESCE over a column and a wider literal" \
     "SELECT COALESCE(V, 'zzzzzzzzzz') FROM T ORDER BY ID"
both "COALESCE where the column is NULL" \
     "SELECT COALESCE(V, 'zzzzzzzzzz') FROM T WHERE ID = 3"
both "IIF with a VARCHAR branch" "SELECT IIF(ID = 1, V, 'abcdef') FROM T ORDER BY ID"

# --- 4. a CHAR COLUMN branch, which is padded by storage --------------
vs_isql "a CHAR column alone, against isql" \
        "SELECT C || '#' FROM T ORDER BY ID" "SELECT C || '#' FROM T ORDER BY ID"
both "CASE over a CHAR column and a literal" \
     "SELECT CASE WHEN 1=1 THEN C ELSE 'ab' END FROM T WHERE ID = 1"
vs_isql "COALESCE over CHAR and VARCHAR columns, against isql" \
        "SELECT COALESCE(C, V) || '#' FROM T ORDER BY ID" \
        "SELECT COALESCE(C, V) || '#' FROM T ORDER BY ID"
vs_isql "a CHAR and a VARCHAR of the same width, against isql" \
        "SELECT C || '#' || V || '#' FROM T WHERE ID = 1" \
        "SELECT C || '#' || V || '#' FROM T WHERE ID = 1"

# --- 5. what the widened value flows into -----------------------------
both "concatenated with a literal" \
     "SELECT CASE WHEN 1=1 THEN 'ab' ELSE 'abcdef' END || 'X' FROM T WHERE ID = 1"
both "compared in a WHERE" \
     "SELECT COUNT(*) FROM T WHERE CASE WHEN 1=1 THEN 'ab' ELSE 'abcdef' END = 'ab'"
both "as an ORDER BY key" \
     "SELECT ID FROM T ORDER BY CASE ID WHEN 1 THEN 'b' ELSE 'aaaa' END, ID"
both "CAST over a conditional" \
     "SELECT CAST(CASE WHEN 1=1 THEN 'ab' ELSE 'abcdef' END AS VARCHAR(8)) FROM T WHERE ID = 1"
both "an explicit CAST to CHAR still pads" \
     "SELECT CAST(V AS CHAR(9)) FROM T WHERE ID = 1"
both "an explicit CAST to VARCHAR does not" \
     "SELECT CAST(V AS VARCHAR(9)) FROM T WHERE ID = 1"

# --- 6. the shapes with NO statically known width ---------------------
# a function's result width is not derived here, so these keep the
# catch-all declaration - they are checked to show they did not move
vs_isql "UPPER of a column, against isql" \
        "SELECT UPPER(V) || '#' FROM T ORDER BY ID" "SELECT UPPER(V) || '#' FROM T ORDER BY ID"
vs_isql "TRIM of a CHAR column, against isql" \
        "SELECT TRIM(C) || '#' FROM T ORDER BY ID" "SELECT TRIM(C) || '#' FROM T ORDER BY ID"
vs_isql "a concatenation of columns, against isql" \
        "SELECT V || W || '#' FROM T WHERE ID = 1" "SELECT V || W || '#' FROM T WHERE ID = 1"
vs_isql "a plain VARCHAR column, against isql" \
        "SELECT V || '#' FROM T ORDER BY ID" "SELECT V || '#' FROM T ORDER BY ID"

rm -f "$A" "$B"
if [ "$ran" -lt 29 ]; then
    echo "DIFF only $ran checks ran (expected at least 29) - did one silently skip?"
    fail=1
fi
exit $fail
