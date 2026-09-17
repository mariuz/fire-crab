#!/bin/bash
# UNION / UNION ALL.
#
# The engine compiles a set operation into an RSE union node whose
# branches feed one stream. fire-crab materialises instead: each branch
# is planned on its own, its rows are collected, the lists are
# concatenated, and a plain UNION then removes duplicates - UNION ALL
# keeps them, which is the whole difference between the two.
#
# The FIRST branch names and types the result, exactly as the engine
# does, and every branch must project the same NUMBER of columns.
#
# THE DIFFERENTIAL: the same isql runs the same query against the engine
# and against fire-crab, and the row sets must match - ORDER, duplicates
# and all, since a union's output order is observable once ORDER BY pins
# it and the un-ordered cases must still agree.
#
# The teeth are the pairs that differ only in a way a wrong
# implementation would collapse:
#
#   UNION vs UNION ALL       must give DIFFERENT row counts on data with
#                            duplicates across branches
#   NULL de-duplication      two NULL rows are the SAME row to a set
#                            operation, unlike `= NULL` in a predicate
#   branch WHEREs            each branch filters independently
#
#   qa/serve-real-union.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4392}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-union.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, S VARCHAR(10));
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, N INTEGER, S VARCHAR(10));
COMMIT;
INSERT INTO A VALUES (1, 10, 'x');
INSERT INTO A VALUES (2, 20, 'y');
INSERT INTO A VALUES (3, 30, 'z');
INSERT INTO A VALUES (4, NULL, NULL);
INSERT INTO B VALUES (1, 10, 'x');
INSERT INTO B VALUES (2, 99, 'q');
INSERT INTO B VALUES (5, NULL, NULL);
COMMIT;
EOF
# THE ENGINE MUST BE ABLE TO OPEN THIS OVER TCP. The isql cells above
# reach it through a LOCAL path, where the file's owner is enough; the
# parameterized cells below attach to 127.0.0.1:3050, and the engine runs
# as its own user - without this every one of them answers CONN_ERR on
# the engine side (caught by the vacuity guard, which refuses to score
# two non-answers as agreement).
chmod 666 "$DB" 2>/dev/null || true

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-union.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
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

fail=0
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# A PARAMETERIZED TWIN. `same` runs isql, which binds nothing, so a `?`
# in a branch needs a client that ships an argument message. Same
# differential: one statement, both servers, the row sets must match.
ran=0
sameq() { # <label> <sql> <json args>
    ran=$((ran + 1))
    local a b
    a=$(FC_Q="$2" FC_A="$3" FC_PORT="$PORT" FC_DB="$DB" node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_A),(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null)
    b=$(FC_Q="$2" FC_A="$3" FC_PORT=3050 FC_DB="$DB" node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(0);}
        db.query(process.env.FC_Q,JSON.parse(process.env.FC_A),(e2,r)=>{
          if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
          console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
          db.detach();process.exit(0);});});' 2>/dev/null)
    # A SIDE THAT DID NOT ANSWER IS NOT AGREEMENT: two CONN_ERRs compare
    # equal and would score OK while measuring nothing.
    if [ "$a" = "CONN_ERR" ] || [ "$b" = "CONN_ERR" ] || [ -z "$a" ] || [ -z "$b" ]; then
        echo "DIFF $1 $3 [VACUOUS: a side did not answer] fc=[$a] engine=[$b]"; fail=1; return
    fi
    if [ "$a" = "$b" ]; then
        echo "OK   $1 $3: $a"
    else
        echo "DIFF $1 $3"; echo "     engine: [$b]"; echo "     fc:     [$a]"; fail=1
    fi
}

# --- a ? INSIDE A BRANCH -----------------------------------------------
# A branch used to be planned into a FRESH sink and refused if it claimed
# a slot, and then - once that guard went - plan_union still CLEARED the
# sink after building the branches, so the statement prepared and
# described ZERO input fields for a union that has one. Slots number by
# TEXT POSITION, left to right across the branches.
#
# Every predicate is paired with a twin that must answer NOTHING from
# that branch, so a branch whose `?` never bound would fail one of them.
sameq "a ? in the FIRST branch" "SELECT ID FROM A WHERE ID > ? UNION ALL SELECT ID FROM B ORDER BY 1" '[2]'
sameq "...the FIRST branch EXCLUDES" "SELECT ID FROM A WHERE ID > ? UNION ALL SELECT ID FROM B ORDER BY 1" '[99]'
sameq "a ? in the SECOND branch" "SELECT ID FROM A UNION ALL SELECT ID FROM B WHERE ID > ? ORDER BY 1" '[1]'
sameq "...the SECOND branch EXCLUDES" "SELECT ID FROM A UNION ALL SELECT ID FROM B WHERE ID > ? ORDER BY 1" '[99]'
sameq "a ? in BOTH branches" "SELECT ID FROM A WHERE ID > ? UNION ALL SELECT ID FROM B WHERE ID < ? ORDER BY 1" '[2,5]'
sameq "...the second half excludes" "SELECT ID FROM A WHERE ID > ? UNION ALL SELECT ID FROM B WHERE ID < ? ORDER BY 1" '[2,0]'
sameq "THREE branches, a ? in each" "SELECT ID FROM A WHERE ID > ? UNION ALL SELECT ID FROM B WHERE ID < ? UNION ALL SELECT ID FROM A WHERE ID = ? ORDER BY 1" '[3,2,1]'
sameq "a distinct UNION with a ? each" "SELECT N FROM A WHERE N > ? UNION SELECT N FROM B WHERE N > ? ORDER BY 1" '[5,5]'
sameq "a ? with the union's ORDER BY" "SELECT ID FROM A WHERE ID > ? UNION ALL SELECT ID FROM B ORDER BY 1 DESC" '[2]'
sameq "a DERIVED TABLE in a branch" "SELECT X.ID FROM (SELECT ID FROM A WHERE ID > ?) X UNION ALL SELECT ID FROM B ORDER BY 1" '[2]'
sameq "a FOLD in a branch" "SELECT COUNT(*) FROM A WHERE ID > ? UNION ALL SELECT ID FROM B ORDER BY 1" '[2]'
# the control: the same union with no `?` at all worked before and must
# still, which is what says these cells measure the BOUND half
same "CONTROL the same union, no ?" "SELECT ID FROM A WHERE ID > 2 UNION ALL SELECT ID FROM B ORDER BY 1"

# --- UNION ALL ---------------------------------------------------------
same "ALL over two tables"          "SELECT ID FROM A UNION ALL SELECT ID FROM B ORDER BY 1"
same "ALL keeps duplicates"         "SELECT N FROM A UNION ALL SELECT N FROM B ORDER BY 1"
same "ALL of one table with itself" "SELECT ID FROM A UNION ALL SELECT ID FROM A ORDER BY 1"
same "ALL over different columns"   "SELECT ID FROM A UNION ALL SELECT N FROM A ORDER BY 1"

# --- UNION (de-duplicating) --------------------------------------------
same "UNION removes duplicates"     "SELECT N FROM A UNION SELECT N FROM B ORDER BY 1"
same "UNION of a table with itself" "SELECT ID FROM A UNION SELECT ID FROM A ORDER BY 1"
same "UNION over two tables"        "SELECT ID FROM A UNION SELECT ID FROM B ORDER BY 1"
same "UNION on text columns"        "SELECT S FROM A UNION SELECT S FROM B ORDER BY 1"

# --- per-branch WHERE --------------------------------------------------
same "each branch filters"          "SELECT ID FROM A WHERE ID = 1 UNION ALL SELECT ID FROM B WHERE ID = 5"
same "a branch that matches nothing" "SELECT ID FROM A WHERE ID > 99 UNION ALL SELECT ID FROM B ORDER BY 1"
same "both branches filtered"       "SELECT N FROM A WHERE N > 15 UNION SELECT N FROM B WHERE N > 15 ORDER BY 1"

# --- three branches ----------------------------------------------------
same "three-way ALL"                "SELECT ID FROM A UNION ALL SELECT ID FROM B UNION ALL SELECT ID FROM A ORDER BY 1"
same "three-way UNION"              "SELECT ID FROM A UNION SELECT ID FROM B UNION SELECT ID FROM A ORDER BY 1"

# --- several columns ---------------------------------------------------
same "two columns, ALL"             "SELECT ID, N FROM A UNION ALL SELECT ID, N FROM B ORDER BY 1"
same "two columns, de-duplicated"   "SELECT ID, N FROM A UNION SELECT ID, N FROM B ORDER BY 1"
same "an expression in a branch"    "SELECT N + 1 FROM A UNION ALL SELECT N FROM B ORDER BY 1"

# --- ORDER BY ----------------------------------------------------------
same "ORDER BY ordinal ascending"   "SELECT ID FROM A UNION ALL SELECT ID FROM B ORDER BY 1"
same "ORDER BY ordinal descending"  "SELECT ID FROM A UNION ALL SELECT ID FROM B ORDER BY 1 DESC"
same "ORDER BY the second column"   "SELECT ID, N FROM A UNION ALL SELECT ID, N FROM B ORDER BY 2"
same "no ORDER BY at all"           "SELECT ID FROM A WHERE ID = 1 UNION ALL SELECT ID FROM B WHERE ID = 1"

# --- NULLs -------------------------------------------------------------
same "NULLs travel through ALL"     "SELECT N FROM A UNION ALL SELECT N FROM B ORDER BY 1"
same "NULLs de-duplicate in UNION"  "SELECT N FROM A UNION SELECT N FROM B ORDER BY 1"
same "an all-NULL row de-duplicates" "SELECT N, S FROM A UNION SELECT N, S FROM B ORDER BY 1"

# --- teeth -------------------------------------------------------------
# 1. UNION and UNION ALL must give DIFFERENT counts here, or the
#    de-duplication is not being exercised at all
a=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM (SELECT N FROM A UNION ALL SELECT N FROM B);\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -d ' \n')
all=$(printf 'SET HEADING OFF;\nSELECT N FROM A UNION ALL SELECT N FROM B;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
dis=$(printf 'SET HEADING OFF;\nSELECT N FROM A UNION SELECT N FROM B;\n' |
      "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ' | wc -w)
if [ "$all" -gt "$dis" ]; then
    echo "OK   teeth: ALL returns more rows than UNION ($all words vs $dis)"
else
    echo "DIFF ALL gave $all and UNION $dis - de-duplication is not exercised"; fail=1
fi

# 2. the de-duplication must keep ONE of each value, not drop them all
u=$(printf 'SET HEADING OFF;\nSELECT N FROM A UNION SELECT N FROM B ORDER BY 1;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$u" in
    *10*20*30*99*) echo "OK   teeth: every distinct value survives ($u)" ;;
    *) echo "DIFF the de-duplicated set is [$u], want 10 20 30 99 and a NULL"; fail=1 ;;
esac

# 3. a branch count mismatch must FAIL, not pad or truncate
out=$(printf 'SELECT ID FROM A UNION ALL SELECT ID, N FROM B;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: mismatched branch widths are refused" ;;
    *) echo "DIFF mismatched branch widths answered [$out]"; fail=1 ;;
esac

# 4. an aggregate branch answers under the AGGREGATE's description
# (the engine: COUNT(*) is INT64 and wider than ID, so the union column
# describes as COUNT and the first row is A's count, then B's ids)
out=$(printf 'SELECT COUNT(*) FROM A UNION ALL SELECT ID FROM B ORDER BY 1;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"COUNT"*1*2*4*5*) echo "OK   teeth: an aggregate branch answers as COUNT ($out)" ;;
    *) echo "DIFF an aggregate branch answered [$out], want COUNT then 1 2 4 5"; fail=1 ;;
esac

if [ "$ran" -lt 11 ]; then
    echo "DIFF only $ran parameterized checks ran (expected at least 11) - did one silently skip?"
    fail=1
fi

exit $fail
