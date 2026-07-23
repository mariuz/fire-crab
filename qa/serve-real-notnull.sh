#!/bin/bash
# ALTER TABLE ALTER COLUMN SET/DROP NOT NULL through fire-crab. Unlike ADD/
# DROP/TYPE, a NOT NULL constraint changes no record layout, so there is no
# new format version: fire-crab sets (or clears) the column's
# RDB$RELATION_FIELDS.RDB$NULL_FLAG, writes (or deletes) an
# RDB$RELATION_CONSTRAINTS "NOT NULL" row and its RDB$CHECK_CONSTRAINTS link
# (trigger_name = the column), and refreshes RDB$RUNTIME. SET NOT NULL is
# refused - as the engine refuses it - if the column already holds a NULL.
#
# THE differential: the C++ ENGINE opens fire-crab's file and treats the
# constraint as its own - SHOW TABLE renders it like the engine's own ALTER
# of a reference copy, and the engine ENFORCES it (a NULL insert into the
# constrained column is rejected). gfix validates and gbak restores it.
#
#   qa/serve-real-notnull.sh [port]
#
# Builds its own scratch database (charset NONE).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4084}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/nn_src.fdb"; CLEAN="$DIR/nn_clean.fdb"
WORK="/tmp/fc-nn-work.fdb"; REF="/tmp/fc-nn-ref.fdb"; RESTORED="/tmp/fc-nn-restored.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK" "$REF" "$RESTORED"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B INTEGER, C INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10, 100);
INSERT INTO T VALUES (2, 20, NULL);
COMMIT;
EOF
"$GBAK" -b -g -user "$U" -pas "$P" "$SRC" "$DIR/nn.fbk" >/dev/null 2>&1 &&
"$GBAK" -c -user "$U" -pas "$P" "$DIR/nn.fbk" "$CLEAN" >/dev/null 2>&1 ||
    { echo "FAIL gbak clean copy"; exit 1; }
cp "$CLEAN" "$WORK"; cp "$CLEAN" "$REF"

# the engine applies the SAME sequence to REF, as the oracle: A gains NOT
# NULL, B gains then loses it - leaving A NOT NULL, B and C nullable
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" <<EOF >/dev/null 2>&1
ALTER TABLE T ALTER A SET NOT NULL;
ALTER TABLE T ALTER B SET NOT NULL;
ALTER TABLE T ALTER B DROP NOT NULL;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nn.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$RESTORED" "$DIR/nn.fbk" /tmp/fc-nn-work.fbk' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$1"; }

node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" \
    timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
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

# --- phase 1: SET / DROP NOT NULL through fire-crab --------------------
check "set A not null"          "$(node_run "ALTER TABLE T ALTER A SET NOT NULL")"          "<no rows>"
check "set B not null"          "$(node_run "ALTER TABLE T ALTER COLUMN B SET NOT NULL")"   "<no rows>"
check "drop B not null"         "$(node_run "ALTER TABLE T ALTER B DROP NOT NULL")"         "<no rows>"
# SET NOT NULL on C fails - row 2 holds a NULL there
case "$(node_run "ALTER TABLE T ALTER C SET NOT NULL")" in
    ERR*) echo "OK   set not null with NULLs present refused" ;;
    *) echo "DIFF set not null with NULLs present refused"; fail=1 ;;
esac
case "$(node_run "ALTER TABLE T ALTER NOSUCH SET NOT NULL")" in
    ERR*) echo "OK   set not null on missing column refused" ;;
    *) echo "DIFF set not null on missing column refused"; fail=1 ;;
esac

# --- phase 2: the ENGINE adopts and ENFORCES fire-crab's constraint ----
kill $srv 2>/dev/null; wait $srv 2>/dev/null

sw=$(echo "SHOW TABLE T;" | run_isql "$WORK" 2>&1 | strip | grep -v '^$')
sr=$(echo "SHOW TABLE T;" | run_isql "$REF" 2>&1 | strip | grep -v '^$')
check "SHOW TABLE WORK == REF" "$sw" "$sr"

# the engine ENFORCES the NOT NULL fire-crab wrote: a NULL into A is refused
enf=$(run_isql "$WORK" <<EOF 2>&1 | strip | grep -iE "validation|null" | head -1
INSERT INTO T (B, C) VALUES (5, 6);
EOF
)
case "$enf" in
    *validation*|*null*) echo "OK   engine enforces the NOT NULL (NULL into A refused)" ;;
    *) echo "DIFF engine enforces the NOT NULL"; echo "     got: $enf"; fail=1 ;;
esac

# a valid insert (A supplied) succeeds, and B (its NOT NULL dropped) takes NULL
val=$(run_isql "$WORK" <<EOF 2>&1 | strip | grep -v '^$'
INSERT INTO T (A) VALUES (7);
COMMIT;
SET LIST ON;
SELECT COUNT(*) AS N FROM T;
EOF
)
check "valid insert with A, B/C NULL" "$(echo $val)" "N 3"

val2=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean" "$(printf '%s' "$val2" | strip)" ""

# gbak backup+restore: replays the constraint as real engine-side DDL, and
# the restored copy still enforces it
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" /tmp/fc-nn-work.fbk >/dev/null 2>&1 &&
   "$GBAK" -c -user "$U" -pas "$P" /tmp/fc-nn-work.fbk "$RESTORED" >/dev/null 2>&1; then
    renf=$(run_isql "$RESTORED" <<EOF 2>&1 | strip | grep -iE "validation|null" | head -1
INSERT INTO T (B, C) VALUES (8, 9);
EOF
)
    case "$renf" in
        *validation*|*null*) echo "OK   gbak restore preserves the enforced NOT NULL" ;;
        *) echo "DIFF gbak restore preserves the enforced NOT NULL"; echo "     got: $renf"; fail=1 ;;
    esac
else
    echo "DIFF gbak backup/restore"; fail=1
fi

exit $fail
