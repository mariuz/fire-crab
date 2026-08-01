#!/bin/bash
# THE FETCH BATCH - a cursor larger than one socket buffer.
#
# The server answered every op_fetch with the WHOLE result set and
# ignored the row count the client asked for. Below about 2300 rows that
# is invisible: everything fits in the socket and the client reads it
# all. Above it the write BLOCKS, the client - having read the batch it
# asked for - stops reading to send its next op_fetch, and neither side
# ever moves again. A SELECT returning 2400 rows HUNG FOREVER.
#
# Two things were missing, and the second is why the first is not
# enough. A batch must be BOUNDED by the count the client sent; and it
# must be TERMINATED, because the client's decode loop runs while
# "count && status != 100" and needs one of the two to stop reading:
#
#   end of BATCH, rows still to come   count = 0, ordinary status
#   end of CURSOR                      status = 100
#
# Sending neither leaves the client waiting for bytes that will not come
# until it asks - which it cannot do while it is waiting.
#
# Every check here returns MORE rows than fit in one batch, and the
# fixture is 6000 rows so that even a large batch size is exceeded.
#
#   qa/serve-real-fetchbatch.sh [port]
#
# Needs the real engine on 3050 (FC_REAL_PORT overrides) and node.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4559}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-batch-crab.fdb"
B="$D/fc-batch-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(20), G INTEGER);
COMMIT;
CREATE INDEX B_G ON B (G);
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS DECLARE I INTEGER = 0; BEGIN
  WHILE (I < 6000) DO BEGIN I = I + 1;
    INSERT INTO B VALUES (:I, 'row ' || :I, MOD(:I, 7)); END
END^
SET TERM ; ^
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-fetchbatch.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
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

query() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 25 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
              console.log(JSON.stringify(Array.isArray(r)?r:(r?[r]:[])));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}

both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(query "$2" "$PORT" "$A")
    b=$(query "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}
refuses() { # <label> <sql>
    ran=$((ran + 1))
    r=$(query "$2" "$PORT" "$A")
    case "$r" in
        ERR*) echo "OK   refused: $1" ;;
        *) echo "DIFF $1 answered: [$r]"; fail=1 ;;
    esac
}


# A cursor of thousands of rows cannot be compared by pasting it into a
# shell variable - the first version of this gate did, and reported
# DIFFs that were its own truncation rather than the server's. Every
# check here compares a DIGEST: the row count and an md5 of the whole
# result, computed in the client.
digest() { # <sql> <port> <db>
    n=0
    while [ $n -lt 6 ]; do
        r=$(timeout 90 env FC_Q="$1" FC_PORT="$2" FC_DB="$3" node -e '
          process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(0); });
          const F=require("node-firebird"), crypto=require("crypto");
          F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                    user:"SYSDBA",password:"masterkey"},(e,db)=>{
            if(e){console.log("CONN_ERR");process.exit(0);}
            db.query(process.env.FC_Q,(e2,r)=>{
              if(e2){console.log("ERR "+(e2.message||"").split("\n")[0].slice(0,50));db.detach();process.exit(0);}
              const a=Array.isArray(r)?r:(r?[r]:[]);
              console.log(a.length+" rows md5="+crypto.createHash("md5").update(JSON.stringify(a)).digest("hex").slice(0,16));
              db.detach();process.exit(0);});});' 2>/dev/null)
        case "$r" in
            CONN_ERR|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r"; return ;;
        esac
    done
    printf 'CONN_ERR'
}
dboth() { # <label> <sql>
    ran=$((ran + 1))
    a=$(digest "$2" "$PORT" "$A")
    b=$(digest "$2" "$REAL" "$B")
    if [ "$a" = "$b" ]; then
        echo "OK   $1: $a"
    else
        echo "DIFF $1"
        echo "     fcwire: $a"
        echo "     engine: $b"
        fail=1
    fi
}

# --- 1. a cursor bigger than one buffer -------------------------------
dboth "every row of a 6000-row table" "SELECT ID FROM B ORDER BY ID"
dboth "... with a second column, so the rows are wider" \
     "SELECT ID, V FROM B ORDER BY ID"
dboth "the row just below the old cliff" "SELECT ID FROM B WHERE ID <= 2300 ORDER BY ID"
dboth "the row just above it" "SELECT ID FROM B WHERE ID <= 2400 ORDER BY ID"
dboth "an exact multiple of the batch size" "SELECT ID FROM B WHERE ID <= 2000 ORDER BY ID"
dboth "one more than a multiple" "SELECT ID FROM B WHERE ID <= 2001 ORDER BY ID"
dboth "one less" "SELECT ID FROM B WHERE ID <= 1999 ORDER BY ID"

# --- 2. the same, through every shape that materialises differently ---
dboth "an index-driven range over half the table" \
     "SELECT ID FROM B WHERE G = 3 ORDER BY ID"
dboth "a sorted cursor" "SELECT ID FROM B ORDER BY V, ID"
dboth "FIRST over a large cursor" "SELECT FIRST 2500 ID FROM B ORDER BY ID"
dboth "SKIP into the tail" "SELECT SKIP 5900 ID FROM B ORDER BY ID"
dboth "a UNION of two large branches" \
     "SELECT ID FROM B WHERE ID <= 2500 UNION ALL SELECT ID FROM B WHERE ID > 4500"
dboth "a grouped cursor with many groups" \
     "SELECT G, COUNT(*) AS K FROM B GROUP BY G ORDER BY G"
dboth "a derived table over the lot" \
     "SELECT COUNT(*) AS K FROM (SELECT ID FROM B WHERE ID > 100) X"
dboth "and the aggregate that reads them all" "SELECT COUNT(*) AS K, MAX(ID) AS M FROM B"

# --- 3. the cursor is CONSUMED, not re-served -------------------------
# a batched cursor must not restart: the rows exist once, and a client
# that fetches until empty would otherwise loop forever. Two whole-table
# reads in one statement is the shape that would show it.
dboth "the table joined to itself, every row" \
     "SELECT COUNT(*) AS K FROM B X JOIN B Y ON X.ID = Y.ID"
dboth "... and read again straight after" "SELECT COUNT(*) AS K FROM B"
# NOT checked here, and worth naming: an IN-SUBQUERY refuses somewhere
# between 10 and 100 inner rows (`WHERE ID IN (SELECT ID FROM B WHERE
# ID > 5900)` is refused while `> 5990` answers). That is a separate,
# pre-existing limit in how an IN-subquery is desugared - nothing to do
# with fetch batching - and it is in the roadmap.

rm -f "$A" "$B"
if [ "$ran" -lt 16 ]; then
    echo "DIFF only $ran checks ran (expected at least 16) - did one silently skip?"
    fail=1
fi
exit $fail
