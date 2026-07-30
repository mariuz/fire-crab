#!/bin/bash
# `<dml> RETURNING <columns>` over the wire, against the REAL engine as a
# twin.
#
# Every check runs the SAME statement through the SAME driver
# (node-firebird) against TWO servers - fire-crab and the live Firebird -
# each with its own copy of an identical database, and requires:
#
#   * the same ROWS back (RETURNING is a cursor in Firebird 5: an UPDATE
#     that touches three rows returns three, not one), and
#   * the same TABLE afterwards - because a statement that returns the
#     right rows and writes the wrong thing is the failure this clause
#     invites.
#
# The values are the engine's: an INSERT and an UPDATE return the row as it
# stands AFTER the statement, a DELETE the row as it was.
#
#   qa/serve-real-returning.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666 so
# the SERVER's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4325}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ret-crab.fdb"
B="$D/fc-ret-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NAME VARCHAR(20));
CREATE TABLE G (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER DEFAULT 7);
COMMIT;
INSERT INTO T VALUES (1, 10, 'aa');
INSERT INTO T VALUES (2, 20, 'bb');
INSERT INTO T VALUES (3, NULL, 'cc');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-returning.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

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
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              const rows=Array.isArray(r)?r:(r?[r]:[]);
              console.log(JSON.stringify(rows));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
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

# --- the three statements, each returning what it touched -------------
both "INSERT ... RETURNING (the stored row)" \
     "INSERT INTO T VALUES (9, 90, 'zz') RETURNING ID, AMT, NAME"
both "UPDATE ... RETURNING one row (the NEW values)" \
     "UPDATE T SET AMT = AMT + 1 WHERE ID = 9 RETURNING ID, AMT"
both "UPDATE ... RETURNING MANY rows - a cursor, not a singleton" \
     "UPDATE T SET AMT = AMT + 1 WHERE AMT IS NOT NULL RETURNING ID, AMT"
both "DELETE ... RETURNING (the row as it WAS)" \
     "DELETE FROM T WHERE ID = 9 RETURNING ID, NAME, AMT"

# --- zero rows: an empty cursor, not an error --------------------------
both "UPDATE matching nothing returns no rows" \
     "UPDATE T SET NAME = 'x' WHERE ID = 99 RETURNING ID"
both "DELETE matching nothing returns no rows" \
     "DELETE FROM T WHERE ID = 99 RETURNING ID"

# --- the columns themselves --------------------------------------------
both "a single returned column" "INSERT INTO T VALUES (11, 110, 'k') RETURNING ID"
both "a NULL column comes back NULL" \
     "INSERT INTO T (ID, NAME) VALUES (12, 'n') RETURNING ID, AMT"
both "a DEFAULT filled in by the insert is returned" \
     "INSERT INTO G (ID) VALUES (1) RETURNING ID, N"
# a qualifier is allowed when it names the TABLE ...
both "a TABLE-qualified column in the list" \
     "INSERT INTO T VALUES (13, 130, 'q') RETURNING T.ID, T.AMT"

# --- the TABLE afterwards ---------------------------------------------
# a statement that returns the right rows and writes the wrong thing is
# exactly what this clause invites
both "the table after every statement above" \
     "SELECT ID, AMT, NAME FROM T ORDER BY ID"
both "and the second table" "SELECT ID, N FROM G ORDER BY ID"

# --- refusals ----------------------------------------------------------
# an expression in the RETURNING list is not converted; the statement must
# be REFUSED at prepare rather than run with an empty cursor - a write
# that happened while the client saw nothing is the worst outcome here
r=$(query "INSERT INTO T VALUES (20, 200, 'e') RETURNING AMT * 2" "$PORT" "$A")
after=$(query "SELECT COUNT(*) FROM T WHERE ID = 20" "$PORT" "$A")
case "$r:$after" in
    ERR*:*'"COUNT":0'*)
        echo "OK   an expression in RETURNING is refused, and nothing was written" ;;
    *) echo "DIFF expression RETURNING: [$r] table after: [$after]"; fail=1 ;;
esac

# ... and NEW./OLD. do NOT exist in DSQL - they are the PSQL trigger
# contexts. The engine answers `Column unknown, "NEW"."ID"`, so fire-crab
# must refuse too: accepting them would return rows for a statement the
# engine rejects AND write a row the engine never writes. This check is
# why the gate compares the TABLE as well as the rows.
a=$(query "INSERT INTO T VALUES (21, 210, 'x') RETURNING NEW.ID" "$PORT" "$A")
b=$(query "INSERT INTO T VALUES (21, 210, 'x') RETURNING NEW.ID" "$REAL" "$B")
aft_a=$(query "SELECT COUNT(*) FROM T WHERE ID = 21" "$PORT" "$A")
aft_b=$(query "SELECT COUNT(*) FROM T WHERE ID = 21" "$REAL" "$B")
case "$a:$b:$aft_a:$aft_b" in
    ERR*:ERR*:*'"COUNT":0'*:*'"COUNT":0'*)
        echo "OK   NEW.<col> is refused by BOTH, and neither wrote the row" ;;
    *) echo "DIFF NEW.<col>: fcwire [$a] engine [$b] rows [$aft_a] [$aft_b]"; fail=1 ;;
esac

rm -f "$A" "$B"
exit $fail
