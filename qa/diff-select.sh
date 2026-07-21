#!/bin/sh
# Differential QA against live SELECT: for every user table in a
# database, compare fcstat's low-level record walk (pointer pages ->
# data pages -> primary record versions) against SELECT COUNT(*)
# through the C++ engine.
#
#   qa/diff-select.sh localhost:/path/db.fdb /path/db.fdb [workdir]
#
# arg1: connection string for isql (the ENGINE's view)
# arg2: the database file path for fcstat (the FILE's view)
#
# The comparison is exact only when the file contains no uncommitted
# work and no pending garbage, so the script first produces a CLEAN
# copy via gbak backup/restore (a restore materializes exactly the
# committed primary record versions, nothing else) and compares on
# that copy. This also exercises gbak's guarantee from the other side:
# fcstat re-derives the row counts from raw pages with no engine code.

set -u
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
CONN="${1:?usage: diff-select.sh <isql-conn-string> <file-path> [workdir]}"
FILE="${2:?usage: diff-select.sh <isql-conn-string> <file-path> [workdir]}"
WORK="${3:-/tmp/fbhandson}"
HOST="${CONN%%:*}"

base=$(basename "$FILE" .fdb)
fbk="$WORK/${base}_qa.fbk"
clean="$WORK/${base}_qa_clean.fdb"

"$GBAK" -b -g "$CONN" "$fbk" -user "${ISC_USER:-SYSDBA}" -pas "${ISC_PASSWORD:-masterkey}" || exit 1
rm -f "$clean"
"$GBAK" -c "$fbk" "$HOST:$clean" -user "${ISC_USER:-SYSDBA}" -pas "${ISC_PASSWORD:-masterkey}" || exit 1

# user tables: id, name (system tables excluded; views have no pages)
tables=$("$ISQL" -q -b -user "${ISC_USER:-SYSDBA}" -pas "${ISC_PASSWORD:-masterkey}" "$HOST:$clean" <<'EOF' | awk 'NF==2 && $1 ~ /^[0-9]+$/'
SET HEADING OFF;
SELECT r.RDB$RELATION_ID, TRIM(r.RDB$RELATION_NAME)
FROM RDB$RELATIONS r
WHERE COALESCE(r.RDB$SYSTEM_FLAG,0) = 0 AND r.RDB$VIEW_BLR IS NULL;
EOF
)

fail=0; checked=0
echo "$tables" | while read -r relid relname; do
    [ -z "$relid" ] && continue
    engine=$("$ISQL" -q -b -user "${ISC_USER:-SYSDBA}" -pas "${ISC_PASSWORD:-masterkey}" "$HOST:$clean" <<EOF | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM "$relname";
EOF
)
    file_side=$("$FCSTAT" records "$clean" "$relid" | awk '/primary records/ {print $3}')
    file_side=${file_side:-0}
    if [ "$engine" = "$file_side" ]; then
        echo "OK   $relname (rel $relid): $engine rows"
    else
        echo "DIFF $relname (rel $relid): engine=$engine fcstat=$file_side"
        fail=1
    fi
done

rm -f "$fbk"
exit $fail
