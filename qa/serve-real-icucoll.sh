#!/bin/bash
# AN ICU COLLATION DECIDES THE ANSWER - AND THIS SERVER NOW HAS THE TABLE.
#
# Firebird's `UNICODE`, `UNICODE_CI` and `UNICODE_CI_AI` are ICU-backed
# collations over the root locale: their order is the Unicode Collation
# Algorithm's, where `'apple' < 'Ápple' < 'banana'` and (under CI)
# `'apple' = 'APPLE'`. The bytes say something else in both cases, so
# this server used to REFUSE every shape one of them decided. It now
# answers them from the UCA itself - `icu_collator`, the one dependency
# in the workspace - and this gate is what that is worth.
#
# TWO LAWS, probed off the live engine (2026-08-27) and pinned below:
#
#   1. A SORT IS FULL STRENGTH whatever the column's own collation is.
#      `ORDER BY <UNICODE>`, `ORDER BY <UNICODE_CI>` and
#      `ORDER BY <UNICODE_CI_AI>` all answer the same order over
#      apple/APPLE/Ápple/ápple. A CI collation makes an EQUALITY loose,
#      it does not make a SORT unstable.
#   2. EQUALITY AND GROUPING READ THE COLLATION'S OWN STRENGTH.
#      `= 'APPLE'` takes one row under UNICODE, two under UNICODE_CI,
#      four under UNICODE_CI_AI.
#
# ...and what is STILL refused, each for a measured reason:
#
#   * `LIKE` / `STARTING WITH` / `CONTAINING` / `SIMILAR TO` match
#     through the collation's own MATCHER, prefix by prefix, and a UCA
#     sort key is not built prefix-wise (its levels are concatenated, so
#     the key of 'app' is no prefix of the key of 'apple').
#   * `GROUP BY` / `DISTINCT` must also answer WHICH SPELLING survives a
#     merged group, and the engine's pick is its own unstable sort's:
#     measured, `SELECT DISTINCT CI` kept 'apple' out of {apple, APPLE}
#     but 'ápple' out of {Ápple, ápple}, while `GROUP BY CI` kept
#     'APPLE' out of the FIRST of those two. Three different rules is no
#     rule, so this server does not guess one.
#   * `MIN` / `MAX` / `COUNT(DISTINCT)` fold plain values with no
#     collation in reach - and that refusal covers PXW_INTL too.
#   * an EXPRESSION over such a column in a comparison (`UPPER(ci) =`),
#     which carries the collation into a result there is no key for.
#   * a JOIN keyed on one, and two DIFFERENT collations meeting in one
#     comparison.
#   * a narrow charset's ICU collation, and a language-tailored one
#     (`DE_DE`): only the three ROOT collations over UTF8 are claimed.
#
# The fixture is built by the ENGINE (this server does not create
# `COLLATE UNICODE_CI` columns) and both servers then work over their
# own copy of it.
#
#   qa/serve-real-icucoll.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4929}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-icucoll-crab.fdb"
B="$D/fc-icucoll-engine.fdb"
LOG="/tmp/fc-serve-icucoll-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T (ID INTEGER,
  S  VARCHAR(20),
  CI VARCHAR(20) COLLATE UNICODE_CI,
  AI VARCHAR(20) COLLATE UNICODE_CI_AI,
  UC VARCHAR(20) COLLATE UNICODE,
  CC CHAR(10) COLLATE UNICODE_CI,
  W  VARCHAR(20) CHARACTER SET WIN1252 COLLATE PXW_INTL);
COMMIT;
INSERT INTO T VALUES (1, 'apple',  'apple',  'apple',  'apple',  'apple',  'apple');
INSERT INTO T VALUES (2, 'Banana', 'Banana', 'Banana', 'Banana', 'Banana', 'Banana');
INSERT INTO T VALUES (3, 'cherry', 'cherry', 'cherry', 'cherry', 'cherry', 'cherry');
INSERT INTO T VALUES (4, 'Ápple',  'Ápple',  'Ápple',  'Ápple',  'Ápple',  'Ápple');
INSERT INTO T VALUES (5, 'APPLE',  'APPLE',  'APPLE',  'APPLE',  'APPLE',  'APPLE');
INSERT INTO T VALUES (6, 'banana', 'banana', 'banana', 'banana', 'banana', 'banana');
INSERT INTO T VALUES (7, 'ápple',  'ápple',  'ápple',  'ápple',  'ápple',  'ápple');
INSERT INTO T VALUES (8, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO T VALUES (9, 'ä', 'ä', 'ä', 'ä', 'ä', 'ä');
INSERT INTO T VALUES (10, 'ae', 'ae', 'ae', 'ae', 'ae', 'ae');
INSERT INTO T VALUES (11, 'Cherry', 'Cherry', 'Cherry', 'Cherry', 'Cherry', 'Cherry');
COMMIT;
SET TERM ^;
CREATE PROCEDURE PCOUNT RETURNS (N INTEGER) AS
BEGIN
  SELECT COUNT(*) FROM T WHERE CI = 'APPLE' INTO :N;
  SUSPEND;
END^
CREATE PROCEDURE PFIRST RETURNS (I INTEGER) AS
BEGIN
  FOR SELECT ID FROM T WHERE CI IS NOT NULL ORDER BY CI, ID INTO :I DO
  BEGIN
    SUSPEND;
  END
END^
SET TERM ;^
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
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() { # <label> <sql> - the two servers must agree
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
refuses() { # <label> <sql> - fc must refuse, and the ENGINE must answer
    ran=$((ran + 1))
    r=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1)
    case "$r:$e" in
        *"Dynamic SQL Error"*) case "$e" in
            *"Dynamic SQL Error"*) echo "DIFF the ENGINE refuses it too - the shape proves nothing: $1"; fail=1 ;;
            *) echo "OK   refuses (the engine answers): $1" ;;
        esac ;;
        *) echo "DIFF ANSWERED where an ICU collation decides: $1"; echo "     [$r]"; fail=1 ;;
    esac
}

# ---- the fixture landed the same way on both sides ----------------------
both "the rows landed the same on both sides" \
  "SELECT ID, S, CI, AI, UC, CC, W FROM T ORDER BY ID;"

# ---- LAW 1: A SORT IS FULL STRENGTH ------------------------------------
# the three collations differ ONLY in what they call equal; all three
# order apple/APPLE/ápple/Ápple the same way, and it is not byte order
both "ORDER BY a UNICODE column" "SELECT ID FROM T ORDER BY UC, ID;"
both "ORDER BY a UNICODE_CI column - the SAME order" "SELECT ID FROM T ORDER BY CI, ID;"
both "ORDER BY a UNICODE_CI_AI column - the same again" "SELECT ID FROM T ORDER BY AI, ID;"
both "the three collated orders, side by side" \
  "SELECT ID FROM T WHERE UC IS NOT NULL ORDER BY UC, ID;
   SELECT ID FROM T WHERE CI IS NOT NULL ORDER BY CI, ID;
   SELECT ID FROM T WHERE AI IS NOT NULL ORDER BY AI, ID;"
# ...and LAW 1 itself: the three orders are the SAME order. Asserted on
# each server on its own, so it holds even if both were wrong together
law1() { # <server label> <connstring>
    o1=$(printf 'SET LIST ON;\nSELECT ID FROM T WHERE UC IS NOT NULL ORDER BY UC, ID;\n' | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$2" 2>&1 | norm)
    o2=$(printf 'SET LIST ON;\nSELECT ID FROM T WHERE CI IS NOT NULL ORDER BY CI, ID;\n' | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$2" 2>&1 | norm)
    o3=$(printf 'SET LIST ON;\nSELECT ID FROM T WHERE AI IS NOT NULL ORDER BY AI, ID;\n' | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$2" 2>&1 | norm)
    ran=$((ran + 1))
    if [ -n "$o1" ] && [ "$o1" = "$o2" ] && [ "$o2" = "$o3" ]; then
        echo "OK   a sort is FULL STRENGTH whatever the collation is ($1)"
    else
        echo "DIFF the three collated orders differ ($1): [$o1] [$o2] [$o3]"; fail=1
    fi
}
law1 "the engine" "127.0.0.1/$REAL:$B"
law1 "fire-crab"  "127.0.0.1/$PORT:$A"
both "DESC reverses it" "SELECT ID FROM T ORDER BY CI DESC, ID;"
both "NULLS FIRST and NULLS LAST" \
  "SELECT ID FROM T ORDER BY CI NULLS FIRST, ID; SELECT ID FROM T ORDER BY CI NULLS LAST, ID;"
both "ORDER BY an ORDINAL naming it" "SELECT ID, CI FROM T ORDER BY 2, 1;"
both "ORDER BY an EXPRESSION over one" "SELECT ID FROM T ORDER BY CI || 'x', ID;"
both "a CHAR column under the collation" "SELECT ID FROM T ORDER BY CC, ID;"
both "ORDER BY it inside a DERIVED TABLE" \
  "SELECT V.ID FROM (SELECT FIRST 4 ID, CI FROM T WHERE CI IS NOT NULL ORDER BY CI, ID) V;"
both "FIRST / SKIP over the collated order" \
  "SELECT FIRST 3 SKIP 1 ID FROM T WHERE CI IS NOT NULL ORDER BY CI, ID;"
both "the collated order under a JOIN" \
  "SELECT a.ID, b.ID FROM T a JOIN T b ON a.ID = b.ID WHERE a.CI IS NOT NULL ORDER BY a.CI, a.ID;"

# ---- LAW 2: EQUALITY READS THE COLLATION'S OWN STRENGTH ----------------
both "UNICODE equality is exact" "SELECT ID FROM T WHERE UC = 'APPLE' ORDER BY ID;"
both "UNICODE_CI folds CASE, not the accent" "SELECT ID FROM T WHERE CI = 'APPLE' ORDER BY ID;"
both "UNICODE_CI_AI folds both" "SELECT ID FROM T WHERE AI = 'APPLE' ORDER BY ID;"
both "...and the accented spelling as the probe" \
  "SELECT ID FROM T WHERE UC = 'ápple' ORDER BY ID;
   SELECT ID FROM T WHERE CI = 'ápple' ORDER BY ID;
   SELECT ID FROM T WHERE AI = 'ápple' ORDER BY ID;"
both "inequality is its complement" "SELECT ID FROM T WHERE CI <> 'APPLE' ORDER BY ID;"
both "the ranges" \
  "SELECT ID FROM T WHERE CI < 'b' ORDER BY ID;
   SELECT ID FROM T WHERE CI <= 'BANANA' ORDER BY ID;
   SELECT ID FROM T WHERE CI > 'b' ORDER BY ID;
   SELECT ID FROM T WHERE CI >= 'BANANA' ORDER BY ID;"
both "BETWEEN" "SELECT ID FROM T WHERE UC BETWEEN 'a' AND 'c' ORDER BY ID;"
both "an IN list, and NOT IN" \
  "SELECT ID FROM T WHERE CI IN ('APPLE', 'CHERRY') ORDER BY ID;
   SELECT ID FROM T WHERE CI NOT IN ('APPLE') ORDER BY ID;"
both "IS NULL and IS NOT NULL" \
  "SELECT ID FROM T WHERE CI IS NULL; SELECT COUNT(*) FROM T WHERE CI IS NOT NULL;"
both "TRAILING BLANKS are the pad, not the value" \
  "SELECT ID FROM T WHERE CI = 'apple   ' ORDER BY ID;
   SELECT ID FROM T WHERE CC = 'apple' ORDER BY ID;"
both "a LEADING blank is part of it" "SELECT ID FROM T WHERE CI = ' apple' ORDER BY ID;"
both "the comparison inside a CASE" \
  "SELECT ID, CASE WHEN CI = 'APPLE' THEN 1 ELSE 0 END X FROM T ORDER BY ID;"
both "the comparison under a DERIVED TABLE's own name" \
  "SELECT ID FROM (SELECT ID, CI FROM T) V WHERE V.CI = 'APPLE' ORDER BY ID;"
both "COUNT over the collated filter" "SELECT COUNT(*) N FROM T WHERE AI = 'apple';"

# ---- the SEMI-JOIN rewrites take the collation too ----------------------
# a rewritten `IN (SELECT ...)` carries its values as HASH KEYS, a
# spelling the strict grammar reads - and that arm compared BYTES, so
# this answered ONE row where the literal `IN ('APPLE')` beside it
# answered two
both "IN (subquery)" \
  "SELECT ID FROM T WHERE CI IN (SELECT CI FROM T WHERE ID = 5) ORDER BY ID;"
both "= ANY (subquery)" \
  "SELECT ID FROM T WHERE CI = ANY (SELECT CI FROM T WHERE ID = 5) ORDER BY ID;"
both "a correlated EXISTS" \
  "SELECT ID FROM T a WHERE EXISTS (SELECT 1 FROM T b WHERE b.CI = a.CI AND b.ID = 5) ORDER BY ID;"
both "a correlated NOT EXISTS" \
  "SELECT ID FROM T a WHERE NOT EXISTS (SELECT 1 FROM T b WHERE b.CI = a.CI AND b.ID = 5) ORDER BY ID;"
both "NOT IN (subquery)" \
  "SELECT ID FROM T WHERE CI NOT IN (SELECT CI FROM T WHERE ID = 5) ORDER BY ID;"
both "a scalar subquery on the other side" \
  "SELECT ID FROM T WHERE CI = (SELECT CI FROM T WHERE ID = 5) ORDER BY ID;"

# ---- DML decides by the collation as well -------------------------------
both "UPDATE ... WHERE <collated>" \
  "UPDATE T SET S = 'hit' WHERE CI = 'APPLE'; COMMIT; SELECT ID, S FROM T ORDER BY ID;"
both "DELETE ... WHERE <collated>" \
  "DELETE FROM T WHERE AI = 'CHERRY'; COMMIT; SELECT COUNT(*) N FROM T;"
both "...and the file reads back the same" "SELECT ID, S, CI, AI, UC FROM T ORDER BY ID;"

# ---- a PSQL body decides by the collation too ---------------------------
# the BLR executor compares text with no descriptor in reach, so a
# collation could decide NOTHING there: this procedure answered ONE
# where the engine answers two, while the same statement typed at the
# prompt answered two. The fast path now stands aside for a relation
# with a collated column and the source interpreter re-plans it
both "a comparison inside a PROCEDURE body" "SELECT N FROM PCOUNT;"
both "a collated ORDER BY inside a PROCEDURE body" "SELECT I FROM PFIRST;"

# ---- THE FOLD KEYS ITS COLLATION TOO ------------------------------------
# MIN/MAX pick by the collation's ORDER and COUNT(DISTINCT) buckets by
# its EQUALITY - both at the collation's OWN strength, which is what a
# FOLD reads: measured, `MIN(<UNICODE_CI col>)` over {APPLE, apple}
# answered whichever row came FIRST, both ways round, so the two are
# EQUAL to the fold and keep-unless-strictly-less decides. (A SORT would
# have answered 'apple' either way - the two halves of the same key.)
both "MIN / MAX under UNICODE" "SELECT MIN(UC) A, MAX(UC) B FROM T;"
both "MIN / MAX under UNICODE_CI" "SELECT MIN(CI) A, MAX(CI) B FROM T;"
both "MIN / MAX under UNICODE_CI_AI" "SELECT MIN(AI) A, MAX(AI) B FROM T;"
both "MIN / MAX under PXW_INTL - the fold keys that too" \
  "SELECT MIN(W) A, MAX(W) B FROM T;"
both "COUNT(DISTINCT) counts the collation's values" \
  "SELECT COUNT(DISTINCT UC) U, COUNT(DISTINCT CI) C,
          COUNT(DISTINCT AI) A, COUNT(DISTINCT W) W FROM T;"
# ...and the SAME rule at the MAX end, where {cherry, Cherry} tie under
# CI: the fold keeps the row it met FIRST, both ways round (measured)
both "the MIN and the MAX of a TIED class" \
  "SELECT MIN(CI) A, MAX(CI) B FROM T;
   SELECT MIN(V.CI) A, MAX(V.CI) B FROM (SELECT CI FROM T ORDER BY ID DESC) V;"
both "MIN / MAX per GROUP, keyed" \
  "SELECT MIN(CI) A, COUNT(*) N FROM T GROUP BY ID > 5 ORDER BY 2;"

# ---- GROUP BY and DISTINCT under a FULL-STRENGTH collation --------------
# a collation that calls two DIFFERENT strings equal cannot say which
# SPELLING survives a merged group (below); one that does not merge
# spellings asks no such question, so `UNICODE` and `PXW_INTL` group and
# deduplicate - AND THE GROUPS COME BACK IN THE COLLATION'S ORDER, which
# is what the engine answers ('ae', 'ä', 'apple', 'APPLE', ... under
# PXW_INTL, where the bytes would have said something else)
both "GROUP BY a UNICODE column" "SELECT UC, COUNT(*) N FROM T GROUP BY UC;"
both "DISTINCT a UNICODE column" "SELECT DISTINCT UC FROM T;"
both "GROUP BY a PXW_INTL column - in ITS order" \
  "SELECT W, COUNT(*) N FROM T GROUP BY W;"
both "DISTINCT a PXW_INTL column" "SELECT DISTINCT W FROM T;"
both "a distinct UNION over a UNICODE column" \
  "SELECT UC FROM T UNION SELECT UC FROM T;"
both "GROUP BY it with an explicit ORDER BY" \
  "SELECT UC, COUNT(*) N FROM T GROUP BY UC ORDER BY 1;
   SELECT W, COUNT(*) N FROM T GROUP BY W ORDER BY 1 DESC;"
both "a grouped JOIN keyed on a collated column" \
  "SELECT a.UC, COUNT(*) N FROM T a JOIN T b ON a.ID = b.ID GROUP BY a.UC;"
both "GROUP BY it in a DERIVED table" \
  "SELECT V.UC, V.N FROM (SELECT UC, COUNT(*) N FROM T GROUP BY UC) V;"

# ---- what the collation does NOT decide: unchanged ----------------------
both "a charset's DEFAULT collation is byte order (UCS_BASIC)" \
  "SELECT ID FROM T ORDER BY S, ID; SELECT ID FROM T WHERE S = 'APPLE';
   SELECT S FROM T GROUP BY S ORDER BY 1;"
both "PXW_INTL orders, compares and groups by its own keys" \
  "SELECT ID FROM T ORDER BY W, ID; SELECT ID FROM T WHERE W = 'apple' ORDER BY ID;
   SELECT COUNT(*) FROM T GROUP BY W ORDER BY 1;"
both "MIN and MAX over the DEFAULT collation" "SELECT MIN(S), MAX(S) FROM T;"
both "the LENGTHS and the CASTS of an ICU-collated value" \
  "SELECT CHAR_LENGTH(CI), OCTET_LENGTH(CI), CAST(CI AS VARCHAR(30)) FROM T WHERE ID = 4;"
both "UPPER / LOWER of one, PROJECTED" \
  "SELECT ID, UPPER(CI), LOWER(CI) FROM T WHERE ID IN (1, 4) ORDER BY ID;"

# ---- what is STILL refused, each for its own measured reason ------------
refuses "LIKE - the matcher, not the key" "SELECT ID FROM T WHERE CI LIKE 'A%' ORDER BY ID;"
refuses "STARTING WITH - a UCA key has no prefix" \
  "SELECT ID FROM T WHERE CI STARTING WITH 'A' ORDER BY ID;"
refuses "CONTAINING" "SELECT ID FROM T WHERE CI CONTAINING 'PPL' ORDER BY ID;"
refuses "SIMILAR TO" "SELECT ID FROM T WHERE CI SIMILAR TO 'A.*' ORDER BY ID;"
refuses "GROUP BY under CI - the surviving SPELLING is unpinnable" \
  "SELECT CI, COUNT(*) FROM T GROUP BY CI;"
refuses "...and under CI_AI" "SELECT AI, COUNT(*) FROM T GROUP BY AI;"
refuses "DISTINCT under CI - the same question" "SELECT DISTINCT CI FROM T;"
refuses "a distinct UNION over one" "SELECT CI FROM T UNION SELECT CI FROM T;"
refuses "MIN over an EXPRESSION reading a collated column" \
  "SELECT MIN(UPPER(CI)) FROM T;"
refuses "a JOIN keyed on it" "SELECT a.ID, b.ID FROM T a JOIN T b ON a.CI = b.CI;"
refuses "an EXPRESSION over one in a COMPARISON" \
  "SELECT ID FROM T WHERE UPPER(CI) = 'APPLE' ORDER BY ID;"
refuses "two DIFFERENT collations meeting in one comparison" \
  "SELECT ID FROM T WHERE CI = UC ORDER BY ID;"
refuses "an explicit COLLATE clause" "SELECT ID FROM T ORDER BY S COLLATE UNICODE_CI;"

# ---- the engine still reads fire-crab's file ----------------------------
eng_q="SET LIST ON; SELECT ID, S, CI, AI, UC, CC, W FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
