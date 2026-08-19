# Roadmap: from converted models to a working engine

Every increment so far has answered the same question — *what does the
engine do here?* — and answered it with a differential. That has produced
a server whose SQL surface agrees with Firebird across 150+ gates, and,
alongside it, nine converted subsystems with their own oracles.

This document is about the two things that are **not** more SQL surface.

## Where the project actually stands

**The gbak programme is COMPLETE.** What began as "the backup
writer is fail-closed by design and refuses almost any real
database" ended twenty-one measured slices later with the refusal
ledger's carryable side EMPTY: sequences, the whole constraint
family with its carried trigger records, views (expression columns
included), procedures, user triggers, exceptions, PSQL functions,
roles with their SYSTEM-PRIVILEGE blocks, packages, GTTs, COMMENTs
on twelve families, named domains with DEFAULTs and CHECKs,
argument DEFAULTs, expression indexes built on the EVALUATED
expression, external tables and function declarations, security
mappings, the publication state, blob-filter declarations, and
physical SHADOWS — fc's restore writes the mirror itself and the
engine maintains it. Every slice was pinned off a real .fbk before
a line of writer existed, proven differentially in BOTH directions
(the engine restores fc's file and fc restores the engine's, with
execution — not just catalog digests — wherever the object can
run), and swept. What still refuses is exactly what fail-closed
honesty demands: an index expression the restore cannot evaluate
(refused whole at build time, never keyed by a guess — the standing
boundary representative in `qa/serve-real-gbakrestore.sh`), and
multi-file shapes FB6 itself can no longer produce. The programme's
laws — the runtime summary is the truth (field lists, trigger
vectors, defaults, validation), the domain IS the type (and the
expression), schema qualifiers are load-bearing, the server lingers
same-path attachments — are each one line in the ledger below, with
the narrative in the commit that paid for it. Per-slice: gbak 58
checks, gbakrestore 39, gbakse 12, gbakverbose 14.

**The next big chunk: incremental nbackup — and its first slice is
in.** Level-0 nbak/nrest were already served; what was missing was
the CHAIN. Slice A (done): fc's level-0 writes the same bookkeeping
the engine's does — the backup GUID into the main header, an
RDB$BACKUP_HISTORY row anchored at the current ERA, the era
advanced — and fc's page writes now stamp the nbackup SCN (the
page's own pag_scn and its slot on the type-10 inventory page),
closing a measured SILENT DATA LOSS: a row inserted through this
server was missing from an engine level-1 chained on a level-0,
because an fc-written page looked unchanged to the engine's
incremental selection. The cross-implementation chain is the gate's
own cell now: fc anchors, fc writes, the ENGINE increments and
restores, and the fc-written row rides. Remaining slices: fc
PRODUCES level-N (the NBAK container: magic + version + level +
this/previous GUIDs + page size, then the changed pages), fc
RESTORES chains (GUID verification, "Wrong order" refusals), and
ALTER DATABASE BEGIN/END BACKUP with the .delta redirection.
(TIMESTAMP WITH TIME ZONE learned its system-format mapping on the
way — type 29 was unanswerable, which had hidden RDB$BACKUP_HISTORY
from every reader.)

The subsystem map's rows fall into three states, and the difference
matters more than the row count:

| state | rows | what it means |
|---|---|---|
| **done** | on-disk structures, record decode + RLE, PIP, pointer/data pages, B-tree decode, TIP/MVCC, GC/sweep, BLR decode | converted and held against an oracle; the server depends on them |
| **converted, wired** | `ods`, `blb`, `auth`, `svc`, `exe`, `dsql` | the running server links and uses them |
| **converted, wired** | `evt` | `POST_EVENT` posts into it, commits move its counters, and the delivery is CARRIED over the auxiliary connection - the paper's own `samples/nodejs/events.js` prints the same lines against fire-crab as against the engine (W5 done) |
| **converted, wired** | `stmc` | the plan a statement resolves to is kept per attachment and dropped by DDL. It took moving the two prepare-time FOLDS to fetch first — a lone aggregate and a `GEN_ID` read were computed by the planner and carried in the plan, so a kept plan answered the same number for ever |
| **wired** | `lck` | a writer that meets another transaction's uncommitted row waits on that transaction's own lock and then re-reads, and two waiting on each other are denied by the wait-for scan with the engine's `isc_deadlock` (W4) |
| **converted, wired** | `opt`, `cch`, `pio` | the server asks `opt` for the access path and takes an index when it says so (W1 — equality, ranges, compound prefixes, text keys, ORDER BY navigation, the FK check, DML targets, the fold's input, the LEFT-join inner side and the join DRIVER); the pages of a file live once per process in `cch`'s buffer pool, are FETCHED one page at a time and flushed in its careful write order (W2), and written with `pio` in the open mode the header's Forced Writes flag calls for (W3) |

That third row **is closed.** `crates/wire/Cargo.toml` depends on `-lck`
as well as `-opt`, `-cch` and `-pio`; only `-evt` is a conversion the
delivery path reaches without the running server linking a call site. The
optimizer's choice is executed rather than merely printed, across every
retrieval shape W1 has taken. The lock manager arbitrates the rows two
transactions both want, and denies the cycle when they wait on each other.
The page cache holds the file's pages once for every attachment, hands
them out ONE PAGE AT A TIME (the per-page fetch flip — a page-addressed
`ods::Image` of `Vec<Arc<[u8]>>`, so a write's cost is O(pages) end to
end rather than O(file)), and flushes only the pages an Arc-identity diff
says changed.

And inside the SQL layer the second structural gap **is closed too.** The
server used to answer views, CTEs and constant subqueries by rewriting SQL
text and re-planning it, where the engine builds a tree of record sources.
That is why a CTE body that GROUPed refused, why `FROM (SELECT ...)` did
not exist, why `WITH RECURSIVE` could not work, and why a qualifier-
stripping pass had to be taught not to reach inside a subquery. R1–R6
closed all four, R7 retired the rewriting they replaced (~870 lines gone),
and R8 made the fetch PULL the tree rather than materialise a `Vec` — so
`FIRST n` stops the scan and a raiser deep in a derived table delivers the
rows before it.

**So the two things this document was about are done — and so is the
frontier the savepoint slice named after them.** Snapshot isolation is in:
`op_transaction` parses the TPB (`parse_tpb` reads concurrency vs read
committed, wait/nowait, lock-timeout and consistency), an explicit
`isc_tpb_concurrency` captures a stable `ods::tra::Snapshot { limit,
active }` whose `sees(tx)` decides every version's visibility, and the
autonomous-block boundary the savepoint section closed with ("the outer
transaction does not see its own block's commit") is a passing check now,
gated by `serve-real-snapshot.sh`, `serve-real-concurrency.sh` and
`serve-real-autonomous.sh`.

What is left is no longer one headline chunk but a **short list of
measured or pinned items**, each recorded in its own place below:

- **cost** — the metadata cache took the per-statement column walk off
  the primary plan path, and `Database::columns` has now routed the
  SECONDARY planners (DML targets, subquery/derived sources, join sides,
  the correlated-outer split) through it too (~21% off a re-planning
  DELETE, measured old-vs-new); the CHAR-decode residual is closed too —
  `intl::fit_char` is a single pass now and the decoder trims a CHAR's
  blank padding as bytes before UTF8-decoding it (~20% off a CHAR-decode-
  bound scan); and the deferred `choose_index` at execute is closed —
  its optimizer GATE (does an index serve this? — invariant across a
  prepared statement's executes) is memoised in the epoch cache, so a
  parameterised WHERE resolves its band without re-running the optimizer
  each time (~26–43% off a re-executed `WHERE col = ?`). The record walk
  was the last measured residual, and PARTIAL DECOMPRESSION closed it: a
  scan `sqz::unpack`ed the WHOLE record before the projection picked
  fields, so a plain scan now decompresses only up to the last byte its
  projection, WHERE and ORDER BY read (`sqz::unpack_prefix`, a read-length
  carried from `Plan::Project` to the scan leaf; `usize::MAX` for anything
  it cannot prove). Old-vs-new on `SELECT id` over eight VARCHAR(200)
  columns: **3.01 → 1.52 µs/row, ~49%**, and a narrow all-int scan is
  unchanged (nothing to prune). This is where COLUMN PRUNING — decoding
  only the read fields — failed at 2%, because the decode was never the
  cost; the decompression was. What is left is the fundamental decompress
  of the columns actually read and the WIRE ENCODE, and the wire encode
  was measured too: on a wide `SELECT` shipping eight VARCHARs it is
  ~0.76 µs per string column, but that is byte-shipping, not redundancy —
  removing `render()`'s String clone and short-circuiting
  `enforce_out_capacity` each moved it ~0% (Rust's allocator makes a small
  String clone free against the copy and the send). What DID cost was the
  batch MATERIALISATION — the whole cursor was collected into a
  `Vec<Vec<Value>>` before a byte was encoded — and CURSOR STREAMING closed
  it: a plain scan now produces `want` rows per fetch and remembers its
  place (`StreamCursor`) rather than building the whole result. Reading the
  first 200 rows of a 50,000-row cursor went from 18.8 to 3.3 ms of server
  CPU (~5.7×, now O(rows fetched) not O(result)), reading ALL 50,000 from
  38.5 to 25.6 ms (~33%, the copy through `Plan::Rows` gone), and peak
  memory from O(result) to O(batch) — the scalability wall a large result
  hit. R8's "the fetch pulls the tree" is real for the shape it fits;
- **the optimizer's stale-statistics region** — ~~statistics non-zero but
  WRONG are unmeasured~~ MEASURED AND CLOSED (`qa/opt-stale.sh`, the
  load / `SET STATISTICS` / grow fixture family): fcopt reads the stale
  figure the way the engine reads it across the whole measured surface,
  the filtered-driver join included — the missing term was the driver's
  own filter selectivity (`stream_filter_selectivity`), see the
  stale-statistics section below;
- **the two R8 tails** — `NestedLoopJoin` still materialises for RIGHT and
  FULL, and the fetch is a PUSH with a `Flow::Stop` rather than the
  engine's row-by-row pull across the wire (observationally equal for
  errors and early exit);
- **the write-side refusals held on purpose** — ~~a store that would
  fragment across pages~~, the DDL patch sites that would rewrite a
  fragmented record, ~~transliteration between charsets~~, and the
  scattered correctness boundaries each gate pins.

  **The fragmenting store is TAKEN** (`ods::dml::insert_record_fragmented`):
  a record too large for one page is written as the engine's own chain
  shape — the head with `rhd_incomplete` and an rhdf forward pointer,
  middle fragments `rhd_fragment | rhd_incomplete`, the last
  `rhd_fragment` alone — every piece NOT_PACKED, because the engine's
  unpack tests that PER PIECE (vio.cpp:575-602), and written TAIL FIRST
  so each piece points at an already-placed successor. The split points
  are this writer's own: the assembled image is identical either way,
  and both readers just follow the chain (gstat counts a different
  fragment total for the same bytes — the split, not the data).
  Verified whole: fire-crab inserts a 20,000-byte row as a 3-piece
  chain, reassembles it itself, the ENGINE reassembles it, finds it by
  content, and `gfix -v -full` is clean. ~~UPDATE and DELETE of a
  fragmented HEAD still refuse~~ — TAKEN with it: `push_back_version`
  accepts an `rhd_incomplete` head (the copied head keeps its rhdf
  forward pointer, so the back version IS the old chain — fragments
  never point at the head, so moving it moves nothing else), and a big
  NEW image in an UPDATE chains with its head rewritten IN PLACE at the
  fixed primary slot, carrying both the back pointer and the forward
  pointer (the head's data sized to what the slot already held — every
  stored record is padded to RHDF_SIZE, so the bare header always
  fits). Shrink-to-small, grow-to-chain, and DELETE of a fragmented
  head all verified with the engine reading the result and gfix clean.
  `qa/serve-real-fragstore.sh` (13) pins the store and the DML both.

  **Transliteration is TAKEN** (`ods::intl::decode_text`/`encode_text`,
  WIN1252 + ISO8859_1 codepage tables, bijective on all 256 bytes so a
  round trip reproduces the stored bytes). Before them, a stored 0xE9
  read through `from_utf8_lossy` became the replacement character - the
  value DESTROYED on rows the ENGINE had written, `OCTET_LENGTH`
  counting the replacement's three bytes - and a write stored UTF-8
  bytes the engine read as mojibake. Now the DECODE speaks the
  codepage; the STORE writes the codepage's bytes (the engine reads
  fire-crab's `garçon` back byte-identically and finds it by value);
  INDEX KEYS carry the codepage bytes (`KeySeg::charset`, threaded
  through every build and band so a key lands where the engine's own
  keys sit — an unmappable search key answers None and SCANS rather
  than missing rows); the WIRE encode re-spells a value into a
  single-byte attachment's codepage (a WIN1252 isql attachment reads
  identical bytes from fire-crab's file and the engine's);
  `OCTET_LENGTH` over such a column counts the COLUMN's bytes
  (`SysFn::OctetLengthCs`, rewritten at resolution where the
  descriptor is); and an unmappable character refuses where the engine
  raises SQLSTATE 22018 (*Cannot transliterate*, the
  `EvalErr::TransliterationFailed` vector) - both reject, the row
  never lands. `qa/serve-real-xlit.sh` (14) pins the whole family
  against live twins, the write-back read with the engine's own tools.
  ~~Still held: DML on a table whose index carries an INTL itype~~ —
  TAKEN the same day. The on-disk irtd stamps
  `ttype + idx_offset_intl_range` (btr.h:141, 0x7FFF + 64: a WIN1252
  default collation stores 32884 = 32831 + 53 — the first build decoded
  against `idx_first_intl_string` alone and refused everything, caught
  by dumping the irtd off a live file). Its key, measured off a live
  engine index: the CODEPAGE bytes with trailing 0x20 stripped, the
  empty value keyed [00] — IDX_METADATA's shape in the column's own
  character set ('café' keys [63,61,66,E9], '€' keys [80]).
  `btw::intl_binary_charset` recognises the DEFAULT (binary) collation
  of a tabled set; a REAL collation (PXW_INTL and kin, its own weight
  tables) still answers None — fail-closed as the allowlists always
  were. With the itype accepted in `resolve_index_ops`,
  `pick_for_terms` and the navigation gate, fire-crab INSERTs and
  UPDATEs maintain the tree with the engine's own keys (verified:
  the engine finds fc's 'süß' — [73,FC,DF] in the dump — through ITS
  index, gfix -v -full clean), and fc's own retrieval bands the
  codepage key. serve-real-xlit.sh 14 -> 17. ~~Still held: a NONE
  column's high bytes.~~ — TAKEN: NONE (with OCTETS and ASCII) is a
  BYTE CARRIER now. The engine never transliterates such a column (a
  stored 0xE9 reaches a UTF8 attachment as the one byte 0xE9,
  measured), CHAR_LENGTH counts its bytes, comparison is byte-wise,
  and its index keys are the raw bytes ([72,61,74,E9] for a raw-byte
  row, off a live engine index). fire-crab carries such values one
  char per byte (the Latin-1 carrier, `carrier_decode`/
  `carrier_encode` - lossless where the lossy-UTF8 read destroyed the
  high bytes of engine-written rows): the DECODE speaks it, index KEYS
  encode back to the raw bytes, the WIRE hands every attachment the
  stored bytes verbatim, OCTET_LENGTH counts the carrier's bytes, and
  a REAL literal compared against a carrier column is LIFTED to the
  carrier of its own UTF-8 bytes (one transform in
  `param_or_typed_term`, where the descriptor is) - so 'café' meets
  the stored C3 A9 pair and not a raw E9, the engine's byte compare.
  The STORE keeps the client-boundary rule (a literal's UTF-8 bytes
  verbatim - already the engine's behaviour); ~~a cross-charset
  INSERT..SELECT INTO a NONE column diverges (the engine copies the
  source codepage's bytes, fc stores the decoded text's UTF-8) -
  recorded~~ — TAKEN: the engine's whole assignment matrix was
  measured off the live engine (a tabled source writes its CODEPAGE
  bytes into a NONE column — WIN1252 'é€2' lands E9 80 32, not
  UTF-8's six; a NONE source copies bytes VERBATIM into any
  single-byte destination and only validly into UTF8 — F8 EC 32
  refuses there with the engine's 22000; tabled-to-tabled
  transliterates through Unicode with 22018 on a missing image), and
  `insert_select` now binds a selected text value as a
  charset-tagged parameter (`WireParam::TextCs`, the source column's
  charset read off the SELECT's projection) so `text_bytes_for` can
  follow that law instead of losing the charset in a re-spelled
  literal. Gated in serve-real-xlit.sh (40 -> 42). ASCII content is
  the identity through every seam, which is why the whole existing
  gate surface is untouched.

  **A wire PARAMETER's bytes mean what the ATTACHMENT charset says** —
  the last lossy seam: every text param came off the XDR message
  through `from_utf8_lossy`, so a NONE-attachment client's raw 0xE9
  was corrupted into the replacement character (stored!), a WIN1252
  column refused a byte the engine stores verbatim, and a UTF8 column
  accepted a malformed string the engine refuses (all probed against
  the live engine). `wire_text_param` decodes by the attachment's
  lc_ctype now — conservatively: all-ASCII bytes keep the old shape
  (identical under every charset, whole gate surface untouched by
  construction), non-ASCII bytes become `WireParam::TextCs` (the
  carrier's chars under NONE, the codepage's under a tabled set) and
  the store's assignment matrix already speaks them. The bind sites
  alias TextCs beside Text, and the byte compare answers through the
  same parameter with no lift and no double encoding.
  serve-real-xlit.sh 42 -> 46.

  **UPPER/LOWER take the CHARSET's own case law** — generated from the
  live engine like the codepage tables (`UNICODE_VAL(UPPER(S))` over
  one-byte rows, all five tabled sets). The law is per-charset, not
  Unicode's: WIN1252 'ß' upcases to ITSELF (Rust's full mapping says
  "SS" — a length change the engine never makes, and the UTF8 UPPER
  keeps 'ß' too, so the default arm switched to the SIMPLE mapping);
  ISO8859_1's 'ÿ' has no pair and stays while WIN1252's becomes 'Ÿ';
  and exactly ONE cell errors — WIN1252 0x83 'ƒ' UPPER raises the
  engine's 22018 (no 'Ƒ' in cp1252) while its LOWER answers. Wrapped
  at the OctetLengthCs seam (`SysFn::UpperCs`/`LowerCs`, stamped at
  resolution; a byte-carrier column cases ASCII only, probed).
  serve-real-xlit.sh 46 -> 57 with UPPER and LOWER over every letter
  byte of the three generated sets compared against the engine.
  DEFAULT collation only, measured: a REAL collation carries its OWN
  case tables — PXW_INTL upcases 'é' to 'E' (accent-stripping, the
  Paradox convention) and does NOT raise on 'ƒ' — so a collated
  column keeps the simple-mapping arm until the collation's case
  tables are wired (recorded divergence: fc answers 'É' there).

  **The narrow collation driver is CONVERTED** (`ods::coll`, from the
  vendored lc_narrow.cpp with pw1252intl.h transcribed by script):
  PXW_INTL orders, compares and KEYS. ORDER BY answers the engine's
  measured order (a á A a-b ab aB Ab ab- aé b e é ss ß st z — case
  and accents at the secondary level, the ß expansion losing its tie
  against 'ss'); WHERE compares through `Expr::CollKey` wraps (both
  sides evaluate to the collation KEY spelled as a carrier string —
  keys collate bytewise, so the plain value compare over wrapped
  sides IS the collation's compare); and fire-crab's DML maintains
  the PXW_INTL index with the engine's own key bytes, proven by the
  ENGINE's index scan finding fc-written rows by collated equality
  and accent-blind range, gfix clean. Discovered against the first
  reading of the C source: PXW_INTL has NO specials — its punctuation
  carries a plain primary in place ('a-b' < 'ab', probed live).
  `qa/serve-real-collate.sh` (13). ~~Deferred: a bound `?` against a
  collated column, the collation's own case tables~~ — both TAKEN the
  next slice: `SysFn::UpperColl`/`LowerColl` drive the transcribed
  ToUpper/ToLowerConversionTbl (validated byte-for-byte against the
  live engine; accent-stripping on UPPER only, LOWER keeps accents,
  nothing raises), and a collated column's `?` term resolves with the
  CollKey lhs so the bind wraps the arriving value to match (a bound
  'a ' pads, a bound range takes accents with their bases; a NUMERIC
  bind steps around the wrap for the per-row coercion).
  serve-real-collate.sh 13 -> 16. Still deferred, recorded: grouped
  ORDER BY stamps, collated retrieval BANDS (scans today, correctly),
  and the other PXW weight tables (same driver, tables per collation
  — PXW_CSY brings the first live CompressTbl, the 'ch' digraph).
  serve-real-xlit.sh 17 -> 20. ~~Still held: the untabled codepages~~ —
  three more TAKEN: WIN1250, WIN1251 and ISO8859_2, and their tables
  were GENERATED FROM THE LIVE ENGINE rather than typed from a chart:
  128 one-byte rows per set inserted as hex literals through a NONE
  attachment, read back as `UNICODE_VAL(S)` through a UTF8 one — the
  engine's own transliteration IS the table (`ods::intl`, full
  128-entry high halves since Latin-2 and Cyrillic diverge from
  Latin-1 above 0xA0 too; `tabled()` extended, which carries the
  DECODE, STORE, KEYS, WIRE, LENGTHS and INTL-itype seams for free —
  a WIN1251 index fc keys is found by the engine's scan, measured in
  the gate). The generation surfaced an engine law the chart never
  shows: a codepage HOLE (WIN1250's 0x81/83/88/90/98, WIN1251's 0x98,
  WIN1252's five) transliterates to U+0000, and the REVERSE direction
  refuses (storing U+0081 raises 22018) — ISO8859_2 has NO holes, its
  0x80..0x9F row is identity C1. fire-crab keeps a hole at its C1
  point instead (the WIN1252 precedent): that keeps each table a
  bijection on 256 bytes, which the NONE-attachment passthrough
  depends on — the divergence is confined to undefined bytes crossing
  charsets, recorded not gated. serve-real-xlit.sh 20 -> 40: real
  Czech/Polish/Cyrillic words through every seam, and EVERY DEFINED
  PRINTABLE BYTE of each new set compared fc-served against the
  engine (holes, NBSP and SHY excluded from the byte sweep — the
  first for the recorded divergence, the last two because whitespace
  normalization eats them). Still held: the real collations
  (PXW_INTL and kin, their own weight tables).

  **The 22018 argument spells the COLUMN CHARSET's bytes** — the full
  sweep after the codepage slice caught two textcolcmp cells the
  byte-carrier slice had silently broken: fc escaped the Rust
  String's UTF-8 (`text.bytes()`), so a NONE value spelled
  `#xc3#x82#xc2#xa02` where the engine spells `#xc2#xa02` — and the
  same bug would have doubled a WIN1252 'é' (probed: the engine's
  CVT_conversion_error renders the value's bytes in its OWN character
  set before any transliteration to the attachment, CAST and implicit
  compare alike). The charset rides the wraps now — `Expr::Cast`,
  `TextNum`, `TextNumKey`, `TextBool`, `Term::ExprParam` each carry
  the text side's charset, stamped at resolution off the descriptor
  (a field, not a transparent wrapper: the field makes every
  shape-matching site a compile error where a wrapper would slip past
  them silently) — and the raise sites build
  `EvalErr::ConversionErrorBytes` through `conv_err`. textcolcmp
  345 -> 352 with a per-charset spelling section, all green.

The rest of this document records how the surface got here and every one
of those boundaries.

## Measured gaps that are nobody's slice yet

The OPEN entries, each measured against the live engine and waiting
for a slice. The closed ones moved to the ledger below - the full
narrative of every closure is in git history and the gate that pins it.

- **A REFUSAL THAT WAS CLOSED AND NOT UNRECORDED.** `qa/serve-real-qualname.sh`
  section K asserted that a view inside an IN / EXISTS / scalar subquery
  REFUSES — true when written, because the nested path did not expand a
  view and a view has no records of its own. **R7 closed it** (a VIEW IS
  A ROW SOURCE, so a subquery plans one like every other consumer) and
  nobody returned to the gate, so four checks went on asserting a refusal
  that no longer happens. *A gate failing because the server improved
  reads exactly like a regression* — what distinguishes them is running
  the OLD binary, where the same four DIFFs appear. They assert agreement
  now, over a FILTERING view (`C > 1`) so the check can tell a body that
  RAN from storage that was SCANNED: both old failure modes — zero rows,
  and everything — get that one wrong. 115 → 118 checks.

- **169/169 does NOT mean the cost model is right everywhere the guard
  used to refuse.** On a stale UNIQUE/PK index there is a structural miss
  at (1200, 700) — engine `PLAN HASH`, fcopt `JOIN_SWAP`, loop 4375.7
  against hash 6417.7, a 47% margin — and it is **pre-existing**: it
  reproduces on the same database with FRESH statistics, where the guard
  never fired. Removing the guard unmasked it; it did not create it.

- **Restored databases fragment their catalogues heavily, and not where
  the source did.** Measured on a 220-table schema: 292 fragmented rows
  after `gbak -b`/`gbak -c`, concentrated in `RDB$INDICES` (27.4% of
  rows) and `RDB$RELATIONS` (28.4%); the un-backed-up source had 45, in
  different relations. **Restore does not preserve fragmentation, it
  relocates it.** And it is not the >8151-byte case: `dpm.epp:2650-2656`
  fragments whenever an UPDATE's new version exceeds the space left on
  the page the record already occupies, so ordinary small catalogue rows
  fragment as restore replays DDL onto crowded pages. An EMPTY database
  gains 26 fragmented rows from a backup/restore round trip alone.

- **The engine converts a NONE column into the ATTACHMENT charset on
  the way out, and fire-crab does not.** Measured with plain ASCII: a
  stored `'ab '` (OCTET_LENGTH 3) answers `'ab'` through a UTF8
  attachment and `'ab '` through a NONE one; fire-crab passes the
  stored bytes through on every attachment. Same family as the
  transliteration entry below, but it bites on a BLANK, not a high
  byte — any gate comparing VARCHAR VALUES with trailing blanks must
  compare a server-side length instead (see serve-real-starting.sh).

- **`qa/auth-srp.sh` has harness bugs**: its NF path is $0-relative
  (node resolves it as a module unless invoked by absolute path), its
  default port has no listener on this box, and the 30 s security-db
  wait is occasionally short. Green (13 OK) when invoked by absolute
  path. Unclaimed.

- **The stale grid's only threshold is the 20→30 step**, which the
  widened size set barely straddles and the old `{0,1,5,50,500,3000}` set
  jumped clean over. Any stale-region model tuned on the old grid had
  zero cells near the one boundary that decides it. When the
  `DEFAULT_SELECTIVITY` increment comes, the size set needs points
  *inside* 20-30, not merely either side.

- **The HASH band edge is not a scale-invariant ratio and does not move
  monotonically with size.** Measured brackets: at base 20 the edge is in
  (1.50, 1.55]; at base 100 in (1.30, 1.40]; at base 1000 in (1.55,
  1.70]. So the band is *narrowest in the middle*. Any "HASH iff the
  cardinalities are within factor F" model is refuted by measurement, and
  one fitted on a single decade will mis-predict another. **That warning
  is now historical**: those edges live in the INDEXED regime, which the
  converted cost arithmetic owns outright, and the band fallback's own
  domain (no index on the join key) turned out to have no edge at all —
  measured across a 1..500-per-side sweep, an UNINDEXED equi key HASHES
  at every size (the engine's page-based cardinality estimate never
  looks empty enough for avoidHashJoin on a real table), larger stream
  probing first, ties in SQL order; a THETA join cannot hash and LOOPS
  with the smaller stream driving; a HALF-INDEXED equality nests the
  indexed side as the loop's inner (the old bands' arrangement search,
  kept for exactly that case); and a CROSS-FAMILY equality still hashes
  — the type family only gates INDEX use. The old band's middle refused
  those cells, and its large-large corner even HASHED a theta join the
  engine loops — a live wrong plan the conversion closed.
  `qa/opt-plans.sh` +4 on a new unindexed fixture (108 -> 112), the
  half-indexed and cross-family cells already pinned on T/U.

- **The `opt` cost model is plan-text fidelity only, today.** A fleet
  established the mechanism: `server.rs` discards any plan that is not a
  one-element `Access::Index | Access::Order` stream, `plan_join_bound`
  pushes a `TableScan` for every base side without ever calling
  `choose_index`, and there is no hash-join row source. So the four
  coupled cost-model edits (the doubled selectivity in `loop_cost`,
  charging position 0, pricing both hash arrangements, and the
  `MINIMUM_CARDINALITY` cap on a unique hashed side), the
  `DEFAULT_SELECTIVITY = 0.1` substitution, the one-sided-index arm, and
  the removal of the stale-statistics guard are all worth doing — the
  crate's stated purpose is agreeing with `SET PLANONLY ON`, and a
  correct model is a hard prerequisite for the keyed join — but none of
  them changes an executed plan until that join exists. They must ship as
  ONE increment for the first four, because each alone regresses a
  measured fixture.

- **The engine's string→double is not correctly rounded**, and fire-crab
  is. `'99999999999999999'` becomes `100000000000000020` on the engine
  where the nearest double is `100000000000000000`. Not a gap to close —
  copying a one-ulp error would make fire-crab less accurate — but a
  divergence that exists, so `qa/serve-real-textnum.sh` compares twins
  only up to sixteen significant digits and checks correctness directly
  beyond that.

- **UNIQUE/PK enforcement is FINAL-STATE, the engine's is WALK-ORDER —
  a self-overlapping key-shift UPDATE commits here where the engine
  refuses 23000.** Probed: from identical fixtures (`W`: PK 1..10;
  `U2`: UNIQUE 10,20..100), `UPDATE W SET ID = ID + 1 WHERE ID >= 5`
  — engine `SQLSTATE 23000 ... ("ID" = 6), Records affected: 0`; fc
  `Records affected: 6`, durable state `{1,2,3,4,6..11}` vs the
  engine's untouched `{1..10}`, gfix -v -full clean on fc's file (the
  divergence is silent and semantic). Same on `U2 SET K = K + 10`.
  The executor rewrites all collected record images FIRST and
  `unique_conflict` (crates/wire/src/server.rs, the enforce path
  around it) judges uniqueness from the CURRENT images — a deferred
  final-state check — while the engine enforces row-at-a-time in walk
  order. Direction-aware by accident: `SET ID = ID - 1 WHERE ID <= 4`
  matches (both succeed), and a shift into an UNTOUCHED row is refused
  by both with full rollback; only the self-overlapping,
  conflict-free-final-state shape diverges. Shared with the
  FC_NO_INDEX build, so it is the common write path, not the index
  walk. Pre-existing, durable, structurally clean — a real
  enforcement-order slice in the write path. — *FIXED*: enforcement is
  now row-at-a-time in RECNO order (probed: the engine's walk is
  record-number order even under an index-driven UPDATE) through one
  interleaved write-then-index loop seeing the partially-updated
  state, and every constraint refusal carries the engine's 23000
  vector byte-exact (constraint vs bare-index codes, FK direction
  items, print_key's format). **The gate's engine re-reads also
  exposed a pre-existing FILE CORRUPTION at clean HEAD: any UPDATE of
  a table whose record data is under 9 bytes re-stored the RHDF fill
  RLE-packed and the engine then unpacked past fmt_length — BUGCHECK
  179. Fixed (trim to fmt_length + the RHDF fill in ods).** Residuals:
  PSQL bodies flatten constraint errors to strings; INSERT images may
  carry the fill byte (NOT_PACKED, engine-forgiven); FK cascades and
  param'd UPDATE defer unchanged. `qa/serve-real-uniqueorder.sh`.

- **Packaged-procedure calls refuse** — `EXECUTE PROCEDURE
  RDB$PROFILER.FLUSH` (and the 3-part `SYSTEM.RDB$PROFILER.FLUSH`):
  the engine prepares TYPE 8 and executes (`NONE []`); fc refuses. A
  package qualifier is not a schema qualifier, and the PUBLIC rule
  currently swallows both. Pre-existing, refusal-only. Unclaimed.

- **The compensating undo of an absolute set is DEFERRED in the engine
  and EAGER here** — a divergence this slice's probing found and did
  NOT introduce (identical on the pre-slice binary). The engine runs an
  absolute set's compensating record at TRANSACTION END: read the
  generator between a `ROLLBACK TO SAVEPOINT` that undid the set and
  the commit, and the engine still answers the *un-compensated* value.
  `SAVEPOINT SP; ALTER TABLE AID ALTER COLUMN ID RESTART WITH 100;
  ROLLBACK TO SP; INSERT INTO AID (V) VALUES (3);` writes `ID 100` on
  the engine and `ID 2` here; the same shape through `ALTER SEQUENCE`
  answers 101 against 51. Put a `COMMIT` after the `ROLLBACK TO SP` and
  both sides agree again, which is why every phase of
  `qa/serve-real-gendurable.sh` — all of which read after a commit —
  is green. Matching it needs the record to fire at transaction end
  rather than at the savepoint undo, and to fire on COMMIT as well as
  ROLLBACK when the window that held it was undone; that is a
  visibility model, not a value model, and it is its own slice.

- **Derived-table FLATTENING is the wrong way to close the sorted-raiser
  residual** — recorded so it is not attempted again. Merging `SELECT …
  FROM (SELECT …) X` into one statement would close it and would let an
  index reach through a derived table, but it is EXACTLY the text
  expansion R7 removed (`splice_ctes`: "the old path EXPANDED a
  definition … this moves ONE FROM ITEM and hands the body to the
  planner as a query of its own"). The residual belongs to programme R:
  the sort must carry UNPROJECTED records and apply the projection at
  delivery, which is the lazy row-source tree, not a rewrite.

  **The older measurement, kept for the cells that held:**
  `SET PLANONLY ON` confirms the split: `J1 JOIN J2 ON J2.T = J1.A` and
  the comma spelling are `PLAN HASH`, a LEFT JOIN of the same pair is
  `PLAN JOIN`, and a semi-join inside a VIEW BODY is neither — two
  plain plans. So the strict grammar reaches the first two and must NOT
  reach the other two (fire-crab answers the hashed pair today and is
  over-strict inside the view body, where its message even leaks the
  raw `@1` template slot).

  The GATING, probed cell by cell, and two of these rule out the
  obvious implementation:
  * both sides non-empty → RAISES; either side EMPTY → no raise, count
    0. So it is not a prepare-time refusal.
  * **it raises with NO MATCHING PAIR AT ALL** (`N1 = {12, 999}` against
    `S1 = {'1 2', '34'}` raises) — the hash BUILD reads the key, so a
    per-pair comparison is the wrong unit of evaluation, or at least
    must not be gated on matching.
  * **filtering the bad row off its OWN stream silences it**: `... ON
    S1.T = N1.A AND S1.T = '34'` answers 0, and so does the derived
    spelling `JOIN (SELECT T FROM S1 WHERE T = '34') X`. The engine
    applies a single-side conjunct to that stream BEFORE the hash — the
    same pushdown `side_filter` already implements for the partnerless
    ON raiser, which is where the implementation should start.
  * a FALSE sibling conjunct (`AND 1=0`) silences it, which the
    invariant pass gives for free.

  Not built yet: it needs a strict twin of the `Expr::TextNum` wrap
  (with arms in all of `type_of`/`rank_of`/`result_scale`/`eval`, per
  this file's own law about new variants), the boundary equality of an
  INNER or comma join rewritten to use it, and same-side ON conjuncts
  pushed onto their stream first. Its own slice; the measurement above
  is the expensive half and is done.

  **The older note, kept:**
  `FROM TNI JOIN TK ON TK.S = TNI.N` and the comma spelling both raise
  on the engine and answer here, at HEAD as well as after this fix — the
  join path compares those two columns per row with the lenient
  grammar and does not know which of its equalities the engine turns
  into hash keys. Pinned on both sides at the end of law 11. Closing it
  is a join-path slice, not a fold one. Beside it: `= ANY` / `= ALL`
  have no surface at all here, and an `INSERT ... SELECT` whose WHERE
  carries ANY per-row conversion raiser refuses at prepare rather than
  raising it (`WHERE ID = 'x'` does the same, and did before).

- **The parameter-bind and STORE vectors refuse with a bare `Dynamic
  SQL Error` where the engine raises 22018 with the argument** — the
  CAST slice above chased this and it is A DIFFERENT MACHINE, not the
  whitespace grammar: the grammar there is already 0x20-only and
  correctly REFUSES `'<TAB>2'`; what is missing is the error. And it
  is not TAB-specific — `SELECT … WHERE N = ?` bound `'abc'`, and
  `INSERT INTO T (N) VALUES ('abc')`, answer the same bare message.
  Both sides fail, so no wrong write; it is the prepare-time refusal
  path that needs the engine's status vector, which the per-row
  `Term::CmpConvErr` path already builds. Unclaimed.

## The ledger of closed gaps

One line each; the narrative lives in the commit that closed it and
the gate that keeps it closed.

**The gbak catalog programme (complete, sweeps 8-29):**

- ~~Sequences refuse~~ — the value rides TWICE (backup.epp's own doubling) and restores into the generator vector.
- ~~UNIQUE/FK/CHECK refuse~~ — the three-block constraint order, the FK partner index, carried trigger records verbatim.
- ~~Views and procedures refuse~~ — the RDB$RUNTIME blob IS the field list; att 22 is where RDB$FIELD_ID comes from; rec 29 closes a procedure or the reader desyncs.
- ~~User triggers refuse~~ — rec 13 with the att-14 debug map; the engine fires them on fc's fbk.
- ~~Exceptions refuse~~ — the message is a plain text att; file order preserves RDB$EXCEPTION_NUMBER.
- ~~PSQL functions refuse~~ — the argument's domain IS its type (the record's quintet is zeros); grant type 15.
- ~~Roles refuse~~ — the CHAR(8) OCTETS block as a plain u8-length att; later the block itself rides verbatim (0x42 bit-identical) instead of refusing non-zero.
- ~~Packages refuse~~ — members as ordinary records with package atts (args need att 10 too); and the OLD loader-crash boundary was ONE NULL column: RDB$FIELD_SOURCE_SCHEMA_NAME on param rows.
- ~~GTTs refuse~~ — att 18 typed 4/5, restored EMPTY (their rows were never in the file), restore-side DBKEY 0.
- ~~Expression view columns refuse~~ — the expression lives on the domain as COMPUTED_BLR; three reader desyncs closed with it.
- ~~COMMENTs are dropped or refused~~ — twelve families, one description2 att each, one set_catalog_description; five latent walker desyncs closed.
- ~~Named domains refuse~~ — the real name on rec 2, columns keep it in att 2, create_domain-first binding; expression indexes' silent drop found and typed.
- ~~Domain DEFAULTs/CHECKs refuse~~ — four blobs verbatim; the engine enforces validation from the RUNTIME's RSR_validation_blr segment, not the domain row.
- ~~Argument DEFAULTs refuse~~ — fn atts 13/14, param atts 7/8; the param reader would have desynced and the writer silently dropped them.
- ~~Expression indexes refuse~~ — IRT_EXPRESSION, one key desc of the result type, backfill on the EVALUATED carried BLR; the engine plans through and maintains fc's index.
- ~~External tables refuse~~ — the definition rides (att 17 path, type 2, NO pages); the validator's pointer-page grumble is the engine's own at every external table; fc's serve side stopped answering an empty lie.
- ~~External functions refuse~~ — declarations ride (legacy module+entrypoint with INLINE-typed args — the third arg-typing convention; UDR entrypoint+engine); a stock-module UDR EXECUTES off both restores.
- ~~Mappings are silently dropped~~ — rec 37 verbatim; and the boundary flip taught the lingering-server harness law (fresh fixture names per era).
- ~~Publications were never fixtured~~ — the DEFAULT publication's state is two booleans on the DATABASE record (fc had hardcoded zeros); tables as rec 41.
- ~~Filters were never fixtured~~ — rec 20 continues the TYPE att series; its OUTPUT_TYPE -4 exposed the global unsigned attribute-int decode (Att::int sign-extends by width now).
- ~~Shadows refuse~~ — a live shadow is its database except the header page (ACTIVE_SHADOW + root-name clumplet); fc's restore writes the physical mirror and the engine maintains it.

- ~~A scalar subquery's aggregate describes as BIGINT~~ — closed (`qa/serve-real-aggdescribe.sh`).
- ~~A modifier dropped the SELECT LIST, and a set was not a sort~~ — closed (`qa/serve-real-modifiers.sh`).
- ~~A bare boolean parameter as a whole predicate~~ — closed.
- ~~`WHERE ? IS NULL`, `? LIKE 'o%'`, `? BETWEEN 1 AND 3`, `? IN (1,2)`~~ — closed (`qa/serve-real-paramshapes.sh`).
- ~~A text parameter into a numeric column or filter~~ — closed (`qa/serve-real-textnum.sh`).
- ~~**The per-statement cost at HEAD is 2.92 ms**~~ — closed.
- ~~A second per-statement stall, ~44 ms~~ — closed.
- ~~FRAGMENTED RECORDS ARE NOT ASSEMBLED~~ — closed.
- Fragment assembly in the PATCH paths — closed: `patch_head_in_place` (measured-unreachable guard) and the fragmenting store took DML over fragmented heads (`qa/serve-real-fragstore.sh`).
- ~~The head-in-place rewrite~~ — closed.
- (historical) the push_back_version INCOMPLETE gap — the mechanism note is kept in git history; the write path learned fragments.
- A row that would fragment refused to WRITE — closed by the fragmenting store (`qa/serve-real-fragstore.sh`).
- ~~`STARTING WITH` is not in the predicate parser~~ — closed (`qa/serve-real-starting.sh`).
- ~~`qa/serve-real-index.sh` 346/13 and `viewjoin` 33/3 environment ...~~ — closed (`qa/serve-real-index.sh`).
- ~~fire-crab IGNORES the client's declared output message format~~ — closed (`qa/serve-real-outblr.sh`).
- ~~`EXECUTE PROCEDURE` on an ENGINE-created FB6 procedure fails "no ...~~ — closed.
- Non-zero-but-WRONG statistics — measured and closed as the stale-statistics region (`qa/opt-stale.sh`).
- The OR union's plan spelling and inversion order — done while measuring the stale region (`qa/opt-plans.sh`).
- ~~The `DEFAULT_SELECTIVITY = 0.1` substitution and the stale-statist ...~~ — closed.
- ~~`name` and `alias` are two describe fields, and fire-crab sets bot ...~~ — closed (`qa/serve-real-describe.sh`).
- ~~Describe items 17 (relation), 18 (owner) answer `""`~~ — closed (`qa/serve-real-describe.sh`).
- ~~A generator inside an EXPRESSION~~ — closed.
- ~~Text LITERALS against numeric columns~~ — closed (`qa/serve-real-textnumwhere.sh`).
- ~~A NON-TEXT parameter against a TEXT column / text-column ...~~ — closed (`qa/serve-real-textcolcmp.sh`).
- Transliteration between character sets — the codepage tables took the whole family: decode/store/keys/wire/lengths, five tabled sets, carriers, params, the assignment matrix, case law, PXW_INTL (`qa/serve-real-xlit.sh`, `qa/serve-real-collate.sh`).
- ~~`RETURNING` comes back in a different shape~~ — closed.
- ~~`EXECUTE PROCEDURE` on an engine-created FB6 procedure fails~~ — closed.
- ~~Qualified TABLE/VIEW references still refuse everywhere~~ — closed (`qa/serve-real-qualname.sh`).
- ~~A subquery must be ONE PHYSICAL TABLE~~ — closed (`qa/serve-real-subquery.sh`).
- ~~A non-selectable procedure in FROM answers `[]`~~ — closed (`qa/serve-real-nosuspend.sh`).
- ~~fire-crab's lexer accepts whitespace the engine's does not~~ — closed.
- ~~An IN-SUBQUERY refuses past ~10-100 inner rows~~ — closed.
- ~~`INSERT ... SELECT ... RETURNING` refuses at EXECUTE~~ — closed.
- ~~`UPDATE OR INSERT ... MATCHING ... RETURNING` fails at PREPARE~~ — closed.
- ~~An IDENTITY-column INSERT refuses~~ — closed.
- ~~OVERRIDING SYSTEM|USER VALUE, INSERT DEFAULT VALUES, params in an ...~~ — closed (`qa/serve-real-overriding.sh`).
- ~~The generator-durability class stays recorded~~ — closed (`qa/serve-real-gendurable.sh`).
- ~~A generator DRAWN IN A DML STATEMENT never advances~~ — closed (`qa/serve-real-genwrite.sh`).
- ~~Constraint errors surface as generic 42000 `Dynamic SQL Error` ...~~ — closed.
- ~~Text COLUMN vs numeric side still render-compares~~ — closed.
- ~~A tab in a failing text literal renders RAW in the error argument~~ — closed (`qa/serve-real-textcolcmp.sh`).
- ~~A refusal ships the engine's MESSAGE TEMPLATE at the user~~ — closed (`qa/serve-real-view.sh`).
- ~~`branch_rows` loses a real error on the way out~~ — closed (`qa/serve-real-derived.sh`).
- ~~The strict grammar reaches a VIEW BODY, where the engine does not ...~~ — closed.
- ~~A DML `SET` list's evaluation failure answers 42000 where the engi ...~~ — closed (`qa/serve-real-setexpr.sh`).
- A RAW high byte lost before any error could name it — closed by the attachment-charset param decode (`wire_text_param`) and the column-charset 22018 spelling (`qa/serve-real-textcolcmp.sh`).
- ~~The compare grammar refuses interior blanks the engine accepts~~ — closed (`qa/serve-real-textcolcmp.sh`).
- ~~The lenient literal grammar leaked through a SUBQUERY FOLD, and ...~~ — closed (`qa/serve-real-textcolcmp.sh`).
- ~~`<op> ANY | SOME | ALL (<subquery>)` has no surface at all~~ — closed (`qa/serve-real-subquery.sh`).
- ~~A text→number conversion longer than 52 characters raises the wron ...~~ — closed (`qa/serve-real-textcolcmp.sh`).
- `CAST(? AS <type>)` refused — stale: the cast target is applied to the slot (probed live, `CAST(? AS INTEGER)` binds and answers).
- ~~`CAST('<TAB>2' AS INTEGER)` answers 2 where the engine raises~~ — closed (`qa/serve-real-textcolcmp.sh`).
- `CAST(? AS INTEGER)` refuses outright — same staleness, verified with a text and an integer bind.
- `CAST('2.5' AS INTEGER)` raises where the engine answers 3 — stale: both answer 3 (`qa/serve-real-textcolcmp.sh` runs the ' 2.5 ' row against all five targets).

## The two programmes

### Programme R — the engine's execution shape

Replace textual rewriting with the engine's own structure: a tree of row
sources (`RecordSource`/rsb in `src/jrd/`), built by the planner and
pulled by the fetch.

- **R1 — the tree exists.** *(done)* A `RowSource` with `TableScan`, `Filter` and
  `Sort`, and the simplest plan executing through it. No behaviour
  change; the gates are the proof.
- **R2 — Aggregate** is a node. *(done)* `group_output` and both grouped
  paths build `TableScan → Filter → Aggregate → Sort`; the fold itself
  (`group_rows`) now has exactly ONE caller, the node.
- **R3 — NestedLoopJoin**, inner and outer. *(done)* `join_rows` builds
  a LEFT-DEEP tree instead of folding, so "each step's kind applies to
  everything accumulated so far" is true by construction; the WHERE is a
  `Filter` above the whole join.
- **R4 — derived tables**: `FROM (SELECT ...)`. *(done)* The first
  capability the tree unlocks that the rewriting could not reach: a
  derived table has no name to substitute, so the outer query resolves
  against a synthetic view built from the inner plan's DESCRIBE.
- **R5 — a materialised CTE**. *(done)* A CTE body the inlining cannot
  rewrite is a DERIVED TABLE by another name: `FROM C` becomes
  `FROM (<body>) C`. Grouped, starred and joined bodies all answer now,
  and a grouped PLAN became a row source in the process.
- **R6 — `WITH RECURSIVE`**, a fixpoint over the tree. *(done)* The one
  CTE shape rewriting cannot reach, because the name it resolves is its
  own. Seed once, then evaluate the recursive branch against the last
  level's rows until a round yields nothing. The hierarchy walk — the
  thing recursive CTEs are usually *for* — goes to the ORDINARY join
  planner with the CTE bound as a side, which is R5a paying for itself;
  aggregating the result reuses the grouped join with no parts. Two
  shapes the engine REJECTS were found ANSWERING (two self-references,
  and `ORDER BY` inside a branch), which is the failure direction a
  behaviour gate does not look in unless it is told to.
- **R5a — a derived table as a SIDE of a join.** *(done)* `JoinSide`,
  `JoinPart` and `Plan::Join` now carry a ROW SOURCE instead of a
  relation id, so a side can be a scan or an inner plan. A materialised
  CTE can be a join side too, which was R5's stated refusal.
- **R7 — retire the textual view/CTE rewriting.** *(done)* A VIEW is a
  ROW SOURCE: its stored SELECT is planned on its own and the outer
  query resolves against that plan's DESCRIBE, exactly as over a derived
  table; in a join it is a side, which is R5a again. `expand_view`,
  `expand_view_join`, `qualify_idents`, `replace_qualified_col`,
  `mentions_bare`, `replace_table_ref` and `replace_idents` are **gone** -
  ~870 lines - and with them the WHERE-moving, the name-lending and the
  renaming-through-text they implemented. Three shapes that refused
  because the rewriting could not express them (a view over a JOIN, a
  view under a RIGHT/FULL join, a bare renamed column in a join) now
  answer, and the derived-table and CTE planners became ONE function.
  What is left of the rewriting is a single FROM-ITEM replacement
  (`FROM C` → `FROM (<body>) C`) into that planner. Removing even that
  needs the planner to bind N names at once rather than one; the
  refusals it still carries are listed with it.

- **R8 — the fetch PULLS the tree.** *(the walk exists)* R1-R7 built
  the tree and retired the rewriting it replaced, but every node
  returned a `Vec`, so this programme's own sentence — "built by the
  planner and PULLED BY THE FETCH" — was half true. A node that
  materialises cannot express the engine's laziness, and this project
  has now measured that the laziness is OBSERVABLE, not an
  implementation detail:

  * a raiser three rows into a derived table delivers the two rows
    before it;
  * a SORT materialises its KEY, so a raiser in the key raises before
    any row while one in the PROJECTION does not — `ORDER BY ID DESC`
    delivers row 4 and then raises on row 3, in sorted order;
  * DISTINCT and a distinct UNION block, and the engine answers no rows
    there either.

  `RowSource::for_each` walks the tree handing each row to a sink, with
  a `Flow::Stop` a consumer can end the walk with; `rows()` is a thin
  collecting wrapper over it, so there is ONE traversal to reason about
  rather than two that can drift. What the split makes explicit rather
  than incidental: `TableScan`, `IndexScan`, `Filter` and `Rows` pass
  rows through; `Aggregate` and `Sort` BLOCK, as the engine's do;
  `NestedLoopJoin` still materialises, because its RIGHT/FULL mirror
  needs the whole accumulated side (`join_step`).

  *No behaviour change — the gates are the proof*, which is R1's
  standard and the right one for a step whose value is what it makes
  possible. What it makes possible, in the order it should be taken:

  1. ~~**`FIRST n` stops the scan.**~~ *(done)* `for_each_record_while`
     is the walker that can end - a SIBLING of the existing one rather
     than a signature change, since 23 of its callers are catalog walks
     that do not care - and the `Modified` arm's hand-rolled early exit
     is gone: it used to keep reading the relation and discard the
     rest, which is the right answer at the cost of the scan the engine
     does not do. The filter moved out of that closure into the tree.

     **It also caught a node LYING about which kind it was.**
     `scan_filter_sort` builds a `Sort` unconditionally, so an unsorted
     `FIRST n` went through a node classed as blocking, materialised
     the whole relation, and raised on a row the engine never reaches -
     the one gate check that measures laziness through an error
     (`SELECT FIRST 1 ID FROM TDIRTY WHERE S = 5`). **A sort with no
     keys is not a sort**, and passes rows through. Under the old code
     that distinction was invisible, because everything materialised
     and only the hand-rolled counter made FIRST behave; making the
     split load-bearing is what exposed it.

     *Measured honestly*: wall-clock cannot show the stop at any size
     this box can build - per-statement cost swamps an 80k-row scan,
     and `FIRST 1 WHERE ID > 79999`, which must scan everything, timed
     FASTER than a plain `FIRST 1`. The claim is therefore made by a
     unit test that COUNTS what the sink saw, not by a benchmark.
  2. ~~**`NestedLoopJoin` streams for LEFT and INNER.**~~ *(done)* Both
     kinds read only the outer row in hand, so "concatenating the
     per-row results IS the whole-pass result" - the identity the index
     probe already relied on, now used for the walk itself. RIGHT and
     FULL fall through to the materialising arm: their MIRROR emits the
     unmatched rows of the OTHER side, which is not knowable one outer
     row at a time. Both inner streams are still built at most ONCE,
     lazily, so an unbuildable key cannot cost a scan per outer row.
  3. ~~**Projection at delivery above `Sort`**~~ *(done)* — the
     sorted-raiser residual, and PROBING NARROWED IT from what this
     entry assumed. A plain scan with an outer ORDER BY was ALREADY
     right: that path materialises RECORDS and projects at encode,
     which is the engine's rule arrived at independently. A raiser in
     the sort KEY, and DISTINCT, block on both sides. The one real case
     was a DERIVED TABLE under an outer sort, where fire-crab sorted
     ALREADY-PROJECTED rows and so ran the inner projection for every
     row before the first shipped.

     A sort above a derived table now sorts the BASE RECORDS and runs
     the inner projection at delivery. The rewrite fires only when
     every outer key is a plain FIELD naming a plain inner column, so
     its record `field_id` exists; a key that needs the EXPRESSION
     (`ORDER BY Q` where Q is the raiser) falls through to the blocking
     path, and that is the ENGINE'S behaviour, not a shortfall - it
     must compute the key before sorting too. `qa/serve-real-derived.sh`
     57 → 61 checks and 3 boundaries, 2 DIFF against the pre-fix
     binary, with both controls and the new blocking check green on
     BOTH binaries.

  **R8's published steps are done, and the tree pulls now.** `Aggregate`
  and `Sort` are blocking by nature; everything else streams. The fetch
  itself pulls a plain `Plan::Project` over a full scan through
  `StreamCursor`, producing `want` rows per op_fetch and resuming from a
  `(page, slot)` position rather than materialising the whole cursor - so
  reading the first 200 rows of a 50,000-row result is O(200), not
  O(50,000), and peak memory is O(batch), not O(result).

  And a JOIN streams under `FIRST n` too, RIGHT and FULL included. This was
  two things. First a WRONG ANSWER: `SELECT FIRST 2 B.K, 100/B.W FROM A
  RIGHT JOIN B` raised a divide-by-zero on a row past the limit the engine
  never reaches, every join kind, because the `Modified` path projected
  every joined row before slicing - fixed by walking `join_rowsource`'s
  tree and stopping at `skip + take` with the select list evaluated only
  for a delivered row. Then a slow one: the RIGHT/FULL `for_each` arm now
  STREAMS its matched portion (driver walked lazily, matches pushed, the
  MIRROR - the preserved side's unmatched rows - emitted only after the
  driver is done, exactly `join_step`'s order), and the batch fetch stops
  MATERIALISING a small `FIRST n` (`take <= want`, so it fits one batch and
  cannot deadlock), serving it from the streaming `emit_rows` instead. The
  two together took `FIRST 2` over an 8,000x8,000 nested-loop join from
  ~7 s (the whole 64,000,000-comparison result) to 0.35 s (two driver
  rows). And a LARGER `FIRST n`, past that one batch, no longer
  materialises the whole source either: `branch_rows_res` collects a
  bounded, non-DISTINCT FIRST n by WALKING a streamable inner and stopping
  at `skip + take` (`stream_first_n`) rather than building the inner whole
  and slicing - the same rows in the same order (the walk is what `.rows()`
  collects), so every caller (a subquery, a derived table, an
  `INSERT ... SELECT`, the batch fetch) is unchanged but for the part past
  the limit it no longer builds. So `FIRST n` over the 8,000x8,000 join
  scales with n now, not N: 100 -> 0.4 s, 500 -> 0.8, 2000 -> 2.2, 5000 ->
  5.1 (was ~7.1 for all), INNER/LEFT/RIGHT/FULL alike - and it fixed a
  WRONG ANSWER on the way, `FIRST 250` past a raiser at row 280 having
  materialised into the raise the engine's limit steps over. Pinned across
  the four kinds and the large-n case in `serve-real-jointypes.sh`.

  A `FIRST n` over a SORTED source was the same wrong answer, one step out:
  `SELECT FIRST 2 K, 10/(K-5) FROM T ORDER BY K` raised on `K = 5` where the
  engine orders the rows, cuts to two, and never projects the fifth. The
  SORT is not the PROJECTION - a sort blocks (its whole cursor is read and
  ordered, the engine's too), but the select list is evaluated AFTER the
  cut, so the projection is now lifted past `skip + take` on every path: the
  batch-fetch emit for a small `n`, `stream_first_n` for a large one and for
  a subquery / derived table / CTE / `INSERT ... SELECT`. A NAVIGABLE key
  (a PK, a unique index) walks its index in order and STOPS at the limit -
  no Sort node, nothing materialised; a real sort or a sorted join blocks
  and materialises but projects only the rows kept. It reaches the scan and
  the join, ASC and DESC, at both batch sizes - pinned in the same gate
  (44 checks).

  And a NAVIGATED `FIRST n` now streams its FETCH, not just its projection. It
  walked the index in key order but read every record the range named before
  the limit cut it: `records_for_2pc` returned a whole Vec. Decomposed over
  50,000 rows, the btree walk is 1.4 ms and the page map 0.02 ms, but FETCHING
  all 50,000 records is 10 ms - the retrieval's whole cost, paid to answer ten
  rows. So the 2PC walk streams: `for_each_2pc` fetches ONE record at a time
  and STOPS when the sink does (`records_for_2pc` is a thin collecting wrapper
  for the callers that still materialise - `rows`, a subquery, a COUNT). A
  navigated or bounded `FIRST n` reads ~n records now: `FIRST 10` over a
  50,000-row PK went 19 ms -> 8.4, `FIRST 250` -> 8.6, both near the 6.2 ms
  unordered baseline - and it SCALES, the fetch-all grew with the row count,
  the walk and map only with the page count.

  Then the WALK streamed too, closing the last O(candidates) cost: `for_each_
  2pc` had still built the whole candidate list (`lookup_range` -> a Vec of
  every entry the range names) before the streamed fetch read ~n of them, an
  overhead that grew with the relation - a `FIRST 10` cost 2.2 ms extra at
  50,000 rows and 9.6 at 200,000, to read ten entries. So `btr::for_each_in_
  range` hands each entry to a callback that STOPS the walk (`lookup_range` is
  that, collected), and a NAVIGATED retrieval - one pick whose key order IS the
  answer, no record-number sort to force the list - drives it, fetching and
  stopping as it walks. A navigated `FIRST n` is flat in the table size now, at
  the unordered baseline: `FIRST 10` over a PK 8.6 -> 6.0 ms at 50,000 rows,
  15.8 -> 6.2 at 200,000 (baseline 6.0), `FIRST 250` at 200,000 is 6.4. Truly
  O(n). A non-navigating retrieval still collects (it sorts by record number
  before it fetches) - the BOUNDED case, whose candidates are the band, not the
  relation.

  And a SORT ABOVE A JOIN is not always a sort: when the ORDER BY is the
  DRIVER's own key, the engine navigates the driver's index for it - its
  `A ORDER RDB$PRIMARY1` - rather than materialising the join to sort. It had
  to, and fire-crab did not: `FIRST 10 ... FROM A JOIN B ... ORDER BY A.<pk>`
  cost 1.78 s - the whole 4,000-row join built and ordered - where the
  unsorted `FIRST 10` was 15 ms, because the driver navigated "by nothing" and
  a Sort hung above the join. Now, when the ORDER BY is a SINGLE ascending
  plain-field key on the driver (side 0, offset 0, so the key's field IS the
  driver record field id), every step is INNER or LEFT (a RIGHT/FULL mirror
  emits the other side's unmatched rows out of driver order), the driver is
  still a plain scan (a WHERE band already keyed it beats navigation), and the
  driver's table has a navigable index on that field, the driver base becomes
  a navigated IndexScan and the `order_by` is CLEARED: the join emits each
  driver row's matches in key order, so the result is already sorted and every
  unsorted-join path - the streaming FIRST n included - just works. 1.78 s ->
  15 ms, INNER and LEFT alike. What still materialises: a `DISTINCT` set (it
  compares what the select list PRODUCES, so it must project whole before it
  dedups), an aggregate, a sort whose key is NOT the driver's (a real sort, on
  the engine too), and the RIGHT/FULL mirror ONLY when a consumer reads into
  it - all fundamental, not a shortfall, and blocking on the engine too. The
  wire cursor is the engine's iterator now, a lazy PUSH with `Flow::Stop` for a
  scan or a `FIRST n` (of any size, sorted or not, over a scan or a join) that
  reads only the rows the limit keeps, a materialising PUSH for the blocking
  rest - and even there the projection runs only over those rows.

  And the JOIN itself PROBES its inner index for an INNER pair now, not just a
  LEFT one. `build_join_probe` was LEFT-only, so `SELECT A.ID FROM A JOIN B ON
  A.K=B.K` over 4,000 x 4,000 did the whole O(N x M) nested-loop scan - 1.79 s,
  every pair compared - where the engine plans `B INDEX RDB$PRIMARY` and reads
  ~one inner row per driver. (A COUNT of the same join was already 190 ms on a
  different path, so the cost hid until a real projection asked for the rows.)
  LEFT and INNER both drive the outer one accumulated row at a time, so the
  per-driver probe the LEFT path used concatenates to the whole INNER result
  too - `join_step` just DROPS an unmatched INNER driver where LEFT pads it -
  and the driver stays the syntactic left, so the inner's record-order matches
  do not move the row order the scan gave. 1.79 s -> 70 ms. The engine HASHes
  these (this server has no hash join), but a nested-loop index probe is its
  best plan and far past the scan it did; RIGHT/FULL still decline (the mirror
  needs the whole other side). That closes the join residual the
  driver-navigation slice named: the FULL sort-less join is the PROBE now, not
  a scan.

  And when the inner has NO index, the join HASHes it rather than scanning it
  whole per driver - the engine's own `HASH (A NATURAL, B NATURAL)` plan.
  `SELECT A.ID FROM A JOIN B ON A.K=B.K` with an unindexed `B.K` cost 466 ms
  over 2,000 x 2,000, every pair compared; now the inner is grouped ONCE by the
  key and each driver reads its bucket - O(N + M) - for 50 ms, FLAT in the row
  count. `build_join_probe` carries its keys even with no index (its `index` is
  optional now), so the join reaches the scan fallback and groups the inner by
  `build_join_key_hash` there. An INTEGER inner at scale 0 is keyed by its
  `i128` (numeric equality) and a TEXT inner by its trailing-space-TRIMMED
  string - exactly how `value_cmp` compares those, so two rows share a bucket
  iff the ON holds (CHAR padding and a VARCHAR-against-a-CHAR fold the same).
  A VARCHAR equi-join that cost 650 ms drops to 50 ms too. And a SCALED numeric
  is keyed by its digits with TRAILING ZEROS STRIPPED - a scale-independent
  canonical form, so `1.50` (150 @ -2) and `1.5` (15 @ -1) land in the one
  bucket `value_cmp` aligns them into; a NUMERIC(9,2) equi-join drops 516 ms ->
  50. A date inner, or an OR of keys, still scans and the ON decides. The
  bucket carries its key FAMILY, and a driver only looks up a bucket of its OWN
  family: `value_cmp` compares a MISMATCHED pair by RENDERED text (an int
  against a text, or an i64-backed scaled against an i128-backed one of a
  different width - it only ALIGNS numerics of the SAME width), which a bucket
  cannot reproduce, so such a pair falls to the scan and the ON renders. The
  family is split by storage width for exactly that reason, and
  `build_join_probe` refuses the hash key up front when the outer's family is
  known and differs. The bucket is filled IN SCAN ORDER, so a driver's matches
  come back exactly as the whole-inner scan gave them: the row order does not
  move. And a TEMPORAL key hashes now as well: a DATE, TIME or TIMESTAMP by its
  stored `(day, time)` fields, an unindexed DATE equi-join dropping 483 ms ->
  50. DATE and TIMESTAMP are ONE family - `value_cmp` compares a DATE against a
  TIMESTAMP as MIDNIGHT, so a DATE keys as `(day, 0)` and meets a zero-time
  TIMESTAMP; TIME is its own, and a WITH-TIME-ZONE value keys by its UTC instant
  (its own family too, since `value_cmp` renders across the temporal kinds).
  And a DECFLOAT key hashes now, the LAST family: `join_key` decodes it and
  keys by `(sign, coefficient, exponent)` with the coefficient's trailing zeros
  stripped - the canonical `decfloat::cmp`'s COHORT comparison sees, so `1.0`
  and `1.00` share it and every zero maps to one; an unindexed DECFLOAT equi-
  join drops 716 ms -> 50. DECFLOAT(16) and DECFLOAT(34) are one family (both
  promote to a decimal128), an Infinity or NaN scans (never keys an index).
  LEFT and INNER alike; RIGHT/FULL still scan. So the equi-join FAMILIES are
  closed - an unindexed INT, TEXT, scaled, temporal or DECFLOAT join all HASH,
  the engine's plan - and the only O(N x M) join left is a THETA join, which
  the engine loops too.

  A THETA join (a non-equality ON) cannot be hashed - but MEASURED, a `FIRST n`
  over one already STREAMS: the driver walks and STOPS, the inner scanned only
  for the drivers a delivered row needs (`FIRST 1` of an 8,000 x 8,000 `>` join
  is 50 ms, the full COUNT 400), and the projection is held past the limit, so
  a raiser at a driver the limit steps over never runs - probed identical to
  the engine over `>`, `<>`, and a LEFT theta, now pinned in
  `serve-real-jointypes.sh`. What did NOT stream was a THETA join fetched
  WHOLE with no limit: the batch fetch materialised its every combined row
  before draining batches, where the engine produces them on demand.

  **DONE — the resumable JOIN cursor.** `JoinCursor` is the StreamCursor a
  scan already has, over a join's `(driver, match)` walk: it materialises
  the two SIDES (O(N + M)) and produces the product a DRIVER ROW AT A TIME,
  resuming from `(driver index, that driver's output rows, index into them)`.
  Reading the first 100 rows of an 8M-pair theta join was 72,162 ms (all 8M
  built first); it is now 25 ms, and peak memory is O(batch), not O(N x M).
  It opens for a bare single-part LEFT/INNER join with no ORDER BY and no
  live index probe on the inner - so the inner is always materialised whole
  (a theta join scans it, an unindexed equi-join hashes it), which is exactly
  the shape whose OUTPUT the fallback built in full; every other join keeps
  the materialising path. The per-driver step reuses `join_step` /
  `join_scan_rows` and the top WHERE `Filter` unchanged, so the rows and
  order are byte-identical to the materialising path. GOTCHA: an exhausted
  join cursor is KEPT in the fetch map (buffers freed), not removed - a
  client's fetch-until-empty loop sends one op_fetch past the last row, and a
  removed cursor would be RE-OPENED and re-deliver the whole join (a
  materialised `Plan::Rows` survives the same extra fetch because it was
  drained to empty in place). Pinned by `serve-real-jointypes.sh` +4 (the
  whole theta / hashed-equi / LEFT-theta / WHERE-above join, no FIRST) and by
  `serve-real-leftjoinindex.sh`'s existing whole-fetch `same3` (the check that
  caught the double-emission). RIGHT/FULL, a multi-table chain, an ORDER BY
  or an indexed inner keep the materialising path.

  **DONE — the RIGHT/FULL resumable mirror.** The cursor now also streams a
  RIGHT or FULL join, in the same TWO PHASES the streaming join arm uses: a
  DRIVER PHASE that emits each driver row's matches (and, for FULL, its own
  padded unmatched row) while marking which inner rows were hit, then a
  MIRROR PHASE that emits the inner rows nothing matched, padded on the left.
  The mirror depends on the WHOLE driver pass, so it is a second resume point
  the cursor reaches only once the driver index exhausts - `right_matched` is
  final by then. The per-phase step reproduces the arm's inline matching /
  partnerless-ON raise (gated by the one-side WHERE) / FULL-keeps-RIGHT-drops
  rule exactly, then the top WHERE `Filter` and the projection, so the rows
  and order are byte-identical to the materialising path. Reading the first
  100 rows of the matched portion of a RIGHT theta join over 4,000 x 4,000
  drops 66,770 ms -> 19 ms. Pinned by `serve-real-jointypes.sh` +5 (the whole
  RIGHT/FULL equi and theta join, and a WHERE above one). Only a multi-table
  chain, an ORDER BY or an indexed inner now keep the materialising path -
  every single-part unbounded plain join of millions of rows streams.

  **DONE — the chain folds through the cursor.** The cursor now streams a
  MULTI-PART chain too: one `PartData` per join (its side decoded once at
  open, plus the unindexed-equi key hash), and each base row is FOLDED
  through every part - a row of A expands into its B-matches, each of those
  into its C-matches - so the cursor produces one base row's whole
  contribution to the output and NEVER the intermediate `(A join B)`, whose
  materialisation is the O(product) the fallback pays. This is sound because
  each base row's expansion is an independent slice of the output (the
  concatenation identity `join_step` already relies on within a step), so
  concatenating the slices in base order IS the whole join, in the order the
  materialising path produces. Every part but the LAST must be LEFT or INNER
  (a mirror in a non-terminal part emits rows that belong to no base row and
  would break the fold); the last part may be RIGHT or FULL - its mirror is
  still the cursor's second phase, walking the LAST side's unmatched rows
  padded out to `mirror_left_width` (the base plus every inner part's width).
  No side may carry a live index probe, as before. Reading the first 100 rows
  of an 8M-pair three-table theta chain (4,000 x 4,000 x 1) took 5.3-6.1 s;
  it now answers at the wire round-trip floor (~330 ms attach-to-row, the
  same as `SELECT 1` - the server-side join work is gone from the fetch).
  Pinned by `serve-real-joinchain.sh` +5 (a three-table theta chain, an
  unindexed-equi-then-theta chain, a LEFT-LEFT chain's padding, a chain
  ENDING in a RIGHT - matches then the mirror - and a WHERE above the whole
  chain, all multiset-compared against the engine). Only an ORDER BY or an
  indexed inner keep the materialising path now.

  **DONE — the INDEXED side streams: the probe walks the frozen image.** The
  cursor declined any part with a live index probe, because a per-driver
  index read against the live database cannot be repeated consistently
  across fetches - the pages move under the cursor. The answer was already
  in the file: freeze the page image at open, exactly as `StreamCursor`
  does, and walk the index THERE, rebuilding the visibility view over that
  image per batch. `for_each_2pc` was split: the walk itself
  (`for_each_2pc_on`) now takes the image, the view and the sequence -> page
  map as arguments, and `for_each_2pc` is the wrapper that derives them from
  the live database - so a probed part derives them ONCE at open
  (`ProbedSide`) and every fetch walks the same pages its materialised
  sides came from. Per accumulated row the probe still bands the index
  (`JoinProbe::band`, whose catalog reads are DDL-stable) and the ON still
  decides over the fetched candidates; a NULL driver key names nothing
  (`Band::Nothing`), and a key the band cannot spell - a scaled NUMERIC
  against an integer PK - falls back to the WHOLE side, read once lazily
  from the same frozen image (`Band::Scan`), so the answer is the scan's
  wherever the band declines. Probed sides must be PLAIN TABLES (a
  flattened view or derived side keeps the materialising path). Reading the
  first 100 rows of a 4M-row indexed equi-join (4,000 drivers x 1,000
  matches each) took 2.7-2.8 s of whole-output materialisation; it now
  answers at the wire round-trip floor (~330 ms attach-to-row, the same as
  `SELECT 1`), and the server-side cost - which grew linearly with the
  output (~270 ms at 400k rows, ~2.4 s at 4M) - is gone from the fetch.
  Pinned by `serve-real-jointypes.sh` +4 (the whole indexed equi-join over
  all 300 drivers, an indexed LEFT join's padding, a NULL and an
  unspellable scaled driver key through the streamed probe, and a WHERE
  above one) and `serve-real-joinchain.sh` +1 (an indexed-then-theta
  chain); `serve-real-leftjoinindex.sh`'s 169 checks - whose whole-fetch
  `same3` probes all route through the cursor now - hold unchanged. Only an
  ORDER BY (whose sort must see every combined row, as the engine's does)
  keeps the materialising path.

  **DONE — the boolean grammar closes: truth tests, literals, IS DISTINCT
  FROM.** Three families the condition-as-a-value grammar (`RawCond`, the
  one the select list, `IIF` and a searched `CASE WHEN` share) refused:
  `x IS [NOT] TRUE/FALSE/UNKNOWN`, a bare boolean LITERAL as a condition
  operand (`B AND TRUE` - `B AND (ID > 1)` already worked), and
  `x IS [NOT] DISTINCT FROM y`. All three desugar at parse into the
  Kleene shapes the pipeline already evaluates, with the TWO-valued
  results a projected value needs: `x IS TRUE` is `x IS NOT NULL AND
  x = TRUE` (false AND UNKNOWN = false, so a NULL operand answers
  `<false>`, never `<null>` - probed), `x IS NOT TRUE` is `x IS NULL OR
  x = FALSE`; NOT-DISTINCT is `(a IS NULL AND b IS NULL) OR (a IS NOT
  NULL AND b IS NOT NULL AND a = b)` - every arm decided whatever is
  NULL - and DISTINCT its NOT. The `= TRUE/FALSE` leaf doubles as the
  TYPE GATE (`cmp_sides` refuses a non-boolean side, as the engine's
  "Invalid usage of boolean expression" does); `IS [NOT] UNKNOWN` alone
  needs a carried variant (`RawCond::IsUnknown`), because it is the NULL
  test with a boolean-ONLY operand - `ID IS UNKNOWN` must refuse at
  prepare where `ID IS NULL` answers, and only resolution knows the
  type. The literal fix is one arm each in the two bare-boolean rules
  (`RawExpr::Bool` beside the bare column, select-list and WHERE), so
  `WHERE TRUE` / `WHERE FL AND TRUE` answer too. GOTCHA that hid the
  whole DISTINCT family: the STATEMENT SPLITTER took the first
  depth-0 FROM as the clause FROM - and `IS DISTINCT FROM` embeds one
  with no parentheses to hide in (SUBSTRING/TRIM/EXTRACT are all
  parenthesised), so `SELECT S IS DISTINCT FROM 'x' FROM T` split at
  the predicate's FROM and refused; a FROM whose preceding word is
  DISTINCT is now skipped (a legitimate clause FROM is never preceded
  by the bare keyword). Pinned by `serve-real-boolvalue.sh` +23
  (51 -> 74): the truth-test matrix over a NULL operand, the literal
  operands under the Kleene fold, the DISTINCT family including
  NULL-vs-NULL and both-columns, IIF/CASE composition, `SELECT
  DISTINCT` still the modifier, `WHERE TRUE/FALSE`, and the two
  boolean-only-operand refusals (engine-probed SQLSTATE 22000).

  **DONE — and UNKNOWN, the third boolean literal.** `UNKNOWN` (and a
  bare `NULL`, which the engine treats identically as a condition -
  probed: `CASE WHEN NULL` and `CASE WHEN UNKNOWN` both take the ELSE,
  `WHERE NULL` and `WHERE UNKNOWN` both keep no row) is the constant
  UNKNOWN condition. Both lex to the same NULL literal, so one arm in
  each bare-boolean rule covers both: the leaf is spelled `NULL = TRUE`,
  which the Cmp evaluator already answers as UNKNOWN per row - no new
  machinery. `NULL IS UNKNOWN` passes the boolean-only operand gate as
  the untyped literal (TRUE on the engine, probed). `B AND UNKNOWN` /
  `B OR UNKNOWN` now show the Kleene fold against a literal UNKNOWN
  operand, projected and in the WHERE. `serve-real-boolvalue.sh` +8
  (74 -> 82).

  ~~The next thing worth doing here is a boundary the gates already pin:
  the engine raises a blocking node's error at OPEN, where this server
  announces the result set and raises at the first FETCH.~~
  **REFUTED BY MEASUREMENT — that boundary was an artefact of comparing
  two different TRANSPORTS.** Asked over the SAME transport fire-crab
  speaks, the engine does exactly what this server does. `SELECT DISTINCT
  CAST(S AS INTEGER) FROM TR` with one unconvertible row:

  | attachment | `MON$REMOTE_PROTOCOL` | what isql shows |
  |---|---|---|
  | bare path (embedded) | `<null>` | the error, no result set announced — **raised at OPEN** |
  | `localhost/3050:` (remote) | `TCPv4` | a blank line, then the error — **announced, raised at FETCH** |
  | fire-crab, `127.0.0.1/<port>:` | `TCPv4` | a blank line, then the error — identical |

  The engine's own remote layer does not run a blocking node at
  `op_execute`; the cursor materialises on the first `op_fetch`, and the
  error arrives there. Since fire-crab speaks only the remote protocol,
  there is nothing here to converge on. **What this leaves is a GATE
  rule, and it is the fourth time this suite has measured its own
  environment** (after `NODE_PATH` drift, isql `AUTODDL` and
  `FORCE_COLOR`): *a differential must hold the transport fixed*. Handing
  isql a bare FILE PATH for the engine side and a `host/port:` string for
  fire-crab is not one difference but two, and the second one talks.
  `qa/serve-real-modifiers.sh` was doing exactly that and now reaches
  both servers over TCP.

### Programme W — wire the converted subsystems in

Each of these is "the model exists and is right; make the server use
it", which is a different risk profile from converting something new:
the oracle already exists, so the gate is *behaviour must not change*
plus *the subsystem is now on the path*.

- ~~**The optimizer's cost model has three further known gaps**~~ —
  *closed, on fresh statistics.* The three were: `loop_cost` charged the
  index SCAN term against the table's cardinality where the engine uses
  the index's PAGE count (Retrieval.cpp:186-194), so a keyed loop looked
  roughly twice its true cost; the driver's own natural scan was not
  charged at position 0 (InnerJoin.cpp:323); and only one hash arrangement
  was costed where the engine takes the minimum over all of them. All
  three are in the crate now (`index_pages` is the page-count term,
  `loop_cost` charges the row term ONCE through it, `hash_cost` carries
  the `MINIMUM_CARDINALITY` cap on a unique hashed side), together with
  the `DEFAULT_SELECTIVITY = 0.1` substitution and the removal of the
  stale-statistics guard — both fresh and stale 169-cell grids score
  169/169 with zero refusals (opt slices 7-9 + the selectivity, grid-hole
  and guard fixes). The residual is the **stale region** (statistics
  non-zero but WRONG): still unmeasured, because it needs its own fixture
  family (load, `SET STATISTICS`, then grow the table) — recorded under
  "Measured gaps" above, not here.

- **W1 — index-driven retrieval.** *(equality, ranges, compound prefixes, text keys, the fold's input, ORDER BY navigation, the FK check and DML targets done)* The first
  slice that put a converted subsystem on the running server's path.
  `crates/wire/Cargo.toml` now depends on `fire-crab-opt`, and **opt
  makes the choice**: `plan_query` is asked about the statement, and only
  when it answers `Access::Index` does the retrieval descend a tree
  (`btr::lookup_key`, new) instead of scanning. The predicate above the
  leaf is unchanged, so an index narrows what is READ and never what is
  ANSWERED.
  - Scope so far: a single-segment index on the projection's retrieval —
    equality and RANGES (`>`, `>=`, `<`, `<=`, `BETWEEN`), multiple
    bounds on one column (a conjunction narrows), any exact-numeric
    SCALE, and **DESCENDING indexes, whose arithmetic is established
    now**. It was read off the engine's own index rather than derived:
    dumping an ascending and a descending index over the same values
    gives `1 → bff0 / 400f`, `2 → c0 / 3f`, `'ab' → 6162 / 9e9d`,
    `'abc' → 616263 / 9e9d9c`, so **the descending key is the bitwise
    COMPLEMENT of the ascending one**, taken after the ascending
    zero-chop and not re-chopped — which is what `build_index_key`
    already wrote. Two things follow it: the BOUNDS SWAP (a larger value
    is a smaller key), and the COMPARISON is not `memcmp` — a shorter
    key pads with **0xFF**, so a key that is a byte PREFIX of another
    sorts AFTER it. That second rule is BOTH recorded misses, and the
    integer one is the same shape as the text one for a reason that was
    not obvious: a zero-chopped key like 2's `c0` IS a prefix of 3's
    `c008`. The rule itself is `btw::key_cmp_desc` — the write side had
    it already, and `lookup_range` asks for it rather than restating it.
    Compound descending indexes still scan (the prefix band's successor
    arithmetic is computed in ascending key space, and one rule for two
    directions is how a missed row ships). Both the PROJECTION's
    retrieval and the
    FOLD's - a grouped query and the prepare-time aggregate fast path
    read their candidates through the same leaf. A key this cannot
    build byte-exactly would be a MISSED ROW rather than a refusal,
    which is why the mechanics are narrow and everything else scans.
  - **The map of what is left, measured rather than remembered.** The
    original entry said "30 `for_each_record` sites"; there are **21**,
    and most are CATALOG walks (`RDB$RELATIONS`, `RDB$FIELDS`,
    `RDB$RELATION_FIELDS`, the FK catalog) which are not query retrieval
    at all. The retrieval sites that matter are four, and two of them
    the roadmap had never named:
    - **`fk_partner_has`** — *(done)* was a FULL SCAN of the referenced
      relation **per written row**. It drives the parent's unique index
      now; the whole key is known, so a compound index is a point lookup
      rather than a prefix range. A text key still scans.
    - **`collect_dml_targets`** — *(done)* `UPDATE`/`DELETE ... WHERE`
      retrieves through the index now. It had its own scan rather than
      going through `for_each_record`, which is why it never appeared in
      the count.
    - ~~`eval_subquery` / `build_correlated_lookup` — a subquery's own
      retrieval~~ *(done)*: the inner residual WHERE drives
      `choose_index` through a reconstructed de-aliased statement
      (fcopt refuses aliased FROM — converting that would delete the
      reconstruction); the fold model stays, because the engine itself
      hash-joins over an inner NATURAL scan for the plain correlated
      semi-join (probed plans in the gate). Still open in this family:
      the OUTER query of a folded subquery scans (`plan_query_inner`
      hands the ORIGINAL text to `choose_index` and fcopt refuses
      anything containing `(SELECT`; `plan_correlated_select`
      hard-codes `index: None` on its outer Project) — hand the FOLDED
      token text to that call. *(done)*: the WHERE-side fold is
      hoisted and rendered into a reconstructed statement at all four
      choose_index sites and both DeferredAccess constructions; the
      select-list fold's re-plan already indexed (verified, pinned);
      plan_correlated_select's outer takes index/defer now; and
      plan_update/plan_delete's choose_index calls — DEAD WEIGHT since
      W1 began (fcopt: "not a SELECT") — get the same reconstruction
      with their own "[srv] dml index:" trace. Activating the DML walk
      exposed a LATENT MISSED-WRITE bug: dml_targets_at claimed the
      recno BEFORE the staleness check, so a band covering a moved
      key's old+new entries skipped the current one — the engine
      writes the row, fc didn't. Fixed per the for_each_candidate law
      (verify only when the walk IS the order; the current image
      decides; recno dedup stops the double write). Follow-ups
      recorded: param'd DML WHERE needs a defer field on the DML
      plans; temporal/double scalar folds arrive as Tok::FnExpr
      (unrenderable → outer scan); IN-subquery outers deliberately
      stay NATURAL (the engine hashes there — model pins in the
      gate).
    - **the JOIN's inner side — ADJUDICATED against the engine's own
      plans, and it is TWO items, not one.** `SET PLANONLY ON` over a
      fixture with an indexed inner column (P 200 rows, C 2000 rows
      with a non-unique index on the FK, Q 2000 rows unindexed):

      *INNER, comma, self, three-table — DO NOT CONVERT.* The engine
      HASHes every inner-join shape fire-crab can reach: `Q ⋈ P` on a
      unique PK is `PLAN HASH (Q NATURAL, P NATURAL)`, so is the
      self-join, so is the comma spelling, and the three-table INNER
      hashes its first pair. In the ONE inner shape that does say JOIN
      (`C ⋈ P`) the engine drives the 200-row side and indexes the
      2000-row one — the DRIVER IS SWAPPED relative to fire-crab's
      left-deep fold, which cannot reproduce it without moving row
      order. Converting these would model a plan the engine does not
      have; the correlated-subquery precedent applies verbatim. **A
      pin, not code.**

      *A GROUP BY over a LEFT join keys its inner side ALREADY* — a
      `Plan::JoinGroup` routes through the SAME `base`+`parts`+`join_rows`
      a plain `Plan::Join` does, so the inner probe fires under the fold
      exactly as without it (the driver scans in both). Measured, not
      assumed: `qa/serve-real-leftjoinindex.sh` now pins a grouped join
      and a global aggregate over the join as `join_indexed`, each
      `FC_NO_INDEX`-twinned. What a grouped join lacks relative to a
      single-relation `Plan::Group` is that group's scalar `index`/`defer`
      field — but it needs none, because its retrieval IS the join tree,
      whose only indexed leaf is the inner probe.

      *The DRIVER index — its EQUALITY half is now ON.* A WHERE
      constraining ONLY the driver keys the outer by its own index, as the
      engine does (probed: `A LEFT JOIN B … WHERE A.col = v` is `PLAN JOIN
      (A INDEX(…), B …)`). The feared row-order coupling turned out inert
      for equality: the equal-key band is recno-ordered on both sides, and
      a scan-filter of `col = v` already yields that same recno order, so
      the driver index CHANGES WHICH ROWS ARE READ, NOT THEIR ORDER — the
      unordered differential holds. `plan_join_bound` swaps `sides[0].src`
      to an `IndexScan` when the WHERE is a single-group (AND) predicate
      over the driver alone with a bare-spellable equality conjunct
      (`choose_index` off the real filter, a bare `SELECT 1 … = 0`
      sentinel for fcopt's blessing); an OR, a range, an aliased driver or
      a mixed WHERE all decline to the scan. `base = sides[0].src` so a
      grouped join inherits it for free. `qa/serve-real-leftjoinindex.sh`
      gates it (`driver_indexed`, unique + non-unique + unordered +
      under-GROUP-BY), `FC_NO_INDEX`-twinned.

      *And a PARAMETERISED driver WHERE defers it* — `Plan::Join` and
      `Plan::JoinGroup` grew a `defer` field for the driver's band, built
      at prepare when the equality is a `?`, and `resolve_driver_base`
      turns `base` from a `TableScan` into an `IndexScan` at EXECUTE from
      the bound predicate before `join_rows` runs. No batch pre-resolve is
      needed (unlike a bare `Plan::Group`): the join's materialisation
      goes through the emit arm that now resolves the driver. A `pdriver`
      twin drives node-bound `WHERE driver.col = ?` (equality, non-unique,
      and under a GROUP BY), each answering the engine's rows with the
      driver band built at execute.

      *And the RANGE driver is ON too — the feared row-order coupling was
      a MISREADING of the engine.* An index range scan does NOT return key
      order: the engine fetches through a record BITMAP (recno order), and
      fire-crab through `records_for_2pc`'s acceptance (recno order too) -
      probed side by side on a column whose storage order differs from its
      key order, both answer identically. A plain scan is recno order as
      well, so keying a RANGE driver changes WHICH rows are read, never
      their order, WHATEVER access the two sides pick - there is no
      cost-agreement to get right. So the driver injection keys `>`, `>=`,
      `<`, `<=` and BETWEEN as well as `=` (the `= 0` sentinel still
      blesses - equality is always selective - and `pick_for_terms` builds
      the real range band off the true filter); a param range defers like
      a param equality. Gated unordered, literal and parameterised. **The
      driver index is closed** for every equality and range shape.

      *LEFT — the slice is ON.* A LEFT JOIN never hashes. In every
      probe the engine's plan IS fire-crab's execution tree: driver =
      the syntactic left, inner = the syntactic right, `INDEX` on the
      inner's ON column when one exists (unique or not, and for `>` as
      well as `=`), NATURAL when none does, chains staying left-deep in
      SQL order with every inner indexed, and a view or derived inner
      FLATTENED rather than materialised. Two boundaries decide the
      scope: a WHERE naming the inner side FLIPS the driver (back to
      the inner-join shape, so out of scope), and the smallest honest
      first slice is a two-table `A LEFT JOIN B ON B.<col> = A.<col>`
      over plain relations with a single conjunctive equality and an
      ascending single-segment index `pick_for_terms` already keys —
      probe once per outer row, fall back to today's materialised inner
      whenever the band cannot be built. Obligations are the W1 standard
      ones (candidates are not answers, the fetched record must still
      carry the entry's key, dedup across bands, a NULL inner key, and
      the padded row must still be emitted — the last of which is why
      the partnerless-ON wrong answer above had to be fixed BEFORE this
      slice could be gated).

      *Slice A is DONE.* `JoinPart` now carries a `JoinProbe`;
      `build_join_probe` gates on LEFT + plain relation + one DNF
      branch + exactly one boundary column-equality + a bare-spellable
      table and column + a single-band blessing from `choose_index`
      over the reconstructed `SELECT 1 FROM <t> WHERE <c> = 0`, and the
      `NestedLoopJoin` arm calls `join_step` with a ONE-ROW accumulated
      side per outer row so the padding, the partnerless ON evaluation
      and the row order stay decided where they were.
      `qa/serve-real-leftjoinindex.sh` (114 checks) gates it, moved keys
      and all; the LEFT CHAIN came free, because the probe is decided
      per part off `sides[k+1].offset`, and the engine plans that chain
      left-deep with both inners indexed. Measured on C 2000 ⋈ BIG
      10000: 2.96 s → 0.39 s wall (engine 0.04 s). Two follow-ups
      recorded: (a) `records_for` rebuilds `page_sequence_map` per
      call, so a probe pays it once per outer row — hoist it behind the
      same function when it starts to dominate; (b) a WHERE naming the
      inner side still probes here, because this executor's tree is
      fixed by the SQL and cannot reproduce the engine's driver flip —
      the rows are the engine's, only the plan shape diverges, and it
      diverged that way before the probe too.

      *The refute pass (265 probes) confirmed the rows and falsified a
      SENTENCE.* Moved keys, keys at every type rim, all-NULL inner
      keys, MVCC, an index built after a DROP COLUMN, the join inside a
      subquery, a CTE and a view body — the row sets held everywhere,
      and the INNER/comma/self pins stayed unprobed. What did not hold
      is W1's usual phrasing, "an index narrows what is READ, never
      what is ANSWERED": an ON that RAISES is value-gated by the band,
      so `ONEN LEFT JOIN RZ ON RZ.K = O.K AND RZ.T > 0` answers the
      padded row under the probe and raises 22018 under `FC_NO_INDEX=1`.
      **The probe is the ENGINE'S answer** — the engine indexes that
      inner side too — so the invariant was reworded (…*and with it
      WHICH ON EVALUATIONS HAPPEN*…) rather than the code changed. It
      is the first place in W1 where the two retrieval paths of the
      same server legitimately differ, and the FC_NO_INDEX twin is an
      equivalence oracle only for non-raising ONs from here on.

      *And it measured the gap, which is the shape of Slice B*: SEVEN
      inner sides the engine INDEXES and this probe declined — **all
      closed now**: the scaled-NUMERIC keys closed `NUMERIC(9,2)` and the
      descending arithmetic closed the DESCENDING index, both of them
      OUTSIDE the join, because neither refusal was ever about the join
      (`pick_for_terms` declined every scaled column and every
      descending one, so plain `WHERE` retrievals scanned too); the
      **expression in the ON** (`RZ.K = O.K + 0`) closed INSIDE it — the
      inner side stays a bare indexable column, and the outer side is
      now any expression over the accumulated row, evaluated per driving
      row to the value the band probes with; and an **OR in the ON**
      closed with it — `JoinProbe` carries ONE key per DNF branch (a
      per-row outer expression, or a constant like the `0` in `PAR.K =
      CHI.K OR PAR.K = 0`), and the per-outer-row band is their UNION,
      deduplicated on acceptance by `records_for_2pc` exactly as the
      projection's OR already was; every branch must be servable, or a
      partial union would miss rows and the whole probe scans; and a
      **VIEW or DERIVED inner** that is a plain projection of ONE base
      table closed too — the engine FLATTENS it (its rows ARE the
      table's), so `build_flatten` keys the base relation through an
      output-column-to-base-field map off the inner `Plan::Project`,
      declining any side carrying a WHERE, DISTINCT, aggregate or window
      the flatten would silently drop; and the **bitmap AND** of two
      indexes closed — two ON equalities on two indexed columns, where
      the probe bands on ONE and lets the ON re-check the other, the
      single-column band being a SUPERSET of the conjunction's matches
      ("candidates, not answers" again), so the rows are the engine's and
      only the plan (a residual filter where the engine intersects two
      bitmaps) differs; and the last, a **`NUMERIC(38,0)` INT128 inner**
      (an `IDX_BCD` key), closed by opening `pick_for_terms`' two type
      gates — the ods `index_key` IDX_BCD arm ALREADY took an i64-range
      value AS `i128`, so the retrieval band builds the SAME bytes the
      write path wrote, and a value too wide for `i64` never becomes an
      `Rhs` in the first place, so it scans rather than mis-keying. (The
      cross-cutting `Rhs`-carries-`i128` change is only for a >`i64`
      LITERAL, closed next; the INDEX itself needed no new
      representation.) **Slice B is closed** —
      `qa/serve-real-leftjoinindex.sh` is 139 checks, every inner shape
      the engine keys now probed, with a `FC_NO_INDEX` twin proving each
      answers the same scanned.

  - **The >`i64` INTEGER LITERAL** — *(done)*, and it was NOT the
      113-site widening the entry below feared. A literal wider than
      `i64` (a `NUMERIC(38,0)` magnitude, up to 39 digits) was REFUSED
      at the tokenizer (`.parse::<i64>().ok()?`); now the tokenizer tries
      `i64` then `i128`, carrying a `Tok::Int128` → `Rhs::Int128` that
      ONLY the exact-numeric compare and index-retrieval paths consume.
      Adding the variants cost **7 compile breaks** (the compiler
      enumerated every exhaustive match), each either handled (the numeric
      resolver routes it to `Term::NumCmp`, `Term::matches` aligns it in
      `i128` through `num_cmp`, `pick_for_terms` carries it to the
      column's scale and keys IDX_BCD) or failed CLOSED (a wide literal in
      a projected expression, a BETWEEN/IN bound, a bound param, or
      against a text column refuses rather than truncating). The compare
      core (`numeric_parts`/`num_cmp`) and the IDX_BCD encoder were
      already `i128`; nothing widened `Rhs::Int` or its 100+ sites.
      `qa/serve-real-leftjoinindex.sh` proves it three ways with the
      `FC_NO_INDEX` twin: a 38-digit equality keys and scan-compares
      identically to the engine, a range past `i64`, and an OR mixing a
      wide and a small literal.

      *And the PROJECTED wide literal describes INT128 now too* —
      `SELECT 99999999999999999999` announced nothing (the select-list
      parser capped at `i64` and REFUSED the statement). The RawExpr/Expr
      literal carriers grew an `Int128(i128)` variant (the select-list
      parser tries `i64` then `i128`); it evaluates to `Value::Int128` and
      `rank_of` returns `NumRank::I128`, which flows through
      `is_wide`→`result_width_bytes`==16→`exact_width_form` to
      `(Wire::Int128, sqltype 32752, len 16)` - the same describe the
      engine gives a magnitude between `i64::MAX` and `i128::MAX`. Adding
      the variant cost three exhaustive `Expr` matches (`type_of`,
      `rank_of`, `eval`) plus a few catch-all sites; the wire encoder
      already sent `Value::Int128`. `qa/serve-real-numsubtype.sh` gates
      the describe (i64::MAX+1, a 20-digit, and `i128::MAX` all
      INT128/len-16) and the VALUE round-trip.

      *And wide-literal ARITHMETIC came with it* — `99999999999999999999
      + 1`, `5000000000 * 5000000000` (both operands i64 but the PRODUCT
      wide), and the same inside a `WHERE`. The select-list arithmetic
      already worked once the `RawExpr::Int128` carrier existed (it flows
      through the shared `expr_atom`→`Expr::Bin` eval, which the prior
      slice built); the gap was the WHERE-*expression* atom parser
      `texpr_atom`, which matched only `Tok::Int(n)` and hit `_ => None`
      on a `Tok::Int128` - one arm (`Tok::Int128(n) => RawExpr::Int128`)
      opened it. The second door was the Expr-LHS comparison lowering's
      `rhs_expr` closure, which refused `Rhs::Int128` for want of a
      carrier (`WHERE <expr> = <wide>`); it now emits `Expr::Int128`. The
      i128-boundary OVERFLOW was already faithful - the shared `Expr::Bin`
      eval uses checked i128 arithmetic and raises SQLSTATE 22003 exactly
      as the engine does (it promotes to DECFLOAT for a bare wider literal
      but RAISES on integer arithmetic overflow, probed). Gated in
      `serve-real-numsubtype.sh`: arithmetic type+value, WHERE-side
      counts, and SQLSTATE parity on the two overflow forms.

      *And the PAST-i128 magnitude is a DECFLOAT(34) literal now* — a bare
      integer literal too big for `i128` (past `170141183460469231731687303715884105727`)
      is what the engine describes DECFLOAT(34) (`sqltype` 32762, len 16),
      rounding the magnitude to 34 significant digits HALF-UP (round half
      AWAY from zero - PROBED, distinct from the HALF-EVEN the text-compare
      grammar uses) and carrying it as an IEEE 754-2008 decimal128. The
      `Value::DecFloat34` carrier and the DPD *decode* already existed (for
      stored DECFLOAT columns); the missing half was an *encoder* - the
      `ods::decfloat` module gained the vendored `BIN2DPD` table (decDPD.h),
      `encode_dec128(neg, coeff, exp)` (the exact inverse of `decode_dec128`;
      the exponent's top two bits are always < 0b11 for a valid decimal128,
      so the combination-field split never collides), and
      `dec128_from_int_digits` (the HALF-UP round + encode), all unit-tested
      by encode→decode identity and against the probed rounding cases.
      `Expr`/`RawExpr` grew a `DecFloat34(u128)` carrier (raw bits);
      `build_expr_col_from` SHORT-CIRCUITS it to `(Wire::Dec34, 32762, 16)`
      before the exact-numeric describe (its `type_of` deliberately declines,
      fail-closing any attempt to nest it in arithmetic - a later slice). The
      SIGN is folded in before the type is chosen (`neg_wide_min`, the
      i128-boundary analog of the existing `neg_i64_min`): exactly `-2^127`
      is `i128::MIN`, an INT128 - only larger magnitudes stay DECFLOAT with
      the sign carried into the encoding. Wire *send* already handled
      `Value::DecFloat34` (`xdr_dec128`). Gated in `serve-real-numsubtype.sh`:
      DECFLOAT type (positive, negative, u128::MAX, 52-digit), the INT128
      `-2^127` boundary, and value round-trips (exact-half, below-half, the
      all-nines carry, and negatives).

      *And the DECFLOAT WHERE-literal came next* — `WHERE <numeric-col> <op>
      <past-i128-literal>`. The engine promotes BOTH sides to decimal128,
      rounding the COLUMN to 34 significant digits HALF-UP too - PROBED: two
      INT128 values differing only past the 34th digit BOTH match one
      DECFLOAT literal, and `i128::MAX+1` rounds DOWN to `…884100000`, which
      an exact `i128::MAX` column also rounds to, so `col = <i128::MAX+1>`
      matches both. The WHERE tokenizer's `numeric_tok` grew the past-i128
      arm (→ `Tok::DecFloat34`, stripping the sign the tokenizer prepends);
      `parse_value` → `Rhs::DecFloat34`; `typed_term`/`numeric_term` →
      `Term::NumCmp(_, _, Rhs::DecFloat34)`; `Term::matches` promotes the
      column via a new `value_as_dec` (exact numerics rounded by
      `ods::decfloat::round_to_dec34`, a stored DECFLOAT decoded) and
      compares with `decfloat::cmp`. Fail-closed everywhere else: no index
      band (`render_toks` declines the token → scan), no BETWEEN/IN bound,
      no expr-compare, no param bind. Gated in `serve-real-numericwhere.sh`
      (+9: the rounding boundary on INT128 and NUMERIC(38,0), `<`/`>`/`<>`/
      `>=`, negative literals, an AND of two DECFLOAT bounds).

      *And the DECFLOAT COLUMN in WHERE came next* — `col_kind` never
      classified DEC64/DEC128, so a DECFLOAT column refused every predicate
      (even `DF = 100`). A new `decfloat_term` resolver (routed beside
      `numeric_term` on `is_decfloat_col`) makes EVERY comparison decimal:
      the literal is promoted to decimal128 (`rhs_to_dec128`, rounding a
      wide integer to 34 significant digits) and carried as
      `Rhs::DecFloat34`, which the existing `Term::matches` arm compares
      against the column - `value_as_dec` decodes a stored DECFLOAT or
      rounds an exact numeric - with `decfloat::cmp`. `=`/`<>`/`<`/`<=`/
      `>`/`>=`, IS [NOT] NULL, BETWEEN, IN and NOT all ride this; a
      text/param literal, LIKE/STARTING and an expression side refuse
      (fail closed). A scale-sign bug in `value_as_dec`/`rhs_to_dec128`
      surfaced and was fixed - a stored numeric is `raw * 10^scale`, so
      the decimal exponent IS the scale, not its negation (the prior slice
      only ever hit scale-0 INT128/NUMERIC(38,0) columns, which hid it);
      the scaled-column-vs-DECFLOAT-literal path is now correct too. A
      **NaN** column value TRAPS on comparison (`isc_decfloat_invalid_operation`,
      SQLSTATE 22000) exactly as the engine does - PROBED, per row - so a
      new `EvalErr::DecfloatInvalidOperation` raises the identical vector
      (Infinity, by contrast, is a normal ordered value `decfloat::cmp`
      handles). Gated (+20): the full DECFLOAT(34) and DECFLOAT(16) column
      matrix, a scaled-column vs DECFLOAT literal, and the NaN-trap SQLSTATE
      parity.

      *And the wide INT128 LITERAL in INSERT VALUES came next* — the value
      list already tokenised a magnitude past i64 as `Tok::Int128` (my
      earlier tokenizer work), but the store's arm-match refused it (`_ =>
      None`). A new `InsVal::Int128(i128)` and a direct branch in
      `encode_set_value` (a new `WireParam` variant would have touched 152
      match sites, so it encodes STRAIGHT to the column bytes) stores it:
      into an INT128 or a `NUMERIC(38,x)` it rescales in i128 (via
      `rescale_int`, the shared `exact_int_le` writing the little-endian
      field), and into a DECFLOAT(34) it promotes to decimal128
      (`dec128_from_int_digits`, rounding a 39-digit i128 to 34 sig). A
      narrower integer column (BIGINT and down) OVERFLOWS - refused at
      prepare (the engine raises 22003 at execute; both reject, the row
      never lands). i128::MAX and i128::MIN both store; the negative folds
      in the tokenizer as always. Gated (+3): fire-crab WRITES the rows and
      the ENGINE reading the same file back byte-identically is the proof
      (INT128, NUMERIC(38,2) x100, DECFLOAT(34) exact and rounded), plus
      the BIGINT-overflow rejection.

      *And the PAST-i128 literal in INSERT came next* — a magnitude beyond
      i128::MAX tokenises as `Tok::DecFloat34`, which already carries its
      decimal128 bits (rounded to 34 sig by the tokenizer). A new
      `InsVal::DecFloat34(u128)` + one `encode_set_value` branch stores it
      into a DECFLOAT(34) column VERBATIM (`bits.to_le_bytes()` - no
      re-encode). Every exact-numeric target OVERFLOWS (the value does not
      fit i128) and refuses. Gated in the same wide-INSERT section (fc
      writes u128::MAX and a negative 52-digit into the DECFLOAT column,
      the engine reads them back identically; plus a past-i128-into-INT128
      overflow rejection).

      *And the DECIMAL64 ENCODER closed DECFLOAT(16) INSERT and small
      literals* — `ods::decfloat` was decode-only for decimal64 too; a new
      `encode_dec64` (inverse of `decode_dec64` - 5 declets, bias 398, an
      8-bit exponent continuation, the same combination-field split as
      decimal128 since biased qe <= 767 < 3*256), `dec64_from_int_digits`
      (round an integer's digits to 16 sig HALF-UP + encode) and
      `round_to_dec16`/`round_to_dec16_of` join it. Wiring them revealed a
      WIDER gap than the DECFLOAT(16) tail: a SMALL integer or decimal
      literal into ANY DECFLOAT column refused too, because
      `encode_wire_value`'s `WireParam::Int` arm had no DEC64/DEC128 case -
      only wide (Int128/DecFloat34) literals had ever been wired. Both arms
      now encode: an INT128 or small integer into DECFLOAT(16) rounds the
      EXACT digits to 16 sig (no double rounding - the full magnitude is in
      hand); a DECFLOAT(34) literal into DECFLOAT(16) re-rounds the 34-sig
      token to 16 (a double rounding, faithful for every value but the rare
      one whose digits 17..34 hide a carry - `round_to_dec16`'s note); a
      small integer/decimal literal into either DECFLOAT keeps its cohort
      (`1.5` is `15 x 10^-1`, `-2.50` is `250 x 10^-2`), the scale becoming
      the decimal exponent. Gated (numericwhere): DECFLOAT(16) column added
      to the wide-INSERT table, small ints, decimals, a wide i128 and a
      past-i128 all written and read back byte-identically; encode_dec64
      encode->decode identity + probed 16-sig rounding, and encode_set_value
      DECFLOAT(16)/small-literal unit tests.

      *And a TEXT literal against a DECFLOAT column came next* — the engine
      converts it by decNumber's string grammar, NOT the exact-numeric CVT
      one: an optional sign, `digits[.digits]` and an optional `[eE][+-]?
      digits` exponent, and NOTHING else - interior OR surrounding spaces
      raise (`DF = ' 1.5 '` is 22018 where `N92 = ' 1.5 '` converts,
      probed), the coefficient rounds to 34 significant, equality is
      cohort-insensitive (`'1.50'` = 1.5). A new `text_to_dec128` parses
      that grammar; `decfloat_term` maps a convertible text to
      `Rhs::DecFloat34` and a non-convertible one to
      `Term::CmpConvErr(_, _, s, None)` - which raises 22018 PER ROW (UNKNOWN
      over NULL, no raise on an empty table, probed identical). The specials
      decNumber also accepts (`Infinity`/`NaN`/`sNaN`) are deliberately left
      to `text_to_dec128` returning None → 22018, a recorded divergence from
      the engine's convert/trap, since a special TEXT literal is vanishingly
      rare and would need the infinity/NaN encodings and the literal-side
      trap. Gated (numericwhere +10): the convertible matrix (sign, dot,
      exponent, scientific, cohort) and the 22018 raise on `'abc'`/`' 1.5
      '`/`''`; a `text_to_dec128` grammar unit test.

      *And a `?` PARAMETER against a DECFLOAT column came next* — the input
      slot describes as the column itself (probed: DECFLOAT(34) len 16), so
      `decfloat_term` registers `params[slot] = d.clone()` and produces a
      `Rhs::Param(slot, ColKind::DecFloat)` (a new binding marker). At bind,
      `bind_rhs` promotes the driver's value to decimal128: an integer or
      decimal `v * 10^ws` encodes exactly, a text value goes through the
      same `text_to_dec128`, and a DOUBLE promotes by its EXACT binary value
      - probed decisively: the f64 `1.1` finds NO decimal-`1.1` row, because
      the double is `1.1000...0888`, not the decimal `1.1` (only exact
      binary fractions like `1.5` match). fire-crab reproduces that exact
      expansion by formatting past 34 significant digits and re-parsing.
      Gated (numericwhere +9): int, exact and inexact double, text and NULL
      params over DECFLOAT(34) and DECFLOAT(16), each bound through node
      against BOTH servers - the engine side on its own server-owned copy,
      since the 3050 engine cannot open the plain-path file fire-crab
      serves.

      *And LIKE / STARTING WITH closed the compare surface* — the engine
      renders the DECFLOAT value to its decNumber string and matches the
      pattern per row (`1.5`, `100`, `-2.5`, the cohort-preserving `1.50`,
      the scientific `3.402...E+38`, `Infinity`), which is exactly
      `Value::render`. So `decfloat_term` reuses the same
      `Term::ExprLike`/`Term::ExprStarting` (and their `?`-pattern variants)
      that `numeric_term` builds - the term evaluates `Expr::Col` to the
      value and matches `v.render()`. Gated (numericwhere +11): literal and
      `?` patterns, wildcards `%`/`_`, the scientific form, cohort, NOT
      LIKE, over both widths. SIMILAR TO stays text-only, as for the
      exact-numeric columns.

      *And the numeric LIKE-pattern describe WIDTH was corrected* — the `?`
      pattern slot on ANY numeric column had been described VARYING(32763)
      where the engine gives a FIXED VARYING(30) (the numeric-to-text render
      width, not the column's own shape - probed: `N92`, `I`, `BIGINT`,
      `INT128`, `DECFLOAT(34)` and `(16)` all len 30, while a text column's
      pattern keeps the column width: `VARCHAR(10)`→10, `CHAR(5)`→5). A new
      `NUM_LIKE_PATTERN_LEN = 32` (32 = 30 + the 2-byte VARYING count)
      replaces the hardcoded 32765 at the four numeric column-path claim
      sites (`numeric_term`, `decfloat_term`, and `param_or_typed_term`'s
      INT LIKE/STARTING); the text-column path already claimed the column's
      own descriptor, so it was right. The value binding was never affected
      (the driver sends the pattern at its true length) - this is purely the
      announced describe. Gated (numericwhere +6): the pattern width read
      through fire-crab and the engine matches len 30 for NUMERIC(9,2),
      NUMERIC(18,4), INT128, INTEGER, DECFLOAT(34) and (16).

      *And the EXPRESSION-LHS pattern width followed the expression* -
      `<expr> LIKE ?` describes the slot as the LHS EXPRESSION's own result
      text width (probed): a numeric expression the fixed 30, a text one its
      computed width - `UPPER(VC10)` is 10, `UPPER(VC200)` is 200,
      `SUBSTRING(.. FOR 3)` is 3, `CAST(I AS VARCHAR(7))` is 7. So
      `resolve_expr_term` computes it from `text_form` (`+2` for the VARYING
      count) for a text side and `NUM_LIKE_PATTERN_LEN` for a numeric one.
      Widening that arm to accept a scaled-NUMERIC side (the literal-pattern
      arm already did) also LIT a previously refused shape: `(N+0) LIKE ?`
      now binds and renders, at width 30, exactly as the engine answers it.
      Gated (numericwhere +4): the expression-LHS width for `(A+0)`,
      `(N+0)`, `(I+0)` and a `CAST`.

      *And the `?`-ON-THE-TESTED-SIDE closed the last width* - the tested
      `?` of `? LIKE/STARTING <pattern>` describes as the PATTERN's own
      width (probed): a literal pattern its char length (`'abc%'` is 4,
      `'a_c%def'` is 7, `'x'` is 1), a NULL pattern a bare 1, and a
      parameter pattern the fixed 30 (both `?`s of `? LIKE ?` are 30).
      `resolve_param_lhs` now claims the tested slot with a
      char-length-derived VARYING (`+2` for the count) instead of the flat
      32765, per pattern kind. The value binding was untouched (the driver
      sends both sides at their true length). Gated (numericwhere +6): the
      literal, NULL and param-pattern widths for `? LIKE` and `? STARTING
      WITH`.

      *And `||` CONCATENATION became a WHERE expression* - the boundary the
      LIKE-width slices kept bumping into was broader than LIKE: a
      concatenation was refused in ANY WHERE side (`VC||'x' = 'abx'` too),
      because the token-level parser did not know `|`. It now tokenises `||`
      to `Tok::Concat` and folds it in a `texpr_concat` level - tighter than
      the arithmetic operators, left-associative, mirroring the select
      list's `expr_concat` - into a `RawExpr::Concat`. Everything downstream
      already handled a concatenation (`resolve_expr` types it Text, `eval`
      renders it, `resolve_expr_term` LIKEs/compares it, and the
      expression-LHS width slice gives its pattern `?` the concat's own
      result width - `VC||'x'` is 11, `VC||VC2` is 15), so the one operator
      lit the whole surface. Gated (wherexpr +9): concat `=`/LIKE/STARTING,
      two-column and multi-`||` (left-assoc), literal-first, concat with a
      CAST, and NULL propagation (`NULL||x` is NULL). Still refused
      deliberately: DECFLOAT in arithmetic / nested, and a value past
      DECFLOAT(34) range.

      *And the `Infinity`/`NaN` TEXT SPECIALS converted* - the boundary the
      DECFLOAT text-literal slice noted: decNumber accepts `inf`/`infinity`
      and `nan`/`snan` (case-insensitive, an optional sign, a NaN payload of
      digits), and the engine converts them where fire-crab had raised
      22018. `encode_dec128_special` builds the decimal128 `±Infinity`
      (combination `11110`) and `NaN` (`11111`) bits; `text_to_dec128`
      recognises the spellings (trailing junk like `Infinityx` still falls
      through to 22018). An Infinity is a normal ORDERED value
      (`decfloat::cmp` ranks it, `DF > '0'` takes it, `DF = 'Infinity'`
      finds it); a NaN TRAPS the comparison (SQLSTATE 22000) on any non-NULL
      row - the same `EvalErr::DecfloatInvalidOperation` the column-NaN uses,
      now also fired when the LITERAL decodes NaN. Both the literal and the
      text-parameter paths inherit it (`text_to_dec128` is shared). Gated
      (numericwhere +9): the Infinity conversions and ordering, the `NaN`/
      `nan`/`sNaN` traps, and the junk refusal. One wording nuance recorded:
      the engine prepends a `decfloat_invalid_operation` line to the *22018
      message* of a malformed special (`Infinityx`); the SQLSTATE matches,
      the extra line does not, an exotic-input boundary.

      *And DECFLOAT ARITHMETIC arrived (`+`/`-`/`*`, unary `-`)* - fc had
      refused any DECFLOAT operand in an expression. `ods::decfloat` gained
      a digit-string big-decimal engine (`add`/`sub`/`mul`/`negate`): exact
      then rounded to 34 significant digits HALF-UP (probed:
      `…2222 + 0.5 → …2223` rounds up off an even digit), the coefficients
      carried as strings so a 34x34 multiply needs no wide integer, with
      `Infinity`/`NaN` propagation (`Inf − Inf` and `Inf × 0` are NaN). The
      wire side: `resolve_expr_inner` now lets a DECFLOAT column into an
      expression; `eval` computes a `Bin`/`Neg` with a DECFLOAT operand in
      decimal (a NaN result traps 22000); and `build_expr_col_from`
      short-circuits an arithmetic tree with a DECFLOAT leaf
      (`is_decfloat_arith`) to the DECFLOAT(34) wire form - any DECFLOAT
      operand promotes the whole result, even `D16 * 2` and a `NUMERIC` mix,
      probed. The cohort rides through (`1.5 * 2` is `3.0`, `1.5 + 1` is
      `2.5`). Gated (numericwhere +11): value AND describe for int/decimal/
      column/nested operands over DECFLOAT(34) and DECFLOAT(16).

      *And DIVISION completed the four operators* - the feared decNumber
      `decDivide` exponent turned out to fall out of long division over the
      operands' OWN cohort coefficients (probed and matched): `6/2` is `3`,
      `1/2` is `0.5`, `12.0/3` is `4.0` (120/3 = 40 at exp -1), `1/3` is 34
      threes, `2/3` rounds up to `…667`. `ods::decfloat::div` does schoolbook
      long division to exactness or 35 sig then rounds to 34 HALF-UP - no
      wide integer, no separate cohort-reduction step. Divide-by-zero traps
      as the engine does: `x/0` is `isc_decfloat_divide_by_zero` (SQLSTATE
      22012, a new `EvalErr` emitted alone), `0/0` the invalid-operation
      22000 - both probed and matched. `is_decfloat_arith` and the eval
      branch now take `/`. Gated (numericwhere +6): column/int/decimal/
      nested quotients and the `x/0` SQLSTATE.

      *And the WHERE side came along* - `WHERE df + 1 > 5` had refused at
      TWO type gates, both keyed on `type_of` (None for a DECFLOAT
      arithmetic expression): `cmp_sides` (which pairs a comparison's sides)
      and the `cond_types` re-check `resolve_expr_term` runs on the built
      term. Both now recognise a DECFLOAT-arithmetic side
      (`is_decfloat_arith`) and let it through when the other side is
      exact-numeric; `value_cmp` grew a mixed arm so a DECFLOAT value
      against any exact numeric (or the two widths) promotes both to
      decimal128 (`value_as_dec`) and compares with `decfloat::cmp` - which
      is what the `Cond2::Cmp` eval falls back to. All four operators,
      column/literal/expression right sides, `IS [NOT] NULL`, negation and
      AND-composition ride it; a NaN from the arithmetic still traps at eval
      before the compare. Gated (numericwhere +10).

      *And `CAST(x AS DECFLOAT(16|34))` closed the surface* - a new
      `CastTarget::DecFloat { wide }` (`DECFLOAT` alone defaults to 34; only
      `(16)`/`(34)` are legal precisions). The five exhaustive `CastTarget`
      matches took it (compiler-guided): `cast_target_descriptor` announces
      DEC128(16 bytes)/DEC64(8) for a `?` slot, `type_of`/`rank_of` decline
      it (the describe short-circuits), `cvt_cap` leaves the text length to
      the decNumber grammar, and `eval` promotes the value to a `Dec` -
      value_as_dec for a numeric or stored DECFLOAT, `text_to_dec128` for a
      string - then encodes decimal128, or (rounded to 16 significant)
      decimal64. `build_expr_col_from` short-circuits a bare cast to its
      declared width, and `is_decfloat_arith` treats a cast-to-DECFLOAT as a
      decimal leaf (`CAST(x AS DECFLOAT) + 1` promotes). NaN/Infinity carry
      through (a CAST re-represents, never traps). This also unblocked the
      `0/0` LITERAL - `CAST(0 AS DECFLOAT)/0` now traps 22000. Gated
      (numericwhere +9): both widths, a text source, the default precision,
      cast-then-arith, the describe width, a WHERE cast, and the `0/0`
      trap. **The DECFLOAT surface is now complete** - literal (projected,
      WHERE, INSERT), column comparison, LIKE/STARTING, parameter, the four
      arithmetic operators (projection and WHERE), and CAST, both widths.
      The one boundary left: a value past DECFLOAT(34) range (DECFLOAT
      cannot exceed its own range - not a real gap).

      *And the wide OUTER value came with it* — the probe's `band` capped
      an `Int128` driving value at `i64` and scanned; now it carries the
      wide value as `Rhs::Int128` into the IDX_BCD band (an i64-range one
      stays `Rhs::Int`, so it still keys a narrower inner). An `INT128`
      driver whose key IS the inner's 38-digit one finds its partner
      through the index, proved `index == scan == engine` by the twin.
      So a wide magnitude is a first-class key on BOTH sides of a join
      now, literal or value.
  - **A predicted bug that measurement did not confirm, recorded as
    such.** `ods::ddl::index_itype` maps every TEXT/VARYING column to
    `idx_string`, ignoring the charset, so a `CREATE INDEX` issued to
    fire-crab on a UTF8 column stamps itype 1 where the engine stamps 4.
    It was expected to produce an index the engine misreads. It does
    not: the engine builds its lookup keys from the itype IN THE INDEX
    ROOT, so the index is self-consistent either way, a gbak round trip
    normalises it, and the two encodings differ only for the EMPTY
    string. The WRITE path was never at risk because
    `resolve_index_ops` reads the itype from the root too — which the
    gate now pins with an empty-string lookup, the one byte where
    `idx_string` (0x20) and `idx_metadata` (0x00) disagree. It remains a
    metadata divergence worth closing, not a wrong answer.
  - **Scaled NUMERIC/DECIMAL keys** *(done)*. A `NUMERIC(9,2)` is a LONG
    holding 1250 at scale -2 and its key is the DOUBLE 12.5 — the same
    bytes a `DOUBLE PRECISION 12.5` gets; a `NUMERIC(18,2)` is an INT64
    and takes the `INT64_KEY` form. **The ENCODER always handled both**
    (`index_key`'s IDX_NUMERIC arm divides by the power of ten, which is
    `MOV_get_double`'s way — multiplying by 10⁻ⁿ differs in the last ulp
    for about a third of the raws at scale 1, and a key one bit off is a
    key the engine never wrote). What was missing was one step earlier:
    carrying the LITERAL to the column's own scale before asking for a
    key. `pick_for_terms` refused every column with `scale != 0`
    outright, so the engine indexed `WHERE N92 = 1.50` and fire-crab
    scanned. `at_column_scale` now moves a literal there — `1.5` and `2`
    both reach a `NUMERIC(9,2)` — and **a literal that does not land
    exactly still scans**: `N > 12.505` has no key at scale -2, and
    rounding one out moves the band's EDGE, which drops rows no filter
    above can recover. FLOAT/DOUBLE columns keep scanning for the same
    reason from the other side: their key is the value's own bits, and a
    decimal literal would have to travel the engine's literal→double
    conversion to land on them. `qa/serve-real-index.sh` 359 → 387
    checks, 14 DIFF against the previous commit — **all of them
    COVERAGE, none of them answers**, which is the right shape for a
    slice that changes which path is taken and not what is returned.
  - **Compound prefixes and text keys** *(done)*: an equality on an
    ascending compound index's LEADING segment is a band whose upper
    bound is the prefix's EXCLUSIVE SUCCESSOR (an inclusive one drops
    every row with a non-NULL trailing segment), and text equality is
    keyed for ASCII literals on `idx_string` and `idx_metadata`.
  - ~~**A named, measured write-path divergence at `i64::MIN`.**~~
    *(done — and the premise was backwards)*. The entry said
    `btw::int64_key` builds a key the engine did not write, because
    `make_int64_key` NEGATES before choosing a scale and negating
    `i64::MIN` overflows, "so its choice differs from the arithmetically
    correct one" — true, and it stopped one step short. **What the
    engine actually WRITES was never read.** Written by the engine, one
    value per database, dumped with `fcstat index-walk`:

    | value | stored key |
    |---|---|
    | `-9223372036854775808` | `800000000000000080` |
    | `0` | `800000000000000080` |
    | `-9223372036854775807` | `3cf5c91d14e3bcd76951` |
    | `1` | `bf1a36e2eb1c432d80` |
    | `-1` | `40e5c91d14e3bcd280` |

    **THE ENGINE FILES `i64::MIN` UNDER ZERO'S KEY.** The overflow does
    not perturb the scale choice, it sends the loop one bucket on, and
    `q *= 10` on `i64::MIN` wraps to exactly 0 (10·2⁶³ is a multiple of
    2⁶⁴), so both parts come out zero — at every scale, since
    `0 / powerof10(scale)` is 0.

    **It is a DEFECT, and it is the ENGINE'S ALONE**: equality finds
    such a row (both sides compute the same wrong key) while every RANGE
    misses it, because the entry sits at zero's position. On the engine,
    `A < -9223372036854775807` answers NOTHING though the row exists,
    and `A+0 < -9223372036854775807` — the same predicate with the index
    taken away — returns it. Matching it is not endorsing it: **a key is
    an ADDRESS in a shared file**, and a row written at a different
    address is one the engine's own lookups cannot find, which is a lost
    record rather than a slower one. So `int64_key` answers zero's key
    here instead of abstaining, `fcstat`-dumped bytes are pinned in a
    unit test, and `qa/serve-real-btree.sh` writes the row with
    fire-crab and reads it back **with the engine** (plus `gfix -v
    -full`, which cross-checks every record against every index entry).

    The blocked half is unblocked too. The literal parse read a digit
    run WITHOUT its sign — a leading `-` is a separate unary node — so
    `9223372036854775808` overflowed `i64` and the whole statement was
    REFUSED, though the value it names is representable. Measured, the
    engine folds the sign in before it types the literal: `-<digits>`,
    `- <digits>` and `-(<digits>)` all describe as **INT64**, while the
    bare magnitude and anything wider are **INT128** (and past 2¹²⁷,
    DECFLOAT(34)). Only the exact magnitude is folded; ~~everything wider
    stays refused until INT128 literals are their own slice, which is a
    real one — `Rhs` carries an `i64` raw across 113 sites~~ — **the wide
    magnitude is DONE** (the entry two above): a `Tok::Int128`/`Rhs::Int128`
    the compare and retrieval paths consume, without widening `Rhs::Int`
    at all. Past `i128` (DECFLOAT) still refuses.

    **It also uncovered a silent wraparound.** `Expr::Neg` used
    `wrapping_neg` where `+` and `-` beside it have always raised, and
    nothing could reach it until this value became spellable. The engine
    describes `- -9223372036854775808` as INT64 and raises 22003 at the
    row; that arm now does the same.

    *This is the SECOND place where fire-crab's two retrieval paths
    legitimately differ* (after the raising ON). `FC_NO_INDEX=1` answers
    the arithmetically correct rows for a range over `i64::MIN`; the
    index path answers the engine's. The twin is an equivalence oracle
    everywhere except this value and a raising ON.

    *Residual, pinned in the gate rather than left silent*: the WHERE
    clause has its OWN tokeniser and the fold lives in the select list's
    parser, so `WHERE A = -(9223372036854775808)` still refuses where the
    engine answers. The BARE spelling works on both sides everywhere.
    Closing it means teaching the token lexer the same magnitude — a
    refusal, never a wrong answer, and the check says so.

  - **`OR` and `IN`** *(done)*: a disjunction is a UNION OF BANDS, one
    per DNF branch, with every branch required to be servable (a partial
    union is a missing set of rows) and candidates deduplicated ACROSS
    bands (one row can satisfy two branches).
  - **Parameters** *(done)*: the bands are built at EXECUTE from the
    bound predicate, since a `?` has no value at prepare. ~~Only the
    projection's retrieval defers so far~~ — a parameterised **GROUP BY**
    defers too now: `Plan::Group` grew a `defer` field beside its
    `index`, built at prepare under the same `index.is_none() &&
    filter_has_params` guard the projection uses, and `resolve_access`
    runs it at execute (in the batch cursor path before the fold
    materialises, and in the streaming path) so a grouped query looks up
    on a bound `?` instead of scanning - proved by `pboth … yes` in
    `qa/serve-real-index.sh`, whose `(deferred)` trace fires for the
    grouped case as it does for the projection. **And DML WHERE defers
    too**: `Plan::Update`/`Plan::Delete` grew the same `defer` field, built
    at prepare in `plan_update`/`plan_delete` and resolved by
    `resolve_access` before `collect_dml_targets` walks the targets, so a
    parameterised `UPDATE … WHERE id = ?` / `DELETE … WHERE id = ?` keys
    the walk at execute (a `pdml` twin drives node-bound DML and checks
    both the resulting STATE and the deferred `dml index:` trace). Every
    retrieval shape - projection, grouped, DML - now defers a `?`'s band
    to execute alike.
  - **A failure that was the GATE's, and a claim of mine that was
    wrong.** `qa/serve-real-params.sh` had been failing since before W1,
    and I reported it as "fire-crab accepts a boolean parameter INSERT
    the engine rejects" — inferred from the gate's expectation rather
    than from the engine. Asked directly, **the engine accepts it too**,
    and the two files come out byte-identical: node-firebird 2.14.1 made
    boolean encoding metadata-directed, so a BOOLEAN target now gets a
    real `blr_bool`. The gate's premise was written when the driver could
    not do that. Four failures, every one pointing at fire-crab, and
    none of them fire-crab's. The gate now asks the engine instead of
    remembering.
  - Still to do: index-driven joins,
    text keys (a collation makes the key a collation key), compound
    prefixes, and parameters (their values arrive after the plan is
    built). Also: a statement `opt` cannot parse - a `HAVING`, for one -
    scans, because the retrieval inherits the optimizer's own limits.
  - **The rule that took two increments to state correctly.** "An index
    names candidates, the predicate decides" is not enough: an entry
    outlives the version that wrote it, so a record whose key CHANGED is
    named by both its old and its new entry, and a range covering both
    returns it TWICE — which no predicate can catch, because the row
    genuinely matches. A candidate is kept only if the fetched record
    still carries the entry's key.
  - It also fixed a pre-existing wrong answer it was in a position to
    see: uniqueness was read from the index ENTRIES, which outlive their
    records, so re-inserting a deleted key was refused against an engine
    that accepts it. The conflicting records are fetched and checked now
    — the same "candidates, not answers" rule.
- **W2 — the page cache.** *(the write order done; the image now
  SHARED)* **The buffer pool landed** (`fire_crab_cch::pool`): the pages
  of a database live **once per file per process** instead of once per
  attachment. `load_database` opens through the pool, readers take a
  reference-counted snapshot of the image, and writers are **serialized
  per database** — the write side is taken at a transaction's first
  write and held to its commit or rollback, because a rollback here
  restores a whole-image snapshot and must not be able to restore over
  another connection's committed rows. A connection that never wrote no
  longer restores anything at all. The pool re-reads a file that
  changed underneath it and forgets a dropped one.

  That closed both divergences W4's oracle had recorded — an attachment
  opened before another's commit sees it, and 20 concurrent inserts
  across two attachments leave 20 rows — and `qa/serve-real-concurrency.sh`
  now asserts the engine's answers on both, plus a COVERAGE section
  reading the pool's own counters (attachments that found the image
  resident, writers that queued) out of the server log, because the
  behaviour checks would also pass against a server whose probes never
  overlapped.

  Still to do here: **per-page fetch**. The unit of sharing is the whole
  image, not `Cache`'s buffer descriptors — reads still slice, they just
  slice pages nobody else can lose. Hit accounting and eviction are the
  rest of W2, and the seam for them is the single `SharedImage::image`
  every read now goes through. Also still: a file that GROWS is written
  whole (extending is its own careful-write question).

  **AND THE COMMIT IS WHAT WRITES NOW.** A statement installs its pages
  into the pool and leaves them dirty; the COMMIT flushes them, in one
  careful pass that carries the transaction's two bits as well. An
  autocommit INSERT was paying two flushes (~866us each of 2.78ms), a
  multi-statement transaction one per statement; both pay one now. It
  is also the durability the engine has: pages no commit reached are
  pages a crash may lose, and killing the server mid-transaction leaves
  the file holding exactly the committed rows.

  And the bug that came with it is the kind worth writing down: the
  commit returned early when the transaction had reserved no
  transaction ID, which is precisely what a DDL-only transaction looks
  like - its catalog rows are settled as they are written, so it never
  asks for one. Its pages stayed dirty and unwritten, and the engine
  reading the file answered *Table unknown*. **Deferring a write means
  every path that ends a transaction has to know it owns a flush.**

  **The last whole-file write went with it.** A generator draw did
  `fs::write` of the image - 5.5ms on a 2MB database, 26.4ms on a 5MB
  one - and so did putting a snapshot back. Both go through the pool
  and its careful flush now: 2.12ms and 3.68ms for the same draws. What
  is left that scales with the file is the per-write COPY of the image,
  which is what per-page fetch removes.

  **WHERE A STATEMENT'S TIME GOES NOW**, measured on an indexed table
  (`FC_SRV_TIME=1`, INSERT 3.6ms end to end):

  | phase | cost |
  |---|---|
  | the careful flush | 2234us |
  | the SELECT plan | 1003us, of which `choose_index` 544us |
  | the DML plan | 420us |
  | executing the write | 118us — the record write itself 2us, index maintenance 6us |
  | the image copy per write | 84us |

  **The statement cache is in, for DML and SELECT alike**
  (`crates/wire/stmc.rs`, 4 unit tests, `FC_NO_STMTCACHE` switch). It
  took a correction first: **a plan was not always a pure function of
  (schema, text)**, because a lone aggregate and a `GEN_ID` read were
  COMPUTED at prepare and carried in the plan. `Plan::Scalar` holds a
  `ScalarVal` now - what to compute, not what was computed - and the
  fetch works it out, which is where the engine works it out. Measured:
  `plan(select)` 984us → 291us and the statement 1.22ms → 0.50ms;
  `plan(dml)` 645us → 514us on a repeated parameterised INSERT. Timed on
  the WARM path rather than as an average, a repeated SELECT is 0.26ms
  against 1.34ms uncached and the hit itself is unmeasurable: the cache
  hands back an `Rc` rather than cloning the plan out, worth 3.3us per
  prepare on a bulky plan and 0.2us on a small one.

  **An average over a cold start is not a measurement of the warm
  path.** "The clone is what a hit costs" was inferred from averages a
  single MISS dominated, and it was wrong by two orders of magnitude.
  Time the thing itself.

  An unfiltered
  `SELECT COUNT(*)` is folded to a CONSTANT at prepare time, so a
  cached plan freezes the count - measured, with the cache on: one row,
  insert a row, ask again, one. The same query with a filter, which is
  not folded, answered two.

  So the next step is precise: **move the unfiltered COUNT(*) fold from
  prepare to execute** - it should plan to the aggregate the filtered
  one already plans to - and then the cache goes in unchanged. It was
  worth measuring what it would buy first: plan(select) 1104us → 299us,
  the statement 1.40ms → 0.50ms.

  Two things follow. **The flush is the physics of the disk**: Forced
  Writes means a synchronous write per page, and the engine is in the
  same regime — fewer pages per transaction is the only lever, and the
  commit already batches a transaction's statements into one. **And
  `choose_index` calls the optimizer per statement**, which re-derives
  its plan from the SQL text and the index metadata every time. That is
  a STATEMENT CACHE - the paper has a chapter on it, the engine has one,
  and fire-crab has none: the next item after this one, with its own
  invalidation (DDL, as here) and its own bound.

  **MEASURED AT SIZE, and both of the costs are O(FILE).** With
  `FC_SRV_TIME=1`, one INSERT:

  | database | INSERT | work copy | careful flush | execute |
  |---|---|---|---|---|
  | 6MB | 4.0ms | 259us | 2449us | 300us |
  | 33MB | 32.0ms | 6550us | 13660us | 6677us |

  Two costs scale, not one. The **image copy** every write makes, and
  the **flush's diff** — `changed_pages` compares the work image with
  the file page by page over the WHOLE file to find the handful that
  moved. At 33MB they are about two thirds of the statement.

  **And the shortcuts do not work, which is why this needs the real
  thing.** A private per-TRANSACTION working image would make the copy
  once per transaction instead of once per statement — but a private
  image is exactly what the buffer pool removed: two transactions each
  publishing a whole image at commit lose each other's rows, unless the
  write side is held for the whole transaction again, which is what W4
  stopped doing so that two writers could work at once.
  `Arc::make_mut` cannot win either while the pool holds a reference of
  its own. **The blocker is that `ods` addresses a database as one
  contiguous `&[u8]` with absolute offsets** — `resolve_relation(file,
  page_size, name)`, `assembled_image(file, ...)`, `u32_at(file, off)` —
  so the pages cannot be stored, shared or copied one at a time while
  that is the shape of the API.

  So the work is: give `ods` a page-addressed image (`Vec<Arc<[u8]>>`
  behind a `pages(n) -> &[u8]` accessor), convert its readers and
  writers to it, and let the pool publish by replacing the pages that
  changed — which also gives the flush its changed set for free and
  ends the diff. It is the largest single piece left in programme W,
  and it is worth what the table above says: at 33MB, ~20ms of a 32ms
  statement.

  **MEASURED BEFORE DOING IT, and it is not where the time is.** With
  `FC_SRV_TIME=1` on a two-row table, an INSERT cost 8.2ms: the work
  copy 111us (1.3%), the careful flush 957us, and **building the plan
  5.6ms**. The whole-image copy per write is real and grows with the
  file (~0.39ms/MB, so ~40ms on a 100MB database — it will have to go),
  but the statement in front of it was spending five times as much
  re-reading the catalog. That is what the metadata cache below
  answered, and per-page fetch is worth doing for the SCALING, not for
  the fixed cost.
- **W2 (as it stood) — the careful write order.** The server's DML
  flush writes PAGES in `cch`'s precedence order and syncs each before
  the page that references it, instead of dumping the whole file — so
  every prefix of the write sequence is a database the engine can open,
  which is exactly what `qa/cch-crash-harness.sh` had been checking
  about a model nothing called. `crates/wire` depends on
  `fire-crab-cch` now. Measured: five pages per statement instead of the
  whole file, and no speed change (the per-page sync cancels the smaller
  write) — this buys crash behaviour, not throughput. The read path that
  this left "slicing the image directly" was afterwards found to be
  **W4's prerequisite rather than a parallel item**, and is what the
  buffer pool above answers.
- **W3 — platform I/O.** *(the write path done)* The careful flush
  writes its pages through `fire-crab-pio`, opened with
  `plan_for_header(<the header's flags>)`. That fixed a rule the flush
  had got wrong on its own: **Forced Writes is an OPEN MODE, not an
  fsync per write** — the engine adds SYNC to the open mode when the
  header says so and does nothing per write when it does not, while the
  flush had been syncing every page unconditionally. Measured: 38.4s
  with it on against 38.3s off, so the sync was never the cost. Still to
  do: the READ path (the pool holds the image; `pio` is not the one
  reading it in).
- **W4 — the lock manager participating** (`lck`). *(done)* Written as
  "what makes concurrent attachments correct rather than accidentally
  correct", then **measured, and it was neither** — and the finding was not a missing lock manager but a
  missing *shared resource*: every attachment held a private
  `std::fs::read` copy of the file, so two attachments were two
  databases that shared a filename. `qa/serve-real-concurrency.sh` is
  the first gate in this suite that opens TWO of them, which is why none
  of the other 183 ever said anything about it.

  **The buffer pool (W2) is that resource, and it is in.** What the same
  probes answer now:

  | probe | engine | before the pool | with the pool | with transaction state |
  |---|---|---|---|---|
  | writer sees its own write | 555 | 555 | 555 | 555 |
  | an attachment opened BEFORE the commit | 555 | **100** — frozen at attach | 555 | 555 |
  | one opened AFTER | 555 | 555 | 555 | 555 |
  | the engine reading the file | 555 | 555 — durable and correctly on disk | 555 | 555 |
  | 20 concurrent inserts, 10 per attachment | all 20 rows | **10** — one image overwrote the other | all 20 rows | all 20 rows |
  | `gfix -v -full` on the result | clean | clean (that is what made it silent) | clean | clean |
  | an uncommitted row, read from another attachment | invisible | invisible — nothing was shared | **visible** | invisible |
  | a second writer, on an UNRELATED row | does not block | did not block | **waits** | **waits** |

  **The second-to-last row closed with real transaction state**, which
  is the half of W4 that is not locking at all. A transaction reserves
  one id at its first write and leaves it `tra_active` in the TIP;
  COMMIT is the two bits that flip it; every record walk goes through
  `fire_crab_ods::tra::visible_version` and takes the newest version
  whose transaction it counts — committed, its own, or the system
  transaction (id 0, whose slot reads active in every real database
  because the engine answers for it in code). That wired `tra`, which
  had been converted and gated since the MVCC increment with nothing
  calling it.

  Two rules came with it, both the engine's: a connection that detaches
  with work uncommitted has its transaction marked `tra_dead` rather
  than left open for good, and the system transaction (id 0) counts as
  committed although its TIP slot reads active. And one bug came out of
  it — reserving the id in an install of its own exposed that a careful
  flush was diffing against the last image PUBLISHED rather than the one
  on DISK, so pages changed by an install that was not itself flushed
  never reached the file. `qa/serve-real-update.sh` caught it as 16
  record-level errors from `gfix -v -full`; the pool now keeps the
  on-disk image as the flush baseline.

  **What is left is granularity.** fire-crab serializes writers on the
  DATABASE — the write side is held from a transaction's first write to
  its commit, because rollback here restores a whole-image snapshot —
  where the engine blocks only on a CONFLICTING row, through `lck` plus
  the record's transaction state.

  **And the reason the write side is held that long is the rollback, not
  the locking.** That is the dependency worth writing down before
  anything is enqueued, because `lck` is not the first step:

  1. **Rollback by STATE, not by image.** *(done)* A transaction that
     wrote only records is undone by `tra_dead` — two bits — instead of
     putting back the whole image; the rows, the index entries naming
     them and the pages they allocated all stay, and none of it counts,
     which is what the engine leaves behind too. `qa/serve-real-undo.sh`
     holds it: 202 versions still on the pages after the rollback, the
     engine reading 2 rows, `gfix -v -full` clean — **and that read
     collecting them, 202 → 34, because Firebird garbage-collects
     cooperatively**; the sweep takes the rest. One page flushed instead
     of the database; 32ms → 11ms to roll back 200 inserts on a 20MB
     file. Snapshots became free on the way (a reference to an immutable
     published image, not a copy).

     What still needs an image: DDL, whose catalog rows are settled as
     they are written, and `ROLLBACK TO` a mark — one transaction id
     cannot say "undo the last three statements". Those transactions
     carry `Database::image_undo`, and it is what step 2 will keep the
     transaction-scoped write side for.

     It also found a bug of the kind this whole programme is for: the
     rows a rollback now LEAVES behind were still being counted.
     `SELECT COUNT(*)` with no filter took a decode-free fast path over
     live primary headers — right only while every transaction in the
     file was committed — so a refused statement's rolled-back row came
     back as `COUNT(*) = 1`. Nothing about the count was new; what was
     new was a file that finally contained a row nobody should see.
  2. **A statement-scoped write side.** *(done)* The exclusive window
     is the read-modify-write of ONE statement now, released between
     requests, so two transactions can be open and writing at once. A
     transaction whose undo still needs an image keeps it — and the
     image it would put back is refreshed at each statement boundary
     until then, since restoring the one from transaction start would
     undo another connection's commits that landed in between.
  3. **The conflict, through `lck`.** *(done)* And the engine's
     mechanism turned out not to be a lock per record at all: a writer
     that meets a version belonging to another transaction reads that
     transaction's STATE, and waits on the lock that transaction holds
     over its own id (`LCK_tra`). `crates/wire/dblocks.rs` is those two
     calls; `with_conflict_wait` drops the write side, waits, and runs
     the statement again — the engine's WAIT and re-read. Two
     transactions waiting on each other close a cycle in the wait-for
     graph and one is denied with the engine's own `isc_deadlock`.

  Written this way round because the tempting order — enqueue first —
  would have produced locks that arbitrate a resource nothing else can
  reach during a transaction, and every single-session gate would pass.

  And it cost one bug worth keeping: **"has this transaction written?"
  had been answered by "does it hold the write side"**, which was the
  same question until the side became one statement long. A transaction
  that wrote and then read held nothing, so its rollback believed there
  was nothing to undo and skipped the generator compensations —
  `qa/serve-real-genwrite.sh` said so. The transaction carries the
  answer itself now.

  ~~**What is left of W4**~~ The deadlock vector's two extra items
  (`isc_update_conflict` and the concurrent transaction's number) are
  carried now, as the UPDATE-CONFLICT under snapshot
  (qa/serve-real-updateconflict.sh) - a snapshot cannot write over a
  row committed after it began. What remains of W4: NO WAIT is honored now
  (qa/serve-real-nowait.sh - an immediate update-conflict instead of a
  block); only LOCK TIMEOUT (wait N then conflict) is still read as
  plain WAIT.
- **W7 — the metadata cache** (`mdc`). *(done, and it was the
  measurement that put it here)* Every plan re-derived its table from
  the file — id, columns, descriptors, index operations, NOT NULL
  fields, identity column, qualified name, each a walk of a system
  relation — and `FC_SRV_TIME=1` put 5.6ms of an 8.2ms INSERT in
  planning. `crates/wire/mdc.rs` holds those answers per database,
  keyed by a generation only DDL advances (and the buffer pool's epoch,
  since a re-read file is a different database). Plan 4857us → 1809us,
  INSERT 7.4ms → 4.3ms. `qa/serve-real-metadata.sh` runs a
  DDL-then-DML script through the engine, through fire-crab and through
  fire-crab with `FC_NO_MDC=1`, and all three must agree.

  Then the rest of the plan, phase by phase: `plan:defaults` was
  1277us of the 1852us that remained — a walk of the whole of
  `RDB$RELATION_FIELDS` and a blob per default, for an answer that
  depends on the table and not the statement. Split into a cached
  `table_defaults` (with a per-column "exists and cannot be evaluated"
  marker, so a statement that omits the column still refuses) and a
  per-statement filter; the FK partnerships and check predicates
  followed. **Plan 5498us → 402us, INSERT 8.2ms → 3.06ms.**

  The SELECT planner followed - its own id and columns, the formats it
  decodes with (the system relations' bootstrap walk included) and the
  computed-column sources - taking `plan(select)` from 902us to 657us
  and the statement from 1.24ms to 0.94ms.

  Still outside it, deliberately: `choose_index` (232us) depends on the
  statement's filter and ORDER BY, not only on the schema. Still
  outside it, not deliberately: the triggers a statement gathers, and
  the per-statement CLONE of the cached check predicates (127us) -
  the answer is shared, the copy is not.
- **W5 — event delivery** (`evt`). *(done)* `POST_EVENT` is
  a PSQL statement now - a procedure containing one used to be refused
  whole - and `fire_crab_evt` is on the path behind it: the post is
  filed under the transaction, the COMMIT moves the counter, a ROLLBACK
  swallows it, and the table is per database so a poster in one
  attachment moves what a listener in another is watching
  (`qa/serve-real-events.sh`, 7 checks).

  ~~**What is left is the carrying**~~ **DONE** (second slice, and W5
  with it). `op_connect_request` answers a sockaddr for a listener of
  the server's own; the client opens the second socket; `op_que_events`
  registers an interest from an EPB; `op_cancel_events` takes it down;
  and each delivery is an `op_event` frame pushed on that socket by
  whichever attachment's COMMIT moved the counter - another connection,
  on another thread, which is why the sockets live in a per-database
  registry beside the event table.

  **The gate is the paper's own client**, as this section predicted:
  `samples/nodejs/events.js` runs against the live engine and against
  fire-crab and the two outputs must match LINE FOR LINE
  (`qa/serve-real-eventdelivery.sh`, 10 checks). That is a stronger
  statement than an assertion of our own, because the client was not
  written for it.

  **It also corrected two counter laws that no gate could see before.**
  A delivery carries `evnt_count + 1` (event.cpp:884), so a subscriber
  to an event nobody has posted is told 1; and a post to a name with no
  event block is DROPPED WHOLE (`if (event)`, event.cpp:376), the block
  being made by a subscription. Both were invisible while the only
  available differential compared DELTAS - which `qa/evt-semantics.sh`
  had to, having no delivery path to read an absolute number from. The
  carrying is what made them observable, and they disagreed at once.

  `EXECUTE BLOCK AS ... BEGIN ... END` came with it, because the
  paper's client posts with one: the interpreter's own surface with the
  DDL taken away, running at execute because it may write, its errors
  carrying the engine's `At block line: L, col: C`
  (`qa/serve-real-execblock.sh`, 11 checks). The parameterised and
  `RETURNS` forms are refused and gated as boundaries.
- **W6 — depth in `exe` and `svc`**: the request lifecycle, cursors and
  exceptions; then gbak/gfix/nbackup as services. *(three slices done;
  the first corrected the sentence above)*

  **EXCEPTIONS ARE DONE for the user-exception half** (third slice):
  named handlers, a bare `EXCEPTION;` re-raise, and - the point of it -
  an uncaught exception reaching the client as the engine's own error
  rather than a generic Dynamic SQL Error, `At procedure ... line: L,
  col: C` included (`qa/serve-real-exceptions.sh`, 19 checks).

  **The rest of `exe`, measured rather than guessed.** Eleven PSQL
  shapes were run against both servers; ten were refused, one worked.
  What is left, in the order the measurement suggests:

  * ~~runtime errors as catchable conditions~~ **DONE** (fourth
    slice): every error the interpreter raises carries a gdscode, a
    SQLCODE and a SQLSTATE, so all three condition forms work, a
    division by zero is catchable, and an overflow that used to answer
    NULL raises 22003 (`qa/serve-real-psqlerrors.sh`, 15 checks). The
    identity is read back out of the vector the server would send, so
    the two can never disagree;
  * ~~explicit cursors~~ **DONE** (fifth slice), and `LEAVE`/`EXIT`/
    `ROW_COUNT` with them, since the canonical loop needs all three
    (`qa/serve-real-cursors.sh`, 14 checks). The cursor's query is
    planned by the ordinary planner, so it sees joins and expressions
    for free; a fetch past the end leaves the variables alone, which is
    the part that would silently answer wrongly if guessed;
  * ~~`EXECUTE PROCEDURE` inside a body~~ **DONE** (sixth slice), with
    `ROW_COUNT` for DML alongside it (`qa/serve-real-callproc.sh`, 15
    checks);
  * ~~`EXECUTE STATEMENT`~~ **DONE** (seventh slice), in all three
    shapes - bare, `INTO` for a singleton, and the `FOR EXECUTE
    STATEMENT` loop (`qa/serve-real-execstmt.sh`, 33 checks). It is
    `isc_dsql_execute_immediate` seen from the inside, so it goes down
    the SAME plan chain a client's statement does - the chain was
    EXTRACTED from the `op_exec_immediate` handler rather than copied,
    because two lists of what a server can execute would drift, and the
    direction they drift is a body silently refusing DDL a client is
    served. What had to be measured rather than guessed: **a dynamic
    DML does not touch `ROW_COUNT`** (the count stays that of the last
    STATIC statement), a singleton that matched nothing leaves its slots
    alone, one that matched several raises 21000 rather than taking the
    first, the INTO slots must equal the projected columns exactly -
    including a query with NO INTO, which is the same "Output parameters
    mismatch" - and a NULL or empty text is the engine's -104, not a
    no-op. Two things came with it because the feature is unusable
    without them: a **text assignment** (`S = 'SELECT ...' || :K`), since
    `Expr` is arithmetic and has no string literal, and **a body's DML
    failure carrying the engine's own error** instead of a generic
    Dynamic SQL Error - which is what lets a handler catch what the
    dynamic statement raised, and which fixed the static form too. The
    text surface also surfaced a WRONG ANSWER that predates it: `N =
    '5'` into an INTEGER output is a conversion the engine performs, and
    the row encoder renders a text value into an integer slot as 0, so
    the client was told 5 is 0. Both the source interpreter and the BLR
    executor now refuse it instead;
  * ~~`IN AUTONOMOUS TRANSACTION`~~ **DONE** (eighth slice), and
    `EXECUTE STATEMENT ... WITH AUTONOMOUS TRANSACTION` with it, since
    it is the same requirement wearing the other syntax
    (`qa/serve-real-autonomous.sh`, 22 checks). The block reserves its
    own id, commits or dies on its own, and - the part that took the
    work - **what it committed survives the failure of the body around
    it**, because every undo in this server is "put an image back" and
    the block's pages therefore have to be written FORWARD over what the
    undo restores, the way the generator windows already write their
    settled values. The other direction came free: the block cannot see
    the outer transaction's uncommitted rows, since visibility here is
    "committed, or my own" and the block's reads run under the block's
    id.

    **What it refused, and what lifted it - DONE, the increment after
    it.** If the BODY AROUND the block had already written, the enclosing
    undo restored an image without those writes and the page carve-out
    carried them straight back in - a failed statement's own rows, still
    visible to its transaction. Undoing them needed them to have a
    transaction of their own to KILL, which is the engine's savepoint
    model (`tra.cpp`'s undo records / `VIO_verb_cleanup`). **That is now
    what every undo window is** (see *A savepoint is a transaction*
    below): the body's writes carry a nested id, killing it is the undo,
    and both the body-wrote-first and the block-inside-a-block boundary
    are ordinary differential checks. What is still refused is the two of
    them meeting the IMAGE path - a transaction that has done DDL.

    It also found where the ISOLATION MODEL first shows: the outer
    transaction reading what the block committed answers 0 in the engine
    (its snapshot predates the block) and 1 here (a reader counts what is
    committed when it reads). Snapshot isolation is not converted; the
    gate asserts the divergence rather than letting it pass;
  * ~~`ROW_COUNT`~~ **DONE** with the slice above - the DML paths report
    what they touched back into the frame, and a statement that matched
    nothing answers 0 rather than leaving the previous count.

  ~~fire-crab announces every procedure OUTPUT
  PARAMETER as BIGINT~~ **DONE** (qa/serve-real-procdescribe.sh, 7):
  proc_out_col rides wire_for, both call shapes render byte-identical
  to the engine, TEXT outputs ride now, and TEXT INPUTS the
  increment after (gate 7 -> 13: quote-aware parse_call_args - 'a,b'
  broke the naive split - shared bind_proc_args on BOTH executor
  paths, CHAR padding, the locationless 22001 truncation vector, and
  the announced-then-raised-at-fetch law for selectable bodies;
  cross-type stays refused where the engine converts), and the
  VARYING count-word normalization in domain_desc came out of the
  first differential render; **an
  expression in a `DECLARE ... CURSOR FOR (...)` select list must be
  ALIASED** or the engine answers "Invalid command" (the identical
  SELECT runs standalone); ~~`SELECT ... INTO :v` - the STATIC
  singleton - is outside the surface~~ **DONE**
  (`qa/serve-real-selectinto.sh`, 8 checks): parsed in the statement
  walk (the INTO clause is last in the grammar and illegal in a
  subquery, so the split is the last paren-depth-0 INTO), planned
  through the ordinary query planner, and its laws are NOT the dynamic
  form's - the static form SETS `ROW_COUNT` (1 on a match, 0 on none)
  where the dynamic form leaves it, and an arity mismatch is the -313
  count-mismatch vector, judged against the PLAN's projection so an
  empty result still refuses. The engine raises the -313 at PREPARE of
  the block, this server when the statement runs - same locationless
  vector, later moment, the recorded difference. ~~Found on the way: a
  TEXT comparison in an IF condition is outside the interpreter's cond
  surface~~ **DONE the increment after** (qa/serve-real-psqltext.sh,
  12): PAD SPACE semantics measured and kept, the stored-BLR boundary
  guarded (a text literal has no probed BLR - bodies carrying one are
  interpreted, never emitted; CHECK stays int-only). ~~Still outside: `B = NULL`~~ DONE the
  increment after (gate 12 -> 16): Expr::NullLiteral, whose blr_null
  byte was already probed by the DECLARE null-init emission;
  ~~a BIGINT literal is outside the PSQL surface~~ **DONE** (gate 16
  -> 19): the lexer reads i64 and the parser picks the narrowest
  literal - i32 keeps every stored shape's exact bytes, an
  out-of-range value takes blr_int64, the shape the BLR executor
  already decodes (pinned by symmetry); the CHECK family closed the
  increment after (qa/serve-real-checktext.sh, 13): text/NULL/BIGINT
  comparisons compile now, the stored text literal GOLD-PINNED
  (blr_text2 + charset), and the real wall was the INLINE column
  CHECK's parse, not the types - with the engine itself enforcing
  fire-crab's stored trigger as the closing oracle, **`INSERT ... VALUES`
  without a column list** is outside it too, and ~~`CREATE PROCEDURE` is
  not supported at all~~ **DONE** (qa/serve-real-createproc.sh, 10):
  dsql::compile_procedure - the BLR oracle - wired to DDL through
  compile_procedure_full + ods::create_procedure, the stored
  RDB$PROCEDURE_BLR BYTE-IDENTICAL to the engine's; boundaries: the
  engine executing an fc-authored procedure still crashes its loader
  (deeper catalog fidelity), and a duplicate refuses without the
  no-meta-update wrapper. DROP PROCEDURE followed, and with it the
  systemic unique-index-after-delete fix (btw::recno_is_live) that
  finally lets ANY dropped object be created again under the same name
  - fire-crab could re-create none before (qa/serve-real-dropcreate.sh,
  8). The old note stood: every gate builds its procedures with the
  engine
  and executes them through fire-crab, which is why the interpreter is
  well covered and the DDL is not.

  And one that had been hiding: **a COMMENT in a body refused the whole
  body**, because the statement walk skipped whitespace and not `/* */`
  or `--`. It survived this long because a body of nothing but
  ASSIGNMENTS never reaches the source parser at all - the BLR executor
  answers it - so only a body that also WRITES showed it. Fixed with the
  autonomous slice, whose gate found it by commenting one of its own
  procedures. ~~A comment INSIDE a statement is still outside the
  surface~~ **DONE** (gate 19 -> 24): one literal-aware stripper at
  the statement slice and the IF/WHILE condition slice; a quoted
  comment-opener stays data.

  **`gfix -write sync|async` is not a service at all.** Filing the
  tools under "as services" was a guess, and this one is wrong: gfix
  ATTACHES, carrying the mode in the DPB as `isc_dpb_force_write` (tag
  24, consts_pub.h:59), and detaches. A server that answered only the
  service manager would leave the switch silently doing nothing. What
  it asks for is one bit - `hdr_force_write` (ods.h:724) in the header
  page - which `fire_crab_pio::plan_for_header` has read since it was
  converted to decide whether a flush opens the file with SYNC; what
  was missing was only the ability to CHANGE it
  (`qa/serve-real-forcewrite.sh`, 9 checks, `gstat -h` as the oracle).

  The lesson generalises to the rest of the tier: **before writing a
  service, check whether the tool uses one.** gbak/nbackup genuinely
  are services; gfix is not, for any of its switches.

  *(second slice done)* The other three header items followed - `-use
  full|reserve` (`hdr_no_reserve`), `-buffers N` (`hdr_page_buffers`)
  and `-housekeeping N` (a CLUMPLET, which meant porting `storeClump`
  and maintaining `hdr_end` - the field only a writer needs, whose
  absence is silent corruption rather than a wrong answer). 23 checks
  in `qa/serve-real-gfixheader.sh`.

  It also corrected an assumption worth keeping visible: **gfix sends
  one item per run.** `buildDpb` (exe.cpp:207-344) is an else-if chain,
  so several switches collapse to whichever the CHAIN reaches first and
  the rest are dropped with rc=0.

  *(third slice done)* **`-mode read_only|read_write`** - the flag is one
  bit (`hdr_read_only`, 0x20) and the refusal path behind it was the
  work, which is why it went last. Three laws had to be measured rather
  than assumed, and each one is a place a converter guesses wrong:
  the mode switch takes the database EXCLUSIVELY and is the ONLY gfix
  switch that does (`-write`, `-buffers` and `-housekeeping` change the
  header with an attachment held; `-mode` answers `isc_lock_timeout` +
  `isc_obj_in_use` naming the file, immediately); it takes it BEFORE
  deciding whether the mode would change, so a no-op `-mode` still
  refuses while somebody is attached - the opposite of this server's own
  "a no-op gfix writes no page" rule; and a write on a read-only database
  gets `isc_read_only_database` in TWO shapes, bare for DML and behind
  `isc_dsql_error` for the DDL the engine refuses at prepare.
  `Database::work_copy` is the floor under all of it - the one funnel
  every write goes through - so a write path added later cannot forget
  the mode. 34 checks in `qa/serve-real-readonly.sh`.

  It also found a bug the other four switches could not reach: **the
  careful flush took its open mode from the image it was about to
  write**, so setting the read-only bit made the file refuse the very
  page that says "read only". The rule is the TRANSITION - a flush that
  CHANGES the bit is the switch and opens read-write - and it is not the
  same rule forced writes has, whose new promise deliberately governs
  the write that turns it on. And **an attach that could not do what its
  DPB asked was answering OK**: the refusal was traced and dropped,
  which made gfix report success (rc=0) for a switch that changed
  nothing.

  *(fourth slice done)* **`-shut`/`-online`** - the mode ladder over
  `hdr_shutdown_mode` (the byte at offset 25), and everything around it
  that had to be measured: the ladder is STRICT in both directions and
  the SAME mode again is refused (the source's `same_mode` reads as if
  it succeeds; this build's IGNORE_SAME_MODE is compiled false); a bare
  `-shut` is MULTI where a bare `-online` is NORMAL (mode bits 0x00,
  normalized at DPB-parse time - jrd.cpp:7187 - one file away from the
  validation that would refuse it); FULL refuses every attach except one
  carrying the mode switches themselves; SINGLE holds one attachment and
  even `-online` is a second attach while the slot is held; and a FORCED
  shutdown KICKS - each survivor's next statement answers 08003
  `connection shutdown` / `-Database is shutdown.`, implemented as a
  generation number on the per-file gate because "kicked" is relative.
  `-attach N`/`-tran N` with a stayer fail with `isc_shutfail` and write
  nothing. 42 checks in `qa/serve-real-shutdown.sh`. The locksmith half
  is vacuous here (fcwire authenticates one configured user), and the
  engine counts READ transactions in `-tran`'s wait where fire-crab has
  ids only for writers - both named in the gate.

  *(fifth slice done)* **`-sweep`** - the WRITE half of the garbage
  collection `gc.rs` had only predicted: rolled-back inserts vanish
  whole, rolled-back updates are backed out BY PROMOTION (the back
  version rewritten into the head's slot, delta reconstruction included,
  then judged afresh - a stack of dead versions unwinds one promotion at
  a time), deleted stubs are expunged with their chains, live heads'
  history is collected. An ACTIVE transaction is judged by its LOCK -
  `DbLocks::transaction_is_held` asks the same table the real waits
  arbitrate on - and a stale one is marked dead on the way. Measured
  first on a fire-crab file swept by the live engine: the TIP's dead
  entries STAY dead (a sweep advances OIT past them, it does not rewrite
  history), and OAT/OST land at next. Fail-closed per chain with the
  ORDER as the guarantee (promote before free), and blob-carrying
  relations left whole - the blob walk is its own slice, asserted as a
  difference in `qa/serve-real-gfixsweep.sh` (13 checks).

  *(sixth slice done)* **`-v [-full] [-n]`** - the page walk behind
  validation, and the discovery that made it urgent: fcwire SKIPPED the
  sixteen info items gfix reads its counters from, so `gfix -v` against
  fire-crab printed the same silence a clean file gets - a validation
  that could not fail. The taxonomy was measured one corruption at a
  time and is held BYTE-IDENTICAL on the same corrupted file: a broken
  data page is one error and no warning, a broken pointer or btree page
  is one error plus one warning, a mad record directory is one data-page
  error per page, a back pointer past EOF fails the attach with the I/O
  vector under -full and is silent under plain -v, and a broken TIP
  fails the attach with the corruption vector naming the page and both
  type names - found through RDB$PAGES read STATE-BLIND, since the
  transaction states are what the wreck took away. The SCN cascade is
  the recorded boundary (engine 296, fc 1). 12 checks in
  `qa/serve-real-validate.sh`.

  **The limbo switches are DONE, and two-phase commit under them**
  (`qa/serve-real-limbo.sh`, 13 checks, its client compiled from
  qa/fb2pc.c because isql cannot speak 2PC): op_prepare/op_prepare2
  write tra_limbo to the disk and the detach cleanup leaves a prepared
  transaction alone; op_reconnect + commit/rollback resolve it, which
  is all gfix -commit/-rollback/-list are; a reader meeting a limbo
  record raises isc_rec_in_limbo naming the transaction, gbak dies on
  the same law, and a statement under a prepared transaction refuses
  with the limbo intact. The COUNT(*)/index/DML boundaries closed in
  the increment after (gate 13 -> 20): every reader path raises, and
  the index raises exactly when it READS the limbo record - a probe
  away from its key answers, measured both ways. Still recorded: the
  TDR description is set aside; a DDL transaction's prepare refuses
  (its undo is an in-memory image).
  With this, EVERY gfix FAMILY the tool ships is either converted or
  typed-refused.

  **nbackup as a service is DONE for level 0**
  (`qa/serve-real-nbackup.sh`, 15 checks): `isc_action_svc_nbak`/`nrest`,
  the only road a physical backup can reach any server by (direct
  `nbackup -B` refuses remote paths and bare paths attach the embedded
  engine). The consistency the engine engineers with BEGIN/END BACKUP
  and the delta file, fire-crab's buffer pool has by construction - the
  backup is one read of an `Arc` that cannot change under it. Two
  measured teeth marks: a level-0 `.nbk` must carry the
  `HDR_backup_guid` clumplet or `nbackup -R` refuses it, and the
  client polls output with line + stdin TOGETHER, the stdin answered
  numeric 0. The incremental chain (level > 0, SCN tracking, the main
  header's backup GUID, `RDB$BACKUP_HISTORY`) is the recorded boundary.
  **gbak as a service: the WRITER's first slice is DONE**
  (`qa/serve-real-gbak.sh`, 19 checks): `crates/burp` writes a `.fbk`
  the REAL `gbak -c` restores - the format pinned byte-by-byte from an
  annotated real file before the writer existed, and the first output
  restored on the first try. The surface is FAIL-CLOSED (a database
  holding anything the writer cannot carry - a sequence, view, index,
  trigger, procedure - refuses the WHOLE backup, because a backup
  missing tables is worse than none), plain tables of the five integer
  and text types with NULLs. Measured along the way: an existing .fbk
  is OVERWRITTEN (the opposite of nbackup's refusal law), and `gbak
  -se` speaks an older protocol - the command line rides the version-3
  ATTACH SPB with 0xff separators and the start SPB is a bare action
  byte. **The RESTORE half is DONE**
  (`qa/serve-real-gbakrestore.sh`, 22 checks): the four-way
  cross-restore matrix - engine.fbk x fc-restore, fc.fbk x
  engine-restore, each side round-tripping itself - all read identically
  through the engine, with fc's restore built from its own machinery
  (create_table + insert_record into a fresh shell). NOT NULL rides the
  file BOTH WAYS now (att 38 + the INTEG constraint pair), flipping the
  writer gate's recorded boundary to the equality it promised to become;
  the writer also gained the user-domain refusal it was missing.
  **PK/index records are DONE** (gbakrestore 26, gbak 21):
  rec_index + the PRIMARY KEY rel_constraint ride the file both ways,
  with the build order as part of the law - rows first, indexes
  backfilled after, because dml::insert_record does no index
  maintenance and the other order leaves empty indexes over full
  tables. UNIQUE / FOREIGN KEY / CHECK constraints still refuse, typed.
  **Blobs are DONE** (gbakrestore 29): the
  blobs-first row reordering, att 9 as the blob's SUB_TYPE, the quad as
  XDR's view of blob_id_bytes, rec_blob's u16-framed segments after a
  bare data tag, NULL blobs as absence - all measured, and the restore
  writes through blb::create_blob so a 30 KB blob grades to a real
  multi-page level rather than refusing.
  **The -se command-line protocol is DONE** (serve-real-gbakse.sh):
  the version-3 attach SPB (u32 lengths), the 0xFF-wrapped command
  line (UtilSvc.h:159), the bare action byte in op_service_start, the
  reversed restore positionals - argv mapped onto the same cores, with
  unknown switches (and -r, whose overwrite-ness is a guess) refusing
  the whole action.
  **Verbose streaming is DONE** (serve-real-gbakverbose.sh, 14) - and
  with it EVERY NAMED gbak SLICE. The commentary is deterministic and
  differential: backup streams byte-equal on the same source modulo
  the privilege records fire-crab does not write; restore streams on
  fire-crab's own fbk BYTE-IDENTICAL between the two servers. Matching
  the stream taught two file laws the writer now keeps: data blocks in
  reverse creation order, constraints in catalog order under their
  real names. Still refused, each its own recorded boundary: verbint,
  skip/include-data, factor/length/parallel, stdout/stdin streaming,
  -r/-recreate.

## A savepoint is a transaction (done)

This was the named architectural next step, and it is the one that
changes what the server IS rather than what it answers.

**The problem.** Every undo in this server was *put the image back*. It
worked, and for a transaction it was even cheap once snapshots became
refcount bumps - but it has three properties nothing can fix from
outside:

1. the image was taken **before the window's first write**, so another
   attachment committing inside the window is undone by putting it back
   (which is why an open savepoint had to HOLD the write side, and why
   nobody else could write while one was open);
2. it undoes a window by undoing the FILE, so anything that must survive
   the undo has to be carved out of it by hand - which is what the
   generator windows do, and what the autonomous block's `auto_pages`
   do, and each carve-out is a place to get the width wrong;
3. it cannot express *undo part of this transaction*, because one
   transaction id has one state.

**The mechanism, which was already there.** A transaction's rollback had
stopped being an image two days earlier: `tra_dead` in the TIP, two bits, and
every reader walks past a version whose transaction it does not count to
the one behind it. The version behind a savepoint's write **is** the
pre-savepoint value of the row. So an undo window only needs an id of
its own:

- each window that installs its writes as it goes - a `SAVEPOINT`, a
  PSQL body, `INSERT ... SELECT`, an `IN AUTONOMOUS TRANSACTION` block -
  reserves a nested id at its **first record write** (a window that
  writes nothing costs nothing, and a single-statement window never
  reserves one at all: its undo is dropping a working copy);
- undoing the window is `tra_dead` on that id;
- closing it successfully hands the id to the window around it, because
  the rows are the transaction's uncommitted work still;
- COMMIT flips **every** id the transaction holds in one work copy and
  one flush, so no other attachment can read half a commit.

Visibility therefore stopped being one number: `fire_crab_ods::tra::OwnTx`
is the set a reader counts as its own, and an AUTONOMOUS window stops
the walk INCLUSIVELY - which is where the engine's "a block cannot see
the uncommitted rows of the transaction around it" now comes from,
instead of a special case.

**What it lifted.** Both boundaries the autonomous slice recorded: a body
that had already written before the block, and a block inside a block.
Both are ordinary differential checks now, each held by the DIVISION it
turns on - the failed body's own UPDATE goes back, the block's INSERT
stays; the inner block commits, the outer one dies.

**What still needs the image, and why that is right.** DDL. A catalog row
here is settled as it is written - this server's DDL is not
transactional - so no transaction state can take it back.
`Database::ddl_undo` says an undo needs the image; `Database::image_undo`
now says only *hold the write side, because an image may still be put
back*. A savepoint sets the second and not the first: it keeps its base
image as the fallback for a transaction that later does DDL, and pays the
write side for it. Removing that last cost means making the fallback
image safe to take LATE, which is its own question.

**What was found on the way**, all of it by the gates rather than by
reading:

- **A writer must count the transaction's WHOLE set of ids.** A row
  inserted before a mark carries the transaction's id and the mark's
  rows a nested one, so a uniqueness check that consulted only the id it
  was writing under could not see the earlier row - and would accept a
  duplicate primary key. Asserted in both directions now: the key of an
  undone window can come back, the key of a pre-mark row cannot.
- **A statement after the undo must read the VISIBLE version.**
  `SET V = V + 1` after a `ROLLBACK TO` computes from the version behind
  the dead one (6) and not from the dead one (21). It was already right -
  `collect_dml_targets` carries the visible image - but nothing said so
  until this gate did.
- **Two ways to lose a nested id, both caught in the first gate run.**
  Window 0 IS the transaction (its records carry the transaction's own
  id, or every statement burns one), and the ids must live somewhere the
  window stack's reset at COMMIT cannot take with it - the reset ran
  BEFORE the transaction ended, so a committed batch of 200 rows read
  back as 2. Both are the same shape of bug: *an id nobody flips*, and
  its symptom is rows that quietly stop counting.

**Recorded divergence.** A writing window burns a transaction id the
engine does not: the engine's savepoint has no id of its own, so
`hdr_next_transaction` advances further here than there for the same
work. Nothing a client reads through SQL depends on it (fire-crab's
`CURRENT_TRANSACTION` was already "the header's next id + 1" rather than
a transaction-long constant), but `gstat -h` counts differently and that
is worth knowing before it is discovered. It also reaches the end of the
TIP chain sooner - this server cannot GROW that chain, and
`tip_bits_at` answers "transaction id beyond the TIP chain" rather than
writing outside it, so the limit fails closed. On an 8 KB page that is
some 32,000 ids, which no gate approaches; a workload that opens a
savepoint per statement would.

**What it opened, and what then walked through.** Snapshot isolation was
the interesting gap the moment a reader counted a SET of transactions —
one step from a reader that counts *the set as of a moment* — and that
step is TAKEN. `op_transaction` parses the TPB, an explicit
`isc_tpb_concurrency` (the engine's and isql's default) captures a stable
`ods::tra::Snapshot`, and the visibility readers (`visible_version_2pc`,
`visible_exists_2pc`, `visible_rows_2pc`) take it: a version is visible iff
its transaction was committed as of the snapshot's start. That closed
`serve-real-autonomous.sh`'s last recorded boundary — the outer
transaction reading what its own block committed, engine 0 and now
fire-crab 0 too — and read committed, wait/nowait, lock-timeout and
`isc_tpb_consistency` (degree-3 table stability) came with it.
`serve-real-snapshot.sh` and `serve-real-concurrency.sh` gate the stable
view directly.

~~*Still waiting on more than a snapshot*: two concurrent writers of the
SAME row and the update-conflict timing are their own measured
slices.~~ — **TAKEN, by the lock manager** ("The lock manager,
participating"): a NO WAIT writer meeting a row another active
transaction holds raises the update-conflict at once naming the
blocker; a WAIT writer parks on the holder's transaction lock
(`wait_for_transaction`, capped by `isc_tpb_lock_timeout` or the
server's own wait) and retries when it ends; a cycle is denied as the
engine's deadlock. `serve-real-concurrency.sh` pins the whole family
with coverage counters (writers queued, parked, a cycle denied) beside
the behaviour checks, and `serve-real-updateconflict.sh` pins the
snapshot-over-commit vectors.

**DONE — a reader meeting a LIMBO record delivers the settled rows
first.** The one behaviour `serve-real-limbo.sh` had recorded as a DIFF:
the engine streams a scan per row, so `SELECT` over a table holding a
limbo record prints the settled rows and THEN raises *record from
transaction N is stuck in limbo* — while `StreamCursor::next_batch` hit
the limbo record mid-batch and returned the error, DISCARDING the rows
already built into the batch. The cursor now hands the partial batch
back and holds the error (`pending_err`) for the next fetch, which is
exactly the order the engine's own wire conversation has. limbo
19/1 -> 20/0.

**DONE — the OIT/OAT/OST bookkeeping `gstat -h` reads.** The three
"Oldest" header fields froze at whatever the engine left in the file;
`ods::dml::update_oldest` now maintains them by the engine's own law
(probed scenario by scenario with gstat -h against a live engine): OIT
is recomputed at a transaction's START only — the starting transaction
is itself active, so after an all-committed history it lands on the
LAST id, and that transaction's own commit does not advance it past
its own id — while OAT (and OST, the oldest snapshot an active
transaction needs, equal to OAT with every snapshot taken at start)
recompute at start AND end, stepping past dead, limbo and committed
ids. Wired at `begin_active_tx` / `allocate_committed_tx` (start
rules) and `commit_tx` / `kill_tx` / `prepare_tx` / `resolve_tx` (end
rules). Both scans start from the stored values, so the cost is how
far the fields advance, not the id space. THE CLAMP THE FIRST BUILD
LEARNED THE HARD WAY: this server stores `hdr_next_transaction` as the
LAST id assigned where the engine stores the next to assign, and the
engine's validation (pag.cpp: *next transaction older than oldest
active transaction (266)*) reads the fields by ITS convention — an OAT
one past the stored field read as corruption and EVERY engine-side
open of an fc-written file failed (gfix, gbak, isql reads across
eight gates at once). So OAT/OST clamp at the stored field: under the
engine's lens `OAT == stored next` already means "nothing is active",
and the whole display sits one slot from the engine's own by design.
Two recorded divergences, pinned per side in the gate: a rolled-back
writer pins fc's OIT at its dead id (the engine undoes and marks it
COMMITTED — rollback via undo log — so its OIT moves past; fc's
rollback-by-state is the engine's own no-undo path), and a read-only
transaction leaves fc's header untouched (the id is allocated lazily
at first write) where the engine burns ids. New gate
`serve-real-oldesttx.sh` (5): the per-side law triples over
all-committed / dead-final / dead-mid histories, the read-only
no-move, and the OIT <= OAT <= OST ordering the loader asserts.

## How these slices are gated

The existing gates change role. For a conversion slice they are the
deliverable; for these they are the **safety net**: the statement is
"the answers do not move", and the new evidence is that the subsystem is
on the path at all.

So each wiring slice needs a second gate of its own kind:

- a **coverage** check — the subsystem is actually exercised (an index
  scan counter that must be non-zero, a cache hit ratio, a lock
  enqueued), because "wired in but never used" passes every behaviour
  gate;
- and the existing behaviour gates, unchanged, as the floor.

That pairing is the lesson from the increment where eleven gates were
comparing the engine with itself: *a gate that cannot fail is not a
weaker check, it is a source of false confidence*. A wiring slice is
exactly where that failure mode lives.

## Order, and why

R1 first, because the tree is what R4–R7 and W1 all stand on: an index
scan is a row source, a derived table is a row source, and a recursive
CTE is a fixpoint over row sources. Wiring the optimizer into a server
that has no row-source tree would mean building the tree anyway, in the
optimizer's shape, and then again in the planner's.
