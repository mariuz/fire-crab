#!/bin/bash
# QUOTED IDENTIFIERS - a double-quoted name is a NAME, not a spelling.
#
# The engine stores a delimited identifier exactly as written and folds
# only the unquoted kind to upper case: `"a"` and `A` are two columns
# of one table, `"tq"` and `TQ` two tables, and `"Order"`, `"Key"`,
# `"value"`, `"select"`, `"Mixed Col"` are ordinary names. The describe
# announces the stored spelling (`name: a`, `name: Mixed Col`).
#
# fire-crab (measured 2026-09-02) folded the quoted kind as well:
# `UPDATE TQ SET "a" = 5` wrote column A, `ORDER BY "a"` sorted by A,
# `SELECT ID, X FROM "tq"` read table TQ, `UPDATE "Order" SET "value" =
# 'x' WHERE "Key" = 1` updated nothing, and a select list naming `"a"`,
# `"Mixed Col"` or `"select"` refused. Every check below is the same
# script on both servers; the fixture is created by the engine AND, in
# a second copy, through fire-crab's own DDL, so that the catalog rows
# fire-crab writes carry the exact spelling too.
#
#   qa/serve-real-quotedname.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4062}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-quotedname-crab.fdb"
B="$D/fc-quotedname-engine.fdb"
C="$D/fc-quotedname-ddl.fdb"
# a PRISTINE engine-built fixture (no DML ran on it): what fire-crab's
# own DDL file must read back as
E="$D/fc-quotedname-pristine.fdb"
LOG="/tmp/fc-serve-quotedname-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

cat >"$D/quotedname-$PORT.sql" <<'EOF'
CREATE TABLE TQ (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, "a" INTEGER, "Mixed Col" VARCHAR(10), "select" INTEGER);
CREATE TABLE "tq" (ID INTEGER NOT NULL PRIMARY KEY, X INTEGER);
CREATE TABLE "Order" ("Key" INTEGER NOT NULL PRIMARY KEY, "value" VARCHAR(5), KEY2 INTEGER);
COMMIT;
INSERT INTO TQ VALUES (1, 100, 1, 'm1', 11);
INSERT INTO TQ VALUES (2, 200, 2, 'm2', 22);
INSERT INTO TQ VALUES (3, 300, 3, 'm3', 33);
INSERT INTO "tq" VALUES (1, 10);
INSERT INTO "tq" VALUES (2, 20);
INSERT INTO "Order" VALUES (1, 'one', 5);
INSERT INTO "Order" VALUES (2, 'two', 6);
COMMIT;
CREATE INDEX IX_A ON TQ ("a");
CREATE VIEW "vq" AS SELECT ID, "a" FROM TQ;
CREATE VIEW VQ AS SELECT ID, A FROM TQ WHERE A > 150;
COMMIT;
EOF
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
make_db "$C" || { echo "FAIL scratch C"; exit 1; }
make_db "$E" || { echo "FAIL scratch E"; exit 1; }
"$ISQL" -q -b -user "$U" -pas "$P" "$E" -i "$D/quotedname-$PORT.sql" >/dev/null 2>&1 || { echo "FAIL fixture E"; exit 1; }
"$ISQL" -q -b -user "$U" -pas "$P" "$A" -i "$D/quotedname-$PORT.sql" >/dev/null 2>&1 || { echo "FAIL fixture A"; exit 1; }
"$ISQL" -q -b -user "$U" -pas "$P" "$B" -i "$D/quotedname-$PORT.sql" >/dev/null 2>&1 || { echo "FAIL fixture B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$C" "$E" "$D/quotedname-$PORT.sql"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
bothd() {
    e=$(printf 'SET SQLDA_DISPLAY ON; SET PLANONLY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a -E 'sqltype|name:|SQLSTATE' | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON; SET PLANONLY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a -E 'sqltype|name:|SQLSTATE' | norm)
    check "$1" "$c" "$e"
}

# ---- 1. reading -----------------------------------------------------------------
both "a select list naming a lower-case, a spaced and a keyword-named quoted column" \
     "SELECT ID, A, \"a\", \"Mixed Col\", \"select\" FROM TQ ORDER BY ID;"
both "unquoted a is A; quoted \"A\" is A too" \
     "SELECT ID, a, \"A\" FROM TQ ORDER BY ID;"
both "ORDER BY, GROUP BY and WHERE on the quoted column" \
     "SELECT ID, A, \"a\" FROM TQ ORDER BY \"a\" DESC; SELECT \"a\", COUNT(*) C FROM TQ GROUP BY \"a\" ORDER BY 1; SELECT ID FROM TQ WHERE \"a\" = 2; SELECT ID FROM TQ WHERE \"Mixed Col\" = 'm1'; SELECT \"select\" FROM TQ WHERE ID = 3;"
both "a quoted lower-case TABLE beside its upper-case twin" \
     "SELECT ID, X FROM \"tq\" ORDER BY ID; SELECT ID FROM tq ORDER BY ID; SELECT COUNT(*) C FROM \"tq\"; SELECT COUNT(*) C FROM TQ;"
both "a table and columns named like keywords" \
     "SELECT \"Key\", \"value\", KEY2 FROM \"Order\" ORDER BY \"Key\"; SELECT o.\"Key\" FROM \"Order\" o WHERE o.\"value\" = 'two';"
both "alias-qualified quoted columns" \
     "SELECT t.\"a\", t.A FROM TQ t WHERE t.\"a\" > 0 ORDER BY t.ID;"
both "quoted output aliases keep their case" \
     "SELECT ID AS \"lower\", A AS \"Mixed\", \"a\" \"a b\" FROM TQ WHERE ID = 1;"
both "a subquery over the quoted twin table" \
     "SELECT ID FROM TQ WHERE \"a\" IN (SELECT X / 10 FROM \"tq\") ORDER BY ID;"
both "views: a quoted view over the quoted column, and the folded twin" \
     "SELECT ID, \"a\" FROM \"vq\" ORDER BY ID; SELECT ID, A FROM VQ ORDER BY ID;"

# ---- 2. writing ------------------------------------------------------------------
both "UPDATE the quoted column: only it changes" \
     "UPDATE TQ SET \"a\" = 5 WHERE ID = 1 RETURNING ID, \"a\", A; SELECT ID, A, \"a\" FROM TQ ORDER BY ID;"
both "UPDATE the folded column by a quoted-column predicate" \
     "UPDATE TQ SET A = 7 WHERE \"a\" = 2 RETURNING ID, \"a\", A; SELECT ID, A, \"a\" FROM TQ ORDER BY ID;"
both "INSERT with a quoted column list, and positional" \
     "INSERT INTO TQ (ID, \"a\") VALUES (4, 4) RETURNING ID, A, \"a\"; INSERT INTO TQ VALUES (5, 500, 55, 'm5', 5) RETURNING *; INSERT INTO TQ (ID, \"Mixed Col\", \"select\") VALUES (6, 'm6', 66) RETURNING ID, \"Mixed Col\", \"select\"; SELECT ID, A, \"a\", \"Mixed Col\", \"select\" FROM TQ ORDER BY ID;"
both "DELETE by the quoted column" \
     "DELETE FROM TQ WHERE \"a\" = 3 RETURNING ID; SELECT COUNT(*) C FROM TQ;"
both "DML on the keyword-named table and columns" \
     "UPDATE \"Order\" SET \"value\" = 'x' WHERE \"Key\" = 1 RETURNING \"Key\", \"value\"; DELETE FROM \"Order\" WHERE \"Key\" = 2 RETURNING \"Key\"; INSERT INTO \"Order\" (\"Key\", \"value\") VALUES (3, 'thr') RETURNING \"Key\", \"value\"; SELECT \"Key\", \"value\", KEY2 FROM \"Order\" ORDER BY \"Key\";"
both "DML on the quoted twin table leaves the folded table alone" \
     "UPDATE \"tq\" SET X = X + 1 WHERE ID = 1 RETURNING ID, X; DELETE FROM \"tq\" WHERE ID = 2 RETURNING ID; SELECT ID, X FROM \"tq\" ORDER BY ID; SELECT ID, A FROM TQ ORDER BY ID;"
both "DML through the quoted view reaches the quoted column" \
     "UPDATE \"vq\" SET \"a\" = 9 WHERE ID = 2 RETURNING ID, \"a\"; SELECT ID, \"a\", A FROM TQ WHERE ID = 2;"
both "an index on the quoted column is used and stays consistent" \
     "SELECT ID FROM TQ WHERE \"a\" = 9; UPDATE TQ SET \"a\" = 10 WHERE ID = 2; SELECT ID FROM TQ WHERE \"a\" = 10; SELECT ID FROM TQ WHERE \"a\" = 9;"

# ---- 3. describes -----------------------------------------------------------------
bothd "the describe announces the stored spelling" \
      "SELECT ID, A, \"a\", \"Mixed Col\", \"select\" FROM TQ WHERE ID = ?;"
bothd "quoted aliases and keyword names in the describe" \
      "SELECT ID AS \"lower\", A AS \"Mixed\", \"Key\" FROM TQ, \"Order\" WHERE ID = ?;"
bothd "UPDATE ... RETURNING describes the quoted column" \
      "UPDATE TQ SET \"a\" = ? WHERE ID = ? RETURNING \"a\", A;"

# ---- 4. DDL through fire-crab writes the exact spelling -----------------------------
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$C" -i "$D/quotedname-$PORT.sql" >/tmp/fc-quotedname-ddl-$PORT.txt 2>&1
ran=$((ran + 1))
if grep -q 'Statement failed' /tmp/fc-quotedname-ddl-$PORT.txt; then echo "DIFF the fixture DDL through fire-crab"; head -5 /tmp/fc-quotedname-ddl-$PORT.txt; fail=1; else echo "OK   the fixture DDL runs through fire-crab"; fi
cat_q="SET LIST ON; SELECT TRIM(RDB\$RELATION_NAME) R, TRIM(RDB\$FIELD_NAME) F FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME IN ('TQ', 'tq', 'Order', 'vq', 'VQ') ORDER BY 1, RDB\$FIELD_POSITION; SELECT TRIM(RDB\$RELATION_NAME) R FROM RDB\$RELATIONS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1; SELECT TRIM(RDB\$INDEX_NAME) I, TRIM(RDB\$FIELD_NAME) F FROM RDB\$INDEX_SEGMENTS WHERE RDB\$INDEX_NAME = 'IX_A';"
e=$(printf '%s\n' "$cat_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$cat_q" | "$ISQL" -q -user "$U" -pas "$P" "$C" 2>&1 | norm)
check "the ENGINE reads the same catalog spellings from fire-crab's own DDL" "$c" "$e"
q2="SET LIST ON; SELECT ID, A, \"a\", \"Mixed Col\", \"select\" FROM TQ ORDER BY ID; SELECT ID, X FROM \"tq\" ORDER BY ID; SELECT \"Key\", \"value\" FROM \"Order\" ORDER BY 1; SELECT ID, \"a\" FROM \"vq\" ORDER BY ID;"
# against the PRISTINE engine fixture: B carries section 2's writes, C only the fixture
e=$(printf '%s\n' "$q2" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | norm)
c=$(printf '%s\n' "$q2" | "$ISQL" -q -user "$U" -pas "$P" "$C" 2>&1 | norm)
check "... and the ENGINE answers the same rows over fire-crab's own DDL file" "$c" "$e"

# ---- the engine reads fire-crab's own file the same way ------------------------------
eng_q="SET LIST ON; SELECT ID, A, \"a\", \"Mixed Col\", \"select\" FROM TQ ORDER BY ID; SELECT ID, X FROM \"tq\" ORDER BY ID; SELECT \"Key\", \"value\", KEY2 FROM \"Order\" ORDER BY 1;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$C" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's DDL file"; else echo "DIFF gfix (ddl): $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
