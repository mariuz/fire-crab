#!/bin/bash
# PARAMETER BINDING: the server prepares statements with `?` markers,
# announces each parameter's target type in the describe's BIND section
# (which is what real clients build their encoders from), then decodes
# the op_execute message - the client's own value-derived BLR + null
# bitmap + XDR values - and binds the values into the plan: INSERT
# images, UPDATE SET bytes, WHERE comparisons. Coercions mirror the
# engine's CVT rules (ints rescale exactly into NUMERIC, doubles round
# half-away, a blr_timestamp truncates into DATE/TIME, blr_bool into
# BOOLEAN).
#
# The differential oracle is the REAL ENGINE, three ways:
#
#   1. node-firebird drives parameterised INSERT/UPDATE/DELETE/SELECT
#      through fire-crab (node's encoders are 3rd-party code keyed off
#      our describe - a wrong bind section or message decode shows up
#      as wrong values, hangs, or client-side errors);
#   2. the C++ engine applies the LITERAL equivalents of the same
#      statements to a second copy of the same clean database - isql
#      must print IDENTICAL final tables from both files (timestamps,
#      dates, times, booleans, scaled numerics included);
#   3. gfix -v -full accepts the file fire-crab wrote (the PK index
#      entries for param-bound keys included), and gbak walks it.
#
# SQL semantics asserted on the way: a NULL parameter in a comparison
# is UNKNOWN (no rows - NOT "ID = NULL matches nulls"), a parameter
# whose wire type cannot bind its column raises an SQL error at
# execute (never a wrong row set), and a lone aggregate over a
# parameterised WHERE computes at fetch (the group machinery), not at
# prepare.
#
#   qa/serve-real-params.sh [port]
#
# Builds its own scratch database: PT(ID INT PK, NAME VARCHAR, SAL
# NUMERIC(9,2), HIRED TIMESTAMP, DOB DATE, T0 TIME, ACTIVE BOOLEAN).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4058}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/params_src.fdb"; CLEAN="$DIR/params_clean.fdb"
WORK="/tmp/fc-params-work.fdb"; REF="/tmp/fc-params-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

# --- build the scratch database ----------------------------------------
rm -f "$SRC" "$CLEAN" "$WORK" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE PT (
  ID INTEGER NOT NULL PRIMARY KEY,
  NAME VARCHAR(20),
  SAL NUMERIC(9,2),
  HIRED TIMESTAMP,
  DOB DATE,
  T0 TIME,
  ACTIVE BOOLEAN
);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/params.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/params.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"
cp "$CLEAN" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-params.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" /tmp/fc-params-work.fbk' EXIT
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

# run one statement through fire-crab with a parameter array (a JS
# array expression - dates need Date objects, which JSON cannot carry);
# rows (or <no rows>) on stdout, ERR <message> on a raised SQL error
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
node_run() { # retry transient first-connect failures
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

# --- phase 1: parameterised DML through fire-crab ----------------------
# every column type bound in one statement: int, text, double->NUMERIC,
# Date->TIMESTAMP, string->DATE, Date->TIME (time half). The BOOLEAN is a
# LITERAL, not a parameter: node-firebird cannot encode a JS boolean into
# a BOOLEAN slot at all - the REAL ENGINE answers `Conversion error from
# string "1"` for the parameterised form, so asking fire-crab to accept
# it would be asking it to out-do the engine. The refusal is asserted
# below instead.
check "insert all-param row (boolean as a literal)" \
    "$(node_run "INSERT INTO PT VALUES (?, ?, ?, ?, ?, ?, TRUE)" \
        '[1,"alpha",100.25,new Date(2024,0,15,10,30,0),"2024-02-20",new Date(1970,0,1,11,22,33)]')" \
    "<no rows>"
# ... and the boolean PARAMETER. This check used to assert a REFUSAL,
# because the driver could not encode a JS boolean for a BOOLEAN column
# and the engine rejected what it sent. node-firebird 2.14.1 made that
# encoding metadata-directed (a BOOLEAN target now gets a real
# blr_bool), so the ENGINE ACCEPTS IT - and so does fire-crab, which is
# the only thing that was ever being asserted. The premise expired, not
# the behaviour.
#
# It is checked against the engine directly rather than against a
# remembered verdict, which is what a stale premise costs: the four
# failures this produced all pointed at fire-crab, and none of them was
# fire-crab's.
b=$(node_run "INSERT INTO PT (ID, ACTIVE) VALUES (99, ?)" '[true]')
case "$b" in
    ERR*) echo "DIFF fire-crab refused a boolean parameter the engine accepts: [$b]"; fail=1 ;;
    *) echo "OK   a boolean PARAMETER is accepted, as the engine accepts this driver's encoding" ;;
esac
# mixed literals and params, column list; JS integral 50 arrives as
# blr_long and must rescale into NUMERIC(9,2) as 5000
check "insert mixed literal/param" \
    "$(node_run "INSERT INTO PT (ID, NAME, SAL) VALUES (2, ?, ?)" '["beta",50]')" \
    "<no rows>"
check "insert NULL params" \
    "$(node_run "INSERT INTO PT VALUES (?, ?, ?, ?, ?, ?, ?)" \
        '[3,null,null,null,null,null,null]')" \
    "<no rows>"
# SET params then WHERE params - slots number in textual order
check "update SET ? WHERE ?" \
    "$(node_run "UPDATE PT SET SAL = ? WHERE ID = ?" '[77.5,1]')" "<no rows>"
check "update text = ? WHERE text = ?" \
    "$(node_run "UPDATE PT SET NAME = ? WHERE NAME = ?" '["gamma","beta"]')" "<no rows>"
check "delete WHERE ?" \
    "$(node_run "DELETE FROM PT WHERE ID = ?" '[3]')" "<no rows>"

# --- phase 2: parameterised SELECT through fire-crab -------------------
check "select WHERE int param" \
    "$(node_run "SELECT ID, NAME FROM PT WHERE ID = ?" '[1]')" "1|alpha"
check "select WHERE text param" \
    "$(node_run "SELECT ID, SAL FROM PT WHERE NAME = ?" '["gamma"]')" "2|50"
# a lone aggregate over a parameterised WHERE cannot be computed at
# prepare - it must route through the group machinery and still agree
# 3, not 2: row 99 exists now (see the boolean parameter above)
check "count WHERE param" \
    "$(node_run "SELECT COUNT(*) FROM PT WHERE ID > ?" '[0]')" "3"
check "sum WHERE param" \
    "$(node_run "SELECT SUM(ID) FROM PT WHERE ID >= ?" '[1]')" "102"
# comparison with a NULL parameter is UNKNOWN - no rows, never "= NULL"
check "NULL param comparison is UNKNOWN" \
    "$(node_run "SELECT ID FROM PT WHERE ID = ?" '[null]')" "<no rows>"
# a text value cannot bind an integer column - SQL error, not wrong rows
case "$(node_run "SELECT ID FROM PT WHERE ID = ?" '["abc"]')" in
    ERR*) echo "OK   type-mismatched param raises an error" ;;
    *) echo "DIFF type-mismatched param raises an error"; fail=1 ;;
esac

# --- phase 3: the ENGINE applies the literal equivalents ---------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<'EOF' || { echo "FAIL engine-side statements"; fail=1; }
INSERT INTO PT VALUES (1, 'alpha', 100.25, TIMESTAMP '2024-01-15 10:30:00', DATE '2024-02-20', TIME '11:22:33', TRUE);
INSERT INTO PT (ID, NAME, SAL) VALUES (2, 'beta', 50);
INSERT INTO PT VALUES (3, NULL, NULL, NULL, NULL, NULL, NULL);
-- the literal twin of the boolean PARAMETER above, which the driver can
-- now encode and both servers now accept
INSERT INTO PT (ID, ACTIVE) VALUES (99, TRUE);
UPDATE PT SET SAL = 77.5 WHERE ID = 1;
UPDATE PT SET NAME = 'gamma' WHERE NAME = 'beta';
DELETE FROM PT WHERE ID = 3;
COMMIT;
EOF

dump() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" <<'EOF' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID || '|' || COALESCE(TRIM(NAME), '<null>') || '|' || COALESCE(CAST(SAL AS VARCHAR(14)), '<null>')
    || '|' || COALESCE(CAST(HIRED AS VARCHAR(30)), '<null>') || '|' || COALESCE(CAST(DOB AS VARCHAR(12)), '<null>')
    || '|' || COALESCE(CAST(T0 AS VARCHAR(15)), '<null>') || '|' || COALESCE(CAST(ACTIVE AS VARCHAR(6)), '<null>')
FROM PT ORDER BY ID;
EOF
}
ours=$(dump "$WORK")
theirs=$(dump "$REF")
check "ENGINE mirror table identical" "$ours" "$theirs"
# non-vacuity: the compared table really carries the bound values
case "$ours" in
    *"alpha|77.50|2024-01-15 10:30:00"*) echo "OK   bound values present in the file" ;;
    *) echo "DIFF bound values present in the file"; echo "     got:  $ours"; fail=1 ;;
esac

# --- phase 4: engine-side structural validation ------------------------
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full finds nothing wrong" "$(printf '%s' "$val" | strip)" ""
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-params-work.fbk >/dev/null 2>&1; then
    echo "OK   gbak backs the file up"
else
    echo "DIFF gbak backs the file up"; fail=1
fi

# --- phase 5: the RECORD IMAGE LENGTH itself ---------------------------
# gfix above catches an over-long image only once an UPDATE stores it
# PACKED (decompression then runs past fmt_length and the engine
# BUGCHECKs 179, sqz.cpp:502). Compare the length directly against the
# engine's own file, so a NOT_PACKED-only regression cannot hide: the
# image must be exactly met.epp:1071's fmt_length - the last descriptor's
# offset + length, with NO rounding. PT's last field is a BOOLEAN, so its
# 55 bytes do not end on a 4-boundary; rounding up to 56 was the bug.
if command -v python3 >/dev/null 2>&1; then
    lens() { # <file> -> sorted unique unpacked image lengths of relation 128
        python3 - "$1" <<'PYEOF'
import sys, struct
b = open(sys.argv[1], 'rb').read(); ps = 8192; out = set()
def unrle(d):
    o = 0; i = 0
    while i < len(d):
        c = struct.unpack_from('b', d, i)[0]; i += 1
        if c >= 0: o += c; i += c
        else:
            n = -c
            if c == -1: n = struct.unpack_from('<H', d, i)[0]; i += 2
            elif c == -2: n = struct.unpack_from('<I', d, i)[0]; i += 4
            o += n; i += 1
    return o
for p in range(len(b)//ps):
    pg = b[p*ps:(p+1)*ps]
    if pg[0] != 5 or struct.unpack_from('<H', pg, 20)[0] != 128: continue
    for s in range(struct.unpack_from('<H', pg, 22)[0]):
        off, ln = struct.unpack_from('<HH', pg, 24+s*4)
        if ln == 0: continue
        rh = pg[off:off+ln]
        flags = struct.unpack_from('<H', rh, 10)[0]
        data = rh[13:]
        if flags & 1: continue                      # deleted stub, header only
        out.add(len(data) if flags & 2048 else unrle(data))
print(' '.join(str(x) for x in sorted(out)))
PYEOF
    }
    fclen=$(lens "$WORK"); englen=$(lens "$REF")
    check "record image length matches the engine's fmt_length" "$fclen" "$englen"
    # non-vacuity: both sides must actually have found records
    case "$fclen" in
        "") echo "DIFF no records found to measure - the check is vacuous"; fail=1 ;;
        *) echo "OK   teeth: measured real record images ($fclen bytes)" ;;
    esac
else
    echo "SKIP python3 not found for the record-image-length check"
fi
exit $fail
