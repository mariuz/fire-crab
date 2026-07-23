#!/bin/bash
# GEN_ID(<name>, <step>) with a NON-ZERO step, and NEXT VALUE FOR <seq> -
# a SELECT that WRITES. The generator is bumped by the step (or, for NEXT
# VALUE FOR, by the sequence's own increment) and the NEW value is
# returned. fire-crab does this at op_execute (the one place a SELECT
# writes): it reads the generator page, adds the step, writes the native
# little-endian SINT64 back, and the statement becomes a scalar of that
# new value for the fetch.
#
# THE differential: every increment runs through BOTH fire-crab (node) and
# the C++ engine (isql) - the returned values must match value-for-value -
# and afterwards the engine reads identical STORED generator values from
# the fire-crab-written file and its own reference. gfix validates the file.
#
#   qa/serve-real-genstep.sh [port]
#
# Builds its own scratch database (a generator and an INCREMENT BY 5 sequence).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4085}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/genstep_src.fdb"; WORK="/tmp/fc-genstep-work.fdb"; REF="/tmp/fc-genstep-ref.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"; rm -f "$SRC" "$WORK" "$REF"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE GENERATOR G;
CREATE SEQUENCE SEQ5 START WITH 100 INCREMENT BY 5;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-genstep.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# run one query through fire-crab and print the single scalar value
fc_val() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
          process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(1);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR");db.detach();process.exit(0);}
              console.log((r&&r.length)?String(Object.values(r[0])[0]):"<none>");
              db.detach();process.exit(0);});
          });' 2>/dev/null)
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}
# run one query through the engine (isql) on REF and print the value
# (SET HEADING OFF so the column title is not captured)
en_val() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF | strip | grep -oE '^-?[0-9]+$' | head -1
SET HEADING OFF;
$1;
EOF
}

fail=0
step() { # <label> <query>
    fc=$(fc_val "$2")
    en=$(en_val "$2")
    if [ "$fc" = "$en" ] && [ -n "$fc" ]; then
        echo "OK   $1 = $fc"
    else
        echo "DIFF $1"
        echo "     engine: $en"
        echo "     fc:     $fc"
        fail=1
    fi
}

# every increment: fire-crab's returned value must equal the engine's
step "GEN_ID(G, 1)"     "SELECT GEN_ID(G, 1) FROM RDB\$DATABASE"
step "GEN_ID(G, 1)"     "SELECT GEN_ID(G, 1) FROM RDB\$DATABASE"
step "GEN_ID(G, 10)"    "SELECT GEN_ID(G, 10) FROM RDB\$DATABASE"
step "GEN_ID(G, -3)"    "SELECT GEN_ID(G, -3) FROM RDB\$DATABASE"
step "GEN_ID(G, 0) read" "SELECT GEN_ID(G, 0) FROM RDB\$DATABASE"
step "NEXT VALUE FOR"   "SELECT NEXT VALUE FOR SEQ5 FROM RDB\$DATABASE"
step "NEXT VALUE FOR"   "SELECT NEXT VALUE FOR SEQ5 FROM RDB\$DATABASE"
step "GEN_ID(SEQ5, 0)"  "SELECT GEN_ID(SEQ5, 0) FROM RDB\$DATABASE"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the engine reads IDENTICAL stored values from both files
storeq() { # <label> <gen>
    ew=$(printf 'SET LIST ON;\nSELECT GEN_ID(%s,0) FROM RDB$DATABASE;\n' "$2" | \
         "$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 | strip | grep -oE '[-0-9]+' | head -1)
    er=$(printf 'SET LIST ON;\nSELECT GEN_ID(%s,0) FROM RDB$DATABASE;\n' "$2" | \
         "$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 | strip | grep -oE '[-0-9]+' | head -1)
    if [ "$ew" = "$er" ] && [ -n "$ew" ]; then
        echo "OK   $1 stored = $ew (engine reads fc == engine)"
    else
        echo "DIFF $1 stored"; echo "     ref: $er"; echo "     work: $ew"; fail=1
    fi
}
storeq "G"    "G"
storeq "SEQ5" "SEQ5"

val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
if [ -z "$(printf '%s' "$val" | strip)" ]; then
    echo "OK   gfix -v -full clean"
else
    echo "DIFF gfix -v -full"; echo "     $val"; fail=1
fi

exit $fail
