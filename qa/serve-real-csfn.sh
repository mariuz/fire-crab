#!/bin/bash
# CHARSET-AWARE STRING FUNCTIONS: a value is cased, hashed and padded IN
# ITS OWN CHARACTER SET, and every operand converts INTO the result's.
#
# Measured on engine 2182 under NONE, UTF8 and WIN1252 attachments (the
# same statement, the same rows, three `-ch`), and fixed:
#
#   * LOWER / UPPER of a LITERAL takes the ATTACHMENT set's case law,
#     because a literal is a value of that set: `LOWER('ÄÖÜ')` (source
#     octets C3 84 C3 96 C3 9C) comes back UNCHANGED under NONE (a byte
#     carrier cases ASCII only), E3 84 E3 96 E3 9C under WIN1252 (its
#     table lowers 0xC3), and the three lower-case letters under UTF8.
#     This server cased the carrier chars by Unicode and answered the
#     WIN1252 bytes under NONE.  Same seam as a column (UpperCs /
#     LowerCs), now reached from any expression whose set is known: a
#     concatenation, a CAST to a named set, an OCTETS operand.
#   * HASH hashes the value's STORED BYTES in ITS OWN set - never the
#     attachment's, never the UTF-8 spelling of the decoded text: a
#     WIN1252 column holding C0 C9 CE is 52574 under all three
#     attachments; the same letters stored as UTF-8 octets are
#     213697982; a NONE 0xE9 is 233; a blob's payload bytes.  This
#     server hashed the UTF-8 of the decoded chars (919206616215896077
#     for a WIN1252 column of UTF-8 octets).  A NON-TEXT operand hashes
#     its engine text form (MOV_make_string2): HASH(10) is HASH('10'),
#     HASH(1.5e0) is HASH('1.500000000000000'), HASH(TRUE) HASH('TRUE'),
#     a DATE its 'YYYY-MM-DD' - every one equal to HASH(CAST(x AS
#     VARCHAR(30))) - where this refused them all.  HASH(x USING CRC32)
#     is an INTEGER: libtomcrypt's CRC-32 stored big-endian and read as a
#     native long, so 'abc' is -1035918283 (0xC2412435, the byte-swap of
#     0x352441C2).  CRC32 is the ONLY algorithm: MD5 / SHA1 / SHA256 /
#     SHA512 / FOO raise *Invalid HASH algorithm X* at prepare.
#   * BIT_LENGTH is eight times OCTET_LENGTH (INTEGER; BIGINT over a
#     blob) - it was *Function unknown* here.
#   * LPAD / RPAD / REPLACE / TRIM / POSITION CONVERT EVERY OTHER OPERAND
#     INTO THE SET THE FUNCTION RUNS IN (each evl* MOV_make_string2's
#     into it): LPAD/RPAD and TRIM run in their VALUE's set, POSITION and
#     REPLACE in the SEARCHED string's (evlReplace: values[0]'s text
#     type; only REPLACE's DESCRIBE negotiates its three).  So `LPAD(N,
#     8, 'Ä')` over a NONE column is NONE with the literal's OCTETS as
#     the pad - C3 84 - under a UTF8 attachment; this server padded with
#     the carrier char C4, and under a WIN1252 attachment ('„' has no
#     carrier image) it DROPPED THE CONNECTION (08006) mid-row.
#     `POSITION(<NONE C3 89> IN U)` is 2 - the octets read as the UTF8
#     'É' - not the byte offset 3.
#   * A VALUE CAN BE IN A SET ITS DESCRIBE DOES NOT NAME, and the engine
#     keeps the two apart: `REPLACE(N, 'É', 'e')` RUNS IN NONE (the
#     literal's octets byte-copied into it) and describes the negotiated
#     UTF8 / WIN1252.  Every consumer that reads the value's type at run
#     time sees NONE - `CHAR_LENGTH` is 5 / 1 for the two rows, `HASH`
#     hashes the NONE bytes (233 for the E9 row), `LOWER` cases ASCII
#     only (C3 80 65 C3 8E), `= N` is a byte compare (rows 2 and 3 - and
#     `<> N` row 1), a nested LPAD pads BYTES, SUBSTRING cuts them - and
#     only DELIVERY moves the value into the announced set, a byte copy
#     that validates: `C3 80 65 C3 8E` arrives, the E9 row is *Malformed
#     string* (22000) under a UTF8 attachment and the E9 itself under
#     WIN1252.  A concatenation negotiates its run-time set from its
#     operands' run-time sets (`REPLACE(N, 'É', 'e') || W1` under UTF8
#     is a WIN1252 value, delivered as C3 83 E2 82 AC 65 ...); a
#     conditional MOVES the chosen branch into its negotiated set
#     (`COALESCE(N, 'ÄÖÜ')` under UTF8 delivers the NONE column's
#     letters, `OCTET_LENGTH` of it 6, `HASH(COALESCE(N, W1))` the same
#     bytes 213697982; `IIF(ID = 1, W1, 'Ω')` is 22018 for the row that
#     takes the literal); an unqualified CAST moves a NONE source into
#     the attachment's set; MAX and a GROUP BY key fold in the announced
#     set.  This server first ran the REPLACE in byte space and shipped
#     the carrier chars' UTF-8 spelling (C3 83 C2 80 65 ...), then read
#     N AS UTF8 (`CHAR_LENGTH` 3 for the engine's 5, *Malformed string*
#     for every consumer of the E9 row); `COALESCE(N, 'ÄÖÜ')` and
#     `LOWER(CAST(N AS VARCHAR(10)))` under WIN1252 DROPPED THE CONNECTION
#     (08006).  ASCII is a real set in the engine: `REPLACE(A, 'É', 'e')`
#     is 22018 under a real attachment and *Malformed string* under NONE,
#     and `A || 'x'` / `COALESCE(A, 'x')` under NONE describe ASCII (the
#     NONE literal yields to it).  Under a NONE attachment a literal that
#     is the VALUE operand names the set the call runs in, and the real
#     operand is byte-copied into it: `LPAD('ab', 5, W1)` is C3 80 C3 ab
#     over a WIN1252 column holding UTF-8 octets, `TRIM(W1 FROM 'ÀÉÎx')`
#     the literal unchanged - this server re-spelled the literal into the
#     real set and answered its characters re-encoded, then dropped the
#     connection on the LPAD.
#   * A LITERAL's DESCRIBED WIDTH under a tabled single-byte attachment
#     (WIN1252, ISO8859_1) is its octet count: 'Ä' is TEXT(2), 'ÄÖÜ'
#     TEXT(6).  This server counted the UTF-8 spelling of the DECODED
#     chars ('„' is three bytes) and announced 5 and 14, padding the
#     value to that width.
#
#   * A SIMPLE CASE / DECODE RETURNS ITS CHOSEN BRANCH AS IT IS, in the
#     branch's own set (DecodeNode has no cast; the searched CASE and IIF
#     do): `LOWER(DECODE(ID, 1, W1, 'Ω'))` under UTF8 is 'àéî' for the
#     WIN1252 row and 'ω' for the rest, HASH 52574 and 3465, CHAR_LENGTH
#     3 and 1 - and under NONE the literal's bytes case ASCII only (CE A9).
#     A function that reads its operand's set distributes over the
#     branches; delivered, each branch moves into the client's field from
#     its own set (a NONE `E9` branch is *Malformed string* under UTF8).
#     This server moved every branch into the negotiated set first and
#     answered 22018 for every row that took the literal; MAX over it
#     still folds in the negotiated set (22018, as the engine).  A
#     comparison over such a CASE where the negotiated reading could
#     change the answer REFUSES (never answers: `CASE ID WHEN 2 THEN W1
#     ELSE U END = N` counts 1 on the engine and counted 0 here).
#
# RECORDED, not fixed: the `_WIN1252 'x'` / `_UTF8 'x'` INTRODUCER on a
# literal refuses to prepare (a bare Dynamic SQL Error), in HASH, LOWER
# and POSITION alike - never a wrong value.  `HASH('a', 'b')`, `HASH()`,
# `HASH('abc' USING)` and `HASH('abc' USING 'CRC32')` refuse with a bare
# 42000 where the engine spells its syntax error (`Token unknown`).
#
# Usage: qa/serve-real-csfn.sh [port]   (default 5830)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5830}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/csfn-eng.fdb"; FC="$D/csfn-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

# every non-ASCII value is written as a HEX INTRODUCER so the fixture
# means the same bytes whatever isql's own charset is
{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE TU (ID INTEGER,
                 W1 VARCHAR(20) CHARACTER SET WIN1252,
                 U VARCHAR(20) CHARACTER SET UTF8,
                 N VARCHAR(20) CHARACTER SET NONE,
                 O VARCHAR(20) CHARACTER SET OCTETS,
                 A VARCHAR(20) CHARACTER SET ASCII,
                 I1 VARCHAR(20) CHARACTER SET ISO8859_1,
                 C5 CHAR(5) CHARACTER SET WIN1252,
                 K INTEGER, DN NUMERIC(9,2), F DOUBLE PRECISION, DT DATE, B BOOLEAN,
                 N38 NUMERIC(38,3), DF DECFLOAT,
                 BT BLOB SUB_TYPE TEXT CHARACTER SET WIN1252, BB BLOB SUB_TYPE 0);
-- row 1: the three letters A-grave E-acute I-circumflex, in each column's own set
INSERT INTO TU VALUES (1, _WIN1252 x'C0C9CE', _UTF8 x'C380C389C38E', _NONE x'C380C389C38E', x'C380C389C38E',
                       'AbC', _ISO8859_1 x'C0C9CE', _WIN1252 x'C0C9', 10, 1.50, 1.5, DATE '2020-01-02', TRUE,
                       12345678901234567890.123, 1.5, _WIN1252 x'C0C9CE', x'C0C9CE');
-- row 2: the WIN1252 column holds the letters' UTF-8 OCTETS (what an
-- INSERT under a NONE attachment stores); the carriers hold a lone E9
INSERT INTO TU VALUES (2, _WIN1252 x'C380C389C38E', _UTF8 x'616263', _NONE x'E9', x'E9',
                       'xyz', _ISO8859_1 x'E9', _WIN1252 x'61', 123, 0.05, 2.5e-3, DATE '2021-12-31', FALSE,
                       -0.001, -0.1, 'abc', x'616263');
-- row 3: WIN1252 9F 83 (0x83 has no upper case), UTF8 eszett, empties
INSERT INTO TU VALUES (3, _WIN1252 x'9F83', _UTF8 x'C39F', _NONE x'', x'', '', _ISO8859_1 x'FF', NULL,
                       -7, -12.34, -0.1, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO TU VALUES (4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/csfn-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/csfn-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/csfn-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-csfn-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session) under an ATTACHMENT CHARSET, its lines squeezed
# and joined; errors included; every byte past ASCII spelled <xx> so the
# pinned values are the OCTETS the client received (isql prints the
# value as the attachment set delivers it)
sess() { # <dsn> <charset> <script>
    printf '%s\n' "$3" | timeout 25 "$ISQL" -q -ch "$2" -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' \
    | perl -pe 's/([\x80-\xff])/sprintf("<%02x>",ord($1))/ge' | paste -sd'|'; }
# the describe: type, length, charset, nullability
dsc() { # <dsn> <charset> <statement>
    printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$3" | timeout 25 "$ISQL" -q -ch "$2" -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <charset> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2" "$3"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2" "$3")
    if [ -z "$ev" ]; then echo "FAIL $1 [$2] - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 [$2]"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$2] [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <charset> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2" "$3"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2" "$3")
    if [ "$ev" != "$4" ]; then echo "FAIL $1 [$2] - THE ENGINE ANSWERS [$ev], not the pinned [$4]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 [$2]"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$2] [$ev]"; fi
}
# the same describe, pinned
dpin() { # <label> <charset> <statement> <engine-describe>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2" "$3"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2" "$3")
    if [ "$ed" != "$4" ]; then echo "FAIL $1 [$2] - THE ENGINE DESCRIBES [$ed], not the pinned [$4]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1 [$2]"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$2] [$ed]"; fi
}
# the engine answers, this server REFUSES - recorded (never a wrong answer)
refused() { # <label> <charset> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2" "$3"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2" "$3")
    if [ "${ev#*SQLSTATE}" != "$ev" ]; then echo "FAIL $1 [$2] - the engine raises now [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 [$2] - IT AGREES NOW [$ev]; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 [$2] - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$2] (recorded: engine [${ev:0:60}], this server refuses)"; fi
}
# both raise, with different spellings - recorded (an error either way)
differs() { # <label> <charset> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2" "$3"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2" "$3")
    if [ "${ev#*SQLSTATE}" = "$ev" ]; then echo "FAIL $1 [$2] - the engine answers now [$ev]"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 [$2] - A WRONG ANSWER, not an error"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 [$2] - IT AGREES NOW [$ev]; promote the cell"; fail=1
    else echo "OK   $1 [$2] (recorded: both raise, engine [${ev:0:70}])"; fi
}
# the session must SURVIVE a cell: the same connection answers again
alive() { # <label> <charset> <statement>
    ran=$((ran + 1))
    local out
    out=$(printf 'SET LIST ON;\n%s\nSELECT 42 AS STILL_HERE FROM RDB$DATABASE;\n' "$3" |
        timeout 25 "$ISQL" -q -ch "$2" -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1)
    case "$out" in
        *08006*) echo "FAIL $1 [$2] - the connection DROPPED (08006)"; fail=1 ;;
        *STILL_HERE*42*) echo "OK   $1 [$2] the connection survives and answers again" ;;
        *) echo "FAIL $1 [$2] - the session did not answer the follow-up"; fail=1 ;;
    esac
}

echo "--- 1. LOWER / UPPER OF A LITERAL: the ATTACHMENT set's case law"
pin "1 LOWER('ÄÖÜ')" NONE "SET LIST ON; SELECT LOWER('ÄÖÜ') L FROM RDB\$DATABASE;" "L <c3><84><c3><96><c3><9c>"
pin "1 LOWER('ÄÖÜ')" UTF8 "SET LIST ON; SELECT LOWER('ÄÖÜ') L FROM RDB\$DATABASE;" "L <c3><a4><c3><b6><c3><bc>"
pin "1 LOWER('ÄÖÜ')" WIN1252 "SET LIST ON; SELECT LOWER('ÄÖÜ') L FROM RDB\$DATABASE;" "L <e3><84><e3><96><e3><9c>"
pin "1 UPPER('äöü')" NONE "SET LIST ON; SELECT UPPER('äöü') L FROM RDB\$DATABASE;" "L <c3><a4><c3><b6><c3><bc>"
pin "1 UPPER('äöü')" UTF8 "SET LIST ON; SELECT UPPER('äöü') L FROM RDB\$DATABASE;" "L <c3><84><c3><96><c3><9c>"
pin "1 UPPER('äöü')" WIN1252 "SET LIST ON; SELECT UPPER('äöü') L FROM RDB\$DATABASE;" "L <c3><a4><c3><b6><c3><bc>"
pin "1 LOWER('ÄÖÜ' || 'x')" NONE "SET LIST ON; SELECT LOWER('ÄÖÜ' || 'x') L FROM RDB\$DATABASE;" "L <c3><84><c3><96><c3><9c>x"
pin "1 LOWER('ÄÖÜ' || 'x')" UTF8 "SET LIST ON; SELECT LOWER('ÄÖÜ' || 'x') L FROM RDB\$DATABASE;" "L <c3><a4><c3><b6><c3><bc>x"
pin "1 LOWER('ÄÖÜ' || 'x')" WIN1252 "SET LIST ON; SELECT LOWER('ÄÖÜ' || 'x') L FROM RDB\$DATABASE;" "L <e3><84><e3><96><e3><9c>x"
pin "1 UPPER(CAST('äöü' AS VARCHAR(10) CHARACTER SET WIN1252))" NONE "SET LIST ON; SELECT UPPER(CAST('äöü' AS VARCHAR(10) CHARACTER SET WIN1252)) L FROM RDB\$DATABASE;" "L <c3><a4><c3><b6><c3><bc>"
pin "1 UPPER(CAST('äöü' AS VARCHAR(10) CHARACTER SET WIN1252))" UTF8 "SET LIST ON; SELECT UPPER(CAST('äöü' AS VARCHAR(10) CHARACTER SET WIN1252)) L FROM RDB\$DATABASE;" "L <c3><84><c3><96><c3><9c>"
pin "1 UPPER(CAST('äöü' AS VARCHAR(10) CHARACTER SET WIN1252))" WIN1252 "SET LIST ON; SELECT UPPER(CAST('äöü' AS VARCHAR(10) CHARACTER SET WIN1252)) L FROM RDB\$DATABASE;" "L <c3><a4><c3><b6><c3><bc>"
pin "1 LOWER(x'C384') - OCTETS has no case" NONE "SET LIST ON; SELECT LOWER(x'C384') L FROM RDB\$DATABASE;" "L C384"
pin "1 LOWER(x'C384') - OCTETS has no case" UTF8 "SET LIST ON; SELECT LOWER(x'C384') L FROM RDB\$DATABASE;" "L C384"
pin "1 LOWER(x'C384') - OCTETS has no case" WIN1252 "SET LIST ON; SELECT LOWER(x'C384') L FROM RDB\$DATABASE;" "L C384"
pin "1 LOWER(CAST('ÄÖÜ' AS VARCHAR(10) CHARACTER SET NONE))" NONE "SET LIST ON; SELECT LOWER(CAST('ÄÖÜ' AS VARCHAR(10) CHARACTER SET NONE)) L FROM RDB\$DATABASE;" "L <c3><84><c3><96><c3><9c>"
pin "1 LOWER(CAST('ÄÖÜ' AS VARCHAR(10) CHARACTER SET NONE))" UTF8 "SET LIST ON; SELECT LOWER(CAST('ÄÖÜ' AS VARCHAR(10) CHARACTER SET NONE)) L FROM RDB\$DATABASE;" "L <c3><84><c3><96><c3><9c>"
pin "1 LOWER(CAST('ÄÖÜ' AS VARCHAR(10) CHARACTER SET NONE))" WIN1252 "SET LIST ON; SELECT LOWER(CAST('ÄÖÜ' AS VARCHAR(10) CHARACTER SET NONE)) L FROM RDB\$DATABASE;" "L <c3><84><c3><96><c3><9c>"
pin "1 CONTROL LOWER('ABC'), UPPER('abc'), LOWER(NULL), LOWER('')" NONE "SET LIST ON; SELECT LOWER('ABC') L1, UPPER('abc') U1, LOWER(NULL) L2, LOWER('') L3 FROM RDB\$DATABASE;" "L1 abc|U1 ABC|L2 <null>|L3"
pin "1 CONTROL LOWER('ABC'), UPPER('abc'), LOWER(NULL), LOWER('')" UTF8 "SET LIST ON; SELECT LOWER('ABC') L1, UPPER('abc') U1, LOWER(NULL) L2, LOWER('') L3 FROM RDB\$DATABASE;" "L1 abc|U1 ABC|L2 <null>|L3"
pin "1 CONTROL LOWER('ABC'), UPPER('abc'), LOWER(NULL), LOWER('')" WIN1252 "SET LIST ON; SELECT LOWER('ABC') L1, UPPER('abc') U1, LOWER(NULL) L2, LOWER('') L3 FROM RDB\$DATABASE;" "L1 abc|U1 ABC|L2 <null>|L3"
pin "1 CONTROL the columns: LOWER/UPPER of W1, N, O, A, I1, U" NONE "SET LIST ON; SELECT ID, LOWER(W1) LW, UPPER(W1) UW, LOWER(N) LN, UPPER(N) UN, LOWER(O) LO, UPPER(O) UO, LOWER(A) LA, UPPER(A) UA, LOWER(I1) LI, UPPER(I1) UI, LOWER(U) LU, UPPER(U) UU FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|LW <e0><e9><ee>|UW <c0><c9><ce>|LN <c3><80><c3><89><c3><8e>|UN <c3><80><c3><89><c3><8e>|LO C380C389C38E|UO C380C389C38E|LA abc|UA ABC|LI <e0><e9><ee>|UI <c0><c9><ce>|LU <c3><a0><c3><a9><c3><ae>|UU <c3><80><c3><89><c3><8e>|ID 2|LW <e3><80><e3><89><e3><9e>|UW <c3><80><c3><89><c3><8e>|LN <e9>|UN <e9>|LO E9|UO E9|LA xyz|UA XYZ|LI <e9>|UI <c9>|LU abc|UU ABC"
pin "1 CONTROL the columns: LOWER/UPPER of W1, N, O, A, I1, U" UTF8 "SET LIST ON; SELECT ID, LOWER(W1) LW, UPPER(W1) UW, LOWER(N) LN, UPPER(N) UN, LOWER(O) LO, UPPER(O) UO, LOWER(A) LA, UPPER(A) UA, LOWER(I1) LI, UPPER(I1) UI, LOWER(U) LU, UPPER(U) UU FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|LW <c3><a0><c3><a9><c3><ae>|UW <c3><80><c3><89><c3><8e>|LN <c3><80><c3><89><c3><8e>|UN <c3><80><c3><89><c3><8e>|LO C380C389C38E|UO C380C389C38E|LA abc|UA ABC|LI <c3><a0><c3><a9><c3><ae>|UI <c3><80><c3><89><c3><8e>|LU <c3><a0><c3><a9><c3><ae>|UU <c3><80><c3><89><c3><8e>|ID 2|LW <c3><a3><e2><82><ac><c3><a3><e2><80><b0><c3><a3><c5><be>|UW <c3><83><e2><82><ac><c3><83><e2><80><b0><c3><83><c5><bd>|LN <e9>|UN <e9>|LO E9|UO E9|LA xyz|UA XYZ|LI <c3><a9>|UI <c3><89>|LU abc|UU ABC"
pin "1 CONTROL the columns: LOWER/UPPER of W1, N, O, A, I1, U" WIN1252 "SET LIST ON; SELECT ID, LOWER(W1) LW, UPPER(W1) UW, LOWER(N) LN, UPPER(N) UN, LOWER(O) LO, UPPER(O) UO, LOWER(A) LA, UPPER(A) UA, LOWER(I1) LI, UPPER(I1) UI, LOWER(U) LU, UPPER(U) UU FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|LW <e0><e9><ee>|UW <c0><c9><ce>|LN <c3><80><c3><89><c3><8e>|UN <c3><80><c3><89><c3><8e>|LO C380C389C38E|UO C380C389C38E|LA abc|UA ABC|LI <e0><e9><ee>|UI <c0><c9><ce>|LU <e0><e9><ee>|UU <c0><c9><ce>|ID 2|LW <e3><80><e3><89><e3><9e>|UW <c3><80><c3><89><c3><8e>|LN <e9>|UN <e9>|LO E9|UO E9|LA xyz|UA XYZ|LI <e9>|UI <c9>|LU abc|UU ABC"
pin "1 CONTROL UPPER over WIN1252 0x83 raises 22018 per row" NONE "SET LIST ON; SELECT UPPER(W1) UW FROM TU WHERE ID = 3;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "1 CONTROL UPPER over WIN1252 0x83 raises 22018 per row" UTF8 "SET LIST ON; SELECT UPPER(W1) UW FROM TU WHERE ID = 3;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "1 CONTROL UPPER over WIN1252 0x83 raises 22018 per row" WIN1252 "SET LIST ON; SELECT UPPER(W1) UW FROM TU WHERE ID = 3;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "1 WHERE LOWER(N) = N counts the NONE rows a carrier leaves alone" NONE "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE LOWER(N) = N;" "C 3"
pin "1 WHERE LOWER(N) = N counts the NONE rows a carrier leaves alone" UTF8 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE LOWER(N) = N;" "C 3"
pin "1 WHERE LOWER(N) = N counts the NONE rows a carrier leaves alone" WIN1252 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE LOWER(N) = N;" "C 3"

echo "--- 2. HASH: the value's STORED bytes in ITS OWN set"
pin "2 HASH of each set's column" NONE "SET LIST ON; SELECT ID, HASH(W1) HW, HASH(U) HU, HASH(N) HN, HASH(O) HO, HASH(A) HA, HASH(I1) HI, HASH(C5) HC FROM TU ORDER BY ID;" "ID 1|HW 52574|HU 213697982|HN 213697982|HO 213697982|HA 18275|HI 52574|HC 13414944|ID 2|HW 213697982|HU 26499|HN 233|HO 233|HA 32778|HI 233|HC 6496800|ID 3|HW 2675|HU 3279|HN 0|HO 0|HA 0|HI 255|HC <null>|ID 4|HW <null>|HU <null>|HN <null>|HO <null>|HA <null>|HI <null>|HC <null>"
pin "2 HASH of each set's column" UTF8 "SET LIST ON; SELECT ID, HASH(W1) HW, HASH(U) HU, HASH(N) HN, HASH(O) HO, HASH(A) HA, HASH(I1) HI, HASH(C5) HC FROM TU ORDER BY ID;" "ID 1|HW 52574|HU 213697982|HN 213697982|HO 213697982|HA 18275|HI 52574|HC 13414944|ID 2|HW 213697982|HU 26499|HN 233|HO 233|HA 32778|HI 233|HC 6496800|ID 3|HW 2675|HU 3279|HN 0|HO 0|HA 0|HI 255|HC <null>|ID 4|HW <null>|HU <null>|HN <null>|HO <null>|HA <null>|HI <null>|HC <null>"
pin "2 HASH of each set's column" WIN1252 "SET LIST ON; SELECT ID, HASH(W1) HW, HASH(U) HU, HASH(N) HN, HASH(O) HO, HASH(A) HA, HASH(I1) HI, HASH(C5) HC FROM TU ORDER BY ID;" "ID 1|HW 52574|HU 213697982|HN 213697982|HO 213697982|HA 18275|HI 52574|HC 13414944|ID 2|HW 213697982|HU 26499|HN 233|HO 233|HA 32778|HI 233|HC 6496800|ID 3|HW 2675|HU 3279|HN 0|HO 0|HA 0|HI 255|HC <null>|ID 4|HW <null>|HU <null>|HN <null>|HO <null>|HA <null>|HI <null>|HC <null>"
pin "2 HASH of a non-text column: its engine text form" NONE "SET LIST ON; SELECT ID, HASH(K) HK, HASH(DN) HD, HASH(F) HF, HASH(DT) HDT, HASH(B) HB, HASH(N38) H38, HASH(DF) HDF FROM TU ORDER BY ID;" "ID 1|HK 832|HD 213376|HF 590872271110997792|HDT 3656409890866|HB 366485|H38 917216118329131107|HDF 13333|ID 2|HK 13395|HD 209205|HF 590872271057453152|HDT 3656426737761|HB 4874613|H38 50533169|HDF 197393|ID 3|HK 775|HD 50614628|HF 230584300918211184|HDT <null>|HB <null>|H38 <null>|HDF <null>|ID 4|HK <null>|HD <null>|HF <null>|HDT <null>|HB <null>|H38 <null>|HDF <null>"
pin "2 HASH of a non-text column: its engine text form" UTF8 "SET LIST ON; SELECT ID, HASH(K) HK, HASH(DN) HD, HASH(F) HF, HASH(DT) HDT, HASH(B) HB, HASH(N38) H38, HASH(DF) HDF FROM TU ORDER BY ID;" "ID 1|HK 832|HD 213376|HF 590872271110997792|HDT 3656409890866|HB 366485|H38 917216118329131107|HDF 13333|ID 2|HK 13395|HD 209205|HF 590872271057453152|HDT 3656426737761|HB 4874613|H38 50533169|HDF 197393|ID 3|HK 775|HD 50614628|HF 230584300918211184|HDT <null>|HB <null>|H38 <null>|HDF <null>|ID 4|HK <null>|HD <null>|HF <null>|HDT <null>|HB <null>|H38 <null>|HDF <null>"
pin "2 HASH of a non-text column: its engine text form" WIN1252 "SET LIST ON; SELECT ID, HASH(K) HK, HASH(DN) HD, HASH(F) HF, HASH(DT) HDT, HASH(B) HB, HASH(N38) H38, HASH(DF) HDF FROM TU ORDER BY ID;" "ID 1|HK 832|HD 213376|HF 590872271110997792|HDT 3656409890866|HB 366485|H38 917216118329131107|HDF 13333|ID 2|HK 13395|HD 209205|HF 590872271057453152|HDT 3656426737761|HB 4874613|H38 50533169|HDF 197393|ID 3|HK 775|HD 50614628|HF 230584300918211184|HDT <null>|HB <null>|H38 <null>|HDF <null>|ID 4|HK <null>|HD <null>|HF <null>|HDT <null>|HB <null>|H38 <null>|HDF <null>"
pin "2 HASH of a blob: the payload bytes" NONE "SET LIST ON; SELECT ID, HASH(BT) HT, HASH(BB) HB FROM TU ORDER BY ID;" "ID 1|HT 52574|HB 52574|ID 2|HT 26499|HB 26499|ID 3|HT <null>|HB <null>|ID 4|HT <null>|HB <null>"
pin "2 HASH of a blob: the payload bytes" UTF8 "SET LIST ON; SELECT ID, HASH(BT) HT, HASH(BB) HB FROM TU ORDER BY ID;" "ID 1|HT 52574|HB 52574|ID 2|HT 26499|HB 26499|ID 3|HT <null>|HB <null>|ID 4|HT <null>|HB <null>"
pin "2 HASH of a blob: the payload bytes" WIN1252 "SET LIST ON; SELECT ID, HASH(BT) HT, HASH(BB) HB FROM TU ORDER BY ID;" "ID 1|HT 52574|HB 52574|ID 2|HT 26499|HB 26499|ID 3|HT <null>|HB <null>|ID 4|HT <null>|HB <null>"
pin "2 HASH of literals and expressions" NONE "SET LIST ON; SELECT HASH('ÀÉÎ') HLIT, HASH('ab'||'c') HCAT, HASH(CAST('ÀÉ' AS VARCHAR(10) CHARACTER SET WIN1252)) HCAST, HASH(CAST('ab' AS VARCHAR(5) CHARACTER SET OCTETS)) HOCT, HASH('') HE, HASH(x'C3') HX, HASH(NULL) HN FROM RDB\$DATABASE;" "HLIT 213697982|HCAT 26499|HCAST 834745|HOCT 1650|HE 0|HX 195|HN <null>"
pin "2 HASH of literals and expressions" UTF8 "SET LIST ON; SELECT HASH('ÀÉÎ') HLIT, HASH('ab'||'c') HCAT, HASH(CAST('ÀÉ' AS VARCHAR(10) CHARACTER SET WIN1252)) HCAST, HASH(CAST('ab' AS VARCHAR(5) CHARACTER SET OCTETS)) HOCT, HASH('') HE, HASH(x'C3') HX, HASH(NULL) HN FROM RDB\$DATABASE;" "HLIT 213697982|HCAT 26499|HCAST 3273|HOCT 1650|HE 0|HX 195|HN <null>"
pin "2 HASH of literals and expressions" WIN1252 "SET LIST ON; SELECT HASH('ÀÉÎ') HLIT, HASH('ab'||'c') HCAT, HASH(CAST('ÀÉ' AS VARCHAR(10) CHARACTER SET WIN1252)) HCAST, HASH(CAST('ab' AS VARCHAR(5) CHARACTER SET OCTETS)) HOCT, HASH('') HE, HASH(x'C3') HX, HASH(NULL) HN FROM RDB\$DATABASE;" "HLIT 213697982|HCAT 26499|HCAST 834745|HOCT 1650|HE 0|HX 195|HN <null>"
pin "2 HASH of a number, a date, a boolean, a timestamp literal" NONE "SET LIST ON; SELECT HASH(123) H1, HASH(1.50) H2, HASH(1.5e0) H3, HASH(-7) H4, HASH(DATE '2020-01-02') H5, HASH(TRUE) H6, HASH(TIMESTAMP '2020-01-02 03:04:05.6') H7, HASH(TIME '03:04:05') H8, HASH(CAST(1 AS BIGINT)) H9 FROM RDB\$DATABASE;" "H1 13395|H2 213376|H3 590872271110997792|H4 775|H5 3656409890866|H6 366485|H7 302706977895797504|H8 14475310351332144|H9 49"
pin "2 HASH of a number, a date, a boolean, a timestamp literal" UTF8 "SET LIST ON; SELECT HASH(123) H1, HASH(1.50) H2, HASH(1.5e0) H3, HASH(-7) H4, HASH(DATE '2020-01-02') H5, HASH(TRUE) H6, HASH(TIMESTAMP '2020-01-02 03:04:05.6') H7, HASH(TIME '03:04:05') H8, HASH(CAST(1 AS BIGINT)) H9 FROM RDB\$DATABASE;" "H1 13395|H2 213376|H3 590872271110997792|H4 775|H5 3656409890866|H6 366485|H7 302706977895797504|H8 14475310351332144|H9 49"
pin "2 HASH of a number, a date, a boolean, a timestamp literal" WIN1252 "SET LIST ON; SELECT HASH(123) H1, HASH(1.50) H2, HASH(1.5e0) H3, HASH(-7) H4, HASH(DATE '2020-01-02') H5, HASH(TRUE) H6, HASH(TIMESTAMP '2020-01-02 03:04:05.6') H7, HASH(TIME '03:04:05') H8, HASH(CAST(1 AS BIGINT)) H9 FROM RDB\$DATABASE;" "H1 13395|H2 213376|H3 590872271110997792|H4 775|H5 3656409890866|H6 366485|H7 302706977895797504|H8 14475310351332144|H9 49"
pin "2 HASH(x) = HASH(CAST(x AS VARCHAR(40))) for every non-text kind" NONE "SET LIST ON; SELECT HASH(F) = HASH(CAST(F AS VARCHAR(40)) ) E1, HASH(DT) = HASH(CAST(DT AS VARCHAR(40))) E2, HASH(DN) = HASH(CAST(DN AS VARCHAR(40))) E3, HASH(B) = HASH(CAST(B AS VARCHAR(40))) E4, HASH(K) = HASH(CAST(K AS VARCHAR(40))) E5, HASH(DF) = HASH(CAST(DF AS VARCHAR(50))) E6, HASH(N38) = HASH(CAST(N38 AS VARCHAR(50))) E7 FROM TU WHERE ID = 1;" "E1 <true>|E2 <true>|E3 <true>|E4 <true>|E5 <true>|E6 <true>|E7 <true>"
pin "2 HASH(x) = HASH(CAST(x AS VARCHAR(40))) for every non-text kind" UTF8 "SET LIST ON; SELECT HASH(F) = HASH(CAST(F AS VARCHAR(40)) ) E1, HASH(DT) = HASH(CAST(DT AS VARCHAR(40))) E2, HASH(DN) = HASH(CAST(DN AS VARCHAR(40))) E3, HASH(B) = HASH(CAST(B AS VARCHAR(40))) E4, HASH(K) = HASH(CAST(K AS VARCHAR(40))) E5, HASH(DF) = HASH(CAST(DF AS VARCHAR(50))) E6, HASH(N38) = HASH(CAST(N38 AS VARCHAR(50))) E7 FROM TU WHERE ID = 1;" "E1 <true>|E2 <true>|E3 <true>|E4 <true>|E5 <true>|E6 <true>|E7 <true>"
pin "2 HASH(x) = HASH(CAST(x AS VARCHAR(40))) for every non-text kind" WIN1252 "SET LIST ON; SELECT HASH(F) = HASH(CAST(F AS VARCHAR(40)) ) E1, HASH(DT) = HASH(CAST(DT AS VARCHAR(40))) E2, HASH(DN) = HASH(CAST(DN AS VARCHAR(40))) E3, HASH(B) = HASH(CAST(B AS VARCHAR(40))) E4, HASH(K) = HASH(CAST(K AS VARCHAR(40))) E5, HASH(DF) = HASH(CAST(DF AS VARCHAR(50))) E6, HASH(N38) = HASH(CAST(N38 AS VARCHAR(50))) E7 FROM TU WHERE ID = 1;" "E1 <true>|E2 <true>|E3 <true>|E4 <true>|E5 <true>|E6 <true>|E7 <true>"
pin "2 HASH of an expression over a carrier: UPPER(N), N || W1" NONE "SET LIST ON; SELECT ID, HASH(UPPER(N)) H1, HASH(N || W1) H2, HASH(W1 || U) H3 FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|H1 213697982|H2 875306986846|H3 215395678|ID 2|H1 233|H2 4122789310|H3 875306960771"
pin "2 HASH of an expression over a carrier: UPPER(N), N || W1" UTF8 "SET LIST ON; SELECT ID, HASH(UPPER(N)) H1, HASH(N || W1) H2, HASH(W1 || U) H3 FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|H1 213697982|H2 875306986846|H3 215395678|ID 2|H1 233|H2 4122789310|H3 875306960771"
pin "2 HASH of an expression over a carrier: UPPER(N), N || W1" WIN1252 "SET LIST ON; SELECT ID, HASH(UPPER(N)) H1, HASH(N || W1) H2, HASH(W1 || U) H3 FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|H1 213697982|H2 875306986846|H3 215395678|ID 2|H1 233|H2 4122789310|H3 875306960771"
pin "2 HASH in a WHERE and a GROUP BY" NONE "SET LIST ON; SELECT ID FROM TU WHERE HASH(W1) = 52574; SELECT HASH(W1) H, COUNT(*) C FROM TU GROUP BY HASH(W1) ORDER BY 1;" "ID 1|H <null>|C 1|H 2675|C 1|H 52574|C 1|H 213697982|C 1"
pin "2 HASH in a WHERE and a GROUP BY" UTF8 "SET LIST ON; SELECT ID FROM TU WHERE HASH(W1) = 52574; SELECT HASH(W1) H, COUNT(*) C FROM TU GROUP BY HASH(W1) ORDER BY 1;" "ID 1|H <null>|C 1|H 2675|C 1|H 52574|C 1|H 213697982|C 1"
pin "2 HASH in a WHERE and a GROUP BY" WIN1252 "SET LIST ON; SELECT ID FROM TU WHERE HASH(W1) = 52574; SELECT HASH(W1) H, COUNT(*) C FROM TU GROUP BY HASH(W1) ORDER BY 1;" "ID 1|H <null>|C 1|H 2675|C 1|H 52574|C 1|H 213697982|C 1"
pin "2 HASH(x USING CRC32)" NONE "SET LIST ON; SELECT HASH('abc' USING CRC32) C1, HASH('ÀÉÎ' USING CRC32) C2, HASH('' USING CRC32) C3, HASH(NULL USING CRC32) C4 FROM RDB\$DATABASE; SELECT ID, HASH(W1 USING CRC32) C5, HASH(N USING CRC32) C6, HASH(U USING CRC32) C7, HASH(K USING CRC32) C8, HASH(DN USING CRC32) C9 FROM TU ORDER BY ID;" "C1 -1035918283|C2 1714852855|C3 0|C4 <null>|ID 1|C5 -489944568|C6 1714852855|C7 1714852855|C8 -517644895|C9 685369567|ID 2|C5 1714852855|C6 1370870795|C7 -1035918283|C8 -765245304|C9 -2017572502|ID 3|C5 -1336495677|C6 0|C7 -1491550527|C8 535645913|C9 955031339|ID 4|C5 <null>|C6 <null>|C7 <null>|C8 <null>|C9 <null>"
pin "2 HASH(x USING CRC32)" UTF8 "SET LIST ON; SELECT HASH('abc' USING CRC32) C1, HASH('ÀÉÎ' USING CRC32) C2, HASH('' USING CRC32) C3, HASH(NULL USING CRC32) C4 FROM RDB\$DATABASE; SELECT ID, HASH(W1 USING CRC32) C5, HASH(N USING CRC32) C6, HASH(U USING CRC32) C7, HASH(K USING CRC32) C8, HASH(DN USING CRC32) C9 FROM TU ORDER BY ID;" "C1 -1035918283|C2 1714852855|C3 0|C4 <null>|ID 1|C5 -489944568|C6 1714852855|C7 1714852855|C8 -517644895|C9 685369567|ID 2|C5 1714852855|C6 1370870795|C7 -1035918283|C8 -765245304|C9 -2017572502|ID 3|C5 -1336495677|C6 0|C7 -1491550527|C8 535645913|C9 955031339|ID 4|C5 <null>|C6 <null>|C7 <null>|C8 <null>|C9 <null>"
pin "2 HASH(x USING CRC32)" WIN1252 "SET LIST ON; SELECT HASH('abc' USING CRC32) C1, HASH('ÀÉÎ' USING CRC32) C2, HASH('' USING CRC32) C3, HASH(NULL USING CRC32) C4 FROM RDB\$DATABASE; SELECT ID, HASH(W1 USING CRC32) C5, HASH(N USING CRC32) C6, HASH(U USING CRC32) C7, HASH(K USING CRC32) C8, HASH(DN USING CRC32) C9 FROM TU ORDER BY ID;" "C1 -1035918283|C2 1714852855|C3 0|C4 <null>|ID 1|C5 -489944568|C6 1714852855|C7 1714852855|C8 -517644895|C9 685369567|ID 2|C5 1714852855|C6 1370870795|C7 -1035918283|C8 -765245304|C9 -2017572502|ID 3|C5 -1336495677|C6 0|C7 -1491550527|C8 535645913|C9 955031339|ID 4|C5 <null>|C6 <null>|C7 <null>|C8 <null>|C9 <null>"
pin "2 HASH USING any other algorithm is the typed prepare refusal" NONE "SET LIST ON; SELECT HASH('abc' USING MD5) H FROM RDB\$DATABASE; SELECT HASH('abc' USING SHA1) H FROM RDB\$DATABASE; SELECT HASH('abc' USING sha256) H FROM RDB\$DATABASE; SELECT HASH('abc' USING FOO) H FROM RDB\$DATABASE;" "Statement failed, SQLSTATE = 42000|Invalid HASH algorithm MD5|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm SHA1|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm SHA256|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm FOO"
pin "2 HASH USING any other algorithm is the typed prepare refusal" UTF8 "SET LIST ON; SELECT HASH('abc' USING MD5) H FROM RDB\$DATABASE; SELECT HASH('abc' USING SHA1) H FROM RDB\$DATABASE; SELECT HASH('abc' USING sha256) H FROM RDB\$DATABASE; SELECT HASH('abc' USING FOO) H FROM RDB\$DATABASE;" "Statement failed, SQLSTATE = 42000|Invalid HASH algorithm MD5|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm SHA1|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm SHA256|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm FOO"
pin "2 HASH USING any other algorithm is the typed prepare refusal" WIN1252 "SET LIST ON; SELECT HASH('abc' USING MD5) H FROM RDB\$DATABASE; SELECT HASH('abc' USING SHA1) H FROM RDB\$DATABASE; SELECT HASH('abc' USING sha256) H FROM RDB\$DATABASE; SELECT HASH('abc' USING FOO) H FROM RDB\$DATABASE;" "Statement failed, SQLSTATE = 42000|Invalid HASH algorithm MD5|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm SHA1|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm SHA256|Statement failed, SQLSTATE = 42000|Invalid HASH algorithm FOO"
dpin "2 HASH(literal) describes BIGINT, not nullable" NONE "SELECT HASH('abc') H FROM RDB\$DATABASE;" "01: sqltype: 580 INT64 scale: 0 subtype: 0 len: 8"
dpin "2 HASH(column) describes BIGINT nullable" UTF8 "SELECT HASH(K) H FROM TU;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8"
dpin "2 HASH(x USING CRC32) describes INTEGER" WIN1252 "SELECT HASH('abc' USING CRC32) H FROM RDB\$DATABASE;" "01: sqltype: 496 LONG scale: 0 subtype: 0 len: 4"
dpin "2 HASH(NULL) describes BIGINT nullable" NONE "SELECT HASH(NULL) H FROM RDB\$DATABASE;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8"

echo "--- 3. BIT_LENGTH is eight OCTET_LENGTHs; CHAR_LENGTH counts the set's characters"
pin "3 the three lengths over each column" NONE "SET LIST ON; SELECT ID, CHAR_LENGTH(W1) C1, OCTET_LENGTH(W1) O1, BIT_LENGTH(W1) B1, CHAR_LENGTH(N) C2, OCTET_LENGTH(N) O2, BIT_LENGTH(N) B2, CHAR_LENGTH(U) C3, OCTET_LENGTH(U) O3, BIT_LENGTH(U) B3, CHAR_LENGTH(O) C4, OCTET_LENGTH(O) O4, BIT_LENGTH(O) B4 FROM TU ORDER BY ID;" "ID 1|C1 3|O1 3|B1 24|C2 6|O2 6|B2 48|C3 3|O3 6|B3 48|C4 6|O4 6|B4 48|ID 2|C1 6|O1 6|B1 48|C2 1|O2 1|B2 8|C3 3|O3 3|B3 24|C4 1|O4 1|B4 8|ID 3|C1 2|O1 2|B1 16|C2 0|O2 0|B2 0|C3 1|O3 2|B3 16|C4 0|O4 0|B4 0|ID 4|C1 <null>|O1 <null>|B1 <null>|C2 <null>|O2 <null>|B2 <null>|C3 <null>|O3 <null>|B3 <null>|C4 <null>|O4 <null>|B4 <null>"
pin "3 the three lengths over each column" UTF8 "SET LIST ON; SELECT ID, CHAR_LENGTH(W1) C1, OCTET_LENGTH(W1) O1, BIT_LENGTH(W1) B1, CHAR_LENGTH(N) C2, OCTET_LENGTH(N) O2, BIT_LENGTH(N) B2, CHAR_LENGTH(U) C3, OCTET_LENGTH(U) O3, BIT_LENGTH(U) B3, CHAR_LENGTH(O) C4, OCTET_LENGTH(O) O4, BIT_LENGTH(O) B4 FROM TU ORDER BY ID;" "ID 1|C1 3|O1 3|B1 24|C2 6|O2 6|B2 48|C3 3|O3 6|B3 48|C4 6|O4 6|B4 48|ID 2|C1 6|O1 6|B1 48|C2 1|O2 1|B2 8|C3 3|O3 3|B3 24|C4 1|O4 1|B4 8|ID 3|C1 2|O1 2|B1 16|C2 0|O2 0|B2 0|C3 1|O3 2|B3 16|C4 0|O4 0|B4 0|ID 4|C1 <null>|O1 <null>|B1 <null>|C2 <null>|O2 <null>|B2 <null>|C3 <null>|O3 <null>|B3 <null>|C4 <null>|O4 <null>|B4 <null>"
pin "3 the three lengths over each column" WIN1252 "SET LIST ON; SELECT ID, CHAR_LENGTH(W1) C1, OCTET_LENGTH(W1) O1, BIT_LENGTH(W1) B1, CHAR_LENGTH(N) C2, OCTET_LENGTH(N) O2, BIT_LENGTH(N) B2, CHAR_LENGTH(U) C3, OCTET_LENGTH(U) O3, BIT_LENGTH(U) B3, CHAR_LENGTH(O) C4, OCTET_LENGTH(O) O4, BIT_LENGTH(O) B4 FROM TU ORDER BY ID;" "ID 1|C1 3|O1 3|B1 24|C2 6|O2 6|B2 48|C3 3|O3 6|B3 48|C4 6|O4 6|B4 48|ID 2|C1 6|O1 6|B1 48|C2 1|O2 1|B2 8|C3 3|O3 3|B3 24|C4 1|O4 1|B4 8|ID 3|C1 2|O1 2|B1 16|C2 0|O2 0|B2 0|C3 1|O3 2|B3 16|C4 0|O4 0|B4 0|ID 4|C1 <null>|O1 <null>|B1 <null>|C2 <null>|O2 <null>|B2 <null>|C3 <null>|O3 <null>|B3 <null>|C4 <null>|O4 <null>|B4 <null>"
pin "3 the three lengths of a literal" NONE "SET LIST ON; SELECT CHAR_LENGTH('ÄÖÜ') C1, OCTET_LENGTH('ÄÖÜ') O1, BIT_LENGTH('ÄÖÜ') B1, BIT_LENGTH('') B2, BIT_LENGTH(NULL) B3, BIT_LENGTH(x'C384') B4 FROM RDB\$DATABASE;" "C1 6|O1 6|B1 48|B2 0|B3 <null>|B4 16"
pin "3 the three lengths of a literal" UTF8 "SET LIST ON; SELECT CHAR_LENGTH('ÄÖÜ') C1, OCTET_LENGTH('ÄÖÜ') O1, BIT_LENGTH('ÄÖÜ') B1, BIT_LENGTH('') B2, BIT_LENGTH(NULL) B3, BIT_LENGTH(x'C384') B4 FROM RDB\$DATABASE;" "C1 3|O1 6|B1 48|B2 0|B3 <null>|B4 16"
pin "3 the three lengths of a literal" WIN1252 "SET LIST ON; SELECT CHAR_LENGTH('ÄÖÜ') C1, OCTET_LENGTH('ÄÖÜ') O1, BIT_LENGTH('ÄÖÜ') B1, BIT_LENGTH('') B2, BIT_LENGTH(NULL) B3, BIT_LENGTH(x'C384') B4 FROM RDB\$DATABASE;" "C1 6|O1 6|B1 48|B2 0|B3 <null>|B4 16"
pin "3 BIT_LENGTH of a blob and of a CAST" NONE "SET LIST ON; SELECT ID, BIT_LENGTH(BT) B1, BIT_LENGTH(BB) B2, BIT_LENGTH(CAST(U AS VARCHAR(10) CHARACTER SET WIN1252)) B3 FROM TU ORDER BY ID;" "ID 1|B1 24|B2 24|B3 24|ID 2|B1 24|B2 24|B3 24|ID 3|B1 <null>|B2 <null>|B3 8|ID 4|B1 <null>|B2 <null>|B3 <null>"
pin "3 BIT_LENGTH of a blob and of a CAST" UTF8 "SET LIST ON; SELECT ID, BIT_LENGTH(BT) B1, BIT_LENGTH(BB) B2, BIT_LENGTH(CAST(U AS VARCHAR(10) CHARACTER SET WIN1252)) B3 FROM TU ORDER BY ID;" "ID 1|B1 24|B2 24|B3 24|ID 2|B1 24|B2 24|B3 24|ID 3|B1 <null>|B2 <null>|B3 8|ID 4|B1 <null>|B2 <null>|B3 <null>"
pin "3 BIT_LENGTH of a blob and of a CAST" WIN1252 "SET LIST ON; SELECT ID, BIT_LENGTH(BT) B1, BIT_LENGTH(BB) B2, BIT_LENGTH(CAST(U AS VARCHAR(10) CHARACTER SET WIN1252)) B3 FROM TU ORDER BY ID;" "ID 1|B1 24|B2 24|B3 24|ID 2|B1 24|B2 24|B3 24|ID 3|B1 <null>|B2 <null>|B3 8|ID 4|B1 <null>|B2 <null>|B3 <null>"
dpin "3 BIT_LENGTH(literal) describes INTEGER, not nullable" UTF8 "SELECT BIT_LENGTH('ÄÖÜ') B FROM RDB\$DATABASE;" "01: sqltype: 496 LONG scale: 0 subtype: 0 len: 4"
dpin "3 BIT_LENGTH(column) describes INTEGER nullable" NONE "SELECT BIT_LENGTH(U) B FROM TU;" "01: sqltype: 496 LONG Nullable scale: 0 subtype: 0 len: 4"
dpin "3 BIT_LENGTH(blob) describes BIGINT" WIN1252 "SELECT BIT_LENGTH(BT) B FROM TU;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8"

echo "--- 4. CONTROLS: REVERSE, LEFT, RIGHT, SUBSTRING, POSITION over the columns"
pin "4 REVERSE / LEFT / RIGHT / SUBSTRING" NONE "SET LIST ON; SELECT ID, REVERSE(W1) R1, REVERSE(N) R2, REVERSE(U) R3, LEFT(W1, 2) L1, RIGHT(W1, 2) R4, LEFT(N, 2) L2, RIGHT(N, 2) R5, SUBSTRING(W1 FROM 2 FOR 2) S1, SUBSTRING(N FROM 2 FOR 2) S2 FROM TU ORDER BY ID;" "ID 1|R1 <ce><c9><c0>|R2 <8e><c3><89><c3><80><c3>|R3 <c3><8e><c3><89><c3><80>|L1 <c0><c9>|R4 <c9><ce>|L2 <c3><80>|R5 <c3><8e>|S1 <c9><ce>|S2 <80><c3>|ID 2|R1 <8e><c3><89><c3><80><c3>|R2 <e9>|R3 cba|L1 <c3><80>|R4 <c3><8e>|L2 <e9>|R5 <e9>|S1 <80><c3>|S2|ID 3|R1 <83><9f>|R2|R3 <c3><9f>|L1 <9f><83>|R4 <9f><83>|L2|R5|S1 <83>|S2|ID 4|R1 <null>|R2 <null>|R3 <null>|L1 <null>|R4 <null>|L2 <null>|R5 <null>|S1 <null>|S2 <null>"
pin "4 REVERSE / LEFT / RIGHT / SUBSTRING" UTF8 "SET LIST ON; SELECT ID, REVERSE(W1) R1, REVERSE(N) R2, REVERSE(U) R3, LEFT(W1, 2) L1, RIGHT(W1, 2) R4, LEFT(N, 2) L2, RIGHT(N, 2) R5, SUBSTRING(W1 FROM 2 FOR 2) S1, SUBSTRING(N FROM 2 FOR 2) S2 FROM TU ORDER BY ID;" "ID 1|R1 <c3><8e><c3><89><c3><80>|R2 <8e><c3><89><c3><80><c3>|R3 <c3><8e><c3><89><c3><80>|L1 <c3><80><c3><89>|R4 <c3><89><c3><8e>|L2 <c3><80>|R5 <c3><8e>|S1 <c3><89><c3><8e>|S2 <80><c3>|ID 2|R1 <c5><bd><c3><83><e2><80><b0><c3><83><e2><82><ac><c3><83>|R2 <e9>|R3 cba|L1 <c3><83><e2><82><ac>|R4 <c3><83><c5><bd>|L2 <e9>|R5 <e9>|S1 <e2><82><ac><c3><83>|S2|ID 3|R1 <c6><92><c5><b8>|R2|R3 <c3><9f>|L1 <c5><b8><c6><92>|R4 <c5><b8><c6><92>|L2|R5|S1 <c6><92>|S2|ID 4|R1 <null>|R2 <null>|R3 <null>|L1 <null>|R4 <null>|L2 <null>|R5 <null>|S1 <null>|S2 <null>"
pin "4 REVERSE / LEFT / RIGHT / SUBSTRING" WIN1252 "SET LIST ON; SELECT ID, REVERSE(W1) R1, REVERSE(N) R2, REVERSE(U) R3, LEFT(W1, 2) L1, RIGHT(W1, 2) R4, LEFT(N, 2) L2, RIGHT(N, 2) R5, SUBSTRING(W1 FROM 2 FOR 2) S1, SUBSTRING(N FROM 2 FOR 2) S2 FROM TU ORDER BY ID;" "ID 1|R1 <ce><c9><c0>|R2 <8e><c3><89><c3><80><c3>|R3 <ce><c9><c0>|L1 <c0><c9>|R4 <c9><ce>|L2 <c3><80>|R5 <c3><8e>|S1 <c9><ce>|S2 <80><c3>|ID 2|R1 <8e><c3><89><c3><80><c3>|R2 <e9>|R3 cba|L1 <c3><80>|R4 <c3><8e>|L2 <e9>|R5 <e9>|S1 <80><c3>|S2|ID 3|R1 <83><9f>|R2|R3 <df>|L1 <9f><83>|R4 <9f><83>|L2|R5|S1 <83>|S2|ID 4|R1 <null>|R2 <null>|R3 <null>|L1 <null>|R4 <null>|L2 <null>|R5 <null>|S1 <null>|S2 <null>"
pin "4 POSITION of a literal in each set's column" NONE "SET LIST ON; SELECT ID, POSITION('É' IN W1) P1, POSITION('É' IN N) P2, POSITION('É' IN U) P3, POSITION('bc' IN A) P4 FROM TU ORDER BY ID;" "ID 1|P1 0|P2 3|P3 2|P4 0|ID 2|P1 3|P2 0|P3 0|P4 0|ID 3|P1 0|P2 0|P3 0|P4 0|ID 4|P1 <null>|P2 <null>|P3 <null>|P4 <null>"
pin "4 POSITION of a literal in each set's column" UTF8 "SET LIST ON; SELECT ID, POSITION('É' IN W1) P1, POSITION('É' IN N) P2, POSITION('É' IN U) P3, POSITION('bc' IN A) P4 FROM TU ORDER BY ID;" "ID 1|P1 2|P2 3|P3 2|P4 0|ID 2|P1 0|P2 0|P3 0|P4 0|ID 3|P1 0|P2 0|P3 0|P4 0|ID 4|P1 <null>|P2 <null>|P3 <null>|P4 <null>"
pin "4 POSITION of a literal in each set's column" WIN1252 "SET LIST ON; SELECT ID, POSITION('É' IN W1) P1, POSITION('É' IN N) P2, POSITION('É' IN U) P3, POSITION('bc' IN A) P4 FROM TU ORDER BY ID;" "ID 1|P1 0|P2 3|P3 0|P4 0|ID 2|P1 3|P2 0|P3 0|P4 0|ID 3|P1 0|P2 0|P3 0|P4 0|ID 4|P1 <null>|P2 <null>|P3 <null>|P4 <null>"
pin "4 the literal-only forms" NONE "SET LIST ON; SELECT REVERSE('ÄÖÜ') R1, LEFT('ÄÖÜ', 2) L1, RIGHT('ÄÖÜ', 2) R2, SUBSTRING('ÄÖÜ' FROM 2 FOR 2) S1, POSITION('Ö' IN 'ÄÖÜ') P1, LPAD('ab', 5, 'Ä') LP, RPAD('ab', 5, 'Ä') RP, REPLACE('ÄÖÜ', 'Ö', 'o') REP, TRIM('Ä' FROM 'ÄÖÜÄ') TR, TRIM(LEADING FROM ' Ä ') TR2 FROM RDB\$DATABASE;" "R1 <9c><c3><96><c3><84><c3>|L1 <c3><84>|R2 <c3><9c>|S1 <84><c3>|P1 3|LP <c3><84><c3>ab|RP ab<c3><84><c3>|REP <c3><84>o<c3><9c>|TR <c3><96><c3><9c>|TR2 <c3><84>"
pin "4 the literal-only forms" UTF8 "SET LIST ON; SELECT REVERSE('ÄÖÜ') R1, LEFT('ÄÖÜ', 2) L1, RIGHT('ÄÖÜ', 2) R2, SUBSTRING('ÄÖÜ' FROM 2 FOR 2) S1, POSITION('Ö' IN 'ÄÖÜ') P1, LPAD('ab', 5, 'Ä') LP, RPAD('ab', 5, 'Ä') RP, REPLACE('ÄÖÜ', 'Ö', 'o') REP, TRIM('Ä' FROM 'ÄÖÜÄ') TR, TRIM(LEADING FROM ' Ä ') TR2 FROM RDB\$DATABASE;" "R1 <c3><9c><c3><96><c3><84>|L1 <c3><84><c3><96>|R2 <c3><96><c3><9c>|S1 <c3><96><c3><9c>|P1 2|LP <c3><84><c3><84><c3><84>ab|RP ab<c3><84><c3><84><c3><84>|REP <c3><84>o<c3><9c>|TR <c3><96><c3><9c>|TR2 <c3><84>"
pin "4 the literal-only forms" WIN1252 "SET LIST ON; SELECT REVERSE('ÄÖÜ') R1, LEFT('ÄÖÜ', 2) L1, RIGHT('ÄÖÜ', 2) R2, SUBSTRING('ÄÖÜ' FROM 2 FOR 2) S1, POSITION('Ö' IN 'ÄÖÜ') P1, LPAD('ab', 5, 'Ä') LP, RPAD('ab', 5, 'Ä') RP, REPLACE('ÄÖÜ', 'Ö', 'o') REP, TRIM('Ä' FROM 'ÄÖÜÄ') TR, TRIM(LEADING FROM ' Ä ') TR2 FROM RDB\$DATABASE;" "R1 <9c><c3><96><c3><84><c3>|L1 <c3><84>|R2 <c3><9c>|S1 <84><c3>|P1 3|LP <c3><84><c3>ab|RP ab<c3><84><c3>|REP <c3><84>o<c3><9c>|TR <c3><96><c3><9c>|TR2 <c3><84>"

echo "--- 5. LPAD / RPAD / REPLACE / TRIM / POSITION: every operand converts INTO the result's set"
pin "5 LPAD(N, 8, 'Ä'): NONE, the pad is the literal's octets" NONE "SET LIST ON; SELECT ID, LPAD(N, 8, 'Ä') LP, RPAD(N, 8, 'Ä') RP FROM TU ORDER BY ID;" "ID 1|LP <c3><84><c3><80><c3><89><c3><8e>|RP <c3><80><c3><89><c3><8e><c3><84>|ID 2|LP <c3><84><c3><84><c3><84><c3><e9>|RP <e9><c3><84><c3><84><c3><84><c3>|ID 3|LP <c3><84><c3><84><c3><84><c3><84>|RP <c3><84><c3><84><c3><84><c3><84>|ID 4|LP <null>|RP <null>"
pin "5 LPAD(N, 8, 'Ä'): NONE, the pad is the literal's octets" UTF8 "SET LIST ON; SELECT ID, LPAD(N, 8, 'Ä') LP, RPAD(N, 8, 'Ä') RP FROM TU ORDER BY ID;" "ID 1|LP <c3><84><c3><80><c3><89><c3><8e>|RP <c3><80><c3><89><c3><8e><c3><84>|ID 2|LP <c3><84><c3><84><c3><84><c3><e9>|RP <e9><c3><84><c3><84><c3><84><c3>|ID 3|LP <c3><84><c3><84><c3><84><c3><84>|RP <c3><84><c3><84><c3><84><c3><84>|ID 4|LP <null>|RP <null>"
pin "5 LPAD(N, 8, 'Ä'): NONE, the pad is the literal's octets" WIN1252 "SET LIST ON; SELECT ID, LPAD(N, 8, 'Ä') LP, RPAD(N, 8, 'Ä') RP FROM TU ORDER BY ID;" "ID 1|LP <c3><84><c3><80><c3><89><c3><8e>|RP <c3><80><c3><89><c3><8e><c3><84>|ID 2|LP <c3><84><c3><84><c3><84><c3><e9>|RP <e9><c3><84><c3><84><c3><84><c3>|ID 3|LP <c3><84><c3><84><c3><84><c3><84>|RP <c3><84><c3><84><c3><84><c3><84>|ID 4|LP <null>|RP <null>"
alive "5 ...and the session survives it" NONE "SELECT ID, LPAD(N, 8, 'Ä') LP, RPAD(N, 8, 'Ä') RP FROM TU ORDER BY ID;"
alive "5 ...and the session survives it" UTF8 "SELECT ID, LPAD(N, 8, 'Ä') LP, RPAD(N, 8, 'Ä') RP FROM TU ORDER BY ID;"
alive "5 ...and the session survives it" WIN1252 "SELECT ID, LPAD(N, 8, 'Ä') LP, RPAD(N, 8, 'Ä') RP FROM TU ORDER BY ID;"
pin "5 LPAD(W1, 6, 'Ä'), LPAD(W1, 6, 'x'): the value's set" NONE "SET LIST ON; SELECT ID, LPAD(W1, 6, 'Ä') LP, LPAD(W1, 6, 'x') LP2, RPAD(W1, 6, 'x') RP FROM TU ORDER BY ID;" "ID 1|LP <c3><84><c3><c0><c9><ce>|LP2 xxx<c0><c9><ce>|RP <c0><c9><ce>xxx|ID 2|LP <c3><80><c3><89><c3><8e>|LP2 <c3><80><c3><89><c3><8e>|RP <c3><80><c3><89><c3><8e>|ID 3|LP <c3><84><c3><84><9f><83>|LP2 xxxx<9f><83>|RP <9f><83>xxxx|ID 4|LP <null>|LP2 <null>|RP <null>"
pin "5 LPAD(W1, 6, 'Ä'), LPAD(W1, 6, 'x'): the value's set" UTF8 "SET LIST ON; SELECT ID, LPAD(W1, 6, 'Ä') LP, LPAD(W1, 6, 'x') LP2, RPAD(W1, 6, 'x') RP FROM TU ORDER BY ID;" "ID 1|LP <c3><84><c3><84><c3><84><c3><80><c3><89><c3><8e>|LP2 xxx<c3><80><c3><89><c3><8e>|RP <c3><80><c3><89><c3><8e>xxx|ID 2|LP <c3><83><e2><82><ac><c3><83><e2><80><b0><c3><83><c5><bd>|LP2 <c3><83><e2><82><ac><c3><83><e2><80><b0><c3><83><c5><bd>|RP <c3><83><e2><82><ac><c3><83><e2><80><b0><c3><83><c5><bd>|ID 3|LP <c3><84><c3><84><c3><84><c3><84><c5><b8><c6><92>|LP2 xxxx<c5><b8><c6><92>|RP <c5><b8><c6><92>xxxx|ID 4|LP <null>|LP2 <null>|RP <null>"
pin "5 LPAD(W1, 6, 'Ä'), LPAD(W1, 6, 'x'): the value's set" WIN1252 "SET LIST ON; SELECT ID, LPAD(W1, 6, 'Ä') LP, LPAD(W1, 6, 'x') LP2, RPAD(W1, 6, 'x') RP FROM TU ORDER BY ID;" "ID 1|LP <c3><84><c3><c0><c9><ce>|LP2 xxx<c0><c9><ce>|RP <c0><c9><ce>xxx|ID 2|LP <c3><80><c3><89><c3><8e>|LP2 <c3><80><c3><89><c3><8e>|RP <c3><80><c3><89><c3><8e>|ID 3|LP <c3><84><c3><84><9f><83>|LP2 xxxx<9f><83>|RP <9f><83>xxxx|ID 4|LP <null>|LP2 <null>|RP <null>"
pin "5 LPAD('ab', 5, N): a carrier pad into the attachment's set" NONE "SET LIST ON; SELECT LPAD('ab', 5, N) LP FROM TU WHERE ID = 1; SELECT LPAD('ab', 5, N) LP FROM TU WHERE ID = 2;" "LP <c3><80><c3>ab|LP <e9><e9><e9>ab"
pin "5 LPAD('ab', 5, N): a carrier pad into the attachment's set" UTF8 "SET LIST ON; SELECT LPAD('ab', 5, N) LP FROM TU WHERE ID = 1; SELECT LPAD('ab', 5, N) LP FROM TU WHERE ID = 2;" "LP <c3><80><c3><89><c3><8e>ab|Statement failed, SQLSTATE = 22000|Malformed string"
pin "5 LPAD('ab', 5, N): a carrier pad into the attachment's set" WIN1252 "SET LIST ON; SELECT LPAD('ab', 5, N) LP FROM TU WHERE ID = 1; SELECT LPAD('ab', 5, N) LP FROM TU WHERE ID = 2;" "LP <c3><80><c3>ab|LP <e9><e9><e9>ab"
pin "5 LPAD(N, 8, x'C4'), LPAD(O, 5, 'Ä'): a carrier result takes bytes" NONE "SET LIST ON; SELECT ID, LPAD(N, 8, x'C4') LP, LPAD(O, 5, 'Ä') LP2 FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|LP <c4><c4><c3><80><c3><89><c3><8e>|LP2 C380C389C3|ID 2|LP <c4><c4><c4><c4><c4><c4><c4><e9>|LP2 C384C384E9"
pin "5 LPAD(N, 8, x'C4'), LPAD(O, 5, 'Ä'): a carrier result takes bytes" UTF8 "SET LIST ON; SELECT ID, LPAD(N, 8, x'C4') LP, LPAD(O, 5, 'Ä') LP2 FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|LP <c4><c4><c3><80><c3><89><c3><8e>|LP2 C380C389C3|ID 2|LP <c4><c4><c4><c4><c4><c4><c4><e9>|LP2 C384C384E9"
pin "5 LPAD(N, 8, x'C4'), LPAD(O, 5, 'Ä'): a carrier result takes bytes" WIN1252 "SET LIST ON; SELECT ID, LPAD(N, 8, x'C4') LP, LPAD(O, 5, 'Ä') LP2 FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|LP <c4><c4><c3><80><c3><89><c3><8e>|LP2 C380C389C3|ID 2|LP <c4><c4><c4><c4><c4><c4><c4><e9>|LP2 C384C384E9"
pin "5 REPLACE(N, 'É', 'e'): NONE yields to the literal's set" NONE "SET LIST ON; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 1; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 2; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 3;" "R <c3><80>e<c3><8e>|R <e9>|R"
pin "5 REPLACE(N, 'É', 'e'): NONE yields to the literal's set" UTF8 "SET LIST ON; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 1; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 2; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 3;" "R <c3><80>e<c3><8e>|Statement failed, SQLSTATE = 22000|Malformed string|R"
pin "5 REPLACE(N, 'É', 'e'): NONE yields to the literal's set" WIN1252 "SET LIST ON; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 1; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 2; SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 3;" "R <c3><80>e<c3><8e>|R <e9>|R"
alive "5 ...and the session survives it" NONE "SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 2;"
alive "5 ...and the session survives it" UTF8 "SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 2;"
alive "5 ...and the session survives it" WIN1252 "SELECT REPLACE(N, 'É', 'e') R FROM TU WHERE ID = 2;"
pin "5 REPLACE(W1, 'É', 'e'), REPLACE(U, 'É', 'e')" NONE "SET LIST ON; SELECT ID, REPLACE(W1, 'É', 'e') R1, REPLACE(U, 'É', 'e') R2 FROM TU ORDER BY ID;" "ID 1|R1 <c0><c9><ce>|R2 <c3><80>e<c3><8e>|ID 2|R1 <c3><80>e<c3><8e>|R2 abc|ID 3|R1 <9f><83>|R2 <c3><9f>|ID 4|R1 <null>|R2 <null>"
pin "5 REPLACE(W1, 'É', 'e'), REPLACE(U, 'É', 'e')" UTF8 "SET LIST ON; SELECT ID, REPLACE(W1, 'É', 'e') R1, REPLACE(U, 'É', 'e') R2 FROM TU ORDER BY ID;" "ID 1|R1 <c3><80>e<c3><8e>|R2 <c3><80>e<c3><8e>|ID 2|R1 <c3><83><e2><82><ac><c3><83><e2><80><b0><c3><83><c5><bd>|R2 abc|ID 3|R1 <c5><b8><c6><92>|R2 <c3><9f>|ID 4|R1 <null>|R2 <null>"
pin "5 REPLACE(W1, 'É', 'e'), REPLACE(U, 'É', 'e')" WIN1252 "SET LIST ON; SELECT ID, REPLACE(W1, 'É', 'e') R1, REPLACE(U, 'É', 'e') R2 FROM TU ORDER BY ID;" "ID 1|R1 <c0><c9><ce>|R2 <c0><c9><ce>|ID 2|R1 <c3><80>e<c3><8e>|R2 abc|ID 3|R1 <9f><83>|R2 <df>|ID 4|R1 <null>|R2 <null>"
pin "5 REPLACE('aÉb', N, 'x'): a carrier search into the attachment's set" NONE "SET LIST ON; SELECT REPLACE('aÉb', N, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE('aÉb', N, 'x') R FROM TU WHERE ID = 2;" "R a<c3><89>b|R a<c3><89>b"
pin "5 REPLACE('aÉb', N, 'x'): a carrier search into the attachment's set" UTF8 "SET LIST ON; SELECT REPLACE('aÉb', N, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE('aÉb', N, 'x') R FROM TU WHERE ID = 2;" "R a<c3><89>b|Statement failed, SQLSTATE = 22000|Malformed string"
pin "5 REPLACE('aÉb', N, 'x'): a carrier search into the attachment's set" WIN1252 "SET LIST ON; SELECT REPLACE('aÉb', N, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE('aÉb', N, 'x') R FROM TU WHERE ID = 2;" "R a<c3><89>b|R a<c3><89>b"
pin "5 REPLACE(U, <NONE C3 89>, 'x'): the octets read as the UTF8 letter" NONE "SET LIST ON; SELECT REPLACE(U, CAST(x'C389' AS VARCHAR(2) CHARACTER SET NONE), 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(U, N, 'x') R FROM TU WHERE ID = 1;" "R <c3><80>x<c3><8e>|R x"
pin "5 REPLACE(U, <NONE C3 89>, 'x'): the octets read as the UTF8 letter" UTF8 "SET LIST ON; SELECT REPLACE(U, CAST(x'C389' AS VARCHAR(2) CHARACTER SET NONE), 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(U, N, 'x') R FROM TU WHERE ID = 1;" "R <c3><80>x<c3><8e>|R x"
pin "5 REPLACE(U, <NONE C3 89>, 'x'): the octets read as the UTF8 letter" WIN1252 "SET LIST ON; SELECT REPLACE(U, CAST(x'C389' AS VARCHAR(2) CHARACTER SET NONE), 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(U, N, 'x') R FROM TU WHERE ID = 1;" "R <c0>x<ce>|R x"
pin "5 TRIM('Î' FROM N), TRIM(x'C3' FROM N), TRIM(N): the value's set" NONE "SET LIST ON; SELECT ID, TRIM('Î' FROM N) T1, TRIM(x'C3' FROM N) T2, TRIM(N) T3, TRIM(W1) T4, TRIM('Î' FROM W1) T5 FROM TU ORDER BY ID;" "ID 1|T1 <c3><80><c3><89>|T2 <80><c3><89><c3><8e>|T3 <c3><80><c3><89><c3><8e>|T4 <c0><c9><ce>|T5 <c0><c9><ce>|ID 2|T1 <e9>|T2 <e9>|T3 <e9>|T4 <c3><80><c3><89><c3><8e>|T5 <c3><80><c3><89>|ID 3|T1|T2|T3|T4 <9f><83>|T5 <9f><83>|ID 4|T1 <null>|T2 <null>|T3 <null>|T4 <null>|T5 <null>"
pin "5 TRIM('Î' FROM N), TRIM(x'C3' FROM N), TRIM(N): the value's set" UTF8 "SET LIST ON; SELECT ID, TRIM('Î' FROM N) T1, TRIM(x'C3' FROM N) T2, TRIM(N) T3, TRIM(W1) T4, TRIM('Î' FROM W1) T5 FROM TU ORDER BY ID;" "ID 1|T1 <c3><80><c3><89>|T2 <80><c3><89><c3><8e>|T3 <c3><80><c3><89><c3><8e>|T4 <c3><80><c3><89><c3><8e>|T5 <c3><80><c3><89>|ID 2|T1 <e9>|T2 <e9>|T3 <e9>|T4 <c3><83><e2><82><ac><c3><83><e2><80><b0><c3><83><c5><bd>|T5 <c3><83><e2><82><ac><c3><83><e2><80><b0><c3><83><c5><bd>|ID 3|T1|T2|T3|T4 <c5><b8><c6><92>|T5 <c5><b8><c6><92>|ID 4|T1 <null>|T2 <null>|T3 <null>|T4 <null>|T5 <null>"
pin "5 TRIM('Î' FROM N), TRIM(x'C3' FROM N), TRIM(N): the value's set" WIN1252 "SET LIST ON; SELECT ID, TRIM('Î' FROM N) T1, TRIM(x'C3' FROM N) T2, TRIM(N) T3, TRIM(W1) T4, TRIM('Î' FROM W1) T5 FROM TU ORDER BY ID;" "ID 1|T1 <c3><80><c3><89>|T2 <80><c3><89><c3><8e>|T3 <c3><80><c3><89><c3><8e>|T4 <c0><c9><ce>|T5 <c0><c9><ce>|ID 2|T1 <e9>|T2 <e9>|T3 <e9>|T4 <c3><80><c3><89><c3><8e>|T5 <c3><80><c3><89>|ID 3|T1|T2|T3|T4 <9f><83>|T5 <9f><83>|ID 4|T1 <null>|T2 <null>|T3 <null>|T4 <null>|T5 <null>"
pin "5 TRIM(TRAILING <NONE C3 8E> FROM U), TRIM(TRAILING N FROM U)" NONE "SET LIST ON; SELECT TRIM(TRAILING CAST(x'C38E' AS VARCHAR(2) CHARACTER SET NONE) FROM U) T FROM TU WHERE ID = 1; SELECT TRIM(TRAILING N FROM U) T FROM TU WHERE ID = 1;" "T <c3><80><c3><89>|T"
pin "5 TRIM(TRAILING <NONE C3 8E> FROM U), TRIM(TRAILING N FROM U)" UTF8 "SET LIST ON; SELECT TRIM(TRAILING CAST(x'C38E' AS VARCHAR(2) CHARACTER SET NONE) FROM U) T FROM TU WHERE ID = 1; SELECT TRIM(TRAILING N FROM U) T FROM TU WHERE ID = 1;" "T <c3><80><c3><89>|T"
pin "5 TRIM(TRAILING <NONE C3 8E> FROM U), TRIM(TRAILING N FROM U)" WIN1252 "SET LIST ON; SELECT TRIM(TRAILING CAST(x'C38E' AS VARCHAR(2) CHARACTER SET NONE) FROM U) T FROM TU WHERE ID = 1; SELECT TRIM(TRAILING N FROM U) T FROM TU WHERE ID = 1;" "T <c0><c9>|T"
alive "5 ...and the session survives it" NONE "SELECT TRIM(TRAILING CAST(x'C38E' AS VARCHAR(2) CHARACTER SET NONE) FROM U) T FROM TU WHERE ID = 1;"
alive "5 ...and the session survives it" UTF8 "SELECT TRIM(TRAILING CAST(x'C38E' AS VARCHAR(2) CHARACTER SET NONE) FROM U) T FROM TU WHERE ID = 1;"
alive "5 ...and the session survives it" WIN1252 "SELECT TRIM(TRAILING CAST(x'C38E' AS VARCHAR(2) CHARACTER SET NONE) FROM U) T FROM TU WHERE ID = 1;"
pin "5 POSITION(<NONE C3 89> IN U) is the character, POSITION(N IN U)" NONE "SET LIST ON; SELECT POSITION(CAST(x'C389' AS VARCHAR(2) CHARACTER SET NONE) IN U) P1, POSITION(N IN U) P2, POSITION(U IN N) P3 FROM TU WHERE ID = 1;" "P1 2|P2 1|P3 1"
pin "5 POSITION(<NONE C3 89> IN U) is the character, POSITION(N IN U)" UTF8 "SET LIST ON; SELECT POSITION(CAST(x'C389' AS VARCHAR(2) CHARACTER SET NONE) IN U) P1, POSITION(N IN U) P2, POSITION(U IN N) P3 FROM TU WHERE ID = 1;" "P1 2|P2 1|P3 1"
pin "5 POSITION(<NONE C3 89> IN U) is the character, POSITION(N IN U)" WIN1252 "SET LIST ON; SELECT POSITION(CAST(x'C389' AS VARCHAR(2) CHARACTER SET NONE) IN U) P1, POSITION(N IN U) P2, POSITION(U IN N) P3 FROM TU WHERE ID = 1;" "P1 2|P2 1|P3 1"
pin "5 N || 'Ä' under each attachment (the concat law, as a control)" NONE "SET LIST ON; SELECT N || 'Ä' C FROM TU WHERE ID = 1; SELECT N || 'Ä' C FROM TU WHERE ID = 2; SELECT W1 || 'Ä' C FROM TU WHERE ID = 1;" "C <c3><80><c3><89><c3><8e><c3><84>|C <e9><c3><84>|C <c0><c9><ce><c3><84>"
pin "5 N || 'Ä' under each attachment (the concat law, as a control)" UTF8 "SET LIST ON; SELECT N || 'Ä' C FROM TU WHERE ID = 1; SELECT N || 'Ä' C FROM TU WHERE ID = 2; SELECT W1 || 'Ä' C FROM TU WHERE ID = 1;" "C <c3><80><c3><89><c3><8e><c3><84>|Statement failed, SQLSTATE = 22000|Malformed string|C <c3><80><c3><89><c3><8e><c3><84>"
pin "5 N || 'Ä' under each attachment (the concat law, as a control)" WIN1252 "SET LIST ON; SELECT N || 'Ä' C FROM TU WHERE ID = 1; SELECT N || 'Ä' C FROM TU WHERE ID = 2; SELECT W1 || 'Ä' C FROM TU WHERE ID = 1;" "C <c3><80><c3><89><c3><8e><c3><84>|C <e9><c3><84>|C <c0><c9><ce><c3><84>"
dpin "5 LPAD(N, 8, 'Ä') describes NONE" NONE "SELECT LPAD(N, 8, 'Ä') LP FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 8 charset: 0 SYSTEM.NONE"
dpin "5 LPAD(N, 8, 'Ä') describes NONE" UTF8 "SELECT LPAD(N, 8, 'Ä') LP FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 8 charset: 0 SYSTEM.NONE"
dpin "5 LPAD(N, 8, 'Ä') describes NONE" WIN1252 "SELECT LPAD(N, 8, 'Ä') LP FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 8 charset: 0 SYSTEM.NONE"
dpin "5 REPLACE(N, 'É', 'e') describes the negotiated set" NONE "SELECT REPLACE(N, 'É', 'e') R FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 0 SYSTEM.NONE"
dpin "5 REPLACE(N, 'É', 'e') describes the negotiated set" UTF8 "SELECT REPLACE(N, 'É', 'e') R FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 80 charset: 4 SYSTEM.UTF8"
dpin "5 REPLACE(N, 'É', 'e') describes the negotiated set" WIN1252 "SELECT REPLACE(N, 'É', 'e') R FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 53 SYSTEM.WIN1252"
dpin "5 TRIM('Î' FROM N) describes NONE" NONE "SELECT TRIM('Î' FROM N) T FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 0 SYSTEM.NONE"
dpin "5 TRIM('Î' FROM N) describes NONE" UTF8 "SELECT TRIM('Î' FROM N) T FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 0 SYSTEM.NONE"
dpin "5 TRIM('Î' FROM N) describes NONE" WIN1252 "SELECT TRIM('Î' FROM N) T FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 0 SYSTEM.NONE"
dpin "5 LPAD('ab', 5, N) describes the attachment's set" NONE "SELECT LPAD('ab', 5, N) LP FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 5 charset: 0 SYSTEM.NONE"
dpin "5 LPAD('ab', 5, N) describes the attachment's set" UTF8 "SELECT LPAD('ab', 5, N) LP FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 4 SYSTEM.UTF8"
dpin "5 LPAD('ab', 5, N) describes the attachment's set" WIN1252 "SELECT LPAD('ab', 5, N) LP FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 5 charset: 53 SYSTEM.WIN1252"

echo "--- 6. A LITERAL's WIDTH under a tabled single-byte attachment is its octet count"
dpin "6 'Ä' is TEXT(2)" WIN1252 "SELECT 'Ä' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 2 charset: 53 SYSTEM.WIN1252"
dpin "6 'Ä' is TEXT(2)" ISO8859_1 "SELECT 'Ä' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 2 charset: 21 SYSTEM.ISO8859_1"
dpin "6 'ÄÖÜ' is TEXT(6)" WIN1252 "SELECT 'ÄÖÜ' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 6 charset: 53 SYSTEM.WIN1252"
dpin "6 'ÄÖÜ' is TEXT(6)" ISO8859_1 "SELECT 'ÄÖÜ' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 6 charset: 21 SYSTEM.ISO8859_1"
dpin "6 'ÄÖÜ' || 'x' is VARYING(7)" WIN1252 "SELECT 'ÄÖÜ' || 'x' A FROM RDB\$DATABASE;" "01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 7 charset: 53 SYSTEM.WIN1252"
dpin "6 'ÄÖÜ' || 'x' is VARYING(7)" ISO8859_1 "SELECT 'ÄÖÜ' || 'x' A FROM RDB\$DATABASE;" "01: sqltype: 448 VARYING scale: 0 subtype: 0 len: 7 charset: 21 SYSTEM.ISO8859_1"
dpin "6 LOWER('Ä') is TEXT(2)" WIN1252 "SELECT LOWER('Ä') A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 2 charset: 53 SYSTEM.WIN1252"
dpin "6 LOWER('Ä') is TEXT(2)" ISO8859_1 "SELECT LOWER('Ä') A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 2 charset: 21 SYSTEM.ISO8859_1"
pin "6 ...and the value is not padded past it" WIN1252 "SET LIST ON; SELECT 'Ä' A, 'ÄÖÜ' B, 'ÄÖÜ' || 'x' C, LOWER('Ä') D FROM RDB\$DATABASE;" "A <c3><84>|B <c3><84><c3><96><c3><9c>|C <c3><84><c3><96><c3><9c>x|D <e3><84>"
pin "6 ...and the value is not padded past it" ISO8859_1 "SET LIST ON; SELECT 'Ä' A, 'ÄÖÜ' B, 'ÄÖÜ' || 'x' C, LOWER('Ä') D FROM RDB\$DATABASE;" "A <c3><84>|B <c3><84><c3><96><c3><9c>|C <c3><84><c3><96><c3><9c>x|D <e3><84>"
dpin "6 CONTROL 'abc' is TEXT(3)" WIN1252 "SELECT 'abc' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 3 charset: 53 SYSTEM.WIN1252"
dpin "6 CONTROL 'abc' is TEXT(3)" ISO8859_1 "SELECT 'abc' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 3 charset: 21 SYSTEM.ISO8859_1"
dpin "6 CONTROL 'ÄÖÜ' under UTF8 is TEXT(12) - three characters" UTF8 "SELECT 'ÄÖÜ' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 12 charset: 4 SYSTEM.UTF8"
dpin "6 CONTROL 'ÄÖÜ' under NONE is TEXT(6)" NONE "SELECT 'ÄÖÜ' A FROM RDB\$DATABASE;" "01: sqltype: 452 TEXT scale: 0 subtype: 0 len: 6 charset: 0 SYSTEM.NONE"

echo "--- 7. REPLACE RUNS IN ITS SEARCHED STRING'S SET; a value is delivered in the set its describe announces"
pin "7 CHAR_LENGTH / OCTET_LENGTH / BIT_LENGTH of REPLACE(N, 'É', 'e') count the NONE bytes" NONE "SET LIST ON; SELECT ID, CHAR_LENGTH(REPLACE(N, 'É', 'e')) C, OCTET_LENGTH(REPLACE(N, 'É', 'e')) O, BIT_LENGTH(REPLACE(N, 'É', 'e')) B FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|C 5|O 5|B 40|ID 2|C 1|O 1|B 8"
pin "7 CHAR_LENGTH / OCTET_LENGTH / BIT_LENGTH of REPLACE(N, 'É', 'e') count the NONE bytes" UTF8 "SET LIST ON; SELECT ID, CHAR_LENGTH(REPLACE(N, 'É', 'e')) C, OCTET_LENGTH(REPLACE(N, 'É', 'e')) O, BIT_LENGTH(REPLACE(N, 'É', 'e')) B FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|C 5|O 5|B 40|ID 2|C 1|O 1|B 8"
pin "7 CHAR_LENGTH / OCTET_LENGTH / BIT_LENGTH of REPLACE(N, 'É', 'e') count the NONE bytes" WIN1252 "SET LIST ON; SELECT ID, CHAR_LENGTH(REPLACE(N, 'É', 'e')) C, OCTET_LENGTH(REPLACE(N, 'É', 'e')) O, BIT_LENGTH(REPLACE(N, 'É', 'e')) B FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|C 5|O 5|B 40|ID 2|C 1|O 1|B 8"
pin "7 LOWER / UPPER of it case ASCII only" NONE "SET LIST ON; SELECT LOWER(REPLACE(N, 'É', 'e')) L, UPPER(REPLACE(N, 'É', 'e')) U FROM TU WHERE ID = 1;" "L <c3><80>e<c3><8e>|U <c3><80>E<c3><8e>"
pin "7 LOWER / UPPER of it case ASCII only" UTF8 "SET LIST ON; SELECT LOWER(REPLACE(N, 'É', 'e')) L, UPPER(REPLACE(N, 'É', 'e')) U FROM TU WHERE ID = 1;" "L <c3><80>e<c3><8e>|U <c3><80>E<c3><8e>"
pin "7 LOWER / UPPER of it case ASCII only" WIN1252 "SET LIST ON; SELECT LOWER(REPLACE(N, 'É', 'e')) L, UPPER(REPLACE(N, 'É', 'e')) U FROM TU WHERE ID = 1;" "L <c3><80>e<c3><8e>|U <c3><80>E<c3><8e>"
pin "7 REPLACE(N, 'É', 'e') = N is a byte compare" NONE "SET LIST ON; SELECT ID FROM TU WHERE REPLACE(N, 'É', 'e') = N ORDER BY ID; SELECT ID FROM TU WHERE REPLACE(N, 'É', 'e') <> N ORDER BY ID;" "ID 2|ID 3|ID 1"
pin "7 REPLACE(N, 'É', 'e') = N is a byte compare" UTF8 "SET LIST ON; SELECT ID FROM TU WHERE REPLACE(N, 'É', 'e') = N ORDER BY ID; SELECT ID FROM TU WHERE REPLACE(N, 'É', 'e') <> N ORDER BY ID;" "ID 2|ID 3|ID 1"
pin "7 REPLACE(N, 'É', 'e') = N is a byte compare" WIN1252 "SET LIST ON; SELECT ID FROM TU WHERE REPLACE(N, 'É', 'e') = N ORDER BY ID; SELECT ID FROM TU WHERE REPLACE(N, 'É', 'e') <> N ORDER BY ID;" "ID 2|ID 3|ID 1"
pin "7 HASH of it hashes the NONE bytes" NONE "SET LIST ON; SELECT ID, HASH(REPLACE(N, 'É', 'e')) H FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|H 13332926|ID 2|H 233"
pin "7 HASH of it hashes the NONE bytes" UTF8 "SET LIST ON; SELECT ID, HASH(REPLACE(N, 'É', 'e')) H FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|H 13332926|ID 2|H 233"
pin "7 HASH of it hashes the NONE bytes" WIN1252 "SET LIST ON; SELECT ID, HASH(REPLACE(N, 'É', 'e')) H FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|H 13332926|ID 2|H 233"
pin "7 REPLACE(N, W1, 'x'): W1 byte-copied into NONE; the E9 row through the announced set" NONE "SET LIST ON; SELECT REPLACE(N, W1, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(N, W1, 'x') R FROM TU WHERE ID = 2;" "R <c3><80><c3><89><c3><8e>|R <e9>"
pin "7 REPLACE(N, W1, 'x'): W1 byte-copied into NONE; the E9 row through the announced set" UTF8 "SET LIST ON; SELECT REPLACE(N, W1, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(N, W1, 'x') R FROM TU WHERE ID = 2;" "R <c3><80><c3><89><c3><8e>|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 REPLACE(N, W1, 'x'): W1 byte-copied into NONE; the E9 row through the announced set" WIN1252 "SET LIST ON; SELECT REPLACE(N, W1, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(N, W1, 'x') R FROM TU WHERE ID = 2;" "R <c3><80><c3><89><c3><8e>|R <e9>"
pin "7 REPLACE(N, U, 'x') likewise" NONE "SET LIST ON; SELECT REPLACE(N, U, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(N, U, 'x') R FROM TU WHERE ID = 2;" "R x|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 REPLACE(N, U, 'x') likewise" UTF8 "SET LIST ON; SELECT REPLACE(N, U, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(N, U, 'x') R FROM TU WHERE ID = 2;" "R x|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 REPLACE(N, U, 'x') likewise" WIN1252 "SET LIST ON; SELECT REPLACE(N, U, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(N, U, 'x') R FROM TU WHERE ID = 2;" "R x|R <e9>"
pin "7 REPLACE(N, 'É', U) / REPLACE(N, 'É', W1): the replacement's bytes" NONE "SET LIST ON; SELECT REPLACE(N, 'É', U) R1, REPLACE(N, 'É', W1) R2 FROM TU WHERE ID = 1;" "R1 <c3><80><c3><80><c3><89><c3><8e><c3><8e>|R2 <c3><80><c0><c9><ce><c3><8e>"
pin "7 REPLACE(N, 'É', U) / REPLACE(N, 'É', W1): the replacement's bytes" UTF8 "SET LIST ON; SELECT REPLACE(N, 'É', U) R1, REPLACE(N, 'É', W1) R2 FROM TU WHERE ID = 1;" "Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 REPLACE(N, 'É', U) / REPLACE(N, 'É', W1): the replacement's bytes" WIN1252 "SET LIST ON; SELECT REPLACE(N, 'É', U) R1, REPLACE(N, 'É', W1) R2 FROM TU WHERE ID = 1;" "R1 <c3><80><c3><80><c3><89><c3><8e><c3><8e>|R2 <c3><80><c0><c9><ce><c3><8e>"
pin "7 LPAD over it pads BYTES, and HASH / OCTET_LENGTH see them" NONE "SET LIST ON; SELECT ID, LPAD(REPLACE(N, 'É', 'e'), 8, 'x') L, OCTET_LENGTH(LPAD(REPLACE(N, 'É', 'e'), 8, 'x')) O, HASH(LPAD(REPLACE(N, 'É', 'e'), 8, 'x')) H FROM TU WHERE ID = 1;" "ID 1|L xxx<c3><80>e<c3><8e>|O 8|H 34364682686"
pin "7 LPAD over it pads BYTES, and HASH / OCTET_LENGTH see them" UTF8 "SET LIST ON; SELECT ID, LPAD(REPLACE(N, 'É', 'e'), 8, 'x') L, OCTET_LENGTH(LPAD(REPLACE(N, 'É', 'e'), 8, 'x')) O, HASH(LPAD(REPLACE(N, 'É', 'e'), 8, 'x')) H FROM TU WHERE ID = 1;" "ID 1|L xxx<c3><80>e<c3><8e>|O 8|H 34364682686"
pin "7 LPAD over it pads BYTES, and HASH / OCTET_LENGTH see them" WIN1252 "SET LIST ON; SELECT ID, LPAD(REPLACE(N, 'É', 'e'), 8, 'x') L, OCTET_LENGTH(LPAD(REPLACE(N, 'É', 'e'), 8, 'x')) O, HASH(LPAD(REPLACE(N, 'É', 'e'), 8, 'x')) H FROM TU WHERE ID = 1;" "ID 1|L xxx<c3><80>e<c3><8e>|O 8|H 34364682686"
pin "7 SUBSTRING over it cuts bytes" NONE "SET LIST ON; SELECT SUBSTRING(REPLACE(N, 'É', 'e') FROM 2) S FROM TU WHERE ID = 1;" "S <80>e<c3><8e>"
pin "7 SUBSTRING over it cuts bytes" UTF8 "SET LIST ON; SELECT SUBSTRING(REPLACE(N, 'É', 'e') FROM 2) S FROM TU WHERE ID = 1;" "Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 SUBSTRING over it cuts bytes" WIN1252 "SET LIST ON; SELECT SUBSTRING(REPLACE(N, 'É', 'e') FROM 2) S FROM TU WHERE ID = 1;" "S <80>e<c3><8e>"
pin "7 POSITION in it is a byte offset" NONE "SET LIST ON; SELECT POSITION('e' IN REPLACE(N, 'É', 'e')) P FROM TU WHERE ID = 1;" "P 3"
pin "7 POSITION in it is a byte offset" UTF8 "SET LIST ON; SELECT POSITION('e' IN REPLACE(N, 'É', 'e')) P FROM TU WHERE ID = 1;" "P 3"
pin "7 POSITION in it is a byte offset" WIN1252 "SET LIST ON; SELECT POSITION('e' IN REPLACE(N, 'É', 'e')) P FROM TU WHERE ID = 1;" "P 3"
pin "7 CAST of it to an unqualified VARCHAR converts the NONE bytes into the attachment's set" NONE "SET LIST ON; SELECT CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10)) C FROM TU WHERE ID = 1; SELECT CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10)) C FROM TU WHERE ID = 2;" "C <c3><80>e<c3><8e>|C <e9>"
pin "7 CAST of it to an unqualified VARCHAR converts the NONE bytes into the attachment's set" UTF8 "SET LIST ON; SELECT CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10)) C FROM TU WHERE ID = 1; SELECT CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10)) C FROM TU WHERE ID = 2;" "C <c3><80>e<c3><8e>|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 CAST of it to an unqualified VARCHAR converts the NONE bytes into the attachment's set" WIN1252 "SET LIST ON; SELECT CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10)) C FROM TU WHERE ID = 1; SELECT CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10)) C FROM TU WHERE ID = 2;" "C <c3><80>e<c3><8e>|C <e9>"
pin "7 ...and to CHARACTER SET NONE keeps them" NONE "SET LIST ON; SELECT ID, CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10) CHARACTER SET NONE) C FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|C <c3><80>e<c3><8e>|ID 2|C <e9>"
pin "7 ...and to CHARACTER SET NONE keeps them" UTF8 "SET LIST ON; SELECT ID, CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10) CHARACTER SET NONE) C FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|C <c3><80>e<c3><8e>|ID 2|C <e9>"
pin "7 ...and to CHARACTER SET NONE keeps them" WIN1252 "SET LIST ON; SELECT ID, CAST(REPLACE(N, 'É', 'e') AS VARCHAR(10) CHARACTER SET NONE) C FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|C <c3><80>e<c3><8e>|ID 2|C <e9>"
pin "7 COALESCE / NULLIF over it" NONE "SET LIST ON; SELECT ID, COALESCE(REPLACE(N, 'É', 'e'), 'q') C, NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID IN (1, 4) ORDER BY ID; SELECT COALESCE(REPLACE(N, 'É', 'e'), 'q') C FROM TU WHERE ID = 2; SELECT NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID = 2;" "ID 1|C <c3><80>e<c3><8e>|N <c3><80>e<c3><8e>|ID 4|C q|N <null>|C <e9>|N <e9>"
pin "7 COALESCE / NULLIF over it" UTF8 "SET LIST ON; SELECT ID, COALESCE(REPLACE(N, 'É', 'e'), 'q') C, NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID IN (1, 4) ORDER BY ID; SELECT COALESCE(REPLACE(N, 'É', 'e'), 'q') C FROM TU WHERE ID = 2; SELECT NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID = 2;" "ID 1|C <c3><80>e<c3><8e>|N <c3><80>e<c3><8e>|ID 4|C q|N <null>|Statement failed, SQLSTATE = 22000|Malformed string|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 COALESCE / NULLIF over it" WIN1252 "SET LIST ON; SELECT ID, COALESCE(REPLACE(N, 'É', 'e'), 'q') C, NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID IN (1, 4) ORDER BY ID; SELECT COALESCE(REPLACE(N, 'É', 'e'), 'q') C FROM TU WHERE ID = 2; SELECT NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID = 2;" "ID 1|C <c3><80>e<c3><8e>|N <c3><80>e<c3><8e>|ID 4|C q|N <null>|C <e9>|N <e9>"
alive "7 ...and the session survives it" NONE "SELECT COALESCE(REPLACE(N, 'É', 'e'), 'q') C, NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID = 2;"
alive "7 ...and the session survives it" UTF8 "SELECT COALESCE(REPLACE(N, 'É', 'e'), 'q') C, NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID = 2;"
alive "7 ...and the session survives it" WIN1252 "SELECT COALESCE(REPLACE(N, 'É', 'e'), 'q') C, NULLIF(REPLACE(N, 'É', 'e'), 'q') N FROM TU WHERE ID = 2;"
pin "7 REPLACE(N, 'É', 'e') || W1 negotiates its run-time set from the VALUES" NONE "SET LIST ON; SELECT REPLACE(N, 'É', 'e') || W1 C FROM TU WHERE ID = 1;" "C <c3><80>e<c3><8e><c0><c9><ce>"
pin "7 REPLACE(N, 'É', 'e') || W1 negotiates its run-time set from the VALUES" UTF8 "SET LIST ON; SELECT REPLACE(N, 'É', 'e') || W1 C FROM TU WHERE ID = 1;" "C <c3><83><e2><82><ac>e<c3><83><c5><bd><c3><80><c3><89><c3><8e>"
pin "7 REPLACE(N, 'É', 'e') || W1 negotiates its run-time set from the VALUES" WIN1252 "SET LIST ON; SELECT REPLACE(N, 'É', 'e') || W1 C FROM TU WHERE ID = 1;" "C <c3><80>e<c3><8e><c0><c9><ce>"
pin "7 MAX over it folds in the announced set" NONE "SET LIST ON; SELECT MAX(REPLACE(N, 'É', 'e')) M FROM TU WHERE ID IN (1, 2);" "M <e9>"
pin "7 MAX over it folds in the announced set" UTF8 "SET LIST ON; SELECT MAX(REPLACE(N, 'É', 'e')) M FROM TU WHERE ID IN (1, 2);" "Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 MAX over it folds in the announced set" WIN1252 "SET LIST ON; SELECT MAX(REPLACE(N, 'É', 'e')) M FROM TU WHERE ID IN (1, 2);" "M <e9>"
pin "7 GROUP BY it keys in the announced set" NONE "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE ID IN (1, 2, 3) GROUP BY REPLACE(N, 'É', 'e');" "C 1|C 1|C 1"
pin "7 GROUP BY it keys in the announced set" UTF8 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE ID IN (1, 2, 3) GROUP BY REPLACE(N, 'É', 'e');" "Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 GROUP BY it keys in the announced set" WIN1252 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE ID IN (1, 2, 3) GROUP BY REPLACE(N, 'É', 'e');" "C 1|C 1|C 1"
pin "7 REPLACE(A, 'É', 'e'): a high byte into ASCII" NONE "SET LIST ON; SELECT REPLACE(A, 'É', 'e') R FROM TU WHERE ID = 1;" "Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 REPLACE(A, 'É', 'e'): a high byte into ASCII" UTF8 "SET LIST ON; SELECT REPLACE(A, 'É', 'e') R FROM TU WHERE ID = 1;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "7 REPLACE(A, 'É', 'e'): a high byte into ASCII" WIN1252 "SET LIST ON; SELECT REPLACE(A, 'É', 'e') R FROM TU WHERE ID = 1;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "7 REPLACE(U, O, 'x'): the OCTETS operand must spell UTF8" NONE "SET LIST ON; SELECT REPLACE(U, O, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(U, O, 'x') R FROM TU WHERE ID = 2;" "R 78|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 REPLACE(U, O, 'x'): the OCTETS operand must spell UTF8" UTF8 "SET LIST ON; SELECT REPLACE(U, O, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(U, O, 'x') R FROM TU WHERE ID = 2;" "R 78|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 REPLACE(U, O, 'x'): the OCTETS operand must spell UTF8" WIN1252 "SET LIST ON; SELECT REPLACE(U, O, 'x') R FROM TU WHERE ID = 1; SELECT REPLACE(U, O, 'x') R FROM TU WHERE ID = 2;" "R 78|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 a conditional moves its branch into the negotiated set" NONE "SET LIST ON; SELECT OCTET_LENGTH(COALESCE(N, 'ÄÖÜ')) O1, BIT_LENGTH(COALESCE(N, 'ÄÖÜ')) B1, HASH(CASE ID WHEN 1 THEN N ELSE W1 END) H1, HASH(COALESCE(N, W1)) H2, HASH(IIF(ID = 1, N, 'q')) H3 FROM TU WHERE ID = 1;" "O1 6|B1 48|H1 213697982|H2 213697982|H3 213697982"
pin "7 a conditional moves its branch into the negotiated set" UTF8 "SET LIST ON; SELECT OCTET_LENGTH(COALESCE(N, 'ÄÖÜ')) O1, BIT_LENGTH(COALESCE(N, 'ÄÖÜ')) B1, HASH(CASE ID WHEN 1 THEN N ELSE W1 END) H1, HASH(COALESCE(N, W1)) H2, HASH(IIF(ID = 1, N, 'q')) H3 FROM TU WHERE ID = 1;" "O1 6|B1 48|H1 213697982|H2 213697982|H3 213697982"
pin "7 a conditional moves its branch into the negotiated set" WIN1252 "SET LIST ON; SELECT OCTET_LENGTH(COALESCE(N, 'ÄÖÜ')) O1, BIT_LENGTH(COALESCE(N, 'ÄÖÜ')) B1, HASH(CASE ID WHEN 1 THEN N ELSE W1 END) H1, HASH(COALESCE(N, W1)) H2, HASH(IIF(ID = 1, N, 'q')) H3 FROM TU WHERE ID = 1;" "O1 6|B1 48|H1 213697982|H2 213697982|H3 213697982"
pin "7 COALESCE(N, 'ÄÖÜ') delivers the NONE bytes" NONE "SET LIST ON; SELECT ID, COALESCE(N, 'ÄÖÜ') V FROM TU WHERE ID IN (1, 2, 4) ORDER BY ID;" "ID 1|V <c3><80><c3><89><c3><8e>|ID 2|V <e9>|ID 4|V <c3><84><c3><96><c3><9c>"
pin "7 COALESCE(N, 'ÄÖÜ') delivers the NONE bytes" UTF8 "SET LIST ON; SELECT ID, COALESCE(N, 'ÄÖÜ') V FROM TU WHERE ID IN (1, 2, 4) ORDER BY ID;" "ID 1|V <c3><80><c3><89><c3><8e>|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 COALESCE(N, 'ÄÖÜ') delivers the NONE bytes" WIN1252 "SET LIST ON; SELECT ID, COALESCE(N, 'ÄÖÜ') V FROM TU WHERE ID IN (1, 2, 4) ORDER BY ID;" "ID 1|V <c3><80><c3><89><c3><8e>|ID 2|V <e9>|ID 4|V <c3><84><c3><96><c3><9c>"
alive "7 ...and the session survives it" NONE "SELECT ID, COALESCE(N, 'ÄÖÜ') V FROM TU WHERE ID IN (1, 2, 4) ORDER BY ID;"
alive "7 ...and the session survives it" UTF8 "SELECT ID, COALESCE(N, 'ÄÖÜ') V FROM TU WHERE ID IN (1, 2, 4) ORDER BY ID;"
alive "7 ...and the session survives it" WIN1252 "SELECT ID, COALESCE(N, 'ÄÖÜ') V FROM TU WHERE ID IN (1, 2, 4) ORDER BY ID;"
pin "7 HASH(COALESCE(N, 'q')) for the E9 row" NONE "SET LIST ON; SELECT HASH(COALESCE(N, 'q')) H FROM TU WHERE ID = 2;" "H 233"
pin "7 HASH(COALESCE(N, 'q')) for the E9 row" UTF8 "SET LIST ON; SELECT HASH(COALESCE(N, 'q')) H FROM TU WHERE ID = 2;" "Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 HASH(COALESCE(N, 'q')) for the E9 row" WIN1252 "SET LIST ON; SELECT HASH(COALESCE(N, 'q')) H FROM TU WHERE ID = 2;" "H 233"
pin "7 IIF(ID = 1, W1, 'Ω'): the literal into WIN1252" NONE "SET LIST ON; SELECT IIF(ID = 1, W1, 'Ω') V FROM TU WHERE ID = 2;" "V <ce><a9>"
pin "7 IIF(ID = 1, W1, 'Ω'): the literal into WIN1252" UTF8 "SET LIST ON; SELECT IIF(ID = 1, W1, 'Ω') V FROM TU WHERE ID = 2;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "7 IIF(ID = 1, W1, 'Ω'): the literal into WIN1252" WIN1252 "SET LIST ON; SELECT IIF(ID = 1, W1, 'Ω') V FROM TU WHERE ID = 2;" "V <ce><a9>"
pin "7 LOWER(CAST(N AS VARCHAR(10)))" NONE "SET LIST ON; SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID = 1; SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID = 2;" "L <c3><80><c3><89><c3><8e>|L <e9>"
pin "7 LOWER(CAST(N AS VARCHAR(10)))" UTF8 "SET LIST ON; SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID = 1; SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID = 2;" "L <c3><a0><c3><a9><c3><ae>|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 LOWER(CAST(N AS VARCHAR(10)))" WIN1252 "SET LIST ON; SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID = 1; SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID = 2;" "L <e3><80><e3><89><e3><9e>|L <e9>"
alive "7 ...and the session survives it" NONE "SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID IN (1, 2) ORDER BY ID;"
alive "7 ...and the session survives it" UTF8 "SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID IN (1, 2) ORDER BY ID;"
alive "7 ...and the session survives it" WIN1252 "SELECT LOWER(CAST(N AS VARCHAR(10))) L FROM TU WHERE ID IN (1, 2) ORDER BY ID;"
pin "7 CONTROL (N || 'x') || U and N || 'x' || U" NONE "SET LIST ON; SELECT (N || 'x') || U C1 FROM TU WHERE ID = 1; SELECT N || 'x' || U C2 FROM TU WHERE ID = 2;" "C1 <c3><80><c3><89><c3><8e>x<c3><80><c3><89><c3><8e>|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 CONTROL (N || 'x') || U and N || 'x' || U" UTF8 "SET LIST ON; SELECT (N || 'x') || U C1 FROM TU WHERE ID = 1; SELECT N || 'x' || U C2 FROM TU WHERE ID = 2;" "C1 <c3><80><c3><89><c3><8e>x<c3><80><c3><89><c3><8e>|Statement failed, SQLSTATE = 22000|Malformed string"
pin "7 CONTROL (N || 'x') || U and N || 'x' || U" WIN1252 "SET LIST ON; SELECT (N || 'x') || U C1 FROM TU WHERE ID = 1; SELECT N || 'x' || U C2 FROM TU WHERE ID = 2;" "C1 <c3><80><c3><89><c3><8e>x<c0><c9><ce>|C2 <e9>xabc"
pin "7 REPLACE('aÉb', U, 'x') / REPLACE('aÉb', W1, 'x'): a NONE literal delivered through the negotiated set" NONE "SET LIST ON; SELECT ID, REPLACE('aÉb', U, 'x') R1, REPLACE('aÉb', W1, 'x') R2 FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|R1 a<c3><89>b|R2 a<c3><89>b|ID 2|R1 a<c3><89>b|R2 a<c3><89>b"
alive "7 ...and the session survives it" NONE "SELECT ID, REPLACE('aÉb', U, 'x') R1, REPLACE('aÉb', W1, 'x') R2 FROM TU WHERE ID IN (1, 2) ORDER BY ID;"
pin "7 TRIM(W1 FROM 'ÀÉÎx') / TRIM(U FROM 'ÀÉÎx'): the real operand byte-copied into the literal's NONE" NONE "SET LIST ON; SELECT ID, TRIM(W1 FROM 'ÀÉÎx') T1, TRIM(U FROM 'ÀÉÎx') T2 FROM TU WHERE ID IN (1, 2) ORDER BY ID;" "ID 1|T1 <c3><80><c3><89><c3><8e>x|T2 x|ID 2|T1 x|T2 <c3><80><c3><89><c3><8e>x"
pin "7 LPAD('ab', 5, W1) / LPAD('ab', 5, U) pad with the real operand's BYTES" NONE "SET LIST ON; SELECT ID, LPAD('ab', 5, W1) L1, LPAD('ab', 5, U) L2 FROM TU WHERE ID IN (1, 2, 3) ORDER BY ID;" "ID 1|L1 <c0><c9><ce>ab|L2 <c3><80><c3>ab|ID 2|L1 <c3><80><c3>ab|L2 abcab|ID 3|L1 <9f><83><9f>ab|L2 <c3><9f><c3>ab"
alive "7 ...and the session survives it" NONE "SELECT ID, LPAD('ab', 5, W1) L1, LPAD('ab', 5, U) L2 FROM TU WHERE ID IN (1, 2, 3) ORDER BY ID;"
pin "7 ASCII outranks the NONE literal: A || 'É' and COALESCE(A, 'É')" NONE "SET LIST ON; SELECT A || 'x' C1, COALESCE(A, 'x') C2 FROM TU WHERE ID = 1; SELECT A || 'É' C3 FROM TU WHERE ID = 1; SELECT COALESCE(A, 'É') C4 FROM TU WHERE ID = 4;" "C1 AbCx|C2 AbC|Statement failed, SQLSTATE = 22000|Malformed string|Statement failed, SQLSTATE = 22000|Malformed string"
dpin "7 A || 'x' describes ASCII under NONE" NONE "SELECT A || 'x' C FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 21 charset: 2 SYSTEM.ASCII"
dpin "7 COALESCE(A, 'x') describes ASCII under NONE" NONE "SELECT COALESCE(A, 'x') C FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 2 SYSTEM.ASCII"
dpin "7 CONTROL REPLACE(N, 'É', 'e') still describes the negotiated set" UTF8 "SELECT REPLACE(N, 'É', 'e') R FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 80 charset: 4 SYSTEM.UTF8"
dpin "7 CONTROL LPAD(REPLACE(N, 'É', 'e'), 8, 'x') describes it too" UTF8 "SELECT LPAD(REPLACE(N, 'É', 'e'), 8, 'x') R FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 32 charset: 4 SYSTEM.UTF8"

echo "--- 8. RECORDED: refused, never answered wrong (the five introducer cells were promoted on 2026-09-26, when the introducer began to be respelled)"
pin "8 HASH(_WIN1252 'ab') - the introducer (answers since the introducer rewrite of 2026-09-26)" NONE "SET LIST ON; SELECT HASH(_WIN1252 'ab') H FROM RDB\$DATABASE;" "H 1650"
pin "8 HASH(_UTF8 'ÀÉ')" WIN1252 "SET LIST ON; SELECT HASH(_UTF8 'ÀÉ') H FROM RDB\$DATABASE;" "H 834745"
pin "8 LOWER(_WIN1252 'ÄÖÜ') - the UTF8 bytes read as WIN1252 chars, lowered, shipped as UTF8" UTF8 "SET LIST ON; SELECT LOWER(_WIN1252 'ÄÖÜ') L FROM RDB\$DATABASE;" "L <c3><a3><e2><80><9e><c3><a3><e2><80><93><c3><a3><c5><93>"
pin "8 UPPER(_NONE 'äöü') - NONE cases ASCII only" NONE "SET LIST ON; SELECT UPPER(_NONE 'äöü') L FROM RDB\$DATABASE;" "L <c3><a4><c3><b6><c3><bc>"
pin "8 POSITION(_WIN1252 'É' IN W1)" UTF8 "SET LIST ON; SELECT ID, POSITION(_WIN1252 'É' IN W1) P FROM TU ORDER BY ID;" "ID 1|P 0|ID 2|P 3|ID 3|P 0|ID 4|P <null>"
differs "8 HASH('a', 'b') is the engine's syntax error, a bare 42000 here" NONE "SET LIST ON; SELECT HASH('a', 'b') H FROM RDB\$DATABASE;"
differs "8 HASH() likewise" NONE "SET LIST ON; SELECT HASH() H FROM RDB\$DATABASE;"
differs "8 HASH('abc' USING) - no algorithm at all - is the engine's syntax error, a bare 42000 here" NONE "SET LIST ON; SELECT HASH('abc' USING) H FROM RDB\$DATABASE;"
differs "8 HASH('abc' USING 'CRC32') - a string, not a name - likewise" NONE "SET LIST ON; SELECT HASH('abc' USING 'CRC32') H FROM RDB\$DATABASE;"

echo "--- 9. A SIMPLE CASE / DECODE RETURNS ITS CHOSEN BRANCH AS IT IS, IN THE BRANCH'S OWN SET"
pin "9 LOWER / HASH over DECODE(ID, 1, W1, 'Ω'): each row in its branch's set" UTF8 "SET LIST ON; SELECT ID, LOWER(DECODE(ID, 1, W1, 'Ω')) L, HASH(DECODE(ID, 1, W1, 'Ω')) H FROM TU ORDER BY ID;" "ID 1|L <c3><a0><c3><a9><c3><ae>|H 52574|ID 2|L <cf><89>|H 3465|ID 3|L <cf><89>|H 3465|ID 4|L <cf><89>|H 3465"
pin "9 LOWER / HASH over DECODE(ID, 1, W1, 'Ω'): each row in its branch's set" WIN1252 "SET LIST ON; SELECT ID, LOWER(DECODE(ID, 1, W1, 'Ω')) L, HASH(DECODE(ID, 1, W1, 'Ω')) H FROM TU ORDER BY ID;" "ID 1|L <e0><e9><ee>|H 52574|ID 2|L <ee><a9>|H 3465|ID 3|L <ee><a9>|H 3465|ID 4|L <ee><a9>|H 3465"
pin "9 LOWER / HASH over DECODE(ID, 1, W1, 'Ω'): each row in its branch's set" NONE "SET LIST ON; SELECT ID, LOWER(DECODE(ID, 1, W1, 'Ω')) L, HASH(DECODE(ID, 1, W1, 'Ω')) H FROM TU ORDER BY ID;" "ID 1|L <e0><e9><ee>|H 52574|ID 2|L <ce><a9>|H 3465|ID 3|L <ce><a9>|H 3465|ID 4|L <ce><a9>|H 3465"
pin "9 DECODE(ID, 1, W1, 2, U, 'Ω') and LOWER of it" UTF8 "SET LIST ON; SELECT ID, DECODE(ID, 1, W1, 2, U, 'Ω') D, LOWER(DECODE(ID, 1, W1, 2, U, 'Ω')) L FROM TU ORDER BY ID;" "ID 1|D <c3><80><c3><89><c3><8e>|L <c3><a0><c3><a9><c3><ae>|ID 2|D abc|L abc|ID 3|D <ce><a9>|L <cf><89>|ID 4|D <ce><a9>|L <cf><89>"
pin "9 DECODE(ID, 1, W1, 2, U, 'Ω') and LOWER of it" NONE "SET LIST ON; SELECT ID, DECODE(ID, 1, W1, 2, U, 'Ω') D, LOWER(DECODE(ID, 1, W1, 2, U, 'Ω')) L FROM TU ORDER BY ID;" "ID 1|D <c0><c9><ce>|L <e0><e9><ee>|ID 2|D abc|L abc|ID 3|D <ce><a9>|L <ce><a9>|ID 4|D <ce><a9>|L <ce><a9>"
pin "9 CASE ID WHEN .. ELSE 'Ω' END, and UPPER over CASE ID WHEN 1 THEN W1 ELSE 'ω' END" UTF8 "SET LIST ON; SELECT ID, CASE ID WHEN 1 THEN W1 WHEN 2 THEN U ELSE 'Ω' END D, UPPER(CASE ID WHEN 1 THEN W1 ELSE 'ω' END) U2 FROM TU ORDER BY ID;" "ID 1|D <c3><80><c3><89><c3><8e>|U2 <c3><80><c3><89><c3><8e>|ID 2|D abc|U2 <ce><a9>|ID 3|D <ce><a9>|U2 <ce><a9>|ID 4|D <ce><a9>|U2 <ce><a9>"
pin "9 OCTET_LENGTH / CHAR_LENGTH / BIT_LENGTH over it: the literal's own octets" UTF8 "SET LIST ON; SELECT ID, OCTET_LENGTH(DECODE(ID, 1, W1, 'Ω')) O, CHAR_LENGTH(DECODE(ID, 1, W1, 'Ω')) C, BIT_LENGTH(DECODE(ID, 1, W1, 'Ω')) B FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|O 3|C 3|B 24|ID 2|O 2|C 1|B 16"
pin "9 OCTET_LENGTH / CHAR_LENGTH / BIT_LENGTH over it: the literal's own octets" WIN1252 "SET LIST ON; SELECT ID, OCTET_LENGTH(DECODE(ID, 1, W1, 'Ω')) O, CHAR_LENGTH(DECODE(ID, 1, W1, 'Ω')) C, BIT_LENGTH(DECODE(ID, 1, W1, 'Ω')) B FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|O 3|C 3|B 24|ID 2|O 2|C 2|B 16"
pin "9 a NONE branch is delivered by its bytes: CASE ID WHEN 2 THEN N ELSE W1 END" UTF8 "SET LIST ON; SELECT ID, CASE ID WHEN 2 THEN N ELSE W1 END D FROM TU ORDER BY ID;" "ID 1|D <c3><80><c3><89><c3><8e>|Statement failed, SQLSTATE = 22000|Malformed string"
pin "9 a NONE branch is delivered by its bytes: CASE ID WHEN 2 THEN N ELSE W1 END" WIN1252 "SET LIST ON; SELECT ID, CASE ID WHEN 2 THEN N ELSE W1 END D FROM TU ORDER BY ID;" "ID 1|D <c0><c9><ce>|ID 2|D <e9>|ID 3|D <9f><83>|ID 4|D <null>"
pin "9 LOWER(CASE ID WHEN 1 THEN N ELSE W1 END): the NONE row cases ASCII only, the WIN1252 row by its table" UTF8 "SET LIST ON; SELECT ID, LOWER(CASE ID WHEN 1 THEN N ELSE W1 END) L FROM TU ORDER BY ID;" "ID 1|L <c3><80><c3><89><c3><8e>|ID 2|L <c3><a3><e2><82><ac><c3><a3><e2><80><b0><c3><a3><c5><be>|ID 3|L <c3><bf><c6><92>|ID 4|L <null>"
pin "9 LOWER(CASE ID WHEN 1 THEN N ELSE W1 END): the NONE row cases ASCII only, the WIN1252 row by its table" WIN1252 "SET LIST ON; SELECT ID, LOWER(CASE ID WHEN 1 THEN N ELSE W1 END) L FROM TU ORDER BY ID;" "ID 1|L <c3><80><c3><89><c3><8e>|ID 2|L <e3><80><e3><89><e3><9e>|ID 3|L <ff><83>|ID 4|L <null>"
pin "9 LOWER(CASE ID WHEN 1 THEN N ELSE W1 END): the NONE row cases ASCII only, the WIN1252 row by its table" NONE "SET LIST ON; SELECT ID, LOWER(CASE ID WHEN 1 THEN N ELSE W1 END) L FROM TU ORDER BY ID;" "ID 1|L <c3><80><c3><89><c3><8e>|ID 2|L <e3><80><e3><89><e3><9e>|ID 3|L <ff><83>|ID 4|L <null>"
pin "9 ||, LPAD and SUBSTRING over DECODE(ID, 1, W1, 'Ω')" UTF8 "SET LIST ON; SELECT ID, DECODE(ID, 1, W1, 'Ω') || 'x' C, LPAD(DECODE(ID, 1, W1, 'Ω'), 5, 'x') P, SUBSTRING(DECODE(ID, 1, W1, 'Ωab') FROM 2) S FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|C <c3><80><c3><89><c3><8e>x|P xx<c3><80><c3><89><c3><8e>|S <c3><89><c3><8e>|ID 2|C <ce><a9>x|P xxxx<ce><a9>|S ab"
pin "9 CAST(DECODE(...) AS VARCHAR(10) CHARACTER SET UTF8) converts from the branch's set" UTF8 "SET LIST ON; SELECT ID, CAST(DECODE(ID, 1, W1, 'Ω') AS VARCHAR(10) CHARACTER SET UTF8) S FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|S <c3><80><c3><89><c3><8e>|ID 2|S <ce><a9>"
pin "9 CAST(DECODE(...) AS VARCHAR(10) CHARACTER SET UTF8) converts from the branch's set" NONE "SET LIST ON; SELECT ID, CAST(DECODE(ID, 1, W1, 'Ω') AS VARCHAR(10) CHARACTER SET UTF8) S FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|S <c3><80><c3><89><c3><8e>|ID 2|S <ce><a9>"
pin "9 nested: UPPER(LOWER(DECODE(...))) and a DECODE inside a DECODE" UTF8 "SET LIST ON; SELECT ID, UPPER(LOWER(DECODE(ID, 1, W1, 'Ω'))) U1, LOWER(DECODE(ID, 1, W1, LOWER(DECODE(ID, 2, U, 'Ω')))) L2 FROM TU ORDER BY ID;" "ID 1|U1 <c3><80><c3><89><c3><8e>|L2 <c3><a0><c3><a9><c3><ae>|ID 2|U1 <ce><a9>|L2 abc|ID 3|U1 <ce><a9>|L2 <cf><89>|ID 4|U1 <ce><a9>|L2 <cf><89>"
pin "9 nested: UPPER(LOWER(DECODE(...))) and a DECODE inside a DECODE" NONE "SET LIST ON; SELECT ID, UPPER(LOWER(DECODE(ID, 1, W1, 'Ω'))) U1, LOWER(DECODE(ID, 1, W1, LOWER(DECODE(ID, 2, U, 'Ω')))) L2 FROM TU ORDER BY ID;" "ID 1|U1 <c0><c9><ce>|L2 <e0><e9><ee>|ID 2|U1 <ce><a9>|L2 abc|ID 3|U1 <ce><a9>|L2 <ce><a9>|ID 4|U1 <ce><a9>|L2 <ce><a9>"
pin "9 the simple CASE spelling, and HASH of a WIN1252 / UTF8 pair" UTF8 "SET LIST ON; SELECT ID, CASE ID WHEN 1 THEN W1 ELSE 'Ω' END D, HASH(CASE ID WHEN 1 THEN W1 ELSE U END) H FROM TU WHERE ID < 3 ORDER BY ID;" "ID 1|D <c3><80><c3><89><c3><8e>|H 52574|ID 2|D <ce><a9>|H 26499"
pin "9 CONTROL MAX(DECODE(ID, 1, W1, 'Ω')) folds in the negotiated set (22018 under UTF8)" UTF8 "SET LIST ON; SELECT MAX(DECODE(ID, 1, W1, 'Ω')) M FROM TU;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "9 CONTROL MAX(DECODE(ID, 1, W1, 'Ω')) folds in the negotiated set (22018 under UTF8)" WIN1252 "SET LIST ON; SELECT MAX(DECODE(ID, 1, W1, 'Ω')) M FROM TU;" "M <ce><a9>"
pin "9 CONTROL the SEARCHED CASE still casts into the negotiated set" UTF8 "SET LIST ON; SELECT ID, CASE WHEN ID = 1 THEN W1 ELSE 'Ω' END D FROM TU WHERE ID = 2;" "Statement failed, SQLSTATE = 22018|arithmetic exception, numeric overflow, or string truncation|-Cannot transliterate character between character sets"
pin "9 CONTROL = between real sets survives the negotiated reading" UTF8 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE CASE ID WHEN 1 THEN W1 ELSE 'q' END = 'q';" "C 3"
pin "9 CONTROL a comparison over a NONE / WIN1252 CASE against a WIN1252 or NONE literal is a byte compare either way" WIN1252 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE CASE ID WHEN 2 THEN N ELSE W1 END = 'é';" "C 0"
pin "9 CONTROL a comparison over a NONE / WIN1252 CASE against a WIN1252 or NONE literal is a byte compare either way" NONE "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE CASE ID WHEN 2 THEN N ELSE W1 END = 'é';" "C 0"
alive "9 ...and the session survives it" UTF8 "SELECT ID, LOWER(DECODE(ID, 1, W1, 'Ω')) L FROM TU ORDER BY ID;"
dpin "9 the describe is the negotiated one: DECODE(ID, 1, W1, 'Ω')" UTF8 "SELECT DECODE(ID, 1, W1, 'Ω') D FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 80 charset: 4 SYSTEM.UTF8"
dpin "9 the describe is the negotiated one: DECODE(ID, 1, W1, 'Ω')" NONE "SELECT DECODE(ID, 1, W1, 'Ω') D FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 53 SYSTEM.WIN1252"
dpin "9 ...and LOWER over it describes the same" NONE "SELECT LOWER(DECODE(ID, 1, W1, 'Ω')) L FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 20 charset: 53 SYSTEM.WIN1252"
dpin "9 ...and || over it" NONE "SELECT DECODE(ID, 1, W1, 'Ω') || 'x' C FROM TU;" "01: sqltype: 448 VARYING Nullable scale: 0 subtype: 0 len: 21 charset: 53 SYSTEM.WIN1252"
dpin "9 ...and HASH over it is a nullable BIGINT" UTF8 "SELECT HASH(DECODE(ID, 1, W1, 'Ω')) H FROM TU;" "01: sqltype: 580 INT64 Nullable scale: 0 subtype: 0 len: 8"
refused "9 RECORDED a NONE branch compared with a UTF8 literal: the engine counts 0, the negotiated reading counted 1 - refused" UTF8 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE CASE ID WHEN 2 THEN N ELSE W1 END = 'é';"
refused "9 RECORDED a WIN1252 / UTF8 CASE compared with a NONE column: the engine counts 1, the negotiated reading counted 0 - refused" UTF8 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE CASE ID WHEN 2 THEN W1 ELSE U END = N;"
refused "9 RECORDED a WIN1252 / UTF8 CASE compared with a NONE column: the engine counts 1, the negotiated reading counted 0 - refused" WIN1252 "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE CASE ID WHEN 2 THEN W1 ELSE U END = N;"
refused "9 RECORDED a WIN1252 / UTF8 CASE compared with a NONE column: the engine counts 1, the negotiated reading counted 0 - refused" NONE "SET LIST ON; SELECT COUNT(*) C FROM TU WHERE CASE ID WHEN 2 THEN W1 ELSE U END = N;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-csfn-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 292 ]; then echo "FAIL only $ran checks ran (floor 292)"; fail=1; fi
exit $fail
