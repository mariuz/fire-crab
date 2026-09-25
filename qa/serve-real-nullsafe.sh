#!/bin/bash
# NULL-SAFE PREDICATES ARE TWO-VALUED: IS [NOT] DISTINCT FROM, IS TRUE / FALSE.
#
# parse_leaf desugars them into the three-valued leaves every later stage
# knows (`=`, `<>`, IS [NOT] NULL), and NOT is pushed into those leaves by
# De Morgan.  Two holes, measured on engine 2182 and fixed:
#
#   * a right side that is NULL AT RUN TIME was assumed never NULL unless
#     it was a bare column or a spelled NULL - `NULLIF(1, 1)`, `NULLIF(Y.ID,
#     Y.ID)` in a JOIN ON, `UPPER(S)` over a NULL S, a scalar subquery with
#     no row: `I IS DISTINCT FROM NULLIF(1, 1)` returned the NULL rows and
#     `I IS NOT DISTINCT FROM NULLIF(1, 1)` none - exactly inverted;
#   * `A = v` alone is UNKNOWN on a NULL A, so an outer NOT stayed UNKNOWN:
#     `NOT (BO IS TRUE)`, `NOT (I IS NOT DISTINCT FROM 1)`, `NOT (I IS
#     [NOT] DISTINCT FROM J)` dropped the rows the engine returns.
#
# Every `=` / `<>` now stands beside explicit IS NOT NULL tests of both
# sides, so the desugared predicate never answers UNKNOWN.
#
# RECORDED, not fixed: HAVING `MAX(V) IS NOT DISTINCT FROM NULLIF(1, 1)`
# is REFUSED (the HAVING resolver cannot null-test an expression side; the
# previous binary answered it WRONG); `(I > 0) IS TRUE` and `(BO IS TRUE)
# IS NOT DISTINCT FROM FALSE` (a predicate as a tested side) are refused
# as before; a `?` right side keeps the never-NULL reading; and each
# nullable-side IS [NOT] DISTINCT FROM is a 2- or 3-group OR, so a chain
# of them crosses DNF_MAX_GROUPS sooner and is REFUSED (the previous
# binary answered those chains wrong).
#
# Usage: qa/serve-real-nullsafe.sh [port]   (default 5320)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-5320}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nullsafe-eng.fdb"; FC="$D/nullsafe-fc.fdb"
mkdir -p "$D"; rm -f "$ENG" "$FC"

{ echo "CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;"
  cat <<'SQL'
CREATE TABLE M (ID INTEGER, I INTEGER, J INTEGER, BO BOOLEAN, S VARCHAR(10), D DATE, N NUMERIC(9,2));
CREATE INDEX M_I ON M (I);
CREATE TABLE G (K INTEGER, V INTEGER);
INSERT INTO M VALUES (1, 1, 1, TRUE, 'a', DATE '2020-01-01', 1.5);
INSERT INTO M VALUES (2, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO M VALUES (3, 3, NULL, FALSE, 'c', DATE '2020-01-03', NULL);
INSERT INTO M VALUES (4, NULL, 4, TRUE, NULL, NULL, 4.25);
INSERT INTO G VALUES (1, 1); INSERT INTO G VALUES (1, NULL); INSERT INTO G VALUES (2, NULL); INSERT INTO G VALUES (3, 5);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/nullsafe-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/nullsafe-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/nullsafe-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-nullsafe-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a SCRIPT (a session), its lines squeezed and joined; errors included,
# so an error cell compares the engine's whole message
sess() { printf '%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -av '^ *$' | grep -av '^=' | grep -av '^After line' | sed 's/^ *//;s/ *$//;s/  */ /g' | paste -sd'|'; }
# the describe: type, length, charset, nullability
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s\n' "$2" | timeout 25 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 \
    | grep -a 'sqltype' | sed 's/  */ /g' | paste -sd'|'; }
# engine and this server print the same thing - value or error
same() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ev" ]; then echo "FAIL $1 - the engine printed nothing"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ...and the ENGINE is pinned too (the law, not just agreement)
pin() { # <label> <script> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" != "$3" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$3]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# the same describe
dsame() { # <label> <select>
    ran=$((ran + 1))
    local ed fd
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ -z "$ed" ]; then echo "FAIL $1 - the engine printed no describe"; fail=1
    elif [ "$ed" != "$fd" ]; then echo "FAIL $1"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ed]"; fi
}
# the engine answers, this server REFUSES - recorded (never a wrong answer)
refused() { # <label> <script>
    ran=$((ran + 1))
    local ev fv
    ev=$(sess "127.0.0.1/$REAL:$ENG" "$2"); fv=$(sess "127.0.0.1/$PORT:$FC" "$2")
    if [ "${ev#*SQLSTATE}" != "$ev" ]; then echo "FAIL $1 - the engine raises now [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#*SQLSTATE}" = "$fv" ]; then echo "FAIL $1 - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 (recorded: engine [${ev:0:60}], this server refuses)"; fi
}

echo "--- 1. A RIGHT SIDE THAT IS NULL AT RUN TIME (the findings)"
pin  "1 IS DISTINCT FROM NULLIF(1,1)" "SELECT ID FROM M WHERE I IS DISTINCT FROM NULLIF(1, 1) ORDER BY ID;" "ID|1|3"
pin  "1 IS NOT DISTINCT FROM NULLIF(1,1)" "SELECT ID FROM M WHERE I IS NOT DISTINCT FROM NULLIF(1, 1) ORDER BY ID;" "ID|2|4"
pin  "1 ...in a JOIN ON" "SELECT X.ID FROM M X JOIN M Y ON X.I IS DISTINCT FROM NULLIF(Y.ID, Y.ID) AND Y.ID = 1 ORDER BY 1;" "ID|1|3"
pin  "1 a BOOLEAN against NULLIF(TRUE,TRUE)" "SELECT ID FROM M WHERE BO IS DISTINCT FROM NULLIF(TRUE, TRUE) ORDER BY ID;" "ID|1|3|4"
pin  "1 a per-row NULLIF(J, 4)" "SELECT ID FROM M WHERE I IS NOT DISTINCT FROM NULLIF(J, 4) ORDER BY ID;" "ID|1|2|4"
pin  "1 ...DISTINCT" "SELECT ID FROM M WHERE I IS DISTINCT FROM NULLIF(J, 4) ORDER BY ID;" "ID|3"
pin  "1 UPPER(S) over a NULL S" "SELECT ID FROM M WHERE S IS NOT DISTINCT FROM UPPER(S) ORDER BY ID;" "ID|2|4"
pin  "1 COALESCE(J, I)" "SELECT ID FROM M WHERE I IS NOT DISTINCT FROM COALESCE(J, I) ORDER BY ID;" "ID|1|2|3"
pin  "1 a scalar subquery with no row" "SELECT ID FROM M WHERE I IS DISTINCT FROM (SELECT MAX(J) FROM M WHERE J > 100) ORDER BY ID;" "ID|1|3"
pin  "1 ...a text one" "SELECT ID FROM M WHERE S IS NOT DISTINCT FROM (SELECT MAX(S) FROM M WHERE ID > 10) ORDER BY ID;" "ID|2|4"
pin  "1 a DATE" "SELECT ID FROM M WHERE D IS NOT DISTINCT FROM CAST(NULLIF(D, D) AS DATE) ORDER BY ID;" "ID|2|4"
pin  "1 a NUMERIC" "SELECT ID FROM M WHERE N IS DISTINCT FROM NULLIF(N, 4.25) ORDER BY ID;" "ID|4"
pin  "1 an expression on both sides" "SELECT ID FROM M WHERE COALESCE(I, 0) IS DISTINCT FROM NULLIF(J, 1) ORDER BY ID;" "ID|1|2|3|4"
pin  "1 COUNT over it" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM NULLIF(J, J);" "COUNT|2"
pin  "1 DELETE by it" "DELETE FROM M WHERE I IS NOT DISTINCT FROM NULLIF(1, 1); SELECT ID FROM M ORDER BY ID; ROLLBACK;" "ID|1|3"
pin  "1 CONTROL the reversed form" "SELECT ID FROM M WHERE NULLIF(1, 1) IS DISTINCT FROM I ORDER BY ID;" "ID|1|3"
pin  "1 CONTROL CAST(NULL AS INT)" "SELECT ID FROM M WHERE I IS DISTINCT FROM CAST(NULL AS INTEGER) ORDER BY ID;" "ID|1|3"
pin  "1 CONTROL a non-NULL subquery" "SELECT ID FROM M WHERE I IS NOT DISTINCT FROM (SELECT MAX(J) FROM M WHERE J < 2) ORDER BY ID;" "ID|1"
pin  "1 CONTROL the select list" "SELECT ID, IIF(I IS NOT DISTINCT FROM NULLIF(1, 1), 1, 0) FROM M ORDER BY ID;" "ID CASE|1 0|2 1|3 0|4 1"

echo "--- 2. UNDER NOT: a two-valued predicate stays two-valued"
pin  "2 NOT (BO IS TRUE)" "SELECT ID FROM M WHERE NOT (BO IS TRUE) ORDER BY ID;" "ID|2|3"
pin  "2 NOT (BO IS FALSE)" "SELECT ID FROM M WHERE NOT (BO IS FALSE) ORDER BY ID;" "ID|1|2|4"
pin  "2 NOT (I IS NOT DISTINCT FROM 1)" "SELECT ID FROM M WHERE NOT (I IS NOT DISTINCT FROM 1) ORDER BY ID;" "ID|2|3|4"
pin  "2 ...on the indexed column, 3" "SELECT ID FROM M WHERE NOT (I IS NOT DISTINCT FROM 3) ORDER BY ID;" "ID|1|2|4"
pin  "2 ...against 1 + 0" "SELECT ID FROM M WHERE NOT (I IS NOT DISTINCT FROM 1 + 0) ORDER BY ID;" "ID|2|3|4"
pin  "2 ...a text" "SELECT ID FROM M WHERE NOT (S IS NOT DISTINCT FROM 'a') ORDER BY ID;" "ID|2|3|4"
pin  "2 ...a DATE" "SELECT ID FROM M WHERE NOT (D IS NOT DISTINCT FROM DATE '2020-01-01') ORDER BY ID;" "ID|2|3|4"
pin  "2 ...a NUMERIC" "SELECT ID FROM M WHERE NOT (N IS NOT DISTINCT FROM 1.5) ORDER BY ID;" "ID|2|3|4"
pin  "2 NOT (I IS NOT DISTINCT FROM J), two columns" "SELECT ID FROM M WHERE NOT (I IS NOT DISTINCT FROM J) ORDER BY ID;" "ID|3|4"
pin  "2 NOT (I IS DISTINCT FROM J)" "SELECT ID FROM M WHERE NOT (I IS DISTINCT FROM J) ORDER BY ID;" "ID|1|2"
pin  "2 NOT (... IS DISTINCT FROM NULLIF(J, 4))" "SELECT ID FROM M WHERE NOT (I IS DISTINCT FROM NULLIF(J, 4)) ORDER BY ID;" "ID|1|2|4"
pin  "2 NOT (... IS NOT DISTINCT FROM NULLIF(J, 4))" "SELECT ID FROM M WHERE NOT (I IS NOT DISTINCT FROM NULLIF(J, 4)) ORDER BY ID;" "ID|3"
pin  "2 NOT (NULLIF(1,1) IS NOT DISTINCT FROM I)" "SELECT ID FROM M WHERE NOT (NULLIF(1, 1) IS NOT DISTINCT FROM I) ORDER BY ID;" "ID|1|3"
pin  "2 NOT (UPPER(S) IS DISTINCT FROM S)" "SELECT ID FROM M WHERE NOT (UPPER(S) IS DISTINCT FROM S) ORDER BY ID;" "ID|2|4"
pin  "2 NOT (... a subquery with no row)" "SELECT ID FROM M WHERE NOT (S IS DISTINCT FROM (SELECT MAX(S) FROM M WHERE ID > 10)) ORDER BY ID;" "ID|2|4"
pin  "2 NOT (BO IS TRUE) OR ID = 1" "SELECT ID FROM M WHERE NOT (BO IS TRUE) OR ID = 1 ORDER BY ID;" "ID|1|2|3"
pin  "2 NOT IS FALSE AND NOT IS TRUE" "SELECT ID FROM M WHERE NOT (BO IS FALSE) AND NOT (BO IS TRUE) ORDER BY ID;" "ID|2"
pin  "2 in a JOIN ON" "SELECT X.ID, Y.ID FROM M X JOIN M Y ON NOT (X.I IS NOT DISTINCT FROM Y.J) WHERE X.ID <= 2 AND Y.ID <= 2 ORDER BY 1, 2;" "ID ID|1 2|2 1"
pin  "2 ...a LEFT JOIN ON NOT (Y.BO IS FALSE)" "SELECT X.ID, Y.ID FROM M X LEFT JOIN M Y ON NOT (Y.BO IS FALSE) AND Y.ID = X.ID ORDER BY 1;" "ID ID|1 1|2 2|3 <null>|4 4"
pin  "2 COUNT under NOT" "SELECT COUNT(*) FROM M WHERE NOT (I IS NOT DISTINCT FROM J);" "COUNT|2"
pin  "2 HAVING NOT (MAX(V) IS NOT DISTINCT FROM 1)" "SELECT K FROM G GROUP BY K HAVING NOT (MAX(V) IS NOT DISTINCT FROM 1) ORDER BY K;" "K|2|3"
pin  "2 HAVING NOT (MAX(V) IS DISTINCT FROM MIN(V))" "SELECT K FROM G GROUP BY K HAVING NOT (MAX(V) IS DISTINCT FROM MIN(V)) ORDER BY K;" "K|1|2|3"
pin  "2 UPDATE by it" "UPDATE M SET S = 'u' WHERE NOT (I IS NOT DISTINCT FROM 1); SELECT ID, S FROM M ORDER BY ID; ROLLBACK;" "ID S|1 a|2 u|3 u|4 u"
pin  "2 NOT NOT (BO IS TRUE)" "SELECT ID FROM M WHERE NOT NOT (BO IS TRUE) ORDER BY ID;" "ID|1|4"
pin  "2 CONTROL NOT (BO IS NOT TRUE)" "SELECT ID FROM M WHERE NOT (BO IS NOT TRUE) ORDER BY ID;" "ID|1|4"
pin  "2 CONTROL NOT (BO IS UNKNOWN)" "SELECT ID FROM M WHERE NOT (BO IS UNKNOWN) ORDER BY ID;" "ID|1|3|4"
pin  "2 CONTROL NOT (I IS DISTINCT FROM 3)" "SELECT ID FROM M WHERE NOT (I IS DISTINCT FROM 3) ORDER BY ID;" "ID|3"

echo "--- 3. CONTROLS: the positive forms (and the index path) are unchanged"
pin  "3 CONTROL IS NOT DISTINCT FROM 3 (indexed)" "SELECT ID FROM M WHERE I IS NOT DISTINCT FROM 3 ORDER BY ID;" "ID|3"
pin  "3 CONTROL ...OR'd" "SELECT ID FROM M WHERE I IS NOT DISTINCT FROM 3 OR I IS NOT DISTINCT FROM 1 ORDER BY ID;" "ID|1|3"
pin  "3 CONTROL IS NOT DISTINCT FROM J" "SELECT ID FROM M WHERE I IS NOT DISTINCT FROM J ORDER BY ID;" "ID|1|2"
pin  "3 CONTROL IS DISTINCT FROM J" "SELECT ID FROM M WHERE I IS DISTINCT FROM J ORDER BY ID;" "ID|3|4"
pin  "3 CONTROL BO IS TRUE" "SELECT ID FROM M WHERE BO IS TRUE ORDER BY ID;" "ID|1|4"
pin  "3 CONTROL BO IS FALSE" "SELECT ID FROM M WHERE BO IS FALSE ORDER BY ID;" "ID|3"
pin  "3 CONTROL BO IS NOT TRUE" "SELECT ID FROM M WHERE BO IS NOT TRUE ORDER BY ID;" "ID|2|3"
pin  "3 CONTROL LEFT JOIN ON Y.BO IS TRUE" "SELECT X.ID, Y.ID FROM M X LEFT JOIN M Y ON Y.BO IS TRUE AND Y.ID = X.ID ORDER BY 1;" "ID ID|1 1|2 <null>|3 <null>|4 4"
pin  "3 CONTROL EXISTS correlated" "SELECT ID FROM M X WHERE EXISTS (SELECT 1 FROM M Y WHERE Y.J IS NOT DISTINCT FROM X.I AND Y.ID <> X.ID) ORDER BY ID;" "ID|2|4"
pin  "3 CONTROL I + 1 IS NOT DISTINCT FROM J + 1" "SELECT ID FROM M WHERE I + 1 IS NOT DISTINCT FROM J + 1 ORDER BY ID;" "ID|1|2"
same "3 CONTROL the select-list CASE" "SELECT ID, CASE WHEN NOT (BO IS TRUE) THEN 1 ELSE 0 END FROM M ORDER BY ID;"
dsame "3 CONTROL the describe" "SELECT ID FROM M WHERE NOT (I IS NOT DISTINCT FROM NULLIF(J, 4));"

echo "--- 4. RECORDED: refused, never answered wrong"
refused "4 HAVING MAX(V) IS NOT DISTINCT FROM NULLIF(1,1)" "SELECT K FROM G GROUP BY K HAVING MAX(V) IS NOT DISTINCT FROM NULLIF(1, 1) ORDER BY K;"
refused "4 (I > 0) IS TRUE" "SELECT ID FROM M WHERE (I > 0) IS TRUE ORDER BY ID;"
refused "4 NOT ((I > 0) IS FALSE)" "SELECT ID FROM M WHERE NOT ((I > 0) IS FALSE) ORDER BY ID;"
refused "4 (BO IS TRUE) IS NOT DISTINCT FROM FALSE" "SELECT ID FROM M WHERE (BO IS TRUE) IS NOT DISTINCT FROM FALSE ORDER BY ID;"

refused "4 six NOT-ed IS DISTINCT FROMs past the DNF cap" "SELECT ID FROM M WHERE NOT (I IS DISTINCT FROM NULLIF(J, 4) OR J IS DISTINCT FROM NULLIF(I, 3) OR S IS DISTINCT FROM UPPER(S) OR BO IS DISTINCT FROM NULLIF(BO, FALSE) OR N IS DISTINCT FROM NULLIF(N, 1.5) OR D IS DISTINCT FROM NULLIF(D, D)) ORDER BY ID;"
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-nullsafe-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 64 ]; then echo "FAIL only $ran checks ran (floor 64)"; fail=1; fi
exit $fail
