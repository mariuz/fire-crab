#!/bin/bash
# A `?` PARAMETER INSIDE A DML VALUE EXPRESSION - `INSERT ... VALUES (?
# + 1)`, `UPDATE ... SET N = ? * 2`, `SET S = 'x' || ?`, `SET N =
# CAST(? AS INTEGER)`. A parameter standing ALONE has always worked; one
# inside an expression refused, which is most of what a prepared
# statement does with arithmetic.
#
# The feature is really the TYPE the parameter is described with, and
# the engine's rule is not the obvious one. Read off its own input SQLDA
# (`SET SQLDA_DISPLAY ON` prints it even for a statement isql cannot
# then execute):
#
#   * a parameter inside an assignment takes the DESTINATION COLUMN's
#     descriptor, whatever operators stand between them - `SET NM = ? *
#     2` over a NUMERIC(9,2) describes the parameter as that NUMERIC,
#     not as the literal 2's INTEGER; `SET D = ? + 1` is a DATE;
#     `SET S = SUBSTRING(? FROM 1 FOR 2)` is S's VARCHAR(20)
#   * a CAST types its own operand instead - `SET NM = CAST(? AS
#     VARCHAR(5))` is a VARYING(5)
#   * COALESCE types its parameter from its OTHER ARGUMENTS and only
#     from them - `SET NM = COALESCE(?, 0)` is a plain INTEGER, where
#     `SET NM = CASE WHEN ... THEN ? ELSE 0 END` is NM's NUMERIC
#   * the slots are numbered in SOURCE order: the SET list left to
#     right, then the WHERE
#
# Both halves are measured: the INPUT SQLDA (isql, both servers) and the
# VALUES a bound execution stores (node-firebird, both servers, same
# arguments, and the table compared afterwards).
#
# Boundaries (recorded, all refuse rather than answer): a parameter in a
# CASE/IIF CONDITION (typed from the other side of the compare - a
# different rule), a COALESCE whose arguments are ALL parameters (the
# engine's -804), a parameter expression into a BLOB column, and a bare
# `?` in a select list (-804 on the engine too, generic here).
#
#   qa/serve-real-dmlparamexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4927}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-dmlparam-crab.fdb"
B="$D/fc-dmlparam-engine.fdb"
LOG="/tmp/fc-serve-dmlparam-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER, N INTEGER, S VARCHAR(20), D DATE, NM NUMERIC(9,2), BG BIGINT, B BLOB SUB_TYPE TEXT);
COMMIT;
INSERT INTO T (ID, N, S, D, NM, BG) VALUES (1, 10, 'aa', '2020-06-15', 12.55, 100);
INSERT INTO T (ID, N, S, D, NM, BG) VALUES (2, 20, 'bb', '2021-07-16', -3.40, 200);
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

# ---- the INPUT SQLDA: what each parameter is described as --------------
# isql cannot EXECUTE a statement with parameters, but it prints the
# input message it prepared - which is the whole type story
sqlda() { # <conn> <sql>
    printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -a -E 'INPUT message|^[0-9][0-9]: sqltype' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'
}
desc() { # <label> <sql>
    e=$(sqlda "127.0.0.1/$REAL:$B" "$2")
    c=$(sqlda "127.0.0.1/$PORT:$A" "$2")
    check "$1" "$c" "$e"
}
desc "the destination types the parameter, through arithmetic" \
  "UPDATE T SET N = ? * 2 WHERE ID = 1;"
desc "... and through a NUMERIC destination, which is the telling one" \
  "UPDATE T SET NM = ? * 2 WHERE ID = 1;"
desc "... a DATE destination, and a BIGINT one" \
  "UPDATE T SET D = ? + 1 WHERE ID = 1; UPDATE T SET BG = ? + 1 WHERE ID = 1;"
desc "... a text destination through concatenation and a function" \
  "UPDATE T SET S = 'x' || ? WHERE ID = 1; UPDATE T SET S = SUBSTRING(? FROM 1 FOR 2) WHERE ID = 1;"
desc "... nested, negated, and in a CASE branch" \
  "UPDATE T SET N = (? + 1) * 2 - 3 WHERE ID = 1; UPDATE T SET N = -? WHERE ID = 1; UPDATE T SET NM = CASE WHEN ID > 0 THEN ? ELSE 0 END WHERE ID = 1;"
desc "a CAST types its own operand instead" \
  "UPDATE T SET NM = CAST(? AS VARCHAR(5)) WHERE ID = 1; UPDATE T SET N = CAST(? AS INTEGER) WHERE ID = 1;"
desc "COALESCE types it from its OTHER arguments, not the destination" \
  "UPDATE T SET NM = COALESCE(?, 0) WHERE ID = 1; UPDATE T SET NM = COALESCE(?, 1.5) WHERE ID = 1; UPDATE T SET S = COALESCE(?, 5) WHERE ID = 1;"
desc "NULLIF and IIF take the destination" \
  "UPDATE T SET NM = NULLIF(?, 0) WHERE ID = 1; UPDATE T SET NM = IIF(ID > 0, ?, 0) WHERE ID = 1;"
desc "the slots are numbered SET-list first, then the WHERE" \
  "UPDATE T SET N = ? + 1, S = ? WHERE ID = ?;"
desc "an INSERT's value list, per column" \
  "INSERT INTO T (ID, N) VALUES (?, ? + 1); INSERT INTO T (ID, S) VALUES (1, UPPER(?)); INSERT INTO T VALUES (?, ? + 1, ?, ?, ?, ?, NULL);"

# ---- the VALUES a bound execution stores -------------------------------
if command -v node >/dev/null 2>&1 && node -e "require('node-firebird')" 2>/dev/null; then
    q() { # <port> <db> <sql> <json args>
        FC_Q="$3" FC_PARAMS="$4" FC_PORT="$1" FC_DB="$2" timeout 25 node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,JSON.parse(process.env.FC_PARAMS),(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null
    }
    bound() { # <label> <sql> <json args>
        e=$(q "$REAL" "$B" "$2" "$3")
        c=$(q "$PORT" "$A" "$2" "$3")
        check "$1" "$c" "$e"
    }
    bound "a parameter in arithmetic, in VALUES and in SET" \
      "INSERT INTO T (ID, N) VALUES (10, ? + 1) RETURNING N" '[5]'
    bound "... and in an UPDATE" \
      "UPDATE T SET N = ? * 2 WHERE ID = 1 RETURNING N" '[7]'
    bound "concatenation, a function, and a CAST" \
      "UPDATE T SET S = 'x' || ? WHERE ID = 1 RETURNING S" '["yz"]'
    bound "... under a CAST" \
      "INSERT INTO T (ID, N) VALUES (11, CAST(? AS INTEGER)) RETURNING N" '["42"]'
    bound "several parameters, SET list then WHERE" \
      "UPDATE T SET N = ? + 1, S = ? WHERE ID = ? RETURNING N, S" '[100,"pp",2]'
    bound "a COALESCE and a CASE branch" \
      "UPDATE T SET N = COALESCE(?, 0) WHERE ID = 1 RETURNING N" '[9]'
    bound "... a NULL argument through the same COALESCE" \
      "UPDATE T SET N = COALESCE(?, -1) WHERE ID = 1 RETURNING N" '[null]'
    bound "the whole row from a positional INSERT with an expression" \
      "INSERT INTO T VALUES (?, ? + 1, ?, ?, ?, ? * 2, NULL) RETURNING ID, N, S, NM, BG" '[12,5,"zz","2022-03-04",1.5,50]'
    bound "the table after all of it" "SELECT ID, N, S, D, NM, BG FROM T ORDER BY ID" '[]'
else
    echo "SKIP node-firebird not found (the bound-value checks)"
fi

# ---- the engine reads what fire-crab wrote ------------------------------
eng_q="SET LIST ON; SELECT ID, N, S, D, NM, BG FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | grep -a -v '^$' | tr '\n' '|')
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | grep -a -v '^$' | tr '\n' '|')
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- boundaries ---------------------------------------------------------
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$r" in
        *"Dynamic SQL Error"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     [$r]"; fail=1 ;;
    esac
}
refuses "a parameter in a CASE CONDITION refuses" \
  "UPDATE T SET N = CASE WHEN ID > ? THEN 1 ELSE 0 END WHERE ID = 1;"
refuses "a COALESCE of only parameters refuses (the engine's -804)" \
  "UPDATE T SET N = COALESCE(?, ?) WHERE ID = 1;"
refuses "a parameter expression into a BLOB column refuses" \
  "UPDATE T SET B = ? || 'x' WHERE ID = 1;"
refuses "a bare parameter in a select list refuses (-804 there too)" \
  "SELECT ? + 1 FROM T;"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
