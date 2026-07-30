//! The lock table's SHARED MEMORY, converted from `src/lock/lock_proto.h`
//! and dumped in `fb_lock_print`'s own text (`src/lock/print.cpp`).
//!
//! [`crate`]'s first slice converted the lock manager's POLICY - the
//! compatibility matrix, the queues, the verdicts - as an in-process
//! model. This module converts the other half: the actual bytes several
//! processes share, which live in a file the engine maps
//! (`/tmp/firebird/fb_lock_<id>` on Linux, the "lock directory").
//!
//! Why that is worth converting: it turns the lock manager from a model
//! into an OBSERVABLE. `fb_lock_print` prints that memory as text, so
//! fire-crab can decode the same bytes and its dump must match the
//! engine's tool word for word - and both can be pointed at the SAME
//! SNAPSHOT (`cp` the file, then `fb_lock_print -f snapshot`), which makes
//! the comparison exact rather than approximate on a table that changes
//! while you read it.
//!
//! # Self-relative queues
//!
//! Every pointer in this memory is a byte OFFSET from the start of the
//! table (`SRQ_PTR`, `src/jrd/que.h:108`), never an address - it has to
//! be, because each process maps the region at a different place. A queue
//! is two such offsets (`srq`: forward, backward), and the queue field
//! sits INSIDE the block it links, so walking from a queue to its block
//! means subtracting the field's offset within the struct. That is why
//! `fb_lock_print` prints `forward: 78392` where the raw queue holds
//! 78408: it prints the BLOCK, having subtracted
//! `offsetof(own, own_lhb_owners)` = 16 (`prt_que`, print.cpp).
//!
//! # This layout is BUILD-specific, not just platform-specific
//!
//! `own` embeds a `Firebird::event_t`, which on Unix embeds a
//! `pthread_mutex_t` and a `pthread_cond_t`. Their sizes come from the C
//! library, so the offset of `own_flags` depends on the platform's
//! pthread implementation - Linux/aarch64 and Linux/x86-64 agree (48 + 48)
//! but nothing guarantees that in general. A lock table is therefore not
//! portable between builds, which is fine for the engine (only one build
//! ever maps it) and is a fact a converter must know rather than
//! discover. [`EVENT_T_SIZE`] is where that assumption lives.
//!
//! Every offset below was derived from the structs and then VERIFIED
//! against `fb_lock_print`'s own numbers on a live table - version 148,
//! length 1048576, used 90232, 8191 hash slots, owner id 2804613644298 at
//! block 78392, and so on.

/// `sizeof(Firebird::MemoryHeader)` (isc_s_proto.h:132-175): the type,
/// header version, version and flags words, an 8-byte timestamp, and a
/// 64-byte union sized to make the header OS-independent.
pub const MEMORY_HEADER_SIZE: usize = 80;

/// `sizeof(Firebird::event_t)` on Linux: `SLONG event_count`,
/// `int event_pid`, `pthread_mutex_t[1]`, `pthread_cond_t[1]` - 4 + 4 +
/// 48 + 48, with the struct 8-byte aligned. See the note above: this is
/// the one number in this module that is a property of libc rather than
/// of Firebird.
pub const EVENT_T_SIZE: usize = 104;

/// Memory tags (`fb_blk.h`), checked so a wrong file is refused rather
/// than decoded into nonsense.
pub mod tag {
    pub const LHB: u8 = 1;
    pub const OWN: u8 = 6;
    pub const PRC: u8 = 7;
}

/// `own_flags` (lock_proto.h:245-247).
pub mod own_flags {
    pub const SCANNED: u16 = 1;
    pub const WAKEUP: u16 = 2;
    pub const SIGNALED: u16 = 4;
}

fn u8_at(b: &[u8], o: usize) -> u8 {
    b.get(o).copied().unwrap_or(0)
}
fn u16_at(b: &[u8], o: usize) -> u16 {
    if o + 2 > b.len() {
        return 0;
    }
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn i32_at(b: &[u8], o: usize) -> i32 {
    if o + 4 > b.len() {
        return 0;
    }
    i32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn u32_at(b: &[u8], o: usize) -> u32 {
    i32_at(b, o) as u32
}
fn u64_at(b: &[u8], o: usize) -> u64 {
    if o + 8 > b.len() {
        return 0;
    }
    let mut v = [0u8; 8];
    v.copy_from_slice(&b[o..o + 8]);
    u64::from_le_bytes(v)
}

/// A self-relative queue: two offsets into the table.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Srq {
    pub forward: i32,
    pub backward: i32,
}

impl Srq {
    fn at(b: &[u8], o: usize) -> Srq {
        Srq {
            forward: i32_at(b, o),
            backward: i32_at(b, o + 4),
        }
    }
    /// A queue whose two ends point at itself is empty (`SRQ_EMPTY`).
    pub fn is_empty(&self, own_offset: i32) -> bool {
        self.forward == own_offset && self.backward == own_offset
    }
}

/// Field offsets inside `lhb`, past the `MemoryHeader` base
/// (lock_proto.h:108-147). `SRQ_PTR` is `SLONG` and `srq` is two of them,
/// so the arithmetic is mechanical; the 8-byte counters force one pad
/// after `lhb_acquire_spins`.
mod lhb_off {
    use super::MEMORY_HEADER_SIZE as H;
    pub const TYPE: usize = H; // USHORT lhb_type
    pub const SECONDARY: usize = H + 4;
    pub const ACTIVE_OWNER: usize = H + 8;
    pub const OWNERS: usize = H + 12;
    pub const PROCESSES: usize = H + 20;
    pub const FREE_PROCESSES: usize = H + 28;
    pub const FREE_OWNERS: usize = H + 36;
    pub const FREE_LOCKS: usize = H + 44;
    pub const FREE_REQUESTS: usize = H + 52;
    pub const LENGTH: usize = H + 60;
    pub const USED: usize = H + 64;
    pub const HASH_SLOTS: usize = H + 68;
    pub const HISTORY: usize = H + 72;
    pub const SCAN_INTERVAL: usize = H + 76;
    pub const ACQUIRE_SPINS: usize = H + 80;
    // The FB_UINT64 run starts 8-byte aligned, i.e. after one pad word,
    // and then it is just counting - but counting CAREFULLY: the run has
    // eleven scalars, then `lhb_operations[LCK_MAX_SERIES]` (6 x 8 bytes),
    // then seven more scalars. Miscounting inside it is invisible for any
    // field that happens to be zero, which is most of them on a quiet
    // table - the two that caught it were `lhb_scans` and `lhb_deadlocks`,
    // whose wrong offsets read into the hash table and printed garbage.
    pub const ACQUIRES: usize = H + 88;
    pub const ACQUIRE_BLOCKS: usize = H + 96;
    // acquire_retries H+104, retry_success H+112
    pub const ENQS: usize = H + 120;
    pub const CONVERTS: usize = H + 128;
    // downgrades H+136, deqs H+144, read_data H+152, write_data H+160,
    // query_data H+168, operations[6] H+176..H+224, waits H+224
    pub const DENIES: usize = H + 232;
    // timeouts H+240
    pub const BLOCKS: usize = H + 248;
    // wakeups H+256
    pub const SCANS: usize = H + 264;
    pub const DEADLOCKS: usize = H + 272;
    /// `srq lhb_data[LCK_MAX_SERIES]` then `srq lhb_hash[1]`
    pub const DATA: usize = H + 280;
    pub const HASH: usize = H + 280 + 8 * super::LCK_MAX_SERIES;
}

/// `LCK_MAX_SERIES` (lock_proto.h:56).
pub const LCK_MAX_SERIES: usize = 6;

/// Field offsets inside an `own` block (lock_proto.h:196-214), with
/// `ThreadId` = `int` on this build.
mod own_off {
    pub const TYPE: usize = 0;
    pub const OWNER_TYPE: usize = 1;
    pub const COUNT: usize = 2;
    pub const OWNER_ID: usize = 8; // LOCK_OWNER_T, 8-byte aligned
    pub const LHB_OWNERS: usize = 16;
    pub const PRC_OWNERS: usize = 24;
    pub const REQUESTS: usize = 32;
    pub const BLOCKS: usize = 40;
    pub const PENDING: usize = 48;
    pub const PROCESS: usize = 56;
    pub const THREAD_ID: usize = 60;
    pub const ACQUIRE_TIME: usize = 64;
    pub const WAITS: usize = 72;
    pub const AST_COUNT: usize = 74;
    pub const WAKEUP: usize = 80; // event_t, 8-byte aligned
    pub const FLAGS: usize = WAKEUP + super::EVENT_T_SIZE;
}

/// Field offsets inside an `lbl` (lock) block (lock_proto.h:164-178).
mod lbl_off {
    pub const TYPE: usize = 0;
    pub const STATE: usize = 1;
    pub const SIZE: usize = 2;
    pub const LENGTH: usize = 3;
    pub const REQUESTS: usize = 4;
    pub const LHB_HASH: usize = 12;
    pub const LHB_DATA: usize = 20;
    /// `LOCK_DATA_T` is SINT64, so it aligns to 8 - leaving a pad after
    /// the third queue
    pub const DATA: usize = 32;
    pub const SERIES: usize = 40;
    pub const FLAGS: usize = 41;
    pub const PENDING_LRQ_COUNT: usize = 42;
    /// `lbl_counts[LCK_max]` - seven USHORTs
    pub const COUNTS: usize = 44;
    pub const KEY: usize = 58;
}

/// Field offsets inside an `lrq` (request) block (lock_proto.h:182-197).
mod lrq_off {
    pub const TYPE: usize = 0;
    pub const REQUESTED: usize = 1;
    pub const STATE: usize = 2;
    /// USHORT after three bytes: aligned to 4
    pub const FLAGS: usize = 4;
    pub const OWNER: usize = 8;
    pub const LOCK: usize = 12;
    /// SINT64, 8-byte aligned
    pub const DATA: usize = 16;
    pub const OWN_REQUESTS: usize = 24;
    pub const LBL_REQUESTS: usize = 32;
    pub const OWN_BLOCKS: usize = 40;
    pub const OWN_PENDING: usize = 48;
}

/// `LCK_max` (lock_proto.h:76) - the width of `lbl_counts`, not the number
/// of lock SERIES (which runs past thirty).
pub const LCK_MAX: usize = 7;

/// The queue-field offsets `prt_que` subtracts to print a BLOCK's offset
/// rather than the queue node's (print.cpp).
///
/// Three of these were WRONG in the first version of this module, shifted
/// by one field, and every gate passed anyway - because the queues they
/// belong to (`Blocks`, `Pending`, `Free requests`) are EMPTY on a server
/// with no contention, and an empty queue prints `*empty*` with no offset
/// to be wrong about. They are right now, and `qa/lck-table-dump.sh` makes
/// a real waiter block on a `PROTECTED WRITE` reservation so the pending
/// queue is populated when the dumps are compared.
pub mod que_field {
    /// `offsetof(own, own_lhb_owners)`
    pub const OWN_LHB_OWNERS: i32 = super::own_off::LHB_OWNERS as i32;
    /// `offsetof(lrq, lrq_own_requests)`
    pub const LRQ_OWN_REQUESTS: i32 = super::lrq_off::OWN_REQUESTS as i32;
    /// `offsetof(lrq, lrq_own_blocks)`
    pub const LRQ_OWN_BLOCKS: i32 = super::lrq_off::OWN_BLOCKS as i32;
    /// `offsetof(lrq, lrq_own_pending)`
    pub const LRQ_OWN_PENDING: i32 = super::lrq_off::OWN_PENDING as i32;
    /// `offsetof(lbl, lbl_lhb_hash)`
    pub const LBL_LHB_HASH: i32 = super::lbl_off::LHB_HASH as i32;
    /// `offsetof(lrq, lrq_lbl_requests)`
    pub const LRQ_LBL_REQUESTS: i32 = super::lrq_off::LBL_REQUESTS as i32;
}

/// Lock series (`lck_t`, jrd/lck.h:45+, starting at 1). Only the ones whose
/// KEY the dump formats specially are named; the rest are printed by
/// number, exactly as the engine does.
pub mod series {
    // `enum lck_t : UCHAR { LCK_database = 1, ... }` - the values are
    // positions in that enum, so counting them off a listing is exactly
    // where an off-by-one comes from. These were checked against a live
    // dump: series 22 is the one whose 4-byte key prints split as
    // `0004:0000`, which is LCK_idx_rescan.
    pub const DATABASE: u8 = 1;
    pub const RELATION: u8 = 2;
    pub const BDB: u8 = 3;
    pub const TRA: u8 = 4;
    pub const ATTACHMENT: u8 = 5;
    pub const MONITOR: u8 = 14;
    pub const CANCEL: u8 = 15;
    pub const BTR_DONT_GC: u8 = 16;
    pub const REL_GC: u8 = 17;
    pub const IDX_RESCAN: u8 = 22;
    pub const RECORD_GC: u8 = 29;
}

/// The lock header block.
#[derive(Clone, Debug)]
pub struct Lhb {
    pub version: u16,
    /// `mhb_timestamp`: an ISC timestamp (MJD days, 1/10000 s)
    pub timestamp: (i32, u32),
    pub active_owner: i32,
    pub length: u32,
    pub used: u32,
    pub hash_slots: u16,
    pub scan_interval: u32,
    pub acquire_spins: u32,
    pub acquires: u64,
    pub acquire_blocks: u64,
    pub enqs: u64,
    pub converts: u64,
    pub denies: u64,
    pub blocks: u64,
    pub scans: u64,
    pub deadlocks: u64,
    pub secondary: i32,
    pub owners: Srq,
    pub free_owners: Srq,
    pub free_locks: Srq,
    pub free_requests: Srq,
}

impl Lhb {
    pub fn decode(b: &[u8]) -> Result<Lhb, String> {
        if b.len() < MEMORY_HEADER_SIZE + 400 {
            return Err(format!("{} bytes is too short for a lock table", b.len()));
        }
        let tag = u16_at(b, lhb_off::TYPE);
        if tag != tag::LHB as u16 {
            return Err(format!(
                "not a lock table: block type {} where type_lhb ({}) was expected",
                tag,
                tag::LHB
            ));
        }
        Ok(Lhb {
            version: u16_at(b, 4), // mhb_version
            timestamp: (i32_at(b, 8), u32_at(b, 12)),
            active_owner: i32_at(b, lhb_off::ACTIVE_OWNER),
            length: u32_at(b, lhb_off::LENGTH),
            used: u32_at(b, lhb_off::USED),
            hash_slots: u16_at(b, lhb_off::HASH_SLOTS),
            scan_interval: u32_at(b, lhb_off::SCAN_INTERVAL),
            acquire_spins: u32_at(b, lhb_off::ACQUIRE_SPINS),
            acquires: u64_at(b, lhb_off::ACQUIRES),
            acquire_blocks: u64_at(b, lhb_off::ACQUIRE_BLOCKS),
            enqs: u64_at(b, lhb_off::ENQS),
            converts: u64_at(b, lhb_off::CONVERTS),
            denies: u64_at(b, lhb_off::DENIES),
            blocks: u64_at(b, lhb_off::BLOCKS),
            scans: u64_at(b, lhb_off::SCANS),
            deadlocks: u64_at(b, lhb_off::DEADLOCKS),
            secondary: i32_at(b, lhb_off::SECONDARY),
            owners: Srq::at(b, lhb_off::OWNERS),
            free_owners: Srq::at(b, lhb_off::FREE_OWNERS),
            free_locks: Srq::at(b, lhb_off::FREE_LOCKS),
            free_requests: Srq::at(b, lhb_off::FREE_REQUESTS),
        })
    }
}

/// One owner block.
#[derive(Clone, Debug)]
pub struct Own {
    /// this block's own offset in the table (what the dump labels it with)
    pub offset: i32,
    pub owner_id: u64,
    pub owner_type: u8,
    pub process: i32,
    pub thread_id: u32,
    pub flags: u16,
    pub requests: Srq,
    pub blocks: Srq,
    pub pending: Srq,
}

impl Own {
    fn decode(b: &[u8], at: i32) -> Result<Own, String> {
        let o = at as usize;
        if u8_at(b, o + own_off::TYPE) != tag::OWN {
            return Err(format!(
                "block at {} is type {}, not type_own ({})",
                at,
                u8_at(b, o + own_off::TYPE),
                tag::OWN
            ));
        }
        Ok(Own {
            offset: at,
            owner_id: u64_at(b, o + own_off::OWNER_ID),
            owner_type: u8_at(b, o + own_off::OWNER_TYPE),
            process: i32_at(b, o + own_off::PROCESS),
            thread_id: u32_at(b, o + own_off::THREAD_ID),
            flags: u16_at(b, o + own_off::FLAGS),
            requests: Srq::at(b, o + own_off::REQUESTS),
            blocks: Srq::at(b, o + own_off::BLOCKS),
            pending: Srq::at(b, o + own_off::PENDING),
        })
    }
}

/// Walk a self-relative queue whose nodes sit `field` bytes into their
/// blocks, returning the BLOCK offsets in order.
///
/// Bounded by the table's own size: a queue can hold at most one node per
/// 8 bytes of table, so that count is a hard upper limit on a walk. The
/// bound is not paranoia - a snapshot of LIVE shared memory can catch a
/// queue mid-update, with a node pointing at itself or past the end, and a
/// dump must still terminate and still print something useful.
pub fn walk_queue(b: &[u8], head: usize, field: i32) -> Vec<i32> {
    let mut out = Vec::new();
    let head_ptr = head as i32;
    let limit = b.len() / 8;
    let mut at = i32_at(b, head);
    while at != head_ptr && out.len() < limit {
        if at < 0 || at as usize + 8 > b.len() {
            break;
        }
        out.push(at - field);
        let next = i32_at(b, at as usize);
        if next == at {
            break; // a node pointing at itself: a torn snapshot
        }
        at = next;
    }
    out
}

/// The hash-length statistics `fb_lock_print` prints: (min, avg, max) and
/// the distribution capped at 21 buckets (print.cpp:795-833).
pub struct HashStats {
    pub min: i64,
    pub avg: i64,
    pub max: i64,
    pub distribution: Vec<u32>,
}

const MAX_MAX_COUNT_STATS: usize = 21;

pub fn hash_stats(b: &[u8], h: &Lhb) -> HashStats {
    let mut total = 0i64;
    let mut max = 0i64;
    let mut min = 10_000_000i64;
    let mut dist = vec![0u32; MAX_MAX_COUNT_STATS];
    for i in 0..h.hash_slots as usize {
        let slot = lhb_off::HASH + i * 8;
        let mut n = 0i64;
        let head = slot as i32;
        let mut at = i32_at(b, slot);
        let limit = (b.len() / 8) as i64;
        while at != head && n < limit {
            if at < 0 || at as usize + 8 > b.len() {
                break;
            }
            total += 1;
            n += 1;
            let next = i32_at(b, at as usize);
            if next == at {
                break;
            }
            at = next;
        }
        if n < min {
            min = n;
        }
        if n > max {
            max = n;
        }
        let bucket = n.min(MAX_MAX_COUNT_STATS as i64 - 1) as usize;
        dist[bucket] += 1;
    }
    HashStats {
        min,
        avg: total / h.hash_slots.max(1) as i64,
        max,
        distribution: dist,
    }
}

/// `2026-07-30 05:59:24` from an ISC timestamp - `TimeStamp::decode`, the
/// same civil-from-days arithmetic the ODS dates use (day 0 = 1858-11-17).
fn timestamp_string(ts: (i32, u32)) -> String {
    let (days, frac) = ts;
    let z = days as i64 - 40587 + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    let secs = frac / 10_000;
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        y,
        m,
        d,
        secs / 3600,
        (secs / 60) % 60,
        secs % 60
    )
}

/// Is that process still alive? The engine calls
/// `ISC_check_process_existence` (kill(pid, 0) and ESRCH); reading
/// `/proc/<pid>` answers the same question without a syscall wrapper, and
/// only differs for a pid that exists but belongs to another user - which
/// on this table cannot happen, since every owner is the server.
fn process_alive(pid: i32) -> bool {
    pid > 0 && std::path::Path::new(&format!("/proc/{}", pid)).exists()
}

/// `prt_que`: a queue line, or `*empty*`.
fn que_line(b: &[u8], label: &str, head: usize, field: i32) -> String {
    let q = Srq::at(b, head);
    if q.is_empty(head as i32) {
        return format!("{}: *empty*\n", label);
    }
    let count = walk_queue(b, head, field).len();
    format!(
        "{} ({}):\tforward: {:6}, backward: {:6}\n",
        label,
        count,
        q.forward - field,
        q.backward - field
    )
}

/// `prt_lock`'s key formatting (print.cpp:...): the key's MEANING depends
/// on the series, and each shape has its own field widths.
///
/// This is the most informative part of the dump - it is where a row of
/// bytes becomes "page 231 of page space 0" or "transaction 1362" - and it
/// is also where a converter can be wrong in a way that still prints
/// something plausible, so every branch below cites the series and length
/// that select it.
pub fn format_key(series: u8, length: u8, key: &[u8], data: i64) -> String {
    let u32_le = |o: usize| -> u32 {
        if o + 4 <= key.len() {
            u32::from_le_bytes([key[o], key[o + 1], key[o + 2], key[o + 3]])
        } else {
            0
        }
    };
    let i64_le = |o: usize| -> i64 {
        if o + 8 <= key.len() {
            let mut v = [0u8; 8];
            v.copy_from_slice(&key[o..o + 8]);
            i64::from_le_bytes(v)
        } else {
            0
        }
    };
    let _ = data;
    match (series, length) {
        // a page lock: since 2.1 the key is (page number, page SPACE), and
        // the dump prints them the other way round - space first
        (series::BDB | series::BTR_DONT_GC, 8) => {
            format!("\tKey: {:04}:{:06},", u32_le(4), u32_le(0))
        }
        // a relation lock: relation id + instance id
        (series::RELATION | series::REL_GC, 12) => {
            format!("\tKey: {:04}:{:09},", u32_le(0), i64_le(4))
        }
        (series::TRA | series::ATTACHMENT | series::MONITOR | series::CANCEL, 8) => {
            format!("\tKey: {:09},", i64_le(0))
        }
        // a record-level GC lock packs the page number and the line number
        // into one 64-bit key
        (series::RECORD_GC, 8) => {
            let k = i64_le(0);
            format!("\tKey: {:06}:{:04},", (k >> 16) as u32, (k & 0xffff) as u32)
        }
        (series::IDX_RESCAN, 4) => {
            let k = u32_le(0) as i32;
            format!("\tKey: {:04}:{:04},", (k >> 16) as u32, (k & 0xffff) as u32)
        }
        (_, 4) => format!("\tKey: {:06},", u32_le(0) as i32),
        (_, 0) => "\tKey: <none>".to_string(),
        // anything else: printable characters as themselves, everything
        // else as <NNN> - the engine's own escape
        _ => {
            let mut t = String::new();
            for &c in key.iter().take(length as usize) {
                if c.is_ascii_alphanumeric() || c == b'/' {
                    t.push(c as char);
                } else {
                    t.push_str(&format!("<{}>", c));
                }
            }
            format!("\tKey: {},", t)
        }
    }
}

/// One lock block.
#[derive(Clone, Debug)]
pub struct Lbl {
    pub offset: i32,
    pub series: u8,
    pub state: u8,
    pub size: u8,
    pub length: u8,
    pub data: i64,
    pub flags: u8,
    pub pending_lrq_count: u16,
    pub key: Vec<u8>,
}

impl Lbl {
    pub fn decode(b: &[u8], at: i32) -> Result<Lbl, String> {
        let o = at as usize;
        if o + lbl_off::KEY > b.len() {
            return Err(format!("lock block at {} runs past the table", at));
        }
        let length = u8_at(b, o + lbl_off::LENGTH);
        let key_end = (o + lbl_off::KEY + length as usize).min(b.len());
        Ok(Lbl {
            offset: at,
            series: u8_at(b, o + lbl_off::SERIES),
            state: u8_at(b, o + lbl_off::STATE),
            size: u8_at(b, o + lbl_off::SIZE),
            length,
            data: u64_at(b, o + lbl_off::DATA) as i64,
            flags: u8_at(b, o + lbl_off::FLAGS),
            pending_lrq_count: u16_at(b, o + lbl_off::PENDING_LRQ_COUNT),
            key: b[(o + lbl_off::KEY).min(b.len())..key_end].to_vec(),
        })
    }
}

/// One request block.
#[derive(Clone, Debug)]
pub struct Lrq {
    pub offset: i32,
    pub owner: i32,
    pub lock: i32,
    pub state: u8,
    pub requested: u8,
    pub flags: u16,
}

impl Lrq {
    pub fn decode(b: &[u8], at: i32) -> Lrq {
        let o = at as usize;
        Lrq {
            offset: at,
            owner: i32_at(b, o + lrq_off::OWNER),
            lock: i32_at(b, o + lrq_off::LOCK),
            state: u8_at(b, o + lrq_off::STATE),
            requested: u8_at(b, o + lrq_off::REQUESTED),
            flags: u16_at(b, o + lrq_off::FLAGS),
        }
    }
}

/// `prt_que2`: the same as [`que_line`] but WITHOUT counting the entries -
/// "as they might be invalid" (print.cpp). A request's own queues are
/// printed this way, so a torn snapshot cannot make the dump hang.
fn que_line_uncounted(b: &[u8], label: &str, head: usize, field: i32) -> String {
    let q = Srq::at(b, head);
    if q.is_empty(head as i32) {
        return format!("{}: *empty*\n", label);
    }
    format!(
        "{}:\tforward: {:6}, backward: {:6}\n",
        label,
        q.forward - field,
        q.backward - field
    )
}

/// Every lock block in the table, in hash-slot order - the order
/// `fb_lock_print -l` walks them (print.cpp: over the hash slots, then
/// along each collision chain).
pub fn locks(b: &[u8], h: &Lhb) -> Vec<i32> {
    let mut out = Vec::new();
    for i in 0..h.hash_slots as usize {
        let slot = lhb_off::HASH + i * 8;
        for at in walk_queue(b, slot, que_field::LBL_LHB_HASH) {
            out.push(at);
        }
    }
    out
}

/// `prt_lock` (print.cpp): one LOCK BLOCK section.
pub fn lock_section(b: &[u8], at: i32) -> Result<String, String> {
    let l = Lbl::decode(b, at)?;
    let mut s = format!("LOCK BLOCK {:6}\n", l.offset);
    s.push_str(&format!(
        "\tSeries: {}, State: {}, Size: {}, Length: {}, Data: {}\n",
        l.series, l.state, l.size, l.length, l.data
    ));
    // the key line has NO newline of its own: the flags continue it
    s.push_str(&format_key(l.series, l.length, &l.key, l.data));
    s.push_str(&format!(
        " Flags: 0x{:02X}, Pending request count: {:6}\n",
        l.flags, l.pending_lrq_count
    ));
    s.push_str(&que_line(
        b,
        "\tHash que",
        at as usize + lbl_off::LHB_HASH,
        que_field::LBL_LHB_HASH,
    ));
    s.push_str(&que_line(
        b,
        "\tRequests",
        at as usize + lbl_off::REQUESTS,
        que_field::LRQ_LBL_REQUESTS,
    ));
    for r in walk_queue(
        b,
        at as usize + lbl_off::REQUESTS,
        que_field::LRQ_LBL_REQUESTS,
    ) {
        let q = Lrq::decode(b, r);
        s.push_str(&format!(
            "\t\tRequest {:6}, Owner: {:6}, State: {} ({}), Flags: 0x{:02X}\n",
            q.offset, q.owner, q.state, q.requested, q.flags
        ));
    }
    s.push('\n');
    Ok(s)
}

/// `prt_request` (print.cpp): one REQUEST BLOCK section.
///
/// The AST line prints two POINTERS - addresses in the server's address
/// space, which are meaningless in a snapshot and differ between the tool's
/// process and ours. fire-crab prints the stored values as the engine
/// formats them (`0x%p`), which for a granted request with no blocking AST
/// is `0x(nil)`; a request that HAS an AST cannot be compared across
/// processes at all, and the gate says so rather than pretending.
pub fn request_section(b: &[u8], at: i32) -> String {
    let r = Lrq::decode(b, at);
    let o = at as usize;
    let mut s = format!("REQUEST BLOCK {:6}\n", at);
    s.push_str(&format!(
        "\tOwner: {:6}, Lock: {:6}, State: {}, Mode: {}, Flags: 0x{:02X}\n",
        r.owner, r.lock, r.state, r.requested, r.flags
    ));
    let ast = u64_at(b, o + 56);
    let arg = u64_at(b, o + 64);
    // The engine's format string is "AST: 0x%p" and glibc's %p ALREADY
    // prints a 0x prefix, so the real output carries a DOUBLE one:
    // `AST: 0x0xeb781933e044`. Converted as it prints, not as it reads -
    // the differential is the tool's text, quirks included.
    let ptr = |v: u64| {
        if v == 0 {
            "0x(nil)".to_string()
        } else {
            format!("0x0x{:x}", v)
        }
    };
    s.push_str(&format!("\tAST: {}, argument: {}\n", ptr(ast), ptr(arg)));
    for (label, off, field) in [
        ("\tlrq_own_requests", lrq_off::OWN_REQUESTS, que_field::LRQ_OWN_REQUESTS),
        ("\tlrq_lbl_requests", lrq_off::LBL_REQUESTS, que_field::LRQ_LBL_REQUESTS),
        ("\tlrq_own_blocks  ", lrq_off::OWN_BLOCKS, que_field::LRQ_OWN_BLOCKS),
        ("\tlrq_own_pending ", lrq_off::OWN_PENDING, que_field::LRQ_OWN_PENDING),
    ] {
        s.push_str(&que_line_uncounted(b, label, o + off, field));
    }
    s.push('\n');
    s
}

/// `history_names` (print.cpp): the operation each history entry records.
/// Index 0 is `n/a` and entries with operation 0 are SKIPPED - the ring is
/// pre-allocated, so an unused slot is a zero.
pub const HISTORY_NAMES: &[&str] = &[
    "n/a", "ENQ", "DEQ", "CONVERT", "SIGNAL", "POST", "WAIT", "DEL_PROC", "DEL_LOCK", "DEL_REQ",
    "DENY", "GRANT", "LEAVE", "SCAN", "DEAD", "ENTER", "BUG", "ACTIVE", "CLEANUP", "DEL_OWNER",
];

/// Field offsets inside a `his` block (lock_proto.h:218-226).
mod his_off {
    pub const OPERATION: usize = 1;
    pub const NEXT: usize = 4;
    pub const PROCESS: usize = 8;
    pub const LOCK: usize = 12;
    pub const REQUEST: usize = 16;
}

/// `prt_history`: the ring of recent lock-manager events, walked from
/// `lhb_history` all the way round to itself.
///
/// The ring is CIRCULAR and pre-allocated, so the walk is "print, then stop
/// when the next pointer is the head again" - not "stop at a null". An
/// entry whose operation is 0 is an unused slot and is skipped, but it
/// still advances the walk.
pub fn history_section(b: &[u8], head: i32, title: &str) -> String {
    let mut s = format!("{}:\n", title);
    let mut at = head;
    let limit = b.len() / 8;
    let mut steps = 0;
    loop {
        let o = at as usize;
        if at < 0 || o + 20 > b.len() || steps > limit {
            break;
        }
        let op = u8_at(b, o + his_off::OPERATION) as usize;
        if op != 0 {
            s.push_str(&format!(
                "    {}:\towner = {:6}, lock = {:6}, request = {:6}\n",
                HISTORY_NAMES.get(op).copied().unwrap_or("n/a"),
                i32_at(b, o + his_off::PROCESS),
                i32_at(b, o + his_off::LOCK),
                i32_at(b, o + his_off::REQUEST)
            ));
        }
        let next = i32_at(b, o + his_off::NEXT);
        if next == head {
            break;
        }
        at = next;
        steps += 1;
    }
    s
}

/// Dump the lock table the way `fb_lock_print` does, for the header block
/// and (with `owners`) the owner blocks - the `-o` switch's output.
///
/// The text is the conversion of `print.cpp:753-880`, tabs, column widths
/// and all, because the differential is a text comparison against the
/// tool's own output on the same snapshot.
pub fn dump(b: &[u8], owners: bool) -> Result<String, String> {
    dump_with(b, owners, false, false)
}

/// The same, with `fb_lock_print`'s other two switches: `-l` (lock blocks)
/// and `-r` (the requests inside each owner, which the engine only prints
/// when `-o` is also given).
pub fn dump_with(
    b: &[u8],
    owners: bool,
    locks_too: bool,
    requests: bool,
) -> Result<String, String> {
    dump_all(b, owners, locks_too, requests, false)
}

/// The full `-a`: owners, locks, requests and the history ring.
pub fn dump_all(
    b: &[u8],
    owners: bool,
    locks_too: bool,
    requests: bool,
    history: bool,
) -> Result<String, String> {
    let h = Lhb::decode(b)?;
    let h_secondary = h.secondary;
    let mut s = String::new();
    s.push_str("LOCK_HEADER BLOCK\n");
    s.push_str(&format!(
        "\tVersion: {}, Creation timestamp: {}\n",
        h.version,
        timestamp_string(h.timestamp)
    ));
    s.push_str(&format!(
        "\tActive owner: {:6}, Length: {:6}, Used: {:6}\n",
        h.active_owner, h.length, h.used
    ));
    s.push_str(&format!(
        "\tEnqs: {:6}, Converts: {:6}, Rejects: {:6}, Blocks: {:6}\n",
        h.enqs, h.converts, h.denies, h.blocks
    ));
    s.push_str(&format!(
        "\tDeadlock scans: {:6}, Deadlocks: {:6}, Scan interval: {:3}\n",
        h.scans, h.deadlocks, h.scan_interval
    ));
    s.push_str(&format!(
        "\tAcquires: {:6}, Acquire blocks: {:6}, Spin count: {:3}\n",
        h.acquires, h.acquire_blocks, h.acquire_spins
    ));
    // the engine prints one decimal, and exactly "0.0%" when there were no
    // blocks (print.cpp:784-791) - not "0.0%" computed from a division
    if h.acquire_blocks != 0 {
        let bottleneck = 100.0 * h.acquire_blocks as f64 / h.acquires as f64;
        s.push_str(&format!("\tMutex wait: {:.1}%\n", bottleneck));
    } else {
        s.push_str("\tMutex wait: 0.0%\n");
    }

    let st = hash_stats(b, &h);
    s.push_str(&format!("\tHash slots: {:4}, ", h.hash_slots));
    s.push_str(&format!(
        "Hash lengths (min/avg/max): {:4}/{:4}/{:4}\n",
        st.min, st.avg, st.max
    ));
    s.push_str("\tHash lengths distribution:\n");
    let last = MAX_MAX_COUNT_STATS as i64 - 1;
    let mut top = st.max;
    if top >= last {
        top = last - 1;
    }
    for i in st.min..=top {
        s.push_str(&format!(
            "\t\t{:<2} : {:8}\t({}%)\n",
            i,
            st.distribution[i as usize],
            st.distribution[i as usize] as u64 * 100 / h.hash_slots.max(1) as u64
        ));
    }
    if top == last - 1 {
        s.push_str(&format!(
            "\t\t>  : {:8}\t({}%)\n",
            st.distribution[last as usize],
            st.distribution[last as usize] as u64 * 100 / h.hash_slots.max(1) as u64
        ));
    }

    // the secondary header block, reached through lhb_secondary
    let shb = h.secondary as usize;
    s.push_str(&format!(
        "\tRemove node: {:6}, Insert queue: {:6}, Insert prior: {:6}\n",
        i32_at(b, shb + 8),
        i32_at(b, shb + 12),
        i32_at(b, shb + 16)
    ));

    s.push_str(&que_line(
        b,
        "\tOwners",
        lhb_off::OWNERS,
        que_field::OWN_LHB_OWNERS,
    ));
    s.push_str(&que_line(
        b,
        "\tFree owners",
        lhb_off::FREE_OWNERS,
        que_field::OWN_LHB_OWNERS,
    ));
    s.push_str(&que_line(
        b,
        "\tFree locks",
        lhb_off::FREE_LOCKS,
        que_field::LBL_LHB_HASH,
    ));
    s.push_str(&que_line(
        b,
        "\tFree requests",
        lhb_off::FREE_REQUESTS,
        que_field::LRQ_LBL_REQUESTS,
    ));
    s.push('\n');

    if owners {
        for at in walk_queue(b, lhb_off::OWNERS, que_field::OWN_LHB_OWNERS) {
            let o = Own::decode(b, at)?;
            s.push_str(&format!("OWNER BLOCK {:6}\n", o.offset));
            s.push_str(&format!(
                "\tOwner id: {:6}, Type: {:1}\n",
                o.owner_id, o.owner_type
            ));
            let pid = i32_at(b, o.process as usize + 4); // prc_process_id
            s.push_str(&format!(
                "\tProcess id: {:6} ({}), Thread id: {:6}\n",
                pid,
                if process_alive(pid) { "Alive" } else { "Dead" },
                o.thread_id
            ));
            // the flag line pads each absent flag with four spaces, so the
            // column layout survives (print.cpp:822-828)
            s.push_str(&format!("\tFlags: 0x{:02X} ", o.flags));
            s.push_str(&format!(
                " {}",
                if o.flags & own_flags::WAKEUP != 0 {
                    "wake"
                } else {
                    "    "
                }
            ));
            s.push_str(&format!(
                " {}",
                if o.flags & own_flags::SCANNED != 0 {
                    "scan"
                } else {
                    "    "
                }
            ));
            s.push_str(&format!(
                " {}",
                if o.flags & own_flags::SIGNALED != 0 {
                    "sgnl"
                } else {
                    "    "
                }
            ));
            s.push('\n');
            s.push_str(&que_line(
                b,
                "\tRequests",
                o.offset as usize + own_off::REQUESTS,
                que_field::LRQ_OWN_REQUESTS,
            ));
            s.push_str(&que_line(
                b,
                "\tBlocks",
                o.offset as usize + own_off::BLOCKS,
                que_field::LRQ_OWN_BLOCKS,
            ));
            s.push_str(&que_line(
                b,
                "\tPending",
                o.offset as usize + own_off::PENDING,
                que_field::LRQ_OWN_PENDING,
            ));
            s.push('\n');
            // -r prints every request this owner holds, in the owner's own
            // request queue order
            if requests {
                for r in walk_queue(
                    b,
                    o.offset as usize + own_off::REQUESTS,
                    que_field::LRQ_OWN_REQUESTS,
                ) {
                    s.push_str(&request_section(b, r));
                }
            }
        }
    }
    if locks_too {
        let h = Lhb::decode(b)?;
        for at in locks(b, &h) {
            s.push_str(&lock_section(b, at)?);
        }
    }
    if history {
        // TWO rings, printed one after the other: the lock table's own
        // (`lhb_history`) and the secondary header's (`shb_history`,
        // print.cpp:885-886) - titled "History" and "Event log". Missing
        // the second one costs exactly one line of output plus its entries,
        // which is how this was caught.
        s.push_str(&history_section(b, i32_at(b, lhb_off::HISTORY), "History"));
        let shb = h_secondary as usize;
        s.push_str(&history_section(b, i32_at(b, shb + 4), "Event log"));
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_header_layout_is_pinned() {
        // Derived from lock_proto.h and VERIFIED against fb_lock_print's
        // own numbers on a live table: version 148 at mhb_version, length
        // 1048576, used 90232, 8191 hash slots, scan interval 10.
        assert_eq!(MEMORY_HEADER_SIZE, 80);
        assert_eq!(lhb_off::TYPE, 80);
        assert_eq!(lhb_off::OWNERS, 92);
        assert_eq!(lhb_off::LENGTH, 140);
        assert_eq!(lhb_off::USED, 144);
        assert_eq!(lhb_off::HASH_SLOTS, 148);
        assert_eq!(lhb_off::SCAN_INTERVAL, 156);
        assert_eq!(lhb_off::ACQUIRES, 168);
        assert_eq!(lhb_off::ENQS, 200);
        assert_eq!(lhb_off::CONVERTS, 208);
        // the counters past lhb_operations[6] - the ones a miscount hides
        // because they are usually zero
        assert_eq!(lhb_off::DENIES, 312);
        assert_eq!(lhb_off::BLOCKS, 328);
        assert_eq!(lhb_off::SCANS, 344);
        assert_eq!(lhb_off::DEADLOCKS, 352);
        assert_eq!(lhb_off::HASH, 408);
        // six series of operations and of data queues sit between the
        // counters and the hash table
        assert_eq!(lhb_off::HASH, lhb_off::DATA + 48);
    }

    #[test]
    fn the_owner_layout_is_pinned() {
        // Verified the same way: owner id 2804613644298 at +8, the owners
        // queue at +16 (the tool prints 78392 for a raw 78408), requests
        // at +32, the process pointer at +56 and a 4-byte thread id at +60.
        assert_eq!(own_off::OWNER_ID, 8);
        assert_eq!(own_off::LHB_OWNERS, 16);
        assert_eq!(own_off::REQUESTS, 32);
        assert_eq!(own_off::PROCESS, 56);
        assert_eq!(own_off::THREAD_ID, 60);
        // own_flags sits past the embedded event_t, whose size comes from
        // libc's pthread types - the one libc-dependent number here
        assert_eq!(own_off::FLAGS, 184);
        assert_eq!(que_field::OWN_LHB_OWNERS, own_off::LHB_OWNERS as i32);
        assert_eq!(que_field::LRQ_OWN_REQUESTS, 24);
    }

    #[test]
    fn a_wrong_file_is_refused() {
        // a database page, not a lock table
        let mut page = vec![0u8; 8192];
        page[0] = 1; // pag_type = header
        let err = Lhb::decode(&page).unwrap_err();
        assert!(err.contains("not a lock table"), "{}", err);
        // and something far too short
        assert!(Lhb::decode(&[0u8; 32]).unwrap_err().contains("too short"));
    }

    #[test]
    fn an_empty_queue_prints_empty() {
        // SRQ_EMPTY: both ends point at the queue itself. The engine
        // prints "*empty*" rather than a count of zero, and the gate
        // compares text.
        let mut b = vec![0u8; 256];
        let head = 100usize;
        b[head..head + 4].copy_from_slice(&(head as i32).to_le_bytes());
        b[head + 4..head + 8].copy_from_slice(&(head as i32).to_le_bytes());
        assert_eq!(que_line(&b, "\tOwners", head, 16), "\tOwners: *empty*\n");
        assert!(Srq::at(&b, head).is_empty(head as i32));
    }

    #[test]
    fn a_queue_line_prints_block_offsets_not_node_offsets() {
        // prt_que subtracts the queue field's offset within its block, so
        // a raw forward pointer of 216 in a queue whose nodes sit 16 bytes
        // into an `own` prints as 200. Getting this wrong shifts every
        // printed offset by a constant - which reads as plausible.
        let mut b = vec![0u8; 512];
        let head = 100usize;
        let node = 216usize;
        b[head..head + 4].copy_from_slice(&(node as i32).to_le_bytes());
        b[head + 4..head + 8].copy_from_slice(&(node as i32).to_le_bytes());
        // the node closes the ring back to the head
        b[node..node + 4].copy_from_slice(&(head as i32).to_le_bytes());
        b[node + 4..node + 8].copy_from_slice(&(head as i32).to_le_bytes());
        let line = que_line(&b, "\tOwners", head, 16);
        assert_eq!(line, "\tOwners (1):\tforward:    200, backward:    200\n");
        assert_eq!(walk_queue(&b, head, 16), vec![200]);
    }

    #[test]
    fn a_broken_queue_does_not_spin_forever() {
        // a snapshot of LIVE shared memory can catch a half-updated queue;
        // walking it must terminate
        let mut b = vec![0u8; 64];
        let head = 8usize;
        b[head..head + 4].copy_from_slice(&16i32.to_le_bytes());
        b[16..20].copy_from_slice(&16i32.to_le_bytes()); // points at itself
        // it terminates on the self-pointing node rather than counting to
        // the table-size bound
        let v = walk_queue(&b, head, 0);
        assert_eq!(v, vec![16]);
        // and an out-of-range pointer stops the walk instead of panicking
        let mut b2 = vec![0u8; 64];
        b2[head..head + 4].copy_from_slice(&999_999i32.to_le_bytes());
        assert!(walk_queue(&b2, head, 0).is_empty());
    }

    #[test]
    fn a_key_means_what_its_series_says() {
        // The most informative line in the dump, and the one with the most
        // branches. Series and LENGTH together select the shape; the widths
        // are the engine's.
        // a page lock: the key is (page number, page SPACE) and the dump
        // prints them the other way round
        let mut k = Vec::new();
        k.extend_from_slice(&231u32.to_le_bytes());
        k.extend_from_slice(&0u32.to_le_bytes());
        assert_eq!(format_key(series::BDB, 8, &k, 0), "\tKey: 0000:000231,");
        assert_eq!(
            format_key(series::BTR_DONT_GC, 8, &k, 0),
            "\tKey: 0000:000231,"
        );
        // a relation lock: relation id + instance id
        let mut k = Vec::new();
        k.extend_from_slice(&128u32.to_le_bytes());
        k.extend_from_slice(&7i64.to_le_bytes());
        assert_eq!(
            format_key(series::RELATION, 12, &k, 0),
            "\tKey: 0128:000000007,"
        );
        // transaction / attachment / monitor / cancel: one 64-bit number
        let k = 1362i64.to_le_bytes().to_vec();
        assert_eq!(format_key(series::TRA, 8, &k, 0), "\tKey: 000001362,");
        assert_eq!(
            format_key(series::ATTACHMENT, 8, &k, 0),
            "\tKey: 000001362,"
        );
        // a record-level GC lock packs page and line into one key
        let k = ((231i64 << 16) | 4).to_le_bytes().to_vec();
        assert_eq!(
            format_key(series::RECORD_GC, 8, &k, 0),
            "\tKey: 000231:0004,"
        );
        // an index rescan lock packs relation and index id into four bytes
        let k = ((4u32 << 16) | 0).to_le_bytes().to_vec();
        assert_eq!(
            format_key(series::IDX_RESCAN, 4, &k, 0),
            "\tKey: 0004:0000,"
        );
        // ... and the SAME four bytes under any other series print as one
        // number. Series 22 was verified against a live dump for exactly
        // this reason: an off-by-one in the series enum shows up here and
        // nowhere else.
        assert_eq!(format_key(99, 4, &k, 0), "\tKey: 262144,");
        // no key at all, and a text key with the engine's escape
        assert_eq!(format_key(series::DATABASE, 0, &[], 0), "\tKey: <none>");
        assert_eq!(
            format_key(99, 5, b"ab\x01c/", 0),
            "\tKey: ab<1>c/,"
        );
    }

    #[test]
    fn the_ast_line_keeps_the_engine_s_double_prefix() {
        // print.cpp writes "AST: 0x%p", and glibc's %p already prints 0x,
        // so the real output is `AST: 0x0xeb781933e044`. The differential is
        // the tool's TEXT, quirks included - "fixing" this makes the dump
        // wrong.
        let mut b = vec![0u8; 128];
        b[56..64].copy_from_slice(&0xeb781933e044u64.to_le_bytes());
        b[64..72].copy_from_slice(&0u64.to_le_bytes());
        let s = request_section(&b, 0);
        assert!(s.contains("\tAST: 0x0xeb781933e044, argument: 0x(nil)\n"), "{}", s);
    }

    #[test]
    fn the_history_ring_skips_unused_slots_and_stops_at_the_head() {
        // the ring is pre-allocated and circular: operation 0 is an unused
        // slot (skipped, but it still advances the walk), and the walk ends
        // when a next pointer points back at the head - not at a null
        let mut b = vec![0u8; 256];
        let mk = |b: &mut Vec<u8>, at: usize, op: u8, next: i32, owner: i32| {
            b[at + 1] = op;
            b[at + 4..at + 8].copy_from_slice(&next.to_le_bytes());
            b[at + 8..at + 12].copy_from_slice(&owner.to_le_bytes());
        };
        mk(&mut b, 32, 1, 64, 111); // ENQ
        mk(&mut b, 64, 0, 96, 222); // unused slot: skipped
        mk(&mut b, 96, 11, 32, 333); // GRANT, then back to the head
        let s = history_section(&b, 32, "History");
        assert_eq!(
            s,
            "History:\n    ENQ:\towner =    111, lock =      0, request =      0\n    GRANT:\towner =    333, lock =      0, request =      0\n"
        );
    }

    #[test]
    fn the_lock_and_request_layouts_are_pinned() {
        // lbl_lhb_hash at 12 was verified in slice 4 through the free-locks
        // queue; the rest follow the struct, with LOCK_DATA_T forcing an
        // 8-byte alignment pad after the third queue
        assert_eq!(lbl_off::REQUESTS, 4);
        assert_eq!(lbl_off::LHB_HASH, 12);
        assert_eq!(lbl_off::DATA, 32);
        assert_eq!(lbl_off::SERIES, 40);
        assert_eq!(lbl_off::COUNTS, 44);
        assert_eq!(lbl_off::KEY, 44 + 2 * LCK_MAX);
        // The request queues: own_requests at 24 was verified against a
        // printed queue head in slice 4, and the other three were WRONG
        // there - shifted by one field - because they are empty on a server
        // with no contention. A blocked waiter populates own_pending, and
        // then 48 is the only value that prints what the tool prints.
        assert_eq!(lrq_off::OWN_REQUESTS, 24);
        assert_eq!(lrq_off::LBL_REQUESTS, 32);
        assert_eq!(lrq_off::OWN_BLOCKS, 40);
        assert_eq!(lrq_off::OWN_PENDING, 48);
    }

    #[test]
    fn the_timestamp_is_the_isc_one() {
        // day 0 = 1858-11-17, time in 1/10000 s
        assert_eq!(timestamp_string((0, 0)), "1858-11-17 00:00:00");
        assert_eq!(
            timestamp_string((40587, 3_600_0000)),
            "1970-01-01 01:00:00"
        );
    }
}
