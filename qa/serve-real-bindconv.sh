#!/bin/bash
# A TEXT bound against a numeric or BOOLEAN base-table column that the
# engine cannot convert ('abc', '5x', '', ' ', '1.5.5', '0x5', 'yes').
#
# The engine raises *Conversion error from string "<text>"* PER ROW and
# VALUE-GATED - exactly the law a text LITERAL of the same spelling obeys:
#
#   * an EMPTY table answers no rows, no raise
#   * a table whose column holds only NULL answers no rows, no raise
#   * a FALSE conjunct written in FRONT silences it (`ID = 99 AND I = ?`),
#     one written BEHIND does not (`I = ? AND ID = 99` raises)
#   * OR, IN, BETWEEN, `? = col`, FIRST, COUNT, a join's WHERE, a derived
#     table, HAVING, UPDATE and DELETE all raise the same vector
#
# measured for INTEGER, SMALLINT, BIGINT (indexed too), INT128, NUMERIC,
# DOUBLE, FLOAT and BOOLEAN. A DECFLOAT(34) column raises TWO messages,
# *Decimal float invalid operation* then the conversion error, under the
# same gate. (DECFLOAT(16) was already right - serve-real-dfparam16.)
#
# fire-crab refused every one of these at execute with a generic
# *Dynamic SQL Error* - the wrong vector, and an error where an empty
# table or a dead conjunct answers.
#
# Still refusing (recorded, checked as fc-only refusals below): an
# EXPRESSION left side (`DP + 0 = ?`, `ABS(I) = ?`), a JOIN ON parameter,
# a parameter inside an IN subquery, `CAST(? AS INTEGER)`, a DOUBLE bound
# '1e400' (the engine compares +-inf), and capital hex '0X10' (the engine
# reads uninitialized memory).
#
# Usage: qa/serve-real-bindconv.sh [port]   (default 4191)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4191}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/bconv-eng.fdb"; FC="$D/bconv-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/bconv-build.log 2>&1 <<'SQL'
CREATE TABLE P (ID INTEGER, I INTEGER, N NUMERIC(9,2), DP DOUBLE PRECISION, B BOOLEAN, D16 DECFLOAT(16), D34 DECFLOAT(34), BI BIGINT, S VARCHAR(10));
INSERT INTO P VALUES (1, 5, 1.50, 2.5, TRUE, 1.5, 1.5, 7, 'a');
INSERT INTO P VALUES (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO P VALUES (3, 9, 9.99, 9.5, FALSE, 9.5, 9.5, 8, 'b');
CREATE TABLE X (ID INTEGER, FL FLOAT, SM SMALLINT, H INT128, D34 DECFLOAT(34), B BOOLEAN);
INSERT INTO X VALUES (1, 1.5, 2, 3, NULL, NULL);
INSERT INTO X VALUES (2, NULL, NULL, NULL, 4.5, TRUE);
CREATE TABLE NU (ID INTEGER, I INTEGER, B BOOLEAN, DP DOUBLE PRECISION, D34 DECFLOAT(34));
INSERT INTO NU VALUES (1, NULL, NULL, NULL, NULL);
CREATE TABLE E (ID INTEGER, I INTEGER, N NUMERIC(9,2), DP DOUBLE PRECISION, B BOOLEAN, D34 DECFLOAT(34));
CREATE TABLE J (ID INTEGER, I INTEGER);
INSERT INTO J VALUES (1, 1);
CREATE TABLE Z (ID INTEGER, I INTEGER, DP DOUBLE PRECISION);
COMMIT;
CREATE INDEX PBI ON P (BI);
COMMIT;
SQL
if grep -qi error /tmp/bconv-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/bconv-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-bconv.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# one query with JSON params through node; rows joined, or ERR <whole message>
node_at() { # <port> <db> <query> <json-params>
    FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR "+String(e2.message||e2).replace(/\n/g," | ").trim());db.detach();process.exit(0);}
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
both() { # <sql> <json> - the same rows or the same WHOLE error message
    local e f
    e=$(node_run 3050 "$ENG" "$1" "$2"); f=$(node_run "$PORT" "$FC" "$1" "$2")
    case "$e" in CONN_ERR) echo "FAIL $1 $2 (engine CONN_ERR)"; fail=1; return ;; esac
    if [ "$e" = "$f" ]; then echo "OK   $1 $2 => $e"; else echo "DIFF $1 $2"; echo "     eng: $e"; echo "     fc:  $f"; fail=1; fi
}
refuses() { # <sql> <json> - fire-crab still refuses (recorded divergence); fc side only
    local f
    f=$(node_run "$PORT" "$FC" "$1" "$2")
    case "$f" in ERR*) echo "OK   $1 $2 (fc refuses - recorded)" ;; *) echo "DIFF $1 $2 - fc no longer refuses: $f (update this gate)"; fail=1 ;; esac
}

echo "-- every column type raises the conversion error --"
for c in I N DP B BI; do
    both "SELECT ID FROM P WHERE $c = ? ORDER BY ID" '["abc"]'
done
for c in FL SM H; do
    both "SELECT ID FROM X WHERE $c = ? ORDER BY ID" '["abc"]'
done
both "SELECT ID FROM P WHERE D16 = ? ORDER BY ID" '["abc"]'
echo "-- DECFLOAT(34): invalid operation, then the conversion error --"
both "SELECT ID FROM P WHERE D34 = ? ORDER BY ID" '["abc"]'
both "SELECT ID FROM X WHERE D34 = ? AND ID = 99" '["abc"]'
both "SELECT ID FROM X WHERE ID = 1 AND D34 = ?" '["abc"]'
both "SELECT ID FROM NU WHERE D34 = ?" '["abc"]'
both "SELECT ID FROM E WHERE D34 = ?" '["abc"]'

echo "-- spellings --"
for v in '"5x"' '""' '" "' '"1.5.5"' '"0x5"' '"x'"'"'05'"'"'"'; do
    both "SELECT ID FROM P WHERE I = ? ORDER BY ID" "[$v]"
done
both "SELECT ID FROM P WHERE N = ? ORDER BY ID" '["1.5.5"]'
both "SELECT ID FROM P WHERE DP = ? ORDER BY ID" '["2.5x"]'
both "SELECT ID FROM P WHERE DP = ? ORDER BY ID" '[" "]'
both "SELECT ID FROM P WHERE DP = ? ORDER BY ID" '["inf"]'
both "SELECT ID FROM P WHERE B = ? ORDER BY ID" '["yes"]'
both "SELECT ID FROM P WHERE B = ? ORDER BY ID" '["t"]'
echo "-- controls: convertible texts still answer --"
both "SELECT ID FROM P WHERE I = ? ORDER BY ID" '[" 5 "]'
both "SELECT ID FROM P WHERE I = ? ORDER BY ID" '["5e0"]'
both "SELECT ID FROM P WHERE I = ? ORDER BY ID" '["1 2"]'
both "SELECT ID FROM P WHERE I = ? ORDER BY ID" '["9999999999"]'
both "SELECT ID FROM P WHERE N = ? ORDER BY ID" '["1e99"]'
both "SELECT ID FROM P WHERE DP = ? ORDER BY ID" '["2.5"]'
both "SELECT ID FROM P WHERE B = ? ORDER BY ID" '[" True "]'
both "SELECT ID FROM P WHERE D34 = ? ORDER BY ID" '["1.5"]'

echo "-- the value gate --"
for c in I B DP; do
    both "SELECT ID FROM NU WHERE $c = ?" '["abc"]'
    both "SELECT ID FROM E WHERE $c = ?" '["abc"]'
done
both "SELECT ID FROM NU WHERE I IS NOT DISTINCT FROM ?" '["abc"]'
both "SELECT ID FROM X WHERE ID = 2 AND FL = ?" '["abc"]'
both "SELECT ID FROM X WHERE ID = 2 AND H = ?" '["abc"]'
both "SELECT ID FROM X WHERE ID = 1 AND B = ?" '["t"]'
both "SELECT ID FROM P WHERE ID = 2 AND I = ?" '["abc"]'

echo "-- conjunct order, OR, IN, BETWEEN, wrappers --"
both "SELECT ID FROM P WHERE ID = 99 AND I = ?" '["abc"]'
both "SELECT ID FROM P WHERE I = ? AND ID = 99" '["abc"]'
both "SELECT ID FROM P WHERE BI = ? AND ID = 99" '["abc"]'
both "SELECT ID FROM P WHERE I = ? OR ID = 1 ORDER BY ID" '["abc"]'
both "SELECT ID FROM P WHERE ID = 1 OR I = ? ORDER BY ID" '["abc"]'
both "SELECT ID FROM P WHERE I > ? ORDER BY ID" '["abc"]'
both "SELECT ID FROM P WHERE I <> ? ORDER BY ID" '["abc"]'
both "SELECT ID FROM P WHERE I IN (?, 5) ORDER BY ID" '["abc"]'
both "SELECT ID FROM P WHERE I BETWEEN ? AND 10 ORDER BY ID" '["x"]'
both "SELECT ID FROM P WHERE ? = I ORDER BY ID" '["abc"]'
both "SELECT FIRST 1 ID FROM P WHERE I = ?" '["abc"]'
both "SELECT COUNT(*) FROM P WHERE I = ?" '["abc"]'
both "SELECT ID FROM P WHERE I = ? AND N = ?" '["abc", "def"]'
both "SELECT ID FROM P WHERE I = ? AND N = ?" '["5", "def"]'
both "SELECT ID FROM P WHERE I = ? OR B = ? ORDER BY ID" '["5", "zz"]'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID WHERE P.I = ?" '["abc"]'
both "SELECT ID FROM (SELECT ID, I FROM P) T WHERE I = ?" '["abc"]'
both "SELECT I, COUNT(*) FROM P GROUP BY I HAVING I = ?" '["abc"]'

echo "-- DML raises and writes nothing --"
both "UPDATE P SET S = 'z' WHERE I = ?" '["abc"]'
both "UPDATE P SET S = 'z' WHERE B = ?" '["maybe"]'
both "DELETE FROM P WHERE I = ?" '["abc"]'
both "DELETE FROM P WHERE D34 = ?" '["abc"]'
both "SELECT ID, S FROM P ORDER BY ID" '[]'

echo "-- an EXPRESSION left side gates on its OWN value --"
for e in "DP + 0" "I + 0" "ABS(I)" "I * 2" "DP * 2" "CAST(I AS NUMERIC(9,2))" "COALESCE(I, 0)" "CAST(DP AS FLOAT)"; do
    both "SELECT ID FROM P WHERE $e = ?" '["abc"]'
done
both "SELECT ID FROM NU WHERE DP + 0 = ?" '["abc"]'
both "SELECT ID FROM NU WHERE I + 0 = ?" '["abc"]'
both "SELECT ID FROM NU WHERE ABS(I) = ?" '["abc"]'
both "SELECT ID FROM Z WHERE DP + 0 = ?" '["abc"]'
both "SELECT ID FROM Z WHERE I + 0 = ?" '["abc"]'
both "SELECT ID FROM Z WHERE ABS(I) = ?" '["abc"]'
both "SELECT ID FROM P WHERE ID = 99 AND DP + 0 = ?" '["abc"]'
both "SELECT ID FROM P WHERE DP + 0 = ? AND ID = 99" '["abc"]'
both "SELECT ID FROM P WHERE DP + 0 = ? OR ID = 1 ORDER BY ID" '["abc"]'
both "SELECT ID FROM P WHERE ID = 1 OR DP + 0 = ? ORDER BY ID" '["abc"]'
both "SELECT ID FROM P WHERE I = ? AND DP + 0 = ?" '["5", "abc"]'
both "SELECT ID FROM P WHERE DP + 0 = ? AND I = ?" '["abc", "5"]'

echo "-- a magnitude no Rhs::Num holds: exact compares exactly, approximate is +-infinity --"
for op in "<" ">" "=" "<>"; do
    both "SELECT ID FROM P WHERE I $op ? ORDER BY ID" '["1e400"]'
    both "SELECT ID FROM P WHERE I $op ? ORDER BY ID" '["-1e400"]'
done
both "SELECT ID FROM P WHERE N < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM P WHERE N > ? ORDER BY ID" '["-1e400"]'
both "SELECT ID FROM P WHERE BI < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM X WHERE H < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM X WHERE H > ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM P WHERE DP = ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM P WHERE DP > ? ORDER BY ID" '["-1e400"]'
both "SELECT ID FROM P WHERE DP < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM P WHERE DP <= ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM X WHERE FL = ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM X WHERE FL > ? ORDER BY ID" '["-1e400"]'
both "SELECT ID FROM P WHERE D16 < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM P WHERE D34 < ? ORDER BY ID" '["1e400"]'
echo "-- the exact spellings: 20 digits, i128's limits, 41 digits --"
both "SELECT ID FROM P WHERE I < ? ORDER BY ID" '["99999999999999999999"]'
both "SELECT ID FROM P WHERE I > ? ORDER BY ID" '["99999999999999999999"]'
both "SELECT ID FROM P WHERE I = ? ORDER BY ID" '["99999999999999999999"]'
both "SELECT ID FROM P WHERE I < ? ORDER BY ID" '["170141183460469231731687303715884105727"]'
both "SELECT ID FROM P WHERE I > ? ORDER BY ID" '["-170141183460469231731687303715884105728"]'
both "SELECT ID FROM P WHERE I < ? ORDER BY ID" '["99999999999999999999999999999999999999999"]'
both "SELECT ID FROM P WHERE I > ? ORDER BY ID" '["-99999999999999999999999999999999999999999"]'
both "SELECT ID FROM P WHERE I = ? ORDER BY ID" '["99999999999999999999999999999999999999999"]'
both "SELECT ID FROM P WHERE I <> ? ORDER BY ID" '["99999999999999999999999999999999999999999"]'
both "SELECT ID FROM P WHERE N < ? ORDER BY ID" '["99999999999999999999999999999999999999999"]'
echo "-- the wide bind is still gated and still not a raise --"
both "SELECT ID FROM NU WHERE I < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM Z WHERE I < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM NU WHERE DP = ?" '["1e400"]'
both "SELECT ID FROM P WHERE ID = 99 AND I < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM P WHERE I + 0 < ? ORDER BY ID" '["1e400"]'
both "SELECT ID FROM P WHERE DP + 0 = ? ORDER BY ID" '["1e400"]'

echo "-- CAST(? AS <type>): the slot IS the cast target, and the cast converts PER ROW --"
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER)" '["abc"]'
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER)" '["5"]'
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER)" '[5]'
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER)" '[null]'
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER)" '["1.9"]'
both "SELECT ID FROM P WHERE I = CAST(? AS BIGINT)" '["abc"]'
both "SELECT ID FROM P WHERE N = CAST(? AS NUMERIC(9,2))" '["abc"]'
both "SELECT ID FROM P WHERE N = CAST(? AS NUMERIC(9,2))" '["1.50"]'
both "SELECT ID FROM P WHERE DP = CAST(? AS DOUBLE PRECISION)" '["abc"]'
both "SELECT ID FROM P WHERE DP = CAST(? AS DOUBLE PRECISION)" '["2.5"]'
both "SELECT ID FROM P WHERE B = CAST(? AS BOOLEAN)" '["abc"]'
both "SELECT ID FROM P WHERE B = CAST(? AS BOOLEAN)" '["true"]'
both "SELECT ID FROM P WHERE D34 = CAST(? AS DECFLOAT(34))" '["abc"]'
both "SELECT ID FROM P WHERE D16 = CAST(? AS DECFLOAT(16))" '["abc"]'
both "SELECT ID FROM P WHERE D34 = CAST(? AS DECFLOAT(34))" '["1.5"]'
echo "-- the target's OWN error vector --"
both "SELECT ID FROM P WHERE I = CAST(? AS SMALLINT)" '["99999"]'
echo "-- NOT value-gated: a NULL column raises, an empty table does not --"
both "SELECT ID FROM Z WHERE I = CAST(? AS INTEGER)" '["abc"]'
both "SELECT ID FROM NU WHERE I = CAST(? AS INTEGER)" '["abc"]'
both "SELECT ID FROM P WHERE ID = 99 AND I = CAST(? AS INTEGER)" '["abc"]'
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER) AND ID = 99" '["abc"]'
both "SELECT FIRST 1 ID FROM P WHERE I = CAST(? AS INTEGER)" '["abc"]'
both "SELECT ID FROM P WHERE CAST(? AS INTEGER) = I" '["abc"]'
both "SELECT ID FROM P WHERE CAST(? AS INTEGER) = 1" '["abc"]'
both "SELECT ID FROM P WHERE I > CAST(? AS INTEGER)" '["abc"]'
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER) + 0" '["abc"]'
both "UPDATE P SET S = 'q' WHERE I = CAST(? AS INTEGER)" '["abc"]'
both "SELECT ID, S FROM P ORDER BY ID" '[]'
echo '-- a ? inside a call numbers by its place in the TEXT --'
both "SELECT ID FROM P WHERE I = ? AND N = CAST(? AS NUMERIC(9,2))" '["5", "1.50"]'
both "SELECT ID FROM P WHERE CAST(? AS INTEGER) = I AND S = ?" '["5", "a"]'
both "SELECT ID FROM P WHERE I = CAST(? AS INTEGER) AND N = CAST(? AS NUMERIC(9,2))" '["9", "9.99"]'
echo "-- the DECFLOAT vectors a CAST and a literal raise --"
both "SELECT ID FROM P WHERE D34 = 'abc'" '[]'
both "SELECT ID FROM P WHERE D16 = 'abc'" '[]'
both "SELECT ID FROM P WHERE D16 > 'abc'" '[]'
both "SELECT ID FROM P WHERE D16 = CAST('abc' AS DECFLOAT(16))" '[]'
both "SELECT ID FROM P WHERE D34 = CAST('abc' AS DECFLOAT(34))" '[]'

echo '-- a ? in a JOIN ON: numbered between the select list and the WHERE --'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID AND P.I = ? ORDER BY 1" '[5]'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID AND P.I = ? ORDER BY 1" '["5"]'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID AND P.I = ? ORDER BY 1" '["abc"]'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID AND P.I = ? ORDER BY 1" '[null]'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID AND ? = P.I ORDER BY 1" '[5]'
both "SELECT P.ID FROM P JOIN J ON P.I = J.I AND P.ID = ? ORDER BY 1" '[1]'
both "SELECT P.ID FROM P LEFT JOIN J ON P.ID = J.ID AND P.I = ? ORDER BY 1" '[5]'
both "SELECT P.ID FROM P LEFT JOIN J ON P.ID = J.ID AND P.I = ? ORDER BY 1" '["abc"]'
both "SELECT P.ID FROM P LEFT JOIN J ON P.ID = J.ID AND P.I = ? ORDER BY 1" '[null]'
echo '-- the ON raises per OUTER row, even with an EMPTY inner side --'
both "SELECT P.ID FROM P JOIN Z ON P.ID = Z.ID AND P.I = ? ORDER BY 1" '[5]'
both "SELECT P.ID FROM P JOIN Z ON P.ID = Z.ID AND P.I = ? ORDER BY 1" '["abc"]'
both "SELECT Z.ID FROM Z JOIN J ON Z.ID = J.ID AND Z.I = ? ORDER BY 1" '["abc"]'
echo '-- ON slots number BEFORE the WHERE (the engine text order) --'
both "SELECT P.ID FROM P JOIN J ON P.I = ? WHERE P.ID = ? ORDER BY 1" '[5, 1]'
both "SELECT P.ID FROM P JOIN J ON P.I = ? WHERE P.ID = ? ORDER BY 1" '[1, 5]'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID AND P.I = ? WHERE P.S = ? ORDER BY 1" '[5, "a"]'
both "SELECT P.ID FROM P JOIN J ON P.ID = J.ID AND P.I = ? WHERE P.S = ? ORDER BY 1" '["abc", "a"]'

echo "-- recorded refusals (fire-crab only) --"
refuses "SELECT ID FROM P WHERE S = CAST(? AS VARCHAR(5))" '["a"]'
refuses "SELECT ID FROM P WHERE S = CAST(? AS VARCHAR(5))" '["abcdefghij"]'
refuses "SELECT ID FROM P WHERE ID IN (SELECT ID FROM E WHERE I = ?)" '["abc"]'
refuses "SELECT ID FROM P WHERE EXISTS (SELECT 1 FROM E WHERE I = ?)" '["abc"]'
refuses "SELECT ID FROM P WHERE I < ?" '["1e-400"]'
refuses "SELECT ID FROM P WHERE I = ?" '["0X10"]'

[ $fail -eq 0 ] && echo "PASS serve-real-bindconv" || { echo "FAIL serve-real-bindconv"; exit 1; }
