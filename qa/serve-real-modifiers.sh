#!/bin/bash
# RESULT MODIFIERS - FIRST n, SKIP n, DISTINCT, ROWS n [TO m].
#
# Each is stripped off the query, the rest is planned normally, and the
# result is wrapped in a plan that materialises the inner rows and then
# de-duplicates and/or slices them. The materialising step is the SAME one
# INSERT ... SELECT and FOR SELECT use, so a modifier works over whatever
# the inner plan is - a table, a VIEW, a UNION, a selectable procedure -
# and a modified query can in turn feed those.
#
# THE GRAMMAR ORDER IS THE ENGINE'S AND IT IS NOT NEGOTIABLE:
#
#     SELECT [FIRST m] [SKIP n] [DISTINCT|ALL] <select list> ...
#            [ROWS n [TO m]]
#
# `SELECT DISTINCT FIRST 2 ...` and `SELECT SKIP 1 FIRST 2 ...` are
# SYNTAX ERRORS in the engine, not alternative spellings. An earlier
# attempt at this feature accepted them and disagreed with the engine on
# five cases - and the gate asserting they should work was itself wrong,
# so the cases below now assert that both are REFUSED.
#
# ROWS uses a different convention from SKIP/FIRST: `ROWS n` keeps the
# first n rows, but `ROWS n TO m` keeps rows n..=m counting from ONE.
# Both are converted to a common (skip, take) so they cannot drift apart.
#
# THE DIFFERENTIAL: the same isql runs the same query against the engine
# and against fire-crab and the row sets must match, ORDER included.
# Every limiting case pins the order with ORDER BY first, because which
# rows "the first two" are is only defined once the order is - and the
# ordering had to be pushed into the materialising step for exactly that
# reason (it used to be dropped, so FIRST took arbitrary rows).
#
# THAT CONVENTION IS RIGHT FOR FIRST/SKIP AND WAS WRONG FOR DISTINCT,
# which it applied to as well: DISTINCT has an order of its own to be
# asked about, and pinning one removed the question instead of answering
# it. See "DISTINCT IS A SORT" below - it is a sort, fire-crab kept scan
# order, and nothing in the first eight checks could tell.
#
#   qa/serve-real-modifiers.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4454}"
# THE ENGINE MUST BE REACHED OVER THE SAME TRANSPORT fire-crab speaks.
# This gate used to hand isql the bare FILE PATH for the engine side and
# a `127.0.0.1/<port>:` string for fire-crab, which is not one difference
# but two - and the second one TALKS. Over a LOCAL attachment the engine
# raises a blocking node's error at OPEN, so isql never announces a
# result set; over TCP the SAME engine on the SAME file announces it and
# raises at the first FETCH, printing one blank line first. Compared
# across transports, fire-crab looked like it had an open-versus-fetch
# divergence. It does not: over TCP the two are byte-identical.
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-modifiers.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, S VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 10, 'x');
INSERT INTO T VALUES (2, 20, 'y');
INSERT INTO T VALUES (3, 10, 'x');
INSERT INTO T VALUES (4, 30, 'z');
INSERT INTO T VALUES (5, NULL, NULL);
INSERT INTO T VALUES (6, NULL, NULL);
COMMIT;
CREATE VIEW V AS SELECT ID, A FROM T;
COMMIT;
CREATE TABLE TE (ID INTEGER, S VARCHAR(10));
COMMIT;
INSERT INTO TE VALUES (1, '10');
INSERT INTO TE VALUES (2, '20');
INSERT INTO TE VALUES (3, 'x');
INSERT INTO TE VALUES (4, '40');
COMMIT;
SET TERM ^;
CREATE PROCEDURE GEN (N INTEGER) RETURNS (K INTEGER) AS
DECLARE VARIABLE I INTEGER;
BEGIN
  I = 1;
  WHILE (I <= N) DO
  BEGIN
    K = I;
    SUSPEND;
    I = I + 1;
  END
END^
SET TERM ;^
COMMIT;
EOF
chmod 666 "$DB"   # the engine's server opens it as its own user, not ours

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-mod.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
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

fail=0
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}
# both sides must REJECT it - the engine's message and fire-crab's differ,
# so this compares the fact of failure, not the wording
both_fail() { # <label> <sql>
    fc=$(printf '%s;\n' "$2" |
         "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf '%s;\n' "$2" |
         "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$DB" 2>&1 | tr -s ' \n' ' ')
    case "$en" in
        *"Statement failed"*|*error*|*ERROR*) ;;
        *) echo "DIFF $1 - the ENGINE accepted it, so the case is wrong: [$en]"; fail=1; return ;;
    esac
    case "$fc" in
        *"Statement failed"*|*error*|*ERROR*) echo "OK   $1 (both refuse)" ;;
        *) echo "DIFF $1 - the engine refuses it but fc answered [$fc]"; fail=1 ;;
    esac
}

# --- DISTINCT ----------------------------------------------------------
same "DISTINCT over duplicates"      "SELECT DISTINCT A FROM T ORDER BY 1"
same "DISTINCT with no duplicates"   "SELECT DISTINCT ID FROM T ORDER BY 1"
same "DISTINCT over two columns"     "SELECT DISTINCT A, S FROM T ORDER BY 1"
same "DISTINCT under a WHERE"        "SELECT DISTINCT A FROM T WHERE A > 5 ORDER BY 1"
same "DISTINCT that matches nothing" "SELECT DISTINCT A FROM T WHERE A > 9999"
same "DISTINCT over a text column"   "SELECT DISTINCT S FROM T ORDER BY 1"
same "DISTINCT de-duplicates NULLs"  "SELECT DISTINCT A FROM T ORDER BY 1"
same "DISTINCT with ALL spelled out" "SELECT ALL A FROM T ORDER BY 1"

# --- FIRST / SKIP ------------------------------------------------------
same "FIRST n"                       "SELECT FIRST 2 ID FROM T ORDER BY ID"
same "FIRST larger than the table"   "SELECT FIRST 99 ID FROM T ORDER BY ID"
same "FIRST 0"                       "SELECT FIRST 0 ID FROM T ORDER BY ID"
same "SKIP n"                        "SELECT SKIP 2 ID FROM T ORDER BY ID"
same "SKIP past the end"             "SELECT SKIP 99 ID FROM T ORDER BY ID"
same "FIRST then SKIP"               "SELECT FIRST 2 SKIP 1 ID FROM T ORDER BY ID"
same "FIRST with a WHERE"            "SELECT FIRST 2 ID FROM T WHERE A IS NOT NULL ORDER BY ID"
same "FIRST descending"              "SELECT FIRST 2 ID FROM T ORDER BY ID DESC"
same "FIRST ordered by another column" "SELECT FIRST 2 ID FROM T ORDER BY A"

# --- ROWS --------------------------------------------------------------
same "ROWS n"                        "SELECT ID FROM T ORDER BY ID ROWS 3"
same "ROWS n TO m"                   "SELECT ID FROM T ORDER BY ID ROWS 2 TO 4"
same "ROWS 1 TO 1"                   "SELECT ID FROM T ORDER BY ID ROWS 1 TO 1"
same "ROWS past the end"             "SELECT ID FROM T ORDER BY ID ROWS 99"
same "ROWS n TO m past the end"      "SELECT ID FROM T ORDER BY ID ROWS 5 TO 99"

# --- the engine's ORDER: FIRST, then SKIP, then DISTINCT ---------------
same "FIRST before DISTINCT"         "SELECT FIRST 2 DISTINCT A FROM T ORDER BY 1"
same "SKIP before DISTINCT"          "SELECT SKIP 1 DISTINCT A FROM T ORDER BY 1"
same "FIRST, SKIP and DISTINCT"      "SELECT FIRST 2 SKIP 1 DISTINCT A FROM T ORDER BY 1"
both_fail "DISTINCT before FIRST is a syntax error" "SELECT DISTINCT FIRST 2 A FROM T"
both_fail "SKIP before FIRST is a syntax error"     "SELECT SKIP 1 FIRST 2 ID FROM T"

# --- combined with the other components --------------------------------
same "a modifier over a VIEW"        "SELECT FIRST 2 ID FROM V ORDER BY ID"
same "DISTINCT over a VIEW"          "SELECT DISTINCT A FROM V ORDER BY 1"
# A modifier over a SELECTABLE PROCEDURE. The procedure plan is deferred
# - the body runs at execute, because there are no rows to slice until it
# has - so the modifier is rebuilt around the rows SUSPEND produced. The
# body still runs in full; the modifier slices the result, it does not
# stop the loop early.
same "FIRST over a procedure"        "SELECT FIRST 3 K FROM GEN(10)"
same "SKIP over a procedure"         "SELECT SKIP 7 K FROM GEN(10)"
same "FIRST and SKIP over a procedure" "SELECT FIRST 2 SKIP 3 K FROM GEN(10)"
same "DISTINCT over a procedure"     "SELECT DISTINCT K FROM GEN(3)"
same "a modifier over an empty procedure" "SELECT FIRST 3 K FROM GEN(0)"
same "ROWS over a procedure"         "SELECT K FROM GEN(10) ROWS 2 TO 4"
same "DISTINCT over a UNION"         "SELECT DISTINCT A FROM T UNION SELECT A FROM T ORDER BY 1"

# --- DISTINCT IS A SORT, and every check above hid that ----------------
# Every DISTINCT case in this file pins the order with `ORDER BY 1`,
# which the header states as a deliberate choice - and it is the right
# one for FIRST/SKIP, where "the first two" is undefined without it. For
# DISTINCT it removed the question instead of answering it. The engine
# does not FILTER duplicates, it SORTS and drops equal neighbours
# (`PLAN SORT (TD NATURAL)`, with or without an index available), so the
# set arrives ASCENDING over every output column left to right, NULLs
# first. fire-crab kept scan order, and no check here could see it.
#
# It is not cosmetic: a modifier SLICES this sequence, so the two
# `FIRST/SKIP ... DISTINCT` cases below returned a different ROW SET,
# not a different row order.
same "DISTINCT sorts, no ORDER BY"    "SELECT DISTINCT A FROM T"
same "DISTINCT sorts text"            "SELECT DISTINCT S FROM T"
same "DISTINCT sorts by every column" "SELECT DISTINCT A, S FROM T"
same "DISTINCT sorts NULLs first"     "SELECT DISTINCT A FROM T WHERE ID > 3"
same "FIRST slices the SORTED set"    "SELECT FIRST 2 DISTINCT A FROM T"
same "SKIP slices the SORTED set"     "SELECT SKIP 1 DISTINCT A FROM T"
same "DISTINCT over a VIEW sorts"     "SELECT DISTINCT A FROM V"
# ...and an explicit ORDER BY REPLACES that sort rather than sitting
# under it - there is one sort in the engine's plan and these are its
# keys. (The first fix for the above re-sorted after de-duplicating and
# broke exactly this case.)
same "ORDER BY beats the set's order" "SELECT DISTINCT A FROM T ORDER BY 1 DESC"
same "ORDER BY DESC over text"        "SELECT DISTINCT S FROM T ORDER BY 1 DESC"
# UNION is the same node; UNION ALL is the one that does not sort
same "UNION sorts"                    "SELECT A FROM T UNION SELECT 99 FROM RDB\$DATABASE"
same "UNION ALL does NOT sort"        "SELECT A FROM T UNION ALL SELECT 99 FROM RDB\$DATABASE"
same "UNION with its own ORDER BY"    "SELECT A FROM T UNION SELECT 99 FROM RDB\$DATABASE ORDER BY 1 DESC"

# --- A MODIFIER MUST STILL RUN THE SELECT LIST -------------------------
# The modifier's own columns are POSITIONAL over rows the inner plan has
# ALREADY PROJECTED. One path fed them BASE RECORDS instead, so every
# select-list EXPRESSION was dropped and column i of the TABLE answered
# in its place: `SELECT FIRST 2 CAST(S AS INTEGER) FROM TE` returned the
# ID column - 1 and 2 - where the engine returns 10 and 20.
#
# It hid behind the batch fetch, which materialises the cursor first and
# only falls through to this path when THAT fails - which is exactly when
# some row RAISES. So the visible symptom was a raising query answering
# wrong values instead of raising, and one bad row silently corrupted
# every good one. TE's third row is the raiser.
same "FIRST runs the select list"     "SELECT FIRST 2 CAST(S AS INTEGER) FROM TE"
same "FIRST stops before the raiser"  "SELECT FIRST 2 ID, CAST(S AS INTEGER) FROM TE"
same "FIRST reaching the raiser"      "SELECT FIRST 4 CAST(S AS INTEGER) FROM TE"
same "rows ship before the raise"     "SELECT FIRST 4 ID, CAST(S AS INTEGER) FROM TE"
same "SKIP streams to the raiser"     "SELECT SKIP 1 CAST(S AS INTEGER) FROM TE"
same "SKIP past the raiser"           "SELECT SKIP 3 CAST(S AS INTEGER) FROM TE"
same "DISTINCT blocks on the raiser"  "SELECT DISTINCT CAST(S AS INTEGER) FROM TE"
same "DISTINCT clear of the raiser"   "SELECT DISTINCT CAST(S AS INTEGER) FROM TE WHERE ID < 3"
same "an arithmetic select list"      "SELECT FIRST 2 A + 1 FROM T ORDER BY ID"
same "a literal in the select list"   "SELECT FIRST 2 7, ID FROM T ORDER BY ID"

# --- teeth -------------------------------------------------------------
# 1. DISTINCT must actually remove rows here
a=$(printf 'SET HEADING OFF;\nSELECT A FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
b=$(printf 'SET HEADING OFF;\nSELECT DISTINCT A FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
if [ "$a" -gt "$b" ]; then
    echo "OK   teeth: DISTINCT really removes rows ($a words vs $b)"
else
    echo "DIFF DISTINCT gave $b words against $a - nothing was removed"; fail=1
fi
# 2. the two NULL rows must collapse to ONE, not vanish
n=$(printf 'SET HEADING OFF;\nSELECT DISTINCT A FROM T ORDER BY 1;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | grep -c "null")
if [ "$n" = "1" ]; then
    echo "OK   teeth: two NULL rows de-duplicate to exactly one"
else
    echo "DIFF the de-duplicated set has $n NULL rows, want 1"; fail=1
fi
# 3. FIRST must really limit
c=$(printf 'SET HEADING OFF;\nSELECT FIRST 2 ID FROM T ORDER BY ID;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
if [ "$c" = "2" ]; then
    echo "OK   teeth: FIRST 2 returned exactly 2 rows"
else
    echo "DIFF FIRST 2 returned $c rows"; fail=1
fi
# 4. THE ORDER MUST BE THE QUERY'S, NOT THE SCAN'S. Ordering by a column
#    whose order differs from the scan order is the case that caught the
#    materialiser dropping ORDER BY: FIRST 2 ... ORDER BY A DESC must
#    return the two LARGEST, not the first two stored.
top=$(printf 'SET HEADING OFF;\nSELECT FIRST 2 A FROM T WHERE A IS NOT NULL ORDER BY A DESC;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$top" in
    *30*20*) echo "OK   teeth: FIRST honours ORDER BY, not the scan order ($top)" ;;
    *) echo "DIFF FIRST 2 ... ORDER BY A DESC gave [$top], want 30 then 20"; fail=1 ;;
esac
# 5. SKIP must disagree with the unmodified query
s1=$(printf 'SET HEADING OFF;\nSELECT SKIP 2 ID FROM T ORDER BY ID;\n' |
     "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
s2=$(printf 'SET HEADING OFF;\nSELECT ID FROM T ORDER BY ID;\n' |
     "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
if [ "$s1" != "$s2" ]; then
    echo "OK   teeth: SKIP really drops rows from the front"
else
    echo "DIFF SKIP returned the whole table"; fail=1
fi

# 6. THE SET MUST NOT ARRIVE IN SCAN ORDER. A's scan order is
#    10,20,10,30,NULL,NULL, so de-duplicating in place gives 10 20 30
#    <null> and sorting gives <null> 10 20 30. Comparing against the
#    engine already catches this, but it catches it as one word of a
#    diff; this says which of the two orders fire-crab produced.
d=$(printf 'SET HEADING OFF;\nSELECT DISTINCT A FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$d" in
    *"null"*10*20*30*) echo "OK   teeth: the DISTINCT set arrives sorted, NULLs first ($d)" ;;
    *10*20*30*"null"*) echo "DIFF DISTINCT came back in SCAN order [$d] - it is a sort, not a filter"; fail=1 ;;
    *) echo "DIFF DISTINCT gave [$d], which is neither the sorted nor the scan order"; fail=1 ;;
esac
# 7. THE SELECT LIST MUST HAVE RUN. `CAST(S AS INTEGER)` over TE's first
#    two rows is 10 and 20; the ID column, which the broken path answered
#    in its place, is 1 and 2. Both are two integers, so only their
#    VALUES tell the two apart - and the differential above compares them
#    against an engine reading the same file, which is the real check.
#    This one names the failure.
e=$(printf 'SET HEADING OFF;\nSELECT FIRST 2 CAST(S AS INTEGER) FROM TE;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$e" in
    *10*20*) echo "OK   teeth: the modifier ran the select list ($e)" ;;
    *1*2*)   echo "DIFF the modifier answered the ID column [$e] - the select list was dropped"; fail=1 ;;
    *)       echo "DIFF FIRST 2 CAST(S AS INTEGER) gave [$e], want 10 then 20"; fail=1 ;;
esac
# 8. AND THE ROWS BEFORE A RAISER MUST STILL SHIP. The engine delivers
#    10 and 20 and then raises on 'x'; a materialising path answers the
#    error alone. Both halves matter, so this asserts both.
r=$(printf 'SET HEADING OFF;\nSELECT FIRST 4 CAST(S AS INTEGER) FROM TE;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$r" in
    *10*20*"conversion error"*) echo "OK   teeth: two rows shipped, then the raise" ;;
    *"conversion error"*) echo "DIFF the raise arrived with no rows before it [$r]"; fail=1 ;;
    *) echo "DIFF FIRST 4 over the raiser gave [$r], want 10, 20, then a conversion error"; fail=1 ;;
esac

exit $fail
