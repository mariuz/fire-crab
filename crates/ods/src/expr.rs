//! Compiling SQL scalar expressions to BLR - the encoder side of what
//! [crate::blr] decodes. A computed field, a CHECK constraint, and a trigger
//! body all reduce to an expression tree that the engine stores as BLR; this
//! emits that BLR byte-exactly (the opcodes and layout are probed from an
//! engine-created table's `RDB$COMPUTED_BLR`).
//!
//! This is the first slice of the expression compiler: field references,
//! integer literals, and the four arithmetic operators (prefix `op left
//! right`), wrapped as `blr_version5, <expr>, blr_eoc`. Comparison, boolean,
//! function and string operators - the rest of the surface a CHECK or a
//! trigger needs - build on this same tree.

// BLR opcodes (blr.h), confirmed against RDB$COMPUTED_BLR.
const BLR_VERSION5: u8 = 5;
const BLR_EOC: u8 = 76;
const BLR_LITERAL: u8 = 21;
const BLR_LONG: u8 = 8;
const BLR_FIELD: u8 = 23;
const BLR_ADD: u8 = 34;
const BLR_SUBTRACT: u8 = 35;
const BLR_MULTIPLY: u8 = 36;
const BLR_DIVIDE: u8 = 37;
// boolean opcodes, confirmed against RDB$TRIGGER_BLR of engine-created
// CHECK constraints
const BLR_BEGIN: u8 = 2;
const BLR_IF: u8 = 8;
const BLR_EQL: u8 = 47;
const BLR_NEQ: u8 = 48;
const BLR_GTR: u8 = 49;
const BLR_GEQ: u8 = 50;
const BLR_LSS: u8 = 51;
const BLR_LEQ: u8 = 52;
const BLR_OR: u8 = 57;
const BLR_AND: u8 = 58;
const BLR_VARIABLE: u8 = 26;
/// `blr_internal_info` (blr.h:325) - the engine's "ask the runtime" node
const BLR_INTERNAL_INFO: u8 = 177;
/// `GEN_ID(name, step)`: counted name, then the step expression
const BLR_GEN_ID: u8 = 101;
/// `NEXT VALUE FOR name`: the counted name alone
const BLR_GEN_ID2: u8 = 210;
/// `INFO_TYPE_TRIGGER_ACTION` (constants.h:320) - which DML action is
/// firing the trigger this body belongs to
const INFO_TYPE_TRIGGER_ACTION: i32 = 6;
const BLR_ABORT: u8 = 128;
const BLR_GDS_CODE: u8 = 0;
const BLR_END: u8 = 255;

/// A compiled scalar-expression tree.
#[derive(Clone, Debug, PartialEq)]
pub enum Expr {
    /// `blr_field`: a row column named within a context (0 for a computed
    /// field's own relation).
    Field { context: u8, name: String },
    /// `blr_variable`: a PSQL local variable by number (a trigger's
    /// DECLARE VARIABLE slot).
    Variable(u16),
    /// `blr_literal blr_long`: a 32-bit integer, scale 0.
    IntLiteral(i32),
    /// `blr_literal blr_int64`: a 64-bit integer literal, scale 0 - the
    /// shape the exe decoder reads out of engine-written BLR (scale
    /// byte, then 8 LE bytes), emitted only for values OUTSIDE i32 so
    /// every existing stored shape keeps its exact bytes.
    Int64Literal(i64),
    /// `blr_null` (45): the NULL keyword as a value - probed, it is the
    /// same byte the engine's own DECLARE null-init assignments carry.
    NullLiteral,
    /// A quoted string. PSQL conditions compare text with PAD-SPACE
    /// semantics (measured: `'x' = 'x '` is TRUE, `'x' = 'X'` is not).
    /// The CHECK-constraint surface stays INT-ONLY: `infer_int_rank`
    /// answers None for this node, so a CHECK carrying one refuses as
    /// it always did, and the BLR below is never stored.
    TextLiteral(String),
    Add(Box<Expr>, Box<Expr>),
    Subtract(Box<Expr>, Box<Expr>),
    Multiply(Box<Expr>, Box<Expr>),
    Divide(Box<Expr>, Box<Expr>),
    /// `blr_fid 0, 0,0`: the `VALUE` keyword of a DOMAIN CHECK - the
    /// engine reserves context 0 / field id 0 for it in the stored
    /// validation BLR (dumped: `CHECK (VALUE > 100)` is `blr_gtr,
    /// blr_fid 0 0,0, blr_literal ...`), remapping it to the real
    /// column at statement compile. Only [domain_validation_blr]
    /// emits it; it never appears in a trigger or computed column.
    DomainValue,
    /// `INSERTING` / `UPDATING` / `DELETING` inside a trigger body: the
    /// ACTION firing it, as the number the engine compares against (1
    /// INSERT, 2 UPDATE, 3 DELETE).
    ///
    /// The engine has no boolean node for these - `parse.y`'s
    /// `trigger_action_predicate` builds `blr_eql(blr_internal_info(6),
    /// <1|2|3>)`, where 6 is `INFO_TYPE_TRIGGER_ACTION` - so this is the
    /// INTERNAL INFO half of that comparison and the literal beside it
    /// says which action the body asked about.
    TriggerAction,
    /// `GEN_ID(<name>, <step>)` - `blr_gen_id`, a COUNTED name, then
    /// the step as an ordinary expression. The engine's own dump of
    /// `NEW.ID = GEN_ID(G, 1)`:
    /// `blr_gen_id, 1, 'G', blr_literal, blr_long, 0, 1,0,0,0`.
    GenId { name: String, step: Box<Expr> },
    /// `NEXT VALUE FOR <name>` - `blr_gen_id2`, the counted name ALONE.
    /// A separate verb, not sugar for `GEN_ID(name, 1)`: the engine
    /// emits `blr_gen_id2, 1, 'G'` and nothing else (probed).
    GenId2 { name: String },
}

impl Expr {
    /// Emit this node's BLR (no version/eoc wrapper) onto `out`, in the
    /// engine's prefix order: an operator's byte, then its operands.
    pub fn emit(&self, out: &mut Vec<u8>) {
        match self {
            Expr::Field { context, name } => {
                out.push(BLR_FIELD);
                out.push(*context);
                out.push(name.len() as u8);
                out.extend_from_slice(name.as_bytes());
            }
            Expr::Variable(n) => {
                out.push(BLR_VARIABLE);
                out.extend_from_slice(&n.to_le_bytes());
            }
            Expr::IntLiteral(v) => {
                out.push(BLR_LITERAL);
                out.push(BLR_LONG);
                out.push(0); // scale
                out.extend_from_slice(&v.to_le_bytes());
            }
            Expr::Int64Literal(v) => {
                out.push(BLR_LITERAL);
                out.push(16); // blr_int64
                out.push(0); // scale
                out.extend_from_slice(&v.to_le_bytes());
            }
            Expr::NullLiteral => out.push(45), // blr_null - probed
            Expr::TextLiteral(t) => {
                // GOLD-PINNED from an engine-created CHECK (V = 'x'):
                // blr_literal blr_text2, charset u16 LE (0 = NONE),
                // length u16 LE, then the bytes - the first guess here
                // used plain blr_text with no charset and stayed
                // guarded out of every stored path until the real
                // bytes were probed
                out.push(BLR_LITERAL);
                out.push(15); // blr_text2
                out.extend_from_slice(&0u16.to_le_bytes()); // charset NONE
                out.extend_from_slice(&(t.len() as u16).to_le_bytes());
                out.extend_from_slice(t.as_bytes());
            }
            Expr::Add(l, r) => Self::binop(out, BLR_ADD, l, r),
            Expr::Subtract(l, r) => Self::binop(out, BLR_SUBTRACT, l, r),
            Expr::Multiply(l, r) => Self::binop(out, BLR_MULTIPLY, l, r),
            Expr::Divide(l, r) => Self::binop(out, BLR_DIVIDE, l, r),
            Expr::DomainValue => {
                out.push(24); // blr_fid
                out.push(0); // context 0 - reserved for VALUE
                out.extend_from_slice(&0u16.to_le_bytes()); // field id 0
            }
            // blr_internal_info, then its operand: the info TYPE as an
            // ordinary long literal (parse.y builds it with
            // MAKE_const_slong(INFO_TYPE_TRIGGER_ACTION))
            Expr::TriggerAction => {
                out.push(BLR_INTERNAL_INFO);
                Expr::IntLiteral(INFO_TYPE_TRIGGER_ACTION).emit(out);
            }
            Expr::GenId { name, step } => {
                out.push(BLR_GEN_ID);
                out.push(name.len() as u8);
                out.extend_from_slice(name.as_bytes());
                step.emit(out);
            }
            Expr::GenId2 { name } => {
                out.push(BLR_GEN_ID2);
                out.push(name.len() as u8);
                out.extend_from_slice(name.as_bytes());
            }
        }
    }

    fn binop(out: &mut Vec<u8>, op: u8, l: &Expr, r: &Expr) {
        out.push(op);
        l.emit(out);
        r.emit(out);
    }

    /// The full BLR of a computed-field expression: `blr_version5, <expr>,
    /// blr_eoc`.
    pub fn to_blr(&self) -> Vec<u8> {
        let mut out = vec![BLR_VERSION5];
        self.emit(&mut out);
        out.push(BLR_EOC);
        out
    }

    /// The distinct field names this expression references, in first-seen
    /// order - a computed column's dependencies.
    pub fn field_refs(&self) -> Vec<String> {
        let mut refs = Vec::new();
        self.collect_refs(&mut refs);
        refs
    }

    fn collect_refs(&self, refs: &mut Vec<String>) {
        match self {
            Expr::Field { name, .. } => {
                if !refs.iter().any(|r| r == name) {
                    refs.push(name.clone());
                }
            }
            Expr::IntLiteral(_)
            | Expr::Int64Literal(_)
            | Expr::TextLiteral(_)
            | Expr::NullLiteral
            | Expr::Variable(_)
            | Expr::DomainValue
            // it names no column - it asks the runtime which action
            // is firing
            | Expr::TriggerAction
            // a draw names a GENERATOR, not a column
            | Expr::GenId2 { .. } => {}
            Expr::GenId { step, .. } => step.collect_refs(refs),
            Expr::Add(l, r)
            | Expr::Subtract(l, r)
            | Expr::Multiply(l, r)
            | Expr::Divide(l, r) => {
                l.collect_refs(refs);
                r.collect_refs(refs);
            }
        }
    }
}

/// A comparison operator of a boolean condition.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CmpOp {
    Eql,
    Neq,
    Gtr,
    Geq,
    Lss,
    Leq,
}

impl CmpOp {
    fn blr(self) -> u8 {
        match self {
            CmpOp::Eql => BLR_EQL,
            CmpOp::Neq => BLR_NEQ,
            CmpOp::Gtr => BLR_GTR,
            CmpOp::Geq => BLR_GEQ,
            CmpOp::Lss => BLR_LSS,
            CmpOp::Leq => BLR_LEQ,
        }
    }
    /// The comparison whose result is this one's logical NOT (two-valued;
    /// an UNKNOWN operand stays UNKNOWN either way, which is exactly why
    /// the negated form keeps SQL's "NULL passes a CHECK" semantics).
    pub fn inverted(self) -> CmpOp {
        match self {
            CmpOp::Eql => CmpOp::Neq,
            CmpOp::Neq => CmpOp::Eql,
            CmpOp::Gtr => CmpOp::Leq,
            CmpOp::Leq => CmpOp::Gtr,
            CmpOp::Geq => CmpOp::Lss,
            CmpOp::Lss => CmpOp::Geq,
        }
    }
}

/// A boolean condition tree - what a CHECK constraint's search condition
/// compiles from.
#[derive(Clone, Debug, PartialEq)]
pub enum Cond {
    Cmp(CmpOp, Expr, Expr),
    And(Box<Cond>, Box<Cond>),
    Or(Box<Cond>, Box<Cond>),
    Not(Box<Cond>),
    /// `<expr> IS NULL` - `blr_missing` (61)
    Missing(Expr),
    /// `<expr> IS NOT NULL` - the ONE place the engine emits `blr_not`
    /// (59) in a trigger condition: `blr_not(blr_missing(x))` (probed;
    /// every other NOT folds into inverted comparisons / De Morgan)
    NotMissing(Expr),
}

impl Cond {
    /// The logical negation, with every NOT pushed down to the
    /// comparisons (De Morgan) - the form the ENGINE stores a CHECK
    /// condition in: the trigger tests "the check FAILED", and an
    /// engine-written RDB$TRIGGER_BLR carries inverted comparison
    /// opcodes with no blr_not at all (probed: `CHECK (A = 1 OR
    /// NOT (A >= 10))` stores `blr_and(blr_neq, blr_geq)`).
    pub fn negated(&self) -> Cond {
        match self {
            Cond::Cmp(op, l, r) => Cond::Cmp(op.inverted(), l.clone(), r.clone()),
            Cond::And(a, b) => Cond::Or(Box::new(a.negated()), Box::new(b.negated())),
            Cond::Or(a, b) => Cond::And(Box::new(a.negated()), Box::new(b.negated())),
            Cond::Not(c) => c.normalized(),
            Cond::Missing(e) => Cond::NotMissing(e.clone()),
            Cond::NotMissing(e) => Cond::Missing(e.clone()),
        }
    }

    /// The same tree with every NOT pushed down (no Not nodes remain) -
    /// public since the trigger compiler folds its IF/WHILE conditions
    /// exactly as the engine's DSQL pass does (probed: `NOT (A > 1 AND
    /// A < 5)` stores `blr_or(blr_leq, blr_geq)`; only IS NULL keeps a
    /// blr_not, as [Cond::NotMissing]).
    pub fn normalized(&self) -> Cond {
        match self {
            Cond::Cmp(..) => self.clone(),
            Cond::And(a, b) => Cond::And(Box::new(a.normalized()), Box::new(b.normalized())),
            Cond::Or(a, b) => Cond::Or(Box::new(a.normalized()), Box::new(b.normalized())),
            Cond::Not(c) => c.negated(),
            Cond::Missing(_) | Cond::NotMissing(_) => self.clone(),
        }
    }

    /// Emit this condition's BLR (must be NOT-free - emit after
    /// [Cond::negated]/normalisation).
    fn emit(&self, out: &mut Vec<u8>) {
        match self {
            Cond::Cmp(op, l, r) => {
                out.push(op.blr());
                l.emit(out);
                r.emit(out);
            }
            Cond::And(a, b) => {
                out.push(BLR_AND);
                a.emit(out);
                b.emit(out);
            }
            Cond::Or(a, b) => {
                out.push(BLR_OR);
                a.emit(out);
                b.emit(out);
            }
            Cond::Missing(e) => {
                out.push(61); // blr_missing
                e.emit(out);
            }
            Cond::NotMissing(e) => {
                out.push(59); // blr_not
                out.push(61); // blr_missing
                e.emit(out);
            }
            Cond::Not(_) => unreachable!("emit is called on a normalised condition"),
        }
    }

    /// Whether the tree contains a NOT node. A user trigger's IF emits
    /// its condition AS WRITTEN (the engine uses blr_not there, which
    /// this compiler does not emit) - a caller supporting only the
    /// NOT-free positive form must refuse when this is true.
    pub fn has_not(&self) -> bool {
        match self {
            Cond::Cmp(..) | Cond::Missing(_) | Cond::NotMissing(_) => false,
            Cond::And(a, b) | Cond::Or(a, b) => a.has_not() || b.has_not(),
            Cond::Not(_) => true,
        }
    }

    /// Emit the condition POSITIVELY (as written - a user trigger's IF,
    /// unlike a CHECK's stored negation). The tree must be NOT-free
    /// ([Cond::has_not]).
    pub fn emit_positive(&self, out: &mut Vec<u8>) {
        self.emit(out);
    }

    /// Every [Expr] operand of the condition's comparisons, for the
    /// caller to type-check field references against its columns.
    pub fn operands(&self) -> Vec<&Expr> {
        let mut out = Vec::new();
        self.collect_operands(&mut out);
        out
    }

    fn collect_operands<'a>(&'a self, out: &mut Vec<&'a Expr>) {
        match self {
            Cond::Cmp(_, l, r) => {
                out.push(l);
                out.push(r);
            }
            Cond::And(a, b) | Cond::Or(a, b) => {
                a.collect_operands(out);
                b.collect_operands(out);
            }
            Cond::Not(c) => c.collect_operands(out),
            Cond::Missing(e) | Cond::NotMissing(e) => out.push(e),
        }
    }
}

/// The BLR of a CHECK constraint's trigger (both the before-insert and
/// the before-update trigger carry the same one, probed byte-for-byte):
///
///   blr_version5, blr_begin,
///     blr_if, <NEGATED search condition>,
///       blr_begin, blr_abort, blr_gds_code, 16, "check_constraint",
///       blr_end,
///     blr_end,   (no else branch)
///   blr_end, blr_eoc
///
/// i.e. "if the check FAILED, raise check_constraint". The stored
/// condition is [Cond::negated] - inverted comparisons, no blr_not -
/// so an UNKNOWN (NULL-operand) check does not raise, SQL's rule.
pub fn check_trigger_blr(cond: &Cond) -> Vec<u8> {
    let mut out = vec![BLR_VERSION5, BLR_BEGIN, BLR_IF];
    cond.negated().emit(&mut out);
    out.push(BLR_BEGIN);
    out.push(BLR_ABORT);
    out.push(BLR_GDS_CODE);
    let code = b"check_constraint";
    out.push(code.len() as u8);
    out.extend_from_slice(code);
    out.extend_from_slice(&[BLR_END, BLR_END, BLR_END, BLR_EOC]);
    out
}

/// The BLR of a DOMAIN CHECK, stored in `RDB$FIELDS.RDB$VALIDATION_BLR`:
/// the bare boolean condition POSITIVELY (unlike a table CHECK's
/// negated trigger), `blr_version5, <cond>, blr_eoc` - no wrapper
/// opcode. `VALUE` is [Expr::DomainValue] (`blr_fid 0, 0,0`). The
/// engine NORMALIZES a written NOT at CREATE, pushing it into inverted
/// comparisons (dumped: `CHECK (NOT (VALUE > 5))` stores `blr_leq`,
/// no blr_not; only IS NOT NULL keeps one, as `blr_not blr_missing` -
/// dumped from `CHECK (VALUE IS NOT NULL)`), which is exactly
/// [Cond::normalized].
pub fn domain_validation_blr(cond: &Cond) -> Vec<u8> {
    let mut out = vec![BLR_VERSION5];
    cond.normalized().emit(&mut out);
    out.push(BLR_EOC);
    out
}

/// The distinct field names a stored computed-column BLR references - the
/// decoder mirror of [Expr::field_refs], over exactly the opcode surface
/// [Expr::emit] writes (binary arithmetic, field references, `blr_long`
/// literals). None on ANY other opcode: the expression then references
/// who-knows-what, and a caller deciding whether a column may be dropped
/// must refuse rather than guess.
pub fn field_names_of_blr(b: &[u8]) -> Option<Vec<String>> {
    if b.first() != Some(&BLR_VERSION5) || b.last() != Some(&BLR_EOC) || b.len() < 2 {
        return None;
    }
    let mut names: Vec<String> = Vec::new();
    let mut i = 1;
    let end = b.len() - 1;
    while i < end {
        match b[i] {
            BLR_ADD | BLR_SUBTRACT | BLR_MULTIPLY | BLR_DIVIDE => i += 1,
            BLR_FIELD => {
                let len = *b.get(i + 2)? as usize;
                let name = std::str::from_utf8(b.get(i + 3..i + 3 + len)?).ok()?;
                if !names.iter().any(|n| n == name) {
                    names.push(name.to_string());
                }
                i += 3 + len;
            }
            BLR_LITERAL => {
                if b.get(i + 1) != Some(&BLR_LONG) {
                    return None;
                }
                i += 7; // literal, long, scale, 4 value bytes
            }
            _ => return None,
        }
    }
    Some(names)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(n: &str) -> Box<Expr> {
        Box::new(Expr::Field {
            context: 0,
            name: n.into(),
        })
    }
    fn i(v: i32) -> Box<Expr> {
        Box::new(Expr::IntLiteral(v))
    }

    #[test]
    fn computed_blr_matches_engine() {
        // golden bytes probed from RDB$COMPUTED_BLR of an engine-created table
        assert_eq!(
            Expr::Add(f("A"), f("B")).to_blr(),
            vec![5, 34, 23, 0, 1, 65, 23, 0, 1, 66, 76]
        );
        assert_eq!(
            Expr::Multiply(f("A"), f("B")).to_blr(),
            vec![5, 36, 23, 0, 1, 65, 23, 0, 1, 66, 76]
        );
        assert_eq!(
            Expr::Subtract(f("A"), f("B")).to_blr(),
            vec![5, 35, 23, 0, 1, 65, 23, 0, 1, 66, 76]
        );
        assert_eq!(
            Expr::Divide(f("A"), f("B")).to_blr(),
            vec![5, 37, 23, 0, 1, 65, 23, 0, 1, 66, 76]
        );
        // A + 10 : a literal operand
        assert_eq!(
            Expr::Add(f("A"), i(10)).to_blr(),
            vec![5, 34, 23, 0, 1, 65, 21, 8, 0, 10, 0, 0, 0, 76]
        );
        // (A + B) * 2 : nesting, in prefix order
        assert_eq!(
            Expr::Multiply(Box::new(Expr::Add(f("A"), f("B"))), i(2)).to_blr(),
            vec![5, 36, 34, 23, 0, 1, 65, 23, 0, 1, 66, 21, 8, 0, 2, 0, 0, 0, 76]
        );
    }

    #[test]
    fn field_refs_are_distinct_and_ordered() {
        let e = Expr::Add(f("A"), Box::new(Expr::Multiply(f("A"), f("B"))));
        assert_eq!(e.field_refs(), vec!["A".to_string(), "B".to_string()]);
    }

    fn nf(n: &str) -> Expr {
        // a CHECK trigger references its fields in context 1 (NEW)
        Expr::Field {
            context: 1,
            name: n.into(),
        }
    }

    /// Golden bytes probed from engine-created CHECK constraints'
    /// RDB$TRIGGER_BLR (tables CK1..CK4): the stored condition is the
    /// NEGATION, De Morgan pushed to inverted comparisons, wrapped as
    /// if-failed-then-abort.
    #[test]
    fn check_trigger_blr_matches_engine() {
        let tail: Vec<u8> = {
            let mut t = vec![2, 128, 0, 16];
            t.extend_from_slice(b"check_constraint");
            t.extend_from_slice(&[255, 255, 255, 76]);
            t
        };
        let blr = |cond_bytes: &[u8]| {
            let mut b = vec![5, 2, 8];
            b.extend_from_slice(cond_bytes);
            b.extend_from_slice(&tail);
            b
        };
        // CHECK (A > 0) -> if A <= 0 (blr_leq 52)
        assert_eq!(
            check_trigger_blr(&Cond::Cmp(CmpOp::Gtr, nf("A"), Expr::IntLiteral(0))),
            blr(&[52, 23, 1, 1, 65, 21, 8, 0, 0, 0, 0, 0])
        );
        // CHECK (A < B) -> if A >= B (blr_geq 50)
        assert_eq!(
            check_trigger_blr(&Cond::Cmp(CmpOp::Lss, nf("A"), nf("B"))),
            blr(&[50, 23, 1, 1, 65, 23, 1, 1, 66])
        );
        // CHECK (A <> 0 AND A <= 100) -> if A = 0 OR A > 100
        let c3 = Cond::And(
            Box::new(Cond::Cmp(CmpOp::Neq, nf("A"), Expr::IntLiteral(0))),
            Box::new(Cond::Cmp(CmpOp::Leq, nf("A"), Expr::IntLiteral(100))),
        );
        assert_eq!(
            check_trigger_blr(&c3),
            blr(&[57, 47, 23, 1, 1, 65, 21, 8, 0, 0, 0, 0, 0, 49, 23, 1, 1, 65, 21, 8, 0, 100, 0, 0, 0])
        );
        // CHECK (A = 1 OR NOT (A >= 10)) -> if A <> 1 AND A >= 10
        let c4 = Cond::Or(
            Box::new(Cond::Cmp(CmpOp::Eql, nf("A"), Expr::IntLiteral(1))),
            Box::new(Cond::Not(Box::new(Cond::Cmp(
                CmpOp::Geq,
                nf("A"),
                Expr::IntLiteral(10),
            )))),
        );
        assert_eq!(
            check_trigger_blr(&c4),
            blr(&[58, 48, 23, 1, 1, 65, 21, 8, 0, 1, 0, 0, 0, 50, 23, 1, 1, 65, 21, 8, 0, 10, 0, 0, 0])
        );
        // double negation normalises away
        let c5 = Cond::Not(Box::new(Cond::Not(Box::new(Cond::Cmp(
            CmpOp::Gtr,
            nf("A"),
            Expr::IntLiteral(0),
        )))));
        assert_eq!(
            check_trigger_blr(&c5),
            check_trigger_blr(&Cond::Cmp(CmpOp::Gtr, nf("A"), Expr::IntLiteral(0)))
        );
    }

    /// Decoding a compiled expression's BLR must recover exactly the
    /// names [Expr::field_refs] reports; any opcode outside the emitted
    /// surface must return None, never a partial (wrong) answer.
    #[test]
    fn field_names_round_trip_and_refuse_unknown_opcodes() {
        let e = Expr::Multiply(
            Box::new(Expr::Add(f("A"), i(10))),
            Box::new(Expr::Subtract(f("LONG_NAME"), f("A"))),
        );
        assert_eq!(
            field_names_of_blr(&e.to_blr()),
            Some(vec!["A".to_string(), "LONG_NAME".to_string()])
        );
        assert_eq!(field_names_of_blr(&Expr::IntLiteral(5).to_blr()), Some(vec![]));
        // blr_user_name (44) is outside the emitted surface
        assert_eq!(field_names_of_blr(&[5, 44, 76]), None);
        // a literal that is not blr_long
        assert_eq!(field_names_of_blr(&[5, 21, 15, 0, 0, 1, 0, 65, 76]), None);
        assert_eq!(field_names_of_blr(&[]), None);
    }
}

#[cfg(test)]
mod gen_blr_tests {
    use super::*;

    /// The engine's own dump of `NEW.ID = GEN_ID(G, 1)` in a trigger
    /// body: `blr_gen_id, 1, 'G', blr_literal, blr_long, 0, 1,0,0,0`.
    #[test]
    fn gen_id_is_a_counted_name_then_the_step() {
        let mut out = Vec::new();
        Expr::GenId { name: "G".into(), step: Box::new(Expr::IntLiteral(1)) }.emit(&mut out);
        assert_eq!(out, vec![101, 1, b'G', 21, 8, 0, 1, 0, 0, 0]);
    }

    /// ...and `NEXT VALUE FOR G` is a DIFFERENT verb with no step at
    /// all - `blr_gen_id2, 1, 'G'` (probed).
    #[test]
    fn next_value_for_is_the_name_alone() {
        let mut out = Vec::new();
        Expr::GenId2 { name: "G".into() }.emit(&mut out);
        assert_eq!(out, vec![210, 1, b'G']);
    }

    /// A draw names no COLUMN; a step that does is still walked.
    #[test]
    fn a_draw_names_no_column() {
        let mut refs = Vec::new();
        Expr::GenId2 { name: "G".into() }.collect_refs(&mut refs);
        assert!(refs.is_empty());
        Expr::GenId { name: "G".into(), step: Box::new(Expr::IntLiteral(1)) }
            .collect_refs(&mut refs);
        assert!(refs.is_empty());
    }
}
