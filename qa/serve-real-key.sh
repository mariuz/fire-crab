#!/bin/bash
# NAMED PRIMARY KEY constraints and UNIQUE constraints in CREATE TABLE.
# Until now fire-crab wrote one shape only: an unnamed PRIMARY KEY, its
# index named RDB$PRIMARY<n>, plus a NOT NULL constraint row for every
# not-null column. Three engine facts, probed and now implemented:
#
#   1. a NAMED constraint names its INDEX too - CONSTRAINT PK_P PRIMARY
#      KEY (A,B) yields RDB$INDICES.RDB$INDEX_NAME = 'PK_P', not
#      RDB$PRIMARY<n>;
#   2. a TABLE-level PRIMARY KEY sets its columns' RDB$NULL_FLAG but
#      writes NO 'NOT NULL' constraint row (a COLUMN-level PRIMARY KEY
#      does write one) - fire-crab wrote one either way;
#   3. the generated index names RDB$PRIMARY<n> (primary) and RDB$<n>
#      (unique) come from ONE sequence, and the INTEG_<n> constraint
#      names likewise, both advanced in the engine's TWO-PASS order:
#      every COLUMN-LEVEL (inline) constraint first - the columns in
#      declaration order and, within one column, its clauses in written
#      order - and only THEN every TABLE-LEVEL clause, in declaration
#      order. KM2 is the decisive shape: its inline UNIQUE on B is
#      written LAST and numbered FIRST, ahead of the table-level
#      UNIQUE (A) before it. No single-pass text order can do that, and
#      two rules that tried numbered INTEG_4 onto a different constraint
#      on the two servers' copies of one file.
#
# The differential is the engine, three ways:
#   1. the catalog the engine reads from fire-crab's file matches, row
#      for row, an engine-built reference of the SAME schema - names,
#      index names, segments, null flags, check-constraint links;
#   2. the constraints are LIVE on fire-crab's raw file: fire-crab
#      itself refuses a duplicate unique key, and the engine refuses
#      one too (and refuses a NULL in a PK column);
#   3. gbak backs up and RESTORES the file, the restored database
#      enforces the same constraints and gfix finds it clean.
#
#   qa/serve-real-key.sh [port]
#
# Builds its own scratch database.

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4117}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
WORK="$D/fc-key-work.fdb"; REF="$D/fc-key-ref.fdb"
FBK="$D/fc-key-work.fbk"; RST="$D/fc-key-rst.fdb"
# the identifier-length and deferred-drop sections build their own
# databases: both need a file nothing else writes, and the collision one
# has to be BACKED UP AND RESTORED on its own
NAM="$D/fc-key-name.fdb"; NBK="$D/fc-key-name.fbk"; NRS="$D/fc-key-name-rst.fdb"
DFD="$D/fc-key-defer.fdb"

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; rm -f "$WORK" "$REF" "$FBK" "$RST" "$NAM" "$NBK" "$NRS" "$DFD"

# NAMED table-level compound PRIMARY KEY: index named after the constraint
DDL_KP="CREATE TABLE KP (A INTEGER, B INTEGER, PNAME VARCHAR(10), CONSTRAINT PK_KP PRIMARY KEY (A, B))"
# NAMED column-level PRIMARY KEY: also a NOT NULL constraint row for X
DDL_KQ="CREATE TABLE KQ (X INTEGER CONSTRAINT PK_KQ PRIMARY KEY, Y VARCHAR(10))"
# NAMED table-level UNIQUE over a NOT NULL column
DDL_KU="CREATE TABLE KU (Z INTEGER NOT NULL, W INTEGER, CONSTRAINT UQ_KU UNIQUE (Z))"
# UNNAMED UNIQUE declared BEFORE an unnamed PRIMARY KEY: exercises both
# generated-name sequences in declaration order
DDL_KM="CREATE TABLE KM (A INTEGER NOT NULL, B INTEGER, UNIQUE (B), C INTEGER NOT NULL, PRIMARY KEY (A))"
# unnamed COLUMN-level UNIQUE (nullable - UNIQUE implies nothing here)
DDL_KC="CREATE TABLE KC (A INTEGER UNIQUE, B INTEGER)"
# a FOREIGN KEY onto the NAMED compound PK: the partner lookup has to
# find PK_KP's index by its constraint name, not by an RDB$PRIMARY<n>
DDL_KF="CREATE TABLE KF (ID INTEGER NOT NULL PRIMARY KEY, FA INTEGER, FB INTEGER, CONSTRAINT FK_KF FOREIGN KEY (FA, FB) REFERENCES KP (A, B))"
# --- the two-pass numbering law, six shapes (all measured on the engine
# --- through 127.0.0.1/3050, both files read back BY THE ENGINE) ---
# KM2: THE DECISIVE ONE. B's INLINE UNIQUE is written last and numbered
# FIRST, because it is column-level and UNIQUE (A) ahead of it is
# table-level. Under strict declaration order fire-crab numbered A's.
DDL_KM2="CREATE TABLE KM2 (A INTEGER, UNIQUE (A), B INTEGER UNIQUE)"
# KM5: the same law with CHECKs, independently - the table-level CHECK
# written between B and C lands AFTER C's inline UNIQUE
DDL_KM5="CREATE TABLE KM5 (A INTEGER CHECK (A > 0), B INTEGER NOT NULL, CHECK (B < 100), C INTEGER UNIQUE)"
# KN1/KN2: WITHIN one column it is plain text order - the same two
# clauses swap numbers when the text swaps them
DDL_KN1="CREATE TABLE KN1 (A INTEGER UNIQUE NOT NULL, B INTEGER)"
DDL_KN2="CREATE TABLE KN2 (A INTEGER NOT NULL UNIQUE, B INTEGER)"
# KN3/KN4: a NOT NULL, and a key clause, written AFTER an inline CHECK
# on the same column. The engine accepts both; fire-crab REFUSED both
# with a bare "Dynamic SQL Error" because the inline-CHECK split took
# the rest of the item as the check's source.
DDL_KN3="CREATE TABLE KN3 (A INTEGER CHECK (A > 0) NOT NULL, B INTEGER)"
DDL_KN4="CREATE TABLE KN4 (A INTEGER CHECK (A > 0) NOT NULL UNIQUE, B INTEGER)"
# KM1: every constraint COLUMN-level, so pass 1 alone orders them and
# the answer reads like plain declaration order - the shape the FIRST
# superseded rule ("every NOT NULL first, then every key") broke
DDL_KM1="CREATE TABLE KM1 (ID INTEGER NOT NULL PRIMARY KEY, C INTEGER UNIQUE, D VARCHAR(10) NOT NULL)"
# KN5: a column-level PRIMARY KEY IMPLIES its NOT NULL, and the implied
# row is numbered just BEFORE the key even when the explicit NOT NULL is
# written after it
DDL_KN5="CREATE TABLE KN5 (A INTEGER PRIMARY KEY NOT NULL, B INTEGER)"
# --- the same law, extended to the FOURTH constraint kind: a FOREIGN
# --- KEY is numbered WHERE IT IS WRITTEN, not last. All engine-measured
# --- through 127.0.0.1/3050, both files read back BY THE ENGINE.
# KF1 (F1): THE DECISIVE FK SHAPE. The INLINE `REFERENCES` on B is
# written LAST and numbered FIRST, ahead of the table-level UNIQUE (A) -
# the KM2 inversion on a different constraint kind. It is also the form
# fire-crab had NO parse path for: every column-level REFERENCES was
# refused with a bare "Dynamic SQL Error".
DDL_KF1="CREATE TABLE KF1 (A INTEGER, UNIQUE (A), B INTEGER REFERENCES KQ)"
# KF2 (F2): a TABLE-level FOREIGN KEY written BEFORE column B still
# lands after B's column-level NOT NULL - the passes are about where a
# clause is ATTACHED, not about what kind it is
DDL_KF2="CREATE TABLE KF2 (A INTEGER, FOREIGN KEY (A) REFERENCES KQ, B INTEGER NOT NULL)"
# KG1/KG2: the SAME two table-level clauses, swapped in the text and
# swapped in the answer. A writer that always issues the FK the last
# numbers is right on KG2 by luck and wrong on KG1.
DDL_KG1="CREATE TABLE KG1 (A INTEGER, B INTEGER, FOREIGN KEY (A) REFERENCES KQ, UNIQUE (B))"
DDL_KG2="CREATE TABLE KG2 (A INTEGER, B INTEGER, UNIQUE (B), FOREIGN KEY (A) REFERENCES KQ)"
# KG3: the same against a table-level CHECK
DDL_KG3="CREATE TABLE KG3 (A INTEGER, B INTEGER, FOREIGN KEY (A) REFERENCES KQ, CHECK (B > 0))"
# KR1/KR2/KR3: the three inline REFERENCES forms - on a later column, on
# the FIRST column, and with an explicit referenced-column list. An
# absent list means the parent's PRIMARY KEY.
DDL_KR1="CREATE TABLE KR1 (A INTEGER, B INTEGER REFERENCES KQ)"
DDL_KR2="CREATE TABLE KR2 (A INTEGER REFERENCES KQ)"
DDL_KR3="CREATE TABLE KR3 (A INTEGER, B INTEGER REFERENCES KQ (X))"
# --- the rules a foreign key STORES. `NO ACTION` is NOT `RESTRICT`:
# --- the engine writes back the rule that was written, and folding the
# --- two together wrote RESTRICT into a file where the engine writes
# --- NO ACTION - a silent wrong write that survives gbak, and the only
# --- catalog divergence among the eighty FK shapes both servers accept.
DDL_KNA="CREATE TABLE KNA (A INTEGER, B INTEGER REFERENCES KQ ON DELETE NO ACTION ON UPDATE NO ACTION)"
DDL_KNB="CREATE TABLE KNB (A INTEGER, B INTEGER, FOREIGN KEY (B) REFERENCES KQ ON DELETE NO ACTION)"
# --- a referential ACTION synthesises a system trigger on the PARENT
# --- table, and the engine also writes the RDB$CHECK_CONSTRAINTS row
# --- tying that trigger to the FK's constraint name. Without the link
# --- the constraint disappears from both catalogs on a DROP while the
# --- unreferenced AFTER DELETE trigger SURVIVES and still cascades, so
# --- a row the engine keeps is silently deleted.
DDL_KEC="CREATE TABLE KEC (A INTEGER, B INTEGER REFERENCES KQ ON DELETE CASCADE)"
DDL_KED="CREATE TABLE KED (A INTEGER, B INTEGER REFERENCES KQ ON UPDATE CASCADE ON DELETE SET NULL)"
# --- a column may carry TWO inline REFERENCES (the engine accepts it)
DDL_KX3="CREATE TABLE KX3 (A INTEGER REFERENCES KQ REFERENCES KQ2)"
DDL_KQ2="CREATE TABLE KQ2 (X INTEGER NOT NULL PRIMARY KEY, Y VARCHAR(10))"
# --- the compound parent the ARITY refusals are measured against, and a
# --- SMALLINT child, which is the type pair BOTH servers accept
DDL_KPC="CREATE TABLE KPC (X INTEGER NOT NULL, Y INTEGER NOT NULL, PRIMARY KEY (X, Y))"
DDL_KCS="CREATE TABLE KCS (A SMALLINT REFERENCES KQ)"
# --- the DROP-takes-its-trigger pair. NAMED, so the gate can drop it by
# --- a name it knows. Its ON DELETE CASCADE trigger sits on KEP.
DDL_KEP="CREATE TABLE KEP (ID INTEGER NOT NULL PRIMARY KEY)"
DDL_KEE="CREATE TABLE KEE (A INTEGER CONSTRAINT FK_KEE REFERENCES KEP ON DELETE CASCADE)"

# ---- shapes BOTH servers must REFUSE. None of them may be written, so
# ---- none of them appears in the reference DDL; each is asserted
# ---- against the engine's own answer below.
#
# A. two overlapping split spans. These four PANICKED the connection
#    thread ("byte range starts at 36 but ends at 23") and the client saw
#    a dropped TCP connection rather than an SQL error - the one answer
#    no input may provoke. Two of them carry no REFERENCES at all.
DDL_ZC1="CREATE TABLE ZC1 (A INTEGER CHECK (A > 0 CONSTRAINT C) CHECK (A < 9))"
DDL_ZC2="CREATE TABLE ZC2 (A INTEGER CONSTRAINT C1 CHECK (A > 0 CONSTRAINT C2) CHECK (A < 9))"
DDL_ZC5="CREATE TABLE ZC5 (A INTEGER CHECK (A > 0 CONSTRAINT C) REFERENCES KQ)"
DDL_ZC3="CREATE TABLE ZC3 (A INTEGER REFERENCES CONSTRAINT N CHECK (A > 0))"
# B. a foreign key whose COLUMN COUNT does not match the key it
#    references: -607 "FOREIGN KEY column count does not match PRIMARY
#    KEY". Written, fire-crab did not enforce it, the ENGINE reading the
#    same file did, and `gbak -c` of the result failed outright.
DDL_ZB1="CREATE TABLE ZB1 (A INTEGER, B INTEGER REFERENCES KPC)"
DDL_ZB2="CREATE TABLE ZB2 (A INTEGER, B INTEGER, FOREIGN KEY (B) REFERENCES KPC)"
DDL_ZB3="CREATE TABLE ZB3 (A INTEGER, B INTEGER, FOREIGN KEY (A, B) REFERENCES KQ)"
# C. a TYPE-INCOMPATIBLE foreign key: "partner index segment no 1 has
#    incompatible data type". KQ's key is INTEGER.
DDL_ZT1="CREATE TABLE ZT1 (A BIGINT REFERENCES KQ)"
DDL_ZT2="CREATE TABLE ZT2 (A BIGINT, FOREIGN KEY (A) REFERENCES KQ)"
DDL_ZT3="CREATE TABLE ZT3 (A VARCHAR(20) REFERENCES KQ)"

# fire-crab's file starts as an engine-created empty database; the engine
# reference gets the same tables in the same order via ordinary DDL.
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL scratch db"; exit 1; }
CREATE DATABASE '$WORK' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF || { echo "FAIL ref db"; exit 1; }
CREATE DATABASE '$REF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
$DDL_KP;
$DDL_KQ;
$DDL_KU;
$DDL_KM;
$DDL_KC;
$DDL_KF;
$DDL_KM2;
$DDL_KM5;
$DDL_KN1;
$DDL_KN2;
$DDL_KN3;
$DDL_KN4;
$DDL_KM1;
$DDL_KN5;
$DDL_KF1;
$DDL_KF2;
$DDL_KG1;
$DDL_KG2;
$DDL_KG3;
$DDL_KR1;
$DDL_KR2;
$DDL_KR3;
$DDL_KQ2;
$DDL_KNA;
$DDL_KNB;
$DDL_KEC;
$DDL_KED;
$DDL_KX3;
$DDL_KPC;
$DDL_KCS;
$DDL_KEP;
$DDL_KEE;
COMMIT;
EOF

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-key.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$WORK" "$REF" "$FBK" "$RST" "$NAM" "$NBK" "$NRS" "$DFD"' EXIT
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
node_once() {
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q="$1" timeout 15 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          console.log(e2?("ERR "+(e2.message||"").split("\n")[0]):"OK");
          db.detach();process.exit(0);});
      });' 2>/dev/null
}
node_run() {
    n=0
    while [ $n -lt 10 ]; do
        r=$(node_once "$1")
        case "$r" in
            *CONN_ERR*|"") n=$((n + 1)); sleep 0.3 ;;
            *) printf '%s' "$r" | strip; return ;;
        esac
    done
    echo CONN_ERR
}

# TWO statements on ONE connection, answers joined by `;`. The A shapes
# below PANICKED the connection thread, and the client's symptom was a
# DROPPED TCP CONNECTION, not an SQL error - so a gate that only looked
# at the first answer would have called the panic a refusal and passed.
# The second statement is the assertion that the connection is still
# there.
node_two() { # <sql1> <sql2>
    FC_DB="$WORK" FC_PORT="$PORT" FC_Q1="$1" FC_Q2="$2" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q1,(e1)=>{
          const a = e1 ? ((/connection/i.test(e1.message||"")) ? "LOST" : "ERR") : "OK";
          db.query(process.env.FC_Q2,(e2,r)=>{
            const b = e2 ? ((/connection/i.test(e2.message||"")) ? "LOST" : "ERR") : "OK";
            console.log(a+";"+b);
            db.detach();process.exit(0);});
        });
      });' 2>/dev/null
}

fail=0
check() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi
}

# --- fire-crab writes the schema ---
check "named compound PK (table level)"  "$(node_run "$DDL_KP")" "OK"
check "named PK (column level)"          "$(node_run "$DDL_KQ")" "OK"
check "named UNIQUE"                     "$(node_run "$DDL_KU")" "OK"
check "unnamed UNIQUE then unnamed PK"   "$(node_run "$DDL_KM")" "OK"
check "unnamed column-level UNIQUE"      "$(node_run "$DDL_KC")" "OK"
check "FK onto the named compound PK"    "$(node_run "$DDL_KF")" "OK"
check "inline UNIQUE after a table-level one" "$(node_run "$DDL_KM2")" "OK"
check "inline CHECK, table CHECK, inline UNIQUE" "$(node_run "$DDL_KM5")" "OK"
check "UNIQUE then NOT NULL on one column" "$(node_run "$DDL_KN1")" "OK"
check "NOT NULL then UNIQUE on one column" "$(node_run "$DDL_KN2")" "OK"
check "NOT NULL written after an inline CHECK" "$(node_run "$DDL_KN3")" "OK"
check "NOT NULL and UNIQUE after an inline CHECK" "$(node_run "$DDL_KN4")" "OK"
check "every constraint column-level"    "$(node_run "$DDL_KM1")" "OK"
check "explicit NOT NULL after an inline PK" "$(node_run "$DDL_KN5")" "OK"
check "inline REFERENCES after a table-level UNIQUE" "$(node_run "$DDL_KF1")" "OK"
check "table-level FK before a NOT NULL column" "$(node_run "$DDL_KF2")" "OK"
check "table-level FK then UNIQUE"       "$(node_run "$DDL_KG1")" "OK"
check "table-level UNIQUE then FK"       "$(node_run "$DDL_KG2")" "OK"
check "table-level FK then CHECK"        "$(node_run "$DDL_KG3")" "OK"
check "inline REFERENCES"                "$(node_run "$DDL_KR1")" "OK"
check "inline REFERENCES on the first column" "$(node_run "$DDL_KR2")" "OK"
check "inline REFERENCES with a column list" "$(node_run "$DDL_KR3")" "OK"
check "a second FK parent table"         "$(node_run "$DDL_KQ2")" "OK"
check "inline REFERENCES ON DELETE/UPDATE NO ACTION" "$(node_run "$DDL_KNA")" "OK"
check "table-level FK ON DELETE NO ACTION" "$(node_run "$DDL_KNB")" "OK"
check "inline REFERENCES ON DELETE CASCADE" "$(node_run "$DDL_KEC")" "OK"
check "inline REFERENCES with both actions" "$(node_run "$DDL_KED")" "OK"
check "two inline REFERENCES on one column" "$(node_run "$DDL_KX3")" "OK"
check "compound-PK parent for the arity shapes" "$(node_run "$DDL_KPC")" "OK"
check "SMALLINT child onto an INTEGER key" "$(node_run "$DDL_KCS")" "OK"
check "cascade parent for the drop test"  "$(node_run "$DDL_KEP")" "OK"
check "named cascade child"               "$(node_run "$DDL_KEE")" "OK"

# --- A. TWO OVERLAPPING SPLIT SPANS MUST NOT PANIC. Each shape must
# --- answer a clean SQL error AND leave the connection alive: the
# --- second statement on the SAME connection has to still answer.
for z in "$DDL_ZC1" "$DDL_ZC2" "$DDL_ZC5" "$DDL_ZC3"; do
    r=$(node_two "$z" "SELECT 1 AS X FROM RDB\$DATABASE")
    lbl=$(printf '%s' "$z" | sed 's/^CREATE TABLE \([A-Z0-9]*\).*/\1/')
    check "overlapping spans refuse and the connection survives ($lbl)" "$r" "ERR;OK"
done

# --- B/C. A FOREIGN KEY THE ENGINE REFUSES MUST BE REFUSED, not
# --- written: fire-crab did not enforce what it wrote, the engine
# --- reading the same file did, and gbak could not restore it.
for z in "$DDL_ZB1" "$DDL_ZB2" "$DDL_ZB3" "$DDL_ZT1" "$DDL_ZT2" "$DDL_ZT3"; do
    r=$(node_two "$z" "SELECT 1 AS X FROM RDB\$DATABASE")
    lbl=$(printf '%s' "$z" | sed 's/^CREATE TABLE \([A-Z0-9]*\).*/\1/')
    check "an unfittable foreign key is refused ($lbl)" "$r" "ERR;OK"
done

# --- rows, and fire-crab's own unique enforcement ---
check "insert into the named UNIQUE"     "$(node_run "INSERT INTO KU VALUES (1, 10)")" "OK"
check "insert a second unique value"     "$(node_run "INSERT INTO KU VALUES (2, 20)")" "OK"
dup=$(node_run "INSERT INTO KU VALUES (1, 30)")
case "$dup" in
    ERR*) echo "OK   fire-crab REFUSES a duplicate unique key" ;;
    *) echo "DIFF duplicate unique key accepted"; echo "     $dup"; fail=1 ;;
esac
check "insert compound PK parent"        "$(node_run "INSERT INTO KP VALUES (1, 100, 'x')")" "OK"
dup2=$(node_run "INSERT INTO KP VALUES (1, 100, 'y')")
case "$dup2" in
    ERR*) echo "OK   fire-crab REFUSES a duplicate PRIMARY KEY" ;;
    *) echo "DIFF duplicate primary key accepted"; echo "     $dup2"; fail=1 ;;
esac
# --- the new foreign keys must still ENFORCE, in BOTH forms. A naming
# --- fix that quietly stopped checking orphan rows would be far worse
# --- than the naming bug it cured.
check "insert the FK parent row"         "$(node_run "INSERT INTO KQ VALUES (7, 'p')")" "OK"
check "valid child, inline REFERENCES"   "$(node_run "INSERT INTO KR1 VALUES (1, 7)")" "OK"
orph_i=$(node_run "INSERT INTO KR1 VALUES (2, 999)")
case "$orph_i" in
    ERR*) echo "OK   fire-crab REFUSES an orphan on an inline REFERENCES" ;;
    *) echo "DIFF orphan accepted on an inline REFERENCES"; echo "     $orph_i"; fail=1 ;;
esac
check "valid child, table-level FK"      "$(node_run "INSERT INTO KG1 VALUES (7, 1)")" "OK"
orph_t=$(node_run "INSERT INTO KG1 VALUES (999, 2)")
case "$orph_t" in
    ERR*) echo "OK   fire-crab REFUSES an orphan on a table-level FK" ;;
    *) echo "DIFF orphan accepted on a table-level FK"; echo "     $orph_t"; fail=1 ;;
esac

# --- a DROP CONSTRAINT must take the referential-action trigger with
# --- it. The trigger sits on the PARENT, is reached only through
# --- RDB$CHECK_CONSTRAINTS, and left behind it keeps cascading with no
# --- constraint to justify it.
check "fire-crab drops the named cascade FK" "$(node_run "ALTER TABLE KEE DROP CONSTRAINT FK_KEE")" "OK"

# ===================================================================
# THE IDENTIFIER LENGTH: 63 CHARACTERS, ON EVERY NAMING PATH
# ===================================================================
# The engine's name columns are CHAR(63) CHARACTER SET UTF8 and its
# LEXER refuses a longer identifier: `-104` / "Name longer than database
# column size" at the token's own (line, column). fire-crab had NO
# length check anywhere, so it WROTE the object with the name silently
# CUT to 63 - two names differing only past character 63 collided into
# one catalog row, `gfix -v -full` still returned 0, and `gbak` RESTORE
# failed with a duplicate key on RDB$RELATION_CONSTRAINTS. A gate that
# checks only the BACKUP passes on that database, which is why the
# RESTORE is asserted (below the server stop, with the other gbak work).
#
# 63 is measured, not assumed: 30 naming paths x two lengths against the
# live engine, 63 accepted by both servers and 64 refused by both. The
# limit counts CHARACTERS, not bytes - 63 A-umlauts is 126 bytes and
# legal, 64 of them is not.
pad() { # <prefix> <total characters>  -> a name of EXACTLY <total>
    printf '%s' "$1"
    n=$(( $2 - ${#1} ))
    i=0; while [ $i -lt $n ]; do printf 'K'; i=$((i + 1)); done
}
upad() { # <prefix> <total characters>, padded with A-umlaut
    python3 -c "import sys; print(sys.argv[1] + 'Ä' * (int(sys.argv[2]) - len(sys.argv[1])), end='')" "$1" "$2" 2>/dev/null
}
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$NAM' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
[ -f "$NAM" ] || { echo "FAIL name-length scratch db"; exit 1; }
chmod 666 "$NAM" 2>/dev/null
node_db() { # <db> <sql>
    FC_DB="$1" FC_PORT="$PORT" FC_Q="$2" timeout 20 node -e '
      process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        db.query(process.env.FC_Q,(e2,r)=>{
          console.log(e2?("ERR "+(e2.message||"").split("\n")[0]):"OK");
          db.detach();process.exit(0);});
      });' 2>/dev/null | strip
}
name_ok()  { check "at the limit (63 chars), still accepted: $1" "$(node_db "$NAM" "$2")" "OK"; }
name_bad() { # <label> <sql>
    r=$(node_db "$NAM" "$2")
    case "$r" in
        "ERR "*"Name longer than database column size"*)
            echo "OK   one past the limit (64), refused with the engine's -104: $1" ;;
        *) echo "DIFF 64 characters NOT refused as the engine refuses them: $1"
           echo "     got:  $r"; fail=1 ;;
    esac
}
for s0 in "CREATE TABLE NPAR (ID INTEGER NOT NULL PRIMARY KEY)" \
          "CREATE TABLE NTIX (A INTEGER)" \
          "CREATE TABLE NALT (A INTEGER)" \
          "CREATE TABLE NALU (A INTEGER)"; do
    check "name-length fixture: $s0" "$(node_db "$NAM" "$s0")" "OK"
done
name_ok "table"                "CREATE TABLE $(pad NT1 63) (A INTEGER)"
name_ok "column"               "CREATE TABLE NC1 ($(pad NCA 63) INTEGER)"
name_ok "domain"               "CREATE DOMAIN $(pad ND1 63) AS INTEGER"
name_ok "index"                "CREATE INDEX $(pad NX1 63) ON NTIX (A)"
name_ok "table-level PRIMARY KEY" "CREATE TABLE NP1 (A INTEGER NOT NULL, CONSTRAINT $(pad NK1 63) PRIMARY KEY (A))"
name_ok "table-level UNIQUE"   "CREATE TABLE NU1 (A INTEGER NOT NULL, CONSTRAINT $(pad NK2 63) UNIQUE (A))"
name_ok "table-level FOREIGN KEY" "CREATE TABLE NF1 (A INTEGER, CONSTRAINT $(pad NK3 63) FOREIGN KEY (A) REFERENCES NPAR)"
name_ok "table-level CHECK"    "CREATE TABLE NK1T (A INTEGER, CONSTRAINT $(pad NK4 63) CHECK (A > 0))"
name_ok "inline CHECK"         "CREATE TABLE NI1 (A INTEGER CONSTRAINT $(pad NK5 63) CHECK (A > 0))"
name_ok "inline REFERENCES"    "CREATE TABLE NI2 (A INTEGER CONSTRAINT $(pad NK6 63) REFERENCES NPAR)"
name_ok "inline UNIQUE"        "CREATE TABLE NI3 (A INTEGER NOT NULL CONSTRAINT $(pad NK7 63) UNIQUE)"
name_ok "ALTER TABLE ADD CONSTRAINT" "ALTER TABLE NALT ADD CONSTRAINT $(pad NK8 63) FOREIGN KEY (A) REFERENCES NPAR"
name_ok "ALTER TABLE ADD column" "ALTER TABLE NALU ADD $(pad NCB 63) INTEGER"
name_ok "generator"            "CREATE GENERATOR $(pad NG1 63)"
name_ok "sequence"             "CREATE SEQUENCE $(pad NG2 63)"
name_ok "view"                 "CREATE VIEW $(pad NV1 63) AS SELECT A FROM NTIX"
name_ok "exception"            "CREATE EXCEPTION $(pad NE1 63) 'x'"
name_ok "quoted table"         "CREATE TABLE \"$(pad NQT 63)\" (A INTEGER)"
name_ok "quoted column"        "CREATE TABLE NQ1 (\"$(pad NQC 63)\" INTEGER)"
name_ok "quoted index"         "CREATE INDEX \"$(pad NQX 63)\" ON NTIX (A)"
name_ok "quoted domain"        "CREATE DOMAIN \"$(pad NQD 63)\" AS INTEGER"
name_ok "quoted table-level constraint" "CREATE TABLE NQ2 (A INTEGER, CONSTRAINT \"$(pad NQK 63)\" CHECK (A > 0))"
name_ok "quoted inline constraint" "CREATE TABLE NQ3 (A INTEGER CONSTRAINT \"$(pad NQI 63)\" CHECK (A > 0))"
# CHARACTERS, NOT BYTES: these are 126 bytes each
if [ -n "$(upad U 63)" ]; then
    name_ok "NON-ASCII quoted table (63 chars = 126 bytes)" "CREATE TABLE \"$(upad NUT 63)\" (A INTEGER)"
    name_ok "NON-ASCII quoted column"                       "CREATE TABLE NU2 (\"$(upad NUC 63)\" INTEGER)"
    name_ok "NON-ASCII quoted inline constraint"            "CREATE TABLE NU3 (A INTEGER CONSTRAINT \"$(upad NUI 63)\" CHECK (A > 0))"
    name_ok "NON-ASCII quoted table-level constraint"       "CREATE TABLE NU4 (A INTEGER, CONSTRAINT \"$(upad NUK 63)\" CHECK (A > 0))"
fi
name_bad "table"                "CREATE TABLE $(pad MT1 64) (A INTEGER)"
name_bad "column"               "CREATE TABLE MC1 ($(pad MCA 64) INTEGER)"
name_bad "domain"               "CREATE DOMAIN $(pad MD1 64) AS INTEGER"
name_bad "index"                "CREATE INDEX $(pad MX1 64) ON NTIX (A)"
name_bad "table-level PRIMARY KEY" "CREATE TABLE MP1 (A INTEGER NOT NULL, CONSTRAINT $(pad MK1 64) PRIMARY KEY (A))"
name_bad "table-level UNIQUE"   "CREATE TABLE MU1 (A INTEGER NOT NULL, CONSTRAINT $(pad MK2 64) UNIQUE (A))"
name_bad "table-level FOREIGN KEY" "CREATE TABLE MF1 (A INTEGER, CONSTRAINT $(pad MK3 64) FOREIGN KEY (A) REFERENCES NPAR)"
name_bad "table-level CHECK"    "CREATE TABLE MK1T (A INTEGER, CONSTRAINT $(pad MK4 64) CHECK (A > 0))"
name_bad "inline CHECK"         "CREATE TABLE MI1 (A INTEGER CONSTRAINT $(pad MK5 64) CHECK (A > 0))"
name_bad "inline REFERENCES"    "CREATE TABLE MI2 (A INTEGER CONSTRAINT $(pad MK6 64) REFERENCES NPAR)"
name_bad "inline UNIQUE"        "CREATE TABLE MI3 (A INTEGER NOT NULL CONSTRAINT $(pad MK7 64) UNIQUE)"
name_bad "ALTER TABLE ADD CONSTRAINT" "ALTER TABLE NALT ADD CONSTRAINT $(pad MK8 64) FOREIGN KEY (A) REFERENCES NPAR"
name_bad "ALTER TABLE ADD column" "ALTER TABLE NALU ADD $(pad MCB 64) INTEGER"
name_bad "generator"            "CREATE GENERATOR $(pad MG1 64)"
name_bad "sequence"             "CREATE SEQUENCE $(pad MG2 64)"
name_bad "view"                 "CREATE VIEW $(pad MV1 64) AS SELECT A FROM NTIX"
name_bad "exception"            "CREATE EXCEPTION $(pad ME1 64) 'x'"
name_bad "quoted table"         "CREATE TABLE \"$(pad MQT 64)\" (A INTEGER)"
name_bad "quoted column"        "CREATE TABLE MQ1 (\"$(pad MQC 64)\" INTEGER)"
name_bad "quoted index"         "CREATE INDEX \"$(pad MQX 64)\" ON NTIX (A)"
name_bad "quoted domain"        "CREATE DOMAIN \"$(pad MQD 64)\" AS INTEGER"
name_bad "quoted table-level constraint" "CREATE TABLE MQ2 (A INTEGER, CONSTRAINT \"$(pad MQK 64)\" CHECK (A > 0))"
name_bad "quoted inline constraint" "CREATE TABLE MQ3 (A INTEGER CONSTRAINT \"$(pad MQI 64)\" CHECK (A > 0))"
name_bad "a SELECT of a too-long column" "SELECT $(pad MSC 64) FROM NTIX"
name_bad "a SELECT alias"       "SELECT A AS $(pad MSA 64) FROM NTIX"
if [ -n "$(upad U 64)" ]; then
    name_bad "NON-ASCII quoted table (64 chars = 128 bytes)" "CREATE TABLE \"$(upad MUT 64)\" (A INTEGER)"
    name_bad "NON-ASCII quoted inline constraint"            "CREATE TABLE MU3 (A INTEGER CONSTRAINT \"$(upad MUI 64)\" CHECK (A > 0))"
fi
# THE COLLISION, which is what the missing check COST: two names that
# differ only PAST character 63. Written truncated they became one row.
name_bad "COLLIDING constraint names (differ only past char 63)" \
    "CREATE TABLE MCT (A INTEGER CONSTRAINT $(pad C 63)A1 CHECK (A > 0), B INTEGER CONSTRAINT $(pad C 63)A2 CHECK (B > 0))"
name_bad "COLLIDING column names (differ only past char 63)" \
    "CREATE TABLE MCT2 ($(pad C 63)A1 INTEGER, $(pad C 63)A2 INTEGER)"
name_bad "COLLIDING table names (differ only past char 63)" \
    "CREATE TABLE $(pad C 63)A1 (A INTEGER)"
# and the names AT the limit that differ in their LAST character are two
# distinct objects, not one - the check must not round down
name_ok "two 63-character names differing in the last character (1)" \
    "CREATE TABLE $(pad NDA 62)1 (A INTEGER)"
name_ok "two 63-character names differing in the last character (2)" \
    "CREATE TABLE $(pad NDA 62)2 (A INTEGER)"

# --- A DELIMITED NAME'S TRAILING BLANKS ARE NOT PART OF IT ---------------
# The engine strips trailing blanks BEFORE applying the 63-character
# limit, so `"<63 chars> "` - 64 characters between the quotes - is a
# legal 63-character name there, and BOTH servers store it trimmed
# (`CREATE TABLE "AB  "` is reachable afterwards as `AB` on either).
# Counting the blank refused a name this server's own writer would have
# written correctly. Every naming path here uses a blank-free name,
# which is why all of the checks above passed with that open.
name_ok "delimited table, 63 significant + a TRAILING BLANK" \
    "CREATE TABLE \"$(pad NSB 63) \" (A INTEGER)"
name_ok "delimited table, 63 significant + 37 TRAILING BLANKS" \
    "CREATE TABLE \"$(pad NSC 63)                                     \" (A INTEGER)"
name_ok "delimited column, 63 significant + a TRAILING BLANK" \
    "CREATE TABLE NSB2 (\"$(pad NSD 63) \" INTEGER)"
# ... and the blank does not buy a 64th character: an INTERNAL blank
# counts, and so does a trailing TAB (measured on the engine both ways)
name_bad "delimited table, 64 significant + a trailing blank" \
    "CREATE TABLE \"$(pad NSE 64) \" (A INTEGER)"
name_bad "delimited table, an INTERNAL blank inside 64 characters" \
    "CREATE TABLE \"$(pad NSF 31) $(pad NSG 32)\" (A INTEGER)"
name_bad "delimited table, 63 significant + a trailing TAB (not a blank)" \
    "$(printf 'CREATE TABLE "%s\t" (A INTEGER)' "$(pad NSH 63)")"
# A NAME OF NOTHING BUT BLANKS IS NOT A NAME. Trimming the trailing ones
# must not trim the whole identifier away: fire-crab WROTE a relation
# whose RDB$RELATION_NAME was all blanks and `gfix -v -full` then
# reported database page warnings on the file. The engine refuses it
# (with its own `Zero length identifiers not permitted` text, recorded).
blank_refused() { # <label> <sql>
    r=$(node_db "$NAM" "$2")
    case "$r" in
        "ERR "*) echo "OK   a delimited name of nothing but blanks is refused: $1" ;;
        *) echo "DIFF a blank-only name was WRITTEN, the engine refuses it: $1"
           echo "     got:  $r"; fail=1 ;;
    esac
}
blank_refused "table name of 3 blanks"  'CREATE TABLE "   " (A INTEGER)'
blank_refused "column name of 2 blanks" 'CREATE TABLE NSBK ("  " INTEGER)'
blank_refused "table name of 80 blanks" \
    "$(printf 'CREATE TABLE "%80s" (A INTEGER)' ' ')"

# ===================================================================
# A DEFERRED-DROP INDEX ROW: TWO SIDES, TWO ANSWERS
# ===================================================================
# `ALTER TABLE <child> DROP CONSTRAINT <fk>` leaves the child's index
# row behind as RDB$TEMP_DEPEND_<rel>_<n> - still naming the parent's
# unique index in RDB$FOREIGN_KEY, with its RDB$INDEX_SEGMENTS rows
# deleted. BOTH servers write exactly that (the two catalogs are
# identical after the drop), and the ENGINE GOES ON ENFORCING FROM IT -
# measured on fire-crab's own file as on its own:
#
#   - an orphan INSERT into the CHILD is ACCEPTED (the constraint is
#     gone as far as the child is concerned);
#   - a DELETE of a REFERENCED parent row is REFUSED, `Violation of
#     FOREIGN KEY constraint "***unknown***"`;
#   - a DELETE of an UNREFERENCED parent row is accepted.
#
# fire-crab skipped that row on BOTH sides, so the parent DELETE went
# through and REMOVED A ROW THE ENGINE KEEPS. The check before this one
# asserted only that the CHILD row survived the drop; it never asked
# whether the parent row should have.
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$DFD' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
COMMIT;
EOF
[ -f "$DFD" ] || { echo "FAIL deferred-drop scratch db"; exit 1; }
chmod 666 "$DFD" 2>/dev/null
for s0 in "CREATE TABLE DP (ID INTEGER NOT NULL PRIMARY KEY)" \
          "CREATE TABLE DC (A INTEGER, B INTEGER, CONSTRAINT FKD FOREIGN KEY (B) REFERENCES DP)" \
          "INSERT INTO DP VALUES (1)" "INSERT INTO DP VALUES (2)" "INSERT INTO DP VALUES (3)" \
          "INSERT INTO DC VALUES (40, 1)"; do
    check "deferred-drop fixture: $s0" "$(node_db "$DFD" "$s0")" "OK"
done
check "the FK refuses an orphan child BEFORE the drop" \
    "$(node_db "$DFD" "INSERT INTO DC VALUES (41, 999)" | cut -c1-3)" "ERR"
check "ALTER TABLE DC DROP CONSTRAINT FKD" \
    "$(node_db "$DFD" "ALTER TABLE DC DROP CONSTRAINT FKD")" "OK"
# the CHILD side keeps the round-4 answer: the dropped constraint stops
# enforcing, and this must NOT be given back
check "after the drop the CHILD accepts an orphan" \
    "$(node_db "$DFD" "INSERT INTO DC VALUES (41, 999)")" "OK"
# the PARENT side: an unreferenced key still goes...
check "after the drop the PARENT deletes an UNREFERENCED row" \
    "$(node_db "$DFD" "DELETE FROM DP WHERE ID = 3")" "OK"
# ...and a REFERENCED one does not, with the engine's own name for the
# constraint whose row is gone
dref=$(node_db "$DFD" "DELETE FROM DP WHERE ID = 1")
case "$dref" in
    *'***unknown***'*) echo "OK   after the drop the PARENT REFUSES a referenced row, as the engine does" ;;
    *) echo "DIFF the parent row the engine keeps was not protected"; echo "     got:  $dref"; fail=1 ;;
esac
duref=$(node_db "$DFD" "UPDATE DP SET ID = 9 WHERE ID = 1")
case "$duref" in
    *'***unknown***'*) echo "OK   ...and refuses the parent key UPDATE too" ;;
    *) echo "DIFF the parent key UPDATE was not protected"; echo "     got:  $duref"; fail=1 ;;
esac
check "a NON-key UPDATE on the parent still works" \
    "$(node_db "$DFD" "UPDATE DP SET ID = ID WHERE ID = 2")" "OK"

# --- THE DECOY COLUMNS: the test must be on the DROPPED KEY'S OWN
# --- COLUMNS, not on "any column of any child row".
# The catalog no longer records which child columns keyed on the parent,
# so the check briefly widened to "does some child row hold this value
# ANYWHERE" - and an order table's STATUS and QTY columns made two of
# three parent rows undeletable. The key columns survive in the one
# place the drop does not touch: the index-root SEGMENT DESCRIPTORS of
# the dropped index, whose tree is exactly what the engine goes on
# enforcing from. ORD below holds ONE row, (100, 2, 3, 1), referencing
# ID = 1 alone; ID = 2 collides with STATUS, ID = 3 with QTY, and the
# ENGINE deletes both.
for s0 in "CREATE TABLE DPD (ID INTEGER NOT NULL PRIMARY KEY, T VARCHAR(10))" \
          "CREATE TABLE DORD (OID INTEGER, STATUS INTEGER, QTY INTEGER, PID INTEGER, CONSTRAINT FKO FOREIGN KEY (PID) REFERENCES DPD)" \
          "INSERT INTO DPD VALUES (1, 'a')" "INSERT INTO DPD VALUES (2, 'b')" \
          "INSERT INTO DPD VALUES (3, 'c')" "INSERT INTO DORD VALUES (100, 2, 3, 1)" \
          "ALTER TABLE DORD DROP CONSTRAINT FKO"; do
    check "decoy-column fixture: $s0" "$(node_db "$DFD" "$s0")" "OK"
done
check "a DECOY value in STATUS does not protect an unreferenced parent row" \
    "$(node_db "$DFD" "DELETE FROM DPD WHERE ID = 2")" "OK"
check "a DECOY value in QTY does not protect an unreferenced parent row" \
    "$(node_db "$DFD" "DELETE FROM DPD WHERE ID = 3")" "OK"
ddref=$(node_db "$DFD" "DELETE FROM DPD WHERE ID = 1")
case "$ddref" in
    *'***unknown***'*) echo "OK   ...and the REFERENCED key is still refused, on the FK column" ;;
    *) echo "DIFF the genuinely referenced parent row was not protected"
       echo "     got:  $ddref"; fail=1 ;;
esac
check "the child still accepts an orphan after the drop (decoy shape)" \
    "$(node_db "$DFD" "INSERT INTO DORD VALUES (101, 7, 7, 42)")" "OK"

kill $srv 2>/dev/null; wait $srv 2>/dev/null

# the ENGINE does the same to its own file, so the two are comparable
"$ISQL" -q -b -user "$U" -pas "$P" "$REF" >/dev/null 2>&1 <<'SQL'
ALTER TABLE KEE DROP CONSTRAINT FK_KEE;
COMMIT;
SQL

# --- the DIFFERENTIAL for the refusals: the ENGINE, on its OWN file over
# --- the same transport, must refuse every one of them too, and with the
# --- reason fire-crab now gives. A refusal that only fire-crab makes
# --- would be a lost write, not a fix.
eng_refuse() { # <label> <sql> <expected substring in the engine's reason>
    r=$("$ISQL" -q -user "$U" -pas "$P" "$REF" 2>&1 <<SQL
$2;
SQL
)
    case "$r" in
        *"$3"*) echo "OK   the engine refuses it too: $1" ;;
        *) echo "DIFF the engine did NOT refuse: $1"; echo "     $r"; fail=1 ;;
    esac
}
eng_refuse "ZC1 overlapping CHECK spans"  "$DDL_ZC1" "Token unknown"
eng_refuse "ZC2 named overlapping CHECKs" "$DDL_ZC2" "Token unknown"
eng_refuse "ZC5 CHECK span meets REFERENCES" "$DDL_ZC5" "Token unknown"
eng_refuse "ZC3 REFERENCES span meets CHECK" "$DDL_ZC3" "Token unknown"
eng_refuse "ZB1 inline FK, wrong column count" "$DDL_ZB1" "column count does not match"
eng_refuse "ZB2 table-level FK, wrong column count" "$DDL_ZB2" "column count does not match"
eng_refuse "ZB3 two columns onto a one-column key" "$DDL_ZB3" "column count does not match"
eng_refuse "ZT1 BIGINT child onto an INTEGER key" "$DDL_ZT1" "incompatible data type"
eng_refuse "ZT2 table-level, BIGINT onto INTEGER" "$DDL_ZT2" "incompatible data type"
eng_refuse "ZT3 VARCHAR child onto an INTEGER key" "$DDL_ZT3" "incompatible data type"

# --- the long-name database BACKS UP AND RESTORES. The RESTORE is the
# --- assertion: the collided file backed up rc=0 and only died on the
# --- way back in, so a backup-only check called it healthy.
if "$GBAK" -b -g -user "$U" -pas "$P" "$NAM" "$NBK" >/tmp/fc-key-nbackup.log 2>&1; then
    echo "OK   gbak backs up the long-name database"
else
    echo "DIFF gbak backup (long names)"; cat /tmp/fc-key-nbackup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$NBK" "$NRS" >/tmp/fc-key-nrestore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error" /tmp/fc-key-nrestore.log; then
    echo "OK   gbak RESTORES the long-name database (nothing collided)"
else
    echo "DIFF gbak restore of the long-name database (exit $rc)"
    grep -iE "error|violation|duplicate" /tmp/fc-key-nrestore.log | head; fail=1
fi
nval=$("$GFIX" -v -full -user "$U" -pas "$P" "$NAM" 2>&1)
check "gfix -v -full clean (long-name database)" "$(printf '%s' "$nval" | strip)" ""
# the two 63-character names that differ in their last character are two
# DISTINCT relations in the catalog the engine reads back
ndist=$("$ISQL" -q -b -user "$U" -pas "$P" "$NAM" 2>&1 <<'SQL' | strip
SET HEADING OFF;
SELECT COUNT(*) FROM RDB$RELATIONS WHERE RDB$RELATION_NAME STARTING WITH 'NDA';
SQL
)
ndist=$(printf '%s' "$ndist" | awk 'NF{print $1; exit}')
check "two 63-character names are two relations, not one" "$ndist" "2"

# --- the deferred-drop database: the ENGINE, reading fire-crab's own
# --- file, makes the same two calls, and the parent row is still there
nleft=$("$ISQL" -q -b -user "$U" -pas "$P" "$DFD" 2>&1 <<'SQL' | strip
SET HEADING OFF;
SELECT COUNT(*) FROM DP;
SQL
)
nleft=$(printf '%s' "$nleft" | awk 'NF{print $1; exit}')
check "the parent rows SURVIVE fire-crab's DELETE (ID 1 and 2 left)" "$nleft" "2"
eref=$("$ISQL" -q -b -user "$U" -pas "$P" "$DFD" 2>&1 <<'SQL'
DELETE FROM DP WHERE ID = 1;
SQL
)
case "$eref" in
    *'***unknown***'*) echo "OK   the ENGINE refuses the same parent DELETE on fire-crab's file" ;;
    *) echo "DIFF the engine's answer on fc's deferred-drop file"; echo "     $eref"; fail=1 ;;
esac
echild=$("$ISQL" -q -b -user "$U" -pas "$P" "$DFD" 2>&1 <<'SQL'
INSERT INTO DC VALUES (42, 777);
SQL
)
check "the ENGINE accepts the orphan child on fire-crab's file" "$(printf '%s' "$echild" | strip)" ""
# the decoy shape, read back BY THE ENGINE on fire-crab's own file: the
# two rows fire-crab deleted are gone (the engine deletes them too), the
# referenced one stands, and the engine refuses IT for the same reason
ndec=$("$ISQL" -q -b -user "$U" -pas "$P" "$DFD" 2>&1 <<'SQL' | strip
SET HEADING OFF;
SELECT COUNT(*) FROM DPD;
SQL
)
ndec=$(printf '%s' "$ndec" | awk 'NF{print $1; exit}')
check "the decoy rows are GONE on the engine's reading (only ID=1 left)" "$ndec" "1"
edec=$("$ISQL" -q -b -user "$U" -pas "$P" "$DFD" 2>&1 <<'SQL'
DELETE FROM DPD WHERE ID = 1;
SQL
)
case "$edec" in
    *'***unknown***'*) echo "OK   the ENGINE refuses the referenced decoy-shape key too" ;;
    *) echo "DIFF the engine's answer on the decoy shape"; echo "     $edec"; fail=1 ;;
esac
dval=$("$GFIX" -v -full -user "$U" -pas "$P" "$DFD" 2>&1)
check "gfix -v -full clean (deferred-drop database)" "$(printf '%s' "$dval" | strip)" ""

# --- 1. the constraint catalog the engine reads from fc == the reference ---
TBLS="'KP','KQ','KU','KM','KC','KF','KM2','KM5','KN1','KN2','KN3','KN4','KM1','KN5'"
catq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^\$'
SET HEADING OFF;
SELECT 'RC|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONSTRAINT_TYPE)
       ||'|'||COALESCE(TRIM(RDB\$INDEX_NAME),'-')
  FROM RDB\$RELATION_CONSTRAINTS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$CONSTRAINT_NAME;
SELECT 'IDX|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$INDEX_NAME)||'|'||COALESCE(RDB\$UNIQUE_FLAG,-1)
       ||'|'||RDB\$SEGMENT_COUNT||'|'||COALESCE(TRIM(RDB\$FOREIGN_KEY),'-')||'|'||COALESCE(RDB\$INDEX_INACTIVE,-1)
  FROM RDB\$INDICES WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$INDEX_ID;
SELECT 'SEG|'||TRIM(S.RDB\$INDEX_NAME)||'|'||TRIM(S.RDB\$FIELD_NAME)||'|'||S.RDB\$FIELD_POSITION
  FROM RDB\$INDEX_SEGMENTS S JOIN RDB\$INDICES I ON I.RDB\$INDEX_NAME = S.RDB\$INDEX_NAME
  WHERE I.RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY S.RDB\$INDEX_NAME, S.RDB\$FIELD_POSITION;
SELECT 'NF|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$FIELD_NAME)||'|'||COALESCE(RDB\$NULL_FLAG,0)
  FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME IN ($TBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$FIELD_POSITION;
SELECT 'CC|'||TRIM(C.RDB\$CONSTRAINT_NAME)||'|'||TRIM(C.RDB\$TRIGGER_NAME)
  FROM RDB\$CHECK_CONSTRAINTS C JOIN RDB\$RELATION_CONSTRAINTS R
       ON R.RDB\$CONSTRAINT_NAME = C.RDB\$CONSTRAINT_NAME
  WHERE R.RDB\$RELATION_NAME IN ($TBLS) ORDER BY C.RDB\$CONSTRAINT_NAME;
-- EVERY link row and EVERY system trigger, with NO relation filter. A
-- foreign key's referential-action trigger sits on the REFERENCED
-- (PARENT) relation, so the filtered CC query above cannot see it - and
-- it was exactly that trigger whose missing RDB$CHECK_CONSTRAINTS link
-- let a DROP CONSTRAINT leave it behind, still cascading, to delete a
-- child row the engine's own database keeps. Both databases hold the
-- same schema, so an unfiltered comparison is exact.
SELECT 'CCALL|'||TRIM(C.RDB\$CONSTRAINT_NAME)||'|'||TRIM(C.RDB\$TRIGGER_NAME)
  FROM RDB\$CHECK_CONSTRAINTS C
  ORDER BY C.RDB\$CONSTRAINT_NAME, C.RDB\$TRIGGER_NAME;
SELECT 'SYSTRG|'||TRIM(T.RDB\$TRIGGER_NAME)||'|'||TRIM(T.RDB\$RELATION_NAME)
       ||'|'||T.RDB\$TRIGGER_TYPE
  FROM RDB\$TRIGGERS T WHERE T.RDB\$SYSTEM_FLAG = 4
  ORDER BY T.RDB\$TRIGGER_NAME;
SELECT 'REF|'||TRIM(RDB\$CONSTRAINT_NAME)||'|'||TRIM(RDB\$CONST_NAME_UQ)||'|'||TRIM(RDB\$MATCH_OPTION)
  FROM RDB\$REF_CONSTRAINTS ORDER BY RDB\$CONSTRAINT_NAME;
SQL
}
check "key catalog matches engine reference" "$(catq "$WORK")" "$(catq "$REF")"

# --- 1b. the FOREIGN KEY shapes: the CONSTRAINT NAMES, in the order the
# two-pass law draws them, on the tables that carry an UNNAMED foreign
# key. Their INDEX names are deliberately left out of this comparison:
# fire-crab names an unnamed FK's backing index after its constraint
# (INTEG_<n>) where the engine names it RDB$FOREIGN<n>, so fire-crab
# draws no index number for it and the shared RDB$INDEX_NAME counter
# runs one behind. That is a DIFFERENT counter, recorded in
# docs/roadmap.md, and out of scope here - what must match is the
# CONSTRAINT name each row carries, which is what this checks.
FKTBLS="'KF1','KF2','KG1','KG2','KG3','KR1','KR2','KR3','KNA','KNB','KEC','KED','KX3','KCS'"
fkq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^\$'
SET HEADING OFF;
SELECT 'FKRC|'||TRIM(RC.RDB\$RELATION_NAME)||'|'||TRIM(RC.RDB\$CONSTRAINT_NAME)
       ||'|'||TRIM(RC.RDB\$CONSTRAINT_TYPE)
       ||'|'||COALESCE((SELECT MIN(TRIM(S.RDB\$FIELD_NAME)) FROM RDB\$INDEX_SEGMENTS S
                        WHERE S.RDB\$INDEX_NAME = RC.RDB\$INDEX_NAME), '-')
  FROM RDB\$RELATION_CONSTRAINTS RC WHERE RC.RDB\$RELATION_NAME IN ($FKTBLS)
  ORDER BY RC.RDB\$RELATION_NAME, RC.RDB\$CONSTRAINT_NAME;
SELECT 'FKREF|'||TRIM(R.RDB\$CONSTRAINT_NAME)||'|'||TRIM(R.RDB\$CONST_NAME_UQ)
       ||'|'||TRIM(R.RDB\$UPDATE_RULE)||'|'||TRIM(R.RDB\$DELETE_RULE)
  FROM RDB\$REF_CONSTRAINTS R JOIN RDB\$RELATION_CONSTRAINTS C
       ON C.RDB\$CONSTRAINT_NAME = R.RDB\$CONSTRAINT_NAME
 WHERE C.RDB\$RELATION_NAME IN ($FKTBLS) ORDER BY R.RDB\$CONSTRAINT_NAME;
SELECT 'FKNF|'||TRIM(RDB\$RELATION_NAME)||'|'||TRIM(RDB\$FIELD_NAME)||'|'||COALESCE(RDB\$NULL_FLAG,0)
  FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME IN ($FKTBLS)
  ORDER BY RDB\$RELATION_NAME, RDB\$FIELD_POSITION;
SQL
}
check "FK constraint names match engine reference" "$(fkq "$WORK")" "$(fkq "$REF")"

# --- 1c. THE CASCADE AFTER THE DROP. The constraint is gone from both
# catalogs; what must also be gone is the AFTER DELETE trigger it owned.
# On a file where the link row was never written, the trigger survived
# the drop and STILL CASCADED, so `DELETE FROM KEP` silently removed the
# child row the engine's own database keeps (measured: CHILD_ROWS_LEFT 0
# against 1, `gfix -v -full` rc=0 on both, nothing warning anyone).
cascq() { # <file>
    "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 <<SQL | strip | grep -v '^\$'
SET HEADING OFF;
INSERT INTO KEP VALUES (1);
INSERT INTO KEE VALUES (1);
COMMIT;
DELETE FROM KEP;
COMMIT;
SELECT 'CHILD_ROWS_LEFT|' || COUNT(*) FROM KEE;
SELECT 'ORPHAN_TRG|'||TRIM(T.RDB\$TRIGGER_NAME) FROM RDB\$TRIGGERS T
  WHERE T.RDB\$SYSTEM_FLAG = 4
    AND T.RDB\$TRIGGER_NAME NOT IN (SELECT TRIM(C.RDB\$TRIGGER_NAME)
                                    FROM RDB\$CHECK_CONSTRAINTS C)
  ORDER BY T.RDB\$TRIGGER_NAME;
SQL
}
casc_fc=$(cascq "$WORK")
check "a dropped FK stops cascading (engine on fc's file)" "$casc_fc" "$(cascq "$REF")"
case "$casc_fc" in
    *"CHILD_ROWS_LEFT|1"*) echo "OK   the child row the engine keeps is still there" ;;
    *) echo "DIFF the dropped cascade still deleted the child row"; echo "     $casc_fc"; fail=1 ;;
esac
case "$casc_fc" in
    *ORPHAN_TRG*) echo "DIFF an unreferenced system trigger survived the drop"; echo "     $casc_fc"; fail=1 ;;
    *) echo "OK   no unreferenced system trigger survived the drop" ;;
esac

# --- 2. the engine enforces the constraints on fc's RAW file ---
raw_dup=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KU VALUES (2, 99);
SQL
)
case "$raw_dup" in
    *"UNIQ"*|*"uniq"*|*"duplicate"*) echo "OK   engine REJECTS a duplicate unique key on fc's raw file" ;;
    *) echo "DIFF raw-file unique enforcement"; echo "     $raw_dup"; fail=1 ;;
esac
raw_null=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KP VALUES (NULL, 7, 'z');
SQL
)
case "$raw_null" in
    *"not allow"*|*"NULL"*|*"null"*) echo "OK   engine REJECTS NULL in a table-level PK column" ;;
    *) echo "DIFF raw-file PK NOT NULL enforcement"; echo "     $raw_null"; fail=1 ;;
esac
raw_ok=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KU VALUES (3, 33);
SQL
)
check "engine ACCEPTS a fresh unique value on fc's raw file" "$(printf '%s' "$raw_ok" | strip)" ""
raw_orph=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KR1 VALUES (3, 888);
SQL
)
case "$raw_orph" in
    *"FOREIGN KEY"*|*"foreign key"*) echo "OK   engine REJECTS an orphan of an inline REFERENCES on fc's raw file" ;;
    *) echo "DIFF raw-file inline-FK enforcement"; echo "     $raw_orph"; fail=1 ;;
esac
raw_child=$("$ISQL" -q -b -user "$U" -pas "$P" "$WORK" 2>&1 <<'SQL'
INSERT INTO KR1 VALUES (4, 7);
SQL
)
check "engine ACCEPTS a valid inline-FK child on fc's raw file" "$(printf '%s' "$raw_child" | strip)" ""

# --- 3. gbak backup + RESTORE, then the same constraints on the copy ---
if "$GBAK" -b -g -user "$U" -pas "$P" "$WORK" "$FBK" >/tmp/fc-key-backup.log 2>&1; then
    echo "OK   gbak backs up fc's constraint database"
else
    echo "DIFF gbak backup"; cat /tmp/fc-key-backup.log; fail=1
fi
"$GBAK" -c -user "$U" -pas "$P" "$FBK" "$RST" >/tmp/fc-key-restore.log 2>&1
rc=$?
if [ $rc -eq 0 ] && ! grep -qiE "error|partner" /tmp/fc-key-restore.log; then
    echo "OK   gbak RESTORES fc's constraint database"
else
    echo "DIFF gbak restore (exit $rc)"; grep -iE "partner|error|cannot" /tmp/fc-key-restore.log | head; fail=1
fi
rst_dup=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO KU VALUES (3, 44);
SQL
)
case "$rst_dup" in
    *"UNIQ"*|*"uniq"*|*"duplicate"*) echo "OK   restored db REJECTS a duplicate unique key" ;;
    *) echo "DIFF restored unique enforcement"; echo "     $rst_dup"; fail=1 ;;
esac
rst_orphan=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO KF VALUES (1, 5, 555);
SQL
)
case "$rst_orphan" in
    *"FOREIGN KEY"*|*"foreign key"*) echo "OK   restored db REJECTS an orphan of the named PK" ;;
    *) echo "DIFF restored FK enforcement"; echo "     $rst_orphan"; fail=1 ;;
esac
rst_child=$("$ISQL" -q -b -user "$U" -pas "$P" "$RST" 2>&1 <<'SQL'
INSERT INTO KF VALUES (2, 1, 100);
SQL
)
check "restored db ACCEPTS a valid child" "$(printf '%s' "$rst_child" | strip)" ""
val=$("$GFIX" -v -full -user "$U" -pas "$P" "$RST" 2>&1)
check "gfix -v -full clean (restored)" "$(printf '%s' "$val" | strip)" ""

exit $fail
