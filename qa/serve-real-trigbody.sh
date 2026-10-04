#!/bin/bash
# TRIGGERS AS APPLICATIONS WRITE THEM (found running the paper's
# samples/nodejs/psql.js against this server).
#
#   1. the SQL-2003 header `CREATE TRIGGER T [ACTIVE|INACTIVE] BEFORE
#      INSERT [OR UPDATE ..] ON TBL [POSITION n] AS ..` - refused; the
#      header now reads as the Firebird `FOR TBL` form (identical rows);
#   2. INACTIVE was parsed and then written as false: `CREATE TRIGGER ..
#      INACTIVE ..` made an ACTIVE trigger that FIRED (a wrong answer);
#   3. RECREATE TRIGGER - refused in every spelling;
#   4. a body this server's own BLR emitter cannot express - a
#      CURRENT_TIMESTAMP or COALESCE in a stored value, an INSERT without
#      a column list, a TIMESTAMP target - refused; it is compiled by the
#      DSQL compiler now (its trigger BLR is the engine's byte for byte -
#      qa/dsql-trig-blr.sh); and a context variable in a column-listed
#      store was written as a COLUMN NAME, refusing every INSERT on the
#      table once such a trigger existed.
# Recorded: such a trigger's RDB$DEBUG_INFO is empty (no source map).
#
# Every cell: one isql script on twin files, the whole output compared;
# then the ENGINE fires the triggers this server wrote, on its file.
#
#   qa/serve-real-trigbody.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4604}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/trigbody-eng.fdb"; FC="$D/trigbody-fc.fdb"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-trigbody-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
fresh() {
    rm -f "$ENG" "$FC"
    printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE AL (L TIMESTAMP, W VARCHAR(60));
CREATE TABLE E2 (ID INTEGER, NAME VARCHAR(30), N INTEGER);
CREATE TABLE TC (A INTEGER, C COMPUTED BY (A * 2), B VARCHAR(5));
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/trigbody-build.log 2>&1
    [ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/trigbody-build.log; exit 1; }
    cp "$ENG" "$FC"; chmod 666 "$FC"
}
R='RDB$'
CAT="COMMIT;
SELECT ${R}TRIGGER_NAME, ${R}TRIGGER_TYPE, ${R}TRIGGER_SEQUENCE, ${R}TRIGGER_INACTIVE, ${R}RELATION_NAME, CAST(${R}TRIGGER_SOURCE AS VARCHAR(200)) FROM ${R}TRIGGERS WHERE ${R}SYSTEM_FLAG = 0 ORDER BY 1;
SELECT ${R}DEPENDENT_NAME, ${R}DEPENDED_ON_NAME, ${R}FIELD_NAME, ${R}DEPENDENT_TYPE, ${R}DEPENDED_ON_TYPE FROM ${R}DEPENDENCIES WHERE ${R}DEPENDENT_TYPE = 2 ORDER BY 1, 2, 3;"
# the rows the triggers wrote: the timestamp is the clock's, so only
# whether it is set is compared
FIRE="DELETE FROM AL; COMMIT;
INSERT INTO E2 (ID, NAME) VALUES (1, 'q');
UPDATE E2 SET NAME = 'r' WHERE ID = 1;
INSERT INTO TC (A, B) VALUES (1, 'x');
SELECT ID, NAME, N FROM E2;
SELECT L IS NOT NULL AS HAS_L, W FROM AL ORDER BY W;
ROLLBACK;"
both() { # <label> <script>
    ran=$((ran + 1))
    fresh
    local e c
    e=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\n%s\n%s\n' "$2" "$CAT" "$FIRE" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\n%s\n%s\n' "$2" "$CAT" "$FIRE" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "${e#*TRIGGER_NAME}" = "$e" ]; then echo "FAIL $1 [the engine never read back: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
    # ...and the ENGINE fires what this server wrote
    local gf ee ef
    ran=$((ran + 1))
    gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
    ee=$(printf '%s\n' "$FIRE" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    ef=$(printf '%s\n' "$FIRE" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$FC" 2>&1 | norm)
    if [ -n "$gf" ]; then echo "FAIL $1 - gfix -v -full: $gf"; fail=1
    elif [ "$ee" != "$ef" ]; then echo "DIFF $1 - the engine firing this server's triggers"; echo "     eng file: [$ee]"; echo "     fc file:  [$ef]"; fail=1
    else echo "OK   $1 - the engine fires this server's triggers alike"; fi
}

echo "--- 1 the SQL-2003 header"
both "1 BEFORE INSERT ON, AFTER INSERT OR UPDATE ON, POSITION"  "CREATE TRIGGER T1 BEFORE INSERT ON E2 AS BEGIN NEW.N = 1; END^
CREATE TRIGGER T2 ACTIVE AFTER INSERT OR UPDATE ON E2 POSITION 5 AS BEGIN INSERT INTO AL (W) VALUES ('t2 ' || NEW.NAME); END^"
both "1 CREATE OR ALTER, a delimited table name"   "CREATE OR ALTER TRIGGER T3 BEFORE UPDATE ON \"E2\" AS BEGIN NEW.N = 3; END^"
echo "--- 2 INACTIVE is kept - and the trigger does not fire"
both "2 INACTIVE, both spellings"                   "CREATE TRIGGER T4 INACTIVE BEFORE INSERT ON E2 AS BEGIN NEW.N = 4; END^
CREATE TRIGGER T5 FOR E2 INACTIVE BEFORE INSERT POSITION 2 AS BEGIN NEW.N = 5; END^"
echo "--- 3 RECREATE TRIGGER"
both "3 RECREATE a new one and an existing one"     "RECREATE TRIGGER T6 FOR E2 BEFORE INSERT AS BEGIN NEW.N = 6; END^
RECREATE TRIGGER T6 BEFORE UPDATE ON E2 AS BEGIN NEW.N = 7; END^"
echo "--- 4 bodies the DSQL compiler carries"
both "4 the psql sample's audit trigger"            "CREATE TRIGGER T7 BEFORE INSERT ON E2 AS BEGIN INSERT INTO AL VALUES (CURRENT_TIMESTAMP, 'insert ' || COALESCE(NEW.NAME, '?')); END^"
both "4 a context variable into a listed TIMESTAMP" "CREATE TRIGGER T8 FOR E2 AFTER INSERT AS BEGIN INSERT INTO AL (L, W) VALUES (CURRENT_TIMESTAMP, 'y'); END^"
both "4 an INSERT with no list over a COMPUTED column" "CREATE TRIGGER T9 FOR E2 AFTER INSERT AS BEGIN INSERT INTO TC VALUES (NEW.ID, 'v'); END^"
both "4 COALESCE into NEW, SELECT .. INTO a variable" "CREATE TRIGGER T10 FOR E2 BEFORE INSERT AS DECLARE C INTEGER; BEGIN SELECT COUNT(*) FROM AL INTO :C; NEW.N = COALESCE(NEW.N, C + 10); END^"
both "4 FOR SELECT .. DO"                            "CREATE TRIGGER T11 FOR E2 AFTER UPDATE AS DECLARE W VARCHAR(60); BEGIN FOR SELECT NAME FROM E2 INTO :W DO INSERT INTO AL (W) VALUES ('seen ' || :W); END^"
echo "--- 6 what the engine refuses at CREATE, refused here too - and no trigger stays"
# (the engine's vectors are its compiler's -206 / -204 / -104 ones; this
# server's refusal is generic - only the refusal and the empty catalog
# are compared). The DSQL compiler asks for no name, so these were
# ACCEPTED by the first cut of the fallback: a bare variable inside a
# DML statement is a COLUMN to the engine, a table or an exception
# nobody defined is its error, and a `;` after a nested block's END is
# its Token unknown (procedures and EXECUTE BLOCK alike).
nope() { # <label> <script>
    ran=$((ran + 1))
    fresh
    local e c ec cc
    e=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\nCOMMIT;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\nCOMMIT;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    ec=$(printf '%s\n' "$CAT" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    cc=$(printf '%s\n' "$CAT" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "${e#Statement failed}" = "$e" ]; then echo "FAIL $1 - the ENGINE accepts it [$e]"; fail=1
    elif [ "${c#Statement failed}" = "$c" ]; then echo "DIFF $1 - accepted here"; echo "     fc: [$c]"; fail=1
    elif [ "$ec" != "$cc" ]; then echo "DIFF $1 - the catalogs differ"; echo "     eng: [$ec]"; echo "     fc:  [$cc]"; fail=1
    else echo "OK   $1"; fi
}
nope "6 a bare variable in VALUES (-206 Column unknown)" "CREATE TRIGGER B1 FOR E2 AFTER DELETE AS DECLARE V INTEGER; BEGIN V = OLD.ID; INSERT INTO AL (W) VALUES (V); END^"
nope "6 a bare variable in SET"                          "CREATE TRIGGER B2 FOR E2 AFTER UPDATE AS DECLARE V INTEGER; BEGIN V = 1; UPDATE TC SET A = V WHERE A = 1; END^"
nope "6 an unknown table (-204)"                         "CREATE TRIGGER B3 FOR E2 AFTER INSERT AS BEGIN DELETE FROM NOSUCH WHERE X = 1; END^"
nope "6 an unknown exception"                            "CREATE TRIGGER B4 FOR E2 BEFORE INSERT AS BEGIN EXCEPTION NOSUCH; END^"
nope "6 an unknown column of a stored table"             "CREATE TRIGGER B5 FOR E2 AFTER INSERT AS BEGIN INSERT INTO AL (NOPE) VALUES (CURRENT_TIMESTAMP); END^"
nope "6 a ; after a nested block's END (-104)"           "CREATE TRIGGER B6 FOR E2 BEFORE INSERT AS BEGIN BEGIN NEW.N = 1; END; NEW.N = 2; END^"

echo "--- 5 CONTROLS - a body the strict emitter carries is unchanged"
both "5 NEW.N = NEW.ID + 1"                          "CREATE TRIGGER T12 FOR E2 BEFORE INSERT AS BEGIN NEW.N = NEW.ID + 1; END^"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-trigbody-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 27 ]; then echo "FAIL only $ran checks ran (floor 27) - cells went missing"; fail=1; fi
exit $fail
