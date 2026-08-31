#!/bin/bash
# ONE PER-CONNECTION OBJECT ID SPACE.
#
# A prepared DSQL statement and a compiled BLR request are different
# KINDS of object that share ONE id space on the client. fbclient keeps a
# single untagged-union slot array per port for every kind
# (remote.h:1356, `Array<RemoteObject> port_objects`), and the engine
# allocates every id by scanning that one array for a free slot
# (remote.h:1600, `rem_port::get_id`) - so two kinds can never collide
# there. fire-crab minted request ids from their own counter starting at
# 5 while statements ran 3, 4, 5, ...
#
# WHAT THAT COST, measured: with `SET SQLDA_DISPLAY ON`, isql resolves a
# CHARACTER result's charset NAME by compiling a BLR request over
# RDB$CHARACTER_SETS. When that landed on id 5 while the third statement
# of the session still held id 5, the compile response overwrote
# `port_objects[5]`, and the next op_execute for statement 5 failed the
# client's own typed-handle check (`checkHandle`) INSIDE its encoder -
# after the input-BLR length had already been written (protocol.cpp:1910
# writes, :1922 looks up). The client abandoned its half-written packet:
#
#     Statement failed, SQLSTATE = 08006
#     Error writing data to the connection.
#     -send_packet/send
#
# ...and EVERY LATER STATEMENT on that connection returned 08006. A
# connection kill outranks a wrong answer here: it destroys work in
# flight, and inside a differential harness a dead tail can read as
# agreement between two servers.
#
# THE RULE IS ARITHMETIC, NOT POSITION. It is "the first op_compile of
# the connection lands on an id a live statement already holds".
# Statement ids climb 3, 4, 5 with each op_allocate_statement, so the
# THIRD statement collided with the fixed first request id 5. That is why
# the checks below sweep POSITIONS and also prepend statements that shift
# the arithmetic (SHOW TABLES burns a request id; a COMMIT frees a
# statement id) rather than testing "position 3" alone.
#
# WHICH CLIENT, AND WHY IT MUST BE isql: node-firebird NEVER sends
# op_compile / op_start_and_receive / op_receive - the legacy BLR request
# API - so it cannot reach this path at all. A driver-based gate here is
# green no matter what the server does.
#
#   qa/serve-real-objid.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4775}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-objid-a.fdb"; B="$D/fc-objid-b.fdb"
fail=0; ran=0
mkdir -p "$D"

mkdb() { rm -f "${1#*:}"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INTEGER, S VARCHAR(8));
COMMIT;
INSERT INTO T VALUES (1, 'one');
COMMIT;
EOF
}
mkdb "$A"; mkdb "127.0.0.1/$REAL:$B"
chmod 666 "$A" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-objid-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

run() { # <dsn> <script>
    printf '%b' "$2" | timeout 60 "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1
}
# Compare the two servers AND assert the connection lived. A dead
# connection yields a short answer, and "both short" must never pass -
# so every check requires the expected trailing value to be present.
both() { # <label> <script> <sentinel the LAST statement must produce>
    ran=$((ran + 1))
    local e c ediff cdiff
    e=$(run "127.0.0.1/$REAL:$B" "$2"); c=$(run "127.0.0.1/$PORT:$A" "$2")
    ediff=$(printf '%s' "$e" | grep -ac '08006')
    cdiff=$(printf '%s' "$c" | grep -ac '08006')
    if [ "$cdiff" != "0" ]; then
        echo "DIFF $1: fcwire returned $cdiff x 08006 - THE CONNECTION DIED"
        printf '%s\n' "$c" | grep -a -m3 -A2 '08006' | sed 's/^/     /'
        fail=1
        return
    fi
    if [ "$ediff" != "0" ]; then
        echo "DIFF $1: the ENGINE returned 08006 - the fixture or script is wrong, not the server"
        fail=1
        return
    fi
    # the last statement really ran on BOTH: a dead tail is not agreement
    if ! printf '%s' "$e" | grep -aq -- "$3" || ! printf '%s' "$c" | grep -aq -- "$3"; then
        echo "DIFF $1: the trailing sentinel '$3' is missing"
        echo "     engine tail: $(printf '%s' "$e" | tr -s ' \n' ' ' | tail -c 90)"
        echo "     fcwire tail: $(printf '%s' "$c" | tr -s ' \n' ' ' | tail -c 90)"
        fail=1
        return
    fi
    # and the describes agree, which is what SQLDA_DISPLAY is here for
    local ed cd
    ed=$(printf '%s' "$e" | grep -aE '^ *0[0-9]: sqltype' | sed 's/  */ /g' | paste -sd'|')
    cd=$(printf '%s' "$c" | grep -aE '^ *0[0-9]: sqltype' | sed 's/  */ /g' | paste -sd'|')
    if [ "$ed" = "$cd" ] && [ -n "$ed" ]; then
        echo "OK   $1 ($(printf '%s' "$ed" | tr '|' '\n' | grep -ac sqltype) describes, connection alive)"
    else
        echo "DIFF $1: the describes differ"
        echo "     engine: $(printf '%.100s' "$ed")"
        echo "     fcwire: $(printf '%.100s' "$cd")"
        fail=1
    fi
}

SD="SET SQLDA_DISPLAY ON;\n"
TAIL="SELECT 'ZZEND' FROM RDB\$DATABASE;\n"

echo "--- 1. the original repro, and the position sweep around it ----------"
both "char at position 3 (the repro)" \
    "${SD}SELECT 1 FROM RDB\$DATABASE;\nSELECT 2 FROM RDB\$DATABASE;\nSELECT 'abc' FROM RDB\$DATABASE;\n$TAIL" "ZZEND"
for n in 1 2 4 5 6; do
    pre=""
    i=1; while [ $i -lt $n ]; do pre="${pre}SELECT $i FROM RDB\$DATABASE;\n"; i=$((i+1)); done
    both "char at position $n" "${SD}${pre}SELECT 'abc' FROM RDB\$DATABASE;\n$TAIL" "ZZEND"
done

echo "--- 2. shapes that SHIFT the id arithmetic ---------------------------"
# SHOW TABLES compiles a request of its own, so it burns a request id and
# moves which statement position would have collided
both "SHOW TABLES then char at 3" \
    "${SD}SHOW TABLES;\nSELECT 1 FROM RDB\$DATABASE;\nSELECT 'abc' FROM RDB\$DATABASE;\n$TAIL" "ZZEND"
both "SHOW TABLES then char at 4" \
    "${SD}SHOW TABLES;\nSELECT 1 FROM RDB\$DATABASE;\nSELECT 2 FROM RDB\$DATABASE;\nSELECT 'abc' FROM RDB\$DATABASE;\n$TAIL" "ZZEND"
# a COMMIT consumes an id; a COMMIT after two statements frees one
both "COMMIT first, char at 3" \
    "${SD}COMMIT;\nSELECT 1 FROM RDB\$DATABASE;\nSELECT 'abc' FROM RDB\$DATABASE;\n$TAIL" "ZZEND"
both "COMMIT in the middle" \
    "${SD}SELECT 1 FROM RDB\$DATABASE;\nSELECT 2 FROM RDB\$DATABASE;\nCOMMIT;\nSELECT 'abc' FROM RDB\$DATABASE;\n$TAIL" "ZZEND"

echo "--- 3. a character COLUMN, not only a literal ------------------------"
both "char column at position 3" \
    "${SD}SELECT 1 FROM RDB\$DATABASE;\nSELECT 2 FROM RDB\$DATABASE;\nSELECT S FROM T;\n$TAIL" "ZZEND"
# A CATALOG char column triggers the same walk, and is worth covering
# because its charset comes from metadata rather than from a table
# definition. Its DESCRIBE is not compared here: fire-crab announces
# catalog char columns as charset 3 SYSTEM.UNICODE_FSS where the engine
# announces 4 SYSTEM.UTF8 - a separate, PRE-EXISTING divergence (verified
# against the binary from before this gate existed) recorded in the
# roadmap. Encoding an unrelated bug as this gate's pass/fail would make
# it fail for the wrong reason and stop anyone trusting it.
alive_only() { # <label> <script> <sentinel>
    ran=$((ran + 1))
    local e c
    e=$(run "127.0.0.1/$REAL:$B" "$2"); c=$(run "127.0.0.1/$PORT:$A" "$2")
    if printf '%s' "$c" | grep -aq '08006'; then
        echo "DIFF $1: fcwire returned 08006 - THE CONNECTION DIED"; fail=1
    elif ! printf '%s' "$c" | grep -aq -- "$3" || ! printf '%s' "$e" | grep -aq -- "$3"; then
        echo "DIFF $1: the trailing sentinel '$3' is missing on one side"; fail=1
    else
        echo "OK   $1 (connection alive, describes not compared - see note)"
    fi
}
alive_only "catalog char column at 3" \
    "${SD}SELECT 1 FROM RDB\$DATABASE;\nSELECT 2 FROM RDB\$DATABASE;\nSELECT RDB\$CHARACTER_SET_NAME FROM RDB\$CHARACTER_SETS ROWS 1;\n$TAIL" "ZZEND"

echo "--- 4. length: the id space must stay coherent over a long session ---"
LONG="$SD"
i=1; while [ $i -le 20 ]; do
    LONG="${LONG}SELECT $i FROM RDB\$DATABASE;\nSELECT 'x$i' FROM RDB\$DATABASE;\n"
    i=$((i + 1))
done
both "40 statements, alternating types" "${LONG}$TAIL" "ZZEND"

echo "--- 5. the control: SQLDA_DISPLAY off never compiles a request -------"
both "no SQLDA_DISPLAY, char at 3 (control)" \
    "SET SQLDA_DISPLAY ON;\nSELECT 1 FROM RDB\$DATABASE;\nSET SQLDA_DISPLAY OFF;\nSELECT 2 FROM RDB\$DATABASE;\nSELECT 'abc' FROM RDB\$DATABASE;\nSET SQLDA_DISPLAY ON;\n$TAIL" "ZZEND"

echo "----------------------------------------------------------------------"
echo "ran $ran checks"
[ "$ran" -ge 14 ] || { echo "FAIL only $ran checks ran"; fail=1; }
[ $fail -eq 0 ] && echo "PASS $ran checks" || echo "FAIL"
exit $fail
