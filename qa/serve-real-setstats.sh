#!/bin/bash
# SET STATISTICS INDEX <name> - recompute an index's selectivity.
#
# The selectivity of an index is not maintained as rows change: it is a
# snapshot taken when the index is built (CREATE INDEX / ALTER INDEX
# ACTIVE - serve-real-alterindex.sh) and it goes stale as the table
# grows. SET STATISTICS refreshes it. The engine does this in two steps -
# it writes RDB$STATISTICS = -1.0 as a "recalculate me" marker at execute
# and a deferred work walks the index tree at commit - but only the
# committed end state is observable, and that state is exactly what a
# fresh build produces: 1 / distinct per key prefix over the rows as they
# now stand, in RDB$INDICES.RDB$STATISTICS (whole key), each
# RDB$INDEX_SEGMENTS.RDB$STATISTICS (per prefix), and the irtd_selectivity
# float of each segment descriptor on the index root page. fire-crab
# computes it from the committed rows with the same machinery every build
# uses.
#
# Any index qualifies - a PRIMARY KEY's included - so the only failure is
# an index that does not exist.
#
# The differential is the engine, four ways:
#   1. rows are added to a table AFTER its indexes are built, so the
#      stored selectivity is STALE; fire-crab and the engine each run
#      SET STATISTICS on the same indexes on two copies of that database,
#      and RDB$INDICES / RDB$INDEX_SEGMENTS are compared - the numbers
#      must have MOVED to the same fresh values;
#   2. the index-root descriptors are read off both files and their
#      irtd_selectivity floats compared;
#   3. an unknown index is refused on both;
#   4. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-setstats.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4153}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
PS=8192
D=/tmp/fbhandson
SRC="$D/fc-ss-src.fdb"; WORK="$D/fc-ss-work.fdb"; REF="$D/fc-ss-ref.fdb"
FBK="$D/fc-ss-work.fbk"; RST="$D/fc-ss-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

# a table indexed over TWO rows, then grown to SIX - so the stored
# selectivity (1/2) is stale and SET STATISTICS must move it to 1/6
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE $PS;
CREATE TABLE T (A INTEGER NOT NULL, B INTEGER, C INTEGER, CONSTRAINT PK_T PRIMARY KEY (A));
COMMIT;
INSERT INTO T VALUES (1, 1, 10);
INSERT INTO T VALUES (2, 1, 20);
COMMIT;
CREATE INDEX IX_TBC ON T (B, C);
CREATE UNIQUE INDEX IX_TC ON T (C);
COMMIT;
INSERT INTO T VALUES (3, 2, 30);
INSERT INTO T VALUES (4, 3, 40);
INSERT INTO T VALUES (5, 4, 50);
INSERT INTO T VALUES (6, 5, 60);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"

SS1="SET STATISTICS INDEX IX_TBC"
SS2="SET STATISTICS INDEX IX_TC"
SS3="SET STATISTICS INDEX PK_T"
UNK="SET STATISTICS INDEX NO_SUCH_INDEX"

# the reference: the engine recomputes on its own copy
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$SS1; $SS2; $SS3;
COMMIT;
EOF
eng_unk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$UNK;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ss.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          console.log(e2?("ERR "+(e2.message||"").split("\n")[0]):"OK");
          db.detach();process.exit(0);});
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

statq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'IDX|'||TRIM(RDB$INDEX_NAME)||'|'||CAST(RDB$STATISTICS AS NUMERIC(9,6))
  FROM RDB$INDICES WHERE RDB$RELATION_NAME = 'T' ORDER BY RDB$INDEX_NAME;
SELECT 'SEG|'||TRIM(RDB$INDEX_NAME)||'|'||RDB$FIELD_POSITION||'|'||CAST(RDB$STATISTICS AS NUMERIC(9,6))
  FROM RDB$INDEX_SEGMENTS S
  WHERE EXISTS (SELECT 1 FROM RDB$INDICES I WHERE I.RDB$INDEX_NAME = S.RDB$INDEX_NAME
                  AND I.RDB$RELATION_NAME = 'T')
  ORDER BY RDB$INDEX_NAME, RDB$FIELD_POSITION;
SQL
}
# the STALE snapshot, before anyone recomputes - so the gate can prove the
# numbers actually moved
stale=$(statq "$WORK")

# fire-crab recomputes
check "SET STATISTICS INDEX IX_TBC" "$(node_run "$SS1")" "OK"
check "SET STATISTICS INDEX IX_TC"  "$(node_run "$SS2")" "OK"
check "SET STATISTICS INDEX PK_T (a constraint's index)" "$(node_run "$SS3")" "OK"
unk=$(node_run "$UNK")
case "$unk" in
    ERR*) echo "OK   an unknown index is refused" ;;
    *) echo "DIFF unknown index accepted"; echo "     got:  $unk"; fail=1 ;;
esac
case "$eng_unk" in
    *"not found"*) echo "OK   the engine refuses the unknown index too" ;;
    *) echo "DIFF engine did not refuse the unknown index"; echo "     $eng_unk"; fail=1 ;;
esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the recomputed statistics match the engine reference -----------
work_stat=$(statq "$WORK")
check "recomputed statistics match the engine reference" "$work_stat" "$(statq "$REF")"
# teeth: the numbers actually MOVED (a no-op SET STATISTICS would leave
# the stale 1/2 snapshot and still "match" a reference that also did
# nothing - but the reference DID recompute, so a fire-crab no-op DIFFs;
# this asserts the movement directly too)
if [ "$work_stat" = "$stale" ]; then
    echo "DIFF SET STATISTICS did not change anything (still the stale snapshot)"; fail=1
else
    echo "OK   the statistics moved off the stale snapshot"
fi
case "$work_stat" in
    *"IDX|IX_TBC|0.166667"*) echo "OK   IX_TBC recomputed to 1/6 over the six rows" ;;
    *) echo "DIFF IX_TBC did not recompute to 1/6"; echo "     $work_stat"; fail=1 ;;
esac
case "$work_stat" in
    *"SEG|IX_TBC|0|0.200000"*"SEG|IX_TBC|1|0.166667"*)
        echo "OK   ... per key PREFIX (first segment 1/5 over B, whole key 1/6)" ;;
    *) echo "DIFF per-prefix segment statistics"; echo "     $work_stat"; fail=1 ;;
esac

# --- 2. the index-root descriptors (irtd_selectivity) ------------------
# read the segment-descriptor floats off relation 128's index root page
descs() { # <file>
    python3 - "$1" "$PS" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read(); ps = int(sys.argv[2])
for pno in range(len(data)// ps):
    p = data[pno*ps:(pno+1)*ps]
    if p[0] == 6 and struct.unpack_from("<H", p, 16)[0] == 128:
        cnt = struct.unpack_from("<H", p, 18)[0]
        for i in range(cnt):
            at = 24 + i*24
            root = struct.unpack_from("<I", p, at+8)[0]
            if root == 0:
                continue
            desc = struct.unpack_from("<H", p, at+16)[0]
            keys = p[at+21]
            sels = [round(struct.unpack_from("<f", p, desc+s*8+4)[0], 6) for s in range(keys)]
            print("slot %d: %s" % (i, sels))
PY
}
check "the index-root descriptors' selectivity floats match" \
      "$(descs "$WORK")" "$(descs "$REF")"
case "$(descs "$WORK")" in
    *0.166667*) echo "OK   the descriptor floats really carry the recomputed value" ;;
    *) echo "DIFF the descriptor comparison was vacuous"; fail=1 ;;
esac

# --- 4. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-ss-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-ss-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-ss-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-ss-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-ss-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
