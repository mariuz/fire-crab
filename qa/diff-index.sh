#!/bin/sh
# Index differential QA: walk each single-segment PRIMARY KEY index at
# leaf level from the RAW FILE (fcstat index-walk: root descent, leaf
# chain, prefix decompression) and compare the resulting ROW ORDER
# against the live engine's `SELECT ... ORDER BY` — which navigates
# the same index. The walked record numbers are joined back to decoded
# rows (fcstat rows-recno), so the comparison is on actual column
# values in index order, not on internal ids.
#
#   qa/diff-index.sh <isql-conn-string> <file-path> [workdir]
#
# PK indices keep the comparison exact: single segment, NOT NULL, and
# unique — no NULL-ordering or duplicate-order ambiguity between the
# two sides.

set -u
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
CONN="${1:?usage: diff-index.sh <isql-conn-string> <file-path> [workdir]}"
FILE="${2:?usage: diff-index.sh <isql-conn-string> <file-path> [workdir]}"
WORK="${3:-/tmp/fbhandson}"
HOST="${CONN%%:*}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

base=$(basename "$FILE" .fdb)
fbk="$WORK/${base}_idx.fbk"
clean="$WORK/${base}_idx_clean.fdb"
"$GBAK" -b -g "$CONN" "$fbk" -user "$U" -pas "$P" || exit 1
rm -f "$clean"
"$GBAK" -c "$fbk" "$HOST:$clean" -user "$U" -pas "$P" || exit 1

run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$clean"; }

# single-segment PK indices of user tables:
# rel_id, index_id-1 (irt slot), field_id, column, table
pks=$(run_isql <<'EOF' | awk 'NF>=5 && $1 ~ /^[0-9]+$/'
SET HEADING OFF;
SELECT r.RDB$RELATION_ID, i.RDB$INDEX_ID - 1, rf.RDB$FIELD_ID,
       TRIM(seg.RDB$FIELD_NAME), TRIM(r.RDB$RELATION_NAME)
FROM RDB$RELATION_CONSTRAINTS c
JOIN RDB$INDICES i ON i.RDB$INDEX_NAME = c.RDB$INDEX_NAME
JOIN RDB$INDEX_SEGMENTS seg ON seg.RDB$INDEX_NAME = i.RDB$INDEX_NAME
JOIN RDB$RELATIONS r ON r.RDB$RELATION_NAME = i.RDB$RELATION_NAME
JOIN RDB$RELATION_FIELDS rf ON rf.RDB$RELATION_NAME = r.RDB$RELATION_NAME
 AND rf.RDB$FIELD_NAME = seg.RDB$FIELD_NAME
WHERE c.RDB$CONSTRAINT_TYPE = 'PRIMARY KEY'
  AND i.RDB$SEGMENT_COUNT = 1
  AND COALESCE(r.RDB$SYSTEM_FLAG,0) = 0;
EOF
)

fail=0
echo "$pks" | while read -r relid idx fid col table; do
    [ -z "$relid" ] && continue

    engine=$(run_isql <<EOF | sed 's/[[:space:]]*$//' | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(CAST("$col" AS VARCHAR(128))) FROM "$table" ORDER BY "$col";
EOF
)
    # file side: leaf-walk order joined to decoded rows via recno
    file_side=$("$FCSTAT" index-walk "$clean" "$relid" "$idx" 2>/dev/null \
        | awk -F'\t' 'NR==FNR{split($0,a,"\t"); m[a[1]]=a[2+'"$fid"']; next} {print m[$1]}' \
            <("$FCSTAT" rows-recno "$clean" "$relid") - \
        | sed 's/[[:space:]]*$//')

    if [ "$engine" = "$file_side" ]; then
        n=$(printf '%s\n' "$engine" | grep -c .)
        echo "OK   $table.$col via PK index (rel $relid idx $idx): $n rows in identical order"
    else
        echo "DIFF $table.$col (rel $relid idx $idx):"
        diff <(printf '%s\n' "$engine") <(printf '%s\n' "$file_side") | head -8 | sed 's/^/     /'
        fail=1
    fi
done

rm -f "$fbk"
exit $fail
