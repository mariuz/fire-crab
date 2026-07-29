//! fire-crab-pio - platform I/O, converted from
//! `src/jrd/os/posix/unix.cpp` (the `PIO_*` layer) with the open-flag and
//! locking rules from the same file.
//!
//! This is the floor of the engine: every page the cache reads or writes
//! goes through here, and everything above it - careful writes, the PIP,
//! the whole ODS - assumes these few arithmetic and flag laws hold. They
//! are small enough to state completely, which is exactly why they are
//! worth pinning: an off-by-one in the page-offset formula produces a
//! database that decodes *almost* correctly.
//!
//! # The addressing law
//!
//! `offset = page * page_size`, from `seek_file` (unix.cpp:850-882) -
//! absolute, from the start of the file, with no per-file rebasing.
//! Firebird 6 has no multi-file databases: `jrd_file` (pio.h:41-49) is
//! one descriptor with no chain and no page range, so there is no
//! "which file holds this page" question left to answer. Older
//! Firebirds had `fil_min_page`/`fil_max_page`; converting the current
//! engine means converting its absence.
//!
//! # The page-count law
//!
//! `PIO_get_number_of_pages` is `file_size / page_size` - INTEGER
//! division (unix.cpp:517). A trailing partial page is not counted and
//! not an error at this level; the engine simply cannot address it. That
//! is why `MON$DATABASE.MON$PAGES` and the file's length agree exactly on
//! a healthy database, and it is the differential this crate is checked
//! by.
//!
//! # The open-flag law
//!
//! `openFile` (unix.cpp:885-911):
//!
//! ```text
//! flag = O_BINARY | (readOnly ? O_RDONLY : O_RDWR)
//! if (forceWrite)   flag |= SYNC       // O_DSYNC where available, else O_SYNC
//! if (notUseFSCache) flag |= O_DIRECT
//! ```
//!
//! Forced Writes is therefore not an fsync-per-write policy but an OPEN
//! MODE, and switching it at runtime (`gfix -w`) means reopening the
//! file - which is why `PIO_force_write` flushes FIRST when turning it on
//! (unix.cpp:449): the pages already in the OS cache were written under
//! the old promise.
//!
//! # The lock law, and why fire-crab can read a live database
//!
//! `lockDatabaseFile` takes an `flock` on the whole file - `LOCK_EX`
//! normally, `LOCK_SH` in shared-write mode, always with `LOCK_NB` - and
//! turns a busy lock into `isc_already_opened`. That is the error behind
//! *"Database already opened with engine instance, incompatible with
//! current"*: a second engine instance refusing to share a file.
//!
//! fire-crab's readers take NO lock. That is a deliberate difference, not
//! an oversight: it is what lets `fcstat`, `fcauth stored` and every
//! differential read a database the server holds open. The cost is that a
//! read can catch a torn page (the engine is writing), so every gate that
//! reads a live file must have a freshness signal of its own - see
//! `qa/auth-srp.sh`, which learned that the hard way.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::{FileExt, OpenOptionsExt};

/// `jrd_file::fil_flags` (pio.h:76-81).
pub mod flags {
    pub const FORCE_WRITE: u16 = 1;
    pub const NO_FS_CACHE: u16 = 2;
    pub const READONLY: u16 = 4;
    pub const SH_WRITE: u16 = 8;
    pub const NO_FAST_EXTEND: u16 = 16;
    pub const RAW_DEVICE: u16 = 32;
}

/// Header-page flags (`ods.h:722-728`), the ones that DECIDE how the file
/// is opened. This is the link between the on-disk structure and this
/// layer: `gfix -w sync` sets `hdr_force_write`, and the next attach turns
/// that bit into an `SYNC` in the open flags.
pub mod hdr {
    pub const ACTIVE_SHADOW: u16 = 0x1;
    pub const FORCE_WRITE: u16 = 0x2;
    pub const CRYPT_PROCESS: u16 = 0x4;
    pub const NO_RESERVE: u16 = 0x8;
    pub const SQL_DIALECT_3: u16 = 0x10;
    pub const READ_ONLY: u16 = 0x20;
    pub const ENCRYPTED: u16 = 0x40;
    /// `hdr_flags` sits at offset 22 of the header page
    /// (ods.h:677 static_assert)
    pub const FLAGS_OFFSET: usize = 22;
}

/// The names `gstat -h` prints for the header flags, in its order - so a
/// differential can compare text with text.
pub fn header_attribute_names(flags: u16) -> Vec<&'static str> {
    let mut v = Vec::new();
    if flags & hdr::FORCE_WRITE != 0 {
        v.push("force write");
    }
    if flags & hdr::NO_RESERVE != 0 {
        v.push("no reserve");
    }
    if flags & hdr::READ_ONLY != 0 {
        v.push("read only");
    }
    if flags & hdr::ENCRYPTED != 0 {
        v.push("encrypted");
    }
    if flags & hdr::ACTIVE_SHADOW != 0 {
        v.push("active shadow");
    }
    v
}

/// The open plan the engine would use for a database whose header carries
/// `flags`, with the configuration's `no_fs_cache` setting - i.e. how a
/// stored bit becomes an open(2) mode.
pub fn plan_for_header(flags: u16, no_fs_cache: bool) -> OpenPlan {
    OpenPlan {
        read_only: flags & hdr::READ_ONLY != 0,
        force_write: flags & hdr::FORCE_WRITE != 0,
        no_fs_cache,
    }
}

/// `IO_RETRY` (unix.cpp:91): how many times a short or interrupted
/// pread/pwrite is retried before the operation is an error.
pub const IO_RETRY: usize = 20;

/// `ZeroBuffer::DEFAULT_SIZE` (common/classes/File.h:49) - the size of
/// the zero block `PIO_init_data` writes with, so the number of pages it
/// zeroes per syscall is `256 KB / page_size`.
pub const ZERO_BUFFER_SIZE: usize = 1024 * 256;

/// `PIO_init_data` refuses to touch anything below page 8
/// (unix.cpp:615): the first pages are written explicitly by database
/// creation, and zeroing them would destroy the header, the first PIP and
/// the first pointer page.
pub const INIT_DATA_FLOOR: u32 = 8;

/// The byte offset of a page - `seek_file` (unix.cpp:872-874).
///
/// The engine also checks that the offset survives the platform's
/// `off_t`; on a 64-bit build that check cannot fire, and
/// [`page_offset_checked`] is where it lives for the record.
pub fn page_offset(page: u32, page_size: u32) -> u64 {
    page as u64 * page_size as u64
}

/// `seek_file`'s overflow guard: the engine compares the 64-bit product
/// against its `off_t`-cast form and raises
/// `isc_io_32bit_exceeded_err` when they differ. Converted as an explicit
/// refusal rather than dropped, because "cannot address this page" is a
/// different answer from "read it".
pub fn page_offset_checked(page: u32, page_size: u32, off_bits: u32) -> Result<u64, String> {
    let off = page_offset(page, page_size);
    if off_bits < 64 && off >= (1u64 << off_bits) {
        return Err(format!(
            "page {} at offset {} exceeds a {}-bit file offset",
            page, off, off_bits
        ));
    }
    Ok(off)
}

/// `PIO_get_number_of_pages` (unix.cpp:517): integer division, so a
/// trailing partial page is invisible.
pub fn number_of_pages(file_len: u64, page_size: u32) -> u32 {
    if page_size == 0 {
        return 0;
    }
    (file_len / page_size as u64) as u32
}

/// Whether the file's length is an exact multiple of the page size.
///
/// The engine does not test this - it just divides - but a healthy
/// database always satisfies it, so a false answer here means either a
/// truncated file or a page size read wrong, and both are worth refusing
/// before decoding anything.
pub fn length_is_whole_pages(file_len: u64, page_size: u32) -> bool {
    page_size != 0 && file_len % page_size as u64 == 0
}

/// `PIO_extend` (unix.cpp:312-370): the `fallocate` offset and length for
/// growing a file by `ext_pages`, clamped the way the engine clamps it
/// (`MIN(MAX_ULONG - filePages, extPages)`).
pub fn extend_plan(file_pages: u32, ext_pages: u32, page_size: u32) -> (u64, u64) {
    let extend_by = ext_pages.min(u32::MAX - file_pages);
    (
        file_pages as u64 * page_size as u64,
        extend_by as u64 * page_size as u64,
    )
}

/// `PIO_init_data` (unix.cpp:585-648): which pages a zero-fill request
/// actually touches, and in how many syscalls.
///
/// Returns `(first_page, pages, syscalls)`. A request below
/// [`INIT_DATA_FLOOR`] touches nothing at all.
pub fn init_data_plan(start_page: u32, init_pages: u16, page_size: u32) -> (u32, u32, u32) {
    if start_page < INIT_DATA_FLOOR || page_size == 0 {
        return (start_page, 0, 0);
    }
    let pages = (init_pages as u32).min(u32::MAX - start_page);
    let per_write = (ZERO_BUFFER_SIZE / page_size as usize).max(1) as u32;
    let syscalls = pages.div_ceil(per_write);
    (start_page, pages, syscalls)
}

/// How a database file is opened - `openFile`'s three booleans.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OpenPlan {
    pub read_only: bool,
    /// Forced Writes: adds SYNC to the OPEN MODE, not an fsync per write
    pub force_write: bool,
    /// `no_fs_cache`: adds O_DIRECT
    pub no_fs_cache: bool,
}

impl OpenPlan {
    /// The `fil_flags` this plan corresponds to.
    pub fn fil_flags(&self) -> u16 {
        let mut f = 0;
        if self.force_write {
            f |= flags::FORCE_WRITE;
        }
        if self.no_fs_cache {
            f |= flags::NO_FS_CACHE;
        }
        if self.read_only {
            f |= flags::READONLY;
        }
        f
    }

    /// The open(2) flag NAMES, in the order `openFile` adds them. Names
    /// rather than numbers, because the numeric values are
    /// platform-specific while the composition rule is the law.
    pub fn open_flag_names(&self) -> Vec<&'static str> {
        let mut v = vec!["O_BINARY"];
        v.push(if self.read_only { "O_RDONLY" } else { "O_RDWR" });
        if self.force_write {
            v.push("SYNC"); // O_DSYNC where the platform has it, else O_SYNC
        }
        if self.no_fs_cache {
            v.push("O_DIRECT");
        }
        v
    }
}

/// An open database file at the PIO level: pages in, pages out, nothing
/// above.
pub struct Pio {
    file: File,
    page_size: u32,
    plan: OpenPlan,
}

impl Pio {
    /// `PIO_open` without the locking: see the crate documentation for why
    /// fire-crab deliberately takes no `flock`.
    ///
    /// O_DIRECT is NOT applied even when the plan asks for it - honest
    /// refusal rather than a silent lie: O_DIRECT needs every buffer,
    /// offset and length aligned to the device block size, which this
    /// reader does not guarantee. [`OpenPlan::open_flag_names`] still
    /// reports what the engine WOULD pass.
    pub fn open(path: &str, page_size: u32, plan: OpenPlan) -> Result<Pio, String> {
        if page_size == 0 {
            return Err("page size 0".into());
        }
        let mut opts = OpenOptions::new();
        opts.read(true).write(!plan.read_only);
        if plan.force_write && !plan.read_only {
            // SYNC in the open mode, exactly as openFile composes it
            opts.custom_flags(libc_o_dsync());
        }
        let file = opts.open(path).map_err(|e| format!("{}: {}", path, e))?;
        Ok(Pio {
            file,
            page_size,
            plan,
        })
    }

    pub fn page_size(&self) -> u32 {
        self.page_size
    }

    pub fn plan(&self) -> OpenPlan {
        self.plan
    }

    pub fn len(&self) -> Result<u64, String> {
        self.file
            .metadata()
            .map(|m| m.len())
            .map_err(|e| e.to_string())
    }

    /// `PIO_get_number_of_pages` for this file.
    pub fn pages(&self) -> Result<u32, String> {
        Ok(number_of_pages(self.len()?, self.page_size))
    }

    /// `PIO_header` (unix.cpp:521): read the first `length` bytes without
    /// knowing the page size yet - the bootstrap read every attach starts
    /// with, since the page size is INSIDE the header page.
    pub fn header(path: &str, length: usize) -> Result<Vec<u8>, String> {
        let f = File::open(path).map_err(|e| format!("{}: {}", path, e))?;
        let mut buf = vec![0u8; length];
        read_exact_at(&f, &mut buf, 0)?;
        Ok(buf)
    }

    /// `PIO_read`: one page at `page * page_size`.
    ///
    /// A short read is `block_size_error` in the engine and an error here
    /// too - never a zero-filled page. Returning zeros for a page past
    /// the end of the file would look exactly like a legitimately empty
    /// page to every layer above.
    pub fn read_page(&self, page: u32) -> Result<Vec<u8>, String> {
        let off = page_offset_checked(page, self.page_size, 64)?;
        let end = off + self.page_size as u64;
        let len = self.len()?;
        if end > len {
            return Err(format!(
                "page {} ends at {} but the file is {} bytes ({} pages)",
                page,
                end,
                len,
                number_of_pages(len, self.page_size)
            ));
        }
        let mut buf = vec![0u8; self.page_size as usize];
        read_exact_at(&self.file, &mut buf, off)?;
        Ok(buf)
    }

    /// `PIO_write`: one page, at the same offset.
    pub fn write_page(&self, page: u32, data: &[u8]) -> Result<(), String> {
        if self.plan.read_only {
            return Err("the file is open read-only".into());
        }
        if data.len() != self.page_size as usize {
            return Err(format!(
                "a page is {} bytes, got {}",
                self.page_size,
                data.len()
            ));
        }
        let off = page_offset_checked(page, self.page_size, 64)?;
        write_all_at(&self.file, data, off)
    }

    /// `PIO_flush`: fsync.
    pub fn flush(&self) -> Result<(), String> {
        self.file.sync_all().map_err(|e| e.to_string())
    }

    /// `PIO_init_data`: zero the tail. Refuses below [`INIT_DATA_FLOOR`]
    /// the way the engine silently does, but says so instead of returning
    /// 0 - a caller that asked to zero page 3 has a bug.
    pub fn init_data(&self, start_page: u32, init_pages: u16) -> Result<u32, String> {
        if start_page < INIT_DATA_FLOOR {
            return Err(format!(
                "PIO_init_data never writes below page {} (asked for {})",
                INIT_DATA_FLOOR, start_page
            ));
        }
        let (_, pages, _) = init_data_plan(start_page, init_pages, self.page_size);
        let zero = vec![0u8; self.page_size as usize];
        for p in start_page..start_page + pages {
            self.write_page(p, &zero)?;
        }
        Ok(pages)
    }
}

/// The result of asking whether anyone holds the database file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LockState {
    /// no `flock` holder: an engine could open this file exclusively
    Free,
    /// somebody holds it - what the engine reports as `isc_already_opened`
    Busy,
}

/// Probe `lockDatabaseFile`'s lock without keeping it: try
/// `flock(LOCK_EX | LOCK_NB)` and release immediately.
///
/// This is how the engine decides that a file is already in use by
/// another instance (unix.cpp's `lockDatabaseFile`, whose busy branch
/// raises `isc_already_opened`). It answers a question fire-crab's own
/// readers never ask, and it explains their most surprising property:
/// they can read a database the server has open, because they take no
/// lock at all.
pub fn lock_probe(path: &str) -> Result<LockState, String> {
    use std::os::unix::io::AsRawFd;
    let f = File::open(path).map_err(|e| format!("{}: {}", path, e))?;
    // LOCK_EX | LOCK_NB = 2 | 4 on Linux; declared here rather than
    // pulling in a libc dependency (the crate has none)
    const LOCK_EX: i32 = 2;
    const LOCK_UN: i32 = 8;
    const LOCK_NB: i32 = 4;
    extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    let fd = f.as_raw_fd();
    let rc = unsafe { flock(fd, LOCK_EX | LOCK_NB) };
    if rc == 0 {
        unsafe { flock(fd, LOCK_UN) };
        Ok(LockState::Free)
    } else {
        Ok(LockState::Busy)
    }
}

/// O_DSYNC on Linux/aarch64 (`SYNC` in unix.cpp:105). Declared rather
/// than depending on libc: this crate, like the rest of fire-crab, has no
/// dependencies.
fn libc_o_dsync() -> i32 {
    // Linux: O_DSYNC = 0x1000 (aarch64 and x86_64 alike)
    0x1000
}

fn read_exact_at(f: &File, buf: &mut [u8], off: u64) -> Result<(), String> {
    let mut done = 0usize;
    for _ in 0..IO_RETRY {
        match f.read_at(&mut buf[done..], off + done as u64) {
            Ok(0) => break,
            Ok(n) => {
                done += n;
                if done == buf.len() {
                    return Ok(());
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.to_string()),
        }
    }
    Err(format!(
        "short read: {} of {} bytes at offset {}",
        done,
        buf.len(),
        off
    ))
}

fn write_all_at(f: &File, buf: &[u8], off: u64) -> Result<(), String> {
    let mut done = 0usize;
    for _ in 0..IO_RETRY {
        match f.write_at(&buf[done..], off + done as u64) {
            Ok(0) => break,
            Ok(n) => {
                done += n;
                if done == buf.len() {
                    return Ok(());
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.to_string()),
        }
    }
    Err(format!(
        "short write: {} of {} bytes at offset {}",
        done,
        buf.len(),
        off
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_offset_is_the_page_number_times_the_page_size() {
        // seek_file: absolute, no rebasing. Firebird 6 has no multi-file
        // databases, so there is no starting page to subtract - a
        // converter carrying one over from older engines would place
        // every page in the wrong spot.
        assert_eq!(page_offset(0, 8192), 0);
        assert_eq!(page_offset(1, 8192), 8192);
        assert_eq!(page_offset(200, 8192), 1_638_400);
        // and it does not overflow at the 32-bit boundary
        assert_eq!(page_offset(600_000, 8192), 4_915_200_000);
        assert_eq!(
            page_offset(u32::MAX, 32768),
            4_294_967_295u64 * 32768
        );
    }

    #[test]
    fn the_page_count_is_integer_division() {
        // PIO_get_number_of_pages: a trailing partial page is invisible,
        // not an error and not rounded up
        assert_eq!(number_of_pages(8192 * 10, 8192), 10);
        assert_eq!(number_of_pages(8192 * 10 + 1, 8192), 10);
        assert_eq!(number_of_pages(8191, 8192), 0);
        assert_eq!(number_of_pages(0, 8192), 0);
        // ... which is exactly why a healthy database's length is a whole
        // number of pages, and why checking that is worth doing
        assert!(length_is_whole_pages(8192 * 10, 8192));
        assert!(!length_is_whole_pages(8192 * 10 + 1, 8192));
        assert!(!length_is_whole_pages(8192, 0));
    }

    #[test]
    fn open_flags_compose_the_way_open_file_composes_them() {
        let ro = OpenPlan {
            read_only: true,
            ..Default::default()
        };
        assert_eq!(ro.open_flag_names(), vec!["O_BINARY", "O_RDONLY"]);
        assert_eq!(ro.fil_flags(), flags::READONLY);

        let rw = OpenPlan::default();
        assert_eq!(rw.open_flag_names(), vec!["O_BINARY", "O_RDWR"]);
        assert_eq!(rw.fil_flags(), 0);

        // Forced Writes is an OPEN MODE, not a per-write fsync
        let fw = OpenPlan {
            force_write: true,
            ..Default::default()
        };
        assert_eq!(fw.open_flag_names(), vec!["O_BINARY", "O_RDWR", "SYNC"]);
        assert_eq!(fw.fil_flags(), flags::FORCE_WRITE);

        let direct = OpenPlan {
            force_write: true,
            no_fs_cache: true,
            ..Default::default()
        };
        assert_eq!(
            direct.open_flag_names(),
            vec!["O_BINARY", "O_RDWR", "SYNC", "O_DIRECT"]
        );
        assert_eq!(
            direct.fil_flags(),
            flags::FORCE_WRITE | flags::NO_FS_CACHE
        );
    }

    #[test]
    fn extension_is_planned_from_the_current_end() {
        // PIO_extend: fallocate(offset = filePages * pageSize,
        //                       length = extendBy * pageSize)
        assert_eq!(extend_plan(100, 50, 8192), (819_200, 409_600));
        assert_eq!(extend_plan(0, 1, 4096), (0, 4096));
        // clamped by MIN(MAX_ULONG - filePages, extPages)
        let (off, len) = extend_plan(u32::MAX - 2, 10, 8192);
        assert_eq!(off, (u32::MAX - 2) as u64 * 8192);
        assert_eq!(len, 2 * 8192);
    }

    #[test]
    fn zero_fill_never_touches_the_first_eight_pages() {
        // unix.cpp:615 - `if (startPage < 8) return 0`. Those pages hold
        // the header, the first PIP and the first pointer page; zeroing
        // them is not "initializing the tail", it is destroying the
        // database.
        for p in 0..INIT_DATA_FLOOR {
            assert_eq!(init_data_plan(p, 100, 8192).1, 0, "page {}", p);
        }
        let (start, pages, calls) = init_data_plan(8, 100, 8192);
        assert_eq!((start, pages), (8, 100));
        // 256 KB of zeros / 8 KB pages = 32 pages per syscall
        assert_eq!(ZERO_BUFFER_SIZE / 8192, 32);
        assert_eq!(calls, 100u32.div_ceil(32));
        // a bigger page size means fewer pages per write
        assert_eq!(init_data_plan(8, 100, 32768).2, 100u32.div_ceil(8));
    }

    #[test]
    fn a_page_past_the_end_is_an_error_not_zeros() {
        // the failure this prevents: a zero-filled buffer for a page that
        // does not exist is indistinguishable, one layer up, from a page
        // that legitimately holds zeros
        let dir = std::env::temp_dir().join("fc-pio-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("short.fdb");
        std::fs::write(&path, vec![7u8; 8192 * 3]).unwrap();
        let p = path.to_str().unwrap();
        let pio = Pio::open(p, 8192, OpenPlan { read_only: true, ..Default::default() }).unwrap();
        assert_eq!(pio.pages().unwrap(), 3);
        assert_eq!(pio.read_page(2).unwrap()[0], 7);
        let err = pio.read_page(3).unwrap_err();
        assert!(err.contains("but the file is"), "{}", err);
        // a read-only file refuses writes rather than failing later
        assert!(pio.write_page(0, &[0u8; 8192]).unwrap_err().contains("read-only"));
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn the_header_is_read_before_the_page_size_is_known() {
        // PIO_header: the bootstrap read. The page size lives at offset
        // 16 of the header page (ods.h), so a 20-byte read is enough to
        // learn how big every later read must be - which is the only
        // reason this function exists separately from PIO_read.
        let dir = std::env::temp_dir().join("fc-pio-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("hdr.fdb");
        let mut page = vec![0u8; 8192];
        page[0] = 1; // pag_type = header
        page[16..18].copy_from_slice(&8192u16.to_le_bytes());
        std::fs::write(&path, &page).unwrap();
        let p = path.to_str().unwrap();
        let head = Pio::header(p, 20).unwrap();
        assert_eq!(head[0], 1);
        assert_eq!(u16::from_le_bytes([head[16], head[17]]), 8192);
        // asking for more than the file holds is a short read, not a
        // silently padded buffer
        assert!(Pio::header(p, 16384).is_err());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_written_page_reads_back_and_the_tail_can_be_zeroed() {
        let dir = std::env::temp_dir().join("fc-pio-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rw.fdb");
        std::fs::write(&path, vec![0xAAu8; 8192 * 12]).unwrap();
        let p = path.to_str().unwrap();
        let pio = Pio::open(p, 8192, OpenPlan::default()).unwrap();
        let mut page = vec![0u8; 8192];
        page[0] = 5;
        page[8191] = 9;
        pio.write_page(10, &page).unwrap();
        let back = pio.read_page(10).unwrap();
        assert_eq!(back[0], 5);
        assert_eq!(back[8191], 9);
        // the neighbours are untouched: the offset arithmetic did not
        // spill into them
        assert_eq!(pio.read_page(9).unwrap()[0], 0xAA);
        assert_eq!(pio.read_page(11).unwrap()[0], 0xAA);
        // zero the tail from page 8 on
        assert_eq!(pio.init_data(8, 4).unwrap(), 4);
        assert!(pio.read_page(8).unwrap().iter().all(|b| *b == 0));
        assert!(pio.read_page(11).unwrap().iter().all(|b| *b == 0));
        // page 7 survives - below the floor
        assert_eq!(pio.read_page(7).unwrap()[0], 0xAA);
        assert!(pio.init_data(7, 1).unwrap_err().contains("below page 8"));
        pio.flush().unwrap();
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_header_flag_becomes_an_open_mode() {
        // the whole point of this layer's link to the ODS: gfix -w sync
        // sets hdr_force_write, and the next attach turns that bit into
        // SYNC in the open flags
        let p = plan_for_header(hdr::FORCE_WRITE | hdr::SQL_DIALECT_3, false);
        assert!(p.force_write && !p.read_only);
        assert_eq!(p.open_flag_names(), vec!["O_BINARY", "O_RDWR", "SYNC"]);
        let ro = plan_for_header(hdr::READ_ONLY, false);
        assert_eq!(ro.open_flag_names(), vec!["O_BINARY", "O_RDONLY"]);
        // gstat -h prints these names for the same bits
        assert_eq!(
            header_attribute_names(hdr::FORCE_WRITE | hdr::NO_RESERVE),
            vec!["force write", "no reserve"]
        );
        assert!(header_attribute_names(hdr::SQL_DIALECT_3).is_empty());
        assert_eq!(hdr::FLAGS_OFFSET, 22);
    }

    #[test]
    fn a_free_file_probes_free() {
        let dir = std::env::temp_dir().join("fc-pio-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("lock.fdb");
        std::fs::write(&path, vec![0u8; 8192]).unwrap();
        let p = path.to_str().unwrap();
        assert_eq!(lock_probe(p).unwrap(), LockState::Free);
        // and probing does not KEEP the lock: a second probe must agree
        assert_eq!(lock_probe(p).unwrap(), LockState::Free);
        std::fs::remove_file(&path).ok();
    }
}
