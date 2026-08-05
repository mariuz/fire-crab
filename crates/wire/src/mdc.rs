//! THE METADATA CACHE - what `MET`/`MetadataCache` is for, and why a
//! statement should not have to re-read the catalog to be planned.
//!
//! Measured, with `FC_SRV_TIME=1` on a two-row table: an INSERT costs
//! 8.2ms end to end, and **5.6ms of it is building the plan** - the
//! work copy is 111us and the careful flush 957us. Planning is that
//! expensive because every plan re-derives the table from the FILE:
//! `RDB$RELATIONS` for the id, `RDB$RELATION_FIELDS` + `RDB$FIELDS` for
//! the columns, `RDB$FORMATS` blobs for the descriptors, and then the
//! index, check, foreign-key and trigger relations for the rest. Each
//! of those is a walk of a system relation's pages, and the answer is
//! the same for every statement until somebody changes the schema.
//!
//! So this holds those answers, per database, exactly as the engine's
//! metadata cache does - and the engine's invalidation rule is the one
//! that matters: **DDL is what makes metadata stale**, nothing else. A
//! million inserts do not change what a table's columns are. The cache
//! is therefore keyed by a GENERATION that only DDL (and a pool reload,
//! which means the file was replaced underneath us) advances.
//!
//! `FC_NO_MDC=1` turns it off, for the same reason `FC_NO_INDEX` and
//! `FC_NO_CAREFUL` exist: a gate that asserts the cache is on the path
//! is worth nothing unless the path can be taken without it.

use fire_crab_ods::format::Descriptor;
use fire_crab_ods::RelationColumn;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

/// Counters for the coverage half of a wiring gate: `hits` staying
/// zero means every statement still read the catalog off the pages.
#[derive(Default)]
pub struct Stats {
    pub hits: AtomicU64,
    pub misses: AtomicU64,
    pub invalidations: AtomicU64,
}

fn stats() -> &'static Stats {
    static S: OnceLock<Stats> = OnceLock::new();
    S.get_or_init(Stats::default)
}

pub fn stats_line() -> String {
    let s = stats();
    format!(
        "hits {} misses {} invalidations {}",
        s.hits.load(Ordering::Relaxed),
        s.misses.load(Ordering::Relaxed),
        s.invalidations.load(Ordering::Relaxed),
    )
}

fn enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("FC_NO_MDC").is_err())
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// What one relation is, as the catalog says: everything a plan needs
/// before it looks at the statement's own text.
pub struct Relation {
    pub id: u16,
    pub columns: Arc<Vec<RelationColumn>>,
    pub formats: Arc<Vec<(u8, Vec<Descriptor>)>>,
}

/// Anything else a plan derives from the catalog and cannot change
/// without DDL: the index operations of a relation, its NOT NULL
/// fields, its identity column, its qualified name. They are held the
/// same way and die the same way - by generation.
type Memo = std::sync::Arc<dyn std::any::Any + Send + Sync>;

#[derive(Default)]
struct Cache {
    /// bumped by DDL, and by the pool re-reading a replaced file
    generation: u64,
    /// the pool epoch these answers were derived under
    epoch: u64,
    /// (generation, UPPERCASE relation name) -> what the catalog said
    relations: HashMap<(u64, String), Arc<Relation>>,
    /// (generation, what it is, what it is about) -> the answer
    memos: HashMap<(u64, &'static str, String), Memo>,
}

/// One cache per database file, shared by its attachments - the engine's
/// metadata cache is per database too.
pub struct DbMetadata {
    cache: Mutex<Cache>,
}

impl DbMetadata {
    /// The relation, from the cache or from the file.
    ///
    /// `read` is the miss path: it walks the catalog exactly as the
    /// caller would have without a cache, so a miss costs what every
    /// statement used to cost and a hit costs a hash lookup.
    pub fn relation<F>(&self, name: &str, read: F) -> Option<Arc<Relation>>
    where
        F: FnOnce() -> Option<Relation>,
    {
        if !enabled() {
            return read().map(Arc::new);
        }
        let key = (self.generation(), name.to_ascii_uppercase());
        if let Some(hit) = lock(&self.cache).relations.get(&key) {
            stats().hits.fetch_add(1, Ordering::Relaxed);
            return Some(Arc::clone(hit));
        }
        stats().misses.fetch_add(1, Ordering::Relaxed);
        let built = Arc::new(read()?);
        let mut c = lock(&self.cache);
        // the generation may have moved while the catalog was being
        // read; storing under the key we looked up would then publish
        // an answer for a schema that no longer exists
        if c.generation == key.0 {
            c.relations.insert(key, Arc::clone(&built));
        }
        Some(built)
    }

    /// One more answer about the schema, held until DDL - see [Memo].
    ///
    /// `kind` names what it is ("index-ops", "not-null", ...) and
    /// `about` what it is about (a relation name, an id): together with
    /// the generation they are the key.
    pub fn memo<T, F>(&self, kind: &'static str, about: &str, read: F) -> Arc<T>
    where
        T: Send + Sync + 'static,
        F: FnOnce() -> T,
    {
        if !enabled() {
            return Arc::new(read());
        }
        let key = (self.generation(), kind, about.to_ascii_uppercase());
        if let Some(hit) = lock(&self.cache).memos.get(&key) {
            if let Ok(v) = Arc::clone(hit).downcast::<T>() {
                stats().hits.fetch_add(1, Ordering::Relaxed);
                return v;
            }
        }
        stats().misses.fetch_add(1, Ordering::Relaxed);
        let built: Arc<T> = Arc::new(read());
        let mut c = lock(&self.cache);
        if c.generation == key.0 {
            c.memos.insert(key, Arc::clone(&built) as Memo);
        }
        built
    }

    pub fn generation(&self) -> u64 {
        lock(&self.cache).generation
    }

    /// THE FILE ITSELF MAY HAVE BEEN REPLACED. The pool re-reads a
    /// database whose file changed underneath it - every gate deletes
    /// and re-creates its scratch database against a running server -
    /// and what this holds was about the file that is gone.
    pub fn sync_epoch(&self, epoch: u64) {
        let stale = {
            let c = lock(&self.cache);
            c.epoch != epoch
        };
        if stale {
            self.invalidate();
            lock(&self.cache).epoch = epoch;
        }
    }

    /// THE SCHEMA CHANGED. Every answer this holds was about the old
    /// one, so the generation moves and they all stop being reachable.
    /// Called for any statement that is not a record write - which is
    /// where this server's DDL lives - and when the pool re-reads a
    /// file that was replaced underneath it.
    pub fn invalidate(&self) {
        let mut c = lock(&self.cache);
        c.generation += 1;
        c.relations.clear();
        c.memos.clear();
        stats().invalidations.fetch_add(1, Ordering::Relaxed);
    }
}

fn registry() -> &'static Mutex<HashMap<String, Arc<DbMetadata>>> {
    static R: OnceLock<Mutex<HashMap<String, Arc<DbMetadata>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The metadata cache of one database, keyed the way the buffer pool
/// and the lock table are.
pub fn for_path(path: &str) -> Arc<DbMetadata> {
    let key = std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string());
    let mut r = lock(registry());
    Arc::clone(r.entry(key).or_insert_with(|| {
        Arc::new(DbMetadata {
            cache: Mutex::new(Cache::default()),
        })
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    fn scratch(name: &str) -> Arc<DbMetadata> {
        for_path(&format!("/nonexistent/fc-mdc-{}", name))
    }

    fn relation(id: u16) -> Relation {
        Relation {
            id,
            columns: Arc::new(Vec::new()),
            formats: Arc::new(Vec::new()),
        }
    }

    #[test]
    fn the_catalog_is_read_once_per_schema() {
        let md = scratch("once");
        let reads = AtomicUsize::new(0);
        let mut count = || {
            reads.fetch_add(1, Ordering::Relaxed);
            Some(relation(7))
        };
        assert_eq!(md.relation("T", &mut count).unwrap().id, 7);
        assert_eq!(md.relation("T", &mut count).unwrap().id, 7);
        assert_eq!(md.relation("t", &mut count).unwrap().id, 7, "names fold case");
        assert_eq!(reads.load(Ordering::Relaxed), 1, "read once, answered thrice");

        // ...until the schema changes
        md.invalidate();
        assert_eq!(md.relation("T", &mut count).unwrap().id, 7);
        assert_eq!(reads.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn a_relation_that_is_not_there_is_not_cached() {
        let md = scratch("missing");
        let reads = AtomicUsize::new(0);
        let mut none = || {
            reads.fetch_add(1, Ordering::Relaxed);
            None
        };
        assert!(md.relation("GONE", &mut none).is_none());
        assert!(md.relation("GONE", &mut none).is_none());
        assert_eq!(reads.load(Ordering::Relaxed), 2, "a miss is not an answer");
    }
}
