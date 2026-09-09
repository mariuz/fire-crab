#!/bin/bash
# EXPONENT-FORM NUMERIC LITERAL TYPING matches Firebird 6.
#
# The SIGNIFICAND alone decides the type (measured), NOT the net value or
# the exponent's magnitude - the significand is the mantissa digits with
# the '.' removed and leading zeros dropped, read as a magnitude M:
#   M <= 2^63-1  -> DOUBLE(480)        (1e5, 1e40, 1.5e38 - significand 1/15)
#   M == 2^63    -> INT128(32752)      (a lone quirk: exactly
#                                       9223372036854775808, whole scale-0)
#   M >= 2^63+1  -> DECFLOAT(34)(32762)(9999999999999999999e0,
#                                       12345678901234567890e0,
#                                       1.2345678901234567890e5)
# fire-crab used to type EVERY exponent literal DOUBLE, so a
# high-significand literal lost precision and announced the wrong SQLDA
# type. The fix routes it to INT128 / DECFLOAT(34) through one shared
# classifier used by BOTH the SELECT and the WHERE lexer.
#
# Held against the live engine: the SQLDA type and the value. A DECFLOAT
# literal in a WHERE COMPARISON or a CAST still REFUSES (42000) - the
# same limitation a PLAIN large literal has (DECFLOAT is not yet a
# comparison type); that is a documented known-refuse, not a wrong value.
# The DOUBLE-side last-digit binary64 rounding (9223372036854775807e0)
# is a pre-existing divergence - TYPE is asserted there, not the value.
#
# Usage: qa/serve-real-explit.sh [port]   (default 4148)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; PORT="${1:-4148}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"; DB="$D/explit.fdb"; rm -f "$DB"
echo "create database '127.0.0.1/3050:$DB' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $DB"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-explit.log 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do kill -0 $srv 2>/dev/null || break
  ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

E="127.0.0.1/3050:$DB"; F="127.0.0.1/$PORT:$DB"
fail=0
typ() { printf 'set sqlda_display on;\nselect %s x from rdb$database;\n' "$2" \
  | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -i 'sqltype:' | head -1 | grep -oiE 'sqltype: [0-9]+ [A-Za-z0-9]+'; }
val() { printf 'set list on;\nselect %s x from rdb$database;\n' "$2" \
  | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -iE '^X ' | tr -d ' \n' | sed 's/^X//'; }
whr() { local r; r=$(printf 'set list on;\nselect 1 y from rdb$database where %s = %s;\n' "$2" "$2" \
  | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
  if printf '%s' "$r" | grep -qi 'failed\|error'; then echo "R"; else printf '%s' "$r" | grep -iE '^Y ' | tr -d ' \n' | sed 's/^Y//'; fi; }

type_agree() { local e f; e=$(typ "$E" "$1"); f=$(typ "$F" "$1"); \
  [ "$e" = "$f" ] && echo "OK   type $1  [$e]" || { echo "FAIL type $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
val_agree()  { local e f; e=$(val "$E" "$1"); f=$(val "$F" "$1"); \
  [ "$e" = "$f" ] && echo "OK   val  $1  [$e]" || { echo "FAIL val  $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
where_agree(){ local e f; e=$(whr "$E" "$1"); f=$(whr "$F" "$1"); \
  [ "$e" = "$f" ] && echo "OK   whr  $1  [$e]" || { echo "FAIL whr  $1"; echo "     eng=[$e] fc=[$f]"; fail=1; }; }
fc_refuses() { local f; f=$(whr "$F" "$1"); \
  [ "$f" = "R" ] && echo "OK   refuse-in-WHERE $1  (engine answers; fc refuses, as a plain DECFLOAT literal does)" \
  || { echo "FAIL refuse $1  expected fc R, got [$f]"; fail=1; }; }
fc_refuses_sel() { local f; f=$(printf 'set list on;\nselect %s x from rdb$database;\n' "$1" \
  | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | grep -ci 'failed\|error'); \
  [ "$f" != 0 ] && echo "OK   refuse $1  (2^63 scaled INT128, no literal form)" || { echo "FAIL refuse $1 (expected fc refuse)"; fail=1; }; }

echo "== DOUBLE side: type + value =="
for c in "1e5" "1e40" "1.5e38" "15e-1" "1.23456789012345e0" "1.234567890123456789e30"; do
  type_agree "$c"; val_agree "$c"; where_agree "$c"; done
echo "== DOUBLE side: type only (pre-existing binary64 last-digit) =="
type_agree "9223372036854775807e0"

echo "== INT128 quirk: type + value + WHERE (all faithful) =="
for c in "9223372036854775808e0" "9223372036854775808e1" "9223372036854775808e5"; do
  type_agree "$c"; val_agree "$c"; where_agree "$c"; done

echo "== DECFLOAT(34) side: type + value (SELECT); WHERE is a known-refuse =="
for c in "9223372036854775809e0" "9999999999999999999e0" "12345678901234567890e0" \
         "1.2345678901234567890e5" "1.2345678901234567890e30" \
         "1234567890123456789012345678901234567890e0"; do
  type_agree "$c"; val_agree "$c"; fc_refuses "$c"; done

echo "== known-refuse: a 2^63 significand needing a SCALED/ROUNDED INT128 =="
fc_refuses_sel "9223372036854775808e-1"
fc_refuses_sel "9.223372036854775808e18"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS explit" || echo "FAIL explit"
exit $fail
