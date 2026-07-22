#!/bin/bash
# The server answers SYSTEM-TABLE projections. System relations' record
# formats are not in RDB$FORMATS (the engine formats them at creation
# from compiled-in tables), so fire-crab COMPUTES them the way ini.epp
# does: the database's own RDB$RELATION_FIELDS/RDB$FIELDS rows give each
# relation's fields and types, and the offset walk (FLAG_BYTES start,
# MET_align per field) lays them out - the file describes itself, with
# only the two catalog-reading relations compiled in. The computation is
# anchored: it must reproduce the offsets catalog.rs found empirically
# by differential testing (4/256/1394/1410, 32/42), and everything
# here must match isql on real system tables - projections, WHERE,
# ORDER BY, aggregates, GROUP BY, and a system-to-system JOIN.
#
#   qa/serve-real-syscat.sh <clean-db-path> [port]
#
# Works on any clean database; expects a user table EMP for the
# catalog-of-a-user-table checks (the join scratch db has one).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-syscat.sh <clean-db-path> [port]}"
PORT="${2:-4059}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-syscat.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

node_once() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0]);db.detach();process.exit(0);}
          if(!r||r.length===0)console.log("<no rows>");
          else for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

isql_q() {
    printf 'SET HEADING OFF;\n%s\n' "$1" | run_isql | strip | grep -v '^$'
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     want: $3"
        echo "     got:  $2"
        fail=1
    fi
}

# the whole catalog, projected and ordered - every relation in the db
check "every relation, id and name" \
    "$(node_run "SELECT RDB\$RELATION_ID, RDB\$RELATION_NAME FROM RDB\$RELATIONS ORDER BY RDB\$RELATION_ID")" \
    "$(isql_q "SELECT RDB\$RELATION_ID || '|' || TRIM(RDB\$RELATION_NAME) FROM RDB\$RELATIONS ORDER BY RDB\$RELATION_ID;")"

# WHERE on an integer and on a text system column
check "WHERE on a system SHORT column" \
    "$(node_run "SELECT RDB\$RELATION_NAME FROM RDB\$RELATIONS WHERE RDB\$RELATION_ID = 6")" \
    "$(isql_q "SELECT TRIM(RDB\$RELATION_NAME) FROM RDB\$RELATIONS WHERE RDB\$RELATION_ID = 6;")"
check "WHERE on a system CHAR column" \
    "$(node_run "SELECT RDB\$RELATION_ID FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'EMP'")" \
    "$(isql_q "SELECT RDB\$RELATION_ID FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'EMP';" | tr -d ' ')"

# a user table's own catalog rows: name, declared position, physical id
check "a user table's columns from the catalog" \
    "$(node_run "SELECT RDB\$FIELD_NAME, RDB\$FIELD_POSITION, RDB\$FIELD_ID FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'EMP' ORDER BY RDB\$FIELD_POSITION")" \
    "$(isql_q "SELECT TRIM(RDB\$FIELD_NAME) || '|' || RDB\$FIELD_POSITION || '|' || RDB\$FIELD_ID FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'EMP' ORDER BY RDB\$FIELD_POSITION;")"

# RDB$FIELDS - the table the format computation itself reads
check "field type/length from RDB\$FIELDS" \
    "$(node_run "SELECT RDB\$FIELD_TYPE, RDB\$FIELD_LENGTH FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'RDB\$FIELD_NAME'")" \
    "$(isql_q "SELECT RDB\$FIELD_TYPE || '|' || RDB\$FIELD_LENGTH FROM RDB\$FIELDS WHERE RDB\$FIELD_NAME = 'RDB\$FIELD_NAME';")"

# RDB$TYPES - the type-name lookup table
check "type names for RDB\$FIELD_TYPE" \
    "$(node_run "SELECT RDB\$TYPE, RDB\$TYPE_NAME FROM RDB\$TYPES WHERE RDB\$FIELD_NAME = 'RDB\$FIELD_TYPE' ORDER BY RDB\$TYPE")" \
    "$(isql_q "SELECT RDB\$TYPE || '|' || TRIM(RDB\$TYPE_NAME) FROM RDB\$TYPES WHERE RDB\$FIELD_NAME = 'RDB\$FIELD_TYPE' ORDER BY RDB\$TYPE;")"

# aggregates and grouping over system rows
check "MAX over a system column" \
    "$(node_run "SELECT MAX(RDB\$RELATION_ID) FROM RDB\$RELATIONS")" \
    "$(isql_q "SELECT MAX(RDB\$RELATION_ID) FROM RDB\$RELATIONS;" | tr -d ' ')"
check "GROUP BY over the catalog" \
    "$(node_run "SELECT RDB\$SYSTEM_FLAG, COUNT(*) FROM RDB\$RELATIONS GROUP BY RDB\$SYSTEM_FLAG ORDER BY 1")" \
    "$(isql_q "SELECT RDB\$SYSTEM_FLAG || '|' || COUNT(*) FROM RDB\$RELATIONS GROUP BY RDB\$SYSTEM_FLAG ORDER BY 1;")"

# a JOIN between two system relations (title-distinct columns)
check "system-to-system JOIN" \
    "$(node_run "SELECT R.RDB\$RELATION_ID, RF.RDB\$FIELD_NAME FROM RDB\$RELATIONS R JOIN RDB\$RELATION_FIELDS RF ON R.RDB\$RELATION_NAME = RF.RDB\$RELATION_NAME WHERE R.RDB\$RELATION_ID = 2 ORDER BY RF.RDB\$FIELD_NAME")" \
    "$(isql_q "SELECT R.RDB\$RELATION_ID || '|' || TRIM(RF.RDB\$FIELD_NAME) FROM RDB\$RELATIONS R JOIN RDB\$RELATION_FIELDS RF ON R.RDB\$RELATION_NAME = RF.RDB\$RELATION_NAME WHERE R.RDB\$RELATION_ID = 2 ORDER BY RF.RDB\$FIELD_NAME;")"

# IS NULL three-valued logic on a system column
check "IS NULL on a system column" \
    "$(node_run "SELECT RDB\$FIELD_NAME FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'EMP' AND RDB\$NULL_FLAG IS NULL ORDER BY RDB\$FIELD_NAME")" \
    "$(isql_q "SELECT TRIM(RDB\$FIELD_NAME) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'EMP' AND RDB\$NULL_FLAG IS NULL ORDER BY RDB\$FIELD_NAME;")"

# COUNT keeps its header-count fast path and must agree with the walk
check "COUNT(*) fast path agrees" \
    "$(node_run "SELECT COUNT(*) FROM RDB\$RELATION_FIELDS")" \
    "$(isql_q "SELECT COUNT(*) FROM RDB\$RELATION_FIELDS;" | tr -d ' ')"

# writes to system relations must still be refused (a real SQL error -
# a dead-connection CONN_ERR would not prove the refusal)
case "$(node_run "DELETE FROM RDB\$RELATIONS WHERE RDB\$RELATION_ID = 128")" in
    ERR*) echo "OK   DML on a system relation is refused" ;;
    *) echo "DIFF DML on a system relation is refused"; fail=1 ;;
esac
exit $fail
