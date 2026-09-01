#!/bin/bash
# BLOB OPERANDS IN EXPRESSIONS - a blob column read as text by every
# predicate and text function, and the BLOB-VALUED result the engine
# hands back for one. Probed against the live engine and traced:
#
#   * a blob is a TEXT OPERAND: `B LIKE`, `B STARTING WITH`, `B = 'x'`,
#     `B > 'x'`, `B = <other blob>` all read the blob's CONTENT (the
#     engine filters it to a string and runs the ordinary text law)
#   * the LENGTHS answer a BIGINT over a blob where they answer an
#     INTEGER over a string: CHAR_LENGTH(B) and OCTET_LENGTH(B) both
#     describe INT64
#   * a BLOB OPERAND MAKES THE WHOLE EXPRESSION A BLOB - concatenation,
#     UPPER/LOWER/TRIM/SUBSTRING/LEFT/RIGHT/REPLACE/LPAD, and a
#     conditional with a blob branch - and the result's text type is the
#     operands' joined one, the FIRST real charset winning (`S || B` is
#     UTF8 from S, `W || B` WIN1252 from W, `B || W` UTF8 from B). One
#     BINARY blob operand (sub_type 0) makes the whole result binary,
#     and a binary blob result carries no charset at all
#   * ORDER BY / GROUP BY / DISTINCT over a blob key the BLOB ID, not
#     the content: four rows whose contents are 'zzz','aaa','zzz','mmm'
#     come out in ID order and group into FOUR groups (measured) - so
#     this server REFUSES them rather than answering by content
#
# Blob ids are normalised out of the comparison: a computed blob's id is
# each server's own (the engine numbers from 0:1 per statement, this one
# from its temp-blob counter), while the CONTENT is the answer.
#
# Boundaries (recorded, all refuse rather than answer): ORDER BY /
# GROUP BY / DISTINCT over a blob, MIN/MAX over one, a user sub_type
# (isc_nofilter), and a blob operand in arithmetic.
#
#   qa/serve-real-blobexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4915}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-blobexpr-crab.fdb"
B="$D/fc-blobexpr-engine.fdb"
LOG="/tmp/fc-serve-blobexpr-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
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
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
# -a: a high byte would make grep call the stream binary and print
# nothing; the blob id is each server's own and normalises out
norm() { grep -a -v '^$' | sed 's/[0-9a-f][0-9a-f]*:[0-9a-f][0-9a-f]*/BLOBID/g' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
bothd() {
    e=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a sqltype | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a sqltype | norm)
    check "$1" "$c" "$e"
}
mk() { cat <<'SQL'
CREATE TABLE T (ID INTEGER, S VARCHAR(20), B BLOB SUB_TYPE TEXT,
                W BLOB SUB_TYPE TEXT CHARACTER SET WIN1252, N BLOB SUB_TYPE 0);
COMMIT;
INSERT INTO T VALUES (1, 'abc', 'blob one', 'wtext', 'binbytes');
INSERT INTO T VALUES (2, 'xyz', 'second value', 'w2', 'more');
INSERT INTO T VALUES (3, 'nul', NULL, NULL, NULL);
COMMIT;
CREATE TABLE T3 (ID INTEGER, B BLOB SUB_TYPE TEXT);
COMMIT;
INSERT INTO T3 VALUES (1, 'zzz');
INSERT INTO T3 VALUES (2, 'aaa');
INSERT INTO T3 VALUES (3, 'zzz');
INSERT INTO T3 VALUES (4, 'mmm');
COMMIT;
SQL
}
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
both "the rows landed the same on both sides" \
  "SELECT ID, S, B, W, N FROM T ORDER BY ID;"

# ---- the blob as a TEXT OPERAND ----------------------------------------
both "the comparison family reads the blob's CONTENT" \
  "SELECT ID FROM T WHERE B = 'blob one'; SELECT ID FROM T WHERE B > 'blob'; SELECT ID FROM T WHERE B BETWEEN 'a' AND 'c'; SELECT ID FROM T WHERE B IN ('blob one', 'nothing');"
both "LIKE, STARTING WITH, SIMILAR TO and the negations" \
  "SELECT ID FROM T WHERE B LIKE '%value'; SELECT ID FROM T WHERE B STARTING WITH 'blob'; SELECT ID FROM T WHERE B NOT LIKE 'blob%' AND B IS NOT NULL; SELECT ID FROM T WHERE B SIMILAR TO 'blob.*';"
both "IS NULL over a blob, and a blob against another blob" \
  "SELECT ID FROM T WHERE B IS NULL; SELECT ID FROM T WHERE B IS NOT NULL; SELECT COUNT(*) FROM T3 A JOIN T3 C ON A.B = C.B;"
bothd "the lengths describe BIGINT over a blob" \
  "SELECT CHAR_LENGTH(B), OCTET_LENGTH(B), CHAR_LENGTH(S) FROM T;"
both "... and answer the blob's own counts" \
  "SELECT ID, CHAR_LENGTH(B), OCTET_LENGTH(B), OCTET_LENGTH(N) FROM T ORDER BY ID;"

# ---- the BLOB-VALUED result --------------------------------------------
bothd "a blob operand makes the result a blob, in the joined text type" \
  "SELECT B || '!', S || B, W || B, B || W, UPPER(B), TRIM(B), SUBSTRING(B FROM 1 FOR 4) FROM T;"
bothd "one BINARY operand makes the whole result binary" \
  "SELECT UPPER(N), N || 'x', COALESCE(N,'x'), COALESCE(B,N), B || N FROM T;"
both "the values the text functions answer over a blob" \
  "SELECT UPPER(B), LOWER(B), TRIM(B), SUBSTRING(B FROM 1 FOR 4), LEFT(B,4), RIGHT(B,3), REPLACE(B,'blob','BLOB') FROM T WHERE ID=1;"
both "concatenation, both ways round, and with a number" \
  "SELECT B || '!', 'x' || B, S || B, B || 1 FROM T WHERE ID=1;"
both "a conditional with a blob branch" \
  "SELECT COALESCE(B,'none'), CASE WHEN ID=1 THEN B ELSE 'other' END, IIF(ID=1, B, NULL) FROM T WHERE ID=1;"
both "... and the same over the NULL row" \
  "SELECT COALESCE(B,'none'), UPPER(B), B || 'x', CHAR_LENGTH(B) FROM T WHERE ID=3;"
both "a WIN1252 blob keeps its own bytes through a function" \
  "SELECT UPPER(W), OCTET_LENGTH(W), CAST(W AS VARCHAR(10)) FROM T WHERE ID=1;"

both "a blob operand through a JOIN's ON and a CASE condition" \
  "SELECT A.ID FROM T A JOIN T C ON A.B = C.B ORDER BY 1; SELECT ID, CASE WHEN B LIKE 'blob%' THEN 'y' ELSE 'n' END FROM T ORDER BY ID;"
both "LIKE with an ESCAPE, POSITION and the TRIM forms over a blob" \
  "SELECT ID FROM T WHERE B LIKE '%o!_e' ESCAPE '!'; SELECT POSITION('one' IN B) FROM T WHERE ID=1; SELECT TRIM(LEADING 'b' FROM B), TRIM(TRAILING 'e' FROM B) FROM T WHERE ID=1;"
both "the text of a blob through CAST stays text" \
  "SELECT CAST(B AS VARCHAR(20)), CHAR_LENGTH(CAST(B AS VARCHAR(20))) FROM T WHERE ID=1;"
both "a blob-valued expression through a UNION" \
  "SELECT UPPER(B) FROM T WHERE ID=1 UNION ALL SELECT LOWER(B) FROM T WHERE ID=1;"

# ---- the ID is the key, not the content --------------------------------
# T3 holds 'zzz','aaa','zzz','mmm' at ids 1..4, so CONTENT order and BLOB
# ID order disagree: the engine answers ID order and groups four rows into
# FOUR groups, and a server that keyed the content would answer 2,4,1,3
# and three groups. Both servers must give the same answer here.
both "ORDER BY / GROUP BY / DISTINCT over a blob key the ID, not the content" \
  "SELECT ID FROM T3 ORDER BY B; SELECT ID FROM T3 ORDER BY B DESC; SELECT COUNT(*) FROM T3 GROUP BY B; SELECT DISTINCT B FROM T3;"

# ---- the ENGINE reads what fire-crab's blob expressions answer ----------
eng_q="SET LIST ON; SELECT ID, CHAR_LENGTH(B) AS CL, CAST(UPPER(B) AS VARCHAR(20)) AS U FROM T ORDER BY ID; SELECT ID, CAST(B AS VARCHAR(30)) AS V, CHAR_LENGTH(B) AS L FROM E ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- blob VALUES in DML ------------------------------------------------
both "UPDATE SET a blob from an expression, another blob, a string column" \
  "CREATE TABLE D (ID INTEGER, B BLOB SUB_TYPE TEXT, C BLOB SUB_TYPE TEXT, S VARCHAR(20)); COMMIT; INSERT INTO D VALUES (1, 'one', NULL, 'sss'); INSERT INTO D VALUES (2, 'two', NULL, 'ttt'); COMMIT; UPDATE D SET B = B || ' more' WHERE ID=1; UPDATE D SET C = B WHERE ID=1; UPDATE D SET C = S WHERE ID=2; COMMIT; SELECT ID, CAST(B AS VARCHAR(30)), CAST(C AS VARCHAR(30)) FROM D ORDER BY ID;"
both "... and back to NULL, and from a function" \
  "UPDATE D SET C = NULL WHERE ID=1; UPDATE D SET B = UPPER(S) WHERE ID=2; COMMIT; SELECT ID, CAST(B AS VARCHAR(30)), C FROM D ORDER BY ID;"
both "INSERT ... SELECT copies a blob column and stores a computed one" \
  "CREATE TABLE E (ID INTEGER, B BLOB SUB_TYPE TEXT); COMMIT; INSERT INTO E SELECT ID, B FROM D; INSERT INTO E SELECT ID + 10, UPPER(B) || '!' FROM D; INSERT INTO E SELECT 30, S FROM D WHERE ID=1; COMMIT; SELECT ID, CAST(B AS VARCHAR(30)) FROM E ORDER BY ID;"
both "INSERT ... VALUES stores every scalar the engine renders into a blob" \
  "INSERT INTO E VALUES (40, UPPER('made') || '-up'); INSERT INTO E VALUES (41, 42); INSERT INTO E VALUES (42, 3.14); INSERT INTO E VALUES (43, DATE'2020-06-15'); INSERT INTO E VALUES (44, TIMESTAMP'2020-06-15 10:20:30'); INSERT INTO E VALUES (45, TRUE); COMMIT; SELECT ID, CAST(B AS VARCHAR(30)) FROM E WHERE ID >= 40 ORDER BY ID;"

# ---- CAST ... AS BLOB ---------------------------------------------------
bothd "the cast target names the blob's own type" \
  "SELECT CAST('x' AS BLOB), CAST('x' AS BLOB SUB_TYPE TEXT), CAST('x' AS BLOB SUB_TYPE 1), CAST('x' AS BLOB SUB_TYPE BINARY), CAST('x' AS BLOB SUB_TYPE TEXT CHARACTER SET WIN1252), CAST('x' AS BLOB CHARACTER SET UTF8), CAST('x' AS BLOB SUB_TYPE TEXT SEGMENT SIZE 100) FROM RDB\$DATABASE;"
both "... and its value, in a select list and as a stored value" \
  "SELECT CAST('abc' AS BLOB SUB_TYPE TEXT), CAST(42 AS BLOB SUB_TYPE TEXT), CAST(CAST(B AS BLOB SUB_TYPE TEXT) AS VARCHAR(30)) FROM D WHERE ID=1; INSERT INTO E VALUES (50, CAST('casted' AS BLOB SUB_TYPE TEXT)); COMMIT; SELECT CAST(B AS VARCHAR(30)) FROM E WHERE ID=50;"

# ---- boundaries ---------------------------------------------------------
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    case "$r" in
        *"Statement failed"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     fc: $r"; fail=1 ;;
    esac
}
refuses "MIN over a blob refuses" \
  "SELECT MIN(B) FROM T3;"
refuses "a blob in arithmetic refuses" \
  "SELECT B + 1 FROM T WHERE ID=1;"
refuses "a blob-valued SCALAR SUBQUERY refuses" \
  "SELECT ID FROM T WHERE B = (SELECT B FROM T WHERE ID=1);"
refuses "a blob-valued expression inside a DERIVED TABLE refuses" \
  "SELECT X FROM (SELECT B || '!' AS X FROM T WHERE ID=1);"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
# --- a blob LENGTH is a BIGINT, however the blob is spelled -------------
# CHAR_LENGTH/OCTET_LENGTH over a blob describe INT64 len 8, not the
# INTEGER len 4 a VARCHAR gets. That rule was gated on the argument being
# a BARE blob column, so every blob EXPRESSION narrowed to LONG len 4 -
# the risky direction, since a client whose buffers were laid out from the
# engine's describe reads the wrong width. The VALUES agreed throughout,
# so only a describe comparison catches it.
bothd "OCTET_LENGTH over a bare blob column" \
    "SELECT OCTET_LENGTH(B) FROM T WHERE ID = 1;"
bothd "OCTET_LENGTH over a blob CONCATENATION" \
    "SELECT OCTET_LENGTH(B || 'x') FROM T WHERE ID = 1;"
bothd "CHAR_LENGTH over a blob concatenation" \
    "SELECT CHAR_LENGTH(B || 'x') FROM T WHERE ID = 1;"
bothd "OCTET_LENGTH over COALESCE of a blob" \
    "SELECT OCTET_LENGTH(COALESCE(B, 'zz')) FROM T WHERE ID = 1;"
bothd "OCTET_LENGTH over a CASE yielding a blob" \
    "SELECT OCTET_LENGTH(CASE WHEN 1=1 THEN B ELSE NULL END) FROM T WHERE ID = 1;"
bothd "control: the same lengths over VARCHAR stay INTEGER" \
    "SELECT OCTET_LENGTH(S), CHAR_LENGTH(S), OCTET_LENGTH(S || 'x') FROM T WHERE ID = 1;"
both "and the length VALUES agree" \
    "SELECT OCTET_LENGTH(B), OCTET_LENGTH(B || 'x'), CHAR_LENGTH(B || 'x') FROM T WHERE ID = 1;"

# --- MIN/MAX over a blob compares CONTENT, or refuses -------------------
# The fold compares Value::Blob(relation, recno) - a blob ID, not its
# content - so MAX answered the LAST-inserted blob and MIN the first,
# whatever they held: over 'zzz','mmm','aaa' the engine answers zzz/aaa
# and this answered aaa/zzz, EXACTLY INVERTED, with no error. Comparing
# content needs the blob READ during the fold, and compute_group has no
# database (ten call sites, most of them window folds), so this refuses
# until the fold can resolve a blob. A refusal beats a silently wrong row.
ran=$((ran + 1))
mm=$(printf 'SET LIST ON;\nSELECT CAST(MAX(B) AS VARCHAR(20)) M FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
me=$(printf 'SET LIST ON;\nSELECT CAST(MAX(B) AS VARCHAR(20)) M FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1)
if printf '%s' "$me" | grep -q 'SQLSTATE'; then
    echo "DIFF the ENGINE refused MAX over a blob - this check assumes it answers"
    fail=1
elif printf '%s' "$mm" | grep -q 'SQLSTATE'; then
    echo "OK   MAX over a blob refuses cleanly (recorded boundary)"
else
    echo "DIFF MAX over a blob ANSWERED [$mm] - it must compare CONTENT or refuse,"
    echo "     never fold on the blob ID. If this now answers, check it against the"
    echo "     engine and turn it into a value comparison."
    fail=1
fi
both "control: MIN/MAX over the VARCHAR twin still answer" \
    "SELECT MAX(S) MS, MIN(S) NS FROM T;"
both "control: COUNT over a blob column still answers" \
    "SELECT COUNT(B) FROM T;"

ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
