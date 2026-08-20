//! AN EXTERNAL SORT - the engine's `sort.cpp` shape, not its bytes.
//!
//! Rows go into a buffer until a memory BUDGET is spent; the buffer is
//! sorted (stably, by the caller's comparator) and written as a RUN; at
//! the end the runs are merged. That is `Sort::put` / `putRun` /
//! `mergeRuns` / `Sort::get`. What is deliberately NOT copied: the
//! engine's quicksort over diddled keys and its balanced, seek-ordered
//! merge tree - measured, the engine's tie order past one run (~2340
//! records per 128 KB) is an artefact of run size x record size x
//! quicksort x merge tree, reproducible only by a bit-level port, and the
//! engine's own gates compare on total keys for that reason. This sort
//! promises what the in-RAM path promised: the comparator's order, ties in
//! RECORD ORDER (the buffer sort is stable, the merge breaks ties by run
//! then position), identical whether the set spilled or not.
//!
//! Knobs (the engine's: `TempCacheLimit` 64 MB SuperServer default,
//! `TempDirectories` default /tmp, run files `fb_sort_*`):
//!   FC_SORT_MEMORY  bytes of rows held before a run is written (64 MiB)
//!   FC_TEMP_DIR     where run files go (std::env::temp_dir() otherwise)
//! Run files are `fc_sort_<pid>_<n>` and are UNLINKED the moment they are
//! created: the open handle keeps them readable, and a crash leaves no
//! litter (TempFile's own rule).

use fire_crab_ods::format::Value;
use std::cmp::Ordering;
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::PathBuf;

static RUN_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// The budget, from `FC_SORT_MEMORY` (bytes), 64 MiB by default.
pub fn budget() -> usize {
    std::env::var("FC_SORT_MEMORY")
        .ok()
        .and_then(|v| v.trim().parse::<usize>().ok())
        .unwrap_or(64 << 20)
}

fn temp_dir() -> PathBuf {
    std::env::var("FC_TEMP_DIR").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir())
}

/// What a row costs in RAM, near enough: the `Vec` header, 32 bytes per
/// `Value` (the enum's size), and each text's bytes.
pub fn row_bytes(row: &[Value]) -> usize {
    24 + row.len() * 32
        + row
            .iter()
            .map(|v| match v {
                Value::Text(t) => t.len(),
                _ => 0,
            })
            .sum::<usize>()
}

// ---- the row encoding: one tag byte per value, little-endian fields ----

fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

pub fn encode_row(row: &[Value], out: &mut Vec<u8>) {
    put_u32(out, row.len() as u32);
    for v in row {
        match v {
            Value::Null => out.push(0),
            Value::Text(t) => {
                out.push(1);
                put_u32(out, t.len() as u32);
                out.extend_from_slice(t.as_bytes());
            }
            Value::Int(i) => {
                out.push(2);
                out.extend_from_slice(&i.to_le_bytes());
            }
            Value::Scaled(i, s) => {
                out.push(3);
                out.extend_from_slice(&i.to_le_bytes());
                out.push(*s as u8);
            }
            Value::Double(d) => {
                out.push(4);
                out.extend_from_slice(&d.to_bits().to_le_bytes());
            }
            Value::Float(f) => {
                out.push(5);
                out.extend_from_slice(&f.to_bits().to_le_bytes());
            }
            Value::Bool(b) => {
                out.push(6);
                out.push(*b as u8);
            }
            Value::Date(d) => {
                out.push(7);
                out.extend_from_slice(&d.to_le_bytes());
            }
            Value::Time(t) => {
                out.push(8);
                out.extend_from_slice(&t.to_le_bytes());
            }
            Value::Timestamp(d, t) => {
                out.push(9);
                out.extend_from_slice(&d.to_le_bytes());
                out.extend_from_slice(&t.to_le_bytes());
            }
            Value::Blob(r, n) => {
                out.push(10);
                out.extend_from_slice(&r.to_le_bytes());
                out.extend_from_slice(&n.to_le_bytes());
            }
            Value::Int128(i, s) => {
                out.push(11);
                out.extend_from_slice(&i.to_le_bytes());
                out.push(*s as u8);
            }
            Value::DecFloat16(b) => {
                out.push(12);
                out.extend_from_slice(&b.to_le_bytes());
            }
            Value::DecFloat34(b) => {
                out.push(13);
                out.extend_from_slice(&b.to_le_bytes());
            }
            Value::TimeTz(t, z) => {
                out.push(14);
                out.extend_from_slice(&t.to_le_bytes());
                out.extend_from_slice(&z.to_le_bytes());
            }
            Value::TimestampTz(d, t, z) => {
                out.push(15);
                out.extend_from_slice(&d.to_le_bytes());
                out.extend_from_slice(&t.to_le_bytes());
                out.extend_from_slice(&z.to_le_bytes());
            }
            Value::Unsupported(why) => {
                out.push(16);
                put_u32(out, why.len() as u32);
                out.extend_from_slice(why.as_bytes());
            }
        }
    }
}

struct Cursor<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn take(&mut self, n: usize) -> io::Result<&'a [u8]> {
        let s = self
            .b
            .get(self.at..self.at + n)
            .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "run row truncated"))?;
        self.at += n;
        Ok(s)
    }
    fn u8(&mut self) -> io::Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> io::Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn i32(&mut self) -> io::Result<i32> {
        Ok(i32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn i64(&mut self) -> io::Result<i64> {
        Ok(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn u128(&mut self) -> io::Result<u128> {
        Ok(u128::from_le_bytes(self.take(16)?.try_into().unwrap()))
    }
}

pub fn decode_row(b: &[u8]) -> io::Result<Vec<Value>> {
    let mut c = Cursor { b, at: 0 };
    let n = c.u32()? as usize;
    let mut row = Vec::with_capacity(n);
    for _ in 0..n {
        row.push(match c.u8()? {
            0 => Value::Null,
            1 => {
                let len = c.u32()? as usize;
                Value::Text(String::from_utf8_lossy(c.take(len)?).into_owned())
            }
            2 => Value::Int(c.i64()?),
            3 => Value::Scaled(c.i64()?, c.u8()? as i8),
            4 => Value::Double(f64::from_bits(c.u64()?)),
            5 => Value::Float(f32::from_bits(c.u32()?)),
            6 => Value::Bool(c.u8()? != 0),
            7 => Value::Date(c.i32()?),
            8 => Value::Time(c.u32()?),
            9 => Value::Timestamp(c.i32()?, c.u32()?),
            10 => Value::Blob(c.u16()?, c.u64()?),
            11 => Value::Int128(c.u128()? as i128, c.u8()? as i8),
            12 => Value::DecFloat16(c.u64()?),
            13 => Value::DecFloat34(c.u128()?),
            14 => Value::TimeTz(c.u32()?, c.u16()?),
            15 => Value::TimestampTz(c.i32()?, c.u32()?, c.u16()?),
            16 => {
                let len = c.u32()? as usize;
                let why: &'static str = Box::leak(String::from_utf8_lossy(c.take(len)?).into_owned().into_boxed_str());
                Value::Unsupported(why)
            }
            t => return Err(io::Error::new(io::ErrorKind::InvalidData, format!("run value tag {}", t))),
        });
    }
    Ok(row)
}

/// One run on disk: rows as `[u32 len][row bytes]`, in sorted order.
struct Run {
    reader: BufReader<File>,
    /// the head row, decoded - what the merge compares
    head: Option<Vec<Value>>,
    /// rows taken so far - with the run's index, the merge's tiebreak
    seq: u64,
    buf: Vec<u8>,
}

impl Run {
    fn advance(&mut self) -> io::Result<()> {
        let mut len = [0u8; 4];
        match self.reader.read_exact(&mut len) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => {
                self.head = None;
                return Ok(());
            }
            Err(e) => return Err(e),
        }
        let len = u32::from_le_bytes(len) as usize;
        self.buf.resize(len, 0);
        self.reader.read_exact(&mut self.buf)?;
        self.head = Some(decode_row(&self.buf)?);
        self.seq += 1;
        Ok(())
    }
}

pub struct ExternalSort<C> {
    cmp: C,
    budget: usize,
    used: usize,
    buf: Vec<Vec<Value>>,
    runs: Vec<File>,
    total: usize,
    spilled: usize,
}

impl<C: Fn(&[Value], &[Value]) -> Ordering> ExternalSort<C> {
    pub fn new(cmp: C) -> ExternalSort<C> {
        ExternalSort { cmp, budget: budget(), used: 0, buf: Vec::new(), runs: Vec::new(), total: 0, spilled: 0 }
    }

    pub fn with_budget(cmp: C, budget: usize) -> ExternalSort<C> {
        ExternalSort { cmp, budget, used: 0, buf: Vec::new(), runs: Vec::new(), total: 0, spilled: 0 }
    }

    pub fn put(&mut self, row: Vec<Value>) -> io::Result<()> {
        self.used += row_bytes(&row);
        self.total += 1;
        self.buf.push(row);
        if self.used > self.budget {
            self.spill()?;
        }
        Ok(())
    }

    /// `putRun`: the buffer sorted (stably) and written as one run.
    fn spill(&mut self) -> io::Result<()> {
        if self.buf.is_empty() {
            return Ok(());
        }
        let cmp = &self.cmp;
        self.buf.sort_by(|a, b| cmp(a, b));
        let n = RUN_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = temp_dir().join(format!("fc_sort_{}_{}", std::process::id(), n));
        let file = File::options().read(true).write(true).create_new(true).open(&path)?;
        // readable through the handle, gone from the directory
        let _ = std::fs::remove_file(&path);
        {
            let mut w = BufWriter::new(&file);
            let mut bytes = Vec::new();
            for row in self.buf.drain(..) {
                bytes.clear();
                encode_row(&row, &mut bytes);
                w.write_all(&(bytes.len() as u32).to_le_bytes())?;
                w.write_all(&bytes)?;
            }
            w.flush()?;
        }
        self.spilled += self.used;
        self.used = 0;
        self.runs.push(file);
        Ok(())
    }

    pub fn rows(&self) -> usize {
        self.total
    }

    pub fn runs(&self) -> usize {
        self.runs.len()
    }

    /// `Sort::sort`: nothing spilled - the buffer sorted in place is the
    /// answer; otherwise the last buffer becomes a run and the runs merge.
    pub fn finish(mut self) -> io::Result<SortCursor<C>> {
        if self.runs.is_empty() {
            let cmp = &self.cmp;
            self.buf.sort_by(|a, b| cmp(a, b));
            let rows = std::mem::take(&mut self.buf);
            return Ok(SortCursor {
                cmp: self.cmp,
                mem: Some(rows.into_iter()),
                runs: Vec::new(),
                stats: (self.total, 0, 0),
            });
        }
        self.spill()?;
        let mut runs = Vec::with_capacity(self.runs.len());
        let nruns = self.runs.len();
        for mut file in self.runs.drain(..) {
            use std::io::Seek;
            file.seek(io::SeekFrom::Start(0))?;
            let mut r = Run { reader: BufReader::with_capacity(1 << 16, file), head: None, seq: 0, buf: Vec::new() };
            r.advance()?;
            runs.push(r);
        }
        Ok(SortCursor { cmp: self.cmp, mem: None, runs, stats: (self.total, nruns, self.spilled) })
    }
}

/// `Sort::get`: the sorted rows, one at a time.
pub struct SortCursor<C> {
    cmp: C,
    mem: Option<std::vec::IntoIter<Vec<Value>>>,
    runs: Vec<Run>,
    /// (rows, runs, bytes spilled) - for the trace
    pub stats: (usize, usize, usize),
}

impl<C: Fn(&[Value], &[Value]) -> Ordering> SortCursor<C> {
    pub fn next(&mut self) -> io::Result<Option<Vec<Value>>> {
        if let Some(it) = self.mem.as_mut() {
            return Ok(it.next());
        }
        // the least head; an equal pair goes to the lower run (written
        // earlier - its rows came first), so ties keep record order
        let mut best: Option<usize> = None;
        for (i, r) in self.runs.iter().enumerate() {
            let Some(h) = r.head.as_ref() else { continue };
            match best {
                None => best = Some(i),
                Some(b) => {
                    if (self.cmp)(h, self.runs[b].head.as_ref().unwrap()) == Ordering::Less {
                        best = Some(i);
                    }
                }
            }
        }
        let Some(b) = best else { return Ok(None) };
        let row = self.runs[b].head.take();
        self.runs[b].advance()?;
        Ok(row)
    }

    pub fn collect_all(mut self) -> io::Result<Vec<Vec<Value>>> {
        let mut out = Vec::with_capacity(self.stats.0);
        while let Some(r) = self.next()? {
            out.push(r);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmp_first(a: &[Value], b: &[Value]) -> Ordering {
        match (&a[0], &b[0]) {
            (Value::Int(x), Value::Int(y)) => x.cmp(y),
            _ => Ordering::Equal,
        }
    }

    #[test]
    fn every_value_round_trips() {
        let row = vec![
            Value::Null,
            Value::Text("héllo".into()),
            Value::Int(-7),
            Value::Scaled(12345, -2),
            Value::Double(-0.5),
            Value::Float(2.5),
            Value::Bool(true),
            Value::Date(-3),
            Value::Time(86399 * 10000),
            Value::Timestamp(1, 2),
            Value::Blob(128, 77),
            Value::Int128(-(1i128 << 100), 3),
            Value::DecFloat16(0x2234000000000001),
            Value::DecFloat34(u128::MAX - 9),
            Value::TimeTz(5, 65535),
            Value::TimestampTz(-1, 9, 1234),
        ];
        let mut b = Vec::new();
        encode_row(&row, &mut b);
        assert_eq!(decode_row(&b).unwrap(), row);
    }

    #[test]
    fn spilled_and_unspilled_agree_and_ties_keep_record_order() {
        let mk = |n: usize| -> Vec<Vec<Value>> {
            (0..n).map(|i| vec![Value::Int((i % 7) as i64), Value::Int(i as i64)]).collect()
        };
        let rows = mk(5000);
        let mut a = ExternalSort::with_budget(cmp_first, usize::MAX);
        for r in rows.clone() {
            a.put(r).unwrap();
        }
        let a = a.finish().unwrap();
        assert_eq!(a.stats.1, 0);
        let a = a.collect_all().unwrap();
        let mut b = ExternalSort::with_budget(cmp_first, 4096);
        for r in rows {
            b.put(r).unwrap();
        }
        let b = b.finish().unwrap();
        assert!(b.stats.1 > 1, "runs={}", b.stats.1);
        let b = b.collect_all().unwrap();
        assert_eq!(a, b);
        // within a key, the second column (insertion order) ascends
        for w in a.windows(2) {
            if w[0][0] == w[1][0] {
                match (&w[0][1], &w[1][1]) {
                    (Value::Int(x), Value::Int(y)) => assert!(x < y),
                    _ => panic!("int positions expected"),
                }
            }
        }
    }
}

/// A ROW STORE for a hash join's build side (the engine's RecordBuffer,
/// which owns a TempSpace): rows appended in arrival order, each
/// addressed by its byte offset; held in RAM to the budget, then the
/// buffer goes to an unlinked file and later rows append there. A
/// bucket of offsets is all a hash table need keep in memory.
pub struct RowStore {
    budget: usize,
    mem: Vec<u8>,
    /// bytes already in the file - offsets below this are read from it
    spilled: u64,
    file: Option<File>,
    count: usize,
}

impl RowStore {
    pub fn new() -> RowStore {
        RowStore { budget: budget(), mem: Vec::new(), spilled: 0, file: None, count: 0 }
    }

    pub fn with_budget(budget: usize) -> RowStore {
        RowStore { budget, mem: Vec::new(), spilled: 0, file: None, count: 0 }
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn spilled_bytes(&self) -> u64 {
        self.spilled
    }

    /// Append a row; its offset is the handle.
    pub fn push(&mut self, row: &[Value]) -> io::Result<u64> {
        let off = self.spilled + self.mem.len() as u64;
        let at = self.mem.len();
        self.mem.extend_from_slice(&[0, 0, 0, 0]);
        encode_row(row, &mut self.mem);
        let len = (self.mem.len() - at - 4) as u32;
        self.mem[at..at + 4].copy_from_slice(&len.to_le_bytes());
        self.count += 1;
        if self.mem.len() > self.budget {
            self.spill()?;
        }
        Ok(off)
    }

    fn spill(&mut self) -> io::Result<()> {
        if self.file.is_none() {
            let n = RUN_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let path = temp_dir().join(format!("fc_sort_{}_{}", std::process::id(), n));
            let file = File::options().read(true).write(true).create_new(true).open(&path)?;
            let _ = std::fs::remove_file(&path);
            self.file = Some(file);
        }
        let file = self.file.as_mut().unwrap();
        use std::os::unix::fs::FileExt;
        file.write_all_at(&self.mem, self.spilled)?;
        self.spilled += self.mem.len() as u64;
        self.mem.clear();
        Ok(())
    }

    /// The row at `off` - off the file when it was spilled, off the
    /// buffer otherwise.
    pub fn get(&self, off: u64) -> io::Result<Vec<Value>> {
        if off >= self.spilled {
            let at = (off - self.spilled) as usize;
            let len = u32::from_le_bytes(
                self.mem
                    .get(at..at + 4)
                    .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "row store offset"))?
                    .try_into()
                    .unwrap(),
            ) as usize;
            return decode_row(&self.mem[at + 4..at + 4 + len]);
        }
        use std::os::unix::fs::FileExt;
        let file = self.file.as_ref().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "row store file"))?;
        let mut len = [0u8; 4];
        file.read_exact_at(&mut len, off)?;
        let len = u32::from_le_bytes(len) as usize;
        let mut buf = vec![0u8; len];
        file.read_exact_at(&mut buf, off + 4)?;
        decode_row(&buf)
    }
}

#[cfg(test)]
mod store_tests {
    use super::*;

    #[test]
    fn rows_come_back_by_offset_across_the_spill() {
        let mut st = RowStore::with_budget(512);
        let mut offs = Vec::new();
        for i in 0..200i64 {
            offs.push(st.push(&[Value::Int(i), Value::Text(format!("r{}", i))]).unwrap());
        }
        assert!(st.spilled_bytes() > 0);
        for (i, off) in offs.iter().enumerate() {
            assert_eq!(st.get(*off).unwrap(), vec![Value::Int(i as i64), Value::Text(format!("r{}", i))]);
        }
    }
}
