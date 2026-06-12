//! PB API-rules engine, v1: substitution lowering.
//!
//! A rule string (`owner = @request.auth.id && status = 'open'`) is parsed
//! with the same PB filter grammar, with `@request.auth.<field>` resolved to
//! the CALLER's literal value at request time (guest → `""`/null). The result
//! is an engine filter:
//! - list/view → AND-merged into the query filter (rows the rule excludes
//!   simply don't exist for the caller — PB semantics);
//! - update/delete → AND-merged into the WHERE (0 affected → 404);
//! - create → evaluated IN MEMORY against the lowered would-be record.
//!
//! Anything v1 cannot faithfully evaluate (`@collection.*`, `:modifiers`,
//! `@request.body/query/headers`) fails CLOSED with an audit line — a rule
//! must never silently widen.

use data_plane_core::{CmpOp, Filter};
use serde_json::{json, Value};

use super::PbAuth;

/// The caller context a rule can reference.
pub(crate) struct RuleCtx {
    /// Shaped auth record (None for guests).
    pub auth: Option<Value>,
    pub superuser: bool,
}

impl RuleCtx {
    pub(crate) fn from_auth(auth: &PbAuth, record: Option<Value>) -> Self {
        Self {
            auth: record,
            superuser: matches!(auth, PbAuth::Superuser),
        }
    }

    fn resolve(&self, reference: &str) -> Option<Value> {
        let field = reference.strip_prefix("@request.auth.")?;
        Some(match self.auth.as_ref().and_then(|a| a.get(field)) {
            Some(v) => v.clone(),
            // PB renders an absent auth value as the zero value — guests
            // compare as empty string.
            None => json!(""),
        })
    }
}

/// Outcome of lowering a rule for query-shaped ops.
pub(crate) enum Lowered {
    /// Superuser or empty rule: no extra constraint.
    Open,
    /// AND this engine-filter wire shape into the operation.
    Constrain(Value),
    /// The rule folded to FALSE for this caller (e.g. a guest with
    /// `owner = @request.auth.id` and an empty owner is still Constrain, but
    /// `@request.auth.id != ''` folds): list → empty, view/update/delete →
    /// 404, create → 400. Matches nothing, ever.
    Never,
    /// Locked (None rule, non-superuser) or unsupported construct.
    Deny,
}

/// Lower `rule` for the caller. `None` rule = locked (superuser only),
/// `""` = public, expression = parse + substitute.
pub(crate) fn lower_rule(rule: Option<&String>, ctx: &RuleCtx) -> Lowered {
    if ctx.superuser {
        return Lowered::Open;
    }
    let Some(raw) = rule else {
        return Lowered::Deny;
    };
    if raw.trim().is_empty() {
        return Lowered::Open;
    }
    match super::filter::parse_pb_filter_with(raw, &|r| ctx.resolve(r)) {
        Ok(ast) => match ast.fold() {
            data_plane_core::Folded::AlwaysTrue => Lowered::Open,
            data_plane_core::Folded::AlwaysFalse => Lowered::Never,
            data_plane_core::Folded::Constrained => {
                Lowered::Constrain(super::records::filter_to_wire(&ast))
            }
        },
        Err(e) => {
            tracing::warn!(target: "audit", event = "pb_rule_unsupported", rule = %raw, error = %e,
                "rule construct not supported by the v1 engine — failing CLOSED");
            Lowered::Deny
        }
    }
}

/// AND two optional engine filters.
pub(crate) fn and_filters(base: Option<Value>, extra: Value) -> Value {
    match base {
        Some(b) => json!({ "$and": [b, extra] }),
        None => extra,
    }
}

/// In-memory evaluation for createRule: does `record` satisfy the filter?
pub(crate) fn eval(filter: &Filter, record: &Value) -> bool {
    match filter {
        Filter::And(parts) => parts.iter().all(|p| eval(p, record)),
        Filter::Or(parts) => parts.iter().any(|p| eval(p, record)),
        Filter::Not(inner) => !eval(inner, record),
        Filter::Cmp { field, op, value } => {
            let got = record.get(field).cloned().unwrap_or(Value::Null);
            cmp_values(&got, *op, value)
        }
        Filter::In { field, values } => {
            let got = record.get(field).cloned().unwrap_or(Value::Null);
            values.iter().any(|v| loose_eq(&got, v))
        }
        Filter::Like { field, pattern, .. } => {
            let got = record.get(field).and_then(|v| v.as_str()).unwrap_or("");
            let pat = pattern.as_str().unwrap_or("");
            like_match(got, pat)
        }
        Filter::Between { field, low, high } => {
            let got = record.get(field).cloned().unwrap_or(Value::Null);
            cmp_values(&got, CmpOp::Gte, low) && cmp_values(&got, CmpOp::Lte, high)
        }
        Filter::IsNull { field, negate } => {
            let is_null = record.get(field).map(Value::is_null).unwrap_or(true);
            is_null != *negate
        }
    }
}

fn loose_eq(a: &Value, b: &Value) -> bool {
    if a == b {
        return true;
    }
    match (a.as_f64(), b.as_f64()) {
        (Some(x), Some(y)) => x == y,
        _ => match (a.as_str(), b.as_str()) {
            (Some(x), Some(y)) => x == y,
            // empty-vs-null are PB-equal zero values
            _ => (a.is_null() && b.as_str() == Some("")) || (b.is_null() && a.as_str() == Some("")),
        },
    }
}

fn cmp_values(a: &Value, op: CmpOp, b: &Value) -> bool {
    use std::cmp::Ordering::*;
    let ord = if let (Some(x), Some(y)) = (a.as_f64(), b.as_f64()) {
        x.partial_cmp(&y)
    } else {
        let x = a.as_str().map(str::to_string).unwrap_or_else(|| a.to_string());
        let y = b.as_str().map(str::to_string).unwrap_or_else(|| b.to_string());
        Some(x.cmp(&y))
    };
    match (op, ord) {
        (CmpOp::Eq, _) => loose_eq(a, b),
        (CmpOp::Ne, _) => !loose_eq(a, b),
        (CmpOp::Lt, Some(Less)) => true,
        (CmpOp::Lte, Some(Less | Equal)) => true,
        (CmpOp::Gt, Some(Greater)) => true,
        (CmpOp::Gte, Some(Greater | Equal)) => true,
        _ => false,
    }
}

/// SQL-LIKE matching (`%` multi, `_` single), case-insensitive like PB's `~`.
fn like_match(text: &str, pattern: &str) -> bool {
    fn inner(t: &[char], p: &[char]) -> bool {
        match (t, p) {
            (_, []) => t.is_empty(),
            (_, ['%', rest @ ..]) => {
                (0..=t.len()).any(|i| inner(&t[i..], rest))
            }
            ([], _) => false,
            ([tc, trest @ ..], [pc, prest @ ..]) => {
                (*pc == '_' || tc.eq_ignore_ascii_case(pc)) && inner(trest, prest)
            }
        }
    }
    let t: Vec<char> = text.to_lowercase().chars().collect();
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    inner(&t, &p)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(auth: Option<Value>) -> RuleCtx {
        RuleCtx { auth, superuser: false }
    }

    #[test]
    fn lowers_auth_substitution() {
        let c = ctx(Some(json!({ "id": "user1user1user1" })));
        match lower_rule(Some(&"owner = @request.auth.id".to_string()), &c) {
            Lowered::Constrain(f) => {
                assert_eq!(f, json!({ "owner": { "$eq": "user1user1user1" } }));
            }
            _ => panic!("expected Constrain"),
        }
    }

    #[test]
    fn guest_substitutes_empty_and_locked_denies() {
        let g = ctx(None);
        match lower_rule(Some(&"owner = @request.auth.id".to_string()), &g) {
            Lowered::Constrain(f) => assert_eq!(f, json!({ "owner": { "$eq": "" } })),
            _ => panic!("guest still gets a (never-matching) constraint"),
        }
        assert!(matches!(lower_rule(None, &g), Lowered::Deny));
        assert!(matches!(lower_rule(Some(&String::new()), &g), Lowered::Open));
    }

    #[test]
    fn unsupported_constructs_fail_closed() {
        let c = ctx(Some(json!({ "id": "u" })));
        for rule in [
            "@collection.other.x = 1",
            "title:isset = true",
            "@request.body.x = 1",
        ] {
            assert!(
                matches!(lower_rule(Some(&rule.to_string()), &c), Lowered::Deny),
                "{rule} must deny"
            );
        }
    }

    #[test]
    fn eval_covers_create_rule_shapes() {
        let rec = json!({ "owner": "u1", "status": "open", "n": 5, "title": "hello world" });
        let f = |s: &str| {
            super::super::filter::parse_pb_filter_with(s, &|r| {
                (r == "@request.auth.id").then(|| json!("u1"))
            })
            .unwrap()
        };
        assert!(eval(&f("owner = @request.auth.id"), &rec));
        assert!(!eval(&f("owner != @request.auth.id"), &rec));
        assert!(eval(&f("n > 3 && status = 'open'"), &rec));
        assert!(eval(&f("title ~ 'world'"), &rec));
        assert!(!eval(&f("title ~ 'mars'"), &rec));
        assert!(eval(&f("missing = null"), &rec));
        assert!(eval(&f("n >= 5 || n < 0"), &rec));
    }
}
