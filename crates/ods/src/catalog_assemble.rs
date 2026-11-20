//! Slice 7: the canonical fresh-database assembly - slices 1-6 in
//! pipeline order, the one function `op_create` calls. The per-slice
//! tests pin the bytes; this module owns only the order and the
//! handoffs (the allocator out of slice 4 into slice 6). Page sizes:
//! the three `op_create` serves (8192/16384/32768); 4096 was never a
//! template size and the bulk index build does not fit there.

use crate::catalog_format::{create_system_storage, format_skeleton};
use crate::catalog_index::store_system_indexes;
use crate::catalog_remaining::store_remaining_catalog;
use crate::catalog_rows::store_core_catalog;
use crate::catalog_runtime::store_runtime_blobs;
use crate::Image;

/// Assemble a fresh database: skeleton, system storage, core rows,
/// system indices, runtime blobs, remaining rows. `creation` is the
/// header's (days, ticks) stamp, `owner` the creating user (stored
/// uppercased by the caller - the engine stores usernames upper).
pub fn assemble_fresh_database(
    page_size: usize,
    guid: &[u8; 16],
    creation: (i32, u32),
    owner: &str,
) -> Result<Vec<u8>, String> {
    let bytes = format_skeleton(page_size, guid, creation);
    let mut file = Image::from_bytes(&bytes, page_size);
    create_system_storage(&mut file, page_size)?;
    let mut alloc = store_core_catalog(&mut file, page_size, owner)?;
    store_system_indexes(&mut file, page_size)?;
    store_runtime_blobs(&mut file, page_size)?;
    store_remaining_catalog(&mut file, page_size, owner, &mut alloc)?;
    Ok(file.to_bytes())
}
