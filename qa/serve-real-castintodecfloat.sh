#!/bin/bash
# CAST(<runtime DOUBLE/FLOAT> AS DECFLOAT(16|34)) matches the engine, where
# fire-crab used to refuse every approximate -> DECFLOAT conversion.
#
# A RUNTIME approximate value (a FLOAT/DOUBLE column, a CAST(.. AS DOUBLE)
# result, a param) converts by rendering the f64 to a FIXED significant-
# digit count and parsing that decimal - the engine's Decimal128/64::set
# (double) = sprintf %.Ng then decXxxFromString: 17 sig for DECFLOAT(34),
# 16 for DECFLOAT(16). NOT the shortest round-trip and NOT the full binary
# expansion. FLOAT is widened to f64 first (its DECFLOAT rep carries the
# f64-of-the-float digits, not an f32 shortest form). A zero is 0E-16
# (signed) in BOTH widths. DOUBLE -> DECFLOAT(16) raises 22003 for the
# top-2 finite doubles (the double->decimal64 path traps there); ->(34)
# never overflows for finite input.
#
# Results are rendered through CAST(.. AS VARCHAR(60)) to defeat isql's
# DECFLOAT display rounding; the overflow rows materialize the value so
# the trap actually fires.
#
# DEFERRED, asserted as a KNOWN divergence (fire-crab refuses, engine
# answers): a bare compile-time-constant approximate literal cast to
# DECFLOAT is a prepare-time decimal fold on the literal TEXT
# (CAST(0.1e0 AS DECFLOAT(34)) -> 0.1), which fire-crab cannot yet
# reproduce, so it refuses rather than ship the 17-sig runtime value. An
# intervening CAST(.. AS DOUBLE) defeats the fold and fire-crab MUST then
# answer the runtime expansion - the pair pins the split.
#
# Usage: qa/serve-real-castintodecfloat.sh [port]   (default 4164)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4164}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/castintodf-eng.fdb"; FC="$D/castintodf-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/castintodf-build.log 2>&1 <<'SQL'
create table t(dd double precision, ff float, nz double precision, dbig double precision, d16 decfloat(16));
commit;
insert into t values (0.1, 0.1, -0.0, 1.7976931348623157e308, 0);
commit;
SQL
if grep -qi error /tmp/castintodf-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/castintodf-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castintodf.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
sig() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -iE '^X |SQLSTATE' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
# fire-crab MUST refuse (deferred), regardless of the engine's answer
refuses_fc() { local f; f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if printf '%s' "$f" | grep -qiE 'SQLSTATE'; then echo "OK   $1 (fc refuses, deferred)"; else echo "FAIL $1 (fc should refuse)"; echo "     fc =[$f]"; fail=1; fi; }
# a double literal materialized through CAST(.. AS DOUBLE), rendered as text
dbl() { printf "cast(cast(%s as double precision) as decfloat(%s))" "$1" "$3"; }
vc() { printf "cast(%s as varchar(60))" "$1"; }

echo "-- runtime DOUBLE -> DECFLOAT(34): 17 significant digits --"
agree "dd col 0.1 -> df34" "select $(vc "cast(dd as decfloat(34))") x from t;"
agree "0.2 -> df34" "select $(vc "$(dbl 0.2 x 34)") x from t;"
agree "1/3 -> df34" "select $(vc "cast(cast(1 as double precision)/cast(3 as double precision) as decfloat(34))") x from t;"
agree "0.7 -> df34" "select $(vc "$(dbl 0.7 x 34)") x from t;"
agree "2.5 -> df34" "select $(vc "$(dbl 2.5 x 34)") x from t;"
agree "100 -> df34" "select $(vc "$(dbl 100 x 34)") x from t;"
agree "1e300 -> df34" "select $(vc "$(dbl 1e300 x 34)") x from t;"
echo "-- runtime DOUBLE -> DECFLOAT(16): 16 significant digits --"
agree "dd col 0.1 -> df16" "select $(vc "cast(dd as decfloat(16))") x from t;"
agree "0.7 -> df16 (rounds up)" "select $(vc "$(dbl 0.7 x 16)") x from t;"
agree "3.14159265358979 -> df16" "select $(vc "$(dbl 3.14159265358979 x 16)") x from t;"
agree "10.0 -> df16" "select $(vc "$(dbl 10.0 x 16)") x from t;"
echo "-- FLOAT source: f64-widen, NOT f32-shortest --"
agree "ff col -> df34" "select $(vc "cast(ff as decfloat(34))") x from t;"
agree "ff col -> df16" "select $(vc "cast(ff as decfloat(16))") x from t;"
echo "-- signed zero: 0E-16 in both widths, sign preserved --"
agree "-0.0 -> df34" "select $(vc "cast(nz as decfloat(34))") x from t;"
agree "-0.0 -> df16" "select $(vc "cast(nz as decfloat(16))") x from t;"
agree "+0.0 -> df16" "select $(vc "$(dbl 0 x 16)") x from t;"
echo "-- a runtime DBL_MAX column converts to a VALUE at both widths (no runtime overflow) --"
agree "DBL_MAX col -> df16 (value)" "select $(vc "cast(dbig as decfloat(16))") x from t;"
agree "DBL_MAX col -> df34 (value)" "select $(vc "cast(dbig as decfloat(34))") x from t;"
agree "1.5e308 col -> df16 (value)" "select $(vc "cast(cast(1.5e308 as double precision) as decfloat(16))") x from t;"
# NOTE: CAST(<top-double LITERAL> AS DECFLOAT(16)) raises 22003 on the
# engine via a PREPARE-TIME constant fold (not a runtime trap); fire-crab
# takes the runtime path and returns the value - a known divergence in the
# deferred constant-fold family, not tested here.
echo "-- rounding ties (spot-check half-even at the 18th digit) --"
agree "0.12345678901234568 -> df16" "select $(vc "$(dbl 0.12345678901234568 x 16)") x from t;"
agree "0.30000000000000004 -> df34" "select $(vc "$(dbl 0.30000000000000004 x 34)") x from t;"
echo "-- constant-literal fold: DEFERRED (fc refuses; engine answers 0.1) --"
refuses_fc "CAST(0.1e0 AS DECFLOAT(34))" "select cast(0.1e0 as decfloat(34)) x from t;"
refuses_fc "CAST(0.1e0+0.0e0 AS DECFLOAT(34))" "select cast(0.1e0+0.0e0 as decfloat(34)) x from t;"
echo "-- contrast: an intervening CAST-to-DOUBLE defeats the fold -> runtime --"
agree "CAST(CAST(0.1e0 AS DOUBLE) AS DF34)" "select $(vc "cast(cast(0.1e0 as double precision) as decfloat(34))") x from t;"
echo "-- control: exact numeric literal still folds correctly (unchanged path) --"
agree "CAST(0.1 AS DF34) exact" "select $(vc "cast(0.1 as decfloat(34))") x from t;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS castintodecfloat" || echo "FAIL castintodecfloat"
exit $fail
