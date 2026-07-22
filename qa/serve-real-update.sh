#!/bin/bash
# The server writes VERSION CHAINS: UPDATE chains the old version behind
# the new primary, DELETE leaves a deleted stub over the chain - the
# MVCC write path (VIO_modify/VIO_erase + DPM_update) on the file image.
# The differential oracle is the REAL ENGINE, three ways:
#
#   1. node-firebird drives UPDATEs/DELETEs through fire-crab and reads
#      every change back through fire-crab (fresh walk of the file);
#   2. the SAME statements are applied by the C++ engine to a second
#      copy of the same clean database - after both, isql must print an
#      IDENTICAL final table from the fire-crab-written file and the
#      engine-written file;
#   3. structurally: gfix -v -full finds nothing wrong with the chains
#      fire-crab wrote, and gfix -sweep GARBAGE-COLLECTS them - the
#      version count must drop to exactly the live row count, with the
#      data unchanged - the engine's own GC consuming fire-crab's chains.
#
# The version arithmetic is asserted exactly: 30 rows, 9 statements ->
# 23 live primaries + 7 deleted stubs + 16 back versions = 46 versions
# before the sweep, 23 after. Unsupported DML (unknown column, type
# mismatch, unknown table) must raise an SQL error - never a silent
# no-op, never a wrong write.
#
#   qa/serve-real-update.sh [port]
#
# Builds its own scratch database (EMP, 30 rows, NULLs in DEPT_ID).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4055}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/dml_src.fdb"; CLEAN="$DIR/dml_clean.fdb"
WORK="/tmp/fc-dml-work.fdb"; REF="/tmp/fc-dml-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

# --- build the scratch database: EMP, 30 rows ---------------------------
# DEPT_ID: NULL when ID is a multiple of 7, else (ID mod 5)+1.
rm -f "$SRC" "$CLEAN" "$WORK" "$REF"
{
    echo "CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
    echo "CREATE TABLE EMP (ID INTEGER NOT NULL, DEPT_ID INTEGER, SALARY BIGINT, NAME VARCHAR(20));"
    echo "COMMIT;"
    i=1
    while [ $i -le 30 ]; do
        if [ $((i % 7)) -eq 0 ]; then dept=NULL; else dept=$(((i % 5) + 1)); fi
        echo "INSERT INTO EMP VALUES ($i, $dept, $((i * 100)), 'Emp $i');"
        i=$((i + 1))
    done
    echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" || { echo "FAIL scratch db creation"; exit 1; }
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/dml.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/dml.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-update.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" /tmp/fc-dml-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# run one statement through fire-crab; rows (or <no rows>) on stdout,
# ERR <message> on a raised SQL error
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() { # retry transient failures
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     want: $3"
        echo "     got:  $2"
        fail=1
    fi
}

# the DML battery - applied through fire-crab now, and through the real
# engine (on REF) later; the two final tables must be identical
S1="UPDATE EMP SET SALARY = 12345 WHERE ID = 7"
S2="update emp set name = 'Renamed', dept_id = 9 where id = 8"
S3="UPDATE EMP SET DEPT_ID = NULL WHERE ID = 9"
S4="UPDATE EMP SET SALARY = 1111 WHERE DEPT_ID = 3"
S5="UPDATE EMP SET SALARY = 54321 WHERE ID = 7"
S6="UPDATE EMP SET SALARY = 1 WHERE ID = 999"
S7="DELETE FROM EMP WHERE ID = 30"
S8="DELETE FROM EMP WHERE DEPT_ID = 5"
S9="DELETE FROM EMP WHERE DEPT_ID IS NULL AND ID > 20"

# --- phase 1: write through fire-crab, read back through fire-crab ------
check "update one row"            "$(node_run "$S1")" "<no rows>"
check "  ..salary changed"        "$(node_run "SELECT SALARY FROM EMP WHERE ID = 7")" "12345"
check "update two cols, lowercase" "$(node_run "$S2")" "<no rows>"
check "  ..both changed"          "$(node_run "SELECT DEPT_ID, NAME FROM EMP WHERE ID = 8")" "9|Renamed"
check "update to NULL"            "$(node_run "$S3")" "<no rows>"
check "  ..now NULL"              "$(node_run "SELECT DEPT_ID FROM EMP WHERE ID = 9")" "<null>"
check "multi-row update"          "$(node_run "$S4")" "<no rows>"
check "  ..five rows hit"         "$(node_run "SELECT COUNT(*) FROM EMP WHERE SALARY = 1111")" "5"
check "second update, same row"   "$(node_run "$S5")" "<no rows>"
check "  ..chain of two walks"    "$(node_run "SELECT SALARY FROM EMP WHERE ID = 7")" "54321"
check "zero-row update"           "$(node_run "$S6")" "<no rows>"
check "  ..changed nothing"       "$(node_run "SELECT COUNT(*) FROM EMP WHERE SALARY = 1")" "0"
check "delete one row"            "$(node_run "$S7")" "<no rows>"
check "  ..count drops"           "$(node_run "SELECT COUNT(*) FROM EMP")" "29"
check "multi-row delete"          "$(node_run "$S8")" "<no rows>"
check "  ..four gone"             "$(node_run "SELECT COUNT(*) FROM EMP")" "25"
check "IS NULL + AND delete"      "$(node_run "$S9")" "<no rows>"
check "  ..two gone"              "$(node_run "SELECT COUNT(*) FROM EMP")" "23"
# unsupported DML must raise SQL errors, not write wrong
for bad in "UPDATE EMP SET BOGUS = 1" \
           "UPDATE EMP SET ID = 'text' WHERE ID = 1" \
           "UPDATE EMP SET SALARY = 2 WHERE BOGUS = 1" \
           "DELETE FROM BOGUS"; do
    case "$(node_run "$bad")" in
        ERR*) echo "OK   error raised: $bad" ;;
        *) echo "DIFF error raised: $bad"; fail=1 ;;
    esac
done

# --- phase 2: the version chains, measured BEFORE any engine attach -----
kill $srv 2>/dev/null; wait $srv 2>/dev/null
rel_id=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<'EOF' | tr -d ' \n'
SET HEADING OFF;
SELECT RDB$RELATION_ID FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'EMP';
EOF
)
# 23 live + 7 stubs + 16 back versions (1+1+1+5+1 updates, 1+4+2 deletes)
check "46 versions before the sweep" "$("$FCSTAT" versions "$WORK" "$rel_id")" "46"

# --- phase 3: the REAL ENGINE validates and mirrors the writes ----------
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full accepts the chains" "$(printf '%s' "$val" | strip)" ""

# the engine applies the SAME statements to its own copy
printf '%s;\n' "$S1" "$S2" "$S3" "$S4" "$S5" "$S6" "$S7" "$S8" "$S9" COMMIT |
    "$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1

dump() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || COALESCE(CAST(DEPT_ID AS VARCHAR(12)),'<null>') || '|' || SALARY || '|' || TRIM(NAME) FROM EMP ORDER BY ID;
EOF
}
work_rows=$(dump "$WORK"); ref_rows=$(dump "$REF")
[ -n "$work_rows" ] || { echo "DIFF engine read of the work file"; fail=1; }
check "fire-crab-written == engine-written table" "$work_rows" "$ref_rows"

# --- phase 4: the engine's GC consumes fire-crab's chains ---------------
"$GFIX" -sweep -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1
check "23 versions after the sweep" "$("$FCSTAT" versions "$WORK" "$rel_id")" "23"
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean after the sweep" "$(printf '%s' "$val" | strip)" ""
check "data survives the sweep" "$(dump "$WORK")" "$ref_rows"
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-dml-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi
exit $fail
