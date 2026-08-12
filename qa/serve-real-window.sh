#!/bin/bash
# WINDOW functions - an aggregate with an OVER clause, answered on every
# input row: `<agg>(arg) OVER ( [PARTITION BY ...] )`. The rows are
# bucketed by the PARTITION BY keys (NULLs bucket together, as GROUP BY
# does), each bucket folded by the same machinery a grouped aggregate
# uses, and every row in a bucket answered that bucket's value - one row
# per INPUT row, not per bucket. `OVER ()` is one bucket of the whole
# result. The value's describe is the aggregate's own (COUNT -> BIGINT,
# MIN/MAX -> the source type, SUM/AVG widened at the source scale), named
# by the function unless aliased - the SAME contract a bare aggregate has.
#
# node-firebird drives fire-crab; isql-created twin answers the same query
# from the live engine; the row sets must be identical. Covered: the
# whole-partition AGGREGATE window - COUNT/SUM/MIN/MAX/AVG, integer /
# NUMERIC / text sources, one- and two-column partitions, `OVER ()`,
# several windows in one select, a window beside plain columns and an
# expression, a WHERE before the window, a NULL partition key, ORDER BY on
# the window column, COUNT(DISTINCT) OVER - and the RANKING functions
# ROW_NUMBER / RANK / DENSE_RANK OVER ( [PARTITION BY ...] ORDER BY ... ),
# with ties (RANK gaps, DENSE_RANK does not), DESC and text ordering, a
# partition, and a ranking beside an aggregate window in one select; and
# the RUNNING aggregate `<agg> OVER ( [PARTITION BY ...] ORDER BY ... )`
# under the default RANGE frame, where rows tying on the ORDER BY keys
# SHARE the cumulative value; and the NAVIGATION functions LAG / LEAD -
# `LAG(arg [, offset [, default]]) OVER ( [PARTITION BY ...] ORDER BY ...)`
# - reading a row `offset` positions back (LAG) or forward (LEAD), the
# default (else NULL) off the partition's ends, describing as the
# argument's own type; and the VALUE functions FIRST_VALUE / LAST_VALUE /
# NTH_VALUE, reading a frame row under the default RANGE frame -
# FIRST_VALUE the partition's first row, LAST_VALUE the current row's last
# peer, NTH_VALUE(n) the nth frame row (NULL if fewer); and an aggregate
# with an EXPLICIT `ROWS` frame - `<agg> OVER (ORDER BY ... ROWS BETWEEN
# <start> AND <end>)` and the `ROWS <start>` shorthand - a PHYSICAL-row
# moving window (bounds UNBOUNDED PRECEDING / n PRECEDING / CURRENT ROW /
# n FOLLOWING / UNBOUNDED FOLLOWING), clamped at the partition ends, an
# empty frame folding no rows (COUNT 0, the rest NULL). A VALUE function
# also takes an explicit `ROWS` frame - FIRST_VALUE the frame's first row,
# LAST_VALUE its last (so `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED
# FOLLOWING` is the partition's last value), NTH_VALUE(n) the nth from the
# frame start.
#
# SCOPE. An AGGREGATE window with no ORDER BY is the whole-partition
# frame; with one and no explicit frame it is a RUNNING aggregate (default
# RANGE, peers share); an explicit `ROWS` frame is a physical moving
# window; an explicit `RANGE` frame is a VALUE window over a single
# INTEGER order key (ASC or DESC), the bounds measured in the key's own
# values (peers fall in naturally). A VALUE function takes an explicit
# `ROWS` frame too. A `RANGE` frame over a numeric/temporal key, a `RANGE`
# frame on a value function, a `GROUPS` frame, and a frame on a
# ranking/navigation function are later slices (refused). Still
# refused, each its own slice: a window over a JOIN or a derived / CTE /
# union-branch row source, a window mixed with GROUP BY, and a `?` inside
# a window. Every ROW_NUMBER / LAG / LEAD / NTH / ROWS-frame check uses a
# TOTAL order - a tie leaves the row sequence unpinned, so only a total
# order is differentially deterministic.
#
#   qa/serve-real-window.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4767}"
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
CREATE TABLE T (ID INTEGER, G INTEGER, H INTEGER, V INTEGER, N92 NUMERIC(9,2), NM VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1,10,1,5,1.50,'aa'); INSERT INTO T VALUES (2,10,1,3,2.50,'bb');
INSERT INTO T VALUES (3,20,1,9,5.00,'cc'); INSERT INTO T VALUES (4,20,2,9,1.00,'dd');
INSERT INTO T VALUES (5,30,2,1,2.00,'ee'); INSERT INTO T VALUES (6,30,2,7,3.00,NULL);
INSERT INTO T VALUES (7,NULL,NULL,4,NULL,'gg');
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-window-a.fdb"; B="$D/fc-window-b.fdb"
mkdb "$A"; mkdb "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-window-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

query() { # <sql> <host> <port> <db>
    timeout 25 env FC_Q="$1" FC_HOST="$2" FC_PORT="$3" FC_DB="$4" node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(0);});
      const F=require("node-firebird");
      F.attach({host:process.env.FC_HOST,port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,44));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null
}
both() { # <label> <sql>
    local a b
    a=$(query "$2" 127.0.0.1 "$PORT" "$A")
    b=$(query "$2" 127.0.0.1 "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}

both "COUNT(*) OVER ()"        "SELECT ID, COUNT(*) OVER () C FROM T ORDER BY ID"
both "SUM OVER (PARTITION)"    "SELECT ID, SUM(V) OVER (PARTITION BY G) S FROM T ORDER BY ID"
both "MAX OVER (PARTITION)"    "SELECT ID, MAX(V) OVER (PARTITION BY G) M FROM T ORDER BY ID"
both "AVG OVER (PARTITION)"    "SELECT ID, AVG(V) OVER (PARTITION BY G) A FROM T ORDER BY ID"
both "MIN text OVER"           "SELECT ID, MIN(NM) OVER (PARTITION BY G) M FROM T ORDER BY ID"
both "SUM numeric OVER"        "SELECT ID, SUM(N92) OVER (PARTITION BY G) S FROM T ORDER BY ID"
both "COUNT(col) OVER"         "SELECT ID, COUNT(NM) OVER (PARTITION BY G) C FROM T ORDER BY ID"
both "two-column partition"    "SELECT ID, SUM(V) OVER (PARTITION BY G, H) S FROM T ORDER BY ID"
both "two windows"             "SELECT ID, SUM(V) OVER (PARTITION BY G) S, COUNT(*) OVER () C FROM T ORDER BY ID"
both "window + plain + expr"   "SELECT ID, V, V*2 D, AVG(V) OVER (PARTITION BY G) A FROM T ORDER BY ID"
both "WHERE then window"       "SELECT ID, SUM(V) OVER (PARTITION BY G) S FROM T WHERE ID>2 ORDER BY ID"
both "NULL partition key"      "SELECT ID, COUNT(*) OVER (PARTITION BY G) C FROM T ORDER BY ID"
both "ORDER BY window column"  "SELECT ID, SUM(V) OVER (PARTITION BY G) S FROM T ORDER BY S, ID"
both "no alias -> named SUM"   "SELECT SUM(V) OVER (PARTITION BY G) FROM T ORDER BY 1"
both "COUNT(DISTINCT) OVER"    "SELECT ID, COUNT(DISTINCT V) OVER (PARTITION BY G) C FROM T ORDER BY ID"
both "AVG numeric OVER ()"     "SELECT ID, AVG(N92) OVER () A FROM T ORDER BY ID"
# --- ranking functions (ROW_NUMBER / RANK / DENSE_RANK) ---
both "ROW_NUMBER total order"  "SELECT ID, ROW_NUMBER() OVER (ORDER BY V, ID) R FROM T ORDER BY ID"
both "RANK ties + gaps"        "SELECT ID, RANK() OVER (ORDER BY V) R FROM T ORDER BY V, ID"
both "DENSE_RANK ties no gap"  "SELECT ID, DENSE_RANK() OVER (ORDER BY V) R FROM T ORDER BY V, ID"
both "ROW_NUMBER PARTITION"    "SELECT ID, G, ROW_NUMBER() OVER (PARTITION BY G ORDER BY V, ID) R FROM T ORDER BY ID"
both "RANK PARTITION"          "SELECT ID, G, RANK() OVER (PARTITION BY G ORDER BY V) R FROM T ORDER BY G, V, ID"
both "DENSE_RANK PARTITION"    "SELECT ID, G, DENSE_RANK() OVER (PARTITION BY G ORDER BY V) R FROM T ORDER BY G, V, ID"
both "RANK DESC"               "SELECT ID, RANK() OVER (ORDER BY V DESC) R FROM T ORDER BY V DESC, ID"
both "ROW_NUMBER text order"   "SELECT ID, ROW_NUMBER() OVER (ORDER BY NM, ID) R FROM T ORDER BY ID"
both "ranking + agg window"    "SELECT ID, G, RANK() OVER (PARTITION BY G ORDER BY V) R, SUM(V) OVER (PARTITION BY G) S FROM T ORDER BY G, V, ID"
both "ranking no alias name"   "SELECT ROW_NUMBER() OVER (ORDER BY ID) FROM T ORDER BY 1"
# --- running (ordered) aggregates, default RANGE frame (peers share) ---
both "running SUM (peers)"     "SELECT ID, SUM(V) OVER (ORDER BY V) S FROM T ORDER BY V, ID"
both "running COUNT (peers)"   "SELECT ID, COUNT(*) OVER (ORDER BY V) C FROM T ORDER BY V, ID"
both "running AVG (peers)"     "SELECT ID, AVG(V) OVER (ORDER BY V) A FROM T ORDER BY V, ID"
both "running MAX (peers)"     "SELECT ID, MAX(V) OVER (ORDER BY V) M FROM T ORDER BY V, ID"
both "running SUM PARTITION"   "SELECT ID, G, SUM(V) OVER (PARTITION BY G ORDER BY V) S FROM T ORDER BY G, V, ID"
both "running SUM DESC"        "SELECT ID, SUM(V) OVER (ORDER BY V DESC) S FROM T ORDER BY V DESC, ID"
both "running numeric SUM"     "SELECT ID, G, SUM(N92) OVER (PARTITION BY G ORDER BY V) S FROM T ORDER BY G, V, ID"
both "running + whole + rank"  "SELECT ID, G, SUM(V) OVER (PARTITION BY G ORDER BY V) RS, SUM(V) OVER (PARTITION BY G) TS, RANK() OVER (PARTITION BY G ORDER BY V) RK FROM T ORDER BY G, V, ID"
# --- navigation functions (LAG / LEAD) ---
both "LAG(V)"                  "SELECT ID, LAG(V) OVER (ORDER BY ID) L FROM T ORDER BY ID"
both "LAG(V,2)"                "SELECT ID, LAG(V,2) OVER (ORDER BY ID) L FROM T ORDER BY ID"
both "LAG(V,1,-9) default"     "SELECT ID, LAG(V,1,-9) OVER (ORDER BY ID) L FROM T ORDER BY ID"
both "LEAD(V)"                 "SELECT ID, LEAD(V) OVER (ORDER BY ID) L FROM T ORDER BY ID"
both "LEAD(V,1,-9) default"    "SELECT ID, LEAD(V,1,-9) OVER (ORDER BY ID) L FROM T ORDER BY ID"
both "LAG partition"           "SELECT ID, G, LAG(V) OVER (PARTITION BY G ORDER BY ID) L FROM T ORDER BY G, ID"
both "LAG text arg"            "SELECT ID, LAG(NM) OVER (ORDER BY ID) L FROM T ORDER BY ID"
both "LAG expression arg"      "SELECT ID, LAG(V*2) OVER (ORDER BY ID) L FROM T ORDER BY ID"
both "LAG + LEAD + ranking"    "SELECT ID, LAG(V) OVER (ORDER BY ID) LA, LEAD(V) OVER (ORDER BY ID) LE, ROW_NUMBER() OVER (ORDER BY ID) RN FROM T ORDER BY ID"
# --- value functions (FIRST_VALUE / LAST_VALUE / NTH_VALUE), default frame ---
both "FIRST_VALUE"             "SELECT ID, FIRST_VALUE(V) OVER (ORDER BY V, ID) F FROM T ORDER BY V, ID"
both "LAST_VALUE peers"        "SELECT ID, V, LAST_VALUE(V) OVER (ORDER BY V) L FROM T ORDER BY V, ID"
both "LAST_VALUE(ID) peers"    "SELECT ID, V, LAST_VALUE(ID) OVER (ORDER BY V) L FROM T ORDER BY V, ID"
both "NTH_VALUE(V,2)"          "SELECT ID, NTH_VALUE(V,2) OVER (ORDER BY V, ID) N FROM T ORDER BY V, ID"
both "FIRST_VALUE partition"   "SELECT ID, G, FIRST_VALUE(V) OVER (PARTITION BY G ORDER BY V, ID) F FROM T ORDER BY G, V, ID"
both "LAST_VALUE partition"    "SELECT ID, G, LAST_VALUE(V) OVER (PARTITION BY G ORDER BY V) L FROM T ORDER BY G, V, ID"
both "FIRST_VALUE text"        "SELECT ID, FIRST_VALUE(NM) OVER (ORDER BY V, ID) F FROM T ORDER BY V, ID"
both "value fns + LAG"         "SELECT ID, FIRST_VALUE(V) OVER (ORDER BY ID) F, LAST_VALUE(V) OVER (ORDER BY ID) L, NTH_VALUE(V,2) OVER (ORDER BY ID) N, LAG(V) OVER (ORDER BY ID) LG FROM T ORDER BY ID"
# --- explicit ROWS frames on aggregate windows (physical moving window) ---
both "ROWS 1 PREC..1 FOLL"     "SELECT ID, SUM(V) OVER (ORDER BY V, ID ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) M FROM T ORDER BY V, ID"
both "ROWS 2 PREC..CURRENT"    "SELECT ID, SUM(V) OVER (ORDER BY V, ID ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) M FROM T ORDER BY V, ID"
both "ROWS UNBOUNDED PREC"     "SELECT ID, SUM(V) OVER (ORDER BY V, ID ROWS UNBOUNDED PRECEDING) M FROM T ORDER BY V, ID"
both "ROWS COUNT window"       "SELECT ID, COUNT(*) OVER (ORDER BY V, ID ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) C FROM T ORDER BY V, ID"
both "ROWS future (empty end)" "SELECT ID, SUM(V) OVER (ORDER BY V, ID ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) M FROM T ORDER BY V, ID"
both "ROWS shorthand 1 PREC"   "SELECT ID, G, SUM(V) OVER (PARTITION BY G ORDER BY V, ID ROWS 1 PRECEDING) M FROM T ORDER BY G, V, ID"
both "ROWS CR..UNB FOLLOWING"  "SELECT ID, MAX(V) OVER (ORDER BY V, ID ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) M FROM T ORDER BY V, ID"
both "ROWS AVG numeric moving" "SELECT ID, G, AVG(N92) OVER (PARTITION BY G ORDER BY V, ID ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) M FROM T ORDER BY G, V, ID"
# --- value functions with an explicit ROWS frame ---
both "LAST_VALUE whole part"   "SELECT ID, LAST_VALUE(V) OVER (ORDER BY V, ID ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) L FROM T ORDER BY V, ID"
both "FIRST_VALUE 1P..CR"      "SELECT ID, FIRST_VALUE(V) OVER (ORDER BY V, ID ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) F FROM T ORDER BY V, ID"
both "LAST_VALUE CR..1F"       "SELECT ID, LAST_VALUE(V) OVER (ORDER BY V, ID ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) L FROM T ORDER BY V, ID"
both "NTH_VALUE CR..UF"        "SELECT ID, NTH_VALUE(V,2) OVER (ORDER BY V, ID ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) N FROM T ORDER BY V, ID"
both "LAST_VALUE partition fr" "SELECT ID, G, LAST_VALUE(V) OVER (PARTITION BY G ORDER BY V, ID ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) L FROM T ORDER BY G, V, ID"
both "NTH_VALUE empty frame"   "SELECT ID, NTH_VALUE(V,3) OVER (ORDER BY V, ID ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) N FROM T ORDER BY V, ID"
# --- explicit RANGE frames (value window over an integer key) ---
both "RANGE 2 PREC..CURRENT"   "SELECT ID, SUM(V) OVER (ORDER BY V RANGE BETWEEN 2 PRECEDING AND CURRENT ROW) S FROM T ORDER BY V, ID"
both "RANGE 2 PREC..2 FOLL"    "SELECT ID, COUNT(*) OVER (ORDER BY V RANGE BETWEEN 2 PRECEDING AND 2 FOLLOWING) C FROM T ORDER BY V, ID"
both "RANGE CURRENT..3 FOLL"   "SELECT ID, SUM(V) OVER (ORDER BY V RANGE BETWEEN CURRENT ROW AND 3 FOLLOWING) S FROM T ORDER BY V, ID"
both "RANGE shorthand 1 PREC"  "SELECT ID, SUM(V) OVER (ORDER BY V RANGE 1 PRECEDING) S FROM T ORDER BY V, ID"
both "RANGE DESC 2 PREC..CR"   "SELECT ID, SUM(V) OVER (ORDER BY V DESC RANGE BETWEEN 2 PRECEDING AND CURRENT ROW) S FROM T ORDER BY V DESC, ID"
both "RANGE partition"         "SELECT ID, G, SUM(V) OVER (PARTITION BY G ORDER BY V RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) S FROM T ORDER BY G, V, ID"
both "RANGE MAX 1P..1F"        "SELECT ID, MAX(V) OVER (ORDER BY V RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) M FROM T ORDER BY V, ID"

echo "ran $ran checks"
exit $fail
