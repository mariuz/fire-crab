#!/bin/bash
# SCHEMA-QUALIFIED DDL: `CREATE TABLE PUBLIC.T7`, `CREATE INDEX PUBLIC.IX
# ON PUBLIC.T8`, `REFERENCES PUBLIC.T7`, `CREATE TRIGGER PUBLIC.TR FOR
# PUBLIC.T7`, `"PUBLIC"."T8"`, ...
#
# Every planner read a qualified object name as a malformed one and refused
# at prepare (a SEQUENCE and an EXCEPTION aside). This server serves the
# PUBLIC schema, where an unqualified name lives, so the two spellings are
# one object - the engine prints `"PUBLIC"."T7"` either way. The qualifier
# now comes off the statement's NAME SLOTS only (the object, an index's ON
# table, a trigger's FOR / ON table, a REFERENCES target, COMMENT ON / SET
# GENERATOR / GRANT .. ON names), never a body: a VIEW over `PUBLIC.T7`
# compiles from a copy with the qualifiers dropped - its BLR is
# byte-identical to the unqualified one's on 2196 - and stores its source
# as written.
#
# A schema that DOES NOT EXIST is refused at PREPARE (it beats even the
# savepoint law): `CREATE TABLE "OTHER"."T9" failed / Schema "OTHER" not
# found` (DYN 257, 42000), with no meta-update wrapper.
#
#   qa/serve-real-ddlqualified.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4596}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/ddlq-eng.fdb"; FC="$D/ddlq-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
printf "CREATE DATABASE '127.0.0.1/%s:%s' USER '%s' PASSWORD '%s';
CREATE TABLE BASE (X INTEGER);
INSERT INTO BASE VALUES (1);
INSERT INTO BASE VALUES (2);
COMMIT;\n" "$REAL" "$ENG" "$U" "$P" | "$ISQL" -q -b > /tmp/ddlq-build.log 2>&1
[ -s "$ENG" ] || { echo "FAIL fixture not created"; sed 's/^/   /' /tmp/ddlq-build.log; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" > "/tmp/fc-serve-ddlq-$PORT.log" 2>&1 & srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0; ran=0
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() { # <label> <script> - one isql session on each, the whole output
    ran=$((ran + 1))
    local e c
    e=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\nCOMMIT;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$ENG" 2>&1 | norm)
    c=$(printf 'SET TERM ^ ;\n%s\nSET TERM ; ^\nCOMMIT;\n' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$FC" 2>&1 | norm)
    if [ "$c" = "$e" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
# a catalog blob as hex (BLR) or text, read through the ENGINE's server
blob() { FC_DB="$1" FC_Q="$2" FC_AS="$3" timeout 25 node -e '
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_REAL,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,d)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    d.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      tr.query(process.env.FC_Q,[],(e2,rows)=>{
        if(e2||!rows||!rows.length){console.log("NONE");process.exit(0);}
        const v=Object.values(rows[0])[0];
        if(typeof v!=="function"){console.log("NULL");process.exit(0);}
        v(tr,(e3,n,em)=>{const b=[];em.on("data",c=>b.push(c));em.on("end",()=>{console.log(Buffer.concat(b).toString(process.env.FC_AS));tr.rollback(()=>process.exit(0));});});
      });
    });
  });' 2>/dev/null | tr '\n' ' '; }
same_blob() { # <label> <sql> <hex|utf8>
    ran=$((ran + 1))
    local e c
    e=$(FC_REAL=$REAL blob "$ENG" "$2" "$3"); c=$(FC_REAL=$REAL blob "$FC" "$2" "$3")
    if [ -z "$e" ] || [ "$e" = "NONE " ] || [ "$e" = "CONN_ERR " ]; then echo "FAIL $1 [the engine's object is missing: $e]"; fail=1
    elif [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}
R="RDB\$"

echo "--- 1 every kind takes a PUBLIC-qualified name"
both "1 tables (bare and delimited), a REFERENCES, an index, a trigger, routines, a domain" \
"CREATE TABLE PUBLIC.T7 (X INTEGER NOT NULL, PRIMARY KEY (X))^
CREATE TABLE \"PUBLIC\".\"T8\" (X INTEGER REFERENCES PUBLIC.T7)^
CREATE INDEX PUBLIC.IX7 ON PUBLIC.T8 (X)^
CREATE SEQUENCE PUBLIC.S7^
CREATE EXCEPTION PUBLIC.E7 'x'^
CREATE DOMAIN PUBLIC.D7 INTEGER^
CREATE PROCEDURE PUBLIC.P7 AS BEGIN EXIT; END^
CREATE FUNCTION PUBLIC.F7 RETURNS INTEGER AS BEGIN RETURN 1; END^
CREATE TRIGGER PUBLIC.TR7 FOR PUBLIC.T7 BEFORE INSERT AS BEGIN NEW.X = NEW.X + 1; END^
ALTER TABLE PUBLIC.T7 ADD Y INTEGER^
COMMENT ON TABLE PUBLIC.T7 IS 'c'^
SET GENERATOR PUBLIC.S7 TO 5^"
both "1 they are the unqualified objects" \
"INSERT INTO T7 (X) VALUES (5)^
SELECT X, Y FROM T7^
SELECT GEN_ID(S7, 0) AS G FROM ${R}DATABASE^
SELECT F7() AS F FROM ${R}DATABASE^
SELECT ${R}INDEX_NAME FROM ${R}INDICES WHERE ${R}RELATION_NAME = 'T8' AND ${R}SYSTEM_FLAG = 0 ORDER BY 1^
SELECT ${R}TRIGGER_NAME FROM ${R}TRIGGERS WHERE ${R}RELATION_NAME = 'T7'^"
both "1 the qualified DROPs" \
"DROP INDEX PUBLIC.IX7^
DROP TRIGGER PUBLIC.TR7^
DROP TABLE PUBLIC.T8^
SELECT COUNT(*) AS N FROM ${R}RELATIONS WHERE ${R}RELATION_NAME = 'T8'^"

echo "--- 2 a VIEW over qualified names: the unqualified BLR, the source as written"
both "2 CREATE VIEW over PUBLIC.BASE, a 3-part column, a delimited qualifier" \
"CREATE VIEW PUBLIC.VQ AS SELECT X FROM PUBLIC.BASE^
CREATE VIEW VQ2 AS SELECT BASE.X FROM \"PUBLIC\".BASE WHERE PUBLIC.BASE.X > 1^
SELECT X FROM VQ ORDER BY X^
SELECT X FROM VQ2^"
for v in VQ VQ2; do
    same_blob "2 $v BLR" "SELECT ${R}VIEW_BLR FROM ${R}RELATIONS WHERE ${R}RELATION_NAME = '$v'" hex
    same_blob "2 $v source" "SELECT ${R}VIEW_SOURCE FROM ${R}RELATIONS WHERE ${R}RELATION_NAME = '$v'" utf8
done

echo "--- 3 a schema that does not exist: refused at prepare, no wrapper"
both "3 CREATE TABLE / SEQUENCE / PROCEDURE / VIEW in OTHER, and a delimited \"other\"" \
"CREATE TABLE OTHER.T9 (X INTEGER)^
CREATE TABLE \"other\".T9 (X INTEGER)^
CREATE SEQUENCE OTHER.S^
CREATE PROCEDURE OTHER.P AS BEGIN EXIT; END^
CREATE VIEW OTHER.V AS SELECT 1 X FROM ${R}DATABASE^"
both "3 ...before the savepoint law" \
"SET AUTODDL OFF^
SAVEPOINT S^
CREATE TABLE OTHER.T9 (X INTEGER)^
ROLLBACK^"

echo "--- 4 CONTROLS - unqualified DDL is as it was"
both "4 an unqualified table, view and procedure" \
"CREATE TABLE PLAIN (X INTEGER)^
CREATE VIEW VPLAIN AS SELECT X FROM BASE^
CREATE PROCEDURE PPLAIN AS BEGIN EXIT; END^
SELECT COUNT(*) AS N FROM VPLAIN^"

echo "--- panic check"
ran=$((ran + 1))
if grep -aq 'panicked at' "/tmp/fc-serve-ddlq-$PORT.log"; then echo "FAIL the server PANICKED"; fail=1
elif ! kill -0 $srv 2>/dev/null; then echo "FAIL the server is gone"; fail=1
else echo "OK   no panic and the server is still up"; fi
echo "ran $ran checks"
# the floor is the MEASURED count: 12 on the 2026-10-03 binary, 12 OK
if [ "$ran" -lt 12 ]; then echo "FAIL only $ran checks ran (floor 12) - cells went missing"; fail=1; fi
exit $fail
