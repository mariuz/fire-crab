#!/bin/bash
# A JOIN whose WHERE names a column that is not an INTEGER or a TEXT -
# a scaled NUMERIC, a DATE, a DOUBLE, a BOOLEAN - against the REAL engine
# as a twin: the same driver, the same statement, two servers, two
# identical databases.
#
# The single-table predicate resolver learned each of those families over
# several increments. The JOIN resolver did not: it classified its
# columns through `col_kind`, which answers Int or Text and nothing else,
# and refused the whole query for anything else. So a join was not
# "broken for NUMERIC columns" - it was broken for any QUERY whose WHERE
# mentioned one, which is a much easier thing to miss, and it is how a
# NUMERIC salary in a scratch fixture hid a perfectly working join for a
# whole afternoon.
#
# The checks are deliberately dull. Each is a join that works, with a
# WHERE naming one column of one family, bare and qualified, so what is
# being measured is the ROUTING and not the comparison rules - those have
# their own gates.
#
#   qa/serve-real-jointypes.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666
# so the server's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4505}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-jt-crab.fdb"
B="$D/fc-jt-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER, K INTEGER, AMT NUMERIC(9,2), D DATE,
                DP DOUBLE PRECISION, B BOOLEAN);
CREATE TABLE C (ID INTEGER, K INTEGER, NAME VARCHAR(10), AMT2 NUMERIC(9,2));
COMMIT;
INSERT INTO A VALUES (1, 1, 10.50, '2020-01-01',  1.5, TRUE);
INSERT INTO A VALUES (2, 1, 20.25, '2021-06-15',  2.5, FALSE);
INSERT INTO A VALUES (3, 2, 5.00,  '2019-03-03', -0.5, NULL);
INSERT INTO A VALUES (4, 3, NULL,  NULL,          NULL, TRUE);
INSERT INTO C VALUES (10, 1, 'one', 10.50);
INSERT INTO C VALUES (20, 2, 'two', 99.00);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-jointypes.log 2>&1 &
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
    both "$1" "SELECT A.ID FROM A JOIN C ON A.K = C.K WHERE $2 ORDER BY A.ID"
}

# --- the control: the two families the join resolver already knew ------
where "an INTEGER column" "A.ID > 1"
where "a TEXT column" "NAME = 'one'"

# --- a scaled NUMERIC --------------------------------------------------
where "a NUMERIC column, bare" "AMT > 10"
where "a NUMERIC column, qualified" "A.AMT > 10"
where "against a decimal literal" "AMT > 10.40"
where "IS NULL over one" "AMT IS NULL"
where "BETWEEN over one" "AMT BETWEEN 10 AND 21"

# --- a temporal --------------------------------------------------------
where "a DATE column against a literal" "D > DATE'2020-01-01'"
where "a DATE column, qualified" "A.D >= DATE'2020-01-01'"
where "IS NULL over a DATE" "D IS NULL"

# --- an approximate ----------------------------------------------------
where "a DOUBLE column" "DP > 1.5"
where "a DOUBLE against an integer literal" "DP > 1"

# --- a boolean ---------------------------------------------------------
where "a bare BOOLEAN column" "B"
where "IS TRUE over one" "B IS TRUE"
where "IS NOT TRUE keeps its NULL row" "B IS NOT TRUE"

# --- combinations, and the other side ----------------------------------
where "two families in one predicate" "AMT > 10 AND D > DATE'2019-01-01'"
where "a NUMERIC on the RIGHT-hand table" "AMT2 > 50"
# (projecting a TEXT column of the joined table is not compared here:
# this driver mis-decodes the ENGINE's own answer for that shape -
# `string right truncation, expected length 7, actual 10` for a
# VARCHAR(10) - so the twin has no oracle. qa/serve-real-join.sh covers
# projections against isql's text instead, which is why that gate exists
# in the shape it does.)
both "the row COUNT of the same join" \
     "SELECT COUNT(*) FROM A JOIN C ON A.K = C.K"
both "a LEFT join with a typed WHERE" \
     "SELECT A.ID FROM A LEFT JOIN C ON A.K = C.K WHERE AMT > 10 ORDER BY A.ID"
both "COUNT(*) over a join with a typed WHERE" \
     "SELECT COUNT(*) FROM A JOIN C ON A.K = C.K WHERE AMT > 10"

rm -f "$A" "$B"
exit $fail
