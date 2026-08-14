//! The page cache and its careful-write precedence graph - the
//! conversion of `src/jrd/cch.cpp` (CCH_precedence / check_precedence,
//! write_buffer's recursive drain, clear_precedence) that the paper's
//! careful-writes chapter opens up.
//!
//! Firebird has no write-ahead log. Crash safety is the ORDER of page
//! writes: if the referenced page (PIP, child bucket, fresh data page)
//! always reaches disk before the page that references it, a crash
//! between two writes leaves a file that existed at some real earlier
//! instant - never an inconsistent one. The precedence graph is that
//! order made load-bearing: an in-memory dependency graph over dirty
//! buffers, built edge-by-edge by every code path touching related
//! pages, drained recursively before every physical write.
//!
//! THE ORACLE IS THE ENGINE'S OWN VALIDATOR AND READER. The crash
//! harness (`fccch crash-matrix`) takes a real multi-page operation
//! (a batch of inserts through `fire_crab_ods::dml` that grows the
//! relation - header, TIP, PIP, pointer and data pages all move),
//! sequences the changed pages through this cache's flush, and
//! materializes EVERY crash prefix - the file as it would exist had
//! the process died after write k. `gfix -v -full` must find nothing
//! wrong with ANY prefix, and `isql` must read exactly the rows that
//! were committed before the operation began (all of them, none of the
//! interrupted work). The same matrix in NAIVE order (the exact
//! reverse) must break at some prefix - proving the gate can tell
//! careful from careless, not merely that the workload is harmless.

use std::collections::{BTreeMap, BTreeSet};

/// The buffer pool: one image per FILE per process, shared by every
/// attachment to it, with the writers over it serialized. See
/// [`pool`] for why a private image per attachment was not a cache at
/// all.
pub mod pool;

/// `related()`'s bounded search depth (cch.cpp caps the transitive
/// walk; past the limit it assumes a relationship exists and forces
/// the write - "force it now when in doubt")
const RELATED_LIMIT: usize = 1000;

/// One cached page - `BufferDesc` reduced to what a single-attachment,
/// synchronous flush needs: the working bytes and the dirty flag.
struct Buffer {
    data: Vec<u8>,
    dirty: bool,
}

/// The cache: an in-memory "disk" image, the buffers over it, and the
/// precedence graph (`bdb_higher` / `bdb_lower` as adjacency sets -
/// `higher[p]` holds the pages that must be written BEFORE `p`).
pub struct Cache {
    pub page_size: usize,
    image: Vec<u8>,
    buffers: BTreeMap<u32, Buffer>,
    higher: BTreeMap<u32, BTreeSet<u32>>,
    lower: BTreeMap<u32, BTreeSet<u32>>,
    /// every physical write, in the order it hit the image - what the
    /// crash harness slices into prefixes
    writes: Vec<u32>,
}

impl Cache {
    /// Attach over a file image.
    pub fn attach(image: Vec<u8>, page_size: usize) -> Cache {
        Cache {
            page_size,
            image,
            buffers: BTreeMap::new(),
            higher: BTreeMap::new(),
            lower: BTreeMap::new(),
            writes: Vec::new(),
        }
    }

    /// CCH_fetch: read a page into its buffer (zeros past EOF - a
    /// fresh page being allocated). Returns the buffered bytes.
    pub fn fetch(&mut self, page: u32) -> &[u8] {
        let ps = self.page_size;
        let start = page as usize * ps;
        let image = &self.image;
        let entry = self.buffers.entry(page).or_insert_with(|| {
            let mut data = vec![0u8; ps];
            if let Some(src) = image.get(start..) {
                let n = src.len().min(ps);
                data[..n].copy_from_slice(&src[..n]);
            }
            Buffer { data, dirty: false }
        });
        &entry.data
    }

    /// CCH_mark after a write access: replace the buffer's bytes and
    /// flag it dirty. (The harness works at whole-page granularity;
    /// the engine's in-place mutation collapses to the same thing.)
    pub fn mark(&mut self, page: u32, bytes: Vec<u8>) {
        assert_eq!(bytes.len(), self.page_size, "a page is a page");
        self.fetch(page);
        let b = self.buffers.get_mut(&page).expect("just fetched");
        b.data = bytes;
        b.dirty = true;
    }

    /// CCH_precedence / check_precedence: `first` must reach disk
    /// before `window` ("given a window accessed for write and a page
    /// number, establish a precedence relationship such that the
    /// specified page will always be written before the page
    /// associated with the window"). If `window` already precedes
    /// `first` transitively, the edge would close a cycle - the engine
    /// breaks the tie by WRITING the window page immediately instead
    /// of creating the relationship, and so does this.
    pub fn precedence(&mut self, window: u32, first: u32) {
        if window == first {
            return;
        }
        // already recorded, or `first` is not even dirty - nothing to
        // order (clear_precedence drops edges as pages clean up)
        if !self.buffers.get(&first).map(|b| b.dirty).unwrap_or(false) {
            return;
        }
        if self.higher.get(&window).is_some_and(|s| s.contains(&first)) {
            return;
        }
        if self.related(first, window, RELATED_LIMIT) {
            // window transitively precedes first: adding the edge
            // would deadlock the graph - write window NOW
            self.write_buffer(window);
            return;
        }
        self.higher.entry(window).or_default().insert(first);
        self.lower.entry(first).or_default().insert(window);
    }

    /// `related()`: is `to` reachable from `from` along the
    /// must-write-first edges? Bounded depth-first search; past the
    /// limit, assume it is (and let the caller force the write).
    fn related(&self, from: u32, to: u32, mut budget: usize) -> bool {
        let mut stack = vec![from];
        let mut seen = BTreeSet::new();
        while let Some(p) = stack.pop() {
            if budget == 0 {
                return true;
            }
            budget -= 1;
            if p == to {
                return true;
            }
            if !seen.insert(p) {
                continue;
            }
            if let Some(next) = self.higher.get(&p) {
                stack.extend(next.iter().copied());
            }
        }
        false
    }

    /// write_buffer: before this page's own bytes go to disk, drain
    /// its higher-precedence queue - recursively writing every page
    /// that must precede it - then write the page itself. This is what
    /// makes the graph load-bearing rather than advisory: whichever
    /// path flushes a page first is forced through the same order,
    /// because the order lives on the buffer, not in the caller.
    pub fn write_buffer(&mut self, page: u32) {
        loop {
            let Some(&first) = self.higher.get(&page).and_then(|s| s.iter().next())
            else {
                break;
            };
            self.write_buffer(first);
        }
        if self.buffers.get(&page).map(|b| b.dirty).unwrap_or(false) {
            self.write_page(page);
        }
    }

    /// The physical write: buffer bytes into the image (extending the
    /// file exactly as far as this page requires - how a real disk
    /// file grows mid-sequence), dirty flag off, edges cleared.
    fn write_page(&mut self, page: u32) {
        let ps = self.page_size;
        let start = page as usize * ps;
        let b = self.buffers.get_mut(&page).expect("writing an unfetched page");
        if self.image.len() < start + ps {
            self.image.resize(start + ps, 0);
        }
        self.image[start..start + ps].copy_from_slice(&b.data);
        b.dirty = false;
        self.writes.push(page);
        self.clear_precedence(page);
    }

    /// clear_precedence: the page is on disk - every edge that named
    /// it as "must go first" is satisfied and comes down.
    fn clear_precedence(&mut self, page: u32) {
        if let Some(lows) = self.lower.remove(&page) {
            for low in lows {
                if let Some(s) = self.higher.get_mut(&low) {
                    s.remove(&page);
                    if s.is_empty() {
                        self.higher.remove(&low);
                    }
                }
            }
        }
    }

    /// CCH_flush: write every dirty buffer, lowest page number first -
    /// each write draining its own precedence chain ahead of itself.
    pub fn flush(&mut self) {
        let dirty: Vec<u32> = self
            .buffers
            .iter()
            .filter(|(_, b)| b.dirty)
            .map(|(p, _)| *p)
            .collect();
        for p in dirty {
            self.write_buffer(p);
        }
    }

    /// The physical write order the flush produced.
    pub fn write_order(&self) -> &[u32] {
        &self.writes
    }

    pub fn into_image(self) -> Vec<u8> {
        self.image
    }
}

// ------------------------------------------------------ the harness

/// The pages on which `before` and `after` differ (after may be
/// longer - freshly allocated pages diff against zeros).
pub fn changed_pages(before: &[u8], after: &[u8], page_size: usize) -> Vec<u32> {
    let pages = after.len().div_ceil(page_size);
    let mut out = Vec::new();
    for p in 0..pages {
        let start = p * page_size;
        let a = after.get(start..(start + page_size).min(after.len())).unwrap_or(&[]);
        let b = before
            .get(start..(start + page_size).min(before.len()))
            .unwrap_or(&[]);
        let same = a.len() == b.len() && a == b
            || (b.is_empty() && a.iter().all(|&x| x == 0));
        if !same {
            out.push(p as u32);
        }
    }
    out
}

/// A page's type byte (`pag_type` at offset 0).
pub fn page_type(image: &[u8], page_size: usize, page: u32) -> u8 {
    image
        .get(page as usize * page_size)
        .copied()
        .unwrap_or(0)
}

/// Build the careful-write plan for a before→after file transition:
/// mark every changed page, then establish the precedence edges the
/// engine's call sites would have established while making the same
/// change, and flush. Each rule mirrors a documented call-site
/// invariant (careful-writes-and-crash-safety.md, "what gets ordered,
/// concretely"):
///
///  - a fresh or changed DATA page precedes the POINTER page that
///    names it (dpm.epp: never point into space)
///  - a changed B-TREE page precedes the INDEX-ROOT page (btr.cpp:
///    "so that the root page doesn't point into space")
///  - a changed BLOB page precedes the DATA pages whose records
///    reference it
///  - the HEADER page (transaction high-water) precedes every page
///    that names a transaction (CCH_tra_precedence's invariant)
///  - the TIP write goes LAST: the commit flip is the atomic
///    visibility switch, and TRA_set_state forces it only after the
///    work it commits is on disk
///
/// PIP placement is the engine's deallocation chain read backwards
/// (dpm.epp: "pip → pp → deallocated page → prior_page" is the
/// must-be-written-AFTER order for freeing): for ALLOCATION the
/// inverse holds - the fresh page's content and the pointer to it are
/// written before the PIP bit is (an interrupted sequence leaks
/// nothing and frees nothing early).
pub fn careful_plan(before: &[u8], after: &[u8], page_size: usize) -> Cache {
    let changed = changed_pages(before, after, page_size);
    let cache = Cache::attach(before.to_vec(), page_size);
    build_plan(
        cache,
        &changed,
        page_size,
        |p| page_type(after, page_size, p),
        |p| {
            let start = p as usize * page_size;
            after
                .get(start..(start + page_size).min(after.len()))
                .unwrap_or(&[])
                .to_vec()
        },
    )
}

/// [`careful_plan`] given a changed set found by ARC IDENTITY. The
/// per-page-fetch flush compares the work image's page `Arc`s against the
/// on-disk baseline's - O(pages), not a whole-file byte diff - and hands
/// the set here. The precedence graph and the write order are identical
/// to [`careful_plan`]'s; only how the changed set was found differs.
///
/// A write always copies its page out ([`fire_crab_ods::Image::page_mut`]
/// is copy-on-write), so a written page has a new `Arc` and is caught. A
/// page written back to the bytes it already held is caught too - the
/// set is a SUPERSET of the byte diff - and re-writing an unchanged page
/// leaves the file identical, so it costs a page write and nothing else.
pub fn careful_plan_paged(after: &fire_crab_ods::Image, changed: &[u32]) -> Cache {
    let page_size = after.page_size();
    // the write order needs the precedence graph, not the base image, so
    // this Cache attaches over nothing; the flush reads each page's bytes
    // from `after` directly.
    let cache = Cache::attach(Vec::new(), page_size);
    build_plan(
        cache,
        changed,
        page_size,
        |p| after.page(p).and_then(|b| b.first().copied()).unwrap_or(0),
        |p| after.page(p).map(<[u8]>::to_vec).unwrap_or_default(),
    )
}

/// The careful-write precedence graph, built from the changed pages and
/// their TYPES (not their bytes). Shared by [`careful_plan`] and
/// [`careful_plan_paged`]: `type_of` gives a page's `pag_type`, and
/// `page_bytes` its `page_size` bytes.
fn build_plan(
    mut cache: Cache,
    changed: &[u32],
    page_size: usize,
    type_of: impl Fn(u32) -> u8,
    page_bytes: impl Fn(u32) -> Vec<u8>,
) -> Cache {
    let mut by_type: BTreeMap<u8, Vec<u32>> = BTreeMap::new();
    for &p in changed {
        let mut page = page_bytes(p);
        page.resize(page_size, 0);
        cache.mark(p, page);
        by_type.entry(type_of(p)).or_default().push(p);
    }
    let of = |t: u8, m: &BTreeMap<u8, Vec<u32>>| m.get(&t).cloned().unwrap_or_default();
    let header = of(1, &by_type);
    let pip = of(2, &by_type);
    let tip = of(3, &by_type);
    let pointer = of(4, &by_type);
    let data = of(5, &by_type);
    let root = of(6, &by_type);
    let btree = of(7, &by_type);
    let blob = of(8, &by_type);
    // content before reference
    for &pp in &pointer {
        for &d in &data {
            cache.precedence(pp, d);
        }
    }
    for &r in &root {
        for &b in &btree {
            cache.precedence(r, b);
        }
    }
    // an index entry names a record NUMBER: the data page holding
    // the record precedes the btree page holding the entry (the
    // slice-1 matrix passed this by page-number luck; the edge makes
    // it law)
    for &b in &btree {
        for &d in &data {
            cache.precedence(b, d);
        }
    }
    for &d in &data {
        for &b in &blob {
            cache.precedence(d, b);
        }
    }
    // allocation bits between the content and the pointer: the PIP
    // bit goes out after the page it allocates exists (an interrupted
    // sequence leaks nothing) but BEFORE the pointer that names the
    // page - gfix itself proved the pointer half: a pointer-page
    // prefix written ahead of its PIP validated with page errors
    for &ip in &pip {
        for &d in &data {
            cache.precedence(ip, d);
        }
    }
    for &pp in &pointer {
        for &ip in &pip {
            cache.precedence(pp, ip);
        }
    }
    // the header's transaction high-water before any page naming one
    for &h in &header {
        for &p in changed {
            if type_of(p) != 1 {
                cache.precedence(p, h);
            }
        }
    }
    // the commit flip last
    for &t in &tip {
        for &p in changed {
            if type_of(p) != 3 {
                cache.precedence(t, p);
            }
        }
    }
    cache.flush();
    cache
}

/// The file as it exists after the first `k` writes of `order` - the
/// crash prefix the harness validates. The image grows exactly as far
/// as the written pages require, like a real file mid-sequence.
pub fn crash_prefix(
    before: &[u8],
    after: &[u8],
    page_size: usize,
    order: &[u32],
    k: usize,
) -> Vec<u8> {
    let mut out = before.to_vec();
    for &p in &order[..k] {
        let start = p as usize * page_size;
        if out.len() < start + page_size {
            out.resize(start + page_size, 0);
        }
        let src = &after[start..(start + page_size).min(after.len())];
        out[start..start + src.len()].copy_from_slice(src);
        for b in out[start + src.len()..start + page_size].iter_mut() {
            *b = 0;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cache_with(pages: &[u32]) -> Cache {
        let ps = 32;
        let mut c = Cache::attach(vec![0u8; ps * 8], ps);
        for &p in pages {
            c.mark(p, vec![p as u8 + 1; ps]);
        }
        c
    }

    #[test]
    fn flush_respects_precedence_chains() {
        let mut c = cache_with(&[1, 2, 3]);
        // 3 before 2 before 1 - the flush starts at page 1 and the
        // recursive drain must invert it
        c.precedence(1, 2);
        c.precedence(2, 3);
        c.flush();
        assert_eq!(c.write_order(), &[3, 2, 1]);
    }

    #[test]
    fn cycle_breaks_by_writing_the_window_now() {
        let mut c = cache_with(&[1, 2]);
        c.precedence(1, 2); // 2 first
        c.precedence(2, 1); // would close the cycle -> writes 2 NOW
        assert_eq!(c.write_order(), &[2]);
        c.flush();
        assert_eq!(c.write_order(), &[2, 1]);
    }

    #[test]
    fn clean_pages_impose_no_order() {
        let mut c = cache_with(&[1]);
        c.fetch(5); // fetched, never marked
        c.precedence(1, 5); // 5 is clean - no edge
        c.flush();
        assert_eq!(c.write_order(), &[1]);
    }

    #[test]
    fn crash_prefixes_grow_the_file_like_a_disk() {
        let ps = 32;
        let before = vec![1u8; ps * 2];
        let mut after = vec![1u8; ps * 2];
        after.extend(vec![7u8; ps]); // a freshly allocated page 2
        let order = [2u32];
        let p0 = crash_prefix(&before, &after, ps, &order, 0);
        assert_eq!(p0.len(), ps * 2); // untouched: no growth
        let p1 = crash_prefix(&before, &after, ps, &order, 1);
        assert_eq!(p1.len(), ps * 3);
        assert_eq!(&p1[ps * 2..], &[7u8; 32]);
    }
}
