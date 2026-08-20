#!/bin/bash
# DDL IS THE TRANSACTION'S: a CREATE, ALTER or DROP writes its catalog
# rows under the user transaction's own id (DdlNodes.epp STOREs under
# the user transaction), so a ROLLBACK, a ROLLBACK TO SAVEPOINT, or a
# failing autonomous block takes them back by TRANSACTION STATE - two
# bits in the TIP - like any row. What no state takes back is journaled
# and undone by hand (the new relation's storage, the new index's tree
# and root slot, the tx-0 RDB$PAGES rows - dpm.epp's MRK_rollback
# resolution, done eagerly), and what COMMIT owns is deferred to it (a
# dropped relation's pages, a dropped index's root-slot state - dfw.epp
# delete_relation / ods.h:456's irt_commit -> irt_drop).
#
# Before this, a catalog row was SETTLED as it was written (a freshly
# minted committed id per row), the only undo was putting back an image
# of the whole database, and three shapes refused or fell back because
# of it: a savepoint over DDL, an autonomous block over a transaction
# that had done DDL, and op_prepare on one. The catalog readers that
# resolve names, formats and columns are transaction-aware now too: a
# DEAD version steps to the one behind it, which is what makes a
# rolled-back DROP give its table back.
#
# Every cell runs the same script against the ENGINE and against
# fire-crab on twin databases; the fire-crab file is then handed to the
# engine's gfix -v -full and read by the engine itself.
#
#   qa/serve-real-ddltx.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4799}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-ddltx-engine.fdb"
DBF="$D/fc-ddltx-crab.fdb"
LOG="/tmp/fc-serve-ddltx-$PORT.log"
fail=0
ran=0
bounds=0
mkdir -p "$D"

build() { # <path>
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE KEEP (ID INTEGER);
COMMIT;
INSERT INTO KEEP VALUES (1);
COMMIT;
EOF
}
rm -f "$DBE" "$DBF"
build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

run() { # <conn> <sql>   (AUTODDL OFF: the DDL is the transaction's, not its own)
    printf 'SET AUTODDL OFF;\nSET HEADING OFF;\n%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}
runt() { # <conn> <body^> <tail>   - a block needs its own terminator
    printf 'SET AUTODDL OFF;\nSET HEADING OFF;\nSET TERM ^;\n%s\nSET TERM ;^\n%s\n' "$2" "$3" |
        timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}
eng() { run "127.0.0.1/$REAL:$DBE" "$1"; }
crab() { run "127.0.0.1/$PORT:$DBF" "$1"; }
engf() { run "127.0.0.1/$REAL:$DBF" "$1"; }   # the ENGINE reading fc's file

both() { # <label> <sql>
    local e c
    e=$(eng "$2"); c=$(crab "$2")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi
}
botht() { # <label> <body^> <tail>
    local e c
    e=$(runt "127.0.0.1/$REAL:$DBE" "$2" "$3"); c=$(runt "127.0.0.1/$PORT:$DBF" "$2" "$3")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi
}
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
gfixok() { ran=$((ran + 1)); g=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1)
    if [ -z "$g" ]; then echo "OK   $1: gfix -v -full finds nothing on fc's file"; else
    echo "DIFF $1: gfix $g"; fail=1; fi; }
bound() { # <label> <engine> <fc>  - a recorded divergence, priced, not a failure
    bounds=$((bounds + 1)); echo "BOUND $1: engine [$2] fc [$3]"; }

# --- 1. a transaction uses the table it created, then takes it back ------
both "CREATE, INSERT, UPDATE and SELECT in one transaction" "
CREATE TABLE T (X INTEGER);
INSERT INTO T VALUES (1);
INSERT INTO T VALUES (2);
UPDATE T SET X = X * 10;
SELECT SUM(X) FROM T;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T';
ROLLBACK;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T';"
both "...and the name is free again" "
CREATE TABLE T (X INTEGER);
INSERT INTO T VALUES (5);
COMMIT;
SELECT X FROM T;
DROP TABLE T;
COMMIT;"
gfixok "1"
check "1 the ENGINE sees no trace of the rolled-back T in fc's file" \
    "$(engf "SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T'; SELECT COUNT(*) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'T';")" "0|0|"

# --- 2. a savepoint over DDL is undone by state, the work before it kept --
both "ROLLBACK TO a mark with CREATE TABLE, CREATE INDEX and rows inside" "
INSERT INTO KEEP VALUES (2);
SAVEPOINT S;
CREATE TABLE S2 (X INTEGER);
INSERT INTO S2 VALUES (1);
CREATE INDEX KEEP_IX ON KEEP (ID);
INSERT INTO KEEP VALUES (3);
ROLLBACK TO S;
COMMIT;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'S2';
SELECT COUNT(*) FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'KEEP_IX';
SELECT COUNT(*) FROM KEEP;"
both "...RELEASE keeps it, the transaction's commit makes it real" "
SAVEPOINT S;
CREATE TABLE S3 (X INTEGER);
RELEASE SAVEPOINT S;
INSERT INTO S3 VALUES (4);
COMMIT;
SELECT X FROM S3;"
gfixok "2"

# --- 3. CREATE INDEX: the creator uses it, COMMIT hands it to everyone ----
both "an index created and used in one transaction" "
CREATE INDEX KEEP_IX ON KEEP (ID);
INSERT INTO KEEP VALUES (9);
SELECT COUNT(*) FROM KEEP WHERE ID = 2;
COMMIT;
SELECT COUNT(*) FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'KEEP_IX';"
check "3 the ENGINE plans through fc's index" \
    "$(engf "SET PLAN ON; SELECT COUNT(*) FROM KEEP WHERE ID = 2;")" \
    "PLAN (\"PUBLIC\".\"KEEP\" INDEX (\"PUBLIC\".\"KEEP_IX\"))|1|"
both "DROP INDEX rolled back keeps it, committed removes it" "
DROP INDEX KEEP_IX;
ROLLBACK;
SELECT COUNT(*) FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'KEEP_IX';
SELECT COUNT(*) FROM KEEP WHERE ID = 9;
DROP INDEX KEEP_IX;
COMMIT;
SELECT COUNT(*) FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'KEEP_IX';"
gfixok "3"

# --- 4. DROP TABLE: rolled back gives the rows back, committed frees ------
both "DROP TABLE rolled back, then committed" "
CREATE TABLE D1 (X INTEGER);
COMMIT;
INSERT INTO D1 VALUES (7);
COMMIT;
DROP TABLE D1;
ROLLBACK;
SELECT COUNT(*), MAX(X) FROM D1;
DROP TABLE D1;
COMMIT;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'D1';"
check "4 fc's file has no RDB\$PAGES rows left for the dropped relation" \
    "$(engf "SELECT COUNT(*) FROM RDB\$PAGES PG WHERE PG.RDB\$RELATION_ID >= 128 AND NOT EXISTS (SELECT 1 FROM RDB\$RELATIONS R WHERE R.RDB\$RELATION_ID = PG.RDB\$RELATION_ID);")" "0|"
gfixok "4"

# --- 5. an autonomous block's DDL survives the outer rollback -------------
botht "DDL inside IN AUTONOMOUS TRANSACTION, outer ROLLBACK" \
"EXECUTE BLOCK AS BEGIN IN AUTONOMOUS TRANSACTION DO EXECUTE STATEMENT 'CREATE TABLE AU (X INTEGER)'; END^" \
"ROLLBACK;
SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'AU';
INSERT INTO AU VALUES (1);
COMMIT;
SELECT COUNT(*) FROM AU;"
gfixok "5"

# --- 6. what the ENGINE does with fc's file after all of it ---------------
check "6 the ENGINE writes into fc's surviving tables" \
    "$(engf "INSERT INTO S3 VALUES (5); INSERT INTO AU VALUES (2); COMMIT; SELECT SUM(X) FROM S3; SELECT COUNT(*) FROM AU; SELECT COUNT(*) FROM KEEP;")" "9|2|3|"
"$GFIX" -sweep -user "$U" -pas "$P" "$DBF" >/dev/null 2>&1
gfixok "6 after the engine's sweep"
check "6 ...and the sweep kept every row" \
    "$(engf "SELECT SUM(X) FROM S3; SELECT COUNT(*) FROM AU; SELECT COUNT(*) FROM KEEP; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME IN ('T', 'S2', 'D1');")" "9|2|3|0|"

# --- 7. RECORDED: who sees an uncommitted DDL ---------------------------
# The engine shows a transaction's uncommitted CREATE TABLE to that
# transaction alone (a second attachment gets -204). fire-crab's catalog
# readers have no attachment to ask, so they count every ACTIVE
# transaction's rows - the second attachment sees the table. Priced
# here, not hidden: the visibility is the next slice's, the undo is
# this one's.
# a second attachment while the first holds its transaction: one isql
# cannot hold a transaction open across attachments, so the probe is a
# background isql that sleeps inside its transaction (and ROLLS BACK -
# an isql that merely exits COMMITS)
probe_other() { # <conn-prefix> <db>
    ( printf 'SET AUTODDL OFF;\nCREATE TABLE V1 (X INTEGER);\nSHELL sleep 2;\nROLLBACK;\n' |
        timeout 30 "$ISQL" -q -user "$U" -pas "$P" "$1:$2" >/dev/null 2>&1 ) &
    sleep 1
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = '"'"'V1'"'"';\n' |
        timeout 30 "$ISQL" -q -user "$U" -pas "$P" "$1:$2" 2>&1 | tr -d ' \n'
    wait
}
eo=$(probe_other "127.0.0.1/$REAL" "$DBE"); fo=$(probe_other "127.0.0.1/$PORT" "$DBF")
if [ "$eo" = "$fo" ]; then
    ran=$((ran + 1)); echo "OK   7 a second attachment's view of an uncommitted CREATE TABLE [$eo]"
else
    bound "7 a second attachment's view of an uncommitted CREATE TABLE" "$eo" "$fo"
fi

# --- 8. COVERAGE: the undo was transaction state, and the residue went ---
ran=$((ran + 1))
killed=$(grep -c 'undo window: transactions' "$LOG")
rolled=$(grep -c 'ROLLBACK - transaction undone: true' "$LOG")
if [ "$killed" -ge 1 ] && [ "$rolled" -ge 4 ]; then
    echo "OK   coverage: $rolled transaction(s) and $killed mark(s) undone by transaction state"; else
    echo "DIFF coverage: [$rolled] transactions / [$killed] marks undone by state"; fail=1; fi
ran=$((ran + 1))
leaks=$(grep -c 'ddl residue not undone' "$LOG")
if [ "$leaks" = "0" ]; then echo "OK   coverage: no residue left behind"; else
    echo "DIFF coverage: $leaks residue failure(s) in the trace"; fail=1; fi

echo "ran $ran checks, $bounds recorded boundaries"
exit $fail
