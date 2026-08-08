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
    pub const INDEX: u8 = 5;
    pub const DATA: u8 = 6;
    pub const BLOB: u8 = 7;
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
    /// att 22 - the field id rec_blob's field number points at
    field_id: i32,
    /// the ORIGINAL descriptor index - the record image's null bitmap
    /// is bit-per-descriptor in CREATION order, and the emitted column
    /// order is not that (blobs come first)
    bitmap_bit: usize,
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
        dtype::BLOB => 261,
        _ => return None,
    })
}

/// XDR-encode one row (canonical.cpp seen from its output): values in
/// field order, then one 4-byte null indicator per field.
fn xdr_row(image: &[u8], cols: &[Col], nulls_at: usize) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    // THE BITMAP BIT IS THE DESCRIPTOR INDEX, NOT THE EMITTED INDEX -
    // with blobs sorted first the two part company, and reading the
    // wrong bit made a NULL blob look live (quad 0:0, "unreadable")
    let null = |bit: usize| {
        image.get(nulls_at + bit / 8).is_some_and(|b| b & (1 << (bit % 8)) != 0)
    };
    for c in cols.iter() {
        let off = c.desc.offset as usize;
        let is_null = null(c.bitmap_bit);
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
            dtype::BLOB => {
                // the QUAD, canonicalized as two big-endian longs of its
                // two stored little-endian words - measured: the first
                // blob of relation 128 rides as 00000080 00000000
                let (hi, lo) = if is_null || image.len() < off + 8 {
                    (0u32, 0u32)
                } else {
                    (
                        u32::from_le_bytes(image[off..off + 4].try_into().ok()?),
                        u32::from_le_bytes(image[off + 4..off + 8].try_into().ok()?),
                    )
                };
                out.extend_from_slice(&hi.to_be_bytes());
                out.extend_from_slice(&lo.to_be_bytes());
            }
            _ => return None,
        }
    }
    for c in cols.iter() {
        let flag: u32 = if null(c.bitmap_bit) { 0xffff_ffff } else { 0 };
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
    write_backup_verbose(image, page_size, db_path, fbk_path, now_secs, &mut Vec::new())
}

/// [write_backup] with gbak's own commentary: every line the engine's
/// `-v` stream prints for the work THIS writer performs is pushed to
/// `log`, phrased from the live captures (the message text carries the
/// `gbak:` prefix on the wire - fbsvcmgr trims the framing space, the
/// gbak client does not). The category headers are UNCONDITIONAL, as
/// the engine's are - "writing functions" prints over an empty set -
/// which is honest here because the surface check above refuses any
/// database where those sets are NOT empty. Per-record lines print only
/// for records actually written; this writer emits no privilege
/// records, so no privilege lines - the one difference from the
/// engine's stream on the same source, and the gate's recorded filter.
pub fn write_backup_verbose(
    image: &[u8],
    page_size: usize,
    db_path: &str,
    fbk_path: &str,
    now_secs: i64,
    log: &mut Vec<String>,
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
        ("a role", "RDB$ROLES"),
    ] {
        if user_rows_in(image, page_size, rel_name) > 0 {
            return Err(Refused(format!("{} is outside this backup's surface", what)));
        }
    }
    // CONSTRAINTS are checked by TYPE: NOT NULL and PRIMARY KEY ride the
    // file; UNIQUE / FOREIGN KEY / CHECK constraints are their own
    // slices (an FK needs cross-table restore ordering, a UNIQUE
    // constraint is more than its index - dropping either silently
    // changes what the schema MEANS).
    let constraints = read_constraints(image, page_size)?;
    // ...and the INDEXES, per relation, segments in order
    let indexes = read_indexes(image, page_size)?;
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
    log.push("gbak:writing schemas".into());
    log.push("gbak:writing schema \"PUBLIC\"".into());
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
                // the field id follows CREATION order - the reference
                // file's ID column keeps id 1 though its record comes
                // after the blobs'
                field_id: (i + 1) as i32,
                bitmap_bit: i,
                source: format!("RDB${}", next_source),
                position: names[i].position,
                desc: d.clone(),
                not_null: not_nulls.iter().any(|n| n == &names[i].name),
            });
            next_source += 1;
        }
        // BLOBS FIRST - the measured field-record order of a real file
        // (TXT pos 1, BIN pos 2, ID pos 0), which the DATA rows follow:
        // blob quads lead the XDR row and the null flags keep the same
        // order. Stable within each group, so positions stay readable.
        cols.sort_by_key(|c| (c.desc.dtype != dtype::BLOB, c.position));
        rel_cols.push((*id, name.clone(), cols));
    }

    // --- rec_global_field: one per column, in file order ------------------
    log.push("gbak:writing domains".into());
    for (_, _, cols) in &rel_cols {
        for c in cols {
            log.push(format!("gbak:    writing domain \"PUBLIC\".\"{}\"", c.source));
            let t = rdb_field_type(&c.desc).unwrap();
            // FOR A BLOB THE SCALE SLOT (att 9) CARRIES THE SUB_TYPE -
            // measured: the TEXT blob's records say 9=1 where the
            // binary one's say 9=0, and the scale is meaningless for a
            // quad. att 12 is the segment length (the engine snapshots
            // its default 80).
            let att9 = if c.desc.dtype == dtype::BLOB {
                c.desc.sub_type as i32
            } else {
                c.desc.scale as i32
            };
            let r = Rec::new(&mut out, rec::GLOBAL_FIELD)
                .text(48, "PUBLIC")
                .text(1, &c.source)
                .int(8, t)
                .int(10, c.desc.length as i32)
                .int(9, att9)
                .int(11, 0);
            match c.desc.dtype {
                dtype::VARYING | dtype::TEXT => r
                    .int(41, c.desc.length as i32) // character length (NONE: 1 byte/char)
                    .int(42, 0) // character set NONE
                    .int(43, 0) // collation
                    .end(),
                dtype::BLOB if c.desc.sub_type == 1 => {
                    r.int(12, 80).int(42, 0).int(43, 0).end()
                }
                dtype::BLOB => r.int(12, 80).end(),
                _ => r.int(44, 0).end(),
            }
        }
    }

    // --- per relation: rec_relation + fields + end -----------------------
    log.push("gbak:writing shadow files".into());
    log.push("gbak:writing character sets".into());
    log.push("gbak:writing collations".into());
    log.push("gbak:writing tables".into());
    for (_, name, cols) in &rel_cols {
        log.push(format!("gbak:    writing table \"PUBLIC\".\"{}\"", name));
        for c in cols.iter() {
            log.push(format!("gbak:         writing column \"{}\"", c.name));
        }
        Rec::new(&mut out, rec::RELATION)
            .text(21, "PUBLIC")
            .text(1, name)
            .int(16, 1) // att_relation_flags (pinned from the reference file)
            .int(18, 0) // relation type: persistent
            .end();
        for c in cols.iter() {
            let att9 = if c.desc.dtype == dtype::BLOB {
                c.desc.sub_type as i32
            } else {
                c.desc.scale as i32
            };
            let mut r = Rec::new(&mut out, rec::FIELD)
                .text(1, &c.name)
                .text(48, "PUBLIC")
                .text(2, &c.source)
                .int(13, c.position as i32)
                .int(8, rdb_field_type(&c.desc).unwrap())
                .int(10, c.desc.length as i32)
                .int(9, att9)
                .int(11, 0)
                .int(22, c.field_id)
                .int(24, 0)
                .int(34, 1);
            if c.not_null {
                // att 38 - the field-level NULL_FLAG the reference file
                // carries on its NOT NULL column
                r = r.int(38, 1);
            }
            match c.desc.dtype {
                dtype::VARYING | dtype::TEXT => r.int(42, 0).int(43, 0).end(),
                dtype::BLOB if c.desc.sub_type == 1 => r.int(42, 0).int(43, 0).end(),
                _ => r.int(43, 0).end(),
            }
        }
        out.push(rec::RELATION_END);
    }

    // --- per relation: the data ------------------------------------------
    log.push("gbak:writing types".into());
    log.push("gbak:writing filters".into());
    log.push("gbak:writing id generators".into());
    log.push("gbak:writing exceptions".into());
    log.push("gbak:writing functions".into());
    log.push("gbak:writing stored procedures".into());
    log.push("gbak:writing packages".into());
    let tips = fire_crab_ods::tra::TipChain::read(image, page_size);
    // THE DATA PHASE WALKS THE RELATIONS IN REVERSE CREATION ORDER -
    // burp prepends each relation to its list and the data pass walks
    // the list head-first (a 3-table probe: metadata A,B,C; data
    // C,B,A). The restore maps blocks by name, so only the bytes'
    // ORDER carries the engine's shape - and the verbose stream shows
    // it.
    for (id, name, cols) in rel_cols.iter().rev() {
        Rec::new(&mut out, rec::RELATION_DATA)
            .text(21, "PUBLIC")
            .text(1, name)
            .end();
        // THE INDEXES, before the data - the reference file's own order
        // (burp.h:146: "<rel attributes> <gen id> <indices> <data>").
        // Attributes pinned from a real PK+two-index file: name(1),
        // segment count(2), inactive(3), unique(4), one att 5 PER
        // SEGMENT in key order, index type(7).
        for ix in indexes.iter().filter(|i| &i.relation == name) {
            log.push(format!("gbak:    writing index \"PUBLIC\".\"{}\"", ix.name));
            let mut r = Rec::new(&mut out, rec::INDEX)
                .text(1, &ix.name)
                .int(2, ix.segments.len() as i32)
                .int(3, 0)
                .int(4, i32::from(ix.unique));
            for seg in &ix.segments {
                r = r.text(5, seg);
            }
            r.int(7, ix.itype).end();
        }
        let descs: Vec<Descriptor> = cols.iter().map(|c| c.desc.clone()).collect();
        let rows = match tips.as_ref() {
            // THE LIMBO LAW RIDES THE BACKUP TOO: the engine's gbak
            // dies on "record from transaction N is stuck in limbo"
            // rather than writing a file that silently lacks the rows
            // nobody has adjudicated yet
            Some(t) => {
                fire_crab_ods::tra::visible_rows_2pc(image, page_size, *id, &descs, t, true)
                    .map_err(|tx| {
                        Refused(format!("record from transaction {} is stuck in limbo", tx))
                    })?
            }
            None => Vec::new(),
        };
        log.push(format!("gbak:    writing data for table \"PUBLIC\".\"{}\"", name));
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
            // THE ROW'S BLOBS, each a rec_blob directly after its row
            // (put_data's own order). A NULL blob writes NO record -
            // "It will be restored as null" (backup.epp) - and its quad
            // above was zeros with the flag set.
            for c in cols.iter() {
                if c.desc.dtype != dtype::BLOB {
                    continue;
                }
                let is_null = row
                    .image
                    .get(nulls_at + c.bitmap_bit / 8)
                    .is_some_and(|b| b & (1 << (c.bitmap_bit % 8)) != 0);
                let off = c.desc.offset as usize;
                if is_null || row.image.len() < off + 8 {
                    continue;
                }
                let rel_word = u16::from_le_bytes([row.image[off], row.image[off + 1]]);
                let recno = ((row.image[off + 3] as u64) << 32)
                    | u32::from_le_bytes(row.image[off + 4..off + 8].try_into().unwrap()) as u64;
                let blob = fire_crab_blb::read_blob(image, page_size, rel_word, recno)
                    .map_err(|e| {
                        Refused(format!("relation {}: blob {}:{} unreadable: {}", name, rel_word, recno, e))
                    })?;
                // segments() deframes SEGMENTED blobs; a STREAM blob's
                // raw bytes carry no frames, so it ships as one chunk
                // (the engine rechunks streams by max_segment itself
                // and says so in put_data's own comment)
                let is_stream = blob.header.is_stream();
                let segments: Vec<Vec<u8>> = if is_stream {
                    let c = blob.content();
                    if c.is_empty() { Vec::new() } else { vec![c] }
                } else {
                    blob.segments().map(|s| s.to_vec()).collect()
                };
                let max_seg = segments.iter().map(|s| s.len()).max().unwrap_or(0);
                if max_seg > u16::MAX as usize {
                    return Err(Refused(format!(
                        "relation {}: a blob segment larger than 64K",
                        name
                    )));
                }
                Rec::new(&mut out, rec::BLOB)
                    .int(3, c.field_id) // att_blob_field_number
                    .int(6, max_seg as i32) // att_blob_max_segment
                    .int(5, segments.len() as i32) // att_blob_number_segments
                    .int(4, i32::from(is_stream)); // att_blob_type
                // att_blob_data: a BARE tag, then u16 LE length + bytes
                // per segment - NO att_end on this record at all
                out.push(7);
                for seg in &segments {
                    out.extend_from_slice(&(seg.len() as u16).to_le_bytes());
                    out.extend_from_slice(seg);
                }
            }
        }
        log.push(format!("gbak:{} records written", rows.len()));
        out.push(rec::RELATION_END);
    }

    log.push("gbak:writing triggers".into());
    log.push("gbak:writing trigger messages".into());
    log.push("gbak:writing security classes".into());
    log.push("gbak:writing table constraints".into());
    // --- the table constraints, in CATALOG ROW ORDER (the engine's own
    // file order - a NOT NULL created before the PRIMARY KEY rides
    // before it). The names are the catalog's real ones now, not
    // invented: the PRIMARY KEY names its INDEX through att 6, and a
    // NOT NULL is a rel_constraint + chk_constraint pair whose second
    // record names the COLUMN.
    for c in &constraints {
        log.push(format!("gbak:writing constraint \"PUBLIC\".\"{}\"", c.name));
        match c.kind {
            UConsKind::PrimaryKey => {
                Rec::new(&mut out, rec::REL_CONSTRAINT)
                    .text(7, "PUBLIC")
                    .text(1, &c.name)
                    .text(2, "PRIMARY KEY")
                    .text(3, &c.relation)
                    .text(4, "NO")
                    .text(5, "NO")
                    .text(6, &c.index)
                    .end();
            }
            UConsKind::NotNull => {
                Rec::new(&mut out, rec::REL_CONSTRAINT)
                    .text(7, "PUBLIC")
                    .text(1, &c.name)
                    .text(2, "NOT NULL")
                    .text(3, &c.relation)
                    .text(4, "NO")
                    .text(5, "NO")
                    .end();
                Rec::new(&mut out, rec::CHK_CONSTRAINT)
                    .text(3, "PUBLIC")
                    .text(1, &c.name)
                    .text(2, &c.column)
                    .end();
            }
        }
    }

    log.push("gbak:writing referential constraints".into());
    log.push("gbak:writing check constraints".into());
    log.push("gbak:writing SQL roles".into());
    log.push("gbak:writing names mapping".into());
    log.push("gbak:writing publications".into());
    log.push("gbak:writing constants".into());
    out.push(rec::END);
    // gbak pads its last block with zeros; 512 is what the reference
    // file's tail shows
    while out.len() % 512 != 0 {
        out.push(0);
    }
    Ok(out)
}

/// One user index, as the writer carries it.
struct UIndex {
    name: String,
    relation: String,
    unique: bool,
    /// RDB$INDEX_TYPE: 1 = descending
    itype: i32,
    /// segment field names, in key order
    segments: Vec<String>,
}

#[derive(PartialEq)]
enum UConsKind {
    PrimaryKey,
    NotNull,
}

/// One table constraint, in catalog row order - which IS the file
/// order the engine writes.
struct UCons {
    kind: UConsKind,
    name: String,
    relation: String,
    /// the PRIMARY KEY's index name (att 6)
    index: String,
    /// the NOT NULL's column (RDB$CHECK_CONSTRAINTS' trigger-name slot)
    column: String,
}

/// The user constraints, typed: PRIMARY KEY rides the file, NOT NULL is
/// carried separately, and anything else refuses the backup whole.
fn read_constraints(image: &[u8], page_size: usize) -> Result<Vec<UCons>, Refused> {
    let Some((cols, rows)) = sys_rows(image, page_size, "RDB$RELATION_CONSTRAINTS") else {
        return Ok(Vec::new());
    };
    let at = |n: &str| cols.iter().find(|(c, _)| c.eq_ignore_ascii_case(n)).map(|(_, i)| *i);
    let (Some(name_at), Some(type_at), Some(rel_at)) = (
        at("RDB$CONSTRAINT_NAME"),
        at("RDB$CONSTRAINT_TYPE"),
        at("RDB$RELATION_NAME"),
    ) else {
        return Ok(Vec::new());
    };
    let index_at = at("RDB$INDEX_NAME");
    let text = |r: &fire_crab_ods::tra::VisibleRow, i: usize| match r.values.get(i) {
        Some(fire_crab_ods::format::Value::Text(t)) => t.trim_end().to_string(),
        _ => String::new(),
    };
    // NOT NULL constraints name their COLUMN through the check-
    // constraints table: for a NOT NULL, RDB$TRIGGER_NAME carries the
    // field name, not a trigger's
    let col_of: Vec<(String, String)> = sys_rows(image, page_size, "RDB$CHECK_CONSTRAINTS")
        .map(|(ccols, crows)| {
            let cat = |n: &str| {
                ccols
                    .iter()
                    .find(|(c, _)| c.eq_ignore_ascii_case(n))
                    .map(|(_, i)| *i)
            };
            let (Some(cn), Some(tn)) = (cat("RDB$CONSTRAINT_NAME"), cat("RDB$TRIGGER_NAME"))
            else {
                return Vec::new();
            };
            let t = |r: &fire_crab_ods::tra::VisibleRow, i: usize| match r.values.get(i) {
                Some(fire_crab_ods::format::Value::Text(t)) => t.trim_end().to_string(),
                _ => String::new(),
            };
            crows.iter().map(|r| (t(r, cn), t(r, tn))).collect()
        })
        .unwrap_or_default();
    // CATALOG ROW ORDER IS THE FILE ORDER: the engine writes its
    // rel_constraint records straight off RDB$RELATION_CONSTRAINTS, so
    // a NOT NULL created before the PRIMARY KEY rides before it - the
    // verbose stream showed the order and the file agrees
    let mut out = Vec::new();
    for r in &rows {
        let rel = text(r, rel_at);
        if rel.starts_with("RDB$") || rel.starts_with("SEC$") || rel.starts_with("MON$") {
            continue; // a system table's own constraints
        }
        let kind = text(r, type_at);
        let name = text(r, name_at);
        match kind.as_str() {
            "NOT NULL" => out.push(UCons {
                column: col_of
                    .iter()
                    .find(|(c, _)| c == &name)
                    .map(|(_, f)| f.clone())
                    .unwrap_or_default(),
                name,
                kind: UConsKind::NotNull,
                relation: rel,
                index: String::new(),
            }),
            "PRIMARY KEY" => out.push(UCons {
                name,
                kind: UConsKind::PrimaryKey,
                relation: rel,
                index: index_at.map(|i| text(r, i)).unwrap_or_default(),
                column: String::new(),
            }),
            other => {
                return Err(Refused(format!(
                    "a {} constraint is outside this backup's surface",
                    other
                )))
            }
        }
    }
    Ok(out)
}

/// The user indexes with their segments, key order preserved. An FK
/// index or an inactive one refuses - both are states this file format
/// slice cannot say.
fn read_indexes(image: &[u8], page_size: usize) -> Result<Vec<UIndex>, Refused> {
    let Some((cols, rows)) = sys_rows(image, page_size, "RDB$INDICES") else {
        return Ok(Vec::new());
    };
    let at = |n: &str| cols.iter().find(|(c, _)| c.eq_ignore_ascii_case(n)).map(|(_, i)| *i);
    let (Some(name_at), Some(rel_at)) = (at("RDB$INDEX_NAME"), at("RDB$RELATION_NAME")) else {
        return Ok(Vec::new());
    };
    let uniq_at = at("RDB$UNIQUE_FLAG");
    let type_at = at("RDB$INDEX_TYPE");
    let inactive_at = at("RDB$INDEX_INACTIVE");
    let fk_at = at("RDB$FOREIGN_KEY");
    let flag_at = at("RDB$SYSTEM_FLAG");
    let text = |r: &fire_crab_ods::tra::VisibleRow, i: usize| match r.values.get(i) {
        Some(fire_crab_ods::format::Value::Text(t)) => t.trim_end().to_string(),
        _ => String::new(),
    };
    let num = |r: &fire_crab_ods::tra::VisibleRow, i: Option<usize>| match i.and_then(|i| r.values.get(i)) {
        Some(fire_crab_ods::format::Value::Int(n)) => *n,
        _ => 0,
    };
    // segments: index name -> (position, field)
    let mut segs: Vec<(String, i64, String)> = Vec::new();
    if let Some((scols, srows)) = sys_rows(image, page_size, "RDB$INDEX_SEGMENTS") {
        let sat = |n: &str| scols.iter().find(|(c, _)| c.eq_ignore_ascii_case(n)).map(|(_, i)| *i);
        if let (Some(ix_at), Some(fld_at)) = (sat("RDB$INDEX_NAME"), sat("RDB$FIELD_NAME")) {
            let pos_at = sat("RDB$FIELD_POSITION");
            for r in &srows {
                segs.push((text(r, ix_at), num(r, pos_at), text(r, fld_at)));
            }
        }
    }
    let mut out = Vec::new();
    for r in &rows {
        let system = matches!(
            flag_at.and_then(|i| r.values.get(i)),
            Some(fire_crab_ods::format::Value::Int(n)) if *n != 0
        );
        let rel = text(r, rel_at);
        if system || rel.starts_with("RDB$") || rel.starts_with("SEC$") || rel.starts_with("MON$")
        {
            continue;
        }
        let name = text(r, name_at);
        if fk_at.is_some_and(|i| matches!(r.values.get(i), Some(fire_crab_ods::format::Value::Text(_))))
        {
            return Err(Refused(format!(
                "index {} backs a FOREIGN KEY - outside this backup's surface",
                name
            )));
        }
        if num(r, inactive_at) != 0 {
            return Err(Refused(format!(
                "index {} is inactive - a state this backup cannot say",
                name
            )));
        }
        let mut mine: Vec<(i64, String)> = segs
            .iter()
            .filter(|(ix, _, _)| ix == &name)
            .map(|(_, p, f)| (*p, f.clone()))
            .collect();
        mine.sort_by_key(|(p, _)| *p);
        out.push(UIndex {
            name,
            relation: rel,
            unique: num(r, uniq_at) != 0,
            itype: num(r, type_at) as i32,
            segments: mine.into_iter().map(|(_, f)| f).collect(),
        });
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
                field_id: 1,
                bitmap_bit: 0,
                source: "RDB$1".into(),
                position: 0,
                desc: Descriptor { dtype: dtype::LONG, scale: 0, length: 4, sub_type: 0, flags: 0, offset: 4 },
                not_null: false,
            },
            Col {
                name: "V".into(),
                field_id: 2,
                bitmap_bit: 1,
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
    /// a blob's SEGMENTS, filled by the rec_blob that follows the row -
    /// a non-null blob starts as an empty segment list (which is also
    /// what a non-null EMPTY blob legitimately stays). `stream` is the
    /// rec_blob's att 4 - the restored blob keeps its kind.
    Blob { stream: bool, segments: Vec<Vec<u8>> },
}

/// One restored column.
pub struct RCol {
    pub name: String,
    /// RDB$FIELD_TYPE: 7 smallint, 8 integer, 16 int64, 14 text,
    /// 37 varying, 261 blob
    pub field_type: i32,
    pub length: u16,
    pub scale: i8,
    /// for a blob, att 9 carries the SUB_TYPE where scale would sit
    pub sub_type: i16,
    /// att 13 - the TRUE column position: field records arrive
    /// blobs-first, so file order is not declaration order
    pub position: i32,
    /// att 22 - what a rec_blob's field number points at
    pub field_id: i32,
    pub not_null: bool,
}

/// One restored index.
pub struct RIndex {
    pub name: String,
    pub unique: bool,
    pub descending: bool,
    pub segments: Vec<String>,
}

/// One restored table.
pub struct RTable {
    pub name: String,
    pub cols: Vec<RCol>,
    pub rows: Vec<Vec<RVal>>,
    pub indexes: Vec<RIndex>,
    /// the index name the PRIMARY KEY constraint points at, if one does
    pub pk_index: Option<String>,
}

/// What a .fbk holds, as far as this slice carries it.
pub struct Restored {
    pub page_size: Option<u32>,
    /// att_backup_format from rec_burp - "backup version is N"
    pub format: Option<i64>,
    /// global-field (domain) names, in file order - what the engine's
    /// verbose restore lists as "restoring domain"
    pub domains: Vec<String>,
    /// indexes into `tables` in the order their DATA blocks appear -
    /// the engine writes them in reverse creation order, and its
    /// verbose restore narrates that order
    pub data_order: Vec<usize>,
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
            261 => {
                // the quad rides as two BE longs; its VALUE is the
                // source database's blob id, replaced wholesale on
                // restore - the rec_blob records that follow the row
                // carry the content
                let _ = take(&mut at, 8)?;
                vals.push(RVal::Blob { stream: false, segments: Vec::new() });
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
    let mut out = Restored {
        page_size: None,
        format: None,
        domains: Vec::new(),
        data_order: Vec::new(),
        tables: Vec::new(),
        privileges_skipped: 0,
    };
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
                out.format = att(&atts, 2).map(|a| a.int());
            }
            rec::PHYSICAL_DB => {
                let atts = read_atts(f, &mut at)?;
                out.page_size = att(&atts, 5).map(|a| a.int() as u32);
            }
            rec::DATABASE | rec::SCHEMA => {
                // the database attributes this slice carries are defaults
                let _ = read_atts(f, &mut at)?;
            }
            rec::GLOBAL_FIELD => {
                // the column types arrive re-derived from the field
                // records; the domain NAME is kept for the verbose
                // stream's "restoring domain" lines
                let atts = read_atts(f, &mut at)?;
                if let Some(a) = att(&atts, 1) {
                    out.domains.push(a.text());
                }
            }
            rec::RELATION => {
                let atts = read_atts(f, &mut at)?;
                let name = att(&atts, 1)
                    .map(|a| a.text())
                    .ok_or_else(|| Refused("a relation with no name".into()))?;
                out.tables.push(RTable {
                    name,
                    cols: Vec::new(),
                    rows: Vec::new(),
                    indexes: Vec::new(),
                    pk_index: None,
                });
                current_rel = Some(out.tables.len() - 1);
            }
            rec::FIELD => {
                let atts = read_atts(f, &mut at)?;
                let t = current_rel.ok_or_else(|| Refused("a field outside a relation".into()))?;
                let ftype = att(&atts, 8)
                    .map(|a| a.int() as i32)
                    .ok_or_else(|| Refused("a field with no type".into()))?;
                if !matches!(ftype, 7 | 8 | 16 | 14 | 37 | 261) {
                    return Err(Refused(format!(
                        "field type {} is outside this restore's surface",
                        ftype
                    )));
                }
                let n = out.tables[t].cols.len();
                out.tables[t].cols.push(RCol {
                    name: att(&atts, 1)
                        .map(|a| a.text())
                        .ok_or_else(|| Refused("a field with no name".into()))?,
                    field_type: ftype,
                    length: att(&atts, 10).map(|a| a.int() as u16).unwrap_or(0),
                    scale: if ftype == 261 {
                        0
                    } else {
                        att(&atts, 9).map(|a| a.int() as i8).unwrap_or(0)
                    },
                    sub_type: if ftype == 261 {
                        att(&atts, 9).map(|a| a.int() as i16).unwrap_or(0)
                    } else {
                        0
                    },
                    position: att(&atts, 13).map(|a| a.int() as i32).unwrap_or(n as i32),
                    field_id: att(&atts, 22).map(|a| a.int() as i32).unwrap_or((n + 1) as i32),
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
                match data_rel {
                    Some(i) => out.data_order.push(i),
                    None => {
                        return Err(Refused(format!("data for an unknown relation {}", name)))
                    }
                }
            }
            rec::INDEX => {
                let t = data_rel
                    .ok_or_else(|| Refused("an index outside relation data".into()))?;
                let atts = read_atts(f, &mut at)?;
                let segments: Vec<String> = atts
                    .iter()
                    .filter(|a| a.tag == 5)
                    .map(|a| a.text())
                    .collect();
                if segments.is_empty() {
                    return Err(Refused("an index with no segments".into()));
                }
                let itype = att(&atts, 7).map(|a| a.int()).unwrap_or(0);
                if !matches!(itype, 0 | 1) {
                    return Err(Refused("an expression index is outside this restore's surface".into()));
                }
                out.tables[t].indexes.push(RIndex {
                    name: att(&atts, 1)
                        .map(|a| a.text())
                        .ok_or_else(|| Refused("an index with no name".into()))?,
                    unique: att(&atts, 4).map(|a| a.int() == 1).unwrap_or(false),
                    descending: itype == 1,
                    segments,
                });
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
            rec::BLOB => {
                // attributes until the BARE att_blob_data tag (7), then
                // u16 LE length + bytes per segment - no att_end at all
                let t = data_rel.ok_or_else(|| Refused("a blob outside relation data".into()))?;
                let mut field_no: i64 = 0;
                let mut nseg: i64 = 0;
                let mut stream = false;
                loop {
                    let tag = *f.get(at).ok_or_else(|| Refused("truncated blob record".into()))?;
                    at += 1;
                    if tag == 7 {
                        break;
                    }
                    let len = *f.get(at).ok_or_else(|| Refused("truncated blob record".into()))? as usize;
                    at += 1;
                    let a = Att {
                        tag,
                        data: f
                            .get(at..at + len)
                            .ok_or_else(|| Refused("truncated blob record".into()))?
                            .to_vec(),
                    };
                    at += len;
                    match a.tag {
                        3 => field_no = a.int(),
                        5 => nseg = a.int(),
                        4 => stream = a.int() == 1,
                        _ => {}
                    }
                }
                let mut segments = Vec::with_capacity(nseg.max(0) as usize);
                for _ in 0..nseg {
                    let lb = f
                        .get(at..at + 2)
                        .ok_or_else(|| Refused("a blob ended mid-segment".into()))?;
                    let n = u16::from_le_bytes([lb[0], lb[1]]) as usize;
                    at += 2;
                    let d = f
                        .get(at..at + n)
                        .ok_or_else(|| Refused("a blob segment past the end".into()))?
                        .to_vec();
                    at += n;
                    segments.push(d);
                }
                // the blob belongs to the LAST row, at the column whose
                // field id the record names
                let table = &mut out.tables[t];
                let col = table
                    .cols
                    .iter()
                    .position(|c| c.field_id as i64 == field_no)
                    .ok_or_else(|| Refused("a blob for an unknown field".into()))?;
                let row = table
                    .rows
                    .last_mut()
                    .ok_or_else(|| Refused("a blob before any row".into()))?;
                match row.get_mut(col) {
                    Some(RVal::Blob { stream: st, segments: sg }) => {
                        *st = stream;
                        *sg = segments;
                    }
                    _ => return Err(Refused("a blob for a non-blob value".into())),
                }
            }
            rec::REL_CONSTRAINT => {
                let atts = read_atts(f, &mut at)?;
                let kind = att(&atts, 2).map(|a| a.text()).unwrap_or_default();
                let cname = att(&atts, 1).map(|a| a.text()).unwrap_or_default();
                let table = att(&atts, 3).map(|a| a.text()).unwrap_or_default();
                match kind.trim() {
                    "NOT NULL" => cons_table.push((cname, table)),
                    "PRIMARY KEY" => {
                        let index = att(&atts, 6).map(|a| a.text()).unwrap_or_default();
                        if let Some(t) = out.tables.iter_mut().find(|t| t.name == table) {
                            t.pk_index = Some(index);
                        }
                    }
                    other => {
                        // UNIQUE / FOREIGN KEY / CHECK are their own
                        // slices - dropping one silently changes what
                        // the schema means
                        return Err(Refused(format!(
                            "a {} constraint is outside this restore's surface",
                            other
                        )));
                    }
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

        // indexes and the PRIMARY KEY constraint ride the file: one
        // rec_index inside relation data, the PK rel_constraint naming
        // its index at the tail
        let mut f2 = Vec::new();
        Rec::new(&mut f2, rec::BURP).int(2, 12).int(4, 1).int(5, 1).end();
        Rec::new(&mut f2, rec::RELATION).text(21, "PUBLIC").text(1, "K").end();
        Rec::new(&mut f2, rec::FIELD).text(1, "ID").int(13, 0).int(8, 8).int(10, 4).int(9, 0).end();
        f2.push(rec::RELATION_END);
        Rec::new(&mut f2, rec::RELATION_DATA).text(21, "PUBLIC").text(1, "K").end();
        Rec::new(&mut f2, rec::INDEX)
            .text(1, "RDB$PRIMARY1")
            .int(2, 1)
            .int(3, 0)
            .int(4, 1)
            .text(5, "ID")
            .int(7, 0)
            .end();
        f2.push(rec::RELATION_END);
        Rec::new(&mut f2, rec::REL_CONSTRAINT)
            .text(7, "PUBLIC")
            .text(1, "INTEG_2")
            .text(2, "PRIMARY KEY")
            .text(3, "K")
            .text(4, "NO")
            .text(5, "NO")
            .text(6, "RDB$PRIMARY1")
            .end();
        f2.push(rec::END);
        let r2 = read_backup(&f2).unwrap();
        assert_eq!(r2.tables[0].indexes.len(), 1);
        assert!(r2.tables[0].indexes[0].unique);
        assert_eq!(r2.tables[0].indexes[0].segments, vec!["ID".to_string()]);
        assert_eq!(r2.tables[0].pk_index.as_deref(), Some("RDB$PRIMARY1"));

        // an unknown RECORD refuses whole - mis-stepping the walk would
        // turn everything after into nonsense
        let mut bad = f.clone();
        let end = bad.len() - 1;
        bad[end] = 13; // rec_trigger where rec_end was
        assert!(read_backup(&bad).is_err());
    }
}
