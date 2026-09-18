#!/bin/bash
# A PARAMETER AS THE TESTED SIDE of a predicate, against the REAL
# engine as a twin: `? IS NULL`, `? LIKE`, `? STARTING WITH`,
# `? BETWEEN`, `? IN` - the four shapes the roadmap had carried as
# "the engine answers all of them and this parser covers none" - plus
# the refuter's finding, `N STARTING WITH ?` on an INTEGER column.
#
# The load-bearing discovery from the probe pass: fire-crab already
# answered every MIRRORED comparison (`? = 1`, `? >= 1.5`), so
# `? BETWEEN a AND b` and `? IN (v, ...)` are a parse-time desugar
# into those leaves - `lo <= ? AND hi >= ?`, an OR of equalities -
# all referencing the ONE slot. Only IS NULL / LIKE / STARTING needed
# new terms, each ROW-INDEPENDENT and decided at bind.
#
# Engine laws probed and pinned here:
#   * `? IS NULL` describes as SQL_NULL (32766, length 0) and the bind
#     is TYPE-BLIND: a text value answers "not null", no error.
#     `? IS UNKNOWN` is the same predicate.
#   * NULL binds are UNKNOWN under BOTH polarities everywhere.
#   * `? BETWEEN 1 AND 3` takes '2.5' (text converts, fraction kept);
#     'x' raises a conversion error at EXECUTE on both sides.
#   * `? NOT IN (1, NULL)` is never true (the NULL leaf is permanently
#     UNKNOWN in the conjunction).
#   * text is pad-insensitive in the mirrored compare ('a ' IN
#     ('a','b') answers).
#   * `N STARTING WITH ?` (N INTEGER): the slot is TEXT; '1' matches
#     N=1 AND N=10, '' matches every non-NULL N, ' 1' none; a
#     blr_long 1 binds as '1'.
#   * `N LIKE ?` (N INTEGER) is the same render against a bound
#     PATTERN: '1%' takes 1 and 10, an int bind 1 is the exact
#     pattern '1' (takes N=1, not N=10), NULL is UNKNOWN.
#   * a SCALED column renders its zero-padded fixed-point text under
#     both: NUMERIC(9,2) 0.5 is '0.50', so STARTING '1.' takes only
#     the 1.5x rows and LIKE '%.5%' takes the .50s.
#   * invalid ESCAPE (22025) raises at first real evaluation, VALUE-
#     gated, and the invariant (no-column) conjuncts evaluate BEFORE
#     the scan in written order with FALSE > error > UNKNOWN: `?bad
#     AND 1=0` raises, `1=0 AND ?bad` does not, `ID=NULL AND ...bad`
#     raises per row where `ID=99 AND ...bad` short-circuits false.
#
# Deliberate refusals kept (engine answers; recorded for later
# slices): `? IN (?, 2)` (the engine types the inner ? from the
# list), `? IN (1, 'a')` (mixed - per-bind conversion semantics),
# `? BETWEEN 1 AND 'x'` (conversion deferred to execute),
# `? IS DISTINCT FROM 5`. Shared refusals (both sides
# refuse): `? BETWEEN ? AND ?`, `? = ?`.
#
#   qa/serve-real-paramshapes.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4573}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-pshape-crab.fdb"
B="$D/fc-pshape-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, N INTEGER, NAME VARCHAR(10), N92 NUMERIC(9,2));
CREATE TABLE E (ID INTEGER, NAME VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 1,    'ok',   0);
INSERT INTO T VALUES (2, 2,    'open', 0.5);
INSERT INTO T VALUES (3, 3,    'x',    -1.5);
INSERT INTO T VALUES (4, 10,   NULL,   10);
INSERT INTO T VALUES (5, NULL, 'aa',   NULL);
COMMIT;
SET TERM ^;
/* a bound value must reach the BODY, in the right slot */
CREATE PROCEDURE PU (A VARCHAR(5) CHARACTER SET UTF8, B INTEGER)
    RETURNS (K INTEGER) AS BEGIN K = B; SUSPEND; END^
CREATE PROCEDURE PX (A VARCHAR(5) CHARACTER SET UTF8)
    RETURNS (K INTEGER) AS BEGIN K = CHAR_LENGTH(A); SUSPEND; END^
SET TERM ;^
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-paramshapes.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

query() { # <sql> <json args> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_A="$2" FC_PORT="$3" FC_DB="$4" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,JSON.parse(process.env.FC_A),(e2,r)=>{
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

# the same comparison over a WHOLE statement, for shapes that are not a
# WHERE clause over T (a procedure call in the FROM, say)
bothq() { # <label> <full sql> <json args>
    ran=$((ran + 1))
    local a b
    a=$(query "$2" "$3" "$PORT" "$A")
    b=$(query "$2" "$3" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1 $3: $a"
    else
        echo "DIFF $1 $3"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

both() { # <label> <predicate> <json args>
    ran=$((ran + 1))
    q="SELECT ID FROM T WHERE $2 ORDER BY ID"
    a=$(query "$q" "$3" "$PORT" "$A")
    b=$(query "$q" "$3" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1 $3: $a"
    else
        echo "DIFF $1 $3"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

# --- 1. ? IS [NOT] NULL: row-independent, type-blind ------------------
both "? IS NULL" "? IS NULL" '[null]'
both "? IS NULL" "? IS NULL" '[5]'
both "? IS NULL is TYPE-BLIND (text bind)" "? IS NULL" '["x"]'
both "? IS NOT NULL" "? IS NOT NULL" '[null]'
both "? IS NOT NULL" "? IS NOT NULL" '[5]'
both "? IS UNKNOWN is the same predicate" "? IS UNKNOWN" '[null]'
both "? IS UNKNOWN" "? IS UNKNOWN" '[true]'
both "NOT (? IS NULL)" "NOT (? IS NULL)" '[null]'
both "NOT (? IS NULL)" "NOT (? IS NULL)" '[5]'

# --- 2. ? LIKE --------------------------------------------------------
both "? LIKE literal" "? LIKE 'o%'" '["ok"]'
both "? LIKE literal" "? LIKE 'o%'" '["x"]'
both "? LIKE with a NULL bind" "? LIKE 'o%'" '[null]'
both "? NOT LIKE" "? NOT LIKE 'o%'" '["x"]'
both "? NOT LIKE" "? NOT LIKE 'o%'" '["ok"]'
both "? NOT LIKE with a NULL bind" "? NOT LIKE 'o%'" '[null]'
both "? LIKE with ESCAPE" "? LIKE 'o!%%' ESCAPE '!'" '["o%mitted"]'
both "? LIKE ? (both parameters)" "? LIKE ?" '["ok","o%"]'
both "? LIKE ? with a NULL pattern" "? LIKE ?" '["ok",null]'
both "? LIKE ? with a NULL value" "? LIKE ?" '[null,"o%"]'
both "? LIKE NULL is never true" "? LIKE NULL" '["x"]'

# --- 3. ? STARTING WITH -----------------------------------------------
both "? STARTING WITH literal" "? STARTING WITH 'a'" '["ab"]'
both "? STARTING WITH literal" "? STARTING WITH 'a'" '["ba"]'
both "? STARTING WITH with a NULL bind" "? STARTING WITH 'a'" '[null]'
both "? NOT STARTING WITH" "? NOT STARTING WITH 'a'" '["ba"]'
both "? NOT STARTING WITH with NULL" "? NOT STARTING WITH 'a'" '[null]'
both "? STARTING WITH ?" "? STARTING WITH ?" '["ab","a"]'
both "? STARTING WITH ?" "? STARTING WITH ?" '["ab","b"]'

# --- 3b. <text col> CONTAINING ? (a BOUND PATTERN) --------------------
#
# CONTAINING is the one predicate that folds case on EVERY character
# set, and until this slice a BOUND pattern refused where the engine
# answered. The fold is the OPERAND's character set - here NAME, a
# VARCHAR(10) in a NONE-charset database, so the fold is ASCII - and the
# pattern is folded at bind, where the value finally exists.
#
# NAME holds 'ok', 'open', 'x', NULL, 'aa'.
both "NAME CONTAINING ? (lower)" "NAME CONTAINING ?" '["o"]'
both "NAME CONTAINING ? folds case" "NAME CONTAINING ?" '["O"]'
both "NAME CONTAINING ? mid-string" "NAME CONTAINING ?" '["PE"]'
both "NAME CONTAINING ? no match" "NAME CONTAINING ?" '["zz"]'
# an EMPTY pattern matches every non-NULL row, and a NULL bind is
# UNKNOWN under BOTH polarities - the two boundaries of the shape
both "NAME CONTAINING '' takes every non-NULL" "NAME CONTAINING ?" '[""]'
both "NAME CONTAINING ? with a NULL bind" "NAME CONTAINING ?" '[null]'
both "NAME NOT CONTAINING ?" "NAME NOT CONTAINING ?" '["o"]'
both "NAME NOT CONTAINING ? with a NULL bind" "NAME NOT CONTAINING ?" '[null]'
# ...and the pattern has NO WILDCARDS, bound exactly as literal
both "a bound % is a literal percent" "NAME CONTAINING ?" '["%"]'
both "a bound _ is a literal underscore" "NAME CONTAINING ?" '["_"]'

# ...and over a NUMERIC side, where the column is RENDERED to its
# decimal text first and the rendering has no case to fold. N holds
# 1, 2, 3, 10, NULL; N92 holds 0, 0.5, -1.5, 10, NULL.
both "N CONTAINING ? takes every '1'" "N CONTAINING ?" '["1"]'
both "N CONTAINING ? takes the '0' of 10" "N CONTAINING ?" '["0"]'
both "N CONTAINING ? with an INTEGER bind" "N CONTAINING ?" '[1]'
both "N CONTAINING '' takes every non-NULL" "N CONTAINING ?" '[""]'
both "N CONTAINING ? with a NULL bind" "N CONTAINING ?" '[null]'
both "N NOT CONTAINING ?" "N NOT CONTAINING ?" '["1"]'
both "N92 CONTAINING ? sees the fraction" "N92 CONTAINING ?" '["1.5"]'
both "N92 CONTAINING ? sees the point" "N92 CONTAINING ?" '["."]'

# --- 3c. ? SIMILAR TO: the tested side of the regex matcher -----------
#
# The last of the tested-side pattern family. The slot takes the same
# shape LIKE and STARTING WITH take; the regex is compiled at BIND.
both "? SIMILAR TO literal" "? SIMILAR TO 'o%'" '["ok"]'
both "? SIMILAR TO literal, no match" "? SIMILAR TO 'o%'" '["x"]'
both "? SIMILAR TO with a NULL bind" "? SIMILAR TO 'o%'" '[null]'
both "? NOT SIMILAR TO" "? NOT SIMILAR TO 'o%'" '["x"]'
both "? NOT SIMILAR TO with a NULL bind" "? NOT SIMILAR TO 'o%'" '[null]'
both "? SIMILAR TO ? (both parameters)" "? SIMILAR TO ?" '["ok","o%"]'
both "a character class" "? SIMILAR TO '[[:ALPHA:]]+'" '["ok"]'
both "a character class rejects a digit" "? SIMILAR TO '[[:ALPHA:]]+'" '["o1"]'
both "? SIMILAR TO with ESCAPE" "? SIMILAR TO 'o!%%' ESCAPE '!'" '["o%mitted"]'
both "an INTEGER bind renders" "? SIMILAR TO '1%'" '[10]'
both "an empty pattern matches empty" "? SIMILAR TO ''" '[""]'
both "? SIMILAR TO NULL is never true" "? SIMILAR TO NULL" '["x"]'

# AN INVALID PATTERN RAISES AT EXECUTE - and NOT the way an invalid LIKE
# escape does. LIKE's is gated by its LENIENT PREFIX, so `? LIKE 'a!'
# ESCAPE '!'` bound 'x' ANSWERS; SIMILAR TO's raises for ANY non-NULL
# value. Only a FALSE written BEFORE it suppresses the raise (the
# written-order invariant law of 8c), and a FALSE written AFTER does
# not. All measured against the engine.
for pair in "? SIMILAR TO '['|[\"x\"]" \
            "? IS NOT NULL AND ? SIMILAR TO '['|[5,\"x\"]" \
            "? SIMILAR TO '[' AND ? IS NULL|[\"x\",5]" \
            "? SIMILAR TO '[' AND 1 = 0|[\"x\"]"; do
    pred="${pair%%|*}"; args="${pair##*|}"
    a=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$REAL" "$B")
    # BOTH must raise - and `ERR*:ERR*` alone CANNOT SAY THAT. A
    # prepare-time REFUSAL is also an ERR, so these four cells passed
    # while the shape was not implemented at all: every one of them
    # compared "fire-crab refuses" against "the engine raises" and
    # called it agreement. The engine's message names the predicate, so
    # require that of both sides.
    case "$a:$b" in
        *SIMILAR*:*SIMILAR*) echo "OK   $pred $args raises on BOTH (invalid SIMILAR pattern)" ;;
        ERR*:ERR*) echo "DIFF $pred $args: both ERR but not both a SIMILAR raise - fcwire [$a] engine [$b]"; fail=1 ;;
        *) echo "DIFF $pred $args: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done
both "a FALSE written BEFORE suppresses the raise" "? IS NULL AND ? SIMILAR TO '['" '[5,"x"]'
both "a NULL value gates the bad pattern off" "? SIMILAR TO '['" '[null]'

# --- 3d. a PROCEDURE CALL'S ARGUMENTS ---------------------------------
#
# The bound value must reach the BODY, in the right slot. PU returns its
# second argument; PX returns the CHAR_LENGTH of its first - so a
# swapped pair or a dropped slot shows up as a wrong ANSWER, not just a
# wrong describe. Slots are numbered in TEXT ORDER across the whole
# statement (measured), which is why the call-plus-WHERE shapes are
# here: they pin the numbering, not just the binding.
# A `?` ARGUMENT IN A FROM-CLAUSE CALL. The bound value must reach the
# BODY, in the right slot: PU returns its SECOND argument and PX the
# CHAR_LENGTH of its first, so a swapped pair or a dropped slot shows up
# as a wrong ANSWER rather than only a wrong describe.
bothq "both arguments bound" "SELECT K FROM PU(?, ?)" '["ab",7]'
bothq "...and the order matters" "SELECT K FROM PU(?, ?)" '["zz",42]'
bothq "a literal beside a bound one" "SELECT K FROM PU('ab', ?)" '[7]'
bothq "the TEXT argument reaches the body" "SELECT K FROM PX(?)" '["abc"]'
bothq "a NULL argument" "SELECT K FROM PU(?, ?)" '[null,5]'
# ...and through a MODIFIER, which runs the body on its own arm rather
# than through materialise_procedures - the seat has to be filled there
# too, or the body runs with a NULL in it (which it once did).
bothq "a modifier over the call" "SELECT FIRST 1 K FROM PU(?, ?)" '["ab",7]'
# ...and through an AGGREGATE, which takes a THIRD route again - the
# bound-row-source one, where the call becomes an inner plan under a
# fold. The seats have to travel WITH that inner plan or the body runs
# with NULL in each of them.
#
# THE CELL THAT WOULD NOT HAVE CAUGHT IT: `COUNT(*)` agrees even when
# every argument is NULL, because counting a row never reads one. The
# value-carrying folds below are the ones with teeth - PU returns its
# SECOND argument and PX the CHAR_LENGTH of its first, so a NULL seat
# shows up as a NULL answer.
bothq "an aggregate over the call" "SELECT MAX(K) FROM PU(?, ?)" '["ab",7]'
bothq "...a SUM, where the value shows" "SELECT SUM(K) FROM PU(?, ?)" '["ab",42]'
bothq "...and over the TEXT argument" "SELECT MAX(K) FROM PX(?)" '["abcde"]'
bothq "COUNT(*) agrees either way (a control)" "SELECT COUNT(*) FROM PU(?, ?)" '["ab",7]'
# ROUTE 2 - A CLAUSE OVER THE CALL. The re-plan rebuilds the statement
# with the call spliced OUT of the FROM, so the call's `?` vanish from
# the text while their slots stay claimed: the statement's own `?` must
# therefore number AFTER the arguments. Measured, and asserted by the
# slot counts in serve-real-bindcs: `PU(?, ?) WHERE K = ?` is three
# slots in TEXT order.
#
# THE EXCLUDING CELLS ARE THE TEETH. A filter that never ran would
# answer the row anyway, so every predicate here is paired with one
# that must answer NOTHING - the same lesson COUNT(*) taught above.
bothq "a WHERE over the call" "SELECT K FROM PU(?, ?) WHERE K > ?" '["ab",7,0]'
bothq "...a WHERE that EXCLUDES the row" "SELECT K FROM PU(?, ?) WHERE K > ?" '["ab",7,99]'
bothq "...an equality that MATCHES" "SELECT K FROM PU(?, ?) WHERE K = ?" '["ab",7,7]'
bothq "...an equality that MISSES" "SELECT K FROM PU(?, ?) WHERE K = ?" '["ab",7,6]'
bothq "a WHERE with no ? of its own" "SELECT K FROM PU(?, ?) WHERE K > 0" '["ab",7]'
bothq "an ORDER BY over the call" "SELECT K FROM PU(?, ?) ORDER BY K" '["ab",7]'
bothq "a GROUP BY over the call" "SELECT K FROM PU(?, ?) GROUP BY K" '["ab",7]'
bothq "the TEXT argument under a WHERE ?" "SELECT K FROM PX(?) WHERE K > ?" '["abcde",0]'
bothq "...the TEXT argument, EXCLUDED" "SELECT K FROM PX(?) WHERE K > ?" '["abcde",99]'
# LITERAL arguments under a clause worked before route 2 landed - it is
# the control that says these cells measure the BOUND half specifically
bothq "LITERAL args + a WHERE ? (a control)" "SELECT K FROM PU('ab', 9) WHERE K > ?" '[0]'
# A HAVING `?` OVER THE GROUPED FORM - recorded here one chunk ago as a
# refusal, and it EXPIRED ITSELF: the grouped branch of plan_over_source
# carried a scope fence that outlived what it was waiting for. The same
# removal answers a grouped derived table, a CTE and a grouped join
# (serve-real-castparamgroup), so these cells pin the procedure end of it.
bothq "a HAVING ? over the call" "SELECT K, COUNT(*) FROM PU(?, ?) GROUP BY K HAVING COUNT(*) > ?" '["ab",7,0]'
bothq "...a HAVING that EXCLUDES the group" "SELECT K, COUNT(*) FROM PU(?, ?) GROUP BY K HAVING COUNT(*) > ?" '["ab",7,9]'
bothq "...with LITERAL arguments too" "SELECT K, COUNT(*) FROM PU('ab', 9) GROUP BY K HAVING COUNT(*) > ?" '[0]'

# RECORDED, NOT FIXED - written so each EXPIRES ITSELF: the cell carries
# the engine's own answer and says so the day fire-crab agrees. A
# refusal written as a bare comment rots silently instead.
#   - a derived table or CTE over a call with BOUND arguments: refused by
#     a different guard entirely - the inner statement carries no clause
#     at all, so route 2's guard was never what stopped it.
for pair in "SELECT K FROM (SELECT K FROM PU(?, ?)) D|[\"ab\",7]" \
            "WITH C AS (SELECT K FROM PU(?, ?)) SELECT K FROM C|[\"ab\",7]"; do
    q="${pair%%|*}"; args="${pair##*|}"
    a=$(query "$q" "$args" "$PORT" "$A")
    case "$a" in
        ERR*) echo "OK   refusal kept (engine answers): $q" ;;
        *) b=$(query "$q" "$args" "$REAL" "$B")
           if [ "$a" = "$b" ]; then
               echo "OK   $q now agrees: $a (update the refusal list)"
           else
               echo "DIFF $q: fcwire [$a] engine [$b]"; fail=1
           fi ;;
    esac
done
bothq "EXECUTE PROCEDURE binds too" "EXECUTE PROCEDURE PU(?, ?)" '["ab",7]'

# --- 4. ? BETWEEN: a desugar into the mirrored comparisons ------------
both "? BETWEEN ints" "? BETWEEN 1 AND 3" '[2]'
both "? BETWEEN ints" "? BETWEEN 1 AND 3" '[5]'
both "? BETWEEN with a NULL bind" "? BETWEEN 1 AND 3" '[null]'
both "? BETWEEN takes numeric text" "? BETWEEN 1 AND 3" '["2"]'
both "? BETWEEN keeps the fraction" "? BETWEEN 1 AND 3" '["2.5"]'
both "? NOT BETWEEN" "? NOT BETWEEN 1 AND 3" '[5]'
both "? NOT BETWEEN" "? NOT BETWEEN 1 AND 3" '[2]'
both "? NOT BETWEEN with NULL" "? NOT BETWEEN 1 AND 3" '[null]'
both "NOT (? BETWEEN ...)" "NOT (? BETWEEN 1 AND 3)" '[5]'
both "? BETWEEN a scaled bound" "? BETWEEN 1.5 AND 3" '[2]'
both "? BETWEEN a scaled bound" "? BETWEEN 1.5 AND 3" '[1]'
both "? BETWEEN text bounds" "? BETWEEN 'a' AND 'c'" '["b"]'
both "? BETWEEN text bounds, pad-blind" "? BETWEEN 'a' AND 'c'" '["b "]'
both "? BETWEEN text bounds" "? BETWEEN 'a' AND 'c'" '["x"]'
both "? BETWEEN a NULL bound is never true" "? BETWEEN NULL AND 3" '[2]'

# --- 5. ? IN: an OR of mirrored equalities ----------------------------
both "? IN ints" "? IN (1, 2)" '[1]'
both "? IN ints" "? IN (1, 2)" '[3]'
both "? IN with a NULL bind" "? IN (1, 2)" '[null]'
both "? IN takes numeric text" "? IN (1, 2)" '["1"]'
both "? NOT IN" "? NOT IN (1, 2)" '[3]'
both "? NOT IN" "? NOT IN (1, 2)" '[1]'
both "? NOT IN with NULL" "? NOT IN (1, 2)" '[null]'
both "? IN with a NULL item" "? IN (1, NULL)" '[1]'
both "? IN with a NULL item" "? IN (1, NULL)" '[2]'
both "? NOT IN (.., NULL) is never true" "? NOT IN (1, NULL)" '[1]'
both "? NOT IN (.., NULL) is never true" "? NOT IN (1, NULL)" '[2]'
both "? IN (NULL) is never true" "? IN (NULL)" '[1]'
both "? IN text items" "? IN ('a', 'b')" '["a"]'
both "? IN text items, pad-blind" "? IN ('a', 'b')" '["a "]'
both "? IN text items, case matters" "? IN ('a', 'b')" '["A"]'
both "? IN text items with NULL bind" "? IN ('a', 'b')" '[null]'

# --- 6. composition ----------------------------------------------------
both "? IS NULL OR a column test" "? IS NULL OR ID > 4" '[null]'
both "? IS NULL OR a column test" "? IS NULL OR ID > 4" '[7]'
both "? BETWEEN AND a column test" "? BETWEEN 1 AND 3 AND ID > 2" '[2]'
both "? BETWEEN AND a column test" "? BETWEEN 1 AND 3 AND ID > 2" '[9]'
both "? IN OR a column test" "? IN (1, 2) OR NAME = 'x'" '[3]'

# --- 7. N STARTING WITH ? (INTEGER column, text slot) -----------------
both "int col STARTING WITH ?" "N STARTING WITH ?" '["1"]'
both "int col STARTING WITH ?" "N STARTING WITH ?" '["10"]'
both "the empty prefix takes non-NULL rows" "N STARTING WITH ?" '[""]'
both "a non-numeric prefix" "N STARTING WITH ?" '["x"]'
both "no trimming of the bound blank" "N STARTING WITH ?" '[" 1"]'
both "a NULL prefix" "N STARTING WITH ?" '[null]'
both "an integer BIND renders to text" "N STARTING WITH ?" '[1]'
both "an integer BIND renders to text" "N STARTING WITH ?" '[10]'
both "NOT with the int column" "N NOT STARTING WITH ?" '["1"]'
both "NOT with a NULL prefix" "N NOT STARTING WITH ?" '[null]'
both "the literal twin still answers" "N STARTING WITH '1'" '[]'

# --- 7b. N LIKE ? (INTEGER column, text slot) -------------------------
both "int col LIKE ?" "N LIKE ?" '["1%"]'
both "a suffix pattern" "N LIKE ?" '["%0"]'
both "the empty pattern takes nothing" "N LIKE ?" '[""]'
both "a NULL pattern" "N LIKE ?" '[null]'
both "an int BIND is the exact pattern" "N LIKE ?" '[1]'
both "an int BIND is the exact pattern" "N LIKE ?" '[10]'
both "NOT LIKE with the int column" "N NOT LIKE ?" '["1%"]'

# --- 7c. scaled columns render for STARTING/LIKE ----------------------
both "N92 STARTING WITH ?" "N92 STARTING WITH ?" '["1"]'
both "the render pads its scale ('1.' = 1.5x)" "N92 STARTING WITH ?" '["1."]'
both "a NULL prefix on the scaled column" "N92 STARTING WITH ?" '[null]'
both "an int BIND renders to text" "N92 STARTING WITH ?" '[1]'
both "N92 LIKE ?" "N92 LIKE ?" '["1%"]'
both "the fraction digits are in the text" "N92 LIKE ?" '["%.5%"]'

# --- 8. error parity: conversion raises at EXECUTE on both ------------
for pair in "? BETWEEN 1 AND 3|[\"x\"]" "? IN (1, 2)|[\"0x1\"]"; do
    pred="${pair%%|*}"; args="${pair##*|}"
    a=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $pred $args raises on BOTH (conversion at execute)" ;;
        *) echo "DIFF $pred $args: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done

# --- 8b. invalid ESCAPE sequences raise at EXECUTE on both ------------
# (the escape must precede %, _ or itself, and may not end the pattern;
# probed: the engine raises 22025 only against a non-NULL tested value,
# so the NULL bind answers no rows on both sides. Found by an
# adversarial pass - fire-crab had matched the bad escapes as literals.)
for pair in "? LIKE 'a!bc' ESCAPE '!'|[\"abc\"]" "? LIKE 'ab!' ESCAPE '!'|[\"ab\"]" \
            "? NOT LIKE 'a!bc' ESCAPE '!'|[\"zz\"]"; do
    pred="${pair%%|*}"; args="${pair##*|}"
    a=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $pred $args raises on BOTH (invalid escape)" ;;
        *) echo "DIFF $pred $args: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done
both "an invalid escape with a NULL bind answers, not raises" "? LIKE 'a!bc' ESCAPE '!'" '[null]'

# --- 8c. the constant-evaluation law around the bad escape ------------
# probed: invariant (no-column) conjuncts evaluate BEFORE the scan in
# written order, FALSE > error > UNKNOWN; on the row pass AND
# short-circuits on FALSE only, never on UNKNOWN, and the escape check
# is value-gated per row. Each raise below raises on BOTH sides; each
# answer answers [] on BOTH.
for pair in "NAME LIKE ? ESCAPE '!'|[\"a!bc\"]" \
            "NAME LIKE ? ESCAPE '!' AND ID = 99|[\"a!bc\"]" \
            "NAME LIKE ? ESCAPE '!' OR ID = 1|[\"a!bc\"]" \
            "ID = NULL AND NAME LIKE ? ESCAPE '!'|[\"a!bc\"]" \
            "? LIKE ? ESCAPE '!' AND 1 = 0|[\"x\",\"a!bc\"]"; do
    pred="${pair%%|*}"; args="${pair##*|}"
    a=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $pred $args raises on BOTH" ;;
        *) echo "DIFF $pred $args: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done
both "a FALSE invariant kills the bad escape" "NAME LIKE ? ESCAPE '!' AND 1 = 0" '["a!bc"]'
both "the row pass short-circuits on FALSE" "ID = 99 AND NAME LIKE ? ESCAPE '!'" '["a!bc"]'
both "a NULL NAME gates the check off (row 4)" "ID = 4 AND NAME LIKE ? ESCAPE '!'" '["a!bc"]'
both "a FALSE invariant written first wins" "? IS NULL AND ? LIKE ? ESCAPE '!'" '[5,"x","a!bc"]'
both "... even written second" "NAME LIKE ? ESCAPE '!' AND ? LIKE 'z'" '["a!bc","x"]'
# a LITERAL bad-escape pattern gates on the LENIENT PREFIX even with a
# `?` tested side (probed: bound 'zz' answers [] - 'zz' does not start
# with the lenient 'abc' - where bound 'abc' raises, pinned in 8b)
both "a literal bad escape misses the bound value: no raise" "? LIKE 'a!bc' ESCAPE '!'" '["zz"]'
# the two OR shapes the invariant pass once broke (probed: the engine
# short-circuits the invariant OR once at open, and the row pass stops
# at ID>0 before ever reaching the division)
both "a TRUE invariant OR-group never reaches the division" "(1 = 1 OR 1 / 0 = 1) AND ID > 0" '[]'
both "a row passing ID>0 short-circuits the OR" "ID > 0 OR 1 / 0 = 1" '[]'

# --- 8d. zero rows do not gate the INVARIANT conjuncts off ------------
# probed over an EMPTY table: `? LIKE ?` with a bad bound pattern
# raises with zero rows (the invariant conjunct evaluates ONCE at
# open), while the row-dependent `NAME LIKE ?bad` answers [] - the
# raise-or-answer split is invariance, not rows
a=$(query "SELECT ID FROM E WHERE ? LIKE ? ESCAPE '!'" '["x","a!bc"]' "$PORT" "$A")
b=$(query "SELECT ID FROM E WHERE ? LIKE ? ESCAPE '!'" '["x","a!bc"]' "$REAL" "$B")
case "$a:$b" in
    ERR*:ERR*) echo "OK   ? LIKE ?bad raises over ZERO rows on BOTH" ;;
    *) echo "DIFF empty-table invariant raise: fcwire [$a] engine [$b]"; fail=1 ;;
esac
a=$(query "SELECT ID FROM E WHERE NAME LIKE ? ESCAPE '!'" '["a!bc"]' "$PORT" "$A")
b=$(query "SELECT ID FROM E WHERE NAME LIKE ? ESCAPE '!'" '["a!bc"]' "$REAL" "$B")
if [ "$a" = "$b" ] && [ "$a" = "[]" ]; then
    echo "OK   the row-dependent bad escape answers [] over zero rows"
else
    echo "DIFF empty-table row-gated: fcwire [$a] engine [$b]"; fail=1
fi

# --- 9. refusals kept, engine answers recorded ------------------------
# each of these the ENGINE answers (see the gate header); fire-crab
# refuses rather than risk the engine's wilder semantics
# The last is what remains of THIS FAMILY'S SCOPE BOUNDARY. The
# numeric-column half that stood here - `N CONTAINING ?` - was measured
# and implemented the chunk after it was recorded, and THIS LOOP IS WHAT
# SAID SO: it answers on a fresh binary and printed "now agrees (update
# the refusal list)". A recorded refusal that carries the engine's own
# answer expires by itself; one written as a bare comment would have
# rotted silently.
#
# What is left is the bound TESTED side, which hits a measured engine
# anomaly: under a UTF8 attachment `? CONTAINING '<non-ascii>'` is false
# even SAME-CASE, while every other combination is true. Answering it
# would mean saying TRUE where the engine says false.
for pair in "? IN (?, 2)|[1,1]" "? IN (1, 'a')|[\"a\"]" "? BETWEEN 1 AND 'x'|[2]" \
            "? IS DISTINCT FROM 5|[4]" "? CONTAINING 'o'|[\"ok\"]"; do
    pred="${pair%%|*}"; args="${pair##*|}"
    a=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$PORT" "$A")
    case "$a" in
        ERR*) echo "OK   refusal kept (engine answers): $pred" ;;
        *) b=$(query "SELECT ID FROM T WHERE $pred ORDER BY ID" "$args" "$REAL" "$B")
           if [ "$a" = "$b" ]; then
               echo "OK   $pred now agrees: $a (update the refusal list)"
           else
               echo "DIFF $pred: fcwire [$a] engine [$b]"; fail=1
           fi ;;
    esac
done
# shared refusals: both sides refuse (the engine says -804 Data type
# unknown; the texts differ, the verdicts must not)
for pair in "? BETWEEN ? AND ?|[1,1,3]" "? = ?|[1,1]"; do
    pred="${pair%%|*}"; args="${pair##*|}"
    a=$(query "SELECT ID FROM T WHERE $pred" "$args" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $pred" "$args" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $pred refuses on BOTH" ;;
        *) echo "DIFF $pred: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done

rm -f "$A" "$B"
echo "ran $ran checks"
# COUNTED FLOOR, derived from a measured run (this gate reported 152
# checks green) - never typed. Without it a block that stops being read
# leaves the gate green over fewer cells with no sign at all: measured
# twice today, once catching two cells that a helper defined below its
# first call had silently disabled.
if [ "$ran" -lt 152 ]; then
    echo "DIFF only $ran checks ran (expected at least 152) - did a block silently skip?"
    fail=1
fi
exit $fail
