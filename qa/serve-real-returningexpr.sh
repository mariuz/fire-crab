#!/bin/bash
# `<dml> ... RETURNING <EXPRESSION>` - the other half of a DML value.
#
# The RETURNING list took plain column references only; every expression
# there refused, which is most of what the clause is asked for
# (`RETURNING ID + 1`, `RETURNING CAST(B AS VARCHAR(30))`, `RETURNING
# UPPER(S) AS U`). The engine takes any VALUE EXPRESSION, describes it
# exactly as it describes the same expression in a select list, and
# evaluates it over the row the statement wrote - the after-image for an
# INSERT or UPDATE, the row as it was for a DELETE.
#
# What is measured here, against the live engine as a twin:
#
#   * the VALUES, over each verb, mixed with plain columns
#   * the DESCRIBE (SQLDA_DISPLAY): the type and width the select list
#     would announce, and the UN-ALIASED NAME the engine gives an
#     expression - `MULTIPLY`, `ADD`, `CONCATENATION`, `CAST`, `CASE`,
#     `UPPER` - with an explicit alias overwriting it
#   * a DELETE's expression reads the OLD row, an UPDATE's the NEW one
#   * the singleton path a driver takes for `INSERT ... RETURNING`
#     (statement type 8, the value read straight off op_sql_response,
#     never a cursor) carries expression columns too
#
# Boundaries (recorded, all refuse rather than answer): an expression
# over a COMPUTED column (these rows are decoded from the STORED image,
# where a computed column's descriptor sits over the null flags - the
# bare column already refused for that reason), an aggregate, a
# subquery, and a parameter.
#
#   qa/serve-real-returningexpr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4925}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-retexpr-crab.fdb"
B="$D/fc-retexpr-engine.fdb"
LOG="/tmp/fc-serve-retexpr-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
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
norm() { grep -a -v '^$' | sed 's/[0-9a-f][0-9a-f]*:[0-9a-f][0-9a-f]*/BLOBID/g' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
bothd() {
    e=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a -E 'sqltype|name:' | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a -E 'sqltype|name:' | norm)
    check "$1" "$c" "$e"
}
mk() { cat <<'SQL'
CREATE TABLE T (ID INTEGER, N INTEGER, S VARCHAR(20), D DATE, NM NUMERIC(9,2), B BLOB SUB_TYPE TEXT);
CREATE TABLE C (ID INTEGER, A INTEGER, CC COMPUTED BY (A * 10));
COMMIT;
INSERT INTO T VALUES (1, 10, 'aa', '2020-06-15', 12.55, 'blob one');
INSERT INTO T VALUES (2, 20, 'bb', '2021-07-16', -3.40, NULL);
INSERT INTO T VALUES (3, NULL, NULL, NULL, NULL, NULL);
INSERT INTO C VALUES (1, 4);
COMMIT;
SQL
}
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
mk | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1
both "the rows landed the same on both sides" \
  "SELECT ID, N, S, D, NM FROM T ORDER BY ID;"

# ---- the values, per verb -----------------------------------------------
both "INSERT RETURNING an expression, and one beside a plain column" \
  "INSERT INTO T (ID, N, S) VALUES (10, 5, 'ten') RETURNING N * 2; INSERT INTO T (ID, N, S) VALUES (11, 6, 'ele') RETURNING ID, N + 1, UPPER(S);"
both "UPDATE RETURNING reads the NEW row" \
  "UPDATE T SET N = 100 WHERE ID = 1 RETURNING N * 2, N - 1; COMMIT; SELECT N FROM T WHERE ID = 1;"
both "DELETE RETURNING reads the row as it WAS" \
  "DELETE FROM T WHERE ID = 11 RETURNING ID, N + 1, S || '!';"
both "several rows, an expression per row" \
  "UPDATE T SET N = COALESCE(N, 0) + 1 WHERE ID <= 3 RETURNING ID, N * 10; COMMIT;"
both "every expression family over the written row" \
  "UPDATE T SET N = 7, S = 'gg', NM = 2.50 WHERE ID = 2 RETURNING N * 2, S || '-x', NM * 2, CAST(N AS VARCHAR(4)), COALESCE(S, 'none'), CASE WHEN N > 5 THEN 'big' ELSE 'small' END, D + 1, UPPER(S), SUBSTRING(S FROM 1 FOR 1), N / 2, -N;"
both "a constant, and a text blob through a cast" \
  "UPDATE T SET B = 'written' WHERE ID = 1 RETURNING 1, 'lit', CAST(B AS VARCHAR(30)), CHAR_LENGTH(B);"
both "an alias overwrites the name, and the NULL row answers NULL" \
  "UPDATE T SET N = NULL WHERE ID = 3 RETURNING N * 2 AS DOUBLED, COALESCE(N, -1) AS FILLED, S || 'x' AS TAIL;"

both "a literal keyword, a decimal constant and a qualified column" \
  "UPDATE T SET N = 3 WHERE ID = 1 RETURNING NULL, TRUE, 12.5, T.N * 2, CURRENT_DATE;"
both "a BLOB-valued expression mints a blob here too" \
  "UPDATE T SET B = 'stored' WHERE ID = 1 RETURNING B || '-x', UPPER(B), B;"
both "UPDATE OR INSERT ... RETURNING an expression" \
  "UPDATE OR INSERT INTO T (ID, N) VALUES (12, 4) MATCHING (ID) RETURNING ID, N * 5;"

# ---- the describe -------------------------------------------------------
bothd "the un-aliased names are the engine's operator names" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING N * 2, N + 1, S || 'x', CAST(N AS VARCHAR(4)), UPPER(S), CASE WHEN N > 0 THEN 1 ELSE 0 END, COALESCE(N, 0);"
bothd "... and the types and widths the select list would announce" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING NM * 2, N / 2, D + 1, CHAR_LENGTH(S), 1, 'lit', -N;"
bothd "an alias renames the column and nothing else" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING N * 2 AS DOUBLED, ID;"

# ---- the singleton (statement type 8) path a driver takes ---------------
if command -v node >/dev/null 2>&1 && node -e "require('node-firebird')" 2>/dev/null; then
    q() { # <port> <db> <sql>
        FC_Q="$3" FC_PORT="$1" FC_DB="$2" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              console.log(JSON.stringify(r));db.detach();process.exit(0);});});' 2>/dev/null
    }
    sql="INSERT INTO T (ID, N, S) VALUES (20, 8, 'drv') RETURNING ID, N * 3 AS TRIPLED, UPPER(S)"
    check "the driver's singleton INSERT ... RETURNING carries expressions" \
        "$(q "$PORT" "$A" "$sql")" "$(q "$REAL" "$B" "$sql")"
else
    echo "SKIP node-firebird not found (the singleton-path check)"
fi

# ---- the engine reads what fire-crab wrote ------------------------------
eng_q="SET LIST ON; SELECT ID, N, S, D, NM, CAST(B AS VARCHAR(30)) FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"

# ---- boundaries ---------------------------------------------------------
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    case "$r" in
        *"Dynamic SQL Error"*|*"Column unknown"*) echo "OK   boundary: $1" ;;
        *) echo "DIFF boundary MOVED: $1"; echo "     [$r]"; fail=1 ;;
    esac
}
refuses "an expression over a COMPUTED column refuses" \
  "UPDATE C SET A = 5 WHERE ID = 1 RETURNING CC + 0;"
refuses "... and the bare computed column still refuses" \
  "UPDATE C SET A = 5 WHERE ID = 1 RETURNING CC;"
refuses "an aggregate in RETURNING refuses" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING MAX(N);"
refuses "a subquery in RETURNING refuses" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING (SELECT MAX(N) FROM T);"
refuses "a quoted name in the wrong case is still Column unknown" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING \"n\";"
refuses "a parameter in RETURNING refuses" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING ?;"
# (a MERGE's RETURNING takes expressions too - see
# --- a fixed-width CHAR result must be WRITTEN at its ANNOUNCED width ---
# The singleton path (op_execute2, which is how an INSERT ... RETURNING is
# answered) emitted the row with NO OUTPUT FORMAT, so it had no attachment
# charset and wrote a CHAR result in the value's OWN bytes while the
# describe announced the attachment's. Under -ch UTF8 `RETURNING 'ok'`
# announced len 8 and wrote 2 bytes padded to the 4-byte XDR boundary; the
# client desynchronised and the CONNECTION DIED - 08006, and every later
# statement on it dead.
#
# Two things make this easy to miss:
#   - it is ATTACHMENT-DEPENDENT. Under -ch NONE the announced length IS
#     the byte length, so the same statement is correct. A gate that runs
#     isql's default attachment sees nothing.
#   - it is INSERT-SPECIFIC. UPDATE/DELETE/MERGE ... RETURNING answer
#     through the ordinary fetch path, which HAS the format, so the
#     identical expression is correct there. The contrast is the evidence.
# The describes agreed on both servers throughout - only the bytes differed.
retmb() { # <label> <sql> ; runs under UTF8 and asserts the connection lives
    ran=$((ran + 1))
    local e c
    e=$(printf '%s\nSELECT 9 FROM RDB$DATABASE;\n' "$2" |
        "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf '%s\nSELECT 9 FROM RDB$DATABASE;\n' "$2" |
        "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    if printf '%s' "$c" | grep -q '08006'; then
        echo "DIFF $1: THE CONNECTION DIED (08006) - a CHAR result was written"
        echo "     at a width other than the one announced"
        fail=1
    elif [ "$c" = "$e" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     got:  [$c]"; echo "     want: [$e]"; fail=1
    fi
}
retmb "INSERT RETURNING a literal" \
    "INSERT INTO T (ID) VALUES (901) RETURNING 'ok';"
retmb "INSERT RETURNING a CAST to CHAR" \
    "INSERT INTO T (ID) VALUES (902) RETURNING CAST('abc' AS CHAR(3));"
retmb "INSERT RETURNING a CASE over literals" \
    "INSERT INTO T (ID) VALUES (903) RETURNING CASE WHEN 1=1 THEN 'yes' ELSE 'no' END;"
retmb "INSERT RETURNING COALESCE over text" \
    "INSERT INTO T (ID,S) VALUES (904,'zz') RETURNING COALESCE(S,'xx');"
retmb "INSERT RETURNING a CHAR in another charset" \
    "INSERT INTO T (ID) VALUES (905) RETURNING CAST('ab' AS CHAR(2) CHARACTER SET WIN1252);"
retmb "INSERT RETURNING a one-character literal (the lucky case)" \
    "INSERT INTO T (ID) VALUES (906) RETURNING 'a';"
# the contrasts that localise it: same expression, other statements
retmb "UPDATE RETURNING the same literal" \
    "UPDATE T SET N=N WHERE ID=901 RETURNING 'ok';"
retmb "DELETE RETURNING the same literal" \
    "DELETE FROM T WHERE ID=906 RETURNING 'ok';"
retmb "INSERT RETURNING a bare column (control)" \
    "INSERT INTO T (ID,S) VALUES (907,'qq') RETURNING S;"
retmb "INSERT RETURNING an integer (control)" \
    "INSERT INTO T (ID) VALUES (908) RETURNING ID;"

# serve-real-mergeparam.sh, where the two-context rule is pinned)
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
