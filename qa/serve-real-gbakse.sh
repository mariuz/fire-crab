#!/bin/bash
# `gbak -se`: THE OLD PROTOCOL - a command line in the attach SPB.
#
# `gbak -b -se host:service_mgr db fbk` does not send dbname/bkp_file
# tags: its WHOLE COMMAND LINE rides the version-3 attach SPB as
# isc_spb_command_line - every argument wrapped in 0xFF (internal 0xFFs
# doubled, UtilSvc.h:159), a space after each, the last rtrimmed - and
# op_service_start carries a BARE ACTION BYTE. The version-3 SPB widens
# every clumplet length to u32, which is the whole reason the version
# exists: a command line is longer than a byte can say.
#
# What this gate holds:
#   * `gbak -b -se` against fire-crab produces an fbk the real
#     `gbak -c` restores, identical rows to the engine's own -se backup;
#   * `gbak -c -se` and `gbak -rep -se` restore THROUGH fire-crab - the
#     positionals REVERSE for a restore (file then database), which a
#     mapping that assumed the backup order would get silently wrong;
#   * restoring onto an existing database without -rep fails with
#     gbak's own vector (isc_gbak_db_exists), byte-compared;
#   * `-v -se` refuses rather than silences (verbose streaming is its
#     own slice), and the streaming forms (stdout/stdin) refuse too.
#
#   qa/serve-real-gbakse.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4722}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-gbakse-src.fdb"
LOG="/tmp/fc-serve-gbakse-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$SRC" "$D"/fc-gbakse-*.fbk "$D"/fc-gbakse-r*.fdb
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(10), B BLOB SUB_TYPE TEXT);
COMMIT;
INSERT INTO T VALUES (1, 'one', 'blob one');
INSERT INTO T VALUES (2, NULL, NULL);
COMMIT;
EOF
chmod 666 "$SRC"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$D"/fc-gbakse-*.fbk "$D"/fc-gbakse-r*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1 [$2]"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
se() { # <mgr> <gbak args...> -> "output|rc=N"
    local mgr=$1; shift
    local out rc
    out=$("$GBAK" -se "$mgr" -user "$U" -pas "$P" "$@" 2>&1); rc=$?
    printf '%s|rc=%s' "$(printf '%s' "$out" | tr '\n' '|')" "$rc"
}
EMGR="localhost:service_mgr"
FMGR="127.0.0.1/$PORT:service_mgr"
grab() { sudo -n chmod 666 "$1" 2>/dev/null || chmod 666 "$1" 2>/dev/null || true; }
rows() { # <db file>
    grab "$1"
    printf 'SET HEADING OFF;\nSELECT ID, V, CAST(B AS VARCHAR(10)) FROM T ORDER BY ID;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}

# --- 1. gbak -b -se against both servers ------------------------------------
check "gbak -b -se through fire-crab" "$(se "$FMGR" -b "$SRC" "$D/fc-gbakse-f.fbk")" "|rc=0"
check "gbak -b -se through the engine" "$(se "$EMGR" -b "$SRC" "$D/fc-gbakse-e.fbk")" "|rc=0"
grab "$D/fc-gbakse-e.fbk"
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbakse-f.fbk" "$D/fc-gbakse-r1.fdb" >/dev/null 2>&1
check "the real gbak -c restores fc's -se backup (rc)" "$?" "0"
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbakse-e.fbk" "$D/fc-gbakse-r2.fdb" >/dev/null 2>&1
check "the same rows as the engine's -se backup" \
    "$(rows "$D/fc-gbakse-r1.fdb")" "$(rows "$D/fc-gbakse-r2.fdb")"

# --- 2. gbak -c -se / -rep -se: the restore route through fire-crab ---------
# THE POSITIONALS REVERSE: a restore is <file> then <database>.
check "gbak -c -se restores THROUGH fire-crab" \
    "$(se "$FMGR" -c "$D/fc-gbakse-e.fbk" "$D/fc-gbakse-r3.fdb")" "|rc=0"
check "...and the rows are right" \
    "$(rows "$D/fc-gbakse-r3.fdb")" "$(rows "$D/fc-gbakse-r2.fdb")"
eo=$(se "$EMGR" -c "$D/fc-gbakse-e.fbk" "$D/fc-gbakse-r2.fdb")
fo=$(se "$FMGR" -c "$D/fc-gbakse-e.fbk" "$D/fc-gbakse-r3.fdb")
check "onto an existing database without -rep: gbak's own vector, both sides" \
    "$(printf '%s' "$fo" | sed "s|$D/fc-gbakse-r3.fdb|<db>|")" \
    "$(printf '%s' "$eo" | sed "s|$D/fc-gbakse-r2.fdb|<db>|")"
check "gbak -rep -se replaces" \
    "$(se "$FMGR" -rep "$D/fc-gbakse-e.fbk" "$D/fc-gbakse-r3.fdb")" "|rc=0"
check "...and the replaced database reads right" \
    "$(rows "$D/fc-gbakse-r3.fdb")" "$(rows "$D/fc-gbakse-r2.fdb")"

# --- 3. the refusals ----------------------------------------------------------
check "boundary: -v -se refuses rather than silences" \
    "$(se "$FMGR" -b -v "$SRC" "$D/fc-gbakse-v.fbk" | sed 's/|rc=1$//;s/gbak: ERROR:feature is not supported.*/REFUSED/')" \
    "REFUSED"
check "boundary: a backup to stdout refuses" \
    "$(se "$FMGR" -b "$SRC" stdout | sed 's/|rc=1$//;s/gbak: ERROR:feature is not supported.*/REFUSED/')" \
    "REFUSED"
check "boundary: -r (recreate) refuses - its overwrite-ness is a guess" \
    "$(se "$FMGR" -r "$D/fc-gbakse-e.fbk" "$D/fc-gbakse-r9.fdb" | sed 's/|rc=1$//;s/gbak: ERROR:feature is not supported.*/REFUSED/')" \
    "REFUSED"

echo "ran $ran checks"
exit $fail
