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
#
# Deliberate refusals kept (engine answers; recorded for later
# slices): `? IN (?, 2)` (the engine types the inner ? from the
# list), `? IN (1, 'a')` (mixed - per-bind conversion semantics),
# `? BETWEEN 1 AND 'x'` (conversion deferred to execute),
# `? IS DISTINCT FROM 5`, `N LIKE ?`. Shared refusals (both sides
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

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, N INTEGER, NAME VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 1,    'ok');
INSERT INTO T VALUES (2, 2,    'open');
INSERT INTO T VALUES (3, 3,    'x');
INSERT INTO T VALUES (4, 10,   NULL);
INSERT INTO T VALUES (5, NULL, 'aa');
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

both() { # <label> <predicate> <json args>
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

# --- 9. refusals kept, engine answers recorded ------------------------
# each of these the ENGINE answers (see the gate header); fire-crab
# refuses rather than risk the engine's wilder semantics
for pair in "? IN (?, 2)|[1,1]" "? IN (1, 'a')|[\"a\"]" "? BETWEEN 1 AND 'x'|[2]" \
            "? IS DISTINCT FROM 5|[4]" "N LIKE ?|[\"1%\"]"; do
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
exit $fail
