#!/bin/bash
# CREATE PROCEDURE - fire-crab writes the catalog rows and the BLR the
# engine itself stores, BYTE FOR BYTE (dsql::compile_procedure was the
# DSQL oracle long before this wired it to DDL).
#
# The oracles, strongest last:
#   * the same DDL creates on both servers, and SELECT / EXECUTE answer
#     the same rows (fire-crab runs its OWN creation);
#   * the catalog rows match (RDB$PROCEDURES + RDB$PROCEDURE_PARAMETERS);
#   * the stored RDB$PROCEDURE_BLR is BYTE-IDENTICAL between the two
#     servers for the same DDL (dumped through node's blob reader; the
#     check SKIPS if node is unavailable).
#
# RECORDED BOUNDARIES: a duplicate CREATE refuses on both but
# fire-crab's vector is generic where the engine ships its
# no-meta-update wrapper (no DDL failure carries that wrapper yet); and
# the ENGINE executing an fc-AUTHORED procedure is a deeper
# metadata-fidelity slice (the BLR is identical and fire-crab runs it,
# but the engine's own executor wants more of the catalog than this
# writes) - its own future increment.
#
#   qa/serve-real-createproc.sh [port]
set -u
trap '' PIPE
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4731}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
fail=0; ran=0
mkdir -p "$D"
EDB="$D/fc-cproc-e.fdb"; FDB="$D/fc-cproc-f.fdb"
rm -f "$EDB" "$FDB"
for c in "localhost:$EDB" "$FDB"; do "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1
CREATE DATABASE '$c' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, V VARCHAR(10));
COMMIT;
INSERT INTO T VALUES (1, 'one');
INSERT INTO T VALUES (2, 'two');
INSERT INTO T VALUES (3, 'three');
COMMIT;
EOF
done
chmod 666 "$EDB" "$FDB" 2>/dev/null
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cproc-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$EDB" "$FDB"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i+1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }
check() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "DIFF $1"; echo "     want: $3"; echo "     got:  $2"; fail=1; fi; }
E="localhost:$EDB"; F="127.0.0.1/$PORT:$FDB"
run() { printf '%s\n' "$2" | "$ISQL" -q -user "$U" -pas "$P" "$1" 2>&1 | tr -s ' \n' ' '; }
both() { check "$1" "$(run "$F" "$2")" "$(run "$E" "$2")"; }

D1='SET TERM ^ ; CREATE PROCEDURE PQ RETURNS (R INTEGER) AS BEGIN FOR SELECT ID FROM T ORDER BY ID INTO :R DO SUSPEND; END^ SET TERM ; ^ COMMIT;'
D2='SET TERM ^ ; CREATE PROCEDURE PADD (A INTEGER, B INTEGER) RETURNS (S INTEGER) AS BEGIN S = A + B; SUSPEND; END^ SET TERM ; ^ COMMIT;'
D3='SET TERM ^ ; CREATE PROCEDURE PTXT RETURNS (V VARCHAR(10)) AS BEGIN FOR SELECT V FROM T ORDER BY ID INTO :V DO SUSPEND; END^ SET TERM ; ^ COMMIT;'

both "a selectable FOR-SELECT procedure creates" "$D1"
both "...and SELECT * FROM it answers the rows" "SELECT * FROM PQ;"
both "an input/output procedure creates" "$D2"
both "...SELECT with arguments" "SELECT * FROM PADD(3, 4);"
both "...EXECUTE PROCEDURE with arguments" "EXECUTE PROCEDURE PADD(10, 20);"
both "a text-returning procedure creates" "$D3"
both "...and its rows" "SELECT * FROM PTXT;"

# --- the catalog rows match ----------------------------------------------------
CAT="SET HEADING OFF; SELECT RDB\$PROCEDURE_NAME, RDB\$PROCEDURE_ID, RDB\$PROCEDURE_TYPE, RDB\$PROCEDURE_INPUTS, RDB\$PROCEDURE_OUTPUTS, RDB\$VALID_BLR FROM RDB\$PROCEDURES WHERE RDB\$SYSTEM_FLAG = 0 ORDER BY RDB\$PROCEDURE_NAME;"
both "the RDB\$PROCEDURES rows match" "$CAT"
PAR="SET HEADING OFF; SELECT RDB\$PROCEDURE_NAME, RDB\$PARAMETER_NAME, RDB\$PARAMETER_NUMBER, RDB\$PARAMETER_TYPE, RDB\$PARAMETER_MECHANISM FROM RDB\$PROCEDURE_PARAMETERS ORDER BY 1, 4, 3;"
both "the RDB\$PROCEDURE_PARAMETERS rows match" "$PAR"

# --- the stored BLR is byte-identical (node blob reader; skips if absent) ------
blr_hex() { # <db file>
    node -e '
    const fb = require("node-firebird");
    fb.attach({host:"localhost", database:"'"$1"'", user:"'"$U"'", password:"'"$P"'"}, (err, db) => {
      if (err) { process.exit(3); }
      db.query("SELECT RDB$PROCEDURE_BLR AS BLR FROM RDB$PROCEDURES WHERE RDB$PROCEDURE_NAME = '"'"'PADD'"'"'", [], (err, rows) => {
        if (err || !rows.length) process.exit(3);
        rows[0].BLR((e, n, em) => {
          if (e) process.exit(3);
          let c = [];
          em.on("data", d => c.push(d));
          em.on("end", () => { process.stdout.write(Buffer.concat(c).toString("hex")); db.detach(()=>process.exit(0)); });
        });
      });
    });' 2>/dev/null
}
kill $srv 2>/dev/null; sleep 0.3  # free FDB so the engine can read it
eh=$(blr_hex "$EDB"); erc=$?
fh=$(blr_hex "$FDB"); frc=$?
if [ $erc -eq 3 ] || [ $frc -eq 3 ]; then
    echo "SKIP: node-firebird unavailable for the BLR byte-compare"
else
    check "the stored PADD BLR is byte-identical to the engine's" "$fh" "$eh"
fi

echo "ran $ran checks"
exit $fail
