#!/bin/sh
# Differential QA: compare fcstat's header decode against the C++
# engine's gstat, field for field, on one or more database files.
#
#   qa/diff-gstat.sh /path/to/db.fdb [more.fdb ...]
#   GSTAT=/opt/firebird/bin/gstat qa/diff-gstat.sh /tmp/fbhandson/*.fdb
#
# The compared fields are exactly the ones both tools print from the
# header page: Page size, ODS version, the four transaction markers,
# Next attachment ID, Page buffers, and the database GUID. Any
# difference is a conversion bug (or a database modified between the
# two runs - run against quiescent files).

set -u
GSTAT="${GSTAT:-gstat}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
FIELDS='Page size|ODS version|Oldest transaction|Oldest active|Oldest snapshot|Next transaction|Next attachment ID|Page buffers|Database GUID'

fail=0
for db in "$@"; do
    a=$("$GSTAT" -h "$db" | grep -E "$FIELDS" | sed 's/^\s*//' | sort)
    b=$("$FCSTAT" header "$db" | grep -E "$FIELDS" | sed 's/^\s*//; s/PAGES relation.*//' | sort)
    if [ "$a" = "$b" ]; then
        echo "OK   $db"
    else
        echo "DIFF $db"
        diff <(echo "$a") <(echo "$b") | sed 's/^/     /'
        fail=1
    fi
done
exit $fail
