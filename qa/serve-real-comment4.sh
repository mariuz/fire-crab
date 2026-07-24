#!/bin/bash
# COMMENT ON DOMAIN - the description mechanism on a user-defined domain.
#
# A comment is a TEXT BLOB written into the commented object's OWN catalog
# relation - here RDB$FIELDS, the same relation that holds the domain itself -
# with its id stored in that row's RDB$DESCRIPTION. As everywhere, IS NULL
# (and IS '') clears the column to NULL, and the description blob carries
# blh_charset = 4 (UTF8, the metadata charset), not the 1 the binary metadata
# blobs use. A system field (RDB$/SQL$) is read-only.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine apply the same COMMENT ON statements on two
#      copies of one database; every RDB$DESCRIPTION is read back as text and
#      compared;
#   2. the domain's description blob RECORD is read off both files and
#      compared byte for byte (framing and charset);
#   3. clearing a comment (IS NULL and IS '') leaves the column NULL on both;
#   4. an unknown domain is refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-comment4.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4183}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-cmt4-src.fdb"; WORK="$D/fc-cmt4-work.fdb"; REF="$D/fc-cmt4-ref.fdb"
FBK="$D/fc-cmt4-work.fbk"; RST="$D/fc-cmt4-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

C_E="COMMENT ON DOMAIN DOM_EMAIL IS 'an email, it''s a string'"
CLR_E="COMMENT ON DOMAIN DOM_EMAIL IS NULL"
C_C="COMMENT ON DOMAIN DOM_CODE IS 'a code'"
CLR_C="COMMENT ON DOMAIN DOM_CODE IS ''"
R_DOM="COMMENT ON DOMAIN NOSUCH IS 'x'"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE DOMAIN DOM_EMAIL AS VARCHAR(50);
CREATE DOMAIN DOM_CODE AS INTEGER;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$C_E; $C_C;
COMMIT;
EOF
eng_rdom=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_DOM;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cmt4.log 2>&1 &
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

check "COMMENT ON DOMAIN DOM_EMAIL (with '' escape)" "$(node_run "$C_E")" "OK"
check "COMMENT ON DOMAIN DOM_CODE"                   "$(node_run "$C_C")" "OK"
r=$(node_run "$R_DOM")
case "$r" in ERR*) echo "OK   an unknown domain is refused" ;;
    *) echo "DIFF unknown domain accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rdom" in *[Ee]rror*|*"not found"*|*"not defined"*) echo "OK   the engine refuses the unknown domain too" ;;
    *) echo "DIFF engine did not refuse unknown domain"; echo "     $eng_rdom"; fail=1 ;; esac

# --- 1. the comments, read back as text --------------------------------
cmq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)),'<null>')
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME IN ('DOM_EMAIL','DOM_CODE') ORDER BY RDB$FIELD_NAME;
SQL
}
work_cm=$(cmq "$WORK")
check "the comments read back identical to the engine's" "$work_cm" "$(cmq "$REF")"
case "$work_cm" in
    *"DOM_CODE|a code"*"DOM_EMAIL|an email, it's a string"*)
        echo "OK   the compared text really carries the comments (incl. the '' escape)" ;;
    *) echo "DIFF the comment comparison was vacuous"; echo "     $work_cm"; fail=1 ;;
esac

# --- 2. the description blob record, byte for byte ---------------------
blobhdr() { # <file> <needle>
    python3 - "$1" "$2" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
needle = sys.argv[2].encode()
i = data.find(needle)
print("NOT FOUND" if i < 0 else " ".join(str(b) for b in data[i-30:i]))
PY
}
check "the domain's description blob record matches byte for byte" \
      "$(blobhdr "$WORK" "an email, it's a string")" "$(blobhdr "$REF" "an email, it's a string")"
case "$(blobhdr "$WORK" "an email, it's a string")" in
    *" 4 0 "*) echo "OK   the blob carries blh_charset = 4 (UTF8), not the binary-blob 1" ;;
    *) echo "DIFF the description blob charset"; echo "     $(blobhdr "$WORK" "an email, it's a string")"; fail=1 ;;
esac

# --- 3. clearing a comment ---------------------------------------------
check "COMMENT ON DOMAIN DOM_EMAIL IS NULL clears it" "$(node_run "$CLR_E")" "OK"
check "COMMENT ON DOMAIN DOM_CODE IS '' clears it"    "$(node_run "$CLR_C")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$CLR_E; $CLR_C;
COMMIT;
EOF
cleared() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$FIELD_NAME)||'|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$FIELDS WHERE RDB$FIELD_NAME IN ('DOM_EMAIL','DOM_CODE') ORDER BY RDB$FIELD_NAME;
SQL
}
work_cleared=$(cleared "$WORK")
check "the cleared descriptions are NULL on both" "$work_cleared" "$(cleared "$REF")"
case "$work_cleared" in
    *"DOM_CODE|null"*"DOM_EMAIL|null"*) echo "OK   both domain descriptions are cleared to NULL" ;;
    *) echo "DIFF the clear did not land as expected"; echo "     $work_cleared"; fail=1 ;;
esac

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-cmt4-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-cmt4-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-cmt4-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-cmt4-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-cmt4-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
