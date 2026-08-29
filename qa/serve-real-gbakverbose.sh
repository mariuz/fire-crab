#!/bin/bash
# gbak's VERBOSE stream: the commentary is part of the protocol.
#
# With -v (bare isc_spb_verbose after the action byte on the -se route,
# the tagged clumplet on fbsvcmgr's) the service streams gbak's own
# lines through isc_info_svc_line polls. The commentary is DETERMINISTIC
# for a given file, and this gate holds fire-crab's stream against the
# engine's:
#
#   * BACKUP of the same source database: byte-equal after the two
#     recorded differences are normalized - the engine's per-privilege
#     lines (fire-crab writes no privilege records) and the closing
#     line's bytes-written count (the files legitimately differ);
#   * RESTORE of the ENGINE's fbk: byte-equal with the engine's
#     per-privilege "restoring privilege" lines filtered (set aside,
#     counted in the trace - the phase marker "adding missing
#     privileges" prints on BOTH sides, engine's own unconditional law);
#   * RESTORE of FIRE-CRAB's fbk: BYTE-IDENTICAL, nothing filtered -
#     the strongest form, both servers narrating the same file;
#   * the streams narrate REAL laws of the file: data blocks ride in
#     REVERSE creation order (a 3-table probe: metadata A,B,C, data
#     C,B,A - burp prepends to its relation list), constraints in
#     catalog row order with their real names;
#   * without -v both backups stay SILENT, and verbint (the versioned
#     verbosity contract) refuses rather than half-speaks.
#
#   qa/serve-real-gbakverbose.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
FBSVCMGR="${FBSVCMGR:-fbsvcmgr}"
PORT="${1:-4723}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-gbakv-src.fdb"
LOG="/tmp/fc-serve-gbakv-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

# the probe fixture: two tables so the reverse data order shows, a PK
# so the constraint and deferred-index lines show, two user indexes
rm -f "$SRC" "$D"/fc-gbakv-*.fbk "$D"/fc-gbakv-r*.fdb
# CREATED THROUGH THE SERVER, not as a bare path. A bare path attaches
# the EMBEDDED engine, which creates the file as THIS user, while every
# consumer below reaches it through `localhost:service_mgr` - a service
# running as the `firebird` user. That mixed-mode access is the whole of
# this gate's long-standing flakiness: intermittently the service's open
# lost the race with the embedded process still releasing the file and
# answered `I/O error during "open" operation`, which surfaced as
# `both -v backups run (rc)` want 0/0 got 1/0 - the ENGINE's own gbak
# failing, on a gate whose subject is fire-crab. Diagnosed 2026-08-29
# after it broke two consecutive sweeps; it reproduced 1-in-3 STANDALONE
# on an idle box, which is what ruled out load and ruled out the change
# under test. Same law as everywhere else here: hold the transport fixed.
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
CREATE DATABASE '127.0.0.1/${FC_REAL_PORT:-3050}:$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(10));
CREATE TABLE B (X INTEGER, W VARCHAR(5));
CREATE INDEX IDX_W ON B (W);
CREATE UNIQUE INDEX UX_X ON B (X);
COMMIT;
INSERT INTO A VALUES (1, 'one');
INSERT INTO A VALUES (2, NULL);
INSERT INTO B VALUES (7, 'w');
COMMIT;
EOF
chmod 666 "$SRC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$D"/fc-gbakv-*.fbk "$D"/fc-gbakv-r*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $(printf '%s' "$3" | head -c 400)"; echo "     got:  $(printf '%s' "$2" | head -c 400)"; fail=1; fi
}
EMGR="localhost:service_mgr"
FMGR="127.0.0.1/$PORT:service_mgr"
grab() { sudo -n chmod 666 "$1" 2>/dev/null || chmod 666 "$1" 2>/dev/null || true; }

# --- 1. the backup stream, engine vs fire-crab on the SAME source -------------
"$GBAK" -b -v -se "$EMGR" -user "$U" -pas "$P" "$SRC" "$D/fc-gbakv-e.fbk" >"$D/fc-gbakv-be.txt" 2>&1
erc=$?
"$GBAK" -b -v -se "$FMGR" -user "$U" -pas "$P" "$SRC" "$D/fc-gbakv-f.fbk" >"$D/fc-gbakv-bf.txt" 2>&1
frc=$?
check "both -v backups run (rc)" "$erc/$frc" "0/0"
# the two RECORDED differences: the engine's privilege lines, and the
# closing line's byte count (the files legitimately differ in size)
# RE-SPLIT THE STREAM ON ITS OWN RECORD MARKER before comparing. A
# verbose service stream is a sequence of `gbak:` records, and WHERE THE
# NEWLINES FALL IN IT IS NOT THE SUBJECT OF THIS GATE: the engine
# re-chunks its own output mid-line under load (diagnosed 2026-08-28),
# which made a line-based diff report a difference that is not in the
# content. Splitting on the marker instead of on newlines absorbs that
# and weakens nothing - every character is still compared, in order.
records() { tr -d '\r' <"$1" | tr '\n' ' ' | sed 's/gbak:/\ngbak:/g' | sed 's/  */ /g; s/ $//'; }
# ...and the privilege filter matches a TRUNCATED record too. The
# engine's stream does not merely re-chunk, it sometimes cuts a record
# off mid-word - a captured failing run held `gbak: writing privile`,
# which `writing privilege` does not match, so the fragment survived the
# filter and misaligned every following line. Privilege records are
# EXCLUDED BY DESIGN here (the engine writes them and fire-crab does
# not, a recorded difference), so matching their prefix excludes the
# fragments too and weakens nothing. This is why the gate broke two
# sweeps running while passing when re-run.
norm_b() {
    records "$1" | grep -v "writing privil" |
        sed "s/[0-9][0-9]* bytes written/N bytes written/; s|fc-gbakv-[ef]\.fbk|FBK|"
}
check "the backup streams are byte-equal (privileges filtered, count normalized)" \
    "$(norm_b "$D/fc-gbakv-bf.txt")" "$(norm_b "$D/fc-gbakv-be.txt")"
check "the stream narrates the REVERSE data order (B's data before A's)" \
    "$(grep "writing data" "$D/fc-gbakv-bf.txt" | tr -d ' ' | tr '\n' '/')" \
    'gbak:writingdatafortable"PUBLIC"."B"/gbak:writingdatafortable"PUBLIC"."A"/'
check "the constraints ride with their catalog names, in catalog order" \
    "$(grep "writing constraint" "$D/fc-gbakv-bf.txt" | tr -d ' ' | tr '\n' '/')" \
    'gbak:writingconstraint"PUBLIC"."INTEG_1"/gbak:writingconstraint"PUBLIC"."INTEG_2"/'

# --- 2. the restore stream on the ENGINE's fbk --------------------------------
grab "$D/fc-gbakv-e.fbk"
rm -f "$D/fc-gbakv-re.fdb" "$D/fc-gbakv-rf.fdb"
"$GBAK" -c -v -se "$EMGR" -user "$U" -pas "$P" "$D/fc-gbakv-e.fbk" "$D/fc-gbakv-re.fdb" >"$D/fc-gbakv-ce.txt" 2>&1
erc=$?
"$GBAK" -c -v -se "$FMGR" -user "$U" -pas "$P" "$D/fc-gbakv-e.fbk" "$D/fc-gbakv-rf.fdb" >"$D/fc-gbakv-cf.txt" 2>&1
frc=$?
check "both -v restores of the engine's fbk run (rc)" "$erc/$frc" "0/0"
# ONE recorded difference: the engine restores its privilege records,
# fire-crab sets them aside (counted in the trace). "adding missing
# privileges" is an UNCONDITIONAL phase marker and must ride BOTH.
norm_r() { records "$1" | grep -v "restoring privil" | sed "s|fc-gbakv-r[ef]\.fdb|FDB|"; }
check "the restore streams are byte-equal (privilege records filtered)" \
    "$(norm_r "$D/fc-gbakv-cf.txt")" "$(norm_r "$D/fc-gbakv-ce.txt")"
check "the phase marker 'adding missing privileges' rides both streams" \
    "$(grep -c 'adding missing privileges' "$D/fc-gbakv-cf.txt")/$(grep -c 'adding missing privileges' "$D/fc-gbakv-ce.txt")" \
    "1/1"

# --- 3. the restore stream on FIRE-CRAB's fbk: byte-identical, no filter ------
rm -f "$D/fc-gbakv-re.fdb" "$D/fc-gbakv-rf.fdb"
"$GBAK" -c -v -se "$EMGR" -user "$U" -pas "$P" "$D/fc-gbakv-f.fbk" "$D/fc-gbakv-re.fdb" >"$D/fc-gbakv-de.txt" 2>&1
erc=$?
"$GBAK" -c -v -se "$FMGR" -user "$U" -pas "$P" "$D/fc-gbakv-f.fbk" "$D/fc-gbakv-rf.fdb" >"$D/fc-gbakv-df.txt" 2>&1
frc=$?
check "both -v restores of fire-crab's fbk run (rc)" "$erc/$frc" "0/0"
check "...and those streams are BYTE-IDENTICAL, nothing filtered" \
    "$(sed 's|fc-gbakv-rf\.fdb|FDB|' "$D/fc-gbakv-df.txt")" \
    "$(sed 's|fc-gbakv-re\.fdb|FDB|' "$D/fc-gbakv-de.txt")"
grab "$D/fc-gbakv-re.fdb"; grab "$D/fc-gbakv-rf.fdb"
rows() {
    printf 'SET HEADING OFF;\nSELECT ID, V FROM A ORDER BY ID;\nSELECT X, W FROM B ORDER BY X;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/${FC_REAL_PORT:-3050}:$1" 2>&1 | tr -s ' \n' ' '
}
check "...and the restored databases read identically" \
    "$(rows "$D/fc-gbakv-rf.fdb")" "$(rows "$D/fc-gbakv-re.fdb")"

# --- 4. the TAGGED route (fbsvcmgr) streams the same commentary ---------------
rm -f "$D/fc-gbakv-e.fbk" "$D/fc-gbakv-f.fbk"
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_backup dbname "$SRC" bkp_file "$D/fc-gbakv-e.fbk" verbose >"$D/fc-gbakv-se.txt" 2>&1
erc=$?
"$FBSVCMGR" "$FMGR" user "$U" password "$P" action_backup dbname "$SRC" bkp_file "$D/fc-gbakv-f.fbk" verbose >"$D/fc-gbakv-sf.txt" 2>&1
frc=$?
check "fbsvcmgr's tagged verbose runs on both (rc)" "$erc/$frc" "0/0"
check "...and matches line for line (same normalization)" \
    "$(norm_b "$D/fc-gbakv-sf.txt")" "$(norm_b "$D/fc-gbakv-se.txt")"

# --- 5. the boundaries ---------------------------------------------------------
out=$("$GBAK" -b -se "$FMGR" -user "$U" -pas "$P" "$SRC" "$D/fc-gbakv-q.fbk" 2>&1)
check "without -v the backup stays SILENT" "$out|rc=$?" "|rc=0"
out=$("$FBSVCMGR" "$FMGR" user "$U" password "$P" action_backup dbname "$SRC" bkp_file "$D/fc-gbakv-vi.fbk" verbint 100 2>&1); vrc=$?
check "boundary: verbint refuses rather than half-speaks" \
    "$(printf '%s' "$out" | head -1)|rc=$vrc" "feature is not supported|rc=1"

echo "ran $ran checks"
exit $fail
