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
    pub const REL_CONSTRAINT: u8 = 31;
    pub const CHK_CONSTRAINT: u8 = 33;
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
    /// RDB$RELATION_FIELDS.RDB$NULL_FLAG - carried as the same three
    /// pieces the engine writes: att 38 on the field record, and an
    /// INTEG "NOT NULL" rel_constraint + chk_constraint pair
    not_null: bool,
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
#[derive(Debug)]
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
    // ...and USER DOMAINS: this writer invents its column sources
    // (RDB$1, RDB$2, ...), so a named domain would restore as a plain
    // type - the data right, the schema silently changed. Refuse.
    if let Some((cols, rows)) = sys_rows(image, page_size, "RDB$FIELDS") {
        let name_at = cols
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case("RDB$FIELD_NAME"))
            .map(|(_, i)| *i);
        for r in &rows {
            if let Some(fire_crab_ods::format::Value::Text(t)) =
                name_at.and_then(|i| r.values.get(i))
            {
                let t = t.trim_end();
                if !t.starts_with("RDB$") && !t.starts_with("SEC$") && !t.starts_with("MON$") {
                    return Err(Refused(format!(
                        "domain {} is outside this backup's surface",
                        t
                    )));
                }
            }
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
        let not_nulls = not_null_columns(image, page_size, name);
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
                not_null: not_nulls.iter().any(|n| n == &names[i].name),
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
            let mut r = Rec::new(&mut out, rec::FIELD)
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
            if c.not_null {
                // att 38 - the field-level NULL_FLAG the reference file
                // carries on its NOT NULL column
                r = r.int(38, 1);
            }
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

    // --- NOT NULL as the engine carries it: an INTEG rel_constraint +
    // chk_constraint pair per column, after the data (the reference
    // file's own position). The names are invented like the sources -
    // the restore regenerates its own INTEG names anyway.
    let mut integ = 1usize;
    for (_, name, cols) in &rel_cols {
        for c in cols {
            if !c.not_null {
                continue;
            }
            let cname = format!("INTEG_{}", integ);
            integ += 1;
            Rec::new(&mut out, rec::REL_CONSTRAINT)
                .text(7, "PUBLIC")
                .text(1, &cname)
                .text(2, "NOT NULL")
                .text(3, name)
                .text(4, "NO")
                .text(5, "NO")
                .end();
            Rec::new(&mut out, rec::CHK_CONSTRAINT)
                .text(3, "PUBLIC")
                .text(1, &cname)
                .text(2, &c.name)
                .end();
        }
    }

    out.push(rec::END);
    // gbak pads its last block with zeros; 512 is what the reference
    // file's tail shows
    while out.len() % 512 != 0 {
        out.push(0);
    }
    Ok(out)
}

/// The NOT NULL columns of one relation - RDB$RELATION_FIELDS rows
/// whose RDB$NULL_FLAG is 1, matched by name.
fn not_null_columns(image: &[u8], page_size: usize, rel_name: &str) -> Vec<String> {
    let Some((cols, rows)) = sys_rows(image, page_size, "RDB$RELATION_FIELDS") else {
        return Vec::new();
    };
    let at = |n: &str| cols.iter().find(|(c, _)| c.eq_ignore_ascii_case(n)).map(|(_, i)| *i);
    let (Some(rel_at), Some(fld_at), Some(null_at)) = (
        at("RDB$RELATION_NAME"),
        at("RDB$FIELD_NAME"),
        at("RDB$NULL_FLAG"),
    ) else {
        return Vec::new();
    };
    rows.iter()
        .filter(|r| {
            matches!(r.values.get(rel_at), Some(fire_crab_ods::format::Value::Text(t)) if t.trim_end() == rel_name)
                && matches!(r.values.get(null_at), Some(fire_crab_ods::format::Value::Int(1)))
        })
        .filter_map(|r| match r.values.get(fld_at) {
            Some(fire_crab_ods::format::Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        })
        .collect()
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
                not_null: false,
            },
            Col {
                name: "V".into(),
                source: "RDB$2".into(),
                position: 1,
                desc: Descriptor { dtype: dtype::VARYING, scale: 0, length: 10, sub_type: 0, flags: 0, offset: 8 },
                not_null: false,
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

// ===================================================================
// THE READ SIDE: a .fbk - the engine's or this crate's own - decoded
// back into tables and rows, for `isc_action_svc_restore`.
//
// The reader is TOLERANT OF ATTRIBUTES and STRICT ABOUT RECORDS. An
// attribute it does not know is skipped by its own length - the
// grammar is self-describing, and that is how the engine's restore
// survives files from newer engines. A RECORD type it does not know
// cannot be skipped (some records are bare, some carry raw payloads),
// and mis-stepping the walk turns everything after into nonsense - so
// an unknown record refuses the WHOLE restore. Records this slice
// understands but does not carry (privileges) are parsed and set
// aside; records that would change what the database MEANS if dropped
// (indexes, triggers, generators, views) refuse.

/// One value out of a data row, as the XDR carries it.
#[derive(Clone, Debug, PartialEq)]
pub enum RVal {
    Null,
    Int(i64),
    /// text bytes, exactly as stored (CHAR keeps its padding)
    Bytes(Vec<u8>),
}

/// One restored column.
pub struct RCol {
    pub name: String,
    /// RDB$FIELD_TYPE: 7 smallint, 8 integer, 16 int64, 14 text, 37 varying
    pub field_type: i32,
    pub length: u16,
    pub scale: i8,
    pub not_null: bool,
}

/// One restored table.
pub struct RTable {
    pub name: String,
    pub cols: Vec<RCol>,
    pub rows: Vec<Vec<RVal>>,
}

/// What a .fbk holds, as far as this slice carries it.
pub struct Restored {
    pub page_size: Option<u32>,
    pub tables: Vec<RTable>,
    /// privilege records seen and set aside - the count keeps the
    /// omission visible in the trace instead of silent
    pub privileges_skipped: u64,
}

/// One parsed attribute.
struct Att {
    tag: u8,
    data: Vec<u8>,
}

impl Att {
    fn int(&self) -> i64 {
        let mut v: i64 = 0;
        for (k, b) in self.data.iter().enumerate().take(8) {
            v |= (*b as i64) << (8 * k);
        }
        v
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.data).into_owned()
    }
}

/// Read one attribute list (up to att_end). Tolerant: unknown tags ride
/// along with their data for the caller to pick from.
fn read_atts(f: &[u8], at: &mut usize) -> Result<Vec<Att>, Refused> {
    let mut out = Vec::new();
    loop {
        let tag = *f.get(*at).ok_or_else(|| Refused("truncated attribute list".into()))?;
        *at += 1;
        if tag == 0 {
            return Ok(out);
        }
        let len = *f.get(*at).ok_or_else(|| Refused("truncated attribute".into()))? as usize;
        *at += 1;
        let data = f
            .get(*at..*at + len)
            .ok_or_else(|| Refused("attribute data past the end".into()))?
            .to_vec();
        *at += len;
        out.push(Att { tag, data });
    }
}

fn att<'a>(atts: &'a [Att], tag: u8) -> Option<&'a Att> {
    atts.iter().find(|a| a.tag == tag)
}

/// Decode one XDR row (the transportable encoding, big-endian, null
/// indicators trailing - the exact mirror of [xdr_row]).
fn xdr_decode(xdr: &[u8], cols: &[RCol]) -> Result<Vec<RVal>, Refused> {
    let mut vals = Vec::with_capacity(cols.len());
    let mut at = 0usize;
    let take = |at: &mut usize, n: usize| -> Result<Vec<u8>, Refused> {
        let d = xdr
            .get(*at..*at + n)
            .ok_or_else(|| Refused("a data row ended mid-field".into()))?
            .to_vec();
        *at += n;
        Ok(d)
    };
    for c in cols {
        match c.field_type {
            7 | 8 => {
                let b = take(&mut at, 4)?;
                vals.push(RVal::Int(i32::from_be_bytes(b.try_into().unwrap()) as i64));
            }
            16 => {
                let b = take(&mut at, 8)?;
                vals.push(RVal::Int(i64::from_be_bytes(b.try_into().unwrap())));
            }
            37 => {
                let b = take(&mut at, 4)?;
                let n = u32::from_be_bytes(b.try_into().unwrap()) as usize;
                if n > c.length as usize {
                    return Err(Refused("a varchar longer than its column".into()));
                }
                let d = take(&mut at, n)?;
                at += (4 - n % 4) % 4; // the pad
                vals.push(RVal::Bytes(d));
            }
            14 => {
                let n = c.length as usize;
                let d = take(&mut at, n)?;
                at += (4 - n % 4) % 4;
                vals.push(RVal::Bytes(d));
            }
            _ => return Err(Refused("a field type outside this restore's surface".into())),
        }
    }
    // the trailing null indicators, one per field
    for v in vals.iter_mut() {
        let b = take(&mut at, 4)?;
        if u32::from_be_bytes(b.try_into().unwrap()) != 0 {
            *v = RVal::Null;
        }
    }
    Ok(vals)
}

/// Read a whole .fbk.
pub fn read_backup(f: &[u8]) -> Result<Restored, Refused> {
    let mut at = 0usize;
    let mut out = Restored { page_size: None, tables: Vec::new(), privileges_skipped: 0 };
    // (schema, source name) -> not-null flag learned from constraints
    let mut current_rel: Option<usize> = None; // index into out.tables (metadata phase)
    let mut data_rel: Option<usize> = None; // index (data phase)
    // constraint pairs: name -> table, and name -> column
    let mut cons_table: Vec<(String, String)> = Vec::new();
    let mut cons_column: Vec<(String, String)> = Vec::new();
    // field-record not-null (att 38) rides the column directly
    loop {
        let r = *f.get(at).ok_or_else(|| Refused("no rec_end - a truncated backup".into()))?;
        at += 1;
        match r {
            rec::BURP => {
                let atts = read_atts(f, &mut at)?;
                // transportable is the only encoding this reader speaks;
                // a non-transportable file's data is in the WRITER's
                // byte order and must refuse rather than misread
                if let Some(a) = att(&atts, 5) {
                    if a.int() == 0 {
                        return Err(Refused("a non-transportable backup".into()));
                    }
                }
                if let Some(a) = att(&atts, 4) {
                    if a.int() == 0 {
                        return Err(Refused("an uncompressed backup".into()));
                    }
                }
            }
            rec::PHYSICAL_DB => {
                let atts = read_atts(f, &mut at)?;
                out.page_size = att(&atts, 5).map(|a| a.int() as u32);
            }
            rec::DATABASE | rec::SCHEMA | rec::GLOBAL_FIELD => {
                // domains arrive re-derived from the field records; the
                // database attributes this slice carries are defaults
                let _ = read_atts(f, &mut at)?;
            }
            rec::RELATION => {
                let atts = read_atts(f, &mut at)?;
                let name = att(&atts, 1)
                    .map(|a| a.text())
                    .ok_or_else(|| Refused("a relation with no name".into()))?;
                out.tables.push(RTable { name, cols: Vec::new(), rows: Vec::new() });
                current_rel = Some(out.tables.len() - 1);
            }
            rec::FIELD => {
                let atts = read_atts(f, &mut at)?;
                let t = current_rel.ok_or_else(|| Refused("a field outside a relation".into()))?;
                let ftype = att(&atts, 8)
                    .map(|a| a.int() as i32)
                    .ok_or_else(|| Refused("a field with no type".into()))?;
                if !matches!(ftype, 7 | 8 | 16 | 14 | 37) {
                    return Err(Refused(format!(
                        "field type {} is outside this restore's surface",
                        ftype
                    )));
                }
                out.tables[t].cols.push(RCol {
                    name: att(&atts, 1)
                        .map(|a| a.text())
                        .ok_or_else(|| Refused("a field with no name".into()))?,
                    field_type: ftype,
                    length: att(&atts, 10).map(|a| a.int() as u16).unwrap_or(0),
                    scale: att(&atts, 9).map(|a| a.int() as i8).unwrap_or(0),
                    not_null: att(&atts, 38).map(|a| a.int() == 1).unwrap_or(false),
                });
            }
            rec::RELATION_END => {
                current_rel = None;
                data_rel = None;
            }
            rec::RELATION_DATA => {
                let atts = read_atts(f, &mut at)?;
                let name = att(&atts, 1)
                    .map(|a| a.text())
                    .ok_or_else(|| Refused("relation data with no name".into()))?;
                data_rel = out.tables.iter().position(|t| t.name == name);
                if data_rel.is_none() {
                    return Err(Refused(format!("data for an unknown relation {}", name)));
                }
            }
            rec::DATA => {
                let t = data_rel.ok_or_else(|| Refused("data outside relation data".into()))?;
                // att_data_length, att_xdr_length, then the raw block
                let mut lens = [0i64; 2];
                for slot in lens.iter_mut() {
                    let tag = *f.get(at).ok_or_else(|| Refused("truncated data record".into()))?;
                    let len = *f.get(at + 1).ok_or_else(|| Refused("truncated data record".into()))? as usize;
                    let a = Att {
                        tag,
                        data: f
                            .get(at + 2..at + 2 + len)
                            .ok_or_else(|| Refused("truncated data record".into()))?
                            .to_vec(),
                    };
                    at += 2 + len;
                    *slot = a.int();
                    let _ = tag;
                }
                let want = lens[1] as usize; // att_xdr_length
                if *f.get(at).ok_or_else(|| Refused("truncated data record".into()))? != 2 {
                    return Err(Refused("a data record without att_data_data".into()));
                }
                at += 1;
                // the RLE stream: positive = literals, negative = repeat
                let mut xdr = Vec::with_capacity(want);
                while xdr.len() < want {
                    let c = *f.get(at).ok_or_else(|| Refused("a data row ended mid-stream".into()))?;
                    at += 1;
                    if c < 128 {
                        let d = f
                            .get(at..at + c as usize)
                            .ok_or_else(|| Refused("a data row ended mid-run".into()))?;
                        xdr.extend_from_slice(d);
                        at += c as usize;
                    } else {
                        let b = *f.get(at).ok_or_else(|| Refused("a data row ended mid-repeat".into()))?;
                        at += 1;
                        xdr.extend(std::iter::repeat(b).take(256 - c as usize));
                    }
                }
                let row = xdr_decode(&xdr, &out.tables[t].cols)?;
                out.tables[t].rows.push(row);
            }
            rec::REL_CONSTRAINT => {
                let atts = read_atts(f, &mut at)?;
                let kind = att(&atts, 2).map(|a| a.text()).unwrap_or_default();
                let cname = att(&atts, 1).map(|a| a.text()).unwrap_or_default();
                let table = att(&atts, 3).map(|a| a.text()).unwrap_or_default();
                if kind.trim() == "NOT NULL" {
                    cons_table.push((cname, table));
                } else {
                    // PRIMARY KEY / UNIQUE / FOREIGN KEY constraints need
                    // the index records this slice refuses anyway
                    return Err(Refused(format!(
                        "a {} constraint is outside this restore's surface",
                        kind.trim()
                    )));
                }
            }
            rec::CHK_CONSTRAINT => {
                let atts = read_atts(f, &mut at)?;
                let cname = att(&atts, 1).map(|a| a.text()).unwrap_or_default();
                let col = att(&atts, 2).map(|a| a.text()).unwrap_or_default();
                cons_column.push((cname, col));
            }
            22 => {
                // rec_user_privilege: parsed and set aside. GRANTs are
                // access metadata, not data; the count keeps the
                // omission visible.
                let _ = read_atts(f, &mut at)?;
                out.privileges_skipped += 1;
            }
            rec::END => break,
            other => {
                return Err(Refused(format!(
                    "record type {} is outside this restore's surface",
                    other
                )));
            }
        }
    }
    // fold the NOT NULL constraint pairs onto the columns
    for (cname, table) in &cons_table {
        let Some(col) = cons_column.iter().find(|(n, _)| n == cname).map(|(_, c)| c) else {
            continue;
        };
        if let Some(t) = out.tables.iter_mut().find(|t| &t.name == table) {
            if let Some(c) = t.cols.iter_mut().find(|c| &c.name == col) {
                c.not_null = true;
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod read_tests {
    use super::*;

    /// The round trip is the unit test: what the writer produces, the
    /// reader decodes - tables, types, rows, NULLs and NOT NULL alike.
    #[test]
    fn the_reader_decodes_what_the_writer_wrote() {
        // a synthetic fbk via the writer's own building blocks
        let mut f = Vec::new();
        Rec::new(&mut f, rec::BURP).int(2, 12).int(4, 1).int(5, 1).end();
        Rec::new(&mut f, rec::PHYSICAL_DB).int(5, 8192).end();
        Rec::new(&mut f, rec::DATABASE).text(11, "NONE").end();
        Rec::new(&mut f, rec::RELATION).text(21, "PUBLIC").text(1, "T").end();
        Rec::new(&mut f, rec::FIELD)
            .text(1, "ID")
            .int(13, 0)
            .int(8, 8)
            .int(10, 4)
            .int(9, 0)
            .int(38, 1)
            .end();
        Rec::new(&mut f, rec::FIELD)
            .text(1, "V")
            .int(13, 1)
            .int(8, 37)
            .int(10, 10)
            .int(9, 0)
            .end();
        f.push(rec::RELATION_END);
        Rec::new(&mut f, rec::RELATION_DATA).text(21, "PUBLIC").text(1, "T").end();
        let xdr: Vec<u8> = vec![
            0, 0, 0, 1, // ID = 1
            0, 0, 0, 3, b'o', b'n', b'e', 0, // V = 'one'
            0, 0, 0, 0, 0, 0, 0, 0, // not null
        ];
        Rec::new(&mut f, rec::DATA)
            .int(1, xdr.len() as i32)
            .int(17, xdr.len() as i32);
        f.push(2);
        f.extend_from_slice(&fire_crab_ods::sqz::pack(&xdr));
        f.push(rec::RELATION_END);
        f.push(rec::END);

        let r = read_backup(&f).unwrap();
        assert_eq!(r.page_size, Some(8192));
        assert_eq!(r.tables.len(), 1);
        let t = &r.tables[0];
        assert_eq!(t.name, "T");
        assert_eq!(t.cols.len(), 2);
        assert!(t.cols[0].not_null, "att 38 carries NOT NULL");
        assert!(!t.cols[1].not_null);
        assert_eq!(t.rows.len(), 1);
        assert_eq!(t.rows[0][0], RVal::Int(1));
        assert_eq!(t.rows[0][1], RVal::Bytes(b"one".to_vec()));

        // an unknown RECORD refuses whole - mis-stepping the walk would
        // turn everything after into nonsense
        let mut bad = f.clone();
        let end = bad.len() - 1;
        bad[end] = 13; // rec_trigger where rec_end was
        assert!(read_backup(&bad).is_err());
    }
}
