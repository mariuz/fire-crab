#!/bin/bash
# CAST(? AS <type>) in the SELECT LIST over a DERIVED TABLE - a `?`
# projection param resolving against a `FROM (SELECT ...) X` source. The
# projection `?` cast landed for a plain single-table SELECT
# (qa/serve-real-castparam.sh) and a join (qa/serve-real-castparamjoin.sh);
# this extends it to the derived/subselect-in-FROM path (plan_over_source),
# which the CTE and view row-sources share.
#
# Driven by node-firebird, not a raw C rig: a derived cursor is fetched
# through the driver here exactly as the application layer does (the raw
# isc_dsql_execute + isc_dsql_fetch flow does not open a cursor over this
# server's Plan::Derived - a separate, pre-existing boundary unrelated to
# parameters; the driver and isql both fetch it correctly). Each case runs
# the SAME statement and argument list against fire-crab and the live
# engine and compares the rows.
#
#   * the projection `?` converts the bound value by its cast grammar;
#   * a projection `?` and a WHERE `?` coexist in one textual order
#     (projection first) - the derived path now offsets its WHERE
#     numbering past the projection params;
#   * SMALLINT/INTEGER/BIGINT targets, ORDER BY, and two projection
#     params (one nested in arithmetic) all hold.
#
# A `?` IN THE INNER SELECT LIST is covered here too now. It used to
# refuse at plan time: nothing bound it at execute, because
# bind_plan_params reached the TOP-LEVEL plan's columns only, so the
# inner Project's own columns would have evaluated unbound - a wrong
# answer where a refusal was honest. Both it and plan_has_proj_param now
# walk into a derived body, a modifier and a union branch.
#
# SCOPE: the UNGROUPED derived projection. A GROUPED derived projection
# param needs projected constants in a grouped query first (the group
# builder refuses any non-key expression) - the same prerequisite the
# plain GROUP BY path is missing - and is a separate slice.
#
#   qa/serve-real-castparamderived.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4749}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node-firebird")' >/dev/null 2>&1; then
    echo "SKIP: node-firebird not available"; exit 0
fi
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 10);
INSERT INTO T VALUES (2, 20);
INSERT INTO T VALUES (3, 30);
COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null
}
A="$D/fc-castparamderived-a.fdb"; B="$D/fc-castparamderived-b.fdb"
make_db "$A"; make_db "localhost:$B"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-castparamderived-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

# run one statement+args through node-firebird, print the rows as JSON
query() { # <sql> <json args> <host> <port> <db>
    timeout 25 env FC_Q="$1" FC_A="$2" FC_HOST="$3" FC_PORT="$4" FC_DB="$5" node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(0);});
      const F=require("node-firebird");
      const args=JSON.parse(process.env.FC_A);
      F.attach({host:process.env.FC_HOST,port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,args,(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,40));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null
}
both() { # <label> <sql> <json args>
    local a b
    a=$(query "$2" "$3" 127.0.0.1 "$PORT" "$A")
    b=$(query "$2" "$3" 127.0.0.1 "$REAL" "$B")
    ran=$((ran + 1))
    if [ "$a" = "$b" ]; then echo "OK   $1: $a"
    else echo "DIFF $1"; echo "     fcwire: $a"; echo "     engine: $b"; fail=1; fi
}

DV="SELECT CAST(? AS INTEGER) AS C, X.V FROM (SELECT V FROM T) X"
both "derived proj rounds"          "$DV"                          "[2.5]"
both "derived proj exponent + order" "$DV ORDER BY X.V"            "[100]"
both "derived proj + WHERE, order"  "$DV WHERE X.V = ?"            "[7.9, 20]"
both "derived smallint"             "SELECT CAST(? AS SMALLINT) AS C, X.V FROM (SELECT V FROM T) X" "[42]"
both "derived bigint"               "SELECT CAST(? AS BIGINT) AS C, X.V FROM (SELECT V FROM T) X"   "[9999999999]"
both "derived two proj params"      "SELECT CAST(? AS INTEGER) AS C, X.V + CAST(? AS INTEGER) AS D FROM (SELECT V FROM T) X" "[5, 3]"
both "derived width overflow"       "SELECT CAST(? AS SMALLINT) AS C, X.V FROM (SELECT V FROM T) X" "[99999]"
# a param-free derived constant still matches (the path is unchanged for it)
both "derived constant"             "SELECT 7 AS C, X.V FROM (SELECT V FROM T) X" "[]"

# --- a `?` in the INNER select list ------------------------------------
# Every predicate is paired with a twin that must answer NOTHING, so a
# projection that was never bound cannot pass by riding an existing row.
both "an inner projection ?"          "SELECT C FROM (SELECT CAST(? AS INTEGER) AS C FROM T) X" "[5]"
both "...a different bound value"     "SELECT C FROM (SELECT CAST(? AS INTEGER) AS C FROM T) X" "[7]"
both "an inner proj ? beside a column" "SELECT C, V FROM (SELECT CAST(? AS INTEGER) AS C, V FROM T WHERE V > ?) X ORDER BY V" "[42,10]"
both "...the inner WHERE EXCLUDES"    "SELECT C, V FROM (SELECT CAST(? AS INTEGER) AS C, V FROM T WHERE V > ?) X ORDER BY V" "[42,99]"
# the ORDER: the outer projection's `?` is textually first, so these two
# values would SWAP if the inner body's slot were numbered before it
both "an outer proj ? and an inner one" "SELECT CAST(? AS INTEGER) AS O, C FROM (SELECT CAST(? AS INTEGER) AS C FROM T WHERE ID = 1) X" "[7,9]"
both "a CTE body's projection ?"      "WITH C AS (SELECT CAST(? AS INTEGER) AS V FROM T WHERE ID = 1) SELECT V FROM C" "[5]"
both "a NESTED derived body's proj ?" "SELECT V FROM (SELECT C AS V FROM (SELECT CAST(? AS INTEGER) AS C FROM T WHERE ID = 1) Y) X" "[5]"
# the control: a literal inner projection worked before, which is what
# says these cells measure the BOUND half
both "CONTROL a literal inner projection" "SELECT C FROM (SELECT CAST(5 AS INTEGER) AS C FROM T) X" "[]"

# A FOLD's BASE and a JOIN's DERIVED SIDE keep their rows in a
# `RowSource::PlanRows`, which is not one of the plan FIELDS
# bind_plan_params walks - so an inner projection `?` under either of
# them reached the FETCH unbound (prepare succeeded, op_execute was
# accepted, `fetch plan = JoinGroup` was the last line). The row-source
# walk binds that plan's projection before materialising it now.
#
# The teeth: a side whose WHERE excludes every row must answer NOTHING,
# and a fold over an EMPTY inner never evaluates the projection at all -
# so the pair together tells a bound projection from an unbound one.
refuses_q() { # <label> <sql> <json args>
    local a b
    a=$(query "$2" "$3" 127.0.0.1 "$PORT" "$A")
    ran=$((ran + 1))
    if [ "$a" = "CONN_ERR" ] || [ -z "$a" ]; then
        echo "DIFF $1 [VACUOUS: fcwire did not answer at all]"; fail=1; return
    fi
    case "$a" in
        ERR*) echo "OK   refusal kept (engine answers): $1" ;;
        *) b=$(query "$2" "$3" 127.0.0.1 "$REAL" "$B")
           if [ "$a" = "$b" ]; then echo "OK   $1 now agrees: $a (update the refusal list)"
           else echo "DIFF $1: fcwire [$a] engine [$b]"; fail=1; fi ;;
    esac
}
both "a FOLD over an inner projection ?" "SELECT SUM(C) AS S FROM (SELECT CAST(? AS INTEGER) AS C FROM T) X" "[10]"
both "...COUNT over one"              "SELECT COUNT(C) AS N FROM (SELECT CAST(? AS INTEGER) AS C FROM T) X" "[10]"
both "...MAX over one"                "SELECT MAX(C) AS M FROM (SELECT CAST(? AS INTEGER) AS C FROM T) X" "[10]"
both "...a GROUP BY over one"         "SELECT C, COUNT(*) AS N FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM T) X GROUP BY C" "[10]"
both "a JOIN SIDE with an inner projection ?" "SELECT X.C FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM T WHERE ID = 1) X JOIN T D ON D.ID = X.ID" "[5]"
both "...the derived side on the RIGHT" "SELECT X.C FROM T D JOIN (SELECT CAST(? AS INTEGER) AS C, ID FROM T WHERE ID = 1) X ON D.ID = X.ID" "[5]"
both "...the side under FIRST"        "SELECT FIRST 1 X.C FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM T WHERE ID = 1) X JOIN T D ON D.ID = X.ID" "[5]"
both "...a fold ABOVE the joined side" "SELECT SUM(X.C) AS S FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM T WHERE ID < 3) X JOIN T D ON D.ID = X.ID" "[5]"
both "...the side EXCLUDES every row" "SELECT X.C FROM (SELECT CAST(? AS INTEGER) AS C, ID FROM T WHERE ID > ?) X JOIN T D ON D.ID = X.ID" "[5,99]"
both "CONTROL a fold over a LITERAL inner projection" "SELECT SUM(C) AS S FROM (SELECT CAST(5 AS INTEGER) AS C FROM T) X" "[]"

echo "ran $ran checks"
exit $fail
