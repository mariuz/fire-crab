#!/bin/bash
# DDL BREADTH: PRIMARY KEY + NOT NULL constraints, CREATE INDEX (with
# backfill of existing rows), DROP TABLE. The differential's high
# point: the ENGINE enforces the constraints fire-crab wrote - its own
# duplicate INSERT dies with "violation of PRIMARY or UNIQUE KEY
# constraint INTEG_n" naming the constraint row fire-crab stored, its
# point lookups PLAN through the RDB$PRIMARYn and user indexes
# fire-crab built (backfill included), and its DROP/our DROP leave a
# file gfix -v -full accepts and gbak restores.
#
# Engine law found live while building this: only pag_pointer/pag_root
# /pag_transactions/pag_ids rows are legal in RDB$PAGES - registering
# a B-tree bucket page there CORRUPTs the attach (DPM_scan_pages error
# 257); bucket pages are reachable only through the index root slots.
#
#   qa/serve-real-ddl2.sh [port]
#
# Builds its own scratch database (charset NONE).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4080}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/ddl2_src.fdb"; CLEAN="$DIR/ddl2_clean.fdb"
WORK="/tmp/fc-ddl2-work.fdb"; RESTORED="/tmp/fc-ddl2-restored.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$RESTORED"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/ddl2.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/ddl2.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ddl2.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$RESTORED" /tmp/fc-ddl2-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }

node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" FC_PARAMS="${2:-[]}" \
    timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      const params=eval(process.env.FC_PARAMS);
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,params,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1" "${2:-[]}")
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
check_err() { # <label> <got>
    case "$2" in
        ERR*) echo "OK   $1" ;;
        *) echo "DIFF $1 (expected an SQL error, got: $2)"; fail=1 ;;
    esac
}

# --- phase 1: PK + NOT NULL through fire-crab --------------------------
check "create table with PK" \
    "$(node_run "CREATE TABLE PKT (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(20), SAL BIGINT)")" \
    "<no rows>"
check "insert rows" "$(node_run "INSERT INTO PKT VALUES (1, 'alpha', 100)")" "<no rows>"
check "second row" "$(node_run "INSERT INTO PKT VALUES (2, 'beta', 200)")" "<no rows>"
check_err "duplicate PK refused by fire-crab" "$(node_run "INSERT INTO PKT VALUES (1, 'dup', 0)")"
check_err "NULL into NOT NULL PK refused" "$(node_run "INSERT INTO PKT (NAME) VALUES ('nopk')")"
check_err "UPDATE PK to NULL refused" "$(node_run "UPDATE PKT SET ID = NULL WHERE ID = 2")"
check "count after refusals" "$(node_run "SELECT COUNT(*) FROM PKT")" "2"

# table-level PK over two columns (the multiseg writer underneath)
check "create table w/ compound table-level PK" \
    "$(node_run "CREATE TABLE CPK (A INTEGER NOT NULL, B VARCHAR(8) NOT NULL, V BIGINT, PRIMARY KEY (A, B))")" \
    "<no rows>"
check "compound rows" "$(node_run "INSERT INTO CPK VALUES (1, 'x', 10)")" "<no rows>"
check "same A different B" "$(node_run "INSERT INTO CPK VALUES (1, 'y', 20)")" "<no rows>"
check_err "compound dup refused" "$(node_run "INSERT INTO CPK VALUES (1, 'x', 0)")"

# --- phase 2: CREATE INDEX with backfill -------------------------------
check "create index on populated table" \
    "$(node_run "CREATE INDEX PKT_NAME ON PKT (NAME)")" "<no rows>"
check "create unique index" \
    "$(node_run "CREATE UNIQUE INDEX PKT_SAL ON PKT (SAL)")" "<no rows>"
check_err "duplicate index name refused" "$(node_run "CREATE INDEX PKT_NAME ON PKT (SAL)")"
check_err "unique backfill catches existing dup" \
    "$(node_run "CREATE UNIQUE INDEX CPK_A ON CPK (A)")"
check "insert after index exists" \
    "$(node_run "INSERT INTO PKT VALUES (3, 'gamma', 300)")" "<no rows>"
check_err "unique index enforced on new inserts" \
    "$(node_run "INSERT INTO PKT VALUES (4, 'delta', 100)")"

# --- phase 3: DROP TABLE through fire-crab -----------------------------
check "create + fill a victim" \
    "$(node_run "CREATE TABLE DROPME (X INTEGER, Y VARCHAR(10))")" "<no rows>"
check "victim row" "$(node_run "INSERT INTO DROPME VALUES (9, 'bye')")" "<no rows>"
check "drop it" "$(node_run "DROP TABLE DROPME")" "<no rows>"
check_err "dropping a system table refused" "$(node_run "DROP TABLE RDB\$RELATIONS")"
check_err "dropping a missing table errors" "$(node_run "DROP TABLE NOSUCH")"

# --- phase 4: the ENGINE enforces what fire-crab wrote ------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full after all fire-crab DDL" "$(printf '%s' "$val" | strip)" ""

plan_out=$(run_isql <<'EOF' | strip | grep -v '^$'
SET PLAN;
SET HEADING OFF;
SELECT NAME FROM PKT WHERE ID = 2;
EOF
)
if printf '%s\n' "$plan_out" | grep -q 'INDEX (.*RDB\$PRIMARY' &&
   printf '%s\n' "$plan_out" | grep -q '^beta$'; then
    echo "OK   engine point lookup THROUGH the fire-crab PK index"
else
    echo "DIFF engine point lookup THROUGH the fire-crab PK index"
    echo "     got: $plan_out"; fail=1
fi
plan_out=$(run_isql <<'EOF' | strip | grep -v '^$'
SET PLAN;
SET HEADING OFF;
SELECT ID FROM PKT WHERE NAME = 'gamma';
EOF
)
if printf '%s\n' "$plan_out" | grep -q 'INDEX (.*PKT_NAME' &&
   printf '%s\n' "$plan_out" | grep -q '^3$'; then
    echo "OK   engine scan THROUGH the backfilled user index"
else
    echo "DIFF engine scan THROUGH the backfilled user index"
    echo "     got: $plan_out"; fail=1
fi

dup=$(run_isql <<'EOF' 2>&1
INSERT INTO PKT VALUES (1, 'engine dup', 999);
EOF
)
case "$dup" in
    *"PRIMARY or UNIQUE KEY"*INTEG*) echo "OK   ENGINE enforces the fire-crab PK (names our INTEG row)" ;;
    *) echo "DIFF ENGINE enforces the fire-crab PK"; echo "     got: $dup"; fail=1 ;;
esac
nn=$(run_isql <<'EOF' 2>&1
INSERT INTO PKT (NAME) VALUES ('engine nopk');
EOF
)
case "$nn" in
    *validation*|*"NOT NULL"*|*null*) echo "OK   ENGINE enforces the fire-crab NOT NULL" ;;
    *) echo "DIFF ENGINE enforces the fire-crab NOT NULL"; echo "     got: $nn"; fail=1 ;;
esac
check "engine sees DROPME gone" \
    "$(run_isql <<< $'SET HEADING OFF; SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = \x27DROPME\x27;' | tr -d ' \n')" "0"

# engine writes a legit row, then sweep collects our drop's stub chains
run_isql <<'EOF' >/dev/null 2>&1 || { echo "DIFF engine INSERT"; fail=1; }
INSERT INTO PKT VALUES (5, 'engine row', 500);
COMMIT;
EOF
"$GFIX" -sweep -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full after engine write + sweep" "$(printf '%s' "$val" | strip)" ""
check "rows survive the sweep" \
    "$(run_isql <<< 'SET HEADING OFF; SELECT COUNT(*) FROM PKT;' | tr -d ' \n')" "4"

# --- phase 5: gbak restore replays constraints + indexes ---------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-ddl2-work.fbk >/dev/null 2>&1 &&
   "$GBAK" -c -user "$U" -pas "$P" /tmp/fc-ddl2-work.fbk "$RESTORED" >/dev/null 2>&1; then
    echo "OK   gbak backup + restore"
else
    echo "DIFF gbak backup + restore"; fail=1
fi
rdup=$("$ISQL" -q -b -user "$U" -pas "$P" "$RESTORED" <<'EOF' 2>&1
INSERT INTO PKT VALUES (1, 'restored dup', 0);
EOF
)
case "$rdup" in
    *"PRIMARY or UNIQUE KEY"*) echo "OK   restored copy still enforces the PK" ;;
    *) echo "DIFF restored copy still enforces the PK"; echo "     got: $rdup"; fail=1 ;;
esac
exit $fail
