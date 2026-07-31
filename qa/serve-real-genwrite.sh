#!/bin/bash
# The server WRITES GENERATOR VALUES into the generator page. Two
# statements set a generator: SET GENERATOR <name> TO <n> stores n, and
# ALTER SEQUENCE <name> RESTART WITH <n> stores n - increment (so the
# next GEN_ID/NEXT VALUE FOR yields n). fire-crab locates the generator's
# slot (id % gensPerPage on the pag_ids page whose gpg_sequence is
# id / gensPerPage) and writes the native little-endian SINT64.
#
# The oracle is the REAL ENGINE. The SAME write statements are applied by
# fire-crab to one copy of a clean database and by the C++ engine to a
# second copy; afterwards each generator's stored value must be identical
# read from the fire-crab-written file and the engine-written file. The
# read is done two ways: by the engine's isql (SHOW GENERATORS reads the
# actual page value through GEN_ID) on both files, and back through
# fire-crab (SHOW GENERATORS via fcwire on its own written file) - so the
# write and the read-back both prove out. gfix must find nothing wrong
# with the file fire-crab wrote, and a SET on a nonexistent generator
# must raise an error, never a silent no-op.
#
#   qa/serve-real-genwrite.sh [port]
#
# Builds its own scratch database (three generators, one with a non-unit
# increment so RESTART WITH exercises the n - increment arithmetic).

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4098}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/genwrite_src.fdb"
WORK="/tmp/fc-genwrite-work.fdb"; REF="/tmp/fc-genwrite-ref.fdb"

mkdir -p "$DIR"
rm -f "$SRC" "$WORK" "$REF"

# --- build the scratch database: three generators -----------------------
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE SEQUENCE SEQ_A;
CREATE SEQUENCE SEQ_INC INCREMENT BY 5;
CREATE GENERATOR GEN_C;
COMMIT;
EOF
cp "$SRC" "$WORK"
cp "$SRC" "$REF"

# the write statements, applied identically to both copies
WRITES="SET GENERATOR GEN_C TO 4242;
ALTER SEQUENCE SEQ_A RESTART WITH 7;
ALTER SEQUENCE SEQ_INC RESTART WITH 100;
SET GENERATOR GEN_C TO 999;
SET GENERATOR SEQ_A TO -3;
COMMIT;"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-genwrite.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF"' EXIT
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
sleep 0.5

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

# apply the writes through fire-crab (to WORK). isql's own COMMIT chatter
# is irrelevant; what matters is the stored values afterwards. Retry the
# whole session on a transient cold-start connection error.
apply_fc() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(timeout -s KILL 15 "$ISQL" -q -b -user "$U" -pas "$P" \
              "localhost/$PORT:$WORK" 2>&1 <<EOF
$WRITES
EOF
)
        case "$r" in
            *08006*|*28000*|*"Unable to complete"*|*"connection rejected"*)
                cp "$SRC" "$WORK"; n=$((n + 1)); sleep 0.3 ;;
            *) return 0 ;;
        esac
    done
    return 1
}
apply_fc || { echo "FAIL could not apply writes through fire-crab"; exit 1; }

# apply the SAME writes through the engine (to REF)
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<EOF
$WRITES
EOF

fail=0
compare() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     engine: $2"
        echo "     fc:     $3"
        fail=1
    fi
}

# 1) the engine reads identical stored values from the fire-crab-written
#    file and the engine-written file (the pure write oracle)
en_ref=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<EOF | strip
SHOW GENERATORS;
EOF
)
en_work=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<EOF | strip
SHOW GENERATORS;
EOF
)
compare "engine reads fc-written == engine-written" "$en_ref" "$en_work"

# spot the exact expected values (non-vacuity: assert the numbers moved)
vals=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<EOF | strip
SELECT GEN_ID(GEN_C,0)||'/'||GEN_ID(SEQ_A,0)||'/'||GEN_ID(SEQ_INC,0) FROM RDB\$DATABASE;
EOF
)
# GEN_C: last SET wins (999); SEQ_A: SET TO -3 after RESTART 7 (-3);
# SEQ_INC: RESTART WITH 100, increment 5 -> 95
compare "stored values GEN_C/SEQ_A/SEQ_INC" "999/-3/95" "$(echo "$vals" | grep -oE '[-0-9]+/[-0-9]+/[-0-9]+')"

# 2) read the values back THROUGH fire-crab (SHOW GENERATORS via fcwire on
#    its own written file) - the write and read-back both prove out.
#    Retry on the transient cold-start connection/auth race.
fc_show_cmd() {
    n=0
    while [ $n -lt 8 ]; do
        r=$(timeout -s KILL 15 "$ISQL" -q -b -user "$U" -pas "$P" \
              "localhost/$PORT:$WORK" 2>&1 <<EOF
SHOW GENERATORS;
EOF
)
        case "$r" in
            *08006*|*28000*|*"Unable to complete"*|*"connection rejected"*|"")
                n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r"; return ;;
        esac
    done
    printf '%s\n' "$r"
}
fc_show=$(fc_show_cmd | strip)
compare "fire-crab reads back its own writes" "$en_ref" "$fc_show"

# 3) gfix finds nothing wrong with the file fire-crab wrote
gfix_out=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1)
compare "gfix -v -full clean after generator writes" "" "$(echo "$gfix_out" | strip)"

# 4) a SET on a nonexistent generator must raise an error, not silently
#    do nothing (isql prints the SQLSTATE/error text)
err=$(timeout -s KILL 15 "$ISQL" -q -b -user "$U" -pas "$P" \
        "localhost/$PORT:$WORK" 2>&1 <<EOF
SET GENERATOR NO_SUCH_GEN TO 5;
EOF
)
case "$err" in
    *error*|*Error*|*failed*|*SQLSTATE*)
        echo "OK   SET on nonexistent generator raises an error" ;;
    *)
        echo "DIFF SET on nonexistent generator raises an error"
        echo "     got: $err"; fail=1 ;;
esac

exit $fail
