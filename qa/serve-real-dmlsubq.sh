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
CREATE TABLE W (ID INTEGER, AMT INTEGER);
CREATE TABLE K (S VARCHAR(20));
CREATE TABLE KOK (S VARCHAR(20));
COMMIT;
INSERT INTO T VALUES (1, 10, 1);
INSERT INTO T VALUES (2, 20, 1);
INSERT INTO T VALUES (3, 30, 2);
INSERT INTO T VALUES (4, 40, 2);
INSERT INTO T VALUES (5, NULL, 3);
INSERT INTO U VALUES (2, 'x', 100);
INSERT INTO U VALUES (3, 'y', 200);
INSERT INTO U VALUES (9, 'z', 300);
INSERT INTO W VALUES (1, 10);
INSERT INTO W VALUES (5, 50);
INSERT INTO W VALUES (12, 120);
INSERT INTO K VALUES ('1 2');
INSERT INTO KOK VALUES ('12');
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
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

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

# --- A SUBQUERY'S VALUE IS A HASH KEY, AND KEYS CONVERT STRICTLY -------
# The engine turns a POSITIVE `IN (<subquery>)` / correlated `EXISTS`
# written as a top-level conjunct into a SEMI-JOIN (`PLAN HASH`) and
# converts its keys with the STRICT store grammar as it builds the hash
# table - so a text column holding '1 2', which the LENIENT per-row
# compare reads as 12, raises 22018 here and the statement writes
# NOTHING. serve-real-textcolcmp.sh owns the law; these are the shapes
# where getting it wrong is a WRONG WRITE rather than a wrong answer.
# Everything the engine does not hash - `NOT IN`, the same IN under an
# OR, a scalar subquery - keeps the lenient grammar and DOES write.
#
# THE ENGINE IS THE READER for every phase below: a write fire-crab
# alone can see is exactly what a re-read through fire-crab would miss.
eread() { # <label> <sql> - the same read from BOTH files, by the ENGINE
    a=$(query "$2" "$REAL" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1 (read back through the ENGINE)"
        echo "     fcwire's file: $a"
        echo "     engine's file: $b"
        fail=1
    fi
}
wstate() { eread "$1 - table W through the engine" \
                 "SELECT ID, AMT FROM W ORDER BY ID, AMT"; }
wstate "before the hash-key phase"

both "UPDATE ... WHERE ID IN (SELECT <text>) raises" \
     "UPDATE W SET AMT = 77 WHERE ID IN (SELECT S FROM K)"
wstate "after the raising IN update"
both "DELETE ... WHERE ID IN (SELECT <text>) raises" \
     "DELETE FROM W WHERE ID IN (SELECT S FROM K)"
wstate "after the raising IN delete"
both "UPDATE ... WHERE EXISTS (correlated) raises" \
     "UPDATE W SET AMT = 77 WHERE EXISTS (SELECT 1 FROM K WHERE K.S = W.ID)"
wstate "after the raising EXISTS update"
both "DELETE ... WHERE EXISTS (correlated) raises" \
     "DELETE FROM W WHERE EXISTS (SELECT 1 FROM K WHERE K.S = W.ID)"
wstate "after the raising EXISTS delete"
# A RECORDED BOUNDARY, and NOT this slice's: an INSERT..SELECT whose
# WHERE carries ANY per-row conversion raiser refuses at prepare rather
# than raising it - `WHERE ID = 'x'` does the same, and did before the
# hash key existed. Both sides still write nothing, which is what the
# re-read below asserts.
bound() { # <label> <sql> - fire-crab must REFUSE; the engine's answer is recorded
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    case "$a" in
        ERR*) echo "BOUND $1"; echo "      fc:  $a"; echo "      eng: $b" ;;
        *) echo "DIFF $1 - fire-crab ANSWERED where the boundary says refuse"
           echo "     got: $a"; fail=1 ;;
    esac
}
bound "INSERT ... SELECT whose WHERE hashes: fc refuses, engine raises" \
      "INSERT INTO W SELECT ID, 1 FROM W WHERE ID IN (SELECT S FROM K)"
wstate "after the refused INSERT..SELECT"

# the un-hashed shapes: the lenient grammar, and the write LANDS
both "NOT IN is an anti-join - the lenient grammar writes" \
     "UPDATE W SET AMT = 88 WHERE ID NOT IN (SELECT S FROM K)"
wstate "after the NOT IN update"
both "the same IN under an OR writes too" \
     "UPDATE W SET AMT = 66 WHERE ID IN (SELECT S FROM K) OR ID = 1"
wstate "after the OR-guarded IN update"
both "a scalar subquery is a singleton, not a key" \
     "UPDATE W SET AMT = 99 WHERE ID = (SELECT S FROM K)"
wstate "after the scalar-subquery update"
both "a key the strict grammar TAKES converts and writes" \
     "UPDATE W SET AMT = 55 WHERE ID IN (SELECT S FROM KOK)"
wstate "after the convertible-key update"
both "the inner text table is untouched throughout" \
     "SELECT S FROM K ORDER BY S"

rm -f "$A" "$B"
exit $fail
