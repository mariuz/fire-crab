#!/bin/bash
# RDB$SET_CONTEXT / RDB$GET_CONTEXT - the attachment's context variables.
# Probed laws: SET_CONTEXT answers INTEGER 0 when the variable is new and
# 1 when it existed (a NULL value deletes it, still answering 0 / 1);
# GET_CONTEXT answers VARCHAR(255), NULL for an unknown name; the
# USER_TRANSACTION namespace empties at COMMIT, USER_SESSION lives with
# the attachment; SYSTEM is read-only (SET refuses) and answers the
# session's facts; any other namespace is "Invalid namespace name"; a
# non-text value is stored as its text; the select list evaluates
# RIGHT-TO-LEFT, so `SET(K, v), GET(K)` reads the OLD value. Until this
# slice fc folded every non-SYSTEM GET_CONTEXT to NULL at prepare. Both
# databases engine-built; isql with SQLDA display on both servers, the
# output compared line by line.
#
#   qa/serve-real-context.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4883}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-context-crab.fdb"
B="$D/fc-context-engine.fdb"
LOG="/tmp/fc-serve-context-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(5));
COMMIT;
INSERT INTO T VALUES (1, 'a'); INSERT INTO T VALUES (2, 'b');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
# ONE session per server: the variables live with the attachment
script() { cat <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT RDB$SET_CONTEXT('USER_SESSION', 'K', 'v') FROM RDB$DATABASE;
SELECT RDB$GET_CONTEXT('USER_SESSION', 'K') FROM RDB$DATABASE;
SET SQLDA_DISPLAY OFF;
SELECT RDB$SET_CONTEXT('USER_SESSION', 'K', 'w'), RDB$GET_CONTEXT('USER_SESSION', 'K'), RDB$GET_CONTEXT('USER_SESSION', 'NOPE') FROM RDB$DATABASE;
SELECT RDB$GET_CONTEXT('USER_SESSION', 'K') FROM RDB$DATABASE;
SELECT RDB$SET_CONTEXT('USER_SESSION', 'K', NULL), RDB$GET_CONTEXT('USER_SESSION', 'K'), RDB$SET_CONTEXT('USER_SESSION', 'K', NULL) FROM RDB$DATABASE;
SELECT RDB$SET_CONTEXT('USER_TRANSACTION', 'T', 'tv'), RDB$GET_CONTEXT('USER_TRANSACTION', 'T') FROM RDB$DATABASE;
SELECT RDB$GET_CONTEXT('USER_TRANSACTION', 'T') FROM RDB$DATABASE;
COMMIT;
SELECT RDB$GET_CONTEXT('USER_TRANSACTION', 'T'), RDB$GET_CONTEXT('USER_SESSION', 'K') FROM RDB$DATABASE;
SELECT RDB$SET_CONTEXT('SYSTEM', 'X', '1') FROM RDB$DATABASE;
SELECT RDB$GET_CONTEXT('BAD', 'X') FROM RDB$DATABASE;
SELECT RDB$SET_CONTEXT('USER_SESSION', 'N', 42), RDB$GET_CONTEXT('USER_SESSION', 'N') || '!' FROM RDB$DATABASE;
SELECT RDB$GET_CONTEXT('USER_SESSION', 'N') || '!' FROM RDB$DATABASE;
SELECT ID FROM T WHERE V = RDB$GET_CONTEXT('USER_SESSION', 'NOPE');
SELECT RDB$SET_CONTEXT('USER_SESSION', 'WANT', 'b') FROM RDB$DATABASE;
SELECT ID FROM T WHERE V = RDB$GET_CONTEXT('USER_SESSION', 'WANT');
SELECT ID, RDB$SET_CONTEXT('USER_SESSION', 'LAST', ID) FROM T ORDER BY ID;
SELECT RDB$GET_CONTEXT('USER_SESSION', 'LAST') FROM RDB$DATABASE;
SELECT RDB$GET_CONTEXT('SYSTEM', 'CURRENT_USER'), RDB$GET_CONTEXT('SYSTEM', 'SEARCH_PATH'), RDB$GET_CONTEXT('SYSTEM', 'CURRENT_SCHEMA') FROM RDB$DATABASE;
SQL
}
norm() { grep -v '^$' | grep -v '^  :' | sed 's/ *$//'; }
e=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
n=$(echo "$e" | wc -l); i=1
while [ $i -le $n ]; do
    el=$(echo "$e" | sed -n "${i}p"); cl=$(echo "$c" | sed -n "${i}p")
    check "line $i: $el" "$cl" "$el"
    i=$((i + 1))
done
check "the same number of lines" "$(echo "$c" | wc -l)" "$n"
echo "ran $ran checks"
exit $fail
