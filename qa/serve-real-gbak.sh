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
CREATE FUNCTION FDEF (A INTEGER = 42) RETURNS INTEGER AS BEGIN RETURN A; END^
CREATE PROCEDURE PDEF (B INTEGER = 7) RETURNS (C INTEGER) AS BEGIN C = B; SUSPEND; END^
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
ran=$((ran + 1))
got=$(printf "SELECT FDEF() || '/' || (SELECT C FROM PDEF) FROM RDB\$DATABASE;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-fnr.fdb" 2>&1 | grep -c "42/7")
if [ "$got" = "1" ]; then
    echo "OK   ...and the argument and parameter DEFAULTS apply on argument-less calls (42/7)"
else
    echo "DIFF argument DEFAULTs after engine restore: match-count [$got] (want 1)"; fail=1
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

# PACKAGES RIDE (rec 38 + members as ordinary records with the package
# attribute): the ENGINE restores fc's backup and EXECUTES both
# members, and the PRIVATE flag still guards the hidden function
PKDB="$D/fc-gbak-pk.fdb"; rm -f "$PKDB" "$D/fc-gbak-pk.fbk" "$D/fc-gbak-pkr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$PKDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
SET TERM ^;
CREATE PACKAGE PK AS
BEGIN
  FUNCTION FD (A INTEGER) RETURNS INTEGER;
  PROCEDURE PS (B INTEGER) RETURNS (C INTEGER);
END^
CREATE PACKAGE BODY PK AS
BEGIN
  FUNCTION FD (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A * 3; END
  FUNCTION FHID (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A + 100; END
  PROCEDURE PS (B INTEGER) RETURNS (C INTEGER) AS BEGIN C = FHID(B); SUSPEND; END
END^
SET TERM ;^
COMMIT;
EOF
chmod 666 "$PKDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$PKDB" "$D/fc-gbak-pk.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a PACKAGE rides the backup (fc backs it up, members and all)"
else
    echo "DIFF package backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-pk.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-pk.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-pkr.fdb" bkp_file "$D/fc-gbak-pk.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-pkr.fdb"
got=$(printf "SELECT PK.FD(14) || '/' || (SELECT C FROM PK.PS(7)) FROM RDB\$DATABASE;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-pkr.fdb" 2>&1 | grep -c "42/107")
if [ "$got" = "1" ]; then
    echo "OK   the ENGINE restores fc's fbk and EXECUTES both members (42/107)"
else
    echo "DIFF package member execution after engine restore: match-count [$got] (want 1)"; fail=1
fi
ran=$((ran + 1))
got=$(printf "SELECT PK.FHID(1) FROM RDB\$DATABASE;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-pkr.fdb" 2>&1 | grep -c "private to package")
if [ "$got" = "1" ]; then
    echo "OK   ...and the carried PRIVATE flag still guards the hidden member"
else
    echo "DIFF private member after engine restore: match-count [$got] (want 1)"; fail=1
fi
rm -f "$PKDB" "$D/fc-gbak-pk.fbk" "$D/fc-gbak-pkr.fdb"

# GTTs RIDE (att 18 relation type 4/5 on the ordinary relation record):
# restored EMPTY - a GTT's rows are per-attachment and never in the
# file - typed 4/5 with FLAGS 1 and the restore-side DBKEY_LENGTH 0,
# and a live INSERT lands in the restored instance
GTDB="$D/fc-gbak-gt.fdb"; rm -f "$GTDB" "$D/fc-gbak-gt.fbk" "$D/fc-gbak-gtr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$GTDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
CREATE GLOBAL TEMPORARY TABLE GP (A INTEGER) ON COMMIT PRESERVE ROWS;
CREATE GLOBAL TEMPORARY TABLE GD (B INTEGER) ON COMMIT DELETE ROWS;
COMMIT;
INSERT INTO T VALUES (5);
INSERT INTO GP VALUES (1);
COMMIT;
EOF
chmod 666 "$GTDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$GTDB" "$D/fc-gbak-gt.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a GLOBAL TEMPORARY table rides the backup (fc backs it up)"
else
    echo "DIFF GTT backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-gt.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-gt.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-gtr.fdb" bkp_file "$D/fc-gbak-gt.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-gtr.fdb"
got=$(printf "SELECT (SELECT COUNT(*) FROM GP) || '/' || TRIM(RDB\$RELATION_TYPE) || '/' || (SELECT X FROM T) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME='GP';\nINSERT INTO GP VALUES (9);\nSELECT 'live:' || A FROM GP;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-gtr.fdb" 2>&1 | grep -cE '0/4/5|live:9')
if [ "$got" = "2" ]; then
    echo "OK   the ENGINE restores fc's fbk: GTT typed 4, EMPTY, live-writable; T kept"
else
    echo "DIFF GTT after engine restore: match-count [$got] (want 2)"; fail=1
fi
rm -f "$GTDB" "$D/fc-gbak-gt.fbk" "$D/fc-gbak-gtr.fdb"

# EXPRESSION view columns RIDE: the expression lives on the column's
# OWN domain as COMPUTED_BLR (subtype 2, carried verbatim on the
# rec-2 record's att 18) - the ENGINE restores fc's backup and reads
# base, arithmetic and concat columns through the view, live rows too
EXVDB="$D/fc-gbak-exv.fdb"; rm -f "$EXVDB" "$D/fc-gbak-exv.fbk" "$D/fc-gbak-exvr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$EXVDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE VB (A INTEGER, S VARCHAR(8));
COMMIT;
CREATE VIEW VX (A2, DBL, TXT) AS SELECT A, A * 2, S || '!' FROM VB;
COMMIT;
INSERT INTO VB VALUES (21, 'hi');
COMMIT;
EOF
chmod 666 "$EXVDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$EXVDB" "$D/fc-gbak-exv.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   an EXPRESSION-columned view rides the backup (fc backs it up)"
else
    echo "DIFF expression view backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-exv.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-exv.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-exvr.fdb" bkp_file "$D/fc-gbak-exv.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-exvr.fdb"
got=$(printf "SELECT A2 || '/' || DBL || '/' || TXT FROM VX;\nINSERT INTO VB VALUES (5, 'yo');\nSELECT DBL || TXT FROM VX WHERE A2 = 5;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-exvr.fdb" 2>&1 | grep -cE '21/42/hi!|10yo!')
if [ "$got" = "2" ]; then
    echo "OK   the ENGINE restores fc's fbk and computes through the view (42, hi!, live rows)"
else
    echo "DIFF expression view after engine restore: match-count [$got] (want 2)"; fail=1
fi
rm -f "$EXVDB" "$D/fc-gbak-exv.fbk" "$D/fc-gbak-exvr.fdb"

# COMMENTS RIDE - every commentable family of the carried surface in
# one fixture (description2 blob atts, measured per record family):
# table 13, column 35, view 13, view column 35, index 9, sequence 4,
# exception 4, procedure 5, parameter 6, function 9, trigger 11,
# role 3. A COMMENT on an invented RDB$n domain refuses typed - it
# cannot follow the renumbering a restore performs.
DSDB="$D/fc-gbak-ds.fdb"; rm -f "$DSDB" "$D/fc-gbak-ds.fbk" "$D/fc-gbak-dsr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$DSDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER, Y VARCHAR(6));
CREATE INDEX IX_T ON T (X);
COMMIT;
CREATE SEQUENCE SQ;
CREATE EXCEPTION E_D 'boom';
COMMIT;
SET TERM ^;
CREATE PROCEDURE PP (B INTEGER) RETURNS (C INTEGER) AS BEGIN C = B; SUSPEND; END^
CREATE FUNCTION FF (A INTEGER) RETURNS INTEGER AS BEGIN RETURN A; END^
CREATE TRIGGER TG FOR T BEFORE INSERT AS BEGIN NEW.X = COALESCE(NEW.X, 0); END^
SET TERM ;^
CREATE VIEW VV (VX) AS SELECT X FROM T;
CREATE ROLE R_D;
COMMIT;
COMMENT ON TABLE T IS 'table words';
COMMENT ON COLUMN T.X IS 'column words';
COMMENT ON VIEW VV IS 'view words';
COMMENT ON COLUMN VV.VX IS 'vcol words';
COMMENT ON INDEX IX_T IS 'index words';
COMMENT ON SEQUENCE SQ IS 'seq words';
COMMENT ON EXCEPTION E_D IS 'exc words';
COMMENT ON PROCEDURE PP IS 'proc words';
COMMENT ON PARAMETER PP.B IS 'parm words';
COMMENT ON FUNCTION FF IS 'fn words';
COMMENT ON TRIGGER TG IS 'trg words';
COMMENT ON ROLE R_D IS 'role words';
COMMIT;
EOF
chmod 666 "$DSDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$DSDB" "$D/fc-gbak-ds.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   COMMENTS on all twelve families ride the backup (fc backs them up)"
else
    echo "DIFF comment backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-ds.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-ds.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-dsr.fdb" bkp_file "$D/fc-gbak-ds.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-dsr.fdb"
descdig() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" <<'EOF' 2>/dev/null | awk 'NF {$1=$1; printf "/%s", $0} END {print "/"}'
SET HEADING OFF;
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME IN ('T','VV') ORDER BY RDB$RELATION_NAME;
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$RELATION_FIELDS WHERE RDB$DESCRIPTION IS NOT NULL ORDER BY RDB$RELATION_NAME;
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$INDICES WHERE RDB$INDEX_NAME='IX_T';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$GENERATORS WHERE RDB$GENERATOR_NAME='SQ';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$EXCEPTIONS WHERE RDB$EXCEPTION_NAME='E_D';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_NAME='PP';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$PROCEDURE_PARAMETERS WHERE RDB$PARAMETER_NAME='B' AND RDB$PROCEDURE_NAME='PP';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$FUNCTIONS WHERE RDB$FUNCTION_NAME='FF';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$TRIGGERS WHERE RDB$TRIGGER_NAME='TG';
SELECT CAST(RDB$DESCRIPTION AS VARCHAR(20)) FROM RDB$ROLES WHERE RDB$ROLE_NAME='R_D';
EOF
}
want="/table words/view words/column words/vcol words/index words/seq words/exc words/proc words/parm words/fn words/trg words/role words/"
got=$(descdig "$D/fc-gbak-dsr.fdb")
ran=$((ran + 1))
if [ "$got" = "$want" ]; then
    echo "OK   the ENGINE restores fc's fbk with every COMMENT in place"
else
    echo "DIFF comments after engine restore: [$got] want [$want]"; fail=1
fi
ran=$((ran + 1))
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CONNECT '$DSDB' USER '$U' PASSWORD '$P';
COMMENT ON DOMAIN RDB\$1 IS 'dom words';
COMMIT;
EOF
fo=$(svc_backup "$FMGR" "$DSDB" "$D/fc-gbak-ds2.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "DIFF a COMMENT on an invented domain should refuse: [$fo]"; fail=1
else
    echo "OK   a COMMENT on an invented RDB\$n domain refuses typed"
fi
rm -f "$DSDB" "$D/fc-gbak-ds.fbk" "$D/fc-gbak-ds2.fbk" "$D/fc-gbak-dsr.fdb"

# NAMED DOMAINS RIDE - the real name on the rec-2 record (with NOT
# NULL att 38, char length, COMMENT), columns keeping the name in
# att 2: the ENGINE restores fc's backup with the binding, the data,
# the comment and the domain's NOT NULL enforcement intact
NDDB="$D/fc-gbak-nd.fdb"; rm -f "$NDDB" "$D/fc-gbak-nd.fbk" "$D/fc-gbak-ndr.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$NDDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE DOMAIN D_AGE AS INTEGER NOT NULL;
CREATE DOMAIN D_TXT AS VARCHAR(8);
CREATE DOMAIN D_POS AS INTEGER DEFAULT 7 CHECK (VALUE > 0);
COMMIT;
CREATE TABLE P (AGE D_AGE, NICK D_TXT, PLAIN INTEGER, POS D_POS);
COMMIT;
INSERT INTO P (AGE, NICK, PLAIN) VALUES (30, 'ada', 1);
COMMIT;
COMMENT ON DOMAIN D_TXT IS 'dom words';
COMMIT;
EOF
chmod 666 "$NDDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$NDDB" "$D/fc-gbak-nd.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   a NAMED DOMAIN rides the backup (fc backs it up)"
else
    echo "DIFF named-domain backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-nd.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-nd.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-ndr.fdb" bkp_file "$D/fc-gbak-nd.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-ndr.fdb"
got=$(printf "SELECT AGE || '/' || NICK || '/' || TRIM(RDB\$FIELD_SOURCE) || '/' || (SELECT CAST(RDB\$DESCRIPTION AS VARCHAR(20)) FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME='D_TXT') FROM P JOIN RDB\$RELATION_FIELDS ON RDB\$RELATION_NAME='P' AND RDB\$FIELD_NAME='AGE';\nINSERT INTO P (NICK, PLAIN) VALUES ('x', 2);\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-ndr.fdb" 2>&1 | grep -cE '30/ada/D_AGE/dom words|validation error for column')
if [ "$got" = "2" ]; then
    echo "OK   the ENGINE restores fc's fbk: binding, data, COMMENT, NOT NULL all carried"
else
    echo "DIFF named domain after engine restore: match-count [$got] (want 2)"; fail=1
fi
ran=$((ran + 1))
got=$(printf "INSERT INTO P (AGE, NICK, PLAIN) VALUES (1, 'd', 9);\nSELECT 'def:' || POS FROM P WHERE PLAIN = 9;\nINSERT INTO P (AGE, NICK, PLAIN, POS) VALUES (1, 'd', 10, -5);\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-ndr.fdb" 2>&1 | grep -cE "def:7|validation error for column.*POS")
if [ "$got" = "2" ]; then
    echo "OK   ...and the domain's DEFAULT lands and its CHECK refuses (7, -5 raises)"
else
    echo "DIFF domain DEFAULT/CHECK after engine restore: match-count [$got] (want 2)"; fail=1
fi
rm -f "$NDDB" "$D/fc-gbak-nd.fbk" "$D/fc-gbak-ndr.fdb"

# EXPRESSION indexes RIDE (atts 10/11 on the rec-5 record, the BLR
# verbatim; the irt repeat takes IRT_EXPRESSION and the backfill keys
# every row on the EVALUATED expression): the ENGINE restores fc's
# backup, PLANS through the index, and MAINTAINS it on a live insert
EXIDB="$D/fc-gbak-exi.fdb"; rm -f "$EXIDB" "$D/fc-gbak-exi.fbk" "$D/fc-gbak-exir.fdb"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$EXIDB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER, S VARCHAR(6));
COMMIT;
INSERT INTO T VALUES (10, 'ab');
INSERT INTO T VALUES (3, 'cd');
COMMIT;
CREATE INDEX IXE ON T COMPUTED BY (X + 1);
COMMIT;
EOF
chmod 666 "$EXIDB"
ran=$((ran + 1))
fo=$(svc_backup "$FMGR" "$EXIDB" "$D/fc-gbak-exi.fbk")
if [ "${fo##*rc=}" = "0" ]; then
    echo "OK   an EXPRESSION index rides the backup (fc backs it up)"
else
    echo "DIFF expression index backup: [$fo]"; fail=1
fi
ran=$((ran + 1))
sudo -n chmod 666 "$D/fc-gbak-exi.fbk" 2>/dev/null || chmod 666 "$D/fc-gbak-exi.fbk" 2>/dev/null
"$FBSVCMGR" "$EMGR" user "$U" password "$P" action_restore dbname "$D/fc-gbak-exir.fdb" bkp_file "$D/fc-gbak-exi.fbk" >/dev/null 2>&1
grab "$D/fc-gbak-exir.fdb"
got=$(printf "SET PLAN ON;\nSELECT X FROM T WHERE X + 1 = 4;\nINSERT INTO T VALUES (99, 'zz');\nSELECT X FROM T WHERE X + 1 = 100;\n" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-gbak-exir.fdb" 2>&1 | grep -cE 'INDEX \("PUBLIC"\."IXE"\)|^ *3 *$|^ *99 *$')
if [ "$got" = "4" ]; then
    echo "OK   the ENGINE restores fc's fbk, PLANS through IXE and maintains it live"
else
    echo "DIFF expression index after engine restore: match-count [$got] (want 4)"; fail=1
fi
rm -f "$EXIDB" "$D/fc-gbak-exi.fbk" "$D/fc-gbak-exir.fdb"

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
