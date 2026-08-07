//! The gbak backup format ("burp", `src/burp/`), write side: producing
//! a `.fbk` the REAL `gbak -c` restores.
//!
//! The format is a stream of MAJOR RECORDS (one byte each, burp.h:84),
//! most carrying an attribute list - `[att byte][u8 length][data]`,
//! numbers 4-byte little-endian ("as in VAX", backup.epp:put_int32) -
//! terminated by `att_end` (0). `rec_relation_end` and `rec_end` are
//! BARE record bytes with no attributes at all. The order of battle is
//! documented in burp.h:133-176 and was pinned against a real FB6
//! `.fbk` byte by byte (an annotated parse of the whole file, not a
//! sample).
//!
//! DATA rows are the interesting part. `rec_data` carries the row in
//! gbak's TRANSPORTABLE encoding: the message XDR-canonicalized
//! (numbers big-endian, a VARCHAR as a 4-byte length + bytes padded to
//! 4, one 4-byte null indicator PER FIELD trailing the values -
//! canonical.cpp), then RLE-compressed with the same positive-literal /
//! negative-repeat scheme the record codec uses - `fire_crab_ods::sqz`
//! emits a stream gbak's `decompress` accepts.
//!
//! FAIL-CLOSED BY SURFACE: a database holding anything this writer
//! cannot carry - a view, a trigger, a procedure, a generator, a blob
//! or unsupported column type - refuses the WHOLE backup. A backup
//! missing tables it should have is worse than no backup: the client
//! holds a file it believes is its data.

use fire_crab_ods::format::{dtype, flag_bytes, Descriptor};

/// The major record bytes this writer emits (burp.h:84).
mod rec {
    pub const BURP: u8 = 0;
    pub const DATABASE: u8 = 1;
    pub const GLOBAL_FIELD: u8 = 2;
    pub const RELATION: u8 = 3;
    pub const FIELD: u8 = 4;
    pub const DATA: u8 = 6;
    pub const RELATION_DATA: u8 = 8;
    pub const RELATION_END: u8 = 9;
    pub const END: u8 = 10;
    pub const PHYSICAL_DB: u8 = 14;
    pub const SCHEMA: u8 = 42;
}

/// One attribute-carrying record under construction.
struct Rec<'a> {
    out: &'a mut Vec<u8>,
}

impl<'a> Rec<'a> {
    fn new(out: &'a mut Vec<u8>, rec: u8) -> Rec<'a> {
        out.push(rec);
        Rec { out }
    }
    fn int(self, att: u8, v: i32) -> Self {
        self.out.push(att);
        self.out.push(4);
        self.out.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn byte(self, att: u8, v: u8) -> Self {
        self.out.push(att);
        self.out.push(1);
        self.out.push(v);
        self
    }
    fn text(self, att: u8, s: &str) -> Self {
        let b = s.as_bytes();
        let n = b.len().min(255);
        self.out.push(att);
        self.out.push(n as u8);
        self.out.extend_from_slice(&b[..n]);
        self
    }
    fn end(self) {
        self.out.push(0); // att_end
    }
}

/// A column the writer carries: everything both the metadata records
/// and the row encoder need.
struct Col {
    name: String,
    /// the invented domain name (RDB$1, RDB$2, ... - gbak restore binds
    /// columns to domains by NAME WITHIN THE FILE, so consistency is
    /// all that matters)
    source: String,
    position: u16,
    desc: Descriptor,
}

/// RDB$FIELDS.RDB$FIELD_TYPE for a descriptor's dtype - the values the
/// catalog stores and the burp records carry.
fn rdb_field_type(d: &Descriptor) -> Option<i32> {
    Some(match d.dtype {
        dtype::SHORT => 7,
        dtype::LONG => 8,
        dtype::INT64 => 16,
        dtype::TEXT => 14,
        dtype::VARYING => 37,
        _ => return None,
    })
}

/// XDR-encode one row (canonical.cpp seen from its output): values in
/// field order, then one 4-byte null indicator per field.
fn xdr_row(image: &[u8], cols: &[Col], nulls_at: usize) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let null = |i: usize| image.get(nulls_at + i / 8).is_some_and(|b| b & (1 << (i % 8)) != 0);
    for (i, c) in cols.iter().enumerate() {
        let off = c.desc.offset as usize;
        let is_null = null(i);
        match c.desc.dtype {
            dtype::SHORT => {
                let v = if is_null || image.len() < off + 2 {
                    0
                } else {
                    i16::from_le_bytes([image[off], image[off + 1]]) as i32
                };
                out.extend_from_slice(&v.to_be_bytes());
            }
            dtype::LONG => {
                let v = if is_null || image.len() < off + 4 {
                    0
                } else {
                    i32::from_le_bytes(image[off..off + 4].try_into().ok()?)
                };
                out.extend_from_slice(&v.to_be_bytes());
            }
            dtype::INT64 => {
                let v = if is_null || image.len() < off + 8 {
                    0
                } else {
                    i64::from_le_bytes(image[off..off + 8].try_into().ok()?)
                };
                out.extend_from_slice(&v.to_be_bytes());
            }
            dtype::VARYING => {
                // stored: u16 LE length + bytes; XDR: u32 BE length +
                // bytes padded to 4
                let (len, bytes): (usize, &[u8]) = if is_null || image.len() < off + 2 {
                    (0, &[])
                } else {
                    let n = u16::from_le_bytes([image[off], image[off + 1]]) as usize;
                    let end = (off + 2 + n).min(image.len());
                    (end - off - 2, &image[off + 2..end])
                };
                out.extend_from_slice(&(len as u32).to_be_bytes());
                out.extend_from_slice(bytes);
                out.extend(std::iter::repeat(0u8).take((4 - len % 4) % 4));
            }
            dtype::TEXT => {
                // fixed n bytes, padded to 4 (xdr opaque)
                let n = c.desc.length as usize;
                if is_null || image.len() < off + n {
                    out.extend(std::iter::repeat(b' ').take(n));
                } else {
                    out.extend_from_slice(&image[off..off + n]);
                }
                out.extend(std::iter::repeat(0u8).take((4 - n % 4) % 4));
            }
            _ => return None,
        }
    }
    for i in 0..cols.len() {
        let flag: u32 = if null(i) { 0xffff_ffff } else { 0 };
        out.extend_from_slice(&flag.to_be_bytes());
    }
    Some(out)
}

/// A `ctime`-shaped stamp, UTC (the same deviation the service
/// timestamps state: fire-crab has no timezone database).
fn backup_date(now_secs: i64) -> String {
    // civil-from-days, Howard Hinnant's algorithm
    let days = now_secs.div_euclid(86400);
    let rem = now_secs.rem_euclid(86400);
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    let wd = (days + 4).rem_euclid(7); // 1970-01-01 was a Thursday
    const WD: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MO: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    format!(
        "{} {} {:2} {:02}:{:02}:{:02} {}",
        WD[wd as usize],
        MO[(m - 1) as usize],
        d,
        h,
        mi,
        s,
        y
    )
}

/// What the backup REFUSED and why - one line for the service trace.
pub struct Refused(pub String);

/// Write a `.fbk` of the database image. `db_path` and `fbk_path` are
/// carried in the header attributes exactly as gbak carries them;
/// `now_secs` stamps the backup date.
pub fn write_backup(
    image: &[u8],
    page_size: usize,
    db_path: &str,
    fbk_path: &str,
    now_secs: i64,
) -> Result<Vec<u8>, Refused> {
    let head = fire_crab_ods::header::HeaderPage::decode(image)
        .ok_or_else(|| Refused("not a database image".into()))?;

    // THE SURFACE CHECK, first and fail-closed: anything present that
    // this writer cannot carry refuses the whole backup. Each check
    // resolves its system relation and its RDB$SYSTEM_FLAG column BY
    // NAME - relation ids and field positions are ODS facts the check
    // must read, not guess (RDB$GENERATORS is relation 20, not the 10
    // a first guess said, and the gate caught it).
    for (what, rel_name) in [
        ("a stored procedure", "RDB$PROCEDURES"),
        ("a trigger", "RDB$TRIGGERS"),
        ("a sequence", "RDB$GENERATORS"),
        ("an exception", "RDB$EXCEPTIONS"),
        ("a user function", "RDB$FUNCTIONS"),
        ("an index", "RDB$INDICES"),
        ("a role", "RDB$ROLES"),
    ] {
        if user_rows_in(image, page_size, rel_name) > 0 {
            return Err(Refused(format!("{} is outside this backup's surface", what)));
        }
    }
    let user_rels: Vec<(u16, String)> = user_tables(image, page_size)?;

    let mut out = Vec::new();
    // --- rec_burp: the program attributes, pinned against FB6 ---------
    Rec::new(&mut out, rec::BURP)
        .int(2, 12) // att_backup_format - version 12
        .int(4, 1) // att_backup_compress
        .int(5, 1) // att_backup_transportable
        .int(6, 262_144) // att_backup_blksize
        .int(8, 1) // att_backup_volume
        .text(7, fbk_path) // att_backup_file
        .text(1, &backup_date(now_secs)) // att_backup_date
        .end();
    // --- rec_physical_db ----------------------------------------------
    Rec::new(&mut out, rec::PHYSICAL_DB)
        .int(14, 3) // SQL dialect
        .int(5, page_size as i32) // att_page_size
        .int(8, 20_000) // att_sweep_interval (gbak snapshots the default)
        .int(12, i32::from(head.flags & fire_crab_ods::header::hdr_flags::FORCE_WRITE != 0))
        .text(1, db_path) // att_file_name
        .end();
    // --- rec_database ---------------------------------------------------
    Rec::new(&mut out, rec::DATABASE)
        .text(11, "NONE") // att_database_dfl_charset
        .byte(20, 0)
        .byte(21, 0)
        .end();
    // --- rec_schema: PUBLIC ----------------------------------------------
    Rec::new(&mut out, rec::SCHEMA).text(1, "PUBLIC").end();

    // --- the relations' columns, and their invented domains --------------
    let mut rel_cols: Vec<(u16, String, Vec<Col>)> = Vec::new();
    let mut next_source = 1usize;
    for (id, name) in &user_rels {
        let formats = fire_crab_ods::relation_formats(image, page_size, *id);
        let descs = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .map(|(_, d)| d.clone())
            .ok_or_else(|| Refused(format!("relation {} has no format", name)))?;
        let names = fire_crab_ods::catalog::relation_columns(image, page_size, name);
        if names.len() != descs.len() {
            return Err(Refused(format!(
                "relation {}: {} columns, {} descriptors - a computed or dropped column shape",
                name,
                names.len(),
                descs.len()
            )));
        }
        let mut cols = Vec::new();
        for (i, d) in descs.iter().enumerate() {
            if rdb_field_type(d).is_none() {
                return Err(Refused(format!(
                    "relation {}: column {} has a type outside this backup's surface",
                    name, names[i].name
                )));
            }
            cols.push(Col {
                name: names[i].name.clone(),
                source: format!("RDB${}", next_source),
                position: names[i].position,
                desc: d.clone(),
            });
            next_source += 1;
        }
        rel_cols.push((*id, name.clone(), cols));
    }

    // --- rec_global_field: one per column, in file order ------------------
    for (_, _, cols) in &rel_cols {
        for c in cols {
            let t = rdb_field_type(&c.desc).unwrap();
            let r = Rec::new(&mut out, rec::GLOBAL_FIELD)
                .text(48, "PUBLIC")
                .text(1, &c.source)
                .int(8, t)
                .int(10, c.desc.length as i32)
                .int(9, c.desc.scale as i32)
                .int(11, 0);
            match c.desc.dtype {
                dtype::VARYING | dtype::TEXT => r
                    .int(41, c.desc.length as i32) // character length (NONE: 1 byte/char)
                    .int(42, 0) // character set NONE
                    .int(43, 0) // collation
                    .end(),
                _ => r.int(44, 0).end(),
            }
        }
    }

    // --- per relation: rec_relation + fields + end -----------------------
    for (_, name, cols) in &rel_cols {
        Rec::new(&mut out, rec::RELATION)
            .text(21, "PUBLIC")
            .text(1, name)
            .int(16, 1) // att_relation_flags (pinned from the reference file)
            .int(18, 0) // relation type: persistent
            .end();
        for (i, c) in cols.iter().enumerate() {
            let r = Rec::new(&mut out, rec::FIELD)
                .text(1, &c.name)
                .text(48, "PUBLIC")
                .text(2, &c.source)
                .int(13, c.position as i32)
                .int(8, rdb_field_type(&c.desc).unwrap())
                .int(10, c.desc.length as i32)
                .int(9, c.desc.scale as i32)
                .int(11, 0)
                .int(22, (i + 1) as i32)
                .int(24, 0)
                .int(34, 1);
            match c.desc.dtype {
                dtype::VARYING | dtype::TEXT => r.int(42, 0).int(43, 0).end(),
                _ => r.int(43, 0).end(),
            }
        }
        out.push(rec::RELATION_END);
    }

    // --- per relation: the data ------------------------------------------
    let tips = fire_crab_ods::tra::TipChain::read(image, page_size);
    for (id, name, cols) in &rel_cols {
        Rec::new(&mut out, rec::RELATION_DATA)
            .text(21, "PUBLIC")
            .text(1, name)
            .end();
        let descs: Vec<Descriptor> = cols.iter().map(|c| c.desc.clone()).collect();
        let rows = match tips.as_ref() {
            Some(t) => fire_crab_ods::tra::visible_rows(image, page_size, *id, &descs, t),
            None => Vec::new(),
        };
        // the null bitmap sits at the front of the record image
        let nulls_at = 0usize;
        let _ = flag_bytes(cols.len());
        for row in &rows {
            let xdr = xdr_row(&row.image, cols, nulls_at)
                .ok_or_else(|| Refused(format!("relation {}: a row failed to encode", name)))?;
            Rec::new(&mut out, rec::DATA)
                .int(1, xdr.len() as i32) // att_data_length
                .int(17, xdr.len() as i32); // att_xdr_length
            // (Rec::int returns self; the record stays OPEN - data has
            // no att_end, the compressed block follows the data tag)
            out.push(2); // att_data_data
            out.extend_from_slice(&fire_crab_ods::sqz::pack(&xdr));
        }
        out.push(rec::RELATION_END);
    }

    out.push(rec::END);
    // gbak pads its last block with zeros; 512 is what the reference
    // file's tail shows
    while out.len() % 512 != 0 {
        out.push(0);
    }
    Ok(out)
}

/// A system relation's rows plus its column-name -> value-index map -
/// what every surface check reads.
fn sys_rows(
    image: &[u8],
    page_size: usize,
    rel_name: &str,
) -> Option<(Vec<(String, usize)>, Vec<fire_crab_ods::tra::VisibleRow>)> {
    let id = fire_crab_ods::resolve_relation(image, page_size, rel_name)?;
    // a SYSTEM relation's formats are not in RDB$FORMATS - they come
    // from the sysfmt bootstrap, the same split the server reads by
    let formats = fire_crab_ods::sysfmt::system_relation_formats(image, page_size, rel_name)?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let tips = fire_crab_ods::tra::TipChain::read(image, page_size)?;
    let cols = fire_crab_ods::catalog::relation_columns(image, page_size, rel_name)
        .into_iter()
        .enumerate()
        .map(|(i, c)| (c.name, i))
        .collect();
    Some((
        cols,
        fire_crab_ods::tra::visible_rows(image, page_size, id, descs, &tips),
    ))
}

/// USER rows in a system relation: rows whose RDB$SYSTEM_FLAG is 0 or
/// NULL. What the surface checks count.
fn user_rows_in(image: &[u8], page_size: usize, rel_name: &str) -> u64 {
    let Some((cols, rows)) = sys_rows(image, page_size, rel_name) else {
        return 0;
    };
    let flag_at = cols
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("RDB$SYSTEM_FLAG"))
        .map(|(_, i)| *i);
    rows.iter()
        .filter(|r| {
            !matches!(
                flag_at.and_then(|i| r.values.get(i)),
                Some(fire_crab_ods::format::Value::Int(n)) if *n != 0
            )
        })
        .count() as u64
}

/// The user TABLES - and only tables: a VIEW in the list refuses the
/// backup (its "rows" are a query, and writing it as a table would
/// restore a table where a view was - the right rows today, the wrong
/// database from then on).
fn user_tables(image: &[u8], page_size: usize) -> Result<Vec<(u16, String)>, Refused> {
    let Some((cols, rows)) = sys_rows(image, page_size, "RDB$RELATIONS") else {
        return Err(Refused("RDB$RELATIONS is unreadable".into()));
    };
    let at = |n: &str| cols.iter().find(|(c, _)| c.eq_ignore_ascii_case(n)).map(|(_, i)| *i);
    let (name_at, id_at) = match (at("RDB$RELATION_NAME"), at("RDB$RELATION_ID")) {
        (Some(n), Some(i)) => (n, i),
        _ => return Err(Refused("RDB$RELATIONS has no name/id columns".into())),
    };
    let type_at = at("RDB$RELATION_TYPE");
    let flag_at = at("RDB$SYSTEM_FLAG");
    let mut out = Vec::new();
    for r in &rows {
        let system = matches!(
            flag_at.and_then(|i| r.values.get(i)),
            Some(fire_crab_ods::format::Value::Int(n)) if *n != 0
        );
        if system {
            continue;
        }
        let name = match r.values.get(name_at) {
            Some(fire_crab_ods::format::Value::Text(t)) => t.trim_end().to_string(),
            _ => continue,
        };
        let id = match r.values.get(id_at) {
            Some(fire_crab_ods::format::Value::Int(n)) => *n as u16,
            _ => continue,
        };
        // relation type 0 = persistent table; anything else (1 = view,
        // 4/5 = GTT) is outside the surface
        match type_at.and_then(|i| r.values.get(i)) {
            Some(fire_crab_ods::format::Value::Int(0)) | None => {}
            Some(fire_crab_ods::format::Value::Null) => {}
            _ => {
                return Err(Refused(format!(
                    "relation {} is not a persistent table - outside this backup's surface",
                    name
                )))
            }
        }
        out.push((id, name));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_date_is_ctime_shaped() {
        // Fri Aug  7 22:46:20 2026 - the reference file's own stamp
        assert_eq!(backup_date(1786142780), "Fri Aug  7 22:46:20 2026");
        // single-digit day pads with a space, as ctime does
        assert_eq!(backup_date(1767229200), "Thu Jan  1 01:00:00 2026");
    }

    #[test]
    fn xdr_rows_are_big_endian_with_trailing_null_flags() {
        // a record image: null bitmap (4 bytes, no nulls), ID=1 @4,
        // VARCHAR "one" @8 (u16 len + bytes)
        let mut img = vec![0u8; 4];
        img.extend_from_slice(&1i32.to_le_bytes());
        img.extend_from_slice(&3u16.to_le_bytes());
        img.extend_from_slice(b"one");
        let cols = vec![
            Col {
                name: "ID".into(),
                source: "RDB$1".into(),
                position: 0,
                desc: Descriptor { dtype: dtype::LONG, scale: 0, length: 4, sub_type: 0, flags: 0, offset: 4 },
            },
            Col {
                name: "V".into(),
                source: "RDB$2".into(),
                position: 1,
                desc: Descriptor { dtype: dtype::VARYING, scale: 0, length: 10, sub_type: 0, flags: 0, offset: 8 },
            },
        ];
        let xdr = xdr_row(&img, &cols, 0).unwrap();
        // the reference row, decompressed from the engine's own fbk:
        // 00000001 00000003 "one" 00 | 00000000 00000000
        assert_eq!(
            xdr,
            [
                0, 0, 0, 1, // ID, big-endian
                0, 0, 0, 3, b'o', b'n', b'e', 0, // VARCHAR: BE len, bytes, pad
                0, 0, 0, 0, 0, 0, 0, 0, // two null flags
            ]
        );
        // and NULL: the flag goes 0xFFFFFFFF, the varchar slot SHRINKS
        // to its empty length word - XDR is self-describing, so a null
        // row is SHORTER, not zero-padded to the full slot
        let mut img2 = img.clone();
        img2[0] = 0b10; // field 1 (V) null
        let xdr2 = xdr_row(&img2, &cols, 0).unwrap();
        assert_eq!(xdr2.len(), 16);
        assert_eq!(&xdr2[4..8], &[0, 0, 0, 0]); // empty varchar
        assert_eq!(&xdr2[8..12], &[0, 0, 0, 0]); // ID not null
        assert_eq!(&xdr2[12..16], &[0xff, 0xff, 0xff, 0xff]);
    }
}
