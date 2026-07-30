#!/bin/bash
# Subqueries in a DML statement's WHERE - `UPDATE ... WHERE ID IN (SELECT
# ...)`, `DELETE ... WHERE ID = (SELECT MIN(...))` - checked against the
# REAL engine as a twin: the same driver, the same statement, two servers,
# two identical databases, and after EVERY statement the tables are
# compared.
#
# The predicate is the one the SELECT path already answered; what was
# missing was the lifting pass in front of it. So the interesting part of
# this gate is not that the rows come back - a DML returns none - but that
# the WRITE matches: a subquery filter that selects the wrong rows deletes
# the wrong rows, and only the table shows it.
#
#   qa/serve-real-dmlsubq.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666 so
# the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4405}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-dmlsubq-crab.fdb"
B="$D/fc-dmlsubq-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, G INTEGER);
CREATE TABLE U (UID INTEGER, TAG VARCHAR(10), N INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10, 1);
INSERT INTO T VALUES (2, 20, 1);
INSERT INTO T VALUES (3, 30, 2);
INSERT INTO T VALUES (4, 40, 2);
INSERT INTO T VALUES (5, NULL, 3);
INSERT INTO U VALUES (2, 'x', 100);
INSERT INTO U VALUES (3, 'y', 200);
INSERT INTO U VALUES (9, 'z', 300);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dmlsubq.log 2>&1 &
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
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
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

# after each write, the TABLE is the check - a DML returns no rows, so a
# wrong subquery filter is invisible until the contents are compared
state() { # <label>
    both "$1 - table T" "SELECT ID, AMT, G FROM T ORDER BY ID"
}

# --- IN a subquery -----------------------------------------------------
both "UPDATE ... WHERE ID IN (SELECT ...)" \
     "UPDATE T SET AMT = 0 WHERE ID IN (SELECT UID FROM U)"
state "after the IN update"

# --- a subquery with its OWN filter ------------------------------------
both "UPDATE ... WHERE ID IN (SELECT ... WHERE ...)" \
     "UPDATE T SET G = 7 WHERE ID IN (SELECT UID FROM U WHERE TAG = 'y')"
state "after the filtered-IN update"

# --- NOT IN, where a NULL in the subquery would change everything ------
both "UPDATE ... WHERE ID NOT IN (SELECT ...)" \
     "UPDATE T SET AMT = 99 WHERE ID NOT IN (SELECT UID FROM U)"
state "after the NOT IN update"

# --- a scalar subquery on the right of a comparison --------------------
both "UPDATE ... WHERE ID = (SELECT MIN(...))" \
     "UPDATE T SET G = 5 WHERE ID = (SELECT MIN(UID) FROM U)"
state "after the scalar-subquery update"
both "UPDATE ... WHERE AMT < (SELECT MAX(N) FROM U)" \
     "UPDATE T SET G = 6 WHERE AMT < (SELECT MAX(N) FROM U)"
state "after the comparison-to-aggregate update"

# --- the same shapes for DELETE ----------------------------------------
both "DELETE ... WHERE ID IN (SELECT ... WHERE ...)" \
     "DELETE FROM T WHERE ID IN (SELECT UID FROM U WHERE TAG = 'y')"
state "after the IN delete"
both "DELETE ... WHERE ID NOT IN (SELECT ...)" \
     "DELETE FROM T WHERE ID NOT IN (SELECT UID FROM U)"
state "after the NOT IN delete"

# --- a subquery that matches NOTHING -----------------------------------
both "UPDATE whose subquery is empty touches no row" \
     "UPDATE T SET AMT = -1 WHERE ID IN (SELECT UID FROM U WHERE TAG = 'nope')"
state "after the empty-subquery update"

# --- and the other table is untouched throughout -----------------------
both "table U is untouched" "SELECT UID, TAG, N FROM U ORDER BY UID"

rm -f "$A" "$B"
exit $fail
