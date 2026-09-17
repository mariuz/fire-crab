#!/bin/bash
# The row-locking / optimizer clauses a SELECT may carry - `FOR UPDATE
# [OF ...]`, `WITH LOCK [SKIP LOCKED]`, `OPTIMIZE FOR ...`. This
# single-snapshot server does not act on them (it holds one read view
# and picks its own plan), but their ROWS are the plain query's, so it
# strips them and answers.
#
# FOR UPDATE and OPTIMIZE are lenient (the engine takes them over a view,
# CTE, join or aggregate too). WITH LOCK is not: the engine takes it over
# a single PHYSICAL base table, or an all-`UNION ALL` chain of exactly
# those, and refuses everything else with one of three -104 messages:
#
#   -WITH LOCK can be used only with a single physical table   (336397326)
#   -WITH LOCK cannot be used with aggregates                  (336397328)
#   -WITH LOCK cannot be used with @1                          (336397329)
#
# the last naming DISTINCT or UNION. When a statement breaks several
# rules the engine reports ONE, in the order
# UNION > single-physical-table > aggregates > DISTINCT; in a chain the
# FIRST bad branch left to right supplies it.
#
# Both servers run the same statements and the FULL isql answer is
# compared - rows for what the engine locks, and the whole error text for
# what it refuses, so a bare `Dynamic SQL Error` cannot pass for the
# engine's named vector.
#
#   qa/serve-real-rowlock.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4893}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-rowlock-crab.fdb"; B="$D/fc-rowlock-engine.fdb"
LOG="/tmp/fc-serve-rowlock-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

for db in "127.0.0.1/$REAL:$B" "127.0.0.1/$PORT:$A"; do
    "$ISQL" -q -user "$U" -pas "$P" "$db" <<'EOF' >/dev/null 2>&1
CREATE TABLE T (ID INTEGER, V INTEGER);
INSERT INTO T VALUES (1, 10); INSERT INTO T VALUES (2, 20); INSERT INTO T VALUES (3, 30);
CREATE TABLE T2 (ID INTEGER, V INTEGER);
INSERT INTO T2 VALUES (7, 70); INSERT INTO T2 VALUES (8, 80);
CREATE VIEW VW AS SELECT ID, V FROM T;
COMMIT;
EOF
done
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/rl.sql" 2>&1 | norm; }

# the FULL isql answer for ONE statement - rows when it answers, the
# whole error text when it refuses
out_of() { printf 'SET LIST ON;\n%s;\n' "$2" > "$D/rl.sql"
    "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/rl.sql" 2>&1 | norm; }
# both servers must answer IDENTICALLY, and neither may answer NOTHING -
# an unreachable server says nothing, and two silences are not agreement
same() {
    ran=$((ran + 1))
    e=$(out_of "127.0.0.1/$REAL:$B" "$2"); c=$(out_of "127.0.0.1/$PORT:$A" "$2")
    if [ -z "$e" ] || [ -z "$c" ]; then
        echo "DIFF $1 - a side answered NOTHING (eng=[$e] fc=[$c])"; fail=1; return; fi
    if [ "$e" = "$c" ]; then echo "OK   $1  [$e]"
    else echo "DIFF $1"; echo "     fc:  [$c]"; echo "     eng: [$e]"; fail=1; fi
}

echo "--- 1. the clauses strip: the rows are the plain query's ------------"
cat > "$D/rl.sql" <<'SQL'
SET LIST ON;
SELECT ID FROM T WHERE ID = 1 WITH LOCK;
SELECT ID FROM T ORDER BY ID FOR UPDATE;
SELECT ID FROM T ORDER BY ID FOR UPDATE WITH LOCK;
SELECT ID FROM T ORDER BY ID FOR UPDATE OF V;
SELECT ID FROM T ORDER BY ID ROWS 2 FOR UPDATE WITH LOCK;
SELECT ID FROM T WHERE ID = 1 WITH LOCK SKIP LOCKED;
SELECT ID FROM T ORDER BY ID OPTIMIZE FOR FIRST ROWS;
SELECT ID FROM T ORDER BY ID WITH LOCK;
SELECT ID FROM VW ORDER BY ID FOR UPDATE;
WITH C AS (SELECT ID FROM T) SELECT ID FROM C ORDER BY ID FOR UPDATE;
SELECT COUNT(*) AS C FROM T OPTIMIZE FOR FIRST ROWS;
SQL
check "FOR UPDATE / WITH LOCK / OPTIMIZE - the rows are the plain query's" "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

echo "--- 2. shapes the engine LOCKS: the rows must match ------------------"
same "single physical table                " "SELECT ID FROM T WITH LOCK"
same "ORDER BY over one table              " "SELECT ID FROM T ORDER BY ID WITH LOCK"
same "a subquery in the WHERE              " "SELECT ID FROM T WHERE ID IN (SELECT ID FROM T WHERE ID > 1) WITH LOCK"
same "FIRST prefix                         " "SELECT FIRST 2 ID FROM T WITH LOCK"
same "SKIP prefix                          " "SELECT SKIP 1 ID FROM T WITH LOCK"
same "FIRST + SKIP                         " "SELECT FIRST 2 SKIP 1 ID FROM T WITH LOCK"
# `FIRST (<expr>)` is a PRE-EXISTING planner gap, not a row-locking one:
# fc reads the parenthesised argument as a call and answers -804
# "Function unknown FIRST", with or without the lock (it fails the same
# way on the binary before this slice). Recorded here rather than gated
# as an equality, and self-expiring when the planner learns the form.
ran=$((ran + 1))
e=$(out_of "127.0.0.1/$REAL:$B" "SELECT FIRST (1+1) ID FROM T WITH LOCK")
c=$(out_of "127.0.0.1/$PORT:$A" "SELECT FIRST (1+1) ID FROM T WITH LOCK")
if printf '%s' "$e" | grep -q 'ID 1' && printf '%s' "$c" | grep -q 'Function unknown'; then
    echo "OK   recorded: FIRST (expr) is a planner gap - engine answers, fc says -804"
else
    echo "DIFF FIRST (expr) moved - eng=[$e] fc=[$c]"; fail=1
fi
same "IS DISTINCT FROM in the projection   " "SELECT ID, V IS DISTINCT FROM 10 AS D FROM T WITH LOCK"
same "IS NOT DISTINCT FROM                 " "SELECT ID, V IS NOT DISTINCT FROM 10 AS D FROM T WITH LOCK"
same "IS DISTINCT FROM in the WHERE        " "SELECT ID FROM T WHERE V IS DISTINCT FROM 10 WITH LOCK"
same "a 'DISTINCT' LITERAL                 " "SELECT ID, 'DISTINCT' AS W FROM T WITH LOCK"
echo "    an all-UNION ALL chain of plain tables is locked too:"
same "UNION ALL, two plain tables          " "SELECT ID FROM T UNION ALL SELECT ID FROM T2 WITH LOCK"
same "UNION ALL, three branches            " "SELECT ID FROM T UNION ALL SELECT ID FROM T2 UNION ALL SELECT ID FROM T WITH LOCK"
same "UNION ALL, branches with a WHERE     " "SELECT ID FROM T WHERE ID > 0 UNION ALL SELECT ID FROM T2 WHERE ID > 0 WITH LOCK"
same "UNION ALL, aliased branches          " "SELECT X.ID FROM T X UNION ALL SELECT Y.ID FROM T2 Y WITH LOCK"
same "UNION ALL, a FIRST in one branch     " "SELECT ID FROM T UNION ALL SELECT FIRST 1 ID FROM T2 WITH LOCK"

echo "--- 3. the engine REFUSES: the whole -104 vector must match ----------"
same "DISTINCT                             " "SELECT DISTINCT ID FROM T WITH LOCK"
same "DISTINCT after FIRST                 " "SELECT FIRST 2 DISTINCT ID FROM T WITH LOCK"
same "DISTINCT after SKIP                  " "SELECT SKIP 1 DISTINCT ID FROM T WITH LOCK"
same "DISTINCT after FIRST + SKIP          " "SELECT FIRST 2 SKIP 1 DISTINCT ID FROM T WITH LOCK"
same "DISTINCT after FIRST (expr)          " "SELECT FIRST (1+1) DISTINCT ID FROM T WITH LOCK"
same "an aggregate                         " "SELECT COUNT(*) FROM T WITH LOCK"
same "COUNT(DISTINCT x) - an AGGREGATE     " "SELECT COUNT(DISTINCT ID) FROM T WITH LOCK"
same "GROUP BY                             " "SELECT ID FROM T GROUP BY ID WITH LOCK"
same "a join                               " "SELECT T.ID FROM T JOIN T2 ON T.ID = T2.ID WITH LOCK"
same "a derived table                      " "SELECT ID FROM (SELECT ID FROM T) X WITH LOCK"
same "a CTE                                " "WITH C AS (SELECT ID FROM T) SELECT ID FROM C WITH LOCK"
same "a view                               " "SELECT ID FROM VW WITH LOCK"
same "a bare UNION                         " "SELECT ID FROM T UNION SELECT ID FROM T2 WITH LOCK"
echo "    precedence: UNION > single table > aggregates > DISTINCT"
same "DISTINCT + join   -> single table    " "SELECT DISTINCT T.ID FROM T JOIN T2 ON T.ID = T2.ID WITH LOCK"
same "aggregate + join  -> single table    " "SELECT COUNT(*) FROM T JOIN T2 ON T.ID = T2.ID WITH LOCK"
same "DISTINCT + aggregate -> aggregates   " "SELECT DISTINCT COUNT(*) FROM T WITH LOCK"
same "DISTINCT + GROUP BY  -> aggregates   " "SELECT DISTINCT ID FROM T GROUP BY ID WITH LOCK"
same "bare UNION + agg branch  -> UNION    " "SELECT COUNT(*) FROM T UNION SELECT ID FROM T2 WITH LOCK"
same "bare UNION + join branch -> UNION    " "SELECT T.ID FROM T JOIN T2 ON T.ID = T2.ID UNION SELECT ID FROM T2 WITH LOCK"
same "mixed ALL then bare      -> UNION    " "SELECT ID FROM T UNION ALL SELECT ID FROM T2 UNION SELECT ID FROM T WITH LOCK"
same "mixed bare then ALL      -> UNION    " "SELECT ID FROM T UNION SELECT ID FROM T2 UNION ALL SELECT ID FROM T WITH LOCK"
echo "    in an ALL chain the FIRST bad branch supplies the message"
same "branch DISTINCT                      " "SELECT DISTINCT ID FROM T UNION ALL SELECT ID FROM T2 WITH LOCK"
same "LAST branch DISTINCT                 " "SELECT ID FROM T UNION ALL SELECT DISTINCT ID FROM T2 WITH LOCK"
same "branch aggregate                     " "SELECT COUNT(*) FROM T UNION ALL SELECT ID FROM T2 WITH LOCK"
same "branch GROUP BY                      " "SELECT ID FROM T UNION ALL SELECT ID FROM T2 GROUP BY ID WITH LOCK"
same "branch join                          " "SELECT T.ID FROM T JOIN T2 ON T.ID = T2.ID UNION ALL SELECT ID FROM T2 WITH LOCK"
same "branch derived table                 " "SELECT ID FROM T UNION ALL SELECT ID FROM (SELECT ID FROM T2) X WITH LOCK"
same "branch view                          " "SELECT ID FROM T UNION ALL SELECT ID FROM VW WITH LOCK"
same "branch FIRST + DISTINCT              " "SELECT ID FROM T UNION ALL SELECT FIRST 1 DISTINCT ID FROM T2 WITH LOCK"
same "agg branch then DISTINCT branch      " "SELECT COUNT(*) FROM T UNION ALL SELECT DISTINCT ID FROM T2 WITH LOCK"
same "DISTINCT branch then agg branch      " "SELECT DISTINCT ID FROM T UNION ALL SELECT COUNT(*) FROM T2 WITH LOCK"
same "DISTINCT branch then join branch     " "SELECT DISTINCT ID FROM T UNION ALL SELECT T.ID FROM T JOIN T2 ON T.ID = T2.ID WITH LOCK"

echo "--- 4. RECORDED divergence: an ALL chain under ORDER BY --------------"
# The engine ANSWERS ZERO ROWS here - measured on two databases against
# three controls (8 rows without the ORDER BY, 8 without the lock, 0 with
# both; 0 for DESC and for three branches too). fire-crab cannot
# reproduce that, and answering the rows would be WRONG where the engine
# returns none, so it refuses. This cell EXPIRES ITSELF if either side
# moves.
for q in "SELECT ID FROM T UNION ALL SELECT ID FROM T2 ORDER BY 1 WITH LOCK" \
         "SELECT ID FROM T UNION ALL SELECT ID FROM T2 ORDER BY 1 DESC WITH LOCK"; do
    ran=$((ran + 1))
    e=$(out_of "127.0.0.1/$REAL:$B" "$q"); c=$(out_of "127.0.0.1/$PORT:$A" "$q")
    if [ -z "$e" ] && printf '%s' "$c" | grep -q 'SQLSTATE'; then
        echo "OK   recorded: engine answers ZERO rows, fc refuses: ${q:0:52}"
    else
        echo "DIFF the ORDER BY divergence MOVED - eng=[$e] fc=[$c]"; fail=1
    fi
done
# the controls that make the cell above mean something
same "control: the chain WITHOUT the ORDER " "SELECT ID FROM T UNION ALL SELECT ID FROM T2 WITH LOCK"
same "control: the ORDER without the lock  " "SELECT ID FROM T UNION ALL SELECT ID FROM T2 ORDER BY 1"
same "control: ORDER + lock, ONE table     " "SELECT ID FROM T ORDER BY 1 WITH LOCK"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
