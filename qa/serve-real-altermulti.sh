#!/bin/bash
# ALTER TABLE WITH SEVERAL ADD CLAUSES - `ALTER TABLE T ADD A INTEGER, ADD
# B DATE` - is one statement and ONE new format: measured on 6.0.0.2196,
# three ADDs in one statement take the table from format 1 to 2 where
# three statements take it to 4. Each column's catalog rows follow in
# clause order (RDB$2, RDB$3, ..; INTEG_<n>; position; field id), a NOT
# NULL column with a DEFAULT fills the rows already there, and the
# statement fails AS ONE: a duplicate name (the table's own, or twice in
# the statement) is the unique-key violation on RDB$RELATION_FIELDS, a NOT
# NULL without a default over rows is 22006 - and nothing is added.
#
# This server refused every multi-clause ALTER at prepare. CONSTRAINT
# clauses run after every column, in clause order (section 1b - the
# engine's order: a UNIQUE may name a column added later in the
# statement). A DROP or ALTER clause, a CHECK over a column the same
# statement adds, or a COMPUTED column beside others still refuses
# (section 4, recorded). The single ADD of
# an existing name answered a bare "Dynamic SQL Error" (section 3).
#
#   qa/serve-real-altermulti.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4600}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/altermulti-eng.fdb"; FC="$D/altermulti-fc.fdb"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-altermulti-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
# (a blob column under SET LIST prints the server's own blob id before
# the text - its numbering, not the content)
norm() { grep -a -v '^$' | sed -E 's/  */ /g; s/ [0-9a-f]+:[0-9a-f]+$/ BLOBID/; s/ *$//' | tr '\n' '|'; }
# a fresh pair of twin files per cell: a table T (ID) with one row, a
# table E with none
fresh() {
    rm -f "$ENG" "$FC"
    printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INTEGER);
CREATE TABLE E (ID INTEGER);
INSERT INTO T VALUES (1);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/altermulti-build.log 2>&1
    [ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/altermulti-build.log; exit 1; }
    cp "$ENG" "$FC"; chmod 666 "$FC"
}
R='RDB$'
# what every cell reads back after its script: the format, the fields'
# catalog rows, the constraints, the rows themselves
READ="COMMIT;
SELECT ${R}RELATION_NAME, ${R}FORMAT, ${R}FIELD_ID FROM ${R}RELATIONS WHERE ${R}RELATION_NAME IN ('T', 'E') ORDER BY 1;
SELECT ${R}RELATION_NAME, ${R}FIELD_NAME, ${R}FIELD_POSITION, ${R}FIELD_ID, ${R}FIELD_SOURCE, ${R}NULL_FLAG, ${R}DEFAULT_SOURCE, ${R}COLLATION_ID FROM ${R}RELATION_FIELDS WHERE ${R}RELATION_NAME IN ('T', 'E') ORDER BY 1, 3;
SELECT F.${R}FIELD_NAME, F.${R}FIELD_TYPE, F.${R}FIELD_LENGTH, F.${R}FIELD_SCALE, F.${R}FIELD_SUB_TYPE, F.${R}CHARACTER_SET_ID, F.${R}CHARACTER_LENGTH FROM ${R}FIELDS F WHERE F.${R}FIELD_NAME STARTING 'RDB\$' AND F.${R}SYSTEM_FLAG = 0 ORDER BY 1;
SELECT ${R}RELATION_NAME, ${R}CONSTRAINT_NAME, ${R}CONSTRAINT_TYPE FROM ${R}RELATION_CONSTRAINTS WHERE ${R}RELATION_NAME IN ('T', 'E') ORDER BY 2;
SELECT ${R}FORMAT FROM ${R}FORMATS F JOIN ${R}RELATIONS R ON R.${R}RELATION_ID = F.${R}RELATION_ID WHERE R.${R}RELATION_NAME = 'T' ORDER BY 1;
SELECT * FROM T;
SELECT * FROM E;"
both() { # <label> <script>
    ran=$((ran + 1))
    fresh
    local e c
    e=$(printf 'SET LIST ON;\n%s\n%s\n' "$2" "$READ" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n%s\n' "$2" "$READ" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "${e#*FORMAT}" = "$e" ]; then echo "FAIL $1 [the engine never read back: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
    # the file this server wrote must validate
    local gf
    gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
    ran=$((ran + 1))
    if [ -n "$gf" ]; then echo "FAIL $1 - gfix -v -full: $gf"; fail=1; else echo "OK   $1 - gfix clean"; fi
}
recorded() { # <label> <script> - the engine answers, this server refuses at prepare
    ran=$((ran + 1))
    fresh
    local e c
    e=$(printf '%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ -n "$e" ]; then echo "FAIL $1 - the ENGINE no longer answers [$e]"; fail=1
    elif [ "$c" = "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|After line 0 in file -|" ] || [ "${c#Statement failed, SQLSTATE = 42000|Dynamic SQL Error|}" != "$c" ]; then
        echo "OK   $1 (recorded: the engine answers, this server refuses)"
    else echo "FAIL $1 - this server moved; promote if it matches: [$c]"; fail=1; fi
}

echo "--- 1 several ADDs, one format"
both "1 two columns"                         "ALTER TABLE T ADD A INTEGER, ADD B DATE;"
both "1 three, with a default and NOT NULL"  "ALTER TABLE T ADD A INTEGER, ADD B VARCHAR(10) DEFAULT 'x', ADD C INTEGER DEFAULT 5 NOT NULL;"
both "1 two NOT NULL defaults over a row"    "ALTER TABLE T ADD A INTEGER DEFAULT 7 NOT NULL, ADD B VARCHAR(3) DEFAULT 'q' NOT NULL;"
both "1 text in sets, a NUMERIC, a BLOB"     "ALTER TABLE T ADD S1 VARCHAR(5) CHARACTER SET WIN1252, ADD S2 CHAR(3), ADD N NUMERIC(9,2), ADD BL BLOB SUB_TYPE TEXT, ADD BI BIGINT;"
both "1 an IDENTITY on an empty table"       "ALTER TABLE E ADD K INTEGER GENERATED BY DEFAULT AS IDENTITY, ADD V VARCHAR(5); INSERT INTO E (ID, V) VALUES (1, 'a'); INSERT INTO E (ID, V) VALUES (2, 'b');"
both "1 line breaks, lower case, a quoted name" $'alter table t\n  add a integer,\n  add "b c" varchar(4) default \'z\';'
both "1 a default holding a comma"           "ALTER TABLE T ADD A VARCHAR(10) DEFAULT 'a,b', ADD B INTEGER;"
both "1 two statements: two formats (control)" "ALTER TABLE T ADD A INTEGER; ALTER TABLE T ADD B INTEGER;"
both "1 then DML: new rows carry both"       "ALTER TABLE T ADD A INTEGER, ADD B VARCHAR(5); COMMIT; INSERT INTO T VALUES (2, 3, 'w'); UPDATE T SET B = 'u' WHERE ID = 1;"
echo "--- 2 the statement fails as one"
both "2 a name twice in the statement"       "ALTER TABLE T ADD D INTEGER, ADD D DATE;"
both "2 the table's own name"                "ALTER TABLE T ADD E INTEGER, ADD ID DATE;"
both "2 NOT NULL without a default over a row" "ALTER TABLE T ADD F INTEGER, ADD G INTEGER NOT NULL;"
both "2 ...over an EMPTY table it is made"   "ALTER TABLE E ADD F INTEGER, ADD G INTEGER NOT NULL;"
echo "--- 3 the single ADD of an existing name: the same vector"
both "3 ADD ID"                              "ALTER TABLE T ADD ID DATE;"
echo "--- 1b CONSTRAINT clauses: after every column, in clause order"
KEYS="SELECT ${R}CONSTRAINT_NAME, ${R}CONSTRAINT_TYPE, ${R}INDEX_NAME FROM ${R}RELATION_CONSTRAINTS WHERE ${R}RELATION_NAME IN ('T', 'E', 'P') ORDER BY 1;
SELECT ${R}INDEX_NAME, ${R}RELATION_NAME, ${R}UNIQUE_FLAG, ${R}FOREIGN_KEY, ${R}INDEX_ID FROM ${R}INDICES WHERE ${R}SYSTEM_FLAG = 0 ORDER BY 1;
SELECT ${R}TRIGGER_NAME, ${R}RELATION_NAME, ${R}TRIGGER_TYPE FROM ${R}TRIGGERS WHERE ${R}SYSTEM_FLAG <> 1 ORDER BY 1;"
both "1b a column, then its PRIMARY KEY"      "ALTER TABLE E ADD H INTEGER NOT NULL, ADD CONSTRAINT PK1 PRIMARY KEY (H); COMMIT; $KEYS"
both "1b two constraints on existing columns" "ALTER TABLE T ADD CONSTRAINT U1 UNIQUE (ID), ADD CONSTRAINT CK1 CHECK (ID > 0); COMMIT; $KEYS"
both "1b a UNIQUE naming a column added AFTER it" "ALTER TABLE E ADD CONSTRAINT U2 UNIQUE (H2), ADD H2 INTEGER; COMMIT; $KEYS"
both "1b interleaved: NOT NULL, PK, a column, CHECK on an old one" "ALTER TABLE E ADD H3 INTEGER NOT NULL, ADD CONSTRAINT PK3 PRIMARY KEY (H3), ADD H4 INTEGER, ADD CONSTRAINT CK4 CHECK (ID > 0); COMMIT; $KEYS"
both "1b UNNAMED: a PRIMARY KEY and a UNIQUE"  "ALTER TABLE E ADD H INTEGER NOT NULL, ADD PRIMARY KEY (H), ADD UNIQUE (ID); COMMIT; $KEYS"
both "1b a FOREIGN KEY to a new key"           "CREATE TABLE P (K INTEGER NOT NULL PRIMARY KEY); COMMIT; ALTER TABLE E ADD PK INTEGER, ADD FOREIGN KEY (PK) REFERENCES P (K), ADD CONSTRAINT FK2 FOREIGN KEY (ID) REFERENCES P; COMMIT; $KEYS"
# a UNIQUE over duplicate rows fails the statement and NOTHING stays - the
# column clause before it included; the VECTOR is recorded: the engine
# names the constraint and the key ("U9" on "PUBLIC"."T", ("ID" = 1)),
# this server's index build reports no key and it answers a bare
# Dynamic SQL Error - the single-clause ADD CONSTRAINT the same
ran=$((ran + 1))
fresh
S1B="INSERT INTO T VALUES (1); COMMIT; ALTER TABLE T ADD Z INTEGER, ADD CONSTRAINT U9 UNIQUE (ID); COMMIT; $KEYS"
e=$(printf 'SET LIST ON;\n%s\n%s\n' "$S1B" "$READ" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
c=$(printf 'SET LIST ON;\n%s\n%s\n' "$S1B" "$READ" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
if [ "${e#*violation of PRIMARY or UNIQUE KEY constraint \"U9\"}" = "$e" ]; then echo "FAIL 1b a duplicate - the ENGINE moved [$e]"; fail=1
elif [ "RDB\$RELATION_NAME${e#*RDB\$RELATION_NAME}" != "RDB\$RELATION_NAME${c#*RDB\$RELATION_NAME}" ]; then
    echo "DIFF 1b a duplicate: the state after it"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1
elif [ "$e" = "$c" ]; then echo "FAIL 1b a duplicate - THE VECTOR AGREES NOW; make it a both cell"; fail=1
else echo "OK   1b a duplicate over the row fails it whole, nothing stays (recorded: the vector)"; fi
echo "--- 4 RECORDED - a clause that is not an ADD, or a COMPUTED column beside others"
recorded "4 DROP beside ADD"                 "ALTER TABLE T ADD H INTEGER, DROP ID;"
recorded "4 a CHECK over a column added beside it" "ALTER TABLE T ADD H INTEGER, ADD CONSTRAINT CK5 CHECK (H > 0);"
recorded "4 a COMPUTED column over one added beside it" "ALTER TABLE T ADD K INTEGER, ADD L COMPUTED BY (K + 1);"

echo "--- 5 RECORDED - a SIBLING transaction's snapshot loses the old catalog row"
# isql (AUTODDL ON) runs each DDL statement in a transaction of its own
# beside the main one; the main SNAPSHOT, opened before the ALTER, still
# reads the RDB\$RELATIONS row at format 1 on the engine. This server
# purges the old version at the DDL's commit (a sibling of the SAME
# attachment is not counted as a reader) and the snapshot reads NO ROW.
# Holding every purge back while a sibling lives is no fix - isql always
# has one, and the catalog's dead versions pile up (blobgc / blobsweep
# measured it); the engine keeps exactly the versions a live snapshot
# can still see. Pinned: both answers, so a move either way is seen.
ran=$((ran + 1))
fresh
S5="SELECT COUNT(*) AS T1 FROM T;
ALTER TABLE T ADD Q INTEGER;
SELECT ${R}FORMAT AS F2 FROM ${R}RELATIONS WHERE ${R}RELATION_NAME = 'T';
COMMIT;
SELECT ${R}FORMAT AS F3 FROM ${R}RELATIONS WHERE ${R}RELATION_NAME = 'T';"
e=$(printf '%s\n' "$S5" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
c=$(printf '%s\n' "$S5" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
we=" T1|=====================| 1| F2|=======| 1| F3|=======| 2|"
wc=" T1|=====================| 1| F3|=======| 2|"
if [ "$e" = "$c" ]; then echo "FAIL 5 the sibling snapshot - IT AGREES NOW; promote the cell"; fail=1
elif [ "$e" = "$we" ] && [ "$c" = "$wc" ]; then echo "OK   5 the sibling snapshot (recorded: the engine reads format 1, this server no row)"
else echo "FAIL 5 the sibling snapshot moved"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-altermulti-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 46 ]; then echo "FAIL only $ran checks ran (floor 46) - cells went missing"; fail=1; fi
exit $fail
