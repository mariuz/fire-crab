#!/bin/bash
# The careful-write crash harness - fire-crab-cch's differential.
# Firebird has no WAL: crash safety IS the page-write order, held by
# cch.cpp's precedence graph. This gate makes that claim executable.
#
# fccch performs a real multi-page operation (a batch of inserts
# through fire-crab's own write path, sized to grow the relation so
# header, TIP, PIP, pointer and data pages all change), sequences the
# changed pages through the fire-crab-cch cache, and materializes
# EVERY crash prefix - the file as it would exist had the process died
# after the k-th page write. The ENGINE then judges every prefix:
#
#   - gfix -v -full -n must report NO errors on ANY careful prefix
#     (benign "warnings" are allowed - the orphan window between the
#     PIP write and the pointer write is space leaked, never data
#     harmed - the same artifact a real kill -9 can leave)
#   - isql must read EXACTLY the rows committed before the operation
#     began on every partial prefix, and all rows on the full one -
#     never a phantom, never a missing committed row
#
# And the TEETH: the same matrix in NAIVE order (the exact reverse)
# must break - at least one prefix with validation errors, a read
# failure, or a wrong row count. On this battery the naive order
# produces all three, including the worst class: a prefix that READS
# PHANTOM ROWS from the interrupted, uncommitted insert.
#
#   qa/cch-crash-harness.sh
#
# Builds its own scratch database.

set -u
FCCCH="${FCCCH:-$(dirname "$0")/../target/release/fccch}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-cchgate.fdb"
MC="$D/cch-careful"; MN="$D/cch-naive"
ROWS_BEFORE=2
ROWS_INSERT=120

mkdir -p "$D"; rm -rf "$DB" "$MC" "$MN"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 4096;
CREATE TABLE T (NAME CHAR(120));
COMMIT;
INSERT INTO T VALUES ('committed-1');
INSERT INTO T VALUES ('committed-2');
COMMIT;
EOF

fail=0
rows_of() { # <file> -> the row count, or the error text
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | tr -s ' \n\t' ' ' | sed 's/^ *//; s/ *$//'
SET HEADING OFF;
SELECT COUNT(*) FROM T;
SQL
}
validate() { # <file> -> gfix -n -v -full output, squeezed
    "$GFIX" -v -full -n -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n\t' ' '
}

# --- the careful matrix: every prefix must satisfy the engine --------
"$FCCCH" crash-matrix "$DB" "$MC" "$ROWS_INSERT" > "$D/cch-order.txt" || {
    echo "FAIL fccch careful run"; exit 1; }
prefixes=$(grep '^PREFIXES' "$D/cch-order.txt" | awk '{print $2}')
echo "careful write order:"
grep '^ORDER' "$D/cch-order.txt" | sed 's/^/  /'
last=$((prefixes - 1))
for k in $(seq 0 $last); do
    f=$(printf '%s/crash-%03d.fdb' "$MC" "$k")
    v=$(validate "$f")
    # "Summary of validation errors" heads the section even when only
    # WARNINGS follow - the per-class lines say "... errors : N"
    case "$v" in
        *"errors :"*) echo "DIFF careful prefix $k: validation errors [$v]"; fail=1 ;;
        *) : ;;
    esac
    r=$(rows_of "$f")
    if [ "$k" -eq "$last" ]; then
        want=$((ROWS_BEFORE + ROWS_INSERT))
    else
        want=$ROWS_BEFORE
    fi
    if [ "$r" = "$want" ]; then
        echo "OK   careful prefix $k: no errors, $r rows"
    else
        echo "DIFF careful prefix $k: expected $want rows, got [$r]"
        fail=1
    fi
done

# --- the teeth: the naive order must break somewhere -----------------
"$FCCCH" crash-matrix "$DB" "$MN" "$ROWS_INSERT" naive >/dev/null || {
    echo "FAIL fccch naive run"; exit 1; }
bad=0
phantom=0
for k in $(seq 0 $last); do
    f=$(printf '%s/crash-%03d.fdb' "$MN" "$k")
    v=$(validate "$f")
    r=$(rows_of "$f")
    if [ "$k" -eq "$last" ]; then want=$((ROWS_BEFORE + ROWS_INSERT)); else want=$ROWS_BEFORE; fi
    ok_v=1; case "$v" in *"errors :"*) ok_v=0 ;; esac
    if [ $ok_v -eq 0 ] || [ "$r" != "$want" ]; then
        bad=$((bad + 1))
        # the worst class: a readable file answering rows that were
        # never committed
        case "$r" in
            ''|*[!0-9]*) : ;;
            *) [ "$r" -gt "$want" ] && phantom=1 ;;
        esac
    fi
done
if [ $bad -gt 0 ]; then
    echo "OK   naive order breaks at $bad of $prefixes prefixes (the gate has teeth)"
else
    echo "DIFF naive order never broke - the workload cannot distinguish careful from careless"
    fail=1
fi
if [ $phantom -eq 1 ]; then
    echo "OK   naive order manufactured PHANTOM ROWS - the class careful writes exist to prevent"
else
    echo "note naive order produced no phantom-row prefix on this run"
fi

rm -rf "$MC" "$MN"
exit $fail
