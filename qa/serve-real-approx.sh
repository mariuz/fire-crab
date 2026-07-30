#!/bin/bash
# FLOAT and DOUBLE PRECISION as OPERANDS - in a WHERE, in an aggregate, in
# a HAVING, in a subquery - against the REAL engine as a twin: the same
# driver, the same statement, two servers, two identical databases.
#
# The approximate numerics were readable and sortable before this and
# nothing else: a FLOAT or DOUBLE column in any predicate refused the
# statement, and `SUM(DP)` refused too. That is the same shape of gap the
# temporal columns had - the resolver classified columns through a
# function that answers Int or Text - with one extra trap on top.
#
# THE TRAP: `value_cmp`'s last resort compares two values by their
# RENDERED TEXT. Approximate values have no exact (raw, scale)
# decomposition, so every mixed comparison fell to it, and text ordering
# is not numeric ordering: "1.5" sorts after "10". The fold had the same
# hole one layer up - it asked for an exact decomposition and SKIPPED
# whatever declined, so `AVG(DP)` folded nothing and answered NULL over a
# column full of numbers.
#
# So the checks are built to separate a real f64 comparison from a text
# one, and an f64 fold from an exact one:
#
#   1. `DP > 1` must take the 1.5 row. Rendered, "1.5" > "1" agrees by
#      luck; `DP < 10` is where text ordering breaks, and it is here.
#   2. An approximate column against a NUMERIC and against an INTEGER
#      column - the exact side converts, not the other way, so the
#      fractional part must survive.
#   3. SUM/AVG/MIN/MAX over DOUBLE and over FLOAT, global and grouped.
#      AVG(DP) is 1.875 - a truncating exact fold would answer 1, and one
#      that skipped the values would answer NULL.
#   4. HAVING over an approximate aggregate, where the comparison happens
#      against the FOLDED value rather than a stored one.
#   5. An approximate answer from a lifted SUBQUERY.
#   6. A string literal converts (`DP > '1.25'`); one that does not parse
#      is an error on both sides, never a row set.
#   7. A CAST to and from an approximate type - including the TEXT one,
#      where the engine prints 16 significant digits for a DOUBLE and 8
#      for a FLOAT.
#
#   qa/serve-real-approx.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4435}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-approx-crab.fdb"
B="$D/fc-approx-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# The values are chosen so text ordering and numeric ordering DISAGREE
# (1.5 against 10, -0.5 against 0) and so the averages are not integers.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, DP DOUBLE PRECISION, F FLOAT, N NUMERIC(9,2),
                I INTEGER, G INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 1.5,  1.5,  10.25, 3,    1);
INSERT INTO T VALUES (2, 2.5,  2.5,  20.75, 7,    1);
INSERT INTO T VALUES (3, -0.5, -0.5, 5.00,  2,    2);
INSERT INTO T VALUES (4, NULL, NULL, NULL,  NULL, 2);
INSERT INTO T VALUES (5, 4.0,  4.0,  4.00,  4,    2);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-approx.log 2>&1 &
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

# --- 0. the values themselves still read and sort ----------------------
both "the columns as stored" "SELECT ID, DP, F FROM T ORDER BY ID"
both "ORDER BY an approximate column" "SELECT ID FROM T ORDER BY DP, ID"

# --- 1. against exact literals -----------------------------------------
where "> an integer literal (the 1.5 row is above 1)" "DP > 1"
where "< an integer literal where TEXT would disagree" "DP < 10"
where "> a decimal literal" "DP > 1.5"
where ">= a decimal literal" "DP >= 1.5"
where "= a decimal literal" "DP = 2.5"
where "a negative value against zero" "DP < 0"
where "IS NULL" "DP IS NULL"
where "IS NOT NULL" "DP IS NOT NULL"
where "BETWEEN exact bounds" "DP BETWEEN -1 AND 2.5"
where "IN a list of exact literals" "DP IN (1.5, 4)"
where "NOT IN" "DP NOT IN (1.5, 4)"
where "a FLOAT column compares the same way" "F > 1.5"

# --- 2. against other columns ------------------------------------------
where "against a NUMERIC column" "DP > N"
where "against an INTEGER column" "DP > I"
where "FLOAT against DOUBLE" "F = DP"
where "an AND of both families" "DP > 0 AND N < 21"

# --- unary and ABS keep the family -------------------------------------
where "unary minus" "-DP < 0"
where "ABS" "ABS(DP) > 1"
both "ABS in the select list" "SELECT ID, ABS(DP) FROM T ORDER BY ID"

# --- 3. the aggregates -------------------------------------------------
both "SUM over DOUBLE" "SELECT SUM(DP) FROM T"
both "AVG over DOUBLE (1.875 - not the truncated 1, not NULL)" "SELECT AVG(DP) FROM T"
both "MIN/MAX over DOUBLE" "SELECT MIN(DP), MAX(DP) FROM T"
both "COUNT over DOUBLE ignores the NULL" "SELECT COUNT(DP) FROM T"
both "SUM/AVG over FLOAT read as DOUBLE" "SELECT SUM(F), AVG(F) FROM T"
both "MIN/MAX over FLOAT" "SELECT MIN(F), MAX(F) FROM T"
both "grouped AVG" "SELECT G, AVG(DP) FROM T GROUP BY G ORDER BY G"
both "grouped SUM and COUNT" "SELECT G, SUM(DP), COUNT(DP) FROM T GROUP BY G ORDER BY G"
both "an aggregate over a filtered set" "SELECT AVG(DP) FROM T WHERE DP > 0"
both "an aggregate over NO rows is NULL" "SELECT SUM(DP), AVG(DP) FROM T WHERE 0 = 1"
both "an aggregate over the all-NULL rows" "SELECT AVG(DP) FROM T WHERE DP IS NULL"

# --- 4. HAVING over an approximate fold --------------------------------
both "HAVING an approximate AVG" \
     "SELECT G, AVG(DP) FROM T GROUP BY G HAVING AVG(DP) > 1.8 ORDER BY G"
both "HAVING an approximate SUM" \
     "SELECT G, SUM(DP) FROM T GROUP BY G HAVING SUM(DP) < 4 ORDER BY G"
both "HAVING an approximate MAX over FLOAT" \
     "SELECT G, MAX(F) FROM T GROUP BY G HAVING MAX(F) >= 4 ORDER BY G"

# --- 5. an approximate answer from a SUBQUERY --------------------------
where "> (SELECT AVG(<double>))" "DP > (SELECT AVG(DP) FROM T)"
where "= (SELECT MAX(<double>))" "DP = (SELECT MAX(DP) FROM T)"
where "an INTEGER column against an approximate subquery" "I > (SELECT AVG(DP) FROM T)"
where "IN (SELECT <double>)" "DP IN (SELECT DP FROM T WHERE ID < 3)"

# --- DML, checked on the table -----------------------------------------
both "UPDATE ... WHERE <approximate>" "UPDATE T SET G = 9 WHERE DP > 2"
both "the table after the update" "SELECT ID, G FROM T ORDER BY ID"
both "DELETE ... WHERE <approximate>" "DELETE FROM T WHERE DP < 0"
both "the table after the delete" "SELECT ID FROM T ORDER BY ID"

# --- 6. strings: converted, or an error on both ------------------------
where "a string literal that IS a number" "DP > '1.25'"
a=$(query "SELECT ID FROM T WHERE DP > 'x'" "$PORT" "$A")
b=$(query "SELECT ID FROM T WHERE DP > 'x'" "$REAL" "$B")
case "$a:$b" in
    ERR*:ERR*) echo "OK   a non-numeric string is an error on BOTH, not a row set" ;;
    *) echo "DIFF DP > 'x': fcwire [$a] engine [$b]"; fail=1 ;;
esac

# --- CAST to an approximate type ---------------------------------------
# A REFUSAL check when this gate was written - CAST's target list held
# integer and text types only - and a comparison since the CAST-target
# slice. The expression is the same; only the verdict moved.
where "against a CAST to DOUBLE PRECISION" "DP > CAST('1.5' AS DOUBLE PRECISION)"
both "the CAST itself" "SELECT CAST(DP AS VARCHAR(30)) FROM T ORDER BY ID"

rm -f "$A" "$B"
exit $fail
