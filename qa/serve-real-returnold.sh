#!/bin/bash
# THE ROW CONTEXTS OF `RETURNING`: OLD. and NEW.
#
# An UPDATE has TWO rows and names them - `OLD.<col>` is the
# before-image, `NEW.<col>` the after-image, and a BARE name is NEW. An
# INSERT and a DELETE have ONE row and no contexts at all: the engine
# answers -206 `Column unknown "NEW"."ID"` there, even for a column that
# exists.
#
# This server had recorded the opposite - "NEW./OLD. do not exist in
# DSQL" - which was right for the INSERT it was probed on and wrong for
# UPDATE, so every `RETURNING OLD.x` refused. It now answers them: the
# BEFORE image is appended to each returned row and an `OLD.` reference
# resolves there, as a plain column or inside an expression.
#
#   qa/serve-real-returnold.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4933}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-returnold-crab.fdb"
B="$D/fc-returnold-engine.fdb"
LOG="/tmp/fc-serve-returnold-$PORT.log"
mkdir -p "$D"
fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
CREATE TABLE T (ID INTEGER NOT NULL, N INTEGER, S VARCHAR(20), D DATE);
CREATE TABLE O (ID INTEGER, K INTEGER);
COMMIT;
INSERT INTO O VALUES (1, 100);
INSERT INTO T VALUES (1, 10, 'a', DATE '2020-01-01');
INSERT INTO T VALUES (2, 20, 'b', DATE '2021-06-30');
INSERT INTO T VALUES (3, NULL, NULL, NULL);
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
both() {
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
# BOTH sides must refuse - the engine with a -206 this server has no
# machinery for, so the VECTORS are not compared, only the refusal
both_refuse() {
    ran=$((ran + 1))
    r=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1)
    case "$r" in *"Dynamic SQL Error"*) ;; *)
        echo "DIFF fire-crab ANSWERED where the engine refuses: $1"; echo "     [$r]"; fail=1; return;; esac
    case "$e" in *"Dynamic SQL Error"*)
        echo "OK   both refuse (the engine's -206 is not reproduced): $1" ;;
      *) echo "DIFF the ENGINE answers it - this is not a shared refusal: $1"; echo "     [$e]"; fail=1;; esac
}
# fire-crab refuses where the ENGINE ANSWERS - a recorded boundary
refuses() {
    ran=$((ran + 1))
    r=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
    e=$(printf 'SET LIST ON;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1)
    case "$r:$e" in
        *"Dynamic SQL Error"*) case "$e" in
            *"Dynamic SQL Error"*) echo "DIFF the ENGINE refuses it too - the shape proves nothing: $1"; fail=1 ;;
            *) echo "OK   refuses (the engine answers): $1" ;;
        esac ;;
        *) echo "DIFF ANSWERED where a refusal was recorded: $1"; echo "     [$r]"; fail=1 ;;
    esac
}

both "the rows landed the same on both sides" "SELECT ID, N, S, D FROM T ORDER BY ID;"

# ---- the two rows of an UPDATE ------------------------------------------
both "OLD, NEW and a BARE name (which is NEW)" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING OLD.N, NEW.N, N; ROLLBACK;"
both "the target's own name is the after-image too" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING T.N, OLD.N; ROLLBACK;"
both "several rows, each with its own before-image" \
  "UPDATE T SET N = COALESCE(N, 0) * 2 RETURNING OLD.ID, OLD.N, NEW.N; ROLLBACK;"
both "a column the SET never touched has an OLD too" \
  "UPDATE T SET N = 99 WHERE ID = 2 RETURNING OLD.S, NEW.S, OLD.D; ROLLBACK;"
both "a NULL before-image" \
  "UPDATE T SET N = 7, S = 'x' WHERE ID = 3 RETURNING OLD.N, OLD.S, NEW.N, NEW.S; ROLLBACK;"
both "the DESCRIBE does not distinguish them" \
  "SET SQLDA_DISPLAY ON; UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING OLD.N, NEW.N, N; ROLLBACK;"
both "a lower-case qualifier" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING old.N, new.N; ROLLBACK;"
both "an UPDATE that touches NO row returns nothing" \
  "UPDATE T SET N = N + 1 WHERE ID = 99 RETURNING OLD.N, NEW.N; ROLLBACK;"

# ---- and inside an expression -------------------------------------------
both "an expression over BOTH images" \
  "UPDATE T SET N = N + 5 WHERE ID = 1 RETURNING NEW.N - OLD.N; ROLLBACK;"
both "an expression over the before-image alone" \
  "UPDATE T SET N = N + 5 WHERE ID = 1 RETURNING OLD.N * 2 AS X; ROLLBACK;"
both "inside a function call" \
  "UPDATE T SET S = 'zz' WHERE ID = 1 RETURNING UPPER(OLD.S), UPPER(NEW.S); ROLLBACK;"
both "inside a CASE" \
  "UPDATE T SET N = 1 WHERE ID = 1 RETURNING CASE WHEN OLD.N > 5 THEN 1 ELSE 0 END; ROLLBACK;"
both "a STRING LITERAL that spells OLD. is left alone" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING 'OLD.N' AS L, OLD.N; ROLLBACK;"
both "...and a column whose name merely starts with OLD" \
  "SELECT 1 AS OLDISH FROM RDB\$DATABASE;"

# ---- the one-row statements have no contexts ----------------------------
both_refuse "an INSERT's NEW." \
  "INSERT INTO T (ID, N) VALUES (9, 9) RETURNING NEW.ID; ROLLBACK;"
both_refuse "an INSERT's OLD." \
  "INSERT INTO T (ID, N) VALUES (9, 9) RETURNING OLD.ID; ROLLBACK;"
both_refuse "a DELETE's OLD." "DELETE FROM T WHERE ID = 2 RETURNING OLD.N; ROLLBACK;"
both_refuse "a DELETE's NEW." "DELETE FROM T WHERE ID = 2 RETURNING NEW.N; ROLLBACK;"
both "...while an INSERT's and a DELETE's PLAIN returning still answer" \
  "INSERT INTO T (ID, N) VALUES (9, 9) RETURNING ID, N; ROLLBACK;
   DELETE FROM T WHERE ID = 2 RETURNING ID, N; ROLLBACK;"

# ---- the star, and what may stand beside it -----------------------------
both "RETURNING * over each verb" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING *; ROLLBACK;
   INSERT INTO T (ID, N) VALUES (9, 9) RETURNING *; ROLLBACK;
   DELETE FROM T WHERE ID = 2 RETURNING *; ROLLBACK;"
both "the target's own name, and NEW., star the same row" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING T.*; ROLLBACK;
   UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING NEW.*; ROLLBACK;"
both "OLD.* is the before-image" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING OLD.*; ROLLBACK;"
both "...and the two stars together, in that order" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING OLD.*, NEW.*; ROLLBACK;"
both "a QUALIFIED star may share the list with a column" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING OLD.*, N; ROLLBACK;"
both "the describe of a star" \
  "SET SQLDA_DISPLAY ON; UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING *; ROLLBACK;"
# ...but a BARE star is a whole clause of its own: the engine's grammar
# takes it as one production, so a comma after (or before) it is -104
both_refuse "a BARE star may not share the list" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING *, OLD.N; ROLLBACK;"
both_refuse "...in either order" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING OLD.N, *; ROLLBACK;"
both_refuse "and a one-row statement has no OLD star either" \
  "INSERT INTO T (ID) VALUES (5) RETURNING OLD.*; ROLLBACK;"

# ---- the target's own ALIAS ---------------------------------------------
# `UPDATE T t SET t.N = ...` - the alias replaces the table name as the
# qualifier, and this server takes it off the statement text before any
# resolver sees it, so every shape below is the plain form it already
# handled
both "an aliased UPDATE, qualified throughout" \
  "UPDATE T t SET t.N = t.N + 1 WHERE t.ID = 1 RETURNING t.N; ROLLBACK;"
both "...with the optional AS" \
  "UPDATE T AS t SET t.N = 5 WHERE t.ID = 1 RETURNING t.N; ROLLBACK;"
both "an alias that is not the table's own letter" \
  "UPDATE T x SET x.N = x.N + 2 WHERE x.ID = 1 RETURNING x.N, x.S; ROLLBACK;"
both "an alias declared and then not used" \
  "UPDATE T t SET N = N + 1 WHERE ID = 1 RETURNING N; ROLLBACK;"
both "an aliased DELETE" "DELETE FROM T t WHERE t.ID = 2 RETURNING t.ID; ROLLBACK;"
both "the alias beside OLD. and NEW." \
  "UPDATE T t SET t.N = t.N + 1 WHERE t.ID = 1 RETURNING OLD.N, NEW.N, t.N; ROLLBACK;"
both "the alias inside a CORRELATED subquery" \
  "UPDATE T x SET x.N = (SELECT o.K FROM O o WHERE o.ID = x.ID) WHERE x.ID = 1
   RETURNING x.N; ROLLBACK;"
both "an alias-starred RETURNING" \
  "UPDATE T x SET x.N = 3 WHERE x.ID = 1 RETURNING x.*; ROLLBACK;"
both "a STRING that spells the alias is left alone" \
  "UPDATE T x SET x.S = 'x.N' WHERE x.ID = 1 RETURNING x.S; ROLLBACK;"
both "an identifier that merely BEGINS with it" \
  "UPDATE T x SET x.N = 1 WHERE x.ID = 1 AND x.S <> 'xx' RETURNING x.N; ROLLBACK;"
both_refuse "an INSERT still takes no alias, on either" \
  "INSERT INTO T t (ID) VALUES (9); ROLLBACK;"
both "...and an unaliased statement is untouched" \
  "UPDATE T SET N = (SELECT COUNT(*) FROM T) WHERE ID = 1 RETURNING N; ROLLBACK;"
# the one shape the text pass may not take: a NESTED FROM that declares
# the SAME alias for another table. Rewriting through it would answer
# the wrong rows, so the statement refuses.
refuses "a nested FROM reusing the alias" \
  "UPDATE T x SET x.N = 1 WHERE EXISTS (SELECT 1 FROM O x WHERE x.ID = 1); ROLLBACK;"

# ---- a MERGE has THREE rows to name ------------------------------------
# the target's after-image, its before-image, and the SOURCE row - and
# the engine names all three: OLD./NEW. for the target (OLD is NULL on
# an inserted row, not an error) and the source's own alias for the
# third, describing against the SOURCE's table rather than the target's
MG="MERGE INTO T t USING O o ON t.ID = o.ID"
both "OLD and NEW on the matched branch" \
  "$MG WHEN MATCHED THEN UPDATE SET t.N = o.K RETURNING OLD.N, NEW.N; ROLLBACK;"
both "the SOURCE's columns beside the target's" \
  "$MG WHEN MATCHED THEN UPDATE SET t.N = o.K RETURNING o.ID, o.K, t.N; ROLLBACK;"
both "the source alias, starred" \
  "$MG WHEN MATCHED THEN UPDATE SET t.N = o.K RETURNING o.*; ROLLBACK;"
both "...and the target's star is still the target's" \
  "$MG WHEN MATCHED THEN UPDATE SET t.N = o.K RETURNING t.*; ROLLBACK;"
both "an INSERTED row answers OLD as NULL" \
  "$MG WHEN MATCHED THEN UPDATE SET t.N = o.K
   WHEN NOT MATCHED THEN INSERT (ID, N) VALUES (o.ID, o.K)
   RETURNING OLD.N, NEW.N; ROLLBACK;"
both "the DESCRIBE names the source's own table" \
  "SET SQLDA_DISPLAY ON; $MG WHEN MATCHED THEN UPDATE SET t.N = o.K
   RETURNING o.K; ROLLBACK;"
both "...and the target's names the target's" \
  "SET SQLDA_DISPLAY ON; $MG WHEN MATCHED THEN UPDATE SET t.N = o.K
   RETURNING t.N; ROLLBACK;"
# a BARE star in a MERGE names BOTH contexts, and the engine proves it
# by raising 42702 on the column they share - this server has only the
# target's columns to expand it with, and no 42702 to answer with
refuses "a BARE star in a MERGE (the engine's 42702 is not reproduced)" \
  "$MG WHEN MATCHED THEN UPDATE SET t.N = o.K RETURNING *; ROLLBACK;"

# ---- the engine still reads fire-crab's file ----------------------------
eng_q="SET LIST ON; SELECT ID, N, S, D FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
# --- a MERGE's DELETE branch has no NEW record --------------------------
# `NEW.<col>` names the after-image. A DELETE branch has none, so the
# engine answers NULL there - while a BARE or target-qualified column
# still answers the deleted row, which is why the delete path records
# that row at all. fire-crab answered the deleted values for NEW too.
#
# The distinction is PER ROW, not per statement: in a mixed merge the
# update branch's row answers its new values and the delete branch's
# answers NULL, in ONE result. That is why the mixed case below is the
# one that matters - a plan-time decision cannot express it.
#
# The DESCRIBE follows the same three-way rule, probed:
#   every branch deletes -> NEW.<col> is the null CONSTANT, CHAR(1) NONE
#   some branch deletes  -> named CONSTANT, no table origin, column type
#   no branch deletes    -> the column itself, with `table:` set
both "MERGE DELETE: NEW is NULL, OLD and the target are not" \
    "MERGE INTO T USING (SELECT 2 AS K FROM RDB\$DATABASE) S ON T.ID=S.K WHEN MATCHED THEN DELETE RETURNING T.ID, OLD.N, NEW.N; ROLLBACK;"
both "MERGE DELETE: several NEW columns" \
    "MERGE INTO T USING (SELECT 2 AS K FROM RDB\$DATABASE) S ON T.ID=S.K WHEN MATCHED THEN DELETE RETURNING NEW.ID, NEW.N, NEW.S; ROLLBACK;"
both "MERGE MIXED: per-row, update keeps values and delete NULLs" \
    "MERGE INTO T USING (SELECT 1 AS K, 111 AS W FROM RDB\$DATABASE UNION ALL SELECT 2, 222 FROM RDB\$DATABASE) S ON T.ID=S.K WHEN MATCHED AND S.K=2 THEN DELETE WHEN MATCHED THEN UPDATE SET N=S.W RETURNING T.ID, OLD.N, NEW.N; ROLLBACK;"
both "MERGE NOT MATCHED BY SOURCE ... DELETE" \
    "MERGE INTO T USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON T.ID=S.K WHEN NOT MATCHED BY SOURCE THEN DELETE RETURNING T.ID, NEW.N; ROLLBACK;"
bothd "the delete-only describe folds NEW to the null constant" \
    "MERGE INTO T USING (SELECT 2 AS K FROM RDB\$DATABASE) S ON T.ID=S.K WHEN MATCHED THEN DELETE RETURNING NEW.N; ROLLBACK;"
bothd "the MIXED describe keeps the column type, named CONSTANT" \
    "MERGE INTO T USING (SELECT 1 AS K, 111 AS W FROM RDB\$DATABASE) S ON T.ID=S.K WHEN MATCHED AND S.K=2 THEN DELETE WHEN MATCHED THEN UPDATE SET N=S.W RETURNING NEW.N; ROLLBACK;"
bothd "control: a merge with NO delete branch names the COLUMN" \
    "MERGE INTO T USING (SELECT 1 AS K, 111 AS W FROM RDB\$DATABASE) S ON T.ID=S.K WHEN MATCHED THEN UPDATE SET N=S.W RETURNING NEW.N; ROLLBACK;"
both "control: the update branch is untouched" \
    "MERGE INTO T USING (SELECT 1 AS K, 111 AS W FROM RDB\$DATABASE) S ON T.ID=S.K WHEN MATCHED THEN UPDATE SET N=S.W RETURNING T.ID, OLD.N, NEW.N; ROLLBACK;"
both "control: the insert branch is untouched" \
    "MERGE INTO T USING (SELECT 77 AS K FROM RDB\$DATABASE) S ON T.ID=S.K WHEN NOT MATCHED THEN INSERT (ID,N) VALUES (77,7) RETURNING T.ID, NEW.N; ROLLBACK;"
both "control: a plain DELETE still answers the deleted row" \
    "DELETE FROM T WHERE ID=2 RETURNING ID, N; ROLLBACK;"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
