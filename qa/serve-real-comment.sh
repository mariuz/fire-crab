#!/bin/bash
# COMMENT ON TABLE / COLUMN - the metadata description a schema carries.
#
# A comment is a TEXT BLOB written into the commented object's own
# catalog relation (RDB$RELATIONS for a table, RDB$RELATION_FIELDS for a
# column) and its id stored in that row's RDB$DESCRIPTION. COMMENT ON ...
# IS NULL - and, the engine's probe shows, IS '' - clears the column to
# NULL, orphaning the old blob exactly as the engine does.
#
# The one on-disk detail that matters is the blob's charset. A binary
# metadata blob (RDB$FORMATS, an ACL) carries blh_charset = 1; a text
# description carries 4 (UTF8, the metadata charset), and
# CAST(RDB$DESCRIPTION AS VARCHAR) decodes through the blob's OWN charset,
# so the two must agree or the text reads back wrong.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine apply the same COMMENT ON statements on
#      two copies of one database; every RDB$DESCRIPTION is read back as
#      text (through the engine's CAST) and compared;
#   2. the description blob RECORD is read off both files and compared
#      byte for byte - header, charset and segment framing;
#   3. clearing a comment (IS NULL and IS '') leaves the column NULL on
#      both;
#   4. an unknown table and an unknown column are refused on both;
#   5. gbak round trip (the '' escape survives) and gfix -v -full on
#      fire-crab's raw file.
#
#   qa/serve-real-comment.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4155}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-cmt-src.fdb"; WORK="$D/fc-cmt-work.fdb"; REF="$D/fc-cmt-ref.fdb"
FBK="$D/fc-cmt-work.fbk"; RST="$D/fc-cmt-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

# statements applied to both - a table comment, two column comments (one
# with a '' escape), then a clear of each kind
C_T="COMMENT ON TABLE T IS 'the T table'"
C_A="COMMENT ON COLUMN T.A IS 'column A here'"
C_B="COMMENT ON COLUMN T.B IS 'col B, it''s varchar'"
CLR_T="COMMENT ON TABLE T IS NULL"
CLR_A="COMMENT ON COLUMN T.A IS ''"
# refused by both
R_TBL="COMMENT ON TABLE NOSUCH IS 'x'"
R_COL="COMMENT ON COLUMN T.NOSUCH IS 'x'"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (A INTEGER, B VARCHAR(10), C INTEGER);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
# the reference gets the SET comments only (the clears run later, so the
# byte-for-byte blob comparison has live blobs to compare)
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$C_T; $C_A; $C_B;
COMMIT;
EOF
eng_rtbl=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_TBL;
EOF
)
eng_rcol=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_COL;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cmt.log 2>&1 &
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

check "COMMENT ON TABLE T"       "$(node_run "$C_T")" "OK"
check "COMMENT ON COLUMN T.A"    "$(node_run "$C_A")" "OK"
check "COMMENT ON COLUMN T.B (with a '' escape)" "$(node_run "$C_B")" "OK"
# refusals
r=$(node_run "$R_TBL")
case "$r" in ERR*) echo "OK   an unknown table is refused" ;;
    *) echo "DIFF unknown table accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$R_COL")
case "$r" in ERR*) echo "OK   an unknown column is refused" ;;
    *) echo "DIFF unknown column accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rtbl" in *"not found"*) echo "OK   the engine refuses the unknown table too" ;;
    *) echo "DIFF engine did not refuse unknown table"; echo "     $eng_rtbl"; fail=1 ;; esac
case "$eng_rcol" in *"does not exist"*) echo "OK   the engine refuses the unknown column too" ;;
    *) echo "DIFF engine did not refuse unknown column"; echo "     $eng_rcol"; fail=1 ;; esac

# --- 1. the comments, read back as text --------------------------------
cmq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'REL|'||COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)),'<null>')
  FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SELECT 'FLD|'||TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)),'<null>')
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'T' ORDER BY RDB$FIELD_POSITION;
SQL
}
work_cm=$(cmq "$WORK")
check "the comments read back identical to the engine's" "$work_cm" "$(cmq "$REF")"
case "$work_cm" in
    *"REL|the T table"*"FLD|B|col B, it's varchar"*)
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
check "the table's description blob record matches byte for byte" \
      "$(blobhdr "$WORK" "the T table")" "$(blobhdr "$REF" "the T table")"
case "$(blobhdr "$WORK" "the T table")" in
    *" 4 0 "*) echo "OK   the blob carries blh_charset = 4 (UTF8), not the binary-blob 1" ;;
    *) echo "DIFF the description blob charset"; echo "     $(blobhdr "$WORK" "the T table")"; fail=1 ;;
esac

# --- 3. clearing a comment ---------------------------------------------
check "COMMENT ON TABLE T IS NULL clears it"  "$(node_run "$CLR_T")" "OK"
check "COMMENT ON COLUMN T.A IS '' clears it" "$(node_run "$CLR_A")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$CLR_T; $CLR_A;
COMMIT;
EOF
cleared() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'REL|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'T';
SELECT 'A|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'T' AND RDB$FIELD_NAME = 'A';
SELECT 'B|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'T' AND RDB$FIELD_NAME = 'B';
SQL
}
work_cleared=$(cleared "$WORK")
check "the cleared columns are NULL, the untouched one still set" "$work_cleared" "$(cleared "$REF")"
case "$work_cleared" in
    *"REL|null"*"A|null"*"B|set"*) echo "OK   T and A are cleared to NULL, B's comment survives" ;;
    *) echo "DIFF the clear did not land as expected"; echo "     $work_cleared"; fail=1 ;;
esac

# --- 5. gbak (the '' escape survives) and gfix -------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-cmt-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-cmt-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-cmt-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-cmt-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-cmt-restore.log | head; fail=1
fi
rst_b=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(60)) FROM RDB$RELATION_FIELDS
  WHERE RDB$RELATION_NAME = 'T' AND RDB$FIELD_NAME = 'B';
SQL
)
check "B's comment (with its '' escape) survives the round trip" "$rst_b" "col B, it's varchar"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
