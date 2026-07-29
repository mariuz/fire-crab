# Converting platform I/O: `src/jrd/os/posix/unix.cpp` → `fire-crab-pio`

The paper's companion chapters are
[on-disk-structure.md](../../../on-disk-structure.md) and
[careful-writes-and-crash-safety.md](../../../careful-writes-and-crash-safety.md);
this file is the conversion record for the layer underneath both.

## The floor

Every page the cache reads or writes goes through `PIO_*`. There is very
little of it — a page-offset multiplication, a page-count division, three
open flags, a file lock, an extension call and a zero-fill — and everything
above it assumes those few things are right. That is exactly why they are
worth pinning: an off-by-one in the offset formula produces a database that
decodes *almost* correctly, and a page-count that rounds the wrong way
invents a page that is not there.

## The addressing law

`seek_file` (unix.cpp:850-882):

```c
FB_UINT64 lseek_offset = page;
lseek_offset *= bcb->bcb_page_size;
```

`offset = page * page_size`, absolute, from the start of the file, with no
per-file rebasing — because **Firebird 6 has no multi-file databases**.
`jrd_file` (pio.h:41-49) is one descriptor: no `fil_next`, no
`fil_min_page`, no `fil_max_page`, and `PageSpace` (pag.h:99) holds a single
`file`. Older engines had a file chain and a starting page per file, so a
converter working from memory or from an old book would subtract a base that
no longer exists and place every page in the wrong spot. Converting the
current engine means converting its absence.

The engine also guards the multiplication against its platform's `off_t`
(`isc_io_32bit_exceeded_err`). On a 64-bit build that cannot fire;
`page_offset_checked` carries it anyway, because "this page cannot be
addressed" is a different answer from "here is the page".

## The page-count law

`PIO_get_number_of_pages` (unix.cpp:517) ends with `return length / pagesize`
— **integer division**. A trailing partial page is not counted, not rounded
up, and not an error at this level: the engine simply cannot address it.

That makes the differential easy and strong, because the engine publishes
its own answer: `MON$DATABASE.MON$PAGES` is "pages allocated on disk". Ours
comes from `stat` and a division; if they agree on a fresh database, on the
`employee` sample, and at two points during growth, the arithmetic is right.

`length_is_whole_pages` is fire-crab's own addition, not the engine's: a
healthy database's length is always an exact multiple of the page size, so a
false answer means a truncated file or a page size read wrong. Both deserve a
refusal before anything decodes a byte. The gate proves the check can fail by
truncating a copy half a page short — the integer division alone would have
hidden that.

## The open-flag law: Forced Writes is a mode, not a policy

`openFile` (unix.cpp:885-911):

```c
int flag = O_BINARY | (readOnly ? O_RDONLY : O_RDWR);
if (forceWrite)    flag |= SYNC;        // O_DSYNC where available, else O_SYNC
if (notUseFSCache) flag |= O_DIRECT;
```

So "Forced Writes" is not an fsync after every write — it is `SYNC` in the
*open mode*, decided once, from a bit on the header page (`hdr_force_write`,
ods.h:724, at offset 22). Two consequences the conversion carries:

* Changing it at runtime means **reopening the file**, which is what
  `PIO_force_write` does; and when switching it ON it **flushes first**
  (unix.cpp:449), because the pages already sitting in the OS cache were
  written under the old promise.
* The bit and the mode are one law with two halves, so `fcpio attributes`
  prints both: the flags it read, the names `gstat -h` prints for them, and
  the open flags the engine would use. `gfix -w sync` / `-w async` moves all
  three together, and the gate checks that it does.

O_DIRECT is deliberately *not* applied by fire-crab's reader even when the
plan asks for it. O_DIRECT requires every buffer, offset and length aligned
to the device block size, which this reader does not guarantee;
`OpenPlan::open_flag_names` still reports what the engine would pass, so the
law is stated without pretending to obey it.

## The lock law — and why fire-crab can read a live database

`lockDatabaseFile` (unix.cpp:969) takes an `flock` on the whole file:
`LOCK_SH` in shared mode, `LOCK_EX` otherwise, always `LOCK_NB`. And the
mode is decided by the server architecture:

```c
const bool shareMode = dbb->dbb_config->getServerMode() != MODE_SUPER;
```

SuperServer therefore holds a database **exclusively**, and a second engine
instance trying to open the same file gets the busy branch —
`isc_already_opened`, whose message is the one this project has hit twice:

```
I/O error during "lock" operation for file "/opt/firebird/security6.fdb"
-Database already opened with engine instance, incompatible with current
```

**fire-crab's readers take no lock at all.** That is a deliberate difference
and the property every differential in this repository rests on: `fcstat`,
`fcauth stored`, `fcblb scan` and `fcpio read` can all read a database the
server holds open. The gate proves both halves at once — with a live
attachment, `fcpio lock` reports BUSY *and* `fcpio read` still returns the
header page.

The cost is real and worth stating: a lock-free read can catch a page
mid-write, so a gate that reads a live file needs a freshness signal of its
own. `qa/auth-srp.sh` learned that the hard way — it waited for a row to
*appear* in a copy of the security database, which is not the same as
waiting for the row it just wrote.

## Extension and zero-fill

`PIO_extend` (unix.cpp:312) is one `fallocate` at
`filePages * pageSize` for `MIN(MAX_ULONG - filePages, extPages) * pageSize`
bytes, and on `EOPNOTSUPP`/`ENOSYS` it sets `FIL_no_fast_extend` and returns
false — the caller then falls back to writing pages. Converted as
`extend_plan`, a pure function, because the arithmetic is the part that can
be wrong.

`PIO_init_data` (unix.cpp:585) has the one surprising rule in this layer:

```c
if (startPage < 8)
    return 0;
```

The first eight pages are never zero-filled by the tail initializer — they
hold the header, the first PIP and the first pointer page, and "initializing
the tail" over them would destroy the database. It writes in blocks of
`ZeroBuffer::DEFAULT_SIZE` (256 KB, File.h:49), so the number of pages per
syscall is `256 KB / page_size` — 32 at an 8 KB page size, 8 at 32 KB.
fire-crab's `init_data` refuses a request below page 8 instead of silently
returning zero, because a caller that asked to zero page 3 has a bug.

## What the gate proves (`qa/pio-layout.sh`, 18 checks)

1. **The page count** equals `MON$DATABASE.MON$PAGES` on a fresh database,
   on the `employee` sample, and at two points during growth — and the file
   really grew while being checked (313 → 401 pages for 12 000 rows), or the
   three checks would be one check repeated.
2. **The addressing law against `RDB$PAGES`.** The engine records the TYPE
   of many pages; reading each of those pages at `page * page_size` must find
   a page of that type. All 84 matched. The teeth: the same comparison
   shifted by one page matched 0 of 84, so the check has discriminating
   power — an off-by-one offset could not pass it.
3. **The header bootstrap**: a 20-byte read of the file already yields the
   page size `MON$DATABASE` reports, which is the entire reason `PIO_header`
   exists separately from `PIO_read`.
4. **Forced writes as an open mode**: `gfix -w sync` sets the bit, our
   decode reports `force write` and an open mode of `O_BINARY|O_RDWR|SYNC`,
   and `gstat -h` prints the same attribute; `-w async` clears all three.
   Then the behavioural half: with forced writes on, a copy of the file taken
   after `COMMIT` contains every row (17 000 of them).
5. **The lock**: BUSY while the engine holds the file, FREE after — and a
   fire-crab read succeeds in both states.
6. **Refusals**: a page past the end is an error, never a zero-filled buffer
   that looks like an empty page one layer up; a file truncated half a page
   short reports `WHOLE no`.

## Frontier

* **`PIO_open`'s own locking**, if fire-crab ever writes to a database the
  server might also hold. Today the write paths (`fcblb write`, the wire
  server's DML) work on scratch files the engine is not attached to, which is
  a discipline rather than a mechanism.
* **Shadowing** (`hdr_active_shadow`, the shadow file chain) and **nbackup
  state** (`hdr_nbak_*`, the difference file): both change what "the file" is
  for a page read.
* **Raw devices** (`PIO_on_raw_device`, `BLKGETSIZE64`) — the page count of a
  block device comes from an ioctl, not from `stat`.
* **O_DIRECT** for real, which means an aligned buffer allocator.
* The Windows half of this layer (`src/jrd/os/win32/winnt.cpp`), where the
  same laws are expressed with `CreateFile` flags and `LockFileEx`.
