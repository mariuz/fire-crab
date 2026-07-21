#!/bin/sh
# The server answers real COLUMN PROJECTIONS. fire-crab runs as a server,
# opens the attached database, and answers SELECT <cols> FROM <table> from
# its actual pages: table resolved through RDB$RELATIONS, columns through
# RDB$RELATION_FIELDS (by field id, which is NOT the column position when a
# table mixes column widths), each record decoded with the format it names.
# Integer columns go on the wire as BIGINT, the rest rendered as VARCHAR.
# node-firebird drives it, and the whole result set must equal isql's.
#
#   qa/serve-real-project.sh <clean-db-path> [port]
#
# For every user table, the eligible columns (exact integers and
# ASCII/UTF8 char/varchar - the shapes the Rust side renders identically,
# same exclusions as qa/diff-rows.sh) are projected both through the
# fire-crab server (node-firebird) and through isql, pipe-joined, string
# values trimmed, sorted, and compared verbatim. A SELECT * is also checked
# per table. Use a clean (gbak-restored) database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
DB="${1:?usage: serve-real-project.sh <clean-db-path> [port]}"
PORT="${2:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$DB"; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-project.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

# node side: run <query>, print each row as its values joined by '|',
# strings right-trimmed to match engine TRIM / CHAR padding, nulls as <null>.
node_rows() {
    FC_DB="$DB" FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_Q="$1" node -e '
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:process.env.FC_U,password:process.env.FC_P},(e,db)=>{
        if(e){console.log("ATTACH_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          if(e2){console.log("QUERY_ERR "+e2.message);db.detach();process.exit(1);}
          for(const row of r)
            console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
          db.detach();process.exit(0);
        });
      });' 2>/dev/null | sort
}

compare() { # <label> <node-query> <isql-select-body>
    fc=$(node_rows "$2")
    is=$(run_isql <<EOF | sed 's/[[:space:]]*$//' | grep -v '^$' | sort
SET HEADING OFF;
$3;
EOF
)
    if [ "$fc" = "$is" ] && [ -n "$fc" ]; then
        echo "OK   $1 ($(printf '%s\n' "$fc" | grep -c .) rows)"; return 0
    fi
    echo "DIFF $1"
    printf '%s\n' "$is" > /tmp/fc-proj-is.txt; printf '%s\n' "$fc" > /tmp/fc-proj-fc.txt
    diff /tmp/fc-proj-is.txt /tmp/fc-proj-fc.txt | head -8 | sed 's/^/     /'
    return 1
}

tables=$(run_isql <<'EOF' | awk 'NF==1 && $1!=""'
SET HEADING OFF;
SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS
WHERE COALESCE(RDB$SYSTEM_FLAG,0)=0 AND RDB$VIEW_BLR IS NULL ORDER BY 1;
EOF
)

fail=0
for t in $tables; do
    # eligible columns (declaration order); build the node list and the
    # isql pipe-projection in lockstep. Skip types the Rust renderer does
    # not match byte-for-byte (double/float/decfloat/int128/tz, non-ASCII/
    # UTF8 charsets) - reported, not silently dropped.
    cols=$(run_isql <<EOF | awk 'NF>=4'
SET HEADING OFF;
SELECT rf.RDB\$FIELD_POSITION, f.RDB\$FIELD_TYPE, COALESCE(f.RDB\$CHARACTER_SET_ID,-1), TRIM(rf.RDB\$FIELD_NAME)
FROM RDB\$RELATION_FIELDS rf JOIN RDB\$FIELDS f ON rf.RDB\$FIELD_SOURCE=f.RDB\$FIELD_NAME
WHERE rf.RDB\$RELATION_NAME='$t' AND f.RDB\$FIELD_SCALE=0 ORDER BY rf.RDB\$FIELD_POSITION;
EOF
)
    nlist=""; ilist=""; skipped=""
    while read -r pos ftype cset fname; do
        [ -z "$fname" ] && continue
        case "$ftype" in
            7|8|16) iexpr="\"$fname\"" ;;
            14|37)  case "$cset" in 0|2|4) iexpr="TRIM(\"$fname\")" ;; *) skipped="$skipped $fname"; continue ;; esac ;;
            *) skipped="$skipped $fname"; continue ;;
        esac
        nlist="$nlist${nlist:+, }$fname"
        ilist="$ilist${ilist:+ || '|' || }COALESCE(CAST($iexpr AS VARCHAR(512)), '<null>')"
    done <<EOF
$cols
EOF
    [ -n "$skipped" ] && echo "note $t: skipping columns:$skipped"
    [ -z "$nlist" ] && continue
    compare "$t explicit" "SELECT $nlist FROM $t" "SELECT $ilist FROM \"$t\"" || fail=1
    # SELECT * returns every column, so only compare it when no column was
    # skipped (otherwise the star result carries columns the projection omits)
    [ -z "$skipped" ] && { compare "$t star" "SELECT * FROM $t" "SELECT $ilist FROM \"$t\"" || fail=1; }
done
exit $fail
