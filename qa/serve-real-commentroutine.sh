#!/bin/bash
# COMMENT ON PROCEDURE / FUNCTION. fc's COMMENT ON handled TABLE / COLUMN /
# INDEX / SEQUENCE / EXCEPTION / ROLE / DOMAIN / DATABASE but not a
# procedure or a function, so both refused while the engine accepts them.
# The planner's kind list and the ods CommentTarget gain Procedure /
# Function, writing (or clearing) the PLAIN routine's RDB$DESCRIPTION - the
# plain row only (RDB$PACKAGE_NAME NULL), never a packaged member of the
# same bare name.
#
# Covered (fc vs the live engine): set a comment on a procedure and a
# function and read it back through CAST(RDB$DESCRIPTION AS VARCHAR); clear
# it with IS NULL; the ENGINE reads the description from fc's file; and it
# survives a gbak backup+restore.
#
# Boundary (recorded, shared by ALL comment targets): the not-found vector
# for a missing object is fc's generic refusal, not the engine's byte-exact
# "COMMENT ON @1 failed / <kind> not found" - pre-existing, not
# routine-specific.
#
#   qa/serve-real-commentroutine.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4943}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-cmtrt-crab.fdb"; B="$D/fc-cmtrt-engine.fdb"
LOG="/tmp/fc-serve-cmtrt-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/cmtrt.fbk" "$D/cmtrt-r.fdb"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE PROCEDURE P(A INTEGER) RETURNS (R INTEGER) AS BEGIN R=A; SUSPEND; END^
CREATE FUNCTION F(A INTEGER) RETURNS INTEGER AS BEGIN RETURN A; END^
SET TERM ;^
COMMENT ON PROCEDURE P IS 'a stored procedure';
COMMENT ON FUNCTION F IS 'a scalar function';
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "COMMENT ON PROCEDURE / FUNCTION build on both" "$c" "$e"

cat > "$D/q-$PORT.sql" <<'SQL'
SET LIST ON;
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(60)) D FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_NAME='P';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(60)) D FROM RDB$FUNCTIONS WHERE RDB$FUNCTION_NAME='F';
SQL
rd() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q-$PORT.sql" 2>&1 | norm; }
check "the descriptions read back" "$(rd "127.0.0.1/$PORT:$A")" "$(rd "127.0.0.1/$REAL:$B")"

# clear the procedure comment with IS NULL
read -r -d '' CLR <<'SQL'
COMMENT ON PROCEDURE P IS NULL;
COMMIT;
SQL
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$CLR" >/dev/null 2>&1
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$CLR" >/dev/null 2>&1
cat > "$D/q2.sql" <<'SQL'
SET LIST ON;
SELECT COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)), '<null>') D FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_NAME='P';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(60)) D FROM RDB$FUNCTIONS WHERE RDB$FUNCTION_NAME='F';
SQL
rd2() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q2.sql" 2>&1 | norm; }
check "IS NULL clears the procedure comment; function keeps its own" \
    "$(rd2 "127.0.0.1/$PORT:$A")" "$(rd2 "127.0.0.1/$REAL:$B")"

# the ENGINE reads fc's file, and a gbak round-trip preserves the function comment
kill $srv 2>/dev/null; wait $srv 2>/dev/null
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/q2.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/q2.sql" 2>&1 | norm)
check "the ENGINE reads the descriptions from fc's file" "$cfile" "$efile"

"$GBAK" -b -user "$U" -pas "$P" "$A" "$D/cmtrt.fbk" >/dev/null 2>&1
rm -f "$D/cmtrt-r.fdb"
"$GBAK" -c -user "$U" -pas "$P" "$D/cmtrt.fbk" "$D/cmtrt-r.fdb" >/dev/null 2>&1
ran=$((ran + 1))
rr=$("$ISQL" -q -user "$U" -pas "$P" "$D/cmtrt-r.fdb" -i "$D/q2.sql" 2>&1 | norm)
if echo "$rr" | grep -q "a scalar function"; then echo "OK   the function comment survives a gbak round-trip"; else
    echo "DIFF gbak lost the comment: [$rr]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
