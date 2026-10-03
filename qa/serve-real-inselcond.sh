#!/bin/bash
# A `?` IN A SELECT-LIST CONDITION OF AN INSERT .. SELECT, AND THE PASSES
# A CONDITIONAL LOSES WHEN ITS CONDITION CARRIES A `?`.
#
# 1. `INSERT .. SELECT` refused EVERY `?` between SELECT and FROM, because
#    a bare item's `?` is typed from the INSERT TARGET (`SELECT ?` into an
#    INTEGER is LONG) and nothing here typed that.  But a `?` INSIDE A
#    CONDITION is a different law the engine keeps apart: it is typed from
#    its comparison's other side exactly as in a plain SELECT (measured
#    2026-10-02 - `IIF(V = ?, 'y', 'n')` describes V's VARYING 20, `CASE
#    WHEN DP > ?` a DOUBLE), and it lands in the input SQLDA BEFORE the
#    WHERE's.  So a select list whose every `?` sits in a condition plans
#    through the source's own sink, and the execute binds the source's
#    projection (the top-level bind never reached a nested plan).  A `?`
#    at a value position - a bare item, an operand, a conditional's BRANCH
#    (`IIF(V = ?, ?, 'n')` types its branch from TAG, VARYING 5) - stays
#    refused and is recorded (§4).
#
# 2. A CHAR-formed conditional KEEPS ITS PAD when its condition carries a
#    `?` - and this server dropped it in every router (PRE-EXISTING, the
#    previous binary diverged identically): `CASE WHEN DP > ? THEN 'big'
#    ELSE 's' END || '|'` answered `s|` where the engine answers `s  |`,
#    `UPDATE .. SET TAG = <it>` STORED `s`, a GROUP BY key split from its
#    literal twin.  The `?`-carrying CASE / IIF / COALESCE arms applied
#    only the FLOAT pass of the literal path's six; with every `?` in a
#    condition the tree IS the literal twin's, and now takes the whole
#    chain (align, recode, pad, recode string functions, float, decfloat).
#
# node-firebird cannot fetch a DECFLOAT (its -804 on the ENGINE side is the
# instrument, not the server), so a DECFLOAT conditional is read through
# CAST(.. AS VARCHAR(40)).
#
# Usage: qa/serve-real-inselcond.sh [port]   (default 4521)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4521}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/inselcond-eng.fdb"; FC="$D/inselcond-fc.fdb"
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
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/inselcond-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/inselcond-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/inselcond-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; cat /tmp/inselcond-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-inselcond-$PORT.log" 2>&1 & srv=$!
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
# a DML statement run inside a ROLLED-BACK transaction: the RETURNING rows
# (or the error text) AND the whole describe must match
dml() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(qmsg "$REAL" "$ENG" "$2" "$js"); fv=$(qmsg "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ] || [ -z "$ev" ]; then echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE did not write [$ev]"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 [the ENGINE printed no describe]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1 (DESCRIBE)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# DML with a READ-BACK, inside a rolled-back transaction: node-firebird
# fetches NO RETURNING row for `INSERT .. VALUES` (the engine's own answer
# reads "(none)" too), so a VALUES cell compares what was WRITTEN instead -
# a RETURNING comparison there would be two empty answers agreeing
qrb() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_RB="$5" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).map(v=>v===null?"NULL":v).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2)=>{
        const d=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):"ok";
        tr.query(process.env.FC_RB,[],(e3,r)=>{
          const rb=e3?"ERR":fmt(r);
          tr.rollback(()=>{console.log("dml="+d+" rb="+rb);db.detach();process.exit(0);});
        });
      });
    });
  });' 2>/dev/null; }
dml_rb() { # <label> <sql> <json> <read-back>
    ran=$((ran + 1))
    local ev fv
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$4"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$4")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ] || [ -z "$ev" ]; then echo "FAIL $1 [CONN_ERR]"; fail=1
    elif [ "${ev#dml=ok}" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not write [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev] (rolled back)"; fi
}
dml_rb_refused() { # <label> <sql> <json> <read-back>
    ran=$((ran + 1))
    local ev fv
    ev=$(qrb "$REAL" "$ENG" "$2" "$3" "$4"); fv=$(qrb "$PORT" "$FC" "$2" "$3" "$4")
    if [ "${ev#dml=ok}" = "$ev" ]; then echo "FAIL $1 - the ENGINE no longer writes [$ev]"; fail=1
    elif [ "${fv#dml=ERR Dynamic SQL Error}" = "$fv" ]; then echo "FAIL $1 - this server moved [$fv] (engine [$ev]); promote if they agree"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
# the engine WRITES/ANSWERS and this server refuses - recorded
dml_refused() {
    ran=$((ran + 1))
    local ev fv
    ev=$(qmsg "$REAL" "$ENG" "$2" "$3"); fv=$(qmsg "$PORT" "$FC" "$2" "$3")
    if [ "${ev#rows }" = "$ev" ]; then echo "FAIL $1 - the ENGINE no longer answers [$ev]"; fail=1
    elif [ "$fv" != "ERR Dynamic SQL Error" ]; then echo "FAIL $1 - this server moved [$fv] (engine [$ev]); promote the cell if they agree"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}

I="INSERT INTO U (ID, TAG)"
# ---------------------------------------------------------------
echo "--- 1 a select-list CONDITION's ? in INSERT .. SELECT: typed from its comparison, bound per execute"
dml "1 IIF(V = ?)"                  "$I SELECT ID + 10, IIF(V = ?, 'y', 'n') FROM T RETURNING ID, TAG" '["10.00"]'
dml "1 IIF(ID > ?)"                 "$I SELECT ID + 10, IIF(ID > ?, 'y', 'n') FROM T RETURNING ID, TAG" '[1]'
dml "1 IIF(V LIKE ?) - the pattern slot" "$I SELECT ID + 10, IIF(V LIKE ?, 'y', 'n') FROM T RETURNING ID, TAG" '["1%"]'
dml "1 IIF(DT CONTAINING ?) - unconverted" "$I SELECT ID + 10, IIF(DT CONTAINING ?, 'y', 'n') FROM T RETURNING ID, TAG" '["2020"]'
dml "1 CASE WHEN DP > ? - a DOUBLE slot, a CHAR(3) result kept padded" "$I SELECT ID + 10, CASE WHEN DP > ? THEN 'big' ELSE 's' END FROM T RETURNING ID, TAG" '[2]'
dml "1 IIF(DP > ?, 'big', 's')"     "$I SELECT ID + 10, IIF(DP > ?, 'big', 's') FROM T RETURNING ID, TAG" '[2]'
dml "1 two conditions, two slots, text order" "$I SELECT ID + 10, IIF(ID > ? AND V LIKE ?, 'y', 'n') FROM T RETURNING ID, TAG" '[1,"1%"]'
dml "1 a NULL bind - UNKNOWN, the ELSE" "$I SELECT ID + 10, IIF(ID > ?, 'y', 'n') FROM T RETURNING ID, TAG" '[null]'
dml "1 the column list in another order" "INSERT INTO U (TAG, ID) SELECT IIF(V = ?, 'y', 'n'), ID + 20 FROM T RETURNING ID, TAG" '["1.50"]'
dml "1 no RETURNING - the row count path" "$I SELECT ID + 10, IIF(V = ?, 'y', 'n') FROM T" '["10.00"]'
dml "1 CONTROL: a WHERE-only ? (answered before)" "$I SELECT ID + 10, 'w' FROM T WHERE ID > ? RETURNING ID, TAG" '[1]'

# ---------------------------------------------------------------
echo "--- 2 a CHAR-formed conditional keeps its pad when its condition carries a ?"
both "2 CASE WHEN DP > ? .. || '|'"   "SELECT ID, CASE WHEN DP > ? THEN 'big' ELSE 's' END || '|' FROM T ORDER BY ID" '[2]'
both "2 ...its literal twin"           "SELECT ID, CASE WHEN DP > 2 THEN 'big' ELSE 's' END || '|' FROM T ORDER BY ID"
both "2 two conditions, two branches"  "SELECT ID, CASE WHEN ID > ? THEN 'a' WHEN ID > ? THEN 'bbbb' END || '|' FROM T ORDER BY ID" '[2,1]'
both "2 WHERE <conditional> = 's  '"   "SELECT ID FROM T WHERE CASE WHEN ID > ? THEN 'big' ELSE 's' END = 's  ' ORDER BY ID" '[1]'
both "2 WHERE <conditional> || '|' = 's  |'" "SELECT ID FROM T WHERE CASE WHEN ID > ? THEN 'big' ELSE 's' END || '|' = 's  |' ORDER BY ID" '[1]'
both "2 a GROUP BY key"                "SELECT IIF(ID > ?, 'big', 's') || '|', COUNT(*) FROM T GROUP BY 1 ORDER BY 1" '[1]'
both "2 an ORDER BY key"               "SELECT ID FROM T ORDER BY IIF(ID > ?, 'big', 's') || V" '[1]'
both "2 COALESCE over a conditional"   "SELECT ID, COALESCE(IIF(ID > ?, NULL, 'ab'), 'zzzz') || '|' FROM T ORDER BY ID" '[1]'
both "2 a CHAR column beside a VARCHAR" "SELECT ID, CASE WHEN ID > ? THEN C ELSE V END || '|' FROM T ORDER BY ID" '[1]'
both "2 a VARCHAR branch does not pad"  "SELECT ID, IIF(ID > ?, V, 'x') || '|' FROM T ORDER BY ID" '[1]'
both "2 scaled branches align"          "SELECT ID, IIF(ID > ?, 1.5, 2.25) FROM T ORDER BY ID" '[1]'
both "2 FLOAT beside DOUBLE"            "SELECT ID, IIF(ID > ?, FL, DP) FROM T ORDER BY ID" '[1]'
both "2 a DECFLOAT conditional (through VARCHAR)" "SELECT ID, CAST(IIF(ID > ?, D34, 1) AS VARCHAR(40)) FROM T ORDER BY ID" '[1]'
dml  "2 UPDATE SET <padded conditional> || '!'" "UPDATE U SET TAG = IIF(ID > ?, 'big', 's') || '!' WHERE ID = 1 RETURNING TAG" '[2]'
dml  "2 UPDATE SET <padded CASE>"       "UPDATE U SET TAG = CASE WHEN ID > ? THEN 'big' ELSE 's' END WHERE ID = 1 RETURNING TAG" '[2]'
dml  "2 UPDATE SET <padded COALESCE> || '!'" "UPDATE U SET TAG = COALESCE(IIF(ID > ?, NULL, 'ab'), 'zzzz') || '!' WHERE ID = 1 RETURNING TAG" '[2]'

# ---------------------------------------------------------------
echo "--- 3 RECORDED BOUNDARIES (each fails loudly the day it moves)"
dml_refused "3 INSERT .. SELECT ? - a bare item, typed from the target" "$I SELECT ?, 'z' FROM T RETURNING ID, TAG" '[10]'
dml_refused "3 INSERT .. SELECT ID + ? - an operand"                 "$I SELECT ID + ?, 'z' FROM T RETURNING ID, TAG" '[10]'
dml_refused "3 INSERT .. SELECT IIF(V = ?, ?, 'n') - a BRANCH ?, typed from TAG" "$I SELECT ID + 10, IIF(V = ?, ?, 'n') FROM T RETURNING ID, TAG" '["10.00","q"]'
dml         "3 INSERT .. SELECT SUBSTRING(IIF(V = ?, ..)) - promoted with section 4's function arm" "$I SELECT ID + 10, SUBSTRING(IIF(V = ?, 'yes', 'no') FROM 1 FOR 1) FROM T RETURNING ID, TAG" '["10.00"]'
# a PATTERN slot beside a WHERE `?` - promoted the day K1 learned the
# pattern slot is neutral (`serve-real-condpattern.sh` section 8)
dml         "3 INSERT .. SELECT IIF(V LIKE ?) .. WHERE ID > ? - a pattern slot mixes nothing" "$I SELECT ID + 10, IIF(V LIKE ?, 'y', 'n') FROM T WHERE ID > ? RETURNING ID, TAG" '["1%",1]'
# ...while a NUMERIC condition slot beside a WHERE `?` is K1's mix, in the
# INSERT and the plain SELECT alike
dml_refused "3 INSERT .. SELECT IIF(ID > ?) .. WHERE ID > ? - K1"     "$I SELECT ID + 10, IIF(ID > ?, 'y', 'n') FROM T WHERE ID > ? RETURNING ID, TAG" '[1,1]'
dml_refused "3 ...and the plain SELECT refuses that mix too"          "SELECT ID, IIF(ID > ?, 'y', 'n') FROM T WHERE ID > ?" '[1,1]'
dml         "3 CHAR_LENGTH(IIF(ID > ?, ..)) - promoted with section 4's function arm"    "SELECT ID, CHAR_LENGTH(IIF(ID > ?, 'big', 's')) FROM T ORDER BY ID" '[1]'

# ---------------------------------------------------------------
echo "--- 4 a BUILT-IN FUNCTION over a conditional whose condition carries a ?"
# The projection router had no function arm at all: CHAR_LENGTH / UPPER /
# TRIM / SUBSTRING / ROUND / HASH .. over `IIF(ID > ?, ..)` refused, though
# the conditional alone answered.  The literal resolver carries every
# function's own law; it now runs with the router's `?` sink LENT to its
# conditions (with_ambient_sink), so only the condition's `?` is new.
X="IIF(ID > ?, 'big', 's')"
for f in "CHAR_LENGTH($X)" "OCTET_LENGTH($X)" "UPPER($X)" "LOWER($X)" "TRIM($X)" "SUBSTRING($X FROM 1 FOR 2)" \
         "POSITION('g' IN $X)" "REVERSE($X)" "LPAD($X, 5, '*')" "REPLACE($X, 's', 'S')" "LEFT($X, 2)" "HASH($X)" \
         "ABS(IIF(ID > ?, -1, 2))" "ROUND(IIF(ID > ?, 1.25, 2.5), 1)" "UPPER(TRIM($X)) || '|'" \
         "CHAR_LENGTH(CASE WHEN V LIKE ? THEN 'abcd' ELSE 'x' END)" "CHAR_LENGTH(COALESCE(IIF(ID > ?, NULL, 'ab'), 'zzzz'))" \
         "EXTRACT(YEAR FROM IIF(ID > ?, DT, DATE '2000-01-01'))" "ROUND(IIF(ID > ?, N92, 0), 0)" \
         "CAST(ABS(IIF(ID > ?, D34, -1)) AS VARCHAR(40))" "UPPER(IIF(IIF(ID > ?, 1, 0) = 1, 'big', 's'))"; do
    case "$f" in *LIKE*) b='["1%"]';; *) b='[1]';; esac
    both "4 $f" "SELECT ID, $f FROM T ORDER BY ID" "$b"
done
both "4 UPPER(IIF(DT CONTAINING ?, V, 'no'))" "SELECT ID, UPPER(IIF(DT CONTAINING ?, V, 'no')) FROM T ORDER BY ID" '["2020"]'
both "4 CHAR_LENGTH(..) with a NULL bind - the ELSE" "SELECT ID, CHAR_LENGTH($X) FROM T ORDER BY ID" '[null]'
both "4 WHERE CHAR_LENGTH(..) = 3"   "SELECT ID FROM T WHERE CHAR_LENGTH($X) = 3 ORDER BY ID" '[1]'
both "4 WHERE UPPER(..) = 'BIG'"     "SELECT ID FROM T WHERE UPPER($X) = 'BIG' ORDER BY ID" '[1]'
both "4 GROUP BY UPPER(..)"          "SELECT UPPER($X), COUNT(*) FROM T GROUP BY 1 ORDER BY 1" '[1]'
both "4 ORDER BY REVERSE(..)"        "SELECT ID FROM T ORDER BY REVERSE($X), ID" '[1]'
both "4 HAVING MAX(CHAR_LENGTH(..))" "SELECT V FROM T GROUP BY V HAVING MAX(CHAR_LENGTH(IIF(V > ?, V, 'x'))) > 4 ORDER BY V" '["10"]'
both "4 SUM(CHAR_LENGTH(..))"        "SELECT SUM(CHAR_LENGTH($X)) FROM T" '[1]'
both "4 UPPER(IIF(V LIKE ?)) .. WHERE ID > ? - a pattern slot beside a classic one" "SELECT ID, UPPER(IIF(V LIKE ?, 'y', 'n')) FROM T WHERE ID > ? ORDER BY ID" '["1%",1]'
dml  "4 UPDATE SET TAG = UPPER(..)"  "UPDATE U SET TAG = UPPER($X) WHERE ID = 1 RETURNING TAG" '[2]'
dml  "4 INSERT .. SELECT UPPER(..)"  "$I SELECT ID + 10, UPPER($X) FROM T RETURNING ID, TAG" '[1]'
# RECORDED: other routers, a value-position `?`, and K1's numeric mix
both        "4 WHERE UPPER(..) LIKE 'B%' - promoted with condpattern section 9's bind fix"  "SELECT ID FROM T WHERE UPPER($X) LIKE 'B%' ORDER BY ID" '[1]'
both        "4 a scalar subquery's CHAR_LENGTH(IIF(T.ID > ?)) - promoted with section 6"             "SELECT ID, (SELECT CHAR_LENGTH(IIF(T.ID > ?, 'big', 's')) FROM RDB\$DATABASE) FROM T ORDER BY ID" '[1]'
dml_refused "4 UPPER(IIF(ID > ?, ?, 's')) - a BRANCH ?"                    "SELECT ID, UPPER(IIF(ID > ?, ?, 's')) FROM T ORDER BY ID" '[1,"q"]'
dml_refused "4 LPAD(.., ?, '*') - a function ARGUMENT ?"                   "SELECT ID, LPAD($X, ?, '*') FROM T ORDER BY ID" '[1,5]'
dml_refused "4 UPPER(IIF(ID > ?)) .. WHERE ID > ? - K1's numeric mix"      "SELECT ID, UPPER($X) FROM T WHERE ID > ? ORDER BY ID" '[1,1]'

# ---------------------------------------------------------------
echo "--- 5 a GROUPED projection: a condition ? over the keys, and an aggregate slot's nullability"
# `SELECT ID, IIF(ID > ?, 'y', 'n') FROM T GROUP BY ID` refused - an
# expression over the grouping keys carrying ANY `?` was a boundary - while
# the same over an AGGREGATE answered.  A condition-only `?` now takes the
# deferred path, resolved through the sink over the key slots.  And a `?`
# compared with COUNT / VAR / STDDEV / a statistical fold is NOT NULL on
# the engine: the group row's view now carries the describe rule
# (agg_described_not_null), shared with the output describe.
G="FROM T GROUP BY"
both "5 IIF(V LIKE ?) .. GROUP BY ID, V"        "SELECT ID, IIF(V LIKE ?, 1, 0) $G ID, V ORDER BY ID" '["1%"]'
both "5 IIF(ID > ?) .. GROUP BY ID"             "SELECT ID, IIF(ID > ?, 'y', 'n') $G ID ORDER BY ID" '[1]'
both "5 IIF(V = ?) .. GROUP BY V"               "SELECT V, IIF(V = ?, 'y', 'n') $G V ORDER BY V" '["10.00"]'
both "5 IIF(V LIKE ?), COUNT(*) .. ORDER BY 1"  "SELECT IIF(V LIKE ?, 1, 0), COUNT(*) $G V ORDER BY 1" '["1%"]'
both "5 CASE WHEN V LIKE ? .. GROUP BY ID, V"   "SELECT ID, CASE WHEN V LIKE ? THEN 'a' ELSE 'b' END $G ID, V ORDER BY ID" '["1%"]'
both "5 UPPER(IIF(ID > ?)) .. GROUP BY ID"      "SELECT ID, UPPER(IIF(ID > ?, 'big', 's')) $G ID ORDER BY ID" '[1]'
both "5 .. HAVING COUNT(*) > 0"                 "SELECT ID, IIF(ID > ?, 'y', 'n') $G ID HAVING COUNT(*) > 0 ORDER BY ID" '[1]'
both "5 .. beside COUNT(*), ORDER BY 2, 1"      "SELECT ID, IIF(ID > ?, 'y', 'n'), COUNT(*) $G ID ORDER BY 2, 1" '[1]'
both "5 .. ROWS 2"                              "SELECT ID, IIF(ID > ?, 'y', 'n') $G ID ORDER BY ID ROWS 2" '[1]'
both "5 FIRST 1 .. DESC"                        "SELECT FIRST 1 ID, IIF(ID > ?, 'y', 'n') $G ID ORDER BY ID DESC" '[1]'
both "5 over a JOIN, GROUP BY T.ID, U.TAG"      "SELECT T.ID, IIF(U.TAG LIKE ?, 1, 0) FROM T JOIN U ON U.ID = T.ID GROUP BY T.ID, U.TAG ORDER BY 1" '["b"]'
both "5 IIF(V LIKE ?) .. WHERE ID > ? - a pattern slot beside a classic one" "SELECT ID, IIF(V LIKE ?, 'y', 'n') FROM T WHERE ID > ? GROUP BY ID, V ORDER BY ID" '["1%",1]'
for a in "COUNT(*)" "COUNT(ID)" "COUNT(DISTINCT ID)" "VAR_POP(ID)" "STDDEV_SAMP(ID)" "COVAR_SAMP(ID, SM)" "REGR_COUNT(ID, SM)" "SUM(ID)" "MIN(ID)" "AVG(ID)" "COUNT(*) + 1"; do
    both "5 IIF($a > ?) - the slot's nullability" "SELECT V, IIF($a > ?, 'y', 'n') $G V ORDER BY V" '[0]'
done
both "5 IIF(COUNT(*) > ?) with no GROUP BY"       "SELECT IIF(COUNT(*) > ?, 'many', 'one') FROM T" '[2]'
both "5 CASE WHEN COUNT(*) > ? .. END"            "SELECT V, CASE WHEN COUNT(*) > ? THEN 1 END $G V ORDER BY V" '[0]'
both "5 HAVING IIF(COUNT(*) > ?, 1, 0) = 1"       "SELECT V $G V HAVING IIF(COUNT(*) > ?, 1, 0) = 1 ORDER BY V" '[0]'
# RECORDED
dml_refused "5 IIF(ID > ?) .. WHERE V LIKE ? - K1: a classic text pattern beside a numeric condition slot" "SELECT ID, IIF(ID > ?, 'y', 'n') FROM T WHERE V LIKE ? GROUP BY ID ORDER BY ID" '[1,"1%"]'
dml_refused "5 IIF(ID > ?, ?, 'n') .. GROUP BY ID - a BRANCH ?" "SELECT ID, IIF(ID > ?, ?, 'n') $G ID ORDER BY ID" '[1,"q"]'

# ---------------------------------------------------------------
echo "--- 6 a SELECT-LIST subquery carrying the statement's ?s"
# Every select-list subquery with a `?` refused: the projection router
# registered its subqueries with no statement slot to number from.  When
# the subquery's text holds EVERY `?` of the body, its first slot is the
# body's own first and nothing else moves - so it now numbers from there,
# and its slots are published past the projection's re-plan.  A `?`
# outside it as well is a numbering slice of its own (recorded).
R="FROM RDB\$DATABASE"
both "6 (SELECT COUNT(*) .. WHERE T2.ID > ?)"          "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?) FROM T ORDER BY ID" '[1]'
both "6 .. two slots in the body"                     "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.ID > ? AND T2.V LIKE ?) FROM T ORDER BY ID" '[1,"1%"]'
both "6 .. correlated, T2.ID > T.ID AND T2.ID < ?"    "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.ID > T.ID AND T2.ID < ?) FROM T ORDER BY ID" '[3]'
both "6 (SELECT MAX(T2.V) .. LIKE ?)"                 "SELECT ID, (SELECT MAX(T2.V) FROM T T2 WHERE T2.V LIKE ?) FROM T ORDER BY ID" '["1%"]'
both "6 (SELECT IIF(T.V LIKE ?, 1, 0) $R)"            "SELECT ID, (SELECT IIF(T.V LIKE ?, 1, 0) $R) FROM T ORDER BY ID" '["1%"]'
both "6 (SELECT IIF(T.ID > ?, 1, 0) $R)"              "SELECT ID, (SELECT IIF(T.ID > ?, 1, 0) $R) FROM T ORDER BY ID" '[1]'
both "6 (SELECT CHAR_LENGTH(IIF(T.ID > ?, ..)) $R) - the pad counts" "SELECT ID, (SELECT CHAR_LENGTH(IIF(T.ID > ?, 'big', 's')) $R) FROM T ORDER BY ID" '[1]'
both "6 .. T2.N382 LIKE ? - the non-text spelling"    "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.N382 LIKE ?) FROM T ORDER BY ID" '["1%"]'
both "6 (SELECT FIRST 1 T2.V .. T2.ID = ?)"           "SELECT ID, (SELECT FIRST 1 T2.V FROM T T2 WHERE T2.ID = ?) FROM T ORDER BY ID" '[2]'
both "6 .. [NULL]"                                    "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?) FROM T ORDER BY ID" '[null]'
both "6 .. T2.V = ? - a text slot"                    "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.V = ?) FROM T ORDER BY ID" '["10.00"]'
both "6 .. T2.DP > ? - a DOUBLE slot"                 "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.DP > ?) FROM T ORDER BY ID" '[1.5]'
both "6 EXISTS(SELECT 1 .. T2.ID > ?) as an item"     "SELECT ID, EXISTS(SELECT 1 FROM T T2 WHERE T2.ID > ?) FROM T ORDER BY ID" '[2]'
both "6 (SELECT ..) + 1 - inside arithmetic"          "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?) + 1 FROM T ORDER BY ID" '[1]'
both "6 .. $R"                                         "SELECT (SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?) $R" '[0]'
both "6 .. beside a ?-free WHERE"                      "SELECT ID, (SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?) FROM T WHERE ID > 1 ORDER BY ID" '[1]'
# INTERLEAVED: the subquery's slots sit among the statement's in TEXT
# ORDER - the projection's renumbering lets a folded subquery consume its
# own count (COUNT_SUBQ_SLOTS).  The binds are chosen so a swapped slot
# changes the answer: [0,2] is the subquery's 0 and the WHERE's 2.
C="(SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?)"
both "6 .. and a WHERE ? [1,1]"             "SELECT ID, $C FROM T WHERE ID > ? ORDER BY ID" '[1,1]'
both "6 .. and a WHERE ? [0,2] - the order discriminates" "SELECT ID, $C FROM T WHERE ID > ? ORDER BY ID" '[0,2]'
both "6 a pattern ? BEFORE the subquery"    "SELECT ID, IIF(V LIKE ?, 1, 0), $C FROM T ORDER BY ID" '["1%",1]'
both "6 a pattern ? AFTER the subquery"     "SELECT ID, $C, IIF(V LIKE ?, 1, 0) FROM T ORDER BY ID" '[1,"1%"]'
both "6 two subqueries with a ? each"       "SELECT ID, $C, (SELECT COUNT(*) FROM T T3 WHERE T3.ID < ?) FROM T ORDER BY ID" '[1,3]'
both "6 two subqueries and a WHERE ?"       "SELECT ID, $C, (SELECT COUNT(*) FROM T T3 WHERE T3.ID < ?) FROM T WHERE ID <> ? ORDER BY ID" '[1,3,2]'
both "6 .. and a WHERE pattern ?"           "SELECT ID, $C FROM T WHERE V LIKE ? ORDER BY ID" '[1,"1%"]'
both "6 .. and a WHERE IN-subquery's ?"     "SELECT ID, $C FROM T WHERE ID IN (SELECT T4.ID FROM T T4 WHERE T4.ID > ?) ORDER BY ID" '[1,1]'
both "6 .. and two WHERE ?s"                "SELECT ID, $C FROM T WHERE ID > ? AND V LIKE ? ORDER BY ID" '[1,1,"1%"]'
both "6 a UNION ALL, a subquery ? in each branch" "SELECT ID, $C FROM T WHERE ID = 1 UNION ALL SELECT ID, (SELECT COUNT(*) FROM T T3 WHERE T3.ID < ?) FROM T WHERE ID = 3" '[0,3]'
both "6 a UNION ALL, the second branch's WHERE ?" "SELECT ID, $C FROM T WHERE ID = 1 UNION ALL SELECT ID, 0 FROM T WHERE ID > ?" '[0,2]'
both "6 a derived table's item, and the outer WHERE ?" "SELECT d.ID, d.K FROM (SELECT ID, $C AS K FROM T) d WHERE d.ID > ? ORDER BY 1" '[0,1]'
both "6 a CTE's item, and the outer WHERE ?" "WITH c AS (SELECT ID, $C AS K FROM T) SELECT ID, K FROM c WHERE ID > ? ORDER BY ID" '[0,1]'
# RECORDED: K1's numeric mix, a repeated or overlapping subquery text (its
# position is ambiguous - refused rather than risk a swapped slot), a
# `FIRST ?`, and a second UNION branch after a first one's WHERE `?`
dml_refused "6 .. and a NUMERIC condition ? - K1"       "SELECT ID, IIF(ID > ?, 1, 0), $C FROM T ORDER BY ID" '[1,1]'
dml_refused "6 the SAME subquery text twice"            "SELECT ID, $C, $C FROM T ORDER BY ID" '[1,2]'
# PROMOTED 2026-10-03: a bound row window answers (serve-real-boundwindow.sh)
both "6 FIRST ? ahead of the select list"               "SELECT FIRST ? ID, $C FROM T ORDER BY ID" '[2,1]'
dml_refused "6 a UNION's second branch after a WHERE ?" "SELECT ID, 0 FROM T WHERE ID > ? UNION ALL SELECT ID, (SELECT COUNT(*) FROM T T3 WHERE T3.ID < ?) FROM T WHERE ID = 3" '[2,3]'

# ---------------------------------------------------------------
echo "--- 7 a DML WHERE's subquery carrying a ? (rolled back)"
# UPDATE / DELETE lift their WHERE's subqueries exactly as a SELECT does,
# but registered them with no slot to number from: every one with a `?`
# refused.  They now number from where the statement has reached (the SET
# list's lead), publishing ONLY this call's claims - a DML plan does not
# clear the registry (corr_claimed_mark / corr_claimed_since).
M="(SELECT MIN(T2.ID) FROM T T2 WHERE T2.ID > ?)"
dml "7 UPDATE .. WHERE ID = <subquery ?>"           "UPDATE U SET TAG = 'x' WHERE ID = $M RETURNING ID" '[1]'
dml "7 UPDATE SET TAG = ? .. WHERE ID = <subquery ?> [zz,1]" "UPDATE U SET TAG = ? WHERE ID = $M RETURNING ID, TAG" '["zz",1]'
dml "7 ..[zz,0] - the order discriminates"          "UPDATE U SET TAG = ? WHERE ID = $M RETURNING ID, TAG" '["zz",0]'
dml "7 UPDATE .. WHERE ID > ? AND ID IN (<subquery ?>)" "UPDATE U SET TAG = 'x' WHERE ID > ? AND ID IN (SELECT T2.ID FROM T T2 WHERE T2.ID < ?) RETURNING ID" '[1,3]'
dml "7 UPDATE .. WHERE ID IN (<subquery ?>) AND ID > ?" "UPDATE U SET TAG = 'x' WHERE ID IN (SELECT T2.ID FROM T T2 WHERE T2.ID < ?) AND ID > ? RETURNING ID" '[3,1]'
dml "7 DELETE .. WHERE ID = <subquery ?>"           "DELETE FROM U WHERE ID = $M RETURNING ID" '[1]'
dml "7 DELETE .. WHERE ID IN (.. T2.N382 LIKE ?) - the non-text spelling" "DELETE FROM U WHERE ID IN (SELECT T2.ID FROM T T2 WHERE T2.N382 LIKE ?) RETURNING ID" '["1%"]'
dml "7 DELETE .. WHERE EXISTS(.. T2.ID > ?) - correlated" "DELETE FROM U WHERE EXISTS(SELECT 1 FROM T T2 WHERE T2.ID = U.ID AND T2.ID > ?) RETURNING ID" '[1]'
dml         "7 DELETE .. WHERE ID = <subquery ?> [NULL] - no row" "DELETE FROM U WHERE ID = $M RETURNING ID" '[null]'
dml "7 INSERT .. SELECT <select-list subquery ?>"   "INSERT INTO U (ID, TAG) SELECT ID + 10, (SELECT MAX(T2.V) FROM T T2 WHERE T2.ID < ?) FROM T RETURNING ID, TAG" '[3]'
# AN UPDATE SET VALUE's lone subquery holding every `?` of the value
# numbers them from where the SET list has reached (LIFT_PARAM_BASE, lent
# by plan_update alone) and publishes only its own claims.
X="(SELECT MAX(T2.V) FROM T T2 WHERE T2.ID < ?)"
K="(SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?)"
dml "7 UPDATE SET TAG = (<subquery ?>) [3]"         "UPDATE U SET TAG = $X WHERE ID = 1 RETURNING TAG" '[3]'
dml "7 ..[2]"                                       "UPDATE U SET TAG = $X WHERE ID = 1 RETURNING TAG" '[2]'
dml "7 UPDATE SET ID = (<subquery ?>) WHERE ID = ? [1,2]" "UPDATE U SET ID = $K WHERE ID = ? RETURNING ID" '[1,2]'
dml "7 ..[2,1] - the order discriminates"           "UPDATE U SET ID = $K WHERE ID = ? RETURNING ID" '[2,1]'
dml "7 SET TAG = ?, ID = (<subquery ?>)"            "UPDATE U SET TAG = ?, ID = $K WHERE ID = 1 RETURNING ID, TAG" '["q",0]'
dml "7 SET ID = (<subquery ?>), TAG = ?"            "UPDATE U SET ID = $K, TAG = ? WHERE ID = 1 RETURNING ID, TAG" '[0,"q"]'
dml "7 SET TAG = (SELECT CHAR_LENGTH(IIF(U.ID > ?, ..)) ..)" "UPDATE U SET TAG = (SELECT CHAR_LENGTH(IIF(U.ID > ?, 'big', 's')) FROM RDB\$DATABASE) WHERE ID = 1 RETURNING TAG" '[0]'
dml "7 SET TAG = <correlated subquery ?> - every row" "UPDATE U SET TAG = (SELECT MAX(T2.V) FROM T T2 WHERE T2.ID = U.ID AND T2.ID < ?) RETURNING ID, TAG" '[3]'
dml "7 SET TAG = (<subquery ?>) [NULL]"             "UPDATE U SET TAG = $X WHERE ID = 1 RETURNING TAG" '[null]'
dml "7 SET TAG = COALESCE((<subquery ?>), 'none')"  "UPDATE U SET TAG = COALESCE($X, 'none') WHERE ID = 1 RETURNING TAG" '[0]'
dml "7 SET ID = 10 + (<subquery ?>)"                "UPDATE U SET ID = 10 + $K WHERE ID = 1 RETURNING ID" '[1]'
# RECORDED: a `?` beside the subquery in the same value, and an INSERT's VALUES
dml_refused "7 SET ID = ? + (<subquery ?>)"         "UPDATE U SET ID = ? + $K WHERE ID = 1 RETURNING ID" '[10,1]'
# AN INSERT's VALUES with a subquery `?`: the engine's row is exactly the
# one `SELECT <values> FROM RDB$DATABASE` makes, so such a list is planned
# as that INSERT .. SELECT - when every `?` sits inside a subquery and no
# DEFAULT is written.  Compared by READ-BACK (see qrb).
RB="SELECT ID, TAG FROM U ORDER BY ID"
I="INSERT INTO U (ID, TAG) VALUES"
dml_rb "7 VALUES ((<sub ?>), 'n')"          "$I ($K, 'n')" '[1]' "$RB"
dml_rb "7 VALUES (7, (<sub ?>))"            "$I (7, $X)" '[3]' "$RB"
dml_rb "7 VALUES (7, (<sub ?> - no row))"   "$I (7, (SELECT T2.V FROM T T2 WHERE T2.ID > ?))" '[5]' "$RB"
dml_rb "7 VALUES (7 + (<sub ?>), 'n')"      "$I (7 + $K, 'n')" '[1]' "$RB"
dml_rb "7 VALUES ((<sub ?>), (<sub ?>))"    "$I ($K, $X)" '[1,3]' "$RB"
dml_rb "7 VALUES with the columns reordered" "INSERT INTO U (TAG, ID) VALUES ($X, 5)" '[3]' "$RB"
dml_rb "7 VALUES with no column list"       "INSERT INTO U VALUES ($K, 'n')" '[1]' "$RB"
dml_rb "7 VALUES (.., 'it''s') - a quote"   "$I ($K, 'it''s')" '[1]' "$RB"
dml_rb "7 VALUES ((<sub ?>), 'n') [NULL]"   "$I ($K, 'n')" '[null]' "$RB"
dml_rb "7 VALUES ((<sub ?>), (<sub LIKE ?>))" "$I ((SELECT COUNT(*) FROM T T2 WHERE T2.ID > ?), (SELECT FIRST 1 T2.V FROM T T2 WHERE T2.V LIKE ?))" '[0,"10%"]' "$RB"
# RECORDED: a bare value `?` beside it (typed from its target), a DEFAULT
dml_rb_refused "7 VALUES (?, (<sub ?>)) - a bare value ?" "$I (?, $X)" '[8,3]' "$RB"
dml_rb_refused "7 VALUES ((<sub ?>), DEFAULT)"           "$I ($K, DEFAULT)" '[1]' "$RB"

# ---------------------------------------------------------------
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-inselcond-$PORT.log"; then
    echo "FAIL the server PANICKED"; sed -n '/panicked at/,+3p' "/tmp/fc-serve-inselcond-$PORT.log" | sed 's/^/   /'; fail=1
elif ! kill -0 $srv 2>/dev/null; then
    echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi

echo "ran $ran checks"
# the floor is the MEASURED count: 168 on the 2026-10-03 binary, 168 OK
if [ "$ran" -lt 168 ]; then echo "FAIL only $ran checks ran (floor 168) - cells went missing"; fail=1; fi
exit $fail
