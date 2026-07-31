#!/bin/bash
# SEVERAL STATEMENTS OPEN AT ONCE on one connection.
#
# fire-crab used to answer every op_allocate_statement with the same
# handle (3) and keep ONE working set per connection, so the second
# prepare silently clobbered the first: a fetch on statement A served
# statement B's rows. A client cannot parse another statement's row into
# its output buffer, so it declares the connection corrupt and shuts it
# down - and libfbclient then SEGFAULTS in its own teardown. That is what
# killed whole firebird-qa runs (tests/bugs/core_3959_test.py alone
# reproduced it in 2.3s), and quieter but worse, a client whose two
# statements happened to share a row shape would have been handed the
# WRONG ROWS with no error at all.
#
# THE DIFFERENTIAL: the same client script runs against the engine and
# against fire-crab and must print the same rows - interleaving two
# cursors so that a single-slot server cannot get it right by accident.
# op_info_transaction (42) is exercised too: it used to fall into the
# unhandled-op arm, which ENDS the connection - the same segfault.
#
#   qa/serve-real-multistmt.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4312}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-multistmt.fdb"
PY="${FC_PY:-/tmp/fbhandson/qa/venv/bin/python}"

command -v "$PY" >/dev/null 2>&1 || [ -x "$PY" ] || { echo "SKIP firebird-driver venv not found"; exit 0; }

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE A (ID INTEGER, V INTEGER);
CREATE TABLE B (ID INTEGER, V INTEGER);
COMMIT;
INSERT INTO A VALUES (1, 11);
INSERT INTO A VALUES (2, 12);
INSERT INTO A VALUES (3, 13);
INSERT INTO B VALUES (1, 91);
INSERT INTO B VALUES (2, 92);
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-multistmt.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB" /tmp/fc-multistmt.py' EXIT
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

cat > /tmp/fc-multistmt.py <<'PYEOF'
import sys
from firebird.driver import connect, driver_config, tpb, Isolation
port, dbfile = sys.argv[1], sys.argv[2]
# 'local' runs the same script through the ENGINE's own client on the
# file directly (the engine daemon cannot open a /tmp scratch file over
# TCP; isql reaches these files the same local way)
if port == 'local':
    driver_config.register_database('md', f"[md]\ndatabase = {dbfile}\n"
                                          f"user = SYSDBA\npassword = masterkey\n")
else:
    driver_config.register_server('m', f"[m]\nhost = 127.0.0.1\nport = {port}\n"
                                       f"user = SYSDBA\npassword = masterkey\n")
    driver_config.register_database('md', f"[md]\nserver = m\ndatabase = {dbfile}\n")
con = connect('md')
t1 = con.transaction_manager(tpb(isolation=Isolation.READ_COMMITTED_RECORD_VERSION))
t2 = con.transaction_manager(tpb(isolation=Isolation.READ_COMMITTED_RECORD_VERSION))
c1, c2 = t1.cursor(), t2.cursor()
# two cursors open AT THE SAME TIME, fetched INTERLEAVED - a server with
# one statement slot cannot get this right
c1.execute("select ID, V from A order by ID")
c2.execute("select ID, V from B order by ID")
print("a1", c1.fetchone())
print("b1", c2.fetchone())
print("a2", c1.fetchone())
print("b2", c2.fetchone())
print("a3", c1.fetchone())
print("b3", c2.fetchone())
# counts over different tables, still interleaved
c1.execute("select count(*) from A")
c2.execute("select count(*) from B")
print("ca", c1.fetchall())
print("cb", c2.fetchall())
# a third statement while the first two are still open
c3 = t1.cursor()
c3.execute("select max(V) from A")
print("mx", c3.fetchall())
print("again-a", c1.fetchall())
# op_info_transaction: the id must be a plain positive integer
print("tra_id_positive", t1.info.id > 0)
con.close()
print("closed cleanly")
PYEOF

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

eng=$("$PY" /tmp/fc-multistmt.py local "$DB" 2>&1)
fc=$("$PY" /tmp/fc-multistmt.py "$PORT" "$DB" 2>&1)

# line-by-line, so a divergence names itself
n=1
while [ $n -le 13 ]; do
    e=$(printf '%s\n' "$eng" | sed -n "${n}p")
    f=$(printf '%s\n' "$fc" | sed -n "${n}p")
    lbl=$(printf '%s' "$e" | cut -d' ' -f1)
    check "line $n [$lbl] matches the engine" "$f" "$e"
    n=$((n + 1))
done

# teeth 1: the run must not have died - a single-slot server broke the
# connection here, and the client segfaulted afterwards
case "$fc" in
    *"closed cleanly"*) echo "OK   teeth: the connection survived two open statements" ;;
    *) echo "DIFF the connection did not survive: $fc"; fail=1 ;;
esac

# teeth 2: the interleaved rows must actually DIFFER between the two
# cursors (a vacuous pass would be both sides printing the same row)
a1=$(printf '%s\n' "$fc" | sed -n '1p')
b1=$(printf '%s\n' "$fc" | sed -n '2p')
if [ "${a1#a1 }" != "${b1#b1 }" ]; then
    echo "OK   teeth: cursor A and cursor B return DIFFERENT rows ($a1 vs $b1)"
else
    echo "DIFF both cursors returned the same row - statements are sharing state"; fail=1
fi

# teeth 3: the crashing qa test itself, if that checkout is present
QA=/tmp/fbhandson/qa
# the plugin needs the alias config this server was NOT started with, so
# only attempt it when the whole external rig is in place
if [ -f "$QA/firebird-qa/tests/bugs/core_3959_test.py" ] && [ -x "$QA/venv/bin/pytest" ] \
   && [ -n "${FC_DATABASES_CONF:-}" ]; then
    sed "s/^port = .*/port = $PORT/" "$QA/fc-driver.conf" > /tmp/fc-ms-driver.conf 2>/dev/null
    (cd "$QA" && timeout 300 ./venv/bin/pytest -p firebird.qa.plugin --server fc \
        --driver-config /tmp/fc-ms-driver.conf -q --timeout=20 --timeout-method=signal \
        -p no:cacheprovider firebird-qa/tests/bugs/core_3959_test.py >/tmp/fc-ms-qa.log 2>&1)
    rc=$?
    case $rc in
        # 139 = SIGSEGV: the crash this slice removes
        13[0-9]|1[4-9][0-9]) echo "DIFF core_3959_test.py still crashes the client (rc=$rc)"; fail=1 ;;
        0|1) echo "OK   teeth: core_3959_test.py runs without crashing the client (rc=$rc)" ;;
        # anything else is the harness, not the crash - do not claim a pass
        *) echo "SKIP core_3959 check inconclusive (pytest rc=$rc, see /tmp/fc-ms-qa.log)" ;;
    esac
else
    echo "SKIP firebird-qa checkout not present for the core_3959 crash check"
fi

exit $fail
