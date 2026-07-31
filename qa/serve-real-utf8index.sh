#!/bin/bash
# A UTF8 DATABASE WITH A TEXT INDEX - which this server could not write
# to at all.
#
# A text index on a UTF8 column is stamped idx_metadata (itype 4), not
# idx_string (1). `resolve_index_ops` did not list itype 4, and it
# returns None for the WHOLE RELATION when any of its indexes carries an
# itype the write path cannot key - and the INSERT planner takes that
# with `?`. So on a UTF8 database - the default character set in this
# project's own hands-on samples - a table with a text index accepted no
# INSERT and no UPDATE whatsoever, while the engine took both. Reads
# worked, which is exactly why it went unnoticed: every gate here builds
# its scratch database in the default (NONE) charset.
#
# `btw::index_key` had encoded itype 4 correctly all along
# (INTL_string_to_key ttype_metadata: plain bytes, trailing spaces
# stripped, and an empty value padding to 0x00 rather than the blank
# idx_string uses).
#
# The decisive check is not that fire-crab accepts the write. It is that
# THE ENGINE READS IT BACK THROUGH ITS OWN INDEX: the gate stops the
# server, opens the file with isql, and runs indexed lookups with
# SET PLAN ON so the PLAN line proves the index was used rather than
# scanned. A key we wrote differently from the engine would find nothing
# there. gfix -v -full then validates the pages.
#
#   qa/serve-real-utf8index.sh [port]
#
# Needs the real engine on 3050 (FC_REAL_PORT overrides) and node with
# node-firebird.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4556}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-u8-crab.fdb"
B="$D/fc-u8-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192
    DEFAULT CHARACTER SET UTF8;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(20), N INTEGER);
COMMIT;
CREATE INDEX T_NAME ON T (NAME);
CREATE INDEX T_N ON T (N);
COMMIT;
INSERT INTO T VALUES (1, 'alpha', 10);
INSERT INTO T VALUES (2, 'beta', 20);
INSERT INTO T VALUES (3, '', 30);
INSERT INTO T VALUES (4, NULL, 40);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-utf8index.log 2>&1 &
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


# --- 1. the writes the outage refused ---------------------------------
both "an INSERT into a UTF8 table with a text index" \
     "INSERT INTO T VALUES (5, 'gamma', 50)"
both "... and one with a NULL text key" "INSERT INTO T VALUES (6, NULL, 60)"
both "... and one with an EMPTY text key" "INSERT INTO T VALUES (7, '', 70)"
both "... and one with trailing blanks, which the key strips" \
     "INSERT INTO T VALUES (8, 'delta   ', 80)"
both "an UPDATE that MOVES a text key" "UPDATE T SET NAME = 'zeta' WHERE ID = 1"
both "an UPDATE that leaves the key alone" "UPDATE T SET N = 99 WHERE ID = 2"
both "a DELETE" "DELETE FROM T WHERE ID = 3"
both "the table, after all of it" "SELECT ID, NAME, N FROM T ORDER BY ID"
both "a lookup on the text column" "SELECT ID FROM T WHERE NAME = 'gamma'"
both "the moved key's new value" "SELECT ID FROM T WHERE NAME = 'zeta'"
both "the moved key's OLD value finds nothing" \
     "SELECT ID FROM T WHERE NAME = 'alpha'"
both "the blank-stripped key" "SELECT ID FROM T WHERE NAME = 'delta'"
both "a text range" "SELECT ID FROM T WHERE NAME >= 'g' ORDER BY NAME"
both "an INTEGER index on the same relation still works" \
     "SELECT ID FROM T WHERE N = 50"

# --- 2. THE DECISIVE CHECK: the ENGINE reads what fire-crab wrote -----
# through its OWN index, which is only possible if our keys are the
# bytes it would have written
kill $srv 2>/dev/null; wait $srv 2>/dev/null; srv=""
plan_and_rows() { # <sql> -> "<plan line>|<rows>"
    printf 'SET PLAN ON;\n%s;\n' "$1" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$2" 2>&1 | tr -s ' \n' ' '
}
engine_finds() { # <label> <sql>
    ran=$((ran + 1))
    a=$(plan_and_rows "$2" "$A")
    b=$(plan_and_rows "$2" "$B")
    case "$a" in
        *INDEX*|*ORDER*) ;;
        *) echo "DIFF the engine did NOT use the index on fire-crab's file: $1 [$a]"
           fail=1; return ;;
    esac
    if [ "$a" = "$b" ]; then
        echo "OK   the engine reads it through the index: $1"
    else
        echo "DIFF $1"
        echo "     fire-crab's file: $a"
        echo "     the engine's:     $b"
        fail=1
    fi
}
engine_finds "a row fire-crab INSERTed" "SELECT ID FROM T WHERE NAME = 'gamma'"
engine_finds "a key fire-crab MOVED" "SELECT ID FROM T WHERE NAME = 'zeta'"
engine_finds "the blank-stripped key" "SELECT ID FROM T WHERE NAME = 'delta'"
engine_finds "every key, in index order" \
             "SELECT ID FROM T WHERE NAME >= 'a' ORDER BY NAME"
engine_finds "the integer index beside it" "SELECT ID FROM T WHERE N >= 50 ORDER BY N"

# --- 3. and the pages are sound ---------------------------------------
ran=$((ran + 1))
if "${GFIX:-gfix}" -v -full -user "$U" -pas "$P" "$A" >/tmp/fc-u8-gfix.txt 2>&1 &&
   [ ! -s /tmp/fc-u8-gfix.txt ]; then
    echo "OK   gfix -v -full finds nothing wrong with fire-crab's UTF8 index"
else
    echo "DIFF gfix reported: $(head -3 /tmp/fc-u8-gfix.txt)"
    fail=1
fi

rm -f "$A" "$B"
if [ "$ran" -lt 20 ]; then
    echo "DIFF only $ran checks ran (expected at least 20) - did one silently skip?"
    fail=1
fi
exit $fail
