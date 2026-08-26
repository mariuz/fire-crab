#!/bin/bash
# Constant EXPRESSIONS in INSERT ... VALUES - the engine accepts any value
# expression there; fire-crab's VALUES list was a fixed set of token
# shapes, so `1e3`, `1+2`, `'A'||'B'`, `(5)`, `UPPER('x')`, `CAST('55' AS
# INTEGER)`, `DATE '..' + 1`, `2.5 * 2`, `1 > 0`, `COALESCE(NULL, 3.25)`
# all refused. Now any item that is not one of the staged shapes (a
# parameter, DEFAULT, a generator, a blob-bound string) is parsed as an
# expression, resolved WITH NO COLUMNS, evaluated at plan (the query
# side's own clock rule), and staged in its wire-parameter form - one
# shared Value-to-WireParam mapping with the UPDATE expression tier, so
# the two DML halves cannot drift.
#
# FOUND ON THE WAY, fixed here: the BOOLEAN WIRE ENCODING was a
# big-endian int (value byte LAST) where XDR opaque puts the value byte
# FIRST - every boolean OUTPUT column read <false> at isql/libfbclient
# (SELECT TRUE included) while WHERE and CAST were right; the engine read
# fc's STORED booleans correctly all along (the write side was fine), and
# the patched node driver's metadata-directed decoding masked it in the
# node gates. The old unit pin asserted the wrong form and was corrected.
#
# Boundaries (recorded): an expression that RAISES folds at plan into fc's generic
# refusal where the engine raises its typed vector at execute (1/0 -
# 22012 there); a `?` inside an expression refuses (engine: 07002); a hex
# literal (0x1F) is a pre-existing lexer gap; a blob-valued expression
# into a BLOB column refuses (the plain string form works).
#
#   qa/serve-real-insertexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4961}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-iex-crab.fdb"; B="$D/fc-iex-engine.fdb"
LOG="/tmp/fc-serve-iex-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

cat > "$D/iex.sql" <<'SQL'
CREATE TABLE TE (ID INTEGER, N NUMERIC(9,2), S VARCHAR(20), DP DOUBLE PRECISION, B BOOLEAN, D DATE, BG BIGINT, SI SMALLINT);
COMMIT;
INSERT INTO TE (ID, DP) VALUES (1, 1e3);
INSERT INTO TE (ID, DP) VALUES (2, -1.5E-2);
INSERT INTO TE (ID) VALUES ((6));
INSERT INTO TE (ID) VALUES (1+2);
INSERT INTO TE (ID, S) VALUES (7, 'A'||'B');
INSERT INTO TE (ID, S) VALUES (8, UPPER('xy'));
INSERT INTO TE (ID) VALUES (CAST('55' AS INTEGER));
INSERT INTO TE (ID, D) VALUES (10, DATE '2020-01-15' + 1);
INSERT INTO TE (ID, N) VALUES (11, 2.5 * 2);
INSERT INTO TE (ID, B) VALUES (12, 1 > 0);
INSERT INTO TE (ID, B) VALUES (13, 1 < 0);
INSERT INTO TE (ID, BG) VALUES (14, 4000000000 + 1);
INSERT INTO TE (ID, S) VALUES (15, LEFT('hello', 3));
INSERT INTO TE (ID, N) VALUES (16, COALESCE(NULL, 3.25));
INSERT INTO TE (ID, S) VALUES (17, NULLIF('a','a'));
INSERT INTO TE (ID, N) VALUES (18, -(2.5));
INSERT INTO TE (ID, S) VALUES (19, IIF(2>1, 'y', 'n'));
INSERT INTO TE (ID, N) VALUES (20, ABS(-7.25));
INSERT INTO TE (ID, DP) VALUES (21, SQRT(2));
INSERT INTO TE (ID, S) VALUES (22, TRIM('  pad  '));
INSERT INTO TE (ID, SI) VALUES (23, 100 - 358);
INSERT INTO TE (ID, S) VALUES (24, CASE WHEN 1=2 THEN 'a' WHEN 2=2 THEN 'b' END);
INSERT INTO TE (ID, DP) VALUES (25, 3.0 / 4);
INSERT INTO TE (ID, N) VALUES (26, CAST(NULL AS INTEGER));
INSERT INTO TE (ID, S) VALUES (27, 1 > 0);
INSERT INTO TE (ID, N) VALUES (28, 1.005e0);
INSERT INTO TE (ID, N) VALUES (29, 1.005);
INSERT INTO TE (ID, N) VALUES (30, -1.005);
INSERT INTO TE (ID, S) VALUES (31, 2.50 * 1);
INSERT INTO TE (ID, S) VALUES (32, SQRT(2));
COMMIT;
SET LIST ON;
SELECT ID, N, S, DP, B, D, BG, SI FROM TE ORDER BY ID;
SQL
xof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/iex.sql" 2>&1 | norm; }
check "every constant-expression VALUES form stores what the engine stores" \
    "$(xof "127.0.0.1/$PORT:$A")" "$(xof "127.0.0.1/$REAL:$B")"

# --- the boolean wire: TRUE reads TRUE at a real client (the old int
# --- encoding read every boolean output as false at isql)
cat > "$D/bool.sql" <<'SQL'
SET LIST ON;
SELECT TRUE LT, FALSE LF, 1 > 0 LC FROM RDB$DATABASE;
SELECT ID, B FROM TE WHERE ID IN (12, 13) ORDER BY ID;
SELECT COUNT(*) CT FROM TE WHERE B;
SQL
bof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/bool.sql" 2>&1 | norm; }
check "boolean OUTPUT columns travel XDR-opaque (SELECT TRUE is <true> at isql)" \
    "$(bof "127.0.0.1/$PORT:$A")" "$(bof "127.0.0.1/$REAL:$B")"

# --- the engine reads fc's stored rows, value for value ---
ran=$((ran + 1))
eng=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
SELECT ID, N, S, DP, B, BG, SI FROM TE WHERE ID IN (2, 11, 12, 14, 21, 23) ORDER BY ID;
SQL
)
crab=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
SELECT ID, N, S, DP, B, BG, SI FROM TE WHERE ID IN (2, 11, 12, 14, 21, 23) ORDER BY ID;
SQL
)
if [ -n "$eng" ] && [ "$eng" = "$crab" ]; then echo "OK   the engine reads fc's stored expression values, line for line"; else
    echo "DIFF engine-reads-fc: [$eng] vs [$crab]"; fail=1; fi

# --- UPDATE keeps the SAME mapping (the shared value_to_wireparam) ---
cat > "$D/upd.sql" <<'SQL'
UPDATE TE SET DP = 2e2, S = 'u'||'v', B = 3 > 4, N = 1.5 + 1 WHERE ID = 6;
COMMIT;
SET LIST ON;
SELECT N, S, DP, B FROM TE WHERE ID = 6;
SQL
uof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/upd.sql" 2>&1 | norm; }
check "UPDATE SET folds through the same mapping" \
    "$(uof "127.0.0.1/$PORT:$A")" "$(uof "127.0.0.1/$REAL:$B")"

# --- temporal arithmetic and boolean coercion, review-caught and fixed:
# --- TIME +/- n is SECONDS (fraction kept, midnight wrap), TIMESTAMP
# --- keeps the day FRACTION, DATE + TIME is that day at that time,
# --- TRUE || '' spells TRUE
cat > "$D/tar.sql" <<'SQL'
SET LIST ON;
SELECT TIME '10:00:00' + 1 A, TIME '23:59:59' + 2 AW, TIME '10:00:00' - 1 AS_ FROM RDB$DATABASE;
SELECT TIME '10:00:00' + 1.5 B FROM RDB$DATABASE;
SELECT DATE '2020-01-15' + TIME '10:20:30' C, TIME '10:20:30' + DATE '2020-01-15' C2 FROM RDB$DATABASE;
SELECT TIMESTAMP '2020-01-15 12:00:00' + 0.25 DD, TIMESTAMP '2020-01-15 12:00:00' - 0.25 DS FROM RDB$DATABASE;
SELECT DATE '2020-01-15' + 1.5 E FROM RDB$DATABASE;
SELECT TRUE || '' F FROM RDB$DATABASE;
SQL
tof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/tar.sql" 2>&1 | norm; }
check "temporal arithmetic (TIME seconds with wrap, TIMESTAMP day fraction, DATE + TIME) and TRUE || ''" \
    "$(tof "127.0.0.1/$PORT:$A")" "$(tof "127.0.0.1/$REAL:$B")"

# --- refusals: shapes fc must not guess at ---
bref() { ran=$((ran + 1))
    local c
    c=$(echo "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$c" in *"Dynamic SQL Error"*) echo "OK   $1 (refused)";;
        *) echo "DIFF $1 answered: [$c]"; fail=1;; esac
}
bref "a typeless fold refuses rather than storing NULL ('5' + 1)" "INSERT INTO TE (ID) VALUES ('5' + 1);"
# a scalar subquery IS a value now (serve-real-subqval.sh): answered once
# and folded in as the literal it computed
sqv="INSERT INTO TE (ID, S) VALUES (90, (SELECT 'q' FROM RDB\$DATABASE)); COMMIT; SET LIST ON; SELECT ID, S FROM TE WHERE ID = 90;"
check "a scalar subquery is a value" \
    "$(printf '%s\n' "$sqv" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)" \
    "$(printf '%s\n' "$sqv" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)"
bref "a raising fold refuses at plan (engine: 22012 at execute)" "INSERT INTO TE (ID) VALUES (1/0);"
bref "a parameter inside an expression refuses (engine: 07002)" "INSERT INTO TE (ID) VALUES (? + 1);"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
