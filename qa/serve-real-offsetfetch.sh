#!/bin/bash
# The SQL-standard row-limiting clauses: `OFFSET <n> ROW|ROWS` and
# `FETCH {FIRST|NEXT} [<n>] ROW|ROWS ONLY`, alone or combined (OFFSET
# then FETCH -> skip then take), beside the Firebird-native `FIRST`/
# `SKIP`/`ROWS n [TO m]` fc already had. Literal counts only, the way
# FIRST/SKIP are. Both databases run the same statements and the rows
# are compared.
#
# Boundary (recorded): `WITH TIES` and `... PERCENT` are not this
# engine's syntax - it answers -104 "Token unknown" and fc refuses them
# too (generically); the query fails on both, so it is checked only that
# both refuse. A `?` count (`OFFSET ? ROWS`) needs an input SQLDA and is
# not this slice.
#
#   qa/serve-real-offsetfetch.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4896}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-offsetfetch-crab.fdb"; B="$D/fc-offsetfetch-engine.fdb"
LOG="/tmp/fc-serve-offsetfetch-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
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
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

SETUP="CREATE TABLE T (ID INTEGER); INSERT INTO T VALUES (1); INSERT INTO T VALUES (2); INSERT INTO T VALUES (3); INSERT INTO T VALUES (4); INSERT INTO T VALUES (5); INSERT INTO T VALUES (5); COMMIT;"
echo "$SETUP" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" >/dev/null 2>&1
echo "$SETUP" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" >/dev/null 2>&1

run_both() {
    local title="$1" sql="$2"
    printf 'SET LIST ON;\n%s\n' "$sql" > "$D/of-q.sql"
    local e c
    e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/of-q.sql" 2>&1 | norm)
    c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/of-q.sql" 2>&1 | norm)
    check "$title" "$c" "$e"
}

run_both "OFFSET n ROWS (skip)"                 "SELECT ID FROM T ORDER BY ID OFFSET 2 ROWS;"
run_both "OFFSET n ROW (singular)"              "SELECT ID FROM T ORDER BY ID OFFSET 1 ROW;"
run_both "FETCH FIRST n ROWS ONLY (take)"       "SELECT ID FROM T ORDER BY ID FETCH FIRST 2 ROWS ONLY;"
run_both "FETCH FIRST ROW ONLY (no count = 1)"  "SELECT ID FROM T ORDER BY ID FETCH FIRST ROW ONLY;"
run_both "FETCH NEXT n ROW ONLY"                "SELECT ID FROM T ORDER BY ID FETCH NEXT 1 ROW ONLY;"
run_both "OFFSET then FETCH combined"           "SELECT ID FROM T ORDER BY ID OFFSET 1 ROW FETCH NEXT 2 ROWS ONLY;"
run_both "OFFSET 0 with FETCH"                  "SELECT ID FROM T ORDER BY ID OFFSET 0 ROWS FETCH NEXT 3 ROWS ONLY;"
run_both "OFFSET/FETCH over ORDER BY DESC"      "SELECT ID FROM T ORDER BY ID DESC OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY;"
run_both "DISTINCT with OFFSET/FETCH"           "SELECT DISTINCT ID FROM T ORDER BY ID OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY;"
run_both "OFFSET/FETCH inside a derived table"  "SELECT X FROM (SELECT ID AS X FROM T ORDER BY ID OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY) D ORDER BY X;"
run_both "native ROWS n still works"            "SELECT ID FROM T ORDER BY ID ROWS 2;"
run_both "native ROWS n TO m still works"       "SELECT ID FROM T ORDER BY ID ROWS 2 TO 3;"
run_both "native FIRST/SKIP still work"         "SELECT FIRST 2 SKIP 1 ID FROM T ORDER BY ID;"

# Boundary: WITH TIES / PERCENT are not this engine's syntax - both refuse
for q in "SELECT ID FROM T ORDER BY ID FETCH FIRST 2 ROWS WITH TIES" \
         "SELECT ID FROM T ORDER BY ID FETCH FIRST 50 PERCENT ROWS ONLY"; do
    printf 'SET LIST ON;\n%s;\n' "$q" > "$D/of-q.sql"
    e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" -i "$D/of-q.sql" 2>&1 | grep -ci 'error')
    c=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/of-q.sql" 2>&1 | grep -ci 'error')
    ran=$((ran + 1))
    if [ "$e" != "0" ] && [ "$c" != "0" ]; then echo "OK   boundary: '$q' refuses on both"
    else echo "DIFF boundary '$q' (eng-errs=$e fc-errs=$c)"; fail=1; fi
done

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
