#!/bin/bash
# A `?` INSIDE a DML value expression converts AT ITS SLOT, before the
# arithmetic - not after it.
#
# The engine reads the driver's value at the slot the describe announced
# and evaluates from there, so `(I) VALUES (? * 2)` bound 1.6 is 2 * 2 =
# 4. fire-crab spliced the raw value and computed 3.2, storing 3 - a
# SILENT wrong store, and the same for every exact destination.
#
# The describe is the DESTINATION's own type, pushed down the tree
# (SQLDA_DISPLAY: `(N) VALUES (? * 2)` over NUMERIC(9,2) announces LONG
# scale -2), with two overrides the engine's PASS1_set_parameter_type
# makes: a CAST types its own operand, and COALESCE types from its other
# arguments (`COALESCE(?, 0)` is a plain INTEGER - 2^40 overflows it).
#
# COALESCE pushes NO type into its arguments, which has a second edge:
# a parameter under a MULTIPLY, a DIVIDE or a unary MINUS there is still
# UNKNOWN when that node is made, and the engine RAISES rather than
# answering - `COALESCE(? * 2, 0.5)` is "-expression evaluation not
# supported / Invalid data type for multiplication in dialect 3", with
# `2 * ?`, `? / 2`, `2 / ?`, `? * 1.0` the same and `-?` carrying
# negation's own message. `? + 0`, `? - 0` and `0 - ?` are fine and take
# the SIBLING's scale, as do a CAST and a nested COALESCE. NULLIF, IIF
# and CASE are not this rule: they push the destination down and take
# `? * 2` at its type.
#
# A MERGE takes ALL of it, in both branches: its markers are read back
# as a tree and typed by the same resolver, so `SET DF = COALESCE(?, 0)`
# stores the engine's 1 and not the 1.1000000000000001 that typing from
# the destination column produced.
#
# THE MULTIPLY ASYMMETRY, measured cell by cell into NUMERIC(9,2) with
# 1.115 bound: the LEFT operand of a multiply converts at SCALE 0 while
# everything else takes the destination's scale -
#
#     ? * 2    -> 2.00   (the value became 1)      2 * ?  -> 2.24
#     ? * 2.0  -> 2.00                             ? / 2  -> 0.56
#     ? + 0    -> 1.12                             ? - 0  -> 1.12
#
# and into NUMERIC(9,4) `? * 2` bound 1.11115 is 2.0000. `? * ?`,
# `? * <column>`, `(? * 2) + 0` and `? * 2 * 2` follow the same LEFT-operand
# rule; a DOUBLE destination keeps its double (2.23). The DESCRIBE still
# announces the destination's scale in every one of those, so the slot
# published and the conversion applied genuinely differ.
#
# Usage: qa/serve-real-slottype.sh [port]   (default 4193)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4193}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/slot-eng.fdb"; FC="$D/slot-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/slot-build.log 2>&1 <<'SQL'
CREATE TABLE T (ID INTEGER, I INTEGER, N NUMERIC(9,2), N4 NUMERIC(9,4), DP DOUBLE PRECISION, DF DECFLOAT(34), D16 DECFLOAT(16), BI BIGINT, SM SMALLINT);
CREATE TABLE U (ID INTEGER, I INTEGER, N NUMERIC(9,2), DF DECFLOAT(34));
INSERT INTO U VALUES (1, 2, 1.00, 1);
CREATE TABLE MG (ID INTEGER, I INTEGER, N NUMERIC(9,2), DF DECFLOAT(34));
INSERT INTO MG VALUES (1, 10, 10.00, 10);
INSERT INTO MG VALUES (2, 10, 10.00, 10);
INSERT INTO MG VALUES (3, 10, 10.00, 10);
INSERT INTO MG VALUES (4, 10, 10.00, 10);
INSERT INTO MG VALUES (5, 10, 10.00, 10);
INSERT INTO MG VALUES (6, 10, 10.00, 10);
INSERT INTO MG VALUES (7, 10, 10.00, 10);
INSERT INTO MG VALUES (8, 10, 10.00, 10);
INSERT INTO MG VALUES (9, 10, 10.00, 10);
INSERT INTO MG VALUES (10, 10, 10.00, 10);
INSERT INTO MG VALUES (11, 10, 10.00, 10);
INSERT INTO MG VALUES (12, 10, 10.00, 10);
INSERT INTO MG VALUES (13, 10, 10.00, 10);
INSERT INTO MG VALUES (14, 10, 10.00, 10);
INSERT INTO MG VALUES (15, 10, 10.00, 10);
INSERT INTO MG VALUES (16, 10, 10.00, 10);
INSERT INTO MG VALUES (17, 10, 10.00, 10);
INSERT INTO MG VALUES (18, 10, 10.00, 10);
COMMIT;
SQL
if grep -qi error /tmp/slot-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/slot-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-slot.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
run() { # <port> <db> <sql> <json>
    FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
          if(e2){console.log("ERR "+String(e2.message||e2).replace(/\n/g," | ").trim());db.detach();process.exit(0);}
          if(!r||!r.length){console.log("(ok)");db.detach();process.exit(0);}
          console.log(r.map(x=>Object.values(x).join()).join(";"));db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
# a DML statement on both, then the STORED value read back through isql
# (node cannot describe a DECFLOAT projection - it answers -804)
stored() { # <conn> <col> <id> <table>
    printf 'SET LIST ON;\nSELECT %s FROM %s WHERE ID = %s;\n' "$2" "$4" "$3" \
        | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | grep -a "^$2 " | sed 's/  */ /g'
}
both() { # <label> <sql> <json> <col> <id> [table, default T]
    local e f se sf tbl="${6:-T}"
    e=$(run 3050 "$ENG" "$2" "$3"); f=$(run "$PORT" "$FC" "$2" "$3")
    se=$(stored "127.0.0.1/3050:$ENG" "$4" "$5" "$tbl"); sf=$(stored "127.0.0.1/$PORT:$FC" "$4" "$5" "$tbl")
    if [ "$e" = "$f" ] && [ "$se" = "$sf" ]; then echo "OK   $1 [$3] => $e / $se"
    else echo "DIFF $1 [$3]"; echo "     eng: $e / $se"; echo "     fc:  $f / $sf"; fail=1; fi
}
# fire-crab DECLINES a shape the ENGINE also refuses, so there is no
# value to compare - only that fc does not INVENT one. Defined HERE,
# beside [both], because a helper defined after its call sites is not a
# helper at all: this gate carried two `refuses` lines it never defined,
# and bash reported "refuses: command not found" on stderr while the
# gate still printed PASS. Both lines asserted nothing for as long as
# they existed; they are real checks below now.
refuses_fc() { # <label> <sql> <json>
    local f; f=$(run "$PORT" "$FC" "$2" "$3")
    case "$f" in
        ERR*) echo "OK   $1 (fc refuses)" ;;
        *) echo "FAIL $1 (fc should refuse)"; echo "     fc: $f"; fail=1 ;;
    esac
}

echo "-- the value converts at its slot, BEFORE the arithmetic --"
both "INTEGER dest, ? * 2"        "INSERT INTO T (ID, I) VALUES (1, ? * 2)"   '[1.6]'     I  1
both "BIGINT dest, ? * 2"         "INSERT INTO T (ID, BI) VALUES (2, ? * 2)"  '[1.6]'     BI 2
both "INTEGER dest, ? + 1"        "INSERT INTO T (ID, I) VALUES (3, ? + 1)"   '[2.5]'     I  3
both "INTEGER dest, ? / 3"        "INSERT INTO T (ID, I) VALUES (4, ? / 3)"   '[10]'      I  4
both "SMALLINT dest, ? * 2"       "INSERT INTO T (ID, SM) VALUES (5, ? * 2)"  '[1.6]'     SM 5

echo "-- the MULTIPLY asymmetry: only the LEFT operand converts at scale 0 --"
both "NUMERIC(9,2), ? * 2"        "INSERT INTO T (ID, N) VALUES (10, ? * 2)"  '[1.115]'   N  10
both "NUMERIC(9,2), 2 * ?"        "INSERT INTO T (ID, N) VALUES (11, 2 * ?)"  '[1.115]'   N  11
both "NUMERIC(9,2), ? * 2.0"      "INSERT INTO T (ID, N) VALUES (12, ? * 2.0)" '[1.115]'  N  12
both "NUMERIC(9,2), ? / 2"        "INSERT INTO T (ID, N) VALUES (13, ? / 2)"  '[1.115]'   N  13
both "NUMERIC(9,2), ? + 0"        "INSERT INTO T (ID, N) VALUES (14, ? + 0)"  '[1.115]'   N  14
both "NUMERIC(9,2), ? - 0"        "INSERT INTO T (ID, N) VALUES (15, ? - 0)"  '[1.115]'   N  15
both "NUMERIC(9,4), ? * 2"        "INSERT INTO T (ID, N4) VALUES (16, ? * 2)" '[1.11115]' N4 16
both "NUMERIC(9,2), ? * 2 * 2"    "INSERT INTO T (ID, N) VALUES (17, ? * 2 * 2)" '[1.115]' N 17
both "NUMERIC(9,2), (? * 2) + 0"  "INSERT INTO T (ID, N) VALUES (18, (? * 2) + 0)" '[1.115]' N 18
both "NUMERIC(9,2), ? * ?"        "INSERT INTO T (ID, N) VALUES (19, ? * ?)"  '[1.115, 2]' N 19
both "NUMERIC(9,2), bare ?"       "INSERT INTO T (ID, N) VALUES (20, ?)"      '[1.115]'   N  20

echo "-- an APPROXIMATE destination keeps its double --"
both "DOUBLE dest, ? * 2"         "INSERT INTO T (ID, DP) VALUES (30, ? * 2)" '[1.115]'   DP 30
both "DOUBLE dest, ? / 3"         "INSERT INTO T (ID, DP) VALUES (31, ? / 3)" '[10]'      DP 31

echo "-- a DECFLOAT destination: the arithmetic is decimal --"
both "DECFLOAT(34), ? / 3"        "INSERT INTO T (ID, DF) VALUES (40, ? / 3)" '[10]'      DF 40
both "DECFLOAT(34), ? * 3"        "INSERT INTO T (ID, DF) VALUES (41, ? * 3)" '[0.1]'     DF 41
both "DECFLOAT(34), bare ?"       "INSERT INTO T (ID, DF) VALUES (42, ?)"     '[10]'      DF 42
both "DECFLOAT(16), ? / 3"        "INSERT INTO T (ID, D16) VALUES (43, ? / 3)" '[10]'     D16 43

echo "-- COALESCE types from its OTHER arguments, and overflows there --"
both "COALESCE(?, 0) fits"        "INSERT INTO T (ID, I) VALUES (50, COALESCE(?, 0))" '[7]' I 50
both "COALESCE(?, 0) 2^40"        "INSERT INTO T (ID, I) VALUES (51, COALESCE(?, 0))" '[1099511627776]' I 51
both "COALESCE(?, 0) NULL"        "INSERT INTO T (ID, I) VALUES (52, COALESCE(?, 0))" '[null]' I 52

echo "-- ... and the SIBLING's own scale wins, not the destination's --"
# COALESCE builds its own descriptor from the arguments that are not
# parameters: beside a 0.5 the slot is INT64 scale -1 and 1.115 stores
# 1.10, where the column's own scale 2 would have kept 1.12 (measured)
both "COALESCE(?, 0.5) scale -1"  "INSERT INTO T (ID, N) VALUES (60, COALESCE(?, 0.5))" '[1.115]' N 60
both "COALESCE(? + 0, 0.5)"       "INSERT INTO T (ID, N) VALUES (61, COALESCE(? + 0, 0.5))" '[1.115]' N 61
both "COALESCE(? - 0, 0.5)"       "INSERT INTO T (ID, N) VALUES (62, COALESCE(? - 0, 0.5))" '[1.115]' N 62
both "COALESCE(0 - ?, 0.5)"       "INSERT INTO T (ID, N) VALUES (63, COALESCE(0 - ?, 0.5))" '[1.115]' N 63
both "COALESCE(CAST(? AS INT),.5)" "INSERT INTO T (ID, N) VALUES (64, COALESCE(CAST(? AS INTEGER), 0.5))" '[1.6]' N 64
both "COALESCE(?, ?, 0.5)"        "INSERT INTO T (ID, N) VALUES (65, COALESCE(?, ?, 0.5))" '[null, 1.115]' N 65

echo "-- a param under * / - INSIDE a COALESCE is the ENGINE'S OWN ERROR --"
# COALESCE pushes NO type into its arguments, so the parameter is still
# UNKNOWN when the arithmetic above it is made - and the engine raises
# "-expression evaluation not supported / Invalid data type for
# multiplication in dialect 3" (division and negation carry their own
# message). fire-crab used to answer these: COALESCE(? * 2, 0.5) bound
# 1.115 STORED 2.00 where the engine stores nothing at all.
#
# NULLIF, IIF and CASE are NOT this rule - they push the DESTINATION
# down and take `? * 2` at its type, which is why they are checked
# against the engine's value just below rather than refused.
refuses_fc "COALESCE(? * 2, 0.5)"  "INSERT INTO T (ID, N) VALUES (70, COALESCE(? * 2, 0.5))" '[1.115]'
refuses_fc "COALESCE(2 * ?, 0.5)"  "INSERT INTO T (ID, N) VALUES (71, COALESCE(2 * ?, 0.5))" '[1.115]'
refuses_fc "COALESCE(? / 2, 0.5)"  "INSERT INTO T (ID, N) VALUES (72, COALESCE(? / 2, 0.5))" '[1.115]'
refuses_fc "COALESCE(2 / ?, 0.5)"  "INSERT INTO T (ID, N) VALUES (73, COALESCE(2 / ?, 0.5))" '[1.115]'
refuses_fc "COALESCE(-?, 0.5)"     "INSERT INTO T (ID, N) VALUES (74, COALESCE(-?, 0.5))"    '[1.115]'
refuses_fc "COALESCE(? * 1.0, .5)" "INSERT INTO T (ID, N) VALUES (75, COALESCE(? * 1.0, 0.5))" '[1.115]'
refuses_fc "UPDATE COALESCE(? * 2)" "UPDATE U SET N = COALESCE(? * 2, 0.5) WHERE ID = 1"    '[1.115]'
both "NULLIF(? * 2, 0) answers"    "INSERT INTO T (ID, N) VALUES (76, NULLIF(? * 2, 0))" '[1.115]' N 76
both "IIF(.., ? * 2, 0) answers"   "INSERT INTO T (ID, N) VALUES (77, IIF(1 > 0, ? * 2, 0))" '[1.115]' N 77
both "CASE WHEN .. ? * 2 answers"  "INSERT INTO T (ID, N) VALUES (78, CASE WHEN 1 > 0 THEN ? * 2 ELSE 0 END)" '[1.115]' N 78

echo "-- UPDATE ... SET takes the same law --"
both "UPDATE SET N = ? * 2"       "UPDATE U SET N = ? * 2 WHERE ID = 1"       '[1.115]'   N  1 U
both "UPDATE SET N = 2 * ?"       "UPDATE U SET N = 2 * ? WHERE ID = 1"       '[1.115]'   N  1 U
both "UPDATE SET I = ? * 2"       "UPDATE U SET I = ? * 2 WHERE ID = 1"       '[1.6]'     I  1 U
both "UPDATE SET DF = ? / 3"      "UPDATE U SET DF = ? / 3 WHERE ID = 1"      '[10]'      DF 1 U

echo "-- a MERGE takes the same law, in both branches --"
# each check matches its OWN seeded row, so one never reads another's write
mg() { printf 'MERGE INTO MG USING (SELECT %s AS K FROM RDB$DATABASE) S ON MG.ID = S.K WHEN MATCHED THEN UPDATE SET %s' "$1" "$2"; }
mgi() { printf 'MERGE INTO MG USING (SELECT %s AS K FROM RDB$DATABASE) S ON MG.ID = S.K WHEN NOT MATCHED THEN INSERT (ID, %s) VALUES (S.K, %s)' "$1" "$2" "$3"; }
both "MERGE UPDATE I = ? * 2"     "$(mg 1 'I = ? * 2')"   '[1.6]'     I  1 MG
both "MERGE UPDATE N = ? * 2"     "$(mg 2 'N = ? * 2')"   '[1.115]'   N  2 MG
both "MERGE UPDATE N = 2 * ?"     "$(mg 3 'N = 2 * ?')"   '[1.115]'   N  3 MG
both "MERGE UPDATE N = ? / 2"     "$(mg 4 'N = ? / 2')"   '[1.115]'   N  4 MG
both "MERGE UPDATE N = ? + 0"     "$(mg 5 'N = ? + 0')"   '[1.115]'   N  5 MG
both "MERGE UPDATE DF = ? / 3"    "$(mg 6 'DF = ? / 3')"  '[10]'      DF 6 MG
both "MERGE UPDATE DF = ? * 3"    "$(mg 7 'DF = ? * 3')"  '[0.1]'     DF 7 MG
both "MERGE UPDATE N = ? (bare)"  "$(mg 8 'N = ?')"       '[1.115]'   N  8 MG
both "MERGE INSERT I = ? * 2"     "$(mgi 101 I '? * 2')"  '[1.6]'     I  101 MG
both "MERGE INSERT N = ? * 2"     "$(mgi 102 N '? * 2')"  '[1.115]'   N  102 MG
both "MERGE INSERT N = 2 * ?"     "$(mgi 103 N '2 * ?')"  '[1.115]'   N  103 MG
both "MERGE INSERT DF = ? / 3"    "$(mgi 104 DF '? / 3')" '[10]'      DF 104 MG
both "MERGE INSERT DF = ? * 3"    "$(mgi 105 DF '? * 3')" '[0.1]'     DF 105 MG
echo "-- ... and a marker in the ON / WHEN-AND still COMPARES, never converts --"
both "MERGE ON param + SET param"  "MERGE INTO MG USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON MG.ID = S.K AND MG.I = ? WHEN MATCHED THEN UPDATE SET N = ?" '[10, 5]' N 1 MG
both "MERGE WHEN-AND param"        "MERGE INTO MG USING (SELECT 2 AS K FROM RDB\$DATABASE) S ON MG.ID = S.K WHEN MATCHED AND MG.I = ? THEN UPDATE SET N = ? * 2" '[10, 1.115]' N 2 MG

echo "-- a MERGE's marker inside a CALL takes the CALL's type, both branches --"
# WAS A REFUSAL: MERGE types a marker from its DESTINATION COLUMN pushed
# down the value TEXT, which reproduces the destination rule only -
# admitting `SET DF = COALESCE(?, 0)` that way STORED 1.1000000000000001
# where the engine stores 1. The value text is now read back as a TREE
# (its FC$P markers become `?` again) and typed by the SAME resolver the
# plain INSERT and UPDATE use, so the engine's own overrides apply.
# Every cell measured on both sides, one statement per fresh row.
both "MERGE UPDATE DF = COALESCE(?, 0)"   "$(mg 9 'DF = COALESCE(?, 0)')"   '[1.1]'   DF 9  MG
both "MERGE UPDATE N = COALESCE(?, 0)"    "$(mg 11 'N = COALESCE(?, 0)')"   '[1.115]' N  11 MG
both "MERGE UPDATE N = COALESCE(?, 0.5)"  "$(mg 12 'N = COALESCE(?, 0.5)')" '[1.115]' N  12 MG
both "MERGE UPDATE DF = CAST(? AS INT)"   "$(mg 13 'DF = CAST(? AS INTEGER)')" '[1.6]' DF 13 MG
both "MERGE UPDATE I = CAST(? AS INT)"    "$(mg 14 'I = CAST(? AS INTEGER)')"  '[1.6]' I  14 MG
both "MERGE UPDATE N = COALESCE(?+0,0.5)" "$(mg 15 'N = COALESCE(? + 0, 0.5)')" '[1.115]' N 15 MG
# the slot COALESCE gives is a plain INTEGER, and 2^40 OVERFLOWS IT: the
# engine answers 22003 and leaves the row alone. fire-crab reported a
# bare "Dynamic SQL Error" here - the overflow was swallowed by the
# generic "cannot write as a literal" refusal on the substitution path -
# while its own plain UPDATE twin already answered 22003
both "MERGE UPDATE I = COALESCE(?, 0) 2^40" "$(mg 10 'I = COALESCE(?, 0)')" '[1099511627776]' I 10 MG
both "MERGE INSERT DF = COALESCE(?, 0)"   "$(mgi 106 DF 'COALESCE(?, 0)')"  '[1.1]'   DF 106 MG
both "MERGE INSERT N = COALESCE(?, 0.5)"  "$(mgi 107 N 'COALESCE(?, 0.5)')" '[1.115]' N  107 MG
both "MERGE INSERT DF = CAST(? AS INT)"   "$(mgi 108 DF 'CAST(? AS INTEGER)')" '[1.6]' DF 108 MG
# and the engine's own refusal reaches the MERGE branches too
refuses_fc "MERGE COALESCE(? * 2, 0.5)"   "$(mg 16 'N = COALESCE(? * 2, 0.5)')" '[1.115]'
refuses_fc "MERGE COALESCE(-?, 0.5)"      "$(mg 17 'N = COALESCE(-?, 0.5)')"    '[1.115]'
refuses_fc "MERGE INSERT COALESCE(?*2,0)" "$(mgi 109 N 'COALESCE(? * 2, 0.5)')" '[1.115]'

[ $fail -eq 0 ] && echo "PASS serve-real-slottype" || { echo "FAIL serve-real-slottype"; exit 1; }
