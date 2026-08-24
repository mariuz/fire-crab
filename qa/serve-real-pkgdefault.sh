#!/bin/bash
# A parameter DEFAULT on a packaged routine's HEADER declaration - the
# canonical place the engine keeps it. fc now stores it (create_package
# writes RDB$FUNCTION_ARGUMENTS / RDB$PROCEDURE_PARAMETERS RDB$DEFAULT_*),
# PRESERVES it across the body create (create_package_body re-writes each
# member's parameter rows and carries the header's defaults onto the fresh
# rows via carried_member_defaults), and FILLS it at an external call - a
# packaged function in a select list or a body, a packaged procedure via
# EXECUTE PROCEDURE - reusing the same catalog-driven, package-aware
# machinery a plain routine uses (user_function_sigs / load_procedure /
# the exe default fill). An un-encodable (> i32) header default refuses at
# CREATE, as on the standalone paths.
#
# Covered (fc vs the live engine, and the ENGINE runs fc's file): the
# header default surviving in BOTH catalogs; a function select-list call
# and a string default; a procedure EXECUTE PROCEDURE call; provided and
# omitted; the un-encodable refusal; gfix.
#
# Boundary (recorded): a package body member's UNQUALIFIED SIBLING call
# cannot omit the sibling's defaulted tail - the header's required arity is
# not reliably visible at body-compile (fc's plan-time catalog is stale for
# same-connection DDL, and a header-only declaration has no BLR to key on),
# so the sibling channel stays exact-arity and such a body refuses. A body
# that re-specifies a default gets the byte-exact -607 (serve-real-funcdefault).
#
#   qa/serve-real-pkgdefault.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4944}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-pkgdef-crab.fdb"; B="$D/fc-pkgdef-engine.fdb"
LOG="/tmp/fc-serve-pkgdef-$PORT.log"
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
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE PACKAGE PK AS BEGIN
  FUNCTION PF(A INTEGER, B INTEGER DEFAULT 9) RETURNS INTEGER;
  FUNCTION PS(A INTEGER, B VARCHAR(5) DEFAULT 'hi') RETURNS VARCHAR(10);
  PROCEDURE PP(A INTEGER, B INTEGER DEFAULT 7) RETURNS (R INTEGER);
END^
CREATE PACKAGE BODY PK AS BEGIN
  FUNCTION PF(A INTEGER, B INTEGER) RETURNS INTEGER AS BEGIN RETURN A+B; END
  FUNCTION PS(A INTEGER, B VARCHAR(5)) RETURNS VARCHAR(10) AS BEGIN RETURN B; END
  PROCEDURE PP(A INTEGER, B INTEGER) RETURNS (R INTEGER) AS BEGIN R = A+B; SUSPEND; END
END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the header-defaulted package (fn + proc) builds on both" "$c" "$e"

cat > "$D/cat.sql" <<'SQL'
SET LIST ON;
SELECT RDB$FUNCTION_NAME||'.'||RDB$ARGUMENT_NAME NM, CAST(RDB$DEFAULT_SOURCE AS VARCHAR(12)) S
FROM RDB$FUNCTION_ARGUMENTS WHERE RDB$PACKAGE_NAME='PK' AND RDB$DEFAULT_SOURCE IS NOT NULL ORDER BY 1;
SELECT RDB$PROCEDURE_NAME||'.'||RDB$PARAMETER_NAME NM, CAST(RDB$DEFAULT_SOURCE AS VARCHAR(12)) S
FROM RDB$PROCEDURE_PARAMETERS WHERE RDB$PACKAGE_NAME='PK' AND RDB$DEFAULT_SOURCE IS NOT NULL ORDER BY 1;
SQL
catof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/cat.sql" 2>&1 | norm; }
check "the header defaults survive the body create (fn + proc catalogs)" \
    "$(catof "127.0.0.1/$PORT:$A")" "$(catof "127.0.0.1/$REAL:$B")"

cat > "$D/call.sql" <<'SQL'
SET LIST ON;
SELECT PK.PF(1) R FROM RDB$DATABASE;
SELECT PK.PF(1, 100) R FROM RDB$DATABASE;
SELECT PK.PS(0) R FROM RDB$DATABASE;
SELECT R FROM PK.PP(1);
SELECT R FROM PK.PP(1, 50);
SQL
callof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/call.sql" 2>&1 | norm; }
check "external calls fill the header default (fn select-list/string, EXECUTE PROCEDURE)" \
    "$(callof "127.0.0.1/$PORT:$A")" "$(callof "127.0.0.1/$REAL:$B")"

# un-encodable header default refuses on fc (no bogus catalog); engine accepts
ran=$((ran + 1))
bad=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<'SQL' 2>&1
SET TERM ^;
CREATE PACKAGE BIG AS BEGIN FUNCTION F(A INTEGER, B INTEGER DEFAULT 9999999999) RETURNS INTEGER; END^
SET TERM ;^
COMMIT;
SELECT RDB$PACKAGE_NAME FROM RDB$PACKAGES WHERE RDB$PACKAGE_NAME='BIG';
SQL
)
if echo "$bad" | grep -q "BIG"; then echo "DIFF fc stored a >i32 header-default package: $bad"; fail=1;
else echo "OK   fc refuses a > i32 header default (no bogus catalog)"; fi

# the ENGINE runs fc's stored header-default package
kill $srv 2>/dev/null; wait $srv 2>/dev/null
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/call.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/call.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored header-default package" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 10"; then echo "OK   PK.PF(1)=10 (header default 9 filled) via fc's file"; else
    echo "DIFF the header default was not filled: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
