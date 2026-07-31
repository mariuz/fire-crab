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
#   qa/serve-real-modifiers.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4454}"
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
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
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
         "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
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

exit $fail
