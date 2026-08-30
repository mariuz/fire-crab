#!/bin/bash
# CREATE / ALTER / DROP MAPPING - a local (database) name mapping, the
# RDB$AUTH_MAPPING catalog. Probed: USING PLUGIN <p>, FROM (ANY <t> | USER /
# ROLE / GROUP <n>) TO (USER | ROLE) [<n>] each write their columns
# (RDB$MAP_USING 'P', RDB$MAP_FROM '*' for ANY, RDB$MAP_TO_TYPE 0=USER/1=ROLE,
# RDB$MAP_TO null when omitted); ALTER replaces the row in place; DROP removes
# it. The vectors: a duplicate CREATE is "unsuccessful metadata update /
# MAPPING @1 failed CREATE / Map @1 already exists", a missing DROP/ALTER the
# same shape with the not-found reason. Both databases engine-built; isql on
# both servers, the catalog and vectors compared; the ENGINE reads fc's
# mappings and gfix validates the file.
# Boundary (recorded): CREATE GLOBAL MAPPING lives in the security database,
# not this catalog, so fire-crab refuses it (the engine writes it elsewhere).
#
#   qa/serve-real-mapping.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4895}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-mapping-crab.fdb"; B="$D/fc-mapping-engine.fdb"
LOG="/tmp/fc-serve-mapping-$PORT.log"
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
CREATE MAPPING M_USER USING PLUGIN SRP FROM USER SYSDBA TO USER BOSS;
CREATE MAPPING M_ANY USING PLUGIN WIN_SSPI FROM ANY USER TO USER GUEST;
CREATE MAPPING M_ROLE USING PLUGIN SRP FROM ROLE RANK TO ROLE ADM;
CREATE MAPPING M_GROUP USING PLUGIN WIN_SSPI FROM GROUP G TO USER U;
CREATE MAPPING M_TONULL USING PLUGIN SRP FROM USER X TO USER;
COMMIT;
ALTER MAPPING M_USER USING PLUGIN SRP FROM USER SYSDBA TO USER CHANGED;
DROP MAPPING M_GROUP;
COMMIT;
SET LIST ON;
SELECT RDB$MAP_NAME AS NM, RDB$MAP_USING AS U, RDB$MAP_PLUGIN AS P, RDB$MAP_DB AS D, RDB$MAP_FROM_TYPE AS FT, RDB$MAP_FROM AS FR, RDB$MAP_TO_TYPE AS TT, RDB$MAP_TO AS TO_ FROM RDB$AUTH_MAPPING ORDER BY 1;
SQL
}
e=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "CREATE / ALTER / DROP MAPPING and the RDB\$AUTH_MAPPING catalog" "$c" "$e"
e=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$REAL:$B" "CREATE MAPPING M_USER USING PLUGIN SRP FROM USER X TO USER Y" "DROP MAPPING NOPE" "ALTER MAPPING NOPE USING PLUGIN SRP FROM USER X TO USER Y" 2>&1 | norm)
c=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "CREATE MAPPING M_USER USING PLUGIN SRP FROM USER X TO USER Y" "DROP MAPPING NOPE" "ALTER MAPPING NOPE USING PLUGIN SRP FROM USER X TO USER Y" 2>&1 | norm)
check "the duplicate / missing MAPPING vectors" "$c" "$e"
# Boundary: GLOBAL mapping is the security database, refused here
cb=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "CREATE GLOBAL MAPPING GM USING PLUGIN SRP FROM USER A TO USER B" 2>&1 | norm)
ran=$((ran + 1))
if [ "${cb#*gds}" != "$cb" ]; then echo "OK   boundary: CREATE GLOBAL MAPPING refuses (the security database)"
else echo "DIFF boundary MOVED: GLOBAL MAPPING"; echo "     fc: $cb"; fail=1; fi
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
# the ENGINE reads fc's mappings
rq="SET LIST ON; SELECT RDB\$MAP_NAME AS NM, RDB\$MAP_FROM_TYPE AS FT, RDB\$MAP_FROM AS FR, RDB\$MAP_TO_TYPE AS TT, RDB\$MAP_TO AS TO_ FROM RDB\$AUTH_MAPPING ORDER BY 1;"
e=$(printf '%s\n' "$rq" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$rq" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE reads fc's mappings" "$c" "$e"
echo "ran $ran checks"
exit $fail
