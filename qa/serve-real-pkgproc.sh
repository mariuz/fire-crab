#!/bin/bash
# PACKAGED procedures execute - a package qualifier is not a schema
# qualifier.
#
# THE RESOLUTION, measured: a bare name and `PUBLIC.name` are the plain
# procedure; any other two-part `Q.N` tries package Q down the search
# path (PUBLIC, then SYSTEM - `RDB$PROFILER.FLUSH` answers, and so does
# a user package's member, while `SYSTEM.PADD` and `NOPKG.PADD` refuse
# -204 Procedure unknown IDENTICALLY); a three-part `S.P.N` constrains
# the schema (`PUBLIC.PKG.PADD` answers, `SYSTEM.PKG.PADD` refuses).
#
# A user packaged procedure's TEXT lives only in the package BODY
# source (its RDB$PROCEDURES row carries a NULL blob) - fire-crab
# extracts the member's AS-tail and interprets it like a plain body.
# The SYSTEM package RDB$PROFILER is NATIVE (no body source at all):
# every member executes silently with no session on the engine, and no
# session can ever exist here (START_SESSION is a function outside the
# surface), so a no-op is honest for every reachable state; its
# DEFAULTED inputs are omittable exactly as the engine's are
# (SET_FLUSH_INTERVAL still requires its interval).
#
#   qa/serve-real-pkgproc.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4785}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
RE="$D/fc-pkgproc-re.fdb"; FC="$D/fc-pkgproc-fc.fdb"

mkdir -p "$D"; rm -f "$RE" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL create"; exit 1; }
CREATE DATABASE '$RE' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE TLOG (V INTEGER);
SET TERM ^;
CREATE PACKAGE PKG AS
BEGIN
  PROCEDURE PADD (A INTEGER, B INTEGER) RETURNS (S INTEGER);
  PROCEDURE PTWO (A INTEGER) RETURNS (R INTEGER, T INTEGER);
END^
CREATE PACKAGE BODY PKG AS
BEGIN
  PROCEDURE PADD (A INTEGER, B INTEGER) RETURNS (S INTEGER) AS
  BEGIN
    S = A + B;
  END
  PROCEDURE PTWO (A INTEGER) RETURNS (R INTEGER, T INTEGER) AS
  DECLARE H INTEGER;
  BEGIN
    H = A * 10;
    IF (H > 50) THEN
    BEGIN
      H = 50;
    END
    R = H;
    T = A - 1;
  END
END^
CREATE PROCEDURE PLAIN (X INTEGER) RETURNS (Y INTEGER) AS BEGIN Y = X * 2; END^
SET TERM ;^
COMMIT;
EOF
cp "$RE" "$FC"; chmod 666 "$RE" "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-pkgproc.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$RE" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || {
    echo "FAIL fcwire is not running - port $PORT already in use? (see the server log)"
    exit 1
}

fail=0
ran=0

# full-output differential: the statement's isql output, engine
# (embedded, $RE) against fc (served, $FC), byte for byte
both() { # <label> <sql>
    ran=$((ran + 1))
    a=$(printf 'SET LIST ON;\n%s;\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$RE" 2>&1)
    b=$(printf 'SET LIST ON;\n%s;\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "localhost/$PORT:$FC" 2>&1)
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "  engine: $(echo "$a" | tr '\n' '|')"
        echo "  fc:     $(echo "$b" | tr '\n' '|')"
        fail=1
    fi
}

# both sides REFUSE; the texts differ exactly as they already do for an
# unqualified unknown name (recorded divergence), so the assertion is
# the refusal, not the words
bothrefuse() { # <label> <sql>
    ran=$((ran + 1))
    a=$(printf '%s;\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$RE" 2>&1 | grep -c 'SQLSTATE')
    b=$(printf '%s;\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "localhost/$PORT:$FC" 2>&1 | grep -c 'SQLSTATE')
    if [ "$a" -ge 1 ] && [ "$b" -ge 1 ]; then
        echo "OK   $1 (both refuse)"
    else
        echo "DIFF $1: engine refusals=$a fc refusals=$b (want both >= 1)"
        fail=1
    fi
}

# --- the SYSTEM native package: silent no-ops --------------------------
both "RDB\$PROFILER.FLUSH executes NONE on both" \
     "EXECUTE PROCEDURE RDB\$PROFILER.FLUSH"
both "... the three-part SYSTEM spelling too" \
     "EXECUTE PROCEDURE SYSTEM.RDB\$PROFILER.FLUSH"
both "... PAUSE_SESSION (its defaulted BOOLEAN is omittable)" \
     "EXECUTE PROCEDURE RDB\$PROFILER.PAUSE_SESSION"
both "... FINISH_SESSION" "EXECUTE PROCEDURE RDB\$PROFILER.FINISH_SESSION"
both "... CANCEL_SESSION" "EXECUTE PROCEDURE RDB\$PROFILER.CANCEL_SESSION"
both "... DISCARD" "EXECUTE PROCEDURE RDB\$PROFILER.DISCARD"
both "SET_FLUSH_INTERVAL takes its required interval" \
     "EXECUTE PROCEDURE RDB\$PROFILER.SET_FLUSH_INTERVAL(5)"

# --- a USER package's members run their bodies -------------------------
both "a packaged procedure executes: PKG.PADD answers" \
     "EXECUTE PROCEDURE PKG.PADD(2, 3)"
both "... the three-part spelling" "EXECUTE PROCEDURE PUBLIC.PKG.PADD(2, 3)"
both "... quoted part by part" \
     'EXECUTE PROCEDURE "PUBLIC"."PKG"."PADD"(2, 3)'
both "a member with declares, a nested block and TWO outputs" \
     "EXECUTE PROCEDURE PKG.PTWO(9)"
both "... and under the clamp branch" "EXECUTE PROCEDURE PKG.PTWO(3)"
both "the plain procedure still answers beside them" \
     "EXECUTE PROCEDURE PUBLIC.PLAIN(3)"

# --- the refusals, identical in SHAPE on the engine --------------------
bothrefuse "a known package's unknown member refuses" \
     "EXECUTE PROCEDURE PKG.NOSUCH"
bothrefuse "an unknown qualifier refuses the same way" \
     "EXECUTE PROCEDURE NOPKG.PADD(1, 2)"
bothrefuse "a plain procedure is not a package member" \
     "EXECUTE PROCEDURE PKG.PLAIN(3)"
bothrefuse "the wrong schema refuses the three-part name" \
     "EXECUTE PROCEDURE SYSTEM.PKG.PADD(2, 3)"
bothrefuse "a missing REQUIRED argument refuses (texts differ: the
     engine's 07001 parameter-mismatch vector is a recorded divergence)" \
     "EXECUTE PROCEDURE PKG.PADD(2)"
bothrefuse "... and so does SET_FLUSH_INTERVAL with none" \
     "EXECUTE PROCEDURE RDB\$PROFILER.SET_FLUSH_INTERVAL"

# --- the file survives the engine's own verifier ----------------------
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
if [ -z "$v" ]; then
    echo "OK   gfix -v -full is clean on fc's file"
else
    echo "DIFF gfix: $v"
    fail=1
fi

if [ "$ran" -lt 20 ]; then
    echo "DIFF only $ran checks ran (expected at least 20) - did one silently skip?"
    fail=1
fi
kill $srv 2>/dev/null; wait $srv 2>/dev/null
if [ "$fail" = 0 ]; then
    echo "PASS serve-real-pkgproc ($ran checks)"
else
    echo "FAIL serve-real-pkgproc"
    exit 1
fi
