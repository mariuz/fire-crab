#!/bin/bash
# AN ATTACH THAT CANNOT OPEN THE DATABASE SAYS SO, AT ATTACH TIME.
#
# fire-crab answers SUCCESS to an attach naming a file that does not
# exist (a `None` from load_database falls through to the fixed-answer
# path); the first statement then fails with `HY000 invalid transaction
# handle` and no file is ever created. The engine refuses at attach with
# `08001 / I/O error during "open" operation / No such file or
# directory`.
#
# It is not only a wrong message. gbak probes for a target's existence
# BY ATTACHING, so an attach that always succeeds tells gbak every path
# is occupied: `gbak -c` and `gbak -r` into a fresh path are impossible
# through fire-crab, which reports `database ... already exists. To
# replace it, use the -REP switch` about a file that is not there.
#
# Measured on the engine 2026-09-03, three distinct failures:
#   missing path   08001  I/O error during "open" operation for file "<p>"
#                         -Error while trying to open file
#                         -No such file or directory
#   not a database HY000  file <p> is not a valid database
#   a directory    08001  I/O error during "read" operation for file "<p>"
#                         -Error while trying to read from file
#                         -Is a directory
#
# NOT a defect, and deliberately asserted here so nobody "fixes" it: a
# `-rep` restore DROPS THE TARGET FIRST, so a restore that fails part
# way leaves neither the old database nor a complete new one. The ENGINE
# does this too - measured with a byte-corrupted backup, the target file
# survives at its original size with its table gone (-204). What a
# server may NOT do is crash its client: fire-crab's `gbak -r -rep`
# SIGSEGVs gbak (rc=139).
#
#   qa/serve-real-attach.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4176}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG="/tmp/fc-serve-attach-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

SRC="$D/fc-att-src-$PORT.fdb"; FBK="$D/fc-att-$PORT.fbk"
mk_src() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE 'localhost:$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE SRC (ID INTEGER NOT NULL PRIMARY KEY, T VARCHAR(10));
COMMIT;
INSERT INTO SRC VALUES (1, 'src'); COMMIT;
EOF
    chmod 666 "$1" 2>/dev/null; return 0; }
mk_src "$SRC" || { echo "FAIL scratch source"; exit 1; }
"$GBAK" -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$SRC" "$FBK" >/dev/null 2>&1 || { echo "FAIL backup"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$SRC" "$FBK" "$D"/fc-att-*-'"$PORT"'.fdb' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# gbak echoes the CONNECTION STRING back, which differs by port and by
# side-specific filename by construction - fold both to a fixed token so
# the comparison is about what gbak SAYS, not which server it said it to
gnorm() { norm | sed -e "s#127\.0\.0\.1/[0-9]*:#<conn>:#g" -e "s#$D/fc-att-[a-z]*-\(engine\|crab\)-$PORT\.fdb#<target>#g"; }
# the same SQL to each server against ITS OWN path, comparing what the
# CLIENT is told - the message is the whole point of this gate
attach_both() {
    e=$(printf 'SET LIST ON;\n%s\n' "$3" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$2" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$3" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$2" 2>&1 | norm)
    check "$1" "$c" "$e"
}

# ---- 1. the three ways an attach cannot open a database ----------------------
MISS="$D/fc-att-nosuch-$PORT.fdb"; rm -f "$MISS"
attach_both "attach to a path that does not exist" "$MISS" "SELECT 1 X FROM RDB\$DATABASE;"
ran=$((ran + 1))
if [ ! -e "$MISS" ]; then echo "OK   ... and no file was created by the failed attach"
else echo "DIFF a failed attach CREATED $MISS"; fail=1; fi

NOTDB="$D/fc-att-notadb-$PORT.fdb"; echo "not a database at all" > "$NOTDB"; chmod 666 "$NOTDB"
attach_both "attach to a file that is not a database" "$NOTDB" "SELECT 1 X FROM RDB\$DATABASE;"
attach_both "attach to a directory" "$D" "SELECT 1 X FROM RDB\$DATABASE;"

# ---- 2. gbak into a FRESH path ------------------------------------------------
# gbak probes for the target by ATTACHING, so this is the attach law with
# a real client on top of it
for side in engine crab; do
    T="$D/fc-att-fresh-$side-$PORT.fdb"; rm -f "$T"
    if [ "$side" = engine ]; then CONN="127.0.0.1/$REAL:$T"; else CONN="127.0.0.1/$PORT:$T"; fi
    out=$("$GBAK" -c -user "$U" -pas "$P" "$FBK" "$CONN" 2>&1); rc=$?
    eval "R_$side=\$rc"; eval "O_$side=\$(printf '%s' \"\$out\" | gnorm)"
    chmod 666 "$T" 2>/dev/null
    eval "E_$side=\$([ -f \"\$T\" ] && echo YES || echo NO)"
done
check "gbak -c into a fresh path: the client's exit status" "$R_crab" "$R_engine"
check "gbak -c into a fresh path: what the client is told" "$O_crab" "$O_engine"
check "gbak -c into a fresh path: the database exists afterwards" "$E_crab" "$E_engine"
ran=$((ran + 1))
if [ "$R_crab" != 139 ]; then echo "OK   ... and the client did not SIGSEGV"
else echo "DIFF gbak died with SIGSEGV (rc=139) against fire-crab"; fail=1; fi

# ---- 3. gbak -c onto an EXISTING database: refuse, and leave it alone ---------
for side in engine crab; do
    T="$D/fc-att-occupied-$side-$PORT.fdb"; rm -f "$T"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE 'localhost:$T' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE KEEPME (ID INTEGER); COMMIT;
INSERT INTO KEEPME VALUES (7); COMMIT;
EOF
    chmod 666 "$T" 2>/dev/null
    if [ "$side" = engine ]; then CONN="127.0.0.1/$REAL:$T"; else CONN="127.0.0.1/$PORT:$T"; fi
    out=$("$GBAK" -c -user "$U" -pas "$P" "$FBK" "$CONN" 2>&1); rc=$?
    eval "R2_$side=\$rc"; eval "O2_$side=\$(printf '%s' \"\$out\" | gnorm)"
    # the ENGINE is the judge of what survived, on both files
    chmod 666 "$T" 2>/dev/null
    eval "K_$side=\$(printf 'SET LIST ON; SELECT COUNT(*) N FROM KEEPME;\n' | \"\$ISQL\" -q -user \"\$U\" -pas \"\$P\" \"127.0.0.1/\$REAL:\$T\" 2>&1 | norm)"
done
check "gbak -c onto an existing database: the client's exit status" "$R2_crab" "$R2_engine"
check "gbak -c onto an existing database: what the client is told" "$O2_crab" "$O2_engine"
check "gbak -c onto an existing database: the target is left INTACT" "$K_crab" "$K_engine"
ran=$((ran + 1))
if [ "$R2_crab" != 139 ]; then echo "OK   ... and the client did not SIGSEGV"
else echo "DIFF gbak died with SIGSEGV (rc=139) against fire-crab"; fail=1; fi

# ---- 4. gbak -r -rep onto an existing database: replace -----------------------
for side in engine crab; do
    T="$D/fc-att-rep-$side-$PORT.fdb"; rm -f "$T"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE 'localhost:$T' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE OLDONE (ID INTEGER); COMMIT;
INSERT INTO OLDONE VALUES (42); COMMIT;
EOF
    chmod 666 "$T" 2>/dev/null
    if [ "$side" = engine ]; then CONN="127.0.0.1/$REAL:$T"; else CONN="127.0.0.1/$PORT:$T"; fi
    out=$("$GBAK" -r -rep -user "$U" -pas "$P" "$FBK" "$CONN" 2>&1); rc=$?
    eval "R3_$side=\$rc"; eval "O3_$side=\$(printf '%s' \"\$out\" | gnorm)"
    chmod 666 "$T" 2>/dev/null
    eval "S3_$side=\$(printf 'SET LIST ON; SELECT ID, T FROM SRC ORDER BY ID;\n' | \"\$ISQL\" -q -user \"\$U\" -pas \"\$P\" \"127.0.0.1/\$REAL:\$T\" 2>&1 | norm)"
done
check "gbak -r -rep onto an existing database: the client's exit status" "$R3_crab" "$R3_engine"
check "gbak -r -rep onto an existing database: what the client is told" "$O3_crab" "$O3_engine"
check "gbak -r -rep: the ENGINE reads the restored rows out of both files" "$S3_crab" "$S3_engine"
ran=$((ran + 1))
if [ "$R3_crab" != 139 ]; then echo "OK   ... and the client did not SIGSEGV"
else echo "DIFF gbak died with SIGSEGV (rc=139) against fire-crab"; fail=1; fi

# ---- 5. the server survived all of it ----------------------------------------
ran=$((ran + 1))
if kill -0 $srv 2>/dev/null; then echo "OK   fcwire is still running at the end"
else echo "DIFF fcwire died during the run"; fail=1; fi
ran=$((ran + 1))
if ! grep -aq 'panicked at' "$LOG"; then echo "OK   no panic in the server log"
else echo "DIFF panic in $LOG:"; grep -a -m2 'panicked at' "$LOG"; fail=1; fi

echo "ran $ran checks"
exit $fail
