#!/bin/sh
# ARRAY-ELEMENT SUBSCRIPT in a search condition and a projection, over
# the stock employee.fdb JOB.LANGUAGE_REQ VARCHAR(15)[1:5] (31 rows, 10
# with a non-null element 1). The defect this gate guards:
#
#   project_read_len under-estimated the partial-decompression length
#   because expr_reads had no Expr::ArrayElem arm, so the array column
#   (JOB's LAST field) was left undecoded on the natural-scan path and
#   every array-element read - in a WHERE filter AND in the projection
#   under a natural-scan filter - collapsed to NULL for EVERY row. A
#   confident WRONG rowset, not a refusal (serve-real-wherearr).
#
#   AND: the WHERE/HAVING/ON tokenizer had no arm for the `[` byte, so a
#   BARE `COL[i]` predicate refused at prepare. It now lexes `COL[...]`
#   whole through the char-based expression parser, so a bare subscript
#   in WHERE reads the real element and matches the engine.
#
# Differential and TRANSPORT-FIXED: the engine is reached over TCP at
# 127.0.0.1/${FC_REAL_PORT:-3050} and fire-crab over TCP at its port, so
# the two answers differ only in the server, never in the attachment.
#
#   qa/serve-real-wherearr.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GBAK="${GBAK:-gbak}"
PORT="${1:-4533}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
STOCK="${STOCK_EMPLOYEE:-/opt/firebird/examples/empbuild/employee.fdb}"
DBE="$D/fc-wherearr-engine.fdb"; DBF="$D/fc-wherearr-crab.fdb"
LOG="/tmp/fc-serve-wherearr-$PORT.log"
fail=0; ran=0
mkdir -p "$D"
[ -f "$STOCK" ] || { echo "SKIP stock employee.fdb not found at $STOCK"; exit 0; }
rm -f "$DBE" "$DBF"; cp "$STOCK" "$DBE"; cp "$STOCK" "$DBF"; chmod 666 "$DBE" "$DBF"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"$LOG" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$DBE" "$DBF"' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }

norm() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -a -v '^$' | tr '\n' '|'; }
ask() { printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | norm; }

# eng == fc for the same SQL. The engine IS the ground truth, so the
# check is simply "the two servers agree", which is the project law.
check() {
    ran=$((ran + 1))
    e=$(ask "127.0.0.1/$REAL:$DBE" "$1")
    c=$(ask "127.0.0.1/$PORT:$DBF" "$1")
    if [ "$e" = "$c" ]; then echo "OK   $1"; else
        echo "DIFF $1"; echo "     eng: [$e]"; echo "     fc:  [$c]"; fail=1; fi
}

# --- wrapped element in WHERE: were a confident WRONG rowset (NULL for
#     every row); must now equal the engine ---
check "SELECT COUNT(*) FROM job WHERE coalesce(language_req[1],'x')='x';"          # 21
check "SELECT COUNT(*) FROM job WHERE trim(language_req[1]) IS NOT NULL;"          # 10
check "SELECT COUNT(*) FROM job WHERE coalesce(language_req[1],'x') LIKE 'English%';" # 6
check "SELECT COUNT(*) FROM job WHERE substring(language_req[1] from 1 for 7)='English';" # 6
check "SELECT COUNT(*) FROM job WHERE upper(language_req[1])='ENGLISH';"           # 0 (trailing byte)
check "SELECT COUNT(*) FROM job WHERE coalesce(language_req[2],'x')='x';"          # 21

# --- BARE element in WHERE: were REFUSED at prepare; must now read the
#     real element and match the engine (trailing-byte semantics and all) ---
check "SELECT COUNT(*) FROM job WHERE language_req[1] IS NULL;"                    # 21
check "SELECT COUNT(*) FROM job WHERE language_req[1] IS NOT NULL;"                # 10
check "SELECT COUNT(*) FROM job WHERE language_req[1] = 'English';"                # 0
check "SELECT COUNT(*) FROM job WHERE language_req[1] LIKE 'English%';"            # 6
check "SELECT COUNT(*) FROM job WHERE language_req[2] > 'A';"                      # 10
check "SELECT COUNT(*) FROM job WHERE language_req[1] || '' = 'English';"          # 0
check "SELECT job_code FROM job WHERE language_req[1] IS NOT NULL ORDER BY job_code;"

# --- projection of the element under a NATURAL-SCAN filter: were all
#     NULL while the rowset was right; must now read the real element ---
check "SELECT job_code, language_req[1] FROM job WHERE job_grade=4;"
check "SELECT language_req[1] FROM job WHERE job_grade=4;"
check "SELECT job_code, language_req[1] FROM job WHERE job_grade>=1;"
check "SELECT language_req[1] FROM job WHERE max_salary>0 AND job_grade=4;"

# --- out-of-bounds / zero subscript: the engine RAISES; fire-crab must
#     raise the identical message, in the projection AND the predicate ---
check "SELECT language_req[9] FROM job;"
check "SELECT language_req[0] FROM job;"
check "SELECT COUNT(*) FROM job WHERE language_req[9] IS NULL;"

# --- controls that were already correct and must stay correct ---
check "SELECT language_req[1] FROM job;"
check "SELECT COUNT(language_req[1]) FROM job;"
check "SELECT job_code, language_req[1] FROM job WHERE job_code='Eng';"            # index path
check "SELECT language_req[1], COUNT(*) FROM job GROUP BY language_req[1];"
check "SELECT DISTINCT language_req[1] FROM job ORDER BY 1;"
check "SELECT language_req[1] FROM job ORDER BY language_req[1];"

echo "ran $ran checks"
[ $fail -eq 0 ] && echo "PASS wherearr" || echo "FAIL wherearr"
exit $fail
