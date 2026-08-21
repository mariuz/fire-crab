#!/bin/bash
# CREATE FUNCTION / DROP FUNCTION and CALLING a PSQL function from DSQL.
# Probed: CREATE FUNCTION writes RDB$FUNCTIONS (id, RETURN_ARGUMENT 0,
# LEGACY_FLAG 0, DETERMINISTIC_FLAG, owner, source, VALID_BLR 1) and one
# RDB$FUNCTION_ARGUMENTS row per argument plus the RETURN at position 0,
# each over an auto domain (RDB$MECHANISM NULL for a PSQL function); the
# function's BLR is the procedure BLR shape (a RETURN assigns output 0
# and leaves). A call `F(<expr>, ...)` in a select list describes as the
# RETURN domain (nullable), names the column after the function, and
# evaluates per row - nested calls, arithmetic around a call, NULL
# arguments, a DETERMINISTIC body with IF/RETURN, a WHILE loop, a text
# body, a no-argument call. An unknown `NAME(` is -804 "Function
# unknown"; the wrong argument count is fun_param_mismatch with the
# first missing argument's name or wronumarg. DROP FUNCTION removes the
# rows; a duplicate CREATE and a missing DROP are the engine's pairs.
# Both databases engine-built; isql on both servers; the ENGINE runs
# fc's functions on fc's file at the end.
# Boundaries (recorded): a function body is interpreted on fc's PSQL
# surface - CAST inside a body, and a call in WHERE / a join, refuse on
# fc where the engine answers; `?` without an input SQLDA is fc's
# generic refusal at execute where the engine says 07002.
#
#   qa/serve-real-createfunction.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4888}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-createfunction-crab.fdb"
B="$D/fc-createfunction-engine.fdb"
LOG="/tmp/fc-serve-createfunction-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"
fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(5), B BIGINT);
COMMIT;
INSERT INTO T VALUES (1, 'a', 10);
INSERT INTO T VALUES (2, 'b', 20);
INSERT INTO T VALUES (3, NULL, NULL);
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | grep -v 'BLOB display' | sed 's/_SOURCE [0-9a-f]*:[0-9a-f]*$/_SOURCE <id>/' | tr '\n' '|'; }
ddl() { cat <<'SQL'
SET TERM ^;
CREATE FUNCTION F (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1; END^
CREATE FUNCTION G (S VARCHAR(5), N INTEGER) RETURNS VARCHAR(10) AS DECLARE X VARCHAR(10); BEGIN X = S || N; RETURN X; END^
CREATE FUNCTION H (A INTEGER) RETURNS INTEGER DETERMINISTIC AS BEGIN IF (A > 1) THEN RETURN A * 10; RETURN 0; END^
CREATE FUNCTION K (N INTEGER) RETURNS BIGINT AS DECLARE I INTEGER; DECLARE S BIGINT; BEGIN S = 0; I = 1; WHILE (I <= N) DO BEGIN S = S + I; I = I + 1; END RETURN S; END^
CREATE FUNCTION Z () RETURNS INTEGER AS BEGIN RETURN 42; END^
SET TERM ;^
COMMIT;
SQL
}
calls() { cat <<'SQL'
SELECT ID, F(ID), G(V, ID), H(ID), K(ID), Z() FROM T ORDER BY ID;
SELECT F(10), H(0), F(NULL), Z(), K(100) FROM RDB$DATABASE;
SELECT F(ID) + 1 AS X, F(F(ID)) AS Y, UPPER(G(V, ID)) AS Z, F(B) AS W FROM T WHERE ID > 1 ORDER BY ID DESC;
SELECT F(ID) * 2, H(F(ID)) FROM T WHERE V IS NOT NULL;
SET SQLDA_DISPLAY ON;
SELECT ID, F(ID), G(V, ID), K(ID), Z() FROM T WHERE ID = 1;
SET SQLDA_DISPLAY OFF;
SELECT NOPE(1) FROM RDB$DATABASE;
SELECT F(1, 2) FROM RDB$DATABASE;
SELECT F() FROM RDB$DATABASE;
SELECT G(V) FROM T;
SELECT nope(ID) FROM T;
SQL
}
# DDL first on each server, then the function CALLS compared. The catalog
# is checked afterwards in fresh attachments (see below).
ddl | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
ddl | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
e=$(calls | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(calls | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "CREATE FUNCTION and calling PSQL functions: the rows, the describe, the vectors" "$c" "$e"
# The catalog is verified query-by-query in fresh attachments: a long
# blob-returning session under wire encryption accumulates op_inline_blob
# packets and eventually desyncs the client's cache (a pre-existing limit
# unrelated to functions - no existing gate drives that many in one
# session), so each differential runs on its own connection.
q_funcs="SET LIST ON; SELECT RDB\$FUNCTION_NAME, RDB\$FUNCTION_ID, RDB\$RETURN_ARGUMENT, RDB\$SYSTEM_FLAG, RDB\$LEGACY_FLAG, RDB\$DETERMINISTIC_FLAG, RDB\$OWNER_NAME, RDB\$VALID_BLR, RDB\$PRIVATE_FLAG, RDB\$ENGINE_NAME, RDB\$ENTRYPOINT, RDB\$MODULE_NAME, RDB\$FUNCTION_SOURCE FROM RDB\$FUNCTIONS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;"
q_args="SET LIST ON; SELECT a.RDB\$FUNCTION_NAME, a.RDB\$ARGUMENT_NAME, a.RDB\$ARGUMENT_POSITION, a.RDB\$MECHANISM, a.RDB\$FIELD_SOURCE, a.RDB\$ARGUMENT_MECHANISM, a.RDB\$NULL_FLAG, a.RDB\$FIELD_TYPE, a.RDB\$FIELD_LENGTH, f.RDB\$FIELD_TYPE, f.RDB\$FIELD_LENGTH, f.RDB\$FIELD_PRECISION, f.RDB\$CHARACTER_LENGTH, f.RDB\$CHARACTER_SET_ID FROM RDB\$FUNCTION_ARGUMENTS a JOIN RDB\$FIELDS f ON f.RDB\$FIELD_NAME = a.RDB\$FIELD_SOURCE WHERE a.RDB\$FUNCTION_NAME IN ('F', 'G', 'H', 'K', 'Z') ORDER BY 1, 3;"
q_deps="SELECT COUNT(*) FROM RDB\$DEPENDENCIES WHERE RDB\$DEPENDENT_NAME IN ('F', 'G', 'H', 'K', 'Z');"
qcheck() { # <label> <sql>
    local e c
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
qcheck "RDB\$FUNCTIONS rows for the created functions" "$q_funcs"
qcheck "RDB\$FUNCTION_ARGUMENTS over their domains" "$q_args"
qcheck "no leftover dependencies" "$q_deps"
# DROP FUNCTION K on both, then the row is gone and calling K is -804
printf 'DROP FUNCTION K; COMMIT;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
printf 'DROP FUNCTION K; COMMIT;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
qcheck "DROP FUNCTION K removes its rows and calling K is -804" "SET LIST ON; SELECT COUNT(*) AS FN FROM RDB\$FUNCTIONS WHERE RDB\$FUNCTION_NAME = 'K'; SELECT COUNT(*) AS ARG FROM RDB\$FUNCTION_ARGUMENTS WHERE RDB\$FUNCTION_NAME = 'K'; SET LIST OFF; SELECT K(1) FROM RDB\$DATABASE;"
e=$("$D/sqlerr" "127.0.0.1/$REAL:$B" "CREATE FUNCTION F (A INTEGER) RETURNS INTEGER AS BEGIN RETURN 1; END" "DROP FUNCTION NOPE" "DROP FUNCTION K" 2>&1 | norm)
c=$("$D/sqlerr" "127.0.0.1/$PORT:$A" "CREATE FUNCTION F (A INTEGER) RETURNS INTEGER AS BEGIN RETURN 1; END" "DROP FUNCTION NOPE" "DROP FUNCTION K" 2>&1 | norm)
check "the duplicate / missing DDL vectors" "$c" "$e"
# the ENGINE runs fc's functions on fc's file
script2() { cat <<'SQL'
SELECT ID, F(ID), G(V, ID), H(ID), Z() FROM T ORDER BY ID;
SELECT F(F(7)), H(3), G('xy', 77) FROM RDB$DATABASE;
SET LIST ON;
SELECT RDB$FUNCTION_NAME, RDB$FUNCTION_ID, RDB$DETERMINISTIC_FLAG, RDB$VALID_BLR FROM RDB$FUNCTIONS WHERE RDB$SYSTEM_FLAG = 0 ORDER BY 1;
SQL
}
e=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE runs fc's functions on fc's file" "$c" "$e"
echo "ran $ran checks"
exit $fail
