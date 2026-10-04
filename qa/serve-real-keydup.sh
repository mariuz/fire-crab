#!/bin/bash
# A KEY BUILT OVER ROWS THAT ALREADY HOLD IT TWICE.
#
# `ALTER TABLE .. ADD [CONSTRAINT ..] PRIMARY KEY | UNIQUE (..)` and
# `CREATE UNIQUE INDEX` over duplicate rows fail inside the statement's
# "<VERB> @1 failed": the unique-key violation naming the CONSTRAINT (an
# unnamed one by the INTEG_<n> it was given), or for a bare unique index
# isc_no_dup "attempt to store duplicate value (visible to active
# transactions) in unique index", then the key. The key is the FIRST one
# the build meets twice in the index's own order (measured on 2196:
# duplicates of 5 and of 3 name 3; a partial-NULL compound key collides,
# `("ID" = NULL, "V" = 'e')`; all-NULL keys do not). This server answered
# a bare Dynamic SQL Error for every one of them.
#
# `USING DESCENDING INDEX` on a constraint names 5 (section 3).
#
#   qa/serve-real-keydup.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4602}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/keydup-eng.fdb"; FC="$D/keydup-fc.fdb"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-keydup-$PORT.log" 2>&1 & srv=$!
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
CREATE TABLE D (ID INTEGER, V VARCHAR(5), N INTEGER NOT NULL, C CHAR(4), DT DATE, X NUMERIC(9,2));
COMMIT;
INSERT INTO D VALUES (5, 'b', 1, 'aa', DATE '2020-01-02', 1.50);
INSERT INTO D VALUES (3, 'a', 2, 'aa', DATE '2020-01-02', 2.25);
INSERT INTO D VALUES (5, 'c', 3, 'bb', DATE '2021-03-04', 1.50);
INSERT INTO D VALUES (3, 'd', 4, 'cc', DATE '2019-05-06', 7.00);
INSERT INTO D VALUES (NULL, 'e', 5, NULL, NULL, NULL);
INSERT INTO D VALUES (NULL, 'e', 5, NULL, NULL, NULL);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/keydup-build.log 2>&1
    [ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/keydup-build.log; exit 1; }
    cp "$ENG" "$FC"; chmod 666 "$FC"
}
# what each cell reads back: nothing stayed
READ="COMMIT;
SELECT RDB\$CONSTRAINT_NAME, RDB\$CONSTRAINT_TYPE FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME = 'D' ORDER BY 1;
SELECT RDB\$INDEX_NAME FROM RDB\$INDICES WHERE RDB\$RELATION_NAME = 'D' ORDER BY 1;
SELECT COUNT(*) AS N FROM D;"
both() { # <label> <statement>
    ran=$((ran + 1))
    fresh
    local e c
    e=$(printf '%s\n%s\n' "$2" "$READ" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf '%s\n%s\n' "$2" "$READ" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "${e#*N|}" = "$e" ]; then echo "FAIL $1 [the engine never read back: $e]"; fail=1
    elif [ "$c" = "$e" ]; then echo "OK   $1 [${e%%|After*}]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

echo "--- 1 ADD CONSTRAINT over duplicate rows: the first key in index order"
both "1 UNIQUE (ID): 3, not 5"                     "ALTER TABLE D ADD CONSTRAINT U1 UNIQUE (ID);"
both "1 UNIQUE (V): a text key"                    "ALTER TABLE D ADD CONSTRAINT U2 UNIQUE (V);"
both "1 UNIQUE (ID, V): a partial-NULL key collides" "ALTER TABLE D ADD CONSTRAINT U3 UNIQUE (ID, V);"
both "1 PRIMARY KEY (N)"                           "ALTER TABLE D ADD CONSTRAINT P1 PRIMARY KEY (N);"
both "1 an unnamed UNIQUE: its INTEG_<n>"          "ALTER TABLE D ADD UNIQUE (ID);"
both "1 a CHAR key prints without its pad"         "ALTER TABLE D ADD CONSTRAINT U5 UNIQUE (C);"
both "1 a DATE key"                                "ALTER TABLE D ADD CONSTRAINT U6 UNIQUE (DT);"
both "1 a NUMERIC key"                             "ALTER TABLE D ADD CONSTRAINT U7 UNIQUE (X);"
both "1 a compound key of three: none collide, made" "ALTER TABLE D ADD CONSTRAINT U8 UNIQUE (C, DT, X);"
both "1 in a multi-clause ALTER, after a column"   "ALTER TABLE D ADD Z INTEGER, ADD CONSTRAINT U9 UNIQUE (ID);"
echo "--- 2 a bare CREATE UNIQUE INDEX: isc_no_dup"
both "2 CREATE UNIQUE INDEX"                       "CREATE UNIQUE INDEX UX5 ON D (ID);"
both "2 ...DESCENDING: 5 comes first"              "CREATE UNIQUE DESCENDING INDEX UX6 ON D (ID);"
both "2 ...over a text column"                     "CREATE UNIQUE INDEX UX7 ON D (V);"
echo "--- 4 CONTROLS - no duplicate: the key is made"
both "4 UNIQUE over distinct rows"                 "DELETE FROM D WHERE ID = 3 OR V = 'e'; COMMIT; ALTER TABLE D ADD CONSTRAINT U1 UNIQUE (V);"
both "4 all-NULL keys do not collide"              "DELETE FROM D WHERE V <> 'e'; COMMIT; ALTER TABLE D ADD CONSTRAINT U1 UNIQUE (ID);"
echo "--- 3 USING DESCENDING INDEX on a constraint: 5 comes first (refused at prepare until 2026-10-04)"
both "3 ADD CONSTRAINT .. USING DESCENDING INDEX"  "ALTER TABLE D ADD CONSTRAINT U4 UNIQUE (ID) USING DESCENDING INDEX UX4;"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-keydup-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 17 ]; then echo "FAIL only $ran checks ran (floor 17) - cells went missing"; fail=1; fi
exit $fail
