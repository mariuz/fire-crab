#!/bin/bash
# The LIST aggregate - `LIST([DISTINCT] arg [, separator])` - and with it
# fire-crab's FIRST COMPUTED BLOB: a result the server itself creates (no
# storage behind it), served through the same relation-0 temp-blob path a
# client-written blob takes (op_open_blob2 / op_info_blob / op_get_segment,
# the transaction's lifetime).
#
# The engine's ListAggNode, converted from measurement:
#   - each non-null value renders to text (MOV_make_string2) and is
#     appended as ITS OWN SEGMENT; the separator (default `,`) is its own
#     segment BEFORE each value after the first, EVALUATED ON THAT ROW (a
#     per-row separator expression works); an empty piece writes NO
#     segment; a NULL separator at any append marks the WHOLE result NULL;
#     NULL over an empty / all-null set. Nullable always.
#   - DISTINCT sorts and dedupes the values; a CHAR argument joins the
#     plain fold padded to its declared CHARACTER count but the DISTINCT
#     fold as its full BYTE image (both measured).
#   - describe: BLOB sub_type 1, charset = the ARGUMENT's (a text column
#     its own, a text expression the first text column it references, a
#     bare literal / numeric NONE).
#   - within a GROUP the engine's sort record orders ties by EVERY OTHER
#     FIELD THE STATEMENT REFERENCES, in field order (a field referenced
#     only in the WHERE included; an unreferenced one excluded); over a
#     JOIN the join's delivery order holds instead. fc reproduces both.
#
# Boundaries (recorded): LIST inside an EXPRESSION (CHAR_LENGTH(LIST(..)),
# HAVING LIST(..) = ..), in a scalar SUBQUERY, and the window OVER () form
# refuse (the engine answers them); the malformed shapes (three arguments,
# LIST(*), empty) refuse with fc's generic vector where the engine spells
# -104; grouped tie order over a DERIVED source and a tie broken only
# through a BLOB column's id are unpinned; a blob id opened after its
# transaction ends degrades to empty rather than the engine's invalid-id.
#
#   qa/serve-real-list.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4951}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-list-crab.fdb"; B="$D/fc-list-engine.fdb"
LOG="/tmp/fc-serve-list-$PORT.log"
FBROOT="${FBROOT:-/opt/firebird}"
FBINC="$FBROOT/include"; FBLIB="$FBROOT/lib"
mkdir -p "$D"; fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
[ -f "$FBINC/ibase.h" ] || { echo "SKIP $FBINC/ibase.h not found"; exit 0; }
gcc -O1 -o "$D/listblob" "$(dirname "$0")/c/listblob.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile"; exit 1; }
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
# blob ids differ between servers by nature: normalise them out
norm() { grep -v '^$' | sed 's/[0-9a-f][0-9a-f]*:[0-9a-f][0-9a-f]*$/BLOBID/' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

SET='CREATE TABLE T (ID INTEGER, G INTEGER, S VARCHAR(20), N NUMERIC(9,2), C CHAR(5), DP DOUBLE PRECISION, B BLOB SUB_TYPE TEXT, SEP VARCHAR(5), SU VARCHAR(10) CHARACTER SET UTF8, CU CHAR(4) CHARACTER SET UTF8);
INSERT INTO T VALUES (1, 1, ''aa'', 1.50, ''ab'', 2.5, ''blob1'', ''-'', ''x€y'', ''Ж'');
INSERT INTO T VALUES (2, 1, ''bb'', 2.25, ''cd'', 1.25, ''blob2'', NULL, ''plain'', ''ab'');
INSERT INTO T VALUES (3, 2, ''cc'', NULL, ''ab'', 300, NULL, ''+'', NULL, ''Жab'');
INSERT INTO T VALUES (4, 2, NULL, 4.00, NULL, 0.001, ''b3'', ''*'', ''€€'', NULL);
INSERT INTO T VALUES (5, 2, ''aa'', 5.75, ''xy'', NULL, ''x'', '';'', ''x€y'', ''cdef'');
INSERT INTO T VALUES (6, 3, '''', 1.00, ''AB'', 7, '''', ''.'', '''', ''g'');
CREATE TABLE T6 (G INTEGER, V VARCHAR(10), W VARCHAR(10));
INSERT INTO T6 VALUES (1, ''b'', ''z'');
INSERT INTO T6 VALUES (1, ''c'', ''y'');
INSERT INTO T6 VALUES (1, ''a'', ''x'');
INSERT INTO T6 VALUES (2, ''q'', ''x'');
INSERT INTO T6 VALUES (2, ''p'', ''z'');
INSERT INTO T6 VALUES (2, ''r'', ''y'');
CREATE TABLE T9 (G INTEGER, V VARCHAR(10), W VARCHAR(10));
INSERT INTO T9 VALUES (1, ''b'', NULL);
INSERT INTO T9 VALUES (1, ''c'', ''y'');
INSERT INTO T9 VALUES (1, ''a'', ''x'');
INSERT INTO T9 VALUES (2, ''p'', ''z'');
INSERT INTO T9 VALUES (2, ''q'', NULL);
CREATE TABLE TA (G INTEGER, V VARCHAR(10), K INTEGER);
INSERT INTO TA VALUES (1, ''b'', 1);
INSERT INTO TA VALUES (1, ''aa'', 2);
INSERT INTO TA VALUES (1, ''c'', 3);
CREATE TABLE TI (G INTEGER, V VARCHAR(10), K INTEGER);
INSERT INTO TI VALUES (1, ''x'', 256);
INSERT INTO TI VALUES (1, ''y'', 1);
INSERT INTO TI VALUES (1, ''z'', -5);
CREATE TABLE TK (G INTEGER, V VARCHAR(10), K INTEGER);
INSERT INTO TK VALUES (1, ''x'', 5);
INSERT INTO TK VALUES (1, ''y'', NULL);
INSERT INTO TK VALUES (1, ''z'', 1);
CREATE TABLE TR (G INTEGER, V VARCHAR(10));
INSERT INTO TR VALUES (1, ''ba'');
INSERT INTO TR VALUES (1, ''ab'');
INSERT INTO TR VALUES (1, ''ca'');
CREATE TABLE TW (G INTEGER, V VARCHAR(10), B8 BIGINT);
INSERT INTO TW VALUES (1, ''x'', 4294967296);
INSERT INTO TW VALUES (1, ''y'', 3);
INSERT INTO TW VALUES (1, ''z'', -1);
CREATE TABLE TD (G INTEGER, ID INTEGER, V VARCHAR(10));
INSERT INTO TD VALUES (1, 1, ''c'');
INSERT INTO TD VALUES (1, 2, ''a'');
INSERT INTO TD VALUES (1, 3, ''b'');
INSERT INTO TD VALUES (2, 4, ''q'');
CREATE VIEW VTD (G, V) AS SELECT G, V FROM TD;
COMMIT;'
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SET" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SET" >/dev/null 2>&1

# --- the C client: describe + info numbers + segment framing + content ---
cq() { # $1 label, $2 sql
    ran=$((ran + 1))
    local e c
    e=$("$D/listblob" "127.0.0.1/$REAL:$B" "$2" 2>&1)
    c=$("$D/listblob" "127.0.0.1/$PORT:$A" "$2" 2>&1)
    if [ "$e" = "$c" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     got:  [$c]"; echo "     want: [$e]"; fail=1; fi
}
cq "plain fold: value and separator each a segment" "SELECT LIST(S) FROM T"
cq "explicit separator" "SELECT LIST(S, ';') FROM T"
cq "empty separator: values only, still between them" "SELECT LIST(S, '') FROM T"
cq "an empty-string value: content, NO segment" "SELECT LIST(S) FROM T WHERE ID IN (5, 6)"
cq "DISTINCT sorts and dedupes (empty string first)" "SELECT LIST(DISTINCT S) FROM T"
cq "DISTINCT over integers sorts numerically" "SELECT LIST(DISTINCT ID) FROM T"
cq "NUMERIC renders at its scale" "SELECT LIST(N) FROM T"
cq "DOUBLE renders the engine's 16 digits" "SELECT LIST(DP) FROM T"
cq "CHAR pads to its CHARACTER count" "SELECT LIST(C) FROM T"
cq "multibyte CHAR: 4 characters, 5 bytes" "SELECT LIST(CU) FROM T"
cq "DISTINCT CHAR: the full BYTE image" "SELECT LIST(DISTINCT CU) FROM T"
cq "a BLOB argument joins by content, one segment" "SELECT LIST(B) FROM T"
cq "a text expression (multibyte)" "SELECT LIST(SU || '€') FROM T WHERE ID < 3"
cq "a single value: one segment, no separator" "SELECT LIST(S) FROM T WHERE ID = 1"
cq "an empty set answers NULL" "SELECT LIST(S) FROM T WHERE ID > 100"
cq "a per-row separator column (one NULL poisons)" "SELECT LIST(S, SEP) FROM T"
cq "a per-row separator over non-null rows" "SELECT LIST(S, SEP) FROM T WHERE ID IN (3, 5)"
cq "a constant NULL separator answers NULL" "SELECT LIST(S, NULL) FROM T"
cq "FILTER folds only the accepted rows" "SELECT LIST(S) FILTER (WHERE ID > 2) FROM T"
cq "DISTINCT + FILTER + separator" "SELECT LIST(DISTINCT S, '#') FILTER (WHERE ID > 1) FROM T"
cq "a date expression renders 2020-01-15" "SELECT LIST(CAST('2020-01-15' AS DATE)) FROM T WHERE ID < 3"
cq "UPPER of the argument" "SELECT LIST(UPPER(S)) FROM T"

# --- grouped: values, tie order, expression keys, HAVING, a join ---
cat > "$D/lg.sql" <<'SQL'
SET LIST ON; SET BLOB ALL;
SELECT G, LIST(S) AS L FROM T GROUP BY G;
SELECT G, LIST(S) AS L, COUNT(*) AS CNT FROM T GROUP BY G;
SELECT G, LIST(N) AS LN FROM T GROUP BY G;
SELECT G, LIST(S, ';') AS LS FROM T WHERE ID < 6 GROUP BY G;
SELECT G, LIST(DISTINCT S) AS LD FROM T GROUP BY G;
SELECT G, LIST(S) AS LH FROM T GROUP BY G HAVING COUNT(*) > 1;
SELECT MOD(G, 2) AS K, LIST(S) AS LK FROM T GROUP BY MOD(G, 2);
SELECT G, LIST(S) AS LO FROM T GROUP BY G ORDER BY 2;
SQL
gof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/lg.sql" 2>&1 | norm; }
check "grouped folds: values, HAVING, expression keys, ORDER BY the list" \
    "$(gof "127.0.0.1/$PORT:$A")" "$(gof "127.0.0.1/$REAL:$B")"

# the tie order within a group is the engine's sort record: the group keys,
# then every OTHER referenCED field in field order - LIST(V) comes out
# V-ordered, LIST(W) W-ordered, both together V-ordered (V leads the
# record), and a field referenced ONLY in the WHERE still drives
cat > "$D/lt.sql" <<'SQL'
SET LIST ON; SET BLOB ALL;
SELECT G, LIST(V) AS LV FROM T6 GROUP BY G;
SELECT G, LIST(W) AS LW FROM T6 GROUP BY G;
SELECT G, LIST(V) AS LV, LIST(W) AS LW FROM T6 GROUP BY G;
SELECT G, LIST(W) AS PW FROM T6 WHERE V > '' GROUP BY G;
SELECT T.G, LIST(T.S || U.S) AS LJ FROM T JOIN T U ON U.ID = T.ID GROUP BY T.G;
SQL
tof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/lt.sql" 2>&1 | norm; }
check "within-group tie order: the referenced-fields record, and a join's delivery order" \
    "$(tof "127.0.0.1/$PORT:$A")" "$(tof "127.0.0.1/$REAL:$B")"

# ... and the record comparison's finer grain, each shape measured: a NULL
# in a referenced field sinks its row below the non-null ones (text AND
# integer fields); a VARYING value compares by its COUNT WORD first
# ('b','c','aa'); within a 4-byte word the LAST byte dominates (the
# engine's quick() compares native ULONGs - 'ba','ca','ab'); an INTEGER
# value compares as one UNSIGNED word (1, 256, -5)
cat > "$D/lt2.sql" <<'SQL'
SET LIST ON; SET BLOB ALL;
SELECT G, LIST(V) AS LV, LIST(W) AS LW FROM T9 GROUP BY G;
SELECT G, LIST(V) AS MIXLEN FROM TA GROUP BY G;
SELECT G, LIST(K) AS KDRIVE FROM TI GROUP BY G;
SELECT G, LIST(V) AS VK, LIST(K) AS KK FROM TK GROUP BY G;
SELECT G, LIST(V) AS RV FROM TR GROUP BY G;
SELECT G, LIST(B8) AS LB8 FROM TW GROUP BY G;
SELECT LIST(ALL V, ';') AS LALL FROM TD;
SQL
t2of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/lt2.sql" 2>&1 | norm; }
check "tie grain: null flags, the vary count word, word-reversed bytes, unsigned ints" \
    "$(t2of "127.0.0.1/$PORT:$A")" "$(t2of "127.0.0.1/$REAL:$B")"

# a DERIVED table, a CTE, a UNION source and a VIEW flatten into the SAME
# grouping sort record, referenced-field ties included (review-caught: the
# first cut kept these in delivery order)
cat > "$D/lt3.sql" <<'SQL'
SET LIST ON; SET BLOB ALL;
SELECT G, LIST(V) AS DRV FROM (SELECT G, V FROM TD) X GROUP BY G;
WITH C AS (SELECT G, V FROM TD) SELECT G, LIST(V) AS CTE FROM C GROUP BY G;
SELECT G, LIST(V) AS UNI FROM (SELECT G, V FROM TD UNION ALL SELECT G, V FROM TD WHERE 1=0) X GROUP BY G;
SELECT G, LIST(V) AS VW FROM VTD GROUP BY G;
SQL
t3of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/lt3.sql" 2>&1 | norm; }
check "a derived table / CTE / UNION / view fold tie-orders like the base table" \
    "$(t3of "127.0.0.1/$PORT:$A")" "$(t3of "127.0.0.1/$REAL:$B")"

# --- the describe: BLOB sub_type 1, the ARGUMENT's charset, Nullable ---
cat > "$D/ld.sql" <<'SQL'
SET SQLDA_DISPLAY ON; SET PLANONLY ON;
SELECT LIST(S) FROM T;
SELECT LIST(SU) FROM T;
SELECT LIST(ID) FROM T;
SELECT LIST('lit') FROM T;
SELECT LIST(NULL) FROM T;
SELECT LIST(SU || 'x') FROM T;
SELECT LIST(B) FROM T;
SELECT LIST(DISTINCT CU, ';') FROM T;
SELECT G, LIST(N) FROM T GROUP BY G;
SELECT LIST(DP) FROM T;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/ld.sql" 2>&1 | grep -iE "sqltype|charset" | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
check "the describe: sub_type 1, the argument's charset, name LIST, Nullable" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# --- boundaries that must REFUSE (a wrong answer would be worse) ---
bref() { # $1 label, $2 sql - fc must refuse, engine answers or refuses its way
    ran=$((ran + 1))
    local c
    c=$(echo "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$c" in *"Dynamic SQL Error"*|*"feature is not supported"*) echo "OK   $1 (refused)";;
        *) echo "DIFF $1 answered: [$c]"; fail=1;; esac
}
bref "LIST inside an expression refuses" "SELECT CHAR_LENGTH(LIST(S)) FROM T;"
bref "HAVING over a LIST refuses" "SELECT G FROM T GROUP BY G HAVING LIST(S) = 'aa,bb';"
bref "a scalar-subquery LIST refuses" "SELECT (SELECT LIST(X.S) FROM T X WHERE X.G = T.G) FROM T WHERE ID = 1;"
bref "the window form refuses" "SELECT LIST(S) OVER () FROM T;"
bref "a LIST inside a derived table refuses" "SELECT * FROM (SELECT LIST(S) AS L FROM T);"
bref "three arguments refuse" "SELECT LIST(S, ',', 'x') FROM T;"
bref "LIST(*) refuses" "SELECT LIST(*) FROM T;"
# the engine's DISTINCT keys a blob by its DESCRIPTOR (the id) - equal
# content never dedupes and the set comes out in id order, which fc's ids
# cannot reproduce: a content dedupe would answer WRONG, so fc refuses
bref "LIST(DISTINCT <blob column>) refuses" "SELECT LIST(DISTINCT B) FROM T;"
# ... and DISTINCT over a NON-BINARY collation dedupes by the collation key
# there - fc's binary compare would dedupe wrong, so it refuses too
ran=$((ran + 1))
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1 <<'SQL'
CREATE TABLE TCO (G INTEGER, VC VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO TCO VALUES (1, 'Aa'); INSERT INTO TCO VALUES (1, 'aa'); COMMIT;
SQL
cco=$(echo "SELECT LIST(DISTINCT VC) FROM TCO;" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
case "$cco" in *"Dynamic SQL Error"*) echo "OK   LIST(DISTINCT <collated column>) refuses";;
    *) echo "DIFF collated DISTINCT answered: [$cco]"; fail=1;; esac

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file (a computed blob leaves no storage)"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
