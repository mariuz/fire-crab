#!/bin/bash
# THE LOGICAL BACKUP, first slice: a .fbk THE REAL gbak RESTORES.
#
# `isc_action_svc_backup` (fbsvcmgr's action_backup) writes the burp
# format - the attribute-list stream burp.h:133 documents, pinned here
# against a real FB6 file byte by byte before the writer existed. The
# oracle is the strongest available: fire-crab's backup of a database
# and the ENGINE's backup of THE SAME database are both restored by the
# REAL `gbak -c`, and the engine must read the same rows from both
# restored databases.
#
# THE SURFACE IS FAIL-CLOSED, and that is most of the point. A backup
# missing tables - or carrying a table where a view was - is worse than
# no backup: the client holds a file it believes is its data. So a
# database holding ANYTHING the writer cannot carry refuses the WHOLE
# backup: a sequence, a view, a trigger, a procedure, an exception, a
# UNIQUE / FOREIGN KEY / CHECK constraint. A PRIMARY KEY and plain or
# unique INDEXES ride the file (rec_index + the PRIMARY KEY
# rel_constraint). Each refusal is asserted here against the engine's
# success on the same database.
#
# RECORDED BOUNDARIES:
#   * `gbak -se` speaks an OLDER protocol (its command line rides the
#     version-3 ATTACH SPB with 0xff separators; op_service_start
#     carries a bare action byte) - carried, and gated on its own in
#     qa/serve-real-gbakse.sh; here one -b smoke check holds the seam;
#   * a VERBOSE request refuses rather than answering silence - the
#     gfix -v lesson (a report that cannot fail) applied before the
#     failure mode ships rather than after.
#
#   qa/serve-real-gbak.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
FBSVCMGR="${FBSVCMGR:-fbsvcmgr}"
PORT="${1:-4720}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-gbak-src.fdb"
LOG="/tmp/fc-serve-gbak-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$SRC" "$D"/fc-gbak-*.fbk "$D"/fc-gbak-r*.fdb "$D"/fc-gbak-b*.fdb
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE MIXED (S SMALLINT, I INTEGER, B BIGINT, C CHAR(7), V VARCHAR(15));
CREATE TABLE EMPTYT (X INTEGER);
COMMIT;
INSERT INTO MIXED VALUES (-5, 100000, 9000000000, 'abc', 'hello world');
INSERT INTO MIXED VALUES (NULL, NULL, NULL, NULL, NULL);
INSERT INTO MIXED VALUES (32767, -2147483648, -9223372036854775808, 'seven77', 'fifteen fifteen');
COMMIT;
EOF
chmod 666 "$SRC"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$D"/fc-gbak-*.fbk "$D"/fc-gbak-r*.fdb "$D"/fc-gbak-b*.fdb' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1 [$2]"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
svc_backup() { # <mgr> <db> <fbk> [extra...] -> "output|rc=N"
    local mgr=$1 db=$2 fbk=$3; shift 3
    local out rc
    out=$("$FBSVCMGR" "$mgr" user "$U" password "$P" action_backup dbname "$db" bkp_file "$fbk" "$@" 2>&1); rc=$?
    printf '%s|rc=%s' "$(printf '%s' "$out" | tr '\n' '|')" "$rc"
}
EMGR="localhost:service_mgr"
FMGR="127.0.0.1/$PORT:service_mgr"
grab() { sudo -n chmod 666 "$1" 2>/dev/null || chmod 666 "$1" 2>/dev/null || true; }
rows() { # <db file> - through the local embedded engine
    printf 'SET HEADING OFF;\nSELECT S, I, B, C, V FROM MIXED ORDER BY S NULLS FIRST;\nSELECT COUNT(*) FROM EMPTYT;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}

# --- 1. both servers back up THE SAME database; gbak -c restores both -------
check "fc action_backup succeeds silently" \
    "$(svc_backup "$FMGR" "$SRC" "$D/fc-gbak-f.fbk")" "|rc=0"
check "engine action_backup succeeds silently" \
    "$(svc_backup "$EMGR" "$SRC" "$D/fc-gbak-e.fbk")" "|rc=0"
grab "$D/fc-gbak-e.fbk"
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbak-f.fbk" "$D/fc-gbak-rf.fdb" >/dev/null 2>&1
check "the real gbak -c restores fire-crab's backup (rc)" "$?" "0"
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbak-e.fbk" "$D/fc-gbak-re.fdb" >/dev/null 2>&1
check "...and the engine's, for the comparison (rc)" "$?" "0"
chmod 666 "$D/fc-gbak-rf.fdb" "$D/fc-gbak-re.fdb" 2>/dev/null
check "the engine reads the SAME rows from both restored databases" \
    "$(rows "$D/fc-gbak-rf.fdb")" "$(rows "$D/fc-gbak-re.fdb")"
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$D/fc-gbak-rf.fdb" 2>&1 | tr -d ' \n')
if [ -z "$v" ]; then echo "OK   gfix -v -full accepts the database restored from fire-crab's backup"
else echo "DIFF gfix -v -full: [$v]"; fail=1; fi

# --- 2. the backup is point-in-time ------------------------------------------
printf 'INSERT INTO MIXED (S) VALUES (1);\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$SRC" >/dev/null 2>&1
rm -f "$D/fc-gbak-r2.fdb"
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbak-f.fbk" "$D/fc-gbak-r2.fdb" >/dev/null 2>&1
chmod 666 "$D/fc-gbak-r2.fdb" 2>/dev/null
got=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM MIXED;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-r2.fdb" 2>&1 | tr -d ' \n')
check "teeth: a row written after the backup is not in it" "$got" "3"

# --- 3. THE FAIL-CLOSED SURFACE: each refusal, against the engine's success --
refusal() { # <label> <ddl>
    local db="$D/fc-gbak-b$ran.fdb"
    rm -f "$db"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$db' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
$2
COMMIT;
EOF
    chmod 666 "$db"
    local fo eo
    fo=$(svc_backup "$FMGR" "$db" "$D/fc-gbak-x.fbk"); rm -f "$D/fc-gbak-x.fbk"
    eo=$(svc_backup "$EMGR" "$db" "$D/fc-gbak-y.fbk"); rm -f "$D/fc-gbak-y.fbk" 2>/dev/null
    sudo -n rm -f "$D/fc-gbak-y.fbk" 2>/dev/null
    ran=$((ran + 1))
    if [ "$fo" = "feature is not supported|rc=1" ] && [ "${eo##*rc=}" = "0" ]; then
        echo "OK   boundary: $1 refuses the whole backup (engine backs it up)"
    else
        echo "DIFF boundary: $1 - engine [$eo] fc [$fo]"; fail=1
    fi
    rm -f "$db"
}
# ~~a sequence refuses~~ - SEQUENCES RIDE THE FILE now (rec_generator,
# the value doubled the way backup.epp writes it); the carriage is
# proven by the ENGINE restoring fc's backup and reading the value
SEQDB="$D/fc-gbak-seq.fdb"; rm -f "$SEQDB" "$D/fc-gbak-seq.fbk" "$D/fc-gbak-seqr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$SEQDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
CREATE SEQUENCE G;
CREATE SEQUENCE H START WITH 500 INCREMENT BY 3;
COMMIT;
SELECT GEN_ID(G, 7) FROM RDB\$DATABASE;
COMMIT;
EOF
chmod 666 "$SEQDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$SEQDB" "$D/fc-gbak-seq.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a sequence RIDES the backup (fc backs it up)"
else
    echo "DIFF sequence backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-seq.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-seq.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-seqr.fdb" bkp_file "$D/fc-gbak-seq.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-seqr.fdb"
# two statements, not one row: two GEN_ID calls in one projection
# evaluate in an order the engine does not promise, and the +3 bump
# ran before the 0-read in the first version of this check
got=$(printf 'SET HEADING OFF;\nSELECT GEN_ID(G, 0), GEN_ID(H, 0) FROM RDB$DATABASE;\nSELECT GEN_ID(H, 3) FROM RDB$DATABASE;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-seqr.fdb" 2>&1 | tr -s ' \n' ' ')
if [ "$got" = " 7 497 500 " ]; then
    echo "OK   the ENGINE restores fc's sequences - value 7 kept, H's next draw is 500"
else
    echo "DIFF engine restore of fc's sequences: [$got] (want ' 7 497 500 ')"; fail=1
fi
rm -f "$SEQDB" "$D/fc-gbak-seq.fbk" "$D/fc-gbak-seqr.fdb"

# a PRIMARY KEY and plain/unique indexes RIDE THE FILE now (rec_index +
# the PRIMARY KEY rel_constraint) - what still refuses is the constraint
# kinds whose meaning is more than an index
# ~~UNIQUE and plain FOREIGN KEY refuse~~ - BOTH RIDE THE FILE now
# (rel_constraint + ref_constraint + the FK index with its partner
# att); proven by the ENGINE restoring fc's backup and ENFORCING both
CONSDB="$D/fc-gbak-cons.fdb"; rm -f "$CONSDB" "$D/fc-gbak-cons.fbk" "$D/fc-gbak-consr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$CONSDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE PARENT (ID INTEGER NOT NULL PRIMARY KEY, UX INTEGER NOT NULL, CONSTRAINT UQ_X UNIQUE (UX));
CREATE TABLE CHILD (PID INTEGER NOT NULL, X INTEGER CHECK (X > 0),
                    CONSTRAINT FK_C FOREIGN KEY (PID) REFERENCES PARENT (ID) ON DELETE CASCADE);
COMMIT;
INSERT INTO PARENT VALUES (1, 10);
INSERT INTO PARENT VALUES (2, 20);
INSERT INTO CHILD VALUES (1, 5);
INSERT INTO CHILD VALUES (2, 7);
COMMIT;
EOF
chmod 666 "$CONSDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$CONSDB" "$D/fc-gbak-cons.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   UNIQUE, FK (CASCADE rule) and CHECK all RIDE the backup (fc backs them up)"
else
    echo "DIFF constraint backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-cons.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-cons.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-consr.fdb" bkp_file "$D/fc-gbak-cons.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-consr.fdb"
viol=$(printf 'INSERT INTO PARENT VALUES (3, 10);\nINSERT INTO CHILD VALUES (99, 1);\nINSERT INTO CHILD VALUES (1, -5);\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$D/fc-gbak-consr.fdb" 2>&1 | grep -c "SQLSTATE = 23000")
if [ "$viol" = "3" ]; then
    echo "OK   the ENGINE restores fc's fbk and enforces ALL THREE (UNIQUE dup, dangling FK, CHECK violation)"
else
    echo "DIFF constraint enforcement after engine restore: 23000-count [$viol] (want 3)"; fail=1
fi
ran=$((ran + 1))
printf 'DELETE FROM PARENT WHERE ID = 2;\nCOMMIT;\n' | "$ISQL" -q -user "$U" -pas "$P" "$D/fc-gbak-consr.fdb" >/dev/null 2>&1
left=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM CHILD;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-consr.fdb" 2>&1 | tr -d ' \n')
if [ "$left" = "1" ]; then
    echo "OK   ... and the CASCADE fires through the carried trigger (parent 2's child went with it)"
else
    echo "DIFF cascade after engine restore: CHILD count [$left] (want 1)"; fail=1
fi
rm -f "$CONSDB" "$D/fc-gbak-cons.fbk" "$D/fc-gbak-consr.fdb"
# ~~a view refuses~~ / ~~a procedure refuses~~ - BOTH RIDE now: the
# view as its rec_relation with the BLR/source blobs and its fields'
# base/context links, the procedure as rec 27/28 with the blobs
# verbatim - proven by the ENGINE restoring fc's backup and running
# both
VPDB="$D/fc-gbak-vp.fdb"; rm -f "$VPDB" "$D/fc-gbak-vp.fbk" "$D/fc-gbak-vpr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$VPDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE VT (ID INTEGER, V VARCHAR(10));
COMMIT;
CREATE VIEW VV AS SELECT ID, V FROM VT WHERE ID > 1;
COMMIT;
SET TERM ^;
CREATE PROCEDURE PSUM (A INTEGER, B INTEGER) RETURNS (S INTEGER) AS BEGIN S = A + B; SUSPEND; END^
SET TERM ;^
COMMIT;
INSERT INTO VT VALUES (1, 'one');
INSERT INTO VT VALUES (2, 'two');
COMMIT;
EOF
chmod 666 "$VPDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$VPDB" "$D/fc-gbak-vp.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a VIEW and a PROCEDURE ride the backup (fc backs them up)"
else
    echo "DIFF view/procedure backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-vp.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-vp.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-vpr.fdb" bkp_file "$D/fc-gbak-vp.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-vpr.fdb"
got=$(printf 'SET HEADING OFF;\nSELECT ID, V FROM VV;\nSELECT S FROM PSUM(30, 12);\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-vpr.fdb" 2>&1 | tr -s ' \n' ' ')
if [ "$got" = " 2 two 42 " ]; then
    echo "OK   the ENGINE restores fc's fbk, READS the view and RUNS the procedure"
else
    echo "DIFF view/procedure after engine restore: [$got] (want ' 2 two 42 ')"; fail=1
fi
rm -f "$VPDB" "$D/fc-gbak-vp.fbk" "$D/fc-gbak-vpr.fdb"

# ~~a trigger refuses~~ - USER TRIGGERS RIDE (the same rec 13 the
# constraint triggers took, plus the att-14 debug map): proven by the
# ENGINE restoring fc's backup and the trigger FIRING on an insert.
# fc's OWN DML on the restored table refuses fail-closed where its
# executor cannot speak the carried body - the engine fires; recorded.
UTDB="$D/fc-gbak-ut.fdb"; rm -f "$UTDB" "$D/fc-gbak-ut.fbk" "$D/fc-gbak-utr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$UTDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE UT (X INTEGER, Y INTEGER);
COMMIT;
SET TERM ^;
CREATE TRIGGER TRU FOR UT BEFORE INSERT POSITION 5 AS BEGIN NEW.Y = NEW.X * 2; END^
SET TERM ;^
COMMIT;
INSERT INTO UT (X) VALUES (7);
COMMIT;
EOF
chmod 666 "$UTDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$UTDB" "$D/fc-gbak-ut.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a USER TRIGGER rides the backup (fc backs it up, debug map included)"
else
    echo "DIFF user-trigger backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-ut.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-ut.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-utr.fdb" bkp_file "$D/fc-gbak-ut.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-utr.fdb"
got=$(printf 'SET HEADING OFF;\nINSERT INTO UT (X) VALUES (9);\nSELECT X, Y FROM UT ORDER BY X;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-utr.fdb" 2>&1 | tr -s ' \n' ' ')
if [ "$got" = " 7 14 9 18 " ]; then
    echo "OK   the ENGINE restores fc's fbk and the trigger FIRES (X=9 doubles to Y=18)"
else
    echo "DIFF trigger after engine restore: [$got] (want ' 7 14 9 18 ')"; fail=1
fi
rm -f "$UTDB" "$D/fc-gbak-ut.fbk" "$D/fc-gbak-utr.fdb"
# ~~an exception refuses~~ - EXCEPTIONS RIDE (rec 30, the message a
# plain text attribute): the ENGINE restores fc's backup and RAISES
# the exception with the carried message
EXDB="$D/fc-gbak-ex.fdb"; rm -f "$EXDB" "$D/fc-gbak-ex.fbk" "$D/fc-gbak-exr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$EXDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
CREATE EXCEPTION E_X 'boom: value too large';
COMMIT;
EOF
chmod 666 "$EXDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$EXDB" "$D/fc-gbak-ex.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   an EXCEPTION rides the backup (fc backs it up)"
else
    echo "DIFF exception backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-ex.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-ex.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-exr.fdb" bkp_file "$D/fc-gbak-ex.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-exr.fdb"
got=$(printf 'SET TERM ^;\nEXECUTE BLOCK AS BEGIN EXCEPTION E_X; END^\nSET TERM ;^\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$D/fc-gbak-exr.fdb" 2>&1 | grep -c "boom: value too large")
if [ "$got" = "1" ]; then
    echo "OK   the ENGINE restores fc's fbk and RAISES it with the carried message"
else
    echo "DIFF exception raise after engine restore: match-count [$got] (want 1)"; fail=1
fi
rm -f "$EXDB" "$D/fc-gbak-ex.fbk" "$D/fc-gbak-exr.fdb"

# FUNCTIONS RIDE (rec 15/16/17): fc backs up a PSQL-function database,
# the ENGINE restores it and EXECUTES both functions - the deterministic
# flag, the NOT NULL argument and the argument names carried
FNDB="$D/fc-gbak-fn.fdb"; rm -f "$FNDB" "$D/fc-gbak-fn.fbk" "$D/fc-gbak-fnr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$FNDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
SET TERM ^;
CREATE FUNCTION FDOUBLE (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 2; END^
CREATE FUNCTION FCAT (S VARCHAR(10), N INTEGER NOT NULL) RETURNS VARCHAR(40) DETERMINISTIC AS BEGIN RETURN S || ':' || N; END^
SET TERM ;^
COMMIT;
EOF
chmod 666 "$FNDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$FNDB" "$D/fc-gbak-fn.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a PSQL FUNCTION rides the backup (fc backs it up)"
else
    echo "DIFF function backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-fn.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-fn.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-fnr.fdb" bkp_file "$D/fc-gbak-fn.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-fnr.fdb"
got=$(printf "SELECT FDOUBLE(21) || '/' || FCAT('a', 5) FROM RDB\$DATABASE;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-fnr.fdb" 2>&1 | grep -c "42/a:5")
if [ "$got" = "1" ]; then
    echo "OK   the ENGINE restores fc's fbk and EXECUTES both functions (42/a:5)"
else
    echo "DIFF function execution after engine restore: match-count [$got] (want 1)"; fail=1
fi
ran=$((ran + 1))
got=$(printf "SELECT FCAT('x', NULL) FROM RDB\$DATABASE;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-fnr.fdb" 2>&1 | grep -c 'validation error for variable "N"')
if [ "$got" = "1" ]; then
    echo "OK   ...and the argument's NOT NULL validates with its carried NAME"
else
    echo "DIFF function NOT NULL arg after engine restore: match-count [$got] (want 1)"; fail=1
fi
rm -f "$FNDB" "$D/fc-gbak-fn.fbk" "$D/fc-gbak-fnr.fdb"

# SQL ROLES RIDE (rec 36 - name, owner, and the eight zero bytes of a
# plain role's privilege block): the ENGINE restores fc's backup, the
# roles are there and a live GRANT lands on one
RLDB="$D/fc-gbak-rl.fdb"; rm -f "$RLDB" "$D/fc-gbak-rl.fbk" "$D/fc-gbak-rlr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$RLDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
CREATE ROLE R_APP;
CREATE ROLE R_AUDIT;
COMMIT;
EOF
chmod 666 "$RLDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$RLDB" "$D/fc-gbak-rl.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a SQL ROLE rides the backup (fc backs it up)"
else
    echo "DIFF role backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-rl.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-rl.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-rlr.fdb" bkp_file "$D/fc-gbak-rl.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-rlr.fdb"
got=$(printf "SELECT TRIM(RDB\$ROLE_NAME) || '.' FROM RDB\$ROLES WHERE RDB\$SYSTEM_FLAG=0 ORDER BY 1;\nGRANT R_AUDIT TO PUBLIC;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-rlr.fdb" 2>&1 | grep -cE 'R_APP\.|R_AUDIT\.')
if [ "$got" = "2" ]; then
    echo "OK   the ENGINE restores fc's fbk: both roles present, a GRANT lands"
else
    echo "DIFF roles after engine restore: match-count [$got] (want 2)"; fail=1
fi
rm -f "$RLDB" "$D/fc-gbak-rl.fbk" "$D/fc-gbak-rlr.fdb"

# --- 4. RECORDED BOUNDARY: NOT NULL is not carried ---------------------------
NN="$D/fc-gbak-nn.fdb"; rm -f "$NN"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$NN' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE N (A INTEGER NOT NULL, B INTEGER);
COMMIT;
INSERT INTO N VALUES (1, 2);
COMMIT;
EOF
chmod 666 "$NN"
rm -f "$D/fc-gbak-nnf.fbk" "$D/fc-gbak-nne.fbk" "$D/fc-gbak-rnf.fdb" "$D/fc-gbak-rne.fdb"
svc_backup "$FMGR" "$NN" "$D/fc-gbak-nnf.fbk" >/dev/null
svc_backup "$EMGR" "$NN" "$D/fc-gbak-nne.fbk" >/dev/null
grab "$D/fc-gbak-nne.fbk"
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbak-nnf.fbk" "$D/fc-gbak-rnf.fdb" >/dev/null 2>&1
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbak-nne.fbk" "$D/fc-gbak-rne.fdb" >/dev/null 2>&1
chmod 666 "$D/fc-gbak-rnf.fdb" "$D/fc-gbak-rne.fdb" 2>/dev/null
tries_null() { # <db> - can a NULL go into N.A?
    printf 'INSERT INTO N (B) VALUES (9);\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | grep -c "validation error"
}
# the data comparison runs BEFORE the null probes - a successful probe
# INSERTS its row, and comparing after it would measure the probe
check "...and the DATA rows agree" \
    "$(printf 'SET HEADING OFF;\nSELECT A, B FROM N;\n' | "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-rnf.fdb" 2>&1 | tr -s ' \n' ' ')" \
    "$(printf 'SET HEADING OFF;\nSELECT A, B FROM N;\n' | "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-rne.fdb" 2>&1 | tr -s ' \n' ' ')"
# THE BOUNDARY FLIPPED: the writer carries NOT NULL now (att 38 on the
# field record + the INTEG rel_constraint/chk_constraint pair), so BOTH
# restored databases refuse a NULL - asserted as the equality the old
# boundary check promised to become.
ran=$((ran + 1))
fnull=$(tries_null "$D/fc-gbak-rnf.fdb"); enull=$(tries_null "$D/fc-gbak-rne.fdb")
if [ "$fnull" = "1" ] && [ "$enull" = "1" ]; then
    echo "OK   NOT NULL is carried: both restored databases refuse a NULL"
else
    echo "DIFF NOT NULL: fc-restore refusals=$fnull engine-restore refusals=$enull (want 1/1)"
    fail=1
fi
rm -f "$NN"

# --- 5. the OLD protocol answers too (the full gate is serve-real-gbakse.sh) --
out=$("$GBAK" -b -se "127.0.0.1/$PORT:service_mgr" -user "$U" -pas "$P" "$SRC" "$D/fc-gbak-se.fbk" 2>&1); serc=$?
check "gbak -se's command-line protocol backs up too" "$out|rc=$serc" "|rc=0"
# verbose STREAMS now (its own gate: serve-real-gbakverbose.sh); here
# one seam check holds that the tagged route answers lines at all
out=$(svc_backup "$FMGR" "$SRC" "$D/fc-gbak-v.fbk" verbose)
check "a VERBOSE backup streams gbak's own closing line" \
    "$(printf '%s' "$out" | grep -c "closing file, committing, and finishing")" "1"

# --- 6. an existing target is OVERWRITTEN on both -----------------------------
# Measured, and the OPPOSITE of nbackup's law: the engine's
# action_backup replaces an existing .fbk silently. A converter copying
# one tool's rule onto the other ships this as a bug in either
# direction, which is why both tools' gates assert their own.
check "a backup onto an EXISTING file overwrites (fc)" \
    "$(svc_backup "$FMGR" "$SRC" "$D/fc-gbak-f.fbk")" "|rc=0"
check "a backup onto an EXISTING file overwrites (engine)" \
    "$(svc_backup "$EMGR" "$SRC" "$D/fc-gbak-e.fbk")" "|rc=0"
rm -f "$D/fc-gbak-r3.fdb"
"$GBAK" -c -user "$U" -pas "$P" "$D/fc-gbak-f.fbk" "$D/fc-gbak-r3.fdb" >/dev/null 2>&1
chmod 666 "$D/fc-gbak-r3.fdb" 2>/dev/null
got=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM MIXED;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-r3.fdb" 2>&1 | tr -d ' \n')
check "...and the overwritten backup carries the CURRENT rows" "$got" "4"

echo "ran $ran checks"
exit $fail
