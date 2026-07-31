#!/bin/bash
# ALTER TABLE ADD COLUMN through fire-crab. The engine models ADD as a new
# FORMAT VERSION: existing records keep their old format and read the new
# column as NULL, new records use the new format. fire-crab writes the new
# RDB$FORMATS row, the new column's RDB$FIELDS/RDB$RELATION_FIELDS rows,
# rebuilds RDB$RUNTIME (which DSQL resolves columns through) and version-
# rewrites the RDB$RELATIONS row to bump its format and field count.
#
# THE differential: the C++ ENGINE then opens fire-crab's altered file and
# treats it as its own - reads the old rows (new column NULL) and the
# fire-crab-inserted new-format rows, WRITES its own row into it, and gbak
# RESTORES the file (a restore replays the catalog as real engine DDL, the
# deepest read of every byte). Every read is cross-checked against the same
# ALTER applied by the engine itself to a REFERENCE copy.
#
#   qa/serve-real-alter.sh [port]
#
# Builds its own scratch database (charset NONE).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4081}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/alter_src.fdb"; CLEAN="$DIR/alter_clean.fdb"
WORK="/tmp/fc-alter-work.fdb"; REF="/tmp/fc-alter-ref.fdb"; RESTORED="/tmp/fc-alter-restored.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$REF" "$RESTORED"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B VARCHAR(5));
COMMIT;
INSERT INTO T VALUES (1, 'x');
INSERT INTO T VALUES (2, 'yy');
COMMIT;
EOF
# a clean gbak copy (no lingering transactions), for WORK and REF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/alter.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/alter.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"

# the engine applies the SAME alters to REF, as the oracle: add two
# columns then drop the original B, leaving A, C, D
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<EOF >/dev/null 2>&1
ALTER TABLE T ADD C INTEGER;
ALTER TABLE T ADD D VARCHAR(3);
ALTER TABLE T DROP B;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-alter.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$RESTORED" "$DIR/alter.fbk" /tmp/fc-alter-work.fbk' EXIT
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
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$1"; }

node_once() { # <db> <sql> [params-js-array]
    FC_DB="$1" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$2" FC_PARAMS="${3:-[]}" \
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
node_run() { # <sql> [params]
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$WORK" "$1" "${2:-[]}")
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

# --- phase 1: ALTER through fire-crab, use the table through fire-crab -
check "alter add integer column"  "$(node_run "ALTER TABLE T ADD C INTEGER")"    "<no rows>"
check "old rows read new col NULL" "$(node_run "SELECT A, B, C FROM T ORDER BY A")" \
"1|x|<null>
2|yy|<null>"
check "alter add second column"   "$(node_run "ALTER TABLE T ADD D VARCHAR(3)")" "<no rows>"
# --- DROP the original B: a new format version, survivors keep their
#     field ids (A=0, C=2, D=3), B's bytes stay in old records unread -----
check "alter drop column"          "$(node_run "ALTER TABLE T DROP B")"          "<no rows>"
check "old rows read survivors"    "$(node_run "SELECT A, C, D FROM T ORDER BY A")" \
"1|<null>|<null>
2|<null>|<null>"
check "insert a new-format row"    "$(node_run "INSERT INTO T (A, C, D) VALUES (3, ?, ?)" '[99,"pq"]')" \
    "<no rows>"
check "fire-crab reads survivors"  "$(node_run "SELECT A, C, D FROM T ORDER BY A")" \
"1|<null>|<null>
2|<null>|<null>
3|99|pq"
check "where on a surviving column" "$(node_run "SELECT A FROM T WHERE C = 99")" "3"
# a duplicate column, an ALTER of a missing table, a DROP of a missing
# column, and a DROP of the only column all raise SQL errors
case "$(node_run "ALTER TABLE T ADD C INTEGER")" in
    ERR*) echo "OK   duplicate column refused" ;;
    *) echo "DIFF duplicate column refused"; fail=1 ;;
esac
case "$(node_run "ALTER TABLE NOSUCH ADD X INTEGER")" in
    ERR*) echo "OK   alter of missing table refused" ;;
    *) echo "DIFF alter of missing table refused"; fail=1 ;;
esac
case "$(node_run "ALTER TABLE T DROP NOSUCH")" in
    ERR*) echo "OK   drop of missing column refused" ;;
    *) echo "DIFF drop of missing column refused"; fail=1 ;;
esac

# --- phase 2: the ENGINE adopts fire-crab's altered file ---------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the engine reads WORK exactly as it reads its own REF (same ALTERs), for
# the two rows both applied - fire-crab's new-format row 3 is WORK-only, so
# compare rows 1-2 which exist on both
# SET LIST ON prints one field per line (name + value), avoiding isql's
# tabular column-width whitespace, which is a display heuristic not a value
w12=$(run_isql "$WORK" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT A, C, D FROM T WHERE A <= 2 ORDER BY A;
EOF
)
r12=$(run_isql "$REF" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT A, C, D FROM T WHERE A <= 2 ORDER BY A;
EOF
)
check "engine reads WORK == engine reads REF" "$w12" "$r12"

# SHOW TABLE definitions must match the engine's own ALTER result
sw=$(echo "SHOW TABLE T;" | run_isql "$WORK" 2>&1 | strip | grep -v '^$')
sr=$(echo "SHOW TABLE T;" | run_isql "$REF" 2>&1 | strip | grep -v '^$')
check "SHOW TABLE WORK == REF" "$sw" "$sr"

# the engine reads fire-crab's own new-format INSERT
w3=$(run_isql "$WORK" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT C, D FROM T WHERE A = 3;
EOF
)
check "engine reads fire-crab's new-format row" "$(echo $w3)" "C 99 D pq"

# gfix validates the physical file
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean" "$(printf '%s' "$val" | strip)" ""

# the engine WRITES its own row into fire-crab's altered table
run_isql "$WORK" <<EOF >/dev/null 2>&1
INSERT INTO T VALUES (4, 400, 'rs');
COMMIT;
EOF
cnt=$(run_isql "$WORK" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT COUNT(*) AS N FROM T;
EOF
)
check "engine writes into the altered table" "$(echo $cnt)" "N 4"

# gbak backup+restore: replays the catalog as real engine-side DDL
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-alter-work.fbk >/dev/null 2>&1 &&
   "$GBAK" -c -user "$U" -pas "$P" /tmp/fc-alter-work.fbk "$RESTORED" >/dev/null 2>&1; then
    rr=$(run_isql "$RESTORED" <<EOF | strip | grep -v '^$'
SET LIST ON;
SELECT C, D FROM T WHERE A = 3;
EOF
)
    check "gbak restore preserves the altered columns" "$(echo $rr)" "C 99 D pq"
else
    echo "DIFF gbak backup/restore"; fail=1
fi

exit $fail
