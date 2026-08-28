#!/bin/bash
# A BEFORE TRIGGER THAT DRAWS A GENERATOR - the classic auto-increment,
# and the one side effect a trigger body may have here.
#
# A draw is a page write, and a trigger fires INSIDE a statement that is
# already holding the working copy of that page - so the draw belongs to
# the CALLER, which has it. The body therefore runs TWICE: pass one
# RECORDS what it would draw (every draw answering 0, over a COPY of the
# row), the caller performs exactly those draws, and pass two REPLAYS the
# values in order. That is sound because a runnable body is otherwise
# pure and both passes start from the same row - and it gets the two
# cases that matter right:
#
#   * a CONDITIONAL draw consumes a value only when its branch runs
#     (`IF (NEW.ID IS NULL) THEN NEW.ID = GEN_ID(G, 1)` leaves the
#     generator alone when the client supplied an ID);
#   * a body that RAISES after drawing still consumes the value, which
#     is what the engine does - the generator is not transactional.
#
# What refuses, and why: a body whose CONTROL FLOW would read a value a
# draw produced. Pass one answers 0 for every draw, so such a body could
# branch differently in the two passes and record the wrong draws.
#
# The BLR is the other half: `CREATE TRIGGER` writes `blr_gen_id` (a
# counted name then the step) and `blr_gen_id2` (the counted name alone
# - NEXT VALUE FOR is a different verb, not sugar for GEN_ID(g, 1)), and
# the ENGINE runs what this server wrote.
#
#   qa/serve-real-triggen.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4932}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-triggen-crab.fdb"
B="$D/fc-triggen-engine.fdb"
LOG="/tmp/fc-serve-triggen-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T (ID INTEGER, N INTEGER, S VARCHAR(20));
CREATE TABLE U (ID INTEGER, N INTEGER);
CREATE TABLE V (ID INTEGER, N INTEGER);
CREATE SEQUENCE G;
CREATE SEQUENCE G10 START WITH 100 INCREMENT BY 10;
-- the refused trigger's own sequence: the ENGINE side of a refusal
-- check RUNS the statement, and a generator draw is NOT transactional -
-- so it must not share a sequence with anything this gate compares
CREATE SEQUENCE GV;
CREATE EXCEPTION E_BAD 'bad row';
COMMIT;
SET TERM ^;
CREATE TRIGGER TBI FOR T ACTIVE BEFORE INSERT POSITION 0 AS
BEGIN
  IF (NEW.ID IS NULL) THEN NEW.ID = GEN_ID(G, 1);
  NEW.N = NEXT VALUE FOR G10;
END^
CREATE TRIGGER TBU FOR T ACTIVE BEFORE UPDATE POSITION 0 AS
BEGIN
  NEW.N = GEN_ID(G, 5);
END^
CREATE TRIGGER UBI FOR U ACTIVE BEFORE INSERT POSITION 0 AS
BEGIN
  NEW.ID = GEN_ID(G, 1);
  IF (NEW.N > 100) THEN EXCEPTION E_BAD;
END^
-- the refused shape: the drawn value decides a later branch
CREATE TRIGGER VBI FOR V ACTIVE BEFORE INSERT POSITION 0 AS
BEGIN
  NEW.ID = GEN_ID(GV, 1);
  IF (NEW.ID > 100) THEN NEW.N = 1;
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
both() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
refuses() {
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

# ---- the draw itself ----------------------------------------------------
both "an INSERT draws through the trigger" \
  "INSERT INTO T (S) VALUES ('a'); COMMIT; SELECT ID, N, S FROM T ORDER BY ID;"
both "...and the next one takes the next value" \
  "INSERT INTO T (S) VALUES ('b'); COMMIT; SELECT ID, N, S FROM T ORDER BY ID;"
both "NEXT VALUE FOR advances by the SEQUENCE's own increment" \
  "SELECT GEN_ID(G10, 0) A, GEN_ID(G, 0) B FROM RDB\$DATABASE;"
both "a CONDITIONAL draw consumes nothing when its branch is skipped" \
  "INSERT INTO T (ID, S) VALUES (50, 'c'); COMMIT;
   SELECT ID, N, S FROM T ORDER BY ID;
   SELECT GEN_ID(G, 0) A, GEN_ID(G10, 0) B FROM RDB\$DATABASE;"
both "a BEFORE UPDATE trigger draws too" \
  "UPDATE T SET S = 'z' WHERE ID = 50; COMMIT;
   SELECT ID, N, S FROM T ORDER BY ID; SELECT GEN_ID(G, 0) A FROM RDB\$DATABASE;"
both "several rows in one statement draw once each" \
  "INSERT INTO T (S) SELECT 'm' FROM RDB\$TYPES WHERE RDB\$TYPE < 3; COMMIT;
   SELECT COUNT(*) C, COUNT(DISTINCT ID) D FROM T;"

# ---- a RAISE after a draw still consumes it -----------------------------
# the generator is NOT transactional: the engine's own row-rejecting
# insert has already moved it when it raises
both "a body that RAISES after drawing still consumed the value" \
  "INSERT INTO U (N) VALUES (200); COMMIT;
   SELECT COUNT(*) C FROM U; SELECT GEN_ID(G, 0) A FROM RDB\$DATABASE;"
both "...and the row that follows takes the NEXT one" \
  "INSERT INTO U (N) VALUES (1); COMMIT; SELECT ID, N FROM U ORDER BY ID;"

# ---- what refuses -------------------------------------------------------
refuses "a body whose CONTROL FLOW reads a drawn value" \
  "INSERT INTO V (N) VALUES (7);"

# ---- the BLR this server writes -----------------------------------------
# `CREATE TRIGGER` from fire-crab's own DDL, read back by the ENGINE
both "fire-crab CREATEs a drawing trigger, and the engine reads its BLR" \
  "CREATE TABLE W (ID INTEGER, N INTEGER); COMMIT;"
fc_ddl="SET TERM ^;
CREATE TRIGGER WBI FOR W ACTIVE BEFORE INSERT POSITION 0 AS
BEGIN
  NEW.ID = GEN_ID(G, 3);
  NEW.N = NEXT VALUE FOR G10;
END^
SET TERM ;^
COMMIT;"
printf '%s\n' "$fc_ddl" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
printf '%s\n' "$fc_ddl" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
blr_q="SET BLOB ALL; SET LIST ON; SELECT RDB\$TRIGGER_BLR FROM RDB\$TRIGGERS WHERE RDB\$TRIGGER_NAME = 'WBI';"
e=$(printf '%s\n' "$blr_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | grep -a "blr_" | norm)
c=$(printf '%s\n' "$blr_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | grep -a "blr_" | norm)
check "the BLR is byte-identical (blr_gen_id / blr_gen_id2)" "$c" "$e"
case "$c" in *"blr_gen_id2"*) echo "OK   ...and NEXT VALUE FOR really is the other verb"; ran=$((ran+1));;
  *) echo "DIFF NEXT VALUE FOR did not compile to blr_gen_id2: [$c]"; fail=1; ran=$((ran+1));; esac
both "and the trigger fire-crab wrote then FIRES on both" \
  "INSERT INTO W (N) VALUES (0); COMMIT; SELECT ID, N FROM W;"

# ---- the engine still reads fire-crab's file ----------------------------
eng_q="SET LIST ON; SELECT ID, N, S FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
