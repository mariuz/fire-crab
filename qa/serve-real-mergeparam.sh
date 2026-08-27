#!/bin/bash
# THE MERGE TAILS - parameters anywhere inside a MERGE, and an
# EXPRESSION in its RETURNING list. Both were recorded refusals; the
# executor itself has been wired since the MERGE slice.
#
# A MERGE is executed here by DESUGARING each source row into ordinary
# INSERT/UPDATE/DELETE statements built as TEXT, so a `?` could not ride
# through as a slot - by the time the per-row statement is planned its
# position in the original text is gone, and the whole statement refused
# the moment it carried one. Each `?` becomes a numbered marker at
# prepare instead, typed there and written as its bound literal at
# execute beside the source row's own values.
#
# What is measured against the live engine:
#
#   * the INPUT SQLDA - a parameter in a SET or an INSERT value list
#     takes its DESTINATION COLUMN's descriptor, one compared in the ON
#     clause or a branch's AND takes the column it is compared with, and
#     the slots are numbered in TEXT order
#   * the rows a bound execution moves, and the table afterwards
#   * the same parameter in several places, and a NULL argument
#
# And the RETURNING half: an expression over the row a MERGE moved,
# described exactly as the same expression in a select list, with the
# TWO-CONTEXT rule kept - the target's alias (or `NEW.`) qualifies it,
# a bare name the SOURCE also carries is the engine's 42702 rather than
# a silent pick, and a source column inside the expression refuses.
#
# Boundaries (recorded, all refuse rather than answer): a parameter in
# the USING source query, one compared with the SOURCE's column, one
# standing outside a comparison in a condition, a RETURNING expression
# naming the source, and `ORDER BY`/`PLAN`/`OVERRIDING` on a MERGE
# (unchanged).
#
#   qa/serve-real-mergeparam.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4928}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-mergeparam-crab.fdb"
B="$D/fc-mergeparam-engine.fdb"
LOG="/tmp/fc-serve-mergeparam-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER, N INTEGER, S VARCHAR(20), NM NUMERIC(9,2));
CREATE TABLE SRC (K INTEGER, V INTEGER, W VARCHAR(20));
COMMIT;
INSERT INTO T VALUES (1, 10, 'aa', 1.50);
INSERT INTO T VALUES (2, 20, 'bb', 2.50);
INSERT INTO SRC VALUES (1, 100, 'one');
INSERT INTO SRC VALUES (3, 300, 'three');
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }

# ---- the INPUT SQLDA ----------------------------------------------------
sqlda() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
    grep -a -E 'INPUT message|^[0-9][0-9]: sqltype' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
desc() { e=$(sqlda "127.0.0.1/$REAL:$B" "$2"); c=$(sqlda "127.0.0.1/$PORT:$A" "$2"); check "$1" "$c" "$e"; }

desc "a parameter in the ON clause takes the compared column" \
  "MERGE INTO T tg USING SRC s ON tg.ID = ? WHEN MATCHED THEN UPDATE SET N = 1;"
desc "one in a SET list takes its destination column" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN UPDATE SET N = ?, NM = ?;"
desc "one in an INSERT value list, by position" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN NOT MATCHED THEN INSERT (ID, S) VALUES (?, ?);"
desc "... and with no column list, the relation's own order" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN NOT MATCHED THEN INSERT VALUES (?, ?, ?, ?);"
desc "one in a branch's AND condition" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED AND tg.NM > ? THEN DELETE;"
desc "the slots are numbered in TEXT order across the whole statement" \
  "MERGE INTO T tg USING SRC s ON tg.ID = ? WHEN MATCHED AND tg.S > ? THEN UPDATE SET N = ? WHEN NOT MATCHED THEN INSERT (ID, NM) VALUES (?, ?);"

# ---- what a bound execution moves --------------------------------------
if command -v node >/dev/null 2>&1 && node -e "require('node-firebird')" 2>/dev/null; then
    q() { FC_Q="$3" FC_PARAMS="$4" FC_PORT="$1" FC_DB="$2" timeout 25 node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,JSON.parse(process.env.FC_PARAMS),(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null; }
    bound() { e=$(q "$REAL" "$B" "$2" "$3"); c=$(q "$PORT" "$A" "$2" "$3"); check "$1" "$c" "$e"; }
    bound "a parameter in the ON clause narrows the join" \
      "MERGE INTO T tg USING SRC s ON tg.ID = ? WHEN MATCHED THEN UPDATE SET N = 999" '[1]'
    bound "... the table after it" "SELECT ID, N FROM T ORDER BY ID" '[]'
    bound "parameters in a SET list and a branch condition" \
      "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED AND tg.N > ? THEN UPDATE SET N = ?, S = ?" '[5,42,"pp"]'
    bound "... the table after it" "SELECT ID, N, S FROM T ORDER BY ID" '[]'
    bound "a parameter in an INSERT branch" \
      "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN NOT MATCHED THEN INSERT (ID, N, S, NM) VALUES (s.K, ?, s.W, ?)" '[7,3.25]'
    bound "... the table after it" "SELECT ID, N, S, NM FROM T ORDER BY ID" '[]'
    bound "a NULL argument" \
      "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN UPDATE SET S = ?" '[null]'
    bound "... the table after it" "SELECT ID, S FROM T ORDER BY ID" '[]'
else
    echo "SKIP node-firebird not found (the bound-value checks)"
fi

# ---- an EXPRESSION in a MERGE's RETURNING ------------------------------
mboth() { # <label> <sql>
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|')
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|')
    check "$1" "$c" "$e"
}
mboth "an expression over the moved row, through the target's alias" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN UPDATE SET N = s.V RETURNING tg.N * 2, tg.ID; ROLLBACK;"
mboth "... a bare name only the target carries, and NEW." \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN UPDATE SET S = s.W RETURNING UPPER(S), NEW.N + 1; ROLLBACK;"
mboth "... a CAST, a CASE and a constant" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN UPDATE SET N = 5 RETURNING CAST(tg.N AS VARCHAR(4)), CASE WHEN tg.N > 1 THEN 'big' ELSE 'small' END, 1; ROLLBACK;"
mboth "... over an INSERT branch, and over the BY SOURCE pass" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN NOT MATCHED THEN INSERT (ID, N) VALUES (s.K, s.V) RETURNING tg.ID, tg.N * 10; ROLLBACK; MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN NOT MATCHED BY SOURCE THEN UPDATE SET N = 0 RETURNING tg.ID, tg.N + 1; ROLLBACK;"
mboth "... an alias renames it, and the describe names the operator" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN UPDATE SET N = 3 RETURNING tg.N * 2 AS DOUBLED; ROLLBACK;"

# ---- the engine reads what fire-crab wrote ------------------------------
eng_q="SET LIST ON; SELECT ID, N, S, NM FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | grep -a -v '^$' | tr '\n' '|')
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | grep -a -v '^$' | tr '\n' '|')
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- boundaries ---------------------------------------------------------
refuses() { ran=$((ran + 1))
    r=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$r" in
        *"Dynamic SQL Error"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     [$r]"; fail=1 ;;
    esac
}
refuses "a parameter in the USING source refuses" \
  "MERGE INTO T tg USING (SELECT ? AS K FROM RDB\$DATABASE) s ON tg.ID = s.K WHEN MATCHED THEN DELETE;"
refuses "one compared with the SOURCE's column refuses" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED AND s.V > ? THEN DELETE;"
refuses "one outside a comparison refuses" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED AND ? THEN DELETE;"
refuses "a RETURNING expression naming the SOURCE refuses" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN UPDATE SET N = 1 RETURNING s.V * 2;"
refuses "ORDER BY on a MERGE still refuses" \
  "MERGE INTO T tg USING SRC s ON tg.ID = s.K WHEN MATCHED THEN DELETE ORDER BY 1;"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
