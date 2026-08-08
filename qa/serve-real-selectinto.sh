#!/bin/bash
# The STATIC singleton: `SELECT ... INTO :v[, :v];` inside a body.
#
# The dynamic form (EXECUTE STATEMENT ... INTO) had the machinery; the
# static form was outside the surface, and its laws are NOT the dynamic
# form's - each measured against the engine first:
#
#   * a MATCH assigns every value, NULLs INCLUDED (a NULL column
#     overwrites the variable);
#   * NO MATCH leaves the variables ALONE - but ROW_COUNT says 0, where
#     the dynamic form leaves ROW_COUNT at the last static statement's
#     count. A match sets it to 1. THE STATIC FORM TOUCHES ROW_COUNT;
#   * several rows raise 21000 "multiple rows in singleton select" with
#     the `At block line` item;
#   * an arity mismatch is the -313 vector ("count of column list and
#     variable list do not match", SQLSTATE 07002) - NOT the dynamic
#     form's 42000 "Output parameters mismatch". The engine raises it at
#     PREPARE of the block; this server's source interpreter raises the
#     same vector when the statement RUNS - the moment differs, the
#     message does not, and isql shows the identical text either way;
#   * expression select-lists work.
#
# OBSERVABILITY: blocks with RETURNS and `:var` in INSERT VALUES are
# outside this server's block surface, so the variables are observed
# through CONDITIONAL EXCEPTION RAISES - IF (<expected state>) THEN
# EXCEPTION E_YES; ELSE EXCEPTION E_NO; - whose vectors the exceptions
# gate already holds equal.
#
#   qa/serve-real-selectinto.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4726}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-selectinto-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

mkdb() { # <conn-or-path for CREATE>
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V VARCHAR(10));
CREATE EXCEPTION E_YES 'yes';
CREATE EXCEPTION E_NO 'no';
COMMIT;
INSERT INTO T VALUES (1, 'one');
INSERT INTO T VALUES (2, 'two');
INSERT INTO T VALUES (3, NULL);
COMMIT;
EOF
}
EDB="$D/fc-si-e.fdb"
FDB="$D/fc-si-f.fdb"
rm -f "$EDB" "$FDB"
mkdb "localhost:$EDB"   # the engine's copy, through its own server
mkdb "$FDB"             # fire-crab's copy, embedded-created then served
chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
E="localhost:$EDB"
F="127.0.0.1/$PORT:$FDB"

blk() { # <conn> <body lines>
    printf 'SET TERM ^ ;\nEXECUTE BLOCK AS\nDECLARE A INTEGER;\nDECLARE B VARCHAR(10);\nDECLARE RC INTEGER;\nBEGIN\n%s\nEND^\nSET TERM ; ^\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
both() { # <label> <body>
    check "$1" "$(blk "$F" "$2")" "$(blk "$E" "$2")"
}

# --- 1. a match assigns - NULLs included - and sets ROW_COUNT to 1 ------------
# (a TEXT comparison in an IF is outside this server's condition
# surface, so B is observed through IS [NOT] NULL - initialized unset)
both "a match assigns the variables" \
  "A = 99;
   SELECT ID, V FROM T WHERE ID = 1 INTO :A, :B;
   IF (A = 1) THEN BEGIN
     IF (B IS NOT NULL) THEN EXCEPTION E_YES; ELSE EXCEPTION E_NO;
   END ELSE EXCEPTION E_NO;"
both "...and ROW_COUNT says 1 - the static form touches it" \
  "SELECT ID FROM T WHERE ID = 2 INTO :A;
   RC = ROW_COUNT;
   IF (RC = 1) THEN EXCEPTION E_YES; ELSE EXCEPTION E_NO;"
both "a NULL column OVERWRITES the variable" \
  "B = 'keep';
   SELECT ID, V FROM T WHERE ID = 3 INTO :A, :B;
   IF (B IS NULL) THEN EXCEPTION E_YES; ELSE EXCEPTION E_NO;"

# --- 2. no match: the slots are left alone, ROW_COUNT says 0 -------------------
both "no match leaves the variables ALONE" \
  "A = 99;
   SELECT ID, V FROM T WHERE ID = 55 INTO :A, :B;
   IF (A = 99) THEN BEGIN
     IF (B IS NULL) THEN EXCEPTION E_YES; ELSE EXCEPTION E_NO;
   END ELSE EXCEPTION E_NO;"
both "...and ROW_COUNT says 0" \
  "SELECT ID FROM T WHERE ID = 55 INTO :A;
   RC = ROW_COUNT;
   IF (RC = 0) THEN EXCEPTION E_YES; ELSE EXCEPTION E_NO;"

# --- 3. several rows raise 21000, at the statement's own line ------------------
both "several rows raise 21000 multiple-rows-in-singleton" \
  "SELECT ID FROM T INTO :A;"

# --- 4. the arity mismatch is the -313 vector ----------------------------------
# (the engine raises it at PREPARE, this server when the statement runs;
# isql shows the identical text either way - the MOMENT is the recorded
# difference, not the message)
both "an arity mismatch is the -313 count-mismatch vector" \
  "SELECT ID, V FROM T WHERE ID = 1 INTO :A;"

# --- 5. expressions in the select list ------------------------------------------
both "an expression select-list assigns its value" \
  "SELECT ID * 10 + 5 FROM T WHERE ID = 2 INTO :A;
   IF (A = 25) THEN EXCEPTION E_YES; ELSE EXCEPTION E_NO;"

echo "ran $ran checks"
exit $fail
