#!/bin/bash
# TRANSACTION ROLLBACK.
#
# This server writes each statement straight into the file, so undoing a
# whole transaction means putting the image back as it stood when the
# transaction began: op_transaction takes a snapshot, ROLLBACK restores
# it, COMMIT makes the current image the new starting point. One clone
# per transaction - the cost model statement-level rollback already runs
# on.
#
# A TYPED `ROLLBACK;` NEVER REACHES op_rollback. isql PREPARES AND
# EXECUTES the word as DSQL (probed: op_prepare/op_execute for it, and no
# op 31 anywhere on the wire), so transaction control has to be a PLAN,
# not just a wire op. Both paths are implemented; this gate drives the
# one clients actually use.
#
# THE DIFFERENTIAL: the same script runs against a copy of one database
# through fire-crab and through the engine, and the ENGINE then reads
# both files back - the tables must be identical.
#
#   qa/serve-real-rollback.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4424}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
SRC="$D/fc-rollback.fdb"
W=/tmp/fc-rb-w.fdb
R=/tmp/fc-rb-r.fdb

mkdir -p "$D"; rm -f "$SRC" "$W" "$R"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, S VARCHAR(10));
CREATE INDEX T_A ON T (A);
COMMIT;
INSERT INTO T VALUES (1, 10, 'x');
INSERT INTO T VALUES (2, 20, 'y');
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-rb.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$W" "$R"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

fail=0
dump() { printf 'SET HEADING OFF;\nSELECT ID, COALESCE(A,-9), COALESCE(S,%s) FROM T ORDER BY ID;\n' "'-'" |
         "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '; }
same() { # <label> <script>
    rm -f "$W" "$R"; cp "$SRC" "$W"; cp "$SRC" "$R"
    printf '%s\n' "$2" | "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/dev/null 2>&1
    printf '%s\n' "$2" | "$ISQL" -q -b -user "$U" -pas "$P" "$R" >/dev/null 2>&1
    ours=$(dump "$W"); theirs=$(dump "$R")
    if [ "$ours" = "$theirs" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$theirs]"; echo "     fc:     [$ours]"; fail=1
    fi
}

same "INSERT then ROLLBACK"        "INSERT INTO T VALUES (3, 30, 'z');
ROLLBACK;"
same "INSERT then COMMIT"          "INSERT INTO T VALUES (3, 30, 'z');
COMMIT;"
same "UPDATE then ROLLBACK"        "UPDATE T SET A = 99;
ROLLBACK;"
same "UPDATE then COMMIT"          "UPDATE T SET A = 99;
COMMIT;"
same "DELETE then ROLLBACK"        "DELETE FROM T;
ROLLBACK;"
same "DELETE then COMMIT"          "DELETE FROM T WHERE ID = 1;
COMMIT;"
same "two statements, both undone" "INSERT INTO T VALUES (3, 30, 'z');
INSERT INTO T VALUES (4, 40, 'w');
ROLLBACK;"
same "COMMIT then a rolled-back statement" "INSERT INTO T VALUES (3, 30, 'z');
COMMIT;
INSERT INTO T VALUES (4, 40, 'w');
ROLLBACK;"
same "mixed DML, all undone"       "INSERT INTO T VALUES (3, 30, 'z');
UPDATE T SET A = 1 WHERE ID = 1;
DELETE FROM T WHERE ID = 2;
ROLLBACK;"
same "mixed DML, all kept"         "INSERT INTO T VALUES (3, 30, 'z');
UPDATE T SET A = 1 WHERE ID = 1;
DELETE FROM T WHERE ID = 2;
COMMIT;"
same "ROLLBACK WORK"               "INSERT INTO T VALUES (3, 30, 'z');
ROLLBACK WORK;"
same "a rolled-back INSERT ... SELECT" "INSERT INTO T (ID, A) SELECT ID + 100, A FROM T;
ROLLBACK;"
same "rollback with nothing to undo" "ROLLBACK;"
same "an UPDATE with a SET expression, undone" "UPDATE T SET A = A + 5;
ROLLBACK;"

# --- teeth -------------------------------------------------------------
# 1. the rollback must really undo: without it the row would be there
rm -f "$W"; cp "$SRC" "$W"
printf 'INSERT INTO T VALUES (3, 30, %s);\nROLLBACK;\n' "'z'" |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/dev/null 2>&1
n=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ "$n" = "2" ]; then
    echo "OK   teeth: the rolled-back INSERT left the table at $n rows"
else
    echo "DIFF after rollback the table has $n rows, want 2"; fail=1
fi
# 2. ...and COMMIT on the same data really keeps it, so the pair differ
rm -f "$W"; cp "$SRC" "$W"
printf 'INSERT INTO T VALUES (3, 30, %s);\nCOMMIT;\n' "'z'" |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/dev/null 2>&1
m=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM T;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ "$m" = "3" ]; then
    echo "OK   teeth: COMMIT keeps it ($m rows) - the two really differ"
else
    echo "DIFF after commit the table has $m rows, want 3"; fail=1
fi
# 3. the file the rollback left behind must still be a valid database,
#    indexes included
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
if [ -z "$val" ]; then
    echo "OK   gfix -v -full accepts the file after commit/rollback"
else
    echo "DIFF gfix after commit/rollback: $val"; fail=1
fi
rm -f "$W"; cp "$SRC" "$W"
printf 'UPDATE T SET A = 77;\nROLLBACK;\n' |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$W" >/dev/null 2>&1
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$W" 2>&1 | tr -d ' \n')
plan=$(printf 'SET PLAN ON;\nSET HEADING OFF;\nSELECT ID FROM T WHERE A = 10;\n' |
       "$ISQL" -q -user "$U" -pas "$P" "$W" 2>&1 | tr -s ' \n' ' ')
if [ -z "$val" ]; then
    echo "OK   teeth: the rolled-back file is valid"
else
    echo "DIFF gfix after a rolled-back UPDATE: $val"; fail=1
fi
case "$plan" in
    *"T_A"*" 1 "*) echo "OK   teeth: the index still finds the ORIGINAL value after rollback" ;;
    *) echo "DIFF index lookup after rollback gave [$plan]"; fail=1 ;;
esac

exit $fail
