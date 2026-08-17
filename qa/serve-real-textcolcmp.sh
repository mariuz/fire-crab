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
#   1. The compare grammar is LENIENT - NOT the store/CAST grammar:
#      interior spaces convert ('1 0' = 10, '1 2 3' = 123, '- 5' = -5),
#      one sign before digits, one dot; an e/E hands the WHOLE string
#      to the stricter double grammar ('1e3' converts, '1 e 3' and
#      '1e 3' raise). It reads the LITERAL side too (law 10) - on the
#      COLUMN side unconditionally, on the literal side wherever no
#      index makes the engine build a key.
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
#   8. The CAST/store grammar skips 0x20 SPACE and NOTHING ELSE at
#      either end: TAB, LF, VT, FF, CR - and the Unicode blanks NBSP,
#      EM SPACE, IDEOGRAPHIC SPACE, NEL - all raise 22018 there, for
#      every numeric target and at BOTH ends. It is the third grammar
#      in this file and it does NOT follow the compare side: '1 0' is
#      10 to a comparison and a conversion error to a CAST, ONE value
#      answering two ways in one statement pair.
#   9. A CONVERSION CAP that is not a grammar at all: the engine moves
#      a text source into the TARGET's fixed buffer before reading a
#      character of it, so a source longer than that buffer is 22001
#      *string right truncation* whatever it spells. 22 bytes for the
#      16-bit routine (SMALLINT, NUMERIC(p<=4)), 52 for the 32/64-bit
#      one (INTEGER, BIGINT, NUMERIC/DECIMAL 5..18 - and DECIMAL(4,0),
#      which is a LONG where NUMERIC(4,0) is a SHORT), 130 for the
#      double and temporal ones, and NO cap on the INT128 path.
#      Trailing blanks drop BEFORE the test and count INTO the reported
#      `actual`; the count is BYTES; and the comparison vector has no
#      cap at all.
#  10. ONE LITERAL, TWO GRAMMARS, THE INDEX DECIDING. The literal side
#      of a comparison is converted twice: the per-row compare takes
#      the LENIENT grammar (`N = '1 2'` answers the 12 row, `'5 . 0'`
#      the 5 row, on an INTEGER, a NUMERIC and through a bound
#      parameter alike) and the optimizer's key build takes the STRICT
#      one, so the SAME statement over an INDEXED column raises 22018 -
#      TNI and TNIX differ only by that index. An expression side is
#      never keyed and only ever converts leniently. The gate's
#      omissions are deliberate and both measured: a MULTI-VALUE `IN`
#      converts its list strictly (fire-crab refuses those spellings
#      rather than answer the OR's rows), and a DOUBLE column's literal
#      side still refuses here.
#  11. A THIRD SITE FOR THE STRICT GRAMMAR: A SEMI-JOIN'S HASH KEY. The
#      engine turns a POSITIVE `IN (<subquery>)` / `= ANY` / correlated
#      `EXISTS` written as a TOP-LEVEL CONJUNCT into a semi-join (`SET
#      PLANONLY ON` says HASH) and converts its keys as it builds the
#      hash table - strictly, so a value that came out of a COLUMN and
#      that only the lenient grammar takes raises 22018 where the same
#      value SPELLED AS A LITERAL answers. Everything the engine does
#      not hash keeps the lenient compare: the same IN under an OR or a
#      NOT, `NOT IN`, `NOT EXISTS`, `= ALL`, and a SCALAR subquery. The
#      raise is not value-gated - it is the BUILD that fails, so an
#      outer table holding only a NULL raises while an EMPTY outer
#      raises nothing, and one bad key sinks a list whose other keys
#      convert and match. Two shapes fire-crab still answers where the
#      engine hashes are RECORDED, not fixed, at the end of section 19.
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
# TCAST is the CAST-grammar table (law 8): every blank byte the ENGINE
# refuses, spelled with ASCII_CHAR so the byte is built INSIDE the
# engine and no shell or isql rewrite can touch it; TCN the numeric
# columns the store and literal vectors write and read.
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
CREATE TABLE TCAST  (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(30));
CREATE TABLE TCN    (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER,
                     Q NUMERIC(9,2), D DOUBLE PRECISION);
CREATE TABLE TNI    (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, Q NUMERIC(9,2));
CREATE TABLE TNIX   (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, Q NUMERIC(9,2));
CREATE INDEX IDX_TNIX_N ON TNIX(N);
CREATE INDEX IDX_TNIX_Q ON TNIX(Q);
CREATE TABLE TLONG  (ID INTEGER NOT NULL PRIMARY KEY, S VARCHAR(210),
                     U VARCHAR(100) CHARACTER SET UTF8);
CREATE TABLE TK     (S VARCHAR(20));
CREATE TABLE TKOK   (S VARCHAR(20));
CREATE TABLE TKMIX  (S VARCHAR(20));
CREATE TABLE TKNUL  (N INTEGER);
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
INSERT INTO TCAST VALUES (1,  ASCII_CHAR(9) || '2');
INSERT INTO TCAST VALUES (2,  '2' || ASCII_CHAR(9));
INSERT INTO TCAST VALUES (3,  ASCII_CHAR(10) || '2');
INSERT INTO TCAST VALUES (4,  '2' || ASCII_CHAR(10));
INSERT INTO TCAST VALUES (5,  ASCII_CHAR(11) || '2');
INSERT INTO TCAST VALUES (6,  '2' || ASCII_CHAR(11));
INSERT INTO TCAST VALUES (7,  ASCII_CHAR(12) || '2');
INSERT INTO TCAST VALUES (8,  '2' || ASCII_CHAR(12));
INSERT INTO TCAST VALUES (9,  ASCII_CHAR(13) || '2');
INSERT INTO TCAST VALUES (10, '2' || ASCII_CHAR(13));
INSERT INTO TCAST VALUES (11, ASCII_CHAR(9) || ASCII_CHAR(9) || '2');
INSERT INTO TCAST VALUES (12, '2' || ASCII_CHAR(9) || ASCII_CHAR(9));
INSERT INTO TCAST VALUES (13, '  2  ');
INSERT INTO TCAST VALUES (14, ' 2.5 ');
INSERT INTO TCAST VALUES (15, ASCII_CHAR(194) || ASCII_CHAR(160) || '2');
INSERT INTO TCAST VALUES (16, ASCII_CHAR(226) || ASCII_CHAR(128) || ASCII_CHAR(131) || '2');
INSERT INTO TCAST VALUES (17, ASCII_CHAR(227) || ASCII_CHAR(128) || ASCII_CHAR(128) || '2');
INSERT INTO TCAST VALUES (18, ASCII_CHAR(194) || ASCII_CHAR(133) || '2');
INSERT INTO TCAST VALUES (19, '2' || ASCII_CHAR(194) || ASCII_CHAR(160));
INSERT INTO TCAST VALUES (20, '1 0');
INSERT INTO TCN VALUES (1, 2, 2.00, 2);
INSERT INTO TCN VALUES (2, 10, 10.00, 10);
INSERT INTO TNI VALUES (1, 12, 12.00);
INSERT INTO TNI VALUES (2, 5, 5.00);
INSERT INTO TNI VALUES (3, NULL, NULL);
INSERT INTO TNIX VALUES (1, 12, 12.00);
INSERT INTO TNIX VALUES (2, 5, 5.00);
INSERT INTO TNIX VALUES (3, NULL, NULL);
INSERT INTO TK VALUES ('1 2');
INSERT INTO TKOK VALUES ('12');
INSERT INTO TKMIX VALUES ('12');
INSERT INTO TKMIX VALUES ('1 2');
INSERT INTO TKNUL VALUES (NULL);
/* the conversion-cap sources, built INSIDE the engine so no shell
   carries a 200-byte run of blanks: LPAD to the exact byte count the
   caps sit on. id 4's UTF8 column is 53 CHARACTERS and 54 BYTES - the
   pair that says which of the two the engine counts. */
INSERT INTO TLONG VALUES (1, LPAD('2', 52), NULL);
INSERT INTO TLONG VALUES (2, LPAD('2', 53), NULL);
INSERT INTO TLONG VALUES (3, RPAD('2', 61), NULL);
INSERT INTO TLONG VALUES (4, NULL, LPAD('é2', 53));
INSERT INTO TLONG VALUES (5, LPAD('2', 22), NULL);
INSERT INTO TLONG VALUES (6, LPAD('2', 23), NULL);
INSERT INTO TLONG VALUES (7, RPAD(LPAD('2', 53), 253), NULL);
INSERT INTO TLONG VALUES (8, LPAD('2', 130), NULL);
INSERT INTO TLONG VALUES (9, LPAD('2', 131), NULL);
INSERT INTO TLONG VALUES (10, LPAD('x', 53), NULL);
INSERT INTO TLONG VALUES (11, LPAD('2', 53, '0'), NULL);
INSERT INTO TLONG VALUES (12, LPAD('2', 52, '0'), NULL);
INSERT INTO TLONG VALUES (13, LPAD('2020-01-01', 130), NULL);
INSERT INTO TLONG VALUES (14, LPAD('2020-01-01', 131), NULL);
INSERT INTO TLONG VALUES (15, LPAD('2', 201), NULL);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

# TXCS: the 22018 argument must spell the value's bytes IN ITS OWN
# CHARACTER SET (probed: a WIN1252 'é2' spells #xe92 even through a
# UTF8 attachment, a WIN1250 'ř2' #xf82, a UTF8 'é2' #xc3#xa92) -
# seeded through a UTF8 attachment so the letters land as their
# codepage bytes, unlike make_db's NONE attachment
seed_xcs() {
    "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$1" <<EOF >/dev/null 2>&1
CREATE TABLE TXCS (ID INTEGER NOT NULL PRIMARY KEY,
                   W VARCHAR(10) CHARACTER SET WIN1252,
                   C VARCHAR(10) CHARACTER SET WIN1250,
                   U VARCHAR(10) CHARACTER SET UTF8);
COMMIT;
INSERT INTO TXCS VALUES (1, 'é2', 'ř2', 'é2');
COMMIT;
EOF
}
seed_xcs "$A" || { echo "FAIL seed TXCS A"; exit 1; }
seed_xcs "$B" || { echo "FAIL seed TXCS B"; exit 1; }

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

# --- 16. the CAST grammar: 0x20 and NOTHING else -----------------------
# The THIRD grammar in this file. The compare side above skips interior
# spaces and converts freely; cvt.cpp's `cvt_decompose` - the one a CAST
# and a STORE go through - skips 0x20 only, so a TAB, LF, VT, FF or CR
# at EITHER end is a conversion error, and so is every Unicode blank
# (NBSP, EM SPACE, IDEOGRAPHIC SPACE, NEL) that a Unicode whitespace
# class would have eaten. TCAST's rows are built with ASCII_CHAR inside
# the engine, so the byte under test never passes through a shell.
# The pairs to read together: id 13 ('  2  ') converts everywhere, so
# the refusals are about the BYTE and not about blanks in general; and
# id 20 ('1 0') answers 10 to the comparison two lines below the CAST
# that refuses it - the two grammars disagreeing over ONE stored value.
cst() { # <id> <target> - one row, one numeric target
    both "CAST(S AS $2) over TCAST id $1" \
         "SELECT CAST(S AS $2) AS V FROM TCAST WHERE ID = $1"
}
for tgt in SMALLINT INTEGER BIGINT "NUMERIC(9,2)" "DOUBLE PRECISION"; do
    for id in 1 2 3 4 5 6 7 8 9 10 11 12 13; do cst $id "$tgt"; done
done
# ' 2.5 ' to every target: the once-recorded "fc refuses a fraction
# the engine ROUNDS" residual is CLOSED (probed live: both answer 3
# for the integer family - half away from zero)
cst 14 SMALLINT
cst 14 INTEGER
cst 14 BIGINT
cst 14 "NUMERIC(9,2)"
cst 14 "DOUBLE PRECISION"
for id in 15 16 17 18 19; do cst $id INTEGER; done
cst 15 "DOUBLE PRECISION"
# the same grammar reached from a LITERAL in the statement text
both "CAST literal, TAB then the digit" \
     "SELECT CAST('${TAB}2' AS INTEGER) AS V FROM RDB\$DATABASE"
both "CAST literal, the digit then TAB" \
     "SELECT CAST('2${TAB}' AS DOUBLE PRECISION) AS V FROM RDB\$DATABASE"
both "CAST literal, LF" \
     "SELECT CAST('${LF}2' AS BIGINT) AS V FROM RDB\$DATABASE"
both "CAST literal, two TABs run together" \
     "SELECT CAST('${TAB}${TAB}2' AS NUMERIC(9,2)) AS V FROM RDB\$DATABASE"
both "CAST literal, SPACES still convert" \
     "SELECT CAST('  2  ' AS INTEGER) AS V FROM RDB\$DATABASE"
both "CAST literal, SPACES round a scaled one" \
     "SELECT CAST('  2.5  ' AS NUMERIC(9,2)) AS V FROM RDB\$DATABASE"
# the COMPARE vector over the same rows must NOT have moved
both "compare over the TAB row still raises" \
     "SELECT ID FROM TCAST WHERE ID = 1 AND S > 1"
both "compare over the SPACES row still answers" \
     "SELECT ID FROM TCAST WHERE ID = 13 AND S = 2"
both "compare converts the interior space ('1 0' is 10)" \
     "SELECT ID FROM TCAST WHERE ID = 20 AND S = 10"
both "... and the CAST of that same value refuses it" \
     "SELECT CAST(S AS INTEGER) AS V FROM TCAST WHERE ID = 20"
both "a spacey literal against an INTEGER column still answers" \
     "SELECT ID FROM TCN WHERE N = ' 2 '"
both "... against a NUMERIC column" "SELECT ID FROM TCN WHERE Q = ' 2.00 '"
both "... against a DOUBLE column" "SELECT ID FROM TCN WHERE D = ' 2 '"
both "... and bound as a text PARAMETER" \
     "SELECT ID FROM TCN WHERE N = ?" '["  2  "]'

# --- 17. the CONVERSION CAP: a buffer, not a grammar (law 9) -----------
# The FOURTH thing this file measures about a text-to-number conversion,
# and the only one that is not about spelling at all: the engine moves
# the source into the target's fixed stack buffer BEFORE the grammar
# reads it, so a source too long for that buffer is 22001 *string right
# truncation* whatever it spells. The buffer belongs to the CONVERSION
# ROUTINE, so the cap follows the target's STORAGE WIDTH and not its
# family - the pair to read together is NUMERIC(4,0) (a SHORT, 22) and
# DECIMAL(4,0) (a LONG, 52), one keyword apart.
cap() { both "$1" "SELECT CAST('$2' AS $3) AS V FROM RDB\$DATABASE"; }
sp() { printf '%*s' "$1" ''; }
# the 16-bit routine: 21 blanks convert, 22 raise
cap "SMALLINT takes 22 bytes"        "$(sp 21)2" SMALLINT
cap "SMALLINT refuses 23"            "$(sp 22)2" SMALLINT
cap "NUMERIC(4,0) is a SHORT too"    "$(sp 21)2" "NUMERIC(4,0)"
cap "... and refuses 23 with it"     "$(sp 22)2" "NUMERIC(4,0)"
# the 32/64-bit routine: 51 blanks convert, 52 raise
cap "INTEGER takes 52 bytes"         "$(sp 51)2" INTEGER
cap "INTEGER refuses 53"             "$(sp 52)2" INTEGER
cap "BIGINT takes the same 52"       "$(sp 51)2" BIGINT
cap "BIGINT refuses 53"              "$(sp 52)2" BIGINT
cap "NUMERIC(9,2) takes 52"          "$(sp 51)2" "NUMERIC(9,2)"
cap "NUMERIC(9,2) refuses 53"        "$(sp 52)2" "NUMERIC(9,2)"
cap "NUMERIC(18,0) refuses 53"       "$(sp 52)2" "NUMERIC(18,0)"
cap "DECIMAL(4,0) is a LONG: 22 fine" "$(sp 22)2" "DECIMAL(4,0)"
cap "... 52 fine"                    "$(sp 51)2" "DECIMAL(4,0)"
cap "... 53 raises"                  "$(sp 52)2" "DECIMAL(4,0)"
# the INT128 routine reads the string where it lies - no cap at all
cap "NUMERIC(19,0) takes 201 bytes"  "$(sp 200)2" "NUMERIC(19,0)"
cap "NUMERIC(38,2) takes 201 bytes"  "$(sp 200)2" "NUMERIC(38,2)"
# the double routine: 129 blanks convert, 130 raise
cap "DOUBLE takes 130 bytes"         "$(sp 129)2" "DOUBLE PRECISION"
cap "DOUBLE refuses 131"             "$(sp 130)2" "DOUBLE PRECISION"
cap "FLOAT takes the same 130"       "$(sp 129)2" FLOAT
cap "FLOAT refuses 131"              "$(sp 130)2" FLOAT
# the temporal scanner shares the double's buffer, and the 22001
# REPLACES the 22018 the spelling would have earned
cap "DATE takes 130 bytes"           "$(sp 120)2020-01-01" DATE
cap "DATE refuses 131"               "$(sp 121)2020-01-01" DATE
cap "TIMESTAMP refuses 131"          "$(sp 121)2020-01-01" TIMESTAMP
cap "a 130-byte nonsense is still 22018" "$(sp 129)x" DATE
# the cap fires BEFORE the grammar: a perfectly spelled source and a
# nonsense one of the same length take the SAME error
cap "53 bytes of DIGITS raise too"   "$(printf '0%.0s' $(seq 1 52))2" INTEGER
cap "52 bytes of digits convert"     "$(printf '0%.0s' $(seq 1 51))2" INTEGER
cap "53 bytes of nonsense: 22001, not 22018" "$(sp 52)x" INTEGER
cap "23 bytes of nonsense, SMALLINT" "$(sp 22)x" SMALLINT
# TRAILING blanks are dropped BEFORE the test and counted INTO the
# reported `actual`
cap "200 trailing blanks never count" "2$(sp 200)" SMALLINT
cap "... nor at the 52-byte target"   "2$(sp 200)" INTEGER
cap "51 lead + 200 trail converts"    "$(sp 51)2$(sp 200)" INTEGER
cap "52 lead + 200 trail raises, actual 253" "$(sp 52)2$(sp 200)" INTEGER
# and the same cap reached from a stored COLUMN
lng() { both "$1" "SELECT CAST(S AS $3) AS V FROM TLONG WHERE ID = $2"; }
lng "a 52-byte column value converts"  1 INTEGER
lng "a 53-byte one raises"             2 INTEGER
lng "trailing blanks converted (61)"   3 INTEGER
lng "22 bytes into a SMALLINT"         5 SMALLINT
lng "23 bytes into a SMALLINT"         6 SMALLINT
lng "53 real + 200 trailing"           7 INTEGER
lng "130 bytes into a DOUBLE"          8 "DOUBLE PRECISION"
lng "131 bytes into a DOUBLE"          9 "DOUBLE PRECISION"
lng "53 bytes of nonsense"            10 INTEGER
lng "53 bytes of leading zeros"       11 INTEGER
lng "52 bytes of leading zeros"       12 INTEGER
lng "130 bytes of DATE"               13 DATE
lng "131 bytes of DATE"               14 DATE
lng "201 bytes into an INT128 target" 15 "NUMERIC(19,0)"
lng "201 bytes into a BIGINT"         15 BIGINT
# BYTES, not characters: id 4's UTF8 value is one character shorter
# than it is bytes long, and the vector reports the BYTES
both "the UTF8 source's characters and bytes" \
     "SELECT CHAR_LENGTH(U) AS C, OCTET_LENGTH(U) AS O FROM TLONG WHERE ID = 4"
both "... and the cap counts the BYTES" \
     "SELECT CAST(U AS INTEGER) AS V FROM TLONG WHERE ID = 4"
# the COMPARISON vector has NO cap on either side - the third place the
# two grammars part company (the store side is priced in the header)
both "a 201-byte literal compares with no cap" \
     "SELECT ID FROM TCN WHERE N = '$(sp 200)2'"
both "... and a 201-byte COLUMN value does too" \
     "SELECT ID FROM TLONG WHERE S = 2"

# --- 18. one literal, two grammars, the INDEX deciding (law 10) --------
# The engine converts the LITERAL side of a comparison twice: the
# per-row compare takes the lenient grammar (blanks anywhere), and the
# optimizer's key build takes the strict store one. Which of the two the
# statement sees is decided by an INDEX on the compared column - TNI and
# TNIX hold the same three rows and differ only by that index, and every
# spelling below answers on one and raises 22018 on the other.
lax() { both "unindexed $1" "SELECT ID FROM TNI WHERE $2"; }
idx() { both "indexed   $1" "SELECT ID FROM TNIX WHERE $2"; }
for w in "N = '1 2'" "N = ' 1 2 '" "N = '1 2 '" "N = '5 . 0'" "N = '- 5'" \
         "N = '1 . 2'" "N > '1 1'" "N IN ('1 2')" "N BETWEEN '1 1' AND '9'" \
         "Q = '1 2'" "Q = '1 2.0 0'" "Q = '5 . 0'"; do
    lax "$w" "$w"
    idx "$w" "$w"
done
# the spellings BOTH grammars refuse still raise, indexed or not
for w in "N = 'x'" "N = '1 e 3'" "N = '5.5.5'" "N = '1,5'" "N = '--5'" "N = ''"; do
    lax "$w" "$w"
    idx "$w" "$w"
done
# the timing laws ride along, exactly as they do for a raising literal:
# the NULL row is silent, a dead group suppresses, an empty table says
# nothing, and the value-gate is per row
lax "the NULL row is UNKNOWN, not a match" "N = '1 2' OR N = '5 . 0'"
lax "a dead group suppresses the whole term" "N = '1 2' AND 1 = 0"
idx "a dead group suppresses the indexed RAISE too" "N = '1 2' AND 1 = 0"
lax "IS NULL beside it" "N IS NULL OR N = '1 2'"
both "an EMPTY table is silent either way" \
     "SELECT ID FROM TEMPTY WHERE ID = '1 2'"
# the literal on the LEFT, and the same value through a PARAMETER
lax "the literal on the left" "'1 2' = N"
both "unindexed, bound as a text parameter" \
     "SELECT ID FROM TNI WHERE N = ?" '["1 2"]'
both "indexed, bound as a text parameter" \
     "SELECT ID FROM TNIX WHERE N = ?" '["1 2"]'
both "unindexed, a bound NUMERIC-column parameter" \
     "SELECT ID FROM TNI WHERE Q = ?" '["1 2"]'
both "indexed, a bound NUMERIC-column parameter" \
     "SELECT ID FROM TNIX WHERE Q = ?" '["1 2"]'
# the keyed BOUND order, where two bad bounds meet: the engine builds
# the UPPER one first, whichever order they are written in
idx "two bad bounds name the UPPER" "N >= 'zz' AND N <= 'yy'"
idx "... written the other way round" "N <= 'yy' AND N >= 'zz'"
idx "... strict operators too" "N > 'zz' AND N < 'yy'"
idx "an equality's upper slot survives a later lower bound" "N = 'aa' AND N > 'bb'"
idx "BETWEEN whose LOWER is the bad one names it" "N BETWEEN 'zz' AND '9'"
# an EXPRESSION side is never keyed, so only the lenient grammar runs
lax "an expression side takes it" "N + 0 = '1 2'"
lax "... and the other orientation" "'1 2' = N + 0"
# ONE value, three answers in three adjacent statements: the comparison
# converts it, the CAST refuses it, and the index turns the comparison
# into the CAST's refusal
both "the CAST of that same literal refuses it" \
     "SELECT CAST('1 2' AS INTEGER) AS V FROM RDB\$DATABASE"
both "... and the CAST of the blanks-only sibling converts" \
     "SELECT CAST(' 12 ' AS INTEGER) AS V FROM RDB\$DATABASE"

# --- 19. THE THIRD KEY: a SEMI-JOIN's hash key (law 11) ----------------
# Same literal, same column, a THIRD conversion site. The engine turns a
# POSITIVE `IN (<subquery>)` / `= ANY` / correlated `EXISTS` written as a
# top-level conjunct into a SEMI-JOIN - `SET PLANONLY ON` says HASH - and
# converts its keys as it builds the hash table, with the STRICT store
# grammar. Every shape it does NOT hash keeps the lenient per-row
# compare, and the plan is the discriminator, cell for cell:
#
#   PLAN HASH, raises 22018      PLAN (..) PLAN (..), answers the row
#   ----------------------       ----------------------------------
#   N IN (SELECT S FROM TK)      N IN (SELECT ...) OR 1=0
#   (N IN (SELECT ...))          NOT (N IN (SELECT ...))
#   ... AND 1=1                  N NOT IN (SELECT ...)
#   EXISTS (correlated)          N = (SELECT S FROM TK)   [scalar]
#                                NOT EXISTS (correlated)
#                                N = ALL (SELECT ...)
#
# The gate is here rather than in serve-real-subquery.sh because the law
# is this file's own: ONE literal, now THREE grammars, and the SHAPE
# chooses which - an index for the retrieval key, a semi-join for the
# hash key, nothing for the per-row compare.
bothk() { both "$1" "SELECT ID FROM TNI WHERE $2"; }
# the hashed half
bothk "IN a subquery hashes: the strict grammar raises" \
      "N IN (SELECT S FROM TK)"
bothk "... parenthesised is still a top-level conjunct" \
      "(N IN (SELECT S FROM TK))"
bothk "... beside a TRUE conjunct" "N IN (SELECT S FROM TK) AND 1=1"
bothk "... beside a sibling OR that does not enclose it" \
      "N IN (SELECT S FROM TK) AND (ID = 1 OR ID = 2)"
bothk "a correlated EXISTS is the same semi-join" \
      "EXISTS (SELECT 1 FROM TK WHERE TK.S = TNI.N)"
# the un-hashed half - the lenient grammar, the row answered
bothk "under OR the semi-join is gone and the compare is lenient" \
      "N IN (SELECT S FROM TK) OR 1=0"
bothk "... an enclosing NOT the same" "NOT (N IN (SELECT S FROM TK))"
bothk "NOT IN is an anti-join, never hashed" "N NOT IN (SELECT S FROM TK)"
bothk "NOT EXISTS likewise" \
      "NOT EXISTS (SELECT 1 FROM TK WHERE TK.S = TNI.N)"
bothk "a correlated EXISTS under OR" \
      "EXISTS (SELECT 1 FROM TK WHERE TK.S = TNI.N) OR 1=0"
bothk "a SCALAR subquery is a singleton, not a key" "N = (SELECT S FROM TK)"
bothk "... against a NUMERIC column" "Q = (SELECT S FROM TK)"
# the gates on the raise: it is the BUILD that fails, so it does not
# read the outer row's value - but it never runs without one
both "a NULL-only outer still raises (no value gate)" \
     "SELECT N FROM TKNUL WHERE N IN (SELECT S FROM TK)"
both "an EMPTY outer raises nothing" \
     "SELECT ID FROM TEMPTY WHERE ID IN (SELECT S FROM TK)"
bothk "an empty INNER decides FALSE with no conversion" \
      "N IN (SELECT S FROM TK WHERE S = 'nope')"
# one bad key sinks the whole build, whatever the others do
bothk "a list the strict grammar takes converts and answers" \
      "N IN (SELECT S FROM TKOK)"
bothk "one bad key among good ones still sinks it" \
      "N IN (SELECT S FROM TKMIX)"
# the index does not change a hash key's grammar - it was strict already
both "the indexed twin raises the same" \
     "SELECT ID FROM TNIX WHERE N IN (SELECT S FROM TK)"
# and the LITERAL spelled out, beside it: the same value, answered
bothk "the same value written as a LITERAL answers" "N IN ('1 2')"

# A LEFT join is the control the plan itself names: the engine NEVER
# hashes one (`PLAN JOIN`), so the same two columns compare leniently
# and every outer row comes back.
both "a LEFT join's ON is not a hash key" \
     "SELECT ID FROM TNI LEFT JOIN TK ON TK.S = TNI.N ORDER BY ID"

# --- THE INNER JOIN'S KEY IS HASHED, AND NOW READ STRICTLY -------------
# The engine hashes an INNER (and comma) join's key and builds it with
# the CAST grammar, so an unconvertible text value RAISES where the
# LEFT join of the same pair - a nested loop - answers. Both spellings
# are real checks now; the ON form and the WHERE form are marked at
# different sites (the ON at the join step, the WHERE at the plan, for
# the comma join whose key never appears in an ON).
both "an INNER join's key is read strictly" \
     "SELECT ID FROM TNI JOIN TK ON TK.S = TNI.N"
both "... the comma spelling, whose key lives in the WHERE" \
     "SELECT ID FROM TNI, TK WHERE TNI.N = TK.S"
both "... and the equality written the other way round" \
     "SELECT ID FROM TNI JOIN TK ON TNI.N = TK.S"
# THE TWO SILENCERS, measured: the engine answers 0 rather than raising
# when a sibling conjunct is INVARIANT (it never builds the hash) and
# when a conjunct filters the KEY'S OWN STREAM (applied to that stream
# before the build). fire-crab declines to mark in both cases, which
# leaves the lenient answer - the same answer the engine gives.
both "a FALSE sibling conjunct silences the key raise" \
     "SELECT COUNT(*) FROM TNI JOIN TK ON TK.S = TNI.N AND 1=0"
both "a filter on the key's own stream silences it" \
     "SELECT COUNT(*) FROM TNI JOIN TK ON TK.S = TNI.N AND TK.S = '34'"
# and the LEFT join must NOT have moved: it is a nested loop, not a hash
both "a LEFT join of the same pair stays lenient" \
     "SELECT ID FROM TNI LEFT JOIN TK ON TK.S = TNI.N ORDER BY ID"
# ... UNLESS THE WHERE KILLS ITS PADDING. A conjunct that rejects a NULL
# from the right side makes the padded row unreachable, so the engine
# plans an inner join - PLAN HASH, probed - and the key is then read
# strictly. The rows are identical either way, which is what makes this
# safe: what changes is which evaluations happen.
both "a LEFT join whose WHERE rejects the padding degrades to inner" \
     "SELECT ID FROM TNI LEFT JOIN TK ON 1=1 WHERE TNI.N = TK.S"
both "... and the same through an explicit ON key" \
     "SELECT ID FROM TNI LEFT JOIN TK ON TK.S = TNI.N WHERE TK.S = '34'"
# the two idioms that must NOT degrade, both PLAN JOIN on the engine
both "the ANTI-JOIN idiom keeps its padding" \
     "SELECT ID FROM TNI LEFT JOIN TK ON TK.S = TNI.N WHERE TK.S IS NULL ORDER BY ID"
both "a conjunct under an OR is not null-rejecting" \
     "SELECT ID FROM TNI LEFT JOIN TK ON TK.S = TNI.N WHERE TK.S = '34' OR 1=1 ORDER BY ID"
both "control: a plain LEFT join still pads" \
     "SELECT ID FROM TNI LEFT JOIN TKOK ON TKOK.S = TNI.N ORDER BY ID"

# --- RECORDED BOUNDARIES: the hashes fire-crab does not reach ----------
# WHICH SIDE the engine builds the hash from is the OPTIMIZER'S choice
# and it moves with CARDINALITY - probed: with one row in the text
# table the plan is `HASH (NE NATURAL, S1 NATURAL)` and an empty other
# side answers 0, with two rows it is `HASH (S1 NATURAL, NE NATURAL)`
# and the SAME query RAISES, because the build side is read whether or
# not the other side has a row. fire-crab evaluates per PAIR, so it can
# never raise with an empty stream. Reproducing that needs the hash
# build AND a model of the side choice; until then this under-raises,
# which is the direction that answers rather than invents.
# `= ANY` / `= ALL` have no surface at all here; the refusal is pinned
# so it cannot quietly become an answer.
krec() { # <label> <sql> <fc-today> <engine-today>
    a=$(query "$2" "[]" "$PORT" "$A")
    b=$(query "$2" "[]" "$REAL" "$B")
    ran=$((ran + 2))
    if [ "$a" = "$3" ]; then echo "BOUND $1 | fc: $a"
    else echo "DIFF $1 - fire-crab moved"; echo "     got:  $a"; echo "     was:  $3"; fail=1; fi
    if [ "$b" = "$4" ]; then echo "BOUND $1 | engine: $b"
    else echo "DIFF $1 - the ENGINE moved"; echo "     got:  $b"; echo "     was:  $4"; fail=1; fi
}
# `= ANY` IS a semi-join, so it hashes and its key is read strictly;
# `= ALL` is not one, so it stays lenient. Both were "no surface at all"
# until the quantified comparisons landed, and this asymmetry is what
# proves `= ANY` goes through the IN path rather than beside it.
both "= ANY inherits the semi-join's strict key" \
     "SELECT ID FROM TNI WHERE N = ANY (SELECT S FROM TK)"
both "= ALL is not hashed, so it stays lenient" \
     "SELECT ID FROM TNI WHERE N = ALL (SELECT S FROM TK)"
both "<> ALL is NOT IN, and never hashed" \
     "SELECT ID FROM TNI WHERE N <> ALL (SELECT S FROM TK)"

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
# the STORE side of law 8: the spacey spellings still write, to every
# numeric column, through both INSERT and UPDATE
both "a spacey literal STORES into all three numeric columns" \
     "INSERT INTO TCN VALUES (3, ' 5 ', ' 5.50 ', ' 5.5 ')"
both "... and UPDATEs one" "UPDATE TCN SET N = ' 6 ' WHERE ID = 3"
both "the stored numbers read back (fresh attachment)" \
     "SELECT ID, N, Q, D FROM TCN ORDER BY ID"

# --- 14. the 22018 argument spells the COLUMN CHARSET's bytes ----------
# CVT_conversion_error renders the value BEFORE any transliteration to
# the attachment set, so the escape is over the codepage's bytes: the
# WIN1252 'é' is one #xe9, the WIN1250 'ř' one #xf8, and the UTF8 'é'
# the two-byte #xc3#xa9 - all through the same UTF8 attachment. Before
# the charset rode the Cast/TextNum wraps, fc escaped the Rust String's
# UTF-8 for every source and the single-byte columns spelled doubled.
both "the CAST 22018 spells WIN1252 bytes (#xe92)" \
     "SELECT CAST(W AS INTEGER) AS V FROM TXCS WHERE ID = 1"
both "... WIN1250 bytes (#xf82)" \
     "SELECT CAST(C AS INTEGER) AS V FROM TXCS WHERE ID = 1"
both "... and UTF8 stays two-byte (#xc3#xa92)" \
     "SELECT CAST(U AS INTEGER) AS V FROM TXCS WHERE ID = 1"
both "the COMPARE vector spells the same way" \
     "SELECT ID FROM TXCS WHERE ID = W"
both "... on the WIN1250 side too" \
     "SELECT ID FROM TXCS WHERE ID = C"
both "a numeric CAST target as well (NUMERIC(9,2))" \
     "SELECT CAST(W AS NUMERIC(9,2)) AS V FROM TXCS WHERE ID = 1"
both "DOUBLE PRECISION too" \
     "SELECT CAST(C AS DOUBLE PRECISION) AS V FROM TXCS WHERE ID = 1"

# --- 15. the ran counter -----------------------------------------------
if [ "$ran" -ne 355 ]; then
    echo "DIFF $ran checks ran (expected exactly 355) - did one silently skip?"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$A" "$B"
exit $fail
