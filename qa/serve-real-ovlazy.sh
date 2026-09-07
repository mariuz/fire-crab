#!/bin/bash
# THE OUT-OF-RANGE RAISE IS LAZY, AS THE ENGINE'S IS (F2, the whole of it).
#
# A BIGINT column holding 9e17, altered to NUMERIC(18,4), holds an old row
# whose value cannot be PRESENTED through the new scale (9e17 * 10^4
# overflows). The engine raises 22003 "numeric value is out of range" ONLY
# where it must present that row's value - as an output column, a filter
# that references the column, an aggregate, a sort / group / distinct key,
# an expression that reads it - and NEVER for a row a filter excludes on
# some OTHER column, nor when the column is not touched. fire-crab carries
# the overflow as a poison value that raises at exactly those points and
# nowhere earlier, so it neither answers a wrong number (the F2 defect) nor
# over-raises on a filtered-out row (the eager-raise regression the poison
# replaced).
#
# Built BY THE ENGINE and copied byte-identically to both servers; for
# every query below the engine and fire-crab must AGREE - both raise
# 22003, or both return the same rows, and fire-crab must never drop the
# connection (a mid-row raise once did). Two fixtures: no index (natural
# scans) and with indexes on N and ID (index-driven reads and a join).
#
# Usage: qa/serve-real-ovlazy.sh [port]   (default 4135)
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4135}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
NX="$D/ovlazy-nx.fdb"; IX="$D/ovlazy-ix.fdb"
rm -f "$NX" "$IX"

build() { # <db> <extra ddl>
    echo "create database '127.0.0.1/3050:$1' user '$U' password '$P' page_size 8192 default character set NONE;" \
        | "$ISQL" -q -user "$U" -pas "$P" >/dev/null 2>&1 || { echo "FAIL create $1"; exit 1; }
    { cat <<'SQL'
create table ov (id integer, n bigint);
commit;
insert into ov values (1, 900000000000000000);
insert into ov values (2, 5);
insert into ov values (3, 6);
commit;
alter table ov alter n type numeric(18,4);
commit;
create table j (id integer, tag varchar(4));
commit;
insert into j values (1,'a');
insert into j values (2,'b');
insert into j values (3,'c');
commit;
SQL
      echo "$2"; } | "$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$1" >/tmp/ovlazy-build.log 2>&1
    if grep -qi "error" /tmp/ovlazy-build.log; then echo "FAIL building $1:"; sed 's/^/     /' /tmp/ovlazy-build.log; exit 1; fi
}
build "$NX" ""
build "$IX" "create index ix_ov_n on ov(n); create index ix_ov_id on ov(id); commit;"
NXC="$D/ovlazy-nxc.fdb"; IXC="$D/ovlazy-ixc.fdb"; cp "$NX" "$NXC"; cp "$IX" "$IXC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-ovlazy.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
# agree(<eng-db> <fc-db> <query>): engine and fc must both-raise or both-return-same, fc no 08006
agree() {
    local edb="$1" fdb="$2" q="$3"
    local e f er fr c8 ev fv
    e=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/3050:$edb" <<< "$q" 2>&1)
    f=$("$ISQL" -q -user "$U" -pas "$P" "127.0.0.1/$PORT:$fdb" <<< "$q" 2>&1)
    er=$(printf '%s' "$e" | grep -c 22003); fr=$(printf '%s' "$f" | grep -c 22003)
    c8=$(printf '%s' "$f" | grep -c 08006)
    ev=$(printf '%s' "$e" | sed 's/[[:space:]]//g' | grep -v '22003\|arithmetic\|numericvalue\|Statementfailed\|^=*$\|^$\|afterline')
    fv=$(printf '%s' "$f" | sed 's/[[:space:]]//g' | grep -v '22003\|arithmetic\|numericvalue\|Statementfailed\|^=*$\|^$\|afterline')
    if [ "$c8" != 0 ]; then echo "FAIL [$q] fire-crab dropped the connection (08006)"; fail=1; return; fi
    if [ "$er" != "$fr" ]; then echo "FAIL [$q] raise disagree: engine=$er fc=$fr"; fail=1; return; fi
    if [ "$er" = 0 ] && [ "$ev" != "$fv" ]; then echo "FAIL [$q] values disagree"; echo "     eng=[$ev] fc=[$fv]"; fail=1; return; fi
    echo "OK   [$q]"
}

# --- natural (no-index) scans ---
for q in \
  "select n from ov;" \
  "select n from ov where id=2;" \
  "select n from ov where n>0;" \
  "select n from ov where n=5;" \
  "select sum(n) from ov;" \
  "select avg(n) from ov;" \
  "select min(n) from ov;" \
  "select count(n) from ov;" \
  "select count(*) from ov;" \
  "select n from ov order by n;" \
  "select distinct n from ov;" \
  "select n, count(*) from ov group by n;" \
  "select n+1 from ov;" \
  "select id from ov where id=2;" \
  "select id from ov;" ; do
  agree "$NX" "$NXC" "$q"
done
# --- index-driven reads and a join ---
for q in \
  "select n from ov where n>0;" \
  "select n from ov where id=1;" \
  "select ov.n, j.tag from ov inner join j on ov.id=j.id;" \
  "select ov.n, j.tag from ov inner join j on ov.id=j.id where j.id=2;" \
  "select j.tag from ov inner join j on ov.id=j.id;" ; do
  agree "$IX" "$IXC" "$q"
done

kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
[ $fail = 0 ] && echo "PASS ovlazy" || echo "FAIL ovlazy"
exit $fail
