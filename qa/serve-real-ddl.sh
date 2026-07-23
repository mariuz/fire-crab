#!/bin/bash
# DDL: CREATE TABLE through fire-crab - catalog rows, format and
# RDB$RUNTIME blobs, pointer/root pages, RDB$PAGES registration and
# system-index maintenance, all written into the file image. THE
# differential: the C++ ENGINE then opens that file and treats the
# table as its own - reads it, WRITES its own rows into it (landing on
# the pointer page fire-crab allocated), runs its own CREATE TABLE on
# top (the relation-id and RDB$<n> domain sequences must survive),
# DROPs the fire-crab table through its own DML over our catalog rows,
# and gbak RESTORES the file - a restore replays the catalog as real
# engine-side DDL, the deepest possible read of every byte we wrote.
#
# Three engine facts this gate exists to pin (each found the hard way,
# by strace/gdb-bisecting a hung attach against the DEBUG engine):
#   - RDB$PAGES rows must be SYSTEM-transaction records (tx 0):
#     get_header (dpm.epp) posts isc_wrong_page otherwise, and the
#     release engine's error path leaves a latched buffer behind - the
#     attach just hangs;
#   - the header's OIT/OAT/OST must advance past the DDL's
#     transactions (a clean engine detach leaves OIT = next-2);
#   - a record landing on an empty data page must clear the pointer
#     page's ppg_dp_empty fill bit, or gfix -v -full warns.
#
#   qa/serve-real-ddl.sh [port]
# (CREATE INDEX / DROP TABLE / constraints: serve-real-ddl2.sh)
#
# Builds its own scratch database (charset NONE).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4078}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/ddl_src.fdb"; CLEAN="$DIR/ddl_clean.fdb"
WORK="/tmp/fc-ddl-work.fdb"; RESTORED="/tmp/fc-ddl-restored.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$RESTORED"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/ddl.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/ddl.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ddl.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$RESTORED" /tmp/fc-ddl-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }

node_once() { # <sql> [params-js-array]
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

# --- phase 1: CREATE TABLE through fire-crab, use it through fire-crab -
check "create table" \
    "$(node_run "CREATE TABLE TDDL (ID INTEGER, NAME VARCHAR(20), SAL BIGINT, F SMALLINT, D DATE, B BOOLEAN, N NUMERIC(9,2))")" \
    "<no rows>"
check "insert into created table" \
    "$(node_run "INSERT INTO TDDL VALUES (1, 'alpha', 1000, 7, ?, ?, ?)" \
        '["2024-03-05",true,12.5]')" "<no rows>"
check "insert second row" \
    "$(node_run "INSERT INTO TDDL (ID, NAME) VALUES (2, 'beta')")" "<no rows>"
check "fire-crab reads its own table" \
    "$(node_run "SELECT ID, NAME, SAL, N FROM TDDL ORDER BY ID")" \
"1|alpha|1000|12.5
2|beta|<null>|<null>"
check "where on created table" \
    "$(node_run "SELECT ID FROM TDDL WHERE NAME LIKE 'al%'")" "1"
# a duplicate CREATE and an unsupported DDL verb both raise SQL errors
case "$(node_run "CREATE TABLE TDDL (X INTEGER)")" in
    ERR*) echo "OK   duplicate table name refused" ;;
    *) echo "DIFF duplicate table name refused"; fail=1 ;;
esac
# CREATE INDEX, DROP TABLE, ALTER TABLE ADD/DROP/ALTER TYPE are supported
# (ddl2 / serve-real-alter / serve-real-altertype); a genuinely unsupported
# form must still raise a real SQL error - DROP CONSTRAINT is not a column
# operation this server implements
case "$(node_run "ALTER TABLE TDDL DROP CONSTRAINT NOSUCH")" in
    ERR*) echo "OK   unsupported ALTER form raises an error" ;;
    *) echo "DIFF unsupported ALTER form raises an error"; fail=1 ;;
esac
case "$(node_run "RECREATE TABLE TDDL (X INTEGER)")" in
    ERR*) echo "OK   unsupported RECREATE raises an error" ;;
    *) echo "DIFF unsupported RECREATE raises an error"; fail=1 ;;
esac

# --- phase 2: the ENGINE adopts the table ------------------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full before engine writes" "$(printf '%s' "$val" | strip)" ""

engine_rows=$(run_isql <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || TRIM(NAME) || '|' || COALESCE(CAST(SAL AS VARCHAR(12)),'<null>') || '|' || COALESCE(CAST(D AS VARCHAR(12)),'<null>') || '|' || COALESCE(CAST(B AS VARCHAR(6)),'<null>') || '|' || COALESCE(CAST(N AS VARCHAR(12)),'<null>') FROM TDDL ORDER BY ID;
EOF
)
check "ENGINE reads the fire-crab table" "$engine_rows" \
"1|alpha|1000|2024-03-05|TRUE|12.50
2|beta|<null>|<null>|<null>|<null>"

field_list=$(run_isql <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT RDB$FIELD_ID || ':' || TRIM(RDB$FIELD_NAME) FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME='TDDL' ORDER BY RDB$FIELD_ID;
EOF
)
check "ENGINE sees fields in declaration order" "$field_list" \
"$(printf '0:ID\n1:NAME\n2:SAL\n3:F\n4:D\n5:B\n6:N')"

run_isql <<'EOF' >/dev/null 2>&1 || { echo "DIFF engine INSERT into fire-crab table"; fail=1; }
INSERT INTO TDDL VALUES (3, 'engine row', 3000, 1, DATE '2025-01-01', FALSE, 7.25);
COMMIT;
EOF
check "ENGINE writes into it, count agrees" \
    "$(run_isql <<< 'SET HEADING OFF; SELECT COUNT(*) FROM TDDL;' | tr -d ' \n')" "3"

# the engine's own DDL on top: sequences must survive
run_isql <<'EOF' >/dev/null 2>&1 || { echo "DIFF engine CREATE TABLE on top"; fail=1; }
CREATE TABLE T2 (X INTEGER);
COMMIT;
INSERT INTO T2 VALUES (42);
COMMIT;
EOF
check "ENGINE creates its own table beside ours" \
    "$(run_isql <<< 'SET HEADING OFF; SELECT X FROM T2;' | tr -d ' \n')" "42"

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full after engine writes" "$(printf '%s' "$val" | strip)" ""

# --- phase 3: gbak restore = the engine REPLAYS our catalog as DDL -----
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-ddl-work.fbk >/dev/null 2>&1 &&
   "$GBAK" -c -user "$U" -pas "$P" /tmp/fc-ddl-work.fbk "$RESTORED" >/dev/null 2>&1; then
    echo "OK   gbak backup + restore"
else
    echo "DIFF gbak backup + restore"; fail=1
fi
check "restored copy serves the table" \
    "$("$ISQL" -q -b -user "$U" -pas "$P" "$RESTORED" <<< 'SET HEADING OFF; SELECT COUNT(*) FROM TDDL;' | tr -d ' \n')" "3"

# --- phase 4: the ENGINE DROPs the fire-crab table ---------------------
run_isql <<'EOF' >/dev/null 2>&1 || { echo "DIFF engine DROP of fire-crab table"; fail=1; }
DROP TABLE TDDL;
COMMIT;
EOF
check "ENGINE drops it through our catalog rows" \
    "$(run_isql <<< $'SET HEADING OFF; SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = \x27TDDL\x27;' | tr -d ' \n')" "0"
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full after the drop" "$(printf '%s' "$val" | strip)" ""
exit $fail
