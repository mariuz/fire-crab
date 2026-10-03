#!/bin/bash
# A ROW WINDOW COUNTED BY `?` - `FIRST ?`, `FIRST (?)`, `SKIP ?`, `ROWS ?
# [TO ?]`, `OFFSET ? ROWS`, `FETCH {FIRST|NEXT} ? ROWS ONLY` - the
# parameterised pagination every application writes.
#
# Every one refused at prepare (`FIRST (?)` answered -804 Function unknown,
# reading FIRST as a call). Now the statement plans with a placeholder count
# and the BOUND counts replace it at each execute. Measured on 6.0.0.2196:
#   - each window parameter is described INT64 NOT NULL, the head's (FIRST,
#     SKIP) before every other parameter, the tail's after;
#   - a NULL binds anyway: a NULL count delivers no row, a NULL skip skips
#     none; `ROWS m TO n` is FIRST n - m + 1, SKIP m - 1, NULL if either is;
#   - a negative count raises isc_bad_limit_param, a negative skip
#     isc_bad_skip_param, the count judged first; a fractional count rounds,
#     a text one converts.
#
#   qa/serve-real-boundwindow.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4600}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/bwin-eng.fdb"; FC="$D/bwin-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE T (ID INTEGER, V VARCHAR(10));
INSERT INTO T VALUES (1, 'a');
INSERT INTO T VALUES (2, 'b');
INSERT INTO T VALUES (3, 'c');
INSERT INTO T VALUES (4, 'b');
INSERT INTO T VALUES (5, 'e');
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/bwin-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/bwin-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-bwin-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
# each argument list in $3.. runs in turn on ONE connection (node-firebird
# keeps the prepared statement, so a second list re-executes the handle)
q() { FC_PORT="$1" FC_DB="$2" FC_Q="$3" FC_PS="$4" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const lists=JSON.parse(process.env.FC_PS);
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    const out=[];
    const next=(k)=>{
      if(k>=lists.length){console.log(out.join(" / "));db.detach();process.exit(0);}
      db.query(process.env.FC_Q,lists[k],(e2,r)=>{
        out.push(e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("ok "+((!r||!r.length)?"(none)":r.map(x=>Object.values(x).join()).join(";"))));
        next(k+1);
      });
    };
    next(0);
  });' 2>/dev/null; }
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -aE 'INPUT|^0[0-9]: sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }
both() { # <label> <sql> <json list of argument lists>
    ran=$((ran + 1))
    local ev fv ed fd
    ev=$(q "$REAL" "$ENG" "$2" "$3"); fv=$(q "$PORT" "$FC" "$2" "$3")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ] || [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then echo "FAIL $1 [the cell never ran: eng=$ev]"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 [the ENGINE printed no describe]"; fail=1
    elif [ "$ev" != "$fv" ]; then echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1 (DESCRIBE)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}

echo "--- 1 every form, a parameter around it, and a re-execute of the handle"
both "1 FIRST ?"                        "SELECT FIRST ? ID FROM T ORDER BY ID" '[[2],[4]]'
both "1 FIRST (?)"                      "SELECT FIRST (?) ID FROM T ORDER BY ID" '[[2],[1]]'
both "1 SKIP ?"                         "SELECT SKIP ? ID FROM T ORDER BY ID" '[[3],[0]]'
both "1 FIRST ? SKIP ?"                 "SELECT FIRST ? SKIP ? ID FROM T ORDER BY ID" '[[2,1],[1,3]]'
both "1 FIRST 2 SKIP ? - a literal beside" "SELECT FIRST 2 SKIP ? ID FROM T ORDER BY ID" '[[1]]'
both "1 ROWS ?"                         "SELECT ID FROM T ORDER BY ID ROWS ?" '[[2],[5]]'
both "1 ROWS ? TO ?"                    "SELECT ID FROM T ORDER BY ID ROWS ? TO ?" '[[2,3],[4,9]]'
both "1 OFFSET ? ROWS"                  "SELECT ID FROM T ORDER BY ID OFFSET ? ROWS" '[[3]]'
both "1 OFFSET ? FETCH NEXT ?"          "SELECT ID FROM T ORDER BY ID OFFSET ? ROWS FETCH NEXT ? ROWS ONLY" '[[1,2],[3,1]]'
both "1 FETCH FIRST ? ROWS ONLY"        "SELECT ID FROM T ORDER BY ID FETCH FIRST ? ROWS ONLY" '[[3]]'
both "1 head ? before a WHERE ?"        "SELECT FIRST ? ID FROM T WHERE ID > ? ORDER BY ID" '[[2,1],[1,3]]'
both "1 a select-list ? between"        "SELECT FIRST ? SKIP ? ID, CAST(? AS INTEGER) AS C FROM T ORDER BY ID" '[[1,1,7]]'
both "1 tail ? after a WHERE ?"         "SELECT ID FROM T WHERE ID > ? ORDER BY ID ROWS ? TO ?" '[[1,1,2]]'
both "1 FIRST ? DISTINCT"               "SELECT FIRST ? DISTINCT V FROM T ORDER BY V" '[[2]]'
both "1 a UNION's ROWS ?"               "SELECT ID FROM T UNION ALL SELECT 9 FROM RDB\$DATABASE ROWS ?" '[[2]]'
both "1 FIRST ? over a GROUP BY"        "SELECT FIRST ? V, COUNT(*) FROM T GROUP BY V ORDER BY V" '[[2]]'

echo "--- 2 NULL, negative, fractional, text counts"
both "2 FIRST NULL - no row"            "SELECT FIRST ? ID FROM T ORDER BY ID" '[[null]]'
both "2 SKIP NULL - none skipped"       "SELECT SKIP ? ID FROM T ORDER BY ID" '[[null]]'
both "2 ROWS NULL"                      "SELECT ID FROM T ORDER BY ID ROWS ?" '[[null]]'
both "2 ROWS NULL TO 2, 2 TO NULL"      "SELECT ID FROM T ORDER BY ID ROWS ? TO ?" '[[null,2],[2,null]]'
both "2 FETCH NULL, OFFSET NULL"        "SELECT ID FROM T ORDER BY ID OFFSET ? ROWS FETCH NEXT ? ROWS ONLY" '[[null,2],[1,null]]'
both "2 FIRST -1"                       "SELECT FIRST ? ID FROM T ORDER BY ID" '[[-1]]'
both "2 SKIP -1"                        "SELECT SKIP ? ID FROM T ORDER BY ID" '[[-1]]'
both "2 both negative: FIRST's raise"   "SELECT FIRST ? SKIP ? ID FROM T ORDER BY ID" '[[-1,-1]]'
both "2 ROWS 3 TO 2 - empty"            "SELECT ID FROM T ORDER BY ID ROWS ? TO ?" '[[3,2]]'
both "2 ROWS 0 TO 2 - SKIP's raise"     "SELECT ID FROM T ORDER BY ID ROWS ? TO ?" '[[0,2]]'
both "2 ROWS 5 TO 2 - FIRST's raise"    "SELECT ID FROM T ORDER BY ID ROWS ? TO ?" '[[5,2]]'
both "2 OFFSET -1"                      "SELECT ID FROM T ORDER BY ID OFFSET ? ROWS" '[[-1]]'
both "2 FETCH -1"                       "SELECT ID FROM T ORDER BY ID FETCH FIRST ? ROWS ONLY" '[[-1]]'
both "2 a fractional count rounds"      "SELECT FIRST ? ID FROM T ORDER BY ID" '[[1.7],[2.4]]'
both "2 a text count converts"          "SELECT FIRST ? ID FROM T ORDER BY ID" '[["2"]]'
both "2 a raise then a good execute"    "SELECT FIRST ? ID FROM T ORDER BY ID" '[[-1],[2]]'

echo "--- 3 CONTROLS - literal windows are as they were"
both "3 FIRST 2"                        "SELECT FIRST 2 ID FROM T ORDER BY ID" '[[]]'
both "3 ROWS 2 TO 3"                    "SELECT ID FROM T ORDER BY ID ROWS 2 TO 3" '[[]]'
both "3 no window, a WHERE ?"           "SELECT ID FROM T WHERE ID > ? ORDER BY ID" '[[3]]'

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-bwin-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 36 on the 2026-10-03 binary, 36 OK
if [ "$ran" -lt 36 ]; then echo "FAIL only $ran checks ran (floor 36) - cells went missing"; fail=1; fi
exit $fail
