#!/bin/sh
# serve-real-procsample.sh - the employee sample's PROCEDURE SHAPES, on
# an engine-built fixture: every body here is compiled by the ENGINE
# (the BLR fire-crab-exe runs) and answered by fire-crab beside the
# engine over its own copy of the file.
#
# The laws pinned, each measured on the engine first (docs/roadmap.md,
# 2026-09-06 "the employee sample's procedures run"):
#   * EXECUTE PROCEDURE p :a, :b - the PAREN-LESS argument spelling
#     inside a body (DEPT_BUDGET's recursion);
#   * SUM / AVG INTO over a DECIMAL(12,2) column keep the scale, AVG
#     divides at the source scale truncating toward zero (SUB_TOT_BUDGET);
#   * a COMPUTED BY column read by a compiled body is its expression
#     over the row, not the empty slot (ORG_CHART's FULL_NAME);
#   * FOR SELECT ... FROM p(:x, :y) runs the callee per row (ALL_LANGS);
#   * EXECUTE PROCEDURE ends the body at its FIRST SUSPEND: a statement
#     written after it never runs, where SELECT * FROM p runs them all.
#
# usage: qa/serve-real-procsample.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4123}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
DB="$D/procsample.fdb"
FCDB="$D/procsample-fc.fdb"
mkdir -p "$D"; rm -f "$DB" "$FCDB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE DEPT (DEPT_NO CHAR(3) NOT NULL PRIMARY KEY, HEAD_DEPT CHAR(3), BUDGET DECIMAL(12, 2), MNGR_NO INTEGER);
CREATE TABLE EMP (EMP_NO INTEGER NOT NULL PRIMARY KEY, DEPT_NO CHAR(3), LAST_NAME VARCHAR(20), FIRST_NAME VARCHAR(15), FULL_NAME COMPUTED BY (LAST_NAME || ', ' || FIRST_NAME), JOB_CODE VARCHAR(5), JOB_GRADE SMALLINT);
CREATE TABLE LANGS (JOB_CODE VARCHAR(5), JOB_GRADE SMALLINT, LANG VARCHAR(15));
COMMIT;
INSERT INTO DEPT VALUES ('000', NULL, 1000000.00, 1);
INSERT INTO DEPT VALUES ('100', '000', 400000.00, 2);
INSERT INTO DEPT VALUES ('120', '100', 250000.01, 3);
INSERT INTO DEPT VALUES ('130', '100', 100000.02, NULL);
INSERT INTO DEPT VALUES ('600', '000', 1100000.00, 2);
INSERT INTO EMP VALUES (1, '000', 'Bender', 'Oliver', 'CEO', 1);
INSERT INTO EMP VALUES (2, '100', 'Nelson', 'Robert', 'VP', 2);
INSERT INTO EMP VALUES (3, '120', 'Young', 'Bruce', 'Eng', 3);
INSERT INTO EMP VALUES (4, '600', 'Lambert', 'Kim', 'Eng', 3);
INSERT INTO LANGS VALUES ('Eng', 3, 'English');
INSERT INTO LANGS VALUES ('Eng', 3, 'Japanese');
INSERT INTO LANGS VALUES ('VP', 2, 'French');
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE DEPT_BUDGET (DNO CHAR(3)) RETURNS (TOT DECIMAL(12, 2)) AS
  DECLARE VARIABLE SUMB DECIMAL(12, 2);
  DECLARE VARIABLE RDNO CHAR(3);
  DECLARE VARIABLE CNT INTEGER;
BEGIN
  TOT = 0;
  SELECT BUDGET FROM DEPT WHERE DEPT_NO = :DNO INTO :TOT;
  SELECT COUNT(BUDGET) FROM DEPT WHERE HEAD_DEPT = :DNO INTO :CNT;
  IF (CNT = 0) THEN SUSPEND;
  FOR SELECT DEPT_NO FROM DEPT WHERE HEAD_DEPT = :DNO INTO :RDNO DO
  BEGIN
    EXECUTE PROCEDURE DEPT_BUDGET :RDNO RETURNING_VALUES :SUMB;
    TOT = TOT + SUMB;
  END
  SUSPEND;
END^
CREATE PROCEDURE SUB_TOT (HEAD CHAR(3)) RETURNS (TOT_B DECIMAL(12, 2), AVG_B DECIMAL(12, 2), MIN_B DECIMAL(12, 2), MAX_B DECIMAL(12, 2)) AS
BEGIN
  SELECT SUM(BUDGET), AVG(BUDGET), MIN(BUDGET), MAX(BUDGET) FROM DEPT WHERE HEAD_DEPT = :HEAD INTO :TOT_B, :AVG_B, :MIN_B, :MAX_B;
  SUSPEND;
END^
CREATE PROCEDURE ORG RETURNS (DNO CHAR(3), MNGR VARCHAR(40), TITLE VARCHAR(5), CNT INTEGER) AS
  DECLARE VARIABLE M INTEGER;
BEGIN
  FOR SELECT DEPT_NO, MNGR_NO FROM DEPT ORDER BY DEPT_NO INTO :DNO, :M DO
  BEGIN
    IF (:M IS NULL) THEN BEGIN MNGR = '--TBH--'; TITLE = ''; END
    ELSE SELECT FULL_NAME, JOB_CODE FROM EMP WHERE EMP_NO = :M INTO :MNGR, :TITLE;
    SELECT COUNT(EMP_NO) FROM EMP WHERE DEPT_NO = :DNO INTO :CNT;
    SUSPEND;
  END
END^
CREATE PROCEDURE SHOWL (CODE VARCHAR(5), GRADE SMALLINT) RETURNS (L VARCHAR(15)) AS
BEGIN
  FOR SELECT LANG FROM LANGS WHERE JOB_CODE = :CODE AND JOB_GRADE = :GRADE ORDER BY LANG INTO :L DO SUSPEND;
END^
CREATE PROCEDURE ALLL RETURNS (CODE VARCHAR(5), GRADE VARCHAR(5), L VARCHAR(15)) AS
BEGIN
  FOR SELECT DISTINCT JOB_CODE, JOB_GRADE FROM EMP ORDER BY 1, 2 INTO :CODE, :GRADE DO
  BEGIN
    FOR SELECT L FROM SHOWL(:CODE, :GRADE) INTO :L DO SUSPEND;
    L = '=====';
    SUSPEND;
  END
END^
CREATE PROCEDURE P7S RETURNS (R INTEGER) AS
BEGIN
  R = 1;
  SUSPEND;
  UPDATE DEPT SET BUDGET = BUDGET + 1 WHERE DEPT_NO = '600';
  R = 2;
  SUSPEND;
END^
CREATE PROCEDURE P7D RETURNS (R INTEGER) AS
  DECLARE VARIABLE C INTEGER;
BEGIN
  R = 0;
  SELECT COUNT(*) FROM DEPT INTO :C;
  IF (C > 0) THEN SUSPEND;
  UPDATE DEPT SET BUDGET = BUDGET + 1 WHERE DEPT_NO = '600';
  R = 9;
  SUSPEND;
END^
SET TERM ; ^
COMMIT;
EOF
cp "$DB" "$FCDB" && chmod 666 "$FCDB" || { echo "FAIL copy"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-procsample.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"; exit 1; }
norm() { sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//' | grep -v '^$' | grep -v '^After line '; }
fail=0
check() { # <label> <script>
    want=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | norm)
    got=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FCDB" 2>&1 | norm)
    if [ "$got" = "$want" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     engine: $(printf '%s' "$want" | tr '\n' '|')"
        echo "     fcwire: $(printf '%s' "$got" | tr '\n' '|')"
        fail=1
    fi
}
check "paren-less EXECUTE PROCEDURE recursion sums the tree" \
      "EXECUTE PROCEDURE DEPT_BUDGET '000'; EXECUTE PROCEDURE DEPT_BUDGET '100'; EXECUTE PROCEDURE DEPT_BUDGET '130'; EXECUTE PROCEDURE DEPT_BUDGET 'ZZZ';"
check "... and as a SELECT the leaf suspends twice" "SELECT * FROM DEPT_BUDGET('130'); SELECT * FROM DEPT_BUDGET('000');"
check "a too-long CHAR(3) argument is refused at the bind" "EXECUTE PROCEDURE DEPT_BUDGET '1000';"
check "SUM/AVG/MIN/MAX INTO keep the scale, AVG truncates" "SELECT * FROM SUB_TOT('100'); SELECT * FROM SUB_TOT('000'); EXECUTE PROCEDURE SUB_TOT '000';"
check "... and NULLs over no rows" "SELECT * FROM SUB_TOT('ZZZ');"
check "the procedure output describes at the declared scale" "SET SQLDA_DISPLAY ON; SELECT * FROM SUB_TOT('000');"
check "a COMPUTED BY column read by a compiled body" "SELECT * FROM ORG; EXECUTE PROCEDURE ORG;"
check "FOR SELECT over a procedure with arguments" "SELECT * FROM ALLL; EXECUTE PROCEDURE ALLL;"
check "EXECUTE PROCEDURE stops at the FIRST SUSPEND" \
      "EXECUTE PROCEDURE P7S; SELECT BUDGET FROM DEPT WHERE DEPT_NO = '600'; ROLLBACK; EXECUTE PROCEDURE P7D; SELECT BUDGET FROM DEPT WHERE DEPT_NO = '600'; ROLLBACK;"
check "... where SELECT runs the body to the end" \
      "SELECT * FROM P7S; SELECT BUDGET FROM DEPT WHERE DEPT_NO = '600'; ROLLBACK; SELECT * FROM P7D; SELECT BUDGET FROM DEPT WHERE DEPT_NO = '600'; ROLLBACK;"
check "AVG on the DSQL path truncates the same way" "SELECT AVG(BUDGET), SUM(BUDGET) FROM DEPT WHERE HEAD_DEPT = '100';"
exit $fail
