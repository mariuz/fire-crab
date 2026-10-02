#!/bin/bash
# A BOUND PATTERN INSIDE A CONDITION - `IIF(<x> LIKE ?, ..)`, `CASE WHEN
# <x> STARTING WITH ? ..`, `CONTAINING ?`, `SIMILAR TO ?` - IS THE SAME
# LAW AS IN A WHERE, and this server refused every one of them.
#
# The predicate world (`WHERE V LIKE ?`) carried the bound pattern all
# along; a CONDITION is a VALUE and goes through a different resolver,
# whose `?` sink typed comparisons only and handed every pattern form to
# the sink-less resolver - one missing sink, four operators, every
# projection, WHERE-over-IIF, HAVING, ORDER BY and UPDATE that wrote one.
# Measured 2026-10-02 across the four operators and nineteen operand
# shapes, the engine's law is ONE sentence: the slot is VARYING, as wide
# as the operand's text (any NON-TEXT operand - integer, scaled, INT128,
# FLOAT, DOUBLE, DECFLOAT, temporal, BOOLEAN - is 30), nullable exactly
# when the operand reads a column, and the bound text is NEVER CONVERTED:
#
#   IIF(DP CONTAINING ?) ['.5'] -> 1;3    IIF(DP CONTAINING '.5') -> none
#   IIF(DT CONTAINING ?) ['2020'] -> 1    IIF(DT CONTAINING '2020') raises
#   IIF(DT LIKE ?)       ['2%'] -> 1;2    IIF(DT LIKE '2%')         raises
#
# Two neighbours fell out of the same measurement, both PRE-EXISTING:
#
#   * SIMILAR TO's ESCAPE may precede only a special or itself - `'1!.%'
#     ESCAPE '!'` raises 22025 *Invalid ESCAPE sequence* on the engine and
#     answered row 1 here, in every world (§4);
#   * a LITERAL malformed SIMILAR pattern inside a condition refused the
#     whole statement at prepare, where the engine raises only when a
#     non-NULL row reaches it (§5).
#
# Usage: qa/serve-real-condpattern.sh [port]   (default 4519)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4519}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/condpattern-eng.fdb"; FC="$D/condpattern-fc.fdb"
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
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/condpattern-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/condpattern-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/condpattern-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/condpattern-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-condpattern-$PORT.log" 2>&1 & srv=$!
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
qmsg() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      if(et){console.log("CONN_ERR");process.exit(1);}
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
        const out=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("rows "+fmt(r));
        tr.rollback(()=>{console.log(out);db.detach();process.exit(0);});
      });
    });
  });' 2>/dev/null; }
err_msg() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(qmsg "$REAL" "$ENG" "$2" "$js"); fv=$(qmsg "$PORT" "$FC" "$2" "$js")
    case "$fv" in *"server was lost"*|CONN_ERR|"")
        echo "FAIL $1 - THE CONNECTION DIED mid-statement on this server (a panic?) [$fv]"; fail=1; return;; esac
    if [ "${ev#ERR }" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not raise [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (the error TEXT differs)"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
W="SELECT ID FROM T WHERE"
# ---------------------------------------------------------------
echo "--- 1 the slot and the answer: four operators x nineteen operand shapes"
for op in "LIKE" "STARTING WITH" "CONTAINING" "SIMILAR TO"; do
    case "$op" in LIKE|SIMILAR*) b='1%';; *) b='1';; esac
    for x in V C "UPPER(V)" "V || 'x'" ID SM N92 N382 I128 FL DP D16 D34 DT TS TM B "'abc'" "1"; do
        both "1 IIF($x $op ?)" "SELECT ID, IIF($x $op ?,1,0) FROM T ORDER BY ID" "[\"$b\"]"
    done
done

# ---------------------------------------------------------------
echo "--- 2 the bound text is NEVER CONVERTED - each bound cell beside its literal twin"
both_q() { both "$1" "$W $2 ORDER BY ID" "$3"; }
both_q "2 IIF(DP CONTAINING ?) ['.5'] - the rendered double"      "IIF(DP CONTAINING ?,1,0)=1" '[".5"]'
both_is "2 ...the literal converts to 0.500000000000000"          "$W IIF(DP CONTAINING '.5',1,0)=1 ORDER BY ID" "(none)"
both_q "2 IIF(DT CONTAINING ?) ['2020']"                          "IIF(DT CONTAINING ?,1,0)=1" '["2020"]'
err_msg "2 ...the literal raises at prepare"                      "$W IIF(DT CONTAINING '2020',1,0)=1"
both_q "2 IIF(DT LIKE ?) ['2%'] - wildcards live over the render" "IIF(DT LIKE ?,1,0)=1" '["2%"]'
err_msg "2 ...the literal raises"                                 "$W IIF(DT LIKE '2%',1,0)=1"
both_q "2 IIF(DP LIKE ?) ['1.5'] - no conversion, no match"       "IIF(DP LIKE ?,1,0)=1" '["1.5"]'
both_q "2 IIF(DP LIKE ?) ['1.5%']"                                "IIF(DP LIKE ?,1,0)=1" '["1.5%"]'
both_q "2 IIF(DP LIKE ?) ['%E%'] - no exponent in the render"     "IIF(DP LIKE ?,1,0)=1" '["%E%"]'
both_q "2 IIF(FL LIKE ?) ['%.5%']"                                "IIF(FL LIKE ?,1,0)=1" '["%.5%"]'
both_q "2 IIF(N92 LIKE ?) ['1.5'] - the render is 1.50"           "IIF(N92 LIKE ?,1,0)=1" '["1.5"]'
both_q "2 IIF(N92 LIKE ?) ['1.50']"                               "IIF(N92 LIKE ?,1,0)=1" '["1.50"]'
both_q "2 IIF(N382 STARTING WITH ?) ['01'] - no leading-zero fold" "IIF(N382 STARTING WITH ?,1,0)=1" '["01"]'
both_q "2 IIF(N382 LIKE ?) ['1e1%'] - no exponent fold"           "IIF(N382 LIKE ?,1,0)=1" '["1e1%"]'
both_q "2 IIF(D34 LIKE ?) ['1.5'] - DECFLOAT renders"             "IIF(D34 LIKE ?,1,0)=1" '["1.5"]'
both_q "2 IIF(D34 CONTAINING ?) ['.50']"                          "IIF(D34 CONTAINING ?,1,0)=1" '[".50"]'
both_q "2 IIF(TS LIKE ?) - the whole timestamp render"            "IIF(TS LIKE ?,1,0)=1" '["2020-01-15 10:20:30%"]'
both_q "2 IIF(TS LIKE ?) ['%.0000'] - its fraction"               "IIF(TS LIKE ?,1,0)=1" '["%.0000"]'
both_q "2 IIF(TM LIKE ?) ['%:30%']"                               "IIF(TM LIKE ?,1,0)=1" '["%:30%"]'
both_q "2 IIF(B CONTAINING ?) ['ru'] - folds case over TRUE"      "IIF(B CONTAINING ?,1,0)=1" '["ru"]'
both_q "2 IIF(B LIKE ?) ['T%']"                                   "IIF(B LIKE ?,1,0)=1" '["T%"]'
both_is "2 IIF(B LIKE ?) ['true'] - LIKE does not fold"           "$W IIF(B LIKE 'true',1,0)=1 ORDER BY ID" "(none)"

# ---------------------------------------------------------------
echo "--- 3 text operands, NULL and integer binds, NOT, ESCAPE, and every placement"
both_q "3 IIF(V CONTAINING ?) ['ABC'] - no row holds abc"        "IIF(V CONTAINING ?,1,0)=1" '["ABC"]'
both_q "3 IIF(V STARTING WITH ?) ['AB'] - STARTING does not fold" "IIF(V STARTING WITH ?,1,0)=1" '["AB"]'
both_q "3 IIF(V LIKE ?) ['_.5_']"                                 "IIF(V LIKE ?,1,0)=1" '["_.5_"]'
both_q "3 IIF(C LIKE ?) ['1.50'] - the CHAR pad is in the value"  "IIF(C LIKE ?,1,0)=1" '["1.50"]'
both_q "3 IIF(C LIKE ?) ['1.50  ']"                               "IIF(C LIKE ?,1,0)=1" '["1.50  "]'
both_q "3 IIF(C STARTING WITH ?) ['1.50  ']"                      "IIF(C STARTING WITH ?,1,0)=1" '["1.50  "]'
both_q "3 IIF(C CONTAINING ?) ['0 ']"                             "IIF(C CONTAINING ?,1,0)=1" '["0 "]'
both_q "3 IIF(C LIKE ?) - a bind wider than the slot"             "IIF(C LIKE ?,1,0)=1" '["1.50%%%%%%%%%%%%"]'
both_q "3 IIF(ID LIKE ?) - a bind wider than the 30"              "IIF(ID LIKE ?,1,0)=1" '["1%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"]'
both_q "3 IIF(V LIKE ?) [NULL] - UNKNOWN, so 0 everywhere"        "IIF(V LIKE ?,1,0)=0" '[null]'
both_q "3 IIF(V NOT LIKE ?) [NULL] - still UNKNOWN"               "IIF(V NOT LIKE ?,1,0)=0" '[null]'
both "3 CONTAINING / STARTING / SIMILAR [NULL]" "SELECT ID, IIF(V CONTAINING ?,1,0), IIF(V STARTING WITH ?,1,0), IIF(V SIMILAR TO ?,1,0) FROM T ORDER BY ID" '[null,null,null]'
both_q "3 IIF(V NOT LIKE ?)"                                      "IIF(V NOT LIKE ?,1,0)=1" '["1%"]'
both_q "3 IIF(V NOT CONTAINING ?)"                                "IIF(V NOT CONTAINING ?,1,0)=1" '["B"]'
both_q "3 IIF(V NOT STARTING WITH ?)"                             "IIF(V NOT STARTING WITH ?,1,0)=1" '["1"]'
both_q "3 IIF(V NOT SIMILAR TO ?)"                                "IIF(V NOT SIMILAR TO ?,1,0)=1" '["[0-9]%"]'
both_q "3 IIF(ID LIKE ?) [1] - an integer bind is the pattern '1'" "IIF(ID LIKE ?,1,0)=1" '[1]'
both_q "3 IIF(V LIKE ?) [1]"                                      "IIF(V LIKE ?,1,0)=1" '[1]'
both_q "3 IIF(V CONTAINING ?) [5]"                                "IIF(V CONTAINING ?,1,0)=1" '[5]'
both_q "3 IIF(V STARTING WITH ?) [10]"                            "IIF(V STARTING WITH ?,1,0)=1" '[10]'
both_q "3 IIF(V LIKE ? ESCAPE '!') ['1.!%'] - an escaped wildcard" "IIF(V LIKE ? ESCAPE '!',1,0)=1" '["1.!%"]'
err_msg "3 IIF(V LIKE ? ESCAPE '!') ['1!.%'] - a bad LIKE escape" "$W IIF(V LIKE ? ESCAPE '!',1,0)=1" '["1!.%"]'
err_msg "3 IIF(V LIKE ? ESCAPE '!') ['1!'] - a trailing escape"   "$W IIF(V LIKE ? ESCAPE '!',1,0)=1" '["1!"]'
err_msg "3 IIF(V SIMILAR TO ?) ['('] - malformed, raised per row" "$W IIF(V SIMILAR TO ?,1,0)=1" '["("]'
both_q "3 IIF(V SIMILAR TO ?) ['[a-z]+']"                         "IIF(V SIMILAR TO ?,1,0)=1" '["[a-z]+"]'
both "3 CASE WHEN V LIKE ?" "SELECT ID, CASE WHEN V LIKE ? THEN 1 ELSE 0 END FROM T ORDER BY ID" '["1.%"]'
both "3 CASE WHEN DP CONTAINING ? .. WHEN V LIKE ? - two slots, two widths" "SELECT ID, CASE WHEN DP CONTAINING ? THEN 1 WHEN V LIKE ? THEN 2 ELSE 0 END FROM T ORDER BY ID" '[".5","10%"]'
both "3 SUM(IIF(V LIKE ?))" "SELECT SUM(IIF(V LIKE ?,1,0)), COUNT(*) FROM T" '["1%"]'
both_q "3 IIF(V LIKE ? AND ID > ?) - beside a comparison slot"    "IIF(V LIKE ? AND ID > ?,1,0)=1" '["1%",1]'
both_q "3 IIF(ID > ? OR V LIKE ?)"                                "IIF(ID > ? OR V LIKE ?,1,0)=1" '[2,"1.%"]'
both_q "3 IIF(NOT (V LIKE ?))"                                    "IIF(NOT (V LIKE ?),1,0)=1" '["1%"]'
both "3 two IIFs, two pattern slots" "SELECT ID, IIF(V LIKE ?,'y','n') || IIF(V LIKE ?,'y','n') FROM T ORDER BY ID" '["1%","%0"]'
both "3 inside a correlated EXISTS" "$W EXISTS(SELECT 1 FROM T T2 WHERE T2.ID = T.ID AND IIF(T2.V LIKE ?,1,0)=1) ORDER BY ID" '["1%"]'
both "3 HAVING MAX(IIF(V LIKE ?))" "SELECT V FROM T GROUP BY V HAVING MAX(IIF(V LIKE ?,1,0)) = 1 ORDER BY V" '["10%"]'
both "3 over a JOIN" "SELECT T.ID FROM T JOIN U ON U.ID = T.ID WHERE IIF(U.TAG LIKE ?,1,0)=1 ORDER BY T.ID" '["b"]'
both "3 ORDER BY IIF(V LIKE ?)" "SELECT ID FROM T ORDER BY IIF(V LIKE ?,0,1), ID" '["10%"]'
both "3 FIRST 1 .. ORDER BY ID DESC" "SELECT FIRST 1 ID FROM T WHERE IIF(V LIKE ?,1,0)=1 ORDER BY ID DESC" '["1%"]'
both "3 DISTINCT IIF(V LIKE ?)" "SELECT DISTINCT IIF(V LIKE ?,1,0) FROM T" '["10%"]'

# ---------------------------------------------------------------
echo "--- 4 SIMILAR TO's ESCAPE precedes only a special or itself (22025), in every world"
for pat in '1!.%' '%!a' '[a!.]' '[!.-z]' '[a-!.]' '(a!b' '(!a' '[a!' '1!.%|(' '(|1!.'; do
    err_msg "4 V SIMILAR TO '$pat' ESCAPE '!'" "$W V SIMILAR TO '$pat' ESCAPE '!'"
done
# ...and the controls: an escape before a special or itself compiles; a
# pattern that ENDS under the escape outside a class, an unclosed one and
# a malformed quantifier are 42000, the other error
both_q "4 '1!!%' ESCAPE '!' - the escape escapes itself" "V SIMILAR TO '1!!%' ESCAPE '!'" '[]'
both_q "4 '1!%!_' ESCAPE '!' - escaped wildcards are literals" "V NOT SIMILAR TO '1!%!_' ESCAPE '!'" '[]'
for pat in '%!' 'a!' '!' 'a{2!,}' '[a-' '('; do
    err_msg "4 V SIMILAR TO '$pat' ESCAPE '!' - 42000" "$W V SIMILAR TO '$pat' ESCAPE '!'"
done
err_msg "4 V SIMILAR TO ? ESCAPE '!' ['1!.%'] - bound, WHERE"      "$W V SIMILAR TO ? ESCAPE '!'" '["1!.%"]'
err_msg "4 IIF(V SIMILAR TO ? ESCAPE '!') ['1!.%'] - bound, condition" "$W IIF(V SIMILAR TO ? ESCAPE '!',1,0)=1" '["1!.%"]'
err_msg "4 IIF(V SIMILAR TO ? ESCAPE '!') ['%!.%']"               "$W IIF(V SIMILAR TO ? ESCAPE '!',1,0)=1" '["%!.%"]'
err_msg "4 IIF(V SIMILAR TO '1!.%' ESCAPE '!') - literal, condition" "$W IIF(V SIMILAR TO '1!.%' ESCAPE '!',1,0)=1"
err_msg "4 a projection's IIF(V SIMILAR TO '%!a' ESCAPE '!')"     "SELECT ID, IIF(V SIMILAR TO '%!a' ESCAPE '!',1,0) FROM T"

# ---------------------------------------------------------------
echo "--- 5 a LITERAL malformed SIMILAR pattern in a condition raises when a non-NULL row reaches it"
err_msg "5 IIF(V SIMILAR TO '(') over rows - raises"               "SELECT ID, IIF(V SIMILAR TO '(',1,0) FROM T"
both_is "5 ...over no rows - answers"                              "SELECT ID, IIF(V SIMILAR TO '(',1,0) FROM T WHERE ID < 0" "(none)"
both_is "5 ...a NULL operand is UNKNOWN, no raise"                 "SELECT ID, IIF(B SIMILAR TO '(',1,0) FROM T WHERE ID = 3" "3,0"
both_is "5 ...a NULL cast everywhere"                              "SELECT ID, IIF(CAST(NULL AS VARCHAR(5)) SIMILAR TO '(',1,0) FROM T ORDER BY ID" "1,0;2,0;3,0"
both_is "5 ...a FALSE conjunct written first suppresses it"        "$W ID < 0 AND IIF(V SIMILAR TO '(',1,0)=1" "(none)"
err_msg "5 ...written second it does not"                          "$W IIF(V SIMILAR TO '(',1,0)=1 AND ID < 0"
both_is "5 ...a CASE branch never reached"                         "SELECT ID, CASE WHEN ID = 1 THEN 0 WHEN V SIMILAR TO '(' THEN 1 END FROM T WHERE ID = 1" "1,0"
# the same value-gating through a BOUND malformed pattern (§3 raised it)
both    "5 a BOUND malformed pattern, FALSE conjunct first"        "$W ID < 0 AND IIF(V SIMILAR TO ?,1,0)=1" '["("]'

# ---------------------------------------------------------------
echo "--- 6 DML that writes through a bound-pattern condition (rolled back)"
for cell in \
  "6 UPDATE .. SET SM = IIF(V LIKE ?, 7, SM)|UPDATE T SET SM = IIF(V LIKE ?, 7, SM) WHERE ID > 0 RETURNING ID, SM|[\"10%\"]" \
  "6 UPDATE .. SET SM = IIF(DT CONTAINING ?, 7, 8)|UPDATE T SET SM = IIF(DT CONTAINING ?, 7, 8) WHERE ID = 1 RETURNING SM|[\"2020\"]" \
  "6 DELETE .. WHERE IIF(V SIMILAR TO ?)|DELETE FROM T WHERE IIF(V SIMILAR TO ?, 1, 0) = 1 RETURNING ID|[\"[0-9]+.00\"]" \
  "6 INSERT .. VALUES (.., IIF('abc' LIKE ?))|INSERT INTO U (ID, TAG) VALUES (5, IIF('abc' LIKE ?, 'y', 'n')) RETURNING TAG|[\"a%\"]" \
  "6 INSERT .. SELECT .. WHERE IIF(V LIKE ?)|INSERT INTO U (ID, TAG) SELECT ID + 10, 'x' FROM T WHERE IIF(V LIKE ?,1,0)=1|[\"1%\"]"; do
    IFS='|' read -r lab sql js <<<"$cell"
    ran=$((ran + 1))
    ev=$(qmsg "$REAL" "$ENG" "$sql" "$js"); fv=$(qmsg "$PORT" "$FC" "$sql" "$js")
    if [ "${ev#ERR}" != "$ev" ] || [ "$ev" = CONN_ERR ]; then echo "FAIL $lab - the ENGINE did not write [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $lab"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $lab [$ev]"; fi
done

# ---------------------------------------------------------------
echo "--- 7 RECORDED BOUNDARIES - other routers, other shapes (each fails loudly the day it moves)"
eng_only "7 IIF(? LIKE ?) - a bound TESTED side"                     "$W IIF(? LIKE ?,1,0)=1 ORDER BY ID" '["ab","a%"]'
eng_only "7 IIF(V LIKE ? || '%') - a ? inside a pattern EXPRESSION"  "$W IIF(V LIKE ? || '%',1,0)=1 ORDER BY ID" '["1"]'
eng_only "7 a scalar subquery's IIF over an outer column"            "SELECT ID, (SELECT IIF(T.V LIKE ?,1,0) FROM RDB\$DATABASE) FROM T ORDER BY ID" '["1%"]'
eng_only "7 a GROUP BY projection's IIF(V LIKE ?)"                   "SELECT ID, IIF(V LIKE ?,1,0) FROM T GROUP BY ID, V ORDER BY ID" '["1%"]'
eng_only "7 EXISTS(.. WHERE T2.N382 LIKE ?) - a subquery's predicate over a non-text operand" "$W EXISTS(SELECT 1 FROM T T2 WHERE T2.N382 LIKE ?) ORDER BY ID" '["1%"]'
eng_only "7 V LIKE ? ESCAPE ? - a bound escape"                      "$W V LIKE ? ESCAPE ? ORDER BY ID" '["1%","!"]'
# INSERT .. SELECT typed NO `?` in a select-list condition at all - not
# even `IIF(V = ?, ..)`; recorded here, these two cells SELF-EXPIRED the
# same day when `serve-real-inselcond.sh` landed, and were promoted: the
# rows AND the describe must now match
for cell in \
  "7 INSERT .. SELECT IIF(V = ?) - the comparison too|INSERT INTO U (ID, TAG) SELECT ID + 10, IIF(V = ?, 'y', 'n') FROM T RETURNING ID, TAG|[\"10.00\"]" \
  "7 INSERT .. SELECT IIF(V STARTING WITH ?)|INSERT INTO U (ID, TAG) SELECT ID + 10, IIF(V STARTING WITH ?, 'y', 'n') FROM T RETURNING ID, TAG|[\"10\"]"; do
    IFS='|' read -r lab sql js <<<"$cell"
    ran=$((ran + 1))
    ev=$(qmsg "$REAL" "$ENG" "$sql" "$js"); fv=$(qmsg "$PORT" "$FC" "$sql" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$sql"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$sql")
    if [ "${ev#rows }" = "$ev" ]; then echo "FAIL $lab - the ENGINE no longer writes [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $lab (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ -z "$ed" ] || [ "$ed" != "$fd" ]; then echo "FAIL $lab (DESCRIBE)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $lab [$ev]"; fi
done

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-condpattern-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-condpattern-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

echo "ran $ran checks"
# the floor is the MEASURED count: 181 on the 2026-10-02 binary, 181 OK
if [ "$ran" -lt 181 ]; then echo "FAIL only $ran checks ran (floor 181) - cells went missing"; fail=1; fi
exit $fail
