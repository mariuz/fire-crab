#!/bin/bash
# SHOW commands over the legacy BLR request API (op_compile / op_start /
# op_receive / op_release). isql's SHOW does NOT use DSQL - it compiles a
# GDML request (a blr_begin of blr_message declarations wrapping a
# blr_for over one or more system relations that blr_sends each row to the
# client) and drives it with the request ops. fire-crab parses that BLR,
# walks the named system relations - joining them with a nested loop when
# there is more than one stream (SHOW INDICES is RDB$INDICES CROSS
# RDB$RELATIONS; SHOW TABLE joins RDB$RELATION_FIELDS to RDB$FIELDS) -
# applies the request's boolean (blr_equiv null-safe joins, blr_starting,
# blr_matching2 the legacy SLEUTH name filter, blr_value_if, comparisons)
# and sort, and ships each row as an op_send.
#
# Two shapes of the protocol make the multi-request SHOWs work: each
# op_compile gets its own handle (SHOW INDICES / SHOW TABLE keep an outer
# request open while, per row, running an inner one - a single request
# slot would clobber the outer), and each op_receive is answered with
# exactly ONE message flagged p_data_messages = 0 (shipping a whole batch
# ahead of demand would have the inner request read the outer's rows and
# desync the stream).
#
# The oracle is the engine: each SHOW runs IDENTICALLY through fire-crab
# (isql -> fcwire serve) and through isql on the same file; output
# compared verbatim.
#
#   qa/serve-real-show.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4094}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
DIR="/tmp/fbhandson"
SRC="$DIR/show_src.fdb"; WORK="/tmp/fc-show-work.fdb"

mkdir -p "$DIR"
rm -f "$SRC" "$WORK"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db creation"; exit 1; }
CREATE DATABASE '$SRC' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE DEPT (DID INTEGER NOT NULL PRIMARY KEY, DNAME VARCHAR(30) NOT NULL);
CREATE TABLE X (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(20), DID INTEGER,
                FOREIGN KEY (DID) REFERENCES DEPT(DID));
CREATE TABLE ALPHA (A INTEGER, B VARCHAR(10));
CREATE VIEW V AS SELECT ID, NAME FROM X;
CREATE INDEX X_NAME_IDX ON X (NAME);
CREATE ROLE R1;
CREATE ROLE R2;
CREATE SEQUENCE SEQ_A;
CREATE SEQUENCE SEQ_B START WITH 100;
CREATE GENERATOR GEN_C;
CREATE TABLE Z (ID INTEGER);
CREATE EXCEPTION E_FIRST 'the first exception message';
CREATE EXCEPTION E_UNUSED 'nobody uses me';
COMMIT;
-- a procedure that raises E_FIRST and writes Z gives E_FIRST a dependency
-- for SHOW EXCEPTION's "Used by:" list, and gives SHOW PROCEDURES a
-- procedure with its own dependencies - Z (Table) once (its field-level
-- and table-level rows folded by the blr_project DISTINCT) and E_FIRST
-- (Exception). Z is not SHOW TABLE'd by this gate.
SET TERM ^;
CREATE PROCEDURE P_USE AS
BEGIN EXCEPTION E_FIRST; INSERT INTO Z (ID) VALUES (1); END^
CREATE PROCEDURE P_ARGS (X INTEGER) RETURNS (Y INTEGER) AS
BEGIN Y = X + 1; SUSPEND; END^
SET TERM ;^
COMMIT;
SET GENERATOR GEN_C TO 4242;
ALTER SEQUENCE SEQ_A RESTART WITH 7;
COMMIT;
EOF
cp "$SRC" "$WORK"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-show.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

# fire-crab side: isql through fcwire. Retry on a transient connection
# error (the first attach after startup can race).
fc_show() { # <show-command>
    n=0
    while [ $n -lt 8 ]; do
        # -s KILL: isql traps SIGTERM, so a plain timeout would not stop a
        # genuine hang - use SIGKILL so a regression fails loud, not slow
        r=$(timeout -s KILL 15 "$ISQL" -q -b -user "$U" -pas "$P" \
              "localhost/$PORT:$WORK" 2>&1 <<EOF
$1;
EOF
)
        case "$r" in
            *08006*|*28000*|*"Unable to complete"*|*"connection rejected"*|"")
                # transient cold-start races (connection reset, or the
                # attach landing before the server settled) - retry
                n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s\n' "$r"; return ;;
        esac
    done
    printf '%s\n' "$r"
}
en_show() { # <show-command>
    "$ISQL" -q -b -user "$U" -pas "$P" "$SRC" 2>&1 <<EOF
$1;
EOF
}

fail=0
compare() { # <label> <show-command>
    fc=$(fc_show "$2" | strip)
    en=$(en_show "$2" | strip)
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     engine: $(echo $en)"
        echo "     fc:     $(echo $fc)"
        fail=1
    fi
}

# single-relation SHOW requests: a blr_for over one system relation with
# a system-flag / not-null boolean and a name sort
compare "SHOW TABLES"       "SHOW TABLES"
compare "SHOW VIEWS"        "SHOW VIEWS"
compare "SHOW ROLES"        "SHOW ROLES"
compare "SHOW FUNCTIONS"    "SHOW FUNCTIONS"
compare "SHOW PROCEDURES"   "SHOW PROCEDURES"
compare "SHOW PACKAGES"     "SHOW PACKAGES"
compare "SHOW FILTERS"      "SHOW FILTERS"
compare "SHOW PUBLICATIONS" "SHOW PUBLICATIONS"

# multi-relation / joined SHOW requests
#  - SHOW INDICES: RDB$INDICES CROSS RDB$RELATIONS (a two-stream join)
#  - SHOW DOMAINS / SHOW COLLATIONS: blr_matching2 excludes system names
#  - SHOW TABLE <name>: a fan of requests (relation, columns joined to
#    RDB$FIELDS with their types, primary/foreign-key constraints, indices)
#    all kept open at once and driven per row
compare "SHOW INDICES"      "SHOW INDICES"
compare "SHOW DOMAINS"      "SHOW DOMAINS"
compare "SHOW COLLATIONS"   "SHOW COLLATIONS"
compare "SHOW TABLE DEPT"   "SHOW TABLE DEPT"
compare "SHOW TABLE X"      "SHOW TABLE X"
compare "SHOW TABLE ALPHA"  "SHOW TABLE ALPHA"

# SHOW GENERATORS: the outer request lists the generators (a blr_for over
# RDB$GENERATORS sorted by schema/name), then per generator isql reads the
# current value with a DSQL probe SELECT GEN_ID(name, 0) FROM RDB$DATABASE
# - which arrives as op_exec_immediate2 and is answered from the generator
# page - and an inner request reads its initial value and increment. The
# named forms exercise the value-probe path for one generator; the missing
# name exercises "no such generator".
compare "SHOW GENERATORS"      "SHOW GENERATORS"
compare "SHOW SEQUENCES"       "SHOW SEQUENCES"
compare "SHOW GENERATOR SEQ_A" "SHOW GENERATOR SEQ_A"
compare "SHOW SEQUENCE SEQ_B"  "SHOW SEQUENCE SEQ_B"
compare "SHOW GENERATOR GEN_C" "SHOW GENERATOR GEN_C"

# exceptions: SHOW EXCEPTIONS lists <schema>.<name>; Msg: <message>. The
# singular SHOW EXCEPTION <name> adds a "Used by:" dependency list read
# from RDB$DEPENDENCIES (a procedure that raises it, here) - the second
# request the plural form does not run.
compare "SHOW EXCEPTIONS"        "SHOW EXCEPTIONS"
compare "SHOW EXCEPTION used"    "SHOW EXCEPTION E_FIRST"
compare "SHOW EXCEPTION unused"  "SHOW EXCEPTION E_UNUSED"

# the singular SHOW PROCEDURE <name> renders the PSQL source text (a blob
# the client opens through op_open_blob) between "====" rules, and a
# Parameters list for a procedure that has any
compare "SHOW PROCEDURE no-args" "SHOW PROCEDURE P_USE"
compare "SHOW PROCEDURE args"    "SHOW PROCEDURE P_ARGS"

exit $fail
