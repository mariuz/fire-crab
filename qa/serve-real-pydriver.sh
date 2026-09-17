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
CREATE SEQUENCE SQQ;
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE PU (A VARCHAR(10), B INTEGER) RETURNS (K INTEGER) AS BEGIN K = B; SUSPEND; END^
SET TERM ; ^
COMMIT;
INSERT INTO T VALUES (1, 'seed', 10.50);
COMMIT;
EOF
cp "$SRC" "$CLEAN"; cp "$CLEAN" "$WORK"
# the live engine serves $CLEAN over 3050 for the differential
# flag battery; it runs as its own user, so the copies must be
# openable by it (the harness law for engine-served fixtures)
chmod 666 "$SRC" "$CLEAN" "$WORK" 2>/dev/null || true

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-pydriver.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK"' EXIT
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

# the whole battery runs inside one python process; it prints one
# "OK <label>" / "DIFF <label> ..." line per check and a final RC
FC_DB="$WORK" FC_REF="$CLEAN" FC_ENGPORT="${FC_ENGPORT:-3050}" FC_PORT="$PORT" FC_U="$U" FC_P="$P" "$FCPY" - <<'PYEOF'
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

# ---------------------------------------------------------------
# THE STATEMENT FLAG WORD (isc_info_sql_stmt_flags, info item 27)
#
# This is what the OO API dispatches on to choose openCursor() over the
# singleton execute(). It is NOT cosmetic: announcing a bare
# `SELECT ... FROM <selectable procedure>` WITHOUT FLAG_HAS_CURSOR sent
# this very driver down op_execute2, where the statement died with a
# Dynamic SQL Error - while isql and node-firebird, which dispatch on
# the stmt TYPE instead, ran the identical SQL correctly. A whole class
# of statement was broken for OO clients only.
#
# Measured DIFFERENTIALLY against the live engine on the SAME fixture
# rather than against stored constants: 1 = FLAG_HAS_CURSOR,
# 2 = FLAG_REPEAT_EXECUTE.
# ---------------------------------------------------------------
esrv = driver_config.register_server('eng')
esrv.host.value = '127.0.0.1'; esrv.port.value = os.environ['FC_ENGPORT']
esrv.user.value = os.environ['FC_U']; esrv.password.value = os.environ['FC_P']
edb = driver_config.register_database('engdb')
edb.server.value = 'eng'; edb.database.value = os.environ['FC_REF']

def shape(dbname, sql):
    """(stmt_type, flag word) as that server announces them at PREPARE."""
    try:
        with connect(dbname, user=os.environ['FC_U'], password=os.environ['FC_P']) as c:
            st = c.cursor().prepare(sql)
            return ("%s" % st.type, int(st._istmt.get_flags()))
    except Exception as e:
        return "ERR:" + str(e).split("\n")[0][:44]

ran = 0
engine_flags_seen = set()
engine_types_seen = set()
def flagcheck(label, sql):
    global fail, ran
    e = shape('engdb', sql); f = shape('fcdb', sql)
    if isinstance(e, str):
        # a cell the ENGINE cannot prepare measures nothing - the gate
        # must not bank an agreement between two refusals
        print(f"DIFF flags {label} [VACUOUS: the engine refused this shape] {e}")
        fail = 1
        return
    engine_flags_seen.add(e[1])
    engine_types_seen.add(e[0])
    ran += 1
    if e == f:
        print(f"OK   flags {label} (type={e[0]} flags={e[1]})")
    else:
        print(f"DIFF flags {label}\n     engine: {e}\n     fc:     {f}")
        fail = 1

CELLS = [
    # cursor statements - flags 3
    ("plain select",                   "SELECT ID FROM T WHERE ID = 1"),
    ("virtual select",                 "SELECT 1 FROM RDB$DATABASE"),
    ("BARE CALL, literal args",        "SELECT K FROM PU('ab', 9)"),
    ("BARE CALL, bound args",          "SELECT K FROM PU(?, ?)"),
    ("aliased bare call",              "SELECT P.K FROM PU('ab', 9) P"),
    ("modifier over the call",         "SELECT FIRST 1 K FROM PU('ab', 9)"),
    ("aggregate over the call",        "SELECT MAX(K) FROM PU('ab', 9)"),
    ("cte",                            "WITH C AS (SELECT ID FROM T) SELECT ID FROM C"),
    ("derived table",                  "SELECT ID FROM (SELECT ID FROM T) D"),
    ("union",                          "SELECT ID FROM T UNION ALL SELECT 1 FROM RDB$DATABASE"),
    # SELECT ... FOR UPDATE is isc_info_sql_stmt_select_for_update (12),
    # not plain select (1) - measured shape by shape against the engine.
    # The FLAG word stays 3 throughout, which is why only the pair can
    # tell these cells apart from the plain-select one above.
    ("FOR UPDATE is TYPE 12",          "SELECT ID FROM T FOR UPDATE"),
    ("FOR UPDATE OF <col>",            "SELECT ID FROM T FOR UPDATE OF ID"),
    ("lower case for update",          "select id from t for update"),
    ("ORDER BY then FOR UPDATE",       "SELECT ID FROM T ORDER BY ID FOR UPDATE"),
    ("ROWS then FOR UPDATE",           "SELECT ID FROM T ROWS 2 FOR UPDATE"),
    ("FOR UPDATE beside WITH LOCK",    "SELECT ID FROM T FOR UPDATE WITH LOCK"),
    ("star projection + FOR UPDATE",   "SELECT * FROM T FOR UPDATE"),
    ("aggregate + FOR UPDATE",         "SELECT COUNT(*) FROM T FOR UPDATE"),
    ("GROUP BY + FOR UPDATE",          "SELECT ID FROM T GROUP BY ID FOR UPDATE"),
    ("FIRST, no DISTINCT",             "SELECT FIRST 2 ID FROM T FOR UPDATE"),
    # DISTINCTs that are NOT the statement's own - all still 12
    ("COUNT(DISTINCT x) + FU",         "SELECT COUNT(DISTINCT ID) FROM T FOR UPDATE"),
    ("a 'DISTINCT' LITERAL + FU",      "SELECT ID, 'DISTINCT' AS W FROM T FOR UPDATE"),
    ("IS DISTINCT FROM + FU",          "SELECT ID, SAL IS DISTINCT FROM 1 AS D FROM T FOR UPDATE"),
    # UNION ALL does not cancel, and neither does a BRANCH's own DISTINCT
    ("UNION ALL stays 12",             "SELECT ID FROM T UNION ALL SELECT 1 FROM RDB$DATABASE FOR UPDATE"),
    ("a branch DISTINCT does not cancel", "SELECT DISTINCT ID FROM T UNION ALL SELECT 1 FROM RDB$DATABASE FOR UPDATE"),
    # a CTE is typed by its MAIN select
    ("CTE + FOR UPDATE",               "WITH C AS (SELECT ID FROM T) SELECT ID FROM C FOR UPDATE"),
    ("DISTINCT in the CTE BODY",       "WITH C AS (SELECT DISTINCT ID FROM T) SELECT ID FROM C FOR UPDATE"),
    # ...and the two cancels, which come back as a plain select (1)
    ("top-level DISTINCT CANCELS",     "SELECT DISTINCT ID FROM T FOR UPDATE"),
    ("FIRST + DISTINCT cancels",       "SELECT FIRST 2 DISTINCT ID FROM T FOR UPDATE"),
    ("SKIP + DISTINCT cancels",        "SELECT SKIP 1 DISTINCT ID FROM T FOR UPDATE"),
    ("bare UNION CANCELS",             "SELECT ID FROM T UNION SELECT 1 FROM RDB$DATABASE FOR UPDATE"),
    # (a MIXED UNION ALL / bare UNION chain is a RECORDED divergence -
    #  fire-crab refuses the statement outright; checked at the end)
    ("CTE top-level DISTINCT cancels", "WITH C AS (SELECT ID FROM T) SELECT DISTINCT ID FROM C FOR UPDATE"),
    # the RETURNING split: INSERT..RETURNING is a SINGLETON (type 8 -> 2),
    # UPDATE/DELETE..RETURNING are CURSORS (type 1 -> 3)
    ("insert .. returning IS A SINGLETON", "INSERT INTO T (ID) VALUES (?) RETURNING ID"),
    ("update .. returning IS A CURSOR",    "UPDATE T SET ID = ? RETURNING ID"),
    ("delete .. returning IS A CURSOR",    "DELETE FROM T RETURNING ID"),
    # non-cursor executable statements - flags 2
    ("insert values",                  "INSERT INTO T (ID) VALUES (?)"),
    ("insert .. select",               "INSERT INTO T (ID) SELECT ID FROM T"),
    ("update",                         "UPDATE T SET ID = ?"),
    ("delete",                         "DELETE FROM T"),
    ("execute procedure",              "EXECUTE PROCEDURE PU('ab', 9)"),
    ("exec block that SUSPENDs",       "EXECUTE BLOCK RETURNS (X INTEGER) AS BEGIN X = 1; SUSPEND; END"),
    ("exec block, void",               "EXECUTE BLOCK AS BEGIN END"),
    ("commit",                         "COMMIT"),
    ("rollback",                       "ROLLBACK"),
    ("savepoint",                      "SAVEPOINT SP1"),
    ("set generator",                  "SET GENERATOR SQQ TO 5"),
    # session management reports the DDL TYPE (5) yet is NOT DDL: it
    # still answers 2. This is why "is DDL" cannot be a type test.
    ("set time zone (type 5, yet 2)",  "SET TIME ZONE 'UTC'"),
    # real DDL - a bare 0, neither bit. These already agreed BEFORE the
    # fix, so they are the battery's positive controls: if the whole
    # battery started reporting DIFF, these would too.
    ("real DDL create table",          "CREATE TABLE ZZQ (A INTEGER)"),
    ("real DDL create index",          "CREATE INDEX IXQ ON T (ID)"),
    ("real DDL grant",                 "GRANT SELECT ON T TO PUBLIC"),
]
for label, sql in CELLS:
    flagcheck(label, sql)

if ran < len(CELLS):
    print(f"DIFF flags battery ran {ran} of {len(CELLS)} cells")
    fail = 1
# THE TYPE LAW NEEDS ITS OWN SPAN CHECK. Every cell compares the (type,
# flags) PAIR, and the flag word is 3 for a plain select and for a FOR
# UPDATE one alike - so a battery that never saw a 12 would agree with a
# server that has never heard of FOR UPDATE, exactly the vacuity the
# flags guard below closes for 0/2/3.
if "12" not in engine_types_seen:
    print(f"DIFF type battery is VACUOUS: the engine never answered select_for_update "
          f"(saw types {sorted(engine_types_seen)}), so the FOR UPDATE law went untested")
    fail = 1
else:
    print(f"OK   type battery spans select_for_update (engine types {sorted(engine_types_seen)})")

# RECORDED, NOT FIXED: a chain that MIXES `UNION ALL` with a bare
# `UNION` is refused by fire-crab outright - `split_union` answers None
# for a mixed chain, so the planner never reaches a shape it can plan
# and the statement cannot be typed at all, while the engine prepares it
# as a plain select. Measured IDENTICAL on the binary before this slice,
# so it is not the FOR UPDATE law failing: that law would answer 1 here
# too, it is simply never asked. Self-expiring - this FAILS if fire-crab
# starts answering, or if the engine stops typing it 1.
mixed = ("SELECT ID FROM T UNION ALL SELECT 1 FROM RDB$DATABASE "
         "UNION SELECT 2 FROM RDB$DATABASE FOR UPDATE")
me = shape('engdb', mixed); mf = shape('fcdb', mixed)
if me == ('1', 3) and isinstance(mf, str) and mf.startswith("ERR:"):
    print("OK   recorded: a MIXED UNION ALL/bare UNION chain - engine types it 1, fc refuses")
else:
    print(f"DIFF the mixed-chain divergence MOVED\n     engine: {me}\n     fc:     {mf}")
    fail = 1

# the law has THREE distinct answers; a battery that saw only one of
# them would agree with almost any implementation
if not {0, 2, 3}.issubset(engine_flags_seen):
    print(f"DIFF flags battery is VACUOUS: the engine answered only {sorted(engine_flags_seen)}, "
          f"so the 0/2/3 distinction went untested")
    fail = 1
else:
    print(f"OK   flags battery spans the law ({ran} cells, engine answered {sorted(engine_flags_seen)})")

sys.exit(fail)
PYEOF
py_rc=$?

# the engine validates the file the python driver left behind
kill $srv 2>/dev/null; wait $srv 2>/dev/null
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$WORK" 2>&1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ -z "$val" ]; then echo "OK   gfix -v -full clean after driver writes"; else
    echo "DIFF gfix -v -full clean after driver writes"; echo "     $val"; py_rc=1; fi
exit $py_rc
