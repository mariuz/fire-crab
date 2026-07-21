#!/bin/sh
# End-to-end query differential: fire-crab logs in over the encrypted
# wire, prepares/executes/fetches a single-BIGINT query, and the value
# it decodes from the wire message must equal what the same query
# returns through isql.
#
#   qa/diff-query.sh <host:port> <db-path>
#
# This is the last gate before firebird-qa: the statement pipeline
# (op_transaction -> op_allocate_statement -> op_prepare_statement ->
# op_execute -> op_fetch -> op_free_statement -> op_commit) working
# end-to-end, with the protocol-13 row message (null bitmap + value)
# decoded correctly. The queries below cover a computed constant, three
# catalog counts and a filtered count.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
ADDR="${1:-localhost:3050}"
DB="${2:?usage: diff-query.sh <host:port> <db-path>}"
HOST="${ADDR%%:*}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

queries='SELECT CAST(42 AS BIGINT) FROM RDB$DATABASE
SELECT COUNT(*) FROM RDB$RELATIONS
SELECT COUNT(*) FROM RDB$FIELDS
SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG = 0
SELECT MAX(RDB$RELATION_ID) FROM RDB$RELATIONS'

fail=0
printf '%s\n' "$queries" | while IFS= read -r q; do
    [ -z "$q" ] && continue
    fc=$("$FCWIRE" query "$ADDR" "$DB" "$U" "$P" "$q" 2>/dev/null | awk '/VALUE/{print $2}')
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$DB" 2>/dev/null <<EOF | tr -d ' \n'
SET HEADING OFF;
$q;
EOF
)
    if [ "$fc" = "$is" ] && [ -n "$fc" ]; then
        echo "OK   $q  = $fc"
    else
        echo "DIFF $q : fire-crab=$fc isql=$is"
        fail=1
    fi
done
exit $fail
