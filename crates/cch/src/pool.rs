//! THE BUFFER POOL - one image per FILE per process, instead of one per
//! attachment.
//!
//! `qa/serve-real-concurrency.sh` measured what the alternative costs.
//! The server's `load_database` did `std::fs::read(path)` into an owned
//! `Vec<u8>`, once per connection thread, so every attachment held a
//! private full-file copy and its flush wrote that copy's pages back:
//! two attachments were two databases that happened to share a filename.
//! An attachment opened before another's commit never saw it, and two
//! attachments writing at once each flushed their own image, so one
//! side's committed rows were silently gone - under a file `gfix -v
//! -full` then called perfectly valid, because it *was* valid: one
//! writer's consistent image, whole, over the top of the other's.
//!
//! This is the shared resource that was missing. It holds what the
//! engine's buffer pool holds - the pages of a file, once, for everyone
//! attached to it - and two rules over it:
//!
//!   * **the image is published atomically.** Readers take a reference
//!     counted snapshot (`image()`) and never a lock held across their
//!     work, so a reader sees the image either before or after a
//!     writer's install and never during it.
//!   * **writers are serialized per database** (`begin_write`). The
//!     server's writes are read-modify-write over the whole image - it
//!     clones, edits the clone, installs it - and two of those
//!     interleaved is exactly the lost update the gate found. The token
//!     is RECURSIVE (a statement that re-enters the write path per row
//!     already holds it) and is meant to be held for the length of a
//!     TRANSACTION, because a rollback in this server restores an image
//!     snapshot and must not be able to restore over somebody else's
//!     committed work.
//!
//! That serialization is COARSER THAN THE ENGINE'S. The engine blocks a
//! second writer only on a conflicting ROW (`lck` + the record's
//! transaction state); this blocks it on the database. Correct and
//! coarse is the honest step from silently-wrong: the lock manager (W4)
//! is what makes it row-granular, and it now has a shared resource to
//! arbitrate, which is what it was waiting for.
//!
//! WHAT THIS IS NOT, YET. Pages are not fetched one at a time through
//! [`crate::Cache`]'s buffer descriptors here; the unit of sharing is
//! the whole image. Per-page fetch with hit accounting is the rest of
//! W2, and the seam for it is [`SharedImage::image`] - the one place
//! every read now goes through.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

/// What the pool has done, for the coverage half of a wiring gate: a
/// subsystem that is wired in but never used passes every behaviour
/// check. `shared` counts attachments that found the image already
/// resident - if it stays zero, nothing is sharing anything.
#[derive(Default)]
pub struct Stats {
    /// attachments that opened a database through the pool
    pub attaches: AtomicU64,
    /// ...of which found the image already resident (the pool's point)
    pub shared: AtomicU64,
    /// images re-read because the file changed underneath the pool
    pub reloads: AtomicU64,
    /// images installed by a writer
    pub publishes: AtomicU64,
    /// writers that had to WAIT for another writer to finish
    pub write_waits: AtomicU64,
}

impl Stats {
    fn line(&self) -> String {
        format!(
            "attaches {} shared {} reloads {} publishes {} write-waits {}",
            self.attaches.load(Ordering::Relaxed),
            self.shared.load(Ordering::Relaxed),
            self.reloads.load(Ordering::Relaxed),
            self.publishes.load(Ordering::Relaxed),
            self.write_waits.load(Ordering::Relaxed),
        )
    }
}

fn stats() -> &'static Stats {
    static STATS: OnceLock<Stats> = OnceLock::new();
    STATS.get_or_init(Stats::default)
}

/// One line of pool counters - what a coverage gate reads.
pub fn stats_line() -> String {
    stats().line()
}

/// The file as the pool last knew it on disk: length and modification
/// time. The pool is process-wide and long-lived while the gates
/// around it delete and re-create the same path over and over (`rm -f`
/// then `CREATE DATABASE`), so a resident image is only reused while
/// the file it came from is still the same file.
type Fingerprint = (u64, u128);

fn fingerprint(path: &str) -> Option<Fingerprint> {
    let m = std::fs::metadata(path).ok()?;
    let t = m
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    Some((m.len(), t))
}

/// Who holds the write side, and how deep. One connection is one
/// thread in this server, so the owner is a thread id; the depth makes
/// the token recursive, since a statement that writes row by row
/// re-enters the write path while already holding it.
#[derive(Default)]
struct WriteState {
    owner: Option<std::thread::ThreadId>,
    depth: usize,
}

/// The pages of one database file, shared by every attachment to it.
pub struct SharedImage {
    path: String,
    /// bumped whenever the pool RE-READS this file - the image is of a
    /// different file than the one it held, so anything derived from
    /// the old one (a metadata cache, say) is about a database that is
    /// no longer there
    epoch: AtomicU64,
    image: Mutex<Arc<fire_crab_ods::Image>>,
    /// the image as it is ON DISK - what a careful flush must diff
    /// against, since an install that is not itself flushed leaves its
    /// pages dirty for the next one to write. Diffing against the
    /// CURRENT image instead loses them: they are equal in both halves
    /// of that comparison, so the flush finds nothing changed and the
    /// pages never reach the file.
    flushed: Mutex<Arc<fire_crab_ods::Image>>,
    disk: Mutex<Option<Fingerprint>>,
    write: Mutex<WriteState>,
    wake: Condvar,
}

/// A poisoned mutex here means a connection thread panicked while
/// holding it. The image behind it is still a whole image (it is only
/// ever REPLACED, never edited in place), so the pool keeps serving it
/// rather than taking every other connection down with the one that
/// died.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl SharedImage {
    /// The image as it stands now. Reference counted, so the caller
    /// reads it without holding any lock and a writer installing a new
    /// one does not disturb it.
    pub fn image(&self) -> Arc<fire_crab_ods::Image> {
        lock(&self.image).clone()
    }

    /// The file this image came from.
    pub fn path(&self) -> &str {
        &self.path
    }

    /// How many times the pool has re-read this file. A caller holding
    /// anything derived from the image compares this against what it
    /// derived from.
    pub fn epoch(&self) -> u64 {
        self.epoch.load(Ordering::Relaxed)
    }

    /// Install a new image. The caller must hold the write token: this
    /// is the second half of a read-modify-write that started with
    /// [`SharedImage::image`].
    pub fn publish(&self, img: fire_crab_ods::Image) -> Arc<fire_crab_ods::Image> {
        let arc = Arc::new(img);
        self.publish_image(Arc::clone(&arc));
        arc
    }

    /// Install an image the caller already holds a reference to.
    ///
    /// A published image is never edited in place - a writer works on a
    /// copy and installs it - so a reference to one stays valid however
    /// many installs follow, which is what makes a SNAPSHOT free: the
    /// transaction that may need to put the file back keeps a reference
    /// rather than a copy, and putting it back is this call.
    pub fn publish_image(&self, img: Arc<fire_crab_ods::Image>) {
        *lock(&self.image) = img;
        stats().publishes.fetch_add(1, Ordering::Relaxed);
    }

    /// The image as it stands ON DISK - the baseline for the next
    /// careful flush.
    pub fn flushed(&self) -> Arc<fire_crab_ods::Image> {
        lock(&self.flushed).clone()
    }

    /// Record that `img` is what the file now holds.
    pub fn note_flushed(&self, img: Arc<fire_crab_ods::Image>) {
        *lock(&self.flushed) = img;
    }

    /// Record the file's fingerprint after the server itself wrote it,
    /// so the pool does not mistake its own flush for somebody else
    /// changing the file and re-read what it just wrote.
    pub fn note_disk(&self) {
        *lock(&self.disk) = fingerprint(&self.path);
    }

    /// Take the write side, blocking while another connection holds it.
    /// Recursive for the thread that already owns it. `None` means the
    /// wait ran out - the caller turns that into a lock-conflict error
    /// rather than hanging a connection forever.
    pub fn begin_write(self: &Arc<Self>, timeout: Duration) -> Option<WriteToken> {
        let me = std::thread::current().id();
        let mut st = lock(&self.write);
        let deadline = std::time::Instant::now() + timeout;
        loop {
            match st.owner {
                None => {
                    st.owner = Some(me);
                    st.depth = 1;
                    break;
                }
                Some(o) if o == me => {
                    st.depth += 1;
                    break;
                }
                _ => {
                    let left = deadline.saturating_duration_since(std::time::Instant::now());
                    if left.is_zero() {
                        return None;
                    }
                    stats().write_waits.fetch_add(1, Ordering::Relaxed);
                    let (g, _) = self
                        .wake
                        .wait_timeout(st, left)
                        .unwrap_or_else(|e| e.into_inner());
                    st = g;
                }
            }
        }
        Some(WriteToken {
            shared: Arc::clone(self),
        })
    }

    fn end_write(&self) {
        let mut st = lock(&self.write);
        if st.depth > 0 {
            st.depth -= 1;
        }
        if st.depth == 0 {
            st.owner = None;
            drop(st);
            self.wake.notify_all();
        }
    }
}

/// The write side of one database, released when it is dropped - which
/// includes the connection thread ending, so a client that vanishes
/// mid-transaction does not lock the database out for good.
pub struct WriteToken {
    shared: Arc<SharedImage>,
}

impl Drop for WriteToken {
    fn drop(&mut self) {
        self.shared.end_write();
    }
}

fn pool() -> &'static Mutex<HashMap<String, Arc<SharedImage>>> {
    static POOL: OnceLock<Mutex<HashMap<String, Arc<SharedImage>>>> = OnceLock::new();
    POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn key(path: &str) -> String {
    std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string())
}

/// Attach to `path`: the resident image if the pool already holds one
/// for that file, otherwise the file, read once. `None` when there is
/// no readable file there - the caller then behaves exactly as it did
/// when its own `fs::read` failed.
pub fn open(path: &str) -> Option<Arc<SharedImage>> {
    let k = key(path);
    let mut p = lock(pool());
    let fp = fingerprint(path);
    if fp.is_none() {
        // the file is gone; a resident image of a deleted file is not a
        // database anybody can attach to
        p.remove(&k);
        return None;
    }
    stats().attaches.fetch_add(1, Ordering::Relaxed);
    if let Some(sh) = p.get(&k) {
        let same = *lock(&sh.disk) == fp;
        if same {
            stats().shared.fetch_add(1, Ordering::Relaxed);
            return Some(Arc::clone(sh));
        }
        // THE FILE CHANGED UNDER THE POOL. The gates delete and
        // re-create the same path against a running server; the engine
        // itself writes these files too. A resident image that no
        // longer matches its file is re-read, not served.
        let raw = std::fs::read(path).ok()?;
        let ps = fire_crab_ods::tra::page_size_of(&raw)?;
        stats().reloads.fetch_add(1, Ordering::Relaxed);
        sh.epoch.fetch_add(1, Ordering::Relaxed);
        let arc = Arc::new(fire_crab_ods::Image::from_bytes(&raw, ps));
        *lock(&sh.image) = Arc::clone(&arc);
        *lock(&sh.flushed) = arc;
        *lock(&sh.disk) = fp;
        return Some(Arc::clone(sh));
    }
    let raw = std::fs::read(path).ok()?;
    let ps = fire_crab_ods::tra::page_size_of(&raw)?;
    let bytes = Arc::new(fire_crab_ods::Image::from_bytes(&raw, ps));
    let sh = Arc::new(SharedImage {
        path: path.to_string(),
        epoch: AtomicU64::new(0),
        image: Mutex::new(Arc::clone(&bytes)),
        flushed: Mutex::new(bytes),
        disk: Mutex::new(fp),
        write: Mutex::new(WriteState::default()),
        wake: Condvar::new(),
    });
    p.insert(k, Arc::clone(&sh));
    Some(sh)
}

/// An image with no file behind it and no entry in the pool: nothing
/// else can reach it, so it shares with nobody. For the paths that need
/// a database-shaped value without a database - the row-source tree's
/// tests reach one only to prove they never touch it.
pub fn detached(bytes: Vec<u8>) -> Arc<SharedImage> {
    let ps = fire_crab_ods::tra::page_size_of(&bytes).unwrap_or(0);
    let arc = Arc::new(fire_crab_ods::Image::from_bytes(&bytes, ps));
    Arc::new(SharedImage {
        path: String::new(),
        epoch: AtomicU64::new(0),
        image: Mutex::new(Arc::clone(&arc)),
        flushed: Mutex::new(arc),
        disk: Mutex::new(None),
        write: Mutex::new(WriteState::default()),
        wake: Condvar::new(),
    })
}

/// Forget a database - `DROP DATABASE`, or any other point where the
/// file stops being the one the image came from. The next attach reads
/// the file again.
pub fn forget(path: &str) {
    lock(pool()).remove(&key(path));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str, bytes: &[u8]) -> String {
        let p = std::env::temp_dir().join(name);
        std::fs::write(&p, bytes).unwrap();
        p.to_string_lossy().into_owned()
    }

    #[test]
    fn two_attachments_get_one_image() {
        let path = scratch("fc-pool-share.bin", &[1u8; 64]);
        let a = open(&path).expect("attach");
        let b = open(&path).expect("attach");
        assert!(Arc::ptr_eq(&a, &b), "one file is one image");
        let t = a.begin_write(Duration::from_secs(1)).expect("write side");
        a.publish(fire_crab_ods::Image::from_bytes(&[2u8; 64], 64));
        drop(t);
        // the OTHER attachment sees it - the whole point
        assert_eq!(b.image().page(0).unwrap()[0], 2);
        forget(&path);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn the_write_side_is_exclusive_and_recursive() {
        let path = scratch("fc-pool-excl.bin", &[0u8; 64]);
        let a = open(&path).expect("attach");
        let outer = a.begin_write(Duration::from_secs(1)).expect("write side");
        // the same thread re-enters (a row-by-row statement does)
        let inner = a.begin_write(Duration::from_secs(1)).expect("recursive");
        let other = {
            let a2 = Arc::clone(&a);
            std::thread::spawn(move || a2.begin_write(Duration::from_millis(200)).is_some())
        };
        assert!(!other.join().unwrap(), "another thread must wait, and time out");
        drop(inner);
        drop(outer);
        let a3 = Arc::clone(&a);
        let after = std::thread::spawn(move || a3.begin_write(Duration::from_secs(1)).is_some());
        assert!(after.join().unwrap(), "released, so the next writer gets in");
        forget(&path);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_replaced_file_is_re_read() {
        let path = scratch("fc-pool-reload.bin", &[7u8; 32]);
        let a = open(&path).expect("attach");
        assert_eq!(a.image().page(0).unwrap()[0], 7);
        // what every gate does: delete the scratch db and make it again
        std::fs::remove_file(&path).unwrap();
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(&path, [9u8; 48]).unwrap();
        let b = open(&path).expect("attach");
        assert_eq!(b.image().page(0).unwrap()[0], 9, "the image follows the file, not the name");
        assert_eq!(b.image().byte_len(), 48);
        forget(&path);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_missing_file_is_not_a_database() {
        let path = scratch("fc-pool-gone.bin", &[0u8; 64]);
        assert!(open(&path).is_some());
        std::fs::remove_file(&path).unwrap();
        assert!(open(&path).is_none(), "no file, no image");
    }
}
