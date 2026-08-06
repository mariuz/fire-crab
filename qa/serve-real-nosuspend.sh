#!/bin/bash
# A PROCEDURE THAT DOES NOT SUSPEND, used as a FROM item. fire-crab
# answered [] here; the engine refuses at PREPARE - and it refuses with
# one of THREE unrelated status vectors, decided by metadata, never by
# whether rows came back. Every law below was probed against the live
# engine first (LI-T6.0.0.2076) and is re-checked here differentially,
# vector item by vector item:
#
#   1. OUTPUTS > 0 and RDB$PROCEDURE_TYPE = 2: SQLCODE -104, gdscodes
#      [335544343 isc_invalid_blr, 335544868 isc_illegal_prc_type].
#      NO "Dynamic SQL Error" wrapper, NO isc_sqlerr, NO line/column -
#      it is a BLR-COMPILE refusal. isc_invalid_blr carries a BYTE
#      OFFSET into BLR fire-crab never generated; it is deterministic,
#      24 + len(schema) + len(name) + 4 per selected column past the
#      first + 3 + (1 | 7 | 11) per argument literal, and it is what
#      this gate really pins.
#   2. ZERO OUTPUTS: a completely different, DSQL-shaped vector -
#      SQLCODE -84, [isc_dsql_error, isc_sqlerr(-84),
#      isc_dsql_procedure_use_err(name), isc_dsql_line_col_error(l, c)]
#      with a LOWERCASE 'procedure' against LAW 1's capital P. Driven
#      purely by RDB$PROCEDURE_OUTPUTS, never by the body, and the
#      line/column point at the FIRST CHARACTER OF THE FROM ITEM as
#      written (qualifier and opening quote included). A LINE ENDS ON
#      CR, ON LF, OR ON CRLF - and CRLF counts ONCE.
#   3. WRONG ARITY: [isc_dsql_error, isc_prcmismat(name)], SQLCODE
#      -902 - and it BEATS the not-selectable refusal, for selectable
#      and non-selectable procedures alike, so an implementation that
#      checked selectability first would answer the wrong error for a
#      whole family. It does NOT beat law 2: re-probed here against
#      the slice spec, a 0-output procedure called with the wrong
#      arity (none, or one too many) answers -84, never isc_prcmismat.
#      The full order is zero-outputs -> arity -> not-selectable.
#   4. SELECTABILITY IS LEXICAL AND DDL-TIME. A SUSPEND inside
#      IF (1=0), inside WHILE (1=0), inside a FOR over an empty table,
#      or dead after an EXIT is still TYPE = 1 and legitimately answers
#      ZERO ROWS with no error - the one case where [] is correct. The
#      fix must be metadata-driven; "no rows came back" would break
#      these four.
#   5. Neither refusal is value-gated and neither ever runs the body:
#      T stays empty after the failed prepare, read back THROUGH THE
#      ENGINE from the file fire-crab served.
#   6. EXECUTE PROCEDURE is untouched: it succeeds on every shape,
#      returns the FIRST SUSPEND's values on a selectable body, NULLs
#      when SUSPEND never fires, and really does insert the row.
#   7. Selectability is LIVE metadata: ALTER PROCEDURE adding SUSPEND
#      flips the answer at the next prepare, and removing it flips it
#      back - the check that proves this reads the catalog rather than
#      a hard-coded name list.
#   8. The recorded boundaries (aggregate, WHERE, derived table, JOIN,
#      empty parentheses) must still ERROR on both sides. A gate that
#      silently stops erroring there is the regression that matters.
#
# Two PRE-EXISTING boundaries, unrelated to selectability, are pinned
# here rather than hidden (both verified against the pre-change binary,
# both refusals and never wrong answers): fire-crab's PSQL interpreter
# has no EXIT, so `SELECT * FROM PEXIT` refuses where the engine answers
# []; and an EMPTY `BEGIN END` body is outside its surface, so EXECUTE
# PROCEDURE on one refuses where the engine succeeds silently. Each is
# asserted as "fc refuses", so if either is ever implemented this gate
# says so instead of going quiet.
#
# THE DIFFERENTIAL: two identical engine-built fixtures; one driver;
# fire-crab on $PORT against the work copy and the ENGINE'S OWN wire
# server on $ENGPORT against the ref copy. The wanted vector is always
# the engine's own, captured through node-firebird's callback hook -
# never hard-coded.
#
#   qa/serve-real-nosuspend.sh [port]
#
# Needs isql, node (node-firebird on NODE_PATH) and the engine's wire
# server on 3050 for the vector differential.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4611}"
ENGPORT="${ENGPORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-nosusp-work.fdb"; REF="$D/fc-nosusp-ref.fdb"
VJS="$D/fc-nosusp-vec.js"

command -v "$ISQL" >/dev/null 2>&1 || { echo "SKIP isql not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e "require('node-firebird')" 2>/dev/null || { echo "SKIP node-firebird not found"; exit 0; }
command -v nc >/dev/null 2>&1 && ! nc -z 127.0.0.1 "$ENGPORT" 2>/dev/null && {
    echo "SKIP engine wire server not reachable on port $ENGPORT (the vector differential needs it)"
    exit 0
}
mkdir -p "$D"; rm -f "$WORK" "$REF"

# --- the fixture ------------------------------------------------------
# PNS/PNS2/PNSARG/PLONGNAMEXYZ: outputs, no SUSPEND -> TYPE 2, LAW 1,
# spanning one to three outputs, name lengths 3 and 12, and 0/2
# arguments. PNOOUT/PEMPTY/PNOUTARG: zero outputs -> LAW 2, and
# PNOOUT WRITES - which is what makes the "body never ran" read-back
# mean something, and what makes the LAW 12 read-back after EXECUTE
# PROCEDURE mean the opposite. PSEL/PSELARG: honest selectable ones.
# PIF/PFOR/PWHILE/PEXIT: SUSPEND present but UNREACHABLE - TYPE 1,
# zero rows, LAW 4.
SCHEMA="CREATE TABLE T (ID INTEGER);
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE PNS RETURNS (X INTEGER) AS BEGIN X = 42; END^
CREATE PROCEDURE PNS2 RETURNS (X INTEGER, Y INTEGER) AS BEGIN X = 1; END^
CREATE PROCEDURE PNSARG (P INTEGER, Q INTEGER) RETURNS (X INTEGER) AS
BEGIN X = :P; END^
CREATE PROCEDURE PLONGNAMEXYZ RETURNS (X INTEGER, Y INTEGER, Z INTEGER) AS
BEGIN X = 1; END^
CREATE PROCEDURE PNOOUT AS BEGIN INSERT INTO T (ID) VALUES (99); END^
CREATE PROCEDURE PEMPTY AS BEGIN END^
CREATE PROCEDURE PNOUTARG (P INTEGER) AS BEGIN END^
CREATE PROCEDURE PSEL RETURNS (X INTEGER) AS
BEGIN X = 1; SUSPEND; X = 2; SUSPEND; END^
CREATE PROCEDURE PSELARG (A INTEGER, B INTEGER) RETURNS (X INTEGER) AS
BEGIN X = :A + :B; SUSPEND; END^
CREATE PROCEDURE PIF RETURNS (X INTEGER) AS
BEGIN IF (1 = 0) THEN BEGIN X = 1; SUSPEND; END END^
CREATE PROCEDURE PFOR RETURNS (X INTEGER) AS
BEGIN FOR SELECT ID FROM T INTO :X DO SUSPEND; END^
CREATE PROCEDURE PWHILE RETURNS (X INTEGER) AS
BEGIN WHILE (1 = 0) DO BEGIN X = 1; SUSPEND; END END^
CREATE PROCEDURE PEXIT RETURNS (X INTEGER) AS
BEGIN EXIT; X = 1; SUSPEND; END^
SET TERM ; ^
COMMIT;"

for f in "$REF" "$WORK"; do
    "$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL create $f"; exit 1; }
CREATE DATABASE '$f' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$SCHEMA
EOF
    # the engine's own wire server runs as another user and must be able
    # to open the ref copy embedded isql created 0660
    chmod 666 "$f"
done

# the fixture is only a fixture if the engine really typed it the way
# the laws say - a silent TYPE flip would make every check below vacuous
types=$("$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 <<'SQL' | tr -s ' \n' ' '
SET HEADING OFF;
SELECT TRIM(RDB$PROCEDURE_NAME) || '=' || RDB$PROCEDURE_TYPE || '/' || RDB$PROCEDURE_OUTPUTS
FROM RDB$PROCEDURES WHERE RDB$SCHEMA_NAME = 'PUBLIC' ORDER BY 1;
SQL
)
case "$types" in
    *"PEXIT=1/1"*"PFOR=1/1"*"PIF=1/1"*) ;;
    *) echo "FAIL the fixture is not typed as probed: [$types]"; exit 1 ;;
esac
case "$types" in
    *"PNOOUT=2/0"*"PNS=2/1"*) ;;
    *) echo "FAIL the fixture is not typed as probed: [$types]"; exit 1 ;;
esac

# --- the full-status probe: node-firebird's callback hook exposes the
# --- RAW status vector items (gdscode, numbers and PRE-QUOTED strings)
# --- exactly as they ride the wire. On success it prints the ROWS, so
# --- the same helper pins LAW 4's legitimate [] too.
cat > "$VJS" <<'JS'
const cb = require("node-firebird/lib/callback");
const orig = cb.doCallback;
let lastStatus = null;
cb.doCallback = function (obj, callback) {
  if (obj && typeof obj === "object" && obj.status) lastStatus = obj.status;
  return orig(obj, function (err, res) {
    if (err && lastStatus) { err.fullStatus = lastStatus; lastStatus = null; }
    if (callback) callback(err, res);
  });
};
const F = require("node-firebird");
F.attach({host:"127.0.0.1", port:+process.env.PORT, database:process.env.DB,
          user:"SYSDBA", password:"masterkey"}, (e, db) => {
  if (e) { console.log("CONN_ERR"); process.exit(1); }
  db.query(process.env.STMT, (qe, rows) => {
    if (qe) console.log("ERR " + JSON.stringify(qe.fullStatus || []));
    else console.log("OK " + JSON.stringify(Array.isArray(rows) ? rows : (rows ? [rows] : [])));
    db.detach(); process.exit(0);
  });
});
JS

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nosusp.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$VJS"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
# "something is listening" is not "OUR server is listening": if the port
# was taken, fcwire exited at bind and every check below measures the
# other server. Fatal, not a warning.
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0
ran=0
strip() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
vec_once() { PORT="$1" DB="$2" STMT="$3" timeout 25 node "$VJS" 2>/dev/null; }
vec_run() { # <port> <db> <stmt> - retries the connection race only
    n=0
    while [ $n -lt 10 ]; do
        r=$(vec_once "$1" "$2" "$3")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}
check() { # <label> <got> <want>
    ran=$((ran + 1))
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     engine: $3"; echo "     fc:     $2"; fail=1; fi
}
# One statement on BOTH sides through the SAME driver: fire-crab on the
# work copy, the engine on the ref copy. On a refusal the whole raw
# vector is compared (no prefix truncation - every argument here is
# reproducible); on success the rows are.
both() { # <label> <stmt>
    got=$(vec_run "$PORT" "$WORK" "$2")
    want=$(vec_run "$ENGPORT" "$REF" "$2")
    check "$1 [$2]" "$got" "$want"
}
# a recorded boundary: the message texts differ, so only the FACT of an
# error is compared - but fc answering rows (or []) is a hard failure
errs() { # <label> <stmt>
    got=$(vec_run "$PORT" "$WORK" "$2")
    want=$(vec_run "$ENGPORT" "$REF" "$2")
    ran=$((ran + 1))
    case "$want" in
        ERR*) ;;
        *) echo "DIFF $1 - the ENGINE accepted it, so the case is wrong: $want"; fail=1; return ;;
    esac
    case "$got" in
        ERR*) echo "OK   $1 (both refuse)" ;;
        *) echo "DIFF $1 - the engine refuses it but fc answered: $got"; fail=1 ;;
    esac
}
# isql on both sides, for the shapes node-firebird does not carry
# (EXECUTE PROCEDURE) and for the DDL of LAW 17
same() { # <label> <sql>
    fc=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$WORK" 2>&1 | tr -s ' \n' ' ' | strip)
    en=$(printf 'SET HEADING OFF;\n%s;\n' "$2" |
         "$ISQL" -q -user "$U" -pas "$P" "$REF" 2>&1 | tr -s ' \n' ' ' | strip)
    check "$1 [$2]" "$fc" "$en"
}
col() { # <file> <query> - the ENGINE's own read of the file fc served
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^$' | tr '\n' ' ' | strip
SET HEADING OFF;
$2;
SQL
}

# --- A. LAW 1: the -104 vector and its BLR offset ----------------------
both "A1. bare call, 1 output (offset 33)"      "SELECT * FROM PNS"
both "A2. a named column does not move it"      "SELECT X FROM PNS"
both "A3. a PUBLIC. qualifier does not move it" "SELECT * FROM PUBLIC.PNS"
both "A4. a fully quoted name"                  "SELECT * FROM \"PUBLIC\".\"PNS\""
both "A5. lower-case SQL"                       "select * from pns"
both "A6. two outputs: +4 per column"           "SELECT * FROM PNS2"
both "A7. one of two columns: back to 1 column" "SELECT X FROM PNS2"
both "A8. a 12-char name, three outputs"        "SELECT * FROM PLONGNAMEXYZ"
both "A9. two blr_long arguments (+3 +7 +7)"    "SELECT * FROM PNSARG(1,2)"
both "A10. a leading NULL argument is cheaper"  "SELECT * FROM PNSARG(NULL,2)"
both "A11. a trailing NULL argument"            "SELECT * FROM PNSARG(1,NULL)"
both "A12. the i32 rim is still blr_long"       "SELECT * FROM PNSARG(2147483647,1)"
both "A13. one past it becomes blr_int64 (+4)"  "SELECT * FROM PNSARG(2147483648,1)"
both "A14. negative literals"                   "SELECT * FROM PNSARG(-2147483648,-1)"
# the modifiers: probed NOT to move the offset, so the refusal travels
# up through the rewriting wrapper unchanged - except DISTINCT, which
# shrinks the SELECT LIST and therefore does move it
both "A15. FIRST does not move the offset"      "SELECT FIRST 1 * FROM PNS"
both "A16. SKIP does not move it"               "SELECT SKIP 1 * FROM PNS2"
both "A17. DISTINCT X moves it via the list"    "SELECT DISTINCT X FROM PNS2"
both "A18. a trailing ROWS does not move it"    "SELECT * FROM PNS ROWS 1"
both "A19. FIRST over an argument call"         "SELECT FIRST 1 * FROM PNSARG(1,2)"

# --- B. LAW 2: the -84 vector, its line and its column -----------------
both "B1. zero outputs, a writing body"     "SELECT * FROM PNOOUT"
both "B2. zero outputs, BEGIN END"          "SELECT * FROM PEMPTY"
both "B3. zero outputs WITH an input"       "SELECT * FROM PNOUTARG(1)"
both "B4. the column is the QUALIFIER's"    "SELECT * FROM PUBLIC.PNOOUT"
both "B5. the column is the opening QUOTE's" "SELECT * FROM \"PUBLIC\".\"PNOOUT\""
both "B6. the line number counts newlines"  "SELECT *
  FROM PNOOUT"
# LAW 5 / LAW 6: the refusal is at PREPARE and the body NEVER RAN - read
# back through the ENGINE, out of the very file fire-crab served
# PNOOUT's body WRITES and its refusal is at PREPARE, so T is empty
check "B7. PNOOUT's INSERT never happened (engine reads fc's file)" \
      "$(col "$WORK" "SELECT COUNT(*) FROM T")" "0"
check "B8. ... and not on the ref copy either" \
      "$(col "$REF" "SELECT COUNT(*) FROM T")" "0"
# A LINE ENDS ON CR, ON LF, OR ON CRLF - AND CRLF COUNTS ONCE. fc
# counted only LF, so everything after a bare CR was reported on line 1
# at a column that measured the whole text. The statement text is the
# point of these, so the label spells the shape rather than echoing a
# statement with a CR in it.
layout() { # <label> <stmt>
    got=$(vec_run "$PORT" "$WORK" "$2")
    want=$(vec_run "$ENGPORT" "$REF" "$2")
    check "$1" "$got" "$want"
}
layout "B9. a bare CR ends the line"          "SELECT *"$'\r'"FROM PNOOUT"
layout "B10. a LEADING bare CR"               $'\r'"SELECT * FROM PNOOUT"
layout "B11. two bare CRs, two lines"         "SELECT *"$'\r'"FROM"$'\r'"PNOOUT"
layout "B12. a CR and a later LF each count"  "SELECT *"$'\r'"FROM"$'\n'"  PNOOUT"
layout "B13. CRLF is ONE break, not two"      "SELECT *"$'\r\n'"FROM PNOOUT"
# the rest of the position story, pinned beside them: none of these
# shapes may move now that the counter changed
layout "B14. a leading LF"                    $'\n'"SELECT * FROM PNOOUT"
layout "B15. leading spaces"                  "  SELECT * FROM PNOOUT"
layout "B16. a TAB is one column"             "SELECT"$'\t'"* FROM PNOOUT"
layout "B17. a FORM FEED is space, not a break" "SELECT *"$'\x0c'"FROM PNOOUT"
layout "B18. extra internal spaces"           "SELECT  *   FROM   PNOOUT"
layout "B19. an inline /* */ comment"         "SELECT * /* c */ FROM PNOOUT"
layout "B20. a /* */ comment spanning a line" "SELECT * /* a"$'\n'"b */ FROM PNOOUT"
layout "B21. a mid-statement -- comment"      "SELECT * -- x"$'\n'"FROM PNOOUT"
layout "B22. a trailing semicolon"            "SELECT * FROM PNOOUT;"
layout "B23. lower-case SQL"                  "select * from pnoout"

# --- C. LAW 10: arity beats both -------------------------------------
both "C1. too few arguments"                 "SELECT * FROM PNSARG(1)"
both "C2. too many arguments"                "SELECT * FROM PNSARG(1,2,3)"
both "C3. none at all"                       "SELECT * FROM PNSARG"
both "C4. on a SELECTABLE procedure"         "SELECT * FROM PSELARG(1)"
both "C5. arguments to a no-input selectable" "SELECT * FROM PSEL(1)"
# THE SPEC HAD THIS BACKWARDS. Re-probed live: a 0-output procedure
# answers -84 whatever the arity - too few arguments, too many, or
# right. Zero-outputs is checked BEFORE parameter matching.
both "C6. 0-output + too few arguments is -84, NOT arity" "SELECT * FROM PNOUTARG"
both "C6b. 0-output + too many arguments, likewise" "SELECT * FROM PNOUTARG(1,2)"
both "C7. arguments to a no-input TYPE 2"    "SELECT * FROM PNS(1)"
both "C8. arity still wins under FIRST"      "SELECT FIRST 1 * FROM PNSARG(1)"

# --- D. LAW 4: the [] that is CORRECT ---------------------------------
# An UNREACHABLE SUSPEND is still a SUSPEND: TYPE 1, prepare OK, one
# output column, zero rows. Breaking these is how a naive "raise when no
# rows came back" fix would look.
both "D1. a real selectable procedure"       "SELECT * FROM PSEL"
both "D2. SUSPEND inside IF (1=0)"           "SELECT * FROM PIF"
both "D3. SUSPEND inside a FOR over an empty table" "SELECT * FROM PFOR"
both "D4. SUSPEND inside WHILE (1=0)"        "SELECT * FROM PWHILE"
# PEXIT is TYPE 1 and the engine answers []. This used to be a RECORDED
# BOUNDARY - fc's interpreter had no EXIT and refused at execute - and
# the boundary is gone: EXIT is converted (qa/serve-real-cursors.sh), so
# the two agree and this is an ordinary differential check again.
#
# The gate caught that itself, which is the point of writing a boundary
# down as an assertion rather than a comment: when the difference
# disappeared, the sweep said so instead of quietly passing.
both "D5. a SUSPEND made dead by EXIT still answers []" "SELECT * FROM PEXIT"
both "D6. a modifier over a selectable one"  "SELECT FIRST 3 X FROM PSEL"
both "D7. a modifier over an unreachable SUSPEND" "SELECT FIRST 3 X FROM PIF"
both "D8. LAW 14: NULL arguments flow through" "SELECT * FROM PSELARG(NULL,2)"
both "D9. arguments that add up"             "SELECT * FROM PSELARG(4,5)"

# --- E. LAW 12: EXECUTE PROCEDURE is untouched ------------------------
same "E1. EXECUTE PROCEDURE on a TYPE 2 with an output" "EXECUTE PROCEDURE PNS"
same "E2. only the FIRST SUSPEND's values"   "EXECUTE PROCEDURE PSEL"
same "E3. an unfired SUSPEND returns NULL"   "EXECUTE PROCEDURE PIF"
same "E4. the SAME 0-output procedure B1 refused in FROM" "EXECUTE PROCEDURE PNOOUT"
# ... and here the body really DID run, on both sides - which is what
# makes B7 a statement about the FAILED PREPARE and not about a body
# fire-crab simply cannot execute
check "E5. EXECUTE PROCEDURE's INSERT landed (engine reads fc's file)" \
      "$(col "$WORK" "SELECT ID FROM T")" "99"
check "E6. ... and on the ref copy" "$(col "$REF" "SELECT ID FROM T")" "99"
# An EMPTY body is outside fire-crab's PSQL surface: the engine's
# EXECUTE PROCEDURE succeeds silently, fc refuses. PRE-EXISTING and
# unrelated to selectability (verified against the pre-change binary) -
# recorded, not hidden, and asserted so that implementing it says so.
e7fc=$(printf 'EXECUTE PROCEDURE PEMPTY;\n' |
       "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$WORK" 2>&1 | tr -s ' \n' ' ' | strip)
e7en=$(printf 'EXECUTE PROCEDURE PEMPTY;\n' |
       "$ISQL" -q -b -user "$U" -pas "$P" "$REF" 2>&1 | tr -s ' \n' ' ' | strip)
ran=$((ran + 1))
if [ -z "$e7en" ] && case "$e7fc" in *"Statement failed"*) true ;; *) false ;; esac; then
    echo "OK   E7. EXECUTE PROCEDURE on BEGIN END: engine silent, fc refuses (boundary)"
else
    echo "DIFF E7. the empty-body boundary moved"
    echo "     engine: [$e7en]"; echo "     fc:     [$e7fc]"; fail=1
fi

# --- F. LAW 17: selectability is LIVE metadata ------------------------
# ALTER the SUSPEND IN through the engine on both files, then ask
# fire-crab again. A hard-coded name list would keep refusing.
alter_both() { # <sql>
    for f in "$WORK" "$REF"; do
        printf 'SET TERM ^ ;\n%s^\nSET TERM ; ^\nCOMMIT;\n' "$1" |
            "$ISQL" -q -b -user "$U" -pas "$P" "$f" >/dev/null 2>&1 ||
            { echo "FAIL ALTER on $f"; exit 1; }
    done
}
alter_both "ALTER PROCEDURE PNS RETURNS (X INTEGER) AS BEGIN X = 42; SUSPEND; END"
both "F1. SUSPEND added: the same statement now ANSWERS" "SELECT * FROM PNS"
alter_both "ALTER PROCEDURE PNS RETURNS (X INTEGER) AS BEGIN X = 42; END"
both "F2. SUSPEND removed: the identical vector returns" "SELECT * FROM PNS"

# --- G. the recorded boundaries, as "both sides error" ----------------
# fc refuses generically here (the offset arithmetic differs for each of
# these shapes, and a fabricated number in a status vector is a wrong
# answer). What must never come back is rows, or [].
errs "G1. an aggregate over the call"    "SELECT COUNT(*) FROM PNS"
errs "G2. a WHERE over the call"         "SELECT * FROM PNS WHERE X = 1"
errs "G3. an ORDER BY over the call"     "SELECT * FROM PNS ORDER BY X"
errs "G4. a derived table wrapping it"   "SELECT * FROM (SELECT * FROM PNS) Q"
errs "G5. a JOIN against it"             "SELECT * FROM T JOIN PNS ON 1=1"
errs "G6. an IN-subquery over it"        "SELECT * FROM T WHERE ID IN (SELECT X FROM PNS)"
errs "G7. a CTE over it"                 "WITH C AS (SELECT X FROM PNS) SELECT * FROM C"
errs "G8. empty argument parentheses"    "SELECT * FROM PNS()"
errs "G9. an unknown column beats it"    "SELECT NOSUCHCOL FROM PNS"
errs "G10. a derived table over a 0-output one" "SELECT * FROM (SELECT * FROM PNOOUT) Q"

# --- H. teeth: the vectors must be the SPECIFIC ones, not "an error" --
# every check above compares fc against the engine, so a fc that refused
# everything generically would already fail - but a gate that stopped
# reaching the -104 path at all would go quietly green. Pin the three
# leading gdscodes explicitly, out of fc's OWN answer.
h1=$(vec_run "$PORT" "$WORK" "SELECT * FROM PNS")
case "$h1" in
    *335544343*335544868*) echo "OK   H1. fc really ships isc_invalid_blr + isc_illegal_prc_type" ;;
    *) echo "DIFF H1. fc's -104 vector is not the probed one: $h1"; fail=1 ;;
esac
ran=$((ran + 1))
h2=$(vec_run "$PORT" "$WORK" "SELECT * FROM PNOOUT")
case "$h2" in
    *335544668*336397208*) echo "OK   H2. fc really ships isc_dsql_procedure_use_err + line/col" ;;
    *) echo "DIFF H2. fc's -84 vector is not the probed one: $h2"; fail=1 ;;
esac
ran=$((ran + 1))
h3=$(vec_run "$PORT" "$WORK" "SELECT * FROM PNSARG(1)")
case "$h3" in
    *335544512*) echo "OK   H3. fc really ships isc_prcmismat for the arity case" ;;
    *) echo "DIFF H3. fc's arity vector is not the probed one: $h3"; fail=1 ;;
esac
ran=$((ran + 1))

# --- the ran counter ---------------------------------------------------
if [ "$ran" -ne 82 ]; then
    echo "DIFF $ran checks ran (expected exactly 82) - did one silently skip?"
    fail=1
fi

kill $srv 2>/dev/null; wait $srv 2>/dev/null; srv=""
rm -f "$WORK" "$REF" "$VJS"
exit $fail
