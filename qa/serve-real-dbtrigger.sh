#!/bin/bash
# DATABASE TRIGGERS - the trigger class that belongs to the ATTACHMENT
# rather than to a table.
#
# Firebird fires five events that no relation owns: ON CONNECT (8192),
# ON DISCONNECT (8193), and ON TRANSACTION START / COMMIT / ROLLBACK
# (8194/8195/8196). They are how a database sets up session context,
# audits who connected, or refuses a login outright. This server read
# them from the catalog and IGNORED them: a database configured with an
# ON CONNECT trigger behaved, through fire-crab, as though it had none -
# silently, which is the one outcome this project does not allow.
#
# The laws, each probed against the live engine first:
#
#   1. ON CONNECT fires once per attachment, BEFORE the client's first
#      transaction, in a transaction of ITS OWN - the engine's connect
#      row lands before the first `tx-start` row and brings no `tx-start`
#      of its own, so an internal transaction fires nothing.
#   2. ON TRANSACTION COMMIT and ON TRANSACTION ROLLBACK fire INSIDE the
#      transaction that is ending. That is visible: a ROLLBACK trigger's
#      own rows GO BACK WITH THE ROLLBACK - they are simply absent
#      afterwards - while the generator it drew from HAS moved, a draw
#      not being transactional. (This is why Firebird's own
#      documentation tells you to write rollback auditing inside an
#      autonomous transaction.)
#   3. ON DISCONNECT fires at the detach.
#   4. A body may do anything the trigger chunks allow - write other
#      tables, read them, draw a generator - because it fires where no
#      statement is running, so nothing is holding a working copy.
#
# The gate compares THE LOG THE TRIGGERS THEMSELVES WROTE: the same
# script runs against both servers over twin databases, and the ordered
# list of events each file ends up holding must be identical.
#
# What this server does NOT do, recorded rather than hidden:
#
#   * CREATE TRIGGER ... ON CONNECT refuses cleanly (nothing is stored -
#     checked). The triggers here are made by the ENGINE on both files;
#     what is under test is FIRING them.
#   * whether a file carries database triggers at all is read ONCE, at
#     the attach, so that the far commoner file with none pays nothing
#     per transaction. A trigger another attachment creates AFTER this
#     one began is therefore not seen by it until it reconnects.
#   * a body's own statement is rendered back to SQL, and that renderer
#     has no CONCATENATION - `'sum=' || :N` refuses (last boundary
#     below) rather than storing something else.
#
#   qa/serve-real-dbtrigger.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4974}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-dbtrig-crab.fdb"
B="$D/fc-dbtrig-engine.fdb"
LOG="/tmp/fc-serve-dbtrig-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() {
    sed "s|@DB@|$1|" > "$D/dbtrig.sql" <<'SQL'
CREATE DATABASE '@DB@' USER 'SYSDBA' PASSWORD 'masterkey' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE LOGT (ID INTEGER, W VARCHAR(20), N INTEGER);
CREATE TABLE T (ID INTEGER, A INTEGER);
CREATE TABLE C (ID INTEGER, A INTEGER);
CREATE SEQUENCE S;
COMMIT;
INSERT INTO C VALUES (1, 10);
INSERT INTO C VALUES (2, 20);
COMMIT;
SET TERM ^ ;
CREATE TRIGGER DB_CONN ON CONNECT AS
BEGIN
  INSERT INTO LOGT (ID, W) VALUES (NEXT VALUE FOR S, 'connect');
END^
CREATE TRIGGER DB_DISC ON DISCONNECT AS
BEGIN
  INSERT INTO LOGT (ID, W) VALUES (NEXT VALUE FOR S, 'disconnect');
END^
CREATE TRIGGER DB_TXS ON TRANSACTION START AS
BEGIN
  INSERT INTO LOGT (ID, W) VALUES (NEXT VALUE FOR S, 'tx-start');
END^
CREATE TRIGGER DB_TXC ON TRANSACTION COMMIT AS
BEGIN
  INSERT INTO LOGT (ID, W) VALUES (NEXT VALUE FOR S, 'tx-commit');
END^
CREATE TRIGGER DB_TXR ON TRANSACTION ROLLBACK AS
BEGIN
  INSERT INTO LOGT (ID, W) VALUES (NEXT VALUE FOR S, 'tx-rollback');
END^
SET TERM ; ^
COMMIT;
DELETE FROM LOGT;
COMMIT;
SQL
    rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" -i "$D/dbtrig.sql" >/dev/null 2>&1
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

# THE ACTING CONNECTION IS THE NODE DRIVER, not isql: this gate compares
# WHAT EACH SERVER FIRES, and isql does not issue the same ops to both
# (it opened two transactions against the engine where it opened one
# against this server for the same script - a client-behaviour
# difference that would drown the thing under test). The driver makes
# EXACTLY the same calls to both: one attach, one transaction per
# `session`, then the log read back over the SAME connection so the
# reading itself is identical on both sides too.
session() { # <port> <db> <verb: commit|rollback> <sql...>
    timeout 25 env FC_PORT="$1" FC_DB="$2" FC_VERB="$3" FC_SQL="$4" node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
      const F=require("node-firebird");
      const stmts=process.env.FC_SQL.split("|").filter(x=>x.length);
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.transaction(F.ISOLATION_READ_COMMITTED,(e1,tx)=>{
          if(e1){console.log("CONN_ERR");process.exit(0);}
          const run=(i)=>{
            if(i>=stmts.length){
              const fin=(e3)=>{
                if(e3){console.log("ERR end");db.detach();process.exit(0);}
                // read the log back on the SAME connection
                db.query("SELECT W, N FROM LOGT ORDER BY ID",(e4,r)=>{
                  if(e4){console.log("ERR read");db.detach();process.exit(0);}
                  console.log((r||[]).map(x=>String(x.W).trim()+(x.N==null?"":"="+x.N)).join(","));
                  db.detach();process.exit(0);});
              };
              if(process.env.FC_VERB==="rollback") tx.rollback(fin); else tx.commit(fin);
              return;
            }
            tx.query(stmts[i],(e2)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,40));db.detach();process.exit(0);}
              run(i+1);});
          };
          run(0);
        });
      });' 2>/dev/null
}
run_both() { # <label> <verb> <sql joined by |>
    e=$(session "$REAL" "$B" "$2" "$3")
    c=$(session "$PORT" "$A" "$2" "$3")
    check "$1" "$c" "$e"
}
wipe() {
    for db in "$A" "$B"; do
        printf 'DELETE FROM LOGT; COMMIT;\n' | "$ISQL" -q -user "$U" -pas "$P" "$db" >/dev/null 2>&1
    done
}

# ---- the lifecycle ------------------------------------------------------
# ONE attachment, ONE transaction, committed: connect, tx-start, the
# work, tx-commit - and the read that follows is a transaction of its
# own, so its tx-start is in the answer too
wipe
run_both "a connection that commits" commit "INSERT INTO T (ID, A) VALUES (1, 1)"
wipe
run_both "...one that ROLLS BACK: the rollback body's own rows go with it" rollback "INSERT INTO T (ID, A) VALUES (2, 2)"
wipe
run_both "two statements in one transaction" commit "INSERT INTO T (ID, A) VALUES (3, 3)|INSERT INTO T (ID, A) VALUES (4, 4)"
wipe
run_both "a connection that only reads" commit "SELECT COUNT(*) AS N FROM T"

# ---- the generator moved even where the rows did not -------------------
# a draw is not transactional, so a rolled-back trigger body still spent
# its number - the two files must have spent the SAME ones
e=$(printf 'SET LIST ON; SELECT GEN_ID(S, 0) AS G FROM RDB$DATABASE;\n' | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf 'SET LIST ON; SELECT GEN_ID(S, 0) AS G FROM RDB$DATABASE;\n' | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the sequence stands at the same number on both" "$c" "$e"

# ---- a body that reads, and one that writes what it read ---------------
# CREATING a database trigger is a surface of its own and this server
# does not compile one, so the ENGINE creates it on BOTH files - what is
# under test here is FIRING it
for db in "$A" "$B"; do
"$ISQL" -q -user "$U" -pas "$P" "$db" >/dev/null 2>&1 <<'SQL'
SET TERM ^ ;
CREATE TRIGGER DB_TXS2 ON TRANSACTION START POSITION 5 AS
DECLARE VARIABLE N INTEGER;
BEGIN
  SELECT SUM(A) FROM C INTO :N;
  INSERT INTO LOGT (ID, W, N) VALUES (NEXT VALUE FOR S, 'sum', :N);
END^
SET TERM ; ^
COMMIT;
SQL
done
wipe
run_both "a START body that READS a table, in POSITION order after the first" \
  commit "INSERT INTO C (ID, A) VALUES (3, 30)"

# ---- ...AND THIS SERVER WRITES ONE --------------------------------------
# the other half of the surface: CREATE TRIGGER ... ON CONNECT compiled
# HERE, its catalog row and BLR compared BYTE FOR BYTE with the one the
# engine writes for the same source, and then the ENGINE RUNS IT
CA="$D/fc-dbtrig-mk-crab.fdb"
CB="$D/fc-dbtrig-mk-engine.fdb"
mk_plain() { # <file>
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 <<SQL
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE L (ID INTEGER, N INTEGER);
CREATE SEQUENCE SQ;
COMMIT;
SQL
    chmod 666 "$1"
}
mk_plain "$CA"; mk_plain "$CB"
# the DDL itself: through THIS server for one file, the engine for the other
ddl='SET TERM ^ ;
CREATE TRIGGER DBC ON CONNECT AS BEGIN INSERT INTO L (ID, N) VALUES (NEXT VALUE FOR SQ, 1); END^
CREATE TRIGGER DBTC ON TRANSACTION COMMIT POSITION 3 AS
DECLARE VARIABLE V INTEGER;
BEGIN
  V = 2;
  INSERT INTO L (ID, N) VALUES (NEXT VALUE FOR SQ, :V);
END^
SET TERM ; ^
COMMIT;'
printf '%s\n' "$ddl" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$CA" >/dev/null 2>&1
printf '%s\n' "$ddl" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$CB" >/dev/null 2>&1
catq() { "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | norm
SET HEADING OFF;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'|'||COALESCE(TRIM(t.RDB$RELATION_NAME),'<null>')||'|'||t.RDB$TRIGGER_TYPE||'|'||t.RDB$TRIGGER_SEQUENCE||'|'||t.RDB$TRIGGER_INACTIVE||'|'||t.RDB$SYSTEM_FLAG||'|'||t.RDB$FLAGS||'|'||t.RDB$VALID_BLR
FROM RDB$TRIGGERS t WHERE t.RDB$SYSTEM_FLAG = 0 ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(t.RDB$TRIGGER_NAME)||'#'||CAST(CAST(t.RDB$TRIGGER_BLR AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS)||'#'||CAST(CAST(t.RDB$DEBUG_INFO AS BLOB SUB_TYPE 0) AS VARCHAR(300) CHARACTER SET OCTETS)
FROM RDB$TRIGGERS t WHERE t.RDB$SYSTEM_FLAG = 0 ORDER BY t.RDB$TRIGGER_NAME;
SELECT TRIM(d.RDB$DEPENDENT_NAME)||'|'||TRIM(d.RDB$DEPENDED_ON_NAME)||'|'||COALESCE(TRIM(d.RDB$FIELD_NAME),'-')||'|'||d.RDB$DEPENDENT_TYPE||'|'||d.RDB$DEPENDED_ON_TYPE
FROM RDB$DEPENDENCIES d WHERE d.RDB$DEPENDENT_NAME STARTING WITH 'DB' ORDER BY 1;
SQL
}
check "the catalog row, the BLR and the debug info are the engine's, byte for byte" \
    "$(catq "$CA")" "$(catq "$CB")"
# ...and the engine RUNS what this server compiled. The two files have
# seen different DDL paths, so the counts are levelled first: the log is
# emptied on both, then EXACTLY ONE attachment is made to each.
for f in "$CA" "$CB"; do
    printf 'DELETE FROM L; COMMIT;\n' | "$ISQL" -q -user "$U" -pas "$P" "$f" >/dev/null 2>&1
done
for f in "$CA" "$CB"; do
    printf 'SELECT 1 FROM RDB$DATABASE;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$f" >/dev/null 2>&1
done
ea=$(printf 'SET LIST ON; SELECT N, COUNT(*) AS C FROM L GROUP BY N ORDER BY N;\n' | "$ISQL" -q -user "$U" -pas "$P" "$CB" 2>&1 | norm)
ca=$(printf 'SET LIST ON; SELECT N, COUNT(*) AS C FROM L GROUP BY N ORDER BY N;\n' | "$ISQL" -q -user "$U" -pas "$P" "$CA" 2>&1 | norm)
check "the ENGINE fires the database trigger THIS server compiled" "$ca" "$ea"
rm -f "$CA" "$CB"

# ---- ON CONNECT IS A GATE, not a notification --------------------------
# a raise in an ON CONNECT body REFUSES THE ATTACH on both servers: the
# connection does not open and the exception is what the client is told
G="$D/fc-dbtrig-gate.fdb"
rm -f "$G"
"$ISQL" -q -b -user "$U" -pas "$P" >/dev/null 2>&1 <<SQL
CREATE DATABASE '$G' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
CREATE TABLE T (ID INTEGER);
COMMIT;
SET TERM ^ ;
CREATE EXCEPTION EXC 'you may not connect'^
CREATE TRIGGER DB_NO ON CONNECT AS
BEGIN
  EXCEPTION EXC;
END^
SET TERM ; ^
COMMIT;
SQL
chmod 666 "$G"
ran=$((ran + 1))
ec=$(printf 'SELECT 1 FROM RDB$DATABASE;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$G" 2>&1 | grep -c "you may not connect")
cc=$(printf 'SELECT 1 FROM RDB$DATABASE;\n' | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$G" 2>&1 | grep -c "you may not connect")
if [ "$ec" = "1" ] && [ "$cc" = "1" ]; then
    echo "OK   an ON CONNECT that raises refuses the attach, with its own message"
else
    echo "DIFF ON CONNECT refusal: engine matched=$ec fire-crab matched=$cc"; fail=1
fi
rm -f "$G"

# ---- a boundary: the body expression grammar ---------------------------
# a body's own statement is rendered back to SQL with the frame's values
# written in, and that renderer has no CONCATENATION - so a body writing
# `'sum=' || :N` refuses rather than storing something else. The engine
# runs it; this is a recorded gap, not a difference in the firing.
"$ISQL" -q -user "$U" -pas "$P" "$A" >/dev/null 2>&1 <<'SQL'
SET TERM ^ ;
CREATE TRIGGER DB_TXS3 ON TRANSACTION START POSITION 9 AS
DECLARE VARIABLE N INTEGER;
BEGIN
  SELECT SUM(A) FROM C INTO :N;
  INSERT INTO LOGT (ID, W) VALUES (NEXT VALUE FOR S, 'sum=' || :N);
END^
SET TERM ; ^
COMMIT;
SQL
ran=$((ran + 1))
r=$(session "$PORT" "$A" commit "SELECT 1 AS X FROM RDB\$DATABASE")
case "$r" in
    CONN_ERR|ERR*) echo "OK   boundary: a body expression with concatenation refuses" ;;
    *) echo "DIFF boundary MOVED: concatenation in a body expression"; echo "     [$r]"; fail=1 ;;
esac

# ---- the engine reads what fire-crab wrote -----------------------------
eng_q="SET LIST ON; SELECT ID, A FROM T ORDER BY ID; SELECT ID, A FROM C ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
