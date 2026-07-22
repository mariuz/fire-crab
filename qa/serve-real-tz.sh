#!/bin/bash
# TIME/TIMESTAMP WITH TIME ZONE: decode, conversion, wire. Values store
# UTC + a zone id (offset zones: id - 1439 minutes, ONE_DAY = 24*60-1 -
# an off-by-one this very differential caught on its first run; named
# zones: ids down from 65535 through the generated TimeZones.h list).
# fire-crab
# converts what is convertible WITHOUT tzdata - offset zones and GMT -
# exactly as TimeZoneUtil does, local time with day carry, and renders
# named zones VISIBLY unconverted (the engine needs ICU's tzdata rules
# for those; a marked placeholder is honest, a wrong local time would
# not be). Differentials:
#
#   1. RENDER: `fcstat rows` == isql text on offset-zone and GMT values,
#      including a time that wraps past midnight in UTC and a timestamp
#      whose local date differs from its UTC date;
#   2. WIRE: node-firebird receives the native SQL_TIME_TZ form (UTC
#      long + zone slot; node discards the zone and yields the UTC
#      instant) and ORDER BY sorts by UTC INSTANT - asserted with rows
#      whose local-time order INVERTS their UTC order;
#   3. the named-zone row renders with the right region name from the
#      generated zone table, and with the placeholder marker - never a
#      silently wrong local time.
#
#   qa/serve-real-tz.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4065}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/tz_src.fdb"; CLEAN="$DIR/tz_clean.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, TT TIME WITH TIME ZONE, TS TIMESTAMP WITH TIME ZONE);
COMMIT;
INSERT INTO T VALUES (1, TIME '11:30:00 +02:00', TIMESTAMP '2021-05-02 13:15:00.5000 -05:30');
INSERT INTO T VALUES (2, TIME '23:30:00.1230 -05:30', TIMESTAMP '2021-01-02 01:00:00 +03:00');
INSERT INTO T VALUES (3, NULL, NULL);
INSERT INTO T VALUES (4, TIME '09:00:00 GMT', TIMESTAMP '2021-01-01 23:00:00 +00:00');
INSERT INTO T VALUES (5, TIME '12:00:00 Europe/Bucharest', TIMESTAMP '2021-07-01 12:00:00 Europe/Bucharest');
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/tz.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/tz.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
isql_q() {
    printf 'SET HEADING OFF;\n%s\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$CLEAN" | strip | grep -v '^$'
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

# --- differential 1: rendered rows == isql (offset zones + GMT) --------
rel_id=$(isql_q "SELECT RDB\$RELATION_ID FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T';" | tr -d ' ')
rows=$("$FCSTAT" rows "$CLEAN" "$rel_id" | tr '\t' '|')
check "render: offset zones and GMT == isql (incl. UTC day wrap)" \
    "$(printf '%s\n' "$rows" | grep -v 'Europe/Bucharest' | sort)" \
    "$(isql_q "SELECT COALESCE(CAST(TT AS VARCHAR(30)),'<null>') || '|' || ID || '|' || COALESCE(CAST(TS AS VARCHAR(40)),'<null>') FROM T WHERE ID <> 5;" | sort)"

# the named-zone row: right name from the generated table, and marked
# unconverted - the zone rules need tzdata the conversion does not have
named=$(printf '%s\n' "$rows" | grep 'Europe/Bucharest' || true)
if [ -n "$named" ] && printf '%s' "$named" | grep -q '<tz '; then
    echo "OK   named zone: correct region name, visibly unconverted"
else
    echo "DIFF named zone: correct region name, visibly unconverted"
    echo "     got: $named"
    fail=1
fi

# --- differential 2: the wire, through node-firebird -------------------
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-tz.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

# node's TimeTz decode discards the zone and yields the UTC instant as
# a compensated Date - print it as HH:MM:SS.mmm of the raw value
node_once() {
    FC_DB="$CLEAN" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      const pad=(n,w)=>String(n).padStart(w,"0");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>{
              if(v===null)return "<null>";
              if(v instanceof Date)
                return pad(v.getHours(),2)+":"+pad(v.getMinutes(),2)+":"+pad(v.getSeconds(),2)+"."+pad(v.getMilliseconds(),3);
              return String(v).replace(/\s+$/,"");
            }).join("|"));
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

# the UTC instants over the wire (node discards zones by design)
check "wire: TIME WITH TIME ZONE - UTC instants" \
    "$(node_run "SELECT ID, TT FROM T WHERE ID = 1 OR ID = 2 OR ID = 4 ORDER BY ID")" \
    "$(isql_q "SELECT ID || '|' || SUBSTRING(CAST(TT AT TIME ZONE '+00:00' AS VARCHAR(30)) FROM 1 FOR 12) FROM T WHERE ID IN (1,2,4) ORDER BY ID;")"
check "wire: the NULL row" \
    "$(node_run "SELECT TT, TS FROM T WHERE ID = 3")" "<null>|<null>"

# ORDER BY sorts by UTC INSTANT: rows 2 and 4's local dates order
# opposite to their UTC instants (Jan 2 +03:00 = Jan 1 22:00 UTC,
# before Jan 1 23:00 +00:00) - lexical/local ordering would invert
check "ORDER BY timestamp-tz sorts by UTC instant" \
    "$(node_run "SELECT ID FROM T ORDER BY TS, ID")" \
    "$(isql_q "SELECT ID FROM T ORDER BY TS, ID;" | tr -d ' ')"
check "ORDER BY time-tz sorts by UTC instant" \
    "$(node_run "SELECT ID FROM T ORDER BY TT, ID")" \
    "$(isql_q "SELECT ID FROM T ORDER BY TT, ID;" | tr -d ' ')"
exit $fail
