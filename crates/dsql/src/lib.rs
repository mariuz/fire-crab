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
    pub const EQL: u8 = 0x2F;
    pub const NEQ: u8 = 0x30;
    pub const GTR: u8 = 0x31;
    pub const GEQ: u8 = 0x32;
    pub const LSS: u8 = 0x33;
    pub const LEQ: u8 = 0x34;
}

/// A value position in a boolean leaf.
#[derive(Clone, Debug, PartialEq)]
enum Val {
    /// an unquoted identifier, stored UPPERCASED like the engine does
    Field(String),
    /// integer literal - blr_long holds 32 bits; wider refuses
    Int(i32),
    /// decimal literal as (raw, scale): 12.50 is (1250, -2)
    Dec(i32, i8),
    Str(String),
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

#[derive(Clone, Debug)]
enum Bool {
    And(Box<Bool>, Box<Bool>),
    Or(Box<Bool>, Box<Bool>),
    /// survives only over Like and Missing - negate() folds the rest
    Not(Box<Bool>),
    Cmp(CmpOp, Val, Val),
    Missing(Val),
    Between(Val, Val, Val),
    Like(Val, Val),
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
        keep @ (Bool::Missing(_) | Bool::Like(..)) => Bool::Not(Box::new(keep)),
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

struct P<'a> {
    t: &'a [Tok],
    i: usize,
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

    fn val(&mut self) -> Option<Val> {
        let v = match self.t.get(self.i)? {
            Tok::Ident(x) if !is_keyword(x) => Val::Field(x.clone()),
            Tok::Int(n) => Val::Int(i32::try_from(*n).ok()?),
            Tok::Dec(r, s) => Val::Dec(i32::try_from(*r).ok()?, *s),
            Tok::Str(s) => Val::Str(s.clone()),
            _ => return None,
        };
        self.i += 1;
        Some(v)
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
            // a parenthesised boolean group; leaves carry no parens in
            // this slice, so no backtracking is needed
            self.i += 1;
            let inner = self.bool_or()?;
            if !matches!(self.t.get(self.i), Some(Tok::RParen)) {
                return None;
            }
            self.i += 1;
            return Some(inner);
        }
        self.leaf()
    }

    fn leaf(&mut self) -> Option<Bool> {
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
        if negated {
            return None;
        }
        if let Some(Tok::Cmp(op)) = self.t.get(self.i) {
            let op = *op;
            self.i += 1;
            let right = self.val()?;
            return Some(Bool::Cmp(op, left, right));
        }
        None
    }
}

fn is_keyword(w: &str) -> bool {
    matches!(
        w,
        "AND" | "OR" | "NOT" | "IS" | "NULL" | "BETWEEN" | "LIKE" | "WHERE" | "FROM" | "SELECT"
    )
}

// -------------------------------------------------------------- emitter

fn emit_val(out: &mut Vec<u8>, v: &Val) {
    match v {
        Val::Field(name) => {
            out.push(blr::FIELD);
            out.push(1); // context id: the single stream
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
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
    }
}

/// Compile a view-shaped SELECT to the BLR the engine's DSQL stores in
/// `RDB$VIEW_BLR` - byte for byte. `None` for anything outside the
/// converted surface (the caller refuses; this crate never guesses).
pub fn compile_view_select(sql: &str) -> Option<Vec<u8>> {
    let toks = lex(sql.trim().trim_end_matches(';'))?;
    let mut p = P { t: &toks, i: 0 };
    if !p.kw("SELECT") {
        return None;
    }
    // the select list leaves NO trace in the view BLR (probed) - skip
    // to FROM, but refuse list shapes this slice has not verified
    // (only bare columns and `*` are known to compile away)
    loop {
        match p.t.get(p.i)? {
            Tok::Ident(w) if w == "FROM" => {
                p.i += 1;
                break;
            }
            Tok::Ident(w) if !is_keyword(w) => p.i += 1,
            Tok::Comma => p.i += 1,
            Tok::Cmp(CmpOp::Gtr) => return None, // not reachable; guard
            _ => return None,
        }
    }
    let Some(Tok::Ident(table)) = p.t.get(p.i) else {
        return None;
    };
    if is_keyword(table) {
        return None;
    }
    let table = table.clone();
    p.i += 1;
    let boolean = if p.kw("WHERE") {
        Some(p.bool_or()?)
    } else {
        None
    };
    if p.i != p.t.len() {
        return None; // trailing clauses are outside this slice
    }

    let mut out = vec![blr::VERSION5, blr::RSE, 1, blr::RELATION];
    out.push(table.len() as u8);
    out.extend_from_slice(table.as_bytes());
    out.push(1); // context id
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
    fn refuses_outside_the_surface() {
        // shapes this slice has NOT verified against the engine refuse
        // rather than guess
        for sql in [
            "SELECT ID FROM T ORDER BY ID",       // trailing clause
            "SELECT ID FROM T WHERE A + 1 > 5",   // arithmetic value
            "SELECT ID FROM T, U",                // two streams
            "SELECT ID FROM T WHERE A IN (1, 2)", // IN not probed
            "SELECT ID FROM T WHERE A = 5000000000", // past blr_long
            "UPDATE T SET A = 1",                 // not a SELECT
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
