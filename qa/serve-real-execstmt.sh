#!/bin/bash
# Dynamic EXECUTE STATEMENT - the SQL operand built at runtime rather than
# a bare literal: a `||` concatenation of literals and variables, or a
# bare variable; and POSITIONAL parameters `(sql) (v1, v2, ...)` with `?`
# placeholders, bound at run time (a `?` inside the statement's own string
# literal is left alone). fc parsed only a literal operand before; now the
# operand is any expression, compiled to the engine's BLR (blr_exec_sql /
# blr_exec_into / blr_exec_stmt over the expression - byte for byte) and
# rendered by the interpreter. Both servers build and run the procedures;
# the rows are compared and the ENGINE runs the BLR fc stored.
#
# Boundaries (recorded): a NAMED head `(a := v)` and the USING / ON
# EXTERNAL / AS USER modifiers remain a later slice.
#
#   qa/serve-real-execstmt.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4891}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-execstmt-crab.fdb"; B="$D/fc-execstmt-engine.fdb"
LOG="/tmp/fc-serve-execstmt-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

cat > "$D/es-setup.sql" <<'SQL'
CREATE TABLE T (ID INTEGER, S VARCHAR(10));
INSERT INTO T VALUES (1, 'a'); INSERT INTO T VALUES (2, 'b'); INSERT INTO T VALUES (3, 'c');
COMMIT;
SET TERM ^;
CREATE PROCEDURE P_LIT RETURNS (N INTEGER) AS BEGIN EXECUTE STATEMENT 'SELECT COUNT(*) FROM T' INTO :N; SUSPEND; END^
CREATE PROCEDURE P_CONCAT (X INTEGER) RETURNS (N INTEGER) AS BEGIN EXECUTE STATEMENT ('SELECT COUNT(*) FROM T WHERE ID <= ' || :X) INTO :N; SUSPEND; END^
CREATE PROCEDURE P_VAR RETURNS (N INTEGER) AS DECLARE V VARCHAR(60); BEGIN V = 'SELECT COUNT(*) FROM T'; EXECUTE STATEMENT V INTO :N; SUSPEND; END^
CREATE PROCEDURE P_DML (X INTEGER) AS BEGIN EXECUTE STATEMENT ('INSERT INTO T (ID, S) VALUES (' || :X || ', ''z'')'); END^
CREATE PROCEDURE P_FOR (P VARCHAR(3)) RETURNS (V VARCHAR(10)) AS BEGIN FOR EXECUTE STATEMENT ('SELECT S FROM T WHERE S >= ''' || :P || ''' ORDER BY ID') INTO :V DO SUSPEND; END^
CREATE PROCEDURE P_POS (X INTEGER, Y VARCHAR(5)) RETURNS (N INTEGER) AS BEGIN EXECUTE STATEMENT ('SELECT COUNT(*) FROM T WHERE ID <= ? AND S <= ?') (:X, :Y) INTO :N; SUSPEND; END^
CREATE PROCEDURE P_POSDML (X INTEGER, Y VARCHAR(5)) AS BEGIN EXECUTE STATEMENT ('INSERT INTO T (ID, S) VALUES (?, ?)') (:X, :Y); END^
CREATE PROCEDURE P_STRQ (Y VARCHAR(5)) RETURNS (N INTEGER) AS BEGIN EXECUTE STATEMENT ('SELECT COUNT(*) FROM T WHERE S = ? OR S = ''x?y''') (:Y) INTO :N; SUSPEND; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/es-setup.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/es-setup.sql" 2>&1 | norm)
check "the dynamic EXECUTE STATEMENT procedures build on both" "$c" "$e"

cat > "$D/es-run.sql" <<'SQL'
SET LIST ON;
SELECT N FROM P_LIT;
SELECT N FROM P_CONCAT(2);
SELECT N FROM P_VAR;
SELECT V FROM P_FOR('b');
SELECT N FROM P_POS(3, 'b');
SELECT N FROM P_STRQ('a');
EXECUTE PROCEDURE P_DML(8);
EXECUTE PROCEDURE P_POSDML(9, 'z');
SELECT COUNT(*) AS C FROM T;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/es-run.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/es-run.sql" 2>&1 | norm)
check "concat / variable / FOR / positional ? params all run and answer alike" "$c" "$e"

# the ENGINE runs the dynamic-statement BLR fc stored
e=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/es-run.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/es-run.sql" 2>&1 | norm)
check "the ENGINE runs the dynamic-statement BLR fc stored" "$c" "$e"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
