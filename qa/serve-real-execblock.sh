#!/bin/bash
# EXECUTE BLOCK - a body with no DDL around it.
#
# It is the PSQL interpreter's own surface with the CREATE PROCEDURE
# taken away: the block's text IS the body, it has no catalog row, and
# it runs where it stands. That is why it costs almost nothing here and
# why it matters - the paper's own event client posts with `execute
# block as begin post_event '...'; end`, and every firebird-qa test that
# needs a scrap of PSQL without a procedure writes one.
#
# What is gated: that a block runs, that it WRITES like any statement
# (and its writes belong to the transaction, so a rollback takes them),
# that a failure inside it reaches the client as the engine's own error,
# and that the two forms this server does not serve are REFUSED rather
# than half-run - the parameterised one, whose arguments arrive in a
# message, and the `RETURNS` one, which makes the block selectable.
#
#   qa/serve-real-execblock.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4713}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-execblock.fdb"
LOG="/tmp/fc-serve-execblock-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10);
INSERT INTO T VALUES (2,20);
COMMIT;
EOF
chmod 666 "$DB"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

run() { # <conn> <sql>
    printf '%s\n' "$2" | timeout 30 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' '|'
}
both() { # <label> <sql>
    local e c
    e=$(run "$DB" "$2"); c=$(run "127.0.0.1/$PORT:$DB" "$2")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: $e"; echo "     fc:     $c"; fail=1; fi
}

# --- 1. it runs, and it writes ------------------------------------------
both "a block that writes" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK AS BEGIN INSERT INTO T (ID, V) VALUES (9, 90); END^
SET TERM ;^
SELECT V FROM T WHERE ID = 9;
ROLLBACK;"
both "...and the write is the TRANSACTION's, so a rollback takes it" "SET HEADING OFF;
SELECT COUNT(*) FROM T WHERE ID = 9;"
both "several statements, and a local variable" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK AS
DECLARE K INTEGER;
BEGIN
  K = 5;
  INSERT INTO T (ID, V) VALUES (11, :K);
  UPDATE T SET V = V + 1 WHERE ID = 11;
END^
SET TERM ;^
SELECT V FROM T WHERE ID = 11;
ROLLBACK;"
both "a loop inside the block" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK AS
DECLARE I INTEGER;
BEGIN
  I = 0;
  WHILE (I < 3) DO
  BEGIN
    I = I + 1;
    INSERT INTO T (ID, V) VALUES (20 + :I, :I);
  END
END^
SET TERM ;^
SELECT COUNT(*) FROM T WHERE ID > 20;
ROLLBACK;"

# --- 2. a failure inside it is the engine's own error --------------------
both "a division by zero inside the block" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK AS
DECLARE Z INTEGER;
DECLARE N INTEGER;
BEGIN
  Z = 0;
  N = 1/Z;
END^"
both "a duplicate key inside the block" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK AS BEGIN INSERT INTO T (ID, V) VALUES (1, 1); END^"
both "...and nothing it wrote before the failure remains" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK AS
BEGIN
  INSERT INTO T (ID, V) VALUES (30, 300);
  INSERT INTO T (ID, V) VALUES (1, 1);
END^
SET TERM ;^
SELECT COUNT(*) FROM T WHERE ID = 30;
ROLLBACK;"

# --- 3. RECORDED BOUNDARIES ---------------------------------------------
# ASSERTIONS: when one of these lands, this gate must FAIL rather than
# quietly agree.
boundary() { # <label> <sql>
    local e c
    e=$(run "$DB" "$2"); c=$(run "127.0.0.1/$PORT:$DB" "$2")
    ran=$((ran + 1))
    if [ "$e" != "$c" ] && [ "${c#*Dynamic SQL Error}" != "$c" ]; then
        echo "OK   boundary: $1 (engine [$e], fc refuses)"
    else
        echo "DIFF boundary MOVED: $1"
        echo "     engine: $e"
        echo "     fc:     $c"
        fail=1
    fi
}
# the arguments arrive in a message the client built from the block's
# own parameter list; RETURNS makes the block SELECTABLE, so its rows
# are a result set and not nothing
boundary "EXECUTE BLOCK (<params>)" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK (A INTEGER = 5) AS BEGIN INSERT INTO T (ID, V) VALUES (40, :A); END^"
boundary "EXECUTE BLOCK ... RETURNS (...)" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN N = 7; SUSPEND; END^"

# --- 4. TEETH ------------------------------------------------------------
# Both servers are compared, so a shared refusal reads as agreement.
ran=$((ran + 1))
answers=$(run "127.0.0.1/$PORT:$DB" "SET HEADING OFF;
SET TERM ^;
EXECUTE BLOCK AS
DECLARE K INTEGER;
BEGIN
  K = 3;
  INSERT INTO T (ID, V) VALUES (50, :K * 100);
END^
SET TERM ;^
SELECT V FROM T WHERE ID = 50;
ROLLBACK;")
if [ "$answers" = "300|" ]; then
    echo "OK   teeth: the block really ran, and its arithmetic reached the table"
else
    echo "DIFF teeth: [$answers]"; fail=1
fi
refused=$(grep -c "execute block failed" "$LOG")
ran=$((ran + 1))
if [ "$refused" -le 3 ]; then
    echo "OK   teeth: only the failing blocks failed ($refused)"
else
    echo "DIFF teeth: $refused blocks failed"; fail=1
fi

echo "ran $ran checks"
exit $fail
