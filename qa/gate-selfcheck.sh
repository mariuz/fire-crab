#!/bin/bash
# The gates check the server. This checks the GATES.
#
# Every differential here works the same way: start fcwire on a port,
# wait for the port to answer, then run checks against it. The waiting is
# done with `nc -z`, which answers "SOMETHING is listening" - and that is
# not the question. If the port was already in use, fcwire exits at bind
# with "Address already in use" and `nc` succeeds anyway, against the
# OTHER server. Every check then runs against that server, and since the
# other server on this machine is the real Firebird engine, a twin gate
# compares the engine with itself and passes. Perfectly. Every time.
#
# That is the worst failure a differential has: not a wrong answer, but a
# green run that measured nothing. Eleven gates defaulted to port 3050 -
# the engine's own - so running any of them without an explicit port
# argument did exactly this, and one of them was read as evidence of a
# bug in fire-crab that did not exist.
#
# Four properties, and the last is the one with teeth:
#
#   1. No gate's OWN server defaults to the engine's port.
#   2. Every fcwire start is followed by a liveness assertion, so a
#      failed bind is fatal rather than invisible.
#   3. Every gate PARSES under the interpreter its own shebang names.
#   4. A gate whose port is OCCUPIED actually FAILS. A static scan can be
#      satisfied by a guard that does not work; this one runs a real gate
#      with a squatter on its port and requires a non-zero exit.
#
#   qa/gate-selfcheck.sh
#
# Static checks need nothing; the behavioural one needs the fcwire binary
# and is skipped (loudly) without it.

set -u
cd "$(dirname "$0")/.." || exit 1
FCWIRE="${FCWIRE:-./target/release/fcwire}"
REAL_PORT="${FC_REAL_PORT:-3050}"
fail=0
ran=0

# every gate that starts a server - EXCEPT this file, which only names
# the pattern it is checking for
gates() { grep -l 'FCWIRE" serve' qa/*.sh | grep -v 'gate-selfcheck.sh'; }

# --- 1. nobody's own server defaults to the engine's port --------------
ran=$((ran + 1))
bad=$(grep -n "PORT=\"\${[0-9]:-$REAL_PORT}\"" $(gates) 2>/dev/null | grep -v 'REAL\|FC_REAL')
if [ -z "$bad" ]; then
    echo "OK   no gate's own server defaults to the engine's port ($REAL_PORT)"
else
    echo "DIFF a gate defaults to the engine's port - it would compare the engine with itself:"
    printf '%s\n' "$bad" | sed 's/^/     /'
    fail=1
fi

# --- 2. every server start is followed by a liveness assertion ---------
# counted per FILE: a gate that starts two servers needs two guards
ran=$((ran + 1))
missing=$(for f in $(gates); do
    starts=$(grep -c 'FCWIRE" serve' "$f")
    guards=$(grep -c 'kill -0 \$srv' "$f")
    [ "$starts" -le "$guards" ] || echo "$f: $starts starts, $guards guards"
done)
if [ -z "$missing" ]; then
    echo "OK   every fcwire start is guarded by a liveness assertion ($(gates | wc -l) gates)"
else
    echo "DIFF gates that start a server without asserting it is running:"
    printf '%s\n' "$missing" | sed 's/^/     /'
    fail=1
fi

# --- 3. default ports are distinct -------------------------------------
# not fatal to correctness, but two gates sharing a default is the same
# collision waiting for whoever runs them concurrently
ran=$((ran + 1))
dup=$(grep -ho 'PORT="${[0-9]:-[0-9]*}"' qa/*.sh | grep -o ':-[0-9]*' | tr -d ':-' | sort | uniq -d)
if [ -z "$dup" ]; then
    echo "OK   every gate's default port is its own"
else
    echo "DIFF gates share a default port:"
    for p in $dup; do
        echo "     $p: $(grep -l "PORT=\"\${[0-9]:-$p}\"" qa/*.sh | tr '\n' ' ')"
    done
    fail=1
fi

# --- 4. every gate PARSES under the interpreter it names ---------------
# Five gates carried a #!/bin/sh shebang while using bash-only syntax, so
# running them as written failed at parse - a gate you cannot invoke the
# way its own header says is the same lost coverage by another route.
ran=$((ran + 1))
unparsable=$(for f in qa/*.sh; do
    sh=$(head -1 "$f" | grep -q bash && echo bash || echo sh)
    $sh -n "$f" 2>/dev/null || echo "$f (declares $sh)"
done)
if [ -z "$unparsable" ]; then
    echo "OK   every gate parses under its own shebang ($(ls qa/*.sh | wc -l) files)"
else
    echo "DIFF gates that do not parse under the interpreter they name:"
    printf '%s\n' "$unparsable" | sed 's/^/     /'
    fail=1
fi

# --- 5. the teeth: an occupied port must make a gate FAIL --------------
# A guard that is present and does not work looks exactly like a guard
# that works, until the day it matters. So: squat on the port, run a real
# gate, and require a non-zero exit and a spoken reason.
ran=$((ran + 1))
if [ ! -x "$FCWIRE" ]; then
    echo "SKIP the behavioural check needs $FCWIRE (build it with cargo build --release)"
else
    SQUAT=4599
    # the squatter is another fcwire: it holds the port and answers, which
    # is precisely the situation that fooled the readiness probe
    "$FCWIRE" serve "127.0.0.1:$SQUAT" SYSDBA masterkey >/tmp/fc-selfcheck-squat.log 2>&1 &
    squat=$!
    trap 'kill $squat 2>/dev/null' EXIT
    i=0; while [ $i -lt 30 ]; do
        command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$SQUAT" 2>/dev/null && break
        i=$((i + 1)); sleep 0.1
    done
    if ! kill -0 $squat 2>/dev/null; then
        echo "SKIP could not hold port $SQUAT to test with"
    else
        out=$(timeout 300 qa/serve-real-viewjoin.sh "$SQUAT" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "already in use"; then
            echo "OK   a gate whose port is occupied FAILS and says why (rc=$rc)"
        else
            echo "DIFF a gate ran to completion with another server on its port (rc=$rc)"
            printf '%s\n' "$out" | head -4 | sed 's/^/     /'
            fail=1
        fi
    fi
    kill $squat 2>/dev/null
fi

if [ "$ran" -lt 5 ]; then
    echo "DIFF only $ran checks ran (expected 5)"
    fail=1
fi
exit $fail
