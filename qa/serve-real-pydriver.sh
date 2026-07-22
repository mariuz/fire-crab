#!/bin/bash
# THE PYTHON firebird-driver DRIVES fire-crab. This is the driver the
# firebird-qa pytest suite's test bodies use for every database
# operation - a THIRD kind of client (after node-firebird's pure JS and
# the C++ isql), the reference python OO client built on the C++
# fbclient library through its IProvider/IStatement/ITransaction
# interfaces. Getting it to work exposed protocol details node-firebird
# was lax about:
#
#   - op_prepare must answer the client's REQUESTED info-item list in
#     the requested order (stmt_type, stmt_flags, and per-var
#     field/relation/schema/alias items); the fixed-shape describe
#     buffer that satisfied node-firebird made the OO API raise
#     "Unrecognized C++ exception";
#   - op_execute's response object must ECHO THE TRANSACTION HANDLE
#     (server.cpp send_response uses transaction->rtr_id) - the OO
#     client reads it as the live transaction and NULLED its
#     ITransaction on the 0 we used to send, so commit crashed;
#   - a string parameter arrives as blr_text2 (charset word + length
#     word), the driver's value-derived representation - not the plain
#     blr_text/blr_varying node-firebird sends.
#
# It needs the python venv the harness built with firebird-driver
# installed; skips cleanly otherwise. The full firebird-qa PLUGIN
# additionally needs the Services API (op_service_attach/op_service_info
# - its session bootstrap reads the server version/home/lock dirs) and
# op_create for per-test databases; those are the named next milestones.
# This gate proves the statement-level driver protocol those tests run
# their SQL through.
#
#   FCPY=/path/to/venv/bin/python qa/serve-real-pydriver.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
FCPY="${FCPY:-}"
PORT="${1:-4082}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/pydriver_src.fdb"; CLEAN="$DIR/pydriver_clean.fdb"
WORK="/tmp/fc-pydriver-work.fdb"

if [ -z "$FCPY" ] || ! "$FCPY" -c "import firebird.driver" 2>/dev/null; then
    echo "SKIP python firebird-driver not available (set FCPY to a venv python)"
    exit 0
fi
mkdir -p "$DIR"

rm -f "$SRC" "$CLEAN" "$WORK"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NAME VARCHAR(20), SAL NUMERIC(9,2));
COMMIT;
INSERT INTO T VALUES (1, 'seed', 10.50);
COMMIT;
EOF
cp "$SRC" "$CLEAN"; cp "$CLEAN" "$WORK"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-pydriver.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

# the whole battery runs inside one python process; it prints one
# "OK <label>" / "DIFF <label> ..." line per check and a final RC
FC_DB="$WORK" FC_PORT="$PORT" FC_U="$U" FC_P="$P" "$FCPY" - <<'PYEOF'
import os, sys
from firebird.driver import connect, driver_config
srv = driver_config.register_server('fc')
srv.host.value = '127.0.0.1'; srv.port.value = os.environ['FC_PORT']
srv.user.value = os.environ['FC_U']; srv.password.value = os.environ['FC_P']
db = driver_config.register_database('fcdb')
db.server.value = 'fc'; db.database.value = os.environ['FC_DB']

fail = 0
def check(label, got, want):
    global fail
    if got == want:
        print(f"OK   {label}")
    else:
        print(f"DIFF {label}\n     want: {want!r}\n     got:  {got!r}")
        fail = 1

con = connect('fcdb', user=os.environ['FC_U'], password=os.environ['FC_P'])
cur = con.cursor()

cur.execute("SELECT ID, NAME FROM T WHERE ID = 1")
check("select one row", cur.fetchall(), [(1, 'seed')])

cur.execute("SELECT ID, NAME, SAL FROM T ORDER BY ID")
check("select typed row (NUMERIC)", cur.fetchall(), [(1, 'seed', __import__('decimal').Decimal('10.50'))])

# parameterised INSERT (string param arrives as blr_text2) + commit
cur.execute("INSERT INTO T VALUES (?, ?, ?)", (2, 'py-param', 22.25))
con.commit()
cur.execute("SELECT COUNT(*) FROM T")
check("param INSERT + commit", cur.fetchone(), (2,))
cur.execute("SELECT NAME, SAL FROM T WHERE ID = 2")
check("bound values readback", cur.fetchone(), ('py-param', __import__('decimal').Decimal('22.25')))

# parameterised WHERE
cur.execute("SELECT ID FROM T WHERE NAME = ?", ('py-param',))
check("param WHERE", cur.fetchall(), [(2,)])

# UPDATE + DELETE through the driver
cur.execute("UPDATE T SET SAL = ? WHERE ID = ?", (99.99, 1)); con.commit()
cur.execute("SELECT SAL FROM T WHERE ID = 1")
check("param UPDATE", cur.fetchone(), (__import__('decimal').Decimal('99.99'),))
cur.execute("DELETE FROM T WHERE ID = ?", (2,)); con.commit()
cur.execute("SELECT COUNT(*) FROM T")
check("param DELETE", cur.fetchone(), (1,))

# DDL through the driver: CREATE TABLE with a PK, use it, drop it
cur.execute("CREATE TABLE PYT (A INTEGER NOT NULL PRIMARY KEY, B VARCHAR(10))"); con.commit()
cur.execute("INSERT INTO PYT VALUES (1, 'ddl')"); con.commit()
cur.execute("SELECT A, B FROM PYT")
check("CREATE TABLE + insert + select", cur.fetchall(), [(1, 'ddl')])
try:
    cur.execute("INSERT INTO PYT VALUES (1, 'dup')"); con.commit()
    check("PK enforced through driver", "no error", "SQL error")
except Exception:
    con.rollback()
    print("OK   PK enforced through driver")
cur.execute("DROP TABLE PYT"); con.commit()
cur.execute("SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'PYT'")
check("table dropped through driver", cur.fetchone(), (0,))

# a fresh connection sees the committed data - the driver's writes
# reached the file (fire-crab is an offline writer that commits every
# statement immediately; rollback is a no-op, so this gate does not
# assert rollback semantics)
con.close()
con2 = connect('fcdb', user=os.environ['FC_U'], password=os.environ['FC_P'])
cur2 = con2.cursor()
cur2.execute("SELECT ID, SAL FROM T ORDER BY ID")
check("a fresh connection sees the committed writes", cur2.fetchall(),
      [(1, __import__('decimal').Decimal('99.99'))])
con2.close()
sys.exit(fail)
PYEOF
py_rc=$?

# the engine validates the file the python driver left behind
kill $srv 2>/dev/null; wait $srv 2>/dev/null
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ -z "$val" ]; then echo "OK   gfix -v -full clean after driver writes"; else
    echo "DIFF gfix -v -full clean after driver writes"; echo "     $val"; py_rc=1; fi
exit $py_rc
