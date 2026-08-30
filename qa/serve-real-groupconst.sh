#!/bin/bash
# A projected CONSTANT in a GROUPED query - SELECT 42, COUNT(*) FROM T
# GROUP BY V. The engine answers a constant (a literal or a constant
# expression, referencing no column) once per group; this server refused
# ANY non-key projected expression with a bare "Dynamic SQL Error". The
# group builder now recognises a column-free item, gives it a placeholder
# group slot and carries the expression on its output column, so the
# constant rides through the fold untouched.
#
# Covered across all three grouped shapes (they share build_group_items):
# plain GROUP BY, an implicit whole-table aggregate, a grouped JOIN and a
# grouped derived table. A constant anywhere in the select list, alone, or
# beside keys and aggregates.
#
# This is the prerequisite for a `?` projection parameter in a grouped
# query (a typed CAST(? AS ..) is a column-free item too) - that rides on
# this in its own slice.
#
# BOUNDARY (left out, still refused): an expression OVER a grouping column
# - SELECT V*2 ... GROUP BY V - which the engine answers (V is
# functionally determined) but this server does not yet; it needs the
# expression evaluated over the group's key slots, a separate slice.
#
#   qa/serve-real-groupconst.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4751}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
mkdb() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V INTEGER, NN INTEGER NOT NULL, S VARCHAR(4) NOT NULL);
CREATE TABLE U (ID INTEGER, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1,10,7,'a'); INSERT INTO T VALUES (2,10,8,'b'); INSERT INTO T VALUES (3,20,9,'c');
INSERT INTO U VALUES (1,100); INSERT INTO U VALUES (3,300);
COMMIT;
EOF
}
EDB="$D/fc-groupconst-e.fdb"; FDB="$D/fc-groupconst-f.fdb"
mkdb "localhost:$EDB"; mkdb "$FDB"; chmod 666 "$EDB" "$FDB" 2>/dev/null

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-groupconst-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT in use?"; exit 1; }

# reduce an answer to its numbers, or the ERROR CLASS, so spacing and the
# engine's longer message text never read as a divergence
red() { printf 'SET HEADING OFF;\n%s;\n' "$2" |
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 |
    grep -v '^$' | grep -oiE 'error|-?[0-9]+' | tr '\n' ' '; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { # <sql>
    local e c
    e=$(red "$E" "$1"); c=$(red "$F" "$1")
    ran=$((ran + 1))
    if [ "$e" = "$c" ]; then echo "OK   $1 [$e]"
    else echo "DIFF $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
# a constant anywhere: leading, between key and aggregate, trailing
both "SELECT 42, COUNT(*) FROM T GROUP BY V"
both "SELECT V, 42, COUNT(*) FROM T GROUP BY V"
both "SELECT COUNT(*), 42 FROM T GROUP BY V"
# a constant EXPRESSION folds to its value
both "SELECT 1+2, COUNT(*) FROM T GROUP BY V"
# a constant-only grouped projection (no aggregate in the list)
both "SELECT 42 FROM T GROUP BY V"
# the implicit whole-table aggregate takes a constant too
both "SELECT 42, SUM(V) FROM T"
both "SELECT 42, COUNT(*) FROM T"
# beside a key and an aggregate, with an ORDER BY
both "SELECT V, 99, SUM(V) FROM T GROUP BY V ORDER BY V"
# a grouped JOIN and a grouped DERIVED table (same builder)
both "SELECT 7, COUNT(*) FROM T JOIN U ON T.ID = U.ID GROUP BY T.V"
both "SELECT 7, COUNT(*) FROM (SELECT V FROM T) X GROUP BY X.V"
# --- the NULLABLE BIT of a grouped select-list EXPRESSION ------------------
# `plan_group` had a nullability pass covering only the plain group KEYS,
# so every grouped EXPRESSION kept the bit `build_expr_col_from` stamped
# and came back Nullable: `SELECT 1 FROM T GROUP BY 1` and `SELECT NN+1
# FROM T GROUP BY 1` both described Nullable where the engine does not,
# while a grouped plain FIELD was already right. Every Project and Join
# site calls `mark_not_null_cols`; this one never did.
#
# The values agree throughout - this is the describe alone - so it needs
# its own comparison rather than the value one above.
#
# THE FOLDS KEEP THEIR OWN RULE and must not be dragged into the
# expression rule. A fold's output slot is POSITIONAL (`GItem::Agg`
# carries no field id) and is therefore absent from the not-null field
# set, so the ordinary expression rule calls it nullable - which is wrong
# for COUNT and for the whole VAR/STDDEV family, which answer 0 rather
# than NULL. Marking those Nullable did not merely mis-describe them: it
# made `VAR_SAMP(N) + 1` over an empty set answer <null> where the engine
# answers 0.0, because the announced bit decides whether the bytes are
# shipped at all (caught by serve-real-statexpr). The fold cases below
# are the guard against that returning.
dsc() { # <dsn> <sql>
    printf 'SET SQLDA_DISPLAY ON;\nSET LIST ON;\n%s;\n' "$2" |
        "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 |
        grep -aE '^[0-9]{2}: sqltype' | tr -s ' ' | tr '\n' '|'
}
dboth() { # <sql>
    local e c
    e=$(dsc "$E" "$1"); c=$(dsc "$F" "$1")
    ran=$((ran + 1))
    if [ "$e" = "$c" ] && [ -n "$e" ]; then echo "OK   describe $1 [$e]"
    else echo "DIFF describe $1"; echo "     engine: [$e]"; echo "     fcrab:  [$c]"; fail=1; fi
}
dboth "SELECT 1 FROM T GROUP BY 1"
dboth "SELECT NN+1 FROM T GROUP BY 1"
dboth "SELECT V+1 FROM T GROUP BY 1"
dboth "SELECT UPPER(S) FROM T GROUP BY 1"
dboth "SELECT S || 'x' FROM T GROUP BY 1"
dboth "SELECT COALESCE(V,0) FROM T GROUP BY 1"
dboth "SELECT NN FROM T GROUP BY 1"
dboth "SELECT V FROM T GROUP BY 1"
dboth "SELECT NN+1, COUNT(*) FROM T GROUP BY 1"
dboth "SELECT 42, COUNT(*) FROM T GROUP BY V"
# the folds, which keep their own rule
dboth "SELECT COUNT(*) FROM T"
dboth "SELECT COUNT(*)+0 FROM T"
dboth "SELECT SUM(NN)+0 FROM T"
dboth "SELECT COALESCE(SUM(V),0) FROM T"
dboth "SELECT VAR_POP(V)+1 FROM T"
dboth "SELECT VAR_SAMP(V)+1 FROM T WHERE 1=0"
# ... and the ungrouped controls, which never moved
dboth "SELECT NN+1 FROM T"
dboth "SELECT 1 FROM T"

# an invalid non-key COLUMN stays refused on both (ID is not grouped) -
# the engine's message is longer, so this is pinned as "both refuse"
refuses() { # <sql>
    local e c
    e=$(printf 'SET HEADING OFF;\n%s;\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$E" 2>&1 | grep -c 'Statement failed')
    c=$(printf 'SET HEADING OFF;\n%s;\n' "$1" | "$ISQL" -q -b -user "$U" -pas "$P" "$F" 2>&1 | grep -c 'Statement failed')
    ran=$((ran + 1))
    if [ "$e" -ge 1 ] && [ "$c" -ge 1 ]; then echo "OK   $1 refuses on both"
    else echo "DIFF $1  engine_fail=$e fcrab_fail=$c"; fail=1; fi
}
refuses "SELECT ID, COUNT(*) FROM T GROUP BY V"

echo "ran $ran checks"
exit $fail
