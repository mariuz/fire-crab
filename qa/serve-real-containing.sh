#!/bin/bash
# `CONTAINING` - the literal substring test, and the one predicate that
# folds case on EVERY character set.
#
# Firebird's matcher says why: `ContainsMatcher<UCHAR, UpcaseConverter<>>`
# for a direct collation (Collation.cpp:1075) and
# `CanonicalConverter<UpcaseConverter<>>` for one with a canonical form
# (:527). So CONTAINING is UPPER-CASE FIRST - on every charset, whatever
# the column's collation - then the collation's canonical form, then a
# substring search. Its sibling STARTING WITH takes `NullStrConverter`
# for a direct collation (no conversion at all: case-SENSITIVE) and the
# canonical converter WITHOUT the upcase for the rest, which is the
# difference this gate exists to hold still.
#
# What is pinned:
#
#   * case folding on a plain column, and on each of the three ICU
#     collations - where only the accent-insensitive one folds accents
#   * THE PATTERN HAS NO WILDCARDS: `%` and `_` are literal characters,
#     and an EMPTY pattern matches every non-NULL row
#   * NULL on either side is UNKNOWN, negated or not
#   * an INTEGER operand renders to its decimal text, a CHAR operand's
#     padding is irrelevant (a substring test, not a comparison)
#   * NOT CONTAINING, and the keyword inside AND/OR/NOT()
#   * an expression operand, and an explicit `COLLATE` on one
#
#   qa/serve-real-containing.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4931}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-containing-crab.fdb"
B="$D/fc-containing-engine.fdb"
LOG="/tmp/fc-serve-containing-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE K (ID INTEGER, S VARCHAR(20), CI VARCHAR(20) COLLATE UNICODE_CI,
  AI VARCHAR(20) COLLATE UNICODE_CI_AI, UC VARCHAR(20) COLLATE UNICODE,
  CC CHAR(10), N INTEGER, W VARCHAR(20) CHARACTER SET WIN1252);
COMMIT;
INSERT INTO K VALUES (1,'apple','apple','apple','apple','apple',123,'apple');
INSERT INTO K VALUES (2,'APPLE','APPLE','APPLE','APPLE','APPLE',456,'APPLE');
INSERT INTO K VALUES (3,'Ápple','Ápple','Ápple','Ápple','Ápple',789,'Ápple');
INSERT INTO K VALUES (4,'banana','banana','banana','banana','banana',12,'banana');
INSERT INTO K VALUES (5,'a%b_c','a%b_c','a%b_c','a%b_c','a%b_c',1,'a%b_c');
INSERT INTO K VALUES (6,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
INSERT INTO K VALUES (7,'x\b','x\b','x\b','x\b','x\b',7,'x\b');
INSERT INTO K VALUES (8,'Straße','Straße','Straße','Straße','Straße',8,'Strasse');
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
both() {
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
        *) echo "DIFF ANSWERED where a refusal was recorded: $1"; echo "     [$r]"; fail=1 ;;
    esac
}

both "the rows landed the same on both sides" "SELECT ID, S, CI, AI, UC, CC, N, W FROM K ORDER BY ID;"

# ---- case folds on EVERY character set ----------------------------------
both "a plain column, either case of pattern" \
  "SELECT ID FROM K WHERE S CONTAINING 'ppl' ORDER BY ID;
   SELECT ID FROM K WHERE S CONTAINING 'PPL' ORDER BY ID;"
both "...and the accent still counts there" \
  "SELECT ID FROM K WHERE S CONTAINING 'Á' ORDER BY ID;
   SELECT ID FROM K WHERE S CONTAINING 'app' ORDER BY ID;"
both "UNICODE folds case, not the accent" \
  "SELECT ID FROM K WHERE UC CONTAINING 'app' ORDER BY ID;"
both "UNICODE_CI the same - the upcase already folded it" \
  "SELECT ID FROM K WHERE CI CONTAINING 'PPL' ORDER BY ID;"
both "UNICODE_CI_AI folds the accent too" \
  "SELECT ID FROM K WHERE AI CONTAINING 'app' ORDER BY ID;"
both "a WIN1252 column folds by ITS table" \
  "SELECT ID FROM K WHERE W CONTAINING 'PPL' ORDER BY ID;"
both "the SIMPLE uppercase again: ß is not SS" \
  "SELECT ID FROM K WHERE S CONTAINING 'STRASSE' ORDER BY ID;
   SELECT ID FROM K WHERE S CONTAINING 'straße' ORDER BY ID;
   SELECT ID FROM K WHERE W CONTAINING 'STRASSE' ORDER BY ID;"

# ---- the pattern has NO wildcards ---------------------------------------
both "a per-cent is a character" "SELECT ID FROM K WHERE S CONTAINING '%' ORDER BY ID;"
both "so is an underscore" "SELECT ID FROM K WHERE S CONTAINING '_' ORDER BY ID;"
both "...and both together, in order" \
  "SELECT ID FROM K WHERE S CONTAINING '%b_' ORDER BY ID;
   SELECT ID FROM K WHERE S CONTAINING '_b%' ORDER BY ID;"
both "a BACKSLASH is a character too" \
  "SELECT ID FROM K WHERE S CONTAINING '\\' ORDER BY ID;
   SELECT ID FROM K WHERE S CONTAINING 'x\\b' ORDER BY ID;"
both "the EMPTY pattern takes every non-NULL row" \
  "SELECT ID FROM K WHERE S CONTAINING '' ORDER BY ID;"
both "a pattern longer than the value takes nothing" \
  "SELECT ID FROM K WHERE S CONTAINING 'applesauce' ORDER BY ID;"

# ---- NULL, negation, and the shapes around it ---------------------------
both "a NULL pattern is UNKNOWN, negated or not" \
  "SELECT ID FROM K WHERE S CONTAINING NULL ORDER BY ID;
   SELECT ID FROM K WHERE S NOT CONTAINING NULL ORDER BY ID;"
both "a NULL VALUE is UNKNOWN too - row 6 is in neither answer" \
  "SELECT ID FROM K WHERE S CONTAINING 'a' ORDER BY ID;
   SELECT ID FROM K WHERE S NOT CONTAINING 'a' ORDER BY ID;"
both "NOT CONTAINING" \
  "SELECT ID FROM K WHERE S NOT CONTAINING 'PPL' ORDER BY ID;
   SELECT ID FROM K WHERE CI NOT CONTAINING 'ppl' ORDER BY ID;"
both "NOT (...) around it" "SELECT ID FROM K WHERE NOT (S CONTAINING 'PPL') ORDER BY ID;"
both "inside AND and OR" \
  "SELECT ID FROM K WHERE S CONTAINING 'ban' OR ID = 1 ORDER BY ID;
   SELECT ID FROM K WHERE S CONTAINING 'a' AND ID > 2 ORDER BY ID;"

# ---- the operand shapes -------------------------------------------------
both "an INTEGER renders to its decimal text" \
  "SELECT ID FROM K WHERE N CONTAINING '2' ORDER BY ID;
   SELECT ID FROM K WHERE N CONTAINING '89' ORDER BY ID;"
both "a CHAR operand's padding is irrelevant" \
  "SELECT ID FROM K WHERE CC CONTAINING 'PPLE' ORDER BY ID;"
both "an EXPRESSION operand" \
  "SELECT ID FROM K WHERE UPPER(S) CONTAINING 'PPL' ORDER BY ID;
   SELECT ID FROM K WHERE S || 'zz' CONTAINING 'EZZ' ORDER BY ID;"
both "an explicit COLLATE on the operand" \
  "SELECT ID FROM K WHERE S COLLATE UNICODE_CI_AI CONTAINING 'app' ORDER BY ID;
   SELECT ID FROM K WHERE AI COLLATE UCS_BASIC CONTAINING 'app' ORDER BY ID;"
# ---- EVERY PREDICATE IS ALSO A VALUE -----------------------------------
# In Firebird a predicate is a BOOLEAN expression, usable anywhere a
# value is. This server's condition grammar knew only LIKE, so the same
# test answered in a WHERE and refused in a CASE. All three now parse
# there, and each keeps the collation law it has as a predicate.
both "CONTAINING as a select-list boolean" \
  "SELECT ID, CASE WHEN S CONTAINING 'PPL' THEN 1 ELSE 0 END X FROM K ORDER BY ID;"
both "STARTING WITH as one" \
  "SELECT ID, CASE WHEN S STARTING WITH 'a' THEN 1 ELSE 0 END X FROM K ORDER BY ID;"
both "SIMILAR TO as one, with and without ESCAPE" \
  "SELECT ID, CASE WHEN S SIMILAR TO 'a%' THEN 1 ELSE 0 END X FROM K ORDER BY ID;
   SELECT ID, CASE WHEN S SIMILAR TO 'a#%b_c' ESCAPE '#' THEN 1 ELSE 0 END X FROM K ORDER BY ID;"
both "negated, as values" \
  "SELECT ID, CASE WHEN S NOT CONTAINING 'PPL' THEN 1 ELSE 0 END X FROM K ORDER BY ID;
   SELECT ID, CASE WHEN S NOT STARTING WITH 'a' THEN 1 ELSE 0 END X FROM K ORDER BY ID;"
both "a BARE boolean projection, no CASE around it" \
  "SELECT ID, (S STARTING WITH 'a') X, (S CONTAINING 'PPL') Y FROM K ORDER BY ID;"
both "...and each keeps its collation law as a value" \
  "SELECT ID, CASE WHEN CI CONTAINING 'PPL' THEN 1 ELSE 0 END X FROM K ORDER BY ID;
   SELECT ID, CASE WHEN AI STARTING WITH 'app' THEN 1 ELSE 0 END Y FROM K ORDER BY ID;
   SELECT ID, CASE WHEN UC STARTING WITH 'app' THEN 1 ELSE 0 END Z FROM K ORDER BY ID;"
both "in a WHERE over the value form" \
  "SELECT ID FROM K WHERE (S CONTAINING 'PPL') = TRUE ORDER BY ID;"
both "in a DML WHERE" \
  "UPDATE K SET N = 99 WHERE S CONTAINING 'BAN'; COMMIT;
   SELECT ID, N FROM K ORDER BY ID;"

# ---- the engine still reads fire-crab's file ----------------------------
eng_q="SET LIST ON; SELECT ID, S, CI, AI, UC, CC, N, W FROM K ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
