#!/bin/bash
# STARTING [WITH] against the REAL engine as a twin: the same driver,
# the same statement, two servers, two identical databases.
#
# The roadmap had carried "STARTING WITH is not in the predicate parser"
# since the fragment gate was built - the engine answers it, fire-crab
# refused every direct-SQL spelling. (The serve-real gates that already
# contained STARTING WITH all sent it through isql against the FILE, so
# no gate ever measured the server on it.)
#
# The semantics under test, each probed against the engine first:
#
#   1. A per-BYTE prefix on the STORED value, no trimming on either
#      side: CHAR(5) 'ab' stores 'ab   ' and matches prefixes 'ab ' and
#      'ab   ' but not a six-char one; VARCHAR 'ab' does NOT match
#      prefix 'ab '. (The BLR path this server keeps for isql's SHOW
#      trims both sides - right for padded metadata columns, wrong in
#      general, and deliberately NOT copied here.)
#   2. The empty prefix matches every non-NULL row; a NULL prefix or a
#      NULL value is UNKNOWN under BOTH polarities (3VL).
#   3. WITH is optional sugar; NOT STARTING negates the leaf.
#   4. An INTEGER column coerces to its decimal text per row (N=1,10
#      both match '1').
#   5. STARTING is NOT a reserved word - a column may be named by it.
#   6. The index path: fcopt answers INDEX for a prefix test, but the
#      retrieval has no band-builder for it, so the statement SCANS -
#      never a partial answer. Asserted by running the row probes
#      against an FC_NO_INDEX twin as well.
#
# Refusals kept, each one an engine answer recorded for a later slice:
# a column prefix (V STARTING WITH C), an expression prefix ('a'||'b'),
# a numeric prefix literal (V STARTING WITH 1).
#
#   qa/serve-real-starting.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4477}"
PORT2=$((PORT + 1))
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-starting-crab.fdb"
B="$D/fc-starting-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# CHAR beside VARCHAR so padding can disagree; a NULL row for the 3VL
# cases; an empty string; a VARCHAR value with its own trailing blank;
# and indexes on V and ID so the scan-not-band claim is under test.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, C CHAR(5), V VARCHAR(10), N INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 'ab',  'ab',   1);
INSERT INTO T VALUES (2, 'abc', 'abc',  10);
INSERT INTO T VALUES (3, 'AB',  'AB',   25);
INSERT INTO T VALUES (4, NULL,  NULL,   NULL);
INSERT INTO T VALUES (5, 'xy',  'ab ',  2);
INSERT INTO T VALUES (6, '',    '',     0);
COMMIT;
CREATE INDEX T_V ON T (V);
CREATE INDEX T_ID ON T (ID);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-starting.log 2>&1 &
srv=$!
FC_NO_INDEX=1 "$FCWIRE" serve "127.0.0.1:$PORT2" "$U" "$P" >/tmp/fc-serve-starting2.log 2>&1 &
srv2=$!
trap 'kill $srv $srv2 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null \
        && nc -z 127.0.0.1 "$PORT2" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "SOMETHING is listening" is not "OUR server is listening": if the port
# was taken, fcwire exited at bind and the checks measure the other
# server. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}
kill -0 $srv2 2>/dev/null || {
    echo "FAIL the FC_NO_INDEX twin is not running - port $PORT2 in use?"
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

both() { # <label> <sql> [json args]
    args="${3:-[]}"
    a=$(query "$2" "$args" "$PORT" "$A")
    a2=$(query "$2" "$args" "$PORT2" "$A")
    b=$(query "$2" "$args" "$REAL" "$B")
    if [ "$a" = "$b" ] && [ "$a2" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire:   $a"
        echo "     no-index: $a2"
        echo "     engine:   $b"
        fail=1
    fi
}
where() { # <label> <predicate> [json args]
    both "$1" "SELECT ID FROM T WHERE $2 ORDER BY ID" "${3:-[]}"
}

# --- 1. the prefix rule, byte by byte ----------------------------------
where "VARCHAR prefix" "V STARTING WITH 'ab'"
where "CHAR prefix" "C STARTING WITH 'ab'"
where "CHAR pad participates (one blank)" "C STARTING WITH 'ab '"
where "CHAR pad participates (full width)" "C STARTING WITH 'ab   '"
where "a prefix longer than the CHAR" "C STARTING WITH 'ab    '"
where "VARCHAR keeps ITS trailing blank" "V STARTING WITH 'ab '"
where "case-sensitive" "V STARTING WITH 'AB'"
where "the empty prefix takes every non-NULL row" "V STARTING WITH ''"
where "... on the CHAR column too" "C STARTING WITH ''"

# --- 2. three-valued logic ---------------------------------------------
where "a NULL prefix is UNKNOWN" "V STARTING WITH NULL"
where "... under NOT as well" "V NOT STARTING WITH NULL"
where "NOT STARTING drops the NULL row" "V NOT STARTING WITH 'ab'"
where "NOT (...) says the same thing" "NOT V STARTING WITH 'ab'"
where "NOT around the parenthesised leaf" "NOT (V STARTING WITH 'ab')"

# --- 3. spellings and neighbours ---------------------------------------
where "WITH is optional" "V STARTING 'ab'"
where "NOT STARTING without WITH" "V NOT STARTING 'ab'"
where "beside an equality on an indexed column" "ID = 2 AND V STARTING WITH 'ab'"
where "in a disjunction" "V STARTING WITH 'ab' OR ID = 3"
# HAVING funnels through the same typed_term the WHERE uses, so the
# text group key and the integer-coercion case are both one leaf
both "HAVING on a text group key" "SELECT COUNT(*) N FROM T GROUP BY V HAVING V STARTING WITH 'ab'"
both "HAVING coerces an integer group key" "SELECT ID, COUNT(*) N FROM T GROUP BY ID HAVING ID STARTING WITH '5'"

# --- 4. non-text sides -------------------------------------------------
where "an INTEGER column coerces to text" "N STARTING WITH '1'"
where "... and negated" "N NOT STARTING WITH '1'"
where "an expression left side" "UPPER(V) STARTING WITH 'AB'"

# --- 5. parameters -----------------------------------------------------
where "a parameter prefix" "V STARTING WITH ?" '["ab"]'
where "the bound blank is not trimmed" "V STARTING WITH ?" '["ab "]'
where "NOT with a parameter" "V NOT STARTING WITH ?" '["ab"]'
where "a bound NULL is UNKNOWN" "V STARTING WITH ?" '[null]'

# --- 6. DML teeth ------------------------------------------------------
both "UPDATE through the predicate" "UPDATE T SET N = 99 WHERE V STARTING WITH 'ab'"
both "the table after the update" "SELECT ID, N FROM T ORDER BY ID"
both "DELETE through it (a no-op)" "DELETE FROM T WHERE C STARTING WITH 'zz'"
both "DELETE through it (one row)" "DELETE FROM T WHERE V STARTING WITH 'abc'"
# OCTET_LENGTH, not V itself: the engine CONVERTS a NONE column into the
# attachment charset on the way out, and that conversion drops row 5's
# trailing blank on this driver's UTF8 attachment (probed: value 'ab',
# OCTET_LENGTH 3 - and 'ab ' with OCTET_LENGTH 3 over a NONE
# attachment). fire-crab passes the stored bytes through - the roadmap's
# transliteration entry, measured here on a plain ASCII blank, so the
# check compares the server-side length the conversion cannot touch.
both "the table after the deletes" "SELECT ID, OCTET_LENGTH(V) L FROM T ORDER BY ID"

# --- 7. refusals kept, engine answers recorded -------------------------
# each of these the ENGINE answers; fire-crab refuses rather than risk a
# wrong row set. The engine's answers are in the spec table for the
# slice that converts them: column prefix -> none for V/C ('ab' vs the
# padded 'ab   '), literal-vs-column, expression prefix.
for bad in "V STARTING WITH C" "V STARTING WITH 'a' || 'b'" "V STARTING WITH 1"; do
    a=$(query "SELECT ID FROM T WHERE $bad ORDER BY ID" "[]" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $bad ORDER BY ID" "[]" "$REAL" "$B")
    case "$a" in
        ERR*) echo "OK   refusal kept (engine answers $b): $bad" ;;
        *) if [ "$a" = "$b" ]; then
               echo "OK   $bad now agrees: $a (update the refusal list)"
           else
               echo "DIFF $bad: fcwire [$a] engine [$b]"; fail=1
           fi ;;
    esac
done

# --- 8. a column NAMED starting ----------------------------------------
# STARTING is not reserved (probed: CREATE TABLE T2 (STARTING INT)
# succeeds on the engine). The fixture has no T2, so the check here is
# that the SPELLING still parses as a column reference on both sides -
# the same refusal, not a parse error on ours alone.
a=$(query "SELECT ID FROM T2 WHERE STARTING = 7" "[]" "$PORT" "$A")
b=$(query "SELECT ID FROM T2 WHERE STARTING = 7" "[]" "$REAL" "$B")
case "$a:$b" in
    ERR*:ERR*) echo "OK   a missing table refuses on both (column named STARTING parses)" ;;
    *) echo "DIFF T2 probe: fcwire [$a] engine [$b]"; fail=1 ;;
esac

rm -f "$A" "$B"
exit $fail
