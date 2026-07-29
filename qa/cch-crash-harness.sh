#!/bin/bash
# The careful-write crash harness - fire-crab-cch's differential.
# Firebird has no WAL: crash safety IS the page-write order, held by
# cch.cpp's precedence graph. This gate makes that claim executable
# across THREE workloads:
#
#   insert   120 rows through fire-crab's own write path - header,
#            TIP, PIP, pointer and data pages all change
#   indexed  the same inserts PLUS B-tree maintenance on T's index -
#            btree pages join the ensemble (an index entry names a
#            record NUMBER, so data pages precede btree pages)
#   delete   2 committed rows deleted - version-chain stubs, TIP and
#            header; nothing allocates
#
# For every workload, EVERY careful crash prefix must satisfy the
# engine: gfix -v -full -n reports no errors (benign warnings allowed
# - the orphan window between PIP and pointer), and isql reads
# exactly the PRE-OPERATION rows until the TIP commit flip lands last
# (the full prefix reads the post-operation rows). The file is never
# wrong, only ever behind.
#
# And the TEETH: the naive reverse order must break somewhere - for
# inserts it manufactures phantom rows; for deletes it makes rows
# VANISH EARLY (the TIP flip arriving before the stubs' pages).
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
ROWS_BEFORE=2

DBI="$D/fc-cchgate-idx.fdb"
mkdir -p "$D"; rm -rf "$DB" "$DBI" "$D"/cch-m-*
# two scratch databases: the PLAIN one for the un-indexed insert
# workload (an insert that skips index maintenance would leave an
# indexed table inconsistent at the FULL prefix - the gate itself
# proved it), the INDEXED one for the indexed and delete workloads
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 4096;
CREATE TABLE T (NAME CHAR(120));
COMMIT;
INSERT INTO T VALUES ('committed-1');
INSERT INTO T VALUES ('committed-2');
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create idx"; exit 1; }
CREATE DATABASE '$DBI' USER '$U' PASSWORD '$P' PAGE_SIZE 4096;
CREATE TABLE T (NAME CHAR(120));
CREATE INDEX IDX_T_NAME ON T (NAME);
COMMIT;
INSERT INTO T VALUES ('committed-1');
INSERT INTO T VALUES ('committed-2');
COMMIT;
EOF

fail=0
rows_of() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<'SQL' | tr -s ' \n\t' ' ' | sed 's/^ *//; s/ *$//'
SET HEADING OFF;
SELECT COUNT(*) FROM T;
SQL
}
validate() {
    "$GFIX" -v -full -n -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n\t' ' '
}

run_workload() { # <db> <workload> <n> <rows-after-full>
    wdb=$1; wl=$2; n=$3; want_full=$4
    MC="$D/cch-m-$wl"; MN="$D/cch-m-$wl-naive"
    "$FCCCH" crash-matrix "$wdb" "$MC" "$wl" "$n" > "$D/cch-order-$wl.txt" || {
        echo "FAIL fccch $wl careful run"; fail=1; return; }
    prefixes=$(grep '^PREFIXES' "$D/cch-order-$wl.txt" | awk '{print $2}')
    echo "$wl careful order: $(grep -c '^ORDER' "$D/cch-order-$wl.txt") writes ($(grep '^ORDER' "$D/cch-order-$wl.txt" | awk '{print $4}' | tr '\n' ' '))"
    last=$((prefixes - 1))
    ok=1
    for k in $(seq 0 $last); do
        f=$(printf '%s/crash-%03d.fdb' "$MC" "$k")
        v=$(validate "$f")
        case "$v" in
            *"errors :"*) echo "DIFF $wl careful prefix $k: [$v]"; ok=0 ;;
        esac
        r=$(rows_of "$f")
        if [ "$k" -eq "$last" ]; then want=$want_full; else want=$ROWS_BEFORE; fi
        if [ "$r" != "$want" ]; then
            echo "DIFF $wl careful prefix $k: expected $want rows, got [$r]"
            ok=0
        fi
    done
    if [ $ok -eq 1 ]; then
        echo "OK   $wl: all $prefixes careful prefixes valid, rows $ROWS_BEFORE until the TIP flip, then $want_full"
    else
        fail=1
    fi
    # the teeth
    "$FCCCH" crash-matrix "$wdb" "$MN" "$wl" "$n" naive >/dev/null || {
        echo "FAIL fccch $wl naive run"; fail=1; return; }
    bad=0
    for k in $(seq 0 $last); do
        f=$(printf '%s/crash-%03d.fdb' "$MN" "$k")
        v=$(validate "$f")
        r=$(rows_of "$f")
        if [ "$k" -eq "$last" ]; then want=$want_full; else want=$ROWS_BEFORE; fi
        okv=1; case "$v" in *"errors :"*) okv=0 ;; esac
        [ $okv -eq 0 ] || [ "$r" != "$want" ] && bad=$((bad + 1))
    done
    if [ $bad -gt 0 ]; then
        echo "OK   $wl: naive order breaks at $bad of $prefixes prefixes (teeth)"
    else
        echo "DIFF $wl: naive order never broke"
        fail=1
    fi
    rm -rf "$MC" "$MN"
}

run_workload "$DB" insert 120 122
run_workload "$DBI" indexed 120 122
run_workload "$DBI" delete 2 0

exit $fail
