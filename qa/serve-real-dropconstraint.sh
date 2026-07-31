#!/bin/bash
# ALTER TABLE <t> DROP CONSTRAINT <name> - NOT NULL, PRIMARY KEY,
# UNIQUE and FOREIGN KEY.
#
# The interesting half is what happens to a dropped constraint's INDEX.
# The engine does NOT erase it (DdlNodes.epp DropIndexNode::drop): the
# RDB$INDICES row is RENAMED to RDB$TEMP_DEPEND_<relation id>_<index id>
# and marked RDB$INDEX_INACTIVE = 4 (MET_index_deferred_drop), its
# RDB$INDEX_SEGMENTS rows are deleted, and the index-root slot moves to
# state irt_drop (6, ods.h) - "index to be removed when OAT >
# irt_transaction" - keeping its pages until then. gbak skips such
# indices (backup.epp:1676), so a restored copy has no trace of them.
# fire-crab reproduces that state rather than a tidier one, because the
# engine has to read the result as its own.
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine drop the SAME constraints on the same
#      schema; the catalogs are compared row for row (including the
#      TEMP_DEPEND leftovers and the index-root slot state read back by
#      fcstat);
#   2. the dropped constraints are no longer ENFORCED by the engine on
#      fire-crab's raw file (duplicates and orphans now accepted, a NULL
#      accepted where NOT NULL was dropped);
#   3. dropping a PRIMARY KEY that a FOREIGN KEY references is refused -
#      by both;
#   4. gbak backs up and RESTORES the file; the restored copy carries
#      the surviving constraints only, and gfix is clean.
#
#   qa/serve-real-dropconstraint.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4127}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dropc-work.fdb"; REF="$D/fc-dropc-ref.fdb"
FBK="$D/fc-dropc-work.fbk"; RST="$D/fc-dropc-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# P keeps its primary key (C's foreign key needs it); U's UNIQUE, C's
# FOREIGN KEY and N's NOT NULL are the ones dropped
DDL_P="CREATE TABLE P (A INTEGER NOT NULL, B INTEGER, CONSTRAINT PK_P PRIMARY KEY (A))"
DDL_U="CREATE TABLE U (Z INTEGER NOT NULL, W INTEGER, CONSTRAINT UQ_U UNIQUE (Z))"
DDL_C="CREATE TABLE C (ID INTEGER NOT NULL PRIMARY KEY, PA INTEGER, CONSTRAINT FK_C FOREIGN KEY (PA) REFERENCES P (A))"
DDL_N="CREATE TABLE N (Q INTEGER NOT NULL, R INTEGER)"
INS_P="INSERT INTO P VALUES (1, 10)"
INS_U="INSERT INTO U VALUES (5, 50)"
INS_C="INSERT INTO C VALUES (1, 1)"
INS_N="INSERT INTO N VALUES (9, 90)"
DROP_UQ="ALTER TABLE U DROP CONSTRAINT UQ_U"
DROP_FK="ALTER TABLE C DROP CONSTRAINT FK_C"
DROP_NN="ALTER TABLE N DROP CONSTRAINT INTEG_7"
# the refusal probe: PK_P is referenced by C's foreign key
DROP_PK="ALTER TABLE P DROP CONSTRAINT PK_P"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_P;
$DDL_U;
$DDL_C;
$DDL_N;
COMMIT;
$INS_P;
$INS_U;
$INS_C;
$INS_N;
COMMIT;
EOF
# the NOT NULL constraint's generated name has to be the same on both
# sides for the DROP to name it - check the engine agrees before using it
nn_name=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<'SQL'
SET HEADING OFF;
SELECT TRIM(C.RDB$CONSTRAINT_NAME) FROM RDB$RELATION_CONSTRAINTS C
 WHERE C.RDB$RELATION_NAME = 'N' AND C.RDB$CONSTRAINT_TYPE = 'NOT NULL';
SQL
)
nn_name=$(printf '%s' "$nn_name" | tr -d ' \n')
DROP_NN="ALTER TABLE N DROP CONSTRAINT $nn_name"
# the engine's refusal, captured while its FOREIGN KEY still stands (the
# drops below remove it, which would make the same statement succeed)
eng_pk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL
$DROP_PK;
SQL
)
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$DROP_UQ;
$DROP_FK;
$DROP_NN;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dropc.log 2>&1 &
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

# --- fire-crab builds the same schema, then drops the same constraints ---
check "create P"                "$(node_run "$DDL_P")" "OK"
check "create U"                "$(node_run "$DDL_U")" "OK"
check "create C (FK onto P)"    "$(node_run "$DDL_C")" "OK"
check "create N"                "$(node_run "$DDL_N")" "OK"
check "insert into P"           "$(node_run "$INS_P")" "OK"
check "insert into U"           "$(node_run "$INS_U")" "OK"
check "insert into C"           "$(node_run "$INS_C")" "OK"
check "insert into N"           "$(node_run "$INS_N")" "OK"
# the PK that a foreign key still references cannot go
pk=$(node_run "$DROP_PK")
case "$pk" in
    ERR*) echo "OK   fire-crab refuses to drop a PK a FOREIGN KEY uses" ;;
    *) echo "DIFF referenced PK dropped"; echo "     $pk"; fail=1 ;;
esac
check "DROP CONSTRAINT (UNIQUE)"      "$(node_run "$DROP_UQ")" "OK"
check "DROP CONSTRAINT (FOREIGN KEY)" "$(node_run "$DROP_FK")" "OK"
check "DROP CONSTRAINT (NOT NULL)"    "$(node_run "$DROP_NN")" "OK"
# an unknown constraint name is an error, not a silent success
unk=$(node_run "ALTER TABLE U DROP CONSTRAINT NO_SUCH")
case "$unk" in
    ERR*) echo "OK   an unknown constraint name errors" ;;
    *) echo "DIFF unknown constraint accepted"; echo "     $unk"; fail=1 ;;
esac
# the dropped UNIQUE is no longer enforced by fire-crab itself
dup=$(node_run "INSERT INTO U VALUES (5, 51)")
check "fire-crab accepts a former-duplicate"  "$dup" "OK"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. catalogs compared, TEMP_DEPEND leftovers and all ---
TBLS="'P','U','C','N'"
catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^\$'
SET HEADING OFF;
SELECT 'RC|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONSTRAINT_TYPE)
       ||'|'||COALESCE(TRIM(RDB\$INDEX_NAME),'-')
  FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$CONSTRAINT_NAME;
SELECT 'IDX|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$INDEX_NAME)||'|'||COALESCE(RDB\$UNIQUE_FLAG,-1)
       ||'|'||COALESCE(RDB\$INDEX_INACTIVE,-1)||'|'||RDB\$INDEX_ID
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
SELECT 'REF|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONST_NAME_UQ) FROM RDB\$REF_CONSTRAINTS
  ORDER BY RDB\$CONSTRAINT_NAME;
SQL
}
check "post-drop catalog matches engine reference" "$(catq "$WORK")" "$(catq "$REF")"

# the index-root slots, read straight off both files by fcstat: a
# deferred-dropped index keeps its root page in state 6 (irt_drop)
if [ -x "$FCSTAT" ]; then
    # states 5 (irt_commit) and 6 (irt_drop) are the same lifecycle
    # point either side of the engine's own settling, and the engine
    # settles the files it opens - so the comparison classifies rather
    # than compares raw states. A slot left "normal", or removed
    # outright, differs from both.
    slots() { # <file>
        for r in 128 129 130 131; do "$FCSTAT" indexes "$1" $r 2>/dev/null; done |
            sed -e 's/^relation \([0-9]*\).*/REL \1/' \
                -e 's/.*index \([0-9]*\): root page \([0-9]*\), .*state \([0-9]*\).*/SLOT \1 root=yes state=\3/' |
            sed -e 's/state=[56]$/state=deferred-drop/' -e 's/state=3$/state=normal/'
    }
    check "index-root slots match (dropped ones deferred, not normal)" \
          "$(slots "$WORK")" "$(slots "$REF")"
else
    echo "SKIP fcstat not built - index-root slot comparison"
fi

# --- 2. the engine no longer enforces what was dropped, on fc's file ---
raw_dup=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO U VALUES (5, 52);
SQL
)
check "engine accepts a former-duplicate (UNIQUE gone)" "$(printf '%s' "$raw_dup" | strip)" ""
raw_orphan=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO C VALUES (2, 999);
SQL
)
check "engine accepts an orphan (FOREIGN KEY gone)" "$(printf '%s' "$raw_orphan" | strip)" ""
raw_null=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO N VALUES (NULL, 91);
SQL
)
check "engine accepts a NULL (NOT NULL gone)" "$(printf '%s' "$raw_null" | strip)" ""
# ... while the surviving primary key still is enforced
raw_pk=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO P VALUES (1, 11);
SQL
)
case "$raw_pk" in
    *"PRIMARY or UNIQUE"*|*"duplicate"*) echo "OK   the surviving PRIMARY KEY is still enforced" ;;
    *) echo "DIFF surviving PK not enforced"; echo "     $raw_pk"; fail=1 ;;
esac

# --- 3. the engine refuses the same PK drop on its own file (captured
# above, before the reference dropped its own foreign key) ---
case "$eng_pk" in
    *"FOREIGN KEY"*) echo "OK   the engine refuses the same PK drop (same reason)" ;;
    *) echo "DIFF engine did not refuse the referenced-PK drop"; echo "     $eng_pk"; fail=1 ;;
esac

# --- 4. gbak backup + RESTORE: the leftovers do not travel ---
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dropc-backup.log 2>&1; then
    echo "OK   gbak backs up the post-drop database"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dropc-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dropc-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error|partner" /tmp/fc-dropc-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "partner|error|cannot" /tmp/fc-dropc-restore.log | head; fail=1
fi
rstq=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<SQL
SET HEADING OFF;
SELECT 'RC|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$CONSTRAINT_TYPE)
  FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY 1;
SELECT 'IDX|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$INDEX_NAME)
  FROM RDB\$INDICES WHERE RDB\$RELATION_NAME IN ($TBLS) ORDER BY 1;
SQL
)
check "restored copy carries only the surviving constraints" \
      "$(printf '%s' "$rstq" | strip | grep -v '^$')" \
      "$(printf 'RC|C|NOT NULL\nRC|C|PRIMARY KEY\nRC|P|NOT NULL\nRC|P|PRIMARY KEY\nRC|U|NOT NULL\nIDX|C|RDB$PRIMARY1\nIDX|P|PK_P')"
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$val" | strip)" ""
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
