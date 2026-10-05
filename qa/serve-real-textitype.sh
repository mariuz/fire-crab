#!/bin/bash
# A TEXT INDEX'S KEY TYPE IS THE COLUMN'S SET. This server stamped every
# text index idx_string (1); the engine (DFW_assign_index_type, measured on
# 2196 off its own index roots) stamps UTF8 idx_metadata (4), a tabled
# single-byte set at its default collation idx_offset_intl + ttype
# (WIN1252 32884, ISO8859_1 32852), NONE and ASCII 1. The key bytes differ
# with it (an empty value keys 0x20 under 1 and 0x00 under the others), so
# the two files were not the same index. Now they are: the index roots
# compare equal (fcstat), the ENGINE reads this server's file through every
# index exactly as its own, and gfix finds it clean.
#
# Refused now: an index on a set with no codepage table here (DOS437 and
# kin) - its text keyed as UTF-8 bytes and the engine misordered and missed
# rows. OCTETS keys idx_byte_array (3: raw bytes, trailing 0x00 stripped)
# and UNICODE_FSS 32834 (idx_metadata's shape), read off the engine's trees.
#
#   qa/serve-real-textitype.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4634}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/txit-eng-$PORT.fdb"; FC="$D/txit-fc-$PORT.fdb"; VFY="$D/txit-vfy-$PORT.fdb"
EC="/tmp/txit-eng-$PORT.copy"
[ -x "$FCSTAT" ] || { echo "SKIP fcstat not built ($FCSTAT)"; exit 0; }
mkdir -p "$D"
sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" "$EC" 2>/dev/null
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE D (ID INT, U VARCHAR(10), W VARCHAR(10) CHARACTER SET WIN1252, I VARCHAR(10) CHARACTER SET ISO8859_1, C CHAR(4), A VARCHAR(10) CHARACTER SET ASCII);
CREATE TABLE R (ID INT, O VARCHAR(10) CHARACTER SET OCTETS, F VARCHAR(10) CHARACTER SET UNICODE_FSS, P VARCHAR(10) CHARACTER SET DOS437);
CREATE TABLE S (ID INT, O CHAR(3) CHARACTER SET OCTETS, F VARCHAR(10) CHARACTER SET UNICODE_FSS);
CREATE INDEX S_O ON S (O);
CREATE UNIQUE INDEX S_F ON S (F);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b -ch UTF8 > /tmp/txit-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/txit-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-txit-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; sudo -n rm -f "$ENG" "$FC" "$VFY" 2>/dev/null; rm -f "$ENG" "$FC" "$VFY" "$EC" 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
run() { printf '%s\n' "$2" | timeout -s KILL 60 "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' | grep -av '^$'; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}
roots() { "$FCSTAT" indexes "$1" "$2" 2>&1 | sed -E 's/root page [0-9]+, //; s/state [0-9]+, //'; }

DDL="INSERT INTO D VALUES (1, 'abc', 'abc', 'abc', 'ab', 'abc');
INSERT INTO D VALUES (2, '', '', '', '', '');
INSERT INTO D VALUES (3, 'é', 'é', 'é', 'é', 'x');
INSERT INTO D VALUES (4, NULL, NULL, NULL, NULL, NULL);
INSERT INTO D VALUES (5, 'abc  ', 'Ab', 'Zz', 'z ', 'y');
COMMIT;
CREATE INDEX X_U ON D (U);
CREATE INDEX X_W ON D (W);
CREATE INDEX X_I ON D (I);
CREATE DESCENDING INDEX X_W2 ON D (W, ID);
CREATE INDEX X_C ON D (C);
CREATE INDEX X_A ON D (A);
CREATE UNIQUE INDEX X_UID ON D (U, ID);
COMMIT;
INSERT INTO D VALUES (6, ' ', 'É', 'ß', ' a', 'q');
UPDATE D SET U = 'zzz', W = 'zzz' WHERE ID = 1;
COMMIT;"
echo "--- 1 the same DDL and DML on both files"
check "1 seven text indexes over five sets, then writes" "$(run "127.0.0.1/$REAL:$ENG" "$DDL")" "$(run "127.0.0.1/$PORT:$FC" "$DDL")"

echo "--- 2 the index roots carry the engine's key types"
cp "$FC" "$VFY"; chmod 666 "$VFY"
sudo -n cat "$ENG" > "$EC" 2>/dev/null || cat "$ENG" > "$EC"
check "2 every slot's flags and segment itypes (UTF8 4, WIN1252 32884, ISO8859_1 32852, CHAR 4, ASCII 1)" \
    "$(roots "$EC" 128)" "$(roots "$VFY" 128)"

echo "--- 3 the ENGINE reads this server's file through every index"
for c in U W I C A; do
    Q="SET PLAN ON;"
    for v in "''" "'abc'" "'é'" "' '" "'zzz'"; do
        Q="$Q
SELECT ID FROM D WHERE $c = $v ORDER BY ID;
SELECT ID FROM D WHERE $c >= $v ORDER BY $c, ID;"
    done
    Q="$Q
SELECT ID FROM D ORDER BY $c, ID;"
    check "3 $c: equality, ranges and ORDER BY through its index" "$(run "127.0.0.1/$REAL:$ENG" "$Q")" "$(run "127.0.0.1/$REAL:$VFY" "$Q")"
done
ran=$((ran + 1))
if "$GFIX" -v -full -user "$U" -pas "$P" "127.0.0.1/$REAL:$VFY" > /tmp/txit-gfix.log 2>&1 && [ ! -s /tmp/txit-gfix.log ]; then
    echo "OK   3 gfix -v -full finds this server's file clean"
else echo "DIFF 3 gfix -v -full:"; sed 's/^/     /' /tmp/txit-gfix.log | head; fail=1; fi

echo "--- 4 OCTETS (idx_byte_array 3) and UNICODE_FSS (32834): built here, read by the engine"
R="INSERT INTO R VALUES (1, x'414200', 'ab', NULL);
INSERT INTO R VALUES (2, x'4142', 'ab  ', NULL);
INSERT INTO R VALUES (3, x'', '', NULL);
INSERT INTO R VALUES (4, x'41422020', 'é', NULL);
INSERT INTO R VALUES (5, NULL, NULL, NULL);
INSERT INTO R VALUES (6, x'FF', 'Ж', NULL);
COMMIT;
CREATE INDEX R_O ON R (O);
CREATE INDEX R_F ON R (F);
CREATE DESCENDING INDEX R_OD ON R (O);
COMMIT;
INSERT INTO R VALUES (7, x'4100', 'Ab', NULL);
UPDATE R SET O = x'00', F = 'z ' WHERE ID = 6;
COMMIT;"
check "4 the DDL and the writes" "$(run "127.0.0.1/$REAL:$ENG" "$R")" "$(run "127.0.0.1/$PORT:$FC" "$R")"
cp "$FC" "$VFY"; chmod 666 "$VFY"
sudo -n cat "$ENG" > "$EC" 2>/dev/null || cat "$ENG" > "$EC"
check "4 the index roots (3, 32834, 3 descending)" "$(roots "$EC" 129)" "$(roots "$VFY" 129)"
Q="SET PLAN ON;
SELECT ID FROM R WHERE O = x'4142' ORDER BY ID;
SELECT ID FROM R WHERE O = x'' ORDER BY ID;
SELECT ID FROM R WHERE O >= x'41' ORDER BY O, ID;
SELECT ID FROM R ORDER BY O DESC, ID;
SELECT ID FROM R WHERE F = 'ab' ORDER BY ID;
SELECT ID FROM R WHERE F >= 'a' ORDER BY F, ID;
SELECT ID FROM R WHERE F = '' ORDER BY ID;"
check "4 the ENGINE reads them, ascending and descending" "$(run "127.0.0.1/$REAL:$ENG" "$Q")" "$(run "127.0.0.1/$REAL:$VFY" "$Q")"
ran=$((ran + 1))
if "$GFIX" -v -full -user "$U" -pas "$P" "127.0.0.1/$REAL:$VFY" > /tmp/txit-gfix.log 2>&1 && [ ! -s /tmp/txit-gfix.log ]; then
    echo "OK   4 gfix -v -full finds it clean"
else echo "DIFF 4 gfix -v -full:"; sed 's/^/     /' /tmp/txit-gfix.log | head; fail=1; fi
ran=$((ran + 1))
c=$(run "127.0.0.1/$PORT:$FC" "CREATE INDEX R_P ON R (P); COMMIT; SELECT COUNT(*) AS N FROM RDB\$INDICES WHERE RDB\$INDEX_NAME = 'R_P';" | sed 's/  */ /g; s/ *$//' | tr '\n' '|')
case "$c" in
    *"Statement failed"*"N|"*"| 0|") echo "OK   4 a DOS437 index is refused here (the engine builds it)" ;;
    *) echo "FAIL 4 a DOS437 index: [$c]"; fail=1 ;;
esac

echo "--- 5 the ENGINE's own OCTETS / UNICODE_FSS indexes take this server's writes (they refused)"
W="INSERT INTO S VALUES (1, x'41', 'ab');
INSERT INTO S VALUES (2, x'4100', 'é');
INSERT INTO S VALUES (3, x'', '');
INSERT INTO S VALUES (4, x'FF00FF', 'Ж');
INSERT INTO S VALUES (5, x'42', 'ab ');
UPDATE S SET O = x'20' WHERE ID = 1;
COMMIT;"
check "5 writes, a UNIQUE FSS duplicate ('ab ' = 'ab')" "$(run "127.0.0.1/$REAL:$ENG" "$W")" "$(run "127.0.0.1/$PORT:$FC" "$W")"
cp "$FC" "$VFY"; chmod 666 "$VFY"
Q="SET PLAN ON;
SELECT ID FROM S WHERE O = x'41' ORDER BY ID;
SELECT ID FROM S WHERE O >= x'20' ORDER BY O, ID;
SELECT ID FROM S WHERE F = 'ab';
SELECT ID FROM S ORDER BY F, ID;"
check "5 the ENGINE reads them back" "$(run "127.0.0.1/$REAL:$ENG" "$Q")" "$(run "127.0.0.1/$REAL:$VFY" "$Q")"
ran=$((ran + 1))
if "$GFIX" -v -full -user "$U" -pas "$P" "127.0.0.1/$REAL:$VFY" > /tmp/txit-gfix.log 2>&1 && [ ! -s /tmp/txit-gfix.log ]; then
    echo "OK   5 gfix -v -full finds it clean"
else echo "DIFF 5 gfix -v -full:"; sed 's/^/     /' /tmp/txit-gfix.log | head; fail=1; fi

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-txit-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 17 on the 2026-10-05 binary, 17 OK (11 before OCTETS / UNICODE_FSS)
if [ "$ran" -lt 17 ]; then echo "FAIL only $ran checks ran (floor 17) - cells went missing"; fail=1; fi
exit $fail
