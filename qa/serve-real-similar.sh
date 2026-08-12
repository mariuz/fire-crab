#!/bin/bash
# SIMILAR TO - the SQL:2008 regular-expression predicate.
#
#   <text> [NOT] SIMILAR TO <pattern> [ESCAPE <char>]
#
# The pattern is an ANCHORED regular expression (the whole string must
# match), case-sensitive. Metacharacters: `|` (alternation), `* + ?`
# and `{m}`/`{m,}`/`{m,n}` (quantifiers), `()` (grouping), `[...]`
# (character class, with ranges `a-z`, POSIX classes `[:ALPHA:]` etc. and
# negation `[^...]`), `_` (any one character), `%` (any sequence); a `.`
# is a LITERAL here, and the ESCAPE character turns the next metacharacter
# literal. A NULL value is UNKNOWN (never matches, under NOT either).
#
# fire-crab compiles the literal pattern to a small regex tree at prepare
# (a malformed pattern refuses there, as the engine raises) and matches
# per row. node-firebird drives fire-crab and the live engine with the
# same query; the row sets must be identical.
#
# SCOPE. A LITERAL pattern against a text column or a text expression
# (`UPPER(S) SIMILAR TO ...`), and a PARAMETER pattern (`SIMILAR TO ?`,
# compiled at bind). A
# `SIMILAR TO` inside a value expression (a projected boolean / CASE), and
# a non-text operand are each refused at prepare - their own later slices.
#
#   qa/serve-real-similar.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4768}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node-firebird")' >/dev/null 2>&1; then
    echo "SKIP: node-firebird not available"; exit 0
fi
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, S VARCHAR(20));
COMMIT;
INSERT INTO T VALUES (1,'abc');   INSERT INTO T VALUES (2,'abbbc'); INSERT INTO T VALUES (3,'axc');
INSERT INTO T VALUES (4,'ac');    INSERT INTO T VALUES (5,'ABC');   INSERT INTO T VALUES (6,'a1c');
INSERT INTO T VALUES (7,'hello'); INSERT INTO T VALUES (8,'a.c');   INSERT INTO T VALUES (9,'xyz');
INSERT INTO T VALUES (10,NULL);   INSERT INTO T VALUES (11,'');     INSERT INTO T VALUES (12,'a%c');
INSERT INTO T VALUES (13,'a-c');  INSERT INTO T VALUES (14,'123');  INSERT INTO T VALUES (15,'foo(bar)');
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-similar-a.fdb"; B="$D/fc-similar-b.fdb"
mkdb "$A"; mkdb "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-similar-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

query() { # <sql> <host> <port> <db>
    timeout 25 env FC_Q="$1" FC_HOST="$2" FC_PORT="$3" FC_DB="$4" node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(0);});
      const F=require("node-firebird");
      F.attach({host:process.env.FC_HOST,port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,44));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r.map(x=>x.ID):[]));
          db.detach();process.exit(0);});});' 2>/dev/null
}
both() { # <label> <where-clause>
    local sql a b
    sql="SELECT ID FROM T WHERE $2 ORDER BY ID"
    a=$(query "$sql" 127.0.0.1 "$PORT" "$A")
    b=$(query "$sql" 127.0.0.1 "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}

both "literal exact"        "S SIMILAR TO 'abc'"
both "one-or-more +"        "S SIMILAR TO 'ab+c'"
both "zero-or-more *"       "S SIMILAR TO 'ab*c'"
both "optional ?"           "S SIMILAR TO 'ab?c'"
both "bounded {2,3}"        "S SIMILAR TO 'ab{2,3}c'"
both "bounded exact {3}"    "S SIMILAR TO 'ab{3}c'"
both "any-one _"            "S SIMILAR TO 'a_c'"
both "any-seq %"            "S SIMILAR TO 'a%c'"
both "alternation"          "S SIMILAR TO '(abc|xyz)'"
both "char class"           "S SIMILAR TO 'a[bx1]c'"
both "range class"          "S SIMILAR TO '[a-c]+'"
both "negated class"        "S SIMILAR TO 'a[^b]c'"
both "posix ALPHA"          "S SIMILAR TO 'a[[:ALPHA:]]c'"
both "posix DIGIT+"         "S SIMILAR TO '[[:DIGIT:]]+'"
both "dot is literal"       "S SIMILAR TO 'a.c' ESCAPE '#'"
both "escaped percent"      "S SIMILAR TO 'a\%c' ESCAPE '\'"
both "escaped parens"       "S SIMILAR TO 'foo\(bar\)' ESCAPE '\'"
both "empty pattern"        "S SIMILAR TO ''"
both "percent matches all"  "S SIMILAR TO '%'"
both "case sensitive"       "S SIMILAR TO 'ABC'"
both "NOT SIMILAR TO"       "S NOT SIMILAR TO 'a%c'"
both "NOT + null excluded"  "S NOT SIMILAR TO 'hello'"
both "expr UPPER"           "UPPER(S) SIMILAR TO 'A_C'"
both "combined with AND"    "S SIMILAR TO 'a%c' AND ID > 3"
both "combined with OR"     "S SIMILAR TO 'xyz' OR S SIMILAR TO 'hello'"
both "nested groups+quant"  "S SIMILAR TO '(a(b|x)+c)'"

# --- a PARAMETER pattern (compiled at bind) ---
queryp() { # <where-clause> <json args> <host> <port> <db>
    timeout 25 env FC_Q="SELECT ID FROM T WHERE $1 ORDER BY ID" FC_A="$2" FC_HOST="$3" FC_PORT="$4" FC_DB="$5" node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(0);});
      const F=require("node-firebird"); const args=JSON.parse(process.env.FC_A);
      F.attach({host:process.env.FC_HOST,port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,args,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,44));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r.map(x=>x.ID):[]));
          db.detach();process.exit(0);});});' 2>/dev/null
}
bothp() { # <label> <where-clause> <json args>
    local a b
    a=$(queryp "$2" "$3" 127.0.0.1 "$PORT" "$A")
    b=$(queryp "$2" "$3" 127.0.0.1 "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}
bothp "param a_c"           "S SIMILAR TO ?" '["a_c"]'
bothp "param alternation"   "S SIMILAR TO ?" '["(abc|xyz)"]'
bothp "param posix class"   "S SIMILAR TO ?" '["a[[:ALPHA:]]c"]'
bothp "param NOT"           "S NOT SIMILAR TO ?" '["a%c"]'
bothp "param ESCAPE"        "S SIMILAR TO ? ESCAPE '#'" '["a#%c"]'
bothp "param no match"      "S SIMILAR TO ?" '["zzz"]'
bothp "param + AND"         "ID > 1 AND S SIMILAR TO ?" '["a%c"]'

echo "ran $ran checks"
exit $fail
