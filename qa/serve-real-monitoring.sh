#!/bin/bash
# THE MONITORING TABLES - and the all-NULL row they used to answer.
#
# `MON$DATABASE`, `MON$ATTACHMENTS` and their siblings are real catalog
# relations (MON$DATABASE is relation 33, with 28 fields), and the
# engine fills them from its live state. This server kept no such state,
# so every MON$ query was answered by ONE ALL-NULL ROW whatever it
# asked - which is worse than empty: `SELECT COUNT(*) FROM
# MON$ATTACHMENTS` answered NULL, and COUNT never answers NULL, under a
# column called `C0` rather than the name the query gave it.
#
# Now they go down the ORDINARY path, described from the catalog like
# any other relation:
#
#   * `MON$DATABASE` is COMPUTED - one row of what this server knows for
#     certain about the file it has open, read through the same header
#     decoder gstat and gfix use;
#   * `MON$ATTACHMENTS` is COMPUTED too - one row per live attachment,
#     from a registry each session keeps: who attached, from what
#     address, over what protocol, and whether the wire is encrypted;
#   * `MON$TRANSACTIONS` too - every attachment's live transactions,
#     with the one its statements run under marked ACTIVE;
#   * `MON$STATEMENTS` too, with its SQL text as a COMPUTED BLOB - the
#     machinery LIST() brought - so the statement a server reports as
#     running is the query asking, and both must answer the same text;
#   * every other MON$ table scans its own (empty) storage and answers
#     NO ROWS, with the right shape and the right column names.
#
# The second is a RECORDED DIVERGENCE, asserted below so a change shows:
# the engine lists live attachments and statements and this server does
# not. An empty relation of the right shape is something a client can
# read; the all-NULL row was not.
#
# WHAT IS COMPARED against the engine: the facts OF THE FILE, which must
# agree exactly. What is NOT: the live counters (MON$NEXT_TRANSACTION
# moves as each server works) and the runtime figures (MON$PAGE_BUFFERS
# is the engine's cache size, and this server's cache is not that) -
# those are asserted locally instead.
#
#   qa/serve-real-monitoring.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4989}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-mon-crab.fdb"
LOG="/tmp/fc-serve-mon-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
rm -f "$A"
"$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 <<SQL
CREATE DATABASE '$A' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER);
COMMIT;
INSERT INTO T VALUES (1);
COMMIT;
SQL
chmod 666 "$A"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# BOTH servers over the SAME file - a monitoring table is about the file
# and the server, so there is nothing to keep two copies of
both() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
fc() { printf 'SET LIST ON;\n%s\n' "$1" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm; }

# ---- the facts of the file, which must agree ---------------------------
both "the file's own facts: page size, ODS, dialect, flags" \
  "SELECT MON\$PAGE_SIZE AS PS, MON\$ODS_MAJOR AS ODSMAJ, MON\$ODS_MINOR AS ODSMIN,
          MON\$SQL_DIALECT AS DIA, MON\$FORCED_WRITES AS FW, MON\$RESERVE_SPACE AS RS,
          MON\$READ_ONLY AS RO, MON\$SHUTDOWN_MODE AS SD, MON\$BACKUP_STATE AS BK,
          MON\$REPLICA_MODE AS RM, MON\$CRYPT_STATE AS CS
   FROM MON\$DATABASE;"
both "...its name, GUID, security database and page count" \
  "SELECT MON\$DATABASE_NAME AS NM, MON\$GUID AS G, MON\$SEC_DATABASE AS SEC,
          MON\$PAGES AS PG, MON\$SWEEP_INTERVAL AS SW
   FROM MON\$DATABASE;"
both "MON\$DATABASE is ONE row" \
  "SELECT COUNT(*) AS N FROM MON\$DATABASE;"
both "...and the ordinary clauses work over it" \
  "SELECT MON\$PAGE_SIZE AS PS FROM MON\$DATABASE WHERE MON\$PAGE_SIZE > 1024 ORDER BY 1;"
both "...and a WHERE that matches nothing answers nothing" \
  "SELECT MON\$PAGE_SIZE AS PS FROM MON\$DATABASE WHERE MON\$PAGE_SIZE = 1;"

# ---- MON$ATTACHMENTS names the live attachments -------------------------
# what the SERVER knows about each: who attached, from where, over what,
# and whether the wire is encrypted
ran=$((ran + 1))
r=$(fc "SELECT MON\$USER AS U, MON\$ATTACHMENT_NAME AS NM, MON\$STATE AS ST,
        MON\$WIRE_ENCRYPTED AS ENC, MON\$ROLE AS RO, MON\$REMOTE_PROTOCOL AS PR
        FROM MON\$ATTACHMENTS;")
case "$r" in
    "U SYSDBA|NM $A|ST 1|ENC <true>|RO NONE|PR TCPv4|")
        echo "OK   an attachment names itself: user, file, state, wire, protocol" ;;
    *) echo "DIFF MON\$ATTACHMENTS row: [$r]"; fail=1 ;;
esac
# ...and the address is the PEER, which only the server can know
ran=$((ran + 1))
r=$(fc "SELECT MON\$REMOTE_ADDRESS AS ADDR FROM MON\$ATTACHMENTS;")
case "$r" in
    "ADDR 127.0.0.1/"*) echo "OK   ...and its remote address is the peer" ;;
    *) echo "DIFF remote address: [$r]"; fail=1 ;;
esac
# THE COUNT FOLLOWS THE CONNECTIONS. One held open makes two; when it
# goes, one again - which is the whole point of a monitoring table.
alone=$(fc "SELECT COUNT(*) AS N FROM MON\$ATTACHMENTS;")
( printf 'SELECT 1 FROM RDB\$DATABASE;\n'; sleep 4 ) \
    | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1 &
sleep 1.5
held=$(fc "SELECT COUNT(*) AS N FROM MON\$ATTACHMENTS;")
sleep 5
after=$(fc "SELECT COUNT(*) AS N FROM MON\$ATTACHMENTS;")
check "the count follows the connections (1, then 2, then 1)" \
    "$alone/$held/$after" "N 1|/N 2|/N 1|"
# the columns a CLIENT sends and this server does not retain answer
# NULL rather than a guess
ran=$((ran + 1))
r=$(fc "SELECT COUNT(*) AS N FROM MON\$ATTACHMENTS
        WHERE MON\$REMOTE_PID IS NULL AND MON\$REMOTE_PROCESS IS NULL;")
case "$r" in
    "N 1|") echo "OK   the DPB-sent columns answer NULL, not a guess" ;;
    *) echo "DIFF DPB columns: [$r]"; fail=1 ;;
esac
# ---- MON$TRANSACTIONS names the live transactions ----------------------
# a SNAPSHOT transaction is mode 1 and ACTIVE on BOTH servers - which is
# the comparison that can be made, because the DEFAULT isolation is not
# the same thing on the two (below)
both "a SNAPSHOT transaction: mode, state and read-only" \
  "SET TRANSACTION SNAPSHOT;
   SELECT MON\$ISOLATION_MODE AS ISO, MON\$STATE AS ST, MON\$READ_ONLY AS RO
   FROM MON\$TRANSACTIONS WHERE MON\$ISOLATION_MODE = 1;
   COMMIT;"
both "...and a READ ONLY one says so" \
  "SET TRANSACTION READ ONLY SNAPSHOT;
   SELECT MON\$READ_ONLY AS RO FROM MON\$TRANSACTIONS WHERE MON\$ISOLATION_MODE = 1;
   COMMIT;"
# every transaction belongs to an attachment this server also names
ran=$((ran + 1))
r=$(fc "SELECT COUNT(*) AS N FROM MON\$TRANSACTIONS t
        JOIN MON\$ATTACHMENTS a ON a.MON\$ATTACHMENT_ID = t.MON\$ATTACHMENT_ID;")
case "$r" in
    "N 0|") echo "DIFF no transaction joined an attachment: [$r]"; fail=1 ;;
    *) echo "OK   every transaction names an attachment this server lists ($r)" ;;
esac
# THE RECORDED DIVERGENCE IN WHAT THE SERVERS DO, not in what they
# report: the engine's default read committed is READ CONSISTENCY (mode
# 4) and this server reads the latest committed version (mode 2). Each
# reports what it actually does.
ran=$((ran + 1))
c=$(fc "SELECT MON\$ISOLATION_MODE AS ISO FROM MON\$TRANSACTIONS WHERE MON\$STATE = 0;")
e=$(printf 'SET LIST ON;\nSELECT MON$ISOLATION_MODE AS ISO FROM MON$TRANSACTIONS WHERE MON$STATE = 0;\n' \
    | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 | norm)
case "$c/$e" in
    "ISO 2|/ISO 4|") echo "OK   divergence recorded: read committed is mode 2 here, 4 (read consistency) there" ;;
    *) echo "DIFF isolation modes moved: fc [$c] engine [$e]"; fail=1 ;;
esac

# ---- MON$STATEMENTS names what is being asked --------------------------
# the strongest comparison on this surface: the statement a server
# reports as running IS the query asking, so both must answer the same
# TEXT - and MON$SQL_TEXT is a BLOB, minted for a computed row
# CAST, so the TEXT is compared and not the blob's id: a computed blob
# is minted from this server's own range (0:40000001) where the engine
# hands out 0:1, and neither number is a fact about the statement
both "the running statement, its state and its SQL text" \
  "SELECT MON\$STATE AS ST, CAST(MON\$SQL_TEXT AS VARCHAR(200)) AS SQLT FROM MON\$STATEMENTS;"
# ...and it belongs to an attachment and a transaction this server also
# names, which is what makes the four tables one picture
ran=$((ran + 1))
r=$(fc "SELECT COUNT(*) AS N FROM MON\$STATEMENTS s
        JOIN MON\$ATTACHMENTS a ON a.MON\$ATTACHMENT_ID = s.MON\$ATTACHMENT_ID
        JOIN MON\$TRANSACTIONS t ON t.MON\$TRANSACTION_ID = s.MON\$TRANSACTION_ID;")
case "$r" in
    "N 0|") echo "DIFF the statement joined no attachment and transaction: [$r]"; fail=1 ;;
    *) echo "OK   a statement joins the attachment and transaction it runs in ($r)" ;;
esac
# the tables this server still does not fill keep the right SHAPE:
# COUNT over an empty relation is 0, never the NULL the all-NULL row gave
ran=$((ran + 1))
r=$(fc "SELECT COUNT(*) AS N FROM MON\$CALL_STACK;")
case "$r" in
    "N 0|") echo "OK   COUNT over an unfilled MON\$ table is 0, not NULL" ;;
    *) echo "DIFF COUNT over MON\$CALL_STACK: [$r]"; fail=1 ;;
esac
ran=$((ran + 1))
r=$(fc "SELECT COUNT(*) AS N FROM MON\$IO_STATS;")
case "$r" in
    "N 0|") echo "OK   ...and over the statistics tables too" ;;
    *) echo "DIFF COUNT over MON\$IO_STATS: [$r]"; fail=1 ;;
esac

# ---- the engine still reads the file ------------------------------------
e=$(printf 'SET LIST ON; SELECT COUNT(*) AS N FROM T;\n' | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over the file this ran against" "$e" "N 1|"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
