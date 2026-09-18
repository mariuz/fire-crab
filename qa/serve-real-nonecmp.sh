#!/bin/bash
# A REAL-CHARSET TEXT COLUMN COMPARED TO A BYTE-CARRIER LITERAL COMPARES
# IN BYTE SPACE, so a matching row is not silently dropped.
#
# isql's default attachment is effectively NONE, so a text literal
# arrives as one char per octet: `'café'` is five carrier octets, not
# four Unicode chars. The engine compares a NONE/OCTETS operand against
# a real-charset column by reading the carrier's OCTETS as the column's
# charset (byte space), so `WHERE u = 'café'` MATCHES a UTF8 column -
# and, crucially, it NEVER validates or raises: `WHERE u = x'…FF'`
# (bytes that do not spell UTF-8) is simply 0 rows, where the same bytes
# through a CAST are 22000. fire-crab used to compare the carrier chars
# against the column's real chars and return 0 rows - a qualifying row
# silently vanished, and every operator (=, <>, <, >, BETWEEN, IN) was
# affected.
#
# The fix reinterprets the literal once at prepare (`decode_text` of the
# carrier octets in the column's charset); a bad-byte literal stays a
# carrier string that equals no real value - the engine's no-match /
# no-raise. Held against the live engine under the NONE attachment
# (truth) and, as a regression guard, under UTF8 and WIN1252.
#
# Usage: qa/serve-real-nonecmp.sh [port]   (default 4143)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4143}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/nonecmp-eng.fdb"; FC="$D/nonecmp-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/nonecmp-build.log 2>&1 <<'SQL'
create table t (id int, u varchar(20) character set utf8, w varchar(20) character set win1252);
commit;
insert into t values (1,'café','café');
insert into t values (2,'abc','abc');
insert into t values (3,'niño','niño');
insert into t values (4,'Zürich','Zürich');
commit;
-- a TEXT BLOB carries its charset in the descriptor's SCALE, and
-- `col_kind` answers None for a blob - so the literal fast path
-- (adopt_carrier_literal) never sees one and the blob reaches the
-- EXPRESSION arm instead. Added here so that route is gated too.
alter table t add b blob sub_type text character set utf8;
commit;
update t set b = u;
commit;
-- a NONE (byte-carrier) COLUMN, for the MIRROR direction: the carrier is
-- the COLUMN and the literal is REAL. Added by ALTER rather than widening
-- the column-less `insert ... values` list above - and it must exist, or
-- every cell naming it errors on BOTH servers and sig()'s REFUSE would
-- compare equal to REFUSE and score a vacuous OK.
alter table t add nn varchar(20) character set none;
commit;
update t set nn = u;
commit;
SQL
if grep -qi error /tmp/nonecmp-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/nonecmp-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-nonecmp.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# THIS GATE HAD NO COUNTER AT ALL until 2026-09-18: a block that silently
# stopped being read - an edit that drops a line, a helper renamed - would
# have left it green over fewer cells with no sign. Every helper counts,
# and the floor at the bottom is derived from the invocations.
ran=0
# the rows/value, or REFUSE, under an optional client charset ($4)
sig() { local ch="" ; [ -n "${4:-}" ] && ch="-ch $4"; local r; \
    r=$(printf 'set list on;\n%s\n' "$3" | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 | sed 's/  */ /g' | grep -ivE '^$|SQL>'); \
    if printf '%s' "$r" | grep -qi 'failed\|malformed\|error'; then echo "REFUSE"; \
    else printf '%s' "$r" | grep -iE '^(N|ID) ' | tr -d ' \n'; fi; }
agree() { # <label> <sql> [client-charset]
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/3050:$ENG" x "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" x "$2" "${3:-}")
    if [ "$e" = "$f" ]; then echo "OK   $1 [$e]"; else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

echo "-- NONE attachment (default): the byte-space comparison --"
agree "u = 'café'"          "select count(*) n from t where u='café';"
agree "u = 'niño'"          "select count(*) n from t where u='niño';"
agree "u = 'Zürich'"        "select count(*) n from t where u='Zürich';"
agree "u = 'abc' (ascii)"   "select count(*) n from t where u='abc';"
agree "u <> 'café'"         "select count(*) n from t where u<>'café';"
agree "u > 'café'"          "select count(*) n from t where u>'café';"
agree "u <= 'café'"         "select count(*) n from t where u<='café';"
agree "u BETWEEN"           "select count(*) n from t where u between 'café' and 'niño';"
agree "u IN (café,abc)"     "select count(*) n from t where u in ('café','abc');"
agree "ids where u='café'"  "select id from t where u='café';"
agree "w = 'café' (win1252)" "select count(*) n from t where w='café';"
echo "-- the no-raise inversion: bad bytes are 0 rows, never an error --"
agree "u = x'636166FF'"     "select count(*) n from t where u=x'636166FF';"
agree "u = x'FF'"           "select count(*) n from t where u=x'FF';"
# A RAISE CELL NEEDS THE MESSAGE, NOT JUST "an error": sig() above maps
# every failure to the single word REFUSE, so two DIFFERENT errors would
# score as agreement - the same trap as counting `grep -ci error`.
mal() { local ch=""; [ -n "${3:-}" ] && ch="-ch $3"
    if printf 'set list on;\n%s\n' "$2" \
        | "$ISQL" -q $ch -user "$U" -pas "$P" "$1" 2>&1 | grep -aqi 'malformed string'
    then echo MALFORMED; else echo OTHER; fi; }
# A RECORDED DIVERGENCE, self-expiring: the two servers must still
# DISAGREE. It fails if they start AGREEING - which is the signal to
# promote the cell back to `agree` - and it fails if either side does not
# answer, so two REFUSEs can never be scored as a difference (sig()
# collapses every error to that one word).
differs() { # <label> <sql> [client-charset]
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/3050:$ENG" x "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" x "$2" "${3:-}")
    if [ "$e" = REFUSE ] || [ "$f" = REFUSE ] || [ -z "$e" ] || [ -z "$f" ]; then
        echo "FAIL $1 [VACUOUS: a side did not answer] eng=[$e] fc=[$f]"; fail=1
    elif [ "$e" != "$f" ]; then
        echo "OK   recorded divergence: $1 eng=[$e] fc=[$f]"
    else
        echo "FAIL $1 NOW AGREES [$e] - the mirror is fixed; promote this cell to agree"; fail=1
    fi
}

# A RECORDED CAPABILITY GAP: the engine ANSWERS and this server REFUSES.
# Both sides are checked - a cell where the ENGINE also fails measures
# nothing and scores DIFF, not OK - and it goes red the day fire-crab
# answers, which is the signal to promote it to `agree` with the engine's
# own value rather than to delete it.
refuses() { # <label> <sql> [client-charset]
    ran=$((ran + 1))
    local e f
    e=$(sig "127.0.0.1/3050:$ENG" x "$2" "${3:-}"); f=$(sig "127.0.0.1/$PORT:$FC" x "$2" "${3:-}")
    if [ "$e" = REFUSE ] || [ -z "$e" ]; then
        echo "FAIL $1 [VACUOUS: the ENGINE did not answer either] eng=[$e]"; fail=1
    elif [ "$f" = REFUSE ]; then
        echo "OK   refused (recorded gap): $1 [engine answers $e]"
    else
        echo "FAIL $1 now ANSWERS [$f] - the gap is closed; promote this cell to agree"; fail=1
    fi
}

malformed() { # <label> <sql> - BOTH servers must raise 22000 Malformed string
    ran=$((ran + 1))
    local e f
    e=$(mal "127.0.0.1/3050:$ENG" "$2"); f=$(mal "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = MALFORMED ] && [ "$f" = MALFORMED ]; then
        echo "OK   $1 [both 22000 Malformed string]"
    else echo "FAIL $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi; }

echo "-- LIKE joins the byte-space law: the pattern reinterprets too --"
agree "u LIKE '%é%'"          "select count(*) n from t where u like '%é%';"
agree "u LIKE '%é'"           "select count(*) n from t where u like '%é';"
agree "u LIKE 'café' exact"   "select count(*) n from t where u like 'café';"
agree "u LIKE '%café%'"       "select count(*) n from t where u like '%café%';"
agree "u LIKE 'caf%' (ascii)" "select count(*) n from t where u like 'caf%';"
agree "u LIKE 'c%é%'"         "select count(*) n from t where u like 'c%é%';"
agree "u LIKE '%ñ%'"          "select count(*) n from t where u like '%ñ%';"
agree "u LIKE '%ü%'"          "select count(*) n from t where u like '%ü%';"
agree "u NOT LIKE '%é%'"      "select count(*) n from t where u not like '%é%';"
agree "u NOT LIKE 'é%'"       "select count(*) n from t where u not like 'é%';"
agree "w LIKE '%é%' win1252"  "select count(*) n from t where w like '%é%';"
agree "ids where u LIKE '%é%'" "select id from t where u like '%é%' order by id;"
echo "-- ...and a leading segment ending MULTI-BYTE is 22000, not a match --"
malformed "u LIKE 'é%'"       "select count(*) n from t where u like 'é%';"
malformed "u LIKE 'café%'"    "select count(*) n from t where u like 'café%';"
malformed "u LIKE 'é_'"       "select count(*) n from t where u like 'é_';"
malformed "u LIKE 'ñ%'"       "select count(*) n from t where u like 'ñ%';"
agree "u LIKE 'éx%' ANSWERS"  "select count(*) n from t where u like 'éx%';"
echo "-- the raise is PER ROW: a FALSE written before it suppresses it --"
agree "1=0 AND u LIKE 'é%'"   "select count(*) n from t where 1=0 and u like 'é%';"
agree "u LIKE 'é%' AND 1=0"   "select count(*) n from t where u like 'é%' and 1=0;"
agree "1=1 OR u LIKE 'é%'"    "select count(*) n from t where 1=1 or u like 'é%';"
echo "-- the EXPRESSION path takes the same law (no column descriptor) --"
agree "u||'' LIKE '%é%'"      "select count(*) n from t where u||'' like '%é%';"
agree "UPPER(u) LIKE '%É%'"   "select count(*) n from t where upper(u) like '%É%';"
malformed "u||'' LIKE 'é%'"   "select count(*) n from t where u||'' like 'é%';"
agree "CAST(u) LIKE '%é%' ctl" "select count(*) n from t where cast(u as varchar(20)) like '%é%';"
echo "-- THE MIRROR: the CARRIER is the COLUMN and the literal is REAL --"
echo "--  (a real attachment; the engine still compares in byte space) --"
# FIXED 2026-09-18 and promoted from `differs`: the FUNCTION path now
# reconciles in byte space when a carrier operand meets a real one
# ([carrier_fn_operands]), so these seven answer the engine's values.
agree "POSITION('é' IN nn) @UTF8"      "select position('é' in nn) n from t where id=1;" UTF8
agree "POSITION(nn IN 'xcafé') @UTF8"  "select position(nn in 'xcafé') n from t where id=1;" UTF8
agree "REPLACE(nn,'é','e') @UTF8"      "select octet_length(replace(nn,'é','e')) n from t where id=1;" UTF8
agree "TRIM(TRAILING 'é' FROM nn)@UTF8" "select octet_length(trim(trailing 'é' from nn)) n from t where id=1;" UTF8
# STILL RECORDED, and NOT an oversight: CONTAINING is built by
# [containing_term] into a `Term::ExprLike` - the shared PREDICATE path,
# not the function path. An earlier attempt re-keyed that shared path and
# turned the CORRECT `nn LIKE '%é%'` below into a wrong answer, so this
# slice deliberately leaves it alone. Measured on this binary: engine 1,
# this server 0.
differs "nn CONTAINING 'é' @UTF8"        "select count(*) n from t where nn containing 'é';" UTF8
agree "nn LIKE '%é%' @UTF8"            "select count(*) n from t where nn like '%é%';" UTF8
echo "--  an OCTETS operand is the same carrier case --"
agree "POSITION('é' IN octets) @UTF8"  "select position('é' in cast(u as varchar(20) character set octets)) n from t where id=1;" UTF8
differs "octets CONTAINING 'é' @UTF8"    "select count(*) n from t where cast(u as varchar(20) character set octets) containing 'é';" UTF8
agree "REPLACE(octets,'é','e') @UTF8"  "select octet_length(replace(cast(u as varchar(20) character set octets),'é','e')) n from t where id=1;" UTF8
agree "POSITION('é' IN padded) @UTF8"  "select position('é' in cast(u as char(8) character set octets)) n from t where id=1;" UTF8
echo "--  COLUMN vs COLUMN: no literal exists to rewrite, so the literal --"
echo "--  fast path could never have reached these. Both attachments.   --"
agree "POSITION(nn IN u) cols"          "select position(nn in u) n from t where id=1;"
agree "POSITION(u IN nn) cols"          "select position(u in nn) n from t where id=1;"
agree "TRIM(TRAILING nn FROM u) cols"   "select octet_length(trim(trailing nn from u)) n from t where id=1;"
agree "REPLACE(u,nn,'x') cols"          "select octet_length(replace(u,nn,'x')) n from t where id=1;"
agree "POSITION(nn IN u) cols @UTF8"    "select position(nn in u) n from t where id=1;" UTF8
agree "REPLACE(u,nn,'x') cols @UTF8"    "select octet_length(replace(u,nn,'x')) n from t where id=1;" UTF8
echo "--  a NON-LITERAL pattern is a MISSING CAPABILITY, not this law:   --"
echo "--  fire-crab refuses it for SAME-charset operands too (measured), --"
echo "--  so it ranks below every wrong answer and is recorded, not fixed --"
refuses "u CONTAINING nn (column pattern)" "select count(*) n from t where u containing nn;"
refuses "nn CONTAINING u (column pattern)" "select count(*) n from t where nn containing u;"
refuses "u LIKE nn (column pattern)"       "select count(*) n from t where u like nn;"
echo "--  controls: BOTH-carrier and BOTH-real need no reconciliation --"
agree "POSITION('é' IN nn) @NONE"      "select position('é' in nn) n from t where id=1;"
agree "nn CONTAINING 'é' @NONE"        "select count(*) n from t where nn containing 'é';"
agree "POSITION('é' IN u) @UTF8 ctl"   "select position('é' in u) n from t where id=1;" UTF8
agree "POSITION('f' IN nn) ascii ctl"  "select position('f' in nn) n from t where id=1;" UTF8
agree "TRIM(TRAILING 'é' FROM padded)" "select octet_length(trim(trailing 'é' from cast(u as char(8) character set octets))) n from t where id=1;" UTF8
echo "-- a TEXT BLOB is the same law by a DIFFERENT route: col_kind is None --"
echo "--  for a blob, so the literal fast path never sees it --"
agree "b CONTAINING 'é'"              "select count(*) n from t where b containing 'é';"
agree "b CONTAINING 'ñ'"              "select count(*) n from t where b containing 'ñ';"
agree "b CONTAINING 'caf' ascii ctl"  "select count(*) n from t where b containing 'caf';"
agree "POSITION('é' IN b)"            "select position('é' in b) n from t where id=1;"
agree "b LIKE '%é%'"                  "select count(*) n from t where b like '%é%';"
agree "OCTET_LENGTH(b) control"       "select octet_length(b) n from t where id=1;"
agree "b CONTAINING 'é' @UTF8"        "select count(*) n from t where b containing 'é';" UTF8
echo "-- the STRING FUNCTIONS take the same byte-space law --"
agree "POSITION('é' IN u)  needle"    "select position('é' in u) n from t where id=1;"
agree "POSITION('café' IN u) whole"   "select position('café' in u) n from t where id=1;"
agree "POSITION(u IN 'xcafé') cont'r" "select position(u in 'xcafé') n from t where id=1;"
agree "POSITION('ñ' IN u)"            "select position('ñ' in u) n from t where id=3;"
agree "POSITION('f' IN u) ascii ctl"  "select position('f' in u) n from t where id=1;"
agree "REPLACE(u,'é','e') octets"     "select octet_length(replace(u,'é','e')) n from t where id=1;"
agree "REPLACE(u,'ñ','n') octets"     "select octet_length(replace(u,'ñ','n')) n from t where id=3;"
agree "TRIM(TRAILING 'é') octets"     "select octet_length(trim(trailing 'é' from u)) n from t where id=1;"
agree "TRIM(LEADING 'c') ascii ctl"   "select octet_length(trim(leading 'c' from u)) n from t where id=1;"
agree "POSITION('é' IN w) win1252"    "select position('é' in w) n from t where id=1;"
echo "-- ...and both-carrier / real-attachment forms are untouched --"
agree "POSITION('é' IN u) @UTF8"      "select position('é' in u) n from t where id=1;" UTF8
agree "REPLACE(u,'é','e') @UTF8"      "select octet_length(replace(u,'é','e')) n from t where id=1;" UTF8
agree "TRIM(TRAILING 'é') @UTF8"      "select octet_length(trim(trailing 'é' from u)) n from t where id=1;" UTF8
agree "POSITION('é' IN w) @WIN1252"   "select position('é' in w) n from t where id=1;" WIN1252
echo "-- regression: real attachments must be unchanged --"
agree "u='café' @UTF8"      "select count(*) n from t where u='café';" UTF8
agree "u='abc' @UTF8"       "select count(*) n from t where u='abc';" UTF8
agree "w='café' @WIN1252"   "select count(*) n from t where w='café';" WIN1252
agree "u ordering @UTF8"    "select id from t where u>'café' order by id;" UTF8

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
echo "ran $ran checks"
# derived from the invocations, not guessed: agree + differs + malformed
# + refuses. A block that stops being read trips this instead of passing
# quietly over fewer cells.
if [ "$ran" -lt 86 ]; then
    echo "FAIL only $ran checks ran (expected at least 86) - did a block silently skip?"
    fail=1
fi
[ $fail = 0 ] && echo "PASS nonecmp" || echo "FAIL nonecmp"
exit $fail
