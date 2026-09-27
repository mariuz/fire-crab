#!/bin/bash
# PSQL GRAMMAR THE ENGINE RUNS AND THIS SERVER REFUSED - the psqlgram
# cluster, every cell measured on engine 2182 (LI-T6.0.0.2182) first.
#
#   1. SQLCODE, GDSCODE and SQLSTATE read what the running WHEN handler
#      caught - the first code's SQLCODE and code, the whole vector's
#      state (1/0 is -802 / 335544321 / 22012, a user exception -836 /
#      335544517 / HY000) - and 0 / 0 / '00000' everywhere else, an outer
#      handler included once a nested one has completed. Read-only.
#   2. EXCEPTION <name> <expression> takes the value's text as the
#      message (NULL or '' keeps the catalog's); EXCEPTION <name> USING
#      (...) fills @1..@9 - one digit, a missing value leaves @n, a NULL
#      is '*** null ***', each value as a CAST to text renders it.
#   3. A value the arithmetic evaluator has no rule for - a BOOLEAN, a
#      DATE plus a number, a DOUBLE division, ABS / MOD - is the
#      planner's; an EXECUTE BLOCK whose body the BLR compiler does not
#      take is run by the source interpreter, its RETURNS read by the
#      compiler over a stand-in body (or the column-type reader for
#      BOOLEAN / DOUBLE / FLOAT), and every query in it is held to the
#      prepare-time rules a client's is (section 10).
#   4. A function call is a statement (RDB$SET_CONTEXT(...);).
#   5. A procedure argument may be DEFAULT (the parameter's literal
#      default, NULL where it has none) or integer arithmetic (P_REC(:N
#      - 1) recursing); EXECUTE PROCEDURE's arity is the engine's 07001
#      at prepare; a DATE / TIME / TIMESTAMP / DOUBLE / FLOAT / BOOLEAN
#      parameter runs from the source (a function was "Function unknown").
#   6. BREAK; a SCROLL cursor's FETCH orientations; <cursor>.<column>
#      (HY109 unpositioned, 24000 closed); FOR SELECT ... AS CURSOR, in
#      scope in its loop only; OPEN of an open cursor restarts it.
#   7. A local typed by a DOMAIN (its NOT NULL, CHECK and DEFAULT), TYPE
#      OF, TYPE OF COLUMN, or its own NOT NULL: every write is validated
#      - isc_not_valid_for_var, the value shown as written.
#   8. INSERT / UPDATE / DELETE ... RETURNING ... INTO: one row assigns,
#      none leaves the slots, two are 21000.
#   9. CREATE TRIGGER with a literal holding ':' before NEW.<col>, and a
#      DECLARE without VARIABLE: stored with the engine's BLR and debug
#      bytes (read back by the engine).
#  11. The engine judges a block's body WHOLE at prepare, and the source
#      interpreter reads only what it reaches: every statement, in a
#      branch that never runs too, is held to the compile's checks - an
#      unknown table (the engine's -204, exact), column or variable, a
#      value's syntax, a duplicate output / local / nested loop label,
#      DECLARE SQLCODE, RETURN in a block, CONTINUE outside a loop, FETCH
#      from no cursor, a DML the planner refuses, a RETURNING list, and
#      the -313 of a singleton's count. A named cursor is a derived
#      table: an unnamed column is the engine's -104 at prepare.
#  12. A FLOAT local reaches the planner as the single it is; a DOUBLE
#      division by zero is the floating-point one; an AUTONOMOUS block's
#      USER_TRANSACTION context is its own; FETCH RELATIVE 0 re-reads
#      the row with ROW_COUNT 0; a trigger's SCROLL cursor scrolls.
#  13. A BLOB moved into a slot of another type is its TEXT (SELECT /
#      FOR SELECT / FETCH INTO, <cursor>.<column>, RETURNING INTO,
#      EXECUTE STATEMENT INTO, a LIST) - the slot held '<blob 0:...>'.
#  14. A DOUBLE past its range is 22003 *Floating-point overflow*, never
#      an Infinity or a NaN.
#  15. A PSQL value's own grammar at prepare: an aggregate or a window
#      function is -104 *Invalid command*; `||` binds tighter than every
#      arithmetic operator, and a text operand of + / - (or SUBSTRING's
#      start) is *expression evaluation not supported*; text * / reads
#      as a DOUBLE.
#  16. Exact arithmetic is typed: + - is a BIGINT unless an operand is
#      an INT128, * / an INT128 over any operand wider than 4 bytes; a
#      BIGINT past its range is the bare *Integer overflow*, an INT128
#      the prefixed one, a rescale *numeric value is out of range* (the
#      BIGINT minimum / -1 PANICKED the server).
#  17. `:SQLCODE` (any context variable) is -104 *Token unknown* at the
#      name; SUSPEND in a block with no RETURNS is -104 at prepare.
#
# RECORDED (the engine answers, this server refuses - a clean refusal,
# never a wrong value): NEXT VALUE FOR in a block; a selectable procedure
# in a scalar subquery or a join; a CAST argument; sub-functions and
# sub-procedures; WHERE CURRENT OF; FETCH ABSOLUTE NULL; a DOMAIN-typed
# block output; RETURNING OLD.<col> INTO; a trigger with COALESCE. And the
# engine's prepare-time vectors this server answers with its generic
# refusal: section 11's vectors but the -204, the -313 and the derived
# table's -104; SQLCODE assigned, ten USING values, a message beside
# USING, an unknown exception, a bare expression statement, COUNT(*) over a
# non-selectable procedure, a loop cursor's column out of its loop, and a
# body query's unbound qualifier. Section 13's blob in an expression
# (`C.B || 'x'`, `IF (C.B = ...)`) and a BLOB block output.
#
#   qa/serve-real-psqlgram.sh [port]     (default 5890; engine at 3050)

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5890}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/psqlgram-eng.fdb"; FC="$D/psqlgram-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE EXCEPTION E_SIMPLE 'simple error';
CREATE EXCEPTION E_PARAM 'bad value @1 in @2';
CREATE EXCEPTION E_NONE 'no params';
CREATE EXCEPTION E_MANY 'a@1b@2c@3d@10e@0f@';
CREATE SEQUENCE G1;
CREATE TABLE T1 (ID INTEGER NOT NULL PRIMARY KEY, BI BIGINT);
INSERT INTO T1 VALUES (1, 10);
INSERT INTO T1 VALUES (2, 20);
INSERT INTO T1 VALUES (3, 30);
CREATE TABLE TT (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(20), N INTEGER, M INTEGER);
CREATE TABLE TA (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(20), N INTEGER, M INTEGER);
CREATE TABLE TB (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(20), N INTEGER, M INTEGER);
CREATE TABLE TC (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(20), N INTEGER, M INTEGER);
CREATE TABLE TD5 (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(20), N INTEGER, M INTEGER);
CREATE TABLE TLOG (ID INTEGER, MSG VARCHAR(40));
CREATE TABLE TD (ID INTEGER, D DATE, X DOUBLE PRECISION, B BOOLEAN);
INSERT INTO TD VALUES (1, DATE '2024-02-28', 2.5, TRUE);
CREATE DOMAIN DPOS AS INTEGER CHECK (VALUE > 0);
CREATE DOMAIN DNN AS INTEGER NOT NULL;
CREATE DOMAIN DD7 AS INTEGER DEFAULT 7;
CREATE DOMAIN DV3 AS VARCHAR(3) CHECK (VALUE <> 'bad');
CREATE DOMAIN DNUMC AS NUMERIC(5,2) CHECK (VALUE < 100);
CREATE DOMAIN DSMALL AS INTEGER CHECK (VALUE < 3);
CREATE TABLE TBLB (ID INTEGER, B BLOB SUB_TYPE TEXT, BB BLOB, BU BLOB SUB_TYPE TEXT CHARACTER SET UTF8);
INSERT INTO TBLB VALUES (1, 'blobtext', 'bin', 'utf');
CREATE TABLE TSC (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER);
CREATE TABLE TSD (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER);
SET TERM ^;
CREATE PROCEDURE PSQ (N INTEGER) RETURNS (I INTEGER, SQ BIGINT) AS BEGIN I = 1; WHILE (I <= N) DO BEGIN SQ = I * I; SUSPEND; I = I + 1; END END^
CREATE PROCEDURE PDEF (A INTEGER = 1, B VARCHAR(10) = 'dflt') RETURNS (R VARCHAR(30)) AS BEGIN R = A || B; SUSPEND; END^
CREATE PROCEDURE P_REC (N INTEGER) RETURNS (R INTEGER) AS BEGIN R = N; SUSPEND; IF (N > 0) THEN FOR SELECT R FROM P_REC(:N - 1) INTO :R DO SUSPEND; END^
CREATE PROCEDURE P_EXEC (N INTEGER) RETURNS (R INTEGER) AS BEGIN R = N; END^
CREATE FUNCTION G7F (A DATE) RETURNS DATE AS BEGIN RETURN A; END^
CREATE FUNCTION FDT (A DATE, N INTEGER) RETURNS DATE AS BEGIN RETURN A + N; END^
CREATE FUNCTION FDBL (A DOUBLE PRECISION) RETURNS DOUBLE PRECISION AS BEGIN RETURN A * 2; END^
CREATE FUNCTION FBOOL (A BOOLEAN) RETURNS VARCHAR(5) AS BEGIN IF (A) THEN RETURN 'yes'; RETURN 'no'; END^
CREATE PROCEDURE PDT (A DATE) RETURNS (R DATE, Y INTEGER) AS BEGIN R = A + 1; Y = EXTRACT(YEAR FROM A); SUSPEND; END^
CREATE FUNCTION FTS (A TIMESTAMP) RETURNS TIME AS BEGIN RETURN CAST(A AS TIME); END^
CREATE PROCEDURE PCODE RETURNS (M INTEGER, G INTEGER, S VARCHAR(5)) AS BEGIN BEGIN M = 1/0; WHEN ANY DO BEGIN M = SQLCODE; G = GDSCODE; S = SQLSTATE; END END SUSPEND; END^
CREATE PROCEDURE PEXU (N INTEGER) RETURNS (R INTEGER) AS BEGIN R = N; EXCEPTION E_PARAM USING (:N, 'p'); SUSPEND; END^
CREATE PROCEDURE PCTX RETURNS (R VARCHAR(20)) AS BEGIN RDB$SET_CONTEXT('USER_TRANSACTION', 'PK', 'pv'); R = RDB$GET_CONTEXT('USER_TRANSACTION', 'PK'); SUSPEND; END^
CREATE PROCEDURE PSCR RETURNS (X INTEGER) AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH LAST FROM C INTO :X; SUSPEND; FETCH PRIOR FROM C INTO :X; SUSPEND; X = C.ID * 10; SUSPEND; CLOSE C; END^
CREATE PROCEDURE PBLOB RETURNS (R VARCHAR(40)) AS BEGIN SELECT B FROM TBLB WHERE ID = 1 INTO R; SUSPEND; END^
CREATE FUNCTION FBLOB RETURNS VARCHAR(40) AS DECLARE R VARCHAR(40); BEGIN SELECT LIST(ID) FROM T1 INTO R; RETURN R; END^
CREATE PROCEDURE PDOM (A INTEGER) RETURNS (R INTEGER) AS DECLARE X DPOS; BEGIN X = A; R = X; SUSPEND; END^
CREATE TRIGGER TSC_BI FOR TSC BEFORE INSERT AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); DECLARE K INTEGER; BEGIN OPEN C; FETCH LAST FROM C INTO K; NEW.N = K; FETCH PRIOR FROM C INTO K; NEW.N = NEW.N * 10 + K; FETCH ABSOLUTE 1 FROM C INTO K; NEW.N = NEW.N * 10 + K; CLOSE C; END^
CREATE TRIGGER TSD_BI FOR TSD BEFORE INSERT AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); DECLARE K INTEGER; BEGIN OPEN C; FETCH LAST FROM C INTO K; NEW.N = K; CLOSE C; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -user "$U" -pas "$P" > /tmp/psqlgram-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/psqlgram-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/psqlgram-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-psqlgram-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | grep -av '^At line .* in file' \
    | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the ENGINE is pinned (the law, not just agreement) and this server matches
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# what THIS SERVER WROTE, read back by the ENGINE: the fc file is copied
# (after the cells before have committed) and the engine answers the
# same query over both files
engboth() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    cp "$FC" "$D/psqlgram-fccopy.fdb"; chmod 666 "$D/psqlgram-fccopy.fdb"
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$REAL:$D/psqlgram-fccopy.fdb" "$2")
    rm -f "$D/psqlgram-fccopy.fdb"
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# RECORDED: the engine answers, this server REFUSES (a clean error, never
# a wrong value). Fails the day the two agree, so the cell gets promoted.
refused() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS; promote the cell"; fail=1
    elif [ "${fv#*Statement failed}" = "$fv" ]; then
        echo "FAIL $1 - this server neither answers nor refuses"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: the engine answers [$ev], this server refuses)"; fi
}
# RECORDED: the engine says one thing, this server another - an error
# vector it does not reproduce, pinned on both sides so it cannot drift.
known() { # <label> <script> <engine-output> <fc-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server answers [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded: the engine answers [$ev], this server [$fv])"; fi
}
eb() { printf 'SET TERM ^;\n%s^\nSET TERM ;^\n' "$1"; }

echo $'--- 1. THE ERROR CONTEXT VARIABLES: SQLCODE, GDSCODE, SQLSTATE'
pin     $'1 SQLCODE outside a handler is 0' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN M = SQLCODE; SUSPEND; END^\nSET TERM ;^' $'M|0'
pin     $'1 GDSCODE and SQLSTATE outside a handler: 0 and \'00000\'' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, S VARCHAR(5)) AS BEGIN M = GDSCODE; S = SQLSTATE; SUSPEND; END^\nSET TERM ;^' $'M S|0 00000'
pin     $'1 a division by zero: GDSCODE 335544321 (isc_arith_except, the FIRST code)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN BEGIN M = 1/0; WHEN ANY DO M = GDSCODE; END SUSPEND; END^\nSET TERM ;^' $'M|335544321'
pin     $'1 ...SQLCODE -802, SQLSTATE 22012 (the whole vector\'s)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, S VARCHAR(5)) AS BEGIN BEGIN M = 1/0; WHEN ANY DO BEGIN M = SQLCODE; S = SQLSTATE; END END SUSPEND; END^\nSET TERM ;^' $'M S|-802 22012'
pin     $'1 a user exception: -836 335544517 HY000' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, G INTEGER, S VARCHAR(5)) AS BEGIN BEGIN EXCEPTION E_SIMPLE; WHEN ANY DO BEGIN M = SQLCODE; G = GDSCODE; S = SQLSTATE; END END SUSPEND; END^\nSET TERM ;^' $'M G S|-836 335544517 HY000'
pin     $'1 a duplicate key: -803 335544665 23000' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, G INTEGER, S VARCHAR(5)) AS BEGIN BEGIN INSERT INTO T1 VALUES (1, 1); WHEN ANY DO BEGIN M = SQLCODE; G = GDSCODE; S = SQLSTATE; END END SUSPEND; END^\nSET TERM ;^' $'M G S|-803 335544665 23000'
pin     $'1 a conversion error: -413 335544334 22018' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, G INTEGER, S VARCHAR(5)) AS BEGIN BEGIN M = CAST(\'x\' AS INTEGER); WHEN ANY DO BEGIN M = SQLCODE; G = GDSCODE; S = SQLSTATE; END END SUSPEND; END^\nSET TERM ;^' $'M G S|-413 335544334 22018'
pin     $'1 after the handler has run they are 0 again' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, G INTEGER, S VARCHAR(5)) AS BEGIN BEGIN M = 1/0; WHEN ANY DO BEGIN M = 1; END END M = SQLCODE; G = GDSCODE; S = SQLSTATE; SUSPEND; END^\nSET TERM ;^' $'M G S|0 0 00000'
pin     $'1 an outer handler sees what IT caught - the inner raise' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, G INTEGER, S VARCHAR(5)) AS BEGIN BEGIN BEGIN M = 1/0; WHEN ANY DO BEGIN M = SQLCODE; EXCEPTION E_SIMPLE; END END WHEN ANY DO BEGIN M = SQLCODE; G = GDSCODE; S = SQLSTATE; END END SUSPEND; END^\nSET TERM ;^' $'M G S|-836 335544517 HY000'
pin     $'1 ...and once a NESTED handler completes, the outer one reads 0' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, G INTEGER, S VARCHAR(5)) AS BEGIN BEGIN M = 1/0; WHEN ANY DO BEGIN BEGIN EXCEPTION E_SIMPLE; WHEN ANY DO M = 0; END M = SQLCODE; G = GDSCODE; S = SQLSTATE; END END SUSPEND; END^\nSET TERM ;^' $'M G S|0 0 00000'
pin     $'1 WHEN SQLCODE -802 DO M = SQLCODE' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN BEGIN M = 1/0; WHEN SQLCODE -802 DO M = SQLCODE; END SUSPEND; END^\nSET TERM ;^' $'M|-802'
pin     $'1 USING\'s exception is the user exception\'s identity' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER, G INTEGER) AS BEGIN BEGIN EXCEPTION E_PARAM USING (\'a\', \'b\'); WHEN ANY DO BEGIN M = SQLCODE; G = GDSCODE; END END SUSPEND; END^\nSET TERM ;^' $'M G|-836 335544517'
pin     $'1 inside an expression: \'x\' || SQLSTATE, GDSCODE + 1' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (S VARCHAR(10), M BIGINT) AS BEGIN S = \'x\' || SQLSTATE; M = GDSCODE + 1; SUSPEND; END^\nSET TERM ;^' $'S M|x00000 1'
pin     $'1 in a stored procedure\'s handler' $'SELECT * FROM PCODE;' $'M G S|-802 335544321 22012'
pin     $'1 a local\'s validation error is 335544879' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X DPOS; BEGIN BEGIN X = -1; WHEN ANY DO R = GDSCODE; END SUSPEND; END^\nSET TERM ;^' $'R|335544879'
known   $'1 SQLCODE is read-only: the engine\'s -104 at prepare, this server\'s refusal' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN SQLCODE = 5; M = 1; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 44|-SQLCODE' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo $'--- 2. EXCEPTION <name> <message expression> AND EXCEPTION ... USING (...)'
pin     $'2 USING (\'X\', \'Y\') fills @1 and @2' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_PARAM USING (\'X\', \'Y\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value X in Y|-At block line: 1, col: 24'
pin     $'2 a VARIABLE message' $'SET TERM ^;\nEXECUTE BLOCK AS DECLARE S VARCHAR(20) = \'var msg\'; BEGIN EXCEPTION E_SIMPLE S; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-var msg|-At block line: 1, col: 59'
pin     $'2 a concatenation message' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_SIMPLE \'a\' || \'b\'; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-ab|-At block line: 1, col: 24'
pin     $'2 a numeric expression message is its text' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_SIMPLE 1+1; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-2|-At block line: 1, col: 24'
pin     $'2 a function-call message' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_SIMPLE UPPER(\'shout\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-SHOUT|-At block line: 1, col: 24'
pin     $'2 a NULL message is no override: the catalog\'s text' $'SET TERM ^;\nEXECUTE BLOCK AS DECLARE S VARCHAR(20); BEGIN EXCEPTION E_SIMPLE S; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-simple error|-At block line: 1, col: 47'
pin     $'2 ...and so is an EMPTY literal' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_SIMPLE \'\'; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-simple error|-At block line: 1, col: 24'
pin     $'2 CONTROL a literal message' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_SIMPLE \'lit\'; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-lit|-At block line: 1, col: 24'
pin     $'2 USING with one value leaves @2 as written' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_PARAM USING (\'X\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value X in @2|-At block line: 1, col: 24'
pin     $'2 a NULL value is \'*** null ***\'' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_PARAM USING (\'X\', NULL); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value X in *** null ***|-At block line: 1, col: 24'
pin     $'2 a third value is ignored, numbers are their text' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_PARAM USING (1, 2, 3); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value 1 in 2|-At block line: 1, col: 24'
pin     $'2 a NUMERIC keeps its scale, a DATE is ISO' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_PARAM USING (1.50, DATE \'2024-01-02\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value 1.50 in 2024-01-02|-At block line: 1, col: 24'
pin     $'2 a DOUBLE and a BOOLEAN' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_PARAM USING (1e0/3, TRUE); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value 0.3333333333333333 in TRUE|-At block line: 1, col: 24'
pin     $'2 a message with no placeholder is unchanged' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_NONE USING (\'x\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 3|-"PUBLIC"."E_NONE"|-no params|-At block line: 1, col: 24'
pin     $'2 a placeholder is ONE digit 1-9: @10 is @1 then 0, @0 and a trailing @ are text' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_MANY USING (\'1\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 4|-"PUBLIC"."E_MANY"|-a1b@2c@3d10e@0f@|-At block line: 1, col: 24'
pin     $'2 variables, bare and colon, and the raise\'s position' $'SET TERM ^;\nEXECUTE BLOCK AS DECLARE I INTEGER = 7; BEGIN EXCEPTION E_PARAM USING (I, :I * 2); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value 7 in 14|-At block line: 1, col: 47'
pin     $'2 expressions as values' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_PARAM USING (\'X\' || \'Z\', UPPER(\'y\')); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value XZ in Y|-At block line: 1, col: 24'
pin     $'2 a USING raise is caught by WHEN EXCEPTION <name>' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M VARCHAR(20)) AS BEGIN BEGIN EXCEPTION E_PARAM USING (\'X\', \'Y\'); WHEN EXCEPTION E_PARAM DO M = \'caught\'; END SUSPEND; END^\nSET TERM ;^' $'M|caught'
pin     $'2 in a stored procedure, its frame named' $'SELECT * FROM PEXU(5);' $'R|Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value 5 in p|-At procedure "PUBLIC"."PEXU" line: 1, col: 71'
known   $'2 ten USING values: the engine\'s 07002 at prepare, this server\'s refusal' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_MANY USING (\'1\',\'2\',\'3\',\'4\',\'5\',\'6\',\'7\',\'8\',\'9\',\'10\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 07002|Number of arguments (10) exceeds the maximum (9) number of EXCEPTION USING arguments' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'2 a message AND a USING list: the engine\'s -104, this server\'s refusal' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_SIMPLE \'x\' USING (\'a\'); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 47|-USING' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'2 an unknown exception: the engine\'s invalid BLR at prepare, this server\'s refusal' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_NOPE; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|invalid request BLR at offset 22|-exception "PUBLIC"."E_NOPE" not defined' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo $'--- 3. VALUES THE ARITHMETIC EVALUATOR HAS NO RULE FOR ARE THE PLANNER\'S'
pin     $'3 a BOOLEAN output from TRUE' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R BOOLEAN) AS BEGIN R = TRUE; SUSPEND; END^\nSET TERM ;^' $'R|<true>'
pin     $'3 ...from a comparison, and from the text \'false\'' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R BOOLEAN, S BOOLEAN) AS BEGIN R = 1 < 2; S = \'false\'; SUSPEND; END^\nSET TERM ;^' $'R S|<true> <false>'
pin     $'3 ...a text that is no boolean is 22018' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R BOOLEAN) AS BEGIN R = \'x\'; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22018|conversion error from string "x"|-At block line: 1, col: 44'
pin     $'3 a DATE output from a DATE literal' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DATE) AS BEGIN R = DATE \'2024-03-01\'; SUSPEND; END^\nSET TERM ;^' $'R|2024-03-01'
pin     $'3 a DATE local plus a number' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DATE) AS DECLARE D DATE = \'2024-03-01\'; BEGIN R = D + 1; SUSPEND; END^\nSET TERM ;^' $'R|2024-03-02'
pin     $'3 ...the difference of two dates' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE D DATE = \'2024-03-01\'; DECLARE E DATE = \'2024-02-01\'; BEGIN R = D - E; SUSPEND; END^\nSET TERM ;^' $'R|29'
pin     $'3 a TIME output from a string' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R TIME) AS BEGIN R = \'10:11:12\'; SUSPEND; END^\nSET TERM ;^' $'R|10:11:12.0000'
pin     $'3 a DOUBLE output, 1e0/3' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS BEGIN R = 1e0/3; SUSPEND; END^\nSET TERM ;^' $'R|0.3333333333333333'
pin     $'3 a FLOAT output' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R FLOAT) AS BEGIN R = 2.5; SUSPEND; END^\nSET TERM ;^' $'R|2.5000000'
pin     $'3 ...DOUBLE arithmetic over a DOUBLE local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE X DOUBLE PRECISION = 2; BEGIN R = X * 1.5 + 1; SUSPEND; END^\nSET TERM ;^' $'R|4.000000000000000'
pin     $'3 CONTROL \'12\' into an INTEGER output' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = \'12\'; SUSPEND; END^\nSET TERM ;^' $'R|12'
pin     $'3 CONTROL \'x12\' is 22018 at the assignment' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = \'x12\'; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22018|conversion error from string "x12"|-At block line: 1, col: 44'
pin     $'3 ABS, MOD and a unary minus over a local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (A INTEGER, B INTEGER, C INTEGER) AS DECLARE I INTEGER = 3; BEGIN A = ABS(-3); B = MOD(10, 3); C = -I; SUSPEND; END^\nSET TERM ;^' $'A B C|3 1 -3'
pin     $'3 COALESCE and IIF over locals' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (A INTEGER, B INTEGER) AS DECLARE X INTEGER; DECLARE Y INTEGER = 5; BEGIN A = COALESCE(X, 3); B = IIF(Y > 3, 1, 0); SUSPEND; END^\nSET TERM ;^' $'A B|3 1'
pin     $'3 a function\'s RETURN over a DATE parameter' $'SELECT FDT(DATE \'2024-02-28\', 2) FROM RDB$DATABASE;' $'FDT|2024-03-01'
refused $'3 NEXT VALUE FOR in a block (a draw no caller owns here)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = NEXT VALUE FOR G1; SUSPEND; END^\nSET TERM ;^' $'R|1'
echo $'--- 4. A FUNCTION CALL IS A STATEMENT; RDB$SET_CONTEXT / RDB$GET_CONTEXT'
pin     $'4 RDB$SET_CONTEXT as a statement, then RDB$GET_CONTEXT - and the session keeps it' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS BEGIN RDB$SET_CONTEXT(\'USER_SESSION\', \'K1\', \'hello\'); R = RDB$GET_CONTEXT(\'USER_SESSION\', \'K1\'); SUSPEND; END^\nSET TERM ;^\nSELECT RDB$GET_CONTEXT(\'USER_SESSION\', \'K1\') AS G FROM RDB$DATABASE;' $'R|hello|G|hello'
pin     $'4 USER_TRANSACTION' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN RDB$SET_CONTEXT(\'USER_TRANSACTION\', \'K2\', \'v2\'); R = RDB$GET_CONTEXT(\'USER_TRANSACTION\', \'K2\'); SUSPEND; END^\nSET TERM ;^' $'R|v2'
pin     $'4 a NULL value clears the key' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN RDB$SET_CONTEXT(\'USER_SESSION\', \'K3\', \'a\'); RDB$SET_CONTEXT(\'USER_SESSION\', \'K3\', NULL); R = COALESCE(RDB$GET_CONTEXT(\'USER_SESSION\', \'K3\'), \'null\'); SUSPEND; END^\nSET TERM ;^' $'R|null'
pin     $'4 RDB$SET_CONTEXT\'s value: 0 for a new key, 1 for an existing one' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN R = RDB$SET_CONTEXT(\'USER_SESSION\', \'K4\', \'a\'); SUSPEND; R = RDB$SET_CONTEXT(\'USER_SESSION\', \'K4\', \'b\'); SUSPEND; END^\nSET TERM ;^' $'R|0|1'
pin     $'4 a bad namespace raises at the call statement' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN RDB$SET_CONTEXT(\'BADNS\', \'k\', \'v\'); R = \'x\'; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = HY000|Invalid namespace name \'BADNS\' passed to RDB$SET_CONTEXT|-At block line: 1, col: 48'
pin     $'4 names and values from locals' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE K VARCHAR(5) = \'K5\'; BEGIN RDB$SET_CONTEXT(\'USER_SESSION\', K, K || \'!\'); R = RDB$GET_CONTEXT(\'USER_SESSION\', :K); SUSPEND; END^\nSET TERM ;^' $'R|K5!'
pin     $'4 SYSTEM ISOLATION_LEVEL' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS BEGIN R = RDB$GET_CONTEXT(\'SYSTEM\', \'ISOLATION_LEVEL\'); SUSPEND; END^\nSET TERM ;^' $'R|SNAPSHOT'
pin     $'4 UPPER(\'x\'); and a user function\'s call as statements' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN UPPER(\'x\'); G7F(CURRENT_DATE); R = \'ok\'; SUSPEND; END^\nSET TERM ;^' $'R|ok'
pin     $'4 in a stored procedure' $'SELECT * FROM PCTX;' $'R|pv'
known   $'4 a bare expression is no statement: the engine\'s -104, this server\'s refusal' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN 1/0; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 24|-1' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo $'--- 5. PROCEDURE ARGUMENTS: DEFAULT, EXPRESSIONS, THE ARITY, AND NEW PARAMETER TYPES'
pin     $'5 PDEF(DEFAULT, \'z\')' $'SELECT * FROM PDEF(DEFAULT, \'z\');' $'R|1z'
pin     $'5 PDEF(DEFAULT) and PDEF(DEFAULT, DEFAULT)' $'SELECT * FROM PDEF(DEFAULT);\nSELECT * FROM PDEF(DEFAULT, DEFAULT);' $'R|1dflt|R|1dflt'
pin     $'5 PDEF(7, DEFAULT), PDEF(NULL, DEFAULT)' $'SELECT * FROM PDEF(7, DEFAULT);\nSELECT * FROM PDEF(NULL, DEFAULT);' $'R|7dflt|R|<null>'
pin     $'5 EXECUTE PROCEDURE PDEF(DEFAULT, \'q\')' $'EXECUTE PROCEDURE PDEF(DEFAULT, \'q\');' $'R|1q'
pin     $'5 DEFAULT for a parameter with no default is NULL: no rows' $'SELECT * FROM PSQ(DEFAULT);' $''
pin     $'5 ...and EXECUTE PROCEDURE PSQ(DEFAULT) answers 1, NULL' $'EXECUTE PROCEDURE PSQ(DEFAULT);' $'I SQ|1 <null>'
pin     $'5 CONTROL PDEF and PDEF(5)' $'SELECT * FROM PDEF;\nSELECT * FROM PDEF(5);' $'R|1dflt|R|5dflt'
pin     $'5 EXECUTE PROCEDURE leaving off a parameter with no default: 07001 at prepare' $'EXECUTE PROCEDURE PSQ;' $'Statement failed, SQLSTATE = 07001|Parameter mismatch for procedure "PUBLIC"."PSQ"|-Parameter N has no default value and was not specified or was specified with DEFAULT'
pin     $'5 EXECUTE PROCEDURE with one argument too many: 07001 wrong number' $'EXECUTE PROCEDURE PSQ(1, 2);' $'Statement failed, SQLSTATE = 07001|Parameter mismatch for procedure "PUBLIC"."PSQ"|-wrong number of arguments on call'
pin     $'5 CONTROL SELECT * FROM PSQ(1, 2) and FROM PSQ keep the wrapped -170' $'SELECT * FROM PSQ(1, 2);\nSELECT * FROM PSQ;' $'Statement failed, SQLSTATE = 07001|Dynamic SQL Error|-Parameter mismatch for procedure "PUBLIC"."PSQ"|Statement failed, SQLSTATE = 07001|Dynamic SQL Error|-Parameter mismatch for procedure "PUBLIC"."PSQ"'
pin     $'5 a RECURSIVE selectable procedure: P_REC(:N - 1)' $'SELECT * FROM P_REC(2);' $'R|2|1|0'
pin     $'5 an argument EXPRESSION: 1 + 1, 4 / 2, 2 * 2 - 1, (3), -1 + 3' $'SELECT * FROM P_REC(1 + 1);\nSELECT * FROM PSQ(4 / 2);\nSELECT * FROM PSQ(2 * 2 - 1);\nSELECT * FROM PSQ((3));\nSELECT * FROM PSQ(-1 + 3);' $'R|2|1|0|I SQ|1 1|2 4|I SQ|1 1|2 4|3 9|I SQ|1 1|2 4|3 9|I SQ|1 1|2 4'
pin     $'5 a DATE parameter: G7F(DATE \'2024-01-01\'), G7F(NULL)' $'SELECT G7F(DATE \'2024-01-01\') FROM RDB$DATABASE;\nSELECT G7F(NULL) FROM RDB$DATABASE;' $'G7F|2024-01-01|G7F|<null>'
pin     $'5 ...its text argument converts at the call, 22018 with no position' $'SELECT G7F(\'2024-05-06\') FROM RDB$DATABASE;\nSELECT G7F(\'bad\') FROM RDB$DATABASE;' $'G7F|2024-05-06|G7F|Statement failed, SQLSTATE = 22018|conversion error from string "bad"'
pin     $'5 ...a column argument' $'SELECT FDT(D, ID) FROM TD;' $'FDT|2024-02-29'
pin     $'5 a DOUBLE parameter' $'SELECT FDBL(1.25e0) FROM RDB$DATABASE;\nSELECT FDBL(X) FROM TD;' $'FDBL|2.500000000000000|FDBL|5.000000000000000'
pin     $'5 a BOOLEAN parameter' $'SELECT FBOOL(TRUE), FBOOL(FALSE), FBOOL(NULL) FROM RDB$DATABASE;\nSELECT FBOOL(B) FROM TD;' $'FBOOL FBOOL FBOOL|yes no no|FBOOL|yes'
pin     $'5 a TIMESTAMP parameter, a TIME return' $'SELECT FTS(TIMESTAMP \'2024-01-02 10:11:12\') FROM RDB$DATABASE;' $'FTS|10:11:12.0000'
pin     $'5 a selectable procedure over a DATE parameter, and EXECUTE PROCEDURE of it' $'SELECT * FROM PDT(DATE \'2024-12-31\');\nEXECUTE PROCEDURE PDT(DATE \'2024-12-31\');' $'R Y|2025-01-01 2024|R Y|2025-01-01 2024'
pin     $'5 a DATE function called in a block' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DATE) AS BEGIN R = G7F(DATE \'2020-02-02\'); SUSPEND; END^\nSET TERM ;^' $'R|2020-02-02'
refused $'5 a selectable procedure in a scalar subquery' $'SELECT (SELECT MAX(SQ) FROM PSQ(3)) AS M FROM RDB$DATABASE;' $'M|9'
refused $'5 a selectable procedure joined to a table' $'SELECT T1.ID, P.SQ FROM T1 JOIN PSQ(3) P ON P.I = T1.ID ORDER BY 1;' $'ID SQ|1 1|2 4|3 9'
refused $'5 a CAST argument that is not a numeric literal' $'SELECT * FROM PSQ(CAST(\'2\' AS INTEGER));' $'I SQ|1 1|2 4'
refused $'5 a sub-function (DECLARE FUNCTION)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE FUNCTION SQ(X INTEGER) RETURNS INTEGER AS BEGIN RETURN X*X; END BEGIN R = SQ(7); SUSPEND; END^\nSET TERM ;^' $'R|49'
refused $'5 a sub-procedure (DECLARE PROCEDURE)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE PROCEDURE PP(X INTEGER) RETURNS (Y INTEGER) AS BEGIN Y = X + 1; SUSPEND; END BEGIN SELECT Y FROM PP(4) INTO :R; SUSPEND; END^\nSET TERM ;^' $'R|5'
known   $'5 COUNT(*) over a procedure with no SUSPEND: the engine\'s not-selectable vector, this server\'s refusal' $'SELECT COUNT(*) FROM P_EXEC(5);' $'Statement failed, SQLSTATE = 42000|invalid request BLR at offset 50|-Procedure "PUBLIC"."P_EXEC" is not selectable (it does not contain a SUSPEND statement)' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
echo $'--- 6. LOOPS AND CURSORS: BREAK, SCROLL, <cursor>.<column>, AS CURSOR'
pin     $'6 BREAK leaves the innermost loop' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (I INTEGER) AS BEGIN I = 0; WHILE (I < 10) DO BEGIN I = I + 1; IF (I > 2) THEN BREAK; END SUSPEND; END^\nSET TERM ;^' $'I|3'
pin     $'6 ...a FOR SELECT loop too' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN FOR SELECT ID FROM T1 ORDER BY ID INTO :X DO BEGIN IF (X = 2) THEN BREAK; SUSPEND; END END^\nSET TERM ;^' $'X|1'
pin     $'6 ORDER BY a position in a FOR SELECT' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN FOR SELECT ID FROM T1 ORDER BY 1 DESC INTO :X DO SUSPEND; END^\nSET TERM ;^' $'X|3|2|1'
pin     $'6 a SCROLL cursor: LAST PRIOR FIRST ABSOLUTE RELATIVE NEXT, past the end, ABSOLUTE 0, PRIOR' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER, RC INTEGER) AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH LAST FROM C INTO :X; RC = ROW_COUNT; SUSPEND; FETCH PRIOR FROM C INTO :X; RC = ROW_COUNT; SUSPEND; FETCH FIRST FROM C INTO :X; SUSPEND; FETCH ABSOLUTE 3 FROM C INTO :X; SUSPEND; FETCH RELATIVE -1 FROM C INTO :X; SUSPEND; FETCH NEXT FROM C INTO :X; SUSPEND; FETCH NEXT FROM C INTO :X; RC = ROW_COUNT; SUSPEND; FETCH ABSOLUTE 0 FROM C INTO :X; RC = ROW_COUNT; SUSPEND; FETCH PRIOR FROM C INTO :X; RC = ROW_COUNT; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X RC|3 1|2 1|1 1|3 1|2 1|3 1|3 0|3 0|3 0'
pin     $'6 ABSOLUTE -1 is the last row, RELATIVE past the end finds nothing' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH ABSOLUTE -1 FROM C INTO :X; SUSPEND; FETCH RELATIVE 5 FROM C INTO :X; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X|3|3'
pin     $'6 ABSOLUTE n and RELATIVE -n from a local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); DECLARE N INTEGER = 2; BEGIN OPEN C; FETCH ABSOLUTE N FROM C INTO :X; SUSPEND; FETCH RELATIVE -N FROM C INTO :X; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X|2|2'
pin     $'6 a plain cursor takes FETCH NEXT FROM' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH NEXT FROM C INTO :X; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X|1'
pin     $'6 ...but FETCH LAST is HY106 at the FETCH' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH LAST FROM C INTO :X; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X|Statement failed, SQLSTATE = HY106|Fetch option LAST is invalid for a non-scrollable cursor|-At block line: 1, col: 106'
pin     $'6 <cursor>.<column> reads the current record' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER, Y BIGINT) AS DECLARE C CURSOR FOR (SELECT ID, BI FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C INTO :X, :Y; X = C.ID + 100; Y = C.BI; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X Y|101 10'
pin     $'6 ...FETCH without INTO, and an aliased column' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER, K INTEGER) AS DECLARE C CURSOR FOR (SELECT ID AS KK FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C; FETCH C; X = C.KK; K = C.KK * 2; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X K|2 4'
pin     $'6 ...before the first FETCH it is HY109' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; X = C.ID; SUSPEND; END^\nSET TERM ;^' $'X|Statement failed, SQLSTATE = HY109|Cursor "C" is not positioned in a valid record|-At block line: 1, col: 106'
pin     $'6 ...past the end, HY109 at the reading statement' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C; FETCH C; FETCH C; FETCH C; X = C.ID; SUSPEND; END^\nSET TERM ;^' $'X|Statement failed, SQLSTATE = HY109|Cursor "C" is not positioned in a valid record|-At block line: 1, col: 142'
pin     $'6 ...after CLOSE, 24000 Cursor is not open' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C INTO :X; CLOSE C; X = C.ID; SUSPEND; END^\nSET TERM ;^' $'X|Statement failed, SQLSTATE = 24000|Cursor is not open|-At block line: 1, col: 132'
pin     $'6 ...in a condition' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN X = 0; OPEN C; FETCH C; FETCH C; IF (C.ID = 2) THEN X = 1; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X|1'
pin     $'6 a FETCH from a cursor never opened is 24000 at the FETCH' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1); BEGIN FETCH C INTO :X; SUSPEND; END^\nSET TERM ;^' $'X|Statement failed, SQLSTATE = 24000|Cursor is not open|-At block line: 1, col: 86'
pin     $'6 ...and after CLOSE' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C; CLOSE C; FETCH C INTO :X; SUSPEND; END^\nSET TERM ;^' $'X|Statement failed, SQLSTATE = 24000|Cursor is not open|-At block line: 1, col: 124'
pin     $'6 OPEN of an open cursor starts it again; CLOSE of a closed one raises nothing' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C INTO :X; FETCH C INTO :X; OPEN C; FETCH C INTO :X; SUSPEND; CLOSE C; CLOSE C; END^\nSET TERM ;^' $'X|1'
pin     $'6 a FETCH that finds nothing leaves the INTO alone, then the field raises' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C CURSOR FOR (SELECT ID FROM T1 WHERE ID > 5); BEGIN OPEN C; FETCH C INTO :X; X = COALESCE(X, -1); SUSPEND; X = C.ID; SUSPEND; END^\nSET TERM ;^' $'X|-1|Statement failed, SQLSTATE = HY109|Cursor "C" is not positioned in a valid record|-At block line: 1, col: 154'
pin     $'6 FOR SELECT ... AS CURSOR: the loop\'s record by name' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN FOR SELECT ID FROM T1 ORDER BY ID DESC AS CURSOR C DO BEGIN X = C.ID; SUSPEND; END END^\nSET TERM ;^' $'X|3|2|1'
pin     $'6 ...with an INTO as well' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER, Y INTEGER) AS BEGIN FOR SELECT ID, BI FROM T1 ORDER BY ID INTO :X, :Y AS CURSOR CC DO BEGIN X = CC.ID * 10; SUSPEND; END END^\nSET TERM ;^' $'X Y|10 10|20 20|30 30'
pin     $'6 ...BREAK out of it' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN FOR SELECT ID FROM T1 ORDER BY ID AS CURSOR C DO BEGIN X = C.ID; IF (X = 2) THEN BREAK; SUSPEND; END END^\nSET TERM ;^' $'X|1'
known   $'6 ...and out of scope after it: the engine\'s -206 at prepare, this server refuses before a row' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN FOR SELECT ID FROM T1 ORDER BY ID AS CURSOR C DO X = C.ID; SUSPEND; X = C.ID; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"C"."ID"|-At line 1, column 116' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin     $'6 a stored procedure with a SCROLL cursor' $'SELECT * FROM PSCR;' $'X|3|2|20'
refused $'6 UPDATE ... WHERE CURRENT OF' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER, Y BIGINT) AS BEGIN FOR SELECT ID, BI FROM T1 WHERE ID < 3 ORDER BY ID AS CURSOR C DO BEGIN UPDATE T1 SET BI = BI + 1 WHERE CURRENT OF C; X = C.ID; Y = C.BI; SUSPEND; END END^\nSET TERM ;^\nROLLBACK;' $'X Y|1 11|2 21'
refused $'6 DELETE ... WHERE CURRENT OF' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN FOR SELECT ID FROM T1 WHERE ID = 3 AS CURSOR C DO DELETE FROM T1 WHERE CURRENT OF C; SELECT COUNT(*) FROM T1 INTO :X; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'X|2'
refused $'6 FETCH ABSOLUTE NULL' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (X INTEGER) AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH FIRST FROM C INTO :X; FETCH ABSOLUTE NULL FROM C INTO :X; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'X|1'
echo $'--- 7. TYPED LOCALS: DOMAINS, TYPE OF, TYPE OF COLUMN, NOT NULL'
pin     $'7 a CHECK domain local: NULL passes, 5 stores' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER, S INTEGER) AS DECLARE X DPOS; DECLARE Y DPOS; BEGIN R = X; Y = 5; S = Y; SUSPEND; END^\nSET TERM ;^' $'R S|<null> 5'
pin     $'7 ...-1 fails at the assignment' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X DPOS; BEGIN X = -1; R = X; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "-1"|-At block line: 1, col: 60'
pin     $'7 ...an initialiser fails at its DECLARE' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X DPOS = -2; BEGIN R = X; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "-2"|-At block line: 1, col: 38'
pin     $'7 a NOT NULL domain: never written is no error' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X DNN; BEGIN R = 1; SUSPEND; END^\nSET TERM ;^' $'R|1'
pin     $'7 ...NULL written is \'*** null ***\'' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X DNN = 4; BEGIN R = X; X = NULL; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "*** null ***"|-At block line: 1, col: 70'
pin     $'7 a domain\'s DEFAULT starts the local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER, S INTEGER) AS DECLARE X DD7; DECLARE Y DD7 = 3; BEGIN R = X; S = Y; SUSPEND; END^\nSET TERM ;^' $'R S|7 3'
pin     $'7 a text domain\'s CHECK' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(10)) AS DECLARE X DV3; BEGIN X = \'bad\'; R = X; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "bad"|-At block line: 1, col: 63'
pin     $'7 ...its width' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(10)) AS DECLARE X DV3; BEGIN X = \'abcd\'; R = X; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 3, actual 4|-At block line: 1, col: 63'
pin     $'7 ...a value it takes' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(10)) AS DECLARE X DV3; BEGIN X = \'ok\'; R = X || \'!\'; SUSPEND; END^\nSET TERM ;^' $'R|ok!'
pin     $'7 a NUMERIC domain rounds, and its CHECK shows the value as written' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R NUMERIC(9,2)) AS DECLARE X DNUMC; BEGIN X = 1.005; R = X; SUSPEND; END^\nSET TERM ;^\nSET TERM ^;\nEXECUTE BLOCK RETURNS (R NUMERIC(9,2)) AS DECLARE X DNUMC; BEGIN X = 150; R = X; SUSPEND; END^\nSET TERM ;^' $'R|1.01|R|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "150"|-At block line: 1, col: 66'
pin     $'7 TYPE OF a domain takes the type, not the CHECK' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X TYPE OF DPOS; BEGIN X = -1; R = X; SUSPEND; END^\nSET TERM ;^' $'R|-1'
pin     $'7 TYPE OF COLUMN converts into the column\'s type' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X TYPE OF COLUMN T1.ID; BEGIN X = \'12\'; R = X + 1; SUSPEND; END^\nSET TERM ;^' $'R|13'
pin     $'7 ...a text column' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE X TYPE OF COLUMN TT.V = \'abc\'; BEGIN R = X; SUSPEND; END^\nSET TERM ;^' $'R|abc'
pin     $'7 an explicit NOT NULL on a local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X INTEGER NOT NULL; BEGIN X = 3; R = X; X = NULL; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "*** null ***"|-At block line: 1, col: 86'
pin     $'7 DECLARE ... DEFAULT' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X INTEGER DEFAULT 6; BEGIN R = X; SUSPEND; END^\nSET TERM ;^' $'R|6'
pin     $'7 a FETCH into a CHECK domain local validates too' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE X DSMALL; DECLARE C CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C INTO :X; R = X; SUSPEND; FETCH C INTO :X; FETCH C INTO :X; R = X; SUSPEND; CLOSE C; END^\nSET TERM ;^' $'R|1|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "3"|-At block line: 1, col: 174'
pin     $'7 in a stored procedure' $'SELECT * FROM PDOM(3);\nSELECT * FROM PDOM(-3);' $'R|3|R|Statement failed, SQLSTATE = 42000|validation error for variable "X", value "-3"|-At procedure "PUBLIC"."PDOM" line: 1, col: 80'
refused $'7 a DOMAIN-typed output of a block' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DPOS) AS BEGIN R = 3; SUSPEND; END^\nSET TERM ;^' $'R|3'
echo $'--- 8. DML ... RETURNING ... INTO'
pin     $'8 INSERT ... RETURNING INTO, ROW_COUNT 1' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER, RC INTEGER) AS BEGIN INSERT INTO T1 (ID, BI) VALUES (9, 90) RETURNING BI INTO :C; RC = ROW_COUNT; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'C RC|90 1'
pin     $'8 an UPDATE that matched nothing leaves the slot alone, ROW_COUNT 0' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER, RC INTEGER) AS BEGIN C = 5; UPDATE T1 SET BI = BI + 1 WHERE ID = 100 RETURNING BI INTO :C; RC = ROW_COUNT; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'C RC|5 0'
pin     $'8 an UPDATE of one row' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER, RC INTEGER) AS BEGIN UPDATE T1 SET BI = BI + 1 WHERE ID = 1 RETURNING BI INTO :C; RC = ROW_COUNT; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'C RC|11 1'
pin     $'8 ...of two rows is 21000 at the statement' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER, RC INTEGER) AS BEGIN UPDATE T1 SET BI = BI + 1 WHERE ID < 3 RETURNING BI INTO :C; RC = ROW_COUNT; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'C RC|Statement failed, SQLSTATE = 21000|multiple rows in singleton select|-At block line: 1, col: 56'
pin     $'8 a DELETE returning two items' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER, D INTEGER) AS BEGIN DELETE FROM T1 WHERE ID = 2 RETURNING ID, BI INTO :C, :D; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'C D|2 20'
pin     $'8 :variables in the statement, bare INTO targets, an expression item' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER, D VARCHAR(10)) AS DECLARE K INTEGER = 20; BEGIN INSERT INTO T1 (ID, BI) VALUES (:K, :K * 2) RETURNING ID, BI || \'x\' INTO C, D; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'C D|20 40x'
pin     $'8 a duplicate key raises at the statement' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER) AS BEGIN INSERT INTO T1 (ID, BI) VALUES (1, 1) RETURNING BI INTO :C; SUSPEND; END^\nSET TERM ;^' $'C|Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint "INTEG_2" on table "PUBLIC"."T1"|-Problematic key value is ("ID" = 1)|-At block line: 1, col: 44'
refused $'8 RETURNING OLD.<col> INTO' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (C INTEGER, O BIGINT) AS BEGIN UPDATE T1 SET BI = 0 WHERE ID = 1 RETURNING ID, OLD.BI INTO :C, :O; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'C O|1 10'
echo $'--- 9. TRIGGER BODIES'
pin     $'9 CREATE TRIGGER with \'I:\' || NEW.V (the colon inside the literal)' $'SET TERM ^;\nCREATE TRIGGER C2 FOR TA BEFORE INSERT AS BEGIN NEW.V = \'I:\' || NEW.V; END^\nSET TERM ;^\nCOMMIT;\nINSERT INTO TA (ID, V) VALUES (1, \'a\');\nSELECT V FROM TA;\nROLLBACK;' $'V|I:a'
pin     $'9 CREATE TRIGGER with DECLARE and no VARIABLE keyword' $'SET TERM ^;\nCREATE TRIGGER D1 FOR TB BEFORE INSERT AS DECLARE X INTEGER; BEGIN X = 5; NEW.N = X; END^\nSET TERM ;^\nCOMMIT;\nINSERT INTO TB (ID) VALUES (1);\nSELECT N FROM TB;\nROLLBACK;' $'N|5'
engboth $'9 the stored BLR and debug info are the engine\'s (both files read by the engine)' $'SELECT RDB$TRIGGER_NAME, CAST(CAST(RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(400) CHARACTER SET OCTETS) AS B, CAST(CAST(RDB$DEBUG_INFO AS BLOB SUB_TYPE 0) AS VARCHAR(400) CHARACTER SET OCTETS) AS D FROM RDB$TRIGGERS WHERE RDB$TRIGGER_NAME IN (\'C2\', \'D1\') ORDER BY 1;' $'RDB$TRIGGER_NAME B D|C2 0502110002020127150F00000200493A1701015617010156FFFFFF4C 010202010000002B0000000400000002010000003100000006000000FF|D1 05020300000800012D1A00001100020201150800050000001A0000011A00001701014EFFFFFF4C 0102030000015802010000002B0000000700000002010000003E0000000E0000000201000000440000001000000002010000004B0000001B000000FF'
pin     $'9 CONTROL an AFTER INSERT trigger that inserts' $'SET TERM ^;\nCREATE TRIGGER A4 FOR TC AFTER INSERT AS BEGIN INSERT INTO TLOG (ID, MSG) VALUES (NEW.ID, \'ins\'); END^\nSET TERM ;^\nCOMMIT;\nINSERT INTO TC (ID) VALUES (1);\nSELECT * FROM TLOG;\nROLLBACK;' $'ID MSG|1 ins'
known   $'9 CREATE TRIGGER with COALESCE(NEW.N, 0): the engine stores and fires it, this server refuses the DDL' $'SET TERM ^;\nCREATE TRIGGER D5 FOR TD5 BEFORE INSERT AS BEGIN NEW.M = COALESCE(NEW.N, 0) + 1; END^\nSET TERM ;^\nCOMMIT;\nINSERT INTO TD5 (ID) VALUES (1);\nSELECT M FROM TD5;\nROLLBACK;' $'M|1' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|M|<null>'
echo $'--- 10. A BODY\'S QUERY IS HELD TO THE PREPARE-TIME RULES'
known   $'10 a qualifier nothing binds: the engine\'s -206 at prepare, this server refuses (it answered 1)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN SELECT FIRST 1 T.ID FROM T1 T ORDER BY T1.ID INTO N; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"T1"."ID"|-At line 1, column 83' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'10 ...beside a construct the block compiler does not take' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SELECT FIRST 1 T.ID FROM T1 T ORDER BY T1.ID INTO N; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"T1"."ID"|-At line 1, column 96' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'

echo $'--- 11. THE BODY IS JUDGED WHOLE AT PREPARE, TAKEN BRANCH OR NOT'
pin     $'11 an unknown table in a branch that never runs: the engine\'s -204 at prepare' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (1 = 0) THEN SELECT ID FROM NOSUCHT INTO N; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-"NOSUCHT"|-At line 1, column 97'
known   $'11 an unknown column there: the engine\'s -206, this server\'s refusal (it answered 1)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = 1; SUSPEND; IF (N = 0) THEN SELECT NOSUCH FROM T1 INTO N; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 83' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 a syntax error in a value there (N = 1 +;): -104, refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 9) THEN N = 1 +; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 89|-;' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 ...SUBSTRING(... FOR 2 FOR 3): refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER, S VARCHAR(10)) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN S = SUBSTRING(\'abc\' FROM 1 FOR 2 FOR 3); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 130|-FOR' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 ...a variable nothing declares: refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN N = NOSUCHV + 1; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCHV"|-At line 1, column 86' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 a duplicate output: -637, refused (it answered two N columns)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER, N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -637|-duplicate specification of "N" - not supported' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 a duplicate local: -637, refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS DECLARE X INTEGER; DECLARE X INTEGER; BEGIN N = SQLCODE; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -637|-duplicate specification of "X" - not supported' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 ...and in a block the BLR compiler takes' $'SET TERM ^;\nEXECUTE BLOCK AS DECLARE X INTEGER; DECLARE X INTEGER; BEGIN X = 1; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -637|-duplicate specification of "X" - not supported' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 DECLARE SQLCODE: -104, refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS DECLARE SQLCODE INTEGER; BEGIN N = 1; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 46|-SQLCODE' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 a nested duplicate loop label: refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; L1: WHILE (N < 0) DO BEGIN L1: WHILE (N < 0) DO LEAVE L1; END END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-Label L1 already exists in the current scope' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 RETURN in a block: refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN RETURN 5; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown|-RETURN' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 CONTINUE outside a loop: refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN CONTINUE; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown|-CONTINUE' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 FETCH from a cursor nothing declares: HY015, refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN FETCH C INTO N; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = HY015|Dynamic SQL Error|-SQL error code = -504|-Invalid cursor reference|-Cursor "C" is not found in the current context' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 UPDATE ... SET <no such column>: refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN UPDATE TT SET NOSUCH = 1; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 96' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 an INSERT whose values do not count the columns: -804, refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN INSERT INTO TT VALUES (1); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 21S01|Dynamic SQL Error|-SQL error code = -804|-Count of read-write columns does not equal count of values' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
known   $'11 RETURNING <no such column> INTO: refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN INSERT INTO TT (ID) VALUES (1) RETURNING NOSUCH INTO N; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S22|Dynamic SQL Error|-SQL error code = -206|-Column unknown|-"NOSUCH"|-At line 1, column 123' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin     $'11 two columns into one variable there: the -313 at prepare, no row first' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = SQLCODE; SUSPEND; IF (N = 5) THEN SELECT ID, BI FROM T1 INTO N; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 07002|Dynamic SQL Error|-SQL error code = -313|-count of column list and variable list do not match'
known   $'11 a block with no RETURNS: an unknown table where it never runs, refused (it ran)' $'SET TERM ^;\nEXECUTE BLOCK AS DECLARE X INTEGER; BEGIN X = SQLCODE; IF (1 = 0) THEN INSERT INTO NOSUCHT VALUES (1); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42S02|Dynamic SQL Error|-SQL error code = -204|-Table unknown|-"NOSUCHT"|-At line 1, column 72' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error'
pin     $'11 CONTROL the same shapes where every name is known still run' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (N INTEGER, S VARCHAR(10)) AS DECLARE C CURSOR FOR (SELECT ID, ID + 1 AS X FROM T1 ORDER BY ID); BEGIN N = SQLCODE; IF (N = 5) THEN SELECT ID FROM T1 INTO N; IF (N = 5) THEN UPDATE TT SET N = 1; IF (N = 5) THEN S = SUBSTRING(\'abc\' FROM 1 FOR 2); OPEN C; FETCH C; N = C.X; SUSPEND; L1: WHILE (N < 3) DO BEGIN N = N + 1; IF (N = 3) THEN LEAVE L1; END SUSPEND; END^\nSET TERM ;^' $'N S|2 <null>|3 <null>'
pin     $'11 a named cursor is a derived table: an unnamed column is its -104 at prepare' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE C CURSOR FOR (SELECT ID, ID + 1 FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH C; R = C.ID; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-no column name specified for column number 2 in derived table C'
pin     $'11 ...read by FETCH INTO alone too' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE C CURSOR FOR (SELECT COUNT(*) FROM T1); BEGIN OPEN C; FETCH C INTO R; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-no column name specified for column number 1 in derived table C'
pin     $'11 ...and FOR SELECT ... AS CURSOR' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN FOR SELECT ID, ID + 1 FROM T1 AS CURSOR C DO BEGIN R = C.ID; SUSPEND; END END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command|-no column name specified for column number 2 in derived table C'
echo $'--- 12. VALUES THE PLANNER ANSWERS, CONTEXTS, SCROLL CURSORS'
pin     $'12 a FLOAT local in arithmetic is the single, not its short text' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M DOUBLE PRECISION) AS DECLARE F FLOAT = 0.1; BEGIN M = F * 3; SUSPEND; END^\nSET TERM ;^' $'M|0.3000000044703484'
pin     $'12 ...two REAL locals' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M DOUBLE PRECISION) AS DECLARE F REAL = 0.1; DECLARE G REAL = 0.2; BEGIN M = F + G; SUSPEND; END^\nSET TERM ;^' $'M|0.3000000044703484'
pin     $'12 ...into text, and through a SELECT' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M VARCHAR(40), D VARCHAR(40)) AS DECLARE F FLOAT = 0.1; BEGIN M = F * 3; SELECT :F * 3 FROM RDB$DATABASE INTO D; SUSPEND; END^\nSET TERM ;^' $'M D|0.3000000044703484 0.3000000044703484'
pin     $'12 a DOUBLE division by zero is the floating-point one' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 2; BEGIN M = A / 0; SUSPEND; END^\nSET TERM ;^' $'M|Statement failed, SQLSTATE = 22012|arithmetic exception, numeric overflow, or string truncation|-Floating-point divide by zero. The code attempted to divide a floating-point value by zero.|-At block line: 1, col: 85'
pin     $'12 ...by a DOUBLE zero' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M VARCHAR(40)) AS DECLARE A INTEGER = 7; DECLARE D DOUBLE PRECISION = 0; BEGIN M = A / D; SUSPEND; END^\nSET TERM ;^' $'M|Statement failed, SQLSTATE = 22012|arithmetic exception, numeric overflow, or string truncation|-Floating-point divide by zero. The code attempted to divide a floating-point value by zero.|-At block line: 1, col: 103'
pin     $'12 an AUTONOMOUS block\'s USER_TRANSACTION context is its own - gone after it' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN IN AUTONOMOUS TRANSACTION DO RDB$SET_CONTEXT(\'USER_TRANSACTION\', \'T5\', \'x\'); END^\nSET TERM ;^\nSELECT RDB$GET_CONTEXT(\'USER_TRANSACTION\', \'T5\') FROM RDB$DATABASE;\nSET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(10)) AS BEGIN IN AUTONOMOUS TRANSACTION DO BEGIN RDB$SET_CONTEXT(\'USER_TRANSACTION\', \'T6\', \'y\'); END R = RDB$GET_CONTEXT(\'USER_TRANSACTION\', \'T6\'); SUSPEND; END^\nSET TERM ;^' $'RDB$GET_CONTEXT|<null>|R|<null>'
pin     $'12 ...the assignment form, and an outer key is not seen inside' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(10), S VARCHAR(10)) AS BEGIN IN AUTONOMOUS TRANSACTION DO R = RDB$SET_CONTEXT(\'USER_TRANSACTION\', \'T8\', \'y\'); R = COALESCE(RDB$GET_CONTEXT(\'USER_TRANSACTION\', \'T8\'), \'null\'); RDB$SET_CONTEXT(\'USER_TRANSACTION\', \'T9\', \'o\'); IN AUTONOMOUS TRANSACTION DO S = COALESCE(RDB$GET_CONTEXT(\'USER_TRANSACTION\', \'T9\'), \'null\'); SUSPEND; END^\nSET TERM ;^' $'R S|null null'
pin     $'12 ...and the block reads back what it set' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(10)) AS BEGIN IN AUTONOMOUS TRANSACTION DO BEGIN RDB$SET_CONTEXT(\'USER_TRANSACTION\', \'TA\', \'y\'); R = RDB$GET_CONTEXT(\'USER_TRANSACTION\', \'TA\'); END SUSPEND; END^\nSET TERM ;^' $'R|y'
pin     $'12 FETCH RELATIVE 0 re-reads the row, ROW_COUNT 0' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER, F INTEGER) AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); BEGIN OPEN C; FETCH RELATIVE 2 FROM C INTO :R; F = ROW_COUNT; SUSPEND; R = 99; FETCH RELATIVE 0 FROM C INTO :R; F = ROW_COUNT; SUSPEND; R = 98; FETCH RELATIVE 1 FROM C INTO :R; F = ROW_COUNT; SUSPEND; END^\nSET TERM ;^' $'R F|2 1|2 0|3 1'
pin     $'12 ...without INTO, read by <cursor>.<column>; from a local 0' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER, F INTEGER) AS DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); DECLARE K INTEGER = 0; BEGIN OPEN C; FETCH ABSOLUTE 2 FROM C INTO :R; F = ROW_COUNT; SUSPEND; FETCH RELATIVE 0 FROM C; R = C.ID; F = ROW_COUNT; SUSPEND; FETCH RELATIVE K FROM C INTO :R; F = ROW_COUNT; SUSPEND; END^\nSET TERM ;^' $'R F|2 1|2 0|2 0'
pin     $'12 a SCROLL cursor in a TRIGGER scrolls' $'INSERT INTO TSC (ID) VALUES (1);\nSELECT * FROM TSC;\nROLLBACK;' $'ID N|1 321'
pin     $'12 ...a plain one there is HY106 at the FETCH' $'INSERT INTO TSD (ID) VALUES (1);\nROLLBACK;' $'Statement failed, SQLSTATE = HY106|Fetch option LAST is invalid for a non-scrollable cursor|-At trigger "PUBLIC"."TSD_BI" line: 1, col: 135'

echo $'--- 13. A BLOB MOVED INTO A SLOT OF ANOTHER TYPE IS ITS TEXT'
pin     $'13 LIST(...) INTO a VARCHAR: the text, not the id' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS BEGIN SELECT LIST(ID) FROM T1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|1,2,3'
pin     $'13 a text blob column INTO a VARCHAR (a typed local beside it)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE X DD7; BEGIN SELECT B FROM TBLB WHERE ID = 1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|blobtext'
pin     $'13 ...a binary one' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE X DD7; BEGIN SELECT BB FROM TBLB WHERE ID = 1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|bin'
pin     $'13 ...a UTF8 one' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE X DD7; BEGIN SELECT BU FROM TBLB WHERE ID = 1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|utf'
pin     $'13 ...into a CHAR(10)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R CHAR(10)) AS BEGIN SELECT BU FROM TBLB WHERE ID = 1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|utf'
pin     $'13 the text compares: IF (R = \'1,2,3\') takes THEN' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE X DD7; BEGIN SELECT LIST(ID) FROM T1 INTO R; IF (R = \'1,2,3\') THEN R = \'eq\'; ELSE R = \'ne\'; SUSPEND; END^\nSET TERM ;^' $'R|eq'
pin     $'13 ...and concatenates' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS BEGIN SELECT LIST(ID) FROM T1 INTO R; R = R || \'!\'; SUSPEND; END^\nSET TERM ;^' $'R|1,2,3!'
pin     $'13 INSERT ... RETURNING <blob> INTO: the blob the statement just stored' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE X DD7; BEGIN INSERT INTO TBLB (ID, B) VALUES (2, \'ret\') RETURNING B INTO R; SUSPEND; END^\nSET TERM ;^\nROLLBACK;' $'R|ret'
pin     $'13 FOR SELECT ... INTO' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE X DD7; BEGIN FOR SELECT B FROM TBLB ORDER BY ID INTO R DO SUSPEND; END^\nSET TERM ;^' $'R|blobtext'
pin     $'13 FETCH ... INTO' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE C CURSOR FOR (SELECT B FROM TBLB WHERE ID = 1); BEGIN OPEN C; FETCH C INTO R; SUSPEND; END^\nSET TERM ;^' $'R|blobtext'
pin     $'13 <cursor>.<column>' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE C CURSOR FOR (SELECT B FROM TBLB WHERE ID = 1); BEGIN OPEN C; FETCH C; R = C.B; SUSPEND; END^\nSET TERM ;^' $'R|blobtext'
pin     $'13 EXCEPTION <name> <the text>' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS BEGIN SELECT B FROM TBLB WHERE ID = 1 INTO R; EXCEPTION E_SIMPLE R; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = HY000|exception 1|-"PUBLIC"."E_SIMPLE"|-blobtext|-At block line: 1, col: 88'
pin     $'13 EXCEPTION ... USING (<the text>, 1)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS BEGIN SELECT B FROM TBLB WHERE ID = 1 INTO R; EXCEPTION E_PARAM USING (R, 1); END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = HY000|exception 2|-"PUBLIC"."E_PARAM"|-bad value blobtext in 1|-At block line: 1, col: 88'
pin     $'13 EXECUTE STATEMENT ... INTO' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS BEGIN EXECUTE STATEMENT \'SELECT B FROM TBLB WHERE ID = 1\' INTO R; SUSPEND; END^\nSET TERM ;^' $'R|blobtext'
pin     $'13 a text too long for the slot is 22001' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(4)) AS BEGIN SELECT B FROM TBLB WHERE ID = 1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22001|arithmetic exception, numeric overflow, or string truncation|-string right truncation|-expected length 4, actual 8|-At block line: 1, col: 47'
pin     $'13 into an INTEGER: the text\'s number' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS BEGIN SELECT LIST(ID, \'\') FROM T1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|123'
pin     $'13 a stored procedure\'s SELECT <blob> INTO' $'SELECT * FROM PBLOB;' $'R|blobtext'
pin     $'13 a stored function\'s SELECT LIST(...) INTO' $'SELECT FBLOB() FROM RDB$DATABASE;' $'FBLOB|1,2,3'
refused $'13 <cursor>.<blob column> || \'x\': refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE C CURSOR FOR (SELECT B FROM TBLB WHERE ID = 1); BEGIN OPEN C; FETCH C; R = C.B || \'x\'; SUSPEND; END^\nSET TERM ;^' $'R|blobtextx'
refused $'13 IF (<cursor>.<blob column> = ...): refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(40)) AS DECLARE C CURSOR FOR (SELECT B FROM TBLB WHERE ID = 1); BEGIN OPEN C; FETCH C; IF (C.B = \'blobtext\') THEN R = \'eq\'; SUSPEND; END^\nSET TERM ;^' $'R|eq'
refused $'13 a BLOB block output: refused' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R BLOB SUB_TYPE TEXT) AS BEGIN SELECT B FROM TBLB WHERE ID = 1 INTO R; SUSPEND; END^\nSET TERM ;^' $'R|88:0|R:|blobtext'
echo $'--- 14. A DOUBLE PAST ITS RANGE IS THE FLOATING-POINT OVERFLOW'
pin     $'14 A * A over 1e300' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 1e300; BEGIN R = A * A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.|-At block line: 1, col: 89'
pin     $'14 A + A over 1.7e308' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 1.7e308; BEGIN R = A + A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.|-At block line: 1, col: 91'
pin     $'14 a condition over it' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 1e300; BEGIN IF (A * A > 0) THEN R = 1; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.|-At block line: 1, col: 89'
pin     $'14 into a VARCHAR' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(30)) AS DECLARE A DOUBLE PRECISION = 1e300; BEGIN R = A * A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.|-At block line: 1, col: 84'
pin     $'14 A * A - A * A (no NaN)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 1e300; BEGIN R = A * A - A * A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.|-At block line: 1, col: 89'
pin     $'14 a handler reads SQLCODE -802' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 1e300; BEGIN R = 0; BEGIN R = A * A; WHEN ANY DO R = SQLCODE; END SUSPEND; END^\nSET TERM ;^' $'R|-802.0000000000000'
pin     $'14 A * I * I over a BIGINT I' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 1e300; DECLARE I BIGINT = 9223372036854775807; BEGIN R = A * I * I; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.|-At block line: 1, col: 129'
pin     $'14 CONTROL an underflow is 0' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R DOUBLE PRECISION) AS DECLARE A DOUBLE PRECISION = 1e-300; BEGIN R = A * A; SUSPEND; END^\nSET TERM ;^' $'R|0.000000000000000'
pin     $'14 a stored function\'s RETURN A * 2 over 1e308' $'SELECT FDBL(1e308) FROM RDB$DATABASE;' $'FDBL|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Floating-point overflow. The exponent of a floating-point operation is greater than the magnitude allowed.|-At function "PUBLIC"."FDBL" line: 1, col: 77'
pin     $'14 CONTROL ...over 1e307' $'SELECT FDBL(1e307) FROM RDB$DATABASE;' $'FDBL|2.000000000000000e+307'
echo $'--- 15. A PSQL VALUE\'S OWN GRAMMAR: NO AGGREGATE, CONCATENATION BINDS TIGHTEST'
pin     $'15 R = SUM(1): -104 Invalid command at prepare' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS BEGIN R = SUM(1); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 R = COUNT(*) (a typed local beside it)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS DECLARE X DD7; BEGIN R = COUNT(*); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 R = ROW_NUMBER() OVER ()' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS DECLARE X DD7; BEGIN R = ROW_NUMBER() OVER (); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 ...in a branch that never runs' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS DECLARE X DD7; BEGIN IF (1 = 0) THEN R = SUM(1); R = 2; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 R = R + SUM(R)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS BEGIN R = 1; R = R + SUM(R); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 IF (MAX(R) = 1)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS BEGIN R = 1; IF (MAX(R) = 1) THEN R = 5; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 WHILE (COUNT(*) < 0)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS BEGIN R = 1; WHILE (COUNT(*) < 0) DO R = 2; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 EXCEPTION E COUNT(*)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS BEGIN EXCEPTION E_SIMPLE COUNT(*); END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 R = LIST(\'a\')' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = LIST(\'a\'); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 R = SUM(1) OVER ()' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT) AS BEGIN R = SUM(1) OVER (); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid command'
pin     $'15 CONTROL an aggregate in a subquery of its own answers' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INT, S INT) AS BEGIN R = (SELECT SUM(ID) FROM T1); S = COALESCE((SELECT MAX(ID) FROM T1), 0) + 1; SUSPEND; END^\nSET TERM ;^' $'R S|6 4'
pin     $'15 \'1\' || 2 + 3 is (\'1\' || 2) + 3: expression evaluation not supported' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE X DD7; BEGIN R = \'1\' || 2 + 3; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...in a block with no typed local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = \'1\' || 2 + 3; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...1 + 2 || 3' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = 1 + 2 || 3; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...the text sum in a branch that never runs' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = \'x\'; IF (1 = 0) THEN R = \'1\' || 2 + 3; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...a VARCHAR local plus 1' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE S VARCHAR(5) = \'1\'; BEGIN R = S + 1; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 2 * 3 || 4 is 2 * \'34\', a DOUBLE' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = 2 * 3 || 4; SUSPEND; END^\nSET TERM ;^' $'R|68.00000000000000'
pin     $'15 ...a VARCHAR local times 2' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE S VARCHAR(5) = \'1\'; BEGIN R = S * 2; SUSPEND; END^\nSET TERM ;^' $'R|2.000000000000000'
pin     $'15 ...8 / a VARCHAR \'4\'' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE S VARCHAR(5) = \'4\'; BEGIN R = 8 / S; SUSPEND; END^\nSET TERM ;^' $'R|2.000000000000000'
pin     $'15 ...\'3x\' * 2 is the conversion error' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = \'3x\' * 2; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22018|conversion error from string "3x"|-At block line: 1, col: 48'
pin     $'15 \'v\' || A * A is (\'v\' || A) * A' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A BIGINT = 4000000000; BEGIN R = \'v\' || A * A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22018|conversion error from string "v4000000000"|-At block line: 1, col: 79'
pin     $'15 SUBSTRING(... FROM \'2\') in a block' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS BEGIN R = SUBSTRING(\'abc\' FROM \'2\'); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...beside a typed local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE X DD7; BEGIN R = SUBSTRING(\'abc\' FROM \'2\'); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...FROM a VARCHAR local' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(20)) AS DECLARE S VARCHAR(3) = \'2\'; BEGIN R = SUBSTRING(\'abc\' FROM S); SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...in a SELECT' $'SELECT SUBSTRING(\'abc\' FROM \'2\') FROM RDB$DATABASE;' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 ...FROM a text CAST' $'SELECT SUBSTRING(\'abc\' FROM CAST(NULL AS VARCHAR(3))) FROM RDB$DATABASE;' $'Statement failed, SQLSTATE = 42000|expression evaluation not supported'
pin     $'15 CONTROL the length converts: FOR \'2\'' $'SELECT SUBSTRING(\'abc\' FROM 1 FOR \'2\') FROM RDB$DATABASE;' $'SUBSTRING|ab'
echo $'--- 16. EXACT ARITHMETIC IS TYPED: BIGINT, INT128 AND THEIR OVERFLOWS'
pin     $'16 an INT128 past BIGINT, minus 1' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INT128 = 10000000000000000000000000000000000000; BEGIN R = A - 1; SUSPEND; END^\nSET TERM ;^' $'R|9999999999999999999999999999999999999'
pin     $'16 ...the INT128 maximum / 2' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE X DD7; DECLARE A INT128 = 170141183460469231731687303715884105727; BEGIN R = A / 2; SUSPEND; END^\nSET TERM ;^' $'R|85070591730234615865843651857942052863'
pin     $'16 ...A + A - 1 at 2^126: the prefixed Integer overflow' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INT128 = 85070591730234615865843651857942052864; BEGIN R = A + A - 1; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 107'
pin     $'16 ...the maximum * 2' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INT128 = 170141183460469231731687303715884105727; BEGIN R = A * 2; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 108'
pin     $'16 an INT128 1 + the BIGINT maximum is an INT128' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INT128 = 1; BEGIN R = A + 9223372036854775807; SUSPEND; END^\nSET TERM ;^' $'R|9223372036854775808'
pin     $'16 BIGINT * BIGINT is an INT128' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE X DD7; DECLARE A BIGINT = 4000000000; BEGIN R = A * A; SUSPEND; END^\nSET TERM ;^' $'R|16000000000000000000'
pin     $'16 ...a BIGINT times a literal' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS BEGIN R = 123456789012 * 1000000000; SUSPEND; END^\nSET TERM ;^' $'R|123456789012000000000'
pin     $'16 ...A * 1 + A over 5e18' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A BIGINT = 5000000000000000000; BEGIN R = A * 1 + A; SUSPEND; END^\nSET TERM ;^' $'R|10000000000000000000'
pin     $'16 BIGINT + BIGINT past the range: the bare Integer overflow' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A BIGINT = 5000000000000000000; BEGIN R = A + A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 88'
pin     $'16 the BIGINT minimum / -1 is 9223372036854775808 (the server panicked)' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A BIGINT = -9223372036854775808; BEGIN R = A / -1; SUSPEND; END^\nSET TERM ;^' $'R|9223372036854775808'
pin     $'16 the INTEGER minimum / -1' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INTEGER = -2147483648; BEGIN R = A / -1; SUSPEND; END^\nSET TERM ;^' $'R|2147483648'
pin     $'16 INTEGER cubed' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INTEGER = 2147483647; BEGIN R = A * A * A; SUSPEND; END^\nSET TERM ;^' $'R|9903520300447984150353281023'
pin     $'16 ...to the fifth: the prefixed overflow' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INTEGER = 2147483647; BEGIN R = A * A * A * A * A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 80'
pin     $'16 NUMERIC(18,2) squared' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A NUMERIC(18,2) = 4000000000.00; BEGIN R = A * A; SUSPEND; END^\nSET TERM ;^' $'R|16000000000000000000.0000'
pin     $'16 NUMERIC(18,2) + itself past the range' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A NUMERIC(18,2) = 90000000000000000.00; BEGIN R = A + A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 96'
pin     $'16 a BIGINT + a NUMERIC(18,2) rescaled past the range' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A BIGINT = 9000000000000000000; DECLARE N NUMERIC(18,2) = 1.00; BEGIN R = A + N; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|-At block line: 1, col: 120'
pin     $'16 an INT128 + a NUMERIC(38,2) rescaled past the range' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INT128 = 10000000000000000000000000000000000000; DECLARE N NUMERIC(38,2) = 1.50; BEGIN R = A + N; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|-At block line: 1, col: 139'
pin     $'16 the INT128 minimum / -1: the bare Integer overflow' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A INT128 = -170141183460469231731687303715884105728; BEGIN R = A / -1; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 109'
pin     $'16 SMALLINT to the fifth' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A SMALLINT = 30000; BEGIN R = A * A * A * A * A; SUSPEND; END^\nSET TERM ;^' $'R|24300000000000000000000'
pin     $'16 a condition over BIGINT * BIGINT' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A BIGINT = 4000000000; BEGIN IF (A * A > 9223372036854775807) THEN R = \'big\'; SUSPEND; END^\nSET TERM ;^' $'R|big'
pin     $'16 ...A * A / A' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50)) AS DECLARE A BIGINT = 4000000000; BEGIN R = A * A / A; SUSPEND; END^\nSET TERM ;^' $'R|4000000000'
pin     $'16 the INT128 product into a BIGINT: the prefixed overflow' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R BIGINT) AS DECLARE A BIGINT = 4000000000; BEGIN R = A * A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 74'
pin     $'16 an INT128 local into an INTEGER' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE A INT128 = 3000000000; BEGIN R = A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 75'
pin     $'16 ...into a SMALLINT: out of range' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R SMALLINT) AS DECLARE A INT128 = 40000; BEGIN R = A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-numeric value is out of range|-At block line: 1, col: 71'
pin     $'16 ...BIGINT * BIGINT into an INTEGER' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R INTEGER) AS DECLARE A BIGINT = 60000; BEGIN R = A * A; SUSPEND; END^\nSET TERM ;^' $'R|Statement failed, SQLSTATE = 22003|arithmetic exception, numeric overflow, or string truncation|-Integer overflow. The result of an integer operation caused the most significant bit of the result to carry.|-At block line: 1, col: 70'
pin     $'16 an INT128 local in a query and a FETCH ABSOLUTE' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (R VARCHAR(50), S VARCHAR(50)) AS DECLARE A INT128 = 5; DECLARE C SCROLL CURSOR FOR (SELECT ID FROM T1 ORDER BY ID); DECLARE K INT; BEGIN OPEN C; FETCH ABSOLUTE A - 3 FROM C INTO K; R = K; S = (SELECT :A - 3 FROM RDB$DATABASE); SUSPEND; END^\nSET TERM ;^' $'R S|2 2'
echo $'--- 17. A CONTEXT VARIABLE IS NO PARAMETER; SUSPEND NEEDS RETURNS'
pin     $'17 :SQLCODE in a handler\'s query: Token unknown at the name' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN BEGIN M = 1/0; WHEN ANY DO SELECT :SQLCODE FROM RDB$DATABASE INTO M; END SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 79|-SQLCODE'
pin     $'17 ...M = :SQLCODE' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN BEGIN M = 1/0; WHEN ANY DO M = :SQLCODE; END SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 76|-SQLCODE'
pin     $'17 ...:ROW_COUNT in a branch that never runs' $'SET TERM ^;\nEXECUTE BLOCK RETURNS (M INTEGER) AS BEGIN M = 0; IF (M = 1) THEN SELECT :ROW_COUNT FROM RDB$DATABASE INTO M; SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Token unknown - line 1, column 75|-ROW_COUNT'
pin     $'17 SUSPEND in a block with no RETURNS' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN IF (SQLCODE = 0) THEN SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-SUSPEND could not be used without RETURNS clause in PROCEDURE or EXECUTE BLOCK'
pin     $'17 ...after a BREAK' $'SET TERM ^;\nEXECUTE BLOCK AS DECLARE I INT = 0; BEGIN WHILE (I < 2) DO BEGIN I = I + 1; IF (I = 1) THEN BREAK; END SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-SUSPEND could not be used without RETURNS clause in PROCEDURE or EXECUTE BLOCK'
pin     $'17 ...a bare one' $'SET TERM ^;\nEXECUTE BLOCK AS BEGIN SUSPEND; END^\nSET TERM ;^' $'Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-SUSPEND could not be used without RETURNS clause in PROCEDURE or EXECUTE BLOCK'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-psqlgram-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 274 ]; then echo "FAIL only $ran checks ran (floor 274)"; fail=1; fi
exit $fail
