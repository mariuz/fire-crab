#!/bin/bash
# VIEWS - querying a view the ENGINE created.
#
# The engine stores a view twice: as BLR in RDB$RELATIONS.RDB$VIEW_BLR,
# which its RSE machinery merges into the outer request, and as the
# SELECT TEXT in RDB$VIEW_SOURCE. fire-crab reads the TEXT and EXPANDS
# it - the same choice PSQL execution makes, and for the same reason: it
# works on views fire-crab did not create, which is the case that
# matters. EVERY view below is created by the engine with isql and only
# ever queried through fire-crab.
#
# A view's own column names live in RDB$RELATION_FIELDS and line up
# POSITIONALLY with its source's select list - a renaming view
# (`CREATE VIEW VR (K, VAL) AS SELECT ID, A FROM T`) stores a source
# with no trace of K or VAL, so the rename has to come from the catalog.
# That is the case a text-only implementation gets wrong.
#
# Expansion rewrites the outer query: the view name becomes the base
# table, view column names become base column names, and the view's own
# WHERE is ANDed with the outer one - so everything a plain table query
# supports works over a view.
#
# THE DIFFERENTIAL: the same isql runs the same SELECT against the engine
# and against fire-crab, and the row sets must match.
#
#   qa/serve-real-view.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4381}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DB="$D/fc-view.fdb"

mkdir -p "$D"; rm -f "$DB"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$DB' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, S VARCHAR(10), N NUMERIC(9,2));
COMMIT;
INSERT INTO T VALUES (1, 10, 'x', 12.50);
INSERT INTO T VALUES (2, 20, 'y', 1.25);
INSERT INTO T VALUES (3, 30, 'z', 13.50);
INSERT INTO T VALUES (4, NULL, NULL, NULL);
COMMIT;
CREATE VIEW V AS SELECT ID, A, S FROM T;
CREATE VIEW VW AS SELECT ID, A FROM T WHERE A > 15;
CREATE VIEW VR (K, VAL) AS SELECT ID, A FROM T;
CREATE VIEW VRW (K, VAL) AS SELECT ID, A FROM T WHERE A IS NOT NULL;
CREATE VIEW VSUB AS SELECT ID, N FROM T;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-view.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DB"' EXIT
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

fail=0
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$fc" = "$en" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"; echo "     engine: [$en]"; echo "     fc:     [$fc]"; fail=1
    fi
}

# --- a plain view ------------------------------------------------------
same "all columns"                 "SELECT ID, A, S FROM V"
same "SELECT * over a view"        "SELECT * FROM V"
same "a subset of the columns"     "SELECT S FROM V"
same "a WHERE on the view"         "SELECT A FROM V WHERE ID = 2"
same "a text WHERE on the view"    "SELECT ID FROM V WHERE S = 'y'"
same "ORDER BY over a view"        "SELECT ID FROM V ORDER BY ID DESC"
same "COUNT(*) over a view"        "SELECT COUNT(*) FROM V"
same "an aggregate over a view"    "SELECT SUM(A) FROM V"
same "NULLs come through a view"   "SELECT ID, A FROM V WHERE A IS NULL"

# --- a view that carries its OWN WHERE ---------------------------------
same "the view's WHERE applies"    "SELECT ID FROM VW"
same "both WHEREs apply"           "SELECT ID FROM VW WHERE ID < 3"
same "COUNT respects the view's WHERE" "SELECT COUNT(*) FROM VW"
same "the view's WHERE plus ORDER BY"  "SELECT ID FROM VW ORDER BY ID DESC"

# --- a RENAMING view: the names exist only in the catalog --------------
same "renamed columns"             "SELECT K, VAL FROM VR"
same "SELECT * over a renaming view"   "SELECT * FROM VR"
same "a WHERE on a renamed column" "SELECT VAL FROM VR WHERE K = 2"
same "ORDER BY a renamed column"   "SELECT K FROM VR ORDER BY VAL DESC"
same "an aggregate over renamed columns" "SELECT SUM(VAL) FROM VR"
same "renaming AND the view's own WHERE" "SELECT K, VAL FROM VRW"
same "a WHERE on both"             "SELECT K FROM VRW WHERE VAL > 15"

# --- scaled column through a view --------------------------------------
same "NUMERIC through a view"      "SELECT ID, N FROM VSUB"
same "NUMERIC arithmetic over a view"  "SELECT N + 1 FROM VSUB WHERE ID = 1"

# --- teeth -------------------------------------------------------------
# 1. the view's own WHERE must really filter: V and VW must DIFFER
a=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM V;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
b=$(printf 'SET HEADING OFF;\nSELECT COUNT(*) FROM VW;\n' |
    "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -d ' \n')
if [ "$a" = "4" ] && [ "$b" = "2" ]; then
    echo "OK   teeth: the view's own WHERE filters ($a rows vs $b)"
else
    echo "DIFF V has $a rows and VW $b, want 4 and 2"; fail=1
fi

# 2. the RENAME must really be in play: the base names must NOT resolve
#    through a renaming view (the engine rejects them, so must fire-crab)
out=$(printf 'SELECT ID FROM VR;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
eng=$(printf 'SELECT ID FROM VR;\n' |
      "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
case "$out$eng" in
    *"Statement failed"*)
        if [ -n "$out" ] && [ -n "$eng" ]; then
            echo "OK   teeth: a base column name does not leak through the rename"
        else
            echo "DIFF rename leak: fc=[$out] engine=[$eng]"; fail=1
        fi ;;
    *) echo "DIFF a base column name resolved through the rename: fc=[$out] engine=[$eng]"; fail=1 ;;
esac

# 3. a view over a JOIN - answered now that a view is a ROW SOURCE
#    rather than a rewrite against base tables, so the view's own join
#    is simply an inner plan. Compared through the ENGINE'S OWN isql,
#    verbatim, because the rendered widths are part of the answer.
"$ISQL" -q -b -user "$U" -pas "$P" "$DB" >/dev/null 2>&1 <<'SQL'
CREATE TABLE U2 (ID INTEGER NOT NULL PRIMARY KEY, W INTEGER);
COMMIT;
INSERT INTO U2 VALUES (1, 100);
INSERT INTO U2 VALUES (2, 200);
COMMIT;
CREATE VIEW VJ AS SELECT T.ID, U2.W FROM T JOIN U2 ON U2.ID = T.ID;
COMMIT;
SQL
for q in 'SELECT ID, W FROM VJ ORDER BY ID' 'SELECT COUNT(*) FROM VJ' \
         'SELECT W FROM VJ WHERE ID = 1'; do
    out=$(printf '%s;\n' "$q" |
          "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$DB" 2>&1 | tr -s ' \n' ' ')
    eng=$(printf '%s;\n' "$q" |
          "$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>&1 | tr -s ' \n' ' ')
    if [ "$out" = "$eng" ] && [ -n "$eng" ]; then
        echo "OK   a view over a JOIN: $q"
    else
        echo "DIFF a view over a JOIN: $q"
        echo "     fcwire: [$out]"
        echo "     engine: [$eng]"
        fail=1
    fi
done

exit $fail
