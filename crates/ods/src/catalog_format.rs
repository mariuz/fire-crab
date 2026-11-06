//! Format the pages a new database file starts life with: the header,
//! the first PIP and the first SCN page (`PAG_format_header` /
//! `PAG_format_pip`, pag.cpp:773-880). Everything else - TIP, generator,
//! pointer, data, root, index and blob pages - the allocator mints while
//! the later slices store the catalog, exactly as `INI_format` does.
//! Page generations stay 0 here: the engine's own creations differ in
//! them (like GUID, creation time and counters), so compares mask them.

use crate::catalog_init::{SysRelation, SYS_FIELDS, SYS_RELATIONS};
use crate::dml;
use crate::format::{flag_bytes, Descriptor, Value};
use crate::header::HDR_DATA_OFFSET;
use crate::pages::PageType;
use crate::pip::PIP_BITS_OFFSET;
use crate::sysfmt::compute_format;

/// `FIRST_PIP_PAGE` / `FIRST_SCN_PAGE` (ods.h:237-238).
pub const FIRST_PIP_PAGE: u32 = 1;
pub const FIRST_SCN_PAGE: u32 = 2;

/// Fresh-format flags: dialect 3 + forced writes (`hdr_SQL_dialect_3 |
/// hdr_force_write`), what a bare engine create carries (0x12).
pub const FORMAT_FLAGS: u16 = 0x12;

/// The creating machine's description (`DbImplementation::store`):
/// x64, Linux, gcc, no flags - byte 80..84 of every file this code
/// formats, as on the engine-made files it is compared against.
pub const FORMAT_DB_IMPL: [u8; 4] = [1, 1, 1, 0];

fn blank_page(page_size: usize, page_type: PageType) -> Vec<u8> {
    let mut page = vec![0u8; page_size];
    page[0] = page_type as u8;
    page
}

/// The header page of a new file (`PAG_format_header`): type, page
/// size, ODS 14.0, implementation, dialect-3 + forced-write flags,
/// oldest transaction 1, `hdr_end` at `hdr_data` with the `HDR_end`
/// clumplet, the GUID and creation stamp passed in. Everything else -
/// counters, `pages_page`, buffers, shadow, crypt - is zero, as after
/// `CCH_fake`.
pub fn format_header_page(
    page_size: usize,
    guid: &[u8; 16],
    creation: (i32, u32),
) -> Vec<u8> {
    let mut page = blank_page(page_size, PageType::Header);
    page[16..18].copy_from_slice(&(page_size as u16).to_le_bytes());
    page[18..20].copy_from_slice(&0x800eu16.to_le_bytes());
    page[20..22].copy_from_slice(&0u16.to_le_bytes());
    page[22..24].copy_from_slice(&FORMAT_FLAGS.to_le_bytes());
    page[36..38].copy_from_slice(&(HDR_DATA_OFFSET as u16).to_le_bytes());
    page[48..56].copy_from_slice(&1u64.to_le_bytes());
    page[80..84].copy_from_slice(&FORMAT_DB_IMPL);
    page[84..100].copy_from_slice(guid);
    page[100..104].copy_from_slice(&creation.0.to_le_bytes());
    page[104..108].copy_from_slice(&creation.1.to_le_bytes());
    page
}

/// The first PIP (`PAG_format_pip`): `pip_used` and `pip_min` cover
/// header + PIP + SCN, every bit set (free) except 0, 1 and 2.
pub fn format_pip_page(page_size: usize) -> Vec<u8> {
    let mut page = blank_page(page_size, PageType::PageInventory);
    let used = FIRST_SCN_PAGE + 1;
    page[16..20].copy_from_slice(&used.to_le_bytes());
    page[20..24].copy_from_slice(&0u32.to_le_bytes());
    page[24..28].copy_from_slice(&used.to_le_bytes());
    for b in page[PIP_BITS_OFFSET..].iter_mut() {
        *b = 0xff;
    }
    page[PIP_BITS_OFFSET] &= !(1 | 2 | (1 << FIRST_SCN_PAGE));
    page
}

/// The first SCN page (`PAG_format_pip`'s non-temporary branch): type
/// and sequence 0, the rest zero.
pub fn format_scn_page(page_size: usize) -> Vec<u8> {
    blank_page(page_size, PageType::ScnInventory)
}

/// The file `PAG_format_pip` leaves behind: header, PIP, SCN.
pub fn format_skeleton(
    page_size: usize,
    guid: &[u8; 16],
    creation: (i32, u32),
) -> Vec<u8> {
    let mut file = format_header_page(page_size, guid, creation);
    file.extend_from_slice(&format_pip_page(page_size));
    file.extend_from_slice(&format_scn_page(page_size));
    file
}

/// Record descriptors for a system relation, the ini.epp:1053-1088
/// walk over the ported tables: each relation field takes its global's
/// dtype/length/subtype. System globals carry no scale.
pub fn descriptors_for(rel: &SysRelation) -> Vec<Descriptor> {
    let fields: Vec<(u8, u16, i8, i16)> = rel
        .fields
        .iter()
        .map(|f| {
            let g = SYS_FIELDS.iter().find(|g| g.key == f.global).unwrap_or_else(|| {
                panic!("{} references unknown global {}", rel.name, f.global)
            });
            (g.dtype, g.length, 0, g.sub_type)
        })
        .collect();
    compute_format(&fields)
}

/// A record image from integer values: the null-flag area with every
/// field marked NULL, then each value little-endian at its
/// descriptor's offset, sized by the descriptor's length (1/2/4/8).
/// Slice 3 stores only integers (RDB$PAGES); text/blob values arrive
/// with the rows that need them.
pub fn encode_int_image(descs: &[Descriptor], values: &[(usize, i64)]) -> Vec<u8> {
    let len = descs.iter().map(|d| d.offset as usize + d.length as usize).max().unwrap_or(0);
    let mut image = vec![0u8; len.max(flag_bytes(descs.len()) as usize)];
    for i in 0..descs.len() {
        image[i / 8] |= 1 << (i % 8);
    }
    for (fid, v) in values {
        let d = &descs[*fid];
        let bytes = v.to_le_bytes();
        let n = d.length as usize;
        assert!(n == 1 || n == 2 || n == 4 || n == 8, "non-integer field in int image");
        image[d.offset as usize..d.offset as usize + n].copy_from_slice(&bytes[..n]);
        image[fid / 8] &= !(1 << (fid % 8));
    }
    image
}

/// Storage for every persistent system relation, in `relfields` order
/// (`DPM_create_relation` over `INI_format`'s first loop): a pointer
/// page and an index root page each, the header's `pages_page` anchor
/// for relation 0, and the two `RDB$PAGES` rows per relation - stored
/// under the system transaction, exactly as `DPM_pages` stores them,
/// so the allocator hands out the same pages in the same order (3..83
/// plus the rows' data page 5). Formats are NOT written: a fresh
/// engine file carries no `RDB$FORMATS` rows.
/// The packing delta: the engine RLE-packs only relation 0's own two
/// rows here (and, later, the generator/TIP rows) while leaving the
/// identical shapes beside them NOT_PACKED; this path packs every
/// record that shrinks (`packed_rhd`, the established writer), which
/// the engine reads identically. Slice 7 masks record packing in its
/// file compare.
pub fn create_system_storage(file: &mut crate::Image, page_size: usize) -> Result<(), String> {
    let pages = SYS_RELATIONS.iter().find(|r| r.id == 0).ok_or("no RDB$PAGES in ported tables")?;
    let pages_descs = descriptors_for(pages);
    let fid = |name: &str| {
        pages.fields.iter().position(|f| f.name == name).ok_or_else(|| format!("RDB$PAGES has no {name}"))
    };
    let (f_page, f_rel, f_seq, f_type) =
        (fid("RDB$PAGE_NUMBER")?, fid("RDB$RELATION_ID")?, fid("RDB$PAGE_SEQUENCE")?, fid("RDB$PAGE_TYPE")?);
    for rel in SYS_RELATIONS.iter().filter(|r| r.persistent) {
        let pointer_page = dml::allocate_page(file, page_size)?;
        {
            let page = crate::page_mut(file, page_size, pointer_page).ok_or("pointer page range")?;
            page.fill(0);
            page[0] = PageType::Pointer as u8;
            page[1] = 1; // ppg_eof
            page[12..16].copy_from_slice(&pointer_page.to_le_bytes());
            page[26..28].copy_from_slice(&rel.id.to_le_bytes());
        }
        if rel.id == 0 {
            let header = crate::page_mut(file, page_size, 0).ok_or("header page range")?;
            header[28..32].copy_from_slice(&pointer_page.to_le_bytes());
        }
        let root_page = dml::allocate_page(file, page_size)?;
        {
            let page = crate::page_mut(file, page_size, root_page).ok_or("root page range")?;
            page.fill(0);
            page[0] = PageType::IndexRoot as u8;
            page[12..16].copy_from_slice(&root_page.to_le_bytes());
            page[16..18].copy_from_slice(&rel.id.to_le_bytes());
            page[18..20].copy_from_slice(&0u16.to_le_bytes());
        }
        for (page_no, page_type) in [(pointer_page, PageType::Pointer as u8), (root_page, PageType::IndexRoot as u8)] {
            let image = encode_int_image(
                &pages_descs,
                &[(f_page, page_no as i64), (f_rel, rel.id as i64), (f_seq, 0), (f_type, page_type as i64)],
            );
            dml::insert_record_system(file, page_size, 0, 0, &image)?;
        }
    }
    Ok(())
}

/// Decode every `RDB$PAGES` row as (relation, type, page, sequence),
/// for the tests' oracle compare.
pub fn read_pages_rows(file: &crate::Image, page_size: usize) -> Vec<(i64, i64, i64, i64)> {
    use crate::data::DataPage;
    use crate::format::decode_record;
    use crate::pointer::relation_data_pages;
    let pages = SYS_RELATIONS.iter().find(|r| r.id == 0).expect("ported RDB$PAGES");
    let descs = descriptors_for(pages);
    let mut out = Vec::new();
    for dp_no in relation_data_pages(file, page_size, 0) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, None) else {
                continue;
            };
            let vals = decode_record(&image, &descs);
            let num = |i: usize| match vals.get(i) {
                Some(Value::Int(n)) => *n,
                v => panic!("RDB$PAGES col {i} decoded as {v:?}"),
            };
            out.push((num(1), num(3), num(0), num(2)));
        }
    }
    out
}
