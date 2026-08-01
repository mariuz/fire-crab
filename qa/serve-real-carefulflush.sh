#!/bin/bash
# THE CAREFUL WRITE ORDER, which the server did not have.
#
# fire-crab flushed a modified database with ONE `fs::write` of the whole
# file. That is correct when it completes and arbitrary when it does not:
# a crash part-way through leaves whatever the operating system happened
# to flush, in whatever order it chose.
#
# The engine writes PAGES, in an order where every page a reader might
# follow is already on disk - content before the reference to it, so a
# pointer page never names a data page that is not there yet.
# `fire-crab-cch` has modelled that precedence graph, and
# qa/cch-crash-harness.sh has gated it, since long before anything
# called it. The server calls it now.
#
# What this gate can check from outside:
#   - the flush IS ordered, and writes only the pages that CHANGED
#     (the trace names the count);
#   - the file the engine then opens is right, and gfix validates it;
#   - and the switch that turns the ordering off (FC_NO_CAREFUL) really
#     does turn it off, so the assertions above can fail.
#
# What it cannot check from outside is the crash itself - that is
# qa/cch-crash-harness.sh's job, and it is the reason the order exists.
#
#   qa/serve-real-carefulflush.sh [port]
#
# Needs the real engine on 3050 (FC_REAL_PORT overrides) and node.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4558}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-cfl-crab.fdb"
B="$D/fc-cfl-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, S VARCHAR(20));
COMMIT;
CREATE INDEX T_A ON T (A);
COMMIT;
INSERT INTO T VALUES (1, 10, 'one');
INSERT INTO T VALUES (2, 20, 'two');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-carefulflush.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
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

query() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(query "$2" "$PORT" "$A")
    case "$r" in
        ERR*) echo "OK   refused: $1" ;;
        *) echo "DIFF $1 answered: [$r]"; fail=1 ;;
    esac
}




# `set -u` and a trap that names a variable it may reach before the
# variable exists is a gate that fails for its own reasons - these are
# declared up front so every trap below is safe whichever path runs.
srv2=""
srv3=""
LOG=/tmp/fc-serve-carefulflush.log
flushes() { grep -c "careful flush:" "$LOG" 2>/dev/null || true; }

# --- 1. every write is flushed in precedence order --------------------
carefully() { # <label> <sql>
    before=$(flushes)
    both "$1" "$2"
    after=$(flushes)
    ran=$((ran + 1))
    if [ "$after" -gt "$before" ]; then
        echo "OK   ... and it was flushed in precedence order"
    else
        echo "DIFF $1 was not flushed carefully"
        fail=1
    fi
}
carefully "an INSERT" "INSERT INTO T VALUES (3, 30, 'three')"
carefully "an INSERT that also maintains an index" \
          "INSERT INTO T VALUES (4, 10, 'four')"
carefully "an UPDATE" "UPDATE T SET S = 'ONE' WHERE ID = 1"
carefully "an UPDATE that moves an index key" "UPDATE T SET A = 99 WHERE ID = 2"
carefully "a DELETE" "DELETE FROM T WHERE ID = 3"
both "the table, after all of it" "SELECT ID, A, S FROM T ORDER BY ID"

# --- 2. only the CHANGED pages are written ----------------------------
# a whole-file write would name every page in the database; a careful
# one names a handful. The count is in the trace.
ran=$((ran + 1))
biggest=$(grep -o "careful flush: [0-9]* pages" "$LOG" | grep -o "[0-9]*" | sort -n | tail -1)
if [ -n "$biggest" ] && [ "$biggest" -lt 40 ]; then
    echo "OK   the largest flush touched $biggest pages, not the whole file"
else
    echo "DIFF a flush touched $biggest pages - that is not a careful write"
    fail=1
fi

# --- 3. the engine opens what fire-crab wrote -------------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null; srv=""
ran=$((ran + 1))
a=$(printf 'SET HEADING OFF;\nSELECT ID, A, S FROM T ORDER BY ID;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$A" 2>&1 | tr -s ' \n' ' ')
b=$(printf 'SET HEADING OFF;\nSELECT ID, A, S FROM T ORDER BY ID;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$B" 2>&1 | tr -s ' \n' ' ')
if [ "$a" = "$b" ]; then
    echo "OK   the engine reads the same rows out of fire-crab's file"
else
    echo "DIFF the engine disagrees: [$a] vs [$b]"; fail=1
fi
ran=$((ran + 1))
if "${GFIX:-gfix}" -v -full -user "$U" -pas "$P" "$A" >/tmp/fc-cfl-gfix.txt 2>&1 &&
   [ ! -s /tmp/fc-cfl-gfix.txt ]; then
    echo "OK   gfix -v -full finds nothing wrong"
else
    echo "DIFF gfix reported: $(head -3 /tmp/fc-cfl-gfix.txt)"; fail=1
fi

# --- 3b. FORCED WRITES IS AN OPEN MODE --------------------------------
# The first version of this flush synced every page unconditionally,
# which is STRICTER than the engine: PIO_open adds SYNC to the OPEN MODE
# when the header's Forced Writes flag is set, and does nothing per write
# when it is not. `fire-crab-pio` has held that rule, and the offset
# arithmetic and the retry count, since it was converted - with nothing
# calling it. The trace names which mode each flush ran in, and the file
# must be right either way.
ran=$((ran + 1))
if grep -q "forced writes on" "$LOG"; then
    echo "OK   the flush reports the header's Forced Writes state"
else
    echo "DIFF the flush did not report a Forced Writes mode"; fail=1
fi
# turn it OFF on a copy and write again: same rows, different open mode
cp "$A" "$A.async" 2>/dev/null
"${GFIX:-gfix}" -write async -user "$U" -pas "$P" "$A.async" >/dev/null 2>&1
P3=$((PORT + 2))
LOG3=/tmp/fc-serve-carefulflush-async.log
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$P3" "$U" "$P" >"$LOG3" 2>&1 &
srv3=$!
trap 'kill $srv $srv2 $srv3 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$P3" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv3 2>/dev/null || { echo "FAIL the async server is not running"; exit 1; }
ran=$((ran + 1))
r=$(query "INSERT INTO T VALUES (55, 550, 'async')" "$P3" "$A.async")
case "$r" in
    ERR*) echo "DIFF a write to a Forced-Writes-off database failed: $r"; fail=1 ;;
    *) echo "OK   a database with Forced Writes OFF takes the same write" ;;
esac
ran=$((ran + 1))
if grep -q "forced writes off" "$LOG3"; then
    echo "OK   ... and the flush used the OTHER open mode for it"
else
    echo "DIFF the async database still flushed as forced"; fail=1
fi
ran=$((ran + 1))
if "${GFIX:-gfix}" -v -full -user "$U" -pas "$P" "$A.async" >/tmp/fc-cfl-gfix2.txt 2>&1 &&
   [ ! -s /tmp/fc-cfl-gfix2.txt ]; then
    echo "OK   ... and gfix validates that file too"
else
    echo "DIFF gfix on the async file: $(head -3 /tmp/fc-cfl-gfix2.txt)"; fail=1
fi
rm -f "$A.async"

# --- 4. THE SWITCH'S OWN TEETH ----------------------------------------
# with the ordering off the trace must say nothing, and the answers must
# be identical - the order changes WHEN bytes land, never WHICH.
P2=$((PORT + 1))
LOG2=/tmp/fc-serve-carefulflush-off.log
FC_NO_CAREFUL=1 FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$P2" "$U" "$P" >"$LOG2" 2>&1 &
srv2=$!
trap 'kill $srv $srv2 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$P2" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv2 2>/dev/null || { echo "FAIL the scan-only server is not running"; exit 1; }
ran=$((ran + 1))
w=$(query "INSERT INTO T VALUES (7, 70, 'seven')" "$P2" "$A")
e=$(query "INSERT INTO T VALUES (7, 70, 'seven')" "$REAL" "$B")
if [ "$w" = "$e" ]; then
    echo "OK   the whole-file write answers the same"
else
    echo "DIFF with the ordering off: [$w] vs [$e]"; fail=1
fi
ran=$((ran + 1))
if [ "$(grep -c 'careful flush:' "$LOG2" 2>/dev/null || true)" -eq 0 ]; then
    echo "OK   FC_NO_CAREFUL really does disable it (so the checks above can fail)"
else
    echo "DIFF FC_NO_CAREFUL did not disable the ordering"; fail=1
fi
ran=$((ran + 1))
a=$(printf 'SET HEADING OFF;\nSELECT ID FROM T ORDER BY ID;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$A" 2>&1 | tr -s ' \n' ' ')
b=$(printf 'SET HEADING OFF;\nSELECT ID FROM T ORDER BY ID;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$B" 2>&1 | tr -s ' \n' ' ')
if [ "$a" = "$b" ]; then
    echo "OK   and both files still agree, page-ordered or not"
else
    echo "DIFF [$a] vs [$b]"; fail=1
fi

rm -f "$A" "$B"
if [ "$ran" -lt 21 ]; then
    echo "DIFF only $ran checks ran (expected at least 21) - did one silently skip?"
    fail=1
fi
exit $fail
