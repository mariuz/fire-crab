//! Slice 5: the system index builds (`store_indices`, ini.epp:1682-1760)
//! over the ported `idx.h` table - plus the skeleton completion the
//! earlier slices deferred: the TIP and generator pages with their two
//! `RDB$PAGES` rows and the create-time header counters.
//!
//! The engine interleaves definition and build per index and keys
//! later rows incrementally; this path stores all 100 definitions,
//! registers all slots and roots, then bulk-builds each tree over the
//! rows so far. Same content, different page shapes - the
//! nativecreate gate compares catalog rows and `gfix` cleanliness,
//! never index bytes. Slice 6 keys its own rows as it stores them
//! through [maintain_row], the engine's `IDX_store` half.
//!
//! Everything structural is pinned against the fresh 2182 file:
//! definition rows and counts, per-relation `RDB$INDEX_ID`s, root
//! entries (field ids, forced itypes, flags), TIP bytes, generator
//! values and header counters.

use crate::catalog_format::descriptors_for;
use crate::catalog_index_def::SYS_INDICES;
use crate::catalog_rows::{encode_image, rel_by_name, rel_col, Cell};
use crate::dml;
use crate::format::{Descriptor, Value};
use crate::pages::PageType;
use crate::Image;

/// A covering index in maintenance form: its root slot, flags and
/// (field, forced itype, scale) segments.
pub struct CoverPlan {
    pub slot: u8,
    pub unique: bool,
    pub descending: bool,
    pub segs: Vec<(u16, u16, i8)>,
}

/// Every system index on a relation, in `idx.h` order, with its root
/// slot (its ordinal: `RDB$INDEX_ID` is slot + 1) and forced table
/// itypes. The itypes are FORCED, never derived: `RDB$INDEX_32` keys
/// its int64 with `idx_numeric` (0) where the user-index path would
/// stamp `NUMERIC2` (probed off the engine's own roots).
pub fn plans_for(rel_id: u16) -> Vec<CoverPlan> {
    let mut plans = Vec::new();
    for idx in SYS_INDICES {
        let rel = rel_by_name(idx.relation);
        if rel.id != rel_id {
            continue;
        }
        let descs = descriptors_for(rel);
        let pos = |field: &str| {
            rel.fields.iter().position(|f| f.name == field).unwrap_or_else(|| panic!("{} has no {field}", rel.name))
        };
        let segs = idx.segments[..idx.count as usize]
            .iter()
            .map(|s| {
                let f = pos(s.field) as u16;
                (f, u16::from(s.itype), descs[f as usize].scale)
            })
            .collect();
        plans.push(CoverPlan { slot: plans.len() as u8, unique: idx.unique, descending: idx.descending, segs });
    }
    plans
}

/// Key one stored row into every covering tree - the `IDX_store` half
/// slice 6 calls after each row it stores. `recno` is the row's record
/// number, `values` its decoded image under `descs`.
pub fn maintain_row(
    file: &mut Image,
    page_size: usize,
    rel_id: u16,
    recno: u64,
    values: &[Value],
    descs: &[Descriptor],
) -> Result<(), String> {
    let null = Value::Null;
    for plan in plans_for(rel_id) {
        let key_segs: Vec<crate::btw::KeySeg<'_>> = plan
            .segs
            .iter()
            .map(|(field, itype, scale)| crate::btw::KeySeg {
                itype: *itype,
                value: values.get(*field as usize).unwrap_or(&null),
                scale: *scale,
                charset: descs
                    .get(*field as usize)
                    .map_or(0, |d| crate::intl::charset_id(d.sub_type)),
            })
            .collect();
        let (key, _) = crate::btw::build_index_key(&key_segs, plan.descending)
            .ok_or("unsupported value for a system index key")?;
        crate::btw::insert_index_entry(
            file,
            page_size,
            rel_id,
            plan.slot,
            &key,
            recno,
            plan.unique,
            plan.descending,
        )?;
    }
    Ok(())
}

/// The TIP page, generator page, their `RDB$PAGES` rows and the
/// create-time header counters - what `INI_format`'s transaction and
/// generator traffic leaves behind (dpm.epp:1459, tra.cpp:614).
///
/// TIP bytes are the pristine engine file's: transactions 1..4
/// committed (`fc 03`, the `4` pre-set by the engine's own create -
/// verified on two pristine creates), the rest virgin-active. The
/// generator page carries zeros plus `RDB$RELATIONS` = 128
/// (`USER_DEF_REL_INIT_ID`, ini.epp:779); slice 6 fills the consumed
/// values as it consumes them. Header: next 4, OIT 2, OAT/OST 3
/// (ods.h:747-749); next attachment is 1 - this path never attaches,
/// where the engine's remote create used two.
pub fn store_skeleton_pages(file: &mut Image, page_size: usize) -> Result<(), String> {
    let tip_page = dml::allocate_page(file, page_size)?;
    {
        let page = crate::page_mut(file, page_size, tip_page).ok_or("TIP page range")?;
        page.fill(0);
        page[0] = PageType::TransactionInventory as u8;
        page[12..16].copy_from_slice(&tip_page.to_le_bytes()); // pag_pageno @12
        // tip_next @16 stays 0; states @20: txns 1..4 committed.
        page[20] = 0xfc;
        page[21] = 0x03;
    }
    let gen_page = dml::allocate_page(file, page_size)?;
    {
        let page = crate::page_mut(file, page_size, gen_page).ok_or("generator page range")?;
        page.fill(0);
        page[0] = PageType::Generators as u8;
        page[12..16].copy_from_slice(&gen_page.to_le_bytes()); // pag_pageno @12
        // gpg_sequence @16 stays 0; slot 13 (RDB$RELATIONS) = 128.
        page[24 + 13 * 8..24 + 14 * 8].copy_from_slice(&128i64.to_le_bytes());
    }
    // The two RDB$PAGES rows, gen then TIP - the engine file's order.
    let pages = rel_by_name("RDB$PAGES");
    let descs = descriptors_for(pages);
    for (page_no, page_type) in [(gen_page, PageType::Generators as u8), (tip_page, PageType::TransactionInventory as u8)] {
        let image = encode_image(
            &descs,
            &[
                (rel_col(0, "RDB$PAGE_NUMBER"), Cell::Int(i64::from(page_no))),
                (rel_col(0, "RDB$RELATION_ID"), Cell::Int(0)),
                (rel_col(0, "RDB$PAGE_SEQUENCE"), Cell::Int(0)),
                (rel_col(0, "RDB$PAGE_TYPE"), Cell::Int(i64::from(page_type))),
            ],
        );
        dml::insert_record_system(file, page_size, 0, 0, &image)?;
    }
    let header = crate::page_mut(file, page_size, 0).ok_or("header page range")?;
    header[40..48].copy_from_slice(&4u64.to_le_bytes());
    header[48..56].copy_from_slice(&2u64.to_le_bytes());
    header[56..64].copy_from_slice(&3u64.to_le_bytes());
    header[64..72].copy_from_slice(&3u64.to_le_bytes());
    header[72..80].copy_from_slice(&1u64.to_le_bytes());
    Ok(())
}

/// The 100 `RDB$INDICES` rows with their 177 `RDB$INDEX_SEGMENTS` rows
/// and 32 `RDB$RELATION_CONSTRAINTS` rows (`store_indices` minus the
/// physical build). `RDB$INDEX_ID` is the per-relation ordinal + 1,
/// precomputed here and asserted at slot allocation; statistics stay
/// NULL - the engine's ini path never writes them.
pub fn store_index_definitions(file: &mut Image, page_size: usize) -> Result<(), String> {
    let mut ordinals: std::collections::HashMap<&str, u8> = std::collections::HashMap::new();
    for idx in SYS_INDICES {
        let ordinal = ordinals.entry(idx.relation).or_insert(0);
        let index_id = *ordinal + 1;
        *ordinal += 1;
        let name = format!("RDB$INDEX_{}", idx.id);

        let mut cells = vec![
            (rel_col(4, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
            (rel_col(4, "RDB$RELATION_NAME"), Cell::Text(idx.relation)),
            (rel_col(4, "RDB$INDEX_NAME"), Cell::Text(&name)),
            (rel_col(4, "RDB$UNIQUE_FLAG"), Cell::Int(i64::from(idx.unique))),
            (rel_col(4, "RDB$SEGMENT_COUNT"), Cell::Int(i64::from(idx.count))),
            (rel_col(4, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
            (rel_col(4, "RDB$INDEX_INACTIVE"), Cell::Int(0)),
            (rel_col(4, "RDB$INDEX_ID"), Cell::Int(i64::from(index_id))),
        ];
        if idx.descending {
            cells.push((rel_col(4, "RDB$INDEX_TYPE"), Cell::Int(1)));
        }
        let image = encode_image(&descriptors_for(rel_by_name("RDB$INDICES")), &cells);
        dml::insert_record_system(file, page_size, 4, 0, &image)?;

        for (position, seg) in idx.segments[..idx.count as usize].iter().enumerate() {
            let image = encode_image(
                &descriptors_for(rel_by_name("RDB$INDEX_SEGMENTS")),
                &[
                    (rel_col(3, "RDB$FIELD_POSITION"), Cell::Int(position as i64)),
                    (rel_col(3, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                    (rel_col(3, "RDB$INDEX_NAME"), Cell::Text(&name)),
                    (rel_col(3, "RDB$FIELD_NAME"), Cell::Text(seg.field)),
                ],
            );
            dml::insert_record_system(file, page_size, 3, 0, &image)?;
        }

        if idx.unique {
            let image = encode_image(
                &descriptors_for(rel_by_name("RDB$RELATION_CONSTRAINTS")),
                &[
                    (rel_col(22, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                    (rel_col(22, "RDB$CONSTRAINT_NAME"), Cell::Text(&name)),
                    (rel_col(22, "RDB$INDEX_NAME"), Cell::Text(&name)),
                    (rel_col(22, "RDB$RELATION_NAME"), Cell::Text(idx.relation)),
                    (rel_col(22, "RDB$CONSTRAINT_TYPE"), Cell::Text("UNIQUE")),
                    (rel_col(22, "RDB$DEFERRABLE"), Cell::Text("NO")),
                    (rel_col(22, "RDB$INITIALLY_DEFERRED"), Cell::Text("NO")),
                ],
            );
            dml::insert_record_system(file, page_size, 22, 0, &image)?;
        }
    }
    Ok(())
}

/// Register every slot and root and bulk-build each tree over the
/// rows so far - the `IDX_create_index(AtOnce)` half. The allocated
/// slot must equal the precomputed ordinal or the build stops: that
/// is the `RDB$INDEX_ID` the definitions already carry.
pub fn build_system_indexes(file: &mut Image, page_size: usize) -> Result<(), String> {
    for idx in SYS_INDICES {
        let rel = rel_by_name(idx.relation);
        let plans = plans_for(rel.id);
        let ordinal = SYS_INDICES[..idx.id as usize].iter().filter(|i| i.relation == idx.relation).count();
        let plan = &plans[ordinal];
        let mut iflags = 0u16;
        if idx.unique {
            iflags |= crate::btw::IRT_UNIQUE;
        }
        if idx.descending {
            iflags |= crate::btw::IRT_DESCENDING;
        }
        let slot = crate::ddl::allocate_index_slot(file, page_size, rel.id, &plan.segs, iflags)?;
        if slot as u8 != plan.slot {
            return Err(format!("index slot drift for RDB$INDEX_{}", idx.id));
        }
        let descs = descriptors_for(rel);
        crate::ddl::backfill_index(
            file,
            page_size,
            rel.id,
            slot,
            &plan.segs,
            &descs,
            idx.unique,
            idx.descending,
            false,
        )?;
    }
    Ok(())
}

/// The whole slice: skeleton pages, definitions, builds.
pub fn store_system_indexes(file: &mut Image, page_size: usize) -> Result<(), String> {
    store_skeleton_pages(file, page_size)?;
    store_index_definitions(file, page_size)?;
    build_system_indexes(file, page_size)?;
    Ok(())
}
