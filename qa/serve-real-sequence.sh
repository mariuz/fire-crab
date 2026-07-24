#!/bin/bash
# CREATE SEQUENCE / DROP SEQUENCE - the statements that MAKE a generator,
# the mirror of the generator writes (serve-real-genwrite.sh) that only
# set one.
#
# The interesting part is not the catalog row. A sequence's id is drawn
# from the MASTER generator - slot 0 of the generator vector, the
# nameless counter (constants.h:134) every metadata object id comes from
# - and storing the row makes vio.cpp:4657 draw a security class name
# from slot 1 (RDB$SECURITY_CLASS, the SQL$<n> counter), so CREATING a
# sequence writes two generator values before the new sequence has one of
# its own. Its own slot is then left holding `start - increment`, which
# is why the first NEXT VALUE FOR yields exactly START WITH. DROP takes
# the catalog rows (generator, security class, privileges) and leaves the
# VALUE behind: nothing zeroes the slot, nothing reclaims the id.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine run the same statements on two copies of
#      one database; the catalogs - RDB$GENERATORS, RDB$SECURITY_CLASSES,
#      RDB$USER_PRIVILEGES - are compared;
#   2. the GENERATOR PAGE is compared BYTE FOR BYTE: both counters, every
#      sequence's stored value, and the orphan the dropped sequence left;
#   3. the engine CONTINUES from fire-crab's file - one more CREATE
#      SEQUENCE by the engine on each copy must land the same id and the
#      same SQL$<n> class, which it can only do if fire-crab advanced the
#      counters exactly as the engine would have;
#   4. the refusals (a duplicate name, an unknown drop, a system
#      generator, INCREMENT BY 0) are refused by both;
#   5. gbak round trip, the first NEXT VALUE FOR, and gfix on fire-crab's
#      raw file.
#
#   qa/serve-real-sequence.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4139}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
PS=8192
D=/tmp/fbhandson
SRC="$D/fc-seq-src.fdb"; WORK="$D/fc-seq-work.fdb"; REF="$D/fc-seq-ref.fdb"
FBK="$D/fc-seq-work.fbk"; RST="$D/fc-seq-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$SRC" "$WORK" "$REF" "$FBK" "$RST"

# the statements, applied in this order to both copies
S1="CREATE SEQUENCE SEQ_A"
S2="CREATE SEQUENCE SEQ_B START WITH 100 INCREMENT BY 5"
S3="CREATE GENERATOR GEN_C"
S4="CREATE SEQUENCE SEQ_NEG START WITH -5 INCREMENT BY -1"
S5="SET GENERATOR SEQ_A TO 77"
S6="DROP SEQUENCE SEQ_A"
S7="DROP GENERATOR GEN_C"
S8="CREATE SEQUENCE SEQ_E"
# refused by both
R1="CREATE SEQUENCE SEQ_B"
R2="DROP SEQUENCE NO_SUCH_SEQ"
R3="DROP SEQUENCE RDB\$PROCEDURES"
R4="CREATE SEQUENCE SEQ_ZERO INCREMENT BY 0"

# one scratch database, copied - so the generator page starts identical
# and comparing it afterwards means something
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE $PS;
CREATE TABLE T (A INTEGER);
COMMIT;
EOF
cp "$SRC" "$WORK"; cp "$SRC" "$REF"

# the reference: the engine runs the statements itself
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$S1; $S2; $S3; $S4;
COMMIT;
$S5;
COMMIT;
$S6; $S7; $S8;
COMMIT;
EOF
# and refuses the four bad ones (captured before anything else runs)
eng_r1=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R1;
EOF
)
eng_r4=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF
$R4;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-seq.log 2>&1 &
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
refused() { # <label> <got>
    case "$2" in
        ERR*) echo "OK   $1" ;;
        *) echo "DIFF $1"; echo "     got:  $2"; fail=1 ;;
    esac
}

# --- fire-crab runs the same statements --------------------------------
check "CREATE SEQUENCE SEQ_A"                     "$(node_run "$S1")" "OK"
check "CREATE SEQUENCE SEQ_B START WITH/INCREMENT" "$(node_run "$S2")" "OK"
check "CREATE GENERATOR GEN_C (legacy spelling)"  "$(node_run "$S3")" "OK"
check "CREATE SEQUENCE SEQ_NEG (negative start and step)" "$(node_run "$S4")" "OK"
check "SET GENERATOR SEQ_A TO 77"                 "$(node_run "$S5")" "OK"
check "DROP SEQUENCE SEQ_A (a sequence with a value)" "$(node_run "$S6")" "OK"
check "DROP GENERATOR GEN_C"                      "$(node_run "$S7")" "OK"
check "CREATE SEQUENCE SEQ_E (after the drops)"   "$(node_run "$S8")" "OK"

# --- 4. the refusals ---------------------------------------------------
refused "a duplicate sequence name is refused"    "$(node_run "$R1")"
refused "dropping an unknown sequence is refused" "$(node_run "$R2")"
refused "dropping a SYSTEM generator is refused"  "$(node_run "$R3")"
refused "INCREMENT BY 0 is refused"               "$(node_run "$R4")"
case "$eng_r1" in
    *"already exists"*) echo "OK   the engine refuses the duplicate too" ;;
    *) echo "DIFF engine accepted the duplicate"; echo "     $eng_r1"; fail=1 ;;
esac
case "$eng_r4" in
    *"INCREMENT BY 0"*) echo "OK   the engine refuses INCREMENT BY 0 too" ;;
    *) echo "DIFF engine accepted INCREMENT BY 0"; echo "     $eng_r4"; fail=1 ;;
esac

# fire-crab reads its own new sequences back, through its own server
fc_show=$(node_run "SELECT RDB\$GENERATOR_NAME FROM RDB\$GENERATORS WHERE RDB\$SYSTEM_FLAG = 0")
check "the new catalog is readable through fire-crab" "$fc_show" "OK"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. the catalogs ---------------------------------------------------
catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'GEN|'||TRIM(RDB$GENERATOR_NAME)||'|'||RDB$GENERATOR_ID||'|'||RDB$SYSTEM_FLAG
       ||'|'||RDB$INITIAL_VALUE||'|'||RDB$GENERATOR_INCREMENT||'|'||TRIM(RDB$OWNER_NAME)
       ||'|'||TRIM(RDB$SECURITY_CLASS)||'|'||TRIM(RDB$SCHEMA_NAME)
  FROM RDB$GENERATORS WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 ORDER BY RDB$GENERATOR_NAME;
SELECT 'PRIV|'||TRIM(RDB$RELATION_NAME)||'|'||TRIM(RDB$USER)||'|'||TRIM(RDB$GRANTOR)
       ||'|'||TRIM(RDB$PRIVILEGE)||'|'||RDB$GRANT_OPTION||'|'||RDB$USER_TYPE
       ||'|'||RDB$OBJECT_TYPE||'|'||TRIM(RDB$RELATION_SCHEMA_NAME)
  FROM RDB$USER_PRIVILEGES WHERE RDB$OBJECT_TYPE = 14 ORDER BY RDB$RELATION_NAME;
SELECT 'CLASS|'||TRIM(C.RDB$SECURITY_CLASS) FROM RDB$SECURITY_CLASSES C
  JOIN RDB$GENERATORS G ON G.RDB$SECURITY_CLASS = C.RDB$SECURITY_CLASS
  WHERE COALESCE(G.RDB$SYSTEM_FLAG, 0) = 0 ORDER BY 1;
SELECT 'CLASSES|'||COUNT(*) FROM RDB$SECURITY_CLASSES;
SQL
}
work_cat=$(catq "$WORK")
check "catalog matches the engine reference" "$work_cat" "$(catq "$REF")"
# teeth: the comparison is not two empty outputs
case "$work_cat" in
    *"GEN|SEQ_B|"*"GEN|SEQ_E|"*) echo "OK   the compared catalog really lists the sequences" ;;
    *) echo "DIFF the catalog comparison was vacuous"; echo "     $work_cat"; fail=1 ;;
esac
# ... and the dropped sequence's id was NOT reused
reused=$(printf '%s\n' "$work_cat" | grep -c '^GEN|SEQ_E|14|')
check "the dropped sequence's id is not reused" "$reused" "0"

# the ACL blob the engine builds for the owner, byte for byte
aclq() { # <file>
    bid=$("$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<'SQL' | grep -oE '[0-9a-f]+:[0-9a-f]+' | head -1
SET LIST ON;
SELECT C.RDB$ACL FROM RDB$GENERATORS G JOIN RDB$SECURITY_CLASSES C
  ON C.RDB$SECURITY_CLASS = G.RDB$SECURITY_CLASS WHERE G.RDB$GENERATOR_NAME = 'SEQ_B';
SQL
)
    [ -n "$bid" ] || { echo "(no acl blob)"; return; }
    rm -f /tmp/fc-seq-acl.bin
    printf 'BLOBDUMP %s /tmp/fc-seq-acl.bin;\n' "$bid" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    od -An -tu1 -v /tmp/fc-seq-acl.bin | tr '\n' ' ' | tr -s ' ' | strip
}
work_acl=$(aclq "$WORK")
check "the owner's ACL blob matches the engine's" "$work_acl" "$(aclq "$REF")"
case "$work_acl" in
    "2 1 3 6 83 89 83 68 66 65 0 2 6 1 3 12 0 0") echo "OK   the ACL is the engine's own encoding (acl.h)" ;;
    *) echo "DIFF unexpected ACL encoding"; echo "     got:  $work_acl"; fail=1 ;;
esac

# --- 2. the generator page, byte for byte ------------------------------
genpage() { # <file> -> the page number of the first pag_ids page
    n=$(( $(wc -c < "$1") / PS )); i=0
    while [ $i -lt $n ]; do
        t=$(od -An -tu1 -j $((i * PS)) -N1 "$1" | tr -d ' ')
        [ "$t" = "9" ] && { echo "$i"; return; }
        i=$((i + 1))
    done
}
gw=$(genpage "$WORK"); gr=$(genpage "$REF")
check "the generator page is at the same page number" "$gw" "$gr"
if [ -n "$gw" ] && [ "$gw" = "$gr" ]; then
    # the VALUES, not the 24-byte page header: pag_generation counts how
    # often the page was written, which two writers reaching the same
    # state need not agree on
    dd if="$WORK" bs=$PS skip="$gw" count=1 2>/dev/null | tail -c +25 > /tmp/fc-seq-gw.bin
    dd if="$REF"  bs=$PS skip="$gr" count=1 2>/dev/null | tail -c +25 > /tmp/fc-seq-gr.bin
    if cmp -s /tmp/fc-seq-gw.bin /tmp/fc-seq-gr.bin; then
        echo "OK   the generator vector is byte-identical (counters, values, the dropped sequence's orphan)"
    else
        echo "DIFF generator vector"; cmp -l /tmp/fc-seq-gw.bin /tmp/fc-seq-gr.bin | head; fail=1
    fi
    # teeth: the page is not all zeroes - the values really are in there
    case "$(od -An -tu1 -v /tmp/fc-seq-gw.bin | tr -s ' \n' ' ' | tr -d ' ')" in
        *[1-9]*) echo "OK   the compared page carries real values" ;;
        *) echo "DIFF the generator page compare was vacuous"; fail=1 ;;
    esac
fi

# --- the values, read by the engine and by fire-crab -------------------
showq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SHOW SEQUENCES;
SQL
}
ref_show=$(showq "$REF")
check "the engine reads identical values from both files" "$(showq "$WORK")" "$ref_show"
case "$ref_show" in
    *"SEQ_B, current value: 95"*) echo "OK   SEQ_B stores start - increment (100 - 5)" ;;
    *) echo "DIFF SEQ_B's stored value"; echo "     $ref_show"; fail=1 ;;
esac

# fire-crab's own SHOW SEQUENCES over its own file, through fcwire
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >>/tmp/fc-serve-seq.log 2>&1 &
srv=$!
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
fc_show_cmd() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(timeout -s KILL 20 "$ISQL" -q -b -user "$U" -pas "$P" \
              "localhost/$PORT:$WORK" 2>&1 <<'SQL'
SHOW SEQUENCES;
SQL
)
        case "$r" in
            *08006*|*28000*|*"Unable to complete"*|*"connection rejected"*|"")
                n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r"; return ;;
        esac
    done
    printf '%s\n' "$r"
}
check "fire-crab reads back the sequences it created" \
      "$(fc_show_cmd | strip | grep -v '^$')" "$ref_show"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 3. the engine CONTINUES from fire-crab's file ---------------------
# one more CREATE SEQUENCE, by the engine, on each copy: same id and same
# SQL$<n> only if fire-crab advanced the master and security-class
# counters exactly as the engine would have
contq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 >/dev/null <<'SQL'
CREATE SEQUENCE SEQ_NEXT;
COMMIT;
SQL
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT RDB$GENERATOR_ID||'|'||TRIM(RDB$SECURITY_CLASS) FROM RDB$GENERATORS
  WHERE RDB$GENERATOR_NAME = 'SEQ_NEXT';
SQL
}
cont_w=$(contq "$WORK"); cont_r=$(contq "$REF")
check "the engine's next sequence lands identically (id and class)" "$cont_w" "$cont_r"
case "$cont_w" in
    *"|SQL\$"*) echo "OK   the continuation really allocated an id and a class" ;;
    *) echo "DIFF the continuation check was vacuous"; echo "     $cont_w"; fail=1 ;;
esac

# --- 5. gbak, the first NEXT VALUE FOR, and gfix -----------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-seq-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-seq-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-seq-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-seq-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-seq-restore.log | head; fail=1
fi
check "the restored copy carries the same sequences" "$(showq "$RST")" "$(showq "$WORK")"

nextq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT NEXT VALUE FOR SEQ_B FROM RDB$DATABASE;
SELECT NEXT VALUE FOR SEQ_NEG FROM RDB$DATABASE;
SELECT NEXT VALUE FOR SEQ_E FROM RDB$DATABASE;
SQL
}
next_w=$(nextq "$WORK")
check "the first NEXT VALUE FOR yields START WITH" "$next_w" "$(nextq "$REF")"
check "  ... and that value is the declared start" "$(printf '%s' "$next_w" | tr -s ' \n' ' ' | strip)" "100 -5 1"

valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
