#!/bin/sh
# The server answers a REAL query. fire-crab runs as a server, opens the
# database file the client names in op_attach, and answers
# SELECT COUNT(*) FROM <table> from its actual pages - resolving the table
# name through RDB$RELATIONS and counting committed primary records with
# the ods crate. A genuine third-party client (node-firebird) drives it
# over the encrypted wire, and every count must equal what isql returns
# through the C++ engine on the same file.
#
#   qa/serve-real-query.sh <clean-db-path> [port]
#
# Use a clean database (freshly created or gbak-restored: no uncommitted
# work, no pending back-versions), because the count is of primary record
# versions - the same clean-file precondition qa/diff-select.sh relies on.
# Every user table plus a few system tables are checked.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-query.sh <clean-db-path> [port]}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

if ! command -v node >/dev/null 2>&1; then echo "SKIP node not found"; exit 0; fi

# user tables + a stable set of system tables
tables=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<'EOF' | awk 'NF==1 && $1!=""'
SET HEADING OFF;
SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS
WHERE RDB$VIEW_BLR IS NULL
  AND (COALESCE(RDB$SYSTEM_FLAG,0)=0
       OR RDB$RELATION_NAME IN ('RDB$RELATIONS','RDB$FIELDS','RDB$DATABASE'))
ORDER BY RDB$RELATION_NAME;
EOF
)

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-query.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
    i=$((i + 1)); sleep 0.1
done

fail=0
for t in $tables; do
    fc=""
    n=0
    while [ $n -lt 8 ]; do
        fc=$(FC_DB="$DB" FC_PORT="$PORT" FC_T="$t" FC_U="$U" FC_P="$P" timeout 15 node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(1);}
            db.query("SELECT COUNT(*) FROM "+process.env.FC_T,(e2,r)=>{
              console.log(e2?"CONN_ERR":r[0][Object.keys(r[0])[0]]);db.detach();process.exit(0);});
          });' 2>/dev/null)
        case "$fc" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;; *) break ;; esac
    done
    is=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<EOF | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM $t;
EOF
)
    if [ "$fc" = "$is" ] && [ -n "$fc" ]; then
        echo "OK   COUNT(*) FROM $t = $fc"
    else
        echo "DIFF $t: fire-crab=$fc isql=$is"
        fail=1
    fi
done
exit $fail
