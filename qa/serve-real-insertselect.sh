#!/bin/bash
# INSERT ... SELECT - a write fed by a query.
#
# The query is planned by the ORDINARY planner at execute, its rows are
# materialised, and each one is then inserted through the ORDINARY insert
# path. That is the point: column defaults, NOT NULL, CHECK constraints,
# FK enforcement and index maintenance all apply exactly as they do to a
# client's own INSERT, with no second write path to keep in step. It also
# means the source can be anything this server can SELECT - a view, a
# query with a subquery in its WHERE, a UNION.
#
# THE DIFFERENTIAL: the same statement runs against a copy of one
# database through fire-crab and through the engine, and the ENGINE then
# reads both files back - the tables must be identical. gfix -v -full and
# gbak must accept what fire-crab wrote, and the engine must find the new
# rows THROUGH the index.
#
#   qa/serve-real-insertselect.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4411}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-isel.fdb"
W=/tmp/fc-isel-w.fdb
R=/tmp/fc-isel-r.fdb

mkdir -p "$D"; rm -f "$SRC" "$W" "$R"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE S (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, T VARCHAR(10), N NUMERIC(9,2));
CREATE TABLE D (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, T VARCHAR(10), N NUMERIC(9,2));
CREATE TABLE DFLT (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER DEFAULT 77, T VARCHAR(10));
CREATE TABLE CHK (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER CHECK (A < 250));
CREATE INDEX D_A ON D (A);
COMMIT;
INSERT INTO S VALUES (1, 10, 'x', 12.50);
INSERT INTO S VALUES (2, 20, 'y', 1.25);
INSERT INTO S VALUES (3, 30, 'z', 13.50);
INSERT INTO S VALUES (4, NULL, NULL, NULL);
COMMIT;
CREATE VIEW SV AS SELECT ID, A FROM S WHERE A > 15;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-isel.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$W" "$R" /tmp/fc-isel.fbk' EXIT
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
dump() { # <file> <table>
    printf 'SET HEADING OFF;\nSELECT ID, COALESCE(A,-9), COALESCE(T,%s), COALESCE(N,-9) FROM %s ORDER BY ID;\n' "'-'" "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '
}
same() { # <label> <sql> [table]
    tbl="${3:-D}"
    rm -f "$W" "$R"; cp "$SRC" "$W"; cp "$SRC" "$R"
    printf '%s;\nCOMMIT;\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/tmp/fc-isel-fc.log 2>&1
    printf '%s;\nCOMMIT;\n' "$2" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$R" >/tmp/fc-isel-en.log 2>&1
    ours=$(dump "$W" "$tbl"); theirs=$(dump "$R" "$tbl")
    if [ "$ours" = "$theirs" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$theirs]"; echo "     fc:     [$ours]"; fail=1
    fi
}

# --- the basic shapes --------------------------------------------------
same "every column, listed"        "INSERT INTO D (ID, A, T, N) SELECT ID, A, T, N FROM S"
same "no column list at all"       "INSERT INTO D SELECT ID, A, T, N FROM S"
same "a subset of the columns"     "INSERT INTO D (ID, A) SELECT ID, A FROM S"
same "columns in a different order" "INSERT INTO D (A, ID) SELECT A, ID FROM S"
same "a filtered source"           "INSERT INTO D (ID, A) SELECT ID, A FROM S WHERE A > 15"
same "a source that matches nothing" "INSERT INTO D (ID, A) SELECT ID, A FROM S WHERE A > 9999"
same "an expression in the source" "INSERT INTO D (ID, A) SELECT ID, A * 2 FROM S WHERE A IS NOT NULL"
same "a scaled NUMERIC column"     "INSERT INTO D (ID, N) SELECT ID, N FROM S"
same "NULLs come through"          "INSERT INTO D (ID, A, T) SELECT ID, A, T FROM S"
same "ORDER BY in the source"      "INSERT INTO D (ID, A) SELECT ID, A FROM S ORDER BY ID DESC"

# --- the source can be anything this server can SELECT -----------------
same "a VIEW as the source"        "INSERT INTO D (ID, A) SELECT ID, A FROM SV"
same "a subquery in the source's WHERE" \
     "INSERT INTO D (ID, A) SELECT ID, A FROM S WHERE ID IN (SELECT ID FROM S WHERE A > 15)"
same "a UNION as the source"       "INSERT INTO D (ID, A) SELECT ID, A FROM S WHERE ID = 1 UNION ALL SELECT ID, A FROM S WHERE ID = 2"

# --- the ordinary insert path's rules still apply ----------------------
same "a column DEFAULT fills an unlisted column" \
     "INSERT INTO DFLT (ID, T) SELECT ID, T FROM S" DFLT

# --- teeth -------------------------------------------------------------
# 1. the rows must really have been written, and through the index
rm -f "$W"; cp "$SRC" "$W"
printf 'INSERT INTO D (ID, A) SELECT ID, A FROM S;\nCOMMIT;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/dev/null 2>&1
n=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM D;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ "$n" = "4" ]; then
    echo "OK   teeth: all four source rows were written ($n)"
else
    echo "DIFF expected 4 rows in D, found [$n]"; fail=1
fi
plan=$(printf 'SET PLAN ON;\nSET HEADING OFF;\nSELECT ID FROM D WHERE A = 20;\n' |
       "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -s ' \n' ' ')
case "$plan" in
    *"D_A"*" 2 "*) echo "OK   teeth: the engine finds a written row THROUGH the index" ;;
    *) echo "DIFF index lookup after INSERT ... SELECT gave [$plan]"; fail=1 ;;
esac

# 2. the engine must accept the file
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ -z "$val" ]; then
    echo "OK   gfix -v -full accepts the file"
else
    echo "DIFF gfix on fc's file: $val"; fail=1
fi
if "$GBAK" -b -g -user "$U" -pas "$P" "$W" /tmp/fc-isel.fbk >/dev/null 2>&1; then
    echo "OK   gbak walks the file"
else
    echo "DIFF gbak failed on fc's file"; fail=1
fi

# 3. a CHECK violation in a selected row must FAIL the statement
rm -f "$W" "$R"; cp "$SRC" "$W"; cp "$SRC" "$R"
out=$(printf 'INSERT INTO CHK (ID, A) SELECT ID, A * 10 FROM S WHERE A IS NOT NULL;\nCOMMIT;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" 2>&1 | tr -s ' \n' ' ')
printf 'INSERT INTO CHK (ID, A) SELECT ID, A * 10 FROM S WHERE A IS NOT NULL;\nCOMMIT;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "$R" >/dev/null 2>&1
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: a CHECK violation in a selected row fails the statement" ;;
    *) echo "DIFF a CHECK violation reported [$out]"; fail=1 ;;
esac
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ -z "$val" ]; then
    echo "OK   teeth: the file is still valid after the failed statement"
else
    echo "DIFF gfix after the failed statement: $val"; fail=1
fi
# ...and the statement is ALL-OR-NOTHING: the rows that succeeded before
# the violation must be gone too. CHECK (A < 250) lets the first two rows
# through (10*10 = 100, 20*10 = 200) and fails the third (30*10 = 300), so
# a non-atomic implementation leaves TWO rows behind - which is exactly
# what this server did before statement-level rollback.
left=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM CHK;\n' |
       "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
eng_left=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM CHK;\n' |
       "$ISQL" -q -user "$U" -pas "$P" "$R" 2>&1 | tr -d ' \n')
if [ "$left" = "0" ]; then
    echo "OK   teeth: the failed statement rolled back completely ($left rows left)"
else
    echo "DIFF the failed statement left $left row(s) behind (engine leaves $eng_left)"; fail=1
fi

# 4. a column-count mismatch must be refused, not padded
out=$(printf 'INSERT INTO D (ID, A) SELECT ID FROM S;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" 2>&1 | tr -s ' \n' ' ')
case "$out" in
    *"Statement failed"*|*error*|*ERROR*)
        echo "OK   teeth: a column-count mismatch is refused" ;;
    *) echo "DIFF a column-count mismatch answered [$out]"; fail=1 ;;
esac

exit $fail
