#!/bin/bash
# Blob garbage collection - the ENGINE's own sweep over
# fire-crab-written blobs. fcblb creates blobs (level 0 and level 1)
# and the records that reference them; the ENGINE then deletes half
# the rows, commits, and runs gfix -sweep - its own garbage
# collector. The dead rows' blobs must die with them:
#
#   - gfix -v -full -n finds nothing wrong after the sweep
#   - the SURVIVING rows' blobs read back in full (engine and fcblb)
#   - the PIP's free-page count RISES - the dead level-1 blob's
#     pages actually return to the free pool, not just its slot
#
# A sweep that "works" but frees nothing would pass a validity-only
# check; the free-count teeth catch that.
#
#   qa/blb-gc.sh
#
# Builds its own scratch database.

set -u
FCBLB="${FCBLB:-$(dirname "$0")/../target/release/fcblb}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-blbgc.fdb"
TMP="$D/blbgc-tmp"

mkdir -p "$D" "$TMP"; rm -f "$DB"; rm -rf "$TMP"; mkdir -p "$TMP"
fail=0

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE W (C BLOB SUB_TYPE TEXT);
COMMIT;
EOF

python3 - "$TMP" <<'PYEOF'
import sys
d = sys.argv[1]
def gen(path, n):
    with open(path, 'w') as f:
        i = 0
        while f.tell() < n:
            f.write(f"line-{i:08d}-abcdefghijklmnopqrstuvwxyz.")
            i += 1
        f.truncate(n)
gen(f"{d}/small.txt", 500)
gen(f"{d}/big-a.txt", 200000)
gen(f"{d}/big-b.txt", 200000)
gen(f"{d}/big-c.txt", 200000)
PYEOF

# four rows: one small (level 0), three big (level 1)
"$FCBLB" write "$DB" W C "$TMP/small.txt" 400 >/dev/null || { echo "FAIL write"; exit 1; }
"$FCBLB" write "$DB" W C "$TMP/big-a.txt" 30000 >/dev/null || { echo "FAIL write"; exit 1; }
"$FCBLB" write "$DB" W C "$TMP/big-b.txt" 30000 >/dev/null || { echo "FAIL write"; exit 1; }
"$FCBLB" write "$DB" W C "$TMP/big-c.txt" 30000 >/dev/null || { echo "FAIL write"; exit 1; }

free_pages() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM RDB$PAGES WHERE 1 = 0;
SQL
}
# count the first PIP's FREE BITS directly (a set bit = a free page;
# the pip_used counter is not reliably maintained on release, the
# BITMAP is the allocation truth)
pip_free() {
    python3 - "$1" <<'PYEOF'
import struct, sys
f = open(sys.argv[1], 'rb').read()
ps = struct.unpack('<H', f[16:18])[0]
bits = f[ps + 28:2 * ps]
print(sum(bin(b).count('1') for b in bits))
PYEOF
}

free_before=$(pip_free "$DB")

# the ENGINE deletes two of the big rows and sweeps
"$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<'SQL'
DELETE FROM W ROWS 2 TO 3;
COMMIT;
SQL
"$GFIX" -sweep -user "$U" -pas "$P" "$DB" >/dev/null 2>&1

# --- the checks -------------------------------------------------------
v=$("$GFIX" -v -full -n -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n\t' ' ')
case "$v" in
    *"errors :"*|*"warnings :"*) echo "DIFF post-sweep validation: [$v]"; fail=1 ;;
    *) echo "OK   gfix -v -full is silent after the engine swept fcblb's blobs" ;;
esac

rows=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 <<'SQL' | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM W;
SQL
)
if [ "$rows" = "2" ]; then
    echo "OK   two rows survive the delete"
else
    echo "DIFF expected 2 surviving rows, got [$rows]"; fail=1
fi

# survivors read in full - through the engine AND through fcblb
lens=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 <<'SQL' | tr -s ' \n' ' ' | sed 's/^ *//; s/ *$//'
SET HEADING OFF;
SELECT OCTET_LENGTH(C) FROM W ORDER BY OCTET_LENGTH(C);
SQL
)
if [ "$lens" = "500 200000" ]; then
    echo "OK   the surviving blobs read in full through the engine (500 + 200000)"
else
    echo "DIFF surviving lengths: [$lens]"; fail=1
fi
flen0=$("$FCBLB" slices "$DB" W C 0 2>/dev/null | awk '/^LEN/{print $2}')
flen1=$("$FCBLB" slices "$DB" W C 1 2>/dev/null | awk '/^LEN/{print $2}')
got="$flen0 $flen1"
if [ "$got" = "500 200000" ] || [ "$got" = "200000 500" ]; then
    echo "OK   fcblb reads the survivors too"
else
    echo "DIFF fcblb survivor lengths: [$got]"; fail=1
fi

# the teeth: the dead level-1 blobs' PAGES came back to the pool
free_after=$(pip_free "$DB")
if [ "$free_after" -gt "$free_before" ]; then
    echo "OK   the sweep freed pages: PIP free bits $free_before -> $free_after (the dead blobs' pages returned)"
else
    echo "DIFF no pages freed: PIP free bits $free_before -> $free_after"; fail=1
fi

rm -rf "$TMP"
exit $fail
