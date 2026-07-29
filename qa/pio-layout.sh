#!/bin/bash
# Platform I/O - the floor of the engine, checked against the engine's own
# accounting of it:
#
#   1. THE PAGE COUNT. PIO_get_number_of_pages is file_size / page_size,
#      integer division. The engine publishes its own answer as
#      MON$DATABASE.MON$PAGES, so the two must agree exactly - on every
#      database, before and after growth - and the file's length must be a
#      whole number of pages.
#
#   2. THE ADDRESSING LAW. offset = page * page_size (seek_file), absolute,
#      no rebasing. RDB$PAGES records the TYPE of many pages, so reading
#      each of those pages through our arithmetic must find a page of the
#      type the engine recorded. With teeth: the same comparison shifted by
#      one page must NOT agree, or the check has no discriminating power.
#
#   3. THE HEADER BOOTSTRAP. PIO_header reads the first bytes before the
#      page size is known (it is inside them, at offset 16). A 20-byte read
#      must already yield the page size MON$DATABASE reports.
#
#   4. FORCED WRITES IS AN OPEN MODE. gfix -w sync/async flips
#      hdr_force_write; the flag decides whether the next attach adds SYNC
#      to its open flags. Our decode of the bit must follow gfix, and match
#      what gstat -h prints as "Attributes".
#
#   5. THE FILE LOCK, and why fire-crab can read a live database. The
#      engine flocks the file (LOCK_EX in SuperServer mode) and reports a
#      busy lock as isc_already_opened. With a live attachment our probe
#      must say BUSY - and a fire-crab READ must still succeed, because it
#      takes no lock. That is the property every differential in this repo
#      rests on.
#
#   6. REFUSALS. A page past the end of the file must be an error, never a
#      zero-filled buffer that looks like an empty page one layer up; a
#      truncated file must not report a whole number of pages.
#
#   qa/pio-layout.sh
#
# Builds its own scratch database; also reads /opt/firebird's sample.

set -u
FCPIO="${FCPIO:-$(dirname "$0")/../target/release/fcpio}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GSTAT="${GSTAT:-gstat}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-pio.fdb"
SAMPLE="${FC_REAL_DB:-/opt/firebird/examples/empbuild/employee.fdb}"

mkdir -p "$D"; rm -f "$DB"
fail=0
val() { awk -v k="$1" '$1 == k {print $2}'; }

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, PAD VARCHAR(200));
CREATE INDEX T_ID ON T (ID);
COMMIT;
EOF

# The row generator: a recursive CTE CROSS JOINED with itself, because
# Firebird caps recursion at 1024 levels - a single `WHERE I < 4000`
# recursion fails, and the first version of this gate failed silently and
# then "verified" a page count that had not moved. 500 x <mult> rows.
insert_rows() { # <multiplier>  (500 * multiplier rows)
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<EOF
INSERT INTO T (ID, PAD)
  WITH RECURSIVE N AS (SELECT 1 AS I FROM RDB\$DATABASE
                       UNION ALL SELECT I + 1 FROM N WHERE I < 500)
  SELECT A.I, LPAD('', 200, 'x') FROM N A CROSS JOIN N B WHERE B.I <= $1;
COMMIT;
EOF
}

rows_now() {
    "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<'SQL' | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM T;
SQL
}

mon() { # <db> <column>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>/dev/null <<SQL | tr -d ' \n'
SET HEADING OFF;
SELECT $2 FROM MON\$DATABASE;
SQL
}

# ------------------------------------------------- 1. the page count -----
count_check() { # <label> <db>
    o=$("$FCPIO" pages "$2" 2>&1)
    ours=$(printf '%s\n' "$o" | val PAGES)
    whole=$(printf '%s\n' "$o" | val WHOLE)
    ps=$(printf '%s\n' "$o" | val PAGE_SIZE)
    eng=$(mon "$2" 'MON$PAGES')
    eps=$(mon "$2" 'MON$PAGE_SIZE')
    if [ -n "$eng" ] && [ "$ours" = "$eng" ] && [ "$whole" = "yes" ] && [ "$ps" = "$eps" ]; then
        echo "OK   $1: $ours pages of $ps bytes = MON\$PAGES, length a whole number of pages"
    else
        echo "DIFF $1: fcpio pages=$ours whole=$whole ps=$ps; engine MON\$PAGES=$eng ps=$eps"
        fail=1
    fi
}
count_check "fresh scratch database" "$DB"
count_check "the employee sample" "$SAMPLE"

# Growth: the same invariant has to hold as the file grows - and the file
# must actually GROW, or the three checks above are one check repeated.
before=$("$FCPIO" pages "$DB" | val PAGES)
insert_rows 8      # 4000 rows
count_check "after 4000 rows" "$DB"
insert_rows 16     # 8000 more
count_check "after 12000 rows" "$DB"
after=$("$FCPIO" pages "$DB" | val PAGES)
rows=$(rows_now)
if [ "$rows" -ge 12000 ] && [ "$after" -gt "$before" ]; then
    echo "OK   the file really grew while being checked: $before -> $after pages for $rows rows"
else
    echo "DIFF growth was vacuous: $before -> $after pages, $rows rows inserted"; fail=1
fi

# ------------------------------------------- 2. the addressing law -------
# the engine's own record of which page holds what
eng_pages=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<'SQL' | awk 'NF==2{print $1" "$2}'
SET HEADING OFF;
SELECT RDB$PAGE_NUMBER, RDB$PAGE_TYPE FROM RDB$PAGES ORDER BY RDB$PAGE_NUMBER;
SQL
)
n=0; match=0; shifted=0
while read -r pg ty; do
    [ -z "$pg" ] && continue
    n=$((n + 1))
    got=$("$FCPIO" read "$DB" "$pg" 2>/dev/null | awk '{print $6}')
    [ "$got" = "$ty" ] && match=$((match + 1))
    got2=$("$FCPIO" read "$DB" "$((pg + 1))" 2>/dev/null | awk '{print $6}')
    [ "$got2" = "$ty" ] && shifted=$((shifted + 1))
done <<EOF
$eng_pages
EOF
if [ "$n" -gt 10 ] && [ "$match" = "$n" ]; then
    echo "OK   every one of $n pages RDB\$PAGES records has the type the engine says, read at page*page_size"
else
    echo "DIFF page types: $match of $n matched (engine's own RDB\$PAGES)"; fail=1
fi
if [ "$shifted" -lt "$n" ]; then
    echo "OK   the same comparison shifted by ONE page disagrees ($shifted of $n) - the check discriminates"
else
    echo "DIFF a one-page shift matched just as well: the type check proves nothing"; fail=1
fi
# page 0 is the header, by definition of the format
t0=$("$FCPIO" read "$DB" 0 2>/dev/null | awk '{print $6}')
if [ "$t0" = "1" ]; then
    echo "OK   page 0 is the header page (type 1) at offset 0"
else
    echo "DIFF page 0 type [$t0]"; fail=1
fi

# ------------------------------------------- 3. the header bootstrap -----
h=$("$FCPIO" header "$DB" 20 2>&1)
hps=$(printf '%s\n' "$h" | val PAGE_SIZE)
eps=$(mon "$DB" 'MON$PAGE_SIZE')
if [ "$hps" = "$eps" ] && [ "$(printf '%s\n' "$h" | val READ)" = "20" ]; then
    echo "OK   a 20-byte header read already yields the page size ($hps) - the bootstrap PIO_header exists for"
else
    echo "DIFF header bootstrap: [$(printf '%s' "$h" | tr '\n' ' ')] engine ps=$eps"; fail=1
fi

# -------------------------------------- 4. forced writes as an open mode -
fw_state() { "$FCPIO" attributes "$1" 2>&1; }
gstat_attrs() {
    "$GSTAT" -h -user "$U" -pas "$P" "$1" 2>&1 |
        awk -F'\t' '/Attributes/{a=$NF} END{gsub(/^ +| +$/,"",a); print a}'
}
"$GFIX" -w sync -user "$U" -pas "$P" "$DB" >/dev/null 2>&1
s=$(fw_state "$DB")
if [ "$(printf '%s\n' "$s" | val ATTRIBUTES)" = "force" ] ||
   printf '%s\n' "$s" | grep -q "ATTRIBUTES force write"; then
    open=$(printf '%s\n' "$s" | sed -n 's/^OPEN //p')
    if [ "$open" = "O_BINARY|O_RDWR|SYNC" ]; then
        echo "OK   gfix -w sync sets hdr_force_write, and the open mode gains SYNC ($open)"
    else
        echo "DIFF force-write open mode: [$open]"; fail=1
    fi
else
    echo "DIFF after gfix -w sync: [$(printf '%s' "$s" | tr '\n' ' ')]"; fail=1
fi
ga=$(gstat_attrs "$DB")
case "$ga" in
    *"force write"*) echo "OK   gstat -h agrees: Attributes = $ga" ;;
    *) echo "DIFF gstat -h attributes [$ga]"; fail=1 ;;
esac

"$GFIX" -w async -user "$U" -pas "$P" "$DB" >/dev/null 2>&1
s=$(fw_state "$DB")
open=$(printf '%s\n' "$s" | sed -n 's/^OPEN //p')
ga=$(gstat_attrs "$DB")
if [ "$(printf '%s\n' "$s" | val ATTRIBUTES)" = "-" ] && [ "$open" = "O_BINARY|O_RDWR" ] &&
   [ -z "$ga" ]; then
    echo "OK   gfix -w async clears it: no SYNC, and gstat -h prints no attributes either"
else
    echo "DIFF after gfix -w async: fcpio [$(printf '%s' "$s" | tr '\n' ' ')] gstat [$ga]"; fail=1
fi
"$GFIX" -w sync -user "$U" -pas "$P" "$DB" >/dev/null 2>&1

# with forced writes ON, a committed row is in the FILE, not just in a
# cache: a copy taken after COMMIT must contain it
insert_rows 10
cp "$DB" "$D/fc-pio-copy.fdb"
rows=$("$ISQL" -q -b -user "$U" -pas "$P" "$D/fc-pio-copy.fdb" 2>/dev/null <<'SQL' | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM T;
SQL
)
live=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<'SQL' | tr -d ' \n'
SET HEADING OFF;
SELECT COUNT(*) FROM T;
SQL
)
if [ -n "$rows" ] && [ "$rows" = "$live" ]; then
    echo "OK   with forced writes on, a copy taken after COMMIT holds every row ($rows)"
else
    echo "DIFF copy has $rows rows, the database has $live"; fail=1
fi
rm -f "$D/fc-pio-copy.fdb"

# -------------------------------------------------- 5. the file lock ----
F=/tmp/fc-pio-gate-fifo; rm -f "$F"; mkfifo "$F"
"$ISQL" -q -b -user "$U" -pas "$P" "localhost:$SAMPLE" < "$F" >/dev/null 2>&1 &
isql_pid=$!
exec 9> "$F"
printf 'SELECT COUNT(*) FROM RDB$RELATIONS;\n' >&9
sleep 1
busy=$("$FCPIO" lock "$SAMPLE" 2>&1 | val LOCK)
readable=$("$FCPIO" read "$SAMPLE" 0 2>&1 | awk '{print $6}')
printf 'QUIT;\n' >&9; exec 9>&-; wait $isql_pid 2>/dev/null; rm -f "$F"
sleep 1
free=$("$FCPIO" lock "$SAMPLE" 2>&1 | val LOCK)
if [ "$busy" = "BUSY" ] && [ "$free" = "FREE" ]; then
    echo "OK   the engine's flock is visible: BUSY while attached, FREE after (isc_already_opened's cause)"
else
    echo "DIFF lock probe: attached=[$busy] detached=[$free]"; fail=1
fi
if [ "$readable" = "1" ]; then
    echo "OK   fire-crab READ the same file while the engine held it locked (it takes no lock)"
else
    echo "DIFF reading a locked database gave type [$readable]"; fail=1
fi

# ---------------------------------------------------- 6. refusals -------
pages=$("$FCPIO" pages "$DB" | val PAGES)
r=$("$FCPIO" read "$DB" "$pages" 2>&1)
case "$r" in
    REFUSED*"but the file is"*)
        echo "OK   a page past the end is refused, not a zero-filled buffer" ;;
    *) echo "DIFF reading page $pages (one past the end): [$r]"; fail=1 ;;
esac
# a truncated file must not claim a whole number of pages
cp "$DB" "$D/fc-pio-trunc.fdb"
ps=$("$FCPIO" pages "$DB" | val PAGE_SIZE)
python3 - "$D/fc-pio-trunc.fdb" "$ps" <<'PYEOF'
import os, sys
path, ps = sys.argv[1], int(sys.argv[2])
size = os.path.getsize(path)
os.truncate(path, size - ps // 2)   # half a page short
PYEOF
w=$("$FCPIO" pages "$D/fc-pio-trunc.fdb" | val WHOLE)
if [ "$w" = "no" ]; then
    echo "OK   a half-page-short file reports WHOLE no (the integer division would have hidden it)"
else
    echo "DIFF truncated file reports WHOLE [$w]"; fail=1
fi
rm -f "$D/fc-pio-trunc.fdb"

# the pure arithmetic, against the numbers the source states
o=$("$FCPIO" offset 200 8192 | val OFFSET)
e=$("$FCPIO" extend-plan 100 50 8192)
i=$("$FCPIO" init-plan 3 100 8192 | val PAGES)
i8=$("$FCPIO" init-plan 8 100 8192)
if [ "$o" = "1638400" ] &&
   [ "$(printf '%s\n' "$e" | val OFFSET)" = "819200" ] &&
   [ "$(printf '%s\n' "$e" | val LENGTH)" = "409600" ] &&
   [ "$i" = "0" ] &&
   [ "$(printf '%s\n' "$i8" | val SYSCALLS)" = "4" ]; then
    echo "OK   the arithmetic: offset 200*8192, extension from the current end, zero-fill floored at page 8"
else
    echo "DIFF arithmetic: offset=$o extend=[$(printf '%s' "$e" | tr '\n' ' ')] init(3)=$i init(8)=[$(printf '%s' "$i8" | tr '\n' ' ')]"
    fail=1
fi

exit $fail
