#!/bin/bash
# A driver-bound DOUBLE against a DECFLOAT parameter slot converts at the
# slot's OWN significant-digit count - 17 for DECFLOAT(34), 16 for
# DECFLOAT(16) - where fire-crab converted it by its FULL binary expansion
# and answered WRONG ROW SETS.
#
# node-firebird sends a non-integer JS number as blr_double. The engine's
# Decimal128/64::set(double) is sprintf("%.16e" / "%.15e") then
# decNumberFromString, trailing-zero cohort kept: a bound 1.1 is
# 1.1000000000000001 in a DECFLOAT(34) slot and 1.100000000000000 in a
# DECFLOAT(16) one. So `D34 = ?` [1.1] finds the row storing
# 1.1000000000000001 (fire-crab found the one storing the 34-digit binary
# expansion 1.100000000000000088817841970012523 instead), `D16 = ?` [1.1]
# finds the whole 1.1 cohort (fire-crab found nothing), and every ordered
# form (>, <, BETWEEN, IN, <>) moved with it. The STORE path (INSERT/UPDATE
# a bound double into a DECFLOAT column) refused outright; it now stores the
# same 17/16-digit value the engine does, cohort included (a bound 1.5 is
# 1.5000000000000000 / 1.500000000000000). And a bound double is a RUNTIME
# value, so CAST(? AS DECFLOAT(34)) takes the runtime 17-digit path instead
# of the compile-time literal const-fold boundary (which refused).
#
# Both servers are driven through the SAME node-firebird build against
# twin copies of one file; the stored table is compared rendered.
#
# The adversarial verify of the first cut (44k probes) found six regressions,
# all closed and gated at the end of this script: a FLOAT source past the
# INT128 range (3.4e38, and 1e-30 at the small end) refused every
# INSERT .. SELECT because its literal was spelled without an exponent; an
# EXPONENT LITERAL stored into a DECFLOAT column went through the runtime
# double (1E+200 stored 9.9999999999999997E+199, 1.5E-398 stored 0E-16)
# where the engine stores the literal's TEXT - refused again (recorded);
# ROUND / TRUNC over an approximate source into a DECFLOAT column stored the
# double's 17 digits where the engine's evlRound value is exact - refused;
# a `?` inside an expression aimed at a DECFLOAT column stays a REFUSE (the
# second verify showed the raw integer splice right only for the simplest
# shapes: `? / 3` [2] is the engine's decimal 0.666..., COALESCE(?, 0) is a
# LONG slot that overflows on 2^40, `? * 1E+3` reads the literal as
# decfloat text); CAST(<approx> AS VARCHAR(n)) raised 22018 wherever the
# 16-digit render did not fit where the engine SHRINKS the precision
# (CAST(1.1e0 AS VARCHAR(10)) is '1.1000000'); and a MERGE with a FLOAT
# source column stored its shortest text's expansion into a DECFLOAT
# (1.1000000000000001) where the engine converts the widened single
# (1.1000000238418579).
#
# BOUNDARY (recorded, not gated): with an INDEX on a DECFLOAT(16) column the
# engine's optimizer builds the index key from the double's 17-digit
# decimal128 form without re-rounding to 16, so `D16 = ?` [1.1] under
# PLAN INDEX misses the 1.1 rows that PLAN NATURAL finds. fire-crab cannot
# CREATE INDEX on a DECFLOAT column, so no fixture here carries one.
#
# Usage: qa/serve-real-dfparambind.sh [port]   (default 4176)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4176}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/dfpb-eng.fdb"; FC="$D/dfpb-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/dfpb-build.log 2>&1 <<'SQL'
CREATE TABLE PB (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16));
INSERT INTO PB VALUES (1, 1.1, 1.1);
INSERT INTO PB VALUES (2, 1.1000000000000001, 1.100000000000000);
INSERT INTO PB VALUES (3, 1.100000000000000088817841970012523, 1.10000000000000009);
INSERT INTO PB VALUES (4, 0.1, 0.1);
INSERT INTO PB VALUES (5, 0.1000000000000000055511151231257827, 0.1000000000000000055511151231257827);
INSERT INTO PB VALUES (6, 1.5, 1.5);
INSERT INTO PB VALUES (7, 0.30000000000000004, 0.3000000000000000);
INSERT INTO PB VALUES (8, 0.3, 0.30000000000000004);
INSERT INTO PB VALUES (9, 123456789.12345679, 123456789.1234568);
INSERT INTO PB VALUES (10, 3.141592653589793, 3.141592653589793);
INSERT INTO PB VALUES (11, 3.1415926535897931, 3.141592653589793115997963468544185);
INSERT INTO PB VALUES (12, 9.9999999999999995E-8, 1.000000000000000E-7);
INSERT INTO PB VALUES (13, 1.000000000000000E-7, 9.9999999999999995E-8);
INSERT INTO PB VALUES (14, 1E+300, 1E+300);
INSERT INTO PB VALUES (15, -1.1000000000000001, -1.1);
INSERT INTO PB VALUES (16, 2.5, 2.5);
INSERT INTO PB VALUES (17, NULL, NULL);
INSERT INTO PB VALUES (18, 1.100000000000000088817841970012523, 1.100000000000000088817841970012523);
INSERT INTO PB VALUES (50, NULL, 1.192092895507812E-7);
INSERT INTO PB VALUES (51, NULL, 1.192092895507813E-7);
INSERT INTO PB VALUES (60, NULL, 7.257658296462933);
INSERT INTO PB VALUES (61, NULL, 7.257658296462934);
INSERT INTO PB VALUES (62, NULL, 9.619580835675920);
INSERT INTO PB VALUES (63, NULL, 9.619580835675921);
INSERT INTO PB VALUES (64, NULL, 4.339250757480817);
INSERT INTO PB VALUES (65, NULL, 4.339250757480818);
CREATE TABLE PBW (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16));
INSERT INTO PBW VALUES (1, 0, 0);
INSERT INTO PBW VALUES (2, 0, 0);
CREATE TABLE TX (ID INTEGER, FL FLOAT, DP DOUBLE PRECISION);
INSERT INTO TX VALUES (1, 1.1, 1.1);
INSERT INTO TX VALUES (3, 2.675, 2.675);
INSERT INTO TX VALUES (4, 1e30, 1e30);
INSERT INTO TX VALUES (6, -1.5, -1.5);
INSERT INTO TX VALUES (7, 3.4e38, 3.4e38);
INSERT INTO TX VALUES (8, 1e-30, 1e-30);
INSERT INTO TX VALUES (9, 100.005, 100.005);
INSERT INTO TX VALUES (12, 0, 0);
CREATE TABLE DX (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16), F FLOAT, DP DOUBLE PRECISION, N NUMERIC(9,2), V VARCHAR(30), I INTEGER);
CREATE TABLE TF (ID INTEGER, FL FLOAT, DP DOUBLE PRECISION, I INTEGER, N92 NUMERIC(9,2));
INSERT INTO TF VALUES (1, 2.675, 2.675, 3, 1.25);
INSERT INTO TF VALUES (4, 0.499995, 0.499995, 1, 2.5);
INSERT INTO TF VALUES (6, 0.499991, 0.499991, 0, 3.75);
INSERT INTO TF VALUES (24, -0.499995, -0.499995, -1, -0.5);
INSERT INTO TF VALUES (11, 100.005, 100.005, 100, 100.01);
INSERT INTO TF VALUES (14, NULL, NULL, NULL, NULL);
INSERT INTO TF VALUES (16, NULL, 8.5, 7, 8);
CREATE TABLE NG (ID INTEGER, D34 DECFLOAT(34), D16 DECFLOAT(16));
INSERT INTO NG VALUES (1, -0.5, -0.5);
INSERT INTO NG VALUES (2, -0.001, -0.001);
INSERT INTO NG VALUES (3, 0.001, 0.001);
INSERT INTO NG VALUES (4, -1.5E-300, -1.5E-300);
INSERT INTO NG VALUES (5, -7E-398, -7E-398);
INSERT INTO NG VALUES (6, -1.55, -1.55);
CREATE VIEW VF AS SELECT ID, COALESCE(FL, DP) X, FL Y, -FL Z, FL + 0 W FROM TF;
COMMIT;
SQL
if grep -qi error /tmp/dfpb-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/dfpb-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-dfpb.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     eng: $3"; echo "     fc:  $2"; fail=1; fi
}
# one query with JSON params through node against <port>/<db>; rows joined
node_at() { # <port> <db> <query> <json-params>
    FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR");db.detach();process.exit(0);}
          if(!r||!r.length){console.log("(none)");db.detach();process.exit(0);}
          console.log(r.map(x=>Object.values(x).join()).join(";"));db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() { # <port> <db> <query> <json> - retry a connection hiccup
    local n=0 r
    while [ $n -lt 8 ]; do
        r=$(node_at "$1" "$2" "$3" "$4")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}
both() { # <label> <sql> <json-params>
    local fc is
    fc=$(node_run "$PORT" "$FC" "$2" "$3")
    is=$(node_run 3050 "$ENG" "$2" "$3")
    check "$1 [$3]" "$fc" "$is"
}
where() { both "$1" "SELECT ID FROM PB WHERE $2 ORDER BY ID" "$3"; }
sig() { printf 'set sqlda_display on;\nset list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -aiE '^0[0-9]: sqltype|^[A-Z_][A-Z0-9_]* |SQLSTATE|^-' | sed 's/  */ /g' | tr '\n' '|'; }
agree() { local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }

echo "-- D34 = ? : the bound double is its 17-significant-digit decimal --"
where "D34 = 1.1 -> the 17-sig row"     "D34 = ?" "[1.1]"
where "D34 = 0.1 -> none"               "D34 = ?" "[0.1]"
where "D34 = 0.30000000000000004"       "D34 = ?" "[0.30000000000000004]"
where "D34 = pi"                        "D34 = ?" "[3.141592653589793]"
where "D34 = 1e-7"                      "D34 = ?" "[1e-7]"
where "D34 = -1.1"                      "D34 = ?" "[-1.1]"
where "D34 = 1.5 exact binary"          "D34 = ?" "[1.5]"
where "D34 = 2.5 exact binary"          "D34 = ?" "[2.5]"
where "D34 = 123456789.12345678"        "D34 = ?" "[123456789.12345678]"
echo "-- D16 = ? : 16 significant digits, the whole cohort matches --"
where "D16 = 1.1 -> cohort"             "D16 = ?" "[1.1]"
where "D16 = 0.1"                       "D16 = ?" "[0.1]"
where "D16 = 0.30000000000000004"       "D16 = ?" "[0.30000000000000004]"
where "D16 = 123456789.12345678"        "D16 = ?" "[123456789.12345678]"
where "D16 = pi"                        "D16 = ?" "[3.141592653589793]"
where "D16 = 1e-7 (rounds up)"          "D16 = ?" "[1e-7]"
where "D16 = -1.1"                      "D16 = ?" "[-1.1]"
where "D16 = 1.5"                       "D16 = ?" "[1.5]"
echo "-- DECFLOAT(16): the engine renders 17 digits THEN narrows to 16 HALF-UP (double rounding) --"
where "D16 = 2^-23 -> the ..813 row"    "D16 = ? AND ID >= 50" "[1.1920928955078125e-7]"
where "D16 < 2^-23"                     "D16 < ? AND ID >= 50" "[1.1920928955078125e-7]"
where "D16 > 2^-23"                     "D16 > ? AND ID >= 50" "[1.1920928955078125e-7]"
where "D16 = 7.2576582964629335"        "D16 = ? AND ID >= 60" "[7.2576582964629335]"
where "D16 = 9.61958083567592"          "D16 = ? AND ID >= 60" "[9.61958083567592]"
where "D16 = 4.3392507574808175"        "D16 = ? AND ID >= 60" "[4.3392507574808175]"
where "? = D16 4.3392507574808175"      "? = D16 AND ID >= 60" "[4.3392507574808175]"
where "D34 = 7.2576582964629335 (17, no narrowing)" "D34 = ?" "[7.2576582964629335]"
echo "-- operand order, ordering operators, BETWEEN, IN, <> --"
where "? = D34"                         "? = D34" "[1.1]"
where "? = D16"                         "? = D16" "[1.1]"
where "D34 > ?"                         "D34 > ?" "[1.1]"
where "D34 < ?"                         "D34 < ?" "[1.1]"
where "D34 >= ? AND <= 1.2"             "D34 >= ? AND D34 <= 1.2" "[1.1]"
where "D16 >= ? AND < 1.2"              "D16 >= ? AND D16 < 1.2" "[1.1]"
where "D16 > ?"                         "D16 > ?" "[1.1]"
where "D16 <= ?"                        "D16 <= ?" "[1.1]"
where "D34 BETWEEN ? AND ?"             "D34 BETWEEN ? AND ?" "[0.1,1.1]"
where "D16 BETWEEN ? AND ?"             "D16 BETWEEN ? AND ?" "[0.1,1.1]"
where "D34 IN (?, ?)"                   "D34 IN (?, ?)" "[1.1,0.1]"
where "D16 IN (?, ?)"                   "D16 IN (?, ?)" "[1.1,0.1]"
where "D34 <> ?"                        "D34 <> ?" "[1.1]"
where "D16 <> ?"                        "D16 <> ?" "[1.1]"
where "D34 = ? OR D16 = ?"              "D34 = ? OR D16 = ?" "[0.1,0.1]"
where "D34 = ? AND D16 = ?"             "D34 = ? AND D16 = ?" "[1.1,1.1]"
echo "-- controls: int / text / null binds unchanged --"
where "int bind"                        "D34 = ?" "[2]"
where "text bind D16 cohort"            "D16 = ?" '["1.1"]'
where "text bind D34 exact"             "D34 = ?" '["1.1"]'
where "null bind"                       "D34 = ?" "[null]"
echo "-- describe of the input slots (INPUT lines only: isql then tries to execute with no SQLDA) --"
sigin() { printf 'set sqlda_display on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -aiE '^0[0-9]: sqltype' | sed 's/  */ /g' | tr '\n' '|'; }
agreein() { local e f; e=$(sigin "127.0.0.1/3050:$ENG" "$2"); f=$(sigin "127.0.0.1/$PORT:$FC" "$2"); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
agreein "input describe D34/D16 compare" "select id from pb where d34 = ? and d16 = ?;"
agreein "input describe INSERT"          "insert into pbw (id, d34, d16) values (999, ?, ?);"
agreein "input describe UPDATE"          "update pbw set d16 = ? where id = 999;"

echo "-- STORE: a bound double into a DECFLOAT column keeps the 17/16-digit cohort --"
store() { # <label> <sql> <json>  - run on BOTH, both must succeed
    local fc is
    fc=$(node_run "$PORT" "$FC" "$2" "$3"); is=$(node_run 3050 "$ENG" "$2" "$3")
    check "$1 [$3]" "$fc" "$is"
}
store "insert 1.1"        "INSERT INTO PBW (ID, D34, D16) VALUES (101, ?, ?)" "[1.1,1.1]"
store "insert 0.1"        "INSERT INTO PBW (ID, D34, D16) VALUES (102, ?, ?)" "[0.1,0.1]"
store "insert 0.3..04"    "INSERT INTO PBW (ID, D34, D16) VALUES (103, ?, ?)" "[0.30000000000000004,0.30000000000000004]"
store "insert pi"         "INSERT INTO PBW (ID, D34, D16) VALUES (104, ?, ?)" "[3.141592653589793,3.141592653589793]"
store "insert 1e-7"       "INSERT INTO PBW (ID, D34, D16) VALUES (105, ?, ?)" "[1e-7,1e-7]"
store "insert -1.1"       "INSERT INTO PBW (ID, D34, D16) VALUES (106, ?, ?)" "[-1.1,-1.1]"
store "insert 1.5 cohort" "INSERT INTO PBW (ID, D34, D16) VALUES (107, ?, ?)" "[1.5,1.5]"
store "insert 1234..78"   "INSERT INTO PBW (ID, D34, D16) VALUES (108, ?, ?)" "[123456789.12345678,123456789.12345678]"
store "insert D16 only"   "INSERT INTO PBW (ID, D16) VALUES (109, ?)" "[1.1]"
store "insert 5e-324"     "INSERT INTO PBW (ID, D34, D16) VALUES (110, ?, ?)" "[5e-324,5e-324]"
store "insert 100.25"     "INSERT INTO PBW (ID, D34, D16) VALUES (111, ?, ?)" "[100.25,100.25]"
store "insert 1e-5"       "INSERT INTO PBW (ID, D34, D16) VALUES (112, ?, ?)" "[1e-5,1e-5]"
store "insert 2^-23 narrows up" "INSERT INTO PBW (ID, D34, D16) VALUES (113, ?, ?)" "[1.1920928955078125e-7,1.1920928955078125e-7]"
store "insert 7.2576582964629335" "INSERT INTO PBW (ID, D34, D16) VALUES (114, ?, ?)" "[7.2576582964629335,7.2576582964629335]"
store "insert 0.37661826488242445" "INSERT INTO PBW (ID, D34, D16) VALUES (115, ?, ?)" "[0.37661826488242445,0.37661826488242445]"
store "insert 83.41949964394693" "INSERT INTO PBW (ID, D34, D16) VALUES (116, ?, ?)" "[83.41949964394693,83.41949964394693]"
store "insert 0.00030441713795923255" "INSERT INTO PBW (ID, D34, D16) VALUES (117, ?, ?)" "[0.00030441713795923255,0.00030441713795923255]"
store "update D34"        "UPDATE PBW SET D34 = ? WHERE ID = 1" "[1.1]"
store "update D16"        "UPDATE PBW SET D16 = ? WHERE ID = 1" "[1.1]"
store "update both"       "UPDATE PBW SET D34 = ?, D16 = ? WHERE ID = 2" "[0.1,0.30000000000000004]"
echo "-- int / text binds into a DECFLOAT column (exact; decNumber grammar, cohort kept) --"
store "insert int 2/3"    "INSERT INTO PBW (ID, D34, D16) VALUES (201, ?, ?)" "[2,3]"
store "insert text 1.1"   "INSERT INTO PBW (ID, D34, D16) VALUES (202, ?, ?)" '["1.1","1.1"]'
store "insert text 1E+3/1.00" "INSERT INTO PBW (ID, D34, D16) VALUES (203, ?, ?)" '["1E+3","1.00"]'
store "insert text 17 digits D16 rounds" "INSERT INTO PBW (ID, D16) VALUES (204, ?)" '["9.99999999999999999"]'
store "insert text Infinity" "INSERT INTO PBW (ID, D34) VALUES (205, ?)" '["Infinity"]'
store "insert text -0"    "INSERT INTO PBW (ID, D34, D16) VALUES (206, ?, ?)" '["-0","-0"]'
store "update text 7.25"  "UPDATE PBW SET D16 = ? WHERE ID = 201" '["7.25"]'
echo "-- text below the decimal64 exponent floor: SUBNORMAL rounding / 0E-398, never garbage --"
store "insert text 1e-400 -> 0E-398"    "INSERT INTO PBW (ID, D34, D16) VALUES (211, ?, ?)" '["1e-400","1e-400"]'
store "insert text 1.5E-398 -> 2E-398"  "INSERT INTO PBW (ID, D34, D16) VALUES (212, ?, ?)" '["1.5E-398","1.5E-398"]'
store "insert text 1.23..E-390 subnormal" "INSERT INTO PBW (ID, D16) VALUES (213, ?)" '["1.2345678901234567890E-390"]'
store "insert text 0E-500"              "INSERT INTO PBW (ID, D34, D16) VALUES (214, ?, ?)" '["0E-500","0E-500"]'
store "insert text 5e-1000"             "INSERT INTO PBW (ID, D16) VALUES (215, ?)" '["5e-1000"]'
store "insert text -1e-400"             "INSERT INTO PBW (ID, D16) VALUES (216, ?)" '["-1e-400"]'
store "insert text 1E-398 min subnormal" "INSERT INTO PBW (ID, D16) VALUES (217, ?)" '["1E-398"]'
store "update text 1E-400"              "UPDATE PBW SET D16 = ? WHERE ID = 201" '["1E-400"]'
# ONE rounding at the subnormal digit: a 17th+ digit just BELOW the midpoint
# must not round up twice (engine 1.23456789E-390, not 1.23456790E-390)
store "insert text subnormal below-mid"  "INSERT INTO PBW (ID, D16) VALUES (222, ?)" '["1.234567894999999999E-390"]'
store "insert text subnormal below-mid 2" "INSERT INTO PBW (ID, D16) VALUES (223, ?)" '["5.4999999999999999E-398"]'
store "insert text subnormal exact mid"   "INSERT INTO PBW (ID, D16) VALUES (224, ?)" '["1.2345678950000000E-390"]'
store "insert text 2.5E-398 -> 3E-398"    "INSERT INTO PBW (ID, D16) VALUES (225, ?)" '["2.5E-398"]'
store "insert text carry 9.99..95E-384"   "INSERT INTO PBW (ID, D16) VALUES (226, ?)" '["9.9999999999999995E-384"]'
agree "literal cast subnormal once-rounded" "select cast(cast('1.234567894999999999E-390' as decfloat(16)) as varchar(40)) a, cast(cast('5.4999999999999999E-398' as decfloat(16)) as varchar(40)) b, cast(cast('1.2345678950000000E-390' as decfloat(16)) as varchar(40)) c, cast(cast(cast('1.2345678949999999E-390' as decfloat(34)) as decfloat(16)) as varchar(40)) d from rdb\$database;"
agree "literal cast underflow"          "select cast(cast('1e-400' as decfloat(16)) as varchar(40)) a, cast(cast('1.5E-398' as decfloat(16)) as varchar(40)) b, cast(cast('1.2345678901234567890E-390' as decfloat(16)) as varchar(40)) c, cast(cast('-1e-400' as decfloat(16)) as varchar(40)) d from rdb\$database;"
# a non-convertible text / a decimal64 overflow: BOTH servers error (the
# engine's decfloat invalid-operation / overflow vector vs fire-crab's
# generic vector - shape recorded, only the error-ness compared)
botherr() { local fc is; fc=$(node_run "$PORT" "$FC" "$2" "$3"); is=$(node_run 3050 "$ENG" "$2" "$3"); if [ "$fc" = "ERR" ] && [ "$is" = "ERR" ]; then echo "OK   $1 (both error)"; else echo "DIFF $1"; echo "     eng: $is"; echo "     fc:  $fc"; fail=1; fi; }
botherr "insert text abc"     "INSERT INTO PBW (ID, D34) VALUES (207, ?)" '["abc"]'
botherr "insert text padded"  "INSERT INTO PBW (ID, D34) VALUES (208, ?)" '["  1.5  "]'
botherr "insert text 1e400 D16 overflow" "INSERT INTO PBW (ID, D16) VALUES (209, ?)" '["1e400"]'
# NaN flavours the engine stores as written (sign / signalling / payload)
# and fc cannot carry: refuse rather than store a plain NaN
refuses_fc() { local f; f=$(node_run "$PORT" "$FC" "$2" "$3"); if [ "$f" = "ERR" ]; then echo "OK   $1 (fc refuses, deferred)"; else echo "FAIL $1 (fc should refuse)"; echo "     fc: $f"; fail=1; fi; }
refuses_fc "insert text sNaN"     "INSERT INTO PBW (ID, D34) VALUES (218, ?)" '["sNaN"]'
refuses_fc "insert text -nan"     "INSERT INTO PBW (ID, D16) VALUES (219, ?)" '["-nan"]'
refuses_fc "insert text nan123"   "INSERT INTO PBW (ID, D34) VALUES (220, ?)" '["nan123"]'
store "insert text plain NaN"     "INSERT INTO PBW (ID, D34, D16) VALUES (221, ?, ?)" '["NaN","nan"]'
agree "stored table rendered"           "select id, cast(d34 as varchar(60)) a, cast(d16 as varchar(60)) b from pbw order by id;"
agree "stored row count"                "select count(*) from pbw;"

echo "-- a bound double is a RUNTIME value: CAST(? AS DECFLOAT) takes the 17/16-digit path --"
both "cast ? df34/df16 1.1"   "SELECT CAST(CAST(? AS DECFLOAT(34)) AS VARCHAR(60)) A, CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[1.1,1.1]"
both "cast ? df34/df16 1.5"   "SELECT CAST(CAST(? AS DECFLOAT(34)) AS VARCHAR(60)) A, CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[1.5,1.5]"
both "cast ? df34/df16 0.5"   "SELECT CAST(CAST(? AS DECFLOAT(34)) AS VARCHAR(60)) A, CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[0.5,0.5]"
both "cast ? df34/df16 1e-5"  "SELECT CAST(CAST(? AS DECFLOAT(34)) AS VARCHAR(60)) A, CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[1e-5,1e-5]"
both "cast ? df34/df16 5e-324" "SELECT CAST(CAST(? AS DECFLOAT(34)) AS VARCHAR(60)) A, CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[5e-324,5e-324]"
both "cast ? as double, text"  "SELECT CAST(CAST(? AS DOUBLE PRECISION) AS VARCHAR(60)) A FROM RDB\$DATABASE" "[1.1]"
both "cast ? as integer"       "SELECT CAST(? AS INTEGER) A FROM RDB\$DATABASE" "[2.5]"
echo "-- a bound double cast to NUMERIC rounds with the engine's CVT epsilon (1.005 -> 1.01) --"
both "cast ? as numeric(9,2) 1.005"  "SELECT CAST(? AS NUMERIC(9,2)) A FROM RDB\$DATABASE" "[1.005]"
both "cast ? as numeric(9,2) -1.005" "SELECT CAST(? AS NUMERIC(9,2)) A FROM RDB\$DATABASE" "[-1.005]"
both "cast ? as numeric(9,2) 2.675"  "SELECT CAST(? AS NUMERIC(9,2)) A FROM RDB\$DATABASE" "[2.675]"
both "cast ? as numeric(18,3) 1.0005" "SELECT CAST(? AS NUMERIC(18,3)) A FROM RDB\$DATABASE" "[1.0005]"
both "cast ? as numeric(4,1) 0.25"   "SELECT CAST(? AS NUMERIC(4,1)) A FROM RDB\$DATABASE" "[0.25]"
agree "literal 1.005e0 -> numeric(9,2)"  "select cast(1.005e0 as numeric(9,2)) x, cast(cast(1.005e0 as double precision) as numeric(9,2)) y, cast(cast(-1.005e0 as double precision) as numeric(9,2)) z from rdb\$database;"
agree "literal edges -> numeric(9,2)"    "select cast(cast(2.675e0 as double precision) as numeric(9,2)) a, cast(cast(0.125e0 as double precision) as numeric(9,2)) b, cast(cast(1.115e0 as double precision) as numeric(9,2)) c, cast(cast(0.285e0 as double precision) as numeric(9,2)) d, cast(cast(1.0049999999999e0 as double precision) as numeric(9,2)) e from rdb\$database;"
agree "literal -> numeric(18,4)/(4,1)"   "select cast(cast(1.00005e0 as double precision) as numeric(18,4)) a, cast(cast(-2.00005e0 as double precision) as numeric(18,4)) b, cast(cast(0.25e0 as double precision) as numeric(4,1)) c, cast(cast(0.35e0 as double precision) as numeric(4,1)) d, cast(cast(-0.45e0 as double precision) as numeric(4,1)) e from rdb\$database;"
agree "literal -> integer"                "select cast(cast(2.5e0 as double precision) as integer) a, cast(cast(-2.5e0 as double precision) as integer) b, cast(cast(0.49999999999999994e0 as double precision) as integer) c from rdb\$database;"
agree "FLOAT through DOUBLE-typed CASE/COALESCE/IIF: 1e-14" "select id, cast(coalesce(fl, dp) as integer) a, cast(coalesce(fl, 0e0) as integer) b, cast(coalesce(fl, dp) as numeric(9,2)) c, cast(case when id > 0 then fl else dp end as integer) e, cast(iif(id > 0, fl, dp) as integer) f, cast(coalesce(fl, dp) as smallint) g from tf order by id;"
agree "FLOAT column / -fl / abs(fl): 1e-5"   "select id, cast(fl as integer) a, cast(fl as numeric(9,2)) b, cast(-fl as integer) c, cast(abs(fl) as integer) d, cast(fl as bigint) e, cast(fl as numeric(18,2)) f from tf order by id;"
agree "FLOAT arithmetic widens: 1e-14"        "select id, cast(fl + 0 as integer) a, cast(fl * 1 as numeric(9,2)) b, cast(dp as integer) c, cast(dp as numeric(9,2)) d from tf order by id;"
echo "-- FLOAT width through unary/conditional shapes: describe 482 vs 480 as the engine --"
agree "describe -fl abs(fl) fl+0"         "select -fl a, abs(fl) b, fl+0 c, fl*fl d, -(-fl) e, abs(-fl) f from tf where id = 1;"
agree "describe coalesce mixes"           "select coalesce(fl,fl) a, coalesce(null,fl) b, coalesce(fl,1) c, coalesce(fl,1.5) d, coalesce(fl,dp) e, coalesce(fl,0e0) f, coalesce(dp,fl) g from tf where id = 1;"
agree "describe nullif/iif/case"          "select nullif(fl,0) a, nullif(fl,dp) b, nullif(dp,fl) c, iif(id>0,fl,fl) d, iif(id>0,fl,dp) e, case when id>0 then fl end f, case when id>0 then fl else 1 end g, case when id>0 then fl else dp end h from tf where id = 1;"
agree "describe coalesce exact widths"    "select coalesce(fl,cast(1 as bigint)) a, coalesce(fl,cast(1 as numeric(18,4))) b, coalesce(fl, cast(dp as float)) d, coalesce(coalesce(fl,fl), dp) e, coalesce(coalesce(fl,dp), fl) f, coalesce(fl, fl+0) g, coalesce(fl, -fl) h from tf where id = 1;"
agree "all-FLOAT conditional keeps 1e-5 + 8-digit text" "select id, cast(coalesce(fl,fl) as integer) a, cast(coalesce(fl,fl) as numeric(9,2)) b, cast(coalesce(fl,fl) as varchar(30)) c, cast(iif(id>0,fl,fl) as integer) d, cast(nullif(fl,dp) as numeric(9,2)) e, cast(case when id>0 then fl end as integer) f, cast(coalesce(fl,1) as integer) g from tf order by id;"
echo "-- an EXACT branch in a FLOAT-typed conditional converts to single (was 0.0 / 22003 at fetch) --"
agree "coalesce(i,fl) / (fl,i) values"    "select id, coalesce(i, fl) a, coalesce(fl, i) b, coalesce(fl, 1) c, coalesce(fl, -1) d, coalesce(fl, 12345678901) e from tf order by id;"
agree "coalesce scaled/bigint branches"   "select id, coalesce(fl, 1.5) a, coalesce(1.5, fl) b, coalesce(n92, fl) c, coalesce(fl, n92) d, coalesce(fl, cast(1 as bigint)) e, coalesce(fl, cast(2.5 as numeric(18,4))) f from tf order by id;"
agree "case/iif with exact branches"      "select id, case when id > 10 then i else fl end a, iif(id > 10, i, fl) b, case when id > 10 then fl else i end c, iif(id = 1, 1, fl) d, case id when 16 then 8 else fl end e from tf order by id;"
# (-(coalesce(i, fl)) of an exact 0 renders -0 on the engine, 0 here: the
# sign of a negated zero - a pre-existing rendering nit, not compared)
agree "unary over exact-in-float cond"    "select id, abs(coalesce(i, fl)) b, coalesce(cast(null as float), i) c, coalesce(cast(null as float), 1) d, -(coalesce(fl, i)) e from tf where id <> 6 order by id;"
agree "exact-in-float cond via CTE/derived" "with q as (select id, coalesce(i, fl) v, coalesce(fl, i) w from tf) select q.id, q.v, q.w, d.x from q join (select id, coalesce(fl, n92) x from tf) d on d.id = q.id order by q.id;"
agree "exact-in-float cond compared above a CTE" "with q as (select id, n92, i, coalesce(n92, fl) x, coalesce(i, fl) v from tf) select id from q where x = 1.25 or x = n92 or v = 100 or v = i order by id;"
agree "exact-in-float cond distinct/subq" "select distinct coalesce(i, fl) a from tf order by 1;"
both "bound CAST(? AS FLOAT) beside DP widens" "SELECT ID, CAST(COALESCE(CAST(? AS FLOAT), DP) AS INTEGER) A, CAST(COALESCE(CAST(? AS FLOAT), DP) AS NUMERIC(9,2)) B, CAST(COALESCE(CAST(? AS FLOAT), DP) AS VARCHAR(30)) C FROM TF WHERE ID IN (1, 4, 14) ORDER BY ID" "[0.499995,0.499995,0.499995]"
both "bound CAST(? AS FLOAT) beside DP 2.675" "SELECT ID, CAST(COALESCE(CAST(? AS FLOAT), DP) AS NUMERIC(9,2)) B, CAST(COALESCE(CAST(? AS FLOAT), DP) AS VARCHAR(30)) C FROM TF WHERE ID IN (1, 14) ORDER BY ID" "[2.675,2.675]"
both "bound CAST(? AS FLOAT) beside 1 stays single" "SELECT ID, CAST(COALESCE(CAST(? AS FLOAT), 1) AS INTEGER) A, CAST(COALESCE(CAST(? AS FLOAT), 1) AS VARCHAR(30)) C FROM TF WHERE ID IN (1, 14) ORDER BY ID" "[0.499995,0.499995]"
agree "ROUND(fl) keeps FLOAT: describe + eps" "select id, round(fl, 2) a, round(fl) b, round(-fl, 2) c, cast(coalesce(fl, round(fl, 2)) as integer) d, cast(round(fl, 2) as integer) e, cast(coalesce(fl, round(fl, 2)) as varchar(30)) f, trunc(fl, 1) g from tf where id in (1, 4, 24) order by id;"
# (cast(round(x, 2) as decfloat(16)) renders the engine's exact int64 cohort
# 2.68 where fc renders 2.680000000000000 - the DP twin does the same, a
# pre-existing cohort nit, not compared here)
agree "ROUND(fl) value is EXACT for consumers" "select id, round(fl, 2) + 1 a, round(fl, 2) * 2 b, cast(round(fl, 2) as numeric(18,8)) c, round(round(fl, 3), 2) e, round(fl, 2) - round(dp, 2) f from tf where id in (1, 4, 11) order by id;"
agree "ROUND(fl) row sets"                "select id from tf where round(fl, 2) = 2.68 or round(fl, 2) in (0.5, 100.01) order by id;"
agree "ROUND(fl) through CTE"             "with c as (select id, round(fl, 2) r from tf) select id, r * 2 a, cast(r as numeric(9,2)) b from c where r = 2.68 or r = 0.5 order by id;"
agree "ROUND(fl) stored"                  "select id, cast(round(fl, 2) as double precision) a from tf where id in (1, 4, 11) order by id;"
both "bound CAST(? AS FLOAT) beside ROUND(FL,2) stays single" "SELECT ID, CAST(COALESCE(CAST(? AS FLOAT), ROUND(FL, 2)) AS INTEGER) A, CAST(COALESCE(CAST(? AS FLOAT), ROUND(FL, 2)) AS VARCHAR(30)) C FROM TF WHERE ID IN (1, 14, 16) ORDER BY ID" "[0.499995,0.499995]"
echo "-- INSERT .. SELECT of a FLOAT source into a DOUBLE column stores the binary value --"
sq() { printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -aiE '^[A-Z_][A-Z0-9_]* |SQLSTATE|^-' | sed 's/  */ /g' | tr '\n' '|'; }
for db in "127.0.0.1/3050:$ENG" "127.0.0.1/$PORT:$FC"; do sq "$db" "create table outf (id integer, flc float, dpc double precision, n92c numeric(9,2), n41c numeric(4,1), n93c numeric(9,3), ic integer, bic bigint, vc varchar(30)); insert into outf (id, dpc) select id, fl from tf; insert into outf (id, flc, dpc) select id + 100, coalesce(fl, i), iif(id = 1, 1, fl) from tf; insert into outf (id, n92c, n41c, n93c, ic, bic, vc) select id + 200, fl, fl, fl, fl, fl, fl from tf; insert into outf (id, n92c, ic) select id + 300, coalesce(fl, i), coalesce(fl, i) from tf; insert into outf (id, n92c) select id + 400, -fl from tf; insert into outf (id, n92c) select id + 500, abs(fl) from tf; insert into outf (id, n92c) select id + 600, nullif(fl, 0) from tf; insert into outf (id, n92c) select id + 700, cast(fl as float) from tf; insert into outf (id, n92c) select id + 800, iif(i > 0, fl, n92) from tf; insert into outf (id, n92c) select id + 900, fl + 0 from tf; insert into outf (id, n92c) values (1001, (select fl from tf where id = 1)); insert into outf (id, n41c) select 1002, cast(0.35 as float) from rdb\$database; insert into outf (id, n92c) select 1003, cast(1.005 as float) from rdb\$database; commit;" >/dev/null; done
agree "insert..select fl -> double column"   "select id, dpc from outf where id < 100 order by id;"
agree "insert..select float cond -> columns" "select id, flc, dpc from outf where id > 100 and id < 200 order by id;"
agree "insert..select fl -> exact columns: eps_float" "select id, n92c, n41c, n93c, ic, bic, vc from outf where id > 200 and id < 300 order by id;"
agree "insert..select float shapes -> numeric(9,2)" "select id, n92c, ic from outf where id > 300 and id < 1000 order by id;"
agree "insert subquery / cast float -> numeric" "select id, n92c, n41c from outf where id >= 1000 order by id;"
agree "FLOAT via CTE: widened branch 1e-14, bare column 1e-5" "with q as (select id, coalesce(fl, dp) x, fl y, -fl z, fl + 0 w from tf) select id, cast(x as integer) a, cast(y as integer) b, cast(z as integer) c, cast(w as integer) d, cast(x as numeric(9,2)) e, cast(y as numeric(9,2)) f from q order by id;"
agree "FLOAT via CTE: row set"            "with q as (select id, coalesce(fl, dp) x from tf) select id from q where cast(x as integer) = 1 order by id;"
agree "FLOAT via VIEW"                    "select id, cast(x as integer) a, cast(y as integer) b, cast(z as integer) c, cast(w as integer) d, cast(x as numeric(9,2)) e from vf order by id;"
agree "FLOAT via derived + join"          "select q.id, cast(q.x as integer) a, cast(q.x as smallint) b, cast(q.x as numeric(18,2)) c from tf join (select id, coalesce(fl, dp) x from tf) q on q.id = tf.id order by q.id;"
echo "-- decimal add with a ZERO operand beside a negative: sign kept (was 9.5 for -0.5 + 0) --"
agree "neg + 0 literal"                   "select cast(d34 + 0 as varchar(50)) a, cast(d16 + 0 as varchar(50)) b, cast(0 + d34 as varchar(50)) c, cast(d34 - 0 as varchar(50)) d from ng order by id;"
agree "SUM of a lone negative fraction"   "select id, cast(sum(d34) as varchar(50)) a, cast(sum(d16) as varchar(50)) b, cast(avg(d16) as varchar(50)) c from ng group by id order by id;"
agree "SUM cancelling to zero cohort"     "select cast(sum(d34) as varchar(50)) a, cast(sum(d16) as varchar(50)) b from ng where id in (2, 3);"
agree "SUM all negatives"                 "select cast(sum(d34) as varchar(50)) a, cast(sum(d16) as varchar(50)) b, cast(avg(d34) as varchar(50)) c from ng;"
agree "FLOAT source: eps_float 1e-5"      "select cast(cast(2.675e0 as float) as numeric(9,2)) a, cast(cast(1.005e0 as float) as numeric(9,2)) b, cast(cast(0.499995e0 as float) as integer) c, cast(cast(-1.005e0 as float) as numeric(18,2)) d, cast(cast(0.499995e0 as float) as bigint) e from rdb\$database;"
agree "cast ? as decfloat(16) 2^-23"      "select cast(cast(cast(1.1920928955078125e-7 as double precision) as decfloat(16)) as varchar(40)) b, cast(cast(cast(9.61958083567592e0 as double precision) as decfloat(16)) as varchar(40)) c, cast(cast(cast(4.3392507574808175e0 as double precision) as decfloat(16)) as varchar(40)) d from rdb\$database;"
both "cast ? df34/df16 2^-23"  "SELECT CAST(CAST(? AS DECFLOAT(34)) AS VARCHAR(60)) A, CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[1.1920928955078125e-7,1.1920928955078125e-7]"
both "cast ? df16 7.2576582964629335" "SELECT CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[7.2576582964629335]"
both "cast ? df16 0.37661826488242445" "SELECT CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[0.37661826488242445]"
both "cast ? df16 3873.2130461097545" "SELECT CAST(CAST(? AS DECFLOAT(16)) AS VARCHAR(60)) B FROM RDB\$DATABASE" "[3873.2130461097545]"
echo "-- boundary (recorded): an EXPRESSION carrying a ? against a DECFLOAT column still refuses --"
refuses_fc() { local f; f=$(node_run "$PORT" "$FC" "$2" "$3"); if [ "$f" = "ERR" ]; then echo "OK   $1 (fc refuses, deferred)"; else echo "FAIL $1 (fc should refuse)"; echo "     fc: $f"; fail=1; fi; }
# was an fc-only refusal until `CAST(? AS <type>)` became a resolvable
# comparison side (serve-real-bindconv, 2026-09-16): the slot describes as
# the cast target and the cast converts per row, so this now ANSWERS - and
# answers what the engine answers, the 17-significant-digit double expansion
# against the DECFLOAT(34) cohort included
both "D34 = CAST(? AS DOUBLE)"  "SELECT ID FROM PB WHERE D34 = CAST(? AS DOUBLE PRECISION) ORDER BY ID" "[1.1]"
refuses_fc "D16 = ? + 0"              "SELECT ID FROM PB WHERE D16 = ? + 0 ORDER BY ID" "[1.1]"
echo "-- boundary (recorded): a ? INSIDE an expression stored into a DECFLOAT column refuses --"
# the engine types the slot from the EXPRESSION'S context and converts the
# bound value THERE, before the decimal arithmetic (INSERT ... VALUES (? * 3)
# [0.1] stores 0.30000000000000003; COALESCE(?, 0) types the slot INTEGER
# and stores 1, and raises on 2^40; `? / 3` [2] is the decimal 0.666...7;
# `? * 1E+3` [2] is 2E+3); a raw splice of the bound value is right only for
# the simplest integer shapes - refused, every bind type
# `?`-in-expression into a DECFLOAT column ANSWERS since serve-real-slottype
# (2026-09-16): the placeholder converts at its own slot, so the decimal
# arithmetic runs on the converted value. These were fc-only refusals;
# each was measured against the engine (status AND stored value) before
# it became an agreement check. `? * 1E+3` and the WHERE-side `D16 = ? + 0`
# still refuse - different items, still recorded below.
both "insert ? * 3 into D34"    "INSERT INTO PBW (ID, D34) VALUES (301, ? * 3)" "[0.1]"
both "insert ? + ? into D34"    "INSERT INTO PBW (ID, D34) VALUES (302, ? + ?)" "[0.1,0.2]"
both "insert coalesce(?,0) D16" "INSERT INTO PBW (ID, D16) VALUES (303, COALESCE(?, 0))" "[1.1]"
both "update ? + 1 D34"         "UPDATE PBW SET D34 = ? + 1 WHERE ID = 1" "[0.7]"
both "update coalesce(?,0) D34" "UPDATE PBW SET D34 = COALESCE(?, 0) WHERE ID = 1" "[1.1]"
refuses_fc "merge set coalesce(?,0)"  "MERGE INTO PBW USING (SELECT 2 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN MATCHED THEN UPDATE SET D34 = COALESCE(?, 0)" "[1.1]"
echo "-- MERGE: a BARE marker into a DECFLOAT column binds (written as the value's literal) --"
store "merge set D34/D16 bare ?"    "MERGE INTO PBW USING (SELECT 2 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN MATCHED THEN UPDATE SET D34 = ?, D16 = ?" "[1.1,1.1]"
store "merge set D16 narrows 17->16" "MERGE INTO PBW USING (SELECT 2 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN MATCHED THEN UPDATE SET D16 = ?" "[7.2576582964629335]"
store "merge insert bare ? double"  "MERGE INTO PBW USING (SELECT 777 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN NOT MATCHED THEN INSERT (ID, D34, D16) VALUES (SRC.K, ?, ?)" "[0.1,0.1]"
store "merge insert bare ? text"    "MERGE INTO PBW USING (SELECT 778 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN NOT MATCHED THEN INSERT (ID, D34, D16) VALUES (SRC.K, ?, ?)" '["1E+3","1.00"]'
both "merge insert ? * 3"     "MERGE INTO PBW USING (SELECT 779 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN NOT MATCHED THEN INSERT (ID, D34) VALUES (SRC.K, ? * 3)" "[0.1]"
agree "stored table after boundaries" "select id, cast(d34 as varchar(40)) a, cast(d16 as varchar(40)) b from pbw where id in (2, 777, 778, 779) order by id;"
agree "stored row count/sum"          "select count(*), sum(id) from pbw;"


# <label> <sql> - fc must REFUSE the statement (an error), on isql
refuses() { local f; f=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1); if echo "$f" | grep -aq "Statement failed"; then echo "OK   $1 (fc refuses)"; else echo "FAIL $1 (fc should refuse)"; echo "     fc: $f" | head -4; fail=1; fi; }
echo "-- verify-found: a FLOAT / DOUBLE source past the INT128 range through INSERT..SELECT / VALUES(subq) / UPDATE subq --"
agree "ins-sel FL 3.4e38, 1e-30 -> FLOAT/DOUBLE/VARCHAR" "INSERT INTO DX (ID, F, DP, V) SELECT ID, FL, FL, FL FROM TX WHERE ID IN (7, 8); SELECT ID, F, DP, V FROM DX ORDER BY ID;"
agree "ins-sel DP 3.4e38, 1e-30, 1e30 -> DOUBLE/FLOAT" "DELETE FROM DX; INSERT INTO DX (ID, DP, F) SELECT ID, DP, DP FROM TX WHERE ID IN (7, 8, 4); SELECT ID, DP, F FROM DX ORDER BY ID;"
agree "VALUES((SELECT FL)) 3.4e38"           "DELETE FROM DX; INSERT INTO DX (ID, F, DP) VALUES (7, (SELECT FL FROM TX WHERE ID = 7), (SELECT FL FROM TX WHERE ID = 7)); SELECT ID, F, DP FROM DX;"
agree "UPDATE .. = (SELECT FL) 3.4e38"       "DELETE FROM DX; INSERT INTO DX (ID) VALUES (1); UPDATE DX SET F = (SELECT FL FROM TX WHERE ID = 7) WHERE ID = 1; SELECT ID, F FROM DX;"
echo "-- verify-found: an EXPONENT LITERAL into a DECFLOAT column is read as DECIMAL FROM ITS OWN SPELLING (serve-real-explitstore, 2026-09-16) --"
# NOT the text verbatim: the decNumber form of the value the literal
# denotes, coefficient and exponent as written - 1e+200 / 1E200 / +1E200
# all store 1E+200, 1.5E+2 stays 1.5E+2, while 1.50E+2 is 150, 0.1E+1 is 1
# and 1.0E+0 is 1.0. Each line below was measured on BOTH sides (status
# AND stored value) before it became an agreement check; arithmetic over a
# literal, INSERT..SELECT and a MERGE INSERT literal still refuse.
# 1.5E-398 is past DOUBLE's range, so it is a DECFLOAT(34) literal (the
# dfliteral chunk) and stores its exact decimal - the engine's 2E-398 in a
# DECFLOAT(16) - no longer the refused DOUBLE underflow
agree "insert 1.5E-398 into D16 stores 2E-398" "INSERT INTO DX (ID, D16) VALUES (501, 1.5E-398); SELECT ID, D16 FROM DX WHERE ID = 501;"
agree "insert 1E+200 into D34"      "INSERT INTO DX (ID, D34) VALUES (502, 1E+200); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 502;"
agree "insert 0.1E0 into D34"       "INSERT INTO DX (ID, D34) VALUES (506, 0.1E0); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 506;"
agree "insert -1.5E-300 into D34"   "INSERT INTO DX (ID, D34) VALUES (504, -1.5E-300); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 504;"
# ARITHMETIC over literals into a DECFLOAT column is DECIMAL arithmetic on
# their decimal forms, never through a double (2026-09-16). Measured cell
# by cell on both sides, status AND stored value, each on its own row.
agree "insert 1E+3 * 2 into D34"    "INSERT INTO DX (ID, D34) VALUES (530, 1E+3 * 2); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 530;"
agree "insert 1E+200 + 0 into D34"  "INSERT INTO DX (ID, D34) VALUES (531, 1E+200 + 0); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 531;"
agree "insert 0.1E0 * 3 into D34"   "INSERT INTO DX (ID, D34) VALUES (532, 0.1E0 * 3); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 532;"
agree "insert 1.5E+2 + 1 into D34"  "INSERT INTO DX (ID, D34) VALUES (533, 1.5E+2 + 1); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 533;"
agree "insert 1E+3 / 4 into D34"    "INSERT INTO DX (ID, D34) VALUES (534, 1E+3 / 4); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 534;"
agree "insert 1E+3 * 1.5 into D34"  "INSERT INTO DX (ID, D34) VALUES (535, 1E+3 * 1.5); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 535;"
agree "insert -1E+3 * 2 into D34"   "INSERT INTO DX (ID, D34) VALUES (536, -1E+3 * 2); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 536;"
# past DOUBLE's range entirely - the cell that proves no f64 is involved
agree "insert 1E+200 * 1E+200 -> 1E+400" "INSERT INTO DX (ID, D34) VALUES (537, 1E+200 * 1E+200); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 537;"
agree "insert 1E+3 * 2 + 1 (nested)" "INSERT INTO DX (ID, D34) VALUES (538, 1E+3 * 2 + 1); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 538;"
agree "insert 1E+3 * 2 into D16"    "INSERT INTO DX (ID, D16) VALUES (539, 1E+3 * 2); SELECT ID, CAST(D16 AS VARCHAR(45)) B FROM DX WHERE ID = 539;"
agree "update D34 = 1E+3 * 2"       "INSERT INTO DX (ID, D34) VALUES (540, 1); UPDATE DX SET D34 = 1E+3 * 2 WHERE ID = 540; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 540;"
agree "update D34 = 0.1E0 * 3"      "INSERT INTO DX (ID, D34) VALUES (541, 1); UPDATE DX SET D34 = 0.1E0 * 3 WHERE ID = 541; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 541;"
# the CONTROLS: an approximate / exact destination keeps double arithmetic
agree "1E+3 * 2 into DOUBLE / NUMERIC" "INSERT INTO DX (ID, DP, N) VALUES (542, 1E+3 * 2, 1E+3 * 2); SELECT ID, DP, N FROM DX WHERE ID = 542;"
agree "exact-only trees unchanged"     "INSERT INTO DX (ID, D34) VALUES (543, 2 * 3); INSERT INTO DX (ID, D34) VALUES (544, 0.1 + 0.2); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID IN (543, 544) ORDER BY ID;"
# RECORDED: a constant past DOUBLE's range into a DOUBLE column refuses on
# both, but the engine raises 22003 where fire-crab answers 42000
refuses "1E+200 * 1E+200 into DOUBLE" "INSERT INTO DX (ID, DP) VALUES (545, 1E+200 * 1E+200);"
# An UPDATE takes it now (serve-real-slottype, 2026-09-16: the UPDATE
# planner's type gate learned the decfloat question, and this literal
# underflows to the value BOTH sides store). Measured before converting:
# engine 2E-398, fire-crab 2E-398 - and `D34 = 1.5E-398` 1.5E-398 on both.
# It runs on its OWN row of DX, never PBW's: an fc-only refusal turned
# into a both-sides check makes the ENGINE run a statement it never ran,
# and a later table-state check then diverges.
agree "update D16 = 1.5E-398 stores 2E-398" "INSERT INTO DX (ID, D16) VALUES (503, 1); UPDATE DX SET D16 = 1.5E-398 WHERE ID = 503; SELECT ID, D16 FROM DX WHERE ID = 503;"
# on its OWN DX row: the ENGINE runs this for the first time now, and a
# statement that mutates PBW would move ground a later check stands on
agree "update D34 = 1E+200"         "INSERT INTO DX (ID, D34) VALUES (520, 1); UPDATE DX SET D34 = 1E+200 WHERE ID = 520; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 520;"
agree "plain decimal / integer literals still store" "DELETE FROM DX; INSERT INTO DX (ID, D34, D16) VALUES (510, 1.1, 1.1); INSERT INTO DX (ID, D34, D16) VALUES (511, 1000, 1000); SELECT ID, D34, D16 FROM DX ORDER BY ID;"
agree "1.5E0 into DOUBLE / NUMERIC / FLOAT unchanged" "DELETE FROM DX; INSERT INTO DX (ID, DP, N, F) VALUES (512, 1.5E0, 1.5E0, 1.5E0); SELECT ID, DP, N, F FROM DX;"
agree "CAST('1.1' AS DOUBLE PRECISION) takes the runtime path" "DELETE FROM DX; INSERT INTO DX (ID, D34, D16) VALUES (513, CAST('1.1' AS DOUBLE PRECISION), CAST('1.1' AS DOUBLE PRECISION)); SELECT ID, D34, D16 FROM DX;"
echo "-- verify-found: ROUND / TRUNC over an approximate source into a DECFLOAT column refuses (engine: exact 2.68) --"
agree "ins-sel ROUND(FL,2) -> D16 (exact, the roundexact chunk)" "DELETE FROM DX; INSERT INTO DX (ID, D16) SELECT ID, ROUND(FL, 2) FROM TX WHERE ID IN (1, 3, 9); SELECT ID, D16 FROM DX ORDER BY ID;"
refuses "ins-sel TRUNC(DP,2) -> D34"    "INSERT INTO DX (ID, D34) SELECT ID, TRUNC(DP, 2) FROM TX;"
agree "UPDATE .. = (SELECT ROUND) D16 stores exact" "UPDATE PBW SET D16 = (SELECT ROUND(FL, 2) FROM TX WHERE ID = 3) WHERE ID = 1; SELECT ID, D16 FROM PBW WHERE ID = 1;"
agree "VALUES((SELECT ROUND)) D34 stores exact" "DELETE FROM DX; INSERT INTO DX (ID, D34) VALUES (1, (SELECT ROUND(FL, 2) FROM TX WHERE ID = 3)); SELECT ID, D34 FROM DX;"
agree "MERGE ROUND source -> D34"     "MERGE INTO PBW USING (SELECT ID, ROUND(FL, 2) R FROM TX WHERE ID IN (1, 3)) SRC ON (PBW.ID = SRC.ID) WHEN MATCHED THEN UPDATE SET D34 = SRC.R; SELECT ID, D34 FROM PBW WHERE ID IN (1, 3) ORDER BY ID;"
agree "ins-sel ROUND(FL,2) -> NUMERIC / DOUBLE unchanged" "DELETE FROM DX; INSERT INTO DX (ID, N, DP) SELECT ID, ROUND(FL, 2), ROUND(FL, 2) FROM TX WHERE ID IN (1, 3, 9); SELECT ID, N, DP FROM DX ORDER BY ID;"
echo "-- verify-found: CAST(<approx> AS <short text>) shrinks the precision as the engine's CVT does (sign column reserved, 22003 below 2 digits) --"
agree "CAST(DP AS VARCHAR(5/6/9/10/12))" "SELECT ID, CAST(DP AS VARCHAR(5)) C5, CAST(DP AS VARCHAR(6)) C6, CAST(DP AS VARCHAR(9)) C9, CAST(DP AS VARCHAR(10)) C10, CAST(DP AS VARCHAR(12)) C12 FROM TX WHERE ID IN (1, 3, 6, 9, 12) ORDER BY ID;"
agree "CAST(DP AS VARCHAR(9/15/17/24)) big / small" "SELECT ID, CAST(DP AS VARCHAR(9)) C9, CAST(DP AS VARCHAR(15)) C15, CAST(DP AS VARCHAR(17)) C17, CAST(DP AS VARCHAR(24)) C24 FROM TX WHERE ID IN (4, 7, 8) ORDER BY ID;"
agree "CAST(FL AS VARCHAR(4/5/9/10/14))" "SELECT ID, CAST(FL AS VARCHAR(4)) F4, CAST(FL AS VARCHAR(5)) F5, CAST(FL AS VARCHAR(9)) F9, CAST(FL AS VARCHAR(10)) F10, CAST(FL AS VARCHAR(14)) F14 FROM TX WHERE ID IN (1, 3, 6, 9, 12) ORDER BY ID;"
agree "CAST(COALESCE(FL,DP) / IIF AS VARCHAR(10)), CHAR(10)" "SELECT ID, CAST(COALESCE(FL, DP) AS VARCHAR(10)) A, CAST(DP AS CHAR(10)) B, CAST(IIF(ID > 0, FL, DP) AS VARCHAR(10)) C FROM TX WHERE ID IN (1, 9) ORDER BY ID;"
agree "too short: 22003"               "SELECT CAST(DP AS VARCHAR(3)) FROM TX WHERE ID = 1;"
agree "1e30 into VARCHAR(7): 22003"    "SELECT CAST(DP AS VARCHAR(7)) FROM TX WHERE ID = 4;"
agree "0.5 into VARCHAR(4): 22003"     "SELECT CAST(0.5e0 AS VARCHAR(4)) FROM RDB\$DATABASE;"
agree "12. / -1.1 / 1.0 / 123456789."  "SELECT CAST(12e0 AS VARCHAR(4)), CAST(-1.1e0 AS VARCHAR(4)), CAST(1e0 AS VARCHAR(4)), CAST(123456789.1234568e0 AS VARCHAR(11)) FROM RDB\$DATABASE;"
agree "the fitted text in WHERE and ||" "SELECT ID FROM TX WHERE CAST(DP AS VARCHAR(10)) = '1.1000000'; SELECT CAST(DP AS VARCHAR(10)) || '|' FROM TX WHERE ID = 9;"
echo "-- verify-found: a MERGE with a FLOAT / DOUBLE source column into a DECFLOAT column converts the widened single --"
agree "MERGE SET D34 = SRC.FL, D16 = SRC.DP, N = SRC.FL" "MERGE INTO PBW USING (SELECT ID, FL, DP FROM TX WHERE ID IN (1, 3)) SRC ON (PBW.ID = SRC.ID) WHEN MATCHED THEN UPDATE SET D34 = SRC.FL, D16 = SRC.DP; SELECT ID, CAST(D34 AS VARCHAR(40)) A, CAST(D16 AS VARCHAR(40)) B FROM PBW WHERE ID IN (1, 3) ORDER BY ID;"
agree "MERGE NOT MATCHED INSERT (SRC.FL, SRC.DP)"         "MERGE INTO PBW USING (SELECT ID, FL, DP FROM TX WHERE ID = 9) SRC ON (PBW.ID = SRC.ID) WHEN NOT MATCHED THEN INSERT (ID, D34, D16) VALUES (SRC.ID, SRC.FL, SRC.DP); SELECT ID, CAST(D34 AS VARCHAR(40)) A, CAST(D16 AS VARCHAR(40)) B FROM PBW WHERE ID = 9;"
agree "MERGE ON with a DOUBLE source column"              "MERGE INTO PBW USING (SELECT ID, DP FROM TX WHERE ID = 1) SRC ON (PBW.ID = SRC.ID AND PBW.D16 < SRC.DP + 100) WHEN MATCHED THEN UPDATE SET D34 = 77; SELECT ID, CAST(D34 AS VARCHAR(40)) A FROM PBW WHERE ID = 1;"
echo "-- verify-found (round 2): a ? INSIDE an expression aimed at a DECFLOAT column refuses for EVERY bind (engine answers noted) --"
# engine: `? + 1` [2] -> 3, `? / 3` [2] -> 0.6666666666666666666666666666666667, COALESCE(?, 0) [2^40] -> raises (LONG slot), `? * 1E+3` [2] -> 2E+3
both "update D34 = ? + 1 [2]"          "UPDATE PBW SET D34 = ? + 1 WHERE ID = 2" "[2]"
both "update D34 = ? / 3 [2]"          "UPDATE PBW SET D34 = ? / 3 WHERE ID = 2" "[2]"
both "update D16 = COALESCE(?, 0) [2^40]" "UPDATE PBW SET D16 = COALESCE(?, 0) WHERE ID = 2" "[1099511627776]"
refuses_fc "insert D34 ? * 1E+3 [2]"         "INSERT INTO PBW (ID, D34) VALUES (790, ? * 1E+3)" "[2]"
refuses_fc "merge set COALESCE(?,0) [2]"     "MERGE INTO PBW USING (SELECT 2 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN MATCHED THEN UPDATE SET D34 = COALESCE(?, 0)" "[2]"
both "merge insert ? * 3 [2]"          "MERGE INTO PBW USING (SELECT 791 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN NOT MATCHED THEN INSERT (ID, D34) VALUES (SRC.K, ? * 3)" "[2]"
echo "-- verify-found (round 2): a NON-RUNTIME approximate value refuses at a DECFLOAT store wherever its provenance was erased; ROUND now stores its EXACT value (the roundexact chunk) and is compared --"
# An INSERT .. SELECT of a CONSTANT literal source is re-planned with its
# literals read as DECIMALS (2026-09-16), so it stores what the engine
# stores; a MERGE's NOT MATCHED INSERT desugars to this same statement and
# follows. Each measured on both sides, status AND stored value, own row.
agree "ins-sel literal 1E+200 -> D34"        "INSERT INTO DX (ID, D34) SELECT 560, 1E+200 FROM RDB\$DATABASE; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 560;"
agree "ins-sel 1E+3 * 2 -> D34"              "INSERT INTO DX (ID, D34) SELECT 561, 1E+3 * 2 FROM RDB\$DATABASE; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 561;"
agree "ins-sel 0.1E0 * 3 -> D34"             "INSERT INTO DX (ID, D34) SELECT 562, 0.1E0 * 3 FROM RDB\$DATABASE; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 562;"
agree "ins-sel literal 1E+200 -> D16"        "INSERT INTO DX (ID, D16) SELECT 563, 1E+200 FROM RDB\$DATABASE; SELECT ID, CAST(D16 AS VARCHAR(45)) B FROM DX WHERE ID = 563;"
agree "ins-sel literal -> DOUBLE / NUMERIC"  "INSERT INTO DX (ID, DP, N) SELECT 564, 1E+200, 1E+3 * 2 FROM RDB\$DATABASE; SELECT ID, DP, N FROM DX WHERE ID = 564;"
agree "VALUES((SELECT 1E+200)) -> D34"       "INSERT INTO DX (ID, D34) VALUES (521, (SELECT 1E+200 FROM RDB\$DATABASE)); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 521;"
agree "UPDATE .. = (SELECT 1E+200) D34"      "INSERT INTO DX (ID, D34) VALUES (522, 1); UPDATE DX SET D34 = (SELECT 1E+200 FROM RDB\$DATABASE) WHERE ID = 522; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM DX WHERE ID = 522;"
agree "MERGE source literal col -> D34"      "MERGE INTO PBW USING (SELECT 1 AS K, 1E+200 AS X FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN MATCHED THEN UPDATE SET D34 = SRC.X; SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM PBW WHERE ID = 1;"
agree "MERGE insert literal 1E+200 -> D16"   "MERGE INTO PBW USING (SELECT 578 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN NOT MATCHED THEN INSERT (ID, D16) VALUES (SRC.K, 1E+200); SELECT ID, CAST(D16 AS VARCHAR(45)) B FROM PBW WHERE ID = 578;"
agree "MERGE insert 1E+3 * 2 -> D34"         "MERGE INTO PBW USING (SELECT 579 AS K FROM RDB\$DATABASE) SRC ON PBW.ID = SRC.K WHEN NOT MATCHED THEN INSERT (ID, D34) VALUES (SRC.K, 1E+3 * 2); SELECT ID, CAST(D34 AS VARCHAR(45)) A FROM PBW WHERE ID = 579;"
refuses "COALESCE(1E+200, 0) -> D34"         "INSERT INTO DX (ID, D34) VALUES (1, COALESCE(1E+200, 0));"
agree "ROUND(2.675E0, 2) const -> D34 stores 2.68" "DELETE FROM DX; INSERT INTO DX (ID, D34) VALUES (1, ROUND(2.675E0, 2)); SELECT ID, D34 FROM DX;"
agree "UPDATE D34 = ROUND(DP, 2) direct"   "DELETE FROM DX; INSERT INTO DX (ID, DP) VALUES (1, 2.675); UPDATE DX SET D34 = ROUND(DP, 2) WHERE ID = 1; SELECT ID, D34 FROM DX;"
refuses "UPDATE D34 = COALESCE(DP, 0)"       "UPDATE DX SET D34 = COALESCE(DP, 0) WHERE ID = 1;"
agree "ins-sel -ROUND(DP,2) -> D16"        "DELETE FROM DX; INSERT INTO DX (ID, D16) SELECT ID, -ROUND(DP, 2) FROM TX WHERE ID IN (1, 3, 9); SELECT ID, D16 FROM DX ORDER BY ID;"
agree "ins-sel ROUND(DP,2) + 0 -> D34 (a double)" "DELETE FROM DX; INSERT INTO DX (ID, D34) SELECT ID, ROUND(DP, 2) + 0 FROM TX WHERE ID IN (1, 3, 9); SELECT ID, D34 FROM DX ORDER BY ID;"
agree "ins-sel ROUND via derived -> D34"   "DELETE FROM DX; INSERT INTO DX (ID, D34) SELECT ID, X FROM (SELECT ID, ROUND(DP, 2) AS X FROM TX WHERE ID IN (1, 3, 9)) Q; SELECT ID, D34 FROM DX ORDER BY ID;"
agree "MERGE SET D34 = ROUND(SRC.DP, 2)"   "MERGE INTO PBW USING (SELECT ID, DP FROM TX WHERE ID = 3) SRC ON (PBW.ID = 1) WHEN MATCHED THEN UPDATE SET D34 = ROUND(SRC.DP, 2); SELECT ID, D34 FROM PBW WHERE ID = 1;"
# a CORRELATED lookup hides its inner expression from the store gate, so it
# still refuses (law-safe; the engine stores the exact 1.10) - fc-only check
refuses "UPDATE D34 = correlated (SELECT ROUND)" "UPDATE PBW SET D34 = (SELECT ROUND(TX.FL, 2) FROM TX WHERE TX.ID = PBW.ID) WHERE ID = 1;"
agree "runtime shapes still store: CAST(ROUND(DP,2) AS DOUBLE PRECISION), DP + 0, -FL, (SELECT DP)" "DELETE FROM DX; INSERT INTO DX (ID, D34, D16) SELECT ID, CAST(ROUND(DP, 2) AS DOUBLE PRECISION), DP + 0 FROM TX WHERE ID IN (1, 3); INSERT INTO DX (ID, D34, D16) VALUES (9, (SELECT DP FROM TX WHERE ID = 9), (SELECT -FL FROM TX WHERE ID = 9)); SELECT ID, CAST(D34 AS VARCHAR(40)) A, CAST(D16 AS VARCHAR(40)) B FROM DX ORDER BY ID;"
agree "a ROUND over an EXACT source / into a non-decfloat column of the same table still stores" "DELETE FROM DX; INSERT INTO DX (ID, D34, N) VALUES (1, (SELECT ROUND(N92) FROM TF WHERE ID = 1), (SELECT ROUND(FL, 2) FROM TF WHERE ID = 1)); INSERT INTO DX (ID, N, DP) SELECT ID, ROUND(FL, 2), ROUND(DP, 2) FROM TX WHERE ID = 3; SELECT ID, CAST(D34 AS VARCHAR(40)) A, N, DP FROM DX ORDER BY ID;"
echo "-- verify-found (round 2): CAST(<approx> AS text) - unsigned negative zero; the fit is into the BYTE length, then the character check (22001) --"
agree "negative zero unsigned"              "SELECT CAST(-DP AS VARCHAR(20)) A, CAST(DP * -1 AS VARCHAR(5)) B, CAST(CAST(-DP AS FLOAT) AS VARCHAR(10)) C, CAST(-0.0e0 AS VARCHAR(10)) D FROM TX WHERE ID = 12;"
utf8() { local e f; e=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" 2>&1 | grep -a -v '^$' | grep -aiE '^[A-Z_][A-Z0-9_]* |SQLSTATE|^-' | tr '\n' '|'); f=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | grep -a -v '^$' | grep -aiE '^[A-Z_][A-Z0-9_]* |SQLSTATE|^-' | tr '\n' '|'); if [ "$e" = "$f" ]; then echo "OK   $1"; else echo "FAIL $1"; echo "     eng=[$e]"; echo "     fc =[$f]"; fail=1; fi; }
utf8 "UTF8: VARCHAR(9) keeps 8 digits, VARCHAR(17) all 16" "SELECT CAST(FL AS VARCHAR(9)) A, CAST(DP AS VARCHAR(17)) B, CAST(DP AS VARCHAR(18)) C FROM TX WHERE ID = 1;"
utf8 "UTF8: VARCHAR(6) raises 22001 (the char check)"    "SELECT CAST(FL AS VARCHAR(6)) A FROM TX WHERE ID = 1;"
utf8 "UTF8: VARCHAR(4) of 1.1 raises 22001"              "SELECT CAST(DP AS VARCHAR(4)) A FROM TX WHERE ID = 1;"
utf8 "UTF8: explicit NONE charset fits by bytes = chars"  "SELECT CAST(DP AS VARCHAR(10) CHARACTER SET NONE) A, CAST(DP AS VARCHAR(10) CHARACTER SET UTF8) B FROM TX WHERE ID = 1;"
echo "-- verify-found (round 2): the STORE path fits an approximate value into a text column the same way; a double past FLOAT's range refuses --"
agree "ins-sel FL 0.499995 -> VARCHAR(10): 7 digits (sign column)" "DELETE FROM DX; INSERT INTO DX (ID, V) SELECT ID, FL FROM TF WHERE ID = 4; INSERT INTO DX (ID, V) SELECT ID, DP FROM TX WHERE ID IN (1, 9); SELECT ID, V FROM DX ORDER BY ID;"
refuses "ins-sel 1e330 -> FLOAT refuses (engine 22003)"  "INSERT INTO DX (ID, F) SELECT ID, DP * 1E+300 FROM TX WHERE ID = 4;"
refuses "ins-sel FL * 2 (6.8e38) -> FLOAT refuses (engine 22003)" "INSERT INTO DX (ID, F) SELECT ID, FL * 2 FROM TX WHERE ID = 7;"
agree "FLOAT column untouched by the refused stores; 3.4e38 itself stores" "INSERT INTO DX (ID, F) SELECT ID, DP FROM TX WHERE ID = 7; SELECT ID, F FROM DX WHERE ID IN (4, 7) ORDER BY ID;"
echo "-- verify-found (round 2): MERGE - a FLOAT source compared in ON matches by its own value; a WHEN condition / SET expression compares the bare literal --"
agree "MERGE ON T.F = SRC.FL matches every non-integer FLOAT row" "DELETE FROM DX; INSERT INTO DX (ID, F, DP) SELECT ID, FL, FL FROM TX; MERGE INTO DX USING (SELECT ID, FL FROM TX) SRC ON (DX.F = SRC.FL AND DX.ID = SRC.ID) WHEN MATCHED THEN UPDATE SET I = 1; MERGE INTO DX USING (SELECT ID, FL FROM TX) SRC ON (DX.DP = SRC.FL) WHEN MATCHED THEN UPDATE SET N = 1; SELECT ID, I, N FROM DX ORDER BY ID;"
agree "MERGE WHEN .. AND SRC.FL = 2.675 (single-precision TRUE), SET IIF(SRC.FL = 1.1 ..)" "MERGE INTO DX USING (SELECT ID, FL FROM TX) SRC ON (DX.ID = SRC.ID) WHEN MATCHED AND SRC.FL = 2.675 THEN UPDATE SET V = 'hit'; MERGE INTO DX USING (SELECT ID, FL FROM TX) SRC ON (DX.ID = SRC.ID) WHEN MATCHED THEN UPDATE SET I = IIF(SRC.FL = 1.1, 7, 0); SELECT ID, V, I FROM DX ORDER BY ID;"
agree "stored PBW after the verify-found sections" "select id, cast(d34 as varchar(40)) a, cast(d16 as varchar(40)) b from pbw where id in (1, 2, 3, 9, 78, 790, 791) order by id;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS dfparambind" || echo "FAIL dfparambind"
exit $fail
