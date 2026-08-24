#!/bin/bash
# HASH(s) - the engine's default (one-argument) hash: WeakHashContext in
# Hash.cpp, a 64-bit ELF-style rolling hash over the value's bytes -
# `h = (h << 4) + byte`, then the top nibble is folded down (`h ^= n >> 56`)
# and cleared. Result BIGINT. Joins the SysFn scalar machinery beside CRC32.
#
# Covered (fc vs the live engine): the value over short and LONG literals
# (the long ones exercise the nibble-fold high-bit path), an empty string,
# a UTF-8 multibyte literal, and a column with a NULL row (NULL propagates);
# the describe (BIGINT).
#
# Boundaries (recorded): a non-text operand refuses (the engine hashes its
# string conversion, unpinned here); HASH of a value stored in a NON-UTF8
# single-byte charset column hashes fc's UTF-8 form where the engine hashes
# the stored bytes (UTF-8 / ASCII / NONE agree); the two-argument crypto
# form (MD5/SHA/...) is not taken.
#
#   qa/serve-real-hash.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4949}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-hash-crab.fdb"; B="$D/fc-hash-engine.fdb"
LOG="/tmp/fc-serve-hash-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
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

SET="CREATE TABLE T(C VARCHAR(60));
INSERT INTO T VALUES ('hello');
INSERT INTO T VALUES ('');
INSERT INTO T VALUES ('a repeated string a repeated string a repeated string');
INSERT INTO T VALUES (NULL);
COMMIT;"
"$ISQL" -q -user "$U" -pas "$P" -ch UTF8 "127.0.0.1/$PORT:$A" <<< "$SET" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" -ch UTF8 "127.0.0.1/$REAL:$B" <<< "$SET" >/dev/null 2>&1

cat > "$D/v.sql" <<'SQL'
SET LIST ON;
SELECT HASH('abc') A, HASH('') E, HASH('a') S FROM RDB$DATABASE;
SELECT HASH('The quick brown fox jumps over the lazy dog') L1,
       HASH('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaXYZ') L2 FROM RDB$DATABASE;
SELECT HASH('café') UTF FROM RDB$DATABASE;
SELECT COALESCE(HASH(C), -1) H FROM T ORDER BY C NULLS LAST;
SQL
vof() { "$ISQL" -q -user "$U" -pas "$P" -ch UTF8 "$1" -i "$D/v.sql" 2>&1 | norm; }
check "HASH values (short/long/empty/UTF-8/column + NULL)" \
    "$(vof "127.0.0.1/$PORT:$A")" "$(vof "127.0.0.1/$REAL:$B")"

cat > "$D/d.sql" <<'SQL'
SET SQLDA_DISPLAY ON;
SELECT HASH('x'), HASH(C) FROM T ROWS 1;
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" -ch UTF8 "$1" -i "$D/d.sql" 2>&1 | grep -iE "sqltype" | norm; }
check "the describe - BIGINT" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
