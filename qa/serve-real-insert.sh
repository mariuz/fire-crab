#!/bin/sh
# The server WRITES: INSERT INTO <t> [(cols)] VALUES (...) puts a real
# record into the database file's pages - a transaction allocated from
# the header and committed in the TIP, the image laid NOT_PACKED into a
# data-page slot. The differential oracle is the REAL ENGINE itself:
#
#   1. node-firebird executes INSERTs against fire-crab, and reads the
#      rows back through fire-crab (same file, fresh walk);
#   2. the server is stopped and the C++ engine opens the very same
#      file: isql must SELECT the inserted rows and the new COUNT;
#   3. gfix -v -full must find NOTHING wrong with the file;
#   4. gbak must back it up (every record walked through the engine).
#
# An INSERT the server cannot honour (unknown column, type mismatch,
# subselect...) answers an SQL ERROR - never a silent no-op, never a
# wrong write. That path is asserted too.
#
#   qa/serve-real-insert.sh <clean-db-path> [port]
#
# Expects EMP(ID, DEPT_ID, REGION_ID, SALARY, NAME) - the join scratch
# db. The clean db is COPIED to a work file; the original is untouched.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
SRC="${1:?usage: serve-real-insert.sh <clean-db-path> [port]}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
WORK="/tmp/fc-insert-work.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
cp "$SRC" "$WORK"
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-insert.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" /tmp/fc-insert-work.fbk' EXIT
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

# --- phase 1: write through fire-crab, read back through fire-crab ---
check "insert full row" \
    "$(node_run "INSERT INTO EMP VALUES (101, 3, 1, 9999, 'Emp insert')")" "<no rows>"
check "insert with column list" \
    "$(node_run "INSERT INTO EMP (ID, NAME, SALARY) VALUES (102, 'Partial row', 8888)")" "<no rows>"
check "insert lowercase/NULL" \
    "$(node_run "insert into emp values (103, null, 2, 7777, 'Third')")" "<no rows>"
check "fire-crab reads its own writes" \
    "$(node_run "SELECT ID, DEPT_ID, SALARY, NAME FROM EMP WHERE ID > 100 ORDER BY ID")" \
"101|3|9999|Emp insert
102|<null>|8888|Partial row
103|<null>|7777|Third"
check "count includes them" \
    "$(node_run "SELECT COUNT(*) FROM EMP")" "103"
# unsupported inserts must raise SQL errors, not write wrong
case "$(node_run "INSERT INTO EMP (BOGUS) VALUES (1)")" in
    ERR*) echo "OK   unknown column raises an error" ;;
    *) echo "DIFF unknown column raises an error"; fail=1 ;;
esac
case "$(node_run "INSERT INTO EMP (ID) VALUES ('not a number')")" in
    ERR*) echo "OK   type mismatch raises an error" ;;
    *) echo "DIFF type mismatch raises an error"; fail=1 ;;
esac

# --- phase 2: the REAL ENGINE opens the file fire-crab wrote ---
kill $srv 2>/dev/null; wait $srv 2>/dev/null

engine_rows=$(run_isql <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || COALESCE(CAST(DEPT_ID AS VARCHAR(12)),'<null>') || '|' || SALARY || '|' || TRIM(NAME) FROM EMP WHERE ID > 100 ORDER BY ID;
EOF
)
check "ENGINE reads fire-crab's rows" "$engine_rows" \
"101|3|9999|Emp insert
102|<null>|8888|Partial row
103|<null>|7777|Third"
engine_count=$(run_isql <<'EOF' | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM EMP;
EOF
)
check "ENGINE count" "$engine_count" "103"

# --- phase 3: engine-side structural validation ---
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full finds nothing wrong" "$(printf '%s' "$val" | strip)" ""
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-insert-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi
exit $fail
