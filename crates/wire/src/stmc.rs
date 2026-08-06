//! THE STATEMENT CACHE - the plan a statement resolves to, kept, so
//! the same text does not have to be planned twice.
//!
//! Measured with `FC_SRV_TIME=1` on an indexed table, an INSERT of
//! 3.6ms: **the SELECT plan 1003us and the DML plan 420us**, against a
//! record write of 2us and index maintenance of 6us. Most of the
//! SELECT's share is `choose_index`, which calls the optimizer, which
//! re-derives its answer from the SQL text and the index metadata
//! every single time - for a statement the client sends over and over.
//!
//! The engine caches prepared statements and drops them when the
//! metadata they were compiled against changes; this does the same,
//! keyed by the SAME GENERATION the metadata cache uses, so one DDL
//! invalidates both.
//!
//! WHAT IT IS NOT. It is keyed by the statement's TEXT, so a client
//! that inlines its values (`WHERE ID = 1`, `WHERE ID = 2`, ...) makes
//! a new entry each time and hits nothing - which is why the cache is
//! BOUNDED and drops everything when it fills rather than growing
//! without limit. Parameterised statements, which is what the cache is
//! for, hit every time after the first.
//!
//! `FC_NO_STMTCACHE=1` turns it off, so a gate can show the same
//! answers with and without it.
//!
//! # Why this is CONVERTED AND NOT WIRED
//!
//! Wiring it made a statement answer wrongly, which is exactly what a
//! cache must never do, and the reason is worth more than the cache:
//! **a plan is not a pure function of (schema, text)**. An unfiltered
//! `SELECT COUNT(*)` is FOLDED TO A CONSTANT at prepare time - the
//! planner counts the records and answers `Plan::Scalar(n)` - so a
//! cached plan freezes the count at whatever it was when the text was
//! first seen. Measured, with the cache on: 1 row, insert a row, ask
//! again - 1. The same query WITH a filter, which is not folded,
//! answered 2 correctly.
//!
//! So the prepare-time fold has to move to EXECUTE before this can be
//! on the path, and that is the next step: an unfiltered COUNT(*)
//! should plan to the aggregate the FILTERED one already plans to, and
//! the fetch should compute it. Then the cache holds only what the
//! schema decides, and this module goes in unchanged - it is written
//! and tested against that day.
//!
//! (The same question is worth asking of every other plan-time
//! shortcut before it is trusted: what did the planner READ that the
//! schema does not decide?)

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

/// How many prepared statements one database keeps. The engine's own
/// cache is bounded by memory; this is bounded by count, and when it
/// fills it is emptied rather than evicted one at a time - a cache that
/// grows without limit inside a long-lived server is a leak with good
/// manners.
const CAPACITY: usize = 256;

#[derive(Default)]
pub struct Stats {
    pub hits: AtomicU64,
    pub misses: AtomicU64,
    pub invalidations: AtomicU64,
    pub evictions: AtomicU64,
}

fn stats() -> &'static Stats {
    static S: OnceLock<Stats> = OnceLock::new();
    S.get_or_init(Stats::default)
}

pub fn stats_line() -> String {
    let s = stats();
    format!(
        "hits {} misses {} invalidations {} evictions {}",
        s.hits.load(Ordering::Relaxed),
        s.misses.load(Ordering::Relaxed),
        s.invalidations.load(Ordering::Relaxed),
        s.evictions.load(Ordering::Relaxed),
    )
}

fn enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("FC_NO_STMTCACHE").is_err())
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// One database's prepared statements.
pub struct DbStatements<P, D> {
    cache: Mutex<HashMap<(u64, String), Arc<(P, Vec<D>)>>>,
}

impl<P, D> Default for DbStatements<P, D> {
    fn default() -> Self {
        DbStatements {
            cache: Mutex::new(HashMap::new()),
        }
    }
}

impl<P: Clone, D: Clone> DbStatements<P, D> {
    /// The plan this text resolves to under `generation`, from the
    /// cache or from `plan`.
    ///
    /// `plan` returning `None` is NOT cached: a statement this server
    /// cannot plan is a refusal, and refusals are cheap to repeat and
    /// dangerous to remember (the next attempt may be against a schema
    /// that can answer it - the generation covers DDL, but not the
    /// reasons a planner declines).
    pub fn plan<F>(&self, generation: u64, sql: &str, plan: F) -> Option<(P, Vec<D>)>
    where
        F: FnOnce() -> Option<(P, Vec<D>)>,
    {
        if !enabled() {
            return plan();
        }
        let key = (generation, sql.to_string());
        if let Some(hit) = lock(&self.cache).get(&key) {
            stats().hits.fetch_add(1, Ordering::Relaxed);
            return Some((hit.0.clone(), hit.1.clone()));
        }
        stats().misses.fetch_add(1, Ordering::Relaxed);
        let built = plan()?;
        let mut c = lock(&self.cache);
        if c.len() >= CAPACITY {
            // full: everything here was planned against some generation,
            // and dropping the lot costs one re-plan each rather than a
            // policy nobody has measured
            c.clear();
            stats().evictions.fetch_add(1, Ordering::Relaxed);
        }
        c.insert(key, Arc::new((built.0.clone(), built.1.clone())));
        Some(built)
    }

    /// The schema changed: every plan here was compiled against the old
    /// one.
    pub fn invalidate(&self) {
        let mut c = lock(&self.cache);
        if !c.is_empty() {
            c.clear();
            stats().invalidations.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn len(&self) -> usize {
        lock(&self.cache).len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn the_same_text_is_planned_once_per_schema() {
        let c: DbStatements<String, u8> = DbStatements::default();
        let planned = AtomicUsize::new(0);
        let mut once = || {
            planned.fetch_add(1, Ordering::Relaxed);
            Some(("PLAN".to_string(), vec![1u8]))
        };
        assert!(c.plan(0, "SELECT 1", &mut once).is_some());
        assert!(c.plan(0, "SELECT 1", &mut once).is_some());
        assert_eq!(planned.load(Ordering::Relaxed), 1);

        // a different generation is a different schema
        assert!(c.plan(1, "SELECT 1", &mut once).is_some());
        assert_eq!(planned.load(Ordering::Relaxed), 2);

        // ...and so is a different text
        assert!(c.plan(1, "SELECT 2", &mut once).is_some());
        assert_eq!(planned.load(Ordering::Relaxed), 3);
    }

    #[test]
    fn a_refusal_is_not_remembered() {
        let c: DbStatements<String, u8> = DbStatements::default();
        let tried = AtomicUsize::new(0);
        let mut never = || {
            tried.fetch_add(1, Ordering::Relaxed);
            None
        };
        assert!(c.plan(0, "NONSENSE", &mut never).is_none());
        assert!(c.plan(0, "NONSENSE", &mut never).is_none());
        assert_eq!(tried.load(Ordering::Relaxed), 2, "refusals are re-decided");
        assert!(c.is_empty());
    }

    #[test]
    fn it_is_bounded() {
        let c: DbStatements<String, u8> = DbStatements::default();
        for i in 0..(CAPACITY + 10) {
            let _ = c.plan(0, &format!("SELECT {}", i), || {
                Some((format!("P{}", i), vec![]))
            });
        }
        assert!(c.len() <= CAPACITY, "a cache in a long-lived server has a ceiling");
    }

    #[test]
    fn ddl_drops_every_plan() {
        let c: DbStatements<String, u8> = DbStatements::default();
        let _ = c.plan(0, "SELECT 1", || Some(("P".into(), vec![])));
        assert_eq!(c.len(), 1);
        c.invalidate();
        assert!(c.is_empty());
    }
}
