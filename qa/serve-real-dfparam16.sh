#!/bin/bash
# A bound TEXT or INTEGER value against a DECFLOAT(16) parameter slot is
# NARROWED to 16 significant digits before the comparison, as the engine
# does - and a bind error through a derived table, a CTE or a
# DISTINCT / FIRST / ROWS wrapper is an ERROR, never an empty result.
#
# DECFLOAT(16), measured against the live engine (node-firebird text binds,
# qa/fbint64.c for a native SQL_INT64):
#   * the value parses to decimal128 (a text rounds to 34 digits first,
#     HALF-UP) and narrows to 16 digits HALF-UP: `D16 = ?` ['12345678901234565']
#     and the int64 12345678901234565 both match 1234567890123457E+1;
#     '1.10000000000000009' matches the 1.1 cohort; the 38-digit
#     '1.00000000000000049999999999999999999' matches 1.000000000000001
#     (the 34-digit rounding makes the 5). fire-crab compared the full
#     34-digit value and answered NO ROW for all of them.
#   * the narrowed value is used only when decimal64 holds it exactly: a
#     16-digit form that overflows (9.9999999999999995E+384, 1E+385) or goes
#     subnormal (1.5E-398, 1e-400) keeps the WIDE value, which sorts between
#     its neighbours.
#   * BLANKS are trimmed (' +1.0 ' matches 1; a tab, CR/LF or NBSP is a
#     conversion error).
#   * every special - inf, Infinity, NaN, sNaN, any sign - and every
#     non-number raises *Conversion error from string* PER ROW: an empty
#     table, a NULL column and a dead `ID = 3 AND` group answer with no
#     raise. fire-crab ANSWERED 'inf' (no rows, and through OR / IN /
#     COUNT / UPDATE silently) and refused 'abc' for the whole statement.
#   * a decimal128 exponent UNDERFLOW clamps (1e-6177 compares equal to 0,
#     on DECFLOAT(34) too); an overflow (1e6145) raises - fire-crab refuses.
#
# The swallow: validate_select_bind checked only Project / Join / Group
# plans, so a bad bind under a Derived / Modified plan reached the fetch and
# shipped the end-of-cursor terminator - `SELECT ID FROM (SELECT ID, I FROM
# P) T WHERE I = ?` ['abc'] answered no rows for INTEGER, NUMERIC, DOUBLE,
# BOOLEAN and both DECFLOAT widths where the engine raises. The check now
# recurses, and a bind failure that still reaches the fetch is an error.
#
# Usage: qa/serve-real-dfparam16.sh [port]   (default 4177)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4177}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfp16-eng.fdb"; FC="$D/dfp16-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
RIG="$D/fc-fbint64-$PORT"
cc -o "$RIG" "$(dirname "$0")/fbint64.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null \
    || { echo "FAIL cannot build qa/fbint64.c"; exit 1; }
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfp16-build.log 2>&1 <<'SQL'
CREATE TABLE PB (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16));
INSERT INTO PB VALUES (1, 1.1, 1.1);
INSERT INTO PB VALUES (2, 1.10000000000000009, 1.100000000000000);
INSERT INTO PB VALUES (3, 12345678901234568, 1234567890123457E+1);
INSERT INTO PB VALUES (4, 12345678901234565, 1234567890123456E+1);
INSERT INTO PB VALUES (5, 0.1000000000000000055511151231257827, 0.1000000000000000);
INSERT INTO PB VALUES (6, 7.2576582964629335, 7.257658296462934);
INSERT INTO PB VALUES (7, 7.2576582964629334, 7.257658296462933);
INSERT INTO PB VALUES (8, 9.9999999999999995E-8, 1.000000000000000E-7);
INSERT INTO PB VALUES (9, 9.9999999999999994E-8, 9.999999999999999E-8);
INSERT INTO PB VALUES (10, 99999999999999995, 1.000000000000000E+17);
INSERT INTO PB VALUES (11, 9223372036854775807, 9223372036854776E+3);
INSERT INTO PB VALUES (12, -12345678901234565, -1234567890123457E+1);
INSERT INTO PB VALUES (13, 1E+385, NULL);
INSERT INTO PB VALUES (14, 1E-400, 0E-398);
INSERT INTO PB VALUES (15, 1.5, 1.5);
INSERT INTO PB VALUES (16, 123, 123);
INSERT INTO PB VALUES (17, 1, 1.000000000000000);
INSERT INTO PB VALUES (18, 1, 1.000000000000001);
CREATE TABLE PI (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16));
INSERT INTO PI VALUES (1, 12345678901234565, 1234567890123456E+1);
INSERT INTO PI VALUES (2, 12345678901234575, 1234567890123457E+1);
INSERT INTO PI VALUES (3, 1234567890123456500, 1234567890123456E+3);
INSERT INTO PI VALUES (4, 1234567890123457500, 1234567890123457E+3);
INSERT INTO PI VALUES (5, -12345678901234565, -1234567890123456E+1);
INSERT INTO PI VALUES (6, -12345678901234565, -1234567890123457E+1);
INSERT INTO PI VALUES (9, 9223372036854775807, 9223372036854776E+3);
CREATE TABLE EDGE (ID INTEGER, D16 DECFLOAT(16));
INSERT INTO EDGE VALUES (1, CAST('Infinity' AS DECFLOAT(16)));
INSERT INTO EDGE VALUES (2, CAST('-Infinity' AS DECFLOAT(16)));
INSERT INTO EDGE VALUES (3, 9.999999999999999E+384);
INSERT INTO EDGE VALUES (4, 0E-398);
INSERT INTO EDGE VALUES (5, 1E-398);
INSERT INTO EDGE VALUES (6, 2E-398);
INSERT INTO EDGE VALUES (7, -1E-398);
INSERT INTO EDGE VALUES (8, 1.000000000000000E-383);
INSERT INTO EDGE VALUES (9, 1);
INSERT INTO EDGE VALUES (10, 1.000000000000000);
INSERT INTO EDGE VALUES (11, 1.234567890123457E-390);
CREATE TABLE E (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16));
CREATE TABLE N (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16));
INSERT INTO N VALUES (1, NULL, NULL);
CREATE TABLE T (ID INTEGER, I INTEGER, N NUMERIC(9,2), D34 DECFLOAT(34), D16 DECFLOAT(16), DP DOUBLE PRECISION, B BOOLEAN, S VARCHAR(10));
INSERT INTO T VALUES (1, 5, 1.5, 0, 0, 1.5, TRUE, 'a');
INSERT INTO T VALUES (2, 6, 2.5, 1, 1, 2.5, FALSE, 'b');
COMMIT;
SQL
if grep -qi error /tmp/dfp16-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfp16-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfp16.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     eng: $3"; echo "     fc:  $2"; fail=1; fi
}
# one query with JSON params through node; rows joined, or ERR <first line>
node_at() { # <port> <db> <query> <json-params>
    FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR "+String(e2.message||e2).split("\n")[0].split(", ")[0].trim());db.detach();process.exit(0);}
          if(!r||!r.length){console.log("(none)");db.detach();process.exit(0);}
          console.log(r.map(x=>Object.values(x).join()).join(";"));db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() { # retry a connection hiccup
    local n=0 r
    while [ $n -lt 8 ]; do
        r=$(node_at "$1" "$2" "$3" "$4")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    echo CONN_ERR
}
both() { # <label> <sql> <json-params> - the same rows or the same error line
    check "$1 [$3]" "$(node_run "$PORT" "$FC" "$2" "$3")" "$(node_run 3050 "$ENG" "$2" "$3")"
}
raises() { # <label> <sql> <json> - the engine raises; fire-crab must raise too (vector recorded, not matched)
    local e f
    e=$(node_run 3050 "$ENG" "$2" "$3"); f=$(node_run "$PORT" "$FC" "$2" "$3")
    case "$e" in ERR*) ;; *) echo "FAIL $1 [$3] (the engine no longer raises: $e)"; fail=1; return ;; esac
    case "$f" in ERR*) echo "OK   $1 [$3] (raises)" ;; *) echo "DIFF $1 [$3] - engine raises, fc answered: $f"; fail=1 ;; esac
}
where() { both "$1" "SELECT ID FROM PB WHERE $2 ORDER BY ID" "$3"; }
irig() { # <label> <sql> <int64> [scale] - native SQL_INT64 bind
    check "$1 [int64 $3${4:+ scale $4}]" "$("$RIG" "127.0.0.1/$PORT:$FC" "$2" "$3" ${4:-})" "$("$RIG" "127.0.0.1/3050:$ENG" "$2" "$3" ${4:-})"
}

echo "-- DECFLOAT(16) slot: a TEXT bind narrows to 16 digits HALF-UP (after the 34-digit parse) --"
where "D16 = ? tie narrows up"            "D16 = ?" '["12345678901234565"]'
where "D16 = ? 17 digits"                 "D16 = ?" '["1.10000000000000009"]'
where "D16 = ? 34-digit text"             "D16 = ?" '["0.1000000000000000055511151231257827"]'
where "D16 = ? midpoint ...9335"          "D16 = ?" '["7.2576582964629335"]'
where "D16 = ? carry to 1E-7"             "D16 = ?" '["9.9999999999999995E-8"]'
where "D16 = ? double rounding (38 digits)" "D16 = ?" '["1.00000000000000049999999999999999999"]'
where "D16 = ? 40 digits"                 "D16 = ?" '["1.0000000000000004999999999999999999999"]'
where "D16 = ? tie ...0005"               "D16 = ?" '["1.0000000000000005"]'
where "D16 = ? already 16"                "D16 = ?" '["1.1000000000000000"]'
where "D16 = ? plain"                     "D16 = ?" '["1.5"]'
where "D16 < ?"                           "D16 < ?" '["12345678901234565"]'
where "D16 >= ?"                          "D16 >= ?" '["12345678901234565"]'
where "D16 <> ?"                          "D16 <> ?" '["7.2576582964629335"]'
where "D16 BETWEEN ? AND ?"               "D16 BETWEEN ? AND ?" '["1.10000000000000009","9e9"]'
where "? = D16 (param left)"              "? = D16" '["7.2576582964629335"]'
where "D16 IN (?, 1)"                     "D16 IN (?, 1)" '["1.10000000000000009"]'
where "D16 IS NOT DISTINCT FROM ?"        "D16 IS NOT DISTINCT FROM ?" '["12345678901234565"]'
both "derived table D16 = ?"  "SELECT ID FROM (SELECT ID, D16 FROM PB) Q WHERE D16 = ? ORDER BY ID" '["7.2576582964629335"]'
both "CTE D16 = ?"            "WITH C AS (SELECT ID, D16 FROM PB) SELECT ID FROM C WHERE D16 = ? ORDER BY ID" '["12345678901234565"]'
both "COUNT(*) D16 = ?"       "SELECT COUNT(*) FROM PB WHERE D16 = ?" '["1.10000000000000009"]'
echo "-- DECFLOAT(16) slot: a native INT64 bind narrows the same way (qa/fbint64.c) --"
irig "D16 = int64 tie up"       "SELECT ID FROM PI WHERE D16 = ? ORDER BY ID" 12345678901234565
irig "D16 = int64 no tie"       "SELECT ID FROM PI WHERE D16 = ? ORDER BY ID" 12345678901234575
irig "D16 = int64 19 digits"    "SELECT ID FROM PI WHERE D16 = ? ORDER BY ID" 1234567890123456500
irig "D16 = int64 negative"     "SELECT ID FROM PI WHERE D16 = ? ORDER BY ID" -12345678901234565
irig "D16 = int64 max"          "SELECT ID FROM PI WHERE D16 = ? ORDER BY ID" 9223372036854775807
irig "D16 < int64"              "SELECT ID FROM PI WHERE D16 < ? ORDER BY ID" 12345678901234565
irig "D34 = int64 exact"        "SELECT ID FROM PI WHERE D34 = ? ORDER BY ID" 12345678901234565
irig "D34 = int64 negative"     "SELECT ID FROM PI WHERE D34 = ? ORDER BY ID" -12345678901234565
irig "D16 = int64 scaled"       "SELECT ID FROM PI WHERE D16 = ? ORDER BY ID" 12345678901234565 2
echo "-- a 16-digit form that OVERFLOWS or goes SUBNORMAL keeps the wide value --"
for op in "=" ">=" "<"; do
    for v in '"1E+385"' '"9.9999999999999995E+384"' '"1.5E-398"' '"1e-400"' '"1.2345678901234565E-390"' '"1E-398"' '"9.999999999999999E+384"'; do
        both "EDGE D16 $op" "SELECT ID FROM EDGE WHERE D16 $op ? ORDER BY ID" "[$v]"
    done
done
echo "-- blanks trim; a tab / CR / NBSP does not --"
both "D16 = ' +1.0 '"   "SELECT ID FROM EDGE WHERE D16 = ? ORDER BY ID" '[" +1.0 "]'
both "D16 = '1. '"      "SELECT ID FROM EDGE WHERE D16 = ? ORDER BY ID" '["1. "]'
both "D16 = '  1.1  '"  "SELECT ID FROM PB WHERE D16 = ? ORDER BY ID" '["  1.1  "]'
both "D16 = tab 1"      "SELECT ID FROM EDGE WHERE D16 = ? ORDER BY ID" '["\t1"]'
both "D16 = 1 CR"       "SELECT ID FROM EDGE WHERE D16 = ? ORDER BY ID" '["1\r"]'
echo "-- specials and non-numbers raise *Conversion error* PER ROW (value-gated) --"
for v in '"inf"' '"Infinity"' '"-inf"' '"+Infinity"' '"NaN"' '"sNaN"' '"-NaN"' '"abc"' '""' '"1e"' '"0x10"' '"1,5"'; do
    both "PB D16 = special/garbage" "SELECT ID FROM PB WHERE D16 = ? ORDER BY ID" "[$v]"
done
both "empty table: no raise"         "SELECT ID FROM E WHERE D16 = ?" '["inf"]'
both "NULL column: no raise"         "SELECT ID FROM N WHERE D16 = ?" '["abc"]'
both "dead AND group: no raise"      "SELECT ID FROM PB WHERE ID = 99 AND D16 = ?" '["inf"]'
both "OR does not hide it"           "SELECT ID FROM PB WHERE D16 = ? OR ID = 2" '["inf"]'
both "IN list member"                "SELECT ID FROM PB WHERE D16 IN (?, ?)" '["1","inf"]'
both "BETWEEN bound"                 "SELECT ID FROM PB WHERE D16 BETWEEN ? AND ?" '["0","abc"]'
both "COUNT(*)"                      "SELECT COUNT(*) FROM PB WHERE D16 = ?" '["inf"]'
both "UPDATE .. WHERE"               "UPDATE PB SET ID = ID WHERE D16 = ?" '["inf"]'
both "DELETE .. WHERE"               "DELETE FROM PB WHERE D16 = ?" '["abc"]'
both "derived table"                 "SELECT ID FROM (SELECT ID, D16 FROM PB) Q WHERE D16 = ?" '["abc"]'
both "D34 = 'inf' is a value (no rows)" "SELECT ID FROM PB WHERE D34 = ?" '["inf"]'
both "D34 = 'NaN' traps"             "SELECT ID FROM PB WHERE D34 = ?" '["NaN"]'
echo "-- a decimal128 exponent underflow clamps to zero; an overflow raises --"
both "D16 = '1e-6177'"   "SELECT ID FROM EDGE WHERE D16 = ? ORDER BY ID" '["1e-6177"]'
both "D16 = '-1e-6177'"  "SELECT ID FROM EDGE WHERE D16 = ? ORDER BY ID" '["-1e-6177"]'
both "D16 >= '1e-6177'"  "SELECT ID FROM EDGE WHERE D16 >= ? ORDER BY ID" '["1e-6177"]'
both "D34 = '1e-6177'"   "SELECT ID FROM T WHERE D34 = ? ORDER BY ID" '["1e-6177"]'
both "D34 = '0E-6200'"   "SELECT ID FROM T WHERE D34 = ? ORDER BY ID" '["0E-6200"]'
both "D16 = '0E+500'"    "SELECT ID FROM EDGE WHERE D16 = ? ORDER BY ID" '["0E+500"]'
raises "D16 = '1e6145' overflow" "SELECT ID FROM EDGE WHERE D16 = ?" '["1e6145"]'
raises "D34 = '1e6145' overflow" "SELECT ID FROM T WHERE D34 = ?" '["1e6145"]'
echo "-- DECFLOAT(34) text binds unchanged --"
where "D34 = ? 17 digits"  "D34 = ?" '["1.10000000000000009"]'
where "D34 = ? 34 digits"  "D34 = ?" '["0.1000000000000000055511151231257827"]'
where "D34 = ? tie text"   "D34 = ?" '["12345678901234565"]'
echo "-- a bind error under a DERIVED table / CTE / DISTINCT / FIRST / ROWS raises, never an empty result --"
for col in I N D34 D16 DP B; do
    raises "derived $col"      "SELECT ID FROM (SELECT ID, $col FROM T) Q WHERE $col = ?" '["abc"]'
    raises "derived * $col"    "SELECT ID FROM (SELECT * FROM T) Q WHERE $col = ?" '["abc"]'
done
raises "CTE consumed"          "WITH C AS (SELECT ID, I FROM T) SELECT ID FROM C WHERE I = ?" '["abc"]'
raises "windowed derived"      "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) FROM (SELECT ID, I FROM T) Q WHERE I = ?" '["abc"]'
raises "DISTINCT"              "SELECT DISTINCT ID FROM T WHERE I = ?" '["abc"]'
raises "FIRST"                 "SELECT FIRST 1 ID FROM T WHERE I = ?" '["abc"]'
raises "ROWS"                  "SELECT ID FROM T WHERE I = ? ROWS 1" '["abc"]'
raises "DISTINCT over derived" "SELECT DISTINCT ID FROM (SELECT ID, I FROM T) Q WHERE I = ?" '["abc"]'
raises "UNION branch"          "SELECT ID FROM T UNION SELECT ID FROM T WHERE I = ?" '["abc"]'
raises "base table (control)"  "SELECT ID FROM T WHERE I = ?" '["abc"]'
echo "-- the same shapes with a GOOD bind answer the same rows (no over-refusal) --"
both "derived I = 6"           "SELECT ID FROM (SELECT ID, I FROM T) Q WHERE I = ?" '[6]'
both "derived N = '2.5'"       "SELECT ID FROM (SELECT ID, N FROM T) Q WHERE N = ?" '["2.5"]'
both "derived D34 = 1"         "SELECT ID FROM (SELECT ID, D34 FROM T) Q WHERE D34 = ?" '[1]'
both "derived B = true"        "SELECT ID FROM (SELECT ID, B FROM T) Q WHERE B = ?" '[true]'
both "CTE I = 5"               "WITH C AS (SELECT ID, I FROM T) SELECT ID FROM C WHERE I = ?" '[5]'
both "windowed derived I = 6"  "SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) FROM (SELECT ID, I FROM T) Q WHERE I = ?" '[6]'
both "DISTINCT I = 5"          "SELECT DISTINCT ID FROM T WHERE I = ?" '[5]'
both "FIRST 1 I > 0"           "SELECT FIRST 1 ID FROM T WHERE I > ? ORDER BY ID" '[0]'
both "ROWS 1"                  "SELECT ID FROM T WHERE I > ? ORDER BY ID ROWS 1" '[0]'
both "derived VARCHAR 'abc' is a value (no rows)" "SELECT ID FROM (SELECT ID, S FROM T) Q WHERE S = ?" '["abc"]'
both "derived empty result"    "SELECT ID FROM (SELECT ID, I FROM T) Q WHERE I = ?" '[99]'

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$RIG"
[ $fail = 0 ] && echo "PASS dfparam16" || echo "FAIL dfparam16"
exit $fail
