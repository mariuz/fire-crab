#!/bin/bash
# `SET TRANSACTION` - THE STATEMENT FORM OF THE ISOLATION.
#
# qa/serve-real-snapshot.sh proves snapshot isolation through the TPB
# (isc_tpb_concurrency, driven by a C client). This gate is the OTHER
# DOOR: the SQL statement. They were not the same door - the TPB path
# read its isolation and the statement path read nothing at all, so
# `SET TRANSACTION SNAPSHOT` opened a READ COMMITTED transaction and
# every read in it saw other connections' commits as they landed. A
# gate saying "snapshot isolation works" was true one way and false the
# other.
#
# The laws, each probed against the engine first:
#
#   * `SET TRANSACTION SNAPSHOT`: a count repeated across another
#     connection's commit answers the SAME both times.
#   * `SET TRANSACTION READ COMMITTED`: it answers the new value.
#   * a BARE `SET TRANSACTION` is SNAPSHOT - the engine's default
#     isolation, not read committed.
#   * a PSQL BODY's read is the TRANSACTION's read: a trigger firing
#     inside a snapshot transaction counts what the snapshot sees, not
#     what is committed now. (That was the symptom this started from,
#     and it was never a body problem.)
#   * `READ ONLY` refuses a write, with the engine's own vector.
#
# TWO CONNECTIONS AND A CLOCK: the second connection must commit
# BETWEEN the first's two reads, so this gate sleeps and is therefore
# in qa/sweep.sh's SERIAL list - on a loaded box the sleeps stretch and
# what it would report is the load.
#
#   qa/serve-real-settransaction.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4995}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-settx-crab.fdb"
B="$D/fc-settx-engine.fdb"
LOG="/tmp/fc-serve-settx-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|$1|" > "$D/settx-$PORT.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE C (ID INTEGER);
CREATE TABLE T (ID INTEGER, N INTEGER);
CREATE TABLE L (ID INTEGER, N INTEGER);
COMMIT;
SET TERM ^ ;
CREATE TRIGGER T_BI FOR T BEFORE INSERT AS
DECLARE VARIABLE K INTEGER;
BEGIN
  SELECT COUNT(*) FROM C INTO :K;
  INSERT INTO L (ID, N) VALUES (NEW.ID, :K);
END^
SET TERM ; ^
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/settx-$PORT.sql" >/dev/null 2>&1
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/settx-$PORT.sql"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

# reset both files to ONE row in C, no log
reset() {
    for db in "$A" "$B"; do
        printf 'DELETE FROM C; DELETE FROM L; DELETE FROM T; COMMIT;\n INSERT INTO C VALUES (1); COMMIT;\n' \
            | "$ISQL" -q -user "$U" -pas "$P" "$db" >/dev/null 2>&1
    done
}
# <server-url> <the SET TRANSACTION statement> <tail statements>
race() {
    url="$1"; settx="$2"; tail_sql="$3"
    ( printf 'SET LIST ON;\n%s\nSELECT COUNT(*) AS FIRST FROM C;\n' "$settx"
      sleep 3
      printf '%s\n' "$tail_sql" ) | timeout 40 "$ISQL" -q -user "$U" -pas "$P" "$url" 2>&1 > "$D/race-$PORT.out" &
    racer=$!
    sleep 1
    printf 'INSERT INTO C VALUES (2);\nCOMMIT;\n' | timeout 20 "$ISQL" -q -user "$U" -pas "$P" "$url" >/dev/null 2>&1
    wait $racer 2>/dev/null
    norm < "$D/race-$PORT.out"
}
both_race() { # <label> <settx> <tail>
    reset
    e=$(race "127.0.0.1/$REAL:$B" "$2" "$3")
    reset
    c=$(race "127.0.0.1/$PORT:$A" "$2" "$3")
    check "$1" "$c" "$e"
}

tail_read="SELECT COUNT(*) AS N2 FROM C;
COMMIT;"
tail_body="SELECT COUNT(*) AS N2 FROM C;
INSERT INTO T VALUES (1, 0);
COMMIT;
SELECT N AS BODY_SAW FROM L;"

# ---- the isolation the statement names ---------------------------------
both_race "SNAPSHOT: the second read answers what the first did" \
    "SET TRANSACTION SNAPSHOT;" "$tail_read"
both_race "READ COMMITTED: the second read answers the new value" \
    "SET TRANSACTION READ COMMITTED;" "$tail_read"
both_race "a BARE SET TRANSACTION is SNAPSHOT, not read committed" \
    "SET TRANSACTION;" "$tail_read"
both_race "ISOLATION LEVEL spelt out, and READ WRITE with it" \
    "SET TRANSACTION READ WRITE WAIT ISOLATION LEVEL SNAPSHOT;" "$tail_read"

# ---- and a body's read is the transaction's read ------------------------
both_race "a PSQL BODY reads the SNAPSHOT its statement runs in" \
    "SET TRANSACTION SNAPSHOT;" "$tail_body"
both_race "...and the latest committed under READ COMMITTED" \
    "SET TRANSACTION READ COMMITTED;" "$tail_body"

# ---- READ ONLY ----------------------------------------------------------
reset
e=$(printf 'SET TRANSACTION READ ONLY;\nINSERT INTO C VALUES (9);\nCOMMIT;\n' \
    | timeout 20 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(printf 'SET TRANSACTION READ ONLY;\nINSERT INTO C VALUES (9);\nCOMMIT;\n' \
    | timeout 20 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "READ ONLY refuses the write, with the engine's vector" "$c" "$e"

# ---- the engine reads what fire-crab wrote -----------------------------
eng_q="SET LIST ON; SELECT COUNT(*) AS CN FROM C; SELECT ID, N FROM L ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

# ---- a clause this server cannot judge refuses --------------------------
ran=$((ran + 1))
r=$(printf 'SET TRANSACTION SNAPSHOT RESERVING C FOR PROTECTED WRITE;\nSELECT 1 FROM RDB$DATABASE;\n' \
    | timeout 20 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
case "$r" in
    *"Dynamic SQL Error"*) echo "OK   boundary: RESERVING is refused, not silently ignored" ;;
    *) echo "DIFF boundary MOVED: RESERVING"; echo "     [$r]"; fail=1 ;;
esac
echo "ran $ran checks"
exit $fail
