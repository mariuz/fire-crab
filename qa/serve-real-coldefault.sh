#!/bin/bash
# A COLUMN-LEVEL DEFAULT SURVIVES fire-crab's LOGICAL BACKUP.
#
# fire-crab's backup writer once emitted no RDB$DEFAULT_VALUE / SOURCE on
# the relation-field record, so a `CREATE TABLE ... B INTEGER DEFAULT 42`
# came back from a restore with NO default: a later INSERT that omits B
# wrote NULL, and an `ON DELETE SET DEFAULT` foreign key wrote NULL where
# the engine writes the declared default. The gbak default gates covered
# only a DOMAIN default and PSQL parameter defaults, never a column one.
#
# This holds fire-crab's backup against the ENGINE's own: the engine
# builds the fixture, both servers back it up, the engine restores both,
# and the two restored databases must agree on the column defaults, on
# what an INSERT that omits the columns stores, and on what ON DELETE SET
# DEFAULT writes.
#
# Usage: qa/serve-real-coldefault.sh [port]   (default 4136)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
GBAK="${GBAK:-gbak}"
PORT="${1:-4136}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
SRC="$D/coldefault-src.fdb"
rm -f "$SRC" "$D"/coldefault-eng.fbk "$D"/coldefault-fc.fbk "$D"/coldefault-eng-r.fdb "$D"/coldefault-fc-r.fdb
echo "create database '127.0.0.1/3050:$SRC' user '$U' password '$P' page_size 8192 default character set NONE;" \
    | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $SRC"; exit 1; }
B=$(mktemp "$D/coldefault-b.XXXXXX.sql")
cat > "$B" <<'SQL'
create domain dom_i as integer default 7;
commit;
create table t (a integer, b integer default 42, c varchar(8) default 'hi', e dom_i);
commit;
insert into t (a) values (1);
commit;
create table gp (id integer not null primary key);
commit;
create table gd (x integer, b integer default 10, constraint fk_gd foreign key (b) references gp(id) on delete set default);
commit;
insert into gp values (1);
insert into gp values (10);
insert into gd (x, b) values (100, 1);
commit;
SQL
"$ISQL" -q -user "$U" -pas "$P" -i "$B" "127.0.0.1/3050:$SRC" >/tmp/coldefault-build.log 2>&1
if grep -qi error /tmp/coldefault-build.log; then echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/coldefault-build.log; exit 1; fi
rm -f "$B"

# engine backup
"$GBAK" -b -user "$U" -pas "$P" "127.0.0.1/3050:$SRC" "$D/coldefault-eng.fbk" >/dev/null 2>&1
# fire-crab backup
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-coldefault.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }
"$GBAK" -b -se "127.0.0.1/$PORT:service_mgr" -user "$U" -pas "$P" "$SRC" "$D/coldefault-fc.fbk" >/dev/null 2>&1
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ -s "$D/coldefault-fc.fbk" ] || { echo "FAIL fire-crab produced no backup"; exit 1; }

fail=0
"$GBAK" -c -user "$U" -pas "$P" "$D/coldefault-eng.fbk" "127.0.0.1/3050:$D/coldefault-eng-r.fdb" >/dev/null 2>&1 || { echo "FAIL engine restore"; exit 1; }
"$GBAK" -c -user "$U" -pas "$P" "$D/coldefault-fc.fbk" "127.0.0.1/3050:$D/coldefault-fc-r.fdb" >/dev/null 2>&1 || { echo "FAIL restore of fire-crab's backup"; exit 1; }
ENG="$D/coldefault-eng-r.fdb"; FC="$D/coldefault-fc-r.fdb"

both() { # <label> <isql script>
    local label="$1" q="$2"
    a=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$ENG" <<< "$q" 2>&1 | sed 's/[[:space:]]*$//')
    b=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$FC" <<< "$q" 2>&1 | sed 's/[[:space:]]*$//')
    if [ "$a" = "$b" ]; then echo "OK   $label"; else echo "FAIL $label"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -10 | sed 's/^/     /'; fail=1; fi
}
both "the column DEFAULT sources survive the backup" \
     "select rdb\$field_name, rdb\$default_source from rdb\$relation_fields where rdb\$relation_name='T' order by 1;"
both "an INSERT that omits the columns stores their defaults" \
     "insert into t (a) values (2); select a, b, c, e from t where a=2;"
both "ON DELETE SET DEFAULT writes the declared column default, not NULL" \
     "delete from gp where id=1; select x, b from gd where x=100;"
[ $fail = 0 ] && echo "PASS coldefault" || echo "FAIL coldefault"
exit $fail
