#!/bin/bash
# CAST(? AS VARCHAR(n) / CHAR(n)) - a `?` projection parameter cast to a
# TEXT type. This closes the last of the projection-parameter cast
# targets: the integer/numeric/approx families landed first
# (serve-real-castparam.sh), the temporal ones next
# (serve-real-castparamt.sh), and text refused there because the
# CAST-to-text VALUE was not yet fit to the width. Now that the eval fits
# it (serve-real-casttext.sh - blank-fit, the 22001/22018 classes, CHAR
# padding), the `?` converts a bound value exactly as a literal does, and
# cast_target_descriptor answers the slot instead of refusing.
#
# Driven by node-firebird: the bound value arrives as a value-derived
# string, so the source is always text and an over-width non-blank value
# is 22001 *string right truncation*. Each case runs the same statement
# and argument against fire-crab and the live engine and compares the row.
#
#   qa/serve-real-castparamtext.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4761}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node-firebird")' >/dev/null 2>&1; then
    echo "SKIP: node-firebird not available"; exit 0
fi
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-castparamtext-a.fdb"; B="$D/fc-castparamtext-b.fdb"
mkdb "$A"; mkdb "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castparamtext-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

query() { # <sql> <json args> <host> <port> <db>
    timeout 25 env FC_Q="$1" FC_A="$2" FC_HOST="$3" FC_PORT="$4" FC_DB="$5" node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(0);});
      const F=require("node-firebird");
      const args=JSON.parse(process.env.FC_A);
      F.attach({host:process.env.FC_HOST,port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,args,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,44));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null
}
both() { # <label> <sql> <json args>
    local a b
    a=$(query "$2" "$3" 127.0.0.1 "$PORT" "$A")
    b=$(query "$2" "$3" 127.0.0.1 "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}

# brackets make the trailing blanks of a CHAR pad / a blank-fit visible
both "varchar fits"        "SELECT '['||CAST(? AS VARCHAR(5))||']' AS C FROM RDB\$DATABASE" '["abc"]'
both "varchar exact"       "SELECT '['||CAST(? AS VARCHAR(5))||']' AS C FROM RDB\$DATABASE" '["abcde"]'
both "varchar blank-fit"   "SELECT '['||CAST(? AS VARCHAR(3))||']' AS C FROM RDB\$DATABASE" '["ab   "]'
both "char pads"           "SELECT '['||CAST(? AS CHAR(5))||']' AS C FROM RDB\$DATABASE"    '["ab"]'
both "varchar overflow"    "SELECT CAST(? AS VARCHAR(3)) AS C FROM RDB\$DATABASE"           '["abcdefgh"]'
both "char overflow"       "SELECT CAST(? AS CHAR(3)) AS C FROM RDB\$DATABASE"              '["abcdefgh"]'
both "varchar wide"        "SELECT CAST(? AS VARCHAR(10)) AS C FROM RDB\$DATABASE"          '["hello"]'
both "NULL binds to NULL"  "SELECT CAST(? AS VARCHAR(5)) AS C FROM RDB\$DATABASE"           '[null]'
# a text `?` and a WHERE `?` coexist, projection numbered first
both "text proj + WHERE"   "SELECT CAST(? AS VARCHAR(5)) AS C FROM RDB\$DATABASE WHERE 1 = ?" '["hi",1]'

echo "ran $ran checks"
exit $fail
