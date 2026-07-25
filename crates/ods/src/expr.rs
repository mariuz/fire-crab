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

/// A compiled scalar-expression tree.
#[derive(Clone, Debug, PartialEq)]
pub enum Expr {
    /// `blr_field`: a row column named within a context (0 for a computed
    /// field's own relation).
    Field { context: u8, name: String },
    /// `blr_literal blr_long`: a 32-bit integer, scale 0.
    IntLiteral(i32),
    Add(Box<Expr>, Box<Expr>),
    Subtract(Box<Expr>, Box<Expr>),
    Multiply(Box<Expr>, Box<Expr>),
    Divide(Box<Expr>, Box<Expr>),
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
            Expr::IntLiteral(v) => {
                out.push(BLR_LITERAL);
                out.push(BLR_LONG);
                out.push(0); // scale
                out.extend_from_slice(&v.to_le_bytes());
            }
            Expr::Add(l, r) => Self::binop(out, BLR_ADD, l, r),
            Expr::Subtract(l, r) => Self::binop(out, BLR_SUBTRACT, l, r),
            Expr::Multiply(l, r) => Self::binop(out, BLR_MULTIPLY, l, r),
            Expr::Divide(l, r) => Self::binop(out, BLR_DIVIDE, l, r),
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
            Expr::IntLiteral(_) => {}
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
}
