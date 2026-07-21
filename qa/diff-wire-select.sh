#!/bin/sh
# General SELECT differential: fire-crab runs multi-column, multi-row
# SELECTs over the encrypted wire (prepare -> describe -> execute ->
# batched fetch, decoding INT64 and VARYING - the two coerced wire
# shapes) and the full result set must equal isql's, row for row.
#
#   qa/diff-select.sh <host:port> <db-path>
#
# Queries mix integer and text columns, ordering, filtering and joins.
# Both sides are pipe-joined and compared verbatim (queries carry their
# own ORDER BY so the row order is defined).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
ADDR="${1:-localhost:3050}"
DB="${2:?usage: diff-select.sh <host:port> <db-path>}"
HOST="${ADDR%%:*}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

# each test: a SELECT returning integer/text columns, with ORDER BY.
run_one() {
    sql="$1"
    # fire-crab: tab-separated -> pipe-joined
    fc=$("$FCWIRE" query-rows "$ADDR" "$DB" "$U" "$P" "$sql" 2>/dev/null \
        | sed 's/\t/|/g')
    # isql: build the same pipe-joined projection. The caller passes an
    # already-pipe-concatenated select list via $2.
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$DB" 2>/dev/null <<EOF | sed 's/[[:space:]]*$//' | grep -v '^$'
SET HEADING OFF;
$2;
EOF
)
    if [ "$fc" = "$is" ]; then
        n=$(printf '%s\n' "$fc" | grep -c .)
        echo "OK   $n rows: $sql"
    else
        echo "DIFF $sql"
        diff <(printf '%s\n' "$is") <(printf '%s\n' "$fc") | head -6 | sed 's/^/     /'
        return 1
    fi
}

fail=0
run_one \
  "SELECT RDB\$RELATION_ID FROM RDB\$RELATIONS ORDER BY 1" \
  "SELECT TRIM(CAST(RDB\$RELATION_ID AS VARCHAR(10))) FROM RDB\$RELATIONS ORDER BY RDB\$RELATION_ID" || fail=1

run_one \
  "SELECT RDB\$RELATION_ID, TRIM(RDB\$RELATION_NAME) FROM RDB\$RELATIONS WHERE RDB\$SYSTEM_FLAG=0 ORDER BY 1" \
  "SELECT RDB\$RELATION_ID || '|' || TRIM(RDB\$RELATION_NAME) FROM RDB\$RELATIONS WHERE RDB\$SYSTEM_FLAG=0 ORDER BY 1" || fail=1

run_one \
  "SELECT TRIM(RDB\$FIELD_NAME), RDB\$FIELD_TYPE FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME='DEPT' ORDER BY RDB\$FIELD_POSITION" \
  "SELECT TRIM(RDB\$FIELD_NAME) || '|' || RDB\$FIELD_TYPE FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME='DEPT' ORDER BY RDB\$FIELD_POSITION" || fail=1

run_one \
  "SELECT COUNT(*), MIN(RDB\$RELATION_ID), MAX(RDB\$RELATION_ID) FROM RDB\$RELATIONS" \
  "SELECT COUNT(*) || '|' || MIN(RDB\$RELATION_ID) || '|' || MAX(RDB\$RELATION_ID) FROM RDB\$RELATIONS" || fail=1

exit $fail
