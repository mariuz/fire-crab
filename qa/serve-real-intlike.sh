#!/bin/bash
# LIKE and STARTING with a NUMERIC left side, literal patterns, against
# the REAL engine as a twin: the same driver, the same statement, two
# servers, two identical databases.
#
# The semantics under test, each probed against the engine first:
#
#   1. An INTEGER column under LIKE coerces to its decimal text per
#      row, exactly as it does under STARTING: `N LIKE '1%'` takes
#      1, 10 and 100; '-%' takes -5; '_' the single digits; '' and
#      NULL take nothing.
#   2. A SCALED column renders its zero-padded fixed-point text -
#      NUMERIC(9,2) 1.5 is '1.50', 1234.56 is '1234.56' - so
#      `STARTING WITH '1.5'` and `'1.50'` both take the 1.5 row and
#      `'1.500'` takes none; NUMERIC(38,2) (INT128 storage) renders
#      the same shapes.
#   3. HAVING funnels through the same typed_term the WHERE uses, so
#      an integer group key coerces under LIKE too.
#   4. An invalid ESCAPE raises 22025 at first real evaluation - but a
#      FALSE invariant written after it in the conjunction kills the
#      group BEFORE the scan, so `... AND 1=0` answers no rows on both
#      sides where the bare predicate raises on both.
#
#   qa/serve-real-intlike.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4575}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-intlike-crab.fdb"
B="$D/fc-intlike-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# the probe fixture: negative, multi-digit and NULL integers; scaled
# values whose renders carry a padding zero (0.50), a sign (-1.50) and
# more digits than the scale (1234.56); NUMERIC(38,2) beside
# NUMERIC(9,2) so the INT128 storage is under the same tests
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, N INTEGER, N92 NUMERIC(9,2), N382 NUMERIC(38,2));
COMMIT;
INSERT INTO T VALUES (1, 1,    0,       0);
INSERT INTO T VALUES (2, 2,    0.5,     0.5);
INSERT INTO T VALUES (3, 3,    -1.5,    -1.5);
INSERT INTO T VALUES (4, 10,   10,      10);
INSERT INTO T VALUES (5, NULL, NULL,    NULL);
INSERT INTO T VALUES (6, 100,  1234.56, 1234.56);
INSERT INTO T VALUES (7, -5,   1.5,     1.5);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-intlike.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
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

# --- 1. LIKE renders the INTEGER column ---------------------------------
where "int LIKE a prefix pattern" "N LIKE '1%'"
where "NOT LIKE is the complement over non-NULL" "N NOT LIKE '1%'"
where "a suffix pattern" "N LIKE '%0'"
where "one _ is one digit" "N LIKE '_'"
where "the sign is part of the text" "N LIKE '-%'"
where "no int text contains a literal %" "N LIKE '1!%' ESCAPE '!'"
where "LIKE NULL is UNKNOWN" "N LIKE NULL"
where "the empty pattern takes nothing" "N LIKE ''"

# --- 2. the scaled render under STARTING --------------------------------
where "N92 STARTING '1' (10, 1234.56, 1.5)" "N92 STARTING WITH '1'"
where "N92 STARTING '1.' is only 1.5x" "N92 STARTING WITH '1.'"
where "N92 STARTING '0.' takes the pad zero" "N92 STARTING WITH '0.'"
where "N92 STARTING '-' takes the negative" "N92 STARTING WITH '-'"
where "N92 STARTING '10.' (the padded 10.00)" "N92 STARTING WITH '10.'"
where "N92 STARTING '1.5'" "N92 STARTING WITH '1.5'"
where "N92 STARTING '1.50' - same row" "N92 STARTING WITH '1.50'"
where "N92 STARTING '1.500' - past the scale" "N92 STARTING WITH '1.500'"
where "the empty prefix takes non-NULL rows" "N92 STARTING WITH ''"
where "NOT over the scaled render" "N92 NOT STARTING WITH '1'"

# --- 3. the scaled render under LIKE ------------------------------------
where "N92 LIKE '%.5%' (.56 matches too)" "N92 LIKE '%.5%'"
where "N92 LIKE '1%'" "N92 LIKE '1%'"
where "N92 LIKE '1.50' - the exact render" "N92 LIKE '1.50'"
where "N92 LIKE '1.5' misses (render is 1.50)" "N92 LIKE '1.5'"
where "NOT LIKE over the scaled render" "N92 NOT LIKE '1%'"

# --- 4. NUMERIC(38,2): INT128 storage, same text ------------------------
where "N382 STARTING WITH '12'" "N382 STARTING WITH '12'"
where "N382 LIKE '%.5%'" "N382 LIKE '%.5%'"

# --- 5. HAVING coerces an integer group key under LIKE ------------------
both "HAVING ID LIKE" "SELECT ID, COUNT(*) C FROM T GROUP BY ID HAVING ID LIKE '1%'"

# --- 6. invalid ESCAPE: raise vs the dead group -------------------------
# probed: the bare predicate raises 22025 at the first non-NULL row on
# both sides; the same predicate with `AND 1=0` is killed by the FALSE
# invariant BEFORE the scan and answers no rows on both
a=$(query "SELECT ID FROM T WHERE N LIKE '1!2' ESCAPE '!' ORDER BY ID" "[]" "$PORT" "$A")
b=$(query "SELECT ID FROM T WHERE N LIKE '1!2' ESCAPE '!' ORDER BY ID" "[]" "$REAL" "$B")
case "$a:$b" in
    ERR*:ERR*) echo "OK   the bad escape raises on BOTH" ;;
    *) echo "DIFF bad escape: fcwire [$a] engine [$b]"; fail=1 ;;
esac
where "... and the FALSE invariant kills it" "N LIKE '1!2' ESCAPE '!' AND 1 = 0"

rm -f "$A" "$B"
exit $fail
