//! Database validation, converted from the shape of `gfix -v [-full]`
//! (jrd/validation.cpp seen from its OBSERVABLE side): a page walk that
//! counts what is broken into the categories gfix prints, without
//! changing a byte.
//!
//! The engine runs validation DURING the verify attach and gfix reads
//! the counts back through `isc_database_info` (alice/exe.cpp:110-117,
//! the `val_errors` item list), printing one line per NON-ZERO counter.
//! A clean database is SILENCE - all sixteen counters zero - which is
//! also what makes an unconverted server dangerous here: a server that
//! skips the info items it does not know answers gfix with no counters
//! at all, and gfix prints the same silence a genuinely clean file gets.
//! This module is what makes that silence MEAN something.
//!
//! THE TAXONOMY WAS MEASURED, one corruption at a time, against the live
//! engine (`gfix -v -full -n` on copies of the same file):
//!
//!   * a DATA page whose type byte is wrong: `database page errors: 1`,
//!     no warning;
//!   * a data page whose record directory is absurd: `data page
//!     errors: 1` - one per page, not per entry;
//!   * a POINTER page or a BTREE page whose type byte is wrong:
//!     `database page errors: 1` AND `database page warnings: 1` - the
//!     orphaned subtree behind it is the warning;
//!   * a record whose back pointer aims PAST THE FILE, under `-full`:
//!     not a count at all - the attach itself fails with `I/O error
//!     during "read" operation / -File size is less than expected`
//!     (the engine read the page the pointer named); plain `-v` does
//!     not walk records and stays silent;
//!   * a TIP page whose type byte is wrong: a CASCADE (296 page errors
//!     on a 313-page file - every validation that needed a transaction
//!     state) - this walk counts the broken page itself and leaves the
//!     cascade as a recorded difference in the gate.
//!
//! The walk takes the CATALOG ROUTE where the engine does: relations
//! and their pointer pages come from RDB$PAGES (relation 0, reached
//! through the same bootstrap the catalog uses), because a pointer page
//! whose type byte is gone cannot be found by scanning for pointer
//! pages - the corruption hides itself from the scan that would report
//! it.

use crate::data::{flags, DataPage, DPG_RPT_OFFSET, RHD_DATA_OFFSET};
use crate::format::Value;
use crate::pages::PageType;
use crate::pointer::PointerPage;
use crate::tra::TipChain;

/// The sixteen counters gfix asks for, in `alice/exe.cpp`'s own item
/// order (val_errors[]): errors 54-60, warnings 115-121, PIP 122-123.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ValCounts {
    pub page_errors: u64,   // isc_info_page_errors   (54)
    pub record_errors: u64, // isc_info_record_errors (55)
    pub bpage_errors: u64,  // isc_info_bpage_errors  (56)
    pub dpage_errors: u64,  // isc_info_dpage_errors  (57)
    pub ipage_errors: u64,  // isc_info_ipage_errors  (58)
    pub ppage_errors: u64,  // isc_info_ppage_errors  (59)
    pub tpage_errors: u64,  // isc_info_tpage_errors  (60)
    pub page_warns: u64,    // fb_info_page_warns     (115)
    pub record_warns: u64,  // fb_info_record_warns   (116)
    pub bpage_warns: u64,   // fb_info_bpage_warns    (117)
    pub dpage_warns: u64,   // fb_info_dpage_warns    (118)
    pub ipage_warns: u64,   // fb_info_ipage_warns    (119)
    pub ppage_warns: u64,   // fb_info_ppage_warns    (120)
    pub tpage_warns: u64,   // fb_info_tpage_warns    (121)
    pub pip_errors: u64,    // fb_info_pip_errors     (122)
    pub pip_warns: u64,     // fb_info_pip_warns      (123)
}

impl ValCounts {
    pub fn clean(&self) -> bool {
        *self == ValCounts::default()
    }

    /// The counters in the wire item order, paired with their info
    /// codes - what `op_info_database` answers gfix with.
    pub fn items(&self) -> [(u8, u64); 16] {
        [
            (54, self.page_errors),
            (55, self.record_errors),
            (56, self.bpage_errors),
            (57, self.dpage_errors),
            (58, self.ipage_errors),
            (59, self.ppage_errors),
            (60, self.tpage_errors),
            (115, self.page_warns),
            (116, self.record_warns),
            (117, self.bpage_warns),
            (118, self.dpage_warns),
            (119, self.ipage_warns),
            (120, self.ppage_warns),
            (121, self.tpage_warns),
            (122, self.pip_errors),
            (123, self.pip_warns),
        ]
    }
}

/// A validation that cannot COUNT: the engine aborts the attach instead.
#[derive(Debug, PartialEq, Eq)]
pub enum ValAbort {
    /// a page pointer aimed past the end of the file - the engine reads
    /// the page the pointer names and the read fails hard ("File size
    /// is less than expected"), so the verify attach fails rather than
    /// reporting a count
    PastEof { page: u32 },
    /// a TRANSACTION INVENTORY page whose type is wrong: the engine
    /// cannot attach a file whose transaction states it cannot read, so
    /// the verify attach fails with `isc_db_corrupt` + "wrong page
    /// type" + the page-level detail rather than counting (measured -
    /// "page 287 is of wrong type (expected transaction inventory,
    /// found purposely undefined)")
    WrongPageType { page: u32, expected: u8, found: u8 },
    /// the file is not a database this walk can hold an opinion on
    Broken(String),
}

/// The engine's pretty page-type names (`pagtype`, jrd/ods.cpp:130) -
/// the strings the wrong-page-type vector carries as arguments.
pub fn page_type_name(t: u8) -> &'static str {
    const NAMES: [&str; 11] = [
        "purposely undefined",
        "database header",
        "page inventory",
        "transaction inventory",
        "pointer",
        "data",
        "index root",
        "index B-tree",
        "blob",
        "generators",
        "SCN inventory",
    ];
    NAMES.get(t as usize).copied().unwrap_or("unknown")
}

/// One record directory entry, bounds-checked the way the engine's
/// data-page validation is: an entry that points outside the page (or
/// a directory that itself overruns the page) is ONE data-page error
/// for the page, however many entries are wrong.
fn data_page_structure_ok(page: &[u8], page_size: usize) -> bool {
    let count = crate::u16_at(page, 22) as usize; // dpg_count
    let dir_top = DPG_RPT_OFFSET + count * 4;
    if dir_top > page_size {
        return false;
    }
    for i in 0..count {
        let at = DPG_RPT_OFFSET + i * 4;
        let (off, len) = (
            crate::u16_at(page, at) as usize,
            crate::u16_at(page, at + 2) as usize,
        );
        if len == 0 {
            continue; // an empty slot is legal (a freed record)
        }
        if off < dir_top || off + len > page_size || len < RHD_DATA_OFFSET {
            return false;
        }
    }
    true
}

/// RDB$PAGES rows read STATE-BLIND - chain heads taken as they stand,
/// no transaction states consulted - for the one caller that cannot
/// consult them: naming the broken TIP page. A validation of a corrupt
/// file reads what is there.
fn pages_rows_stateless(file: &[u8], page_size: usize) -> Vec<(u32, u16, u16)> {
    let Some(formats) = crate::sysfmt::system_relation_formats(file, page_size, "RDB$PAGES")
    else {
        return Vec::new();
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for dp_no in crate::pointer::relation_data_pages(file, page_size, 0) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if !r.is_primary_record() {
                continue;
            }
            let Some(img) = crate::data::assembled_image(file, page_size, &r) else {
                continue;
            };
            let vals = crate::format::decode_record(&img, descs);
            let (num, rel, ptype) = match (vals.first(), vals.get(1), vals.get(3)) {
                (Some(Value::Int(n)), Some(Value::Int(r)), Some(Value::Int(t))) => {
                    (*n as u32, *r as u16, *t as u16)
                }
                _ => continue,
            };
            out.push((num, rel, ptype));
        }
    }
    out
}

/// Validate the file: the page walk of `gfix -v`, plus the record walk
/// under `full` (`-full`). Counts, or the abort the engine turns into a
/// failed attach.
pub fn validate(file: &[u8], page_size: usize, full: bool) -> Result<ValCounts, ValAbort> {
    let mut c = ValCounts::default();
    if crate::HeaderPage::decode(file).is_none() {
        return Err(ValAbort::Broken("no header page".into()));
    }
    let npages = (file.len() / page_size) as u32;
    let page_of = |no: u32| crate::page_at(file, page_size, no);

    // THE FIXED-POSITION PAGES: page 1 is the first PIP and page 2 the
    // first SCN page on every modern file - positions the ODS pins, so
    // a wrong type THERE is checkable without any catalog. (The engine
    // answers a broken SCN page with a CASCADE - every SCN-consulted
    // check fails too, 296 errors on a 313-page file - where this walk
    // counts the page itself; the gate records that difference.)
    if let Some(p1) = page_of(1) {
        if p1[0] != PageType::PageInventory as u8 {
            c.pip_errors += 1;
        }
    }
    if let Some(p2) = page_of(2) {
        if p2[0] != 10 {
            // pag_scns - no PageType variant needed for one check
            c.page_errors += 1;
        }
    }

    // THE TRANSACTION INVENTORY, first: everything below consults it,
    // and the ENGINE cannot attach a file whose transaction states it
    // cannot read - a broken TIP fails the verify attach with the
    // corruption vector, it does not count (measured). The TIP is found
    // the way the engine's own bugcheck names it: the first type-3 page
    // is where the chain should start; when NO page reads as a TIP, the
    // page that should have been one is unknowable from the wreck, so
    // the walk names the one the header's transaction count says must
    // exist somewhere - page 0 stands in as "the file, corrupt".
    let tips = TipChain::read(file, page_size);
    if tips.is_none() {
        // NAME THE PAGE THE ENGINE WOULD NAME. RDB$PAGES declares the
        // TIP pages (type 3, relation 0), and it can be read without
        // the transaction states the wreck took away - state-blind,
        // chain heads as they stand. The first declared TIP whose type
        // byte disagrees is the page the engine's own fetch trips over.
        let page = pages_rows_stateless(file, page_size)
            .into_iter()
            .filter(|(_, _, t)| *t == 3)
            .map(|(num, _, _)| num)
            .find(|num| !page_of(*num).is_some_and(|p| p[0] == 3))
            .unwrap_or(0);
        let found = page_of(page).map(|p| p[0]).unwrap_or(0);
        return Err(ValAbort::WrongPageType { page, expected: 3, found });
    }

    // RDB$PAGES - the catalog's own map of relations to their pointer
    // and index-root pages. This is the route the corruption cannot
    // hide from: a pointer page with no type byte is invisible to a
    // scan but RDB$PAGES still names it.
    let pages_rows: Vec<(u32, u16, u16)> = match (
        crate::sysfmt::system_relation_formats(file, page_size, "RDB$PAGES"),
        tips.as_ref(),
    ) {
        (Some(formats), Some(_)) => {
            let descs = formats
                .iter()
                .max_by_key(|(n, _)| *n)
                .map(|(_, d)| d.clone())
                .unwrap_or_default();
            crate::tra::visible_rows(file, page_size, 0, &descs, tips.as_ref().unwrap())
                .into_iter()
                .filter_map(|r| {
                    // RDB$PAGE_NUMBER, RDB$RELATION_ID, RDB$PAGE_SEQUENCE,
                    // RDB$PAGE_TYPE - in declaration order
                    let num = match r.values.first() {
                        Some(Value::Int(n)) => *n as u32,
                        _ => return None,
                    };
                    let rel = match r.values.get(1) {
                        Some(Value::Int(n)) => *n as u16,
                        _ => return None,
                    };
                    let ptype = match r.values.get(3) {
                        Some(Value::Int(n)) => *n as u16,
                        _ => return None,
                    };
                    Some((num, rel, ptype))
                })
                .collect()
        }
        _ => Vec::new(),
    };

    let mut pointer_pages: Vec<(u32, u16)> = Vec::new(); // (page, relation)
    let mut root_pages: Vec<(u32, u16)> = Vec::new();
    for (num, rel, ptype) in pages_rows {
        if num >= npages {
            return Err(ValAbort::PastEof { page: num });
        }
        match ptype {
            4 => pointer_pages.push((num, rel)), // pag_pointer
            6 => root_pages.push((num, rel)),    // pag_root
            _ => {}
        }
    }

    // POINTER PAGES, then the data pages they declare.
    for (pp_no, rel) in &pointer_pages {
        let Some(page) = page_of(*pp_no) else {
            return Err(ValAbort::PastEof { page: *pp_no });
        };
        let Some(pp) = PointerPage::decode(page) else {
            // the measured shape: one error, and one warning for the
            // subtree nothing can reach any more
            c.page_errors += 1;
            c.page_warns += 1;
            continue;
        };
        if pp.relation != *rel {
            c.ppage_errors += 1;
            continue;
        }
        for dp_no in pp.data_pages() {
            if dp_no >= npages {
                return Err(ValAbort::PastEof { page: dp_no });
            }
            let Some(dpage) = page_of(dp_no) else {
                return Err(ValAbort::PastEof { page: dp_no });
            };
            if dpage[0] != PageType::Data as u8 {
                // measured: a broken data page is one error, NO warning
                c.page_errors += 1;
                continue;
            }
            if crate::u16_at(dpage, 20) != *rel {
                // dpg_relation disagrees with the pointer page
                c.dpage_errors += 1;
                continue;
            }
            if !data_page_structure_ok(dpage, page_size) {
                c.dpage_errors += 1;
                continue;
            }
            if full {
                // THE RECORD WALK (`-full`): every version reachable.
                let Some(dp) = DataPage::decode(dpage) else {
                    c.dpage_errors += 1;
                    continue;
                };
                for r in dp.records() {
                    if r.back_page != 0 {
                        if r.back_page >= npages {
                            // the engine READS the page this names, and
                            // the read past the end fails the attach
                            return Err(ValAbort::PastEof { page: r.back_page });
                        }
                        let ok = page_of(r.back_page)
                            .and_then(DataPage::decode)
                            .and_then(|bp| bp.record(r.back_line))
                            .is_some();
                        if !ok {
                            c.record_errors += 1;
                        }
                    }
                    if let Some((fp, fl)) = r.frag_ptr {
                        if r.flags & flags::INCOMPLETE != 0 {
                            if fp >= npages {
                                return Err(ValAbort::PastEof { page: fp });
                            }
                            let ok = page_of(fp)
                                .and_then(DataPage::decode)
                                .and_then(|f2| f2.record(fl))
                                .is_some();
                            if !ok {
                                c.record_errors += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    // INDEX ROOTS, and each index's tree. `walk_index_leaves` descends
    // the leftmost path and then crosses the leaf level, so a broken
    // page on either is found; an interior page off the leftmost path
    // of a deep tree is not - stated rather than hidden, and every
    // fixture this project can build has depth <= 1.
    for (root_no, rel) in &root_pages {
        let Some(page) = page_of(*root_no) else {
            return Err(ValAbort::PastEof { page: *root_no });
        };
        let Some(root) = crate::btr::IndexRootPage::decode(page) else {
            c.page_errors += 1;
            c.page_warns += 1;
            continue;
        };
        for entry in root.live_entries() {
            if entry.root_page == 0 {
                continue;
            }
            if entry.root_page >= npages {
                return Err(ValAbort::PastEof { page: entry.root_page });
            }
            if crate::btr::walk_index_leaves(file, page_size, *rel, entry.id).is_none() {
                // the measured shape for a broken btree page: one
                // error, one warning
                c.page_errors += 1;
                c.page_warns += 1;
            }
        }
    }

    Ok(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The structural check is per PAGE, as the engine counts it: a
    /// directory that overruns the page is one error however many
    /// entries it would take to get there.
    #[test]
    fn a_mad_directory_is_one_error() {
        let ps = 4096usize;
        let mut page = vec![0u8; ps];
        page[0] = PageType::Data as u8;
        // count = 60000: the directory alone would overrun the page
        page[22..24].copy_from_slice(&60000u16.to_le_bytes());
        assert!(!data_page_structure_ok(&page, ps));
        // a sane page with one freed slot passes
        page[22..24].copy_from_slice(&2u16.to_le_bytes());
        let off = (ps - 20) as u16;
        page[DPG_RPT_OFFSET..DPG_RPT_OFFSET + 2].copy_from_slice(&off.to_le_bytes());
        page[DPG_RPT_OFFSET + 2..DPG_RPT_OFFSET + 4].copy_from_slice(&20u16.to_le_bytes());
        // slot 1 freed: off 0, len 0
        assert!(data_page_structure_ok(&page, ps));
        // an entry pointing outside the page fails
        page[DPG_RPT_OFFSET + 2..DPG_RPT_OFFSET + 4].copy_from_slice(&9000u16.to_le_bytes());
        assert!(!data_page_structure_ok(&page, ps));
    }

    /// The sixteen counters map to gfix's own info items, in
    /// alice/exe.cpp's val_errors[] order.
    #[test]
    fn the_items_carry_the_wire_codes() {
        let mut c = ValCounts::default();
        assert!(c.clean());
        c.dpage_errors = 3;
        assert!(!c.clean());
        let items = c.items();
        assert_eq!(items[0].0, 54);
        assert_eq!(items[3], (57, 3));
        assert_eq!(items[15].0, 123);
    }
}
