#!/bin/bash
# A BOOLEAN IS TEXT TO A PATTERN, AND ITS TEXT IS UPPER CASE.
#
# Wherever the engine needs a boolean as a string - LIKE, STARTING WITH,
# CONTAINING, SIMILAR TO, POSITION, SUBSTRING and the rest of the string
# functions - it converts it the way CVT does, to `TRUE` / `FALSE`:
#
#   B LIKE 'T%'           -> the TRUE rows    B LIKE 'true'        -> (none)
#   B STARTING WITH 'FA'  -> the FALSE rows   B CONTAINING 'ru'    -> TRUE rows
#   B SIMILAR TO '_{5}'   -> the FALSE rows   POSITION('RU' IN B)  -> 2
#
# A boolean does NOT convert its pattern, unlike the INT128, DOUBLE and
# temporal operands of `serve-real-i128like.sh` / `-tmplike.sh`: a
# wildcard answers rather than raising, and the pattern is matched as
# written against the upper-case text.
#
# This server rendered a boolean `true` / `false` (`Value::render`), so
# every LIKE and POSITION/SUBSTRING over one answered WRONG - `B LIKE
# 'T%'` found nothing, `B LIKE 'true'` found the row - while CAST, `||`
# and UPPER/LOWER, which spell the text themselves, were right.  STARTING
# WITH, CONTAINING and SIMILAR TO refused a boolean operand outright.
#
# Usage: qa/serve-real-boollike.sh [port]   (default 4473)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4473}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/boollike-eng.fdb"; FC="$D/boollike-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (ID INTEGER, B BOOLEAN, S VARCHAR(10));
CREATE TABLE U (ID INTEGER, TAG VARCHAR(5));
CREATE TABLE C (ID INTEGER, B BOOLEAN, NB COMPUTED BY (NOT B));
INSERT INTO T VALUES (1, TRUE,  'TRUE');
INSERT INTO T VALUES (2, FALSE, 'FALSE');
INSERT INTO T VALUES (3, NULL,  NULL);
INSERT INTO T VALUES (4, TRUE,  'true');
INSERT INTO U VALUES (1, 'a'); INSERT INTO U VALUES (2, 'b'); INSERT INTO U VALUES (3, 'c');
INSERT INTO C (ID, B) VALUES (1, TRUE); INSERT INTO C (ID, B) VALUES (2, FALSE);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/boollike-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/boollike-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/boollike-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/boollike-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-boollike-$PORT.log" 2>&1 & srv=$!
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

# BOTH describe and the describes DIFFER - both pinned, so the cell fails
# the day either moves.  Recorded, not fixed.
dsc_differs() { # <label> <sql> <engine-describe-substring> <this-server-describe-substring>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ] || [ -z "$fd" ]; then echo "FAIL $1 - a side printed no describe [eng=$ed] [fc=$fd]"; fail=1
    elif [ "${ed#*$3}" = "$ed" ]; then echo "FAIL $1 - the ENGINE describe moved: [$ed]"; fail=1
    elif [ "$ed" = "$fd" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES; promote the cell"; fail=1
    elif [ "${fd#*$4}" = "$fd" ]; then echo "FAIL $1 - this server's describe moved: [$fd]"; fail=1
    else echo "OK   $1 (recorded describe gap: engine [$3], this server [$4])"; fi
}

# A SENTINEL BEFORE ANY CELL: the rows are what every pinned answer reads,
# and B really is a BOOLEAN (sqltype 32764) - a fixture that declared it
# a CHAR would make every LIKE cell agree for the wrong reason.
sent=$(run "$REAL" "$ENG" "SELECT (SELECT COUNT(*) FROM T) A,(SELECT COUNT(*) FROM T WHERE B) B,(SELECT COUNT(*) FROM T WHERE NOT B) C FROM RDB\$DATABASE" '[]')
[ "$sent" = "4,2,1" ] || { echo "FAIL SENTINEL rows [$sent] (want 4,2,1)"; exit 1; }
wid=$(printf 'SET SQLDA_DISPLAY ON;\nSELECT B, NB FROM C;\n' \
      | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' \
      | grep -aoE 'sqltype: [0-9]+' | tr -s ' ' | paste -sd'|')
[ "$wid" = "sqltype: 32764|sqltype: 32764" ] \
  || { echo "FAIL SENTINEL types [$wid] - B and NB are not the BOOLEANs this gate assumes"; exit 1; }
echo "OK   SENTINEL [$sent | $wid]"

echo "--- 1. LIKE MATCHES THE UPPER-CASE TEXT (every cell here was a WRONG ANSWER)"
both_is "1 B LIKE 'T%'        - the TRUE rows"                     "SELECT ID FROM T WHERE B LIKE 'T%' ORDER BY ID" "1;4"
both_is "1 B LIKE 'TRUE'      - the whole text"                    "SELECT ID FROM T WHERE B LIKE 'TRUE' ORDER BY ID" "1;4"
both_is "1 B LIKE 'true'      - LIKE IS CASE-SENSITIVE: nothing"   "SELECT ID FROM T WHERE B LIKE 'true' ORDER BY ID" "(none)"
both_is "1 B LIKE 'false'     - ...and nothing"                    "SELECT ID FROM T WHERE B LIKE 'false' ORDER BY ID" "(none)"
both_is "1 B LIKE '%A%'       - only FALSE carries an A"           "SELECT ID FROM T WHERE B LIKE '%A%' ORDER BY ID" "2"
both_is "1 B LIKE 'F_LSE'"                                         "SELECT ID FROM T WHERE B LIKE 'F_LSE' ORDER BY ID" "2"
both_is "1 B LIKE '____'      - four characters, TRUE"             "SELECT ID FROM T WHERE B LIKE '____' ORDER BY ID" "1;4"
both_is "1 B LIKE '_____'     - five, FALSE"                       "SELECT ID FROM T WHERE B LIKE '_____' ORDER BY ID" "2"
both_is "1 B LIKE '%'         - every non-NULL row, NO CONVERSION RAISE" "SELECT ID FROM T WHERE B LIKE '%' ORDER BY ID" "1;2;4"
both_is "1 B LIKE ''          - the empty pattern"                 "SELECT ID FROM T WHERE B LIKE '' ORDER BY ID" "(none)"
both_is "1 B LIKE 'TRUE '     - no padding on the text"            "SELECT ID FROM T WHERE B LIKE 'TRUE ' ORDER BY ID" "(none)"
both_is "1 B LIKE 'T'         - not a conversion: 'T' is no boolean spelling here" "SELECT ID FROM T WHERE B LIKE 'T' ORDER BY ID" "(none)"
both_is "1 B NOT LIKE 'T%'    - FALSE; NULL stays UNKNOWN"         "SELECT ID FROM T WHERE B NOT LIKE 'T%' ORDER BY ID" "2"
both_is "1 NOT B LIKE 'T%'"                                        "SELECT ID FROM T WHERE NOT B LIKE 'T%' ORDER BY ID" "2"
both_is "1 B NOT LIKE 'true'  - the lower-case text matches no row, so every non-NULL row" "SELECT ID FROM T WHERE B NOT LIKE 'true' ORDER BY ID" "1;2;4"
both_is "1 B LIKE 'T%' ESCAPE '\\'"                                "SELECT ID FROM T WHERE B LIKE 'T%' ESCAPE '\\' ORDER BY ID" "1;4"
both_is "1 B LIKE 'T\\%' ESCAPE '\\' - an escaped % is a literal one" "SELECT ID FROM T WHERE B LIKE 'T\\%' ESCAPE '\\' ORDER BY ID" "(none)"
both_is "1 'TRUE' LIKE B      - the boolean as the PATTERN"        "SELECT ID FROM T WHERE 'TRUE' LIKE B ORDER BY ID" "1;4"
both_is "1 'true' LIKE B      - ...case-sensitive from that side too" "SELECT ID FROM T WHERE 'true' LIKE B ORDER BY ID" "(none)"
both_is "1 S LIKE B           - a text column against the boolean's text" "SELECT ID FROM T WHERE S LIKE B ORDER BY ID" "1;2"
both_is "1 B LIKE S           - ...and the other way: row 4's 'true' is not TRUE" "SELECT ID FROM T WHERE B LIKE S ORDER BY ID" "1;2"
both_is "1 B || '' LIKE 'F%'  - the concatenation already spelled it right" "SELECT ID FROM T WHERE B || '' LIKE 'F%' ORDER BY ID" "2"
both    "1 CONTROL S LIKE 'T%' - a VARCHAR column"                 "SELECT ID FROM T WHERE S LIKE 'T%' ORDER BY ID"
both    "1 CONTROL S LIKE 't%'"                                    "SELECT ID FROM T WHERE S LIKE 't%' ORDER BY ID"

echo "--- 2. STARTING WITH, CONTAINING, SIMILAR TO (every cell here was a REFUSAL)"
both_is "2 B STARTING WITH 'FA'"                                   "SELECT ID FROM T WHERE B STARTING WITH 'FA' ORDER BY ID" "2"
both_is "2 B STARTING WITH 'T'"                                    "SELECT ID FROM T WHERE B STARTING WITH 'T' ORDER BY ID" "1;4"
both_is "2 B STARTING WITH 'TRUE'"                                 "SELECT ID FROM T WHERE B STARTING WITH 'TRUE' ORDER BY ID" "1;4"
both_is "2 B STARTING WITH 'fa'   - case-sensitive"                "SELECT ID FROM T WHERE B STARTING WITH 'fa' ORDER BY ID" "(none)"
both_is "2 B STARTING WITH 'true' - ...and the lower-case text is not a prefix" "SELECT ID FROM T WHERE B STARTING WITH 'true' ORDER BY ID" "(none)"
both_is "2 B STARTING WITH ''     - every non-NULL row"            "SELECT ID FROM T WHERE B STARTING WITH '' ORDER BY ID" "1;2;4"
both_is "2 B STARTING WITH 'TRUE ' - one character too many"       "SELECT ID FROM T WHERE B STARTING WITH 'TRUE ' ORDER BY ID" "(none)"
both_is "2 B STARTING WITH '%'    - no wildcards in a prefix"      "SELECT ID FROM T WHERE B STARTING WITH '%' ORDER BY ID" "(none)"
both_is "2 B NOT STARTING WITH 'T'"                                "SELECT ID FROM T WHERE B NOT STARTING WITH 'T' ORDER BY ID" "2"
both_is "2 B CONTAINING 'ru'      - CONTAINING folds case"         "SELECT ID FROM T WHERE B CONTAINING 'ru' ORDER BY ID" "1;4"
both_is "2 B CONTAINING 'ALS'"                                     "SELECT ID FROM T WHERE B CONTAINING 'ALS' ORDER BY ID" "2"
both_is "2 B CONTAINING 'e'       - both texts end in E"           "SELECT ID FROM T WHERE B CONTAINING 'e' ORDER BY ID" "1;2;4"
both_is "2 B CONTAINING ''        - every non-NULL row"            "SELECT ID FROM T WHERE B CONTAINING '' ORDER BY ID" "1;2;4"
both_is "2 B CONTAINING 'TRUEX'"                                   "SELECT ID FROM T WHERE B CONTAINING 'TRUEX' ORDER BY ID" "(none)"
both_is "2 B CONTAINING '%'       - the wildcard is a literal character here" "SELECT ID FROM T WHERE B CONTAINING '%' ORDER BY ID" "(none)"
both_is "2 B NOT CONTAINING 'U'   - FALSE has no U"                "SELECT ID FROM T WHERE B NOT CONTAINING 'U' ORDER BY ID" "2"
both_is "2 B SIMILAR TO 'T%'"                                      "SELECT ID FROM T WHERE B SIMILAR TO 'T%' ORDER BY ID" "1;4"
both_is "2 B SIMILAR TO '(TRUE|X)'"                                "SELECT ID FROM T WHERE B SIMILAR TO '(TRUE|X)' ORDER BY ID" "1;4"
both_is "2 B SIMILAR TO 'true'    - case-sensitive"                "SELECT ID FROM T WHERE B SIMILAR TO 'true' ORDER BY ID" "(none)"
both_is "2 B SIMILAR TO '[A-Z]{4}'"                                "SELECT ID FROM T WHERE B SIMILAR TO '[A-Z]{4}' ORDER BY ID" "1;4"
both_is "2 B SIMILAR TO '_{5}'"                                    "SELECT ID FROM T WHERE B SIMILAR TO '_{5}' ORDER BY ID" "2"
both_is "2 B SIMILAR TO '%L%'"                                     "SELECT ID FROM T WHERE B SIMILAR TO '%L%' ORDER BY ID" "2"
both_is "2 B NOT SIMILAR TO 'F%'"                                  "SELECT ID FROM T WHERE B NOT SIMILAR TO 'F%' ORDER BY ID" "1;4"

echo "--- 3. THE SAME LAW INSIDE AN EXPRESSION (the IIF/CASE router)"
both    "3 IIF over the four predicates" \
        "SELECT ID, IIF(B LIKE 'T%', 1, 0), IIF(B STARTING WITH 'F', 1, 0), IIF(B CONTAINING 'als', 1, 0), IIF(B SIMILAR TO '(TRUE|X)', 1, 0) FROM T ORDER BY ID"
both_is "3 IIF(B LIKE 'T%') - pinned" "SELECT ID, IIF(B LIKE 'T%', 1, 0) FROM T ORDER BY ID" "1,1;2,0;3,0;4,1"
both_is "3 IIF(B CONTAINING 'ru') - pinned (this arm refused a boolean)" "SELECT ID, IIF(B CONTAINING 'ru', 1, 0) FROM T ORDER BY ID" "1,1;2,0;3,0;4,1"
both_is "3 CASE WHEN B NOT LIKE 'F%'" "SELECT ID, CASE WHEN B NOT LIKE 'F%' THEN 1 ELSE 0 END FROM T ORDER BY ID" "1,1;2,0;3,0;4,1"
both_is "3 SUM(IIF(B STARTING WITH 'T'))" "SELECT SUM(IIF(B STARTING WITH 'T', 1, 0)) FROM T" "2"
both_is "3 SUM(IIF(B SIMILAR TO '_{5}'))" "SELECT SUM(IIF(B SIMILAR TO '_{5}', 1, 0)) FROM T" "1"

echo "--- 4. A BOOLEAN-TYPED EXPRESSION, A COMPUTED COLUMN, A JOIN"
both_is "4 COALESCE(B, FALSE) STARTING WITH 'F' - the NULL row renders FALSE" "SELECT ID FROM T WHERE COALESCE(B, FALSE) STARTING WITH 'F' ORDER BY ID" "2;3"
both_is "4 NULLIF(B, TRUE) CONTAINING 'a'"     "SELECT ID FROM T WHERE NULLIF(B, TRUE) CONTAINING 'a' ORDER BY ID" "2"
both_is "4 COALESCE(B, FALSE) LIKE 'F%'"       "SELECT ID FROM T WHERE COALESCE(B, FALSE) LIKE 'F%' ORDER BY ID" "2;3"
both_is "4 NB LIKE 'F%'     - a COMPUTED BY (NOT B) column" "SELECT ID FROM C WHERE NB LIKE 'F%' ORDER BY ID" "1"
both_is "4 NB STARTING WITH 'T'"               "SELECT ID FROM C WHERE NB STARTING WITH 'T' ORDER BY ID" "2"
both_is "4 NB SIMILAR TO 'TRUE'"               "SELECT ID FROM C WHERE NB SIMILAR TO 'TRUE' ORDER BY ID" "2"
both_is "4 a JOIN: T.B LIKE 'T%' AND T.ID = U.ID" "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.B LIKE 'T%' ORDER BY U.TAG" "a"
both_is "4 a JOIN: T.B CONTAINING 'L'"         "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.B CONTAINING 'L' ORDER BY U.TAG" "b"
both_is "4 a derived table"                    "SELECT X.ID FROM (SELECT ID, B FROM T) X WHERE X.B STARTING WITH 'T' ORDER BY X.ID" "1;4"

echo "--- 5. THE STRING FUNCTIONS SEE THE SAME TEXT"
both_is "5 POSITION('RU' IN B) - was 0" "SELECT ID, POSITION('RU' IN B) FROM T ORDER BY ID" "1,2;2,0;3,NULL;4,2"
both_is "5 POSITION('E', B, 3)"         "SELECT ID, POSITION('E', B, 3) FROM T ORDER BY ID" "1,4;2,5;3,NULL;4,4"
both_is "5 SUBSTRING(B FROM 1 FOR 2) - was tr/fa" "SELECT ID, SUBSTRING(B FROM 1 FOR 2) FROM T ORDER BY ID" "1,TR;2,FA;3,NULL;4,TR"
both_is "5 SUBSTRING(B FROM 2)"         "SELECT ID, SUBSTRING(B FROM 2) FROM T ORDER BY ID" "1,RUE;2,ALSE;3,NULL;4,RUE"
both_is "5 LEFT / RIGHT"                "SELECT ID, LEFT(B, 2), RIGHT(B, 2) FROM T ORDER BY ID" "1,TR,UE;2,FA,SE;3,NULL,NULL;4,TR,UE"
both_is "5 REVERSE"                     "SELECT ID, REVERSE(B) FROM T ORDER BY ID" "1,EURT;2,ESLAF;3,NULL;4,EURT"
both_is "5 REPLACE(B, 'U', 'x')"        "SELECT ID, REPLACE(B, 'U', 'x') FROM T ORDER BY ID" "1,TRxE;2,FALSE;3,NULL;4,TRxE"
both_is "5 LPAD / RPAD"                 "SELECT ID, LPAD(B, 6, '*'), RPAD(B, 6, '*') FROM T ORDER BY ID" "1,**TRUE,TRUE**;2,*FALSE,FALSE*;3,NULL,NULL;4,**TRUE,TRUE**"
both_is "5 TRIM"                        "SELECT ID, TRIM(B) FROM T ORDER BY ID" "1,TRUE;2,FALSE;3,NULL;4,TRUE"
both_is "5 CHAR_LENGTH / OCTET_LENGTH"  "SELECT ID, CHAR_LENGTH(B), OCTET_LENGTH(B) FROM T ORDER BY ID" "1,4,4;2,5,5;3,NULL,NULL;4,4,4"
both_is "5 CONTROL UPPER / LOWER"       "SELECT ID, UPPER(B), LOWER(B) FROM T ORDER BY ID" "1,TRUE,true;2,FALSE,false;3,NULL,NULL;4,TRUE,true"
both_is "5 CONTROL CAST AS VARCHAR"     "SELECT ID, CAST(B AS VARCHAR(10)) FROM T ORDER BY ID" "1,TRUE;2,FALSE;3,NULL;4,TRUE"
both_is "5 CONTROL B || B"              "SELECT ID, B || B FROM T ORDER BY ID" "1,TRUETRUE;2,FALSEFALSE;3,NULL;4,TRUETRUE"
both    "5 describe: POSITION"           "SELECT POSITION('RU' IN B) FROM T ORDER BY ID"
# THE VALUES AGREE AND THE ANNOUNCEMENT DOES NOT: the engine types a
# boolean's text as five characters (FALSE), this server as the 32765 it
# gives an operand it cannot size.  Recorded, both sides pinned.
dsc_differs "5 describe: SUBSTRING(B FROM 1 FOR 2)" "SELECT SUBSTRING(B FROM 1 FOR 2) FROM T" \
    "len: 2 charset: 2 SYSTEM.ASCII" "len: 32765 charset: 0 SYSTEM.NONE"
dsc_differs "5 describe: LEFT(B, 2)"   "SELECT LEFT(B, 2) FROM T" \
    "len: 5 charset: 0 SYSTEM.NONE" "len: 32765 charset: 0 SYSTEM.NONE"
dsc_differs "5 describe: REVERSE(B)"   "SELECT REVERSE(B) FROM T" \
    "len: 5 charset: 0 SYSTEM.NONE" "len: 32765 charset: 0 SYSTEM.NONE"
dsc_differs "5 describe: REPLACE(B, 'U', 'x')" "SELECT REPLACE(B, 'U', 'x') FROM T" \
    "len: 5 charset: 0 SYSTEM.NONE" "len: 32765 charset: 0 SYSTEM.NONE"

echo "--- 6. A BOUND PATTERN: the engine matches the same text, this server refuses the shape"
eng_only "6 B LIKE ? ['T%']"            "SELECT ID FROM T WHERE B LIKE ? ORDER BY ID" '["T%"]'
eng_only "6 B LIKE ? ['true']"          "SELECT ID FROM T WHERE B LIKE ? ORDER BY ID" '["true"]'
eng_only "6 B LIKE ? ['F_LSE']"         "SELECT ID FROM T WHERE B LIKE ? ORDER BY ID" '["F_LSE"]'

echo "--- 7. RECORDED BOUNDARIES (the engine answers or raises, this server refuses)"
eng_only    "7 (B OR FALSE) LIKE 'T%'   - a boolean-valued PREDICATE as the operand" "SELECT ID FROM T WHERE (B OR FALSE) LIKE 'T%' ORDER BY ID"
eng_only    "7 (ID = 1) LIKE 'T%'"                                                  "SELECT ID FROM T WHERE (ID = 1) LIKE 'T%' ORDER BY ID"
eng_only    "7 HASH(B)"                                                             "SELECT ID, HASH(B) FROM T ORDER BY ID"
both_is     "7 CONTROL CAST(B AS CHAR(5)) - padded, as the engine pads" "SELECT ID, CAST(B AS CHAR(5)) || '|' FROM T ORDER BY ID" "1,TRUE |;2,FALSE|;3,NULL;4,TRUE |"
both_is     "7 CONTROL CHAR_LENGTH(CAST(B AS CHAR(6)))" "SELECT ID, CHAR_LENGTH(CAST(B AS CHAR(6))) FROM T ORDER BY ID" "1,6;2,6;3,NULL;4,6"
eng_only    "7 OVERLAY(B PLACING 'xx' FROM 2) - OVERLAY is not converted"           "SELECT ID, OVERLAY(B PLACING 'xx' FROM 2) FROM T ORDER BY ID"
err_differs "7 B = 'T'   - the engine's per-row 22018, this server's prepare refusal" "SELECT ID FROM T WHERE B = 'T'" 'conversion error from string "T"' '42000'
err_differs "7 B = 'yes'"                                                            "SELECT ID FROM T WHERE B = 'yes'" 'conversion error from string "yes"' '42000'
both_is     "7 CONTROL B = 'true' - a boolean SPELLING converts, any case, and answers" "SELECT ID FROM T WHERE B = 'true' ORDER BY ID" "1;4"
both_is     "7 CONTROL B = ' false '"                                               "SELECT ID FROM T WHERE B = ' false ' ORDER BY ID" "2"

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-boollike-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-boollike-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

echo "ran $ran checks"
if [ "$ran" -lt 93 ]; then echo "FAIL only $ran checks ran (floor 93) - cells went missing"; fail=1; fi
exit $fail
