#!/bin/bash
# CREATE VIEW / DROP VIEW from fire-crab's OWN DDL. Until this slice views
# existed only from restored metadata. Now `CREATE VIEW <name> [(cols)]
# AS <select>` plans the SELECT at prepare: a plain column keeps its base
# relation's RDB$FIELD_SOURCE, RDB$BASE_FIELD and RDB$VIEW_CONTEXT; an
# expression column gets an auto-domain RDB$<n> of its type (precision by
# storage width) carrying the expression's BLR over the view's streams in
# RDB$COMPUTED_BLR (no source - probed); the FROM items are the contexts
# (1.. in order, the alias quoted or "PUBLIC"."T"); RDB$VIEW_BLR is the
# dsql crate's byte-for-byte RSE; dbkey length 8 per context, a security
# class and a default class like a table's. The proof that matters: the
# ENGINE opens fc's file and runs fc's BLR - same rows as its own views.
# Errors: a duplicate name (CREATE VIEW failed / Table already exists), a
# missing DROP VIEW (the nested -607 "View does not exist"), DROP VIEW of a
# table (the same). Boundaries: WITH CHECK OPTION, UNION views, derived
# tables / CTEs in the FROM, an expression the dsql crate cannot compile.
#
#   qa/serve-real-createview.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4885}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-createview-crab.fdb"
B="$D/fc-createview-engine.fdb"
LOG="/tmp/fc-serve-createview-$PORT.log"
FBINC="${FBINC:-/opt/firebird/include}"; FBLIB="${FBLIB:-/opt/firebird/lib}"
mkdir -p "$D"
fail=0; ran=0
command -v gcc >/dev/null 2>&1 || { echo "SKIP gcc not found"; exit 0; }
gcc -O0 -o "$D/sqlerr-$(basename "$0" .sh)" "$(dirname "$0")/c/sqlerr.c" -I"$FBINC" -L"$FBLIB" -lfbclient -Wl,-rpath,"$FBLIB" 2>/dev/null || { echo "FAIL compile sqlerr"; exit 1; }
make_db() {
    rm -f "$1"
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(5), N INTEGER, C CHAR(3));
CREATE TABLE U (ID INTEGER NOT NULL PRIMARY KEY, TID INTEGER, W INTEGER);
COMMIT;
INSERT INTO T VALUES (1, 'a', 1, 'x'); INSERT INTO T VALUES (2, 'b', 0, 'y'); INSERT INTO T VALUES (3, 'c', 5, NULL);
INSERT INTO U VALUES (10, 1, 100); INSERT INTO U VALUES (11, 3, 300); INSERT INTO U VALUES (12, 3, 301);
COMMIT;
EOF
    chmod 666 "$1"
}
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
FC_SRV_TRACE=1 "$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
script1() { cat <<'SQL'
CREATE VIEW VW AS SELECT ID, V FROM T WHERE N > 0;
CREATE VIEW VW2 (A, B) AS SELECT ID, V || 'x' FROM T;
CREATE VIEW VW3 AS SELECT a.ID AS AID, b.V, a.N + 1 AS NP FROM T a JOIN T b ON b.ID = a.ID WHERE a.N > 0;
CREATE VIEW VW4 AS SELECT ID, N * 2 AS N2, UPPER(V) AS UV, C FROM T WHERE ID <> 2;
CREATE VIEW VW5 AS SELECT t.ID, u.W FROM T t LEFT JOIN U u ON u.TID = t.ID;
COMMIT;
SELECT * FROM VW ORDER BY ID;
SELECT * FROM VW2 ORDER BY A;
SELECT * FROM VW3 ORDER BY AID;
SELECT * FROM VW4 ORDER BY ID;
SELECT * FROM VW5 ORDER BY ID, W;
SELECT A FROM VW2 WHERE B = 'bx';
SELECT COUNT(*) FROM VW5 WHERE W IS NULL;
SQL
}
e=$(script1 | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script1 | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "CREATE VIEW x5 and the reads through the server" "$c" "$e"
script2() { cat <<'SQL'
SELECT * FROM VW ORDER BY ID;
SELECT * FROM VW2 ORDER BY A;
SELECT * FROM VW3 ORDER BY AID;
SELECT * FROM VW4 ORDER BY ID;
SELECT * FROM VW5 ORDER BY ID, W;
SET LIST ON;
SELECT RDB$RELATION_NAME, RDB$RELATION_TYPE, RDB$FORMAT, RDB$FIELD_ID, RDB$DBKEY_LENGTH, RDB$FLAGS, RDB$OWNER_NAME FROM RDB$RELATIONS WHERE RDB$RELATION_NAME STARTING WITH 'VW' ORDER BY 1;
SELECT rf.RDB$RELATION_NAME, rf.RDB$FIELD_NAME, rf.RDB$FIELD_SOURCE, rf.RDB$VIEW_CONTEXT, rf.RDB$BASE_FIELD, rf.RDB$FIELD_POSITION, rf.RDB$UPDATE_FLAG, f.RDB$FIELD_TYPE, f.RDB$FIELD_LENGTH, f.RDB$FIELD_PRECISION, f.RDB$CHARACTER_LENGTH, f.RDB$FIELD_SCALE, f.RDB$FIELD_SUB_TYPE, f.RDB$CHARACTER_SET_ID FROM RDB$RELATION_FIELDS rf JOIN RDB$FIELDS f ON f.RDB$FIELD_NAME = rf.RDB$FIELD_SOURCE WHERE rf.RDB$RELATION_NAME STARTING WITH 'VW' ORDER BY 1, rf.RDB$FIELD_POSITION;
SELECT RDB$VIEW_NAME, RDB$RELATION_NAME, RDB$VIEW_CONTEXT, RDB$CONTEXT_NAME, RDB$CONTEXT_TYPE FROM RDB$VIEW_RELATIONS ORDER BY 1, 3;
SELECT r.RDB$RELATION_NAME, r.RDB$VIEW_SOURCE FROM RDB$RELATIONS r WHERE r.RDB$RELATION_NAME STARTING WITH 'VW' ORDER BY 1;
SQL
}
e=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | grep -v 'RDB$VIEW_SOURCE *[0-9a-f]*:[0-9a-f]*' | norm)
c=$(script2 | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | grep -v 'RDB$VIEW_SOURCE *[0-9a-f]*:[0-9a-f]*' | norm)
check "the ENGINE reads fc's views (BLR + catalog rows)" "$c" "$e"
e=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$REAL:$B" "CREATE VIEW VW AS SELECT ID FROM T" "DROP VIEW NOPE" "DROP VIEW T" "DROP VIEW VW2" COMMIT "DROP VIEW VW2" 2>&1 | norm)
c=$("$D/sqlerr-$(basename "$0" .sh)" "127.0.0.1/$PORT:$A" "CREATE VIEW VW AS SELECT ID FROM T" "DROP VIEW NOPE" "DROP VIEW T" "DROP VIEW VW2" COMMIT "DROP VIEW VW2" 2>&1 | norm)
check "duplicate / missing / not-a-view vectors, DROP VIEW round trip" "$c" "$e"
script4() { cat <<'SQL'
SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'VW2';
SELECT COUNT(*) FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'VW2';
SELECT COUNT(*) FROM RDB$VIEW_RELATIONS WHERE RDB$VIEW_NAME = 'VW2';
SELECT COUNT(*) FROM RDB$FIELDS WHERE RDB$FIELD_NAME = 'RDB$4';
SELECT * FROM VW3 ORDER BY AID;
SQL
}
e=$(script4 | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
c=$(script4 | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
check "DROP VIEW leaves no row behind, the others still answer" "$c" "$e"
echo "ran $ran checks"
exit $fail
