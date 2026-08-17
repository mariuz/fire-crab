#!/bin/bash
# THE METADATA CACHE, AND WHAT IT IS NOT ALLOWED TO CHANGE.
#
# Every statement used to re-derive its table from the FILE - the id
# from `RDB$RELATIONS`, the columns from `RDB$RELATION_FIELDS` +
# `RDB$FIELDS`, the descriptors from `RDB$FORMATS`, then the indexes,
# the NOT NULL fields, the identity column, the qualified name, each
# one a walk of a system relation. Measured with `FC_SRV_TIME=1`:
# 5.6ms of an 8.2ms INSERT was planning, and the answers were the same
# every time, because only DDL can change them.
#
# So they are cached per database, keyed by a generation that DDL
# advances - the engine's own metadata-cache rule. This gate holds the
# two things that matter about a cache:
#
#   * THE ANSWERS DO NOT MOVE. Every check below runs TWICE against
#     fire-crab - once with the cache and once with `FC_NO_MDC=1` - and
#     both must equal what the ENGINE says. A cache that changed an
#     answer would show up as the two fire-crab runs disagreeing, or as
#     either disagreeing with the engine.
#   * IT IS ACTUALLY USED. The pool's own counters, out of the server
#     log: hits must be non-zero (otherwise every statement still read
#     the catalog) and invalidations must be non-zero (otherwise DDL
#     never dropped anything and the answers above were lucky).
#
# The statements are chosen to make STALENESS visible: each DDL is
# followed by DML that can only be right if the cache noticed.
#
#   qa/serve-real-metadata.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4696}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
LOG=/tmp/fc-serve-metadata-$PORT.log
fail=0
ran=0
mkdir -p "$D"

check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"
    else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

# THE SCRIPT: DDL, then DML that depends on it, over and over. A stale
# columns/format/index/NOT NULL answer cannot survive this.
# Column lists throughout, so a statement means the same thing before
# and after the ALTERs - what is being measured is whether the cache
# NOTICED them, not whether the script survives them. And every UPDATE
# touches a row stored in the CURRENT format: fire-crab refuses to
# patch a record whose stored format is older than the plan's (a
# recorded limitation, with or without this cache), and a gate about
# metadata should not be measuring that.
SCRIPT='SET AUTODDL ON;
CREATE TABLE M (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER);
INSERT INTO M (ID, A) VALUES (1, 10);
COMMIT;
ALTER TABLE M ADD B VARCHAR(8);
INSERT INTO M (ID, A, B) VALUES (2, 20, %s);
UPDATE M SET B = %s WHERE ID = 2;
COMMIT;
CREATE INDEX M_A ON M (A);
INSERT INTO M (ID, A, B) VALUES (3, 30, %s);
UPDATE M SET A = 99 WHERE ID = 3;
COMMIT;
CREATE TABLE N (ID INTEGER NOT NULL PRIMARY KEY, MID INTEGER);
ALTER TABLE N ADD CONSTRAINT N_FK FOREIGN KEY (MID) REFERENCES M (ID);
INSERT INTO N (ID, MID) VALUES (1, 1);
COMMIT;
ALTER TABLE M ADD C INTEGER;
INSERT INTO M (ID, A, B, C) VALUES (4, 40, %s, 44);
UPDATE M SET C = A + 1 WHERE ID = 4;
DELETE FROM M WHERE ID = 3;
COMMIT;
SET HEADING OFF;
SELECT COUNT(*) FROM M;
SELECT ID || %s || A || %s || COALESCE(B, %s) || %s || COALESCE(C, -1) FROM M ORDER BY ID;
SELECT COUNT(*) FROM N;'

run() { # <conn> [env...]
    local conn="$1"; shift
    printf "$SCRIPT\n" "'bee'" "'one'" "'cee'" "'dee'" "'|'" "'|'" "'-'" "'|'" |
        env "$@" "$ISQL" -q -b -user "$U" -pas "$P" "$conn" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ','
}

# --- 1. the engine's answers ------------------------------------------
E="$D/fc-meta-engine.fdb"; rm -f "$E"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$E' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
chmod 666 "$E"
engine=$(run "$E" FC_X=1)
ran=$((ran + 1))
if [ -n "$engine" ]; then echo "OK   the engine ran the script [$engine]"
else echo "DIFF the engine produced nothing"; fail=1; fi

# --- 2. fire-crab, with the cache and without --------------------------
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

A="$D/fc-meta-crab.fdb"; rm -f "$A"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$A' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
chmod 666 "$A"
cached=$(run "127.0.0.1/$PORT:$A" FC_X=1)
check "fc WITH the cache answers what the engine answers" "$cached" "$engine"

# the same server, the cache off for this connection's statements is not
# possible - the switch is per process - so a second server runs without
P2=$((PORT + 1))
FC_NO_MDC=1 "$FCWIRE" serve "127.0.0.1:$P2" "$U" "$P" >/dev/null 2>&1 &
srv2=$!
trap 'kill $srv $srv2 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$P2" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv2 2>/dev/null || { echo "FAIL second fcwire not running - port $P2 taken?"; exit 1; }
B="$D/fc-meta-crab2.fdb"; rm -f "$B"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$B' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
chmod 666 "$B"
uncached=$(run "127.0.0.1/$P2:$B" FC_X=1)
check "fc WITHOUT the cache answers the same thing" "$uncached" "$cached"

# --- 3. COVERAGE: it was used, and DDL dropped it ----------------------
mdc=$(grep '\[srv\] mdc:' "$LOG" | tail -1)
hits=$(printf '%s' "$mdc" | sed -n 's/.*hits \([0-9]*\).*/\1/p')
inv=$(printf '%s' "$mdc" | sed -n 's/.*invalidations \([0-9]*\).*/\1/p')
ran=$((ran + 1))
if [ -n "${hits:-}" ] && [ "${hits:-0}" -gt 0 ]; then
    echo "OK   coverage: the cache answered $hits times [$mdc]"
else
    echo "DIFF coverage: nothing was ever answered from the cache [$mdc]"; fail=1
fi
ran=$((ran + 1))
if [ -n "${inv:-}" ] && [ "${inv:-0}" -gt 0 ]; then
    echo "OK   coverage: DDL dropped it $inv times"
else
    echo "DIFF coverage: DDL never dropped the cache [$mdc]"; fail=1
fi

# --- 4. THE ANSWERS A KEPT PLAN MUST NOT FREEZE -------------------------
# The statement cache keeps the plan a text resolves to. That is only
# sound while a plan says WHAT TO COMPUTE rather than WHAT WAS COMPUTED,
# and it did not: an unfiltered COUNT(*) and a GEN_ID read were worked
# out at PREPARE and carried in the plan, so the second ask answered the
# first ask's number. The same text is sent twice here with a write in
# between, and both servers must move.
FRESH='SET HEADING OFF;
CREATE TABLE F (ID INTEGER);
CREATE SEQUENCE FG;
COMMIT;
INSERT INTO F VALUES (1);
COMMIT;
SELECT COUNT(*) FROM F;
SELECT GEN_ID(FG, 0) FROM RDB$DATABASE;
INSERT INTO F VALUES (2);
SELECT GEN_ID(FG, 5) FROM RDB$DATABASE;
COMMIT;
SELECT COUNT(*) FROM F;
SELECT GEN_ID(FG, 0) FROM RDB$DATABASE;'
fresh() { # <conn>
    printf '%s\n' "$FRESH" | "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ','
}
E2="$D/fc-meta-fresh-engine.fdb"; rm -f "$E2"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$E2' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
chmod 666 "$E2"
eng_fresh=$(fresh "$E2")
A2="$D/fc-meta-fresh-crab.fdb"; rm -f "$A2"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$A2' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
chmod 666 "$A2"
check "a kept plan does not freeze COUNT(*) or a GEN_ID read" \
      "$(fresh "127.0.0.1/$PORT:$A2")" "$eng_fresh"

echo "ran $ran checks"
exit $fail
