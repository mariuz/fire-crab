#!/bin/bash
# A COLLATION DECIDES WHICH ROWS ARE ONE GROUP, ONE PARTITION, ONE PEER
# GROUP, ONE SET MEMBER - AND WHICH SPELLING OF THEM SURVIVES.
#
# Measured on engine 2182 (2026-09-26) and read against its sources
# (SortedStream / AggregatedStream / sort.cpp / unicode_util.cpp):
#
#   * a sort (ORDER BY, a window's PARTITION BY / ORDER BY) keys an ICU
#     collation with its SORT collator, which is FULL strength whatever
#     the collation's own strength: 'abc', 'aBC', 'Abc', 'AbC', 'ABC' in
#     that order under UNICODE_CI. A GROUP BY / DISTINCT / UNION sort is
#     a UNIQUE sort and keys with the COMPARE collator at the collation's
#     own strength - all five are one key. Boundaries - the group, the
#     partition, the window's peer group - are MOV_compare at the own
#     strength, so ROW_NUMBER() OVER (ORDER BY ci) numbers the five 1..5
#     while DENSE_RANK() gives them one rank;
#   * the survivor of a merged group or set member is the LAST row in
#     the sort record's order: the keys, then the referenced fields' NULL
#     flags and values in field order (an ICU-collated key is a VOLATILE
#     key and its value rides among them; a byte-collated one is restored
#     from the key slot and rides nowhere), then the record number.
#     GROUP BY ci over {abc, ABC, Abc} in any insertion order keeps 'abc'
#     (the last by the record's text compare: byte length, then 4-byte
#     little-endian words); with ID referenced anywhere it keeps the
#     highest ID's spelling; a PAD SPACE key ('abc' / 'abc ') keeps the
#     row fed last. DISTINCT drops the earlier of two adjacent equals, so
#     it keeps the same row;
#   * a fold sees the group in that order: MIN/MAX keep the FIRST of the
#     rows the collation calls equal, LIST(DISTINCT ci) sorts at full
#     strength and keeps the first of each own-strength run.
#
# This server (the fc/integ binary before this gate) refused every GROUP
# BY / DISTINCT / UNION / HAVING / LIST(DISTINCT) / grouped MIN-MAX over a
# CI or AI column, partitioned and ranked windows by BYTES (every spelling
# its own partition; five ranks for one), showed the first-fed spelling of
# a PAD SPACE group, and bucketed `GROUP BY ci || 'x'` by bytes.
#
# RECORDED, not fixed (the `refused` cells, each a clean refusal): a
# DISTINCT whose survivor the projection cannot name (a WHERE on a column
# it does not carry: the record orders that column first when its field
# id is lower), and the same shape as a grouped DERIVED source; DISTINCT
# over more than one column with an ORDER BY on the collated one (the
# engine folds the ORDER BY into the unique sort and the ties come back
# in the other columns' order); a grouped JOIN over CI keys whose group
# merges spellings (the fold runs in delivery order; the joined record's
# order is a later slice); a narrow charset's collation (WIN_PTBR), a
# keyword-only RANGE frame and a windowed LIST (all three pre-existing);
# and the engine's -104 for a select-list column that is not the `GROUP
# BY <col> COLLATE` key, which this server answers with its bare 42000.
#
# Usage: qa/serve-real-collkey.sh [port]   (default 5770)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5770}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/collkey-eng.fdb"; FC="$D/collkey-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;"
  cat <<'SQL'
CREATE TABLE CS (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO CS VALUES (1,'abc'); INSERT INTO CS VALUES (2,'ABC'); INSERT INTO CS VALUES (3,'Abc'); INSERT INTO CS VALUES (4,'b');
CREATE TABLE CP (ID INTEGER, P VARCHAR(10));
INSERT INTO CP VALUES (1,'abc '); INSERT INTO CP VALUES (2,'abc');
CREATE TABLE C2 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO C2 VALUES (1,'ABC'); INSERT INTO C2 VALUES (2,'Abc'); INSERT INTO C2 VALUES (3,'abc'); INSERT INTO C2 VALUES (4,'aBC');
INSERT INTO C2 VALUES (5,'AbC'); INSERT INTO C2 VALUES (6,'b'); INSERT INTO C2 VALUES (7,'B'); INSERT INTO C2 VALUES (8,NULL);
CREATE TABLE C3 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI_AI);
INSERT INTO C3 VALUES (1,'café'); INSERT INTO C3 VALUES (2,'CAFE'); INSERT INTO C3 VALUES (3,'cafe'); INSERT INTO C3 VALUES (4,'Café'); INSERT INTO C3 VALUES (5,'CAFÉ');
CREATE TABLE C5 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO C5 VALUES (1,'abc '); INSERT INTO C5 VALUES (2,'ABC'); INSERT INTO C5 VALUES (3,'Abc  '); INSERT INTO C5 VALUES (4,NULL); INSERT INTO C5 VALUES (5,NULL);
CREATE TABLE O1 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO O1 VALUES (1,'ABC'); INSERT INTO O1 VALUES (2,'Abc'); INSERT INTO O1 VALUES (3,'abc');
CREATE TABLE O2 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO O2 VALUES (1,'Abc'); INSERT INTO O2 VALUES (2,'abc'); INSERT INTO O2 VALUES (3,'ABC');
CREATE TABLE O3 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO O3 VALUES (1,'abc'); INSERT INTO O3 VALUES (2,'Abc'); INSERT INTO O3 VALUES (3,'ABC');
CREATE TABLE O4 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO O4 VALUES (1,'ABC'); INSERT INTO O4 VALUES (2,'abc'); INSERT INTO O4 VALUES (3,'Abc');
CREATE TABLE O5 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO O5 VALUES (1,'Abc'); INSERT INTO O5 VALUES (2,'ABC'); INSERT INTO O5 VALUES (3,'abc');
CREATE TABLE H1 (ID INTEGER, S CHAR(3) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO H1 VALUES (1,'ABC'); INSERT INTO H1 VALUES (2,'Abc'); INSERT INTO H1 VALUES (3,'abc');
CREATE TABLE H2 (ID INTEGER, S CHAR(5) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO H2 VALUES (1,'abc'); INSERT INTO H2 VALUES (2,'ABC'); INSERT INTO H2 VALUES (3,'Abc');
CREATE TABLE P1 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO P1 VALUES (1,'Ab'); INSERT INTO P1 VALUES (2,'aB');
CREATE TABLE P2 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO P2 VALUES (1,'aB'); INSERT INTO P2 VALUES (2,'Ab');
CREATE TABLE Q1 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI, ID INTEGER);
INSERT INTO Q1 VALUES ('Ab',1); INSERT INTO Q1 VALUES ('aB',2);
CREATE TABLE Q7 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI, ID INTEGER);
INSERT INTO Q7 VALUES ('ABC',1); INSERT INTO Q7 VALUES ('Abc',2); INSERT INTO Q7 VALUES ('abc',3); INSERT INTO Q7 VALUES ('aBC',4);
INSERT INTO Q7 VALUES ('AbC',5); INSERT INTO Q7 VALUES ('abC',6); INSERT INTO Q7 VALUES ('ABc',7); INSERT INTO Q7 VALUES ('aBc',8);
CREATE TABLE Q8 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI_AI, ID INTEGER);
INSERT INTO Q8 VALUES ('café',1); INSERT INTO Q8 VALUES ('CAFE',2); INSERT INTO Q8 VALUES ('cafe',3); INSERT INTO Q8 VALUES ('Café',4); INSERT INTO Q8 VALUES ('CAFÉ',5);
CREATE TABLE T1 (ID INTEGER, P VARCHAR(10)); INSERT INTO T1 VALUES (1,'abc '); INSERT INTO T1 VALUES (2,'abc');
CREATE TABLE T2 (ID INTEGER, P VARCHAR(10)); INSERT INTO T2 VALUES (1,'abc'); INSERT INTO T2 VALUES (2,'abc ');
CREATE TABLE T3 (ID INTEGER, P VARCHAR(10)); INSERT INTO T3 VALUES (1,'abc'); INSERT INTO T3 VALUES (2,'abc  '); INSERT INTO T3 VALUES (3,'abc ');
CREATE TABLE T4 (ID INTEGER, P VARCHAR(10)); INSERT INTO T4 VALUES (1,'abc  '); INSERT INTO T4 VALUES (2,'abc '); INSERT INTO T4 VALUES (3,'abc');
CREATE TABLE W1 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO W1 VALUES ('Ab'); INSERT INTO W1 VALUES ('aB'); INSERT INTO W1 VALUES ('AB'); INSERT INTO W1 VALUES ('ab');
CREATE TABLE W2 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO W2 VALUES ('aBc'); INSERT INTO W2 VALUES ('AbC'); INSERT INTO W2 VALUES ('abC'); INSERT INTO W2 VALUES ('ABc');
CREATE TABLE W3 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO W3 VALUES ('abc '); INSERT INTO W3 VALUES ('ABC'); INSERT INTO W3 VALUES ('Abc  ');
CREATE TABLE W4 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO W4 VALUES ('a'); INSERT INTO W4 VALUES ('A'); INSERT INTO W4 VALUES ('a '); INSERT INTO W4 VALUES ('A  ');
CREATE TABLE W5 (S VARCHAR(10) CHARACTER SET WIN1252 COLLATE WIN_PTBR);
INSERT INTO W5 VALUES ('abc'); INSERT INTO W5 VALUES ('ABC'); INSERT INTO W5 VALUES ('Abc');
CREATE TABLE W6 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE);
INSERT INTO W6 VALUES ('abc '); INSERT INTO W6 VALUES ('abc'); INSERT INTO W6 VALUES ('abc  ');
CREATE TABLE E1 (K INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO E1 VALUES (1,'a '); INSERT INTO E1 VALUES (1,'A'); INSERT INTO E1 VALUES (1,'a  '); INSERT INTO E1 VALUES (1,'A  ');
CREATE TABLE E4 (K INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI);
INSERT INTO E4 VALUES (1,'Ab'); INSERT INTO E4 VALUES (1,'aB'); INSERT INTO E4 VALUES (1,'AB'); INSERT INTO E4 VALUES (1,'ab');
CREATE TABLE N1 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8, G INTEGER);
INSERT INTO N1 VALUES (1,'abc',1); INSERT INTO N1 VALUES (2,'ABC',1); INSERT INTO N1 VALUES (3,'Abc',2); INSERT INTO N1 VALUES (4,'b',2); INSERT INTO N1 VALUES (5,'abc ',1);
CREATE TABLE J1 (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI, V INTEGER);
INSERT INTO J1 VALUES (1,'x',10); INSERT INTO J1 VALUES (2,'X',20); INSERT INTO J1 VALUES (3,'y',30);
CREATE TABLE J2 (S VARCHAR(10) CHARACTER SET UTF8 COLLATE UNICODE_CI, W INTEGER);
INSERT INTO J2 VALUES ('X',1); INSERT INTO J2 VALUES ('Y',2); INSERT INTO J2 VALUES ('x',3);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/collkey-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/collkey-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/collkey-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-collkey-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message; a LIST blob is
# shown by isql as its content lines, which is what a cell compares
sess() { printf 'SET NAMES UTF8;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | grep -av '^LIST: *$' | sed 's/^ *//;s/ *$//;s/  */ /g;s/0:[0-9a-f]*/0:B/g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the engine answers, this server REFUSES - recorded (never a wrong answer)
refused() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" != "$ev" ]; then echo "FAIL $1 - the engine raises now [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server refuses)"; fi
}
# BOTH raise - the engine's vector pinned, this server's allowed its own
# (recorded: the message differs)
botherr() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - AN ANSWER where the engine raises"; echo "     fc =[$fv]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "OK   $1 [$ev]"
    else echo "OK   $1 (both raise; recorded: this server's vector differs [${fv:0:60}])"; fi
}

echo "--- 1. THE MEMBERS: a CI column under a window key, GROUP BY, DISTINCT; a PAD SPACE group's spelling"
pin  "1 COUNT(*) OVER (PARTITION BY ci)" "SELECT ID, COUNT(*) OVER (PARTITION BY S) FROM CS ORDER BY ID;" "ID COUNT|1 3|2 3|3 3|4 1"
pin  "1 DENSE_RANK() OVER (ORDER BY ci)" "SELECT ID, DENSE_RANK() OVER (ORDER BY S) FROM CS ORDER BY ID;" "ID DENSE_RANK|1 1|2 1|3 1|4 2"
pin  "1 GROUP BY ci" "SELECT S, COUNT(*) FROM CS GROUP BY S;" "S COUNT|abc 3|b 1"
pin  "1 DISTINCT ci" "SELECT DISTINCT S FROM CS;" "S|abc|b"
pin  "1 COUNT(DISTINCT ci) (control)" "SELECT COUNT(DISTINCT S) FROM CS;" "COUNT|2"
pin  "1 LIST(DISTINCT ci)" "SELECT LIST(DISTINCT S) FROM CS;" "LIST|0:B|abc,b"
pin  "1 GROUP BY p over 'abc ' / 'abc' - the LAST fed" "SELECT '[' || P || ']', COUNT(*) FROM CP GROUP BY P;" "CONCATENATION COUNT|[abc] 2"
pin  "1 ...its DISTINCT" "SELECT '[' || P || ']' FROM (SELECT DISTINCT P FROM CP);" "CONCATENATION|[abc]"
pin  "1 CONTROL the expression is two values" "SELECT DISTINCT '[' || P || ']' FROM CP;" "CONCATENATION|[abc ]|[abc]"

echo "--- 2. THE GROUP'S SURVIVOR: the last row in record order"
pin  "2 O1 ABC,Abc,abc" "SELECT S FROM O1 GROUP BY S;" "S|abc"
pin  "2 O2 Abc,abc,ABC" "SELECT S FROM O2 GROUP BY S;" "S|abc"
pin  "2 O3 abc,Abc,ABC" "SELECT S FROM O3 GROUP BY S;" "S|abc"
pin  "2 O4 ABC,abc,Abc" "SELECT S FROM O4 GROUP BY S;" "S|abc"
pin  "2 O5 Abc,ABC,abc" "SELECT S FROM O5 GROUP BY S;" "S|abc"
pin  "2 O1 with MAX(ID): the highest id's" "SELECT S, MAX(ID) FROM O1 GROUP BY S;" "S MAX|abc 3"
pin  "2 O2 with MAX(ID)" "SELECT S, MAX(ID) FROM O2 GROUP BY S;" "S MAX|ABC 3"
pin  "2 O3 with MAX(ID)" "SELECT S, MAX(ID) FROM O3 GROUP BY S;" "S MAX|ABC 3"
pin  "2 O4 with MAX(ID)" "SELECT S, MAX(ID) FROM O4 GROUP BY S;" "S MAX|Abc 3"
pin  "2 O5 with MAX(ID)" "SELECT S, MAX(ID) FROM O5 GROUP BY S;" "S MAX|abc 3"
pin  "2 O4 with ID only in the WHERE" "SELECT S FROM O4 WHERE ID > 0 GROUP BY S;" "S|Abc"
pin  "2 O4 with ID in the WHERE, cut" "SELECT S FROM O4 WHERE ID < 3 GROUP BY S;" "S|abc"
pin  "2 H1 CHAR(3)" "SELECT '[' || S || ']' FROM H1 GROUP BY S;" "CONCATENATION|[abc]"
pin  "2 H2 CHAR(5)" "SELECT '[' || S || ']' FROM H2 GROUP BY S;" "CONCATENATION|[abc ]"
pin  "2 H2 CHAR(5) with MAX(ID)" "SELECT '[' || S || ']', MAX(ID) FROM H2 GROUP BY S;" "CONCATENATION MAX|[Abc ] 3"
pin  "2 P1 Ab,aB - the record's text compare (c1 leads c0)" "SELECT S FROM P1 GROUP BY S;" "S|Ab"
pin  "2 P2 aB,Ab" "SELECT S FROM P2 GROUP BY S;" "S|Ab"
pin  "2 W1 the order, by LIST" "SELECT S, LIST(S) FROM W1 GROUP BY S;" "S LIST|ab 0:B|AB,aB,Ab,ab"
pin  "2 W2" "SELECT S, LIST(S) FROM W2 GROUP BY S;" "S LIST|aBc 0:B|AbC,abC,ABc,aBc"
pin  "2 W3 byte LENGTH leads" "SELECT '[' || S || ']', LIST('[' || S || ']') FROM W3 GROUP BY S;" "CONCATENATION LIST|[Abc ] 0:B|[ABC],[abc ],[Abc ]"
pin  "2 W4" "SELECT '[' || S || ']', LIST('[' || S || ']') FROM W4 GROUP BY S;" "CONCATENATION LIST|[A ] 0:B|[A],[a],[a ],[A ]"
refused "2 W5 WIN_PTBR (PXW) - a narrow charset's collation has no key here (pre-existing)" "SELECT S, LIST(S) FROM W5 GROUP BY S;"
pin  "2 W6 UNICODE, trailing blanks" "SELECT '[' || S || ']', LIST('[' || S || ']') FROM W6 GROUP BY S;" "CONCATENATION LIST|[abc ] 0:B|[abc],[abc ],[abc ]"
pin  "2 Q1 (s, id)" "SELECT S, LIST(ID) FROM Q1 GROUP BY S;" "S LIST|Ab 0:B|2,1"
pin  "2 Q7 eight spellings" "SELECT S, LIST(ID) FROM Q7 GROUP BY S;" "S LIST|abc 0:B|1,4,5,6,7,8,2,3"
pin  "2 Q8 CI_AI" "SELECT S, LIST(ID) FROM Q8 GROUP BY S;" "S LIST|café 0:B|2,3,5,4,1"
pin  "2 C3 CI_AI" "SELECT S FROM C3 GROUP BY S;" "S|café"
pin  "2 C3 CI_AI with MAX(ID)" "SELECT S, MAX(ID) FROM C3 GROUP BY S;" "S MAX|CAFÉ 5"
pin  "2 C5 blanks and NULLs" "SELECT '[' || S || ']', COUNT(*) FROM C5 GROUP BY S;" "CONCATENATION COUNT|<null> 2|[Abc ] 3"
pin  "2 E1 (k, s)" "SELECT K, LIST(S) FROM E1 GROUP BY K;" "K LIST|1 0:B|A,a ,A ,a"
pin  "2 E4 (k, s)" "SELECT K, LIST(S) FROM E4 GROUP BY K;" "K LIST|1 0:B|AB,aB,Ab,ab"
pin  "2 T1 PAD SPACE 'abc ','abc'" "SELECT '[' || P || ']' FROM T1 GROUP BY P;" "CONCATENATION|[abc]"
pin  "2 T2 'abc','abc '" "SELECT '[' || P || ']' FROM T2 GROUP BY P;" "CONCATENATION|[abc ]"
pin  "2 T3 three lengths" "SELECT '[' || P || ']' FROM T3 GROUP BY P;" "CONCATENATION|[abc ]"
pin  "2 T4" "SELECT '[' || P || ']' FROM T4 GROUP BY P;" "CONCATENATION|[abc]"
pin  "2 T3 with MAX(ID)" "SELECT '[' || P || ']', MAX(ID) FROM T3 GROUP BY P;" "CONCATENATION MAX|[abc ] 3"
pin  "2 T4 with ID in the WHERE" "SELECT '[' || P || ']' FROM T4 WHERE ID > 0 GROUP BY P;" "CONCATENATION|[abc]"
pin  "2 N1 UTF8 default collation" "SELECT '[' || S || ']', G FROM N1 GROUP BY S, G;" "CONCATENATION G|[ABC] 1|[Abc] 2|[abc ] 1|[b] 2"
pin  "2 C2 the groups in the collation's order, NULL first" "SELECT S, COUNT(*) FROM C2 GROUP BY S;" "S COUNT|<null> 1|abc 5|b 2"
pin  "2 C2 ... ORDER BY S DESC" "SELECT S FROM C2 GROUP BY S ORDER BY S DESC;" "S|b|abc|<null>"
pin  "2 C2 the WHERE narrows the group" "SELECT S FROM C2 WHERE S = 'abc' GROUP BY S;" "S|abc"
refused "2 a derived source whose WHERE names a column it does not project (ID orders the record first)" "SELECT S, COUNT(*) FROM (SELECT S FROM C2 WHERE ID < 6) GROUP BY S;"

echo "--- 3. THE FOLDS SEE THE GROUP IN THAT ORDER"
pin  "3 grouped MIN/MAX keep the first row the collation calls equal" "SELECT S, MIN(S), MAX(S), COUNT(*), MIN(ID), MAX(ID) FROM C2 GROUP BY S;" "S MIN MAX COUNT MIN MAX|<null> <null> <null> 1 8 8|AbC ABC ABC 5 1 5|B b b 2 6 7"
pin  "3 P1 grouped MIN/MAX" "SELECT S, MIN(S), MAX(S) FROM P1 GROUP BY S;" "S MIN MAX|Ab aB aB"
pin  "3 P2 grouped MIN/MAX" "SELECT S, MIN(S), MAX(S) FROM P2 GROUP BY S;" "S MIN MAX|Ab aB aB"
pin  "3 global MIN/MAX: the first fed" "SELECT MIN(S), MAX(S) FROM C2;" "MIN MAX|ABC b"
pin  "3 global MIN/MAX P1" "SELECT MIN(S), MAX(S) FROM P1;" "MIN MAX|Ab Ab"
pin  "3 global MIN/MAX P2" "SELECT MIN(S), MAX(S) FROM P2;" "MIN MAX|aB aB"
pin  "3 LIST(DISTINCT) P1: full-strength first" "SELECT LIST(DISTINCT S) FROM P1;" "LIST|0:B|aB"
pin  "3 LIST(DISTINCT) P2" "SELECT LIST(DISTINCT S) FROM P2;" "LIST|0:B|aB"
pin  "3 LIST(DISTINCT) C2" "SELECT LIST(DISTINCT S) FROM C2;" "LIST|0:B|abc,b"
pin  "3 LIST(DISTINCT) C3" "SELECT LIST(DISTINCT S) FROM C3;" "LIST|0:B|café"
pin  "3 LIST(DISTINCT) grouped" "SELECT S, LIST(DISTINCT S) FROM C2 GROUP BY S;" "S LIST|<null> <null>|abc 0:B|abc|b 0:B|b"
pin  "3 COUNT(DISTINCT) per group" "SELECT S, COUNT(DISTINCT S), COUNT(DISTINCT ID) FROM C2 GROUP BY S;" "S COUNT COUNT|<null> 0 1|AbC 1 5|B 1 2"
pin  "3 LIST(S) plain keeps the record order" "SELECT LIST(S) FROM O3;" "LIST|0:B|abc,Abc,ABC"

echo "--- 4. HAVING, IN, expression keys, an explicit COLLATE"
pin  "4 HAVING ci = literal" "SELECT S, COUNT(*) FROM C2 GROUP BY S HAVING S = 'ABC';" "S COUNT|abc 5"
pin  "4 HAVING ci > literal" "SELECT S, COUNT(*) FROM C2 GROUP BY S HAVING S > 'ab';" "S COUNT|abc 5|b 2"
pin  "4 HAVING ci IN" "SELECT S, COUNT(*) FROM C2 GROUP BY S HAVING S IN ('B');" "S COUNT|b 2"
pin  "4 HAVING ci IS NULL" "SELECT S FROM C2 GROUP BY S HAVING S IS NULL;" "S|<null>"
pin  "4 HAVING ci <> literal" "SELECT S, COUNT(*) FROM C2 GROUP BY S HAVING S <> 'b';" "S COUNT|abc 5"
pin  "4 HAVING ci BETWEEN" "SELECT S, COUNT(*) FROM C2 GROUP BY S HAVING S BETWEEN 'a' AND 'abc';" "S COUNT|abc 5"
pin  "4 HAVING MIN(ci) = literal" "SELECT S, COUNT(*) FROM C2 GROUP BY S HAVING MIN(S) = 'ABC';" "S COUNT|abc 5"
pin  "4 HAVING MAX(ci) = literal" "SELECT S FROM C2 GROUP BY S HAVING MAX(S) = 'abc';" "S|abc"
pin  "4 HAVING COUNT(*) > 1" "SELECT S FROM C2 GROUP BY S HAVING COUNT(*) > 1;" "S|abc|b"
pin  "4 WHERE ci IN list, grouped" "SELECT S FROM C2 WHERE S IN ('B', 'X') GROUP BY S;" "S|b"
pin  "4 WHERE ci = literal, grouped" "SELECT S, COUNT(*) FROM C2 WHERE S = 'b' GROUP BY S;" "S COUNT|b 2"
pin  "4 WHERE ci IN (control)" "SELECT ID FROM C2 WHERE S IN ('abc', 'X') ORDER BY ID;" "ID|1|2|3|4|5"
pin  "4 GROUP BY UPPER(ci) keeps the collation" "SELECT UPPER(S) FROM C2 GROUP BY UPPER(S);" "UPPER|<null>|ABC|B"
pin  "4 GROUP BY ci || 'x' keeps the collation" "SELECT S || 'x' FROM C2 GROUP BY S || 'x';" "CONCATENATION|<null>|abcx|bx"
pin  "4 GROUP BY CAST(ci AS VARCHAR(3)) drops it" "SELECT CAST(S AS VARCHAR(3)) FROM C2 GROUP BY CAST(S AS VARCHAR(3));" "CAST|<null>|ABC|AbC|Abc|B|aBC|abc|b"
pin  "4 GROUP BY 1 over s COLLATE UNICODE_CI" "SELECT '[' || S || ']' FROM (SELECT S COLLATE UNICODE_CI AS S FROM N1) GROUP BY 1;" "CONCATENATION|[abc ]|[abc]|[b]"
pin  "4 s COLLATE UNICODE_CI AS cs ... GROUP BY cs" "SELECT S COLLATE UNICODE_CI AS CS, COUNT(*) FROM N1 GROUP BY CS;" "CS COUNT|abc 4|b 1"
pin  "4 ... ORDER BY cs" "SELECT S COLLATE UNICODE_CI AS CS FROM N1 GROUP BY CS ORDER BY CS;" "CS|abc|b"
pin  "4 DISTINCT s COLLATE UNICODE_CI" "SELECT DISTINCT S COLLATE UNICODE_CI FROM N1;" "CAST|abc|b"
pin  "4 DISTINCT s COLLATE UNICODE_CI AS cs ORDER BY 1" "SELECT DISTINCT S COLLATE UNICODE_CI AS CS FROM N1 ORDER BY 1;" "CS|abc|b"
refused "4 a grouped JOIN over CI keys (the fold runs in delivery order; the joined record's order is a later slice)" "SELECT X.S, Y.S, SUM(V), SUM(W) FROM J1 X JOIN J2 Y ON X.S = Y.S GROUP BY X.S, Y.S;"
refused "4 ...one key" "SELECT X.S, COUNT(*) FROM J1 X JOIN J2 Y ON X.S = Y.S GROUP BY X.S;"

echo "--- 5. DISTINCT and UNION"
pin  "5 DISTINCT C2" "SELECT DISTINCT S FROM C2;" "S|<null>|abc|b"
pin  "5 DISTINCT C3" "SELECT DISTINCT S FROM C3;" "S|café"
pin  "5 DISTINCT H2 CHAR(5)" "SELECT DISTINCT '[' || S || ']' FROM (SELECT DISTINCT S FROM H2);" "CONCATENATION|[abc ]"
pin  "5 DISTINCT C5" "SELECT '[' || S || ']' FROM (SELECT DISTINCT S FROM C5);" "CONCATENATION|<null>|[Abc ]"
pin  "5 DISTINCT O1..O5" "SELECT DISTINCT S FROM O1; SELECT DISTINCT S FROM O2; SELECT DISTINCT S FROM O3; SELECT DISTINCT S FROM O4; SELECT DISTINCT S FROM O5;" "S|abc|S|abc|S|abc|S|abc|S|abc"
pin  "5 DISTINCT P1 / P2" "SELECT DISTINCT S FROM P1; SELECT DISTINCT S FROM P2;" "S|Ab|S|Ab"
pin  "5 DISTINCT W1..W4" "SELECT DISTINCT '[' || S || ']' FROM (SELECT DISTINCT S FROM W1); SELECT DISTINCT '[' || S || ']' FROM (SELECT DISTINCT S FROM W2); SELECT DISTINCT '[' || S || ']' FROM (SELECT DISTINCT S FROM W3); SELECT DISTINCT '[' || S || ']' FROM (SELECT DISTINCT S FROM W4);" "CONCATENATION|[ab]|CONCATENATION|[aBc]|CONCATENATION|[Abc ]|CONCATENATION|[A ]"
pin  "5 DISTINCT Q1 / Q7 / Q8" "SELECT DISTINCT S FROM Q1; SELECT DISTINCT S FROM Q7; SELECT DISTINCT S FROM Q8;" "S|Ab|S|abc|S|café"
pin  "5 DISTINCT T1..T4 PAD SPACE: the last fed" "SELECT '[' || P || ']' FROM (SELECT DISTINCT P FROM T1); SELECT '[' || P || ']' FROM (SELECT DISTINCT P FROM T2); SELECT '[' || P || ']' FROM (SELECT DISTINCT P FROM T3); SELECT '[' || P || ']' FROM (SELECT DISTINCT P FROM T4);" "CONCATENATION|[abc]|CONCATENATION|[abc ]|CONCATENATION|[abc ]|CONCATENATION|[abc]"
pin  "5 DISTINCT with a WHERE on the same column" "SELECT DISTINCT S FROM C2 WHERE S = 'abc';" "S|abc"
pin  "5 DISTINCT ci ORDER BY ci" "SELECT DISTINCT S FROM C2 ORDER BY S;" "S|<null>|abc|b"
pin  "5 DISTINCT ci, id" "SELECT DISTINCT S, ID FROM C2 WHERE ID IN (1, 2, 3);" "S ID|ABC 1|Abc 2|abc 3"
pin  "5 DISTINCT over a derived DISTINCT, ordered" "SELECT S FROM (SELECT DISTINCT S FROM C2) ORDER BY S;" "S|<null>|abc|b"
pin  "5 UNION of two CI legs" "SELECT S FROM CS UNION SELECT S FROM C2;" "S|<null>|abc|b"
pin  "5 UNION the other way" "SELECT S FROM C2 UNION SELECT S FROM CS;" "S|<null>|abc|b"
pin  "5 UNION with an ORDER BY" "SELECT S FROM C2 UNION SELECT S FROM P1 ORDER BY 1;" "S|<null>|Ab|abc|b"
pin  "5 UNION of a leg with itself" "SELECT S FROM C2 UNION SELECT S FROM C2 WHERE ID > 3;" "S|<null>|abc|b"
pin  "5 UNION ALL of two GROUP BYs (control)" "SELECT S, COUNT(*) FROM C2 GROUP BY S UNION ALL SELECT S, COUNT(*) FROM P1 GROUP BY S;" "S COUNT|<null> 1|abc 5|b 2|Ab 2"
pin  "5 UNION over PAD SPACE legs: the later leg" "SELECT '[' || P || ']' FROM (SELECT P FROM T1 UNION SELECT P FROM T2);" "CONCATENATION|[abc ]"

echo "--- 6. WINDOWS: sorted at full strength, bounded at the collation's own"
pin  "6 ROW_NUMBER / RANK / DENSE_RANK" "SELECT ID, S, ROW_NUMBER() OVER (ORDER BY S), RANK() OVER (ORDER BY S), DENSE_RANK() OVER (ORDER BY S) FROM C2 ORDER BY ID;" "ID S ROW_NUMBER RANK DENSE_RANK|1 ABC 6 2 2|2 Abc 4 2 2|3 abc 2 2 2|4 aBC 3 2 2|5 AbC 5 2 2|6 b 7 7 3|7 B 8 7 3|8 <null> 1 1 1"
pin  "6 SUM / COUNT / MIN / MAX OVER (PARTITION BY ci)" "SELECT ID, S, SUM(ID) OVER (PARTITION BY S), COUNT(*) OVER (PARTITION BY S), MIN(S) OVER (PARTITION BY S), MAX(S) OVER (PARTITION BY S) FROM C2 ORDER BY ID;" "ID S SUM COUNT MIN MAX|1 ABC 15 5 abc abc|2 Abc 15 5 abc abc|3 abc 15 5 abc abc|4 aBC 15 5 abc abc|5 AbC 15 5 abc abc|6 b 13 2 b b|7 B 13 2 b b|8 <null> 8 1 <null> <null>"
pin  "6 LAG / LEAD along the full-strength order" "SELECT ID, S, LAG(S) OVER (ORDER BY S), LEAD(ID) OVER (ORDER BY S, ID) FROM C2 ORDER BY ID;" "ID S LAG LEAD|1 ABC AbC 6|2 Abc aBC 5|3 abc <null> 4|4 aBC abc 2|5 AbC Abc 1|6 b ABC 7|7 B b <null>|8 <null> <null> 3"
pin  "6 LAG / LEAD of the value" "SELECT ID, LAG(S) OVER (ORDER BY S), LEAD(S) OVER (ORDER BY S) FROM C2 ORDER BY ID;" "ID LAG LEAD|1 AbC b|2 aBC AbC|3 <null> aBC|4 abc Abc|5 Abc ABC|6 ABC B|7 b <null>|8 <null> abc"
pin  "6 COUNT(*) OVER (ORDER BY ci): one peer group" "SELECT ID, S, COUNT(*) OVER (ORDER BY S) FROM C2 ORDER BY ID;" "ID S COUNT|1 ABC 6|2 Abc 6|3 abc 6|4 aBC 6|5 AbC 6|6 b 8|7 B 8|8 <null> 1"
refused "6 a keyword-only RANGE frame (pre-existing parse gap)" "SELECT ID, S, COUNT(*) OVER (ORDER BY S RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM C2 ORDER BY ID;"
pin  "6 ...ROWS frame runs in full-strength order" "SELECT ID, S, COUNT(*) OVER (ORDER BY S ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM C2 ORDER BY ID;" "ID S COUNT|1 ABC 6|2 Abc 4|3 abc 2|4 aBC 3|5 AbC 5|6 b 7|7 B 8|8 <null> 1"
pin  "6 FIRST_VALUE / LAST_VALUE" "SELECT ID, S, FIRST_VALUE(ID) OVER (ORDER BY S), LAST_VALUE(ID) OVER (ORDER BY S) FROM C2 ORDER BY ID;" "ID S FIRST_VALUE LAST_VALUE|1 ABC 8 1|2 Abc 8 1|3 abc 8 1|4 aBC 8 1|5 AbC 8 1|6 b 8 7|7 B 8 7|8 <null> 8 8"
pin  "6 NTH_VALUE" "SELECT ID, S, NTH_VALUE(ID, 2) OVER (ORDER BY S) FROM C2 ORDER BY ID;" "ID S NTH_VALUE|1 ABC 3|2 Abc 3|3 abc 3|4 aBC 3|5 AbC 3|6 b 3|7 B 3|8 <null> <null>"
pin  "6 PERCENT_RANK / CUME_DIST / NTILE" "SELECT ID, S, PERCENT_RANK() OVER (ORDER BY S), CUME_DIST() OVER (ORDER BY S), NTILE(2) OVER (ORDER BY S) FROM C2 ORDER BY ID;" "ID S PERCENT_RANK CUME_DIST NTILE|1 ABC 0.1428571428571428 0.7500000000000000 2|2 Abc 0.1428571428571428 0.7500000000000000 1|3 abc 0.1428571428571428 0.7500000000000000 1|4 aBC 0.1428571428571428 0.7500000000000000 1|5 AbC 0.1428571428571428 0.7500000000000000 2|6 b 0.8571428571428571 1.000000000000000 2|7 B 0.8571428571428571 1.000000000000000 2|8 <null> 0.000000000000000 0.1250000000000000 1"
pin  "6 FIRST_VALUE(ci) OVER (PARTITION BY ci ORDER BY id): the key's own order leads the id" "SELECT ID, MIN(S) OVER (PARTITION BY S), MAX(S) OVER (PARTITION BY S), FIRST_VALUE(S) OVER (PARTITION BY S ORDER BY ID), LAST_VALUE(S) OVER (PARTITION BY S ORDER BY ID ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM C2 ORDER BY ID;" "ID MIN MAX FIRST_VALUE LAST_VALUE|1 abc abc abc ABC|2 abc abc abc ABC|3 abc abc abc ABC|4 abc abc abc ABC|5 abc abc abc ABC|6 b b b B|7 b b b B|8 <null> <null> <null> <null>"
pin  "6 running COUNT OVER (PARTITION BY ci ORDER BY id)" "SELECT ID, S, COUNT(*) OVER (PARTITION BY S ORDER BY ID) FROM C5 ORDER BY ID;" "ID S COUNT|1 abc 1|2 ABC 3|3 Abc 2|4 <null> 1|5 <null> 2"
pin  "6 COUNT OVER (PARTITION BY ci) with NULLs" "SELECT ID, COUNT(*) OVER (PARTITION BY S) FROM C5 ORDER BY ID;" "ID COUNT|1 3|2 3|3 3|4 2|5 2"
pin  "6 COUNT OVER (PARTITION BY ci ORDER BY ci)" "SELECT ID, S, COUNT(*) OVER (PARTITION BY S ORDER BY S) FROM C2 ORDER BY ID;" "ID S COUNT|1 ABC 5|2 Abc 5|3 abc 5|4 aBC 5|5 AbC 5|6 b 2|7 B 2|8 <null> 1"
refused "6 a windowed LIST (pre-existing)" "SELECT S, COUNT(*) OVER (PARTITION BY S), LIST(ID) OVER (PARTITION BY S) FROM Q7 ORDER BY ID;"
pin  "6 FIRST_VALUE OVER (PARTITION BY ci ORDER BY id) on O1" "SELECT ID, FIRST_VALUE(S) OVER (PARTITION BY S ORDER BY ID) FROM O1 ORDER BY ID;" "ID FIRST_VALUE|1 abc|2 abc|3 abc"
pin  "6 PARTITION BY s COLLATE UNICODE_CI" "SELECT ID, COUNT(*) OVER (PARTITION BY S COLLATE UNICODE_CI) FROM N1 ORDER BY ID;" "ID COUNT|1 4|2 4|3 4|4 1|5 4"
pin  "6 DENSE_RANK OVER (ORDER BY s COLLATE UNICODE_CI)" "SELECT ID, DENSE_RANK() OVER (ORDER BY S COLLATE UNICODE_CI) FROM N1 ORDER BY ID;" "ID DENSE_RANK|1 1|2 1|3 1|4 2|5 1"
pin  "6 ROW_NUMBER OVER (ORDER BY s COLLATE UNICODE_CI)" "SELECT ID, ROW_NUMBER() OVER (ORDER BY S COLLATE UNICODE_CI) FROM N1 ORDER BY ID;" "ID ROW_NUMBER|1 1|2 4|3 3|4 5|5 2"
pin  "6 CI_AI window" "SELECT ID, S, DENSE_RANK() OVER (ORDER BY S), ROW_NUMBER() OVER (ORDER BY S), COUNT(*) OVER (PARTITION BY S) FROM C3 ORDER BY ID;" "ID S DENSE_RANK ROW_NUMBER COUNT|1 café 1 3 5|2 CAFE 1 2 5|3 cafe 1 1 5|4 Café 1 4 5|5 CAFÉ 1 5 5"

echo "--- 7. CONTROLS: the sort is full strength, the compare is not"
pin  "7 ORDER BY ci" "SELECT ID, S FROM C2 ORDER BY S;" "ID S|8 <null>|3 abc|4 aBC|2 Abc|5 AbC|1 ABC|6 b|7 B"
pin  "7 ORDER BY ci DESC NULLS FIRST" "SELECT ID, S FROM C2 ORDER BY S DESC NULLS FIRST;" "ID S|8 <null>|7 B|6 b|1 ABC|5 AbC|2 Abc|4 aBC|3 abc"
pin  "7 ORDER BY ci_ai" "SELECT ID, S FROM C3 ORDER BY S;" "ID S|3 cafe|2 CAFE|1 café|4 Café|5 CAFÉ"
pin  "7 ORDER BY s COLLATE UNICODE_CI, ID DESC" "SELECT ID, S FROM N1 ORDER BY S COLLATE UNICODE_CI, ID DESC;" "ID S|5 abc|1 abc|3 Abc|2 ABC|4 b"
pin  "7 ORDER BY over blanks" "SELECT ID, S FROM C5 ORDER BY S;" "ID S|4 <null>|5 <null>|1 abc|3 Abc|2 ABC"
pin  "7 WHERE ci = literal" "SELECT COUNT(*) FROM C2 WHERE S = 'ABC';" "COUNT|5"
pin  "7 WHERE ci BETWEEN" "SELECT COUNT(*) FROM C2 WHERE S BETWEEN 'abc' AND 'abc';" "COUNT|5"
pin  "7 the byte-collated N1 groups" "SELECT S FROM N1 GROUP BY S;" "S|ABC|Abc|abc|b"

echo "--- 8. RECORDED"
refused "8 DISTINCT ci with a WHERE on another column (the record orders ID first)" "SELECT DISTINCT S FROM C2 WHERE ID > 1;"
refused "8 DISTINCT ci, id ORDER BY ci (the ORDER BY folded into the unique sort)" "SELECT DISTINCT S, ID FROM C2 WHERE ID IN (1, 2, 3) ORDER BY S;"
botherr "8 the select-list column is not the GROUP BY <col> COLLATE key" "SELECT S FROM N1 GROUP BY S COLLATE UNICODE_CI;" "Statement failed, SQLSTATE = 42000|Dynamic SQL Error|-SQL error code = -104|-Invalid expression in the select list (not contained in either an aggregate function or the GROUP BY clause)"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-collkey-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 137 ]; then echo "FAIL only $ran checks ran (floor 137)"; fail=1; fi
exit $fail
