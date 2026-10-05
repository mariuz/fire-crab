#!/bin/bash
# CREATE INDEX .. COMPUTED BY (<expr>) AND CREATE INDEX .. WHERE <cond>
# THROUGH THIS SERVER. Both refused at prepare (the paper's
# samples/nodejs/indexes.js). Now:
#   * an EXPRESSION index stores the BLR a COMPUTED BY column stores -
#     byte-identical on 2196 - its source as written, and the key itype
#     the engine stamps for the expression's type (UPPER over UTF8 4,
#     INTEGER * 2 8, EXTRACT 0, a DATE 5), every committed row keyed on
#     the evaluated expression;
#   * a PARTIAL index stores RDB$CONDITION_BLR (blr_version5, the boolean
#     as written, blr_eoc - byte-identical) and RDB$CONDITION_SOURCE, its
#     backfill AND its selectivity over the rows the condition takes, and a
#     UNIQUE one over duplicates it takes fails as the engine's 23000.
# THE PROOF IS THE ENGINE'S: the same DDL and DML run on twin files, and
# the engine then reads this server's file - the catalog rows, the BLR
# bytes, the queries planned THROUGH the new indexes - exactly as its own,
# and `gfix -v -full` finds it clean.
#
# Recorded elsewhere (TODO): a text column's key itype - this server
# stamps 1 where the engine stamps 4 over UTF8 - the plain-index law, which
# the partial index inherits.
#
#   qa/serve-real-exprindexddl.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4632}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/xddl-eng-$PORT.fdb"; FC="$D/xddl-fc-$PORT.fdb"; VFY="$D/xddl-vfy-$PORT.fdb"
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE D (ID INT, T VARCHAR(20), S VARCHAR(10), N INT, K INT, DT DATE);
INSERT INTO D VALUES (1, 'abc', 'active', 5, 50, DATE '2024-01-02');
INSERT INTO D VALUES (2, 'Déf', 'done', 7, 50, NULL);
INSERT INTO D VALUES (3, NULL, 'active', NULL, 200, DATE '2023-05-05');
INSERT INTO D VALUES (4, 'axe', 'active', -3, 300, DATE '2024-06-06');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/xddl-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/xddl-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-xddl-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf '%s\n' "$2" | timeout -s KILL 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$' \
    | sed -E 's/[0-9a-f]+:[0-9a-f]+/BLOBID/g; s/  */ /g; s/ *$//'; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}

DDL="CREATE INDEX X_U ON D COMPUTED BY (UPPER(T));
CREATE DESCENDING INDEX X_N2 ON D COMPUTED BY (N * 2);
CREATE INDEX X_Y ON D COMPUTED (EXTRACT(YEAR FROM DT));
CREATE INDEX X_D ON D COMPUTED BY (DT + 1);
CREATE INDEX X_C ON D COMPUTED BY (T || '-' || ID);
CREATE INDEX P_S ON D (S) WHERE S = 'active';
CREATE UNIQUE INDEX P_UK ON D (K) WHERE K > 100;
CREATE DESCENDING INDEX P_PN ON D (N) WHERE N > 0 AND T IS NOT NULL;
CREATE INDEX P_ST ON D (T) WHERE T STARTING WITH 'a';
CREATE INDEX P_NN ON D (N, K) WHERE N IS NOT NULL;
CREATE UNIQUE INDEX P_BAD ON D (K) WHERE K < 100;
COMMIT;
INSERT INTO D VALUES (5, 'ant', 'active', 9, 50, DATE '2025-01-01');
INSERT INTO D VALUES (6, 'b', 'x', 1, 300, NULL);
UPDATE D SET K = 999, T = 'ABC' WHERE ID = 1;
UPDATE D SET S = 'active' WHERE ID = 2;
COMMIT;"
echo "--- 1 the DDL and the DML after it answer alike (a UNIQUE partial over duplicates: 23000)"
check "1 eleven CREATE INDEX, four writes" "$(run "127.0.0.1/$REAL:$ENG" "$DDL")" "$(run "127.0.0.1/$PORT:$FC" "$DDL")"

echo "--- 2 the ENGINE reads this server's file: catalog, BLR, reads through the indexes"
cp "$FC" "$VFY"; chmod 666 "$VFY"
CAT="SET BLOB ALL;
SELECT RDB\$INDEX_NAME, RDB\$INDEX_ID, RDB\$SEGMENT_COUNT, RDB\$INDEX_TYPE, RDB\$UNIQUE_FLAG, RDB\$STATISTICS, RDB\$EXPRESSION_SOURCE, RDB\$CONDITION_SOURCE FROM RDB\$INDICES WHERE RDB\$RELATION_NAME = 'D' ORDER BY RDB\$INDEX_ID;
SELECT RDB\$INDEX_NAME, RDB\$FIELD_NAME, RDB\$FIELD_POSITION, RDB\$STATISTICS FROM RDB\$INDEX_SEGMENTS WHERE RDB\$INDEX_NAME STARTING WITH 'P_' ORDER BY 1, 3;"
check "2 RDB\$INDICES / RDB\$INDEX_SEGMENTS rows: sources, statistics, segments" "$(run "127.0.0.1/$REAL:$ENG" "$CAT")" "$(run "127.0.0.1/$REAL:$VFY" "$CAT")"
if command -v node >/dev/null 2>&1 && node -e 'require("node-firebird")' 2>/dev/null; then
    blr() { FC_DB="$1" FC_REAL="$REAL" timeout 30 node -e '
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_REAL,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,d)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        d.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
          tr.query("SELECT RDB$INDEX_NAME AS N, COALESCE(RDB$EXPRESSION_BLR, RDB$CONDITION_BLR) AS B FROM RDB$INDICES WHERE RDB$RELATION_NAME = \x27D\x27 ORDER BY RDB$INDEX_ID",[],(e2,rows)=>{
            const out=[];let left=rows.length;if(!left){console.log("none");process.exit(0);}
            rows.forEach((r,i)=>{if(typeof r.B!=="function"){out[i]=r.N.trim()+" -";if(--left===0){console.log(out.join(" "));process.exit(0);}return;}
              r.B(tr,(e3,n,em)=>{const b=[];em.on("data",c=>b.push(c));em.on("end",()=>{out[i]=r.N.trim()+" "+Buffer.concat(b).toString("hex");if(--left===0){console.log(out.join(" "));process.exit(0);}});});});
          });
        });
      });' 2>/dev/null; }
    e=$(blr "$ENG"); c=$(blr "$VFY")
    if [ -z "$e" ] || [ "$e" = CONN_ERR ]; then ran=$((ran + 1)); echo "FAIL 2 the BLR read never ran"; fail=1
    else check "2 RDB\$EXPRESSION_BLR / RDB\$CONDITION_BLR bytes [$e]" "$e" "$c"; fi
else
    echo "SKIP 2 BLR bytes: node-firebird not resolvable"
fi
for q in \
    "SELECT ID FROM D WHERE UPPER(T) = 'ABC';" \
    "SELECT ID FROM D WHERE N * 2 > 0 ORDER BY ID;" \
    "SELECT ID FROM D WHERE EXTRACT(YEAR FROM DT) = 2024 ORDER BY ID;" \
    "SELECT ID FROM D WHERE DT + 1 > DATE '2024-01-01' ORDER BY ID;" \
    "SELECT ID FROM D WHERE T || '-' || ID = 'ant-5';" \
    "SELECT ID FROM D WHERE S = 'active' ORDER BY ID;" \
    "SELECT ID FROM D WHERE K > 100 ORDER BY ID;" \
    "SELECT ID FROM D WHERE N > 0 AND T IS NOT NULL ORDER BY ID;" \
    "SELECT ID FROM D WHERE T STARTING WITH 'a' ORDER BY ID;"; do
    check "2 $q" "$(run "127.0.0.1/$REAL:$ENG" "SET PLAN ON; $q")" "$(run "127.0.0.1/$REAL:$VFY" "SET PLAN ON; $q")"
done
ran=$((ran + 1))
if "$GFIX" -v -full -user "$U" -pas "$P" "127.0.0.1/$REAL:$VFY" > /tmp/xddl-gfix.log 2>&1 && [ ! -s /tmp/xddl-gfix.log ]; then
    echo "OK   2 gfix -v -full finds this server's file clean"
else echo "DIFF 2 gfix -v -full:"; sed 's/^/     /' /tmp/xddl-gfix.log | head; fail=1; fi

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-xddl-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 14 on the 2026-10-05 binary, 14 OK
if [ "$ran" -lt 14 ]; then echo "FAIL only $ran checks ran (floor 14) - cells went missing"; fail=1; fi
exit $fail
