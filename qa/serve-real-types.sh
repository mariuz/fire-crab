#!/bin/sh
# The server sends native wire types. fire-crab, as a server, describes
# and encodes every column type the record decoder handles exactly in the
# engine's own wire form - SMALLINT/INTEGER/BIGINT natively (not coerced
# to BIGINT), NUMERIC/DECIMAL as raw scaled integers with the scale in
# the describe (the client divides - the engine's contract), FLOAT/DOUBLE
# as IEEE bytes, DATE/TIME/TIMESTAMP as raw day/1e-4-second units,
# BOOLEAN as an XDR int slot. node-firebird decodes them with its normal
# typed path (JS numbers, Date objects, booleans) and the values must
# equal isql's rendering after canonicalisation:
#   - node Date objects are formatted YYYY-MM-DD / HH:MM:SS.ffff / both,
#     picking the shape by sentinel (1970-01-01 = a TIME value, midnight
#     = a DATE value) - the scratch data avoids the ambiguous corners
#   - isql DOUBLE/FLOAT text has trailing zeros trimmed on the isql side
#   - scaled test data never ends in a zero decimal digit (JS numbers
#     drop trailing zeros; 12.30 would print 12.3)
#   - TIME test data sticks to whole milliseconds (JS Date resolution;
#     the wire carries 1/10000 s)
#
#   qa/serve-real-types.sh <clean-db-path> [port]
#
# Expects the TY table of the wiretypes scratch db (see docs). Use a
# clean (gbak-restored) database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-types.sh <clean-db-path> [port]}"
PORT="${2:-4531}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-types.log 2>&1 &
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

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

node_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      const pad=(n,w)=>String(n).padStart(w,"0");
      const fmt=(v)=>{
        if(v===null)return "<null>";
        if(v===true)return "TRUE";
        if(v===false)return "FALSE";
        if(v instanceof Date){
          const date=`${pad(v.getFullYear(),4)}-${pad(v.getMonth()+1,2)}-${pad(v.getDate(),2)}`;
          const time=`${pad(v.getHours(),2)}:${pad(v.getMinutes(),2)}:${pad(v.getSeconds(),2)}.${pad(v.getMilliseconds(),3)}0`;
          if(date==="1970-01-01")return time;         // a TIME value
          if(time==="00:00:00.0000")return date;      // a DATE value
          return date+" "+time;
        }
        return String(v).replace(/\s+$/,"");
      };
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("CONN_ERR");db.detach();process.exit(1);}
          if(r.length===0)console.log("<no rows>");
          for(const row of r)
            console.log(Object.values(row).map(fmt).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_ordered() {
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
compare() { # <label> <node-query> <isql-select-body>
    fc=$(node_ordered "$2")
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING OFF;
$3;
EOF
)
    [ -z "$is" ] && is="<no rows>"
    if [ "$fc" = "$is" ]; then
        echo "OK   $1 ($(printf '%s\n' "$fc" | grep -c .) rows)"
    else
        echo "DIFF $1"
        printf '%s\n' "$is" > /tmp/fc-ty-is.txt; printf '%s\n' "$fc" > /tmp/fc-ty-fc.txt
        diff /tmp/fc-ty-is.txt /tmp/fc-ty-fc.txt | head -8 | sed 's/^/     /'
        fail=1
    fi
}

# isql-side canonicalisers, matching the node formatter
NV() { echo "COALESCE(CAST($1 AS VARCHAR(24)),'<null>')"; }              # exact numerics/ints
FV() { echo "COALESCE(TRIM(TRAILING '.' FROM TRIM(TRAILING '0' FROM CAST($1 AS VARCHAR(30)))),'<null>')"; } # float/double
TV() { echo "COALESCE(TRIM(CAST($1 AS VARCHAR(26))),'<null>')"; }        # temporal/boolean/text

# every integer width natively, incl. SMALLINT extremes
compare "native integers" \
    "SELECT ID, SI, BI FROM TY ORDER BY ID" \
    "SELECT ID || '|' || $(NV SI) || '|' || $(NV BI) FROM TY ORDER BY ID"
# scaled numerics: LONG(9,2), SHORT(4,2), INT64(15,4) - raw + describe scale
compare "scaled numerics" \
    "SELECT ID, N92, N42, D154 FROM TY ORDER BY ID" \
    "SELECT ID || '|' || $(NV N92) || '|' || $(NV N42) || '|' || $(NV D154) FROM TY ORDER BY ID"
# IEEE float and double
compare "float and double" \
    "SELECT ID, F, DP FROM TY ORDER BY ID" \
    "SELECT ID || '|' || $(FV F) || '|' || $(FV DP) FROM TY ORDER BY ID"
# date (incl. the 1858-11-17 epoch day 0), time, timestamp
compare "date/time/timestamp" \
    "SELECT ID, DT, TM, TS FROM TY ORDER BY ID" \
    "SELECT ID || '|' || $(TV DT) || '|' || $(TV TM) || '|' || $(TV TS) FROM TY ORDER BY ID"
# boolean and text alongside
compare "boolean and text" \
    "SELECT ID, B, VC FROM TY ORDER BY ID" \
    "SELECT ID || '|' || $(TV B) || '|' || $(TV VC) FROM TY ORDER BY ID"
# SELECT * carries every type at once
compare "SELECT * all types" \
    "SELECT * FROM TY ORDER BY ID" \
    "SELECT ID || '|' || $(NV SI) || '|' || $(NV BI) || '|' || $(NV N92) || '|' || $(NV N42) || '|' || $(NV D154) || '|' || $(FV F) || '|' || $(FV DP) || '|' || $(TV DT) || '|' || $(TV TM) || '|' || $(TV TS) || '|' || $(TV B) || '|' || $(TV VC) FROM TY ORDER BY ID"
# ORDER BY on a scaled numeric sorts numerically (9.50 < 12.30), NULL first
compare "ORDER BY scaled numeric" \
    "SELECT ID, N42 FROM TY ORDER BY N42, ID" \
    "SELECT ID || '|' || $(NV N42) FROM TY ORDER BY N42, ID"
# ORDER BY timestamp descending
compare "ORDER BY timestamp DESC" \
    "SELECT ID, TS FROM TY ORDER BY TS DESC" \
    "SELECT ID || '|' || $(TV TS) FROM TY ORDER BY TS DESC"
# dates as GROUP BY keys (two rows share a date, NULL its own bucket)
compare "GROUP BY date" \
    "SELECT DT, COUNT(*) FROM TY GROUP BY DT ORDER BY DT" \
    "SELECT $(TV DT) || '|' || COUNT(*) FROM TY GROUP BY DT ORDER BY DT"
# COUNT(col) counts non-null temporal values
compare "COUNT over a time column" \
    "SELECT COUNT(TM) FROM TY" \
    "SELECT COUNT(TM) FROM TY"
exit $fail
