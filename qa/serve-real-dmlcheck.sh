#!/bin/bash
# THE SEMANTIC CHECKS A DESTRUCTIVE OR MATCHING STATEMENT MAKES BEFORE IT
# WRITES - measured on engine 2182 and matched, cell by cell.
#
#   * UPDATE OR INSERT ... MATCHING compares with blr_equiv - IS NOT
#     DISTINCT FROM - so a NULL value MATCHES a NULL column (a spelled
#     NULL, CAST(NULL ...), UPPER(NULL) and a bound NULL alike), and every
#     row the key matches is updated. This server compared with `=`: it
#     INSERTED a second row where the engine updates one - a silent wrong
#     answer - and refused a spelled NULL outright.
#   * DROP TABLE / RECREATE TABLE over a VIEW (IF EXISTS included) is the
#     missing-table -607 "Table @1 does not exist" and the view stays;
#     this server dropped the view.
#   * DROP VIEW / RECREATE VIEW of a view something reads is refused with
#     the engine's two checks (dfw.epp delete_relation): RDB$VIEW_RELATIONS
#     rows first - "cannot delete / TABLE @1 / there are N dependencies",
#     N the ROWS (a self-join counts 2), TABLE even for a view - else the
#     distinct RDB$DEPENDENCIES dependents under the relation's own kind
#     ("VIEW @1" for a procedure and a trigger reading a view). The same
#     helper now serves DROP TABLE, whose count was the distinct views
#     and ignored a trigger on another table. ALTER VIEW and CREATE OR
#     ALTER VIEW pass.
#   * CREATE VIEW without a column list needs every select item of the
#     first union branch to NAME its column (a plain column, `*`, an
#     alias): a literal, expression, call, CAST, NULL, aggregate or
#     CURRENT_DATE is -607 "must specify column name for view select
#     expression"; a column list of the wrong length is -607 "number of
#     columns does not match select list" (07002). Both fire at EXECUTE
#     (the two-phase rig, qa/ddlphase.c). This server stored the
#     describe name - CONSTANT, ADD, CAST, UPPER - as the column.
#   * COMMENT ON TABLE wants a table and COMMENT ON VIEW a view: the
#     wrong kind or a missing name is "COMMENT ON @1 failed / Table|View
#     @1 not found" - and the engine's quirk, kept: the TABLE verb prints
#     a name it cannot find BARE ("NOSUCH"), everything else qualified.
#     This server accepted TABLE over a view and refused VIEW entirely.
#   * A FOREIGN KEY across the persistent / temporary line is DYN 232 "@1
#     cannot reference @2" (HY000): a GTT of either kind -> a persistent
#     table, a persistent table -> a GTT, ON COMMIT PRESERVE ROWS -> ON
#     COMMIT DELETE ROWS; DELETE -> PRESERVE, like -> like and a
#     self-reference pass. Before it: a referenced name the catalog does
#     not hold is "Table @1 not found", a view is "attempt to reference a
#     view (@1) in a foreign key" - CREATE TABLE and ALTER TABLE ADD alike.
#
# CONTROLS from neighbouring fixes, green before this slice: ALTER TABLE
# DROP of a column a view reads, ALTER TABLE ADD ... IDENTITY over rows.
#
# RECORDED, not fixed: `DROP TABLE IF EXISTS` and `ALTER TABLE ADD <column>
# REFERENCES` do not parse here; a key moved and ROLLED BACK leaves an
# index entry that blinds the next same-statement duplicate check (a
# pre-existing silent duplicate PK, section 1c); a view
# over `SELECT *`, a union, or `(id)` refuses at prepare; a duplicate
# column name in a view (the engine's RDB$INDEX_72 violation) refuses
# generically; a DROP VIEW dependency fires at EXECUTE here where the
# engine defers it to COMMIT (the DROP TABLE convention); a refused
# CREATE / ALTER draws no INTEG_n number here where the engine's failed
# statement consumed one.
#
# Usage: qa/serve-real-dmlcheck.sh [port]   (default 5710)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5710}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dmlcheck-eng.fdb"; FC="$D/dmlcheck-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE U (ID INTEGER PRIMARY KEY, NAME VARCHAR(10), N INTEGER);
INSERT INTO U VALUES (5, NULL, NULL);
INSERT INTO U VALUES (7, 'x', NULL);
INSERT INTO U VALUES (8, NULL, 3);
CREATE TABLE UQ (ID INTEGER PRIMARY KEY, NAME VARCHAR(10));
INSERT INTO UQ VALUES (5, NULL);
CREATE TABLE T1 (ID INTEGER, N INTEGER, S VARCHAR(20));
CREATE TABLE T2 (ID INTEGER PRIMARY KEY);
CREATE TABLE T3 (ID INTEGER PRIMARY KEY);
CREATE TABLE OTHER (ID INTEGER);
CREATE TABLE TA (ID INTEGER, S VARCHAR(20), X INTEGER);
CREATE TABLE TC (ID INTEGER PRIMARY KEY);
INSERT INTO TC VALUES (10);
CREATE TABLE TE (ID INTEGER PRIMARY KEY);
CREATE TABLE TP (ID INTEGER PRIMARY KEY);
CREATE GLOBAL TEMPORARY TABLE GP (ID INTEGER PRIMARY KEY) ON COMMIT PRESERVE ROWS;
CREATE GLOBAL TEMPORARY TABLE GD (ID INTEGER PRIMARY KEY) ON COMMIT DELETE ROWS;
CREATE GLOBAL TEMPORARY TABLE G8 (A INTEGER);
CREATE TABLE PA (A INTEGER);
COMMIT;
CREATE VIEW V1 AS SELECT ID, N, S FROM T1;
CREATE VIEW VD AS SELECT ID, N FROM T1;
CREATE VIEW VDEP AS SELECT ID, N FROM VD;
CREATE VIEW VDEP2 AS SELECT ID FROM VD;
CREATE VIEW VP AS SELECT ID FROM T1;
CREATE VIEW VS AS SELECT ID FROM T2;
CREATE VIEW VSELF AS SELECT A.ID FROM VS A JOIN VS B ON A.ID = B.ID;
CREATE VIEW TSELF AS SELECT A.ID FROM T3 A JOIN T3 B ON A.ID = B.ID;
CREATE VIEW VFREE AS SELECT ID FROM T1;
CREATE VIEW VA1 AS SELECT ID, S FROM TA;
COMMIT;
SET TERM ^;
CREATE PROCEDURE PR RETURNS (S INTEGER) AS BEGIN SELECT SUM(ID) FROM VP INTO :S; SUSPEND; END^
CREATE TRIGGER TRG_O FOR OTHER BEFORE INSERT AS DECLARE X INTEGER; BEGIN SELECT SUM(ID) FROM VP INTO X; END^
SET TERM ;^
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/dmlcheck-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/dmlcheck-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/dmlcheck-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
# the two-phase rig (qa/ddlphase.c): PREPARE, EXECUTE and COMMIT each
# statement on its own and say which phase raised
RIG="$D/dmlcheck-ddlphase"
if ! cc -o "$RIG" "$(dirname "$0")/ddlphase.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "FAIL cannot build the phase rig (cc/libfbclient missing)"; exit 1
fi
command -v node >/dev/null 2>&1 || { echo "FAIL node not found (the bound-NULL cells need node-firebird)"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-dmlcheck-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC" "$RIG"' EXIT
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
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the phase rig over one statement: PREPARED|EXECUTED|COMMITTED, or the
# phase that raised and its vector
phase() { timeout 25 "$RIG" "$1" "$2" 2>&1 | tr -d '\r' | sed 's/  */ /g' | paste -sd'|'; }
# ONE statement with ONE bound value (NULL for the word NULL) through
# node-firebird, then a SELECT in the same connection; node auto-commits
nq() { # <db-path> <port> <sql> <value|NULL> <select>
    FC_DB="$1" FC_PORT="$2" FC_Q="$3" FC_V="$4" FC_S="$5" FC_U="$U" FC_P="$P" timeout 20 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      const v = process.env.FC_V === "NULL" ? null : process.env.FC_V;
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,[v],(e2)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          db.query(process.env.FC_S,(e3,r)=>{
            if(e3){console.log("ERR "+(e3.message||"").split("\n")[0]);db.detach();process.exit(0);}
            for(const row of r) console.log(Object.values(row).map(x=>x===null?"<null>":String(x).replace(/\s+$/,"")).join(" "));
            db.detach();process.exit(0);
          });
        });
      });' 2>/dev/null | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the phase rig, pinned on both sides
ppin() { # <label> <sql> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(phase "127.0.0.1/$REAL:$ENG" "$2"); fv=$(phase "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# a bound value, pinned
npin() { # <label> <sql> <value|NULL> <select> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(nq "$ENG" "$REAL" "$2" "$3" "$4"); fv=$(nq "$FC" "$PORT" "$2" "$3" "$4")
    if [ "$ev" != "$5" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$5]"; fail=1
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
# RECORDED DIVERGENCE: both sides pinned; fails when either moves
differs() { # <label> <script> <engine-output> <fc-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - THIS SERVER MOVED: [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded divergence: engine [$ev], this server [$fv])"; fi
}
pdiffers() { # <label> <sql> <engine-output> <fc-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(phase "127.0.0.1/$REAL:$ENG" "$2"); fv=$(phase "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - THIS SERVER MOVED: [$fv], not the recorded [$4]"; fail=1
    else echo "OK   $1 (recorded divergence: engine [$ev], this server [$fv])"; fi
}
UROWS='SELECT * FROM U ORDER BY ID; ROLLBACK;'
UHDR='ID NAME N'
META='Statement failed, SQLSTATE = 42000|unsuccessful metadata update'

echo "--- 1. UPDATE OR INSERT ... MATCHING IS NULL-SAFE (blr_equiv), AND UPDATES EVERY MATCHING ROW"
pin "1 a NULL key matching TWO rows given one ID: both are updated, the PK refuses" "UPDATE OR INSERT INTO U (ID, N) VALUES (9, NULL) MATCHING (N); $UROWS" "Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint \"INTEG_2\" on table \"PUBLIC\".\"U\"|-Problematic key value is (\"ID\" = 9)|$UHDR|5 <null> <null>|7 x <null>|8 <null> 3"
pin "1 a spelled NULL matches BOTH NULL-NAME rows (5 and 8): the PK refuses the second" "UPDATE OR INSERT INTO U (ID, NAME) VALUES (6, NULL) MATCHING (NAME); $UROWS" "Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint \"INTEG_2\" on table \"PUBLIC\".\"U\"|-Problematic key value is (\"ID\" = 6)|$UHDR|5 <null> <null>|7 x <null>|8 <null> 3"
pin "1 CAST(NULL AS VARCHAR) matches the same two" "UPDATE OR INSERT INTO U (ID, NAME) VALUES (6, CAST(NULL AS VARCHAR(10))) MATCHING (NAME); $UROWS" "Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint \"INTEG_2\" on table \"PUBLIC\".\"U\"|-Problematic key value is (\"ID\" = 6)|$UHDR|5 <null> <null>|7 x <null>|8 <null> 3"
pin "1 an expression NULL (UPPER(NULL)) matches (the previous binary inserted a second row here)" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (9, UPPER(NULL), 3) MATCHING (NAME, N); $UROWS" "$UHDR|5 <null> <null>|7 x <null>|9 <null> 3"
pin "1 two NULL keys match the (NULL, NULL) row" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (6, NULL, NULL) MATCHING (NAME, N); $UROWS" "$UHDR|6 <null> <null>|7 x <null>|8 <null> 3"
pin "1 (NULL, 1) matches nothing: inserted" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (6, NULL, 1) MATCHING (NAME, N); $UROWS" "$UHDR|5 <null> <null>|6 <null> 1|7 x <null>|8 <null> 3"
pin "1 ('x', NULL) matches row 7" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (9, 'x', NULL) MATCHING (NAME, N); $UROWS" "$UHDR|5 <null> <null>|8 <null> 3|9 x <null>"
pin "1 ...the MATCHING list in the other order" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (9, 'x', NULL) MATCHING (N, NAME); $UROWS" "$UHDR|5 <null> <null>|8 <null> 3|9 x <null>"
pin "1 (CAST NULL, 3) matches row 8" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (9, CAST(NULL AS VARCHAR(10)), 3) MATCHING (NAME, N); $UROWS" "$UHDR|5 <null> <null>|7 x <null>|9 <null> 3"
pin "1 a NULL key matching TWO rows updates BOTH (no singleton error)" "UPDATE OR INSERT INTO U (NAME, N) VALUES ('w', NULL) MATCHING (N); $UROWS" "$UHDR|5 w <null>|7 w <null>|8 <null> 3"
pin "1 RETURNING OLD.ID of the NULL-matched row" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (9, NULL, 3) MATCHING (NAME, N) RETURNING OLD.ID; $UROWS" "CONSTANT|8|$UHDR|5 <null> <null>|7 x <null>|9 <null> 3"
pin "1 RETURNING ID, OLD.ID, NEW.ID" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (6, NULL, NULL) MATCHING (NAME, N) RETURNING ID, OLD.ID, NEW.ID; $UROWS" "ID CONSTANT ID|6 5 6|$UHDR|6 <null> <null>|7 x <null>|8 <null> 3"
pin "1 (8, NULL) does not match row 8's (8, 3): the insert hits the PK" "UPDATE OR INSERT INTO U (ID, N) VALUES (8, NULL) MATCHING (ID, N); $UROWS" "Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint \"INTEG_2\" on table \"PUBLIC\".\"U\"|-Problematic key value is (\"ID\" = 8)|$UHDR|5 <null> <null>|7 x <null>|8 <null> 3"
pin "1 a NULL into the PK column MATCHING (ID) is the NOT NULL validation" "UPDATE OR INSERT INTO U (ID, NAME) VALUES (NULL, 'z') MATCHING (ID); $UROWS" "Statement failed, SQLSTATE = 23000|validation error for column \"PUBLIC\".\"U\".\"ID\", value \"*** null ***\"|$UHDR|5 <null> <null>|7 x <null>|8 <null> 3"
pin "1 control: a non-NULL key that matches nothing inserts" "UPDATE OR INSERT INTO U (ID, NAME) VALUES (6, 'q') MATCHING (NAME); $UROWS" "$UHDR|5 <null> <null>|6 q <null>|7 x <null>|8 <null> 3"
pin "1 control: a non-NULL key that matches updates" "UPDATE OR INSERT INTO U (ID, NAME, N) VALUES (9, 'x', 4) MATCHING (NAME); $UROWS" "$UHDR|5 <null> <null>|8 <null> 3|9 x 4"
pin "1 control: no MATCHING - the PK" "UPDATE OR INSERT INTO U (ID, NAME) VALUES (5, 'q'); $UROWS" "$UHDR|5 q <null>|7 x <null>|8 <null> 3"
pin "1 control: (9, 3) MATCHING (N, ID) matches nothing" "UPDATE OR INSERT INTO U (ID, N) VALUES (9, 3) MATCHING (N, ID); $UROWS" "$UHDR|5 <null> <null>|7 x <null>|8 <null> 3|9 <null> 3"
echo "--- 1c. RECORDED (pre-existing, found by this gate's ordering): A KEY MOVED AND ROLLED BACK LEAVES A STALE INDEX ENTRY THAT BLINDS THE NEXT DUPLICATE CHECK"
pin "1c a session moves row 7 to key 4 and rolls back" "UPDATE U SET ID = 4 WHERE ID = 7; $UROWS" "$UHDR|4 x <null>|5 <null> <null>|8 <null> 3"
differs "1c RECORDED the next session moving TWO rows to key 4 stores a duplicate PK here" "UPDATE U SET ID = 4 WHERE N IS NULL; $UROWS" "Statement failed, SQLSTATE = 23000|violation of PRIMARY or UNIQUE KEY constraint \"INTEG_2\" on table \"PUBLIC\".\"U\"|-Problematic key value is (\"ID\" = 4)|$UHDR|5 <null> <null>|7 x <null>|8 <null> 3" "$UHDR|4 <null> <null>|4 x <null>|8 <null> 3"
echo "--- 1b. THE COMMONEST FORM: A BOUND NULL (node-firebird, auto-committed on UQ)"
npin "1b ? bound NULL MATCHING (NAME) updates the NULL row" "UPDATE OR INSERT INTO UQ (ID, NAME) VALUES (6, ?) MATCHING (NAME)" "NULL" "SELECT ID, NAME FROM UQ ORDER BY ID" "6 <null>"
npin "1b ? bound 'k' matches nothing: inserted" "UPDATE OR INSERT INTO UQ (ID, NAME) VALUES (7, ?) MATCHING (NAME)" "k" "SELECT ID, NAME FROM UQ ORDER BY ID" "6 <null>|7 k"
npin "1b ? bound NULL again: the one NULL row is updated to 8" "UPDATE OR INSERT INTO UQ (ID, NAME) VALUES (8, ?) MATCHING (NAME)" "NULL" "SELECT ID, NAME FROM UQ ORDER BY ID" "7 k|8 <null>"

echo "--- 2. DROP TABLE OVER A VIEW IS THE MISSING-TABLE -607, AND THE VIEW STAYS"
NOTBL='|-SQL error code = -607|-Invalid command|-Table "PUBLIC"."V1" does not exist'
pin "2 DROP TABLE V1 (a view)" "DROP TABLE V1;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-DROP TABLE \"PUBLIC\".\"V1\" failed$NOTBL"
pin "2 RECREATE TABLE V1 (a view)" "RECREATE TABLE V1 (ID INTEGER);" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-RECREATE TABLE \"PUBLIC\".\"V1\" failed$NOTBL"
refused "2 RECORDED DROP TABLE IF EXISTS V1 (the engine refuses it too; IF EXISTS does not parse here)" "DROP TABLE IF EXISTS V1;" "Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-DROP TABLE \"PUBLIC\".\"V1\" failed$NOTBL"
pin "2 control: DROP VIEW over a table" "DROP VIEW T1;" 'Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-DROP VIEW "PUBLIC"."T1" failed|-SQL error code = -607|-Invalid command|-View "PUBLIC"."T1" does not exist'
pin "2 control: DROP TABLE of a lower-case name that is not there" "DROP TABLE \"v1\";" 'Statement failed, SQLSTATE = 42S02|unsuccessful metadata update|-DROP TABLE "PUBLIC"."v1" failed|-SQL error code = -607|-Invalid command|-Table "PUBLIC"."v1" does not exist'
pin "2 the view and the table are still there" "SELECT COUNT(*) FROM V1; SELECT COUNT(*) FROM T1;" "COUNT|0|COUNT|0"
ppin "2 phase: DROP TABLE V1 prepares, fails at EXECUTE" "DROP TABLE V1" 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |DROP TABLE "PUBLIC"."V1" failed |SQL error code = -607 |Invalid command |Table "PUBLIC"."V1" does not exist'
ppin "2 phase: RECREATE TABLE V1 too" "RECREATE TABLE V1 (ID INTEGER)" 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |RECREATE TABLE "PUBLIC"."V1" failed |SQL error code = -607 |Invalid command |Table "PUBLIC"."V1" does not exist'

echo "--- 3. DROP VIEW / RECREATE VIEW UNDER DEPENDENTS: THE ROWS OF RDB\$VIEW_RELATIONS, ELSE THE DISTINCT DEPENDENTS"
DEP='|-cannot delete|-'
pin "3 two dependent views: cannot delete / TABLE / 2" "DROP VIEW VD;" "$META$DEP""TABLE \"PUBLIC\".\"VD\"|-there are 2 dependencies"
pin "3 RECREATE VIEW meets the same wall" "RECREATE VIEW VD AS SELECT ID, N FROM T1;" "$META$DEP""TABLE \"PUBLIC\".\"VD\"|-there are 2 dependencies"
pin "3 a self-joining dependent view counts its TWO contexts" "DROP VIEW VS;" "$META$DEP""TABLE \"PUBLIC\".\"VS\"|-there are 2 dependencies"
pin "3 DROP TABLE under a self-joining view counts 2 as well (was 1)" "DROP TABLE T3;" "$META$DEP""TABLE \"PUBLIC\".\"T3\"|-there are 2 dependencies"
pin "3 a procedure and a trigger reading a view: VIEW / 2" "DROP VIEW VP;" "$META$DEP""VIEW \"PUBLIC\".\"VP\"|-there are 2 dependencies"
pin "3 RECREATE VIEW under them" "RECREATE VIEW VP AS SELECT ID FROM T1;" "$META$DEP""VIEW \"PUBLIC\".\"VP\"|-there are 2 dependencies"
pin "3 ALTER VIEW of a view with dependents passes" "ALTER VIEW VD AS SELECT ID, N FROM T1; COMMIT; SELECT COUNT(*) FROM VDEP;" "COUNT|0"
pin "3 drop the procedure: the trigger alone is VIEW / 1" "DROP PROCEDURE PR; COMMIT; DROP VIEW VP;" "$META$DEP""VIEW \"PUBLIC\".\"VP\"|-there are 1 dependencies"
pin "3 drop the trigger: the view drops" "DROP TRIGGER TRG_O; COMMIT; DROP VIEW VP; COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'VP';" "COUNT|0"
pin "3 one dependent view dropped: TABLE / 1" "DROP VIEW VDEP2; COMMIT; DROP VIEW VD;" "$META$DEP""TABLE \"PUBLIC\".\"VD\"|-there are 1 dependencies"
pin "3 both dropped: the view drops" "DROP VIEW VDEP; COMMIT; DROP VIEW VD; COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME IN ('VD', 'VDEP', 'VDEP2');" "COUNT|0"
pin "3 control: a free view drops" "DROP VIEW VFREE; COMMIT; SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'VFREE';" "COUNT|0"
pin "3 the base tables are untouched" "SELECT COUNT(*) FROM T1; SELECT COUNT(*) FROM T2; SELECT COUNT(*) FROM T3;" "COUNT|0|COUNT|0|COUNT|0"
pdiffers "3 RECORDED phase: the engine defers the dependency check to COMMIT, this server raises at EXECUTE" "DROP VIEW VS" 'PREPARED|EXECUTED|COMMIT ERR: |unsuccessful metadata update |cannot delete |TABLE "PUBLIC"."VS" |there are 2 dependencies' 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |cannot delete |TABLE "PUBLIC"."VS" |there are 2 dependencies'

echo "--- 4. CONTROLS: ALTER TABLE DROP OF A VIEW'S COLUMN, ADD IDENTITY OVER ROWS"
pin "4 a column a view reads cannot be dropped" "ALTER TABLE TA DROP S;" "$META|-ALTER TABLE \"PUBLIC\".\"TA\" failed|-Column \"S\" from table \"PUBLIC\".\"TA\" is referenced in view \"PUBLIC\".\"VA1\""
pin "4 ...the view still answers" "SELECT * FROM VA1;" ""
pin "4 a column no view reads drops" "ALTER TABLE TA DROP X; COMMIT; SELECT COUNT(*) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TA';" "COUNT|2"
pin "4 ADD ... IDENTITY over a row is the NOT NULL refusal" "ALTER TABLE TC ADD IDENT INTEGER GENERATED BY DEFAULT AS IDENTITY; COMMIT; SELECT * FROM TC;" "Statement failed, SQLSTATE = 22006|unsuccessful metadata update|-Cannot make field \"IDENT\" of table \"PUBLIC\".\"TC\" NOT NULL because there are NULLs present|ID|10"
pin "4 ...over an empty table it lands" "ALTER TABLE TE ADD IDENT INTEGER GENERATED BY DEFAULT AS IDENTITY; COMMIT; SELECT COUNT(*) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'TE';" "COUNT|2"

echo "--- 5. CREATE VIEW: A SELECT ITEM MUST NAME ITS COLUMN; A COLUMN LIST MUST FIT"
cv() { echo "$META|-CREATE VIEW \"PUBLIC\".\"$1\" failed|-SQL error code = -607|-Invalid command|-must specify column name for view select expression"; }
pin "5 a literal" "CREATE VIEW VB AS SELECT 1 FROM T1;" "$(cv VB)"
pin "5 a string literal" "CREATE VIEW VB AS SELECT 'x' FROM T1;" "$(cv VB)"
pin "5 an arithmetic expression" "CREATE VIEW VB AS SELECT ID + 1 FROM T1;" "$(cv VB)"
pin "5 an aggregate" "CREATE VIEW VB AS SELECT COUNT(*) FROM T1;" "$(cv VB)"
pin "5 a column beside a literal" "CREATE VIEW VB AS SELECT ID, 1 FROM T1;" "$(cv VB)"
pin "5 a CAST" "CREATE VIEW VB AS SELECT CAST(ID AS VARCHAR(5)) FROM T1;" "$(cv VB)"
pin "5 a unary minus" "CREATE VIEW VB AS SELECT -ID FROM T1;" "$(cv VB)"
pin "5 NULL" "CREATE VIEW VB AS SELECT NULL FROM T1;" "$(cv VB)"
pin "5 CURRENT_DATE (reads like a name, is an expression)" "CREATE VIEW VB AS SELECT CURRENT_DATE FROM T1;" "$(cv VB)"
pin "5 a call" "CREATE VIEW VB AS SELECT UPPER(S) FROM T1;" "$(cv VB)"
pin "5 nothing was written" "SELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'VB';" "COUNT|0"
pin "5 a column list of the wrong length: 07002" "CREATE VIEW VB (A, B) AS SELECT ID FROM T1;" "Statement failed, SQLSTATE = 07002|unsuccessful metadata update|-CREATE VIEW \"PUBLIC\".\"VB\" failed|-SQL error code = -607|-Invalid command|-number of columns does not match select list"
pin "5 ...too short as well" "CREATE VIEW VB (A) AS SELECT ID, S FROM T1;" "Statement failed, SQLSTATE = 07002|unsuccessful metadata update|-CREATE VIEW \"PUBLIC\".\"VB\" failed|-SQL error code = -607|-Invalid command|-number of columns does not match select list"
pin "5 RECREATE VIEW carries its own verb" "RECREATE VIEW VB AS SELECT 1 FROM T1;" "$META|-RECREATE VIEW \"PUBLIC\".\"VB\" failed|-SQL error code = -607|-Invalid command|-must specify column name for view select expression"
pin "5 ALTER VIEW of a real view: the old definition stays" "ALTER VIEW V1 AS SELECT 1 FROM T1; COMMIT; SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'V1' ORDER BY RDB\$FIELD_POSITION;" "$META|-ALTER VIEW \"PUBLIC\".\"V1\" failed|-SQL error code = -607|-Invalid command|-must specify column name for view select expression|RDB\$FIELD_NAME|ID|N|S"
ppin "5 phase: the refusal is EXECUTE's" "CREATE VIEW VB AS SELECT 1 FROM T1" 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE VIEW "PUBLIC"."VB" failed |SQL error code = -607 |Invalid command |must specify column name for view select expression'
ppin "5 phase: the count mismatch too" "CREATE VIEW VB (A, B) AS SELECT ID FROM T1" 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE VIEW "PUBLIC"."VB" failed |SQL error code = -607 |Invalid command |number of columns does not match select list'
VF='SELECT RDB$FIELD_NAME FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = '
pin "5 a column list names a literal" "CREATE VIEW VE (C) AS SELECT 1 FROM T1; COMMIT; $VF'VE';" "RDB\$FIELD_NAME|C"
pin "5 AS names it" "CREATE VIEW VF AS SELECT 1 AS C FROM T1; COMMIT; $VF'VF';" "RDB\$FIELD_NAME|C"
pin "5 a bare alias names it" "CREATE VIEW VG AS SELECT 1 C FROM T1; COMMIT; $VF'VG';" "RDB\$FIELD_NAME|C"
pin "5 a qualified column" "CREATE VIEW VM AS SELECT T1.ID FROM T1; COMMIT; $VF'VM';" "RDB\$FIELD_NAME|ID"
pin "5 an aliased-table column" "CREATE VIEW VU AS SELECT X.ID FROM T1 X; COMMIT; $VF'VU';" "RDB\$FIELD_NAME|ID"
pin "5 a WHERE changes nothing" "CREATE VIEW VW AS SELECT ID FROM T1 WHERE 1 = 1; COMMIT; $VF'VW';" "RDB\$FIELD_NAME|ID"
pin "5 columns, an alias and a column" "CREATE VIEW VV AS SELECT ID, 2 AS TWO, S FROM T1; COMMIT; $VF'VV' ORDER BY RDB\$FIELD_POSITION;" "RDB\$FIELD_NAME|ID|TWO|S"
pin "5 a list over a column and a literal" "CREATE VIEW VX (A, B) AS SELECT ID, 1 FROM T1; COMMIT; $VF'VX' ORDER BY RDB\$FIELD_POSITION;" "RDB\$FIELD_NAME|A|B"
refused "5 RECORDED a parenthesised column is a column to the engine" "CREATE VIEW VL AS SELECT (ID) FROM T1; COMMIT; $VF'VL';" "RDB\$FIELD_NAME|ID"
refused "5 RECORDED SELECT *" "CREATE VIEW VST AS SELECT * FROM T1; COMMIT; $VF'VST' ORDER BY RDB\$FIELD_POSITION;" "RDB\$FIELD_NAME|ID|N|S"
refused "5 RECORDED a union names by its first branch" "CREATE VIEW VZ AS SELECT ID FROM T1 UNION SELECT 1 FROM T1; COMMIT; $VF'VZ';" "RDB\$FIELD_NAME|ID"
pin "5 a union whose first branch does not name" "CREATE VIEW VZ2 AS SELECT 1 FROM T1 UNION SELECT ID FROM T1;" "$(cv VZ2)"
refused "5 RECORDED a duplicate column name is the catalog's unique-key violation" "CREATE VIEW VJ AS SELECT ID, ID FROM T1;" "Statement failed, SQLSTATE = 23000|unsuccessful metadata update|-CREATE VIEW \"PUBLIC\".\"VJ\" failed|-violation of PRIMARY or UNIQUE KEY constraint \"RDB\$INDEX_72\" on table \"SYSTEM\".\"RDB\$RELATION_FIELDS\"|-Problematic key value is (\"RDB\$FIELD_NAME\" = 'ID', \"RDB\$SCHEMA_NAME\" = 'PUBLIC', \"RDB\$PACKAGE_NAME\" = NULL, \"RDB\$RELATION_NAME\" = 'VJ')"

echo "--- 6. COMMENT ON TABLE WANTS A TABLE, COMMENT ON VIEW A VIEW"
pin "6 COMMENT ON VIEW over a view" "COMMENT ON VIEW V1 IS 'view'; COMMIT; SELECT CAST(RDB\$DESCRIPTION AS VARCHAR(20)) AS D FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'V1';" "D|view"
pin "6 COMMENT ON TABLE over a view: Table not found, qualified" "COMMENT ON TABLE V1 IS 'as table';" "$META|-COMMENT ON \"PUBLIC\".\"V1\" failed|-Table \"PUBLIC\".\"V1\" not found"
pin "6 COMMENT ON VIEW over a table: View not found" "COMMENT ON VIEW T1 IS 'as view';" "$META|-COMMENT ON \"PUBLIC\".\"T1\" failed|-View \"PUBLIC\".\"T1\" not found"
pin "6 COMMENT ON TABLE over a table" "COMMENT ON TABLE T1 IS 'table'; COMMIT; SELECT CAST(RDB\$DESCRIPTION AS VARCHAR(20)) AS D FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T1';" "D|table"
pin "6 COMMENT ON VIEW of a missing name: qualified" "COMMENT ON VIEW NOSUCH IS 'x';" "$META|-COMMENT ON \"PUBLIC\".\"NOSUCH\" failed|-View \"PUBLIC\".\"NOSUCH\" not found"
pin "6 COMMENT ON TABLE of a missing name: BARE (the engine's quirk)" "COMMENT ON TABLE NOSUCH IS 'x';" "$META|-COMMENT ON \"NOSUCH\" failed|-Table \"NOSUCH\" not found"
pin "6 ...a quoted lower-case miss, both verbs" "COMMENT ON VIEW \"v1\" IS 'l'; COMMENT ON TABLE \"t1\" IS 'l';" "$META|-COMMENT ON \"PUBLIC\".\"v1\" failed|-View \"PUBLIC\".\"v1\" not found|$META|-COMMENT ON \"t1\" failed|-Table \"t1\" not found"
pin "6 a view's column takes a comment" "COMMENT ON COLUMN V1.ID IS 'vcol'; COMMIT; SELECT CAST(RDB\$DESCRIPTION AS VARCHAR(20)) AS D FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'V1' AND RDB\$FIELD_NAME = 'ID';" "D|vcol"
pin "6 COMMENT ON VIEW ... IS NULL clears it" "COMMENT ON VIEW V1 IS NULL; COMMIT; SELECT CAST(RDB\$DESCRIPTION AS VARCHAR(20)) AS D FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'V1';" "D|<null>"
pin "6 the table's comment is what the TABLE verb set" "SELECT CAST(RDB\$DESCRIPTION AS VARCHAR(20)) AS D FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T1';" "D|table"
ppin "6 phase: COMMENT ON TABLE over a view fails at EXECUTE" "COMMENT ON TABLE V1 IS 'x'" 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |COMMENT ON "PUBLIC"."V1" failed |Table "PUBLIC"."V1" not found'

echo "--- 7. A FOREIGN KEY ACROSS THE PERSISTENT / TEMPORARY LINE"
gttp() { echo "Statement failed, SQLSTATE = HY000|unsuccessful metadata update|-CREATE TABLE \"PUBLIC\".\"$1\" failed|-$2"; }
pin "7 a DELETE ROWS GTT -> a persistent table" "CREATE GLOBAL TEMPORARY TABLE G1 (A INTEGER REFERENCES TP(ID));" "$(gttp G1 'global temporary table "PUBLIC"."G1" of type ON COMMIT DELETE ROWS cannot reference persistent table "PUBLIC"."TP"')"
pin "7 a PRESERVE ROWS GTT -> a persistent table" "CREATE GLOBAL TEMPORARY TABLE G2 (A INTEGER REFERENCES TP(ID)) ON COMMIT PRESERVE ROWS;" "$(gttp G2 'global temporary table "PUBLIC"."G2" of type ON COMMIT PRESERVE ROWS cannot reference persistent table "PUBLIC"."TP"')"
pin "7 PRESERVE ROWS -> DELETE ROWS" "CREATE GLOBAL TEMPORARY TABLE G3 (A INTEGER REFERENCES GD(ID)) ON COMMIT PRESERVE ROWS;" "$(gttp G3 'global temporary table "PUBLIC"."G3" of type ON COMMIT PRESERVE ROWS cannot reference global temporary table "PUBLIC"."GD" of type ON COMMIT DELETE ROWS')"
pin "7 a persistent table -> a PRESERVE ROWS GTT" "CREATE TABLE PT (A INTEGER REFERENCES GP(ID));" "$(gttp PT 'persistent table "PUBLIC"."PT" cannot reference global temporary table "PUBLIC"."GP" of type ON COMMIT PRESERVE ROWS')"
pin "7 a persistent table -> a DELETE ROWS GTT" "CREATE TABLE PT2 (A INTEGER REFERENCES GD(ID));" "$(gttp PT2 'persistent table "PUBLIC"."PT2" cannot reference global temporary table "PUBLIC"."GD" of type ON COMMIT DELETE ROWS')"
pin "7 the table-level constraint form" "CREATE GLOBAL TEMPORARY TABLE G7 (A INTEGER, CONSTRAINT FK7 FOREIGN KEY (A) REFERENCES TP(ID));" "$(gttp G7 'global temporary table "PUBLIC"."G7" of type ON COMMIT DELETE ROWS cannot reference persistent table "PUBLIC"."TP"')"
pin "7 ALTER TABLE ADD CONSTRAINT on a GTT" "ALTER TABLE G8 ADD CONSTRAINT FK8 FOREIGN KEY (A) REFERENCES TP(ID);" "Statement failed, SQLSTATE = HY000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"G8\" failed|-global temporary table \"PUBLIC\".\"G8\" of type ON COMMIT DELETE ROWS cannot reference persistent table \"PUBLIC\".\"TP\""
refused "7 RECORDED ALTER TABLE ADD <column> REFERENCES (the inline form does not plan here) on a GTT" "ALTER TABLE G8 ADD B INTEGER REFERENCES TP(ID);" "Statement failed, SQLSTATE = HY000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"G8\" failed|-global temporary table \"PUBLIC\".\"G8\" of type ON COMMIT DELETE ROWS cannot reference persistent table \"PUBLIC\".\"TP\""
pin "7 ALTER TABLE ADD on a persistent table -> a GTT" "ALTER TABLE PA ADD CONSTRAINT FKPA FOREIGN KEY (A) REFERENCES GD(ID);" "Statement failed, SQLSTATE = HY000|unsuccessful metadata update|-ALTER TABLE \"PUBLIC\".\"PA\" failed|-persistent table \"PUBLIC\".\"PA\" cannot reference global temporary table \"PUBLIC\".\"GD\" of type ON COMMIT DELETE ROWS"
pin "7 DELETE ROWS -> PRESERVE ROWS passes" "CREATE GLOBAL TEMPORARY TABLE G4 (A INTEGER REFERENCES GP(ID)) ON COMMIT DELETE ROWS; COMMIT; SELECT RDB\$RELATION_TYPE FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'G4';" "RDB\$RELATION_TYPE|5"
pin "7 DELETE ROWS -> DELETE ROWS passes" "CREATE GLOBAL TEMPORARY TABLE G5 (A INTEGER REFERENCES GD(ID)) ON COMMIT DELETE ROWS; COMMIT; SELECT RDB\$RELATION_TYPE FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'G5';" "RDB\$RELATION_TYPE|5"
pin "7 PRESERVE ROWS -> PRESERVE ROWS passes" "CREATE GLOBAL TEMPORARY TABLE G6 (A INTEGER REFERENCES GP(ID)) ON COMMIT PRESERVE ROWS; COMMIT; SELECT RDB\$RELATION_TYPE FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'G6';" "RDB\$RELATION_TYPE|4"
pin "7 a GTT referencing itself passes" "CREATE GLOBAL TEMPORARY TABLE G11 (ID INTEGER PRIMARY KEY, A INTEGER REFERENCES G11(ID)); COMMIT; SELECT RDB\$RELATION_TYPE FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'G11';" "RDB\$RELATION_TYPE|5"
pin "7 ALTER TABLE ADD on a GTT -> a PRESERVE ROWS GTT passes" "ALTER TABLE G8 ADD CONSTRAINT FK8B FOREIGN KEY (A) REFERENCES GP(ID); COMMIT; SELECT RDB\$CONSTRAINT_NAME FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME = 'G8';" "RDB\$CONSTRAINT_NAME|FK8B"
pin "7 nothing refused was written" "SELECT RDB\$RELATION_NAME FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME IN ('G1','G2','G3','G7','PT','PT2') ORDER BY 1;" ""
pin "7 ...and no constraint of theirs" "SELECT RDB\$CONSTRAINT_NAME FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME IN ('G1','G2','G3','G7','G8','PA','PT','PT2') ORDER BY 1;" "RDB\$CONSTRAINT_NAME|FK8B"
ppin "7 phase: EXECUTE" "CREATE GLOBAL TEMPORARY TABLE G1 (A INTEGER REFERENCES TP(ID))" 'PREPARED|EXECUTE ERR: |unsuccessful metadata update |CREATE TABLE "PUBLIC"."G1" failed |global temporary table "PUBLIC"."G1" of type ON COMMIT DELETE ROWS cannot reference persistent table "PUBLIC"."TP"'
echo "--- 7b. BEFORE THE SCOPE: THE REFERENCED NAME MUST BE A TABLE THE CATALOG HOLDS"
pin "7b CREATE TABLE referencing a missing table" "CREATE GLOBAL TEMPORARY TABLE G10 (A INTEGER REFERENCES NOSUCH(ID));" "$META|-CREATE TABLE \"PUBLIC\".\"G10\" failed|-Table \"PUBLIC\".\"NOSUCH\" not found"
pin "7b ...a quoted lower-case miss" "CREATE TABLE P9 (A INTEGER REFERENCES \"tp\"(ID));" "$META|-CREATE TABLE \"PUBLIC\".\"P9\" failed|-Table \"PUBLIC\".\"tp\" not found"
pin "7b ALTER TABLE ADD referencing a missing table" "ALTER TABLE PA ADD CONSTRAINT FK9 FOREIGN KEY (A) REFERENCES NOSUCH(ID);" "$META|-ALTER TABLE \"PUBLIC\".\"PA\" failed|-Table \"PUBLIC\".\"NOSUCH\" not found"
pin "7b a foreign key to a VIEW" "CREATE TABLE PV (A INTEGER REFERENCES V1(ID));" "$META|-CREATE TABLE \"PUBLIC\".\"PV\" failed|-attempt to reference a view (\"PUBLIC\".\"V1\") in a foreign key"
refused "7b RECORDED ...through ALTER TABLE ADD <column> REFERENCES (the inline form)" "ALTER TABLE PA ADD B INTEGER REFERENCES V1(ID);" "$META|-ALTER TABLE \"PUBLIC\".\"PA\" failed|-attempt to reference a view (\"PUBLIC\".\"V1\") in a foreign key"
pin "7b a GTT whose key column is not a key: the partner check comes first" "CREATE GLOBAL TEMPORARY TABLE GU (A INTEGER REFERENCES T2(ID), B INTEGER REFERENCES TP(ID));" "$(gttp GU 'global temporary table "PUBLIC"."GU" of type ON COMMIT DELETE ROWS cannot reference persistent table "PUBLIC"."T2"')"
differs "7b RECORDED a refused statement draws no INTEG_n here (the engine's did)" "CREATE TABLE PN (A INTEGER, UNIQUE (A)); COMMIT; SELECT RDB\$CONSTRAINT_NAME FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME = 'PN';" "RDB\$CONSTRAINT_NAME|INTEG_37" "RDB\$CONSTRAINT_NAME|INTEG_25"

ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-dmlcheck-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
else echo "OK   no panic"; fi
echo "ran $ran checks"
if [ "$ran" -lt 116 ]; then echo "FAIL only $ran checks ran (floor 116)"; fail=1; fi
exit $fail
