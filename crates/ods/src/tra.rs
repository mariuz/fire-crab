//! The transaction system's durable half, converted from the TIP
//! machinery in `tra.cpp` and the version-chain rules in `vio.cpp`:
//! transaction-state lookup across the chained inventory pages, delta
//! back-version reconstruction (`Difference::apply`, sqz.cpp:515),
//! and the committed-only visibility walk - "which version of each
//! record would a reader see if it considers exactly the committed
//! transactions" - the core MVCC question, answerable from the raw
//! file because both the versions and the transaction states are
//! durable.

use crate::data::{flags, DataPage};
use crate::format::{decode_record, Descriptor, Value};
use crate::pointer::relation_data_pages;
use crate::tip::{TipPage, TxState};
use crate::u16_at;

/// All TIP pages in transaction order. TIPs chain through `tip_next`;
/// the head is the TIP no other TIP points to (page 2 in practice,
/// but derived, not assumed).
pub struct TipChain<'a> {
    pages: Vec<TipPage<'a>>,
    per_page: usize,
}

impl<'a> TipChain<'a> {
    pub fn read(file: &'a crate::Image, page_size: usize) -> Option<TipChain<'a>> {
        let mut tips: Vec<TipPage> = file
            .pages()
            .filter(|p| p[0] == crate::PageType::TransactionInventory as u8)
            .filter_map(TipPage::decode)
            .collect();
        if tips.is_empty() {
            return None;
        }
        // the head is the TIP no other TIP's tip_next points to
        let head = tips
            .iter()
            .map(|t| t.pag.page_no)
            .find(|no| !tips.iter().any(|t| t.next == *no))?;

        let mut ordered = Vec::with_capacity(tips.len());
        let mut cur = head;
        while cur != 0 {
            let pos = tips.iter().position(|t| t.pag.page_no == cur)?;
            let t = tips.swap_remove(pos);
            cur = t.next;
            ordered.push(t);
        }
        Some(TipChain {
            per_page: TipPage::transactions_per_page(page_size),
            pages: ordered,
        })
    }

    /// State of transaction `id` (tra.cpp's TIP lookup: page
    /// `id / per_page`, index `id % per_page`).
    pub fn state(&self, id: u64) -> Option<TxState> {
        let page = self.pages.get((id as usize) / self.per_page)?;
        page.state((id as usize) % self.per_page)
    }

    pub fn page_count(&self) -> usize {
        self.pages.len()
    }
}

/// `Difference::apply` (sqz.cpp:515): reconstruct the PRIOR version's
/// image by applying a differences stream to (a copy of) the newer
/// image. Positive control byte = take that many literal bytes from
/// the stream; negative = retain that many bytes of the newer image.
pub fn apply_differences(diff: &[u8], newer_image: &[u8]) -> Option<Vec<u8>> {
    let mut out = newer_image.to_vec();
    let mut p = 0usize; // position in out
    let mut d = 0usize; // position in diff
    while d < diff.len() && p < out.len() {
        let l = diff[d] as i8;
        d += 1;
        if l > 0 {
            let n = l as usize;
            if p + n > out.len() || d + n > diff.len() {
                return None; // BUGCHECK 176/177 territory
            }
            out[p..p + n].copy_from_slice(&diff[d..d + n]);
            p += n;
            d += n;
        } else {
            p += (-(l as i32)) as usize;
        }
    }
    // trailing difference bytes must be zero padding (sqz.cpp:553)
    if diff[d..].iter().any(|b| *b != 0) {
        return None;
    }
    out.truncate(p.min(out.len()));
    Some(out)
}

/// THE TRANSACTIONS A READER COUNTS AS ITS OWN - not one id, a SET.
///
/// A reader must see the uncommitted work of its own transaction, and
/// for a long time that was one number, because one attachment wrote
/// under one id. It is a set now because an UNDO WINDOW inside a
/// transaction - a savepoint, a PSQL body, a row-by-row statement -
/// writes under a NESTED id of its own, so that undoing the window is
/// `tra_dead` on that id and nothing else (the engine's savepoint
/// model, `tra.cpp`'s undo records seen from the durable side). All of
/// those ids belong to the same reader; a transaction that commits
/// flips every one of them, and one that rolls a window back flips
/// only that window's.
///
/// Order does not matter and the sets are tiny (one per open window),
/// so this is a `Vec` and the test is a linear scan - a `HashSet` here
/// costs more than it saves, and this is on the per-record path.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OwnTx {
    ids: Vec<u64>,
    /// THE CATALOG READER'S RULE: every ACTIVE transaction's rows count.
    /// A DDL statement's catalog rows carry the user transaction's id
    /// now, and the readers that resolve names, formats and columns
    /// have no attachment to ask whose transaction that is - so they
    /// count it, as this server's shared pool already let every
    /// attachment see an uncommitted DDL (recorded divergence: the
    /// engine shows it to the owning transaction alone). What they do
    /// NOT count any more is a DEAD or LIMBO version: the walk steps
    /// behind it, which is what makes a rolled-back DDL disappear by
    /// state.
    any_active: bool,
}

impl OwnTx {
    /// The committed-only walk: a reader with no transaction of its
    /// own, which is what a tool reading a quiet file is.
    pub fn none() -> OwnTx {
        OwnTx { ids: Vec::new(), any_active: false }
    }

    pub fn one(id: u64) -> OwnTx {
        OwnTx { ids: vec![id], any_active: false }
    }

    pub fn of<I: IntoIterator<Item = u64>>(ids: I) -> OwnTx {
        OwnTx { ids: ids.into_iter().collect(), any_active: false }
    }

    /// The catalog reader's walk - see `any_active`.
    pub fn catalog() -> OwnTx {
        OwnTx { ids: Vec::new(), any_active: true }
    }

    /// A reader with a transaction of its own and the owner-only rule:
    /// committed rows and its own rows count, another transaction's
    /// ACTIVE rows do not - what the engine's metadata transaction sees
    /// (Attachment::getMetaTransaction impersonates the user
    /// transaction's number).
    pub fn owner(ids: Vec<u64>) -> OwnTx {
        OwnTx { ids, any_active: false }
    }

    pub fn push(&mut self, id: u64) {
        if !self.contains(id) {
            self.ids.push(id);
        }
    }

    pub fn contains(&self, id: u64) -> bool {
        self.ids.contains(&id)
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub fn ids(&self) -> &[u64] {
        &self.ids
    }
}

impl From<Option<u64>> for OwnTx {
    fn from(id: Option<u64>) -> OwnTx {
        match id {
            Some(id) => OwnTx::one(id),
            None => OwnTx::none(),
        }
    }
}

/// One visible row: its record number and decoded values.
pub struct VisibleRow {
    pub recno: u64,
    pub values: Vec<Value>,
    /// THE FORMAT THE VISIBLE VERSION WAS WRITTEN UNDER, which need not
    /// be the relation's newest: `ALTER TABLE ... ALTER c TYPE` mints a
    /// format and rewrites no row. A caller that goes back to `image`
    /// must lay its fields at THIS format's offsets, and convert them
    /// before presenting them through any other one - see
    /// [crate::format::relay_image].
    pub format: u8,
    /// the record image the values were decoded from - kept so a caller
    /// that needs BYTES (an OCTETS column, a format-level check) can go
    /// back to the ground truth instead of a lossy string
    pub image: Vec<u8>,
    /// how many chain steps back the visible version was found
    pub versions_walked: u32,
    /// how many of those steps reconstructed a delta (rhd_delta)
    pub deltas_applied: u32,
}

/// The version of one record chain a reader should see, and the image
/// it decodes from: the newest version whose transaction the reader
/// COUNTS - committed, or the reader's own uncommitted work - walking
/// the back-version chain (`rhd_b_page`/`rhd_b_line`) and
/// reconstructing delta versions (the NEWER version's `rhd_delta` flag
/// says its prior is stored as differences).
///
/// `None` means the reader sees no row here at all: the version it
/// would see is a deleted stub, or there is no such version (an insert
/// by a transaction it does not count).
///
/// `own` is the reader's OWN transactions, whose uncommitted work it
/// must see - a statement reads what the statements before it in the
/// same transaction wrote, INCLUDING the ones an undo window inside it
/// wrote under a nested id. Pass [OwnTx::none] for the pure
/// committed-only walk (what a tool reading a quiet file wants).
///
/// The returned `format` is the FOUND VERSION's, not the chain head's:
/// an older version can carry an older format, and decoding it with
/// the head's descriptors reads the wrong bytes.
pub struct VisibleVersion {
    pub image: Vec<u8>,
    pub format: u8,
    /// chain steps back to it (0 = the primary version)
    pub walked: u32,
    pub deltas: u32,
}

/// A transaction's SNAPSHOT of the inventory, captured at its start -
/// what `isc_tpb_concurrency` (the engine's default, and isql's) gives:
/// a stable view. A version's transaction is visible under the snapshot
/// iff it was COMMITTED as of the snapshot's start, which is exactly
/// `tx < limit AND tx not in active` (`active` = the transactions that
/// were still uncommitted below the limit at capture; a transaction
/// that committed AFTER the snapshot is either >= limit or was in
/// active, so its rows stay hidden - the whole point). Dead
/// transactions need no storing: their versions fail the live-committed
/// test and the chain walks past them anyway.
///
/// READ COMMITTED passes `None` and keeps the old "committed now" rule.
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub limit: u64,
    pub active: Vec<u64>,
    /// ids this transaction COMMITTED while keeping its snapshot - a
    /// COMMIT RETAIN's (tra.cpp retain_context: TBM_SET(tra_commit_sub_trans,
    /// old_number), read by TRA_snapshot_state ahead of the snapshot).
    /// They count even though they are at or past `limit`.
    pub committed_own: Vec<u64>,
}

impl Snapshot {
    /// Capture the inventory as it stands: `limit` = the header's next
    /// transaction, `active` = every id below it the TIP does not read
    /// as committed and that is not dead (active or limbo - the ones
    /// that could still commit later and must stay invisible).
    pub fn capture(file: &crate::Image, page_size: usize) -> Snapshot {
        // hdr_next_transaction (offset 40) holds the HIGHEST id
        // ASSIGNED so far (begin_active_tx returns it + 1 and stores
        // that), so the snapshot's exclusive limit is one PAST it - a
        // transaction committed by that id must be visible to a reader
        // starting now.
        let limit = crate::page_at(file, page_size, 0).and_then(|hdr| hdr.get(40..48))
            .map(|b| u64::from_le_bytes(b.try_into().unwrap()) + 1)
            .unwrap_or(0);
        let mut active = Vec::new();
        if let Some(tips) = TipChain::read(file, page_size) {
            for tx in 1..limit {
                match tips.state(tx) {
                    Some(TxState::Active) | Some(TxState::Limbo) => active.push(tx),
                    _ => {}
                }
            }
        }
        Snapshot { limit, active, committed_own: Vec::new() }
    }

    /// Was transaction `tx` committed as of this snapshot?
    pub fn sees(&self, tx: u64) -> bool {
        (tx < self.limit && !self.active.contains(&tx)) || self.committed_own.contains(&tx)
    }
}


thread_local! {
    /// THE READER'S VIEW OF THE CATALOG for the current thread - set by
    /// the server around each request from the attachment's own
    /// transaction ids (one thread per connection), read by
    /// [crate::data::catalog_image]. Unset (the tools, a server thread
    /// outside a request, a DDL statement under [ReaderViewGuard::wide])
    /// means the catalog walk: every active transaction's rows count.
    static READER_VIEW: std::cell::RefCell<Option<OwnTx>> = const { std::cell::RefCell::new(None) };
}

/// The current thread's reader view, if one is set.
pub fn reader_view() -> Option<OwnTx> {
    READER_VIEW.with(|v| v.borrow().clone())
}

/// Replace the thread's reader view outright - for the server when the
/// attachment's own ids change mid-request (an id adopted, an autonomous
/// block opened or closed). No restore: the request's guard does that.
pub fn set_reader_view(view: Option<OwnTx>) {
    READER_VIEW.with(|v| *v.borrow_mut() = view);
}

/// Set (or clear) the thread's reader view for a scope; the guard puts
/// the previous view back when dropped.
pub struct ReaderViewGuard(Option<OwnTx>);

impl ReaderViewGuard {
    pub fn set(view: Option<OwnTx>) -> ReaderViewGuard {
        ReaderViewGuard(READER_VIEW.with(|v| v.replace(view)))
    }
    /// The wide view - every active transaction's rows count - for the
    /// scope of a DDL statement: its duplicate checks must see another
    /// transaction's uncommitted CREATE ("already exists", measured),
    /// and its own rows are not adopted until it lands.
    pub fn wide() -> ReaderViewGuard {
        ReaderViewGuard::set(None)
    }
}

impl Drop for ReaderViewGuard {
    fn drop(&mut self) {
        let prev = self.0.take();
        READER_VIEW.with(|v| *v.borrow_mut() = prev);
    }
}

pub fn visible_version(
    file: &crate::Image,
    page_size: usize,
    head: &crate::data::RecordHeader,
    tips: &TipChain,
    own: &OwnTx,
) -> Option<VisibleVersion> {
    visible_version_2pc(file, page_size, head, tips, own, false, None).unwrap_or(None)
}

/// [visible_version] with the engine's LIMBO law: a reader that MEETS a
/// version whose transaction is in limbo does not walk past it - it
/// RAISES `isc_rec_in_limbo` naming the transaction (vio.cpp's
/// tra_limbo arm; only `isc_tpb_ignore_limbo`, which nothing here
/// speaks yet, walks past). `strict` false is the old walk - what the
/// tools that must read a wrecked file want.
pub fn visible_version_2pc(
    file: &crate::Image,
    page_size: usize,
    head: &crate::data::RecordHeader,
    tips: &TipChain,
    own: &OwnTx,
    strict: bool,
    snap: Option<&Snapshot>,
) -> Result<Option<VisibleVersion>, u64> {
    visible_version_2pc_prefix(file, page_size, head, tips, own, strict, snap, usize::MAX)
}

/// [visible_version_2pc], decompressing only the first `min_len` bytes of
/// the VISIBLE head - so a scan projecting low-offset columns need not
/// unpack the whole record. `usize::MAX` is the whole image, exactly as
/// [visible_version_2pc] always was.
///
/// The prefix is taken of the HEAD only, and used only when the head is
/// itself the visible version. The moment the walk steps to a BACK
/// version stored as a delta, the head is reconstructed in FULL first,
/// because `apply_differences` rebuilds the prior image against the whole
/// current one; a prefix there would silently corrupt an updated row's
/// visible value. The caller (a scan) passes a `min_len` covering every
/// field it reads - see the read-extent computed at the plan.
#[allow(clippy::too_many_arguments)]
pub fn visible_version_2pc_prefix(
    file: &crate::Image,
    page_size: usize,
    head: &crate::data::RecordHeader,
    tips: &TipChain,
    own: &OwnTx,
    strict: bool,
    snap: Option<&Snapshot>,
    min_len: usize,
) -> Result<Option<VisibleVersion>, u64> {
    let fetch_page = |no: u32| {
        crate::page_at(file, page_size, no)
            .and_then(DataPage::decode)
    };
    let mut current = head.clone();
    let mut image: Option<Vec<u8>> = if current.flags & flags::DELETED != 0 {
        None // deleted stubs carry no data
    } else {
        crate::data::assembled_image_prefix(file, page_size, &current, min_len)
    };
    // did we take only a PREFIX of the head? then a delta back-version
    // below must re-read it whole before reconstructing against it
    let mut prefixed = min_len != usize::MAX;
    let mut walked = 0u32;
    let mut deltas = 0u32;
    loop {
        // THE SYSTEM TRANSACTION IS COMMITTED BY DEFINITION. Its TIP
        // slot reads `tra_active` in every real database (measured: id
        // 0's two bits are 0 while 1..n read 3), because it is not a
        // transaction anybody ever started - the engine answers for it
        // in code instead (tra.cpp's snapshot-state lookup returns
        // committed for number 0). The rows that carry it are the ones
        // only the system transaction may write, `RDB$PAGES` first
        // among them, so reading it as active would hide the catalog.
        let counts = own.contains(current.transaction)
            || current.transaction == 0
            || (tips.state(current.transaction) == Some(TxState::Committed)
                && snap.is_none_or(|s| s.sees(current.transaction)))
            || (own.any_active && tips.state(current.transaction) == Some(TxState::Active));
        if counts {
            if current.flags & flags::DELETED != 0 {
                return Ok(None); // the reader's row is a deleted stub
            }
            return Ok(match image {
                Some(image) => Some(VisibleVersion {
                    image,
                    format: current.format,
                    walked,
                    deltas,
                }),
                None => None,
            });
        }
        if strict
            && !own.contains(current.transaction)
            && tips.state(current.transaction) == Some(TxState::Limbo)
        {
            return Err(current.transaction);
        }
        // not counted: step to the back version
        if current.back_page == 0 {
            return Ok(None); // an insert this reader does not count
        }
        // A DELTA back version is reconstructed against THIS image; if we
        // only took a prefix of the head, get the whole thing now, before
        // it is used. (A non-delta back version replaces the image
        // outright, so the prefix is simply discarded and this is skipped.)
        if prefixed && current.flags & flags::DELTA != 0 && current.flags & flags::DELETED == 0 {
            image = crate::data::assembled_image(file, page_size, &current);
        }
        prefixed = false;
        let Some(back) = fetch_page(current.back_page).and_then(|p| p.record(current.back_line))
        else {
            return Ok(None);
        };
        // ASSEMBLED. A fragmented BACK version used to end the walk,
        // dropping the row even when the primary was perfectly
        // readable - and the delta path below would then have applied
        // against an image that was never fetched.
        let Some(back_data) = crate::data::assembled_image(file, page_size, &back) else {
            return Ok(None);
        };
        image = if current.flags & flags::DELTA != 0 {
            // prior version stored as differences against the CURRENT
            // image (ods.h:1012)
            deltas += 1;
            match image.as_deref().and_then(|i| apply_differences(&back_data, i)) {
                Some(applied) => Some(applied),
                None => return Ok(None),
            }
        } else {
            Some(back_data)
        };
        current = back;
        walked += 1;
    }
}

/// Every transaction the inventory holds in LIMBO, oldest first - what
/// `isc_info_limbo` answers one cluster per id, and what `gfix -list`
/// prints. The range is 1..the header's next id (offset 40, u64 LE).
pub fn limbo_ids(file: &crate::Image, page_size: usize) -> Vec<u64> {
    let Some(tips) = TipChain::read(file, page_size) else {
        return Vec::new();
    };
    let next = crate::page_at(file, page_size, 0).and_then(|hdr| hdr.get(40..48))
        .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
        .unwrap_or(0);
    (1..=next)
        .filter(|id| tips.state(*id) == Some(TxState::Limbo))
        .collect()
}

/// Is there a version of this chain the reader counts, and is it a row?
///
/// The same walk as [visible_version] with the images left alone: a
/// COUNT does not need the bytes, only the answer, and assembling
/// every record to throw it away is what made counting expensive.
/// Deltas are irrelevant here for the same reason - a delta version
/// is still a version, and whether it is DELETED is in its header.
pub fn visible_exists(
    file: &crate::Image,
    page_size: usize,
    head: &crate::data::RecordHeader,
    tips: &TipChain,
    own: &OwnTx,
) -> bool {
    visible_exists_2pc(file, page_size, head, tips, own, false, None).unwrap_or(false)
}

/// [visible_exists] under the limbo law - see [visible_version_2pc].
pub fn visible_exists_2pc(
    file: &crate::Image,
    page_size: usize,
    head: &crate::data::RecordHeader,
    tips: &TipChain,
    own: &OwnTx,
    strict: bool,
    snap: Option<&Snapshot>,
) -> Result<bool, u64> {
    if head.flags & (flags::CHAIN | flags::FRAGMENT | flags::BLOB) != 0 {
        return Ok(false); // reached through its head, never walked as one
    }
    let mut current = head.clone();
    loop {
        let counts = own.contains(current.transaction)
            || current.transaction == 0
            || (tips.state(current.transaction) == Some(TxState::Committed)
                && snap.is_none_or(|s| s.sees(current.transaction)))
            || (own.any_active && tips.state(current.transaction) == Some(TxState::Active));
        if counts {
            return Ok(current.flags & flags::DELETED == 0);
        }
        if strict && tips.state(current.transaction) == Some(TxState::Limbo) {
            return Err(current.transaction);
        }
        if current.back_page == 0 {
            return Ok(false);
        }
        let Some(back) = crate::page_at(file, page_size, current.back_page)
            .and_then(DataPage::decode)
            .and_then(|dp| dp.record(current.back_line))
        else {
            return Ok(false);
        };
        current = back;
    }
}

/// The committed-only visibility walk (the vio.cpp rule a fresh
/// snapshot reader applies when every interesting transaction is
/// either committed or not): for each primary record, take the newest
/// version whose transaction is committed - walking the back-version
/// chain (`rhd_b_page`/`rhd_b_line`), reconstructing delta versions
/// (the NEWER version's `rhd_delta` flag says its prior is stored as
/// differences) - and drop the row if that version is a deleted stub
/// or no committed version exists (an uncommitted insert).
pub fn visible_rows(
    file: &crate::Image,
    page_size: usize,
    relation: u16,
    descs: &[Descriptor],
    tips: &TipChain,
) -> Vec<VisibleRow> {
    visible_rows_2pc(file, page_size, relation, descs, tips, false).unwrap_or_default()
}

/// [visible_rows] under the limbo law - what gbak's read is: the
/// engine's backup DIES on "record from transaction N is stuck in
/// limbo" rather than writing a file that silently lacks the rows.
pub fn visible_rows_2pc(
    file: &crate::Image,
    page_size: usize,
    relation: u16,
    descs: &[Descriptor],
    tips: &TipChain,
    strict: bool,
) -> Result<Vec<VisibleRow>, u64> {
    let recs_per_dp = crate::format::max_recs_per_dp(page_size);
    let mut out = Vec::new();

    for dp_no in relation_data_pages(file, page_size, relation) {
        let Some(dp) = crate::page_at(file, page_size, dp_no)
            .and_then(DataPage::decode)
        else {
            continue;
        };
        for r in dp.records() {
            // only chain heads: back versions and blobs are reached
            // through their primaries. A FRAGMENT is skipped here for the
            // same reason - it is reached through its head, which carries
            // rhd_incomplete and is NOT filtered out - and the head's
            // image is assembled by the walk below.
            if r.flags & (flags::CHAIN | flags::BLOB | flags::FRAGMENT) != 0 {
                continue;
            }
            let recno = dp.sequence as u64 * recs_per_dp + r.slot as u64;
            // committed-only: a reader with no transaction of its own
            let Some(v) =
                visible_version_2pc(file, page_size, &r, tips, &OwnTx::none(), strict, None)?
            else {
                continue;
            };
            out.push(VisibleRow {
                recno,
                values: decode_record(&v.image, descs),
                format: v.format,
                image: v.image,
                versions_walked: v.walked,
                deltas_applied: v.deltas,
            });
        }
    }
    Ok(out)
}

/// Header-vs-TIP invariants a healthy database file satisfies; each
/// violated invariant is returned as a message.
pub fn check_invariants(file: &crate::Image, page_size: usize) -> Vec<String> {
    let mut problems = Vec::new();
    let Some(h) = crate::page_at(file, page_size, 0).and_then(crate::HeaderPage::decode) else {
        return vec!["no header page".into()];
    };
    let _ = page_size;
    if h.oldest_transaction > h.oldest_active {
        problems.push(format!(
            "OIT {} > OAT {}",
            h.oldest_transaction, h.oldest_active
        ));
    }
    if h.oldest_active > h.next_transaction {
        problems.push(format!(
            "OAT {} > next {}",
            h.oldest_active, h.next_transaction
        ));
    }
    if h.oldest_snapshot > h.next_transaction {
        problems.push(format!(
            "OST {} > next {}",
            h.oldest_snapshot, h.next_transaction
        ));
    }
    problems
}

/// Convenience: page-size accessor for tools. A buffer too short to hold
/// the `hdr_page_size` field (offset 16, a u16) is not a database image -
/// `None`, not a panic - so a caller handed an empty or truncated image
/// (a detached zero-length pool image, say) gets an answer rather than a
/// crash.
pub fn page_size_of(file: &[u8]) -> Option<usize> {
    if file.len() < 18 {
        return None;
    }
    Some(u16_at(file, 16) as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The set a reader counts as its own. It was one id for as long as
    /// one attachment wrote under one transaction; an undo window writes
    /// under a nested one, so it is a set - and `None` (a tool reading a
    /// quiet file) must stay the EMPTY set rather than becoming
    /// "everything", which is the direction that would make a rolled-back
    /// row visible to `fcstat`.
    #[test]
    fn own_tx_is_a_set_and_none_is_empty() {
        let none = OwnTx::none();
        assert!(none.is_empty());
        assert!(!none.contains(0));
        assert!(!none.contains(7));
        assert_eq!(OwnTx::from(None), none);
        assert_eq!(OwnTx::from(Some(7)), OwnTx::one(7));

        let mut own = OwnTx::of([7u64, 9]);
        assert!(own.contains(7) && own.contains(9) && !own.contains(8));
        // pushing is idempotent: a window whose id is already counted
        // must not grow the set every time it is asked
        own.push(9);
        own.push(11);
        assert_eq!(own.ids(), &[7, 9, 11]);
    }

    #[test]
    fn apply_differences_matches_sqz_cpp() {
        // newer = "AAAABBBB"; diff: retain 4, replace 4 with "CCDD"
        let newer = b"AAAABBBB";
        let diff = [(-4i8) as u8, 4, b'C', b'C', b'D', b'D'];
        assert_eq!(apply_differences(&diff, newer).unwrap(), b"AAAACCDD");

        // shortening: retain 2 only -> length 2
        let diff = [(-2i8) as u8];
        assert_eq!(apply_differences(&diff, newer).unwrap(), b"AA");

        // literal overrun is an error (BUGCHECK 176)
        let diff = [3, b'X'];
        assert!(apply_differences(&diff, newer).is_none());

        // trailing nonzero garbage is an error (sqz.cpp:553)
        let newer2 = b"AB";
        let diff = [(-2i8) as u8, 7];
        assert!(apply_differences(&diff, newer2).is_none());
    }

    /// A file with one TIP page (page 1) whose transaction states the
    /// caller sets, and one data page (page 2) the caller fills.
    fn tip_file(page_size: usize, states: &[(u64, TxState)]) -> Vec<u8> {
        let mut f = vec![0u8; page_size * 3];
        f[0] = crate::PageType::Header as u8;
        f[16..18].copy_from_slice(&(page_size as u16).to_le_bytes());
        let t = page_size;
        f[t] = crate::PageType::TransactionInventory as u8;
        f[t + 12..t + 16].copy_from_slice(&1u32.to_le_bytes()); // pag_pageno
        for (id, st) in states {
            let byte = t + crate::tip::TIP_TRANSACTIONS_OFFSET + (*id as usize) / 4;
            let shift = 2 * ((*id as usize) % 4);
            f[byte] = (f[byte] & !(0b11 << shift)) | ((*st as u8) << shift);
        }
        f
    }

    /// COUNTING IS A VISIBILITY QUESTION, which is what the fast path
    /// behind `SELECT COUNT(*)` forgot: a rolled-back insert leaves a
    /// live primary header behind, and counting headers counts it.
    #[test]
    fn a_dead_transactions_row_is_not_counted() {
        let ps = 4096;
        let f = tip_file(
            ps,
            &[(11, TxState::Committed), (12, TxState::Dead), (13, TxState::Active)],
        );
        let img = crate::Image::from_bytes(&f, ps);
        let tips = TipChain::read(&img, ps).expect("tip chain");
        assert_eq!(tips.state(11), Some(TxState::Committed));
        assert_eq!(tips.state(12), Some(TxState::Dead));
        assert_eq!(tips.state(13), Some(TxState::Active));
        // the system transaction reads ACTIVE in the file and counts
        // anyway - the engine answers for id 0 in code
        assert_eq!(tips.state(0), Some(TxState::Active));
    }
}
