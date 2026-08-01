#!/bin/bash
# WRITING INTO A DESCENDING INDEX - which fire-crab silently CORRUPTED.
#
# A descending key is stored COMPLEMENTED, so plain byte order almost
# works. It fails on exactly one shape: where one key is a byte PREFIX
# of another. Ordinary lexicographic comparison pads the shorter key
# with 0x00 and puts it FIRST; the engine pads it with 0xFF and puts it
# LAST. fire-crab used the ordinary one, so its inserts went into the
# wrong place in the tree.
#
# The damage was not visible from fire-crab at all - it reads what it
# wrote. It was visible from THE ENGINE:
#
#   SELECT COUNT(*) FROM T WHERE D = 3    -> 0, on a table holding it
#   SELECT D FROM T ORDER BY D DESC       -> out of order
#   gfix -v -full                         -> "Number of index page errors: 2"
#
# So this gate does not ask fire-crab anything. It has fire-crab do the
# WRITING, then stops the server and asks the ENGINE - with SET PLAN ON,
# so the PLAN line proves the index was used rather than scanned - and
# finishes with gfix, which is what actually named the corruption.
#
#   qa/serve-real-descwrite.sh [port]
#
# Needs the real engine on 3050 (FC_REAL_PORT overrides) and node with
# node-firebird.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4557}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-dsc-crab.fdb"
B="$D/fc-dsc-engine.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0
ran=0

make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, D INTEGER, S VARCHAR(8));
CREATE TABLE DC (ID INTEGER, V DECIMAL(9,1));
COMMIT;
CREATE DESCENDING INDEX T_D ON T (D);
CREATE DESCENDING INDEX T_S ON T (S);
CREATE ASCENDING INDEX T_DA ON T (D);
CREATE INDEX DC_V ON DC (V);
COMMIT;
INSERT INTO T VALUES (0, 100, 'zz');
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-descwrite.log 2>&1 &
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



# --- 1. fire-crab writes, over values whose keys are prefixes ---------
# 16/256 and 17/257 are the pairs that matter: one encoded key is a byte
# prefix of the other, which is the only place the two orderings differ.
for v in 1 2 3 4 5 16 17 256 257 0 -1 -2 -256 -257; do
    both "insert D = $v" "INSERT INTO T (ID, D, S) VALUES ($v, $v, 'k$v')"
done
both "a NULL descending key" "INSERT INTO T (ID, D, S) VALUES (900, NULL, NULL)"
both "a text key that is a PREFIX of another" \
     "INSERT INTO T (ID, D, S) VALUES (901, 901, 'ab')"
both "... and the one it prefixes" \
     "INSERT INTO T (ID, D, S) VALUES (902, 902, 'abc')"
both "an UPDATE that moves a descending key" "UPDATE T SET D = 999 WHERE ID = 1"
both "a DELETE from a descending index" "DELETE FROM T WHERE ID = 2"

# A SCALED DECIMAL key travels the same road: its bytes come from
# MOV_get_double, which DIVIDES by the power of ten. Multiplying by
# 10^-n instead is a different double in the last ulp for about a third
# of the raws, so fire-crab wrote keys the engine could not match - the
# same shape of silent corruption as the descending order, found by the
# same fleet. These raws are the ones where the two disagree.
both "write a scaled DECIMAL key" "INSERT INTO DC VALUES (1, 0.3)"
both "... another" "INSERT INTO DC VALUES (2, 0.6)"
both "... and another" "INSERT INTO DC VALUES (3, 1.7)"
both "... one where they agree" "INSERT INTO DC VALUES (4, 5.0)"

# --- 2. THE ENGINE reads what fire-crab wrote ------------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null; srv=""
plan_and_rows() {
    printf 'SET PLAN ON;\n%s;\n' "$1" |
        "$ISQL" -q -b -user "$U" -pas "$P" "$2" 2>&1 | tr -s ' \n' ' '
}
engine_finds() { # <label> <sql>
    ran=$((ran + 1))
    a=$(plan_and_rows "$2" "$A")
    b=$(plan_and_rows "$2" "$B")
    case "$a" in
        *INDEX*|*ORDER*) ;;
        *) echo "DIFF the engine did not use an index on fire-crab's file: $1 [$a]"
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
engine_finds "a value whose key prefixes another" "SELECT COUNT(*) FROM T WHERE D = 3"
engine_finds "the longer of the pair" "SELECT COUNT(*) FROM T WHERE D = 257"
engine_finds "and the shorter" "SELECT COUNT(*) FROM T WHERE D = 256"
engine_finds "a negative descending key" "SELECT COUNT(*) FROM T WHERE D = -257"
engine_finds "the moved key" "SELECT COUNT(*) FROM T WHERE D = 999"
engine_finds "the deleted one is gone" "SELECT COUNT(*) FROM T WHERE D = 2"
engine_finds "EVERY key, in descending order" "SELECT D FROM T WHERE D > -1000 ORDER BY D DESC"
engine_finds "the text index, prefix pair included" \
             "SELECT S FROM T WHERE S >= 'a' ORDER BY S DESC"
engine_finds "the ASCENDING twin on the same column is unharmed" \
             "SELECT D FROM T WHERE D > 0 ORDER BY D"
engine_finds "a scaled DECIMAL key fire-crab wrote" "SELECT COUNT(*) FROM DC WHERE V = 0.3"
engine_finds "... and another" "SELECT COUNT(*) FROM DC WHERE V = 1.7"
engine_finds "... every one of them, in order" "SELECT V FROM DC WHERE V > 0 ORDER BY V"

# --- 3. and gfix, which is what named the corruption -----------------
ran=$((ran + 1))
if "${GFIX:-gfix}" -v -full -user "$U" -pas "$P" "$A" >/tmp/fc-dsc-gfix.txt 2>&1 &&
   [ ! -s /tmp/fc-dsc-gfix.txt ]; then
    echo "OK   gfix -v -full finds nothing wrong with the descending indexes"
else
    echo "DIFF gfix reported: $(head -3 /tmp/fc-dsc-gfix.txt)"
    fail=1
fi

rm -f "$A" "$B"
if [ "$ran" -lt 36 ]; then
    echo "DIFF only $ran checks ran (expected at least 36) - did one silently skip?"
    fail=1
fi
exit $fail
