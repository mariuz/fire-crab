#!/bin/bash
# MULTI-SEGMENT + DESCENDING INDEXES: the two index shapes real schemas
# are full of, previously refused. Compound keys are assembled exactly
# as BTR_key (btr.cpp:2245) assembles them - each segment compressed
# individually, then interleaved into 5-byte groups: a marker byte (the
# number of segments remaining, including the current one) followed by
# up to STUFF_COUNT(4) data bytes, the group zero-padded when a segment
# ends. A DESCENDING index complements the WHOLE assembled key -
# markers and padding included (BTR_complement_key runs after
# assembly); a descending NULL is a single pre-complement 0x00 byte.
# Uniqueness follows the engine's rule: only an ALL-NULL key is exempt
# (btr.cpp:5629 key_all_nulls).
#
# The differential oracle is the REAL ENGINE:
#
#   1. 1500 rows inserted through fire-crab into a table whose PRIMARY
#      KEY is compound (INTEGER, VARCHAR) - wide stuffed keys force
#      leaf splits; the engine then reads THROUGH that tree with
#      PLAN-asserted index scans;
#   2. descending single-column and descending COMPOUND indexes get
#      rows through fire-crab; the engine's point lookups and
#      navigational ORDER BY ... DESC scans go through those trees
#      (PLAN asserted again);
#   3. unique-with-NULLs semantics, the ENGINE'S actual rule
#      (btr.cpp:5629, confirmed against the live engine when this
#      gate's first draft assumed otherwise): only an ALL-NULL key is
#      unique-exempt - a partial-NULL compound key still validates,
#      so (NULL,2) twice is refused while (NULL,NULL) twice is not;
#   4. gfix -v -full cross-checks EVERY record against EVERY index
#      entry - one wrong marker, pad or complement byte and it
#      reports; gbak walks the whole file; the engine applies the
#      same statements to a second copy -> identical tables.
#
#   qa/serve-real-multiseg.sh [port]
#
# Builds its own scratch database. (The descending 0x01 end-value
# guard - values whose pre-complement image starts 0x00/0x01 - is
# unreachable from INTEGER/VARCHAR data and is covered by unit tests
# against btr.cpp:3978 instead.)

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4074}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/multiseg_src.fdb"; CLEAN="$DIR/multiseg_clean.fdb"
WORK="/tmp/fc-multiseg-work.fdb"; REF="/tmp/fc-multiseg-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE TC (A INTEGER NOT NULL, B VARCHAR(10) NOT NULL, PAYLOAD BIGINT,
                 PRIMARY KEY (A, B));
CREATE TABLE TD (ID INTEGER, S VARCHAR(10));
CREATE DESCENDING INDEX TD_ID_DESC ON TD (ID);
CREATE TABLE TDC (A INTEGER, B VARCHAR(10), V BIGINT);
CREATE DESCENDING INDEX TDC_AB_DESC ON TDC (A, B);
CREATE TABLE TU (X INTEGER, Y INTEGER);
CREATE UNIQUE INDEX TU_XY ON TU (X, Y);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/multiseg.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/multiseg.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-multiseg.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" /tmp/fc-multiseg-work.fbk' EXIT
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
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; }

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

# --- phase 1: 1500 rows through the compound PRIMARY KEY ---------------
# stuffed (marker-interleaved) keys are ~1.9x wider than their data, so
# 1500 (int, varchar) keys overflow an 8K leaf many times over - splits
bulk=$(FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" timeout 240 node -e '
  process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    const Q="\u0027";
    let i=0;
    const next=()=>{
      if(i>=1500){console.log("DONE "+i);db.detach();process.exit(0);}
      i++;
      // A cycles 0..99 so each A carries ~15 different Bs: both
      // segments genuinely discriminate
      db.query("INSERT INTO TC VALUES ("+(i%100)+", "+Q+"b"+i+Q+", "+(i*7)+")",(e2)=>{
        if(e2){console.log("ERR at "+i+": "+(e2.message||"").split("\n")[0]);process.exit(0);}
        next();
      });
    };
    next();
  });' 2>/dev/null)
check "1500 inserts through the compound PK" "$bulk" "DONE 1500"
check "fire-crab count" "$(node_run "SELECT COUNT(*) FROM TC")" "1500"

# a genuine compound duplicate is refused; same A with a new B is fine
case "$(node_run "INSERT INTO TC VALUES (7, 'b7', 0)")" in
    ERR*) echo "OK   duplicate compound PK is refused" ;;
    *) echo "DIFF duplicate compound PK is refused"; fail=1 ;;
esac
check "same A, different B accepted" \
    "$(node_run "INSERT INTO TC VALUES (7, 'other', 1)")" "<no rows>"

# --- phase 2: descending indexes get rows ------------------------------
for v in "(5, 'five')" "(-3, 'minus')" "(1200, 'big')" "(NULL, 'nul')"; do
    r=$(node_run "INSERT INTO TD VALUES $v")
    [ "$r" = "<no rows>" ] || { echo "DIFF TD insert $v"; fail=1; }
done
echo "OK   descending-index rows inserted (incl. negative + NULL keys)"
for v in "(1, 'aa', 10)" "(1, 'bb', 20)" "(2, 'aa', 30)" "(NULL, NULL, 40)"; do
    r=$(node_run "INSERT INTO TDC VALUES $v")
    [ "$r" = "<no rows>" ] || { echo "DIFF TDC insert $v"; fail=1; }
done
echo "OK   descending-COMPOUND rows inserted"

# --- phase 3: unique-with-NULLs on a compound UNIQUE index -------------
check "unique compound: first row" \
    "$(node_run "INSERT INTO TU VALUES (1, 2)")" "<no rows>"
case "$(node_run "INSERT INTO TU VALUES (1, 2)")" in
    ERR*) echo "OK   unique compound duplicate refused" ;;
    *) echo "DIFF unique compound duplicate refused"; fail=1 ;;
esac
check "partial-NULL key accepted once" \
    "$(node_run "INSERT INTO TU VALUES (NULL, 2)")" "<no rows>"
case "$(node_run "INSERT INTO TU VALUES (NULL, 2)")" in
    ERR*) echo "OK   partial-NULL duplicate refused (engine rule)" ;;
    *) echo "DIFF partial-NULL duplicate refused (engine rule)"; fail=1 ;;
esac
check "all-NULL key exempt from unique (1st)" \
    "$(node_run "INSERT INTO TU VALUES (NULL, NULL)")" "<no rows>"
check "all-NULL key exempt from unique (2nd)" \
    "$(node_run "INSERT INTO TU VALUES (NULL, NULL)")" "<no rows>"

# --- phase 4: the ENGINE reads through the trees fire-crab wrote -------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

plan_check() { # <label> <sql> <index-name> <expected rows...>
    local label="$1" sql="$2" idx="$3" want="$4"
    local out
    out=$(printf 'SET PLAN;\nSET HEADING OFF;\n%s\n' "$sql" | run_isql | strip | grep -v '^$')
    if printf '%s\n' "$out" | grep -q "INDEX (.*$idx" &&
       [ "$(printf '%s\n' "$out" | grep -v 'PLAN ')" = "$want" ]; then
        echo "OK   $label"
    else
        echo "DIFF $label"
        echo "     want: $want (via $idx)"
        echo "     got:  $out"
        fail=1
    fi
}
order_plan_check() { # navigational ORDER plans print ORDER, not INDEX
    local label="$1" sql="$2" idx="$3" want="$4"
    local out
    out=$(printf 'SET PLAN;\nSET HEADING OFF;\n%s\n' "$sql" | run_isql | strip | grep -v '^$')
    if printf '%s\n' "$out" | grep -q "ORDER .*$idx" &&
       [ "$(printf '%s\n' "$out" | grep -v 'PLAN ')" = "$want" ]; then
        echo "OK   $label"
    else
        echo "DIFF $label"
        echo "     want: $want (ORDER $idx)"
        echo "     got:  $out"
        fail=1
    fi
}

plan_check "engine compound-PK point lookup" \
    "SELECT PAYLOAD FROM TC WHERE A = 7 AND B = 'b7';" 'RDB\$PRIMARY' "49"
plan_check "engine compound-PK partial-key scan" \
    "SELECT COUNT(*) FROM TC WHERE A = 7;" 'RDB\$PRIMARY' "16"
plan_check "engine descending point lookup" \
    "SELECT S FROM TD WHERE ID = -3;" "TD_ID_DESC" "minus"
# the table is tiny, so the optimizer would SORT on its own - FORCE the
# navigational plan: the engine must then walk our complemented tree in
# order, and a wrong byte shows up as wrong row order (or an error)
order_plan_check "engine navigational DESC scan (forced plan)" \
    "SELECT ID FROM TD WHERE ID IS NOT NULL PLAN (TD ORDER TD_ID_DESC) ORDER BY ID DESC;" \
    "TD_ID_DESC" \
"$(printf '1200\n5\n-3')"
plan_check "engine descending-compound lookup" \
    "SELECT V FROM TDC WHERE A = 1 AND B = 'bb';" "TDC_AB_DESC" "20"

# --- phase 5: engine mirror + structural cross-check -------------------
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<'EOF' >/tmp/fc-multiseg-ref.log 2>&1 || { echo "DIFF engine-side statements failed:"; head -6 /tmp/fc-multiseg-ref.log; fail=1; }
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 1500) DO BEGIN
    I = I + 1;
    INSERT INTO TC VALUES (MOD(:I, 100), 'b' || :I, :I * 7);
  END
END^
SET TERM ;^
INSERT INTO TC VALUES (7, 'other', 1);
INSERT INTO TD VALUES (5, 'five'); INSERT INTO TD VALUES (-3, 'minus');
INSERT INTO TD VALUES (1200, 'big'); INSERT INTO TD VALUES (NULL, 'nul');
INSERT INTO TDC VALUES (1, 'aa', 10); INSERT INTO TDC VALUES (1, 'bb', 20);
INSERT INTO TDC VALUES (2, 'aa', 30); INSERT INTO TDC VALUES (NULL, NULL, 40);
INSERT INTO TU VALUES (1, 2); INSERT INTO TU VALUES (NULL, 2);
INSERT INTO TU VALUES (NULL, NULL); INSERT INTO TU VALUES (NULL, NULL);
COMMIT;
EOF
mirror() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT COUNT(*) || '/' || SUM(PAYLOAD) FROM TC;
SELECT COUNT(*) || '/' || SUM(ID) FROM TD;
SELECT COUNT(*) || '/' || SUM(V) FROM TDC;
SELECT COUNT(*) || '/' || SUM(Y) FROM TU;
EOF
}
check "ENGINE same-statements mirror agrees" "$(mirror "$WORK")" "$(mirror "$REF")"

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full cross-checks every entry" "$(printf '%s' "$val" | strip)" ""
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-multiseg-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi
exit $fail
