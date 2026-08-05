//! THE LOCK MANAGER, PARTICIPATING - one lock table per database, and
//! the one thing the server asks it: **has this row's transaction
//! finished?**
//!
//! That is how the engine arbitrates a row, and it is worth stating
//! plainly because it is not what "row locking" sounds like. Firebird
//! does not lock records in the lock table. A writer that finds a
//! version belonging to another transaction reads that transaction's
//! STATE, and if it is still active it waits - by taking a lock on the
//! TRANSACTION (`LCK_tra`, series 4), which that transaction holds
//! exclusively for as long as it lives. When it commits or rolls back
//! the lock goes, the waiter wakes, re-reads the row, and proceeds
//! against whatever it now finds.
//!
//! So the whole participation is two calls:
//!
//!   * [DbLocks::hold_transaction] - taken once, at a transaction's
//!     first write, released when it ends;
//!   * [DbLocks::wait_for_transaction] - taken by a writer that met an
//!     active version, and released the moment it is granted.
//!
//! And what that buys, beyond the wait, is the **deadlock scan**: two
//! transactions each waiting on the other's lock close a cycle in the
//! wait-for graph, and `fire_crab_lck` denies the second one rather
//! than letting it wait forever - the engine's own SQLSTATE 40001.
//!
//! The table is `&mut self` and in-process, so it lives behind a mutex
//! with a condvar for the parked waiters; a wait that runs out of time
//! is dropped through the table's own deadline machinery
//! (`enqueue_deadline` + `expire`), which had been converted with
//! nothing calling it.

use fire_crab_lck::shm::series;
use fire_crab_lck::{LockTable, Mode, OwnerId, Verdict};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

/// What a wait ended as.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Waited {
    /// the transaction ended - re-read the row and carry on
    Ended,
    /// waiting would close a cycle in the wait-for graph: the engine
    /// denies the request rather than deadlocking (SQLSTATE 40001)
    Deadlock,
    /// the wait ran out of time
    TimedOut,
}

/// What the lock table has done, for the coverage half of a wiring
/// gate: `waits` counts writers that actually met an active
/// transaction, and it stays zero on a server nothing contends with.
#[derive(Default)]
pub struct Stats {
    pub holds: AtomicU64,
    pub waits: AtomicU64,
    pub grants: AtomicU64,
    pub deadlocks: AtomicU64,
    pub timeouts: AtomicU64,
}

fn stats() -> &'static Stats {
    static S: OnceLock<Stats> = OnceLock::new();
    S.get_or_init(Stats::default)
}

/// One line of lock counters - what a coverage gate reads.
pub fn stats_line() -> String {
    let s = stats();
    format!(
        "holds {} waits {} grants {} deadlocks {} timeouts {}",
        s.holds.load(Ordering::Relaxed),
        s.waits.load(Ordering::Relaxed),
        s.grants.load(Ordering::Relaxed),
        s.deadlocks.load(Ordering::Relaxed),
        s.timeouts.load(Ordering::Relaxed),
    )
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The tick the table's deadlines are counted in. The lock table has
/// no clock of its own - the engine's `SET LOCK TIMEOUT` is a caller
/// tick there too - so this is milliseconds since the first call.
fn now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

pub struct DbLocks {
    table: Mutex<LockTable>,
    /// woken whenever a lock is released, so parked waiters re-test
    wake: Condvar,
}

fn tra_key(tx: u32) -> [u8; 4] {
    tx.to_le_bytes()
}

impl DbLocks {
    /// A fresh owner - one per attachment, as `create_owner` is.
    pub fn owner(&self) -> OwnerId {
        lock(&self.table).create_owner()
    }

    /// Hold this transaction's own lock for as long as it lives. It is
    /// exclusive and always granted: nobody else can be holding a lock
    /// on an id this attachment has just reserved.
    pub fn hold_transaction(&self, owner: OwnerId, tx: u32) {
        let mut t = lock(&self.table);
        t.enqueue(owner, series::TRA, &tra_key(tx), Mode::Exclusive, false);
        stats().holds.fetch_add(1, Ordering::Relaxed);
    }

    /// Wait for transaction `tx` to end, the way a writer that met one
    /// of its versions must.
    ///
    /// THE CALLER MUST NOT HOLD THE DATABASE'S WRITE SIDE HERE. The
    /// transaction being waited for needs it to commit, so waiting
    /// while holding it is a deadlock this side of the lock table -
    /// one it could not see, because the write side is not a lock it
    /// knows about.
    pub fn wait_for_transaction(&self, owner: OwnerId, tx: u32, timeout: Duration) -> Waited {
        let key = tra_key(tx);
        let deadline = now_ms() + timeout.as_millis() as u64;
        let mut t = lock(&self.table);
        stats().waits.fetch_add(1, Ordering::Relaxed);
        // SHARED READ against the holder's EXCLUSIVE: incompatible
        // while it lives, granted the moment it goes
        let verdict =
            t.enqueue_deadline(owner, series::TRA, &key, Mode::SharedRead, true, Some(deadline));
        let outcome = match verdict {
            Verdict::Granted => Waited::Ended,
            Verdict::Deadlock => {
                stats().deadlocks.fetch_add(1, Ordering::Relaxed);
                return Waited::Deadlock;
            }
            Verdict::Rejected => Waited::TimedOut,
            Verdict::Waiting => loop {
                if t.is_granted(owner, series::TRA, &key) {
                    break Waited::Ended;
                }
                let left = deadline.saturating_sub(now_ms());
                if left == 0 {
                    // the table's own deadline machinery drops it, so a
                    // request that gave up leaves nothing parked in
                    // front of the next one
                    for (o, s, k) in t.expire(now_ms()) {
                        if o == owner && s == series::TRA && k == key {
                            stats().timeouts.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    break Waited::TimedOut;
                }
                let (g, _) = self
                    .wake
                    .wait_timeout(t, Duration::from_millis(left.min(50)))
                    .unwrap_or_else(|e| e.into_inner());
                t = g;
            },
        };
        if outcome == Waited::Ended {
            // the wait is over the moment it is granted - this lock was
            // never wanted for itself, only for the waiting
            t.dequeue(owner, series::TRA, &key);
            stats().grants.fetch_add(1, Ordering::Relaxed);
            drop(t);
            self.wake.notify_all();
        }
        outcome
    }

    /// The transaction ended, or the attachment did: drop everything
    /// this owner holds and wake whoever was waiting for it.
    pub fn release(&self, owner: OwnerId) {
        {
            let mut t = lock(&self.table);
            t.purge_owner(owner);
        }
        self.wake.notify_all();
    }
}

fn registry() -> &'static Mutex<HashMap<String, Arc<DbLocks>>> {
    static R: OnceLock<Mutex<HashMap<String, Arc<DbLocks>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The lock table of one database, shared by every attachment to it -
/// keyed the way the buffer pool is, since it arbitrates the same
/// thing.
pub fn for_path(path: &str) -> Arc<DbLocks> {
    let key = std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string());
    let mut r = lock(registry());
    Arc::clone(r.entry(key).or_insert_with(|| {
        Arc::new(DbLocks {
            table: Mutex::new(LockTable::new()),
            wake: Condvar::new(),
        })
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_writer_waits_for_the_transaction_it_met() {
        let locks = for_path("/nonexistent/fc-dblocks-test-1");
        let holder = locks.owner();
        let waiter = locks.owner();
        locks.hold_transaction(holder, 7);
        // it is held, so a wait times out rather than being granted
        assert_eq!(
            locks.wait_for_transaction(waiter, 7, Duration::from_millis(80)),
            Waited::TimedOut
        );
        // ...and ends the moment the holder's transaction does
        locks.release(holder);
        assert_eq!(
            locks.wait_for_transaction(waiter, 7, Duration::from_millis(500)),
            Waited::Ended
        );
        locks.release(waiter);
    }

    #[test]
    fn a_wait_that_closes_a_cycle_is_denied() {
        let locks = for_path("/nonexistent/fc-dblocks-test-2");
        let a = locks.owner();
        let b = locks.owner();
        locks.hold_transaction(a, 1);
        locks.hold_transaction(b, 2);
        // A parks on B's transaction...
        let l2 = Arc::clone(&locks);
        let parked =
            std::thread::spawn(move || l2.wait_for_transaction(a, 2, Duration::from_millis(400)));
        std::thread::sleep(Duration::from_millis(60));
        // ...and B asking for A's would close the cycle
        assert_eq!(
            locks.wait_for_transaction(b, 1, Duration::from_millis(400)),
            Waited::Deadlock,
            "the wait-for graph is what makes this answerable"
        );
        let _ = parked.join().unwrap();
        locks.release(a);
        locks.release(b);
    }
}
