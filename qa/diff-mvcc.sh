#!/bin/sh
# MVCC differential QA: freeze a database file WHILE a transaction
# holds uncommitted inserts, updates and deletes, then check that
# fire-crab's TIP-driven visibility walk (fcstat visible) reproduces
# the live engine's committed-only view exactly.
#
#   qa/diff-mvcc.sh <isql-conn-prefix> [workdir]
#   e.g. qa/diff-mvcc.sh localhost /tmp/fbhandson
#
# Choreography:
#   1. create a fresh database; commit 10 rows
#   2. a background connection applies UPDATE/DELETE/INSERT and holds
#      the transaction OPEN
#   3. ALTER DATABASE BEGIN BACKUP freezes the main file (the page
#      cache is flushed; subsequent writes go to the delta), the file
#      is copied, END BACKUP releases it
#   4. the engine's truth: SELECT from a fresh connection - committed
#      data only
#   5. fcstat visible on the frozen copy must equal (4); and to prove
#      the test is not vacuous, fcstat rows (the raw walk, which sees
#      the uncommitted versions) must DIFFER from it
#   6. the background transaction rolls back; the database is dropped

set -u
ISQL="${ISQL:-isql}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
HOST="${1:-localhost}"
WORK="${2:-/tmp/fbhandson}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

db="$WORK/mvcc_qa.fdb"
frozen="$WORK/mvcc_qa_frozen.fdb"
rm -f "$db" "$frozen"

"$ISQL" -q -user "$U" -pas "$P" <<EOF || exit 1
CREATE DATABASE '$HOST:$db';
CREATE TABLE VIS (ID INT NOT NULL PRIMARY KEY, NAME VARCHAR(20));
COMMIT;
EOF
"$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" <<'EOF' || exit 1
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INT = 1; BEGIN
  WHILE (I <= 10) DO BEGIN
    INSERT INTO VIS VALUES (:I, 'committed ' || :I); I = I + 1;
  END
END^
SET TERM ;^
COMMIT;
EOF

# background: uncommitted work held open for ~12s, then rolled back
{
    printf 'UPDATE VIS SET NAME = %s uncommitted%s WHERE ID <= 3;\n' "'" "'"
    printf 'DELETE FROM VIS WHERE ID IN (4, 5);\n'
    printf "INSERT INTO VIS VALUES (11, 'phantom 11');\n"
    printf "INSERT INTO VIS VALUES (12, 'phantom 12');\n"
    sleep 12
    printf 'ROLLBACK;\n'
} | "$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" &
bgpid=$!
sleep 3

# freeze + copy + thaw
"$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" <<'EOF'
ALTER DATABASE BEGIN BACKUP;
COMMIT;
EOF
cp "$db" "$frozen"
"$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" <<'EOF'
ALTER DATABASE END BACKUP;
COMMIT;
EOF

# the engine's committed-only truth (fresh connection, fresh snapshot)
engine=$("$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$db" <<'EOF' | sed 's/[[:space:]]*$//' | grep -v '^$' | sort
SET HEADING OFF;
SELECT ID || '|' || TRIM(NAME) FROM VIS;
EOF
)

relid=$("$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$db" <<'EOF' | tr -d ' \n'
SET HEADING OFF;
SELECT RDB$RELATION_ID FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'VIS';
EOF
)

"$FCSTAT" visible "$frozen" "$relid" 2>/tmp/mvcc_stats.txt >/dev/null
visible=$("$FCSTAT" visible "$frozen" "$relid" 2>/dev/null \
    | awk -F'\t' '{print $1 "|" $2}' | sort)
raw=$("$FCSTAT" rows "$frozen" "$relid" 2>/dev/null \
    | awk -F'\t' '{print $1 "|" $2}' | sort)

wait "$bgpid" 2>/dev/null

fail=0
if [ "$engine" = "$visible" ]; then
    n=$(printf '%s\n' "$visible" | grep -c .)
    echo "OK   visibility: $n rows match the engine's committed-only view"
    echo "     $(cat /tmp/mvcc_stats.txt)"
else
    echo "DIFF visibility:"
    diff <(printf '%s\n' "$engine") <(printf '%s\n' "$visible") | sed 's/^/     /'
    fail=1
fi
if [ "$raw" = "$visible" ]; then
    echo "VACUOUS: raw walk equals visible walk - the uncommitted work never reached the frozen file"
    fail=1
else
    echo "OK   non-vacuous: the frozen file does contain the uncommitted versions"
    diff <(printf '%s\n' "$visible") <(printf '%s\n' "$raw") | grep -c '^[<>]' \
        | sed 's/^/     uncommitted-version lines in raw walk: /'
fi

"$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" <<'EOF'
DROP DATABASE;
EOF
rm -f "$frozen"
exit $fail
