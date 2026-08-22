#!/bin/bash
# CREATE / DROP PACKAGE (the header). A package header is an RDB$PACKAGES row
# (the BEGIN..END source, no body, VALID_BODY_FLAG null) plus a DECLARATION
# row per member - RDB$PROCEDURES / RDB$FUNCTIONS tagged with the package, no
# blr/type/valid, their parameters over auto-domains. Probed: the member ids
# come from the procedure/function generators; a member declaration has no
# security class. Both databases engine-built; isql on both servers, the
# catalog compared (the header source as text) and the vectors; the ENGINE
# reads fc's package and gfix validates the file.
# Boundary (recorded): CREATE PACKAGE BODY (the implementations, member BLR)
# is not taken here and refuses - a later slice.
#
#   qa/serve-real-package.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4897}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-package-crab.fdb"; B="$D/fc-package-engine.fdb"
LOG="/tmp/fc-serve-package-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"; fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
cat > "$D/pkg-script.sql" <<'SQL'
SET TERM ^;
CREATE PACKAGE PKG AS BEGIN PROCEDURE PP (A INTEGER) RETURNS (B INTEGER); FUNCTION FF (A INTEGER) RETURNS INTEGER; PROCEDURE P2 (X VARCHAR(5)); END^
CREATE PACKAGE PKG2 AS BEGIN FUNCTION G (N BIGINT) RETURNS BIGINT; END^
SET TERM ;^
COMMIT;
DROP PACKAGE PKG2;
COMMIT;
SET LIST ON;
SELECT RDB$PACKAGE_NAME AS NM, CAST(RDB$PACKAGE_HEADER_SOURCE AS VARCHAR(250)) AS HDR, RDB$VALID_BODY_FLAG AS VB, RDB$OWNER_NAME AS OWN FROM RDB$PACKAGES WHERE RDB$SYSTEM_FLAG = 0 ORDER BY 1;
SELECT RDB$PROCEDURE_NAME AS PR, RDB$PACKAGE_NAME AS PKG, RDB$PROCEDURE_INPUTS AS I, RDB$PROCEDURE_OUTPUTS AS O, RDB$PROCEDURE_TYPE AS T, RDB$VALID_BLR AS VB, RDB$PRIVATE_FLAG AS PV FROM RDB$PROCEDURES WHERE RDB$PACKAGE_NAME IS NOT NULL AND RDB$SYSTEM_FLAG = 0 ORDER BY 1;
SELECT RDB$FUNCTION_NAME AS FN, RDB$PACKAGE_NAME AS PKG, RDB$RETURN_ARGUMENT AS R, RDB$VALID_BLR AS VB, RDB$PRIVATE_FLAG AS PV FROM RDB$FUNCTIONS WHERE RDB$PACKAGE_NAME IS NOT NULL AND RDB$SYSTEM_FLAG = 0 ORDER BY 1;
SELECT pp.RDB$PROCEDURE_NAME AS PR, pp.RDB$PARAMETER_NAME AS PN, pp.RDB$PARAMETER_TYPE AS TY, f.RDB$FIELD_TYPE AS FT, f.RDB$CHARACTER_LENGTH AS CL FROM RDB$PROCEDURE_PARAMETERS pp JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = pp.RDB$FIELD_SOURCE WHERE pp.RDB$PACKAGE_NAME = 'PKG' ORDER BY 1, 3, pp.RDB$PARAMETER_NUMBER;
SELECT a.RDB$FUNCTION_NAME AS FN, a.RDB$ARGUMENT_POSITION AS POS, a.RDB$ARGUMENT_NAME AS AN, f.RDB$FIELD_TYPE AS FT FROM RDB$FUNCTION_ARGUMENTS a JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = a.RDB$FIELD_SOURCE WHERE a.RDB$PACKAGE_NAME = 'PKG' ORDER BY 1, 2;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/pkg-script.sql" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/pkg-script.sql" 2>&1 | norm)
check "CREATE / DROP PACKAGE header, members and parameters" "$c" "$e"
e=$("$D/sqlerr" "127.0.0.1/$REAL:$B" "CREATE PACKAGE PKG AS BEGIN PROCEDURE X (A INTEGER); END" "DROP PACKAGE NOPE" 2>&1 | norm)
c=$("$D/sqlerr" "127.0.0.1/$PORT:$A" "CREATE PACKAGE PKG AS BEGIN PROCEDURE X (A INTEGER); END" "DROP PACKAGE NOPE" 2>&1 | norm)
check "the duplicate / missing PACKAGE vectors" "$c" "$e"
# Boundary: CREATE PACKAGE BODY is not taken here
cb=$("$D/sqlerr" "127.0.0.1/$PORT:$A" "CREATE PACKAGE BODY PKG AS BEGIN PROCEDURE PP (A INTEGER) RETURNS (B INTEGER) AS BEGIN B = A; SUSPEND; END FUNCTION FF (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A; END PROCEDURE P2 (X VARCHAR(5)) AS BEGIN EXIT; END END" 2>&1 | norm)
ran=$((ran + 1))
if [ "${cb#*gds}" != "$cb" ]; then echo "OK   boundary: CREATE PACKAGE BODY refuses (the implementations, a later slice)"
else echo "DIFF boundary MOVED: PACKAGE BODY"; echo "     fc: $cb"; fail=1; fi
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
# the ENGINE reads fc's package members
rq="SET LIST ON; SELECT RDB\$PROCEDURE_NAME AS PR, RDB\$PACKAGE_NAME AS PKG, RDB\$PROCEDURE_INPUTS AS I FROM RDB\$PROCEDURES WHERE RDB\$PACKAGE_NAME = 'PKG' ORDER BY 1; SELECT RDB\$FUNCTION_NAME AS FN FROM RDB\$FUNCTIONS WHERE RDB\$PACKAGE_NAME = 'PKG';"
e=$(printf '%s\n' "$rq" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$rq" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's package members" "$c" "$e"
echo "ran $ran checks"
exit $fail
