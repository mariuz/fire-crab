//! The database header page (`struct header_page`, ods.h:639), the
//! root of everything: page size, ODS version, the four transaction
//! markers (64-bit since the ODS 12+ widening), the database GUID.
//! Offsets are pinned by the static_asserts at ods.h:661-685 and
//! mirrored by the tests below.

use crate::pages::{PageHeader, PageType};
use crate::{u16_at, u32_at, u64_at};

/// ODS major version numbers carry a "Firebird" flag bit.
/// (ODS_FIREBIRD_FLAG in ods.h; ODS 14.0 reads 0x800e raw.)
pub const ODS_FIREBIRD_FLAG: u16 = 0x8000;

#[derive(Clone, Debug)]
pub struct HeaderPage {
    pub pag: PageHeader,
    pub page_size: u16,
    /// Raw ODS version word including the Firebird flag (e.g. 0x800e)
    pub ods_version_raw: u16,
    pub ods_minor: u16,
    pub flags: u16,
    pub backup_mode: u8,
    pub shutdown_mode: u8,
    pub replica_mode: u8,
    /// Page number of the RDB$PAGES relation's first pointer page -
    /// the bootstrap anchor the catalog is found through
    pub pages_page: u32,
    pub page_buffers: u32,
    pub next_transaction: u64,
    pub oldest_transaction: u64,
    pub oldest_active: u64,
    pub oldest_snapshot: u64,
    pub next_attachment_id: u64,
    /// `hdr_db_impl` (offset 80): the cpu, os, compiler and compatibility
    /// bytes of the machine the database was CREATED on
    pub db_impl: [u8; 4],
    pub guid: [u8; 16],
    /// `hdr_creation_date` (offset 100): an ISC timestamp - MJD days and
    /// 1/10000-second units
    pub creation_date: (i32, u32),
    /// `hdr_shadow_count` (offset 108)
    pub shadow_count: i32,
    /// `hdr_crypt_plugin` (offset 116, 32 bytes)
    pub crypt_plugin: String,
}

/// One variable-header clumplet: `<type><length><data>` in `hdr_data`
/// (ods.h:703-719).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HeaderClumplet {
    pub tag: u8,
    pub data: Vec<u8>,
}

/// `HDR_*` clumplet codes (ods.h:707-719). The commented-out ones -
/// `HDR_file` (2) and `HDR_last_page` (3) - are the multi-file database's
/// remains: Firebird 6 no longer writes them.
pub mod hdr_clump {
    pub const END: u8 = 0;
    pub const ROOT_FILE_NAME: u8 = 1;
    pub const SWEEP_INTERVAL: u8 = 4;
    pub const CRYPT_CHECKSUM: u8 = 5;
    pub const DIFFERENCE_FILE: u8 = 6;
    pub const BACKUP_GUID: u8 = 7;
    pub const CRYPT_KEY: u8 = 8;
    pub const CRYPT_HASH: u8 = 9;
    pub const REPL_SEQ: u8 = 11;
    pub const MAX: u8 = 11;
}

/// `hdr_data` starts at offset 148 (ods.h:672 static_assert).
pub const HDR_DATA_OFFSET: usize = 148;

/// The machine-description tables `DbImplementation` prints from
/// (common/classes/DbImplementation.cpp:77-120). The INDEX is what the
/// header stores, so these lists are a byte-for-byte part of the format:
/// dropping an entry renames every later platform.
const HARDWARE: &[&str] = &[
    "Intel/i386",
    "AMD/Intel/x64",
    "UltraSparc",
    "PowerPC",
    "PowerPC64",
    "MIPSEL",
    "MIPS",
    "ARM",
    "IA64",
    "s390",
    "s390x",
    "SH",
    "SHEB",
    "HPPA",
    "Alpha",
    "ARM64",
    "PowerPC64el",
    "M68k",
    "RiscV64",
    "MIPS64EL",
    "LOONGARCH",
];

const OPERATING_SYSTEM: &[&str] = &[
    "Windows", "Linux", "Darwin", "Solaris", "HPUX", "AIX", "MVS", "FreeBSD", "NetBSD",
];

const COMPILER: &[&str] = &["MSVC", "gcc", "xlC", "aCC", "SunStudio", "icc"];

/// The three short month names `gstat` prints (`FB_SHORT_MONTHS`).
const SHORT_MONTHS: &[&str] = &[
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

impl HeaderPage {
    /// ODS major version with the Firebird flag stripped (14 for
    /// Firebird 6).
    pub fn ods_major(&self) -> u16 {
        self.ods_version_raw & !ODS_FIREBIRD_FLAG
    }

    pub fn is_firebird(&self) -> bool {
        self.ods_version_raw & ODS_FIREBIRD_FLAG != 0
    }

    /// Decode page 0 of a database file. Returns None if the buffer
    /// is too small or not a header page.
    pub fn decode(page: &[u8]) -> Option<HeaderPage> {
        if page.len() < 100 {
            return None;
        }
        let pag = PageHeader::decode(page)?;
        if pag.page_type != PageType::Header as u8 {
            return None;
        }
        if page.len() < 148 {
            return None;
        }
        let mut guid = [0u8; 16];
        guid.copy_from_slice(&page[84..100]); // hdr_guid, offset 84
        let mut db_impl = [0u8; 4];
        db_impl.copy_from_slice(&page[80..84]); // hdr_db_impl, offset 80
        let plugin_bytes = &page[116..148]; // hdr_crypt_plugin, offset 116
        let plugin_end = plugin_bytes
            .iter()
            .position(|b| *b == 0)
            .unwrap_or(plugin_bytes.len());

        Some(HeaderPage {
            pag,
            page_size: u16_at(page, 16),          // hdr_page_size
            ods_version_raw: u16_at(page, 18),    // hdr_ods_version
            ods_minor: u16_at(page, 20),          // hdr_ods_minor
            flags: u16_at(page, 22),              // hdr_flags
            backup_mode: page[24],                // hdr_backup_mode
            shutdown_mode: page[25],              // hdr_shutdown_mode
            replica_mode: page[26],               // hdr_replica_mode
            pages_page: u32_at(page, 28),         // hdr_PAGES
            page_buffers: u32_at(page, 32),       // hdr_page_buffers
            next_transaction: u64_at(page, 40),   // hdr_next_transaction
            oldest_transaction: u64_at(page, 48), // hdr_oldest_transaction
            oldest_active: u64_at(page, 56),      // hdr_oldest_active
            oldest_snapshot: u64_at(page, 64),    // hdr_oldest_snapshot
            next_attachment_id: u64_at(page, 72), // hdr_attachment_id
            db_impl,
            guid,
            creation_date: (
                u32_at(page, 100) as i32, // hdr_creation_date[0], MJD days
                u32_at(page, 104),        // hdr_creation_date[1], 1/10000 s
            ),
            shadow_count: u32_at(page, 108) as i32, // hdr_shadow_count
            crypt_plugin: String::from_utf8_lossy(&plugin_bytes[..plugin_end]).into_owned(),
        })
    }


    /// `DbImplementation::cpu/endianess/os/cc` as one line, the way
    /// `gstat -h` prints it: `HW=ARM64 little-endian OS=Linux CC=gcc`.
    /// An index the tables do not cover prints as `unknown`, which is what
    /// `GET_ARRAY_ELEMENT` does for an out-of-range value.
    pub fn implementation_string(&self) -> String {
        let name = |t: &[&str], i: u8| -> String {
            t.get(i as usize).map(|s| s.to_string()).unwrap_or_else(|| "unknown".to_string())
        };
        // EndianMask = 1, EndianBig = 1 (DbImplementation.cpp:75)
        let endian = if self.db_impl[3] & 1 != 0 { "big" } else { "little" };
        format!(
            "HW={} {}-endian OS={} CC={}",
            name(HARDWARE, self.db_impl[0]),
            endian,
            name(OPERATING_SYSTEM, self.db_impl[1]),
            name(COMPILER, self.db_impl[2])
        )
    }

    /// The SQL dialect line's value. A dialect-1 database has NO dialect
    /// information in its header (ppg.cpp:81-87), so the absence of the
    /// bit means 1 - it does not mean "unknown".
    pub fn dialect(&self) -> u8 {
        if self.flags & hdr_flags::SQL_DIALECT_3 != 0 {
            3
        } else {
            1
        }
    }

    /// `Creation date` as `gstat` prints it: `Jul 28, 2026 14:42:59`.
    pub fn creation_date_string(&self) -> String {
        let (days, frac) = self.creation_date;
        // civil-from-days, Firebird epoch (day 0 = 1858-11-17)
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
            "{} {}, {} {}:{:02}:{:02}",
            SHORT_MONTHS
                .get((m - 1) as usize)
                .copied()
                .unwrap_or("???"),
            d,
            y,
            secs / 3600,
            (secs / 60) % 60,
            secs % 60
        )
    }

    /// The `Attributes` line's value - `ppg.cpp:102-217`, in the engine's
    /// exact order, comma-separated. Empty when the database has none, in
    /// which case gstat prints the label with nothing after it.
    pub fn attributes_string(&self) -> String {
        let f = self.flags;
        let mut v: Vec<String> = Vec::new();
        if f & hdr_flags::FORCE_WRITE != 0 {
            v.push("force write".into());
        }
        if f & hdr_flags::NO_RESERVE != 0 {
            v.push("no reserve".into());
        }
        if f & hdr_flags::ACTIVE_SHADOW != 0 {
            v.push("active shadow".into());
        }
        if f & hdr_flags::ENCRYPTED != 0 {
            v.push("encrypted".into());
        }
        if f & hdr_flags::CRYPT_PROCESS != 0 {
            v.push("crypt process".into());
        }
        if f & (hdr_flags::ENCRYPTED | hdr_flags::CRYPT_PROCESS) != 0 {
            v.push(format!("plugin {}", self.crypt_plugin));
        }
        if f & hdr_flags::READ_ONLY != 0 {
            v.push("read only".into());
        }
        match self.shutdown_mode {
            0 => {}
            1 => v.push("multi-user maintenance".into()),
            2 => v.push("single-user maintenance".into()),
            3 => v.push("full shutdown".into()),
            m => v.push(format!("wrong shutdown state {}", m)),
        }
        match self.backup_mode {
            0 => {}
            1 => v.push("backup lock".into()),
            2 => v.push("backup merge".into()),
            m => v.push(format!("wrong backup state {}", m)),
        }
        match self.replica_mode {
            0 => {}
            1 => v.push("read-only replica".into()),
            2 => v.push("read-write replica".into()),
            m => v.push(format!("wrong replica state {}", m)),
        }
        v.join(", ")
    }

    /// Render the GUID the way the engine prints it:
    /// {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} with the first three
    /// groups little-endian (Windows GUID convention, as used by
    /// Firebird's Guid class).
    pub fn guid_string(&self) -> String {
        let g = &self.guid;
        format!(
            "{{{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}}}",
            u32::from_le_bytes([g[0], g[1], g[2], g[3]]),
            u16::from_le_bytes([g[4], g[5]]),
            u16::from_le_bytes([g[6], g[7]]),
            g[8],
            g[9],
            g[10],
            g[11],
            g[12],
            g[13],
            g[14],
            g[15]
        )
    }
}


/// Header-page flag bits (ods.h:722-728).
pub mod hdr_flags {
    pub const ACTIVE_SHADOW: u16 = 0x1;
    pub const FORCE_WRITE: u16 = 0x2;
    pub const CRYPT_PROCESS: u16 = 0x4;
    pub const NO_RESERVE: u16 = 0x8;
    pub const SQL_DIALECT_3: u16 = 0x10;
    pub const READ_ONLY: u16 = 0x20;
    pub const ENCRYPTED: u16 = 0x40;
}

/// Walk the variable header data - the clumplets after the fixed part
/// (`hdr_data`, offset 148), each `<type><length><data>`, terminated by
/// `HDR_end` (0) or by the end of the page (ppg.cpp:222-226).
pub fn variable_header(page: &[u8]) -> Vec<HeaderClumplet> {
    let mut out = Vec::new();
    let mut at = HDR_DATA_OFFSET;
    while at + 1 < page.len() {
        let tag = page[at];
        if tag == hdr_clump::END {
            break;
        }
        let len = page[at + 1] as usize;
        let end = at + 2 + len;
        if end > page.len() {
            break; // a length past the page: stop rather than invent data
        }
        out.push(HeaderClumplet {
            tag,
            data: page[at + 2..end].to_vec(),
        });
        at = end;
    }
    out
}

/// `hdr_end` (offset 36, ods.h:683): WHERE THE `HDR_end` BYTE IS.
///
/// The reader above does not need it - it walks to the terminator - but
/// a WRITER does, and getting this wrong is silent corruption rather
/// than a wrong answer: `HeaderClumplet::add` (pag.cpp:150) appends AT
/// `hdr_end` and asserts the byte there is the terminator. A clumplet
/// added without moving `hdr_end` would be overwritten by the engine's
/// very next header write, which would append on top of it.
pub const HDR_END_OFFSET: usize = 36;

/// Store a clumplet in the variable header, replacing one of the same
/// type - `storeClump` (pag.cpp:213-266), which is what
/// `isc_dpb_sweep_interval` reaches.
///
/// The engine's three cases, in its order:
///
/// * present and THE SAME LENGTH - overwritten in place, nothing moves;
/// * present at a different length - REMOVED (the tail memmoved down
///   over it, terminator included) and then appended as a new entry, so
///   a resized clumplet migrates to the end of the list;
/// * absent - appended at `hdr_end`, with a fresh terminator after it.
///
/// `find` keeps the LAST match rather than the first (pag.cpp:123-137),
/// which is only observable on a page that already holds two of a type;
/// this keeps that, because a writer that picked the first one would
/// leave the engine reading the other.
///
/// Answers whether anything changed. Refuses - `isc_hdr_overflow`, the
/// error the engine raises - rather than write past the page.
pub fn store_clumplet(
    page: &mut [u8],
    page_size: usize,
    tag: u8,
    data: &[u8],
) -> Result<bool, String> {
    if tag == hdr_clump::END || data.len() > u8::MAX as usize {
        return Err("not a storable clumplet".to_string());
    }
    let page_size = page_size.min(page.len());
    if page_size <= HDR_DATA_OFFSET {
        return Err("header page too small".to_string());
    }
    // walk to the terminator, keeping the last entry of this type
    let mut at = HDR_DATA_OFFSET;
    let mut found: Option<usize> = None;
    while at + 1 < page_size {
        if page[at] == hdr_clump::END {
            break;
        }
        let len = page[at + 1] as usize;
        if at + 2 + len > page_size {
            return Err("a clumplet runs past the page".to_string());
        }
        if page[at] == tag {
            found = Some(at);
        }
        at += 2 + len;
    }
    if at >= page_size || page[at] != hdr_clump::END {
        return Err("the variable header has no terminator".to_string());
    }
    // THE FIELD THE READER NEVER NEEDED. `hdr_end` must name the byte
    // the walk stopped on; if the file disagrees with itself, this
    // refuses rather than picking one and corrupting the other.
    let hdr_end = u16_at(page, HDR_END_OFFSET) as usize;
    if hdr_end != at {
        return Err(format!(
            "hdr_end says {} but the terminator is at {}",
            hdr_end, at
        ));
    }
    let mut end = at;

    if let Some(entry) = found {
        let org_len = page[entry + 1] as usize;
        if org_len == data.len() {
            if page[entry + 2..entry + 2 + org_len] == *data {
                return Ok(false); // already what was asked for
            }
            page[entry + 2..entry + 2 + org_len].copy_from_slice(data);
            return Ok(true);
        }
        // remove: the tail slides down over it, terminator included
        let tail = entry + 2 + org_len;
        page.copy_within(tail..end + 1, entry);
        end -= 2 + org_len;
        let new_end = end as u16;
        page[HDR_END_OFFSET..HDR_END_OFFSET + 2].copy_from_slice(&new_end.to_le_bytes());
    }

    // append at the terminator - `checkSpace` wants room for the entry
    // AND the terminator that follows it (pag.cpp:141)
    if page_size - end <= 2 + data.len() {
        return Err("isc_hdr_overflow: no room in the header page".to_string());
    }
    page[end] = tag;
    page[end + 1] = data.len() as u8;
    page[end + 2..end + 2 + data.len()].copy_from_slice(data);
    page[end + 2 + data.len()] = hdr_clump::END;
    let new_end = (end + 2 + data.len()) as u16;
    page[HDR_END_OFFSET..HDR_END_OFFSET + 2].copy_from_slice(&new_end.to_le_bytes());
    Ok(true)
}

/// `gstat -h`'s report for a header page, byte for byte - the conversion
/// of `PPG_print_header` (`src/utilities/gstat/ppg.cpp:56-287`).
///
/// This is the text a Services `db_stats` action streams back, which makes
/// it checkable in the strongest possible way: run the engine's own
/// `gstat -h` against a file and this function against the same file, and
/// the two must be identical.
///
/// `nocreation` suppresses the GUID and creation-date lines, exactly as
/// `isc_spb_sts_nocreation` does.
pub fn header_report(page: &[u8], nocreation: bool) -> Option<String> {
    let h = HeaderPage::decode(page)?;
    let mut s = String::new();
    s.push_str("Database header page information:\n");
    s.push_str(&format!("\tFlags\t\t\t{}\n", h.pag.flags));
    s.push_str(&format!("\tGeneration\t\t{}\n", h.pag.generation));
    s.push_str(&format!("\tSystem Change Number\t{}\n", h.pag.scn));
    s.push_str(&format!("\tPage size\t\t{}\n", h.page_size));
    s.push_str(&format!(
        "\tODS version\t\t{}.{}\n",
        h.ods_major(),
        h.ods_minor
    ));
    s.push_str(&format!(
        "\tOldest transaction\t{}\n",
        h.oldest_transaction
    ));
    s.push_str(&format!("\tOldest active\t\t{}\n", h.oldest_active));
    s.push_str(&format!("\tOldest snapshot\t\t{}\n", h.oldest_snapshot));
    s.push_str(&format!("\tNext transaction\t{}\n", h.next_transaction));
    s.push_str(&format!(
        "\tNext attachment ID\t{}\n",
        h.next_attachment_id
    ));
    s.push_str(&format!(
        "\tImplementation\t\t{}\n",
        h.implementation_string()
    ));
    s.push_str(&format!("\tShadow count\t\t{}\n", h.shadow_count));
    s.push_str(&format!("\tPage buffers\t\t{}\n", h.page_buffers));
    s.push_str(&format!("\tDatabase dialect\t{}\n", h.dialect()));
    if !nocreation {
        s.push_str(&format!("\tDatabase GUID:\t{}\n", h.guid_string()));
        s.push_str(&format!(
            "\tCreation date\t\t{}\n",
            h.creation_date_string()
        ));
    }
    // The label is printed unconditionally; the VALUE and its newline only
    // when there is something to say (ppg.cpp:102-217) - so a database with
    // no attributes leaves a dangling label with no line break, and the
    // next line is the blank one before "Variable header data".
    s.push_str("\tAttributes\t\t");
    let attrs = h.attributes_string();
    if !attrs.is_empty() {
        s.push_str(&attrs);
        s.push('\n');
    }
    s.push_str("\n    Variable header data:\n");
    for c in variable_header(page) {
        let text = || String::from_utf8_lossy(&c.data).into_owned();
        match c.tag {
            hdr_clump::ROOT_FILE_NAME => {
                s.push_str(&format!("\tRoot file name:\t\t{}\n", text()))
            }
            hdr_clump::SWEEP_INTERVAL => {
                let n = if c.data.len() >= 4 {
                    i32::from_le_bytes([c.data[0], c.data[1], c.data[2], c.data[3]])
                } else {
                    0
                };
                s.push_str(&format!("\tSweep interval:\t\t{}\n", n));
            }
            hdr_clump::DIFFERENCE_FILE => {
                s.push_str(&format!("\tBackup difference file:\t{}\n", text()))
            }
            hdr_clump::BACKUP_GUID => {
                let mut g = [0u8; 16];
                if c.data.len() >= 16 {
                    g.copy_from_slice(&c.data[..16]);
                }
                let fake = HeaderPage {
                    guid: g,
                    ..h.clone()
                };
                s.push_str(&format!(
                    "\tDatabase backup GUID:\t{}\n",
                    fake.guid_string()
                ));
            }
            hdr_clump::CRYPT_KEY => {
                s.push_str(&format!("\tEncryption key name:\t{}\n", text()))
            }
            hdr_clump::CRYPT_HASH => s.push_str(&format!("\tKey hash:\t{}\n", text())),
            hdr_clump::CRYPT_CHECKSUM => {
                s.push_str(&format!("\tCrypt checksum:\t{}\n", text()))
            }
            hdr_clump::REPL_SEQ => {
                let mut n = 0u64;
                for (i, b) in c.data.iter().take(8).enumerate() {
                    n |= (*b as u64) << (8 * i);
                }
                s.push_str(&format!("\tReplication sequence:\t{}\n", n));
            }
            t if t > hdr_clump::MAX => s.push_str(&format!(
                "\tUnrecognized option {}, length {}\n",
                t,
                c.data.len()
            )),
            t => s.push_str(&format!(
                "\tEncoded option {}, length {}\n",
                t,
                c.data.len()
            )),
        }
    }
    s.push_str("\t*END*\n");
    Some(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_report_is_gstat_s_text() {
        // A synthetic header with the fields gstat prints. The live
        // differential (qa/svc-stats.sh) compares this generator's output
        // with the engine's own gstat on real databases; this pins the
        // SHAPE offline, including the two branches that are easy to get
        // backwards.
        let mut page = vec![0u8; 8192];
        page[0] = 1; // pag_type = header
        page[1] = 0; // pag_flags - what the "Flags" LINE prints
        page[4..8].copy_from_slice(&30u32.to_le_bytes()); // pag_generation
        page[8..12].copy_from_slice(&0u32.to_le_bytes()); // pag_scn
        page[16..18].copy_from_slice(&8192u16.to_le_bytes());
        page[18..20].copy_from_slice(&0x800eu16.to_le_bytes()); // ODS 14
        page[22..24].copy_from_slice(&0x12u16.to_le_bytes()); // force write + dialect 3
        page[80] = 15; // ARM64
        page[81] = 1; // Linux
        page[82] = 1; // gcc
        page[83] = 0; // little-endian
        // one variable-header clumplet: a sweep interval
        page[148] = hdr_clump::SWEEP_INTERVAL;
        page[149] = 4;
        page[150..154].copy_from_slice(&20000i32.to_le_bytes());

        let t = header_report(&page, false).expect("a header page");
        assert!(t.starts_with("Database header page information:\n"));
        // the Flags LINE is the PAGE's flags (0), while hdr_flags (0x12)
        // shows up as Attributes - a converter that prints hdr_flags here
        // reports 18 where gstat reports 0
        assert!(t.contains("\tFlags\t\t\t0\n"), "{}", t);
        assert!(t.contains("\tAttributes\t\tforce write\n"), "{}", t);
        assert!(t.contains("\tGeneration\t\t30\n"));
        assert!(t.contains("\tODS version\t\t14.0\n"));
        assert!(t.contains("\tImplementation\t\tHW=ARM64 little-endian OS=Linux CC=gcc\n"));
        assert!(t.contains("\tDatabase dialect\t3\n"));
        assert!(t.contains("\tSweep interval:\t\t20000\n"));
        assert!(t.ends_with("\t*END*\n"));

        // no attributes: the LABEL is still printed, with NO newline after
        // it, so the blank line before "Variable header data" follows
        // immediately (ppg.cpp:102-217)
        page[22..24].copy_from_slice(&0u16.to_le_bytes());
        let t = header_report(&page, false).unwrap();
        assert!(t.contains("\tAttributes\t\t\n    Variable header data:\n"), "{}", t);
        // dialect 1 is the ABSENCE of the dialect bit, not an unknown
        assert!(t.contains("\tDatabase dialect\t1\n"));

        // nocreation drops the GUID and creation-date lines
        let t = header_report(&page, true).unwrap();
        assert!(!t.contains("Database GUID"));
        assert!(!t.contains("Creation date"));
    }

    /// Build a synthetic header page with a distinct value at every
    /// field offset pinned by ods.h:661-685, and check each lands in
    /// the right struct member - the Rust mirror of the C++
    /// static_asserts plus a semantic decode check.
    #[test]
    fn header_layout_matches_ods_h() {
        let mut page = vec![0u8; 8192];
        page[0] = 1; // pag_header
        page[16..18].copy_from_slice(&8192u16.to_le_bytes()); // hdr_page_size @16
        page[18..20].copy_from_slice(&0x800eu16.to_le_bytes()); // hdr_ods_version @18
        page[20..22].copy_from_slice(&0u16.to_le_bytes()); // hdr_ods_minor @20
        page[22..24].copy_from_slice(&0x1234u16.to_le_bytes()); // hdr_flags @22
        page[24] = 1; // hdr_backup_mode @24
        page[25] = 2; // hdr_shutdown_mode @25
        page[26] = 3; // hdr_replica_mode @26
        page[28..32].copy_from_slice(&3u32.to_le_bytes()); // hdr_PAGES @28
        page[32..36].copy_from_slice(&2048u32.to_le_bytes()); // hdr_page_buffers @32
        page[40..48].copy_from_slice(&29u64.to_le_bytes()); // hdr_next_transaction @40
        page[48..56].copy_from_slice(&28u64.to_le_bytes()); // hdr_oldest_transaction @48
        page[56..64].copy_from_slice(&29u64.to_le_bytes()); // hdr_oldest_active @56
        page[64..72].copy_from_slice(&29u64.to_le_bytes()); // hdr_oldest_snapshot @64
        page[72..80].copy_from_slice(&7u64.to_le_bytes()); // hdr_attachment_id @72
        page[84..100].copy_from_slice(&[0xAA; 16]); // hdr_guid @84

        let h = HeaderPage::decode(&page).unwrap();
        assert_eq!(h.page_size, 8192);
        assert_eq!(h.ods_major(), 14);
        assert!(h.is_firebird());
        assert_eq!(h.flags, 0x1234);
        assert_eq!(h.backup_mode, 1);
        assert_eq!(h.shutdown_mode, 2);
        assert_eq!(h.replica_mode, 3);
        assert_eq!(h.pages_page, 3);
        assert_eq!(h.page_buffers, 2048);
        assert_eq!(h.next_transaction, 29);
        assert_eq!(h.oldest_transaction, 28);
        assert_eq!(h.oldest_active, 29);
        assert_eq!(h.oldest_snapshot, 29);
        assert_eq!(h.next_attachment_id, 7);
        assert_eq!(h.guid, [0xAA; 16]);
    }

    #[test]
    fn rejects_non_header_pages() {
        let mut page = vec![0u8; 8192];
        page[0] = 5; // a data page
        assert!(HeaderPage::decode(&page).is_none());
    }

    /// A page whose variable header holds `clumps`, with `hdr_end`
    /// pointing at the terminator the way the engine keeps it.
    fn with_clumplets(clumps: &[(u8, &[u8])]) -> Vec<u8> {
        let mut page = vec![0u8; 8192];
        page[0] = 1;
        page[16..18].copy_from_slice(&8192u16.to_le_bytes());
        page[18..20].copy_from_slice(&0x800eu16.to_le_bytes());
        let mut at = HDR_DATA_OFFSET;
        for (tag, data) in clumps {
            page[at] = *tag;
            page[at + 1] = data.len() as u8;
            page[at + 2..at + 2 + data.len()].copy_from_slice(data);
            at += 2 + data.len();
        }
        page[at] = hdr_clump::END;
        page[HDR_END_OFFSET..HDR_END_OFFSET + 2].copy_from_slice(&(at as u16).to_le_bytes());
        page
    }

    fn tags(page: &[u8]) -> Vec<(u8, Vec<u8>)> {
        variable_header(page)
            .into_iter()
            .map(|c| (c.tag, c.data))
            .collect()
    }

    /// `hdr_end` must name the terminator after every write, or the
    /// engine's next header write appends on top of what was stored.
    fn end_is_consistent(page: &[u8]) {
        let e = u16_at(page, HDR_END_OFFSET) as usize;
        assert_eq!(page[e], hdr_clump::END, "hdr_end must name the terminator");
        let walked = {
            let mut at = HDR_DATA_OFFSET;
            while page[at] != hdr_clump::END {
                at += 2 + page[at + 1] as usize;
            }
            at
        };
        assert_eq!(e, walked, "hdr_end disagrees with the walk");
    }

    #[test]
    fn a_clumplet_is_added_when_it_is_not_there() {
        // a fresh database has NO sweep-interval clumplet - measured:
        // `gstat -h` prints no such line until `gfix -housekeeping` runs
        let mut page = with_clumplets(&[]);
        assert!(store_clumplet(&mut page, 8192, hdr_clump::SWEEP_INTERVAL, &12345i32.to_le_bytes()).unwrap());
        assert_eq!(
            tags(&page),
            vec![(hdr_clump::SWEEP_INTERVAL, 12345i32.to_le_bytes().to_vec())]
        );
        end_is_consistent(&page);
        assert!(header_report(&page, true).unwrap().contains("\tSweep interval:\t\t12345\n"));
    }

    #[test]
    fn the_same_length_is_overwritten_in_place() {
        let mut page = with_clumplets(&[
            (hdr_clump::SWEEP_INTERVAL, &20000i32.to_le_bytes()),
            (hdr_clump::ROOT_FILE_NAME, b"/db/x.fdb"),
        ]);
        let before = u16_at(&page, HDR_END_OFFSET);
        assert!(store_clumplet(&mut page, 8192, hdr_clump::SWEEP_INTERVAL, &7i32.to_le_bytes()).unwrap());
        // nothing moved: the entry is still first and hdr_end is unchanged
        assert_eq!(
            tags(&page),
            vec![
                (hdr_clump::SWEEP_INTERVAL, 7i32.to_le_bytes().to_vec()),
                (hdr_clump::ROOT_FILE_NAME, b"/db/x.fdb".to_vec()),
            ]
        );
        assert_eq!(u16_at(&page, HDR_END_OFFSET), before);
        // ...and writing what is already there is not a change at all
        assert!(!store_clumplet(&mut page, 8192, hdr_clump::SWEEP_INTERVAL, &7i32.to_le_bytes()).unwrap());
    }

    #[test]
    fn a_resized_clumplet_moves_to_the_end() {
        // storeClump removes and re-adds when the length differs
        // (pag.cpp:245-266), so the entry migrates past the ones after it
        let mut page = with_clumplets(&[
            (hdr_clump::ROOT_FILE_NAME, b"/db/x.fdb"),
            (hdr_clump::SWEEP_INTERVAL, &20000i32.to_le_bytes()),
            (hdr_clump::BACKUP_GUID, &[9u8; 16]),
        ]);
        assert!(store_clumplet(&mut page, 8192, hdr_clump::ROOT_FILE_NAME, b"/db/longer-name.fdb").unwrap());
        assert_eq!(
            tags(&page),
            vec![
                (hdr_clump::SWEEP_INTERVAL, 20000i32.to_le_bytes().to_vec()),
                (hdr_clump::BACKUP_GUID, vec![9u8; 16]),
                (hdr_clump::ROOT_FILE_NAME, b"/db/longer-name.fdb".to_vec()),
            ]
        );
        end_is_consistent(&page);
    }

    #[test]
    fn a_header_that_disagrees_with_itself_is_refused() {
        let mut page = with_clumplets(&[(hdr_clump::SWEEP_INTERVAL, &20000i32.to_le_bytes())]);
        page[HDR_END_OFFSET..HDR_END_OFFSET + 2].copy_from_slice(&999u16.to_le_bytes());
        assert!(store_clumplet(&mut page, 8192, hdr_clump::SWEEP_INTERVAL, &1i32.to_le_bytes()).is_err());
    }

    #[test]
    fn it_refuses_rather_than_write_past_the_page() {
        // isc_hdr_overflow: the engine's own answer when the variable
        // header cannot take another entry
        let mut page = with_clumplets(&[]);
        let mut size = HDR_DATA_OFFSET + 3; // room for a 0-length entry and no more
        assert!(store_clumplet(&mut page, size, hdr_clump::SWEEP_INTERVAL, &[1, 2, 3, 4]).is_err());
        size = HDR_DATA_OFFSET + 7;
        assert!(store_clumplet(&mut page, size, hdr_clump::SWEEP_INTERVAL, &[1, 2, 3, 4]).unwrap());
    }
}
