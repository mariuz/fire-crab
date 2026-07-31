#!/bin/bash
# ALTER TABLE ADD [CONSTRAINT n] PRIMARY KEY|UNIQUE on an EXISTING,
# populated table - plus a FOREIGN KEY that references a UNIQUE key
# rather than the primary key.
#
# Probed engine rules this gate pins:
#   * ALTER ... ADD PRIMARY KEY REFUSES a column that is not ALREADY
#     NOT NULL ("Column: X not defined as NOT NULL - cannot be used in
#     PRIMARY KEY constraint definition") - it does not silently make
#     the column not-null;
#   * the constraint's index is built over the rows already in the
#     table, so DUPLICATE data fails the statement;
#   * REFERENCES T (col) picks the PRIMARY KEY or UNIQUE constraint
#     whose index carries exactly those columns: the FK's
#     RDB$REF_CONSTRAINTS row then names the UNIQUE constraint and its
#     index is the partner.
#
# The differential is the engine, three ways: fire-crab and the engine
# build the schema the SAME way (create, insert, THEN alter), the
# catalogs are compared row for row, the engine enforces the new
# constraints on fire-crab's raw file, and gbak restores into a
# database that enforces them too and is gfix-clean.
#
#   qa/serve-real-keyalter.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4121}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-keyalter-work.fdb"; REF="$D/fc-keyalter-ref.fdb"
FBK="$D/fc-keyalter-work.fbk"; RST="$D/fc-keyalter-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# the schema both sides build, in this order: tables, rows, THEN the
# constraints - so the differential covers the ALTER path, not just the
# end state a CREATE TABLE could also have produced
DDL_A1="CREATE TABLE A1 (X INTEGER NOT NULL, Y INTEGER, Z VARCHAR(10))"
DDL_A2="CREATE TABLE A2 (K INTEGER NOT NULL, L INTEGER NOT NULL, M INTEGER)"
# A3 starts nullable: the PRIMARY KEY only becomes addable after SET NOT
# NULL - the pair proves the refusal below is exactly the NOT NULL rule
DDL_A3="CREATE TABLE A3 (N INTEGER, V VARCHAR(5))"
# A4 is the refusal probe, left constraint-free on both sides
DDL_A4="CREATE TABLE A4 (N INTEGER)"
INS_A3="INSERT INTO A3 VALUES (7, 'g')"
ALT_A3_NN="ALTER TABLE A3 ALTER N SET NOT NULL"
ALT_A3_PK="ALTER TABLE A3 ADD CONSTRAINT PK_A3 PRIMARY KEY (N)"
ALT_A4_PK="ALTER TABLE A4 ADD PRIMARY KEY (N)"
INS_A1_1="INSERT INTO A1 VALUES (1, 10, 'a')"
INS_A1_2="INSERT INTO A1 VALUES (2, 20, 'b')"
INS_A2_1="INSERT INTO A2 VALUES (1, 100, 5)"
INS_A2_2="INSERT INTO A2 VALUES (1, 200, 6)"
ALT_PK="ALTER TABLE A1 ADD CONSTRAINT PK_A1 PRIMARY KEY (X)"
ALT_UQ="ALTER TABLE A1 ADD UNIQUE (Y)"
ALT_PK2="ALTER TABLE A2 ADD PRIMARY KEY (K, L)"
# a foreign key onto the UNIQUE key of A1 (A1's PK is X, not Y)
DDL_B1="CREATE TABLE B1 (ID INTEGER NOT NULL PRIMARY KEY, FY INTEGER, CONSTRAINT FK_B1 FOREIGN KEY (FY) REFERENCES A1 (Y))"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_A1;
$DDL_A2;
$DDL_A3;
$DDL_A4;
COMMIT;
$INS_A1_1;
$INS_A1_2;
$INS_A2_1;
$INS_A2_2;
$INS_A3;
COMMIT;
$ALT_PK;
$ALT_UQ;
$ALT_PK2;
$ALT_A3_NN;
$ALT_A3_PK;
COMMIT;
$DDL_B1;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-keyalter.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          console.log(e2?("ERR "+(e2.message||"").split("\n")[0]):"OK");
          db.detach();process.exit(0);});
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

# --- fire-crab builds the same schema in the same order ---
check "create A1"                  "$(node_run "$DDL_A1")" "OK"
check "create A2"                  "$(node_run "$DDL_A2")" "OK"
check "create A3 (nullable N)"     "$(node_run "$DDL_A3")" "OK"
check "create A4 (refusal probe)"  "$(node_run "$DDL_A4")" "OK"
check "insert A1 rows"             "$(node_run "$INS_A1_1")" "OK"
check "insert A1 rows (2)"         "$(node_run "$INS_A1_2")" "OK"
check "insert A2 rows"             "$(node_run "$INS_A2_1")" "OK"
check "insert A2 rows (2)"         "$(node_run "$INS_A2_2")" "OK"
check "insert A3 row"              "$(node_run "$INS_A3")" "OK"
check "ALTER ADD named PRIMARY KEY" "$(node_run "$ALT_PK")" "OK"
check "ALTER ADD unnamed UNIQUE"    "$(node_run "$ALT_UQ")" "OK"
check "ALTER ADD compound PK"       "$(node_run "$ALT_PK2")" "OK"

# --- the engine's own refusals, reproduced. fire-crab answers every
# failed statement with the generic isc_dsql_error, so the client sees
# no reason text: the differential runs the SAME statement against the
# engine and requires BOTH to refuse, and then proves WHICH rule
# refused by making the statement succeed once the rule is satisfied.
nn_fc=$(node_run "$ALT_A4_PK")
nn_eng=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL
$ALT_A4_PK;
SQL
)
case "$nn_fc" in
    ERR*) echo "OK   fire-crab refuses a PRIMARY KEY over a nullable column" ;;
    *) echo "DIFF nullable-column PK not refused"; echo "     $nn_fc"; fail=1 ;;
esac
case "$nn_eng" in
    *"not defined as NOT NULL"*) echo "OK   the engine refuses it too (same statement, same table)" ;;
    *) echo "DIFF engine did not refuse the nullable-column PK"; echo "     $nn_eng"; fail=1 ;;
esac
# ... and the same statement succeeds once the column IS not-null
check "ALTER N SET NOT NULL"        "$(node_run "$ALT_A3_NN")" "OK"
check "then ADD PRIMARY KEY (N)"    "$(node_run "$ALT_A3_PK")" "OK"
check "FK REFERENCES a UNIQUE key"  "$(node_run "$DDL_B1")" "OK"
# 2. a second PRIMARY KEY
two=$(node_run "ALTER TABLE A1 ADD PRIMARY KEY (X)")
case "$two" in
    ERR*) echo "OK   a second PRIMARY KEY refused" ;;
    *) echo "DIFF second primary key accepted"; echo "     $two"; fail=1 ;;
esac
# 3. a UNIQUE over data that already holds duplicates
check "insert a duplicate M value"  "$(node_run "INSERT INTO A2 VALUES (2, 100, 5)")" "OK"
dupq=$(node_run "ALTER TABLE A2 ADD CONSTRAINT UQ_BAD UNIQUE (M)")
case "$dupq" in
    ERR*) echo "OK   UNIQUE over duplicate data refused" ;;
    *) echo "DIFF unique over duplicates accepted"; echo "     $dupq"; fail=1 ;;
esac
# and the constraints that DID land are live in fire-crab itself
dup=$(node_run "INSERT INTO A1 VALUES (1, 30, 'c')")
case "$dup" in
    ERR*) echo "OK   fire-crab enforces the ALTER-added PRIMARY KEY" ;;
    *) echo "DIFF altered-in PK not enforced"; echo "     $dup"; fail=1 ;;
esac
dupu=$(node_run "INSERT INTO A1 VALUES (3, 10, 'd')")
case "$dupu" in
    ERR*) echo "OK   fire-crab enforces the ALTER-added UNIQUE" ;;
    *) echo "DIFF altered-in UNIQUE not enforced"; echo "     $dupu"; fail=1 ;;
esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the catalog the engine reads from fc == the engine reference ---
TBLS="'A1','A2','A3','A4','B1'"
catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^\$'
SET HEADING OFF;
SELECT 'RC|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONSTRAINT_TYPE)
       ||'|'||COALESCE(TRIM(RDB\$INDEX_NAME),'-')
  FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$CONSTRAINT_NAME;
SELECT 'IDX|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$INDEX_NAME)||'|'||COALESCE(RDB\$UNIQUE_FLAG,-1)
       ||'|'||RDB\$SEGMENT_COUNT||'|'||COALESCE(TRIM(RDB\$FOREIGN_KEY),'-')
       ||'|'||COALESCE(TRIM(RDB\$FOREIGN_KEY_SCHEMA_NAME),'-')
  FROM RDB\$INDICES WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$INDEX_ID;
SELECT 'SEG|'||TRIM(S.RDB\$INDEX_NAME)||'|'||TRIM(S.RDB\$FIELD_NAME)||'|'||S.RDB\$FIELD_POSITION
  FROM RDB\$INDEX_SEGMENTS S JOIN RDB\$INDICES I ON I.RDB\$INDEX_NAME = S.RDB\$INDEX_NAME
  WHERE I.RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY S.RDB\$INDEX_NAME, S.RDB\$FIELD_POSITION;
SELECT 'NF|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$FIELD_NAME)||'|'||COALESCE(RDB\$NULL_FLAG,0)
  FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$FIELD_POSITION;
SELECT 'REF|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONST_NAME_UQ)||'|'||TRIM(RDB\$MATCH_OPTION)
       ||'|'||TRIM(RDB\$UPDATE_RULE)||'|'||TRIM(RDB\$DELETE_RULE)
  FROM RDB\$REF_CONSTRAINTS ORDER BY RDB\$CONSTRAINT_NAME;
SQL
}
check "ALTER-built catalog matches engine reference" "$(catq "$WORK")" "$(catq "$REF")"

# --- 2. the engine enforces the ALTER-added constraints on fc's raw file ---
raw_pk=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO A1 VALUES (1, 40, 'e');
SQL
)
case "$raw_pk" in
    *"PRIMARY or UNIQUE"*|*"duplicate"*) echo "OK   engine enforces the ALTER-added PK on fc's raw file" ;;
    *) echo "DIFF raw-file PK enforcement"; echo "     $raw_pk"; fail=1 ;;
esac
raw_fk=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO B1 VALUES (1, 777);
SQL
)
case "$raw_fk" in
    *"FOREIGN KEY"*|*"foreign key"*) echo "OK   engine enforces the UNIQUE-referencing FK on fc's raw file" ;;
    *) echo "DIFF raw-file FK-onto-UNIQUE enforcement"; echo "     $raw_fk"; fail=1 ;;
esac
raw_ok=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO B1 VALUES (2, 10);
SQL
)
check "engine ACCEPTS a child of the UNIQUE key" "$(printf '%s' "$raw_ok" | strip)" ""

# --- 3. gbak backup + RESTORE, and the same enforcement on the copy ---
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-keyalter-backup.log 2>&1; then
    echo "OK   gbak backs up the altered database"
else
    echo "DIFF gbak backup"; cat /tmp/fc-keyalter-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-keyalter-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error|partner" /tmp/fc-keyalter-restore.log; then
    echo "OK   gbak RESTORES the altered database"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "partner|error|cannot" /tmp/fc-keyalter-restore.log | head; fail=1
fi
rst_pk=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO A2 VALUES (1, 100, 9);
SQL
)
case "$rst_pk" in
    *"PRIMARY or UNIQUE"*|*"duplicate"*) echo "OK   restored db REJECTS a duplicate compound PK" ;;
    *) echo "DIFF restored compound-PK enforcement"; echo "     $rst_pk"; fail=1 ;;
esac
rst_fk=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO B1 VALUES (3, 888);
SQL
)
case "$rst_fk" in
    *"FOREIGN KEY"*|*"foreign key"*) echo "OK   restored db REJECTS an orphan of the UNIQUE key" ;;
    *) echo "DIFF restored FK-onto-UNIQUE enforcement"; echo "     $rst_fk"; fail=1 ;;
esac
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$val" | strip)" ""

exit $fail
