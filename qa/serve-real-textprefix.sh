#!/bin/bash
# A TEXT EXPRESSION's BOUND STARTING WITH / CONTAINING IN A WHERE, UNDER
# ITS OWN COLLATION.
#
# `WHERE UPPER(P) STARTING WITH ?`, `U || '' CONTAINING ?`, `TRIM(U)
# STARTING WITH ?` - every one refused: the predicate world's bound-prefix
# arms admitted a NON-text expression only ("its prefix test is decided by
# the operand's COLLATION, which a value known only at bind cannot be
# wrapped the same way"), and a guard refused any non-comparison predicate
# over an expression reading an ICU-collated column.  But the condition
# world already does exactly that per row - `IIF(U || '' STARTING WITH ?,
# 1, 0)` answered the engine's rows - so the WHERE arms now build the same
# condition (bound_starting_cond / bound_containing_cond) and the guard
# lets those two bound forms through.  LIKE and SIMILAR TO stay guarded.
#
# Measured 2026-10-02 on a UTF8 database: the COLLATION PROPAGATES THROUGH
# THE EXPRESSION (`U || ''` keeps UNICODE_CI, `A || ''` UNICODE_CI_AI - so
# 'é', 'É' and 'e' all take Éclair, eclat and ÉTÉ), the slot is VARYING at
# the expression's width in its charset, and 140 accent / case / collation
# cells agree.
#
# Usage: qa/serve-real-textprefix.sh [port]   (default 4561)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4561}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/textprefix-eng.fdb"; FC="$D/textprefix-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' DEFAULT CHARACTER SET UTF8;"
  cat <<'SQL'
CREATE TABLE W (ID INTEGER, U VARCHAR(10) COLLATE UNICODE_CI, A VARCHAR(10) COLLATE UNICODE_CI_AI,
                P VARCHAR(10), N VARCHAR(10) CHARACTER SET NONE, C CHAR(6) COLLATE UNICODE_CI);
COMMIT;
INSERT INTO W VALUES (1, 'Apple', 'Éclair', 'Apple', 'Apple', 'Ab');
INSERT INTO W VALUES (2, 'apricot', 'eclat', 'apricot', 'apricot', 'ab');
INSERT INTO W VALUES (3, 'BANANA', 'ÉTÉ', 'BANANA', 'BANANA', 'xy');
INSERT INTO W VALUES (4, 'Ärger', 'ärger', 'Ärger', 'x', 'Äb');
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/textprefix-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/textprefix-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/textprefix-build.log; exit 1; }
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-textprefix-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
q() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 25 node -e '
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
# the describe under the SAME attachment charset the driver uses (UTF8) - under
# NONE, `A || '' COLLATE UNICODE` does not even prepare
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" | timeout 25 "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 \
    | tr -d '\r' | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }
# the rows (rolled back) AND the whole describe must match; the engine must answer
both() {
    ran=$((ran + 1))
    local ev fv ed fd
    ev=$(q "$REAL" "$ENG" "$2" "$3"); fv=$(q "$PORT" "$FC" "$2" "$3")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ] || [ -z "$ev" ]; then echo "FAIL $1 [CONN_ERR]"; fail=1
    elif [ "${ev#rows }" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not answer [$ev]"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 [the ENGINE printed no describe]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1 (DESCRIBE)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the engine ANSWERS and this server refuses - a recorded boundary
eng_only() {
    ran=$((ran + 1))
    local ev fv
    ev=$(q "$REAL" "$ENG" "$2" "$3"); fv=$(q "$PORT" "$FC" "$2" "$3")
    if [ "${ev#rows }" = "$ev" ]; then echo "FAIL $1 - the ENGINE no longer answers [$ev]"; fail=1
    elif [ "$fv" != "ERR Dynamic SQL Error" ]; then echo "FAIL $1 - this server moved [$fv] (engine [$ev]); promote if they agree"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}

W="SELECT ID FROM W WHERE"
echo "--- 1 every text-expression shape, both operators, an ASCII needle"
for x in "UPPER(P)" "P || ''" "U || ''" "TRIM(U)" "SUBSTRING(U FROM 1)" "A || ''" "N || ''" "C || ''" "LOWER(U)" "U COLLATE UNICODE" "P COLLATE UNICODE_CI"; do
    both "1 $x STARTING WITH ? ['ap']" "$W $x STARTING WITH ? ORDER BY ID" '["ap"]'
    both "1 $x CONTAINING ? ['AN']"    "$W $x CONTAINING ? ORDER BY ID" '["AN"]'
done

echo "--- 2 the COLLATION decides, per row - accents and case across five collations"
for n in '"é"' '"É"' '"e"' '"ä"' '"Ä"' '"a"' '"ÉT"' '"été"' '"ÄR"' '"rg"'; do
    for x in "U || ''" "A || ''" "P || ''" "UPPER(U)" "C || ''" "A || '' COLLATE UNICODE" "P || '' COLLATE UNICODE_CI_AI"; do
        both "2 $x STARTING WITH ? [$n]" "$W $x STARTING WITH ? ORDER BY ID" "[$n]"
        both "2 $x CONTAINING ? [$n]"    "$W $x CONTAINING ? ORDER BY ID" "[$n]"
    done
done

echo "--- 3 NOT, NULL, an integer bind, wildcards are literal, beside other terms, DML"
both "3 NOT STARTING WITH ?"        "$W U || '' NOT STARTING WITH ? ORDER BY ID" '["ap"]'
both "3 NOT CONTAINING ?"           "$W U || '' NOT CONTAINING ? ORDER BY ID" '["AN"]'
both "3 STARTING WITH ? [NULL]"     "$W U || '' STARTING WITH ? ORDER BY ID" '[null]'
both "3 CONTAINING ? [NULL]"        "$W U || '' CONTAINING ? ORDER BY ID" '[null]'
both "3 STARTING WITH ? [5] - an integer bind" "$W U || '' STARTING WITH ? ORDER BY ID" '[5]'
both "3 CONTAINING ? ['%'] - no wildcard"      "$W U || '' CONTAINING ? ORDER BY ID" '["%"]'
both "3 CONTAINING ? ['_']"                    "$W P || '' CONTAINING ? ORDER BY ID" '["_"]'
both "3 a CHAR expression's pad: CONTAINING ? ['B ']" "$W C || '' CONTAINING ? ORDER BY ID" '["B "]'
both "3 the whole value: STARTING WITH ? ['APPLE']"   "$W U || '' STARTING WITH ? ORDER BY ID" '["APPLE"]'
both "3 .. AND ID > ? - beside a classic slot" "$W UPPER(U) STARTING WITH ? AND ID > ? ORDER BY ID" '["AP",1]'
both "3 .. OR ID = 3"                          "$W U || '' STARTING WITH ? OR ID = 3 ORDER BY ID" '["ap"]'
both "3 UPDATE .. WHERE U || '' STARTING WITH ?" "UPDATE W SET P = 'z' WHERE U || '' STARTING WITH ? RETURNING ID" '["ap"]'
both "3 DELETE .. WHERE A || '' CONTAINING ?"    "DELETE FROM W WHERE A || '' CONTAINING ? RETURNING ID" '["CLA"]'
both "3 CONTROL: the IIF form, which answered before" "$W IIF(U || '' STARTING WITH ?, 1, 0) = 1 ORDER BY ID" '["ap"]'
# RECORDED: LIKE and SIMILAR TO over an ICU-collated expression stay guarded
eng_only "3 U || '' LIKE ? - LIKE stays behind the collation guard" "$W U || '' LIKE ? ORDER BY ID" '["ap%"]'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-textprefix-$PORT.log"; then
    echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 178 on the 2026-10-02 binary, 178 OK
if [ "$ran" -lt 178 ]; then echo "FAIL only $ran checks ran (floor 178) - cells went missing"; fail=1; fi
exit $fail
