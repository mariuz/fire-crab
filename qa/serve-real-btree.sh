#!/bin/bash
# INDEX MAINTENANCE: DML on indexed tables. fire-crab builds index keys
# byte-exactly as btr.cpp compress() does (doubles for INTEGER,
# INT64_KEY for BIGINT, pad-stripped bytes for text), inserts them with
# btn.h's prefix-compressed node encoding, splits full pages exactly as
# split_and_insert (END_BUCKET midpoint on the left, full-key first
# node on the right, parent propagation), and grows a NEW ROOT when the
# root splits. DELETE touches no index (the engine's VIO_erase does not
# either); UPDATE adds entries for changed keys (IDX_modify).
#
# The oracles could not be sharper:
#   - the ENGINE READS THROUGH THE INDEX: isql point lookups, range
#     scans and ORDER BY navigations - with PLAN output asserted to
#     name the index - must find exactly the rows fire-crab wrote;
#   - gfix -v -full cross-checks every record against every index
#     entry: one wrong key byte and it screams;
#   - a duplicate PRIMARY KEY insert is refused; unsupported index
#     shapes: DESCENDING accepts DML too (serve-real-multiseg.sh
#     proves the engine reads those keys back);
#   - the engine applying the SAME statements to a second copy prints
#     the identical table, and gfix -sweep leaves everything clean.
#
#   qa/serve-real-btree.sh [port]
#
# Builds its own scratch database. 2000 inserts push the PK index
# through leaf splits AND a root split (one 8K leaf holds ~800 keys).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4072}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/btree_src.fdb"; CLEAN="$DIR/btree_clean.fdb"
WORK="/tmp/fc-btree-work.fdb"; REF="/tmp/fc-btree-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(40), N BIGINT);
CREATE INDEX T_NAME ON T (NAME);
CREATE INDEX T_N ON T (N);
CREATE TABLE TDESC (ID INTEGER);
CREATE DESCENDING INDEX TDESC_ID ON TDESC (ID);
COMMIT;
INSERT INTO T VALUES (1, 'seed one', 1000);
INSERT INTO T VALUES (2, 'seed two', 2000);
INSERT INTO T VALUES (3, NULL, NULL);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/btree.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/btree.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-btree.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" /tmp/fc-btree-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }
isql_q() {
    printf 'SET HEADING OFF;\n%s\n' "$1" | run_isql | strip | grep -v '^$'
}

node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 20 node -e '
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
node_run() {
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

# --- phase 1: 2000 inserts - three indexes maintained, PK root splits --
bulk=$(FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" timeout 240 node -e '
  process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    const Q="\u0027";
    let i=10;
    const next=()=>{
      if(i>=2010){console.log("DONE "+(i-10));db.detach();process.exit(0);}
      i++;
      db.query("INSERT INTO T VALUES ("+i+", "+Q+"row "+i+Q+", "+(i*1000000)+")",(e2)=>{
        if(e2){console.log("ERR at "+i+": "+(e2.message||"").split("\n")[0]);process.exit(0);}
        next();
      });
    };
    next();
  });' 2>/dev/null)
check "2000 inserts into a 3-index table" "$bulk" "DONE 2000"
check "fire-crab count" "$(node_run "SELECT COUNT(*) FROM T")" "2003"

# duplicate PRIMARY KEY refused, nothing written
case "$(node_run "INSERT INTO T VALUES (500, 'dup', 1)")" in
    ERR*) echo "OK   duplicate PRIMARY KEY is refused" ;;
    *) echo "DIFF duplicate PRIMARY KEY is refused"; fail=1 ;;
esac
check "  ..count unchanged" "$(node_run "SELECT COUNT(*) FROM T")" "2003"

# UPDATE changes an indexed key; DELETE some rows (no index work needed)
check "update an indexed key" \
    "$(node_run "UPDATE T SET NAME = 'renamed row' WHERE ID = 1500")" "<no rows>"
check "delete rows" \
    "$(node_run "DELETE FROM T WHERE ID > 2000")" "<no rows>"
check "  ..count after delete" "$(node_run "SELECT COUNT(*) FROM T")" "1993"

# DESCENDING indexes are maintained now (increment 31) - the insert
# succeeds; qa/serve-real-multiseg.sh proves the engine reads the
# complemented keys back
check "DESCENDING-index table accepts DML now" \
    "$(node_run "INSERT INTO TDESC VALUES (1)")" "<no rows>"

# --- phase 2: the ENGINE reads through the indexes fire-crab wrote -----
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the plan must name the index - these are index scans, not table scans
plan=$(printf 'SET PLAN;\nSET HEADING OFF;\nSELECT ID FROM T WHERE ID = 1500;\n' | run_isql | strip)
if printf '%s\n' "$plan" | grep -q 'INDEX (.*RDB\$PRIMARY' && printf '%s\n' "$plan" | grep -q "^1500$"; then
    echo "OK   engine point lookup THROUGH the PK index"
else
    echo "DIFF engine point lookup THROUGH the PK index"; echo "     got: $plan"; fail=1
fi
check "engine range scan via the PK index" \
    "$(isql_q "SELECT COUNT(*) FROM T WHERE ID BETWEEN 100 AND 300;" | tr -d ' ')" "201"
check "engine lookup via the NAME index" \
    "$(isql_q "SELECT ID FROM T WHERE NAME = 'row 1234';" | tr -d ' ')" "1234"
check "engine range via the BIGINT index" \
    "$(isql_q "SELECT COUNT(*) FROM T WHERE N BETWEEN 100000000 AND 200000000;" | tr -d ' ')" "101"
check "navigational ORDER BY through the index" \
    "$(isql_q "SELECT FIRST 3 ID FROM T ORDER BY ID;" | tr -d ' ')" "1
2
3"
# the updated key: found under the NEW name, not under the old
check "updated key found via the index" \
    "$(isql_q "SELECT ID FROM T WHERE NAME = 'renamed row';" | tr -d ' ')" "1500"
check "  ..old key finds nothing" \
    "$(isql_q "SELECT COUNT(*) FROM T WHERE NAME = 'row 1500';" | tr -d ' ')" "0"
# deleted rows invisible through the index
check "deleted rows invisible via the index" \
    "$(isql_q "SELECT COUNT(*) FROM T WHERE ID = 2005;" | tr -d ' ')" "0"

# --- phase 3: structural validation + the engine's own mirror ----------
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full accepts records AND index entries" "$(printf '%s' "$val" | strip)" ""

{
    i=10
    while [ $i -lt 2010 ]; do
        i=$((i + 1))
        echo "INSERT INTO T VALUES ($i, 'row $i', $((i * 1000000)));"
    done
    echo "UPDATE T SET NAME = 'renamed row' WHERE ID = 1500;"
    echo "DELETE FROM T WHERE ID > 2000;"
    echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1
dump() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || COALESCE(NAME,'<null>') || '|' || COALESCE(CAST(N AS VARCHAR(20)),'<null>') FROM T ORDER BY ID;
EOF
}
check "fire-crab-written == engine-written table" "$(dump "$WORK")" "$(dump "$REF")"

"$GFIX" -sweep -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "clean after sweep (engine GCs the stale entries)" "$(printf '%s' "$val" | strip)" ""
check "data survives the sweep" "$(isql_q "SELECT COUNT(*) FROM T;" | tr -d ' ')" "1993"
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-btree-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi
exit $fail
