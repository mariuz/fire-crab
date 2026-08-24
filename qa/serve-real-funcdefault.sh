#!/bin/bash
# DEFAULT parameters on a stored FUNCTION - the same literal defaults the
# procedure slice added, now on RDB$FUNCTION_ARGUMENTS. dsql parses the
# default in the function's input list, fn_arg_of stores RDB$DEFAULT_SOURCE
# (verbatim form) and RDB$DEFAULT_VALUE (byte-exact, the column-default
# helpers), load_function decodes it into the parameter, user_function_sigs
# reports the REQUIRED arity (inputs without a default) so a select-list
# call may omit the defaulted tail, and with_proc_defaults fills it at run.
#
# Covered (fc vs the live engine, and the ENGINE runs fc's file): the
# stored RDB$DEFAULT_SOURCE (DEFAULT / = / string); a call omitting the
# default, providing it, and two trailing defaults omitted independently;
# the byte-exact "Parameter <n> has no default value" vector for a missing
# required argument and "wrong number of arguments" for too many.
#
# Boundary (recorded, shared with procedures): a non-literal / context
# default and an un-encodable (> i32) default refuse at CREATE; the
# RDB$DEFAULT_SOURCE is canonicalised (re-rendered), not verbatim.
#
#   qa/serve-real-funcdefault.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4945}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-fdef-crab.fdb"; B="$D/fc-fdef-engine.fdb"
LOG="/tmp/fc-serve-fdef-$PORT.log"
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
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//; /-At function/d' | tr '\n' '|'; }

read -r -d '' SETUP <<'SQL'
SET TERM ^;
CREATE FUNCTION FA(B INTEGER, A INTEGER DEFAULT 5) RETURNS INTEGER AS BEGIN RETURN A+B; END^
CREATE FUNCTION FB(B INTEGER, A INTEGER = 7) RETURNS INTEGER AS BEGIN RETURN A+B; END^
CREATE FUNCTION FS(B INTEGER, A VARCHAR(5) DEFAULT 'hi') RETURNS VARCHAR(10) AS BEGIN RETURN A; END^
CREATE FUNCTION F2(B INTEGER, A INTEGER DEFAULT 1, C INTEGER DEFAULT 2) RETURNS INTEGER AS BEGIN RETURN A+C+B; END^
SET TERM ;^
COMMIT;
SQL
e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" <<< "$SETUP" 2>&1 | norm)
c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<< "$SETUP" 2>&1 | norm)
check "the defaulted functions build on both" "$c" "$e"

cat > "$D/src.sql" <<'SQL'
SET LIST ON;
SELECT RDB$FUNCTION_NAME F, CAST(RDB$DEFAULT_SOURCE AS VARCHAR(15)) S
FROM RDB$FUNCTION_ARGUMENTS WHERE RDB$DEFAULT_SOURCE IS NOT NULL
AND RDB$FUNCTION_NAME IN ('FA','FB','FS','F2') ORDER BY 1, RDB$ARGUMENT_POSITION;
SQL
srcs() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/src.sql" 2>&1 | norm; }
check "RDB\$FUNCTION_ARGUMENTS default source (DEFAULT / = / string)" \
    "$(srcs "127.0.0.1/$PORT:$A")" "$(srcs "127.0.0.1/$REAL:$B")"

cat > "$D/q.sql" <<'SQL'
SET LIST ON;
SELECT FA(10) R FROM RDB$DATABASE;
SELECT FA(10, 20) R FROM RDB$DATABASE;
SELECT FB(10) R FROM RDB$DATABASE;
SELECT FS(0) R FROM RDB$DATABASE;
SELECT F2(100) R FROM RDB$DATABASE;
SELECT F2(100, 10) R FROM RDB$DATABASE;
SELECT F2(100, 10, 20) R FROM RDB$DATABASE;
SQL
rows_of() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/q.sql" 2>&1 | norm; }
check "omitted defaults filled; provided used; string / multi-default" \
    "$(rows_of "127.0.0.1/$PORT:$A")" "$(rows_of "127.0.0.1/$REAL:$B")"

cat > "$D/m.sql" <<'SQL'
SET LIST ON;
SELECT FA() R FROM RDB$DATABASE;
SELECT FA(1, 2, 3) R FROM RDB$DATABASE;
SQL
mm() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/m.sql" 2>&1 | norm; }
check "byte-exact arity vectors: too few (no-default) and too many" \
    "$(mm "127.0.0.1/$PORT:$A")" "$(mm "127.0.0.1/$REAL:$B")"

# A parameter DEFAULT belongs on a package HEADER declaration, never in the
# package BODY of a previously declared member: the engine rejects a body
# default with the DYN dyn_defvaldecl_package_{func,proc} vector. fc raises
# the SAME byte-exact error - for an encodable literal and for one it cannot
# encode (a > i32 integer, which must still be refused, not silently
# dropped) - on both a function and a procedure member.
pkgbody() {
    cat > "$D/pb.sql" <<SQL
SET TERM ^;
CREATE PACKAGE $1 AS BEGIN $2 END^
CREATE PACKAGE BODY $1 AS BEGIN $3 END^
SET TERM ;^
COMMIT;
SQL
    "$ISQL" -q -user "$U" -pas "$P" "$4" -i "$D/pb.sql" 2>&1 | norm
}
check "package FUNCTION body default (encodable) -> byte-exact -607" \
    "$(pkgbody BF 'FUNCTION F(A INTEGER, B INTEGER) RETURNS INTEGER;' 'FUNCTION F(A INTEGER, B INTEGER DEFAULT 9) RETURNS INTEGER AS BEGIN RETURN A; END' "127.0.0.1/$PORT:$A")" \
    "$(pkgbody BF 'FUNCTION F(A INTEGER, B INTEGER) RETURNS INTEGER;' 'FUNCTION F(A INTEGER, B INTEGER DEFAULT 9) RETURNS INTEGER AS BEGIN RETURN A; END' "127.0.0.1/$REAL:$B")"
check "package FUNCTION body default (> i32, un-encodable) -> byte-exact -607" \
    "$(pkgbody BG 'FUNCTION F(A INTEGER, B INTEGER) RETURNS INTEGER;' 'FUNCTION F(A INTEGER, B INTEGER DEFAULT 9999999999) RETURNS INTEGER AS BEGIN RETURN A; END' "127.0.0.1/$PORT:$A")" \
    "$(pkgbody BG 'FUNCTION F(A INTEGER, B INTEGER) RETURNS INTEGER;' 'FUNCTION F(A INTEGER, B INTEGER DEFAULT 9999999999) RETURNS INTEGER AS BEGIN RETURN A; END' "127.0.0.1/$REAL:$B")"
check "package PROCEDURE body default -> byte-exact -607" \
    "$(pkgbody BH 'PROCEDURE P(A INTEGER, B INTEGER) RETURNS (R INTEGER);' 'PROCEDURE P(A INTEGER, B INTEGER DEFAULT 8) RETURNS (R INTEGER) AS BEGIN R=A; SUSPEND; END' "127.0.0.1/$PORT:$A")" \
    "$(pkgbody BH 'PROCEDURE P(A INTEGER, B INTEGER) RETURNS (R INTEGER);' 'PROCEDURE P(A INTEGER, B INTEGER DEFAULT 8) RETURNS (R INTEGER) AS BEGIN R=A; SUSPEND; END' "127.0.0.1/$REAL:$B")"

# Boundary (recorded): a packaged routine's HEADER declaration may carry a
# default on the live engine (its canonical place), but fc neither stores
# nor preserves it across the body re-write, so it REFUSES the header create
# rather than accept a defaultless catalog. A PSQL body call that OMITS a
# defaulted function's trailing argument also refuses (the select-list call
# fills it) - both await a dedicated packaged/body-fill slice.
ran=$((ran + 1))
hdr=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" <<'SQL' 2>&1
SET TERM ^;
CREATE PACKAGE HDRD AS BEGIN FUNCTION F(A INTEGER, B INTEGER DEFAULT 10) RETURNS INTEGER; END^
SET TERM ;^
COMMIT;
SELECT RDB$PACKAGE_NAME FROM RDB$PACKAGES WHERE RDB$PACKAGE_NAME = 'HDRD';
SQL
)
if echo "$hdr" | grep -q "HDRD" ; then
    echo "DIFF fc stored a header-default package it cannot honour: $hdr"; fail=1
else
    echo "OK   fc refuses a packaged header default (no bogus catalog)"; fi

# the ENGINE runs fc's stored function defaults
kill $srv 2>/dev/null; wait $srv 2>/dev/null
efile=$("$ISQL" -q -user "$U" -pas "$P" "$B" -i "$D/q.sql" 2>&1 | norm)
cfile=$("$ISQL" -q -user "$U" -pas "$P" "$A" -i "$D/q.sql" 2>&1 | norm)
check "the ENGINE runs fc's stored defaulted functions" "$cfile" "$efile"
ran=$((ran + 1))
if echo "$cfile" | grep -q "R 15"; then echo "OK   FA(10)=15 (default filled) via fc's file"; else
    echo "DIFF the default was not filled: [$cfile]"; fail=1; fi

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
