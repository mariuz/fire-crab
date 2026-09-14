#!/bin/bash
# A UNION with a DECFLOAT branch types the result DECFLOAT and coerces the
# other branches into it - matching the engine, where fire-crab refused at
# describe (the union reconciliation had no decfloat handling).
#
# Precedence (measured, order-independent) = the DECFLOAT-conditionals rule:
# TEXT > DECFLOAT > {DOUBLE,FLOAT} > exact-numerics; among decfloats df34 >
# df16. So a UNION column with a DECFLOAT branch and no TEXT branch is
# DECFLOAT: df34 iff ANY branch is df34, else df16 (a non-decfloat sibling
# converts INTO that width, the sibling scale dropped to 0). Per-branch
# value coercion is the CAST-to-DECFLOAT vehicle: exact numeric via
# value_as_dec, DOUBLE/FLOAT via f64_to_dec at the result width (17 sig for
# df34, 16 for df16), a df16 branch widened into df34 exactly. A const
# approx literal branch is a RUNTIME 17-sig conversion here (NOT the CAST
# fold - measured). DISTINCT dedup is correct for free (branches coerced to
# the result-width decfloat, then value_cmp): the width flips a tie.
#
# DEFERRED / STILL REFUSING: DECFLOAT beside TEXT (engine renders the
# decfloat to VARCHAR - needs a decfloat->text renderer), and beside a
# non-numeric (temporal/blob). fire-crab refuses these rather than guess.
#
# NOTE: fire-crab does not yet support a derived-table over a UNION
# (`FROM (SELECT .. UNION ..)`) for ANY type, so values are read from bare
# unions, not a CAST-wrapped derived table.
#
# Usage: qa/serve-real-uniondecfloat.sh [port]   (default 4171)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4171}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/unidf-eng.fdb"; FC="$D/unidf-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/unidf-build.log 2>&1 <<'SQL'
create table t(id int, d16 decfloat(16), d34 decfloat(34), n numeric(9,2), i integer, bi bigint, dp double precision, fl float, s varchar(20));
commit;
insert into t values (1, 1.5, 2.2, 1.25, 5, 9, 0.1, 0.1, 'x');
commit;
SQL
if grep -qi error /tmp/unidf-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/unidf-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-unidf.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^01: sqltype|^V ' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
# count returned rows (for DISTINCT dedup), engine vs fc
rows() { local e f; e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" 2>&1 | grep -icE '^V '); f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | grep -icE '^V '); if [ "$e" = "$f" ]; then echo "OK   $1 (rows=$e)"; else echo "FAIL $1 eng=$e fc=$f"; fail=1; fi; }
refuses_fc() { local f; f=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | grep -iE 'SQLSTATE'); [ -n "$f" ] && echo "OK   refuse $1 (deferred; engine answers)" || { echo "FAIL refuse $1 (fc answered)"; fail=1; }; }

echo "-- TYPING: DECFLOAT dominates, df34 wins, width order-independent --"
agree "d16 U d34"   "select d16 v from t union select d34 from t;"
agree "d34 U d16"   "select d34 v from t union select d16 from t;"
agree "d16 U i"     "select d16 v from t union select i from t;"
agree "i U d16"     "select i v from t union select d16 from t;"
agree "d34 U i"     "select d34 v from t union select i from t;"
agree "d16 U bi"    "select d16 v from t union select bi from t;"
agree "d16 U n(9,2)" "select d16 v from t union select n from t;"
agree "n U d16"     "select n v from t union select d16 from t;"
agree "d16 U dp"    "select d16 v from t union select dp from t;"
agree "dp U d16"    "select dp v from t union select d16 from t;"
agree "d34 U dp"    "select d34 v from t union select dp from t;"
agree "d16 U fl"    "select d16 v from t union select fl from t;"
agree "d16 U d34 U i" "select d16 v from t union select d34 from t union select i from t;"
agree "d16 U d34 U dp" "select d16 v from t union select d34 from t union select dp from t;"
agree "d16 U NULL"  "select d16 v from t union select cast(null as integer) from t;"
echo "-- PER-BRANCH VALUE (bare UNION ALL, rendered) --"
agree "int 5 -> df34"   "select d34 v from t union all select i from t;"
agree "numeric -> df34" "select d34 v from t union all select n from t;"
agree "dbl 0.1e0 -> df34 (17sig)" "select d34 v from t union all select cast(0.1e0 as double precision) from t;"
agree "dbl 0.1e0 -> df16 (16sig)" "select d16 v from t union all select cast(0.1e0 as double precision) from t;"
agree "float -> df34"   "select d34 v from t union all select fl from t;"
agree "df16 1.5 -> df34 widen" "select d34 v from t union all select cast(1.5 as decfloat(16)) from t;"
agree "const 0.1e0 -> df34 runtime" "select d34 v from t union all select 0.1e0 from t;"
echo "-- DISTINCT dedup: the result width flips the tie (rows returned) --"
rows "0.1 df16 U 0.1e0 -> 1" "select cast(0.1 as decfloat(16)) v from t union select cast(0.1e0 as double precision) v from t;"
rows "0.1 df34 U 0.1e0 -> 2" "select cast(0.1 as decfloat(34)) v from t union select cast(0.1e0 as double precision) v from t;"
rows "0.5 df16 U 0.5e0 -> 1" "select cast(0.5 as decfloat(16)) v from t union select cast(0.5e0 as double precision) v from t;"
rows "0.1e0 U 0.1 df16 -> 1 (order)" "select cast(0.1e0 as double precision) v from t union select cast(0.1 as decfloat(16)) v from t;"
echo "-- DEFERRED (still refuse): DECFLOAT beside TEXT / non-numeric --"
refuses_fc "d16 U varchar"    "select d16 v from t union select s from t;"
refuses_fc "d34 U varchar"    "select d34 v from t union select s from t;"
refuses_fc "d16 U d34 U varchar" "select d16 v from t union select d34 from t union select s from t;"
echo "-- control: a non-decfloat union unchanged --"
agree "i U n numeric union" "select i v from t union select n from t;"
agree "i U dp double union" "select i v from t union select dp from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS uniondecfloat" || echo "FAIL uniondecfloat"
exit $fail
