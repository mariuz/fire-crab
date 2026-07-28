#!/bin/bash
# THE FIXED-ANSWER FALLBACK MUST NEVER REACH A CLIENT.
#
# When this server cannot plan a statement it falls back to
# Plan::Scalar(FIXED_ANSWER) - one row, one column, the value 4242. That
# exists so the wire pipeline still round-trips during development, but as
# an ANSWER it is the worst possible outcome: a client cannot tell it from
# a real result, so an unsupported query looks like it succeeded and
# returned nonsense.
#
# The hazard has had to be cut off five times so far, once per surface:
# procedures (Inc150), views (Inc153), unions (Inc154), result modifiers
# (Inc161) and conditional expressions (Inc164). Each time it was found by
# accident. This gate looks for it on purpose.
#
# Two properties are checked over every query below:
#
#   1. a query the server SUPPORTS must not contain 4242 in its answer;
#   2. a query it does NOT support must RAISE - an error, not a row.
#
# The second is the one that catches a new fallback path: any statement
# whose shape this server declines should reach the client as a SQL error.
# A case that answers 4242 fails here whichever list it is in.
#
#   qa/serve-real-nofallback.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4495}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-nofallback.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, S VARCHAR(10), N NUMERIC(9,2));
CREATE TABLE U2 (ID INTEGER NOT NULL PRIMARY KEY, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10, 'x', 12.50);
INSERT INTO T VALUES (2, 20, 'y', 1.25);
INSERT INTO T VALUES (3, NULL, NULL, NULL);
INSERT INTO U2 VALUES (1, 100);
COMMIT;
CREATE VIEW V AS SELECT ID, A FROM T;
CREATE VIEW VJ AS SELECT T.ID, U2.W FROM T JOIN U2 ON U2.ID = T.ID;
COMMIT;
SET TERM ^;
CREATE PROCEDURE GEN (N INTEGER) RETURNS (K INTEGER) AS
DECLARE VARIABLE I INTEGER;
BEGIN
  I = 1;
  WHILE (I <= N) DO
  BEGIN
    K = I; SUSPEND; I = I + 1;
  END
END^
CREATE PROCEDURE UNSUP RETURNS (R INTEGER) AS
DECLARE VARIABLE C INTEGER;
BEGIN
  EXECUTE STATEMENT 'SELECT 1 FROM RDB\$DATABASE' INTO :C;
  R = C;
END^
SET TERM ;^
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nofb.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

fail=0
ask() { printf 'SET HEADING OFF;\n%s;\n' "$1" |
        "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' '; }

# a query the server ANSWERS: the answer must not be the fallback, and it
# must match the engine
answers() { # <sql>
    out=$(ask "$1")
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$1" |
         "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    case "$out" in
        *4242*) echo "DIFF FALLBACK LEAKED: [$1] answered [$out]"; fail=1; return ;;
    esac
    if [ "$out" = "$en" ]; then
        echo "OK   answers, no fallback: $1"
    else
        echo "DIFF [$1] engine=[$en] fc=[$out]"; fail=1
    fi
}
# a query the server does NOT support: it must RAISE, never answer
refuses() { # <sql>
    out=$(ask "$1")
    case "$out" in
        *4242*)
            echo "DIFF FALLBACK LEAKED: [$1] answered [$out] instead of raising"; fail=1 ;;
        *"Statement failed"*|*error*|*ERROR*)
            echo "OK   refuses cleanly: $1" ;;
        *) echo "DIFF [$1] answered [$out] instead of raising"; fail=1 ;;
    esac
}

# --- supported, across every surface -----------------------------------
answers "SELECT A FROM T ORDER BY ID"
answers "SELECT COUNT(*) FROM T"
answers "SELECT A + 1 FROM T ORDER BY ID"
answers "SELECT A || S FROM T WHERE ID = 1"
answers "SELECT CAST(A AS BIGINT) FROM T ORDER BY ID"
answers "SELECT COALESCE(A, 0) FROM T ORDER BY ID"
answers "SELECT NULLIF(A, 10) FROM T ORDER BY ID"
answers "SELECT IIF(A > 15, 1, 0) FROM T ORDER BY ID"
answers "SELECT DISTINCT A FROM T ORDER BY 1"
answers "SELECT FIRST 2 ID FROM T ORDER BY ID"
answers "SELECT ID FROM T ORDER BY ID ROWS 2"
answers "SELECT ID FROM T UNION ALL SELECT ID FROM U2 ORDER BY 1"
answers "SELECT ID, A FROM V ORDER BY ID"
answers "SELECT ID FROM T WHERE ID IN (SELECT ID FROM U2)"
answers "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.ID = T.ID)"
answers "SELECT ID FROM T WHERE A > (SELECT MIN(W) FROM U2)"
answers "SELECT K FROM GEN(3)"
answers "SELECT FIRST 2 K FROM GEN(5)"
answers "SELECT SUM(A) FROM T"
answers "SELECT A, COUNT(*) FROM T GROUP BY A ORDER BY 1"
answers "SELECT T.ID, U2.W FROM T JOIN U2 ON U2.ID = T.ID"
answers "SELECT N + 1.25 FROM T WHERE ID = 1"
answers "SELECT ID FROM T WHERE S LIKE 'x%'"
answers "EXECUTE PROCEDURE GEN 1"
# built-in scalar functions joined the surface (serve-real-functions.sh
# is their gate; these two used to sit in the unsupported list below)
answers "SELECT UPPER(S) FROM T ORDER BY ID"
answers "SELECT SUBSTRING(S FROM 1 FOR 1) FROM T ORDER BY ID"

# --- NOT supported: each must raise ------------------------------------
# a view over a join (the view has a relation id but no records, so a
# fall-through would scan its empty storage and answer ZERO ROWS)
refuses "SELECT ID, W FROM VJ"
# a PSQL body outside the interpreted surface
refuses "EXECUTE PROCEDURE UNSUP"
# a procedure that does not exist
refuses "EXECUTE PROCEDURE NOSUCHPROC"
# malformed conditional calls
refuses "SELECT COALESCE(A) FROM T"
refuses "SELECT NULLIF(A) FROM T"
refuses "SELECT IIF(A > 1) FROM T"
# malformed built-in function calls
refuses "SELECT UPPER() FROM T"
refuses "SELECT LEFT(S) FROM T"
# modifier grammar the engine rejects too
refuses "SELECT DISTINCT FIRST 2 A FROM T"
refuses "SELECT SKIP 1 FIRST 2 ID FROM T"
# a union whose branches are different widths
refuses "SELECT ID FROM T UNION ALL SELECT ID, W FROM U2"
# an aggregate branch in a union
refuses "SELECT COUNT(*) FROM T UNION ALL SELECT ID FROM U2"
# a WHERE over a procedure call
refuses "SELECT K FROM GEN(5) WHERE K > 2"
# a rollback to a savepoint that was never set
refuses "ROLLBACK TO NOSUCHPOINT"

# --- teeth -------------------------------------------------------------
# the fallback must be reachable AT ALL for this gate to mean anything:
# a shape far outside the surface should still not answer 4242
for weird in "SELECT CASE WHEN A > 1 THEN 1 ELSE 0 END FROM T" \
             "SELECT A FROM T WHERE UPPER(S) = 'X'" \
             "SELECT EXTRACT(YEAR FROM CURRENT_DATE) FROM T" \
             "SELECT A FROM T GROUP BY A HAVING COUNT(*) > 99 ORDER BY 1 ROWS 1 TO 2"; do
    out=$(ask "$weird")
    case "$out" in
        *4242*) echo "DIFF FALLBACK LEAKED on an unsupported shape: [$weird] -> [$out]"; fail=1 ;;
        *) echo "OK   unsupported shape did not answer the fallback: $weird" ;;
    esac
done

# --- a refusal must be a CLEAN error, and must not kill the session ----
# A refusal used to be raised mid-cursor: the prepare was answered and the
# error arrived during the fetch, which some clients report as
# "request synchronization error" and follow by dropping the connection -
# and a dropped connection is what libfbclient segfaults on. A refused
# statement now fails at PREPARE, which is where the engine fails an
# unsupported one, so the client gets a plain SQL error and carries on.
out=$(printf 'SET HEADING OFF;\nSELECT CASE WHEN A > 1 THEN 1 ELSE 0 END FROM T;\nSELECT A FROM T ORDER BY ID;\nSELECT COUNT(*) FROM T;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1)
flat=$(printf '%s' "$out" | tr -s ' \n' ' ')
case "$flat" in
    *"synchronization error"*)
        echo "DIFF a refusal desynced the connection: [$flat]"; fail=1 ;;
    *"Statement failed"*) echo "OK   a refusal is a clean SQL error" ;;
    *) echo "DIFF a refusal produced [$flat]"; fail=1 ;;
esac
# the two statements AFTER the refusal must still have been answered
# the values from the two statements AFTER the refusal must be there -
# checked as a count of answered rows rather than a brittle glob
after=$(printf 'SET HEADING OFF;\nSELECT CASE WHEN A > 1 THEN 1 ELSE 0 END FROM T;\nSELECT A FROM T WHERE A IS NOT NULL ORDER BY ID;\n' |
        "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 |
        grep -cE '^ *[0-9]+ *$')
if [ "$after" -ge 2 ]; then
    echo "OK   teeth: the session survived the refusal and answered $after more rows"
else
    echo "DIFF the session answered $after rows after a refusal, want 2 or more"; fail=1
fi
# and the refusal must carry a SQL error code, not a protocol one
case "$flat" in
    *"SQLSTATE = 42000"*) echo "OK   teeth: the refusal carries SQLSTATE 42000 (a SQL error)" ;;
    *) echo "DIFF the refusal's SQLSTATE is not 42000: [$flat]"; fail=1 ;;
esac

exit $fail
