#!/bin/bash
# INVOKING packaged procedures and functions from a query. The header +
# body slices store a packaged routine's BLR; this one CALLS it:
#   - a packaged FUNCTION in a select list: `PKG.FF(x)`, bare and
#     fully qualified (`PUBLIC.PKG.FF`), over a literal, over a table
#     column (one call per row), a text-returning member, and NESTED
#     (`PKG.FF(PKG.FF(x))`);
#   - a packaged SELECTABLE PROCEDURE in the FROM clause: `PKG.PP(x)`,
#     bare and qualified, a single row and a multi-row (SUSPEND loop);
#   - the error vectors the engine raises: a function called with the
#     wrong arity (`"PUBLIC"."PKG"."FF"` / wrong number of arguments), a
#     procedure the same way, and an unknown member (-804 "Function
#     unknown" '"PKG"."NOPE"').
#
# Both databases are built by their own server (fc builds its package
# with CREATE PACKAGE BODY, the engine with its); the invocations then
# run through each and the rows + vectors are compared with norm.
#
# A plain routine and a packaged member may share a short name - the
# engine namespaces them by package, and so does fc: a plain FUNCTION FF
# and a packaged PKG.FF, a plain PROCEDURE PP and a packaged PKG.PP, all
# coexist and each resolves to its own body (checked below). The member's
# id is looked up by name AND package, so CREATE PACKAGE BODY does not
# reuse a same-named plain routine's RDB$..._ID.
#
# An unknown SELECTABLE procedure in the FROM clause (call syntax,
# `NAME(args)`) answers the engine's -204 "Procedure unknown" with the
# name AS WRITTEN and its line/column - bare, PUBLIC.-qualified, and a
# missing package member alike (checked below). A procedure that EXISTS
# but is outside the interpreter's surface still falls to the generic
# refusal (procedure_defined gates on existence).
#
# A BARE unknown name with no call syntax (`FROM NOSUCHTHING`) is a
# RELATION reference - the engine's -204 "Table unknown" (a different
# code / SQLSTATE); fc answers it too, in the main FROM, once the name is
# shown to be no table, view, procedure or CTE (checked below).
#
# An unknown relation ANYWHERE - a subquery, a derived table, an
# IN/EXISTS body, a scalar subselect - also answers -204 "Table unknown"
# (checked below): a fallback over a generically-refused statement finds
# the first unknown FROM/JOIN name.
#
# Boundary (recorded): a QUALIFIED unknown reference or a procedure CALL
# INSIDE a subquery keeps the generic refusal - the fallback takes bare
# relation names only.
#
#   qa/serve-real-callpkg.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4898}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-callpkg-crab.fdb"; B="$D/fc-callpkg-engine.fdb"
LOG="/tmp/fc-serve-callpkg-$PORT.log"
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

cat > "$D/callpkg-setup.sql" <<'SQL'
SET TERM ^;
CREATE PACKAGE PKG AS BEGIN
 PROCEDURE PP (A INTEGER) RETURNS (B INTEGER);
 FUNCTION FF (A INTEGER) RETURNS INTEGER;
 FUNCTION DOUBLED (S VARCHAR(10)) RETURNS VARCHAR(20);
 PROCEDURE MULTI (N INTEGER) RETURNS (K INTEGER);
END^
CREATE PACKAGE BODY PKG AS BEGIN
 PROCEDURE PP (A INTEGER) RETURNS (B INTEGER) AS BEGIN B = A * 2; SUSPEND; END
 FUNCTION FF (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1; END
 FUNCTION DOUBLED (S VARCHAR(10)) RETURNS VARCHAR(20) AS BEGIN RETURN S || S; END
 PROCEDURE MULTI (N INTEGER) RETURNS (K INTEGER) AS BEGIN K = 0; WHILE (K < N) DO BEGIN K = K + 1; SUSPEND; END END
END^
SET TERM ;^
CREATE TABLE T (ID INTEGER, V INTEGER);
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-setup.sql" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-setup.sql" >/dev/null 2>&1

# packaged FUNCTION in a select list
cat > "$D/callpkg-fn.sql" <<'SQL'
SET LIST ON;
SELECT PKG.FF(41) AS R FROM RDB$DATABASE;
SELECT PUBLIC.PKG.FF(100) AS R2 FROM RDB$DATABASE;
SELECT PKG.DOUBLED('ab') AS D FROM RDB$DATABASE;
SELECT ID, PKG.FF(V) AS FV FROM T ORDER BY ID;
SELECT PKG.FF(PKG.FF(5)) AS NESTED FROM RDB$DATABASE;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-fn.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-fn.sql" 2>&1 | norm)
check "a packaged FUNCTION in a select list (bare, qualified, text, per-row, nested)" "$c" "$e"

# packaged SELECTABLE PROCEDURE in the FROM clause
cat > "$D/callpkg-proc.sql" <<'SQL'
SET LIST ON;
SELECT B FROM PKG.PP(21);
SELECT B FROM PUBLIC.PKG.PP(50);
SELECT K FROM PKG.MULTI(3);
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-proc.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-proc.sql" 2>&1 | norm)
check "a packaged SELECTABLE PROCEDURE in the FROM clause (bare, qualified, multi-row)" "$c" "$e"

# the error vectors: wrong arity (proc + fn), unknown member
cat > "$D/callpkg-vec.sql" <<'SQL'
SELECT B FROM PKG.PP(1, 2);
SELECT PKG.FF(1, 2) FROM RDB$DATABASE;
SELECT PKG.FF() FROM RDB$DATABASE;
SELECT PKG.NOPE(1) FROM RDB$DATABASE;
SELECT NOPKG.FF(1) FROM RDB$DATABASE;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-vec.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-vec.sql" 2>&1 | norm)
check "the invocation error vectors (arity: proc + fn, and -804 unknown member)" "$c" "$e"

# EXECUTE PROCEDURE of a packaged procedure still answers its outputs
cat > "$D/callpkg-exe.sql" <<'SQL'
SET LIST ON;
EXECUTE PROCEDURE PKG.PP(21);
EXECUTE PROCEDURE PUBLIC.PKG.PP(9);
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-exe.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-exe.sql" 2>&1 | norm)
check "EXECUTE PROCEDURE of a packaged procedure" "$c" "$e"

# a plain function and a packaged member of the SAME name coexist, each
# resolving to its own body (the engine namespaces by package)
cat > "$D/callpkg-collide.sql" <<'SQL'
SET TERM ^;
CREATE FUNCTION FF (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 1000; END^
CREATE PROCEDURE PP (A INTEGER) RETURNS (B INTEGER) AS BEGIN B = A + 500; SUSPEND; END^
SET TERM ;^
COMMIT;
SET LIST ON;
SELECT FF(7) AS PLAIN_FN, PKG.FF(7) AS PKG_FN, PUBLIC.FF(7) AS QUAL_PLAIN FROM RDB$DATABASE;
SELECT B FROM PP(7);
SELECT B FROM PKG.PP(7);
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-collide.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-collide.sql" 2>&1 | norm)
check "a plain FUNCTION and PROCEDURE coexist with same-named packaged members, each resolving" "$c" "$e"

# an unknown SELECTABLE procedure in the FROM clause: -204 Procedure
# unknown, bare / PUBLIC.-qualified / a missing package member
cat > "$D/callpkg-unknownproc.sql" <<'SQL'
SELECT X FROM NOSUCHPROC(1);
SELECT X FROM NOSUCHPROC(1, 'a');
SELECT X FROM PUBLIC.NOSUCHPROC(5);
SELECT X FROM PKG.NOSUCHMEMBER(1);
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-unknownproc.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-unknownproc.sql" 2>&1 | norm)
check "an unknown selectable procedure in FROM is -204 Procedure unknown (bare, qualified, missing member)" "$c" "$e"
# an unknown RELATION (bare name, no call syntax) in FROM is -204 Table unknown
cat > "$D/callpkg-unknowntab.sql" <<'SQL'
SELECT X FROM NOSUCHTHING;
SELECT * FROM NOSUCHTHING;
SELECT COUNT(*) FROM NOSUCHTHING;
SELECT ID FROM "lowernope";
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-unknowntab.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-unknowntab.sql" 2>&1 | norm)
check "an unknown relation in FROM is -204 Table unknown (bare, star, count, quoted)" "$c" "$e"
# an unknown relation inside a SUBQUERY / derived table / IN-EXISTS body
cat > "$D/callpkg-unknownsub.sql" <<'SQL'
SELECT B FROM PKG.PP(2) WHERE B IN (SELECT ID FROM NOSUCHTAB);
SELECT X FROM (SELECT ID AS X FROM NOSUCHTAB) D;
SELECT (SELECT ID FROM NOSUCHTAB) FROM RDB$DATABASE;
SELECT 1 FROM RDB$DATABASE WHERE EXISTS (SELECT 1 FROM NOSUCHTAB);
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/callpkg-unknownsub.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/callpkg-unknownsub.sql" 2>&1 | norm)
check "an unknown relation in a subquery / derived table / IN / EXISTS is -204 Table unknown" "$c" "$e"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
