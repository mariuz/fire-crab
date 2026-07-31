#!/bin/bash
# fc-side DEFAULT application on INSERT - the gap the INT128 slice
# surfaced: fire-crab's own INSERT left omitted defaulted columns NULL
# where the engine fills them from the runtime summary.
#
# fire-crab now decodes each omitted column's stored RDB$DEFAULT_VALUE
# BLR (the column's own, else its domain's) and applies it at execute,
# before NOT NULL validation - so an omitted NOT-NULL-with-DEFAULT
# column now inserts exactly as it does through the engine. Supported
# shapes (probed): blr_short/long/int64 literals with their SIGNED
# scale byte (DEFAULT 1.5 = blr_long scale -1 value 15, DEFAULT -3 a
# negative literal), blr_text/text2, DEFAULT NULL, and the clock
# keywords (CURRENT_DATE/TIME/TIMESTAMP, LOCAL*). Session-dependent
# defaults evaluate from the attachment (inc 129): USER is the
# validated login upper-cased, CURRENT_ROLE is 'NONE' (no roles here,
# same as a role-less engine attachment), CURRENT_CONNECTION the
# attachment id, CURRENT_TRANSACTION the id the row's own insert
# allocates.
#
# The differential is the engine, four ways:
#   1. fire-crab INSERTs omitting defaulted columns on one engine-made
#      copy, the engine runs the same INSERTs on the other; the tables
#      match (clock columns compared by date/non-null);
#   2. explicit values still override, DEFAULT NULL stays NULL, a
#      domain default applies and a column default overrides it;
#   3. session defaults fill: USER/ROLE match the engine exactly,
#      distinct connections store distinct CURRENT_CONNECTION ids;
#   4. gbak round trip and gfix -v -full.
#
#   qa/serve-real-insertdefault.sh [port]
#
# Builds its own scratch databases.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4287}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-insdef-work.fdb"; REF="$D/fc-insdef-ref.fdb"
FBK="$D/fc-insdef-work.fbk"; RST="$D/fc-insdef-rst.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST"

SETUP="CREATE TABLE T (ID INTEGER, A INTEGER DEFAULT 7, B NUMERIC(9,2) DEFAULT 1.5,
  C BIGINT DEFAULT 5000000000, E INTEGER DEFAULT -3, F VARCHAR(8) DEFAULT 'hi',
  G CHAR(4) DEFAULT 'ab', H INTEGER DEFAULT NULL, K INTEGER,
  NN INTEGER DEFAULT 9 NOT NULL, I128 INT128 DEFAULT 5);
CREATE DOMAIN DD AS INTEGER DEFAULT 42;
CREATE DOMAIN DO2 AS INTEGER DEFAULT 10;
CREATE TABLE U (X DD, Y DO2 DEFAULT 20, Z VARCHAR(3));
CREATE TABLE V (S INTEGER, TS TIMESTAMP DEFAULT CURRENT_TIMESTAMP, DT DATE DEFAULT CURRENT_DATE);
CREATE TABLE W (S INTEGER, CN BIGINT DEFAULT CURRENT_CONNECTION);
CREATE TABLE SS (ID INTEGER, UU VARCHAR(31) DEFAULT USER, RR VARCHAR(31) DEFAULT CURRENT_ROLE, TX BIGINT DEFAULT CURRENT_TRANSACTION);
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SETUP
EOF
done

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-insdef.log 2>&1 &
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
node_q() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||!r.length){console.log("OK");db.detach();process.exit(0);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_q "$1")
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

# --- 1. fire-crab INSERTs omitting defaulted columns -------------------
check "fc: all defaults incl NOT NULL + INT128 (previously refused/NULL)" \
      "$(node_run 'INSERT INTO T (ID) VALUES (1)')" "OK"
check "fc: explicit values override their defaults" \
      "$(node_run 'INSERT INTO T (ID, A, H) VALUES (2, 100, 55)')" "OK"
check "fc: domain default applies, column default overrides the domain" \
      "$(node_run "INSERT INTO U (Z) VALUES ('q')")" "OK"
check "fc: clock defaults (CURRENT_TIMESTAMP / CURRENT_DATE)" \
      "$(node_run 'INSERT INTO V (S) VALUES (1)')" "OK"
# session defaults evaluate from the attachment (inc 129): each
# node_run is its OWN connection, so two omitted-CN inserts must land
# DISTINCT attachment ids
check "fc: CURRENT_CONNECTION default fills (first connection)" \
      "$(node_run 'INSERT INTO W (S) VALUES (1)')" "OK"
check "fc: CURRENT_CONNECTION default fills (second connection)" \
      "$(node_run 'INSERT INTO W (S) VALUES (3)')" "OK"
check "fc: supplying the session-defaulted column explicitly still overrides" \
      "$(node_run 'INSERT INTO W (S, CN) VALUES (2, 77)')" "OK"
check "fc: USER / CURRENT_ROLE / CURRENT_TRANSACTION defaults fill" \
      "$(node_run 'INSERT INTO SS (ID) VALUES (1)')" "OK"
check "fc reads its defaulted row back" \
      "$(node_run 'SELECT A, C, E, F, K, NN FROM T WHERE ID = 1')" \
      "7|5000000000|-3|hi|<null>|9"
kill $srv 2>/dev/null; wait $srv 2>/dev/null

# --- 2. the engine runs the same INSERTs on the ref --------------------
# (statement 5 is omitted: the engine WOULD fill CURRENT_CONNECTION -
# fire-crab's refusal there is the documented conservative side)
"$ISQL" -q -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
INSERT INTO T (ID) VALUES (1);
INSERT INTO T (ID, A, H) VALUES (2, 100, 55);
INSERT INTO U (Z) VALUES ('q');
INSERT INTO V (S) VALUES (1);
INSERT INTO W (S) VALUES (1);
INSERT INTO W (S) VALUES (3);
INSERT INTO W (S, CN) VALUES (2, 77);
INSERT INTO SS (ID) VALUES (1);
COMMIT;
SQL

dump() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'T|'||ID||'|'||COALESCE(A,-1)||'|'||COALESCE(B,-1)||'|'||COALESCE(C,-1)||'|'||COALESCE(E,-1)
       ||'|'||COALESCE(F,'#')||'|'||COALESCE(G,'#')||'|'||COALESCE(H,-1)||'|'||COALESCE(K,-1)
       ||'|'||NN||'|'||COALESCE(I128,-1) FROM T ORDER BY ID;
SELECT 'U|'||X||'|'||Y||'|'||Z FROM U;
SELECT 'V|'||S||'|'||DT||'|'||IIF(TS IS NULL, 'NULL', 'SET') FROM V;
SELECT 'W|'||S||'|'||IIF(S = 2, CN, IIF(CN > 0, -7, -8)) FROM W ORDER BY S;
SELECT 'S|'||ID||'|'||TRIM(UU)||'|'||TRIM(RR)||'|'||IIF(TX > 0, 'TX+', 'TX?') FROM SS ORDER BY ID;
SQL
}
work_d=$(dump "$WORK")
check "every applied default matches the engine (clock cols by date + set-ness)" \
      "$work_d" "$(dump "$REF")"
case "$work_d" in
    *"T|1|7|1.50|5000000000|-3|hi|ab"*"|-1|-1|9|5"*"U|42|20|q"*)
        echo "OK   the teeth bite: 1.50 scaled, -3 negative, NULL default stayed NULL, domain 42 vs override 20" ;;
    *) echo "DIFF the dump comparison was vacuous"; echo "     $work_d"; fail=1 ;;
esac

# the two omitted-CN rows carry DISTINCT attachment ids on fc's file
dcn=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL' | strip | grep -v '^$'
SET HEADING OFF;
SELECT 'DCN|'||COUNT(DISTINCT CN) FROM W WHERE S IN (1, 3);
SQL
)
check "distinct connections stored distinct CURRENT_CONNECTION ids" "$dcn" "DCN|2"

# --- 3. gbak and gfix ---------------------------------------------------
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-insdef-backup.log 2>&1; then
    echo "OK   gbak backs up the database fire-crab wrote"
else
    echo "DIFF gbak backup"; cat /tmp/fc-insdef-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-insdef-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-insdef-restore.log; then
    echo "OK   gbak RESTORES it"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "error|cannot" /tmp/fc-insdef-restore.log | head; fail=1
fi
valw=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
check "gfix -v -full clean (fc's raw file)" "$(printf '%s' "$valw" | strip)" ""

exit $fail
