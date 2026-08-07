#!/bin/bash
# `gfix -v [-full] -n`: VALIDATION, AND WHAT ITS SILENCE MEANS.
#
# The engine validates DURING the verify attach and gfix reads sixteen
# counters back through isc_database_info, printing one line per
# non-zero counter - so a CLEAN database is SILENCE. That is also what
# made an unconverted server dangerous here: fcwire used to skip info
# items it did not know, gfix printed the same silence a clean file
# gets, and `gfix -v` against fire-crab was a validation that could not
# fail. This gate is what makes the silence a claim.
#
# THE DESIGN: one fixture built by the engine, then per corruption case
# a fresh COPY is corrupted at a DETERMINISTIC target (found through
# RDB$PAGES, the catalog's own page map) and BOTH servers validate THE
# SAME file - the engine offline, fire-crab over TCP; `-n` never
# writes, so the file cannot drift between the two runs.
#
# Byte-equal cases (measured first, one corruption at a time):
#   * clean: silence, both;
#   * a DATA page of T with its type byte zeroed: "database page
#     errors: 1", no warning - under -full AND plain -v alike;
#   * the same page with an absurd record directory: "data page
#     errors: 1" - one per page, not per entry;
#   * T's POINTER page zeroed: 1 error + 1 warning (the orphaned
#     subtree is the warning); a BTREE page zeroed: the same shape;
#   * a record's back pointer aimed PAST THE FILE, under -full: the
#     attach itself fails - I/O error / "File size is less than
#     expected" - and plain -v (no record walk) stays silent;
#   * the TIP zeroed: the attach fails with the corruption vector,
#     naming the page and both type names ("expected transaction
#     inventory, found purposely undefined").
#
# RECORDED BOUNDARY: the SCN page (page 2) zeroed. The engine answers a
# CASCADE - every SCN-consulted check fails too (296 errors on this
# fixture) - where fire-crab counts the broken page itself: exactly 1.
#
#   qa/serve-real-validate.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4718}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-validate-src.fdb"
CP="$D/fc-validate-case.fdb"
LOG="/tmp/fc-serve-validate-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$SRC" "$CP"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
UPDATE T SET V = 11 WHERE ID = 1;
COMMIT;
EOF
chmod 666 "$SRC"
PS=8192

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$CP"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

# THE DETERMINISTIC TARGETS, from the catalog's own page map
q() { printf 'SET HEADING OFF;\n%s\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$SRC" 2>&1 | tr -d ' \n'; }
relT=$(q "SELECT RDB\$RELATION_ID FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'T';")
PP=$(q "SELECT MIN(RDB\$PAGE_NUMBER) FROM RDB\$PAGES WHERE RDB\$RELATION_ID = $relT AND RDB\$PAGE_TYPE = 4;")
TIP=$(q "SELECT MIN(RDB\$PAGE_NUMBER) FROM RDB\$PAGES WHERE RDB\$PAGE_TYPE = 3;")
# T's first data page: slot 0 of its pointer page; and a btree page: the
# highest type-7 page in the file (the last index built)
DP=$(python3 -c "
f=open('$SRC','rb').read()
import struct
print(struct.unpack_from('<I', f, $PP*$PS+32)[0])")
BT=$(python3 -c "
f=open('$SRC','rb').read()
print(max(i for i in range(len(f)//$PS) if f[i*$PS]==7))")
echo "note targets: relT=$relT pointer=$PP data=$DP tip=$TIP btree=$BT"

# run one case: corrupt a copy, validate through both, compare verbatim
vboth() { # <label> <corrupt-python> <switches...>
    local label=$1 py=$2; shift 2
    cp "$SRC" "$CP"; chmod 666 "$CP"
    [ -n "$py" ] && python3 -c "$py"
    local eo ec erc frc
    eo=$("$GFIX" "$@" -user "$U" -pas "$P" "$CP" 2>&1); erc=$?
    ec=$("$GFIX" "$@" -user "$U" -pas "$P" "127.0.0.1/$PORT:$CP" 2>&1); frc=$?
    eo="$(printf '%s' "$eo" | tr '\n' '|')|rc=$erc"
    ec="$(printf '%s' "$ec" | tr '\n' '|')|rc=$frc"
    ran=$((ran + 1))
    if [ "$eo" = "$ec" ]; then echo "OK   $label [$eo]"
    else echo "DIFF $label"; echo "     engine: $eo"; echo "     fc:     $ec"; fail=1; fi
}

# --- the byte-equal cases ----------------------------------------------------
vboth "clean file, -v -full -n" "" -v -full -n
vboth "clean file, plain -v -n" "" -v -n
vboth "a data page of T, type zeroed (-full)" \
    "f=open('$CP','r+b'); f.seek($DP*$PS); f.write(bytes([0]))" -v -full -n
vboth "the same, plain -v (no record walk, same page walk)" \
    "f=open('$CP','r+b'); f.seek($DP*$PS); f.write(bytes([0]))" -v -n
vboth "an absurd record directory on T's data page" \
    "f=open('$CP','r+b'); f.seek($DP*$PS+22); f.write((60000).to_bytes(2,'little'))" -v -full -n
vboth "T's pointer page, type zeroed" \
    "f=open('$CP','r+b'); f.seek($PP*$PS); f.write(bytes([0]))" -v -full -n
vboth "a btree page, type zeroed" \
    "f=open('$CP','r+b'); f.seek($BT*$PS); f.write(bytes([0]))" -v -full -n
vboth "a back pointer past the file (-full): the attach fails" \
    "
import struct
f=open('$CP','r+b'); data=open('$CP','rb').read()
off, ln = struct.unpack_from('<HH', data, $DP*$PS+24)
f.seek($DP*$PS+off+4); f.write((99999).to_bytes(4,'little'))" -v -full -n
vboth "...and plain -v does not walk records" \
    "
import struct
f=open('$CP','r+b'); data=open('$CP','rb').read()
off, ln = struct.unpack_from('<HH', data, $DP*$PS+24)
f.seek($DP*$PS+off+4); f.write((99999).to_bytes(4,'little'))" -v -n
vboth "the TIP zeroed: the corruption vector, page and type names" \
    "f=open('$CP','r+b'); f.seek($TIP*$PS); f.write(bytes([0]))" -v -full -n

# --- the recorded boundary: the SCN cascade ---------------------------------
cp "$SRC" "$CP"; chmod 666 "$CP"
python3 -c "f=open('$CP','r+b'); f.seek(2*$PS); f.write(bytes([0]))"
eo=$("$GFIX" -v -full -n -user "$U" -pas "$P" "$CP" 2>&1 | tr '\n' '|')
ec=$("$GFIX" -v -full -n -user "$U" -pas "$P" "127.0.0.1/$PORT:$CP" 2>&1 | tr '\n' '|')
ran=$((ran + 1))
en=$(printf '%s' "$eo" | sed -n 's/.*database page errors\t: \([0-9]*\).*/\1/p')
fn=$(printf '%s' "$ec" | sed -n 's/.*database page errors\t: \([0-9]*\).*/\1/p')
if [ "$fn" = "1" ] && [ -n "$en" ] && [ "$en" -gt 1 ] 2>/dev/null; then
    echo "OK   boundary: the SCN cascade (engine $en errors, fc counts the page itself: 1)"
else
    echo "DIFF boundary MOVED: SCN page zeroed - engine [$eo] fc [$ec]"
    fail=1
fi

# --- TEETH: silence is a claim now, not a skipped item ----------------------
# The old failure mode: a server that skips the info items answers gfix
# with nothing, which prints as clean. The trace says the walk RAN.
ran=$((ran + 1))
if grep -q "validate (full=" "$LOG"; then
    echo "OK   teeth: the validation walk ran ($(grep -c 'validate (full=' "$LOG") times)"
else
    echo "DIFF teeth: no validation ran - the silence above meant nothing"; fail=1
fi

echo "ran $ran checks"
exit $fail
