#!/bin/bash
# An AGGREGATE inside a scalar subquery - `WHERE AMT > (SELECT AVG(AMT)
# FROM T)` - checked against the REAL engine as a twin: the same driver,
# the same statement, two servers, two identical databases.
#
# The subquery's value is a single number nobody ever sees, which is what
# makes this worth a gate of its own: a wrong average is not an error, it
# is a different SET OF ROWS. Every case below is built so the value the
# engine computes and a plausible wrong one select DIFFERENT rows:
#
#   1. AVG over INTEGER TRUNCATES toward zero (probed: 32/4 = 8, and a
#      group of 10 and 11 averages 10, not 11). The fixture has a row
#      sitting between the truncated and the rounded answer.
#   2. A NULL is ignored by the DIVISOR as well as the sum. With the NULL
#      row counted the average drops from 8 to 6, and 6 selects one more
#      row than 8 does.
#   3. AVG over NUMERIC keeps the source's SCALE - 7.86, not 7 - so a
#      fold that flattened to an integer would take an extra row.
#   4. MIN/MAX over TEXT: a subquery aggregate is not restricted to the
#      integers an i64 fold can carry.
#   5. The arguments a SELECT list accepts, a subquery accepts too:
#      `COUNT(DISTINCT col)`, `AVG(<expression>)`, `SUM(A * 2)`.
#   6. The empty subquery: MIN/MAX/SUM/AVG answer NULL (so the comparison
#      is UNKNOWN and NO row is selected) while COUNT answers 0 (so
#      `> 0` selects nearly all of them). These two are the discriminator
#      between "the aggregate found nothing" and "the aggregate is zero".
#   7. The same values through DML, where the check is the TABLE.
#   8. A refusal: an aggregate over an approximate column is refused
#      rather than folded, because the top-level `SELECT AVG(D) FROM T`
#      is refused too - one expression cannot be legal in one position
#      and illegal in the other.
#
#   qa/serve-real-subqagg.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4415}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-subqagg-crab.fdb"
B="$D/fc-subqagg-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# AMT: 10, 11, 4, NULL, 7  -> sum 32 over FOUR non-null rows = 8 exactly.
#   * with the NULL row in the divisor it would be 32/5 = 6, and 7 sits
#     between the two - so `>= AVG` returns 2 rows at 8 and 3 rows at 6.
#   * within G = 1 the average of 10 and 11 is 10.5: truncated 10 selects
#     the 11 row, rounded 11 selects nothing.
# NUM: 11.25, 11.35, NULL, 1.00, 5.50 -> 29.10/4 = 7.27 (scale kept);
#   flattened to the integer 7 it would also take the 7.27-adjacent row.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NUM NUMERIC(9,2), NAME VARCHAR(10),
                D DOUBLE PRECISION, G INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10,   11.25, 'aa',  1.5,  1);
INSERT INTO T VALUES (2, 11,   11.35, 'zz',  2.5,  1);
INSERT INTO T VALUES (3, 4,    NULL,  'mm',  NULL, 2);
INSERT INTO T VALUES (4, NULL, 1.00,  NULL,  4.0,  2);
INSERT INTO T VALUES (5, 7,    5.50,  'bb',  3.0,  2);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-subqagg.log 2>&1 &
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

# --- the value itself, so a wrong row set can be told from a wrong ------
#     comparison
both "AVG over INTEGER truncates" "SELECT AVG(AMT) FROM T"
both "AVG over NUMERIC keeps the scale" "SELECT AVG(NUM) FROM T"
both "AVG of 10 and 11 is 10, not 11" "SELECT AVG(AMT) FROM T WHERE G = 1"

# --- 1+2. AVG(INTEGER) as a comparison right side -----------------------
both "WHERE AMT >= (SELECT AVG(AMT))" \
     "SELECT ID FROM T WHERE AMT >= (SELECT AVG(AMT) FROM T) ORDER BY ID"
both "WHERE AMT > (SELECT AVG(AMT))" \
     "SELECT ID FROM T WHERE AMT > (SELECT AVG(AMT) FROM T) ORDER BY ID"
both "the subquery carries its OWN filter (truncation shows here)" \
     "SELECT ID FROM T WHERE AMT > (SELECT AVG(AMT) FROM T WHERE G = 1) ORDER BY ID"
both "below the average" \
     "SELECT ID FROM T WHERE AMT < (SELECT AVG(AMT) FROM T) ORDER BY ID"

# --- 3. the scale survives ----------------------------------------------
both "WHERE NUM >= (SELECT AVG(NUM))" \
     "SELECT ID FROM T WHERE NUM >= (SELECT AVG(NUM) FROM T) ORDER BY ID"
both "a NUMERIC sum as the right side" \
     "SELECT ID FROM T WHERE NUM > (SELECT SUM(NUM) FROM T WHERE G = 2) ORDER BY ID"
both "an INTEGER column against a NUMERIC average" \
     "SELECT ID FROM T WHERE AMT > (SELECT AVG(NUM) FROM T) ORDER BY ID"

# --- 4. MIN/MAX are not restricted to integers --------------------------
both "MAX over TEXT" "SELECT ID FROM T WHERE NAME = (SELECT MAX(NAME) FROM T) ORDER BY ID"
both "MIN over TEXT, with the subquery's own filter" \
     "SELECT ID FROM T WHERE NAME < (SELECT MIN(NAME) FROM T WHERE G = 2) ORDER BY ID"
both "MIN/MAX over INTEGER still answer" \
     "SELECT ID FROM T WHERE AMT = (SELECT MAX(AMT) FROM T) ORDER BY ID"

# --- 5. the arguments a SELECT list accepts -----------------------------
both "COUNT(DISTINCT col)" \
     "SELECT ID FROM T WHERE AMT > (SELECT COUNT(DISTINCT G) FROM T) ORDER BY ID"
both "COUNT(col) counts non-NULLs" \
     "SELECT ID FROM T WHERE AMT > (SELECT COUNT(NAME) FROM T) ORDER BY ID"
both "AVG of an EXPRESSION" \
     "SELECT ID FROM T WHERE AMT > (SELECT AVG(AMT + 1) FROM T) ORDER BY ID"
both "SUM of an expression" \
     "SELECT ID FROM T WHERE AMT > (SELECT SUM(AMT * 2) FROM T WHERE G = 2) ORDER BY ID"
both "MIN of a function call over text" \
     "SELECT ID FROM T WHERE NAME > (SELECT MIN(UPPER(NAME)) FROM T) ORDER BY ID"

# --- 6. the empty subquery: NULL and 0 are different answers ------------
both "an empty AVG is NULL, so NO row compares true" \
     "SELECT ID FROM T WHERE AMT > (SELECT AVG(AMT) FROM T WHERE 0 = 1) ORDER BY ID"
both "an empty MAX is NULL too" \
     "SELECT ID FROM T WHERE AMT > (SELECT MAX(AMT) FROM T WHERE 0 = 1) ORDER BY ID"
both "an empty COUNT is 0, and 0 selects rows" \
     "SELECT ID FROM T WHERE ID > (SELECT COUNT(*) FROM T WHERE 0 = 1) ORDER BY ID"
both "a subquery over ALL-NULL values is empty as well" \
     "SELECT ID FROM T WHERE AMT > (SELECT AVG(AMT) FROM T WHERE AMT IS NULL) ORDER BY ID"

# --- COUNT(*) on a SYSTEM relation still answers ------------------------
# these have no RDB\$FORMATS entry, so their rows cannot be decoded - the
# count comes from the record headers, and routing subqueries through the
# group machinery must not lose it
both "COUNT(*) over a system relation inside a subquery" \
     "SELECT ID FROM T WHERE ID < (SELECT COUNT(*) FROM RDB\$RELATIONS) ORDER BY ID"

# --- 7. the same right sides in DML, where the TABLE is the check -------
both "UPDATE ... WHERE AMT > (SELECT AVG(AMT))" \
     "UPDATE T SET G = 8 WHERE AMT > (SELECT AVG(AMT) FROM T)"
both "the table after the average update" "SELECT ID, AMT, G FROM T ORDER BY ID"
both "DELETE ... WHERE AMT < (SELECT AVG(AMT))" \
     "DELETE FROM T WHERE AMT < (SELECT AVG(AMT) FROM T)"
both "the table after the average delete" "SELECT ID, AMT, G FROM T ORDER BY ID"

# --- 8. refusals --------------------------------------------------------
# an APPROXIMATE source: the engine answers it, this server does not - and
# what matters is that it refuses in BOTH positions. A subquery that folded
# a DOUBLE while `SELECT AVG(D) FROM T` was refused would make the same
# expression legal in one place and illegal in another; worse, the fold
# used to DROP the double values silently and answer NULL.
top=$(query "SELECT AVG(D) FROM T" "$PORT" "$A")
sub=$(query "SELECT ID FROM T WHERE AMT > (SELECT AVG(D) FROM T)" "$PORT" "$A")
case "$top:$sub" in
    ERR*:ERR*) echo "OK   an approximate source is refused in BOTH positions" ;;
    *) echo "DIFF approximate source: top [$top] subquery [$sub]"; fail=1 ;;
esac
# SUM(text) is not an aggregate the engine allows either
r=$(query "SELECT ID FROM T WHERE AMT > (SELECT SUM(NAME) FROM T)" "$PORT" "$A")
case "$r" in
    ERR*) echo "OK   SUM over a text column is refused" ;;
    *) echo "DIFF SUM(text) answered: [$r]"; fail=1 ;;
esac
# only COUNT takes DISTINCT
r=$(query "SELECT ID FROM T WHERE AMT > (SELECT AVG(DISTINCT AMT) FROM T)" "$PORT" "$A")
case "$r" in
    ERR*) echo "OK   AVG(DISTINCT ...) is refused, not silently folded" ;;
    *) echo "DIFF AVG(DISTINCT) answered: [$r]"; fail=1 ;;
esac

rm -f "$A" "$B"
exit $fail
