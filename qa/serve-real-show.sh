#!/bin/bash
# SHOW commands over the legacy BLR request API (op_compile / op_start /
# op_receive / op_release). isql's SHOW does NOT use DSQL - it compiles a
# GDML request (a blr_begin of blr_message declarations wrapping a
# blr_for over a system relation that blr_sends each row to the client)
# and drives it with the request ops. fire-crab now parses that BLR,
# walks the named system relation applying the request's boolean and
# sort, and ships the rows back as op_send messages - the whole batch per
# op_receive, every packet but the last carrying p_data_messages = 1 and
# the last carrying 0, which is how the client (batch_gds_receive) knows
# the batch has ended. Nullable output columns come across as
# blr_parameter2 (value + a separate short null indicator).
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
CREATE TABLE X (ID INTEGER NOT NULL, NAME VARCHAR(20));
CREATE TABLE ALPHA (A INTEGER, B VARCHAR(10));
CREATE VIEW V AS SELECT ID, NAME FROM X;
CREATE ROLE R1;
CREATE ROLE R2;
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
        r=$(timeout 12 "$ISQL" -q -b -user "$U" -pas "$P" \
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

exit $fail
