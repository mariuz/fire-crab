#!/bin/bash
# SCHEMA-QUALIFIED RELATION NAMES - `SCHEMA.TABLE` everywhere a relation
# is named, and the 3-part column reference `SCHEMA.TABLE.COLUMN` that
# goes with it. Twin databases, one driver, two servers; row sets AND
# error messages compared exactly (node-firebird flattens the engine's
# status vector to one comma-joined line, so an exact string compare IS
# a vector compare), plus the DESCRIBE compared item by item.
#
# The laws under test, each probed against the live engine first:
#
#   1. Every spelling of the qualifier names the same relation:
#      `PUBLIC.T`, `public.t`, `"PUBLIC".T`, `"PUBLIC"."T"` and
#      `PUBLIC . T` all answer. Unquoted halves FOLD, a quoted half does
#      NOT - `"public".T` is -204 while `public.t` answers.
#   2. THE PUBLIC RULE THAT WORKS FOR PROCEDURES IS WRONG FOR RELATIONS.
#      The qualifier is a TWO-WAY CHECK against the catalog, not a
#      strip: `SYSTEM.RDB$RELATIONS` answers, `PUBLIC.RDB$RELATIONS`
#      and `SYSTEM.T` both raise -204. (And it must be a real catalog
#      read, not the RDB$ name prefix: `CREATE TABLE "RDB$FOO"` lands
#      in PUBLIC, so a prefix rule would ANSWER `SYSTEM."RDB$FOO"`.)
#   3. An unknown SCHEMA and an unknown TABLE are the IDENTICAL vector -
#      -204 / dsql_relation_err / `"S"."T"` / line+column - and the
#      line/column points at the START OF THE QUALIFIER, not at the
#      relation token. There is no "schema unknown" diagnostic.
#   4. QUALIFICATION IS INVISIBLE IN THE DESCRIBE. `FROM T` and `FROM
#      PUBLIC.T` describe BYTE-IDENTICALLY: item 17 the BARE relation,
#      item 25 the alias (an empty string when there is none), item 33
#      the schema. A qualifier leaking into any of the ~7 sites that
#      stamp a relation is a silent describe corruption no row gate
#      catches - which is why section D prepares and compares them.
#   5. THE VIEW GUARD. A view is a relation with an id and NO records of
#      its own, so a wrongly qualified view that reached the scan would
#      answer ZERO ROWS rather than refuse - a wrong answer wearing an
#      empty result's clothes. `SYSTEM.V1` must RAISE.
#   6. A 3-part column ref is legal in the select list, WHERE, GROUP BY,
#      ORDER BY, HAVING and as a star, over a QUALIFIED *or* an
#      unqualified FROM - the reference matches the (schema, relation)
#      the context RESOLVED to. A 2-part ref is always TABLE.COLUMN and
#      never SCHEMA.COLUMN (`SELECT PUBLIC.C FROM PUBLIC.T` is -206).
#   7. AN ALIAS IS EXCLUSIVE: after `FROM PUBLIC.T AS X` all of `T.C`,
#      `PUBLIC.T.C` and `PUBLIC.X.C` are -206. (`SELECT T.C FROM T X`
#      is the same law and closes a PRE-EXISTING fire-crab wrong
#      answer - it used to answer where the engine raises.) An alias
#      may itself be named PUBLIC and then shadows the schema.
#   8. A CTE can be neither defined nor referenced qualified, and a
#      qualified reference SHADOWS a same-named CTE: `WITH T AS (...)
#      SELECT * FROM PUBLIC.T` answers the BASE TABLE.
#   9. A view BODY may be stored qualified (`RDB$VIEW_SOURCE` keeps the
#      text verbatim), and qualified names work in joins, comma lists,
#      IN-subqueries, derived tables and CTE bodies.
#  10. Every DML shape takes a qualified target and 3-part refs in its
#      SET / WHERE / RETURNING.
#  11. A NESTED QUERY EXPRESSION IS NOT AN EXEMPTION (sections H-J). The
#      FROM of an IN / NOT IN / EXISTS / NOT EXISTS / scalar subquery
#      gets laws 1, 2 and 5 whole - including inside an UPDATE, a DELETE
#      and an INSERT ... SELECT, where ignoring the qualifier did not
#      merely answer wrongly, it WROTE. And law 7 reaches into the
#      subquery: after `FROM T AS Q` the base name T is not a binding in
#      the correlated comparison either.
#
# Recorded boundaries this gate encodes rather than hides:
#   * fire-crab emits the -204 vector for a SELECT's FROM item only.
#     A -206 (column/alias) refusal, a qualified DML target and a
#     qualified CTE reference all keep the generic Dynamic SQL Error,
#     so those checks assert only that BOTH sides raise ("refuse").
#   * fire-crab holds one user schema, so the cross-schema ambiguity
#     vector (336003085) and SET SEARCH_PATH are unreachable here.
#   * the NESTED contexts keep the generic Dynamic SQL Error rather than
#     the engine's -204 with its argument and line/column: the subquery
#     text is lifted out of the statement before it is resolved, so the
#     span a positional vector needs is gone. Sections H-J therefore
#     assert "refuse", which is the part that matters - answering rows,
#     answering [], or writing is what a wrong qualifier used to do.
#   * a nested query expression does not EXPAND a view (section K). It
#     refuses one instead of scanning its recordless storage, which is
#     what made `IN (SELECT C FROM V2)` answer [] where the engine
#     answers every row.
#
#   qa/serve-real-qualname.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4613}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-qualname-crab.fdb"
B="$D/fc-qualname-engine.fdb"

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

# The fixture, created by isql so the catalog is the REAL engine's.
# V1's body is stored QUALIFIED - RDB$VIEW_SOURCE keeps the text
# verbatim, so V1 only became plannable once a view body could carry a
# schema; V2 is the unqualified control and the join-side view.
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (C INTEGER, D VARCHAR(10));
CREATE TABLE U (C INTEGER, E VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1,'one');
INSERT INTO T VALUES (2,'two');
INSERT INTO U VALUES (1,'uno');
COMMIT;
CREATE VIEW V1 AS SELECT C, D FROM PUBLIC.T;
CREATE VIEW V2 AS SELECT C FROM T;
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-qualname.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

# The WHOLE error message, not its first line: node-firebird flattens
# the engine's status vector into one comma-joined string, so comparing
# it compares the gdscodes, the -204 argument and the line/column.
query() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,[],(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").replace(/\n/g," "));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

# PREPARE ONLY - the describe is the whole question in section D, and
# executing an INSERT there would write on both sides.
describe() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          // splice OWNER (18) into the describe request, as the
          // describe gate does - the parser handles it already
          const M=require("node-firebird/lib/wire/const");
          const C=M.default||M;
          for (const a of [C.DESCRIBE, C.DESCRIBE_WITH_SCHEMA]) {
            const i=a.indexOf(C.isc_info_sql_alias);
            if(i>=0&&!a.includes(C.isc_info_sql_owner)) a.splice(i,0,C.isc_info_sql_owner); }
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.newStatement(process.env.FC_Q,(e2,st)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,60));db.detach();process.exit(0);}
              console.log(JSON.stringify((st.output||[]).map(v=>
                [v.field??"",v.alias??"",v.relation??"",v.relationAlias??"",v.owner??"",v.relationSchema??""])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql> - rows AND the full error message must match
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

# Both sides must RAISE, and fire-crab must never answer. The message
# is NOT compared: these are the vectors fire-crab does not reproduce
# (-206 column/alias, the DML target's -204, the CTE -104/-204) - a
# recorded boundary, and a refusal is an acceptable one.
refuse() { # <label> <sql>
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    ran=$((ran + 1))
    if [ "${a#ERR}" != "$a" ] && [ "${b#ERR}" != "$b" ]; then
        echo "OK   $1 (both refuse)"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

# fire-crab REFUSES where the engine ANSWERS - a recorded boundary,
# asserted in BOTH directions so it cannot silently rot into a wrong
# answer again. (It is not a `refuse`: the engine does not refuse.)
boundary() { # <label> <sql>
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    ran=$((ran + 1))
    if [ "${a#ERR}" != "$a" ] && [ "${b#ERR}" = "$b" ]; then
        echo "OK   $1 (fcwire refuses, engine answers)"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

desc() { # <label> <sql> - every describe item, compared exactly
    a=$(describe "$2" "$PORT" "$A")
    b=$(describe "$2" "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

# --- A. every spelling of the qualifier --------------------------------
both "PUBLIC.T" "SELECT * FROM PUBLIC.T"
both "public.t (both halves fold)" "SELECT * FROM public.t"
both "\"PUBLIC\".T" "SELECT * FROM \"PUBLIC\".T"
both "\"PUBLIC\".\"T\"" "SELECT * FROM \"PUBLIC\".\"T\""
both "PUBLIC . T (the dot is its own token)" "SELECT * FROM PUBLIC . T"
both "a newline around the dot" "SELECT * FROM PUBLIC
.T"
both "COUNT(*) over a qualified FROM" "SELECT COUNT(*) FROM PUBLIC.T"
both "a qualified FROM with an alias" "SELECT * FROM PUBLIC.T AS X WHERE X.C = 1"
both "an alias NAMED PUBLIC shadows the schema" \
     "SELECT COUNT(*) FROM PUBLIC.T AS PUBLIC WHERE PUBLIC.C = 1"

# --- B. 3-part column references ---------------------------------------
both "PUBLIC.T.C over a qualified FROM" "SELECT PUBLIC.T.C FROM PUBLIC.T"
both "T.C over a qualified FROM" "SELECT T.C FROM PUBLIC.T"
both "PUBLIC.T.C over an UNQUALIFIED FROM" "SELECT PUBLIC.T.C FROM T"
both "all-lowercase 3-part ref" "SELECT public.t.c FROM t"
both "PUBLIC.T.* is a legal star" "SELECT PUBLIC.T.* FROM PUBLIC.T"
both "T.* over a qualified FROM" "SELECT T.* FROM PUBLIC.T"
both "select list, WHERE, GROUP BY and ORDER BY at once" \
     "SELECT PUBLIC.T.C FROM PUBLIC.T WHERE PUBLIC.T.C = 1 GROUP BY PUBLIC.T.C ORDER BY PUBLIC.T.C"
both "ORDER BY a 3-part ref not in the select list" \
     "SELECT C FROM PUBLIC.T ORDER BY PUBLIC.T.C DESC"
both "3-part refs inside aggregates and HAVING" \
     "SELECT SUM(PUBLIC.T.C) FROM PUBLIC.T HAVING SUM(PUBLIC.T.C) > 0"

# --- C. the SYSTEM schema is not the PUBLIC one ------------------------
both "SYSTEM.RDB\$RELATIONS answers" "SELECT COUNT(*) FROM SYSTEM.RDB\$RELATIONS"
both "the unqualified system table answers" "SELECT COUNT(*) FROM RDB\$RELATIONS"
both "a projection off a SYSTEM-qualified table" \
     "SELECT RDB\$RELATION_ID FROM SYSTEM.RDB\$RELATIONS WHERE RDB\$RELATION_ID = 6"

# --- D. joins, comma lists, subqueries, derived tables, CTEs, views ----
both "a JOIN with 3-part refs on both sides" \
     "SELECT PUBLIC.T.C, PUBLIC.U.E FROM PUBLIC.T JOIN PUBLIC.U ON PUBLIC.T.C = PUBLIC.U.C"
both "3-part refs in an ON over an UNQUALIFIED FROM" \
     "SELECT T.C, U.E FROM T JOIN U ON PUBLIC.T.C = PUBLIC.U.C"
both "a qualified comma list" "SELECT * FROM PUBLIC.T, PUBLIC.U"
both "a qualified IN-subquery" "SELECT * FROM PUBLIC.T WHERE C IN (SELECT C FROM PUBLIC.U)"
both "a qualified derived table" "SELECT * FROM (SELECT PUBLIC.T.C FROM PUBLIC.T) DT"
both "a qualified CTE BODY" "WITH C1 AS (SELECT C FROM PUBLIC.T) SELECT * FROM C1"
both "a view whose BODY is stored qualified" "SELECT * FROM PUBLIC.V1"
both "a 3-part ref over a qualified view" "SELECT PUBLIC.V1.C FROM PUBLIC.V1"
both "a qualified VIEW as a join side" \
     "SELECT * FROM PUBLIC.T JOIN PUBLIC.V2 ON PUBLIC.T.C = PUBLIC.V2.C"
both "a qualified reference SHADOWS a same-named CTE" \
     "WITH T AS (SELECT 99 AS C, 'cte' AS D FROM RDB\$DATABASE) SELECT * FROM PUBLIC.T"
both "the unqualified control takes the CTE" \
     "WITH T AS (SELECT 99 AS C, 'cte' AS D FROM RDB\$DATABASE) SELECT * FROM T"

# --- E. the -204 vector, compared BYTE FOR BYTE ------------------------
# unknown schema and unknown table are the SAME vector, and the
# line/column points at the START of the qualifier
both "an unknown schema" "SELECT * FROM NOSUCH.T"
both "a real table under the wrong schema" "SELECT * FROM SYSTEM.T"
both "a system table under PUBLIC (column 22, the P of PUBLIC)" \
     "SELECT COUNT(*) FROM PUBLIC.RDB\$RELATIONS"
both "an unknown table under a real schema" "SELECT * FROM PUBLIC.NOSUCHTAB"
both "a quoted lower-case schema does NOT match PUBLIC" "SELECT * FROM \"public\".T"
both "THE VIEW GUARD: a wrongly qualified view RAISES, never zero rows" \
     "SELECT * FROM SYSTEM.V1"
both "an unknown schema on a JOIN SIDE" \
     "SELECT * FROM PUBLIC.T JOIN SYSTEM.U ON PUBLIC.T.C = U.C"

# --- F. refusals whose vector fire-crab does not reproduce -------------
refuse "a 2-part ref is TABLE.COLUMN, never SCHEMA.COLUMN" \
       "SELECT PUBLIC.C FROM PUBLIC.T"
refuse "an alias kills the 3-part binding" "SELECT PUBLIC.T.C FROM PUBLIC.T AS X"
refuse "an alias kills the bare binding" "SELECT T.C FROM PUBLIC.T AS X"
refuse "the alias is not reachable 3-part either" "SELECT PUBLIC.X.C FROM PUBLIC.T AS X"
refuse "T.C after FROM T X (a PRE-EXISTING wrong answer, now refused)" \
       "SELECT T.C FROM T X"
refuse "a CTE cannot be REFERENCED qualified" \
       "WITH C1 AS (SELECT C FROM T) SELECT * FROM PUBLIC.C1"
refuse "a CTE cannot be DEFINED qualified" \
       "WITH PUBLIC.C1 AS (SELECT C FROM T) SELECT * FROM C1"
refuse "four parts are not a name" "SELECT * FROM A.B.C.D"
refuse "INSERT into a wrongly qualified target" "INSERT INTO SYSTEM.T (C,D) VALUES (5,'x')"
refuse "UPDATE of a wrongly qualified target" "UPDATE SYSTEM.T SET D='x' WHERE C=1"
refuse "DELETE from an unknown schema" "DELETE FROM NOSUCH.T WHERE C=1"

# --- G. THE DESCRIBE IS BLIND TO THE QUALIFIER -------------------------
# The only guard against a leaked qualifier: item 17 must stay the BARE
# relation, item 25 the alias-or-empty-string, item 33 the schema. No
# row-comparison check above would notice if one of the ~7 stamping
# sites took the FROM text instead.
desc "the unqualified baseline" "SELECT * FROM T"
desc "a qualified FROM describes IDENTICALLY" "SELECT * FROM PUBLIC.T"
desc "a quoted-qualified FROM" "SELECT * FROM \"PUBLIC\".\"T\""
desc "a qualified FROM with an alias" "SELECT C FROM PUBLIC.T AS Q"
desc "a 3-part column ref" "SELECT PUBLIC.T.C FROM PUBLIC.T"
desc "a 3-part ref aliased" "SELECT PUBLIC.T.C AS QQ FROM PUBLIC.T"
desc "a 3-part ref over an unqualified FROM" "SELECT PUBLIC.T.C FROM T"
desc "a SYSTEM-qualified system table" "SELECT RDB\$RELATION_ID FROM SYSTEM.RDB\$RELATIONS"
desc "a qualified view" "SELECT * FROM PUBLIC.V1"
desc "a qualified JOIN" \
     "SELECT PUBLIC.T.C, PUBLIC.U.E FROM PUBLIC.T JOIN PUBLIC.U ON PUBLIC.T.C = PUBLIC.U.C"
desc "a qualified INSERT ... RETURNING keeps the BARE relation" \
     "INSERT INTO PUBLIC.T (C,D) VALUES (900,'x') RETURNING PUBLIC.T.C"

# --- H. THE NESTED QUERY EXPRESSION GETS THE SAME CHECK ----------------
# A subquery's FROM is a FROM. It used to IGNORE the qualifier entirely -
# no catalog read, no view guard - so `IN (SELECT C FROM SYSTEM.U)`
# answered rows the engine refuses, and the DML shapes of it WROTE.
refuse "IN over a wrongly qualified inner FROM" \
       "SELECT * FROM T WHERE C IN (SELECT C FROM SYSTEM.U)"
refuse "IN over an unknown schema" \
       "SELECT * FROM T WHERE C IN (SELECT C FROM NOSUCH.U)"
refuse "NOT IN over a wrongly qualified inner FROM" \
       "SELECT * FROM T WHERE C NOT IN (SELECT C FROM SYSTEM.U)"
refuse "NOT IN over an unknown schema" \
       "SELECT * FROM T WHERE C NOT IN (SELECT C FROM NOSUCH.U)"
refuse "EXISTS over a wrongly qualified inner FROM" \
       "SELECT * FROM T WHERE EXISTS (SELECT 1 FROM SYSTEM.U)"
refuse "NOT EXISTS over a wrongly qualified inner FROM" \
       "SELECT * FROM T WHERE NOT EXISTS (SELECT 1 FROM SYSTEM.U)"
refuse "a CORRELATED EXISTS over a wrongly qualified inner FROM" \
       "SELECT * FROM T WHERE EXISTS (SELECT 1 FROM SYSTEM.U WHERE U.C = T.C)"
refuse "a scalar subquery over a wrongly qualified inner FROM" \
       "SELECT (SELECT MAX(C) FROM SYSTEM.U) FROM T"
refuse "a CORRELATED scalar subquery over a wrongly qualified inner FROM" \
       "SELECT (SELECT COUNT(*) FROM SYSTEM.U WHERE U.C = T.C) FROM T"
refuse "a quoted lower-case schema does NOT fold inside a subquery" \
       "SELECT * FROM T WHERE C IN (SELECT C FROM \"public\".U)"
# THE VIEW GUARD, inside a subquery: a view has an id and no records, so
# a wrong qualifier that reached the scan answered [] - an empty result
# wearing a wrong answer's clothes
refuse "THE VIEW GUARD in an IN-subquery (was [], not a refusal)" \
       "SELECT * FROM T WHERE C IN (SELECT C FROM SYSTEM.V2)"
refuse "THE VIEW GUARD in an EXISTS-subquery" \
       "SELECT * FROM T WHERE EXISTS (SELECT 1 FROM SYSTEM.V1)"
# the RIGHT qualifier still answers - the check is two-way, not a strip
both "NOT IN over a correctly qualified inner FROM" \
     "SELECT * FROM T WHERE C NOT IN (SELECT C FROM PUBLIC.U) ORDER BY C"
both "a scalar subquery over a correctly qualified inner FROM" \
     "SELECT (SELECT MAX(C) FROM PUBLIC.U) AS M FROM T"
both "a correlated subquery over a correctly qualified inner FROM" \
     "SELECT C, (SELECT COUNT(*) FROM PUBLIC.U WHERE U.C = T.C) AS N FROM T ORDER BY C"
# law 6 INSIDE a subquery: the inner relation is reachable 3-part too
both "a 3-part ref to the INNER table, inside the subquery" \
     "SELECT C FROM T WHERE EXISTS (SELECT 1 FROM PUBLIC.U WHERE PUBLIC.U.C = 1) ORDER BY C"
both "a 3-part ref to the INNER table of a scalar subquery" \
     "SELECT (SELECT COUNT(*) FROM PUBLIC.U WHERE PUBLIC.U.C = 1) AS N FROM T"

# --- I. AN ALIAS IS EXCLUSIVE INSIDE A SUBQUERY TOO --------------------
# Law 7 again, in the one place it leaked: the CORRELATED COMPARISON.
# After `FROM T AS Q` the base name T is not a binding ANYWHERE in the
# statement, so an outer reference spelled T.C is a -206 and not a
# correlation - fire-crab used to read every unrecognised qualifier as
# "the outer one" and answer.
refuse "the base name in a correlated EXISTS after AS Q" \
       "SELECT C FROM T AS Q WHERE EXISTS (SELECT 1 FROM U WHERE U.C = T.C)"
refuse "the 3-part base name in a correlated EXISTS after AS Q" \
       "SELECT C FROM T AS Q WHERE EXISTS (SELECT 1 FROM U WHERE U.C = PUBLIC.T.C)"
refuse "the alias is not reachable 3-part inside a subquery either" \
       "SELECT C FROM T AS Q WHERE EXISTS (SELECT 1 FROM U WHERE U.C = PUBLIC.Q.C)"
refuse "the select-list scalar form of the same leak" \
       "SELECT (SELECT COUNT(*) FROM U WHERE U.C = T.C) FROM T AS Q"
refuse "the select-list scalar form, spelled 3-part" \
       "SELECT (SELECT COUNT(*) FROM U WHERE U.C = PUBLIC.T.C) FROM PUBLIC.T AS Q"
# the shapes that ALREADY refused - kept so a future change cannot
# silently flip them back
refuse "control: the base name in a NON-correlation leaf" \
       "SELECT C FROM T AS Q WHERE EXISTS (SELECT 1 FROM U WHERE T.C = 1)"
refuse "control: the same leaf under a scalar comparison" \
       "SELECT C FROM T AS Q WHERE 1 = (SELECT COUNT(*) FROM U WHERE U.C = T.C)"
refuse "control: the base name in a HAVING" \
       "SELECT C FROM T AS Q GROUP BY 1 HAVING PUBLIC.T.C > 1"
refuse "control: the DELETE ... AS Q variant" \
       "DELETE FROM T AS Q WHERE C IN (SELECT C FROM U WHERE U.C = T.C)"
refuse "control: the UPDATE ... AS Q variant" \
       "UPDATE T AS Q SET D = 'x' WHERE C IN (SELECT C FROM U WHERE U.C = T.C)"
both "the AS Q controls wrote nothing (fresh attachment)" \
     "SELECT * FROM T ORDER BY C"
# the spellings that DO resolve must keep resolving
both "the alias itself is the correlation's outer key" \
     "SELECT C FROM T AS Q WHERE EXISTS (SELECT 1 FROM U WHERE U.C = Q.C) ORDER BY C"
both "an UNALIASED outer FROM answers to its base name" \
     "SELECT C FROM T WHERE EXISTS (SELECT 1 FROM U WHERE U.C = T.C) ORDER BY C"
both "an UNALIASED outer FROM answers 3-part" \
     "SELECT C FROM T WHERE EXISTS (SELECT 1 FROM U WHERE U.C = PUBLIC.T.C) ORDER BY C"

# --- J. A SUBQUERY INSIDE DML MUST NOT WRITE ---------------------------
# The project law: re-read the file through the engine after every write
# phase. Each of these used to DELETE or UPDATE the row the engine
# refuses to touch.
refuse "DELETE whose IN-subquery is wrongly qualified" \
       "DELETE FROM T WHERE C IN (SELECT C FROM SYSTEM.U)"
both "T is untouched (fresh attachment)" "SELECT * FROM T ORDER BY C"
refuse "UPDATE whose IN-subquery is wrongly qualified" \
       "UPDATE T SET D = 'x' WHERE C IN (SELECT C FROM SYSTEM.U)"
both "T is untouched (fresh attachment)" "SELECT * FROM T ORDER BY C"
refuse "DELETE whose EXISTS-subquery names an unknown schema" \
       "DELETE FROM T WHERE EXISTS (SELECT 1 FROM NOSUCH.U)"
both "T is untouched (fresh attachment)" "SELECT * FROM T ORDER BY C"
refuse "UPDATE whose CORRELATED EXISTS is wrongly qualified" \
       "UPDATE T SET D = 'x' WHERE EXISTS (SELECT 1 FROM SYSTEM.U WHERE U.C = T.C)"
both "T is untouched (fresh attachment)" "SELECT * FROM T ORDER BY C"
refuse "INSERT ... SELECT whose WHERE holds a wrongly qualified subquery" \
       "INSERT INTO U (C,E) SELECT C, D FROM T WHERE C IN (SELECT C FROM SYSTEM.U)"
both "U is untouched (fresh attachment)" "SELECT * FROM U ORDER BY C"

# --- K. the view-in-a-subquery boundary, locked ------------------------
# The nested path does not EXPAND a view, and a view has no records of
# its own: scanning its storage answered ZERO ROWS where the engine
# answers every row. Refusing is the honest reply, and these lock it so
# the lie cannot come back unnoticed.
boundary "a view inside an IN-subquery" \
         "SELECT * FROM T WHERE C IN (SELECT C FROM V2)"
boundary "a view inside an EXISTS-subquery" \
         "SELECT * FROM T WHERE EXISTS (SELECT 1 FROM V2)"
boundary "a view inside a scalar subquery" \
         "SELECT (SELECT MAX(C) FROM V2) AS M FROM T"
boundary "a CORRECTLY qualified view inside a subquery" \
         "SELECT * FROM T WHERE C IN (SELECT C FROM PUBLIC.V2)"

# --- L. DML (LAST: it mutates) -----------------------------------------
both "INSERT into a qualified target" "INSERT INTO PUBLIC.T (C,D) VALUES (9,'nine')"
both "the row landed (fresh attachment)" "SELECT * FROM T ORDER BY C"
both "UPDATE with a 3-part SET and a 3-part WHERE" \
     "UPDATE PUBLIC.T SET PUBLIC.T.D = 'IX' WHERE PUBLIC.T.C = 9"
both "the update took (fresh attachment)" "SELECT * FROM T ORDER BY C"
both "INSERT ... RETURNING a 3-part ref" \
     "INSERT INTO PUBLIC.T (C,D) VALUES (7,'sev') RETURNING PUBLIC.T.C, D"
both "UPDATE OR INSERT into a qualified target" \
     "UPDATE OR INSERT INTO PUBLIC.T (C,D) VALUES (8,'eig') MATCHING (C) RETURNING C,D"
both "DELETE with a 3-part WHERE" "DELETE FROM PUBLIC.T WHERE PUBLIC.T.C = 9"
both "DELETE the rest" "DELETE FROM PUBLIC.T WHERE PUBLIC.T.C > 2"
both "the table is back to its two rows (fresh attachment)" \
     "SELECT * FROM T ORDER BY C"

# --- M. the ran counter -------------------------------------------------
if [ "$ran" -ne 115 ]; then
    echo "DIFF $ran checks ran (expected exactly 115) - did one silently skip?"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$A" "$B"
exit $fail
