#!/bin/bash
# DATABASE ALIASES: a client may attach to a NAME rather than a path,
# and the SERVER resolves it through databases.conf - what firebird-qa's
# '#alias' database factories rely on, and what made fire-crab fall back
# to its fixed answer for `employee.fdb` (an alias in the stock conf)
# instead of serving the sample database.
#
# The engine's rules, read from its source:
#   - alias entries are the TOP-LEVEL `name = path` lines of
#     databases.conf; a `{ ... }` block after an entry holds
#     per-database settings, not aliases;
#   - a path may carry `$(...)` macros (config_file.cpp:508-597), whose
#     directory table is common/utils.cpp:995-1080: conf/log/guard/secDb
#     at the install root, bin under `bin`, the sample database under
#     `examples/empbuild`, and so on;
#   - the attachment then reports the RESOLVED path, not the alias
#     (checked against the engine: attaching `employee` returns
#     /opt/firebird/examples/empbuild/employee.fdb as the database name).
#
# The differential is the engine, four ways:
#   1. the stock conf's `employee` / `employee.fdb` aliases resolve
#      through fire-crab to the same path the ENGINE reports for them,
#      and fire-crab really serves that file (same relation count);
#   2. a CUSTOM conf (FC_DATABASES_CONF - the system config is never
#      touched) resolves a plain alias, a $(dir_sampleDb) macro alias
#      and a $(root) macro alias;
#   3. an alias inside a per-database `{ }` settings block is NOT taken
#      as an alias, an unknown macro is NOT resolved, and a name with no
#      alias entry is used as a path unchanged;
#   4. the resolved database answers real queries (the engine's own rows).
#
#   qa/serve-real-alias.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
FCPY="${FCPY:-}"
PORT="${1:-4292}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
OWN="$D/fc-alias-own.fdb"; CONF="$D/fc-alias-databases.conf"
SAMPLE=/opt/firebird/examples/empbuild/employee.fdb

mkdir -p "$D"; rm -f "$OWN" "$CONF"
[ -f "$SAMPLE" ] || { echo "SKIP sample database not found"; exit 0; }

"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$OWN' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER);
COMMIT;
INSERT INTO T VALUES (42);
COMMIT;
EOF

# a conf of our own - the system databases.conf is never modified
cat > "$CONF" <<EOF
# fire-crab alias gate
plain_alias = $OWN
sample_alias = \$(dir_sampleDb)/employee.fdb
root_alias = \$(root)/examples/empbuild/employee.fdb
bogus_alias = \$(dir_nonesuch)/employee.fdb
blocked_alias = $OWN
{
    inner_alias = $OWN
}
EOF

strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

# --- 1. the STOCK conf's aliases, fire-crab vs the engine --------------
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-alias.log 2>&1 &
srv=$!
trap 'kill $srv $srv2 2>/dev/null; rm -f "$OWN" "$CONF"' EXIT
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

rels() { # <dsn> -> the relation count the server reports
    printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM RDB$RELATIONS;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | strip | grep -v '^$' | head -1
}
eng_rels=$(rels "$SAMPLE")
for a in employee employee.fdb; do
    check "stock conf: alias '$a' serves the sample database ($eng_rels relations)" \
          "$(rels "127.0.0.1/$PORT:$a")" "$eng_rels"
done
kill $srv 2>/dev/null; wait $srv 2>/dev/null; srv=""

# --- 2/3. a CUSTOM conf: macros, blocks, unknown macros ---------------
srv2=""
FC_DATABASES_CONF="$CONF" "$FCWIRE" serve "127.0.0.1:$((PORT + 1))" "$U" "$P" \
    >/tmp/fc-serve-alias2.log 2>&1 &
srv2=$!
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$((PORT + 1))" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# The readiness probe above answers "SOMETHING is listening", not "OUR
# server is listening". If the port was already taken, fcwire exited at
# bind and every check below runs against the OTHER server - a gate that
# reports success while measuring nothing. Fatal, not a warning.
# $srv2, NOT $srv: the first server was killed and its variable cleared
# two lines up, so checking it here tested the empty string and this gate
# exited 1 before phase 2 ever ran - the mirror of a gate that cannot
# fail is a gate that cannot pass, and both report something untrue.
kill -0 $srv2 2>/dev/null || {
    echo "FAIL fcwire is not running - port $((PORT + 1)) already in use? (see the server log)"
    exit 1
}
P2=$((PORT + 1))
own_rows() { # <dsn> -> the row our own database holds
    printf 'SET HEADING OFF;\nSELECT ID FROM T;\n' |
        "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | strip | grep -v '^$' | head -1
}
check "custom conf: a plain alias resolves" "$(own_rows "127.0.0.1/$P2:plain_alias")" "42"
check "custom conf: a \$(dir_sampleDb) macro alias resolves" \
      "$(rels "127.0.0.1/$P2:sample_alias")" "$eng_rels"
check "custom conf: a \$(root) macro alias resolves" \
      "$(rels "127.0.0.1/$P2:root_alias")" "$eng_rels"
# an unknown macro must NOT resolve: the name is then used as a path,
# which does not exist, so the server falls back to its fixed answer -
# never someone else's file
case "$(own_rows "127.0.0.1/$P2:bogus_alias")" in
    42) echo "DIFF an unknown macro resolved anyway"; fail=1 ;;
    *) echo "OK   an unknown \$(macro) does NOT resolve (no guessed path)" ;;
esac
case "$(own_rows "127.0.0.1/$P2:inner_alias")" in
    42) echo "DIFF a settings-block entry was taken as an alias"; fail=1 ;;
    *) echo "OK   an entry inside a { } settings block is not an alias" ;;
esac
# the entry that OPENS the block is still a real alias
check "custom conf: the entry preceding a { } block still resolves" \
      "$(own_rows "127.0.0.1/$P2:blocked_alias")" "42"
# a name with no alias entry is used as a PATH, unchanged
check "no alias entry: the name is used as a path" "$(own_rows "127.0.0.1/$P2:$OWN")" "42"

# --- 4. the resolved sample database answers real queries -------------
q="SELECT COUNT(*) FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = 'COUNTRY'"
engq=$(printf 'SET HEADING OFF;\n%s;\n' "$q" | "$ISQL" -q -b -user "$U" -pas "$P" "$SAMPLE" 2>&1 | strip | grep -v '^$' | head -1)
fcq=$(printf 'SET HEADING OFF;\n%s;\n' "$q" | "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$P2:sample_alias" 2>&1 | strip | grep -v '^$' | head -1)
check "the alias-resolved database answers a real query like the engine" "$fcq" "$engq"

exit $fail
