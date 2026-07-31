#!/bin/bash
# UNION / UNION ALL.
#
# The engine compiles a set operation into an RSE union node whose
# branches feed one stream. fire-crab materialises instead: each branch
# is planned on its own, its rows are collected, the lists are
# concatenated, and a plain UNION then removes duplicates - UNION ALL
# keeps them, which is the whole difference between the two.
#
# The FIRST branch names and types the result, exactly as the engine
# does, and every branch must project the same NUMBER of columns.
#
# THE DIFFERENTIAL: the same isql runs the same query against the engine
# and against fire-crab, and the row sets must match - ORDER, duplicates
# and all, since a union's output order is observable once ORDER BY pins
# it and the un-ordered cases must still agree.
#
# The teeth are the pairs that differ only in a way a wrong
# implementation would collapse:
#
#   UNION vs UNION ALL       must give DIFFERENT row counts on data with
#                            duplicates across branches
#   NULL de-duplication      two NULL rows are the SAME row to a set
#                            operation, unlike `= NULL` in a predicate
#   branch WHEREs            each branch filters independently
#
#   qa/serve-real-union.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4392}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-union.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, S VARCHAR(10));
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, S VARCHAR(10));
COMMIT;
INSERT INTO A VALUES (1, 10, 'x');
INSERT INTO A VALUES (2, 20, 'y');
INSERT INTO A VALUES (3, 30, 'z');
INSERT INTO A VALUES (4, NULL, NULL);
INSERT INTO B VALUES (1, 10, 'x');
INSERT INTO B VALUES (2, 99, 'q');
INSERT INTO B VALUES (5, NULL, NULL);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-union.log 2>&1 &
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

# --- UNION ALL ---------------------------------------------------------
same "ALL over two tables"          "SELECT ID FROM A UNION ALL SELECT ID FROM B ORDER BY 1"
same "ALL keeps duplicates"         "SELECT N FROM A UNION ALL SELECT N FROM B ORDER BY 1"
same "ALL of one table with itself" "SELECT ID FROM A UNION ALL SELECT ID FROM A ORDER BY 1"
same "ALL over different columns"   "SELECT ID FROM A UNION ALL SELECT N FROM A ORDER BY 1"

# --- UNION (de-duplicating) --------------------------------------------
same "UNION removes duplicates"     "SELECT N FROM A UNION SELECT N FROM B ORDER BY 1"
same "UNION of a table with itself" "SELECT ID FROM A UNION SELECT ID FROM A ORDER BY 1"
same "UNION over two tables"        "SELECT ID FROM A UNION SELECT ID FROM B ORDER BY 1"
same "UNION on text columns"        "SELECT S FROM A UNION SELECT S FROM B ORDER BY 1"

# --- per-branch WHERE --------------------------------------------------
same "each branch filters"          "SELECT ID FROM A WHERE ID = 1 UNION ALL SELECT ID FROM B WHERE ID = 5"
same "a branch that matches nothing" "SELECT ID FROM A WHERE ID > 99 UNION ALL SELECT ID FROM B ORDER BY 1"
same "both branches filtered"       "SELECT N FROM A WHERE N > 15 UNION SELECT N FROM B WHERE N > 15 ORDER BY 1"

# --- three branches ----------------------------------------------------
same "three-way ALL"                "SELECT ID FROM A UNION ALL SELECT ID FROM B UNION ALL SELECT ID FROM A ORDER BY 1"
same "three-way UNION"              "SELECT ID FROM A UNION SELECT ID FROM B UNION SELECT ID FROM A ORDER BY 1"

# --- several columns ---------------------------------------------------
same "two columns, ALL"             "SELECT ID, N FROM A UNION ALL SELECT ID, N FROM B ORDER BY 1"
same "two columns, de-duplicated"   "SELECT ID, N FROM A UNION SELECT ID, N FROM B ORDER BY 1"
same "an expression in a branch"    "SELECT N + 1 FROM A UNION ALL SELECT N FROM B ORDER BY 1"

# --- ORDER BY ----------------------------------------------------------
same "ORDER BY ordinal ascending"   "SELECT ID FROM A UNION ALL SELECT ID FROM B ORDER BY 1"
same "ORDER BY ordinal descending"  "SELECT ID FROM A UNION ALL SELECT ID FROM B ORDER BY 1 DESC"
same "ORDER BY the second column"   "SELECT ID, N FROM A UNION ALL SELECT ID, N FROM B ORDER BY 2"
same "no ORDER BY at all"           "SELECT ID FROM A WHERE ID = 1 UNION ALL SELECT ID FROM B WHERE ID = 1"

# --- NULLs -------------------------------------------------------------
same "NULLs travel through ALL"     "SELECT N FROM A UNION ALL SELECT N FROM B ORDER BY 1"
same "NULLs de-duplicate in UNION"  "SELECT N FROM A UNION SELECT N FROM B ORDER BY 1"
same "an all-NULL row de-duplicates" "SELECT N, S FROM A UNION SELECT N, S FROM B ORDER BY 1"

# --- teeth -------------------------------------------------------------
# 1. UNION and UNION ALL must give DIFFERENT counts here, or the
#    de-duplication is not being exercised at all
a=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM (SELECT N FROM A UNION ALL SELECT N FROM B);\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -d ' \n')
all=$(printf 'SET HEADING OFF;\nSELECT N FROM A UNION ALL SELECT N FROM B;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
dis=$(printf 'SET HEADING OFF;\nSELECT N FROM A UNION SELECT N FROM B;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
if [ "$all" -gt "$dis" ]; then
    echo "OK   teeth: ALL returns more rows than UNION ($all words vs $dis)"
else
    echo "DIFF ALL gave $all and UNION $dis - de-duplication is not exercised"; fail=1
fi

# 2. the de-duplication must keep ONE of each value, not drop them all
u=$(printf 'SET HEADING OFF;\nSELECT N FROM A UNION SELECT N FROM B ORDER BY 1;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$u" in
    *10*20*30*99*) echo "OK   teeth: every distinct value survives ($u)" ;;
    *) echo "DIFF the de-duplicated set is [$u], want 10 20 30 99 and a NULL"; fail=1 ;;
esac

# 3. a branch count mismatch must FAIL, not pad or truncate
out=$(printf 'SELECT ID FROM A UNION ALL SELECT ID, N FROM B;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: mismatched branch widths are refused" ;;
    *) echo "DIFF mismatched branch widths answered [$out]"; fail=1 ;;
esac

# 4. an aggregate branch is outside this slice - it must fail, not answer
out=$(printf 'SELECT COUNT(*) FROM A UNION ALL SELECT ID FROM B;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: an aggregate branch is refused" ;;
    *) echo "DIFF an aggregate branch answered [$out]"; fail=1 ;;
esac

exit $fail
