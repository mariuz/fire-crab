#!/bin/bash
# A KEY CONSTRAINT'S `USING [ASC | DESC] INDEX <name>`, and RDB$INDEX_TYPE.
#
# `.. PRIMARY KEY (..) USING DESC INDEX PXC`, `.. UNIQUE (..) USING INDEX
# UXC`, `.. FOREIGN KEY .. REFERENCES .. USING ASC INDEX FXC` - in CREATE
# TABLE and ALTER TABLE ADD alike - name the backing index; an unnamed
# constraint is still INTEG_<n>. Every one refused at prepare here.
# Measured on 2196, and the second half of this gate: a CONSTRAINT's index
# leaves RDB$INDEX_TYPE NULL unless it is DESCENDING (1), and only a bare
# CREATE INDEX writes 0 / 1 - this server wrote 0 for every UNIQUE
# constraint, and NULL for a descending primary key.
#
# Each cell runs one isql script on twin files and compares the whole
# output (no PLAN lines - `SET PLAN` is a separate gap); the last section
# has the ENGINE read the file this server wrote.
#
#   qa/serve-real-usingindex.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4603}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/usingix-eng.fdb"; FC="$D/usingix-fc.fdb"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-usingix-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
fresh() {
    rm -f "$ENG" "$FC"
    printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s' DEFAULT CHARACTER SET UTF8;
CREATE TABLE P (K INTEGER NOT NULL, V VARCHAR(5));
INSERT INTO P VALUES (1, 'a');
INSERT INTO P VALUES (2, 'b');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/usingix-build.log 2>&1
    [ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/usingix-build.log; exit 1; }
    cp "$ENG" "$FC"; chmod 666 "$FC"
}
R='RDB$'
CAT="COMMIT;
SELECT ${R}CONSTRAINT_NAME, ${R}CONSTRAINT_TYPE, ${R}INDEX_NAME FROM ${R}RELATION_CONSTRAINTS WHERE ${R}RELATION_NAME NOT STARTING 'RDB\$' AND ${R}RELATION_NAME NOT STARTING 'MON\$' AND ${R}RELATION_NAME NOT STARTING 'SEC\$' ORDER BY 1;
SELECT ${R}INDEX_NAME, ${R}RELATION_NAME, ${R}UNIQUE_FLAG, ${R}INDEX_TYPE, ${R}FOREIGN_KEY, ${R}INDEX_ID, ${R}SEGMENT_COUNT FROM ${R}INDICES WHERE ${R}SYSTEM_FLAG = 0 ORDER BY 1;"
both() { # <label> <script>
    ran=$((ran + 1))
    fresh
    local e c
    e=$(printf '%s\n%s\n' "$2" "$CAT" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf '%s\n%s\n' "$2" "$CAT" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "${e#*INDEX_NAME}" = "$e" ]; then echo "FAIL $1 [the engine never read back: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
    # ...and the ENGINE reads the file this server wrote: the indexes it
    # made are the engine's to walk, and the file validates
    local gf ef ee
    ran=$((ran + 1))
    gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
    ee=$(printf '%s\n' "SELECT K FROM P ORDER BY K DESC; SELECT V FROM P WHERE V > 'a';" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    ef=$(printf '%s\n' "SELECT K FROM P ORDER BY K DESC; SELECT V FROM P WHERE V > 'a';" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$FC" 2>&1 | norm)
    if [ -n "$gf" ]; then echo "FAIL $1 - gfix -v -full: $gf"; fail=1
    elif [ "$ee" != "$ef" ]; then echo "DIFF $1 - the engine reading this server's file"; echo "     eng file: [$ee]"; echo "     fc file:  [$ef]"; fail=1
    else echo "OK   $1 - gfix clean, the engine reads the file alike"; fi
}

echo "--- 1 USING INDEX names the index; DESC sets RDB\$INDEX_TYPE 1"
both "1 ALTER: a UNIQUE over a DESCENDING index"   "ALTER TABLE P ADD CONSTRAINT U4 UNIQUE (V) USING DESCENDING INDEX UX4;"
both "1 ALTER: a PRIMARY KEY over a named index"   "ALTER TABLE P ADD CONSTRAINT PK1 PRIMARY KEY (K) USING INDEX PXK;"
both "1 ALTER: an unnamed UNIQUE: INTEG_<n> over UXC" "ALTER TABLE P ADD UNIQUE (V) USING INDEX UXC;"
both "1 ALTER: ASC, ASCENDING, DESC spellings"     "ALTER TABLE P ADD CONSTRAINT U1 UNIQUE (V) USING ASC INDEX UA; ALTER TABLE P ADD CONSTRAINT PK2 PRIMARY KEY (K) USING DESC INDEX PD;"
both "1 CREATE TABLE: a PK USING DESC, an FK USING ASC" "ALTER TABLE P ADD CONSTRAINT PK1 PRIMARY KEY (K); COMMIT; CREATE TABLE C (ID INTEGER NOT NULL, K INTEGER, CONSTRAINT PKC PRIMARY KEY (ID) USING DESC INDEX PXC, CONSTRAINT FKC FOREIGN KEY (K) REFERENCES P (K) USING ASC INDEX FXC);"
both "1 an FK with actions, then USING"            "ALTER TABLE P ADD CONSTRAINT PK1 PRIMARY KEY (K); COMMIT; CREATE TABLE C (ID INTEGER, K INTEGER); COMMIT; ALTER TABLE C ADD CONSTRAINT FKC FOREIGN KEY (K) REFERENCES P (K) ON DELETE CASCADE USING DESCENDING INDEX FXD;"
both "1 the named index enforces: a duplicate names the constraint" "ALTER TABLE P ADD CONSTRAINT U4 UNIQUE (V) USING DESC INDEX UX4; COMMIT; INSERT INTO P VALUES (3, 'a');"
both "1 DROP CONSTRAINT takes the named index"     "ALTER TABLE P ADD CONSTRAINT U4 UNIQUE (V) USING DESC INDEX UX4; COMMIT; ALTER TABLE P DROP CONSTRAINT U4;"
echo "--- 2 RDB\$INDEX_TYPE without USING: NULL on a constraint's index, 0/1 on a bare one"
both "2 UNIQUE constraints (named, unnamed, table-level) and two bare indexes" \
"CREATE TABLE Q (A INTEGER NOT NULL, B INTEGER, C INTEGER, CONSTRAINT UQB UNIQUE (B), UNIQUE (C)); ALTER TABLE Q ADD CONSTRAINT UQA UNIQUE (A); CREATE INDEX IQ ON Q (B); CREATE DESCENDING INDEX IQD ON Q (C);"
both "2 a column-level PRIMARY KEY and UNIQUE"     "CREATE TABLE Q2 (A INTEGER NOT NULL PRIMARY KEY, B INTEGER UNIQUE);"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-usingix-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 21 ]; then echo "FAIL only $ran checks ran (floor 21) - cells went missing"; fail=1; fi
exit $fail
