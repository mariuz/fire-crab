//! DDL write path: CREATE TABLE, converted from the engine's own
//! sequence - `RelationNode` DDL (DdlNodes.epp `make_version`,
//! :8570-9000) storing the catalog rows, `makeFormat` (:9455) laying
//! the physical format and storing `RDB$FORMATS` with the packed
//! descriptor blob, the `RDB$RUNTIME` field-summary blob
//! (`putSummaryRecord`, :9292 - `[tag][payload]` per segment), and
//! `DPM_create_relation` (dpm.epp:588) allocating the pointer and
//! index-root pages and registering both in `RDB$PAGES`.
//!
//! Everything here was pinned by a differential probe first: two
//! engine-created databases differing by exactly one CREATE TABLE,
//! their catalog rows, blob bytes and page structures diffed. Facts
//! that came out of that probe rather than assumption:
//!   - field ids are assigned in DECLARATION order for a fresh table
//!     (ID=0, NAME=1, ... - not alphabetical, not by alignment);
//!   - the descriptor blob is `[u16 count][count x 12-byte packed
//!     Ods::Descriptor][u16 0 defaults]` in ONE segment;
//!   - the runtime blob is, per field: RSR_field_id(0) u16,
//!     RSR_field_name(1), RSR_field_source(25) as the QUOTED
//!     `"PUBLIC"."RDB$n"`, RSR_field_length(19) u16,
//!     RSR_character_length(26) u16 (text only), RSR_field_pos(27)
//!     u16 - nothing else for a plain nullable column;
//!   - blh_charset is 1 for both metadata blobs, blh_length counts
//!     segment payloads only;
//!   - auto-domains are `RDB$<n>`; the engine's own
//!     `DYN_UTIL_generate_field_name` loops until unused, so naming
//!     ours max+1 cannot break later engine-side DDL;
//!   - the security-class/owner columns can stay NULL: SYSDBA access
//!     does not consult them (asserted by the gate - the engine both
//!     reads and writes the table).
//!
//! System-catalog INDEXES are maintained on every row this module
//! inserts (the engine resolves metadata through them - a missing
//! entry makes the table invisible to its lookups, and `gfix -v`
//! reports it): segments read from the irtd arrays, keys built by
//! [crate::btw::build_index_key] - `idx_metadata` text and numeric
//! segments, unique enforcement included (a duplicate table name
//! refuses on the RDB$RELATIONS unique index exactly like a duplicate
//! key anywhere else).

use crate::btr::find_index_root;
use crate::btw;
use crate::catalog::{list_relations, relation_columns};
use crate::data::{DataPage, DPG_RPT_OFFSET, RHD_DATA_OFFSET};
use crate::dml;
use crate::format::{decode_record, flag_bytes, max_recs_per_dp, Value};
use crate::gen;
use crate::pointer::relation_data_pages;
use crate::sysfmt::{compute_format, compute_format_mixed, system_relation_formats};
use crate::{u16_at, u32_at, Descriptor};

/// Whether a type's `RDB$FIELD_SUB_TYPE` is written at all: the engine
/// stores one (0 or the declared NUMERIC/DECIMAL code) only for the
/// exact-int family and text; FLOAT/DOUBLE/DATE/TIME/TIMESTAMP/BOOLEAN
/// rows keep it NULL (probed).
fn subtype_carried(field_type: i16) -> bool {
    // 261 = blob, whose sub_type is the whole point of the column
    matches!(field_type, 7 | 8 | 16 | 26 | 14 | 37 | 261)
}

/// One column of a CREATE TABLE: its name, the external catalog type
/// code (`RDB$FIELD_TYPE`), and the storage descriptor pieces.
#[derive(Clone)]
pub struct ColumnDef {
    pub name: String,
    /// RDB$FIELD_TYPE: 7 smallint, 8 integer, 16 int64, 14 text,
    /// 37 varying, 12 date, 13 time, 35 timestamp, 23 boolean,
    /// 27 double, 10 float
    pub field_type: i16,
    /// dsc dtype (dsc.h codes - what the descriptor blob carries)
    pub dtype: u8,
    /// stored length (dsc_length: VARCHAR includes the count word)
    pub length: u16,
    pub scale: i8,
    /// RDB$FIELD_SUB_TYPE (1/2 for NUMERIC/DECIMAL, else 0)
    pub sub_type: i16,
    /// RDB$FIELD_PRECISION as the engine writes it for a declared column
    /// (probed, incl domains and ALTER ADD): `Some(0)` for the plain
    /// exact-int family (SMALLINT/INTEGER/BIGINT/INT128), the declared
    /// `p` for NUMERIC/DECIMAL(p,s), `None` (SQL NULL) for every other
    /// type. A computed column ignores this - its result precision
    /// travels in [ComputedCol::precision].
    pub precision: Option<i16>,
    /// character length, for CHAR/VARCHAR (charset NONE: == bytes)
    pub char_len: Option<u16>,
    /// an ARRAY column's dimensions, `(lower, upper)` each, in
    /// declaration order (`INTEGER [1:5, 0:2]`); empty for a scalar. The
    /// type fields above describe the ELEMENT (RDB$FIELD_TYPE / LENGTH /
    /// SCALE are the element's, RDB$DIMENSIONS the count, the bounds in
    /// RDB$FIELD_DIMENSIONS - probed); the record stores an 8-byte array
    /// blob id, dsc dtype_array.
    pub dims: Vec<(i32, i32)>,
    /// a BLOB column's `SEGMENT SIZE` (RDB$SEGMENT_LENGTH; the engine's
    /// default is 80); None for every other type
    pub segment_length: Option<u16>,
    /// a text BLOB's `CHARACTER SET` id (RDB$CHARACTER_SET_ID; also the
    /// format descriptor's scale, which is how a blob describes it)
    pub charset_id: Option<u8>,
    /// NOT NULL - explicit, or implied by PRIMARY KEY membership
    pub not_null: bool,
    /// whether this column's NOT NULL is a COLUMN-level declaration
    /// (`... NOT NULL` or a column-level `PRIMARY KEY`). The engine
    /// writes an `INTEG_<n>` "NOT NULL" constraint row only for those;
    /// a TABLE-level `PRIMARY KEY (a, b)` sets its columns' NULL_FLAG
    /// but writes no constraint row (probed: table P vs table Q).
    pub not_null_constraint: bool,
    /// WHERE this column's NOT NULL clause is written INSIDE the
    /// column's own declaration text - the byte offset of the clause in
    /// that item. It is what orders the row against the column's other
    /// inline constraints, which are numbered in plain text order
    /// (probed: `A INTEGER UNIQUE NOT NULL` numbers UNIQUE first,
    /// `A INTEGER NOT NULL UNIQUE` numbers NOT NULL first).
    ///
    /// A column-level `PRIMARY KEY` IMPLIES a NOT NULL, and the implied
    /// row stands at the PRIMARY KEY's own place - so when both are
    /// written the offset is the EARLIER of the two (probed: `A INTEGER
    /// PRIMARY KEY NOT NULL` is NOT NULL then PRIMARY KEY, though the
    /// text reads the other way round).
    ///
    /// Meaningless when [ColumnDef::not_null_constraint] is false, and 0
    /// when the caller does not know (nothing else on the column is
    /// inline, so nothing can be ordered against it).
    pub not_null_at: usize,
    /// a column `DEFAULT <literal>`, if any: the source text
    /// (`DEFAULT 0`) and its value BLR
    pub default: Option<ColumnDefault>,
    /// when the column's type is a user domain (`X DOM_I`), the domain's
    /// name; the type fields above are placeholders, resolved from the
    /// domain's `RDB$FIELDS` row at [create_table]. `None` for a built-in type.
    pub domain: Option<String>,
    /// a `GENERATED ... AS IDENTITY` clause: an implicit generator backs the
    /// column and its next value fills it. `None` for an ordinary column.
    pub identity: Option<IdentityDef>,
    /// a `COMPUTED BY (<expr>)` column: the expression, compiled. The
    /// ColumnDef's type fields carry the expression's RESULT type - inferred
    /// by the caller from the engine's dialect-3 rules, not declared.
    pub computed: Option<ComputedCol>,
}

/// The pieces of a `COMPUTED BY (<expr>)` column the catalog stores: the
/// verbatim parenthesised source text (`RDB$COMPUTED_SOURCE`), the
/// compiled expression BLR (`RDB$COMPUTED_BLR`), and the result type's
/// `RDB$FIELD_PRECISION` (the engine writes it for a computed field where
/// a plain declared column gets 0/NULL: SHORT 4, LONG 9, INT64 18).
#[derive(Clone)]
pub struct ComputedCol {
    pub source: String,
    pub blr: Vec<u8>,
    pub precision: i16,
}

/// A column's `GENERATED {ALWAYS | BY DEFAULT} AS IDENTITY
/// [(START WITH <n> [INCREMENT [BY] <n>])]`.
#[derive(Clone)]
pub struct IdentityDef {
    /// `RDB$IDENTITY_TYPE`: 0 = GENERATED ALWAYS, 1 = GENERATED BY DEFAULT
    pub identity_type: i16,
    pub start: i64,
    pub increment: i64,
}

/// A column (or domain) `DEFAULT <literal>`: the `RDB$DEFAULT_SOURCE` text
/// and the `RDB$DEFAULT_VALUE` BLR.
#[derive(Clone)]
pub struct ColumnDefault {
    pub source: String,
    pub value_blr: Vec<u8>,
}

/// The BLR of an integer-literal default - `blr_version5, blr_literal,
/// blr_long, scale 0, the 4-byte value, blr_eoc`. The engine writes a
/// literal as `blr_long` regardless of the column width (probe: a SMALLINT
/// and a BIGINT default both carry a 4-byte `blr_long` value).
pub fn int_default_blr(value: i32) -> Vec<u8> {
    num_default_blr(value, 0)
}

/// The BLR of a NUMERIC-literal default at a SCALE - the same
/// `blr_literal blr_long` shape, with the literal's own scale in the
/// scale byte (which is SIGNED: a fraction is negative). A decimal
/// default is a scaled integer to the engine, not a separate kind.
/// Measured on Firebird 6 at `127.0.0.1/3050`, 2026-09-03, by reading
/// `RDB$DEFAULT_VALUE` back as hex:
///
/// ```text
/// NUMERIC(9,2)     DEFAULT 7.00          05 15 08 FE BC020000 4C   (700, -2)
/// NUMERIC(9,2)     DEFAULT 7.0           05 15 08 FF 46000000 4C   (70,  -1)
/// NUMERIC(9,2)     DEFAULT 7             05 15 08 00 07000000 4C   (7,    0)
/// NUMERIC(9,2)     DEFAULT -7.25         05 15 08 FE 2BFDFFFF 4C   (-725,-2)
/// NUMERIC(18,2)    DEFAULT 1.5           05 15 08 FF 0F000000 4C   (15,  -1)
/// INTEGER          DEFAULT 7.0           05 15 08 FF 46000000 4C   (70,  -1)
/// DOUBLE PRECISION DEFAULT 7.5           05 15 08 FF 4B000000 4C   (75,  -1)
/// NUMERIC(9,4)     DEFAULT 123456.7890   05 15 08 FC D2029649 4C   (1234567890, -4)
/// ```
///
/// The scale is the LITERAL's, not the column's - `DEFAULT 7.0` on a
/// `NUMERIC(9,2)` column stores `(70, -1)`, and the column's own scale
/// is applied when the default is bound. A mantissa that does not fit
/// `blr_long` is a WIDER literal the engine writes as `blr_int64`
/// instead; this emitter does not write that form and its callers
/// decline such a literal, which is the refusal they already gave.
pub fn num_default_blr(value: i32, scale: i8) -> Vec<u8> {
    let mut b = vec![5u8, 21, 8, scale as u8]; // version5, blr_literal, blr_long, scale
    b.extend_from_slice(&value.to_le_bytes());
    b.push(76); // blr_eoc
    b
}

/// The BLR of a string-literal default - `blr_version5, blr_literal,
/// blr_text2, charset 0, the 2-byte length, the bytes, blr_eoc`. The
/// literal carries its own length, not the column's (no padding).
pub fn str_default_blr(text: &str) -> Vec<u8> {
    let mut b = vec![5u8, 21, 15, 0, 0]; // version5, literal, blr_text2, charset(2 bytes)
    b.extend_from_slice(&(text.len() as u16).to_le_bytes());
    b.extend_from_slice(text.as_bytes());
    b.push(76); // blr_eoc
    b
}

/// The BLR of a `DEFAULT <context-value-keyword>` - each a fixed byte
/// sequence (probed): the date/time/user values are one opcode
/// (`blr_version5, <op>, blr_eoc`); LOCALTIME/LOCALTIMESTAMP carry a
/// default-precision byte; CURRENT_CONNECTION/TRANSACTION are
/// `blr_internal_info` (177) with an info-code literal. None for anything a
/// full expression compiler would be needed for.
pub fn keyword_default_blr(keyword: &str) -> Option<Vec<u8>> {
    Some(match keyword.trim().to_ascii_uppercase().as_str() {
        "CURRENT_DATE" => vec![5, 160, 76],
        "CURRENT_TIMESTAMP" => vec![5, 161, 76],
        "CURRENT_TIME" => vec![5, 162, 76],
        "CURRENT_USER" | "USER" => vec![5, 44, 76], // blr_user_name
        "CURRENT_ROLE" => vec![5, 174, 76],
        "LOCALTIMESTAMP" => vec![5, 214, 3, 76], // default precision 3
        "LOCALTIME" => vec![5, 215, 0, 76],      // default precision 0
        // blr_internal_info, blr_literal blr_long <info-code>, blr_eoc
        "CURRENT_CONNECTION" => vec![5, 177, 21, 8, 0, 1, 0, 0, 0, 76],
        "CURRENT_TRANSACTION" => vec![5, 177, 21, 8, 0, 2, 0, 0, 0, 76],
        _ => return None,
    })
}

/// The BLR of a `DEFAULT NULL` - `blr_version5, blr_null, blr_eoc`. The
/// engine stores this explicitly (source `DEFAULT NULL`), distinct from a
/// column with no default at all (which has neither source nor value); the
/// applied result is the same NULL, but the catalog records the intent.
pub fn null_default_blr() -> Vec<u8> {
    vec![5u8, 45, 76] // version5, blr_null, blr_eoc
}

/// One table-level key constraint of a CREATE TABLE: a `PRIMARY KEY` or
/// a `UNIQUE`, named or not. Both are backed by a unique index; the
/// engine names that index after the constraint when the constraint is
/// named, and generates `RDB$PRIMARY<n>` / `RDB$<n>` when it is not.
#[derive(Clone)]
pub struct KeyDef {
    /// constraint name, empty when the statement did not name it
    pub name: String,
    /// key columns, in key order
    pub columns: Vec<String>,
    /// PRIMARY KEY (true) or UNIQUE (false)
    pub primary: bool,
}

/// One `[CONSTRAINT <name>] CHECK (<condition>)` of a CREATE TABLE: the
/// verbatim source text from the CHECK keyword on (`RDB$TRIGGER_SOURCE`),
/// the compiled trigger BLR (the NEGATED condition inside the
/// if-failed-raise wrapper - [crate::expr::check_trigger_blr]), and the
/// fields the condition references, first-seen order (the trigger's
/// `RDB$DEPENDENCIES` rows).
#[derive(Clone)]
pub struct CheckDef {
    /// constraint name, empty when the statement did not name it
    pub name: String,
    pub source: String,
    pub trigger_blr: Vec<u8>,
    pub fields: Vec<String>,
}

/// A constraint of a CREATE TABLE other than a column's NOT NULL: a
/// PRIMARY KEY / UNIQUE key or a CHECK, written either INLINE on a
/// column or as a clause standing on its own in the column list.
/// [TableConstraint::place] says which, and that is what orders the
/// generated `INTEG_<n>` names.
#[derive(Clone)]
pub struct TableConstraint {
    pub kind: ConstraintKind,
    /// WHERE the statement writes this constraint - the whole input to
    /// the two-pass numbering law in [constraint_steps].
    pub place: ConstraintPlace,
}

/// WHERE a constraint stands in a CREATE TABLE's column list. The
/// engine draws the generated `INTEG_<n>` names in TWO PASSES: every
/// COLUMN-LEVEL (inline) constraint first, and only then every
/// TABLE-LEVEL clause - so this is not one linear position but a pass
/// plus a position inside it.
///
/// Measured on the engine: `(A INTEGER, UNIQUE (A), B INTEGER UNIQUE)`
/// numbers `B`'s inline UNIQUE BEFORE the table-level `UNIQUE (A)`
/// written ahead of it in the text. No single-pass text order can
/// produce that, and a single `cols_before` count - which is what this
/// used to be - could express neither the pass nor the position of one
/// clause INSIDE a column's own text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConstraintPlace {
    /// Written INLINE as part of column `col`'s definition, at byte
    /// offset `at` within that column's own declaration text (the same
    /// scale as [ColumnDef::not_null_at], so the two compare).
    Inline { col: usize, at: usize },
    /// A clause standing on its own in the column list, `decl` being
    /// its position in that list. Ordered among themselves by `decl`,
    /// and ALL of them after every Inline one.
    ///
    /// The rank is carried EXPLICITLY rather than left to the vector's
    /// own order because a CREATE TABLE's constraints travel in TWO
    /// vectors - the keys/CHECKs and the foreign keys - and vector
    /// order can only say where a clause stands among its OWN kind.
    /// `G1 (A INTEGER, B INTEGER, FOREIGN KEY (A) REFERENCES P,
    /// UNIQUE (B))` is numbered FOREIGN KEY then UNIQUE by the engine,
    /// and nothing but a shared rank puts them back in that order.
    Table { decl: usize },
}

/// What a [TableConstraint] is: a key (PRIMARY KEY / UNIQUE) or a CHECK.
#[derive(Clone)]
pub enum ConstraintKind {
    Key(KeyDef),
    Check(CheckDef),
}

/// Values a system-catalog row is built from, keyed by column name.
pub(crate) enum SysVal<'a> {
    I(i64),
    S(&'a str),
    /// a DOUBLE PRECISION catalog column (index selectivity)
    F(f64),
    /// the 8 on-disk blob-id bytes
    B([u8; 8]),
    /// a binary CHAR (CHARACTER SET OCTETS) column - the bytes verbatim,
    /// zero-padded (not space-padded) to the column length. `RDB$ROLES`'s
    /// `RDB$SYSTEM_PRIVILEGES` is a CHAR(8) OCTETS of eight zero bytes.
    O(&'a [u8]),
    /// set the column's NULL bit (an in-place patch only - `sys_insert`
    /// starts every field NULL already)
    Null,
}

/// The 8 wire/disk bytes of a blob id (RecordNumber.h:63-71) - also in
/// the server's `encode_blob_id`; duplicated here because the id goes
/// INTO catalog record images.
fn blob_id_bytes(rel: u16, num: u64) -> [u8; 8] {
    let mut b = [0u8; 8];
    b[0..2].copy_from_slice(&rel.to_le_bytes());
    b[3] = (num >> 32) as u8;
    b[4..8].copy_from_slice(&(num as u32).to_le_bytes());
    b
}

/// Walk every committed-looking primary record of a system relation,
/// decoded with `descs`.
fn walk_rows(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    descs: &[Descriptor],
    mut cb: impl FnMut(&[Value]),
) {
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            cb(&decode_record(&image, descs));
        }
    }
}

/// The shape of a new system-relation row: format number 0 - every
/// engine-written system record carries it (probe: rels 0/2/5/6/8,
/// 900+ records, all format 0) - and the computed format's walk-end
/// length (`fmt_length`; rel 8's probe image was exactly it).
fn system_row_shape(descs: &[Descriptor]) -> (u8, usize) {
    let end = descs
        .iter()
        .map(|d| d.offset as usize + d.length as usize)
        .max()
        .unwrap_or(0);
    (0, end)
}

/// Encode one value at a catalog column's descriptor. Only the types
/// the system catalog actually stores in the rows we write.
fn encode_sys_value(d: &Descriptor, v: &SysVal<'_>) -> Result<Vec<u8>, String> {
    use crate::format::dtype;
    Ok(match (v, d.dtype) {
        (SysVal::I(n), dtype::SHORT) => (i16::try_from(*n).map_err(|_| "short range")?)
            .to_le_bytes()
            .to_vec(),
        (SysVal::I(n), dtype::LONG) => (i32::try_from(*n).map_err(|_| "long range")?)
            .to_le_bytes()
            .to_vec(),
        (SysVal::I(n), dtype::INT64) => n.to_le_bytes().to_vec(),
        (SysVal::S(s), dtype::TEXT) => {
            let b = s.as_bytes();
            if b.len() > d.length as usize {
                return Err("text too long for catalog column".into());
            }
            let mut out = b.to_vec();
            out.resize(d.length as usize, b' ');
            out
        }
        (SysVal::S(s), dtype::VARYING) => {
            let b = s.as_bytes();
            if b.len() + 2 > d.length as usize {
                return Err("varchar too long for catalog column".into());
            }
            let mut out = (b.len() as u16).to_le_bytes().to_vec();
            out.extend_from_slice(b);
            out
        }
        (SysVal::F(v), dtype::DOUBLE) => v.to_le_bytes().to_vec(),
        (SysVal::B(id), dtype::BLOB) => id.to_vec(),
        (SysVal::O(b), dtype::TEXT) => {
            if b.len() > d.length as usize {
                return Err("octets too long for catalog column".into());
            }
            let mut out = b.to_vec();
            out.resize(d.length as usize, 0); // OCTETS pad byte is 0, not space
            out
        }
        (SysVal::Null, _) => return Err("SysVal::Null has no encoding".into()),
        _ => return Err("catalog value/type mismatch".into()),
    })
}

/// Insert one row into a system relation - image built at the
/// relation's computed (ini.epp-walk) format, EVERY index of the
/// relation maintained. This is what makes the row real to the
/// engine: its metadata lookups go through these indexes.
pub(crate) fn sys_insert(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    values: &[(&str, SysVal<'_>)],
) -> Result<(), String> {
    let formats =
        system_relation_formats(file, page_size, rel_name).ok_or("no computed system format")?;
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("empty system format")?;
    let columns = relation_columns(file, page_size, rel_name);
    let (format_no, image_len) = system_row_shape(descs);

    let mut image = vec![0u8; image_len];
    for i in 0..descs.len() {
        image[i / 8] |= 1 << (i % 8); // start all-NULL
    }
    let mut key_values: Vec<Value> = vec![Value::Null; descs.len()];
    for (name, v) in values {
        let rc = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(name))
            .ok_or_else(|| format!("unknown catalog column {}", name))?;
        let fid = rc.field_id as usize;
        let d = descs.get(fid).ok_or("field beyond computed format")?;
        let bytes = encode_sys_value(d, v)?;
        let at = d.offset as usize;
        if at + bytes.len() > image.len() {
            return Err("catalog image shorter than its format".into());
        }
        image[at..at + bytes.len()].copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        key_values[fid] = match v {
            SysVal::I(n) => Value::Int(*n),
            SysVal::S(s) => Value::Text((*s).to_string()),
            // no catalog index covers a blob, a selectivity or a NULL
            SysVal::B(_) | SysVal::F(_) | SysVal::O(_) | SysVal::Null => Value::Null,
        };
    }

    // RDB$PAGES rows must be system-transaction (tx 0) records - the
    // engine's get_header refuses anything else with isc_wrong_page
    let out = if rel == 0 {
        let out = dml::insert_record_system(file, page_size, rel, format_no, &image)?;
        if file.ddl_tx.is_some() {
            // a tx-0 row no state can take back: the rollback's residue
            file.ddl_residue.push(crate::DdlResidue::SysPagesRow { page: out.page_no, slot: out.slot });
        }
        out
    } else {
        dml::insert_record(file, page_size, rel, format_no, &image)?
    };
    let seq = u32_at(
        crate::page_at(file, page_size, out.page_no).ok_or("data page out of range")?,
        16,
    ) as u64;
    let recno = seq * max_recs_per_dp(page_size) + out.slot as u64;

    maintain_indexes(file, page_size, rel, recno, &key_values, descs)
}

/// The values of ONE record of a relation by record number, as the
/// catalog walk sees it: the visible version, decoded at `descs`.
/// `None` when that slot holds no live row (a deleted stub, a back
/// version, a page that is not there) - which is how a caller tells "I
/// could not read it" from "it is not a row".
fn row_values_at(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    recno: u64,
    descs: &[Descriptor],
) -> Option<Vec<Value>> {
    let recs = max_recs_per_dp(page_size);
    if recs == 0 {
        return None;
    }
    let (seq, slot) = ((recno / recs) as u32, (recno % recs) as u16);
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        if dp.sequence != seq {
            continue;
        }
        let r = dp.record(slot)?;
        let image = crate::data::catalog_image(file, page_size, &r, tips.as_ref())?;
        return Some(decode_record(&image, descs));
    }
    None
}

/// Key one record into every index of its relation - what the engine
/// does on any write that changes an INDEXED value. Insertion is the
/// obvious caller; the other is an in-place row rewrite that changes a
/// key column (renaming an index in RDB$INDICES, say), where the old
/// entry stays behind for garbage collection but the NEW key needs an
/// entry of its own: `gfix` reports "Index n is corrupt {missing
/// entries for record m}" otherwise.
fn maintain_indexes(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    recno: u64,
    key_values: &[Value],
    descs: &[Descriptor],
) -> Result<(), String> {
    let Some(irt) = find_index_root(file, page_size, rel) else {
        return Ok(());
    };
    let entries: Vec<_> = irt.live_entries().map(|e| (e.id, e.key_count)).collect();
    for (id, key_count) in entries {
        let (segs, iflags) = btw::index_segments(file, page_size, rel, id, key_count as usize)
            .ok_or("unreadable system index segments")?;
        let null = Value::Null;
        let key_segs: Vec<btw::KeySeg<'_>> = segs
            .iter()
            .map(|(field, itype)| btw::KeySeg {
                itype: *itype,
                value: key_values.get(*field as usize).unwrap_or(&null),
                scale: descs.get(*field as usize).map_or(0, |d| d.scale),
                // system-catalog text is UTF8/metadata - no codepage
                charset: 0,
            })
            .collect();
        let (key, all_null) = btw::build_index_key(&key_segs, iflags & btw::IRT_DESCENDING != 0)
            .ok_or("unsupported system index key")?;
        // A CONFLICTING ENTRY COUNTS ONLY IF ITS RECORD STILL BUILDS
        // THAT KEY. Entries outlive the versions that wrote them, so a
        // renamed catalog row (`DROP INDEX X` renames its RDB$INDICES
        // row to RDB$TEMP_DEPEND_<rel>_<n>) leaves an entry under the
        // OLD name pointing at a row that is still live under the new
        // one - and `CREATE INDEX X` after it collided with that ghost
        // for ever. The key is rebuilt HERE, by the code that builds
        // the one being inserted, so a genuine duplicate still refuses;
        // a record this cannot read answers "still keyed", the
        // conservative half.
        let still_keys = |img: &crate::Image, other: u64| -> bool {
            let Some(vals) = row_values_at(img, page_size, rel, other, descs) else {
                return true;
            };
            let other_segs: Vec<btw::KeySeg<'_>> = segs
                .iter()
                .map(|(field, itype)| btw::KeySeg {
                    itype: *itype,
                    value: vals.get(*field as usize).unwrap_or(&null),
                    scale: descs.get(*field as usize).map_or(0, |d| d.scale),
                    charset: 0,
                })
                .collect();
            match btw::build_index_key(&other_segs, iflags & btw::IRT_DESCENDING != 0) {
                Some((other_key, _)) => other_key == key,
                None => true,
            }
        };
        btw::insert_index_entry_checked(
            file,
            page_size,
            rel,
            id,
            &key,
            recno,
            iflags & btw::IRT_UNIQUE != 0 && !all_null,
            iflags & btw::IRT_DESCENDING != 0,
            &still_keys,
        )?;
    }
    Ok(())
}

/// The first of `count` consecutive `RDB$<n>` auto-domain numbers, from
/// the engine's own counter for them - the system generator
/// `RDB$FIELD_NAME` (`DYN_UTIL_generate_field_name`). See
/// [draw_from_counter] for why the highest name in use is the wrong
/// answer.
fn next_domain_numbers(
    file: &mut crate::Image,
    page_size: usize,
    count: u64,
) -> Result<u64, String> {
    let used = used_numeric_suffixes(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME", &["RDB$"])?;
    let fallback = used.iter().copied().max().unwrap_or(0) + 1;
    draw_from_counter(file, page_size, "RDB$FIELD_NAME", false, 1, count, &used, fallback)
}

/// One auto-domain number - [next_domain_numbers] for a single column.
fn next_domain_number(file: &mut crate::Image, page_size: usize) -> Result<u64, String> {
    next_domain_numbers(file, page_size, 1)
}

/// Write a format descriptor blob (makeFormat): one segment of
/// `[u16 count][count x 12B packed descriptors][u16 0 defaults]`. Stored
/// in `RDB$FORMATS.RDB$DESCRIPTOR`; the engine reads it to lay out records
/// of that format version.
fn write_format_blob(
    file: &mut crate::Image,
    page_size: usize,
    descs: &[Descriptor],
) -> Result<u64, String> {
    let mut fmt_payload = Vec::with_capacity(2 + descs.len() * 12 + 2);
    fmt_payload.extend_from_slice(&(descs.len() as u16).to_le_bytes());
    for d in descs {
        fmt_payload.push(d.dtype);
        fmt_payload.push(d.scale as u8);
        fmt_payload.extend_from_slice(&d.length.to_le_bytes());
        fmt_payload.extend_from_slice(&(d.sub_type as u16).to_le_bytes());
        fmt_payload.extend_from_slice(&d.flags.to_le_bytes());
        fmt_payload.extend_from_slice(&d.offset.to_le_bytes());
    }
    fmt_payload.extend_from_slice(&0u16.to_le_bytes());
    dml::insert_blob(file, page_size, 8, &[fmt_payload], 6)
}

/// Turn a relation's current descriptors back into the `(dtype, length,
/// scale, sub_type)` tuples `compute_format` consumes. `compute_format`
/// re-adds the VARYING count word, so it is stripped here first - without
/// which each ALTER would inflate every VARYING column by two more bytes.
fn descs_to_fields(descs: &[Descriptor]) -> Vec<(u8, u16, i8, i16)> {
    descs
        .iter()
        .map(|d| {
            let gfld = if d.dtype == crate::format::dtype::VARYING {
                d.length.saturating_sub(2)
            } else {
                d.length
            };
            (d.dtype, gfld, d.scale, d.sub_type)
        })
        .collect()
}

/// The `compute_format` input tuple for a *declared* column. A ColumnDef's
/// `length` for VARYING already carries the 2-byte count word (VARCHAR(n) =>
/// n+2), but `compute_format` re-adds it, so strip it here - the mirror of
/// `descs_to_fields`. Without this the descriptor double-counts the count word
/// (VARCHAR(6) => dsc_length 10 where the engine writes 8).
fn col_field(dtype: u8, length: u16, scale: i8, sub_type: i16) -> (u8, u16, i8, i16) {
    let gfld = if dtype == crate::format::dtype::VARYING {
        length.saturating_sub(2)
    } else {
        length
    };
    (dtype, gfld, scale, sub_type)
}

/// [col_field] for a column definition: an ARRAY column's storage is the
/// 8-byte array blob id (dtype_array), whatever its element type
fn col_field_of(c: &ColumnDef) -> (u8, u16, i8, i16) {
    if c.dtype == crate::format::dtype::BLOB && c.dims.is_empty() {
        // a blob's descriptor carries its sub_type, and its CHARACTER SET
        // where a scale would be (dsc_blob_charset = dsc_scale; probed:
        // a UTF8 text blob describes sqlscale 4)
        (c.dtype, 8, c.charset_id.unwrap_or(0) as i8, c.sub_type)
    } else if c.dims.is_empty() {
        col_field(c.dtype, c.length, c.scale, c.sub_type)
    } else {
        (crate::format::dtype::ARRAY, 8, 0, 0)
    }
}

/// An ARRAY column's shape as the engine keeps it (RDB$FIELDS +
/// RDB$FIELD_DIMENSIONS): the element's (dtype, length, scale, sub_type)
/// and the bounds per dimension - what `Ods::InternalArrayDesc` is built
/// from (DdlNodes.epp getArrayDesc).
#[derive(Clone, Debug, PartialEq)]
pub struct ArrayShape {
    pub dtype: u8,
    pub length: u16,
    pub scale: i8,
    pub sub_type: i16,
    pub dims: Vec<(i32, i32)>,
}

/// An `Ods::InternalArrayDesc` (ods.h:1044, 16 + 24 per dimension) for a
/// shape - what the engine stores ahead of an array's elements and
/// carries in the runtime summary. The last dimension varies fastest
/// (stride 1).
pub fn array_desc_bytes(sh: &ArrayShape) -> Vec<u8> {
    // `sh.length` is already the slot ([array_shape] adds the length
    // word for a VARYING) - adding it again here made 19-byte elements
    // the engine read as blanks (measured: 40 + 95 against its 40 + 85)
    let elem_len: u16 = sh.length;
    let mut dims: Vec<(u32, i32, i32)> = sh.dims.iter().map(|&(lo, hi)| (0u32, lo, hi)).collect();
    let mut count: u32 = 1;
    for d in dims.iter_mut().rev() {
        d.0 = count;
        count *= (d.2 - d.1 + 1).max(0) as u32;
    }
    let header_len = 16 + 24 * dims.len().max(1);
    let mut h = Vec::with_capacity(header_len);
    h.push(1); // iad_version
    h.push(dims.len() as u8); // iad_dimensions
    h.extend_from_slice(&1u16.to_le_bytes()); // iad_struct_count
    h.extend_from_slice(&elem_len.to_le_bytes()); // iad_element_length
    h.extend_from_slice(&(header_len as u16).to_le_bytes()); // iad_length
    h.extend_from_slice(&count.to_le_bytes()); // iad_count
    h.extend_from_slice(&(count * u32::from(elem_len)).to_le_bytes()); // iad_total_length
    for (i, (stride, lo, hi)) in dims.iter().enumerate() {
        if i == 0 {
            // iad_desc: the element descriptor, in the first repeat only
            h.push(sh.dtype);
            h.push(sh.scale as u8);
            h.extend_from_slice(&elem_len.to_le_bytes());
            h.extend_from_slice(&sh.sub_type.to_le_bytes());
            h.extend_from_slice(&0u16.to_le_bytes()); // dsc_flags
            h.extend_from_slice(&0u32.to_le_bytes()); // dsc_address
        } else {
            h.extend_from_slice(&[0u8; 12]);
        }
        h.extend_from_slice(&stride.to_le_bytes()); // iad_length: the stride
        h.extend_from_slice(&lo.to_le_bytes());
        h.extend_from_slice(&hi.to_le_bytes());
    }
    h
}

/// The shape of `relation`.`field`, or None when it is not an array
/// column (or unknown)
pub fn array_shape(file: &crate::Image, page_size: usize, relation: &str, field: &str) -> Option<ArrayShape> {
    let text = |v: Option<&Value>| -> Option<String> {
        match v {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        }
    };
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n)?;
    let rfcols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rff = |n: &str| rfcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rel_f, fld_f, src_f) = (rff("RDB$RELATION_NAME")?, rff("RDB$FIELD_NAME")?, rff("RDB$FIELD_SOURCE")?);
    let mut source: Option<String> = None;
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if source.is_some() {
            return;
        }
        let (Some(r), Some(f), Some(src)) = (text(vals.get(rel_f)), text(vals.get(fld_f)), text(vals.get(src_f))) else {
            return;
        };
        if r == relation && f == field {
            source = Some(src);
        }
    });
    let source = source?;
    let f_formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, f_descs) = f_formats.iter().max_by_key(|(n, _)| *n)?;
    let fcols = relation_columns(file, page_size, "RDB$FIELDS");
    let ff = |n: &str| fcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, type_f, len_f, scale_f, sub_f, dims_f) = (
        ff("RDB$FIELD_NAME")?,
        ff("RDB$FIELD_TYPE")?,
        ff("RDB$FIELD_LENGTH")?,
        ff("RDB$FIELD_SCALE")?,
        ff("RDB$FIELD_SUB_TYPE")?,
        ff("RDB$DIMENSIONS")?,
    );
    let mut elem: Option<(i64, i64, i64, i64, i64)> = None;
    walk_rows(file, page_size, 2, f_descs, |vals| {
        if elem.is_some() {
            return;
        }
        if text(vals.get(name_f)).as_deref() != Some(source.as_str()) {
            return;
        }
        let int = |i: usize| match vals.get(i) {
            Some(Value::Int(n)) => *n,
            _ => 0,
        };
        elem = Some((int(type_f), int(len_f), int(scale_f), int(sub_f), int(dims_f)));
    });
    let (ftype, flen, fscale, fsub, ndims) = elem?;
    if ndims <= 0 {
        return None;
    }
    let d_formats = system_relation_formats(file, page_size, "RDB$FIELD_DIMENSIONS")?;
    let (_, d_descs) = d_formats.iter().max_by_key(|(n, _)| *n)?;
    let dcols = relation_columns(file, page_size, "RDB$FIELD_DIMENSIONS");
    let df = |n: &str| dcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (dn_f, dd_f, dl_f, du_f) = (df("RDB$FIELD_NAME")?, df("RDB$DIMENSION")?, df("RDB$LOWER_BOUND")?, df("RDB$UPPER_BOUND")?);
    let mut dims: Vec<(i64, i32, i32)> = Vec::new();
    walk_rows(file, page_size, 21, d_descs, |vals| {
        if text(vals.get(dn_f)).as_deref() != Some(source.as_str()) {
            return;
        }
        let int = |i: usize| match vals.get(i) {
            Some(Value::Int(n)) => *n,
            _ => 0,
        };
        dims.push((int(dd_f), int(dl_f) as i32, int(du_f) as i32));
    });
    dims.sort_by_key(|d| d.0);
    if dims.len() != ndims as usize {
        return None;
    }
    // RDB$FIELD_TYPE -> the element's dsc dtype, with the stored length
    let (dtype, length) = match ftype {
        7 => (crate::format::dtype::SHORT, 2u16),
        8 => (crate::format::dtype::LONG, 4),
        16 => (crate::format::dtype::INT64, 8),
        10 => (crate::format::dtype::REAL, 4),
        27 => (crate::format::dtype::DOUBLE, 8),
        12 => (crate::format::dtype::SQL_DATE, 4),
        13 => (crate::format::dtype::SQL_TIME, 4),
        35 => (crate::format::dtype::TIMESTAMP, 8),
        14 => (crate::format::dtype::TEXT, flen as u16),
        37 => (crate::format::dtype::VARYING, flen as u16 + 2),
        _ => return None,
    };
    Some(ArrayShape { dtype, length, scale: fscale as i8, sub_type: fsub as i16, dims: dims.into_iter().map(|d| (d.1, d.2)).collect() })
}

/// Whether a format contains a COMPUTED field: a descriptor at offset 0
/// with a real type. No stored field can live at offset 0 (the null
/// flags do), and a DROPPED-field placeholder there is all-zero - a
/// nonzero length at offset 0 can only be a computed column.
pub fn has_computed_field(descs: &[Descriptor]) -> bool {
    descs.iter().any(|d| d.offset == 0 && d.length != 0)
}

/// Every COMPUTED column of a table, with the field names its stored
/// expression references: `(column name, Some(referenced names))`, or
/// `None` names when the BLR is outside the surface
/// [crate::expr::field_names_of_blr] can read - the caller must then
/// assume it references anything.
fn computed_dependencies(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Vec<(String, Option<Vec<String>>)> {
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    // (column name, field source) of the table's columns
    let Some(rf_formats) = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
    else {
        return Vec::new();
    };
    let Some((_, rf_descs)) = rf_formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(rf_rel), Some(rf_name), Some(rf_src)) = (
        rf_fid("RDB$RELATION_NAME"),
        rf_fid("RDB$FIELD_NAME"),
        rf_fid("RDB$FIELD_SOURCE"),
    ) else {
        return Vec::new();
    };
    let mut members: Vec<(String, String)> = Vec::new();
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if text(vals.get(rf_rel)).as_deref() != Some(table) {
            return;
        }
        if let (Some(name), Some(src)) = (text(vals.get(rf_name)), text(vals.get(rf_src))) {
            members.push((name, src));
        }
    });
    // each source's RDB$COMPUTED_BLR, decoded to its field names
    let Some(f_formats) = system_relation_formats(file, page_size, "RDB$FIELDS") else {
        return Vec::new();
    };
    let Some((_, f_descs)) = f_formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let fcols = relation_columns(file, page_size, "RDB$FIELDS");
    let ffid = |n: &str| fcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(fname_f), Some(cblr_f)) = (ffid("RDB$FIELD_NAME"), ffid("RDB$COMPUTED_BLR"))
    else {
        return Vec::new();
    };
    let mut blobs: Vec<(String, u16, u64)> = Vec::new();
    walk_rows(file, page_size, 2, f_descs, |vals| {
        let Some(fname) = text(vals.get(fname_f)) else { return };
        let Some((col, _)) = members.iter().find(|(_, s)| *s == fname) else {
            return;
        };
        if let Some(Value::Blob(r, n)) = vals.get(cblr_f) {
            blobs.push((col.clone(), *r, *n));
        }
    });
    blobs
        .into_iter()
        .map(|(col, r, n)| {
            let names = crate::format::read_blob_content(file, page_size, r, n)
                .and_then(|b| crate::expr::field_names_of_blr(&b));
            (col, names)
        })
        .collect()
}

/// Locate a system relation's primary row whose decoded values satisfy
/// `pred`: its data page and slot. For an in-place catalog update or
/// delete (ALTER).
fn find_sys_row_slot(
    file: &crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    pred: impl Fn(&[Value]) -> bool,
) -> Option<(u32, u16)> {
    let formats = system_relation_formats(file, page_size, rel_name)?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let dp = crate::page_at(file, page_size, dp_no)
            .and_then(DataPage::decode)?;
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            if pred(&decode_record(&image, descs)) {
                return Some((dp_no, r.slot));
            }
        }
    }
    None
}

/// Locate the `RDB$RELATIONS` primary row for `table`: its data page,
/// slot, current record image, and record format number - what an
/// in-place catalog update (ALTER) needs to rewrite the row.
fn find_relations_row(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Option<(u32, u16, Vec<u8>, u8)> {
    let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let name_fid = relation_columns(file, page_size, "RDB$RELATIONS")
        .iter()
        .find(|c| c.name == "RDB$RELATION_NAME")
        .map(|c| c.field_id as usize)?;
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, 6) {
        let dp = crate::page_at(file, page_size, dp_no)
            .and_then(DataPage::decode)?;
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            let vals = decode_record(&image, descs);
            if let Some(Value::Text(t)) = vals.get(name_fid) {
                if t.trim_end() == table {
                    return Some((dp_no, r.slot, image, r.format));
                }
            }
        }
    }
    None
}

/// Rebuild the `RDB$RUNTIME` field summary for a table from its current
/// `RDB$RELATION_FIELDS` rows (the engine's DSQL layer resolves columns
/// through this blob, so after an ALTER it must list every field). Each
/// field contributes the same segment sequence `make_version` writes:
/// id, name, source (as the quoted `"PUBLIC"."RDB$n"`), length, character
/// length for text, position, and a not-null marker. `descs` is the new
/// full format, indexed by field id, for lengths.
fn rebuild_runtime_blob(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    descs: &[Descriptor],
) -> Result<u64, String> {
    use crate::format::dtype;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid_of = |name: &str| cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let name_fid = fid_of("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let rel_fid = fid_of("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let id_fid = fid_of("RDB$FIELD_ID").ok_or("no RDB$FIELD_ID")?;
    let src_fid = fid_of("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let pos_fid = fid_of("RDB$FIELD_POSITION").ok_or("no RDB$FIELD_POSITION")?;
    let null_fid = fid_of("RDB$NULL_FLAG");
    let default_fid = fid_of("RDB$DEFAULT_VALUE");
    let gen_fid = fid_of("RDB$GENERATOR_NAME");
    let idt_fid = fid_of("RDB$IDENTITY_TYPE");
    let base_fid = fid_of("RDB$BASE_FIELD");
    let vctx_fid = fid_of("RDB$VIEW_CONTEXT");
    let mut view_links: Vec<(String, i64, String)> = Vec::new();

    // collect (field_id, name, source, position, not_null), by field id
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let int = |v: Option<&Value>| match v {
        Some(Value::Int(n)) => Some(*n),
        _ => None,
    };
    #[allow(clippy::type_complexity)]
    let mut fields: Vec<(
        u16,
        String,
        String,
        u16,
        bool,
        Option<(u16, u64)>,
        Option<(String, i16)>,
    )> = Vec::new();
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if text(vals.get(rel_fid)).as_deref() != Some(table) {
            return;
        }
        let (Some(name), Some(id), Some(src), Some(pos)) = (
            text(vals.get(name_fid)),
            int(vals.get(id_fid)),
            text(vals.get(src_fid)),
            int(vals.get(pos_fid)),
        ) else {
            return;
        };
        let not_null = null_fid.and_then(|f| int(vals.get(f))) == Some(1);
        // the column's DEFAULT blob, if any, to re-emit as RSR_default_value
        let default = default_fid.and_then(|f| match vals.get(f) {
            Some(Value::Blob(r, n)) => Some((*r, *n)),
            _ => None,
        });
        // an identity column's generator name and type, to re-emit (tags 22/23)
        let identity = idt_fid.and_then(|f| int(vals.get(f))).and_then(|t| {
            gen_fid
                .and_then(|g| text(vals.get(g)))
                .map(|g| (g, t as i16))
        });
        // a VIEW field's context + base, for the runtime's
        // RSR_view_context / RSR_base_field segments
        if let (Some(bf), Some(vf)) = (base_fid, vctx_fid) {
            if let (Some(crate::format::Value::Text(b)), Some(crate::format::Value::Int(c))) =
                (vals.get(bf), vals.get(vf))
            {
                view_links.push((name.clone(), *c, b.trim_end().to_string()));
            }
        }
        fields.push((id as u16, name, src, pos as u16, not_null, default, identity));
    });
    fields.sort_by_key(|f| f.0);

    // per field SOURCE, from its RDB$FIELDS row: a COMPUTED field's
    // expression BLR (re-emitted as RSR_computed_blr = 4, between the
    // length and position segments - probed order), and a DOMAIN's
    // DEFAULT (a domain column with no column-level default INHERITS
    // the domain's, and the engine's rebuilt summary carries it -
    // probed on ALTER DOMAIN rename, where the engine's runtime kept
    // the RSR_default_value segment this rebuild used to drop)
    let mut computed_blobs: Vec<(String, (u16, u64))> = Vec::new();
    let mut domain_defaults: Vec<(String, (u16, u64))> = Vec::new();
    let mut domain_validations: Vec<(String, (u16, u64))> = Vec::new();
    if let Some(f_formats) = system_relation_formats(file, page_size, "RDB$FIELDS") {
        if let Some((_, f_descs)) = f_formats.iter().max_by_key(|(n, _)| *n) {
            let fcols = relation_columns(file, page_size, "RDB$FIELDS");
            let ffid =
                |n: &str| fcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            let vblr_f = ffid("RDB$VALIDATION_BLR");
            if let (Some(fname_f), Some(cblr_f), dval_f) = (
                ffid("RDB$FIELD_NAME"),
                ffid("RDB$COMPUTED_BLR"),
                ffid("RDB$DEFAULT_VALUE"),
            ) {
                walk_rows(file, page_size, 2, f_descs, |vals| {
                    let Some(fname) = text(vals.get(fname_f)) else { return };
                    if !fields.iter().any(|f| f.2 == fname) {
                        return;
                    }
                    if let Some(Value::Blob(r, n)) = vals.get(cblr_f) {
                        computed_blobs.push((fname.clone(), (*r, *n)));
                    }
                    if let Some(Some(Value::Blob(r, n))) = dval_f.map(|f| vals.get(f)) {
                        domain_defaults.push((fname.clone(), (*r, *n)));
                    }
                    if let Some(Some(Value::Blob(r, n))) = vblr_f.map(|f| vals.get(f)) {
                        domain_validations.push((fname, (*r, *n)));
                    }
                });
            }
        }
    }

    if std::env::var_os("FC_DDL_TRACE").is_some() {
        eprintln!(
            "[ddl] runtime {table}: fields {:?} computed {} defaults {} validations {}",
            fields.iter().map(|f| f.2.clone()).collect::<Vec<_>>(),
            computed_blobs.len(),
            domain_defaults.len(),
            domain_validations.len()
        );
    }
    let seg = |tag: u8, data: &[u8]| {
        let mut s = Vec::with_capacity(1 + data.len());
        s.push(tag);
        s.extend_from_slice(data);
        s
    };
    let mut runtime: Vec<Vec<u8>> = Vec::new();
    for (id, name, src, pos, not_null, default, identity) in &fields {
        let d = descs.get(*id as usize).ok_or("field beyond format")?;
        runtime.push(seg(0, &id.to_le_bytes())); // RSR_field_id
        runtime.push(seg(1, name.as_bytes())); // RSR_field_name
        // a VIEW's field carries its context and base field - the
        // relation loader binds fld_source through them
        // (met.epp RSR_view_context / RSR_base_field)
        if let Some((ctx, base)) = view_links.iter().find(|(n, ..)| n == name).map(|(_, c, b)| (*c, b)) {
            runtime.push(seg(2, &(ctx as u16).to_le_bytes())); // RSR_view_context
            runtime.push(seg(3, base.as_bytes())); // RSR_base_field
        }
        let qsrc = format!("\"PUBLIC\".\"{}\"", src);
        runtime.push(seg(25, qsrc.as_bytes())); // RSR_field_source
        // an ARRAY column: RSR_dimensions (10) - the count, a u16 the
        // engine reads from the segment's first two bytes (met.epp:3518,
        // `n`) - then RSR_array_desc (11), the Ods::InternalArrayDesc it
        // memcpy's over the ArrayField it just made. Without these the
        // engine's DSQL answers "scalar operator used on field ... which
        // is not an array" for a column whose catalog says it is one.
        if let Some(shape) = array_shape(file, page_size, table, name) {
            runtime.push(seg(10, &(shape.dims.len() as u16).to_le_bytes()));
            runtime.push(seg(11, &array_desc_bytes(&shape)));
        }
        let char_len = match d.dtype {
            dtype::VARYING => Some(d.length.saturating_sub(2)),
            dtype::TEXT => Some(d.length),
            _ => None,
        };
        // RSR_field_length is the byte (declared) length, not the storage
        // length - a VARYING's is d.length minus its 2-byte count word
        runtime.push(seg(19, &char_len.unwrap_or(d.length).to_le_bytes()));
        if let Some(cl) = char_len {
            // RSR_character_length is the CHARACTER count; char_len above is
            // the BYTE length, so divide by the charset's bytes-per-char.
            let bpc = crate::intl::bytes_per_char(crate::intl::charset_id(d.sub_type)).max(1);
            runtime.push(seg(26, &(cl / bpc as u16).to_le_bytes()));
        }
        // the computed expression (RSR_computed_blr = 4) before the position
        if let Some((_, (r, n))) = computed_blobs.iter().find(|(s, _)| s == src) {
            if let Some(blr) = crate::format::read_blob_content(file, page_size, *r, *n) {
                runtime.push(seg(4, &blr));
            }
        }
        runtime.push(seg(27, &pos.to_le_bytes())); // RSR_field_pos
        // re-emit the column DEFAULT (RSR_default_value = 6) so an ALTER
        // does not drop it from the summary the engine applies defaults
        // from; a domain column with no column-level default inherits
        // the DOMAIN's
        let effective_default = default
            .map(|(r, n)| (r, n))
            .or_else(|| domain_defaults.iter().find(|(s, _)| s == src).map(|(_, b)| *b));
        if let Some((r, n)) = effective_default {
            if let Some(blr) = crate::format::read_blob_content(file, page_size, r, n) {
                runtime.push(seg(6, &blr));
            }
        }
        // the DOMAIN's CHECK (RSR_validation_blr = 7): the engine
        // enforces field validation from THIS summary segment, not from
        // the domain row - a byte-identical catalog with no segment
        // let a CHECK (VALUE > 0) domain take -5 (measured)
        if let Some((_, (r, n))) = domain_validations.iter().find(|(s, _)| s == src) {
            if let Some(blr) = crate::format::read_blob_content(file, page_size, *r, *n) {
                runtime.push(seg(7, &blr));
            }
        }
        if *not_null {
            runtime.push(seg(21, &NONNULL_BLR)); // RSR_field_not_null
        }
        // re-emit an identity field's generator (22) and type (23) so an ALTER
        // does not strip it - without them the column stops auto-generating
        if let Some((gen_name, itype)) = identity {
            runtime.push(seg(22, gen_name.as_bytes()));
            runtime.push(seg(23, &(*itype as u16).to_le_bytes()));
        }
    }
    // the relation's triggers (RSR_trigger_name = 9): the engine loads a
    // relation's trigger vector from these runtime entries, NOT by scanning
    // RDB$TRIGGERS by relation name - so a trigger absent here never fires
    for tname in relation_trigger_names(file, page_size, table) {
        runtime.push(seg(9, tname.as_bytes()));
    }
    dml::insert_blob(file, page_size, 6, &runtime, 5)
}

/// The names of a relation's triggers in the order the engine lists
/// them in the relation's `RDB$RUNTIME` summary - which is the order it
/// FIRES same-position triggers in. Two passes, as `RelationNode`'s
/// summary writer makes them (DdlNodes.epp:9190-9250): first the USER
/// triggers that are not a constraint's (system flag 0, not named by an
/// RDB$CHECK_CONSTRAINTS row of a CHECK or FOREIGN KEY constraint),
/// then the CONSTRAINT triggers (system flag 3..5, or a user-flag trigger
/// a CHECK / FOREIGN KEY constraint names), each pass `SORTED BY
/// RDB$TRIGGER_SEQUENCE`, inactive triggers skipped. Within a position
/// the pass lists lexically (probed: CHECK_10 before CHECK_7). The
/// split is not cosmetic: on the employee sample a BEFORE INSERT
/// `SET_EMP_NO` at position 0 must run before `CHECK_3` at position 0,
/// or a row that fails its check never draws the generator the engine
/// draws for it.
fn relation_trigger_names(file: &crate::Image, page_size: usize, table: &str) -> Vec<String> {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$TRIGGERS"),
        system_relation_formats(file, page_size, "RDB$TRIGGERS"),
    ) else {
        return Vec::new();
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let cols = relation_columns(file, page_size, "RDB$TRIGGERS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(name_f), Some(rn_f), Some(seq_f)) =
        (fid("RDB$TRIGGER_NAME"), fid("RDB$RELATION_NAME"), fid("RDB$TRIGGER_SEQUENCE"))
    else {
        return Vec::new();
    };
    let sys_f = fid("RDB$SYSTEM_FLAG");
    let inactive_f = fid("RDB$TRIGGER_INACTIVE");
    let int = |v: Option<&Value>| match v {
        Some(Value::Int(n)) => *n,
        _ => 0,
    };
    // the triggers a CHECK / FOREIGN KEY constraint of this table names
    let constraint_triggers: std::collections::HashSet<String> = {
        let mut names: Vec<String> = Vec::new();
        if let (Some(rc_rel), Some(rc_formats)) = (
            crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS"),
            system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS"),
        ) {
            if let Some((_, rc_descs)) = rc_formats.iter().max_by_key(|(n, _)| *n) {
                let rc_cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
                let rf = |n: &str| rc_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
                if let (Some(cn_f), Some(ct_f), Some(crn_f)) =
                    (rf("RDB$CONSTRAINT_NAME"), rf("RDB$CONSTRAINT_TYPE"), rf("RDB$RELATION_NAME"))
                {
                    walk_rows(file, page_size, rc_rel, rc_descs, |v| {
                        if !text_is(v.get(crn_f), table) {
                            return;
                        }
                        let kind = match v.get(ct_f) {
                            Some(Value::Text(t)) => t.trim_end().to_string(),
                            _ => return,
                        };
                        if kind != "CHECK" && kind != "FOREIGN KEY" {
                            return;
                        }
                        if let Some(Value::Text(t)) = v.get(cn_f) {
                            names.push(t.trim_end().to_string());
                        }
                    });
                }
            }
        }
        let mut out = std::collections::HashSet::new();
        if !names.is_empty() {
            if let (Some(cc_rel), Some(cc_formats)) = (
                crate::resolve_relation(file, page_size, "RDB$CHECK_CONSTRAINTS"),
                system_relation_formats(file, page_size, "RDB$CHECK_CONSTRAINTS"),
            ) {
                if let Some((_, cc_descs)) = cc_formats.iter().max_by_key(|(n, _)| *n) {
                    let cc_cols = relation_columns(file, page_size, "RDB$CHECK_CONSTRAINTS");
                    let cf = |n: &str| cc_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
                    if let (Some(ccn_f), Some(ctn_f)) = (cf("RDB$CONSTRAINT_NAME"), cf("RDB$TRIGGER_NAME")) {
                        walk_rows(file, page_size, cc_rel, cc_descs, |v| {
                            let (Some(Value::Text(c)), Some(Value::Text(t))) = (v.get(ccn_f), v.get(ctn_f)) else {
                                return;
                            };
                            if names.iter().any(|n| n == c.trim_end()) {
                                out.insert(t.trim_end().to_string());
                            }
                        });
                    }
                }
            }
        }
        out
    };
    let mut user: Vec<(i64, String)> = Vec::new();
    let mut constraint: Vec<(i64, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |v| {
        if !text_is(v.get(rn_f), table) {
            return;
        }
        let Some(Value::Text(t)) = v.get(name_f) else { return };
        if inactive_f.map(|f| int(v.get(f))) == Some(1) {
            return;
        }
        let name = t.trim_end().to_string();
        let seq = int(v.get(seq_f));
        let sys = sys_f.map(|f| int(v.get(f))).unwrap_or(0);
        if (3..=5).contains(&sys) || constraint_triggers.contains(&name) {
            constraint.push((seq, name));
        } else if sys == 0 {
            user.push((seq, name));
        }
    });
    user.sort();
    constraint.sort();
    user.into_iter().chain(constraint).map(|(_, n)| n).collect()
}

/// `ALTER TABLE <table> ADD <column>`: append one column to an existing
/// table. The engine models this as a new *format version* - existing
/// records keep their old format (and read the new column as NULL), new
/// records use the new one. The sequence mirrors the tail of
/// [create_table] for the single new field, plus a version rewrite of the
/// `RDB$RELATIONS` row to bump its `RDB$FORMAT` and field count.
pub fn alter_table_add_column(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col: &ColumnDef,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;

    // existing columns: reject a duplicate name, find the next field id
    let existing = relation_columns(file, page_size, &table);
    if existing
        .iter()
        .any(|c| c.name == col.name)
    {
        return Err(format!("column {} already exists", col.name));
    }
    let new_fid = existing.iter().map(|c| c.field_id + 1).max().unwrap_or(0);

    // a DOMAIN-typed column resolves its storage off the domain's row,
    // exactly as create_table does, and its RDB$FIELD_SOURCE is the
    // DOMAIN - no RDB$<n> carrier is minted. (This used to fall through
    // with the UNRESOLVED zero-typed ColumnDef under a fresh carrier -
    // a column the engine reads as length-0 garbage, and every later
    // DML on the table refused; review-caught.)
    let resolved_col: ColumnDef;
    let (col, domain_source): (&ColumnDef, Option<String>) = match &col.domain {
        Some(dname) => {
            let dname = dname.trim().trim_matches('"').to_ascii_uppercase();
            let dt = resolve_domain_type(file, page_size, &dname)
                .ok_or_else(|| format!("Domain {} is not defined", dname))?;
            // the domain's own NOT NULL would need existing rows
            // re-checked and an RSR not-null segment sourced from the
            // domain - outside this writer's proven surface
            if dt.not_null {
                return Err(format!(
                    "domain {} is NOT NULL - outside this ALTER surface",
                    dname
                ));
            }
            let mut rc = col.clone();
            rc.field_type = dt.field_type;
            rc.dtype = dt.dtype;
            rc.length = dt.length;
            rc.scale = dt.scale;
            rc.sub_type = dt.sub_type;
            rc.char_len = dt.char_len;
            rc.dims = dt.dims.clone();
            resolved_col = rc;
            (&resolved_col, Some(dname))
        }
        None => (col, None),
    };

    // the new full format: existing descriptors + the new field, offsets
    // recomputed by the same ini.epp walk (append-stable, so the existing
    // fields keep their offsets and the new one lands at the end)
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    // a computed column has no storage to constrain or default into
    if col.computed.is_some() && (col.not_null || col.default.is_some() || col.identity.is_some())
    {
        return Err(format!("computed column {} cannot carry constraints", col.name));
    }
    // existing COMPUTED fields (descriptor at offset 0) keep their
    // offset-0 descriptors through the recompute; the stored-offset walk
    // skips them, so existing stored fields keep their offsets and a new
    // stored field lands after the last stored one (probed: adding a
    // BIGINT to `(A INTEGER, C COMPUTED BY (A))` lands it at offset 8)
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    let (dt, l, s, st) = col_field_of(col);
    fields.push((dt, l, s, st, col.computed.is_some()));
    let new_descs = compute_format_mixed(&fields);
    if new_descs.len() != fields.len() {
        return Err("format computation failed".into());
    }

    // locate the RDB$RELATIONS row and read its current format number
    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, &table)
            .ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field = |name: &str| -> Option<usize> {
        rel_cols
            .iter()
            .find(|c| c.name == name)
            .map(|c| c.field_id as usize)
    };
    let cur_vals = decode_record(&rel_image, rel_descs);
    let cur_format_no = match cur_vals.get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?) {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    // --- write the new format version blob + RDB$FORMATS row ----------
    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;

    // --- the new column's domain, RDB$FIELDS and RDB$RELATION_FIELDS --
    // a USER-domain column points at the domain itself; only a plain
    // column mints an auto-carrier RDB$<n> row
    let dom = match &domain_source {
        Some(d) => d.clone(),
        None => format!("RDB${}", next_domain_number(file, page_size)?),
    };
    if domain_source.is_none() {
    let mut field_vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&dom)),
        ("RDB$FIELD_TYPE", SysVal::I(col.field_type as i64)),
        ("RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(col))),
        ("RDB$FIELD_SCALE", SysVal::I(col.scale as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        // an auto-domain is owned by the table's owner (no security class)
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if subtype_carried(col.field_type) {
        // text carries its charset in the DESCRIPTOR sub_type (the ttype) but
        // RDB$FIELD_SUB_TYPE is 0 for CHAR/VARCHAR (the charset is in
        // RDB$CHARACTER_SET_ID); numeric keeps its 1/2.
        let st = if matches!(col.field_type, 14 | 37) { 0 } else { col.sub_type };
        field_vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(st as i64)));
    }
    if let Some(cl) = col.char_len {
        field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(col.charset_id.unwrap_or(0) as i64)));
        field_vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
        field_vals.push(("RDB$COLLATION_ID", SysVal::I(crate::intl::collation_id(col.sub_type) as i64)));
    }
    if col.field_type == 261 {
        field_vals.push(("RDB$SEGMENT_LENGTH", SysVal::I(col.segment_length.unwrap_or(80) as i64)));
        if col.sub_type == 1 {
            field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(col.charset_id.unwrap_or(0) as i64)));
            field_vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
        }
    }
    // a computed column: the verbatim `(expr)` source + compiled BLR +
    // the result type's precision, exactly as create_table writes them
    let computed_blobs = match &col.computed {
        Some(cp) => {
            let src =
                dml::insert_blob_cs(file, page_size, 2, &[cp.source.as_bytes().to_vec()], 1, 4)?;
            let blr = dml::insert_blob(file, page_size, 2, &[cp.blr.clone()], 2)?;
            Some((src, blr, cp.precision))
        }
        None => None,
    };
    if let Some((src, blr, precision)) = computed_blobs {
        field_vals.push(("RDB$COMPUTED_SOURCE", SysVal::B(blob_id_bytes(2, src))));
        field_vals.push(("RDB$COMPUTED_BLR", SysVal::B(blob_id_bytes(2, blr))));
        field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(precision as i64)));
    } else if let Some(p) = col.precision {
        // a plain added column's precision, same rule as create_table
        field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(p as i64)));
    }
    if !col.dims.is_empty() {
        field_vals.push(("RDB$DIMENSIONS", SysVal::I(col.dims.len() as i64)));
    }
    sys_insert(file, page_size, "RDB$FIELDS", 2, &field_vals)?;
    // an ARRAY column's bounds: one RDB$FIELD_DIMENSIONS row per dimension,
    // exactly as create_table writes them
    for (dim, (lo, hi)) in col.dims.iter().enumerate() {
        sys_insert(
            file,
            page_size,
            "RDB$FIELD_DIMENSIONS",
            21,
            &[
                ("RDB$FIELD_NAME", SysVal::S(&dom)),
                ("RDB$DIMENSION", SysVal::I(dim as i64)),
                ("RDB$LOWER_BOUND", SysVal::I(*lo as i64)),
                ("RDB$UPPER_BOUND", SysVal::I(*hi as i64)),
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ],
        )?;
    }
    } // domain_source.is_none() - a user domain's row already exists

    let rf_vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&col.name)),
        ("RDB$RELATION_NAME", SysVal::S(&table)),
        ("RDB$FIELD_SOURCE", SysVal::S(&dom)),
        ("RDB$FIELD_POSITION", SysVal::I(new_fid as i64)),
        // a computed column is read-only: RDB$UPDATE_FLAG 0 (probed)
        ("RDB$UPDATE_FLAG", SysVal::I(if col.computed.is_some() { 0 } else { 1 })),
        ("RDB$FIELD_ID", SysVal::I(new_fid as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
        // a text column's collation rides here too (the ttype high byte);
        // a built-in non-text column is 0
        ("RDB$COLLATION_ID", SysVal::I(crate::intl::collation_id(col.sub_type) as i64)),
    ];
    sys_insert(file, page_size, "RDB$RELATION_FIELDS", 5, &rf_vals)?;

    // --- rebuild RDB$RUNTIME for all fields (incl. the new one, now in
    // RDB$RELATION_FIELDS) so DSQL resolves the added column ------------
    let runtime = rebuild_runtime_blob(file, page_size, &table, &new_descs)?;

    // --- bump RDB$RELATIONS.RDB$FORMAT, RDB$FIELD_ID and RDB$RUNTIME in
    // place (a version rewrite of the row) -----------------------------
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8)); // clear NULL bit (already set)
        Ok(())
    };
    let old_rt = rel_field("RDB$RUNTIME").and_then(|f| old_blob_at(&rel_image, rel_descs, f));
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$FIELD_ID", SysVal::I((new_fid + 1) as i64))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(
        file,
        page_size,
        6,
        &[(rel_page, rel_slot, rel_image)],
        rec_format,
    )?;
    if let Some((orel, onum)) = old_rt {
        dispose_superseded_blob(file, page_size, orel, onum);
        dispose_row_purge(file, page_size, 6, rel_page, rel_slot);
    }

    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// A field's `RDB$FIELD_LENGTH`: the byte length, which for a `VARCHAR` is
/// the character count, not the `+2` count-word storage length a
/// [ColumnDef]'s `length` carries. A `CHAR`'s length is already the count;
/// a non-text type has no `char_len` and uses `length` directly.
fn catalog_field_length(col: &ColumnDef) -> i64 {
    // RDB$FIELD_LENGTH is a BYTE length (char_len * bytes-per-char), which is
    // already what col.length holds for text (a VARYING carries its 2-byte
    // count word on top, not counted here). A non-text column has no char_len
    // and uses its length directly.
    if col.char_len.is_some() {
        (if col.dtype == crate::format::dtype::VARYING {
            col.length.saturating_sub(2)
        } else {
            col.length
        }) as i64
    } else {
        col.length as i64
    }
}

/// `ALTER DOMAIN <old> TO <new>`: rename the domain's RDB$FIELDS row IN
/// PLACE and key the NEW name into the catalog's name index - the old
/// entry stays behind pointing at the live row with a stale key, the
/// same shape every engine update leaves until garbage collection, and
/// what validation demands is that the CURRENT key be findable
/// ([maintain_indexes]'s second caller). Every column using the domain
/// gets its RDB$FIELD_SOURCE patched (not an indexed column) and its
/// table's RDB$RUNTIME rebuilt - the summary quotes the source name, so
/// without the rebuild the engine would still resolve columns through
/// the OLD name (probed: the engine updates both on rename, and the
/// domain's DEFAULT keeps applying afterwards).
pub fn rename_domain(
    file: &mut crate::Image,
    page_size: usize,
    old: &str,
    new: &str,
) -> Result<(), String> {
    let old = old.trim().trim_matches('"').to_ascii_uppercase();
    let new = new.trim().trim_matches('"').to_ascii_uppercase();
    if old.starts_with("RDB$") || new.starts_with("RDB$") {
        return Err("system domains cannot be renamed".into());
    }
    if !domain_exists(file, page_size, &old) {
        return Err(format!("domain {} not found", old));
    }
    if domain_exists(file, page_size, &new) {
        return Err(format!("domain {} already exists", new));
    }

    // the RDB$FIELDS row: patch RDB$FIELD_NAME in place
    let formats =
        system_relation_formats(file, page_size, "RDB$FIELDS").ok_or("no RDB$FIELDS format")?;
    let (_, f_descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let f_descs = f_descs.clone();
    let f_cols = relation_columns(file, page_size, "RDB$FIELDS");
    let name_fid = f_cols
        .iter()
        .find(|c| c.name == "RDB$FIELD_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$FIELD_NAME")?;
    let mut hit: Option<(u32, u16, Vec<u8>, u8)> = None;
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, 2) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            let vals = decode_record(&image, &f_descs);
            if text_eq(vals.get(name_fid), &old) {
                hit = Some((dp_no, r.slot, image, r.format));
            }
        }
    }
    let (page, slot, mut image, rec_format) = hit.ok_or("domain row not found")?;
    let d = f_descs.get(name_fid).ok_or("field beyond format")?;
    let bytes = encode_sys_value(d, &SysVal::S(&new))?;
    let at = d.offset as usize;
    image
        .get_mut(at..at + bytes.len())
        .ok_or("image shorter than format")?
        .copy_from_slice(&bytes);
    // key the RENAMED row into the catalog's indexes from its FULL
    // patched image - the name index is compound ((schema, name) at ODS
    // 14), so a name-only key would insert an entry the engine's DDL
    // lookup never finds (caught live: SELECT ... WHERE RDB$FIELD_NAME
    // found the row through the index while CREATE TABLE <domain> said
    // the domain did not exist)
    let key_values = decode_record(&image, &f_descs);
    dml::update_records(file, page_size, 2, &[(page, slot, image)], rec_format)?;

    let seq = u32_at(
        crate::page_at(file, page_size, page).ok_or("data page out of range")?,
        16,
    ) as u64;
    let recno = seq * max_recs_per_dp(page_size) + slot as u64;
    maintain_indexes(file, page_size, 2, recno, &key_values, &f_descs)?;

    // every column whose RDB$FIELD_SOURCE is the domain: patch the source
    // (not an indexed column) and remember its table for a runtime rebuild
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rf_descs = rf_descs.clone();
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let src_fid = rf_fid("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let rel_fid = rf_fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let mut patches: Vec<(u32, u16, Vec<u8>, u8)> = Vec::new();
    let mut tables: Vec<String> = Vec::new();
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, 5) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            let vals = decode_record(&image, &rf_descs);
            if !text_eq(vals.get(src_fid), &old) {
                continue;
            }
            if let Some(Value::Text(t)) = vals.get(rel_fid) {
                let t = t.trim_end().to_string();
                if !tables.contains(&t) {
                    tables.push(t);
                }
            }
            patches.push((dp_no, r.slot, image, r.format));
        }
    }
    let sd = rf_descs.get(src_fid).ok_or("field beyond format")?;
    let sbytes = encode_sys_value(sd, &SysVal::S(&new))?;
    for (dp_no, slot, mut image, fmt) in patches {
        let at = sd.offset as usize;
        image
            .get_mut(at..at + sbytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&sbytes);
        // RDB$FIELD_SOURCE is INDEXED at ODS 14 (RDB$INDEX_3, and the
        // schema-qualified RDB$INDEX_61) - the patched row's new source
        // needs entries under its new key, like the rel-2 row above
        // (gfix: "missing entries for record n" otherwise, caught live)
        let key_values = decode_record(&image, &rf_descs);
        dml::update_records(file, page_size, 5, &[(dp_no, slot, image)], fmt)?;
        let seq = u32_at(
            crate::page_at(file, page_size, dp_no).ok_or("data page out of range")?,
            16,
        ) as u64;
        let recno = seq * max_recs_per_dp(page_size) + slot as u64;
        maintain_indexes(file, page_size, 5, recno, &key_values, &rf_descs)?;
    }
    for t in &tables {
        update_relation_runtime(file, page_size, t)?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// Whether an `RDB$FIELDS` domain of this name exists.
fn domain_exists(file: &crate::Image, page_size: usize, name: &str) -> bool {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$FIELDS"),
        system_relation_formats(file, page_size, "RDB$FIELDS"),
    ) else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let name_f = match relation_columns(file, page_size, "RDB$FIELDS")
        .iter()
        .find(|c| c.name == "RDB$FIELD_NAME")
    {
        Some(c) => c.field_id as usize,
        None => return false,
    };
    let mut found = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(name_f), name) {
            found = true;
        }
    });
    found
}

/// Give `table` a NEW FORMAT VERSION with the fields at `fids` retyped
/// to `new_col`'s storage - the per-dependent-table half of an in-use
/// `ALTER DOMAIN TYPE` (the engine bumps every dependent table's format
/// by exactly one per statement, however many of its columns use the
/// domain - probed). The same repack-insert-rebuild-bump sequence the
/// column ALTER TYPE performs after its own guards: existing records
/// keep their old format and read back promoted.
fn reformat_for_retype(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fids: &[usize],
    new_col: &ColumnDef,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    // the new format: each dependent field's descriptor replaced, all
    // repacked; a COMPUTED field keeps its offset-0 descriptor
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    let (dt, l, s, st) = col_field_of(new_col);
    for fid in fids {
        let f = fields
            .get_mut(*fid)
            .ok_or("dependent field beyond the format")?;
        if f.4 {
            return Err(format!("cannot retype a computed field of {}", table));
        }
        *f = (dt, l, s, st, false);
    }
    let new_descs = compute_format_mixed(&fields);

    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats = system_relation_formats(file, page_size, "RDB$RELATIONS")
        .ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field =
        |name: &str| rel_cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let cur_format_no = match decode_record(&rel_image, rel_descs)
        .get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?)
    {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;
    let runtime = rebuild_runtime_blob(file, page_size, table, &new_descs)?;
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    let old_rt = rel_field("RDB$RUNTIME").and_then(|f| old_blob_at(&rel_image, rel_descs, f));
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(file, page_size, 6, &[(rel_page, rel_slot, rel_image)], rec_format)?;
    if let Some((orel, onum)) = old_rt {
        dispose_superseded_blob(file, page_size, orel, onum);
        dispose_row_purge(file, page_size, 6, rel_page, rel_slot);
    }
    Ok(())
}

/// Every table.column that uses a domain as its `RDB$FIELD_SOURCE`,
/// as (relation name, column name) pairs - what the ALTER DOMAIN TYPE
/// dependents guard walks.
fn domain_dependents(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Result<Vec<(String, String)>, String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let fn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let src_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_SOURCE")?;
    let mut out = Vec::new();
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(src_f), name) {
            if let (Some(Value::Text(t)), Some(Value::Text(c))) = (v.get(rn_f), v.get(fn_f)) {
                out.push((t.trim_end().to_string(), c.trim_end().to_string()));
            }
        }
    });
    Ok(out)
}

/// The first table.column that uses a domain as its `RDB$FIELD_SOURCE`
/// (None if the domain is unused) - a `DROP DOMAIN` is refused while it
/// is in use.
fn domain_user(file: &crate::Image, page_size: usize, name: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rn_f, src_f) = (fid("RDB$RELATION_NAME")?, fid("RDB$FIELD_SOURCE")?);
    let mut used = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if used.is_none() && text_eq(v.get(src_f), name) {
            if let Some(Value::Text(t)) = v.get(rn_f) {
                used = Some(t.trim_end().to_string());
            }
        }
    });
    used
}

/// `CREATE DOMAIN <name> [AS] <type> [NOT NULL]` - a standalone field
/// definition, one `RDB$FIELDS` row named by the user (no relation link,
/// no security class). The same row a table column's auto-domain gets,
/// with the user's name; `NOT NULL` sets `RDB$NULL_FLAG` on the domain
/// itself (a table column keeps its NOT NULL on `RDB$RELATION_FIELDS`).
pub fn create_domain(file: &mut crate::Image, page_size: usize, col: &ColumnDef) -> Result<(), String> {
    let name = col.name.trim().trim_matches('"').to_ascii_uppercase();
    if name.is_empty() {
        return Err("a domain needs a name".into());
    }
    if domain_exists(file, page_size, &name) {
        return Err(format!("Domain {} already exists", name));
    }
    // a user domain carries a security class and owner, like a sequence: the
    // SQL$<n> class holds the owner's alter/control/drop/usage ACL, and the
    // owner takes a USAGE ('G', object type 9) privilege row
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    let mut vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&name)),
        ("RDB$FIELD_TYPE", SysVal::I(col.field_type as i64)),
        ("RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(col))),
        ("RDB$FIELD_SCALE", SysVal::I(col.scale as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$SECURITY_CLASS", SysVal::S(&class)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if subtype_carried(col.field_type) {
        let st = if matches!(col.field_type, 14 | 37) { 0 } else { col.sub_type };
        vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(st as i64)));
    }
    if let Some(cl) = col.char_len {
        vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(col.charset_id.unwrap_or(0) as i64)));
        vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
        vals.push(("RDB$COLLATION_ID", SysVal::I(crate::intl::collation_id(col.sub_type) as i64)));
    }
    if col.field_type == 261 {
        vals.push(("RDB$SEGMENT_LENGTH", SysVal::I(col.segment_length.unwrap_or(80) as i64)));
        if col.sub_type == 1 {
            vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(col.charset_id.unwrap_or(0) as i64)));
            vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
        }
    }
    if let Some(p) = col.precision {
        // same rule as a table column's auto-domain: 0 for plain exact
        // ints, the declared p for NUMERIC/DECIMAL (probed on domains)
        vals.push(("RDB$FIELD_PRECISION", SysVal::I(p as i64)));
    }
    if col.not_null {
        vals.push(("RDB$NULL_FLAG", SysVal::I(1)));
    }
    if !col.dims.is_empty() {
        vals.push(("RDB$DIMENSIONS", SysVal::I(col.dims.len() as i64)));
    }
    // a domain DEFAULT lives on the domain's own RDB$FIELDS row (the source
    // text, subtype 1 charset 4 like a description, and the value BLR,
    // subtype 2) - the same two blobs a table column's default gets, but on
    // RDB$FIELDS (2) rather than RDB$RELATION_FIELDS (5). A column that then
    // uses the domain without its own default inherits this at insert time.
    if let Some(def) = &col.default {
        let src = dml::insert_blob_cs(file, page_size, 2, &[def.source.as_bytes().to_vec()], 1, 4)?;
        let val = dml::insert_blob(file, page_size, 2, &[def.value_blr.clone()], 2)?;
        vals.push(("RDB$DEFAULT_SOURCE", SysVal::B(blob_id_bytes(2, src))));
        vals.push(("RDB$DEFAULT_VALUE", SysVal::B(blob_id_bytes(2, val))));
    }
    sys_insert(file, page_size, "RDB$FIELDS", 2, &vals)?;
    // an ARRAY domain's bounds: one RDB$FIELD_DIMENSIONS row per
    // dimension on the domain's own name (a column of the domain has no
    // rows of its own - array_shape follows RDB$FIELD_SOURCE here)
    for (dim, (lo, hi)) in col.dims.iter().enumerate() {
        sys_insert(
            file,
            page_size,
            "RDB$FIELD_DIMENSIONS",
            21,
            &[
                ("RDB$FIELD_NAME", SysVal::S(&name)),
                ("RDB$DIMENSION", SysVal::I(dim as i64)),
                ("RDB$LOWER_BOUND", SysVal::I(*lo as i64)),
                ("RDB$UPPER_BOUND", SysVal::I(*hi as i64)),
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ],
        )?;
    }
    store_privileges(file, page_size, &name, 9, &["G"])?;
    advance_oldest_transactions(file, page_size)
}

/// `DROP DOMAIN <name>` - delete the `RDB$FIELDS` row. Refused while a
/// table column still uses the domain as its `RDB$FIELD_SOURCE`, or when
/// the domain does not exist.
/// `DECLARE FILTER <name> INPUT_TYPE <i> OUTPUT_TYPE <o> ENTRY_POINT '<e>'
/// MODULE_NAME '<m>'`: one RDB$FILTERS row (owner, a security class like
/// a sequence's, no privilege row - probed). A name already declared is
/// "Blob filter already exists"; a (input, output) pair already declared
/// is the engine's unique-key violation on RDB$INDEX_17 (the caller
/// spells that vector).
pub fn declare_filter(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    input: i16,
    output: i16,
    entry: &str,
    module: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a filter needs a name".into());
    }
    let (names, pairs) = filters(file, page_size);
    if names.iter().any(|n| n == &want) {
        return Err(format!("Blob filter {} already exists", want));
    }
    if pairs.contains(&(input, output)) {
        return Err(format!("filter pair {} {} already exists", input, output));
    }
    let rel = crate::resolve_relation(file, page_size, "RDB$FILTERS").ok_or("no RDB$FILTERS relation")?;
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$FILTERS",
        rel,
        &[
            ("RDB$FUNCTION_NAME", SysVal::S(&want)),
            ("RDB$MODULE_NAME", SysVal::S(module)),
            ("RDB$ENTRYPOINT", SysVal::S(entry)),
            ("RDB$INPUT_SUB_TYPE", SysVal::I(input as i64)),
            ("RDB$OUTPUT_SUB_TYPE", SysVal::I(output as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// Every declared filter: the names, and the (input, output) pairs.
fn filters(file: &crate::Image, page_size: usize) -> (Vec<String>, Vec<(i16, i16)>) {
    let mut names = Vec::new();
    let mut pairs = Vec::new();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$FILTERS"),
        system_relation_formats(file, page_size, "RDB$FILTERS"),
    ) else {
        return (names, pairs);
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return (names, pairs);
    };
    let cols = relation_columns(file, page_size, "RDB$FILTERS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(name_f), Some(in_f), Some(out_f)) =
        (fid("RDB$FUNCTION_NAME"), fid("RDB$INPUT_SUB_TYPE"), fid("RDB$OUTPUT_SUB_TYPE"))
    else {
        return (names, pairs);
    };
    walk_rows(file, page_size, rel, descs, |v| {
        if let Some(Value::Text(t)) = v.get(name_f) {
            names.push(t.trim_end().to_string());
        }
        let geti = |f: usize| match v.get(f) {
            Some(Value::Int(i)) => *i as i16,
            _ => 0,
        };
        pairs.push((geti(in_f), geti(out_f)));
    });
    (names, pairs)
}

/// `DROP FILTER <name>`: the row and its security class go.
pub fn drop_filter(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (names, _) = filters(file, page_size);
    if !names.iter().any(|n| n == &want) {
        return Err(format!("BLOB Filter {} not found", want));
    }
    let name_f = sys_fid(file, page_size, "RDB$FILTERS", "RDB$FUNCTION_NAME")?;
    let cls_f_src = sys_fid(file, page_size, "RDB$FILTERS", "RDB$SECURITY_CLASS")?;
    let mut class: Option<String> = None;
    if let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$FILTERS"),
        system_relation_formats(file, page_size, "RDB$FILTERS"),
    ) {
        if let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) {
            let w = want.clone();
            walk_rows(file, page_size, rel, descs, |v| {
                if class.is_none() && text_eq(v.get(name_f), &w) {
                    if let Some(Value::Text(t)) = v.get(cls_f_src) {
                        class = Some(t.trim_end().to_string());
                    }
                }
            });
        }
    }
    {
        let w = want.clone();
        delete_catalog_rows(file, page_size, "RDB$FILTERS", move |v| text_eq(v.get(name_f), &w))?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    advance_oldest_transactions(file, page_size)
}

/// `DROP FUNCTION <name>`: the RDB$FUNCTIONS row, its argument rows and
/// their auto-domains, its security class, privileges and dependencies go.
pub fn drop_function(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (class, found) = {
        let formats = system_relation_formats(file, page_size, "RDB$FUNCTIONS").ok_or("no RDB$FUNCTIONS format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let rel = crate::resolve_relation(file, page_size, "RDB$FUNCTIONS").ok_or("no RDB$FUNCTIONS")?;
        let cols = relation_columns(file, page_size, "RDB$FUNCTIONS");
        let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
        let name_f = fid("RDB$FUNCTION_NAME").ok_or("no RDB$FUNCTION_NAME")?;
        let cls_f = fid("RDB$SECURITY_CLASS");
        let pkg_f = fid("RDB$PACKAGE_NAME");
        let mut class = None;
        let mut found = false;
        walk_rows(file, page_size, rel, descs, |v| {
            if !found && text_eq(v.get(name_f), &want) && !matches!(pkg_f.and_then(|f| v.get(f)), Some(Value::Text(_))) {
                found = true;
                if let Some(Value::Text(t)) = cls_f.and_then(|f| v.get(f)) {
                    class = Some(t.trim_end().to_string());
                }
            }
        });
        (class, found)
    };
    if !found {
        return Err(format!("Function {} not found", want));
    }
    let mut domain_names: Vec<String> = Vec::new();
    {
        let formats = system_relation_formats(file, page_size, "RDB$FUNCTION_ARGUMENTS").ok_or("no RDB$FUNCTION_ARGUMENTS format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let rel = crate::resolve_relation(file, page_size, "RDB$FUNCTION_ARGUMENTS").ok_or("no RDB$FUNCTION_ARGUMENTS")?;
        let fn_f = sys_fid(file, page_size, "RDB$FUNCTION_ARGUMENTS", "RDB$FUNCTION_NAME")?;
        let src_f = sys_fid(file, page_size, "RDB$FUNCTION_ARGUMENTS", "RDB$FIELD_SOURCE")?;
        // a PACKAGED member of the same bare name shares RDB$FUNCTION_NAME;
        // its RDB$PACKAGE_NAME is Text where the plain function's is NULL, so
        // gather (and below, delete) only the plain rows - never the member's
        let apk_f = sys_fid(file, page_size, "RDB$FUNCTION_ARGUMENTS", "RDB$PACKAGE_NAME")?;
        walk_rows(file, page_size, rel, descs, |v| {
            if text_eq(v.get(fn_f), &want)
                && !matches!(v.get(apk_f), Some(Value::Text(_)))
            {
                if let Some(Value::Text(t)) = v.get(src_f) {
                    let t = t.trim_end();
                    if t.strip_prefix("RDB$").is_some_and(|x| x.parse::<u64>().is_ok()) {
                        domain_names.push(t.to_string());
                    }
                }
            }
        });
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FUNCTION_ARGUMENTS", "RDB$FUNCTION_NAME")?;
        let pk = sys_fid(file, page_size, "RDB$FUNCTION_ARGUMENTS", "RDB$PACKAGE_NAME")?;
        let n = want.clone();
        delete_catalog_rows(file, page_size, "RDB$FUNCTION_ARGUMENTS", move |v| {
            text_eq(v.get(fid), &n) && !matches!(v.get(pk), Some(Value::Text(_)))
        })?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
        let names = domain_names.clone();
        delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| names.iter().any(|d| text_eq(v.get(fid), d)))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FUNCTIONS", "RDB$FUNCTION_NAME")?;
        let pk = sys_fid(file, page_size, "RDB$FUNCTIONS", "RDB$PACKAGE_NAME")?;
        let n = want.clone();
        delete_catalog_rows(file, page_size, "RDB$FUNCTIONS", move |v| {
            text_eq(v.get(fid), &n) && !matches!(v.get(pk), Some(Value::Text(_)))
        })?;
    }
    if let Some(class) = class {
        let fid = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| text_eq(v.get(fid), &class))?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        let n = want.clone();
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| text_eq(v.get(rel_f), &n) && int_eq(v.get(obj_f), 15))?;
    }
    if crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES").is_some() {
        let dn_f = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_NAME")?;
        let dt_f = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_TYPE")?;
        let n = want.clone();
        delete_catalog_rows(file, page_size, "RDB$DEPENDENCIES", move |v| text_eq(v.get(dn_f), &n) && int_eq(v.get(dt_f), 15))?;
    }
    advance_oldest_transactions(file, page_size)
}

pub fn drop_domain(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if !domain_exists(file, page_size, &want) {
        return Err(format!("Domain {} not found", want));
    }
    if let Some(user) = domain_user(file, page_size, &want) {
        return Err(format!("Domain {} is used in table {}", want, user));
    }
    // the domain's security class and its owner privilege go with it (the
    // engine drops both), then the RDB$FIELDS row
    let class = domain_security_class(file, page_size, &want);
    let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    let nm = want.clone();
    delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| text_eq(v.get(name_f), &nm))?;
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
    let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
    let dn = want.clone();
    delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
        text_eq(v.get(rn_f), &dn) && matches!(v.get(ot_f), Some(Value::Int(9)))
    })?;
    advance_oldest_transactions(file, page_size)
}

/// A domain's `RDB$SECURITY_CLASS` off its `RDB$FIELDS` row (None if unset).
fn domain_security_class(file: &crate::Image, page_size: usize, dname: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$FIELD_NAME")?;
    let sc_f = fid("RDB$SECURITY_CLASS")?;
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), dname) {
            if let Some(Value::Text(t)) = v.get(sc_f) {
                out = Some(t.trim_end().to_string());
            }
        }
    });
    out
}

/// `ALTER DOMAIN <name> SET DEFAULT <lit>` / `DROP DEFAULT` - set (or
/// replace, or clear) the default on the domain's own `RDB$FIELDS` row. A
/// SET writes the two blobs a `CREATE DOMAIN ... DEFAULT` writes
/// (`RDB$DEFAULT_SOURCE`, subtype 1 charset 4; `RDB$DEFAULT_VALUE`, the BLR,
/// subtype 2) and patches them in; a DROP (`default` = None) patches both to
/// NULL, leaving any prior blob orphaned - exactly as the engine does. A
/// column that uses the domain without its own default sees the change on its
/// next insert.
pub fn alter_domain_default(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    default: Option<&ColumnDefault>,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.starts_with("RDB$") || want.starts_with("SQL$") {
        return Err("system domains are read-only".into());
    }
    if !domain_exists(file, page_size, &want) {
        return Err(format!("Domain {} not found", want));
    }
    let (src_val, val_val) = match default {
        Some(def) => {
            let src =
                dml::insert_blob_cs(file, page_size, 2, &[def.source.as_bytes().to_vec()], 1, 4)?;
            let val = dml::insert_blob(file, page_size, 2, &[def.value_blr.clone()], 2)?;
            (
                SysVal::B(blob_id_bytes(2, src)),
                SysVal::B(blob_id_bytes(2, val)),
            )
        }
        None => (SysVal::Null, SysVal::Null),
    };
    let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    let nm = want.clone();
    patch_sys_row(
        file,
        page_size,
        "RDB$FIELDS",
        2,
        move |v| text_eq(v.get(name_f), &nm),
        &[
            ("RDB$DEFAULT_SOURCE", src_val),
            ("RDB$DEFAULT_VALUE", val_val),
        ],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER DOMAIN <name> SET NOT NULL` / `DROP NOT NULL` - the nullability of a
/// domain, on its own `RDB$FIELDS` row. SET writes `RDB$NULL_FLAG` = 1, DROP
/// writes 0 (probe: a dropped constraint leaves the flag at 0, distinct from a
/// domain that never had one, whose flag is NULL). A column that uses the
/// domain inherits the constraint; the engine enforces it on the next insert.
///
/// This is the catalog write only: the engine additionally validates that no
/// existing row of any column using the domain is NULL before a SET, which an
/// offline writer over freshly-created (unused) domains never has to.
pub fn alter_domain_not_null(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    not_null: bool,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.starts_with("RDB$") || want.starts_with("SQL$") {
        return Err("system domains are read-only".into());
    }
    if !domain_exists(file, page_size, &want) {
        return Err(format!("Domain {} not found", want));
    }
    let flag: i64 = if not_null { 1 } else { 0 };
    let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    let nm = want.clone();
    patch_sys_row(
        file,
        page_size,
        "RDB$FIELDS",
        2,
        move |v| text_eq(v.get(name_f), &nm),
        &[("RDB$NULL_FLAG", SysVal::I(flag))],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `RDB$FIELD_TYPE` -> dsc dtype, for the int and text families
/// [type_change_supported] understands (enough to widen a domain).
pub fn field_type_to_dtype(ft: i16) -> Option<u8> {
    use crate::format::dtype;
    Some(match ft {
        7 => dtype::SHORT,
        8 => dtype::LONG,
        16 => dtype::INT64,
        26 => dtype::INT128,
        10 => dtype::REAL,
        27 => dtype::DOUBLE,
        12 => dtype::SQL_DATE,
        13 => dtype::SQL_TIME,
        35 => dtype::TIMESTAMP,
        23 => dtype::BOOLEAN,
        14 => dtype::TEXT,
        37 => dtype::VARYING,
        // blr_blob is 261 in the catalog (blr_blob = 261, blr.h), the
        // 8-byte id in the record; blr_quad the same width
        261 => dtype::BLOB,
        9 => dtype::QUAD,
        _ => return None,
    })
}

/// A domain's current `(field_type, byte length, scale, sub_type)` off its
/// `RDB$FIELDS` row.
pub fn domain_type_info(file: &crate::Image, page_size: usize, name: &str) -> Option<(i16, u16, i8, i16)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$FIELD_NAME")?;
    let ft_f = fid("RDB$FIELD_TYPE")?;
    let len_f = fid("RDB$FIELD_LENGTH")?;
    let sc_f = fid("RDB$FIELD_SCALE")?;
    let sub_f = fid("RDB$FIELD_SUB_TYPE")?;
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(name_f), name) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            out = Some((
                geti(ft_f) as i16,
                geti(len_f) as u16,
                geti(sc_f) as i8,
                geti(sub_f) as i16,
            ));
        }
    });
    out
}

/// A user domain's full resolved type, for a column declared with it. The
/// descriptor pieces (dtype, dsc_length, scale, sub_type, char_len), plus the
/// domain's own `NOT NULL` and `DEFAULT` (which a column of the domain
/// inherits) - read once off the domain's `RDB$FIELDS` row.
pub struct DomainType {
    pub field_type: i16,
    pub dtype: u8,
    pub length: u16,
    pub scale: i8,
    pub sub_type: i16,
    pub char_len: Option<u16>,
    pub not_null: bool,
    pub default_blr: Option<Vec<u8>>,
    pub validation_blr: Option<Vec<u8>>,
    /// an ARRAY domain's bounds (RDB$DIMENSIONS + RDB$FIELD_DIMENSIONS);
    /// empty for a scalar domain
    pub dims: Vec<(i32, i32)>,
}

/// The bounds of an ARRAY field's dimensions, in dimension order -
/// RDB$FIELD_DIMENSIONS (relation 21) for `fname`; empty for a scalar.
fn field_dimensions(file: &crate::Image, page_size: usize, fname: &str) -> Vec<(i32, i32)> {
    let Some(formats) = system_relation_formats(file, page_size, "RDB$FIELD_DIMENSIONS") else {
        return Vec::new();
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let cols = relation_columns(file, page_size, "RDB$FIELD_DIMENSIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(n_f), Some(d_f), Some(l_f), Some(u_f)) =
        (fid("RDB$FIELD_NAME"), fid("RDB$DIMENSION"), fid("RDB$LOWER_BOUND"), fid("RDB$UPPER_BOUND"))
    else {
        return Vec::new();
    };
    let mut dims: Vec<(i64, i32, i32)> = Vec::new();
    walk_rows(file, page_size, 21, descs, |v| {
        if text_eq(v.get(n_f), fname) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            dims.push((geti(d_f), geti(l_f) as i32, geti(u_f) as i32));
        }
    });
    dims.sort_by_key(|d| d.0);
    dims.into_iter().map(|d| (d.1, d.2)).collect()
}

/// The database's DEFAULT CHARACTER SET, by name, out of RDB$DATABASE
/// (`RDB$CHARACTER_SET_NAME`). It is what every text or text-blob
/// column declared WITHOUT a `CHARACTER SET` clause takes - the engine
/// resolves the default at CREATE time and writes the resolved id into
/// the column's catalog row, so a file created in a UTF8 database has
/// UTF8 columns and four times the declared byte length.
pub fn database_charset_name(file: &crate::Image, page_size: usize) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$DATABASE")?;
    let formats = system_relation_formats(file, page_size, "RDB$DATABASE")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$DATABASE");
    let cs_f = cols
        .iter()
        .find(|c| c.name == "RDB$CHARACTER_SET_NAME")
        .map(|c| c.field_id as usize)?;
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if let Some(Value::Text(t)) = v.get(cs_f) {
            let t = t.trim();
            if !t.is_empty() {
                out = Some(t.to_string());
            }
        }
    });
    out
}

/// A domain's `RDB$CHARACTER_SET_ID` (None when SQL NULL - non-text
/// types) - the one type fact [domain_type_info] does not carry, needed
/// to gate a text-domain CHECK compile to the NONE charset the stored
/// literal shape is pinned for.
pub fn domain_charset_id(file: &crate::Image, page_size: usize, name: &str) -> Option<i64> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$FIELD_NAME")?;
    let cs_f = fid("RDB$CHARACTER_SET_ID")?;
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(name_f), name) {
            if let Some(Value::Int(i)) = v.get(cs_f) {
                out = Some(*i);
            }
        }
    });
    out
}

fn resolve_domain_type(file: &crate::Image, page_size: usize, dname: &str) -> Option<DomainType> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_f = fid("RDB$FIELD_NAME")?;
    let ft_f = fid("RDB$FIELD_TYPE")?;
    let len_f = fid("RDB$FIELD_LENGTH")?;
    let sc_f = fid("RDB$FIELD_SCALE")?;
    let sub_f = fid("RDB$FIELD_SUB_TYPE")?;
    let cl_f = fid("RDB$CHARACTER_LENGTH");
    let nf_f = fid("RDB$NULL_FLAG");
    let dv_f = fid("RDB$DEFAULT_VALUE");
    let vb_f = fid("RDB$VALIDATION_BLR");
    let dim_f = fid("RDB$DIMENSIONS");
    #[allow(clippy::type_complexity)]
    let mut found: Option<(
        i16,
        u16,
        i8,
        i16,
        Option<u16>,
        bool,
        Option<(u16, u64)>,
        Option<(u16, u64)>,
        i64,
    )> = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_none() && text_eq(v.get(name_f), dname) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            let char_len = cl_f.and_then(|f| match v.get(f) {
                Some(Value::Int(i)) => Some(*i as u16),
                _ => None,
            });
            let not_null = nf_f.map_or(false, |f| matches!(v.get(f), Some(Value::Int(1))));
            let def = dv_f.and_then(|f| match v.get(f) {
                Some(Value::Blob(r, n)) => Some((*r, *n)),
                _ => None,
            });
            let vblr = vb_f.and_then(|f| match v.get(f) {
                Some(Value::Blob(r, n)) => Some((*r, *n)),
                _ => None,
            });
            found = Some((
                geti(ft_f) as i16,
                geti(len_f) as u16,
                geti(sc_f) as i8,
                geti(sub_f) as i16,
                char_len,
                not_null,
                def,
                vblr,
                dim_f.map_or(0, geti),
            ));
        }
    });
    let (field_type, byte_len, scale, sub_type, char_len, not_null, def, vblr, ndims) = found?;
    let dims = if ndims > 0 { field_dimensions(file, page_size, dname) } else { Vec::new() };
    let dtype = field_type_to_dtype(field_type)?;
    // dsc_length: a VARYING carries its 2-byte count word, other types do not
    let length = if dtype == crate::format::dtype::VARYING {
        byte_len + 2
    } else {
        byte_len
    };
    let default_blr = def.and_then(|(r, n)| crate::format::read_blob_content(file, page_size, r, n));
    let validation_blr =
        vblr.and_then(|(r, n)| crate::format::read_blob_content(file, page_size, r, n));
    Some(DomainType {
        field_type,
        dtype,
        length,
        scale,
        sub_type,
        char_len,
        not_null,
        default_blr,
        validation_blr,
        dims,
    })
}

/// `ALTER DOMAIN <name> TYPE <newtype>` - retype a domain in place on its
/// `RDB$FIELDS` row (`RDB$FIELD_TYPE` / `LENGTH` / `SCALE` / `SUB_TYPE`, and
/// `RDB$CHARACTER_LENGTH` for text). Only a widening this write path performs
/// (see [type_change_supported]) - a SMALLINT to a wider integer, a CHAR or
/// VARCHAR to a same-or-longer one; a narrowing errors, as the engine's does
/// ("must be at least N characters"). This is the unused-domain case:
/// fire-crab does not yet declare a domain-typed column, so there is no table
/// format to carry along.
pub fn alter_domain_type(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    new_col: &ColumnDef,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.starts_with("RDB$") || want.starts_with("SQL$") {
        return Err("system domains are read-only".into());
    }
    let (old_ft, old_len, old_scale, old_sub) = domain_type_info(file, page_size, &want)
        .ok_or_else(|| format!("Domain {} not found", want))?;
    let old_dtype = field_type_to_dtype(old_ft)
        .ok_or("the domain's current type is not one this path retypes")?;
    // the old descriptor, in the same length convention new_col uses
    // (a VARYING's dsc_length carries the 2-byte count word)
    let old_dsc_len = if old_dtype == crate::format::dtype::VARYING {
        old_len + 2
    } else {
        old_len
    };
    let old_desc = Descriptor {
        dtype: old_dtype,
        scale: old_scale,
        length: old_dsc_len,
        sub_type: old_sub,
        flags: 0,
        offset: 0,
    };
    if !type_change_supported(&old_desc, new_col) {
        return Err(format!(
            "cannot change datatype for domain {}; conversion not supported",
            want
        ));
    }
    // the dependents guard, before any write. The engine's rule
    // (probed): a dependent column inside a FOREIGN KEY index refuses -
    // "Cannot modify index used by an Integrity Constraint" - while
    // PK/UNIQUE and plain-indexed dependents retype fine, each
    // dependent TABLE getting one new format version below.
    let deps = domain_dependents(file, page_size, &want)?;
    for (t, c) in &deps {
        if indices_containing(file, page_size, t, c)?.iter().any(|(_, fk)| *fk) {
            return Err("Cannot modify index used by an Integrity Constraint".into());
        }
    }
    // group the dependents by table and resolve their field ids now
    // (pure reads) - any unresolvable dependent refuses before a write
    let mut by_table: Vec<(String, Vec<usize>)> = Vec::new();
    for (t, c) in &deps {
        let cols = relation_columns(file, page_size, t);
        let fid = cols
            .iter()
            .find(|rc| rc.name.eq_ignore_ascii_case(c))
            .map(|rc| rc.field_id as usize)
            .ok_or_else(|| format!("dependent column {}.{} not found", t, c))?;
        match by_table.iter_mut().find(|(name, _)| name == t) {
            Some((_, fids)) => fids.push(fid),
            None => by_table.push((t.clone(), vec![fid])),
        }
    }
    // patch the domain's RDB$FIELDS row in place (mirror of the column
    // ALTER TYPE retype, minus the table format/runtime it does not have)
    let f_cols = relation_columns(file, page_size, "RDB$FIELDS");
    let f_fid = |n: &str| f_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let f_name_fid = f_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let dom_pred = {
        let dom = want.clone();
        move |vals: &[Value]| text_eq(vals.get(f_name_fid), &dom)
    };
    let (fpage, fslot) = find_sys_row_slot(file, page_size, "RDB$FIELDS", 2, dom_pred)
        .ok_or("RDB$FIELDS domain row not found")?;
    let f_formats =
        system_relation_formats(file, page_size, "RDB$FIELDS").ok_or("no RDB$FIELDS format")?;
    let (f_format_no, f_descs) = {
        let (n, d) = f_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let mut f_image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, fpage).ok_or("bad page")?)
            .ok_or("bad data page")?;
        dp.record(fslot)
            .and_then(|r| r.image())
            .ok_or("no field image")?
    };
    let patch_field = |image: &mut [u8], nm: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = f_fid(nm).ok_or_else(|| format!("no {} column", nm))?;
        let d = f_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    patch_field(&mut f_image, "RDB$FIELD_TYPE", SysVal::I(new_col.field_type as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(new_col)))?;
    patch_field(&mut f_image, "RDB$FIELD_SCALE", SysVal::I(new_col.scale as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_SUB_TYPE", SysVal::I(new_col.sub_type as i64))?;
    if let Some(p) = new_col.precision {
        // the engine retypes precision too (probed: INTEGER ->
        // NUMERIC(12) sets 12; int -> int keeps 0)
        patch_field(&mut f_image, "RDB$FIELD_PRECISION", SysVal::I(p as i64))?;
    }
    if let Some(cl) = new_col.char_len {
        patch_field(&mut f_image, "RDB$CHARACTER_LENGTH", SysVal::I(cl as i64))?;
    }
    dml::update_records(file, page_size, 2, &[(fpage, fslot, f_image)], f_format_no)?;
    // every dependent table gets ONE new format version with all its
    // domain-typed fields retyped (probed: one bump per table per
    // statement, old rows read back promoted)
    for (t, fids) in &by_table {
        reformat_for_retype(file, page_size, t, fids, new_col)?;
    }
    advance_oldest_transactions(file, page_size)
}

/// `ALTER TABLE <table> DROP <column>`: remove a column. Like ADD, this is
/// a new *format version* - existing records keep their old format (and
/// still carry the dropped field's bytes, now unreferenced); the new
/// format keeps the field-id indexing (the survivors are NOT renumbered -
/// probe: dropping the middle of A/B/C leaves A=id0, C=id2, a hole at 1)
/// but replaces the dropped field's descriptor with a zero-length
/// placeholder and repacks the rest. The column's `RDB$RELATION_FIELDS`
/// row and its auto-domain are deleted, `RDB$RUNTIME` is rebuilt without
/// it, and `RDB$RELATIONS.RDB$FORMAT` is bumped (the field-id high-water,
/// `RDB$FIELD_ID`, is left as-is - the engine does not reuse ids).
///
/// This first slice drops a plain nullable, unindexed column; a NOT NULL
/// column, an indexed/key column, or the table's only column each error
/// (they need constraint or index teardown first).
pub fn alter_table_drop_column(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let col_up = col_name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;

    let cols = relation_columns(file, page_size, &table);
    let target = cols
        .iter()
        .find(|c| c.name == col_up)
        .ok_or_else(|| format!("column {} not found", col_name))?;
    let drop_fid = target.field_id as usize;
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let is_computed =
        |fid: usize| matches!(cur_descs.get(fid), Some(d) if d.offset == 0 && d.length != 0);
    // the engine refuses a drop that leaves no STORED column - "can't
    // have relation with only computed fields or constraints" (probed;
    // subsumes the old only-column check)
    let stored_left = cols
        .iter()
        .filter(|c| c.field_id as usize != drop_fid && !is_computed(c.field_id as usize))
        .count();
    if stored_left == 0 {
        return Err("cannot drop: a table cannot have only computed fields".into());
    }
    // a stored column some computed expression references cannot go -
    // the engine counts dependencies and refuses (probed). An expression
    // whose BLR this writer cannot read is assumed to reference anything.
    if !is_computed(drop_fid) {
        for (cname, deps) in computed_dependencies(file, page_size, &table) {
            let depends = match deps {
                None => true,
                Some(names) => names.iter().any(|n| *n == col_up),
            };
            if depends {
                return Err(format!(
                    "cannot drop {}: computed column {} depends on it",
                    col_name, cname
                ));
            }
        }
    }
    // an indexed/key column would leave a dangling index - reject it
    if let Some(irt) = find_index_root(file, page_size, rel) {
        for e in irt.live_entries() {
            let (segs, _) =
                btw::index_segments(file, page_size, rel, e.id, e.key_count as usize)
                    .ok_or("unreadable index segments")?;
            if segs.iter().any(|(field, _)| *field as usize == drop_fid) {
                return Err(format!("column {} is indexed; drop the index first", col_name));
            }
        }
    }

    // the column's RDB$RELATION_FIELDS row: its slot, domain, null flag
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let rf_rel = rf_fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let rf_name = rf_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let rf_src = rf_fid("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let rf_null = rf_fid("RDB$NULL_FLAG");
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let matches_col = |vals: &[Value]| {
        text(vals.get(rf_rel)).as_deref() == Some(table.as_str())
            && text(vals.get(rf_name)).as_deref() == Some(col_up.as_str())
    };
    // read the domain + null flag before deleting the row
    let mut domain: Option<String> = None;
    let mut not_null = false;
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if matches_col(vals) {
            domain = text(vals.get(rf_src));
            if let Some(nf) = rf_null {
                not_null = matches!(vals.get(nf), Some(Value::Int(1)));
            }
        }
    });
    if not_null {
        return Err(format!("column {} is NOT NULL; not supported", col_name));
    }

    // the new format version: existing descriptors, the dropped field
    // replaced by a zero-length placeholder, the rest repacked. A
    // surviving COMPUTED field keeps its offset-0 descriptor (the walk
    // skips it); dropping the computed field itself leaves the same
    // all-zero placeholder a stored field would.
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    fields[drop_fid] = (0, 0, 0, 0, false); // dropped-field placeholder
    let mut new_descs = compute_format_mixed(&fields);
    // the placeholder itself is all-zero at offset 0 (dfw.epp), matching
    // the engine's format blob for a dropped field
    new_descs[drop_fid] = Descriptor {
        dtype: 0,
        scale: 0,
        length: 0,
        sub_type: 0,
        flags: 0,
        offset: 0,
    };
    // ... except at the TAIL: the engine truncates trailing dropped
    // placeholders from the new format (probed: dropping the LAST field
    // shrinks the descriptor count; only a mid-table hole keeps its
    // placeholder). RDB$RELATIONS.RDB$FIELD_ID - the next-id counter -
    // stays where it was either way.
    while matches!(new_descs.last(), Some(d) if d.dtype == 0 && d.length == 0) {
        new_descs.pop();
    }

    // current format number, for the bump
    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, &table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field = |name: &str| rel_cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let cur_vals = decode_record(&rel_image, rel_descs);
    let cur_format_no = match cur_vals.get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?) {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    // --- new format blob + RDB$FORMATS row ----------------------------
    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;

    // --- delete the column's RDB$RELATION_FIELDS row and its domain ---
    let rf_slot = find_sys_row_slot(file, page_size, "RDB$RELATION_FIELDS", 5, matches_col)
        .ok_or("RDB$RELATION_FIELDS row not found")?;
    dml::delete_records(file, page_size, 5, &[rf_slot])?;
    if let Some(dom) = &domain {
        let dom_pred = |vals: &[Value]| {
            let f_fid = relation_columns(file, page_size, "RDB$FIELDS")
                .iter()
                .find(|c| c.name == "RDB$FIELD_NAME")
                .map(|c| c.field_id as usize);
            f_fid.and_then(|f| text(vals.get(f))).as_deref() == Some(dom.as_str())
        };
        if let Some(slot) = find_sys_row_slot(file, page_size, "RDB$FIELDS", 2, dom_pred) {
            dml::delete_records(file, page_size, 2, &[slot])?;
        }
    }

    // --- rebuild RDB$RUNTIME (now omits the dropped field) ------------
    let runtime = rebuild_runtime_blob(file, page_size, &table, &new_descs)?;

    // --- bump RDB$RELATIONS.RDB$FORMAT and RDB$RUNTIME (field-id high-
    // water is left as-is: the engine does not reuse dropped ids) ------
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    let old_rt = rel_field("RDB$RUNTIME").and_then(|f| old_blob_at(&rel_image, rel_descs, f));
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(file, page_size, 6, &[(rel_page, rel_slot, rel_image)], rec_format)?;
    if let Some((orel, onum)) = old_rt {
        dispose_superseded_blob(file, page_size, orel, onum);
        dispose_row_purge(file, page_size, 6, rel_page, rel_slot);
    }

    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// The storage width of an integer dtype, for the widening check.
fn int_width(dt: u8) -> Option<u16> {
    use crate::format::dtype;
    match dt {
        dtype::SHORT => Some(2),
        dtype::LONG => Some(4),
        dtype::INT64 => Some(8),
        dtype::INT128 => Some(16),
        _ => None,
    }
}

/// Whether changing a column from `old` to `new` is a conversion this
/// write path performs. Deliberately a SUBSET of what the engine allows -
/// only clearly loss-free widenings, so fire-crab never *succeeds* where
/// the engine would reject (narrowing). An integer widens to a wider
/// integer (scale 0), a CHAR/VARCHAR widens to a same-or-longer one of
/// the same kind. Everything else errors, as the engine does for an
/// unsupported conversion.
/// The indices of `table` that have `col` among their segments, each as
/// (index name, is-a-FOREIGN-KEY index - its RDB$FOREIGN_KEY names a
/// partner).
fn indices_containing(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    col: &str,
) -> Result<Vec<(String, bool)>, String> {
    let irel =
        crate::resolve_relation(file, page_size, "RDB$INDICES").ok_or("no RDB$INDICES")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let ix_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let rn_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$RELATION_NAME")?;
    let fk_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$FOREIGN_KEY")?;
    let mut names: Vec<(String, bool)> = Vec::new();
    walk_rows(file, page_size, irel, descs, |values| {
        if text_is(values.get(rn_f), table) {
            if let Some(Value::Text(t)) = values.get(ix_f) {
                let fk = matches!(values.get(fk_f),
                    Some(Value::Text(p)) if !p.trim_end().is_empty());
                names.push((t.trim_end().to_string(), fk));
            }
        }
    });
    let mut out = Vec::new();
    for (n, fk) in names {
        if index_segment_columns(file, page_size, &n)?
            .iter()
            .any(|c| c == col)
        {
            out.push((n, fk));
        }
    }
    Ok(out)
}

/// TRUE when `col` is a segment of an index that an
/// `RDB$RELATION_CONSTRAINTS` row names - a PRIMARY KEY / UNIQUE /
/// FOREIGN KEY enforcement index. The engine refuses retyping such a
/// column: "Cannot update index segment used by an Integrity
/// Constraint" (probed: PK, UNIQUE-constraint and FK-child segments all
/// refuse, ANY segment of a multi-column key included, while a plain
/// CREATE INDEX column retypes fine).
fn column_in_constraint_index(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    col: &str,
) -> Result<bool, String> {
    let mine: Vec<String> = indices_containing(file, page_size, table, col)?
        .into_iter()
        .map(|(n, _)| n)
        .collect();
    if mine.is_empty() {
        return Ok(false);
    }
    // ...and whether any of those backs a constraint
    let crel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")
        .ok_or("no RDB$RELATION_CONSTRAINTS")?;
    let cformats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")
        .ok_or("no RDB$RELATION_CONSTRAINTS format")?;
    let (_, cdescs) = cformats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cix_f = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$INDEX_NAME")?;
    let mut hit = false;
    walk_rows(file, page_size, crel, cdescs, |values| {
        if let Some(Value::Text(t)) = values.get(cix_f) {
            let t = t.trim_end();
            if mine.iter().any(|m| m == t) {
                hit = true;
            }
        }
    });
    Ok(hit)
}

fn type_change_supported(old: &Descriptor, new: &ColumnDef) -> bool {
    use crate::format::dtype;
    // integer family: same or wider, both scale 0
    if let (Some(ow), Some(nw)) = (int_width(old.dtype), int_width(new.dtype)) {
        return old.scale == 0 && new.scale == 0 && nw >= ow;
    }
    // text: same kind (CHAR or VARCHAR), same or longer
    match (old.dtype, new.dtype) {
        (dtype::TEXT, dtype::TEXT) | (dtype::VARYING, dtype::VARYING) => new.length >= old.length,
        _ => false,
    }
}

/// `ALTER TABLE <table> ALTER <column> TYPE <newtype>`: change a column's
/// type. Like ADD and DROP, a new *format version* - existing records keep
/// their old format (and their old-width value, which reads back promoted:
/// an `INTEGER` stored 4 bytes reads as the new `BIGINT`); new records use
/// the new format. The column keeps its field id, position and domain
/// name; the domain's `RDB$FIELDS` row is retyped IN PLACE (the engine does
/// the same - probe: `RDB$1` changed from type 8/len 4 to type 16/len 8),
/// `RDB$RUNTIME` is rebuilt for the new length, and `RDB$RELATIONS.RDB$FORMAT`
/// is bumped. Only a widening conversion (see [type_change_supported]) is
/// performed; anything else errors.
pub fn alter_table_alter_column_type(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
    new_col: &ColumnDef,
) -> Result<(), String> {
    // ARRAY columns are taken at CREATE TABLE only: an ALTER would have to
    // write the dimension rows too, and today it does not (recorded)
    if !new_col.dims.is_empty() {
        return Err("an ARRAY column can only be declared at CREATE TABLE".into());
    }
    let table = table.trim().to_string();
    let col_up = col_name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;

    let cols = relation_columns(file, page_size, &table);
    let target = cols
        .iter()
        .find(|c| c.name == col_up)
        .ok_or_else(|| format!("column {} not found", col_name))?;
    let fid = target.field_id as usize;

    // the current descriptors, and the conversion check against the field's
    // existing descriptor
    let cur_formats = crate::relation_formats(file, page_size, rel);
    let (_, cur_descs) = cur_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let old_desc = cur_descs.get(fid).ok_or("field beyond format")?;
    if !type_change_supported(old_desc, new_col) {
        return Err(format!(
            "cannot change datatype for {}; conversion not supported",
            col_name
        ));
    }
    // a column whose index enforces a PRIMARY KEY / UNIQUE / FOREIGN KEY
    // cannot be retyped - the engine's own refusal, mirrored
    if column_in_constraint_index(file, page_size, &table, &col_up)? {
        return Err(format!(
            "Cannot update index segment used by an Integrity Constraint ({})",
            col_up
        ));
    }

    // a computed column's type is its expression's - "cannot add or
    // remove COMPUTED from column" (probed refusal). Retyping a STORED
    // column is allowed even when a computed expression references it:
    // the engine keeps the computed column's declared type UNCHANGED
    // (probed: A INTEGER -> BIGINT leaves C COMPUTED BY (A) a LONG).
    if matches!(cur_descs.get(fid), Some(d) if d.offset == 0 && d.length != 0) {
        return Err(format!("cannot change the type of computed column {}", col_up));
    }
    // the new format: the target field's descriptor replaced, all
    // repacked; a COMPUTED field keeps its offset-0 descriptor
    let mut fields: Vec<(u8, u16, i8, i16, bool)> = descs_to_fields(cur_descs)
        .into_iter()
        .zip(cur_descs.iter())
        .map(|((dt, l, s, st), d)| (dt, l, s, st, d.offset == 0 && d.length != 0))
        .collect();
    let (dt, l, s, st) = col_field_of(new_col);
    fields[fid] = (dt, l, s, st, false);
    let new_descs = compute_format_mixed(&fields);

    // the column's domain (RDB$FIELD_SOURCE) - retyped in place
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let rf_rel = rf_fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let rf_name = rf_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let rf_src = rf_fid("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let mut domain: Option<String> = None;
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if text(vals.get(rf_rel)).as_deref() == Some(table.as_str())
            && text(vals.get(rf_name)).as_deref() == Some(col_up.as_str())
        {
            domain = text(vals.get(rf_src));
        }
    });
    let domain = domain.ok_or("column domain not found")?;

    // current format number
    let (rel_page, rel_slot, mut rel_image, rec_format) =
        find_relations_row(file, page_size, &table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let rel_field = |name: &str| rel_cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
    let cur_format_no = match decode_record(&rel_image, rel_descs)
        .get(rel_field("RDB$FORMAT").ok_or("no RDB$FORMAT")?)
    {
        Some(Value::Int(n)) => *n,
        _ => return Err("RDB$FORMAT unreadable".into()),
    };
    let new_format_no = cur_format_no + 1;

    // --- new format blob + RDB$FORMATS row ----------------------------
    let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;

    // --- retype the domain's RDB$FIELDS row in place ------------------
    let f_cols = relation_columns(file, page_size, "RDB$FIELDS");
    let f_fid = |n: &str| f_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let f_name_fid = f_fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let dom_pred = {
        let dom = domain.clone();
        move |vals: &[Value]| text(vals.get(f_name_fid)).as_deref() == Some(dom.as_str())
    };
    let (fpage, fslot) = find_sys_row_slot(file, page_size, "RDB$FIELDS", 2, dom_pred)
        .ok_or("RDB$FIELDS domain row not found")?;
    let f_formats =
        system_relation_formats(file, page_size, "RDB$FIELDS").ok_or("no RDB$FIELDS format")?;
    let (f_format_no, f_descs) = {
        let (n, d) = f_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let mut f_image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, fpage).ok_or("bad page")?)
            .ok_or("bad data page")?;
        // `image()`, NOT `assembled_image` - ON PURPOSE. This reads a
        // record it is about to REWRITE IN PLACE, and a fragmented one
        // cannot be rewritten in place: its bytes live on several pages
        // and the pieces would have to be re-split. `image()` answers
        // None for a fragmented record, so this errors out instead of
        // patching the head and leaving the tail describing the old
        // shape. Refusing is the boundary; the other patch sites in this
        // file are the same, and the roadmap names them.
        dp.record(fslot).and_then(|r| r.image()).ok_or("no field image")?
    };
    let patch_field = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = f_fid(name).ok_or_else(|| format!("no {} column", name))?;
        let d = f_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    patch_field(&mut f_image, "RDB$FIELD_TYPE", SysVal::I(new_col.field_type as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_LENGTH", SysVal::I(new_col.length as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_SCALE", SysVal::I(new_col.scale as i64))?;
    patch_field(&mut f_image, "RDB$FIELD_SUB_TYPE", SysVal::I(new_col.sub_type as i64))?;
    if let Some(p) = new_col.precision {
        // the engine retypes precision too (probed: INTEGER ->
        // NUMERIC(12) sets 12; int -> int keeps 0)
        patch_field(&mut f_image, "RDB$FIELD_PRECISION", SysVal::I(p as i64))?;
    }
    if let Some(cl) = new_col.char_len {
        patch_field(&mut f_image, "RDB$CHARACTER_LENGTH", SysVal::I(cl as i64))?;
    }
    dml::update_records(file, page_size, 2, &[(fpage, fslot, f_image)], f_format_no)?;

    // --- rebuild RDB$RUNTIME (the field's length changed) -------------
    let runtime = rebuild_runtime_blob(file, page_size, &table, &new_descs)?;

    // --- bump RDB$RELATIONS.RDB$FORMAT and RDB$RUNTIME ----------------
    let patch = |image: &mut [u8], name: &str, v: SysVal<'_>| -> Result<(), String> {
        let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
        let d = rel_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8));
        Ok(())
    };
    let old_rt = rel_field("RDB$RUNTIME").and_then(|f| old_blob_at(&rel_image, rel_descs, f));
    patch(&mut rel_image, "RDB$FORMAT", SysVal::I(new_format_no))?;
    patch(&mut rel_image, "RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))?;
    dml::update_records(file, page_size, 6, &[(rel_page, rel_slot, rel_image)], rec_format)?;
    if let Some((orel, onum)) = old_rt {
        dispose_superseded_blob(file, page_size, orel, onum);
        dispose_row_purge(file, page_size, 6, rel_page, rel_slot);
    }

    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> SET DEFAULT <lit>` / `DROP DEFAULT` -
/// set, replace, or clear a column's default. Two blobs on the column's
/// `RDB$RELATION_FIELDS` row (`RDB$DEFAULT_SOURCE`, subtype 1 charset 4;
/// `RDB$DEFAULT_VALUE`, the literal BLR, subtype 2), then the relation's
/// `RDB$RUNTIME` is rebuilt so the engine applies (or stops applying) it -
/// the default the engine reads lives in that summary, not in the catalog
/// column ([rebuild_runtime_blob] re-reads `RDB$DEFAULT_VALUE`). No new
/// format version (the probe shows `RDB$FORMAT` unchanged); the row layout
/// does not move.
pub fn alter_column_default(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    default: Option<&ColumnDefault>,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let column = column.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let col_fid = relation_columns(file, page_size, &table)
        .iter()
        .find(|c| c.name == column)
        .map(|c| c.field_id)
        .ok_or_else(|| format!("column {} not found in table {}", column, table))?;
    // the engine refuses a default change on a column inside a FOREIGN
    // KEY index ("cannot modify index used by an integrity constraint",
    // probed - a SET DEFAULT referential action reads the default
    // through that index's constraint; PK, UNIQUE and plain-indexed
    // columns all accept the change)
    if let Some(irt) = find_index_root(file, page_size, rel) {
        for e in irt.live_entries() {
            if e.flags & btw::IRT_FOREIGN == 0 {
                continue;
            }
            let (segs, _) = btw::index_segments(file, page_size, rel, e.id, e.key_count as usize)
                .ok_or("unreadable index segments")?;
            if segs.iter().any(|(field, _)| *field == col_fid) {
                return Err(format!(
                    "column {} is part of a FOREIGN KEY - its default cannot change",
                    column
                ));
            }
        }
    }
    let (src_val, val_val) = match default {
        Some(def) => {
            let src =
                dml::insert_blob_cs(file, page_size, 5, &[def.source.as_bytes().to_vec()], 1, 4)?;
            let val = dml::insert_blob(file, page_size, 5, &[def.value_blr.clone()], 2)?;
            (
                SysVal::B(blob_id_bytes(5, src)),
                SysVal::B(blob_id_bytes(5, val)),
            )
        }
        None => (SysVal::Null, SysVal::Null),
    };
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, c) = (table.clone(), column.clone());
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        5,
        move |v| text_is(v.get(rel_fid), &t) && text_is(v.get(name_fid), &c),
        &[
            ("RDB$DEFAULT_SOURCE", src_val),
            ("RDB$DEFAULT_VALUE", val_val),
        ],
    )?;
    // rebuild the runtime so the engine applies (or stops applying) the default
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// The identity generator backing a column - its `RDB$GENERATOR_NAME` when
/// `RDB$IDENTITY_TYPE` is set - or None if the column is not an identity column.
fn column_identity_generator(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rel_f, name_f, gen_f, idt_f) = (
        fid("RDB$RELATION_NAME")?,
        fid("RDB$FIELD_NAME")?,
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$IDENTITY_TYPE")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_is(v.get(rel_f), table) && text_is(v.get(name_f), column) {
            if matches!(v.get(idt_f), Some(Value::Int(_))) {
                if let Some(Value::Text(g)) = v.get(gen_f) {
                    out = Some(g.trim_end().to_string());
                }
            }
        }
    });
    out
}

/// A generator's `(RDB$GENERATOR_ID, RDB$GENERATOR_INCREMENT,
/// RDB$INITIAL_VALUE)`.
fn generator_incr_init(file: &crate::Image, page_size: usize, name: &str) -> Option<(i64, i64, i64)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")?;
    let formats = system_relation_formats(file, page_size, "RDB$GENERATORS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$GENERATORS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f, inc_f, init_f) = (
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$GENERATOR_ID")?,
        fid("RDB$GENERATOR_INCREMENT")?,
        fid("RDB$INITIAL_VALUE")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), name) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            out = Some((geti(id_f), geti(inc_f), geti(init_f)));
        }
    });
    out
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> RESTART [WITH <n>]` - reposition an
/// identity column's generator. `RESTART WITH n` primes it to yield `n` next
/// (stored `n - increment`); a bare `RESTART` uses the generator's
/// `RDB$INITIAL_VALUE`. Neither changes the catalog (`RDB$INITIAL_VALUE` and
/// the increment stay); only the generator's stored value moves.
pub fn alter_column_restart(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    with_value: Option<i64>,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let column = column.trim().to_string();
    let gen = column_identity_generator(file, page_size, &table, &column)
        .ok_or_else(|| format!("column {} is not an identity column", column))?;
    let (id, increment, initial) = generator_incr_init(file, page_size, &gen)
        .ok_or_else(|| format!("identity generator {} not found", gen))?;
    let target = with_value.unwrap_or(initial);
    gen::write(file, page_size, id, target.wrapping_sub(increment))?;
    advance_oldest_transactions(file, page_size)
}

/// The DEFERRED half of `ALTER TABLE ... ALTER COLUMN ... RESTART`:
/// resolve the identity column's backing generator and the value the
/// restart stores (`target - increment`), WITHOUT writing the slot -
/// the caller posts it to its transaction cache and the page learns it
/// at COMMIT, the way the engine's dfw_set_generator does. The
/// statement's header bookkeeping (the OIT advance) still lands here.
pub fn column_restart_posting(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    with_value: Option<i64>,
) -> Result<(String, i64), String> {
    let table = table.trim().to_string();
    let column = column.trim().to_string();
    let gen = column_identity_generator(file, page_size, &table, &column)
        .ok_or_else(|| format!("column {} is not an identity column", column))?;
    let (_id, increment, initial) = generator_incr_init(file, page_size, &gen)
        .ok_or_else(|| format!("identity generator {} not found", gen))?;
    let target = with_value.unwrap_or(initial);
    advance_oldest_transactions(file, page_size)?;
    Ok((gen, target.wrapping_sub(increment)))
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> SET GENERATED { ALWAYS | BY DEFAULT }` -
/// change an identity column's `RDB$IDENTITY_TYPE` (0 ALWAYS / 1 BY DEFAULT).
/// The generator and its value are untouched; the relation's `RDB$RUNTIME` is
/// rebuilt so the runtime's identity-type segment (23) follows.
pub fn alter_column_set_generated(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    identity_type: i16,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let column = column.trim().to_string();
    if column_identity_generator(file, page_size, &table, &column).is_none() {
        return Err(format!("column {} is not an identity column", column));
    }
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, c) = (table.clone(), column.clone());
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        5,
        move |v| text_is(v.get(rel_fid), &t) && text_is(v.get(name_fid), &c),
        &[("RDB$IDENTITY_TYPE", SysVal::I(identity_type as i64))],
    )?;
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> DROP IDENTITY` - make an identity
/// column an ordinary one. The column's `RDB$IDENTITY_TYPE` and
/// `RDB$GENERATOR_NAME` are cleared (its `RDB$NULL_FLAG` stays - the column
/// remains NOT NULL), the implicit generator and its security class and
/// privilege rows are dropped, and the runtime is rebuilt (which drops the
/// identity segments 22/23 but keeps the not-null, since the RF row still
/// carries the flag).
pub fn alter_column_drop_identity(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let column = column.trim().to_string();
    let gen = column_identity_generator(file, page_size, &table, &column)
        .ok_or_else(|| format!("column {} is not an identity column", column))?;
    let class = find_generator(file, page_size, &gen).and_then(|(_, _, c)| c);
    // clear the column's identity metadata (leave RDB$NULL_FLAG as-is)
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, c) = (table.clone(), column.clone());
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        5,
        move |v| text_is(v.get(rel_fid), &t) && text_is(v.get(name_fid), &c),
        &[
            ("RDB$IDENTITY_TYPE", SysVal::Null),
            ("RDB$GENERATOR_NAME", SysVal::Null),
        ],
    )?;
    // drop the generator, its security class and its privilege rows
    let gname_f = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_NAME")?;
    let g = gen.clone();
    delete_catalog_rows(file, page_size, "RDB$GENERATORS", move |v| {
        text_eq(v.get(gname_f), &g)
    })?;
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
    let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
    let g2 = gen.clone();
    delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
        text_eq(v.get(rn_f), &g2) && matches!(v.get(ot_f), Some(Value::Int(14)))
    })?;
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER TABLE <t> ALTER [COLUMN] <c> POSITION <n>` - move a column to the
/// 1-based display position `n`. Only `RDB$FIELD_POSITION` moves (and the
/// runtime's positions follow); the field ids, the record format and the
/// stored bytes are untouched - reordering is a display change, not a storage
/// one.
pub fn alter_column_position(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
    new_pos: i64,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let column = column.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let cols = relation_columns(file, page_size, &table);
    let ncols = cols.len();
    // the engine errors on a position below 1, but a position past the last
    // column is clamped to the last (the column moves to the end)
    if new_pos < 1 {
        return Err(format!("column position {} is out of range", new_pos));
    }
    let to = ((new_pos - 1) as usize).min(ncols - 1);
    // the current order, by position; move the target to `to`
    let mut order: Vec<(String, u16)> =
        cols.iter().map(|c| (c.name.clone(), c.position)).collect();
    order.sort_by_key(|(_, p)| *p);
    let from = order
        .iter()
        .position(|(n, _)| *n == column)
        .ok_or_else(|| format!("column {} not found in table {}", column, table))?;
    if from == to {
        return advance_oldest_transactions(file, page_size);
    }
    let item = order.remove(from);
    order.insert(to, item);
    // patch the RDB$FIELD_POSITION of each column whose position moved
    let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    for (new_p, (name, old_p)) in order.iter().enumerate() {
        if new_p as u16 == *old_p {
            continue;
        }
        let (t, c) = (table.clone(), name.clone());
        patch_sys_row(
            file,
            page_size,
            "RDB$RELATION_FIELDS",
            5,
            move |v| text_is(v.get(rel_fid), &t) && text_is(v.get(name_fid), &c),
            &[("RDB$FIELD_POSITION", SysVal::I(new_p as i64))],
        )?;
    }
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)
}

/// Whether any committed primary record of `rel` has a NULL in field
/// `fid` - the check `SET NOT NULL` makes before it can succeed.
fn column_has_nulls(file: &crate::Image, page_size: usize, rel: u16, fid: usize) -> bool {
    let formats = crate::relation_formats(file, page_size, rel);
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            let descs = formats
                .iter()
                .find(|(n, _)| *n == r.format)
                .or_else(|| formats.iter().max_by_key(|(n, _)| *n));
            let Some((_, descs)) = descs else { continue };
            let vals = decode_record(&image, descs);
            if matches!(vals.get(fid), Some(Value::Null) | None) {
                return true;
            }
        }
    }
    false
}

/// Set (or clear) the `RDB$NULL_FLAG` of a column's `RDB$RELATION_FIELDS`
/// row in place: `Some(1)` for NOT NULL, `None` to make it nullable again.
fn patch_rf_null_flag(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_up: &str,
    flag: Option<i64>,
) -> Result<(), String> {
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (rf_format_no, rf_descs) = {
        let (n, d) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let rel_fid = fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let name_fid = fid("RDB$FIELD_NAME").ok_or("no RDB$FIELD_NAME")?;
    let null_fid = fid("RDB$NULL_FLAG").ok_or("no RDB$NULL_FLAG")?;
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let pred = |vals: &[Value]| {
        text(vals.get(rel_fid)).as_deref() == Some(table)
            && text(vals.get(name_fid)).as_deref() == Some(col_up)
    };
    let (page, slot) = find_sys_row_slot(file, page_size, "RDB$RELATION_FIELDS", 5, pred)
        .ok_or("RDB$RELATION_FIELDS row not found")?;
    let mut image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, page).ok_or("bad page")?)
            .ok_or("bad data page")?;
        dp.record(slot).and_then(|r| r.image()).ok_or("no field image")?
    };
    let d = rf_descs.get(null_fid).ok_or("field beyond format")?;
    let at = d.offset as usize;
    match flag {
        Some(v) => {
            let bytes = encode_sys_value(d, &SysVal::I(v))?;
            image
                .get_mut(at..at + bytes.len())
                .ok_or("image shorter than format")?
                .copy_from_slice(&bytes);
            image[null_fid / 8] &= !(1 << (null_fid % 8)); // not NULL
        }
        None => {
            image[null_fid / 8] |= 1 << (null_fid % 8); // NULL
        }
    }
    dml::update_records(file, page_size, 5, &[(page, slot, image)], rf_format_no)?;
    Ok(())
}

/// Rebuild `RDB$RUNTIME` and repoint the `RDB$RELATIONS` row at it - after
/// a change to a field's not-null status, so the engine's DSQL metadata
/// carries the RSR_field_not_null marker. The format is NOT bumped (a
/// NOT NULL constraint changes no record layout).
fn refresh_runtime(file: &mut crate::Image, page_size: usize, table: &str) -> Result<(), String> {
    let formats = crate::relation_formats(
        file,
        page_size,
        crate::resolve_relation(file, page_size, table).ok_or("table not found")?,
    );
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let runtime = rebuild_runtime_blob(file, page_size, table, &descs)?;
    let (page, slot, mut image, rec_format) =
        find_relations_row(file, page_size, table).ok_or("RDB$RELATIONS row not found")?;
    let sys_formats =
        system_relation_formats(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS format")?;
    let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let fid = cols
        .iter()
        .find(|c| c.name == "RDB$RUNTIME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$RUNTIME")?;
    let d = rel_descs.get(fid).ok_or("field beyond format")?;
    let old_rt = old_blob_at(&image, rel_descs, fid);
    let bytes = encode_sys_value(d, &SysVal::B(blob_id_bytes(6, runtime)))?;
    let at = d.offset as usize;
    image
        .get_mut(at..at + bytes.len())
        .ok_or("image shorter than format")?
        .copy_from_slice(&bytes);
    image[fid / 8] &= !(1 << (fid % 8));
    dml::update_records(file, page_size, 6, &[(page, slot, image)], rec_format)?;
    if let Some((orel, onum)) = old_rt {
        dispose_superseded_blob(file, page_size, orel, onum);
        dispose_row_purge(file, page_size, 6, page, slot);
    }
    Ok(())
}

/// The commit-time half of a trigger (or anything else the summary
/// carries) that landed after its relation was built: the summary is
/// rebuilt from the catalog as it now stands. Reads WIDE, as every
/// deferred task does - the rows it exists to pick up are this
/// transaction's own. A relation with no storage yet (its own task is
/// later in the same list, or it is a view without a format) is left to
/// that task.
pub fn refresh_runtime_deferred(file: &mut crate::Image, page_size: usize, table: &str) -> Result<(), String> {
    let _wide = crate::tra::ReaderViewGuard::wide();
    let Some(rel) = crate::resolve_relation(file, page_size, table) else {
        return Ok(()); // a database trigger, or a relation this server does not know
    };
    if crate::relation_formats(file, page_size, rel).is_empty() {
        return Ok(());
    }
    refresh_runtime(file, page_size, table)
}

/// A domain's row changed under the tables built on it: each dependent
/// table re-derives its layout from the catalog. A layout that differs
/// from the current format - a column whose RDB$COMPUTED_BLR arrived
/// late and now has no storage - is a NEW FORMAT VERSION (the engine's
/// dfw modify_field -> make_version: the employee sample's three tables
/// with computed columns end their restore at RDB$FORMAT 2 for exactly
/// this reason); existing records keep their format and read back
/// through it. An unchanged layout only refreshes the summary, which
/// now carries the validation / computed BLR.
pub fn field_changed(file: &mut crate::Image, page_size: usize, field: &str) -> Result<(), String> {
    let _wide = crate::tra::ReaderViewGuard::wide();
    let mut tables: Vec<String> = domain_dependents(file, page_size, field)?
        .into_iter()
        .map(|(t, _)| t)
        .collect();
    tables.sort();
    tables.dedup();
    for table in tables {
        let Some(rel) = crate::resolve_relation(file, page_size, &table) else { continue };
        let cur_formats = crate::relation_formats(file, page_size, rel);
        let Some((cur_no, cur_descs)) = cur_formats.iter().max_by_key(|(n, _)| *n) else {
            continue; // not built yet: its own storage task reads the catalog as it stands
        };
        if is_view(file, page_size, &table) {
            refresh_runtime(file, page_size, &table)?;
            continue;
        }
        let fields = catalog_field_list(file, page_size, &table)?;
        if fields.is_empty() {
            continue;
        }
        let new_descs = compute_format_mixed(&fields);
        let same = new_descs.len() == cur_descs.len()
            && new_descs.iter().zip(cur_descs.iter()).all(|(a, b)| {
                a.dtype == b.dtype && a.length == b.length && a.scale == b.scale && a.sub_type == b.sub_type && a.offset == b.offset
            });
        if same {
            refresh_runtime(file, page_size, &table)?;
            continue;
        }
        let new_format_no = *cur_no as i64 + 1;
        let fmt_blob = write_format_blob(file, page_size, &new_descs)?;
        sys_insert(
            file,
            page_size,
            "RDB$FORMATS",
            8,
            &[
                ("RDB$RELATION_ID", SysVal::I(rel as i64)),
                ("RDB$FORMAT", SysVal::I(new_format_no)),
                ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
            ],
        )?;
        let runtime = rebuild_runtime_blob(file, page_size, &table, &new_descs)?;
        let (rel_page, rel_slot, mut rel_image, rec_format) =
            find_relations_row(file, page_size, &table).ok_or("RDB$RELATIONS row not found")?;
        let sys_formats = system_relation_formats(file, page_size, "RDB$RELATIONS")
            .ok_or("no RDB$RELATIONS format")?;
        let (_, rel_descs) = sys_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let rel_cols = relation_columns(file, page_size, "RDB$RELATIONS");
        let rel_field =
            |name: &str| rel_cols.iter().find(|c| c.name == name).map(|c| c.field_id as usize);
        let old_rt = rel_field("RDB$RUNTIME").and_then(|f| old_blob_at(&rel_image, rel_descs, f));
        for (name, v) in [
            ("RDB$FORMAT", SysVal::I(new_format_no)),
            ("RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime))),
        ] {
            let fid = rel_field(name).ok_or_else(|| format!("no {} column", name))?;
            let d = rel_descs.get(fid).ok_or("field beyond format")?;
            let bytes = encode_sys_value(d, &v)?;
            let at = d.offset as usize;
            rel_image
                .get_mut(at..at + bytes.len())
                .ok_or("image shorter than format")?
                .copy_from_slice(&bytes);
            rel_image[fid / 8] &= !(1 << (fid % 8));
        }
        dml::update_records(file, page_size, 6, &[(rel_page, rel_slot, rel_image)], rec_format)?;
        if let Some((orel, onum)) = old_rt {
            dispose_superseded_blob(file, page_size, orel, onum);
            dispose_row_purge(file, page_size, 6, rel_page, rel_slot);
        }
    }
    Ok(())
}

/// `ALTER TABLE <table> ALTER <column> SET NOT NULL`: add a NOT NULL
/// constraint. No new format version (the layout is unchanged); the
/// column's `RDB$RELATION_FIELDS.RDB$NULL_FLAG` is set, an
/// `RDB$RELATION_CONSTRAINTS` "NOT NULL" row and its `RDB$CHECK_CONSTRAINTS`
/// link (trigger_name = the column) are written, and `RDB$RUNTIME` is
/// refreshed so the engine enforces it. Fails - as the engine does - if
/// the column already holds a NULL.
pub fn alter_table_set_not_null(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let col_up = col_name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    let target = relation_columns(file, page_size, &table)
        .into_iter()
        .find(|c| c.name == col_up)
        .ok_or_else(|| format!("column {} not found", col_name))?;
    if column_has_nulls(file, page_size, rel, target.field_id as usize) {
        return Err(format!(
            "cannot make field {} NOT NULL because there are NULLs present",
            col_name
        ));
    }
    patch_rf_null_flag(file, page_size, &table, &col_up, Some(1))?;
    let cname = next_integ_name(file, page_size)?;
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("NOT NULL")),
        ("RDB$RELATION_NAME", SysVal::S(&table)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$TRIGGER_NAME", SysVal::S(&col_up)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    refresh_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> ALTER <column> DROP NOT NULL`: remove the NOT NULL
/// constraint - clear the column's `RDB$NULL_FLAG`, delete the
/// `RDB$RELATION_CONSTRAINTS`/`RDB$CHECK_CONSTRAINTS` rows, refresh runtime.
pub fn alter_table_drop_not_null(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    col_name: &str,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let col_up = col_name.trim().to_string();
    crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if !relation_columns(file, page_size, &table)
        .iter()
        .any(|c| c.name == col_up)
    {
        return Err(format!("column {} not found", col_name));
    }

    // the constraint name: the RDB$CHECK_CONSTRAINTS row whose
    // RDB$TRIGGER_NAME is this column (a NOT NULL links that way)
    let cc_formats = system_relation_formats(file, page_size, "RDB$CHECK_CONSTRAINTS")
        .ok_or("no RDB$CHECK_CONSTRAINTS format")?;
    let (_, cc_descs) = cc_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let cc_cols = relation_columns(file, page_size, "RDB$CHECK_CONSTRAINTS");
    let cc_fid = |n: &str| cc_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let cc_name = cc_fid("RDB$CONSTRAINT_NAME").ok_or("no RDB$CONSTRAINT_NAME")?;
    let cc_trig = cc_fid("RDB$TRIGGER_NAME").ok_or("no RDB$TRIGGER_NAME")?;
    let cc_rel = crate::resolve_relation(file, page_size, "RDB$CHECK_CONSTRAINTS")
        .ok_or("no RDB$CHECK_CONSTRAINTS")?;
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let mut constraint: Option<String> = None;
    walk_rows(file, page_size, cc_rel, cc_descs, |vals| {
        if text(vals.get(cc_trig)).as_deref() == Some(col_up.as_str()) {
            constraint = text(vals.get(cc_name));
        }
    });
    let constraint = constraint
        .ok_or_else(|| format!("column {} has no NOT NULL constraint", col_name))?;

    patch_rf_null_flag(file, page_size, &table, &col_up, None)?;

    // delete the RDB$CHECK_CONSTRAINTS row (by trigger = column)
    let cc_pred = |vals: &[Value]| text(vals.get(cc_trig)).as_deref() == Some(col_up.as_str());
    if let Some(slot) = find_sys_row_slot(file, page_size, "RDB$CHECK_CONSTRAINTS", cc_rel, cc_pred) {
        dml::delete_records(file, page_size, cc_rel, &[slot])?;
    }
    // delete the RDB$RELATION_CONSTRAINTS row (by constraint name)
    let rc_rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")
        .ok_or("no RDB$RELATION_CONSTRAINTS")?;
    let rc_cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let rc_name = rc_cols
        .iter()
        .find(|c| c.name == "RDB$CONSTRAINT_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$CONSTRAINT_NAME")?;
    let rc_pred = |vals: &[Value]| text(vals.get(rc_name)).as_deref() == Some(constraint.as_str());
    if let Some(slot) =
        find_sys_row_slot(file, page_size, "RDB$RELATION_CONSTRAINTS", rc_rel, rc_pred)
    {
        dml::delete_records(file, page_size, rc_rel, &[slot])?;
    }
    refresh_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// CREATE TABLE: the full engine sequence against the file image.
/// Errors leave the caller's copy to be discarded - the statement
/// failed, nothing half-created survives.
/// The `nonnull_validation_blr` bytes DdlNodes.epp stores in the
/// runtime blob's RSR_field_not_null segment (probe-copied verbatim).
const NONNULL_BLR: [u8; 8] = [5, 59, 61, 24, 0, 0, 0, 76];

/// A foreign key's referential action for `ON UPDATE` / `ON DELETE`.
///
/// `NO ACTION` and `RESTRICT` behave the same - neither synthesises a
/// trigger - but they are NOT the same stored rule. The engine writes
/// back exactly what was written: `ON DELETE NO ACTION` stores
/// `RDB$DELETE_RULE = 'NO ACTION'`, an omitted clause and an explicit
/// `RESTRICT` store `'RESTRICT'` (measured 2026-09-03 on
/// 127.0.0.1/3050, both files read back by the engine). A comment here
/// once stated the collapse as a law; it was wrong, and collapsing them
/// was a SILENT WRONG WRITE that survived gbak - the only catalog
/// divergence among the eighty FK shapes both servers fully accept.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RefAction {
    Restrict,
    /// `ON UPDATE|DELETE NO ACTION` as WRITTEN: the same behaviour as
    /// [RefAction::Restrict] and its own stored rule string
    NoAction,
    Cascade,
    SetNull,
    SetDefault,
}

impl RefAction {
    /// The `RDB$UPDATE_RULE` / `RDB$DELETE_RULE` string the engine stores.
    fn rule(self) -> &'static str {
        match self {
            RefAction::Restrict => "RESTRICT",
            RefAction::NoAction => "NO ACTION",
            RefAction::Cascade => "CASCADE",
            RefAction::SetNull => "SET NULL",
            RefAction::SetDefault => "SET DEFAULT",
        }
    }

    /// Whether this action synthesises a system trigger on the
    /// referenced table. `RESTRICT` and `NO ACTION` do not - the key is
    /// simply enforced - and every other action does.
    pub fn synthesises_trigger(self) -> bool {
        !matches!(self, RefAction::Restrict | RefAction::NoAction)
    }

    /// The action READ BACK from a stored `RDB$UPDATE_RULE` /
    /// `RDB$DELETE_RULE` - the inverse of [RefAction::rule], and the
    /// only place a server learns what a foreign key already on file
    /// tells it to DO. Trailing catalog padding is trimmed; an
    /// unrecognised rule is `None` and its caller must refuse rather
    /// than guess a behaviour for it.
    pub fn from_rule(s: &str) -> Option<RefAction> {
        Some(match s.trim_end() {
            "RESTRICT" => RefAction::Restrict,
            "NO ACTION" => RefAction::NoAction,
            "CASCADE" => RefAction::Cascade,
            "SET NULL" => RefAction::SetNull,
            "SET DEFAULT" => RefAction::SetDefault,
            _ => return None,
        })
    }
}

/// One `FOREIGN KEY (<columns>) REFERENCES <ref_table> [(<ref_columns>)]
/// [ON UPDATE <action>] [ON DELETE <action>]` clause of a CREATE TABLE -
/// or the same thing wearing COLUMN syntax, `B INTEGER REFERENCES P`.
/// `name` is the constraint name (also the FK index name, as the engine
/// names them the same).
///
/// [ForeignKeyDef::place] is the FK's seat in the two-pass numbering law
/// ([constraint_steps]), exactly as [TableConstraint::place] is for a key
/// or a CHECK: a foreign key is not a fourth thing that always comes
/// last, it is the FOURTH KIND OF CONSTRAINT and takes its number where
/// it is written. An inline `REFERENCES` is `Inline { col, at }` and goes
/// in pass 1; a `FOREIGN KEY (...)` clause standing on its own is
/// `Table` and takes its declaration place among the other table-level
/// clauses. Callers that add an FK to an EXISTING table
/// ([alter_table_add_foreign_key], gbak restore) draw one number per
/// statement and leave this at `Table`, which orders nothing there.
#[derive(Clone)]
pub struct ForeignKeyDef {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_update: RefAction,
    pub on_delete: RefAction,
    pub place: ConstraintPlace,
}

pub fn create_table(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    cols: &[ColumnDef],
    constraints: &[TableConstraint],
    fks: &[ForeignKeyDef],
    relation_type: i64,
) -> Result<(), String> {
    if cols.is_empty() {
        return Err("a table needs at least one column".into());
    }
    // a computed column has no storage to constrain, default or generate
    // into - the parser refuses these combinations; this is the writer's
    // own line of defence
    for c in cols {
        if c.computed.is_some()
            && (c.not_null || c.default.is_some() || c.identity.is_some() || c.domain.is_some())
        {
            return Err(format!("computed column {} cannot carry constraints", c.name));
        }
    }
    // ONE SET OF COLUMNS, ONE KEY. `(A INTEGER NOT NULL, UNIQUE (A),
    // PRIMARY KEY (A))` is refused by the engine with DYN 126, "Same set
    // of columns cannot be used in more than one PRIMARY KEY and/or
    // UNIQUE constraint definition" - and it is the SET, not the order:
    // `UNIQUE (A,B)` beside `UNIQUE (B,A)` is refused too, while
    // `UNIQUE (A)` beside `UNIQUE (A,B)` is fine. A column-level key
    // counts (measured on `A INTEGER NOT NULL UNIQUE, UNIQUE (A)`).
    // fire-crab used to write both constraints and both indexes.
    {
        let mut seen: Vec<Vec<String>> = Vec::new();
        for c in constraints {
            let ConstraintKind::Key(k) = &c.kind else { continue };
            let mut set = k.columns.clone();
            set.sort();
            if seen.contains(&set) {
                return Err(SAME_KEY_COLUMNS_MSG.to_string());
            }
            seen.push(set);
        }
    }
    let name = name.trim().to_string();

    // the name has to be free (the catalog as it stands is the judge of
    // that), and the id comes from the engine's own counter for it -
    // NOT from the same list, which would re-issue the id of a dropped
    // relation the moment the two answers were allowed to disagree
    let rels = list_relations(file, page_size);
    if rels
        .iter()
        .any(|(_, n)| n.trim_end() == name)
    {
        return Err(format!("table {} already exists", name));
    }
    let rel_id_u16 = next_relation_id(file, page_size, &rels)?;
    let rel_id = rel_id_u16 as i64;

    // resolve each column's source (its RDB$FIELD_SOURCE): a per-table
    // auto-domain RDB$<n> for a built-in type, or the user domain it names.
    // A domain column's type is filled from the domain's RDB$FIELDS row, and
    // it inherits the domain's DEFAULT and NOT NULL (both applied via the
    // runtime, not the column's own catalog row). The auto-domain counter
    // advances only for built-in columns, so with no domain columns the
    // source names are byte-identical to before.
    let auto_domains = cols.iter().filter(|c| c.domain.is_none()).count() as u64;
    let domain_base = next_domain_numbers(file, page_size, auto_domains)?;
    // identity columns get an implicit RDB$<n> generator, named from a
    // separate counter; the generator itself is written after the
    // table's security classes, but its name is needed on the field row
    // now, so the run of names is drawn here
    let identity_gens =
        cols.iter().filter(|c| c.domain.is_none() && c.identity.is_some()).count() as u64;
    let gen_base = next_generator_number(file, page_size, identity_gens)?;
    let mut resolved: Vec<ColumnDef> = Vec::with_capacity(cols.len());
    // per column: (source name, is_domain, inherited default BLR, inherited not_null)
    #[allow(clippy::type_complexity)]
    let mut src_meta: Vec<(String, bool, Option<Vec<u8>>, bool, Option<Vec<u8>>)> =
        Vec::with_capacity(cols.len());
    // per column: the identity generator name and its definition, if any
    let mut identity_meta: Vec<Option<(String, IdentityDef)>> = Vec::with_capacity(cols.len());
    let mut auto_idx: u64 = 0;
    let mut gen_idx: u64 = 0;
    for c in cols {
        if let Some(dname) = &c.domain {
            let dname = dname.trim().trim_matches('"').to_ascii_uppercase();
            let dt = resolve_domain_type(file, page_size, &dname)
                .ok_or_else(|| format!("Domain {} is not defined", dname))?;
            let mut rc = c.clone();
            rc.field_type = dt.field_type;
            rc.dtype = dt.dtype;
            rc.length = dt.length;
            rc.scale = dt.scale;
            rc.sub_type = dt.sub_type;
            rc.char_len = dt.char_len;
            // an ARRAY domain makes the column an array of its shape (the
            // bounds live on the domain's RDB$FIELDS row; the column's
            // storage is the 8-byte array id like any other)
            rc.dims = dt.dims.clone();
            resolved.push(rc);
            src_meta.push((dname, true, dt.default_blr, dt.not_null, dt.validation_blr));
            identity_meta.push(None);
        } else {
            resolved.push(c.clone());
            src_meta.push((format!("RDB${}", domain_base + auto_idx), false, None, false, None));
            auto_idx += 1;
            match &c.identity {
                Some(id) => {
                    identity_meta.push(Some((format!("RDB${}", gen_base + gen_idx), id.clone())));
                    gen_idx += 1;
                }
                None => identity_meta.push(None),
            }
        }
    }
    let cols: &[ColumnDef] = &resolved;

    // the physical format: field ids in declaration order (probe-pinned),
    // offsets by the ini.epp walk sysfmt already implements. A computed
    // column keeps its declaration-order field id but no storage - its
    // descriptor carries the result type at offset 0.
    let fields: Vec<(u8, u16, i8, i16, bool)> = cols
        .iter()
        .map(|c| {
            let (dt, l, s, st) = col_field_of(c);
            (dt, l, s, st, c.computed.is_some())
        })
        .collect();
    let descs = compute_format_mixed(&fields);
    if descs.len() != cols.len() {
        return Err("format computation failed".into());
    }

    // --- pages first (DPM_create_relation): pointer + index root.
    // An EXTERNAL table (type 2) owns NO pages - its rows live in the
    // external file, and the engine's own restore leaves RDB$PAGES
    // empty for it (measured)
    let external = relation_type == 2;
    let (pointer_page, root_page) = if external {
        (0u32, 0u32)
    } else {
        (
            dml::allocate_page(file, page_size)?,
            dml::allocate_page(file, page_size)?,
        )
    };
    if !external {
        if file.ddl_tx.is_some() {
            // the relation's storage is the rollback's residue - whatever
            // it owns by then, the transaction's own rows' pages included
            file.ddl_residue.push(crate::DdlResidue::CreatedRelation { rel: rel_id_u16 });
        }
        {
            let page =
                crate::page_mut(file, page_size, pointer_page).expect("pointer page out of range");
            page.fill(0);
            page[0] = 4; // pag_pointer
            page[1] = 1; // pag_flags = ppg_eof (last pointer page)
            dml::put_u32(page, 12, pointer_page); // pag_pageno
            dml::put_u16(page, 26, rel_id_u16); // ppg_relation @26
        }
        {
            let page =
                crate::page_mut(file, page_size, root_page).expect("root page out of range");
            page.fill(0);
            page[0] = 6; // pag_root
            dml::put_u32(page, 12, root_page); // pag_pageno
            dml::put_u16(page, 16, rel_id_u16); // irt_relation @16
            dml::put_u16(page, 18, 0); // irt_count
        }
    }

    // --- the format descriptor blob (makeFormat) ---------------------
    let fmt_blob = write_format_blob(file, page_size, &descs)?;

    // CHECK constraints: each takes a PAIR of CHECK_<n> triggers
    // (before-insert, before-update), numbered from the engine's
    // RDB$TRIGGER_NAME generator NOW so the runtime summary below can
    // name them - a trigger absent from RDB$RUNTIME never fires
    let mut check_names: Vec<(String, String)> = Vec::new();
    {
        let n_checks = constraints
            .iter()
            .filter(|c| matches!(c.kind, ConstraintKind::Check(_)))
            .count();
        if n_checks > 0 {
            let slot = generator_id_by_name(file, page_size, "RDB$TRIGGER_NAME")
                .ok_or("no RDB$TRIGGER_NAME generator")?;
            for _ in 0..n_checks {
                let a = gen::bump(file, page_size, slot, 1)?;
                let b = gen::bump(file, page_size, slot, 1)?;
                check_names.push((format!("CHECK_{}", a), format!("CHECK_{}", b)));
            }
        }
    }

    // --- the RDB$RUNTIME field summary (make_version): per field the
    // probe-pinned tag sequence ------------------------------------------
    let mut runtime: Vec<Vec<u8>> = Vec::new();
    let seg = |tag: u8, data: &[u8]| {
        let mut s = Vec::with_capacity(1 + data.len());
        s.push(tag);
        s.extend_from_slice(data);
        s
    };
    for (i, c) in cols.iter().enumerate() {
        let (source, is_domain, dom_default, dom_not_null, dom_validation) = &src_meta[i];
        runtime.push(seg(0, &(i as u16).to_le_bytes())); // RSR_field_id
        runtime.push(seg(1, c.name.as_bytes())); // RSR_field_name
        let src = format!("\"PUBLIC\".\"{}\"", source);
        runtime.push(seg(25, src.as_bytes())); // RSR_field_source
        // RSR_field_length is the byte (declared) length, not the storage
        // length a VARYING carries in the format descriptor
        runtime.push(seg(19, &(catalog_field_length(c) as u16).to_le_bytes()));
        if let Some(cl) = c.char_len {
            runtime.push(seg(26, &cl.to_le_bytes())); // RSR_character_length
        }
        // a computed field's expression BLR (RSR_computed_blr = 4) sits
        // between the length and position segments (probed byte order)
        if let Some(cp) = &c.computed {
            runtime.push(seg(4, &cp.blr));
        }
        runtime.push(seg(27, &(i as u16).to_le_bytes())); // RSR_field_pos
        // the field DEFAULT (RSR_default_value = 6): the engine reads a
        // field's default from this runtime entry, not from the catalog
        // column. A column-level default wins; a domain column with none
        // inherits the domain's.
        let default_blr: Option<&[u8]> = c
            .default
            .as_ref()
            .map(|d| d.value_blr.as_slice())
            .or(if *is_domain { dom_default.as_deref() } else { None });
        if let Some(blr) = default_blr {
            runtime.push(seg(6, blr));
        }
        // the DOMAIN's CHECK (RSR_validation_blr = 7): the engine
        // enforces field validation from THIS summary segment, not from
        // the domain row - measured, a byte-identical catalog with no
        // segment let a CHECK (VALUE > 0) domain take -5
        if *is_domain {
            if let Some(blr) = dom_validation {
                runtime.push(seg(7, blr));
            }
        }
        // NOT NULL: a column-level NOT NULL, or (for a domain column) the
        // domain's own NOT NULL, or (implicitly) an identity column
        let identity = identity_meta[i].as_ref();
        let not_null = c.not_null || (*is_domain && *dom_not_null) || identity.is_some();
        if not_null {
            runtime.push(seg(21, &NONNULL_BLR)); // RSR_field_not_null
        }
        // an identity field names its generator (RSR_field_generator = 22)
        // and its identity type (RSR_field_identity_type = 23, a 2-byte type)
        if let Some((gen_name, id)) = identity {
            runtime.push(seg(22, gen_name.as_bytes()));
            runtime.push(seg(23, &(id.identity_type as u16).to_le_bytes()));
        }
    }
    // the CHECK triggers' names (RSR_trigger_name = 9) in the engine's
    // runtime order: (sequence, then name lexically) - check triggers
    // are all sequence 0, so lexically
    let mut tnames: Vec<&str> = check_names
        .iter()
        .flat_map(|(a, b)| [a.as_str(), b.as_str()])
        .collect();
    tnames.sort();
    for t in &tnames {
        runtime.push(seg(9, t.as_bytes()));
    }
    let runtime_blob = dml::insert_blob(file, page_size, 6, &runtime, 5)?;

    // --- catalog rows, each with its indexes maintained ---------------
    // the auto-domain RDB$FIELDS row - only for a built-in-typed column; a
    // domain column's RDB$FIELDS row already exists (the domain itself)
    for (i, c) in cols.iter().enumerate() {
        let (source, is_domain, ..) = &src_meta[i];
        if *is_domain {
            continue;
        }
        let mut vals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(source)),
            ("RDB$FIELD_TYPE", SysVal::I(c.field_type as i64)),
            ("RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(c))),
            ("RDB$FIELD_SCALE", SysVal::I(c.scale as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            // an auto-domain is owned by the table's owner (no security class)
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if subtype_carried(c.field_type) {
            let st = if matches!(c.field_type, 14 | 37) { 0 } else { c.sub_type };
            vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(st as i64)));
        }
        if let Some(cl) = c.char_len {
            vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(c.charset_id.unwrap_or(0) as i64)));
            vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
            vals.push(("RDB$COLLATION_ID", SysVal::I(crate::intl::collation_id(c.sub_type) as i64)));
        }
        // a BLOB: its segment size (80 unless declared) and, for a TEXT
        // blob, its character set with the default collation (probed:
        // `BLOB SUB_TYPE TEXT CHARACTER SET UTF8` -> charset 4, collation 0;
        // a binary blob carries neither)
        if c.field_type == 261 {
            vals.push(("RDB$SEGMENT_LENGTH", SysVal::I(c.segment_length.unwrap_or(80) as i64)));
            if c.sub_type == 1 {
                vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(c.charset_id.unwrap_or(0) as i64)));
                vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
            }
        }
        if !c.dims.is_empty() {
            vals.push(("RDB$DIMENSIONS", SysVal::I(c.dims.len() as i64)));
        }
        // a computed field: the verbatim `(expr)` source, the compiled
        // BLR, and the result type's precision (source before value, the
        // DEFAULT blob order). The blobs belong to RDB$FIELDS (rel 2)
        let computed_blobs = match &c.computed {
            Some(cp) => {
                let src = dml::insert_blob_cs(
                    file, page_size, 2, &[cp.source.as_bytes().to_vec()], 1, 4,
                )?;
                let blr = dml::insert_blob(file, page_size, 2, &[cp.blr.clone()], 2)?;
                Some((src, blr, cp.precision))
            }
            None => None,
        };
        if let Some((src, blr, precision)) = computed_blobs {
            vals.push(("RDB$COMPUTED_SOURCE", SysVal::B(blob_id_bytes(2, src))));
            vals.push(("RDB$COMPUTED_BLR", SysVal::B(blob_id_bytes(2, blr))));
            vals.push(("RDB$FIELD_PRECISION", SysVal::I(precision as i64)));
        } else if let Some(p) = c.precision {
            // a plain declared column's precision: 0 for the exact-int
            // family, the declared p for NUMERIC/DECIMAL (probed)
            vals.push(("RDB$FIELD_PRECISION", SysVal::I(p as i64)));
        }
        sys_insert(file, page_size, "RDB$FIELDS", 2, &vals)?;
        // an ARRAY column's bounds, one RDB$FIELD_DIMENSIONS row per dimension
        for (dim, (lo, hi)) in c.dims.iter().enumerate() {
            sys_insert(
                file,
                page_size,
                "RDB$FIELD_DIMENSIONS",
                21,
                &[
                    ("RDB$FIELD_NAME", SysVal::S(source)),
                    ("RDB$DIMENSION", SysVal::I(dim as i64)),
                    ("RDB$LOWER_BOUND", SysVal::I(*lo as i64)),
                    ("RDB$UPPER_BOUND", SysVal::I(*hi as i64)),
                    ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
                ],
            )?;
        }
    }
    for (i, c) in cols.iter().enumerate() {
        let (source, is_domain, ..) = &src_meta[i];
        let mut vals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(&c.name)),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$FIELD_SOURCE", SysVal::S(source)),
            ("RDB$FIELD_POSITION", SysVal::I(i as i64)),
            // a computed column is read-only: RDB$UPDATE_FLAG 0 (probed)
            ("RDB$UPDATE_FLAG", SysVal::I(if c.computed.is_some() { 0 } else { 1 })),
            ("RDB$FIELD_ID", SysVal::I(i as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        // RDB$COLLATION_ID on the RELATION_FIELDS row: 0 for a built-in
        // column (its collation is the relation field's own), NULL for a
        // domain column (the collation is the domain's) - probe: an INTEGER
        // built-in column has 0 too, so this is not a text-only attribute
        if !is_domain {
            // a text column's collation (the ttype high byte) rides the
            // relation-field row too; a built-in non-text column is 0
            vals.push(("RDB$COLLATION_ID", SysVal::I(crate::intl::collation_id(c.sub_type) as i64)));
        }
        // a COLUMN-level NOT NULL / DEFAULT lands on the RDB$RELATION_FIELDS
        // row (for a built-in or a domain column alike); a domain column with
        // neither inherits them from the domain, so its row carries neither -
        // the engine keeps those on the domain's RDB$FIELDS row
        // an identity column is implicitly NOT NULL (no INTEG constraint row)
        if c.not_null || identity_meta[i].is_some() {
            vals.push(("RDB$NULL_FLAG", SysVal::I(1)));
        }
        if let Some(def) = &c.default {
            let src =
                dml::insert_blob_cs(file, page_size, 5, &[def.source.as_bytes().to_vec()], 1, 4)?;
            let val = dml::insert_blob(file, page_size, 5, &[def.value_blr.clone()], 2)?;
            vals.push(("RDB$DEFAULT_SOURCE", SysVal::B(blob_id_bytes(5, src))));
            vals.push(("RDB$DEFAULT_VALUE", SysVal::B(blob_id_bytes(5, val))));
        }
        // an identity column names its implicit generator and its type
        if let Some((gen_name, id)) = &identity_meta[i] {
            vals.push(("RDB$GENERATOR_NAME", SysVal::S(gen_name)));
            vals.push(("RDB$IDENTITY_TYPE", SysVal::I(id.identity_type as i64)));
        }
        sys_insert(file, page_size, "RDB$RELATION_FIELDS", 5, &vals)?;
    }
    // the security catalog: the relation's own class and the class its
    // fields default to, each with the owner's ACL, then the owner's
    // five privileges. Both class NAMES come from counters the engine
    // does not re-check, so they are taken by advancing them.
    let class = next_security_class(file, page_size, ACL_TABLE_OWNER)?;
    let default_class = next_default_class(file, page_size)?;
    sys_insert(
        file,
        page_size,
        "RDB$RELATIONS",
        6,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel_id)),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime_blob))),
            ("RDB$DBKEY_LENGTH", SysVal::I(8)),
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$FIELD_ID", SysVal::I(cols.len() as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$FLAGS", SysVal::I(1)), // REL_sql
            // 0 persistent, 4 GTT ON COMMIT PRESERVE, 5 GTT ON COMMIT DELETE
            ("RDB$RELATION_TYPE", SysVal::I(relation_type)),
            ("RDB$OWNER_NAME", SysVal::S("SYSDBA")),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$DEFAULT_CLASS", SysVal::S(&default_class)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ],
    )?;
    store_privileges(file, page_size, &name, 0, TABLE_OWNER_PRIVILEGES)?;
    // the implicit identity generators (system_flag 6), created after the
    // table's own security class so their SQL$<n> classes follow it, in
    // column order (RDB$1, RDB$2, ...)
    for (gen_name, id) in identity_meta.iter().flatten() {
        write_generator(file, page_size, gen_name, 6, id.start, id.increment)?;
    }
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel_id)),
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;
    for (page, ptype) in if external {
        vec![]
    } else {
        vec![(pointer_page, 4i64), (root_page, 6i64)]
    } {
        sys_insert(
            file,
            page_size,
            "RDB$PAGES",
            0,
            &[
                ("RDB$RELATION_ID", SysVal::I(rel_id)),
                ("RDB$PAGE_NUMBER", SysVal::I(page as i64)),
                ("RDB$PAGE_SEQUENCE", SysVal::I(0)),
                ("RDB$PAGE_TYPE", SysVal::I(ptype)),
            ],
        )?;
    }
    // --- constraints, IN THE ENGINE'S TWO-PASS ORDER: every
    // COLUMN-LEVEL (inline) constraint first - the columns in
    // declaration order and, within one column, its clauses in written
    // order - and only THEN every TABLE-LEVEL clause, in declaration
    // order. That order is the one the engine's INTEG_<n> and
    // index-name sequences follow. See [constraint_steps]; the place
    // travels in [TableConstraint::place] and [ColumnDef::not_null_at].
    let mut check_i = 0usize;
    for step in constraint_steps(cols, constraints, fks) {
        match step {
            ConstraintStep::NotNull(i) => {
                let c = &cols[i];
                let cname = next_integ_name(file, page_size)?;
                sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
                    ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
                    ("RDB$CONSTRAINT_TYPE", SysVal::S("NOT NULL")),
                    ("RDB$RELATION_NAME", SysVal::S(&name)),
                    ("RDB$DEFERRABLE", SysVal::S("NO")),
                    ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
                    ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
                ])?;
                sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
                    ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
                    ("RDB$TRIGGER_NAME", SysVal::S(&c.name)),
                    ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
                ])?;
            }
            ConstraintStep::Table(i) => match &constraints[i].kind {
                ConstraintKind::Key(key) => write_key(file, page_size, &name, key)?,
                ConstraintKind::Check(ck) => {
                    write_check(file, page_size, &name, ck, &check_names[check_i])?;
                    check_i += 1;
                }
            },
            // --- a FOREIGN KEY: a non-unique index on the referencing
            // columns (irt_foreign, naming the partner key's index), an
            // RDB$RELATION_CONSTRAINTS 'FOREIGN KEY' row, and an
            // RDB$REF_CONSTRAINTS row linking to the referenced table's
            // PK/UNIQUE constraint (MATCH FULL). Written HERE, in the
            // law's place, not from a trailing loop: the engine numbers
            // an FK where it is written, and it writes the FK's INDEX
            // there too - probed, `G1 (A INTEGER, B INTEGER, FOREIGN KEY
            // (A) REFERENCES P, UNIQUE (B))` gives the FK index id 1 and
            // the UNIQUE index id 2.
            //
            // Nothing downstream wants FKs last. The partner lookup
            // (find_partner_key) reads the catalog as it stands, and a
            // SELF-referencing FK therefore needs its own table's key
            // already written - but the ENGINE has exactly the same
            // rule: `(A INTEGER NOT NULL, B INTEGER, FOREIGN KEY (B)
            // REFERENCES S1 (A), PRIMARY KEY (A))` is refused by the
            // engine with "could not find UNIQUE or PRIMARY KEY
            // constraint", and accepted when the PRIMARY KEY is written
            // first. Writing in the law's order reproduces that.
            ConstraintStep::Fk(i) => {
                let fk = &fks[i];
                // an unnamed FK is named INTEG_<n> - the same generated
                // name for both the constraint and its index, as the
                // engine does
                let fk_name = if fk.name.is_empty() {
                    next_integ_name(file, page_size)?
                } else {
                    fk.name.clone()
                };
                write_foreign_key_full(file, page_size, &name, &fk_name, fk, true)?;
            }
        }
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// One constraint row a CREATE TABLE writes, in the order it writes
/// them: a column's NOT NULL (by column index) or a table constraint
/// (by index into the statement's constraint list).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConstraintStep {
    NotNull(usize),
    Table(usize),
    /// a FOREIGN KEY, by index into the statement's `fks` list - inline
    /// (`B INTEGER REFERENCES P`) or a table-level clause, and ordered
    /// by its [ForeignKeyDef::place] like every other constraint
    Fk(usize),
}

/// THE ORDER A CREATE TABLE WRITES ITS CONSTRAINTS, which is the order
/// their generated `INTEG_<n>` names - and the backing indexes' names -
/// are drawn in.
///
/// **The law, measured on the engine: the names are drawn in TWO
/// PASSES. Every COLUMN-LEVEL (inline) constraint first, walking the
/// columns in declaration order and, within one column, taking its
/// clauses in the order they are written; then every TABLE-LEVEL
/// clause, in declaration order.**
///
/// Column-level means written as part of a column's definition - its
/// NOT NULL, an inline `PRIMARY KEY`/`UNIQUE`, an inline `CHECK`.
/// Table-level means a clause standing on its own in the column list.
///
/// The shapes that establish it (all measured through 127.0.0.1/3050,
/// both servers' files read back BY THE ENGINE):
///
/// - `(ID INTEGER NOT NULL PRIMARY KEY, C INTEGER UNIQUE, D VARCHAR(10)
///   NOT NULL)` -> NOT NULL, PRIMARY KEY, UNIQUE, NOT NULL. One pass is
///   enough here, which is why the superseded single-pass rule fitted.
/// - `(A INTEGER, UNIQUE (A), B INTEGER UNIQUE)` -> UNIQUE on B, then
///   UNIQUE on A. THE DECISIVE ONE: `B`'s inline UNIQUE is written LAST
///   and numbered FIRST, because it is column-level and the `UNIQUE (A)`
///   ahead of it is table-level. No single-pass text order can do that.
/// - `(A INTEGER NOT NULL, B INTEGER, UNIQUE (B), C INTEGER NOT NULL,
///   PRIMARY KEY (A))` -> NOT NULL, NOT NULL, UNIQUE, PRIMARY KEY: both
///   NOT NULLs (pass 1) before both table-level keys (pass 2).
/// - `(A INTEGER CHECK (A > 0), B INTEGER NOT NULL, CHECK (B < 100),
///   C INTEGER UNIQUE)` -> CHECK on A, NOT NULL on B, UNIQUE on C, then
///   the table-level CHECK. The same law with CHECKs, independently.
/// - `(A INTEGER UNIQUE NOT NULL, B INTEGER)` -> UNIQUE, NOT NULL, and
///   `(A INTEGER NOT NULL UNIQUE, B INTEGER)` -> NOT NULL, UNIQUE:
///   within ONE column it is plain text order, so the two clauses swap
///   numbers when the text swaps them.
///
/// Two rules this replaced, each right on some shapes and wrong on
/// others: "every NOT NULL first, then every key" (wrong on the first
/// shape) and "one strict declaration order" (wrong on the second,
/// third, fourth and fifth). Under either, `INTEG_4` named a different
/// constraint on the two servers' copies of one file.
fn constraint_steps(
    cols: &[ColumnDef],
    constraints: &[TableConstraint],
    fks: &[ForeignKeyDef],
) -> Vec<ConstraintStep> {
    // The FOREIGN KEYs travel in their OWN list (they carry a partner
    // table and referential actions no other constraint has), but they
    // are numbered in the SAME two passes as everything else - so their
    // places are merged in here, not appended after. `decl` restores the
    // one declaration order the two lists were split out of: a
    // table-level clause's rank is its position in its own list, and
    // interleaving the two by that rank is what `G1 (..., FOREIGN KEY
    // (A) REFERENCES P, UNIQUE (B))` needs - measured on the engine as
    // FOREIGN KEY then UNIQUE, which an FK-last writer cannot produce.
    //
    // pass 1: the COLUMN-LEVEL constraints, ordered by (column, offset
    // inside that column's own text). A stable sort settles a tie the
    // way the engine does: a column-level PRIMARY KEY's IMPLIED NOT NULL
    // carries the key's own offset and is numbered just before it.
    let mut inline: Vec<(usize, usize, ConstraintStep)> =
        Vec::with_capacity(cols.len() + constraints.len() + fks.len());
    for (i, c) in cols.iter().enumerate() {
        if c.not_null_constraint {
            inline.push((i, c.not_null_at, ConstraintStep::NotNull(i)));
        }
    }
    for (i, k) in constraints.iter().enumerate() {
        if let ConstraintPlace::Inline { col, at } = k.place {
            inline.push((col, at, ConstraintStep::Table(i)));
        }
    }
    for (i, f) in fks.iter().enumerate() {
        if let ConstraintPlace::Inline { col, at } = f.place {
            inline.push((col, at, ConstraintStep::Fk(i)));
        }
    }
    inline.sort_by_key(|(col, at, _)| (*col, *at));
    let mut steps: Vec<ConstraintStep> = inline.into_iter().map(|(_, _, s)| s).collect();
    // pass 2: the TABLE-LEVEL clauses, in declaration order, all of them
    // after every column-level one. The keys/CHECKs and the FKs are two
    // lists of one order, so they merge on `decl` - the position the
    // parser stamped from the SHARED clause counter.
    let mut table: Vec<(usize, ConstraintStep)> = Vec::new();
    for (i, k) in constraints.iter().enumerate() {
        if let ConstraintPlace::Table { decl } = k.place {
            table.push((decl, ConstraintStep::Table(i)));
        }
    }
    for (i, f) in fks.iter().enumerate() {
        if let ConstraintPlace::Table { decl } = f.place {
            table.push((decl, ConstraintStep::Fk(i)));
        }
    }
    table.sort_by_key(|(decl, _)| *decl);
    steps.extend(table.into_iter().map(|(_, s)| s));
    steps
}

/// Write one PRIMARY KEY or UNIQUE constraint onto a table: the unique
/// index backing it (primary-flagged for a PRIMARY KEY) and the
/// RDB$RELATION_CONSTRAINTS row. A NAMED constraint names its index too;
/// an unnamed one draws INTEG_<n> and its index name from the engine's
/// generated sequences (probed: ONE index-number sequence feeds
/// RDB$PRIMARY<n> and RDB$<n> alike). Shared by create_table and
/// ALTER TABLE ADD CONSTRAINT; create_index backfills - and unique-
/// checks - the table's existing rows, so this works on a populated
/// table exactly as the engine's own does.
fn write_key(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    key: &KeyDef,
) -> Result<(), String> {
    let (cname, iname) = if key.name.is_empty() {
        let n = next_index_number(file, page_size)?;
        let iname = if key.primary {
            format!("RDB$PRIMARY{}", n)
        } else {
            format!("RDB${}", n)
        };
        (next_integ_name(file, page_size)?, iname)
    } else {
        (key.name.clone(), key.name.clone())
    };
    create_index(
        file, page_size, table, &iname, &key.columns, true, false, key.primary, None,
    )?;
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$CONSTRAINT_TYPE",
            SysVal::S(if key.primary { "PRIMARY KEY" } else { "UNIQUE" })),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$INDEX_NAME", SysVal::S(&iname)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    Ok(())
}

/// Write one CHECK constraint onto a table: the PAIR of CHECK_<n>
/// triggers (before-insert type 1, before-update type 3 - both carrying
/// the SAME if-failed-raise BLR and the verbatim source, probed), their
/// per-referenced-field RDB$DEPENDENCIES rows, the
/// RDB$RELATION_CONSTRAINTS 'CHECK' row (no index), and the two
/// RDB$CHECK_CONSTRAINTS rows linking constraint to triggers. The
/// trigger names come pre-assigned from the RDB$TRIGGER_NAME generator
/// (create_table draws them before building the runtime summary, which
/// must already name them).
fn write_check(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    check: &CheckDef,
    tnames: &(String, String),
) -> Result<(), String> {
    let cname = if check.name.is_empty() {
        next_integ_name(file, page_size)?
    } else {
        check.name.clone()
    };
    let trel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    for (tname, ttype) in [(&tnames.0, 1i64), (&tnames.1, 3i64)] {
        let src =
            dml::insert_blob_cs(file, page_size, trel, &[check.source.as_bytes().to_vec()], 1, 4)?;
        let blr = dml::insert_blob(file, page_size, trel, &[check.trigger_blr.clone()], 2)?;
        sys_insert(
            file,
            page_size,
            "RDB$TRIGGERS",
            trel,
            &[
                ("RDB$TRIGGER_NAME", SysVal::S(tname)),
                ("RDB$RELATION_NAME", SysVal::S(table)),
                ("RDB$TRIGGER_SEQUENCE", SysVal::I(0)),
                ("RDB$TRIGGER_TYPE", SysVal::I(ttype)),
                ("RDB$TRIGGER_SOURCE", SysVal::B(blob_id_bytes(trel, src))),
                ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(trel, blr))),
                ("RDB$TRIGGER_INACTIVE", SysVal::I(0)),
                // fb_sysflag_check_constraint
                ("RDB$SYSTEM_FLAG", SysVal::I(3)),
                ("RDB$FLAGS", SysVal::I(1)),
                ("RDB$VALID_BLR", SysVal::I(1)),
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ],
        )?;
        // one dependency row per referenced field, first-seen order
        for f in &check.fields {
            let drel = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES")
                .ok_or("no RDB$DEPENDENCIES relation")?;
            sys_insert(
                file,
                page_size,
                "RDB$DEPENDENCIES",
                drel,
                &[
                    ("RDB$DEPENDENT_NAME", SysVal::S(tname)),
                    ("RDB$DEPENDED_ON_NAME", SysVal::S(table)),
                    ("RDB$FIELD_NAME", SysVal::S(f)),
                    ("RDB$DEPENDENT_TYPE", SysVal::I(2)),   // obj_trigger
                    ("RDB$DEPENDED_ON_TYPE", SysVal::I(0)), // obj_relation
                    ("RDB$DEPENDENT_SCHEMA_NAME", SysVal::S("PUBLIC")),
                    ("RDB$DEPENDED_ON_SCHEMA_NAME", SysVal::S("PUBLIC")),
                ],
            )?;
        }
    }
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("CHECK")),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    for tname in [&tnames.0, &tnames.1] {
        sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
            ("RDB$CONSTRAINT_NAME", SysVal::S(&cname)),
            ("RDB$TRIGGER_NAME", SysVal::S(tname)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }
    Ok(())
}

/// One field of a restored VIEW, as the backup carries it.
#[derive(Clone, Debug)]
pub struct RestoredViewField {
    pub name: String,
    /// its RDB$FIELD_SOURCE domain - the base column's, or the
    /// expression's own carried domain
    pub source: String,
    /// empty for an EXPRESSION column
    pub base_field: String,
    pub view_context: i64,
    pub position: i64,
}

/// One FROM-context of a restored VIEW (an RDB$VIEW_RELATIONS row).
#[derive(Clone, Debug)]
pub struct RestoredViewContext {
    pub relation: String,
    pub context: i64,
    pub context_name: String,
}

/// Store a VIEW as gbak's restore does: the RDB$RELATIONS row
/// (type 1) with the carried VIEW_BLR and VIEW_SOURCE blobs verbatim,
/// one format row derived from the fields' domains, the
/// RDB$RELATION_FIELDS rows with their base-field and context links,
/// and the RDB$VIEW_RELATIONS context rows. A view owns no pages -
/// its rows are a query - so nothing else is allocated.
/// One output column of a `CREATE VIEW`: a PLAIN column reads a base
/// relation's field (its RDB$FIELD_SOURCE is reused, RDB$BASE_FIELD and
/// RDB$VIEW_CONTEXT name it); an EXPRESSION column gets an auto-domain
/// RDB$<n> of its own type (probed: `V || 'x'` became RDB$4 VARCHAR(6)),
/// no base field, RDB$UPDATE_FLAG 0.
#[derive(Clone)]
pub struct ViewFieldSpec {
    pub name: String,
    /// (the base relation's RDB$FIELD_SOURCE, base field name, view context)
    pub base: Option<(String, String, i64)>,
    /// the expression's type, for the auto-domain
    pub expr: Option<ColumnDef>,
    /// the expression's BLR over the view's streams - the auto-domain's
    /// RDB$COMPUTED_BLR (probed: no RDB$COMPUTED_SOURCE on a view's)
    pub computed_blr: Option<Vec<u8>>,
}

/// `CREATE VIEW <name> [(cols)] AS <select>`: the auto-domains of the
/// expression columns, then the same rows the restore writes (RDB$FORMATS,
/// RDB$RELATIONS with the BLR and the source text, RDB$RELATION_FIELDS,
/// RDB$VIEW_RELATIONS), then what a CREATE writes beyond a restore: an
/// 8-byte dbkey length, a security class and a default class (probed).
pub fn create_view(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    view_blr: &[u8],
    view_source: &str,
    fields: &[ViewFieldSpec],
    contexts: &[RestoredViewContext],
) -> Result<(), String> {
    let want = name.trim().to_string();
    if crate::resolve_relation(file, page_size, &want).is_some() {
        return Err(format!("relation {} already exists", want));
    }
    create_view_impl(file, page_size, name, view_blr, view_source, fields, contexts, None)
}

/// `ALTER VIEW` - the view's definition is replaced but its RELATION ID
/// survives (probed: 129 -> 129), so the drop-and-repopulate reuses the
/// old id. The fields, view relations and auto-domains are all fresh.
pub fn alter_view(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    view_blr: &[u8],
    view_source: &str,
    fields: &[ViewFieldSpec],
    contexts: &[RestoredViewContext],
) -> Result<(), String> {
    let want = name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &want)
        .ok_or_else(|| format!("View {} not found", want))?;
    if rel < 128 || !is_view(file, page_size, &want) {
        return Err(format!("View {} not found", want));
    }
    let old_id = rel as i64;
    drop_view(file, page_size, &want)?;
    create_view_impl(file, page_size, name, view_blr, view_source, fields, contexts, Some(old_id))
}

fn create_view_impl(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    view_blr: &[u8],
    view_source: &str,
    fields: &[ViewFieldSpec],
    contexts: &[RestoredViewContext],
    forced_id: Option<i64>,
) -> Result<(), String> {
    let want = name.trim().to_string();
    let auto_domains =
        fields.iter().filter(|f| f.base.is_none() && f.expr.is_some()).count() as u64;
    let domain_base = next_domain_numbers(file, page_size, auto_domains)?;
    let mut auto_idx = 0u64;
    let mut restored: Vec<RestoredViewField> = Vec::with_capacity(fields.len());
    for (i, f) in fields.iter().enumerate() {
        match (&f.base, &f.expr) {
            (Some((source, base_field, ctx)), _) => restored.push(RestoredViewField {
                name: f.name.clone(),
                source: source.clone(),
                base_field: base_field.clone(),
                view_context: *ctx,
                position: i as i64,
            }),
            (None, Some(col)) => {
                let source = format!("RDB${}", domain_base + auto_idx);
                auto_idx += 1;
                insert_auto_field_row(file, page_size, &source, col, f.computed_blr.as_deref())?;
                restored.push(RestoredViewField {
                    name: f.name.clone(),
                    source,
                    base_field: String::new(),
                    view_context: 0,
                    position: i as i64,
                });
            }
            (None, None) => return Err("a view column needs a base field or a type".into()),
        }
    }
    let class = next_security_class(file, page_size, ACL_TABLE_OWNER)?;
    let default_class = next_default_class(file, page_size)?;
    // 8 bytes of dbkey per context (probed: a two-table view is 16)
    let dbkey = 8 * contexts.len().max(1) as i64;
    restore_view_with(
        file,
        page_size,
        &want,
        view_blr,
        view_source.as_bytes(),
        &restored,
        contexts,
        Some((dbkey, &class, &default_class)),
        forced_id,
    )
}

/// The RDB$FIELDS row of an auto-domain (`RDB$<n>`) - the type of an
/// expression column, precision by storage width (4 / 9 / 18 / 38 for
/// the exact kinds - probed on a view's expression columns).
fn insert_auto_field_row(file: &mut crate::Image, page_size: usize, source: &str, c: &ColumnDef, computed_blr: Option<&[u8]>) -> Result<(), String> {
    let blr_id = match computed_blr {
        Some(b) => Some(blob_id_bytes(2, dml::insert_blob(file, page_size, 2, &[b.to_vec()], 2)?)),
        None => None,
    };
    let mut vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(source)),
        ("RDB$FIELD_TYPE", SysVal::I(c.field_type as i64)),
        ("RDB$FIELD_LENGTH", SysVal::I(catalog_field_length(c))),
        ("RDB$FIELD_SCALE", SysVal::I(c.scale as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if subtype_carried(c.field_type) {
        vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(c.sub_type as i64)));
    }
    if let Some(cl) = c.char_len {
        vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(c.charset_id.unwrap_or(0) as i64)));
        vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(cl as i64)));
        vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
    }
    if c.field_type == 261 {
        vals.push(("RDB$SEGMENT_LENGTH", SysVal::I(80)));
        if c.sub_type == 1 {
            vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(c.charset_id.unwrap_or(0) as i64)));
            vals.push(("RDB$COLLATION_ID", SysVal::I(0)));
        }
    }
    if let Some(p) = c.precision {
        vals.push(("RDB$FIELD_PRECISION", SysVal::I(p as i64)));
    }
    if let Some(id) = &blr_id {
        vals.push(("RDB$COMPUTED_BLR", SysVal::B(*id)));
    }
    sys_insert(file, page_size, "RDB$FIELDS", 2, &vals)
}

/// `DROP VIEW <name>`: the relation, its fields, its own auto-domains, its
/// view relations, formats, security class and privileges go; a TABLE is
/// not a view (the engine's "does not exist" for DROP VIEW, probed).
pub fn drop_view(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let name = name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &name)
        .ok_or_else(|| format!("View {} not found", name))?;
    if rel < 128 || !is_view(file, page_size, &name) {
        return Err(format!("View {} not found", name));
    }
    let mut domain_names: Vec<String> = Vec::new();
    {
        let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let src_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_SOURCE")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
        let base_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$BASE_FIELD")?;
        walk_rows(file, page_size, 5, descs, |values| {
            if text_is(values.get(rel_fid), &name) && !matches!(values.get(base_fid), Some(Value::Text(_))) {
                if let Some(Value::Text(t)) = values.get(src_fid) {
                    let t = t.trim_end();
                    if t.strip_prefix("RDB$").is_some_and(|x| x.parse::<u64>().is_ok()) {
                        domain_names.push(t.to_string());
                    }
                }
            }
        });
    }
    let security_class = {
        let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let cls_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$SECURITY_CLASS")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
        let mut class = None;
        walk_rows(file, page_size, 6, descs, |values| {
            if text_is(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(cls_fid) {
                    class = Some(t.trim_end().to_string());
                }
            }
        });
        class
    };
    {
        let fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
        let n = name.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATION_FIELDS", move |v| text_is(v.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
        let names = domain_names.clone();
        delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| names.iter().any(|d| text_is(v.get(fid), d)))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$VIEW_RELATIONS", "RDB$VIEW_NAME")?;
        let n = name.clone();
        delete_catalog_rows(file, page_size, "RDB$VIEW_RELATIONS", move |v| text_is(v.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FORMATS", "RDB$RELATION_ID")?;
        delete_catalog_rows(file, page_size, "RDB$FORMATS", move |v| int_eq(v.get(fid), rel as i64))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
        let n = name.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATIONS", move |v| text_is(v.get(fid), &n))?;
    }
    if let Some(class) = security_class {
        let fid = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| text_eq(v.get(fid), &class))?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        let n = name.clone();
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| text_is(v.get(rel_f), &n) && int_eq(v.get(obj_f), 0))?;
    }
    advance_oldest_transactions(file, page_size)
}

/// Whether a relation is a VIEW (RDB$RELATION_TYPE 1 / a view BLR).
pub fn is_view(file: &crate::Image, page_size: usize, name: &str) -> bool {
    let Some(formats) = system_relation_formats(file, page_size, "RDB$RELATIONS") else { return false };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else { return false };
    let cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(name_f), Some(blr_f)) = (fid("RDB$RELATION_NAME"), fid("RDB$VIEW_BLR")) else { return false };
    let mut view = false;
    walk_rows(file, page_size, 6, descs, |v| {
        if text_is(v.get(name_f), name) && matches!(v.get(blr_f), Some(Value::Blob(..))) {
            view = true;
        }
    });
    view
}

/// A relation field's RDB$FIELD_SOURCE (the domain it reads) - what a view
/// column over it reuses.
pub fn relation_field_source(file: &crate::Image, page_size: usize, relation: &str, field: &str) -> Option<String> {
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rel_f, fld_f, src_f) = (fid("RDB$RELATION_NAME")?, fid("RDB$FIELD_NAME")?, fid("RDB$FIELD_SOURCE")?);
    let mut out = None;
    walk_rows(file, page_size, 5, descs, |v| {
        if out.is_none() && text_is(v.get(rel_f), relation) && text_is(v.get(fld_f), field) {
            if let Some(Value::Text(t)) = v.get(src_f) {
                out = Some(t.trim_end().to_string());
            }
        }
    });
    out
}

pub fn restore_view(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    view_blr: &[u8],
    view_source: &[u8],
    fields: &[RestoredViewField],
    contexts: &[RestoredViewContext],
) -> Result<(), String> {
    restore_view_with(file, page_size, name, view_blr, view_source, fields, contexts, None, None)
}

/// [restore_view] with what a CREATE writes beyond a restore - the dbkey
/// length, the security class and the default class - put on the
/// RDB$RELATIONS row at INSERT (a later patch of a system row needs room
/// for a new version on a page that may be full - measured on the fifth
/// view of one transaction).
fn restore_view_with(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    view_blr: &[u8],
    view_source: &[u8],
    fields: &[RestoredViewField],
    contexts: &[RestoredViewContext],
    created: Option<(i64, &str, &str)>,
    forced_id: Option<i64>,
) -> Result<(), String> {
    let name = name.trim().to_string();
    let rels = list_relations(file, page_size);
    if rels.iter().any(|(_, n)| n.trim_end() == name) {
        return Err(format!("relation {} already exists", name));
    }
    // ALTER VIEW keeps the relation's id across the drop-and-repopulate;
    // a fresh CREATE draws one from the engine's RDB$RELATIONS counter,
    // the same as a table.
    let rel_id = match forced_id {
        Some(id) => id,
        None => next_relation_id(file, page_size, &rels)? as i64,
    };
    // the format: each field's descriptor from its (already restored)
    // domain, offsets laid out the way the row would be
    let mut descs: Vec<Descriptor> = Vec::new();
    let mut off = 4u16; // the null bitmap slot, as create_table lays out
    for f in fields {
        let (ft, len, sc, st) = domain_type_info(file, page_size, &f.source)
            .ok_or_else(|| format!("view {}: domain {} not found", name, f.source))?;
        let dt = field_type_to_dtype(ft)
            .ok_or_else(|| format!("view {}: field type {} unsupported", name, ft))?;
        descs.push(Descriptor {
            dtype: dt,
            scale: sc,
            length: len,
            sub_type: st,
            flags: 0,
            offset: off as u32,
        });
        off += len;
    }
    let fmt_blob = write_format_blob(file, page_size, &descs)?;
    let formats_rel = crate::resolve_relation(file, page_size, "RDB$FORMATS")
        .ok_or("no RDB$FORMATS relation")?;
    let relations_rel = crate::resolve_relation(file, page_size, "RDB$RELATIONS")
        .ok_or("no RDB$RELATIONS relation")?;
    let relfields_rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS relation")?;
    let viewrels_rel = crate::resolve_relation(file, page_size, "RDB$VIEW_RELATIONS")
        .ok_or("no RDB$VIEW_RELATIONS relation")?;
    sys_insert(file, page_size, "RDB$FORMATS", formats_rel, &[
        ("RDB$RELATION_ID", SysVal::I(rel_id)),
        ("RDB$FORMAT", SysVal::I(1)),
        ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(formats_rel, fmt_blob))),
    ])?;
    let src = dml::insert_blob_cs(file, page_size, relations_rel, &[view_source.to_vec()], 1, 4)?;
    let blr = dml::insert_blob(file, page_size, relations_rel, &[view_blr.to_vec()], 2)?;
    sys_insert(file, page_size, "RDB$RELATIONS", relations_rel, &[
        ("RDB$RELATION_NAME", SysVal::S(&name)),
        ("RDB$RELATION_ID", SysVal::I(rel_id)),
        ("RDB$RELATION_TYPE", SysVal::I(1)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        // a VIEW's dbkey length is 0 and its FLAGS bit 1 marks the
        // view (both diffed off the engine's own restore - and the
        // missing schema qualifier on the field-source was exactly
        // what made the engine answer "Column unknown" over an
        // otherwise perfect catalog, the FK-blocker lesson again)
        ("RDB$FLAGS", SysVal::I(1)),
        ("RDB$DBKEY_LENGTH", SysVal::I(created.map_or(0, |c| c.0))),
        ("RDB$FORMAT", SysVal::I(1)),
        ("RDB$FIELD_ID", SysVal::I(fields.len() as i64)),
        ("RDB$VIEW_BLR", SysVal::B(blob_id_bytes(relations_rel, blr))),
        ("RDB$VIEW_SOURCE", SysVal::B(blob_id_bytes(relations_rel, src))),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ]
    .into_iter()
    .chain(created.iter().flat_map(|(_, cls, dcls)| {
        [("RDB$SECURITY_CLASS", SysVal::S(*cls)), ("RDB$DEFAULT_CLASS", SysVal::S(*dcls))]
    }))
    .collect::<Vec<_>>())?;
    for (i, f) in fields.iter().enumerate() {
        // an EXPRESSION column: BASE_FIELD stays NULL (omitted -
        // sys_insert starts every field NULL), context 0, read-only -
        // the engine's own restored row (measured)
        let expr = f.base_field.is_empty();
        let mut fvals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(&f.name)),
            ("RDB$RELATION_NAME", SysVal::S(&name)),
            ("RDB$FIELD_SOURCE", SysVal::S(&f.source)),
            ("RDB$FIELD_POSITION", SysVal::I(f.position)),
            ("RDB$FIELD_ID", SysVal::I(i as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$UPDATE_FLAG", SysVal::I(if expr { 0 } else { 1 })),
            ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if !expr {
            // an expression column has no context and no base field (probed: both NULL)
            fvals.push(("RDB$VIEW_CONTEXT", SysVal::I(f.view_context)));
            fvals.push(("RDB$BASE_FIELD", SysVal::S(&f.base_field)));
        }
        sys_insert(file, page_size, "RDB$RELATION_FIELDS", relfields_rel, &fvals)?;
    }
    for c in contexts {
        sys_insert(file, page_size, "RDB$VIEW_RELATIONS", viewrels_rel, &[
            ("RDB$VIEW_NAME", SysVal::S(&name)),
            ("RDB$RELATION_NAME", SysVal::S(&c.relation)),
            ("RDB$VIEW_CONTEXT", SysVal::I(c.context)),
            ("RDB$CONTEXT_NAME", SysVal::S(&c.context_name)),
            ("RDB$CONTEXT_TYPE", SysVal::I(0)),
            ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }
    // THE RUNTIME SUMMARY IS THE FIELD LIST: the engine's relation
    // loader reads its fields from the RDB$RUNTIME blob, not from the
    // RDB$RELATION_FIELDS rows (met.epp "Pick up field specific
    // stuff", blb::open(&REL.RDB$RUNTIME)) - a view restored with a
    // perfect catalog and no runtime answered "Column unknown" to
    // every column while COUNT(*) ran fine, measured
    update_relation_runtime(file, page_size, &name)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// One trigger row as a BACKUP carries it - a CHECK constraint's or a
/// referential action's, stored VERBATIM: the BLR and source are the
/// engine's own bytes off the file, not compiled here.
pub struct CarriedTrigger {
    /// the PSQL debug map, stored sub_type 9 like CREATE TRIGGER's
    pub debug: Option<Vec<u8>>,
    pub name: String,
    pub relation: String,
    pub sequence: i64,
    pub ttype: i64,
    pub blr: Vec<u8>,
    pub source: Vec<u8>,
    pub system_flag: i64,
    pub inactive: i64,
    pub flags: Option<i64>,
    pub valid_blr: Option<i64>,
}

/// Store one carried trigger row (gbak restore). The caller refreshes
/// the relation runtime once per table when its triggers are in.
pub fn restore_carried_trigger(
    file: &mut crate::Image,
    page_size: usize,
    t: &CarriedTrigger,
) -> Result<(), String> {
    let trel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    let src = dml::insert_blob_cs(file, page_size, trel, &[t.source.clone()], 1, 4)?;
    let blr = dml::insert_blob(file, page_size, trel, &[t.blr.clone()], 2)?;
    let dbg = match &t.debug {
        Some(d) => Some(dml::insert_blob(file, page_size, trel, &[d.clone()], 9)?),
        None => None,
    };
    let mut vals: Vec<(&str, SysVal)> = vec![
        ("RDB$TRIGGER_NAME", SysVal::S(&t.name)),
        ("RDB$RELATION_NAME", SysVal::S(&t.relation)),
        ("RDB$TRIGGER_SEQUENCE", SysVal::I(t.sequence)),
        ("RDB$TRIGGER_TYPE", SysVal::I(t.ttype)),
        ("RDB$TRIGGER_SOURCE", SysVal::B(blob_id_bytes(trel, src))),
        ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(trel, blr))),
        ("RDB$TRIGGER_INACTIVE", SysVal::I(t.inactive)),
        ("RDB$SYSTEM_FLAG", SysVal::I(t.system_flag)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if let Some(fl) = t.flags {
        vals.push(("RDB$FLAGS", SysVal::I(fl)));
    }
    if let Some(v) = t.valid_blr {
        vals.push(("RDB$VALID_BLR", SysVal::I(v)));
    }
    let dbg_bytes = dbg.map(|d| blob_id_bytes(trel, d));
    if let Some(b) = &dbg_bytes {
        vals.push(("RDB$DEBUG_INFO", SysVal::B(*b)));
    }
    sys_insert(file, page_size, "RDB$TRIGGERS", trel, &vals)?;
    Ok(())
}

/// Store a CHECK constraint's RDB$RELATION_CONSTRAINTS row (gbak
/// restore; the chk rows and the triggers arrive separately, verbatim).
pub fn restore_check_constraint_row(
    file: &mut crate::Image,
    page_size: usize,
    cname: &str,
    table: &str,
) -> Result<(), String> {
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(cname)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("CHECK")),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])
}

/// Store one RDB$CHECK_CONSTRAINTS row verbatim (gbak restore).
pub fn restore_chk_row(
    file: &mut crate::Image,
    page_size: usize,
    cname: &str,
    tname: &str,
) -> Result<(), String> {
    sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(cname)),
        ("RDB$TRIGGER_NAME", SysVal::S(tname)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])
}

/// Refresh a relation's runtime summary - public for the gbak restore,
/// which stores carried triggers and must make them FIRE.
pub fn refresh_relation_runtime(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
) -> Result<(), String> {
    update_relation_runtime(file, page_size, table.trim())
}

/// A user `CREATE TRIGGER`, compiled: the catalog values plus the three
/// blobs (verbatim source from `AS` on, the body BLR, and the
/// `RDB$DEBUG_INFO` source-to-BLR map the engine writes for PSQL).
#[derive(Clone)]
pub struct UserTriggerDef {
    pub name: String,
    /// RDB$TRIGGER_INACTIVE: 1 for `INACTIVE` (an ALTER / CREATE OR ALTER
    /// keeps the stored flag when the statement does not say - probed)
    pub inactive: bool,
    /// 1 = BEFORE INSERT, 3 = BEFORE UPDATE (the slice this writer
    /// compiles; AFTER/DELETE bodies have nothing our surface can say)
    pub trigger_type: i64,
    /// POSITION <n> - RDB$TRIGGER_SEQUENCE, the firing order
    pub sequence: i64,
    pub source: String,
    pub blr: Vec<u8>,
    pub debug: Vec<u8>,
    /// referenced fields (reads and assignment targets, deduplicated,
    /// sorted) - one RDB$DEPENDENCIES row each
    pub fields: Vec<String>,
    /// INSERT-INTO (blr_store) target relations: one relation-level
    /// dependency row (no field) plus one per stored column - what the
    /// engine records for a store inside a trigger body (probed)
    pub store_deps: Vec<(String, Vec<String>)>,
    /// raised EXCEPTIONs: one dependency row each, object type 7
    pub exceptions: Vec<String>,
    /// GENERATORS the body draws (`NEXT VALUE FOR` / `GEN_ID`): one
    /// dependency row each, object type 14 (measured against the
    /// engine's own rows for the same source)
    pub generators: Vec<String>,
    /// the CHARACTER SET a body's declared TEXT variables carry: ONE
    /// dependency row, object type 17, however many such variables
    /// there are (measured)
    pub charset: Option<String>,
}

/// `CREATE TRIGGER <name> FOR <table> ...`: the RDB$TRIGGERS row (user
/// trigger: system_flag 0, flags 1), its source / BLR / debug-info blobs
/// (the last with the declared sub_type 9), one RDB$DEPENDENCIES row per
/// referenced field, and a refresh of the relation's RDB$RUNTIME - a
/// trigger absent from the summary never fires.
/// Write a trigger's catalog rows.
///
/// `table` is the relation a DML trigger belongs to. A DATABASE trigger
/// (`ON CONNECT` and its siblings) belongs to none: it is written with
/// `RDB$RELATION_NAME` left NULL, which is what the firing side reads it
/// by, and its name must be unique across ALL triggers rather than
/// within one relation's.
pub fn create_user_trigger(
    file: &mut crate::Image,
    page_size: usize,
    table: Option<&str>,
    def: &UserTriggerDef,
) -> Result<(), String> {
    let table = table.map(|t| t.trim().to_string());
    match table.as_deref() {
        Some(t) => {
            let rel = crate::resolve_relation(file, page_size, t)
                .ok_or_else(|| format!("table {} not found", t))?;
            if rel < 128 {
                return Err("system relations are read-only".into());
            }
            if relation_trigger_names(file, page_size, t)
                .iter()
                .any(|n| n.eq_ignore_ascii_case(&def.name))
            {
                return Err(format!("trigger {} already exists", def.name));
            }
        }
        None => {
            if trigger_info(file, page_size, &def.name).is_some() {
                return Err(format!("trigger {} already exists", def.name));
            }
        }
    }
    let trel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    let src = dml::insert_blob_cs(file, page_size, trel, &[def.source.as_bytes().to_vec()], 1, 4)?;
    let blr = dml::insert_blob(file, page_size, trel, &[def.blr.clone()], 2)?;
    let dbg = dml::insert_blob(file, page_size, trel, &[def.debug.clone()], 9)?;
    sys_insert(
        file,
        page_size,
        "RDB$TRIGGERS",
        trel,
        &{
            // sys_insert starts every field NULL, so a database
            // trigger's relation column is simply not written
            let mut row = vec![("RDB$TRIGGER_NAME", SysVal::S(&def.name))];
            if let Some(t) = table.as_deref() {
                row.push(("RDB$RELATION_NAME", SysVal::S(t)));
            }
            row.extend([
            ("RDB$TRIGGER_SEQUENCE", SysVal::I(def.sequence)),
            ("RDB$TRIGGER_TYPE", SysVal::I(def.trigger_type)),
            ("RDB$TRIGGER_SOURCE", SysVal::B(blob_id_bytes(trel, src))),
            ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(trel, blr))),
            ("RDB$DEBUG_INFO", SysVal::B(blob_id_bytes(trel, dbg))),
            ("RDB$TRIGGER_INACTIVE", SysVal::I(def.inactive as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$FLAGS", SysVal::I(1)),
            ("RDB$VALID_BLR", SysVal::I(1)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ]);
            row
        },
    )?;
    let dep = |file: &mut crate::Image, on: &str, field: Option<&str>, otype: i64| -> Result<(), String> {
        let drel = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES")
            .ok_or("no RDB$DEPENDENCIES relation")?;
        let mut row = vec![
            ("RDB$DEPENDENT_NAME", SysVal::S(&def.name)),
            ("RDB$DEPENDED_ON_NAME", SysVal::S(on)),
            ("RDB$DEPENDENT_TYPE", SysVal::I(2)), // obj_trigger
            ("RDB$DEPENDED_ON_TYPE", SysVal::I(otype)),
            ("RDB$DEPENDENT_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$DEPENDED_ON_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if let Some(f) = field {
            row.push(("RDB$FIELD_NAME", SysVal::S(f)));
        }
        sys_insert(file, page_size, "RDB$DEPENDENCIES", drel, &row)
    };
    // a database trigger has no row, so it names no column of its own
    if let Some(t) = table.as_deref() {
        for f in &def.fields {
            dep(file, t, Some(f), 0)?;
        }
    }
    // a blr_store's target: the relation itself plus each stored column
    for (srel_name, scols) in &def.store_deps {
        dep(file, srel_name, None, 0)?;
        for c in scols {
            dep(file, srel_name, Some(c), 0)?;
        }
    }
    // a raised exception: object type 7 (probed)
    for e in &def.exceptions {
        dep(file, e, None, 7)?;
    }
    // a generator the body draws: object type 14 (measured)
    for g in &def.generators {
        dep(file, g, None, 14)?;
    }
    // the character set of a declared TEXT variable: object type 17,
    // one row whatever the count (measured)
    if let Some(cs) = &def.charset {
        dep(file, cs, None, 17)?;
    }
    // a database trigger belongs to no relation, so no relation's
    // runtime summary changes with it
    if let Some(t) = table.as_deref() {
        update_relation_runtime(file, page_size, t)?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] CHECK (<condition>)`:
/// the same trigger pair and catalog rows a CREATE-time CHECK writes
/// ([write_check]), plus a refresh of the relation's RDB$RUNTIME so the
/// new triggers load. The engine does NOT validate existing rows
/// (probed: a violating row survives the ALTER untouched; only future
/// DML is checked) - so neither does this.
/// A user trigger's row: (relation, trigger type, sequence, inactive).
pub fn trigger_info(file: &crate::Image, page_size: usize, name: &str) -> Option<(String, i64, i64, i64)> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")?;
    let formats = system_relation_formats(file, page_size, "RDB$TRIGGERS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$TRIGGERS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, rel_f, type_f, seq_f, ina_f) = (
        fid("RDB$TRIGGER_NAME")?,
        fid("RDB$RELATION_NAME")?,
        fid("RDB$TRIGGER_TYPE")?,
        fid("RDB$TRIGGER_SEQUENCE")?,
        fid("RDB$TRIGGER_INACTIVE")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), &want) {
            let geti = |f: usize| match v.get(f) {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            let table = match v.get(rel_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => String::new(),
            };
            out = Some((table, geti(type_f), geti(seq_f), geti(ina_f)));
        }
    });
    out
}

/// `ALTER TRIGGER <name> [ACTIVE|INACTIVE] [POSITION n]` without a new
/// body: the row's flag and sequence change in place (probed).
pub fn alter_trigger_attrs(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    inactive: Option<bool>,
    sequence: Option<i64>,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if trigger_info(file, page_size, &want).is_none() {
        return Err(format!("Trigger {} not found", want));
    }
    let rel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS").ok_or("no RDB$TRIGGERS")?;
    let name_f = sys_fid(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME")?;
    let mut vals: Vec<(&str, SysVal<'_>)> = Vec::new();
    if let Some(i) = inactive {
        vals.push(("RDB$TRIGGER_INACTIVE", SysVal::I(i as i64)));
    }
    if let Some(sq) = sequence {
        vals.push(("RDB$TRIGGER_SEQUENCE", SysVal::I(sq)));
    }
    if vals.is_empty() {
        return Ok(());
    }
    let nm = want.clone();
    patch_sys_row(file, page_size, "RDB$TRIGGERS", rel, move |v| text_eq(v.get(name_f), &nm), &vals)?;
    advance_oldest_transactions(file, page_size)
}

/// `DROP TRIGGER <name>`: the row and the trigger's dependency rows go.
pub fn drop_trigger(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    // THE RELATION IS READ BEFORE THE ROW GOES, because its runtime
    // summary has to be rebuilt afterwards and the name is only in the
    // row. Dropping a trigger left its name in `RDB$RUNTIME` - CREATE
    // rebuilt the summary and DROP did not - so the engine reading this
    // file was still told the relation had a trigger that is gone.
    // (Found by a gate that compares the summary byte for byte, once a
    // check began creating and dropping one.)
    let table = match trigger_info(file, page_size, &want) {
        None => return Err(format!("Trigger {} not found", want)),
        // a DATABASE or DDL trigger belongs to no relation, so there is
        // no summary to rebuild
        Some((t, ..)) if t.trim().is_empty() => None,
        Some((t, ..)) => Some(t.trim().to_string()),
    };
    {
        let fid = sys_fid(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME")?;
        let n = want.clone();
        delete_catalog_rows(file, page_size, "RDB$TRIGGERS", move |v| text_eq(v.get(fid), &n))?;
    }
    if crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES").is_some() {
        let dn_f = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_NAME")?;
        let dt_f = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_TYPE")?;
        let n = want.clone();
        delete_catalog_rows(file, page_size, "RDB$DEPENDENCIES", move |v| {
            text_eq(v.get(dn_f), &n) && int_eq(v.get(dt_f), 2)
        })?;
    }
    if let Some(t) = table {
        update_relation_runtime(file, page_size, &t)?;
    }
    advance_oldest_transactions(file, page_size)
}

pub fn alter_table_add_check(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    check: &CheckDef,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let slot = generator_id_by_name(file, page_size, "RDB$TRIGGER_NAME")
        .ok_or("no RDB$TRIGGER_NAME generator")?;
    let a = gen::bump(file, page_size, slot, 1)?;
    let b = gen::bump(file, page_size, slot, 1)?;
    write_check(
        file,
        page_size,
        &table,
        check,
        &(format!("CHECK_{}", a), format!("CHECK_{}", b)),
    )?;
    update_relation_runtime(file, page_size, &table)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] PRIMARY KEY|UNIQUE
/// (<cols>)`: add a key constraint to an EXISTING table. The index is
/// built over the table's committed rows, so duplicate data fails the
/// statement the way the engine's own index build does. A PRIMARY KEY
/// requires its columns to be NOT NULL ALREADY - the engine refuses to
/// add one over a nullable column rather than making it not-null
/// (probed), and so does this.
pub fn alter_table_add_key(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    key: &KeyDef,
) -> Result<(), String> {
    let name = table.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &name)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let columns = relation_columns(file, page_size, &name);
    for c in &key.columns {
        if !columns.iter().any(|rc| rc.name == *c) {
            return Err(format!("unknown column {}", c));
        }
    }
    if key.primary {
        if find_partner_key(file, page_size, &name, &[]).is_some() {
            return Err(format!("table {} already has a primary key", name));
        }
        for c in &key.columns {
            if !column_is_not_null(file, page_size, &name, c) {
                return Err(format!(
                    "Column: {} not defined as NOT NULL - cannot be used in PRIMARY KEY constraint definition",
                    c
                ));
            }
        }
    }
    write_key(file, page_size, &name, key)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `ALTER TABLE <table> DROP CONSTRAINT <name>`: remove a NOT NULL,
/// PRIMARY KEY, UNIQUE or FOREIGN KEY constraint.
///
/// The key constraints take their index with them, and the engine does
/// that in a DEFERRED way worth reproducing exactly (DdlNodes.epp:
/// `DropIndexNode::drop`, ods.h's index-state lifecycle): the
/// `RDB$INDICES` row is not erased but RENAMED to
/// `RDB$TEMP_DEPEND_<relation id>_<index id>` with `RDB$INDEX_INACTIVE
/// = MET_index_deferred_drop (4)`, its `RDB$INDEX_SEGMENTS` rows are
/// deleted, and the index-root slot goes to state `irt_drop` (6) -
/// "index to be removed when OAT > irt_transaction" - keeping its
/// pages until then. gbak skips such indices (backup.epp:1676), so a
/// restored copy carries no trace of them.
///
/// A PRIMARY KEY or UNIQUE that a foreign key references is refused,
/// as the engine refuses it ("Cannot delete PRIMARY KEY being used in
/// FOREIGN KEY definition").
pub fn alter_table_drop_constraint(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    constraint: &str,
) -> Result<(), String> {
    let name = table.trim().to_string();
    let cname = constraint.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &name)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let (ctype, index_name) = find_constraint(file, page_size, &name, &cname).ok_or_else(|| {
        format!("constraint {} on table {} not found", cname, name)
    })?;
    match ctype.as_str() {
        "NOT NULL" => {
            // the column it guards is named by its RDB$CHECK_CONSTRAINTS
            // link; clearing NULL_FLAG and refreshing RDB$RUNTIME is what
            // ALTER COLUMN DROP NOT NULL already does
            let column = check_constraint_column(file, page_size, &cname)
                .ok_or_else(|| format!("constraint {} has no column", cname))?;
            patch_rf_null_flag(file, page_size, &name, &column, None)?;
            let cn_fid = sys_fid(file, page_size, "RDB$CHECK_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
            delete_catalog_rows(file, page_size, "RDB$CHECK_CONSTRAINTS", |v| {
                text_is(v.get(cn_fid), &cname)
            })?;
            refresh_runtime(file, page_size, &name)?;
        }
        "PRIMARY KEY" | "UNIQUE" => {
            if let Some(fk) = foreign_key_referencing(file, page_size, &cname) {
                return Err(format!(
                    "Cannot delete {} being used in FOREIGN KEY definition (constraint {})",
                    ctype, fk
                ));
            }
            let index_name = index_name.ok_or("key constraint without an index")?;
            deferred_drop_index(file, page_size, rel, &index_name)?;
        }
        "FOREIGN KEY" => {
            let cn_fid = sys_fid(file, page_size, "RDB$REF_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
            delete_catalog_rows(file, page_size, "RDB$REF_CONSTRAINTS", |v| {
                text_is(v.get(cn_fid), &cname)
            })?;
            // A REFERENTIAL-ACTION TRIGGER GOES WITH ITS CONSTRAINT.
            // An `ON DELETE CASCADE` key owns an AFTER DELETE trigger on
            // the PARENT table, linked to this constraint name through
            // RDB$CHECK_CONSTRAINTS. Left behind it keeps cascading with
            // no constraint to justify it, and a child row the engine's
            // own database keeps is silently deleted (measured on the
            // engine driving both files: CHILD_ROWS_LEFT 1 against 0).
            // The parent's RDB$RUNTIME is rebuilt so the trigger stops
            // being loaded - the trigger sits on the PARENT, not on the
            // table this ALTER names.
            let tnames = check_constraint_trigger_names(file, page_size, &cname);
            let parents: Vec<String> = tnames
                .iter()
                .filter_map(|t| trigger_relation_name(file, page_size, t))
                .collect();
            let cc_fid = sys_fid(file, page_size, "RDB$CHECK_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
            delete_catalog_rows(file, page_size, "RDB$CHECK_CONSTRAINTS", |v| {
                text_is(v.get(cc_fid), &cname)
            })?;
            let tn_fid = sys_fid(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME")?;
            let dn_fid = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_NAME")?;
            for t in &tnames {
                let t = t.clone();
                delete_catalog_rows(file, page_size, "RDB$TRIGGERS", {
                    let t = t.clone();
                    move |v| text_is(v.get(tn_fid), &t)
                })?;
                delete_catalog_rows(file, page_size, "RDB$DEPENDENCIES", move |v| {
                    text_is(v.get(dn_fid), &t)
                })?;
            }
            for parent in &parents {
                if crate::resolve_relation(file, page_size, parent).is_some() {
                    refresh_runtime(file, page_size, parent)?;
                }
            }
            let index_name = index_name.ok_or("foreign key without an index")?;
            deferred_drop_index(file, page_size, rel, &index_name)?;
        }
        "CHECK" => {
            // the pair of CHECK_<n> triggers, their dependency rows and
            // the link rows all go, and the runtime refresh drops the
            // trigger names - the engine leaves nothing and the
            // condition stops enforcing (probed)
            let tnames = check_constraint_trigger_names(file, page_size, &cname);
            let cn_fid = sys_fid(file, page_size, "RDB$CHECK_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
            delete_catalog_rows(file, page_size, "RDB$CHECK_CONSTRAINTS", |v| {
                text_is(v.get(cn_fid), &cname)
            })?;
            let tn_fid = sys_fid(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME")?;
            let dn_fid = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_NAME")?;
            for t in &tnames {
                let t = t.clone();
                delete_catalog_rows(file, page_size, "RDB$TRIGGERS", {
                    let t = t.clone();
                    move |v| text_is(v.get(tn_fid), &t)
                })?;
                delete_catalog_rows(file, page_size, "RDB$DEPENDENCIES", move |v| {
                    text_is(v.get(dn_fid), &t)
                })?;
            }
            refresh_runtime(file, page_size, &name)?;
        }
        other => return Err(format!("cannot drop a {} constraint", other)),
    }
    let rc_name = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
    delete_catalog_rows(file, page_size, "RDB$RELATION_CONSTRAINTS", |v| {
        text_is(v.get(rc_name), &cname)
    })?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// `DROP INDEX <name>`: remove a standalone index - the mirror of
/// [create_index]. An index that BACKS a constraint cannot be dropped
/// this way; the engine posts isc_integ_index_del ("Cannot delete index
/// used by an Integrity Constraint", DdlNodes.epp:14643) and refers the
/// user to ALTER TABLE DROP CONSTRAINT. The removal itself is the
/// engine's deferred one - see [deferred_drop_index].
pub fn drop_index(file: &mut crate::Image, page_size: usize, index_name: &str) -> Result<(), String> {
    let want = index_name.trim().to_string();
    let (table, system) = find_index_relation(file, page_size, &want)
        .ok_or_else(|| format!("index {} not found", want))?;
    if system != 0 {
        return Err("system indices are read-only".into());
    }
    if let Some(constraint) = constraint_using_index(file, page_size, &want) {
        return Err(format!(
            "Cannot delete index used by an Integrity Constraint (constraint {})",
            constraint
        ));
    }
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    deferred_drop_index(file, page_size, rel, &want)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// What a `COMMENT ON` targets - the object whose `RDB$DESCRIPTION`
/// column is written.
#[derive(Clone)]
pub enum CommentTarget {
    /// `COMMENT ON TABLE <name>` - the `RDB$RELATIONS` row
    Table(String),
    /// `COMMENT ON COLUMN <table>.<column>` - the `RDB$RELATION_FIELDS` row
    Column(String, String),
    /// `COMMENT ON INDEX <name>` - the `RDB$INDICES` row
    Index(String),
    /// `COMMENT ON SEQUENCE|GENERATOR <name>` - the `RDB$GENERATORS` row
    Sequence(String),
    /// `COMMENT ON EXCEPTION <name>` - the `RDB$EXCEPTIONS` row
    Exception(String),
    /// `COMMENT ON ROLE <name>` - the `RDB$ROLES` row
    Role(String),
    /// `COMMENT ON DOMAIN <name>` - the `RDB$FIELDS` row
    Domain(String),
    /// `COMMENT ON PROCEDURE <name>` - the plain `RDB$PROCEDURES` row
    Procedure(String),
    /// `COMMENT ON FUNCTION <name>` - the plain `RDB$FUNCTIONS` row
    Function(String),
    /// `COMMENT ON DATABASE` - the single `RDB$DATABASE` row (no name)
    Database,
}

/// A `RDB$DESCRIPTION` cell value from comment text: a text blob written
/// into `owner_rel`'s own data pages (charset 4, UTF8 - the metadata
/// charset, not the 1 the binary metadata blobs carry), or NULL when the
/// comment is being cleared.
fn description_blob(
    file: &mut crate::Image,
    page_size: usize,
    owner_rel: u16,
    text: Option<&str>,
) -> Result<SysVal<'static>, String> {
    match text {
        Some(t) => {
            let id = dml::insert_blob_cs(file, page_size, owner_rel, &[t.as_bytes().to_vec()], 1, 4)?;
            Ok(SysVal::B(blob_id_bytes(owner_rel, id)))
        }
        None => Ok(SysVal::Null),
    }
}

/// `COMMENT ON <kind> <name> IS <text>` - `CommentOnNode` against the
/// file image, for a table, a column, an index or a sequence. The comment
/// is a text blob written into the owning catalog relation's data pages
/// (`RDB$RELATIONS` for a table, `RDB$RELATION_FIELDS` for a column,
/// `RDB$INDICES` for an index, `RDB$GENERATORS` for a sequence) and its id
/// stored in the target row's `RDB$DESCRIPTION`; `IS NULL` (and, the
/// engine's probe shows, `IS ''`) clears the column to NULL, leaving the
/// old blob orphaned exactly as the engine does.
///
/// The one on-disk detail that matters: a `RDB$DESCRIPTION` text blob
/// carries `blh_charset` = 4 (UTF8, the metadata charset), not the 1 the
/// binary metadata blobs use - `CAST(RDB$DESCRIPTION AS VARCHAR)` decodes
/// through the blob's own charset, so it must match (see
/// [crate::dml::insert_blob_cs]).
pub fn comment_on(
    file: &mut crate::Image,
    page_size: usize,
    target: &CommentTarget,
    text: Option<&str>,
) -> Result<(), String> {
    // an empty comment is a NULL comment (engine probe: IS '' clears it)
    let text = text.filter(|t| !t.is_empty());
    match target {
        CommentTarget::Table(name) => {
            let name = name.trim().to_string();
            let rel = crate::resolve_relation(file, page_size, &name)
                .ok_or_else(|| format!("Table \"{}\" not found", name))?;
            if rel < 128 {
                return Err("system relations are read-only".into());
            }
            let value = description_blob(file, page_size, 6, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$RELATIONS", 6,
                move |v| text_is(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Column(table, column) => {
            let table = table.trim().to_string();
            let column = column.trim().to_string();
            let rel = crate::resolve_relation(file, page_size, &table)
                .ok_or_else(|| format!("Table \"{}\" not found", table))?;
            if rel < 128 {
                return Err("system relations are read-only".into());
            }
            if !relation_columns(file, page_size, &table)
                .iter()
                .any(|c| c.name == column)
            {
                return Err(format!(
                    "column {} does not exist in table/view \"{}\"",
                    column, table
                ));
            }
            let value = description_blob(file, page_size, 5, text)?;
            let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
            let name_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
            let (t, c) = (table.clone(), column.clone());
            patch_sys_row(file, page_size, "RDB$RELATION_FIELDS", 5,
                move |v| text_is(v.get(rel_fid), &t) && text_is(v.get(name_fid), &c),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Index(name) => {
            let name = name.trim().to_string();
            let (_table, system) = find_index_relation(file, page_size, &name)
                .ok_or_else(|| format!("index {} not found", name))?;
            if system != 0 {
                return Err("system indices are read-only".into());
            }
            let irel = crate::resolve_relation(file, page_size, "RDB$INDICES")
                .ok_or("RDB$INDICES not found")?;
            let value = description_blob(file, page_size, irel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$INDICES", irel,
                move |v| text_is(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Sequence(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            let (_, system, _) = find_generator(file, page_size, &name)
                .ok_or_else(|| format!("generator {} not found", name))?;
            if system != 0 {
                return Err("system generators are read-only".into());
            }
            let grel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")
                .ok_or("RDB$GENERATORS not found")?;
            let value = description_blob(file, page_size, grel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$GENERATORS", grel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Exception(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            if find_exception(file, page_size, &name).is_none() {
                return Err(format!("Exception {} not found", name));
            }
            let erel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")
                .ok_or("RDB$EXCEPTIONS not found")?;
            let value = description_blob(file, page_size, erel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$EXCEPTIONS", "RDB$EXCEPTION_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$EXCEPTIONS", erel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Role(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            if find_role(file, page_size, &name).is_none() {
                return Err(format!("Role {} not found", name));
            }
            let rrel = crate::resolve_relation(file, page_size, "RDB$ROLES")
                .ok_or("RDB$ROLES not found")?;
            let value = description_blob(file, page_size, rrel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$ROLES", "RDB$ROLE_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$ROLES", rrel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Domain(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            // a domain is a user RDB$FIELDS row; the built-in RDB$/SQL$
            // fields the engine synthesises are read-only
            if name.starts_with("RDB$") || name.starts_with("SQL$") {
                return Err("system domains are read-only".into());
            }
            if !domain_exists(file, page_size, &name) {
                return Err(format!("Domain {} not found", name));
            }
            let frel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
                .ok_or("RDB$FIELDS not found")?;
            let value = description_blob(file, page_size, frel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$FIELDS", frel,
                move |v| text_eq(v.get(name_fid), &nm),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Procedure(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            // the PLAIN procedure (RDB$PACKAGE_NAME NULL); a packaged member
            // is commented via COMMENT ON PROCEDURE PKG.P, not this path
            if procedure_id(file, page_size, &name).is_none() {
                return Err(format!("Procedure {} not found", name));
            }
            let prel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")
                .ok_or("RDB$PROCEDURES not found")?;
            let value = description_blob(file, page_size, prel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$PROCEDURES", "RDB$PROCEDURE_NAME")?;
            let pkg_fid = sys_fid(file, page_size, "RDB$PROCEDURES", "RDB$PACKAGE_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$PROCEDURES", prel,
                move |v| text_eq(v.get(name_fid), &nm) && !matches!(v.get(pkg_fid), Some(Value::Text(_))),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Function(name) => {
            let name = name.trim().trim_matches('"').to_ascii_uppercase();
            if function_id_plain(file, page_size, &name).is_none() {
                return Err(format!("Function {} not found", name));
            }
            let frel = crate::resolve_relation(file, page_size, "RDB$FUNCTIONS")
                .ok_or("RDB$FUNCTIONS not found")?;
            let value = description_blob(file, page_size, frel, text)?;
            let name_fid = sys_fid(file, page_size, "RDB$FUNCTIONS", "RDB$FUNCTION_NAME")?;
            let pkg_fid = sys_fid(file, page_size, "RDB$FUNCTIONS", "RDB$PACKAGE_NAME")?;
            let nm = name.clone();
            patch_sys_row(file, page_size, "RDB$FUNCTIONS", frel,
                move |v| text_eq(v.get(name_fid), &nm) && !matches!(v.get(pkg_fid), Some(Value::Text(_))),
                &[("RDB$DESCRIPTION", value)])?;
        }
        CommentTarget::Database => {
            // the singleton RDB$DATABASE row - the description blob is owned
            // by RDB$DATABASE itself, and the one row is patched in place
            let drel = crate::resolve_relation(file, page_size, "RDB$DATABASE")
                .ok_or("RDB$DATABASE not found")?;
            let value = description_blob(file, page_size, drel, text)?;
            patch_sys_row(file, page_size, "RDB$DATABASE", drel,
                |_| true,
                &[("RDB$DESCRIPTION", value)])?;
        }
    }
    advance_oldest_transactions(file, page_size)
}

/// `SET STATISTICS INDEX <name>` - `SetStatisticsNode` (DdlNodes.epp:14475)
/// against the file image.
///
/// The engine's statement is two steps: at execute it writes
/// `RDB$STATISTICS = -1.0` as a "recalculate me" marker, and at commit a
/// deferred work (`set_statistics`, dfw.epp:3575) walks the index tree
/// (`IDX_statistics`) and `DFW_update_index` writes the fresh selectivity
/// into the two catalog columns and the index root descriptor. Only the
/// committed end state is observable, and it is exactly what a build
/// produces: `1 / distinct` per key prefix over the rows as they now
/// stand. fire-crab, an offline writer that computes from the committed
/// rows rather than by scanning the tree, produces that end state
/// directly - which is why the machinery is the same
/// [index_selectivity]/[write_index_statistics] every build already uses.
///
/// Any index qualifies - a `PRIMARY KEY`'s and an inactive one included
/// (the engine recomputes both) - so the only failure is an index that
/// does not exist ("Index not found").
pub fn set_index_statistics(
    file: &mut crate::Image,
    page_size: usize,
    index_name: &str,
) -> Result<(), String> {
    let want = index_name.trim().to_string();
    let (table, system) = find_index_relation(file, page_size, &want)
        .ok_or_else(|| format!("Index not found: {}", want))?;
    if system != 0 {
        return Err("system indices are read-only".into());
    }
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let (_, _unique, descending) = index_row_state(file, page_size, &want)?;
    let slot = index_id_of(file, page_size, &want)?.saturating_sub(1);
    let columns = relation_columns(file, page_size, &table);
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let mut segs: Vec<(u16, u16, i8)> = Vec::new();
    for n in index_segment_columns(file, page_size, &want)? {
        let rc = columns
            .iter()
            .find(|c| c.name == n)
            .ok_or_else(|| format!("unknown column {}", n))?;
        let d = descs.get(rc.field_id as usize).ok_or("field beyond format")?;
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }
    if segs.is_empty() {
        return Err(format!("index {} has no segments", want));
    }
    let sel = index_selectivity(file, page_size, rel, &segs, descending)?;
    write_index_statistics(file, page_size, rel, slot, &want, &sel, true)?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER INDEX <name> ACTIVE|INACTIVE` - `AlterIndexNode`
/// (DdlNodes.epp:14270) against the file image.
///
/// INACTIVE is the deferred index drop again, minus the catalog
/// teardown: the index-root slot goes to the drop states with its pages,
/// which (per the DROP INDEX slice) means the tree keeps being
/// MAINTAINED while `setDrop`'s cleared `irt_unique|irt_primary|
/// irt_foreign` stop it being ENFORCED - an inactive UNIQUE index
/// accepts duplicates, engine-probed. The `RDB$INDICES` row keeps its
/// name, its id and its segment rows; only `RDB$INDEX_INACTIVE` moves to
/// 1 (`MET_index_inactive`, Relation.h:449).
///
/// ACTIVE REBUILDS. `AlterIndexNode::step2` tries `IDX_activate_index`
/// first, but once the deactivating transaction has committed that undo
/// is refused and the index is built from scratch (engine probe: even in
/// the same isql session, `RDB$INDEX_ID` moves 1 -> 2, the old slot stays
/// in the drop state with its pages, the new slot is a fresh tree). So
/// this takes a NEW slot, backfills every committed row - a duplicate
/// under a unique index fails the statement, exactly as the engine's
/// rebuild does - and recomputes the selectivity.
///
/// An index backing a constraint cannot be deactivated at all
/// ("Cannot deactivate index used by a PRIMARY/UNIQUE constraint" /
/// "... by an integrity constraint").
pub fn alter_index_active(
    file: &mut crate::Image,
    page_size: usize,
    index_name: &str,
    active: bool,
) -> Result<(), String> {
    let want = index_name.trim().to_string();
    let (table, system) = find_index_relation(file, page_size, &want)
        .ok_or_else(|| format!("Index not found: {}", want))?;
    if system != 0 {
        return Err("system indices are read-only".into());
    }
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let (inactive, unique, descending) = index_row_state(file, page_size, &want)?;
    if (inactive == 0) == active {
        return Ok(()); // already in the desired state: the engine does nothing
    }
    if !active {
        if let Some(constraint) = constraint_using_index(file, page_size, &want) {
            return Err(format!(
                "Cannot deactivate index used by an integrity constraint (constraint {})",
                constraint
            ));
        }
        let id = index_id_of(file, page_size, &want)?;
        mark_index_slot_dropped(file, page_size, rel, id.saturating_sub(1))?;
        let ix_name = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
        patch_sys_row(
            file,
            page_size,
            "RDB$INDICES",
            4,
            |v| text_is(v.get(ix_name), &want),
            &[("RDB$INDEX_INACTIVE", SysVal::I(1))], // MET_index_inactive
        )?;
        advance_oldest_transactions(file, page_size)?;
        return Ok(());
    }

    // ACTIVE: a rebuild into a new slot
    let columns = relation_columns(file, page_size, &table);
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let mut segs: Vec<(u16, u16, i8)> = Vec::new();
    for n in index_segment_columns(file, page_size, &want)? {
        let rc = columns
            .iter()
            .find(|c| c.name == n)
            .ok_or_else(|| format!("unknown column {}", n))?;
        let d = descs
            .get(rc.field_id as usize)
            .ok_or("field beyond format")?;
        // a COMPUTED column has no stored bytes to key on - the build
        // would index the null-flag area
        if d.offset == 0 && d.length != 0 {
            return Err(format!("column {} is computed - not indexable", n));
        }
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }
    if segs.is_empty() {
        return Err(format!("index {} has no segments", want));
    }
    let mut iflags = 0u16;
    if unique {
        iflags |= btw::IRT_UNIQUE;
    }
    if descending {
        iflags |= btw::IRT_DESCENDING;
    }
    let slot = allocate_index_slot(file, page_size, rel, &segs, iflags)?;
    backfill_index(
        file, page_size, rel, slot, &segs, &descs, unique, descending, false,
    )?;
    let ix_name = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$INDICES",
        4,
        |v| text_is(v.get(ix_name), &want),
        &[
            ("RDB$INDEX_INACTIVE", SysVal::I(0)), // MET_index_active
            ("RDB$INDEX_ID", SysVal::I(slot as i64 + 1)),
        ],
    )?;
    let sel = index_selectivity(file, page_size, rel, &segs, descending)?;
    write_index_statistics(file, page_size, rel, slot, &want, &sel, true)?;
    advance_oldest_transactions(file, page_size)
}

/// An index's `(RDB$INDEX_INACTIVE, unique, descending)` from
/// RDB$INDICES. A NULL `RDB$INDEX_INACTIVE` counts as active (0), the
/// way `MetadataCache::getIndexStatus` reads it.
fn index_row_state(file: &crate::Image, page_size: usize, name: &str) -> Result<(i64, bool, bool), String> {
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let inact_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_INACTIVE")?;
    let uniq_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$UNIQUE_FLAG")?;
    let type_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_TYPE")?;
    let mut found = None;
    walk_rows(file, page_size, 4, descs, |values| {
        if text_is(values.get(name_f), name) {
            let int = |v: Option<&Value>| match v {
                Some(Value::Int(i)) => *i,
                _ => 0,
            };
            found = Some((
                int(values.get(inact_f)),
                int(values.get(uniq_f)) == 1,
                int(values.get(type_f)) == 1,
            ));
        }
    });
    found.ok_or_else(|| format!("Index not found: {}", name))
}

/// An index's `RDB$INDEX_ID` (the index-root slot plus one).
fn index_id_of(file: &crate::Image, page_size: usize, name: &str) -> Result<usize, String> {
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let id_f = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_ID")?;
    let mut found = None;
    walk_rows(file, page_size, 4, descs, |values| {
        if text_is(values.get(name_f), name) {
            if let Some(Value::Int(i)) = values.get(id_f) {
                found = Some(*i as usize);
            }
        }
    });
    found.ok_or_else(|| format!("index {} has no id", name))
}

/// An index's column names, in key order, from RDB$INDEX_SEGMENTS.
fn index_segment_columns(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Result<Vec<String>, String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS relation")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_f = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
    let field_f = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$FIELD_NAME")?;
    let pos_f = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$FIELD_POSITION")?;
    let mut segs: Vec<(i64, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(name_f), name) {
            if let Some(Value::Text(t)) = values.get(field_f) {
                let pos = match values.get(pos_f) {
                    Some(Value::Int(i)) => *i,
                    _ => 0,
                };
                segs.push((pos, t.trim_end().to_string()));
            }
        }
    });
    segs.sort_by_key(|(p, _)| *p);
    Ok(segs.into_iter().map(|(_, n)| n).collect())
}

/// Move one index-root slot into the drop states with its pages kept -
/// `setDrop` (ods.h:613), which also clears
/// `irt_unique|irt_foreign|irt_primary`, so the tree is still maintained
/// but no longer enforces anything.
fn mark_index_slot_dropped(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    slot: usize,
) -> Result<(), String> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
    let at = 24 + slot * 24;
    if at + 24 > page.len() {
        return Err("index slot beyond the root page".into());
    }
    dml::put_u16(page, at + 18, 0); // irt_flags
    page[at + 20] = 6; // irt_drop (ods.h:456)
    Ok(())
}

/// An index's (relation name, RDB$SYSTEM_FLAG) from RDB$INDICES.
fn find_index_relation(file: &crate::Image, page_size: usize, index_name: &str) -> Option<(String, i64)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$INDICES")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$INDICES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (ix_f, rn_f, sf_f) = (
        fid("RDB$INDEX_NAME")?,
        fid("RDB$RELATION_NAME")?,
        fid("RDB$SYSTEM_FLAG")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(ix_f), index_name) {
            if let Some(Value::Text(t)) = values.get(rn_f) {
                let system = match values.get(sf_f) {
                    Some(Value::Int(i)) => *i,
                    _ => 0,
                };
                found = Some((t.trim_end().to_string(), system));
            }
        }
    });
    found
}

/// The constraint (if any) an index backs - a PRIMARY KEY, UNIQUE or
/// FOREIGN KEY row of RDB$RELATION_CONSTRAINTS naming it.
fn constraint_using_index(file: &crate::Image, page_size: usize, index_name: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, ix_f) = (fid("RDB$CONSTRAINT_NAME")?, fid("RDB$INDEX_NAME")?);
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(ix_f), index_name) {
            if let Some(Value::Text(t)) = values.get(cn_f) {
                found = Some(t.trim_end().to_string());
            }
        }
    });
    found
}

/// A constraint's (type, index name) from RDB$RELATION_CONSTRAINTS.
fn find_constraint(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    cname: &str,
) -> Option<(String, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, ct_f, rn_f, ix_f) = (
        fid("RDB$CONSTRAINT_NAME")?,
        fid("RDB$CONSTRAINT_TYPE")?,
        fid("RDB$RELATION_NAME")?,
        fid("RDB$INDEX_NAME")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(cn_f), cname) && text_is(values.get(rn_f), table) {
            let ctype = match values.get(ct_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            let index = match values.get(ix_f) {
                Some(Value::Text(t)) => Some(t.trim_end().to_string()),
                _ => None,
            };
            found = Some((ctype, index));
        }
    });
    found
}

/// The column a NOT NULL constraint guards (RDB$CHECK_CONSTRAINTS'
/// RDB$TRIGGER_NAME holds the column name for those rows).
fn check_constraint_column(file: &crate::Image, page_size: usize, cname: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$CHECK_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$CHECK_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$CHECK_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, tr_f) = (fid("RDB$CONSTRAINT_NAME")?, fid("RDB$TRIGGER_NAME")?);
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(cn_f), cname) {
            if let Some(Value::Text(t)) = values.get(tr_f) {
                found = Some(t.trim_end().to_string());
            }
        }
    });
    found
}

/// The relation one trigger sits on, from `RDB$TRIGGERS`. A foreign
/// key's referential-action trigger sits on the REFERENCED (parent)
/// table, not on the table whose constraint it belongs to, so a drop
/// has to refresh that table's runtime and not the child's.
fn trigger_relation_name(file: &crate::Image, page_size: usize, trigger: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")?;
    let formats = system_relation_formats(file, page_size, "RDB$TRIGGERS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$TRIGGERS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (tn_f, rn_f) = (fid("RDB$TRIGGER_NAME")?, fid("RDB$RELATION_NAME")?);
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(tn_f), trigger) {
            if let Some(Value::Text(t)) = values.get(rn_f) {
                found = Some(t.trim_end().to_string());
            }
        }
    });
    found
}

/// EVERY trigger name a check constraint's RDB$CHECK_CONSTRAINTS rows
/// link to - a CHECK has a pair, where a NOT NULL has its single column
/// name in the same place ([check_constraint_column]).
fn check_constraint_trigger_names(file: &crate::Image, page_size: usize, cname: &str) -> Vec<String> {
    let mut names = Vec::new();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$CHECK_CONSTRAINTS"),
        system_relation_formats(file, page_size, "RDB$CHECK_CONSTRAINTS"),
    ) else {
        return names;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return names;
    };
    let cols = relation_columns(file, page_size, "RDB$CHECK_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(cn_f), Some(tr_f)) = (fid("RDB$CONSTRAINT_NAME"), fid("RDB$TRIGGER_NAME")) else {
        return names;
    };
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(cn_f), cname) {
            if let Some(Value::Text(t)) = values.get(tr_f) {
                let t = t.trim_end().to_string();
                if !names.contains(&t) {
                    names.push(t);
                }
            }
        }
    });
    names
}

/// Does a FOREIGN KEY on ANOTHER table reference this table's PRIMARY KEY
/// or UNIQUE constraint? The engine refuses DROP TABLE there immediately
/// (before the dependency count) with the PRIMARY_KEY_REF vector.
fn table_pk_referenced_by_fk(file: &crate::Image, page_size: usize, table: &str) -> bool {
    let Some(crel) = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS") else { return false };
    let Some(cfmts) = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS") else { return false };
    let Some((_, cdescs)) = cfmts.iter().max_by_key(|(n, _)| *n) else { return false };
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(cn_f), Some(ct_f), Some(rn_f)) = (fid("RDB$CONSTRAINT_NAME"), fid("RDB$CONSTRAINT_TYPE"), fid("RDB$RELATION_NAME")) else { return false };
    // this table's PRIMARY KEY / UNIQUE constraint names
    let mut uniques: Vec<String> = Vec::new();
    walk_rows(file, page_size, crel, cdescs, |v| {
        if text_is(v.get(rn_f), table) {
            let ct = match v.get(ct_f) { Some(Value::Text(t)) => t.trim_end().to_string(), _ => String::new() };
            if ct == "PRIMARY KEY" || ct == "UNIQUE" {
                if let Some(Value::Text(cn)) = v.get(cn_f) {
                    uniques.push(cn.trim_end().to_string());
                }
            }
        }
    });
    // a FK naming one of them, whose own relation is not this table (a
    // self-FK drops with the table)
    uniques.iter().any(|uq| {
        if let Some(fk) = foreign_key_referencing(file, page_size, uq) {
            let mut on_other = false;
            walk_rows(file, page_size, crel, cdescs, |v| {
                if text_is(v.get(cn_f), &fk) && !text_is(v.get(rn_f), table) {
                    on_other = true;
                }
            });
            on_other
        } else {
            false
        }
    })
}

/// The DISTINCT procedures that reference this table (RDB$DEPENDENCIES,
/// dependent type 5). When no view blocks, these are the drop's N.
fn procedure_dependents(file: &crate::Image, page_size: usize, table: &str) -> Vec<String> {
    let mut procs: Vec<String> = Vec::new();
    let Some(drel) = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES") else { return procs };
    let Some(dfmts) = system_relation_formats(file, page_size, "RDB$DEPENDENCIES") else { return procs };
    let Some((_, ddescs)) = dfmts.iter().max_by_key(|(n, _)| *n) else { return procs };
    let cols = relation_columns(file, page_size, "RDB$DEPENDENCIES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(dn_f), Some(dt_f), Some(don_f)) = (fid("RDB$DEPENDENT_NAME"), fid("RDB$DEPENDENT_TYPE"), fid("RDB$DEPENDED_ON_NAME")) else { return procs };
    walk_rows(file, page_size, drel, ddescs, |v| {
        if text_is(v.get(don_f), table) && matches!(v.get(dt_f), Some(Value::Int(5))) {
            if let Some(Value::Text(t)) = v.get(dn_f) {
                let n = t.trim_end().to_string();
                if !procs.iter().any(|x| x.eq_ignore_ascii_case(&n)) {
                    procs.push(n);
                }
            }
        }
    });
    procs
}

/// The foreign key (if any) whose RDB$REF_CONSTRAINTS row names this
/// unique/primary constraint as its partner.
fn foreign_key_referencing(file: &crate::Image, page_size: usize, cname: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$REF_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$REF_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$REF_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, uq_f) = (fid("RDB$CONSTRAINT_NAME")?, fid("RDB$CONST_NAME_UQ")?);
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(uq_f), cname) {
            if let Some(Value::Text(t)) = values.get(cn_f) {
                found = Some(t.trim_end().to_string());
            }
        }
    });
    found
}

/// Remove an index the engine's deferred way: its RDB$INDICES row
/// renamed to RDB$TEMP_DEPEND_<rel>_<id> and marked
/// MET_index_deferred_drop (4), its segment rows deleted, and its
/// index-root slot moved to irt_drop (6) with its flags cleared - the
/// state fcstat reads back from an engine-dropped index, pages and all.
fn deferred_drop_index(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    index_name: &str,
) -> Result<(), String> {
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES format")?;
    let (ix_format_no, ix_descs) = {
        let (n, d) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        (*n, d.clone())
    };
    let name_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let id_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_ID")?;
    let inactive_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_INACTIVE")?;
    let want = index_name.trim().to_string();
    let (page, slot) = find_sys_row_slot(file, page_size, "RDB$INDICES", 4, |vals| {
        text_is(vals.get(name_fid), &want)
    })
    .ok_or_else(|| format!("index {} not found", index_name))?;
    let mut image = {
        let dp = DataPage::decode(crate::page_at(file, page_size, page).ok_or("bad page")?)
            .ok_or("bad data page")?;
        dp.record(slot).and_then(|r| r.image()).ok_or("no index image")?
    };
    // RDB$INDEX_ID is the irt slot + 1 (both here and in the engine)
    let index_id = {
        let d = ix_descs.get(id_fid).ok_or("field beyond format")?;
        let vals = decode_record(&image, &ix_descs);
        match vals.get(id_fid) {
            Some(Value::Int(i)) => *i as usize,
            _ => return Err(format!("index {} has no id (dsc {:?})", index_name, d.dtype)),
        }
    };
    let temp = format!("RDB$TEMP_DEPEND_{}_{}", rel, index_id.saturating_sub(1));
    for (fid, val) in [
        (name_fid, SysVal::S(&temp)),
        (inactive_fid, SysVal::I(4)), // MET_index_deferred_drop
    ] {
        let d = ix_descs.get(fid).ok_or("field beyond format")?;
        let bytes = encode_sys_value(d, &val)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than format")?
            .copy_from_slice(&bytes);
        image[fid / 8] &= !(1 << (fid % 8)); // not NULL
    }
    dml::update_records(file, page_size, 4, &[(page, slot, image.clone())], ix_format_no)?;
    // the rename changed an INDEXED column of RDB$INDICES, so the new
    // key needs its own entries - the rewrite keeps the record's
    // position, so its record number is unchanged
    let seq = u32_at(
        crate::page_at(file, page_size, page).ok_or("data page out of range")?,
        16,
    ) as u64;
    let recno = seq * max_recs_per_dp(page_size) + slot as u64;
    let values = decode_record(&image, &ix_descs);
    maintain_indexes(file, page_size, 4, recno, &values, &ix_descs)?;
    let seg_fid = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
    delete_catalog_rows(file, page_size, "RDB$INDEX_SEGMENTS", |v| {
        text_is(v.get(seg_fid), &want)
    })?;
    // the index-root slot: irt_drop, flags cleared, root page kept
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    let slot = index_id.saturating_sub(1);
    if file.ddl_tx.is_some() {
        // the slot's state is COMMIT's to change (irt_commit -> irt_drop
        // on commit, -> irt_normal on rollback, ods.h:456): deferred
        file.ddl_deferred.push(crate::DdlDeferred::DropIndexSlot { irt_page, slot });
        return Ok(());
    }
    let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
    let at = 24 + slot * 24;
    if at + 24 > page.len() {
        return Err("index slot beyond the root page".into());
    }
    // irt_drop (6) with the flags cleared: the SETTLED shape an
    // engine-dropped index reaches (fcstat reads exactly this back off
    // an engine file once the dropping transaction is old). The engine
    // passes through irt_commit (5) first because its DDL runs inside a
    // transaction that has yet to commit; this writer's statement is
    // already committed when it returns, so the settled state is the
    // honest one - and it is the one gfix validates as clean, since a
    // state-5 index is still scanned while its segment rows are gone
    dml::put_u16(page, at + 18, 0); // irt_flags
    page[at + 20] = 6; // irt_drop (ods.h:456)
    Ok(())
}

/// Whether a column's `RDB$RELATION_FIELDS.RDB$NULL_FLAG` is set.
fn column_is_not_null(file: &crate::Image, page_size: usize, table: &str, col_up: &str) -> bool {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS") else {
        return false;
    };
    let Some(formats) = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS") else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(rn_f), Some(fn_f), Some(nf_f)) = (
        fid("RDB$RELATION_NAME"),
        fid("RDB$FIELD_NAME"),
        fid("RDB$NULL_FLAG"),
    ) else {
        return false;
    };
    let mut not_null = false;
    walk_rows(file, page_size, rel, descs, |values| {
        if text_is(values.get(rn_f), table) && text_is(values.get(fn_f), col_up) {
            not_null = int_eq(values.get(nf_f), 1);
        }
    });
    not_null
}

/// The next generated `INTEG_<n>` constraint name, read from the catalog
/// as it now stands (every writer takes its number this way, so the
/// sequence advances across mixed constraint kinds the way the engine's
/// does).
/// The next generated `INTEG_<n>` constraint name, from the engine's own
/// counter for it - the system generator `RDB$CONSTRAINT_NAME`. Every
/// unnamed constraint of a statement draws in the order the engine
/// writes them (NOT NULL rows in column order, then the key constraints
/// in declaration order, then the foreign keys).
fn next_integ_name(file: &mut crate::Image, page_size: usize) -> Result<String, String> {
    let used = used_numeric_suffixes(
        file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME", &["INTEG_"],
    )?;
    let fallback = used.iter().copied().max().unwrap_or(0) + 1;
    let n = draw_from_counter(
        file, page_size, "RDB$CONSTRAINT_NAME", false, 1, 1, &used, fallback,
    )?;
    Ok(format!("INTEG_{}", n))
}

/// Emit a `blr_field ctx <name>` operand (blr_field, context, len, name).
fn blr_field(b: &mut Vec<u8>, ctx: u8, name: &str) {
    b.push(23);
    b.push(ctx);
    b.push(name.len() as u8);
    b.extend_from_slice(name.as_bytes());
}

/// The BLR of a referential-action trigger the engine synthesises on the
/// referenced (parent) table, single or multi column, matched byte for
/// byte. The child (context 2) is scanned for rows keyed on the parent
/// row through OLD (context 0):
///
///   `FOR (child WHERE AND(child.fk_i = OLD.pk_i)) <action>`
///
/// wrapped, for the UPDATE event, in `IF OR(OLD.pk_i <> NEW.pk_i) THEN ...`.
/// The action is `ERASE` for a delete-cascade, or a `MODIFY` that assigns
/// each `child.fk_i` either `NEW.pk_i` (cascade) or `NULL` (set-null).
fn fk_trigger_blr(
    is_update: bool,
    action: RefAction,
    child_rel: &str,
    fk_cols: &[String],
    pk_cols: &[String],
) -> Vec<u8> {
    let set_null = action == RefAction::SetNull;
    let set_default = action == RefAction::SetDefault;
    let mut b = vec![5u8]; // blr_version5
    if set_default {
        // SET DEFAULT declares variables, so the whole trigger sits in a
        // begin..end; the default is fetched at RUNTIME, per column: a
        // PAIR of variables typed as the child column itself
        // (blr_column_name - flag 1 also carries the column's DEFAULT),
        // var2i := NULL, then a fault-swallowing block that initialises
        // var2i+1 (init_variable evaluates the declared default) and
        // copies it into var2i. A column with no default - or one whose
        // default fails to evaluate - leaves var2i NULL. Probed
        // byte-for-byte from the engine's own SET DEFAULT triggers.
        b.push(2); // blr_begin
        for (i, col) in fk_cols.iter().enumerate() {
            let v0 = (2 * i) as u16;
            let v1 = (2 * i + 1) as u16;
            for (v, flag) in [(v0, 0u8), (v1, 1u8)] {
                b.push(3); // blr_dcl_variable
                b.extend_from_slice(&v.to_le_bytes());
                b.push(21); // blr_column_name (dtype by column reference)
                b.push(flag);
                b.push(child_rel.len() as u8);
                b.extend_from_slice(child_rel.as_bytes());
                b.push(col.len() as u8);
                b.extend_from_slice(col.as_bytes());
            }
            b.push(1); // blr_assignment: NULL -> var2i
            b.push(45); // blr_null
            b.push(26); // blr_variable
            b.extend_from_slice(&v0.to_le_bytes());
            b.push(129); // blr_block
            b.push(2); // blr_begin
            b.push(184); // blr_init_variable var2i+1 (evaluates the default)
            b.extend_from_slice(&v1.to_le_bytes());
            b.push(1); // blr_assignment: var2i+1 -> var2i
            b.push(26);
            b.extend_from_slice(&v1.to_le_bytes());
            b.push(26);
            b.extend_from_slice(&v0.to_le_bytes());
            b.push(255); // blr_end (the block's begin)
            // blr_error_handler, 1 condition (any error), empty body
            b.extend_from_slice(&[130, 1, 0, 4, 2]);
            b.extend_from_slice(&[255, 255]); // end handler, end block
        }
    }
    if is_update {
        b.push(8); // blr_if
        // OR chain of OLD.pk_i <> NEW.pk_i
        for (i, pk) in pk_cols.iter().enumerate() {
            if i + 1 < pk_cols.len() {
                b.push(57); // blr_or
            }
            b.push(48); // blr_neq
            blr_field(&mut b, 0, pk);
            blr_field(&mut b, 1, pk);
        }
        b.push(2); // blr_begin (then branch)
        b.push(2); // blr_begin
    }
    b.push(7); // blr_for
    // the RSE: FOR (child WHERE AND(child.fk_i = OLD.pk_i))
    b.push(67); // blr_rse
    b.push(1); // stream count 1
    b.push(74); // blr_relation
    b.push(child_rel.len() as u8);
    b.extend_from_slice(child_rel.as_bytes());
    b.push(2); // context 2
    b.push(71); // blr_boolean
    for i in 0..fk_cols.len() {
        if i + 1 < fk_cols.len() {
            b.push(58); // blr_and
        }
        b.push(47); // blr_eql
        blr_field(&mut b, 2, &fk_cols[i]);
        blr_field(&mut b, 0, &pk_cols[i]);
    }
    b.push(255); // blr_end (rse)

    if !is_update && action == RefAction::Cascade {
        // delete cascade: ERASE the child row
        b.push(5); // blr_erase
        b.push(2); // context 2
    } else {
        // MODIFY: set each child.fk_i to NEW.pk_i (cascade), NULL
        // (set-null), or the runtime-fetched default in var2i
        b.push(10); // blr_modify
        b.push(2); // from context 2
        b.push(2); // to context 2
        b.push(2); // blr_begin
        for i in 0..fk_cols.len() {
            b.push(1); // blr_assignment
            if set_null {
                b.push(45); // blr_null
            } else if set_default {
                b.push(26); // blr_variable var2i
                b.extend_from_slice(&((2 * i) as u16).to_le_bytes());
            } else {
                blr_field(&mut b, 1, &pk_cols[i]); // NEW.pk_i
            }
            blr_field(&mut b, 2, &fk_cols[i]); // child.fk_i (target)
        }
        b.push(255); // blr_end (modify's begin)
        if is_update {
            b.extend_from_slice(&[255, 255, 255]); // for / begin / begin
        }
    }
    if set_default {
        b.push(255); // blr_end (the outer begin)
    }
    b.push(76); // blr_eoc
    b
}

/// Store one FK-cascade system trigger on the referenced (parent) table -
/// a `RDB$TRIGGERS` row named `CHECK_<n>` (number from the
/// `RDB$TRIGGER_NAME` generator), the `RDB$CHECK_CONSTRAINTS` row that
/// TIES that trigger to the foreign key's constraint name, plus the
/// three `RDB$DEPENDENCIES` rows the engine records (on the child
/// relation, the child FK column and the parent key column).
/// `trigger_type` is 4 for AFTER UPDATE, 6 for AFTER DELETE. The caller
/// must also refresh the parent's `RDB$RUNTIME` so the trigger is loaded
/// ([update_relation_runtime]).
///
/// THE LINK ROW IS NOT DECORATION. It is what makes the trigger part of
/// the constraint: `ALTER TABLE <child> DROP CONSTRAINT <fk>` follows
/// `RDB$CHECK_CONSTRAINTS` to find the triggers to delete. Without it
/// the constraint disappears from both catalogs and the unreferenced
/// `AFTER DELETE` trigger SURVIVES the drop and keeps cascading, so a
/// child row the engine's own database keeps is silently deleted on
/// fire-crab's file (measured; `gfix -v -full` reports rc=0 on it). The
/// engine writes one row per trigger, both carrying the FK's own
/// constraint name (measured: `INTEG_3 -> CHECK_1` and
/// `INTEG_3 -> CHECK_2` for an `ON UPDATE CASCADE ON DELETE SET NULL`).
#[allow(clippy::too_many_arguments)]
fn store_fk_trigger(
    file: &mut crate::Image,
    page_size: usize,
    parent: &str,
    child_rel: &str,
    fk_name: &str,
    fk_cols: &[String],
    pk_cols: &[String],
    trigger_type: i64,
    blr: &[u8],
) -> Result<(), String> {
    let n = {
        let slot = generator_id_by_name(file, page_size, "RDB$TRIGGER_NAME")
            .ok_or("no RDB$TRIGGER_NAME generator")?;
        gen::bump(file, page_size, slot, 1)?
    };
    let tname = format!("CHECK_{}", n);
    let rel = crate::resolve_relation(file, page_size, "RDB$TRIGGERS")
        .ok_or("no RDB$TRIGGERS relation")?;
    let blob = dml::insert_blob(file, page_size, rel, &[blr.to_vec()], 2)?; // subtype 2 = BLR
    sys_insert(
        file,
        page_size,
        "RDB$TRIGGERS",
        rel,
        &[
            ("RDB$TRIGGER_NAME", SysVal::S(&tname)),
            ("RDB$RELATION_NAME", SysVal::S(parent)),
            ("RDB$TRIGGER_SEQUENCE", SysVal::I(0)),
            ("RDB$TRIGGER_TYPE", SysVal::I(trigger_type)),
            ("RDB$TRIGGER_BLR", SysVal::B(blob_id_bytes(rel, blob))),
            ("RDB$TRIGGER_INACTIVE", SysVal::I(0)),
            ("RDB$SYSTEM_FLAG", SysVal::I(4)),
            ("RDB$FLAGS", SysVal::I(3)),
            ("RDB$VALID_BLR", SysVal::I(1)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ],
    )?;
    // the link that makes this trigger part of the constraint - what a
    // later DROP CONSTRAINT follows to take the trigger with it
    sys_row_by_name(file, page_size, "RDB$CHECK_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(fk_name)),
        ("RDB$TRIGGER_NAME", SysVal::S(&tname)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    let dep = |file: &mut crate::Image, on: &str, field: Option<&str>| -> Result<(), String> {
        let mut row = vec![
            ("RDB$DEPENDENT_NAME", SysVal::S(&tname)),
            ("RDB$DEPENDED_ON_NAME", SysVal::S(on)),
            ("RDB$DEPENDENT_TYPE", SysVal::I(2)),   // obj_trigger
            ("RDB$DEPENDED_ON_TYPE", SysVal::I(0)), // obj_relation
            ("RDB$DEPENDENT_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$DEPENDED_ON_SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if let Some(f) = field {
            row.push(("RDB$FIELD_NAME", SysVal::S(f)));
        }
        let drel = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES")
            .ok_or("no RDB$DEPENDENCIES relation")?;
        sys_insert(file, page_size, "RDB$DEPENDENCIES", drel, &row)
    };
    for fk_col in fk_cols {
        dep(file, child_rel, Some(fk_col))?;
    }
    dep(file, child_rel, None)?;
    for pk_col in pk_cols {
        dep(file, parent, Some(pk_col))?;
    }
    Ok(())
}

/// Rebuild a relation's `RDB$RUNTIME` and patch it into the RDB$RELATIONS
/// row in place - the way to make a newly written trigger loadable, since
/// [rebuild_runtime_blob] now folds the relation's trigger names into the
/// summary the engine loads triggers from.
fn update_relation_runtime(file: &mut crate::Image, page_size: usize, table: &str) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let descs = descs.clone();
    let runtime = rebuild_runtime_blob(file, page_size, table, &descs)?;
    let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
    let nm = table.to_string();
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATIONS",
        6,
        move |v| text_is(v.get(name_fid), &nm),
        &[("RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime)))],
    )
}

/// Write one FOREIGN KEY onto a table: the referencing index (irt_foreign,
/// naming the partner PK index, with the partner-schema column that makes
/// MET_lookup_partner find it - see [create_index]), the RDB$RELATION_
/// CONSTRAINTS 'FOREIGN KEY' row, the RDB$REF_CONSTRAINTS row linking to the
/// referenced table's PK constraint (MATCH FULL), and - for a CASCADE
/// action - the system trigger(s) the engine synthesises on the referenced
/// table (single column), refreshing that table's RDB$RUNTIME so they load.
/// Shared by create_table and ALTER TABLE ADD CONSTRAINT.
fn write_foreign_key_full(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fk_name: &str,
    fk: &ForeignKeyDef,
    synth_triggers: bool,
) -> Result<(), String> {
    let (uq_constraint, partner_index) =
        find_partner_key(file, page_size, &fk.ref_table, &fk.ref_columns).ok_or_else(|| {
            if fk.ref_columns.is_empty() {
                format!("referenced table {} has no primary key", fk.ref_table)
            } else {
                format!(
                    "referenced table {} has no primary key or unique constraint on ({})",
                    fk.ref_table,
                    fk.ref_columns.join(", ")
                )
            }
        })?;
    // THE PARTNER KEY MUST ACTUALLY FIT - checked HERE, before one byte
    // of the index or the catalog rows is written. A foreign key the
    // engine refuses is not a harmless divergence: fire-crab does NOT
    // enforce the key it wrote, the ENGINE reading the same file DOES,
    // so the two servers disagree about the file's rows - and `gbak -c`
    // of the result fails outright (`cannot commit index ... Database is
    // not online due to failure to activate one or more indices`), which
    // makes the database unrestorable. Refusing is the only answer.
    check_partner_compatible(file, page_size, table, fk, &partner_index)?;
    create_index(
        file, page_size, table, fk_name, &fk.columns, false, false, false,
        Some(&partner_index),
    )?;
    sys_row_by_name(file, page_size, "RDB$RELATION_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(fk_name)),
        ("RDB$CONSTRAINT_TYPE", SysVal::S("FOREIGN KEY")),
        ("RDB$RELATION_NAME", SysVal::S(table)),
        ("RDB$INDEX_NAME", SysVal::S(fk_name)),
        ("RDB$DEFERRABLE", SysVal::S("NO")),
        ("RDB$INITIALLY_DEFERRED", SysVal::S("NO")),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    sys_row_by_name(file, page_size, "RDB$REF_CONSTRAINTS", &[
        ("RDB$CONSTRAINT_NAME", SysVal::S(fk_name)),
        ("RDB$CONST_NAME_UQ", SysVal::S(&uq_constraint)),
        ("RDB$MATCH_OPTION", SysVal::S("FULL")),
        ("RDB$UPDATE_RULE", SysVal::S(fk.on_update.rule())),
        ("RDB$DELETE_RULE", SysVal::S(fk.on_delete.rule())),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$CONST_SCHEMA_NAME_UQ", SysVal::S("PUBLIC")),
    ])?;

    // a CASCADE / SET NULL action synthesises a system trigger on the
    // referenced (parent) table - the update trigger first (the engine
    // numbers it CHECK_<lower>), then delete - and the parent's RDB$RUNTIME
    // is refreshed so the engine loads them
    if synth_triggers
        && (fk.on_update.synthesises_trigger() || fk.on_delete.synthesises_trigger())
    {
        let parent = fk.ref_table.trim().to_string();
        let pk_cols = if fk.ref_columns.is_empty() {
            index_segment_columns(file, page_size, &partner_index)?
        } else {
            fk.ref_columns.clone()
        };
        if fk.columns.len() != pk_cols.len() {
            return Err("foreign key column count does not match the referenced key".into());
        }
        let mut make = |is_update: bool, action: RefAction, ttype: i64| -> Result<(), String> {
            if !action.synthesises_trigger() {
                return Ok(());
            }
            let blr = fk_trigger_blr(is_update, action, table, &fk.columns, &pk_cols);
            store_fk_trigger(
                file, page_size, &parent, table, fk_name, &fk.columns, &pk_cols, ttype, &blr,
            )
        };
        make(true, fk.on_update, 4)?;
        make(false, fk.on_delete, 6)?;
        update_relation_runtime(file, page_size, &parent)?;
    }
    Ok(())
}

/// `ALTER TABLE <table> ADD [CONSTRAINT <name>] FOREIGN KEY (...)
/// REFERENCES ...`: add a foreign key to an EXISTING table. The FK index
/// is built and backfilled over the table's committed rows, then the
/// constraint catalog rows are written - the same shape create_table
/// produces, so the engine reads and gbak restores it identically.
pub fn alter_table_add_foreign_key(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fk: &ForeignKeyDef,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let name = table.trim().to_string();
    let fk_name = if fk.name.is_empty() {
        next_integ_name(file, page_size)?
    } else {
        fk.name.clone()
    };
    write_foreign_key_full(file, page_size, &name, &fk_name, fk, true)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// The gbak-restore variant: the referential-action TRIGGERS arrive
/// CARRIED in the file (the engine's own BLR, stored verbatim by the
/// caller), so this must not synthesise its own - two CHECK_<n>
/// triggers for one rule was the first restore's duplicate-key
/// failure, measured.
pub fn alter_table_add_foreign_key_carried(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    fk: &ForeignKeyDef,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let name = table.trim().to_string();
    let fk_name = if fk.name.is_empty() {
        next_integ_name(file, page_size)?
    } else {
        fk.name.clone()
    };
    write_foreign_key_full(file, page_size, &name, &fk_name, fk, false)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// The referenced table's key a foreign key partners with: (constraint
/// name, index name), read from RDB$RELATION_CONSTRAINTS. An FK's
/// RDB$REF_CONSTRAINTS row names the unique CONSTRAINT (INTEG_n or the
/// name it was given), and its index is the partner MET_lookup_partner
/// links to. With no referenced columns named, that is the table's
/// PRIMARY KEY; with columns named, it is the PRIMARY KEY or UNIQUE
/// constraint whose index carries exactly those columns in that order
/// (probed: `REFERENCES A1 (Y)` onto a UNIQUE(Y) links the FK to the
/// UNIQUE constraint and its index, not the table's primary key).
/// A table's PRIMARY KEY column names in key order, from
/// `RDB$RELATION_CONSTRAINTS` + `RDB$INDEX_SEGMENTS` - `None` when the
/// table has no primary key. The wire server's UPDATE OR INSERT takes
/// this as its implicit MATCHING list, exactly as the engine does
/// (StmtNodes.cpp `UpdateOrInsertNode`).
pub fn primary_key_columns(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Option<Vec<String>> {
    let (_, index) = find_partner_key(file, page_size, table, &[])?;
    let cols = index_segment_names(file, page_size, &index);
    if cols.is_empty() { None } else { Some(cols) }
}

/// The engine's message for a foreign key whose column count does not
/// match the key it references (`isc_foreign_key_notfound`'s sibling,
/// 335544604, under a -607 "Invalid command"). Spelled here EXACTLY as
/// the engine spells it: the wire server recognises it by text and
/// rebuilds the engine's own error vector from it, so a client can tell
/// this refusal from the type one.
/// DYN 126 (336068734), the engine's refusal when two PRIMARY KEY /
/// UNIQUE constraints of one table name the same SET of columns.
/// Spelled here exactly as the engine spells it - the wire server
/// recognises it by text and rebuilds the engine's vector from it.
pub(crate) const SAME_KEY_COLUMNS_MSG: &str =
    "Same set of columns cannot be used in more than one PRIMARY KEY and/or UNIQUE constraint definition";

pub(crate) const FK_ARITY_MSG: &str = "FOREIGN KEY column count does not match PRIMARY KEY";

/// `isc_partner_idx_incompat_type` (335544852), whose one argument is
/// the 1-BASED number of the FIRST segment that does not fit (measured:
/// a two-column FK whose second column is wrong says `no 2`).
pub(crate) fn fk_incompat_msg(segment: usize) -> String {
    format!("partner index segment no {} has incompatible data type", segment)
}

/// THE INDEX-KEY CLASS of a stored column: two columns may be the two
/// ends of one foreign key exactly when they share it.
///
/// **Measured on the engine, 2026-09-03**, by building a parent table
/// per type and a child column per type against it (24 x 24 pairs plus
/// precision, charset, collation and domain probes) and reading which
/// `CREATE TABLE ... REFERENCES` it accepted. What it refuses it
/// refuses with `partner index segment no 1 has incompatible data
/// type`; the classes measured are:
///
/// | class | types |
/// |---|---|
/// | 0 | SMALLINT, INTEGER, FLOAT, DOUBLE PRECISION, NUMERIC/DECIMAL of precision <= 9 (any scale) |
/// | 1 | BIGINT, NUMERIC/DECIMAL of precision 10..18 |
/// | 2 | INT128, NUMERIC/DECIMAL of precision 19..38 |
/// | 3 | DATE | 4 | TIME | 5 | TIMESTAMP |
/// | 6 | BOOLEAN | 7 | DECFLOAT(16) *and* DECFLOAT(34) together |
/// | 8/9 | TIME WITH TIME ZONE / TIMESTAMP WITH TIME ZONE, each its own |
/// | text | CHAR and VARCHAR alike, keyed on the TTYPE - character set AND collation |
///
/// The consequences worth stating, all measured: the declared LENGTH of
/// a string never matters (`VARCHAR(80)` keys against `CHAR(5)`), and
/// CHAR vs VARCHAR never matters, but the CHARACTER SET does (NONE,
/// OCTETS and WIN1252 are three classes) and so does the COLLATION
/// (`UTF8` and `UTF8 COLLATE UNICODE` are two). Scale never matters
/// inside a numeric class, but PRECISION picks the class, because it
/// picks the storage type. A DOMAIN behaves exactly as its base type on
/// either side.
///
/// This is the same partition [index_itype] draws for the key ENCODING -
/// which is why it is a partition at all: two columns can share one
/// index only if their keys are built the same way. It is stated
/// separately because a class here need not be an itype this crate can
/// key (DECFLOAT), and because the text case must carry the whole ttype
/// where an itype folds the untabled ones together.
///
/// `None` for a type that cannot be an index key at all (BLOB, ARRAY) -
/// the engine refuses those too.
fn key_class(d: &Descriptor) -> Option<u32> {
    use crate::format::dtype;
    Some(match d.dtype {
        dtype::SHORT | dtype::LONG | dtype::REAL | dtype::DOUBLE => 0,
        dtype::INT64 => 1,
        dtype::INT128 => 2,
        dtype::SQL_DATE => 3,
        dtype::SQL_TIME => 4,
        dtype::TIMESTAMP => 5,
        dtype::BOOLEAN => 6,
        // DECFLOAT(16) and DECFLOAT(34) key together - measured, they
        // are the one pair of DIFFERENT dtypes that share a class
        dtype::DEC64 | dtype::DEC128 => 7,
        dtype::SQL_TIME_TZ => 8,
        dtype::TIMESTAMP_TZ => 9,
        dtype::EX_TIME_TZ => 10,
        dtype::EX_TIMESTAMP_TZ => 11,
        // the descriptor's sub_type IS the ttype for text: character set
        // in the low byte, collation in the high one. Both discriminate
        // (measured), and the length does not - so the whole ttype rides
        // into the class and nothing else about the column does.
        dtype::TEXT | dtype::VARYING => 0x1_0000 | (d.sub_type as u16 as u32),
        _ => return None,
    })
}

/// The [key_class] of one named column of one named relation, read from
/// the relation's newest stored format - so a DOMAIN-typed column
/// answers its RESOLVED type, exactly as the engine's own comparison
/// does. `None` when the column, the relation or its format is not
/// there, or when the type cannot be an index key.
fn column_key_class(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    column: &str,
) -> Option<u32> {
    let rel = crate::resolve_relation(file, page_size, table)?;
    let fid = relation_columns(file, page_size, table)
        .into_iter()
        .find(|c| c.name == column)?
        .field_id as usize;
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    key_class(descs.get(fid)?)
}

/// Refuse a foreign key the engine would refuse, BEFORE anything is
/// written: the referencing columns must be as MANY as the partner
/// index's segments, and each must be of a type that keys the same way
/// as the segment it is paired with ([key_class]).
///
/// Both were missing, and both produced a database the engine's own
/// `gbak -c` could not restore - the arity one additionally producing a
/// key fire-crab did not enforce and the engine did, so the two servers
/// read different data out of one file.
fn check_partner_compatible(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    fk: &ForeignKeyDef,
    partner_index: &str,
) -> Result<(), String> {
    let partner_cols = index_segment_names(file, page_size, partner_index);
    if partner_cols.is_empty() {
        return Err(format!("partner index {} has no segments", partner_index));
    }
    if partner_cols.len() != fk.columns.len() {
        return Err(FK_ARITY_MSG.to_string());
    }
    let parent = fk.ref_table.trim();
    for (i, (child, key)) in fk.columns.iter().zip(partner_cols.iter()).enumerate() {
        let a = column_key_class(file, page_size, table, child);
        let b = column_key_class(file, page_size, parent, key);
        if a.is_none() || a != b {
            return Err(fk_incompat_msg(i + 1));
        }
    }
    Ok(())
}
fn find_partner_key(
    file: &crate::Image,
    page_size: usize,
    ref_table: &str,
    ref_columns: &[String],
) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (cn_f, ct_f, rn_f, ix_f) = (
        fid("RDB$CONSTRAINT_NAME")?,
        fid("RDB$CONSTRAINT_TYPE")?,
        fid("RDB$RELATION_NAME")?,
        fid("RDB$INDEX_NAME")?,
    );
    let want = ref_table.trim().to_string();
    // every PRIMARY KEY / UNIQUE constraint of the referenced table,
    // primaries first (they win when both would fit)
    let mut candidates: Vec<(bool, String, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |values| {
        let txt = |i: usize| match values.get(i) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        if txt(rn_f).as_deref() != Some(want.as_str()) {
            return;
        }
        let primary = match txt(ct_f).as_deref() {
            Some("PRIMARY KEY") => true,
            Some("UNIQUE") => false,
            _ => return,
        };
        if let (Some(cn), Some(ix)) = (txt(cn_f), txt(ix_f)) {
            candidates.push((primary, cn, ix));
        }
    });
    candidates.sort_by_key(|(primary, _, _)| !*primary);
    if ref_columns.is_empty() {
        let (_, cn, ix) = candidates.into_iter().find(|(primary, _, _)| *primary)?;
        return Some((cn, ix));
    }
    candidates
        .into_iter()
        .find(|(_, _, ix)| {
            let segs = index_segment_names(file, page_size, ix);
            segs.len() == ref_columns.len()
                && segs
                    .iter()
                    .zip(ref_columns)
                    .all(|(a, b)| a == b)
        })
        .map(|(_, cn, ix)| (cn, ix))
}

/// An index's columns in key order, from RDB$INDEX_SEGMENTS.
fn index_segment_names(file: &crate::Image, page_size: usize, index_name: &str) -> Vec<String> {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS") else {
        return Vec::new();
    };
    let Some(formats) = system_relation_formats(file, page_size, "RDB$INDEX_SEGMENTS") else {
        return Vec::new();
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return Vec::new();
    };
    let cols = relation_columns(file, page_size, "RDB$INDEX_SEGMENTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(ix_f), Some(fn_f), Some(pos_f)) = (
        fid("RDB$INDEX_NAME"),
        fid("RDB$FIELD_NAME"),
        fid("RDB$FIELD_POSITION"),
    ) else {
        return Vec::new();
    };
    let mut segs: Vec<(i64, String)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |values| {
        if !text_is(values.get(ix_f), index_name) {
            return;
        }
        let pos = match values.get(pos_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        if let Some(Value::Text(t)) = values.get(fn_f) {
            segs.push((pos, t.trim_end().to_string()));
        }
    });
    segs.sort_by_key(|(pos, _)| *pos);
    segs.into_iter().map(|(_, n)| n).collect()
}

/// The next generated index number. The engine draws the `RDB$<n>` name
/// of an unnamed UNIQUE index, the `RDB$PRIMARY<n>` name of an unnamed
/// PRIMARY KEY index and the `RDB$FOREIGN<n>` name of an unnamed
/// FOREIGN KEY index from ONE counter, the system generator
/// `RDB$INDEX_NAME` (probed: a table declaring UNIQUE then PRIMARY KEY
/// got RDB$7 and RDB$PRIMARY8; a fresh database reaches GEN_ID 6 after
/// five generated index names). All three spellings are therefore
/// already-used numbers for [draw_from_counter] to step over.
fn next_index_number(file: &mut crate::Image, page_size: usize) -> Result<u64, String> {
    let used = used_numeric_suffixes(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME", &[
        "RDB$PRIMARY",
        "RDB$FOREIGN",
        "RDB$",
    ])?;
    let fallback = used.iter().copied().max().unwrap_or(0) + 1;
    draw_from_counter(file, page_size, "RDB$INDEX_NAME", false, 1, 1, &used, fallback)
}

/// Every `<prefix><n>` number already spelled in a catalog column. The
/// prefixes are tried in order and the first that leaves a number wins,
/// so a longer spelling (`RDB$PRIMARY`) must precede the shorter one it
/// starts with (`RDB$`).
fn used_numeric_suffixes(
    file: &crate::Image,
    page_size: usize,
    rel_name: &str,
    col: &str,
    prefixes: &[&str],
) -> Result<std::collections::HashSet<u64>, String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)
        .ok_or_else(|| format!("no {} relation", rel_name))?;
    let formats = system_relation_formats(file, page_size, rel_name)
        .ok_or("no computed system format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let fid = relation_columns(file, page_size, rel_name)
        .iter()
        .find(|c| c.name == col)
        .map(|c| c.field_id as usize)
        .ok_or_else(|| format!("no {} column", col))?;
    let mut used = std::collections::HashSet::new();
    walk_rows(file, page_size, rel, descs, |values| {
        if let Some(Value::Text(t)) = values.get(fid) {
            let t = t.trim_end();
            for prefix in prefixes {
                if let Some(num) =
                    t.strip_prefix(prefix).and_then(|x| x.parse::<u64>().ok())
                {
                    used.insert(num);
                    break;
                }
            }
        }
    });
    Ok(used)
}

/// Draw `count` consecutive numbers from one of the engine's own
/// metadata counters - the system generators the DDL names its objects
/// from.
///
/// This is the whole of the divergence this module used to carry.
/// Firebird never asks the catalog what number is free: `DYN_UTIL_*`
/// draws from a system generator (`RDB$RELATIONS` for a new relation's
/// id, `RDB$INDEX_NAME`, `RDB$CONSTRAINT_NAME`, `RDB$FIELD_NAME`,
/// `RDB$GENERATOR_NAME` for the generated names), and a generator only
/// ever moves forward - `DROP` gives nothing back. Choosing "one past
/// the highest in use" instead hands back a number the engine has
/// retired, so after the first DROP the two servers name every later
/// object differently, and on a file both servers write, fire-crab
/// picks the very number the engine's counter is about to issue: two
/// objects, one name. Reading the counter is also cheaper than the
/// walk, and, being the engine's own state, it stays right when the
/// engine writes the next object itself.
///
/// `holds_next` distinguishes the two spellings the engine uses:
/// `RDB$RELATIONS` stores the id to use NEXT (a fresh database reads
/// 128 and its first table IS 128), while every name counter stores the
/// number last issued (a fresh database reads 0 and the first name is
/// 1).
///
/// A number already spelled in the catalog is stepped over rather than
/// re-used - a database whose counter lags behind its own objects (one
/// restored from a backup, or written by an older fire-crab) then heals
/// instead of colliding. Each attempt writes a strictly larger value,
/// so this ends; it cannot return a number in use, and a draw of one or
/// more numbers always leaves the counter moved past them. A draw of
/// NONE (a table all of whose columns name a user domain) leaves the
/// counter alone - it is the engine's, and a statement that mints no
/// name must not move it.
fn draw_from_counter(
    file: &mut crate::Image,
    page_size: usize,
    counter: &str,
    holds_next: bool,
    floor: u64,
    count: u64,
    used: &std::collections::HashSet<u64>,
    fallback: u64,
) -> Result<u64, String> {
    // nothing to name: the counter is the engine's, and a statement that
    // mints no name must not move it
    if count == 0 {
        return Ok(fallback);
    }
    let Some(slot) = generator_id_by_name(file, page_size, counter) else {
        return Ok(fallback);
    };
    // a database whose generator vector never grew to hold this slot
    // keeps the old walk rather than failing the statement
    if gen::slot_offset(file, page_size, slot).is_none() {
        return Ok(fallback);
    }
    let cur = gen::read(file, page_size, slot).max(0) as u64;
    let (first, store) = pick_run(cur, holds_next, floor, count, used)
        .ok_or_else(|| format!("{}: no free number for {} name(s)", counter, count))?;
    gen::write(file, page_size, slot, store as i64)?;
    Ok(first)
}

/// One attempt at a run of `count` numbers from a counter reading `cur`:
/// the first number of the run, and the value to leave in the counter.
/// `holds_next` counters (RDB$RELATIONS) store the number to issue NEXT,
/// the name counters the number last issued.
fn counter_run(cur: u64, holds_next: bool, floor: u64, count: u64) -> (u64, u64) {
    let first = if holds_next { cur.max(floor) } else { cur.saturating_add(1).max(floor) };
    let last = first.saturating_add(count.saturating_sub(1));
    (first, if holds_next { last.saturating_add(1) } else { last })
}

/// The run [draw_from_counter] settles on: the first free run of `count`
/// consecutive numbers at or after what the counter reads, and the value
/// to leave behind. `None` only if `used` is so dense that stepping over
/// every number in it still found nothing - impossible for a finite set,
/// since each attempt starts past the last, so it is the loop's bound
/// rather than a reachable answer.
fn pick_run(
    cur: u64,
    holds_next: bool,
    floor: u64,
    count: u64,
    used: &std::collections::HashSet<u64>,
) -> Option<(u64, u64)> {
    let mut cur = cur;
    for _ in 0..=used.len() {
        let (first, store) = counter_run(cur, holds_next, floor, count);
        if !(first..first + count).any(|n| used.contains(&n)) {
            return Some((first, store));
        }
        cur = store;
    }
    None
}

/// The id a new relation takes. `RDB$RELATIONS` is the engine's counter
/// for it and holds the id to use next; `rels` is the catalog as it
/// stands, both to floor the counter and to step over an id a lagging
/// counter would otherwise hand out twice. A relation id is a `u16` on
/// every page header that names it, so exhausting the range is an
/// error, never a wrap.
/// The next free relation id, for a caller that must stamp it into a row
/// BEFORE the row is written.
///
/// It has to be before. `sys_insert` keys the record into every index of
/// its relation as it writes it, and `patch_sys_row` does NOT - so a row
/// stored with a NULL id and patched afterwards keeps the `RDB$INDEX_1`
/// key it was given when the id was null. The engine finds a relation by
/// NAME and then re-finds it BY ID through that index (`jrd_rel::scan`,
/// `WITH REL.RDB$RELATION_ID EQ getId()`), so the second probe misses
/// and the table is answered `-204 Table unknown` - with a catalog that
/// reads correctly in every column. The engine avoids the whole problem
/// by assigning the id in a BEFORE-insert trigger
/// (`SystemTriggers::beforeInsertRelation`, which asserts the client did
/// not supply one).
pub fn next_free_relation_id(file: &mut crate::Image, page_size: usize) -> Result<u16, String> {
    let rels = crate::catalog::list_relations(file, page_size);
    next_relation_id(file, page_size, &rels)
}

fn next_relation_id(
    file: &mut crate::Image,
    page_size: usize,
    rels: &[(u16, String)],
) -> Result<u16, String> {
    let used: std::collections::HashSet<u64> = rels.iter().map(|(id, _)| *id as u64).collect();
    let fallback = rels.iter().map(|(id, _)| *id).max().unwrap_or(127).max(127) as u64 + 1;
    let id = draw_from_counter(file, page_size, "RDB$RELATIONS", true, 128, 1, &used, fallback)?;
    u16::try_from(id).map_err(|_| "no relation id left".to_string())
}

/// [sys_insert] with the relation id resolved by name - for catalog
/// relations whose ids this module does not hardcode.
fn sys_row_by_name(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    values: &[(&str, SysVal<'_>)],
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)
        .ok_or_else(|| format!("no {} relation", rel_name))?;
    sys_insert(file, page_size, rel_name, rel, values)
}

/// The index key type for a stored column (`DFW_assign_index_type`,
/// dfw.epp:1236) - None for a type this write path cannot key.
fn index_itype(d: &Descriptor) -> Option<u16> {
    use crate::format::dtype;
    Some(match d.dtype {
        dtype::SHORT | dtype::LONG | dtype::REAL | dtype::DOUBLE => btw::IDX_NUMERIC,
        dtype::INT64 => btw::IDX_NUMERIC2,
        dtype::INT128 => btw::IDX_BCD, // ODS >= 13.1 (dfw.epp)
        dtype::TEXT | dtype::VARYING => btw::IDX_STRING,
        dtype::SQL_DATE => 5,  // idx_sql_date
        dtype::SQL_TIME => 6,  // idx_sql_time
        dtype::TIMESTAMP => 7, // idx_timestamp
        dtype::BOOLEAN => 9,   // idx_boolean
        _ => return None,
    })
}

/// Whether an index of `index_name` already exists (any relation).
fn index_name_taken(file: &crate::Image, page_size: usize, index_name: &str) -> Result<bool, String> {
    let irel = crate::resolve_relation(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES relation")?;
    let formats = system_relation_formats(file, page_size, "RDB$INDICES")
        .ok_or("no computed system format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let name_fid = relation_columns(file, page_size, "RDB$INDICES")
        .iter()
        .find(|c| c.name == "RDB$INDEX_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$INDEX_NAME column")?;
    let mut taken = false;
    walk_rows(file, page_size, irel, descs, |values| {
        if let Some(Value::Text(t)) = values.get(name_fid) {
            if t.trim_end() == index_name {
                taken = true;
            }
        }
    });
    Ok(taken)
}

/// CREATE INDEX: a new irt slot (tx 0, state normal - the settled
/// shape every long-lived index shows; a freshly engine-created one
/// idles in state 2 until touched), the irtd segment array carved
/// downward from the irt page's tail (the engine's own allocation,
/// probe: slot0 at page_size-8, slot1 below it), an empty root
/// bucket, the RDB$PAGES + RDB$INDICES + RDB$INDEX_SEGMENTS rows, and
/// a BACKFILL: every existing committed row keyed and inserted, with
/// unique/primary enforcement - a duplicate fails the whole statement
/// exactly like the engine's index build does.
#[allow(clippy::too_many_arguments)]
pub fn create_index(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    index_name: &str,
    col_names: &[String],
    unique: bool,
    descending: bool,
    primary: bool,
    // Some(partner index) makes this a FOREIGN KEY index: the irt gets
    // irt_foreign and RDB$INDICES names the partner (referenced) PK/unique
    // index in RDB$FOREIGN_KEY (+ its schema). MET_lookup_partner links FK
    // to partner purely through these two columns (met.epp:2401-2412) - the
    // schema column is the ODS-14 field the older attempts missed.
    foreign_key: Option<&str>,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    if index_name_taken(file, page_size, index_name)? {
        return Err(format!("index {} already exists", index_name));
    }
    let columns = relation_columns(file, page_size, table);
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;

    // segments: (field id, itype, scale) in key order
    let mut segs: Vec<(u16, u16, i8)> = Vec::new();
    // a column name arrives CANONICAL (a quoted one exact, a bare one
    // folded), so the match is exact - `"a"` beside `A` keys `a`
    for n in col_names {
        let rc = columns
            .iter()
            .find(|c| c.name == *n)
            .ok_or_else(|| format!("unknown column {}", n))?;
        let d = descs
            .get(rc.field_id as usize)
            .ok_or("field beyond format")?;
        // a COMPUTED column has no stored bytes to key on - the build
        // would index the null-flag area
        if d.offset == 0 && d.length != 0 {
            return Err(format!("column {} is computed - not indexable", n));
        }
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }
    if segs.is_empty() {
        return Err("an index needs at least one column".into());
    }

    let mut iflags = 0u16;
    if unique {
        iflags |= btw::IRT_UNIQUE;
    }
    if descending {
        iflags |= btw::IRT_DESCENDING;
    }
    if primary {
        iflags |= btw::IRT_PRIMARY; // ods.h:462
    }
    if foreign_key.is_some() {
        iflags |= btw::IRT_FOREIGN; // ods.h:461
    }
    let slot = allocate_index_slot(file, page_size, rel, &segs, iflags)?;

    // catalog rows. NOTE: the bucket page is NOT registered in
    // RDB$PAGES - only pag_pointer/pag_root/pag_transactions/pag_ids
    // rows are legal there (DPM_scan_pages CORRUPTs on anything else,
    // engine-error 257 caught live); B-tree pages are reachable only
    // through the relation's index root slots
    let table_upper = table.to_string();
    let mut ivals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$INDEX_NAME", SysVal::S(index_name)),
        ("RDB$RELATION_NAME", SysVal::S(&table_upper)),
        ("RDB$INDEX_ID", SysVal::I(slot as i64 + 1)),
        ("RDB$UNIQUE_FLAG", SysVal::I(if unique { 1 } else { 0 })),
        ("RDB$SEGMENT_COUNT", SysVal::I(segs.len() as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$INDEX_INACTIVE", SysVal::I(0)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    // probe: a PK's RDB$INDEX_TYPE is NULL, a user index carries 0/1; a
    // FOREIGN KEY index also leaves RDB$INDEX_TYPE NULL (engine-probed)
    if !primary && foreign_key.is_none() {
        ivals.push(("RDB$INDEX_TYPE", SysVal::I(if descending { 1 } else { 0 })));
    }
    // a foreign-key index names its partner (referenced unique) index. Both
    // the name AND its schema are required: MET_lookup_partner's self-join
    // matches IND.RDB$SCHEMA_NAME EQ IDX.RDB$FOREIGN_KEY_SCHEMA_NAME
    // (met.epp:2408) - omitting the schema column leaves it NULL and the
    // partner lookup silently fails ("Partner index does not exist") at
    // gbak restore, which is what blocked the two earlier FK attempts.
    if let Some(partner) = foreign_key {
        ivals.push(("RDB$FOREIGN_KEY", SysVal::S(partner)));
        ivals.push(("RDB$FOREIGN_KEY_SCHEMA_NAME", SysVal::S("PUBLIC")));
    }
    sys_row_by_name(file, page_size, "RDB$INDICES", &ivals)?;
    for (pos, n) in col_names.iter().enumerate() {
        // the segment names the column's EXACT catalog spelling
        sys_row_by_name(file, page_size, "RDB$INDEX_SEGMENTS", &[
            ("RDB$INDEX_NAME", SysVal::S(index_name)),
            ("RDB$FIELD_NAME", SysVal::S(n)),
            ("RDB$FIELD_POSITION", SysVal::I(pos as i64)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ])?;
    }

    backfill_index(
        file, page_size, rel, slot, &segs, descs, unique, descending, primary,
    )?;
    // the selectivity the engine computes at build time and keeps in
    // three places
    let sel = index_selectivity(file, page_size, rel, &segs, descending)?;
    write_index_statistics(file, page_size, rel, slot, index_name, &sel, true)
}

/// `CREATE INDEX ... COMPUTED BY (<expr>)` from a CARRIED expression:
/// the RDB$INDICES row keeps the engine's BLR and source verbatim
/// (segment count 0, no segment rows), the irt repeat takes
/// IRT_EXPRESSION with ONE key descriptor of the expression's result
/// type, and the backfill keys every committed row on `eval`'s answer -
/// the CALLER evaluates the expression (the BLR walker lives with the
/// executor), this writer only builds what it is handed.
#[allow(clippy::too_many_arguments)]
pub fn create_expression_index(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    index_name: &str,
    unique: bool,
    descending: bool,
    key_itype: u16,
    expr_blr: &[u8],
    expr_source: &str,
    eval: &mut dyn FnMut(&[Value]) -> Result<Value, String>,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, table)
        .ok_or_else(|| format!("table {} not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    if index_name_taken(file, page_size, index_name)? {
        return Err(format!("index {} already exists", index_name));
    }
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .map(|(n, d)| (*n, d.clone()))
        .ok_or("relation has no format")?;
    let segs: Vec<(u16, u16, i8)> = vec![(0, key_itype, 0)];
    let mut iflags = btw::IRT_EXPRESSION;
    if unique {
        iflags |= btw::IRT_UNIQUE;
    }
    if descending {
        iflags |= btw::IRT_DESCENDING;
    }
    let slot = allocate_index_slot(file, page_size, rel, &segs, iflags)?;
    let irel = crate::resolve_relation(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES relation")?;
    let blr_blob = dml::insert_blob(file, page_size, irel, &[expr_blr.to_vec()], 2)?;
    let src_blob =
        dml::insert_blob_cs(file, page_size, irel, &[expr_source.as_bytes().to_vec()], 1, 4)?;
    let table_upper = table.to_string();
    sys_row_by_name(file, page_size, "RDB$INDICES", &[
        ("RDB$INDEX_NAME", SysVal::S(index_name)),
        ("RDB$RELATION_NAME", SysVal::S(&table_upper)),
        ("RDB$INDEX_ID", SysVal::I(slot as i64 + 1)),
        ("RDB$UNIQUE_FLAG", SysVal::I(if unique { 1 } else { 0 })),
        ("RDB$SEGMENT_COUNT", SysVal::I(0)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$INDEX_INACTIVE", SysVal::I(0)),
        ("RDB$INDEX_TYPE", SysVal::I(if descending { 1 } else { 0 })),
        ("RDB$EXPRESSION_BLR", SysVal::B(blob_id_bytes(irel, blr_blob))),
        ("RDB$EXPRESSION_SOURCE", SysVal::B(blob_id_bytes(irel, src_blob))),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ])?;
    // backfill on the EVALUATED expression, one key per committed row
    let recs = max_recs_per_dp(page_size);
    let mut distinct: Vec<Vec<u8>> = Vec::new();
    let mut total = 0u64;
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        let seq = dp.sequence as u64;
        let rows: Vec<(u16, Vec<Value>)> = dp
            .records()
            .filter(|r| r.is_primary_record())
            .filter_map(|r| {
                crate::data::assembled_image(file, page_size, &r)
                    .map(|img| (r.slot, decode_record(&img, &descs)))
            })
            .collect();
        for (line, values) in rows {
            let recno = seq * recs + line as u64;
            let v = eval(&values)?;
            let key_segs = [btw::KeySeg { itype: key_itype, value: &v, scale: 0, charset: 0 }];
            let (key, all_null) = btw::build_index_key(&key_segs, descending)
                .ok_or("unsupported value for an expression index key")?;
            btw::insert_index_entry(
                file,
                page_size,
                rel,
                slot as u8,
                &key,
                recno,
                unique && !all_null,
                descending,
            )?;
            total += 1;
            if !distinct.contains(&key) {
                distinct.push(key);
            }
        }
    }
    let sel = if total == 0 { 0.0 } else { 1.0 / distinct.len().max(1) as f32 };
    write_index_statistics(file, page_size, rel, slot, index_name, &[sel], false)
}

/// Take the first free index-root slot for a new index of `rel`: the
/// first repeat with no root page, its segment descriptors carved from
/// the page tail below the lowest in use, an empty root bucket
/// allocated, the repeat written `irt_normal`. Returns the slot -
/// `RDB$INDEX_ID - 1`.
fn allocate_index_slot(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    segs: &[(u16, u16, i8)],
    iflags: u16,
) -> Result<usize, String> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    // find a free slot and the lowest descriptor offset, page-local on
    // the irt page; the borrow drops before allocate_page takes the file
    let (slot, lowest_desc) = {
        let page = crate::page_at(file, page_size, irt_page).ok_or("irt page out of range")?;
        let mut slot = None;
        let mut lowest_desc = page_size;
        for i in 0..((page_size - 24) / 24) {
            let at = 24 + i * 24;
            let root = u32_at(page, at + 8);
            if root == 0 {
                if slot.is_none() {
                    slot = Some(i);
                    break;
                }
            } else {
                lowest_desc = lowest_desc.min(u16_at(page, at + 16) as usize);
            }
        }
        (slot.ok_or("no free index slot")?, lowest_desc)
    };
    let desc_off = lowest_desc
        .checked_sub(8 * segs.len())
        .ok_or("irt page full")?;
    if 24 + (slot + 1) * 24 > desc_off {
        return Err("irt page full".into());
    }

    if file.ddl_tx.is_some() {
        // the slot and every bucket of the tree are the rollback's residue
        file.ddl_residue.push(crate::DdlResidue::IndexTree { irt_page, rel, slot });
    }
    let root_page = dml::allocate_page(file, page_size)?;
    crate::page_mut(file, page_size, root_page)
        .expect("index root page out of range")
        .fill(0);
    btw::write_empty_root(file, page_size, root_page, rel, slot as u8)?;

    // the index-root entry, its segment descriptors and the count are all
    // on the irt page
    let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
    let at = 24 + slot * 24;
    page[at..at + 8].copy_from_slice(&0u64.to_le_bytes()); // irt_transaction
    dml::put_u32(page, at + 8, root_page);
    dml::put_u32(page, at + 12, 0); // page space
    dml::put_u16(page, at + 16, desc_off as u16);
    dml::put_u16(page, at + 18, iflags);
    page[at + 20] = 3; // irt_normal
    page[at + 21] = segs.len() as u8;
    page[at + 22] = 0;
    page[at + 23] = 0;
    for (i, (field, itype, _)) in segs.iter().enumerate() {
        let d = desc_off + i * 8;
        dml::put_u16(page, d, *field);
        dml::put_u16(page, d + 2, *itype);
        dml::put_u32(page, d + 4, 0); // selectivity, computed after the build
    }
    let count = u16_at(page, 18); // irt_count @18
    if (slot as u16) + 1 > count {
        dml::put_u16(page, 18, slot as u16 + 1);
    }
    Ok(slot)
}

/// Key every committed primary row of `rel` into the tree at `slot` -
/// what an index build (CREATE INDEX, ALTER INDEX ACTIVE, a key
/// constraint over existing rows) does. A duplicate under a unique or
/// primary index fails the whole statement, as the engine's build does.
///
/// THROUGH THE SORT: the keys are built for every row first, sorted in
/// the index's own order (the complemented DESCENDING keys by their own
/// rule, ties by record number), and the tree is built WHOLE from that
/// order by [btw::build_index_bulk] - the engine's `fast_load`. Inserting
/// in record order had each key decode and re-encode its leaf, split
/// pages mid-way, and (descending) descend the wrong child.
#[allow(clippy::too_many_arguments)]
fn backfill_index(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    slot: usize,
    segs: &[(u16, u16, i8)],
    descs: &[Descriptor],
    unique: bool,
    descending: bool,
    primary: bool,
) -> Result<(), String> {
    backfill_index_inner(file, page_size, rel, slot, segs, descs, unique, descending, primary)
}

#[allow(clippy::too_many_arguments)]
fn backfill_index_inner(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    slot: usize,
    segs: &[(u16, u16, i8)],
    descs: &[Descriptor],
    unique: bool,
    descending: bool,
    primary: bool,
) -> Result<(), String> {
    let recs = max_recs_per_dp(page_size);
    // (key, recno) for every row, then sorted in the tree's order
    let mut keyed: Vec<(Vec<u8>, u64, bool)> = Vec::new();
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        let seq = dp.sequence as u64;
        let rows: Vec<(u16, Vec<Value>)> = dp
            .records()
            .filter(|r| r.is_primary_record())
            .filter_map(|r| {
                // ASSEMBLED, not `image()`. A fragmented row skipped here is
                // a row MISSING FROM THE INDEX THIS WRITES - and that index is
                // then read by the REAL engine, which returns nothing for a key
                // whose row plainly exists. Durable wrong state, not a bad plan.
                crate::data::assembled_image(file, page_size, &r)
                    .map(|img| (r.slot, decode_record(&img, descs)))
            })
            .collect();
        for (line, values) in rows {
            let recno = seq * recs + line as u64;
            let null = Value::Null;
            let key_segs: Vec<btw::KeySeg<'_>> = segs
                .iter()
                .map(|(field, itype, scale)| btw::KeySeg {
                    itype: *itype,
                    value: values.get(*field as usize).unwrap_or(&null),
                    scale: *scale,
                    charset: descs
                        .get(*field as usize)
                        .map_or(0, |d| crate::intl::charset_id(d.sub_type)),
                })
                .collect();
            let (key, all_null) = btw::build_index_key(&key_segs, descending)
                .ok_or("unsupported value for an index key")?;
            keyed.push((key, recno, all_null));
        }
    }
    keyed.sort_by(|a, b| {
        let k = if descending { btw::key_cmp_desc(&a.0, &b.0) } else { a.0.cmp(&b.0) };
        k.then(a.1.cmp(&b.1))
    });
    btw::build_index_bulk(file, page_size, rel, slot as u8, &keyed, unique, primary)
}

/// Walk a system relation like [walk_rows], also yielding each row's
/// (data page, slot) - what [crate::dml::delete_records] targets.
fn walk_rows_at(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    descs: &[Descriptor],
    mut cb: impl FnMut(u32, u16, &[Value]),
) {
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            cb(dp_no, r.slot, &decode_record(&image, descs));
        }
    }
}

/// Delete every row of a catalog relation the predicate accepts -
/// normal MVCC deletion (a stub over a version chain, the engine's
/// sweep collects both), which is also what keeps the catalog INDEX
/// entries valid: they point at deleted stubs, exactly as after an
/// engine-side DELETE.
fn delete_catalog_rows(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    pred: impl Fn(&[Value]) -> bool,
) -> Result<usize, String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)
        .ok_or_else(|| format!("no {} relation", rel_name))?;
    let formats = system_relation_formats(file, page_size, rel_name)
        .ok_or("no computed system format")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let mut targets: Vec<(u32, u16)> = Vec::new();
    walk_rows_at(file, page_size, rel, descs, |page, slot, values| {
        if pred(values) {
            targets.push((page, slot));
        }
    });
    if targets.is_empty() {
        return Ok(0);
    }
    let out = dml::delete_records(file, page_size, rel, &targets)?;
    Ok(out.affected)
}

/// The field id of a named column in a system relation's computed
/// format.
fn sys_fid(file: &crate::Image, page_size: usize, rel_name: &str, col: &str) -> Result<usize, String> {
    relation_columns(file, page_size, rel_name)
        .iter()
        .find(|c| c.name == col)
        .map(|c| c.field_id as usize)
        .ok_or_else(|| format!("no {} column in {}", col, rel_name))
}

fn text_eq(v: Option<&Value>, want: &str) -> bool {
    matches!(v, Some(Value::Text(t)) if t.trim_end().eq_ignore_ascii_case(want))
}

/// [text_eq] EXACT - for a relation, column or index name, which arrives
/// canonical (the catalog's own spelling: `"tq"` beside TQ are two rows)
fn text_is(v: Option<&Value>, want: &str) -> bool {
    matches!(v, Some(Value::Text(t)) if t.trim_end() == want)
}
fn int_eq(v: Option<&Value>, want: i64) -> bool {
    matches!(v, Some(Value::Int(i)) if *i == want)
}

/// DROP TABLE: the engine's `DPM_delete_relation` sequence against the
/// file image. Catalog rows in eight relations become normal deleted
/// stubs (the engine's own DROP does the same; its sweep collects the
/// chains AND the blobs their back versions still reference); the
/// RDB$PAGES rows are WIPED - they are system-transaction records with
/// no version chains, and the post-drop engine state has them
/// physically gone; every page the relation owned (data, pointer,
/// index root, every B-tree bucket, level-1 blob pages) is released
/// back to the PIP.
pub fn drop_table(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let name = name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &name)
        .ok_or_else(|| format!("table {} not found", name))?;
    if rel < 128 {
        return Err("system relations cannot be dropped".into());
    }
    // FK/PK takes precedence and fires immediately, with its own vector: a
    // FOREIGN KEY on another table that references this table's PRIMARY KEY
    // or UNIQUE constraint blocks the drop before any dependency count.
    if table_pk_referenced_by_fk(file, page_size, &name) {
        return Err(format!(
            "Cannot delete PRIMARY KEY being used in FOREIGN KEY definition. DROP TABLE {}",
            name
        ));
    }
    // Then the dependency count. The engine's N is DISTINCT dependent VIEWS
    // whenever any view exists (procedures/triggers that also reference the
    // table are recompiled, not counted); with no view, DISTINCT dependent
    // PROCEDURES. RDB$VIEW_RELATIONS holds one row per view context (fc
    // writes it for its own views, so this is db-agnostic); the procedure
    // count reads RDB$DEPENDENCIES, which the engine populates. A trigger on
    // ANOTHER table that is the SOLE dependent is a recorded boundary - this
    // server drops there, where the engine refuses.
    let mut views: Vec<String> = Vec::new();
    if let Some(vrel) = crate::resolve_relation(file, page_size, "RDB$VIEW_RELATIONS") {
        let vfmts = system_relation_formats(file, page_size, "RDB$VIEW_RELATIONS")
            .ok_or("no RDB$VIEW_RELATIONS format")?;
        let (_, vdescs) = vfmts.iter().max_by_key(|(n, _)| *n).ok_or("no view-relations format")?;
        let vname_f = sys_fid(file, page_size, "RDB$VIEW_RELATIONS", "RDB$VIEW_NAME")?;
        let vreln_f = sys_fid(file, page_size, "RDB$VIEW_RELATIONS", "RDB$RELATION_NAME")?;
        walk_rows(file, page_size, vrel, vdescs, |v| {
            if text_is(v.get(vreln_f), &name) {
                if let Some(Value::Text(t)) = v.get(vname_f) {
                    let vn = t.trim_end().to_string();
                    if !views.iter().any(|x| *x == vn) {
                        views.push(vn);
                    }
                }
            }
        });
    }
    let n = if !views.is_empty() {
        views.len()
    } else {
        procedure_dependents(file, page_size, &name).len()
    };
    if n > 0 {
        return Err(format!("cannot delete TABLE {} - there are {} dependencies", name, n));
    }

    // gather what the catalog says belongs to this table BEFORE
    // stubbing it: index names, constraint names, auto-domain names
    let mut index_names: Vec<String> = Vec::new();
    {
        let irel = crate::resolve_relation(file, page_size, "RDB$INDICES")
            .ok_or("no RDB$INDICES")?;
        let formats = system_relation_formats(file, page_size, "RDB$INDICES")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let name_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
        let rel_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$RELATION_NAME")?;
        walk_rows(file, page_size, irel, descs, |values| {
            if text_is(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(name_fid) {
                    index_names.push(t.trim_end().to_string());
                }
            }
        });
    }
    let mut constraint_names: Vec<String> = Vec::new();
    {
        let crel = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")
            .ok_or("no RDB$RELATION_CONSTRAINTS")?;
        let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let name_fid = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$RELATION_NAME")?;
        walk_rows(file, page_size, crel, descs, |values| {
            if text_is(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(name_fid) {
                    constraint_names.push(t.trim_end().to_string());
                }
            }
        });
    }
    // A DROPPED TABLE TAKES ITS CONSTRAINTS' TRIGGERS AND PARTNER ROWS
    // WITH IT. `ALTER TABLE ... DROP CONSTRAINT` learned this in the
    // round before; DROP TABLE did not, and left behind the FK's
    // `RDB$REF_CONSTRAINTS` row, the referential-action triggers (which
    // sit on the PARENT, not on the table being dropped), the CHECK
    // constraint's own trigger pair, and every one of their
    // `RDB$DEPENDENCIES` rows. `gfix -v -full` still returned 0 and
    // `gbak -b` still returned 0 - the RESTORE is where it died, with
    // "Name of Referential Constraint not defined in constraints
    // table". Worse, the orphan action trigger RE-ATTACHED BY NAME to a
    // table of the same name created afterwards. Measured: the engine
    // leaves NOTHING of any of it.
    //
    // A NOT NULL constraint's `RDB$CHECK_CONSTRAINTS` row holds its
    // COLUMN name where a CHECK or FK row holds a TRIGGER name (see
    // [check_constraint_column]), so only names that really are
    // triggers are followed - otherwise a column called `ID` would take
    // every `RDB$DEPENDENCIES` row of that name with it.
    {
        let mut trigger_names: Vec<String> = Vec::new();
        let mut trigger_relations: Vec<String> = Vec::new();
        for c in &constraint_names {
            for t in check_constraint_trigger_names(file, page_size, c) {
                let Some(on) = trigger_relation_name(file, page_size, &t) else { continue };
                if !trigger_names.iter().any(|x| *x == t) {
                    trigger_names.push(t);
                }
                if on != name && !trigger_relations.iter().any(|x| *x == on) {
                    trigger_relations.push(on);
                }
            }
        }
        let rc_fid = sys_fid(file, page_size, "RDB$REF_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
        let cs = constraint_names.clone();
        delete_catalog_rows(file, page_size, "RDB$REF_CONSTRAINTS", move |v| {
            cs.iter().any(|c| text_is(v.get(rc_fid), c))
        })?;
        let tn_fid = sys_fid(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME")?;
        let dn_fid = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_NAME")?;
        for t in &trigger_names {
            let t = t.clone();
            delete_catalog_rows(file, page_size, "RDB$TRIGGERS", {
                let t = t.clone();
                move |v| text_is(v.get(tn_fid), &t)
            })?;
            delete_catalog_rows(file, page_size, "RDB$DEPENDENCIES", move |v| {
                text_is(v.get(dn_fid), &t)
            })?;
        }
        // the PARENT's runtime, so its action triggers stop loading -
        // the dropped table's own runtime dies with it
        for parent in &trigger_relations {
            if crate::resolve_relation(file, page_size, parent).is_some() {
                refresh_runtime(file, page_size, parent)?;
            }
        }
    }

    let mut domain_names: Vec<String> = Vec::new();
    {
        let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let src_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_SOURCE")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
        walk_rows(file, page_size, 5, descs, |values| {
            if text_is(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(src_fid) {
                    let t = t.trim_end();
                    // only auto-domains die with the table
                    if t.strip_prefix("RDB$").is_some_and(|x| x.parse::<u64>().is_ok()) {
                        domain_names.push(t.to_string());
                    }
                }
            }
        });
    }

    // the relation's OWN security class, which dies with it. Its
    // RDB$DEFAULT_CLASS does NOT: the engine leaves the SQL$DEFAULT<n>
    // row behind (probe: after DROP TABLE only the SQL$<n> row is gone),
    // and so does this.
    let security_class = {
        let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let cls_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$SECURITY_CLASS")?;
        let rel_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
        let mut class = None;
        walk_rows(file, page_size, 6, descs, |values| {
            if text_is(values.get(rel_fid), &name) {
                if let Some(Value::Text(t)) = values.get(cls_fid) {
                    class = Some(t.trim_end().to_string());
                }
            }
        });
        class
    };

    // catalog rows -> deleted stubs (version chains the engine sweeps)
    let idx_pred = |names: Vec<String>, fid: usize| {
        move |values: &[Value]| {
            names.iter().any(|n| text_is(values.get(fid), n))
        }
    };
    {
        let fid = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$INDEX_SEGMENTS",
            idx_pred(index_names.clone(), fid))?;
    }
    let name2 = name.clone();
    {
        let fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$INDICES",
            move |values| text_is(values.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$CHECK_CONSTRAINTS", "RDB$CONSTRAINT_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$CHECK_CONSTRAINTS",
            idx_pred(constraint_names.clone(), fid))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$RELATION_CONSTRAINTS", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATION_CONSTRAINTS",
            move |values| text_is(values.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATION_FIELDS",
            move |values| text_is(values.get(fid), &n))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$FIELDS",
            idx_pred(domain_names.clone(), fid))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$FORMATS", "RDB$RELATION_ID")?;
        delete_catalog_rows(file, page_size, "RDB$FORMATS",
            move |values| int_eq(values.get(fid), rel as i64))?;
    }
    {
        let fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$RELATIONS",
            move |values| text_is(values.get(fid), &n))?;
    }
    // the security catalog: the relation's class row and every privilege
    // granted ON the relation (object type 0 - a sequence of the same
    // name keeps its own)
    if let Some(class) = security_class {
        let fid = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES",
            move |values| text_eq(values.get(fid), &class))?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        let n = name2.clone();
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES",
            move |values| text_is(values.get(rel_f), &n) && int_eq(values.get(obj_f), 0))?;
    }

    // the storage: released NOW for a settled drop, at COMMIT under a
    // transaction (dfw.epp delete_relation) - a rolled-back DROP keeps
    // its pages, and only the deleted stubs above die with the id
    if file.ddl_tx.is_some() {
        file.ddl_deferred.push(crate::DdlDeferred::DropRelation { rel });
    } else {
        release_relation_storage(file, page_size, rel)?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}


/// Release everything relation `rel` owns on disk: its `RDB$PAGES` rows
/// wiped (system-transaction records with no chains - the slots are
/// blanked, the post-sweep engine state; rel 0 has no indexes, so no
/// entries dangle) and every page it owns - data pages and the page
/// vectors of their level-1 blobs, pointer pages, index roots and
/// B-tree buckets, found by catalog-free page-type scans - given back
/// to the PIP. The settled half of DROP TABLE, and a DDL transaction's
/// deferred work at COMMIT.
pub(crate) fn release_relation_storage(file: &mut crate::Image, page_size: usize, rel: u16) -> Result<(), String> {
    // pages the relation owns - catalog-free page-type scans, plus the
    // page vectors of any level-1 blob slots on its data pages
    let mut pages: Vec<u32> = Vec::new();
    let data_pages = relation_data_pages(file, page_size, rel);
    for &dp_no in &data_pages {
        if let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) {
            for i in 0..dp.count {
                let Some(b) = dp.slot_bytes(i) else { continue };
                if b.len() >= 28 && u16_at(b, 10) & crate::data::flags::BLOB != 0 && b[27] == 1 {
                    let mut at = 28;
                    while at + 4 <= b.len() {
                        let pg = u32_at(b, at);
                        if pg == 0 {
                            break;
                        }
                        pages.push(pg);
                        at += 4;
                    }
                }
            }
        }
        pages.push(dp_no);
    }
    for (i, p) in file.pages().enumerate() {
        let owned = match p[0] {
            4 => u16_at(p, 26) == rel,  // pointer: ppg_relation
            6 => u16_at(p, 16) == rel,  // index root: irt_relation
            7 => u16_at(p, 28) == rel,  // B-tree bucket: btr_relation @28
            _ => false,
        };
        if owned {
            pages.push(i as u32);
        }
    }

    // RDB$PAGES rows: system-transaction records with no chains - wipe
    // the slots (the post-sweep engine state); rel 0 has no indexes,
    // so no entries dangle
    {
        let formats = system_relation_formats(file, page_size, "RDB$PAGES")
            .ok_or("no computed system format")?;
        let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
        let fid = sys_fid(file, page_size, "RDB$PAGES", "RDB$RELATION_ID")?;
        let mut targets: Vec<(u32, u16)> = Vec::new();
        walk_rows_at(file, page_size, 0, descs, |page, slot, values| {
            if int_eq(values.get(fid), rel as i64) {
                targets.push((page, slot));
            }
        });
        for (page, slot) in targets {
            let p = crate::page_mut(file, page_size, page).expect("RDB$PAGES page out of range");
            let dir = DPG_RPT_OFFSET + slot as usize * 4;
            dml::put_u16(p, dir, 0);
            dml::put_u16(p, dir + 2, 0);
        }
    }

    // release every owned page back to the PIP
    pages.sort_unstable();
    pages.dedup();
    for p in pages {
        dml::release_page(file, page_size, p)?;
    }
    Ok(())
}

/// The transaction that holds an UNCOMMITTED version of relation `name`'s
/// `RDB$RELATIONS` row - the head version's id when its state is ACTIVE
/// (an ALTER's new version, a DROP's deleted stub, a CREATE's first
/// version) - or None when the row's head is settled. The engine's
/// first-updater-wins check reads the same fact off its metadata
/// cache's version list (CacheVector.h isAvailable: OCCUPIED by a
/// transaction that is still active); measured: the second ALTER or
/// DROP fails at once, no wait, even under WAIT. Read WIDE: every
/// active transaction's version is exactly what is looked for.
pub fn relation_head_owner(file: &crate::Image, page_size: usize, name: &str) -> Option<(u64, u16)> {
    let want = name.trim().to_string();
    let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let name_fid = fid("RDB$RELATION_NAME")?;
    let id_fid = fid("RDB$RELATION_ID")?;
    let tips = crate::tra::TipChain::read(file, page_size)?;
    for dp_no in relation_data_pages(file, page_size, 6) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            if r.flags & (crate::data::flags::CHAIN | crate::data::flags::FRAGMENT | crate::data::flags::BLOB) != 0 {
                continue;
            }
            if r.transaction == 0 || tips.state(r.transaction) != Some(crate::tip::TxState::Active) {
                continue;
            }
            // the name: off the head, or - for a DROP's stub - off the
            // committed version behind it (the committed-only walk steps
            // past an active head)
            let image = if r.flags & crate::data::flags::DELETED == 0 {
                crate::data::assembled_image(file, page_size, &r)
            } else {
                crate::tra::visible_version(file, page_size, &r, &tips, &crate::tra::OwnTx::none())
                    .map(|v| v.image)
            };
            let Some(image) = image else { continue };
            let values = decode_record(&image, descs);
            if text_is(values.get(name_fid), &want) {
                let rel = match values.get(id_fid) {
                    Some(Value::Int(i)) => *i as u16,
                    _ => 0,
                };
                return Some((r.transaction, rel));
            }
        }
    }
    None
}

/// Rewrite named columns of ONE system-relation row in place, at its
/// current format. The row keeps its position (so its record number,
/// and every index entry pointing at it, stay valid) - which is only
/// safe for columns no index of the relation keys; a keyed column needs
/// [maintain_indexes] afterwards, as the deferred index drop does.
/// A blob-typed field's CURRENT id off a row image - the read half of
/// superseded-catalog-blob GC, taken BEFORE the field is overwritten.
/// None when the field is NULL, not blob-typed, or holds the zero id.
fn old_blob_at(image: &[u8], descs: &[Descriptor], fid: usize) -> Option<(u16, u64)> {
    use crate::format::dtype;
    let d = descs.get(fid)?;
    if d.dtype != dtype::BLOB && d.dtype != dtype::QUAD {
        return None;
    }
    if d.offset == 0 || image.get(fid / 8).map(|b| b & (1 << (fid % 8)) != 0).unwrap_or(true) {
        return None;
    }
    let at = d.offset as usize;
    let f = image.get(at..at + 8)?;
    let orel = u16_at(f, 0);
    let onum = ((f[3] as u64) << 32) | u32_at(f, 4) as u64;
    // the empty bid is ALL zero (blb.h isEmpty); recno 0 alone is slot
    // 0 of sequence 0, a legitimate blob
    if orel == 0 && onum == 0 {
        return None;
    }
    Some((orel, onum))
}

/// Every blob id a row image still references - the "staying" half of
/// the engine's BLB_garbage_collect diff (blb.cpp:424: identity is the
/// id, not the field - a blob that moved fields is NOT superseded).
fn image_blob_ids(image: &[u8], descs: &[Descriptor]) -> Vec<(u16, u64)> {
    (0..descs.len()).filter_map(|fid| old_blob_at(image, descs, fid)).collect()
}

/// Dispose of a catalog blob a patch superseded: under a DDL
/// transaction the free waits for COMMIT (a rollback must find the old
/// row version's blob still there); the settled path (tools, restore)
/// frees on the spot - the same two-arm shape as drop_table's storage
/// (ddl.rs release_relation_storage branch).
fn dispose_superseded_blob(file: &mut crate::Image, page_size: usize, rel: u16, recno: u64) {
    if file.ddl_tx.is_some() {
        file.ddl_deferred.push(crate::DdlDeferred::FreeBlob { rel, recno });
    } else {
        crate::gc::free_blob(file, page_size, rel, recno);
    }
}

/// The other half of every free: no on-disk version may keep naming a
/// freed blob (see [crate::DdlDeferred::PurgeRowChain]). Rides with
/// [dispose_superseded_blob] on the patched row itself.
fn dispose_row_purge(file: &mut crate::Image, page_size: usize, rel: u16, page: u32, slot: u16) {
    if file.ddl_tx.is_some() {
        file.ddl_deferred.push(crate::DdlDeferred::PurgeRowChain { rel, page, slot });
    } else {
        crate::gc::purge_row_chain(file, page_size, page, slot);
    }
}

/// THE CONVERSION OF `dfw_create_relation`: give a relation that exists
/// only as a CATALOG ROW the storage that makes it a table.
///
/// A client storing straight into `RDB$RELATIONS` - which is what gbak's
/// restore does - writes a row and nothing else. The engine posts
/// deferred work for it and runs that work AT COMMIT, and the timing is
/// not incidental: the relation's column rows arrive AFTER its own, so
/// the format cannot be computed when the row is stored. Only at commit
/// is the catalog complete enough to describe the table it names.
///
/// So this reads the catalog as it then stands and produces exactly what
/// [create_table] produces in one go for a parsed `CREATE TABLE`: a
/// pointer page and an index root page with their headers, the format
/// descriptor blob and its `RDB$FORMATS` row, and the two `RDB$PAGES`
/// rows that say where the storage is.
///
/// Idempotent: a relation that already has an index root has already
/// been through here (or was made by [create_table]), and is left alone.
pub fn create_relation_storage(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
) -> Result<(), String> {
    // READ THE CATALOG WIDE. This runs at commit but BEFORE the TIP
    // flip - the engine's own ordering (tra.cpp:488 `DFW_perform_work`
    // ahead of the flip at 547) - so the rows this work exists to read
    // are still uncommitted. A visibility-filtered walk cannot see the
    // relation it is about to give storage to, nor its columns, and the
    // task would build a table out of nothing.
    let _wide = crate::tra::ReaderViewGuard::wide();
    // THE ID IS NOT IN THE ROW THE CLIENT STORED. gbak leaves
    // `RDB$RELATION_ID` and `RDB$FORMAT` NULL and the ENGINE assigns
    // both - which is the other half of why this cannot happen at store
    // time, and why the work is named rather than numbered.
    let rels = crate::catalog::list_relations(file, page_size);
    // A NULL id READS AS ZERO. `relation_row` takes the id from a fixed
    // offset without consulting the null bitmap, so the row this work
    // exists to finish - whose id has not been assigned yet - comes back
    // as relation 0. Relation 0 is RDB$PAGES, which HAS an index root,
    // so treating that as "already has storage" made this task a no-op
    // every single time, silently: the catalog rows landed, the storage
    // never did, and the engine reading the file said the table was
    // unknown. No user relation is 0.
    let existing = rels.iter().find(|(id, n)| n == name && *id != 0).map(|(id, _)| *id);
    let rel = match existing {
        Some(id) => id,
        None => {
            let id = next_relation_id(file, page_size, &rels)?;
            let want = name.to_string();
            let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
            patch_sys_row(
                file,
                page_size,
                "RDB$RELATIONS",
                6,
                move |v| {
                    matches!(v.get(name_fid), Some(Value::Text(t)) if t.trim_end() == want)
                },
                &[("RDB$RELATION_ID", SysVal::I(id as i64))],
            )?;
            id
        }
    };
    if crate::btr::find_index_root(file, page_size, rel).is_some() {
        return Ok(());
    }
    // A VIEW GETS A FORMAT AND NOTHING TO STORE IT IN. The engine's own
    // restore leaves a view with one RDB$FORMATS row and no RDB$PAGES
    // (measured on the employee sample's PHONE_LIST: fmts 1, pgs 0), and
    // a DBKEY_LENGTH of 8 per context - what [restore_view_with] writes
    // for fire-crab's own CREATE VIEW. Laying a view out as a table gave
    // it a pointer page and a root page it would never use.
    if is_view(file, page_size, name) {
        return create_view_storage(file, page_size, name, rel);
    }
    let fields = catalog_field_list(file, page_size, name)?;
    if fields.is_empty() {
        return Err(format!("relation {name} has no columns to lay out"));
    }
    let descs = compute_format_mixed(&fields);

    // --- pages, exactly as DPM_create_relation lays them out ---------
    let pointer_page = dml::allocate_page(file, page_size)?;
    let root_page = dml::allocate_page(file, page_size)?;
    {
        let page = crate::page_mut(file, page_size, pointer_page).ok_or("pointer page range")?;
        page.fill(0);
        page[0] = 4; // pag_pointer
        page[1] = 1; // pag_flags = ppg_eof
        dml::put_u32(page, 12, pointer_page);
        dml::put_u16(page, 26, rel);
    }
    {
        let page = crate::page_mut(file, page_size, root_page).ok_or("root page range")?;
        page.fill(0);
        page[0] = 6; // pag_root
        dml::put_u32(page, 12, root_page);
        dml::put_u16(page, 16, rel);
        dml::put_u16(page, 18, 0); // irt_count
    }

    // --- the format, and the row that names it -----------------------
    let fmt_blob = write_format_blob(file, page_size, &descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            // FORMAT 1, not 0 - what [create_table] writes for a new
            // table and what the engine's own restore leaves behind
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;
    for (page, ptype) in [(pointer_page, 4i64), (root_page, 6i64)] {
        sys_insert(
            file,
            page_size,
            "RDB$PAGES",
            0,
            &[
                ("RDB$RELATION_ID", SysVal::I(rel as i64)),
                ("RDB$PAGE_NUMBER", SysVal::I(page as i64)),
                ("RDB$PAGE_SEQUENCE", SysVal::I(0)),
                ("RDB$PAGE_TYPE", SysVal::I(ptype)),
            ],
        )?;
    }
    // THE RUNTIME SUMMARY. Without it the engine's metadata scan has no
    // description of the relation to cache, and a table whose catalog
    // rows are all present is still answered `-204 Table unknown` -
    // which is exactly what it answered until this was written.
    let runtime = rebuild_runtime_blob(file, page_size, name, &descs)?;

    // ...and the relation names the format it now has, and how many
    // fields it turned out to have. The client leaves these for the
    // server, the way it leaves the id.
    let want = name.to_string();
    let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATIONS",
        6,
        move |v| matches!(v.get(name_fid), Some(Value::Text(t)) if t.trim_end() == want),
        &[
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$FIELD_ID", SysVal::I(descs.len() as i64)),
            // gbak never sends RDB$DBKEY_LENGTH for a table and the
            // engine's restored row reads 0 (measured on every employee
            // table; met.epp:3243 reads 0 as 8). DDL's 8 is
            // CreateRelationNode's, not dfw_create_relation's.
            ("RDB$DBKEY_LENGTH", SysVal::I(0)),
            ("RDB$RUNTIME", SysVal::B(blob_id_bytes(6, runtime))),
        ],
    )?;
    Ok(())
}

/// The commit-time half of a VIEW that arrived as catalog rows: its
/// format (each column's descriptor from the domain its
/// `RDB$FIELD_SOURCE` names, laid out the way [restore_view_with] does),
/// `RDB$FORMAT` = 1, the field count, and a dbkey length of 8 per
/// `RDB$VIEW_RELATIONS` context - the rows gbak stores right after the
/// view's columns and before it commits. Idempotent through
/// `RDB$FORMAT`: a view that already names its format has been here.
fn create_view_storage(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    rel: u16,
) -> Result<(), String> {
    let has_format = relation_columns(file, page_size, "RDB$RELATIONS")
        .iter()
        .find(|c| c.name == "RDB$FORMAT")
        .map(|c| c.field_id as usize)
        .and_then(|fid| {
            let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")?;
            let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
            let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME").ok()?;
            let mut found = None;
            walk_rows(file, page_size, 6, descs, |vals| {
                if matches!(vals.get(name_fid), Some(Value::Text(t)) if t.trim_end() == name) {
                    found = Some(matches!(vals.get(fid), Some(Value::Int(_))));
                }
            });
            found
        })
        .unwrap_or(false);
    if has_format {
        return Ok(());
    }
    let fields = catalog_field_list(file, page_size, name)?;
    if fields.is_empty() {
        return Err(format!("view {name} has no columns to describe"));
    }
    let descs = compute_format_mixed(&fields);
    let fmt_blob = write_format_blob(file, page_size, &descs)?;
    sys_insert(
        file,
        page_size,
        "RDB$FORMATS",
        8,
        &[
            ("RDB$RELATION_ID", SysVal::I(rel as i64)),
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$DESCRIPTOR", SysVal::B(blob_id_bytes(8, fmt_blob))),
        ],
    )?;
    // RDB$DBKEY_LENGTH is the client's (gbak's "adjusting views dbkey
    // length" pass MODIFIES it itself; the engine's restore ends with
    // 0 on the employee view - measured)
    let want = name.to_string();
    let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATIONS",
        6,
        move |v| matches!(v.get(name_fid), Some(Value::Text(t)) if t.trim_end() == want),
        &[
            ("RDB$FORMAT", SysVal::I(1)),
            ("RDB$FIELD_ID", SysVal::I(descs.len() as i64)),
        ],
    )?;
    Ok(())
}

/// A relation's columns AS THE CATALOG HOLDS THEM, in field-id order and
/// in the shape [compute_format_mixed] takes.
///
/// [create_table] builds this from a parsed `CREATE TABLE`; a relation
/// that arrived as catalog rows has no such parse to read, so the same
/// facts are joined back out of `RDB$RELATION_FIELDS` and the
/// `RDB$FIELDS` rows its `RDB$FIELD_SOURCE` names.
fn catalog_field_list(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Result<Vec<(u8, u16, i8, i16, bool)>, String> {
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty rf format")?;
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(rf_rel), Some(rf_src), Some(rf_id)) =
        (rf_fid("RDB$RELATION_NAME"), rf_fid("RDB$FIELD_SOURCE"), rf_fid("RDB$FIELD_ID"))
    else {
        return Err("RDB$RELATION_FIELDS is missing a column this needs".into());
    };
    let mut members: Vec<(usize, String)> = Vec::new();
    walk_rows(file, page_size, 5, rf_descs, |vals| {
        if text(vals.get(rf_rel)).as_deref() != Some(table) {
            return;
        }
        let (Some(Value::Int(id)), Some(src)) = (vals.get(rf_id), text(vals.get(rf_src))) else {
            return;
        };
        members.push((*id as usize, src));
    });
    if members.is_empty() {
        return Ok(Vec::new());
    }
    if std::env::var_os("FC_DDL_TRACE").is_some() {
        eprintln!("[ddl] catalog_field_list {table}: members {members:?}");
    }

    let f_formats =
        system_relation_formats(file, page_size, "RDB$FIELDS").ok_or("no RDB$FIELDS format")?;
    let (_, f_descs) = f_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty fields format")?;
    let fcols = relation_columns(file, page_size, "RDB$FIELDS");
    let ffid = |n: &str| fcols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(fn_f), Some(ft_f), Some(fl_f)) =
        (ffid("RDB$FIELD_NAME"), ffid("RDB$FIELD_TYPE"), ffid("RDB$FIELD_LENGTH"))
    else {
        return Err("RDB$FIELDS is missing a column this needs".into());
    };
    let fs_f = ffid("RDB$FIELD_SCALE");
    let fsub_f = ffid("RDB$FIELD_SUB_TYPE");
    let fcomp_f = ffid("RDB$COMPUTED_BLR");
    let fdims_f = ffid("RDB$DIMENSIONS");
    let fcs_f = ffid("RDB$CHARACTER_SET_ID");
    let mut sources: Vec<(String, (u8, u16, i8, i16, bool))> = Vec::new();
    walk_rows(file, page_size, 2, f_descs, |vals| {
        let Some(fname) = text(vals.get(fn_f)) else { return };
        if !members.iter().any(|(_, s)| *s == fname) {
            return;
        }
        let int_at = |i: Option<usize>| -> i64 {
            match i.and_then(|i| vals.get(i)) {
                Some(Value::Int(n)) => *n,
                _ => 0,
            }
        };
        // `RDB$FIELD_TYPE` IS THE BLR CODE, NOT THE dsc DTYPE. They are
        // different numbering schemes that overlap: blr 8 is a LONG and
        // dsc 8 is a SHORT, blr 37 is a VARYING and dsc 37 is nothing at
        // all. Passing the catalog's value straight into
        // [compute_format_mixed] laid the record out as SHORT + garbage,
        // and - because the VARYING arm never fired - without the two
        // bytes a varying's length prefix needs. The engine READ that
        // table (the catalog columns all agree) and could not WRITE to
        // it: `internal error` on any insert.
        let dt = match vals.get(ft_f) {
            Some(Value::Int(n)) => match field_type_to_dtype(*n as i16) {
                Some(d) => d,
                None => return,
            },
            _ => return,
        };
        let len = match vals.get(fl_f) {
            Some(Value::Int(n)) => *n as u16,
            _ => return,
        };
        let computed =
            matches!(fcomp_f.and_then(|i| vals.get(i)), Some(Value::Blob(..)));
        // the same tuple [col_field_of] builds for a parsed column: an
        // ARRAY (RDB$DIMENSIONS > 0) is stored as its 8-byte array id
        // whatever its element type; a BLOB is its 8-byte id, sub_type
        // carried and the CHARACTER SET where a scale would be. Both
        // used to fall out of the `field_type_to_dtype` match and be
        // reported as a missing RDB$FIELDS row - JOB's RDB$3 in the
        // employee sample.
        let tuple = if int_at(fdims_f) > 0 {
            (crate::format::dtype::ARRAY, 8, 0, 0, false)
        } else if dt == crate::format::dtype::BLOB {
            (dt, 8, int_at(fcs_f) as i8, int_at(fsub_f) as i16, computed)
        } else {
            (dt, len, int_at(fs_f) as i8, int_at(fsub_f) as i16, computed)
        };
        sources.push((fname, tuple));
    });

    let width = members.iter().map(|(id, _)| id + 1).max().unwrap_or(0);
    // a gap in the field ids keeps its slot, the way [laid_out_descs]
    // does: the walk is by OFFSET, so a missing descriptor would shift
    // every column after it
    let mut out = vec![(crate::format::dtype::SHORT, 2u16, 0i8, 0i16, false); width];
    for (id, src) in &members {
        let f = sources
            .iter()
            .find(|(n, _)| n == src)
            .map(|(_, f)| *f)
            .ok_or_else(|| format!("no RDB$FIELDS row for {src}"))?;
        out[*id] = f;
    }
    Ok(out)
}

/// BUILD AN INDEX THAT ARRIVED AS CATALOG ROWS.
///
/// The sibling of [create_relation_storage], and the same shape: a
/// client storing straight into `RDB$INDICES` writes a row, its SEGMENT
/// rows arrive after it, and the b-tree cannot be built until they have.
/// So the work is deferred to commit and reads the catalog as it then
/// stands.
///
/// It does what [create_index]'s structural half does - allocate the
/// index-root slot, stamp the `RDB$INDEX_ID` that names it, key every
/// existing row into the tree, and write the selectivity - but takes its
/// segments and its flags from the catalog instead of from a parsed
/// `CREATE INDEX`.
///
/// Idempotent: an index whose `RDB$INDEX_ID` is already set has been
/// through here (or was made by [create_index]).
pub fn create_index_storage(
    file: &mut crate::Image,
    page_size: usize,
    index_name: &str,
) -> Result<(), String> {
    // the catalog is read WIDE: this runs at commit but before the TIP
    // flip, so the rows it exists to read are still uncommitted
    let _wide = crate::tra::ReaderViewGuard::wide();

    let text = |v: Option<&Value>| match v {
        Some(Value::Text(t)) => Some(t.trim_end().to_string()),
        _ => None,
    };
    let int = |v: Option<&Value>| match v {
        Some(Value::Int(n)) => Some(*n),
        _ => None,
    };

    // --- the index's own row ------------------------------------------
    let i_formats =
        system_relation_formats(file, page_size, "RDB$INDICES").ok_or("no RDB$INDICES format")?;
    let (_, i_descs) = i_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let icols = relation_columns(file, page_size, "RDB$INDICES");
    let ifid = |n: &str| icols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(i_name), Some(i_rel)) = (ifid("RDB$INDEX_NAME"), ifid("RDB$RELATION_NAME")) else {
        return Err("RDB$INDICES is missing a column this needs".into());
    };
    let (i_id, i_uniq, i_type) =
        (ifid("RDB$INDEX_ID"), ifid("RDB$UNIQUE_FLAG"), ifid("RDB$INDEX_TYPE"));
    // BY NAME, NEVER BY A GUESSED ID. This module deliberately does not
    // hardcode the ids of the catalog relations outside the handful it
    // owns - `sys_row_by_name` exists for exactly that - and a walk over
    // the wrong relation finds nothing and reports the row missing.
    let i_rel_id = crate::resolve_relation(file, page_size, "RDB$INDICES")
        .ok_or("no RDB$INDICES relation")?;
    let mut found: Option<(String, bool, bool, bool)> = None;
    walk_rows(file, page_size, i_rel_id, i_descs, |vals| {
        if text(vals.get(i_name)).as_deref() != Some(index_name) {
            return;
        }
        let already = i_id.and_then(|f| int(vals.get(f))).is_some();
        found = Some((
            text(vals.get(i_rel)).unwrap_or_default(),
            i_uniq.and_then(|f| int(vals.get(f))).unwrap_or(0) != 0,
            i_type.and_then(|f| int(vals.get(f))).unwrap_or(0) != 0,
            already,
        ));
    });
    let Some((table, unique, descending, already)) = found else {
        return Err(format!("no RDB$INDICES row for {index_name}"));
    };
    if already {
        return Ok(());
    }
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("index {index_name} names unknown relation {table}"))?;

    // --- its segments, in key order -----------------------------------
    let s_formats = system_relation_formats(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS format")?;
    let (_, s_descs) = s_formats.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let scols = relation_columns(file, page_size, "RDB$INDEX_SEGMENTS");
    let sfid = |n: &str| scols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(s_idx), Some(s_fld), Some(s_pos)) =
        (sfid("RDB$INDEX_NAME"), sfid("RDB$FIELD_NAME"), sfid("RDB$FIELD_POSITION"))
    else {
        return Err("RDB$INDEX_SEGMENTS is missing a column this needs".into());
    };
    let s_rel_id = crate::resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS relation")?;
    let mut members: Vec<(i64, String)> = Vec::new();
    walk_rows(file, page_size, s_rel_id, s_descs, |vals| {
        if text(vals.get(s_idx)).as_deref() != Some(index_name) {
            return;
        }
        if let Some(f) = text(vals.get(s_fld)) {
            members.push((int(vals.get(s_pos)).unwrap_or(0), f));
        }
    });
    if members.is_empty() {
        return Err(format!("index {index_name} has no segments"));
    }
    members.sort_by_key(|(p, _)| *p);

    // --- is it a PRIMARY KEY? the index row does not say; the
    //     constraint row does, and this runs late enough to see it -----
    let primary = constraint_kind_of(file, page_size, index_name)
        .map(|k| k == "PRIMARY KEY")
        .unwrap_or(false);

    // --- the same segment resolution [create_index] does ---------------
    let columns = relation_columns(file, page_size, &table);
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("relation has no format")?;
    let mut segs: Vec<(u16, u16, i8)> = Vec::new();
    for (_, n) in &members {
        let rc = columns
            .iter()
            .find(|c| c.name == *n)
            .ok_or_else(|| format!("index {index_name} names unknown column {n}"))?;
        let d = descs.get(rc.field_id as usize).ok_or("field beyond format")?;
        let itype = index_itype(d).ok_or("column type cannot be indexed by this writer")?;
        segs.push((rc.field_id, itype, d.scale));
    }

    let mut iflags = 0u16;
    if unique {
        iflags |= btw::IRT_UNIQUE;
    }
    if descending {
        iflags |= btw::IRT_DESCENDING;
    }
    if primary {
        iflags |= btw::IRT_PRIMARY;
    }
    let slot = allocate_index_slot(file, page_size, rel, &segs, iflags)?;

    // the id NAMES the slot, and it is patched rather than inserted
    // because the row is already there - which is safe here and is not
    // for a relation id: RDB$INDEX_ID is not a key of any system index
    // (idx.h has RDB$INDICES keyed by name and by relation, not by id).
    let want = index_name.to_string();
    let name_fid = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$INDICES",
        i_rel_id,
        move |v| matches!(v.get(name_fid), Some(Value::Text(t)) if t.trim_end() == want),
        &[
            ("RDB$INDEX_ID", SysVal::I(slot as i64 + 1)),
            // ...AND THE DEFERRAL IS DISCHARGED. gbak stores EVERY index
            // with `RDB$INDEX_INACTIVE = 3` - `DEFERRED_ACTIVE`
            // (restore.epp:97, and the coercion at :6843 that turns an
            // active index into a deferred one) - and the ENGINE builds
            // it much later, when the restore's tail modifies that 3
            // back to 0 after the data is loaded
            // (`SystemTriggers::afterUpdateIndex`). Storing the row posts
            // the engine no work at all: `indexDfw` returns without
            // posting when RDB$INDEX_ID is null (vio.cpp).
            //
            // fire-crab builds HERE instead, at the store's commit, and
            // that is a recorded divergence rather than an oversight:
            // its DML keys every written row into whatever indexes the
            // relation's root already carries ([resolve_index_ops]), so
            // an index built empty before the load ends up with the same
            // entries the engine's end-of-restore build would have made.
            // What must not be left behind is the FLAG - a 3 says "not
            // built yet" about an index that is.
            ("RDB$INDEX_INACTIVE", SysVal::I(0)),
        ],
    )?;

    backfill_index(file, page_size, rel, slot, &segs, descs, unique, descending, primary)?;
    let sel = index_selectivity(file, page_size, rel, &segs, descending)?;
    write_index_statistics(file, page_size, rel, slot, index_name, &sel, true)
}

/// The constraint TYPE that names this index, if one does. A primary key
/// is not visible on the `RDB$INDICES` row at all - the engine records it
/// only in `RDB$RELATION_CONSTRAINTS` - so an index built without asking
/// would lose its `irt_primary` flag.
fn constraint_kind_of(file: &crate::Image, page_size: usize, index_name: &str) -> Option<String> {
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_CONSTRAINTS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (idx_f, typ_f) = (fid("RDB$INDEX_NAME")?, fid("RDB$CONSTRAINT_TYPE")?);
    let c_rel_id = crate::resolve_relation(file, page_size, "RDB$RELATION_CONSTRAINTS")?;
    let mut out = None;
    walk_rows(file, page_size, c_rel_id, descs, |vals| {
        let names_it = matches!(vals.get(idx_f), Some(Value::Text(t)) if t.trim_end() == index_name);
        if !names_it {
            return;
        }
        if let Some(Value::Text(t)) = vals.get(typ_f) {
            out = Some(t.trim_end().to_string());
        }
    });
    out
}

/// DELETE ONE ROW OF A SYSTEM RELATION, from outside this crate.
///
/// `Ok(false)` when no row matched, which is not an error: the caller
/// asking for a row that is already absent has got what it wanted.
///
/// The index entry is deliberately left behind, as it is everywhere
/// else here - an entry outlives the version that wrote it, and the
/// uniqueness check counts a conflicting entry only when its record
/// still builds that key ([maintain_indexes]). So the name can be
/// stored again straight away.
pub fn delete_system_row(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    pred: impl Fn(&[Value]) -> bool,
) -> Result<bool, String> {
    let Some((page, slot)) = find_sys_row_slot(file, page_size, rel_name, rel, pred) else {
        return Ok(false);
    };
    dml::delete_records(file, page_size, rel, &[(page, slot)])?;
    Ok(true)
}

/// STORE ONE NEW ROW INTO A SYSTEM RELATION, from outside this crate.
///
/// The other half of what the legacy BLR write API needs: gbak's
/// client-driven restore writes the whole metadata catalog this way,
/// one `STORE X IN RDB$<something>` request per row. Like
/// [patch_system_row] this is a thin face on the writer the DDL
/// planners already use ([sys_insert]) rather than a second one - it
/// starts every field NULL, sets the named ones, and keys the record
/// into every index the relation carries.
///
/// It does NOT do the engine's deferred work. Storing a row into
/// `RDB$RELATIONS` makes a catalog entry, not a usable relation - the
/// pointer page, the format blob and the `RDB$PAGES` rows come from
/// `DFW_post_work`, and a caller that needs them must post the
/// equivalent itself.
pub fn insert_system_row(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    values: &[(&str, SysValue<'_>)],
) -> Result<(), String> {
    let vals: Vec<(&str, SysVal<'_>)> = values
        .iter()
        .map(|(c, v)| {
            (
                *c,
                match v {
                    SysValue::Text(t) => SysVal::S(t),
                    SysValue::Int(n) => SysVal::I(*n),
                    SysValue::Double(d) => SysVal::F(*d),
                    SysValue::Blob(b) => SysVal::B(*b),
                    SysValue::Null => SysVal::Null,
                },
            )
        })
        .collect();
    sys_insert(file, page_size, rel_name, rel, &vals)
}

/// PATCH ONE ROW OF A SYSTEM RELATION, from outside this crate.
///
/// The legacy BLR write API (`blr_modify` over a system relation, which
/// is how gbak's client-driven restore re-points `RDB$DATABASE`) needs
/// exactly what [patch_sys_row] does and nothing more: find the row,
/// decode it AT ITS OWN FORMAT, and write the named columns back.
///
/// It is deliberately a thin wrapper rather than a new writer. Every
/// property that took a defect to learn - the row's own format rather
/// than the newest, the fragmented-row read-whole-patch-head path, the
/// back version and the deferred blob disposal under a DDL transaction -
/// belongs to that function, and a second implementation would have to
/// re-learn all of them.
///
/// `values` names columns by their catalog name; a text column takes
/// [SysValue::Text], which SPACE-pads to the column width the way the
/// engine's own `PAD()` does (ini.epp:785).
pub fn patch_system_row(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    pred: impl Fn(&[Value]) -> bool,
    values: &[(&str, SysValue<'_>)],
) -> Result<(), String> {
    let vals: Vec<(&str, SysVal<'_>)> = values
        .iter()
        .map(|(c, v)| {
            (
                *c,
                match v {
                    SysValue::Text(t) => SysVal::S(t),
                    SysValue::Int(n) => SysVal::I(*n),
                    SysValue::Double(d) => SysVal::F(*d),
                    SysValue::Blob(b) => SysVal::B(*b),
                    SysValue::Null => SysVal::Null,
                },
            )
        })
        .collect();
    patch_sys_row(file, page_size, rel_name, rel, pred, &vals)
}

/// The value shapes [patch_system_row] takes. A narrow public face over
/// the crate-private `SysVal`: the BLR write path assigns text, integers
/// and NULL, and has no business naming a raw blob id or an octet
/// column, whose padding rules differ.
pub enum SysValue<'a> {
    Text(&'a str),
    Int(i64),
    /// a DOUBLE PRECISION catalog column - an index's selectivity
    Double(f64),
    /// a blob column: the 8 on-disk bid bytes of a blob ALREADY
    /// materialised in the target relation
    Blob([u8; 8]),
    Null,
}

fn patch_sys_row(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    rel: u16,
    pred: impl Fn(&[Value]) -> bool,
    values: &[(&str, SysVal<'_>)],
) -> Result<(), String> {
    let formats =
        system_relation_formats(file, page_size, rel_name).ok_or("no computed system format")?;
    let (page, slot) = find_sys_row_slot(file, page_size, rel_name, rel, pred)
        .ok_or_else(|| format!("no matching {} row", rel_name))?;
    // THE ROW'S OWN FORMAT, NOT THE NEWEST ONE.
    //
    // This used to take `formats.iter().max_by_key(...)` - the relation's
    // LATEST format - and then poke the image at that format's field
    // OFFSETS and re-stamp the record with that format NUMBER. The image
    // itself was decoded at the record's own format, so on a row written
    // under an older format the poke landed on the wrong bytes AND the
    // row was relabelled as the newer shape, which makes every later read
    // decode the WHOLE row at offsets it was never written with.
    //
    // It leaves a file `gfix -v -full` calls clean, which is the worst
    // kind: the page structure is intact and only the values are wrong.
    // It needs a system relation carrying more than one format to fire,
    // so it has been latent rather than absent - and it is reachable on
    // ORDINARY rows, nothing to do with fragmentation.
    let (mut image, format_no, fragmented) = {
        let dp = DataPage::decode(crate::page_at(file, page_size, page).ok_or("bad page")?)
            .ok_or("bad data page")?;
        let r = dp.record(slot).ok_or("no row image")?;
        let frag = r.flags & crate::data::flags::INCOMPLETE != 0;
        // A FRAGMENTED ROW IS READ WHOLE and patched in its head. Reading
        // with `image()` answered None here, which is what refused 88
        // COMMENT ON and 92 DROP INDEX statements on an ordinary restored
        // database - see [dml::patch_head_in_place] for why the head is
        // enough and what happens when it is not.
        let img = crate::data::assembled_image(file, page_size, &r).ok_or("no row image")?;
        (img, r.format, frag)
    };
    let descs = formats
        .iter()
        .find(|(n, _)| *n == format_no)
        .map(|(_, d)| d.clone())
        .ok_or("the row's format is not among the relation's computed formats")?;
    // fmt_length as met.epp:1071 derives it (last stored descriptor's
    // offset + length) - the assembled image can carry the FILL pad as
    // literal zero data, and re-storing it unpadded is the law
    // ([dml::trim_fill_tail]; engine BUGCHECK 179 otherwise)
    let fmt_len = descs
        .iter()
        .filter(|d| d.offset != 0)
        .last()
        .map(|d| d.offset as usize + d.length as usize)
        .unwrap_or(0);
    let columns = relation_columns(file, page_size, rel_name);
    // which byte ranges the loop below actually changes, so a fragmented
    // row can be patched by range instead of rewritten whole
    let mut touched: Vec<(usize, usize)> = Vec::new();
    let mut superseded: Vec<(u16, u64)> = Vec::new();
    for (name, v) in values {
        let fid = columns
            .iter()
            .find(|c| c.name.eq_ignore_ascii_case(name))
            .ok_or_else(|| format!("unknown catalog column {}", name))?
            .field_id as usize;
        // a blob id this write is about to bury: captured before the
        // overwrite, freed only once the new row is down (and only if
        // the final image no longer names it anywhere - the engine's
        // going-minus-staying diff, blb.cpp:424)
        if let Some(old) = old_blob_at(&image, &descs, fid) {
            superseded.push(old);
        }
        if let SysVal::Null = v {
            image[fid / 8] |= 1 << (fid % 8); // NULL
            continue;
        }
        let d = descs.get(fid).ok_or("field beyond computed format")?;
        let bytes = encode_sys_value(d, v)?;
        let at = d.offset as usize;
        image
            .get_mut(at..at + bytes.len())
            .ok_or("image shorter than its format")?
            .copy_from_slice(&bytes);
        touched.push((at, bytes.len()));
        image[fid / 8] &= !(1 << (fid % 8)); // not NULL
    }
    let staying = image_blob_ids(&image, &descs);
    superseded.retain(|id| !staying.contains(id));
    if fragmented && file.ddl_tx.is_none() {
        // Only the bytes that actually changed, as offsets into the
        // assembled image - which for a fragmented record begins with the
        // head's own bytes, so an offset inside the head is the same
        // offset either way. `patch_head_in_place` re-checks that every
        // range lands in the head and refuses otherwise.
        //
        // SETTLED PATH ONLY: an in-place poke leaves no version behind,
        // so transaction-state rollback cannot see it (measured: a
        // rolled-back ALTER DOMAIN on a fragmented RDB$FIELDS row kept
        // the DROP half - the check vanished). Under `ddl_tx` the row
        // goes through the versioned update below instead - a
        // fragmented head CLONES as the back version, forward pointer
        // and all, so the engine's undo-by-state works unchanged.
        let mut pokes: Vec<(usize, Vec<u8>)> = Vec::new();
        for (at, len) in touched {
            pokes.push((at, image[at..at + len].to_vec()));
        }
        // the null-flag bytes are at the very front, so they are always
        // in the head
        pokes.push((0, image[..crate::format::flag_bytes(descs.len())].to_vec()));
        match dml::patch_head_in_place(file, page_size, page, slot, &pokes) {
            Ok(()) => {}
            // a poke past the head (or one the head's slot cannot take
            // back) rewrites the row whole instead: the old fragmented
            // head is CLONED as the back version - forward pointer and
            // all, so the tail pieces follow it - and the primary slot
            // gets a fresh head ([dml::push_back_version] accepts an
            // rhd_incomplete head for exactly this)
            Err(e)
                if e.starts_with("the field to patch lies past")
                    || e.starts_with("the patched head no longer fits") =>
            {
                let mut image = image;
                dml::trim_fill_tail(&mut image, fmt_len);
                dml::update_records(file, page_size, rel, &[(page, slot, image)], format_no)?;
            }
            Err(e) => return Err(e),
        }
    } else {
        let mut image = image;
        dml::trim_fill_tail(&mut image, fmt_len);
        dml::update_records(file, page_size, rel, &[(page, slot, image)], format_no)?;
    }
    if !superseded.is_empty() {
        for (orel, onum) in superseded {
            dispose_superseded_blob(file, page_size, orel, onum);
        }
        dispose_row_purge(file, page_size, rel, page, slot);
    }
    Ok(())
}

/// An index's selectivity, per key prefix: `1 / distinct` over the
/// relation's committed primary rows, counting a NULL key as a key
/// (engine probe: two all-NULL rows give 1.0). Prefix `i` covers
/// segments `0..=i`, so the last entry is the whole key's selectivity -
/// which is what `RDB$INDICES.RDB$STATISTICS` carries, while
/// `RDB$INDEX_SEGMENTS.RDB$STATISTICS` carries one per prefix. An empty
/// relation is 0.0, not 1/0.
///
/// The engine stores these as 4-byte floats both on the index root page
/// (`irtd_selectivity`) and in the catalog, so they are computed as f32.
fn index_selectivity(
    file: &crate::Image,
    page_size: usize,
    rel: u16,
    segs: &[(u16, u16, i8)],
    descending: bool,
) -> Result<Vec<f32>, String> {
    let formats = crate::relation_formats(file, page_size, rel);
    let (_, descs) = formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("relation has no format")?;
    let mut distinct: Vec<std::collections::BTreeSet<Vec<u8>>> =
        vec![std::collections::BTreeSet::new(); segs.len()];
    let mut rows = 0usize;
    let tips = crate::tra::TipChain::read(file, page_size);
    for dp_no in relation_data_pages(file, page_size, rel) {
        let Some(dp) = crate::page_at(file, page_size, dp_no).and_then(DataPage::decode) else {
            continue;
        };
        for r in dp.records() {
            let Some(image) = crate::data::catalog_image(file, page_size, &r, tips.as_ref()) else { continue };
            let values = decode_record(&image, descs);
            rows += 1;
            let null = Value::Null;
            for prefix in 0..segs.len() {
                let key_segs: Vec<btw::KeySeg<'_>> = segs[..=prefix]
                    .iter()
                    .map(|(field, itype, scale)| btw::KeySeg {
                        itype: *itype,
                        value: values.get(*field as usize).unwrap_or(&null),
                        scale: *scale,
                        charset: descs
                            .get(*field as usize)
                            .map_or(0, |d| crate::intl::charset_id(d.sub_type)),
                    })
                    .collect();
                let (key, _) = btw::build_index_key(&key_segs, descending)
                    .ok_or("unsupported value for an index key")?;
                distinct[prefix].insert(key);
            }
        }
    }
    Ok(distinct
        .iter()
        .map(|d| {
            if rows == 0 || d.is_empty() {
                0.0
            } else {
                1.0 / d.len() as f32
            }
        })
        .collect())
}

/// Write an index's computed selectivity where the engine keeps it:
/// the `irtd_selectivity` float of each segment descriptor on the index
/// root page, `RDB$INDEX_SEGMENTS.RDB$STATISTICS` per segment, and
/// `RDB$INDICES.RDB$STATISTICS` (the whole key's, i.e. the last prefix).
fn write_index_statistics(
    file: &mut crate::Image,
    page_size: usize,
    rel: u16,
    slot: usize,
    index_name: &str,
    selectivity: &[f32],
    // false for an EXPRESSION index: it has no RDB$INDEX_SEGMENTS rows
    // to carry per-segment statistics
    segment_rows: bool,
) -> Result<(), String> {
    let irt_page = file
        .pages()
        .position(|p| p[0] == 6 && u16_at(p, 16) == rel)
        .ok_or("relation has no index root page")? as u32;
    {
        let page = crate::page_mut(file, page_size, irt_page).ok_or("irt page out of range")?;
        let at = 24 + slot * 24;
        let desc_off = u16_at(page, at + 16) as usize;
        for (i, sel) in selectivity.iter().enumerate() {
            let d = desc_off + i * 8 + 4;
            page.get_mut(d..d + 4)
                .ok_or("segment descriptor beyond the root page")?
                .copy_from_slice(&sel.to_le_bytes());
        }
    }
    let seg_name = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$INDEX_NAME")?;
    let seg_pos = sys_fid(file, page_size, "RDB$INDEX_SEGMENTS", "RDB$FIELD_POSITION")?;
    let seg_rel = crate::resolve_relation(file, page_size, "RDB$INDEX_SEGMENTS")
        .ok_or("no RDB$INDEX_SEGMENTS relation")?;
    if segment_rows {
        for (i, sel) in selectivity.iter().enumerate() {
            patch_sys_row(
                file,
                page_size,
                "RDB$INDEX_SEGMENTS",
                seg_rel,
                |v| text_is(v.get(seg_name), index_name) && int_eq(v.get(seg_pos), i as i64),
                &[("RDB$STATISTICS", SysVal::F(*sel as f64))],
            )?;
        }
    }
    let ix_name = sys_fid(file, page_size, "RDB$INDICES", "RDB$INDEX_NAME")?;
    let whole = *selectivity.last().unwrap_or(&0.0);
    patch_sys_row(
        file,
        page_size,
        "RDB$INDICES",
        4,
        |v| text_is(v.get(ix_name), index_name),
        &[("RDB$STATISTICS", SysVal::F(whole as f64))],
    )
}

/// A generator's `(RDB$GENERATOR_ID, RDB$SYSTEM_FLAG, RDB$SECURITY_CLASS)`
/// from `RDB$GENERATORS`, by name. None when there is no such generator.
fn find_generator(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Option<(i64, i64, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")?;
    let formats = system_relation_formats(file, page_size, "RDB$GENERATORS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$GENERATORS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f, sys_f, cls_f) = (
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$GENERATOR_ID")?,
        fid("RDB$SYSTEM_FLAG")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |values| {
        if found.is_some() || !text_eq(values.get(name_f), name) {
            return;
        }
        let id = match values.get(id_f) {
            Some(Value::Int(i)) => *i,
            _ => return,
        };
        let sys = match values.get(sys_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        let class = match values.get(cls_f) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        found = Some((id, sys, class));
    });
    found
}

/// Whether a generator id is already spoken for - the condition the
/// engine's store loop discovers as a unique-key violation on
/// RDB$INDEX_46 and retries (DdlNodes.epp:6624).
fn generator_id_taken(file: &crate::Image, page_size: usize, id: i64) -> bool {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$GENERATORS") else {
        return false;
    };
    let Some(formats) = system_relation_formats(file, page_size, "RDB$GENERATORS") else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let Ok(id_f) = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_ID") else {
        return false;
    };
    let mut taken = false;
    walk_rows(file, page_size, rel, descs, |values| {
        if int_eq(values.get(id_f), id) {
            taken = true;
        }
    });
    taken
}

/// The privileges the owner of a SEQUENCE holds, in the order
/// `grant_privileges` emits them (acl.h): alter, control, drop, usage.
/// Differential probe of an engine-created sequence's `RDB$ACL`:
/// `02 01 03 06 SYSDBA 00 02 06 01 03 0c 00 00`.
const ACL_SEQUENCE_OWNER: &[u8] = &[6, 1, 3, 12];

/// The privileges the owner of a TABLE holds: the same three object
/// privileges - alter, control, drop - then insert, update, delete,
/// select and references. Probe of an engine-created table's `RDB$ACL`:
/// `02 01 03 06 SYSDBA 00 02 06 01 03 07 09 08 04 0a 00 00`.
const ACL_TABLE_OWNER: &[u8] = &[6, 1, 3, 7, 9, 8, 4, 10];

/// The privileges the owner of a ROLE holds: only the three object
/// privileges - alter, control, drop - with no usage (a role is not
/// something one holds a runtime privilege *on*). Probe of an
/// engine-created role's `RDB$ACL`: `02 01 03 06 SYSDBA 00 02 06 01 03 00 00`.
const ACL_ROLE_OWNER: &[u8] = &[6, 1, 3];

/// An owner's access control list for a newly created object, in the
/// engine's own encoding (acl.h): version 2, an id list naming the
/// owner as a person, then the privilege list for that kind of object.
fn owner_acl(owner: &str, privileges: &[u8]) -> Vec<u8> {
    let mut acl = vec![
        2u8, // ACL_version
        1,   // ACL_id_list
        3,   // id_person
        owner.len() as u8,
    ];
    acl.extend_from_slice(owner.as_bytes());
    acl.push(0); // id_end
    acl.push(2); // ACL_priv_list
    acl.extend_from_slice(privileges);
    acl.push(0); // priv_end
    acl.push(0); // ACL_end
    acl
}

/// Store one `RDB$SECURITY_CLASSES` row: the ACL blob (subtype 3) into
/// that relation's own data pages, then the row pointing at it. The
/// class name is the caller's `SQL$<n>`.
fn store_security_class(
    file: &mut crate::Image,
    page_size: usize,
    class: &str,
    owner: &str,
    privileges: &[u8],
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
        .ok_or("no RDB$SECURITY_CLASSES relation")?;
    let acl = dml::insert_blob(file, page_size, rel, &[owner_acl(owner, privileges)], 3)?;
    sys_insert(
        file,
        page_size,
        "RDB$SECURITY_CLASSES",
        rel,
        &[
            ("RDB$SECURITY_CLASS", SysVal::S(class)),
            ("RDB$ACL", SysVal::B(blob_id_bytes(rel, acl))),
        ],
    )
}

/// `CREATE SEQUENCE|GENERATOR <name> [START WITH <n>] [INCREMENT [BY]
/// <n>]` - the engine's `CreateAlterSequenceNode::executeCreate`
/// (DdlNodes.epp:6450) against the file image.
///
/// Three writes, in the engine's order. The id comes from the MASTER
/// generator - slot 0 of the generator vector, the counter every
/// metadata object id is drawn from (`DYN_UTIL_gen_unique_id(...,
/// MASTER_GENERATOR)`), taken modulo `MAX_SSHORT + 1` with zero skipped,
/// and retried while it collides with a live generator. Storing the row
/// makes `vio.cpp:4657` allocate a security class name from slot 1
/// (`RDB$SECURITY_CLASS`, the `SQL$<n>` counter), whose row carries the
/// owner's ACL, and `storePrivileges` records the owner's USAGE grant.
/// Finally the sequence's own slot is left holding `initial - step`, so
/// the first `GEN_ID`/`NEXT VALUE FOR` yields `initial` exactly.
///
/// Creating a sequence therefore *writes generator values* - two of
/// them - before it has a value of its own.
pub fn create_sequence(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    start: Option<i64>,
    increment: Option<i64>,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a sequence needs a name".into());
    }
    if find_generator(file, page_size, &want).is_some() {
        return Err(format!("Sequence {} already exists", want));
    }
    let step = increment.unwrap_or(1);
    if step == 0 {
        return Err(format!(
            "INCREMENT BY 0 is an illegal option for sequence {}",
            want
        ));
    }
    let initial = start.unwrap_or(1);
    write_generator(file, page_size, &want, 0, initial, step)?;
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// Write one `RDB$GENERATORS` row - a user sequence (`system_flag` 0) or an
/// implicit identity generator (`system_flag` 6). The id comes from the master
/// generator (modulo `MAX_SSHORT + 1`, never 0, never a live id); the row gets
/// an `SQL$<n>` security class with the owner's ACL and a USAGE privilege; and
/// the slot is primed to `initial - step` so the first draw yields `initial`.
/// Set a sequence's CURRENT value - what `gbak`'s restore does with
/// the value the backup carried (the engine's att_gen_value_int64):
/// the slot in the generator vector, not any catalog column.
pub fn set_sequence_value(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    value: i64,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (id, _, _) = find_generator(file, page_size, &want)
        .ok_or_else(|| format!("Sequence {} does not exist", want))?;
    gen::write(file, page_size, id, value)
}

/// The next number a SYSTEM GENERATOR hands out for a metadata object -
/// `RDB$EXCEPTIONS` for an exception's number, `RDB$PROCEDURES` for a
/// procedure's id, `RDB$FUNCTIONS` for a function's (vio.cpp
/// `set_metadata_id` -> `DYN_UTIL_gen_unique_id`, when the stored row
/// left the column NULL, as gbak's does). The engine's SSHORT cast is
/// kept: the ids are shorts.
pub fn next_metadata_id(file: &mut crate::Image, page_size: usize, generator: &str) -> Result<i64, String> {
    let slot = generator_id_by_name(file, page_size, generator)
        .ok_or_else(|| format!("no {generator} generator"))?;
    Ok(gen::bump(file, page_size, slot, 1)? as i16 as i64)
}

/// The next generator id, the engine's way: drawn from the MASTER
/// generator modulo `MAX_SSHORT + 1`, zero skipped, retried while it
/// names a live generator (`set_metadata_id` in vio.cpp, which a
/// gbak-stored `RDB$GENERATORS` row with a NULL id goes through at store
/// time; `DYN_UTIL_gen_unique_id` for DDL).
pub fn next_generator_id(file: &mut crate::Image, page_size: usize) -> Result<i64, String> {
    for _ in 0..=u16::MAX {
        let next = gen::bump(file, page_size, gen::MASTER, 1)? % (i16::MAX as i64 + 1);
        if next != 0 && !generator_id_taken(file, page_size, next) {
            return Ok(next);
        }
    }
    Err("no free generator id".into())
}

fn write_generator(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    system_flag: i64,
    initial: i64,
    step: i64,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")
        .ok_or("no RDB$GENERATORS relation")?;
    let id = next_generator_id(file, page_size)?;
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$GENERATORS",
        rel,
        &[
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$GENERATOR_NAME", SysVal::S(name)),
            ("RDB$GENERATOR_ID", SysVal::I(id)),
            ("RDB$SYSTEM_FLAG", SysVal::I(system_flag)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$INITIAL_VALUE", SysVal::I(initial)),
            ("RDB$GENERATOR_INCREMENT", SysVal::I(step)),
        ],
    )?;
    store_privileges(file, page_size, name, 14, &["G"])?;
    let stored = initial.wrapping_sub(step);
    if stored != 0 {
        gen::write(file, page_size, id, stored)?;
    }
    Ok(())
}

/// The first of `count` consecutive system-generated `RDB$<n>` generator
/// names (the implicit generator behind an identity column), from the
/// engine's own counter for them - the system generator
/// `RDB$GENERATOR_NAME` (probed: a table with an identity column
/// created, dropped, then created again leaves GEN_ID 3 and names the
/// third generator RDB$3, never re-using the dropped RDB$2).
fn next_generator_number(
    file: &mut crate::Image,
    page_size: usize,
    count: u64,
) -> Result<u64, String> {
    let used =
        used_numeric_suffixes(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_NAME", &["RDB$"])?;
    let fallback = used.iter().copied().max().unwrap_or(0) + 1;
    draw_from_counter(file, page_size, "RDB$GENERATOR_NAME", false, 1, count, &used, fallback)
}

/// The owner every fire-crab-written catalog object belongs to. The
/// server attaches as SYSDBA; the engine writes
/// `attachment->getEffectiveUserName()`.
const OWNER: &str = "SYSDBA";

/// The owner's `WITH GRANT OPTION` rows in `RDB$USER_PRIVILEGES` - one
/// per privilege letter, user type 8 (obj_user) and the object's own
/// type: 14 (obj_generator) for a sequence, 0 (obj_relation) for a
/// table. A sequence's owner gets 'G' (usaGe); a table's owner gets
/// S/I/U/D/R (select, insert, update, delete, references), the five
/// rows an engine-created table carries.
fn store_privileges(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    object_type: i64,
    privileges: &[&str],
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    for p in privileges {
        sys_insert(
            file,
            page_size,
            "RDB$USER_PRIVILEGES",
            rel,
            &[
                ("RDB$USER", SysVal::S(OWNER)),
                ("RDB$GRANTOR", SysVal::S(OWNER)),
                ("RDB$PRIVILEGE", SysVal::S(p)),
                ("RDB$GRANT_OPTION", SysVal::I(1)),
                ("RDB$RELATION_NAME", SysVal::S(name)),
                ("RDB$USER_TYPE", SysVal::I(8)),
                ("RDB$OBJECT_TYPE", SysVal::I(object_type)),
                ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ],
        )?;
    }
    Ok(())
}

/// The privileges an engine-created table's owner holds, in the order
/// the engine stores them: select, insert, update, delete, references.
const TABLE_OWNER_PRIVILEGES: &[&str] = &["S", "I", "U", "D", "R"];

/// A relation's `(RDB$SECURITY_CLASS, RDB$OWNER_NAME, RDB$DEFAULT_CLASS)`
/// from RDB$RELATIONS.
fn relation_security(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Option<(String, String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, sc_f, own_f, dc_f) = (
        fid("RDB$RELATION_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$DEFAULT_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_none() && text_is(v.get(name_f), table) {
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let dc = match v.get(dc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => String::new(),
            };
            found = Some((sc, own, dc));
        }
    });
    found
}

// --- the engine's ACL compiler (grant.epp / scl.epp), ported for the
//     relation + field privilege recompute ---

// SCL_* privilege flags (scl.h)
const SCL_SELECT: u32 = 1;
const SCL_DROP: u32 = 2;
const SCL_CONTROL: u32 = 4;
const SCL_ALTER: u32 = 16;
const SCL_INSERT: u32 = 64;
const SCL_DELETE: u32 = 128;
const SCL_UPDATE: u32 = 256;
const SCL_REFERENCES: u32 = 512;
const SCL_EXECUTE: u32 = 1024;
const SCL_USAGE: u32 = 2048;

/// A relation owner's privilege mask (grant.epp:121-128): control, drop,
/// alter, then the four DML and references.
const OWNER_RELATION_PRIVS: u32 = SCL_CONTROL
    | SCL_DROP
    | SCL_ALTER
    | SCL_REFERENCES
    | SCL_SELECT
    | SCL_INSERT
    | SCL_UPDATE
    | SCL_DELETE;

/// A procedure/function owner's privilege mask: alter, control, drop, execute
/// (probe: the owner ACE bytes are 6 1 3 11).
const OWNER_PROCEDURE_PRIVS: u32 = SCL_ALTER | SCL_CONTROL | SCL_DROP | SCL_EXECUTE;

/// A usage-object (sequence, exception) owner's privilege mask: alter,
/// control, drop, usage (probe: the owner ACE bytes are 6 1 3 12).
const OWNER_USAGE_PRIVS: u32 = SCL_ALTER | SCL_CONTROL | SCL_DROP | SCL_USAGE;

/// A SQL privilege letter to its SCL flag (grant.epp `trans_sql_priv`, the
/// letters a relation/field grant uses).
fn sql_priv_flag(letter: char) -> u32 {
    match letter.to_ascii_uppercase() {
        'S' => SCL_SELECT,
        'I' => SCL_INSERT,
        'U' => SCL_UPDATE,
        'D' => SCL_DELETE,
        'R' => SCL_REFERENCES,
        _ => 0,
    }
}

/// The ACL privilege bytes for a mask, in the `p_names` emission order
/// (scl.epp:94 - alter, control, drop, insert, update, delete, select,
/// references), which `SCL_move_priv` walks.
fn move_priv(mask: u32) -> Vec<u8> {
    const ORDER: &[(u32, u8)] = &[
        (SCL_ALTER, 6),
        (SCL_CONTROL, 1),
        (SCL_DROP, 3),
        (SCL_INSERT, 7),
        (SCL_UPDATE, 9),
        (SCL_DELETE, 8),
        (SCL_SELECT, 4),
        (SCL_REFERENCES, 10),
        (SCL_EXECUTE, 11),
        (SCL_USAGE, 12),
    ];
    ORDER
        .iter()
        .filter(|(f, _)| mask & f != 0)
        .map(|(_, c)| *c)
        .collect()
}

/// An ACL under construction: ordered (person, mask) entries; a `None`
/// person is the all-users wildcard.
type AclList = Vec<(Option<String>, u32)>;

/// grant_user (grant.epp:653): append a person's ACE, unless the mask is
/// empty (then nothing is added).
fn acl_grant_user(acl: &mut AclList, person: Option<String>, privs: u32) {
    if privs != 0 {
        acl.push((person, privs));
    }
}

/// squeeze_acl (grant.epp:1045): find a person's ACE, remove it, return
/// its privileges (0 if absent). The removal is what lets a re-grant move
/// the person to the end of the list.
fn acl_squeeze(acl: &mut AclList, person: &str) -> u32 {
    if let Some(i) = acl.iter().position(|(p, _)| p.as_deref() == Some(person)) {
        acl.remove(i).1
    } else {
        0
    }
}

/// Serialize an [AclList] to the engine's acl.h version-2 bytes.
fn acl_serialize(acl: &AclList) -> Vec<u8> {
    let mut out = vec![2u8]; // ACL_version
    for (person, privs) in acl {
        out.push(1); // ACL_id_list
        if let Some(name) = person {
            out.push(3); // id_person
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
        }
        out.push(0); // id_end
        out.push(2); // ACL_priv_list
        out.extend_from_slice(&move_priv(*privs));
        out.push(0); // priv_end
    }
    out.push(0); // ACL_end
    out
}

/// The recomputed security-class ACLs for a relation and its granted
/// fields.
struct RecomputedAcls {
    /// the relation's own class ACL bytes
    relation: Vec<u8>,
    /// (field name, that field's class ACL bytes), fields with grants
    fields: Vec<(String, Vec<u8>)>,
    /// the RDB$DEFAULT_CLASS ACL bytes, present only when field grants
    /// added relation-level ACEs (the engine's `restrct`)
    default: Option<Vec<u8>>,
}

/// Recompute a relation's ACLs from the privileges now in
/// `RDB$USER_PRIVILEGES`, a faithful port of the engine's
/// `GRANT_privileges` (grant.epp): the owner ACE, the relation-level
/// grantees alphabetically (each unioned with PUBLIC), then the field
/// grantees folded in with the squeeze-and-reappend that orders a person
/// by their last field. Each granted field gets its own class ACL (owner
/// + relation grantees + that field's grantees), and if field grants add
/// relation-level ACEs the default class is rebuilt without them.
fn recompute_acls(file: &crate::Image, page_size: usize, table: &str, owner: &str) -> RecomputedAcls {
    use std::collections::BTreeMap;
    let mut public_priv = 0u32;
    let mut rel_grantees: BTreeMap<String, u32> = BTreeMap::new();
    let mut field_rows: BTreeMap<(String, String), u32> = BTreeMap::new();

    if let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) {
        if let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) {
            let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
            let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            if let (Some(u_f), Some(p_f), Some(rn_f), Some(fn_f), Some(ot_f)) = (
                fid("RDB$USER"),
                fid("RDB$PRIVILEGE"),
                fid("RDB$RELATION_NAME"),
                fid("RDB$FIELD_NAME"),
                fid("RDB$OBJECT_TYPE"),
            ) {
                walk_rows(file, page_size, rel, descs, |v| {
                    if !text_is(v.get(rn_f), table) || !int_eq(v.get(ot_f), 0) {
                        return;
                    }
                    let user = match v.get(u_f) {
                        Some(Value::Text(t)) => t.trim_end().to_string(),
                        _ => return,
                    };
                    if user.eq_ignore_ascii_case(owner) {
                        return; // the owner ACE is fixed, not read from rows
                    }
                    let flag = match v.get(p_f) {
                        Some(Value::Text(t)) => {
                            t.trim_end().chars().next().map_or(0, sql_priv_flag)
                        }
                        _ => 0,
                    };
                    if flag == 0 {
                        return;
                    }
                    match v.get(fn_f) {
                        Some(Value::Text(t)) => {
                            *field_rows.entry((t.trim_end().to_string(), user)).or_default() |= flag;
                        }
                        _ if user == "PUBLIC" => public_priv |= flag,
                        _ => *rel_grantees.entry(user).or_default() |= flag,
                    }
                });
            }
        }
    }

    // GRANT_privileges: owner, then relation-level grantees (get_user_privs)
    let mut acl: AclList = vec![(Some(owner.to_string()), OWNER_RELATION_PRIVS)];
    for (user, mask) in &rel_grantees {
        acl_grant_user(&mut acl, Some(user.clone()), public_priv | mask);
    }
    let base_len = acl.len();
    let acl_start = acl.clone();

    // save_field_privileges: fold field grantees into acl (squeeze+reappend)
    // and build each field's own class, walking (field, user) in order
    let mut aggregate_public = public_priv;
    let mut fields_out: Vec<(String, Vec<u8>)> = Vec::new();
    let mut cur_field: Option<String> = None;
    let mut field_acl = acl_start.clone();
    let mut field_public = 0u32;
    let finish_field =
        |name: String, mut fa: AclList, field_public: u32, public_priv: u32| -> (String, Vec<u8>) {
            if (field_public | public_priv) != 0 {
                fa.push((None, field_public | public_priv));
            }
            (name, acl_serialize(&fa))
        };
    for ((f, u), mask) in &field_rows {
        if cur_field.as_deref() != Some(f.as_str()) {
            if let Some(of) = cur_field.take() {
                aggregate_public |= field_public;
                fields_out.push(finish_field(of, field_acl.clone(), field_public, public_priv));
            }
            cur_field = Some(f.clone());
            field_public = 0;
            field_acl = acl_start.clone();
        }
        if u != "PUBLIC" {
            let fp = public_priv | mask | acl_squeeze(&mut field_acl, u);
            acl_grant_user(&mut field_acl, Some(u.clone()), fp);
            let rp = public_priv | mask | acl_squeeze(&mut acl, u);
            acl_grant_user(&mut acl, Some(u.clone()), rp);
        } else {
            field_public |= public_priv | mask;
        }
    }
    if let Some(of) = cur_field {
        aggregate_public |= field_public;
        fields_out.push(finish_field(of, field_acl, field_public, public_priv));
    }

    // finish the relation class (all-users wildcard) and, if field grants
    // added relation ACEs, the default class without them (restrct)
    let mut rel_final = acl.clone();
    if aggregate_public != 0 {
        rel_final.push((None, aggregate_public));
    }
    let default = if acl.len() != base_len {
        let mut da = acl_start;
        if public_priv != 0 {
            da.push((None, public_priv));
        }
        Some(acl_serialize(&da))
    } else {
        None
    };

    RecomputedAcls {
        relation: acl_serialize(&rel_final),
        fields: fields_out,
        default,
    }
}

/// Write (rewrite in place) a security class's `RDB$ACL` blob.
fn write_class_acl(
    file: &mut crate::Image,
    page_size: usize,
    class: &str,
    acl: &[u8],
) -> Result<(), String> {
    let screl = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
        .ok_or("no RDB$SECURITY_CLASSES relation")?;
    let blob = dml::insert_blob(file, page_size, screl, &[acl.to_vec()], 3)?;
    let name_fid = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
    let cl = class.to_string();
    patch_sys_row(
        file,
        page_size,
        "RDB$SECURITY_CLASSES",
        screl,
        move |v| text_eq(v.get(name_fid), &cl),
        &[("RDB$ACL", SysVal::B(blob_id_bytes(screl, blob)))],
    )
}

/// A field's current `RDB$SECURITY_CLASS` (None if NULL/empty).
fn field_security_class(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    field: &str,
) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (rn_f, fn_f, sc_f) = (
        fid("RDB$RELATION_NAME")?,
        fid("RDB$FIELD_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_is(v.get(rn_f), table) && text_is(v.get(fn_f), field) {
            if let Some(Value::Text(t)) = v.get(sc_f) {
                let t = t.trim_end();
                if !t.is_empty() {
                    out = Some(t.to_string());
                }
            }
        }
    });
    out
}

/// The fields of a relation that currently carry a `SQL$GRANT<n>` security
/// class (a column grant's class), as (field name, class name).
fn granted_field_classes(
    file: &crate::Image,
    page_size: usize,
    table: &str,
) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS"),
        system_relation_formats(file, page_size, "RDB$RELATION_FIELDS"),
    ) else {
        return out;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return out;
    };
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(rn_f), Some(fn_f), Some(sc_f)) =
        (fid("RDB$RELATION_NAME"), fid("RDB$FIELD_NAME"), fid("RDB$SECURITY_CLASS"))
    else {
        return out;
    };
    walk_rows(file, page_size, rel, descs, |v| {
        if !text_is(v.get(rn_f), table) {
            return;
        }
        if let (Some(Value::Text(fname)), Some(Value::Text(cls))) = (v.get(fn_f), v.get(sc_f)) {
            let cls = cls.trim_end();
            if cls.starts_with("SQL$GRANT") {
                out.push((fname.trim_end().to_string(), cls.to_string()));
            }
        }
    });
    out
}

/// Set (or clear, with `None`) a field's `RDB$RELATION_FIELDS.RDB$SECURITY_CLASS`.
fn set_field_security_class(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    field: &str,
    class: Option<&str>,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS relation")?;
    let rn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$RELATION_NAME")?;
    let fn_f = sys_fid(file, page_size, "RDB$RELATION_FIELDS", "RDB$FIELD_NAME")?;
    let (t, f) = (table.to_string(), field.to_string());
    let value = match class {
        Some(c) => SysVal::S(c),
        None => SysVal::Null,
    };
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATION_FIELDS",
        rel,
        move |v| text_is(v.get(rn_f), &t) && text_is(v.get(fn_f), &f),
        &[("RDB$SECURITY_CLASS", value)],
    )
}

/// Recompute and write a relation's own class ACL, every granted field's
/// class ACL (allocating a `SQL$GRANT<n>` class for a newly granted field,
/// dropping and clearing one whose last grant was revoked) and, when field
/// grants added relation-level ACEs, the default class.
fn recompute_relation_acl(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
) -> Result<(), String> {
    let (class, owner, default_class) = relation_security(file, page_size, table)
        .ok_or_else(|| format!("relation {} has no security class", table))?;
    let acls = recompute_acls(file, page_size, table, &owner);

    // the relation's own class
    write_class_acl(file, page_size, &class, &acls.relation)?;

    // each granted field's class (create SQL$GRANT<n> if the field has none)
    let granted: std::collections::BTreeSet<&str> =
        acls.fields.iter().map(|(f, _)| f.as_str()).collect();
    for (field, field_acl) in &acls.fields {
        let fclass = match field_security_class(file, page_size, table, field) {
            Some(c) => c,
            None => {
                let n = gen::bump(file, page_size, gen::SECURITY_CLASS, 1)?;
                let c = format!("SQL$GRANT{}", n);
                // the class row is stored with the field ACL itself
                let screl = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
                    .ok_or("no RDB$SECURITY_CLASSES relation")?;
                let blob = dml::insert_blob(file, page_size, screl, &[field_acl.clone()], 3)?;
                sys_insert(
                    file,
                    page_size,
                    "RDB$SECURITY_CLASSES",
                    screl,
                    &[
                        ("RDB$SECURITY_CLASS", SysVal::S(&c)),
                        ("RDB$ACL", SysVal::B(blob_id_bytes(screl, blob))),
                    ],
                )?;
                set_field_security_class(file, page_size, table, field, Some(&c))?;
                continue;
            }
        };
        write_class_acl(file, page_size, &fclass, field_acl)?;
    }

    // a field whose last grant was revoked: drop its class, clear the column
    for (field, fclass) in granted_field_classes(file, page_size, table) {
        if !granted.contains(field.as_str()) {
            let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
            let c = fclass.clone();
            delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
                text_eq(v.get(cls_f), &c)
            })?;
            set_field_security_class(file, page_size, table, &field, None)?;
        }
    }

    // the default class, only when field grants added relation-level ACEs
    if let Some(default_acl) = &acls.default {
        write_class_acl(file, page_size, &default_class, default_acl)?;
    }
    Ok(())
}


/// Write a security class's ACL, creating the `RDB$SECURITY_CLASSES` row
/// when the class is only a NAME so far - which is every class a gbak
/// restore's object rows name: the backup carries the names, the engine
/// recompiles the rows from the restored privileges (`dfw_grant`).
fn upsert_class_acl(file: &mut crate::Image, page_size: usize, class: &str, acl: &[u8]) -> Result<(), String> {
    let screl = crate::resolve_relation(file, page_size, "RDB$SECURITY_CLASSES")
        .ok_or("no RDB$SECURITY_CLASSES relation")?;
    let name_fid = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
    let cl = class.to_string();
    let exists = find_sys_row_slot(file, page_size, "RDB$SECURITY_CLASSES", screl, move |v| text_eq(v.get(name_fid), &cl)).is_some();
    if exists {
        return write_class_acl(file, page_size, class, acl);
    }
    let blob = dml::insert_blob(file, page_size, screl, &[acl.to_vec()], 3)?;
    sys_insert(
        file,
        page_size,
        "RDB$SECURITY_CLASSES",
        screl,
        &[
            ("RDB$SECURITY_CLASS", SysVal::S(class)),
            ("RDB$ACL", SysVal::B(blob_id_bytes(screl, blob))),
        ],
    )
}

/// An object's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` off the system
/// relation that holds it, by its name column - the exception, domain,
/// character-set and collation shape of [procedure_owner_class].
fn object_owner_class(
    file: &crate::Image,
    page_size: usize,
    rel_name: &str,
    name_col: &str,
    name: &str,
) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, rel_name)?;
    let formats = system_relation_formats(file, page_size, rel_name)?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, rel_name);
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (fid(name_col)?, fid("RDB$OWNER_NAME")?, fid("RDB$SECURITY_CLASS")?);
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), name) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            if !sc.is_empty() {
                out = Some((own, sc));
            }
        }
    });
    out
}

/// `dfw_grant` for one object, at commit: `GRANT_privileges` (grant.epp:89)
/// recompiled from the `RDB$USER_PRIVILEGES` rows now present, keyed by
/// the object type the privilege row carried (obj.h). Reads WIDE - the
/// rows are this transaction's. The object's class row is created when it
/// is missing, and a relation without an `RDB$DEFAULT_CLASS` is given one
/// (`SQL$DEFAULT<n>`, the relation's own ACL until field grants restrict
/// it - the engine's restore of the employee sample leaves the two
/// byte-identical, measured). A type this server does not compile a class
/// for - the DDL-object grants, the schema - is left as it is. THE
/// CONSEQUENCE OF NOT DOING THIS IS NOT A COSMETIC ONE: the engine treats
/// a class with no row as UNCHECKED, so a restore that stored the rows
/// alone answered a non-SYSDBA user `gen_id(EMP_NO_GEN, 0)` where the
/// engine's own restore refuses `no permission for USAGE access`.
pub fn grant_privileges_deferred(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    object_type: i64,
) -> Result<(), String> {
    let _wide = crate::tra::ReaderViewGuard::wide();
    let usage = |file: &mut crate::Image, rel_name: &str, name_col: &str, letter: &str| -> Result<(), String> {
        let Some((owner, class)) = object_owner_class(file, page_size, rel_name, name_col, name) else {
            return Ok(());
        };
        let acl = build_object_acl(file, page_size, name, object_type, letter, &owner, OWNER_USAGE_PRIVS, SCL_USAGE);
        upsert_class_acl(file, page_size, &class, &acl)
    };
    match object_type {
        // obj_relation / obj_view
        0 | 1 => {
            let Some((class, owner, default_class)) = relation_security(file, page_size, name) else {
                return Ok(());
            };
            if class.is_empty() {
                return Ok(());
            }
            let acls = recompute_acls(file, page_size, name, &owner);
            upsert_class_acl(file, page_size, &class, &acls.relation)?;
            let default_acl = acls.default.clone().unwrap_or_else(|| acls.relation.clone());
            if default_class.is_empty() {
                let id = generator_id_by_name(file, page_size, "SQL$DEFAULT").ok_or("no SQL$DEFAULT generator")?;
                let c = format!("SQL$DEFAULT{}", gen::bump(file, page_size, id, 1)?);
                upsert_class_acl(file, page_size, &c, &default_acl)?;
                let rrel = crate::resolve_relation(file, page_size, "RDB$RELATIONS").ok_or("no RDB$RELATIONS")?;
                let name_fid = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
                let want = name.to_string();
                patch_sys_row(
                    file,
                    page_size,
                    "RDB$RELATIONS",
                    rrel,
                    move |v| text_is(v.get(name_fid), &want),
                    &[("RDB$DEFAULT_CLASS", SysVal::S(&c))],
                )?;
            } else {
                upsert_class_acl(file, page_size, &default_class, &default_acl)?;
            }
            // the granted fields' own classes, and the default class again
            // when field grants restricted it
            recompute_relation_acl(file, page_size, name)
        }
        // obj_procedure
        5 => {
            let Some((owner, class)) = procedure_owner_class(file, page_size, name) else { return Ok(()) };
            let acl = build_object_acl(file, page_size, name, 5, "X", &owner, OWNER_PROCEDURE_PRIVS, SCL_EXECUTE);
            upsert_class_acl(file, page_size, &class, &acl)
        }
        // obj_udf
        15 => {
            let Some((owner, class)) = function_owner_class(file, page_size, name) else { return Ok(()) };
            let acl = build_object_acl(file, page_size, name, 15, "X", &owner, OWNER_PROCEDURE_PRIVS, SCL_EXECUTE);
            upsert_class_acl(file, page_size, &class, &acl)
        }
        // obj_generator
        14 => {
            let Some((owner, class)) = generator_owner_class(file, page_size, name) else { return Ok(()) };
            let acl = build_object_acl(file, page_size, name, 14, "G", &owner, OWNER_USAGE_PRIVS, SCL_USAGE);
            upsert_class_acl(file, page_size, &class, &acl)
        }
        // obj_exception / obj_field / obj_charset / obj_collation
        7 => usage(file, "RDB$EXCEPTIONS", "RDB$EXCEPTION_NAME", "G"),
        9 => usage(file, "RDB$FIELDS", "RDB$FIELD_NAME", "G"),
        11 => usage(file, "RDB$CHARACTER_SETS", "RDB$CHARACTER_SET_NAME", "G"),
        17 => usage(file, "RDB$COLLATIONS", "RDB$COLLATION_NAME", "G"),
        _ => Ok(()),
    }
}

/// One column of a system relation's row for `name`, as text.
fn sys_text_of(file: &crate::Image, page_size: usize, rel_name: &str, key_col: &str, key: &str, col: &str) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)?;
    let formats = system_relation_formats(file, page_size, rel_name)?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, rel_name);
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (k_f, c_f) = (fid(key_col)?, fid(col)?);
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(k_f), key) {
            if let Some(Value::Text(t)) = v.get(c_f) {
                out = Some(t.trim_end().to_string());
            }
        }
    });
    out
}

/// A blob column of a system relation's row for `name`: its bytes.
fn sys_blob_of(file: &crate::Image, page_size: usize, rel_name: &str, key_col: &str, key: &str, col: &str) -> Option<Vec<u8>> {
    let rel = crate::resolve_relation(file, page_size, rel_name)?;
    let formats = system_relation_formats(file, page_size, rel_name)?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, rel_name);
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (k_f, c_f) = (fid(key_col)?, fid(col)?);
    let mut id = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if id.is_none() && text_eq(v.get(k_f), key) {
            if let Some(Value::Blob(r, n)) = v.get(c_f) {
                id = Some((*r, *n));
            }
        }
    });
    let (r, n) = id?;
    crate::format::read_blob_content(file, page_size, r, n)
}

/// What a BLR context is bound to while resolving dependencies.
#[derive(Clone, Debug)]
enum CtxBind {
    Relation(String),
    Procedure(String),
}

/// `MET_get_dependencies` for a row a client stored: the object's BLR is
/// walked ([crate::blr::decode]) and every reference the engine's parse
/// would record (`PAR_dependency`, `csb->addDependency`) becomes an
/// RDB$DEPENDENCIES row - `kind` is RDB$DEPENDENT_TYPE: 5 a procedure
/// (RDB$PROCEDURE_BLR), 2 a trigger (RDB$TRIGGER_BLR, with contexts 0 and
/// 1 bound to its relation, the way `PAR_blr` binds them - which is why
/// a trigger's own columns give field rows and no relation row), 1 a
/// view (RDB$VIEW_BLR, plus the base fields its columns name, as
/// `PAR_make_field` records them from RSR_base_field). Reads WIDE.
///
/// Rows: a stream opened on a relation is a NULL-field row (type 0, or 1
/// when the relation is a view); a field of a bound relation a field row;
/// a procedure called or opened a type-5 row (named arguments as field
/// rows); a generator drawn a type-14 row unless it is a system one
/// (`MET_store_dependency` drops those); an exception raised or handled a
/// type-7 row; a user function type 15; a domain named in a descriptor
/// type 9; an explicit collation type 17. Deduplicated on (name, type,
/// field) as the engine's store lookups do, and inserted in the REVERSE
/// of encounter order - `MET_store_dependencies` pops its array. The
/// object's existing rows of this type go first (`MET_delete_dependencies`).
pub fn store_dependencies_deferred(file: &mut crate::Image, page_size: usize, kind: i64, name: &str) -> Result<(), String> {
    let _wide = crate::tra::ReaderViewGuard::wide();
    let (blr, own_relation): (Vec<u8>, Option<String>) = match kind {
        5 => (
            match sys_blob_of(file, page_size, "RDB$PROCEDURES", "RDB$PROCEDURE_NAME", name, "RDB$PROCEDURE_BLR") {
                Some(b) => b,
                None => return Ok(()), // no body: nothing depends on anything
            },
            None,
        ),
        2 => (
            match sys_blob_of(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME", name, "RDB$TRIGGER_BLR") {
                Some(b) => b,
                None => return Ok(()),
            },
            sys_text_of(file, page_size, "RDB$TRIGGERS", "RDB$TRIGGER_NAME", name, "RDB$RELATION_NAME"),
        ),
        1 => (
            match sys_blob_of(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME", name, "RDB$VIEW_BLR") {
                Some(b) => b,
                None => return Ok(()),
            },
            None,
        ),
        _ => return Ok(()),
    };
    let decoded = crate::blr::decode(&blr).map_err(|e| format!("dependencies of {name}: {e}"))?;

    let mut ctx: std::collections::HashMap<u8, CtxBind> = std::collections::HashMap::new();
    if let Some(rel) = &own_relation {
        ctx.insert(0, CtxBind::Relation(rel.clone()));
        ctx.insert(1, CtxBind::Relation(rel.clone()));
    }
    // (depended-on name, its type, field) in encounter order
    let mut deps: Vec<(String, i64, Option<String>)> = Vec::new();
    let rels = crate::catalog::list_relations(file, page_size);
    let rel_type = |file: &crate::Image, r: &str| -> i64 { if is_view(file, page_size, r) { 1 } else { 0 } };
    for ev in &decoded.deps {
        match ev {
            crate::blr::DepEvent::RelCtx { ctx: c, name: r } => {
                ctx.insert(*c, CtxBind::Relation(r.clone()));
                deps.push((r.clone(), rel_type(file, r), None));
            }
            crate::blr::DepEvent::RelId { ctx: c, id } => {
                if let Some((_, r)) = rels.iter().find(|(i, _)| *i == *id) {
                    let r = r.trim_end().to_string();
                    ctx.insert(*c, CtxBind::Relation(r.clone()));
                    deps.push((r.clone(), rel_type(file, &r), None));
                }
            }
            crate::blr::DepEvent::ProcCtx { ctx: c, name: p } => {
                ctx.insert(*c, CtxBind::Procedure(p.clone()));
                deps.push((p.clone(), 5, None));
            }
            crate::blr::DepEvent::Field { ctx: c, name: f } => match ctx.get(c) {
                Some(CtxBind::Relation(r)) => deps.push((r.clone(), rel_type(file, r), Some(f.clone()))),
                Some(CtxBind::Procedure(p)) => deps.push((p.clone(), 5, Some(f.clone()))),
                None => {}
            },
            crate::blr::DepEvent::Fid { ctx: c, id } => match ctx.get(c) {
                Some(CtxBind::Relation(r)) => {
                    if let Some(col) = relation_columns(file, page_size, r).iter().find(|col| col.field_id == *id) {
                        deps.push((r.clone(), rel_type(file, r), Some(col.name.clone())));
                    }
                }
                Some(CtxBind::Procedure(p)) => {
                    if let Some(param) = procedure_param_name(file, page_size, p, 1, *id as i64) {
                        deps.push((p.clone(), 5, Some(param)));
                    }
                }
                None => {}
            },
            crate::blr::DepEvent::ExecProc { name: p } => deps.push((p.clone(), 5, None)),
            crate::blr::DepEvent::ProcArg { proc, arg } => deps.push((proc.clone(), 5, Some(arg.clone()))),
            crate::blr::DepEvent::GenId { name: g } => {
                // a system generator is dropped (MET_store_dependency: sysGen)
                if let Some((_, sys, _)) = find_generator(file, page_size, g) {
                    if sys == 0 {
                        deps.push((g.clone(), 14, None));
                    }
                }
            }
            crate::blr::DepEvent::Exception { name: e } => deps.push((e.clone(), 7, None)),
            crate::blr::DepEvent::Function { name: f } => deps.push((f.clone(), 15, None)),
            crate::blr::DepEvent::Domain { name: d } => deps.push((d.clone(), 9, None)),
            crate::blr::DepEvent::RelField { relation: r, field: f } => {
                deps.push((r.clone(), rel_type(file, r), Some(f.clone())));
            }
            crate::blr::DepEvent::Collation { ttype } => {
                if let Some(coll) = collation_name(file, page_size, *ttype) {
                    deps.push((coll, 17, None));
                }
            }
        }
    }
    // a view's columns: the base field each names, on the relation of its
    // context (RSR_base_field -> PAR_make_field -> PAR_dependency)
    if kind == 1 {
        let vrel_of_ctx: Vec<(i64, String)> = view_context_relations(file, page_size, name);
        for (vctx, base) in view_base_fields(file, page_size, name) {
            if let Some((_, r)) = vrel_of_ctx.iter().find(|(c, _)| *c == vctx) {
                deps.push((r.clone(), rel_type(file, r), Some(base)));
            }
        }
    }
    // dedupe on (name, type, field), keeping the FIRST encounter - then
    // the engine's pop order
    let mut seen: Vec<(String, i64, Option<String>)> = Vec::new();
    for d in deps {
        if !seen.contains(&d) {
            seen.push(d);
        }
    }
    seen.reverse();

    // MET_delete_dependencies for (name, kind)
    if crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES").is_some() {
        let dn_f = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_NAME")?;
        let dt_f = sys_fid(file, page_size, "RDB$DEPENDENCIES", "RDB$DEPENDENT_TYPE")?;
        let want = name.to_string();
        delete_catalog_rows(file, page_size, "RDB$DEPENDENCIES", move |v| text_eq(v.get(dn_f), &want) && int_eq(v.get(dt_f), kind))?;
    }
    let drel = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES").ok_or("no RDB$DEPENDENCIES relation")?;
    for (on, otype, field) in &seen {
        // the depended-on object's schema: a relation's own (a system
        // relation lives in SYSTEM), PUBLIC for everything else here
        let on_schema = if *otype == 0 || *otype == 1 {
            sys_text_of(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME", on, "RDB$SCHEMA_NAME").unwrap_or_else(|| "PUBLIC".into())
        } else {
            "PUBLIC".to_string()
        };
        let mut row: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$DEPENDENT_NAME", SysVal::S(name)),
            ("RDB$DEPENDED_ON_NAME", SysVal::S(on)),
            ("RDB$DEPENDENT_TYPE", SysVal::I(kind)),
            ("RDB$DEPENDED_ON_TYPE", SysVal::I(*otype)),
            ("RDB$DEPENDENT_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$DEPENDED_ON_SCHEMA_NAME", SysVal::S(&on_schema)),
        ];
        if let Some(f) = field {
            row.push(("RDB$FIELD_NAME", SysVal::S(f)));
        }
        sys_insert(file, page_size, "RDB$DEPENDENCIES", drel, &row)?;
    }
    Ok(())
}

/// A procedure's parameter name by (RDB$PARAMETER_TYPE, RDB$PARAMETER_NUMBER).
fn procedure_param_name(file: &crate::Image, page_size: usize, proc: &str, ptype: i64, number: i64) -> Option<String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$PROCEDURE_PARAMETERS")?;
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURE_PARAMETERS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$PROCEDURE_PARAMETERS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (p_f, n_f, t_f, num_f) = (fid("RDB$PROCEDURE_NAME")?, fid("RDB$PARAMETER_NAME")?, fid("RDB$PARAMETER_TYPE")?, fid("RDB$PARAMETER_NUMBER")?);
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(p_f), proc) && int_eq(v.get(t_f), ptype) && int_eq(v.get(num_f), number) {
            if let Some(Value::Text(t)) = v.get(n_f) {
                out = Some(t.trim_end().to_string());
            }
        }
    });
    out
}

/// A collation's name from a text type (charset id | collation id << 8).
fn collation_name(file: &crate::Image, page_size: usize, ttype: u16) -> Option<String> {
    let (cs, coll) = ((ttype & 0xff) as i64, (ttype >> 8) as i64);
    let rel = crate::resolve_relation(file, page_size, "RDB$COLLATIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$COLLATIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$COLLATIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (n_f, cs_f, id_f) = (fid("RDB$COLLATION_NAME")?, fid("RDB$CHARACTER_SET_ID")?, fid("RDB$COLLATION_ID")?);
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && int_eq(v.get(cs_f), cs) && int_eq(v.get(id_f), coll) {
            if let Some(Value::Text(t)) = v.get(n_f) {
                out = Some(t.trim_end().to_string());
            }
        }
    });
    out
}

/// A view's (context, base relation) pairs from RDB$VIEW_RELATIONS.
fn view_context_relations(file: &crate::Image, page_size: usize, view: &str) -> Vec<(i64, String)> {
    let mut out = Vec::new();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$VIEW_RELATIONS"),
        system_relation_formats(file, page_size, "RDB$VIEW_RELATIONS"),
    ) else {
        return out;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else { return out };
    let cols = relation_columns(file, page_size, "RDB$VIEW_RELATIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(v_f), Some(r_f), Some(c_f)) = (fid("RDB$VIEW_NAME"), fid("RDB$RELATION_NAME"), fid("RDB$VIEW_CONTEXT")) else {
        return out;
    };
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(v_f), view) {
            if let (Some(Value::Text(r)), Some(Value::Int(c))) = (v.get(r_f), v.get(c_f)) {
                out.push((*c, r.trim_end().to_string()));
            }
        }
    });
    out
}

/// A view's (context, base field) pairs from its RDB$RELATION_FIELDS rows.
fn view_base_fields(file: &crate::Image, page_size: usize, view: &str) -> Vec<(i64, String)> {
    let mut out = Vec::new();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$RELATION_FIELDS"),
        system_relation_formats(file, page_size, "RDB$RELATION_FIELDS"),
    ) else {
        return out;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else { return out };
    let cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(r_f), Some(b_f), Some(c_f)) = (fid("RDB$RELATION_NAME"), fid("RDB$BASE_FIELD"), fid("RDB$VIEW_CONTEXT")) else {
        return out;
    };
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(r_f), view) {
            if let (Some(Value::Text(b)), Some(Value::Int(c))) = (v.get(b_f), v.get(c_f)) {
                let b = b.trim_end();
                if !b.is_empty() {
                    out.push((*c, b.to_string()));
                }
            }
        }
    });
    out
}

/// Whether a matching `RDB$USER_PRIVILEGES` row already exists - by
/// grantee, letter and field (`None` = the relation-level, NULL-field
/// row) - so a re-`GRANT` does not duplicate it.
fn priv_row_present(
    file: &crate::Image,
    page_size: usize,
    table: &str,
    grantee: &str,
    letter: char,
    field: Option<&str>,
) -> bool {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(u_f), Some(p_f), Some(rn_f), Some(fn_f)) = (
        fid("RDB$USER"),
        fid("RDB$PRIVILEGE"),
        fid("RDB$RELATION_NAME"),
        fid("RDB$FIELD_NAME"),
    ) else {
        return false;
    };
    let letter = letter.to_string();
    let mut present = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_is(v.get(rn_f), table)
            && text_eq(v.get(u_f), grantee)
            && text_eq(v.get(p_f), &letter)
            && match field {
                Some(f) => text_is(v.get(fn_f), f),
                None => matches!(v.get(fn_f), None | Some(Value::Null)),
            }
        {
            present = true;
        }
    });
    present
}

/// `GRANT <privileges> [(<fields>)] ON [TABLE] <table> TO <grantees>
/// [WITH GRANT OPTION]` and its `REVOKE ... FROM` inverse - `GrantRevokeNode`
/// against the file image. Two effects, the engine's order: the
/// fine-grained rows of `RDB$USER_PRIVILEGES` (one per grantee per
/// privilege per field), and a recompute of the relation's security-class
/// ACLs ([recompute_relation_acl]).
///
/// With no `fields`, a relation-level grant, exactly as before. With
/// `fields`, a column grant: the same privilege letters carry a
/// `RDB$FIELD_NAME`, each granted column gets its own `SQL$GRANT<n>`
/// security class, and the recompute folds the field grantees into the
/// relation's own ACL too (see [recompute_acls]).
///
/// A grantee is any name (`PUBLIC` included, an ordinary `RDB$USER` row);
/// it need not exist. `GRANT` inserts a missing row (a re-grant is a
/// no-op); `REVOKE` deletes the matching rows, silently where there is
/// nothing to remove.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub fn grant_table(
    file: &mut crate::Image,
    page_size: usize,
    table: &str,
    grantees: &[String],
    privileges: &[char],
    fields: &[String],
    grant_option: bool,
    revoke: bool,
    option_only: bool,
) -> Result<(), String> {
    let table = table.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, &table)
        .ok_or_else(|| format!("Table \"{}\" not found", table))?;
    if rel < 128 {
        return Err("system relations are read-only".into());
    }
    let upriv = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    // a column grant validates its fields exist
    let field_list: Vec<String> = fields
        .iter()
        .map(|f| f.trim().to_string())
        .collect();
    if !field_list.is_empty() {
        let have = relation_columns(file, page_size, &table);
        for f in &field_list {
            if !have.iter().any(|c| c.name == *f) {
                return Err(format!("column {} does not exist in table/view \"{}\"", f, table));
            }
        }
    }
    // the field slots to write: one None for a relation grant, or one per column
    let slots: Vec<Option<&str>> = if field_list.is_empty() {
        vec![None]
    } else {
        field_list.iter().map(|f| Some(f.as_str())).collect()
    };

    for grantee in grantees {
        let grantee = grantee.trim().trim_matches('"').to_ascii_uppercase();
        for &letter in privileges {
            for &field in &slots {
                if revoke {
                    let (g, t, l) = (grantee.clone(), table.clone(), letter.to_string());
                    let want_field = field.map(|f| f.to_string());
                    let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
                    let u_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$USER")?;
                    let p_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$PRIVILEGE")?;
                    let fn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$FIELD_NAME")?;
                    let matches_row = move |v: &[Value]| {
                        text_is(v.get(rn_f), &t)
                            && text_eq(v.get(u_f), &g)
                            && text_eq(v.get(p_f), &l)
                            && match &want_field {
                                Some(f) => text_is(v.get(fn_f), f),
                                None => matches!(v.get(fn_f), None | Some(Value::Null)),
                            }
                    };
                    if option_only {
                        // REVOKE GRANT OPTION FOR: keep the privilege, clear
                        // its grant option (the ACL does not carry it, so it
                        // is not recomputed)
                        patch_sys_row(
                            file,
                            page_size,
                            "RDB$USER_PRIVILEGES",
                            upriv,
                            matches_row,
                            &[("RDB$GRANT_OPTION", SysVal::I(0))],
                        )?;
                    } else {
                        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", matches_row)?;
                    }
                } else if !priv_row_present(file, page_size, &table, &grantee, letter, field) {
                    let letter = letter.to_string();
                    let mut row = vec![
                        ("RDB$USER", SysVal::S(&grantee)),
                        ("RDB$GRANTOR", SysVal::S(OWNER)),
                        ("RDB$PRIVILEGE", SysVal::S(&letter)),
                        ("RDB$GRANT_OPTION", SysVal::I(if grant_option { 1 } else { 0 })),
                        ("RDB$RELATION_NAME", SysVal::S(&table)),
                        ("RDB$USER_TYPE", SysVal::I(8)),
                        ("RDB$OBJECT_TYPE", SysVal::I(0)),
                        ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
                    ];
                    if let Some(f) = field {
                        row.push(("RDB$FIELD_NAME", SysVal::S(f)));
                    }
                    sys_insert(file, page_size, "RDB$USER_PRIVILEGES", upriv, &row)?;
                }
            }
        }
    }
    // REVOKE GRANT OPTION FOR touches only RDB$GRANT_OPTION, which the ACL
    // does not encode - so the ACL is left as it stands
    if !option_only {
        recompute_relation_acl(file, page_size, &table)?;
    }
    advance_oldest_transactions(file, page_size)
}

/// A procedure's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$PROCEDURES`.
fn procedure_owner_class(file: &crate::Image, page_size: usize, proc: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")?;
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$PROCEDURE_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), proc) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// A non-relation object's (procedure, function, sequence) security-class ACL
/// from the grants now in `RDB$USER_PRIVILEGES`: the owner ACE (`owner_mask`),
/// then every other grantee with `grantee_flag`, alphabetically, with `PUBLIC`
/// (the all-users wildcard) last - the relation ordering. `object_type` and
/// `priv_letter` select the object's rows (procedure 5/`X`, function 15/`X`,
/// sequence 14/`G`).
fn build_object_acl(
    file: &crate::Image,
    page_size: usize,
    name: &str,
    object_type: i64,
    priv_letter: &str,
    owner: &str,
    owner_mask: u32,
    grantee_flag: u32,
) -> Vec<u8> {
    use std::collections::BTreeSet;
    let mut named: BTreeSet<String> = BTreeSet::new();
    let mut has_public = false;
    if let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) {
        if let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) {
            let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
            let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            if let (Some(u_f), Some(rn_f), Some(p_f), Some(ot_f)) = (
                fid("RDB$USER"),
                fid("RDB$RELATION_NAME"),
                fid("RDB$PRIVILEGE"),
                fid("RDB$OBJECT_TYPE"),
            ) {
                walk_rows(file, page_size, rel, descs, |v| {
                    if text_is(v.get(rn_f), name)
                        && text_eq(v.get(p_f), priv_letter)
                        && matches!(v.get(ot_f), Some(Value::Int(t)) if *t == object_type)
                    {
                        if let Some(Value::Text(u)) = v.get(u_f) {
                            let u = u.trim_end();
                            if u.eq_ignore_ascii_case(owner) {
                                // the owner's implicit full-privilege ACE
                            } else if u.eq_ignore_ascii_case("PUBLIC") {
                                has_public = true;
                            } else {
                                named.insert(u.to_string());
                            }
                        }
                    }
                });
            }
        }
    }
    let mut acl: AclList = vec![(Some(owner.to_string()), owner_mask)];
    for u in named {
        acl_grant_user(&mut acl, Some(u), grantee_flag);
    }
    if has_public {
        acl_grant_user(&mut acl, None, grantee_flag);
    }
    acl_serialize(&acl)
}

/// A function's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$FUNCTIONS`
/// (the packaged-function rows carry a package name; a standalone function's
/// `RDB$PACKAGE_NAME` is NULL, which is the one this grants on).
fn function_owner_class(file: &crate::Image, page_size: usize, func: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FUNCTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FUNCTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FUNCTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$FUNCTION_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let pkg_f = fid("RDB$PACKAGE_NAME");
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        let standalone = pkg_f.map_or(true, |f| matches!(v.get(f), None | Some(Value::Null)));
        if out.is_none() && standalone && text_eq(v.get(name_f), func) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// The shared core of a `GRANT` on a non-relation object (procedure,
/// function, sequence): write (or delete) the `RDB$USER_PRIVILEGES` rows for
/// the object (`priv_letter`/`object_type`), then recompute its security-class
/// ACL from `owner_mask` and `grantee_flag`. The procedure/function/sequence
/// analogue of [grant_table].
#[allow(clippy::too_many_arguments)]
fn grant_object(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    object_type: i64,
    priv_letter: &str,
    owner: &str,
    class: &str,
    owner_mask: u32,
    grantee_flag: u32,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let upriv = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    let letter = priv_letter.chars().next().unwrap_or('X');
    for grantee in grantees {
        let grantee = grantee.trim().trim_matches('"').to_ascii_uppercase();
        if revoke {
            let (g, p, pl) = (grantee.clone(), name.to_string(), priv_letter.to_string());
            let u_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$USER")?;
            let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
            let pr_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$PRIVILEGE")?;
            let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
            delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
                text_eq(v.get(u_f), &g)
                    && text_eq(v.get(rn_f), &p)
                    && text_eq(v.get(pr_f), &pl)
                    && matches!(v.get(ot_f), Some(Value::Int(t)) if *t == object_type)
            })?;
        } else if !priv_row_present(file, page_size, name, &grantee, letter, None) {
            let row = vec![
                ("RDB$USER", SysVal::S(&grantee)),
                ("RDB$GRANTOR", SysVal::S(owner)),
                ("RDB$PRIVILEGE", SysVal::S(priv_letter)),
                ("RDB$GRANT_OPTION", SysVal::I(if grant_option { 1 } else { 0 })),
                ("RDB$RELATION_NAME", SysVal::S(name)),
                ("RDB$USER_TYPE", SysVal::I(8)),
                ("RDB$OBJECT_TYPE", SysVal::I(object_type)),
                ("RDB$RELATION_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ];
            sys_insert(file, page_size, "RDB$USER_PRIVILEGES", upriv, &row)?;
        }
    }
    let acl = build_object_acl(
        file,
        page_size,
        name,
        object_type,
        priv_letter,
        owner,
        owner_mask,
        grantee_flag,
    );
    write_class_acl(file, page_size, class, &acl)?;
    advance_oldest_transactions(file, page_size)
}

/// `GRANT EXECUTE ON PROCEDURE <p> TO <grantees> [WITH GRANT OPTION]` and its
/// `REVOKE ... FROM` inverse (object type 5, privilege `X`).
pub fn grant_procedure(
    file: &mut crate::Image,
    page_size: usize,
    proc: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let proc = proc.trim().trim_matches('"').to_ascii_uppercase();
    let (owner, class) = procedure_owner_class(file, page_size, &proc)
        .ok_or_else(|| format!("Procedure {} not found", proc))?;
    grant_object(
        file, page_size, &proc, 5, "X", &owner, &class, OWNER_PROCEDURE_PRIVS, SCL_EXECUTE,
        grantees, grant_option, revoke,
    )
}

/// `GRANT EXECUTE ON FUNCTION <f> TO <grantees> [WITH GRANT OPTION]` and its
/// `REVOKE ... FROM` inverse (object type 15, privilege `X`).
pub fn grant_function(
    file: &mut crate::Image,
    page_size: usize,
    func: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let func = func.trim().trim_matches('"').to_ascii_uppercase();
    let (owner, class) = function_owner_class(file, page_size, &func)
        .ok_or_else(|| format!("Function {} not found", func))?;
    grant_object(
        file, page_size, &func, 15, "X", &owner, &class, OWNER_PROCEDURE_PRIVS, SCL_EXECUTE,
        grantees, grant_option, revoke,
    )
}

/// A sequence's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$GENERATORS`.
fn generator_owner_class(file: &crate::Image, page_size: usize, seq: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$GENERATORS")?;
    let formats = system_relation_formats(file, page_size, "RDB$GENERATORS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$GENERATORS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$GENERATOR_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), seq) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// `GRANT USAGE ON SEQUENCE|GENERATOR <s> TO <grantees> [WITH GRANT OPTION]`
/// and its `REVOKE ... FROM` inverse (object type 14, privilege `G`). The
/// owner ACE is alter/control/drop/usage; a grantee gets usage.
pub fn grant_sequence(
    file: &mut crate::Image,
    page_size: usize,
    seq: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let seq = seq.trim().trim_matches('"').to_ascii_uppercase();
    let (_, system, _) = find_generator(file, page_size, &seq)
        .ok_or_else(|| format!("Sequence {} not found", seq))?;
    if system != 0 {
        return Err("system generators are read-only".into());
    }
    let (owner, class) = generator_owner_class(file, page_size, &seq)
        .ok_or_else(|| format!("Sequence {} has no security class", seq))?;
    grant_object(
        file, page_size, &seq, 14, "G", &owner, &class, OWNER_USAGE_PRIVS, SCL_USAGE,
        grantees, grant_option, revoke,
    )
}

/// An exception's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$EXCEPTIONS`.
fn exception_owner_class(file: &crate::Image, page_size: usize, exc: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$EXCEPTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$EXCEPTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$EXCEPTION_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), exc) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// `GRANT USAGE ON EXCEPTION <e> TO <grantees> [WITH GRANT OPTION]` and its
/// `REVOKE ... FROM` inverse (object type 7, privilege `G`).
pub fn grant_exception(
    file: &mut crate::Image,
    page_size: usize,
    exc: &str,
    grantees: &[String],
    grant_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let exc = exc.trim().trim_matches('"').to_ascii_uppercase();
    if find_exception(file, page_size, &exc).is_none() {
        return Err(format!("Exception {} not found", exc));
    }
    let (owner, class) = exception_owner_class(file, page_size, &exc)
        .ok_or_else(|| format!("Exception {} has no security class", exc))?;
    grant_object(
        file, page_size, &exc, 7, "G", &owner, &class, OWNER_USAGE_PRIVS, SCL_USAGE,
        grantees, grant_option, revoke,
    )
}

/// A role's `(RDB$OWNER_NAME, RDB$SECURITY_CLASS)` from `RDB$ROLES`.
fn role_owner_class(file: &crate::Image, page_size: usize, role: &str) -> Option<(String, String)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$ROLES")?;
    let formats = system_relation_formats(file, page_size, "RDB$ROLES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$ROLES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, own_f, sc_f) = (
        fid("RDB$ROLE_NAME")?,
        fid("RDB$OWNER_NAME")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), role) {
            let own = match v.get(own_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => OWNER.to_string(),
            };
            let sc = match v.get(sc_f) {
                Some(Value::Text(t)) => t.trim_end().to_string(),
                _ => return,
            };
            out = Some((own, sc));
        }
    });
    out
}

/// Whether a user already holds membership of a role (an `M` /
/// object-type-13 row in `RDB$USER_PRIVILEGES`).
fn role_member_present(file: &crate::Image, page_size: usize, role: &str, grantee: &str) -> bool {
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(u_f), Some(rn_f), Some(p_f), Some(ot_f)) = (
        fid("RDB$USER"),
        fid("RDB$RELATION_NAME"),
        fid("RDB$PRIVILEGE"),
        fid("RDB$OBJECT_TYPE"),
    ) else {
        return false;
    };
    let mut present = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(rn_f), role)
            && text_eq(v.get(u_f), grantee)
            && text_eq(v.get(p_f), "M")
            && int_eq(v.get(ot_f), 13)
        {
            present = true;
        }
    });
    present
}

/// Recompute a role's own security-class ACL: the owner (alter, control,
/// drop), then each member holding the role `WITH ADMIN OPTION`
/// (grant_option = 2) alphabetically, with the `drop` privilege the engine
/// gives an admin member (grant.epp maps a role membership to `"O"` =
/// drop). A member without the admin option is not in the ACL.
fn recompute_role_acl(file: &mut crate::Image, page_size: usize, role: &str) -> Result<(), String> {
    use std::collections::BTreeSet;
    let (owner, class) = role_owner_class(file, page_size, role)
        .ok_or_else(|| format!("role {} has no security class", role))?;
    let mut admins: BTreeSet<String> = BTreeSet::new();
    if let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES"),
        system_relation_formats(file, page_size, "RDB$USER_PRIVILEGES"),
    ) {
        if let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) {
            let cols = relation_columns(file, page_size, "RDB$USER_PRIVILEGES");
            let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
            if let (Some(u_f), Some(rn_f), Some(p_f), Some(ot_f), Some(go_f)) = (
                fid("RDB$USER"),
                fid("RDB$RELATION_NAME"),
                fid("RDB$PRIVILEGE"),
                fid("RDB$OBJECT_TYPE"),
                fid("RDB$GRANT_OPTION"),
            ) {
                walk_rows(file, page_size, rel, descs, |v| {
                    if text_eq(v.get(rn_f), role)
                        && text_eq(v.get(p_f), "M")
                        && int_eq(v.get(ot_f), 13)
                        && int_eq(v.get(go_f), 2)
                    {
                        if let Some(Value::Text(t)) = v.get(u_f) {
                            let u = t.trim_end().to_string();
                            if !u.eq_ignore_ascii_case(&owner) {
                                admins.insert(u);
                            }
                        }
                    }
                });
            }
        }
    }
    let mut acl: AclList = vec![(Some(owner), SCL_ALTER | SCL_CONTROL | SCL_DROP)];
    for user in &admins {
        acl.push((Some(user.clone()), SCL_DROP));
    }
    write_class_acl(file, page_size, &class, &acl_serialize(&acl))
}

/// `GRANT <role> TO <grantees> [WITH ADMIN OPTION]` and its `REVOKE ...
/// FROM` inverse - role membership, `GrantRevokeNode` for `obj_sql_role`.
/// A membership is a `RDB$USER_PRIVILEGES` row: privilege `M`, object type
/// 13 (`obj_sql_role`), the role in `RDB$RELATION_NAME`, no schema, and
/// `RDB$GRANT_OPTION` = 2 for `WITH ADMIN OPTION` (not 1). Granting a role
/// recomputes the role's ACL - every admin-option member gets a `drop`
/// ACE. Unlike a table grant, the role must exist.
pub fn grant_role(
    file: &mut crate::Image,
    page_size: usize,
    role: &str,
    grantees: &[String],
    admin_option: bool,
    revoke: bool,
) -> Result<(), String> {
    let role = role.trim().trim_matches('"').to_ascii_uppercase();
    if find_role(file, page_size, &role).is_none() {
        return Err(format!("SQL role \"{}\" does not exist", role));
    }
    let upriv = crate::resolve_relation(file, page_size, "RDB$USER_PRIVILEGES")
        .ok_or("no RDB$USER_PRIVILEGES relation")?;
    for grantee in grantees {
        let grantee = grantee.trim().trim_matches('"').to_ascii_uppercase();
        if revoke {
            let (g, r) = (grantee.clone(), role.clone());
            let rn_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
            let u_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$USER")?;
            let p_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$PRIVILEGE")?;
            let ot_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
            delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
                text_eq(v.get(rn_f), &r)
                    && text_eq(v.get(u_f), &g)
                    && text_eq(v.get(p_f), "M")
                    && int_eq(v.get(ot_f), 13)
            })?;
        } else if !role_member_present(file, page_size, &role, &grantee) {
            sys_insert(
                file,
                page_size,
                "RDB$USER_PRIVILEGES",
                upriv,
                &[
                    ("RDB$USER", SysVal::S(&grantee)),
                    ("RDB$GRANTOR", SysVal::S(OWNER)),
                    ("RDB$PRIVILEGE", SysVal::S("M")),
                    ("RDB$GRANT_OPTION", SysVal::I(if admin_option { 2 } else { 0 })),
                    ("RDB$RELATION_NAME", SysVal::S(&role)),
                    ("RDB$USER_TYPE", SysVal::I(8)),
                    ("RDB$OBJECT_TYPE", SysVal::I(13)),
                ],
            )?;
        }
    }
    recompute_role_acl(file, page_size, &role)?;
    advance_oldest_transactions(file, page_size)
}

/// Take the next `SQL$<n>` security class name from generator slot 1
/// (`RDB$SECURITY_CLASS`) and store its row with the owner's ACL. The
/// engine draws this name from the counter WITHOUT checking whether it
/// is free - unlike the generated INTEG_/RDB$ names, which skip what is
/// taken - and `RDB$SECURITY_CLASSES` has a unique index on the column
/// (RDB$INDEX_7). A writer that invented a name here without advancing
/// the counter would hand the engine a duplicate-key error on its next
/// DDL.
fn next_security_class(
    file: &mut crate::Image,
    page_size: usize,
    privileges: &[u8],
) -> Result<String, String> {
    let class = format!(
        "SQL${}",
        gen::bump(file, page_size, gen::SECURITY_CLASS, 1)?
    );
    store_security_class(file, page_size, &class, OWNER, privileges)?;
    Ok(class)
}

/// The same for a relation's `RDB$DEFAULT_CLASS`, whose `SQL$DEFAULT<n>`
/// names come from their own counter - generator slot 2, the system
/// generator actually named `SQL$DEFAULT`. It carries the same ACL as
/// the relation's own class.
fn next_default_class(file: &mut crate::Image, page_size: usize) -> Result<String, String> {
    let id = generator_id_by_name(file, page_size, "SQL$DEFAULT")
        .ok_or("no SQL$DEFAULT generator")?;
    let class = format!("SQL$DEFAULT{}", gen::bump(file, page_size, id, 1)?);
    store_security_class(file, page_size, &class, OWNER, ACL_TABLE_OWNER)?;
    Ok(class)
}

/// A system generator's id by name - the counters the DDL draws names
/// from live in `RDB$GENERATORS` like any other.
fn generator_id_by_name(file: &crate::Image, page_size: usize, name: &str) -> Option<i64> {
    find_generator(file, page_size, name).map(|(id, _, _)| id)
}

/// `DROP SEQUENCE|GENERATOR <name>` - `DropSequenceNode::execute`
/// (DdlNodes.epp:6665). The catalog rows go: the `RDB$GENERATORS` row,
/// its security class, and the privileges granted on it. A system
/// generator is refused ("Cannot delete system generator").
///
/// What does NOT happen is as instructive: the generator's VALUE stays
/// in the vector. Nothing zeroes the slot and nothing reclaims the id -
/// `delete_generator` (dfw.epp:2173) only checks dependencies - so a
/// dropped sequence leaves its last value behind as garbage, and the
/// next `CREATE SEQUENCE` takes a fresh id from the master generator
/// rather than reusing the hole.
pub fn drop_sequence(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (_, system, class) = find_generator(file, page_size, &want)
        .ok_or_else(|| format!("generator {} is not defined", want))?;
    if system != 0 {
        return Err(format!("Cannot delete system generator {}", want));
    }
    let name_f = sys_fid(file, page_size, "RDB$GENERATORS", "RDB$GENERATOR_NAME")?;
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$GENERATORS", move |v| {
            text_eq(v.get(name_f), &want)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    {
        // by name AND object type: a table may share the name (the
        // generator namespace is its own)
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
            text_eq(v.get(rel_f), &want) && int_eq(v.get(obj_f), 14)
        })?;
    }
    advance_oldest_transactions(file, page_size)?;
    Ok(())
}

/// An exception's `(RDB$EXCEPTION_NUMBER, RDB$SYSTEM_FLAG,
/// RDB$SECURITY_CLASS)` from `RDB$EXCEPTIONS`, by name. None when there is
/// no such exception.
fn find_exception(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Option<(i64, i64, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$EXCEPTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$EXCEPTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, num_f, sys_f, cls_f) = (
        fid("RDB$EXCEPTION_NAME")?,
        fid("RDB$EXCEPTION_NUMBER")?,
        fid("RDB$SYSTEM_FLAG")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_some() || !text_eq(v.get(name_f), name) {
            return;
        }
        let number = match v.get(num_f) {
            Some(Value::Int(i)) => *i,
            _ => return,
        };
        let sys = match v.get(sys_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        let class = match v.get(cls_f) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        found = Some((number, sys, class));
    });
    found
}

/// `DROP PROCEDURE <name>` - the inverse of [create_procedure]: the
/// RDB$PROCEDURES row, its RDB$PROCEDURE_PARAMETERS rows, each
/// parameter's invented RDB$n domain (RDB$FIELDS), the security class
/// and the owner's grant. Refuses a name that is not there, and - the
/// fail-closed part - a procedure any RDB$DEPENDENCIES row still names
/// as depended-on (the engine's "there are N dependencies"; fire-crab
/// only writes those rows for the dependencies it tracks, so a
/// body-to-body call it never recorded cannot be caught here, a
/// recorded boundary).
/// A procedure's RDB$PROCEDURE_ID, if it exists.
pub fn procedure_id(file: &crate::Image, page_size: usize, name: &str) -> Option<i64> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")?;
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f) = (fid("RDB$PROCEDURE_NAME")?, fid("RDB$PROCEDURE_ID")?);
    // a PLAIN procedure only: a packaged member shares the bare name but
    // carries a Text RDB$PACKAGE_NAME (the plain one is NULL), and ALTER /
    // CREATE OR ALTER PROCEDURE must never pick or drop the member's id
    let pk_f = fid("RDB$PACKAGE_NAME");
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        let plain = !matches!(pk_f.and_then(|f| v.get(f)), Some(Value::Text(_)));
        if out.is_none() && plain && text_eq(v.get(name_f), &want) {
            if let Some(Value::Int(i)) = v.get(id_f) {
                out = Some(*i);
            }
        }
    });
    out
}

/// The RDB$PROCEDURE_ID of a PACKAGED member - matched on name AND
/// package, so a packaged `PKG.PP` is not confused with a same-named
/// plain procedure (whose id create_package_body would otherwise reuse,
/// colliding on the RDB$PROCEDURE_ID unique index). Mirrors function_id.
fn procedure_id_in_package(file: &crate::Image, page_size: usize, name: &str, package: &str) -> Option<i64> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")?;
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f, pk_f) = (fid("RDB$PROCEDURE_NAME")?, fid("RDB$PROCEDURE_ID")?, fid("RDB$PACKAGE_NAME")?);
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), &want) && text_eq(v.get(pk_f), package) {
            if let Some(Value::Int(i)) = v.get(id_f) {
                out = Some(*i);
            }
        }
    });
    out
}

pub fn drop_procedure(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    // the row, and its parameter domains, gathered before anything is
    // deleted
    let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES format")?;
    let (_, pdescs) = formats.iter().max_by_key(|(n, _)| *n).ok_or("no format")?;
    let prel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES relation")?;
    let pcols = relation_columns(file, page_size, "RDB$PROCEDURES");
    let pname_f = pcols
        .iter()
        .find(|c| c.name == "RDB$PROCEDURE_NAME")
        .map(|c| c.field_id as usize)
        .ok_or("no RDB$PROCEDURE_NAME")?;
    let pcls_f = pcols
        .iter()
        .find(|c| c.name == "RDB$SECURITY_CLASS")
        .map(|c| c.field_id as usize);
    // a packaged member shares the bare RDB$PROCEDURE_NAME; its
    // RDB$PACKAGE_NAME is Text where the plain procedure's is NULL. DROP /
    // ALTER of a plain procedure must touch ONLY the plain rows, never the
    // member's (which belong to the package).
    let ppkg_f = pcols
        .iter()
        .find(|c| c.name == "RDB$PACKAGE_NAME")
        .map(|c| c.field_id as usize);
    let is_plain = move |v: &[crate::format::Value]| {
        !matches!(ppkg_f.and_then(|f| v.get(f)), Some(Value::Text(_)))
    };
    let mut found = false;
    let mut class: Option<String> = None;
    {
        let want = want.clone();
        walk_rows(file, page_size, prel, pdescs, |v| {
            if is_plain(v) && text_eq(v.get(pname_f), &want) {
                found = true;
                if let Some(cf) = pcls_f {
                    if let Some(Value::Text(t)) = v.get(cf) {
                        class = Some(t.trim_end().to_string());
                    }
                }
            }
        });
    }
    if !found {
        return Err(format!("Procedure {} not found", want));
    }
    // depended-on? refuse, as the engine does - for the dependencies
    // this server records
    if let Some(drel) = crate::resolve_relation(file, page_size, "RDB$DEPENDENCIES") {
        let dfmts = system_relation_formats(file, page_size, "RDB$DEPENDENCIES")
            .ok_or("no RDB$DEPENDENCIES format")?;
        let (_, ddescs) = dfmts.iter().max_by_key(|(n, _)| *n).ok_or("no format")?;
        let dcols = relation_columns(file, page_size, "RDB$DEPENDENCIES");
        let don_f = dcols
            .iter()
            .find(|c| c.name == "RDB$DEPENDED_ON_NAME")
            .map(|c| c.field_id as usize);
        if let Some(don_f) = don_f {
            let mut deps = 0usize;
            let want = want.clone();
            walk_rows(file, page_size, drel, ddescs, |v| {
                if text_eq(v.get(don_f), &want) {
                    deps += 1;
                }
            });
            if deps > 0 {
                return Err(format!(
                    "cannot delete PROCEDURE {} - there are {} dependencies",
                    want, deps
                ));
            }
        }
    }
    // the parameter domains, before the parameter rows go
    let mut domains: Vec<String> = Vec::new();
    {
        let pprel = crate::resolve_relation(file, page_size, "RDB$PROCEDURE_PARAMETERS")
            .ok_or("no RDB$PROCEDURE_PARAMETERS relation")?;
        let ppfmts = system_relation_formats(file, page_size, "RDB$PROCEDURE_PARAMETERS")
            .ok_or("no format")?;
        let (_, ppdescs) = ppfmts.iter().max_by_key(|(n, _)| *n).ok_or("no format")?;
        let ppcols = relation_columns(file, page_size, "RDB$PROCEDURE_PARAMETERS");
        let pp_name_f = ppcols
            .iter()
            .find(|c| c.name == "RDB$PROCEDURE_NAME")
            .map(|c| c.field_id as usize)
            .ok_or("no RDB$PROCEDURE_NAME")?;
        let pp_src_f = ppcols
            .iter()
            .find(|c| c.name == "RDB$FIELD_SOURCE")
            .map(|c| c.field_id as usize);
        let pp_pkg_f = ppcols
            .iter()
            .find(|c| c.name == "RDB$PACKAGE_NAME")
            .map(|c| c.field_id as usize);
        let want = want.clone();
        walk_rows(file, page_size, pprel, ppdescs, |v| {
            let plain = !matches!(pp_pkg_f.and_then(|f| v.get(f)), Some(Value::Text(_)));
            if plain && text_eq(v.get(pp_name_f), &want) {
                if let Some(sf) = pp_src_f {
                    if let Some(Value::Text(t)) = v.get(sf) {
                        domains.push(t.trim_end().to_string());
                    }
                }
            }
        });
    }
    // now delete: procedure row, parameter rows, each domain, class, grant
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$PROCEDURES", move |v| {
            text_eq(v.get(pname_f), &want)
                && !matches!(ppkg_f.and_then(|f| v.get(f)), Some(Value::Text(_)))
        })?;
    }
    {
        let pp_name_f = sys_fid(file, page_size, "RDB$PROCEDURE_PARAMETERS", "RDB$PROCEDURE_NAME")?;
        let pp_pkg_f = sys_fid(file, page_size, "RDB$PROCEDURE_PARAMETERS", "RDB$PACKAGE_NAME")?;
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$PROCEDURE_PARAMETERS", move |v| {
            text_eq(v.get(pp_name_f), &want)
                && !matches!(v.get(pp_pkg_f), Some(Value::Text(_)))
        })?;
    }
    let fname_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    for dom in domains {
        delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| {
            text_eq(v.get(fname_f), &dom)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
            text_eq(v.get(rel_f), &want) && int_eq(v.get(obj_f), 5)
        })?;
    }
    advance_oldest_transactions(file, page_size)
}

/// One parameter of a CREATE PROCEDURE, in the catalog's own terms.
#[derive(Clone, Debug, PartialEq)]
pub struct ProcParamDef {
    pub name: String,
    pub field_type: i16,
    pub length: u16,
    pub scale: i16,
    pub sub_type: i16,
    /// a parameter DEFAULT: (value BLR verbatim, `= 7` source text)
    pub default: Option<(Vec<u8>, String)>,
}

/// `CREATE PROCEDURE` - the catalog rows the engine writes, measured
/// off an engine-created pair (P0/P1): an RDB$PROCEDURES row whose id
/// comes from the RDB$PROCEDURES generator, whose SOURCE blob is the
/// body text from its first non-space byte and whose BLR blob is the
/// dsql crate's byte-for-byte compile; one invented RDB$n domain per
/// parameter (the same counter table columns draw from); and one
/// RDB$PROCEDURE_PARAMETERS row per parameter, FIELD_SOURCE naming the
/// domain, mechanism 0. PROCEDURE_TYPE is 1 when a SUSPEND makes it
/// selectable, 2 otherwise; VALID_BLR is 1 - the engine executes what
/// this stores.
#[allow(clippy::too_many_arguments)]
pub fn create_procedure(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    ins: &[ProcParamDef],
    outs: &[ProcParamDef],
    selectable: bool,
    source: &str,
    blr: &[u8],
    package: Option<(&str, i64)>,
) -> Result<(), String> {
    create_procedure_with_id(file, page_size, name, ins, outs, selectable, source, blr, package, None, false)
}

/// [create_procedure] keeping a given RDB$PROCEDURE_ID - what ALTER
/// PROCEDURE does (probed: the id survives the redefinition).
pub fn create_procedure_with_id(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    ins: &[ProcParamDef],
    outs: &[ProcParamDef],
    selectable: bool,
    source: &str,
    blr: &[u8],
    package: Option<(&str, i64)>,
    keep_id: Option<i64>,
    declaration: bool,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a procedure needs a name".into());
    }
    let prel = crate::resolve_relation(file, page_size, "RDB$PROCEDURES")
        .ok_or("no RDB$PROCEDURES relation")?;
    // already exists? refuse before any row lands
    {
        let formats = system_relation_formats(file, page_size, "RDB$PROCEDURES")
            .ok_or("no RDB$PROCEDURES format")?;
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("no RDB$PROCEDURES format")?;
        let cols = relation_columns(file, page_size, "RDB$PROCEDURES");
        let name_f = cols
            .iter()
            .find(|c| c.name == "RDB$PROCEDURE_NAME")
            .map(|c| c.field_id as usize)
            .ok_or("no RDB$PROCEDURE_NAME column")?;
        // the name clashes ONLY within the same namespace: a plain
        // procedure with a plain one, a packaged member with a member of
        // the SAME package. A packaged PKG.PP and a plain PP coexist, the
        // way the engine namespaces them (a pre-schema ODS has no package
        // column, so the old name-only rule stands there).
        let pkg_f = cols.iter().find(|c| c.name == "RDB$PACKAGE_NAME").map(|c| c.field_id as usize);
        let want_pkg = package.map(|(p, _)| p.trim().trim_matches('"').to_ascii_uppercase());
        let mut dup = false;
        walk_rows(file, page_size, prel, descs, |v| {
            if !text_eq(v.get(name_f), &want) {
                return;
            }
            let same_ns = match &want_pkg {
                None => pkg_f.map_or(true, |i| matches!(v.get(i), None | Some(Value::Null))),
                Some(pk) => pkg_f.is_some_and(|i| text_eq(v.get(i), pk)),
            };
            if same_ns {
                dup = true;
            }
        });
        if dup {
            return Err(format!("Procedure {} already exists", want));
        }
    }
    let id = match keep_id {
        Some(id) => id,
        None => {
            let slot = generator_id_by_name(file, page_size, "RDB$PROCEDURES")
                .ok_or("no RDB$PROCEDURES generator")?;
            gen::bump(file, page_size, slot, 1)?
        }
    };
    // a package MEMBER holds no security class of its own and gets no
    // grant - the PACKAGE is the privilege boundary (measured: the
    // member rows' RDB$SECURITY_CLASS is NULL and only the package
    // name appears in RDB$USER_PRIVILEGES)
    let class = match package {
        None => Some(next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?),
        Some(_) => None,
    };
    let mut pvals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$PROCEDURE_NAME", SysVal::S(&want)),
        ("RDB$PROCEDURE_ID", SysVal::I(id)),
        ("RDB$PROCEDURE_INPUTS", SysVal::I(ins.len() as i64)),
        ("RDB$PROCEDURE_OUTPUTS", SysVal::I(outs.len() as i64)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
    ];
    // a package-header DECLARATION carries no source, blr, type or valid
    // flag (the body fills them); a real procedure carries them all.
    if !declaration {
        let blr_blob = dml::insert_blob(file, page_size, prel, &[blr.to_vec()], 2)?;
        pvals.push(("RDB$PROCEDURE_BLR", SysVal::B(blob_id_bytes(prel, blr_blob))));
        pvals.push(("RDB$PROCEDURE_TYPE", SysVal::I(if selectable { 1 } else { 2 })));
        pvals.push(("RDB$VALID_BLR", SysVal::I(1)));
        // a PACKAGED member holds no source of its own (its text lives in
        // the package body source); a standalone procedure carries it.
        if package.is_none() {
            let src_blob = dml::insert_blob_cs(file, page_size, prel, &[source.as_bytes().to_vec()], 1, 4)?;
            pvals.push(("RDB$PROCEDURE_SOURCE", SysVal::B(blob_id_bytes(prel, src_blob))));
        }
    }
    if let Some(c) = &class {
        pvals.push(("RDB$SECURITY_CLASS", SysVal::S(c)));
    }
    if let Some((pk, pv)) = package {
        pvals.push(("RDB$PACKAGE_NAME", SysVal::S(pk)));
        pvals.push(("RDB$PRIVATE_FLAG", SysVal::I(pv)));
    }
    sys_insert(file, page_size, "RDB$PROCEDURES", prel, &pvals)?;
    // parameters: an invented domain each, then the parameter row
    let pprel = crate::resolve_relation(file, page_size, "RDB$PROCEDURE_PARAMETERS")
        .ok_or("no RDB$PROCEDURE_PARAMETERS relation")?;
    for (ptype, list) in [(0i64, ins), (1i64, outs)] {
        for (num, p) in list.iter().enumerate() {
            let domain_num = next_domain_number(file, page_size)?;
            let dom = format!("RDB${}", domain_num);
            let mut field_vals: Vec<(&str, SysVal<'_>)> = vec![
                ("RDB$FIELD_NAME", SysVal::S(&dom)),
                ("RDB$FIELD_TYPE", SysVal::I(p.field_type as i64)),
                ("RDB$FIELD_LENGTH", SysVal::I(p.length as i64)),
                ("RDB$FIELD_SCALE", SysVal::I(p.scale as i64)),
                ("RDB$SYSTEM_FLAG", SysVal::I(0)),
                ("RDB$OWNER_NAME", SysVal::S(OWNER)),
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ];
            if subtype_carried(p.field_type) {
                field_vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(p.sub_type as i64)));
            }
            // an exact-numeric parameter domain carries PRECISION 0 (an
            // engine-created INTEGER param row measured 0, not the 9 a
            // computed column gets) - a NULL here is what crashed the
            // engine's executor reading an fc-authored procedure
            if matches!(p.field_type, 7 | 8 | 16 | 26) {
                field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(0)));
            }
            if matches!(p.field_type, 14 | 37) {
                field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0)));
                field_vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(p.length as i64)));
            }
            let frel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
                .ok_or("no RDB$FIELDS relation")?;
            sys_insert(file, page_size, "RDB$FIELDS", frel, &field_vals)?;
            // RDB$FIELD_SOURCE_SCHEMA_NAME is LOAD-BEARING: the
            // engine's procedure loader resolves the param's domain
            // through it and SEGFAULTS on NULL (the FK-blocker lesson
            // again - a missing schema qualifier, found by full-row
            // diff against the engine's own restore)
            let mut prm_vals: Vec<(&str, SysVal<'_>)> = vec![
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
                ("RDB$PARAMETER_NAME", SysVal::S(&p.name)),
                ("RDB$PROCEDURE_NAME", SysVal::S(&want)),
                ("RDB$PARAMETER_NUMBER", SysVal::I(num as i64)),
                ("RDB$PARAMETER_TYPE", SysVal::I(ptype)),
                ("RDB$FIELD_SOURCE", SysVal::S(&dom)),
                ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
                ("RDB$PARAMETER_MECHANISM", SysVal::I(0)),
                ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ];
            if let Some((pk, _)) = package {
                prm_vals.push(("RDB$PACKAGE_NAME", SysVal::S(pk)));
            }
            let def_blobs = match &p.default {
                Some((blr, src)) => Some((
                    dml::insert_blob(file, page_size, pprel, &[blr.clone()], 2)?,
                    dml::insert_blob_cs(file, page_size, pprel, &[src.as_bytes().to_vec()], 1, 4)?,
                )),
                None => None,
            };
            if let Some((vb, sb)) = def_blobs {
                prm_vals.push(("RDB$DEFAULT_VALUE", SysVal::B(blob_id_bytes(pprel, vb))));
                prm_vals.push(("RDB$DEFAULT_SOURCE", SysVal::B(blob_id_bytes(pprel, sb))));
            }
            sys_insert(
                file,
                page_size,
                "RDB$PROCEDURE_PARAMETERS",
                pprel,
                &prm_vals,
            )?;
        }
    }
    // the owner's EXECUTE grant, object type 5 - unless the procedure
    // is a package member (the package holds the grant)
    if package.is_none() {
        store_privileges(file, page_size, &want, 5, &["X"])?;
    }
    advance_oldest_transactions(file, page_size)
}

/// Mint one carrier domain (`RDB$<n>`) with the given type facts and
/// return its name - the same rows create_procedure writes for its
/// params, factored for callers that bind by name (expression view
/// columns). The PRECISION-0 law applies.
pub fn mint_carrier_domain(
    file: &mut crate::Image,
    page_size: usize,
    field_type: i16,
    length: u16,
    scale: i16,
    sub_type: i16,
    computed_blr: Option<&[u8]>,
) -> Result<String, String> {
    let domain_num = next_domain_number(file, page_size)?;
    let dom = format!("RDB${}", domain_num);
    // an expression view column's domain IS the expression: the
    // carried BLR stores as RDB$COMPUTED_BLR, subtype 2 - without it
    // the engine answers "cannot access column" to the view (measured)
    let cb_blob = match computed_blr {
        Some(b) => {
            let frel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
                .ok_or("no RDB$FIELDS relation")?;
            Some(dml::insert_blob(file, page_size, frel, &[b.to_vec()], 2)?)
        }
        None => None,
    };
    let mut field_vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$FIELD_NAME", SysVal::S(&dom)),
        ("RDB$FIELD_TYPE", SysVal::I(field_type as i64)),
        ("RDB$FIELD_LENGTH", SysVal::I(length as i64)),
        ("RDB$FIELD_SCALE", SysVal::I(scale as i64)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if subtype_carried(field_type) {
        field_vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(sub_type as i64)));
    }
    if matches!(field_type, 7 | 8 | 16 | 26) {
        field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(0)));
    }
    if matches!(field_type, 14 | 37) {
        field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0)));
        field_vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(length as i64)));
    }
    let frel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
        .ok_or("no RDB$FIELDS relation")?;
    if let Some(cb) = cb_blob {
        field_vals.push(("RDB$COMPUTED_BLR", SysVal::B(blob_id_bytes(frel, cb))));
    }
    sys_insert(file, page_size, "RDB$FIELDS", frel, &field_vals)?;
    Ok(dom)
}

/// Store a carried domain CHECK: the engine's own validation BLR
/// (subtype 2) and its `CHECK (VALUE > 0)` source (subtype 1) onto the
/// domain's RDB$FIELDS row, verbatim - nothing is compiled here.
pub fn set_domain_validation(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    blr: &[u8],
    source: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
        .ok_or("no RDB$FIELDS relation")?;
    let blr_blob = dml::insert_blob(file, page_size, rel, &[blr.to_vec()], 2)?;
    let src_blob = dml::insert_blob_cs(file, page_size, rel, &[source.as_bytes().to_vec()], 1, 4)?;
    let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$FIELDS",
        rel,
        move |v| text_eq(v.get(name_f), &want),
        &[
            ("RDB$VALIDATION_BLR", SysVal::B(blob_id_bytes(rel, blr_blob))),
            ("RDB$VALIDATION_SOURCE", SysVal::B(blob_id_bytes(rel, src_blob))),
        ],
    )
}

/// Does the domain's `RDB$FIELDS` row carry a validation BLR? Public so
/// the wire's ALTER executor can answer "Only one constraint allowed
/// for a domain" BEFORE compiling the new check - the engine's refusal
/// order (an out-of-surface second check must still get the engine
/// vector, not a compile refusal).
pub fn domain_validation_present(file: &crate::Image, page_size: usize, name: &str) -> bool {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (Some(rel), Some(formats)) = (
        crate::resolve_relation(file, page_size, "RDB$FIELDS"),
        system_relation_formats(file, page_size, "RDB$FIELDS"),
    ) else {
        return false;
    };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else {
        return false;
    };
    let cols = relation_columns(file, page_size, "RDB$FIELDS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(name_f), Some(vblr_f)) = (fid("RDB$FIELD_NAME"), fid("RDB$VALIDATION_BLR")) else {
        return false;
    };
    let mut has = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(name_f), &want) && matches!(v.get(vblr_f), Some(Value::Blob(..))) {
            has = true;
        }
    });
    has
}

/// `ALTER DOMAIN <name> ADD [CONSTRAINT] CHECK (...)` (`check` carries
/// the compiled validation BLR + verbatim source) / `DROP CONSTRAINT`
/// (`check` is None). ADD refuses when a check already exists - the
/// engine's "Only one constraint allowed for a domain" (DdlNodes.epp
/// dyn 160); DROP nulls both validation columns and is a no-op when
/// none exists (measured). Existing rows are NOT re-scanned - the
/// engine posts no deferred work for a CHECK change (measured: a
/// violating row survives ADD CONSTRAINT). Every table using the
/// domain gets its runtime summary rebuilt, because the engine
/// enforces from the summary's RSR_validation_blr segment, not from
/// the domain's own row.
pub fn alter_domain_check(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    check: Option<(&[u8], &str)>,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.starts_with("RDB$") || want.starts_with("SQL$") {
        return Err("system domains are read-only".into());
    }
    if !domain_exists(file, page_size, &want) {
        return Err(format!("Domain {} not found", want));
    }
    match check {
        Some((blr, source)) => {
            // one constraint per domain - the ADD path's only refusal
            if domain_validation_present(file, page_size, &want) {
                return Err("Only one constraint allowed for a domain".into());
            }
            set_domain_validation(file, page_size, &want, blr, source)?;
        }
        None => {
            let name_f = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
            let nm = want.clone();
            patch_sys_row(
                file,
                page_size,
                "RDB$FIELDS",
                2,
                move |v| text_eq(v.get(name_f), &nm),
                &[
                    ("RDB$VALIDATION_BLR", SysVal::Null),
                    ("RDB$VALIDATION_SOURCE", SysVal::Null),
                ],
            )?;
        }
    }
    // the tables whose columns use the domain, for the summary rebuild
    let rf_formats = system_relation_formats(file, page_size, "RDB$RELATION_FIELDS")
        .ok_or("no RDB$RELATION_FIELDS format")?;
    let (_, rf_descs) = rf_formats
        .iter()
        .max_by_key(|(n, _)| *n)
        .ok_or("empty format")?;
    let rf_cols = relation_columns(file, page_size, "RDB$RELATION_FIELDS");
    let rf_fid = |n: &str| rf_cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let src_fid = rf_fid("RDB$FIELD_SOURCE").ok_or("no RDB$FIELD_SOURCE")?;
    let rel_fid = rf_fid("RDB$RELATION_NAME").ok_or("no RDB$RELATION_NAME")?;
    let mut tables: Vec<String> = Vec::new();
    walk_rows(file, page_size, 5, rf_descs, |v| {
        if !text_eq(v.get(src_fid), &want) {
            return;
        }
        if let Some(Value::Text(t)) = v.get(rel_fid) {
            let t = t.trim_end().to_string();
            if !tables.contains(&t) {
                tables.push(t);
            }
        }
    });
    for t in &tables {
        update_relation_runtime(file, page_size, t)?;
    }
    advance_oldest_transactions(file, page_size)
}

/// Store a COMMENT: write `text` as a subtype-1 blob into the
/// `RDB$DESCRIPTION` column of the catalog row matching every
/// `(column, value)` pair. The restore's generic description pass -
/// one helper, every commentable family.
pub fn set_catalog_description(
    file: &mut crate::Image,
    page_size: usize,
    rel_name: &str,
    matches: &[(&str, &str)],
    text: &str,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, rel_name)
        .ok_or_else(|| format!("no {} relation", rel_name))?;
    let fids: Vec<(usize, String)> = matches
        .iter()
        .map(|(col, val)| {
            sys_fid(file, page_size, rel_name, col).map(|f| (f, val.trim().to_ascii_uppercase()))
        })
        .collect::<Result<_, _>>()?;
    let blob = dml::insert_blob_cs(file, page_size, rel, &[text.as_bytes().to_vec()], 1, 4)?;
    patch_sys_row(
        file,
        page_size,
        rel_name,
        rel,
        move |v| fids.iter().all(|(f, want)| text_eq(v.get(*f), want)),
        &[("RDB$DESCRIPTION", SysVal::B(blob_id_bytes(rel, blob)))],
    )
}

/// One RDB$BACKUP_HISTORY row - the chain bookkeeping a level-0
/// nbackup writes into the MAIN database so a later incremental can
/// name the backup it extends. The id comes from the system's own
/// RDB$BACKUP_HISTORY generator; the timestamp stays NULL (a clock is
/// not a differential surface - the GUID is the chain key).
pub fn insert_backup_history(
    file: &mut crate::Image,
    page_size: usize,
    level: i64,
    guid_text: &str,
    scn: i64,
    file_name: &str,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$BACKUP_HISTORY")
        .ok_or("no RDB$BACKUP_HISTORY relation")?;
    let slot = generator_id_by_name(file, page_size, "RDB$BACKUP_HISTORY")
        .ok_or("no RDB$BACKUP_HISTORY generator")?;
    let id = gen::bump(file, page_size, slot, 1)?;
    sys_insert(file, page_size, "RDB$BACKUP_HISTORY", rel, &[
        ("RDB$BACKUP_ID", SysVal::I(id)),
        ("RDB$BACKUP_LEVEL", SysVal::I(level)),
        ("RDB$GUID", SysVal::S(guid_text)),
        ("RDB$SCN", SysVal::I(scn)),
        ("RDB$FILE_NAME", SysVal::S(file_name)),
    ])?;
    advance_oldest_transactions(file, page_size)
}

/// The most recent RDB$BACKUP_HISTORY row of a given level: its GUID
/// text and SCN - what an incremental backup chains onto.
pub fn last_backup_history(
    file: &crate::Image,
    page_size: usize,
    level: i64,
) -> Option<(String, i64)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$BACKUP_HISTORY")?;
    let formats = system_relation_formats(file, page_size, "RDB$BACKUP_HISTORY")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$BACKUP_HISTORY");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (id_f, lvl_f, guid_f, scn_f) = (
        fid("RDB$BACKUP_ID")?,
        fid("RDB$BACKUP_LEVEL")?,
        fid("RDB$GUID")?,
        fid("RDB$SCN")?,
    );
    let mut best: Option<(i64, String, i64)> = None;
    walk_rows(file, page_size, rel, descs, |v| {
        let (Some(Value::Int(id)), Some(Value::Int(l)), Some(Value::Text(g)), Some(Value::Int(scn))) =
            (v.get(id_f), v.get(lvl_f), v.get(guid_f), v.get(scn_f))
        else {
            return;
        };
        if *l == level && best.as_ref().map_or(true, |(bid, ..)| *id > *bid) {
            best = Some((*id, g.trim_end().to_string(), *scn));
        }
    });
    best.map(|(_, g, scn)| (g, scn))
}

/// Restore a carried SHADOW: the RDB$FILES row (the physical file is
/// the CALLER's to write - it is the database image itself with the
/// header marked, and only the caller holds the finished image).
pub fn restore_shadow_row(
    file: &mut crate::Image,
    page_size: usize,
    path: &str,
    shadow: i64,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FILES")
        .ok_or("no RDB$FILES relation")?;
    sys_insert(file, page_size, "RDB$FILES", rel, &[
        ("RDB$FILE_NAME", SysVal::S(path)),
        ("RDB$FILE_SEQUENCE", SysVal::I(0)),
        ("RDB$FILE_START", SysVal::I(0)),
        ("RDB$FILE_LENGTH", SysVal::I(0)),
        ("RDB$FILE_FLAGS", SysVal::I(1)),
        ("RDB$SHADOW_NUMBER", SysVal::I(shadow)),
    ])?;
    advance_oldest_transactions(file, page_size)
}

/// Mark a database image as an ACTIVE SHADOW of `root_path`: the
/// header takes hdr_active_shadow (bit 0x1 of hdr_flags @22) and the
/// HDR_root_file_name clumplet (tag 1, u8 length, the main file's
/// path) appended at hdr_end (@36), the end offset moved past it -
/// the measured byte diff between a live shadow and its database,
/// which is otherwise page-identical.
pub fn shadow_image_of(image: &[u8], page_size: usize, root_path: &str) -> Vec<u8> {
    let mut out = image.to_vec();
    if out.len() < page_size {
        return out;
    }
    let flags = u16::from_le_bytes([out[22], out[23]]) | 0x1;
    out[22..24].copy_from_slice(&flags.to_le_bytes());
    let end = u32::from_le_bytes([out[36], out[37], out[38], out[39]]) as usize;
    let p = root_path.as_bytes();
    let n = p.len().min(255);
    if end + 2 + n < page_size {
        out[end] = 1; // HDR_root_file_name
        out[end + 1] = n as u8;
        out[end + 2..end + 2 + n].copy_from_slice(&p[..n]);
        let new_end = (end + 2 + n) as u32;
        out[36..40].copy_from_slice(&new_end.to_le_bytes());
    }
    out
}

/// Restore a carried BLOB FILTER declaration: one RDB$FILTERS row,
/// names and subtypes verbatim, a fresh SQL$ class - the code the
/// names point at stays outside the file (no grant rows: measured,
/// the engine writes none for a filter).
pub fn restore_carried_filter(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    module: &str,
    entrypoint: &str,
    input_sub_type: i64,
    output_sub_type: i64,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$FILTERS")
        .ok_or("no RDB$FILTERS relation")?;
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    sys_insert(file, page_size, "RDB$FILTERS", rel, &[
        ("RDB$FUNCTION_NAME", SysVal::S(name)),
        ("RDB$MODULE_NAME", SysVal::S(module)),
        ("RDB$ENTRYPOINT", SysVal::S(entrypoint)),
        ("RDB$INPUT_SUB_TYPE", SysVal::I(input_sub_type)),
        ("RDB$OUTPUT_SUB_TYPE", SysVal::I(output_sub_type)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$SECURITY_CLASS", SysVal::S(&class)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
    ])?;
    advance_oldest_transactions(file, page_size)
}

/// Patch the DEFAULT publication's flags (ALTER DATABASE ENABLE
/// PUBLICATION travels as two booleans on the DATABASE record) and
/// insert the carried (publication, table) rows.
pub fn restore_publication_state(
    file: &mut crate::Image,
    page_size: usize,
    active: bool,
    auto_enable: bool,
    tables: &[(String, String)],
) -> Result<(), String> {
    if active || auto_enable {
        let rel = crate::resolve_relation(file, page_size, "RDB$PUBLICATIONS")
            .ok_or("no RDB$PUBLICATIONS relation")?;
        let name_f = sys_fid(file, page_size, "RDB$PUBLICATIONS", "RDB$PUBLICATION_NAME")?;
        patch_sys_row(
            file,
            page_size,
            "RDB$PUBLICATIONS",
            rel,
            move |v| text_eq(v.get(name_f), "RDB$DEFAULT"),
            &[
                ("RDB$ACTIVE_FLAG", SysVal::I(if active { 1 } else { 0 })),
                ("RDB$AUTO_ENABLE", SysVal::I(if auto_enable { 1 } else { 0 })),
            ],
        )?;
    }
    if !tables.is_empty() {
        let rel = crate::resolve_relation(file, page_size, "RDB$PUBLICATION_TABLES")
            .ok_or("no RDB$PUBLICATION_TABLES relation")?;
        for (p, t) in tables {
            sys_insert(file, page_size, "RDB$PUBLICATION_TABLES", rel, &[
                ("RDB$PUBLICATION_NAME", SysVal::S(p)),
                ("RDB$TABLE_NAME", SysVal::S(t)),
                ("RDB$TABLE_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ])?;
        }
    }
    advance_oldest_transactions(file, page_size)
}

/// Restore a carried security-name MAPPING: the RDB$AUTH_MAPPING row,
/// every column verbatim. Nothing else - a local mapping is pure
/// catalog, read by the engine's own login machinery.
#[allow(clippy::too_many_arguments)]
pub fn restore_carried_mapping(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    using_: &str,
    plugin: Option<&str>,
    db: Option<&str>,
    from_type: &str,
    from: &str,
    to_type: i64,
    to: Option<&str>,
) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$AUTH_MAPPING")
        .ok_or("no RDB$AUTH_MAPPING relation")?;
    let mut vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$MAP_NAME", SysVal::S(name)),
        ("RDB$MAP_USING", SysVal::S(using_)),
        ("RDB$MAP_FROM_TYPE", SysVal::S(from_type)),
        ("RDB$MAP_FROM", SysVal::S(from)),
        ("RDB$MAP_TO_TYPE", SysVal::I(to_type)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
    ];
    if let Some(pl) = plugin {
        vals.push(("RDB$MAP_PLUGIN", SysVal::S(pl)));
    }
    if let Some(d) = db {
        vals.push(("RDB$MAP_DB", SysVal::S(d)));
    }
    if let Some(t) = to {
        vals.push(("RDB$MAP_TO", SysVal::S(t)));
    }
    sys_insert(file, page_size, "RDB$AUTH_MAPPING", rel, &vals)?;
    advance_oldest_transactions(file, page_size)
}

/// Is there a RDB$COLLATIONS row of this name (any charset)?
fn collation_exists(file: &crate::Image, page_size: usize, name: &str) -> bool {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$COLLATIONS") else { return false };
    let Some(fmts) = system_relation_formats(file, page_size, "RDB$COLLATIONS") else { return false };
    let Some((_, descs)) = fmts.iter().max_by_key(|(n, _)| *n) else { return false };
    let Ok(nf) = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$COLLATION_NAME") else { return false };
    let mut found = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(nf), name) {
            found = true;
        }
    });
    found
}

/// The base collation's SPECIFIC_ATTRIBUTES for a charset: outer None = the
/// base is not defined for this charset; inner None = it has no specific
/// attributes (a non-ICU base). A user collation copies the base's string
/// (the ICU/collation version), which is what the engine stores.
fn collation_base_spec(
    file: &crate::Image,
    page_size: usize,
    charset_id: i64,
    base: &str,
) -> Option<Option<Vec<u8>>> {
    let rel = crate::resolve_relation(file, page_size, "RDB$COLLATIONS")?;
    let fmts = system_relation_formats(file, page_size, "RDB$COLLATIONS")?;
    let (_, descs) = fmts.iter().max_by_key(|(n, _)| *n)?;
    let nf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$COLLATION_NAME").ok()?;
    let csf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$CHARACTER_SET_ID").ok()?;
    let spf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$SPECIFIC_ATTRIBUTES").ok()?;
    let mut out: Option<Option<Vec<u8>>> = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(nf), base) && int_eq(v.get(csf), charset_id) {
            let spec = match v.get(spf) {
                Some(Value::Blob(r, n)) => crate::format::read_blob_content(file, page_size, *r, *n),
                _ => None,
            };
            out = Some(spec);
        }
    });
    out
}

/// The next user-collation id for a charset: the highest free id counting
/// down from 126 (probed: user collations take 126, 125, 124 ... per
/// charset, well above the built-ins).
fn next_collation_id(file: &crate::Image, page_size: usize, charset_id: i64) -> i64 {
    let mut used: Vec<i64> = Vec::new();
    if let Some(rel) = crate::resolve_relation(file, page_size, "RDB$COLLATIONS") {
        if let Some(fmts) = system_relation_formats(file, page_size, "RDB$COLLATIONS") {
            if let Some((_, descs)) = fmts.iter().max_by_key(|(n, _)| *n) {
                if let (Ok(csf), Ok(idf)) = (
                    sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$CHARACTER_SET_ID"),
                    sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$COLLATION_ID"),
                ) {
                    walk_rows(file, page_size, rel, descs, |v| {
                        if int_eq(v.get(csf), charset_id) {
                            if let Some(Value::Int(id)) = v.get(idf) {
                                used.push(*id);
                            }
                        }
                    });
                }
            }
        }
    }
    (0..=126).rev().find(|id| !used.contains(id)).unwrap_or(126)
}

/// `CREATE COLLATION <name> FOR <charset> FROM <base> [attrs]`: the
/// RDB$COLLATIONS row. The SPECIFIC_ATTRIBUTES blob is copied from the base
/// collation (the ICU version); the id counts down from 126 per charset.
/// This server keys BINARY, so a CASE/ACCENT INSENSITIVE collation orders as
/// its base does - the catalog is faithful, the ordering is a boundary.
#[allow(clippy::too_many_arguments)]
pub fn create_collation(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    charset_id: i64,
    base: &str,
    pad: bool,
    case_insensitive: bool,
    accent_insensitive: bool,
) -> Result<(), String> {
    if collation_exists(file, page_size, name) {
        return Err(format!("collation {} already exists", name));
    }
    let base_spec = collation_base_spec(file, page_size, charset_id, base)
        .ok_or_else(|| format!("base collation {} not found", base))?;
    // CASE / ACCENT INSENSITIVE need an ICU base (one with specific
    // attributes); ACCENT INSENSITIVE needs CASE INSENSITIVE too.
    if (case_insensitive || accent_insensitive) && base_spec.is_none() {
        return Err("Invalid collation attributes".into());
    }
    if accent_insensitive && !case_insensitive {
        return Err("Invalid collation attributes".into());
    }
    let attr = i64::from(pad) | (i64::from(case_insensitive) << 1) | (i64::from(accent_insensitive) << 2);
    let cid = next_collation_id(file, page_size, charset_id);
    let rel = crate::resolve_relation(file, page_size, "RDB$COLLATIONS").ok_or("no RDB$COLLATIONS")?;
    let spec_id = match &base_spec {
        Some(bytes) => Some(blob_id_bytes(rel, dml::insert_blob_cs(file, page_size, rel, &[bytes.clone()], 1, 4)?)),
        None => None,
    };
    let mut vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$COLLATION_NAME", SysVal::S(name)),
        ("RDB$COLLATION_ID", SysVal::I(cid)),
        ("RDB$CHARACTER_SET_ID", SysVal::I(charset_id)),
        ("RDB$COLLATION_ATTRIBUTES", SysVal::I(attr)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ("RDB$BASE_COLLATION_NAME", SysVal::S(base)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
    ];
    if let Some(id) = &spec_id {
        vals.push(("RDB$SPECIFIC_ATTRIBUTES", SysVal::B(*id)));
    }
    sys_insert(file, page_size, "RDB$COLLATIONS", rel, &vals)?;
    advance_oldest_transactions(file, page_size)
}

/// `DROP COLLATION` - remove the RDB$COLLATIONS row (a user collation).
pub fn drop_collation(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let rel = crate::resolve_relation(file, page_size, "RDB$COLLATIONS").ok_or("no RDB$COLLATIONS")?;
    let nf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$COLLATION_NAME")?;
    let sysf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$SYSTEM_FLAG")?;
    let fmts = system_relation_formats(file, page_size, "RDB$COLLATIONS").ok_or("no format")?;
    let (_, descs) = fmts.iter().max_by_key(|(n, _)| *n).ok_or("empty format")?;
    let mut found = false;
    let mut system = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(nf), name) {
            found = true;
            if !int_eq(v.get(sysf), 0) {
                system = true;
            }
        }
    });
    if !found {
        return Err(format!("collation {} not found", name));
    }
    if system {
        return Err(format!("Cannot delete system collation {}", name));
    }
    let want = name.to_string();
    delete_catalog_rows(file, page_size, "RDB$COLLATIONS", move |v| text_eq(v.get(nf), &want))?;
    advance_oldest_transactions(file, page_size)
}

/// Is there a RDB$AUTH_MAPPING row of this name?
fn mapping_exists(file: &crate::Image, page_size: usize, name: &str) -> bool {
    let Some(rel) = crate::resolve_relation(file, page_size, "RDB$AUTH_MAPPING") else { return false };
    let Some(fmts) = system_relation_formats(file, page_size, "RDB$AUTH_MAPPING") else { return false };
    let Some((_, descs)) = fmts.iter().max_by_key(|(n, _)| *n) else { return false };
    let Ok(nf) = sys_fid(file, page_size, "RDB$AUTH_MAPPING", "RDB$MAP_NAME") else { return false };
    let mut found = false;
    walk_rows(file, page_size, rel, descs, |v| {
        if text_eq(v.get(nf), name) {
            found = true;
        }
    });
    found
}

/// `CREATE MAPPING` - a local (database) name mapping: the RDB$AUTH_MAPPING
/// row, the same one gbak restores ([restore_carried_mapping]). A GLOBAL
/// mapping lives in the security database and is refused upstream.
#[allow(clippy::too_many_arguments)]
pub fn create_mapping(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    using_: &str,
    plugin: Option<&str>,
    db: Option<&str>,
    from_type: &str,
    from: &str,
    to_type: i64,
    to: Option<&str>,
) -> Result<(), String> {
    if mapping_exists(file, page_size, name) {
        return Err(format!("mapping {} already exists", name));
    }
    restore_carried_mapping(file, page_size, name, using_, plugin, db, from_type, from, to_type, to)
}

/// `DROP MAPPING` - remove the RDB$AUTH_MAPPING row.
pub fn drop_mapping(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    if !mapping_exists(file, page_size, name) {
        return Err(format!("mapping {} not found", name));
    }
    let nf = sys_fid(file, page_size, "RDB$AUTH_MAPPING", "RDB$MAP_NAME")?;
    let want = name.to_string();
    delete_catalog_rows(file, page_size, "RDB$AUTH_MAPPING", move |v| text_eq(v.get(nf), &want))?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER MAPPING` - replace the row in place (delete then re-insert).
#[allow(clippy::too_many_arguments)]
pub fn alter_mapping(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    using_: &str,
    plugin: Option<&str>,
    db: Option<&str>,
    from_type: &str,
    from: &str,
    to_type: i64,
    to: Option<&str>,
) -> Result<(), String> {
    if !mapping_exists(file, page_size, name) {
        return Err(format!("mapping {} not found", name));
    }
    let nf = sys_fid(file, page_size, "RDB$AUTH_MAPPING", "RDB$MAP_NAME")?;
    {
        let want = name.to_string();
        delete_catalog_rows(file, page_size, "RDB$AUTH_MAPPING", move |v| text_eq(v.get(nf), &want))?;
    }
    restore_carried_mapping(file, page_size, name, using_, plugin, db, from_type, from, to_type, to)
}

/// A relation's `RDB$EXTERNAL_FILE` path, if it is an EXTERNAL table.
pub fn relation_external_file(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Option<String> {
    let want = name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$RELATIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let name_f = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME").ok()?;
    let ext_f = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$EXTERNAL_FILE").ok()?;
    let mut found: Option<String> = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_none() && text_is(v.get(name_f), &want) {
            if let Some(Value::Text(t)) = v.get(ext_f) {
                let t = t.trim_end();
                if !t.is_empty() {
                    found = Some(t.to_string());
                }
            }
        }
    });
    found
}

/// Patch a relation's `RDB$EXTERNAL_FILE` - the carried path of an
/// EXTERNAL table, verbatim (the restore does not touch the file).
pub fn patch_relation_external_file(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    path: &str,
) -> Result<(), String> {
    let want = name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATIONS")
        .ok_or("no RDB$RELATIONS relation")?;
    let name_f = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATIONS",
        rel,
        move |v| text_is(v.get(name_f), &want),
        &[("RDB$EXTERNAL_FILE", SysVal::S(path))],
    )
}

/// Patch a relation's `RDB$DBKEY_LENGTH`. The engine's own RESTORE of
/// a GTT writes 0 where live DDL writes 8 (measured on a round trip) -
/// fc's restore mirrors the restored catalog.
pub fn patch_relation_dbkey_length(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    value: i64,
) -> Result<(), String> {
    let want = name.trim().to_string();
    let rel = crate::resolve_relation(file, page_size, "RDB$RELATIONS")
        .ok_or("no RDB$RELATIONS relation")?;
    let name_f = sys_fid(file, page_size, "RDB$RELATIONS", "RDB$RELATION_NAME")?;
    patch_sys_row(
        file,
        page_size,
        "RDB$RELATIONS",
        rel,
        move |v| text_is(v.get(name_f), &want),
        &[("RDB$DBKEY_LENGTH", SysVal::I(value))],
    )
}

/// One carried function argument: the position off the file, the type
/// facts resolved through the carried domain records. Position 0 is
/// the RETURN argument (RDB$RETURN_ARGUMENT names it on the header row).
#[derive(Clone, Debug)]
pub struct FnArgDef {
    pub name: Option<String>,
    pub position: i64,
    pub field_type: i16,
    pub length: u16,
    pub scale: i16,
    pub sub_type: i16,
    pub null_flag: bool,
    /// an argument DEFAULT: (value BLR verbatim, `= 42` source text)
    pub default: Option<(Vec<u8>, String)>,
    /// a LEGACY arg: type facts land INLINE on the row, no domain
    pub inline: bool,
    pub precision: Option<i64>,
    /// RDB$MECHANISM: 0 by value, 1 by reference (a legacy arg's)
    pub mech: i64,
}

/// The EXTERNAL half of a carried function declaration: the code the
/// names point at stays OUTSIDE the file, exactly the engine's own
/// carriage.
pub struct ExternalFn {
    pub module: Option<String>,
    pub entrypoint: Option<String>,
    pub engine: Option<String>,
    pub legacy: bool,
}

/// Restore a carried PSQL function: the `RDB$FUNCTIONS` row with the
/// engine's BLR and source verbatim, one invented `RDB$n` domain per
/// argument (the argument row's own type columns stay NULL, exactly the
/// engine's catalog - the domain IS the type), and the owner's EXECUTE
/// grant (object type 15, `obj_udf`). `RDB$MECHANISM` lands 0, not
/// NULL, mirroring the ENGINE'S OWN RESTORE of the same record (the
/// file carries an unconditional int32 where the source catalog held
/// NULL - measured on a round trip).
#[allow(clippy::too_many_arguments)]
pub fn restore_carried_function(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    args: &[FnArgDef],
    return_arg: i64,
    deterministic: bool,
    source: &str,
    blr: &[u8],
    debug: Option<&[u8]>,
    package: Option<(&str, i64)>,
    external: Option<&ExternalFn>,
    declaration: bool,
    keep_id: Option<i64>,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a function needs a name".into());
    }
    let frel = crate::resolve_relation(file, page_size, "RDB$FUNCTIONS")
        .ok_or("no RDB$FUNCTIONS relation")?;
    // already exists? refuse before any row lands
    {
        let formats = system_relation_formats(file, page_size, "RDB$FUNCTIONS")
            .ok_or("no RDB$FUNCTIONS format")?;
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("no RDB$FUNCTIONS format")?;
        let cols = relation_columns(file, page_size, "RDB$FUNCTIONS");
        let name_f = cols
            .iter()
            .find(|c| c.name == "RDB$FUNCTION_NAME")
            .map(|c| c.field_id as usize)
            .ok_or("no RDB$FUNCTION_NAME column")?;
        // same namespace rule as procedures: a packaged member and a
        // plain function of the same name coexist (the engine namespaces
        // members by their package)
        let pkg_f = cols.iter().find(|c| c.name == "RDB$PACKAGE_NAME").map(|c| c.field_id as usize);
        let want_pkg = package.map(|(p, _)| p.trim().trim_matches('"').to_ascii_uppercase());
        let mut dup = false;
        walk_rows(file, page_size, frel, descs, |v| {
            if !text_eq(v.get(name_f), &want) {
                return;
            }
            let same_ns = match &want_pkg {
                None => pkg_f.map_or(true, |i| matches!(v.get(i), None | Some(Value::Null))),
                Some(pk) => pkg_f.is_some_and(|i| text_eq(v.get(i), pk)),
            };
            if same_ns {
                dup = true;
            }
        });
        if dup {
            return Err(format!("Function {} already exists", want));
        }
    }
    let slot = generator_id_by_name(file, page_size, "RDB$FUNCTIONS")
        .ok_or("no RDB$FUNCTIONS generator")?;
    let id = match keep_id {
        Some(k) => k,
        None => gen::bump(file, page_size, slot, 1)?,
    };
    // a package member's security class is NULL and its grant lives on
    // the package (measured), exactly as for packaged procedures
    let class = match package {
        None => Some(next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?),
        Some(_) => None,
    };
    // an EXTERNAL function has NO blobs of its own - the names are
    // the whole declaration (measured: no blr, no source, VALID_BLR
    // null on the engine's rows)
    let blobs = if external.is_some() || declaration {
        None
    } else {
        // a PACKAGED member holds no source of its own (only its blr); a
        // standalone function carries both.
        let src_blob = if package.is_none() {
            Some(dml::insert_blob_cs(file, page_size, frel, &[source.as_bytes().to_vec()], 1, 4)?)
        } else {
            None
        };
        let blr_blob = dml::insert_blob(file, page_size, frel, &[blr.to_vec()], 2)?;
        Some((src_blob, blr_blob))
    };
    let dbg_blob = match debug {
        Some(d) => Some(dml::insert_blob(file, page_size, frel, &[d.to_vec()], 9)?),
        None => None,
    };
    let mut vals: Vec<(&str, SysVal<'_>)> = vec![
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$FUNCTION_NAME", SysVal::S(&want)),
        ("RDB$FUNCTION_ID", SysVal::I(id)),
        ("RDB$RETURN_ARGUMENT", SysVal::I(return_arg)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        (
            "RDB$DETERMINISTIC_FLAG",
            SysVal::I(if deterministic { 1 } else { 0 }),
        ),
        ("RDB$AGGREGATE_FLAG", SysVal::I(0)),
    ];
    if let Some((src_blob, blr_blob)) = blobs {
        if let Some(src_blob) = src_blob {
            vals.push(("RDB$FUNCTION_SOURCE", SysVal::B(blob_id_bytes(frel, src_blob))));
        }
        vals.push(("RDB$FUNCTION_BLR", SysVal::B(blob_id_bytes(frel, blr_blob))));
        vals.push(("RDB$VALID_BLR", SysVal::I(1)));
    }
    match external {
        Some(ext) => {
            if let Some(m) = &ext.module {
                vals.push(("RDB$MODULE_NAME", SysVal::S(m)));
            }
            if let Some(e) = &ext.entrypoint {
                vals.push(("RDB$ENTRYPOINT", SysVal::S(e)));
            }
            if let Some(en) = &ext.engine {
                vals.push(("RDB$ENGINE_NAME", SysVal::S(en)));
            }
            vals.push(("RDB$LEGACY_FLAG", SysVal::I(if ext.legacy { 1 } else { 0 })));
        }
        None => vals.push(("RDB$LEGACY_FLAG", SysVal::I(0))),
    }
    if let Some(db) = dbg_blob {
        vals.push(("RDB$DEBUG_INFO", SysVal::B(blob_id_bytes(frel, db))));
    }
    if let Some(c) = &class {
        vals.push(("RDB$SECURITY_CLASS", SysVal::S(c)));
    }
    if let Some((pk, pv)) = package {
        vals.push(("RDB$PACKAGE_NAME", SysVal::S(pk)));
        vals.push(("RDB$PRIVATE_FLAG", SysVal::I(pv)));
    }
    sys_insert(file, page_size, "RDB$FUNCTIONS", frel, &vals)?;
    // arguments: an invented domain each, then the argument row
    let arel = crate::resolve_relation(file, page_size, "RDB$FUNCTION_ARGUMENTS")
        .ok_or("no RDB$FUNCTION_ARGUMENTS relation")?;
    for a in args {
        if a.inline {
            // a LEGACY arg: the type facts land INLINE, no domain, the
            // measured row shape (FIELD_SOURCE null, MECHANISM 0/1)
            let mut avals: Vec<(&str, SysVal<'_>)> = vec![
                ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
                ("RDB$FUNCTION_NAME", SysVal::S(&want)),
                ("RDB$ARGUMENT_POSITION", SysVal::I(a.position)),
                ("RDB$MECHANISM", SysVal::I(a.mech)),
                ("RDB$FIELD_TYPE", SysVal::I(a.field_type as i64)),
                ("RDB$FIELD_SCALE", SysVal::I(a.scale as i64)),
                ("RDB$FIELD_LENGTH", SysVal::I(a.length as i64)),
                ("RDB$FIELD_SUB_TYPE", SysVal::I(a.sub_type as i64)),
                ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ];
            if let Some(pr) = a.precision {
                avals.push(("RDB$FIELD_PRECISION", SysVal::I(pr)));
            }
            if let Some(an) = &a.name {
                avals.push(("RDB$ARGUMENT_NAME", SysVal::S(an.as_str())));
            }
            sys_insert(file, page_size, "RDB$FUNCTION_ARGUMENTS", arel, &avals)?;
            continue;
        }
        let domain_num = next_domain_number(file, page_size)?;
        let dom = format!("RDB${}", domain_num);
        let mut field_vals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$FIELD_NAME", SysVal::S(&dom)),
            ("RDB$FIELD_TYPE", SysVal::I(a.field_type as i64)),
            ("RDB$FIELD_LENGTH", SysVal::I(a.length as i64)),
            ("RDB$FIELD_SCALE", SysVal::I(a.scale as i64)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ];
        if subtype_carried(a.field_type) {
            field_vals.push(("RDB$FIELD_SUB_TYPE", SysVal::I(a.sub_type as i64)));
        }
        // the PRECISION-0 law from the procedure slice holds here too: a
        // NULL precision on an exact-numeric domain crashed the engine's
        // executor reading an fc-authored catalog
        if matches!(a.field_type, 7 | 8 | 16 | 26) {
            field_vals.push(("RDB$FIELD_PRECISION", SysVal::I(0)));
        }
        if matches!(a.field_type, 14 | 37) {
            field_vals.push(("RDB$CHARACTER_SET_ID", SysVal::I(0)));
            field_vals.push(("RDB$CHARACTER_LENGTH", SysVal::I(a.length as i64)));
        }
        let fdrel = crate::resolve_relation(file, page_size, "RDB$FIELDS")
            .ok_or("no RDB$FIELDS relation")?;
        sys_insert(file, page_size, "RDB$FIELDS", fdrel, &field_vals)?;
        let mut avals: Vec<(&str, SysVal<'_>)> = vec![
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$FUNCTION_NAME", SysVal::S(&want)),
            ("RDB$ARGUMENT_POSITION", SysVal::I(a.position)),
            ("RDB$FIELD_SOURCE", SysVal::S(&dom)),
            ("RDB$FIELD_SOURCE_SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$ARGUMENT_MECHANISM", SysVal::I(0)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ];
        if a.mech >= 0 {
            // a PSQL function's argument has no RDB$MECHANISM (NULL, probed); a UDF's is carried
            avals.push(("RDB$MECHANISM", SysVal::I(a.mech)));
        }
        if let Some(an) = &a.name {
            avals.push(("RDB$ARGUMENT_NAME", SysVal::S(an.as_str())));
        }
        if a.null_flag {
            avals.push(("RDB$NULL_FLAG", SysVal::I(1)));
        }
        if let Some((pk, _)) = package {
            avals.push(("RDB$PACKAGE_NAME", SysVal::S(pk)));
        }
        let def_blobs = match &a.default {
            Some((blr, src)) => Some((
                dml::insert_blob(file, page_size, arel, &[blr.clone()], 2)?,
                dml::insert_blob_cs(file, page_size, arel, &[src.as_bytes().to_vec()], 1, 4)?,
            )),
            None => None,
        };
        if let Some((vb, sb)) = def_blobs {
            avals.push(("RDB$DEFAULT_VALUE", SysVal::B(blob_id_bytes(arel, vb))));
            avals.push(("RDB$DEFAULT_SOURCE", SysVal::B(blob_id_bytes(arel, sb))));
        }
        sys_insert(file, page_size, "RDB$FUNCTION_ARGUMENTS", arel, &avals)?;
    }
    // the owner's EXECUTE grant, object type 15 (obj_udf) - unless the
    // function is a package member (the package holds the grant)
    if package.is_none() {
        store_privileges(file, page_size, &want, 15, &["X"])?;
    }
    advance_oldest_transactions(file, page_size)
}

/// Restore a carried PACKAGE header row: the two sources verbatim,
/// VALID_BODY_FLAG 1, a fresh SQL$ security class, and the owner's
/// EXECUTE grant with object type 18 (obj_package_header, measured).
/// The members arrive separately through create_procedure /
/// restore_carried_function with their package tag.
/// One member of a package header (a declaration, no body).
#[derive(Clone, Debug)]
pub enum PackageMember {
    Procedure { name: String, ins: Vec<ProcParamDef>, outs: Vec<ProcParamDef> },
    Function { name: String, args: Vec<FnArgDef> },
}

/// `CREATE PACKAGE <name> AS BEGIN <decls> END` - the header. Writes the
/// RDB$PACKAGES row (header source only, no body, VALID_BODY_FLAG null) and a
/// DECLARATION row per member (no blr/type/valid). The body fills them later.
pub fn create_package(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    header_source: &str,
    members: &[PackageMember],
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a package needs a name".into());
    }
    let prel = crate::resolve_relation(file, page_size, "RDB$PACKAGES").ok_or("no RDB$PACKAGES relation")?;
    {
        let fmts = system_relation_formats(file, page_size, "RDB$PACKAGES").ok_or("no RDB$PACKAGES format")?;
        let (_, descs) = fmts.iter().max_by_key(|(n, _)| *n).ok_or("no RDB$PACKAGES format")?;
        let nf = sys_fid(file, page_size, "RDB$PACKAGES", "RDB$PACKAGE_NAME")?;
        let mut dup = false;
        walk_rows(file, page_size, prel, descs, |v| { if text_eq(v.get(nf), &want) { dup = true; } });
        if dup {
            return Err(format!("Package {} already exists", want));
        }
    }
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    let hdr_blob = dml::insert_blob_cs(file, page_size, prel, &[header_source.as_bytes().to_vec()], 1, 4)?;
    sys_insert(file, page_size, "RDB$PACKAGES", prel, &[
        ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
        ("RDB$PACKAGE_NAME", SysVal::S(&want)),
        ("RDB$PACKAGE_HEADER_SOURCE", SysVal::B(blob_id_bytes(prel, hdr_blob))),
        ("RDB$SECURITY_CLASS", SysVal::S(&class)),
        ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ("RDB$SYSTEM_FLAG", SysVal::I(0)),
    ])?;
    store_privileges(file, page_size, &want, 18, &["X"])?;
    for m in members {
        match m {
            PackageMember::Procedure { name, ins, outs } => {
                create_procedure_with_id(file, page_size, name, ins, outs, false, "", &[], Some((&want, 0)), None, true)?;
            }
            PackageMember::Function { name, args } => {
                restore_carried_function(file, page_size, name, args, 0, false, "", &[], None, Some((&want, 0)), None, true, None)?;
            }
        }
    }
    advance_oldest_transactions(file, page_size)
}

/// A member of a package BODY (a full implementation, with compiled blr).
#[derive(Clone, Debug)]
pub enum PackageBodyMember {
    Procedure { name: String, ins: Vec<ProcParamDef>, outs: Vec<ProcParamDef>, selectable: bool, blr: Vec<u8> },
    Function { name: String, args: Vec<FnArgDef>, deterministic: bool, blr: Vec<u8> },
}

/// The RDB$FUNCTION_ID of a PLAIN (non-packaged) function - matched on
/// name where RDB$PACKAGE_NAME is NULL, so a standalone function is not
/// confused with a same-named packaged member. Used by ALTER FUNCTION to
/// preserve the id across a drop-and-recreate.
pub fn function_id_plain(file: &crate::Image, page_size: usize, name: &str) -> Option<i64> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, "RDB$FUNCTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FUNCTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FUNCTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f, pk_f) = (fid("RDB$FUNCTION_NAME")?, fid("RDB$FUNCTION_ID")?, fid("RDB$PACKAGE_NAME")?);
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        let plain = !matches!(v.get(pk_f), Some(Value::Text(_)));
        if out.is_none() && plain && text_eq(v.get(name_f), &want) {
            if let Some(Value::Int(i)) = v.get(id_f) {
                out = Some(*i);
            }
        }
    });
    out
}

fn function_id(file: &crate::Image, page_size: usize, name: &str, package: &str) -> Option<i64> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let rel = crate::resolve_relation(file, page_size, "RDB$FUNCTIONS")?;
    let formats = system_relation_formats(file, page_size, "RDB$FUNCTIONS")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$FUNCTIONS");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, id_f, pk_f) = (fid("RDB$FUNCTION_NAME")?, fid("RDB$FUNCTION_ID")?, fid("RDB$PACKAGE_NAME")?);
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if out.is_none() && text_eq(v.get(name_f), &want) && text_eq(v.get(pk_f), package) {
            if let Some(Value::Int(i)) = v.get(id_f) {
                out = Some(*i);
            }
        }
    });
    out
}

/// Delete a package MEMBER (procedure or function) with its parameters and
/// their auto-domains - the way [create_package_body] clears a declaration
/// before re-writing it as an implementation.
fn delete_package_member(file: &mut crate::Image, page_size: usize, is_proc: bool, member: &str, package: &str) -> Result<(), String> {
    let (mrel, mname_c, prel_name, pname_c) = if is_proc {
        ("RDB$PROCEDURES", "RDB$PROCEDURE_NAME", "RDB$PROCEDURE_PARAMETERS", "RDB$PROCEDURE_NAME")
    } else {
        ("RDB$FUNCTIONS", "RDB$FUNCTION_NAME", "RDB$FUNCTION_ARGUMENTS", "RDB$FUNCTION_NAME")
    };
    // the member's param domains
    let mut domains: Vec<String> = Vec::new();
    if let (Some(rel), Some(fmts)) = (crate::resolve_relation(file, page_size, prel_name), system_relation_formats(file, page_size, prel_name)) {
        if let Some((_, descs)) = fmts.iter().max_by_key(|(n, _)| *n) {
            if let (Ok(nf), Ok(pf), Ok(sf)) = (
                sys_fid(file, page_size, prel_name, pname_c),
                sys_fid(file, page_size, prel_name, "RDB$PACKAGE_NAME"),
                sys_fid(file, page_size, prel_name, "RDB$FIELD_SOURCE"),
            ) {
                walk_rows(file, page_size, rel, descs, |v| {
                    if text_eq(v.get(nf), member) && text_eq(v.get(pf), package) {
                        if let Some(Value::Text(t)) = v.get(sf) {
                            let d = t.trim_end().to_string();
                            if d.strip_prefix("RDB$").is_some_and(|x| x.parse::<u64>().is_ok()) {
                                domains.push(d);
                            }
                        }
                    }
                });
            }
        }
    }
    {
        let nf = sys_fid(file, page_size, prel_name, pname_c)?;
        let pf = sys_fid(file, page_size, prel_name, "RDB$PACKAGE_NAME")?;
        let (m, pk) = (member.to_string(), package.to_string());
        delete_catalog_rows(file, page_size, prel_name, move |v| text_eq(v.get(nf), &m) && text_eq(v.get(pf), &pk))?;
    }
    {
        let nf = sys_fid(file, page_size, mrel, mname_c)?;
        let pf = sys_fid(file, page_size, mrel, "RDB$PACKAGE_NAME")?;
        let (m, pk) = (member.to_string(), package.to_string());
        delete_catalog_rows(file, page_size, mrel, move |v| text_eq(v.get(nf), &m) && text_eq(v.get(pf), &pk))?;
    }
    for d in domains {
        let nf = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| text_eq(v.get(nf), &d))?;
    }
    Ok(())
}

/// The INPUT-parameter DEFAULTs a package HEADER declared for one member,
/// keyed by uppercased parameter name: (value BLR, source text). A default
/// belongs on the header declaration, and the engine PRESERVES it when the
/// body is created even though the body re-declares the member without one;
/// create_package_body re-writes the member's parameter rows, so it reads
/// the header's defaults here first and carries them onto the fresh rows.
/// `is_proc` selects RDB$PROCEDURE_PARAMETERS (input params, type 0) vs
/// RDB$FUNCTION_ARGUMENTS (arguments, position >= 1 - position 0 is the
/// return value).
fn carried_member_defaults(
    file: &crate::Image,
    page_size: usize,
    is_proc: bool,
    member: &str,
    package: &str,
) -> std::collections::HashMap<String, (Vec<u8>, String)> {
    let mut out = std::collections::HashMap::new();
    let (rel_name, name_col, param_name_col, filt_col) = if is_proc {
        ("RDB$PROCEDURE_PARAMETERS", "RDB$PROCEDURE_NAME", "RDB$PARAMETER_NAME", "RDB$PARAMETER_TYPE")
    } else {
        ("RDB$FUNCTION_ARGUMENTS", "RDB$FUNCTION_NAME", "RDB$ARGUMENT_NAME", "RDB$ARGUMENT_POSITION")
    };
    let Some(rel) = crate::resolve_relation(file, page_size, rel_name) else { return out };
    let Some(formats) = system_relation_formats(file, page_size, rel_name) else { return out };
    let Some((_, descs)) = formats.iter().max_by_key(|(n, _)| *n) else { return out };
    let cols = relation_columns(file, page_size, rel_name);
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (Some(name_f), Some(pn_f), Some(dv_f), Some(ds_f), Some(filt_f)) = (
        fid(name_col),
        fid(param_name_col),
        fid("RDB$DEFAULT_VALUE"),
        fid("RDB$DEFAULT_SOURCE"),
        fid(filt_col),
    ) else {
        return out;
    };
    let pkg_f = fid("RDB$PACKAGE_NAME");
    let want_m = member.trim().trim_matches('"').to_ascii_uppercase();
    let want_p = package.trim().trim_matches('"').to_ascii_uppercase();
    // collect (name, def-blob, src-blob) in the walk; read the blobs after,
    // the way domain_type does (no blob read inside the row closure)
    let mut hits: Vec<(String, (u16, u64), Option<(u16, u64)>)> = Vec::new();
    walk_rows(file, page_size, rel, descs, |v| {
        if !text_eq(v.get(name_f), &want_m) {
            return;
        }
        let pkg_ok = matches!(pkg_f.map(|i| v.get(i)),
            Some(Some(Value::Text(rp))) if rp.trim_end().eq_ignore_ascii_case(&want_p));
        if !pkg_ok {
            return;
        }
        // inputs only: procedure param type 0, function argument position >= 1
        match v.get(filt_f) {
            Some(Value::Int(x)) if (is_proc && *x == 0) || (!is_proc && *x >= 1) => {}
            _ => return,
        }
        let Some(Value::Text(pn)) = v.get(pn_f) else { return };
        let Some(Value::Blob(dr, dn)) = v.get(dv_f) else { return };
        let src = match v.get(ds_f) {
            Some(Value::Blob(sr, sn)) => Some((*sr, *sn)),
            _ => None,
        };
        hits.push((pn.trim_end().to_ascii_uppercase(), (*dr, *dn), src));
    });
    for (nm, (dr, dn), src) in hits {
        let Some(blr) = crate::format::read_blob_content(file, page_size, dr, dn) else { continue };
        let src_txt = src
            .and_then(|(sr, sn)| crate::format::read_blob_content(file, page_size, sr, sn))
            .and_then(|b| String::from_utf8(b).ok())
            .unwrap_or_default();
        out.insert(nm, (blr, src_txt));
    }
    out
}

/// `CREATE PACKAGE BODY <name> AS BEGIN <impls> END` - fills the header's
/// members with their compiled bodies. The engine re-writes each member (new
/// param domains) keeping its RDB$PROCEDURE/FUNCTION_ID, then stamps the
/// package row with the body source and VALID_BODY_FLAG.
pub fn create_package_body(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    body_source: &str,
    members: &[PackageBodyMember],
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let prel = crate::resolve_relation(file, page_size, "RDB$PACKAGES").ok_or("no RDB$PACKAGES relation")?;
    {
        let fmts = system_relation_formats(file, page_size, "RDB$PACKAGES").ok_or("no format")?;
        let (_, descs) = fmts.iter().max_by_key(|(n, _)| *n).ok_or("empty")?;
        let nf = sys_fid(file, page_size, "RDB$PACKAGES", "RDB$PACKAGE_NAME")?;
        let vf = sys_fid(file, page_size, "RDB$PACKAGES", "RDB$VALID_BODY_FLAG")?;
        let (mut found, mut has_body) = (false, false);
        walk_rows(file, page_size, prel, descs, |v| {
            if text_eq(v.get(nf), &want) {
                found = true;
                if matches!(v.get(vf), Some(Value::Int(_))) {
                    has_body = true;
                }
            }
        });
        if !found {
            return Err(format!("Package {} not found", want));
        }
        if has_body {
            return Err(format!("Package body {} already exists", want));
        }
    }
    // A parameter DEFAULT belongs on the package HEADER declaration, never
    // on the BODY definition of a previously declared member: the engine
    // rejects it with the DYN dyn_defvaldecl_package_{proc,func} vector
    // ("Default values for parameters are not allowed in the definition of
    // a previously declared packaged {procedure,function} @1.@2"). fc emits
    // no header-declaration defaults yet, so ANY default here is a body one
    // - refuse it fast, before writing, in member (source) order so the
    // FIRST offending member is named, as the engine names it. The marker
    // text is decoded by respond_ddl_meta into the byte-exact vector.
    for m in members {
        let bad = match m {
            PackageBodyMember::Procedure { name, ins, .. } => {
                ins.iter().any(|p| p.default.is_some()).then(|| ("procedure", name.clone()))
            }
            PackageBodyMember::Function { name, args, .. } => {
                args.iter().any(|a| a.default.is_some()).then(|| ("function", name.clone()))
            }
        };
        if let Some((kind, mem)) = bad {
            return Err(format!("pkgdefault {} {}", kind, mem));
        }
    }
    for m in members {
        match m {
            PackageBodyMember::Procedure { name, ins, outs, selectable, blr } => {
                let id = procedure_id_in_package(file, page_size, name, &want).ok_or_else(|| format!("member {} not declared in the header", name))?;
                // carry the header declaration's input defaults onto the
                // re-written parameter rows (the body has none - guarded
                // above; the engine keeps the header's)
                let carried = carried_member_defaults(file, page_size, true, name, &want);
                let mut ins = ins.clone();
                for p in ins.iter_mut() {
                    if p.default.is_none() {
                        if let Some(d) = carried.get(&p.name.trim().trim_matches('"').to_ascii_uppercase()) {
                            p.default = Some(d.clone());
                        }
                    }
                }
                delete_package_member(file, page_size, true, name, &want)?;
                create_procedure_with_id(file, page_size, name, &ins, outs, *selectable, "", blr, Some((&want, 0)), Some(id), false)?;
            }
            PackageBodyMember::Function { name, args, deterministic, blr } => {
                let id = function_id(file, page_size, name, &want).ok_or_else(|| format!("member {} not declared in the header", name))?;
                let carried = carried_member_defaults(file, page_size, false, name, &want);
                let mut args = args.clone();
                for a in args.iter_mut() {
                    if a.default.is_none() {
                        if let Some(nm) = &a.name {
                            if let Some(d) = carried.get(&nm.trim().trim_matches('"').to_ascii_uppercase()) {
                                a.default = Some(d.clone());
                            }
                        }
                    }
                }
                delete_package_member(file, page_size, false, name, &want)?;
                restore_carried_function(file, page_size, name, &args, 0, *deterministic, "", blr, None, Some((&want, 0)), None, false, Some(id))?;
            }
        }
    }
    let body_blob = dml::insert_blob_cs(file, page_size, prel, &[body_source.as_bytes().to_vec()], 1, 4)?;
    let name_fid = sys_fid(file, page_size, "RDB$PACKAGES", "RDB$PACKAGE_NAME")?;
    let w = want.clone();
    patch_sys_row(file, page_size, "RDB$PACKAGES", prel, move |v| text_eq(v.get(name_fid), &w), &[
        ("RDB$PACKAGE_BODY_SOURCE", SysVal::B(blob_id_bytes(prel, body_blob))),
        ("RDB$VALID_BODY_FLAG", SysVal::I(1)),
    ])?;
    advance_oldest_transactions(file, page_size)
}

/// `DROP PACKAGE <name>` - the package row, every member procedure/function
/// with this package tag, their parameters and auto-domains.
pub fn drop_package(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let prel = crate::resolve_relation(file, page_size, "RDB$PACKAGES").ok_or("no RDB$PACKAGES relation")?;
    {
        let fmts = system_relation_formats(file, page_size, "RDB$PACKAGES").ok_or("no format")?;
        let (_, descs) = fmts.iter().max_by_key(|(n, _)| *n).ok_or("empty")?;
        let nf = sys_fid(file, page_size, "RDB$PACKAGES", "RDB$PACKAGE_NAME")?;
        let mut found = false;
        walk_rows(file, page_size, prel, descs, |v| { if text_eq(v.get(nf), &want) { found = true; } });
        if !found {
            return Err(format!("Package {} not found", want));
        }
    }
    // collect the member domains (RDB$FIELD_SOURCE of the members' params) so
    // they can go with the rest.
    let mut domains: Vec<String> = Vec::new();
    for (tbl, pkgcol, srccol) in [
        ("RDB$PROCEDURE_PARAMETERS", "RDB$PACKAGE_NAME", "RDB$FIELD_SOURCE"),
        ("RDB$FUNCTION_ARGUMENTS", "RDB$PACKAGE_NAME", "RDB$FIELD_SOURCE"),
    ] {
        if let (Some(rel), Some(fmts)) = (crate::resolve_relation(file, page_size, tbl), system_relation_formats(file, page_size, tbl)) {
            if let Some((_, descs)) = fmts.iter().max_by_key(|(n, _)| *n) {
                if let (Ok(pf), Ok(sf)) = (sys_fid(file, page_size, tbl, pkgcol), sys_fid(file, page_size, tbl, srccol)) {
                    walk_rows(file, page_size, rel, descs, |v| {
                        if text_eq(v.get(pf), &want) {
                            if let Some(Value::Text(t)) = v.get(sf) {
                                let d = t.trim_end().to_string();
                                if d.strip_prefix("RDB$").is_some_and(|x| x.parse::<u64>().is_ok()) {
                                    domains.push(d);
                                }
                            }
                        }
                    });
                }
            }
        }
    }
    let del_by_pkg = |file: &mut crate::Image, tbl: &str| -> Result<(), String> {
        let pf = sys_fid(file, page_size, tbl, "RDB$PACKAGE_NAME")?;
        let w = want.clone();
        delete_catalog_rows(file, page_size, tbl, move |v| text_eq(v.get(pf), &w)).map(|_| ())
    };
    del_by_pkg(file, "RDB$PROCEDURE_PARAMETERS")?;
    del_by_pkg(file, "RDB$FUNCTION_ARGUMENTS")?;
    del_by_pkg(file, "RDB$PROCEDURES")?;
    del_by_pkg(file, "RDB$FUNCTIONS")?;
    for d in domains {
        let nf = sys_fid(file, page_size, "RDB$FIELDS", "RDB$FIELD_NAME")?;
        delete_catalog_rows(file, page_size, "RDB$FIELDS", move |v| text_eq(v.get(nf), &d))?;
    }
    {
        let nf = sys_fid(file, page_size, "RDB$PACKAGES", "RDB$PACKAGE_NAME")?;
        let w = want.clone();
        delete_catalog_rows(file, page_size, "RDB$PACKAGES", move |v| text_eq(v.get(nf), &w))?;
    }
    advance_oldest_transactions(file, page_size)
}

pub fn restore_carried_package(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    header: &[u8],
    body: &[u8],
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a package needs a name".into());
    }
    let prel = crate::resolve_relation(file, page_size, "RDB$PACKAGES")
        .ok_or("no RDB$PACKAGES relation")?;
    {
        let formats = system_relation_formats(file, page_size, "RDB$PACKAGES")
            .ok_or("no RDB$PACKAGES format")?;
        let (_, descs) = formats
            .iter()
            .max_by_key(|(n, _)| *n)
            .ok_or("no RDB$PACKAGES format")?;
        let cols = relation_columns(file, page_size, "RDB$PACKAGES");
        let name_f = cols
            .iter()
            .find(|c| c.name == "RDB$PACKAGE_NAME")
            .map(|c| c.field_id as usize)
            .ok_or("no RDB$PACKAGE_NAME column")?;
        let mut dup = false;
        walk_rows(file, page_size, prel, descs, |v| {
            if text_eq(v.get(name_f), &want) {
                dup = true;
            }
        });
        if dup {
            return Err(format!("Package {} already exists", want));
        }
    }
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    let hdr_blob = dml::insert_blob_cs(file, page_size, prel, &[header.to_vec()], 1, 4)?;
    let body_blob = dml::insert_blob_cs(file, page_size, prel, &[body.to_vec()], 1, 4)?;
    sys_insert(
        file,
        page_size,
        "RDB$PACKAGES",
        prel,
        &[
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$PACKAGE_NAME", SysVal::S(&want)),
            (
                "RDB$PACKAGE_HEADER_SOURCE",
                SysVal::B(blob_id_bytes(prel, hdr_blob)),
            ),
            (
                "RDB$PACKAGE_BODY_SOURCE",
                SysVal::B(blob_id_bytes(prel, body_blob)),
            ),
            ("RDB$VALID_BODY_FLAG", SysVal::I(1)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
        ],
    )?;
    store_privileges(file, page_size, &want, 18, &["X"])?;
    advance_oldest_transactions(file, page_size)
}

/// `CREATE EXCEPTION <name> <message>` - `CreateAlterExceptionNode`
/// (DdlNodes.epp) against the file image. The mirror of CREATE SEQUENCE:
/// a `RDB$EXCEPTIONS` row whose number comes from the system generator
/// *named* `RDB$EXCEPTIONS` (exceptions have their own counter, not the
/// master generator), a `SQL$<n>` security class carrying the owner's ACL
/// - the same alter/control/drop/usage a sequence owner holds - and the
/// owner's USAGE grant (object type 7, `obj_exception`). Unlike a
/// sequence there is no value of its own to store.
pub fn create_exception(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    message: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("an exception needs a name".into());
    }
    if find_exception(file, page_size, &want).is_some() {
        return Err(format!("Exception {} already exists", want));
    }
    let rel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")
        .ok_or("no RDB$EXCEPTIONS relation")?;
    // the number: the system generator named RDB$EXCEPTIONS, one per
    // exception (1, 2, ...); DROP does not give it back
    let slot = generator_id_by_name(file, page_size, "RDB$EXCEPTIONS")
        .ok_or("no RDB$EXCEPTIONS generator")?;
    let number = gen::bump(file, page_size, slot, 1)?;
    let class = next_security_class(file, page_size, ACL_SEQUENCE_OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$EXCEPTIONS",
        rel,
        &[
            ("RDB$SCHEMA_NAME", SysVal::S("PUBLIC")),
            ("RDB$EXCEPTION_NAME", SysVal::S(&want)),
            ("RDB$EXCEPTION_NUMBER", SysVal::I(number)),
            ("RDB$MESSAGE", SysVal::S(message)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
        ],
    )?;
    store_privileges(file, page_size, &want, 7, &["G"])?;
    advance_oldest_transactions(file, page_size)
}

/// `ALTER EXCEPTION <name> <message>` - `CreateAlterExceptionNode` in its
/// alter arm: the message is rewritten in place, the number and security
/// class untouched. The exception must exist ("Exception not found").
pub fn alter_exception(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    message: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if find_exception(file, page_size, &want).is_none() {
        return Err(format!("Exception {} not found", want));
    }
    let erel = crate::resolve_relation(file, page_size, "RDB$EXCEPTIONS")
        .ok_or("no RDB$EXCEPTIONS relation")?;
    let name_fid = sys_fid(file, page_size, "RDB$EXCEPTIONS", "RDB$EXCEPTION_NAME")?;
    let nm = want.clone();
    patch_sys_row(
        file,
        page_size,
        "RDB$EXCEPTIONS",
        erel,
        move |v| text_eq(v.get(name_fid), &nm),
        &[("RDB$MESSAGE", SysVal::S(message))],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `CREATE OR ALTER EXCEPTION <name> <message>`: alter it if it exists
/// (keeping its number and class), otherwise create it.
pub fn create_or_alter_exception(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    message: &str,
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if find_exception(file, page_size, &want).is_some() {
        alter_exception(file, page_size, name, message)
    } else {
        create_exception(file, page_size, name, message)
    }
}

/// `DROP EXCEPTION <name>` - `DropExceptionNode`. The mirror of
/// DROP SEQUENCE, but cleaner: the row, its security class *and* the
/// owner's privilege all go (an engine probe: after the drop the
/// `SQL$<n>` class row is gone, no orphan). The number counter is not
/// rewound - the next exception takes the following number.
pub fn drop_exception(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (_, system, class) = find_exception(file, page_size, &want)
        .ok_or_else(|| format!("Exception {} not found", want))?;
    if system != 0 {
        return Err(format!("Cannot delete system exception {}", want));
    }
    let name_f = sys_fid(file, page_size, "RDB$EXCEPTIONS", "RDB$EXCEPTION_NAME")?;
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$EXCEPTIONS", move |v| {
            text_eq(v.get(name_f), &want)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    {
        let rel_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$RELATION_NAME")?;
        let obj_f = sys_fid(file, page_size, "RDB$USER_PRIVILEGES", "RDB$OBJECT_TYPE")?;
        delete_catalog_rows(file, page_size, "RDB$USER_PRIVILEGES", move |v| {
            text_eq(v.get(rel_f), &want) && int_eq(v.get(obj_f), 7)
        })?;
    }
    advance_oldest_transactions(file, page_size)
}

/// A role's `(RDB$SYSTEM_FLAG, RDB$SECURITY_CLASS)` from `RDB$ROLES`, by
/// name. None when there is no such role.
fn find_role(file: &crate::Image, page_size: usize, name: &str) -> Option<(i64, Option<String>)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$ROLES")?;
    let formats = system_relation_formats(file, page_size, "RDB$ROLES")?;
    let (_, descs) = formats.iter().max_by_key(|(n, _)| *n)?;
    let cols = relation_columns(file, page_size, "RDB$ROLES");
    let fid = |n: &str| cols.iter().find(|c| c.name == n).map(|c| c.field_id as usize);
    let (name_f, sys_f, cls_f) = (
        fid("RDB$ROLE_NAME")?,
        fid("RDB$SYSTEM_FLAG")?,
        fid("RDB$SECURITY_CLASS")?,
    );
    let mut found = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if found.is_some() || !text_eq(v.get(name_f), name) {
            return;
        }
        let sys = match v.get(sys_f) {
            Some(Value::Int(i)) => *i,
            _ => 0,
        };
        let class = match v.get(cls_f) {
            Some(Value::Text(t)) => Some(t.trim_end().to_string()),
            _ => None,
        };
        found = Some((sys, class));
    });
    found
}

/// `CREATE ROLE <name>` - `CreateRoleNode` (DdlNodes.epp) against the file
/// image. The leanest of the security objects: a `RDB$ROLES` row and a
/// `SQL$<n>` security class, and nothing else - no number generator (a
/// role has no number), no `RDB$USER_PRIVILEGES` rows (a role is not
/// something one is granted a privilege *on* by creating it). The owner's
/// ACL is alter/control/drop only, no usage ([ACL_ROLE_OWNER]).
///
/// The one on-disk subtlety: `RDB$SYSTEM_PRIVILEGES` is a CHAR(8) OCTETS,
/// and CREATE ROLE writes it as eight ZERO bytes (an empty system-privilege
/// bitmask) - not NULL, and not the spaces a text CHAR would pad with, so
/// it needs [SysVal::O].
pub fn create_role(
    file: &mut crate::Image,
    page_size: usize,
    name: &str,
    sys_privileges: &[u8],
) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    if want.is_empty() {
        return Err("a role needs a name".into());
    }
    if find_role(file, page_size, &want).is_some() {
        return Err(format!("SQL role {} already exists", want));
    }
    let rel = crate::resolve_relation(file, page_size, "RDB$ROLES")
        .ok_or("no RDB$ROLES relation")?;
    let class = next_security_class(file, page_size, ACL_ROLE_OWNER)?;
    sys_insert(
        file,
        page_size,
        "RDB$ROLES",
        rel,
        &[
            ("RDB$ROLE_NAME", SysVal::S(&want)),
            ("RDB$OWNER_NAME", SysVal::S(OWNER)),
            ("RDB$SECURITY_CLASS", SysVal::S(&class)),
            ("RDB$SYSTEM_FLAG", SysVal::I(0)),
            ("RDB$SYSTEM_PRIVILEGES", SysVal::O(sys_privileges)),
        ],
    )?;
    advance_oldest_transactions(file, page_size)
}

/// `DROP ROLE <name>` - `DropRoleNode`. The row and its security class go
/// (an engine probe: after the drop the `SQL$<n>` class is gone, no
/// orphan); a role owns no privileges of its own to remove.
pub fn drop_role(file: &mut crate::Image, page_size: usize, name: &str) -> Result<(), String> {
    let want = name.trim().trim_matches('"').to_ascii_uppercase();
    let (system, class) = find_role(file, page_size, &want)
        .ok_or_else(|| format!("Role {} not found", want))?;
    if system != 0 {
        return Err(format!("Cannot delete system role {}", want));
    }
    let name_f = sys_fid(file, page_size, "RDB$ROLES", "RDB$ROLE_NAME")?;
    {
        let want = want.clone();
        delete_catalog_rows(file, page_size, "RDB$ROLES", move |v| {
            text_eq(v.get(name_f), &want)
        })?;
    }
    if let Some(class) = class {
        let cls_f = sys_fid(file, page_size, "RDB$SECURITY_CLASSES", "RDB$SECURITY_CLASS")?;
        delete_catalog_rows(file, page_size, "RDB$SECURITY_CLASSES", move |v| {
            text_eq(v.get(cls_f), &class)
        })?;
    }
    advance_oldest_transactions(file, page_size)
}

/// Advance the header's oldest-transaction markers past every
/// transaction this DDL burned, mirroring what a clean engine detach
/// leaves behind (probe: fresh db OIT/OAT/OST/next = 8/9/9/10,
/// post-CREATE 18/19/19/20 - OIT = next-2): two phantom committed
/// transactions, the markers pointing at them. Not what fixed the
/// attach hang (that was RDB$PAGES needing system-transaction
/// records; attach was re-verified fine without this) - but leaving
/// OIT a dozen transactions behind next would misrepresent a cleanly
/// closed database and make every attach start with catch-up work.
fn advance_oldest_transactions(file: &mut crate::Image, page_size: usize) -> Result<(), String> {
    // under a transaction the markers are that transaction's business:
    // it is ACTIVE, and OAT cannot step past it
    if file.ddl_tx.is_some() {
        return Ok(());
    }
    let t1 = dml::allocate_committed_tx(file, page_size)?;
    let t2 = dml::allocate_committed_tx(file, page_size)?;
    let _ = t2;
    let put = |file: &mut crate::Image, at: usize, v: u64| {
        if let Some(hdr) = crate::page_mut(file, page_size, 0) {
            hdr[at..at + 8].copy_from_slice(&v.to_le_bytes());
        }
    };
    put(file, 48, t1); // hdr_oldest_transaction @48
    put(file, 56, t2); // hdr_oldest_active @56
    put(file, 64, t2); // hdr_oldest_snapshot @64
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn used(ns: &[u64]) -> std::collections::HashSet<u64> {
        ns.iter().copied().collect()
    }

    /// A column carrying nothing but its NOT NULL flag, for the
    /// constraint-order tests. `at` is where the NOT NULL clause is
    /// written inside the column's own text.
    fn col_nn(name: &str, at: Option<usize>) -> ColumnDef {
        ColumnDef {
            name: name.to_string(),
            field_type: 8,
            dtype: 8,
            length: 4,
            scale: 0,
            sub_type: 0,
            char_len: None,
            precision: None,
            dims: Vec::new(),
            segment_length: None,
            charset_id: None,
            not_null: at.is_some(),
            not_null_constraint: at.is_some(),
            not_null_at: at.unwrap_or(0),
            default: None,
            domain: None,
            identity: None,
            computed: None,
        }
    }

    /// A plain nullable column.
    fn col(name: &str) -> ColumnDef {
        col_nn(name, None)
    }

    fn key_at(place: ConstraintPlace, primary: bool) -> TableConstraint {
        TableConstraint {
            kind: ConstraintKind::Key(KeyDef {
                name: String::new(),
                columns: Vec::new(),
                primary,
            }),
            place,
        }
    }

    /// A FOREIGN KEY at `place` - only its seat matters to
    /// [constraint_steps], the partner and the actions never do.
    fn fk_at(place: ConstraintPlace) -> ForeignKeyDef {
        ForeignKeyDef {
            name: String::new(),
            columns: Vec::new(),
            ref_table: "P".into(),
            ref_columns: Vec::new(),
            on_update: RefAction::Restrict,
            on_delete: RefAction::Restrict,
            place,
        }
    }

    fn check_at(place: ConstraintPlace) -> TableConstraint {
        TableConstraint {
            kind: ConstraintKind::Check(CheckDef {
                name: String::new(),
                source: String::new(),
                trigger_blr: Vec::new(),
                fields: Vec::new(),
            }),
            place,
        }
    }

    /// `M1 (ID INTEGER NOT NULL PRIMARY KEY, C INTEGER UNIQUE,
    ///      D VARCHAR(10) NOT NULL)`
    /// -> INTEG_1 NOT NULL (ID), INTEG_2 PRIMARY KEY, INTEG_3 UNIQUE,
    ///    INTEG_4 NOT NULL (D)  [measured on the engine].
    ///
    /// Every constraint here is COLUMN-LEVEL, so pass 1 alone orders
    /// them and the answer reads like plain declaration order - which is
    /// exactly why the superseded single-pass rule fitted this shape and
    /// nothing else.
    #[test]
    fn every_constraint_inline_reads_as_declaration_order() {
        //         ID INTEGER NOT NULL PRIMARY KEY
        //         0          11       20
        let cols = [col_nn("ID", Some(11)), col("C"), col_nn("D", Some(14))];
        let cs = [
            key_at(ConstraintPlace::Inline { col: 0, at: 20 }, true),
            key_at(ConstraintPlace::Inline { col: 1, at: 10 }, false),
        ];
        assert_eq!(
            constraint_steps(&cols, &cs, &[]),
            vec![
                ConstraintStep::NotNull(0), // INTEG_1
                ConstraintStep::Table(0),   // INTEG_2 - the PRIMARY KEY
                ConstraintStep::Table(1),   // INTEG_3 - the UNIQUE
                ConstraintStep::NotNull(2), // INTEG_4
            ]
        );
    }

    /// THE DECISIVE SHAPE. `M2 (A INTEGER, UNIQUE (A), B INTEGER
    /// UNIQUE)` -> INTEG_5 UNIQUE on B, INTEG_6 UNIQUE on A (measured):
    /// the inline UNIQUE written LAST is numbered FIRST, because it is
    /// column-level and the `UNIQUE (A)` ahead of it is table-level. No
    /// single-pass text order can produce this, which is what forced the
    /// pass discriminator into [ConstraintPlace].
    #[test]
    fn an_inline_constraint_outranks_an_earlier_table_level_one() {
        let cols = [col("A"), col("B")];
        let cs = [
            key_at(ConstraintPlace::Table { decl: 1 }, false),         // UNIQUE (A)
            key_at(ConstraintPlace::Inline { col: 1, at: 10 }, false), // B ... UNIQUE
        ];
        assert_eq!(
            constraint_steps(&cols, &cs, &[]),
            vec![
                ConstraintStep::Table(1), // INTEG_5 - B's inline UNIQUE
                ConstraintStep::Table(0), // INTEG_6 - the table-level UNIQUE (A)
            ]
        );
    }

    /// `M4 (A INTEGER NOT NULL, B INTEGER, UNIQUE (B), C INTEGER NOT
    /// NULL, PRIMARY KEY (A))` -> NOT NULL, NOT NULL, UNIQUE, PRIMARY
    /// KEY (measured): BOTH NOT NULLs (pass 1) before BOTH table-level
    /// keys (pass 2), even though `UNIQUE (B)` is written between them.
    /// This is the shape the strict-declaration-order rule broke.
    #[test]
    fn both_passes_run_to_completion_in_turn() {
        let cols = [col_nn("A", Some(10)), col("B"), col_nn("C", Some(10))];
        let cs = [
            key_at(ConstraintPlace::Table { decl: 2 }, false), // UNIQUE (B)
            key_at(ConstraintPlace::Table { decl: 4 }, true),  // PRIMARY KEY (A)
        ];
        assert_eq!(
            constraint_steps(&cols, &cs, &[]),
            vec![
                ConstraintStep::NotNull(0), // INTEG_11
                ConstraintStep::NotNull(2), // INTEG_12
                ConstraintStep::Table(0),   // INTEG_13 - UNIQUE (B)
                ConstraintStep::Table(1),   // INTEG_14 - PRIMARY KEY (A)
            ]
        );
    }

    /// `M5 (A INTEGER CHECK (A > 0), B INTEGER NOT NULL, CHECK (B <
    /// 100), C INTEGER UNIQUE)` -> CHECK on A, NOT NULL on B, UNIQUE on
    /// C, the table-level CHECK (measured): the same two passes shown
    /// independently with CHECKs, the table-level one written between
    /// `B` and `C` landing after `C`'s inline UNIQUE.
    #[test]
    fn a_table_level_check_follows_every_inline_constraint() {
        let cols = [col("A"), col_nn("B", Some(10)), col("C")];
        let cs = [
            check_at(ConstraintPlace::Inline { col: 0, at: 10 }), // A ... CHECK (A > 0)
            check_at(ConstraintPlace::Table { decl: 2 }),         // CHECK (B < 100)
            key_at(ConstraintPlace::Inline { col: 2, at: 10 }, false), // C ... UNIQUE
        ];
        assert_eq!(
            constraint_steps(&cols, &cs, &[]),
            vec![
                ConstraintStep::Table(0),   // INTEG_15 - A's inline CHECK
                ConstraintStep::NotNull(1), // INTEG_16 - B's NOT NULL
                ConstraintStep::Table(2),   // INTEG_17 - C's inline UNIQUE
                ConstraintStep::Table(1),   // INTEG_18 - the table-level CHECK
            ]
        );
    }

    /// WITHIN ONE COLUMN it is plain text order: `N1 (A INTEGER UNIQUE
    /// NOT NULL, B INTEGER)` -> UNIQUE then NOT NULL, and `N2 (A INTEGER
    /// NOT NULL UNIQUE, B INTEGER)` -> NOT NULL then UNIQUE (both
    /// measured). The same two clauses swap numbers when the text swaps
    /// them - which a per-column count could not express at all.
    #[test]
    fn within_one_column_the_clauses_follow_the_text() {
        // A INTEGER UNIQUE NOT NULL
        // 0         10     17
        let n1_cols = [col_nn("A", Some(17)), col("B")];
        let n1 = [key_at(ConstraintPlace::Inline { col: 0, at: 10 }, false)];
        assert_eq!(
            constraint_steps(&n1_cols, &n1, &[]),
            vec![ConstraintStep::Table(0), ConstraintStep::NotNull(0)]
        );
        // A INTEGER NOT NULL UNIQUE
        // 0         10       19
        let n2_cols = [col_nn("A", Some(10)), col("B")];
        let n2 = [key_at(ConstraintPlace::Inline { col: 0, at: 19 }, false)];
        assert_eq!(
            constraint_steps(&n2_cols, &n2, &[]),
            vec![ConstraintStep::NotNull(0), ConstraintStep::Table(0)]
        );
    }

    /// A column-level PRIMARY KEY IMPLIES the NOT NULL, and the implied
    /// row is numbered just BEFORE the key: `(A INTEGER PRIMARY KEY, B
    /// INTEGER)` -> INTEG_1 NOT NULL, INTEG_2 PRIMARY KEY, and even
    /// `(A INTEGER PRIMARY KEY NOT NULL, B INTEGER)` -> NOT NULL then
    /// PRIMARY KEY though the text reads the other way (both measured).
    /// The caller stamps the EARLIER of the two offsets on the column,
    /// and the stable sort keeps the NOT NULL ahead of the key on a tie.
    #[test]
    fn an_implied_not_null_is_numbered_just_before_its_key() {
        // A INTEGER PRIMARY KEY  - nothing else written, so both at 10
        let cols = [col_nn("A", Some(10)), col("B")];
        let cs = [key_at(ConstraintPlace::Inline { col: 0, at: 10 }, true)];
        assert_eq!(
            constraint_steps(&cols, &cs, &[]),
            vec![ConstraintStep::NotNull(0), ConstraintStep::Table(0)]
        );
    }

    /// A FOREIGN KEY is the FOURTH KIND OF CONSTRAINT, not a fourth
    /// thing that always comes last: it takes its number where it is
    /// written, in the same two passes as a key, a CHECK or a NOT NULL.
    /// All four shapes measured on the engine through 127.0.0.1/3050,
    /// both servers' files read back BY THE ENGINE:
    ///
    /// - `F1 (A INTEGER, UNIQUE (A), B INTEGER REFERENCES P)` ->
    ///   FOREIGN KEY on B, then UNIQUE on A. The M2 inversion on a
    ///   fourth constraint kind: the INLINE clause written LAST takes
    ///   the LOWER number, because it is column-level.
    /// - `G1 (A INTEGER, B INTEGER, FOREIGN KEY (A) REFERENCES P,
    ///   UNIQUE (B))` -> FOREIGN KEY, then UNIQUE. Two TABLE-level
    ///   clauses of different kinds, ordered by declaration.
    /// - `G2 (..., UNIQUE (B), FOREIGN KEY (A) REFERENCES P)` ->
    ///   UNIQUE, then FOREIGN KEY - the same two clauses, swapped in
    ///   the text, swapped in the answer. G1 and G2 together are what
    ///   an FK-last writer cannot do: it is right on G2 by luck and
    ///   wrong on G1.
    /// - `G3 (..., FOREIGN KEY (A) REFERENCES P, CHECK (B > 0))` ->
    ///   FOREIGN KEY, then CHECK. The same, against a CHECK.
    #[test]
    fn a_foreign_key_is_numbered_where_it_is_written() {
        // F1: the inline REFERENCES on B outranks the table-level
        // UNIQUE (A) written ahead of it
        let cols = [col("A"), col("B")];
        assert_eq!(
            constraint_steps(
                &cols,
                &[key_at(ConstraintPlace::Table { decl: 1 }, false)],
                &[fk_at(ConstraintPlace::Inline { col: 1, at: 10 })],
            ),
            vec![ConstraintStep::Fk(0), ConstraintStep::Table(0)]
        );
        // G1: FOREIGN KEY written first, numbered first
        assert_eq!(
            constraint_steps(
                &cols,
                &[key_at(ConstraintPlace::Table { decl: 3 }, false)],
                &[fk_at(ConstraintPlace::Table { decl: 2 })],
            ),
            vec![ConstraintStep::Fk(0), ConstraintStep::Table(0)]
        );
        // G2: the same two, swapped in the text
        assert_eq!(
            constraint_steps(
                &cols,
                &[key_at(ConstraintPlace::Table { decl: 2 }, false)],
                &[fk_at(ConstraintPlace::Table { decl: 3 })],
            ),
            vec![ConstraintStep::Table(0), ConstraintStep::Fk(0)]
        );
        // G3: against a table-level CHECK
        assert_eq!(
            constraint_steps(
                &cols,
                &[check_at(ConstraintPlace::Table { decl: 3 })],
                &[fk_at(ConstraintPlace::Table { decl: 2 })],
            ),
            vec![ConstraintStep::Fk(0), ConstraintStep::Table(0)]
        );
    }

    /// `F2 (A INTEGER, FOREIGN KEY (A) REFERENCES P, B INTEGER NOT
    /// NULL)` -> NOT NULL on B, then FOREIGN KEY on A (measured): the
    /// TABLE-level foreign key written BEFORE column B still lands
    /// after B's column-level NOT NULL, because the passes are about
    /// WHERE A CLAUSE IS ATTACHED and not about what kind it is.
    #[test]
    fn a_table_level_fk_still_follows_every_inline_constraint() {
        let cols = [col("A"), col_nn("B", Some(10))];
        assert_eq!(
            constraint_steps(&cols, &[], &[fk_at(ConstraintPlace::Table { decl: 1 })]),
            vec![ConstraintStep::NotNull(1), ConstraintStep::Fk(0)]
        );
    }

    /// THE TYPE-COMPATIBILITY RULE FOR A FOREIGN KEY, measured on the
    /// engine at 127.0.0.1/3050 on 2026-09-03 by building a parent table
    /// per type and a child column per type against it and reading back
    /// which `CREATE TABLE ... REFERENCES` it accepted (24 x 24 pairs,
    /// plus precision, charset, collation and domain probes). What it
    /// refuses it refuses with `partner index segment no 1 has
    /// incompatible data type`, and a database carrying such a key
    /// cannot be restored by `gbak -c`.
    ///
    /// The rows this pins, each measured:
    ///
    /// - SMALLINT, INTEGER, FLOAT, DOUBLE and NUMERIC(p <= 9) key
    ///   together; SMALLINT onto INTEGER is accepted by BOTH servers.
    /// - BIGINT keys with NUMERIC(10..18) and with nothing narrower:
    ///   INTEGER onto BIGINT is refused, and so is NUMERIC(9,0) onto
    ///   NUMERIC(10,0) - the boundary is the PRECISION, because the
    ///   precision picks the storage type.
    /// - INT128 keys with NUMERIC(19..38) and not with BIGINT.
    /// - DATE, TIME and TIMESTAMP are three classes, and each TIME ZONE
    ///   type is its own (TIMESTAMP onto TIMESTAMP WITH TIME ZONE is
    ///   refused).
    /// - DECFLOAT(16) and DECFLOAT(34) key TOGETHER - the one pair of
    ///   different dtypes that share a class.
    /// - a string's LENGTH and CHAR-vs-VARCHAR never matter
    ///   (VARCHAR(80) keys against CHAR(5)), but its CHARACTER SET and
    ///   its COLLATION both do (NONE, OCTETS and WIN1252 are three
    ///   classes; UTF8 and UTF8 COLLATE UNICODE are two).
    /// - BLOB cannot be a key at all, on either side.
    #[test]
    fn a_foreign_key_partner_must_key_the_same_way() {
        use crate::format::dtype;
        let d = |dtype: u8, length: u16, scale: i8, sub_type: i16| Descriptor {
            dtype,
            scale,
            length,
            sub_type,
            flags: 0,
            offset: 0,
        };
        let same = |a: &Descriptor, b: &Descriptor| key_class(a) == key_class(b);
        let short = d(dtype::SHORT, 2, 0, 0);
        let long = d(dtype::LONG, 4, 0, 0);
        let num92 = d(dtype::LONG, 4, -2, 1); // NUMERIC(9,2)
        let dbl = d(dtype::DOUBLE, 8, 0, 0);
        let flt = d(dtype::REAL, 4, 0, 0);
        let i64_ = d(dtype::INT64, 8, 0, 0);
        let num182 = d(dtype::INT64, 8, -2, 1); // NUMERIC(18,2)
        let i128_ = d(dtype::INT128, 16, 0, 0);
        // one class: the small exact ints, the floats, and NUMERIC(p<=9)
        for x in [&short, &num92, &dbl, &flt] {
            assert!(same(&long, x));
        }
        // and NOT with the int64 class, nor int64 with int128
        assert!(!same(&long, &i64_));
        assert!(same(&i64_, &num182));
        assert!(!same(&i64_, &i128_));
        // the date/time family: three classes, and the zoned ones apart
        let date = d(dtype::SQL_DATE, 4, 0, 0);
        let time = d(dtype::SQL_TIME, 4, 0, 0);
        let ts = d(dtype::TIMESTAMP, 8, 0, 0);
        let tstz = d(dtype::TIMESTAMP_TZ, 12, 0, 0);
        assert!(!same(&date, &time) && !same(&time, &ts) && !same(&date, &ts));
        assert!(!same(&ts, &tstz));
        // DECFLOAT(16) and DECFLOAT(34) key together
        assert!(same(&d(dtype::DEC64, 8, 0, 0), &d(dtype::DEC128, 16, 0, 0)));
        assert!(!same(&d(dtype::DEC64, 8, 0, 0), &dbl));
        // text: length and CHAR-vs-VARCHAR are nothing, ttype is all
        let char_none_5 = d(dtype::TEXT, 5, 0, 0);
        let varchar_none_80 = d(dtype::VARYING, 82, 0, 0);
        let varchar_utf8 = d(dtype::VARYING, 42, 0, 4);
        let varchar_utf8_unicode = d(dtype::VARYING, 42, 0, (2 << 8) | 4);
        let char_octets = d(dtype::TEXT, 5, 0, 1);
        assert!(same(&char_none_5, &varchar_none_80));
        assert!(!same(&char_none_5, &varchar_utf8));
        assert!(!same(&char_none_5, &char_octets));
        assert!(!same(&varchar_utf8, &varchar_utf8_unicode));
        assert!(same(&varchar_utf8, &d(dtype::TEXT, 40, 0, 4)));
        // a text column never keys with a number
        assert!(!same(&char_none_5, &long));
        // and a BLOB is no key at all
        assert!(key_class(&d(dtype::BLOB, 8, 0, 1)).is_none());
    }

    /// `NO ACTION` is its OWN stored rule. It behaves exactly as
    /// `RESTRICT` - neither synthesises a trigger - but the engine
    /// writes back what was written: `ON DELETE NO ACTION` stores
    /// `RDB$DELETE_RULE = 'NO ACTION'` where an omitted clause and an
    /// explicit `RESTRICT` store `'RESTRICT'` (measured, both files read
    /// back by the engine). Collapsing the two was a silent wrong write
    /// that survived gbak.
    #[test]
    fn no_action_is_stored_as_no_action_and_still_makes_no_trigger() {
        assert_eq!(RefAction::NoAction.rule(), "NO ACTION");
        assert_eq!(RefAction::Restrict.rule(), "RESTRICT");
        // EVERY stored rule reads back as the action that wrote it -
        // the catalog is where a server learns what to DO, so the round
        // trip is the law and an unknown rule is refused, not guessed
        for a in [
            RefAction::Restrict,
            RefAction::NoAction,
            RefAction::Cascade,
            RefAction::SetNull,
            RefAction::SetDefault,
        ] {
            assert_eq!(RefAction::from_rule(a.rule()), Some(a), "{:?}", a);
            // as the catalog hands it over: CHAR-padded
            assert_eq!(RefAction::from_rule(&format!("{}    ", a.rule())), Some(a));
        }
        assert_eq!(RefAction::from_rule(""), None);
        assert_eq!(RefAction::from_rule("SET  NULL"), None);
        assert_eq!(RefAction::from_rule("cascade"), None);
        assert!(!RefAction::NoAction.synthesises_trigger());
        assert!(!RefAction::Restrict.synthesises_trigger());
        for a in [RefAction::Cascade, RefAction::SetNull, RefAction::SetDefault] {
            assert!(a.synthesises_trigger());
        }
    }

    /// Nothing is dropped and nothing is written twice, whatever the
    /// places are: every column with a NOT NULL and every constraint
    /// appears exactly once, the table-level ones keeping declaration
    /// order among themselves.
    #[test]
    fn every_constraint_is_written_exactly_once() {
        let cols = [col_nn("A", Some(3)), col_nn("B", Some(9)), col("C")];
        for cs in [
            vec![],
            vec![key_at(ConstraintPlace::Table { decl: 0 }, true)],
            vec![
                key_at(ConstraintPlace::Table { decl: 0 }, true),
                check_at(ConstraintPlace::Table { decl: 1 }),
            ],
            vec![
                check_at(ConstraintPlace::Inline { col: 0, at: 20 }),
                key_at(ConstraintPlace::Inline { col: 0, at: 1 }, false),
                check_at(ConstraintPlace::Table { decl: 2 }),
            ],
            vec![
                check_at(ConstraintPlace::Table { decl: 0 }),
                key_at(ConstraintPlace::Inline { col: 2, at: 5 }, false),
                check_at(ConstraintPlace::Table { decl: 2 }),
            ],
        ] {
            let steps = constraint_steps(&cols, &cs, &[]);
            let mut tables: Vec<usize> = steps
                .iter()
                .filter_map(|s| match s {
                    ConstraintStep::Table(i) => Some(*i),
                    _ => None,
                })
                .collect();
            let nn: Vec<usize> = steps
                .iter()
                .filter_map(|s| match s {
                    ConstraintStep::NotNull(i) => Some(*i),
                    _ => None,
                })
                .collect();
            assert_eq!(nn, vec![0, 1], "the NOT NULL rows, in column order");
            // the TABLE-level ones keep declaration order among themselves
            let table_only: Vec<usize> = tables
                .iter()
                .copied()
                .filter(|i| matches!(cs[*i].place, ConstraintPlace::Table { .. }))
                .collect();
            let mut sorted_table_only = table_only.clone();
            sorted_table_only.sort_unstable();
            assert_eq!(
                table_only, sorted_table_only,
                "the table-level clauses left declaration order"
            );
            tables.sort_unstable();
            tables.dedup();
            assert_eq!(tables.len(), cs.len(), "a constraint was dropped or doubled");
        }
    }

    /// A fresh database's name counters read 0 and their first name is
    /// 1 (probed: RDB$INDEX_NAME is 0 in a just-created database and 1
    /// after the first generated index name); the counter keeps the
    /// number last issued.
    #[test]
    fn a_name_counter_issues_one_first_and_keeps_the_last_issued() {
        assert_eq!(counter_run(0, false, 1, 1), (1, 1));
        assert_eq!(counter_run(1, false, 1, 1), (2, 2));
        assert_eq!(counter_run(7, false, 1, 1), (8, 8));
    }

    /// RDB$RELATIONS spells it the other way: it holds the id to use
    /// NEXT. A fresh database reads 128 and its first table IS 128
    /// (probed), leaving 129 behind.
    #[test]
    fn the_relation_counter_issues_what_it_holds() {
        assert_eq!(counter_run(128, true, 128, 1), (128, 129));
        assert_eq!(counter_run(131, true, 128, 1), (131, 132));
    }

    /// A statement that mints several names at once takes them
    /// consecutively and leaves the counter past the whole run.
    #[test]
    fn a_run_of_names_is_consecutive() {
        assert_eq!(counter_run(5, false, 1, 3), (6, 8));
        assert_eq!(counter_run(128, true, 128, 2), (128, 130));
    }

    /// A counter below its floor is lifted to it: a relation id is never
    /// below 128 whatever the counter says.
    #[test]
    fn the_floor_wins_over_a_lagging_counter() {
        assert_eq!(counter_run(0, true, 128, 1), (128, 129));
        assert_eq!(counter_run(0, false, 1, 1), (1, 1));
    }

    /// The whole point of the counter: a number a DROP gave back is NOT
    /// re-issued. The catalog no longer holds RDB$PRIMARY2, and the
    /// counter still hands out 3.
    #[test]
    fn a_dropped_number_is_not_re_issued() {
        assert_eq!(pick_run(2, false, 1, 1, &used(&[1])), Some((3, 3)));
    }

    /// A counter that lags behind the objects already written (a
    /// database restored from a backup, or one an older fire-crab wrote
    /// by scanning) steps over every number in use instead of naming a
    /// second object what the first is called.
    #[test]
    fn a_lagging_counter_steps_over_what_is_in_use() {
        assert_eq!(pick_run(0, false, 1, 1, &used(&[1, 2, 3])), Some((4, 4)));
        assert_eq!(pick_run(0, true, 128, 1, &used(&[128, 129])), Some((130, 131)));
        // and it heals: the counter is left past the collision, so the
        // next draw is one step, not another walk
        let (_, store) = pick_run(0, false, 1, 1, &used(&[1, 2, 3])).unwrap();
        assert_eq!(pick_run(store, false, 1, 1, &used(&[1, 2, 3])), Some((5, 5)));
    }

    /// A run is placed whole: a free number inside an otherwise taken
    /// run does not make the run free.
    #[test]
    fn a_run_needs_every_number_of_it_free() {
        assert_eq!(pick_run(0, false, 1, 3, &used(&[2])), Some((4, 6)));
        assert_eq!(pick_run(0, false, 1, 2, &used(&[2])), Some((3, 4)));
        // a run clear of everything in use is taken where it lies
        assert_eq!(pick_run(0, false, 1, 2, &used(&[3])), Some((1, 2)));
    }

    /// Whatever it returns is free, and it always moves the counter past
    /// what it returned - the invariant that stops two objects sharing a
    /// name.
    #[test]
    fn a_drawn_run_is_free_and_the_counter_moves_past_it() {
        let taken = used(&[1, 2, 4, 5, 7]);
        for count in 1..4u64 {
            for cur in 0..10u64 {
                let (first, store) = pick_run(cur, false, 1, count, &taken).unwrap();
                assert!(first > cur, "cur {} gave {}", cur, first);
                for n in first..first + count {
                    assert!(!taken.contains(&n), "drew a used number {}", n);
                }
                assert_eq!(store, first + count - 1);
            }
        }
    }

    #[test]
    fn blob_id_bytes_round_trip() {
        let b = blob_id_bytes(8, 5);
        assert_eq!(&b[0..2], &8u16.to_le_bytes());
        assert_eq!(&b[4..8], &5u32.to_le_bytes());
    }

    /// Golden bytes probed from the engine's own SET DEFAULT triggers
    /// (RDB$TRIGGER_BLR of `FOREIGN KEY (X) REFERENCES P (ID) ON DELETE
    /// SET DEFAULT` and friends): the variable preamble that fetches the
    /// child column's default at RUNTIME, then the SET NULL skeleton
    /// assigning the variables, all inside an outer begin.
    #[test]
    fn set_default_trigger_blr_matches_engine() {
        let one = |s: &str| vec![s.to_string()];
        // ON DELETE SET DEFAULT, single column (probe table C1)
        let del = fk_trigger_blr(false, RefAction::SetDefault, "C1", &one("X"), &one("ID"));
        let want_hex = "05020300001500024331015803010015010243310158012D1A00008102B80100011A01001A0000FF8201000402FFFF0743014A02433102472F170201581700024944FF0A020202011A000017020158FFFF4C";
        let want: Vec<u8> = (0..want_hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&want_hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(del, want);
        // ON UPDATE SET DEFAULT, single column (probe table C2)
        let upd = fk_trigger_blr(true, RefAction::SetDefault, "C2", &one("X"), &one("ID"));
        let want_hex = "05020300001500024332015803010015010243320158012D1A00008102B80100011A01001A0000FF8201000402FFFF08301700024944170102494402020743014A02433202472F170201581700024944FF0A020202011A000017020158FFFFFFFFFF4C";
        let want: Vec<u8> = (0..want_hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&want_hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(upd, want);
        // ON DELETE SET DEFAULT, TWO columns (probe table C3): per-column
        // variable pairs (0,1) and (2,3), AND-chained match, both assigned
        let del2 = fk_trigger_blr(
            false,
            RefAction::SetDefault,
            "C3",
            &["X".to_string(), "Y".to_string()],
            &["A".to_string(), "B".to_string()],
        );
        let want_hex = "05020300001500024333015803010015010243330158012D1A00008102B80100011A01001A0000FF8201000402FFFF0302001500024333015903030015010243330159012D1A02008102B80300011A03001A0200FF8201000402FFFF0743014A02433302473A2F17020158170001412F1702015917000142FF0A020202011A000017020158011A020017020159FFFF4C";
        let want: Vec<u8> = (0..want_hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&want_hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(del2, want);
    }

    #[test]
    fn format_blob_payload_shape() {
        // the descriptor pack must byte-match the engine's probe blob:
        // INTEGER at offset 4 in a 4-col format packs as
        // 09 00 04 00 00 00 00 00 04 00 00 00
        let descs = compute_format(&[
            (crate::format::dtype::LONG, 4, 0, 0),
            (crate::format::dtype::VARYING, 22, 0, 0),
            (crate::format::dtype::INT64, 8, 0, 0),
            (crate::format::dtype::SHORT, 2, 0, 0),
        ]);
        assert_eq!(descs.len(), 4);
        assert_eq!(
            (descs[0].offset, descs[1].offset, descs[2].offset, descs[3].offset),
            (4, 8, 32, 40) // FLAG_BYTES(4)=4; int64 aligns to 8
        );
        assert_eq!(flag_bytes(4), 4);
        let _ = (u16_at(&[0, 0], 0), DPG_RPT_OFFSET, RHD_DATA_OFFSET); // linkage
    }
}




/// A collation by NAME, wherever it lives: `(charset id, collation id,
/// is a SYSTEM collation)`.
///
/// A collation belongs to ONE character set, so a caller that meant it
/// for another operand has to tell "no such collation" from "not that
/// character set's" - and the two spell their error differently (the
/// schema in the message is `SYSTEM` for a built-in, `PUBLIC` for a
/// user one).
pub fn collation_lookup(
    file: &crate::Image,
    page_size: usize,
    name: &str,
) -> Option<(i64, i64, bool)> {
    let rel = crate::resolve_relation(file, page_size, "RDB$COLLATIONS")?;
    let fmts = system_relation_formats(file, page_size, "RDB$COLLATIONS")?;
    let (_, descs) = fmts.iter().max_by_key(|(n, _)| *n)?;
    let nf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$COLLATION_NAME").ok()?;
    let csf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$CHARACTER_SET_ID").ok()?;
    let idf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$COLLATION_ID").ok()?;
    let sysf = sys_fid(file, page_size, "RDB$COLLATIONS", "RDB$SYSTEM_FLAG").ok()?;
    let mut out = None;
    walk_rows(file, page_size, rel, descs, |v| {
        if !text_eq(v.get(nf), name) {
            return;
        }
        let int_of = |x: Option<&Value>| match x {
            Some(Value::Int(n)) => Some(*n),
            _ => None,
        };
        if let (Some(cs), Some(id)) = (int_of(v.get(csf)), int_of(v.get(idf))) {
            out = Some((cs, id, int_of(v.get(sysf)).unwrap_or(0) != 0));
        }
    });
    out
}
