#!/bin/bash
# THE LOGICAL RESTORE: fire-crab reads a .fbk - the engine's or its own.
#
# `isc_action_svc_restore` closes the differential the writer opened:
# with both sides able to back up AND restore, the four combinations
# (engine.fbk x fc-restore, fc.fbk x engine-restore, and each side round
# tripping itself) must all produce databases the ENGINE reads the same
# rows from. A converter that got the format subtly wrong cannot pass
# all four - an encoding bug shows in the cross pairs, a decoding bug in
# the other diagonal.
#
# The restore goes through fire-crab's OWN machinery: burp::read_backup
# decodes the stream, ddl::create_table lays the tables into a fresh
# shell, and every row goes through dml::insert_record exactly as an
# INSERT's would - so gfix -v -full on the result is a real check of
# that machinery, not of a copied file.
#
# MEASURED LAWS HELD:
#   * a FRESH target restores silently; an EXISTING one without
#     res_replace fails with gbak's own STATUS VECTOR - isc_gbak_db_exists
#     naming the file, then "Exiting before completion due to errors"
#     (rc 1; a first probe misread its own pipeline and thought the rc
#     was 0 - the rc must be taken from fbsvcmgr itself, not from the
#     tr behind a pipe); with res_replace it overwrites;
#   * NOT NULL rides the file both ways now (att 38 + the INTEG
#     constraint pair): all four restored databases refuse a NULL;
#   * BLOBS ride the file in both directions: the field records arrive
#     BLOBS-FIRST (att 13 carries the true position, so the restore
#     re-sorts), a row leads with the blob quads, and each non-null
#     blob's rec_blob follows its row with u16-framed segments - a NULL
#     blob writes no record at all. The digest below covers null, empty,
#     short and a 30000-byte multi-segment blob, text and binary;
#   * privileges are parsed and SET ASIDE (access metadata, not data) -
#     the count is in the trace, and the restored databases differ from
#     the engine's restore exactly there.
#
# A PRIMARY KEY AND ITS INDEXES RIDE THE FILE (rec_index + the PRIMARY
# KEY rel_constraint), and the BUILD ORDER is part of the law: rows
# first, indexes after, BACKFILLED - dml::insert_record does no index
# maintenance, so the other order leaves empty indexes over full tables.
#
# FAIL-CLOSED: a .fbk carrying a FOREIGN KEY (cross-table restore
# ordering), a trigger, or any record this reader does not know refuses
# the WHOLE restore - mis-stepping the record walk would turn
# everything after it into nonsense.
#
#   qa/serve-real-gbakrestore.sh [port]

set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
FBSVCMGR="${FBSVCMGR:-fbsvcmgr}"
PORT="${1:-4721}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-gbr-src.fdb"
LOG="/tmp/fc-serve-gbakrestore-$PORT.log"
fail=0
ran=0
mkdir -p "$D"

rm -f "$SRC" "$D"/fc-gbr-*.fbk "$D"/fc-gbr-r*.fdb "$D"/fc-gbr-pk.fdb
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE MIXED (S SMALLINT, I INTEGER NOT NULL, B BIGINT, C CHAR(7), V VARCHAR(15));
CREATE TABLE EMPTYT (X INTEGER);
CREATE TABLE KEYED (ID INTEGER NOT NULL PRIMARY KEY, W VARCHAR(8));
CREATE INDEX KX_W ON KEYED (W);
CREATE UNIQUE INDEX KU_2 ON KEYED (W, ID);
CREATE TABLE BT (ID INTEGER, TXT BLOB SUB_TYPE TEXT, BIN BLOB SUB_TYPE 0, W VARCHAR(6));
CREATE SEQUENCE SQ1;
CREATE SEQUENCE SQ2 START WITH 500 INCREMENT BY 3;
CREATE VIEW MIXVW AS SELECT S, I FROM MIXED WHERE I > 0;
CREATE TABLE UPAR (ID INTEGER NOT NULL PRIMARY KEY, UX INTEGER NOT NULL, CONSTRAINT UQ_UX UNIQUE (UX));
CREATE TABLE UCHILD (PID INTEGER NOT NULL, X INTEGER CHECK (X > 0),
                     CONSTRAINT FK_UP FOREIGN KEY (PID) REFERENCES UPAR (ID) ON DELETE CASCADE);
COMMIT;
INSERT INTO UPAR VALUES (1, 10);
INSERT INTO UPAR VALUES (2, 20);
INSERT INTO UPAR VALUES (5, 50);
INSERT INTO UCHILD VALUES (1, 4);
INSERT INTO UCHILD VALUES (5, 6);
COMMIT;
SELECT GEN_ID(SQ1, 7) FROM RDB\$DATABASE;
COMMIT;
SET TERM ^;
CREATE PROCEDURE PSUM (A INTEGER, B INTEGER) RETURNS (S INTEGER) AS BEGIN S = A + B; SUSPEND; END^
SET TERM ;^
COMMIT;
INSERT INTO KEYED VALUES (1, 'aa');
INSERT INTO KEYED VALUES (2, 'bb');
INSERT INTO BT VALUES (1, 'hello blob', NULL, 'w1');
INSERT INTO BT VALUES (2, NULL, NULL, NULL);
INSERT INTO BT VALUES (3, CAST(LPAD('', 30000, 'abcdefghij') AS BLOB SUB_TYPE TEXT), 'binbytes', 'w3');
INSERT INTO BT VALUES (4, '', NULL, 'w4');
COMMIT;
INSERT INTO MIXED VALUES (-5, 100000, 9000000000, 'abc', 'hello world');
INSERT INTO MIXED VALUES (NULL, 1, NULL, NULL, NULL);
INSERT INTO MIXED VALUES (32767, -2147483648, -9223372036854775808, 'seven77', 'fifteen fifteen');
COMMIT;
EOF
chmod 666 "$SRC"

FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$D"/fc-gbr-*.fbk "$D"/fc-gbr-r*.fdb "$D"/fc-gbr-pk.fdb' EXIT
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
svc() { # <mgr> <action-args...> -> "output|rc=N"
    local mgr=$1; shift
    local out rc
    out=$("$FBSVCMGR" "$mgr" user "$U" password "$P" "$@" 2>&1); rc=$?
    printf '%s|rc=%s' "$(printf '%s' "$out" | tr '\n' '|')" "$rc"
}
EMGR="localhost:service_mgr"
FMGR="127.0.0.1/$PORT:service_mgr"
grab() { sudo -n chmod 666 "$1" 2>/dev/null || chmod 666 "$1" 2>/dev/null || true; }
rows() { # <db file>
    grab "$1"
    printf 'SET HEADING OFF;\nSELECT S, I, B, C, V FROM MIXED ORDER BY I;\nSELECT COUNT(*) FROM EMPTYT;\nSELECT ID, W FROM KEYED ORDER BY ID;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
blobs() { # <db file> - a digest of every blob: null/empty/short/30k
    grab "$1"
    printf 'SET HEADING OFF;\nSELECT ID, CHAR_LENGTH(TXT), CAST(SUBSTRING(TXT FROM 1 FOR 10) AS VARCHAR(10)), CAST(SUBSTRING(TXT FROM 29996) AS VARCHAR(5)), CAST(BIN AS VARCHAR(10)), W FROM BT ORDER BY ID;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
cons() { # <db> - the whole constraint family: catalog, the three
         # violations, the valid row, and the CASCADE through the
         # carried trigger
    grab "$1"
    local cat trg viol n
    cat=$(printf 'SET HEADING OFF;\nSELECT TRIM(RDB$CONSTRAINT_NAME) FROM RDB$RELATION_CONSTRAINTS WHERE RDB$CONSTRAINT_TYPE IN (%s, %s, %s) ORDER BY 1;\n' "'UNIQUE'" "'FOREIGN KEY'" "'CHECK'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' ')
    trg=$(printf 'SET HEADING OFF;\nSELECT TRIM(RDB$TRIGGER_NAME) || RDB$SYSTEM_FLAG FROM RDB$TRIGGERS WHERE RDB$SYSTEM_FLAG IN (3, 4) ORDER BY 1;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' ')
    viol=$(printf 'INSERT INTO UPAR VALUES (3, 10);\nINSERT INTO UCHILD VALUES (99, 1);\nINSERT INTO UCHILD VALUES (1, -4);\nINSERT INTO UCHILD VALUES (2, 8);\n' |
        "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -c "SQLSTATE = 23000")
    printf 'DELETE FROM UPAR WHERE ID = 5;\nCOMMIT;\n' |
        "$ISQL" -q -user "$U" -pas "$P" "$1" >/dev/null 2>&1
    n=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM UCHILD;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' ')
    printf '%s/%s/23000x%s/rows%s' "$cat" "$trg" "$viol" "$n"
}
vwproc() { # <db> - the view reads, the procedure runs
    grab "$1"
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM MIXVW;\nSELECT S FROM PSUM(40, 2);\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
gens() { # <db> - sequence catalog + CURRENT values (GEN_ID step 0)
    grab "$1"
    printf 'SET HEADING OFF;\nSELECT TRIM(RDB\$GENERATOR_NAME), RDB\$INITIAL_VALUE, RDB\$GENERATOR_INCREMENT FROM RDB\$GENERATORS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;\nSELECT GEN_ID(SQ1, 0), GEN_ID(SQ2, 0) FROM RDB\$DATABASE;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
pk_and_indexes() { # <db>: "dup-refusals/index-list"
    local dup ix
    dup=$(printf 'INSERT INTO KEYED VALUES (1, %s);\n' "'x'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | grep -c "PRIMARY or UNIQUE")
    ix=$(printf 'SET HEADING OFF;\nSELECT TRIM(RDB$INDEX_NAME) FROM RDB$INDICES WHERE RDB$RELATION_NAME = %s AND RDB$INDEX_NAME NOT STARTING WITH %s ORDER BY 1;\n' "'KEYED'" "'RDB$'" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' ')
    printf '%s/%s' "$dup" "$ix"
}

# --- 0. both sides back up the same database --------------------------------
check "engine backup" "$(svc "$EMGR" action_backup dbname "$SRC" bkp_file "$D/fc-gbr-e.fbk")" "|rc=0"
check "fc backup" "$(svc "$FMGR" action_backup dbname "$SRC" bkp_file "$D/fc-gbr-f.fbk")" "|rc=0"
grab "$D/fc-gbr-e.fbk"

# --- 1. THE FOUR RESTORES ----------------------------------------------------
check "fc restores the ENGINE's fbk" \
    "$(svc "$FMGR" action_restore dbname "$D/fc-gbr-r1.fdb" bkp_file "$D/fc-gbr-e.fbk")" "|rc=0"
check "fc restores its OWN fbk" \
    "$(svc "$FMGR" action_restore dbname "$D/fc-gbr-r2.fdb" bkp_file "$D/fc-gbr-f.fbk")" "|rc=0"
check "the engine restores fc's fbk" \
    "$(svc "$EMGR" action_restore dbname "$D/fc-gbr-r3.fdb" bkp_file "$D/fc-gbr-f.fbk")" "|rc=0"
check "the engine restores its own fbk" \
    "$(svc "$EMGR" action_restore dbname "$D/fc-gbr-r4.fdb" bkp_file "$D/fc-gbr-e.fbk")" "|rc=0"
base=$(rows "$D/fc-gbr-r4.fdb")
check "engine.fbk x fc-restore reads the same rows" "$(rows "$D/fc-gbr-r1.fdb")" "$base"
check "fc.fbk x fc-restore reads the same rows" "$(rows "$D/fc-gbr-r2.fdb")" "$base"
check "fc.fbk x engine-restore reads the same rows" "$(rows "$D/fc-gbr-r3.fdb")" "$base"
bbase=$(blobs "$D/fc-gbr-r4.fdb")
check "the BLOBS read identically from fc's restore of the engine's fbk" "$(blobs "$D/fc-gbr-r1.fdb")" "$bbase"
check "...and from fc's round trip" "$(blobs "$D/fc-gbr-r2.fdb")" "$bbase"
check "...and from the engine's restore of fc's fbk" "$(blobs "$D/fc-gbr-r3.fdb")" "$bbase"

# the SEQUENCES: catalog row AND the current value out of the generator
# vector, all four corners of the matrix reading the same numbers -
# SQ1 advanced to 7 before the backup, SQ2 sits at 497 (START 500
# INCREMENT 3, never drawn)
gbase=$(gens "$SRC")
check "sequences ride the engine's fbk through fc's restore" "$(gens "$D/fc-gbr-r1.fdb")" "$gbase"
check "...and fc's own round trip" "$(gens "$D/fc-gbr-r2.fdb")" "$gbase"
check "...and fc's fbk through the ENGINE's restore" "$(gens "$D/fc-gbr-r3.fdb")" "$gbase"
check "...and the engine's own round trip agrees" "$(gens "$D/fc-gbr-r4.fdb")" "$gbase"

# the CONSTRAINT FAMILY: UNIQUE + plain FK in every corner - catalog
# rows present, the duplicate and the dangling PID both raise 23000,
# and the VALID child row lands (enforcement, not refusal)
cbase=$(cons "$D/fc-gbr-r4.fdb")
check "UNIQUE + FK ride the engine's fbk through fc's restore" "$(cons "$D/fc-gbr-r1.fdb")" "$cbase"
check "...and fc's own round trip" "$(cons "$D/fc-gbr-r2.fdb")" "$cbase"
check "...and fc's fbk through the ENGINE's restore" "$(cons "$D/fc-gbr-r3.fdb")" "$cbase"

# the VIEW and the PROCEDURE in EVERY corner: ~~the ENGINE executing
# an fc-authored procedure catalog was the old recorded loader
# boundary~~ - CLOSED: the crash was one NULL column, the param rows'
# RDB$FIELD_SOURCE_SCHEMA_NAME the engine's loader dereferences (the
# FK-blocker lesson found again by full-row diff), and with it
# written the engine executes procedures off fc's restores too
vbase=$(vwproc "$D/fc-gbr-r4.fdb")
check "the view and procedure ride fc's fbk through the ENGINE's restore" "$(vwproc "$D/fc-gbr-r3.fdb")" "$vbase"
check "...and the engine's fbk through FC's restore (the old boundary, closed)" "$(vwproc "$D/fc-gbr-r1.fdb")" "$vbase"
check "...and fc's own round trip" "$(vwproc "$D/fc-gbr-r2.fdb")" "$vbase"
for r in r1 r2; do
    ran=$((ran + 1))
    v=$("$GFIX" -v -full -user "$U" -pas "$P" "$D/fc-gbr-$r.fdb" 2>&1 | tr -d ' \n')
    if [ -z "$v" ]; then echo "OK   gfix -v -full accepts fc's restore ($r)"
    else echo "DIFF gfix -v -full ($r): [$v]"; fail=1; fi
done

# --- 2. NOT NULL rides the file in all four combinations --------------------
nulltry() { # <db> - 1 = refused
    printf 'INSERT INTO MIXED (S) VALUES (1);\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | grep -c "validation error"
}
for r in r1 r2 r3 r4; do
    check "NOT NULL enforced in $r" "$(nulltry "$D/fc-gbr-$r.fdb")" "1"
done

# --- 2b. THE KEYS AND INDEXES ride the file in all four combinations --------
# The build order is the teeth here: dml::insert_record does no index
# maintenance, so an index created before the rows would be EMPTY over a
# full table - rows silently missing through any indexed access. The
# duplicate-key refusal proves the PK backfilled; the index list proves
# the secondary indexes exist.
for r in r1 r2 r3 r4; do
    check "PK enforced and indexes present in $r" \
        "$(pk_and_indexes "$D/fc-gbr-$r.fdb")" "1/ KU_2 KX_W "
done

# --- 3. the create/replace law, text and all ---------------------------------
eo=$(svc "$EMGR" action_restore dbname "$D/fc-gbr-r4.fdb" bkp_file "$D/fc-gbr-e.fbk")
fo=$(svc "$FMGR" action_restore dbname "$D/fc-gbr-r1.fdb" bkp_file "$D/fc-gbr-e.fbk")
check "an existing target streams gbak's message (same shape both sides)" \
    "$(printf '%s' "$fo" | sed "s|$D/fc-gbr-r1.fdb|<db>|")" \
    "$(printf '%s' "$eo" | sed "s|$D/fc-gbr-r4.fdb|<db>|")"
check "...and res_replace overwrites (fc)" \
    "$(svc "$FMGR" action_restore dbname "$D/fc-gbr-r1.fdb" bkp_file "$D/fc-gbr-e.fbk" res_replace)" "|rc=0"
check "the replaced database still reads right" "$(rows "$D/fc-gbr-r1.fdb")" "$base"

# --- 4. FAIL-CLOSED: an fbk carrying what this reader cannot ----------------
# (~~a named domain refuses~~ - they ride now; the representative
# refusal is an EXPRESSION INDEX - COMPUTED BY, whose expression this
# restore cannot rebuild; refused typed on both sides)
rm -f "$D/fc-gbr-pk.fdb" "$D/fc-gbr-pk.fbk"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$D/fc-gbr-pk.fdb' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (X INTEGER);
COMMIT;
CREATE TABLE P2 (AGE INTEGER);
CREATE INDEX IXE ON P2 COMPUTED BY (AGE + 1);
COMMIT;
EOF
chmod 666 "$D/fc-gbr-pk.fdb"
svc "$EMGR" action_backup dbname "$D/fc-gbr-pk.fdb" bkp_file "$D/fc-gbr-pk.fbk" >/dev/null
grab "$D/fc-gbr-pk.fbk"
check "an fbk with an EXPRESSION index refuses fc's restore whole" \
    "$(svc "$FMGR" action_restore dbname "$D/fc-gbr-rpk.fdb" bkp_file "$D/fc-gbr-pk.fbk")" \
    "feature is not supported|rc=1"
ran=$((ran + 1))
if [ ! -e "$D/fc-gbr-rpk.fdb" ]; then
    echo "OK   ...and no half-restored database is left behind"
else
    echo "DIFF a refused restore left a file"; fail=1
fi
printf 'garbage' > "$D/fc-gbr-junk.fbk"
check "a non-backup file refuses" \
    "$(svc "$FMGR" action_restore dbname "$D/fc-gbr-rj.fdb" bkp_file "$D/fc-gbr-junk.fbk")" \
    "feature is not supported|rc=1"
rm -f "$D/fc-gbr-junk.fbk"

# --- 5. the privileges are set aside VISIBLY ---------------------------------
ran=$((ran + 1))
skipped=$(grep -c "privilege record(s) set aside" "$LOG")
if [ "$skipped" -ge 1 ]; then
    echo "OK   boundary: privilege records set aside, counted in the trace ($skipped restores)"
else
    echo "DIFF the privilege omission is silent"; fail=1
fi

echo "ran $ran checks"
exit $fail
