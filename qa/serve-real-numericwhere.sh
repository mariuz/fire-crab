#!/bin/bash
# WHERE predicates over scaled NUMERIC/DECIMAL and INT128 columns - the
# surface col_kind never classified (statements fell back to the fixed
# answer). Comparisons now decompose both sides into (raw, scale) and
# align exactly in i128 - the engine's dialect-3 compare - so integer
# and decimal literals, BETWEEN/IN desugarings, NULL tests, NOT, and
# `?` parameters (bound with their wire scale) all work; decimal
# literals also work against plain INT columns (A > 9.5), and INSERT /
# UPDATE SET take decimal literals that rescale exactly into their
# target (1.5 -> NUMERIC(9,2) 1.50; 1.5 into an INTEGER refuses - the
# engine rounds there, fire-crab never writes an inexact value).
#
# The differential is the engine, three ways:
#   1. every predicate runs through fire-crab (node) AND through isql
#      on the SAME file, selecting the integer ID only - identical row
#      sets, no render normalization in the way;
#   2. fire-crab UPDATEs and DELETEs through numeric predicates and
#      INSERTs decimal literals; the engine mirrors on a ref copy and
#      the tables match;
#   3. gbak round trip and gfix -v -full.
#
#   qa/serve-real-numericwhere.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4289}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-numw-work.fdb"; REF="$D/fc-numw-ref.fdb"
FBK="$D/fc-numw-work.fbk"; RST="$D/fc-numw-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE TABLE T (ID INTEGER, A INTEGER, N NUMERIC(9,2), M NUMERIC(18,4), I INT128);
COMMIT;
INSERT INTO T VALUES (1, 10, 12.50, 0.0001, 42);
INSERT INTO T VALUES (2, 3, -1.25, 7.0000, -5000000000);
INSERT INTO T VALUES (3, 9, NULL, 123.4567, NULL);
INSERT INTO T VALUES (4, -8, 2.00, NULL, 0);
COMMIT;
-- wide-valued rows for the DECFLOAT-literal section (section 1b). Written
-- by the ENGINE here: a wide INT128 LITERAL in INSERT VALUES is a separate
-- surface fire-crab does not yet parse; this slice is the READ/compare side.
-- Rows 1 and 2 differ only past the 34th significant digit, so both round
-- to the same DECFLOAT(34).
CREATE TABLE W (ID INTEGER, K INT128, NB NUMERIC(38,0));
COMMIT;
INSERT INTO W VALUES (1, 170141183460469231731687303715884100000, 170141183460469231731687303715884100000);
INSERT INTO W VALUES (2, 170141183460469231731687303715884105727, 170141183460469231731687303715884105727);
INSERT INTO W VALUES (3, 5, 5);
INSERT INTO W VALUES (4, -170141183460469231731687303715884105728, -170141183460469231731687303715884105728);
COMMIT;
-- DECFLOAT columns (section 1c): the decimal128 comparison surface. Row 6
-- is +Infinity (a normal ordered value, no trap); row 7 is NaN, which the
-- engine TRAPS on any comparison (SQLSTATE 22000) - kept in its own table
-- DFNAN so it does not poison the finite matrix.
CREATE TABLE DF2 (ID INTEGER, D DECFLOAT(34), S DECFLOAT(16));
COMMIT;
INSERT INTO DF2 VALUES (1, 100, 100);
INSERT INTO DF2 VALUES (2, 1.5, 1.5);
INSERT INTO DF2 VALUES (3, -2.5, -2.5);
INSERT INTO DF2 VALUES (4, 340282366920938463463374607431768211455, 250);
INSERT INTO DF2 VALUES (5, NULL, NULL);
INSERT INTO DF2 VALUES (6, CAST('Infinity' AS DECFLOAT(34)), 7);
COMMIT;
CREATE TABLE DFNAN (ID INTEGER, D DECFLOAT(34));
COMMIT;
INSERT INTO DFNAN VALUES (1, 5);
INSERT INTO DFNAN VALUES (2, CAST('NaN' AS DECFLOAT(34)));
COMMIT;
-- empty target for the wide-INT128-literal INSERT section (1d): fire-crab
-- WRITES the rows, the engine reading the same file back is the check
CREATE TABLE WI (ID INTEGER, W INT128, N2 NUMERIC(38,2), DF DECFLOAT(34), D16 DECFLOAT(16), B BIGINT);
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP
EOF
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-numw.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
node_q() { # <query> [json params]
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" FC_P="${2:-[]}" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||!r.length){console.log("OK");db.detach();process.exit(0);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v)).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_q "$1" "${2:-[]}")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}
# a predicate through fire-crab vs the ENGINE on the same file
predq() { # <label> <where-clause>
    fc=$(node_run "SELECT ID FROM T WHERE $2 ORDER BY ID")
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<SQL | strip | grep -v '^$' | tr '\n' ' ' | strip
SET HEADING OFF;
SELECT ID FROM T WHERE $2 ORDER BY ID;
SQL
)
    fc=$(printf '%s' "$fc" | tr '\n' ' ' | strip)
    check "$1 [$2]" "$fc" "$is"
}

# --- 1. the predicate matrix: fire-crab == engine, same file -----------
predq "scaled equality, written scale"   "N = 12.50"
predq "scaled equality, shorter scale"   "N = 12.5"
predq "scaled vs integer literal"        "N > 3"
predq "scaled negative bound"            "N <= -1.25"
predq "scaled inequality"                "N <> 2"
predq "scaled NULL test"                 "N IS NULL"
predq "scaled BETWEEN"                   "N BETWEEN 1 AND 20"
predq "scaled IN with a decimal"         "N IN (99, 12.50)"
predq "NOT over a scaled compare"        "NOT (N < 5)"
predq "fine-scale equality"              "M = 0.0001"
predq "INT128 equality"                  "I = 42"
predq "INT128 negative range"            "I > -5"
predq "INT128 below an i64 literal"      "I < 5000000000"
predq "decimal literal vs INT column"    "A > 9.5"
predq "mixed AND/OR across kinds"        "N > 0 AND I >= 0 OR A = 3"
# a parameter binds with its wire scale
fcp=$(node_run 'SELECT ID FROM T WHERE M = ? ORDER BY ID' '[7]' | tr '\n' ' ' | strip)
check "numeric parameter (M = ? bound 7)" "$fcp" "2"

# --- 1b. a DECFLOAT(34) literal (magnitude PAST i128::MAX) against the
# exact-numeric columns. The engine promotes BOTH sides to decimal128 - the
# COLUMN rounded to 34 significant digits, HALF-UP - so an INT128 literal
# like i128::MAX+1, which rounds DOWN to ...884100000, is matched by BOTH a
# column holding exactly that AND one holding i128::MAX (...884105727, which
# rounds to the same 34 digits). A DECFLOAT literal never keys an index; a
# DECFLOAT COLUMN in WHERE is a separate surface fire-crab does not resolve.
predw() { # <label> <where-clause> - fire-crab vs the ENGINE, same file, table W
    fc=$(node_run "SELECT ID FROM W WHERE $2 ORDER BY ID" | tr '\n' ' ' | strip)
    # node_q prints "OK" for an EMPTY result set; the engine prints nothing
    [ "$fc" = "OK" ] && fc=""
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<SQL | strip | grep -v '^$' | tr '\n' ' ' | strip
SET HEADING OFF;
SELECT ID FROM W WHERE $2 ORDER BY ID;
SQL
)
    check "$1 [$2]" "$fc" "$is"
}
# the ROUNDING boundary: rows 1 and 2 both equal the rounded literal
predw "INT128 col = DECFLOAT lit (round boundary)"  "K = 170141183460469231731687303715884105728"
predw "NUMERIC col = DECFLOAT lit (round boundary)" "NB = 170141183460469231731687303715884105728"
predw "INT128 col < DECFLOAT lit"                   "K < 340282366920938463463374607431768211455"
predw "INT128 col > DECFLOAT lit"                   "K > 340282366920938463463374607431768211455"
predw "INT128 col <> DECFLOAT lit"                  "K <> 340282366920938463463374607431768211455"
predw "INT128 col >= negative DECFLOAT lit"         "K >= -340282366920938463463374607431768211455"
predw "INT128 col < negative DECFLOAT lit"          "K < -340282366920938463463374607431768211455"
predw "NUMERIC col < DECFLOAT lit"                  "NB < 340282366920938463463374607431768211455"
predw "DECFLOAT lit both bounds (AND)"              "K < 340282366920938463463374607431768211455 AND K > -340282366920938463463374607431768211455"
# a SCALED numeric column (scale != 0) vs a DECFLOAT literal: the column's
# scale IS its decimal exponent, so the promotion must not negate it
predq "scaled NUMERIC(9,2) col < DECFLOAT lit"      "N < 340282366920938463463374607431768211455"
predq "fine NUMERIC(18,4) col > -DECFLOAT lit"      "M > -340282366920938463463374607431768211455"

# --- 1c. DECFLOAT COLUMNS: the decimal128 comparison surface ------------
predf() { # <label> <where-clause> - fire-crab vs the ENGINE, same file, table DF2
    fc=$(node_run "SELECT ID FROM DF2 WHERE $2 ORDER BY ID" | tr '\n' ' ' | strip)
    [ "$fc" = "OK" ] && fc=""
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<SQL | strip | grep -v '^$' | tr '\n' ' ' | strip
SET HEADING OFF;
SELECT ID FROM DF2 WHERE $2 ORDER BY ID;
SQL
)
    check "$1 [$2]" "$fc" "$is"
}
predf "DECFLOAT col = int lit"        "D = 100"
predf "DECFLOAT col = decimal lit"    "D = 1.5"
predf "DECFLOAT col > decimal lit"    "D > 2.5"
predf "DECFLOAT col <= neg decimal"   "D <= -2.5"
predf "DECFLOAT col <> int lit"       "D <> 100"
predf "DECFLOAT col IS NULL"          "D IS NULL"
predf "DECFLOAT col IS NOT NULL"      "D IS NOT NULL"
predf "DECFLOAT col BETWEEN"          "D BETWEEN 1 AND 200"
predf "DECFLOAT col IN"               "D IN (100, 1.5)"
predf "DECFLOAT col NOT (<)"          "NOT (D < 5)"
predf "DECFLOAT col = wide (>i128)"   "D = 340282366920938463463374607431768211455"
predf "DECFLOAT col = 1 vs 1 int"     "D = 100"
predf "DECFLOAT col > 0 (+Infinity)"  "D > 0"
predf "DECFLOAT(16) col = int"        "S = 100"
predf "DECFLOAT(16) col = decimal"    "S = 1.5"
predf "DECFLOAT(16) col <= neg"       "S <= -2.5"
# a NaN column value TRAPS on comparison (SQLSTATE 22000), as the engine
# does - fire-crab raises the identical isc_decfloat_invalid_operation
raisef() { # <label> <where-clause>
    fce=$(FC_DB="$WORK" FC_PORT="$PORT" FC_Q="SELECT ID FROM DFNAN WHERE $2" FC_P='[]' timeout 15 node -e '
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("ATT");process.exit(0);}
        db.query(process.env.FC_Q,[],(er)=>{console.log(er?("ERR "+(er.gdscode||er.message||"")):"NOERR");db.detach();process.exit(0);});
      });' 2>/dev/null)
    ise=$("$ISQL" -q -user "$U" -pas "$P" "$WORK" <<SQL 2>&1 | grep -oiE 'SQLSTATE = [0-9]+' | head -1
SELECT ID FROM DFNAN WHERE $2;
SQL
)
    case "$fce" in ERR*) fcok=raise ;; *) fcok=noraise ;; esac
    case "$ise" in *22000*) isok=raise ;; *) isok=noraise ;; esac
    check "NaN traps [$2]" "$fcok/$isok" "raise/raise"
}
raisef "NaN > 0"  "D > 0"
raisef "NaN <> 5" "D <> 5"

# --- 1d. WIDE INT128 LITERAL in INSERT VALUES --------------------------
# The value-list tokenizer reads a magnitude past i64 as Tok::Int128; the
# store now encodes it into an exact-numeric column (rescaling in i128) or
# a DECFLOAT(34) (promoting to decimal128) instead of refusing. fire-crab
# WRITES the rows; the ENGINE reading the SAME file back byte-identically
# (compared here as fc-served isql vs engine-read isql, one render) is the
# proof the stored bytes are the engine's.
inswide() { node_run "INSERT INTO WI (ID, $1) VALUES ($2, $3)" >/dev/null; }
inswide "W"  1 "99999999999999999999"                            # INT128
inswide "W"  2 "170141183460469231731687303715884105727"         # i128::MAX
inswide "W"  3 "-170141183460469231731687303715884105728"        # i128::MIN
inswide "N2" 4 "99999999999999999999"                            # NUMERIC(38,2), rescales x100
inswide "DF" 5 "99999999999999999999"                            # DECFLOAT(34), exact
inswide "DF" 6 "170141183460469231731687303715884105727"         # DECFLOAT(34), rounds to 34 sig
# a magnitude PAST i128::MAX is a DECFLOAT literal (Tok::DecFloat34); it
# stores into the DECFLOAT(34) column verbatim (already 34-sig in the token)
inswide "DF" 7 "340282366920938463463374607431768211455"                     # u128::MAX
inswide "DF" 8 "-9999999999999999999999999999999999999999999999999999"       # negative, 52 nines
# small integer and decimal literals into DECFLOAT columns too (the scale
# IS the exponent, cohort preserved); DECFLOAT(16) via the decimal64 encoder
inswide "DF"  10 "1.5"                                            # DECFLOAT(34), cohort 15e-1
inswide "DF"  11 "-2.50"                                          # DECFLOAT(34), cohort 250e-2
inswide "D16" 12 "100"                                            # DECFLOAT(16), small int
inswide "D16" 13 "1.5"                                            # DECFLOAT(16), decimal
inswide "D16" 14 "99999999999999999999"                          # DECFLOAT(16), wide int -> 16 sig
inswide "D16" 15 "340282366920938463463374607431768211455"       # DECFLOAT(16), past-i128 -> 16 sig
wi_read() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^$' | tr -s ' \n' ' '
SET HEADING OFF;
SELECT ID, W, N2, DF, D16 FROM WI ORDER BY ID;
SQL
}
check "wide-literal INSERT: fc-served == engine-read (same file)" \
      "$(wi_read "127.0.0.1/$PORT:$WORK")" "$(wi_read "$WORK")"
# a wide literal into a too-narrow BIGINT column: both REJECT the write
# (the engine raises 22003 at execute, fire-crab refuses at prepare - the
# row must not land either way)
bigovf=$(node_run 'INSERT INTO WI (ID, B) VALUES (9, 99999999999999999999)')
case "$bigovf" in ERR*) echo "OK   wide literal into BIGINT refuses (overflow)" ;;
    *) echo "DIFF wide-into-BIGINT should refuse, got: $bigovf"; fail=1 ;; esac
landed=$(node_run 'SELECT COUNT(*) FROM WI WHERE B IS NOT NULL')
check "the rejected BIGINT row did not land" "$landed" "0"
# a PAST-i128 literal into an INT128 column overflows - it does not fit an
# exact integer (the engine raises 22003; fire-crab refuses); row must not land
pi_ovf=$(node_run 'INSERT INTO WI (ID, W) VALUES (10, 340282366920938463463374607431768211455)')
case "$pi_ovf" in ERR*) echo "OK   past-i128 literal into INT128 refuses (overflow)" ;;
    *) echo "DIFF past-i128-into-INT128 should refuse, got: $pi_ovf"; fail=1 ;; esac

# --- 2. DML through numeric predicates + decimal literals --------------
check "fc INSERT with decimal literals" \
      "$(node_run 'INSERT INTO T (ID, A, N, M, I) VALUES (5, 1, 3.75, 2.5, 9)')" "OK"
check "fc UPDATE SET a decimal through a scaled WHERE" \
      "$(node_run 'UPDATE T SET N = 9.25 WHERE N = 2.00')" "OK"
check "fc DELETE through a fine-scale WHERE" \
      "$(node_run 'DELETE FROM T WHERE M = 0.0001')" "OK"
case "$(node_run 'INSERT INTO T (ID, A) VALUES (9, 1.5)')" in
    ERR*) echo "OK   an inexact decimal into INTEGER refuses (the engine would round)" ;;
    *) echo "DIFF inexact-decimal refusal"; fail=1 ;; esac
kill $srv 2>/dev/null; wait $srv 2>/dev/null

"$ISQL" -q -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (ID, A, N, M, I) VALUES (5, 1, 3.75, 2.5, 9);
UPDATE T SET N = 9.25 WHERE N = 2.00;
DELETE FROM T WHERE M = 0.0001;
COMMIT;
SQL
dump() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT ID||'|'||COALESCE(A,-99)||'|'||COALESCE(N,-99)||'|'||COALESCE(M,-99)||'|'||COALESCE(I,-99) FROM T ORDER BY ID;
SQL
}
work_d=$(dump "$WORK")
check "the DML through numeric predicates matches the engine" "$work_d" "$(dump "$REF")"
case "$work_d" in
    *"5|1|3.75|2.5000|9"*) echo "OK   the decimal literals landed exactly (3.75, 2.5000)" ;;
    *) echo "DIFF the dump comparison was vacuous"; echo "     $work_d"; fail=1 ;;
esac

# --- 3. gbak and gfix ---------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-numw-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-numw-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-numw-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-numw-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-numw-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
