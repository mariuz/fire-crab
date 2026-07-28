//! SQL -> BLR: the conversion of the engine's `src/dsql/` - the
//! compiler that turns a SQL statement into the BLR the executor runs.
//!
//! THE ORACLE IS `RDB$VIEW_BLR`. When the ENGINE runs `CREATE VIEW v AS
//! <select>`, its own DSQL compiles the SELECT and stores the resulting
//! BLR verbatim in the catalog - so every byte this crate emits can be
//! compared against the engine's own output for the identical statement
//! (`qa/dsql-view-blr.sh`). No layout here is guessed: each was read
//! back from a probe view and pinned in the unit tests below.
//!
//! The first slice covers the single-relation SELECT shape a view
//! stores:
//!
//!   blr_version5,
//!   blr_rse, 1,
//!     blr_relation, <len>, '<TABLE>', <context 1>,
//!     [ blr_boolean, <boolean tree> ]
//!     blr_end,
//!   blr_eoc
//!
//! Probed laws (each a unit test and a gate check):
//!
//!   * the view's BLR is the RSE ALONE - the select list leaves no
//!     trace (`SELECT ID` and `SELECT ID, A` compile identically; the
//!     column mapping lives positionally in RDB$RELATION_FIELDS)
//!   * NOT is compiled AWAY where an inverse exists: `NOT (A > 5)`
//!     stores blr_leq, and De Morgan pushes through AND/OR
//!     (`NOT (x OR y)` stores blr_and of the negations); blr_not
//!     survives only over LIKE and MISSING
//!   * `NOT BETWEEN lo AND hi` expands to `blr_or(blr_lss lo,
//!     blr_gtr hi)` while plain BETWEEN stays blr_between
//!   * IS NULL is blr_missing; IS NOT NULL is blr_not(blr_missing)
//!   * an integer literal is blr_long scale 0, little-endian; a decimal
//!     literal keeps its written scale (12.50 -> scale -2, raw 1250);
//!     a string literal is blr_text2 with a 2-byte charset and a
//!     2-byte length (charset 0 in a NONE-charset database)
//!   * AND/OR chains nest LEFT-associatively
//!
//! Slice 2 (same oracle) added VALUE EXPRESSIONS (blr_add/subtract/
//! multiply/divide/negate/concatenate - a sign before a numeric
//! literal FOLDS into it, blr_negate survives only before fields),
//! IN lists (blr_in_list with a little-endian u16 count; NOT IN keeps
//! a real blr_not), and MULTI-STREAM RSEs: comma-FROM lists and INNER
//! JOIN ... ON (blr_join nesting like an rse, its ON clause a
//! boolean sub-clause), with aliases stored as blr_relation2 whose
//! alias text is the UPPERCASED name in DOUBLE QUOTES (probed:
//! `FROM T x` stores alias "X", quotes included). Fields carry their
//! stream's context id; in a multi-stream statement every field must
//! be QUALIFIED (the engine resolves bare names through the catalog;
//! this catalog-free slice refuses them rather than guess a context).
//!
//! Slice 3 (same oracle) added OUTER JOINS (blr_join_type after the
//! streams, before the ON boolean: 1=LEFT, 2=RIGHT, 3=FULL - absent
//! for INNER; `LEFT OUTER JOIN` compiles byte-identical to `LEFT
//! JOIN`), JOIN CHAINS (each ON binds LEFT, so the second join's node
//! holds the first join's node as its first stream slot - the chain
//! nests left, and a type byte sits only on its own node), INT64
//! LITERALS (blr_int64: dtype 0x10, one scale byte, 8 little-endian
//! bytes - the sign still folds in), and the first BUILT-IN FUNCTIONS:
//! blr_upcase/blr_lowcase (one operand), blr_strlen with a length-type
//! byte (CHAR_LENGTH=1, OCTET_LENGTH=2), blr_substring whose start is
//! 0-BASED and compiled as `blr_subtract(<from>, 1)` UNFOLDED (probed:
//! `FROM 1` stores subtract(1,1), not literal 0), and blr_trim with a
//! where byte (0=BOTH, 1=LEADING, 2=TRAILING) and a spec byte (0=trim
//! spaces, 1=an explicit <what> operand follows; a bare
//! `TRIM('a' FROM s)` is BOTH). An unknown name followed by `(` is a
//! UDF or an unconverted built-in and REFUSES - it must never fall
//! back to being read as a field.
//!
//! Slice 4 (same oracle) added CAST (blr_cast + a dsc whose layouts
//! were probed target by target: NUMERIC(p<=4) is SHORT but
//! DECIMAL(p<=9) is ALWAYS LONG, p 10..=18 is INT64, texts carry a
//! charset word and a length word, temporals are a bare dtype) and
//! the CONDITIONALS with their two compiled shapes: the searched CASE
//! and IIF (byte-identical sugar) are ONE blr_cast over a blr_value_if
//! chain - each further WHEN nests in the ELSE slot, a missing ELSE is
//! blr_null - where the cast's descriptor is the branches' UNIFIED
//! type; the simple CASE is blr_decode (count byte, comparands, count
//! byte, results; the ELSE is one extra result) and COALESCE is
//! blr_coalesce (count byte, values), both WITHOUT a cast wrapper.
//! NULLIF(a, b) is cast(value_if(a = b, NULL, a)) - its dsc comes from
//! the BRANCHES (NULL and a), never from b. The unification law,
//! probed: NULL branches are ignored, text branches take blr_text2 at
//! the MAX length, exact numerics take MAX integer digits + MIN scale
//! and the dtype that FITS the total (<=4 short, <=9 long, else
//! int64) - so long(0) united with long(-1) WIDENS to int64. A FIELD
//! branch under a cast wrapper refuses: its descriptor lives in the
//! catalog, and this compiler never guesses one.

/// The BLR bytes this slice emits, every constant read back from the
/// engine's own stored view BLR (see the module doc).
mod blr {
    pub const VERSION5: u8 = 0x05;
    pub const RSE: u8 = 0x43;
    /// the relation stream verb the engine stores for a view's table
    /// (counted name + context id)
    pub const RELATION: u8 = 0x4A;
    /// the rse sub-clause introducing the WHERE tree
    pub const BOOLEAN: u8 = 0x47;
    pub const END: u8 = 0xFF;
    pub const EOC: u8 = 0x4C;
    pub const FIELD: u8 = 0x17;
    pub const LITERAL: u8 = 0x15;
    /// literal dtypes
    pub const LONG: u8 = 0x08;
    pub const TEXT2: u8 = 0x0F;
    /// booleans
    pub const AND: u8 = 0x3A;
    pub const OR: u8 = 0x39;
    pub const NOT: u8 = 0x3B;
    pub const MISSING: u8 = 0x3D;
    pub const BETWEEN: u8 = 0x38;
    pub const LIKE: u8 = 0x3F;
    pub const ADD: u8 = 0x22;
    pub const SUBTRACT: u8 = 0x23;
    pub const MULTIPLY: u8 = 0x24;
    pub const DIVIDE: u8 = 0x25;
    pub const NEGATE: u8 = 0x26;
    pub const CONCATENATE: u8 = 0x27;
    /// FB5+'s dedicated IN-list verb: value, u16 count, values
    pub const IN_LIST: u8 = 0x40;
    /// an explicit join: stream count, streams, sub-clauses, blr_end -
    /// nested inside the rse like a stream
    pub const JOIN: u8 = 0x77;
    /// a relation WITH AN ALIAS: counted name, counted alias (the
    /// alias travels UPPERCASED IN DOUBLE QUOTES - probed), context
    pub const RELATION2: u8 = 0x92;
    /// join-type sub-clause inside blr_join: absent for INNER,
    /// 1=LEFT, 2=RIGHT, 3=FULL (probed)
    pub const JOIN_TYPE: u8 = 0x50;
    /// 64-bit literal dtype: one scale byte, 8 little-endian bytes
    pub const INT64: u8 = 0x10;
    pub const UPCASE: u8 = 0x67;
    pub const LOWCASE: u8 = 0xB5;
    /// blr_strlen with a length-type byte: CHAR_LENGTH=1,
    /// OCTET_LENGTH=2 (probed)
    pub const STRLEN: u8 = 0xB6;
    /// blr_substring: source, 0-BASED start, length - the engine
    /// compiles `FROM 1` as blr_subtract(literal 1, literal 1),
    /// UNFOLDED (probed)
    pub const SUBSTRING: u8 = 0x28;
    /// blr_trim: where byte (0=BOTH, 1=LEADING, 2=TRAILING), spec
    /// byte (0=spaces, 1=an explicit <what> operand follows), [what],
    /// source (probed)
    pub const TRIM: u8 = 0xB7;
    /// blr_cast: a dsc (dtype byte + its parameters), then the value
    pub const CAST: u8 = 0x83;
    /// blr_value_if: condition, then-value, else-value; the DSQL wraps
    /// the OUTERMOST value_if of a searched CASE / IIF / NULLIF in a
    /// blr_cast to the branches' UNIFIED descriptor (probed)
    pub const VALUE_IF: u8 = 0x69;
    /// blr_decode - the simple CASE: value, count byte, comparands,
    /// count byte, results (the ELSE is one extra result; without it
    /// the result count simply equals the comparand count). No cast
    /// wrapper (probed)
    pub const DECODE: u8 = 0xCB;
    /// blr_coalesce: count byte, values. No cast wrapper (probed)
    pub const COALESCE: u8 = 0xCA;
    /// blr_null - also the missing ELSE of a searched CASE
    pub const NULL: u8 = 0x2D;
    /// dsc dtypes seen only inside blr_cast
    pub const SHORT: u8 = 0x07;
    pub const VARYING2: u8 = 0x26;
    pub const DATE: u8 = 0x0C;
    pub const TIME: u8 = 0x0D;
    pub const TIMESTAMP: u8 = 0x23;
    /// blr_any - EXISTS: the verb and ONE rse, the subquery's WHERE
    /// as that rse's boolean (probed; the subquery's select list
    /// leaves no trace, like a view's)
    pub const ANY: u8 = 0x3C;
    /// blr_unique - SINGULAR, same single-rse shape as EXISTS
    pub const UNIQUE: u8 = 0x3E;
    /// blr_ansi_any / blr_ansi_all - IN (SELECT ...) and quantified
    /// comparisons: the verb, an rse whose SINGLE STREAM IS ANOTHER
    /// RSE (the subquery, carrying its own WHERE), then the
    /// quantified comparison as the OUTER rse's boolean (probed)
    pub const ANSI_ANY: u8 = 0x97;
    pub const ANSI_ALL: u8 = 0x9E;
    pub const EQL: u8 = 0x2F;
    pub const NEQ: u8 = 0x30;
    pub const GTR: u8 = 0x31;
    pub const GEQ: u8 = 0x32;
    pub const LSS: u8 = 0x33;
    pub const LEQ: u8 = 0x34;
}

/// A value expression in a boolean leaf.
#[derive(Clone, Debug, PartialEq)]
enum Val {
    /// a field with its stream CONTEXT id and UPPERCASED name
    Field(u8, String),
    /// integer literal - blr_long holds 32 bits; wider refuses
    Int(i32),
    /// decimal literal as (raw, scale): 12.50 is (1250, -2)
    Dec(i32, i8),
    Str(String),
    Add(Box<Val>, Box<Val>),
    Sub(Box<Val>, Box<Val>),
    Mul(Box<Val>, Box<Val>),
    Div(Box<Val>, Box<Val>),
    /// blr_negate - survives only before a FIELD; a sign before a
    /// numeric literal folds into it at parse (probed: A = -1 stores
    /// the literal 0xFFFFFFFF, no negate verb)
    Neg(Box<Val>),
    Concat(Box<Val>, Box<Val>),
    /// a literal past blr_long's 32 bits: blr_int64
    Int64(i64),
    Upper(Box<Val>),
    Lower(Box<Val>),
    /// blr_strlen with its length-type byte (1=CHAR, 2=OCTET)
    StrLen(u8, Box<Val>),
    /// blr_substring(source, start, length) - START IS 0-BASED and the
    /// engine emits `subtract(<from>, 1)` unfolded, so the parser
    /// builds exactly that Sub node
    Substring(Box<Val>, Box<Val>, Box<Val>),
    /// blr_trim(where, [what], source)
    Trim(u8, Option<Box<Val>>, Box<Val>),
    Null,
    /// blr_cast to an explicit target descriptor
    Cast(Dsc, Box<Val>),
    /// blr_value_if(condition, then, else) - built by searched CASE,
    /// IIF and NULLIF, always under a Cast to the unified branch dsc
    ValueIf(Box<Bool>, Box<Val>, Box<Val>),
    /// blr_decode - the simple CASE: selector, comparands, results
    /// (the ELSE, when present, is the extra last result)
    Decode(Box<Val>, Vec<Val>, Vec<Val>),
    /// blr_coalesce
    Coalesce(Vec<Val>),
}

/// A cast target descriptor, exactly the dsc bytes blr_cast carries
/// (each layout probed: numerics are dtype + scale, texts carry a
/// 2-byte charset then a 2-byte length, temporals are the dtype alone)
#[derive(Clone, Copy, Debug, PartialEq)]
enum Dsc {
    /// blr_short / blr_long / blr_int64 with a scale byte
    Num(u8, i8),
    /// blr_text2, charset 0 (a NONE-charset database), length
    Text(u16),
    /// blr_varying2, charset 0, length
    Varying(u16),
    Date,
    Time,
    Timestamp,
}

fn emit_dsc(out: &mut Vec<u8>, d: Dsc) {
    match d {
        Dsc::Num(dt, sc) => {
            out.push(dt);
            out.push(sc as u8);
        }
        Dsc::Text(l) => {
            out.push(blr::TEXT2);
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&l.to_le_bytes());
        }
        Dsc::Varying(l) => {
            out.push(blr::VARYING2);
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&l.to_le_bytes());
        }
        Dsc::Date => out.push(blr::DATE),
        Dsc::Time => out.push(blr::TIME),
        Dsc::Timestamp => out.push(blr::TIMESTAMP),
    }
}

/// A branch's contribution to the unified descriptor of a value_if
/// chain. Only literals and explicit CASTs contribute - a FIELD
/// branch's descriptor lives in the catalog, so it REFUSES (same
/// principle as bare multi-stream fields: never guess a descriptor).
enum BranchDsc {
    /// exact-numeric: (integer digits, scale<=0)
    Num(i32, i8),
    Text(u16),
    /// NULL - ignored by unification (probed: the missing-ELSE null
    /// leaves the dsc to the real branches)
    Skip,
}

fn branch_dsc(v: &Val) -> Option<BranchDsc> {
    Some(match v {
        Val::Int(_) => BranchDsc::Num(9, 0),
        Val::Int64(_) => BranchDsc::Num(18, 0),
        // a decimal literal is blr_long at its written scale (the
        // stored scale is ALREADY negative: 1.5 is (15, -1)): 9
        // digits of precision, |scale| of them fractional
        Val::Dec(_, sc) => BranchDsc::Num(9 + *sc as i32, *sc),
        Val::Str(t) => BranchDsc::Text(u16::try_from(t.len()).ok()?),
        Val::Null => BranchDsc::Skip,
        Val::Cast(d, _) => match d {
            Dsc::Num(dt, sc) => {
                let prec = match *dt {
                    blr::SHORT => 4,
                    blr::LONG => 9,
                    blr::INT64 => 18,
                    _ => return None,
                };
                BranchDsc::Num(prec + *sc as i32, *sc)
            }
            Dsc::Text(l) => BranchDsc::Text(*l),
            // varying / temporal branches: unification not yet probed
            _ => return None,
        },
        _ => return None,
    })
}

/// The UNIFIED descriptor the engine's DSQL computes for a value_if
/// chain, probed law by law: NULL branches are ignored; all-text
/// branches unify to blr_text2 at the MAXIMUM length ('yes'/'no' ->
/// CHAR(3)); exact numerics take the MAXIMUM integer-digit count and
/// the MINIMUM scale, then the dtype that FITS the total digit count
/// (<=4 short, <=9 long, else int64) - which is why long(scale 0)
/// united with long(scale -1) WIDENS to int64: 9 + 1 = 10 digits
fn unify_branches(branches: &[&Val]) -> Option<Dsc> {
    let mut num: Option<(i32, i8)> = None;
    let mut text: Option<u16> = None;
    let mut seen = false;
    for b in branches {
        match branch_dsc(b)? {
            BranchDsc::Skip => continue,
            BranchDsc::Num(ints, sc) => {
                if text.is_some() {
                    return None; // text/numeric mixtures: unprobed
                }
                let (i0, s0) = num.unwrap_or((ints, sc));
                num = Some((i0.max(ints), s0.min(sc)));
                seen = true;
            }
            BranchDsc::Text(l) => {
                if num.is_some() {
                    return None;
                }
                text = Some(text.unwrap_or(0).max(l));
                seen = true;
            }
        }
    }
    if !seen {
        return None; // all-NULL: the engine's choice is unprobed
    }
    if let Some(l) = text {
        return Some(Dsc::Text(l));
    }
    let (ints, sc) = num?;
    let needed = ints - sc as i32;
    let dt = if needed <= 4 {
        blr::SHORT
    } else if needed <= 9 {
        blr::LONG
    } else {
        blr::INT64
    };
    Some(Dsc::Num(dt, sc))
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum CmpOp {
    Eql,
    Neq,
    Gtr,
    Geq,
    Lss,
    Leq,
}

impl CmpOp {
    fn verb(self) -> u8 {
        match self {
            CmpOp::Eql => blr::EQL,
            CmpOp::Neq => blr::NEQ,
            CmpOp::Gtr => blr::GTR,
            CmpOp::Geq => blr::GEQ,
            CmpOp::Lss => blr::LSS,
            CmpOp::Leq => blr::LEQ,
        }
    }
    /// the inverse comparison - what the engine compiles `NOT <cmp>`
    /// into (probed: NOT (A > 5) stores blr_leq)
    fn inverse(self) -> CmpOp {
        match self {
            CmpOp::Eql => CmpOp::Neq,
            CmpOp::Neq => CmpOp::Eql,
            CmpOp::Gtr => CmpOp::Leq,
            CmpOp::Leq => CmpOp::Gtr,
            CmpOp::Lss => CmpOp::Geq,
            CmpOp::Geq => CmpOp::Lss,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Bool {
    And(Box<Bool>, Box<Bool>),
    Or(Box<Bool>, Box<Bool>),
    /// survives only over Like and Missing - negate() folds the rest
    Not(Box<Bool>),
    Cmp(CmpOp, Val, Val),
    Missing(Val),
    Between(Val, Val, Val),
    Like(Val, Val),
    /// blr_in_list: value, u16 count, values (FB5+); NOT IN keeps a
    /// real blr_not over it (probed)
    InList(Val, Vec<Val>),
    /// EXISTS - blr_any over the subquery's rse
    Any(SubQ),
    /// SINGULAR - blr_unique, same shape
    Unique(SubQ),
    /// `<left> <cmp> ANY/SOME (SELECT <col> ...)` and IN (SELECT) -
    /// blr_ansi_any; the comparison is the outer rse's boolean
    AnsiAny(CmpOp, Val, SubQ),
    /// `<left> <cmp> ALL (SELECT ...)` and NOT IN - blr_ansi_all
    AnsiAll(CmpOp, Val, SubQ),
}

/// A single-stream subquery: its stream (already holding a context id
/// in the statement's numbering, which CONTINUES across subqueries -
/// probed), its own WHERE, and for the quantified forms the selected
/// column.
#[derive(Clone, Debug, PartialEq)]
struct SubQ {
    stream: Stream,
    ctx: u8,
    wher: Option<Box<Bool>>,
    col: Option<Val>,
}

/// Push a negation down the tree the way the engine's DSQL does
/// (probed): De Morgan through AND/OR, inverse verbs for comparisons,
/// `NOT BETWEEN` expanded to `< lo OR > hi`, blr_not kept only over
/// LIKE and MISSING, double negation cancelled.
fn negate(b: Bool) -> Bool {
    match b {
        Bool::And(l, r) => Bool::Or(Box::new(negate(*l)), Box::new(negate(*r))),
        Bool::Or(l, r) => Bool::And(Box::new(negate(*l)), Box::new(negate(*r))),
        Bool::Not(inner) => *inner,
        Bool::Cmp(op, a, b) => Bool::Cmp(op.inverse(), a, b),
        Bool::Between(v, lo, hi) => Bool::Or(
            Box::new(Bool::Cmp(CmpOp::Lss, v.clone(), lo)),
            Box::new(Bool::Cmp(CmpOp::Gtr, v, hi)),
        ),
        keep @ (Bool::Missing(_) | Bool::Like(..) | Bool::InList(..)) => {
            Bool::Not(Box::new(keep))
        }
        // the quantifier FLIPS and the comparison INVERTS (probed:
        // NOT (A = ANY ...) stores ansi_all/neq - the NOT IN shape -
        // and NOT (A > ALL ...) stores ansi_any/leq)
        Bool::AnsiAny(op, l, s) => Bool::AnsiAll(op.inverse(), l, s),
        Bool::AnsiAll(op, l, s) => Bool::AnsiAny(op.inverse(), l, s),
        // EXISTS and SINGULAR have no inverse verb - blr_not survives
        keep @ (Bool::Any(_) | Bool::Unique(_)) => Bool::Not(Box::new(keep)),
    }
}

// ---------------------------------------------------------------- lexer

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Ident(String),
    Int(i64),
    Dec(i64, i8),
    Str(String),
    LParen,
    RParen,
    Cmp(CmpOp),
    Comma,
    Plus,
    Minus,
    Star,
    Slash,
    Concat,
    Dot,
}

fn lex(sql: &str) -> Option<Vec<Tok>> {
    let b: Vec<char> = sql.chars().collect();
    let mut i = 0;
    let mut out = Vec::new();
    while i < b.len() {
        let c = b[i];
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        match c {
            '(' => {
                out.push(Tok::LParen);
                i += 1;
            }
            ')' => {
                out.push(Tok::RParen);
                i += 1;
            }
            ',' => {
                out.push(Tok::Comma);
                i += 1;
            }
            '+' => {
                out.push(Tok::Plus);
                i += 1;
            }
            '-' => {
                out.push(Tok::Minus);
                i += 1;
            }
            '*' => {
                out.push(Tok::Star);
                i += 1;
            }
            '/' => {
                out.push(Tok::Slash);
                i += 1;
            }
            '|' if b.get(i + 1) == Some(&'|') => {
                out.push(Tok::Concat);
                i += 2;
            }
            '.' => {
                out.push(Tok::Dot);
                i += 1;
            }
            '=' => {
                out.push(Tok::Cmp(CmpOp::Eql));
                i += 1;
            }
            '<' => {
                if b.get(i + 1) == Some(&'=') {
                    out.push(Tok::Cmp(CmpOp::Leq));
                    i += 2;
                } else if b.get(i + 1) == Some(&'>') {
                    out.push(Tok::Cmp(CmpOp::Neq));
                    i += 2;
                } else {
                    out.push(Tok::Cmp(CmpOp::Lss));
                    i += 1;
                }
            }
            '>' => {
                if b.get(i + 1) == Some(&'=') {
                    out.push(Tok::Cmp(CmpOp::Geq));
                    i += 2;
                } else {
                    out.push(Tok::Cmp(CmpOp::Gtr));
                    i += 1;
                }
            }
            '\'' => {
                i += 1;
                let mut v = String::new();
                loop {
                    match b.get(i) {
                        None => return None,
                        Some('\'') if b.get(i + 1) == Some(&'\'') => {
                            v.push('\'');
                            i += 2;
                        }
                        Some('\'') => {
                            i += 1;
                            break;
                        }
                        Some(ch) => {
                            v.push(*ch);
                            i += 1;
                        }
                    }
                }
                out.push(Tok::Str(v));
            }
            d if d.is_ascii_digit() => {
                let start = i;
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
                if b.get(i) == Some(&'.') && b.get(i + 1).is_some_and(|c| c.is_ascii_digit()) {
                    i += 1;
                    let fs = i;
                    while i < b.len() && b[i].is_ascii_digit() {
                        i += 1;
                    }
                    let digits: String =
                        b[start..fs - 1].iter().chain(&b[fs..i]).collect();
                    out.push(Tok::Dec(digits.parse().ok()?, -((i - fs) as i8)));
                } else {
                    let n: i64 = b[start..i].iter().collect::<String>().parse().ok()?;
                    out.push(Tok::Int(n));
                }
            }
            a if a.is_alphabetic() || a == '_' || a == '$' => {
                let start = i;
                while i < b.len()
                    && (b[i].is_alphanumeric() || b[i] == '_' || b[i] == '$')
                {
                    i += 1;
                }
                // unquoted identifiers uppercase, exactly as the engine
                // stores them in the compiled BLR
                out.push(Tok::Ident(
                    b[start..i].iter().collect::<String>().to_ascii_uppercase(),
                ));
            }
            _ => return None, // outside this slice's lexicon
        }
    }
    Some(out)
}

// --------------------------------------------------------------- parser

/// One FROM stream: relation name, optional alias, 1-based context.
#[derive(Clone, Debug, PartialEq)]
struct Stream {
    name: String,
    alias: Option<String>,
}

struct P<'a> {
    t: &'a [Tok],
    i: usize,
    streams: Vec<Stream>,
    /// how many of `streams` belong to the OUTER FROM (set when the
    /// WHERE begins); subquery streams keep their context ids but
    /// never become visible to outer-scope bare names
    outer: Option<usize>,
    /// the stream index of the subquery currently being parsed - a
    /// bare name inside a subquery binds to the subquery's OWN stream
    /// (the innermost-scope-first rule; an outer reference must be
    /// qualified)
    sub: Option<usize>,
}

impl<'a> P<'a> {
    fn kw(&mut self, w: &str) -> bool {
        if matches!(self.t.get(self.i), Some(Tok::Ident(x)) if x == w) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    /// Resolve a field's stream context. Qualified names match a
    /// VISIBLE stream's ALIAS (which shadows the table name) or its
    /// table name - visible means the outer FROM streams plus, inside
    /// a subquery, that subquery's own stream. A bare name inside a
    /// subquery binds to the subquery's OWN stream (the
    /// innermost-scope-first rule; an outer reference must be
    /// qualified); a bare name in the outer scope is legal only with
    /// ONE outer stream - the engine resolves bare multi-stream names
    /// through the catalog, which this catalog-free compiler refuses
    /// rather than guessing.
    fn field(&self, qualifier: Option<&str>, name: &str) -> Option<Val> {
        let n_outer = self.outer.unwrap_or(self.streams.len());
        let ctx = match qualifier {
            Some(q) => {
                let hit = |st: &Stream| {
                    st.alias.as_deref().map_or(st.name == q, |a| a == q)
                };
                let idx = self
                    .streams
                    .iter()
                    .take(n_outer)
                    .position(hit)
                    .or_else(|| {
                        self.sub
                            .filter(|&si| hit(&self.streams[si]))
                    })?;
                (idx + 1) as u8
            }
            None => match self.sub {
                Some(si) => (si + 1) as u8,
                None => {
                    if n_outer != 1 {
                        return None;
                    }
                    1
                }
            },
        };
        Some(Val::Field(ctx, name.to_string()))
    }

    /// `TABLE [alias]` in a FROM clause or a subquery
    fn stream_item(&mut self) -> Option<Stream> {
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        if is_keyword(name) {
            return None;
        }
        let name = name.clone();
        self.i += 1;
        let alias = match self.t.get(self.i) {
            Some(Tok::Ident(a)) if !is_keyword(a) => {
                let a = a.clone();
                self.i += 1;
                Some(a)
            }
            _ => None,
        };
        Some(Stream { name, alias })
    }

    /// `(SELECT <one column | anything> FROM TABLE [alias]
    /// [WHERE <bool>])`, self.i ON the opening paren. The subquery's
    /// stream JOINS the statement's context numbering; with
    /// `need_col` the single select-list column is resolved (bare -
    /// against the subquery's own stream), without it the list
    /// compiles away exactly like a view's (probed: SELECT 1 and
    /// SELECT * leave no trace).
    fn subselect(&mut self, need_col: bool) -> Option<SubQ> {
        if self.outer.is_none() {
            // a subquery inside an ON clause would interleave the
            // join chain's stream numbering: unprobed, refuse
            return None;
        }
        if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
            return None;
        }
        self.i += 1;
        if !self.kw("SELECT") {
            return None;
        }
        // capture the select list positionally; resolve after the
        // stream exists
        let mut col: Option<(Option<String>, String)> = None;
        if need_col {
            let Some(Tok::Ident(a)) = self.t.get(self.i) else {
                return None;
            };
            if is_keyword(a) {
                return None;
            }
            let a = a.clone();
            self.i += 1;
            if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                self.i += 1;
                let Some(Tok::Ident(b)) = self.t.get(self.i) else {
                    return None;
                };
                col = Some((Some(a), b.clone()));
                self.i += 1;
            } else {
                col = Some((None, a));
            }
        } else {
            // EXISTS/SINGULAR: skip a traceless select list
            loop {
                match self.t.get(self.i)? {
                    Tok::Ident(w) if w == "FROM" => break,
                    Tok::Ident(w) if !is_keyword(w) => self.i += 1,
                    Tok::Int(_) | Tok::Comma | Tok::Dot | Tok::Star => self.i += 1,
                    _ => return None,
                }
            }
        }
        if !self.kw("FROM") {
            return None;
        }
        let stream = self.stream_item()?;
        self.streams.push(stream.clone());
        let si = self.streams.len() - 1;
        let ctx = (si + 1) as u8;
        // the subquery scope: bare names bind to ITS stream
        let saved = self.sub.replace(si);
        let col = match col {
            None => None,
            Some((q, n)) => Some(self.field(q.as_deref(), &n)?),
        };
        let wher = if self.kw("WHERE") {
            Some(Box::new(self.bool_or()?))
        } else {
            None
        };
        self.sub = saved;
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None; // joins, comma-FROM etc. in a subquery: unconverted
        }
        self.i += 1;
        Some(SubQ { stream, ctx, wher, col })
    }

    /// expression grammar mirroring the engine's precedence:
    /// `+`/`-` over `*`/`/` over unary `-` over `||` over atoms
    fn val(&mut self) -> Option<Val> {
        let mut left = self.val_mul()?;
        loop {
            match self.t.get(self.i) {
                Some(Tok::Plus) => {
                    self.i += 1;
                    left = Val::Add(Box::new(left), Box::new(self.val_mul()?));
                }
                Some(Tok::Minus) => {
                    self.i += 1;
                    left = Val::Sub(Box::new(left), Box::new(self.val_mul()?));
                }
                _ => return Some(left),
            }
        }
    }

    fn val_mul(&mut self) -> Option<Val> {
        let mut left = self.val_unary()?;
        loop {
            match self.t.get(self.i) {
                Some(Tok::Star) => {
                    self.i += 1;
                    left = Val::Mul(Box::new(left), Box::new(self.val_unary()?));
                }
                Some(Tok::Slash) => {
                    self.i += 1;
                    left = Val::Div(Box::new(left), Box::new(self.val_unary()?));
                }
                _ => return Some(left),
            }
        }
    }

    fn val_unary(&mut self) -> Option<Val> {
        if matches!(self.t.get(self.i), Some(Tok::Minus)) {
            self.i += 1;
            // a sign before a NUMERIC LITERAL folds into it (probed:
            // A = -1 stores the negative literal, no blr_negate);
            // before anything else, blr_negate survives
            return Some(match self.val_unary()? {
                Val::Int(n) => Val::Int(n.checked_neg()?),
                Val::Int64(n) => Val::Int64(n.checked_neg()?),
                Val::Dec(r, sc) => Val::Dec(r.checked_neg()?, sc),
                other => Val::Neg(Box::new(other)),
            });
        }
        if matches!(self.t.get(self.i), Some(Tok::Plus)) {
            self.i += 1;
            return self.val_unary();
        }
        self.val_concat()
    }

    fn val_concat(&mut self) -> Option<Val> {
        let mut left = self.val_atom()?;
        while matches!(self.t.get(self.i), Some(Tok::Concat)) {
            self.i += 1;
            left = Val::Concat(Box::new(left), Box::new(self.val_atom()?));
        }
        Some(left)
    }

    fn val_atom(&mut self) -> Option<Val> {
        let v = match self.t.get(self.i)? {
            Tok::Ident(x) if x == "CASE" => {
                self.i += 1;
                return self.case_tail();
            }
            Tok::Ident(x) if x == "NULL" => Val::Null,
            Tok::Ident(x) if !is_keyword(x) => {
                let first = x.clone();
                self.i += 1;
                if matches!(self.t.get(self.i), Some(Tok::LParen)) {
                    // a call: only the probed built-ins compile; an
                    // unknown name followed by '(' REFUSES (a UDF or
                    // unconverted function must never become a field)
                    return self.func(&first);
                }
                // a qualified field: IDENT . IDENT
                if matches!(self.t.get(self.i), Some(Tok::Dot)) {
                    self.i += 1;
                    let Some(Tok::Ident(f)) = self.t.get(self.i) else {
                        return None;
                    };
                    let f = f.clone();
                    self.i += 1;
                    return self.field(Some(&first), &f);
                }
                return self.field(None, &first);
            }
            Tok::Int(n) => match i32::try_from(*n) {
                Ok(v) => Val::Int(v),
                Err(_) => Val::Int64(*n),
            },
            Tok::Dec(r, s) => Val::Dec(i32::try_from(*r).ok()?, *s),
            Tok::Str(s) => Val::Str(s.clone()),
            Tok::LParen => {
                self.i += 1;
                let inner = self.val()?;
                if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    return None;
                }
                self.i += 1;
                return Some(inner);
            }
            _ => return None,
        };
        self.i += 1;
        Some(v)
    }

    /// the built-in functions whose compiled BLR was probed; self.i
    /// sits ON the opening paren
    fn func(&mut self, name: &str) -> Option<Val> {
        self.i += 1; // (
        let v = match name {
            "UPPER" => Val::Upper(Box::new(self.val()?)),
            "LOWER" => Val::Lower(Box::new(self.val()?)),
            // blr_strlen's length-type byte: CHAR_LENGTH=1,
            // OCTET_LENGTH=2 (probed)
            "CHAR_LENGTH" | "CHARACTER_LENGTH" => {
                Val::StrLen(1, Box::new(self.val()?))
            }
            "OCTET_LENGTH" => Val::StrLen(2, Box::new(self.val()?)),
            "SUBSTRING" => {
                // SUBSTRING(src FROM a FOR b): blr_substring's start
                // is 0-BASED and the engine emits subtract(<a>, 1)
                // UNFOLDED (probed: FROM 1 stores subtract(1, 1),
                // not the literal 0) - build exactly that Sub node
                let src = self.val()?;
                if !self.kw("FROM") {
                    return None;
                }
                let from = self.val()?;
                if !self.kw("FOR") {
                    return None; // FOR-less substring: not yet probed
                }
                let len = self.val()?;
                Val::Substring(
                    Box::new(src),
                    Box::new(Val::Sub(Box::new(from), Box::new(Val::Int(1)))),
                    Box::new(len),
                )
            }
            "TRIM" => {
                // where byte 0=BOTH 1=LEADING 2=TRAILING; a bare
                // `TRIM('a' FROM s)` is BOTH (probed byte-identical)
                let (wher, explicit) = if self.kw("LEADING") {
                    (1u8, true)
                } else if self.kw("TRAILING") {
                    (2u8, true)
                } else if self.kw("BOTH") {
                    (0u8, true)
                } else {
                    (0u8, false)
                };
                if self.kw("FROM") {
                    // TRIM(LEADING FROM s): a where-spec, no what
                    if !explicit {
                        return None;
                    }
                    Val::Trim(wher, None, Box::new(self.val()?))
                } else {
                    let v1 = self.val()?;
                    if self.kw("FROM") {
                        Val::Trim(wher, Some(Box::new(v1)), Box::new(self.val()?))
                    } else {
                        // plain TRIM(s) - a where-spec demands FROM
                        if explicit {
                            return None;
                        }
                        Val::Trim(0, None, Box::new(v1))
                    }
                }
            }
            "CAST" => {
                let v = self.val()?;
                if !self.kw("AS") {
                    return None;
                }
                Val::Cast(self.cast_target()?, Box::new(v))
            }
            "COALESCE" => {
                // blr_coalesce with its count byte; a single argument
                // is a syntax error IN THE ENGINE, so it refuses here
                let mut vs = vec![self.val()?];
                while matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    self.i += 1;
                    vs.push(self.val()?);
                }
                if vs.len() < 2 {
                    return None;
                }
                Val::Coalesce(vs)
            }
            "NULLIF" => {
                // NULLIF(a, b) compiles as cast(value_if(a = b, NULL,
                // a)) - and the unified dsc comes from the BRANCHES
                // (NULL and a), so b never shapes it (probed:
                // NULLIF(1, 2.55) casts to long scale 0)
                let a = self.val()?;
                if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    return None;
                }
                self.i += 1;
                let b = self.val()?;
                let dsc = unify_branches(&[&Val::Null, &a])?;
                Val::Cast(
                    dsc,
                    Box::new(Val::ValueIf(
                        Box::new(Bool::Cmp(CmpOp::Eql, a.clone(), b)),
                        Box::new(Val::Null),
                        Box::new(a),
                    )),
                )
            }
            "IIF" => {
                // IIF is pure sugar: byte-identical to the searched
                // CASE WHEN c THEN a ELSE b END (probed)
                let c = self.bool_or()?;
                if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    return None;
                }
                self.i += 1;
                let a = self.val()?;
                if !matches!(self.t.get(self.i), Some(Tok::Comma)) {
                    return None;
                }
                self.i += 1;
                let b = self.val()?;
                let dsc = unify_branches(&[&a, &b])?;
                Val::Cast(
                    dsc,
                    Box::new(Val::ValueIf(Box::new(c), Box::new(a), Box::new(b))),
                )
            }
            _ => return None,
        };
        if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
            return None;
        }
        self.i += 1;
        Some(v)
    }

    /// CASE ... END, self.i past the CASE keyword. The searched form
    /// compiles to a value_if CHAIN (each further WHEN nests in the
    /// ELSE slot) under ONE cast to the branches' unified dsc; a
    /// missing ELSE is blr_null. The simple form compiles to
    /// blr_decode with NO cast wrapper (probed).
    fn case_tail(&mut self) -> Option<Val> {
        if matches!(self.t.get(self.i), Some(Tok::Ident(w)) if w == "WHEN") {
            // searched CASE
            let mut arms: Vec<(Bool, Val)> = Vec::new();
            while self.kw("WHEN") {
                let c = self.bool_or()?;
                if !self.kw("THEN") {
                    return None;
                }
                arms.push((c, self.val()?));
            }
            let els = if self.kw("ELSE") {
                self.val()?
            } else {
                Val::Null
            };
            if !self.kw("END") {
                return None;
            }
            let mut branches: Vec<&Val> = arms.iter().map(|(_, v)| v).collect();
            branches.push(&els);
            let dsc = unify_branches(&branches)?;
            let mut tree = els;
            for (c, v) in arms.into_iter().rev() {
                tree = Val::ValueIf(Box::new(c), Box::new(v), Box::new(tree));
            }
            return Some(Val::Cast(dsc, Box::new(tree)));
        }
        // simple CASE: blr_decode(selector, comparands, results); the
        // ELSE is one extra result and NOTHING marks its absence
        let sel = self.val()?;
        let mut comparands = Vec::new();
        let mut results = Vec::new();
        while self.kw("WHEN") {
            comparands.push(self.val()?);
            if !self.kw("THEN") {
                return None;
            }
            results.push(self.val()?);
        }
        if comparands.is_empty() {
            return None;
        }
        if self.kw("ELSE") {
            results.push(self.val()?);
        }
        if !self.kw("END") {
            return None;
        }
        Some(Val::Decode(Box::new(sel), comparands, results))
    }

    /// the cast targets whose dsc bytes were probed; anything else -
    /// FLOAT, BLOB, DECFLOAT, INT128, zones, explicit charsets -
    /// refuses
    fn cast_target(&mut self) -> Option<Dsc> {
        let Some(Tok::Ident(name)) = self.t.get(self.i) else {
            return None;
        };
        let name = name.clone();
        self.i += 1;
        let paren_num = |p: &mut Self| -> Option<(i64, i8)> {
            if !matches!(p.t.get(p.i), Some(Tok::LParen)) {
                return None;
            }
            p.i += 1;
            let Some(Tok::Int(prec)) = p.t.get(p.i) else {
                return None;
            };
            let prec = *prec;
            p.i += 1;
            let mut sc = 0i8;
            if matches!(p.t.get(p.i), Some(Tok::Comma)) {
                p.i += 1;
                let Some(Tok::Int(x)) = p.t.get(p.i) else {
                    return None;
                };
                sc = i8::try_from(*x).ok()?;
                p.i += 1;
            }
            if !matches!(p.t.get(p.i), Some(Tok::RParen)) {
                return None;
            }
            p.i += 1;
            Some((prec, sc))
        };
        Some(match name.as_str() {
            "SMALLINT" => Dsc::Num(blr::SHORT, 0),
            "INTEGER" | "INT" => Dsc::Num(blr::LONG, 0),
            "BIGINT" => Dsc::Num(blr::INT64, 0),
            // NUMERIC(p<=4) is short; DECIMAL(p<=9) is ALWAYS long -
            // DECIMAL(4,1) probed as blr_long (SQL's "at least p")
            "NUMERIC" | "DECIMAL" => match paren_num(self) {
                None => Dsc::Num(blr::LONG, 0),
                Some((p, sc)) => {
                    let dt = if p <= 4 && name == "NUMERIC" {
                        blr::SHORT
                    } else if p <= 9 {
                        blr::LONG
                    } else if p <= 18 {
                        blr::INT64
                    } else {
                        return None; // INT128 territory: unprobed
                    };
                    Dsc::Num(dt, -sc)
                }
            },
            "VARCHAR" => {
                let (l, sc) = paren_num(self)?;
                if sc != 0 {
                    return None;
                }
                Dsc::Varying(u16::try_from(l).ok()?)
            }
            "CHAR" | "CHARACTER" => {
                let (l, sc) = paren_num(self)?;
                if sc != 0 {
                    return None;
                }
                Dsc::Text(u16::try_from(l).ok()?)
            }
            "DATE" => Dsc::Date,
            "TIME" => Dsc::Time,
            "TIMESTAMP" => Dsc::Timestamp,
            _ => return None,
        })
    }

    fn bool_or(&mut self) -> Option<Bool> {
        let mut left = self.bool_and()?;
        while self.kw("OR") {
            let right = self.bool_and()?;
            left = Bool::Or(Box::new(left), Box::new(right));
        }
        Some(left)
    }

    fn bool_and(&mut self) -> Option<Bool> {
        let mut left = self.bool_not()?;
        while self.kw("AND") {
            let right = self.bool_not()?;
            left = Bool::And(Box::new(left), Box::new(right));
        }
        Some(left)
    }

    fn bool_not(&mut self) -> Option<Bool> {
        if self.kw("NOT") {
            return Some(negate(self.bool_not()?));
        }
        if matches!(self.t.get(self.i), Some(Tok::LParen)) {
            // a paren opens a boolean group OR a parenthesised value
            // ((A + 1) * 2 = 8): try the group on a saved position,
            // fall through to the leaf parser otherwise
            let save = self.i;
            self.i += 1;
            if let Some(inner) = self.bool_or() {
                if matches!(self.t.get(self.i), Some(Tok::RParen)) {
                    self.i += 1;
                    return Some(inner);
                }
            }
            self.i = save;
        }
        self.leaf()
    }

    fn leaf(&mut self) -> Option<Bool> {
        if self.kw("EXISTS") {
            return Some(Bool::Any(self.subselect(false)?));
        }
        if self.kw("SINGULAR") {
            return Some(Bool::Unique(self.subselect(false)?));
        }
        let left = self.val()?;
        if self.kw("IS") {
            let negated = self.kw("NOT");
            if !self.kw("NULL") {
                return None;
            }
            let m = Bool::Missing(left);
            return Some(if negated { Bool::Not(Box::new(m)) } else { m });
        }
        let negated = self.kw("NOT");
        if self.kw("BETWEEN") {
            let lo = self.val()?;
            if !self.kw("AND") {
                return None;
            }
            let hi = self.val()?;
            let body = Bool::Between(left, lo, hi);
            return Some(if negated { negate(body) } else { body });
        }
        if self.kw("LIKE") {
            let pat = self.val()?;
            let body = Bool::Like(left, pat);
            return Some(if negated {
                Bool::Not(Box::new(body))
            } else {
                body
            });
        }
        if self.kw("IN") {
            if !matches!(self.t.get(self.i), Some(Tok::LParen)) {
                return None;
            }
            // IN (SELECT ...) is blr_ansi_any with an EQL boolean;
            // NOT IN negates to blr_ansi_all with NEQ (probed)
            if matches!(self.t.get(self.i + 1), Some(Tok::Ident(w)) if w == "SELECT") {
                let sub = self.subselect(true)?;
                let body = Bool::AnsiAny(CmpOp::Eql, left, sub);
                return Some(if negated { negate(body) } else { body });
            }
            self.i += 1;
            let mut items = vec![self.val()?];
            while matches!(self.t.get(self.i), Some(Tok::Comma)) {
                self.i += 1;
                items.push(self.val()?);
            }
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                return None;
            }
            self.i += 1;
            let body = Bool::InList(left, items);
            return Some(if negated {
                Bool::Not(Box::new(body))
            } else {
                body
            });
        }
        if negated {
            return None;
        }
        if let Some(Tok::Cmp(op)) = self.t.get(self.i) {
            let op = *op;
            self.i += 1;
            // a quantifier keeps the WRITTEN comparison as the outer
            // rse's boolean; ANY and SOME are the same verb (probed)
            if self.kw("ANY") || self.kw("SOME") {
                return Some(Bool::AnsiAny(op, left, self.subselect(true)?));
            }
            if self.kw("ALL") {
                return Some(Bool::AnsiAll(op, left, self.subselect(true)?));
            }
            let right = self.val()?;
            return Some(Bool::Cmp(op, left, right));
        }
        None
    }
}

fn is_keyword(w: &str) -> bool {
    matches!(
        w,
        "AND"
            | "OR"
            | "NOT"
            | "IS"
            | "NULL"
            | "BETWEEN"
            | "LIKE"
            | "IN"
            | "WHERE"
            | "FROM"
            | "SELECT"
            | "JOIN"
            | "INNER"
            | "ON"
            | "LEFT"
            | "RIGHT"
            | "FULL"
            | "OUTER"
            | "FOR"
            | "LEADING"
            | "TRAILING"
            | "BOTH"
            | "CASE"
            | "WHEN"
            | "THEN"
            | "ELSE"
            | "END"
            | "AS"
            | "EXISTS"
            | "SINGULAR"
            | "ANY"
            | "SOME"
            | "ALL"
    )
}

// -------------------------------------------------------------- emitter

fn emit_val(out: &mut Vec<u8>, v: &Val) {
    match v {
        Val::Field(ctx, name) => {
            out.push(blr::FIELD);
            out.push(*ctx);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
        }
        Val::Add(a, b) => {
            out.push(blr::ADD);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Sub(a, b) => {
            out.push(blr::SUBTRACT);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Mul(a, b) => {
            out.push(blr::MULTIPLY);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Div(a, b) => {
            out.push(blr::DIVIDE);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Neg(a) => {
            out.push(blr::NEGATE);
            emit_val(out, a);
        }
        Val::Concat(a, b) => {
            out.push(blr::CONCATENATE);
            emit_val(out, a);
            emit_val(out, b);
        }
        Val::Int64(n) => {
            out.push(blr::LITERAL);
            out.push(blr::INT64);
            out.push(0); // scale
            out.extend_from_slice(&n.to_le_bytes());
        }
        Val::Upper(a) => {
            out.push(blr::UPCASE);
            emit_val(out, a);
        }
        Val::Lower(a) => {
            out.push(blr::LOWCASE);
            emit_val(out, a);
        }
        Val::StrLen(kind, a) => {
            out.push(blr::STRLEN);
            out.push(*kind);
            emit_val(out, a);
        }
        Val::Substring(src, start, len) => {
            out.push(blr::SUBSTRING);
            emit_val(out, src);
            emit_val(out, start);
            emit_val(out, len);
        }
        Val::Trim(wher, what, src) => {
            out.push(blr::TRIM);
            out.push(*wher);
            match what {
                None => out.push(0),
                Some(w) => {
                    out.push(1);
                    emit_val(out, w);
                }
            }
            emit_val(out, src);
        }
        Val::Null => out.push(blr::NULL),
        Val::Cast(d, v) => {
            out.push(blr::CAST);
            emit_dsc(out, *d);
            emit_val(out, v);
        }
        Val::ValueIf(c, t, e) => {
            out.push(blr::VALUE_IF);
            emit_bool(out, c);
            emit_val(out, t);
            emit_val(out, e);
        }
        Val::Decode(sel, comparands, results) => {
            out.push(blr::DECODE);
            emit_val(out, sel);
            out.push(comparands.len() as u8);
            for c in comparands {
                emit_val(out, c);
            }
            out.push(results.len() as u8);
            for r in results {
                emit_val(out, r);
            }
        }
        Val::Coalesce(vs) => {
            out.push(blr::COALESCE);
            out.push(vs.len() as u8);
            for v in vs {
                emit_val(out, v);
            }
        }
        Val::Int(n) => {
            out.push(blr::LITERAL);
            out.push(blr::LONG);
            out.push(0); // scale
            out.extend_from_slice(&n.to_le_bytes());
        }
        Val::Dec(raw, scale) => {
            out.push(blr::LITERAL);
            out.push(blr::LONG);
            out.push(*scale as u8);
            out.extend_from_slice(&raw.to_le_bytes());
        }
        Val::Str(s) => {
            out.push(blr::LITERAL);
            out.push(blr::TEXT2);
            out.extend_from_slice(&0u16.to_le_bytes()); // charset (NONE)
            out.extend_from_slice(&(s.len() as u16).to_le_bytes());
            out.extend_from_slice(s.as_bytes());
        }
    }
}

fn emit_bool(out: &mut Vec<u8>, b: &Bool) {
    match b {
        Bool::And(l, r) => {
            out.push(blr::AND);
            emit_bool(out, l);
            emit_bool(out, r);
        }
        Bool::Or(l, r) => {
            out.push(blr::OR);
            emit_bool(out, l);
            emit_bool(out, r);
        }
        Bool::Not(inner) => {
            out.push(blr::NOT);
            emit_bool(out, inner);
        }
        Bool::Cmp(op, a, bb) => {
            out.push(op.verb());
            emit_val(out, a);
            emit_val(out, bb);
        }
        Bool::Missing(v) => {
            out.push(blr::MISSING);
            emit_val(out, v);
        }
        Bool::Between(v, lo, hi) => {
            out.push(blr::BETWEEN);
            emit_val(out, v);
            emit_val(out, lo);
            emit_val(out, hi);
        }
        Bool::Like(v, p) => {
            out.push(blr::LIKE);
            emit_val(out, v);
            emit_val(out, p);
        }
        Bool::InList(v, items) => {
            out.push(blr::IN_LIST);
            emit_val(out, v);
            out.extend_from_slice(&(items.len() as u16).to_le_bytes());
            for it in items {
                emit_val(out, it);
            }
        }
        Bool::Any(sub) | Bool::Unique(sub) => {
            out.push(if matches!(b, Bool::Any(_)) {
                blr::ANY
            } else {
                blr::UNIQUE
            });
            out.push(blr::RSE);
            out.push(1);
            emit_stream(out, &sub.stream, sub.ctx);
            if let Some(w) = &sub.wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, w);
            }
            out.push(blr::END);
        }
        Bool::AnsiAny(op, left, sub) | Bool::AnsiAll(op, left, sub) => {
            out.push(if matches!(b, Bool::AnsiAny(..)) {
                blr::ANSI_ANY
            } else {
                blr::ANSI_ALL
            });
            // the outer rse's single stream IS the subquery's rse -
            // which carries the subquery's own WHERE; the quantified
            // comparison is the OUTER rse's boolean (probed)
            out.push(blr::RSE);
            out.push(1);
            out.push(blr::RSE);
            out.push(1);
            emit_stream(out, &sub.stream, sub.ctx);
            if let Some(w) = &sub.wher {
                out.push(blr::BOOLEAN);
                emit_bool(out, w);
            }
            out.push(blr::END);
            out.push(blr::BOOLEAN);
            out.push(op.verb());
            emit_val(out, left);
            emit_val(
                out,
                sub.col.as_ref().expect("quantified subquery has a column"),
            );
            out.push(blr::END);
        }
    }
}

/// One relation stream: plain (blr_relation) or aliased
/// (blr_relation2, the alias UPPERCASED IN DOUBLE QUOTES - probed).
fn emit_stream(out: &mut Vec<u8>, st: &Stream, ctx: u8) {
    match &st.alias {
        None => {
            out.push(blr::RELATION);
            out.push(st.name.len() as u8);
            out.extend_from_slice(st.name.as_bytes());
        }
        Some(a) => {
            out.push(blr::RELATION2);
            out.push(st.name.len() as u8);
            out.extend_from_slice(st.name.as_bytes());
            let quoted = format!("\"{}\"", a);
            out.push(quoted.len() as u8);
            out.extend_from_slice(quoted.as_bytes());
        }
    }
    out.push(ctx);
}

/// Compile a view-shaped SELECT to the BLR the engine's DSQL stores in
/// `RDB$VIEW_BLR` - byte for byte. `None` for anything outside the
/// converted surface (the caller refuses; this crate never guesses).
pub fn compile_view_select(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P {
        t: &toks,
        i: 0,
        streams: Vec::new(),
        outer: None,
        sub: None,
    };
    if !p.kw("SELECT") {
        return None;
    }
    // the select list leaves NO trace in the view BLR (probed) - skip
    // to FROM, but refuse list shapes this slice has not verified
    // (bare and qualified columns and `*` are known to compile away)
    loop {
        match p.t.get(p.i)? {
            Tok::Ident(w) if w == "FROM" => {
                p.i += 1;
                break;
            }
            Tok::Ident(w) if !is_keyword(w) => p.i += 1,
            Tok::Comma | Tok::Dot | Tok::Star => p.i += 1,
            _ => return None,
        }
    }
    // FROM: `T [alias]`, a comma-list `T [a], U [b], ...`, or a JOIN
    // chain `T [a] j U [b] ON <bool> j V [c] ON <bool> ...` where j is
    // [INNER] JOIN | LEFT/RIGHT/FULL [OUTER] JOIN - each ON binds the
    // join to its LEFT, so the chain nests left (probed: the second
    // join's node contains the first as its first stream slot)
    let first = p.stream_item()?;
    p.streams.push(first);
    // each chained join: (join-type byte - 0 for INNER, which emits NO
    // blr_join_type sub-clause; 1/2/3 for LEFT/RIGHT/FULL - and its ON)
    let mut joins: Vec<(u8, Bool)> = Vec::new();
    if matches!(p.t.get(p.i), Some(Tok::Comma)) {
        // the comma list: streams side by side in the rse
        while matches!(p.t.get(p.i), Some(Tok::Comma)) {
            p.i += 1;
            let st = p.stream_item()?;
            p.streams.push(st);
        }
    } else {
        loop {
            let jt = if p.kw("LEFT") {
                1u8
            } else if p.kw("RIGHT") {
                2u8
            } else if p.kw("FULL") {
                3u8
            } else if matches!(p.t.get(p.i), Some(Tok::Ident(w)) if w == "JOIN" || w == "INNER")
            {
                let _ = p.kw("INNER");
                0u8
            } else {
                break;
            };
            if jt != 0 {
                let _ = p.kw("OUTER"); // LEFT OUTER JOIN == LEFT JOIN (probed)
            }
            if !p.kw("JOIN") {
                return None;
            }
            let st = p.stream_item()?;
            p.streams.push(st);
            if !p.kw("ON") {
                return None;
            }
            joins.push((jt, p.bool_or()?));
        }
    }
    // everything pushed so far is the outer FROM; subquery streams
    // keep joining `streams` for context numbering but stay invisible
    // to outer bare names
    p.outer = Some(p.streams.len());
    let boolean = if p.kw("WHERE") {
        Some(p.bool_or()?)
    } else {
        None
    };
    if p.i != p.t.len() {
        return None; // trailing clauses are outside this slice
    }

    let n_outer = p.outer.unwrap_or(p.streams.len());
    let mut out = vec![blr::VERSION5, blr::RSE];
    if joins.is_empty() {
        // plain OUTER streams, side by side (subquery streams live
        // inside their own rses)
        out.push(n_outer as u8);
        for (i, st) in p.streams.iter().take(n_outer).enumerate() {
            emit_stream(&mut out, st, (i + 1) as u8);
        }
    } else {
        // one rse stream holding the join chain, nested LEFT: join k's
        // node holds join k-1's node as its first stream slot, then
        // the new stream, then blr_join_type for an outer join (probed
        // absent for INNER), then its ON as a boolean sub-clause, then
        // its own blr_end
        out.push(1);
        fn emit_join_chain(
            out: &mut Vec<u8>,
            streams: &[Stream],
            joins: &[(u8, Bool)],
            k: usize,
        ) {
            if k == 0 {
                emit_stream(out, &streams[0], 1);
                return;
            }
            let (jt, on) = &joins[k - 1];
            out.push(blr::JOIN);
            out.push(2);
            emit_join_chain(out, streams, joins, k - 1);
            emit_stream(out, &streams[k], (k + 1) as u8);
            if *jt != 0 {
                out.push(blr::JOIN_TYPE);
                out.push(*jt);
            }
            out.push(blr::BOOLEAN);
            emit_bool(out, on);
            out.push(blr::END);
        }
        emit_join_chain(&mut out, &p.streams, &joins, joins.len());
    }
    if let Some(b) = &boolean {
        out.push(blr::BOOLEAN);
        emit_bool(&mut out, b);
    }
    out.push(blr::END);
    out.push(blr::EOC);
    Some(out)
}

/// The emitted BLR as uppercase hex - what the gate compares against
/// isql's OCTETS rendering of `RDB$VIEW_BLR`.
pub fn compile_view_select_hex(sql: &str) -> Option<String> {
    Some(
        compile_view_select(sql)?
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// every expected string here was read back from the ENGINE's
    /// RDB$VIEW_BLR for the identical statement (see the module doc);
    /// the gate re-verifies them against a live engine on every run
    fn pin(sql: &str, want_hex: &str) {
        assert_eq!(
            compile_view_select_hex(sql).as_deref(),
            Some(want_hex),
            "{sql}"
        );
    }

    #[test]
    fn compiles_the_probed_view_blr_byte_for_byte() {
        // the select list leaves no trace: both compile identically
        pin("SELECT ID FROM T", "0543014A015401FF4C");
        pin("SELECT ID, A FROM T", "0543014A015401FF4C");
        // WHERE with a comparison and a literal
        pin(
            "SELECT ID FROM T WHERE A > 5",
            "0543014A01540147311701014115080005000000FF4C",
        );
        // AND of comparisons, text literal as blr_text2
        pin(
            "SELECT ID, S FROM T WHERE A = 1 AND S = 'x'",
            "0543014A015401473A2F17010141150800010000002F17010153150F0000010078FF4C",
        );
        // OR, >=, <>
        pin(
            "SELECT ID FROM T WHERE A >= 5 OR A <> 0",
            "0543014A0154014739321701014115080005000000301701014115080000000000FF4C",
        );
        // NOT folds to the inverse comparison
        pin(
            "SELECT ID FROM T WHERE NOT (A > 5)",
            "0543014A01540147341701014115080005000000FF4C",
        );
        // IS NULL is blr_missing
        pin("SELECT ID FROM T WHERE S IS NULL", "0543014A015401473D17010153FF4C");
        // a decimal literal keeps its written scale (12.50 -> -2, 1250)
        pin(
            "SELECT ID FROM T WHERE N = 12.50",
            "0543014A015401472F1701014E1508FEE2040000FF4C",
        );
        // BETWEEN stays blr_between
        pin(
            "SELECT ID FROM T WHERE A BETWEEN 1 AND 9",
            "0543014A0154014738170101411508000100000015080009000000FF4C",
        );
        // LIKE
        pin(
            "SELECT ID FROM T WHERE S LIKE 'x%'",
            "0543014A015401473F17010153150F000002007825FF4C",
        );
        // left-nested ANDs, <, <=, IS NOT NULL = not(missing)
        pin(
            "SELECT ID FROM T WHERE A < 3 AND A <= 4 AND S IS NOT NULL",
            "0543014A015401473A3A3317010141150800030000003417010141150800040000003B3D17010153FF4C",
        );
        // De Morgan pushes NOT through OR: and(neq, not(missing))
        pin(
            "SELECT ID FROM T WHERE NOT (A = 1 OR S IS NULL)",
            "0543014A015401473A3017010141150800010000003B3D17010153FF4C",
        );
        // NOT LIKE keeps blr_not
        pin(
            "SELECT ID FROM T WHERE S NOT LIKE 'x%'",
            "0543014A015401473B3F17010153150F000002007825FF4C",
        );
        // NOT BETWEEN expands to lss OR gtr
        pin(
            "SELECT ID FROM T WHERE A NOT BETWEEN 1 AND 9",
            "0543014A0154014739331701014115080001000000311701014115080009000000FF4C",
        );
        // field against field
        pin(
            "SELECT ID FROM T WHERE A = ID",
            "0543014A015401472F170101411701024944FF4C",
        );
    }

    #[test]
    fn compiles_slice_two_shapes_byte_for_byte() {
        // value expressions: add/sub/mul/div with plain precedence
        pin(
            "SELECT ID FROM T WHERE A + 1 > 5",
            "0543014A015401473122170101411508000100000015080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A * 2 - 1 = 9",
            "0543014A015401472F232417010141150800020000001508000100000015080009000000FF4C",
        );
        // blr_negate survives only before a field...
        pin(
            "SELECT ID FROM T WHERE -A = 5",
            "0543014A015401472F261701014115080005000000FF4C",
        );
        // ...while a sign before a numeric literal FOLDS into it
        pin(
            "SELECT ID FROM T WHERE A = -1",
            "0543014A015401472F17010141150800FFFFFFFFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A = -1.5",
            "0543014A015401472F170101411508FFF1FFFFFFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A / 2 = 3",
            "0543014A015401472F25170101411508000200000015080003000000FF4C",
        );
        // parens reshape the tree
        pin(
            "SELECT ID FROM T WHERE (A + 1) * 2 = 8",
            "0543014A015401472F242217010141150800010000001508000200000015080008000000FF4C",
        );
        // concatenation
        pin(
            "SELECT ID FROM T WHERE S = 'a' || 'b'",
            "0543014A015401472F1701015327150F0000010061150F0000010062FF4C",
        );
        // IN is blr_in_list with a u16 count; NOT IN keeps blr_not
        pin(
            "SELECT ID FROM T WHERE A IN (1, 2, 3)",
            "0543014A0154014740170101410300150800010000001508000200000015080003000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A NOT IN (1, 2)",
            "0543014A015401473B401701014102001508000100000015080002000000FF4C",
        );
        // comma-FROM: two streams side by side, fields by context
        pin(
            "SELECT T.ID FROM T, U2 WHERE T.ID = U2.UID",
            "0543024A0154014A02553202472F1701024944170203554944FF4C",
        );
        // an alias becomes blr_relation2, UPPERCASED IN DOUBLE QUOTES
        pin(
            "SELECT X.ID FROM T X WHERE X.A > 1",
            "054301920154032258220147311701014115080001000000FF4C",
        );
        pin(
            "SELECT AB.ID FROM T AB WHERE AB.A > 1",
            "05430192015404224142220147311701014115080001000000FF4C",
        );
        // a lowercase alias uppercases before quoting
        pin(
            "SELECT x.ID FROM T x WHERE x.A > 1",
            "054301920154032258220147311701014115080001000000FF4C",
        );
        // INNER JOIN: blr_join nests like an rse, the ON clause is its
        // boolean, and a WHERE is the rse's own boolean after it
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID WHERE U2.UA > 0",
            "05430177024A0154014A02553202472F1701024944170203554944FF4731170202554115080000000000FF4C",
        );
        pin(
            "SELECT E.ID FROM T E JOIN U2 D ON E.ID = D.UID",
            "05430177029201540322452201920255320322442202472F1701024944170203554944FFFF4C",
        );
    }

    #[test]
    fn compiles_slice_three_shapes_byte_for_byte() {
        // outer joins: blr_join_type (absent for INNER) carries
        // 1=LEFT, 2=RIGHT, 3=FULL after the streams, before the ON
        pin(
            "SELECT T.ID FROM T LEFT JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025001472F1701024944170203554944FFFF4C",
        );
        pin(
            "SELECT T.ID FROM T RIGHT JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025002472F1701024944170203554944FFFF4C",
        );
        pin(
            "SELECT T.ID FROM T FULL JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025003472F1701024944170203554944FFFF4C",
        );
        // LEFT OUTER JOIN compiles to the same bytes as LEFT JOIN
        pin(
            "SELECT T.ID FROM T LEFT OUTER JOIN U2 ON T.ID = U2.UID",
            "05430177024A0154014A025532025001472F1701024944170203554944FFFF4C",
        );
        // a chained join NESTS LEFT: the second join's node holds the
        // first join's node as its first stream slot (probed)
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID JOIN V3T ON U2.UA = V3T.VID",
            "054301770277024A0154014A02553202472F1701024944170203554944FF4A0356335403472F1702025541170303564944FFFF4C",
        );
        // a mixed chain: the type byte sits on ITS OWN node only
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID LEFT JOIN V3T ON U2.UA = V3T.VID",
            "054301770277024A0154014A02553202472F1701024944170203554944FF4A03563354035001472F1702025541170303564944FFFF4C",
        );
        // an outer join plus WHERE: the rse's own boolean follows the
        // join node - the classic find-the-unmatched-rows shape
        pin(
            "SELECT T.ID FROM T LEFT JOIN U2 ON T.ID = U2.UID WHERE U2.UA IS NULL",
            "05430177024A0154014A025532025001472F1701024944170203554944FF473D1702025541FF4C",
        );
        // a literal past blr_long's 32 bits: blr_int64, one scale
        // byte, 8 little-endian bytes
        pin(
            "SELECT ID FROM T WHERE A = 5000000000",
            "0543014A015401472F1701014115100000F2052A01000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A = -5000000000",
            "0543014A015401472F17010141151000000EFAD5FEFFFFFFFF4C",
        );
        // built-ins: blr_upcase / blr_lowcase take one operand
        pin(
            "SELECT ID FROM T WHERE UPPER(S) = 'X'",
            "0543014A015401472F6717010153150F0000010058FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE LOWER(S) = 'x'",
            "0543014A015401472FB517010153150F0000010078FF4C",
        );
        // blr_strlen's length-type byte: CHAR_LENGTH=1, OCTET_LENGTH=2
        pin(
            "SELECT ID FROM T WHERE CHAR_LENGTH(S) > 3",
            "0543014A0154014731B6011701015315080003000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE OCTET_LENGTH(S) > 3",
            "0543014A0154014731B6021701015315080003000000FF4C",
        );
        // blr_substring's start is 0-BASED and the engine emits
        // subtract(<from>, 1) UNFOLDED - FROM 1 stores subtract(1, 1)
        pin(
            "SELECT ID FROM T WHERE SUBSTRING(S FROM 1 FOR 2) = 'ab'",
            "0543014A015401472F281701015323150800010000001508000100000015080002000000150F000002006162FF4C",
        );
        // blr_trim: where byte (0=BOTH 1=LEADING 2=TRAILING), spec
        // byte (0=spaces, 1=an explicit what operand)
        pin(
            "SELECT ID FROM T WHERE TRIM(S) = 'x'",
            "0543014A015401472FB7000017010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(LEADING 'a' FROM S) = 'x'",
            "0543014A015401472FB70101150F000001006117010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(TRAILING 'a' FROM S) = 'x'",
            "0543014A015401472FB70201150F000001006117010153150F0000010078FF4C",
        );
        // a bare `TRIM('a' FROM s)` is BOTH - byte-identical to the
        // explicit form
        pin(
            "SELECT ID FROM T WHERE TRIM('a' FROM S) = 'x'",
            "0543014A015401472FB70001150F000001006117010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(BOTH 'a' FROM S) = 'x'",
            "0543014A015401472FB70001150F000001006117010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE TRIM(LEADING FROM S) = 'x'",
            "0543014A015401472FB7010017010153150F0000010078FF4C",
        );
    }

    #[test]
    fn compiles_slice_four_shapes_byte_for_byte() {
        // blr_cast: dsc bytes per target - numerics carry dtype +
        // scale; NUMERIC(p<=4) is SHORT but DECIMAL(p<=9) is ALWAYS
        // LONG; p in 10..=18 is INT64; texts carry charset + length;
        // temporals are the dtype alone
        pin(
            "SELECT ID FROM T WHERE CAST(A AS BIGINT) = 5",
            "0543014A015401472F8310001701014115080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS SMALLINT) = 5",
            "0543014A015401472F8307001701014115080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS INTEGER) = 5",
            "0543014A015401472F8308001701015315080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(9,2)) = 1.50",
            "0543014A015401472F8308FE170101411508FE96000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(4,1)) = 1.5",
            "0543014A015401472F8307FF170101411508FF0F000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS DECIMAL(4,1)) = 1.5",
            "0543014A015401472F8308FF170101411508FF0F000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(18,2)) = 1.5",
            "0543014A015401472F8310FE170101411508FF0F000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(10)) = 1",
            "0543014A015401472F8310001701014115080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(ID AS VARCHAR(10)) = '5'",
            "0543014A015401472F832600000A001701024944150F0000010035FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS CHAR(5)) = 'x'",
            "0543014A015401472F830F0000050017010153150F0000010078FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS DATE) = S",
            "0543014A015401472F830C1701015317010153FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS TIME) = S",
            "0543014A015401472F830D1701015317010153FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CAST(S AS TIMESTAMP) = S",
            "0543014A015401472F83231701015317010153FF4C",
        );
        // the searched CASE: ONE cast wrapper over a value_if chain,
        // the unified dsc from the branches (NULL ignored)
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1 ELSE 0 END = 1",
            "0543014A015401472F83080069311701014115080005000000150800010000001508000000000015080001000000FF4C",
        );
        // IIF is byte-identical sugar for it
        pin(
            "SELECT ID FROM T WHERE IIF(A > 5, 1, 0) = 1",
            "0543014A015401472F83080069311701014115080005000000150800010000001508000000000015080001000000FF4C",
        );
        // a missing ELSE is blr_null - and does not shape the dsc
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1 END = 1",
            "0543014A015401472F83080069311701014115080005000000150800010000002D15080001000000FF4C",
        );
        // further WHENs nest in the ELSE slot; still ONE cast on top
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1 WHEN A > 2 THEN 2 ELSE 3 END = 1",
            "0543014A015401472F830800693117010141150800050000001508000100000069311701014115080002000000150800020000001508000300000015080001000000FF4C",
        );
        // text branches unify to blr_text2 at the MAXIMUM length
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 'yes' ELSE 'no' END = 'yes'",
            "0543014A015401472F830F0000030069311701014115080005000000150F00000300796573150F000002006E6F150F00000300796573FF4C",
        );
        // THE WIDENING LAW: long(0) with long(-1) needs 10 digits -
        // the unified dsc is INT64 scale -1, not long
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1.5 ELSE 0 END = 1",
            "0543014A015401472F8310FF693117010141150800050000001508FF0F0000001508000000000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 1.23 ELSE 0.5 END = 1",
            "0543014A015401472F8310FE693117010141150800050000001508FE7B0000001508FF0500000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 5000000000 ELSE 0 END = 1",
            "0543014A015401472F8310006931170101411508000500000015100000F2052A010000001508000000000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 5000000000 ELSE 0.5 END = 1",
            "0543014A015401472F8310FF6931170101411508000500000015100000F2052A010000001508FF0500000015080001000000FF4C",
        );
        // CAST branches contribute their EXPLICIT dsc: two SMALLINT
        // casts stay short; short with long-0 is long
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN CAST(A AS SMALLINT) ELSE CAST(ID AS SMALLINT) END = 1",
            "0543014A015401472F8307006931170101411508000500000083070017010141830700170102494415080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN CAST(A AS SMALLINT) ELSE 0 END = 1",
            "0543014A015401472F83080069311701014115080005000000830700170101411508000000000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN CAST(A AS BIGINT) ELSE 0 END = 1",
            "0543014A015401472F83100069311701014115080005000000831000170101411508000000000015080001000000FF4C",
        );
        // the simple CASE is blr_decode - NO cast wrapper; the ELSE
        // is one extra result, its absence unmarked
        pin(
            "SELECT ID FROM T WHERE CASE ID WHEN 1 THEN 'a' WHEN 2 THEN 'b' ELSE 'c' END = 'a'",
            "0543014A015401472FCB170102494402150800010000001508000200000003150F0000010061150F0000010062150F0000010063150F0000010061FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE CASE ID WHEN 1 THEN 'a' WHEN 2 THEN 'b' END = 'a'",
            "0543014A015401472FCB170102494402150800010000001508000200000002150F0000010061150F0000010062150F0000010061FF4C",
        );
        // COALESCE: a count byte and the values, NO cast wrapper -
        // field arguments are fine here (no dsc to compute)
        pin(
            "SELECT ID FROM T WHERE COALESCE(A, 0) = 5",
            "0543014A015401472FCA02170101411508000000000015080005000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE COALESCE(A, ID, 0) = 5",
            "0543014A015401472FCA031701014117010249441508000000000015080005000000FF4C",
        );
        // NULLIF(a, b) is cast(value_if(a = b, NULL, a)) - the dsc
        // from the BRANCHES (NULL, a), so b never shapes it
        pin(
            "SELECT ID FROM T WHERE NULLIF(1, 2.55) = 1",
            "0543014A015401472F830800692F150800010000001508FEFF0000002D1508000100000015080001000000FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NULLIF('ab', 'cd') = 'ab'",
            "0543014A015401472F830F00000200692F150F000002006162150F0000020063642D150F000002006162150F000002006162FF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NULLIF('abc', 'z') = 'a'",
            "0543014A015401472F830F00000300692F150F00000300616263150F000001007A2D150F00000300616263150F0000010061FF4C",
        );
    }

    #[test]
    fn compiles_slice_five_shapes_byte_for_byte() {
        // EXISTS is blr_any over ONE rse; the subquery's WHERE is
        // that rse's boolean and its select list leaves no trace
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473C43014A02553202472F1702035549441701024944FFFF4C",
        );
        // SELECT * compiles identically
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT * FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473C43014A02553202472F1702035549441701024944FFFF4C",
        );
        // NOT EXISTS keeps a REAL blr_not (no inverse verb)
        pin(
            "SELECT ID FROM T WHERE NOT EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473B3C43014A02553202472F1702035549441701024944FFFF4C",
        );
        // SINGULAR is blr_unique, same single-rse shape
        pin(
            "SELECT ID FROM T WHERE SINGULAR (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473E43014A02553202472F1702035549441701024944FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NOT SINGULAR (SELECT 1 FROM U2 WHERE U2.UID = T.ID)",
            "0543014A015401473B3E43014A02553202472F1702035549441701024944FFFF4C",
        );
        // IN (SELECT ...) is blr_ansi_any: an rse whose single STREAM
        // IS THE SUBQUERY'S RSE, then the comparison as the OUTER
        // rse's boolean; = ANY compiles byte-identical
        pin(
            "SELECT ID FROM T WHERE A IN (SELECT UA FROM U2)",
            "0543014A0154014797430143014A02553202FF472F170101411702025541FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE A = ANY (SELECT UA FROM U2)",
            "0543014A0154014797430143014A02553202FF472F170101411702025541FFFF4C",
        );
        // NOT IN: the quantifier FLIPS to ansi_all, the comparison
        // INVERTS to neq
        pin(
            "SELECT ID FROM T WHERE A NOT IN (SELECT UA FROM U2)",
            "0543014A015401479E430143014A02553202FF4730170101411702025541FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NOT (A = ANY (SELECT UA FROM U2))",
            "0543014A015401479E430143014A02553202FF4730170101411702025541FFFF4C",
        );
        // ALL keeps the WRITTEN comparison; NOT (> ALL) flips back to
        // ansi_any with the INVERSE (leq)
        pin(
            "SELECT ID FROM T WHERE A > ALL (SELECT UA FROM U2)",
            "0543014A015401479E430143014A02553202FF4731170101411702025541FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE NOT (A > ALL (SELECT UA FROM U2))",
            "0543014A0154014797430143014A02553202FF4734170101411702025541FFFF4C",
        );
        // SOME == ANY; a correlated WHERE sits inside the INNER rse
        pin(
            "SELECT ID FROM T WHERE A = SOME (SELECT UA FROM U2 WHERE U2.UID = T.ID)",
            "0543014A0154014797430143014A02553202472F1702035549441701024944FF472F170101411702025541FFFF4C",
        );
        // an aliased subquery stream is blr_relation2, and a bare
        // select column binds to the subquery's OWN stream
        pin(
            "SELECT ID FROM T WHERE A IN (SELECT UA FROM U2 X WHERE X.UA > 0)",
            "0543014A0154014797430143019202553203225822024731170202554115080000000000FF472F170101411702025541FFFF4C",
        );
        // context numbering CONTINUES across subqueries: T=1, U2=2,
        // then the subquery's V3T takes 3
        pin(
            "SELECT T.ID FROM T JOIN U2 ON T.ID = U2.UID WHERE EXISTS (SELECT 1 FROM V3T WHERE V3T.VID = T.A)",
            "05430177024A0154014A02553202472F1701024944170203554944FF473C43014A0356335403472F17030356494417010141FFFF4C",
        );
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID) OR EXISTS (SELECT 1 FROM V3T WHERE V3T.VID = T.ID)",
            "0543014A01540147393C43014A02553202472F1702035549441701024944FF3C43014A0356335403472F1703035649441701024944FFFF4C",
        );
        // subqueries compose with plain terms
        pin(
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 WHERE U2.UID = T.ID) AND A > 0",
            "0543014A015401473A3C43014A02553202472F1702035549441701024944FF311701014115080000000000FF4C",
        );
    }

    #[test]
    fn refuses_outside_the_surface() {
        // shapes this slice has NOT verified against the engine refuse
        // rather than guess
        for sql in [
            "SELECT ID FROM T ORDER BY ID",          // trailing clause
            "UPDATE T SET A = 1",                    // not a SELECT
            "SELECT COUNT(*) FROM T",                // aggregates
            // a BARE field in a multi-stream statement: the engine
            // resolves it through the catalog; catalog-free, we refuse
            "SELECT T.ID FROM T, U2 WHERE ID = 1",
            "SELECT T.ID FROM T, U2, T WHERE T.ID = 1 AND X.A = 2", // bad qualifier
            // an unknown name followed by '(' is a UDF or an
            // unconverted built-in - never a field
            "SELECT ID FROM T WHERE FOO(A) = 1",
            "SELECT ID FROM T WHERE DECODE(A, 1, 2) = 1",
            // SUBSTRING without FOR: layout not yet probed
            "SELECT ID FROM T WHERE SUBSTRING(S FROM 1) = 'a'",
            "SELECT ID FROM T CROSS JOIN U2",        // no ON clause
            // a FIELD branch in a cast-wrapped conditional: its dsc
            // lives in the catalog - never guess a descriptor
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN A ELSE 0 END = 1",
            "SELECT ID FROM T WHERE NULLIF(A, 0) = 5",
            // single-argument COALESCE is a syntax error IN THE ENGINE
            "SELECT ID FROM T WHERE COALESCE(A) = 5",
            // unprobed cast targets and unprobed unifications
            "SELECT ID FROM T WHERE CAST(A AS FLOAT) = 1",
            "SELECT ID FROM T WHERE CAST(A AS NUMERIC(30)) = 1",
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN NULL ELSE NULL END IS NULL",
            "SELECT ID FROM T WHERE CASE WHEN A > 5 THEN 'x' ELSE 0 END = 'x'",
            // a scalar subselect as a VALUE: unconverted
            "SELECT ID FROM T WHERE A = (SELECT UA FROM U2)",
            // a subquery inside an ON clause would interleave the
            // join chain's stream numbering: unprobed
            "SELECT T.ID FROM T JOIN U2 ON EXISTS (SELECT 1 FROM V3T WHERE V3T.VID = T.ID)",
            // multi-stream subqueries and multi-column select lists
            "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM U2 JOIN V3T ON U2.UID = V3T.VID)",
            "SELECT ID FROM T WHERE A IN (SELECT UA, UID FROM U2)",
        ] {
            assert!(compile_view_select(sql).is_none(), "{sql} was compiled");
        }
        // double negation cancels
        assert_eq!(
            compile_view_select("SELECT ID FROM T WHERE NOT (NOT (A > 5))"),
            compile_view_select("SELECT ID FROM T WHERE A > 5"),
        );
    }
}
