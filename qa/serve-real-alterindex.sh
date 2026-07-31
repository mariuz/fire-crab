#!/bin/bash
# ALTER INDEX <name> ACTIVE | INACTIVE - the third user of the engine's
# deferred index removal, and the first REBUILD.
#
# INACTIVE is the deferred drop minus the catalog teardown: the
# index-root slot moves to the drop states with its pages (so the tree is
# still MAINTAINED - serve-real-dropindex.sh) while setDrop's cleared
# irt_unique|irt_primary|irt_foreign stop it ENFORCING, and the
# RDB$INDICES row keeps its name, its id and its segments with only
# RDB$INDEX_INACTIVE moving to 1. An inactive UNIQUE index therefore
# accepts duplicates.
#
# ACTIVE REBUILDS. AlterIndexNode::step2 tries to undo the delete first,
# but once the deactivating transaction has committed that is refused and
# the index is built from scratch - engine probe: even inside one isql
# session RDB$INDEX_ID moves on, the old slot stays in the drop state
# with its pages, and a NEW slot carries a fresh tree. The rebuild also
# recomputes the SELECTIVITY, which the engine keeps in three places at
# once: the irtd_selectivity float of each segment descriptor on the
# index root page, RDB$INDEX_SEGMENTS.RDB$STATISTICS per key prefix, and
# RDB$INDICES.RDB$STATISTICS for the whole key. fire-crab now computes it
# (1 / distinct over the committed rows, a NULL key counting as a key) on
# every index build, CREATE INDEX included - which this gate compares.
#
# The differential is the engine, five ways:
#   1. fire-crab and the engine build the same schema and run the same
#      statements; RDB$INDICES, RDB$INDEX_SEGMENTS (both with their
#      STATISTICS) and the index-root slots are compared;
#   2. the OPTIMIZER agrees: on fire-crab's raw file the engine reads the
#      deactivated index's column NATURAL and PLANs through the
#      reactivated one, exactly as on its own file - and the rebuilt
#      index finds the row that was inserted WHILE IT WAS INACTIVE;
#   3. an inactive UNIQUE index does not enforce (a duplicate goes in on
#      both files) while the PRIMARY KEY still does;
#   4. the refusals: a constraint's index cannot be deactivated, an
#      unknown index errors, and reactivating a unique index over the
#      duplicates admitted while it was inactive fails - on both, leaving
#      the catalogs still identical;
#   5. gbak round trip and gfix -v -full on fire-crab's raw file.
#
#   qa/serve-real-alterindex.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4147}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-alteri-work.fdb"; REF="$D/fc-alteri-ref.fdb"
FBK="$D/fc-alteri-work.fbk"; RST="$D/fc-alteri-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

# the schema and the statements, applied in this order to both copies
DDL_T="CREATE TABLE T (A INTEGER NOT NULL, B VARCHAR(10), C INTEGER, CONSTRAINT PK_T PRIMARY KEY (A))"
DDL_IB="CREATE INDEX IX_TB ON T (B)"
DDL_IC="CREATE UNIQUE INDEX IX_TC ON T (C)"
DDL_IBC="CREATE INDEX IX_TBC ON T (B, C)"
INS_1="INSERT INTO T VALUES (1, 'x', 10)"
INS_2="INSERT INTO T VALUES (2, 'x', 20)"
INS_3="INSERT INTO T VALUES (3, 'y', 30)"
INS_4="INSERT INTO T VALUES (4, NULL, 40)"
OFF_B="ALTER INDEX IX_TB INACTIVE"
INS_5="INSERT INTO T VALUES (5, 'z', 50)"
ON_B="ALTER INDEX IX_TB ACTIVE"
OFF_C="ALTER INDEX IX_TC INACTIVE"
INS_6="INSERT INTO T VALUES (6, 'z', 10)"
# refused by both
R_PK="ALTER INDEX PK_T INACTIVE"
R_UNK="ALTER INDEX NO_SUCH_INDEX INACTIVE"
R_DUP="ALTER INDEX IX_TC ACTIVE"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
# the reference: the engine builds and runs everything itself
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_T;
$DDL_IB;
$DDL_IC;
COMMIT;
$INS_1; $INS_2; $INS_3; $INS_4;
COMMIT;
$DDL_IBC;
COMMIT;
$OFF_B;
COMMIT;
$INS_5;
COMMIT;
$ON_B;
COMMIT;
$OFF_C;
COMMIT;
$INS_6;
COMMIT;
EOF
# the engine's refusals, captured on the reference in its final state
eng_pk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL
$R_PK;
SQL
)
eng_unk=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL
$R_UNK;
SQL
)
eng_dup=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<SQL
$R_DUP;
SQL
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-alteri.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
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
refused() { # <label> <got>
    case "$2" in
        ERR*) echo "OK   $1" ;;
        *) echo "DIFF $1"; echo "     got:  $2"; fail=1 ;;
    esac
}

# --- fire-crab builds the same schema and runs the same statements -----
check "create T with a PRIMARY KEY"        "$(node_run "$DDL_T")" "OK"
check "create IX_TB"                       "$(node_run "$DDL_IB")" "OK"
check "create UNIQUE IX_TC"                "$(node_run "$DDL_IC")" "OK"
for q in "$INS_1" "$INS_2" "$INS_3" "$INS_4"; do
    check "insert row"                     "$(node_run "$q")" "OK"
done
# built over rows, so its selectivity is computed at CREATE INDEX time
check "create two-segment IX_TBC over the rows" "$(node_run "$DDL_IBC")" "OK"
check "ALTER INDEX IX_TB INACTIVE"         "$(node_run "$OFF_B")" "OK"
check "insert WHILE the index is inactive" "$(node_run "$INS_5")" "OK"
check "ALTER INDEX IX_TB ACTIVE (rebuild)" "$(node_run "$ON_B")" "OK"
check "ALTER INDEX IX_TC INACTIVE"         "$(node_run "$OFF_C")" "OK"
# --- 3. an inactive UNIQUE index does not enforce ----------------------
check "a duplicate goes in under the inactive UNIQUE index" "$(node_run "$INS_6")" "OK"
dup_pk=$(node_run "INSERT INTO T VALUES (1, 'q', 99)")
refused "the PRIMARY KEY still enforces itself" "$dup_pk"

# --- 4. the refusals ---------------------------------------------------
refused "a constraint's index cannot be deactivated" "$(node_run "$R_PK")"
refused "an unknown index name errors"               "$(node_run "$R_UNK")"
refused "reactivating over the duplicates fails"     "$(node_run "$R_DUP")"
case "$eng_pk" in
    *"deactivate index used by"*) echo "OK   the engine refuses the constraint's index too" ;;
    *) echo "DIFF engine did not refuse the constraint index"; echo "     $eng_pk"; fail=1 ;;
esac
case "$eng_unk" in
    *"not found"*) echo "OK   the engine refuses the unknown index too" ;;
    *) echo "DIFF engine did not refuse the unknown index"; echo "     $eng_unk"; fail=1 ;;
esac
case "$eng_dup" in
    *"duplicate"*) echo "OK   the engine refuses the reactivation too (duplicate value)" ;;
    *) echo "DIFF engine did not refuse the reactivation"; echo "     $eng_dup"; fail=1 ;;
esac

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 1. catalogs (with the statistics) and index-root slots ------------
catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'IDX|'||TRIM(RDB$INDEX_NAME)||'|'||COALESCE(RDB$UNIQUE_FLAG,-1)||'|'
       ||COALESCE(RDB$INDEX_INACTIVE,-1)||'|'
       ||CASE WHEN RDB$INDEX_NAME = 'IX_TB' THEN 'rebuilt'
              ELSE CAST(COALESCE(RDB$INDEX_ID,-1) AS VARCHAR(8)) END||'|'
       ||RDB$SEGMENT_COUNT||'|'||COALESCE(CAST(RDB$STATISTICS AS NUMERIC(9,6)),-99)
  FROM RDB$INDICES WHERE RDB$RELATION_NAME = 'T' ORDER BY RDB$INDEX_NAME;
SELECT 'SEG|'||TRIM(S.RDB$INDEX_NAME)||'|'||S.RDB$FIELD_POSITION||'|'||TRIM(S.RDB$FIELD_NAME)
       ||'|'||COALESCE(CAST(S.RDB$STATISTICS AS NUMERIC(9,6)),-99)
  FROM RDB$INDEX_SEGMENTS S JOIN RDB$INDICES I ON I.RDB$INDEX_NAME = S.RDB$INDEX_NAME
  WHERE I.RDB$RELATION_NAME = 'T' ORDER BY S.RDB$INDEX_NAME, S.RDB$FIELD_POSITION;
SELECT 'ROW|'||A||'|'||COALESCE(B,'-')||'|'||COALESCE(C,-1) FROM T ORDER BY A;
SQL
}
work_cat=$(catq "$WORK")
check "catalog (with RDB\$STATISTICS) matches the engine reference" "$work_cat" "$(catq "$REF")"
# teeth: the compared catalog really carries computed selectivities, not
# a column of nulls on both sides
case "$work_cat" in
    *"SEG|IX_TBC|0|B|0.333333"*"SEG|IX_TBC|1|C|0.250000"*)
        echo "OK   CREATE INDEX computed a selectivity PER KEY PREFIX (1/3 then 1/4)" ;;
    *) echo "DIFF per-prefix segment statistics"; echo "     $work_cat"; fail=1 ;;
esac
# IX_TB was built over an empty table (selectivity 0, as on the engine)
# and REBUILT over five rows with four distinct keys
case "$work_cat" in
    *"IDX|IX_TB|0|0|rebuilt|1|0.250000"*)
        echo "OK   the REBUILD recomputed the selectivity (0 at create, 1/4 now)" ;;
    *) echo "DIFF the rebuild's selectivity"; echo "     $work_cat"; fail=1 ;;
esac
if [ -x "$FCSTAT" ]; then
    # states 2 and 3 are one lifecycle point either side of the engine's
    # settling (a fresh index idles at 2 until touched), and 5/6 are the
    # same for a slot on its way out - classified, not compared
    slots() { # <file> <state class>
        "$FCSTAT" indexes "$1" 128 2>/dev/null |
            sed -e 's/.*index [0-9]*: root page [0-9]*, \([0-9]*\) key(s), state \([0-9]*\).*/keys=\1 state=\2/' |
            sed -e 's/state=[56]$/state=deferred-drop/' -e 's/state=[23]$/state=live/' |
            grep "state=$2" | sort
    }
    # the LIVE slots - one per index the engine will actually use - must
    # match. The slots on their way OUT must not: whether a deactivated
    # index's pages have been released yet is the engine's background
    # work, and fire-crab writes the statement-time state (the deferred
    # drop of serve-real-dropindex.sh)
    check "the live index-root slots match" "$(slots "$WORK" live)" "$(slots "$REF" live)"
    check "  ... three of them (PK_T, the rebuilt IX_TB, IX_TBC)" \
          "$(slots "$WORK" live | wc -l)" "3"
    case "$(slots "$WORK" deferred-drop)" in
        "") echo "DIFF fire-crab left no deferred-drop slot behind"; fail=1 ;;
        *) echo "OK   the deactivated index's slot is in the drop states, pages kept" ;;
    esac
else
    echo "SKIP fcstat not built - index-root slot comparison"
fi

# --- 2. the optimizer, on fire-crab's raw file -------------------------
planq() { # <file> <query>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | grep -i '^PLAN' | strip
SET PLAN ON;
$2;
SQL
}
check "the engine PLANs through the REACTIVATED index" \
      "$(planq "$WORK" "SELECT COUNT(*) FROM T WHERE B = 'z'")" \
      "$(planq "$REF"  "SELECT COUNT(*) FROM T WHERE B = 'z'")"
case "$(planq "$WORK" "SELECT COUNT(*) FROM T WHERE B = 'z'")" in
    *INDEX*) echo "OK   that plan really is an index plan (not both NATURAL)" ;;
    *) echo "DIFF the reactivated index is unused - the comparison was vacuous"; fail=1 ;;
esac
check "the engine reads the DEACTIVATED index's column NATURAL" \
      "$(planq "$WORK" "SELECT COUNT(*) FROM T WHERE C = 40")" \
      "$(planq "$REF"  "SELECT COUNT(*) FROM T WHERE C = 40")"
# the rebuilt index finds the row inserted while it was inactive
rowq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT A FROM T WHERE B = 'z' ORDER BY A;
SQL
}
check "the rebuilt index finds the row inserted while it was inactive" \
      "$(rowq "$WORK")" "$(rowq "$REF")"
case "$(rowq "$WORK" | tr -s ' \n' ' ' | strip)" in
    "5 6") echo "OK   both rows keyed 'z' come back (5 was inserted while inactive)" ;;
    *) echo "DIFF rows keyed 'z'"; echo "     got: $(rowq "$WORK")"; fail=1 ;;
esac

# --- 3b. the engine agrees about enforcement on fire-crab's file -------
enfq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | grep -ciE "violat|duplicate"
INSERT INTO T VALUES (7, 'q', 10);
INSERT INTO T VALUES (1, 'q', 70);
ROLLBACK;
SQL
}
check "the engine enforces the same way on both files (PK yes, inactive UNIQUE no)" \
      "$(enfq "$WORK")" "$(enfq "$REF")"
check "  ... and that is exactly one refusal (the PK)" "$(enfq "$WORK")" "1"

# --- 5. gbak and gfix --------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-alteri-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-alteri-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-alteri-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-alteri-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-alteri-restore.log | head; fail=1
fi
rstq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT TRIM(RDB$INDEX_NAME)||'|'||COALESCE(RDB$INDEX_INACTIVE,-1)
  FROM RDB$INDICES WHERE RDB$RELATION_NAME = 'T' ORDER BY 1;
SQL
}
check "the restored copy keeps the inactive index inactive" "$(rstq "$RST")" "$(rstq "$REF")"
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""
valr=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$valr" | strip)" ""

exit $fail
