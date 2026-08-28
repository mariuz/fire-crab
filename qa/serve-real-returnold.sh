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
COMMIT;
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

# ---- recorded boundaries ------------------------------------------------
refuses "RETURNING * - this server has no star there at all" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING *; ROLLBACK;"
refuses "...so OLD.* rides on it" \
  "UPDATE T SET N = N + 1 WHERE ID = 1 RETURNING OLD.*; ROLLBACK;"
refuses "an ALIASED DML target (the alias is a legal qualifier there)" \
  "UPDATE T t SET t.N = t.N + 1 WHERE t.ID = 1 RETURNING t.N; ROLLBACK;"

# ---- the engine still reads fire-crab's file ----------------------------
eng_q="SET LIST ON; SELECT ID, N, S, D FROM T ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
