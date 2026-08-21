#!/bin/bash
# MERGE (StmtNodes.cpp MergeNode): a LEFT join of the source onto the
# target, one action per joined row - the FIRST branch of the row's kind
# whose AND condition holds, in declaration order, or nothing (genBlr's
# if-else chain). A target row two source rows reach raises
# isc_merge_dup_update (SQLSTATE 21000, -811) and the whole statement is
# undone. The source may be a table or a derived table; the counts of
# the three verbs add up to isql's one "Records affected".
#
# fire-crab desugars per SOURCE ROW at execute: the pairs are read first
# against the state the statement started from (the engine's join is
# one cursor over that state - a row this MERGE deletes still pairs with
# a later source row, and raises), then each pair runs through the
# UPDATE / DELETE / INSERT planners this server already audits, the
# source's column references substituted as literals.
#
# Measured on the way: an UPDATE over a row whose head was a rolled-back
# DELETE's stub used to chain the stub in as a back version - a
# zero-length "full image" the ENGINE took for a record and BUGCHECKED
# on ("wrong record length (183)", vio.cpp:1902). The new head links
# past the stub now; the first cell pins it.
#
# WHEN NOT MATCHED BY SOURCE (the join turns FULL: every target row no
# source row reached gets its own pass) and RETURNING (Firebird 5 makes
# it a CURSOR: the after-image of each moved row, the old one for a
# DELETE; the target is named by its ALIAS when it has one; a bare name
# both sides carry is 42702 ambiguous; a source reference inside a BY
# SOURCE clause is 42S22 Column unknown, not NULL) are in.
#
# RECORDED: a MERGE that raises the duplicate-target error reports, on
# the engine, the rows it moved before the raise ("Records affected: 2")
# - fc reports 0, having read every pair before moving any. Those two
# cells compare without the count line.
#
#   qa/serve-real-merge.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4837}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-merge-engine.fdb"; DBF="$D/fc-merge-crab.fdb"
LOG="/tmp/fc-serve-merge-$PORT.log"
fail=0; ran=0
mkdir -p "$D"
build() {
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(10));
CREATE TABLE S (ID INTEGER, V VARCHAR(10));
CREATE TABLE N (ID INTEGER, V VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 't1'); INSERT INTO T VALUES (2, 't2'); INSERT INTO T VALUES (3, 't3');
INSERT INTO S VALUES (2, 's2'); INSERT INTO S VALUES (3, 'del'); INSERT INTO S VALUES (4, 's4');
INSERT INTO N VALUES (1, 'n1'); INSERT INTO N VALUES (1, 'n1b'); INSERT INTO N VALUES (5, 'n5');
COMMIT;
EOF
}
rm -f "$DBE" "$DBF" "$D/fc-merge.fbk"; build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D/fc-merge.fbk"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
run() { printf 'SET HEADING OFF;\nSET COUNT ON;\n%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g' | grep -v '^$' | tr '\n' '|'; }
eng() { run "127.0.0.1/$REAL:$DBE" "$1"; }
crab() { run "127.0.0.1/$PORT:$DBF" "$1"; }
both() { local e c; e=$(eng "$2"); c=$(crab "$2"); ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"; else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi; }
both_nocount() { local e c; e=$(eng "$2" | sed 's/Records affected: [0-9]*|//g'); c=$(crab "$2" | sed 's/Records affected: [0-9]*|//g'); ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"; else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi; }
# both sides refuse at prepare; the engine's vector names the column
# (42S22 / 42702) where fc answers the one DSQL error every refused
# statement gets - RECORDED. The SQLSTATE and the vector lines are
# stripped; what stays is that both refused and the state after.
refused() { sed 's/Statement failed, SQLSTATE = [0-9A-Z]*|/REFUSED|/; s/Dynamic SQL Error|//; s/SQL error code = -[0-9]*|//; s/-[^|]*|//g'; }
both_refused() { local e c; e=$(eng "$2" | refused); c=$(crab "$2" | refused); ran=$((ran + 1))
    if [ "$e" = "$c" ] && [ "${e#REFUSED}" != "$e" ]; then echo "OK   $1 [$e]"; else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

both "an UPDATE over a rolled-back DELETE's stub (the engine reads the chain)" \
    "DELETE FROM T WHERE ID = 2; ROLLBACK; UPDATE T SET V = 'again' WHERE ID = 2; COMMIT; SELECT * FROM T ORDER BY ID; UPDATE T SET V = 't2' WHERE ID = 2; COMMIT;"
both "MATCHED updates, NOT MATCHED inserts" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET V = S.V WHEN NOT MATCHED THEN INSERT (ID, V) VALUES (S.ID, S.V); SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "conditional branches, first in order wins; DELETE; an insert condition" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED AND S.V = 'del' THEN DELETE WHEN MATCHED THEN UPDATE SET V = S.V || '!' WHEN NOT MATCHED AND S.ID > 3 THEN INSERT VALUES (S.ID, 'new'); SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "a condition on the TARGET side" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED AND T.V = 't2' THEN UPDATE SET V = 'only2'; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "the second of two conditional branches" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED AND S.V = 'none' THEN DELETE WHEN MATCHED AND T.ID = 3 THEN UPDATE SET V = 'third'; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "no branch holds: nothing happens" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED AND S.V = 'zz' THEN UPDATE SET V = 'x'; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "a derived-table source" \
    "MERGE INTO T USING (SELECT ID, UPPER(V) AS V FROM S WHERE ID < 4) X ON T.ID = X.ID WHEN MATCHED THEN UPDATE SET V = X.V; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "aliases on both sides, a qualified SET target" \
    "MERGE INTO T AS tg USING S AS sr ON tg.ID = sr.ID WHEN MATCHED THEN UPDATE SET tg.V = sr.V; SELECT V FROM T WHERE ID = 2; ROLLBACK;"
both "expressions in the INSERT values, two insert branches" \
    "MERGE INTO T USING S ON 1 = 0 WHEN NOT MATCHED AND S.ID = 4 THEN INSERT VALUES (S.ID + 20, 'four') WHEN NOT MATCHED THEN INSERT VALUES (S.ID + 30, S.V); SELECT * FROM T ORDER BY ID; ROLLBACK;"
both_nocount "two source rows reach one target: isc_merge_dup_update, statement undone (counts: recorded)" \
    "INSERT INTO S VALUES (2, 'dup'); MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET V = S.V; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both_nocount "...a DELETE branch too (the pairs are read before any row moves)" \
    "INSERT INTO S VALUES (2, 'dup'); MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN DELETE; SELECT COUNT(*) FROM T; ROLLBACK;"
both "two inserts of one key: the PRIMARY KEY, not MERGE, refuses" \
    "MERGE INTO T USING N ON T.ID = N.ID + 100 WHEN NOT MATCHED THEN INSERT VALUES (N.ID, N.V); SELECT COUNT(*) FROM T; ROLLBACK;"
both "NOT MATCHED BY SOURCE updates the orphans (the join turns FULL)" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN NOT MATCHED BY SOURCE THEN UPDATE SET V = 'orphan'; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "all three kinds in one statement" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN NOT MATCHED BY SOURCE THEN DELETE WHEN MATCHED THEN UPDATE SET V = S.V WHEN NOT MATCHED BY TARGET THEN INSERT VALUES (S.ID, S.V); SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "two BY SOURCE branches, the first in order wins" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN NOT MATCHED BY SOURCE AND T.ID = 1 THEN UPDATE SET V = 'one' WHEN NOT MATCHED BY SOURCE THEN DELETE; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "a BY SOURCE condition that does not hold: nothing happens" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN NOT MATCHED BY SOURCE AND T.V = 'zz' THEN DELETE; SELECT * FROM T ORDER BY ID; ROLLBACK;"
both "a PK-less target: identical orphans move together" \
    "MERGE INTO N USING S ON N.ID = S.ID WHEN NOT MATCHED BY SOURCE AND N.ID = 1 THEN UPDATE SET V = 'o' WHEN NOT MATCHED BY SOURCE THEN DELETE; SELECT * FROM N ORDER BY ID, V; ROLLBACK;"
both_refused "a source reference inside BY SOURCE is Column unknown (fc refuses at prepare: recorded vector)" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN NOT MATCHED BY SOURCE AND S.ID IS NULL THEN UPDATE SET V = 'x'; SELECT COUNT(*) FROM T WHERE V = 'x'; ROLLBACK;"
both "RETURNING over a MERGE is a cursor: the after-image per moved row" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET V = S.V WHEN NOT MATCHED THEN INSERT VALUES (S.ID, S.V) RETURNING T.ID, T.V; ROLLBACK;"
both "RETURNING a DELETE branch answers the row as it was" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED AND S.V = 'del' THEN DELETE WHEN MATCHED THEN UPDATE SET V = S.V RETURNING T.ID, T.V; ROLLBACK;"
both "RETURNING through the target's alias, and NEW." \
    "MERGE INTO T tg USING S sr ON tg.ID = sr.ID WHEN MATCHED THEN UPDATE SET V = sr.V RETURNING tg.ID, NEW.V; ROLLBACK;"
both_refused "RETURNING with the alias: the table name is unknown" \
    "MERGE INTO T tg USING S sr ON tg.ID = sr.ID WHEN MATCHED THEN UPDATE SET V = sr.V RETURNING T.V; ROLLBACK;"
both_refused "RETURNING a bare name both sides carry: ambiguous (fc refuses at prepare: recorded vector)" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET V = S.V RETURNING V; SELECT COUNT(*) FROM T WHERE V = 's2'; ROLLBACK;"
both "RETURNING with no row moved: an empty cursor" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED AND 1 = 0 THEN UPDATE SET V = S.V RETURNING T.ID; ROLLBACK;"
both "RETURNING from the BY SOURCE pass" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN NOT MATCHED BY SOURCE THEN UPDATE SET V = 'orphan' RETURNING T.ID, T.V; ROLLBACK;"
both "committed" \
    "MERGE INTO T USING S ON T.ID = S.ID WHEN MATCHED THEN UPDATE SET V = S.V WHEN NOT MATCHED THEN INSERT VALUES (S.ID, S.V); COMMIT; SELECT * FROM T ORDER BY ID;"
check "the ENGINE reads the table fc merged" \
    "$(printf 'SET HEADING OFF;\nSELECT * FROM T ORDER BY ID;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$DBF" 2>&1 | tr -s ' \n' ' ')" " 1 t1 2 s2 3 del 4 s4 "
ran=$((ran + 1)); g=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1)
if [ -z "$g" ]; then echo "OK   gfix -v -full finds nothing on fc's file"; else echo "DIFF gfix: $g"; fail=1; fi
ran=$((ran + 1)); if "$GBAK" -b -user "$U" -pas "$P" "$DBF" "$D/fc-merge.fbk" >/dev/null 2>&1; then echo "OK   gbak -b carries fc's file"; else echo "DIFF gbak -b failed"; fail=1; fi
ran=$((ran + 1)); n=$(grep -c 'merge: ' "$LOG")
if [ "$n" -ge 8 ]; then echo "OK   coverage: $n merges ran through the per-row executor"; else echo "DIFF coverage: [$n] merges"; fail=1; fi
echo "ran $ran checks"
exit $fail
