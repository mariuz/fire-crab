#!/bin/bash
# TRANSLITERATION: a WIN1252 (or ISO8859_1) column's bytes are not UTF-8,
# and every seam that touches them must speak its codepage.
#
# Before the codepage tables, fire-crab read a stored 0xE9 through
# String::from_utf8_lossy - the replacement character DESTROYED the
# value ('café' read as 'caf<?>', OCTET_LENGTH counted the replacement's
# three bytes), the write path stored UTF-8 bytes the engine then read
# as mojibake, and an index key built from those bytes landed elsewhere
# in the tree. The tables (ods::intl, WIN1252 + ISO8859_1, bijective on
# all 256 bytes) close all of it at once:
#
#   DECODE   a stored byte becomes its codepage's character
#   STORE    text becomes the codepage's bytes - the bytes the ENGINE
#            writes and reads; a character with no image refuses where
#            the engine raises 22018 (both reject, the row never lands)
#   KEYS     index keys are the codepage bytes (KeySeg.charset), so a
#            band finds what the engine's own keys hold
#   WIRE     a single-byte ATTACHMENT receives the codepage bytes back
#            (the UTF8 attachment receives UTF-8, as always)
#   LENGTHS  OCTET_LENGTH counts the COLUMN's bytes (café = 4), not the
#            decoded text's UTF-8 bytes (5)
#
# Twin databases: the engine populates both identically; fire-crab
# serves one over the wire, isql reads the other; every answer must
# match. Then fire-crab WRITES, and the ENGINE reads the file - the
# corruption direction, checked with the engine's own tools.
#
#   qa/serve-real-xlit.sh [port]

set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GFIX="${GFIX:-gfix}"
PORT="${1:-4775}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
RE="$D/fc-xlit-re.fdb"; FC="$D/fc-xlit-fc.fdb"
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH

command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"
fail=0; ran=0

mkdb() {
    rm -f "$1"
    "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE XL (ID INTEGER, W VARCHAR(10) CHARACTER SET WIN1252,
                 L VARCHAR(10) CHARACTER SET ISO8859_1);
COMMIT;
INSERT INTO XL VALUES (1, 'café', 'café');
INSERT INTO XL VALUES (2, 'für', 'für');
INSERT INTO XL VALUES (3, '€uro', 'ascii');
COMMIT;
CREATE TABLE XC (ID INTEGER, C VARCHAR(10) CHARACTER SET WIN1250,
                 Y VARCHAR(10) CHARACTER SET WIN1251,
                 T VARCHAR(10) CHARACTER SET ISO8859_2);
CREATE TABLE XU (ID INTEGER, S VARCHAR(10) CHARACTER SET UTF8);
COMMIT;
INSERT INTO XC VALUES (1, 'řeka', 'река', 'řeka');
INSERT INTO XC VALUES (2, 'żółw', 'мышь', 'żółw');
INSERT INTO XC VALUES (3, 'ascii', 'ascii', 'ascii');
COMMIT;
EOF
    chmod 666 "$1"
}
mkdb "$RE" || { echo "FAIL scratch RE"; exit 1; }
mkdb "$FC" || { echo "FAIL scratch FC"; exit 1; }

# every high byte of the generated-table sets, stored VERBATIM via hex
# literals through a NONE attachment (a NONE source assigns bytes as-is,
# the same technique that generated the tables off the engine)
BSQL=$D/xlit-bytes.sql
python3 - "$BSQL" <<'PYEOF'
import sys
out = open(sys.argv[1], 'w')
for t, cs in [("B1250", "WIN1250"), ("B1251", "WIN1251"), ("B8859", "ISO8859_2")]:
    out.write(f"CREATE TABLE {t} (ID INTEGER, S VARCHAR(1) CHARACTER SET {cs});\n")
out.write("COMMIT;\n")
for t in ("B1250", "B1251", "B8859"):
    for b in range(0x80, 0x100):
        out.write(f"INSERT INTO {t} VALUES ({b}, x'{b:02X}');\n")
out.write("COMMIT;\n")
PYEOF
"$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "$RE" < "$BSQL" >/dev/null 2>&1 || { echo "FAIL bytes RE"; exit 1; }
"$ISQL" -q -b -ch NONE -user "$U" -pas "$P" "$FC" < "$BSQL" >/dev/null 2>&1 || { echo "FAIL bytes FC"; exit 1; }

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-xlit.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire not running - port $PORT taken?"; exit 1; }

node_q() { FC_DB="$FC" FC_PORT="$PORT" FC_Q="$1" timeout 30 node -e '
  process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
            user:"SYSDBA",password:"masterkey",encoding:"UTF8"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,(e2,r)=>{
      if(e2){console.log("ERR");db.detach();process.exit(0);}
      if(Array.isArray(r)) for(const row of r)
        console.log(Object.values(row).map(v=>v===null?"<null>":String(v).replace(/\s+$/,"")).join("|"));
      else console.log("OK");
      db.detach();process.exit(0);});});' 2>/dev/null
}
isql_q() { # <db> <sql>
    printf 'SET HEADING OFF;\n%s;\n' "$2" |
        "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$1" 2>&1 |
        sed 's/^[[:space:]]*//; s/[[:space:]]\{1,\}/|/g; s/|$//' | grep -v '^$'
}
twin() { # <label> <sql> - fc over the wire vs the engine, same rows
    ran=$((ran + 1))
    a=$(node_q "$2")
    b=$(isql_q "$RE" "$2")
    if [ "$a" = "$b" ]; then
        echo "OK   $1"
    else
        echo "DIFF $1"
        echo "     fcwire: [$a]"
        echo "     engine: [$b]"
        fail=1
    fi
}

# --- 1. reading the engine's rows --------------------------------------
twin "a WIN1252 column decodes by its codepage" "SELECT ID, W FROM XL ORDER BY ID"
twin "an ISO8859_1 column too" "SELECT ID, L FROM XL ORDER BY ID"
twin "OCTET_LENGTH counts the COLUMN's bytes, CHAR_LENGTH its characters" \
     "SELECT ID, OCTET_LENGTH(W) AS OW, CHAR_LENGTH(W) AS CW, OCTET_LENGTH(L) AS OL FROM XL ORDER BY ID"
twin "a WHERE literal meets the column's characters" \
     "SELECT ID FROM XL WHERE W = 'café'"
twin "... and the cp1252 punctuation row (the 0x80 block)" \
     "SELECT ID FROM XL WHERE W = '€uro'"
twin "LIKE walks characters, not bytes" \
     "SELECT ID FROM XL WHERE W LIKE 'f_r'"
twin "UPPER maps the accents" "SELECT ID, UPPER(W) FROM XL ORDER BY ID"

# --- 2. fire-crab WRITES, the ENGINE reads -----------------------------
ran=$((ran + 1))
r=$(node_q "INSERT INTO XL VALUES (4, 'garçon', 'Ähre')")
if [ "$r" = "OK" ]; then
    echo "OK   fc stores non-ASCII through a UTF8 attachment"
else
    echo "DIFF fc INSERT refused: [$r]"
    fail=1
fi
ran=$((ran + 1))
got=$(isql_q "$FC" "SELECT ID, W, L, OCTET_LENGTH(W) FROM XL WHERE ID = 4")
if [ "$got" = "4|garçon|Ähre|6" ]; then
    echo "OK   the ENGINE reads fc's row back - codepage bytes, 6 octets"
else
    echo "DIFF engine read of fc's row: [$got]"
    fail=1
fi
ran=$((ran + 1))
got=$(isql_q "$FC" "SELECT ID FROM XL WHERE W = 'garçon'")
if [ "$got" = "4" ]; then
    echo "OK   ... and finds it by value"
else
    echo "DIFF engine WHERE over fc's row: [$got]"
    fail=1
fi

# --- 3. the unmappable character ---------------------------------------
# the engine raises SQLSTATE 22018 (Cannot transliterate) at execute;
# fire-crab refuses at prepare - both reject, and the row never lands
ran=$((ran + 1))
r=$(node_q "INSERT INTO XL VALUES (9, '₹', 'x')")
e=$(printf "INSERT INTO XL VALUES (9, '₹', 'x');\n" | "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$RE" 2>&1 | grep -c "SQLSTATE = 22018")
if [ "$r" = "ERR" ] && [ "$e" -ge 1 ]; then
    echo "OK   an unmappable character: fc refuses, the engine raises 22018"
else
    echo "DIFF unmappable: fc [$r], engine 22018-count $e"
    fail=1
fi
ran=$((ran + 1))
a=$(node_q "SELECT COUNT(*) FROM XL WHERE ID = 9")
b=$(isql_q "$RE" "SELECT COUNT(*) FROM XL WHERE ID = 9")
if [ "$a" = "0" ] && [ "$b" = "0" ]; then
    echo "OK   ... and the row landed on NEITHER side"
else
    echo "DIFF unmappable row count: fc [$a] engine [$b]"
    fail=1
fi

# --- 4. a single-byte ATTACHMENT gets the codepage bytes back ----------
# reading the fc-SERVED file through isql -ch WIN1252: the wire encode
# re-spells the value in the attachment's codepage, which for a
# same-charset column is the STORED bytes - compared against the
# engine's own WIN1252-attachment answer on the twin
ran=$((ran + 1))
a=$(printf 'SET HEADING OFF;\nSELECT ID, W, OCTET_LENGTH(W) AS OW FROM XL WHERE ID <= 3 ORDER BY ID;\n' |
    "$ISQL" -q -b -ch WIN1252 -user "$U" -pas "$P" "$FC" 2>&1 | md5sum | cut -d' ' -f1)
b=$(printf 'SET HEADING OFF;\nSELECT ID, W, OCTET_LENGTH(W) AS OW FROM XL WHERE ID <= 3 ORDER BY ID;\n' |
    "$ISQL" -q -b -ch WIN1252 -user "$U" -pas "$P" "$RE" 2>&1 | md5sum | cut -d' ' -f1)
if [ "$a" = "$b" ]; then
    echo "OK   a WIN1252 attachment reads identical bytes from both files"
else
    echo "DIFF WIN1252-attachment reads differ between the twins"
    fail=1
fi

# --- 5. an INDEXED WIN1252 column: the INTL itype ----------------------
# the irtd stamps `ttype + idx_offset_intl_range` (32831 + 53 for the
# default WIN1252 collation); its key is the codepage bytes with
# trailing blanks stripped, the empty value keyed [00] - measured off a
# live engine index. fire-crab now builds the same keys, so DML
# maintains the tree and the ENGINE's own index scans find the rows.
"$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$FC" <<EOF >/dev/null 2>&1
CREATE TABLE KI (ID INTEGER, W VARCHAR(10) CHARACTER SET WIN1252);
CREATE INDEX IDX_KI_W ON KI (W);
COMMIT;
INSERT INTO KI VALUES (1, 'café');
COMMIT;
EOF
ran=$((ran + 1))
r=$(node_q "INSERT INTO KI VALUES (2, 'süß')")
r2=$(node_q "UPDATE KI SET W = 'çedille' WHERE ID = 1")
if [ "$r" = "OK" ] && [ "$r2" = "OK" ]; then
    echo "OK   fc INSERTs and UPDATEs through the INTL-itype index"
else
    echo "DIFF INTL-index DML: insert [$r] update [$r2]"
    fail=1
fi
ran=$((ran + 1))
got=$(isql_q "$FC" "SELECT ID FROM KI WHERE W = 'süß'")$(isql_q "$FC" "SELECT ID FROM KI WHERE W = 'çedille'")
if [ "$got" = "21" ]; then
    echo "OK   the ENGINE finds both fc-keyed rows through ITS index"
else
    echo "DIFF engine index lookups over fc's keys: [$got]"
    fail=1
fi
ran=$((ran + 1))
a=$(node_q "SELECT ID FROM KI WHERE W = 'süß'")
if [ "$a" = "2" ]; then
    echo "OK   ... and fc's own retrieval bands the codepage key"
else
    echo "DIFF fc indexed retrieval: [$a]"
    fail=1
fi

# --- 6. NONE is a BYTE CARRIER -----------------------------------------
# a NONE column holds bytes with no charset semantics: the engine never
# transliterates them (a stored 0xE9 reaches a UTF8 attachment as the
# one byte 0xE9, measured), CHAR_LENGTH counts bytes, and comparison is
# byte-wise - a UTF-8 literal's C3 A9 pair matches a C3 A9 row and NOT a
# raw E9 one. fire-crab carries such values one char per byte (the
# Latin-1 carrier), which round-trips every byte the old lossy-UTF8 read
# destroyed. The raw-byte row comes from a WIN1252 -> NONE copy: the
# engine copies the codepage bytes verbatim.
"$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$FC" <<'EOF' >/dev/null 2>&1
CREATE TABLE NB (ID INTEGER, S VARCHAR(10) CHARACTER SET NONE);
CREATE INDEX IDX_NB_S ON NB (S);
COMMIT;
INSERT INTO NB VALUES (1, 'café');
INSERT INTO NB SELECT 2, W FROM XL WHERE ID = 1;
COMMIT;
EOF
ran=$((ran + 1))
a=$(node_q "SELECT ID, OCTET_LENGTH(S) AS O, CHAR_LENGTH(S) AS C FROM NB ORDER BY ID")
b=$(isql_q "$FC" "SELECT ID, OCTET_LENGTH(S) AS O, CHAR_LENGTH(S) AS C FROM NB ORDER BY ID")
if [ "$a" = "$b" ] && [ -n "$a" ]; then
    echo "OK   NONE lengths count BYTES on both sides ($a)"
else
    echo "DIFF NONE lengths: fc [$a] engine [$b]"
    fail=1
fi
ran=$((ran + 1))
a=$(node_q "SELECT ID FROM NB WHERE S = 'café'")
b=$(isql_q "$FC" "SELECT ID FROM NB WHERE S = 'café'")
if [ "$a" = "1" ] && [ "$b" = "1" ]; then
    echo "OK   the byte compare: the UTF-8 literal matches its own bytes, not the raw-byte row"
else
    echo "DIFF NONE byte compare: fc [$a] engine [$b]"
    fail=1
fi
ran=$((ran + 1))
r=$(node_q "INSERT INTO NB VALUES (3, 'naïve')")
got=$(isql_q "$FC" "SELECT ID FROM NB WHERE S = 'naïve'")
if [ "$r" = "OK" ] && [ "$got" = "3" ]; then
    echo "OK   fc writes NONE bytes the engine finds - index keys included"
else
    echo "DIFF NONE write-back: insert [$r], engine find [$got]"
    fail=1
fi

# cross-charset INSERT..SELECT: ~~recorded divergence~~ TAKEN. The
# engine's assignment law (probed): a tabled source writes its
# CODEPAGE bytes into a NONE column ('café' from WIN1252 lands 4
# bytes, not UTF-8's 5; 'řeka' from WIN1250 lands 4, not 5), a NONE
# source copies bytes VERBATIM into any single-byte destination, and
# into UTF8 only when the bytes are valid there. fire-crab now binds
# a selected text value as a charset-tagged parameter
# (WireParam::TextCs) so the store can follow that law.
ran=$((ran + 1))
r=$(node_q "INSERT INTO NB SELECT 4, W FROM XL WHERE ID = 1")
got=$(isql_q "$FC" "SELECT ID, OCTET_LENGTH(S) FROM NB WHERE ID = 4")
if [ "$r" = "OK" ] && [ "$got" = "4|4" ]; then
    echo "OK   WIN1252 -> NONE copies the codepage's 4 bytes (not UTF-8's 5)"
else
    echo "DIFF WIN1252 -> NONE: insert [$r], engine read [$got] (want 4|4)"
    fail=1
fi
ran=$((ran + 1))
r=$(node_q "INSERT INTO NB SELECT 5, C FROM XC WHERE ID = 1")
got=$(isql_q "$FC" "SELECT ID, OCTET_LENGTH(S) FROM NB WHERE ID = 5")
if [ "$r" = "OK" ] && [ "$got" = "5|4" ]; then
    echo "OK   WIN1250 -> NONE too ('řeka' is its 4 codepage bytes)"
else
    echo "DIFF WIN1250 -> NONE: insert [$r], engine read [$got] (want 5|4)"
    fail=1
fi

# --- 7. the GENERATED codepages: WIN1250, WIN1251, ISO8859_2 -----------
# three more tables in ods::intl, generated FROM the live engine (hex
# literals in, UNICODE_VAL out) rather than typed from a chart. Real
# words first, then every DEFINED printable byte of each set compared
# fc-served vs engine. Excluded from the byte sweep: the codepage HOLES
# (0x81/83/88/90/98 in 1250, 0x98 in 1251 - the engine transliterates
# those to U+0000, fc keeps the C1 carrier; recorded divergence), NBSP
# 0xA0 and SHY 0xAD (whitespace normalization would eat them), and the
# 8859_2 C1 control row (raw controls break line-based comparison).
twin "a WIN1250 column decodes by its codepage" "SELECT ID, C FROM XC ORDER BY ID"
twin "a WIN1251 column speaks Cyrillic" "SELECT ID, Y FROM XC ORDER BY ID"
twin "an ISO8859_2 column speaks Latin-2" "SELECT ID, T FROM XC ORDER BY ID"
twin "lengths count the codepage's single bytes" \
     "SELECT ID, OCTET_LENGTH(C) AS OC, CHAR_LENGTH(Y) AS CY, OCTET_LENGTH(T) AS OT FROM XC ORDER BY ID"
twin "a WHERE literal meets WIN1250 characters" "SELECT ID FROM XC WHERE C = 'řeka'"
twin "... and Cyrillic ones" "SELECT ID FROM XC WHERE Y = 'мышь'"
twin "LIKE walks WIN1250 characters, not bytes" "SELECT ID FROM XC WHERE C LIKE 'ř_ka'"
twin "UPPER maps the Latin-2 and Cyrillic letters" \
     "SELECT ID, UPPER(C) AS UC, UPPER(Y) AS UY FROM XC ORDER BY ID"
twin "every defined WIN1250 punctuation byte (the 0x80 row, holes aside)" \
     "SELECT ID, S FROM B1250 WHERE ID BETWEEN 128 AND 159 AND ID NOT IN (129,131,136,144,152) ORDER BY ID"
twin "every WIN1250 letter byte (0xA1..0xFF)" \
     "SELECT ID, S FROM B1250 WHERE ID >= 161 AND ID <> 173 ORDER BY ID"
twin "every defined WIN1251 punctuation byte" \
     "SELECT ID, S FROM B1251 WHERE ID BETWEEN 128 AND 159 AND ID <> 152 ORDER BY ID"
twin "every WIN1251 letter byte (0xA1..0xFF)" \
     "SELECT ID, S FROM B1251 WHERE ID >= 161 AND ID <> 173 ORDER BY ID"
twin "every ISO8859_2 letter byte (0xA1..0xFF)" \
     "SELECT ID, S FROM B8859 WHERE ID >= 161 AND ID <> 173 ORDER BY ID"
twin "all 128 WIN1250 high-byte rows are readable (holes included)" \
     "SELECT COUNT(*) AS N, SUM(OCTET_LENGTH(S)) AS O FROM B1250"
twin "... all 128 WIN1251 rows" \
     "SELECT COUNT(*) AS N, SUM(OCTET_LENGTH(S)) AS O FROM B1251"
twin "... all 128 ISO8859_2 rows" \
     "SELECT COUNT(*) AS N, SUM(OCTET_LENGTH(S)) AS O FROM B8859"

# fc WRITES the new codepages' bytes, the ENGINE reads them back
ran=$((ran + 1))
r=$(node_q "INSERT INTO XC VALUES (4, 'čaj', 'чай', 'čaj')")
got=$(isql_q "$FC" "SELECT ID, C, Y, T, OCTET_LENGTH(C) FROM XC WHERE ID = 4")
if [ "$r" = "OK" ] && [ "$got" = "4|čaj|чай|čaj|3" ]; then
    echo "OK   fc stores all three codepages; the engine reads 3 octets of 'čaj'"
else
    echo "DIFF new-codepage store: insert [$r], engine read [$got]"
    fail=1
fi
ran=$((ran + 1))
got=$(isql_q "$FC" "SELECT ID FROM XC WHERE Y = 'чай'")
if [ "$got" = "4" ]; then
    echo "OK   ... and finds the Cyrillic row by value"
else
    echo "DIFF engine WHERE over fc's cp1251 row: [$got]"
    fail=1
fi

# the unmappable pair: Cyrillic has no image in Latin-2 - both refuse
ran=$((ran + 1))
r=$(node_q "INSERT INTO XC VALUES (9, 'x', 'x', 'жук')")
e=$(printf "INSERT INTO XC VALUES (9, 'x', 'x', 'жук');\n" | "$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$RE" 2>&1 | grep -c "SQLSTATE = 22018")
if [ "$r" = "ERR" ] && [ "$e" -ge 1 ]; then
    echo "OK   Cyrillic into ISO8859_2: fc refuses, the engine raises 22018"
else
    echo "DIFF cross-set unmappable: fc [$r], engine 22018-count $e"
    fail=1
fi

# an INDEXED WIN1251 column: the INTL itype generalizes (ttype 52 + 32831)
"$ISQL" -q -b -ch UTF8 -user "$U" -pas "$P" "$FC" <<EOF >/dev/null 2>&1
CREATE TABLE KY (ID INTEGER, Y VARCHAR(10) CHARACTER SET WIN1251);
CREATE INDEX IDX_KY_Y ON KY (Y);
COMMIT;
INSERT INTO KY VALUES (1, 'море');
COMMIT;
EOF
ran=$((ran + 1))
r=$(node_q "INSERT INTO KY VALUES (2, 'юг')")
got=$(isql_q "$FC" "SELECT ID FROM KY WHERE Y = 'юг'")
a=$(node_q "SELECT ID FROM KY WHERE Y = 'море'")
if [ "$r" = "OK" ] && [ "$got" = "2" ] && [ "$a" = "1" ]; then
    echo "OK   fc keys a WIN1251 index the engine's scan finds, and bands it itself"
else
    echo "DIFF WIN1251 index: insert [$r], engine find [$got], fc band [$a]"
    fail=1
fi

# --- 8. a RAW-BYTE PARAMETER through a NONE attachment -----------------
# a parameter's bytes mean what the ATTACHMENT charset says (probed on
# the live engine): under a NONE attachment they are BYTES - stored
# verbatim into a NONE or single-byte column, refused by a UTF8 one
# when malformed there. Before the attachment-aware decode, fc pushed
# every wire text param through from_utf8_lossy: the 0xE9 was
# DESTROYED into the replacement character (stored, not refused), the
# WIN1252 column refused what the engine stores, and the UTF8 column
# accepted a malformed string the engine refuses.
node_raw() { # <sql> - E9 32 as the one bound parameter, NONE attachment
    FC_DB="$FC" FC_PORT="$PORT" FC_Q="$1" timeout 30 node -e '
      process.on("uncaughtException", () => { console.log("CONN_ERR"); process.exit(1); });
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey",encoding:"NONE"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        const s = Buffer.from([0xE9, 0x32]).toString("latin1");
        db.query(process.env.FC_Q,[s],(e2,r)=>{
          if(e2){console.log("ERR");db.detach();process.exit(0);}
          if(Array.isArray(r)) for(const row of r)
            console.log(Object.values(row).join("|"));
          else console.log("OK");
          db.detach();process.exit(0);});});' 2>/dev/null
}
ran=$((ran + 1))
r=$(node_raw "INSERT INTO NB VALUES (9, ?)")
got=$(isql_q "$FC" "SELECT ID, OCTET_LENGTH(S) FROM NB WHERE ID = 9")
if [ "$r" = "OK" ] && [ "$got" = "9|2" ]; then
    echo "OK   a raw E9 32 param lands VERBATIM in a NONE column (2 octets, not lossy 4)"
else
    echo "DIFF raw param into NONE: insert [$r], engine read [$got] (want 9|2)"
    fail=1
fi
ran=$((ran + 1))
r=$(node_raw "INSERT INTO XL (ID, W) VALUES (9, ?)")
got=$(isql_q "$FC" "SELECT ID, OCTET_LENGTH(W) FROM XL WHERE W = 'é2'")
if [ "$r" = "OK" ] && [ "$got" = "9|2" ]; then
    echo "OK   ... and verbatim in a WIN1252 column, where the byte IS 'é'"
else
    echo "DIFF raw param into WIN1252: insert [$r], engine find [$got] (want 9|2)"
    fail=1
fi
ran=$((ran + 1))
r=$(node_raw "INSERT INTO XU VALUES (9, ?)")
e=$(FC_DB="$RE" FC_PORT=3050 FC_Q="INSERT INTO XU VALUES (9, ?)" timeout 30 node -e '
      const F=require("node-firebird");
      F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,
                user:"SYSDBA",password:"masterkey",encoding:"NONE"},(e,db)=>{
        if(e){console.log("CONN_ERR");process.exit(1);}
        const s = Buffer.from([0xE9, 0x32]).toString("latin1");
        db.query(process.env.FC_Q,[s],(e2)=>{
          console.log(e2?"ERR":"OK");db.detach();process.exit(0);});});' 2>/dev/null)
if [ "$r" = "ERR" ] && [ "$e" = "ERR" ]; then
    echo "OK   ... and a UTF8 column refuses the malformed bytes on BOTH sides"
else
    echo "DIFF raw param into UTF8: fc [$r], engine [$e] (want ERR ERR)"
    fail=1
fi
ran=$((ran + 1))
got=$(node_raw "SELECT ID FROM NB WHERE S = ?")
if [ "$got" = "9" ]; then
    echo "OK   the byte compare finds the raw row through the same param"
else
    echo "DIFF raw param compare: [$got] (want 9)"
    fail=1
fi

# --- 9. the file survives the engine's own verifier --------------------
ran=$((ran + 1))
g=$("$GFIX" -v -full -user "$U" -pas "$P" "$FC" 2>&1)
if [ -z "$g" ]; then
    echo "OK   gfix -v -full finds nothing wrong with the fc-written file"
else
    echo "DIFF gfix: $g"
    fail=1
fi

kill $srv 2>/dev/null; srv=""
rm -f "$RE" "$FC"
if [ "$ran" -lt 46 ]; then
    echo "DIFF only $ran checks ran (expected at least 46) - did one silently skip?"
    fail=1
fi
exit $fail
