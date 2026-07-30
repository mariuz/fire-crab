#!/bin/bash
# A DATE/TIME/TIMESTAMP column in a WHERE, against the REAL engine as a
# twin: the same driver, the same statement, two servers, two identical
# databases.
#
# Before this, a temporal column in a predicate refused the whole
# statement - `WHERE D IS NULL` included, because the predicate resolver
# classified columns through `col_kind`, which answers Int or Text and
# nothing else. The comparison RULES already existed one layer down (the
# expression path compares Values, and `value_cmp` reads a DATE as
# MIDNIGHT against a TIMESTAMP); what was missing was the route to them
# and the lexer's temporal literal.
#
# The checks:
#
#   1. Every operator against a typed literal (`DATE'2021-01-01'`), plus
#      IS [NOT] NULL, BETWEEN, IN and LIKE - the desugared shapes have to
#      come along, since they become ordinary comparisons at parse time.
#   2. DATE vs TIMESTAMP, in both directions and both as columns. The
#      DATE reads as midnight, so a row whose TIMESTAMP is 08:30 on its
#      own DATE is strictly LATER than that date - `TS > D` returns it and
#      `D = TS` does not. A converter that compared the two by rendered
#      text gets the equality wrong.
#   3. A STRING literal against a temporal column. The engine converts it,
#      and `'2021-6-15'` is the same DATE as `'2021-06-15'` while being a
#      different STRING - which is the case that separates a real
#      conversion from a text compare that happens to work because ISO
#      dates sort like dates.
#   4. Temporal ANSWERS from a subquery: `WHERE D = (SELECT MAX(D) FROM
#      T)`. The lifted subquery's value folds back into the token stream,
#      and it must fold back as a temporal LITERAL - as text it would
#      take the text path again.
#   5. The same predicates through UPDATE and DELETE, checked on the
#      TABLE.
#   6. Refusals, three of them for different reasons:
#      * `D > 'garbage'` - the engine raises a conversion error (22018);
#        this server refuses at prepare. Both are an error to the client;
#        what neither may do is return rows.
#      * `D > 20200101` - same, a number is not a date.
#      * `TM > TS` - the engine promotes a TIME to a TIMESTAMP using the
#        CURRENT DATE. This server does not do that yet, so it refuses
#        rather than compare rendered text and answer confidently.
#
#   qa/serve-real-temporalwhere.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4425}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-tw-crab.fdb"
B="$D/fc-tw-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# Row 1's TIMESTAMP is 08:30 on row 1's own DATE, so the date/timestamp
# conversion is visible; row 5's is midnight, so `D = TS` has exactly one
# answer. Row 4 is all-NULL for the three-valued checks.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, D DATE, TM TIME, TS TIMESTAMP, NAME VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, '2020-01-01', '08:30:00', '2020-01-01 08:30:00', 'aa');
INSERT INTO T VALUES (2, '2021-06-15', '12:00:00.5000', '2021-06-15 12:00:00.5000', 'bb');
INSERT INTO T VALUES (3, '2019-03-03', '23:59:59', '2019-03-03 23:59:59', 'cc');
INSERT INTO T VALUES (4, NULL, NULL, NULL, 'dd');
INSERT INTO T VALUES (5, '2022-12-31', '00:00:00', '2022-12-31 00:00:00', 'ee');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-temporalwhere.log 2>&1 &
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
where() { # <label> <predicate>
    both "$1" "SELECT ID FROM T WHERE $2 ORDER BY ID"
}

# --- 1. the operators, and the shapes that desugar into them -----------
where "= a DATE literal"  "D = DATE'2020-01-01'"
where "<> a DATE literal" "D <> DATE'2020-01-01'"
where "> a DATE literal"  "D > DATE'2021-01-01'"
where "<= a DATE literal" "D <= DATE'2020-01-01'"
where "a TIME literal"    "TM > TIME'09:00:00'"
where "a TIMESTAMP literal" "TS > TIMESTAMP'2020-06-01 00:00:00'"
where "IS NULL on a temporal column" "D IS NULL"
where "IS NOT NULL on a temporal column" "D IS NOT NULL"
where "BETWEEN two DATE literals" \
      "D BETWEEN DATE'2020-01-01' AND DATE'2022-01-01'"
where "NOT BETWEEN" "D NOT BETWEEN DATE'2020-01-01' AND DATE'2022-01-01'"
where "IN a list of DATE literals" "D IN (DATE'2020-01-01', DATE'2022-12-31')"
where "NOT IN a list of DATE literals" "D NOT IN (DATE'2020-01-01', DATE'2022-12-31')"
where "LIKE against the rendered date" "D LIKE '2020%'"
where "AND of two temporal terms" \
      "D > DATE'2019-06-01' AND TM < TIME'13:00:00'"
where "OR, with a NULL row in play" \
      "D = DATE'2020-01-01' OR D IS NULL"
where "NOT of a temporal comparison (UNKNOWN still drops the NULL row)" \
      "NOT (D = DATE'2020-01-01')"

# --- 2. DATE against TIMESTAMP: the DATE reads as MIDNIGHT -------------
where "a TIMESTAMP column against a DATE literal" "TS > DATE'2021-06-15'"
where "a DATE column against a TIMESTAMP literal" "D > TIMESTAMP'2020-01-01 12:00:00'"
where "equality across the two (only the midnight row)" "D = TS"
where "a timestamp is LATER than its own date" "TS > D"
where "and the date is not later than its timestamp" "D > TS"

# --- 3. a STRING literal is CONVERTED, not compared as text -----------
where "a string literal date" "D > '2021-01-01'"
where "the SAME date written differently" "D = '2021-6-15'"
where "a string literal time" "TM > '09:00'"
where "a string literal timestamp" "TS > '2021-06-15 11:00'"
where "a string literal in BETWEEN" "D BETWEEN '2020-01-01' AND '2022-01-01'"
where "a string and a typed literal in one IN list" \
      "D IN ('2020-01-01', DATE'2022-12-31')"

# --- 4. a temporal answer from a SUBQUERY ------------------------------
where "= (SELECT MAX(<date>))" "D = (SELECT MAX(D) FROM T)"
where "> (SELECT MIN(<date>))" "D > (SELECT MIN(D) FROM T)"
where ">= (SELECT MAX(<timestamp>))" "TS >= (SELECT MAX(TS) FROM T)"
where "= (SELECT MIN(<time>))" "TM = (SELECT MIN(TM) FROM T)"
where "IN (SELECT <date>)" "D IN (SELECT D FROM T WHERE ID < 3)"
where "NOT IN (SELECT <date>) - the NULL poisons it" \
      "D NOT IN (SELECT D FROM T WHERE ID < 5)"
where "a DATE column against a TIMESTAMP subquery" "D = (SELECT MAX(TS) FROM T)"

# --- expression sides still work over temporal columns -----------------
where "arithmetic on a DATE column" "D + 1 > DATE'2021-01-01'"
where "EXTRACT in the predicate" "EXTRACT(YEAR FROM D) = 2021"
where "against the clock keyword" "D < CURRENT_DATE"

# --- 5. the same predicates through DML, checked on the TABLE ----------
both "UPDATE ... WHERE <temporal>" \
     "UPDATE T SET NAME = 'up' WHERE D > DATE'2022-01-01'"
both "the table after the temporal update" "SELECT ID, NAME FROM T ORDER BY ID"
both "DELETE ... WHERE <temporal>" "DELETE FROM T WHERE D < DATE'2020-01-01'"
both "the table after the temporal delete" "SELECT ID, NAME FROM T ORDER BY ID"

# --- 6. refusals -------------------------------------------------------
# the engine raises a conversion error where this server refuses at
# prepare - both are an error to the client, and neither returns rows.
# Returning rows is the failure that matters: before the conversion was
# real, `D > 'garbage'` compared RENDERED TEXT and answered a row set.
for bad in "D > 'garbage'" "D > 20200101" "D = 'not-a-date'"; do
    a=$(query "SELECT ID FROM T WHERE $bad" "$PORT" "$A")
    b=$(query "SELECT ID FROM T WHERE $bad" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $bad is an error on BOTH, not a row set" ;;
        *) echo "DIFF $bad: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
done
# TIME against DATE/TIMESTAMP: the engine promotes the TIME with the
# CURRENT DATE, which this server does not implement - so it refuses.
# A documented refusal, not a wrong answer: comparing the two by rendered
# text would have answered every row confidently.
for mix in "TM > TS" "D > TIME'09:00:00'" "TM < D"; do
    a=$(query "SELECT ID FROM T WHERE $mix" "$PORT" "$A")
    case "$a" in
        ERR*) echo "OK   $mix is refused (engine promotes with the current date; we do not)" ;;
        *) echo "DIFF $mix answered: [$a]"; fail=1 ;;
    esac
done

rm -f "$A" "$B"
exit $fail
