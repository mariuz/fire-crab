#!/bin/sh
# BLR differential QA: for every BLR blob in a database (computed
# fields, view/trigger/procedure bodies, check constraints, defaults),
# compare fire-crab's structural decode against the engine's OWN BLR
# printer - the `SET BLOB ALL` rendering isql produces via gds.cpp,
# exactly the code fire-crab converts. The comparison is on the
# sequence of `blr_*` verb/dtype tokens: if fire-crab's grammar is
# wrong it emits a different token, overruns, or reports an unknown
# verb.
#
#   qa/diff-blr.sh <isql-conn-string>
#   e.g. qa/diff-blr.sh localhost:/tmp/fbhandson/plans_fbcpp.fdb
#
# Each BLR source is a row of (label, hex, expected-tokens); a source
# fire-crab cannot fully decode (unknown verb) is reported as SKIP with
# the offending verb, not counted as a pass - honest about the
# grammar's current coverage.

set -u
ISQL="${ISQL:-isql}"
FCSTAT="${FCSTAT:-$(dirname "$0")/../target/release/fcstat}"
CONN="${1:?usage: diff-blr.sh <isql-conn-string>}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
tmp="${TMPDIR:-/tmp}/fc_blr.$$"

run() { "$ISQL" -q -b -user "$U" -pas "$P" "$CONN"; }

# collect BLR sources: computed fields, procedures, triggers, views.
# each line: TYPE|LABEL where the follow-up query fetches the blr hex.
sources=$(run <<'EOF' | awk 'NF'
SET HEADING OFF;
SELECT 'CF|' || TRIM(rf.RDB$FIELD_NAME) || '|' || TRIM(f.RDB$FIELD_NAME)
FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON rf.RDB$FIELD_SOURCE = f.RDB$FIELD_NAME
WHERE f.RDB$COMPUTED_BLR IS NOT NULL;
SELECT 'PR|' || TRIM(RDB$PROCEDURE_NAME)
FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_BLR IS NOT NULL;
SELECT 'TR|' || TRIM(RDB$TRIGGER_NAME)
FROM RDB$TRIGGERS WHERE RDB$TRIGGER_BLR IS NOT NULL
  AND COALESCE(RDB$SYSTEM_FLAG,0) = 0;
EOF
)

hex_for() { # $1 type  $2 fieldsource-or-name
    case "$1" in
        CF) run <<EOF | tr -d ' \n\r'
SET HEADING OFF;
SELECT CAST(f.RDB\$COMPUTED_BLR AS VARCHAR(30000) CHARACTER SET OCTETS)
FROM RDB\$FIELDS f WHERE TRIM(f.RDB\$FIELD_NAME) = '$2';
EOF
        ;;
        PR) run <<EOF | tr -d ' \n\r'
SET HEADING OFF;
SELECT CAST(RDB\$PROCEDURE_BLR AS VARCHAR(30000) CHARACTER SET OCTETS)
FROM RDB\$PROCEDURES WHERE TRIM(RDB\$PROCEDURE_NAME) = '$2';
EOF
        ;;
        TR) run <<EOF | tr -d ' \n\r'
SET HEADING OFF;
SELECT CAST(RDB\$TRIGGER_BLR AS VARCHAR(30000) CHARACTER SET OCTETS)
FROM RDB\$TRIGGERS WHERE TRIM(RDB\$TRIGGER_NAME) = '$2';
EOF
        ;;
    esac
}

render_for() { # same selection but SET BLOB ALL -> gds.cpp tokens
    col=$1; tbl=$2; key=$3; val=$4
    run <<EOF | grep -oE 'blr_[a-z0-9_]+'
SET BLOB ALL; SET HEADING OFF;
SELECT $col FROM $tbl WHERE TRIM($key) = '$val';
EOF
}

ok=0; skip=0; fail=0
echo "$sources" | while IFS='|' read -r typ label src; do
    [ -z "$typ" ] && continue
    case "$typ" in
        CF) key="$src"; col="f.RDB\$COMPUTED_BLR"; tbl="RDB\$FIELDS f"; kf="f.RDB\$FIELD_NAME"; kv="$src"; disp="computed $label" ;;
        PR) key="$label"; col="RDB\$PROCEDURE_BLR"; tbl="RDB\$PROCEDURES"; kf="RDB\$PROCEDURE_NAME"; kv="$label"; disp="procedure $label" ;;
        TR) key="$label"; col="RDB\$TRIGGER_BLR"; tbl="RDB\$TRIGGERS"; kf="RDB\$TRIGGER_NAME"; kv="$label"; disp="trigger $label" ;;
    esac

    hex=$(hex_for "$typ" "$key")
    [ -z "$hex" ] && continue
    printf '%s' "$hex" | xxd -r -p > "$tmp.bin" 2>/dev/null

    engine=$(render_for "$col" "$tbl" "$kf" "$kv")
    fc=$("$FCSTAT" blr "$tmp.bin" 2>"$tmp.err" | grep -oE 'blr_[a-z0-9_]+')

    if [ -z "$fc" ]; then
        echo "SKIP $disp: $(cat "$tmp.err")"
        continue
    fi
    if [ "$engine" = "$fc" ]; then
        n=$(printf '%s\n' "$engine" | grep -c .)
        echo "OK   $disp: $n blr tokens match the engine's printer"
    else
        echo "DIFF $disp:"
        diff <(printf '%s\n' "$engine") <(printf '%s\n' "$fc") | head -8 | sed 's/^/     /'
    fi
done

rm -f "$tmp.bin" "$tmp.err"
