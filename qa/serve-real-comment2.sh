#!/bin/bash
# COMMENT ON INDEX / SEQUENCE - the same description a table carries, on
# the other schema objects fire-crab can create.
#
# A comment is a TEXT BLOB written into the commented object's OWN catalog
# relation - here RDB$INDICES for an index and RDB$GENERATORS for a
# sequence - and its id stored in that row's RDB$DESCRIPTION. As for a
# table, COMMENT ON ... IS NULL (and IS '') clears the column to NULL,
# orphaning the old blob, and the description blob carries blh_charset = 4
# (UTF8, the metadata charset), not the 1 the binary metadata blobs use.
# SEQUENCE and GENERATOR are synonyms; both land in RDB$GENERATORS.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine apply the same COMMENT ON statements on
#      two copies of one database; every RDB$DESCRIPTION is read back as
#      text (through the engine's CAST) and compared;
#   2. the index's description blob RECORD is read off both files and
#      compared byte for byte - header, charset and segment framing;
#   3. clearing a comment (IS NULL and IS '') leaves the column NULL on
#      both;
#   4. an unknown index and an unknown sequence are refused on both;
#   5. gbak round trip (the '' escape survives) and gfix -v -full on
#      fire-crab's raw file.
#
#   qa/serve-real-comment2.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4156}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-cmt2-src.fdb"; WORK="$D/fc-cmt2-work.fdb"; REF="$D/fc-cmt2-ref.fdb"
FBK="$D/fc-cmt2-work.fbk"; RST="$D/fc-cmt2-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

# statements applied to both - an index comment, a sequence comment (one
# via the GENERATOR synonym, with a '' escape), then a clear of each kind
C_IX="COMMENT ON INDEX IX_T IS 'the A index'"
C_S1="COMMENT ON SEQUENCE S1 IS 'a plain counter'"
C_S2="COMMENT ON GENERATOR S2 IS 'gen S2, it''s a synonym'"
CLR_IX="COMMENT ON INDEX IX_T IS NULL"
CLR_S1="COMMENT ON SEQUENCE S1 IS ''"
# refused by both
R_IX="COMMENT ON INDEX NOSUCH IS 'x'"
R_SEQ="COMMENT ON SEQUENCE NOSUCH IS 'x'"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B VARCHAR(10));
CREATE INDEX IX_T ON T (A);
CREATE SEQUENCE S1;
CREATE SEQUENCE S2;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
# the reference gets the SET comments only (the clears run later, so the
# byte-for-byte blob comparison has live blobs to compare)
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$C_IX; $C_S1; $C_S2;
COMMIT;
EOF
eng_rix=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_IX;
EOF
)
eng_rseq=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_SEQ;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cmt2.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

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

check "COMMENT ON INDEX IX_T"        "$(node_run "$C_IX")" "OK"
check "COMMENT ON SEQUENCE S1"       "$(node_run "$C_S1")" "OK"
check "COMMENT ON GENERATOR S2 (synonym, with a '' escape)" "$(node_run "$C_S2")" "OK"
# refusals
r=$(node_run "$R_IX")
case "$r" in ERR*) echo "OK   an unknown index is refused" ;;
    *) echo "DIFF unknown index accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$R_SEQ")
case "$r" in ERR*) echo "OK   an unknown sequence is refused" ;;
    *) echo "DIFF unknown sequence accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rix" in *[Ee]rror*|*"not found"*|*"not exist"*) echo "OK   the engine refuses the unknown index too" ;;
    *) echo "DIFF engine did not refuse unknown index"; echo "     $eng_rix"; fail=1 ;; esac
case "$eng_rseq" in *[Ee]rror*|*"not found"*|*"not exist"*) echo "OK   the engine refuses the unknown sequence too" ;;
    *) echo "DIFF engine did not refuse unknown sequence"; echo "     $eng_rseq"; fail=1 ;; esac

# --- 1. the comments, read back as text --------------------------------
cmq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'IX|'||TRIM(RDB$INDEX_NAME)||'|'||COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)),'<null>')
  FROM RDB$INDICES WHERE RDB$INDEX_NAME = 'IX_T';
SELECT 'GEN|'||TRIM(RDB$GENERATOR_NAME)||'|'||COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)),'<null>')
  FROM RDB$GENERATORS WHERE RDB$GENERATOR_NAME IN ('S1','S2') ORDER BY RDB$GENERATOR_NAME;
SQL
}
work_cm=$(cmq "$WORK")
check "the comments read back identical to the engine's" "$work_cm" "$(cmq "$REF")"
case "$work_cm" in
    *"IX|IX_T|the A index"*"GEN|S2|gen S2, it's a synonym"*)
        echo "OK   the compared text really carries the comments (incl. the '' escape)" ;;
    *) echo "DIFF the comment comparison was vacuous"; echo "     $work_cm"; fail=1 ;;
esac

# --- 2. the description blob record, byte for byte ---------------------
# read the 30 header+framing bytes preceding the known comment text
blobhdr() { # <file> <needle>
    python3 - "$1" "$2" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
needle = sys.argv[2].encode()
i = data.find(needle)
print("NOT FOUND" if i < 0 else " ".join(str(b) for b in data[i-30:i]))
PY
}
check "the index's description blob record matches byte for byte" \
      "$(blobhdr "$WORK" "the A index")" "$(blobhdr "$REF" "the A index")"
case "$(blobhdr "$WORK" "the A index")" in
    *" 4 0 "*) echo "OK   the blob carries blh_charset = 4 (UTF8), not the binary-blob 1" ;;
    *) echo "DIFF the description blob charset"; echo "     $(blobhdr "$WORK" "the A index")"; fail=1 ;;
esac

# --- 3. clearing a comment ---------------------------------------------
check "COMMENT ON INDEX IX_T IS NULL clears it"  "$(node_run "$CLR_IX")" "OK"
check "COMMENT ON SEQUENCE S1 IS '' clears it"   "$(node_run "$CLR_S1")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$CLR_IX; $CLR_S1;
COMMIT;
EOF
cleared() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'IX|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$INDICES WHERE RDB$INDEX_NAME = 'IX_T';
SELECT 'S1|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$GENERATORS WHERE RDB$GENERATOR_NAME = 'S1';
SELECT 'S2|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$GENERATORS WHERE RDB$GENERATOR_NAME = 'S2';
SQL
}
work_cleared=$(cleared "$WORK")
check "the cleared columns are NULL, the untouched one still set" "$work_cleared" "$(cleared "$REF")"
case "$work_cleared" in
    *"IX|null"*"S1|null"*"S2|set"*) echo "OK   IX_T and S1 are cleared to NULL, S2's comment survives" ;;
    *) echo "DIFF the clear did not land as expected"; echo "     $work_cleared"; fail=1 ;;
esac

# --- 5. gbak (the '' escape survives) and gfix -------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-cmt2-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-cmt2-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-cmt2-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-cmt2-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-cmt2-restore.log | head; fail=1
fi
rst_s2=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(60)) FROM RDB$GENERATORS
  WHERE RDB$GENERATOR_NAME = 'S2';
SQL
)
check "S2's comment (with its '' escape) survives the round trip" "$rst_s2" "gen S2, it's a synonym"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
