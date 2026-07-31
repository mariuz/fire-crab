#!/bin/bash
# UPDATE ... SET <col> = <EXPRESSION>.
#
# Until now this server's UPDATE took only a literal or a `?` on the
# right of SET, so `UPDATE T SET N = N + 5` was refused outright - which
# also made every PSQL body that bumped a column refuse (Inc151). A SET
# expression cannot be bound once before the scan the way a literal is:
# it reads the row it is replacing, so it is evaluated PER ROW against
# that row's own values, with the same expression machinery a select list
# uses.
#
# THE DIFFERENTIAL: the same UPDATE runs against a copy of one database
# through fire-crab and through the engine, and the ENGINE then reads
# both files back - the tables must be identical. gfix -v -full and gbak
# must also accept what fire-crab wrote, since a SET expression rewrites
# records in place and maintains indexes.
#
# The teeth are the cases a naive implementation gets wrong:
#
#   SET A = B, B = A     SQL assigns SIMULTANEOUSLY - both sides read the
#                        OLD row, so this SWAPS. Applying assignments in
#                        sequence would leave both columns equal.
#   SET A = A + 5        must read the A it replaces, not a bound value
#   NULL operands        propagate: a NULL column stays NULL
#   SET A = A / 0        must raise, not write a wrong value
#
#   qa/serve-real-setexpr.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4378}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-setexpr.fdb"
W=/tmp/fc-setexpr-w.fdb
R=/tmp/fc-setexpr-r.fdb

mkdir -p "$D"; rm -f "$SRC" "$W" "$R"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (
  ID INTEGER NOT NULL PRIMARY KEY,
  A INTEGER,
  B INTEGER,
  N NUMERIC(9,2),
  K BIGINT,
  -- a BOOLEAN and a DATE: the families the SET path could not STORE,
  -- however well it computed them
  FLAG BOOLEAN,
  D DATE
);
CREATE INDEX T_A ON T (A);
COMMIT;
INSERT INTO T VALUES (1, 10, 3, 12.50, 4000000000, TRUE, '2020-01-01');
INSERT INTO T VALUES (2, 20, 4, 1.25, 5, FALSE, '2021-06-15');
INSERT INTO T VALUES (3, NULL, 5, NULL, NULL, NULL, NULL);
INSERT INTO T VALUES (4, -8, 2, 13.50, 7, TRUE, '2022-12-31');
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-setexpr.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$W" "$R" /tmp/fc-setexpr.fbk' EXIT
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

fail=0
dump() {
    printf 'SET HEADING OFF;\nSELECT ID, COALESCE(A,-9), COALESCE(B,-9), COALESCE(N,-9), COALESCE(K,-9) FROM T ORDER BY ID;\n' |
        "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
# run one UPDATE both ways on a fresh copy; the ENGINE reads both back
same() { # <label> <sql>
    rm -f "$W" "$R"; cp "$SRC" "$W"; cp "$SRC" "$R"
    printf '%s;\nCOMMIT;\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/tmp/fc-setexpr-fc.log 2>&1
    printf '%s;\nCOMMIT;\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$R" >/tmp/fc-setexpr-en.log 2>&1
    ours=$(dump "$W"); theirs=$(dump "$R")
    if [ "$ours" = "$theirs" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$theirs]"; echo "     fc:     [$ours]"; fail=1
    fi
}

# --- values the SET path could COMPUTE but not STORE --------------------
# The expression machinery had learned booleans and the temporal types;
# the code that writes the result back had a list of value shapes that
# predated them, and answered "expression type cannot be stored". A
# condition IS a value in Firebird, so this is the ordinary way to fill
# a boolean column from one.
same "SET boolean = a condition"      "UPDATE T SET FLAG = (A > 5)"
same "SET boolean = NOT itself"       "UPDATE T SET FLAG = NOT FLAG"
same "SET boolean = another boolean"  "UPDATE T SET FLAG = (B > 3)"
same "SET boolean = a LIKE"           "UPDATE T SET FLAG = (CAST(A AS VARCHAR(8)) LIKE '1%')"
same "SET boolean = an IS NULL test"  "UPDATE T SET FLAG = (A IS NULL)"
same "SET boolean = a literal"        "UPDATE T SET FLAG = TRUE"
same "SET date = date arithmetic"     "UPDATE T SET D = D + 1"
same "SET date = a CAST"              "UPDATE T SET D = CAST('2024-02-29' AS DATE)"
same "a NULL operand still propagates" "UPDATE T SET FLAG = (A > 5), D = D + A"

# --- the basic shapes --------------------------------------------------
same "SET col = col + literal"        "UPDATE T SET A = A + 5"
same "SET col = col * col"            "UPDATE T SET A = A * B"
same "SET col = bare other column"    "UPDATE T SET A = B"
same "SET col = parenthesised expr"   "UPDATE T SET A = (A + B) * 2"
same "SET col = unary minus"          "UPDATE T SET A = -A"
same "SET col = subtraction"          "UPDATE T SET A = A - B"
same "SET col = division"             "UPDATE T SET A = A / B"

# --- with a WHERE, and on scaled / wide columns -------------------------
same "expression under a WHERE"       "UPDATE T SET A = A + 5 WHERE B > 3"
same "expression on one row"          "UPDATE T SET A = A * B WHERE ID = 1"
same "scaled NUMERIC arithmetic"      "UPDATE T SET N = N + 1.25"
same "NUMERIC times an integer"       "UPDATE T SET N = N * 2"
same "BIGINT column"                  "UPDATE T SET K = K + 1"

# --- several assignments in one statement ------------------------------
same "two expression assignments"     "UPDATE T SET A = A + B, B = B * 2"
same "expression beside a literal"    "UPDATE T SET A = A + 1, B = 99"
same "expression beside a NULL"       "UPDATE T SET A = A + 1, N = NULL"

# --- NULL propagation --------------------------------------------------
same "NULL operand stays NULL"        "UPDATE T SET A = A + 5 WHERE ID = 3"
same "NULL row under a blanket update" "UPDATE T SET A = A + B"
same "WHERE picks the NULL row only"  "UPDATE T SET A = A + 5 WHERE A IS NULL"

# --- errors ------------------------------------------------------------
same "divide by zero raises"          "UPDATE T SET A = A / 0 WHERE ID = 1"
same "divide by a zero column"        "UPDATE T SET A = A / (B - B)"

# --- teeth -------------------------------------------------------------
# 1. SIMULTANEOUS ASSIGNMENT: both sides read the OLD row, so this swaps.
#    Sequential application would leave A and B both holding B's value.
rm -f "$W"; cp "$SRC" "$W"
printf 'UPDATE T SET A = B, B = A WHERE ID = 2;\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/dev/null 2>&1
sw=$(printf 'SET HEADING OFF;\nSELECT A, B FROM T WHERE ID = 2;\n' |
     "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -s ' \n' ' ')
case "$sw" in
    *" 4 20 "*) echo "OK   teeth: SET A = B, B = A really SWAPPED (4, 20)" ;;
    *" 4 4 "*|*" 20 20 "*)
        echo "DIFF the assignments were applied in sequence, not simultaneously: [$sw]"; fail=1 ;;
    *) echo "DIFF the swap produced [$sw], want 4 and 20"; fail=1 ;;
esac

# 2. the update must actually have changed something
rm -f "$W"; cp "$SRC" "$W"
printf 'UPDATE T SET A = A + 5;\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/dev/null 2>&1
got=$(printf 'SET HEADING OFF;\nSELECT A FROM T WHERE ID = 1;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ "$got" = "15" ]; then
    echo "OK   teeth: the expression really ran (10 + 5 = 15)"
else
    echo "DIFF expected 15 after A = A + 5, got [$got]"; fail=1
fi

# 3. the engine must accept the file, indexes included (T_A indexes the
#    very column the expression rewrote)
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ -z "$val" ]; then
    echo "OK   gfix -v -full accepts the rewritten file"
else
    echo "DIFF gfix on fc's file: $val"; fail=1
fi
if "$GBAK" -b -g -user "$U" -pas "$P" "$W" /tmp/fc-setexpr.fbk >/dev/null 2>&1; then
    echo "OK   gbak walks the rewritten file"
else
    echo "DIFF gbak failed on fc's file"; fail=1
fi
# and the index on the rewritten column still finds the new value
plan=$(printf 'SET PLAN ON;\nSET HEADING OFF;\nSELECT ID FROM T WHERE A = 15;\n' |
       "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -s ' \n' ' ')
case "$plan" in
    *"T_A"*" 1 "*) echo "OK   teeth: the engine finds the new value THROUGH the index" ;;
    *) echo "DIFF index lookup after the update gave [$plan]"; fail=1 ;;
esac

# 4. a computed column is read-only - SET on one must be refused
"$ISQL" -q -b -user "$U" -pas "$P" "$SRC" >/dev/null 2>&1 <<'SQL'
ALTER TABLE T ADD C COMPUTED BY (A + B);
COMMIT;
SQL
rm -f "$W"; cp "$SRC" "$W"
out=$(printf 'UPDATE T SET C = 1;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: SET on a COMPUTED column is refused" ;;
    *) echo "DIFF SET on a computed column reported [$out]"; fail=1 ;;
esac

exit $fail
