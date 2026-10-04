#!/bin/bash
# WHAT THE ENGINE'S COMPILER REFUSES IN A ROUTINE BODY - and this server
# stored. A procedure or function body is compiled by the DSQL compiler,
# which emits every name without asking; the engine's compiler resolves
# them at CREATE. Measured on 2196:
#
#   a parameter or variable written BARE inside a DML statement is a
#   COLUMN to the engine - `VALUES (V, 1)`, `SET Y = V`, `WHERE X = V`
#   over a declared V are -206 Column unknown (the colon form is the
#   variable);  a table nobody made is -204;  a column its table lacks
#   -206;  an exception or a sequence nobody defined, a procedure or a
#   function nobody created - each the engine's refusal.
#
# This server stored every one (the BLR then named things that do not
# exist, or read a variable where the engine reads a column). The vectors
# differ - the engine names the word, this server refuses generically -
# so the refusal and the catalog after it are what is compared. The
# controls are the shapes the check must not refuse.
#
# Section 3: a target variable needs no colon - `INTO N`, `FETCH C INTO
# N`, `RETURNING_VALUES N` - the DSQL compiler demanded one.
#
#   qa/serve-real-procnames.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4606}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/procnames-eng.fdb"; FC="$D/procnames-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE LOG (X INTEGER, Y INTEGER);
CREATE VIEW VL AS SELECT X, Y FROM LOG;
CREATE SEQUENCE SQ;
CREATE EXCEPTION EX 'boom';
INSERT INTO LOG VALUES (1, 10);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/procnames-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/procnames-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-procnames-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
CAT="SELECT RDB\$PROCEDURE_NAME FROM RDB\$PROCEDURES WHERE RDB\$SYSTEM_FLAG = 0 AND RDB\$PACKAGE_NAME IS NULL ORDER BY 1; SELECT RDB\$FUNCTION_NAME FROM RDB\$FUNCTIONS WHERE RDB\$SYSTEM_FLAG = 0 AND RDB\$PACKAGE_NAME IS NULL ORDER BY 1;"
run() { printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\nCOMMIT;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | norm; }
cat_of() { printf '%s\n' "$CAT" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | norm; }
nope() { # <label> <ddl> - both refuse, and the catalogs stay alike
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"); c=$(run "127.0.0.1/$PORT:$FC" "$2")
    if [ "${e#Statement failed}" = "$e" ]; then echo "FAIL $1 - the ENGINE accepts it [$e]"; fail=1
    elif [ "${c#Statement failed}" = "$c" ]; then echo "DIFF $1 - stored here"; fail=1
    elif [ "$(cat_of "127.0.0.1/$REAL:$ENG")" != "$(cat_of "127.0.0.1/$PORT:$FC")" ]; then echo "DIFF $1 - the catalogs differ"; fail=1
    else echo "OK   $1"; fi
}
both() { # <label> <ddl> <call> - both store it, and the call answers alike
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$ENG" "$2"; printf '%s\n' "$3" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(run "127.0.0.1/$PORT:$FC" "$2"; printf '%s\n' "$3" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

echo "--- 1 refused at CREATE"
nope "1 a bare variable in VALUES"            "CREATE PROCEDURE R1 AS DECLARE V INTEGER; BEGIN V = 1; INSERT INTO LOG (X, Y) VALUES (V, 1); END^"
nope "1 a bare parameter in WHERE"            "CREATE PROCEDURE R2 (A INTEGER) AS BEGIN DELETE FROM LOG WHERE X = A; END^"
nope "1 a bare output in SET"                 "CREATE PROCEDURE R3 RETURNS (O INTEGER) AS BEGIN O = 1; UPDATE LOG SET Y = O; END^"
nope "1 an unknown table"                     "CREATE PROCEDURE R4 AS BEGIN DELETE FROM NOSUCH WHERE X = 1; END^"
nope "1 an unknown column"                    "CREATE PROCEDURE R5 AS BEGIN UPDATE LOG SET NOPE = 1; END^"
nope "1 an unknown exception"                 "CREATE PROCEDURE R6 AS BEGIN EXCEPTION NOSUCH; END^"
nope "1 an unknown sequence"                  "CREATE PROCEDURE R7 RETURNS (N BIGINT) AS BEGIN N = NEXT VALUE FOR NOSQ; END^"
nope "1 an unknown procedure"                 "CREATE PROCEDURE R8 AS BEGIN EXECUTE PROCEDURE NOPROC; END^"
nope "1 a function: a bare argument in a query" "CREATE FUNCTION F1 (A INTEGER) RETURNS INTEGER AS DECLARE R INTEGER; BEGIN SELECT COUNT(*) FROM LOG WHERE X = A INTO :R; RETURN R; END^"
nope "1 a function over an unknown table"     "CREATE FUNCTION F2 RETURNS INTEGER AS DECLARE R INTEGER; BEGIN SELECT COUNT(*) FROM NOSUCH INTO :R; RETURN R; END^"
echo "--- 2 CONTROLS - stored, and they run alike"
both "2 colon variables in DML and in an INTO" "CREATE PROCEDURE C1 (A INTEGER) RETURNS (N INTEGER) AS DECLARE V INTEGER; BEGIN V = A + 1; INSERT INTO LOG (X, Y) VALUES (:V, :A); SELECT COUNT(*) FROM LOG WHERE X = :V INTO :N; END^" "EXECUTE PROCEDURE C1(5);"
both "2 a view, a system table, an exception"  "CREATE PROCEDURE C2 RETURNS (N INTEGER) AS BEGIN SELECT COUNT(*) FROM VL INTO :N; SELECT COUNT(*) FROM RDB\$DATABASE INTO :N; IF (N < 0) THEN EXCEPTION EX; END^" "EXECUTE PROCEDURE C2;"
both "2 a sequence drawn: stored alike (the catalog)" "CREATE PROCEDURE C7 RETURNS (G BIGINT) AS BEGIN G = NEXT VALUE FOR SQ; END^" "$CAT"
both "2 a recursive procedure"                 "CREATE PROCEDURE C3 (A INTEGER) RETURNS (R INTEGER) AS BEGIN IF (A <= 0) THEN R = 0; ELSE BEGIN EXECUTE PROCEDURE C3(:A - 1) RETURNING_VALUES :R; R = R + A; END END^" "EXECUTE PROCEDURE C3(4);"
both "2 a procedure calling another"           "CREATE PROCEDURE C4 RETURNS (R INTEGER) AS BEGIN R = 7; END^
CREATE PROCEDURE C5 RETURNS (R INTEGER) AS BEGIN EXECUTE PROCEDURE C4 RETURNING_VALUES :R; END^" "EXECUTE PROCEDURE C5;"
both "2 a recursive function"                  "CREATE FUNCTION FC1 (A INTEGER) RETURNS INTEGER AS BEGIN IF (A <= 1) THEN RETURN 1; RETURN A * FC1(A - 1); END^" "SELECT FC1(5) FROM RDB\$DATABASE;"
both "2 a variable named like a column, used with its colon" "CREATE PROCEDURE C6 RETURNS (X INTEGER) AS BEGIN X = 1; SELECT COUNT(*) FROM LOG WHERE LOG.X = :X INTO :X; SUSPEND; END^" "SELECT * FROM C6;"

echo "--- 3 a target variable needs no colon (refused here until 2026-10-04)"
both "3 SELECT .. INTO N"                      "CREATE PROCEDURE I1 RETURNS (N INTEGER) AS BEGIN SELECT COUNT(*) FROM LOG INTO N; END^" "EXECUTE PROCEDURE I1;"
both "3 FOR SELECT .. INTO N DO"               "CREATE PROCEDURE I2 RETURNS (N INTEGER) AS BEGIN FOR SELECT X FROM LOG INTO N DO SUSPEND; END^" "SELECT * FROM I2;"
both "3 RETURNING_VALUES N"                    "CREATE PROCEDURE I0 RETURNS (R INTEGER) AS BEGIN R = 7; END^
CREATE PROCEDURE I3 RETURNS (N INTEGER) AS BEGIN EXECUTE PROCEDURE I0 RETURNING_VALUES N; END^" "EXECUTE PROCEDURE I3;"
both "3 FETCH C INTO N"                        "CREATE PROCEDURE I4 RETURNS (N INTEGER) AS DECLARE C CURSOR FOR (SELECT X FROM LOG); BEGIN OPEN C; FETCH C INTO N; CLOSE C; END^" "EXECUTE PROCEDURE I4;"
both "3 a bare column named like the output (the employee sample's GET_EMP_PROJ)" "CREATE PROCEDURE I5 RETURNS (X INTEGER) AS BEGIN FOR SELECT X FROM LOG WHERE Y > 0 INTO :X DO SUSPEND; END^" "SELECT * FROM I5;"

echo "--- 4 a sequence drawn in a body (it refused at EXECUTE: \"uses PSQL this server does not interpret\")"
both "4 G = NEXT VALUE FOR, G = GEN_ID(SQ, 1), SELECT NEXT VALUE .. INTO" "CREATE PROCEDURE G1 RETURNS (G BIGINT) AS BEGIN G = NEXT VALUE FOR SQ; END^
CREATE PROCEDURE G2 RETURNS (G BIGINT) AS BEGIN G = GEN_ID(SQ, 1); END^
CREATE PROCEDURE G3 RETURNS (G BIGINT) AS BEGIN SELECT NEXT VALUE FOR SQ FROM RDB\$DATABASE INTO :G; END^" "EXECUTE PROCEDURE G1; EXECUTE PROCEDURE G2; EXECUTE PROCEDURE G3;"
both "4 a draw survives ROLLBACK"              "CREATE PROCEDURE G4 RETURNS (G BIGINT) AS BEGIN G = NEXT VALUE FOR SQ; END^" "EXECUTE PROCEDURE G4; ROLLBACK; SELECT GEN_ID(SQ, 0) AS AFTER_RB FROM RDB\$DATABASE;"
both "4 a draw per suspended row; FIRST 1 draws once" "CREATE PROCEDURE G5 RETURNS (X INTEGER, G BIGINT) AS BEGIN FOR SELECT X FROM LOG ORDER BY X INTO :X DO BEGIN G = GEN_ID(SQ, 10); SUSPEND; END END^" "SELECT * FROM G5; SELECT FIRST 1 * FROM G5; SELECT GEN_ID(SQ, 0) AS AFTER_SEL FROM RDB\$DATABASE;"
both "4 EXECUTE BLOCK draws"                   "COMMIT^" "SET TERM ^ ; EXECUTE BLOCK RETURNS (G BIGINT) AS BEGIN G = NEXT VALUE FOR SQ; SUSPEND; G = NEXT VALUE FOR SQ; SUSPEND; END^ SET TERM ; ^"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-procnames-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 27 ]; then echo "FAIL only $ran checks ran (floor 27) - cells went missing"; fail=1; fi
exit $fail
