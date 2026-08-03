#!/bin/bash
# A TEXT COLUMN against a NUMERIC side: the engine coerces the COLUMN's
# text to a number PER ROW (cvt2.cpp cmp_numeric_string -> cvt.cpp
# CVT_get_numeric) - so `S = 5` matches '5', ' 5', '5.0', '05', '+5',
# '5e0' and '  5  ' alike - and raises 22018 MID-SCAN, value-gated, on
# a row that will not convert. Twin databases, one driver, two servers;
# every row-set and every error MESSAGE (the 22018 argument is the raw,
# CHAR-padded value) compared exactly.
#
# The laws under test, each probed against the engine first:
#
#   1. The compare grammar is LENIENT - NOT the store/literal grammar:
#      interior spaces convert ('1 0' = 10, '1 2 3' = 123, '- 5' = -5),
#      one sign before digits, one dot; an e/E hands the WHOLE string
#      to the stricter double grammar ('1e3' converts, '1 e 3' and
#      '1e 3' raise).
#   2. The comparison is EXACT, not double: the two BIGINTs ...806 and
#      ...807 pick different rows, '...806.5' sits strictly between,
#      a 39-digit spelling stays exact while a 40-digit one rounds to
#      34 significant digits (the dec128 collapse).
#   3. The raise is VALUE-GATED and rides the conjunct machinery: NULL
#      rows and empty tables are silent, a dead `1=0 AND` kills it, an
#      INDEXED protecting conjunct excludes the bad row in EITHER
#      order, non-indexed conjuncts short-circuit in WRITTEN order, OR
#      is left-to-right, FIRST 1 stops before a later bad row, and a
#      raising UPDATE/DELETE leaves rows UNTOUCHED (read back on a
#      fresh attachment).
#   4. The rule spans literal-on-either-side, BETWEEN/IN, IS DISTINCT
#      FROM, text col vs INTEGER col, text col vs DOUBLE col, joins,
#      HAVING over text group keys (per group, NULL group silent),
#      numeric parameters (a JS boolean arrives as blr_long 1/0 and
#      raises from the first non-NULL row), and `S = TRUE` (per-row
#      trimmed TRUE/FALSE, '1' raises).
#   5. With an INDEX on S, `S = 5` still scans NATURAL and answers the
#      class; `S = '5'` PLANs the index and answers only '5' -
#      text-vs-text never coerces.
#   6. Capital-X hex ('0X10') reads UNINITIALIZED MEMORY in the live
#      engine (~1.9e25, different per string): only the equality-miss
#      (`= 16` answers [], no raise) is pinned, never the ordering.
#   7. The 22018 ARGUMENT is ESCAPED on the way into the status vector:
#      `#x` + two lowercase hex digits for every byte outside
#      0x20..0x7f, PER BYTE - and no other vector escapes (the 23000
#      key value carries the raw one).
#
#   qa/serve-real-textcolcmp.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4581}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-textcolcmp-crab.fdb"
B="$D/fc-textcolcmp-engine.fdb"

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# The fixture. TCLEAN carries the `= 5` equivalence class (ids 1-7,12)
# beside neighbours for the other five ops; TDIRTY is the raise-timing
# table (a NULL row and an 'abc' row behind an indexed PK); TBAD puts
# the bad row physically FIRST; TPAIR is text-vs-INTEGER-column;
# TDBL text-vs-DOUBLE-column; TIDX carries an INDEX on S; TB the
# boolean spellings (with a NULL row); TCH a CHAR(6) whose raise
# argument must keep its padding; TG one grammar spelling per PK; TBIG
# the two i64-rim BIGINT spellings. TCTL is the unprintable-byte table -
# one CLEAN row here, its control-byte row seeded through both servers
# below (no shell heredoc carries those bytes into isql intact) - and
# TCTLK the text PRIMARY KEY whose 23000 vector must NOT escape.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE TCLEAN (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(30));
CREATE TABLE TDIRTY (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(20));
CREATE TABLE TBAD   (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(20));
CREATE TABLE TPAIR  (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(10));
CREATE TABLE TNULL  (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(10));
CREATE TABLE TEMPTY (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(10));
CREATE TABLE TIDX   (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(10));
CREATE INDEX IDX_TIDX_S ON TIDX(S);
CREATE TABLE TB     (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(10));
CREATE TABLE TCH    (ID INTEGER NOT NULL PRIMARY KEY, C CHAR(6));
CREATE TABLE TDBL   (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(10), D DOUBLE PRECISION);
CREATE TABLE TG     (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(45));
CREATE TABLE TBIG   (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(25));
CREATE TABLE TCTL   (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER,
                     S VARCHAR(20), C CHAR(6),
                     U VARCHAR(20) CHARACTER SET UTF8);
CREATE TABLE TCTLK  (S VARCHAR(20) NOT NULL PRIMARY KEY);
COMMIT;
INSERT INTO TCLEAN VALUES (1, '5');
INSERT INTO TCLEAN VALUES (2, ' 5');
INSERT INTO TCLEAN VALUES (3, '5.0');
INSERT INTO TCLEAN VALUES (4, '05');
INSERT INTO TCLEAN VALUES (5, '+5');
INSERT INTO TCLEAN VALUES (6, '5e0');
INSERT INTO TCLEAN VALUES (7, '0.5e1');
INSERT INTO TCLEAN VALUES (8, '10');
INSERT INTO TCLEAN VALUES (9, '4.5');
INSERT INTO TCLEAN VALUES (10, '6');
INSERT INTO TCLEAN VALUES (11, '1');
INSERT INTO TCLEAN VALUES (12, '  5  ');
INSERT INTO TCLEAN VALUES (13, '9');
INSERT INTO TCLEAN VALUES (14, '1 0');
INSERT INTO TCLEAN VALUES (15, '5.5');
INSERT INTO TCLEAN VALUES (16, '2.5');
INSERT INTO TDIRTY VALUES (1, '5');
INSERT INTO TDIRTY VALUES (2, NULL);
INSERT INTO TDIRTY VALUES (3, 'abc');
INSERT INTO TDIRTY VALUES (4, '05');
INSERT INTO TBAD VALUES (1, 'abc');
INSERT INTO TBAD VALUES (2, '5');
INSERT INTO TPAIR VALUES (1, '1');
INSERT INTO TPAIR VALUES (2, '02');
INSERT INTO TPAIR VALUES (3, 'x3');
INSERT INTO TPAIR VALUES (4, '4');
INSERT INTO TNULL VALUES (1, '5');
INSERT INTO TNULL VALUES (2, NULL);
INSERT INTO TNULL VALUES (3, '6');
INSERT INTO TIDX VALUES (1, '5');
INSERT INTO TIDX VALUES (2, '05');
INSERT INTO TIDX VALUES (3, '6');
INSERT INTO TB VALUES (1, 'true');
INSERT INTO TB VALUES (2, 'FALSE');
INSERT INTO TB VALUES (3, ' True ');
INSERT INTO TB VALUES (4, '1');
INSERT INTO TB VALUES (5, NULL);
INSERT INTO TCH VALUES (1, '5');
INSERT INTO TCH VALUES (2, '05');
INSERT INTO TCH VALUES (3, 'abc');
INSERT INTO TDBL VALUES (1, '2.50', 2.5);
INSERT INTO TDBL VALUES (2, '2.5', 2.5);
INSERT INTO TDBL VALUES (3, '3', 2.5);
INSERT INTO TG VALUES (1, '1e3');
INSERT INTO TG VALUES (2, '1E3');
INSERT INTO TG VALUES (3, '1e-3');
INSERT INTO TG VALUES (4, '1.5e2');
INSERT INTO TG VALUES (5, '+.5');
INSERT INTO TG VALUES (6, '.5');
INSERT INTO TG VALUES (7, '5.');
INSERT INTO TG VALUES (8, '1 2 3');
INSERT INTO TG VALUES (9, '- 5');
INSERT INTO TG VALUES (10, '5 . 0');
INSERT INTO TG VALUES (11, '');
INSERT INTO TG VALUES (12, '   ');
INSERT INTO TG VALUES (13, 'abc');
INSERT INTO TG VALUES (14, '0x10');
INSERT INTO TG VALUES (15, 'inf');
INSERT INTO TG VALUES (16, 'NaN');
INSERT INTO TG VALUES (17, '1,5');
INSERT INTO TG VALUES (18, '5.5.5');
INSERT INTO TG VALUES (19, '--5');
INSERT INTO TG VALUES (20, '.');
INSERT INTO TG VALUES (21, '1 e 3');
INSERT INTO TG VALUES (22, '1e 3');
INSERT INTO TG VALUES (23, '1e400');
INSERT INTO TG VALUES (24, '9223372036854775806.5');
INSERT INTO TG VALUES (25, '0.10000000000000001');
INSERT INTO TG VALUES (26, '1.0000000000000000000000000000000000001');
INSERT INTO TG VALUES (27, '1.00000000000000000000000000000000000001');
INSERT INTO TG VALUES (28, '0X10');
INSERT INTO TBIG VALUES (1, '9223372036854775806');
INSERT INTO TBIG VALUES (2, '9223372036854775807');
INSERT INTO TCTL VALUES (1, 2, '5', '5', '5');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-textcolcmp.log 2>&1 &
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

# Every call is its OWN attachment (node-firebird auto-commits), which
# is exactly what the durable-DML section needs: the read-back after a
# raising UPDATE runs on a FRESH attachment by construction.
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
              // 200, not 80: the 23000 key value sits at column 108 of
              // its message, and its RAW byte is under test below
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,200));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql> [json args] - row sets AND error messages
    # (the 22018 argument text included) must be identical
    a=$(query "$2" "${3:-[]}" "$PORT" "$A")
    b=$(query "$2" "${3:-[]}" "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
clean() { both "$1" "SELECT ID FROM TCLEAN WHERE $2 ORDER BY ID"; }
dirty() { both "$1" "SELECT ID FROM TDIRTY WHERE $2"; }

# --- 1. the equivalence class, all six ops, both orientations ----------
clean "S = 5 answers the whole class" "S = 5"
clean "S <> 5" "S <> 5"
clean "S < 5" "S < 5"
clean "S <= 5" "S <= 5"
clean "S > 5" "S > 5"
clean "S >= 5" "S >= 5"
clean "5 = S (literal left)" "5 = S"
clean "BETWEEN 4 AND 6" "S BETWEEN 4 AND 6"
clean "IN (5, 9)" "S IN (5, 9)"
clean "S = 10 takes '1 0' AND '10'" "S = 10"
clean "S = 2.5 (decimal literal)" "S = 2.5"
clean "S = 5e0 (double literal)" "S = 5e0"
clean "text vs text never coerces" "S = '5.0'"

# --- 2. the compare grammar, one spelling per PK -----------------------
g() { both "$1" "SELECT ID FROM TG WHERE ID = $2 AND S = $3"; }
g "'1e3' = 1000" 1 1000
g "'1E3' = 1000" 2 1000
g "'1e-3' = 0.001" 3 0.001
g "'1.5e2' = 150" 4 150
g "'+.5' = 0.5" 5 0.5
g "'.5' = 0.5" 6 0.5
g "'5.' = 5" 7 5
g "'1 2 3' = 123 (interior spaces)" 8 123
g "'- 5' = -5" 9 -5
g "'5 . 0' = 5" 10 5
# the raisers, with the EXACT 22018 argument text compared
g "'' raises" 11 0
g "'   ' raises" 12 0
g "'abc' raises" 13 0
g "lowercase '0x10' raises" 14 0
g "'inf' raises" 15 0
g "'NaN' raises" 16 0
g "'1,5' raises" 17 0
g "'5.5.5' raises" 18 0
g "'--5' raises" 19 0
g "'.' raises" 20 0
g "'1 e 3' raises (double grammar)" 21 0
g "'1e 3' raises (double grammar)" 22 0

# --- 3. precision pins: exact, not double ------------------------------
both "'...806' picks ITS row" "SELECT ID FROM TBIG WHERE S = 9223372036854775806"
both "'...807' picks the OTHER row" "SELECT ID FROM TBIG WHERE S = 9223372036854775807"
both "'...806' > splits the pair" "SELECT ID FROM TBIG WHERE S > 9223372036854775806"
both "'...806.5' sits strictly BETWEEN" \
     "SELECT ID FROM TG WHERE ID = 24 AND S > 9223372036854775806 AND S < 9223372036854775807"
both "17 digits != 0.1" "SELECT ID FROM TG WHERE ID = 25 AND S = 0.1"
both "17 digits = its own spelling" \
     "SELECT ID FROM TG WHERE ID = 25 AND S = 0.10000000000000001"
both "39 digits stay exact (!= 1)" "SELECT ID FROM TG WHERE ID = 26 AND S = 1"
both "40 digits round to 34 (= 1)" "SELECT ID FROM TG WHERE ID = 27 AND S = 1"
both "'1e400' > 1e300 (dec128 magnitude)" "SELECT ID FROM TG WHERE ID = 23 AND S > 1e300"

# --- 4. raise-timing: the conjunct machinery ---------------------------
dirty "unprotected scan raises from 'abc'" "S = 5"
dirty "dead conjunct first: no raise" "1 = 0 AND S = 5"
dirty "dead conjunct second: no raise" "S = 5 AND 1 = 0"
dirty "indexed protection first" "ID < 3 AND S = 5"
dirty "indexed protection second (retrieval excludes)" "S = 5 AND ID < 3"
dirty "non-indexed gate first: written order answers" "ID + 0 < 3 AND S = 5"
dirty "non-indexed gate second: written order raises" "S = 5 AND ID + 0 < 3"
both "OR left-to-right: TRUE alternative short-circuits" \
     "SELECT ID FROM TDIRTY WHERE ID = 3 OR S = 5 ORDER BY ID"
both "OR reversed: the raiser evaluates first" \
     "SELECT ID FROM TDIRTY WHERE S = 5 OR ID = 3 ORDER BY ID"
both "FIRST 1 stops before the bad row" "SELECT FIRST 1 ID FROM TDIRTY WHERE S = 5"
both "IN raises through its desugar" "SELECT ID FROM TDIRTY WHERE S IN (5, 9)"
both "a bad row physically FIRST raises" "SELECT ID FROM TBAD WHERE S = 5"
both "empty table: no raise" "SELECT ID FROM TEMPTY WHERE S = 5"

# --- 5. NULL gates -----------------------------------------------------
both "NULL row is UNKNOWN, no raise" "SELECT ID FROM TNULL WHERE S = 5 ORDER BY ID"
both "NULL under <>" "SELECT ID FROM TNULL WHERE S <> 5 ORDER BY ID"
both "IS DISTINCT FROM keeps the NULL row" \
     "SELECT ID FROM TNULL WHERE S IS DISTINCT FROM 5 ORDER BY ID"
both "HAVING's NULL group is silent" \
     "SELECT S FROM TNULL GROUP BY S HAVING S = 5 ORDER BY S"

# --- 6. text column vs INTEGER / DOUBLE column, and a join -------------
both "NAME = ID raises on 'x3'" "SELECT ID FROM TPAIR WHERE NAME = ID ORDER BY ID"
both "protected NAME = ID matches '02' against 2" \
     "SELECT ID FROM TPAIR WHERE ID < 3 AND NAME = ID ORDER BY ID"
both "text col vs DOUBLE col: the double domain" \
     "SELECT ID FROM TDBL WHERE S = D ORDER BY ID"
both "join ON A.S = B.ID raises on 'abc'" \
     "SELECT A.ID AID FROM TDIRTY A JOIN TPAIR B ON A.S = B.ID"

# --- 7. HAVING over text group keys ------------------------------------
both "HAVING S = 5 answers every class group" \
     "SELECT S FROM TCLEAN GROUP BY S HAVING S = 5 ORDER BY S"
both "HAVING raises from the 'abc' group" \
     "SELECT S FROM TDIRTY GROUP BY S HAVING S = 5"

# --- 8. an INDEX on S never serves a numeric compare -------------------
both "indexed S = 5 scans NATURAL, answers the class" \
     "SELECT ID FROM TIDX WHERE S = 5 ORDER BY ID"
both "indexed S = '5' keys the index, answers ONLY '5'" \
     "SELECT ID FROM TIDX WHERE S = '5' ORDER BY ID"

# --- 9. parameters: the wire value decides -----------------------------
both "S = ? bound 5: the class" "SELECT ID FROM TCLEAN WHERE S = ? ORDER BY ID" "[5]"
both "S > ? bound 5" "SELECT ID FROM TCLEAN WHERE S > ? ORDER BY ID" "[5]"
both "S = ? bound 4.5 (blr_double)" "SELECT ID FROM TCLEAN WHERE S = ? ORDER BY ID" "[4.5]"
both "S = ? bound '5' stays the text compare" \
     "SELECT ID FROM TCLEAN WHERE S = ? ORDER BY ID" '["5"]'
both "S = ? bound true arrives as blr_long 1: raises from 'true'" \
     "SELECT ID FROM TB WHERE ID < 4 AND S = ? ORDER BY ID" "[true]"
both "S = ? bound false raises identically" \
     "SELECT ID FROM TB WHERE ID < 4 AND S = ? ORDER BY ID" "[false]"
both "S = ? bound 5 raises over the dirty table" \
     "SELECT ID FROM TDIRTY WHERE S = ? ORDER BY ID" "[5]"

# --- 11. boolean literals: per-row TRUE/FALSE --------------------------
both "protected S = TRUE answers the spellings" \
     "SELECT ID FROM TB WHERE ID < 4 AND S = TRUE ORDER BY ID"
both "protected S = FALSE" "SELECT ID FROM TB WHERE ID < 4 AND S = FALSE ORDER BY ID"
both "S = TRUE raises from '1'" "SELECT ID FROM TB WHERE S = TRUE ORDER BY ID"
both "NULL row is silent under S = TRUE" \
     "SELECT ID FROM TB WHERE ID <> 4 AND S = TRUE ORDER BY ID"
both "TNULL S = TRUE raises from '5'" "SELECT ID FROM TNULL WHERE S = TRUE ORDER BY ID"

# --- 12. CHAR keeps its padding in the raise argument ------------------
both "protected CHAR class" "SELECT ID FROM TCH WHERE ID < 3 AND C = 5 ORDER BY ID"
both "CHAR raise argument is padded 'abc   '" "SELECT ID FROM TCH WHERE C = 5 ORDER BY ID"

# --- 13. capital-X hex: equality-miss only -----------------------------
# The live engine reads uninitialized memory for the value (probed
# ~1.9e25, different per string): `= 16` answering [] with NO raise is
# the one pinnable fact - never pin its ordering.
both "'0X10' = 16 answers [] with no raise" \
     "SELECT ID FROM TG WHERE ID = 28 AND S = 16"

# --- 15. the 22018 ARGUMENT escapes the unprintable bytes --------------
# The engine renders the offending text before it reaches the status
# vector (CVT_conversion_error): every byte it will not print travels as
# `#x` + TWO LOWERCASE hex digits, so `N = '<TAB>2'` names "#x092" - the
# escape, then the literal '2'. Probed byte by byte against the live
# engine, literal side and column side, at the start, in the middle and
# at the end of the text:
#   - 0x00-0x1f and 0x80-0xff escape; 0x20-0x7e travel raw (a CHAR's
#     padding stays blanks) and so does 0x7f (DEL), alone above the band;
#   - the escape is PER BYTE, not per character: a UTF-8 'e' with an
#     acute prints "#xc3#xa9", the euro sign "#xe2#x82#xac";
#   - and it belongs to THIS vector ONLY - the 23000 key value
#     (print_key) carries the raw byte on the engine's own wire.
#
# EXCLUDED: a RAW high byte in the SQL text (0x80-0xff outside UTF-8) -
# fc decodes the statement text as UTF-8 and replaces it with U+FFFD, so
# its argument reads "#xef#xbf#xbd" where the engine's reads "#x80"; a
# text-DECODING residual, not an escaping one. And NUL, which no shell
# variable carries.
TAB=$'\t'; LF=$'\n'; CR=$'\r'; VT=$'\v'; FF=$'\f'
SOH=$'\001'; US=$'\037'; ESC=$'\033'; DEL=$'\177'
EACUTE=$'\xc3\xa9'; EURO=$'\xe2\x82\xac'
lit() { both "$1" "SELECT ID FROM TCTL WHERE N = '$2'"; }
both "the control-byte row, seeded through both servers" \
     "INSERT INTO TCTL VALUES (2, NULL, '${TAB}x', '${TAB}a', '${EACUTE}9')"
lit "a TAB before the digit is #x09" "${TAB}2"
lit "... in the MIDDLE of the text" "2${TAB}2"
lit "... and at the END of it" "2${TAB}"
lit "LF" "${LF}2"
lit "CR" "${CR}2"
lit "VT" "${VT}2"
lit "FF" "${FF}2"
lit "0x01, the bottom of the escaped band" "${SOH}2"
lit "0x1f, the top of it" "${US}2"
lit "ESC 0x1b" "${ESC}2"
lit "two escapes run together" "${TAB}${TAB}2"
lit "DEL 0x7f travels RAW" "${DEL}2"
lit "'!' 0x21 raw, the printable band's floor" "!2"
lit "'~' 0x7e raw, its ceiling" "~2"
lit "an e-acute escapes PER BYTE" "${EACUTE}2"
lit "the euro sign, three bytes, three escapes" "${EURO}2"
both "a TAB in the COLUMN value, mid-scan" "SELECT ID FROM TCTL WHERE S = 5"
both "... a CHAR column keeps its padding beside it" \
     "SELECT ID FROM TCTL WHERE C = 5"
both "... a UTF8 column escapes per byte too" "SELECT ID FROM TCTL WHERE U = 5"
both "... and a numeric PARAMETER raises the same argument" \
     "SELECT ID FROM TCTL WHERE S = ?" "[5]"
both "the text key, seeded" "INSERT INTO TCTLK VALUES ('${TAB}a')"
both "the 23000 key value does NOT escape it" \
     "INSERT INTO TCTLK VALUES ('${TAB}a')"

# --- 10. durable DML atomicity (LAST: it mutates) ----------------------
both "raising UPDATE errors on both" "UPDATE TDIRTY SET S = '9' WHERE S = 5"
both "raising DELETE errors on both" "DELETE FROM TDIRTY WHERE S = 5"
both "raising bound UPDATE errors on both" "UPDATE TDIRTY SET S = '9' WHERE S = ?" "[5]"
both "rows UNTOUCHED after the raising DML (fresh attachment)" \
     "SELECT ID, S FROM TDIRTY ORDER BY ID"
both "a protected UPDATE succeeds" "UPDATE TDIRTY SET S = '6' WHERE ID < 3 AND S = 5"
both "the protected write IS durable (fresh attachment)" \
     "SELECT ID, S FROM TDIRTY ORDER BY ID"
both "bound UPDATE over the clean table" "UPDATE TCLEAN SET S = '5' WHERE S = ?" "[5]"
both "the class collapsed to '5' (fresh attachment)" \
     "SELECT ID, S FROM TCLEAN ORDER BY ID"

# --- 14. the ran counter -----------------------------------------------
if [ "$ran" -ne 115 ]; then
    echo "DIFF $ran checks ran (expected exactly 115) - did one silently skip?"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$A" "$B"
exit $fail
