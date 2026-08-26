#!/bin/bash
# AT TIME ZONE + the time-zone EXTRACT parts - the two surfaces the
# tz-DML slice recorded as "outside this slice".
#
# `<value> AT TIME ZONE <zone>` (parse.y:8561, AtNode) CONVERTS AND THEN
# RE-LABELS (ExprNodes.cpp:3368: MOV_move to the WITH TIME ZONE type
# normalises to a UTC instant, then only the zone id is overwritten):
#   * a ZONELESS operand is a wall time in the SESSION zone - 12:00
#     under a UTC session is 14:00 +02:00, and 11:00 +02:00 under a
#     +03:00 session (the standard's reading, the OPPOSITE of
#     PostgreSQL's re-anchoring)
#   * a ZONED operand keeps its instant and only changes how it prints
#   * the result is ALWAYS a WITH TIME ZONE value, of the operand's own
#     family (TIME -> TIME WITH TIME ZONE, TIMESTAMP -> TIMESTAMP WITH
#     TIME ZONE), described 32756/8 and 32754/12, named AT, and NOT
#     nullable when neither operand is (AtNode::make:3328)
#   * `AT LOCAL` is the session zone, and still yields a zoned value
#   * the operator chains left (`%left AT`), the zone may be any
#     expression, and it is evaluated PER ROW: a bad zone is a 22009 at
#     EXECUTE, never at prepare
# EXTRACT gains TIMEZONE_HOUR / TIMEZONE_MINUTE, SIGNED ON BOTH PARTS
# (ExprNodes.cpp:5860 `tzSign * tzh` / `tzSign * tzm`: -03:30 gives -3
# and -30), and a ZONELESS operand answers the SESSION zone's offset
# (:5806). Ordinary parts of a zoned value read its LOCAL WALL CLOCK
# (:5825 decodeTimeStamp adds the displacement first), not the stored
# UTC instant.
# Beside them a pre-existing describe divergence is closed: EXTRACT
# announced BIGINT for every part where the engine announces SMALLINT
# (ExprNodes.cpp:5644 makeShort) - and INTEGER at scale -4/-1 for
# SECOND/MILLISECOND (makeLong).
#
# Boundaries (recorded): a RULED named zone (Europe/Paris) refuses -
# fire-crab carries no tzdata rules, so it cannot place a value in one
# (the tz-DML slice's boundary, unchanged); TIMEZONE_NAME refuses for
# the same reason (the engine renders it through ICU).
#
#   qa/serve-real-attimezone.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4994}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-attz.fdb"
LOG="/tmp/fc-serve-attz-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE TZT (ID INTEGER, TS TIMESTAMP, TSZ TIMESTAMP WITH TIME ZONE,
                  TM TIME, TMZ TIME WITH TIME ZONE);
COMMIT;
INSERT INTO TZT VALUES (1, TIMESTAMP '2020-06-15 12:00:00',
                           TIMESTAMP '2020-06-15 12:00:00 +05:00',
                           TIME '12:00:00', TIME '12:00:00 +05:00');
INSERT INTO TZT VALUES (2, TIMESTAMP '2020-12-31 23:30:00',
                           TIMESTAMP '2020-12-31 23:30:00 -03:30',
                           TIME '23:30:00', TIME '23:30:00 -03:30');
COMMIT;
EOF
chmod 666 "$DB"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
norm() { grep -v '^$' | sed 's/  */ /g; s/^ //; s/ *$//' | tr '\n' '|'; }
# fc and the engine, same statement, same file
q()  { printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "127.0.0.1/$1:$DB" 2>&1 | norm; }
qz() { printf "SET HEADING OFF;\nSET TIME ZONE '%s';\n%s\n" "$2" "$3" \
    | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "127.0.0.1/$1:$DB" 2>&1 | norm; }
qd() { printf 'SET SQLDA_DISPLAY ON;\nSET HEADING OFF;\n%s\n' "$2" \
    | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "127.0.0.1/$1:$DB" 2>&1 | grep -E 'sqltype|name:' | norm; }
both() { ran=$((ran + 1)); a=$(q "$PORT" "$2"); b=$(q "$REAL" "$2")
    if [ "$a" = "$b" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi; }
bothz() { ran=$((ran + 1)); a=$(qz "$PORT" "$2" "$3"); b=$(qz "$REAL" "$2" "$3")
    if [ "$a" = "$b" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi; }
bothd() { ran=$((ran + 1)); a=$(qd "$PORT" "$2"); b=$(qd "$REAL" "$2")
    if [ "$a" = "$b" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi; }

# --- the conversion law, literals ---
both "a zoneless TIMESTAMP is a wall time in the SESSION zone" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"
both "a ZONED timestamp keeps its instant and only re-labels" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00 +05:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"
both "...including into UTC" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00 +05:00' AT TIME ZONE 'UTC' FROM RDB\$DATABASE;"
both "a zoneless TIME converts the same way" \
    "SELECT TIME '12:00:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"
both "a zoned TIME re-labels" \
    "SELECT TIME '12:00:00 +05:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"
both "the operator CHAINS left" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE '+02:00' AT TIME ZONE '-03:00' FROM RDB\$DATABASE;"
both "AT LOCAL is the session zone, and still zoned" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00 +05:00' AT LOCAL FROM RDB\$DATABASE;"
both "the zone may be an EXPRESSION" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE ('+0' || '2:00') FROM RDB\$DATABASE;"
both "a NULL datetime answers NULL" \
    "SELECT CAST(NULL AS TIMESTAMP) AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"
both "a NULL zone answers NULL" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE CAST(NULL AS VARCHAR(10)) FROM RDB\$DATABASE;"

# --- the SESSION zone is what a zoneless operand is read in ---
bothz "under a +03:00 session, a zoneless operand converts from THERE" "+03:00" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"
bothz "...and a zoned one is unaffected by the session" "+03:00" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00 +05:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"

# --- columns, and every stored kind ---
both "over stored columns: plain and zoned, TIMESTAMP and TIME" \
    "SELECT ID, TS AT TIME ZONE '+02:00', TSZ AT TIME ZONE '-05:30', TM AT TIME ZONE '+02:00', TMZ AT TIME ZONE '-05:30' FROM TZT ORDER BY ID;"

# --- the describe: form, width and the column NAME ---
bothd "describe: TIMESTAMP WITH TIME ZONE 32754/12, TIME WITH TIME ZONE 32756/8, named AT" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE '+02:00', TIME '12:00:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"
bothd "...and a column operand keeps the nullability of its operands" \
    "SELECT TS AT TIME ZONE '+02:00' FROM TZT;"

# --- in the predicate and the sort, by INSTANT ---
both "in WHERE, comparing by UTC instant across spellings" \
    "SELECT ID FROM TZT WHERE TSZ AT TIME ZONE '+09:00' = TIMESTAMP '2020-06-15 07:00:00 UTC';"
both "...a zoneless column too (the session's reading)" \
    "SELECT ID FROM TZT WHERE TS AT TIME ZONE '+02:00' = TIMESTAMP '2020-06-15 12:00:00 UTC';"
both "in ORDER BY" \
    "SELECT ID FROM TZT ORDER BY TS AT TIME ZONE '+02:00' DESC;"
both "in a COUNT over a predicate" \
    "SELECT COUNT(*) FROM TZT WHERE TS AT TIME ZONE '+02:00' > TIMESTAMP '2000-01-01 00:00:00 UTC';"

# --- the zone errors: 22009 verbatim, at EXECUTE ---
both "a bad OFFSET is 22009, verbatim" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE '+99:00' FROM RDB\$DATABASE;"
both "an unknown REGION is 22009, verbatim" \
    "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE 'Nowhere/Here' FROM RDB\$DATABASE;"
both "a DATE operand refuses (the engine's prepare-time -833)" \
    "SELECT DATE '2020-06-15' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;"

# --- EXTRACT: the two zone parts, signed on BOTH ---
both "TIMEZONE_HOUR and TIMEZONE_MINUTE are SIGNED on both parts" \
    "SELECT EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2020-06-15 12:00:00 -03:30'), EXTRACT(TIMEZONE_MINUTE FROM TIMESTAMP '2020-06-15 12:00:00 -03:30') FROM RDB\$DATABASE;"
both "...positive offsets too" \
    "SELECT EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2020-06-15 12:00:00 +05:45'), EXTRACT(TIMEZONE_MINUTE FROM TIMESTAMP '2020-06-15 12:00:00 +05:45') FROM RDB\$DATABASE;"
both "...over a TIME WITH TIME ZONE" \
    "SELECT EXTRACT(TIMEZONE_HOUR FROM TIME '12:00:00 -03:30') FROM RDB\$DATABASE;"
bothz "a ZONELESS operand answers the SESSION zone's offset" "+03:00" \
    "SELECT EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2020-06-15 12:00:00'), EXTRACT(TIMEZONE_MINUTE FROM TIMESTAMP '2020-06-15 12:00:00') FROM RDB\$DATABASE;"
both "...and under a UTC session that is zero" \
    "SELECT EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2020-06-15 12:00:00') FROM RDB\$DATABASE;"

# --- EXTRACT: ordinary parts of a zoned value are its LOCAL wall clock ---
both "ordinary parts read the value's own LOCAL clock, not UTC" \
    "SELECT EXTRACT(HOUR FROM TIMESTAMP '2020-06-15 12:00:00 +03:30'), EXTRACT(DAY FROM TIMESTAMP '2020-06-15 23:00:00 +03:30') FROM RDB\$DATABASE;"
both "...across the stored columns, including the year end" \
    "SELECT ID, EXTRACT(HOUR FROM TSZ), EXTRACT(DAY FROM TSZ), EXTRACT(YEAR FROM TSZ), EXTRACT(MINUTE FROM TMZ) FROM TZT ORDER BY ID;"
both "...and the zone parts over columns" \
    "SELECT ID, EXTRACT(TIMEZONE_HOUR FROM TSZ), EXTRACT(TIMEZONE_MINUTE FROM TSZ) FROM TZT ORDER BY ID;"
both "a zone part drives a predicate" \
    "SELECT ID FROM TZT WHERE EXTRACT(TIMEZONE_HOUR FROM TSZ) = 5;"

# --- the describe divergence this slice closed ---
bothd "EXTRACT describes SMALLINT for integer parts, INTEGER for SECOND/MILLISECOND" \
    "SELECT EXTRACT(YEAR FROM DATE '2020-06-15'), EXTRACT(SECOND FROM TIME '12:00:00'), EXTRACT(MILLISECOND FROM TIME '12:00:00'), EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2020-06-15 12:00:00 -03:30') FROM RDB\$DATABASE;"

# --- SET TIME ZONE: the session zone itself ---
both "SET TIME ZONE moves the zoneless clocks with it (LOCALTIMESTAMP)" \
    "SELECT EXTRACT(HOUR FROM LOCALTIMESTAMP) - EXTRACT(HOUR FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC') FROM RDB\$DATABASE;"
bothz "...LOCALTIME follows the session too" "+05:00" \
    "SELECT EXTRACT(HOUR FROM LOCALTIME) - EXTRACT(HOUR FROM CURRENT_TIME AT TIME ZONE 'UTC') FROM RDB\$DATABASE;"
bothz "...and CURRENT_DATE is the session's day" "+14:00" \
    "SELECT CURRENT_DATE - CAST(LOCALTIMESTAMP AS DATE) FROM RDB\$DATABASE;"
both "a bad OFFSET in SET TIME ZONE is the same 22009" \
    "SET TIME ZONE '+99:00';"
both "an unknown REGION in SET TIME ZONE is the same 22009" \
    "SET TIME ZONE 'Nowhere/Here';"
# THE WORDS MUST BE WORDS: the engine -104s every glued spelling, and
# fire-crab must not quietly TAKE one. (fc's unknown-statement refusal
# does not carry the engine's token-level -104 text - a pre-existing
# refusal SHAPE difference, so this pins that both REFUSE and that the
# session zone is untouched, not the vector.)
refuses() { ran=$((ran + 1)); r=$(q "$PORT" "$2")
    case "$r" in
        *"Statement failed"*) echo "OK   $1" ;;
        *) echo "DIFF $1 - fc answered [$r]"; fail=1 ;;
    esac; }
refuses "SET TIMEZONE (one word) is not this statement" "SET TIMEZONE '+07:00';"
refuses "SETTIME ZONE is not either" "SETTIME ZONE '+07:00';"
refuses "nor SETTIMEZONE" "SETTIMEZONE '+07:00';"
# ...and the refused spelling left the session alone: the SELECT that
# follows it in the SAME session still converts from the default zone
# (no -b here, so the script continues past the refusal)
ran=$((ran + 1))
r=$(printf "SET HEADING OFF;\nSET TIMEZONE '+07:00';\nSELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE '+02:00' FROM RDB\$DATABASE;\n" \
    | "$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | grep -c '14:00:00')
if [ "$r" = "1" ]; then echo "OK   ...and a refused spelling left the session zone alone"; else
    echo "DIFF a refused SET TIMEZONE moved the session zone"; fail=1; fi

# --- a WITH TIME ZONE value through a derived table and a CTE ---
both "a tz column named out of a derived table keeps its value" \
    "SELECT Y FROM (SELECT TSZ AS Y FROM TZT) Q ORDER BY 1;"
both "...and an AT TIME ZONE result through a CTE" \
    "WITH Q AS (SELECT ID, TS AT TIME ZONE '+02:00' AS X FROM TZT) SELECT ID, X FROM Q ORDER BY ID;"
both "...a TIME WITH TIME ZONE too" \
    "SELECT Y FROM (SELECT TMZ AS Y FROM TZT) Q ORDER BY 1;"

# --- the EXTRACT describe holds under every wrapper ---
bothd "EXTRACT keeps its declared width under -, COALESCE, CASE and NULLIF" \
    "SELECT -EXTRACT(YEAR FROM DATE '2020-06-15'), COALESCE(EXTRACT(HOUR FROM TIME '12:00:00'), 0), CASE WHEN 1=1 THEN EXTRACT(TIMEZONE_HOUR FROM TIMESTAMP '2020-06-15 12:00:00 +05:00') ELSE 0 END, NULLIF(EXTRACT(SECOND FROM TIME '12:00:00'), 0) FROM RDB\$DATABASE;"

# --- BOUNDARY: a ruled zone has no rules here, and must refuse ---
ran=$((ran + 1))
r=$(q "$PORT" "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE 'Europe/Paris' FROM RDB\$DATABASE;")
e=$(q "$REAL" "SELECT TIMESTAMP '2020-06-15 12:00:00' AT TIME ZONE 'Europe/Paris' FROM RDB\$DATABASE;")
case "$r" in
    *"Statement failed"*) echo "OK   boundary: a RULED zone refuses (fc carries no tzdata rules; engine: ${e%%|*})" ;;
    *) echo "DIFF a ruled zone must refuse, fc answered [$r]"; fail=1 ;;
esac
ran=$((ran + 1))
r=$(q "$PORT" "SELECT EXTRACT(TIMEZONE_NAME FROM TIMESTAMP '2020-06-15 12:00:00 +05:00') FROM RDB\$DATABASE;")
case "$r" in
    *"Statement failed"*) echo "OK   boundary: TIMEZONE_NAME refuses (the engine renders it through ICU)" ;;
    *) echo "DIFF TIMEZONE_NAME must refuse, fc answered [$r]"; fail=1 ;;
esac
ran=$((ran + 1))
r=$(q "$PORT" "SET TIME ZONE 'Europe/Paris';")
case "$r" in
    *"Statement failed"*) echo "OK   boundary: a session cannot be SET to a ruled zone either" ;;
    *) echo "DIFF SET TIME ZONE to a ruled zone must refuse, fc answered [$r]"; fail=1 ;;
esac
# RECORDED DIVERGENCE, not a check: under isql's autocommit a
# statement typed isc_info_sql_stmt_ddl runs on isql's OWN transaction
# and is committed there (isql.epp:8575) - and fire-crab hands every
# transaction the same TX_HANDLE, so that commit takes the caller's
# pending DML with it. SET TIME ZONE is the first session-management
# statement to reach that path; a plain CREATE TABLE in the same
# position diverges identically (measured), so the gap is the shared
# handle, not this statement. Priced and recorded; the fix is distinct
# transaction handles.
echo "BOUND isql-autocommit commits pending DML on a stmt_ddl statement (shared TX handle; CREATE TABLE diverges the same way)"

# --- the file is untouched by any of it ---
kill $srv 2>/dev/null; wait $srv 2>/dev/null
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$DB" 2>&1 | norm)
if [ -z "$v" ]; then echo "OK   gfix -v -full is silent afterwards"; else
    echo "DIFF gfix: [$v]"; fail=1; fi

echo
if [ "$fail" = 0 ]; then echo "PASS all $ran checks"; else echo "FAIL"; exit 1; fi
