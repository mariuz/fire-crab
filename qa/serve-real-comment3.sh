#!/bin/bash
# COMMENT ON EXCEPTION / ROLE - the same description mechanism, on the two
# security objects fire-crab now creates.
#
# A comment is a TEXT BLOB written into the commented object's OWN catalog
# relation - RDB$EXCEPTIONS for an exception, RDB$ROLES for a role - with
# its id stored in that row's RDB$DESCRIPTION. As everywhere, IS NULL (and
# IS '') clears the column to NULL, and the description blob carries
# blh_charset = 4 (UTF8, the metadata charset), not the 1 the binary
# metadata blobs use.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine apply the same COMMENT ON statements on
#      two copies of one database; every RDB$DESCRIPTION is read back as
#      text and compared;
#   2. the exception's description blob RECORD is read off both files and
#      compared byte for byte;
#   3. clearing a comment (IS NULL and IS '') leaves the column NULL on
#      both;
#   4. an unknown exception and an unknown role are refused on both;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-comment3.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4160}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-cmt3-src.fdb"; WORK="$D/fc-cmt3-work.fdb"; REF="$D/fc-cmt3-ref.fdb"
FBK="$D/fc-cmt3-work.fbk"; RST="$D/fc-cmt3-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

C_E="COMMENT ON EXCEPTION E_ONE IS 'describes the exception'"
C_R="COMMENT ON ROLE MANAGER IS 'the manager role, it''s important'"
CLR_E="COMMENT ON EXCEPTION E_ONE IS NULL"
CLR_R="COMMENT ON ROLE MANAGER IS ''"
R_EXC="COMMENT ON EXCEPTION NOSUCH IS 'x'"
R_ROLE="COMMENT ON ROLE NOSUCH IS 'x'"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE EXCEPTION E_ONE 'the first exception';
CREATE ROLE MANAGER;
CREATE ROLE AUDITOR;
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$C_E; $C_R;
COMMIT;
EOF
eng_rexc=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_EXC;
EOF
)
eng_rrole=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R_ROLE;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cmt3.log 2>&1 &
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

check "COMMENT ON EXCEPTION E_ONE"                "$(node_run "$C_E")" "OK"
check "COMMENT ON ROLE MANAGER (with '' escape)"  "$(node_run "$C_R")" "OK"
r=$(node_run "$R_EXC")
case "$r" in ERR*) echo "OK   an unknown exception is refused" ;;
    *) echo "DIFF unknown exception accepted"; echo "     $r"; fail=1 ;; esac
r=$(node_run "$R_ROLE")
case "$r" in ERR*) echo "OK   an unknown role is refused" ;;
    *) echo "DIFF unknown role accepted"; echo "     $r"; fail=1 ;; esac
case "$eng_rexc" in *[Ee]rror*|*"not found"*) echo "OK   the engine refuses the unknown exception too" ;;
    *) echo "DIFF engine did not refuse unknown exception"; echo "     $eng_rexc"; fail=1 ;; esac
case "$eng_rrole" in *[Ee]rror*|*"not found"*) echo "OK   the engine refuses the unknown role too" ;;
    *) echo "DIFF engine did not refuse unknown role"; echo "     $eng_rrole"; fail=1 ;; esac

# --- 1. the comments, read back as text --------------------------------
cmq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'EXC|'||COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)),'<null>')
  FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME = 'E_ONE';
SELECT 'ROLE|'||TRIM(RDB$ROLE_NAME)||'|'||COALESCE(CAST(RDB$DESCRIPTION AS VARCHAR(60)),'<null>')
  FROM RDB$ROLES WHERE RDB$ROLE_NAME IN ('MANAGER','AUDITOR') ORDER BY RDB$ROLE_NAME;
SQL
}
work_cm=$(cmq "$WORK")
check "the comments read back identical to the engine's" "$work_cm" "$(cmq "$REF")"
case "$work_cm" in
    *"EXC|describes the exception"*"ROLE|MANAGER|the manager role, it's important"*)
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
check "the exception's description blob record matches byte for byte" \
      "$(blobhdr "$WORK" "describes the exception")" "$(blobhdr "$REF" "describes the exception")"
case "$(blobhdr "$WORK" "describes the exception")" in
    *" 4 0 "*) echo "OK   the blob carries blh_charset = 4 (UTF8), not the binary-blob 1" ;;
    *) echo "DIFF the description blob charset"; echo "     $(blobhdr "$WORK" "describes the exception")"; fail=1 ;;
esac

# --- 3. clearing a comment ---------------------------------------------
check "COMMENT ON EXCEPTION E_ONE IS NULL clears it" "$(node_run "$CLR_E")" "OK"
check "COMMENT ON ROLE MANAGER IS '' clears it"      "$(node_run "$CLR_R")" "OK"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$CLR_E; $CLR_R;
COMMIT;
EOF
cleared() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'EXC|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME = 'E_ONE';
SELECT 'MANAGER|'||CASE WHEN RDB$DESCRIPTION IS NULL THEN 'null' ELSE 'set' END
  FROM RDB$ROLES WHERE RDB$ROLE_NAME = 'MANAGER';
SQL
}
work_cleared=$(cleared "$WORK")
check "the cleared descriptions are NULL on both" "$work_cleared" "$(cleared "$REF")"
case "$work_cleared" in
    *"EXC|null"*"MANAGER|null"*) echo "OK   the exception and role descriptions are cleared to NULL" ;;
    *) echo "DIFF the clear did not land as expected"; echo "     $work_cleared"; fail=1 ;;
esac

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-cmt3-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-cmt3-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-cmt3-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-cmt3-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-cmt3-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
