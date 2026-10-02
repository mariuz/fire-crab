#!/bin/bash
# EVERY NON-TEXT OPERAND IS RENDERED TEXT FOR EVERY PATTERN OPERATOR -
# AND A BOUND PATTERN IS NEVER CONVERTED.
#
# The two halves belong together because the SAME TEXT gives DIFFERENT
# ANSWERS depending only on whether it was written or bound:
#
#   DP CONTAINING '.5'  -> (none)   DP CONTAINING ? ['.5']  -> 1;3
#   DT CONTAINING '2020'-> RAISES   DT CONTAINING ? ['2020']-> 1
#   DP LIKE '1.5'       -> (none)   DP LIKE ? ['1%']        -> 1;2
#
# A LITERAL pattern converts at PREPARE by the law the four chunks
# before this one built (`serve-real-i128like.sh`, `dfnflit`, `tmplike`);
# a BOUND one cannot, because the conversion is a prepare-time fold and
# a parameter has no value to fold.  So a bound pattern matches the
# RENDERED value with its wildcards live, in every family, and its slot
# is announced `VARYING len 30 charset NONE` for every non-text operand
# (measured across all eight).
#
# The second half is the TYPE side of the same square: LIKE, STARTING
# WITH, CONTAINING and SIMILAR TO over SMALLINT/INTEGER/BIGINT, every
# NUMERIC width, INT128, FLOAT, DOUBLE, DECFLOAT(16|34), the temporals
# and BOOLEAN.  What this server refused, the engine answers; what it
# answered wrongly, it now converts.  Two silent WRONG ANSWERS were
# closed here:
#
#   * a BOOLEAN rendered "true" where the engine renders "TRUE", so
#     `B LIKE 'T%'` found NOTHING (§5);
#   * a DECFLOAT operand reached no conversion at all through the
#     EXPRESSION routers - it has no ExprType to key on - so
#     `SUM(IIF(D34 LIKE '1%',1,0))` answered 3 where the engine raises
#     and `STARTING WITH '01'` answered 0 where the engine answers 3 (§8).
#
# Usage: qa/serve-real-patternfam.sh [port]   (default 4474)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4474}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/patternfam-eng.fdb"; FC="$D/patternfam-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (
  ID INTEGER,
  SM SMALLINT, IN4 INTEGER, BI BIGINT,
  N92 NUMERIC(9,2), N184 NUMERIC(18,4), N382 NUMERIC(38,2), I128 INT128,
  FL FLOAT, DP DOUBLE PRECISION, D16 DECFLOAT(16), D34 DECFLOAT(34),
  DT DATE, TS TIMESTAMP, TM TIME,
  C CHAR(6), V VARCHAR(20), B BOOLEAN);
CREATE TABLE U (ID INTEGER, TAG VARCHAR(5));
COMMIT;
INSERT INTO T VALUES (1, 1, 1, 1, 1.50, 1.5000, 1.50, 1, 1.5, 1.5, 1.5, 1.5,
                      '2020-01-15','2020-01-15 10:20:30','10:20:30','1.50','1.50', TRUE);
INSERT INTO T VALUES (2, 10, 10, 10, 10.00, 10.0000, 10.00, 10, 100.0, 100.0, 10, 10,
                      '2021-02-05','2021-02-05 01:02:03','01:02:03','10.00','10.00', FALSE);
INSERT INTO T VALUES (3, 100, 100, 100, 100.50, 100.5000, 100.50, 100, -2.5, -2.5, 100.50, 100.50,
                      '1999-12-31','1999-12-31 23:59:59','23:59:59','100.50','100.50', NULL);
INSERT INTO U VALUES (1,'a'); INSERT INTO U VALUES (2,'b'); INSERT INTO U VALUES (3,'c');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/patternfam-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/patternfam-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/patternfam-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/patternfam-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-patternfam-$PORT.log" 2>&1 & srv=$!
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
    | tr -d '\r' | grep -aiE 'SQLSTATE|conversion error|Invalid time zone|Invalid SIMILAR' | sed 's/^ *//;s/  */ /g' | paste -sd'|'; }

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

# A SENTINEL BEFORE ANY CELL: this gate is a TYPE SQUARE, so it proves
# the eight storage types really are eight - a fixture that quietly
# declared DP as a FLOAT or D34 as a NUMERIC would make half of §6 and
# §7 agree for the wrong reason - and it proves the three rows are there.
sent=$(run "$REAL" "$ENG" "SELECT (SELECT COUNT(*) FROM T) A,(SELECT COUNT(*) FROM U) B FROM RDB\$DATABASE" '[]')
[ "$sent" = "3,3" ] || { echo "FAIL SENTINEL rows [$sent] (want 3,3)"; exit 1; }
wid=$(printf 'SET SQLDA_DISPLAY ON;\nSELECT SM, N92, N382, I128, FL, DP, D16, D34, DT, B FROM T;\n' \
      | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' \
      | grep -aoE 'sqltype: [0-9]+' | tr -s ' ' | paste -sd'|')
want="sqltype: 500|sqltype: 496|sqltype: 32752|sqltype: 32752|sqltype: 482|sqltype: 480|sqltype: 32760|sqltype: 32762|sqltype: 570|sqltype: 32764"
[ "$wid" = "$want" ] || { echo "FAIL SENTINEL types [$wid]"; echo "                want [$want]"; exit 1; }
echo "OK   SENTINEL [$sent | $wid]"

echo "--- 1. THE SAME TEXT, WRITTEN AND BOUND, IS TWO DIFFERENT PATTERNS"
# The chunk in four pairs: on a CONVERTING operand the literal converts
# at prepare and the bound one cannot, so they answer differently - and
# on a NON-converting one they agree, which is what makes the pairs
# proof rather than illustration.
both      "1 DP CONTAINING '.5'   - the literal converts to \"0.500000000000000\"" "SELECT ID FROM T WHERE DP CONTAINING '.5' ORDER BY ID"
both      "1 DP CONTAINING ? ['.5'] - ...and the BOUND needle is raw text" "SELECT ID FROM T WHERE DP CONTAINING ? ORDER BY ID" '[".5"]'
err_same  "1 DT CONTAINING '2020'  - the literal converts and a date it is not" "SELECT ID FROM T WHERE DT CONTAINING '2020'"
both      "1 DT CONTAINING ? ['2020'] - ...and the BOUND needle answers the row" "SELECT ID FROM T WHERE DT CONTAINING ? ORDER BY ID" '["2020"]'
err_same  "1 N382 LIKE '1%'        - a wildcard cannot convert"  "SELECT ID FROM T WHERE N382 LIKE '1%'"
both      "1 N382 LIKE ? ['1%']    - ...and bound it is an ordinary wildcard" "SELECT ID FROM T WHERE N382 LIKE ? ORDER BY ID" '["1%"]'
both      "1 N382 LIKE '01'        - the literal converts to \"1\", which no render is" "SELECT ID FROM T WHERE N382 LIKE '01' ORDER BY ID"
both      "1 N382 LIKE ? ['01']    - ...and bound it matches no rendered text either" "SELECT ID FROM T WHERE N382 LIKE ? ORDER BY ID" '["01"]'
both      "1 FL CONTAINING '.5'   - a NON-converting operand answers the SAME either way" "SELECT ID FROM T WHERE FL CONTAINING '.5' ORDER BY ID"
both      "1 FL CONTAINING ? ['.5'] - ...which is what makes the pairs above proof" "SELECT ID FROM T WHERE FL CONTAINING ? ORDER BY ID" '[".5"]'
both      "1 CONTROL V LIKE '1%'   - and so does a VARCHAR"     "SELECT ID FROM T WHERE V LIKE '1%' ORDER BY ID"
both      "1 CONTROL V LIKE ? ['1%']" "SELECT ID FROM T WHERE V LIKE ? ORDER BY ID" '["1%"]'

echo "--- 2. A BOUND LIKE OVER EVERY FAMILY - and the slot is the same everywhere"
both      "2 SM LIKE ? ['1%']"    "SELECT ID FROM T WHERE SM LIKE ? ORDER BY ID" '["1%"]'
both      "2 BI LIKE ? ['1%']"    "SELECT ID FROM T WHERE BI LIKE ? ORDER BY ID" '["1%"]'
both      "2 N92 LIKE ? ['1%']"   "SELECT ID FROM T WHERE N92 LIKE ? ORDER BY ID" '["1%"]'
both      "2 I128 LIKE ? ['1%']"  "SELECT ID FROM T WHERE I128 LIKE ? ORDER BY ID" '["1%"]'
both      "2 FL LIKE ? ['1%']     - FLOAT, which the LITERAL law leaves alone" "SELECT ID FROM T WHERE FL LIKE ? ORDER BY ID" '["1%"]'
both      "2 DP LIKE ? ['1%']     - DOUBLE, which it does not"  "SELECT ID FROM T WHERE DP LIKE ? ORDER BY ID" '["1%"]'
both      "2 DP LIKE ? ['1.5']    - and the bound text is the RENDER's, not the value's" "SELECT ID FROM T WHERE DP LIKE ? ORDER BY ID" '["1.5"]'
both      "2 DP LIKE ? ['1.500000000000000'] - ...which at fifteen decimals it is" "SELECT ID FROM T WHERE DP LIKE ? ORDER BY ID" '["1.500000000000000"]'
both      "2 D16 LIKE ? ['1%']"   "SELECT ID FROM T WHERE D16 LIKE ? ORDER BY ID" '["1%"]'
both      "2 D34 LIKE ? ['1.5']   - a DECFLOAT renders its own short form" "SELECT ID FROM T WHERE D34 LIKE ? ORDER BY ID" '["1.5"]'
both      "2 DT LIKE ? ['2%']"    "SELECT ID FROM T WHERE DT LIKE ? ORDER BY ID" '["2%"]'
both      "2 TS LIKE ? ['2020-01-15%']" "SELECT ID FROM T WHERE TS LIKE ? ORDER BY ID" '["2020-01-15%"]'
both      "2 TM LIKE ? ['10:20:30.0000'] - the FULL render, fraction and all" "SELECT ID FROM T WHERE TM LIKE ? ORDER BY ID" '["10:20:30.0000"]'
both      "2 TM LIKE ? ['10:20:30'] - ...and one decimal short matches nothing" "SELECT ID FROM T WHERE TM LIKE ? ORDER BY ID" '["10:20:30"]'
both      "2 C LIKE ? ['1%']      - a CHAR side keeps its OWN width"  "SELECT ID FROM T WHERE C LIKE ? ORDER BY ID" '["1%"]'
both      "2 N382 NOT LIKE ? ['1%'] - negation"          "SELECT ID FROM T WHERE N382 NOT LIKE ? ORDER BY ID" '["1%"]'
both      "2 N382 LIKE ? [NULL]   - a NULL bind is UNKNOWN" "SELECT ID FROM T WHERE N382 LIKE ? ORDER BY ID" '[null]'
both      "2 N382 LIKE ? ['']     - and an empty one matches no render" "SELECT ID FROM T WHERE N382 LIKE ? ORDER BY ID" '[""]'

echo "--- 3. STARTING WITH ? - an arm that did not exist at all"
both      "3 DP STARTING WITH ? ['1']"  "SELECT ID FROM T WHERE DP STARTING WITH ? ORDER BY ID" '["1"]'
both      "3 FL STARTING WITH ? ['1']"  "SELECT ID FROM T WHERE FL STARTING WITH ? ORDER BY ID" '["1"]'
both      "3 DT STARTING WITH ? ['2020'] - A BARE YEAR IS A PREFIX HERE, where the LITERAL form raises" "SELECT ID FROM T WHERE DT STARTING WITH ? ORDER BY ID" '["2020"]'
err_same  "3 DT STARTING WITH '2020'  - ...the literal twin, for the contrast" "SELECT ID FROM T WHERE DT STARTING WITH '2020'"
both      "3 TS STARTING WITH ? ['2020-01-15']" "SELECT ID FROM T WHERE TS STARTING WITH ? ORDER BY ID" '["2020-01-15"]'
both      "3 TM STARTING WITH ? ['10:20']"      "SELECT ID FROM T WHERE TM STARTING WITH ? ORDER BY ID" '["10:20"]'
both      "3 B STARTING WITH ? ['F']"           "SELECT ID FROM T WHERE B STARTING WITH ? ORDER BY ID" '["F"]'
both      "3 N382 STARTING WITH ? ['1']"        "SELECT ID FROM T WHERE N382 STARTING WITH ? ORDER BY ID" '["1"]'
both      "3 D34 STARTING WITH ? ['10']"        "SELECT ID FROM T WHERE D34 STARTING WITH ? ORDER BY ID" '["10"]'
both      "3 SM STARTING WITH ? ['1']"          "SELECT ID FROM T WHERE SM STARTING WITH ? ORDER BY ID" '["1"]'
both      "3 B NOT STARTING WITH ? ['T']"       "SELECT ID FROM T WHERE B NOT STARTING WITH ? ORDER BY ID" '["T"]'
both      "3 CONTROL V STARTING WITH ? ['1']"   "SELECT ID FROM T WHERE V STARTING WITH ? ORDER BY ID" '["1"]'

echo "--- 4. A BOUND CONTAINING, the third operator with the same law"
both      "4 N382 CONTAINING ? ['.5']"  "SELECT ID FROM T WHERE N382 CONTAINING ? ORDER BY ID" '[".5"]'
both      "4 D34 CONTAINING ? ['0']"    "SELECT ID FROM T WHERE D34 CONTAINING ? ORDER BY ID" '["0"]'
both      "4 FL CONTAINING ? ['.5']"    "SELECT ID FROM T WHERE FL CONTAINING ? ORDER BY ID" '[".5"]'
both      "4 B CONTAINING ? ['ru']      - and the substring test folds case" "SELECT ID FROM T WHERE B CONTAINING ? ORDER BY ID" '["ru"]'
both      "4 SM CONTAINING ? ['1']"     "SELECT ID FROM T WHERE SM CONTAINING ? ORDER BY ID" '["1"]'
both      "4 CONTROL V CONTAINING ? ['.5']" "SELECT ID FROM T WHERE V CONTAINING ? ORDER BY ID" '[".5"]'

echo "--- 5. A BOOLEAN IS RENDERED TEXT - and this server rendered it in lower case"
both      "5 B LIKE 'T%'        - THE SILENT WRONG ANSWER: nothing, where the engine takes TRUE" "SELECT ID FROM T WHERE B LIKE 'T%' ORDER BY ID"
both      "5 B LIKE 'TRUE'"                   "SELECT ID FROM T WHERE B LIKE 'TRUE' ORDER BY ID"
both      "5 B LIKE 'TR_E'      - wildcards live: a BOOLEAN converts nothing" "SELECT ID FROM T WHERE B LIKE 'TR_E' ORDER BY ID"
both      "5 B LIKE 'true'      - ...and the match is CASE-SENSITIVE" "SELECT ID FROM T WHERE B LIKE 'true' ORDER BY ID"
both      "5 B LIKE ? ['F%']"                 "SELECT ID FROM T WHERE B LIKE ? ORDER BY ID" '["F%"]'
both      "5 B STARTING WITH 'T'"             "SELECT ID FROM T WHERE B STARTING WITH 'T' ORDER BY ID"
both      "5 B STARTING WITH 't'   - case-sensitive here too"  "SELECT ID FROM T WHERE B STARTING WITH 't' ORDER BY ID"
both      "5 B STARTING WITH 'TRUEX'"         "SELECT ID FROM T WHERE B STARTING WITH 'TRUEX' ORDER BY ID"
both      "5 B CONTAINING 'RU'"               "SELECT ID FROM T WHERE B CONTAINING 'RU' ORDER BY ID"
both      "5 B CONTAINING 'ru'     - CONTAINING folds case, so the needle may be lower" "SELECT ID FROM T WHERE B CONTAINING 'ru' ORDER BY ID"
both      "5 B CONTAINING 'ALS'    - the FALSE row"  "SELECT ID FROM T WHERE B CONTAINING 'ALS' ORDER BY ID"
both      "5 B CONTAINING 'x'"                "SELECT ID FROM T WHERE B CONTAINING 'x' ORDER BY ID"
both      "5 B SIMILAR TO 'T%'"               "SELECT ID FROM T WHERE B SIMILAR TO 'T%' ORDER BY ID"
both      "5 B SIMILAR TO '[TF]%'  - and the SIMILAR grammar is its own" "SELECT ID FROM T WHERE B SIMILAR TO '[TF]%' ORDER BY ID"
both      "5 B SIMILAR TO 'true'   - case-sensitive, unlike CONTAINING" "SELECT ID FROM T WHERE B SIMILAR TO 'true' ORDER BY ID"
both      "5 B NOT LIKE 'T%'       - the NULL row is UNKNOWN under both polarities" "SELECT ID FROM T WHERE B NOT LIKE 'T%' ORDER BY ID"
both      "5 CONTROL CAST(B AS VARCHAR(5)) LIKE 'T%' - the CAST said TRUE all along" "SELECT ID FROM T WHERE CAST(B AS VARCHAR(5)) LIKE 'T%' ORDER BY ID"
both      "5 CONTROL B = 'TRUE'    - and so did the comparison"  "SELECT ID FROM T WHERE B = 'TRUE' ORDER BY ID"

echo "--- 6. CONTAINING OVER EVERY FAMILY: it converts for exactly the LIKE set"
both      "6 N92 CONTAINING '.5'   - NARROW: the raw needle" "SELECT ID FROM T WHERE N92 CONTAINING '.5' ORDER BY ID"
both      "6 N382 CONTAINING '.5'  - WIDE: converted to \"0.50\"" "SELECT ID FROM T WHERE N382 CONTAINING '.5' ORDER BY ID"
both      "6 D16 CONTAINING '.5'   - THE DISCRIMINATING CELL: 3 alone, where the raw needle would take 1 as well" "SELECT ID FROM T WHERE D16 CONTAINING '.5' ORDER BY ID"
both      "6 D34 CONTAINING '0'"                  "SELECT ID FROM T WHERE D34 CONTAINING '0' ORDER BY ID"
both      "6 I128 CONTAINING '0'"                 "SELECT ID FROM T WHERE I128 CONTAINING '0' ORDER BY ID"
both      "6 FL CONTAINING '.5'    - FLOAT does not convert" "SELECT ID FROM T WHERE FL CONTAINING '.5' ORDER BY ID"
both      "6 DP CONTAINING '.5'    - ...and DOUBLE does"     "SELECT ID FROM T WHERE DP CONTAINING '.5' ORDER BY ID"
both      "6 SM CONTAINING '1'"                   "SELECT ID FROM T WHERE SM CONTAINING '1' ORDER BY ID"
both      "6 DT CONTAINING '2020-01-15' - a TEMPORAL converts and then matches" "SELECT ID FROM T WHERE DT CONTAINING '2020-01-15' ORDER BY ID"
both      "6 DT CONTAINING '15.01.2020' - ...through the whole date grammar" "SELECT ID FROM T WHERE DT CONTAINING '15.01.2020' ORDER BY ID"
err_same  "6 TM CONTAINING '20'    - and what cannot convert raises" "SELECT ID FROM T WHERE TM CONTAINING '20'"
both      "6 N382 CONTAINING '1.50'"              "SELECT ID FROM T WHERE N382 CONTAINING '1.50' ORDER BY ID"
both      "6 CONTROL V CONTAINING '.5'"           "SELECT ID FROM T WHERE V CONTAINING '.5' ORDER BY ID"

echo "--- 7. SIMILAR TO OVER EVERY FAMILY: the same conversion set again"
both      "7 SM SIMILAR TO '1%'"                  "SELECT ID FROM T WHERE SM SIMILAR TO '1%' ORDER BY ID"
both      "7 N92 SIMILAR TO '1%'   - narrow, so the pattern stands" "SELECT ID FROM T WHERE N92 SIMILAR TO '1%' ORDER BY ID"
err_same  "7 N382 SIMILAR TO '1%'  - wide, so a wildcard cannot convert" "SELECT ID FROM T WHERE N382 SIMILAR TO '1%'"
both      "7 N382 SIMILAR TO '1.50' - ...and a convertible pattern answers through the render" "SELECT ID FROM T WHERE N382 SIMILAR TO '1.50' ORDER BY ID"
err_same  "7 I128 SIMILAR TO '1%'"                "SELECT ID FROM T WHERE I128 SIMILAR TO '1%'"
err_same  "7 DP SIMILAR TO '1%'"                  "SELECT ID FROM T WHERE DP SIMILAR TO '1%'"
both      "7 FL SIMILAR TO '1%'    - FLOAT, again the exception"  "SELECT ID FROM T WHERE FL SIMILAR TO '1%' ORDER BY ID"
err_same  "7 D34 SIMILAR TO '1%'"                 "SELECT ID FROM T WHERE D34 SIMILAR TO '1%'"
both      "7 D34 SIMILAR TO '1.5'"                "SELECT ID FROM T WHERE D34 SIMILAR TO '1.5' ORDER BY ID"
both      "7 CONTROL V SIMILAR TO '1%'"           "SELECT ID FROM T WHERE V SIMILAR TO '1%' ORDER BY ID"

echo "--- 8. THE DECFLOAT EXPRESSION ROUTER - two silent wrong answers"
err_same  "8 SUM(IIF(D34 LIKE '1%',..)) - a PROJECTION, which answered 3" "SELECT SUM(IIF(D34 LIKE '1%',1,0)) A FROM T"
both      "8 SUM(IIF(D34 STARTING WITH '01',..)) - ...and this answered 0 where the engine answers 3" "SELECT SUM(IIF(D34 STARTING WITH '01',1,0)) A FROM T"
err_same  "8 JOIN + WHERE T.D34 LIKE '1%'" "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.D34 LIKE '1%'"
both      "8 JOIN + WHERE T.D34 LIKE '1.5'" "SELECT T.ID FROM T JOIN U ON T.ID = U.ID WHERE T.D34 LIKE '1.5' ORDER BY T.ID"
# A DECFLOAT ARITHMETIC TREE AND A DECFLOAT CAST ARE NOT COLUMNS, and
# the conversion reaches a column's descriptor and nothing else - so
# these two keep REFUSING rather than answering by a width nobody
# measured.  Admitting them to the type check without a conversion is
# exactly how this chunk's first draft turned them into wrong answers.
err_differs "8 WHERE D34 + 0 LIKE '1%'  - an arithmetic DECFLOAT operand refuses the shape" \
            "SELECT ID FROM T WHERE D34 + 0 LIKE '1%'" "22018" "42000"
err_differs "8 WHERE CAST(N92 AS DECFLOAT(34)) LIKE '1%' - and so does a CAST" \
            "SELECT ID FROM T WHERE CAST(N92 AS DECFLOAT(34)) LIKE '1%'" "22018" "42000"
both      "8 CONTROL SUM(IIF(D34 LIKE '1.5',..)) - a converting pattern through the same router" "SELECT SUM(IIF(D34 LIKE '1.5',1,0)) A FROM T"

echo "--- 9. MUST NOT TOUCH"
both      "9 V LIKE '1%'"                         "SELECT ID FROM T WHERE V LIKE '1%' ORDER BY ID"
both      "9 C LIKE '1%'   - a CHAR column pads, and the pattern still matches" "SELECT ID FROM T WHERE C LIKE '1%' ORDER BY ID"
both      "9 V LIKE ? ESCAPE '!' ['1!%'] - a LITERAL escape with a bound pattern" "SELECT ID FROM T WHERE V LIKE ? ESCAPE '!' ORDER BY ID" '["1!%"]'
both      "9 N92 = '1.50'"                        "SELECT ID FROM T WHERE N92 = '1.50' ORDER BY ID"
both      "9 DP > 1"                              "SELECT ID FROM T WHERE DP > 1 ORDER BY ID"
both      "9 D34 = 1.5"                           "SELECT ID FROM T WHERE D34 = 1.5 ORDER BY ID"
both      "9 DT = '2020-1-15'"                    "SELECT ID FROM T WHERE DT = '2020-1-15' ORDER BY ID"
both      "9 B IS TRUE"                           "SELECT ID FROM T WHERE B IS TRUE ORDER BY ID"
both      "9 UPPER(V) LIKE ? ['1%'] - a TEXT EXPRESSION's bound pattern" "SELECT ID FROM T WHERE UPPER(V) LIKE ? ORDER BY ID" '["1%"]'
both      "9 N382 + 0 LIKE ? ['1%'] - and a numeric expression's"  "SELECT ID FROM T WHERE N382 + 0 LIKE ? ORDER BY ID" '["1%"]'
both      "9 CAST(DT AS TIMESTAMP) LIKE ? ['2020%']"  "SELECT ID FROM T WHERE CAST(DT AS TIMESTAMP) LIKE ? ORDER BY ID" '["2020%"]'

echo "--- 10. RECORDED, NOT FIXED"
# A BOUND PATTERN INSIDE AN EXPRESSION CONDITION was recorded here as a
# missing parameter sink; the five IIF / CASE cells SELF-EXPIRED on
# 2026-10-02 when the condition resolver's sink learned the bare-`?`
# pattern (`serve-real-condpattern.sh`, 181 cells) and were promoted.
# A subquery's WHERE over a non-text operand is a different router and
# still refuses.
both      "10 IIF(V LIKE ?,..) - a bound pattern inside an expression condition" "SELECT ID FROM T WHERE IIF(V LIKE ?,1,0) = 1 ORDER BY ID" '["1%"]'
both      "10 CASE WHEN V LIKE ? .." "SELECT ID FROM T WHERE CASE WHEN V LIKE ? THEN 1 ELSE 0 END = 1 ORDER BY ID" '["1%"]'
both      "10 IIF(DP LIKE ?,..)"     "SELECT ID FROM T WHERE IIF(DP LIKE ?,1,0) = 1 ORDER BY ID" '["1%"]'
both      "10 IIF(V STARTING WITH ?,..)" "SELECT ID FROM T WHERE IIF(V STARTING WITH ?,1,0) = 1 ORDER BY ID" '["1"]'
both      "10 IIF(V CONTAINING ?,..)"    "SELECT ID FROM T WHERE IIF(V CONTAINING ?,1,0) = 1 ORDER BY ID" '["1"]'
both      "10 EXISTS(.. WHERE T2.N382 LIKE ?) - promoted with serve-real-condpattern.sh section 10" "SELECT ID FROM T WHERE EXISTS(SELECT 1 FROM T T2 WHERE T2.N382 LIKE ?) ORDER BY ID" '["1%"]'
eng_only  "10 V LIKE ? ESCAPE ? - a BOUND escape character has no slot here" "SELECT ID FROM T WHERE V LIKE ? ESCAPE ? ORDER BY ID" '["1%","!"]'
eng_only  "10 B SIMILAR TO ? - SIMILAR TO has no bound-pattern arm at all" "SELECT ID FROM T WHERE B SIMILAR TO ? ORDER BY ID" '["T%"]'
# SIMILAR TO over a TEMPORAL raises whatever the pattern is - 22018 when
# it cannot convert, *Invalid SIMILAR TO pattern* when it can (the
# converted text will not compile as one).  The FIRST of the two is the
# engine's own vector now: the temporal operand is in SIMILAR TO's
# converting set, so the pattern converts here too and raises where the
# engine raises.  The second is still a refusal - this cell SELF-EXPIRED
# and was promoted when the two lines of work met.
err_same    "10 DT SIMILAR TO '2020%' - the pattern converts, and a wildcard cannot" \
            "SELECT ID FROM T WHERE DT SIMILAR TO '2020%'"
err_differs "10 DT SIMILAR TO '2020-01-15' - ...and a CONVERTIBLE pattern raises differently again" \
            "SELECT ID FROM T WHERE DT SIMILAR TO '2020-01-15'" "SIMILAR TO" "42000"

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-patternfam-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-patternfam-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

echo "ran $ran checks"
if [ "$ran" -lt 100 ]; then echo "FAIL only $ran checks ran (floor 100) - cells went missing"; fail=1; fi
exit $fail
