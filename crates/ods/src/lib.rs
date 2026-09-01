//! # fire-crab-ods
//!
//! Rust decoding of Firebird's on-disk structure (ODS 14, Firebird 6),
//! converted from `src/jrd/ods.h` in the Firebird source tree. This is
//! fire-crab's first conversion slice: the storage layer, bottom-up,
//! chosen because every byte it produces can be checked against the
//! C++ engine's own files and tools (`gstat`) - differential testing
//! from day one.
//!
//! ## Conversion notes (methodology in `docs/methodology.md`)
//!
//! - Every struct here mirrors a C++ struct whose layout is pinned by
//!   `static_assert`s in `ods.h`; the same offsets are pinned by unit
//!   tests below. The C++ engine reads pages by casting buffers to
//!   `struct pag*`; the Rust conversion reads fields with explicit
//!   little-endian accessors instead - no `unsafe`, no alignment or
//!   endianness assumptions. (Firebird databases are little-endian on
//!   all supported platforms; big-endian hosts got a converted format
//!   historically, which fire-crab does not support, matching modern
//!   Firebird.)
//! - C++ `USHORT/ULONG/FB_UINT64` become `u16/u32/u64`. Transaction
//!   ids are `u64` (48-bit on disk since ODS 12+ widened markers).
//! - Record compression is converted from `src/jrd/sqz.cpp` including
//!   the Firebird 4+ extended run lengths (control bytes -1/-2).

pub mod delta;
pub mod blr;
pub mod btr;
pub mod btw;
pub mod catalog;
pub mod coll;
pub mod data;
pub mod ddl;
pub mod decfloat;
pub mod dml;
pub mod expr;
pub mod format;
pub mod gc;
pub mod gen;
pub mod header;
pub mod intl;
pub mod pages;
pub mod pip;
pub mod pointer;
pub mod sqz;
pub mod sysfmt;
pub mod tip;
pub mod tra;
pub mod val;
pub mod tz;

pub use blr::{decode as decode_blr, BlrDecode};
pub use btr::{walk_index_leaves, BtreePage, IndexRootPage};
pub use catalog::{
    count_primary_records, list_relations, relation_columns, resolve_relation, RelationColumn,
};
pub use data::{DataPage, RecordHeader};
pub use dml::{allocate_page, begin_active_tx, begin_committed_tx, delete_records, delete_records_under, insert_blob_slot, insert_record, insert_record_under, set_tx_state, update_record_under, update_records, DmlOutcome, InsertOutcome};
pub use header::{header_report, variable_header, HeaderClumplet};
pub use format::{
    decode_record, field_bytes, read_blob_content, relation_format_defaults, relation_formats,
    Descriptor, Value,
};
pub use gc::{analyze as gc_analyze, version_count, GcReport};
pub use header::HeaderPage;
pub use pages::{census, PageType};
pub use pip::PipPage;
pub use sysfmt::system_relation_formats;
pub use pointer::{relation_data_pages, PointerPage};
pub use tip::{TipPage, TxState};
pub use tra::{visible_rows, Snapshot, TipChain};

/// A database image addressed by PAGE rather than by absolute byte
/// offset. The pages live in a `Vec<Arc<[u8]>>`, so a reader shares them
/// by cloning `Arc`s and a writer copies only the one page it touches
/// (copy-on-write in [`Image::page_mut`]). That is what lets the buffer
/// pool publish - and a write make its work copy - in O(pages) rather
/// than O(file): the point of per-page fetch. The preparation slices
/// routed every whole-image access through `page_at`/`page_mut`, so this
/// representation change touches only their bodies and the type threaded
/// through the readers.
#[derive(Clone)]
pub struct Image {
    pages: Vec<std::sync::Arc<[u8]>>,
    page_size: usize,
    /// THE TRANSACTION A DDL STATEMENT WRITES UNDER. While set, every
    /// catalog row and back version the `ddl` module writes carries this
    /// id instead of a freshly minted committed one (`dml::
    /// allocate_committed_tx` answers it), so a ROLLBACK takes the
    /// statement back by transaction state - the engine's own way
    /// (DdlNodes.epp STOREs under the user transaction). `None` is the
    /// settled write: the tools, and a server that has no transaction.
    pub ddl_tx: Option<u64>,
    /// What a DDL statement under `ddl_tx` wrote that NO transaction
    /// state can take back - the residue a ROLLBACK must undo by hand.
    pub ddl_residue: Vec<DdlResidue>,
    /// What a DDL statement under `ddl_tx` must NOT do until COMMIT -
    /// the engine's deferred work (dfw.epp): a dropped relation's pages
    /// are released when the drop is final, not when it is said.
    pub ddl_deferred: Vec<DdlDeferred>,
}

/// A settled side effect of a DDL statement (see [Image::ddl_residue]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DdlResidue {
    /// an `RDB$PAGES` row - a system-transaction (tx 0) record the
    /// engine refuses under any other id (dpm.epp get_header); undone
    /// by blanking its directory slot, the post-sweep shape
    SysPagesRow { page: u32, slot: u16 },
    /// a page allocated for the new object - released back to its PIP
    Page(u32),
    /// a relation this transaction CREATED: every page it owns by the
    /// time of the rollback - its pointer and root pages, and the data
    /// pages the transaction's own INSERTs gave it - goes back, and its
    /// `RDB$PAGES` rows with them (dpm.epp's MRK_rollback resolution:
    /// DPM_delete_relation when the creator is dead)
    CreatedRelation { rel: u16 },
    /// an index this transaction CREATED: every bucket of the tree
    /// (found by `btr_relation`/`btr_id`, so the pages later inserts
    /// split into count too) released, the root slot zeroed
    IndexTree { irt_page: u32, rel: u16, slot: usize },
}
// NOTE deliberately ABSENT: a rolled-back DDL's own minted blobs are
// NOT freed as residue. The dead row versions that name them stay on
// the pages, and the ENGINE's version GC (a gbak attach's cooperative
// purge, gfix, sweep) frees a dead version's blobs BY ID - if this
// server had freed the slot and re-minted into it, the engine would
// free the NEW occupant (measured: gbak freed a table's live
// RDB$RUNTIME and then failed on it). Blob and referencing version
// must always go TOGETHER; at rollback that means both stay.

/// Deferred work of a DDL statement (see [Image::ddl_deferred]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DdlDeferred {
    /// release every page relation `rel` owns and wipe its `RDB$PAGES`
    /// rows - dfw.epp delete_relation, at commit
    DropRelation { rel: u16 },
    /// an index root slot's state goes `irt_drop` - ods.h:456's
    /// irt_commit -> irt_drop step, taken when the drop is final
    DropIndexSlot { irt_page: u32, slot: usize },
    /// a catalog blob a patch SUPERSEDED (the old RDB$RUNTIME, an ALTER
    /// DOMAIN's replaced validation pair, a re-granted ACL): freed when
    /// the change is final. The engine's shape differs only in timing -
    /// a user-transaction catalog update leaves the old blob to the
    /// version GC (vio.cpp:1694 purge -> BLB_garbage_collect:5649);
    /// fire-crab's sweep skips blob-bearing relations, so commit is the
    /// one moment this server can free it (guarded: not while another
    /// transaction is active - a snapshot may still read the old row
    /// version that names this blob)
    FreeBlob { rel: u16, recno: u64 },
    /// PURGE a patched catalog row's back-version chain when the patch
    /// is final: the freed blobs above are named by those back
    /// versions, and the engine's version GC frees a collected
    /// version's blobs BY ID - a stale reference plus a recycled slot
    /// makes it free the new occupant. The engine's own purge
    /// (vio.cpp:6977) removes chain and blob references together; so
    /// does this, at the same no-other-actives moment the frees run
    PurgeRowChain { rel: u16, page: u32, slot: u16 },
}

impl Image {
    /// Split a contiguous file image into pages. A trailing partial page
    /// (a file length not a whole multiple of `page_size`) is kept as its
    /// own short page so `to_bytes` round-trips it.
    pub fn from_bytes(bytes: &[u8], page_size: usize) -> Image {
        let pages = if page_size == 0 {
            Vec::new()
        } else {
            bytes.chunks(page_size).map(std::sync::Arc::from).collect()
        };
        Image {
            pages,
            page_size,
            ddl_tx: None,
            ddl_residue: Vec::new(),
            ddl_deferred: Vec::new(),
        }
    }

    /// The whole image as one contiguous vector - for a whole-file write
    /// or a caller that still needs a flat buffer.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.byte_len());
        for p in &self.pages {
            out.extend_from_slice(p);
        }
        out
    }

    #[inline]
    pub fn page_size(&self) -> usize {
        self.page_size
    }

    /// Number of pages in the image.
    #[inline]
    pub fn num_pages(&self) -> usize {
        self.pages.len()
    }

    /// The image's length in bytes - what `file.len()` used to answer.
    #[inline]
    pub fn byte_len(&self) -> usize {
        self.pages.iter().map(|p| p.len()).sum()
    }

    /// The bytes of page `page`, `None` when there is no such page.
    #[inline]
    pub fn page(&self, page: u32) -> Option<&[u8]> {
        self.pages.get(page as usize).map(|a| a.as_ref())
    }

    /// The MUTABLE bytes of page `page`, copying that one page out of any
    /// sharing first (copy-on-write) so a writer never disturbs a reader's
    /// snapshot. `None` when there is no such page.
    #[inline]
    pub fn page_mut(&mut self, page: u32) -> Option<&mut [u8]> {
        let arc = self.pages.get_mut(page as usize)?;
        if std::sync::Arc::get_mut(arc).is_none() {
            let owned: std::sync::Arc<[u8]> = std::sync::Arc::from(&**arc);
            *arc = owned;
        }
        std::sync::Arc::get_mut(arc)
    }

    /// Iterate the pages as slices - what `file.pages()`
    /// used to produce (a trailing short page is skipped, as chunks_exact
    /// dropped a partial final chunk).
    pub fn pages(&self) -> impl Iterator<Item = &[u8]> {
        let ps = self.page_size;
        self.pages
            .iter()
            .map(|a| a.as_ref())
            .filter(move |p| p.len() == ps)
    }

    /// Grow the image to cover at least `bytes` bytes by appending zeroed
    /// whole pages - what `file.resize(bytes, 0)` did for a file that only
    /// ever grows by whole pages.
    pub fn grow(&mut self, bytes: usize) {
        if self.page_size == 0 {
            return;
        }
        let want = bytes.div_ceil(self.page_size);
        while self.pages.len() < want {
            self.pages
                .push(std::sync::Arc::from(vec![0u8; self.page_size]));
        }
    }

    /// The page numbers whose bytes differ from `base` - by `Arc` IDENTITY
    /// (O(1) per page, no byte compare), exact because a writer only ever
    /// replaces a page's `Arc` through `page_mut`. A page present on one
    /// side and not the other counts as changed.
    pub fn changed_pages(&self, base: &Image) -> Vec<u32> {
        let n = self.pages.len().max(base.pages.len());
        (0..n)
            .filter(|&i| match (self.pages.get(i), base.pages.get(i)) {
                (Some(a), Some(b)) => !std::sync::Arc::ptr_eq(a, b),
                (a, b) => a.is_some() != b.is_some(),
            })
            .map(|i| i as u32)
            .collect()
    }
}

/// Page `page`'s bytes, or `None`. Free-function twin of [`Image::page`],
/// kept at the historical three-argument shape - the `page_size` argument
/// is redundant now (the image carries it) but every call site passes it,
/// so keeping it means the representation change did not have to touch
/// them.
#[inline]
pub fn page_at(file: &Image, _page_size: usize, page: u32) -> Option<&[u8]> {
    file.page(page)
}

/// The mutable twin - see [`page_at`] and [`Image::page_mut`].
#[inline]
pub fn page_mut(file: &mut Image, _page_size: usize, page: u32) -> Option<&mut [u8]> {
    file.page_mut(page)
}

/// Read a `u16` at `offset`, little-endian, like the engine's
/// in-memory access to an aligned USHORT field on x86/ARM.
#[inline]
pub(crate) fn u16_at(buf: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([buf[offset], buf[offset + 1]])
}

#[inline]
pub(crate) fn u32_at(buf: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        buf[offset],
        buf[offset + 1],
        buf[offset + 2],
        buf[offset + 3],
    ])
}

#[inline]
pub(crate) fn u64_at(buf: &[u8], offset: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&buf[offset..offset + 8]);
    u64::from_le_bytes(b)
}
