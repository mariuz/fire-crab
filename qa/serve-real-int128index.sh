#!/bin/bash
# INT128 INDEX KEYS - idx_bcd (13), the itype the INT128-declaration
# slice fenced off. The key transform is Int128::makeIndexKey +
# Decimal128::makeBcdKey ported byte for byte: normalized BCD digits
# behind a 2-byte biased sign-folded exponent, nine's-complemented for
# negatives, packed 3-digits-per-10-bits - PMAX 39 (Int128.h declares
# TWO classes; the live engine takes 39-digit values exactly, so the
# built one is the PMAX-39 twin), BIAS 128, at most 19 bytes.
#
# The oracle is byte-equality BY BEHAVIOUR: the engine computes ITS key
# for a value and searches fire-crab's tree - so every duplicate the
# engine refuses on fc's file proves fc's stored key equals the
# engine's computed one for that value, and gfix -v -full recomputes
# every entry. The differential:
#   1. fire-crab creates an INT128 PK, a scaled NUMERIC(38,2) UNIQUE
#      index and a multi-segment (INT, INT128) index, INSERTs through
#      them (negatives, zero, i64-sized), refuses its own duplicates;
#   2. the engine, on fc's file, refuses a duplicate of EVERY fc key,
#      inserts the 39-digit extremes into fc's trees, refuses ITS own
#      duplicates, and navigates WHERE K = <value> per row;
#   3. fire-crab maintains an ENGINE-created INT128 index (insert +
#      duplicate refusal both ways);
#   4. gfix -v -full over the mixed fc/engine entries, on both tables;
#   5. the same statements on a ref copy give the same tables.
#
#   qa/serve-real-int128index.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4288}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-i128x-work.fdb"; REF="$D/fc-i128x-ref.fdb"
FBK="$D/fc-i128x-work.fbk"; RST="$D/fc-i128x-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# the engine lays an INT128-indexed table of its own on both copies -
# fire-crab must maintain an ENGINE-built idx_bcd tree too
for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE Y (P INT128 NOT NULL PRIMARY KEY);
COMMIT;
INSERT INTO Y VALUES (1000);
COMMIT;
EOF
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-i128x.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_q() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||!r.length){console.log("OK");db.detach();process.exit(0);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v)).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_q "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
refuse() { # <label> <got>
    case "$2" in
        ERR*) echo "OK   $1" ;;
        *) echo "DIFF $1 (want refusal, got: $2)"; fail=1 ;;
    esac
}

# --- 1. fire-crab builds and fills INT128 indexes ----------------------
check "fc: INT128 PRIMARY KEY table" \
      "$(node_run 'CREATE TABLE X (K INT128 NOT NULL PRIMARY KEY, N NUMERIC(38,2), ID INTEGER)')" "OK"
check "fc: UNIQUE index over NUMERIC(38,2)" "$(node_run 'CREATE UNIQUE INDEX XN ON X (N)')" "OK"
check "fc: multi-segment (INT, INT128) index" "$(node_run 'CREATE INDEX XM ON X (ID, K)')" "OK"
for row in "-5000000000, -2, 1" "-3, 0, 2" "0, 2, 3" "7, 5, 4" "9223372036854775807, 9, 5"; do
    check "fc INSERT ($row)" "$(node_run "INSERT INTO X (K, N, ID) VALUES ($row)")" "OK"
done
refuse "fc refuses its own PK duplicate (K = 7)" \
       "$(node_run 'INSERT INTO X (K, N, ID) VALUES (7, 90, 9)')"
refuse "fc refuses its own UNIQUE duplicate (N = 5.00)" \
       "$(node_run 'INSERT INTO X (K, N, ID) VALUES (90, 5, 9)')"
# (WHERE on an INT128 column is outside fc's predicate surface - the
# integer ID selects the row instead)
check "fc UPDATE moves a multi-segment key (IDX_modify adds an entry)" \
      "$(node_run 'UPDATE X SET ID = 40 WHERE ID = 4')" "OK"
check "fc maintains the ENGINE-built idx_bcd tree (INSERT INTO Y)" \
      "$(node_run 'INSERT INTO Y VALUES (-2000)')" "OK"
refuse "fc refuses a duplicate against the ENGINE's entry (Y = 1000)" \
       "$(node_run 'INSERT INTO Y VALUES (1000)')"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 2. the engine, on fc's file: every fc key is ITS key --------------
dup() { # <file> <stmt> -> engine output
    "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 <<< "$2;"
}
for k in -5000000000 -3 0 7 9223372036854775807; do
    out=$(dup "$WORK" "INSERT INTO X (K, N, ID) VALUES ($k, 77, 9)")
    case "$out" in
        *"violation of PRIMARY or UNIQUE KEY"*)
            echo "OK   the engine finds fc's key for K = $k (duplicate refused)" ;;
        *) echo "DIFF engine dup for K = $k"; echo "     $out"; fail=1 ;;
    esac
done
out=$(dup "$WORK" "INSERT INTO X (K, N, ID) VALUES (91, 5, 9)")
case "$out" in
    *"duplicate value"*) echo "OK   the engine finds fc's scaled UNIQUE key (N = 5.00)" ;;
    *) echo "DIFF engine dup for N"; echo "     $out"; fail=1 ;;
esac
out=$(dup "$WORK" "INSERT INTO Y VALUES (-2000)")
case "$out" in
    *"violation of PRIMARY or UNIQUE KEY"*) echo "OK   the engine finds fc's entry in its OWN tree (Y = -2000)" ;;
    *) echo "DIFF engine dup for Y"; echo "     $out"; fail=1 ;;
esac
# the 39-digit extremes go INTO fc's tree through the engine
"$ISQL" -q -user "$U" -pas "$P" "$WORK" >/dev/null 2>&1 <<'SQL'
INSERT INTO X (K, N, ID) VALUES (170141183460469231731687303715884105727, 11, 6);
INSERT INTO X (K, N, ID) VALUES (-170141183460469231731687303715884105728, 12, 7);
INSERT INTO X (K, N, ID) VALUES (99999999999999999999999999999999999999, 13, 8);
COMMIT;
SQL
out=$(dup "$WORK" "INSERT INTO X (K, N, ID) VALUES (170141183460469231731687303715884105727, 78, 9)")
case "$out" in
    *"violation of PRIMARY or UNIQUE KEY"*) echo "OK   the engine's own 39-digit entry in fc's tree detects its duplicate" ;;
    *) echo "DIFF engine extreme dup"; echo "     $out"; fail=1 ;;
esac
# navigation: WHERE K = <value> walks the PK index over MIXED entries
nav=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'F|'||ID FROM X WHERE K = -5000000000;
SELECT 'F|'||ID FROM X WHERE K = 7;
SELECT 'F|'||ID FROM X WHERE K = 170141183460469231731687303715884105727;
SELECT 'F|'||ID FROM X WHERE K = -170141183460469231731687303715884105728;
SQL
)
check "the engine navigates fc's PK index to every row (mixed entries)" \
      "$nav" "F|1
F|40
F|6
F|7"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean over the mixed fc/engine idx_bcd entries" "$(printf '%s' "$valw" | strip)" ""

# --- 3. the same statements on the ref give the same tables ------------
"$ISQL" -q -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
CREATE TABLE X (K INT128 NOT NULL PRIMARY KEY, N NUMERIC(38,2), ID INTEGER);
CREATE UNIQUE INDEX XN ON X (N);
CREATE INDEX XM ON X (ID, K);
COMMIT;
INSERT INTO X (K, N, ID) VALUES (-5000000000, -2, 1);
INSERT INTO X (K, N, ID) VALUES (-3, 0, 2);
INSERT INTO X (K, N, ID) VALUES (0, 2, 3);
INSERT INTO X (K, N, ID) VALUES (7, 5, 4);
INSERT INTO X (K, N, ID) VALUES (9223372036854775807, 9, 5);
UPDATE X SET ID = 40 WHERE ID = 4;
INSERT INTO Y VALUES (-2000);
INSERT INTO X (K, N, ID) VALUES (170141183460469231731687303715884105727, 11, 6);
INSERT INTO X (K, N, ID) VALUES (-170141183460469231731687303715884105728, 12, 7);
INSERT INTO X (K, N, ID) VALUES (99999999999999999999999999999999999999, 13, 8);
COMMIT;
SQL
dumpq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'X|'||K||'|'||N||'|'||ID FROM X ORDER BY K;
SELECT 'Y|'||P FROM Y ORDER BY P;
SQL
}
check "the tables match the ref, ordered BY the INT128 key" "$(dumpq "$WORK")" "$(dumpq "$REF")"

# --- 4. gbak and gfix ----------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-i128x-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-i128x-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-i128x-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-i128x-restore.log; then
    echo "OK   gbak RESTORES it (indexes rebuilt over the INT128 keys)"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-i128x-restore.log | head; fail=1
fi

exit $fail
