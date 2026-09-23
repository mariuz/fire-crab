#!/bin/bash
# A LIKE / STARTING WITH PATTERN AGAINST A TEMPORAL OPERAND IS CONVERTED
# AT PREPARE AND RENDERED BACK.
#
# The third family of `serve-real-i128like.sh`'s law - after the
# INT128-backed exact numerics and DOUBLE PRECISION - and the one whose
# render is not a number's:
#
#   DT LIKE '2%'         -> RAISES 22018    DT LIKE '2020-1-15'   -> row 1
#   DT LIKE '15.01.2020' -> row 1           DT LIKE '15-JAN-2020' -> row 1
#   TS LIKE '2020-1-15 10:20:30' -> row 1   TS LIKE '10:20:30'    -> RAISES
#   TM LIKE '10:20:30.0' -> row 1           TM LIKE '10:20'       -> (none)
#
# A wildcard cannot convert, so it raises the ONE-LINE 22018 AT PREPARE
# with no describe, exactly as a wide numeric's does.  THREE things then
# decide the text that comes back, and each has its own section here:
#
#   * THE OPERAND'S TYPE PICKS THE GRAMMAR.  A DATE takes a date and
#     nothing else, a TIME takes a time, a TIMESTAMP takes a date with an
#     optional time - so the SAME text raises against one and converts
#     against another (§3).
#   * THE OPERAND'S TYPE ALSO PICKS THE CORE RENDER, filling a missing
#     time: against a row holding today at midnight `TS LIKE '<today>'`
#     ANSWERS, so the render is the full `YYYY-MM-DD HH:MM:SS.FFFF`.
#   * THE ZONE COMES FROM THE TEXT AND NEVER FROM THE OPERAND (§4).  A
#     zoned pattern against a ZONELESS operand keeps its zone and matches
#     nothing; a zoneless one against a ZONED operand renders without a
#     zone and matches nothing.  An offset normalises through the zone id
#     and a region name through the zone table.
#
# TODAY / NOW / YESTERDAY / TOMORROW KEEP THE RAW TEXT (§5): they neither
# raise nor convert, which row 6 - written at CURRENT_DATE - is what
# proves.
#
# Usage: qa/serve-real-tmplike.sh [port]   (default 4472)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4472}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/tmplike-eng.fdb"; FC="$D/tmplike-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"

# TODAY, as the fixture's row 6 will hold it.  Every cell that uses it is
# checked by the sentinel below, so a run that straddles midnight fails
# loudly instead of quietly measuring the wrong day.
TODAY=$(date +%F)

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (
  ID INTEGER, DT DATE, TS TIMESTAMP, TSZ TIMESTAMP WITH TIME ZONE,
  TM TIME, TMZ TIME WITH TIME ZONE, S VARCHAR(40), N92 NUMERIC(9,2));
CREATE TABLE U (ID INTEGER, TAG VARCHAR(5));
CREATE TABLE W (ID INTEGER, DT DATE);
CREATE TABLE C (ID INTEGER, DT DATE, CP COMPUTED BY (DT + 1));
COMMIT;
INSERT INTO T VALUES (1,'2020-01-15','2020-01-15 10:20:30','2020-01-15 10:20:30 +02:00','10:20:30','10:20:30 +02:00','2020-01-15',1.50);
INSERT INTO T VALUES (2,'2021-02-05','2021-02-05 01:02:03.1234','2021-02-05 01:02:03.1234 +02:00','01:02:03.1234','01:02:03.1234 +02:00','2021-02-05',10.00);
INSERT INTO T VALUES (3,'1999-12-31','1999-12-31 23:59:59.9999','1999-12-31 23:59:59.9999 +02:00','23:59:59.9999','23:59:59.9999 +02:00','1999-12-31',100.50);
INSERT INTO T VALUES (4,'2020-01-16','2020-01-15 08:20:30','2020-01-15 10:20:30 Europe/Bucharest','12:20:30','12:20:30 +04:00','x',0.00);
INSERT INTO T VALUES (5,'2020-01-17','2020-01-15 12:20:30','2020-01-15 08:20:30 GMT','08:20:30','08:20:30 GMT','y',0.00);
INSERT INTO T VALUES (6, CURRENT_DATE, CAST('TODAY' AS TIMESTAMP),'2020-01-18 00:00:00 +00:00','00:00:00','00:00:00 +00:00','z',0.00);
INSERT INTO U VALUES (1,'a'); INSERT INTO U VALUES (2,'b'); INSERT INTO U VALUES (3,'c');
INSERT INTO W VALUES (1,'2020-01-15'); INSERT INTO W VALUES (2,'2021-02-05');
INSERT INTO C (ID,DT) VALUES (1,'2020-01-15'); INSERT INTO C (ID,DT) VALUES (2,'2021-02-05');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/tmplike-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/tmplike-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/tmplike-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/tmplike-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-tmplike-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
LOST='const lost=e=>/was lost|ECONNRESET|EPIPE|Connection is closed|socket hang up/i.test(String((e&&e.message)||e));'
FMT='const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":v).join()).join(";");'
q() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e "$LOST$FMT"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
      if(e2){if(lost(e2)){console.log("CONN_ERR");process.exit(1);}console.log("ERR");db.detach();process.exit(0);}
      console.log(fmt(r));db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
run() { local n=0 r; while [ $n -lt 8 ]; do r=$(q "$1" "$2" "$3" "$4")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }
# the FULL error vector as isql renders it - a ONE-LINE 22018 and a
# 22009 zone reason are different answers and `ERR` cannot tell them apart
err() { printf '%s;\n' "$2" | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 \
    | tr -d '\r' | grep -aiE 'SQLSTATE|conversion error|Invalid time zone' | sed 's/^ *//;s/  */ /g' | paste -sd'|'; }

# the value AND the whole describe must match
both() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] && [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - that is an err_same cell]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - the value agrees, the announcement does not)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# [both] with the ENGINE's answer PINNED as well, for a cell whose
# agreement would otherwise be vacuous - two servers that both did
# nothing agree perfectly.
both_is() { # <label> <sql> <engine-answer>
    ran=$((ran + 1))
    local ev fv
    ev=$(run "$REAL" "$ENG" "$2" '[]'); fv=$(run "$PORT" "$FC" "$2" '[]')
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" != "$3" ]; then
        echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]; the cell before it did not do what it claims"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# a DML statement has no describe of its own: run it on both sides and
# let the cell after it read the damage
exec_both() {
    ran=$((ran + 1))
    local ev fv
    ev=$(run "$REAL" "$ENG" "$2" '[]'); fv=$(run "$PORT" "$FC" "$2" '[]')
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] || [ "$fv" = ERR ]; then
        echo "FAIL $1 - the statement did not run [eng=$ev] [fc=$fv]"; fail=1
    else echo "OK   $1"; fi
}
# BOTH raise, the VECTORS ARE THE SAME TEXT, and - because this whole law
# is about WHEN the raise happens - NEITHER emits a describe
err_same() {
    ran=$((ran + 1))
    local ee fe ed fd
    ee=$(err "127.0.0.1/$REAL:$ENG" "$2"); fe=$(err "127.0.0.1/$PORT:$FC" "$2")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ee" ]; then echo "FAIL $1 - THE ENGINE NO LONGER RAISES; the boundary moved"; fail=1
    elif [ -z "$fe" ]; then echo "FAIL $1 - this server did not raise"; fail=1
    elif [ "$ee" != "$fe" ]; then
        echo "FAIL $1 (the VECTOR)"; echo "     eng=[$ee]"; echo "     fc =[$fe]"; fail=1
    elif [ -n "$ed" ]; then echo "FAIL $1 - the ENGINE emitted a describe, so this is not a prepare-time raise"; fail=1
    elif [ -n "$fd" ]; then echo "FAIL $1 - THIS SERVER ANSWERED THE PREPARE [$fd] and raised later"; fail=1
    else echo "OK   $1 [$ee]"; fi
}
# BOTH raise and the VECTORS DIFFER - both pinned as they stand, so the
# cell fails the day either one moves.  Recorded, not fixed.
err_differs() { # <label> <sql> <engine-vector-substring> <this-server-vector-substring>
    ran=$((ran + 1))
    local ee fe
    ee=$(err "127.0.0.1/$REAL:$ENG" "$2"); fe=$(err "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ee" ] || [ -z "$fe" ]; then echo "FAIL $1 - one of the two stopped raising [eng=$ee] [fc=$fe]"; fail=1
    elif [ "${ee#*$3}" = "$ee" ]; then echo "FAIL $1 - the ENGINE vector moved: [$ee] no longer carries [$3]"; fail=1
    elif [ "${fe#*$4}" = "$fe" ]; then echo "FAIL $1 - THIS SERVER's vector moved: [$fe] no longer carries [$4] - if it now matches the engine, promote the cell"; fail=1
    else echo "OK   $1 (recorded vector gap: engine [$3], this server [$4])"; fi
}
# BOTH ANSWER AND THE ANSWERS DIFFER - a recorded WRONG ANSWER, pinned on
# both sides so it fails the day either moves.
differs() { # <label> <sql> <engine-answer> <this-server-answer>
    ran=$((ran + 1))
    local ev fv
    ev=$(run "$REAL" "$ENG" "$2" '[]'); fv=$(run "$PORT" "$FC" "$2" '[]')
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" != "$3" ]; then echo "FAIL $1 - the ENGINE now answers [$ev], not [$3]"; fail=1
    elif [ "$fv" = "$3" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES [$fv]; promote the cell"; fail=1
    elif [ "$fv" != "$4" ]; then echo "FAIL $1 - this server now answers [$fv], not [$4]"; fail=1
    else echo "OK   $1 (recorded gap: engine [$ev], this server [$fv])"; fi
}
# the engine ANSWERS and this server refuses - a recorded boundary
eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE no longer answers; the boundary moved"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS SERVER ANSWERS [$fv] where it must refuse"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}

# A SENTINEL BEFORE ANY CELL.  This gate is about WHICH GRAMMAR an
# operand's TYPE selects, so it proves the five declared types really are
# five different sqltypes - a fixture that quietly declared TM as a
# TIMESTAMP would make half the §3 cells agree for the wrong reason - and
# it proves row 6 really is TODAY, since every special cell reads it.
sent=$(run "$REAL" "$ENG" "SELECT (SELECT COUNT(*) FROM T) A,(SELECT COUNT(*) FROM U) B,(SELECT COUNT(*) FROM T WHERE ID=6 AND DT=CURRENT_DATE) C FROM RDB\$DATABASE" '[]')
[ "$sent" = "6,3,1" ] || { echo "FAIL SENTINEL rows [$sent] (want 6,3,1 - row 6 must be TODAY; did this run straddle midnight?)"; exit 1; }
wid=$(printf 'SET SQLDA_DISPLAY ON;\nSELECT DT, TS, TSZ, TM, TMZ FROM T;\n' \
      | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' \
      | grep -aoE 'sqltype: [0-9]+' | tr -s ' ' | paste -sd'|')
[ "$wid" = "sqltype: 570|sqltype: 510|sqltype: 32754|sqltype: 560|sqltype: 32756" ] \
  || { echo "FAIL SENTINEL types [$wid] - the five temporal families are not what this gate assumes"; exit 1; }
tod=$(run "$REAL" "$ENG" "SELECT ID FROM T WHERE DT LIKE '$TODAY' ORDER BY ID" '[]')
[ "$tod" = "6" ] || { echo "FAIL SENTINEL today [$tod] (want 6) - the date this gate computed is not the row's"; exit 1; }
echo "OK   SENTINEL [$sent | $wid | today=$TODAY]"

echo "--- 1. THE BOUNDARY: a wildcard raises on every temporal operand"
err_same  "1 DT LIKE '2%'   - DATE"                       "SELECT ID FROM T WHERE DT LIKE '2%'"
err_same  "1 TS LIKE '2%'   - TIMESTAMP"                  "SELECT ID FROM T WHERE TS LIKE '2%'"
err_same  "1 TSZ LIKE '2%'  - TIMESTAMP WITH TIME ZONE"   "SELECT ID FROM T WHERE TSZ LIKE '2%'"
err_same  "1 TM LIKE '_0:20:30' - TIME, a wildcard the zone parser never sees" "SELECT ID FROM T WHERE TM LIKE '_0:20:30'"
err_same  "1 TMZ LIKE '1_:20:30 +02:00' - TIME WITH TIME ZONE" "SELECT ID FROM T WHERE TMZ LIKE '1_:20:30 +02:00'"
err_same  "1 DT LIKE '%'"                                 "SELECT ID FROM T WHERE DT LIKE '%'"
err_same  "1 DT LIKE '_'"                                 "SELECT ID FROM T WHERE DT LIKE '_'"
err_same  "1 DT LIKE '2020-01-1_' - a wildcard INSIDE a well-formed date" "SELECT ID FROM T WHERE DT LIKE '2020-01-1_'"
err_same  "1 DT LIKE '2020-01-15%' - ...and after one"    "SELECT ID FROM T WHERE DT LIKE '2020-01-15%'"
err_same  "1 DT LIKE 'abc'"                               "SELECT ID FROM T WHERE DT LIKE 'abc'"
err_same  "1 DT LIKE ''      - the empty string"          "SELECT ID FROM T WHERE DT LIKE ''"
err_same  "1 DT LIKE ' abc ' - THE VECTOR QUOTES THE PATTERN AS WRITTEN, blanks and all" "SELECT ID FROM T WHERE DT LIKE ' abc '"
both      "1 CONTROL S LIKE '2%'  - a VARCHAR column is a real pattern" "SELECT ID FROM T WHERE S LIKE '2%' ORDER BY ID"
both      "1 CONTROL N92 LIKE '1%' - and so is a NARROW numeric" "SELECT ID FROM T WHERE N92 LIKE '1%' ORDER BY ID"

echo "--- 2. THE ROUND TRIP: the whole CVT date grammar converts, and the render is canonical"
both      "2 DT LIKE '2020-01-15' - the canonical spelling" "SELECT ID FROM T WHERE DT LIKE '2020-01-15' ORDER BY ID"
both      "2 DT LIKE '2020-1-15'  - THE CELL RAW TEXT CANNOT PRODUCE" "SELECT ID FROM T WHERE DT LIKE '2020-1-15' ORDER BY ID"
both      "2 DT LIKE '15.01.2020' - day-first, dotted"    "SELECT ID FROM T WHERE DT LIKE '15.01.2020' ORDER BY ID"
both      "2 DT LIKE '2020/01/15' - slashed"              "SELECT ID FROM T WHERE DT LIKE '2020/01/15' ORDER BY ID"
both      "2 DT LIKE '15-JAN-2020' - an English month"    "SELECT ID FROM T WHERE DT LIKE '15-JAN-2020' ORDER BY ID"
both      "2 DT LIKE 'JAN-15-2020'"                       "SELECT ID FROM T WHERE DT LIKE 'JAN-15-2020' ORDER BY ID"
both      "2 DT LIKE '2020-JAN-15'"                       "SELECT ID FROM T WHERE DT LIKE '2020-JAN-15' ORDER BY ID"
both      "2 DT LIKE '15 JAN 2020' - blank-separated"     "SELECT ID FROM T WHERE DT LIKE '15 JAN 2020' ORDER BY ID"
both      "2 DT LIKE ' 2020-01-15 ' - the outer blanks go in the conversion" "SELECT ID FROM T WHERE DT LIKE ' 2020-01-15 ' ORDER BY ID"
both      "2 DT LIKE '  2020-01-15'"                      "SELECT ID FROM T WHERE DT LIKE '  2020-01-15' ORDER BY ID"
both      "2 DT LIKE '2020-1-5'  - ...and it can still miss" "SELECT ID FROM T WHERE DT LIKE '2020-1-5' ORDER BY ID"
both      "2 DT LIKE '2021-02-05'"                        "SELECT ID FROM T WHERE DT LIKE '2021-02-05' ORDER BY ID"
both      "2 DT LIKE '1999-12-31'"                        "SELECT ID FROM T WHERE DT LIKE '1999-12-31' ORDER BY ID"
err_same  "2 DT LIKE '20-01-15'   - a two-digit year is not this grammar's" "SELECT ID FROM T WHERE DT LIKE '20-01-15'"
err_same  "2 DT LIKE '2020-02-30' - an impossible day"    "SELECT ID FROM T WHERE DT LIKE '2020-02-30'"
err_same  "2 DT LIKE '32768-01-01' - and a year past the engine's range" "SELECT ID FROM T WHERE DT LIKE '32768-01-01'"
err_same  "2 DT LIKE 'JAN 15, 2020' - the comma spelling is not in it"  "SELECT ID FROM T WHERE DT LIKE 'JAN 15, 2020'"
err_same  "2 DT LIKE '2 0 2 0-01-15' - AND AN INTERIOR BLANK IS NOT SKIPPED, which the numeric law's lenient grammar does" "SELECT ID FROM T WHERE DT LIKE '2 0 2 0-01-15'"
both      "2 TM LIKE '10:20:30'   - the fraction is padded to four"  "SELECT ID FROM T WHERE TM LIKE '10:20:30' ORDER BY ID"
both      "2 TM LIKE '10:20:30.0'"                        "SELECT ID FROM T WHERE TM LIKE '10:20:30.0' ORDER BY ID"
both      "2 TM LIKE '10:20:30.'  - a bare point"         "SELECT ID FROM T WHERE TM LIKE '10:20:30.' ORDER BY ID"
both      "2 TM LIKE '1:2:3.1234' - single digits"        "SELECT ID FROM T WHERE TM LIKE '1:2:3.1234' ORDER BY ID"
both      "2 TM LIKE '10:20'      - a missing second is 00, so this misses" "SELECT ID FROM T WHERE TM LIKE '10:20' ORDER BY ID"
both      "2 TM LIKE '23:59:59.9999'"                     "SELECT ID FROM T WHERE TM LIKE '23:59:59.9999' ORDER BY ID"
err_same  "2 TM LIKE '10:20:30.00000' - five fraction digits"  "SELECT ID FROM T WHERE TM LIKE '10:20:30.00000'"
err_same  "2 TM LIKE '24:00:00'    - and an hour past the day" "SELECT ID FROM T WHERE TM LIKE '24:00:00'"
both      "2 TS LIKE '2020-01-15 10:20:30.0000' - the canonical timestamp" "SELECT ID FROM T WHERE TS LIKE '2020-01-15 10:20:30.0000' ORDER BY ID"
both      "2 TS LIKE '2020-1-15 10:20:30'"                "SELECT ID FROM T WHERE TS LIKE '2020-1-15 10:20:30' ORDER BY ID"
both      "2 TS LIKE '2021-02-05 1:2:3.1234'"             "SELECT ID FROM T WHERE TS LIKE '2021-02-05 1:2:3.1234' ORDER BY ID"

echo "--- 3. THE OPERAND'S TYPE PICKS THE GRAMMAR - the same text, two answers"
err_same  "3 DT LIKE '2020-01-15 00:00:00' - a DATE takes NO time part" "SELECT ID FROM T WHERE DT LIKE '2020-01-15 00:00:00'"
both      "3 TS LIKE '2020-01-15 00:00:00' - ...and the TIMESTAMP twin converts it" "SELECT ID FROM T WHERE TS LIKE '2020-01-15 00:00:00' ORDER BY ID"
err_same  "3 DT LIKE '2020-01-15 +02:00'   - nor a zone"  "SELECT ID FROM T WHERE DT LIKE '2020-01-15 +02:00'"
err_same  "3 DT LIKE '2020-01-15 zz'       - nor anything else" "SELECT ID FROM T WHERE DT LIKE '2020-01-15 zz'"
err_same  "3 TS LIKE '10:20:30'  - a TIMESTAMP takes NO time-only text" "SELECT ID FROM T WHERE TS LIKE '10:20:30'"
both      "3 TM LIKE '10:20:30'  - ...and the TIME twin answers the row" "SELECT ID FROM T WHERE TM LIKE '10:20:30' ORDER BY ID"
err_same  "3 TM LIKE '2020-01-15' - a TIME takes no date"  "SELECT ID FROM T WHERE TM LIKE '2020-01-15'"
both      "3 TS LIKE '$TODAY' - A DATE-ONLY TEXT FILLS 00:00:00, which row 6 proves" "SELECT ID FROM T WHERE TS LIKE '$TODAY' ORDER BY ID"
both      "3 DT LIKE '$TODAY' - the DATE twin of the same text"  "SELECT ID FROM T WHERE DT LIKE '$TODAY' ORDER BY ID"
both      "3 TS LIKE '2020-01-15' - and where no row is at midnight it misses" "SELECT ID FROM T WHERE TS LIKE '2020-01-15' ORDER BY ID"
both      "3 TS LIKE '2020-01-15 08:20:30' - row 4, so the TIMESTAMP cells are not all row 1" "SELECT ID FROM T WHERE TS LIKE '2020-01-15 08:20:30' ORDER BY ID"

echo "--- 4. THE ZONE COMES FROM THE TEXT, NEVER FROM THE OPERAND"
both      "4 TM LIKE '10:20:30 +02:00' - A ZONED PATTERN AGAINST A ZONELESS OPERAND MATCHES NOTHING - not the 10:20:30 row, and not the 08:20:30 one a session conversion would reach" "SELECT ID FROM T WHERE TM LIKE '10:20:30 +02:00' ORDER BY ID"
both      "4 TMZ LIKE '10:20:30 +02:00' - ...and the ZONED twin answers on the same text" "SELECT ID FROM T WHERE TMZ LIKE '10:20:30 +02:00' ORDER BY ID"
both      "4 TM LIKE '12:20:30 +02:00' - nor the wall clock a dropped zone would give" "SELECT ID FROM T WHERE TM LIKE '12:20:30 +02:00' ORDER BY ID"
both      "4 TM LIKE '12:20:30'        - which IS a row when the zone is not written" "SELECT ID FROM T WHERE TM LIKE '12:20:30' ORDER BY ID"
both      "4 TMZ LIKE '08:20:30'       - and a ZONELESS pattern against a ZONED operand misses" "SELECT ID FROM T WHERE TMZ LIKE '08:20:30' ORDER BY ID"
both      "4 TS LIKE '2020-01-15 10:20:30 +02:00' - the TIMESTAMP half of the same rule" "SELECT ID FROM T WHERE TS LIKE '2020-01-15 10:20:30 +02:00' ORDER BY ID"
both      "4 TSZ LIKE '2020-1-15 10:20:30 +02:00' - ...and its zoned twin" "SELECT ID FROM T WHERE TSZ LIKE '2020-1-15 10:20:30 +02:00' ORDER BY ID"
both      "4 TSZ LIKE '2020-01-15 10:20:30' - and a zoneless pattern misses every zoned row" "SELECT ID FROM T WHERE TSZ LIKE '2020-01-15 10:20:30' ORDER BY ID"
both      "4 TMZ LIKE '10:20:30.0000 +2:00' - AN OFFSET NORMALISES through the zone id" "SELECT ID FROM T WHERE TMZ LIKE '10:20:30.0000 +2:00' ORDER BY ID"
both      "4 TMZ LIKE '10:20:30.0000+02:00' - ...with no blank at all" "SELECT ID FROM T WHERE TMZ LIKE '10:20:30.0000+02:00' ORDER BY ID"
both      "4 TSZ LIKE '2020-01-15 10:20:30+02:00' - the TIMESTAMP spelling of that" "SELECT ID FROM T WHERE TSZ LIKE '2020-01-15 10:20:30+02:00' ORDER BY ID"
both      "4 TMZ LIKE '08:20:30 -00:00' - and -00:00 renders as +00:00, which row 6 has" "SELECT ID FROM T WHERE TMZ LIKE '08:20:30 -00:00' ORDER BY ID"
both      "4 TMZ LIKE '00:00:00 +00:00' - row 6 through the plain spelling" "SELECT ID FROM T WHERE TMZ LIKE '00:00:00 +00:00' ORDER BY ID"
both      "4 TMZ LIKE '08:20:30 GMT'  - A REGION IS RENDERED BY NAME, and row 5 is stored in one" "SELECT ID FROM T WHERE TMZ LIKE '08:20:30 GMT' ORDER BY ID"
both      "4 TMZ LIKE '08:20:30 gmt'  - ...canonicalised out of the zone table" "SELECT ID FROM T WHERE TMZ LIKE '08:20:30 gmt' ORDER BY ID"
both      "4 TSZ LIKE '2020-01-15 08:20:30 gmt' - the TIMESTAMP twin" "SELECT ID FROM T WHERE TSZ LIKE '2020-01-15 08:20:30 gmt' ORDER BY ID"
both      "4 TMZ LIKE '08:20:30 +00:00' - AND GMT IS NOT +00:00 HERE: the same instant, a different TEXT" "SELECT ID FROM T WHERE TMZ LIKE '08:20:30 +00:00' ORDER BY ID"
both      "4 TM LIKE '10:20:30 Europe/Bucharest' - a region against a zoneless operand still keeps it" "SELECT ID FROM T WHERE TM LIKE '10:20:30 Europe/Bucharest' ORDER BY ID"
both      "4 TMZ LIKE '12:20:30 +04:00' - row 4, so the zoned cells are not all row 1" "SELECT ID FROM T WHERE TMZ LIKE '12:20:30 +04:00' ORDER BY ID"
both      "4 TSZ LIKE '2020-01-18 00:00:00 +00:00' - and row 6" "SELECT ID FROM T WHERE TSZ LIKE '2020-01-18 00:00:00 +00:00' ORDER BY ID"

echo "--- 5. TODAY / NOW / YESTERDAY / TOMORROW KEEP THE RAW TEXT"
# Row 6 holds CURRENT_DATE and today-at-midnight, so these are not
# 'matches nothing either way' cells: the converted reading PREDICTS row
# 6 in each of the first three, and the engine answers none.
both      "5 DT LIKE 'TODAY'  - row 6 IS today, and the engine does not find it" "SELECT ID FROM T WHERE DT LIKE 'TODAY' ORDER BY ID"
both      "5 TS LIKE 'TODAY'  - nor at midnight"          "SELECT ID FROM T WHERE TS LIKE 'TODAY' ORDER BY ID"
both      "5 TS STARTING WITH 'TODAY' - nor as a PREFIX, which a date render would be" "SELECT ID FROM T WHERE TS STARTING WITH 'TODAY' ORDER BY ID"
both      "5 DT LIKE 'NOW'"                               "SELECT ID FROM T WHERE DT LIKE 'NOW' ORDER BY ID"
both      "5 DT LIKE 'YESTERDAY'"                         "SELECT ID FROM T WHERE DT LIKE 'YESTERDAY' ORDER BY ID"
both      "5 DT LIKE 'today'  - case does not matter"     "SELECT ID FROM T WHERE DT LIKE 'today' ORDER BY ID"
both      "5 DT LIKE ' TODAY ' - nor the surrounding blanks" "SELECT ID FROM T WHERE DT LIKE ' TODAY ' ORDER BY ID"
both      "5 TM LIKE 'TODAY'  - and not even where the grammar has no such value" "SELECT ID FROM T WHERE TM LIKE 'TODAY' ORDER BY ID"
both      "5 TM LIKE 'NOW'"                               "SELECT ID FROM T WHERE TM LIKE 'NOW' ORDER BY ID"
err_same  "5 DT LIKE 'TODAYX' - and it is THESE FOUR WORDS, not a lenient special grammar" "SELECT ID FROM T WHERE DT LIKE 'TODAYX'"
err_same  "5 DT LIKE 'TOD'"                               "SELECT ID FROM T WHERE DT LIKE 'TOD'"
err_same  "5 TS LIKE 'TODAY.' - which even a CAST refuses on this engine" "SELECT ID FROM T WHERE TS LIKE 'TODAY.'"

echo "--- 6. THE RAISE IS AT PREPARE, and it reaches DML"
err_same  "6 DT NOT LIKE '2%'   - negation does not excuse it" "SELECT ID FROM T WHERE DT NOT LIKE '2%'"
both      "6 DT NOT LIKE '2020-01-15' - ...and a converting pattern negates normally" "SELECT ID FROM T WHERE DT NOT LIKE '2020-01-15' ORDER BY ID"
err_same  "6 1 = 0 AND DT LIKE '2%' - a dead conjunct still raises" "SELECT ID FROM T WHERE 1 = 0 AND DT LIKE '2%'"
err_same  "6 ID = 99 AND DT LIKE '2%' - and an empty result"   "SELECT ID FROM T WHERE ID = 99 AND DT LIKE '2%'"
# the conversion runs BEFORE the escape is ever read, which is why an
# ESCAPE clause changes nothing here and a pattern carrying the escape
# character raises like any other unconvertible text
both      "6 DT LIKE '2020-01-15' ESCAPE '!' - an ESCAPE clause over a converted pattern" "SELECT ID FROM T WHERE DT LIKE '2020-01-15' ESCAPE '!' ORDER BY ID"
err_same  "6 DT LIKE '2020-01-15!' ESCAPE '!' - ...and the escape character is not a date" "SELECT ID FROM T WHERE DT LIKE '2020-01-15!' ESCAPE '!'"
err_same  "6 DELETE FROM W WHERE DT LIKE '2%'"            "DELETE FROM W WHERE DT LIKE '2%'"
both_is   "6 ...and W is untouched"                       "SELECT ID FROM W ORDER BY ID" "1;2"
err_same  "6 UPDATE W SET ID = 77 WHERE DT LIKE '2%'"     "UPDATE W SET ID = 77 WHERE DT LIKE '2%'"
both_is   "6 ...and nothing was renumbered"               "SELECT ID FROM W ORDER BY ID" "1;2"
exec_both "6 DELETE FROM W WHERE DT LIKE '2020-01-15' - a CONVERTING pattern does delete" "DELETE FROM W WHERE DT LIKE '2020-01-15'"
both_is   "6 ...and W lost exactly that row"              "SELECT ID FROM W ORDER BY ID" "2"

echo "--- 7. THE ZONE PARSER'S OWN VECTORS - a 22009, not a 22018"
err_same  "7 TM LIKE '1%'  - the wildcard is read as a ZONE REGION" "SELECT ID FROM T WHERE TM LIKE '1%'"
err_same  "7 TM LIKE '10%'"                               "SELECT ID FROM T WHERE TM LIKE '10%'"
err_same  "7 TM LIKE '1 %'"                               "SELECT ID FROM T WHERE TM LIKE '1 %'"
err_same  "7 TM LIKE '10 x'"                              "SELECT ID FROM T WHERE TM LIKE '10 x'"
err_same  "7 TM LIKE '10:20:30 zz' - an unknown region after a GOOD time" "SELECT ID FROM T WHERE TM LIKE '10:20:30 zz'"
err_same  "7 TS LIKE '2020-01-15 %'  - the TIMESTAMP half"  "SELECT ID FROM T WHERE TS LIKE '2020-01-15 %'"
err_same  "7 TS LIKE '2020-01-15 10:20:30 zz'"            "SELECT ID FROM T WHERE TS LIKE '2020-01-15 10:20:30 zz'"
err_same  "7 TM LIKE '2020-01-15 10:20:30' - a DATE read as a time and an OFFSET" "SELECT ID FROM T WHERE TM LIKE '2020-01-15 10:20:30'"
err_same  "7 TM LIKE '10:20:30 +15:00' - an offset past +14:00" "SELECT ID FROM T WHERE TM LIKE '10:20:30 +15:00'"
err_same  "7 TM LIKE '10:20:30 +2'    - and one that is not hh:mm" "SELECT ID FROM T WHERE TM LIKE '10:20:30 +2'"
err_same  "7 TM LIKE 'zz' - A TEXT THAT DOES NOT OPEN WITH A DIGIT never reaches the zone parser" "SELECT ID FROM T WHERE TM LIKE 'zz'"
err_same  "7 TM LIKE 'x%'"                                "SELECT ID FROM T WHERE TM LIKE 'x%'"
err_same  "7 TM LIKE '10'   - a lone hour with no zone at all is the plain 22018" "SELECT ID FROM T WHERE TM LIKE '10'"
err_same  "7 TM LIKE '10 +02:00' - A GOOD ZONE AND A BAD HEAD is the plain 22018 too" "SELECT ID FROM T WHERE TM LIKE '10 +02:00'"
both      "7 TM LIKE '10:20 +02:00' - ...and a good head with a good zone converts" "SELECT ID FROM T WHERE TM LIKE '10:20 +02:00' ORDER BY ID"
both      "7 TM LIKE '10:20:30 +02:30' - an offset with minutes"  "SELECT ID FROM T WHERE TM LIKE '10:20:30 +02:30' ORDER BY ID"
both      "7 TM LIKE '10:20:30 UTC'    - and a region that is not GMT" "SELECT ID FROM T WHERE TM LIKE '10:20:30 UTC' ORDER BY ID"

# WHERE THE ZONE MAY OPEN AT ALL, which is not the same question for the
# two families: a TIME hands the parser the rest after ONE component
# (`'1%'`), a TIMESTAMP only after a COMPLETE DATE - three numeric
# components, valid or not - and neither does it after a SEPARATOR that
# opened a component which never arrived.
err_same  "7 TS LIKE '2%'           - one component is not a date, so this is the plain 22018" "SELECT ID FROM T WHERE TS LIKE '2%'"
err_same  "7 TS LIKE '2020-01 %'    - nor are two"     "SELECT ID FROM T WHERE TS LIKE '2020-01 %'"
err_same  "7 TS LIKE '2020-13-01 %' - THREE ARE, though the month is impossible: the COUNT decides, not the calendar" "SELECT ID FROM T WHERE TS LIKE '2020-13-01 %'"
err_same  "7 TS LIKE '2020-02-30 zz' - the same on a day that does not exist" "SELECT ID FROM T WHERE TS LIKE '2020-02-30 zz'"
err_same  "7 TS LIKE '2020-01-15zz'  - and NO BLANK is needed to open the zone" "SELECT ID FROM T WHERE TS LIKE '2020-01-15zz'"
err_same  "7 TS LIKE '2020-01-15 10 %' - a fourth component, then the zone" "SELECT ID FROM T WHERE TS LIKE '2020-01-15 10 %'"
err_same  "7 TS LIKE '2020-01-15 10:%' - ...but a ':' opened a minute that never came" "SELECT ID FROM T WHERE TS LIKE '2020-01-15 10:%'"
err_same  "7 TM LIKE '1:2%'         - two time components and the rest is a zone" "SELECT ID FROM T WHERE TM LIKE '1:2%'"
err_same  "7 TM LIKE '10:20:30.%'   - ...and a '.' opened a fraction that never came" "SELECT ID FROM T WHERE TM LIKE '10:20:30.%'"
err_differs "7 TS LIKE '15 JAN 2020 zz' - AN ENGLISH MONTH IS A COMPONENT THIS SPLITTER CANNOT COUNT, so the zone reason is lost and the plain one takes its place" \
            "SELECT ID FROM T WHERE TS LIKE '15 JAN 2020 zz'" "22009" "22018"

echo "--- 8. STARTING WITH is the SAME conversion - and this server refused it outright"
both      "8 DT STARTING WITH '2020-01-15'"               "SELECT ID FROM T WHERE DT STARTING WITH '2020-01-15' ORDER BY ID"
both      "8 DT STARTING WITH '2020-1-15' - through the same grammar" "SELECT ID FROM T WHERE DT STARTING WITH '2020-1-15' ORDER BY ID"
both      "8 DT STARTING WITH '15.01.2020'"               "SELECT ID FROM T WHERE DT STARTING WITH '15.01.2020' ORDER BY ID"
err_same  "8 DT STARTING WITH '2020' - a PREFIX of the render is NOT a prefix here: it must convert" "SELECT ID FROM T WHERE DT STARTING WITH '2020'"
err_same  "8 DT STARTING WITH 'abc'"                      "SELECT ID FROM T WHERE DT STARTING WITH 'abc'"
both      "8 TS STARTING WITH '2020-1-15 10:20:30'"       "SELECT ID FROM T WHERE TS STARTING WITH '2020-1-15 10:20:30' ORDER BY ID"
both      "8 TS STARTING WITH '2020-01-15' - THE PREFIX IS THE FILLED-IN MIDNIGHT, so it misses" "SELECT ID FROM T WHERE TS STARTING WITH '2020-01-15' ORDER BY ID"
both      "8 TS STARTING WITH '$TODAY' - ...and hits the row that IS at midnight" "SELECT ID FROM T WHERE TS STARTING WITH '$TODAY' ORDER BY ID"
both      "8 TM STARTING WITH '10:20:30'"                 "SELECT ID FROM T WHERE TM STARTING WITH '10:20:30' ORDER BY ID"
both      "8 TM STARTING WITH '10:20:30.0'"               "SELECT ID FROM T WHERE TM STARTING WITH '10:20:30.0' ORDER BY ID"
both      "8 TMZ STARTING WITH '10:20:30 +02:00'"         "SELECT ID FROM T WHERE TMZ STARTING WITH '10:20:30 +02:00' ORDER BY ID"
both      "8 DT STARTING WITH 'TODAY' - the specials keep their raw text here too" "SELECT ID FROM T WHERE DT STARTING WITH 'TODAY' ORDER BY ID"
err_same  "8 TM STARTING WITH '1%' - and the zone parser answers the same way" "SELECT ID FROM T WHERE TM STARTING WITH '1%'"
both      "8 DT NOT STARTING WITH '2020-01-15'"           "SELECT ID FROM T WHERE DT NOT STARTING WITH '2020-01-15' ORDER BY ID"
both      "8 CONTROL S STARTING WITH '2020' - a VARCHAR prefix is untouched" "SELECT ID FROM T WHERE S STARTING WITH '2020' ORDER BY ID"

echo "--- 9. THE ROUTERS: a WHERE over a plain column is not the only way in"
err_same  "9 JOIN + WHERE T.DT LIKE '2%'"                 "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.DT LIKE '2%'"
both      "9 JOIN + WHERE T.DT LIKE '2020-1-15' - and a converting pattern answers" "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.DT LIKE '2020-1-15' ORDER BY T.ID"
err_same  "9 WHERE IIF(DT LIKE '2%',1,0) = 1"            "SELECT ID FROM T WHERE IIF(DT LIKE '2%',1,0) = 1"
both      "9 WHERE IIF(DT LIKE '2020-1-15',1,0) = 1"     "SELECT ID FROM T WHERE IIF(DT LIKE '2020-1-15',1,0) = 1 ORDER BY ID"
err_same  "9 SELECT SUM(IIF(DT LIKE '2%',..)) - a PROJECTION" "SELECT SUM(IIF(DT LIKE '2%',1,0)) A FROM T"
both      "9 SELECT SUM(IIF(DT LIKE '2020-1-15',..))"    "SELECT SUM(IIF(DT LIKE '2020-1-15',1,0)) A FROM T"
err_same  "9 SELECT SUM(CASE WHEN TM LIKE '1%' ..) - the zone vector through a projection" "SELECT SUM(CASE WHEN TM LIKE '1%' THEN 1 ELSE 0 END) A FROM T"
both      "9 SELECT SUM(CASE WHEN TM LIKE '10:20:30' ..)" "SELECT SUM(CASE WHEN TM LIKE '10:20:30' THEN 1 ELSE 0 END) A FROM T"
err_same  "9 WHERE CP LIKE '2%' - a COMPUTED BY temporal column" "SELECT ID FROM C WHERE CP LIKE '2%'"
both      "9 WHERE CP LIKE '2020-1-16' - ...which converts to the computed day" "SELECT ID FROM C WHERE CP LIKE '2020-1-16' ORDER BY ID"
err_same  "9 WHERE DT + 1 LIKE '2%' - an arithmetic operand" "SELECT ID FROM T WHERE DT + 1 LIKE '2%'"
both      "9 WHERE DT + 1 LIKE '2020-1-16'"              "SELECT ID FROM T WHERE DT + 1 LIKE '2020-1-16' ORDER BY ID"
err_same  "9 WHERE CAST(DT AS TIMESTAMP) LIKE '2%' - a CAST" "SELECT ID FROM T WHERE CAST(DT AS TIMESTAMP) LIKE '2%'"
both      "9 WHERE CAST(DT AS TIMESTAMP) LIKE '2020-01-15' - and the CAST's OWN type picks the grammar" "SELECT ID FROM T WHERE CAST(DT AS TIMESTAMP) LIKE '2020-01-15' ORDER BY ID"
both      "9 WHERE CAST(TS AS DATE) LIKE '2020-01-15' - narrowed the other way" "SELECT ID FROM T WHERE CAST(TS AS DATE) LIKE '2020-01-15' ORDER BY ID"
both      "9 CONTROL CAST(DT AS VARCHAR(20)) LIKE '2%' - rendered FIRST, so it is a real pattern again" "SELECT ID FROM T WHERE CAST(DT AS VARCHAR(20)) LIKE '2%' ORDER BY ID"
both      "9 JOIN + T.DT STARTING WITH '2020-1-15' - the prefix half through the join router" "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.DT STARTING WITH '2020-1-15' ORDER BY T.ID"

echo "--- 10. MUST NOT TOUCH: the comparison operators on the same columns"
both      "10 DT = '2020-1-15'   - the comparison converts too, and always did" "SELECT ID FROM T WHERE DT = '2020-1-15' ORDER BY ID"
both      "10 DT = 'TODAY'       - ...and it DOES take the specials, which the pattern does not" "SELECT ID FROM T WHERE DT = 'TODAY' ORDER BY ID"
both      "10 DT > '2020-01-16'"                          "SELECT ID FROM T WHERE DT > '2020-01-16' ORDER BY ID"
both      "10 DT BETWEEN '2020-01-01' AND '2020-12-31'"   "SELECT ID FROM T WHERE DT BETWEEN '2020-01-01' AND '2020-12-31' ORDER BY ID"
both      "10 DT IN ('2020-01-15','2021-02-05')"          "SELECT ID FROM T WHERE DT IN ('2020-01-15','2021-02-05') ORDER BY ID"
both      "10 TM = '10:20:30'"                            "SELECT ID FROM T WHERE TM = '10:20:30' ORDER BY ID"
both      "10 TS = '2020-1-15 10:20:30'"                  "SELECT ID FROM T WHERE TS = '2020-1-15 10:20:30' ORDER BY ID"
both      "10 DT IS NULL"                                 "SELECT ID FROM T WHERE DT IS NULL ORDER BY ID"
both      "10 CONTROL S LIKE '2020-01-15'"                "SELECT ID FROM T WHERE S LIKE '2020-01-15' ORDER BY ID"
both      "10 CONTROL N92 LIKE '1.50'  - the narrow numeric's rendered match" "SELECT ID FROM T WHERE N92 LIKE '1.50' ORDER BY ID"
both      "10 CONTROL EXTRACT(YEAR FROM DT) = 2020 - a temporal FUNCTION is not a pattern" "SELECT ID FROM T WHERE EXTRACT(YEAR FROM DT) = 2020 ORDER BY ID"

echo "--- 11. RECORDED, NOT FIXED"
# CONTAINING and SIMILAR TO are the same law and answer it now
# (`serve-real-numpattern.sh`), so these two are promoted
err_same  "11 DT CONTAINING '2020' - the needle converts, and a bare year is no date" "SELECT ID FROM T WHERE DT CONTAINING '2020'"
err_same  "11 DT SIMILAR TO '2%'   - likewise, and a wildcard cannot convert"       "SELECT ID FROM T WHERE DT SIMILAR TO '2%'"
# fire-crab knows the zone NAMES but not the tzdata RULES, so it cannot
# render a value stored in a named zone other than GMT at all - which is
# a boundary of its own, older than this law, and it costs these cells.
# The PATTERN's half of the rule is proved by the GMT cells in §4.
differs   "11 TSZ LIKE '2020-01-15 10:20:30 Europe/Bucharest' - row 4 is stored in a named zone this server cannot convert" \
          "SELECT ID FROM T WHERE TSZ LIKE '2020-01-15 10:20:30 Europe/Bucharest' ORDER BY ID" "4" "(none)"
differs   "11 TSZ LIKE '2020-01-15 10:20:30.0000 europe/bucharest' - and the canonicalised spelling of it" \
          "SELECT ID FROM T WHERE TSZ LIKE '2020-01-15 10:20:30.0000 europe/bucharest' ORDER BY ID" "4" "(none)"

echo "--- 12. THE LAW IS A LITERAL'S, AND A BOUND ? IS NOT ONE"
# Measured against the engine with node-firebird: a `?` pattern is NOT
# converted - it matches the RENDERED value as ordinary text, wildcards
# and all.  That is the mechanism showing through: the conversion is a
# PREPARE-time fold, and a parameter has no value to fold.  These cells
# pin the boundary this chunk must not spread past, and they are the
# same reading that explains why TODAY - which cannot be folded either -
# keeps its raw text in §5.
both      "12 DT LIKE ? ['2%']        - A WILDCARD ANSWERS, where the same text as a LITERAL raises" "SELECT ID FROM T WHERE DT LIKE ? ORDER BY ID" '["2%"]'
both      "12 DT LIKE ? ['2020-01-15'] - the RENDERED text matches" "SELECT ID FROM T WHERE DT LIKE ? ORDER BY ID" '["2020-01-15"]'
both      "12 DT LIKE ? ['2020-1-15']  - ...and a spelling that would CONVERT does not" "SELECT ID FROM T WHERE DT LIKE ? ORDER BY ID" '["2020-1-15"]'
both      "12 TM LIKE ? ['10:20:30']   - nor does a time short of its fraction" "SELECT ID FROM T WHERE TM LIKE ? ORDER BY ID" '["10:20:30"]'
both      "12 TM LIKE ? ['10:20:30.0000'] - which at the full render does match" "SELECT ID FROM T WHERE TM LIKE ? ORDER BY ID" '["10:20:30.0000"]'
# ...and the PREFIX half of that is a boundary, not a law: the
# expression resolver has no `STARTING WITH ?` arm at all (its LIKE twin
# is the one this chunk widened), so a bound prefix over a temporal
# refuses.  Recorded rather than answered - the engine's answers are
# pinned here, so the day the arm exists these two cells say so.
eng_only  "12 DT STARTING WITH ? ['2020'] - a bare year IS a prefix of the render, and this server refuses the shape" "SELECT ID FROM T WHERE DT STARTING WITH ? ORDER BY ID" '["2020"]'
eng_only  "12 DT STARTING WITH ? ['2020-1-15'] - ...and so is the converting spelling's miss" "SELECT ID FROM T WHERE DT STARTING WITH ? ORDER BY ID" '["2020-1-15"]'

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-tmplike-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-tmplike-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

echo "ran $ran checks"
if [ "$ran" -lt 180 ]; then echo "FAIL only $ran checks ran (floor 178) - cells went missing"; fail=1; fi
exit $fail
