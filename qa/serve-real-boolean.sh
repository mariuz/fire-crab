#!/bin/bash
# BOOLEAN as a VALUE and as a PREDICATE, against the REAL engine as a
# twin: the same driver, the same statement, two servers, two identical
# databases.
#
# Boolean columns had been readable for a long time and nothing else:
# `INSERT ... VALUES (TRUE)` was refused - the LITERAL, not the parameter
# - so a row with a boolean never landed, and every predicate over one
# refused too. (That refusal is what had been keeping
# qa/serve-real-params.sh red for dozens of increments.)
#
# BOOLEAN is the only type that is both a value and a predicate, and that
# is where the rules live:
#
#   1. `WHERE B` is a complete WHERE clause. It means `B = TRUE`, so the
#      NULL rows drop - and `WHERE NOT B` means `B <> TRUE`, which drops
#      them too. A converter that read a bare column as "not null" or as
#      "not false" would answer the NULL row in one of those.
#   2. `IS TRUE` and `IS FALSE` are TWO-valued: a NULL is simply not
#      true. Their negations are NOT the negated comparison - `B IS NOT
#      TRUE` RETURNS the NULL rows where `B <> TRUE` and `NOT (B = TRUE)`
#      both drop them. All three run side by side here, because the
#      difference is a row count rather than an error.
#   3. `IS UNKNOWN` is `IS NULL` by another name.
#   4. A boolean meets a boolean, or a string the engine converts
#      (`B = 'TRUE'`). It does NOT meet a number: `B = 1` is a conversion
#      error on the engine, so answering it would be worse than refusing.
#   5. The value side: literals in a VALUES list and a SET, NULL, and the
#      table compared after every write.
#
# One refusal is the driver's, not this server's: node-firebird cannot
# encode a JS boolean into a BOOLEAN parameter slot - the REAL ENGINE
# answers `Conversion error from string "1"` for it. The gate asserts
# both servers raise, which is the honest form of that check.
#
#   qa/serve-real-boolean.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4475}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-bool-crab.fdb"
B="$D/fc-bool-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# Two boolean columns so a boolean can be compared with a boolean, and a
# NULL in each so the three-valued cases have a row to disagree about.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, B BOOLEAN, C BOOLEAN, NAME VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, TRUE,  TRUE,  'aa');
INSERT INTO T VALUES (2, FALSE, TRUE,  'bb');
INSERT INTO T VALUES (3, NULL,  FALSE, 'cc');
INSERT INTO T VALUES (4, TRUE,  NULL,  'dd');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-boolean.log 2>&1 &
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

query() { # <sql> <json args> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_A="$2" FC_PORT="$3" FC_DB="$4" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,JSON.parse(process.env.FC_A),(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
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
    a=$(query "$2" "[]" "$PORT" "$A")
    b=$(query "$2" "[]" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
where() { # <label> <predicate>
    both "$1" "SELECT ID FROM T WHERE $2 ORDER BY ID"
}

# --- 1. a boolean column IS a predicate --------------------------------
where "a bare boolean column" "B"
where "NOT a bare boolean column" "NOT B"
where "two of them, ANDed" "B AND C"
where "two of them, ORed" "B OR C"
where "one beside an ordinary comparison" "B AND NAME = 'aa'"
where "parenthesised, with a comparison" "(B OR C) AND ID > 1"
where "both negated" "NOT B AND NOT C"

# --- 2. the three-valued family, side by side --------------------------
# these three differ ONLY on the NULL row, which is the whole point
where "= TRUE" "B = TRUE"
where "IS TRUE" "B IS TRUE"
where "IS NOT TRUE keeps the NULL row" "B IS NOT TRUE"
where "<> TRUE drops it" "B <> TRUE"
where "NOT (= TRUE) drops it too" "NOT (B = TRUE)"
where "= FALSE" "B = FALSE"
where "IS FALSE" "B IS FALSE"
where "IS NOT FALSE keeps the NULL row" "B IS NOT FALSE"

# --- 3. UNKNOWN is NULL ------------------------------------------------
where "IS UNKNOWN" "B IS UNKNOWN"
where "IS NOT UNKNOWN" "B IS NOT UNKNOWN"
where "IS NULL says the same thing" "B IS NULL"
where "IS NOT NULL" "B IS NOT NULL"
where "= NULL is UNKNOWN, so no row" "B = NULL"

# --- 4. what a boolean may be compared WITH ----------------------------
where "column against column" "B = C"
where "column against column, negated" "B <> C"
where "IN a list of literals" "B IN (TRUE)"
where "NOT IN" "B NOT IN (TRUE)"
where "a string the engine converts" "B = 'TRUE'"
where "a lower-case string too" "B = 'false'"
where "an aggregate subquery's boolean answer" "B = (SELECT MAX(B) FROM T)"
where "IN a subquery" "B IN (SELECT B FROM T WHERE ID = 1)"

# --- the value side ----------------------------------------------------
both "a boolean literal in the select list" "SELECT TRUE AS X FROM T WHERE ID = 1"
both "ORDER BY a boolean" "SELECT ID FROM T ORDER BY B, ID"
both "GROUP BY a boolean" "SELECT B, COUNT(*) FROM T GROUP BY B ORDER BY 1"
both "MIN/MAX/COUNT over a boolean" "SELECT MIN(B), MAX(B), COUNT(B) FROM T"

# --- 5. writing them ---------------------------------------------------
both "INSERT with boolean literals" "INSERT INTO T VALUES (5, TRUE, FALSE, 'ee')"
both "INSERT with a column list" "INSERT INTO T (ID, B) VALUES (6, FALSE)"
both "INSERT a NULL boolean" "INSERT INTO T (ID, B) VALUES (7, NULL)"
both "the table after the inserts" "SELECT ID, B, C FROM T ORDER BY ID"
both "UPDATE SET a boolean literal" "UPDATE T SET B = FALSE WHERE ID = 1"
both "UPDATE SET one where it IS NULL" "UPDATE T SET B = TRUE WHERE B IS NULL"
both "the table after the updates" "SELECT ID, B, C FROM T ORDER BY ID"
both "DELETE on a boolean predicate" "DELETE FROM T WHERE B = FALSE"
both "the table after the delete" "SELECT ID, B, C FROM T ORDER BY ID"

# --- 6. refusals -------------------------------------------------------
# a NUMBER is not a boolean: the engine raises a conversion error, so
# answering the comparison would be worse than refusing it
for bad in "B = 1" "B = 0"; do
    a=$(query "SELECT ID FROM T WHERE $bad" "[]" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $bad" "[]" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $bad is an error on BOTH, not a row set" ;;
        *) echo "DIFF $bad: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done
# a non-boolean column is not a predicate on its own
for bad in "NAME" "ID"; do
    a=$(query "SELECT ID FROM T WHERE $bad" "[]" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $bad" "[]" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   a bare $bad is not a predicate on either" ;;
        *) echo "DIFF bare $bad: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done
# and the driver's own limit, asserted as the shared refusal it is
a=$(query "INSERT INTO T (ID, B) VALUES (9, ?)" "[true]" "$PORT" "$A")
b=$(query "INSERT INTO T (ID, B) VALUES (9, ?)" "[true]" "$REAL" "$B")
case "$a:$b" in
    ERR*:ERR*) echo "OK   a boolean PARAMETER is refused by both - this driver cannot encode one" ;;
    *) echo "DIFF boolean parameter: fcwire [$a] engine [$b]"; fail=1 ;;
esac

rm -f "$A" "$B"
exit $fail
