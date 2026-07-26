#!/bin/bash
# ALTER TABLE ALTER COLUMN TYPE through fire-crab. Like ADD/DROP, a type
# change is a new FORMAT VERSION: existing records keep their old format
# and their old-width value (an INTEGER stored 4 bytes reads back as the
# new BIGINT); new records use the new format. The column keeps its field
# id, position and domain; the domain's RDB$FIELDS row is retyped in place,
# RDB$RUNTIME is rebuilt for the new length, RDB$RELATIONS.RDB$FORMAT bumps.
# Only a widening conversion is performed - a narrowing errors, as the
# engine's does.
#
# THE differential: the C++ ENGINE opens fire-crab's file and reads it
# byte-identically to the same ALTERs applied by its own DDL to a REFERENCE
# copy - old rows promoted, new-format rows at full width - then WRITES its
# own row and gbak RESTORES it (replaying the catalog as real engine DDL).
#
#   qa/serve-real-altertype.sh [port]
#
# Builds its own scratch database (charset NONE).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4083}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/atype_src.fdb"; CLEAN="$DIR/atype_clean.fdb"
WORK="/tmp/fc-atype-work.fdb"; REF="/tmp/fc-atype-ref.fdb"; RESTORED="/tmp/fc-atype-restored.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$REF" "$RESTORED"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B VARCHAR(5), C SMALLINT);
CREATE TABLE G (PK INTEGER NOT NULL PRIMARY KEY, UQ INTEGER CONSTRAINT GU UNIQUE, PI INTEGER, K1 INTEGER NOT NULL, K2 INTEGER NOT NULL, CONSTRAINT GK UNIQUE (K1, K2));
CREATE TABLE GC (FK INTEGER REFERENCES G (PK));
CREATE INDEX GPI ON G (PI);
COMMIT;
INSERT INTO T VALUES (1000000, 'xy', 42);
INSERT INTO T VALUES (2000000, 'zz', 7);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/atype.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/atype.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"

# the engine applies the SAME widenings to REF, as the oracle:
# A -> BIGINT (integer family), B -> VARCHAR(10) and C -> INTEGER
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<EOF >/dev/null 2>&1
ALTER TABLE T ALTER A TYPE BIGINT;
ALTER TABLE T ALTER B TYPE VARCHAR(10);
ALTER TABLE T ALTER C TYPE INTEGER;
ALTER TABLE G ALTER PI TYPE BIGINT;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-atype.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$RESTORED" "$DIR/atype.fbk" /tmp/fc-atype-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$1"; }

node_once() { # <db> <sql> [params]
    FC_DB="$1" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$2" FC_PARAMS="${3:-[]}" \
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
        r=$(node_once "$WORK" "$1" "${2:-[]}")
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

# --- phase 1: TYPE changes through fire-crab ---------------------------
check "widen integer to bigint"  "$(node_run "ALTER TABLE T ALTER A TYPE BIGINT")"         "<no rows>"
check "widen varchar"            "$(node_run "ALTER TABLE T ALTER COLUMN B TYPE VARCHAR(10)")" "<no rows>"
check "widen smallint to int"    "$(node_run "ALTER TABLE T ALTER C TYPE INTEGER")"        "<no rows>"
# old records read back promoted to the new types
check "old rows read promoted"   "$(node_run "SELECT A, B, C FROM T ORDER BY A")" \
"1000000|xy|42
2000000|zz|7"
# a new-format row carries values the OLD types could not hold: A beyond
# 32-bit INTEGER, B beyond 5 characters, C beyond 16-bit SMALLINT
check "insert wide new-format row" \
    "$(node_run "INSERT INTO T VALUES (?, ?, ?)" '[9000000000,"abcdefghij",40000]')" "<no rows>"
check "fire-crab reads wide row"  "$(node_run "SELECT A, B, C FROM T WHERE A > 3000000000")" \
"9000000000|abcdefghij|40000"
# a narrowing conversion is refused, exactly as the engine refuses it
case "$(node_run "ALTER TABLE T ALTER A TYPE SMALLINT")" in
    ERR*) echo "OK   narrowing conversion refused" ;;
    *) echo "DIFF narrowing conversion refused"; fail=1 ;;
esac
case "$(node_run "ALTER TABLE T ALTER NOSUCH TYPE BIGINT")" in
    ERR*) echo "OK   retype of missing column refused" ;;
    *) echo "DIFF retype of missing column refused"; fail=1 ;;
esac
# a column whose index enforces an integrity constraint cannot be
# retyped - "Cannot update index segment used by an Integrity
# Constraint" (probed: PK, UNIQUE and FK-child segments refuse, ANY
# segment of a multi-column key; a plain CREATE INDEX column is fine)
for stmt in "ALTER TABLE G ALTER PK TYPE BIGINT" \
            "ALTER TABLE G ALTER UQ TYPE BIGINT" \
            "ALTER TABLE GC ALTER FK TYPE BIGINT" \
            "ALTER TABLE G ALTER K2 TYPE BIGINT"; do
    case "$(node_run "$stmt")" in
        ERR*) echo "OK   constraint-index column refused: ${stmt#ALTER TABLE }" ;;
        *) echo "DIFF constraint refusal: $stmt"; fail=1 ;;
    esac
done
check "a PLAIN-indexed column still retypes" \
    "$(node_run 'ALTER TABLE G ALTER PI TYPE BIGINT')" "<no rows>"

# --- phase 2: the ENGINE adopts fire-crab's retyped file ---------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the engine refuses the same constrained retype on fc's file - the
# constraint metadata fc preserved is what makes it refuse
engref=$("$ISQL" -q -user "$U" -pas "$P" "$WORK" 2>&1 <<< "ALTER TABLE G ALTER PK TYPE BIGINT;")
case "$engref" in
    *"Integrity Constraint"*) echo "OK   the engine refuses the same retype on fc's file" ;;
    *) echo "DIFF engine-side constraint refusal"; echo "     $engref"; fail=1 ;;
esac

# rows 1-2 exist on both WORK and REF (same ALTERs); compare via SET LIST
w12=$(run_isql "$WORK" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT A, B, C FROM T WHERE A < 3000000000 ORDER BY A;
EOF
)
r12=$(run_isql "$REF" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT A, B, C FROM T WHERE A < 3000000000 ORDER BY A;
EOF
)
check "engine reads WORK == engine reads REF" "$w12" "$r12"

sw=$(echo "SHOW TABLE T;" | run_isql "$WORK" 2>&1 | strip | grep -v '^$')
sr=$(echo "SHOW TABLE T;" | run_isql "$REF" 2>&1 | strip | grep -v '^$')
check "SHOW TABLE WORK == REF" "$sw" "$sr"

# the engine reads fire-crab's own wide new-format row
w3=$(run_isql "$WORK" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT A, B, C FROM T WHERE A > 3000000000;
EOF
)
check "engine reads fire-crab's wide row" "$(echo $w3)" "A 9000000000 B abcdefghij C 40000"

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean" "$(printf '%s' "$val" | strip)" ""

# the engine WRITES a wide row of its own into fire-crab's retyped table
run_isql "$WORK" <<EOF >/dev/null 2>&1
INSERT INTO T VALUES (8000000000, 'klmnopqrst', 50000);
COMMIT;
EOF
cnt=$(run_isql "$WORK" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT COUNT(*) AS N FROM T;
EOF
)
check "engine writes a wide row" "$(echo $cnt)" "N 4"

# gbak backup+restore: replays the catalog as real engine-side DDL
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-atype-work.fbk >/dev/null 2>&1 &&
   "$GBAK" -c -user "$U" -pas "$P" /tmp/fc-atype-work.fbk "$RESTORED" >/dev/null 2>&1; then
    rr=$(run_isql "$RESTORED" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT A, B, C FROM T WHERE A > 3000000000 AND A < 9000000000;
EOF
)
    check "gbak restore preserves the retyped columns" "$(echo $rr)" "A 8000000000 B klmnopqrst C 50000"
else
    echo "DIFF gbak backup/restore"; fail=1
fi

exit $fail
