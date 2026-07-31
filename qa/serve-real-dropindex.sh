#!/bin/bash
# DROP INDEX <name> - the mirror of CREATE INDEX, and the second user of
# the engine's DEFERRED index removal (see serve-real-dropconstraint.sh:
# the RDB$INDICES row is renamed RDB$TEMP_DEPEND_<relation id>_<index
# id> and marked RDB$INDEX_INACTIVE = 4, its segment rows deleted, the
# index-root slot moved into the drop states with its pages kept).
#
# An index that BACKS a constraint cannot go this way: the engine posts
# "Cannot delete index used by an Integrity Constraint" and points the
# user at ALTER TABLE DROP CONSTRAINT. fire-crab refuses it too.
#
# The differential is the engine, four ways:
#   1. fire-crab and the engine drop the same index on the same schema;
#      the catalogs and the index-root slots are compared;
#   2. the engine's OPTIMIZER agrees the index is gone - the same query
#      that PLANned through it before now reads the table NATURAL, on
#      fire-crab's raw file, and the surviving index is still PLANned;
#   3. dropping a constraint's index is refused by both;
#   4. gbak restores the file, the restored copy has only the surviving
#      indices, and gfix is clean on both it and fire-crab's raw file.
#
#   qa/serve-real-dropindex.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4133}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-dropi-work.fdb"; REF="$D/fc-dropi-ref.fdb"
FBK="$D/fc-dropi-work.fbk"; RST="$D/fc-dropi-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

DDL_T="CREATE TABLE T (A INTEGER NOT NULL, B VARCHAR(10), C INTEGER, CONSTRAINT PK_T PRIMARY KEY (A))"
DDL_IB="CREATE INDEX IX_TB ON T (B)"
DDL_IC="CREATE UNIQUE INDEX IX_TC ON T (C)"
INS_1="INSERT INTO T VALUES (1, 'x', 10)"
INS_2="INSERT INTO T VALUES (2, 'y', 20)"
INS_3="INSERT INTO T VALUES (3, 'z', 30)"
DROP_IB="DROP INDEX IX_TB"
# refused: PK_T's index backs a constraint
DROP_PK="DROP INDEX PK_T"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_T;
$DDL_IB;
$DDL_IC;
COMMIT;
$INS_1;
$INS_2;
$INS_3;
COMMIT;
EOF
# the engine's refusal, captured before the reference drops IX_TB
eng_pk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL
$DROP_PK;
SQL
)
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$DROP_IB;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dropi.log 2>&1 &
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

check "create T (with PK)"          "$(node_run "$DDL_T")" "OK"
check "create index IX_TB"          "$(node_run "$DDL_IB")" "OK"
check "create unique index IX_TC"   "$(node_run "$DDL_IC")" "OK"
check "insert rows"                 "$(node_run "$INS_1")" "OK"
check "insert rows (2)"             "$(node_run "$INS_2")" "OK"
check "insert rows (3)"             "$(node_run "$INS_3")" "OK"
# a constraint's index cannot be dropped this way
pk=$(node_run "$DROP_PK")
case "$pk" in
    ERR*) echo "OK   fire-crab refuses to DROP a constraint's index" ;;
    *) echo "DIFF constraint index dropped"; echo "     $pk"; fail=1 ;;
esac
unk=$(node_run "DROP INDEX NO_SUCH_INDEX")
case "$unk" in
    ERR*) echo "OK   an unknown index name errors" ;;
    *) echo "DIFF unknown index accepted"; echo "     $unk"; fail=1 ;;
esac
check "DROP INDEX IX_TB"            "$(node_run "$DROP_IB")" "OK"
# the surviving unique index still enforces itself in fire-crab
dup=$(node_run "INSERT INTO T VALUES (4, 'w', 10)")
case "$dup" in
    ERR*) echo "OK   the surviving UNIQUE index still refuses a duplicate" ;;
    *) echo "DIFF surviving unique index not enforced"; echo "     $dup"; fail=1 ;;
esac
# ... and rows still insert through it
check "insert still works after the drop" "$(node_run "INSERT INTO T VALUES (4, 'w', 40)")" "OK"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the reference gets the same extra row, so the files stay comparable
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'EOF'
INSERT INTO T VALUES (4, 'w', 40);
COMMIT;
EOF

# --- 1. catalogs and index-root slots ---
catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'IDX|'||TRIM(RDB$INDEX_NAME)||'|'||COALESCE(RDB$UNIQUE_FLAG,-1)||'|'
       ||COALESCE(RDB$INDEX_INACTIVE,-1)||'|'||RDB$INDEX_ID||'|'||RDB$SEGMENT_COUNT
  FROM RDB$INDICES WHERE RDB$RELATION_NAME = 'T' ORDER BY RDB$INDEX_ID;
SELECT 'SEG|'||TRIM(S.RDB$INDEX_NAME)||'|'||TRIM(S.RDB$FIELD_NAME)||'|'||S.RDB$FIELD_POSITION
  FROM RDB$INDEX_SEGMENTS S JOIN RDB$INDICES I ON I.RDB$INDEX_NAME = S.RDB$INDEX_NAME
  WHERE I.RDB$RELATION_NAME = 'T' ORDER BY S.RDB$INDEX_NAME, S.RDB$FIELD_POSITION;
SELECT 'RC|'||TRIM(RDB$CONSTRAINT_NAME)||'|'||TRIM(RDB$CONSTRAINT_TYPE)||'|'
       ||COALESCE(TRIM(RDB$INDEX_NAME),'-')
  FROM RDB$RELATION_CONSTRAINTS WHERE RDB$RELATION_NAME = 'T' ORDER BY 1;
SELECT 'ROW|'||A||'|'||COALESCE(B,'-')||'|'||COALESCE(C,-1) FROM T ORDER BY A;
SQL
}
check "post-drop catalog matches engine reference" "$(catq "$WORK")" "$(catq "$REF")"
if [ -x "$FCSTAT" ]; then
    # states 5 (irt_commit) and 6 (irt_drop) are one lifecycle point
    # either side of the engine's own settling - classified, not compared
    slots() { # <file>
        "$FCSTAT" indexes "$1" 128 2>/dev/null |
            sed -e 's/.*index \([0-9]*\): root page [0-9]*, \([0-9]*\) key(s), state \([0-9]*\).*/SLOT \1 keys=\2 state=\3/' |
            sed -e 's/state=[56]$/state=deferred-drop/' -e 's/state=3$/state=normal/'
    }
    check "index-root slots match" "$(slots "$WORK")" "$(slots "$REF")"
else
    echo "SKIP fcstat not built - index-root slot comparison"
fi

# --- 2. the optimizer agrees: the dropped index is gone, the others are not ---
planq() { # <file> <query>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | grep -i '^PLAN' | strip
SET PLAN ON;
$2;
SQL
}
check "engine PLANs T NATURAL on the dropped index's column" \
      "$(planq "$WORK" "SELECT COUNT(*) FROM T WHERE B = 'x'")" \
      "$(planq "$REF"  "SELECT COUNT(*) FROM T WHERE B = 'x'")"
check "engine still PLANs through the surviving index" \
      "$(planq "$WORK" "SELECT COUNT(*) FROM T WHERE C = 20")" \
      "$(planq "$REF"  "SELECT COUNT(*) FROM T WHERE C = 20")"
case "$(planq "$WORK" "SELECT COUNT(*) FROM T WHERE C = 20")" in
    *INDEX*) echo "OK   the surviving index is a real index plan (not both NATURAL)" ;;
    *) echo "DIFF surviving index unused - the comparison above was vacuous"; fail=1 ;;
esac

# --- 3. the engine refused the same constraint-index drop ---
case "$eng_pk" in
    *"Integrity Constraint"*) echo "OK   the engine refuses the same drop (same reason)" ;;
    *) echo "DIFF engine did not refuse the constraint-index drop"; echo "     $eng_pk"; fail=1 ;;
esac

# --- 4. gbak, and structural validation of both files ---
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-dropi-backup.log 2>&1; then
    echo "OK   gbak backs up the post-drop database"
else
    echo "DIFF gbak backup"; cat /tmp/fc-dropi-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-dropi-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-dropi-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-dropi-restore.log | head; fail=1
fi
rstq=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
SET HEADING OFF;
SELECT TRIM(RDB$INDEX_NAME) FROM RDB$INDICES WHERE RDB$RELATION_NAME = 'T' ORDER BY 1;
SQL
)
check "restored copy carries only the surviving indices" \
      "$(printf '%s' "$rstq" | strip | grep -v '^$')" "$(printf 'IX_TC\nPK_T')"
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$val" | strip)" ""
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
