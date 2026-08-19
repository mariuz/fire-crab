//! The nbackup DIFFERENCE FILE (`<db>.delta`) - where the engine
//! diverts page writes while a database is in backup mode (BEGIN
//! BACKUP), so the main file stays frozen for a physical copy.
//!
//! The format, from nbak.cpp: ALLOCATION pages sit at delta positions
//! that are multiples of `pages_per_alloc + 1` (0, 2048, ... for 8K
//! pages, `pages_per_alloc = page_size/4 - 1`). An allocation page is
//! an array of little-endian u32: `[0]` = how many entries this page
//! holds, `[1 + i]` = the DATABASE page number stored at delta
//! position `alloc_pos + 1 + i`. BEGIN BACKUP writes one ZEROED page
//! (an empty table).

/// The database page numbers a delta holds, in allocation order:
/// `(db_page, delta_position)`.
pub fn delta_entries(delta: &[u8], page_size: usize) -> Result<Vec<(u32, usize)>, String> {
    if page_size < 8 || delta.len() < page_size {
        return Err("not a difference file".into());
    }
    let per_alloc = page_size / 4 - 1;
    let mut out = Vec::new();
    let mut alloc_pos = 0usize;
    loop {
        let base = alloc_pos * page_size;
        let Some(ap) = delta.get(base..base + page_size) else {
            return Err("a difference allocation page runs past the file".into());
        };
        let count = u32::from_le_bytes([ap[0], ap[1], ap[2], ap[3]]) as usize;
        if count > per_alloc {
            return Err("a difference allocation count is impossible".into());
        }
        for i in 0..count {
            let at = 4 + i * 4;
            let db_page = u32::from_le_bytes([ap[at], ap[at + 1], ap[at + 2], ap[at + 3]]);
            out.push((db_page, alloc_pos + 1 + i));
        }
        if count == per_alloc {
            alloc_pos += per_alloc + 1;
        } else {
            break;
        }
    }
    Ok(out)
}

/// Overlay a delta's pages onto a database image (raw bytes), the way
/// the engine reads a database that is in backup mode.
pub fn apply_delta(image: &mut Vec<u8>, delta: &[u8], page_size: usize) -> Result<(), String> {
    for (db_page, delta_pos) in delta_entries(delta, page_size)? {
        let src = delta_pos * page_size;
        let Some(page) = delta.get(src..src + page_size) else {
            return Err("a difference page runs past the file".into());
        };
        let end = (db_page as usize + 1) * page_size;
        if image.len() < end {
            image.resize(end, 0);
        }
        image[db_page as usize * page_size..end].copy_from_slice(page);
    }
    Ok(())
}

/// Write changed pages INTO a delta file: pages already in the table
/// are overwritten in place, new ones appended. One allocation page
/// only - a backup-mode write set past `page_size/4 - 1` pages refuses
/// rather than guessing at the chained-table append order.
pub fn upsert_delta_pages(
    path: &str,
    page_size: usize,
    changed: &[(u32, &[u8])],
) -> Result<(), String> {
    let mut delta = std::fs::read(path).map_err(|e| format!("difference file: {}", e))?;
    let entries = delta_entries(&delta, page_size)?;
    let per_alloc = page_size / 4 - 1;
    let mut count = entries.len();
    if count == per_alloc && !changed.is_empty() {
        return Err("the difference file's first allocation page is full".into());
    }
    for (db_page, page) in changed {
        if page.len() != page_size {
            return Err("a page of the wrong size".into());
        }
        let pos = match entries.iter().find(|(p, _)| p == db_page) {
            Some((_, pos)) => *pos,
            None => {
                if count == per_alloc {
                    return Err("the difference file's first allocation page is full".into());
                }
                let pos = 1 + count;
                let at = 4 + count * 4;
                delta[at..at + 4].copy_from_slice(&db_page.to_le_bytes());
                count += 1;
                delta[0..4].copy_from_slice(&(count as u32).to_le_bytes());
                pos
            }
        };
        let dst = pos * page_size;
        if delta.len() < dst + page_size {
            delta.resize(dst + page_size, 0);
        }
        delta[dst..dst + page_size].copy_from_slice(page);
    }
    std::fs::write(path, &delta).map_err(|e| format!("difference file: {}", e))
}
