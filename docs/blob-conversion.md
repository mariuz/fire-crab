# The Blob Storage Conversion (`fire-crab-blb`)

The conversion of `src/jrd/blb.cpp`'s on-disk addressing — blob
headers (`blh`), blob pages (`blp`), the three address levels — and
its creation path, differentially tested in **both directions**: the
engine writes blobs this crate must read byte-for-byte (through a
genuine 36 MB level-2 blob), and this crate writes blobs the engine
must read back in full, validate with `gfix`, and back up with
`gbak`.

* [Blobs live outside the record](#outside)
* [The three address levels](#levels)
* [The layouts, pinned](#layouts)
* [Segmented and stream framings](#framings)
* [Three laws the probes settled](#laws)
* [The oracle, both directions](#oracle)
* [What slice 1 converts, and what waits](#scope)
* [Roadmap](#roadmap)

<a name="outside"></a>
## Blobs live outside the record

A blob column stores an 8-byte id — `bid`: `u16` relation, a pad
byte, and a 40-bit record number (`RecordNumber.h:63-71`, little-
endian branch). The blob itself is a "record" of its own on the
relation's data pages: a slot whose bytes are not a record header but
a **blob header** (`blh` — `dpm.epp:2491` lays it down in place of an
`rhd`), discriminated by `rhd_blob` (16) in the slot's flags word at
offset 10. Records and blobs interleave freely on the same data
pages; the record numbers share one positional space.

That placement is why the blob crate sits on `fire-crab-ods`: finding
a blob *is* finding a record slot (`pointer page → data page → slot
directory`), and creating one *is* the same `find_space` /
`write_at_spot` placement every record takes —
`ods::insert_blob_slot` owns *where* the header lives, `fire-crab-blb`
owns *what it says*.

<a name="levels"></a>
## The three address levels

`blh_level` says what follows the 28-byte header:

- **Level 0 — inline.** The framed data itself, in the slot. Ceiling:
  a data-page slot (`page_size − 28` less the slot directory), so
  roughly one page.
- **Level 1 — a page vector.** `blh_page[]`, an array of `u32` page
  numbers, each a **blob page** (`pag_type` 8): 28 bytes of header,
  then `blp_length` bytes of data. The vector must fit the slot —
  about two thousand pages at 8 KB, so level 1 tops out around
  16 MB there.
- **Level 2 — pointer pages.** `blh_page[]` names blob *pointer*
  pages (`pag_flags & blp_pointers`), whose data area is itself a
  vector of data-page numbers. The same
  never-point-into-space shape the careful-writes chapter orders,
  one level deeper. The gate's 36 MB blob (a doubling
  `EXECUTE BLOCK`) is a genuine level 2, and `fcblb` reads it
  byte-for-byte against the engine's `SUBSTRING` answers.

A page of the wrong kind at any step **refuses** — the level said one
thing, the page said another, and a guess would read garbage as
content.

<a name="layouts"></a>
## The layouts, pinned

`ods.h` pins every offset with `static_assert`s; the crate's unit
tests mirror them one-for-one, so a drifted field is a failing test
before it is a wrong byte.

```text
blh (32 bytes, ods.h:969)             blob_page (32 bytes, ods.h:271)
  0  blh_lead_page    u32               0  pag: type 8, flags @1
  4  blh_max_sequence u32              12  pag_pageno       u32
  8  blh_max_segment  u16              16  blp_lead_page    u32
 10  blh_flags        u16              20  blp_sequence     u32
 12  blh_count        u32              24  blp_length       u16
 16  blh_length       u64              26  blp_pad          u16
 24  blh_sub_type     u16              28  data / page vector
 26  blh_charset      u8
 27  blh_level        u8
 28  inline data or blh_page[] u32...
```

<a name="framings"></a>
## Segmented and stream framings

Two content framings ride the same storage:

- **Segmented** (the default): the byte stream is
  `[u16 length][payload]` per segment. `blh_count` counts segments,
  `blh_max_segment` the longest payload. The engine hands segments
  back one at a time (`BLB_get_segment`); the crate's
  `Blob::segments()` is that view, and `Blob::content()` is the
  deframed whole. A zero-length segment is legal and survives the
  framing (unit-pinned).
- **Stream** (`rhd_stream_blob`, 32, in the slot flags): raw bytes,
  no framing — what bulk loaders and the engine's own metadata
  blobs use.

<a name="laws"></a>
## Three laws the probes settled

1. **`blh_max_sequence` is the LAST sequence, not the count.**
   `ods.h` comments it "Number of data pages"; the reading loop
   (`blb.cpp:2377`) stops at `blb_sequence > blb_max_sequence`, so
   the field is `n_pages − 1`. The draft wrote the count — and the
   engine read one page past the vector, hit a zero entry, and
   called the file corrupt (`page 0 is of wrong type (expected
   blob, found database header)`). The comment misleads; the code
   decides.
2. **`blh_length` counts payload, framing excluded.** Probed: the
   engine's `OCTET_LENGTH` equals it exactly, for level-0 inline
   blobs and 36 MB level-2 blobs alike.
3. **The flag values are what `ods.h` says, not what memory says.**
   `rhd_blob` is 16 and `rhd_stream_blob` is 32; a first-guess 8
   made every real blob slot "not a blob". The porting playbook's
   standing rule — grep the header, never trust recall — earned
   another notch.

<a name="oracle"></a>
## The oracle, both directions

**Reading** (phase A of `qa/blb-levels.sh`): the engine creates text
blobs — empty, one byte, ten bytes, a NULL, then a doubling
`EXECUTE BLOCK` that walks one value to 9 MB (level 1) and 36 MB
(level 2). For every row the gate compares `fcblb`'s `LEN`, `HEAD`,
`MID` and `TAIL` content slices against the engine's own
`OCTET_LENGTH` and `SUBSTRING` answers, and asserts the decoded
level is the one the size demands (`0/0/null/0/1/2`).

**Writing** (phase B): `fcblb write` creates blobs through
fire-crab's own path — empty, tiny with 7-byte segments, at the
level-0 ceiling, just past it, 120 KB with 4000-byte and
65535-byte segments, and a megabyte — plus the records that
reference them (the `bid` laid into a record image at the column's
descriptor offset). The engine then reads every one back in full,
`gfix -v -full -n` finds neither errors nor warnings, and `gbak`
backs the file up. `fcblb` also re-reads its own writes, closing the
self-consistency loop.

The two phases share no code path in either system — engine-write /
crab-read and crab-write / engine-read cross the boundary in
opposite directions, so an error in a shared assumption has nowhere
to hide.

<a name="scope"></a>
## What slice 1 converts, and what waits

| Converted | Where |
|---|---|
| `blh` decode/encode, offsets pinned | `BlobHeader` |
| `blp` data pages, header + `blp_length` | `blob_page_data` |
| Level 0/1/2 reading | `read_blob` |
| Segment framing, both directions | `SegmentIter` / `create_blob` |
| Stream-blob content | `Blob::content` |
| Level 0/1/2 creation + page allocation | `create_blob` (+ `ods::allocate_page`, `ods::insert_blob_slot`) |
| Wire serving through this crate | `read_blob_content` (op_open_blob / op_get_segment content source) |
| The referencing record's `bid` | `fcblb write` |

Not yet, by name: **blob garbage collection** (a deleted record's
blobs), **blob filters**, **stream-blob creation**, and the
**per-transaction temporary blob** namespace.

<a name="roadmap"></a>
## Slice 2: level-2 creation and the wire adoption

Both leading roadmap items landed in slice 2. **Level-2 creation**
mirrors the layout probed off the engine's own 36 MB blob: data pages
keep the blob-wide lead and their global sequence; pointer pages are
type 8 with `blp_pointers` set, carry the blob-wide lead, sequence 0
(the engine writes 0 on every pointer page - probed, mirrored), and a
`blp_length` counting the ENTRY BYTES of their u32 data-page vectors;
the slot's `blh_page[]` holds the pointer pages and `blh_max_sequence`
still counts data pages (last sequence). The gate writes an 18 MB
blob through this path - `RECNO n LEVEL 2` - and the engine reads all
eighteen million bytes back, gfix silent, gbak happy.

**Wire adoption**: the server's seven blob call sites now read through
`fire_crab_blb::read_blob_content` instead of the ods reader - so
op_open_blob / op_get_segment serve level-2 blobs no earlier reader
could, proven by the gate's phase C: node-firebird fetches every
fcblb-written blob (the 18 MB level 2 included) over the wire and the
assembled content equals the source files, byte counts and both ends.
The pre-existing `qa/serve-real-blob.sh` differential stays green on
the swapped reader.

## Slice 3: the sweep and the crash matrix

Both leading roadmap items landed. **Blob GC** (`qa/blb-gc.sh`): the
ENGINE's own sweep over a fire-crab-written file — two deleted rows'
level-1 blobs collected, validation silent, survivors intact through
both readers, and the PIP free-bit count rising by exactly the dead
blobs' pages (the bitmap, not the unreliable pip_used counter, is
the allocation truth). **The crash workload** (`fccch crash-matrix
... blob`): level-1 blobs through this crate's own creation path in
the careful-write matrix — fourteen writes with nine blob pages
riding AHEAD of the data pages whose records name them, all fifteen
prefixes engine-valid, the naive order breaking at twelve.

## Slice 4: stream blobs

`create_stream_blob` writes the unframed flavour: `rhd_stream_blob`
set, content raw, `blh_count` 1 and `blh_max_segment` the whole
length. The differential here runs ONE WAY by nature — stream blobs
come from the API's BPB (`isc_bpb_type_stream`), and the probe
confirmed SQL literal blobs store SEGMENTED, so the engine cannot
be asked to write one through isql. What the gate CAN hold is the
direction that exists, and it does: fire-crab writes stream blobs at
levels 0 and 1, and the engine reads every byte back through
OCTET_LENGTH and SUBSTRING — proving in particular that the
unframed bytes are not mistaken for frames.

## Roadmap

1. The `isc_bpb` parameter surface (requested type/charset
   transliteration) — the last named item.
