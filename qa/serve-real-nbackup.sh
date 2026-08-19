#!/bin/bash
# nbackup AS A SERVICE: isc_action_svc_nbak / nrest, level 0.
#
# The physical backup is the tool that CANNOT reach a server any other
# way: direct `nbackup -B` refuses a remote path ("nbackup needs local
# access to database file") and a bare path attaches the EMBEDDED
# engine, never a server - so the service actions are not a convenience
# here, they are the whole story.
#
# WHAT THE ENGINE'S MACHINERY BUYS, AND WHY FIRE-CRAB GETS IT FREE. The
# engine's backup needs BEGIN/END BACKUP around its copy because the
# file changes underneath: the mode diverts writes to a .delta, the copy
# reads a frozen file, END BACKUP merges. What that buys is a consistent
# point-in-time image - and fire-crab's buffer pool already IS one: a
# published image is never edited in place, so the Arc the action takes
# cannot change however many writers commit while the copy runs.
#
# MEASURED LAWS:
#   * a level-0 .nbk is the database with hdr_backup_mode STALLED inside
#     it (the engine's own .nbk differs from the live file in exactly
#     that byte plus the counters END BACKUP advanced afterwards);
#   * restore is a FIXUP COPY: mode cleared, and a FRESH database GUID -
#     the restored database is a NEW database holding the same rows;
#   * nrest streams NO output; nbak streams the three stat lines;
#   * the client polls with isc_info_svc_line + isc_info_svc_stdin
#     together, and stdin must answer numeric 0 ("no input wanted") -
#     refusing the pair fails an action that has already succeeded.
#
# RECORDED BOUNDARY - one feature, not three: incremental backup. A
# level > 0 (or -B <GUID>) needs SCN tracking, a backup GUID in the main
# header and an RDB$BACKUP_HISTORY row - the chain bookkeeping the
# engine writes EVEN FOR LEVEL 0, and fire-crab deliberately does not:
# after the engine's nbak the main file gains a history row and a backup
# GUID, after fire-crab's it gains neither. Asserted, not hidden.
#
#   qa/serve-real-nbackup.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GSTAT="${GSTAT:-gstat}"
NBACKUP="${NBACKUP:-nbackup}"
FBSVCMGR="${FBSVCMGR:-fbsvcmgr}"
PORT="${1:-4719}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBE="$D/fc-nbackup-engine.fdb"
DBF="$D/fc-nbackup-crab.fdb"
LOG="/tmp/fc-serve-nbackup-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

build() { # <path>
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
COMMIT;
EOF
}
rm -f "$DBE" "$DBF" "$D"/fc-nbackup-*.nbk "$D"/fc-nbackup-r*.fdb
build "$DBE"; build "$DBF"; chmod 666 "$DBE" "$DBF"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF" "$D"/fc-nbackup-*.nbk "$D"/fc-nbackup-r*.fdb' EXIT
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
svc() { # <mgr> <args...> -> "output|rc=N", elapsed seconds normalized
    local mgr=$1; shift
    local out rc
    out=$("$FBSVCMGR" "$mgr" user "$U" password "$P" "$@" 2>&1); rc=$?
    printf '%s|rc=%s' \
        "$(printf '%s' "$out" | sed 's/elapsed\t[0-9]* sec/elapsed\tN sec/' | tr '\n' '|')" "$rc"
}
EMGR="localhost:service_mgr"
FMGR="127.0.0.1/$PORT:service_mgr"
# a file the engine's service wrote is owned by the firebird user; the
# gate (and fire-crab) read it as this user, so open it up
grab() { sudo -n chmod 666 "$1" 2>/dev/null || chmod 666 "$1" 2>/dev/null || true; }
rows_via_engine() { # <file> - through TCP, so the engine's own user reads it
    printf 'SET HEADING OFF;\nSELECT ID, V FROM T ORDER BY ID;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$1" 2>&1 | tr -s ' \n' ' '
}

# --- 1. the SERVICE OUTPUT is the same, byte for byte ------------------------
eo=$(svc "$EMGR" action_nbak nbk_level 0 dbname "$DBE" nbk_file "$D/fc-nbackup-e.nbk")
fo=$(svc "$FMGR" action_nbak nbk_level 0 dbname "$DBF" nbk_file "$D/fc-nbackup-f.nbk")
check "action_nbak streams the same stat lines" "$fo" "$eo"

# --- 2. THE CROSS-RESTORES: each side's backup through the other's tools ----
# fire-crab's backup, restored by the REAL nbackup
rm -f "$D/fc-nbackup-r1.fdb"
"$NBACKUP" -R "$D/fc-nbackup-r1.fdb" "$D/fc-nbackup-f.nbk" >/dev/null 2>&1
check "real nbackup -R accepts fire-crab's level-0 backup (rc)" "$?" "0"
chmod 666 "$D/fc-nbackup-r1.fdb" 2>/dev/null
check "...and the engine reads the right rows from it" \
    "$(rows_via_engine "$D/fc-nbackup-r1.fdb")" " 1 10 2 20 "
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$D/fc-nbackup-r1.fdb" 2>&1 | tr -d ' \n')
if [ -z "$v" ]; then echo "OK   gfix -v -full accepts the restored file"
else echo "DIFF gfix -v -full: [$v]"; fail=1; fi

# the ENGINE's backup, restored by fire-crab's service
grab "$D/fc-nbackup-e.nbk"
fo=$(svc "$FMGR" action_nrest dbname "$D/fc-nbackup-r2.fdb" nbk_file "$D/fc-nbackup-e.nbk")
check "fc action_nrest accepts the engine's backup (and streams nothing)" "$fo" "|rc=0"
chmod 666 "$D/fc-nbackup-r2.fdb" 2>/dev/null
check "...and the engine reads the right rows from it" \
    "$(rows_via_engine "$D/fc-nbackup-r2.fdb")" " 1 10 2 20 "
# the fixup: backup mode cleared, and a FRESH GUID (the engine's law)
attrs=$("$GSTAT" -h -user "$U" -pas "$P" "$D/fc-nbackup-r2.fdb" 2>&1 |
    sed -n 's/^[[:space:]]*Attributes[[:space:]]*//p')
check "the restored file is out of backup mode" "$attrs" "force write"
ran=$((ran + 1))
same=$(python3 -c "
a=open('$D/fc-nbackup-e.nbk','rb').read()[84:100]
b=open('$D/fc-nbackup-r2.fdb','rb').read()[84:100]
print('same' if a==b else 'fresh')")
if [ "$same" = "fresh" ]; then
    echo "OK   the restore wrote a FRESH database GUID (the engine's law)"
else
    echo "DIFF the restored database kept the backup's GUID"; fail=1
fi

# --- 3. the backup is a POINT-IN-TIME image ---------------------------------
printf 'INSERT INTO T VALUES (3, 30);\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DBF" >/dev/null 2>&1
rm -f "$D/fc-nbackup-g.nbk" "$D/fc-nbackup-r3.fdb"
svc "$FMGR" action_nbak nbk_level 0 dbname "$DBF" nbk_file "$D/fc-nbackup-g.nbk" >/dev/null
printf 'INSERT INTO T VALUES (4, 40);\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DBF" >/dev/null 2>&1
"$NBACKUP" -R "$D/fc-nbackup-r3.fdb" "$D/fc-nbackup-g.nbk" >/dev/null 2>&1
chmod 666 "$D/fc-nbackup-r3.fdb" 2>/dev/null
check "teeth: a row written AFTER the backup is not in it" \
    "$(rows_via_engine "$D/fc-nbackup-r3.fdb")" " 1 10 2 20 3 30 "
check "...and the live database has both" \
    "$(printf 'SET HEADING OFF;\nSELECT ID, V FROM T ORDER BY ID;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DBF" 2>&1 | tr -s ' \n' ' ')" \
    " 1 10 2 20 3 30 4 40 "

# --- 4. refusals compared ----------------------------------------------------
eo=$(svc "$EMGR" action_nbak nbk_level 0 dbname "$DBE" nbk_file "$D/fc-nbackup-e.nbk")
fo=$(svc "$FMGR" action_nbak nbk_level 0 dbname "$DBF" nbk_file "$D/fc-nbackup-f.nbk")
ran=$((ran + 1))
erc="${eo##*rc=}"; frc="${fo##*rc=}"
if [ "$erc" = "1" ] && [ "$frc" = "1" ]; then
    echo "OK   a backup onto an EXISTING file refuses on both (engine rc=1, fc rc=1)"
else
    echo "DIFF backup onto existing file: engine [$eo] fc [$fo]"; fail=1
fi
eo=$(svc "$EMGR" action_nrest dbname "$DBE" nbk_file "$D/fc-nbackup-e.nbk")
fo=$(svc "$FMGR" action_nrest dbname "$DBF" nbk_file "$D/fc-nbackup-f.nbk")
ran=$((ran + 1))
erc="${eo##*rc=}"; frc="${fo##*rc=}"
if [ "$erc" = "1" ] && [ "$frc" = "1" ]; then
    echo "OK   a restore onto an EXISTING database refuses on both"
else
    echo "DIFF restore onto existing db: engine [$eo] fc [$fo]"; fail=1
fi

# --- 5. RECORDED BOUNDARY: the incremental chain ----------------------------
# fire-crab still refuses PRODUCING level > 0 (that is the next
# slice); but its level-0 now writes the SAME chain bookkeeping the
# engine's does - a backup GUID into the main header, an
# RDB$BACKUP_HISTORY row anchored at the current ERA, the era
# advanced - so the ENGINE's own incremental chains onto it.
# ~~producing an incremental refuses~~ - fc PRODUCES level N now:
# the engine's own inc_header container (one zero-padded page:
# NBAK, version 2, level, this/prev GUIDs, page size, both SCNs)
# then the raw pages above the previous era, ascending
rm -f "$D/fc-nbackup-l1.nbk"
ran=$((ran + 1))
fo=$(svc "$FMGR" action_nbak nbk_level 1 dbname "$DBF" nbk_file "$D/fc-nbackup-l1.nbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   fc PRODUCES a level-1 increment (the engine's own container)"
else
    echo "DIFF fc level-1 production: [$fo]"; fail=1
fi
rm -f "$D/fc-nbackup-l1.nbk"
hist() { # <conn> - how many backup-history rows
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM RDB$BACKUP_HISTORY;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d ' \n'
}
ran=$((ran + 1))
eh=$(hist "127.0.0.1/$REAL:$DBE"); fh=$(hist "127.0.0.1/$PORT:$DBF")
if [ "$eh" -ge 1 ] 2>/dev/null && [ "$fh" -ge 1 ] 2>/dev/null; then
    echo "OK   ~~boundary~~ both nbaks write the chain bookkeeping (engine $eh, fc $fh)"
else
    echo "DIFF history rows: engine=$eh fc=$fh (want >=1 both)"; fail=1
fi

# --- 5b. THE CROSS-IMPLEMENTATION CHAIN: the engine's level-1 extends
# fc's level-0, and a row written through FC'S OWN DML rides it - the
# SCN stamping this asserts was measured missing (a silent data loss)
CHDB="$D/fc-nbackup-chain.fdb"
rm -f "$CHDB" "$D/fc-nb-ch0.nbk" "$D/fc-nb-ch1.nbk" "$D/fc-nb-chr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$CHDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
INSERT INTO T VALUES (1);
COMMIT;
EOF
chmod 666 "$CHDB"
ran=$((ran + 1))
fo=$(svc "$FMGR" action_nbak nbk_level 0 dbname "$CHDB" nbk_file "$D/fc-nb-ch0.nbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   fc anchors a chain (level 0 with the bookkeeping)"
else
    echo "DIFF chain level-0: [$fo]"; fail=1
fi
printf 'INSERT INTO T VALUES (3);\nCOMMIT;\n' | "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$CHDB" >/dev/null 2>&1
sudo -n chmod 666 "$D/fc-nb-ch0.nbk" 2>/dev/null || chmod 666 "$D/fc-nb-ch0.nbk" 2>/dev/null
"$NBACKUP" -B 1 "$CHDB" "$D/fc-nb-ch1.nbk" -user "$U" -password "$P" >/dev/null 2>&1
"$NBACKUP" -R "$D/fc-nb-chr.fdb" "$D/fc-nb-ch0.nbk" "$D/fc-nb-ch1.nbk" >/dev/null 2>&1
chmod 666 "$D/fc-nb-chr.fdb" 2>/dev/null
ran=$((ran + 1))
got=$(printf 'SET HEADING OFF;\nSELECT X FROM T ORDER BY X;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-nb-chr.fdb" 2>&1 | tr -s ' \n' '/')
if [ "$got" = "/1/3/" ]; then
    echo "OK   the ENGINE's level-1 chains onto fc's level-0 and carries FC's OWN write"
else
    echo "DIFF cross-implementation chain: [$got] (want /1/3/)"; fail=1
fi
# ...and the ALL-FC chain: fc anchors, fc writes, fc INCREMENTS, the
# ENGINE restores - then an engine write and FC's level 2 on top
rm -f "$D/fc-nb-ch2.nbk" "$D/fc-nb-chr2.fdb"
printf 'INSERT INTO T VALUES (7);\nCOMMIT;\n' | "$ISQL" -q -b -user "$U" -pas "$P" "$CHDB" >/dev/null 2>&1
ran=$((ran + 1))
fo=$(svc "$FMGR" action_nbak nbk_level 2 dbname "$CHDB" nbk_file "$D/fc-nb-ch2.nbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   fc's level-2 increments the mixed chain (an ENGINE-written row inside)"
else
    echo "DIFF fc level-2: [$fo]"; fail=1
fi
sudo -n chmod 666 "$D/fc-nb-ch2.nbk" 2>/dev/null || chmod 666 "$D/fc-nb-ch2.nbk" 2>/dev/null
"$NBACKUP" -R "$D/fc-nb-chr2.fdb" "$D/fc-nb-ch0.nbk" "$D/fc-nb-ch1.nbk" "$D/fc-nb-ch2.nbk" >/dev/null 2>&1
chmod 666 "$D/fc-nb-chr2.fdb" 2>/dev/null
ran=$((ran + 1))
got=$(printf 'SET HEADING OFF;\nSELECT X FROM T ORDER BY X;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-nb-chr2.fdb" 2>&1 | tr -s ' \n' '/')
if [ "$got" = "/1/3/7/" ]; then
    echo "OK   the ENGINE restores the three-level MIXED chain (fc-0, engine-1, fc-2)"
else
    echo "DIFF mixed chain: [$got] (want /1/3/7/)"; fail=1
fi
# ...and FC RESTORES a chain the ENGINE produced - the level-0's
# guid clumplet seeds the chain, each increment must name its
# predecessor, and a wrong order refuses whole with no half-db
rm -f "$D/fc-nb-e0.nbk" "$D/fc-nb-e1.nbk" "$D/fc-nb-fcr.fdb" "$D/fc-nb-bad.fdb"
"$NBACKUP" -B 0 "$CHDB" "$D/fc-nb-e0.nbk" -user "$U" -password "$P" >/dev/null 2>&1
printf 'INSERT INTO T VALUES (9);\nCOMMIT;\n' | "$ISQL" -q -b -user "$U" -pas "$P" "$CHDB" >/dev/null 2>&1
"$NBACKUP" -B 1 "$CHDB" "$D/fc-nb-e1.nbk" -user "$U" -password "$P" >/dev/null 2>&1
chmod 666 "$D/fc-nb-e0.nbk" "$D/fc-nb-e1.nbk" 2>/dev/null
ran=$((ran + 1))
fo=$(svc "$FMGR" action_nrest dbname "$D/fc-nb-fcr.fdb" nbk_file "$D/fc-nb-e0.nbk" nbk_file "$D/fc-nb-e1.nbk")
grab "$D/fc-nb-fcr.fdb"
got=$(printf 'SET HEADING OFF;\nSELECT MAX(X) FROM T;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-nb-fcr.fdb" 2>&1 | tr -d ' \n')
if [ "$got" = "9" ]; then
    echo "OK   FC restores the ENGINE's chain (the increment's row is the answer)"
else
    echo "DIFF fc chain restore: [$fo] max=[$got] (want 9)"; fail=1
fi
ran=$((ran + 1))
fo=$(svc "$FMGR" action_nrest dbname "$D/fc-nb-bad.fdb" nbk_file "$D/fc-nb-e1.nbk" nbk_file "$D/fc-nb-e0.nbk")
if [ "${fo##*rc=}" = "1" ] && [ ! -e "$D/fc-nb-bad.fdb" ]; then
    echo "OK   a WRONG ORDER refuses whole (no half-restored database)"
else
    echo "DIFF wrong-order restore: [$fo]"; fail=1
fi
rm -f "$CHDB" "$D/fc-nb-ch0.nbk" "$D/fc-nb-ch1.nbk" "$D/fc-nb-ch2.nbk" "$D/fc-nb-chr.fdb" "$D/fc-nb-chr2.fdb" "$D/fc-nb-e0.nbk" "$D/fc-nb-e1.nbk" "$D/fc-nb-fcr.fdb" "$D/fc-nb-bad.fdb"

# --- 6. and the MAIN database survives its own backup ------------------------
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$DBF" 2>&1 | tr -d ' \n')
if [ -z "$v" ]; then echo "OK   gfix -v -full accepts the live database after its backups"
else echo "DIFF gfix -v -full on the live db: [$v]"; fail=1; fi

echo "ran $ran checks"
exit $fail
