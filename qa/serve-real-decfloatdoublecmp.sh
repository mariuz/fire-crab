#!/bin/bash
# DECFLOAT vs DOUBLE/FLOAT comparison matches the engine, where fire-crab
# used to refuse it at prepare (and, once past prepare, would have compared
# rendered TEXT).
#
# The engine compares a DECFLOAT operand against an approximate one in the
# DECIMAL domain: it converts the double (a FLOAT is widened to f64 first)
# to a decfloat at the DECFLOAT operand's OWN width - 16 significant digits
# for DECFLOAT(16), 17 for DECFLOAT(34) - then decfloat::cmp. The width
# comes from the DECFLOAT operand alone, so the SAME double 0.1 is EQ to
# DECFLOAT(16) 0.1 but NE to DECFLOAT(34) 0.1 - the width flips the answer -
# and it is operand-order symmetric.
#
# Two edits landed it: cmp_sides now admits an APPROXIMATE side opposite a
# DECFLOAT one (it refused everything but exact-numeric, so the comparison
# never built), and value_cmp gained four DECFLOAT-vs-approx arms that
# convert the approx side at the DECFLOAT operand's width (via the runtime
# f64_to_dec the CAST path uses) and compare in decimal. num_cmp returns
# None for the pair, so this one value_cmp path serves =,<>,<,<=,>,>=, IN,
# BETWEEN, ORDER BY, DISTINCT dedup, CASE, and every set context.
#
# DEFERRED, NOT tested here (separate follow-ons, each still law-safe):
#  - UNION of a DECFLOAT branch with a DOUBLE branch: a describe-time
#    result-TYPING concern (union_coerce), distinct from value_cmp - still
#    refuses.
#  - an ALL-CONSTANT comparison CAST(<lit> AS DECFLOAT) = <bare double
#    literal>: the constant-fold family (fire-crab refuses; it refused
#    before this chunk too - no regression). A runtime approximate operand
#    (column, or CAST(.. AS DOUBLE)) is the in-scope path.
#
# Usage: qa/serve-real-decfloatdoublecmp.sh [port]   (default 4165)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4165}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfdcmp-eng.fdb"; FC="$D/dfdcmp-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfdcmp-build.log 2>&1 <<'SQL'
create table t(id integer, d16 decfloat(16), d34 decfloat(34), dp double precision, fl float, z double precision);
commit;
insert into t values (1, 0.1, 0.1, 0.1, 0.1, -0.0);
insert into t values (2, 0.5, 0.5, 0.5, 0.5, 0.0);
insert into t values (3, -0.1, -0.1, -0.1, -0.1, 0.0);
commit;
SQL
if grep -qi error /tmp/dfdcmp-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfdcmp-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfdcmp.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^(ID|X|V) |SQLSTATE' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }

echo "-- the width-flip: same double 0.1, EQ at width 16, NE at width 34 --"
agree "d16 = 0.1e0 -> row1" "select id from t where d16 = 0.1e0;"
agree "d34 = 0.1e0 -> none" "select id from t where d34 = 0.1e0;"
agree "d34 < 0.1e0 @1 (LT)" "select id from t where d34 < 0.1e0 and id=1;"
agree "d34 > 0.1e0 @1 none" "select id from t where d34 > 0.1e0 and id=1;"
echo "-- operand-order symmetry --"
agree "0.1e0 = d16 -> row1" "select id from t where 0.1e0 = d16;"
agree "0.1e0 = d34 -> none" "select id from t where 0.1e0 = d34;"
agree "0.1e0 > d34 @1 (GT)" "select id from t where 0.1e0 > d34 and id=1;"
echo "-- DECFLOAT vs DOUBLE column, both orders --"
agree "d16 = dp @1" "select id from t where d16 = dp and id=1;"
agree "d34 = dp @1 none" "select id from t where d34 = dp and id=1;"
agree "dp = d16 @1" "select id from t where dp = d16 and id=1;"
echo "-- FLOAT (widened f32->f64, NE even at width 16) --"
agree "d16 = fl @1 none" "select id from t where d16 = fl and id=1;"
agree "d34 = fl @1 none" "select id from t where d34 = fl and id=1;"
echo "-- binary-exact 0.5 EQ both widths; negative flips like 0.1 --"
agree "d16 = 0.5e0 @2" "select id from t where d16 = 0.5e0 and id=2;"
agree "d34 = 0.5e0 @2" "select id from t where d34 = 0.5e0 and id=2;"
agree "d16 = -0.1e0 @3" "select id from t where d16 = -0.1e0 and id=3;"
agree "d34 = -0.1e0 @3 none" "select id from t where d34 = -0.1e0 and id=3;"
echo "-- signed zero: a decfloat 0 equals a -0.0 double (cohort) --"
agree "z(-0.0)=cast(0 df16) @1" "select id from t where cast(0 as decfloat(16)) = z and id=1;"
agree "z(-0.0)=cast(0 df34) @1" "select id from t where cast(0 as decfloat(34)) = z and id=1;"
echo "-- IN / BETWEEN route through the same compare --"
agree "d16 IN (0.1e0,9e0) @1" "select id from t where d16 in (0.1e0, 9e0) and id=1;"
agree "d34 IN (0.1e0,9e0) @1 none" "select id from t where d34 in (0.1e0, 9e0) and id=1;"
agree "d16 BETWEEN 0.1e0 AND 1e0 @1" "select id from t where d16 between 0.1e0 and 1e0 and id=1;"
agree "d34 BETWEEN 0.1e0 AND 1e0 @1 none" "select id from t where d34 between 0.1e0 and 1e0 and id=1;"
echo "-- CASE expression evaluates the compare through value_cmp --"
agree "case d16=dp @1" "select id, (case when d16 = dp then 1 else 0 end) x from t where id=1;"
agree "case d34=dp @1 (0)" "select id, (case when d34 = dp then 1 else 0 end) x from t where id=1;"
# (ORDER BY / DISTINCT interleave of a DECFLOAT and a DOUBLE needs a UNION,
#  whose result-typing is a deferred follow-on; value_cmp serves the dedup
#  once such a query can be typed.)
echo "-- control: DECFLOAT vs EXACT numeric still compares (unchanged arm) --"
agree "d34 = 0.1 exact @1" "select id from t where d34 = 0.1 and id=1;"
agree "d16 > 0 @1" "select id from t where d16 > 0 and id=1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS decfloatdoublecmp" || echo "FAIL decfloatdoublecmp"
exit $fail
