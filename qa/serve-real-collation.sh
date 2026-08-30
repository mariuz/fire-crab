#!/bin/bash
# CREATE / DROP COLLATION - a user collation, the RDB$COLLATIONS catalog.
# Probed: the id counts DOWN from 126 per charset (126, 125, 124 ...); the
# attributes bitmask is PAD(1, the default) | CASE INSENSITIVE(2) | ACCENT
# INSENSITIVE(4); an ICU (UTF8) collation carries the base collation's
# COLL-VERSION/ICU-VERSION in RDB$SPECIFIC_ATTRIBUTES (copied verbatim); a
# non-ICU (single-byte) base has none and takes only PAD / NO PAD. Both
# databases engine-built; isql on both servers, the catalog (the specific
# attributes compared as text - the blob id is an internal record number) and
# the vectors compared; the ENGINE reads fc's collations and gfix validates.
# Boundaries (recorded): CASE / ACCENT INSENSITIVE on a non-ICU base is
# "Invalid collation attributes" (matched); FROM EXTERNAL (a collation
# module) refuses; and this server keys BINARY, so a CI/AI collation orders
# as its base does - the catalog is faithful, the ordering is not.
#
#   qa/serve-real-collation.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4896}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-collation-crab.fdb"; B="$D/fc-collation-engine.fdb"
LOG="/tmp/fc-serve-collation-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"; fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr-$(basename "$0" .sh)" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
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
script() { cat <<'SQL'
CREATE COLLATION UCI FOR UTF8 FROM UNICODE CASE INSENSITIVE;
CREATE COLLATION UCIAI FOR UTF8 FROM UNICODE CASE INSENSITIVE ACCENT INSENSITIVE;
CREATE COLLATION U3 FOR UTF8 FROM UNICODE;
CREATE COLLATION UDROP FOR UTF8 FROM UNICODE CASE INSENSITIVE;
CREATE COLLATION WPAD FOR WIN1252 FROM WIN1252 NO PAD;
CREATE COLLATION IPAD FOR ISO8859_1 FROM ISO8859_1 PAD SPACE;
COMMIT;
DROP COLLATION UDROP;
COMMIT;
SET LIST ON;
SELECT RDB$COLLATION_NAME AS NM, RDB$COLLATION_ID AS CID, RDB$CHARACTER_SET_ID AS CS, RDB$COLLATION_ATTRIBUTES AS ATTR, RDB$BASE_COLLATION_NAME AS BASE, CAST(RDB$SPECIFIC_ATTRIBUTES AS VARCHAR(80)) AS SPEC, RDB$OWNER_NAME AS OWN, RDB$SYSTEM_FLAG AS SF FROM RDB$COLLATIONS WHERE RDB$SYSTEM_FLAG = 0 ORDER BY RDB$CHARACTER_SET_ID, RDB$COLLATION_ID;
SQL
}
e=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "CREATE / DROP COLLATION and the RDB\$COLLATIONS catalog (id, attributes, specific)" "$c" "$e"
e=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$REAL:$B" "CREATE COLLATION UCI FOR UTF8 FROM UNICODE" "DROP COLLATION NOPE" "CREATE COLLATION BAD FOR WIN1252 FROM WIN1252 CASE INSENSITIVE" 2>&1 | norm)
c=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "CREATE COLLATION UCI FOR UTF8 FROM UNICODE" "DROP COLLATION NOPE" "CREATE COLLATION BAD FOR WIN1252 FROM WIN1252 CASE INSENSITIVE" 2>&1 | norm)
check "the duplicate / missing / invalid-attribute vectors" "$c" "$e"
# Boundary: FROM EXTERNAL (a collation module) refuses
cb=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "CREATE COLLATION EXT FOR UTF8 FROM EXTERNAL ('x')" 2>&1 | norm)
ran=$((ran + 1))
if [ "${cb#*gds}" != "$cb" ]; then echo "OK   boundary: CREATE COLLATION FROM EXTERNAL refuses"
else echo "DIFF boundary MOVED: FROM EXTERNAL"; echo "     fc: $cb"; fail=1; fi
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
rq="SET LIST ON; SELECT RDB\$COLLATION_NAME AS NM, RDB\$COLLATION_ID AS CID, RDB\$COLLATION_ATTRIBUTES AS ATTR, CAST(RDB\$SPECIFIC_ATTRIBUTES AS VARCHAR(80)) AS SPEC FROM RDB\$COLLATIONS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY RDB\$CHARACTER_SET_ID, RDB\$COLLATION_ID;"
e=$(printf '%s\n' "$rq" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$rq" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's collations" "$c" "$e"
echo "ran $ran checks"
exit $fail
