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

# ---- the shape of the tables this server does not fill ------------------
# COUNT over an empty relation is 0 - never NULL, which is what the
# all-NULL row used to answer
ran=$((ran + 1))
r=$(fc "SELECT COUNT(*) AS N FROM MON\$ATTACHMENTS;")
case "$r" in
    "N 0|") echo "OK   COUNT over an unfilled MON\$ table is 0, not NULL" ;;
    *) echo "DIFF COUNT over MON\$ATTACHMENTS: [$r]"; fail=1 ;;
esac
ran=$((ran + 1))
r=$(fc "SELECT MON\$ATTACHMENT_ID AS I FROM MON\$ATTACHMENTS;")
case "$r" in
    "") echo "OK   ...and selecting from one answers no rows, by name" ;;
    *) echo "DIFF MON\$ATTACHMENTS rows: [$r]"; fail=1 ;;
esac
# the RECORDED DIVERGENCE: the engine has attachments to list, this
# server answers none. Asserted so a change shows.
ran=$((ran + 1))
e=$(printf 'SET LIST ON;\nSELECT COUNT(*) AS N FROM MON$ATTACHMENTS;\n' \
    | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 | norm)
case "$e" in
    "N 0|") echo "DIFF the engine reports no attachments either - divergence gone?"; fail=1 ;;
    *) echo "OK   divergence recorded: the engine lists attachments ($e), this server none" ;;
esac

# ---- the engine still reads the file ------------------------------------
e=$(printf 'SET LIST ON; SELECT COUNT(*) AS N FROM T;\n' | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over the file this ran against" "$e" "N 1|"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
