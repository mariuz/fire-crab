#!/bin/bash
# SQL COMMENTS - `/* ... */` and `-- to end of line` - accepted in every
# statement, as the engine's lexer treats them: whitespace. fire-crab
# refused a comment ANYWHERE outside a PSQL body (`SELECT 1 /* c */`
# was a generic 42000), which is why every script that reaches fc had to
# be comment-stripped by hand.
#
# The transform: comments blanked to SPACES, byte for byte, at the FOUR
# statement entries (the three wire decode sites and PSQL's EXECUTE
# STATEMENT) - position-preserving, so every byte offset (error line/col
# mapping included) matches the original; quote-aware for `'` strings
# and `"` identifiers with doubled-quote escapes; block comments do NOT
# nest (the first `*/` closes, as the engine -104s the leftover); a
# comment separates tokens (`SELECT/*t*/2` answers); unterminated blanks
# to the end. The PSQL body parser's own strip became the same function,
# which also fixed its latent Latin-1 mangling of non-ASCII bodies.
#
# Boundaries (recorded): a routine/view/check CREATED THROUGH fc's wire
# stores its RDB$SOURCE with the comments BLANKED to spaces - same
# length, same line/col coordinates - where the engine stores them
# verbatim (fc's RDB$DEFAULT_SOURCE was already re-rendered; gbak-carried
# and engine-built sources keep their comments); the nested-comment
# refusal is fc's generic vector where the engine spells -104.
#
#   qa/serve-real-comments.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4963}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-cmt-crab.fdb"; B="$D/fc-cmt-engine.fdb"
LOG="/tmp/fc-serve-cmt-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

# --- comments in every statement class, one commented script ---
cat > "$D/cmt.sql" <<'SQL'
/* leading */ CREATE TABLE TB (ID INTEGER, S VARCHAR(20)) /* trailing */;
COMMIT;
SET TERM ^ ;
CREATE PROCEDURE PC (A INTEGER) RETURNS (R INTEGER) AS
BEGIN
  -- a body comment
  R = A + 1; /* another */
END^
SET TERM ; ^
CREATE VIEW VC (ID) AS SELECT ID /* in view */ FROM TB;
COMMIT;
INSERT INTO TB (ID, S) VALUES (1 /* c */, 'x'); -- tail
INSERT INTO TB (ID, S) VALUES (2, '-- keep');
INSERT INTO TB (ID, S) VALUES (3, '/* keep */');
UPDATE TB SET S = 'y' /* c */ WHERE ID = 1;
DELETE /* d */ FROM TB WHERE ID = 99;
COMMIT;
SET LIST ON;
EXECUTE PROCEDURE PC 41 /* call */;
SELECT/*tight*/ID, S -- cols
  FROM TB ORDER BY ID;
SELECT '--not a comment' A, "S" /* quoted ident */ FROM TB WHERE ID = 2;
SELECT COUNT(*) VC_OK FROM VC;
SELECT 3/*x*/+ 4 C7 FROM RDB$DATABASE;
SELECT 5 /* -- line inside block */ D5 FROM RDB$DATABASE;
SELECT 6 -- block /* inside line
 E6 FROM RDB$DATABASE;
SQL
cof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/cmt.sql" 2>&1 | norm; }
check "comments ride every statement class (DDL, PSQL bodies, DML, projections, tight adjacency, markers-in-markers, strings kept)" \
    "$(cof "127.0.0.1/$PORT:$A")" "$(cof "127.0.0.1/$REAL:$B")"

# --- EXECUTE STATEMENT: the dynamic text carries comments too ---
cat > "$D/cdyn.sql" <<'SQL'
SET TERM ^ ;
EXECUTE BLOCK RETURNS (N INTEGER) AS
BEGIN
  EXECUTE STATEMENT 'SELECT COUNT(*) /* dyn */ FROM TB -- tail
' INTO :N;
  SUSPEND;
END^
SET TERM ; ^
SQL
dof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/cdyn.sql" 2>&1 | norm; }
check "EXECUTE STATEMENT strips its dynamic text (the fourth entry)" \
    "$(dof "127.0.0.1/$PORT:$A")" "$(dof "127.0.0.1/$REAL:$B")"

# --- a commented body's runtime error keeps its vector (fc omits the
# --- engine's At-procedure line/col frame - the recorded fc-wide shape)
cat > "$D/cerr.sql" <<'SQL'
SET TERM ^ ;
CREATE PROCEDURE PERR (A INTEGER) RETURNS (R INTEGER) AS
BEGIN
  -- comment line
  /* another
     multiline */
  R = A / 0;
END^
SET TERM ; ^
COMMIT;
EXECUTE PROCEDURE PERR 1;
SQL
eof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/cerr.sql" 2>&1 | grep -v '^$' | grep -v "^After line" | grep -v "At procedure" | tr '\n' '|'; }
check "a commented body raises the same vector (minus the recorded At-frame)" \
    "$(eof "127.0.0.1/$PORT:$A")" "$(eof "127.0.0.1/$REAL:$B")"

# --- the ENGINE runs what fc stored from commented DDL ---
ran=$((ran + 1))
eng=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$REAL:$A" 2>&1 <<'SQL' | norm
SET LIST ON;
EXECUTE PROCEDURE PC 10;
SELECT COUNT(*) V FROM VC;
SQL
)
case "$eng" in *"R 11"*) echo "OK   the engine runs the procedure and view fc stored from commented DDL";;
    *) echo "DIFF engine-runs-fc: [$eng]"; fail=1;; esac

# --- fc's stored source: comments BLANKED, length kept (the recorded
# --- divergence - the engine stores them verbatim)
ran=$((ran + 1))
src=$("$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 <<'SQL'
SET LIST ON; SET BLOB ALL;
SELECT RDB$PROCEDURE_SOURCE FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_NAME = 'PC';
SQL
)
case "$src" in *"body comment"*) echo "DIFF fc stored the comment text (expected blanked): [$src]"; fail=1;;
    *"R = A + 1;"*) echo "OK   fc's stored source keeps positions with comments blanked (recorded divergence)";;
    *) echo "DIFF stored source unreadable: [$src]"; fail=1;; esac

# --- the nested-comment refusal (engine -104 at the leftover token) ---
ran=$((ran + 1))
nc=$(echo "SELECT 1 /* a /* nested */ still */ X FROM RDB\$DATABASE;" | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1)
case "$nc" in *"Dynamic SQL Error"*) echo "OK   a nested block comment refuses (the first */ closes)";;
    *) echo "DIFF nested comment answered: [$nc]"; fail=1;; esac

# --- ENGINE-BUILT stored sources carrying comments, read through fc:
# --- the view re-plan, computed columns and CHECK re-parse all strip at
# --- read (review-caught: '--' in a stored source read as double
# --- negation; '/*' refused DML the engine serves)
EF="$D/fc-cmt-engsrc.fdb"; FF="$D/fc-cmt-engsrc2.fdb"
rm -f "$EF" "$FF"
"$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 <<SQL
CREATE DATABASE '$EF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE BASE (V INTEGER);
CREATE VIEW V2 (X) AS SELECT V FROM BASE WHERE V > 1 -- keep big
;
CREATE TABLE C1 (V INTEGER CHECK (V > 0 /* pos */));
CREATE TABLE CM (A INTEGER, D COMPUTED BY (A * 2 /* dbl */));
INSERT INTO BASE VALUES (1); INSERT INTO BASE VALUES (5);
INSERT INTO CM (A) VALUES (10);
COMMIT;
SQL
cp "$EF" "$FF"; chmod 666 "$EF" "$FF"
cat > "$D/cread.sql" <<'SQL'
SET LIST ON;
SELECT X FROM V2;
SELECT A, D FROM CM;
INSERT INTO C1 (V) VALUES (3);
INSERT INTO C1 (V) VALUES (-3);
COMMIT;
SELECT V FROM C1;
SQL
rof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/cread.sql" 2>&1 | grep -v '^$' | grep -v "^After line" | grep -v "At trigger" | tr '
' '|'; }
check "engine-built commented sources (view, computed, CHECK) serve identically"     "$(rof "127.0.0.1/$PORT:$FF")" "$(rof "127.0.0.1/$REAL:$EF")"
rm -f "$EF" "$FF"

# --- an UNTERMINATED block comment refuses (the engine's -104; isql eats
# --- it client-side, so the server-side path is a dynamic statement)
cat > "$D/cunterm.sql" <<'SQL'
SET TERM ^ ;
EXECUTE BLOCK RETURNS (N INTEGER) AS
BEGIN
  EXECUTE STATEMENT 'SELECT 7 FROM RDB$DATABASE /* open' INTO :N;
  SUSPEND;
END^
SET TERM ; ^
SQL
ran=$((ran + 1))
uc=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" -i "$D/cunterm.sql" 2>&1)
case "$uc" in *"Dynamic SQL Error"*) echo "OK   an unterminated block comment refuses (never silently swallowed)";;
    *) echo "DIFF unterminated comment answered: [$uc]"; fail=1;; esac

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
