#!/bin/bash
# DOMAIN CHECK constraints - `CREATE DOMAIN ... CHECK (VALUE ...)`,
# `ALTER DOMAIN ADD [CONSTRAINT] CHECK / DROP CONSTRAINT`, and the
# VALIDATION at every INSERT and UPDATE. fire-crab used to write rows
# the engine refuses (the domain's RDB$VALIDATION_* had NO consumer -
# the silent-wrong class this project treats as the worst outcome).
#
# The measured engine laws this gate pins:
#   - violation: SQLSTATE 23000, `validation error for column
#     "SCHEMA"."TABLE"."COL", value "<v>"` (isc_not_valid), NULL
#     rendering as `*** null ***`, scaled numerics with their scale,
#     DATE as ISO, TIMESTAMP as the LEGACY `07-JUN-2019 8:09:10.5000`
#   - FALSE fails, UNKNOWN passes: a NULL value stores through
#     `VALUE > 10` but not through `VALUE IS NOT NULL`
#   - EVERY column of the row validates, at INSERT (unassigned columns
#     as NULL/DEFAULT) and at UPDATE (the merged row - an untouched
#     column re-validates); first violating field in FIELD ORDER wins;
#     a table CHECK (PRE trigger) beats all validations
#   - a DEFAULT-filled value is validated like any other
#   - one constraint per domain: a second ADD is "unsuccessful
#     metadata update / ALTER DOMAIN @1 failed / "Only one constraint
#     allowed for a domain""; DROP CONSTRAINT with none is a no-op
#   - ALTER does NOT re-scan existing rows
#   - the stored form: RDB$VALIDATION_SOURCE verbatim + the bare
#     positive boolean BLR (`blr_fid 0,0,0` for VALUE; a written NOT
#     normalizes into inverted comparisons) - the engine ENFORCES from
#     the RSR_validation_blr runtime segment, which fc emits at CREATE
#     TABLE and rebuilds on ALTER, so the ENGINE enforces fc-written
#     checks (proved in the engine-runs-fc leg)
#
# Boundaries (recorded): fc's CREATE/ALTER DOMAIN check surface is the
# table-CHECK compile surface (plain-int and NONE-charset-text
# comparisons, AND/OR/NOT/IS NULL) - anything else refuses the WHOLE
# statement (never a domain without its rule) where the engine
# creates; ENFORCEMENT of engine-built checks runs the full WHERE
# surface (BETWEEN, IN, LIKE, functions). CAST(x AS domain) and PSQL
# variables over a checked domain refuse (the engine validates with
# its own 42000 vectors). The old "no room on the page" refusal on a
# repeated ALTER cycle is CLOSED: records pack on write and a full
# page fragments the new version (see serve-real-sqzpack.sh).
#
#   qa/serve-real-domaincheck.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4972}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
A="$D/fc-domck-crab.fdb"; B="$D/fc-domck-engine.fdb"
LOG="/tmp/fc-serve-domck-$PORT.log"
mkdir -p "$D"; fail=0; ran=0
# 32K pages predate the SQZ pack-on-write writer (8K survives the
# ALTER cycle now - serve-real-sqzpack.sh pins that); kept as-is so
# this gate's pins stay byte-stable
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 32768;
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B" "$D/fc-domck2-crab.fdb" "$D/fc-domck2-engine.fdb" "$D/fc-domck-lossy.fdb"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
norm() { grep -v '^$' | sed 's/  */ /g; s/ *$//' | tr '\n' '|'; }

# --- the DDL + enforcement story, one script through each server ---
cat > "$D/domck.sql" <<'SQL'
CREATE DOMAIN DPOS AS INTEGER CHECK (VALUE > 10);
CREATE DOMAIN DTX AS VARCHAR(7) CHECK (VALUE <> 'no');
CREATE DOMAIN DNN AS INTEGER CHECK (VALUE IS NOT NULL);
CREATE DOMAIN DNOT AS INTEGER CHECK (NOT (VALUE > 5));
CREATE DOMAIN DDEF AS INTEGER DEFAULT 3 CHECK (VALUE > 10);
CREATE TABLE TT (A DPOS, S DTX);
CREATE TABLE TN (N DNN, M DPOS);
CREATE TABLE TD (W DDEF, X INTEGER);
-- table-LEVEL check syntax: fc's own DDL takes no column-level CHECK
-- beside other columns (pre-existing, refuses whole - fail-safe)
CREATE TABLE TZ (A DPOS, B INTEGER NOT NULL, C INTEGER, CHECK (C > 0));
COMMIT;
-- FALSE fails, UNKNOWN passes; text renders raw
INSERT INTO TT VALUES (50, 'yes');
INSERT INTO TT VALUES (5, 'yes');
INSERT INTO TT VALUES (50, 'no');
INSERT INTO TT VALUES (NULL, NULL);
-- an OMITTED column validates as NULL: IS NOT NULL refuses, > passes
INSERT INTO TN (M) VALUES (50);
INSERT INTO TN (N, M) VALUES (1, 50);
-- the first violating FIELD wins (N before M)
INSERT INTO TN (N, M) VALUES (NULL, 5);
-- a DEFAULT-filled value is validated (DDEF's DEFAULT 3 fails > 10)
INSERT INTO TD (X) VALUES (1);
INSERT INTO TD (W, X) VALUES (50, 1);
-- a table CHECK beats every validation; NOT NULL beside a domain check
INSERT INTO TZ (A, C) VALUES (5, -1);
INSERT INTO TZ (A) VALUES (5);
INSERT INTO TZ (A, B, C) VALUES (50, 1, 1);
COMMIT;
-- UPDATE validates the MERGED row: the assigned column...
UPDATE TT SET A = 7 WHERE S = 'yes';
-- ...and an untouched one is re-read but its old value passes
UPDATE TT SET S = 'ok' WHERE A = 50;
-- INSERT..SELECT takes the same path
INSERT INTO TT SELECT A + 1, 'sel' FROM TT WHERE A = 50;
INSERT INTO TT SELECT A - 45, 'sel2' FROM TT WHERE A = 50;
COMMIT;
SET LIST ON;
SELECT A, S FROM TT ORDER BY A NULLS FIRST, S;
SELECT N, M FROM TN ORDER BY N;
SELECT W, X FROM TD;
-- the NOT-form check enforces inverted
INSERT INTO TZ (A, B) VALUES (50, 1);
CREATE TABLE TI (V DNOT);
COMMIT;
INSERT INTO TI VALUES (3);
INSERT INTO TI VALUES (7);
SELECT V FROM TI;
-- ALTER TABLE ADD <col> <domain>: the added column carries the
-- domain (RDB$FIELD_SOURCE) and its CHECK enforces (review-caught:
-- this used to write a zero-typed carrier the engine chokes on)
CREATE TABLE AD1 (K INTEGER);
COMMIT;
ALTER TABLE AD1 ADD C DPOS;
COMMIT;
INSERT INTO AD1 (K, C) VALUES (1, 50);
INSERT INTO AD1 (K, C) VALUES (2, 5);
SELECT K, C FROM AD1;
SELECT RDB$FIELD_SOURCE SRC FROM RDB$RELATION_FIELDS WHERE RDB$RELATION_NAME = 'AD1' AND RDB$FIELD_NAME = 'C';
-- legal clause orders beside the check
CREATE DOMAIN DOK1 AS INTEGER DEFAULT 50 CHECK (VALUE > 10);
CREATE DOMAIN DOK2 AS INTEGER CHECK (VALUE > 10) NOT NULL;
CREATE TABLE TOK (P DOK1, Q DOK2);
COMMIT;
INSERT INTO TOK (Q) VALUES (50);
SELECT P, Q FROM TOK;
SQL
cof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/domck.sql" 2>&1 | grep -v "^After line" | grep -v "At trigger" | norm; }
check "domain checks: create, insert/update/insert-select validation, NULL & UNKNOWN, field order, defaults, table-check precedence" \
    "$(cof "127.0.0.1/$PORT:$A")" "$(cof "127.0.0.1/$REAL:$B")"

# --- ALTER DOMAIN: the constraint life cycle - on a FRESH minimal twin
# --- pair: every ALTER rewrites the runtime blob of every table using
# --- the domain, and on a catalog already crowded by the main leg's DDL
# --- that runs into the recorded page-pressure refusal (fc frees no
# --- superseded catalog blob; the engine RLE-packs and GCs)
A2="$D/fc-domck2-crab.fdb"; B2="$D/fc-domck2-engine.fdb"
make_db "$A2" || { echo "FAIL scratch A2"; exit 1; }
make_db "$B2" || { echo "FAIL scratch B2"; exit 1; }
cat > "$D/domalt.sql" <<'SQL'
CREATE DOMAIN DPOS AS INTEGER CHECK (VALUE > 10);
CREATE TABLE TT (A DPOS, S VARCHAR(7));
COMMIT;
INSERT INTO TT (A, S) VALUES (50, 'x');
COMMIT;
-- a second constraint refuses with the engine's three-item vector
ALTER DOMAIN DPOS ADD CONSTRAINT CHECK (VALUE > 100);
ALTER DOMAIN DPOS DROP CONSTRAINT;
COMMIT;
-- the check is GONE: 5 stores now, and existing rows were never re-scanned
INSERT INTO TT (A, S) VALUES (5, 'ok');
COMMIT;
-- re-arm with a TIGHTER rule
ALTER DOMAIN DPOS ADD CHECK (VALUE > 100);
COMMIT;
INSERT INTO TT (A, S) VALUES (50, 'ok');
INSERT INTO TT (A, S) VALUES (500, 'ok');
SET LIST ON;
SELECT COUNT(*) N FROM TT;
SELECT F.RDB$VALIDATION_SOURCE SRC FROM RDB$FIELDS F WHERE F.RDB$FIELD_NAME = 'DPOS';
SQL
aof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/domalt.sql" 2>&1 | grep -v "^After line" | sed 's/[0-9a-f]*:[0-9a-f]*$/BLOBID/' | norm; }
check "ALTER DOMAIN ADD/DROP CONSTRAINT: only-one vector, drop frees, re-add re-arms, source verbatim" \
    "$(aof "127.0.0.1/$PORT:$A2")" "$(aof "127.0.0.1/$REAL:$B2")"

# --- the ENGINE enforces the ALTER-time check fc stored ---
ran=$((ran + 1))
ea=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$REAL:$A2" 2>&1 <<'SQL' | norm
INSERT INTO TT (A, S) VALUES (200, 'e2');
INSERT INTO TT (A, S) VALUES (50, 'e2');
SET LIST ON;
SELECT COUNT(*) NE FROM TT WHERE S = 'e2';
SQL
)
case "$ea" in *'validation error for column "PUBLIC"."TT"."A", value "50"'*"NE 1"*)
    echo "OK   the ENGINE enforces fc's ALTER-written check (runtime rebuilt)";;
    *) echo "DIFF engine-runs-fc-alter: [$ea]"; fail=1;; esac
rm -f "$A2" "$B2"

# --- the ENGINE enforces what fc stored (the BLR is real) ---
cat > "$D/domeng.sql" <<'SQL'
SET LIST ON;
DELETE FROM TT WHERE S = 'e1';
COMMIT;
INSERT INTO TT (A, S) VALUES (50, 'e1');
INSERT INTO TT (A, S) VALUES (500, 'e1');
INSERT INTO TT (A, S) VALUES (500, 'no');
SELECT COUNT(*) N2 FROM TT WHERE S = 'e1';
SQL
xof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/domeng.sql" 2>&1 | grep -v "^After line" | norm; }
check "the ENGINE runs fc's stored validation BLR (CREATE-time and ALTER-time) exactly as fc does" \
    "$(xof "127.0.0.1/$REAL:$A")" "$(xof "127.0.0.1/$PORT:$A")"

# --- ENGINE-BUILT checks fc's DDL surface refuses still ENFORCE:
# --- BETWEEN/IN/LIKE/functions, NUMERIC scale, DATE and the legacy
# --- TIMESTAMP message render
EF="$D/fc-domck-eng.fdb"; FF="$D/fc-domck-eng2.fdb"
rm -f "$EF" "$FF"
"$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 <<SQL
CREATE DATABASE '$EF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE DOMAIN DRANGE AS INTEGER CHECK (VALUE BETWEEN 1 AND 9 AND VALUE <> 5);
CREATE DOMAIN DSET AS VARCHAR(3) CHECK (VALUE IN ('a', 'b') OR VALUE IS NULL);
CREATE DOMAIN DNUM AS NUMERIC(9,2) CHECK (VALUE > 1.5);
CREATE DOMAIN DDT AS DATE CHECK (VALUE > DATE '2020-01-01');
CREATE DOMAIN DTS AS TIMESTAMP CHECK (VALUE > TIMESTAMP '2020-01-01 00:00:00');
CREATE DOMAIN DTM AS TIME CHECK (VALUE > TIME '10:00:00');
CREATE DOMAIN DM2 AS INTEGER CHECK (VALUE > 10);
CREATE DOMAIN "dm2" AS INTEGER CHECK (VALUE > 100);
CREATE TABLE TE (R DRANGE, S DSET, M DNUM, T DDT, TS DTS, TM DTM);
CREATE TABLE CASE2 (STRICT2 "dm2");
INSERT INTO TE (R, S, M, T, TS) VALUES (3, 'a', 100.10, DATE '2021-05-05', TIMESTAMP '2021-05-05 10:00:00');
COMMIT;
SQL
cp "$EF" "$FF"; chmod 666 "$EF" "$FF"
cat > "$D/domread.sql" <<'SQL'
SET LIST ON;
INSERT INTO TE (R) VALUES (5);
INSERT INTO TE (R) VALUES (12);
INSERT INTO TE (R, S) VALUES (3, 'zz');
INSERT INTO TE (R, M) VALUES (3, 1.25);
INSERT INTO TE (R, T) VALUES (3, DATE '2019-05-05');
INSERT INTO TE (R, TS) VALUES (3, TIMESTAMP '2019-06-07 08:09:10.5');
-- a standalone TIME message keeps the PADDED hour (review-caught:
-- only the TIMESTAMP render above is legacy-unpadded)
INSERT INTO TE (R, TM) VALUES (3, TIME '08:09:10.5000');
INSERT INTO TE (R, S, M) VALUES (7, 'b', 2.50);
UPDATE TE SET M = 1.10 WHERE R = 3;
COMMIT;
SELECT R, S, M FROM TE ORDER BY R;
-- EXACT-case domain binding: the column's domain is "dm2" (> 100),
-- not DM2 (> 10) - a case-blind join stored this row (review-caught)
INSERT INTO CASE2 VALUES (50);
INSERT INTO CASE2 VALUES (500);
SELECT STRICT2 FROM CASE2;
-- a second ADD over an out-of-surface existing check still answers
-- the engine's only-one vector (the dup test runs BEFORE the compile)
ALTER DOMAIN DNUM ADD CHECK (VALUE > 5);
SQL
rof() { "$ISQL" -q -user "$U" -pas "$P" "$1" -i "$D/domread.sql" 2>&1 | grep -v "^After line" | norm; }
check "engine-built BETWEEN/IN/NUMERIC/DATE/TIMESTAMP checks enforce identically (incl the legacy timestamp render)" \
    "$(rof "127.0.0.1/$PORT:$FF")" "$(rof "127.0.0.1/$REAL:$EF")"
rm -f "$EF" "$FF"

# --- fc's DDL-surface refusals stay refusals (never a silent domain
# --- without its rule): NUMERIC target, subquery, foreign name, and
# --- the engine's clause ORDER (CHECK before DEFAULT is a -104 there
# --- - review-caught: fc used to create it)
ran=$((ran + 1))
rf=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$A" 2>&1 <<'SQL'
CREATE DOMAIN DBAD1 AS NUMERIC(9,2) CHECK (VALUE > 0);
CREATE DOMAIN DBAD2 AS INTEGER CHECK (OTHER > 0);
CREATE DOMAIN DBAD3 AS INTEGER CHECK (VALUE > 0) DEFAULT 5;
SET LIST ON;
SELECT COUNT(*) NBAD FROM RDB$FIELDS WHERE RDB$FIELD_NAME IN ('DBAD1', 'DBAD2', 'DBAD3');
SQL
)
case "$rf" in *"NBAD 0"*|*"NBAD                            0"*) echo "OK   an out-of-surface CREATE DOMAIN CHECK refuses whole (no unshielded domain)";;
    *) echo "DIFF out-of-surface check: [$rf]"; fail=1;; esac

# --- a LOSSILY transliterated source (the engine enforces from the
# --- BLR; fc's re-parse would enforce a WRONG rule) refuses DML ---
LF="$D/fc-domck-lossy.fdb"
rm -f "$LF"
"$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 <<SQL
CREATE DATABASE '$LF' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE DOMAIN DU8 AS VARCHAR(10) CHARACTER SET UTF8 CHECK (VALUE <> 'né');
CREATE TABLE E4 (U DU8);
COMMIT;
SQL
chmod 666 "$LF"
ran=$((ran + 1))
lr=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$LF" 2>&1 <<'SQL' | norm
INSERT INTO E4 VALUES ('ok');
SET LIST ON;
SELECT COUNT(*) NL FROM E4;
SQL
)
case "$lr" in *"Dynamic SQL Error"*"NL 0"*)
    echo "OK   a lossy '?'-marked check source refuses DML (never a wrong rule enforced)";;
    *) echo "DIFF lossy-source handling: [$lr]"; fail=1;; esac
rm -f "$LF"

gf=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1)
ran=$((ran + 1))
if [ -z "$gf" ]; then echo "OK   gfix -v -full clean on fc's file"; else echo "DIFF gfix: $gf"; fail=1; fi

echo "ran $ran checks"
exit $fail
