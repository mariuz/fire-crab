#!/bin/bash
# GENERATED METADATA NAMES COME FROM THE ENGINE'S COUNTERS, NOT FROM A
# SCAN OF WHAT IS IN USE.
#
# Every name the engine invents for you - a new relation's id, an
# auto-domain `RDB$<n>`, `RDB$PRIMARY<n>` / `RDB$FOREIGN<n>` / `RDB$<n>`
# for an unnamed index, `INTEG_<n>` for an unnamed constraint, the
# implicit generator behind an identity column - is drawn from a system
# GENERATOR: RDB$RELATIONS, RDB$INDEX_NAME, RDB$CONSTRAINT_NAME,
# RDB$FIELD_NAME, RDB$GENERATOR_NAME. Those counters only ever go up. A
# DROP never gives a number back: drop the exception that took 2 and the
# next one is still 3.
#
# fire-crab derived the same names by scanning the catalog for the
# highest one in use and adding one. On a database nobody had dropped
# anything in, the two agree; after the first DROP they diverge for
# every object created afterwards - and on a file BOTH servers write,
# fire-crab hands out the very number the engine's counter is about to
# issue. Two relations with one id share pointer pages, RDB$PAGES rows
# and formats; two indices with one name break MET_lookup_partner and
# DROP INDEX.
#
# The gate runs the SAME DDL script through fire-crab and through the
# engine into two files, then has the ENGINE read both catalogs back and
# compare them: relation names AND RELATION IDS, index names and their
# segments, every RDB$RELATION_CONSTRAINTS row (name, kind, index, and
# the column a NOT NULL names through RDB$CHECK_CONSTRAINTS), the
# auto-domain RDB$FIELD_SOURCE of every user column, the user
# generators, THE FIVE COUNTERS THEMSELVES through GEN_ID, and every row
# of every table. Every statement is followed by a USE of what it
# created, so a statement that reports success and writes nothing cannot
# pass either - and the last section makes a COMMIT's write fail on
# purpose, because a commit that cannot write used to answer success.
#
# (Comparing only relation NAMES defends exactly one of the five
# allocators: measured, a file whose relations are numbered 131..148
# where the engine's counter says 132..151 passes a name check
# byte-for-byte.)
#
# (This gate was written for a reported silent no-op - `CREATE TABLE`
# after `CREATE INDEX` returning rc=0 and writing nothing. That does not
# reproduce; the report was almost certainly an environment artefact,
# the sticky bit on /tmp/fbhandson blocking fire-crab's rename-over of
# an engine-owned file. The name-counter divergence is what the gate
# found instead, and it is real.)
#
#   qa/serve-real-ddlsequence.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4068}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ddlseq-crab.fdb"
B="$D/fc-ddlseq-engine.fdb"
LOG="/tmp/fc-serve-ddlseq-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

# an EMPTY database on each side; every object below is created by the
# server under test, which is the whole point
mk_empty() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE 'localhost:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null; return 0; }
mk_empty "$A" || { echo "FAIL scratch A"; exit 1; }
mk_empty "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D"/fc-ddlseq-nowrite-$PORT.fdb "$D"/ddlseq-$PORT-*.sql' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# run one DDL script through each server, on its own file
both() {
    printf '%s\n' "$2" > "$D/ddlseq-$PORT-e.sql"
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
# what the ENGINE reads from each file - the only judge of what was written
eboth() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}

# ---- 1. a table, an index, then another table --------------------------------
both "CREATE TABLE, then CREATE INDEX, then CREATE TABLE - and use each" \
     "CREATE TABLE ZT (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER); COMMIT;
      INSERT INTO ZT VALUES (1, 10); COMMIT;
      CREATE INDEX ZI ON ZT (A); COMMIT;
      CREATE TABLE ZT2 (ID INTEGER NOT NULL PRIMARY KEY, B INTEGER); COMMIT;
      INSERT INTO ZT2 VALUES (2, 20); COMMIT;
      SELECT COUNT(*) C1 FROM ZT; SELECT COUNT(*) C2 FROM ZT2; SELECT ID, B FROM ZT2;"
both "... a third table and a second index keep working" \
     "CREATE INDEX ZI2 ON ZT2 (B); COMMIT;
      CREATE TABLE ZT3 (ID INTEGER NOT NULL PRIMARY KEY, C VARCHAR(5)); COMMIT;
      INSERT INTO ZT3 VALUES (3, 'c3'); COMMIT;
      SELECT COUNT(*) C FROM ZT3; SELECT ID, C FROM ZT3;"
both "a VIEW created after an index answers" \
     "CREATE VIEW ZV AS SELECT ID, A FROM ZT; COMMIT;
      SELECT ID, A FROM ZV; SELECT COUNT(*) C FROM ZV;"
both "a UNIQUE index, a DESCENDING index and a two-column index, each followed by a table" \
     "CREATE UNIQUE INDEX ZU ON ZT3 (C); COMMIT;
      CREATE TABLE ZT4 (ID INTEGER NOT NULL PRIMARY KEY, D INTEGER); COMMIT;
      INSERT INTO ZT4 VALUES (4, 40); COMMIT;
      CREATE DESCENDING INDEX ZD ON ZT4 (D); COMMIT;
      CREATE TABLE ZT5 (ID INTEGER NOT NULL PRIMARY KEY, E INTEGER, F INTEGER); COMMIT;
      CREATE INDEX ZM ON ZT5 (E, F); COMMIT;
      CREATE TABLE ZT6 (ID INTEGER NOT NULL PRIMARY KEY, G INTEGER); COMMIT;
      INSERT INTO ZT6 VALUES (6, 60); COMMIT;
      SELECT COUNT(*) C4 FROM ZT4; SELECT COUNT(*) C6 FROM ZT6; SELECT ID, G FROM ZT6;"

# ---- 2. other DDL that follows an index --------------------------------------
both "ALTER TABLE ADD, a trigger, a procedure and a generator after an index" \
     "ALTER TABLE ZT6 ADD H INTEGER; COMMIT;
      UPDATE ZT6 SET H = 66 WHERE ID = 6; COMMIT;
      CREATE SEQUENCE ZS; COMMIT;
      SET TERM ^;
      CREATE PROCEDURE ZP (I INTEGER) RETURNS (O INTEGER) AS BEGIN O = I * 2; SUSPEND; END^
      SET TERM ;^
      COMMIT;
      SELECT ID, G, H FROM ZT6; SELECT O FROM ZP(4); SELECT GEN_ID(ZS, 1) N FROM RDB\$DATABASE;"
both "an index on a table that already holds rows, then a table" \
     "CREATE TABLE ZR (ID INTEGER NOT NULL PRIMARY KEY, K INTEGER); COMMIT;
      INSERT INTO ZR VALUES (1, 5); INSERT INTO ZR VALUES (2, 6); INSERT INTO ZR VALUES (3, 5); COMMIT;
      CREATE INDEX ZRI ON ZR (K); COMMIT;
      CREATE TABLE ZT7 (ID INTEGER NOT NULL PRIMARY KEY, J INTEGER); COMMIT;
      INSERT INTO ZT7 VALUES (7, 70); COMMIT;
      SELECT ID FROM ZR WHERE K = 5 ORDER BY ID; SELECT COUNT(*) C FROM ZT7; SELECT ID, J FROM ZT7;"
both "DROP INDEX then CREATE TABLE, and DROP TABLE then CREATE TABLE" \
     "DROP INDEX ZRI; COMMIT;
      CREATE TABLE ZT8 (ID INTEGER NOT NULL PRIMARY KEY, L INTEGER); COMMIT;
      INSERT INTO ZT8 VALUES (8, 80); COMMIT;
      DROP TABLE ZT8; COMMIT;
      CREATE TABLE ZT9 (ID INTEGER NOT NULL PRIMARY KEY, M INTEGER); COMMIT;
      INSERT INTO ZT9 VALUES (9, 90); COMMIT;
      SELECT COUNT(*) C FROM ZT9; SELECT ID, M FROM ZT9;"

# ---- 2b. the OTHER four allocators: a relation id, an INTEG_<n>, an
# auto-domain RDB$<n> and an identity column's implicit generator -------------
both "NOT NULL, PRIMARY KEY, UNIQUE and CHECK interleave in declaration order" \
     "CREATE TABLE ZC1 (ID INTEGER NOT NULL PRIMARY KEY, C INTEGER UNIQUE, D VARCHAR(10) NOT NULL); COMMIT;
      CREATE TABLE ZC2 (A INTEGER NOT NULL CHECK (A > 0), B INTEGER UNIQUE, C INTEGER NOT NULL, CHECK (C < 100), PRIMARY KEY (A)); COMMIT;
      INSERT INTO ZC1 VALUES (1, 1, 'x'); INSERT INTO ZC2 VALUES (5, 2, 7); COMMIT;
      SELECT ID, C, D FROM ZC1; SELECT A, B, C FROM ZC2;"
both "a DROPPED table gives its id and its generated names back to NOBODY" \
     "CREATE TABLE ZDROP (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER); COMMIT;
      DROP TABLE ZDROP; COMMIT;
      CREATE TABLE ZAFTER (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER); COMMIT;
      INSERT INTO ZAFTER VALUES (1, 1); COMMIT;
      SELECT ID, A FROM ZAFTER;"
both "an IDENTITY column's implicit generator" \
     "CREATE TABLE ZID (ID INTEGER GENERATED BY DEFAULT AS IDENTITY, V INTEGER); COMMIT;
      INSERT INTO ZID (V) VALUES (10); INSERT INTO ZID (V) VALUES (20); COMMIT;
      SELECT ID, V FROM ZID ORDER BY 1;"
both "DROP INDEX then CREATE INDEX under the SAME name" \
     "CREATE TABLE ZRE (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER); COMMIT;
      CREATE INDEX ZREI ON ZRE (A); COMMIT;
      DROP INDEX ZREI; COMMIT;
      CREATE INDEX ZREI ON ZRE (A); COMMIT;
      INSERT INTO ZRE VALUES (1, 5); COMMIT;
      SELECT ID, A FROM ZRE WHERE A = 5;"
both "a dropped FOREIGN KEY constraint leaves the PARENT table writable" \
     "CREATE TABLE ZFP (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER); COMMIT;
      CREATE TABLE ZFC (ID INTEGER NOT NULL PRIMARY KEY, P INTEGER); COMMIT;
      ALTER TABLE ZFC ADD CONSTRAINT ZFK FOREIGN KEY (P) REFERENCES ZFP (ID); COMMIT;
      ALTER TABLE ZFC DROP CONSTRAINT ZFK; COMMIT;
      INSERT INTO ZFP VALUES (1, 100); COMMIT;
      INSERT INTO ZFC VALUES (1, 1); COMMIT;
      SELECT ID, V FROM ZFP; SELECT ID, P FROM ZFC;"

# ---- 3. what the ENGINE reads back from each file ----------------------------
eboth "the ENGINE lists the same user relations in both files" \
      "SELECT TRIM(RDB\$RELATION_NAME) R FROM RDB\$RELATIONS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;"
# THE RELATION ID, the headline allocator: a name check alone passes on a
# file whose relations are numbered densely where the engine's counter
# has moved on (measured: 131..148 against the engine's 132..151).
eboth "the ENGINE gives every user relation the same RELATION ID in both files" \
      "SELECT TRIM(RDB\$RELATION_NAME) R, RDB\$RELATION_ID I FROM RDB\$RELATIONS
       WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;"
# the INTEG_<n> sequence AND what each name is attached to - the NOT NULL
# rows name their column through RDB\$CHECK_CONSTRAINTS
eboth "the ENGINE reads the same constraints, names, kinds and indices" \
      "SELECT TRIM(c.RDB\$RELATION_NAME) R, TRIM(c.RDB\$CONSTRAINT_NAME) C,
              TRIM(c.RDB\$CONSTRAINT_TYPE) T, TRIM(COALESCE(c.RDB\$INDEX_NAME, '-')) X,
              TRIM(COALESCE(k.RDB\$TRIGGER_NAME, '-')) K
       FROM RDB\$RELATION_CONSTRAINTS c
       LEFT JOIN RDB\$CHECK_CONSTRAINTS k ON k.RDB\$CONSTRAINT_NAME = c.RDB\$CONSTRAINT_NAME
       WHERE c.RDB\$RELATION_NAME NOT STARTING WITH 'RDB\$' ORDER BY 1, 2, 5;"
# the auto-domain RDB\$<n> behind every user column
eboth "the ENGINE reads the same FIELD SOURCE for every user column" \
      "SELECT TRIM(RDB\$RELATION_NAME) R, TRIM(RDB\$FIELD_NAME) F, TRIM(RDB\$FIELD_SOURCE) S
       FROM RDB\$RELATION_FIELDS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1, 2;"
# the user generators - an identity column's implicit RDB\$<n> among them
eboth "the ENGINE lists the same generators in both files" \
      "SELECT TRIM(RDB\$GENERATOR_NAME) G, RDB\$INITIAL_VALUE V, RDB\$GENERATOR_INCREMENT I
       FROM RDB\$GENERATORS WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY 1;"
# AND THE COUNTERS THEMSELVES, which is what this whole chunk is about:
# every generated name above came out of one of these five, and a server
# that scanned the catalog instead leaves them behind.
eboth "the five metadata COUNTERS read the same in both files" \
      "SELECT GEN_ID(RDB\$RELATIONS, 0) RELS, GEN_ID(RDB\$INDEX_NAME, 0) IXN,
              GEN_ID(RDB\$CONSTRAINT_NAME, 0) CON, GEN_ID(RDB\$FIELD_NAME, 0) FLD,
              GEN_ID(RDB\$GENERATOR_NAME, 0) GEN FROM RDB\$DATABASE;"
# RDB$TEMP_DEPEND_<rel>_<n> - the deferred-drop stub BOTH servers leave
# behind a DROP INDEX - is left out on purpose: the ENGINE eventually
# removes its own (reusing the dropped name removes it at once), and
# fire-crab never does. That is a recorded, pre-existing metadata leak
# (docs/roadmap.md), not a name this gate is about; every name a COUNTER
# handed out is still compared.
eboth "the ENGINE lists the same user indices and their segments" \
      "SELECT TRIM(RDB\$INDEX_NAME) I, TRIM(RDB\$RELATION_NAME) R FROM RDB\$INDICES
       WHERE (RDB\$SYSTEM_FLAG = 0 OR RDB\$SYSTEM_FLAG IS NULL)
         AND RDB\$INDEX_NAME NOT STARTING WITH 'RDB\$TEMP_DEPEND' ORDER BY 1;
       SELECT TRIM(RDB\$INDEX_NAME) I, TRIM(RDB\$FIELD_NAME) F, RDB\$FIELD_POSITION P
       FROM RDB\$INDEX_SEGMENTS ORDER BY 1, 3;"
eboth "the ENGINE reads the same rows out of every table both servers built" \
      "SELECT ID, A FROM ZT ORDER BY ID; SELECT ID, B FROM ZT2 ORDER BY ID; SELECT ID, C FROM ZT3 ORDER BY ID;
       SELECT ID, D FROM ZT4 ORDER BY ID; SELECT ID, G, H FROM ZT6 ORDER BY ID; SELECT ID, K FROM ZR ORDER BY ID;
       SELECT ID, J FROM ZT7 ORDER BY ID; SELECT ID, M FROM ZT9 ORDER BY ID; SELECT ID, A FROM ZV ORDER BY ID;"

# ---- 4. the last statement of all still writes -------------------------------
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/tmp/fc-ddlseq-2nd-$PORT.txt 2>&1 <<'SQL'
SET LIST ON;
CREATE TABLE ZLAST (ID INTEGER NOT NULL PRIMARY KEY, V INTEGER);
COMMIT;
INSERT INTO ZLAST VALUES (1, 1);
COMMIT;
SELECT COUNT(*) C FROM ZLAST;
SQL
got=$(norm < /tmp/fc-ddlseq-2nd-$PORT.txt)
check "a table created after every other statement is usable" "$got" "C 1|"
e=$(printf 'SET LIST ON; SELECT COUNT(*) C FROM ZLAST;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 | norm)
check "... and the ENGINE reads it out of fire-crab's file" "$e" "C 1|"

# ---- 5. A COMMIT THAT CANNOT WRITE REPORTS AN ERROR --------------------------
# The other half of "a statement either does what it says or reports an
# error": every write in this server lands at the COMMIT, and the commit's
# own Result used to be traced and dropped, so a transaction whose flush
# failed answered the client a CLEAN op_response and was lost with nothing
# on disk - the DDL and the DML alike (measured: `INSERT` then `COMMIT`,
# then `CREATE TABLE` then `COMMIT`, all silent, all absent afterwards).
# The failure is made deterministically: a COPY of fire-crab's own file,
# the attachment opened on it, and only THEN the write permission removed,
# so it is the flush that fails and not the attach.
AW="$D/fc-ddlseq-nowrite-$PORT.fdb"
AWOUT="/tmp/fc-ddlseq-nowrite-$PORT.txt"
cp "$A" "$AW" && chmod 666 "$AW"
(
    echo "SET LIST ON;"
    echo "SELECT COUNT(*) C0 FROM ZT;"   # the attachment is open from here
    sleep 3
    echo "INSERT INTO ZT VALUES (99, 99);"
    echo "COMMIT;"
) | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$AW" >"$AWOUT" 2>&1 &
aw=$!
sleep 1.5; chmod 000 "$AW" 2>/dev/null
wait $aw
chmod 666 "$AW" 2>/dev/null
if grep -q 'I/O error during' "$AWOUT"; then got=reported; else got="silent: $(norm < "$AWOUT")"; fi
check "a COMMIT whose write FAILS answers an error, not success" "$got" "reported"
e=$(printf 'SET LIST ON; SELECT COUNT(*) C FROM ZT;\n' \
    | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$AW" 2>&1 | norm)
check "... and the ENGINE agrees that row was never written" "$e" "C 1|"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
