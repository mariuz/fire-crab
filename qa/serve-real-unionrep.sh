#!/bin/bash
# A DEDUP COLLISION WHOSE VARCHAR SURVIVOR DIFFERS ONLY IN TRAILING
# BLANKS HAS NO REPRODUCIBLE SPELLING - SO IT IS REFUSED, NEVER GUESSED.
#
# A DISTINCT UNION (or SELECT DISTINCT) that collapses two rows equal
# only up to trailing blanks must return ONE row - but WHICH spelling?
# The engine returns whichever the LAST row fed to its unique-sort
# carried: `SELECT c3 UNION SELECT v5` (c3=CHAR(3)'ab ', v5=VARCHAR(5)
# 'ab') answers the v5 'ab' (last leg), the reverse order answers 'ab '
# (the other leg), and a table's DISTINCT/GROUP flips with INSERT order.
# It is a storage-/leg-order artifact this server does not reproduce.
# fire-crab used to keep the FIRST occurrence and return its un-re-padded
# bytes ('ab ') where the engine returned 'ab' - a confident wrong
# spelling on a VARCHAR result.
#
# Because a VARCHAR survivor is not re-padded by the encoder (unlike a
# CHAR, which pads to its declared width and so has an invariant
# representative), fire-crab now REFUSES the dedup when a collapse
# differs in bytes on a VARYING column - the same call it already makes
# for a CASE/ACCENT-insensitive collation, here for the default PAD
# SPACE one, and only when the colliding rows actually differ. A refusal
# beats a wrong spelling. Held against the live engine: the collisions
# refuse; every unambiguous shape (byte-equal VARCHAR, UNION ALL, plain
# DISTINCT over differing values, CHAR results) still answers and
# matches.
#
# RECORDED, not done here (same law, separate sites): the eager refusal
# also refuses a COUNT/EXISTS/outer-filtered query over an ambiguous
# union where the value never reaches the client (a lazy poison would
# narrow it); GROUP BY / MIN / MAX representative (compute_group); and a
# CHAR-result union that does not re-pad the survivor to the result
# width (a fixable-to-match padding gap, pre-existing).
#
# Usage: qa/serve-real-unionrep.sh [port]   (default 4150)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4150}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/unionrep-eng.fdb"; FC="$D/unionrep-fc.fdb"
rm -f "$ENG" "$FC"
echo "create database '127.0.0.1/3050:$ENG' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $ENG"; exit 1; }
"$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" >/tmp/unionrep-build.log 2>&1 <<'SQL'
create table t(id int, c3 char(3), c5 char(5), v5 varchar(5), v3 varchar(3), nm varchar(10));
commit;
insert into t values (1, 'ab', 'ab', 'ab', 'ab', 'alice');
commit;
SQL
if grep -qi error /tmp/unionrep-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/unionrep-build.log; exit 1; fi
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-unionrep.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# ANSWER (the row values) or REFUSE
sig() { local r; r=$(printf 'set list on;\n%s\n' "$2" | "$ISQL" -q -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 | grep -viE '^$|SQL>|Database:'); \
    if printf '%s' "$r" | grep -qiE 'SQLSTATE|error|unsupported|feature|not supported|failed|token unknown'; then echo REFUSE; \
    else printf '%s' "$r" | grep -iE '^(OL|CL|N|X) ' | tr -d ' ' | tr '\n' ','; fi; }

# the reported bug: engine ANSWERS, fire-crab must now REFUSE (law-safe)
refuses() { # <label> <sql>
    local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" != "REFUSE" ] && [ "$f" = "REFUSE" ]; then echo "OK   refuse: $1 (eng=[$e])";
    else echo "FAIL refuse: $1"; echo "     eng=[$e] fc=[$f] (want eng answers, fc REFUSE)"; fail=1; fi
}
# controls: engine and fire-crab agree (both answer the same)
agree() { # <label> <sql>
    local e f; e=$(sig "127.0.0.1/3050:$ENG" "$2"); f=$(sig "127.0.0.1/$PORT:$FC" "$2")
    if [ "$e" = "$f" ]; then echo "OK   agree:  $1 [$e]"; else echo "FAIL agree: $1"; echo "     eng=[$e] fc=[$f]"; fail=1; fi
}

echo "-- the bug: a blank-only-differing VARCHAR dedup survivor is REFUSED --"
refuses "c3 UNION v5"        "select octet_length(x) ol from (select c3 x from t union select v5 from t) z;"
refuses "v5 UNION c3 (rev)"  "select octet_length(x) ol from (select v5 x from t union select c3 from t) z;"
refuses "3-leg c3 U v5 U c5" "select octet_length(x) ol from (select c3 x from t union select v5 from t union select c5 from t) z;"
refuses "SELECT DISTINCT mix" "select octet_length(x) ol from (select distinct c3 x from t union select v5 from t) z;"
echo "-- controls that must STILL ANSWER and match the engine --"
agree "byte-equal v3 U v5"   "select octet_length(x) ol from (select v3 x from t union select v5 from t) z;"
agree "UNION ALL passthrough" "select octet_length(x) ol from (select c3 x from t union all select v5 from t) z order by 1;"
agree "plain distinct ints"  "select x from (select 1 x from t union select 2 from t) z order by 1;"
agree "distinct diff varchars" "select octet_length(x) ol from (select 'ab' x from t union select 'cd' from t) z order by 1;"
agree "same-value varchar U"  "select nm x from (select nm from t union select nm from t) z;"
agree "SELECT DISTINCT one col" "select id x from (select distinct id from t) z;"
agree "UNION of distinct rows" "select x from (select 'p' x from t union select 'q' from t union select 'r' from t) z order by 1;"

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS unionrep" || echo "FAIL unionrep"
exit $fail
