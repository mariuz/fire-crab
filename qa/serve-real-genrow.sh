#!/bin/bash
# NEXT VALUE FOR <seq> / GEN_ID(<name>, <n>) in the SELECT LIST of a
# ROW-RETURNING query - one generator advance PER ROW, mid-fetch. Unlike
# the single-row RDB$DATABASE form (serve-real-genstep), here the SELECT
# walks a real table and each emitted row advances the generator and
# carries the new value. The engine evaluates it during FETCH, in OUTPUT
# order (after any ORDER BY), so with `ORDER BY X` the value follows the
# sorted output, not the scan order.
#
# Generators inside EXPRESSIONS - `(NEXT VALUE FOR S) + 100`, a CAST, a
# concat - are answered too, with the engine's evaluation-order law:
# select-list ITEMS evaluate RIGHT-TO-LEFT (probed: two bare items give
# the LEFT one the HIGHER value), leaves within one item LEFT-TO-RIGHT,
# and the LAZY positions (CASE branches, COALESCE tails, WHERE, ORDER
# BY, FIRST, GROUP BY) refuse rather than over-bump.
#
# THE differential is the engine. The SAME query runs through BOTH
# fire-crab (node -> fcwire, WORK) and the C++ engine (isql, REF); the
# per-row values must match value-for-value AND the stored generator value
# afterwards must match. gfix validates the file.
#
#   qa/serve-real-genrow.sh [port]
#
# Builds its own scratch database (a 3-row table with UNSORTED keys - so
# scan order differs from sorted order - a plain sequence, an INCREMENT
# BY 5 sequence, and a generator).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4093}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/genrow_src.fdb"
WORK="/tmp/fc-genrow-work.fdb"; REF="/tmp/fc-genrow-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"; rm -f "$SRC" "$WORK" "$REF"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE SRC (X INTEGER);
CREATE SEQUENCE SEQ;
CREATE SEQUENCE SEQ5 START WITH 100 INCREMENT BY 5;
CREATE GENERATOR G;
CREATE SEQUENCE SEQBIG;
-- SEQD belongs to the DERIVED-TABLE block at the end and to nothing
-- else, so those cells cannot perturb the sequences above. The cells
-- that ANSWER advance both sides identically (lockstep); the cells that
-- RECORD a refusal never call the engine at all, so neither side moves
-- and the lockstep the stored-value checks rely on is preserved.
CREATE SEQUENCE SEQD;
-- BIG exists for ONE check, and it is the check the whole batching
-- interaction hangs on: 2500 rows is past the ~2300 where a fetch has
-- to be split into batches, which is what made the cursor MATERIALISE
-- and is exactly how the generator advance came to be dropped.
CREATE TABLE BIG (X INTEGER);
COMMIT;
-- a cross join, not a recursive CTE: the CTE form hits Firebird's
-- 1024-deep recursion limit ("too many concurrent executions of the
-- same request") long before 2500 rows.
INSERT INTO BIG SELECT ROW_NUMBER() OVER () FROM RDB\$TYPES A, RDB\$TYPES B ROWS 2500;
COMMIT;
INSERT INTO SRC VALUES (30);
INSERT INTO SRC VALUES (10);
INSERT INTO SRC VALUES (20);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-genrow.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
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

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# run one SELECT through fire-crab; print each row's columns pipe-joined,
# one row per line (values in select-list order)
fc_rows() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
          process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(1);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR");db.detach();process.exit(0);}
              if(!r||!r.length)console.log("<none>");
              else for(const row of r)console.log(Object.values(row).map(v=>v===null?"<null>":String(v)).join("|"));
              db.detach();process.exit(0);});
          });' 2>/dev/null)
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}
# run one SELECT through the engine (isql) on REF; same pipe-joined shape.
# Build the pipe string in SQL so column widths do not matter.
en_rows() { # <select-cols> <from/order tail>
    "$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL | strip | grep -v '^$'
SET HEADING OFF;
$1;
SQL
}
# read a generator's stored value from a file through the engine
gen_of() { # <file> <gen>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -oE '[-0-9]+' | head -1
SET HEADING OFF;
SELECT GEN_ID($2, 0) FROM RDB\$DATABASE;
SQL
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ] && [ -n "$2" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1
    fi
}

# 1) no ORDER BY: one advance per row in scan order. fc must equal the
#    engine row-for-row (both walk the same file the same way).
Q1="SELECT NEXT VALUE FOR SEQ, X FROM SRC"
check "NEXT VALUE FOR, no order (per-row vs engine)" \
    "$(fc_rows "$Q1")" "$(en_rows "SELECT (NEXT VALUE FOR SEQ) || '|' || X FROM SRC")"
# 2) ORDER BY X: the value follows OUTPUT order (X 10,20,30 -> 4,5,6 after
#    the two rows SEQ already advanced above)
Q2="SELECT NEXT VALUE FOR SEQ, X FROM SRC ORDER BY X"
check "NEXT VALUE FOR, ORDER BY X (output order)" \
    "$(fc_rows "$Q2")" "$(en_rows "SELECT (NEXT VALUE FOR SEQ) || '|' || X FROM SRC ORDER BY X")"
# 3) GEN_ID with a step, ORDER BY DESC
Q3="SELECT GEN_ID(SEQ5, 5), X FROM SRC ORDER BY X DESC"
check "GEN_ID(SEQ5,5), ORDER BY X DESC" \
    "$(fc_rows "$Q3")" "$(en_rows "SELECT GEN_ID(SEQ5, 5) || '|' || X FROM SRC ORDER BY X DESC")"
# 4) WHERE filters rows before the advance count (only matching rows bump)
Q4="SELECT GEN_ID(G, 1), X FROM SRC WHERE X > 15 ORDER BY X"
check "GEN_ID(G,1) with WHERE (only matching rows advance)" \
    "$(fc_rows "$Q4")" "$(en_rows "SELECT GEN_ID(G, 1) || '|' || X FROM SRC WHERE X > 15 ORDER BY X")"

# A GENERATOR INSIDE AN EXPRESSION - the shapes this gate used to assert
# as refusals. The law that took a probe to find: the engine evaluates
# select-list ITEMS RIGHT-TO-LEFT (two bare NEXT VALUE items give the
# LEFT one the HIGHER value) and leaves WITHIN one item left-to-right.
# The engine twins for the two-item checks are therefore TWO ITEMS
# joined by sed, never a single concat expression - a concat evaluates
# its leaves left-to-right and answers DIFFERENT per-column values.
en_cols() { en_rows "$1" | sed 's/[[:space:]]\{1,\}/|/g'; }
Q5="SELECT (NEXT VALUE FOR SEQ) + 100, X FROM SRC ORDER BY X"
check "an advance inside arithmetic, per row" \
    "$(fc_rows "$Q5")" "$(en_rows "SELECT ((NEXT VALUE FOR SEQ) + 100) || '|' || X FROM SRC ORDER BY X")"
Q6="SELECT (NEXT VALUE FOR SEQ) || 'x' FROM SRC"
check "an advance inside a concat" \
    "$(fc_rows "$Q6")" "$(en_rows "SELECT (NEXT VALUE FOR SEQ) || 'x' FROM SRC")"
Q7="SELECT CAST(NEXT VALUE FOR SEQ AS VARCHAR(10)) FROM SRC"
check "an advance inside a CAST" \
    "$(fc_rows "$Q7")" "$(en_rows "SELECT CAST(NEXT VALUE FOR SEQ AS VARCHAR(10)) FROM SRC")"
Q8="SELECT NEXT VALUE FOR SEQ AS A, NEXT VALUE FOR SEQ AS B, X FROM SRC ORDER BY X"
check "two bare items evaluate RIGHT-TO-LEFT (A > B)" \
    "$(fc_rows "$Q8")" "$(en_cols "SELECT NEXT VALUE FOR SEQ, NEXT VALUE FOR SEQ, X FROM SRC ORDER BY X")"
Q9="SELECT NEXT VALUE FOR SEQ AS A, (NEXT VALUE FOR SEQ) + 1000 AS B, X FROM SRC ORDER BY X"
check "a bare item beside an expression item" \
    "$(fc_rows "$Q9")" "$(en_cols "SELECT NEXT VALUE FOR SEQ, (NEXT VALUE FOR SEQ) + 1000, X FROM SRC ORDER BY X")"
Q10="SELECT GEN_ID(SEQ5, 5) + 1, X FROM SRC ORDER BY X DESC"
check "GEN_ID with a step inside arithmetic" \
    "$(fc_rows "$Q10")" "$(en_rows "SELECT (GEN_ID(SEQ5, 5) + 1) || '|' || X FROM SRC ORDER BY X DESC")"

# THE FB6 SCHEMA QUALIFIER on a generator reference - the form SHOW
# GENERATORS itself emits. A PUBLIC qualifier (bare or quoted) strips
# to the bare catalog name; any OTHER qualifier must FAIL on BOTH
# sides: the old strip took ANY qualifier off, so fc ANSWERED
# GEN_ID(NOSCHEMA.SEQ, 0) where the engine raises "Generator
# "NOSCHEMA"."SEQ" is not defined" - a wrong answer, not an outage.
# Step 0 is a pure read, so the twins stay in lockstep.
check "GEN_ID with a bare PUBLIC qualifier (step 0 read)" \
    "$(fc_rows 'SELECT GEN_ID(PUBLIC.SEQ, 0) FROM RDB$DATABASE')" \
    "$(en_rows 'SELECT GEN_ID(PUBLIC.SEQ, 0) FROM RDB$DATABASE')"
check "GEN_ID with a QUOTED PUBLIC qualifier" \
    "$(fc_rows 'SELECT GEN_ID("PUBLIC".SEQ, 0) FROM RDB$DATABASE')" \
    "$(en_rows 'SELECT GEN_ID("PUBLIC".SEQ, 0) FROM RDB$DATABASE')"
# the dot is its own token: the engine answers whitespace around it in
# every generator reference (probed) - the NEXT VALUE FOR parsers used
# to truncate the name at the first blank while GEN_ID's path answered
check "GEN_ID with a SPACED qualifier dot (step 0 read)" \
    "$(fc_rows 'SELECT GEN_ID(PUBLIC . SEQ, 0) FROM RDB$DATABASE')" \
    "$(en_rows 'SELECT GEN_ID(PUBLIC . SEQ, 0) FROM RDB$DATABASE')"
check "NEXT VALUE FOR with a SPACED qualifier dot (advances in lockstep)" \
    "$(fc_rows 'SELECT NEXT VALUE FOR PUBLIC . SEQ FROM RDB$DATABASE')" \
    "$(en_rows 'SELECT NEXT VALUE FOR PUBLIC . SEQ FROM RDB$DATABASE')"
check "NEXT VALUE FOR, spaced dot, both parts quoted" \
    "$(fc_rows 'SELECT NEXT VALUE FOR "PUBLIC" . "SEQ" FROM RDB$DATABASE')" \
    "$(en_rows 'SELECT NEXT VALUE FOR "PUBLIC" . "SEQ" FROM RDB$DATABASE')"
r=$(fc_rows 'SELECT GEN_ID(NOSCHEMA.SEQ, 0) FROM RDB$DATABASE')
e=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<'SQL' | tr -s ' \n' ' '
SELECT GEN_ID(NOSCHEMA.SEQ, 0) FROM RDB$DATABASE;
SQL
)
en_failed=0
case "$e" in *"Statement failed"*|*"not defined"*|*error*|*ERROR*) en_failed=1 ;; esac
case "$r" in
    *ERR*) if [ "$en_failed" = "1" ]; then
               echo "OK   a foreign qualifier (NOSCHEMA.SEQ) fails on BOTH sides"
           else
               echo "DIFF engine ANSWERED NOSCHEMA.SEQ: [$e]"; fail=1
           fi ;;
    *) echo "DIFF fc answered a foreign-qualified generator: [$r] (engine: [$e])"; fail=1 ;;
esac

# A GENERATOR ACROSS FETCH BATCHES. The three-row checks above all fit in
# one batch; this one does not, and the two halves of the interaction it
# pins are the two that were broken:
#
#   * the cursor is MATERIALISED before it is batched, and the advance has
#     to happen at materialisation - `branch_rows` computes the rows and
#     knows nothing of gen_cols, so every value came back NULL;
#   * the advance must happen ONCE, not once per batch, and its final
#     value must be persisted by a fetch that returns without reaching the
#     old single persistence site.
#
# Compared as DIGESTS: 2500 rows pasted into a shell variable is a gate
# that reports its own truncation as a difference.
QB="SELECT NEXT VALUE FOR SEQBIG, X FROM BIG ORDER BY X"
a=$(fc_rows "$QB" | md5sum | cut -d' ' -f1)
b=$(en_rows "SELECT (NEXT VALUE FOR SEQBIG) || '|' || X FROM BIG ORDER BY X" | md5sum | cut -d' ' -f1)
check "NEXT VALUE FOR over 2500 rows (spans fetch batches)" "$a" "$b"
# ... and the EXPRESSION form over the same 2500 rows - this is the one
# that exercises the gen-aware materialisation in the batch fetch (an
# expression column evaluates against the filled slot at encode time,
# which the projected-rows path could never do)
QB2="SELECT (NEXT VALUE FOR SEQBIG) + 0, X FROM BIG ORDER BY X"
a=$(fc_rows "$QB2" | md5sum | cut -d' ' -f1)
b=$(en_rows "SELECT ((NEXT VALUE FOR SEQBIG) + 0) || '|' || X FROM BIG ORDER BY X" | md5sum | cut -d' ' -f1)
check "the expression form over 2500 rows" "$a" "$b"

# --- A GENERATOR INSIDE A DERIVED TABLE, A CTE OR A VIEW -------------
# The advance lived only in the TOP-LEVEL fetch. Every row source below
# it - a derived table, a CTE level, a view, a union branch - projected
# the inner columns WITHOUT it, so the synthetic slot stayed unfilled
# and read back NULL: rendered 0 under the non-nullable announcement
# `NEXT VALUE FOR` carries (sqltype 580) and <null> under GEN_ID's
# (581), with the sequence never moving. One cause, two appearances,
# and the third time this exact `..`-destructure dropped `gen_cols`.
#
# THE ENGINE DRAWS PER EVALUATED REFERENCE, NOT PER ROW (measured over
# four rows): one reference draws 4, two draw 8, three draw 12, and a
# column the outer never delivers draws NOTHING. A filter on another
# column does not re-evaluate - it shrinks the delivered set FIRST
# (keeping 2 of 4 draws 2). The value follows OUTPUT order: the first
# DELIVERED row takes the first value, whatever record it came from.
# So the fix materialises, filters, sorts and only THEN advances, and
# it is exact at ONE delivered reference and nowhere else - everything
# else refuses below rather than answer a different wrong number.
check "a generator in a DERIVED TABLE, per delivered row" \
    "$(fc_rows 'SELECT Z.N FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z')" \
    "$(en_rows 'SELECT Z.N FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z')"
check "...beside another column, in OUTPUT order" \
    "$(fc_rows 'SELECT Z.N, Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.X')" \
    "$(en_rows "SELECT Z.N || '|' || Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.X")"
# the first DELIVERED row takes the first value: under DESC the HIGHEST
# X is drawn FIRST, which a sort after the advance could not produce
check "the value follows the OUTER sort, not the scan" \
    "$(fc_rows 'SELECT Z.N, Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.X DESC')" \
    "$(en_rows "SELECT Z.N || '|' || Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.X DESC")"
check "an INNER ORDER BY drives the delivery order" \
    "$(fc_rows 'SELECT Z.N, Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC ORDER BY X DESC) Z')" \
    "$(en_rows "SELECT Z.N || '|' || Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC ORDER BY X DESC) Z")"
check "an outer WHERE shrinks the set BEFORE the draw" \
    "$(fc_rows 'SELECT Z.N FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z WHERE Z.X = 10')" \
    "$(en_rows 'SELECT Z.N FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z WHERE Z.X = 10')"
# the column the outer never delivers: the engine draws NOTHING, which
# is what NOT advancing already produced - so this shape was always
# right and must STAY right (a blanket guard here would have broken it)
check "a generator column the outer never selects" \
    "$(fc_rows 'SELECT Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.X')" \
    "$(en_rows 'SELECT Z.X FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.X')"
check "a CTE level is the same shape" \
    "$(fc_rows 'WITH C AS (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) SELECT N FROM C')" \
    "$(en_rows 'WITH C AS (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) SELECT N FROM C')"
check "the GEN_ID spelling through a derived table" \
    "$(fc_rows 'SELECT Z.N FROM (SELECT GEN_ID(SEQD, 1) AS N FROM SRC) Z')" \
    "$(en_rows 'SELECT Z.N FROM (SELECT GEN_ID(SEQD, 1) AS N FROM SRC) Z')"

# THE DECLARED COLUMN, which the value comparisons above cannot see -
# they compare values positionally and a wrong NAME is invisible to them.
# Probed with SET SQLDA_DISPLAY ON: the two spellings get DIFFERENT
# names and DIFFERENT nullability. `NEXT VALUE FOR S` is NEXT_VALUE and
# sqltype 580; `GEN_ID(S, 1)` is GEN_ID and 581, the nullable form.
# fire-crab announced GEN_ID/581 for both.
sqlda() { # <conn> <statement>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | grep -E 'sqltype:|name:' | tr -s ' '
SET SQLDA_DISPLAY ON;
SET PLANONLY ON;
$2;
SQL
}
for st in "SELECT NEXT VALUE FOR SEQ FROM SRC" "SELECT GEN_ID(SEQ, 1) FROM SRC"; do
    check "declared column for: $st" \
        "$(sqlda "127.0.0.1/$PORT:$WORK" "$st")" "$(sqlda "$REF" "$st")"
done

# THE SHAPES THAT MUST STILL REFUSE, each one an engine-answered shape
# whose eager slot-filling would give WRONG VALUES rather than an
# outage: the engine bumps lazily in a CASE (an untaken branch does not
# advance), per matching row in a WHERE, per compared row in an ORDER
# BY, only for EMITTED rows under FIRST, and 19-bumps-for-5-rows
# messily under GROUP BY. `FIRST 2 NEXT VALUE FOR SEQ` used to ANSWER
# here - every value NULL and the sequence never moved - so its line is
# the regression pin for that bug. These run against fire-crab only (a
# refusal advances nothing, so the twins stay in lockstep).
# ... including ORDER BY reaching the generator through an ORDINAL or
# an ALIAS - the spelled form refuses at resolution, but these two
# reach the key through the ProjCol and ANSWERED with wrong rows and a
# diverged stored value before an adversarial pass caught them (the
# sort ran over slots the advance had not filled).
for st in "SELECT X FROM SRC WHERE NEXT VALUE FOR SEQ > 0" \
          "SELECT X FROM SRC ORDER BY NEXT VALUE FOR SEQ" \
          "SELECT NEXT VALUE FOR SEQ, X FROM SRC ORDER BY 1 DESC" \
          "SELECT NEXT VALUE FOR SEQ AS A, X FROM SRC ORDER BY A DESC" \
          "SELECT (NEXT VALUE FOR SEQ) + 0 AS A, X FROM SRC ORDER BY 1" \
          "SELECT CASE WHEN X > 15 THEN NEXT VALUE FOR SEQ ELSE -1 END FROM SRC" \
          "SELECT FIRST 2 NEXT VALUE FOR SEQ FROM SRC" \
          "SELECT COUNT(*), NEXT VALUE FOR SEQ FROM SRC" \
          "SELECT COALESCE(X, NEXT VALUE FOR SEQ) FROM SRC"; do
    r=$(fc_rows "$st")
    case "$r" in
        *ERR*) echo "OK   refused (the engine's evaluation there is lazy/partial): $st" ;;
        *) echo "DIFF fire-crab answered a shape it must refuse: $st -> $r"; fail=1 ;;
    esac
done

# ...and the SAME law one level down. Materialise-then-advance is exact
# at ONE delivered reference; each shape here draws a DIFFERENT number
# on the engine, so answering any of them with one-draw-per-row would
# trade one wrong answer for another. The engine's count is named
# beside each. fire-crab only - a refusal advances nothing, so the
# twins stay in lockstep and the stored-SEQD check below still holds.
for st in "SELECT Z.N, Z.N FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z" \
          "SELECT Z.N, Z.N, Z.N FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z" \
          "SELECT Z.N FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z WHERE Z.N > 1" \
          "SELECT Z.N FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.N" \
          "SELECT DISTINCT Z.N FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z" \
          "SELECT FIRST 1 Z.N FROM (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ORDER BY Z.X" \
          "SELECT SUM(Z.N) FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Z" \
          "SELECT Z.N FROM (SELECT (NEXT VALUE FOR SEQD) + 100 AS N FROM SRC) Z" \
          "SELECT * FROM (SELECT NEXT VALUE FOR SEQD AS A, NEXT VALUE FOR SEQ5 AS B FROM SRC) Z" \
          "WITH C AS (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) SELECT N FROM C UNION ALL SELECT N FROM C" \
          "SELECT Z.N FROM (SELECT * FROM (SELECT NEXT VALUE FOR SEQD AS N FROM SRC) Y) Z" \
          "SELECT NEXT VALUE FOR SEQD AS N FROM SRC UNION ALL SELECT 99 FROM RDB\$DATABASE" \
          "SELECT Z.N FROM SRC A JOIN (SELECT X, NEXT VALUE FOR SEQD AS N FROM SRC) Z ON Z.X = A.X"; do
    r=$(fc_rows "$st")
    case "$r" in
        *ERR*) echo "OK   refused (the draw count is not one per delivered row): $st" ;;
        *) echo "DIFF fire-crab answered a derived generator shape it must refuse: $st -> $r"
           echo "     re-measure the ENGINE's draw count for it before gating an answer"
           fail=1 ;;
    esac
done

# stored generator values must match the engine's. WORK advanced once per
# fc query above; REF advanced once per en_rows query in the SAME order
# (same generators, same steps, same row counts) - so they are in lockstep
# and no replay is needed (replaying would double-advance REF).
kill $srv 2>/dev/null; wait $srv 2>/dev/null
for g in SEQ SEQ5 G SEQBIG SEQD; do
    check "stored $g matches engine" "$(gen_of "$WORK" "$g")" "$(gen_of "$REF" "$g")"
done

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
if [ -z "$(printf '%s' "$val" | strip)" ]; then
    echo "OK   gfix -v -full clean"
else
    echo "DIFF gfix -v -full"; echo "     $val"; fail=1
fi

exit $fail
