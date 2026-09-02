#!/bin/bash
# DML THROUGH A VIEW - the engine's laws, measured 2026-09-01 and pinned here.
#
# A view has a relation id and NO records of its own. fire-crab used to
# plan `UPDATE V ...` / `DELETE FROM V ...` as a walk over the view's
# (empty) storage - a SILENT NO-OP with "Records affected: 0" - and
# refused `INSERT INTO V` with a bare Dynamic SQL Error. The laws:
#
#   1. A NATURALLY UPDATABLE view (one plain relation, no join / DISTINCT
#      / GROUP BY / aggregate / UNION / FIRST / ORDER BY / window /
#      derived table; a subquery in its WHERE is fine) forwards INSERT,
#      UPDATE and DELETE to its base table: view columns are renamed to
#      base columns, the view's WHERE is ANDed into the statement's, and
#      the chain resolves through a view over a view. RETURNING answers
#      the base row but DESCRIBES the view (name, table: V, nullable).
#   2. Any other shape is `cannot update read-only view "PUBLIC"."VJ"`
#      at PREPARE (gds 335544362, bare) - unless a trigger for the event
#      exists (law 5).
#   3. An EXPRESSION column (RDB$BASE_FIELD null) may be read in WHERE /
#      RETURNING; ASSIGNING it (SET, or an INSERT column list) is
#      `attempted update of read-only column <unknown>` at PREPARE
#      (gds 335544359 with the literal string "<unknown>").
#   4. WITH CHECK OPTION: the new row must satisfy the view's WHERE, else
#      the CHECK vector with an EMPTY constraint name, the VIEW's name
#      and the engine's system check trigger (CHECK_n, RDB$SYSTEM_FLAG
#      5, a GLOBAL sequence - read from RDB$TRIGGERS, never derived).
#   5. A view with a USER trigger for the event runs ONLY its triggers:
#      no base write, even on a naturally updatable view; the count is
#      the number of view rows the triggers ran for; OLD/NEW are view
#      rows; a BEFORE trigger's NEW.x assignment shows in RETURNING. With
#      CHECK OPTION too, the USER triggers run first and the check tests the
#      post-trigger NEW - and finds nothing to test if a write-through
#      trigger already moved the base row out from under OLD.
#   6. MERGE, UPDATE OR INSERT, INSERT ... SELECT and PSQL bodies
#      re-plan text, so they inherit all of the above.
#
# Engine quirk NOT mirrored (a BOUND line, never a DIFF): RETURNING
# through a CHECK OPTION view answers zeros / no row on the engine
# because its system trigger does the write; fire-crab answers the
# real values. Every fixture table holds SEVERAL rows - a one-row
# fixture cannot tell "the right row" from "every row".
#
#   qa/serve-real-viewdml.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4057}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-viewdml-crab.fdb"
B="$D/fc-viewdml-engine.fdb"
LOG="/tmp/fc-serve-viewdml-$PORT.log"
mkdir -p "$D"
fail=0; ran=0

cat >"$D/viewdml-$PORT.sql" <<'EOF'
CREATE TABLE T (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, S VARCHAR(10), N NUMERIC(9,2));
CREATE TABLE LG (ID INTEGER, WHAT VARCHAR(20));
CREATE TABLE D (ID INTEGER NOT NULL PRIMARY KEY, NM VARCHAR(10));
CREATE TABLE B (ID INTEGER NOT NULL PRIMARY KEY, A INTEGER, REQ VARCHAR(5) NOT NULL, DFLT INTEGER DEFAULT 42);
COMMIT;
INSERT INTO T VALUES (1, 10, 'x', 12.50);
INSERT INTO T VALUES (2, 20, 'y', 1.25);
INSERT INTO T VALUES (3, 30, 'z', 13.50);
INSERT INTO T VALUES (4, NULL, NULL, NULL);
INSERT INTO T VALUES (5, 50, 'w', 5.00);
INSERT INTO T VALUES (6, 60, 'v', 6.00);
INSERT INTO D VALUES (1, 'one');
INSERT INTO D VALUES (2, 'two');
INSERT INTO B VALUES (1, 1, 'a', 1);
INSERT INTO B VALUES (2, 2, 'b', 2);
INSERT INTO B VALUES (3, 3, 'c', 3);
COMMIT;
CREATE VIEW V AS SELECT ID, A, S FROM T;
CREATE VIEW VW AS SELECT ID, A FROM T WHERE A > 15;
CREATE VIEW VR (K, VAL) AS SELECT ID, A FROM T;
CREATE VIEW VH AS SELECT ID, S FROM T WHERE A > 15;
CREATE VIEW VV AS SELECT ID, A FROM V WHERE A > 15;
CREATE VIEW VRR (KK, VV2) AS SELECT K, VAL FROM VR WHERE VAL < 55;
CREATE VIEW VSWAP (A, ID) AS SELECT ID, A FROM T;
CREATE VIEW VAL AS SELECT X.ID AS I, X.A AS B FROM T X WHERE X.A > 15;
CREATE VIEW VX AS SELECT ID, A*2 AS A2, A FROM T;
CREATE VIEW VONE AS SELECT ID, 1 AS ONE, A FROM T;
CREATE VIEW VS AS SELECT ID, A FROM T WHERE ID IN (SELECT ID FROM D);
CREATE VIEW VN AS SELECT ID, A FROM T WHERE ID NOT IN (SELECT ID FROM D);
CREATE VIEW VDUP (X, Y) AS SELECT A, A FROM T;
CREATE VIEW VB AS SELECT ID, A FROM B;
CREATE VIEW VBD AS SELECT ID, A, REQ FROM B;
CREATE VIEW VC AS SELECT ID, A FROM T WHERE A > 15 WITH CHECK OPTION;
CREATE VIEW VCR (K, VAL) AS SELECT ID, A FROM T WHERE A > 15 WITH CHECK OPTION;
CREATE VIEW VJ AS SELECT T.ID, T.A, D.NM FROM T JOIN D ON D.ID = T.ID;
CREATE VIEW VG AS SELECT A, COUNT(*) CNT FROM T GROUP BY A;
CREATE VIEW VD AS SELECT DISTINCT A FROM T;
CREATE VIEW VU AS SELECT ID, A FROM T UNION ALL SELECT ID, NULL FROM D;
CREATE VIEW VF AS SELECT FIRST 2 ID, A FROM T ORDER BY ID;
CREATE VIEW VO AS SELECT ID, A FROM T ORDER BY A DESC;
CREATE VIEW VWIN AS SELECT ID, A, ROW_NUMBER() OVER (ORDER BY ID) RN FROM T;
CREATE VIEW VDT AS SELECT ID, A FROM (SELECT ID, A FROM T) Q;
CREATE VIEW VT2 AS SELECT ID, A FROM T;
CREATE VIEW VM AS SELECT ID, A FROM T;
CREATE VIEW VCT AS SELECT ID, A FROM T WHERE A > 15 WITH CHECK OPTION;
CREATE VIEW VCW AS SELECT ID, A FROM T WHERE A > 15 WITH CHECK OPTION;
CREATE VIEW VCN AS SELECT ID, A FROM T WHERE A > 15 WITH CHECK OPTION;
COMMIT;
SET TERM ^;
CREATE TRIGGER B_BU FOR B BEFORE UPDATE AS BEGIN NEW.A = NEW.A * 10; INSERT INTO LG VALUES (OLD.ID, 'b-bu'); END^
CREATE TRIGGER B_AD FOR B AFTER DELETE AS BEGIN INSERT INTO LG VALUES (OLD.ID, 'b-ad'); END^
CREATE TRIGGER B_BI FOR B BEFORE INSERT AS BEGIN NEW.A = NEW.A + 1; END^
CREATE PROCEDURE PV (I INTEGER, V INTEGER) AS BEGIN UPDATE V SET A = :V WHERE ID = :I; DELETE FROM VW WHERE ID = :I + 1; INSERT INTO VR (K, VAL) VALUES (:I + 1000, :V); END^
CREATE TRIGGER D_AU FOR D AFTER UPDATE AS BEGIN UPDATE V SET S = 'trg' WHERE ID = NEW.ID; END^
CREATE TRIGGER VT2_BU FOR VT2 BEFORE UPDATE AS BEGIN INSERT INTO LG VALUES (OLD.ID, 'upd2'); END^
CREATE TRIGGER VT2_AD FOR VT2 AFTER DELETE AS BEGIN INSERT INTO LG VALUES (OLD.ID, 'del2'); END^
CREATE TRIGGER VT2_BI FOR VT2 BEFORE INSERT AS BEGIN INSERT INTO LG VALUES (NEW.ID, 'ins2'); NEW.A = NEW.A + 1; END^
CREATE TRIGGER VM_BIU FOR VM BEFORE INSERT OR UPDATE AS BEGIN INSERT INTO LG VALUES (NEW.ID, 'vm-biu'); END^
CREATE TRIGGER VJ_BI FOR VJ BEFORE INSERT AS BEGIN INSERT INTO LG VALUES (NEW.ID, 'vjins'); INSERT INTO T (ID, A) VALUES (NEW.ID, NEW.A); END^
CREATE TRIGGER VCT_BU FOR VCT BEFORE UPDATE AS BEGIN INSERT INTO LG VALUES (OLD.ID, 'vct-bu'); END^
CREATE TRIGGER VCW_BU FOR VCW BEFORE UPDATE AS BEGIN INSERT INTO LG VALUES (OLD.ID, 'vcw-bu'); UPDATE T SET A = NEW.A WHERE ID = OLD.ID; END^
CREATE TRIGGER VCN_BU FOR VCN BEFORE UPDATE AS BEGIN INSERT INTO LG VALUES (OLD.ID, 'vcn-bu'); NEW.A = 50; END^
CREATE TRIGGER VCN_BI FOR VCN BEFORE INSERT AS BEGIN INSERT INTO LG VALUES (NEW.ID, 'vcn-bi'); NEW.A = NEW.A + 100; END^
SET TERM ;^
COMMIT;
EOF
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192 DEFAULT CHARACTER SET UTF8;
COMMIT;
EOF
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" -i "$D/viewdml-$PORT.sql" >/dev/null 2>&1 || return 1
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/viewdml-$PORT.sql"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -a -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }
# the same script, SET LIST ON + SET COUNT ON, on the engine and on fire-crab
both() {
    e=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    check "$1" "$c" "$e"
}
# a DESCRIBE differential: prepare only, no execute (PLANONLY keeps isql
# from executing the `?` statement - the execute-time 07002 / 42000 it
# would then print is a pre-existing divergence, identical on a table)
bothd() {
    e=$(printf 'SET SQLDA_DISPLAY ON; SET PLANONLY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | grep -a -E 'sqltype|name:|SQLSTATE|read-only' | norm)
    c=$(printf 'SET SQLDA_DISPLAY ON; SET PLANONLY ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | grep -a -E 'sqltype|name:|SQLSTATE|read-only' | norm)
    check "$1" "$c" "$e"
}
# a recorded engine quirk: printed, never failed
bound() {
    e=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$B" 2>&1 | norm)
    c=$(printf 'SET LIST ON; SET COUNT ON;\n%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 | norm)
    if [ "$c" = "$e" ]; then echo "OK   (quirk gone) $1"; ran=$((ran + 1)); else echo "BOUND $1"; echo "     engine: [$e]"; echo "     fc:     [$c]"; fi
}

# ---- 1. a plain view forwards to its base table ---------------------------
both "UPDATE through a plain view changes the base row, and only that row" \
     "UPDATE V SET A = A + 1 WHERE ID = 1; SELECT ID, A FROM T ORDER BY ID;"
both "UPDATE ... RETURNING through a view: NEW, OLD, and a column not in SET" \
     "UPDATE V SET A = A + 1 WHERE ID = 1 RETURNING ID, A, OLD.A, S;"
both "a multi-row UPDATE through a view counts every base row it touched" \
     "UPDATE V SET A = A + 1 WHERE A IS NOT NULL; SELECT ID, A FROM T ORDER BY ID;"
both "DELETE through a view removes the base row" \
     "DELETE FROM V WHERE ID = 2; SELECT COUNT(*) C FROM T;"
both "DELETE ... RETURNING through a view" \
     "DELETE FROM V WHERE A = (SELECT MAX(A) FROM V) RETURNING ID, A; SELECT ID, A FROM T ORDER BY ID;"
both "INSERT through a view with a column list, and RETURNING" \
     "INSERT INTO V (ID, A, S) VALUES (7, 70, 'q') RETURNING ID, A, S; SELECT ID, A, S FROM T WHERE ID = 7;"
both "INSERT through a view without a column list is positional over the VIEW's columns" \
     "INSERT INTO V VALUES (8, 80, 'r'); SELECT ID, A, S, N FROM T WHERE ID = 8;"
both "a base column the view does not expose stays NULL / default" \
     "INSERT INTO VBD (ID, A, REQ) VALUES (9, 9, 'i') RETURNING ID, A; SELECT * FROM B WHERE ID = 9;"
both "INSERT ... DEFAULT VALUES through a view hits the base table's NOT NULL" \
     "INSERT INTO V DEFAULT VALUES;"
both "a schema-qualified view name works in every spelling" \
     "UPDATE PUBLIC.V SET A = 1 WHERE ID = 1 RETURNING ID, A; DELETE FROM \"PUBLIC\".\"V\" WHERE ID = 4 RETURNING ID; SELECT ID, A FROM T ORDER BY ID;"
both "an alias on the view in UPDATE / DELETE, columns qualified by it" \
     "UPDATE V v SET v.A = 3 WHERE v.ID = 3 RETURNING v.ID, v.A; DELETE FROM V vv WHERE vv.ID = 8 RETURNING vv.ID, vv.S;"

# ---- 2. a RENAMING view maps names both ways ------------------------------
both "a renaming view: SET, WHERE and RETURNING use the VIEW's names" \
     "UPDATE VR SET VAL = VAL * 2 WHERE K = 5 RETURNING K, VAL, OLD.VAL; SELECT ID, A FROM T WHERE ID = 5;"
both "a renaming view: DELETE by the renamed column" \
     "DELETE FROM VR WHERE VAL = 60 RETURNING K; SELECT COUNT(*) C FROM T;"
both "a renaming view: INSERT with the view's column list" \
     "INSERT INTO VR (K, VAL) VALUES (11, 110) RETURNING K, VAL; SELECT ID, A, S FROM T WHERE ID = 11;"
both "a renaming view: positional INSERT" \
     "INSERT INTO VR VALUES (12, 120); SELECT ID, A FROM T WHERE ID = 12;"
both "a renaming view: INSERT ... SELECT, with and without RETURNING" \
     "INSERT INTO VR (K, VAL) SELECT ID + 200, A FROM T WHERE ID < 3 RETURNING K; INSERT INTO VR (K, VAL) SELECT ID + 300, A FROM T WHERE ID < 3; SELECT ID, A FROM T WHERE ID > 100 ORDER BY ID;"
both "a SWAPPING view (A, ID) AS SELECT ID, A: the rename is simultaneous" \
     "UPDATE VSWAP SET ID = 1000 WHERE A = 3 RETURNING A, ID; SELECT ID, A FROM T WHERE ID = 3;"
both "two view columns over ONE base column: the last assignment wins, no error" \
     "UPDATE VDUP SET X = 61, Y = 62 WHERE X = 1000 RETURNING X, Y; SELECT ID, A FROM T WHERE ID = 3;"

# ---- 3. the view's WHERE is ANDed in --------------------------------------
both "a filtered view: a row outside the view is not touched" \
     "UPDATE VW SET A = 99 WHERE ID = 4; SELECT ID, A FROM T WHERE ID = 4;"
both "a filtered view: an UPDATE may move a row OUT of the view (no CHECK OPTION)" \
     "UPDATE VW SET A = 1 WHERE ID = 7; SELECT ID, A FROM VW ORDER BY ID; SELECT ID, A FROM T WHERE ID = 7;"
both "a filtered view: a multi-row UPDATE / DELETE count only the visible rows" \
     "UPDATE VW SET A = A + 1; DELETE FROM VW WHERE ID > 200; SELECT ID, A FROM T ORDER BY ID;"
both "a filtered view: INSERT of a row the view will not show is allowed" \
     "INSERT INTO VW (ID, A) VALUES (13, 1); SELECT ID, A FROM T WHERE ID = 13; SELECT COUNT(*) C FROM VW WHERE ID = 13;"
both "the view's WHERE may name a column the view does not expose" \
     "UPDATE VH SET S = 'hid' WHERE ID IN (1, 7, 12, 13); SELECT ID, S FROM T ORDER BY ID;"
both "a view over a view: both levels' WHEREs apply, renames compose" \
     "UPDATE VV SET A = A + 1 WHERE ID = 12 RETURNING ID, A; UPDATE VV SET A = A + 1 WHERE ID = 13 RETURNING ID, A; UPDATE VRR SET VV2 = VV2 + 1 WHERE KK = 1 RETURNING KK, VV2; DELETE FROM VRR WHERE KK = 13 RETURNING KK; SELECT ID, A FROM T ORDER BY ID;"
both "a body alias (X.ID AS I ... FROM T X WHERE X.A > 15) and a statement alias" \
     "UPDATE VAL SET B = 66 WHERE I = 6 RETURNING I, B; DELETE FROM VAL v WHERE v.I = 6 RETURNING v.I; SELECT ID, A FROM T ORDER BY ID;"
both "a view whose WHERE holds a subquery (IN / NOT IN) is still updatable" \
     "UPDATE VS SET A = 77 WHERE ID = 1 RETURNING ID, A; UPDATE VN SET A = -1 WHERE ID = 12 RETURNING ID, A; DELETE FROM VS WHERE ID = 2 RETURNING ID; SELECT ID, A FROM T ORDER BY ID;"

# ---- 4. expression columns ------------------------------------------------
both "an expression column can be read in WHERE and RETURNING (recomputed from NEW)" \
     "UPDATE VX SET A = 7 WHERE ID = 5 RETURNING ID, A, A2; DELETE FROM VX WHERE A2 = 14 RETURNING ID; INSERT INTO VX (ID, A) VALUES (15, 150) RETURNING ID, A2; SELECT ID, A FROM T ORDER BY ID;"
both "assigning an expression column in SET is a read-only column error at prepare" \
     "UPDATE VX SET A2 = 7 WHERE ID = 15;"
both "naming an expression column in an INSERT list is the same error" \
     "INSERT INTO VONE (ID, ONE) VALUES (41, 1); INSERT INTO VONE (ID, A) VALUES (41, 410) RETURNING ID, ONE, A;"

# ---- 5. read-only views ---------------------------------------------------
both "a JOIN view refuses UPDATE, DELETE (it has only an INSERT trigger)" \
     "UPDATE VJ SET A = 5 WHERE ID = 1; DELETE FROM VJ WHERE ID = 1; UPDATE VJ SET NM = 'x' WHERE ID = 1;"
both "GROUP BY / DISTINCT / UNION / FIRST / ORDER BY / window / derived-table views are read-only" \
     "UPDATE VG SET CNT = 1; DELETE FROM VD WHERE A = 10; INSERT INTO VU (ID, A) VALUES (1, 1); UPDATE VF SET A = 1 WHERE ID = 5; DELETE FROM VO WHERE ID = 5; UPDATE VWIN SET A = 1 WHERE ID = 5; INSERT INTO VDT (ID, A) VALUES (99, 1); INSERT INTO VG (A, CNT) VALUES (1, 1);"
bothd "the read-only refusal happens at PREPARE (no INPUT message is described)" \
      "UPDATE VJ SET A = ? WHERE ID = ?;"

# ---- 6. WITH CHECK OPTION -------------------------------------------------
both "CHECK OPTION: an UPDATE that moves the row out of the view is refused, named by the view and its CHECK trigger" \
     "UPDATE VC SET A = 1 WHERE ID = 3; SELECT ID, A FROM T WHERE ID = 3;"
both "CHECK OPTION: an INSERT the view would not show is refused" \
     "INSERT INTO VC (ID, A) VALUES (16, 1); INSERT INTO VCR (K, VAL) VALUES (17, 1); SELECT COUNT(*) C FROM T WHERE ID IN (16, 17);"
both "CHECK OPTION: a conforming UPDATE / INSERT / DELETE go through, with counts" \
     "UPDATE VC SET A = 100 WHERE ID = 3; INSERT INTO VC (ID, A) VALUES (16, 160); DELETE FROM VC WHERE ID = 16; UPDATE VC SET A = A + 1 WHERE ID > 0; SELECT ID, A FROM T ORDER BY ID;"
both "CHECK OPTION: a renamed view's check trigger has its OWN name in the sequence" \
     "UPDATE VCR SET VAL = 1 WHERE K = 3;"
both "CHECK OPTION on a nested violation names the trigger of the view NAMED in the statement" \
     "INSERT INTO VCR (K, VAL) SELECT ID + 400, 1 FROM T WHERE ID = 1; SELECT COUNT(*) C FROM T WHERE ID > 400;"
bound "RETURNING through a CHECK OPTION view: the engine's system trigger does the write and its RETURNING sees zeros / nothing; fire-crab answers the real values" \
      "UPDATE VC SET A = 200 WHERE ID = 3 RETURNING ID, A, OLD.A; INSERT INTO VC (ID, A) VALUES (18, 180) RETURNING ID, A;"
both "... and the rows behind that quirk are the same on both sides" \
     "SELECT ID, A FROM T WHERE ID IN (3, 18) ORDER BY ID;"

# ---- 7. base-table triggers and validation fire through the view ----------
both "a base table's BEFORE UPDATE / AFTER DELETE / BEFORE INSERT triggers fire through the view" \
     "UPDATE VB SET A = 5 WHERE ID = 1 RETURNING ID, A, OLD.A; DELETE FROM VB WHERE ID = 2 RETURNING ID; INSERT INTO VBD (ID, A, REQ) VALUES (4, 4, 'd') RETURNING ID, A; SELECT * FROM B ORDER BY ID; SELECT * FROM LG ORDER BY ID, WHAT;"
both "a NOT NULL base column the view hides: the base table's validation error" \
     "INSERT INTO VB (ID, A) VALUES (5, 5);"

# ---- 8. MERGE, UPDATE OR INSERT, PSQL bodies inherit ----------------------
both "MERGE INTO a view updates and inserts through it" \
     "MERGE INTO V USING D ON V.ID = D.ID WHEN MATCHED THEN UPDATE SET A = 555 WHEN NOT MATCHED THEN INSERT (ID, A) VALUES (D.ID + 100, 1); SELECT ID, A FROM T ORDER BY ID;"
both "UPDATE OR INSERT INTO a view, both branches, RETURNING" \
     "UPDATE OR INSERT INTO V (ID, A, S) VALUES (1, 2, 'uoi') MATCHING (ID) RETURNING ID, A, S; UPDATE OR INSERT INTO V (ID, A, S) VALUES (300, 2, 'new') MATCHING (ID) RETURNING ID, A, S; SELECT ID, A, S FROM T WHERE ID IN (1, 300) ORDER BY ID;"
both "a procedure body's UPDATE / DELETE / INSERT through views" \
     "EXECUTE PROCEDURE PV(3, 333); SELECT ID, A FROM T ORDER BY ID;"
both "a table trigger's UPDATE through a view" \
     "UPDATE D SET NM = 'chg' WHERE ID = 1; SELECT ID, S FROM T WHERE ID = 1;"
both "an EXECUTE BLOCK's DML through views" \
     "SET TERM ^; EXECUTE BLOCK RETURNS (N INTEGER) AS BEGIN UPDATE V SET A = 0 WHERE ID = 3; DELETE FROM V WHERE ID = 300; INSERT INTO V (ID, A) VALUES (400, 4); SELECT COUNT(*) FROM T INTO :N; SUSPEND; END^ SET TERM ;^ SELECT ID, A FROM T ORDER BY ID;"

# ---- 9. a view with a USER trigger runs ONLY its triggers -----------------
both "a naturally updatable view with log-only triggers: RETURNING shows NEW, the base row is untouched" \
     "UPDATE VT2 SET A = 1000 WHERE ID = 1 RETURNING ID, A, OLD.A; SELECT ID, A FROM T WHERE ID = 1;"
both "... DELETE through it deletes nothing, INSERT stores nothing, but the BEFORE trigger's NEW.A shows in RETURNING" \
     "DELETE FROM VT2 WHERE ID = 12 RETURNING ID; SELECT COUNT(*) C FROM T WHERE ID = 12; INSERT INTO VT2 (ID, A) VALUES (14, 140) RETURNING ID, A; SELECT COUNT(*) C FROM T WHERE ID = 14; SELECT * FROM LG WHERE WHAT IN ('upd2', 'del2', 'ins2') ORDER BY ID, WHAT;"
both "... the count is the number of view rows the triggers ran for" \
     "UPDATE VT2 SET A = 1 WHERE ID > 0; DELETE FROM VT2 WHERE ID > 0; INSERT INTO VT2 (ID, A) VALUES (30, 300); SELECT COUNT(*) C FROM T;"
both "a multi-action trigger (BEFORE INSERT OR UPDATE) covers both events, DELETE still goes to the base" \
     "UPDATE VM SET A = 1 WHERE ID = 1 RETURNING ID, A; INSERT INTO VM (ID, A) VALUES (31, 310) RETURNING ID, A; DELETE FROM VM WHERE ID = 400 RETURNING ID; SELECT ID, A FROM T WHERE ID IN (1, 31, 400) ORDER BY ID; SELECT * FROM LG WHERE WHAT = 'vm-biu' ORDER BY ID;"
both "a JOIN view with a BEFORE INSERT trigger accepts INSERT (the trigger writes the base)" \
     "INSERT INTO VJ (ID, A) VALUES (32, 320); SELECT ID, A FROM T WHERE ID = 32; SELECT * FROM LG WHERE WHAT = 'vjins';"
both "CHECK OPTION on a trigger view: a violation undoes the trigger's own writes; a conforming UPDATE runs the trigger and writes nothing" \
     "INSERT INTO T (ID, A) VALUES (22, 220); UPDATE VCT SET A = 1 WHERE ID = 22; SELECT ID, A FROM T WHERE ID = 22; SELECT COUNT(*) C FROM LG WHERE WHAT = 'vct-bu'; UPDATE VCT SET A = 100 WHERE ID = 22; SELECT ID, A FROM T WHERE ID = 22; SELECT COUNT(*) C FROM LG WHERE WHAT = 'vct-bu';"
both "... the user trigger runs FIRST: a write-through trigger moves the base row, so the CHECK finds no row to test and passes" \
     "INSERT INTO T (ID, A) VALUES (20, 200); UPDATE VCW SET A = 1 WHERE ID = 20; SELECT ID, A FROM T WHERE ID = 20; SELECT COUNT(*) C FROM LG WHERE WHAT = 'vcw-bu';"
both "... and the CHECK tests the POST-trigger NEW: a trigger that assigns NEW.A back into the view passes, INSERT alike" \
     "INSERT INTO T (ID, A) VALUES (21, 210); UPDATE VCN SET A = 1 WHERE ID = 21; INSERT INTO VCN (ID, A) VALUES (60, -50); INSERT INTO VCN (ID, A) VALUES (61, -200); SELECT ID, A FROM T WHERE ID IN (21, 60, 61) ORDER BY ID; SELECT * FROM LG WHERE WHAT LIKE 'vcn%' ORDER BY ID, WHAT;"

# ---- 10. describes ----------------------------------------------------------
bothd "UPDATE ... RETURNING through a view describes the VIEW: names, table, nullable" \
      "UPDATE V SET A = ? WHERE ID = ? RETURNING ID, A, OLD.A, S;"
bothd "a renaming view describes its OWN column names" \
      "UPDATE VR SET VAL = ? WHERE K = ? RETURNING K, VAL, OLD.VAL;"
bothd "an expression column in RETURNING is typed from its expression and named by the view" \
      "INSERT INTO VX (ID, A) VALUES (?, ?) RETURNING ID, A2;"
bothd "INSERT ... RETURNING through a renaming view" \
      "INSERT INTO VR (K, VAL) VALUES (?, ?) RETURNING K, VAL;"
bothd "DELETE ... RETURNING through an aliased view" \
      "DELETE FROM VAL v WHERE v.I = ? RETURNING v.I, v.B;"
bothd "assigning an expression column fails at PREPARE with the read-only column text" \
      "UPDATE VX SET A2 = ? WHERE ID = ?;"

# ---- the engine reads fire-crab's own file the same way -------------------
eng_q="SET LIST ON; SELECT ID, A, S FROM T ORDER BY ID; SELECT * FROM B ORDER BY ID; SELECT * FROM LG ORDER BY ID, WHAT; SELECT ID, A FROM VW ORDER BY ID;"
e=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$B" 2>&1 | norm)
c=$(printf '%s\n' "$eng_q" | "$ISQL" -q -user "$U" -pas "$P" "$A" 2>&1 | norm)
check "the ENGINE answers the same over fire-crab's own file" "$c" "$e"
gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi
echo "ran $ran checks"
exit $fail
