#!/bin/bash
# NAMED PRIMARY KEY constraints and UNIQUE constraints in CREATE TABLE.
# Until now fire-crab wrote one shape only: an unnamed PRIMARY KEY, its
# index named RDB$PRIMARY<n>, plus a NOT NULL constraint row for every
# not-null column. Three engine facts, probed and now implemented:
#
#   1. a NAMED constraint names its INDEX too - CONSTRAINT PK_P PRIMARY
#      KEY (A,B) yields RDB$INDICES.RDB$INDEX_NAME = 'PK_P', not
#      RDB$PRIMARY<n>;
#   2. a TABLE-level PRIMARY KEY sets its columns' RDB$NULL_FLAG but
#      writes NO 'NOT NULL' constraint row (a COLUMN-level PRIMARY KEY
#      does write one) - fire-crab wrote one either way;
#   3. the generated index names RDB$PRIMARY<n> (primary) and RDB$<n>
#      (unique) come from ONE sequence, advanced in DECLARATION order,
#      and the INTEG_<n> constraint names likewise - so a table
#      declaring UNIQUE before PRIMARY KEY numbers them in that order.
#
# The differential is the engine, three ways:
#   1. the catalog the engine reads from fire-crab's file matches, row
#      for row, an engine-built reference of the SAME schema - names,
#      index names, segments, null flags, check-constraint links;
#   2. the constraints are LIVE on fire-crab's raw file: fire-crab
#      itself refuses a duplicate unique key, and the engine refuses
#      one too (and refuses a NULL in a PK column);
#   3. gbak backs up and RESTORES the file, the restored database
#      enforces the same constraints and gfix finds it clean.
#
#   qa/serve-real-key.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4117}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-key-work.fdb"; REF="$D/fc-key-ref.fdb"
FBK="$D/fc-key-work.fbk"; RST="$D/fc-key-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# NAMED table-level compound PRIMARY KEY: index named after the constraint
DDL_KP="CREATE TABLE KP (A INTEGER, B INTEGER, PNAME VARCHAR(10), CONSTRAINT PK_KP PRIMARY KEY (A, B))"
# NAMED column-level PRIMARY KEY: also a NOT NULL constraint row for X
DDL_KQ="CREATE TABLE KQ (X INTEGER CONSTRAINT PK_KQ PRIMARY KEY, Y VARCHAR(10))"
# NAMED table-level UNIQUE over a NOT NULL column
DDL_KU="CREATE TABLE KU (Z INTEGER NOT NULL, W INTEGER, CONSTRAINT UQ_KU UNIQUE (Z))"
# UNNAMED UNIQUE declared BEFORE an unnamed PRIMARY KEY: exercises both
# generated-name sequences in declaration order
DDL_KM="CREATE TABLE KM (A INTEGER NOT NULL, B INTEGER, UNIQUE (B), C INTEGER NOT NULL, PRIMARY KEY (A))"
# unnamed COLUMN-level UNIQUE (nullable - UNIQUE implies nothing here)
DDL_KC="CREATE TABLE KC (A INTEGER UNIQUE, B INTEGER)"
# a FOREIGN KEY onto the NAMED compound PK: the partner lookup has to
# find PK_KP's index by its constraint name, not by an RDB$PRIMARY<n>
DDL_KF="CREATE TABLE KF (ID INTEGER NOT NULL PRIMARY KEY, FA INTEGER, FB INTEGER, CONSTRAINT FK_KF FOREIGN KEY (FA, FB) REFERENCES KP (A, B))"

# fire-crab's file starts as an engine-created empty database; the engine
# reference gets the same tables in the same order via ordinary DDL.
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_KP;
$DDL_KQ;
$DDL_KU;
$DDL_KM;
$DDL_KC;
$DDL_KF;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-key.log 2>&1 &
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

# --- fire-crab writes the schema ---
check "named compound PK (table level)"  "$(node_run "$DDL_KP")" "OK"
check "named PK (column level)"          "$(node_run "$DDL_KQ")" "OK"
check "named UNIQUE"                     "$(node_run "$DDL_KU")" "OK"
check "unnamed UNIQUE then unnamed PK"   "$(node_run "$DDL_KM")" "OK"
check "unnamed column-level UNIQUE"      "$(node_run "$DDL_KC")" "OK"
check "FK onto the named compound PK"    "$(node_run "$DDL_KF")" "OK"

# --- rows, and fire-crab's own unique enforcement ---
check "insert into the named UNIQUE"     "$(node_run "INSERT INTO KU VALUES (1, 10)")" "OK"
check "insert a second unique value"     "$(node_run "INSERT INTO KU VALUES (2, 20)")" "OK"
dup=$(node_run "INSERT INTO KU VALUES (1, 30)")
case "$dup" in
    ERR*) echo "OK   fire-crab REFUSES a duplicate unique key" ;;
    *) echo "DIFF duplicate unique key accepted"; echo "     $dup"; fail=1 ;;
esac
check "insert compound PK parent"        "$(node_run "INSERT INTO KP VALUES (1, 100, 'x')")" "OK"
dup2=$(node_run "INSERT INTO KP VALUES (1, 100, 'y')")
case "$dup2" in
    ERR*) echo "OK   fire-crab REFUSES a duplicate PRIMARY KEY" ;;
    *) echo "DIFF duplicate primary key accepted"; echo "     $dup2"; fail=1 ;;
esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the constraint catalog the engine reads from fc == the reference ---
TBLS="'KP','KQ','KU','KM','KC','KF'"
catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^\$'
SET HEADING OFF;
SELECT 'RC|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONSTRAINT_TYPE)
       ||'|'||COALESCE(TRIM(RDB\$INDEX_NAME),'-')
  FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$CONSTRAINT_NAME;
SELECT 'IDX|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$INDEX_NAME)||'|'||COALESCE(RDB\$UNIQUE_FLAG,-1)
       ||'|'||RDB\$SEGMENT_COUNT||'|'||COALESCE(TRIM(RDB\$FOREIGN_KEY),'-')||'|'||COALESCE(RDB\$INDEX_INACTIVE,-1)
  FROM RDB\$INDICES WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$INDEX_ID;
SELECT 'SEG|'||TRIM(S.RDB\$INDEX_NAME)||'|'||TRIM(S.RDB\$FIELD_NAME)||'|'||S.RDB\$FIELD_POSITION
  FROM RDB\$INDEX_SEGMENTS S JOIN RDB\$INDICES I ON I.RDB\$INDEX_NAME = S.RDB\$INDEX_NAME
  WHERE I.RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY S.RDB\$INDEX_NAME, S.RDB\$FIELD_POSITION;
SELECT 'NF|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$FIELD_NAME)||'|'||COALESCE(RDB\$NULL_FLAG,0)
  FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$FIELD_POSITION;
SELECT 'CC|'||TRIM(C.RDB\$CONSTRAINT_NAME)||'|'||TRIM(C.RDB\$TRIGGER_NAME)
  FROM RDB\$CHECK_CONSTRAINTS C JOIN RDB\$RELATION_CONSTRAINTS R
       ON R.RDB\$CONSTRAINT_NAME = C.RDB\$CONSTRAINT_NAME
  WHERE R.RDB\$RELATION_NAME IN ($TBLS) ORDER BY C.RDB\$CONSTRAINT_NAME;
SELECT 'REF|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONST_NAME_UQ)||'|'||TRIM(RDB\$MATCH_OPTION)
  FROM RDB\$REF_CONSTRAINTS ORDER BY RDB\$CONSTRAINT_NAME;
SQL
}
check "key catalog matches engine reference" "$(catq "$WORK")" "$(catq "$REF")"

# --- 2. the engine enforces the constraints on fc's RAW file ---
raw_dup=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KU VALUES (2, 99);
SQL
)
case "$raw_dup" in
    *"UNIQ"*|*"uniq"*|*"duplicate"*) echo "OK   engine REJECTS a duplicate unique key on fc's raw file" ;;
    *) echo "DIFF raw-file unique enforcement"; echo "     $raw_dup"; fail=1 ;;
esac
raw_null=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KP VALUES (NULL, 7, 'z');
SQL
)
case "$raw_null" in
    *"not allow"*|*"NULL"*|*"null"*) echo "OK   engine REJECTS NULL in a table-level PK column" ;;
    *) echo "DIFF raw-file PK NOT NULL enforcement"; echo "     $raw_null"; fail=1 ;;
esac
raw_ok=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KU VALUES (3, 33);
SQL
)
check "engine ACCEPTS a fresh unique value on fc's raw file" "$(printf '%s' "$raw_ok" | strip)" ""

# --- 3. gbak backup + RESTORE, then the same constraints on the copy ---
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-key-backup.log 2>&1; then
    echo "OK   gbak backs up fc's constraint database"
else
    echo "DIFF gbak backup"; cat /tmp/fc-key-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-key-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error|partner" /tmp/fc-key-restore.log; then
    echo "OK   gbak RESTORES fc's constraint database"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "partner|error|cannot" /tmp/fc-key-restore.log | head; fail=1
fi
rst_dup=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO KU VALUES (3, 44);
SQL
)
case "$rst_dup" in
    *"UNIQ"*|*"uniq"*|*"duplicate"*) echo "OK   restored db REJECTS a duplicate unique key" ;;
    *) echo "DIFF restored unique enforcement"; echo "     $rst_dup"; fail=1 ;;
esac
rst_orphan=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO KF VALUES (1, 5, 555);
SQL
)
case "$rst_orphan" in
    *"FOREIGN KEY"*|*"foreign key"*) echo "OK   restored db REJECTS an orphan of the named PK" ;;
    *) echo "DIFF restored FK enforcement"; echo "     $rst_orphan"; fail=1 ;;
esac
rst_child=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO KF VALUES (2, 1, 100);
SQL
)
check "restored db ACCEPTS a valid child" "$(printf '%s' "$rst_child" | strip)" ""
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$val" | strip)" ""

exit $fail
