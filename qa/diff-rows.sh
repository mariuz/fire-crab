#!/bin/sh
# Full-row differential QA: decode every row of every user table from
# the RAW FILE (fcstat rows: RDB$FORMATS bootstrap -> record walk ->
# field decode) and compare, value by value, against SELECT through
# the live C++ engine.
#
#   qa/diff-rows.sh <isql-conn-string> <file-path> [workdir]
#
# Like diff-select.sh, comparison happens on a gbak-restored CLEAN
# copy. Both sides are canonicalized: engine values via
# TRIM(CAST(.. AS VARCHAR)) with booleans lowercased and NULLs as
# <null>; fcstat values via per-field trim, with blob ids collapsed to
# <blob> on both sides. Columns whose types the Rust decoder does not
# yet render (double/float, DECFLOAT, INT128, TZ types) are excluded
# per-table and reported, not silently dropped.

set -u
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
CONN="${1:?usage: diff-rows.sh <isql-conn-string> <file-path> [workdir]}"
FILE="${2:?usage: diff-rows.sh <isql-conn-string> <file-path> [workdir]}"
WORK="${3:-/tmp/fbhandson}"
HOST="${CONN%%:*}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"

base=$(basename "$FILE" .fdb)
fbk="$WORK/${base}_rows.fbk"
clean="$WORK/${base}_rows_clean.fdb"
"$GBAK" -b -g "$CONN" "$fbk" -user "$U" -pas "$P" || exit 1
rm -f "$clean"
"$GBAK" -c "$fbk" "$HOST:$clean" -user "$U" -pas "$P" || exit 1

run_isql() { "$ISQL" -q -b -user "$U" -pas "$P" "$HOST:$clean"; }

tables=$(run_isql <<'EOF' | awk 'NF==2 && $1 ~ /^[0-9]+$/'
SET HEADING OFF;
SELECT r.RDB$RELATION_ID, TRIM(r.RDB$RELATION_NAME)
FROM RDB$RELATIONS r
WHERE COALESCE(r.RDB$SYSTEM_FLAG,0) = 0 AND r.RDB$VIEW_BLR IS NULL;
EOF
)

overall=0
echo "$tables" | while read -r relid relname; do
    [ -z "$relid" ] && continue

    # columns: position, FIELD_ID (the index into the stored format -
    # fcstat's output order), type, charset, name. gbak restore can
    # assign field ids in a different order than positions, so the two
    # must be mapped explicitly.
    cols=$(run_isql <<EOF | awk 'NF>=5 && $1 ~ /^[0-9]+$/'
SET HEADING OFF;
SELECT rf.RDB\$FIELD_POSITION, rf.RDB\$FIELD_ID, f.RDB\$FIELD_TYPE,
       COALESCE(f.RDB\$CHARACTER_SET_ID, -1), TRIM(rf.RDB\$FIELD_NAME)
FROM RDB\$RELATION_FIELDS rf JOIN RDB\$FIELDS f
  ON rf.RDB\$FIELD_SOURCE = f.RDB\$FIELD_NAME
WHERE rf.RDB\$RELATION_NAME = '$relname'
ORDER BY rf.RDB\$FIELD_POSITION;
EOF
)
    select_list=""; awk_cols=""; skipped=""
    while read -r pos fid ftype cset fname; do
        case "$ftype" in
            7|8|16)  expr="TRIM(CAST(\"$fname\" AS VARCHAR(64)))" ;;   # exact ints/numerics
            14|37)   # char/varchar: only charsets the Rust side renders
                     # byte-identically (2 ASCII, 4 UTF8); other charsets
                     # transliterate on the engine side - out of scope for
                     # this increment, skipped visibly
                     case "$cset" in
                         2|4) expr="TRIM(CAST(\"$fname\" AS VARCHAR(512)))" ;;
                         *)   skipped="$skipped $fname(cs$cset)"; continue ;;
                     esac ;;
            12|13|35) expr="TRIM(CAST(\"$fname\" AS VARCHAR(64)))" ;;  # date/time/timestamp
            23)      expr="LOWER(TRIM(CAST(\"$fname\" AS VARCHAR(8))))" ;; # boolean
            261)     expr="IIF(\"$fname\" IS NULL, CAST(NULL AS VARCHAR(8)), '<blob>')" ;; # blob presence
            *)       skipped="$skipped $fname($ftype)"; continue ;;     # double/float/dec/int128/tz
        esac
        select_list="$select_list${select_list:+ || '|' || }COALESCE($expr, '<null>')"
        awk_cols="$awk_cols${awk_cols:+,}$((fid + 1))"
    done <<EOF
$cols
EOF
    [ -n "$skipped" ] && echo "note $relname: skipping columns:$skipped"
    [ -z "$select_list" ] && continue

    engine=$(run_isql <<EOF | sed 's/[[:space:]]*$//' | grep -v '^$' | sort
SET HEADING OFF;
SELECT $select_list FROM "$relname";
EOF
)
    file_side=$("$FCSTAT" rows "$clean" "$relid" \
        | sed 's/<blob [0-9]*:[0-9]*>/<blob>/g' \
        | awk -F'\t' -v cols="$awk_cols" 'BEGIN{n=split(cols,C,",")}
            {out=""; for(i=1;i<=n;i++){v=$C[i]; gsub(/^ +| +$/,"",v); out=out (i>1?"|":"") v} print out}' \
        | sort)

    if [ "$engine" = "$file_side" ]; then
        n=$(printf '%s' "$engine" | grep -c . || true)
        echo "OK   $relname (rel $relid): $n rows match value-for-value"
    else
        echo "DIFF $relname (rel $relid):"
        diff <(printf '%s\n' "$engine") <(printf '%s\n' "$file_side") | head -10 | sed 's/^/     /'
        overall=1
    fi
done

rm -f "$fbk"
exit $overall
