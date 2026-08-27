#!/bin/bash
# `COLLATE <name>` WRITTEN INTO THE STATEMENT - the explicit collation.
#
# A column's collation is a property of the COLUMN; `COLLATE` in a query
# is a property of the OPERAND, and it wins. The same three laws hold as
# for a declared one (`qa/serve-real-icucoll.sh`): a SORT is full
# strength, an EQUALITY reads the named collation's own strength, and a
# FOLD reads it too. What is new here is that a statement can now ask a
# COLLATED column for the BYTE answer (`COLLATE UCS_BASIC`) and an
# UNCOLLATED one for a collation's, which is what the clause is for.
#
# Pinned below:
#
#   * ORDER BY over one - with ASC/DESC and NULLS, quoted or not, and
#     `UCS_BASIC` on a UNICODE_CI column, which sorts by bytes
#   * the comparison family, either side, and through a CASE
#   * MIN / MAX / COUNT(DISTINCT) - a FOLD reads the named collation
#   * a PROJECTED one: the value is UNCHANGED, and the engine renames
#     the column to `CAST` and describes it as its operand (measured)
#   * the three ERROR vectors, byte for byte: a name that is no
#     collation (-204, `"PUBLIC"."NOSUCH"`), a REAL collation of
#     ANOTHER character set (-204, and its schema is `"SYSTEM"` because
#     the name IS a built-in), and a COLLATE on a non-TEXT operand
#     (-204 "Data type unknown / Invalid use of CHARACTER SET or
#     COLLATE", SQLSTATE HY004)
#   * what still REFUSES: GROUP BY / DISTINCT under one - grouping keys
#     off the RECORD descriptors here and a synthetic expression slot
#     carries no ttype, so the buckets would be the bytes'; and a
#     collation this server has no table for
#
#   qa/serve-real-collclause.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4930}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-collclause-crab.fdb"
B="$D/fc-collclause-engine.fdb"
LOG="/tmp/fc-serve-collclause-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE C (ID INTEGER, S VARCHAR(20), CI VARCHAR(20) COLLATE UNICODE_CI,
                UC VARCHAR(20) COLLATE UNICODE);
COMMIT;
INSERT INTO C VALUES (1, 'apple',  'apple',  'apple');
INSERT INTO C VALUES (2, 'APPLE',  'APPLE',  'APPLE');
INSERT INTO C VALUES (3, 'Ápple',  'Ápple',  'Ápple');
INSERT INTO C VALUES (4, 'banana', 'banana', 'banana');
INSERT INTO C VALUES (5, 'ápple',  'ápple',  'ápple');
INSERT INTO C VALUES (6, NULL, NULL, NULL);
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
        *) echo "DIFF ANSWERED where an explicit COLLATE decides: $1"; echo "     [$r]"; fail=1 ;;
    esac
}

both "the rows landed the same on both sides" "SELECT ID, S, CI, UC FROM C ORDER BY ID;"

# ---- ORDER BY under a written collation ---------------------------------
both "ORDER BY <plain col> COLLATE UNICODE_CI" \
  "SELECT ID FROM C ORDER BY S COLLATE UNICODE_CI, ID;"
both "...and COLLATE UNICODE, which sorts the same" \
  "SELECT ID FROM C ORDER BY S COLLATE UNICODE, ID;"
both "COLLATE UCS_BASIC asks a COLLATED column for the BYTES" \
  "SELECT ID FROM C ORDER BY CI COLLATE UCS_BASIC, ID;"
both "the charset's OWN name does the same" \
  "SELECT ID FROM C ORDER BY UC COLLATE UTF8, ID;"
both "with DESC and NULLS" \
  "SELECT ID FROM C ORDER BY S COLLATE UNICODE_CI DESC NULLS LAST, ID;
   SELECT ID FROM C ORDER BY S COLLATE UNICODE_CI NULLS FIRST, ID;"
both "a QUOTED collation name" "SELECT ID FROM C ORDER BY S COLLATE \"UNICODE_CI\", ID;"
both "one key collated, the next not" \
  "SELECT ID FROM C ORDER BY S COLLATE UNICODE_CI, S, ID;"

# ---- the comparison family ----------------------------------------------
both "= under a written collation" \
  "SELECT ID FROM C WHERE S COLLATE UNICODE_CI = 'APPLE' ORDER BY ID;"
both "...on the OTHER side of the operator" \
  "SELECT ID FROM C WHERE 'APPLE' = S COLLATE UNICODE_CI ORDER BY ID;"
both "the accent-insensitive one takes more rows" \
  "SELECT ID FROM C WHERE S COLLATE UNICODE_CI_AI = 'APPLE' ORDER BY ID;"
both "a RANGE" "SELECT ID FROM C WHERE S COLLATE UNICODE < 'b' ORDER BY ID;"
both "UCS_BASIC on a COLLATED column is the byte comparison" \
  "SELECT ID FROM C WHERE CI COLLATE UCS_BASIC = 'APPLE' ORDER BY ID;"
both "inside a CASE" \
  "SELECT ID, CASE WHEN S COLLATE UNICODE_CI = 'APPLE' THEN 1 ELSE 0 END X
   FROM C ORDER BY ID;"

# ---- the FOLD reads it too ----------------------------------------------
both "MIN / MAX under a written collation" \
  "SELECT MIN(S COLLATE UNICODE_CI) A, MAX(S COLLATE UNICODE_CI) B FROM C;"
both "...and the tie keeps the row the fold met FIRST" \
  "SELECT MIN(S COLLATE UNICODE_CI_AI) A FROM C;
   SELECT MIN(V.S COLLATE UNICODE_CI_AI) A FROM (SELECT S FROM C ORDER BY ID DESC) V;"
both "COUNT(DISTINCT) counts the named collation's values" \
  "SELECT COUNT(DISTINCT S COLLATE UNICODE) U, COUNT(DISTINCT S COLLATE UNICODE_CI) C,
          COUNT(DISTINCT S COLLATE UNICODE_CI_AI) A FROM C;"
both "MIN over a COLLATED column, asked for bytes" \
  "SELECT MIN(CI COLLATE UCS_BASIC) A FROM C;"

# ---- a PROJECTED one decides nothing, and is renamed --------------------
both "the value is unchanged" "SELECT ID, S COLLATE UNICODE_CI FROM C ORDER BY ID;"
both "the column is named CAST, and describes as its operand" \
  "SET SQLDA_DISPLAY ON; SELECT S COLLATE UNICODE_CI FROM C WHERE ID = 1;"
both "an ALIAS still names it" \
  "SELECT S COLLATE UNICODE_CI AS X FROM C WHERE ID = 1;"
both "and an aggregate over one describes as MIN" \
  "SET SQLDA_DISPLAY ON; SELECT MIN(S COLLATE UNICODE_CI) FROM C;"

# ---- the error vectors, byte for byte -----------------------------------
both "a name that is no collation" "SELECT ID FROM C ORDER BY S COLLATE NOSUCHCOLL;"
both "a REAL collation of ANOTHER character set" \
  "SELECT ID FROM C ORDER BY S COLLATE PXW_INTL;"
both "...and the same in a WHERE" "SELECT ID FROM C WHERE S COLLATE NOSUCHCOLL = 'x';"
both "COLLATE on a non-TEXT operand" "SELECT ID FROM C ORDER BY ID COLLATE UNICODE;"

# ---- what still refuses -------------------------------------------------
refuses "GROUP BY under a written collation" \
  "SELECT S COLLATE UNICODE X, COUNT(*) N FROM C GROUP BY S COLLATE UNICODE;"
refuses "DISTINCT under one" "SELECT DISTINCT S COLLATE UNICODE FROM C;"

# ---- the engine still reads fire-crab's file ----------------------------
eng_q="SET LIST ON; SELECT ID, S, CI, UC FROM C ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
