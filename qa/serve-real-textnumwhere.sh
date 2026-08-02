#!/bin/bash
# Text LITERALS against exact-numeric columns in WHERE/HAVING/JOIN,
# against the REAL engine as a twin: the same driver, the same
# statement, two servers, two identical databases.
#
# The semantics under test, each probed against the engine first:
#
#   1. A convertible text literal compares EXACTLY, not through a
#      double: `N = '2'` is `N = 2`, `N > '1.5'` keeps the fraction,
#      `NSM = '99999'` answers [] with no range error, and the two
#      BIGINTs 9223372036854775806 and ...807 - one single f64 - pick
#      DIFFERENT rows for their two strings.
#   2. E-notation converts (the engine routes it through DOUBLE, exact
#      inside the 2^53 window): `N >= '2e0'`, `N92 = '5e-1'`.
#   3. An UNCONVERTIBLE literal raises 22018 PER ROW, VALUE-GATED: an
#      empty table, a row whose column is NULL, and a dead `AND 1=0`
#      group all answer with no raise; `OR ID=1` beside it and NOT
#      around it still raise; an UPDATE that raises leaves NO durable
#      change.
#   4. HAVING, JOIN ON/WHERE and expression sides (`N + 0 > '9'`)
#      convert the same way - the last one a fixed wrong-answer bug
#      (the pair used to fall to a rendered-text compare: "10" < "9").
#   5. Over an INDEXED column (table TI) convertible spellings answer
#      the same rows as the scan - the engine keys `N = '2'`.
#
# EXCLUDED, deliberately (fc refuses or raises where the engine's
# answer is not one thing):
#   - interior-space spellings (`'1 0'`): the UNINDEXED engine skips
#     the spaces and answers rows, the INDEXED engine raises 22018 -
#     fc raises everywhere (one strict grammar).
#   - hex (`'0XA'`, `'0x10'`): the engine's answer is op-, arity- and
#     index-dependent (a NaN-that-sorts-high unindexed, a raise
#     indexed, a store-grammar 10 in a multi-IN) - fc refuses the
#     statement.
#   - e-notation whose FOLDED value (mantissa x 10^exp) is past 2^53
#     (`'9223372036854775806e0'`, `'9007199254740991e3'`): the engine
#     double-rounds to a wrong-row answer - the second spelling matches
#     BOTH TB rows through the collapse - fc refuses.
#   - mantissas past i64 / scales past i8: fc refuses.
#   - an INDEXED EMPTY table with a bad literal: the engine raises at
#     open, fc answers [] (priced residual; EMPTY_T here is unindexed).
#
#   qa/serve-real-textnumwhere.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4577}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-textnumwhere-crab.fdb"
B="$D/fc-textnumwhere-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0

# the probe fixture: T spans every exact width (SMALLINT to
# NUMERIC(38,2)) with a NULL row and the two i64-rim BIGINTs; EMPTY_T
# is the value gate's zero-row case (UNINDEXED - the indexed-empty
# shape is the priced residual above); TI carries INDEXES on N and N92
# because index presence is load-bearing on the engine
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, N INTEGER, NSM SMALLINT, NBIG BIGINT,
                N92 NUMERIC(9,2), N382 NUMERIC(38,2), NAME VARCHAR(10));
CREATE TABLE EMPTY_T (ID INTEGER, N INTEGER);
CREATE TABLE TB (ID INTEGER, NB BIGINT);
CREATE TABLE TI (ID INTEGER, N INTEGER, N92 NUMERIC(9,2));
CREATE INDEX IDX_TI_N ON TI(N);
CREATE INDEX IDX_TI_N92 ON TI(N92);
COMMIT;
INSERT INTO T VALUES (1, 1,    1,    1,                   0,       0,       'alpha');
INSERT INTO T VALUES (2, 2,    2,    2,                   0.5,     0.5,     'beta');
INSERT INTO T VALUES (3, 3,    3,    3,                   -1.5,    -1.5,    'gamma');
INSERT INTO T VALUES (4, 10,   10,   9223372036854775806, 10,      10,      'delta');
INSERT INTO T VALUES (5, NULL, NULL, NULL,                NULL,    NULL,    NULL);
INSERT INTO T VALUES (6, 100,  100,  9223372036854775807, 1234.56, 1234.56, 'zeta');
INSERT INTO T VALUES (7, -5,   -5,   -5,                  1.5,     1.5,     'eta');
INSERT INTO TI SELECT ID, N, N92 FROM T;
INSERT INTO TB VALUES (1, 9007199254740991000);
INSERT INTO TB VALUES (2, 9007199254740990976);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-textnumwhere.log 2>&1 &
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
where() { # <label> <predicate over T>
    both "$1" "SELECT ID FROM T WHERE $2 ORDER BY ID"
}
raises() { # <label> <full sql> - both sides must error
    a=$(query "$2" "[]" "$PORT" "$A")
    b=$(query "$2" "[]" "$REAL" "$B")
    case "$a:$b" in
        ERR*:ERR*) echo "OK   $1 raises on BOTH" ;;
        *) echo "DIFF $1: fcwire [$a] engine [$b]"; fail=1 ;;
    esac
}
fcrefuses() { # <label> <full sql> - a PRICED refusal: fc must refuse a
    # spelling whose engine answer fc will not reproduce (the engine's
    # side is deliberately NOT compared - it answers double-collapsed
    # rows an exact compare never would)
    a=$(query "$2" "[]" "$PORT" "$A")
    case "$a" in
        ERR*) echo "OK   $1 refuses (priced)" ;;
        *) echo "DIFF $1: fcwire answered [$a]"; fail=1 ;;
    esac
}

# --- 1. exact conversion, INTEGER column --------------------------------
where "N = '2'" "N = '2'"
where "BETWEEN '1' AND '3'" "N BETWEEN '1' AND '3'"
where "IN ('1','2')" "N IN ('1','2')"
where "N > '1.5' keeps the fraction" "N > '1.5'"
where "BETWEEN '0.5' AND '2.5'" "N BETWEEN '0.5' AND '2.5'"
where "N = '2.5' never matches" "N = '2.5'"
where "an explicit +" "N = '+2'"
where "a negative" "N = '-5'"
where "surrounding blanks" "N = ' 2 '"
where "a trailing point" "N = '2.'"
where "a fraction of zeros" "N = '2.0'"
where "leading zeros" "N = '00002'"
where "mixed BETWEEN '1' AND 3" "N BETWEEN '1' AND 3"
where "mixed BETWEEN 1 AND '3'" "N BETWEEN 1 AND '3'"
where "mixed IN ('1', 2)" "N IN ('1', 2)"
where "NOT (N = '2')" "NOT (N = '2')"
where "NOT BETWEEN complements over non-NULL" "N NOT BETWEEN '1' AND '3'"
where "NOT IN complements over non-NULL" "N NOT IN ('1','2')"

# --- 2. e-notation ------------------------------------------------------
where "N >= '2e0'" "N >= '2e0'"
where "N = '2.5e0' never matches" "N = '2.5e0'"
where "IN ('1','0.5e1','3')" "N IN ('1','0.5e1','3')"
where "BETWEEN '2.5e0' AND '3.5e0'" "N BETWEEN '2.5e0' AND '3.5e0'"
where "N92 = '5e-1'" "N92 = '5e-1'"

# --- 3. scaled and wide columns -----------------------------------------
where "N92 = '0.5'" "N92 = '0.5'"
where "N92 = '0.50' - same value" "N92 = '0.50'"
where "N92 = '.5' - same value" "N92 = '.5'"
where "N92 = '0.505' past the scale" "N92 = '0.505'"
where "N92 IN ('0.5','10')" "N92 IN ('0.5','10')"
where "N92 > '0.499'" "N92 > '0.499'"
where "N382 = '0.5' (INT128 storage)" "N382 = '0.5'"
where "NSM = '2'" "NSM = '2'"
where "NSM > '1.999999' - no range check" "NSM > '1.999999'"
where "NSM = '99999' - [] not an error" "NSM = '99999'"
where "NBIG = '...806' is ITS row" "NBIG = '9223372036854775806'"
where "NBIG = '...807' is the OTHER row" "NBIG = '9223372036854775807'"
# a ZERO column value across a scale gap past 38: 0 x 10^k is 0, and the
# alignment must not saturate it to i128::MAX (probed rows; the zero
# N92/N382 row is ID 1, the negative one ID 3)
where "N92 > '1e-50' keeps the zero row OUT" "N92 > '1e-50'"
where "N92 >= '1e-50' likewise" "N92 >= '1e-50'"
where "N92 < '1e-50' keeps the zero row IN" "N92 < '1e-50'"
where "'1e-50' < N92 - the reversed side" "'1e-50' < N92"
where "N92 = '1e-50' matches nothing" "N92 = '1e-50'"
where "N382 > '1e-60' (INT128 storage)" "N382 > '1e-60'"
# the 2^53 double window tests the FOLDED value: TB's two BIGINTs
# 9007199254740991000 and ...990976 are ONE double, and the engine's
# e-notation collapse matches BOTH where the exact spelling matches one
both "plain '...991000' is ITS row only" \
     "SELECT ID FROM TB WHERE NB = '9007199254740991000' ORDER BY ID"
both "e-notation folding INSIDE the window converts" \
     "SELECT ID FROM TB WHERE NB = '900719925474099e1' ORDER BY ID"
fcrefuses "a mantissa inside 2^53 whose FOLDED value is not" \
     "SELECT ID FROM TB WHERE NB = '9007199254740991e3' ORDER BY ID"

# --- 4. unconvertible literals raise on BOTH ----------------------------
for bad in "x" "" " " "." "--2" "2," "2.5.5" "2e" "e2"; do
    raises "N = '$bad'" "SELECT ID FROM T WHERE N = '$bad' ORDER BY ID"
done
raises "NOT gives no shelter" "SELECT ID FROM T WHERE NOT (N = 'x') ORDER BY ID"
raises "an OR arm beside it still raises" "SELECT ID FROM T WHERE N = 'x' OR ID = 1 ORDER BY ID"
raises "a scaled column raises the same" "SELECT ID FROM T WHERE N92 = 'x' AND ID = 1 ORDER BY ID"
raises "HAVING raises with groups" "SELECT N FROM T GROUP BY N HAVING N = 'x'"
raises "JOIN ON raises" "SELECT A.ID FROM T A JOIN T B ON A.ID = B.ID AND A.N = 'x' ORDER BY A.ID"
raises "UPDATE raises" "UPDATE T SET NAME = 'CHANGED' WHERE ID = 1 OR N = 'x'"
both   "... and left NO durable change" "SELECT ID, NAME FROM T ORDER BY ID"

# --- 5. the value gate suppresses the raise -----------------------------
where "a dead group: N='x' AND 1=0" "N = 'x' AND 1 = 0"
where "written the other way round" "1 = 0 AND N = 'x'"
both  "an empty table answers []" "SELECT ID FROM EMPTY_T WHERE N = 'x'"
where "the NULL row answers, no raise" "ID = 5 AND N = 'x'"
where "no surviving row, no raise" "ID = 99 AND N = 'x'"
both  "a 0-row DELETE succeeds" "DELETE FROM EMPTY_T WHERE N = 'x'"
both  "LEFT JOIN an empty side: all outer rows" \
      "SELECT A.ID FROM T A LEFT JOIN EMPTY_T B ON B.N = 'x' AND A.ID = B.ID ORDER BY A.ID"
# ... but an EMPTY inner stream does not silence a raiser gated on the
# PRESERVED side: the engine walks its outer stream and evaluates the
# ON per outer row (probed: LEFT, INNER and FULL raise; a RIGHT join
# walks the RIGHT stream, so ITS empty side answers []; zero outer
# rows answer []; a FALSE conjunct beside the raiser short-circuits)
raises "LEFT JOIN empty inner, preserved-side raiser" \
       "SELECT A.ID FROM T A LEFT JOIN EMPTY_T B ON A.ID = B.ID AND A.N = 'x' ORDER BY A.ID"
raises "INNER JOIN empty inner, left-side raiser" \
       "SELECT A.ID FROM T A JOIN EMPTY_T B ON A.ID = B.ID AND A.N = 'x' ORDER BY A.ID"
raises "FULL JOIN empty inner, left-side raiser" \
       "SELECT A.ID FROM T A FULL JOIN EMPTY_T B ON A.ID = B.ID AND A.N = 'x' ORDER BY A.ID"
both   "zero preserved rows answer [] with no raise" \
       "SELECT A.ID FROM EMPTY_T A LEFT JOIN EMPTY_T B ON A.ID = B.ID AND A.N = 'x'"
both   "RIGHT JOIN's empty preserved side answers []" \
       "SELECT A.ID FROM T A RIGHT JOIN EMPTY_T B ON A.ID = B.ID AND A.N = 'x'"
raises "RIGHT JOIN walks its right stream: empty LEFT still raises" \
       "SELECT B.ID FROM EMPTY_T A RIGHT JOIN T B ON A.ID = B.ID AND B.N = 'x' ORDER BY B.ID"
both   "a FALSE conjunct short-circuits the empty-inner raiser" \
       "SELECT A.ID FROM T A LEFT JOIN EMPTY_T B ON A.ID = B.ID AND A.ID = -1 AND A.N = 'x' ORDER BY A.ID"
both   "convertible on the preserved side: all rows padded" \
       "SELECT A.ID FROM T A LEFT JOIN EMPTY_T B ON A.ID = B.ID AND A.N = ' 2 ' ORDER BY A.ID"

# --- 6. HAVING, joins and expression sides convert ----------------------
both "HAVING N > '50'" "SELECT N FROM T GROUP BY N HAVING N > '50'"
both "HAVING SUM(N92) = '0.5'" "SELECT ID FROM T GROUP BY ID HAVING SUM(N92) = '0.5' ORDER BY ID"
both "join WHERE A.N = '2'" "SELECT A.ID FROM T A JOIN T B ON A.ID = B.ID WHERE A.N = '2' ORDER BY A.ID"
both "join WHERE A.N92 = '0.5'" "SELECT A.ID FROM T A JOIN T B ON A.ID = B.ID WHERE A.N92 = '0.5' ORDER BY A.ID"
where "N + 0 > '9' - the fixed wrong answer" "N + 0 > '9'"
where "N + 0 = ' 2 '" "N + 0 = ' 2 '"

# --- 7. the INDEXED twin answers the same rows --------------------------
ti() { # <label> <predicate over TI>
    both "$1" "SELECT ID FROM TI WHERE $2 ORDER BY ID"
}
ti "indexed N = '2'" "N = '2'"
ti "indexed BETWEEN '1' AND '3'" "N BETWEEN '1' AND '3'"
ti "indexed N > '1.5'" "N > '1.5'"
ti "indexed N92 = '0.5'" "N92 = '0.5'"
ti "indexed IN ('1','2')" "N IN ('1','2')"
ti "indexed N = ' 2 '" "N = ' 2 '"

rm -f "$A" "$B"
exit $fail
