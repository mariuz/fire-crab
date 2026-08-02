#!/bin/bash
# `<dml> RETURNING <columns>` over the wire, against the REAL engine as a
# twin.
#
# Every check runs the SAME statement through the SAME driver
# (node-firebird) against TWO servers - fire-crab and the live Firebird -
# each with its own copy of an identical database, and requires:
#
#   * the same ROWS back (RETURNING is a cursor in Firebird 5: an UPDATE
#     that touches three rows returns three, not one), and
#   * the same TABLE afterwards - because a statement that returns the
#     right rows and writes the wrong thing is the failure this clause
#     invites.
#
# The values are the engine's: an INSERT and an UPDATE return the row as it
# stands AFTER the statement, a DELETE the row as it was.
#
#   qa/serve-real-returning.sh [port]
#
# Builds two identical scratch databases; the engine's copy is chmod 666 so
# the SERVER's own user can open it.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4325}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-ret-crab.fdb"
B="$D/fc-ret-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
# both driver generations (the outblr pattern): stock 2.11.0 and the
# patched 2.14.1 dispatch IDENTICALLY on the announced statement type,
# so the singleton shape must hold through both
N211="${N211:-/home/ubuntu/conceptual-architecture-for-firebird-paper/samples/nodejs/node_modules}"
N214="${N214:-${NODE_PATH:-/home/ubuntu/work}}"
NODE_PATH="$N211" node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird 2.11.0 not found"; exit 0; }
NODE_PATH="$N214" node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird 2.14.1 not found"; exit 0; }
mkdir -p "$D"
fail=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, AMT INTEGER, NAME VARCHAR(20));
CREATE TABLE G (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER DEFAULT 7);
CREATE TABLE WPK (A INTEGER NOT NULL PRIMARY KEY, B VARCHAR(10));
CREATE TABLE NOPK (A INTEGER, B VARCHAR(10));
CREATE TABLE SRC (X INTEGER, Y VARCHAR(10));
CREATE TABLE DST (X INTEGER, Y VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 10, 'aa');
INSERT INTO T VALUES (2, 20, 'bb');
INSERT INTO T VALUES (3, NULL, 'cc');
INSERT INTO NOPK VALUES (9, 'a');
INSERT INTO NOPK VALUES (9, 'b');
INSERT INTO SRC VALUES (1, 'u');
INSERT INTO SRC VALUES (2, 'v');
INSERT INTO SRC VALUES (3, 'w');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-returning.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
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

query() { # <sql> <port> <db> [node_modules-path]
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env NODE_PATH="${4:-${NODE_PATH:-}}" FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              const rows=Array.isArray(r)?r:(r?[r]:[]);
              // THE SHAPE IS PART OF THE ANSWER: the engine delivers
              // insert-values RETURNING as ONE OBJECT (stmt type 8 ->
              // op_execute2 singleton) and UPDATE/DELETE RETURNING as an
              // ARRAY. This marker used to be normalized away, which is
              // exactly how the array-of-one divergence survived the gate.
              console.log((Array.isArray(r)?"ARR ":"OBJ ")+JSON.stringify(rows));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

qparam() { # <sql> <json-params> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PARAMS="$2" FC_PORT="$3" FC_DB="$4" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,JSON.parse(process.env.FC_PARAMS),(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              const rows=Array.isArray(r)?r:(r?[r]:[]);
              console.log((Array.isArray(r)?"ARR ":"OBJ ")+JSON.stringify(rows));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

tprobe() { # <sql> <port> <db> - prepare only, print the ANNOUNCED type
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.transaction(F.ISOLATION_READ_COMMITTED,(e1,tr)=>{
              if(e1){console.log("TR_ERR");process.exit(0);}
              tr.newStatement(process.env.FC_Q,(e2,st)=>{
                if(e2){console.log("PREP_ERR");process.exit(0);}
                console.log("TYPE "+st.type);
                tr.rollback(()=>{db.detach();process.exit(0);});});});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

# --- the three statements, each returning what it touched -------------
both "INSERT ... RETURNING (the stored row)" \
     "INSERT INTO T VALUES (9, 90, 'zz') RETURNING ID, AMT, NAME"
both "UPDATE ... RETURNING one row (the NEW values)" \
     "UPDATE T SET AMT = AMT + 1 WHERE ID = 9 RETURNING ID, AMT"
both "UPDATE ... RETURNING MANY rows - a cursor, not a singleton" \
     "UPDATE T SET AMT = AMT + 1 WHERE AMT IS NOT NULL RETURNING ID, AMT"
both "DELETE ... RETURNING (the row as it WAS)" \
     "DELETE FROM T WHERE ID = 9 RETURNING ID, NAME, AMT"

# --- zero rows: an empty cursor, not an error --------------------------
both "UPDATE matching nothing returns no rows" \
     "UPDATE T SET NAME = 'x' WHERE ID = 99 RETURNING ID"
both "DELETE matching nothing returns no rows" \
     "DELETE FROM T WHERE ID = 99 RETURNING ID"

# --- the columns themselves --------------------------------------------
both "a single returned column" "INSERT INTO T VALUES (11, 110, 'k') RETURNING ID"
both "a NULL column comes back NULL" \
     "INSERT INTO T (ID, NAME) VALUES (12, 'n') RETURNING ID, AMT"
both "a DEFAULT filled in by the insert is returned" \
     "INSERT INTO G (ID) VALUES (1) RETURNING ID, N"
# a qualifier is allowed when it names the TABLE ...
both "a TABLE-qualified column in the list" \
     "INSERT INTO T VALUES (13, 130, 'q') RETURNING T.ID, T.AMT"

# --- the TABLE afterwards ---------------------------------------------
# a statement that returns the right rows and writes the wrong thing is
# exactly what this clause invites
both "the table after every statement above" \
     "SELECT ID, AMT, NAME FROM T ORDER BY ID"
both "and the second table" "SELECT ID, N FROM G ORDER BY ID"

# --- THE ANNOUNCED STATEMENT TYPE --------------------------------------
# probed against FB6: the engine types INSERT ... VALUES ... RETURNING
# as isc_info_sql_stmt_exec_procedure (8) - the driver dispatches on it
# to op_execute2 and delivers ONE OBJECT - while UPDATE and DELETE
# RETURNING stay cursors (1, fetchAll, an array). fc announced 1 for
# all three; the OBJ/ARR markers above pin the delivered shape, this
# block pins the type that DRIVES it. Prepare-only, rolled back.
for probe in "INSERT INTO T VALUES (30, 300, 'tt') RETURNING ID:TYPE 8" \
             "UPDATE T SET AMT = AMT WHERE ID = 1 RETURNING ID:TYPE 1" \
             "DELETE FROM T WHERE ID = 99999 RETURNING ID:TYPE 1"; do
    sql=${probe%:*}; wanttype=${probe##*:}
    a=$(tprobe "$sql" "$PORT" "$A")
    b=$(tprobe "$sql" "$REAL" "$B")
    if [ "$a" = "$b" ] && [ "$a" = "$wanttype" ]; then
        echo "OK   announced type $a: $sql"
    else
        echo "DIFF announced type of [$sql]: fcwire [$a] engine [$b] want [$wanttype]"; fail=1
    fi
done

# --- a PARAMETERIZED singleton: the input message must BIND ------------
# type 8 sends the parameters through op_execute2, whose input message
# fc used to read and DISCARD - this is the check that path binds
a=$(qparam "INSERT INTO T (ID, AMT) VALUES (?, ?) RETURNING ID, AMT" "[60, 61]" "$PORT" "$A")
b=$(qparam "INSERT INTO T (ID, AMT) VALUES (?, ?) RETURNING ID, AMT" "[60, 61]" "$REAL" "$B")
if [ "$a" = "$b" ] && [ "${a#OBJ }" != "$a" ]; then
    echo "OK   parameterized INSERT ... RETURNING binds through execute2: $a"
else
    echo "DIFF parameterized INSERT ... RETURNING"
    echo "     fcwire: $a"; echo "     engine: $b"; fail=1
fi

# --- the singleton through BOTH driver generations ---------------------
# stock 2.11.0 gates its op_execute2 dispatch on protocol >= 13 and the
# patched 2.14.1 dispatches unconditionally; fc negotiates 20, so both
# must see the SAME single object
for NP in "$N211" "$N214"; do
    gen=$(NODE_PATH="$NP" node -e 'console.log(require("node-firebird/package.json").version)' 2>/dev/null)
    a=$(query "INSERT INTO T (ID, AMT, NAME) VALUES (70, 700, 'g') RETURNING ID, AMT" "$PORT" "$A" "$NP")
    b=$(query "INSERT INTO T (ID, AMT, NAME) VALUES (70, 700, 'g') RETURNING ID, AMT" "$REAL" "$B" "$NP")
    if [ "$a" = "$b" ] && [ "${a#OBJ }" != "$a" ]; then
        echo "OK   node-firebird $gen delivers the singleton as ONE OBJECT: $a"
    else
        echo "DIFF singleton through node-firebird $gen"
        echo "     fcwire: $a"; echo "     engine: $b"; fail=1
    fi
done

# --- refusals ----------------------------------------------------------
# an expression in the RETURNING list is not converted; the statement must
# be REFUSED at prepare rather than run with an empty cursor - a write
# that happened while the client saw nothing is the worst outcome here
r=$(query "INSERT INTO T VALUES (20, 200, 'e') RETURNING AMT * 2" "$PORT" "$A")
after=$(query "SELECT COUNT(*) FROM T WHERE ID = 20" "$PORT" "$A")
case "$r:$after" in
    ERR*:*'"COUNT":0'*)
        echo "OK   an expression in RETURNING is refused, and nothing was written" ;;
    *) echo "DIFF expression RETURNING: [$r] table after: [$after]"; fail=1 ;;
esac

# ... and NEW./OLD. do NOT exist in DSQL - they are the PSQL trigger
# contexts. The engine answers `Column unknown, "NEW"."ID"`, so fire-crab
# must refuse too: accepting them would return rows for a statement the
# engine rejects AND write a row the engine never writes. This check is
# why the gate compares the TABLE as well as the rows.
a=$(query "INSERT INTO T VALUES (21, 210, 'x') RETURNING NEW.ID" "$PORT" "$A")
b=$(query "INSERT INTO T VALUES (21, 210, 'x') RETURNING NEW.ID" "$REAL" "$B")
aft_a=$(query "SELECT COUNT(*) FROM T WHERE ID = 21" "$PORT" "$A")
aft_b=$(query "SELECT COUNT(*) FROM T WHERE ID = 21" "$REAL" "$B")
case "$a:$b:$aft_a:$aft_b" in
    ERR*:ERR*:*'"COUNT":0'*:*'"COUNT":0'*)
        echo "OK   NEW.<col> is refused by BOTH, and neither wrote the row" ;;
    *) echo "DIFF NEW.<col>: fcwire [$a] engine [$b] rows [$aft_a] [$aft_b]"; fail=1 ;;
esac

# --- QUOTED-IDENTIFIER CASE in the RETURNING list ----------------------
# The engine matches a QUOTED name EXACTLY against the catalog and folds
# a bare one (probed): `RETURNING "id"` is -206 `Column unknown, "id"` -
# and writes NOTHING - while `RETURNING ID`, `id` and `"ID"` all answer.
# The same rule gates the table qualifier: `"t".ID` refuses where `t.ID`
# and `"T".ID` answer. fc used to strip the quotes and match
# case-insensitively - rows returned AND a row written for statements
# the engine refuses, this clause's worst outcome, so the refusing forms
# check the TABLE as well as the error.
refused_no_write() { # <label> <sql> <id>
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    aft_a=$(query "SELECT COUNT(*) FROM T WHERE ID = $3" "$PORT" "$A")
    aft_b=$(query "SELECT COUNT(*) FROM T WHERE ID = $3" "$REAL" "$B")
    case "$a:$b:$aft_a:$aft_b" in
        ERR*:ERR*:*'"COUNT":0'*:*'"COUNT":0'*)
            echo "OK   $1 is refused by BOTH, and neither wrote the row" ;;
        *) echo "DIFF $1: fcwire [$a] engine [$b] rows [$aft_a] [$aft_b]"; fail=1 ;;
    esac
}
refused_no_write 'INSERT ... RETURNING "id" (quoted-lowercase)' \
    "INSERT INTO T VALUES (80, 800, 'q1') RETURNING \"id\"" 80
refused_no_write 'INSERT ... RETURNING "t".ID (quoted-lowercase table)' \
    "INSERT INTO T VALUES (81, 810, 'q2') RETURNING \"t\".ID" 81
both 'RETURNING "ID" (quoted-uppercase) answers' \
     "INSERT INTO T VALUES (82, 820, 'q3') RETURNING \"ID\""
both 'RETURNING id (bare lowercase) folds and answers' \
     "INSERT INTO T VALUES (83, 830, 'q4') RETURNING id"
both 'RETURNING "T".ID (quoted-uppercase table) answers' \
     "INSERT INTO T VALUES (84, 840, 'q5') RETURNING \"T\".ID"
both 'RETURNING t."ID" (bare table, quoted column) answers' \
     "INSERT INTO T VALUES (85, 850, 'q6') RETURNING t.\"ID\""
# UPDATE and DELETE run the same matching
a=$(query "UPDATE T SET AMT = AMT WHERE ID = 1 RETURNING \"amt\"" "$PORT" "$A")
b=$(query "UPDATE T SET AMT = AMT WHERE ID = 1 RETURNING \"amt\"" "$REAL" "$B")
case "$a:$b" in
    ERR*:ERR*) echo 'OK   UPDATE ... RETURNING "amt" is refused by BOTH' ;;
    *) echo "DIFF UPDATE RETURNING \"amt\": fcwire [$a] engine [$b]"; fail=1 ;;
esac
both 'UPDATE ... RETURNING "AMT" answers' \
     "UPDATE T SET AMT = AMT + 1 WHERE ID = 85 RETURNING \"AMT\""
# a refused DELETE must leave its target row IN PLACE on both sides
a=$(query "DELETE FROM T WHERE ID = 1 RETURNING \"id\"" "$PORT" "$A")
b=$(query "DELETE FROM T WHERE ID = 1 RETURNING \"id\"" "$REAL" "$B")
aft_a=$(query "SELECT COUNT(*) FROM T WHERE ID = 1" "$PORT" "$A")
aft_b=$(query "SELECT COUNT(*) FROM T WHERE ID = 1" "$REAL" "$B")
case "$a:$b:$aft_a:$aft_b" in
    ERR*:ERR*:*'"COUNT":1'*:*'"COUNT":1'*)
        echo 'OK   DELETE ... RETURNING "id" is refused by BOTH, row kept' ;;
    *) echo "DIFF DELETE RETURNING \"id\": fcwire [$a] engine [$b] rows [$aft_a] [$aft_b]"; fail=1 ;;
esac
both 'DELETE ... RETURNING "ID" answers' \
     "DELETE FROM T WHERE ID = 85 RETURNING \"ID\""
both "the table after the quoted-identifier block" \
     "SELECT ID, AMT, NAME FROM T ORDER BY ID"

# --- UPDATE OR INSERT ... RETURNING ------------------------------------
# probed against FB6: the upsert's RETURNING is a 1-row CURSOR (ARR, not
# the insert-values OBJ singleton) - the insert branch answers the
# STORED row, the update branch the AFTER image; a MATCHING that updates
# TWO rows returns BOTH (one row per updated row - no singleton error in
# FB6). fc used to refuse all of these at prepare: dml_table_name took
# the token after UPDATE - `OR` - as the table.
both "upsert RETURNING, insert branch (ARR, the stored row)" \
     "UPDATE OR INSERT INTO WPK (A, B) VALUES (1, 'one') RETURNING A, B"
both "upsert RETURNING, update branch (ARR, the AFTER image)" \
     "UPDATE OR INSERT INTO WPK (A, B) VALUES (1, 'uno') RETURNING A, B"
a=$(query "UPDATE OR INSERT INTO NOPK (A, B) VALUES (9, 'z') MATCHING (A) RETURNING A, B" "$PORT" "$A")
b=$(query "UPDATE OR INSERT INTO NOPK (A, B) VALUES (9, 'z') MATCHING (A) RETURNING A, B" "$REAL" "$B")
want='ARR [{"A":9,"B":"z"},{"A":9,"B":"z"}]'
if [ "$a" = "$b" ] && [ "$a" = "$want" ]; then
    echo "OK   MATCHING multi-match returns one row PER updated row: $a"
else
    echo "DIFF MATCHING multi-match RETURNING"
    echo "     fcwire: $a"; echo "     engine: $b"; echo "     want:   $want"; fail=1
fi
both "both files' NOPK after the multi-match" "SELECT A, B FROM NOPK ORDER BY A, B"
# PK-less upsert without MATCHING refuses AT PREPARE - with RETURNING
# wrapped around it the vector must NOT move to execute time (the
# pass-through: wrap_returning never sees a RefusedEval plan)
a=$(query "UPDATE OR INSERT INTO NOPK (A, B) VALUES (1, 'x') RETURNING A" "$PORT" "$A")
b=$(query "UPDATE OR INSERT INTO NOPK (A, B) VALUES (1, 'x') RETURNING A" "$REAL" "$B")
aft_a=$(query "SELECT COUNT(*) FROM NOPK WHERE A = 1" "$PORT" "$A")
aft_b=$(query "SELECT COUNT(*) FROM NOPK WHERE A = 1" "$REAL" "$B")
case "$a:$b:$aft_a:$aft_b" in
    ERR*"Primary key required on table"*:ERR*"Primary key required on table"*:*'"COUNT":0'*:*'"COUNT":0'*)
        echo "OK   PK-less upsert RETURNING refuses at prepare with the engine's vector, nothing written" ;;
    *) echo "DIFF PK-less upsert RETURNING: fcwire [$a] engine [$b] rows [$aft_a] [$aft_b]"; fail=1 ;;
esac

# --- INSERT INTO ... SELECT ... RETURNING ------------------------------
# probed: multi-row RETURNING is real in FB6 - a three-row source writes
# three rows and returns ALL THREE as a cursor, in select order; a
# zero-row source answers an EMPTY cursor (records affected 0), not an
# error. fc used to prepare this and then die at execute (no InsertSelect
# arm in execute_dml_collecting) - writing NOTHING while announcing a
# cursor.
a=$(query "INSERT INTO DST (X, Y) SELECT X, Y FROM SRC RETURNING X, Y" "$PORT" "$A")
b=$(query "INSERT INTO DST (X, Y) SELECT X, Y FROM SRC RETURNING X, Y" "$REAL" "$B")
want='ARR [{"X":1,"Y":"u"},{"X":2,"Y":"v"},{"X":3,"Y":"w"}]'
if [ "$a" = "$b" ] && [ "$a" = "$want" ]; then
    echo "OK   INSERT..SELECT..RETURNING returns every inserted row, in select order: $a"
else
    echo "DIFF INSERT..SELECT..RETURNING"
    echo "     fcwire: $a"; echo "     engine: $b"; echo "     want:   $want"; fail=1
fi
both "zero-row source: an EMPTY cursor, and nothing written" \
     "INSERT INTO DST (X, Y) SELECT X, Y FROM SRC WHERE X > 999 RETURNING X, Y"
both "both files' DST after the insert-selects" "SELECT X, Y FROM DST ORDER BY X"

# --- the announced types of the new forms ------------------------------
# probed [node-eng newStatement().type]: plain upsert and bare
# insert-select are type 2 (insert); BOTH RETURNING forms are type-1
# CURSORS - unlike insert-values RETURNING, which is the type-8
# singleton pinned above
for probe in "UPDATE OR INSERT INTO WPK (A, B) VALUES (5, 'five'):TYPE 2" \
             "UPDATE OR INSERT INTO WPK (A, B) VALUES (5, 'five') RETURNING A, B:TYPE 1" \
             "INSERT INTO DST (X, Y) SELECT X, Y FROM SRC:TYPE 2" \
             "INSERT INTO DST (X, Y) SELECT X, Y FROM SRC RETURNING X, Y:TYPE 1"; do
    sql=${probe%:*}; wanttype=${probe##*:}
    a=$(tprobe "$sql" "$PORT" "$A")
    b=$(tprobe "$sql" "$REAL" "$B")
    if [ "$a" = "$b" ] && [ "$a" = "$wanttype" ]; then
        echo "OK   announced type $a: $sql"
    else
        echo "DIFF announced type of [$sql]: fcwire [$a] engine [$b] want [$wanttype]"; fail=1
    fi
done

rm -f "$A" "$B"
exit $fail
