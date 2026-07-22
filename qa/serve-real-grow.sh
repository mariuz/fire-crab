#!/bin/bash
# WRITE-PATH PAGE ALLOCATION: INSERT grows the table. When every data
# page is full, fire-crab allocates a page from the PIP (first free bit
# cleared, pip_used/pip_min maintained, the FILE extended when the page
# lies past EOF), formats it, and hooks it into the relation's last
# pointer page with its fill-bits byte - PAG_allocate_pages + the
# DPM_allocate/extend path. Back versions grow the relation the same
# way, so an UPDATE storm over full pages works too.
#
# The oracle is the engine: after 250 inserts (several pages of growth)
# and an update storm through fire-crab,
#   - isql reads the same table the engine produces from the SAME
#     statements applied to a second copy of the clean db;
#   - gfix -v -full validates the allocation bookkeeping fire-crab
#     wrote - PIP bits, pointer-page slots and fill bytes, page
#     headers;
#   - gfix -sweep collects the update storm's chains; gbak backs up.
#
# GIDX (a PRIMARY KEY table) additionally exercises the index write
# path: its insert and delete must maintain the PK index the engine
# then validates.
#
#   qa/serve-real-grow.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
GSTAT="${GSTAT:-gstat}"
PORT="${1:-4067}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/grow_src.fdb"; CLEAN="$DIR/grow_clean.fdb"
WORK="/tmp/fc-grow-work.fdb"; REF="/tmp/fc-grow-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

PADX=$(printf 'x%.0s' $(seq 1 160))
rm -f "$SRC" "$CLEAN" "$WORK" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE G (ID INTEGER, PAD VARCHAR(200));
CREATE TABLE GIDX (ID INTEGER NOT NULL PRIMARY KEY);
COMMIT;
INSERT INTO G VALUES (1, 'seed one');
INSERT INTO G VALUES (2, 'seed two');
INSERT INTO G VALUES (3, 'seed three');
INSERT INTO GIDX VALUES (1);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/grow.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/grow.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"
dp_count() { "$GSTAT" -user "$U" -pas "$P" -t G "$1" 2>/dev/null | grep -i "Data pages:" | grep -o '[0-9]*' | head -1; }
dp_before=$(dp_count "$WORK")

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-grow.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" /tmp/fc-grow-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }

node_once() { # one statement
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

# --- phase 1: 250 inserts on ONE connection - the table must grow -----
bulk=$(FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_PAD="$PADX" timeout 120 node -e '
  process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    const Q="\u0027"; // a single quote, kept out of the shell quoting
    let i=3;
    const next=()=>{
      if(i>=253){console.log("DONE "+(i-3));db.detach();process.exit(0);}
      i++;
      db.query("INSERT INTO G VALUES ("+i+", "+Q+"row "+i+" "+process.env.FC_PAD+Q+")",(e2)=>{
        if(e2){console.log("ERR at "+i+": "+(e2.message||"").split("\n")[0]);process.exit(0);}
        next();
      });
    };
    next();
  });' 2>/dev/null)
check "250 inserts through one connection" "$bulk" "DONE 250"

check "fire-crab reads all rows back" "$(node_run "SELECT COUNT(*) FROM G")" "253"
check "  ..spot row on a grown page" \
    "$(node_run "SELECT ID FROM G WHERE ID = 250")" "250"
# growth teeth via gstat (the engine's own page accounting): the
# relation must hold several more data pages than it started with -
# whether the pages came from free bits below EOF (a gbak-restored
# file keeps some) or extended the file
dp_after=$(dp_count "$WORK")
if [ -n "$dp_after" ] && [ "$dp_after" -ge $(( ${dp_before:-0} + 5 )) ]; then
    echo "OK   the relation grew (data pages ${dp_before:-?} -> $dp_after per gstat)"
else
    echo "DIFF the relation grew"; echo "     data pages ${dp_before:-?} -> ${dp_after:-?}"; fail=1
fi

# --- phase 2: an update storm over the grown, full pages ---------------
check "update storm (back versions need fresh pages)" \
    "$(node_run "UPDATE G SET PAD = 'updated' WHERE ID > 200")" "<no rows>"
check "  ..all 53 updated" \
    "$(node_run "SELECT COUNT(*) FROM G WHERE PAD = 'updated'")" "53"

# --- phase 3: DML on the indexed table (PK maintained) ------------------
check "INSERT into the indexed table" "$(node_run "INSERT INTO GIDX VALUES (2)")" "<no rows>"
check "DELETE from the indexed table" "$(node_run "DELETE FROM GIDX WHERE ID = 1")" "<no rows>"

# --- phase 4: the REAL ENGINE mirrors and validates ---------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

{
    i=3
    while [ $i -lt 253 ]; do
        i=$((i + 1))
        echo "INSERT INTO G VALUES ($i, 'row $i $PADX');"
    done
    echo "UPDATE G SET PAD = 'updated' WHERE ID > 200;"
    echo "COMMIT;"
} | "$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1

dump() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || CHAR_LENGTH(PAD) || '|' || SUBSTRING(PAD FROM 1 FOR 12) FROM G ORDER BY ID;
EOF
}
work_rows=$(dump "$WORK"); ref_rows=$(dump "$REF")
[ -n "$work_rows" ] || { echo "DIFF engine read of the work file"; fail=1; }
check "fire-crab-written == engine-written table (253 rows)" "$work_rows" "$ref_rows"
check "GIDX reflects the indexed DML (engine-read)" \
    "$(run_isql <<<'SET HEADING OFF; SELECT ID FROM GIDX;' | tr -d ' \n')" "2"

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full accepts the allocation bookkeeping" "$(printf '%s' "$val" | strip)" ""
"$GFIX" -sweep -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "clean after sweep too" "$(printf '%s' "$val" | strip)" ""
check "data survives the sweep" "$(dump "$WORK")" "$ref_rows"
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-grow-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi
exit $fail
