#!/bin/bash
# A STRING LITERAL AGAINST A DECFLOAT COLUMN IS CONVERTED ONCE, AT PREPARE.
#
# The engine has THREE different text->DECFLOAT grammars and this gate is
# about the one a LITERAL gets, which is neither of the other two:
#
#   * a bound PARAMETER and an explicit CAST take decNumber's grammar -
#     `CAST('inf' AS DECFLOAT(34))` is a VALUE, `D = ?` bound to 'inf'
#     ANSWERS, and a surrounding blank RAISES;
#   * a MULTI-ELEMENT IN-LIST is a CHAR list: every element is
#     BLANK-PADDED TO THE WIDEST ONE and then converted PER ROW by
#     decNumber - which is why `D IN ('2.5','7')` raises on `"7  "`
#     although both elements are perfectly good numbers, and why
#     `D IN ('inf','100')` (nothing to pad) ANSWERS;
#   * a LITERAL takes the engine's LENIENT COMPARE grammar, once, at
#     PREPARE, at the COLUMN's width, and that is what this gate pins:
#
#       - a BLANK IS IGNORED WHEREVER IT STANDS when there is no
#         exponent: `D = '1 0 0'` is the 100 row, `'- 2.5'` the -2.5 row,
#         `'1 . 5'` the 1.5 row, and `'1 5'` converts to 15 and matches
#         nothing rather than raising;
#       - WITH an e/E the whole string goes to the DOUBLE grammar, which
#         trims its ENDS and refuses an INTERIOR blank: `' 1.5e0 '`
#         answers, `'1 e2'` and `'1.5 e0'` raise;
#       - EVERY decNumber SPECIAL is REJECTED - inf, Infinity, +INF, NaN,
#         nan, sNaN - and so is every junk string, with the engine's
#         ONE-LINE 22018 `conversion error from string "<text>"`.  ONE
#         line: the two-line compound that opens with *Decimal float
#         invalid operation* belongs to the per-row paths;
#       - an out-of-range exponent is 22003 *Decimal float overflow*,
#         and the boundary is decimal128's emax: '1e6144' prepares,
#         '1e6145' raises, '1e-7000' underflows to 0 and ANSWERS;
#       - THE RAISE IS AT PREPARE AND EMITS NO DESCRIBE.  `1 = 0 AND
#         D = 'inf'`, `ID = 99 AND D = 'inf'` and the same predicate over
#         an empty table all raise, and none of them evaluates a row.
#
#   * a LIKE / STARTING WITH pattern takes THE SAME conversion, so it is
#     not a pattern until it converts (`D LIKE '1%'` raises); and when it
#     DOES convert the value is RENDERED BACK and that text is the
#     pattern - `D STARTING WITH '01'` answers through "1", `D LIKE
#     '+1.5'` through "1.5", `D LIKE ' 1.5 '` likewise.  An EXPONENT-
#     bearing pattern is the exception and is recorded, not modelled:
#     the engine renders that one as a DOUBLE.
#
# WHAT THIS GATE DOES NOT CLAIM, and pins as divergence instead:
#   * THE VALUE of an e/E spelling.  `D = '1E+38'` answers NO ROWS on the
#     engine although a row holds 1.0E+38, because the quoted exponent
#     form goes through the DOUBLE literal law - the same law the
#     UNQUOTED `D = 1E+38` obeys, which this server already gets right.
#     This server converts the quoted one exactly and answers the row.
#     Pre-existing, identical on the previous binary, and out of scope:
#     it belongs to the double-literal law, not to this one.
#   * a literal written FIRST (`'inf' = D`) and an EXPRESSION side
#     (`D + 0 = 'inf'`), both of which this server refuses outright.
#   * NULLIF's second operand, which converts per row inside the
#     expression evaluator and so answers the prepare before raising.
#
# Usage: qa/serve-real-dfnflit.sh [port]   (default 4464)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4464}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfnflit-eng.fdb"; FC="$D/dfnflit-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"

# A DECFLOAT non-finite, unlike a DOUBLE one, IS writable in plain SQL -
# `CAST('Infinity' AS DECFLOAT(34))` is a value, not a conversion error -
# so the whole fixture goes in through isql and no bound-parameter loader
# is needed.
{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE M (ID INTEGER, D DECFLOAT(34), S DECFLOAT(16), DP DOUBLE PRECISION, T VARCHAR(20));
CREATE TABLE W (ID INTEGER, D DECFLOAT(34));
CREATE TABLE E (ID INTEGER, D DECFLOAT(34));
COMMIT;
INSERT INTO M VALUES (1, 1.5,     1.5,  1.5,  '1.5');
INSERT INTO M VALUES (2, 100,     100,  100,  '100');
INSERT INTO M VALUES (3, -2.5,   -2.5, -2.5,  '-2.5');
INSERT INTO M VALUES (4, 1.0E+38, 2.5,  1E38, '1e38');
INSERT INTO M VALUES (5, NULL,   NULL, NULL,  NULL);
INSERT INTO M VALUES (6, 0,        0,    0,   '0');
-- row 7 exists to DISCRIMINATE the exponent-bearing LIKE pattern: its
-- DECFLOAT rendering is exactly "1E+2", so a pattern re-rendered as a
-- DECFLOAT matches it and the engine's DOUBLE text ("100.000...") does
-- not.  Without it `D LIKE '1E2'` is "(none)" on both servers for two
-- different reasons, which is a cell that measures nothing.
INSERT INTO M VALUES (7, CAST('1E+2' AS DECFLOAT(34)), 7, 100, '1e2');
INSERT INTO W VALUES (1, 1.5);
INSERT INTO W VALUES (2, CAST('Infinity' AS DECFLOAT(34)));
INSERT INTO W VALUES (3, CAST('-Infinity' AS DECFLOAT(34)));
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/dfnflit-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/dfnflit-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/dfnflit-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/dfnflit-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-dfnflit-$PORT.log" 2>&1 & srv=$!
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
# BOTH raise the same vector and BOTH emitted a describe first - a
# PER-ROW raise, which is what the IN-list's padded elements produce and
# the deliberate opposite of `err_same`.  Requiring the describe is the
# point: it is what separates the two grammars.
err_row_same() {
    ran=$((ran + 1))
    local ee fe ed
    ee=$(err "127.0.0.1/$REAL:$ENG" "$2"); fe=$(err "127.0.0.1/$PORT:$FC" "$2")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2")
    if [ -z "$ee" ]; then echo "FAIL $1 - THE ENGINE NO LONGER RAISES"; fail=1
    elif [ -z "$fe" ]; then echo "FAIL $1 - this server did not raise"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 - the engine raised at PREPARE; this is an err_same cell now"; fail=1
    elif [ "$ee" != "$fe" ]; then
        echo "FAIL $1 (the VECTOR)"; echo "     eng=[$ee]"; echo "     fc =[$fe]"; fail=1
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
# both answer and they DISAGREE - both answers pinned, self-expiring
divergence() { # <label> <sql> <json> <engine-answer> <this-server-answer>
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" != "$4" ]; then echo "FAIL $1 - the ENGINE now answers [$ev], not [$4]"; fail=1
    elif [ "$fv" != "$5" ]; then echo "FAIL $1 - THIS SERVER now answers [$fv], not [$5] - if it matches the engine, promote the cell"; fail=1
    else echo "OK   $1 (recorded divergence: engine [$ev], this server [$fv])"; fi
}

# A SENTINEL BEFORE ANY CELL: six rows, and the two that decide the whole
# fixture - the 1.0E+38 row and the +Infinity row - really holding what
# they claim.  A cell that measures nothing looks exactly like one that
# passes, and a fixture that silently lost its wide row would make half
# of section 4 vacuous.
sent=$(run "$REAL" "$ENG" "SELECT (SELECT COUNT(*) FROM M) A,(SELECT COUNT(*) FROM W) B,(SELECT COUNT(*) FROM M WHERE CAST(D AS VARCHAR(45))='1.0E+38') C,(SELECT COUNT(*) FROM W WHERE CAST(D AS VARCHAR(45))='Infinity') F,(SELECT COUNT(*) FROM M WHERE CAST(D AS VARCHAR(45))='1E+2') G,(SELECT COUNT(*) FROM E) H FROM RDB\$DATABASE" '[]')
[ "$sent" = "7,3,1,1,1,0" ] || { echo "FAIL SENTINEL: the fixture is not what the cells assume [$sent] (want 7,3,1,1,1,0)"; exit 1; }
echo "OK   SENTINEL [$sent]"

echo "--- 1. THE BLANK RULE, no exponent: a blank is ignored wherever it stands"
both      "1 D = ' 1.5 '   - surrounding blanks trim"        "SELECT ID FROM M WHERE D = ' 1.5 ' ORDER BY ID"
both      "1 D = '  100  ' - and at any width"               "SELECT ID FROM M WHERE D = '  100  ' ORDER BY ID"
both      "1 D = '1 0 0'   - INTERIOR blanks too"            "SELECT ID FROM M WHERE D = '1 0 0' ORDER BY ID"
both      "1 D = '- 2.5'   - after the sign"                 "SELECT ID FROM M WHERE D = '- 2.5' ORDER BY ID"
both      "1 D = '+ 1.5'   - and after a plus"               "SELECT ID FROM M WHERE D = '+ 1.5' ORDER BY ID"
both      "1 D = '1 . 5'   - and round the dot"              "SELECT ID FROM M WHERE D = '1 . 5' ORDER BY ID"
both      "1 D = '1 0 0 '  - interior AND trailing"          "SELECT ID FROM M WHERE D = '1 0 0 ' ORDER BY ID"
both      "1 D = '1 5'     - it CONVERTS to 15 and matches nothing; it does NOT raise" "SELECT ID FROM M WHERE D = '1 5' ORDER BY ID"
both      "1 S = ' 1.5 '   - the same at DECFLOAT(16)"       "SELECT ID FROM M WHERE S = ' 1.5 ' ORDER BY ID"
both      "1 S = '1 0 0'   - interior, DECFLOAT(16)"         "SELECT ID FROM M WHERE S = '1 0 0' ORDER BY ID"
both      "1 CONTROL D = '1.5'"                              "SELECT ID FROM M WHERE D = '1.5' ORDER BY ID"
both      "1 CONTROL D = '1.50' - the cohort compares equal" "SELECT ID FROM M WHERE D = '1.50' ORDER BY ID"
both      "1 CONTROL D <= '-2.5'"                            "SELECT ID FROM M WHERE D <= '-2.5' ORDER BY ID"
both      "1 CONTROL D >= '0'"                               "SELECT ID FROM M WHERE D >= '0' ORDER BY ID"

echo "--- 2. WITH an e/E it is the DOUBLE grammar: ends trim, an interior blank refuses"
both      "2 D = ' 1.5e0 ' - the ends still trim"            "SELECT ID FROM M WHERE D = ' 1.5e0 ' ORDER BY ID"
both      "2 CONTROL D = '150e-2'"                           "SELECT ID FROM M WHERE D = '150e-2' ORDER BY ID"
err_same  "2 D = '1 e2'    - an INTERIOR blank refuses"      "SELECT ID FROM M WHERE D = '1 e2'"
err_same  "2 D = '1e 2'    - on either side of the e"        "SELECT ID FROM M WHERE D = '1e 2'"
err_same  "2 D = '1.5 e0'"                                   "SELECT ID FROM M WHERE D = '1.5 e0'"
err_same  "2 D = '1 . 5 e 0' - the lenient rule does NOT apply once there is an exponent" "SELECT ID FROM M WHERE D = '1 . 5 e 0'"

echo "--- 3. EVERY decNumber SPECIAL is rejected - the ONE-LINE 22018, at PREPARE"
err_same  "3 D = 'inf'"                                      "SELECT ID FROM M WHERE D = 'inf'"
err_same  "3 D = 'Infinity'"                                 "SELECT ID FROM M WHERE D = 'Infinity'"
err_same  "3 D = '+INF'"                                     "SELECT ID FROM M WHERE D = '+INF'"
err_same  "3 D = '-inf'"                                     "SELECT ID FROM M WHERE D = '-inf'"
err_same  "3 D = 'NaN'"                                      "SELECT ID FROM M WHERE D = 'NaN'"
err_same  "3 D = 'nan'"                                      "SELECT ID FROM M WHERE D = 'nan'"
err_same  "3 D = 'sNaN'"                                     "SELECT ID FROM M WHERE D = 'sNaN'"
err_same  "3 D = ' inf '   - trimming does not rescue it"    "SELECT ID FROM M WHERE D = ' inf '"
err_same  "3 D = 'i nf'    - nor does blank-skipping"        "SELECT ID FROM M WHERE D = 'i nf'"
err_same  "3 D < 'Infinity' - an ordering operator, same raise" "SELECT ID FROM M WHERE D < 'Infinity'"
err_same  "3 D <> 'inf'"                                     "SELECT ID FROM M WHERE D <> 'inf'"
err_same  "3 S = 'inf'     - DECFLOAT(16) raises the SAME one line" "SELECT ID FROM M WHERE S = 'inf'"
err_same  "3 S = 'NaN'"                                      "SELECT ID FROM M WHERE S = 'NaN'"
err_same  "3 D = 'Infinityx' - a near miss is ordinary junk" "SELECT ID FROM M WHERE D = 'Infinityx'"

echo "--- 4. junk, the empty string, and the exponent range"
err_same  "4 D = 'abc'"                                      "SELECT ID FROM M WHERE D = 'abc'"
err_same  "4 D = 'a b c'"                                    "SELECT ID FROM M WHERE D = 'a b c'"
err_same  "4 D = ''       - the empty string is not a zero"  "SELECT ID FROM M WHERE D = ''"
err_same  "4 D = '  '     - nor is a string of blanks"       "SELECT ID FROM M WHERE D = '  '"
err_same  "4 D = '1,5'    - the comma is not a decimal point here" "SELECT ID FROM M WHERE D = '1,5'"
err_same  "4 D = '0x1'    - and a DECFLOAT takes no hex"     "SELECT ID FROM M WHERE D = '0x1'"
err_same  "4 D = '1e7000' - 22003, a DIFFERENT vector"       "SELECT ID FROM M WHERE D = '1e7000'"
err_same  "4 S = '1e7000' - 22003 at DECFLOAT(16) too"       "SELECT ID FROM M WHERE S = '1e7000'"
err_same  "4 D = '1e6145' - the boundary: one past decimal128's emax" "SELECT ID FROM M WHERE D = '1e6145'"
both      "4 D = '1e6144' - ...and AT emax it prepares"      "SELECT ID FROM M WHERE D = '1e6144' ORDER BY ID"
both      "4 D = '1e-7000' - underflow CLAMPS to zero and answers the 0 row" "SELECT ID FROM M WHERE D = '1e-7000' ORDER BY ID"

echo "--- 5. THE RAISE IS AT PREPARE: no row is ever evaluated"
err_same  "5 1 = 0 AND D = 'inf' - a dead conjunct still raises" "SELECT ID FROM M WHERE 1 = 0 AND D = 'inf'"
err_same  "5 ID = 99 AND D = 'inf' - and so does an empty result" "SELECT ID FROM M WHERE ID = 99 AND D = 'inf'"
err_same  "5 ID = 5 AND D = 'inf' - even over the NULL-D row" "SELECT ID FROM M WHERE ID = 5 AND D = 'inf'"
err_same  "5 D = 'inf' OR ID = 1 - a hand-written OR raises (an IN-list does not: section 8)" "SELECT ID FROM M WHERE D = 'inf' OR ID = 1"
err_same  "5 D BETWEEN '0' AND 'inf' - a BETWEEN bound"      "SELECT ID FROM M WHERE D BETWEEN '0' AND 'inf'"
err_same  "5 D BETWEEN 'inf' AND '0' - either bound"         "SELECT ID FROM M WHERE D BETWEEN 'inf' AND '0'"

echo "--- 6. a LIKE / STARTING pattern takes the SAME conversion, then RENDERS BACK"
err_same  "6 D LIKE '1%'   - a wildcard is not a number"     "SELECT ID FROM M WHERE D LIKE '1%'"
err_same  "6 D LIKE '1_0'"                                   "SELECT ID FROM M WHERE D LIKE '1_0'"
err_same  "6 D LIKE '%E+38'"                                 "SELECT ID FROM M WHERE D LIKE '%E+38'"
err_same  "6 D NOT LIKE '1%' - negation does not excuse it"  "SELECT ID FROM M WHERE D NOT LIKE '1%'"
err_same  "6 D STARTING WITH '-' - a bare sign"              "SELECT ID FROM M WHERE D STARTING WITH '-'"
err_same  "6 S LIKE '2%'    - DECFLOAT(16) too"              "SELECT ID FROM M WHERE S LIKE '2%'"
err_same  "6 D LIKE 'inf'   - a special as a pattern"        "SELECT ID FROM M WHERE D LIKE 'inf'"
both      "6 D LIKE '1.5'   - it converts, so it matches"    "SELECT ID FROM M WHERE D LIKE '1.5' ORDER BY ID"
both      "6 D LIKE '1.50'  - ...and 1.50 renders '1.50', which matches NOTHING" "SELECT ID FROM M WHERE D LIKE '1.50' ORDER BY ID"
both      "6 D LIKE '+1.5'  - THE ROUND TRIP: the sign is normalised away" "SELECT ID FROM M WHERE D LIKE '+1.5' ORDER BY ID"
both      "6 D LIKE ' 1.5 ' - ...and the blanks with it"     "SELECT ID FROM M WHERE D LIKE ' 1.5 ' ORDER BY ID"
# ...BUT ONLY WITHOUT AN EXPONENT.  With one the engine renders the
# pattern as a DOUBLE ("1E2" becomes the text "100.0000000000000"), not
# as a DECFLOAT, so this server's DECFLOAT re-rendering finds the row
# whose own rendering is "1E+2" and the engine finds nothing.  Recorded,
# not modelled: the double text belongs to the double-literal law.
divergence "6 D LIKE '1E2' - the exponent pattern renders as a DOUBLE on the engine and as a DECFLOAT here" \
           "SELECT ID FROM M WHERE D LIKE '1E2' ORDER BY ID" '[]' "(none)" "7"
divergence "6 D LIKE '1E+2' - the same gap spelled with the sign" \
           "SELECT ID FROM M WHERE D LIKE '1E+2' ORDER BY ID" '[]' "(none)" "7"
both      "6 D LIKE '1 0 0' - the lenient blank rule reaches the pattern" "SELECT ID FROM M WHERE D LIKE '1 0 0' ORDER BY ID"
both      "6 D STARTING WITH '01' - THE CELL NO 'keep the text' RULE FITS: '01' renders '1'" "SELECT ID FROM M WHERE D STARTING WITH '01' ORDER BY ID"
both      "6 D STARTING WITH '1'"                            "SELECT ID FROM M WHERE D STARTING WITH '1' ORDER BY ID"
both      "6 D STARTING WITH '1 0'"                          "SELECT ID FROM M WHERE D STARTING WITH '1 0' ORDER BY ID"
both      "6 D STARTING WITH '100'"                          "SELECT ID FROM M WHERE D STARTING WITH '100' ORDER BY ID"

echo "--- 7. THE CAPPED SURFACE: a multi-element IN-list is a CHAR list, padded to its widest element"
# Nothing here is modelled from a rule - each cell is the engine's own
# answer, and the cap holds because the PADDING is visible in the error
# text: `D IN ('2.5','7')` names `"7  "`, two blanks wide, and
# `D IN ('-2.5','7')` names `"7   "`, three.
err_same  "7 D IN ('inf')   - ONE element is not a list: the ordinary literal's one-line vector" "SELECT ID FROM M WHERE D IN ('inf')"
err_same  "7 D NOT IN ('inf') - likewise negated"            "SELECT ID FROM M WHERE D NOT IN ('inf')"
both      "7 D IN ('1.5','inf') - nothing to pad (both 3 wide), so 'inf' is a decNumber Infinity and the 1.5 row answers" "SELECT ID FROM M WHERE D IN ('1.5','inf') ORDER BY ID"
both      "7 D IN ('inf','1.5') - and the order does not matter" "SELECT ID FROM M WHERE D IN ('inf','1.5') ORDER BY ID"
both      "7 D IN ('inf','100') - nor does which element matches" "SELECT ID FROM M WHERE D IN ('inf','100') ORDER BY ID"
err_row_same "7 D IN ('inf','9999') - 4 wide, so 'inf' becomes 'inf ' and the trailing blank is fatal" "SELECT ID FROM M WHERE D IN ('inf','9999')"
err_row_same "7 D IN ('2.5','7') - BOTH ELEMENTS ARE VALID NUMBERS and it still raises, on \"7  \"" "SELECT ID FROM M WHERE D IN ('2.5','7')"
err_row_same "7 D IN ('-2.5','7') - ...and a MATCHING element does not save it either" "SELECT ID FROM M WHERE D IN ('-2.5','7')"
both      "7 D IN ('2.5','100') - equal widths, so it answers"  "SELECT ID FROM M WHERE D IN ('2.5','100') ORDER BY ID"
err_row_same "7 D IN ('abc','1.5') - ordinary junk, the two-line compound" "SELECT ID FROM M WHERE D IN ('abc','1.5')"
err_row_same "7 D IN ('1.5','100000') - the padding lands on the FIRST element: \"1.5   \"" "SELECT ID FROM M WHERE D IN ('1.5','100000')"
err_row_same "7 D IN ('NaN','1.5') - the NaN CONVERTS and the COMPARISON raises: 22000, a different vector again" "SELECT ID FROM M WHERE D IN ('NaN','1.5')"
err_differs "7 D IN ('1.5000','1e7000') - equal widths, so the engine's OVERFLOW shows through; this server still spells it as a conversion error" \
            "SELECT ID FROM M WHERE D IN ('1.5000','1e7000')" "22003" "22018"
both      "7 D IN ('001.5','00100') - equal widths and both convert"  "SELECT ID FROM M WHERE D IN ('001.5','00100') ORDER BY ID"
both      "7 D IN (' 1.5 ') - a ONE-element list takes the blank-SKIPPING literal grammar" "SELECT ID FROM M WHERE D IN (' 1.5 ') ORDER BY ID"
err_row_same "7 S IN ('2.5','7') - the padding rule at DECFLOAT(16), where the PARAMETER path would have trimmed it" "SELECT ID FROM M WHERE S IN ('2.5','7')"
both      "7 S IN ('1.5','inf') - and DECFLOAT(16) answers when nothing is padded" "SELECT ID FROM M WHERE S IN ('1.5','inf') ORDER BY ID"
both      "7 ID = 3 AND D IN ('1.5','inf') - value-gated, unlike the literal path" "SELECT ID FROM M WHERE ID = 3 AND D IN ('1.5','inf') ORDER BY ID"

echo "--- 8. MUST NOT TOUCH: the OTHER two grammars, each measured green"
both      "8 D = ? ['inf']  - a bound TEXT parameter IS decNumber: it is a VALUE, and it matches nothing here" "SELECT ID FROM M WHERE D = ? ORDER BY ID" '["inf"]'
both      "8 D = ? ['1.5']  - the ordinary bind"             "SELECT ID FROM M WHERE D = ? ORDER BY ID" '["1.5"]'
both      "8 CAST('inf' AS DECFLOAT(34)) is a VALUE, not an error" "SELECT ID FROM W WHERE D = CAST('inf' AS DECFLOAT(34)) ORDER BY ID"
both      "8 CAST('-inf' AS DECFLOAT(34))"                   "SELECT ID FROM W WHERE D = CAST('-inf' AS DECFLOAT(34)) ORDER BY ID"
both      "8 CAST('inf' AS DECFLOAT(16))"                    "SELECT ID FROM W WHERE D = CAST('inf' AS DECFLOAT(16)) ORDER BY ID"
both      "8 the CAST renders 'Infinity', long and capitalised - NOT the DOUBLE's 'inf'" "SELECT CAST(CAST('inf' AS DECFLOAT(34)) AS VARCHAR(45)) A FROM RDB\$DATABASE"
err_differs "8 DP = 'inf' - the DOUBLE literal path is untouched: it REFUSES, on this binary and on the previous one alike" \
            "SELECT ID FROM M WHERE DP = 'inf'" "22018" "42000"
both      "8 CONTROL DP = '1.5' - ...and still answers an ordinary one" "SELECT ID FROM M WHERE DP = '1.5' ORDER BY ID"
both      "8 CONTROL T = 'inf' - a VARCHAR column has no conversion to fail" "SELECT ID FROM M WHERE T = 'inf' ORDER BY ID"
both      "8 CONTROL T LIKE '1%' - and its LIKE is a real pattern" "SELECT ID FROM M WHERE T LIKE '1%' ORDER BY ID"
# CASE and DECODE are their OWN routers and they do NOT raise - anything
# that refuses on "the literal is a special" without counting them breaks
# these two.
eng_only  "8 CASE D WHEN 'inf' - the engine does NOT raise here, it simply never matches; this server refuses the shape outright, on both binaries" "SELECT ID FROM M WHERE CASE D WHEN 'inf' THEN 1 ELSE 0 END = 1 ORDER BY ID"
eng_only  "8 CASE D WHEN '1.5' - ...and the same refusal swallows the matching half" "SELECT ID FROM M WHERE CASE D WHEN '1.5' THEN 1 ELSE 0 END = 1 ORDER BY ID"
eng_only  "8 DECODE(D,'inf',1,0) - DECODE is its own router and this server does not reach it either" "SELECT ID FROM M WHERE DECODE(D,'inf',1,0) = 1 ORDER BY ID"
both      "8 CONTROL an EMPTY table still raises at prepare - no row is needed" "SELECT ID FROM E WHERE ID > 0 ORDER BY ID"

echo "--- 9. RECORDED, NOT FIXED - each pinned so it fails loudly if it moves"
# The quoted e/E spelling goes through the DOUBLE literal law, which this
# chunk must not touch: the engine answers the UNQUOTED `D = 1E+38` and
# the quoted `D = '1E+38'` identically (no rows), while this server
# converts the quoted one as an EXACT decimal and finds the row. Both
# binaries do; it is not this chunk's regression, and fixing it means
# moving the quoted form onto the double path.
divergence "9 D = '1E+38' - the quoted exponent is the DOUBLE law, and this server converts it exactly" \
           "SELECT ID FROM M WHERE D = '1E+38' ORDER BY ID" '[]' "(none)" "4"
divergence "9 D > '1E+38' - the same gap, the other way round" \
           "SELECT ID FROM M WHERE D > '1E+38' ORDER BY ID" '[]' "4" "(none)"
both      "9 CONTROL D = 1E+38 - UNQUOTED, and this server already agrees" "SELECT ID FROM M WHERE D = 1E+38 ORDER BY ID"
err_differs "9 'inf' = D - a literal written FIRST: the engine converts it and raises, this server cannot parse the shape at all" \
            "SELECT ID FROM M WHERE 'inf' = D" "22018" "42000"
eng_only  "9 '1.5' = D - ...and it is not about the special" "SELECT ID FROM M WHERE '1.5' = D ORDER BY ID"
err_differs "9 D + 0 = 'inf' - an EXPRESSION side takes a different router, which this chunk did not reach" \
            "SELECT ID FROM M WHERE D + 0 = 'inf'" "22018" "42000"
eng_only  "9 D + 0 = ' 1.5 ' - the same router, the answering half"  "SELECT ID FROM M WHERE D + 0 = ' 1.5 ' ORDER BY ID"
# NULLIF converts inside the PER-ROW expression evaluator, so this server
# answers the prepare and raises later - the one in-scope router this
# chunk did not reach.  It is `serve-real-absround.sh`'s remaining red.
# NULLIF's second operand is the law's FOURTH router, and the only one
# that is an EXPRESSION rather than a Term - it resolves through TWO arms
# (`resolve_expr_inner` and `resolve_proj_expr`), and a grep for the
# per-row conversion it used to rely on finds neither of them.  A probe
# reported that NULLIF's two CONTEXTS use different grammars; re-measured,
# they do not - both raise the same one-line 22018 and both convert a
# blank-bearing spelling.  These cells carry both contexts.

echo "--- 9b. NULLIF, the fourth router - a BOOLEAN context and a SELECT-LIST one"
err_same  "9b NULLIF(D,'inf') IS NULL   - boolean context"   "SELECT ID FROM M WHERE NULLIF(D,'inf') IS NULL"
err_same  "9b NULLIF(D,'abc') IS NULL"                       "SELECT ID FROM M WHERE NULLIF(D,'abc') IS NULL"
err_same  "9b SELECT NULLIF(D,'inf')    - select-list context, the SAME vector" "SELECT CAST(NULLIF(D,'inf') AS VARCHAR(20)) A FROM M WHERE ID = 1"
err_same  "9b SELECT NULLIF(D,'abc')"                        "SELECT CAST(NULLIF(D,'abc') AS VARCHAR(20)) A FROM M WHERE ID = 1"
err_same  "9b SELECT NULLIF(S,'inf')    - and at DECFLOAT(16)" "SELECT CAST(NULLIF(S,'inf') AS VARCHAR(20)) A FROM M WHERE ID = 1"
both      "9b NULLIF(D,' 1.5 ') IS NULL - the blank rule reaches NULLIF too" "SELECT ID FROM M WHERE NULLIF(D,' 1.5 ') IS NULL ORDER BY ID"
both      "9b NULLIF(D,'1 0 0') IS NULL - interior blanks as well" "SELECT ID FROM M WHERE NULLIF(D,'1 0 0') IS NULL ORDER BY ID"
both      "9b NULLIF(S,' 1.5 ') IS NULL - at DECFLOAT(16)"   "SELECT ID FROM M WHERE NULLIF(S,' 1.5 ') IS NULL ORDER BY ID"
both      "9b CONTROL NULLIF(D,'1.5') IS NULL"               "SELECT ID FROM M WHERE NULLIF(D,'1.5') IS NULL ORDER BY ID"
both      "9b SELECT NULLIF(D,' 1.5 ') - the select-list half answers too, where the previous binary raised" "SELECT CAST(NULLIF(D,' 1.5 ') AS VARCHAR(20)) A FROM M WHERE ID = 1"
both      "9b CONTROL NULLIF over a TEXT column is untouched" "SELECT NULLIF(T,'1.5') A FROM M WHERE ID = 1"
both      "9b CONTROL NULLIF over an INTEGER column is untouched" "SELECT NULLIF(ID,1) A FROM M WHERE ID = 1"
both      "9b CONTROL NULLIF over a DOUBLE column is untouched" "SELECT NULLIF(DP,1.5) A FROM M WHERE ID = 1"

echo "--- 10. THE ROW-MUTATING PAIR, and it runs LAST because a regression here CORRUPTS THE FIXTURE"
# On the previous binary the DELETE really did remove the +Infinity row,
# and every later cell that reads W then measured a mutilated table - the
# two CAST controls in section 8 went red for that reason alone and not
# for anything to do with CAST.  Running the pair last means a future
# regression shows up HERE, in one cell, instead of as a cascade of
# unrelated reds.
err_same  "10 DELETE FROM W WHERE D = 'inf' - THE SEVEREST CELL IN THE CHUNK: this server used to delete the +Infinity row" "DELETE FROM W WHERE D = 'inf'"
both      "10 W still holds all three rows"               "SELECT ID FROM W ORDER BY ID"
err_same  "10 UPDATE W SET ID = 77 WHERE D = 'inf' - its sister" "UPDATE W SET ID = 77 WHERE D = 'inf'"
both      "10 ...and no row was renumbered either"        "SELECT ID FROM W ORDER BY ID"
both      "10 W WHERE D = ' 1.5 ' - the blank rule holds on this table too, and here it must NOT raise" "SELECT ID FROM W WHERE D = ' 1.5 ' ORDER BY ID"

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-dfnflit-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-dfnflit-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

# A COUNTED FLOOR, from a measured run: a cell that silently stops running
# reads exactly like one that passes.
echo "ran $ran checks"
if [ "$ran" -lt 127 ]; then echo "FAIL only $ran checks ran (floor 127) - cells went missing"; fail=1; fi
exit $fail
