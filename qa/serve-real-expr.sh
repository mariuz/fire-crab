#!/bin/bash
# PREDICATE EXPRESSION SURFACE: LIKE (with ESCAPE), BETWEEN, IN, NOT
# and parentheses - the WHERE shapes real statements are written in.
# The predicate grammar is now a recursive parser (OR over AND over
# NOT/parens/leaves) normalized to DNF with NOT pushed into the leaves
# by De Morgan - sound in three-valued logic, where the inverse of an
# UNKNOWN comparison is still UNKNOWN. BETWEEN desugars to >= AND <=
# (bounds NOT swapped), IN to OR-of-equalities, and their NOT forms
# fall out of De Morgan - including the classic `x NOT IN (1, NULL)`
# = UNKNOWN trap, which must return NO rows.
#
# LIKE matches the STORED value - CHAR padding counts (CHAR(6) 'abc'
# matches 'abc%' and 'abc   ' but NOT 'abc'), differentially confirmed
# against the engine before implementation. Matching is per character;
# this gate's data is ASCII in a NONE-charset database so byte and
# character semantics coincide (multi-byte `_` behaviour is pinned by
# unit tests under the project's UTF8-only exclusion).
#
# Every check runs the IDENTICAL SQL through fire-crab (node-firebird)
# and through isql on the same file - the engine is the oracle for
# every shape, then parameterised LIKE/IN run through node's real
# encoders, and UPDATE/DELETE with the new predicates are applied by
# the engine to a mirror copy -> identical tables.
#
#   qa/serve-real-expr.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4076}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/expr_src.fdb"; CLEAN="$DIR/expr_clean.fdb"
WORK="/tmp/fc-expr-work.fdb"; REF="/tmp/fc-expr-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE E (ID INTEGER NOT NULL, C CHAR(6), V VARCHAR(12), N INTEGER);
COMMIT;
INSERT INTO E VALUES (1, 'abc',    'apple',      10);
INSERT INTO E VALUES (2, 'abd',    'apricot',    20);
INSERT INTO E VALUES (3, 'xyz',    'banana',     NULL);
INSERT INTO E VALUES (4, NULL,     'grape',      30);
INSERT INTO E VALUES (5, 'a_c',    '50% off',    40);
INSERT INTO E VALUES (6, 'abcdef', 'a_b',        50);
INSERT INTO E VALUES (7, 'ab',     NULL,         20);
INSERT INTO E VALUES (8, 'zz  z',  'red',        60);
INSERT INTO E VALUES (9, 'abc',    'road',       10);
INSERT INTO E VALUES (10, 'q',     'rod',        NULL);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/expr.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/expr.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-expr.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }

node_once() { # <sql> [params-js-array]
    FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" FC_PARAMS="${2:-[]}" \
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

fail=0
# run the IDENTICAL select through both sides; "<no rows>" sentinel for
# empty results so a legit empty answer is distinguishable from a hang
compare() { # <label> <select over ID list>
    fc=$(node_run "$2" | sort)
    is=$(run_isql <<EOF | strip | grep -v '^$' | sort
SET HEADING OFF;
$2;
EOF
)
    [ -n "$is" ] || is="<no rows>"
    if [ "$fc" = "$is" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     isql: $(echo $is)"
        echo "     fc:   $(echo $fc)"
        fail=1
    fi
}

# --- LIKE ---------------------------------------------------------------
compare "LIKE prefix"          "SELECT ID FROM E WHERE V LIKE 'ap%'"
compare "LIKE suffix"          "SELECT ID FROM E WHERE V LIKE '%e'"
compare "LIKE contains"        "SELECT ID FROM E WHERE V LIKE '%o%'"
compare "LIKE underscore"      "SELECT ID FROM E WHERE V LIKE 'r_d'"
compare "LIKE exact varchar"   "SELECT ID FROM E WHERE V LIKE 'banana'"
compare "CHAR pad: no pct"     "SELECT ID FROM E WHERE C LIKE 'abc'"
compare "CHAR pad: pct"        "SELECT ID FROM E WHERE C LIKE 'abc%'"
compare "CHAR pad: padded pat" "SELECT ID FROM E WHERE C LIKE 'abc   '"
compare "CHAR inner space"     "SELECT ID FROM E WHERE C LIKE 'zz%z%'"
compare "NOT LIKE"             "SELECT ID FROM E WHERE V NOT LIKE '%a%'"
compare "LIKE escape pct"      "SELECT ID FROM E WHERE V LIKE '50!% %' ESCAPE '!'"
compare "LIKE escape under"    "SELECT ID FROM E WHERE V LIKE 'a!_b' ESCAPE '!'"
compare "LIKE wildcard as lit" "SELECT ID FROM E WHERE V LIKE 'a_b'"
compare "LIKE on NULL col"     "SELECT ID FROM E WHERE V LIKE '%'"

# --- BETWEEN / IN -------------------------------------------------------
compare "BETWEEN"              "SELECT ID FROM E WHERE ID BETWEEN 3 AND 6"
compare "NOT BETWEEN"          "SELECT ID FROM E WHERE ID NOT BETWEEN 3 AND 6"
compare "BETWEEN null col"     "SELECT ID FROM E WHERE N BETWEEN 10 AND 30"
compare "NOT BETWEEN null col" "SELECT ID FROM E WHERE N NOT BETWEEN 10 AND 30"
compare "BETWEEN reversed"     "SELECT ID FROM E WHERE ID BETWEEN 6 AND 3"
compare "BETWEEN text"         "SELECT ID FROM E WHERE V BETWEEN 'apple' AND 'grape'"
compare "IN ints"              "SELECT ID FROM E WHERE ID IN (2, 4, 6, 99)"
compare "NOT IN ints"          "SELECT ID FROM E WHERE ID NOT IN (2, 4, 6)"
compare "IN text"              "SELECT ID FROM E WHERE V IN ('apple', 'rod')"
compare "IN with NULL listed"  "SELECT ID FROM E WHERE N IN (10, NULL)"
compare "NOT IN w/ NULL (3VL)" "SELECT ID FROM E WHERE N NOT IN (10, NULL)"
compare "NOT IN excl null col" "SELECT ID FROM E WHERE N NOT IN (10, 20)"

# --- NOT / parentheses --------------------------------------------------
compare "parens precedence"    "SELECT ID FROM E WHERE (ID = 1 OR ID = 8) AND N = 60"
compare "NOT over OR"          "SELECT ID FROM E WHERE NOT (ID < 3 OR ID > 8)"
compare "NOT over AND"         "SELECT ID FROM E WHERE NOT (N = 20 AND V IS NULL)"
compare "NOT IS NULL"          "SELECT ID FROM E WHERE NOT (N IS NULL)"
compare "double NOT"           "SELECT ID FROM E WHERE NOT NOT ID = 5"
compare "nested parens"        "SELECT ID FROM E WHERE ((ID = 1 OR ID = 2) AND (N = 10 OR N = 20))"
compare "mix like/in/between"  "SELECT ID FROM E WHERE V LIKE '%r%' AND ID BETWEEN 2 AND 9 OR ID IN (1, 10)"
compare "count over expr"      "SELECT COUNT(*) FROM E WHERE ID NOT IN (1, 2) AND C IS NOT NULL"
compare "having between"       "SELECT N FROM E GROUP BY N HAVING COUNT(*) BETWEEN 2 AND 9"
compare "having in"            "SELECT N FROM E GROUP BY N HAVING N IN (10, 30)"

# --- parameters through the new shapes ---------------------------------
check() {
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
check "param LIKE pattern" \
    "$(node_run "SELECT ID FROM E WHERE V LIKE ? ORDER BY ID" '["r_d"]')" \
    "$(printf '8\n10')"
check "param IN list" \
    "$(node_run "SELECT ID FROM E WHERE ID IN (?, ?) ORDER BY ID" '[3,7]')" \
    "$(printf '3\n7')"
check "param BETWEEN bounds" \
    "$(node_run "SELECT COUNT(*) FROM E WHERE ID BETWEEN ? AND ?" '[2,5]')" "4"
check "param NULL in LIKE is UNKNOWN" \
    "$(node_run "SELECT ID FROM E WHERE V LIKE ?" '[null]')" "<no rows>"
check "shared param slot in parens" \
    "$(node_run "SELECT ID FROM E WHERE (ID = ? OR N = ?) AND ID <> 4 ORDER BY ID" '[1,20]')" \
    "$(printf '1\n2\n7')"

# --- DML through the new predicates + engine mirror ---------------------
check "update WHERE LIKE" \
    "$(node_run "UPDATE E SET N = 99 WHERE V LIKE 'r%'")" "<no rows>"
check "delete WHERE NOT IN" \
    "$(node_run "DELETE FROM E WHERE ID NOT IN (1, 2, 3, 4, 5, 6, 7)")" "<no rows>"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<'EOF' >/dev/null 2>&1 || { echo "DIFF engine-side statements"; fail=1; }
UPDATE E SET N = 99 WHERE V LIKE 'r%';
DELETE FROM E WHERE ID NOT IN (1, 2, 3, 4, 5, 6, 7);
COMMIT;
EOF
dump() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || COALESCE(C, '<n>') || '|' || COALESCE(V, '<n>') || '|' || COALESCE(CAST(N AS VARCHAR(5)), '<n>') FROM E ORDER BY ID;
EOF
}
check "ENGINE mirror identical" "$(dump "$WORK")" "$(dump "$REF")"
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean" "$(printf '%s' "$val" | strip)" ""
exit $fail
