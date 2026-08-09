#!/bin/bash
# The CHECK surface takes TEXT, NULL and BIGINT - and the INLINE
# column-level form, which turned out to be the real wall: the first
# text-CHECK probes looked like a type refusal and were a PARSE gap
# (`V VARCHAR(5) CHECK (...)` never split the clause off the column).
#
# The stored text literal is GOLD-PINNED from an engine-created CHECK:
# blr_literal blr_text2, charset u16 LE (NONE), length u16 LE, bytes -
# and the STRONGEST check below is the engine ENFORCING fire-crab's
# stored trigger: it must reject a violating INSERT with its own 23000
# vector, through fire-crab's file.
#
#   qa/serve-real-checktext.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4730}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
EDB="$D/fc-ckt-e.fdb"; FDB="$D/fc-ckt-f.fdb"
rm -f "$EDB" "$FDB"
for c in "localhost:$EDB" "$FDB"; do "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$c' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
EOF
done
chmod 666 "$EDB" "$FDB" 2>/dev/null
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ckt-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
both() { a=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$E" 2>&1 | tr -s ' \n' ' '); b=$(printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$F" 2>&1 | tr -s ' \n' ' '); check "$1" "$b" "$a"; }
both "an inline text CHECK creates" "CREATE TABLE T1 (V VARCHAR(5) CHECK (V = 'x'));"
both "...rejects a violation with the 23000 vector" "INSERT INTO T1 VALUES ('y');"
both "...accepts a match" "INSERT INTO T1 VALUES ('x');"
both "...and NULL passes (a CHECK fails only on FALSE)" "INSERT INTO T1 VALUES (NULL);"
both "an inline BIGINT CHECK creates" "CREATE TABLE T2 (B BIGINT CHECK (B > 3000000000));"
both "...rejects" "INSERT INTO T2 VALUES (5);"
both "...accepts" "INSERT INTO T2 VALUES (4000000000);"
both "text ordering creates" "CREATE TABLE T3 (V VARCHAR(5) CHECK (V < 'm'));"
both "...rejects" "INSERT INTO T3 VALUES ('z');"
both "...accepts" "INSERT INTO T3 VALUES ('a');"
both "the int inline form still works" "CREATE TABLE T4 (N INTEGER CHECK (N > 0), M INTEGER);"
both "...and rejects" "INSERT INTO T4 VALUES (0, 1);"
# THE ORACLE'S ORACLE: the engine enforces fire-crab's stored trigger
out=$(printf "INSERT INTO T1 VALUES ('no');\n" | "$ISQL" -q -user "$U" -pas "$P" "localhost:$FDB" 2>&1 | tr -s ' \n' ' ')
check "the ENGINE enforces fire-crab's stored text CHECK" \
    "$out" "Statement failed, SQLSTATE = 23000 Operation violates CHECK constraint \"INTEG_1\" on view or table \"PUBLIC\".\"T1\" -At trigger \"PUBLIC\".\"CHECK_1\" "
echo "ran $ran checks"
exit $fail
