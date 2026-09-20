#!/bin/bash
# A LIKE / STARTING WITH PATTERN AGAINST AN INT128-BACKED EXACT NUMERIC
# IS CONVERTED; AGAINST A NARROWER ONE IT IS NOT.
#
# The neighbour of `serve-real-dfnflit.sh`, and NOT the same law: there
# the question is a decNumber grammar and which spellings are values,
# here it is a WIDTH BOUNDARY inside one family of column types.
#
#   NUMERIC(9,2)  LIKE '1%' -> answers     NUMERIC(19,0) LIKE '1%' -> RAISES
#   NUMERIC(18,0) LIKE '1%' -> answers     NUMERIC(38,2) LIKE '1%' -> RAISES
#   NUMERIC(18,4) LIKE '1%' -> answers     INT128        LIKE '1%' -> RAISES
#
# A NARROW column matches the pattern against the RENDERED value - which
# is what this server did for every width.  A WIDE one CONVERTS the
# pattern first, so a wildcard, which cannot convert, raises the ONE-LINE
# 22018 `conversion error from string "1%"` AT PREPARE, with no describe.
#
# THE BOUNDARY IS THE STORAGE TYPE and precision >= 19 is only what
# selects it: `NUMERIC(18,0)` describes sqltype 580 INT64 len 8 and
# `NUMERIC(19,0)` describes 32752 INT128 len 16.  So the test is
# `dtype::INT128` and no precision arithmetic is needed - which is why
# this gate carries a column at each side of the boundary AT TWO SCALES,
# in both the NUMERIC and DECIMAL spellings.
#
# AND WHEN THE PATTERN CONVERTS IT IS RENDERED BACK, AT THE LITERAL'S OWN
# SCALE, NOT THE COLUMN'S.  The cells that fix that are the ones where
# the NARROW column answers the other way round on the same text:
#
#   N382 STARTING WITH '01' -> 1;2;3   |  N92 STARTING WITH '01' -> (none)
#   N382 LIKE '01.50'       -> 1          ('01.50' -> 1.50 -> "1.50")
#   N382 LIKE '10'          -> (none)     ("10", NOT the column's "10.00")
#
# The grammar is the LENIENT compare one, so an INTERIOR BLANK is skipped
# (`N382 STARTING WITH '1 0'` -> 2;3) exactly as in the DECFLOAT law,
# while hex and the empty string raise.
#
# WHAT THIS GATE DOES NOT CLAIM, and pins instead:
#   * an e/E spelling keeps the RAW TEXT - `N382 STARTING WITH '1e1'`
#     answers NOTHING on the engine, where converting it to 10 and
#     rendering "10" would predict 2;3.  That branch is the previous
#     binary's answer and is measured right, not a new law;
#   * CONTAINING and SIMILAR TO over these columns, which this server
#     refuses outright on both binaries.
#
# Usage: qa/serve-real-i128like.sh [port]   (default 4468)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4468}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/i128like-eng.fdb"; FC="$D/i128like-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (
  ID INTEGER,
  N92 NUMERIC(9,2), N180 NUMERIC(18,0), N184 NUMERIC(18,4), N1818 NUMERIC(18,18),
  N190 NUMERIC(19,0), N194 NUMERIC(19,4), N382 NUMERIC(38,2), N380 NUMERIC(38,0),
  DC192 DECIMAL(19,2), DC382 DECIMAL(38,2),
  I128 INT128, BI BIGINT, SM SMALLINT, IN4 INTEGER, S VARCHAR(20),
  DP DOUBLE PRECISION, FL FLOAT);
CREATE TABLE W (ID INTEGER, N382 NUMERIC(38,2));
CREATE TABLE U (ID INTEGER, TAG VARCHAR(5));
CREATE TABLE C (ID INTEGER, N382 NUMERIC(38,2), CP COMPUTED BY (N382 * 1), N92 NUMERIC(9,2));
COMMIT;
INSERT INTO T VALUES (1, 1.50, 1, 1.5000, 0.5, 1, 1.5000, 1.50, 1, 1.50, 1.50, 1, 1, 1, 1, '1.50', 1.5, 1.5);
INSERT INTO T VALUES (2, 10.00, 10, 10.0000, 0.1, 10, 10.0000, 10.00, 10, 10.00, 10.00, 10, 10, 10, 10, '10.00', 100.0, 100.0);
INSERT INTO T VALUES (3, 100.50, 100, 100.5000, 0.0, 100, 100.5000, 100.50, 100, 100.50, 100.50, 100, 100, 100, 100, '100.50', -2.5, -2.5);
INSERT INTO W VALUES (1, 1.50);
INSERT INTO W VALUES (2, 10.00);
INSERT INTO W VALUES (3, 100.50);
INSERT INTO U VALUES (1,'a'); INSERT INTO U VALUES (2,'b'); INSERT INTO U VALUES (3,'c');
INSERT INTO C (ID,N382,N92) VALUES (1, 1.50, 1.50);
INSERT INTO C (ID,N382,N92) VALUES (2, 10.00, 10.00);
INSERT INTO C (ID,N382,N92) VALUES (3, 100.50, 100.50);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/i128like-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/i128like-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/i128like-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/i128like-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-i128like-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
LOST='const lost=e=>/was lost|ECONNRESET|EPIPE|Connection is closed|socket hang up/i.test(String((e&&e.message)||e));'
FMT='const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":v).join()).join(";");'
q() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e "$LOST$FMT"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
      if(e2){if(lost(e2)){console.log("CONN_ERR");process.exit(1);}console.log("ERR");db.detach();process.exit(0);}
      console.log(fmt(r));db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
run() { local n=0 r; while [ $n -lt 8 ]; do r=$(q "$1" "$2" "$3" "$4")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }
# the FULL error vector as isql renders it - the ONE-LINE 22018 and the
# TWO-LINE compound are different answers and `ERR` cannot tell them apart
err() { printf '%s;\n' "$2" | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 \
    | tr -d '\r' | grep -aiE 'SQLSTATE|conversion error|Decimal float' | sed 's/^ *//;s/  */ /g' | paste -sd'|'; }

# the value AND the whole describe must match
both() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] && [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - that is an err_same cell]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - the value agrees, the announcement does not)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# BOTH raise AND THE VECTORS ARE THE SAME TEXT, and - because this whole
# law is about WHEN the raise happens - NEITHER emits a describe
err_same() {
    ran=$((ran + 1))
    local ee fe ed fd
    ee=$(err "127.0.0.1/$REAL:$ENG" "$2"); fe=$(err "127.0.0.1/$PORT:$FC" "$2")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ee" ]; then echo "FAIL $1 - THE ENGINE NO LONGER RAISES; the boundary moved"; fail=1
    elif [ -z "$fe" ]; then echo "FAIL $1 - this server did not raise"; fail=1
    elif [ "$ee" != "$fe" ]; then
        echo "FAIL $1 (the VECTOR)"; echo "     eng=[$ee]"; echo "     fc =[$fe]"; fail=1
    elif [ -n "$ed" ]; then echo "FAIL $1 - the ENGINE emitted a describe, so this is not a prepare-time raise"; fail=1
    elif [ -n "$fd" ]; then echo "FAIL $1 - THIS SERVER ANSWERED THE PREPARE [$fd] and raised later"; fail=1
    else echo "OK   $1 [$ee]"; fi
}
# BOTH raise and the VECTORS DIFFER - both pinned as they stand, so the
# cell fails the day either one moves.  Recorded, not fixed.
err_differs() { # <label> <sql> <engine-vector-substring> <this-server-vector-substring>
    ran=$((ran + 1))
    local ee fe
    ee=$(err "127.0.0.1/$REAL:$ENG" "$2"); fe=$(err "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ee" ] || [ -z "$fe" ]; then echo "FAIL $1 - one of the two stopped raising [eng=$ee] [fc=$fe]"; fail=1
    elif [ "${ee#*$3}" = "$ee" ]; then echo "FAIL $1 - the ENGINE vector moved: [$ee] no longer carries [$3]"; fail=1
    elif [ "${fe#*$4}" = "$fe" ]; then echo "FAIL $1 - THIS SERVER's vector moved: [$fe] no longer carries [$4] - if it now matches the engine, promote the cell"; fail=1
    else echo "OK   $1 (recorded vector gap: engine [$3], this server [$4])"; fi
}
# the engine RAISES and this server ANSWERS - a recorded WRONG ANSWER,
# self-expiring: it fails the day this server starts raising.
eng_err_only() { # <label> <sql> <json> <this-server-answer>
    ran=$((ran + 1))
    local js="${3:-[]}" ee fv
    ee=$(err "127.0.0.1/$REAL:$ENG" "$2"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ -z "$ee" ]; then echo "FAIL $1 - THE ENGINE NO LONGER RAISES; the boundary moved"; fail=1
    elif [ "$fv" = ERR ]; then echo "FAIL $1 - THIS SERVER NOW RAISES; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server now answers [$fv], not [$4]"; fail=1
    else echo "OK   $1 (recorded WRONG ANSWER: engine raises, this server answers [$fv])"; fi
}
# the engine ANSWERS and this server refuses - a recorded boundary
eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE no longer answers; the boundary moved"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS SERVER ANSWERS [$fv] where it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}

# A SENTINEL BEFORE ANY CELL: the whole gate is about WHICH SIDE OF A
# WIDTH BOUNDARY a column sits on, so it proves the widths themselves -
# three rows, and the 18-vs-19 pair really describing INT64 against
# INT128.  A fixture that silently declared both sides narrow would make
# every wide cell agree for the wrong reason.
sent=$(run "$REAL" "$ENG" "SELECT (SELECT COUNT(*) FROM T) A,(SELECT COUNT(*) FROM W) B,(SELECT COUNT(*) FROM U) C,(SELECT COUNT(*) FROM C) D FROM RDB\$DATABASE" '[]')
[ "$sent" = "3,3,3,3" ] || { echo "FAIL SENTINEL rows [$sent] (want 3,3,3,3)"; exit 1; }
wid=$(printf 'SET SQLDA_DISPLAY ON;\nSELECT N180, N190, N92, N382, I128 FROM T;\n' \
      | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' \
      | grep -aoE 'sqltype: [0-9]+' | tr -s ' ' | paste -sd'|')
[ "$wid" = "sqltype: 580|sqltype: 32752|sqltype: 496|sqltype: 32752|sqltype: 32752" ] \
  || { echo "FAIL SENTINEL widths [$wid] - the 18/19 boundary is not where this gate assumes"; exit 1; }
echo "OK   SENTINEL [$sent | $wid]"

echo "--- 1. THE BOUNDARY: a wildcard raises on a WIDE column and matches text on a NARROW one"
both      "1 N92 LIKE '1%'   - NUMERIC(9,2), narrow"      "SELECT ID FROM T WHERE N92 LIKE '1%' ORDER BY ID"
both      "1 N180 LIKE '1%'  - NUMERIC(18,0), the last narrow one" "SELECT ID FROM T WHERE N180 LIKE '1%' ORDER BY ID"
both      "1 N184 LIKE '1%'  - NUMERIC(18,4), narrow at a scale" "SELECT ID FROM T WHERE N184 LIKE '1%' ORDER BY ID"
both      "1 N1818 LIKE '0%' - NUMERIC(18,18), the extreme scale, still narrow" "SELECT ID FROM T WHERE N1818 LIKE '0%' ORDER BY ID"
both      "1 BI LIKE '1%'    - BIGINT"                    "SELECT ID FROM T WHERE BI LIKE '1%' ORDER BY ID"
both      "1 SM LIKE '1%'    - SMALLINT"                  "SELECT ID FROM T WHERE SM LIKE '1%' ORDER BY ID"
both      "1 IN4 LIKE '1%'   - INTEGER"                   "SELECT ID FROM T WHERE IN4 LIKE '1%' ORDER BY ID"
err_same  "1 N190 LIKE '1%'  - NUMERIC(19,0), ONE DIGIT WIDER and it raises" "SELECT ID FROM T WHERE N190 LIKE '1%'"
err_same  "1 N194 LIKE '1%'  - NUMERIC(19,4), wide at a scale" "SELECT ID FROM T WHERE N194 LIKE '1%'"
err_same  "1 N382 LIKE '1%'  - NUMERIC(38,2)"             "SELECT ID FROM T WHERE N382 LIKE '1%'"
err_same  "1 N380 LIKE '1%'  - NUMERIC(38,0)"             "SELECT ID FROM T WHERE N380 LIKE '1%'"
err_same  "1 DC192 LIKE '1%' - DECIMAL(19,2), the other spelling" "SELECT ID FROM T WHERE DC192 LIKE '1%'"
err_same  "1 DC382 LIKE '1%' - DECIMAL(38,2)"             "SELECT ID FROM T WHERE DC382 LIKE '1%'"
err_same  "1 I128 LIKE '1%'  - INT128 itself"             "SELECT ID FROM T WHERE I128 LIKE '1%'"
both      "1 CONTROL S LIKE '1%' - a VARCHAR column is a real pattern at any width" "SELECT ID FROM T WHERE S LIKE '1%' ORDER BY ID"

echo "--- 2. THE ROUND TRIP: the converted value is rendered back, at the LITERAL's scale"
both      "2 N382 STARTING WITH '01' - '01' becomes \"1\"" "SELECT ID FROM T WHERE N382 STARTING WITH '01' ORDER BY ID"
both      "2 N92 STARTING WITH '01'  - ...and the NARROW twin answers the OTHER WAY on the same text" "SELECT ID FROM T WHERE N92 STARTING WITH '01' ORDER BY ID"
both      "2 N382 STARTING WITH ' 1' - the blank goes in the conversion" "SELECT ID FROM T WHERE N382 STARTING WITH ' 1' ORDER BY ID"
both      "2 N382 STARTING WITH '+1' - and so does the sign" "SELECT ID FROM T WHERE N382 STARTING WITH '+1' ORDER BY ID"
both      "2 N382 LIKE '01.50'  - -> 1.50 -> \"1.50\", which the raw text is not" "SELECT ID FROM T WHERE N382 LIKE '01.50' ORDER BY ID"
both      "2 N382 LIKE '1.50'"                            "SELECT ID FROM T WHERE N382 LIKE '1.50' ORDER BY ID"
both      "2 N382 LIKE '1.5'    - the row renders \"1.50\", so this matches nothing" "SELECT ID FROM T WHERE N382 LIKE '1.5' ORDER BY ID"
both      "2 N382 LIKE '10'     - THE SCALE CELL: \"10\", NOT the column's \"10.00\"" "SELECT ID FROM T WHERE N382 LIKE '10' ORDER BY ID"
both      "2 N382 LIKE '10.00'  - ...and at the column's own scale it matches" "SELECT ID FROM T WHERE N382 LIKE '10.00' ORDER BY ID"
both      "2 I128 STARTING WITH '010' - the round trip on INT128 itself" "SELECT ID FROM T WHERE I128 STARTING WITH '010' ORDER BY ID"
both      "2 I128 LIKE '010'"                             "SELECT ID FROM T WHERE I128 LIKE '010' ORDER BY ID"
both      "2 I128 STARTING WITH '11' - and it can still miss" "SELECT ID FROM T WHERE I128 STARTING WITH '11' ORDER BY ID"
both      "2 N382 STARTING WITH '1' - CONTROL, the plain prefix" "SELECT ID FROM T WHERE N382 STARTING WITH '1' ORDER BY ID"

echo "--- 3. THE GRAMMAR IS THE LENIENT ONE: an interior blank is skipped"
both      "3 N382 STARTING WITH '1 0' - -> 10 -> \"10\"" "SELECT ID FROM T WHERE N382 STARTING WITH '1 0' ORDER BY ID"
both      "3 N382 LIKE '1 0 0.50'     - -> 100.50"       "SELECT ID FROM T WHERE N382 LIKE '1 0 0.50' ORDER BY ID"
both      "3 N382 = '1 0 0.50'        - CONTROL: the comparison path already agreed" "SELECT ID FROM T WHERE N382 = '1 0 0.50' ORDER BY ID"
err_same  "3 N382 STARTING WITH '0x1' - hex raises"       "SELECT ID FROM T WHERE N382 STARTING WITH '0x1'"
err_same  "3 N382 STARTING WITH ''    - and so does the empty string" "SELECT ID FROM T WHERE N382 STARTING WITH ''"
err_same  "3 N382 LIKE 'abc'          - ordinary junk"    "SELECT ID FROM T WHERE N382 LIKE 'abc'"
both      "3 CONTROL N92 LIKE 'abc'   - which the NARROW column simply does not match" "SELECT ID FROM T WHERE N92 LIKE 'abc' ORDER BY ID"

echo "--- 4. WILDCARDS, NEGATION, AND THE RAISE AT PREPARE"
err_same  "4 N190 LIKE '1_'"                              "SELECT ID FROM T WHERE N190 LIKE '1_'"
err_same  "4 N382 LIKE '%.5%'  - the cell serve-real-intlike.sh has been red on" "SELECT ID FROM T WHERE N382 LIKE '%.5%'"
err_same  "4 N382 NOT LIKE '1%' - negation does not excuse it" "SELECT ID FROM T WHERE N382 NOT LIKE '1%'"
err_same  "4 1 = 0 AND N382 LIKE '1%' - a dead conjunct still raises" "SELECT ID FROM T WHERE 1 = 0 AND N382 LIKE '1%'"
err_same  "4 ID = 99 AND N382 LIKE '1%' - and an empty result" "SELECT ID FROM T WHERE ID = 99 AND N382 LIKE '1%'"
err_same  "4 DELETE FROM W WHERE N382 LIKE '1%' - it reaches DML" "DELETE FROM W WHERE N382 LIKE '1%'"
both      "4 ...and W is untouched"                       "SELECT ID FROM W ORDER BY ID"
err_same  "4 UPDATE W SET ID = 77 WHERE N382 LIKE '1%'"   "UPDATE W SET ID = 77 WHERE N382 LIKE '1%'"
both      "4 ...and nothing was renumbered"               "SELECT ID FROM W ORDER BY ID"

echo "--- 5. MUST NOT TOUCH: the comparison operators on the SAME wide columns"
both      "5 N382 = '10.00'"                              "SELECT ID FROM T WHERE N382 = '10.00' ORDER BY ID"
both      "5 N382 = '010'    - the comparison converts too, and always did" "SELECT ID FROM T WHERE N382 = '010' ORDER BY ID"
both      "5 N382 > '1.50'"                               "SELECT ID FROM T WHERE N382 > '1.50' ORDER BY ID"
both      "5 N382 BETWEEN '1' AND '11'"                   "SELECT ID FROM T WHERE N382 BETWEEN '1' AND '11' ORDER BY ID"
both      "5 N382 IN ('1.50','10.00')"                    "SELECT ID FROM T WHERE N382 IN ('1.50','10.00') ORDER BY ID"
both      "5 I128 = '010'"                                "SELECT ID FROM T WHERE I128 = '010' ORDER BY ID"
both      "5 N382 IS NULL"                                "SELECT ID FROM T WHERE N382 IS NULL ORDER BY ID"
both      "5 CONTROL N92 LIKE '%.5%' - the narrow pattern match this chunk must not move" "SELECT ID FROM T WHERE N92 LIKE '%.5%' ORDER BY ID"
both      "5 CONTROL N92 LIKE '10.00'"                    "SELECT ID FROM T WHERE N92 LIKE '10.00' ORDER BY ID"
both      "5 CONTROL N180 STARTING WITH '1'"              "SELECT ID FROM T WHERE N180 STARTING WITH '1' ORDER BY ID"

echo "--- 6. RECORDED, NOT FIXED"
# An e/E spelling keeps the RAW TEXT.  That is the previous binary's
# behaviour and it is MEASURED RIGHT: converting '1e1' to 10 and
# rendering "10" would predict 2;3 and the engine answers nothing.
both      "6 N382 STARTING WITH '1e1' - the exponent keeps the raw text, and the engine agrees" "SELECT ID FROM T WHERE N382 STARTING WITH '1e1' ORDER BY ID"
both      "6 N382 LIKE '99999999999999999999999.50' - an INT128-magnitude pattern converts and misses" "SELECT ID FROM T WHERE N382 LIKE '99999999999999999999999.50' ORDER BY ID"
eng_only  "6 N382 CONTAINING '1' - this server refuses CONTAINING over a numeric column, on both binaries" "SELECT ID FROM T WHERE N382 CONTAINING '1' ORDER BY ID"
err_differs "6 N382 SIMILAR TO '1%' - the engine converts and raises; this server refuses the shape" \
            "SELECT ID FROM T WHERE N382 SIMILAR TO '1%'" "22018" "42000"

echo "--- 7. THE OTHER FIVE ROUTERS, because a WHERE over a plain column is not the only way in"
# `col_kind` answers None for every INT128 column, so a JOIN, a COMPUTED
# BY column, an arithmetic operand and a CAST all divert to the
# EXPRESSION resolver and never reach the typed path - and a LIKE inside
# IIF / CASE WHEN takes a third route again.  All five answered rows
# after the WHERE arms were fixed.
err_same  "7 JOIN + WHERE T.N382 LIKE '1%'"  "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.N382 LIKE '1%'"
both      "7 JOIN + WHERE T.N92 LIKE '1%' - the narrow twin still answers" "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.N92 LIKE '1%' ORDER BY T.ID"
both      "7 JOIN + WHERE T.N382 LIKE '10.00' - and a converting pattern answers" "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.N382 LIKE '10.00' ORDER BY T.ID"
err_same  "7 WHERE IIF(N382 LIKE '1%',1,0) = 1 - a condition inside an expression" "SELECT ID FROM T WHERE IIF(N382 LIKE '1%',1,0) = 1"
err_same  "7 SELECT SUM(IIF(N382 LIKE '1%',..)) - a PROJECTION, a different router again" "SELECT SUM(IIF(N382 LIKE '1%',1,0)) A FROM T"
err_same  "7 SELECT SUM(CASE WHEN N382 LIKE '1%' ..)" "SELECT SUM(CASE WHEN N382 LIKE '1%' THEN 1 ELSE 0 END) A FROM T"
both      "7 SUM(IIF(N92 LIKE '1%',..)) - the narrow twin of the projection" "SELECT SUM(IIF(N92 LIKE '1%',1,0)) A FROM T"
both      "7 SUM(IIF(N382 LIKE '10.00',..)) - and a converting pattern" "SELECT SUM(IIF(N382 LIKE '10.00',1,0)) A FROM T"
err_same  "7 WHERE CP LIKE '1%' - a COMPUTED BY INT128 column"  "SELECT ID FROM C WHERE CP LIKE '1%'"
err_same  "7 WHERE N382 + 0 LIKE '1%' - an arithmetic operand"  "SELECT ID FROM T WHERE N382 + 0 LIKE '1%'"
err_same  "7 WHERE CAST(ID AS NUMERIC(38,2)) LIKE '1%' - a CAST" "SELECT ID FROM T WHERE CAST(ID AS NUMERIC(38,2)) LIKE '1%'"
both      "7 SUM(IIF(N382 STARTING WITH '01',..)) - THE ROUND TRIP through the expression router" "SELECT SUM(IIF(N382 STARTING WITH '01',1,0)) A FROM T"
both      "7 SUM(IIF(N92 STARTING WITH '01',..)) - ...and the narrow twin answers the other way" "SELECT SUM(IIF(N92 STARTING WITH '01',1,0)) A FROM T"
both      "7 SUM(CASE WHEN N382 STARTING WITH '01' ..)" "SELECT SUM(CASE WHEN N382 STARTING WITH '01' THEN 1 ELSE 0 END) A FROM T"
err_same  "7 SUM(IIF(N382 STARTING WITH '0x1',..)) - hex through the expression router" "SELECT SUM(IIF(N382 STARTING WITH '0x1',1,0)) A FROM T"
both      "7 CONTROL a TEXT operand through the same router is untouched" "SELECT SUM(IIF(CAST(ID AS VARCHAR(4)) STARTING WITH '1',1,0)) A FROM T"
eng_only  "7 JOIN + T.N382 STARTING WITH '01' - a joined STARTING over a numeric operand REFUSES here, on both binaries, and that refusal is deliberate" "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.N382 STARTING WITH '01' ORDER BY T.ID"

echo "--- 8. THE BOUNDARY IS THE dtype, AND IT DOES NOT STOP AT INT128"
# The whole family, measured: the operand types that CONVERT are INT128,
# DOUBLE PRECISION, DECFLOAT(16|34), DATE, TIMESTAMP, TIMESTAMP WITH TIME
# ZONE and TIME.  The ones that do NOT are SMALLINT, INTEGER, BIGINT,
# FLOAT, every NUMERIC/DECIMAL at precision <= 18 (any scale), BOOLEAN,
# CHAR/VARCHAR and BLOB.  This chunk lands the INT128 half; the DOUBLE
# and TEMPORAL halves each need their own renderer and are the next
# chunk, so their wrong answers are PINNED here rather than left silent.
both      "8 CAST(ID AS BIGINT) LIKE '1%' - BIGINT carries NINETEEN DIGITS and still does not convert, which is what kills the 'precision decides it' reading" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) LIKE '1%' ORDER BY ID"
both      "8 CAST(N92 AS FLOAT) LIKE '1%' - FLOAT does not convert, though DOUBLE does" "SELECT ID FROM T WHERE CAST(N92 AS FLOAT) LIKE '1%' ORDER BY ID"
both      "8 CAST(N382 AS NUMERIC(18,2)) LIKE '1%' - a WIDE column NARROWED stops converting" "SELECT ID FROM T WHERE CAST(N382 AS NUMERIC(18,2)) LIKE '1%' ORDER BY ID"
err_same  "8 CAST(N92 AS NUMERIC(19,2)) LIKE '1%' - ...and a NARROW one WIDENED starts" "SELECT ID FROM T WHERE CAST(N92 AS NUMERIC(19,2)) LIKE '1%'"
both      "8 (N92 * 1) LIKE '1%' - a narrow arithmetic result"  "SELECT ID FROM T WHERE (N92 * 1) LIKE '1%' ORDER BY ID"
both      "8 CAST(N382 AS VARCHAR(20)) LIKE '1%' - rendered FIRST, so it is a real pattern again" "SELECT ID FROM T WHERE CAST(N382 AS VARCHAR(20)) LIKE '1%' ORDER BY ID"
eng_err_only "8 CAST(N92 AS DOUBLE PRECISION) LIKE '1%' - DOUBLE converts too, and this server still answers rows" \
             "SELECT ID FROM T WHERE CAST(N92 AS DOUBLE PRECISION) LIKE '1%' ORDER BY ID" '[]' "1;2;3"
eng_err_only "8 CURRENT_DATE LIKE '2%' - and so does a DATE" \
             "SELECT ID FROM T WHERE CURRENT_DATE LIKE '2%' ORDER BY ID" '[]' "1;2;3"
eng_err_only "8 CAST('2020-01-01' AS DATE) LIKE '1%' - a written DATE cast" \
             "SELECT ID FROM T WHERE CAST('2020-01-01' AS DATE) LIKE '1%' ORDER BY ID" '[]' "(none)"

echo "--- 9. THE DOUBLE HALF: the SAME law with the exponent branch FLIPPED"
# An EXACT wide operand renders a non-exponent spelling at the literal's
# own scale and leaves an e/E one as raw text.  A DOUBLE operand renders
# the non-exponent spelling the same way - which is why `DP LIKE '1.5'`
# answers NOTHING against a row rendering "1.500000000000000" - and
# renders an e/E one through the ENGINE'S CANONICAL DOUBLE TEXT, which is
# why `'1.5e0'`, `'15e-1'`, `'0.15e1'` and `'1e2'` all answer.
# Nine of these were PREDICTED from that reading before being measured.
err_same  "9 DP LIKE '1%'   - a wildcard cannot convert"     "SELECT ID FROM T WHERE DP LIKE '1%'"
err_same  "9 DP LIKE 'abc'"                                  "SELECT ID FROM T WHERE DP LIKE 'abc'"
err_same  "9 DP LIKE '_'"                                    "SELECT ID FROM T WHERE DP LIKE '_'"
err_same  "9 DP NOT LIKE '1%' - negation does not excuse it" "SELECT ID FROM T WHERE DP NOT LIKE '1%'"
err_same  "9 1 = 0 AND DP LIKE '1%' - and it raises at PREPARE" "SELECT ID FROM T WHERE 1 = 0 AND DP LIKE '1%'"
both      "9 DP LIKE '1.5'   - scale 1, so \"1.5\", which the row's text is not" "SELECT ID FROM T WHERE DP LIKE '1.5' ORDER BY ID"
both      "9 DP LIKE '1.50'  - nor is \"1.50\""            "SELECT ID FROM T WHERE DP LIKE '1.50' ORDER BY ID"
both      "9 DP LIKE '1.5000000000000000' - sixteen decimals, one too many" "SELECT ID FROM T WHERE DP LIKE '1.5000000000000000' ORDER BY ID"
both      "9 DP LIKE '1.500000000000000' - ...and at FIFTEEN it is the render" "SELECT ID FROM T WHERE DP LIKE '1.500000000000000' ORDER BY ID"
both      "9 DP LIKE '100'   - scale 0"                      "SELECT ID FROM T WHERE DP LIKE '100' ORDER BY ID"
both      "9 DP LIKE '100.0000000000000'"                    "SELECT ID FROM T WHERE DP LIKE '100.0000000000000' ORDER BY ID"
both      "9 DP LIKE '-2.500000000000000' - and a negative one" "SELECT ID FROM T WHERE DP LIKE '-2.500000000000000' ORDER BY ID"
both      "9 DP LIKE '1.5e0'  - AN EXPONENT TAKES THE DOUBLE GRAMMAR" "SELECT ID FROM T WHERE DP LIKE '1.5e0' ORDER BY ID"
both      "9 DP LIKE '15e-1'  - ...whatever the spelling of the value" "SELECT ID FROM T WHERE DP LIKE '15e-1' ORDER BY ID"
both      "9 DP LIKE '0.15e1'"                               "SELECT ID FROM T WHERE DP LIKE '0.15e1' ORDER BY ID"
both      "9 DP LIKE '1e2'"                                  "SELECT ID FROM T WHERE DP LIKE '1e2' ORDER BY ID"
both      "9 DP LIKE '-25e-1'"                               "SELECT ID FROM T WHERE DP LIKE '-25e-1' ORDER BY ID"
both      "9 DP LIKE '01.500000000000000' - the leading zero goes in the conversion" "SELECT ID FROM T WHERE DP LIKE '01.500000000000000' ORDER BY ID"
both      "9 DP LIKE ' 1.500000000000000 ' - and the surrounding blanks" "SELECT ID FROM T WHERE DP LIKE ' 1.500000000000000 ' ORDER BY ID"
both      "9 DP LIKE '1 . 500000000000000' - and an INTERIOR one: the lenient grammar" "SELECT ID FROM T WHERE DP LIKE '1 . 500000000000000' ORDER BY ID"
both      "9 DP LIKE '1.5e0 ' - a trailing blank AFTER an exponent is fine" "SELECT ID FROM T WHERE DP LIKE '1.5e0 ' ORDER BY ID"
err_same  "9 DP LIKE '1.5 e0' - ...an INTERIOR one is not: the double grammar refuses" "SELECT ID FROM T WHERE DP LIKE '1.5 e0'"
both      "9 CONTROL FL LIKE '1%' - FLOAT DOES NOT CONVERT, which is why this asks for the dtype and not for \"approximate\"" "SELECT ID FROM T WHERE FL LIKE '1%' ORDER BY ID"
both      "9 CONTROL FL LIKE '1.5'"                          "SELECT ID FROM T WHERE FL LIKE '1.5' ORDER BY ID"
both      "9 CONTROL S LIKE '1%' - and a VARCHAR is a real pattern" "SELECT ID FROM T WHERE S LIKE '1%' ORDER BY ID"

echo "--- 10. STARTING WITH over an APPROXIMATE operand, which this server used to REFUSE"
# `resolve_expr_term`'s STARTING arm refused every approximate operand
# with a bare 42000 on the grounds that the rendering was "unprobed".
# It is probed now, and the refusal was costing THREE real answers on
# FLOAT alone - while the same server's `FL LIKE '1%'` had been right all
# along.  A refusal planted at an edge nobody measured is the trap the
# house laws warn about; this was one.
both      "10 FL STARTING WITH '1'   - FLOAT does not convert: a plain text prefix" "SELECT ID FROM T WHERE FL STARTING WITH '1' ORDER BY ID"
both      "10 FL STARTING WITH '1.5'"                        "SELECT ID FROM T WHERE FL STARTING WITH '1.5' ORDER BY ID"
both      "10 FL STARTING WITH 'abc' - ...and junk simply matches nothing" "SELECT ID FROM T WHERE FL STARTING WITH 'abc' ORDER BY ID"
both      "10 FL STARTING WITH '01'  - ...which a CONVERTING operand would have matched" "SELECT ID FROM T WHERE FL STARTING WITH '01' ORDER BY ID"
both      "10 DP STARTING WITH '1'   - a DOUBLE DOES convert its prefix" "SELECT ID FROM T WHERE DP STARTING WITH '1' ORDER BY ID"
both      "10 DP STARTING WITH '+1'  - THE CELL RAW TEXT CANNOT PRODUCE: '+1' renders \"1\"" "SELECT ID FROM T WHERE DP STARTING WITH '+1' ORDER BY ID"
both      "10 DP STARTING WITH '1.5'"                        "SELECT ID FROM T WHERE DP STARTING WITH '1.5' ORDER BY ID"
both      "10 DP STARTING WITH '1.5e0' - and the exponent form goes through DOUBLE here too" "SELECT ID FROM T WHERE DP STARTING WITH '1.5e0' ORDER BY ID"
err_same  "10 DP STARTING WITH 'abc' - and what cannot convert raises, as LIKE does" "SELECT ID FROM T WHERE DP STARTING WITH 'abc'"
both      "10 CONTROL S STARTING WITH '1' - a VARCHAR operand is untouched" "SELECT ID FROM T WHERE S STARTING WITH '1' ORDER BY ID"

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-i128like-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-i128like-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

echo "ran $ran checks"
if [ "$ran" -lt 120 ]; then echo "FAIL only $ran checks ran (floor 120) - cells went missing"; fail=1; fi
exit $fail
