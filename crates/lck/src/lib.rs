//! The lock manager - the conversion of `src/lock/lock.cpp`'s lock
//! table: modes, the compatibility matrix, enqueue/convert/dequeue,
//! the pending queue with FIFO regrant, and the deadlock scan over
//! the wait-for graph.
//!
//! # Two layers, one converted
//!
//! The engine splits locking across two layers (the paper's
//! lock-manager chapter): the `Lock` OBJECT layer in `jrd/lck.cpp` -
//! typed handles the rest of the engine holds - and the lock TABLE in
//! `src/lock/lock.cpp`, a shared-memory arena of owner blocks (`own`),
//! lock blocks (`lbl`) and request blocks (`lrq`) that arbitrates
//! between processes. This crate converts the TABLE's logic: who may
//! be granted what, who waits, who deadlocks. The arena itself
//! (shared memory, hash chains, the history buffer, blocking-AST
//! delivery across process boundaries) is transport, not policy, and
//! stays unconverted - the policy is what can be wrong in
//! interesting ways, and what the oracle can judge.
//!
//! # The oracle
//!
//! Two, actually. The compatibility matrix is pinned against the
//! ENGINE'S OWN SOURCE - `fclck pin-source` re-parses the
//! `compatibility[LCK_max][LCK_max]` table out of the vendored
//! `lock.cpp` and diffs it cell-by-cell against this crate's copy, so
//! a transcription slip cannot survive. And the grant/deny BEHAVIOR
//! is held against the LIVE engine: `SET TRANSACTION RESERVING <table>
//! FOR <mode>` maps reservation modes straight onto table-lock modes
//! (shared read = SR, shared write = SW, protected read = PR,
//! protected write = PW - `tra.cpp`), so a second connection's
//! `NO WAIT` reservation either succeeds or answers "lock conflict on
//! no wait transaction" exactly as the matrix says. The gate
//! (`qa/lck-reserving-matrix.sh`) holds one mode while probing all
//! four against a real server and compares every cell with
//! [`compatible`]; a live two-session cross-update then produces the
//! engine's deadlock error where [`LockTable`]'s scan finds the same
//! cycle.
//!
//! # What the matrix actually says
//!
//! The famous subtlety: **shared read is compatible with protected
//! write**. PW means "no OTHER writers" - a PW holder tolerates SR
//! readers (they read record versions; MVCC does the isolation), it
//! excludes SW/PW/EX (other writers) and PR ("protected read" =
//! nobody may write, which a PW holder violates). The full table,
//! transcribed from `lock.cpp:150` and pinned there by the gate:
//!
//! ```text
//!            none  null   SR    PR    SW    PW    EX
//!    none     +     +     +     +     +     +     +
//!    null     +     +     +     +     +     +     +
//!    SR       +     +     +     +     +     +     -
//!    PR       +     +     +     +     -     -     -
//!    SW       +     +     +     -     +     -     -
//!    PW       +     +     +     -     -     -     -
//!    EX       +     +     -     -     -     -     -
//! ```
//!
//! `null` locks (LCK_null) conflict with nothing - they exist to KEEP
//! A NAME: an owner holding null retains its interest in the lock
//! (and its right to be told when someone wants it exclusively)
//! without blocking anyone. The engine uses them for existence locks
//! on metadata objects.
//!
//! # The granted-state aggregate
//!
//! The engine does not test a request against every holder. Each lock
//! block keeps per-mode counts (`lbl_counts`) and one aggregate
//! `lbl_state` - the highest granted mode - and the grant test is a
//! single matrix probe: `compatibility[requested][lbl_state]`
//! (`lock.cpp:2228`). That aggregate is SOUND even though matrix rows
//! are not monotone (SW tolerates SW but not PR, and PR < SW
//! numerically), because the granted set is always MUTUALLY
//! compatible: any pair of granted modes that could make "highest"
//! hide a conflict - like {PR, SW} - cannot both be granted in the
//! first place. This crate keeps the same counts, the same aggregate,
//! and the same single-probe test, so its decisions come from the
//! engine's own data structure, not an equivalent reformulation.
//!
//! # Slice 1 boundaries
//!
//! In-process table only (the arena is transport); owners, enqueue
//! with WAIT/NO WAIT, convert, dequeue, FIFO regrant of the pending
//! queue, and the deadlock scan. Slice 2 added OWNER TEARDOWN
//! ([LockTable::purge_owner] - the detach purge, live-verified: a
//! parked reservation proceeds the moment its blocker's attachment
//! dies), LOCK DATA WORDS ([LockTable::write_data]/read_data -
//! holding required to write, anyone reads, absent reads zero; a
//! live transaction lock on this box carries Data: 134 in
//! fb_lock_print) and the BLOCKING SET ([LockTable::blockers] - who
//! would receive the AST). AST delivery, timeouts and the series'
//! semantics ride later slices. A SuperServer finding bounds the
//! structural differential: RELATION locks do not appear in the
//! shared lock table (fb_lock_print shows the cross-process series
//! only), so reservation behavior stays the relation-lock oracle.

use std::collections::BTreeMap;

/// A lock mode - `lock_proto.h:69-76`, values identical. The names
/// read as promises about OTHERS: "shared" tolerates more holders of
/// the same intent, "protected" excludes the opposite intent.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
#[repr(u8)]
pub enum Mode {
    /// LCK_none: no lock - compatible with everything (a request for
    /// nothing always succeeds)
    None_ = 0,
    /// LCK_null: keeps the lock NAME alive without excluding anyone -
    /// the engine's existence-interest lock
    Null = 1,
    /// LCK_SR - shared read: many readers, tolerates writers (MVCC
    /// isolates them), excludes only EX
    SharedRead = 2,
    /// LCK_PR - protected read: "nobody may write while I read"
    ProtectedRead = 3,
    /// LCK_SW - shared write: writers that tolerate each other
    /// (record locks arbitrate below), excludes protected modes
    SharedWrite = 4,
    /// LCK_PW - protected write: "no OTHER writers" - tolerates SR
    /// readers, the reservation mode `isql` calls PROTECTED WRITE
    ProtectedWrite = 5,
    /// LCK_EX - exclusive: nobody else at all (DDL, exclusive attach)
    Exclusive = 6,
}

impl Mode {
    pub const ALL: [Mode; 7] = [
        Mode::None_,
        Mode::Null,
        Mode::SharedRead,
        Mode::ProtectedRead,
        Mode::SharedWrite,
        Mode::ProtectedWrite,
        Mode::Exclusive,
    ];

    /// The engine's short name (fb_lock_print vocabulary).
    pub fn short(self) -> &'static str {
        match self {
            Mode::None_ => "none",
            Mode::Null => "null",
            Mode::SharedRead => "SR",
            Mode::ProtectedRead => "PR",
            Mode::SharedWrite => "SW",
            Mode::ProtectedWrite => "PW",
            Mode::Exclusive => "EX",
        }
    }

    pub fn from_short(s: &str) -> Option<Mode> {
        Mode::ALL.iter().copied().find(|m| m.short().eq_ignore_ascii_case(s))
    }
}

/// `compatibility[LCK_max][LCK_max]` - `lock.cpp:150`, transcribed
/// cell-for-cell (`true` = the two modes may be granted together).
/// `fclck pin-source` re-derives this table from the vendored engine
/// source and diffs it against this constant, so the transcription
/// itself is under differential test.
pub const COMPATIBILITY: [[bool; 7]; 7] = [
    /* none */ [true, true, true, true, true, true, true],
    /* null */ [true, true, true, true, true, true, true],
    /* SR   */ [true, true, true, true, true, true, false],
    /* PR   */ [true, true, true, true, false, false, false],
    /* SW   */ [true, true, true, false, true, false, false],
    /* PW   */ [true, true, true, false, false, false, false],
    /* EX   */ [true, true, false, false, false, false, false],
];

/// May `requested` be granted while `held` is granted?
pub fn compatible(requested: Mode, held: Mode) -> bool {
    COMPATIBILITY[requested as usize][held as usize]
}

/// An owner id - the engine's `own` block, reduced to a handle. One
/// owner per attachment (or per transaction, per the series' choice);
/// the table only needs identity.
pub type OwnerId = u32;

/// A granted or pending request - the engine's `lrq` block.
#[derive(Clone, Debug)]
struct Request {
    owner: OwnerId,
    mode: Mode,
}

/// One lock block (`lbl`): the granted requests with their per-mode
/// counts and aggregate state, and the pending queue in arrival
/// order. Keyed by (series, key) in the table - the block itself
/// does not interpret either.
#[derive(Default)]
struct LockBlock {
    /// `lbl_data`: the lock's data word - a value an owner HOLDING
    /// the lock may stamp (LCK_write_data) and any owner may read;
    /// the nbackup state lock's side channel, and live on this box:
    /// a transaction lock carrying Data: 134 in fb_lock_print
    data: u64,
    granted: Vec<Request>,
    /// `lbl_counts`: how many granted requests hold each mode
    counts: [u32; 7],
    /// the FIFO pending queue - regrant walks it IN ORDER and stops
    /// granting nothing out of turn
    pending: Vec<Request>,
}

impl LockBlock {
    /// `lbl_state`: the highest granted mode - sound as a single
    /// aggregate because granted modes are mutually compatible (see
    /// the crate docs).
    fn state(&self) -> Mode {
        for m in Mode::ALL.iter().rev() {
            if self.counts[*m as usize] > 0 {
                return *m;
            }
        }
        Mode::None_
    }

    /// The aggregate EXCLUDING one owner's contribution - what
    /// `convert` tests against ("would my new mode be compatible with
    /// everyone else").
    fn state_excluding(&self, owner: OwnerId) -> Mode {
        let mut counts = self.counts;
        for r in &self.granted {
            if r.owner == owner {
                counts[r.mode as usize] -= 1;
            }
        }
        for m in Mode::ALL.iter().rev() {
            if counts[*m as usize] > 0 {
                return *m;
            }
        }
        Mode::None_
    }
}

/// The verdict of an enqueue or convert.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Verdict {
    /// granted immediately
    Granted,
    /// incompatible and `wait` was set: the request sits in the
    /// pending queue (the caller would block; a later dequeue may
    /// regrant it - poll with [LockTable::is_granted])
    Waiting,
    /// incompatible and NO WAIT: the request was refused and leaves
    /// no trace - the engine's "lock conflict on no wait transaction"
    Rejected,
    /// waiting would close a cycle in the wait-for graph: the
    /// engine's deadlock scan denies the request instead of letting
    /// it wait forever
    Deadlock,
}

/// The lock table - `LockManager`'s policy core: lock blocks by
/// (series, key), the grant/wait/deadlock decisions, and the FIFO
/// regrant walk. Single arena, in process; identity is [OwnerId].
#[derive(Default)]
pub struct LockTable {
    locks: BTreeMap<(u8, Vec<u8>), LockBlock>,
    next_owner: OwnerId,
}

impl LockTable {
    pub fn new() -> LockTable {
        LockTable::default()
    }

    /// A fresh owner (`create_owner` - one per attachment).
    pub fn create_owner(&mut self) -> OwnerId {
        self.next_owner += 1;
        self.next_owner
    }

    /// LCK_lock / `enqueue`: request `mode` on (series, key). The
    /// grant test is the engine's single probe against the aggregate
    /// (`lock.cpp:2228`); an incompatible WAIT request joins the
    /// pending queue unless waiting would deadlock, an incompatible
    /// NO WAIT request is refused outright.
    pub fn enqueue(
        &mut self,
        owner: OwnerId,
        series: u8,
        key: &[u8],
        mode: Mode,
        wait: bool,
    ) -> Verdict {
        let lock = self.locks.entry((series, key.to_vec())).or_default();
        // a pending queue in front of us also blocks the grant: FIFO
        // fairness - the engine grants no one out of turn once
        // someone compatible-with-nothing is parked (post_pending
        // walks in order)
        let blocked_by_queue = lock
            .pending
            .iter()
            .any(|p| !compatible(mode, p.mode) || !compatible(p.mode, mode));
        if compatible(mode, lock.state()) && !blocked_by_queue {
            lock.granted.push(Request { owner, mode });
            lock.counts[mode as usize] += 1;
            return Verdict::Granted;
        }
        if !wait {
            return Verdict::Rejected;
        }
        lock.pending.push(Request { owner, mode });
        if self.deadlock_from(owner) {
            // the scan found a cycle through us: withdraw the request
            // and report the deadlock (the engine errors the scanning
            // request - the victim is the one that would have waited)
            let lock = self.locks.get_mut(&(series, key.to_vec())).expect("just used");
            let pos = lock
                .pending
                .iter()
                .rposition(|p| p.owner == owner && p.mode == mode)
                .expect("just pushed");
            lock.pending.remove(pos);
            return Verdict::Deadlock;
        }
        Verdict::Waiting
    }

    /// LCK_convert: change an owner's granted mode on a lock. The
    /// test runs against everyone ELSE's aggregate (`lock.cpp:2535`
    /// takes the state with this request's own contribution removed).
    /// A NO WAIT convert that fails leaves the old grant standing.
    pub fn convert(
        &mut self,
        owner: OwnerId,
        series: u8,
        key: &[u8],
        new_mode: Mode,
        wait: bool,
    ) -> Verdict {
        let Some(lock) = self.locks.get_mut(&(series, key.to_vec())) else {
            return Verdict::Rejected;
        };
        let Some(pos) = lock.granted.iter().position(|r| r.owner == owner) else {
            return Verdict::Rejected;
        };
        let others = lock.state_excluding(owner);
        if compatible(new_mode, others) {
            let old = lock.granted[pos].mode;
            lock.counts[old as usize] -= 1;
            lock.granted[pos].mode = new_mode;
            lock.counts[new_mode as usize] += 1;
            return Verdict::Granted;
        }
        if !wait {
            return Verdict::Rejected;
        }
        lock.pending.push(Request { owner, mode: new_mode });
        if self.deadlock_from(owner) {
            let lock = self.locks.get_mut(&(series, key.to_vec())).expect("just used");
            let pos = lock
                .pending
                .iter()
                .rposition(|p| p.owner == owner && p.mode == new_mode)
                .expect("just pushed");
            lock.pending.remove(pos);
            return Verdict::Deadlock;
        }
        Verdict::Waiting
    }

    /// LCK_release / `dequeue`: drop an owner's granted request on a
    /// lock, then walk the pending queue IN ORDER regranting every
    /// request the new state admits - stopping the walk grants
    /// nothing out of turn past a still-blocked head... exactly the
    /// engine's post_pending sweep.
    pub fn dequeue(&mut self, owner: OwnerId, series: u8, key: &[u8]) {
        let Some(lock) = self.locks.get_mut(&(series, key.to_vec())) else {
            return;
        };
        if let Some(pos) = lock.granted.iter().position(|r| r.owner == owner) {
            let mode = lock.granted.remove(pos).mode;
            lock.counts[mode as usize] -= 1;
        }
        // FIFO regrant
        loop {
            let Some(head) = lock.pending.first().cloned() else { break };
            if compatible(head.mode, lock.state()) {
                lock.pending.remove(0);
                lock.counts[head.mode as usize] += 1;
                lock.granted.push(head);
            } else {
                break;
            }
        }
        if lock.granted.is_empty() && lock.pending.is_empty() {
            self.locks.remove(&(series, key.to_vec()));
        }
    }

    /// Is this owner's request granted on (series, key)? (How a
    /// caller polls a [Verdict::Waiting] request after releases.)
    pub fn is_granted(&self, owner: OwnerId, series: u8, key: &[u8]) -> bool {
        self.locks
            .get(&(series, key.to_vec()))
            .map(|l| l.granted.iter().any(|r| r.owner == owner))
            .unwrap_or(false)
    }

    /// Owner teardown - the engine's purge on detach: every granted
    /// and pending request the owner holds comes down, and every
    /// affected lock regrants its queue FIFO (the release path run
    /// once per lock). Returns how many grants were released.
    pub fn purge_owner(&mut self, owner: OwnerId) -> usize {
        let keys: Vec<(u8, Vec<u8>)> = self.locks.keys().cloned().collect();
        let mut released = 0;
        for (series, key) in keys {
            let Some(lock) = self.locks.get_mut(&(series, key.clone())) else {
                continue;
            };
            lock.pending.retain(|p| p.owner != owner);
            let before = lock.granted.len();
            // dequeue re-runs the FIFO regrant per removal; an owner
            // may hold at most one grant per lock in this table
            if lock.granted.iter().any(|r| r.owner == owner) {
                self.dequeue(owner, series, &key);
                released += 1;
            } else {
                let _ = before;
                if lock.granted.is_empty() && lock.pending.is_empty() {
                    self.locks.remove(&(series, key));
                }
            }
        }
        released
    }

    /// LCK_write_data: stamp the lock's data word. The engine
    /// requires the writer to HOLD the lock - so does this.
    pub fn write_data(
        &mut self,
        owner: OwnerId,
        series: u8,
        key: &[u8],
        data: u64,
    ) -> Result<(), String> {
        let lock = self
            .locks
            .get_mut(&(series, key.to_vec()))
            .ok_or("no such lock")?;
        if !lock.granted.iter().any(|r| r.owner == owner) {
            return Err("data writes require holding the lock".into());
        }
        lock.data = data;
        Ok(())
    }

    /// LCK_read_data: any owner may read the word; an absent lock
    /// reads zero (the engine's convention - data outlives no lock).
    pub fn read_data(&self, series: u8, key: &[u8]) -> u64 {
        self.locks
            .get(&(series, key.to_vec()))
            .map(|l| l.data)
            .unwrap_or(0)
    }

    /// The blocking set: the owners whose GRANTED requests are
    /// incompatible with this owner's PENDING request on the lock -
    /// exactly who would receive the blocking AST when delivery
    /// exists. Empty when the owner is not waiting there.
    pub fn blockers(&self, owner: OwnerId, series: u8, key: &[u8]) -> Vec<OwnerId> {
        let Some(lock) = self.locks.get(&(series, key.to_vec())) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for p in lock.pending.iter().filter(|p| p.owner == owner) {
            for g in &lock.granted {
                if g.owner != owner
                    && !compatible(p.mode, g.mode)
                    && !out.contains(&g.owner)
                {
                    out.push(g.owner);
                }
            }
        }
        out
    }

    /// The deadlock scan: does a wait-for cycle pass through `start`?
    /// An owner with a PENDING request waits for every owner whose
    /// GRANTED request on the same lock is incompatible with it - the
    /// engine walks these edges (lrq → lbl → granted lrq → own) with
    /// a visited mark; a path back to the starting owner is a
    /// deadlock, and the starting request is the victim.
    fn deadlock_from(&self, start: OwnerId) -> bool {
        let mut stack = vec![start];
        let mut seen = Vec::new();
        let mut first = true;
        while let Some(owner) = stack.pop() {
            if !first && owner == start {
                return true;
            }
            first = false;
            if seen.contains(&owner) {
                continue;
            }
            seen.push(owner);
            for lock in self.locks.values() {
                for p in lock.pending.iter().filter(|p| p.owner == owner) {
                    for g in &lock.granted {
                        if g.owner != owner && !compatible(p.mode, g.mode) {
                            stack.push(g.owner);
                        }
                    }
                }
            }
        }
        false
    }
}

/// Parse the engine's own `compatibility[LCK_max][LCK_max]` table out
/// of `lock.cpp` source text - the source oracle behind `fclck
/// pin-source`. Returns the 7x7 cells in declaration order.
pub fn parse_engine_matrix(source: &str) -> Result<[[bool; 7]; 7], String> {
    let start = source
        .find("compatibility[LCK_max][LCK_max]")
        .ok_or("no compatibility table in this source")?;
    let body = &source[start..];
    let end = body.find("};").ok_or("table does not close")?;
    let mut cells = Vec::new();
    let mut token = String::new();
    for ch in body[..end].chars() {
        if ch.is_ascii_alphabetic() {
            token.push(ch);
        } else {
            match token.as_str() {
                "true" => cells.push(true),
                "false" => cells.push(false),
                _ => {}
            }
            token.clear();
        }
    }
    if cells.len() != 49 {
        return Err(format!("expected 49 cells, found {}", cells.len()));
    }
    let mut out = [[false; 7]; 7];
    for (i, c) in cells.iter().enumerate() {
        out[i / 7][i % 7] = *c;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use Mode::*;

    const REL: u8 = 3; // the relation series - opaque to the table

    #[test]
    fn matrix_pins() {
        // the famous cell: shared read tolerates protected write
        assert!(compatible(SharedRead, ProtectedWrite));
        assert!(compatible(ProtectedWrite, SharedRead));
        // ...but protected READ does not tolerate writers
        assert!(!compatible(ProtectedRead, SharedWrite));
        assert!(!compatible(ProtectedRead, ProtectedWrite));
        // writers tolerate each other only in shared mode
        assert!(compatible(SharedWrite, SharedWrite));
        assert!(!compatible(ProtectedWrite, ProtectedWrite));
        // null conflicts with nothing, EX with everything but n/n
        for m in Mode::ALL {
            assert!(compatible(Null, m));
            assert_eq!(compatible(Exclusive, m), matches!(m, None_ | Null));
        }
    }

    #[test]
    fn matrix_is_symmetric() {
        for a in Mode::ALL {
            for b in Mode::ALL {
                assert_eq!(compatible(a, b), compatible(b, a), "{:?}/{:?}", a, b);
            }
        }
    }

    #[test]
    fn grant_wait_reject() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T", ProtectedWrite, false), Verdict::Granted);
        // SR rides beside PW; SW conflicts
        assert_eq!(t.enqueue(b, REL, b"T", SharedRead, false), Verdict::Granted);
        assert_eq!(t.enqueue(b, REL, b"U", SharedWrite, false), Verdict::Granted);
        assert_eq!(t.enqueue(b, REL, b"T", SharedWrite, false), Verdict::Rejected);
        assert_eq!(t.enqueue(b, REL, b"T", SharedWrite, true), Verdict::Waiting);
    }

    #[test]
    fn dequeue_regrants_fifo() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        let c = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T", Exclusive, false), Verdict::Granted);
        assert_eq!(t.enqueue(b, REL, b"T", ProtectedWrite, true), Verdict::Waiting);
        assert_eq!(t.enqueue(c, REL, b"T", SharedRead, true), Verdict::Waiting);
        t.dequeue(a, REL, b"T");
        // the queue regrants IN ORDER: PW first, then SR (compatible
        // with PW) rides along
        assert!(t.is_granted(b, REL, b"T"));
        assert!(t.is_granted(c, REL, b"T"));
    }

    #[test]
    fn fifo_blocks_late_compatible_requests_behind_the_queue() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        let c = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T", SharedWrite, false), Verdict::Granted);
        // b waits for PR (conflicts with SW)
        assert_eq!(t.enqueue(b, REL, b"T", ProtectedRead, true), Verdict::Waiting);
        // c's SW would be compatible with a's SW - but granting it
        // would starve b: the queue blocks it
        assert_eq!(t.enqueue(c, REL, b"T", SharedWrite, false), Verdict::Rejected);
    }

    #[test]
    fn convert_tests_against_the_others_only() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T", SharedRead, false), Verdict::Granted);
        assert_eq!(t.enqueue(b, REL, b"T", SharedRead, false), Verdict::Granted);
        // SR -> PW succeeds beside an SR holder (the subtle cell)...
        assert_eq!(t.convert(a, REL, b"T", ProtectedWrite, false), Verdict::Granted);
        // ...but the other SR cannot ALSO become a writer now
        assert_eq!(t.convert(b, REL, b"T", SharedWrite, false), Verdict::Rejected);
        // and the failed no-wait convert left b's SR standing
        assert!(t.is_granted(b, REL, b"T"));
    }

    #[test]
    fn deadlock_two_owner_cycle() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T1", ProtectedWrite, false), Verdict::Granted);
        assert_eq!(t.enqueue(b, REL, b"T2", ProtectedWrite, false), Verdict::Granted);
        // a waits for T2 (held by b) - fine so far
        assert_eq!(t.enqueue(a, REL, b"T2", ProtectedWrite, true), Verdict::Waiting);
        // b waiting for T1 would close the cycle: the scan denies it
        assert_eq!(t.enqueue(b, REL, b"T1", ProtectedWrite, true), Verdict::Deadlock);
        // the victim's request left no trace; a still waits, and
        // releasing T2 regrants it
        t.dequeue(b, REL, b"T2");
        assert!(t.is_granted(a, REL, b"T2"));
    }

    #[test]
    fn purge_regrants_the_queue() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        let c = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T", Exclusive, false), Verdict::Granted);
        assert_eq!(t.enqueue(b, REL, b"T", SharedWrite, true), Verdict::Waiting);
        assert_eq!(t.enqueue(a, REL, b"U", SharedRead, false), Verdict::Granted);
        // a detaches: everything it held comes down, b's wait grants
        assert_eq!(t.purge_owner(a), 2);
        assert!(t.is_granted(b, REL, b"T"));
        assert!(!t.is_granted(a, REL, b"U"));
        // c never waits on anything a held
        assert_eq!(t.enqueue(c, REL, b"U", Exclusive, false), Verdict::Granted);
    }

    #[test]
    fn lock_data_requires_holding() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T", SharedRead, false), Verdict::Granted);
        // a holds - the stamp lands; b does not - refused
        assert!(t.write_data(a, REL, b"T", 134).is_ok());
        assert!(t.write_data(b, REL, b"T", 7).is_err());
        // anyone reads; an absent lock reads zero
        assert_eq!(t.read_data(REL, b"T"), 134);
        assert_eq!(t.read_data(REL, b"NONE"), 0);
    }

    #[test]
    fn blockers_name_the_ast_targets() {
        let mut t = LockTable::new();
        let a = t.create_owner();
        let b = t.create_owner();
        let c = t.create_owner();
        assert_eq!(t.enqueue(a, REL, b"T", SharedWrite, false), Verdict::Granted);
        assert_eq!(t.enqueue(b, REL, b"T", SharedWrite, false), Verdict::Granted);
        assert_eq!(t.enqueue(c, REL, b"T", ProtectedRead, true), Verdict::Waiting);
        // both shared writers would get the knock; nobody blocks a
        // non-waiter
        assert_eq!(t.blockers(c, REL, b"T"), vec![a, b]);
        assert!(t.blockers(a, REL, b"T").is_empty());
        // one releases: still blocked by the other alone
        t.dequeue(a, REL, b"T");
        assert_eq!(t.blockers(c, REL, b"T"), vec![b]);
        // the last releases: c grants, no blockers remain
        t.dequeue(b, REL, b"T");
        assert!(t.is_granted(c, REL, b"T"));
        assert!(t.blockers(c, REL, b"T").is_empty());
    }

    #[test]
    fn parses_the_engine_table_shape() {
        let src = "static constexpr bool compatibility[LCK_max][LCK_max] =\n{\
            {true,true,true,true,true,true,true},\
            {true,true,true,true,true,true,true},\
            {true,true,true,true,true,true,false},\
            {true,true,true,true,false,false,false},\
            {true,true,true,false,true,false,false},\
            {true,true,true,false,false,false,false},\
            {true,true,false,false,false,false,false}};";
        assert_eq!(parse_engine_matrix(src).unwrap(), COMPATIBILITY);
    }
}
