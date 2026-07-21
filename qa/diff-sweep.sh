#!/bin/sh
# Sweep/GC differential QA: fire-crab predicts how many record-version
# segments `gfix -sweep` will remove; the engine's actual sweep must
# remove exactly that many.
#
#   qa/diff-sweep.sh <host> [workdir]
#
# The hard part is keeping garbage ON DISK long enough to measure:
# Firebird's cooperative GC collects old versions whenever a scan
# passes them with an advanced snapshot. So the scenario pins the
# oldest snapshot with a HELD snapshot transaction while the garbage
# is generated (updates + deletes), which blocks cooperative GC; then
# releases it, advances the oldest snapshot WITHOUT scanning the table
# (touching only RDB$DATABASE), and freezes the file. At that point the
# back versions are still on disk but now collectable.
#
#   1. fcstat gc predicts `collectable` on the frozen "before" file
#   2. gfix -sweep runs the real collection
#   3. fcstat versions on "before" and "after" gives the actual removal
#   4. assert  before - after == predicted  (and predicted > 0)

set -u
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
HOST="${1:-localhost}"
WORK="${2:-/tmp/fbhandson}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

db="$WORK/sweep_qa.fdb"
before="$WORK/sweep_qa_before.fdb"
after="$WORK/sweep_qa_after.fdb"
rm -f "$db" "$before" "$after"

freeze() { # $1 = destination copy
    "$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" >/dev/null 2>&1 <<'EOF'
ALTER DATABASE BEGIN BACKUP; COMMIT;
EOF
    cp "$db" "$1"
    "$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" >/dev/null 2>&1 <<'EOF'
ALTER DATABASE END BACKUP; COMMIT;
EOF
}

"$ISQL" -q -user "$U" -pas "$P" <<EOF || exit 1
CREATE DATABASE '$HOST:$db';
CREATE TABLE G (ID INT NOT NULL PRIMARY KEY, N INT);
COMMIT;
SET TERM ^;
EXECUTE BLOCK AS DECLARE I INT = 1; BEGIN
  WHILE (I <= 100) DO BEGIN INSERT INTO G VALUES (:I, 0); I = I + 1; END
END^
SET TERM ;^
COMMIT;
EOF

# a held SNAPSHOT reader pins the oldest snapshot, blocking cooperative
# GC while we churn versions
{
    printf 'SET TRANSACTION SNAPSHOT;\n'
    printf 'SELECT COUNT(*) FROM G;\n'   # take the snapshot
    sleep 10
    printf 'COMMIT;\n'
} | "$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" >/dev/null 2>&1 &
pin=$!
sleep 2

# generate garbage under the pin (a separate connection): update all
# rows three times, delete a slice - none collectable yet
"$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" <<'EOF'
UPDATE G SET N = 1; COMMIT;
UPDATE G SET N = 2; COMMIT;
UPDATE G SET N = 3; COMMIT;
DELETE FROM G WHERE ID > 90; COMMIT;
EOF

wait "$pin" 2>/dev/null   # release the pin

# advance the oldest snapshot without scanning G (RDB$DATABASE only)
for _ in 1 2 3 4 5 6; do
    "$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" >/dev/null 2>&1 <<'EOF'
SELECT 1 FROM RDB$DATABASE; COMMIT;
EOF
done

relid=$("$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$db" <<'EOF' | tr -d ' \n'
SET HEADING OFF;
SELECT RDB$RELATION_ID FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'G';
EOF
)

freeze "$before"
predicted=$("$FCSTAT" gc "$before" "$relid" | awk '/COLLECTABLE/{print $2}')
v_before=$("$FCSTAT" versions "$before" "$relid")

"$GFIX" -sweep -user "$U" -pas "$P" "$HOST:$db" >/dev/null 2>&1
freeze "$after"
v_after=$("$FCSTAT" versions "$after" "$relid")

removed=$((v_before - v_after))
"$ISQL" -q -user "$U" -pas "$P" "$HOST:$db" >/dev/null 2>&1 <<'EOF'
DROP DATABASE;
EOF
rm -f "$before" "$after"

echo "versions before $v_before, after $v_after: engine removed $removed"
echo "fire-crab predicted $predicted collectable"
if [ "$removed" -eq "$predicted" ] && [ "$predicted" -gt 0 ]; then
    echo "OK   sweep prediction matches the engine ($predicted versions)"
    exit 0
elif [ "$predicted" -eq 0 ]; then
    echo "VACUOUS: nothing collectable was left on disk (cooperative GC won the race)"
    exit 1
else
    echo "DIFF prediction $predicted != actual removal $removed"
    exit 1
fi
