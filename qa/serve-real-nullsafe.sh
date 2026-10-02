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
# SECOND ROUND (a review of the first), also measured on engine 2182:
#
#   * a `?` side was still read as never NULL - the commonest use of the
#     predicate, an application binding NULL to `C IS NOT DISTINCT FROM ?`:
#     it counted 0 where the engine counts 2, and `CAST(? AS INTEGER) + J`
#     bound 0 is NULL on a NULL-J row.  A `?` (bare, `(?)`, `? + 1`) now
#     gets its own bind-time null test; an expression holding one gets the
#     expression null test.  `? IS [NOT] DISTINCT FROM X` - the `?` written
#     first - refused and now answers.  Section 5, through the qa/fbparam.c
#     rig (isql cannot bind a parameter);
#   * the first round's HAVING change REFUSED right sides the previous
#     binary answered right - `1 + 4`, `CAST(5 AS INTEGER)`, `K * 2`,
#     `COALESCE(K, 0) + 1` - because the group-row resolver could not
#     null-test an expression; it can now (section 6, which also promotes
#     the first round's recorded `MAX(V) IS NOT DISTINCT FROM NULLIF(1, 1)`);
#   * `S IS TRUE` over a VARCHAR, `I IS FALSE` over an INTEGER: the engine
#     raises 22000 "Invalid usage of boolean expression" at PREPARE; this
#     printed a header and raised 22018 from the first row (section 7, with
#     the bare `WHERE S`, which now answers the same vector).
#
# RECORDED, not fixed (section 4 and the 5 RECORDED cells): `(I > 0) IS
# TRUE` and `(BO IS TRUE) IS NOT DISTINCT FROM FALSE` (a predicate as a
# tested side) refused - ANSWERED since the qshape chunk, where a
# parenthesised predicate became a BOOLEAN operand (the three cells are
# pinned now, qa/serve-real-qshape.sh section 7); each nullable-side IS [NOT] DISTINCT FROM
# is a 2- or 3-group OR and a NOT over a column pair is 12 groups (the
# contradictory null-test groups are not pruned), so TWO `NOT (a IS
# DISTINCT FROM b)` or SEVEN `NOT (x IS NOT DISTINCT FROM 1)` cross
# DNF_MAX_GROUPS and REFUSE - with a misleading 42S02 "Table unknown"
# naming a column - where the previous binary answered them wrong; a `?`
# in a JOIN's predicate, `-?`, and `? IS TRUE` refuse, as they did before.
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
CREATE TABLE G (K INTEGER, V INTEGER, W INTEGER);
INSERT INTO M VALUES (1, 1, 1, TRUE, 'a', DATE '2020-01-01', 1.5);
INSERT INTO M VALUES (2, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO M VALUES (3, 3, NULL, FALSE, 'c', DATE '2020-01-03', NULL);
INSERT INTO M VALUES (4, NULL, 4, TRUE, NULL, NULL, 4.25);
INSERT INTO G VALUES (1, 1, 1); INSERT INTO G VALUES (1, NULL, 2); INSERT INTO G VALUES (2, NULL, NULL); INSERT INTO G VALUES (3, 5, 5);
COMMIT;
SQL
} | "$ISQL" -q -b -user "$U" -pas "$P" > /tmp/nullsafe-build.log 2>&1
grep -qiE 'Statement failed|error' /tmp/nullsafe-build.log && { echo "FAIL fixture build"; sed 's/^/   /' /tmp/nullsafe-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
# the one-`?` rig (qa/fbparam.c): binds the value as VARCHAR, or NULL for
# the word NULL - isql cannot bind a parameter at all
RIG="$D/nullsafe-fbparam"
if ! cc -o "$RIG" "$(dirname "$0")/fbparam.c" -I/opt/firebird/include -L/opt/firebird/lib -lfbclient -Wl,-rpath,/opt/firebird/lib 2>/dev/null; then
    echo "FAIL cannot build the param rig (cc/libfbclient missing)"; exit 1
fi

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-nullsafe-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC" "$RIG"' EXIT
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

# a one-`?` statement through the rig on both, the ENGINE pinned
ppin() { # <label> <sql> <bound value|NULL> <engine-output>
    ran=$((ran + 1))
    local ev fv
    ev=$(timeout 15 "$RIG" "127.0.0.1/$REAL:$ENG" "$2" "$3" 2>&1); fv=$(timeout 15 "$RIG" "127.0.0.1/$PORT:$FC" "$2" "$3" 2>&1)
    if [ "$ev" != "$4" ]; then echo "FAIL $1 - THE ENGINE ANSWERS [$ev], not the pinned [$4]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 <- $3"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 <- $3 [$ev]"; fi
}
# ...the engine answers it, this server refuses at prepare - recorded
prefused() { # <label> <sql> <bound value|NULL>
    ran=$((ran + 1))
    local ev fv
    ev=$(timeout 15 "$RIG" "127.0.0.1/$REAL:$ENG" "$2" "$3" 2>&1); fv=$(timeout 15 "$RIG" "127.0.0.1/$PORT:$FC" "$2" "$3" 2>&1)
    if [ "${ev#ERR}" != "$ev" ]; then echo "FAIL $1 - the engine raises now [$ev]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - IT AGREES NOW; promote the cell"; fail=1
    elif [ "${fv#ERR}" = "$fv" ]; then echo "FAIL $1 - A WRONG ANSWER, not a refusal"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 <- $3 (recorded: engine [$ev], this server refuses)"; fi
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

echo "--- 5. A \`?\` SIDE IS NULLABLE TOO (bound through the rig)"
ppin "5 I IS NOT DISTINCT FROM ?" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM ?" "NULL" "2"
ppin "5 I IS DISTINCT FROM ?" "SELECT COUNT(*) FROM M WHERE I IS DISTINCT FROM ?" "NULL" "2"
ppin "5 NOT (I IS NOT DISTINCT FROM ?)" "SELECT COUNT(*) FROM M WHERE NOT (I IS NOT DISTINCT FROM ?)" "NULL" "2"
ppin "5 NOT (I IS DISTINCT FROM ?)" "SELECT COUNT(*) FROM M WHERE NOT (I IS DISTINCT FROM ?)" "NULL" "2"
ppin "5 a text S IS NOT DISTINCT FROM ?" "SELECT COUNT(*) FROM M WHERE S IS NOT DISTINCT FROM ?" "NULL" "2"
ppin "5 a NUMERIC N IS DISTINCT FROM ?" "SELECT COUNT(*) FROM M WHERE N IS DISTINCT FROM ?" "NULL" "2"
ppin "5 a DATE D IS NOT DISTINCT FROM ?" "SELECT COUNT(*) FROM M WHERE D IS NOT DISTINCT FROM ?" "NULL" "2"
ppin "5 a BOOLEAN BO IS NOT DISTINCT FROM ?" "SELECT COUNT(*) FROM M WHERE BO IS NOT DISTINCT FROM ?" "NULL" "1"
ppin "5 OR'd with ID = 1" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM ? OR ID = 1" "NULL" "3"
ppin "5 MAX over it" "SELECT MAX(ID) FROM M WHERE I IS NOT DISTINCT FROM ?" "NULL" "4"
ppin "5 under a DISTINCT derived table" "SELECT COUNT(*) FROM (SELECT DISTINCT I FROM M WHERE I IS NOT DISTINCT FROM ?)" "NULL" "1"
ppin "5 (?) parenthesised" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM (?)" "NULL" "2"
ppin "5 ? + 1" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM ? + 1" "NULL" "2"
ppin "5 CAST(? AS INTEGER)" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM CAST(? AS INTEGER)" "NULL" "2"
ppin "5 NULLIF(CAST(? AS INTEGER), 1) bound 1" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM NULLIF(CAST(? AS INTEGER), 1)" "1" "2"
ppin "5 ...DISTINCT" "SELECT COUNT(*) FROM M WHERE I IS DISTINCT FROM NULLIF(CAST(? AS INTEGER), 1)" "1" "2"
ppin "5 CAST(? AS INTEGER) + J bound 0 (NULL on a NULL J)" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM CAST(? AS INTEGER) + J" "0" "2"
ppin "5 ...DISTINCT" "SELECT COUNT(*) FROM M WHERE I IS DISTINCT FROM CAST(? AS INTEGER) + J" "0" "2"
ppin "5 NOT (... IS DISTINCT FROM CAST(? AS INTEGER) + J)" "SELECT COUNT(*) FROM M WHERE NOT (I IS DISTINCT FROM CAST(? AS INTEGER) + J)" "0" "2"
ppin "5 ? first: ? IS NOT DISTINCT FROM I" "SELECT COUNT(*) FROM M WHERE ? IS NOT DISTINCT FROM I" "1" "1"
ppin "5 ...bound NULL" "SELECT COUNT(*) FROM M WHERE ? IS NOT DISTINCT FROM I" "NULL" "2"
ppin "5 NOT (? IS NOT DISTINCT FROM I)" "SELECT COUNT(*) FROM M WHERE NOT (? IS NOT DISTINCT FROM I)" "1" "3"
ppin "5 ? IS DISTINCT FROM I bound NULL" "SELECT COUNT(*) FROM M WHERE ? IS DISTINCT FROM I" "NULL" "2"
ppin "5 ? IS DISTINCT FROM UPPER(S)" "SELECT COUNT(*) FROM M WHERE ? IS DISTINCT FROM UPPER(S)" "A" "3"
ppin "5 ? IS NOT DISTINCT FROM 1 bound NULL" "SELECT COUNT(*) FROM M WHERE ? IS NOT DISTINCT FROM 1" "NULL" "0"
ppin "5 HAVING MAX(V) IS NOT DISTINCT FROM ?" "SELECT COUNT(*) FROM (SELECT K FROM G GROUP BY K HAVING MAX(V) IS NOT DISTINCT FROM ?)" "NULL" "1"
ppin "5 HAVING MAX(V) IS DISTINCT FROM ?" "SELECT COUNT(*) FROM (SELECT K FROM G GROUP BY K HAVING MAX(V) IS DISTINCT FROM ?)" "NULL" "2"
ppin "5 CONTROL I IS NOT DISTINCT FROM ? bound 1" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM ?" "1" "1"
ppin "5 CONTROL NOT (I IS NOT DISTINCT FROM ?) bound 1" "SELECT COUNT(*) FROM M WHERE NOT (I IS NOT DISTINCT FROM ?)" "1" "3"
ppin "5 CONTROL (?) bound 1" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM (?)" "1" "1"
ppin "5 CONTROL ? + 1 bound 0" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM ? + 1" "0" "1"
ppin "5 CONTROL HAVING ... bound 5" "SELECT COUNT(*) FROM (SELECT K FROM G GROUP BY K HAVING MAX(V) IS NOT DISTINCT FROM ?)" "5" "1"
ppin "5 CONTROL a bad bind still raises 22018" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM ?" "abc" "CONV_ERROR"
ppin "5 CONTROL ? IS NULL" "SELECT COUNT(*) FROM M WHERE ? IS NULL" "NULL" "4"
dsame "5 the describe: I IS NOT DISTINCT FROM ? is I's LONG" "SELECT COUNT(*) FROM M WHERE I IS NOT DISTINCT FROM ?;"
dsame "5 ...and NOT DISTINCT FROM ? + 1" "SELECT COUNT(*) FROM M WHERE NOT (I IS DISTINCT FROM ? + 1);"
dsame "5 ...? first, from S" "SELECT COUNT(*) FROM M WHERE ? IS DISTINCT FROM S;"
dsame "5 ...a DATE" "SELECT COUNT(*) FROM M WHERE D IS NOT DISTINCT FROM ?;"
dsame "5 ...HAVING" "SELECT K FROM G GROUP BY K HAVING MAX(V) IS DISTINCT FROM ?;"
prefused "5 RECORDED a JOIN ON ... IS NOT DISTINCT FROM ?" "SELECT COUNT(*) FROM M X JOIN M Y ON X.ID = Y.ID AND X.I IS NOT DISTINCT FROM ?" "NULL"
prefused "5 RECORDED ...a join WHERE" "SELECT COUNT(*) FROM M X JOIN M Y ON X.ID = Y.ID WHERE X.I IS DISTINCT FROM ?" "1"
prefused "5 RECORDED -? (a negated ? refuses everywhere)" "SELECT COUNT(*) FROM M WHERE I IS DISTINCT FROM -?" "1"
prefused "5 RECORDED ? IS TRUE" "SELECT COUNT(*) FROM M WHERE ? IS TRUE" "TRUE"

echo "--- 6. HAVING: the right side's own null test"
pin  "6 SUM(V) IS NOT DISTINCT FROM 1 + 4" "SELECT K FROM G GROUP BY K HAVING SUM(V) IS NOT DISTINCT FROM 1 + 4 ORDER BY K;" "K|3"
pin  "6 MAX(V) IS DISTINCT FROM CAST(5 AS INTEGER)" "SELECT K FROM G GROUP BY K HAVING MAX(V) IS DISTINCT FROM CAST(5 AS INTEGER) ORDER BY K;" "K|1|2"
pin  "6 MAX(V) IS DISTINCT FROM K * 2" "SELECT K FROM G GROUP BY K HAVING MAX(V) IS DISTINCT FROM K * 2 ORDER BY K;" "K|1|2|3"
pin  "6 MAX(W) IS NOT DISTINCT FROM COALESCE(K, 0) + 1" "SELECT K FROM G GROUP BY K HAVING MAX(W) IS NOT DISTINCT FROM COALESCE(K, 0) + 1 ORDER BY K;" "K|1"
pin  "6 MAX(V) IS NOT DISTINCT FROM NULLIF(1, 1)" "SELECT K FROM G GROUP BY K HAVING MAX(V) IS NOT DISTINCT FROM NULLIF(1, 1) ORDER BY K;" "K|2"
pin  "6 NOT (MAX(V) IS NOT DISTINCT FROM NULLIF(K, 2))" "SELECT K FROM G GROUP BY K HAVING NOT (MAX(V) IS NOT DISTINCT FROM NULLIF(K, 2)) ORDER BY K;" "K|3"
pin  "6 K IS DISTINCT FROM NULLIF(K, 2)" "SELECT K FROM G GROUP BY K HAVING K IS DISTINCT FROM NULLIF(K, 2) ORDER BY K;" "K|2"
pin  "6 a BOOLEAN key: HAVING BO IS FALSE" "SELECT BO, COUNT(*) FROM M GROUP BY BO HAVING BO IS FALSE;" "BO COUNT|<false> 1"
pin  "6 ...HAVING BO IS NOT TRUE" "SELECT BO, COUNT(*) FROM M GROUP BY BO HAVING BO IS NOT TRUE ORDER BY 1;" "BO COUNT|<null> 1|<false> 1"
pin  "6 ...a DATE key: HAVING D IS DISTINCT FROM DATE '2020-01-01'" "SELECT D, COUNT(*) FROM M GROUP BY D HAVING D IS DISTINCT FROM DATE '2020-01-01' ORDER BY 1;" "D COUNT|<null> 2|2020-01-03 1"
pin  "6 CONTROL HAVING K IS NOT DISTINCT FROM 2" "SELECT K FROM G GROUP BY K HAVING K IS NOT DISTINCT FROM 2;" "K|2"

echo "--- 7. IS TRUE / FALSE TESTS A BOOLEAN: anything else is the engine's 22000 at prepare"
pin  "7 S IS TRUE" "SELECT ID FROM M WHERE S IS TRUE ORDER BY ID;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 NOT (I IS TRUE)" "SELECT ID FROM M WHERE NOT (I IS TRUE) ORDER BY ID;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 I IS FALSE" "SELECT ID FROM M WHERE I IS FALSE;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 S IS NOT TRUE" "SELECT ID FROM M WHERE S IS NOT TRUE;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 I IS NOT FALSE" "SELECT ID FROM M WHERE I IS NOT FALSE;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 UPPER(S) IS TRUE" "SELECT ID FROM M WHERE UPPER(S) IS TRUE;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 D IS TRUE" "SELECT ID FROM M WHERE D IS TRUE;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 N IS FALSE" "SELECT ID FROM M WHERE N IS FALSE;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 a bare WHERE S" "SELECT ID FROM M WHERE S;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 WHERE NOT I" "SELECT ID FROM M WHERE NOT I;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 in a join WHERE" "SELECT X.ID FROM M X JOIN M Y ON X.ID = Y.ID WHERE X.S IS TRUE;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 UPDATE ... WHERE S IS FALSE" "UPDATE M SET J = 0 WHERE S IS FALSE; ROLLBACK;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 DELETE ... WHERE I IS NOT TRUE" "DELETE FROM M WHERE I IS NOT TRUE; ROLLBACK;" "Statement failed, SQLSTATE = 22000|Dynamic SQL Error|-SQL error code = -104|-Invalid usage of boolean expression"
pin  "7 CONTROL NULL IS TRUE (no row, no raise)" "SELECT COUNT(*) FROM M WHERE NULL IS TRUE;" "COUNT|0"
same "7 CONTROL S = TRUE coerces per row" "SELECT ID FROM M WHERE S = TRUE ORDER BY ID;"
pin  "7 CONTROL BO IS NOT FALSE" "SELECT ID FROM M WHERE BO IS NOT FALSE ORDER BY ID;" "ID|1|2|4"
pin  "7 CONTROL NOT (BO IS NOT FALSE)" "SELECT ID FROM M WHERE NOT (BO IS NOT FALSE) ORDER BY ID;" "ID|3"
pin  "7 CONTROL CAST(... AS BOOLEAN) IS TRUE" "SELECT COUNT(*) FROM M WHERE CAST(NULLIF(S, S) AS BOOLEAN) IS TRUE;" "COUNT|0"
pin  "7 CONTROL the select list BO IS NOT FALSE" "SELECT ID, BO IS NOT FALSE FROM M ORDER BY ID;" "ID BOOL|1 <true>|2 <true>|3 <false>|4 <true>"

echo "--- 4. RECORDED: refused, never answered wrong"
pin  "4 (I > 0) IS TRUE (answers since the qshape chunk)" "SELECT ID FROM M WHERE (I > 0) IS TRUE ORDER BY ID;" "ID|1|3"
pin  "4 NOT ((I > 0) IS FALSE) (answers since the qshape chunk)" "SELECT ID FROM M WHERE NOT ((I > 0) IS FALSE) ORDER BY ID;" "ID|1|2|3|4"
pin  "4 (BO IS TRUE) IS NOT DISTINCT FROM FALSE (answers since the qshape chunk)" "SELECT ID FROM M WHERE (BO IS TRUE) IS NOT DISTINCT FROM FALSE ORDER BY ID;" "ID|2|3"

refused "4 six NOT-ed IS DISTINCT FROMs past the DNF cap" "SELECT ID FROM M WHERE NOT (I IS DISTINCT FROM NULLIF(J, 4) OR J IS DISTINCT FROM NULLIF(I, 3) OR S IS DISTINCT FROM UPPER(S) OR BO IS DISTINCT FROM NULLIF(BO, FALSE) OR N IS DISTINCT FROM NULLIF(N, 1.5) OR D IS DISTINCT FROM NULLIF(D, D)) ORDER BY ID;"
refused "4 two NOT (a IS DISTINCT FROM b) over columns (12 DNF groups each)" "SELECT ID FROM M WHERE NOT (I IS DISTINCT FROM J) AND NOT (S IS DISTINCT FROM UPPER(S)) ORDER BY ID;"
refused "4 seven NOT (x IS NOT DISTINCT FROM <literal>) (2 groups each)" "SELECT ID FROM M WHERE NOT (I IS NOT DISTINCT FROM 1) AND NOT (J IS NOT DISTINCT FROM 1) AND NOT (N IS NOT DISTINCT FROM 1) AND NOT (S IS NOT DISTINCT FROM 'a') AND NOT (D IS NOT DISTINCT FROM DATE '2020-01-01') AND NOT (BO IS NOT DISTINCT FROM TRUE) AND NOT (ID IS NOT DISTINCT FROM 9) ORDER BY ID;"
echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-nullsafe-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
if [ "$ran" -lt 138 ]; then echo "FAIL only $ran checks ran (floor 138)"; fail=1; fi
exit $fail
