#!/bin/bash
# SELECT-LIST EXPRESSIONS: arithmetic (+, -, *, unary -, parens) over
# integer columns and literals, and constant literals, in the select
# list - SELECT A + B, A * 2, -A, 1 + 1 FROM t. The server evaluates
# each expression per decoded row, propagating NULL through arithmetic
# (SQL three-valued), and describes the result as BIGINT. The un-aliased
# output column takes the engine's own operation name (ADD / SUBTRACT /
# MULTIPLY / NEGATE / CONSTANT), which is why the differential below can
# compare the isql column HEADER too, not just the values.
#
# The oracle is the engine: every query runs IDENTICALLY through
# fire-crab (node-firebird) and through isql on the same file, values
# and column names compared.
#
#   qa/serve-real-selectexpr.sh [port]
#
# Builds its own scratch database.
#
# The last block is here because the select-list ITEM PARSER, not the
# charset layer, is what a multi-byte expression used to break: the item
# was tested for the DECODE builtin by slicing its first six BYTES, and
# `'ABCDe-acute' || 'x'` has a character straddling byte 6. Slicing a
# Rust str off a character boundary PANICS, and a panic in a connection
# thread drops the client (libfbclient has been seen to segfault on it).
# So those checks run the once-panicking statements as ordinary
# differentials, keep a genuine DECODE call as the control that the
# recognition still works, and end by asking a FRESH attachment to
# answer - the failure mode was a dropped connection, so liveness after
# the fact is the check that matters most.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4092}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/selexpr_src.fdb"; CLEAN="$DIR/selexpr_clean.fdb"
WORK="/tmp/fc-selexpr-work.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE E (ID INTEGER NOT NULL, A INTEGER, B INTEGER, S VARCHAR(10), N NUMERIC(9,2), M NUMERIC(9,4), K BIGINT, U NUMERIC(10,2), I INT128);
-- a table of its own for the multi-byte block: table E's rows are
-- positional and adding a column to them would rewrite every INSERT
CREATE TABLE MB (ID INTEGER NOT NULL, D INTEGER, S8 VARCHAR(10) CHARACTER SET UTF8);
COMMIT;
INSERT INTO E VALUES (1, 10, 3, 'x', 12.50, 1.2345, 4000000000, 9.75, 900000000000);
INSERT INTO E VALUES (2, 5, 100, 'y', -3.25, 4.0000, 5, -2.50, 7);
INSERT INTO E VALUES (3, NULL, 7, 'z', NULL, 2.0000, NULL, NULL, NULL);
INSERT INTO E VALUES (4, -8, 2, 'w', 13.50, 0.5000, 3100000000, 100.00, 123456);
COMMIT;
EOF
# the multi-byte rows go in over a UTF8 connection: a NONE attachment
# would hand the engine bytes it is entitled to reject on the way in
"$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$SRC" <<EOF || { echo "FAIL multi-byte rows"; exit 1; }
INSERT INTO MB VALUES (1, 1, 'ABCDé');
INSERT INTO MB VALUES (2, 2, 'ăîșță');
INSERT INTO MB VALUES (3, 3, 'plain');
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" "$SRC" >/dev/null 2>&1 <<'EOF'
COMMIT;
EOF
cp "$SRC" "$CLEAN"; cp "$CLEAN" "$WORK"

LOG=/tmp/fc-serve-selexpr-$PORT.log
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
# CH selects the ATTACHMENT character set for both sides at once. An
# untyped literal takes the attachment's charset, so 'ABCDé' is six
# octets to a NONE connection and five characters to a UTF8 one - both
# sides must be asked the same way or the compare measures the connection
# rather than the server.
#
# EMPTY IS NOT "NONE ON BOTH SIDES": isql with no -ch attaches NONE,
# node-firebird with no `encoding` attaches UTF8. The blocks below that
# leave CH empty are ASCII-only, where the two agree; anything
# multi-byte either sets CH (which both sides then honour) or uses the
# isql-on-both-sides comparator further down.
CH=""
run_isql() {
    if [ -n "$CH" ]; then "$ISQL" -q -b -ch "$CH" -user "$U" -pas "$P" "$WORK"
    else "$ISQL" -q -b -user "$U" -pas "$P" "$WORK"; fi
}

# node: run <query>, print header (column titles) then each row, values
# joined by '|', so both the column NAME and the values are compared
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" FC_CH="$CH" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      const o={host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
               user:"SYSDBA",password:"masterkey"};
      // node-firebird names the attachment charset `encoding`, and
      // defaults it to UTF8; a `charset` property is silently ignored
      if(process.env.FC_CH) o.encoding=process.env.FC_CH;
      F.attach(o,(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(r&&r.length) console.log("H:"+Object.keys(r[0]).join("|"));
          for(const row of (r||[]))
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
# compare fire-crab and isql on the SAME select. isql prints the column
# header (titles) which we prefix H: to match node's header line, then
# the rows; both sides sorted so row order is not under test here.
compare() { # <label> <select>
    fc=$(node_run "$2" | sort)
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING ON;
$2;
EOF
)
    # turn isql's "===" underline + header into H:col|col, values below
    is=$(printf '%s\n' "$is" | awk '
        /^=+/ { next }
        NR==1 { gsub(/[ \t]+/,"|"); print "H:" $0; next }
        { gsub(/^[ \t]+|[ \t]+$/,""); gsub(/[ \t]+/,"|"); print }
    ' | sort)
    if [ "$fc" = "$is" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     isql: $(echo $is)"
        echo "     fc:   $(echo $fc)"
        fail=1
    fi
}

# node-firebird renders a NUMERIC as a JavaScript number, dropping the
# trailing zeros isql keeps (25.00 -> 25, 156.2500 -> 156.25). Strip
# trailing zeros from pure-decimal fields on BOTH sides so the display
# artifact does not fail the compare - a WRONG scale still changes the
# significant digits and is caught (25 vs 0.25 vs 2500). Only decimal-
# looking fields are touched, so text/CAST values stay exact.
denum() {
    awk -F'|' '{
        for (i=1;i<=NF;i++) if ($i ~ /^-?[0-9]+\.[0-9]+$/) {
            sub(/0+$/, "", $i); sub(/\.$/, "", $i)
        }
        s=$1; for (i=2;i<=NF;i++) s=s"|"$i; print s
    }'
}

# a numeric-normalizing compare for the arithmetic block (values compared
# up to trailing-zero display; column HEADERS still compared exactly)
comparen() { # <label> <select>
    fc=$(node_run "$2" | denum | sort)
    is=$(run_isql <<EOF | strip | grep -v '^$'
SET HEADING ON;
$2;
EOF
)
    is=$(printf '%s\n' "$is" | awk '
        /^=+/ { next }
        NR==1 { gsub(/[ \t]+/,"|"); print "H:" $0; next }
        { gsub(/^[ \t]+|[ \t]+$/,""); gsub(/[ \t]+/,"|"); print }
    ' | denum | sort)
    if [ "$fc" = "$is" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     isql: $(echo $is)"
        echo "     fc:   $(echo $fc)"
        fail=1
    fi
}

# --- arithmetic over columns -------------------------------------------
compare "add columns"       "SELECT A + B FROM E WHERE ID = 1"
compare "subtract columns"  "SELECT A - B FROM E WHERE ID = 2"
compare "multiply column"   "SELECT A * 2 FROM E WHERE ID = 1"
compare "precedence * over +" "SELECT A + B * 2 FROM E WHERE ID = 1"
compare "parens override"   "SELECT (A + B) * 2 FROM E WHERE ID = 1"
# unary minus: aliased so both sides carry a comparable header (the
# un-aliased engine header for -A is blank, which isql prints as spaces
# that the harness strips - a display artifact, not a value difference)
compare "unary minus"       "SELECT -A AS NEG FROM E WHERE ID = 4"
compare "column then expr"  "SELECT A, A * B FROM E WHERE ID = 2"
compare "NULL propagates"   "SELECT A + B FROM E WHERE ID = 3"
compare "nested"            "SELECT A * B - A FROM E WHERE ID = 1"

# --- constant literals -------------------------------------------------
compare "int literal"       "SELECT 1 + 1 FROM E WHERE ID = 1"
compare "literal times col" "SELECT 3 * A FROM E WHERE ID = 1"

# --- aliases -----------------------------------------------------------
compare "aliased expr"      "SELECT A + B AS TOTAL FROM E WHERE ID = 1"
compare "aliased mult"      "SELECT A * B AS PROD FROM E WHERE ID = 2"

# --- multiple expression columns + a plain column ----------------------
compare "mixed columns"     "SELECT ID, A + B, A - B FROM E WHERE ID = 1"

# --- integer division (truncates toward zero, named DIVIDE) ------------
compare "divide columns"    "SELECT A / B FROM E WHERE ID = 1"
compare "divide truncates"  "SELECT A / B FROM E WHERE ID = 2"
compare "divide negative"   "SELECT A / B FROM E WHERE ID = 4"
compare "divide toward zero" "SELECT B / A FROM E WHERE ID = 4"
compare "divide literal"    "SELECT 7 / 2 FROM E WHERE ID = 1"
compare "divide NULL"       "SELECT A / B FROM E WHERE ID = 3"
compare "divide then mul"   "SELECT A / B * 2 FROM E WHERE ID = 1"

# --- string concatenation (|| binds tighter, named CONCATENATION) ------
compare "concat columns"    "SELECT S || S FROM E WHERE ID = 1"
compare "concat literal"    "SELECT S || '!' FROM E WHERE ID = 1"
compare "concat both sides" "SELECT '[' || S || ']' FROM E WHERE ID = 2"
compare "concat coerces int" "SELECT A || 'n' FROM E WHERE ID = 1"
compare "concat chains left" "SELECT 'a' || 'b' || 'c' FROM E WHERE ID = 1"
compare "concat NULL"       "SELECT S || NULL FROM E WHERE ID = 1"

# --- CAST(x AS type): integer family and text width, over int/text -----
compare "cast int to varchar" "SELECT CAST(A AS VARCHAR(20)) FROM E WHERE ID = 1"
compare "cast int to char"    "SELECT CAST(A AS CHAR(5)) FROM E WHERE ID = 1"
compare "cast string to int"  "SELECT CAST('100' AS INTEGER) FROM E WHERE ID = 1"
compare "cast trims to int"   "SELECT CAST(' 55 ' AS INTEGER) FROM E WHERE ID = 1"
compare "cast to bigint"      "SELECT CAST(A AS BIGINT) FROM E WHERE ID = 1"
compare "cast to smallint"    "SELECT CAST(A AS SMALLINT) FROM E WHERE ID = 2"
compare "cast negative"       "SELECT CAST(A AS VARCHAR(10)) FROM E WHERE ID = 4"
compare "cast of expr"        "SELECT CAST(A + B AS VARCHAR(10)) FROM E WHERE ID = 1"
compare "cast then concat"    "SELECT CAST(A AS VARCHAR(4)) || '!' FROM E WHERE ID = 1"
compare "cast NULL"           "SELECT CAST(A AS VARCHAR(5)) FROM E WHERE ID = 3"
compare "cast aliased"        "SELECT CAST(A AS INTEGER) AS X FROM E WHERE ID = 1"

# --- CAST over a scaled NUMERIC column: round to int (half away from
#     zero), render with decimals to text (the deferred item now done) ---
compare "cast numeric round up"   "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 1"
compare "cast numeric half to 14" "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 4"
compare "cast numeric neg below"  "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 2"
compare "cast numeric to varchar" "SELECT CAST(N AS VARCHAR(10)) FROM E WHERE ID = 1"
compare "cast numeric neg varchar" "SELECT CAST(N AS VARCHAR(10)) FROM E WHERE ID = 2"
compare "cast numeric NULL"       "SELECT CAST(N AS INTEGER) FROM E WHERE ID = 3"

# --- numeric arithmetic: the engine's dialect-3 scale rules ------------
#     +/- take the finer scale, * and / add the two scales (/ scales the
#     dividend by 10^(-2*s2) then truncates). Column headers ADD/SUBTRACT/
#     MULTIPLY/DIVIDE and values (with their decimal places) both compared.
comparen "num add same scale"   "SELECT N + N AS R FROM E WHERE ID = 1"
comparen "num add finer scale"  "SELECT N + M AS R FROM E WHERE ID = 1"
comparen "num sub"              "SELECT N - M AS R FROM E WHERE ID = 1"
comparen "num add int col"      "SELECT N + A AS R FROM E WHERE ID = 1"
comparen "num add int literal"  "SELECT N + 1 AS R FROM E WHERE ID = 1"
comparen "num mul same scale"   "SELECT N * N AS R FROM E WHERE ID = 1"
comparen "num mul finer scale"  "SELECT N * M AS R FROM E WHERE ID = 1"
comparen "num mul int"          "SELECT N * A AS R FROM E WHERE ID = 1"
comparen "num mul literal"      "SELECT N * 2 AS R FROM E WHERE ID = 1"
comparen "num div same scale"   "SELECT N / M AS R FROM E WHERE ID = 2"
comparen "num div finer scale"  "SELECT N / M AS R FROM E WHERE ID = 1"
comparen "num div int col"      "SELECT N / A AS R FROM E WHERE ID = 1"
comparen "num div literal"      "SELECT N / 4 AS R FROM E WHERE ID = 1"
comparen "num precedence"       "SELECT N + M * 2 AS R FROM E WHERE ID = 1"
comparen "num negate"           "SELECT -N AS R FROM E WHERE ID = 1"
comparen "num header default"   "SELECT N * M FROM E WHERE ID = 1"
comparen "num NULL propagates"  "SELECT N * M AS R FROM E WHERE ID = 3"

# --- decimal literals: scale = written fractional digits (trailing zeros
#     count), and they arithmetic-combine like any numeric operand -------
comparen "declit add"          "SELECT N + 1.5 AS R FROM E WHERE ID = 1"
comparen "declit trailing zero" "SELECT N + 1.50 AS R FROM E WHERE ID = 1"
comparen "declit mul"          "SELECT N * 1.5 AS R FROM E WHERE ID = 1"
comparen "declit div"          "SELECT N / 1.5 AS R FROM E WHERE ID = 1"
comparen "declit both literals" "SELECT 1.5 + 2.25 AS R FROM E WHERE ID = 1"
comparen "declit times int"    "SELECT 1.5 * 2 AS R FROM E WHERE ID = 1"
comparen "declit bare"         "SELECT 1.5 AS R FROM E WHERE ID = 1"

# --- INT128-width results: the engine's dtype-driven widening (probed
#     via SQLDA + getDescDialect3/DSC_multiply_result): * and / promote
#     to INT128 with ANY INT64-ranked operand (BIGINT, NUMERIC(10..18),
#     a past-i32 literal, CAST AS BIGINT, a +'s INT64 result); + and -
#     widen only when an operand already IS INT128. The value comparison
#     doubles as the describe check: node decodes by the announced type,
#     so a wrong width or scale would garble every value. Known
#     node-firebird INT128 decode bugs (inc 26) are dodged: negatives and
#     past-2^53 magnitudes go through CAST AS VARCHAR instead.
comparen "wide mul: BIGINT * literal"   "SELECT ID, K * 2 FROM E ORDER BY ID"
comparen "wide mul: NUMERIC(10,2) * N"  "SELECT ID, U * N FROM E ORDER BY ID"
comparen "wide div: NUMERIC(10,2) / 2"  "SELECT ID, U / 2 FROM E WHERE ID <> 2 ORDER BY ID"
comparen "narrow add: BIGINT + BIGINT"  "SELECT ID, K + K FROM E ORDER BY ID"
comparen "narrow sub: NUMERIC(10,2)-N"  "SELECT ID, U - N FROM E ORDER BY ID"
comparen "wide add: INT128 + 1"         "SELECT ID, I + 1 FROM E ORDER BY ID"
comparen "wide div: INT128 / 2"         "SELECT ID, I / 2 FROM E ORDER BY ID"
comparen "wide declit: 1.5 + INT128"    "SELECT ID, 1.5 + I FROM E ORDER BY ID"
comparen "wide int literal rank"        "SELECT ID, N * 2147483648 FROM E WHERE ID <> 2 ORDER BY ID"
comparen "wide dec literal rank"        "SELECT ID, N * 1234567890.5 FROM E WHERE ID <> 2 ORDER BY ID"
comparen "wide nested add rank"         "SELECT ID, (N + M) * A FROM E WHERE ID <> 4 ORDER BY ID"
comparen "wide cast rank"               "SELECT ID, CAST(N AS BIGINT) * B FROM E WHERE ID <> 2 ORDER BY ID"
comparen "narrow cast rank stays"       "SELECT ID, CAST(N AS INT) * B FROM E WHERE ID <> 2 ORDER BY ID"
comparen "past-i64 value via text"      "SELECT ID, CAST(K * K AS VARCHAR(30)) AS T FROM E ORDER BY ID"
comparen "negative wide via text"       "SELECT ID, CAST(-I * 3 AS VARCHAR(45)) AS T FROM E ORDER BY ID"

# --- multi-byte select-list items: the item parser must not INDEX the
#     item's bytes. Every check here is an ordinary differential; the
#     first two are the statements that used to panic the connection
#     thread (byte 6 of `'ABCDé' || 'x'` is inside the é), and the
#     DECODE block is the control that the six-byte builtin test still
#     recognises what it is for. Run over a UTF8 attachment on BOTH
#     sides so the literals mean characters, not octets.
CH=UTF8
compare  "mb concat literal"      "SELECT 'ABCDé' || 'x' AS X FROM RDB\$DATABASE"
compare  "mb concat unaliased"    "SELECT 'ABCDé' || 'x' FROM RDB\$DATABASE"
compare  "mb concat two-char lit" "SELECT 'é' || 'x' AS X FROM RDB\$DATABASE"
compare  "mb concat column"       "SELECT ID, S8 || '!' AS X FROM MB ORDER BY ID"
compare  "mb upper/lower literal" "SELECT UPPER('ABCDé') AS U, LOWER('ABCDÉ') AS L FROM RDB\$DATABASE"
compare  "mb upper/lower column"  "SELECT ID, UPPER(S8) AS U, LOWER(S8) AS L FROM MB ORDER BY ID"
compare  "mb lengths literal"     "SELECT CHAR_LENGTH('ABCDé') AS C, OCTET_LENGTH('ABCDé') AS O FROM RDB\$DATABASE"
compare  "mb lengths column"      "SELECT ID, CHAR_LENGTH(S8) AS C, OCTET_LENGTH(S8) AS O FROM MB ORDER BY ID"
compare  "mb substring literal"   "SELECT SUBSTRING('ABCDéfg' FROM 4 FOR 3) AS X FROM RDB\$DATABASE"
compare  "mb substring column"    "SELECT ID, SUBSTRING(S8 FROM 2 FOR 2) AS X FROM MB ORDER BY ID"
# the control: DECODE is still recognised (un-aliased it keeps its own
# name even though it desugars to CASE), including with multi-byte
# results and a multi-byte subject, and `DECODE(...) + 1` is still an ADD
compare  "DECODE named DECODE"    "SELECT ID, DECODE(D, 1, 'a', 2, 'b', 'z') FROM MB ORDER BY ID"
compare  "DECODE mb results"      "SELECT ID, DECODE(D, 1, 'ă', 2, 'é', 'ș') FROM MB ORDER BY ID"
compare  "DECODE mb subject"      "SELECT ID, DECODE(S8, 'ABCDé', 'hit', 'miss') AS X FROM MB ORDER BY ID"
compare  "DECODE plus one is ADD" "SELECT ID, DECODE(D, 1, 10, 20) + 1 FROM MB ORDER BY ID"
# a non-breaking space is two bytes and lands the 7th byte mid-character
# too; here BOTH sides refuse - the engine with a conversion error, and
# fire-crab because ABS over text is not on its surface. What is under
# test is that the refusal is an ERROR and not a dead connection.
NBSP=$'\xc2\xa0'
mbrej() { # <label> <select>
    fc=$(node_run "$2")
    is=$("$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$WORK" 2>&1 <<EOF
$2;
EOF
)
    if printf '%s' "$fc" | grep -qi "ERR" && ! printf '%s' "$fc" | grep -q "CONN_ERR" \
       && printf '%s' "$is" | grep -qi "conversion error"; then
        echo "OK   $1 (both reject, connection kept)"
    else
        echo "DIFF $1"
        echo "     isql: $(echo $is)"
        echo "     fc:   $(echo $fc)"
        fail=1
    fi
}
mbrej "mb ABS over NBSP text" "SELECT ABS('${NBSP}2') AS X FROM RDB\$DATABASE"
# liveness: the failure mode was a PANICKED CONNECTION THREAD, so a fresh
# attachment answering after all of the above is the check that counts
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire died on a multi-byte item"; exit 1; }
compare  "alive after multi-byte" "SELECT 1 AS ALIVE FROM RDB\$DATABASE"
grep -q 'panicked' "$LOG" && { echo "FAIL a connection thread panicked"; fail=1; }
CH=""

# --- a multi-byte QUOTED IDENTIFIER: the sixth byte-slicing site ------
# The five sites the earlier audit fixed all sliced a str at a constant
# byte offset and were found by grepping for that. This one is a
# DIFFERENT SHAPE and the grep could not see it: `split_union` walked the
# statement as a Vec<char> and then used the CHARACTER position as a BYTE
# index into the same string, so any multi-byte character anywhere before
# a scan position panicked the connection thread - and a quoted
# identifier may hold ANY character.
#
#   SELECT 1 AS "<two two-byte letters>" FROM RDB$DATABASE
#     -> panicked at "byte index 14 is not a char boundary", then 08006
#        on that statement and on every statement after it
#
# Both sides are asked through isql here, not node-firebird: the
# attachment charset must be varied for real on BOTH sides, and
# node-firebird's attachment charset is its `encoding` option (default
# UTF8) - it ignores `charset` entirely, so a node side cannot be moved
# off UTF8 by the CH the isql side follows. isql is also libfbclient,
# the client that a panicked connection thread has been seen to segfault.
mb_alive() {
    printf 'SELECT 1 AS ALIVE FROM RDB$DATABASE;\n' \
        | "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$WORK" 2>&1 \
        | grep -q '^ *1 *$'
}
mbid() { # <label> <select> - both sides through isql, under $CH
    at() { # <target>
        if [ -n "$CH" ]; then "$ISQL" -q -b -ch "$CH" -user "$U" -pas "$P" "$1"
        else "$ISQL" -q -b -user "$U" -pas "$P" "$1"; fi
    }
    a=$(printf '%s;\n' "$2" | at "127.0.0.1/$PORT:$WORK" 2>&1 | strip | grep -v '^$' \
        | tr -s ' ' | grep -v '^=*$')
    b=$(printf '%s;\n' "$2" | at "$WORK" 2>&1 | strip | grep -v '^$' \
        | tr -s ' ' | grep -v '^=*$')
    if printf '%s' "$a" | grep -q "SQLSTATE"; then
        echo "DIFF [${CH:-NONE}] $1 - fcwire raised: $(printf '%s' "$a" | tr '\n' '|')"
        fail=1
    elif [ "$a" != "$b" ]; then
        echo "DIFF [${CH:-NONE}] $1"
        echo "     isql: $(echo $b)"
        echo "     fc:   $(echo $a)"
        fail=1
    elif ! mb_alive; then
        echo "DIFF [${CH:-NONE}] $1 - the NEXT attachment could not connect"
        fail=1
    else
        echo "OK   [${CH:-NONE}] $1"
    fi
}
MB2=$(printf '\xc4\x83\xc3\xae')          # two two-byte letters
EUR=$(printf '\xe2\x82\xac')              # one three-byte character
for CH in "" UTF8; do
    mbid "quoted alias, multi-byte" "SELECT 1 AS \"$MB2\" FROM RDB\$DATABASE"
    mbid "quoted alias, 3-byte char" "SELECT 1 AS \"$EUR\" FROM RDB\$DATABASE"
    # the same scan on a statement that really IS a union: the cut
    # offsets it hands back are byte offsets into the ORIGINAL text
    mbid "quoted alias over a UNION ALL" \
        "SELECT 1 AS \"${MB2}B\" FROM RDB\$DATABASE UNION ALL SELECT 2 FROM RDB\$DATABASE"
    mbid "multi-byte literal in a UNION branch" \
        "SELECT '$MB2' AS X FROM RDB\$DATABASE UNION ALL SELECT 'x' FROM RDB\$DATABASE"
    mbid "multi-byte identifier AND literal" \
        "SELECT '$MB2' AS \"$MB2\" FROM RDB\$DATABASE"
    mbid "quoted alias, multi-byte, ORDER BY" \
        "SELECT 1 AS \"$MB2\" FROM RDB\$DATABASE ORDER BY 1"
done
CH=""
grep -q 'panicked' "$LOG" && {
    echo "FAIL a connection thread panicked on a multi-byte identifier"; fail=1; }

# --- runtime errors: BOTH the engine and fire-crab reject the row rather
#     than answering. Divide-by-zero is the arithmetic exception (SQLSTATE
#     22012); a bad or too-long CAST is the conversion error (22018).
errck() { # <label> <select> <isql-error-pattern>
    fc=$(node_run "$2")
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<EOF
$2;
EOF
)
    if printf '%s' "$fc" | grep -qi "ERR" \
       && printf '%s' "$is" | grep -qi "$3"; then
        echo "OK   $1 (both reject)"
    else
        echo "DIFF $1"
        echo "     isql: $(echo $is)"
        echo "     fc:   $(echo $fc)"
        fail=1
    fi
}
errck "divide by zero literal" "SELECT A / 0 FROM E WHERE ID = 1"          "divide by zero"
errck "divide by zero column"  "SELECT A / (B - B) FROM E WHERE ID = 1"    "divide by zero"
errck "cast bad string"        "SELECT CAST(S AS INTEGER) FROM E WHERE ID = 1"   "conversion error"
errck "cast too long"          "SELECT CAST(A AS VARCHAR(1)) FROM E WHERE ID = 1" "conversion error"
# an INT64-announced sum past i64 is the runtime integer overflow (22003)
errck "int64 add overflow"     "SELECT K + 9223372036854775807 FROM E WHERE ID = 1" "Integer overflow"

exit $fail
