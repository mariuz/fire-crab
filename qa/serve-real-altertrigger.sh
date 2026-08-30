#!/bin/bash
# ALTER TRIGGER / DROP TRIGGER / CREATE OR ALTER TRIGGER / ALTER PROCEDURE /
# CREATE OR ALTER PROCEDURE - the DDL that edits what CREATE made. Probed:
# ALTER TRIGGER ACTIVE|INACTIVE and POSITION n edit the row in place; an
# ALTER with events or a body redefines the trigger (the stored relation,
# the unspoken attributes kept); CREATE OR ALTER TRIGGER on an existing
# name keeps its sequence and active flag unless the statement says;
# ALTER PROCEDURE replaces parameters and body keeping RDB$PROCEDURE_ID;
# CREATE OR ALTER PROCEDURE creates or does the same; DROP TRIGGER
# removes the row and the trigger's dependency rows; a missing name is
# the engine's "<VERB> failed / <object> not found" pair. Both databases
# engine-built; isql on both servers, the catalog compared line by line
# (blob ids differ by construction and are masked); the vectors raw.
# Boundary (recorded): fire-crab does not EXECUTE trigger BLR - its own
# DML on a user-trigger table refuses, so no DML fires these triggers
# here; the ENGINE reads fc's catalog at the end.
#
#   qa/serve-real-altertrigger.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4887}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-altertrigger-crab.fdb"
B="$D/fc-altertrigger-engine.fdb"
LOG="/tmp/fc-serve-altertrigger-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"
fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr-$(basename "$0" .sh)" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER);
SET TERM ^;
CREATE TRIGGER TR FOR T BEFORE INSERT POSITION 3 AS BEGIN NEW.N = 1; END^
CREATE PROCEDURE P (A INTEGER) RETURNS (X INTEGER) AS BEGIN X = A + 1; SUSPEND; END^
SET TERM ;^
COMMIT;
EOF
    chmod 666 "$1"
}
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | grep -v 'BLOB display' | sed 's/_SOURCE [0-9a-f]*:[0-9a-f]*$/_SOURCE <id>/' | tr '\n' '|'; }
script() { cat <<'SQL'
SET TERM ^;
ALTER TRIGGER TR INACTIVE^
ALTER TRIGGER TR POSITION 7^
COMMIT^
SET LIST ON^
SELECT RDB$TRIGGER_SEQUENCE, RDB$TRIGGER_INACTIVE, RDB$TRIGGER_TYPE FROM RDB$TRIGGERS WHERE RDB$TRIGGER_NAME = 'TR'^
CREATE OR ALTER TRIGGER TR FOR T BEFORE INSERT AS BEGIN NEW.N = 3; END^
COMMIT^
SELECT RDB$TRIGGER_SEQUENCE, RDB$TRIGGER_INACTIVE, RDB$TRIGGER_TYPE, RDB$TRIGGER_SOURCE FROM RDB$TRIGGERS WHERE RDB$TRIGGER_NAME = 'TR'^
ALTER TRIGGER TR ACTIVE^
ALTER TRIGGER TR BEFORE INSERT OR UPDATE POSITION 1 AS BEGIN NEW.N = 4; END^
COMMIT^
SELECT RDB$TRIGGER_SEQUENCE, RDB$TRIGGER_INACTIVE, RDB$TRIGGER_TYPE, RDB$TRIGGER_SOURCE FROM RDB$TRIGGERS WHERE RDB$TRIGGER_NAME = 'TR'^
SELECT COUNT(*) FROM RDB$DEPENDENCIES WHERE RDB$DEPENDENT_NAME = 'TR'^
CREATE OR ALTER TRIGGER TR2 FOR T BEFORE UPDATE POSITION 2 AS BEGIN NEW.N = 5; END^
COMMIT^
SELECT RDB$TRIGGER_NAME, RDB$TRIGGER_SEQUENCE, RDB$TRIGGER_INACTIVE, RDB$TRIGGER_TYPE FROM RDB$TRIGGERS WHERE RDB$RELATION_NAME = 'T' ORDER BY 1^
SET LIST OFF^
ALTER PROCEDURE P (A INTEGER, B INTEGER) RETURNS (X INTEGER, Y INTEGER) AS BEGIN X = A + B; Y = 0; SUSPEND; END^
CREATE OR ALTER PROCEDURE P2 RETURNS (X INTEGER) AS BEGIN X = 9; SUSPEND; END^
CREATE OR ALTER PROCEDURE P2 RETURNS (X INTEGER) AS BEGIN X = 10; SUSPEND; END^
COMMIT^
SELECT X, Y FROM P(1, 2)^
SELECT X FROM P2^
SET LIST ON^
SELECT RDB$PROCEDURE_NAME, RDB$PROCEDURE_ID, RDB$PROCEDURE_INPUTS, RDB$PROCEDURE_OUTPUTS, RDB$PROCEDURE_SOURCE FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_NAME IN ('P', 'P2') ORDER BY 1^
SELECT RDB$PROCEDURE_NAME, RDB$PARAMETER_NAME, RDB$PARAMETER_NUMBER, RDB$PARAMETER_TYPE FROM RDB$PROCEDURE_PARAMETERS WHERE RDB$PROCEDURE_NAME IN ('P', 'P2') ORDER BY 1, 4, 3^
SET LIST OFF^
DROP TRIGGER TR^
COMMIT^
SELECT COUNT(*) FROM RDB$TRIGGERS WHERE RDB$TRIGGER_NAME = 'TR'^
SELECT COUNT(*) FROM RDB$DEPENDENCIES WHERE RDB$DEPENDENT_NAME = 'TR'^
SQL
}
e=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "the DDL and the catalog through each server" "$c" "$e"
e=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$REAL:$B" "ALTER TRIGGER NOPE INACTIVE" "DROP TRIGGER NOPE" "ALTER PROCEDURE NOPE AS BEGIN END" "DROP PROCEDURE NOPE" 2>&1 | norm)
c=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "ALTER TRIGGER NOPE INACTIVE" "DROP TRIGGER NOPE" "ALTER PROCEDURE NOPE AS BEGIN END" "DROP PROCEDURE NOPE" 2>&1 | norm)
check "the missing-object vectors" "$c" "$e"
# the ENGINE reads fc's catalog: TR2 and the procedures as the engine left its own
script2() { cat <<'SQL'
SET LIST ON;
SELECT RDB$TRIGGER_NAME, RDB$TRIGGER_SEQUENCE, RDB$TRIGGER_INACTIVE, RDB$TRIGGER_TYPE, RDB$TRIGGER_SOURCE FROM RDB$TRIGGERS WHERE RDB$RELATION_NAME = 'T' ORDER BY 1;
SELECT RDB$PROCEDURE_NAME, RDB$PROCEDURE_ID, RDB$PROCEDURE_INPUTS, RDB$PROCEDURE_OUTPUTS FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_NAME IN ('P', 'P2') ORDER BY 1;
SET LIST OFF;
SELECT X, Y FROM P(5, 6);
SELECT X FROM P2;
SQL
}
e=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's catalog and runs fc's procedures" "$c" "$e"
echo "ran $ran checks"
exit $fail
