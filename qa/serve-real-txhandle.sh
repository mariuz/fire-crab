#!/bin/bash
# ONE ATTACHMENT, SEVERAL TRANSACTIONS - the wire's transaction handle
# means something.
#
# A client may hold more than one transaction open on a single
# attachment, and every op that carries a transaction handle names WHICH
# one it means: op_transaction answers a fresh handle in p_resp_object
# (server.cpp:6889 make_transaction), op_commit / op_rollback resolve
# that handle and FREE the slot (server.cpp:3464), the retaining forms
# keep it, and op_execute rebinds the statement to the handle it is
# given (dsql.cpp:193 `req_transaction = *tra_handle`) - which is why
# isql can PREPARE on its DDL transaction and EXECUTE on the user's
# (isql.epp:8425/8636). A handle that named nothing answers
# isc_bad_trans_handle (335544332).
#
# fire-crab used to hand every transaction the SAME handle, so a commit
# of one committed the other: isql's autocommit of a DDL statement
# committed the user's pending DML, and a ROLLBACK afterwards had
# nothing left to undo. That is the class this gate exists to catch -
# a rollback that does not roll back is the worst kind of wrong answer.
#
# The differential is run three ways: through isql's own two
# transactions (autocommit ON, the default), through node-firebird with
# two explicit transactions on one attachment, and against a control
# with AUTODDL OFF where a single transaction does all the work.
#
#   qa/serve-real-txhandle.sh [port]
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"; GFIX="${GFIX:-gfix}"
PORT="${1:-4995}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D=/tmp/fbhandson
NODE_PATH="${NODE_PATH:-/home/ubuntu/work}"; export NODE_PATH
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
mkdir -p "$D"; fail=0; ran=0
# one scratch file per side, so each server owns its own
A="$D/fc-txh-crab.fdb"; B="$D/fc-txh-engine.fdb"
make_db() { rm -f "$1"; "$ISQL" -q -b -user "$U" -pas "$P" <<EOF >/dev/null 2>&1 || return 1
CREATE DATABASE '$1' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (I INTEGER);
COMMIT;
EOF
    chmod 666 "$1"; }
make_db "$A" || { echo "FAIL scratch A"; exit 1; }
make_db "$B" || { echo "FAIL scratch B"; exit 1; }
"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >"/tmp/fc-serve-txh-$PORT.log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$A" "$B"' EXIT
i=0; while [ $i -lt 20 ]; do command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; i=$((i + 1)); sleep 0.1; done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT in use?"; exit 1; }
norm() { grep -v '^$' | sed 's/  */ /g; s/^ //; s/ *$//' | tr '\n' '|'; }
# <port> <db> <sql>
run() { printf '%b' "$3" | "$ISQL" -q -ch NONE -user "$U" -pas "$P" "127.0.0.1/$1:$2" 2>&1 | norm; }
both() { ran=$((ran + 1)); a=$(run "$PORT" "$A" "$2"); b=$(run "$REAL" "$B" "$2")
    if [ "$a" = "$b" ]; then echo "OK   $1"; else
    echo "DIFF $1"; echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi; }
reset_both() { run "$PORT" "$A" "DELETE FROM T;\nCOMMIT;\n" >/dev/null
               run "$REAL" "$B" "DELETE FROM T;\nCOMMIT;\n" >/dev/null; }

# --- 1. isql's OWN two transactions (autocommit ON, the default) ------
# isql executes a DDL statement on its own DDL transaction and commits
# THAT one (isql.epp:8596); the user's INSERT is still pending on the
# other, and the ROLLBACK that follows must take it back.
reset_both
both "a DDL statement's autocommit leaves the pending INSERT rollback-able" \
    "SET HEADING OFF;\nINSERT INTO T VALUES (1);\nCREATE TABLE X1 (I INTEGER);\nROLLBACK;\nSELECT COUNT(*) FROM T;\n"
both "...and the DDL it committed is still there" \
    "SET HEADING OFF;\nSELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'X1';\n"
reset_both
both "SET GENERATOR autocommits the same way, and leaves DML alone" \
    "SET HEADING OFF;\nCREATE SEQUENCE S1;\nCOMMIT;\nINSERT INTO T VALUES (2);\nSET GENERATOR S1 TO 7;\nROLLBACK;\nSELECT COUNT(*) FROM T;\nSELECT GEN_ID(S1, 0) FROM RDB\$DATABASE;\n"
# the control: with AUTODDL OFF isql runs everything on ONE transaction,
# so the DDL rolls back with the row
reset_both
both "CONTROL: with AUTODDL OFF one transaction does it all" \
    "SET HEADING OFF;\nSET AUTODDL OFF;\nINSERT INTO T VALUES (3);\nCREATE TABLE X2 (I INTEGER);\nROLLBACK;\nSELECT COUNT(*) FROM T;\nSELECT COUNT(*) FROM RDB\$RELATIONS WHERE RDB\$RELATION_NAME = 'X2';\n"

# --- 2. two EXPLICIT transactions on one attachment -------------------
# committing one must not commit the other, and rolling the other back
# must really take its rows away
two_tx() { # <port> <db>
  node -e '
const fb=require("node-firebird");
const opts={host:"127.0.0.1",port:'"$1"',database:"'"$2"'",user:"'"$U"'",password:"'"$P"'"};
fb.attach(opts,(e,db)=>{
  if(e){console.log("attach:"+e.message);process.exit(0);}
  db.query("DELETE FROM T",(e0)=>{
    db.transaction(fb.ISOLATION_READ_COMMITTED,(e1,t1)=>{
      if(e1){console.log("t1:"+e1.message);process.exit(0);}
      db.transaction(fb.ISOLATION_READ_COMMITTED,(e2,t2)=>{
        if(e2){console.log("t2:"+e2.message);process.exit(0);}
        t1.query("INSERT INTO T VALUES (10)",(e3)=>{
          t2.query("INSERT INTO T VALUES (20)",(e4)=>{
            t2.commit((e5)=>{
              t1.rollback((e6)=>{
                db.query("SELECT I FROM T ORDER BY I",(e7,r)=>{
                  const errs=[e3,e4,e5,e6,e7].map(x=>x?x.message.split("\n")[0]:"ok").join(" ");
                  console.log("errs: "+errs+" rows: "+(e7?"-":JSON.stringify(r.map(x=>x.I))));
                  db.detach(()=>process.exit(0));
                });
              });
            });
          });
        });
      });
    });
  });
});' 2>&1 | head -2
}
ran=$((ran + 1)); a=$(two_tx "$PORT" "$A" | norm); b=$(two_tx "$REAL" "$B" | norm)
if [ "$a" = "$b" ]; then echo "OK   commit of one transaction leaves the other's rows uncommitted"; else
    echo "DIFF commit of one transaction leaves the other's rows uncommitted"
    echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi

# each transaction reads its OWN uncommitted work and not its sibling's
iso_tx() { # <port> <db>
  node -e '
const fb=require("node-firebird");
const opts={host:"127.0.0.1",port:'"$1"',database:"'"$2"'",user:"'"$U"'",password:"'"$P"'"};
fb.attach(opts,(e,db)=>{
  if(e){console.log("attach:"+e.message);process.exit(0);}
  db.query("DELETE FROM T",(e0)=>{
    db.transaction(fb.ISOLATION_READ_COMMITTED,(e1,t1)=>{
      db.transaction(fb.ISOLATION_READ_COMMITTED,(e2,t2)=>{
        t1.query("INSERT INTO T VALUES (30)",(e3)=>{
          t1.query("SELECT COUNT(*) AS C FROM T",(e4,r1)=>{
            t2.query("SELECT COUNT(*) AS C FROM T",(e5,r2)=>{
              console.log("own:"+(e4?e4.message.split("\n")[0]:r1[0].C)+" sibling:"+(e5?e5.message.split("\n")[0]:r2[0].C));
              t1.rollback(()=>{ t2.rollback(()=>{ db.detach(()=>process.exit(0)); }); });
            });
          });
        });
      });
    });
  });
});' 2>&1 | head -2
}
ran=$((ran + 1)); a=$(iso_tx "$PORT" "$A" | norm); b=$(iso_tx "$REAL" "$B" | norm)
if [ "$a" = "$b" ]; then echo "OK   a transaction sees its own uncommitted rows, not its sibling's"; else
    echo "DIFF a transaction sees its own uncommitted rows, not its sibling's"
    echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi

# --- 3. a handle that named nothing ----------------------------------
# committing the same transaction twice: the second names a freed slot
dead_handle() { # <port> <db>
  node -e '
const fb=require("node-firebird");
const opts={host:"127.0.0.1",port:'"$1"',database:"'"$2"'",user:"'"$U"'",password:"'"$P"'"};
fb.attach(opts,(e,db)=>{
  if(e){console.log("attach:"+e.message);process.exit(0);}
  db.transaction(fb.ISOLATION_READ_COMMITTED,(e1,t)=>{
    if(e1){console.log("t:"+e1.message);process.exit(0);}
    t.query("INSERT INTO T VALUES (40)",(e2)=>{
      t.commit((e3)=>{
        // the handle is freed now - a second commit must be refused
        t.commit((e4)=>{
          console.log("second commit: "+(e4?e4.message.split("\n")[0]:"ACCEPTED"));
          db.detach(()=>process.exit(0));
        });
      });
    });
  });
});' 2>&1 | head -2
}
ran=$((ran + 1)); a=$(dead_handle "$PORT" "$A" | norm); b=$(dead_handle "$REAL" "$B" | norm)
if [ "$a" = "$b" ]; then echo "OK   a second commit of the same transaction is refused the same way"; else
    echo "DIFF a second commit of the same transaction"
    echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi

# --- 3b. what one transaction's END must not take with it -------------
# Its LOCKS: a commit released the whole attachment's lock owner, so a
# sibling's transaction lock went with it - and a concurrent sweep then
# read that live transaction as abandoned and backed its rows out
# (review-caught, data destroyed). Each transaction owns its locks now.
sweep_sib() { # <port> <db>
  node -e '
const fb=require("node-firebird");
const opts={host:"127.0.0.1",port:'"$1"',database:"'"$2"'",user:"'"$U"'",password:"'"$P"'"};
fb.attach(opts,(e,db)=>{
  if(e){console.log("attach:"+e.message);process.exit(0);}
  db.query("DELETE FROM T",()=>{
    db.transaction(fb.ISOLATION_READ_COMMITTED,(e1,t1)=>{
      t1.query("INSERT INTO T VALUES (10)",()=>{
        db.transaction(fb.ISOLATION_READ_COMMITTED,(e2,t2)=>{
          t2.query("INSERT INTO T VALUES (20)",()=>{
            t2.commit(()=>{
              try { require("child_process").execSync("'"$GFIX"' -sweep -user '"$U"' -pas '"$P"' 127.0.0.1/'"$1"':'"$2"' 2>/dev/null"); } catch (x) {}
              t1.commit(()=>{
                db.query("SELECT I FROM T ORDER BY I",(e5,r)=>{
                  console.log(e5?e5.message.split("\n")[0]:JSON.stringify(r.map(x=>x.I)));
                  db.detach(()=>process.exit(0));
                });
              });
            });
          });
        });
      });
    });
  });
});' 2>&1 | head -2
}
ran=$((ran + 1)); a=$(sweep_sib "$PORT" "$A" | norm); b=$(sweep_sib "$REAL" "$B" | norm)
if [ "$a" = "$b" ]; then echo "OK   a sibling's commit leaves the live transaction's locks alone (sweep keeps its rows)"; else
    echo "DIFF a sibling's commit purged the live transaction's locks"
    echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi

# ...and its TEMP BLOBS: the ids restarted at 2 in every transaction
# while op_put_segment carries no handle, so a segment landed in the
# sibling's blob (review-caught). Ids are unique per attachment now.
blob_sib() { # <port> <db>
  node -e '
const fb=require("node-firebird");
const opts={host:"127.0.0.1",port:'"$1"',database:"'"$2"'",user:"'"$U"'",password:"'"$P"'"};
fb.attach(opts,(e,db)=>{
  if(e){console.log("attach:"+e.message);process.exit(0);}
  db.query("DELETE FROM BT",()=>{
    db.transaction(fb.ISOLATION_READ_COMMITTED,(e1,t1)=>{
      db.transaction(fb.ISOLATION_READ_COMMITTED,(e2,t2)=>{
        t1.query("INSERT INTO BT VALUES (1, ?)",[Buffer.from("AAA-from-t1")],()=>{
          t2.query("INSERT INTO BT VALUES (2, ?)",[Buffer.from("BBB-from-t2")],()=>{
            t1.commit(()=>{ t2.commit(()=>{
              db.query("SELECT I, CAST(D AS VARCHAR(30)) AS D FROM BT ORDER BY I",(e5,r)=>{
                console.log(e5?e5.message.split("\n")[0]:JSON.stringify(r));
                db.detach(()=>process.exit(0));
              });
            });});
          });
        });
      });
    });
  });
});' 2>&1 | head -2
}
run "$PORT" "$A" "CREATE TABLE BT (I INTEGER, D BLOB SUB_TYPE TEXT);\nCOMMIT;\n" >/dev/null
run "$REAL" "$B" "CREATE TABLE BT (I INTEGER, D BLOB SUB_TYPE TEXT);\nCOMMIT;\n" >/dev/null
ran=$((ran + 1)); a=$(blob_sib "$PORT" "$A" | norm); b=$(blob_sib "$REAL" "$B" | norm)
if [ "$a" = "$b" ]; then echo "OK   two transactions' blobs written interleaved keep their own contents"; else
    echo "DIFF interleaved blobs crossed between transactions"
    echo "     fc:     [$a]"; echo "     engine: [$b]"; fail=1; fi

# --- 4. the file the two servers leave behind -------------------------
kill $srv 2>/dev/null; wait $srv 2>/dev/null
ran=$((ran + 1))
v=$("$GFIX" -v -full -user "$U" -pas "$P" "$A" 2>&1 | norm)
if [ -z "$v" ]; then echo "OK   gfix -v -full is silent on fire-crab's file"; else
    echo "DIFF gfix: [$v]"; fail=1; fi

echo
if [ "$fail" = 0 ]; then echo "PASS all $ran checks"; else echo "FAIL"; exit 1; fi
