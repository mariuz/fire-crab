#!/bin/bash
# SERVICES API + op_create - the two wire operations the firebird-qa
# pytest plugin's session bootstrap needs before it can talk to fire-crab
# at all. Both are exercised through the reference python firebird-driver
# (the client the suite is built on):
#
#   1. connect_server() -> op_service_attach + op_service_info: the
#      plugin's pytest_configure reads the server version, home and lock
#      directories, security database and architecture this way. The
#      response byte format was captured from the real Firebird server
#      ([tag][u16 len][string], SvcInfoCode 55/56/58/59/60) and mirrored.
#   2. create_database() -> op_create: fire-crab does not synthesise a
#      valid ODS from nothing (a separate large conversion); it
#      MATERIALISES an empty database with the engine (isql CREATE
#      DATABASE), then serves and mutates it - the same real-file basis
#      every gate uses. The driver then runs CREATE TABLE / INSERT /
#      SELECT against the fresh database, and the ENGINE validates the
#      file fire-crab wrote into it.
#
# This does NOT run the full firebird-qa suite: past these two, the
# plugin bootstrap attaches to the `employee` sample database and probes
# MON$ATTACHMENTS and the ODS version to detect the server architecture
# - monitoring tables and sample-database emulation that remain ahead.
# What this gate locks in is that the session-bootstrap wire operations
# work with the real driver.
#
#   FCPY=/path/to/venv/bin/python qa/serve-real-services.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
FCPY="${FCPY:-}"
PORT="${1:-4088}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
NEWDB="/tmp/fc-services-new.fdb"

if [ -z "$FCPY" ] || ! "$FCPY" -c "import firebird.driver" 2>/dev/null; then
    echo "SKIP python firebird-driver not available (set FCPY to a venv python)"
    exit 0
fi

rm -f "$NEWDB"
# the server materialises op_create databases with this isql
FC_ISQL="$ISQL" "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-services.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$NEWDB"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

FC_PORT="$PORT" FC_U="$U" FC_P="$P" FC_NEWDB="$NEWDB" "$FCPY" - <<'PYEOF'
import os, sys
from firebird.driver import connect_server, create_database, driver_config
srv = driver_config.register_server('fc')
srv.host.value = '127.0.0.1'; srv.port.value = os.environ['FC_PORT']
srv.user.value = os.environ['FC_U']; srv.password.value = os.environ['FC_P']
db = driver_config.register_database('newdb')
db.server.value = 'fc'; db.database.value = os.environ['FC_NEWDB']

fail = 0
def check(label, ok):
    global fail
    if ok: print(f"OK   {label}")
    else: print(f"DIFF {label}"); fail = 1

# 1. the Services manager (op_service_attach + op_service_info)
with connect_server('fc', user=os.environ['FC_U'], password=os.environ['FC_P']) as s:
    v = s.info.version
    check(f"connect_server reads version ({v})", v.count('.') >= 2)
    check("home directory", s.info.home_directory.startswith('/'))
    check("lock directory", s.info.lock_directory.startswith('/'))
    check("security database", s.info.security_database.endswith('.fdb'))
    check("architecture", 'Firebird' in s.info.architecture)

# 2. op_create: the driver creates a database, then uses it
con = create_database('newdb', user=os.environ['FC_U'], password=os.environ['FC_P'])
cur = con.cursor()
cur.execute("CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(20))"); con.commit()
cur.execute("INSERT INTO T VALUES (?, ?)", (1, 'created')); con.commit()
cur.execute("INSERT INTO T VALUES (?, ?)", (2, 'second')); con.commit()
cur.execute("SELECT ID, NAME FROM T ORDER BY ID")
check("driver creates + populates a database", cur.fetchall() == [(1, 'created'), (2, 'second')])
try:
    cur.execute("INSERT INTO T VALUES (?, ?)", (1, 'dup')); con.commit()
    check("PK enforced in the created db", False)
except Exception:
    con.rollback(); check("PK enforced in the created db", True)

# 3. the op_info_database items the firebird-qa plugin bootstrap reads:
# con.info.name (DB_ID), .id (ATTACHMENT_ID), .ods_version, and two
# connections get distinct attachment ids
check("con.info.name is the database path", con.info.name == os.environ['FC_NEWDB'])
check("con.info.id is a positive int", isinstance(con.info.id, int) and con.info.id > 0)
check("con.info.ods_version", con.info.ods_version >= 13)
con2 = create_database('newdb', user=os.environ['FC_U'], password=os.environ['FC_P']) if False else None
con_b = None
from firebird.driver import connect
con_b = connect('newdb', user=os.environ['FC_U'], password=os.environ['FC_P'])
check("distinct attachment ids across connections", con.info.id != con_b.info.id)

# 4. MON$ virtual tables report as empty - the plugin's architecture
# probe (an aggregate over MON$ATTACHMENTS) returns one all-NULL row
cur_b = con_b.cursor()
cur_b.execute("""select count(distinct a.mon$server_pid), min(a.mon$remote_protocol),
    max(iif(a.mon$remote_protocol is null, 1, 0)) from mon$attachments a
    where a.mon$attachment_id in (%d, %d)""" % (con.info.id, con_b.info.id))
row = cur_b.fetchone()
check("MON$ architecture query returns one all-NULL row", row == (None, None, None))
con_b.close()

# 5. op_drop_database: the SAME operation firebird-qa's per-test
# teardown issues (db.drop()) - the file must be GONE afterwards, and
# a fresh create at that path must then succeed (the cascade that
# blocked the suite when the op was unhandled)
path = os.environ['FC_NEWDB']
con.drop_database()
check("drop_database removes the file", not os.path.exists(path))
con2 = create_database('newdb', user=os.environ['FC_U'], password=os.environ['FC_P'])
cur2 = con2.cursor()
cur2.execute("CREATE TABLE T2 (ID INTEGER)"); con2.commit()
cur2.execute("INSERT INTO T2 VALUES (7)"); con2.commit()
cur2.execute("SELECT ID FROM T2")
check("re-create at the dropped path works", cur2.fetchall() == [(7,)])
con2.close()
sys.exit(fail)
PYEOF
py_rc=$?

# the engine opens the database the driver created and fire-crab filled
kill $srv 2>/dev/null; wait $srv 2>/dev/null
if [ -f "$NEWDB" ]; then
    rows=$("$ISQL" -q -b -user "$U" -pas "$P" "$NEWDB" <<'EOF' 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
SET HEADING OFF;
SELECT ID FROM T2;
EOF
)
    want="7"
    if [ "$rows" = "$want" ]; then echo "OK   ENGINE reads the driver-created database"; else
        echo "DIFF ENGINE reads the driver-created database"; echo "     got: $rows"; py_rc=1; fi
    val=$("$GFIX" -v -full -user "$U" -pas "$P" "$NEWDB" 2>&1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$val" ]; then echo "OK   gfix -v -full clean on the created database"; else
        echo "DIFF gfix -v -full clean"; echo "     $val"; py_rc=1; fi
else
    echo "DIFF the created database file exists"; py_rc=1
fi
exit $py_rc
