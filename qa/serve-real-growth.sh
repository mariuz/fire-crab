#!/bin/bash
# THE FILE GROWS THE ENGINE'S WAY: four walls a fire-crab-written
# database used to hit, each the engine's own allocation law.
#
#   * a relation's SECOND POINTER PAGE (dpm.epp extend_relation):
#     ppg_eof moved, ppg_next linked, an RDB$PAGES row the engine's
#     DPM_scan_pages needs to find it at all (before: "pointer page
#     full", ~13 MB per table);
#   * the SCN INVENTORY PAGE at every pagesPerSCN (2041 at 8K, ods.h:
#     787): reserved by the allocator, and every page's era stamped in
#     ITS slot on the SCN page that owns it - `nbackup -B <n>` reads
#     those slots to choose an increment's pages, so a slot stamped on
#     the wrong page is a SILENT LOSS in an engine incremental (before:
#     page 2041 handed out as data, ~16 MB);
#   * the SECOND TIP (tra.cpp TRA_extend_tip): minted by the first id
#     of its range, linked from the prior tip_next, catalogued in
#     RDB$PAGES (before: "transaction id beyond the TIP chain", 32688
#     ids at 8K);
#   * the SECOND PIP (pag.cpp PAG_allocate_pages): the last bit of a
#     PIP is the next PIP's home, formatted all-free (before: "first
#     PIP exhausted", ~510 MB).
#
# Each wall is crossed BY FIRE-CRAB and read back by the ENGINE (count,
# gfix -v -full, a write of its own on the new structure), and the
# engine-grown twin is read and extended by fire-crab. Coverage checks
# read the page types at the predicted page numbers, so "wired in but
# never reached" cannot pass.
#
#   qa/serve-real-growth.sh [port]      GROWTH_SKIP_PIP=1 skips the 510 MB cell

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"; GSTAT="${GSTAT:-gstat}"; NBACKUP="${NBACKUP:-nbackup}"
PORT="${1:-4790}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
DBA="$D/fc-growth-a.fdb"; DBB="$D/fc-growth-b.fdb"; DBC="$D/fc-growth-c.fdb"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH
PS=8192; PER_SCN=2041; PER_PIP=65312; PER_TIP=32688

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP python3 not found"; exit 0; }
mkdir -p "$D"
fail=0; ran=0
cleanup() { kill $srv 2>/dev/null; rm -f "$DBA" "$DBB" "$DBC" "$D"/fc-growth-*.nbk "$D"/fc-growth-r.fdb; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"/tmp/fc-serve-growth-$PORT.log" 2>&1 &
srv=$!
trap cleanup EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }

check() { ran=$((ran + 1)); if [ "$2" = "$3" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     got:  [$2]"; echo "     want: [$3]"; fail=1; fi; }
# the engine over TCP (the transport held fixed), fire-crab over TCP
eng() { printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "127.0.0.1/${FC_REAL_PORT:-3050}:$1" 2>&1 | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }
fc()  { printf 'SET HEADING OFF;\n%s\n' "$2" | "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "127.0.0.1/$PORT:$1" 2>&1 | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }
ptype() { xxd -s $(( $2 * PS )) -l 1 -p "$1" 2>/dev/null; }
nexttx() { "$GSTAT" -h -user "$U" -pas "$P" "$1" 2>/dev/null | awk '/Next transaction/ {print $3}'; }
# PIP 0 as the engine leaves it: FREE bits left (set = free), and
# whether its LAST bit - the next PIP's home - is among them. (pip_used
# is not the allocation mark: the engine's ensureDiskSpace raises it to
# the size it pre-extended the file to.)
pip0() { python3 -c "
import struct; b=open('$1','rb').read($PS*2)[$PS:]
bits=b[28:28+$PER_PIP//8]; free=sum(bin(x).count('1') for x in bits)
print(free, (b[28+($PER_PIP-1)//8]>>(($PER_PIP-1)%8))&1)"; }
gfixok() { ran=$((ran + 1)); g=$("$GFIX" -v -full -user "$U" -pas "$P" "$2" 2>&1)
    if [ -z "$g" ]; then echo "OK   $1"; else echo "DIFF $1: $g"; fail=1; fi; }
mkdb() { rm -f "$1"; "$ISQL" -q -b -ch NONE -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || { echo "FAIL scratch $1"; exit 1; }
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE $PS;
CREATE TABLE G (ID INTEGER, V VARCHAR(3900) CHARACTER SET NONE);
CREATE TABLE T2 (ID INTEGER);
CREATE TABLE P (ID INTEGER, V VARCHAR(7900) CHARACTER SET NONE);
COMMIT;
EOF
    chmod 666 "$1"; "$GFIX" -write async -user "$U" -pas "$P" "$1" 2>/dev/null; }

# node: N wide rows in ONE transaction (TABLE, N0..N1, LEN)
rows() { FC_DB="$1" FC_PORT="$PORT" FC_T="$2" FC_N0="$3" FC_N1="$4" FC_LEN="$5" timeout 600 node -e '
  process.on("uncaughtException", e => { console.log("CONN_ERR " + e.message); process.exit(1); });
  const F=require("node-firebird"); const E=process.env;
  const v=require("crypto").randomBytes(Math.ceil(+E.FC_LEN/2)).toString("hex").slice(0,+E.FC_LEN);
  F.attach({host:"127.0.0.1",port:+E.FC_PORT,database:E.FC_DB,user:"SYSDBA",password:"masterkey",encoding:"NONE"},(e,d)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    d.transaction(F.ISOLATION_READ_COMMITTED,(e,tr)=>{
      let i=+E.FC_N0; const step=()=>{ if(i>=+E.FC_N1){ tr.commit(()=>{console.log("OK");d.detach();}); return; }
        tr.query("INSERT INTO "+E.FC_T+" (ID, V) VALUES (?, ?)",[i,v],(e)=>{ if(e){console.log("ERR "+i+" "+e.message);process.exit(1);} i++; step(); }); };
      step(); });});' 2>/dev/null; }
# node: N single-row TRANSACTIONS on T2 (N0..N1) - each its own id
txs() { FC_DB="$1" FC_PORT="$PORT" FC_N0="$2" FC_N1="$3" timeout 600 node -e '
  process.on("uncaughtException", e => { console.log("CONN_ERR " + e.message); process.exit(1); });
  const F=require("node-firebird"); const E=process.env;
  F.attach({host:"127.0.0.1",port:+E.FC_PORT,database:E.FC_DB,user:"SYSDBA",password:"masterkey",encoding:"NONE"},(e,d)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    let i=+E.FC_N0; const step=()=>{ if(i>=+E.FC_N1){ console.log("OK"); d.detach(); return; }
      d.transaction(F.ISOLATION_READ_COMMITTED,(e,tr)=>{ if(e){console.log("ERR tx "+i);process.exit(1);}
        tr.query("INSERT INTO T2 (ID) VALUES (?)",[i],(e)=>{ if(e){console.log("ERR "+i+" "+e.message);process.exit(1);}
          tr.commit((e)=>{ if(e){console.log("ERR commit "+i);process.exit(1);} i++; step(); }); }); }); };
    step(); });' 2>/dev/null; }
# the engine burns ids: one autonomous transaction per row
burn() { printf 'SET TERM ^;\nEXECUTE BLOCK AS DECLARE I INTEGER = %s; BEGIN WHILE (I < %s) DO BEGIN IN AUTONOMOUS TRANSACTION DO INSERT INTO T2 VALUES (:I); I = I + 1; END END^\nSET TERM ;^\nCOMMIT;\n' "$2" "$3" |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/${FC_REAL_PORT:-3050}:$1" >/dev/null 2>&1; }
# the engine grows a table with INCOMPRESSIBLE rows (RLE would fold a
# constant into nothing and the file would never reach the wall)
grow_eng() { printf 'SET TERM ^;\nEXECUTE BLOCK AS DECLARE I INTEGER = %s; DECLARE S VARCHAR(%s) CHARACTER SET NONE; BEGIN S = LPAD('"''"', %s, UUID_TO_CHAR(GEN_UUID())); WHILE (I < %s) DO BEGIN INSERT INTO %s VALUES (:I, :S); I = I + 1; END END^\nSET TERM ;^\nCOMMIT;\n' "$3" "$5" "$5" "$4" "$2" |
    "$ISQL" -q -b -user "$U" -pas "$P" "127.0.0.1/${FC_REAL_PORT:-3050}:$1" >/dev/null 2>&1; }

# ======================================================================
# A. FIRE-CRAB GROWS: pointer page, SCN page, nbackup chain, TIP
# ======================================================================
mkdb "$DBA"
check "A1 fc writes 5000 wide rows (1630 data pages is the first pointer page's capacity)" \
    "$(rows "$DBA" G 0 5000 3900)" "OK"
check "A1 fc counts them" "$(fc "$DBA" 'SELECT COUNT(*), SUM(ID) FROM G;')" "5000 12497500"
check "A1 COVERAGE page 2041 is an SCN inventory page (type 10)" "$(ptype "$DBA" 2041)" "0a"
check "A1 COVERAGE the second pointer page is catalogued (RDB\$PAGES seq 1, type 4)" \
    "$(eng "$DBA" "SELECT COUNT(*) FROM RDB\$PAGES PG JOIN RDB\$RELATIONS R ON R.RDB\$RELATION_ID = PG.RDB\$RELATION_ID WHERE R.RDB\$RELATION_NAME = 'G' AND PG.RDB\$PAGE_TYPE = 4 AND PG.RDB\$PAGE_SEQUENCE = 1;")" "1"
check "A1 the ENGINE reads every row through the chained pointer pages" \
    "$(eng "$DBA" 'SELECT COUNT(*), SUM(ID), MAX(ID) FROM G;')" "5000 12497500 4999"
gfixok "A1 gfix -v -full: page SCNs match their slots, nothing orphaned" "$DBA"

# the silent-loss cell: the engine's level-0, fc's late pages (all past
# page 2041, stamped on SCN page 1), the engine's level-1, the restore
rm -f "$D/fc-growth-0.nbk" "$D/fc-growth-1.nbk" "$D/fc-growth-r.fdb"
"$NBACKUP" -B 0 "$DBA" "$D/fc-growth-0.nbk" -user "$U" -password "$P" >/dev/null 2>&1
check "A2 fc writes 500 more rows after the engine's level-0" "$(rows "$DBA" G 5000 5500 3900)" "OK"
"$NBACKUP" -B 1 "$DBA" "$D/fc-growth-1.nbk" -user "$U" -password "$P" >/dev/null 2>&1
"$NBACKUP" -R "$D/fc-growth-r.fdb" "$D/fc-growth-0.nbk" "$D/fc-growth-1.nbk" >/dev/null 2>&1
chmod 666 "$D/fc-growth-r.fdb" 2>/dev/null
check "A2 the engine's level-1 carried fc's late pages (restore counts them)" \
    "$(eng "$D/fc-growth-r.fdb" 'SELECT COUNT(*), MAX(ID) FROM G;')" "5500 5499"
gfixok "A2 gfix -v -full on the restored chain" "$D/fc-growth-r.fdb"

# the TIP wall: the engine burns ids up to just below it, fc crosses
nt=$(nexttx "$DBA"); burn "$DBA" 0 $(( PER_TIP - 200 - nt ))
nt=$(nexttx "$DBA")
ran=$((ran + 1)); if [ "${nt:-0}" -lt "$PER_TIP" ] && [ "${nt:-0}" -gt $(( PER_TIP - 400 )) ]; then
    echo "OK   A3 precondition: Next transaction $nt sits just below $PER_TIP"; else
    echo "DIFF A3 precondition: Next transaction [$nt]"; fail=1; fi
check "A3 fc runs 400 transactions across the TIP boundary" "$(txs "$DBA" 100000 100400)" "OK"
nt=$(nexttx "$DBA")
ran=$((ran + 1)); if [ "${nt:-0}" -gt "$PER_TIP" ]; then echo "OK   A3 COVERAGE Next transaction $nt is on TIP 1"; else
    echo "DIFF A3 Next transaction [$nt] never crossed $PER_TIP"; fail=1; fi
check "A3 COVERAGE TIP 1 is catalogued (RDB\$PAGES relation 0, type 3, seq 1)" \
    "$(eng "$DBA" 'SELECT COUNT(*) FROM RDB$PAGES WHERE RDB$RELATION_ID = 0 AND RDB$PAGE_TYPE = 3 AND RDB$PAGE_SEQUENCE = 1;')" "1"
tip1=$(eng "$DBA" 'SELECT RDB$PAGE_NUMBER FROM RDB$PAGES WHERE RDB$RELATION_ID = 0 AND RDB$PAGE_TYPE = 3 AND RDB$PAGE_SEQUENCE = 1;')
check "A3 COVERAGE ...and that page IS a TIP (type 3)" "$(ptype "$DBA" "${tip1:-0}")" "03"
c0=$(eng "$DBA" 'SELECT COUNT(*) FROM T2;')
check "A3 the ENGINE commits a transaction of its own on fc's TIP 1" \
    "$(eng "$DBA" 'INSERT INTO T2 VALUES (200000); COMMIT; SELECT COUNT(*), MAX(ID) FROM T2;')" "$(( c0 + 1 )) 200000"
check "A3 fc sees the engine's row" "$(fc "$DBA" 'SELECT MAX(ID) FROM T2;')" "200000"
gfixok "A3 gfix -v -full after both sides wrote on TIP 1" "$DBA"

# ======================================================================
# B. THE ENGINE GREW IT: fc reads and extends the engine's structures
# ======================================================================
mkdb "$DBB"
grow_eng "$DBB" G 0 5000 3900
burn "$DBB" 0 33000
check "B  COVERAGE the engine's file has its SCN page 1 and second pointer page" \
    "$(ptype "$DBB" 2041)|$(eng "$DBB" "SELECT COUNT(*) FROM RDB\$PAGES PG JOIN RDB\$RELATIONS R ON R.RDB\$RELATION_ID = PG.RDB\$RELATION_ID WHERE R.RDB\$RELATION_NAME = 'G' AND PG.RDB\$PAGE_SEQUENCE = 1;")|$(eng "$DBB" 'SELECT COUNT(*) FROM RDB$PAGES WHERE RDB$RELATION_ID = 0 AND RDB$PAGE_TYPE = 3 AND RDB$PAGE_SEQUENCE = 1;')" "0a|1|1"
check "B  fc reads the engine's grown table and its 33000 ids" \
    "$(fc "$DBB" 'SELECT COUNT(*), SUM(ID) FROM G; SELECT COUNT(*) FROM T2;')" "5000 12497500 33000"
check "B  fc extends the engine's second pointer page (500 rows past SCN page 1)" "$(rows "$DBB" G 5000 5500 3900)" "OK"
check "B  fc commits 50 transactions on the engine's TIP 1" "$(txs "$DBB" 100000 100050)" "OK"
check "B  the ENGINE reads fc's extension" \
    "$(eng "$DBB" 'SELECT COUNT(*), SUM(ID), MAX(ID) FROM G; SELECT COUNT(*), MAX(ID) FROM T2;')" "5500 15122250 5499 33050 100049"
gfixok "B  gfix -v -full on the engine's file after fc's extension" "$DBB"

# ======================================================================
# C. THE SECOND PIP (510 MB): fc mints it, the engine allocates from it
# ======================================================================
if [ "${GROWTH_SKIP_PIP:-0}" = "1" ]; then
    echo "SKIP C  GROWTH_SKIP_PIP=1 (the 510 MB cell)"
else
    mkdb "$DBC"
    # the engine fills PIP 0 to within a few hundred pages of its last
    # bit (it allocates in extents, so the row count is not the page
    # count - the fixture is sized off the PIP itself)
    grow_eng "$DBC" P 0 64000 7900
    read free freebit <<<"$(pip0 "$DBC")"
    ran=$((ran + 1)); if [ "${free:-0}" -gt 0 ] && [ "${free:-0}" -lt 3000 ] && [ "${freebit:-0}" = "1" ]; then
        echo "OK   C  precondition: PIP 0 has $free free pages left, its last bit among them"; else
        echo "DIFF C  precondition: free [$free] last-bit-free [$freebit]"; fail=1; fi
    n=$(( free + 300 ))
    check "C  fc writes $n one-page rows across the PIP boundary" "$(rows "$DBC" P 64000 $(( 64000 + n )) 7900)" "OK"
    check "C  COVERAGE page 65311 is PIP 1 (type 2) and 65312 SCN page 32 (type 10)" \
        "$(ptype "$DBC" 65311)|$(ptype "$DBC" 65312)" "02|0a"
    read free freebit <<<"$(pip0 "$DBC")"
    check "C  COVERAGE PIP 0 is spent (no free page, last bit taken)" "$free|$freebit" "0|0"
    p1=$(python3 -c "
import struct; b=open('$DBC','rb').read()[65311*$PS:65312*$PS]; print(struct.unpack_from('<I',b,24)[0] > 0)")
    check "C  COVERAGE PIP 1 has handed out pages" "$p1" "True"
    check "C  the ENGINE counts every row" "$(eng "$DBC" 'SELECT COUNT(*), MAX(ID) FROM P;')" "$(( 64000 + n )) $(( 64000 + n - 1 ))"
    check "C  the ENGINE allocates from fc's PIP 1" \
        "$(eng "$DBC" "INSERT INTO P VALUES (900000, LPAD('', 7900, 'z')); COMMIT; SELECT COUNT(*), MAX(ID) FROM P;")" "$(( 64000 + n + 1 )) 900000"
    check "C  fc reads the engine's row" "$(fc "$DBC" 'SELECT COUNT(*), MAX(ID) FROM P;')" "$(( 64000 + n + 1 )) 900000"
    gfixok "C  gfix -v -full over both PIPs" "$DBC"
fi

echo "$ran checks, fail=$fail"
exit $fail
