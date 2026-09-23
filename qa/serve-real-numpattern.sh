#!/bin/bash
# CONTAINING AND SIMILAR TO CONVERT THEIR PATTERN EXACTLY AS LIKE DOES.
#
# `serve-real-i128like.sh` and `-tmplike.sh` pinned the pattern-conversion
# law for LIKE / STARTING WITH: against an INT128-backed exact numeric, a
# DOUBLE, a DECFLOAT or a temporal operand, a LITERAL pattern is converted
# to the operand's type at prepare and rendered back, so a wildcard
# raises 22018.  The other two pattern predicates are the same law:
#
#   I128 CONTAINING 'x'     -> RAISES 22018      N382 CONTAINING '10.5' -> row
#   DT CONTAINING '2'       -> RAISES 22018      DT CONTAINING '2020-1-15' -> row
#   N382 SIMILAR TO '10.5'  -> (none)            N382 SIMILAR TO '10.50' -> row
#   I128 SIMILAR TO '%'     -> RAISES 22018      DP CONTAINING '1e20'   -> row
#
# and a narrow numeric, an integer or a REAL matches the rendered value
# with the pattern as written.  This server refused every CONTAINING and
# SIMILAR TO over a numeric or temporal operand.
#
# Two things the round found on the way, each with its section:
#   * A DOUBLE is a WIDTH, not a column (§6): `DP + 0 LIKE 'x'`, `R * 1
#     LIKE '%'` and `ABS(DP) LIKE 'x'` all raise on the engine and
#     answered rows here, because only a bare DOUBLE column converted.
#   * The engine's SIMILAR grammar rejects a bare `-` or `^` outside a
#     class and a class ending in `-` (§5): `'a-b' SIMILAR TO 'a-b'`
#     raises "Invalid SIMILAR TO pattern", and this server answered 1.
#
# Usage: qa/serve-real-numpattern.sh [port]   (default 4474)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4474}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/numpat-eng.fdb"; FC="$D/numpat-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE T (ID INT, SI SMALLINT, I INT, BI BIGINT, N92 NUMERIC(9,2), N184 NUMERIC(18,4),
  N382 NUMERIC(38,2), I128 INT128, R REAL, DP DOUBLE PRECISION, D16 DECFLOAT(16), D34 DECFLOAT(34),
  DT DATE, TM TIME, TS TIMESTAMP, S VARCHAR(20));
INSERT INTO T VALUES (1, -12, 150, 1234567890123, 1.5, -2.25, 10.5, 170141183460469231731687303715884105727,
  1.5, 0.1, 1.50, -2.5E10, '2020-01-15', '10:20:30.1234', '2020-01-15 10:20:30', 'a-b');
INSERT INTO T VALUES (2, 0, -7, 0, 0, 0, 0, 0, -0.25, 1e20, 0, 1E-7, '1999-12-31', '00:00:00',
  '1999-12-31 23:59:59.9999', 'a^b');
CREATE TABLE U (ID INT, TAG VARCHAR(5));
INSERT INTO U VALUES (1, 'a'); INSERT INTO U VALUES (2, 'b');
CREATE TABLE C (ID INT, N382 NUMERIC(38,2), DT DATE, CN COMPUTED BY (N382 + 1), CD COMPUTED BY (DT + 1));
INSERT INTO C (ID, N382, DT) VALUES (1, 10.5, '2020-01-15');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/numpat-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/numpat-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/numpat-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/numpat-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-numpat-$PORT.log" 2>&1 & srv=$!
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

# BOTH raise the SAME vector, and a describe is allowed: an invalid
# SIMILAR pattern raises when a ROW reaches it, after the prepare
err_rows_same() {
    ran=$((ran + 1))
    local ee fe
    ee=$(err "127.0.0.1/$REAL:$ENG" "$2"); fe=$(err "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ee" ]; then echo "FAIL $1 - THE ENGINE NO LONGER RAISES; the boundary moved"; fail=1
    elif [ -z "$fe" ]; then echo "FAIL $1 - this server did not raise"; fail=1
    elif [ "$ee" != "$fe" ]; then
        echo "FAIL $1 (the VECTOR)"; echo "     eng=[$ee]"; echo "     fc =[$fe]"; fail=1
    else echo "OK   $1 [$ee]"; fi
}

# A SENTINEL BEFORE ANY CELL: the widths this gate's law turns on.  N184
# must be INT64 (580, narrow) and N382/I128 INT128 (32752, wide); R
# single (482) and DP double (480); D16/D34 the two DECFLOATs.
sent=$(run "$REAL" "$ENG" "SELECT COUNT(*) FROM T" '[]')
[ "$sent" = "2" ] || { echo "FAIL SENTINEL rows [$sent] (want 2)"; exit 1; }
wid=$(printf 'SET SQLDA_DISPLAY ON;\nSELECT N92, N184, N382, I128, R, DP, D16, D34 FROM T;\n' \
      | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | tr -d '\r' \
      | grep -aoE 'sqltype: [0-9]+' | tr -s ' ' | awk '{print $2}' | paste -sd'|')
[ "$wid" = "496|580|32752|32752|482|480|32760|32762" ] \
  || { echo "FAIL SENTINEL types [$wid] - the widths are not what this gate assumes"; exit 1; }
echo "OK   SENTINEL [$sent | $wid]"

echo "--- 1. CONTAINING CONVERTS against a wide exact, a DOUBLE, a DECFLOAT and a temporal"
err_same "1 I128 CONTAINING 'x'   - a needle that is no number raises at prepare" "SELECT ID FROM T WHERE I128 CONTAINING 'x'"
err_same "1 I128 CONTAINING '%'   - and CONTAINING has no wildcards to spare it" "SELECT ID FROM T WHERE I128 CONTAINING '%'"
err_same "1 N382 CONTAINING '.'"                                               "SELECT ID FROM T WHERE N382 CONTAINING '.'"
err_same "1 DP CONTAINING 'x'"                                                 "SELECT ID FROM T WHERE DP CONTAINING 'x'"
err_same "1 DP CONTAINING 'E+20'  - the render's own tail is not a number"     "SELECT ID FROM T WHERE DP CONTAINING 'E+20'"
err_same "1 D34 CONTAINING 'e'"                                                "SELECT ID FROM T WHERE D34 CONTAINING 'e'"
err_same "1 DT CONTAINING '2'     - a DATE needle must be a date"              "SELECT ID FROM T WHERE DT CONTAINING '2'"
err_same "1 TM CONTAINING '2'"                                                 "SELECT ID FROM T WHERE TM CONTAINING '2'"
err_same "1 TS CONTAINING '2'"                                                 "SELECT ID FROM T WHERE TS CONTAINING '2'"
err_same "1 1 = 0 AND I128 CONTAINING 'x' - AT PREPARE: no row is read"        "SELECT ID FROM T WHERE 1 = 0 AND I128 CONTAINING 'x'"
both_is  "1 N382 CONTAINING '.5'   - '0.5' at the literal's scale, inside 10.50" "SELECT ID FROM T WHERE N382 CONTAINING '.5' ORDER BY ID" "1"
both_is  "1 N382 CONTAINING '10.5'"                                             "SELECT ID FROM T WHERE N382 CONTAINING '10.5' ORDER BY ID" "1"
both_is  "1 N382 CONTAINING '10.50'"                                            "SELECT ID FROM T WHERE N382 CONTAINING '10.50' ORDER BY ID" "1"
both_is  "1 N382 CONTAINING '1e1'  - an exact operand keeps an e/E spelling RAW" "SELECT ID FROM T WHERE N382 CONTAINING '1e1' ORDER BY ID" "(none)"
both_is  "1 N382 NOT CONTAINING '.5'"                                           "SELECT ID FROM T WHERE N382 NOT CONTAINING '.5' ORDER BY ID" "2"
both_is  "1 I128 CONTAINING '0'"                                                "SELECT ID FROM T WHERE I128 CONTAINING '0' ORDER BY ID" "1;2"
both_is  "1 I128 CONTAINING '1701'"                                             "SELECT ID FROM T WHERE I128 CONTAINING '1701' ORDER BY ID" "1"
both_is  "1 DP CONTAINING '1e20'   - the DOUBLE's own text, upper-cased on both sides" "SELECT ID FROM T WHERE DP CONTAINING '1e20' ORDER BY ID" "2"
both_is  "1 DP CONTAINING '0.1'"                                                "SELECT ID FROM T WHERE DP CONTAINING '0.1' ORDER BY ID" "1"
both_is  "1 DP CONTAINING '1.000000000000000e+20'" "SELECT ID FROM T WHERE DP CONTAINING '1.000000000000000e+20' ORDER BY ID" "2"
both_is  "1 D16 CONTAINING '1.5'"                                               "SELECT ID FROM T WHERE D16 CONTAINING '1.5' ORDER BY ID" "1"
both_is  "1 D16 CONTAINING '1.50'"                                              "SELECT ID FROM T WHERE D16 CONTAINING '1.50' ORDER BY ID" "1"
both_is  "1 D34 CONTAINING '2.5'"                                               "SELECT ID FROM T WHERE D34 CONTAINING '2.5' ORDER BY ID" "1"
both_is  "1 D34 CONTAINING '1e-7'  - the DECFLOAT exponent law LIKE already carries" "SELECT ID FROM T WHERE D34 CONTAINING '1e-7' ORDER BY ID" "(none)"
both_is  "1 DT CONTAINING '2020-1-15' - converted and rendered back"            "SELECT ID FROM T WHERE DT CONTAINING '2020-1-15' ORDER BY ID" "1"
both_is  "1 DT CONTAINING '15.01.2020'"                                         "SELECT ID FROM T WHERE DT CONTAINING '15.01.2020' ORDER BY ID" "1"
both_is  "1 TM CONTAINING '10:20:30.1234'"                                      "SELECT ID FROM T WHERE TM CONTAINING '10:20:30.1234' ORDER BY ID" "1"
both_is  "1 TM CONTAINING '10:20:30' - renders .0000, not inside .1234"         "SELECT ID FROM T WHERE TM CONTAINING '10:20:30' ORDER BY ID" "(none)"
both_is  "1 TS CONTAINING '2020-01-15 10:20:30'"                                "SELECT ID FROM T WHERE TS CONTAINING '2020-01-15 10:20:30' ORDER BY ID" "1"

echo "--- 2. CONTAINING over a narrow numeric, an integer or a REAL is the RAW needle"
both_is  "2 N92 CONTAINING '1.5'"            "SELECT ID FROM T WHERE N92 CONTAINING '1.5' ORDER BY ID" "1"
both_is  "2 N92 CONTAINING '.'   - no raise: a narrow operand does not convert" "SELECT ID FROM T WHERE N92 CONTAINING '.' ORDER BY ID" "1;2"
both_is  "2 N92 CONTAINING 'x'"              "SELECT ID FROM T WHERE N92 CONTAINING 'x' ORDER BY ID" "(none)"
both_is  "2 N184 CONTAINING '.25'"           "SELECT ID FROM T WHERE N184 CONTAINING '.25' ORDER BY ID" "1"
both_is  "2 N184 CONTAINING '-2.25'"         "SELECT ID FROM T WHERE N184 CONTAINING '-2.25' ORDER BY ID" "1"
both_is  "2 R CONTAINING '.25'"              "SELECT ID FROM T WHERE R CONTAINING '.25' ORDER BY ID" "2"
both_is  "2 R CONTAINING '1.5'"              "SELECT ID FROM T WHERE R CONTAINING '1.5' ORDER BY ID" "1"
both_is  "2 R CONTAINING 'x'"                "SELECT ID FROM T WHERE R CONTAINING 'x' ORDER BY ID" "(none)"
both     "2 CONTROL I CONTAINING '5'"        "SELECT ID FROM T WHERE I CONTAINING '5' ORDER BY ID"
both     "2 CONTROL SI CONTAINING '-'"       "SELECT ID FROM T WHERE SI CONTAINING '-' ORDER BY ID"

echo "--- 3. SIMILAR TO CONVERTS by the same law, then compiles what came back"
err_same "3 I128 SIMILAR TO '%'"           "SELECT ID FROM T WHERE I128 SIMILAR TO '%'"
err_same "3 N382 SIMILAR TO '%2%'"         "SELECT ID FROM T WHERE N382 SIMILAR TO '%2%'"
err_same "3 N382 SIMILAR TO '(10.5|0)' - a grammar is no number either" "SELECT ID FROM T WHERE N382 SIMILAR TO '(10.5|0)'"
err_same "3 DP SIMILAR TO '%2%'"           "SELECT ID FROM T WHERE DP SIMILAR TO '%2%'"
err_same "3 D16 SIMILAR TO '%2%'"          "SELECT ID FROM T WHERE D16 SIMILAR TO '%2%'"
err_same "3 DT SIMILAR TO '%2%'"           "SELECT ID FROM T WHERE DT SIMILAR TO '%2%'"
err_same "3 1 = 0 AND I128 SIMILAR TO '%' - at prepare" "SELECT ID FROM T WHERE 1 = 0 AND I128 SIMILAR TO '%'"
both_is  "3 I128 SIMILAR TO '0'"           "SELECT ID FROM T WHERE I128 SIMILAR TO '0' ORDER BY ID" "2"
both_is  "3 N382 SIMILAR TO '10.50'"       "SELECT ID FROM T WHERE N382 SIMILAR TO '10.50' ORDER BY ID" "1"
both_is  "3 N382 SIMILAR TO '10.5' - rendered at the LITERAL's scale, not the column's" "SELECT ID FROM T WHERE N382 SIMILAR TO '10.5' ORDER BY ID" "(none)"
both_is  "3 N382 NOT SIMILAR TO '10.50'"   "SELECT ID FROM T WHERE N382 NOT SIMILAR TO '10.50' ORDER BY ID" "2"
both_is  "3 DP SIMILAR TO '0.1'  - the double renders fifteen decimals" "SELECT ID FROM T WHERE DP SIMILAR TO '0.1' ORDER BY ID" "(none)"
both_is  "3 DP SIMILAR TO '1e20' - its render carries a '+', a quantifier" "SELECT ID FROM T WHERE DP SIMILAR TO '1e20' ORDER BY ID" "(none)"
both_is  "3 D16 SIMILAR TO '1.50'"         "SELECT ID FROM T WHERE D16 SIMILAR TO '1.50' ORDER BY ID" "1"
both_is  "3 D16 SIMILAR TO '1.5'"          "SELECT ID FROM T WHERE D16 SIMILAR TO '1.5' ORDER BY ID" "(none)"
both_is  "3 TM SIMILAR TO '10:20:30.1234'" "SELECT ID FROM T WHERE TM SIMILAR TO '10:20:30.1234' ORDER BY ID" "1"
err_rows_same "3 DT SIMILAR TO '15.01.2020' - converts to 2020-01-15, whose '-' is no grammar" "SELECT ID FROM T WHERE DT SIMILAR TO '15.01.2020'"
err_rows_same "3 D34 SIMILAR TO '1e-7'  - ...and the same for the DECFLOAT render"               "SELECT ID FROM T WHERE D34 SIMILAR TO '1e-7'"

echo "--- 4. SIMILAR TO over a narrow numeric, an integer or a REAL is the RAW pattern"
both_is  "4 SI SIMILAR TO '%2%'  - an integer column (was a refusal)" "SELECT ID FROM T WHERE SI SIMILAR TO '%2%' ORDER BY ID" "1"
both_is  "4 I SIMILAR TO '%5%'"             "SELECT ID FROM T WHERE I SIMILAR TO '%5%' ORDER BY ID" "1"
both_is  "4 BI SIMILAR TO '1234567890123'"  "SELECT ID FROM T WHERE BI SIMILAR TO '1234567890123' ORDER BY ID" "1"
both_is  "4 I SIMILAR TO '\\-7' ESCAPE '\\'" "SELECT ID FROM T WHERE I SIMILAR TO '\\-7' ESCAPE '\\' ORDER BY ID" "2"
both_is  "4 N92 SIMILAR TO '1.50'"          "SELECT ID FROM T WHERE N92 SIMILAR TO '1.50' ORDER BY ID" "1"
both_is  "4 N92 SIMILAR TO '1.5'"           "SELECT ID FROM T WHERE N92 SIMILAR TO '1.5' ORDER BY ID" "(none)"
both_is  "4 N184 SIMILAR TO '\\-2.2500' ESCAPE '\\'" "SELECT ID FROM T WHERE N184 SIMILAR TO '\\-2.2500' ESCAPE '\\' ORDER BY ID" "1"
both_is  "4 R SIMILAR TO '%2%'"             "SELECT ID FROM T WHERE R SIMILAR TO '%2%' ORDER BY ID" "2"
both_is  "4 R SIMILAR TO '1.5'"             "SELECT ID FROM T WHERE R SIMILAR TO '1.5' ORDER BY ID" "(none)"
err_rows_same "4 I SIMILAR TO '-7'  - the bare '-' again" "SELECT ID FROM T WHERE I SIMILAR TO '-7'"

echo "--- 5. THE SIMILAR GRAMMAR: a bare - or ^ is no literal (these ANSWERED here)"
err_rows_same "5 'a-b' SIMILAR TO 'a-b'"   "SELECT 1 FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO 'a-b'"
err_rows_same "5 SIMILAR TO '-'"           "SELECT 1 FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '-'"
err_rows_same "5 SIMILAR TO '(a|-)'"       "SELECT 1 FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '(a|-)'"
err_rows_same "5 SIMILAR TO '(-)'"         "SELECT 1 FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '(-)'"
err_rows_same "5 SIMILAR TO 'a^b'"         "SELECT 1 FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO 'a^b'"
err_rows_same "5 SIMILAR TO '^a'"          "SELECT 1 FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '^a'"
err_rows_same "5 SIMILAR TO '[a-]' - a class that ENDS in -" "SELECT 1 FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '[a-]'"
err_rows_same "5 a column: S SIMILAR TO 'a-b'" "SELECT ID FROM T WHERE S SIMILAR TO 'a-b'"
both_is  "5 CONTROL 'a\\-b' ESCAPE '\\' - the escaped one IS the literal" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO 'a\\-b' ESCAPE '\\'" "1"
both_is  "5 CONTROL '[-]'  - a class of just -"   "SELECT COUNT(*) FROM RDB\$DATABASE WHERE '-' SIMILAR TO '[-]'" "1"
both_is  "5 CONTROL '[-a]%' - a LEADING - in a class" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '[-a]%'" "1"
both_is  "5 CONTROL '[a-c]%' - a range"           "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '[a-c]%'" "1"
both_is  "5 CONTROL '[^b]%' - a leading ^ negates" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '[^b]%'" "1"
both_is  "5 CONTROL '[a^]%' - a later ^ is the character" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a-b' SIMILAR TO '[a^]%'" "1"

echo "--- 5b. A CLASS IS [<include>^<exclude>] - a later ^ is no member (these answered 1 here)"
both_is  "5b S SIMILAR TO 'a[-^]b' - takes '-', and the '^' only opens an empty exclusion" "SELECT ID FROM T WHERE S SIMILAR TO 'a[-^]b' ORDER BY ID" "1"
both_is  "5b 'a^b' SIMILAR TO 'a[x^]b'"      "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a^b' SIMILAR TO 'a[x^]b'" "0"
both_is  "5b 'x' SIMILAR TO '[x^]'"          "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'x' SIMILAR TO '[x^]'" "1"
both_is  "5b 'a' SIMILAR TO '[a-z^b]'"       "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a' SIMILAR TO '[a-z^b]'" "1"
both_is  "5b 'b' SIMILAR TO '[a-z^b]' - excluded" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'b' SIMILAR TO '[a-z^b]'" "0"
both_is  "5b 'b' SIMILAR TO '[[:ALPHA:]^a]'" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'b' SIMILAR TO '[[:ALPHA:]^a]'" "1"
both_is  "5b 'a' SIMILAR TO '[[:ALPHA:]^a]'" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'a' SIMILAR TO '[[:ALPHA:]^a]'" "0"
both_is  "5b '5' SIMILAR TO '[0-9^[:DIGIT:]]' - everything excluded" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE '5' SIMILAR TO '[0-9^[:DIGIT:]]'" "0"
both_is  "5b 'q' SIMILAR TO '[^]' - a negated empty class takes anything" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE 'q' SIMILAR TO '[^]'" "1"
both_is  "5b '^' SIMILAR TO '[a\^]' ESCAPE - an escaped ^ IS a member" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE '^' SIMILAR TO '[a\^]' ESCAPE '\'" "1"
both_is  "5b '^' SIMILAR TO '[^\^]' ESCAPE" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE '^' SIMILAR TO '[^\^]' ESCAPE '\'" "0"
both_is  "5b ']' SIMILAR TO '[]a]' - a LEADING ] is a member" "SELECT COUNT(*) FROM RDB\$DATABASE WHERE ']' SIMILAR TO '[]a]'" "1"
err_rows_same "5b '[^a^b]' - a negated class has no exclusion" "SELECT 1 FROM RDB\$DATABASE WHERE 'a' SIMILAR TO '[^a^b]'"
err_rows_same "5b '[a^b^c]' - nor a third list"                "SELECT 1 FROM RDB\$DATABASE WHERE 'a' SIMILAR TO '[a^b^c]'"
err_rows_same "5b '[]'  - unclosed: its ] is a member"         "SELECT 1 FROM RDB\$DATABASE WHERE 'a' SIMILAR TO '[]'"

echo "--- 6. A DOUBLE IS A WIDTH, NOT A COLUMN (these ANSWERED here where the engine raises)"
err_same "6 DP + 0 LIKE 'x'"                   "SELECT ID FROM T WHERE DP + 0 LIKE 'x'"
err_same "6 R * 1 LIKE '%'  - FLOAT arithmetic widens" "SELECT ID FROM T WHERE R * 1 LIKE '%'"
err_same "6 R + R LIKE 'x'"                    "SELECT ID FROM T WHERE R + R LIKE 'x'"
err_same "6 -DP LIKE 'x'"                      "SELECT ID FROM T WHERE -DP LIKE 'x'"
err_same "6 ABS(DP) LIKE 'x'"                  "SELECT ID FROM T WHERE ABS(DP) LIKE 'x'"
err_same "6 ROUND(DP, 1) LIKE 'x'"             "SELECT ID FROM T WHERE ROUND(DP, 1) LIKE 'x'"
err_same "6 COALESCE(DP, 0) LIKE 'x'"          "SELECT ID FROM T WHERE COALESCE(DP, 0) LIKE 'x'"
err_same "6 CAST(ID AS DOUBLE PRECISION) LIKE 'x'" "SELECT ID FROM T WHERE CAST(ID AS DOUBLE PRECISION) LIKE 'x'"
err_same "6 N92 * 1e0 LIKE 'x' - a double literal widens the product" "SELECT ID FROM T WHERE N92 * 1e0 LIKE 'x'"
err_same "6 DP / 2 STARTING WITH 'x'"          "SELECT ID FROM T WHERE DP / 2 STARTING WITH 'x'"
err_same "6 DP + 0 CONTAINING 'x'"             "SELECT ID FROM T WHERE DP + 0 CONTAINING 'x'"
err_same "6 DP * 1 SIMILAR TO '%'"             "SELECT ID FROM T WHERE DP * 1 SIMILAR TO '%'"
both_is  "6 DP * 1 CONTAINING '1e20' - was a WRONG ANSWER" "SELECT ID FROM T WHERE DP * 1 CONTAINING '1e20' ORDER BY ID" "2"
both_is  "6 DP + 0 LIKE '1e20'"                "SELECT ID FROM T WHERE DP + 0 LIKE '1e20' ORDER BY ID" "2"
both_is  "6 CONTROL -R LIKE 'x'   - a single stays single, raw" "SELECT ID FROM T WHERE -R LIKE 'x' ORDER BY ID" "(none)"
both_is  "6 CONTROL ABS(R) LIKE '%'"           "SELECT ID FROM T WHERE ABS(R) LIKE '%' ORDER BY ID" "1;2"
both_is  "6 CONTROL CAST(ID AS REAL) LIKE 'x'" "SELECT ID FROM T WHERE CAST(ID AS REAL) LIKE 'x' ORDER BY ID" "(none)"
both_is  "6 CONTROL COALESCE(R, R) LIKE '%'"   "SELECT ID FROM T WHERE COALESCE(R, R) LIKE '%' ORDER BY ID" "1;2"
both_is  "6 CONTROL IIF(ID = 1, R, R) LIKE '%'" "SELECT ID FROM T WHERE IIF(ID = 1, R, R) LIKE '%' ORDER BY ID" "1;2"
both_is  "6 CONTROL R + 0 LIKE '1.5'"          "SELECT ID FROM T WHERE R + 0 LIKE '1.5' ORDER BY ID" "(none)"
both_is  "6 CONTROL (DP + 0) || '' LIKE 'x' - a concatenation is text" "SELECT ID FROM T WHERE (DP + 0) || '' LIKE 'x' ORDER BY ID" "(none)"

echo "--- 7. EVERY ROUTER: a join, a computed column, a CAST, arithmetic, IIF / CASE"
both_is  "7 JOIN T.N382 CONTAINING '10.5'"      "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.N382 CONTAINING '10.5'" "a"
err_same "7 JOIN T.N382 CONTAINING 'x'"         "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.N382 CONTAINING 'x'"
both_is  "7 JOIN T.I128 SIMILAR TO '0'"         "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.I128 SIMILAR TO '0'" "b"
both_is  "7 JOIN T.DT CONTAINING '2020-1-15'"   "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.DT CONTAINING '2020-1-15'" "a"
err_same "7 JOIN T.DP SIMILAR TO '%'"           "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.DP SIMILAR TO '%'"
both_is  "7 COMPUTED CN CONTAINING '11.5'"      "SELECT ID FROM C WHERE CN CONTAINING '11.5'" "1"
both_is  "7 COMPUTED CN SIMILAR TO '11.50'"     "SELECT ID FROM C WHERE CN SIMILAR TO '11.50'" "1"
both_is  "7 COMPUTED CD CONTAINING '2020-1-16'" "SELECT ID FROM C WHERE CD CONTAINING '2020-1-16'" "1"
err_same "7 COMPUTED CD SIMILAR TO '%'"         "SELECT ID FROM C WHERE CD SIMILAR TO '%'"
err_same "7 N382 + 0 CONTAINING 'x'"            "SELECT ID FROM T WHERE N382 + 0 CONTAINING 'x'"
both_is  "7 N382 + 0 CONTAINING '10.5'"         "SELECT ID FROM T WHERE N382 + 0 CONTAINING '10.5' ORDER BY ID" "1"
both_is  "7 CAST(ID AS NUMERIC(38,2)) SIMILAR TO '1.00'" "SELECT ID FROM T WHERE CAST(ID AS NUMERIC(38,2)) SIMILAR TO '1.00' ORDER BY ID" "1"
err_same "7 CAST(ID AS NUMERIC(38,2)) CONTAINING 'x'" "SELECT ID FROM T WHERE CAST(ID AS NUMERIC(38,2)) CONTAINING 'x'"
both_is  "7 DT + 1 CONTAINING '2020-1-16'"      "SELECT ID FROM T WHERE DT + 1 CONTAINING '2020-1-16' ORDER BY ID" "1"
err_same "7 CAST(DT AS TIMESTAMP) SIMILAR TO '2020%'" "SELECT ID FROM T WHERE CAST(DT AS TIMESTAMP) SIMILAR TO '2020%'"
both_is  "7 SUM(IIF(N382 CONTAINING '10.5'))"   "SELECT SUM(IIF(N382 CONTAINING '10.5', 1, 0)) FROM T" "1"
both_is  "7 SUM(IIF(I128 SIMILAR TO '0'))"      "SELECT SUM(IIF(I128 SIMILAR TO '0', 1, 0)) FROM T" "1"
err_same "7 SUM(IIF(DT SIMILAR TO '%'))"        "SELECT SUM(IIF(DT SIMILAR TO '%', 1, 0)) FROM T"
both_is  "7 CASE WHEN DP CONTAINING '1e20'"     "SELECT ID, CASE WHEN DP CONTAINING '1e20' THEN 1 ELSE 0 END FROM T ORDER BY ID" "1,0;2,1"
both_is  "7 IIF(R CONTAINING '.25') in a WHERE" "SELECT ID FROM T WHERE IIF(R CONTAINING '.25', 1, 0) = 1" "2"
both     "7 describe: IIF over each"            "SELECT IIF(N92 CONTAINING '5', 1, 0), IIF(R SIMILAR TO '%5%', 1, 0), IIF(SI SIMILAR TO '%2%', 1, 0) FROM T ORDER BY ID"

echo "--- 8. RECORDED (the engine answers or raises differently; this server refuses or differs)"
eng_only    "8 JOIN T.D16 CONTAINING '1.5' - a DECFLOAT through the join router" "SELECT U.TAG FROM T JOIN U ON T.ID = U.ID WHERE T.D16 CONTAINING '1.5'"
eng_only    "8 D16 in a string function"   "SELECT ID, CHAR_LENGTH(D16), POSITION('.' IN D16), LEFT(D16, 2) FROM T ORDER BY ID"
eng_only    "8 REPLACE / LPAD over D34"    "SELECT ID, REPLACE(D34, '0', 'o'), LPAD(D34, 12, '*') FROM T ORDER BY ID"
err_differs "8 IIF(D16 CONTAINING 'x') - the DECFLOAT arm of the IIF router refuses" "SELECT IIF(D16 CONTAINING 'x', 1, 0) FROM T" 'conversion error from string "x"' '42000'
err_differs "8 TWO conversions in one select list: the engine names the LAST, this server the FIRST" \
            "SELECT IIF(N382 CONTAINING '.', 1, 0), IIF(N382 LIKE '%0%', 1, 0) FROM T" 'conversion error from string "%0%"' 'conversion error from string "."'

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-numpat-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-numpat-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

echo "ran $ran checks"
if [ "$ran" -lt 143 ]; then echo "FAIL only $ran checks ran (floor 143) - cells went missing"; fail=1; fi
exit $fail
