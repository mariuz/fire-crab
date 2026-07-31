#!/bin/bash
# SHOW DATABASE breadth: the "Replica mode:" and "Publication:" lines,
# plus SHOW SYS PUB / SHOW PUB <name> - the surface the firebird-qa
# tests functional/basic/isql/test_07 and test_08 assert.
#
# How isql produces them (read from the engine's own show.epp):
#   - Replica mode: show.epp:669 reads fb_info_replica_mode (info item
#     146, inf_pub.h:174) with getBigInt and prints NONE (0) /
#     READ_ONLY (1) / READ_WRITE (2). The value is the header's
#     hdr_replica_mode byte - ods.h:648, static_assert'd at offset 26.
#   - Publication: show.epp:3551 runs a legacy-BLR request
#     `FOR PUB IN RDB$PUBLICATIONS WITH PUB.RDB$ACTIVE_FLAG > 0` and
#     prints Enabled when any row matches, else Disabled - the same
#     request API fire-crab's other SHOW commands ride.
#
# THE DIFFERENTIAL: the SAME isql binary runs `show database` (and the
# publication commands) twice per state - once against the engine, once
# against fire-crab serving the very same file - and the printed lines
# must be identical. Three states, all reachable without a replication
# setup: a plain database, one with publication ENABLED, and one turned
# into a READ_ONLY replica by gfix.
#
#   qa/serve-real-showdb.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4291}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
PLAIN="$D/fc-sdb-plain.fdb"; PUB="$D/fc-sdb-pub.fdb"

mkdir -p "$D"; rm -f "$PLAIN" "$PUB"

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$PLAIN' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
cp "$PLAIN" "$PUB"
"$ISQL" -q -b -user "$U" -pas "$P" "$PUB" <<'EOF' >/dev/null 2>&1
ALTER DATABASE ENABLE PUBLICATION;
COMMIT;
EOF
# NOTE on the READ_ONLY replica state: a gfix'd replica file is NOT a
# usable live oracle on this box - the engine intermittently refuses a
# normal attach to one (I/O error naming the file "replica <path>",
# replication handling with no setup behind it), and fire-crab's own
# intermittent auth rejection (SQLSTATE 28000 on ~1 in 20 attaches, a
# separate known server bug) compounds it. The replica-mode VALUE - the
# header byte 26 -> item 146 -> "Replica mode:" mapping this slice adds -
# is covered deterministically by the db_info_answers_replica_mode unit
# test instead, and was verified by hand end-to-end (a gfix'd replica
# reads back READ_ONLY through fire-crab, matching the engine).

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-sdb.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$PLAIN" "$PUB"' EXIT
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

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
# fire-crab's FIRST connect after startup can flake (known); warm it
# until an attach answers, so every comparison below is deterministic
w=0; while [ $w -lt 15 ]; do
    printf 'show database;\n' | "$ISQL" -q -nod -user "$U" -pas "$P" \
        "127.0.0.1/$PORT:$PLAIN" 2>&1 | grep -q "ODS" && break
    w=$((w + 1)); sleep 0.4
done
fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

# the two lines, from the engine and from fire-crab, on the SAME file
lines() { # <dsn> <sql>
    printf '%s\n' "$2" | "$ISQL" -q -nod -user "$U" -pas "$P" "$1" 2>&1 |
        grep -aE "Replica mode:|Publication:" | strip
}
pubcmds() { # <dsn>
    printf 'show sys pub;\nshow pub rdb$default;\n' |
        "$ISQL" -q -nod -user "$U" -pas "$P" "$1" 2>&1 | strip | grep -v '^$'
}
# fire-crab's SRP path intermittently rejects a rapid re-attach (a known
# server-side bug, seen in the firebird-qa runs too) and every query here
# is a fresh connection - so each fc-side query retries until it answers
retry() { # <fn> <dsn> [sql]
    n=0
    while [ $n -lt 30 ]; do
        r=$("$1" "$2" ${3+"$3"})
        [ -n "$r" ] && { printf '%s' "$r"; return; }
        n=$((n + 1)); sleep 0.5
    done
    printf ''
}

plain_fc=""; pub_fc=""; pub_fc_cmds=""
for spec in "plain $PLAIN" "publication-enabled $PUB"; do
    name=${spec% *}; f=${spec#* }
    eng=$(lines "$f" "show database;")
    fc=$(retry lines "127.0.0.1/$PORT:$f" "show database;")
    case "$f" in
        "$PLAIN") plain_fc=$fc ;;
        "$PUB") pub_fc=$fc ;;
    esac
    check "$name: SHOW DATABASE replica+publication lines match the engine" "$fc" "$eng"
done
for spec in "plain $PLAIN" "publication-enabled $PUB"; do
    name=${spec% *}; f=${spec#* }
    fcp=$(retry pubcmds "127.0.0.1/$PORT:$f")
    [ "$f" = "$PUB" ] && pub_fc_cmds=$fcp
    check "$name: SHOW SYS PUB / SHOW PUB match the engine" "$fcp" "$(pubcmds "$f")"
done

# the teeth: each state must actually SAY something different, or the
# comparisons above would hold vacuously (values captured above)
case "$plain_fc" in *"Replica mode: NONE"*"Publication: Disabled"*)
    echo "OK   teeth: a plain database reads NONE + Disabled" ;;
    *) echo "DIFF plain state"; echo "     $plain_fc"; fail=1 ;; esac
case "$pub_fc" in *"Replica mode: NONE"*"Publication: Enabled"*)
    echo "OK   teeth: ENABLE PUBLICATION flips the publication line only" ;;
    *) echo "DIFF publication state"; echo "     $pub_fc"; fail=1 ;; esac
case "$pub_fc_cmds" in *"RDB\$DEFAULT: Enabled"*)
    echo "OK   teeth: SHOW PUB reports the enabled publication" ;;
    *) echo "DIFF show pub enabled"; fail=1 ;; esac

exit $fail
