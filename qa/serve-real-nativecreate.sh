#!/bin/bash
# CREATE DATABASE WITHOUT A FIREBIRD INSTALL - op_create writes the
# engine's own empty database (crates/ods/templates, made by 6.0.0.2196)
# and makes it its own: a fresh GUID, the creation time, the page size the
# engine would pick, the DEFAULT CHARACTER SET. It once spawned the engine's
# `isql`; this gate runs the server with a PATH holding no Firebird tool
# and no $FC_ISQL, so a create that still needed one fails here.
#
# Every database is made twice, by the engine and by this server, from the
# same CREATE DATABASE text, and the ENGINE reads both: the same catalog
# (every system relation's row count, RDB$DATABASE, MON$DATABASE's page
# size / ODS / dialect / forced writes / sweep interval), a clean `gfix -v
# -full` of this server's file, and DDL / DML through either server over
# it. Measured: the page size is the NEAREST of 8192 / 16384 / 32768 (a tie
# up, 1 and 4096 are 8192, 65536 is 32768); a DEFAULT CHARACTER SET is
# stored as spelled (upper-cased - `win_1252` is WIN_1252, an alias kept);
# an unknown one is 2C000 *ALTER DATABASE failed* / *CHARACTER SET
# "PUBLIC"."NOSUCH" is not defined*, and the client then drops the file.
# The client re-sends its CREATE DATABASE text on the new attachment -
# the engine runs it as an ALTER of the database - and ALTER DATABASE SET
# DEFAULT CHARACTER SET is taken on its own too.
#
#   qa/serve-real-nativecreate.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-$(dirname "$(command -v "$ISQL")")/gfix}"
PORT="${1:-4647}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson/nc-$PORT"
mkdir -p "$D"; chmod 777 "$D"
gone() { sudo -n rm -f "$1" 2>/dev/null; rm -f "$1" 2>/dev/null; }
# THE SERVER SEES NO FIREBIRD: an emptied environment, a PATH of /usr/bin
# and /bin, no FC_ISQL
env -i HOME="$HOME" PATH=/usr/bin:/bin "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-nc-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; for f in "$D"/*.fdb; do gone "$f"; done' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
clean() { tr -d '\r' | grep -av '^$' | sed 's/  */ /g; s/ *$//'; }
run() { printf "%s\nSELECT 'DONE' AS X FROM RDB\$DATABASE;\n" "$2" | timeout -s KILL 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | clean; }
check() { # <label> <want> <got>
    ran=$((ran + 1))
    if [ -z "$2" ]; then echo "FAIL $1 [the engine answered nothing]"; fail=1
    elif [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | sed 's/^/     /'; fail=1; fi
}
# create <file> <clauses>: the engine's create and this server's, the same text
create() {
    gone "$D/e-$1.fdb"; gone "$D/f-$1.fdb"
    local e f
    e=$(printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s'%s;\n" "$REAL" "$D/e-$1.fdb" "$U" "$P" "$2" | timeout -s KILL 60 "$ISQL" -q 2>&1 | clean)
    f=$(printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s'%s;\n" "$PORT" "$D/f-$1.fdb" "$U" "$P" "$2" | timeout -s KILL 60 "$ISQL" -q 2>&1 | clean)
    check "create $1:$2 - the create's own answer, and whether a file is left" "$e|$([ -e "$D/e-$1.fdb" ] && echo FILE || echo NOFILE)" "$f|$([ -e "$D/f-$1.fdb" ] && echo FILE || echo NOFILE)"
    [ -e "$D/f-$1.fdb" ] && chmod 666 "$D/f-$1.fdb"
}
CAT="SELECT MON\$PAGE_SIZE, MON\$ODS_MAJOR, MON\$ODS_MINOR, MON\$SQL_DIALECT, MON\$READ_ONLY, MON\$FORCED_WRITES, MON\$SWEEP_INTERVAL, MON\$RESERVE_SPACE FROM MON\$DATABASE;
SELECT RDB\$CHARACTER_SET_NAME, RDB\$SECURITY_CLASS, RDB\$LINGER, RDB\$DESCRIPTION FROM RDB\$DATABASE;
SELECT R.RDB\$RELATION_NAME, (SELECT COUNT(*) FROM RDB\$RELATION_FIELDS F WHERE F.RDB\$RELATION_NAME = R.RDB\$RELATION_NAME) FROM RDB\$RELATIONS R ORDER BY 1;
SELECT 'F', COUNT(*) FROM RDB\$FIELDS UNION ALL SELECT 'TY', COUNT(*) FROM RDB\$TYPES UNION ALL SELECT 'IX', COUNT(*) FROM RDB\$INDICES UNION ALL SELECT 'SEG', COUNT(*) FROM RDB\$INDEX_SEGMENTS UNION ALL SELECT 'CO', COUNT(*) FROM RDB\$COLLATIONS UNION ALL SELECT 'CS', COUNT(*) FROM RDB\$CHARACTER_SETS UNION ALL SELECT 'UP', COUNT(*) FROM RDB\$USER_PRIVILEGES UNION ALL SELECT 'SC', COUNT(*) FROM RDB\$SCHEMAS UNION ALL SELECT 'PK', COUNT(*) FROM RDB\$PACKAGES UNION ALL SELECT 'PR', COUNT(*) FROM RDB\$PROCEDURES UNION ALL SELECT 'FN', COUNT(*) FROM RDB\$FUNCTIONS UNION ALL SELECT 'SEC', COUNT(*) FROM RDB\$SECURITY_CLASSES UNION ALL SELECT 'GEN', COUNT(*) FROM RDB\$GENERATORS UNION ALL SELECT 'BF', COUNT(*) FROM RDB\$BACKUP_HISTORY;"
# the ENGINE reads both files: the same catalog
engine_reads() { # <name>
    check "engine reads $1: the catalog of this server's file is the engine's own" "$(run "127.0.0.1/$REAL:$D/e-$1.fdb" "$CAT")" "$(run "127.0.0.1/$REAL:$D/f-$1.fdb" "$CAT")"
    ran=$((ran + 1))
    local v
    v=$(sudo -n "$GFIX" -v -full -user "$U" -pas "$P" "$D/f-$1.fdb" 2>&1)
    if [ -z "$v" ]; then echo "OK   gfix -v -full of this server's $1 is clean"; else echo "FAIL gfix -v -full of this server's $1: $v" | head -5; fail=1; fi
}

echo "--- 1 the page size the engine picks, and the catalog it writes"
for ps in 8192 1 4096 12287 12288 16384 24575 24576 32768 65536; do
    create "p$ps" " PAGE_SIZE $ps"
    engine_reads "p$ps"
done
create "plain" ""
engine_reads "plain"

echo "--- 2 the DEFAULT CHARACTER SET"
for cs in UTF8 utf8 WIN_1252 win1252 ISO8859_1 UNICODE_FSS; do
    create "cs$cs" " DEFAULT CHARACTER SET $cs"
    engine_reads "cs$cs"
done
create "csNOSUCH" " DEFAULT CHARACTER SET NOSUCH"
create "csps" " PAGE_SIZE 16384 DEFAULT CHARACTER SET UTF8"
engine_reads "csps"

echo "--- 3 a new database at work: DDL / DML through this server, read by the engine"
WORK="CREATE TABLE T (ID INT PRIMARY KEY, S VARCHAR(10), N NUMERIC(9,2));
CREATE INDEX T_S ON T (S);
INSERT INTO T VALUES (1, 'abc', 1.50);
INSERT INTO T VALUES (2, 'xyz', NULL);
CREATE SEQUENCE G;
CREATE VIEW V AS SELECT ID, S FROM T WHERE ID > 1;
COMMIT;
SELECT NEXT VALUE FOR G FROM RDB\$DATABASE;
COMMIT;"
READ="SELECT ID, S, N FROM T ORDER BY ID; SELECT * FROM V; SELECT S FROM T WHERE S = 'xyz'; SELECT GEN_ID(G, 0) FROM RDB\$DATABASE;
SELECT F.RDB\$CHARACTER_SET_ID FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = RF.RDB\$FIELD_SOURCE WHERE RF.RDB\$RELATION_NAME = 'T' AND RF.RDB\$FIELD_NAME = 'S';"
for n in plain csUTF8; do
    check "3 $n: the work, each server on its own file" "$(run "127.0.0.1/$REAL:$D/e-$n.fdb" "$WORK")" "$(run "127.0.0.1/$PORT:$D/f-$n.fdb" "$WORK")"
    check "3 $n: the engine reads what this server wrote" "$(run "127.0.0.1/$REAL:$D/e-$n.fdb" "$READ")" "$(run "127.0.0.1/$REAL:$D/f-$n.fdb" "$READ")"
    check "3 $n: and this server reads it back" "$(run "127.0.0.1/$REAL:$D/e-$n.fdb" "$READ")" "$(run "127.0.0.1/$PORT:$D/f-$n.fdb" "$READ")"
    engine_reads "$n"
done

echo "--- 4 ALTER DATABASE SET DEFAULT CHARACTER SET"
ALT="ALTER DATABASE SET DEFAULT CHARACTER SET ISO8859_1;
COMMIT;
SELECT RDB\$CHARACTER_SET_NAME FROM RDB\$DATABASE;
CREATE TABLE T2 (S VARCHAR(5)); COMMIT;
SELECT F.RDB\$CHARACTER_SET_ID FROM RDB\$RELATION_FIELDS RF JOIN RDB\$FIELDS F ON F.RDB\$FIELD_NAME = RF.RDB\$FIELD_SOURCE WHERE RF.RDB\$RELATION_NAME = 'T2';
ALTER DATABASE SET DEFAULT CHARACTER SET NOSUCH;
ALTER DATABASE SET DEFAULT CHARACTER SET \"utf8\";
SELECT RDB\$CHARACTER_SET_NAME FROM RDB\$DATABASE;"
check "4 on a database each server made: the name, a new column's set, an unknown one" "$(run "127.0.0.1/$REAL:$D/e-p8192.fdb" "$ALT")" "$(run "127.0.0.1/$PORT:$D/f-p8192.fdb" "$ALT")"
check "4 ...and the engine reads this server's result" "$(run "127.0.0.1/$REAL:$D/e-p8192.fdb" "SELECT RDB\$CHARACTER_SET_NAME FROM RDB\$DATABASE;")" "$(run "127.0.0.1/$REAL:$D/f-p8192.fdb" "SELECT RDB\$CHARACTER_SET_NAME FROM RDB\$DATABASE;")"

echo "--- 5 the header is this database's own"
ran=$((ran + 1))
G1=$(run "127.0.0.1/$REAL:$D/f-p8192.fdb" "SELECT MON\$GUID FROM MON\$DATABASE;" | sed -n 3p)
G2=$(run "127.0.0.1/$REAL:$D/f-plain.fdb" "SELECT MON\$GUID FROM MON\$DATABASE;" | sed -n 3p)
case "$G1" in
    *-????-4???-[89AB]???-*) if [ "$G1" != "$G2" ]; then echo "OK   5 a version-4 GUID per database ($G1 / $G2)"; else echo "FAIL 5 two creates share a GUID [$G1]"; fail=1; fi;;
    *) echo "FAIL 5 the GUID is no version-4 one [$G1]"; fail=1;;
esac
check "5 the creation time is now (the engine reads it)" "$(run "127.0.0.1/$REAL:$D/e-plain.fdb" "SELECT CAST(MON\$CREATION_DATE AS DATE) - CURRENT_DATE, IIF(DATEDIFF(MINUTE FROM MON\$CREATION_DATE TO CURRENT_TIMESTAMP) < 30, 'recent', 'old') FROM MON\$DATABASE;")" "$(run "127.0.0.1/$REAL:$D/f-plain.fdb" "SELECT CAST(MON\$CREATION_DATE AS DATE) - CURRENT_DATE, IIF(DATEDIFF(MINUTE FROM MON\$CREATION_DATE TO CURRENT_TIMESTAMP) < 30, 'recent', 'old') FROM MON\$DATABASE;")"

MON="SELECT MON\$OWNER, MON\$CREATION_DATE, MON\$GUID, MON\$PAGE_SIZE, MON\$SWEEP_INTERVAL FROM MON\$DATABASE;"
check "5 MON\$DATABASE through this server: the owner, the creation time, the GUID - as the engine reads the same file" "$(run "127.0.0.1/$REAL:$D/f-plain.fdb" "$MON")" "$(run "127.0.0.1/$PORT:$D/f-plain.fdb" "$MON")"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-nc-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 71 ]; then echo "FAIL only $ran checks ran (floor 71) - cells went missing"; fail=1; fi
exit $fail
