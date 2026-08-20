# Changelog

fire-crab has no version numbers yet — the unit of progress is the
**increment**: one converted piece with its differential gate against the
live C++ engine, one commit each. This file groups those increments by
day and theme, newest first. The full per-increment record is the git
history (each commit message carries the differential's numbers); the
deep narrative lives in [docs/qa-and-benchmarks.md](docs/qa-and-benchmarks.md)
and [docs/methodology.md](docs/methodology.md).

Format inspired by [Keep a Changelog](https://keepachangelog.com/); the
categories are the project's own: **Converted** (a new engine behavior,
differential-gated), **Fixed** (a divergence from the engine, and how it
was caught), **Guarded** (a wrong-answer path closed by refusal).

## 2026-08-20 — MERGE

### Converted
- **MERGE** (`Plan::Merge`, StmtNodes.cpp MergeNode): table or derived
  source, ON, MATCHED UPDATE/DELETE and NOT MATCHED INSERT branches with
  AND conditions - the first of the row's kind whose condition holds,
  in declaration order, or nothing; `isc_merge_dup_update` (21000,
  -811) when two source rows reach one target, the statement undone.
  Desugared per source row at execute into the UPDATE / DELETE / INSERT
  planners (the pairs read first against the starting state, the
  engine's one-cursor law); NOT MATCHED renders as `INSERT ... SELECT
  ... FROM RDB$DATABASE [WHERE cond]` so expressions evaluate.

### Fixed
- **An UPDATE over a rolled-back DELETE's stub corrupted the file for
  the engine**: the stub was chained in as a back version - a
  zero-length "full image" the engine took for a record and
  BUGCHECKED on ("wrong record length (183)", vio.cpp:1902). The new
  head links past the stub now (the engine purges the dead version
  before writing). Introduced with the dead-head rule in the DDL
  slice; found by the MERGE probes, pinned as the merge gate's first
  cell.

### Gated
- `qa/serve-real-merge.sh` (new, 17): thirteen `both` cells against
  the engine, the engine reading fc's merged table, gfix, gbak,
  coverage by the trace.

## 2026-08-20 — blob writes over the wire, and RETAIN

### Converted
- **Blob writes**: `op_create_blob(2)`, `op_put_segment`,
  `op_batch_segments`, `op_cancel_blob`; a `blr_quad` parameter binds;
  the temp blob (relation 0, blb.cpp `BLB_temporary`) is materialised
  into the relation's pages at the store (`blb::move`) through
  `crates/blb` (levels 0-2). A temp id opens before the store; an
  all-zero quad is the empty blob; a blob never stored dies with the
  transaction. Before: a blr_quad parameter dropped the connection.
- **COMMIT RETAIN / ROLLBACK RETAIN** as SQL and as ops 50/86
  (tra.cpp retain_context): the handle, the snapshot - now counting the
  retained commits (`Snapshot::committed_own`, TRA_snapshot_state's
  tra_commit_sub_trans) -, cursors, statements, the generator cache and
  the temp blobs stay; every savepoint dies; a retain without work
  burns no id (the tra.cpp:457 fast path, for free from `touched`).
- `isc_invalid_savepoint` (3B000) for a ROLLBACK TO / RELEASE of a mark
  that is not there.

### Gated
- `qa/serve-real-blobwrite.sh` (new, 8): the same node script against
  both servers, then the engine reads fc's blobs (lengths, content, the
  level-1 tail, the binary bytes), gfix and gbak.
- `qa/serve-real-retain.sh` (new, 8): SQL cells on both, the
  two-attachment snapshot law through node's commitRetaining /
  rollbackRetaining, Next advancing only for retains with work.

## 2026-08-20 — first updater wins, and a schema is its transaction's

### Converted
- **First-updater-wins on a relation** (CacheVector.h `newVersion` →
  `isAvailable` OCCUPIED): an ALTER or DROP of a relation another
  ACTIVE transaction holds an uncommitted version of refuses at once -
  no wait, even under WAIT - with the engine's vector
  (`unsuccessful metadata update` / `ALTER TABLE @1 failed` /
  `newVersion: table N is used by transaction M`; a DROP says `table
  id=N busy in another thread`). DML, reads and index DDL beside it
  are unaffected, as measured. The write side is no longer held for a
  DDL transaction's life.
- **Per-transaction schema visibility**: a thread-local reader view
  (`tra::ReaderViewGuard`) set from the attachment's own ids makes the
  catalog readers owner-only - another transaction's uncommitted
  CREATE TABLE is unknown to name resolution - while DDL statements and
  the unique-key check read wide (the second CREATE says "already
  exists"). The shared metadata cache is bypassed by an attachment
  with uncommitted DDL and invalidated at its commit.

### Gated
- `qa/serve-real-ddltx.sh` 22 → 32: nine two-transaction cells driven
  identically against the engine (a background holder, a foreground
  second transaction, ids normalised), the recorded visibility
  boundary now an equality, coverage by the trace's refusals.

## 2026-08-20 — OIT is one below the first interesting id

### Fixed
- **Rolled-back rows came back after the engine's sweep.** fire-crab
  wrote `hdr_oldest_transaction` AT the first non-committed id; the
  engine's `transaction_start` writes it one BELOW (`--oldest`,
  tra.cpp). With a dead final writer D and OIT = D the engine's sweep
  skipped D's versions, advanced OIT past D, and everything below OIT
  is assumed committed - 200 rolled-back rows resurrected. Measured
  with the header patched by hand: OIT = D - 1 and the sweep collects.
  Pre-existing, bisected against the previous commit; found by the
  full sweep (`serve-real-undo`). `update_oldest` applies the rule,
  monotonic like the engine's.
- The recorded "one display slot apart" convention claim was wrong:
  `hdr_next_transaction` is the highest id assigned on both sides.

### Gated
- `serve-real-undo` 16/16 again; `serve-real-oldesttx` rewritten to
  one shared `last = Next` definition - fc and the engine answer the
  same (1 0 0) triple on the committed and dead-final-writer
  scenarios; the dead-mid-writer divergence (engine undoes and marks
  committed, fc leaves `tra_dead`) re-pinned at (2 0 0) vs (1 0 0).

## 2026-08-20 — DDL is the transaction's

### Converted
- **A DDL statement's catalog rows carry the user transaction's id**
  (`Image::ddl_tx`), so ROLLBACK / ROLLBACK TO SAVEPOINT / a failing
  autonomous block undo DDL by transaction state, as the engine does
  (DdlNodes.epp STOREs under the user transaction). The catalog
  readers step past DEAD and LIMBO versions (`catalog_image`); the
  unique-key liveness test is MVCC-aware. The settled residue a
  rollback must undo by hand is journaled per undo window
  (`DdlResidue`: a created relation's storage, a created index's tree
  and root slot, tx-0 `RDB$PAGES` rows) and COMMIT's work is deferred
  (`DdlDeferred`: a dropped relation's pages, a dropped index's
  `irt_drop`) - dfw.epp's shape. Gone: the whole-image undo of DDL,
  the savepoint's write-side hold, the autonomous-over-DDL refusal,
  the `op_prepare`-over-DDL refusal (kept only for a pending DROP).

### Fixed
- **A second DROP after a rolled-back DROP failed** ("target is not a
  live primary record version"): a DELETED head whose transaction is
  dead is now chained over like any version (VIO_modify leaves dead
  versions to the collector).
- **Deferred DDL work lost at COMMIT**: the window stack was
  reset ahead of `commit_tx`; the deferred DDL work is stashed across
  the reset now.

### Gated
- `qa/serve-real-ddltx.sh` (new, 22): same scripts against the engine
  and fire-crab on twin databases, fc's file validated by `gfix -v
  -full` after every section, written into and swept by the engine;
  coverage by the server's own trace.

## 2026-08-20 — the file grows the engine's way

### Converted
- **The page allocator crosses its walls** (`ods::dml::allocate_page`,
  `extend_relation`, `ensure_tip_for`): a relation's SECOND POINTER
  PAGE (`ppg_eof` moved, `ppg_next` linked, the `RDB$PAGES` row
  `DPM_scan_pages` needs), the SECOND PIP at `n·pagesPerPIP − 1`
  minted all-free, the SCN INVENTORY PAGE reserved at every
  `pagesPerSCN·N` and every page's era stamped in ITS slot on the SCN
  page that owns it, and the SECOND TIP minted by the first id of its
  range with its `RDB$PAGES (0, pag_transactions, seq, page)` row.
  Before: "pointer page full" at ~13 MB per table, page 2041 handed
  out as DATA at ~16 MB (an engine `nbackup -B 1` reads the SCN slots
  and would have MISSED fc's late pages), "transaction id beyond the
  TIP chain" at 32,688 ids, "first PIP exhausted" at ~510 MB.
- **`pip_used` is a high-water mark** (`PAG_last_page` sizes the file
  by it; `PAG_release_page` never lowers it) — fc decremented it on a
  release.

### Fixed
- **`DECLARE I INTEGER = 0;` dropped its initialiser** — a `WHILE (I <
  N)` body ran zero times and reported success (found probing the
  growth gate). Initialisers now run as the assignments they are
  (`declared_var_inits`); one outside the surface refuses the body.

### Gated
- `qa/serve-real-growth.sh` (new, 32): fc crosses each wall and the
  ENGINE reads the result (count, `gfix -v -full`, a write of its own
  on the new structure, a level-1 nbackup chain over fc's late pages,
  restored and counted); the engine-grown twin read and extended by
  fc; coverage checks read the page types at the predicted numbers.
- `docs/roadmap.md` rewritten from the survey of what the engine still
  has that fire-crab does not; the old narrative is
  `docs/roadmap-history.md`, with fifteen stale "still to do" claims
  retired in the new file.

## 2026-08-08 — an aggregate says its source's type

### Converted
- **MIN and MAX describe their SOURCE column's type** — over an
  INTEGER they announce 496 LONG, over a SMALLINT 500 SHORT — where
  every `Plan::Scalar` used to announce the fold's own BIGINT (581).
  Measured shape by shape: SUM and AVG genuinely widen to INT64;
  **COUNT is INT64 and the one aggregate the engine announces NOT
  NULLABLE** (580 even); an aggregate inside arithmetic widens. The
  plan carries a `ScalarTy` now, the describe builds from it, and
  **the announced type decides the wire slot** — a MAX that said LONG
  travels in XDR's 4-byte slot, because saying one thing and sending
  another desyncs every driver.

### Gated
- `qa/serve-real-aggdescribe.sh` (new, 8): the SQLDA_DISPLAY lines and
  the fetched rows compared together, per shape.

## 2026-08-09 — no waiting

### Converted
- **TPB NO WAIT** — the last of W4. A WAIT transaction that meets a row
  another ACTIVE transaction holds blocks until that one ends (the lock
  manager, unchanged); a NO WAIT transaction does not block — the
  engine raises the update-conflict AT ONCE, naming the blocker, the
  SAME `deadlock / update conflicts with concurrent update / concurrent
  transaction number is @1` vector as a committed conflict, and the
  same under BOTH isolations (measured). `isc_tpb_nowait` is read from
  the TPB at op_transaction onto the connection's `wait` flag, and
  `with_conflict_wait` short-circuits to `EvalErr::UpdateConflict` when
  it is set instead of dropping the write side and waiting.

### Boundaries recorded
- `isc_tpb_lock_timeout` (wait N seconds, then the conflict) is still
  read as plain WAIT — its own slice.

### Gated
- `qa/serve-real-nowait.sh` (new, 3): NO WAIT under both isolations,
  differential against the engine through a rig that holds one
  transaction's write open while another (NO WAIT) hits the row.

## 2026-08-09 — the write that came too late

### Converted
- **UPDATE conflict under snapshot** — the write half of snapshot
  isolation. A snapshot transaction reads a stable view (the increment
  before), and it may NOT write over a row another transaction
  committed AFTER its snapshot began: the engine answers `deadlock /
  update conflicts with concurrent update / concurrent transaction
  number is @1`, and fire-crab emits the same three-item vector now.
  The rule is uniform — measured across UPDATE-over-update,
  DELETE-over-update and UPDATE-over-a-committed-delete, all the same
  vector — so the check is one place: in the DML target walks, once a
  row matches the filter through the snapshot view, its PRIMARY chain
  head is inspected, and if that head's transaction is committed, not
  the reader's own, and outside the snapshot, the write is refused. An
  ACTIVE (uncommitted) head is the WAIT case still, left to the lock
  manager; READ COMMITTED never conflicts.

### Gated
- `qa/serve-real-updateconflict.sh` (new, 5): the three conflict shapes
  differential against the engine (the concurrent-transaction number
  normalized, since ids differ per server) and the read-committed
  no-conflict; the full sweep proves the DML write path did not move.

## 2026-08-09 — a stable view

### Converted
- **SNAPSHOT isolation** — the engine's default, and isql's, and the
  one fire-crab never had: a transaction sees the database as of its
  START, not the latest committed. Every read before this answered
  read-committed ("what is committed WHEN I read"); now a transaction
  opened with `isc_tpb_concurrency` captures a snapshot at
  op_transaction and holds it — a row another transaction commits
  afterwards stays invisible until a FRESH transaction. `isc_tpb_read_committed`
  keeps the old rule. Measured against the engine with a two-attachment
  rig: SNAPSHOT answers 2 / 2 / 3 (start, after a concurrent commit, a
  fresh transaction), READ COMMITTED 2 / 3 / 3 — fire-crab now matches
  both.
- The snapshot is `(limit, active)` captured from the inventory:
  `limit = hdr_next_transaction + 1` (the field holds the highest id
  ASSIGNED, since `begin_active_tx` hands back that + 1 — an off-by-one
  a fresh transaction's blindness to the last commit caught), `active`
  = the ids still uncommitted below it. A version is visible iff it is
  the reader's own, or committed AND `tx < limit AND tx ∉ active`.
  Threaded through the two visibility walks and carried on the
  connection's `Database`, so every client read inherits it;
  constraint checks stay read-committed (uniqueness sees all committed
  rows, not the snapshot — the engine's rule).

### Boundaries recorded
- A read INSIDE a PSQL body still answers read-committed (the
  autonomous-block-visibility check in serve-real-autonomous.sh holds:
  engine 0, fire-crab 1) — the body path does not yet carry the
  transaction's snapshot, its own slice. Concurrent WRITE conflicts
  (update-conflict, table stability) are unconverted too.

### Gated
- `qa/serve-real-snapshot.sh` (new, 4): both isolations, differential
  against the engine through the rig; the whole 216-gate sweep is the
  proof the shared visibility path did not move (0 DIFF).

## 2026-08-09 — the drop that names what is missing

### Converted
- **The no-meta-update wrapper for a missing DROP** — the irregular
  half the duplicate-CREATE wrapper left generic, and now the whole
  family, all four object types. Each reason is its own shape: an
  EXCEPTION's carries NO name ("Exception not found"), a SEQUENCE's is
  the generator's "@1 is not defined" (isc_gennotdef), a PROCEDURE's
  names it ("Procedure @1 not found", dyn_proc_not_found — the dyn_dup
  formula again), and a TABLE's is a NESTED chain: isc_sqlerr(-607)
  "SQL error code = -607", isc_dsql_command_err "Invalid command",
  then isc_dsql_table_not_found "Table @1 does not exist" (which
  carries the SQLSTATE 42S02 isql prints). All four match the engine's
  full `unsuccessful metadata update / -DROP <VERB> "PUBLIC"."NAME"
  failed / -<reason>` vector. Routed by Plan variant, so a dependency
  refusal ("there are N dependencies") never misfires — it says
  neither "already exists", "not found" nor "is not defined".

### Gated
- `qa/serve-real-metaupdate.sh` 5 → 8 (four duplicate creates, four
  missing drops).

## 2026-08-09 — unsuccessful metadata update

### Converted
- **The no-meta-update wrapper for a duplicate CREATE** — the DDL-error
  family CREATE PROCEDURE and DROP had each hit as a boundary. A
  duplicate is the one reason shape uniform across every object type:
  the engine answers `unsuccessful metadata update / -<VERB>
  "PUBLIC"."NAME" failed / -<Object> "PUBLIC"."NAME" already exists`,
  and fire-crab emits the same three gds items now for TABLE,
  EXCEPTION, SEQUENCE and PROCEDURE. isql renders identical text AND
  the same SQLSTATE (42S01 for a table, 42000 otherwise), because the
  SQLSTATE follows the reason code — the dyn_dup_* family, whose codes
  follow the probed `dyn_dup_table + (dyn# − 132)`, checked against
  `dyn_dup_index`.

### Boundaries recorded
- DROP of a missing name still refuses with fire-crab's generic vector:
  the drop reasons are irregular per type (a table "does not exist"
  behind -607, a sequence "is not defined", an exception/procedure
  "not found"), unlike the uniform duplicate — their own slice.
- The engine executing an fc-AUTHORED procedure still crashes its
  loader; investigated further this round (the catalog is byte-identical
  bar RDB$DEBUG_INFO, and a non-null debug blob did not settle it —
  fc-authored triggers already execute on the engine, so the debug
  format is not the cause), and it remains a deeper slice.

### Gated
- `qa/serve-real-metaupdate.sh` (new, 5).

## 2026-08-09 — drop, then create again

### Converted
- **`DROP PROCEDURE`**, and the systemic fix it uncovered. The drop
  itself mirrors the engine — the RDB$PROCEDURES row, the parameter
  rows, each parameter's invented RDB$n domain, the security class and
  the owner grant, and a fail-closed refusal for a name any
  RDB$DEPENDENCIES row still depends on.
- **A dropped catalog object can be CREATEd again under the same name
  — for EVERY object type.** fire-crab could re-create none of them:
  "duplicate key in unique index", because a delete leaves its index
  entry for the GC to clear (the engine works the same way) and the
  unique-index INSERT refused against that ghost without asking whether
  its record was still live. `btw::recno_is_live` now answers that —
  the engine's own duplicate scan skips deleted versions — so a
  conflict counts only against a live row. A genuine duplicate still
  refuses.

### Boundaries recorded
- `DROP PROCEDURE` of a missing name, and a duplicate CREATE, refuse
  on both servers but with fire-crab's generic vector where the engine
  ships its no-meta-update wrapper — the same DDL-vector family no
  statement carries yet.

### Gated
- `qa/serve-real-dropcreate.sh` (new, 8): drop-and-recreate cycles for
  exception, sequence, table and procedure, the re-created objects
  taking rows and running, and the live-duplicate refusal that proves
  the fix did not open the door.

## 2026-08-09 — CREATE PROCEDURE

### Converted
- **`CREATE PROCEDURE`**, the roadmap's standing "not supported at all"
  — every PSQL gate before this built its procedures with the engine.
  The hard half already existed: `dsql::compile_procedure`, the DSQL
  BLR oracle, was never wired to DDL. Exposed as
  `compile_procedure_full` (the BLR plus the catalog metadata, None
  exactly when the compiler refuses, so the DDL surface and the oracle
  cannot drift), it now feeds `ods::create_procedure`, which writes the
  RDB$PROCEDURES / RDB$PROCEDURE_PARAMETERS / RDB$FIELDS rows an
  engine-created procedure leaves — id from the RDB$PROCEDURES
  generator, an invented RDB$n domain per parameter, PROCEDURE_TYPE 1
  when a SUSPEND makes it selectable.
- **The stored `RDB$PROCEDURE_BLR` is BYTE-IDENTICAL to the engine's**
  for the same DDL, checked in the gate through the blob reader; the
  gate spans FOR-SELECT, input/output, expression-body and
  text-returning procedures, all creating and running with rows equal
  to the engine's.

### Boundaries recorded
- The ENGINE executing an fc-AUTHORED procedure crashes its own
  metadata loader — the BLR is identical and fire-crab runs the
  procedure, but the engine's executor wants more of the catalog than
  this writes (an undiagnosed field beyond RDB$FIELD_PRECISION, which
  matching did not settle); a deeper metadata-fidelity slice of its
  own. A duplicate `CREATE PROCEDURE` refuses on both, but fire-crab's
  vector is generic where the engine ships its no-meta-update wrapper —
  the same wrapper no DDL failure carries yet.

### Fixed
- A unit test asserting a text CHECK refuses (`CHECK (A > 'x')`) —
  stale since the CHECK-surface increment lifted exactly that, and
  masked at the time by a summary that summed the failure line's
  passed-count; it asserts the compile now, with a cross-class
  comparison still refusing.

### Gated
- `qa/serve-real-createproc.sh` (new, 10).

## 2026-08-09 — the check learns three more words

### Converted
- **CHECK constraints take TEXT, NULL and BIGINT comparisons** — and
  the INLINE column-level form, which turned out to be the real wall:
  the first text probes looked like a type refusal and were a PARSE
  gap (`V VARCHAR(5) CHECK (...)` never split the clause off the
  column; it desugars to the table-level constraint now, parens
  balanced so a type's own don't fool the split). The stored text
  literal is GOLD-PINNED from an engine-created CHECK — `blr_literal
  blr_text2, charset u16 LE, length u16 LE, bytes` — replacing the
  guessed blr_text shape that had rightly stayed guarded; blr_int64's
  scale-plus-8LE emission is engine-gold-confirmed on the way. The
  compile gate types comparisons by class (Int/Text/Null, Null pairing
  with anything); enforcement already ran through the ordinary
  predicate machinery.

### Gated
- `qa/serve-real-checktext.sh` (new, 13), ending on the strongest
  oracle this suite has: **the ENGINE enforcing fire-crab's stored
  trigger** — rejecting a violating INSERT with its own 23000 vector,
  through fire-crab's file.

## 2026-08-09 — the comment inside the statement

### Converted
- **Comments INSIDE a statement** — the between-statements walk
  learned comments long ago (a body-ending comment refused everything
  once), and this is the same disease at the next depth: the text
  between semicolons went verbatim to sub-parsers that do not know
  comments, so `A = 1 /* one */ + 1` refused the whole body. One
  literal-aware stripper now runs at the statement slice and at the
  IF/WHILE condition slice — a quoted `--` or `/*` stays data.

### Gated
- `qa/serve-real-psqltext.sh` 19 → 24.

## 2026-08-09 — a number bigger than the lexer

### Converted
- **BIGINT literals in PSQL** — `A = 3000000000` refused the whole
  body, because `ETok::Num` was an i32. The lexer reads i64 now, and
  the parser picks THE NARROWEST LITERAL THAT HOLDS THE VALUE:
  everything in i32 range stays `IntLiteral` — every stored shape
  keeps its exact BLR bytes — and only an out-of-range value takes
  `Int64Literal`, whose `blr_literal blr_int64` emission is the very
  shape the BLR executor already decodes out of engine-written bodies
  (scale byte, then 8 LE bytes — pinned by symmetry). Assignment,
  comparison, arithmetic, negatives, embedded-DML WHERE and the DSQL
  path all match the engine; the CHECK-constraint surface still
  refuses a big literal, as it refused before (its own recorded
  family, alongside text and NULL comparisons).

### Gated
- `qa/serve-real-psqltext.sh` 16 → 19.

## 2026-08-08 — the grouped half, and the subquery's flag

### Converted
- **The other half of the aggregate-describe entry.** Grouped MIN/MAX
  carry their source column's type (the grouped select-item arm typed
  every int source as INT64 where a text source already used
  `wire_for` — the int arm does now too); grouped COUNT drops the
  Nullable flag exactly as the lone form does. And a WHOLE-ITEM
  scalar subquery lends the outer column its announced type — the
  fold-to-literal kept the value and lost the type, so the fname
  patch loop carries the sub-plan's `ScalarTy` across the re-plan —
  with one measured refinement: **a subquery result is ALWAYS
  nullable, even COUNT**, because no row answers NULL.

### Gated
- `qa/serve-real-aggdescribe.sh` 8 → 16: the grouped four, HAVING,
  and the three subquery-in-projection shapes.

## 2026-08-08 — an argument in its own words

### Converted
- **Text arguments to procedures**, lifting the previous increment's
  boundary. The obstacle was never the types — it was the SPLIT:
  `PT('a,b')` carries a comma INSIDE the literal, and both call sites
  read arguments with a naive `split(',')`. A quote-aware tokenizer
  (`parse_call_args`) now serves both shapes: NULL, integers, 'text'
  with the doubled-quote escape, and `?` where placeholders are legal.
- **The binding is shared by BOTH executor paths** (`bind_proc_args`,
  used by the stored-BLR runner and the source interpreter — or the
  two would disagree about one call), and it keeps the measured laws:
  a CHAR parameter PADS its argument to declared width; an overlong
  one raises the LOCATIONLESS 22001 truncation vector naming expected
  and actual lengths; NULL passes into any type; a CROSS-TYPE argument
  refuses where the engine would convert ('12' into an INTEGER
  parameter) — a conversion this surface has not measured.
- **A selectable body's error is ANNOUNCED, then RAISED AT FETCH** —
  the engine runs those bodies lazily, so the column header goes out
  before the vector (measured with the truncation raise). The execute
  arm defers a typed body error into the cursor
  (`Plan::RefusedEval` now raises its OWN vector at the fetch instead
  of collapsing to a generic conversion error); `EXECUTE PROCEDURE`
  raises immediately, as the engine does — no cursor, no deferral.

### Gated
- `qa/serve-real-procdescribe.sh` 7 → 13: the input-refusal boundary
  FLIPPED to a binding check, plus the comma-in-literal, escape,
  CHAR-pad (raw bytes), both truncation shapes, and the cross-type
  refusal boundary.

## 2026-08-08 — a procedure says what it declared

### Converted
- **Procedure output parameters describe their DECLARED types.** Every
  output was announced as BIGINT (581/8): the values agreed, the
  widths a client renders did not — visible the moment a procedure has
  two output columns. `proc_out_col` now rides `wire_for`, the same
  descriptor-to-wire mapping every table column uses, for both the
  `SELECT * FROM P` projection and the `EXECUTE PROCEDURE` describe —
  isql output is byte-identical to the engine's, underlines included.
- **TEXT output parameters ride now** — the interpreter's variables
  have been Value slots all along, and the loader's int-only check
  predates the text increments. Text INPUTS stay refused: the call
  sites parse integer literals and NULL, and a silently coerced text
  argument would be a wrong answer (recorded boundary).

### Fixed
- RDB$FIELD_LENGTH is the PAYLOAD; a record descriptor's VARYING
  length carries the 2-byte count word on top, and the describe
  subtracts it back — without the normalization in `domain_desc` a
  VARCHAR(7) output announced as 5 and isql drew the column a width
  short. Caught by the first differential render.

### Gated
- `qa/serve-real-procdescribe.sh` (new, 7): mixed-type outputs
  byte-identical through both call shapes, projections and aliases
  keeping their columns' types, the text-output round trip, and the
  text-input refusal.

## 2026-08-08 — NULL is a value the keyword can say

### Converted
- **`B = NULL` — assigning the NULL keyword** — the gap the text
  increment recorded. `Expr::NullLiteral`, whose BLR is the one
  already-probed byte (`blr_null`, 45 — the same byte the engine's own
  DECLARE null-init assignments carry, which this emitter has written
  since triggers were converted). Assignment to text and integer
  variables, comparison with the keyword (UNKNOWN — the IF skips), and
  propagation through arithmetic all match the engine; the CHECK
  surface keeps refusing NULL comparisons by rank, as it always did.

### Gated
- `qa/serve-real-psqltext.sh` 12 → 16.

## 2026-08-08 — text meets the condition

### Converted
- **Text comparisons in PSQL conditions** — `IF (B = 'x')` and its
  family, found refused by the SELECT INTO gate's first draft. `Expr`
  gained its first non-arithmetic node (`TextLiteral`), the condition
  evaluator compares text the way the engine does — **PAD SPACE**,
  measured: `'x' = 'x '` is TRUE, both sides space-padded to the
  longer and the bytes decide; case-sensitive under NONE; ordering is
  the same padded byte order; a NULL operand is UNKNOWN. Variables
  against literals, variables against variables, mixed freely with
  integer conditions, and an embedded UPDATE's WHERE takes text too
  (it renders through the ordinary planner).

### Guarded
- **A text literal has no probed BLR**, so a body carrying one is
  INTERPRETED, never stored: `body_has_uninterpretable_blr` now
  inspects conditions and assignment/store expressions, and the CHECK
  constraint surface stays int-only by rank — a `CHECK (V = 'x')`
  refuses exactly as it always did. (The re-routing this caused —
  `B = 'x'` now parses as a plain assignment instead of the AssignText
  special case — runs through the same interpreter arm either way; all
  seven PSQL gates held.) Found and recorded: `B = NULL` — assigning
  the NULL keyword — is still outside the surface, its own slice.

### Gated
- `qa/serve-real-psqltext.sh` (new, 12): the seven comparison laws,
  the quote escape, the mixed-condition and embedded-UPDATE shapes,
  and the CHECK boundary.

## 2026-08-08 — the static singleton

### Converted
- **`SELECT ... INTO :v[, :v];` inside a body** — the dynamic form
  (`EXECUTE STATEMENT ... INTO`) had the fetch contract already; the
  static form was outside the surface, and its laws are NOT the
  dynamic form's, each measured first. A match assigns every value,
  NULLs included; no match leaves the slots alone; several rows raise
  21000. The divergences: **the static form SETS `ROW_COUNT`** (1 on a
  match, 0 on none) where the dynamic form leaves it at the last
  static statement's count, and **an arity mismatch is the -313
  "count of column list and variable list do not match" vector**
  (SQLSTATE 07002), not the dynamic 42000 — judged against the PLAN's
  projection, so an empty result still refuses a mismatched list. The
  engine raises the -313 at PREPARE of the block; this server's source
  interpreter raises the same LOCATIONLESS vector when the statement
  runs — the moment is the recorded difference, never the message.
- Parsed in the statement walk: the INTO clause is last in the
  engine's grammar and illegal inside a subquery, so the split point
  is the last paren-depth-0 INTO of the literal-masked text; the query
  goes down the ORDINARY planner, so joins and expressions come free.

### Gated
- `qa/serve-real-selectinto.sh` (new, 8): all five laws differential
  via EXECUTE BLOCK, the variables observed through conditional
  exception raises (blocks with RETURNS and `:var` in INSERT VALUES
  are outside the block surface — and a TEXT comparison in an IF
  condition turned out to be too, found by this gate's first draft).

## 2026-08-08 — every reader meets the limbo law

### Converted
- **The paths Inc429 recorded as boundaries, closed.** COUNT(*) (both
  the header-count fast path and the filtered fold), MIN/MAX/SUM, the
  UPDATE/DELETE target walks (measured: even an UPDATE of a SETTLED
  row raises when its scan walks into a limbo record, and a DELETE
  that matches nothing raises the same way), and the INDEX-driven
  retrieval - where the law has a finer grain, measured both ways:
  **the index narrows what is READ, and limbo raises only when a named
  record is read.** A probe away from the limbo key answers normally;
  a probe at it, or a range crossing it, raises. That is exactly W1's
  sentence ("an index narrows what is READ and never what is
  ANSWERED") meeting the two-phase law.
- The scalar fold ships the TYPED vector through a new [ScalarErr]:
  a lone aggregate computed at fetch raises `isc_rec_in_limbo` naming
  the transaction instead of answering NULL or falling back.

### Gated
- `qa/serve-real-limbo.sh` 13 → 20: COUNT / MAX / UPDATE-of-settled /
  no-match-DELETE compared against the engine verbatim (ids
  normalized), and the three index shapes - away, at, crossing.

## 2026-08-08 — a transaction that survives its own death

### Converted
- **Two-phase commit, and the LIMBO it leaves.** `op_prepare` (32) /
  `op_prepare2` (51 — the form the client always sends, the TDR
  message set aside like a privilege record): every id the transaction
  wrote under goes to `tra_limbo` ON THE DISK, and the detach cleanup
  now leaves a prepared transaction alone — surviving exactly that
  death is what the first phase promises. A no-write prepare reserves
  an id and goes to limbo too (measured). `op_reconnect` (33) picks a
  limbo id back up — the id rides VAX/LE in the TPB slot — and the
  commit or rollback that follows IS the resolution, which is how
  `gfix -commit`/`-rollback` work unchanged; `gfix -list` reads
  `isc_info_limbo` (16), one cluster per id.
- **A reader that MEETS a limbo record RAISES** `isc_rec_in_limbo`
  naming the transaction — the row is neither there nor not-there
  until somebody resolves it, and walking past would be a silent wrong
  answer. The strict walk lives in `ods::tra` (`visible_*_2pc`); the
  scan paths (row-source TableScan and the legacy emit walkers) stop
  on the hit and ship the typed vector; settled rows BEFORE the limbo
  record still arrive, exactly as the engine delivers them. gbak dies
  on the same law (`SpecialErr::Limbo`), and a statement under a
  PREPARED transaction refuses with "no transaction for request",
  the limbo surviving the refusal.

### Guarded
- Reconnecting an id that is NOT in limbo answers the engine's own
  pair: "transaction is not in limbo" + "transaction @1 is in an
  ill-defined state". A DDL transaction's prepare refuses — its undo
  is an image in this process's memory, which cannot survive the death
  limbo promises to survive. Recorded boundaries: the COUNT(*) fold
  and an INDEX-driven scan do not detect limbo yet (natural scans do),
  and the TDR description is not stored (gfix -list shows the bare
  line).

### Gated
- `qa/serve-real-limbo.sh` (new, 13): isql cannot speak 2PC, so the
  gate compiles its own client (`qa/fb2pc.c`, libfbclient) and runs it
  against BOTH servers — prepare-and-die, gfix -list, info clusters,
  the reader raise (byte-compared modulo the id), the gbak death, the
  statement refusal, resolve by commit and by gfix -rollback, and the
  bad-reconnect pair. Skips when no cc/libfbclient.

## 2026-08-08 — the commentary is part of the protocol

### Converted
- **gbak's VERBOSE stream, both directions and both transports.** With
  `-v` (a bare `isc_spb_verbose` after the action byte on the -se
  route, the tagged clumplet on fbsvcmgr's) the service streams gbak's
  own lines through `isc_info_svc_line` polls — the machinery the
  nbackup gate already proved, fed by commentary the cores now
  produce, phrased from live captures. The framing carries a trailing
  space per line (fbsvcmgr trims it, the gbak client prints it) and
  the LAST line needs its newline too, or its framing space vanishes.
- **The commentary taught two laws of the FILE, and the writer now
  matches both**: data blocks ride in REVERSE creation order (a
  3-table probe: metadata A,B,C — data C,B,A; burp prepends each
  relation to its list and the data pass walks it head-first), and
  table constraints ride in CATALOG ROW ORDER with their REAL names —
  the NOT NULL's column read from RDB$CHECK_CONSTRAINTS' trigger-name
  slot — where the writer had invented INTEG_n names and put the
  PRIMARY KEY first.
- The category headers are UNCONDITIONAL, as the engine's are
  ("writing functions" prints over an empty set) — honest here because
  the surface check refuses any database where those sets are NOT
  empty. Phase markers print unconditionally too ("adding missing
  privileges" rides even a privilege-free restore); per-record lines
  print per record.

### Gated
- `qa/serve-real-gbakverbose.sh` (new, 14): backup streams byte-equal
  on the same source (privilege lines filtered — fire-crab writes no
  privilege records — and the closing byte-count normalized); restore
  streams on the engine's fbk byte-equal (per-privilege lines
  filtered, set aside and counted); restore streams on FIRE-CRAB's fbk
  **byte-identical with nothing filtered**; fbsvcmgr's tagged route
  line-for-line; no `-v` stays silent; `verbint` refuses. The two
  standing gates' recorded boundaries FLIPPED again: "a VERBOSE backup
  is refused" became "a VERBOSE backup streams gbak's closing line".

## 2026-08-08 — gbak -se: the command line in the attach SPB

### Converted
- **`gbak -se`'s command-line protocol.** The oldest of the three gbak
  transports sends no dbname/bkp_file tags at all: the WHOLE COMMAND
  LINE rides the attach SPB as `isc_spb_command_line`, every argument
  wrapped in 0xFF (internal 0xFFs doubled — `addStringWithSvcTrmntr`,
  UtilSvc.h:159) with a space after each, and `op_service_start`
  carries a BARE ACTION BYTE. That attach SPB is **version 3**, which
  widens every clumplet length to u32 LE — the version exists because a
  command line is longer than a byte can say. `SpbAttach` grew the
  version-3 arm, `parse_command_line` undoes the 0xFF wrapping
  (paths-with-spaces intact), and the argv maps onto the same backup /
  restore cores the tagged protocol calls.
- The argv mapping knows the trap in the positionals: a backup is
  `<database> <file>`, a restore is `<file> <database>` — REVERSED — and
  `-c*` / `-rep*` are matched by gbak's own prefix-abbreviation rule.

### Guarded
- Unknown switches refuse the whole action — a dropped switch is a
  backup that means something else. `-r`/`-recreate` stays refused BY
  NAME: its overwrite-ness depends on a following bare `o[verwrite]`
  token, and guessing it either way silently changes whether a database
  is replaced. `-v` refuses (verbose streaming is its own slice), and
  stdout/stdin names refuse as before.

### Gated
- `qa/serve-real-gbakse.sh` (new, 12): `-b`/`-c`/`-rep` through `-se`
  against both servers, cross-restored; the exists-without-`-rep` vector
  byte-compared against the engine's; the `-v`, stdout and `-r`
  refusals. `serve-real-gbak.sh`'s recorded boundary FLIPPED: "gbak -se
  is refused" became "gbak -se backs up too".

## 2026-08-08 — blobs ride the file

### Converted
- **Blob columns in the burp format, both directions.** Three laws the
  reference file taught, each one a silent wrong answer if guessed: **a
  table with blobs reorders itself** — the field records arrive
  BLOBS-FIRST with att 13 carrying the true position, the data rows lead
  with the blob quads and the null flags keep that same order, so the
  restore re-sorts by position while decoding in file order; **for a
  blob the scale slot (att 9) carries the SUB_TYPE**, since scale means
  nothing to a quad; and the quad itself is XDR's view of the on-disk id
  — two big-endian longs of the two little-endian words `blob_id_bytes`
  lays down (relation at 0, recno high byte at 3, low word at 4).
- **`rec_blob` follows its row**: field number (att 3, matching the
  field record's att 22), max segment, segment count, type (segmented /
  stream), then a BARE `att_blob_data` tag and u16-LE-framed segments —
  no att_end on the record at all. A NULL blob writes NO record
  ("It will be restored as null", backup.epp's own comment) — the quad
  is zeros and the flag rides the row. A non-null EMPTY blob is a
  rec_blob with zero segments.
- The writer reads segments faithfully through `blb::read_blob` (a
  stream blob's raw bytes carry no frames, so it ships as one chunk —
  the engine rechunks streams itself and says so); the restore writes
  through `blb::create_blob`, which grades to level 1 and 2 as the
  payload grows — the first build used `dml::insert_blob`, the INLINE
  level-0 form, and a 30 KB blob refused with "blob header larger than
  a data-page slot".

### Fixed
- **The null bitmap is bit-per-descriptor in CREATION order, and the
  emitted column order is not that.** With blobs sorted first, reading
  the bitmap by emitted index made a NULL blob look live — quad 0:0,
  "blob 0:0 unreadable" — and would have flagged the wrong columns null
  on any mixed row. Each column carries its descriptor index now, and
  every null test goes through it.
- `subtype_carried` gained 261: a restored text blob's sub_type lands in
  RDB$FIELDS, where it had silently stayed NULL.

### Gated
- `qa/serve-real-gbakrestore.sh` 26 → 29: the BT fixture — text and
  binary blobs; null, empty, short and a 30000-byte multi-segment blob —
  with a per-blob digest (length, head, tail) compared across all four
  restore combinations.

## 2026-08-08 — keys and indexes ride the file

### Converted
- **`rec_index` and the PRIMARY KEY `rel_constraint`**, both directions —
  lifting the boundary both gbak gates held. The grammar, pinned from a
  real PK-plus-two-indexes file: name(1), segment count(2), inactive(3),
  unique(4), ONE att 5 PER SEGMENT in key order, index type(7 — 1 is
  descending); the indexes sit inside relation_data BEFORE the data
  (burp.h:146's own order), and the PRIMARY KEY constraint names its
  index through att 6.
- **The writer reads the real catalog**: user indexes from RDB$INDICES +
  RDB$INDEX_SEGMENTS (segments ordered by position), PK constraints from
  RDB$RELATION_CONSTRAINTS — all columns resolved by name. The
  constraint check is TYPED now: NOT NULL and PRIMARY KEY ride the file;
  UNIQUE, FOREIGN KEY and CHECK constraints refuse the whole backup (an
  FK needs cross-table restore ordering; a UNIQUE constraint is more
  than its index — dropping either silently changes what the schema
  means). An FK-backing or INACTIVE index refuses too.
- **The reader's BUILD ORDER is part of the law**: rows first, indexes
  after, BACKFILLED — and here the machinery forces what the engine's
  restore chooses, because `dml::insert_record` does no index
  maintenance: an index created before the rows would be EMPTY over a
  full table, which reads as rows silently missing through any indexed
  access. The PK arrives through `alter_table_add_key` (uniqueness and
  NOT NULL enforced as it backfills), the rest through `create_index`.
- Verified beyond row equality: the engine's own planner USES an index
  fire-crab's restore built (`PLAN (T INDEX (IDX_V))` on the restored
  database), and a duplicate key refuses in all four restore
  combinations.

### Gated
- `qa/serve-real-gbakrestore.sh` 22 → 26 checks: the KEYED fixture (PK +
  plain index + two-segment unique index) through the four-way matrix,
  with the duplicate-key refusal and the index list asserted in every
  result; the fail-closed representative is a FOREIGN-KEY fbk now.
  `qa/serve-real-gbak.sh` 19 → 21: the index refusal became three
  constraint refusals (UNIQUE, FK, CHECK), each against the engine's
  success.

## 2026-08-08 — the logical restore: fire-crab reads a .fbk

### Converted
- **`isc_action_svc_restore`** — the read side of `crates/burp`, closing
  the differential the writer opened. With both sides able to back up
  AND restore, the four combinations (engine.fbk × fc-restore, fc.fbk ×
  engine-restore, and each side round-tripping itself) all produce
  databases the ENGINE reads the same rows from — an encoding bug would
  show in one diagonal, a decoding bug in the other. The restore goes
  through fire-crab's OWN machinery: `read_backup` decodes the stream,
  `ddl::create_table` lays the tables into a fresh shell, and every row
  goes through `dml::insert_record` exactly as an INSERT's would, so
  `gfix -v -full` on the result checks that machinery, not a copied
  file.
- **The reader is TOLERANT OF ATTRIBUTES and STRICT ABOUT RECORDS.** An
  unknown attribute skips by its own length — the self-describing
  grammar, and how the engine's restore survives newer files. An unknown
  RECORD refuses the whole restore: some records are bare and some carry
  raw payloads, so mis-stepping the walk turns everything after it into
  nonsense. Privileges are the deliberate exception — parsed, counted,
  set aside (access metadata, not data), the count in the trace rather
  than silent.
- **NOT NULL rides the file both ways now** — the writer emits att 38 on
  the field record plus the INTEG `rel_constraint`/`chk_constraint`
  pair (read from RDB$RELATION_FIELDS null flags), the reader folds the
  pair back onto the columns — so all four restored databases refuse a
  NULL, and the writer gate's recorded boundary flipped to the equality
  it promised to become. The writer also gained a missing surface check:
  a USER DOMAIN refuses (this writer invents its column sources, so a
  named domain would restore as a plain type — data right, schema
  silently changed).
- The create/replace law, measured: a fresh target restores silently; an
  existing one without `res_replace` fails with gbak's own vector —
  `isc_gbak_db_exists` naming the file, then "Exiting before completion
  due to errors" — and with `res_replace` (0x1000) it overwrites. A
  refused or failed restore leaves NO half-restored database behind.

### Fixed
- **A probe that misreads its own pipeline pins the wrong law.** The
  first already-exists probe took `rc=$?` after a `| head`, read 0, and
  the restore was built to STREAM the message as output — the gate
  caught the mismatch against the engine's real rc=1 immediately. The
  same bug the sweep runner had, in a new place; the rc must come from
  fbsvcmgr itself.

### Gated
- **`qa/serve-real-gbakrestore.sh`** (22 checks): the four-way
  cross-restore matrix with the engine as the reader of record;
  `gfix -v -full` on fc's restores; NOT NULL enforced in all four; the
  exists/replace laws byte-compared; the PRIMARY-KEY and garbage-file
  refusals with no half-restored file left; and the privilege omission
  visible in the trace, not silent.

## 2026-08-08 — the logical backup, first slice: a .fbk the real gbak restores

### Converted
- **`isc_action_svc_backup`** — fbsvcmgr's `action_backup` — writing the
  burp format: `crates/burp` (fire-crab-burp), a new subsystem crate
  mirroring `src/burp/`. The format was PINNED BEFORE THE WRITER EXISTED:
  a real FB6 `.fbk` parsed byte by byte — major records (burp.h:84) each
  carrying `[att byte][u8 length][data]` attribute lists ("low byte
  first, as in VAX", backup.epp:put_int32), `rec_relation_end` and
  `rec_end` bare, the order of battle as burp.h:133 documents it. Data
  rows ride `rec_data` in the TRANSPORTABLE encoding: the message
  XDR-canonicalized — numbers big-endian, a VARCHAR as a 4-byte length +
  bytes padded to 4 (a NULL row is SHORTER, not zero-padded — XDR is
  self-describing), one 4-byte null indicator per field TRAILING the
  values — then RLE-compressed with the positive-literal /
  negative-repeat scheme `fire_crab_ods::sqz` already emits.
- **The first fbk restored on the first try** — `gbak -c` accepted the
  writer's output whole, NULLs included — which is what pinning a format
  from an annotated real file buys over guessing from source.
- Verified across SMALLINT / INTEGER / BIGINT / CHAR / VARCHAR, extreme
  values (i64::MIN), NULL rows, multiple tables, and an empty table.
  Domain names are INVENTED (RDB$1, RDB$2, ...): gbak restore binds
  columns to domains by name WITHIN the file, so consistency is all that
  matters.

### Guarded
- **The surface is fail-closed, and that is most of the point.** A backup
  missing tables — or carrying a table where a view was — is worse than
  no backup: the client holds a file it believes is its data. A database
  holding a sequence, view, index (a restored table silently missing its
  PRIMARY KEY is a meaning change), trigger, procedure, exception,
  function or role refuses the WHOLE backup. Each check resolves its
  system relation and its RDB$SYSTEM_FLAG column BY NAME — relation ids
  and field positions are ODS facts to read, not guess (RDB$GENERATORS
  is relation 20, not the 10 a first guess said; and a system relation's
  formats come from the sysfmt bootstrap, not RDB$FORMATS — both caught
  by the probe loop).
- A VERBOSE request refuses rather than answering silence — the gfix -v
  lesson (a report that cannot fail) applied before the failure mode
  ships rather than after. skip_data/include_data likewise.

### Found
- **An existing target is OVERWRITTEN — the opposite of nbackup's law.**
  The engine's action_backup replaces an existing `.fbk` silently where
  its action_nbak refuses one; a converter copying either tool's rule
  onto the other ships it as a bug. Both gates assert their own.
- **`gbak -se` speaks an OLDER protocol**: its whole command line rides
  the version-3 ATTACH SPB as `isc_spb_command_line` with 0xff
  separators, and `op_service_start` carries a BARE ACTION BYTE. That
  protocol (and the stdout-streaming backup it enables) is its own
  slice; until then the shape arrives with no dbname and refuses,
  asserted in the gate.

### Named, not converted
- NOT NULL is not carried (the constraint records rec_rel_constraint +
  rec_chk_constraint are their own slice): a column restored from
  fire-crab's backup accepts NULL where the engine's restore refuses it
  — asserted from both ends, with the data rows agreeing. The RESTORE
  half (fire-crab reading a .fbk) is the front's next slice.

### Gated
- **`qa/serve-real-gbak.sh`** (19 checks): both servers back up THE SAME
  database and the real `gbak -c` restores both, the engine reading the
  same rows from both results; `gfix -v -full` on the restored file;
  point-in-time teeth; five fail-closed refusals each asserted against
  the engine's success; the NOT NULL boundary both ways; the -se and
  VERBOSE refusals; and the overwrite law with the overwritten backup
  carrying the current rows.

## 2026-08-07 — the physical backup: nbackup as a service

### Converted
- **`isc_action_svc_nbak` / `isc_action_svc_nrest`, level 0** — the
  service actions behind `fbsvcmgr action_nbak`/`action_nrest`, and for
  fire-crab they are not a convenience: direct `nbackup -B` refuses a
  remote path ("nbackup needs local access to database file") and a bare
  path attaches the EMBEDDED engine, so the service is the only road a
  physical backup can reach any server by.
- **The consistency the engine engineers, this architecture has by
  construction.** The engine's backup needs BEGIN/END BACKUP around its
  copy because the file changes underneath — the mode diverts writes to a
  `.delta`, the copy reads a frozen file, END BACKUP merges. What that
  buys is a consistent point-in-time image, and fire-crab's buffer pool
  already IS one: a published image is never edited in place, so the
  `Arc` the action takes cannot change however many writers commit while
  the copy runs. The backup is one read of an `Arc`.
- **Measured shape of a level-0 `.nbk`**: the database with
  `hdr_backup_mode` STALLED inside it (the engine's own `.nbk` differs
  from the live file in exactly that byte plus the counters END BACKUP
  advanced afterwards) — **plus the backup GUID clumplet
  (`HDR_backup_guid`, tag 7), which is not decoration: `nbackup -R`
  REFUSES a level-0 file without one** ("Cannot get backup guid clumplet
  from L0 backup"), because the GUID is how a level-1 file later names
  the backup it increments. Found the hard way — the first build's backup
  restored only on databases the engine had already backed up once.
- **Restore is a fixup copy**: `hdr_backup_mode` cleared and a FRESH
  database GUID (the engine writes one on every restore — the restored
  database is a NEW database that happens to hold the same rows).
  `nrest` streams NO output; `nbak` streams the three stat lines,
  byte-identical including the counts.
- **The client polls with `isc_info_svc_line` + `isc_info_svc_stdin`
  together** — and stdin must answer numeric 0 ("no input wanted",
  svc.cpp:1337-1348) rather than being refused: the first build's actions
  succeeded and then reported "feature is not supported", because the
  info query after them died on the stdin item.

### Named, not converted
- **The incremental chain — one feature, not three.** A level > 0 backup
  (or `-B <GUID>`) needs SCN tracking, a backup GUID in the MAIN header
  and an `RDB$BACKUP_HISTORY` row — bookkeeping the engine writes even
  for a level-0 backup. fire-crab refuses level > 0 and leaves the main
  file UNTOUCHED by its own backup (the GUID goes into the copy alone);
  the gate asserts both halves of the difference: after the engine's
  nbak the main file gains a history row, after fire-crab's it gains
  nothing.

### Gated
- **`qa/serve-real-nbackup.sh`** (15 checks): the service output
  byte-identical (elapsed time normalized); the CROSS-RESTORES both ways
  — the REAL `nbackup -R` restores fire-crab's backup and fire-crab's
  `nrest` restores the engine's, with the engine reading the rows from
  both results and `gfix -v -full` accepting them; the fresh-GUID law;
  point-in-time teeth (a row written after the backup is not in it);
  refusals onto existing files compared; the incremental boundary; and
  the live database clean after its own backups.

## 2026-08-07 — validation, and what its silence means: gfix -v

### Converted
- **`gfix -v [-full] [-n]`** — `isc_dpb_verify` (tag 9) — as a page walk
  that counts what is broken into the sixteen categories gfix reads back
  through `isc_database_info` (alice/exe.cpp's `val_errors` list, items
  54–60 and 115–123), printing one line per non-zero counter. **A clean
  database is SILENCE — which is what made the unconverted server
  dangerous: fcwire skipped info items it did not know, gfix printed the
  same silence a genuinely clean file gets, and `gfix -v` against
  fire-crab was a validation that could not fail.** The counters are only
  answered when THIS attachment ran a walk: a counter of 0 and no counter
  at all read the same to gfix, but only one of them is a claim.
- **The taxonomy was measured, one corruption at a time**, and held
  byte-identical on the SAME corrupted file (`-n` never writes, so both
  servers can validate one copy): a data page with a zeroed type byte is
  1 "database page error" and NO warning, under `-full` and plain `-v`
  alike; an absurd record directory is 1 "data page error" — per page,
  not per entry; a broken pointer or btree page is 1 error + 1 warning
  (the orphaned subtree is the warning); a record's back pointer aimed
  PAST THE FILE under `-full` is not a count at all — the attach fails
  with `I/O error / File size is less than expected`, because the engine
  reads the page the pointer names — while plain `-v` walks no records
  and stays silent.
- **A broken TIP fails the attach with the corruption vector, naming the
  page and both type names** — `database file appears corrupt / -wrong
  page type / -page 287 is of wrong type (expected transaction
  inventory, found purposely undefined)` — with the page found the way
  the engine finds it: **RDB$PAGES declares the TIP pages**, and the walk
  reads that map STATE-BLIND (chain heads as they stand), because the
  transaction states are exactly what the wreck took away. The type
  names come from the engine's own `pagtype()` table (jrd/ods.cpp:130).
- **The walk takes the catalog route for the same reason**: a pointer
  page whose type byte is gone is invisible to a scan for pointer pages
  — the corruption hides itself from the scan that would report it — so
  relations and their pages come from RDB$PAGES.
- `isc_info_db_read_only` (63) now answers the header's real flag — it
  had been a hardcoded 0 since before the mode existed.

### Named, not converted
- **The SCN cascade**: page 2 zeroed makes the engine fail every
  SCN-consulted check too (296 errors on a 313-page fixture) where
  fire-crab counts the broken page itself: exactly 1. Asserted as a
  boundary with both numbers. And the warning taxonomy is per-relation in
  ways the probes only sampled: a SYSTEM relation's broken data page
  drew a warning where T's did not — the gate corrupts deterministic
  targets (T's own pages, found through RDB$PAGES) for exactly that
  reason. `walk_index_leaves` descends the leftmost path and the leaf
  level, so an interior page off the leftmost path of a deep tree is not
  visited — stated in the code, and every fixture this project can build
  has depth <= 1.

### Gated
- **`qa/serve-real-validate.sh`** (12 checks): the byte-equal cases
  above, the SCN boundary, and teeth that the walk actually RAN (the
  trace line), because the old failure mode — silence that means nothing
  — is precisely what this gate exists to prevent.

## 2026-08-07 — the sweep performed: gfix -sweep

### Converted
- **`gfix -sweep`** — `isc_dpb_sweep` (tag 10) — as the WRITE half of the
  garbage collection `crates/ods/src/gc.rs` has predicted since it was
  converted (`qa/diff-sweep.sh` holds the prediction; the new gate holds
  the performance). `gc::sweep` walks every relation off the pointer
  pages, catalog-free, and per chain: a rolled-back INSERT vanishes whole
  (the slot's directory entry zeroed — the bytes stay, as the engine's
  own lazily-compacted pages do); a rolled-back UPDATE is **backed out by
  PROMOTION** — the back version's image (reconstructed through
  `apply_differences` when the dead head carries `rhd_delta`) is repacked
  under dml's own RLE coin (packed when it shrinks, raw + NOT_PACKED when
  it does not) and rewritten into the head's slot, then the back slot is
  freed, then the NEW head is judged afresh (a stack of dead versions
  unwinds one promotion at a time); a committed DELETED stub is expunged
  with its whole chain; and a live head's history is collected, its back
  pointer cut. One liberty, stated: this server has no snapshots, so the
  oldest-snapshot threshold that gates the engine's collection is always
  "everything" here.
- **An ACTIVE transaction is judged by its LOCK.** `gfix -sweep` skips a
  version whose transaction somebody still holds and backs out one whose
  owner is gone — the engine's own probe is the transaction lock, so
  `DbLocks::transaction_is_held` asks the same table the real waits
  arbitrate on (a no-wait SharedRead probe against the holder's
  Exclusive, dropped either way), not a second bookkeeping that could
  drift. A stale active is marked DEAD in the TIP on the way.
- **Measured laws the shape comes from** (a fire-crab-written file with
  real `tra_dead` entries, swept by the LIVE engine): versions collapse
  to the live count with rows unchanged; **the TIP's dead entries STAY
  dead** — a sweep advances `hdr_oldest_transaction` PAST them rather
  than rewriting history; OAT and OST land at next-transaction. fire-crab
  burns no id, so its postcondition is OIT = OAT = OST = next.
- The read-only refusal is the engine's own pair, measured: "Unable to
  run sweep / -Database in read only state" (`isc_sweep_unable_to_run` +
  `isc_sweep_read_only`).

### Guarded
- **Fail-closed per chain, and the ORDER is the guarantee**: a promotion
  is rewritten into the head slot BEFORE the back slot is freed, so a
  page with no room refuses with nothing half-done. A chain with a
  fragmented member, a LIMBO transaction, a 64-bit id (the 32-bit header
  slot would truncate it), or an unreconstructable delta is left whole
  and counted. A relation whose pages carry BLOB records is left whole
  too — freeing a version without freeing its blobs leaks them, and the
  blob walk is its own slice; the gate asserts the difference against the
  engine, which does collect them.

### Gated
- **`qa/serve-real-gfixsweep.sh`** (13 checks): each server builds the
  same history through ITSELF and sweeps its own file — the BEFORE counts
  legitimately differ (the engine backs a rollback out at ROLLBACK time
  through its undo log; fire-crab's rollback is two TIP bits and its
  garbage waits for the sweep), the AFTER counts must be equal and the
  rows must read identically THROUGH THE ENGINE. Plus the header law read
  offline before any engine attach can move it, dead TIP entries
  surviving, `gfix -v -full` on the swept file, a held transaction's row
  surviving the sweep and committing after it on BOTH servers, the
  read-only pair, idempotence, and the blob boundary.
- Unit tests in `gc.rs` build the four shapes on a synthetic four-page
  file and check the promotion BY BYTES (the rolled-back update reads its
  prior value again), plus idempotence — a second sweep finds nothing.

## 2026-08-07 — the mode ladder: gfix -shut and -online

### Converted
- **`gfix -shut [multi|single|full] -force|-attach|-tran N` and
  `gfix -online [normal|multi|single]`** — `isc_dpb_shutdown` (50, one
  byte: flag bits 0x2/0x4/0x8, mode bits 0x70) + `isc_dpb_shutdown_delay`
  (52) and `isc_dpb_online` (51), over `hdr_shutdown_mode`, the byte at
  offset 25 (none 0, multi 1, single 2, full 3).
- **THE LADDER IS STRICT IN BOTH DIRECTIONS, and the same mode again is
  REFUSED** — measured, and it beats the source: shut.cpp's `same_mode`
  reads as if it silently succeeds ("gbak relies on that"), but this
  build's `IGNORE_SAME_MODE` is compiled false and `gfix -shut multi
  -force 0` twice answers `Target shutdown mode is invalid for database
  "<file>"` the second time. `-shut` must tighten, `-online` must loosen,
  the refusal is `isc_bad_shutdown_mode` with the quotes living in the
  message template, and the header is untouched.
- **The bare spellings differ per direction.** A `-shut` with no mode
  word is MULTI (the legacy `gfix -shut -force 0`); a bare `-online` is
  NORMAL — and it arrives as mode bits 0x00, which jrd.cpp:7187
  normalizes at DPB-parse time rather than refusing. Found the hard way:
  the first build refused plain `gfix -online`, because SHUT_online's own
  switch would too — the normalization lives in the DPB parser, one file
  away from the validation.
- **What each mode refuses at ATTACH.** FULL refuses every attach
  (`isc_shutdown` naming the file) including a non-mode gfix like
  `-buffers` — EXCEPT an attach carrying `-shut`/`-online`, which is how
  the database ever comes back. SINGLE holds ONE attachment: the second
  is refused with the same vector, and even `gfix -online` is that second
  attach while the slot is held (measured — the ladder never gets to
  run). The maintenance attachment can WRITE, because maintenance is what
  the mode is for.
- **THE FORCE KICK.** `-shut <mode> -force 0` succeeds immediately with
  attachments present; each of their NEXT statements answers SQLSTATE
  08003 — `connection shutdown` / `-Database is shutdown.`
  (`isc_att_shutdown` + `isc_att_shut_db_down`) — and the kicked
  attachment stops occupying the single-user slot. Implemented as a
  GENERATION NUMBER on the per-file gate (`DbGate::kick_gen`), because
  "kicked" is relative: an attachment made after the shutdown is governed
  by the header instead, and a second shutdown kicks the survivors of the
  first. The checks sit AFTER each op's payload reads — answering before
  consuming the arguments desyncs the stream (the Inc411 lesson, the
  other way round).
- **`-attach N` / `-tran N` with a stayer fail** with `isc_shutfail`
  ("database shutdown unsuccessful") and write nothing; the successful
  forms kick the stragglers exactly as the engine's closing force-notify
  does. `-tran` waits on the gate's count of OPEN TRANSACTIONS, fed by
  the transaction bookkeeping (`note_tx_begun` at the first adopt,
  released at end).

### Gated
- **`qa/serve-real-shutdown.sh`** (42 checks): the full ladder in both
  directions with every refusal's text compared (file names normalized to
  `<db>` since each server has its own), the offline `gstat -h`
  Attributes line as the header oracle, fifo-held attachments on BOTH
  sides for the single-slot and kick halves, the kicked attachment's own
  next-statement output compared engine-vs-fc, and shutfail leaving the
  header untouched.

### Named, not converted
- The locksmith half (`CHANGE_SHUTDOWN_MODE`, `isc_no_priv`) is vacuous
  here: fcwire authenticates exactly one configured user, so there is
  nobody unprivileged to refuse. The engine also counts READ transactions
  in `-tran`'s wait; fire-crab reserves transaction ids only at the first
  write, so a pure reader does not hold that wait.

## 2026-08-07 — a read-only database, and the switch that makes one

### Converted
- **`gfix -mode read_only|read_write`** — `isc_dpb_set_db_readonly` (tag
  64, a byte) → `hdr_read_only` (0x20) in the header page. The bit was
  never the work; the REFUSAL PATH is, and it is why this switch was left
  for last while the other four header switches landed.
- **THE MODE SWITCH TAKES THE DATABASE EXCLUSIVELY, and it is the only
  gfix switch that does** (`CCH_exclusive`, jrd.cpp:2181). Measured both
  ways against the live engine with an attachment held open: `-write`,
  `-buffers` and `-housekeeping` change the header regardless, `-mode`
  answers `isc_lock_timeout` + `isc_obj_in_use` naming the FILE — and
  answers it **immediately**, not after a wait. New `attachments_for`
  registry, keyed like the buffer pool and the lock table, incremented by
  `load_database` and decremented by `impl Drop for Database` so no error
  path can leave the count too high.
- **...and the check comes BEFORE deciding whether anything would
  change.** `gfix -mode read_only` on a database that is ALREADY
  read-only still refuses while somebody is attached — which is exactly
  the opposite of this server's own "a no-op gfix writes no page" rule,
  and had to be measured rather than assumed.
- **A read-only database refuses every write, in the engine's two vector
  shapes.** The bare `isc_read_only_database` for DML, an identity draw, a
  `NEXT VALUE FOR` and an `EXECUTE BLOCK` that writes (the block adds its
  own `At block line: 1, col: 24` item, which this server's wrapper
  already produced); `isc_dsql_error` in front of it for the DDL the
  engine refuses at prepare — `CREATE TABLE`, `COMMENT ON`, `GRANT`,
  `SET GENERATOR`, `ALTER SEQUENCE ... RESTART`. A `SELECT` still answers,
  and so does `GEN_ID(g, 0)`, the zero-increment READ.
- **`Database::work_copy` is the floor under all of it.** Every write in
  this server goes through that one funnel — records, catalog rows,
  generators, index pages, the header's own clumplets — so refusing there
  means a path added later cannot forget the mode. The typed refusals sit
  in front of it for the two families whose error text the engine
  specifies; `-mode read_write` takes `work_copy_unchecked`, being the one
  write a read-only file must still allow.

### Found
- **The exclusivity this converts is PER PROCESS.** `attachments_for`
  counts the attachments *this server* has; the engine's `CCH_exclusive`
  goes through the lock manager, so it sees attachments in other
  processes too. For fire-crab, whose attachments are all threads of one
  server, the two agree — until a second fire-crab process opens the same
  file, which nothing else in this server is safe for either (the buffer
  pool and the lock table are per process as well). Named so it is not
  mistaken for finished; the converted lock manager is where the
  cross-process version would go.

### Fixed
- **THE CAREFUL FLUSH TOOK ITS OPEN MODE FROM THE IMAGE IT WAS ABOUT TO
  WRITE, so `gfix -mode read_only` refused the very page that says "read
  only".** `plan_for_header` was handed the AFTER image's flags — right
  for forced writes, whose new promise governs this write too, and wrong
  for read-only, which decides whether the process may write the file at
  all. Taking it from the image on disk would have broken the mirror case
  (`-mode read_write` on a file that is still read-only). The rule is the
  TRANSITION: a flush that CHANGES the bit is the switch itself and opens
  read-write; a flush that leaves it set is an ordinary write to a
  read-only file and must not be happening.
- **An attach that could not do what its DPB asked was answering OK.**
  `apply_header_dpb`'s error was traced and dropped — and gfix's exit
  status IS its attach's status, so a refused switch reported success
  (rc=0) while changing nothing. The attach now answers the refusal's own
  status vector and detaches, which is what makes rc=1 mean something.

### Gated
- **`qa/serve-real-readonly.sh`** (34 checks): every law above, with
  `gstat -h`'s Attributes line as the oracle for the bit itself and gfix's
  own rc+output compared side by side; an attachment held open through a
  fifo-fed isql on BOTH servers for the exclusivity half; and teeth that
  the same statements are accepted once the mode is off.
- **Recorded boundaries, asserted:** `ALTER TABLE` and `DROP TABLE` are
  refused INSIDE the engine's metadata machinery and come wrapped in
  `isc_no_meta_update` + "<statement> failed" — and DROP carries the
  Dynamic SQL Error inside that wrapper where ALTER does not. This server
  has no `no_meta_update` wrapper for ANY DDL failure yet, so both shapes
  are held as differences with the engine's exact text in the gate.
  `CREATE VIEW` is outside this server's DDL surface altogether, so its
  refusal is the generic one either way — asserted, so the day CREATE VIEW
  lands, the gate says the read-only vector has to come with it.

## 2026-08-07 — a savepoint is a transaction

### Converted
- **AN UNDO WINDOW IS A TRANSACTION.** Every window that installs its
  writes as it goes — a `SAVEPOINT`, a PSQL body, a row-by-row statement
  (`INSERT ... SELECT`), an `IN AUTONOMOUS TRANSACTION` block — now
  reserves a **nested transaction id** at its first record write, and
  undoing the window is `tra_dead` on that id and nothing else. A reader
  walks past a version whose transaction it does not count to the one
  behind it, which is precisely the pre-savepoint value of the row. That
  is the engine's savepoint model (`tra.cpp`'s undo records,
  `VIO_verb_cleanup`) reached through the one mechanism this server has,
  rather than the record-level surgery the engine's own undo needs.
- **Visibility is a SET of own transactions, not one id.**
  `fire_crab_ods::tra::OwnTx` replaces the `Option<u64>` that
  `visible_version` and `visible_exists` took: a reader counts the
  transaction's own id plus one per undo window that wrote. All of them
  are flipped **in one work copy and one flush** at COMMIT, so no other
  attachment can read a transaction half committed.
- **A block inside a block, and a body that had already written**, both
  of which the autonomous slice refused a day ago. The refusals existed
  because the enclosing undo put an IMAGE back and the page carve-out
  that keeps an autonomous commit would have carried the body's own rows
  forward with it. With a nested id the body's writes are killed by two
  bits and the block's are untouched, so both shapes are answered.
- **`ROLLBACK TO SAVEPOINT` is real** rather than an image restore.
  Which is not only cheaper: an image restore is taken before the
  window's first write, so another attachment committing inside the
  window would be undone by putting it back. Two bits belonging to this
  transaction cannot do that.

### Guarded
- **The image is the FALLBACK, not the rule.** A DDL statement's catalog
  rows are settled as they are written here — no transaction state can
  take them back — so a window that contains one still undoes by
  restoring its base image (`Database::ddl_undo`, kept apart from
  `image_undo`, which now says only "hold the write side, because that
  image may still be put back"). The one shape still refused is an
  autonomous block inside a body that has written **while the
  transaction is on the image path**.

### Fixed
- **A writer must count the transaction's WHOLE set of ids**, not the
  one it is writing under. Caught by asking what the uniqueness check
  reads: a row inserted BEFORE a mark carries the transaction's id and
  the mark's rows carry a nested one, so a check that consulted only the
  statement's id could not see the earlier row — and would have accepted
  a duplicate primary key. The index-maintenance path now builds its
  view from `own_tx()` plus the id this statement reserved.
- **Two bugs the gate caught within a minute of each other**, both of
  the same family — a nested id that nobody flips: window 0 IS the
  transaction (its records carry `Database::tx`, not a nested id, or
  every statement burns one), and the ids have to live somewhere the
  window stack's reset at COMMIT cannot take with it
  (`Database::nested_tx`) — `reset_gen_windows` ran BEFORE
  `end_transaction`, so a committed batch of 200 rows read back as 2.

### Found
- **A writing window burns a transaction id the engine does not.** The
  engine's savepoint has no id of its own, so `hdr_next_transaction`
  advances further here than there for the same work. Nothing a client
  reads through SQL depends on it — fire-crab's `CURRENT_TRANSACTION` was
  already the header's next id rather than a transaction-long constant —
  but `gstat -h` counts differently, and the TIP chain (which this server
  cannot grow) is reached sooner. It fails closed when it is:
  `tip_bits_at` answers "transaction id beyond the TIP chain" rather than
  writing past it. Some 32,000 ids on an 8 KB page.

### Gated
- **`qa/serve-real-savepointtx.sh`** (30 checks): the work before a mark
  against the work after it, for INSERT, UPDATE and DELETE; **a
  statement after the undo reading the RESTORED value** (`SET V = V + 1`
  answers 6, not the rolled-back 21 — a writer that reads the chain head
  instead of the visible version gets this wrong silently); a key
  re-inserted after its window died, and a duplicate of a pre-mark row
  still refused; nested marks, `RELEASE`, a second undo to the same
  mark, a full `ROLLBACK` over them; **a body inside a mark**, whose own
  window's id folds into the mark's (undone with it, committed when it is
  released); DDL inside a mark falling back to the image; log teeth that
  the undo was **state and not an image**; and `gfix -v -full` on the file
  the nested ids were written into.
- **`qa/serve-real-autonomous.sh`** 22 → 30 checks: the two recorded
  boundaries became ordinary differential checks, each with the DIVISION
  it turns on — a body that writes, a block that commits, then a body
  that fails, where the body's UPDATE must go back and the block's INSERT
  must stay; and an inner block that commits while the outer one dies.

## 2026-08-07 — the carrying: event delivery over the auxiliary connection

### Converted
- **The auxiliary connection, end to end.** `op_connect_request` opens a
  listener and answers its sockaddr; the client connects on a SECOND
  socket; `op_que_events` registers an interest from an EPB;
  `op_cancel_events` takes it down; and every delivery is an `op_event`
  frame pushed on that second socket. The frame's event buffer is the
  shape a client parses by hand — a version byte, then per event a name
  length, the name, and the counter as a **little-endian** 32-bit value,
  little-endian inside a protocol that is big-endian everywhere else
  because the engine builds those four bytes itself (event.cpp:885-888).
- **A delivery is written by whichever attachment's COMMIT moved the
  counter** — another connection, on another thread — so the sockets
  live in a per-database registry beside the event table rather than on
  the connection that made them.
- **`EXECUTE BLOCK AS ... BEGIN ... END`**, because the paper's own
  event client posts with one and this server had none. It is the PSQL
  interpreter's surface with the DDL taken away: the block's text IS the
  body, it has no catalog row, and it runs at execute because it may
  write. Its errors carry the engine's own `At block line: L, col: C`
  item — computed from the WHOLE statement text, which a block has in
  hand where a procedure must recover it from `RDB$DEBUG_INFO`.

### Fixed
- **A delivery carries `evnt_count + 1`, not the counter.** `const SLONG
  count = event->evnt_count + 1;` (event.cpp:884). A subscriber to an
  event nobody has posted is told **1**, and the paper's client prints
  `baseline counter = 1` and then `counter=4` after three posts. The
  converted table shipped the raw counter, so it would have printed 0
  and 3 — agreeing on the DELTA, which is exactly what hid it, and
  disagreeing on every absolute number a client sees.
- **A post to a name nobody has ever listened for is DROPPED.**
  `postEvent` looks the name up and does nothing when there is no event
  block (`if (event)`, event.cpp:376); the block is made by a
  SUBSCRIPTION. Measured live: two posts before anybody subscribed left
  the next subscriber's baseline at 1, not 3.
- The fire test is `rint_count <= evnt_count` (event.cpp:303, 388), not
  `<`. That is why a fresh interest at 0 over a counter at 0 fires at
  once, which is what gives a subscriber its baseline.

### Found
- The two counter laws were invisible for as long as they were, because
  the only gate that could see them had to compare **deltas** —
  `qa/evt-semantics.sh` says so in its own header: "absolute counters
  depend on the database's history". The delivery path is what makes the
  absolute number observable, and it disagreed immediately.
- `serve-real-events.sh` was asserting fire-crab's own invention: it
  required the counter to move for posts NO ONE was listening to. It
  now asserts the engine's law instead, and the delivery gate is where
  a moving counter is checked.

### Gated
- **`qa/serve-real-eventdelivery.sh`** (10 checks): the paper's own
  `samples/nodejs/events.js` run against the live engine and against
  fire-crab, output required to match **line for line** — a stronger
  statement than any assertion the gate could write itself, because the
  client was not written for it. Plus the individual laws, so a shared
  failure cannot read as agreement, and log teeth for the whole dance.
- **`qa/serve-real-execblock.sh`** (11 checks): a block that writes and
  whose write the transaction owns, locals and loops, a failure inside
  it carrying the engine's error and its `At block` position, and the
  parameterised and `RETURNS` forms refused as recorded boundaries.

## 2026-08-07 — a transaction inside a transaction

### Converted
- **`IN AUTONOMOUS TRANSACTION DO <stmt>`** — the block runs under a
  transaction of its OWN: a fresh id reserved ACTIVE in the TIP, flipped
  to committed when the block finishes and to dead when it raises, and
  flushed either way. `EXECUTE STATEMENT ... WITH AUTONOMOUS
  TRANSACTION` is the same requirement in the engine's other syntax and
  is parsed into the same block.
- **What the block committed SURVIVES the failure of the body around
  it** — the point of the feature, and the hard part here, because every
  undo in this server is "put an image back". The pages the block
  committed are kept as a carve-out and written FORWARD over whatever
  the enclosing undo restores, exactly as the generator windows write
  their settled values forward.
- **The block cannot see the outer transaction's uncommitted rows.**
  That one came free: this server's visibility rule is "committed, or my
  own", so running the block's reads under the block's id is the whole
  of it.
- **An error inside the block rolls the block back and then escapes**,
  so the caller may catch it and nothing the block wrote remains.
- **Comments in a PSQL body** — `/* ... */` and `--` — are skipped
  between statements. See below for how that was found.

### Found
- **THE CARVE-OUT'S BASELINE HAS TO PREDATE THE ID RESERVATION, and
  getting it wrong is silent.** Reserving the transaction writes the
  HEADER (`hdr_next_transaction`) and a TIP page; a carve-out captured
  after them keeps the block's ROWS while letting the header go back, so
  the next autonomous block reserves the SAME id, marks it dead when it
  fails, and the row that was committed quietly stops counting. Measured
  exactly that way — the trace showed one id opened twice.
- **A COMMENT REFUSED THE BODY THAT EXPLAINED IT.** This gate's own
  `/* duplicate key */` note made its procedure unparseable: the
  statement walk skipped whitespace and not comments, so the cursor
  landed on `/` and the block parse gave up. It had been invisible
  because a body of nothing but ASSIGNMENTS is answered by the BLR
  executor, which never consults the source parser — only a body that
  also WRITES reaches it. A comment INSIDE a statement is still outside
  the surface, and that is now written down rather than assumed.

### Guarded
- **A body that has already written REFUSES the block.** The enclosing
  undo would put back an image without the body's writes, and the page
  carve-out would carry them straight back in — a failed statement's own
  rows, still visible to its transaction. Undoing those needs them to
  have a transaction of their own to kill (the engine's savepoint
  model), which this server does not have; until it does, the block is
  refused rather than answered. A block inside a block is the same
  problem with the outer block as the writer.

### Gated
- **`qa/serve-real-autonomous.sh`** (22 checks): the commit, the
  survival of the body's failure, the error inside the block caught and
  uncaught with nothing left behind, several statements committing
  together, DDL and assignment inside the block, and the `EXECUTE
  STATEMENT` syntax for the same thing.
- It is the **only serve-real gate that holds each server's database
  apart**, and it says why: every other one runs both servers over the
  same file because a rollback puts the file back, and an autonomous
  commit is precisely what a rollback does not put back — the engine's
  run would seed fire-crab's, and every later check would meet a
  duplicate key.
- Three recorded boundaries as assertions: the body-wrote-first refusal,
  the nested block, and **the outer transaction reading what the block
  committed** — the engine answers 0 because its transaction took a
  snapshot before the block existed, and this server answers 1 because a
  reader counts what is committed when it reads. That is the isolation
  model rather than this slice, written down where it first shows.
- `qa/serve-real-execstmt.sh`'s `WITH AUTONOMOUS TRANSACTION` boundary
  failed the day this landed, as a boundary written as an assertion
  should, and is an ordinary check now.

## 2026-08-07 — the statement a body builds at runtime

### Converted
- **`EXECUTE STATEMENT`**, in all three shapes: a bare one (DML and
  DDL), `... INTO :v[, ...]` for a singleton, and `FOR EXECUTE
  STATEMENT ... INTO ... DO <stmt>` for the loop, `LEAVE` included. It
  is `isc_dsql_execute_immediate` seen from the inside, so the text goes
  down the SAME plan chain a client's statement does (`plan_immediate`,
  extracted from the `op_exec_immediate` handler rather than copied) and
  a query goes down the ordinary planner — which is why a dynamic
  `CREATE TABLE`, then an `INSERT` into it, then a `SELECT` from it all
  work in one body.
- **A text operand that is actually built.** `Expr` is arithmetic — it
  has no string literal — so `S = 'SELECT ...'` refused the whole body,
  and with it the canonical way this feature is written. A TEXT
  ASSIGNMENT now stands beside the arithmetic one: literals, variables
  and `||` between them, the same surface the `EXECUTE STATEMENT`
  operand takes. An integer variable renders as its digits and a CHAR
  variable's blank padding is dropped, both probed.
- **A body's DML failure carries the engine's own error.** A duplicate
  key, a NOT NULL, a CHECK — the write path already builds the typed
  vector and the interpreter threw it away for a generic Dynamic SQL
  Error, which no handler can catch. Now `WHEN ANY` and `WHEN SQLSTATE
  '23000'` catch it and an uncaught one names the constraint, the table
  and the offending key exactly as the engine does. This is what makes
  "catch what the dynamic statement raised" possible at all.
- **`ROW_COUNT` starts at 0, not NULL** (probed: a body whose first
  statement tests `ROW_COUNT IS NULL` answers 0).
- Two new error identities, both read off the engine's own message
  table: `isc_eds_output_prm_mismatch` ("Output parameters mismatch")
  and the `isc_dsql_error` + `isc_sqlerr`(-104) + `isc_command_end_err2`
  vector an empty statement text prepares to.

### Found
- **`EXECUTE STATEMENT` DOES NOT TOUCH `ROW_COUNT`** — measured, and it
  is the rule a converter gets wrong for free. A body that updates two
  rows, then runs a dynamic update that changes one, then reads
  `ROW_COUNT`, answers **2**: the count belongs to the last STATIC
  statement.
- **The INTO contract is three separate rules, each of which would
  silently answer wrongly if guessed.** A singleton that matched nothing
  LEAVES THE SLOTS ALONE (as a FETCH past the end does); one that
  matched more than one row RAISES `isc_sing_select_err` rather than
  taking the first; and the slot count must equal the projected column
  count exactly — **including a query with no INTO at all**, which is
  the same "Output parameters mismatch", not a discarded row.
- **A NULL or empty statement text is not a no-op**: the engine prepares
  it like any other and its parser hits the end at once, -104
  "Unexpected end of command - line 1, column 1". A NULL variable and a
  literal `''` give the identical vector.
- **A statement's terminating semicolon must be found OUTSIDE its string
  literals.** A body's statement rarely carries a literal, which is why
  a plain scan served until now — but an `EXECUTE STATEMENT`'s operand
  is nothing but a literal, and `'INSERT ...; '` would be cut in half.
- **`SELECT ... INTO :v` (the STATIC singleton) is outside the PSQL
  surface** — found while gating, pre-existing and unrelated: the
  dynamic form works and the static one refuses.
- **A WRONG ANSWER, found by asking what the new text surface could
  reach.** `N = '5'` into an INTEGER output is a conversion the ENGINE
  performs — and the row encoder renders a text value into a 4-byte
  integer slot as **0**, so the client was told 5 is 0. It came from
  the BLR executor, which runs BEFORE the source interpreter and
  decodes string literals faithfully, so it predates this slice
  entirely; the text assignment is what made it reachable from the
  source side too.

### Guarded
- **Text in a non-text output parameter now REFUSES rather than
  answers.** Both paths carry the check — the source interpreter before
  it builds its row, and the BLR executor, which falls back to the
  interpreter (and its refusal) rather than shipping the value. The
  engine's CVT is what closes this properly; until it is converted, a
  refusal is the honest answer, and it is gated as a boundary so the
  day CVT lands the gate says so.

### Gated
- **`qa/serve-real-execstmt.sh`** (33 checks): the three shapes, the
  text built from a variable and by concatenation, ROW_COUNT untouched
  by a dynamic DML and 0 before anything ran, all four INTO rules, the
  NULL and empty texts, the dynamic statement seeing this transaction's
  uncommitted rows, DDL through it, its write dying with the body that
  failed, `EXECUTE PROCEDURE` through a dynamic string, what it raises
  caught and uncaught, and the static DML-failure identities that
  enable those.
- **The sweep caught a recorded boundary moving, again.**
  `serve-real-nofallback` asserted that a body holding an `EXECUTE
  STATEMENT` must RAISE rather than answer — an assertion, not a
  comment — so it failed the moment the feature landed. Its body moved
  to the far side of the same statement (`ON EXTERNAL DATA SOURCE`,
  which needs a whole external-connection subsystem) rather than the
  check being dropped.
- Four **recorded boundaries, written as ASSERTIONS** so the gate fails
  rather than quietly agrees when one moves: a parameter list after the
  text, `WITH AUTONOMOUS TRANSACTION`, a string assigned to a numeric
  output, and a dynamic statement that fails to PREPARE — the last because this server cannot yet tell "your
  column does not exist" (the engine's -206) from "this shape is outside
  my surface", and a refusal it cannot justify must stay generic.

## 2026-08-07 — a body calling a body, and what ROW_COUNT means

### Converted
- **`EXECUTE PROCEDURE` inside PSQL**, with arguments and
  `RETURNING_VALUES`. The callee gets its OWN frame — variables,
  cursors, ROW_COUNT — and its writes are this transaction's writes, so
  a callee that INSERTs and a caller that fails leave nothing behind.
  Arguments may be expressions over the caller's variables, and BARE
  names resolve there (unlike an embedded INSERT's VALUES, where the
  engine demands the `:`).
- **What the callee raises, the caller may catch** — `WHEN ANY` and the
  callee's own SQLSTATE both catch a division by zero raised one frame
  down, because the call returns a raise rather than a refusal.
- **`ROW_COUNT` after DML**: the rows an INSERT, UPDATE or DELETE
  touched, and **0 for one that matched nothing** rather than the
  previous statement's count. It is the same frame slot a FETCH sets.
- **A depth ceiling on nested calls.** This interpreter recurses on the
  Rust stack, so a self-calling body would take the server down rather
  than fail one statement; past 48 frames it refuses.

### Found
- **Raise points join differently from FRAMES, and the difference is
  visible in the bytes.** Two raise points in one body travel as TWO
  `isc_stack_trace` items — a client prints each with its own leading
  dash — but a nested call's outer frame is APPENDED TO THE CALLEE'S
  LAST ITEM with a newline, so the engine's two-frame output has no
  dash on its second line. Measured against the engine and reproduced;
  a converter guessing either rule prints the wrong shape for the other.
- **String literals are outside the embedded-DML surface** — an
  `UPDATE ... SET S = 'z'` inside a body is refused where the numeric
  form is not. Pre-existing, unrelated to this slice, found because the
  first ROW_COUNT probe used one. The gate uses numeric DML and says so.

### Gated
- **`qa/serve-real-callproc.sh`** (15 checks): the call with arguments
  and returned values, expression arguments, a call in a loop, the
  callee's error caught two ways and uncaught naming both frames, a
  callee's write dying with the caller's failure, and ROW_COUNT after
  each kind of DML including the one that matched nothing.

## 2026-08-07 — explicit cursors, and the loop they are for

### Converted
- **`DECLARE ... CURSOR FOR (...)`, `OPEN`, `FETCH ... INTO`, `CLOSE`**
  — the declared cursor, which was refused whole, taking every body
  that drives one with it. The cursor's query goes through the ORDINARY
  planner, exactly as a `FOR SELECT`'s does, so a cursor sees joins,
  filters and expressions for free.
- **`ROW_COUNT`, `LEAVE` and `EXIT`**, because the canonical cursor
  loop needs all three: fetch, ask whether anything came, get out.
  `ROW_COUNT` is not a declared variable but reads exactly like one, so
  it takes a slot at the end of the body's name list and the ordinary
  resolution turns it into that slot — a body that never mentions it
  never pays for it.
- **A FETCH past the end LEAVES THE VARIABLES ALONE** — probed: a
  variable holding 1 still holds 1 after a fetch that found nothing,
  and `ROW_COUNT` is how the body tells the two apart. Nulling them
  would be a wrong answer that only shows up at the end of a loop.
- **`LEAVE` ends the innermost loop only**, in `WHILE` and in
  `FOR SELECT`; **`EXIT` ends the body** from any depth, and a
  selectable procedure keeps the rows it has already SUSPENDed. A
  `LEAVE` that escapes every loop is refused, which is what the engine
  rejects at compile time.

### Found
- **Inside `DECLARE ... CURSOR FOR (...)`, an expression in the select
  list MUST BE ALIASED.** `SELECT A.ID * B.W AS P FROM ...` compiles;
  the identical statement without `AS P` is *Invalid command*, though it
  runs standalone. Found by writing the gate, and it is why the first
  version of the join check would not create.
- **A procedure with two output columns reveals a divergence that has
  nothing to do with cursors**: fire-crab announces every output
  parameter as BIGINT, so a client pads the columns differently from
  the engine's INTEGER. The values agree, the widths do not. Named in
  the gate so it is not read as a cursor bug, and split into
  single-column procedures so the cursor semantics stay strictly gated.

### Gated
- **`qa/serve-real-cursors.sh`** (14 checks): the three statements, the
  canonical loop, past-the-end behaviour and its ROW_COUNT, a cursor
  over a join with a filter and an expression, what `LEAVE` and `EXIT`
  each end, a selectable procedure driven by a cursor, and one that
  EXITs midway keeping its suspended rows.

## 2026-08-07 — runtime errors have an identity, and can be caught

### Converted
- **Every error the interpreter raises now carries a gdscode, a SQLCODE
  and a SQLSTATE**, which is what the three remaining handler forms
  compare against. `WHEN SQLCODE`, `WHEN GDSCODE` and `WHEN SQLSTATE`
  work; `WHEN SQLSTATE` is new to the parser as well.
- **A division by zero inside a body is an ERROR, not a refusal.** It
  used to stop the body with "this server does not interpret", which no
  handler can catch and which tells a client nothing.
- **An arithmetic overflow was answering NULL** — the one thing a
  converted engine may never do. It raises `isc_exception_integer_
  overflow` (SQLSTATE 22003) and is catchable.
- **`crates/wire/src/gdscodes.rs` regenerated with the whole identity**:
  1543 codes with gdscode, SQLCODE and SQLSTATE, from the engine's own
  `msg/*.h`, the gdscode computed its way
  (`0x14000000 | facility << 16 | number`).
- **`sqlstate_of` ports `fb_sqlstate`** (gds.cpp:2464): skip
  `isc_random`/`isc_sqlerr`, ignore `00000`, and keep scanning past the
  general `22000`/`42000`/`HY000` for something specific.
- **An error's identity is read back out of the status vector the
  server would send**, not listed a second time — so a `WHEN GDSCODE`
  can never catch something the client was not told about.

### Found
- **The two condition forms see different depths of the same error, in
  opposite directions.** `WHEN GDSCODE` matches the FIRST code and no
  other, so `arith_except` catches a division by zero and
  `exception_integer_divide_by_zero` does not. `WHEN SQLSTATE` matches
  the state derived from the WHOLE vector, so `'22012'` catches it and
  `'22000'` — the first code's own state — does not. A server that gave
  each error one identity would get exactly one of the two right.
- **Appending to a terminated status vector kills the connection.** The
  `At procedure` wrapper wrote the inner error with
  `eval_status_vector`, which ends with `isc_arg_end`, then added its
  items after it. The client read the error correctly, stopped at the
  terminator, and took the leftovers as the next message: right text,
  dead connection, and a hang that showed up several ops later and
  pointed nowhere near the cause. Split into `eval_status_items` (no
  terminator) and `eval_status_vector` (items + terminator).
- **A wrong diagnosis, recorded because it cost a cycle**: the hang was
  first blamed on a `continue` that short-circuits the `op_execute2`
  loop, and separately on a write-side deadlock in the re-run that
  recovers a raise position. Both were tested and neither was the
  cause; the re-run works fine now that the vector is well formed.
- **A BIGINT literal is outside the PSQL surface** — `Expr::IntLiteral`
  is an `i32`. Widening it changes BLR encoding and type ranking, so it
  is its own increment; the gate reaches an overflow by multiplying up
  from small literals instead, and says why.

### Gated
- **`qa/serve-real-psqlerrors.sh`** (15 checks): each condition form
  catching a division by zero, both non-matches above, a user
  exception's identity in all three forms, the uncaught error's text and
  position, a bare `EXCEPTION;` re-raising a runtime error with both
  positions, and an overflow caught by SQLSTATE and by `WHEN ANY`.

## 2026-08-06 — exceptions: catching them, and what reaches the client

### Converted
- **`WHEN EXCEPTION <name> DO`** — a handler with a condition used to be
  refused outright, so `WHEN ANY` was the whole of PSQL exception
  handling. The condition is matched against the raise's identity now.
- **A bare `EXCEPTION;` re-raises**, identity intact: the client sees
  the original exception, not a new one. The handler's body runs with
  what it caught in scope, saved and restored around nested handlers.
  It is interpreted-only — its BLR shape has not been probed — so
  `CREATE TRIGGER` refuses a body holding one rather than store BLR
  that silently drops a statement its own source contains.
- **An uncaught exception reaches the client as the ENGINE'S ERROR**,
  not as a generic Dynamic SQL Error: `isc_except` + the exception's
  catalog NUMBER, `isc_random` + its quoted name, `isc_random` + its
  message, then one `isc_stack_trace` per raise point
  (StmtNodes.cpp:5958). That distinction is the point of the slice — a
  driver cannot tell "your data raised E_MINE" from "this server could
  not run that procedure" when both arrive as -104.
- **The identity is read AT RAISE TIME**, as `MET_lookup_exception`
  does, so an `ALTER EXCEPTION` is visible to the very next raise
  rather than frozen when the body was parsed. Gated both ways.

### Found
- **`At procedure ... line: L, col: C` counts the DDL statement, and
  the catalog stores only the body.** The identical body reports line 2
  under a one-line header, line 6 under a five-line one, and line 1 col
  59 when the whole `CREATE PROCEDURE` was one line. fire-crab recovers
  the difference from the procedure's own `RDB$DEBUG_INFO` — the format
  it already writes for its own triggers — by reading where the body's
  BEGIN sat in the DDL. Version 1 of that blob packed line and column
  into 16 bits and version 2 widened both to 32; a reader assuming one
  width walks off the item boundary on the other.
- **A re-raise reports BOTH raise points**, in order — one stack item
  per raise, not one per exception.
- **Which handler runs is not what the engine's own loop suggests.**
  `StmtNodes.cpp:604` walks a block's handlers and takes the first
  whose conditions match; measured, `WHEN EXCEPTION E_M ... WHEN ANY
  ...` answers from the ANY, though the named one is first and matches.
  So the list that loop walks is not the source-order one. What the
  engine does, in each shape that distinguishes a rule: a `WHEN ANY`
  beats a named handler from either side, the LAST of several `WHEN
  ANY` wins, and with no `WHEN ANY` the first matching named handler
  wins — including one in the middle. All five are gated.
- **`INSERT ... VALUES` without a column list is outside the PSQL
  surface** — found while writing the gate, unrelated to exceptions,
  and noted where the gate works around it.

### Gated
- **`qa/serve-real-exceptions.sh`** (19 checks): every handler form and
  precedence shape, uncaught and re-raised error text compared line for
  line, nesting in both directions, the three DDL shapes, the ALTER
  EXCEPTION visibility, and that a body which wrote before raising
  leaves nothing behind.

## 2026-08-06 — the rest of gfix's header switches, and `hdr_end`

### Converted
- **`-use full|reserve`, `-buffers N`, `-housekeeping N`** — the other
  three header items a gfix attach can carry: `isc_dpb_no_reserve` (27)
  → `hdr_no_reserve` (0x8), `isc_dpb_set_page_buffers` (61) →
  `hdr_page_buffers` at offset 32, `isc_dpb_sweep_interval` (22) → a
  CLUMPLET in the variable header. Read back with `gstat -h` against
  the engine's own database after the same commands.
- **`store_clumplet`** in `fire-crab-ods` — `storeClump`
  (pag.cpp:213-266) with its three cases kept in the engine's order:
  same length overwrites in place, a different length is removed and
  re-appended (so a resized entry migrates to the end), absent is
  appended. It refuses with `isc_hdr_overflow` rather than writing past
  the page, and `find` keeps the LAST match as the engine's does.
- **A no-op gfix writes no page.** What would change is decided before
  the work copy is taken, so a switch asking for what is already true
  costs no image copy, no flush and no write side.

### Found
- **`hdr_end` (offset 36) is a field only a WRITER needs, and getting
  it wrong is silent corruption rather than a wrong answer.** Nothing
  that reads the variable header uses it — `variable_header` walks to
  the terminator — but the engine APPENDS AT IT
  (`HeaderClumplet::add`, pag.cpp:150). A clumplet added without moving
  `hdr_end` is overwritten by the engine's next header write. The gate
  makes the engine perform exactly that write (`ALTER DATABASE ADD
  DIFFERENCE FILE`, which inserts at the front and memmoves the rest by
  `hdr_end`, pag.cpp:425) against a database fire-crab wrote, and
  requires both entries to survive. **Checked by breaking it**: with
  the update removed, that entry reads `Sweep interval: 0` — the check
  can fail.
- **`store_clumplet` refuses a header that disagrees with itself** —
  `hdr_end` not naming the terminator the walk found. That is the only
  safe answer: picking either one corrupts the other.
- **gfix sends ONE item per run, and not the one you would guess.**
  `buildDpb` (exe.cpp:207-344) is a single else-if chain, so several
  switches on one command line collapse to whichever comes first IN THE
  CHAIN — not in argv — and the rest are dropped silently with rc=0.
  Measured: `gfix -buffers 700 -housekeeping 999` sets the sweep
  interval and leaves the buffers alone, from either order; `-use full
  -buffers 700` sets the buffers and leaves the attribute alone. **This
  gate caught its own premise**: it was written asserting that three
  switches are one header write, and the engine said otherwise.
- The dpb itself has no such rule, so the parser reads all four items
  and one attach applies them in one write. No gfix command line can
  produce that, so it is a unit test rather than a gate.

### Gated
- **`qa/serve-real-gfixheader.sh`** (23 checks): each switch against
  both servers with `gstat -h` as the oracle, the else-if chain's
  precedence in both argv orders, the `hdr_end` teeth above, coverage
  that every attach carried exactly one item and that the repeat wrote
  nothing, then `gfix -v -full`.

## 2026-08-06 — `gfix -write` is not a service (W6, first slice)

### Converted
- **`isc_dpb_force_write` is honoured at attach**, which is what
  `gfix -write sync|async` actually sends. The roadmap had gfix filed
  under "gbak/gfix/nbackup as services" and that was a guess: gfix does
  not open the service manager for this switch at all — it ATTACHES
  with DPB tag 24 (consts_pub.h:59) carrying 0 or 1, and detaches. A
  server that answered only the service manager would have left the
  switch looking like it worked while changing nothing.
- **One bit, and most of it was already there.** The switch asks for
  `hdr_force_write` (ods.h:724) in the header page, which
  `fire_crab_pio::plan_for_header` has read since it was converted — it
  is what decides whether a flush opens the file with SYNC. What was
  missing was only the ability to change it: decode the flag, flip it
  in a work copy, flush the header carefully, and the very next flush
  already obeys the new mode.
- **`qa/serve-real-forcewrite.sh`** (9 checks) runs the engine's own
  tool against both servers and reads the result with the engine's
  other tool: `gstat -h` prints `Attributes force write` when the bit
  is on and nothing when it is off. async then sync, both directions,
  both servers, plus `gfix -v -full` on the database afterwards; the
  coverage check requires the server log to show a flush in *each*
  mode, since the behaviour checks alone would pass against a server
  that wrote the bit and went on flushing the way it always had.

### Found
- **Before writing a service, check whether the tool uses one.** The
  same question is now open for gfix's other switches
  (`-housekeeping`, `-sweep interval`, `-mode read_only`), which look
  like the same shape — DPB or header, not SPB.

## 2026-08-06 — POST_EVENT is a statement now (W5, first slice)

### Converted
- **`POST_EVENT` joined the PSQL surface**, and `fire_crab_evt` is on
  the path with it. A procedure containing one used to be refused
  whole — *body is outside this server's PSQL surface* — which took the
  procedure's other statements down with it; it parses, emits
  `blr_post` (blr.h:128) when compiled, and posts when interpreted.
- **The engine's law, end to end**: a post changes nothing on its own,
  the COMMIT moves the counter, a ROLLBACK swallows it, and several
  posts of one name in one transaction move the counter by that many.
  Measured through the server: 1, then 3, then a rolled-back post
  leaving it at 3.
- **The event table is per database**, keyed the way the buffer pool,
  the lock table and the caches are — a poster in one attachment moves
  the counter a listener in another is watching. A transaction that
  only posts writes no records and so reserves no transaction id, so
  posts are filed under the attachment's own key, kept far above any
  real transaction number.
- **`qa/serve-real-events.sh`** (7 checks): both servers run the same
  posting procedure and must answer the same, on commit and on
  rollback; fire-crab's counter is then read out of its own log and
  must move by the posts and not at all on a rollback.
- **What is NOT here, named rather than assumed: DELIVERY.** A client
  learns about an event over an AUXILIARY connection —
  `op_connect_request`, a second socket, `op_que_events`, `op_event` —
  and this server speaks none of it. The counter is what a delivery
  would carry, and it is right; the carrying is the next slice.

## 2026-08-06 — What per-page fetch is actually worth, and what blocks it

### Measured
- **Two costs scale with the database, not one.** One INSERT, timed
  with `FC_SRV_TIME=1`: at 6MB the work copy is 259us and the careful
  flush 2449us; **at 33MB they are 6550us and 13660us of a 32ms
  statement**. The second one is the flush's DIFF — `changed_pages`
  compares the work image against the file page by page over the whole
  file to find the handful that moved.
- **The shortcuts do not work, and knowing why is the useful part.** A
  private per-transaction working image would copy once per transaction
  rather than once per statement — but that is exactly what the buffer
  pool removed: two transactions each publishing a whole image at
  commit lose each other's rows unless the write side is held for the
  whole transaction, which is what W4 stopped doing so two writers
  could work at once. `Arc::make_mut` cannot win while the pool holds a
  reference of its own.
- **The blocker is the shape of the `ods` API**: a database is one
  contiguous `&[u8]` addressed by absolute offsets. Pages cannot be
  stored, shared or copied one at a time until that changes — so the
  work is a page-addressed image (`Vec<Arc<[u8]>>` behind a
  `pages(n) -> &[u8]`), its readers and writers converted, and a pool
  that publishes the pages that changed (which hands the flush its
  changed set and ends the diff). The roadmap carries the plan and the
  number it is worth: ~20ms of a 32ms statement at 33MB.

## 2026-08-06 — A cached plan is adopted, not copied

### Converted
- **The statement cache hands back a reference.** It stored
  `Arc<(Plan, Vec<Descriptor>)>` and CLONED both out on every hit; it
  keeps `(Rc<Plan>, Rc<Vec<Descriptor>>)` now and the connection adopts
  them — `Rc` and not `Arc` because a `Plan` holds `Rc`s and belongs to
  one connection anyway. The live statement, the parked statement slots
  and the switch between them all carry `Rc`s.
- **What that is worth, measured rather than assumed: 3.3us per prepare
  on a bulky plan** (five indexes, three checks, a default) **and 0.2us
  on a small one — against 0.0us after.** That is 0.03% of a 9ms
  statement. **The earlier claim that "the clone is the cached path's
  cost" was wrong**, and wrong in an instructive way: it came from
  comparing averages that a single cache MISS dominated. Timing the
  warm path directly says a hit was already ~0.2us and is now
  unmeasurable.
- **What is worth having is the shape, not the microseconds.** A hit is
  constant-time whatever the plan's size, and the two places that patch
  a live plan in place — the deferred index, the `Rows` cursor — go
  through `Rc::make_mut`, so a plan shared with the cache is copied
  before it is changed rather than mutated underneath it.
- **The statement itself, all hits**: a repeated SELECT is 0.26ms
  against 1.34ms with `FC_NO_STMTCACHE=1`.

## 2026-08-06 — What to compute, not what was computed

### Converted
- **The two prepare-time folds moved to fetch, and the statement cache
  went in whole.** A lone aggregate (`SELECT COUNT(*)`, `MAX(ID)`, ...)
  was COMPUTED by the planner and carried in `Plan::Scalar`, and so was
  a `GEN_ID(g, 0)` read. `Plan::Scalar` now holds a **`ScalarVal`** —
  `Fixed` for a value that genuinely is constant, `GenRead(name)` for a
  generator, `Agg(AggPlan)` for an aggregate — and one `scalar_value`
  works it out at fetch, which is where the engine works it out too.
- **The probe stays at prepare and the value does not.** Asking
  `aggregate` is how that branch learns whether the shape is one it can
  do at all — the shapes it declines fall through to the group
  machinery, which types and computes them at fetch — so the call is
  still made and its ANSWER thrown away.
- **SELECT plans are cached now**: `plan(select)` 984us → 291us and the
  statement 1.22ms → 0.50ms, with the same rows before and after
  (`FC_NO_STMTCACHE=1` to compare). Together with the DML side, a
  repeated statement no longer re-plans at all.
- **`qa/serve-real-metadata.sh` gained the check that would have caught
  it**: the same text twice with a write in between — `COUNT(*)` and a
  `GEN_ID` read — and both servers must move. It is the check that
  turns "the cache is sound" from an argument into a measurement.

## 2026-08-06 — The statement cache, wired where it is sound

### Converted
- **DML plans are cached now**, and the asymmetry is the finding: **a
  DML plan is a pure function of (schema, text)** — its defaults are
  kept as `CurrentTimestamp`/`User` variants and evaluated at execute,
  its checks, foreign keys, index operations and formats are catalog —
  while a SELECT plan is not, because an unfiltered `COUNT(*)` and a
  `GEN_ID` read are folded to constants at prepare. So the DML side
  goes in and the SELECT side waits for those folds to move to execute.
  `qa/serve-real-defaultcurrent.sh` (20 checks) is what says the
  defaults still happen per row.
- **Measured on a repeated parameterised INSERT** — the shape a cache
  is for, since a client that inlines its literals sends a new text
  every time: `plan(dml)` 645us → 514us, the statement 3.08ms → 3.00ms.
  The saving is smaller than the planning it skips because a hit CLONES
  the plan out of the cache and a DML plan is not small; handing back an
  `Arc` is the next thing to do there.

## 2026-08-06 — The statement cache, and why it is not wired

### Converted
- **`crates/wire/stmc.rs`**: the plan a statement resolves to, kept per
  attachment, keyed by the SAME generation the metadata cache uses so
  one DDL drops both — bounded at 256 entries (a client that inlines
  its literals makes a new entry per statement, and a cache without a
  ceiling inside a long-lived server is a leak with good manners), and
  refusals deliberately not remembered. Four unit tests; `FC_NO_STMTCACHE`
  to turn it off.
- **NOT WIRED, and the reason is worth more than the cache.** Wiring it
  made a statement answer wrongly: **a plan is not a pure function of
  (schema, text)**. An unfiltered `SELECT COUNT(*)` is FOLDED TO A
  CONSTANT at prepare time — the planner counts the records and answers
  `Plan::Scalar(n)` — so a cached plan freezes the count. Measured with
  the cache on: one row, insert a row, ask again, one. The same query
  WITH a filter, which is not folded, answered two.
- **What it would buy, measured before it was taken out again**:
  `plan(select)` 1104us → 299us, the statement 1.40ms → 0.50ms.
- **The next step is precise**: move the unfiltered COUNT(*) fold from
  prepare to execute — it should plan to the aggregate the filtered one
  already plans to — and the cache goes in unchanged. `Plan` and the
  DDL payload types gained `Clone` on the way, which is what a cache
  needs of them.

## 2026-08-06 — Where a statement's time goes

### Converted
- **The phase timer reaches inside the write**, with a scope form
  (`TimeSpan`) as well as the call form, so a phase can be timed
  without wrapping the code in a closure that swallows its errors.
  Measured on an indexed table, an INSERT of 3.6ms: the careful flush
  2234us, the SELECT plan 1003us (of which `choose_index` 544us), the
  DML plan 420us, executing the write 118us — **the record write itself
  2us and the index maintenance 6us** — and the image copy 84us.
- **What that says about the next items.** The flush is the disk:
  Forced Writes is a synchronous write per page and the engine is in
  the same regime, with the commit already batching a transaction's
  statements into one. `choose_index` calls the optimizer per
  statement, which re-derives its plan from the SQL and the index
  metadata every time — a STATEMENT CACHE, which the engine has and
  fire-crab does not, and which the roadmap now names as the next item.

## 2026-08-06 — The last whole-file write

### Converted
- **A generator draw stopped rewriting the database.** It was the last
  `fs::write` of the whole image left in the write path, and it showed:
  measured, one `GEN_ID` cost **5.5ms on a 2MB database and 26.4ms on a
  5MB one** — the shape of an image write and nothing else. Draws now
  install into the pool like every other write and the commit flushes
  them: **2.12ms and 3.68ms** on the same two files.
- **And so did putting an image back.** `restore_db` wrote the whole
  file to undo a few pages; it goes through the careful flush now,
  which compares against the disk and writes what differs.
- **A committed draw survives `kill -9`**, and `gfix -v -full` finds
  nothing wrong with the file afterwards.

### Fixed
- **The image-path rollback owns a flush too.** A generator is not
  transactional: a rolled-back transaction's DRAW survives, which the
  generator windows implement by writing the settled value FORWARD over
  the restored image. With the flush deferred to commit, nothing then
  carried it to the disk — and `qa/serve-real-gendurable.sh` said so
  precisely, the engine answering 51 where fire-crab answered 50. The
  same lesson as the DDL commit, one path further along: every route
  out of a transaction has to know whether it owns a flush.

## 2026-08-06 — The commit is what writes

### Converted
- **A statement's write stops at the pool.** Its pages are installed
  for every attachment to see and left DIRTY; the COMMIT is the one
  careful flush that puts them on the disk, carrying the transaction's
  own two bits with them. That is what a page cache is for, and the
  measurement said so: an autocommit INSERT was paying TWO flushes,
  ~866us each of a 2.78ms statement — one for the statement and one for
  the commit. A transaction with many statements now pays one.
- **It is also the right durability.** Pages no commit has reached are
  pages a crash is entitled to lose: killing the server mid-transaction
  now leaves the file with exactly the committed rows and `gfix -v
  -full` finding nothing wrong, where before the uncommitted rows were
  already on disk (invisible, but there). And what must never be
  reordered — the data before the TIP bits that make it real — is the
  careful flush's own business, which now sees the whole set at once
  rather than one statement at a time: `qa/serve-real-carefulflush.sh`
  is unchanged and green, largest flush 5 pages.
- **A transaction id is not what makes a commit** — the bug the gates
  caught the moment the flush moved. `commit_tx` returned early when
  the transaction had reserved no id, which is exactly what a DDL-only
  transaction looks like: its catalog rows are settled as they are
  written, so it never needs one. Its PAGES were dirty in the pool all
  the same, and nothing put them on the disk — `qa/serve-real-alterdefault.sh`,
  `alterdomaintype` and `altercomputed` said so in the plainest way
  available, the engine reading the file and answering *Table unknown*.
  The commit now flushes whatever the transaction dirtied, id or no id,
  and skips the work entirely when it wrote nothing at all.
- **INSERT 2.78ms → 2.52ms.** `qa/serve-real-undo.sh`'s coverage check
  was re-pinned: a rollback's flush now carries what the transaction
  dirtied as well as its two bits, so the number is a handful of pages —
  bounded by the work, not by the database — rather than exactly one.

## 2026-08-05 — The metadata cache

### Converted
- **The catalog is read once per schema, not once per statement.**
  Measured first, with a new `FC_SRV_TIME=1` switch that times a
  statement's phases: an INSERT cost 8.2ms, of which **5.6ms was
  building the plan** — the work copy 111us and the careful flush
  957us. Planning was that expensive because every plan re-derived the
  table from the FILE: `RDB$RELATIONS` for the id,
  `RDB$RELATION_FIELDS` + `RDB$FIELDS` for the columns, `RDB$FORMATS`
  for the descriptors, then `RDB$INDICES` and its segments for the
  index operations, the NOT NULL fields, the identity column, the
  qualified name — each a walk of a system relation, for an answer only
  DDL can change.
- **So `crates/wire/mdc.rs` holds them**, per database, keyed by a
  GENERATION that only DDL advances — the engine's own metadata-cache
  rule, since a million inserts do not change what a table's columns
  are. It also follows the buffer pool's EPOCH: a file the pool
  re-read is a different database, and everything derived from the old
  one goes.
- **Measured after the first pass: plan 4857us → 1809us, and the
  INSERT 7.4ms → 4.3ms**, on the same two-row table.
- **And then the rest of the plan, measured phase by phase.** With the
  first cache in, `plan(dml)` was 1852us: `plan:defaults` **1277us**,
  checks 207us, FKs 195us, NOT NULL 24us, index operations 0 (cached).
  The defaults walk the whole of `RDB$RELATION_FIELDS` — a row per
  column of every relation in the database — and read a blob per
  default, for an answer that depends on the TABLE, not the statement;
  only which columns the statement NAMED is per statement. Split in
  two: `table_defaults` is cached, with a per-column "there is a
  default here and it cannot be evaluated" marker so a statement that
  omits that column still refuses and one that supplies it still does
  not care. The FK partnerships and the check predicates followed (the
  latter keyed by the guard as well as the table, since an UPDATE's
  answer depends on which columns it sets).
- **Plan 5498us → 402us, and the INSERT 8.2ms → 3.06ms.**
- **The SELECT planner had the same problem**, and the timer said so:
  `plan(select)` was 902us of a 1.20ms SELECT. Its own id and columns
  read, the formats it decodes with (`select_formats` — the system
  relations' bootstrap walk when `RDB$FORMATS` has nothing) and the
  computed-column sources now come from the same cache. Left uncached
  deliberately: `choose_index`, 232us, which depends on the
  statement's filter and ORDER BY and not only on the schema.
- **Where the session's statements ended up**, timers off:
  **SELECT 1.24ms → 0.94ms, INSERT ~7.9ms → 2.78ms.** And the timing
  switch itself reads its environment variable ONCE, in a `OnceLock` —
  it wraps hot paths, and `env::var` per call would have made the
  instrument part of what it measures.
- **`qa/serve-real-metadata.sh`** (5 checks) runs a DDL-then-DML script
  — add a column and write it, create an index and write through it,
  add a foreign key and write across it — three ways: through the
  engine, through fire-crab, and through fire-crab with `FC_NO_MDC=1`.
  All three must agree, which is what says the cache changed no
  answers; and the pool's counters (`mdc: hits 19 misses 27
  invalidations 12`, read at the connection's END rather than its
  start) say it was used and that DDL really dropped it.

## 2026-08-05 — The lock manager, participating

### Converted
- **W4 is done: `lck` is wired, and the write side is one statement
  long.** The database's write side used to be held from a
  transaction's first write to its commit, because a rollback put an
  image back; now that a rollback is two bits, it covers the
  read-modify-write of ONE statement and is released between requests.
  Two transactions can be open and writing at once — and what
  arbitrates a row they both want is the lock table.
- **The engine's own mechanism, not a lock per record.** Firebird does
  not lock records: a writer that meets a version belonging to another
  transaction reads that transaction's STATE, and if it is still active
  it waits — on a lock the transaction holds over its own id
  (`LCK_tra`, series 4) for as long as it lives. `crates/wire/dblocks.rs`
  is that, in two calls: `hold_transaction` at a transaction's first
  write, `wait_for_transaction` by a writer that met one. When the
  holder ends, the waiter wakes, **re-reads the row and applies its
  write to what it now finds** — the engine's WAIT and re-read, in
  `with_conflict_wait`, which is also where the write side is dropped
  before waiting (the transaction being waited for needs it to commit,
  and that deadlock is not one the lock table could see).
- **And the deadlock scan answers.** Two transactions each waiting on
  the other close a cycle in the wait-for graph, and `fire_crab_lck`
  denies the second rather than letting it hang — reported with the
  engine's own `isc_deadlock` (335544336), so a driver reads SQLSTATE
  40001 and retries; a wait that runs out of time gets
  `isc_lock_conflict` (335544345). The table's deadline machinery
  (`enqueue_deadline` + `expire`) is what bounds the wait, converted
  long ago with nothing calling it.
- **Measured, against the engine, on every probe**
  (`qa/serve-real-concurrency.sh`, 20 checks — all of them now the
  engine's answers rather than recorded divergences):

  | probe | engine | fire-crab |
  |---|---|---|
  | an uncommitted row, from another attachment | invisible | invisible |
  | a writer wanting an UNRELATED row | not held up | not held up |
  | a writer wanting a row another transaction holds | waits, then writes | waits, then writes |
  | two transactions waiting on each other | exactly one denied | exactly one denied |
  | the deadlock's status code | 335544336 | 335544336 |

  Plus the coverage half, read out of the server log: `locks: holds 10
  waits 3 grants 2 deadlocks 1` — the lock table was on the path, and
  the wait-for scan really denied a cycle.
- **A snapshot taken when it is needed, not at transaction start.** A
  transaction whose undo is an image (DDL, an open savepoint) keeps the
  write side, and the image it would put back is refreshed at every
  statement boundary until then — restoring the transaction's opening
  image would otherwise undo another connection's commits that landed
  in between. It costs a refcount bump, which is the other reason
  snapshots stopped being copies.

### Fixed
- **"Has this transaction written?" stopped meaning "does it hold the
  write side".** They were the same question while the side was held
  from a transaction's first write to its end; once it became one
  statement long, a transaction that wrote and then answered a SELECT
  held nothing — and its ROLLBACK concluded there was nothing to undo,
  so the GENERATOR COMPENSATIONS never ran and a rolled-back
  `SET GENERATOR` kept its value. `qa/serve-real-genwrite.sh` and
  `qa/serve-real-gendurable.sh` caught it (17 checks between them). The
  transaction now carries the answer itself.

## 2026-08-05 — A rollback is two bits

### Converted
- **Undo by transaction STATE, not by image.** A transaction that wrote
  only records is rolled back by marking it `tra_dead` — two bits in
  the TIP — where it used to be undone by putting back the whole
  database image the transaction started from. The rows stay on the
  pages, the index entries naming them stay in the trees, the pages it
  allocated stay allocated, and none of it counts, because every reader
  walks past a version whose transaction it does not count. **That is
  what the engine leaves behind too.**
- **The engine's own garbage collector takes them.** New gate
  `qa/serve-real-undo.sh` (16 checks + one observation): after fire-crab
  rolls back 200 inserts, all 202 versions are still on the pages
  (counted before the engine is let near the file), the engine reads 2
  rows, `gfix -v -full` finds nothing wrong, and `gfix -sweep` collects
  every rolled-back version — the engine treats a transaction fire-crab
  marked dead exactly as it treats its own, which is a stronger
  statement than "the rows are hidden". A plain SELECT usually collects
  them too (202 → 34: Firebird's COOPERATIVE GC, a read taking dead
  versions with it), but **whether a given read collects is the
  engine's own scheduling** — it was seen collecting nothing — so the
  gate reports that number and asserts the sweep.
- **Measured**: a rollback flushes ONE page instead of the database (the
  gate asserts it from the careful-flush trace), and 200 rolled-back
  inserts on a 20MB database cost 32ms before and 11ms now — the
  remainder being the whole-image copy every write still makes, which is
  what W2's per-page fetch removes.
- **Snapshots are free now.** A published image is never edited in
  place, so a transaction that may need to put the file back keeps a
  REFERENCE (`Arc<Vec<u8>>`) rather than a copy: `snapshot_db` costs a
  refcount bump where it used to copy the whole database, once per
  transaction and once per savepoint.
- **The carve-out is measured, not assumed.** An image is still what
  undoes a DDL statement — this server's catalog rows are settled as
  they are written — and a `ROLLBACK TO` a mark, which asks a
  transaction to undo part of itself; those transactions carry
  `Database::image_undo` and take the old path. The gate holds both
  against the engine.

### Fixed
- **`SELECT COUNT(*)` counted record HEADERS, not rows.** With no
  filter it took a decode-free fast path over live primary headers,
  which was right only while every transaction in the file was
  committed. The moment a rollback stopped rewriting the database, the
  rows it left behind were still headers — and a refused
  `INSERT ... RETURNING` whose transaction the driver rolled back came
  back as `COUNT(*) = 1` against the engine's 0.
  `qa/serve-real-outblr.sh` caught it. The fast path now walks the
  version chain through `tra::visible_exists` — the same walk the
  decoding path does, with the images left alone, because a count needs
  the answer and not the bytes — and `qa/serve-real-undo.sh` asks
  fire-crab for the count itself rather than only asking the engine.

## 2026-08-05 — A transaction that has not committed

### Converted
- **Real transaction state.** A transaction now reserves ONE id at its
  first record write and leaves it `tra_active` in the TIP; every
  record it writes carries that id; **COMMIT is the two bits** that flip
  it to `tra_committed`. A rollback still restores the image snapshot,
  and when there is none to restore the transaction is marked
  `tra_dead` — the other way the engine ends one it will not honour.
  New in `ods::dml`: `begin_active_tx`, `set_tx_state`,
  `insert_record_under`, `delete_records_under` (the TIP slot
  arithmetic the committed path already had, deduplicated into
  `tip_bits_at`).
- **Every record walk reads through the version chain**, which wires
  `fire_crab_ods::tra` — converted and gated since the MVCC increment,
  never called by the server. `ReadView` asks
  `tra::visible_version` for the newest version whose transaction this
  attachment counts (committed, its own, or the system transaction) and
  decodes it with THAT version's format, not the chain head's. It
  replaces `is_primary_record()` in the full-relation walks, the
  record-number fetch, the index-candidate fetch, the DML target
  collectors and the uniqueness check — a write reads what its own
  transaction sees, so it neither updates nor duplicate-refuses against
  rows nobody has committed.
- **The system transaction is committed by definition.** Measured: id
  0's two bits read `tra_active` in every real database, because it is
  not a transaction anybody started — the engine answers for it in code
  (tra.cpp's snapshot-state lookup). Reading it as active would have
  hidden `RDB$PAGES` and with it the catalog.
- **Result** (`qa/serve-real-concurrency.sh`): an uncommitted row is now
  **invisible** to other attachments, the engine's own answer, where the
  previous increment had exposed it as this server's one remaining
  isolation divergence. What is left is blocking GRANULARITY — the
  engine blocks a second writer only on a conflicting row; this still
  holds one write side per database — which is what `lck` is for.

- **A connection that vanishes mid-transaction leaves it DEAD, not
  open.** The engine ends an uncommitted transaction when its
  attachment goes; the connection loop now marks one `tra_dead` on the
  way out, so its rows count for nobody and the engine's own sweep can
  collect them. Left active, they would be a transaction that never
  ends.
- **Cost: none measurable.** The transaction id is reserved inside the
  statement's own working copy rather than an install of its own, so a
  write still clones the image once — 300 inserts, five alternating
  rounds against the pre-change binary: 8.55ms/row against 8.65ms;
  point queries and scans unchanged. It also means a statement that
  FAILS burns no transaction: its copy is dropped, the header still
  reads what it read, and the next write reserves the same number.
- **The engine is the oracle for all of it.** `qa/serve-real-concurrency.sh`
  (14 checks) holds a transaction open in fire-crab and asks ISQL what
  is in the file: the row is already on the pages — every statement
  flushes — so the only thing hiding it is the TIP entry, read by the
  engine's own code. It does not see the row, and sees it the moment
  fire-crab commits.

### Fixed
- **A careful flush must diff against the FILE, not the last thing
  published.** Found by `qa/serve-real-update.sh` the moment a
  transaction id was reserved in an install of its own: the header and
  TIP pages it changed were equal in both halves of the next
  statement's comparison, so the flush found nothing changed and **they
  never reached the disk** — leaving records whose transaction id was
  above the file's `hdr_next_transaction`, 16 record-level errors from
  `gfix -v -full`, and a sweep that collected nothing. The pool now
  keeps the image as it stands ON DISK (`SharedImage::flushed`) and
  every flush diffs against that.

## 2026-08-05 — One file, one image

### Converted
- **The buffer pool** (`fire_crab_cch::pool`) — the shared resource the
  concurrency oracle found missing the day before. The pages of a
  database now live **once per file per process** instead of once per
  attachment: `load_database` goes through the pool rather than
  `std::fs::read`, readers take a reference-counted snapshot of the
  image (so a writer installing a new one never changes it under a read
  in progress), and **writers are serialized per database** — the write
  side is taken at a transaction's FIRST write and held until it commits
  or rolls back, because this server undoes a rollback by restoring a
  whole-image snapshot and must not be able to restore over another
  connection's committed rows. A connection that never wrote no longer
  "restores" anything. The pool re-reads a file that changed underneath
  it (every gate deletes and re-creates its scratch database against a
  running server) and forgets a dropped one.
- **Both divergences the oracle recorded are gone**, measured by the
  same probes with the engine's half asserted alongside: an attachment
  opened BEFORE another's commit now sees it (was: frozen at attach, for
  the life of the connection), and 20 concurrent inserts across two
  attachments now leave **all 20 rows** (was: 10, one image landing
  whole over the top of the other) — with `gfix -v -full` still finding
  nothing wrong with the file. `qa/serve-real-concurrency.sh` was
  rewritten around what is left, and gained a COVERAGE section that
  reads the pool's own counters out of the server log: attachments that
  found the image resident, and writers that queued behind another.
  Both non-zero is what makes the behaviour checks evidence about the
  pool rather than about a process that happened to be alone.
- **What is still different, and now measured rather than assumed.**
  The serialization is DATABASE-wide where the engine's is row-wide (a
  second writer waits even for an unrelated row), and an uncommitted row
  is VISIBLE to other attachments — fire-crab marks a write's
  transaction committed in the TIP as it writes it, so there is no
  in-flight state for a reader to skip. While the image was private
  neither could be seen from outside. The first is what W4 (`lck`) makes
  row-granular; the second wants real transaction state, not more
  locking. **W4 is unblocked**: there is a shared resource to arbitrate.

## 2026-08-05 — Two attachments are two databases

### Guarded
- **The concurrency oracle, and what it found.** Every gate in this
  suite compared ONE session's answers, so nothing had ever asked what
  two attachments do to each other — which is exactly the question W4
  exists to answer. `qa/serve-real-concurrency.sh` opens two and
  measures both servers. The engine BLOCKS a second writer (default
  WAIT). fire-crab does not, and the reason is not a missing lock
  manager: `load_database` does `std::fs::read(path)` into an owned
  `Vec<u8>` once per connection thread, so **every attachment holds a
  private full-file copy**. An attachment opened before another's commit
  never sees it (the write is durable and on disk — one opened after
  sees it, and so does the engine); two attachments inserting 10 rows
  each end with 10 rows, one image having overwritten the other; and
  `gfix -v -full` calls the result perfectly valid, because it is one
  writer's *consistent* image, whole, over the top of the other's.
  **W4 therefore cannot be started** — a lock manager arbitrates a
  shared resource and there is not one yet. Its prerequisite is W2's
  read path, which the roadmap had listed as an independent item.

## 2026-08-05 — The key the engine files in the wrong place

### Converted
- **DESCENDING indexes are keyed now**, and the arithmetic was READ off
  the engine's own index rather than derived. An ascending and a
  descending index over the same values: `1 → bff0 / 400f`,
  `2 → c0 / 3f`, `'ab' → 6162 / 9e9d`, `'abc' → 616263 / 9e9d9c` — the
  descending key is the bitwise COMPLEMENT of the ascending one, taken
  after the ascending zero-chop and not re-chopped, which is exactly
  what the write side already produced. Two things follow: the BOUNDS
  SWAP (a larger value is a smaller key), and the comparison is not
  `memcmp` — a shorter key pads with **0xFF**, so a key that is a byte
  PREFIX of another sorts AFTER it. That second rule is both recorded
  misses, and it explains why the integer one looked unrelated to the
  text one: a zero-chopped key like 2's `c0` IS a prefix of 3's `c008`.
  The rule is `btw::key_cmp_desc` — the write side had it, and
  `lookup_range` asks for it rather than restating it, which also closed
  a latent flaw in `lookup_key`, where a UNIQUE or FK descending index
  compared its bounds with plain `memcmp`. Compound descending indexes
  still scan.
- **Scaled NUMERIC/DECIMAL columns are keyed now.** A `NUMERIC(9,2)` is
  a LONG at scale -2 whose key is the DOUBLE 12.5; a `NUMERIC(18,2)` is
  an INT64 taking the `INT64_KEY` form. The encoder always handled both
  — what was missing was carrying the LITERAL to the column's own scale
  before asking for a key, so `pick_for_terms` refused every scaled
  column and the engine indexed `WHERE N92 = 1.50` where fire-crab
  scanned. A literal that does not land on the column's scale EXACTLY
  still scans: `N > 12.505` has no key at scale -2, and rounding one out
  moves the band's edge, which drops rows no filter above can recover.
  FLOAT/DOUBLE columns keep scanning — their key is the value's own
  bits. `qa/serve-real-index.sh` 359 → 387 checks, 14 DIFF against the
  previous commit, all of them coverage and none of them answers.

### Fixed
- **`i64::MIN` can be written now, and it is keyed where the ENGINE
  files it.** Two halves the roadmap had said to do together or not at
  all. The literal parse read a digit run WITHOUT its sign (a leading
  `-` is a separate unary node), so `9223372036854775808` overflowed
  `i64` and the statement was REFUSED though the value is
  representable — measured, the engine folds the sign in before typing:
  `-<digits>`, `- <digits>` and `-(<digits>)` all describe INT64, the
  bare magnitude is INT128, past 2¹²⁷ it is DECFLOAT(34). And the write
  key, which the entry had guessed at: read off indexes the engine wrote
  itself, `-9223372036854775808` and `0` share the key
  `800000000000000080`. **The engine files `i64::MIN` under zero's
  key** — the overflow sends the scale loop one bucket on, and `q *= 10`
  on `i64::MIN` wraps to exactly 0. It is a defect and it is the
  engine's alone: equality finds such a row, every RANGE misses it
  (`A < -9223372036854775807` answers nothing though the row exists;
  the same predicate with `A+0` returns it). fire-crab matches it,
  because a key is an ADDRESS in a shared file and a row written
  elsewhere is one the engine cannot find. Gated by writing the row with
  fire-crab and reading it back with the engine, plus `gfix -v -full`.
- **`Expr::Neg` wrapped silently** where `+` and `-` beside it have
  always raised. Nothing could reach it until the literal became
  spellable; the engine describes `- -9223372036854775808` as INT64 and
  raises 22003 at the row, which that arm now does.

## 2026-08-05 — A modifier that dropped the select list, and a set that is a sort

Two wrong answers under `FIRST`/`SKIP`/`DISTINCT`, both found by asking
a question the gate had been phrased to avoid, and one queued roadmap
item retired as an artefact of the measurement rather than a divergence.

### Fixed
- **A modifier must still run the SELECT LIST.** The modifier's own
  columns are POSITIONAL over rows the inner plan has already projected
  (`field_id: i, expr: None`); one path fed them BASE RECORDS instead,
  so every select-list EXPRESSION was dropped and column *i* of the
  TABLE answered in its place. `SELECT FIRST 2 CAST(S AS INTEGER) FROM
  TE` returned the ID column — 1 and 2 — where the engine returns 10 and
  20, and `SELECT DISTINCT CAST(S AS INTEGER) FROM TE` returned four
  rows where the engine raises. **It hid behind the batch fetch**, which
  materialises the cursor through `branch_rows` first and only falls
  through to this path when THAT returns `None` — which happens exactly
  when some row RAISES. So one unconvertible row silently corrupted the
  answer for every good one, and a fixture without a raiser could never
  see it. The inner `Project`'s own `cols` now turn each record into a
  projected row before the modifier's positional columns read it.
- **`SKIP` without `FIRST` streams too** — there is no stop, but no
  reason to materialise: the engine delivers row 2 of `SKIP 1 <raiser>`
  before it raises on row 3.
- **`DISTINCT` is a SORT, not a filter.** The engine does not remove
  duplicates in place, it sorts and drops equal neighbours — `PLAN SORT
  (TD NATURAL)`, with or without an index available — so the set arrives
  ASCENDING over every output column left to right, NULLs first. `UNION`
  is the same node; `UNION ALL` does not sort. fire-crab kept scan
  order. **Not cosmetic: a modifier SLICES that sequence**, so `SELECT
  FIRST 2 DISTINCT A FROM T` answered 30 and 10 where the engine answers
  NULL and 10 — a different ROW SET out of a difference in row ORDER.
  An explicit `ORDER BY` REPLACES that sort rather than sitting under it
  (there is one sort in the engine's plan and those are its keys); the
  first attempt at this re-sorted after de-duplicating and broke exactly
  that case, which the gate caught.
- **Why no gate saw either.** Every `DISTINCT` check in
  `qa/serve-real-modifiers.sh` pinned the order with `ORDER BY 1`, which
  the file's own header states as a deliberate choice — and it is the
  right one for `FIRST`/`SKIP`, where "the first two" is undefined
  without it. For `DISTINCT` it removed the question instead of
  answering it. The gate is 48 → 66 checks; 18 DIFF against the pre-fix
  binary.

### Guarded
- **A differential must hold the TRANSPORT fixed** — the fourth time
  this suite has measured its own environment (after `NODE_PATH` drift,
  isql `AUTODDL` and `FORCE_COLOR`). The roadmap's queued R8 item said
  the engine raises a blocking node's error at OPEN where this server
  announces the result set and raises at the first FETCH. Asked over the
  same transport, it does not: a bare FILE PATH attaches the EMBEDDED
  engine (`MON$REMOTE_PROTOCOL` NULL), which raises at open, while the
  SAME engine on the SAME file over `localhost/3050:` announces and
  raises at fetch, exactly as fire-crab does. The item is retired and
  the gate now reaches both servers over TCP.

## 2026-08-02 — Three refutations, three laws re-probed

Three adversarially-confirmed divergences, each re-probed against the
live engine before the fix: expression describe widths over multibyte
charsets, the bind-time invariant pass raising into OR-groups the
engine never reaches, and the literal bad-escape LIKE raising where the
engine's lenient-prefix pre-filter answers.

### Fixed
- **Text expression widths are CHARACTER counts, scaled at emission**
  (out-blr refutation): `SUBSTRING(U6 FROM 1 FOR 3)` over a VARCHAR(6)
  UTF8 column described 3 bytes where the engine describes 12, so both
  node-firebird generations got a spurious per-row truncation raise;
  `U6 || 'x'` described 100 vs the engine's 28. Probed the full
  {SUBSTRING FOR/LPAD/RPAD/LEFT/UPPER/TRIM/`||`/COALESCE} x {NONE col,
  UTF8 col, WIN1252 col, literal} matrix under UTF8, WIN1252 AND NONE
  attachments (SQLDA_DISPLAY): the algebra is charset-independent in
  characters; the announced charset is the ATTACHMENT's whenever it
  names a real one, the operand's own under a NONE attachment (NONE
  and OCTETS operands keep theirs); of two different real charsets the
  FIRST operand's wins; a FOR count past the source caps at the
  source's width. text_form now runs in characters, real-charset
  expressions ride a second negative sub_type sentinel (enc_real_cs)
  resolved beside ATT_SUBTYPE at describe emission, and cs_join
  carries the probed join. Six new outblr pins (32 checks).
- **The invariant pass walks CONJUNCTS, not DNF groups** (tri-state
  refutation, a regression): `(1=1 OR 1/0=1) AND ID>0` and
  `ID>0 OR 1/0=1` raised at bind where the engine answers every row.
  Probed model: every fully row-independent TOP-LEVEL conjunct
  evaluates ONCE at open - even over an EMPTY table (`WHERE 1/0=1`
  and `? LIKE ?bad` both raise with zero rows; `1=0 AND 1/0=1` does
  not; `ID/0=1 AND 1=0` answers no rows - the FALSE invariant kills
  the scan the row-dependent division never reaches) - while a
  conjunct with any row-dependent part evaluates whole, per row, in
  written order under the engine's short-circuit (OR stops at TRUE,
  AND at FALSE, UNKNOWN at neither). The DNF now carries per-term
  conjunct provenance (parse_predicate tags, kept 1:1 through
  resolution and bind), Predicate::matches evaluates conjunct by
  conjunct, and the bind pass raises/drops/strips by conjunct. The
  distributed spelling `1=1 AND ID>3 OR 1/0=1 AND ID>3` still raises
  per row exactly as the engine does - same DNF, different provenance,
  different answer, both probed.
- **Literal bad-escape LIKE gates on the LENIENT PREFIX** (tri-state
  refutation): `NAME LIKE 'a!bc' ESCAPE '!'` answers [] when no row
  starts with 'abc' (the bad escape processed as if it escaped the
  next character; prefix stops at an unescaped wildcard or trailing
  escape; per-byte case-sensitive starts_with - probed 'abcd' raises,
  'abX' answers), raises 22025 on the first reached prefix-hit row.
  The gate is the engine's DSQL-time rewrite of a LITERAL pattern
  only: a BOUND pattern (`NAME LIKE ?`), NOT LIKE, and a non-text
  side (`N LIKE '1!2'`) all raise ungated, and a `?`/expression text
  side gates the same (`? LIKE 'a!bc'` bound 'zz' answers [], bound
  'abc' raises even over zero rows - the conjunct is invariant).
  Term::BadLike / Term::BadExprLike carry the prefix; the select-list
  value path (IIF) keeps its ungated value-gated raise. Twelve new
  intlike pins (40 checks), five new paramshapes pins (114).

### Recorded
- DNF flattening tags only TOP-LEVEL conjuncts, so a parenthesized
  invariant OR nested BELOW another OR still shows DNF raise-order:
  `((1=1 OR 1/0=1) AND ID>3) OR ID=1` raises on the first row failing
  ID>3 where the engine short-circuits the inner OR once and answers
  (probed both ways). Exact fidelity needs tree-shaped evaluation,
  its own slice.
- `LPAD(U6, ?, 'x')`-style NON-literal counts still describe the
  32765 NONE catch-all where the engine announces 32764 in the
  attachment charset - describe-only, no raise flip observed.
- The engine's OCTETS-expression law is pinned only where probed
  (UPPER/`||` over OCTETS keep OCTETS under a UTF8 attachment);
  OCTETS joined with a real charset is unprobed and keeps cs_join's
  first-real answer.

## 2026-08-02 — W1 reaches the subquery

The subquery surface never consulted the optimizer: all three inner
evaluators walked their tables with full scans. The engine, probed,
drives the inner table's index whenever the subquery's OWN WHERE names
an indexed column - and does NOT for the plain correlated semi-join
(it hash-joins over an inner NATURAL scan, exactly fire-crab's fold
model), so the fold stays; the slice is the inner residual WHERE only.

### Converted
- render_toks renders the de-aliased, de-correlated residual WHERE
  back to SQL for fcopt's gatekeeper (unrenderable tokens = scan,
  never a guess - fcopt refuses aliased FROM, which is why the text
  is reconstructed); eval_subquery's two walks and
  build_correlated_lookup's one became for_each_candidate with the
  chosen index; group_output takes the index through leaf_source.
  The candidates-not-answers law is inherited from records_for - the
  closures' predicates are byte-identical, and the recno dedup is
  what keeps a scalar subquery ALIVE after a key UPDATE (a stale
  double-return would refuse as multi-row where the engine answers).
- New qa/serve-real-subqindex.sh (54 checks): band-edge behavior vs
  the engine, coverage via the new "[srv] subq index:" trace
  (deliberately NOT containing the "index scan:" substring the index
  gate's zero-assertion greps), natural-shape non-coverage, DML
  stale-entry probes, FC_NO_INDEX twin three-way equality.

### Fixed
- qa/opt-plans.sh was red at clean HEAD: fcopt no longer refuses two
  populated-join statements and matches the engine's plans - the
  stale prefuse expectations became pcheck equalities.

### Recorded
- The OUTER query of a folded subquery still scans (plan_query_inner
  hands the ORIGINAL text to choose_index; fcopt refuses subqueries) -
  the adjacent follow-up, answers already engine-identical.
- fcopt's aliased-FROM refusal: converting it would delete the
  reconstruction.

## 2026-08-02 — Three truth values, in written order

The engine evaluates INVARIANT conjuncts - parameters-only,
literals-only - BEFORE the scan, in written order, with FALSE beating
error beating UNKNOWN (probed: `1=0 AND 1/0=1` answers no rows where
`1=NULL AND 1/0=1` raises). fire-crab's two-valued Term::matches could
not express that law; it is tri-state now.

### Fixed
- Term::matches answers Result<Option<bool>> - UNKNOWN is distinct
  from FALSE, and Term::Never split into invariant-dead vs per-row
  Unknown (they answered alike and the engine does not treat them
  alike). The invariant pass in Predicate::bind walks row-independent
  terms in written order; a dead group is dropped, a fully-TRUE
  invariant OR-group suppresses later groups' errors (`1=1 OR bad`
  never raises - probed).
- The literal bad-escape bug: `NAME LIKE 'a!bc' ESCAPE '!'` had been
  ANSWERING wrong rows; invalid_escape now raises value-gated in the
  Like eval arms, and the wire says 22025/335544702 instead of a
  generic error. The pre-existing `ID=99 AND 1/0=1` twin gap closed
  free.
- `N LIKE ?` and the literal `N LIKE '1%'` family on INTEGER columns;
  scaled NUMERIC/INT128 columns under STARTING/LIKE, literal and
  param (fc's Value::Scaled render matches the engine's CAST matrix -
  probed before trusting); `UPPER(NAME) LIKE ?` via the same arm.

### Converted
- paramshapes grew to 109 checks (constant-law section: five
  raise-on-both, five answer-on-both pairs); new
  qa/serve-real-intlike.sh (28 checks) for the literal shapes.

### Recorded
- Text literals against numeric columns (`N BETWEEN '1' AND '3'`,
  `N = '2'`...) - engine answers, probes attached, unblocked by this
  machinery but its own slice.

## 2026-08-02 — The client's declaration is the contract

fire-crab had been reading and discarding the client's declared output
message BLR - answering full values where the engine, honoring the
client's own too-narrow declaration, raises per-row truncation.

### Converted
- `isc_dpb_lc_ctype` parsed at attach (absent = NONE); the out-BLR
  parsed at op_fetch/op_execute2 (mirroring parse_param_blr); the row
  encode enforces the engine's probed capacity rule: transliterate
  path exempt entirely, silent trailing-blank trim delivering
  padded-to-cap, else the exact status vector with the UNTRIMMED
  actual (a CHAR(5) 'ab' raises expected 1, actual 5). Rows before the
  failing row still ship; INSERT..RETURNING raises and does not
  persist, on both sides.
- Expression describes gained the charset dimension the probe table
  demanded: UPPER(V6) stays NONE while V6||'x' announces UTF8 at 4
  bytes per char - the live describe path is answer_prepare, not the
  test-only build_describe the spec first anchored.
- New qa/serve-real-outblr.sh (26 checks) running the SAME statements
  through the stock 2.11.0 driver (must get the same error at the
  same row) and the patched 2.14.1 (must get the same rows).

### Found, not fixed (recorded in the roadmap)
- EXECUTE PROCEDURE on an ENGINE-created FB6 procedure fails "no such
  procedure" - likely PUBLIC-schema lookup.
- qa/auth-srp.sh harness bugs ($0-relative NF path, dead default
  port, short security-db wait).

## 2026-08-02 — What the second refuters found

An adversarial pass over the day's two implementation increments
refuted both; three findings fixed, one boundary priced and recorded.

### Fixed
- **Invalid ESCAPE sequences matched as literals where the engine
  raises 22025.** The engine validates a LIKE pattern's escapes at
  EXECUTE — the escape must precede `%`, `_` or itself, and may not
  end the pattern — and only against a non-NULL tested value (a NULL
  bind answers no rows on both sides, which is why the check lives in
  the bind, not the parse). `invalid_escape` + the ParamLike bind arm.
- **Item 33 was decided by a bare `RDB$` name-prefix**: `SEC$USERS`
  answered PUBLIC where the engine says SYSTEM. The prefix set is now
  RDB$/MON$/SEC$; the true discriminator is the relation's SYSTEM
  FLAG, so a USER table quoted into an `RDB$` name still answers
  SYSTEM here and PUBLIC there — a recorded boundary.
- **A derived side's RENAME hid the base field name in JOINs** — the
  residual recorded since the fname increment, now closed for free by
  the machinery this slice added: `JoinSide` carries per-column
  `fnames` from its inner plan, and the named-col, star and grouped-key
  producers let the inner symbol shine through (probed:
  `(SELECT X AS C FROM T) D` joined answers field X).

### Recorded (fail-closed, its own slice)
- **DOUBLE binds refuse where the engine answers** on every
  param-tested shape (`? BETWEEN 1 AND 3` bound 1.5 — engine: all
  rows; fc: refuses at execute) — and the root is pre-existing in the
  mirrored comparison leaves (`? >= 1.5` bound 1.5 refuses too, so the
  previous increment's "already answered every mirrored comparison"
  overclaimed: it held for text and integer binds only). Matching the
  engine needs its double-to-text/exact-compare rendering rules — the
  known minefield — so the refusal stands, priced: a JS client binding
  a fractional number gets an error, never a wrong row.

## 2026-08-02 — The describe names its sources

Items 17 (relation), 18 (owner), 25 (relation_alias) and 33 (schema)
join the describe — and the plan's own item numbers were wrong: the
relation alias is 25, not 34. fire-crab's 34 arm was dead code no
client ever requests, and the engine answers item 25 for every query
(empty payload when no alias) while fire-crab omitted it entirely —
invisible to a field+alias comparison.

### Fixed
- `ProjCol` carries `relation`/`rel_alias` (None = "", the fname
  precedent); ~14 producer categories stamp the probed engine answers:
  the single-table path, RETURNING, all four JoinSide constructors
  (per-column relations mapped back through the combined offsets),
  views (stamped on EVERY column — an expression view column still
  carries the view), derived tables and CTEs (base relation shines
  through under the OUTERMOST binding alias; a CTE's name IS an alias
  where a view's name is NOT), unions (first branch's relation+alias
  under the existing all-plain predicate), procedures, group keys
  (plain keys only), the subquery fold (an inner FROM alias ESCAPES),
  and correlated lookups.
- Owner derives at emission: SYSDBA exactly when a relation is
  answered, RDB$ tables included (a non-SYSDBA-owned relation is a
  recorded boundary).
- Item 33 was wrong in BOTH directions — SYSTEM tables answered
  PUBLIC, expressions answered PUBLIC instead of "" — and now follows
  the same relation knowledge.
- A law the probe table itself got wrong, refuted live during
  implementation: a BINDING ALIAS does not require a relation —
  `(SELECT X+1 AS C FROM T) V` answers relation "", relationAlias V.

### Converted
- `qa/serve-real-describe.sh` grew to 107 checks comparing all SIX
  describe strings (field, alias, relation, relationAlias, owner —
  spliced into node-firebird's request, its parser already handles
  it — and relationSchema).

## 2026-08-01 — The parameter takes the stand

`WHERE ? IS NULL`, `? LIKE 'o%'`, `? BETWEEN 1 AND 3`, `? IN (1,2)` —
the four shapes the roadmap carried as "the engine answers all of them
and this parser covers none" — answer now, plus `? STARTING WITH`,
`? LIKE ?`, `? STARTING WITH ?`, and the refuter's `N STARTING WITH ?`.

### Converted
- The load-bearing probe discovery: fire-crab already answered every
  MIRRORED comparison (`? = 1`, `? >= 1.5`) with engine-identical rows,
  so BETWEEN and IN are a parse-time DESUGAR into those leaves —
  `lo <= ? AND hi >= ?`, an OR of equalities — all referencing the ONE
  slot (claimed before the bounds, so `? LIKE ?` numbers its two slots
  in textual order). Only IS NULL / LIKE / STARTING needed new terms,
  each ROW-INDEPENDENT and decided at bind.
- Engine laws probed and pinned: `? IS NULL` describes as SQL_NULL
  (32766, length 0 — the engine's makeNullString describe, now a real
  dtype::UNKNOWN arm in wire_for) and the bind is TYPE-BLIND (a text
  value answers "not null", no error); `? IS UNKNOWN` is the same
  predicate; NULL binds are UNKNOWN under both polarities everywhere;
  `? BETWEEN 1 AND 3` takes '2.5' with the fraction kept; text items
  are pad-insensitive in the mirrored compare; `? NOT IN (1, NULL)` is
  never true.
- `N STARTING WITH ?` (INTEGER column): the engine describes the SLOT
  as text and renders the COLUMN per row — '1' matches N=1 and N=10,
  '' matches every non-NULL N, ' 1' matches none, and a blr_long 1
  binds as '1'. param_or_typed_term routes the Int-column case into a
  bind-time ExprStarting.
- New `qa/serve-real-paramshapes.sh`, 83 checks, including error
  parity ('x' into an int-anchored BETWEEN raises at EXECUTE on both
  sides) and the refusal pins.

### Guarded
- Refused deliberately, engine answers recorded: `? IN (?, 2)` (the
  engine types the inner ? from the list — asymmetric with BETWEEN,
  which refuses -804 even with one typed bound), `? IN (1, 'a')`
  (per-bind conversion semantics), `? BETWEEN 1 AND 'x'`,
  `? IS DISTINCT FROM 5`, `N LIKE ?`.

## 2026-08-01 — Sixteen DIFFs, one stale path

The "environment drift" recorded yesterday — serve-real-index 346/13,
viewjoin 33/3, engine-side errors labelled "numeric overflow on the
BIGINT-family keys" — is diagnosed, and the label was a red herring.

### Fixed
- All 16 DIFFs were ONE defect, selected by what each check PROJECTS
  (a ≥2-character NONE VARCHAR), not what it filters on. A stock
  node-firebird 2.11.0 declares its output slot at the column's BYTE
  length; `blr_varying` carries no charset; the engine resolves the
  slot to the ATTACHMENT charset (UTF8, 4 bytes/char) and its capacity
  check raises "string right truncation" per row. The green baselines
  ran on the patched 2.14.1 checkout with the node-firebird#422 fix;
  a NODE_PATH note went stale and selected the published 2.11.0. The
  engine build never changed (LI-T6.0.0.2076, verified). Both gates
  now pin `encoding:"NONE"` — driver-proof — and answer 359/0 and
  36/0 under either driver.

### Found, not fixed (recorded in the roadmap)
- fire-crab IGNORES the client's declared output message BLR (op_fetch
  reads and discards it), so for a stock 2.11.0 client the ENGINE
  refuses — correctly, per the client's own declaration — what
  fire-crab answers. Honoring the declared format (charset-aware
  per-row truncation with the engine's status vector) is its own
  slice.

## 2026-08-01 — What the refuters found

An adversarial pass over the day's three increments: one confirmed
clean (STARTING WITH — ~60 probes including a column named STARTING
used as a table alias, quote/wildcard prefixes, high bytes, and
Halloween-style updates), two refuted. All three findings fixed and
pinned.

### Fixed
- **ORDER BY reaching a generator through an ORDINAL or ALIAS answered
  wrong rows and diverged the stored sequence.** The spelled form
  (`ORDER BY NEXT VALUE FOR S`) refused at resolution, but `ORDER BY
  1` / `ORDER BY A` reach the key through the ProjCol — a synthetic
  field_id, or an `Expr::GenVal` inside a cloned expression — and the
  sort ran over slots the advance had not filled: every key NULL, scan
  order kept, values numbered afterwards, stored value 3 where the
  engine's was 6. Refused now (`expr_contains_genval` + the synthetic
  field check), pinned in the genrow gate.
- **The union FIELD name is empty only when some branch's item is an
  EXPRESSION** — an all-plain-column union keeps the FIRST branch's
  column name (probed: `X UNION ALL Y` is field X; `X+1 UNION ALL X`
  is ""). The increment had blanked every union column from the one
  shape the gate probed — a regression against pre-increment behavior,
  which had been right for plain columns by accident.
- **The union ALIAS blanks too when the first branch's item is an
  unaliased expression** (probed: `X+1 UNION ALL X` describes ""/"");
  a pre-existing divergence the new union checks exposed. "Unaliased"
  is approximated as name == symbolic name.
- **A folded whole-item EXISTS described as CONSTANT** — the fold
  rewrites to `TRUE AS BOOL` and the literal named itself; the
  position-patch now recognizes the `EXISTS <marker>` item and stamps
  BOOL.

### Recorded (refuter observations, deliberate boundaries)
- `N STARTING WITH ?` (a parameter prefix against an INTEGER column)
  refuses where the literal form answers — param_or_typed_term
  requires a text column; a future slice.
- A gen-bearing union branch refuses with a conversion-error message
  rather than a clean unsupported error — cosmetic.
- `raw_contains_gen` ignores generator advances inside CONDITIONS
  (IIF/CASE tests); resolution still refuses them, so no wrong answer
  — but the routing is by luck, worth tightening when conditions learn
  generators.

## 2026-08-01 — A generator is an expression leaf

`(NEXT VALUE FOR S) + 100` and its kin, refused since the select-list
parser was built, are answered now — with the engine's evaluation-order
law, which took a probe to find.

### Converted
- `RawExpr::Gen`, on the `RawExpr::Agg` pattern: a leaf not resolvable
  on its own; the planner assigns it a synthetic slot that the per-row
  advance fills, and the expression evaluates against the filled row.
  Arithmetic, concat, CAST, function arguments and COALESCE heads all
  take one; `GEN_ID(S, n)` with a literal step likewise.
- **The order law**: select-list ITEMS evaluate RIGHT-TO-LEFT (probed:
  two bare `NEXT VALUE` items on a fresh sequence answer A=2, B=1 — the
  LEFT item gets the HIGHER value), leaves within one item evaluate
  left-to-right (probed: `(NEXT VALUE FOR S)*1000 + (NEXT VALUE FOR S)`
  at 61 answers 62063). The `gen_cols` vector's ORDER now carries that
  law — which also fixed a pre-existing wrong VALUE: two bare items had
  been numbered ascending left-to-right.
- `qa/serve-real-genrow.sh` grew from 14 to 25 checks: the expression
  forms agree value-for-value including a 2500-row digest that spans
  fetch batches, the two-item twins are compared as TWO ITEMS (a concat
  twin would evaluate left-to-right and mis-pin the law), and all four
  generators' stored values stay in engine lockstep.

### Fixed
- **`SELECT FIRST 2 NEXT VALUE FOR SEQ` had been ANSWERING — every
  value NULL, and the sequence never moved.** `branch_rows`
  destructures `Plan::Project` with `..` and knows nothing of
  `gen_cols`; `Plan::Modified` materialised through it. It now refuses
  a gen-bearing Project outright (prepare-time refusal at the Modified
  constructor, plus the `branch_rows` backstop for every other caller:
  union branches, FOR SELECT, INSERT ... SELECT, recursive CTE levels).
- The batch fetch materialises a gen-bearing Project in RECORD
  coordinates — slots filled by the advance, ORIGINAL columns kept, so
  a gen-bearing expression evaluates against the filled slot at encode
  time. The old positional patch (which could only fix WHOLE-item
  columns, after projection) is gone.

### Guarded
- The LAZY positions refuse rather than over-bump: the engine does not
  advance in an untaken CASE branch (probed), bumps per matching row in
  WHERE, per compared row in ORDER BY, only for emitted rows under
  FIRST, and 19-times-for-5-rows under GROUP BY (measured). CASE, IIF,
  NULLIF, COALESCE tails, conditions, WHERE, ORDER BY clauses, GROUP
  BY/HAVING and FIRST/SKIP/DISTINCT all refuse, each pinned in the
  gate.

## 2026-08-01 — The describe's two names

The engine's describe carries a FIELD name (item 16, the symbolic or
source name) and an ALIAS (item 19, the client's column key), and its
rule is one line of `DsqlAliasNode::setParameterName`: every expression
sets BOTH names to its symbol; the user's `AS` overwrites only the
alias. fire-crab had answered the alias in both fields for every
aliased column since the describe writer was built.

### Fixed
- `ProjCol` carries `fname` beside `name`; `None` means "same as name",
  so an unconverted construction site stays byte-identical. The live
  describe writer (`answer_prepare`) emits them separately; ~20
  producer sites set the symbol the engine was probed to answer:
  `X AS Z` is `X`/`Z`, `X + 1 AS Y` is `ADD`/`Y`, `COUNT(*) AS N` is
  `COUNT`/`N`, a computed column is its own name, a view column hides
  the base where a derived table lets it shine through, a UNION column
  is EMPTY, a grouped key keeps its bare column name under an alias.
- `NULLIF` describes as `CASE` — it compiles into one; fire-crab
  answered `NULLIF`, a DIFF visible without any alias.
- `NEXT VALUE FOR G1 FROM RDB$DATABASE` describes as `NEXT_VALUE`; the
  GenIdIncrement path had said `GEN_ID` for both spellings.
- A selectable procedure's `SELECT R AS RR FROM P` DROPPED the alias
  entirely — wrong for every client keying rows by it.
- A folded scalar subquery lost its inner symbol (`(SELECT MAX(X) ...)`
  described as `CONSTANT`): the fold rewrites SQL text, which cannot
  carry the name, so the fold now remembers each whole-item subquery's
  position and patches the re-planned column.

### Converted
- New `qa/serve-real-describe.sh`, 63 checks, comparing BOTH fields via
  `newStatement` (prepare only, so generator probes advance nothing) —
  including the engine's surprises: unary minus is EMPTY/EMPTY, a
  scalar subquery delegates naming to its inner item, `DECODE` keeps
  its own name although it desugars to CASE (which is why the symbol
  travels from parse time in `SelItem::Expr`).

### Found, not fixed (recorded in the roadmap)
- Items 17/18 (relation/owner) still answer `""` where the engine names
  the table/view/procedure — a separate slice.
- A derived table as a JOIN side loses base-name propagation — the
  synthetic `RelationColumn` is an ods catalog type and should not grow
  a wire concern.
- `serve-real-viewjoin.sh` carries 3 engine-side errors of the same
  environment-drift class the index gate showed.

## 2026-08-01 — STARTING [WITH] joins the predicate parser

The roadmap had carried "STARTING WITH is not in the predicate parser"
since the fragment gate was built. It is one leaf beside LIKE now — and
because STARTING is **not a reserved word** (probed: `CREATE TABLE T2
(STARTING INT)` succeeds), it is recognized by identifier text, the
`IS [NOT] DISTINCT FROM` precedent, so a column named STARTING still
parses everywhere else.

### Converted
- `<col> [NOT] STARTING [WITH] <prefix>` in WHERE, HAVING, join
  filters, `UPDATE`/`DELETE ... WHERE`, and with a `?` prefix bound at
  execute. Semantics probed row by row against the engine: a per-BYTE
  prefix on the STORED value with **no trimming on either side**
  (CHAR(5) `'ab'` stores `'ab   '` and matches prefix `'ab '`; VARCHAR
  `'ab'` does NOT), the empty prefix takes every non-NULL row, a NULL
  prefix or value is UNKNOWN under both polarities, and an INTEGER
  column coerces to its decimal text per row (1 and 10 both match
  `'1'`). New `qa/serve-real-starting.sh`, 36 checks, every row set
  diffed against the engine and against an `FC_NO_INDEX` twin — the
  optimizer answers INDEX for a prefix test but no band-builder exists,
  so the statement SCANS, never a partial answer.

### Guarded
- Refusals kept, each with the engine's answer recorded for its future
  slice: a column prefix (`V STARTING WITH C` — the CHAR pad makes the
  prefix `'ab   '`), an expression prefix (`'a'||'b'`), a numeric
  prefix literal.

### Found, not fixed (recorded in the roadmap)
- The BLR path's `BBool::Starting` (isql SHOW plumbing) trims trailing
  blanks on BOTH sides; the engine does not. Wrong in general, right
  for the padded metadata columns SHOW reads — not copied into the new
  term.
- The engine converts a NONE column into the ATTACHMENT charset on the
  way out and that conversion drops a VARCHAR's trailing blank on a
  UTF8 attachment; fire-crab passes stored bytes through. Measured on
  plain ASCII — the transliteration gap bites before any high byte.
- `qa/serve-real-index.sh` is 346/13 at HEAD on this box and the 13 are
  environment drift (the ENGINE side now errors with numeric overflow
  on the BIGINT-family key checks) — identical at clean HEAD, so the
  floor still attests this slice; the gate's premises need re-probing
  against the current driver.

## 2026-08-01 — Patch the head, leave the tail alone

`dml::patch_head_in_place`. A record too large for a page is stored as a
head plus continuation fragments, and the catalogue patch sites refused
such a record outright — costing 88 `COMMENT ON TABLE` and 92
`DROP INDEX` statements on an ordinary `gbak`-restored database that the
engine performs without complaint.

### The guard is the design
Every poked range must end within the head's unpacked length, or the
function refuses and the caller fails exactly as before. That is not
caution for its own sake: it is what makes the change small enough to be
safe. Measured on a restored 220-table schema, the head's own bytes are a
**byte prefix of the assembled image in 266 of 266** fragmented rows, and
every field these sites poke lands inside it — **88 of 88 and 178 of
178**. The change never reaches the tail, so the tail never has to move.

A poke that ran past the head would need an `rhdf` writer, packed-stream
truncation, tail teardown and page compaction. Those four are
deliberately NOT built: each is a new way to write into a user's
database, and nothing in the 184 statements needs one.

Two further refusals, both because the alternative is worse: an
unfragmented record is sent to the ordinary update path, and a repack
that would grow past its slot is rejected rather than relocated, because
moving the body would strand a tail that points at this page.

Never touched: the transaction id, the back pointer, the format byte,
`rhdf_f_page`/`rhdf_f_line`, and every fragment after the head. This is a
byte edit inside one record's payload, not a record rewrite — which is
why it does not push a back version either, matching what the engine does
for catalogue patches.

### What it fixes, and what it does not
`COMMENT ON TABLE` now succeeds on every table of the restored fixture
(it was 48 of 60, refusing exactly the fragmented ones). Of the 184
fragmentation-caused refusals measured on the 220-table schema, this
slice addresses 179. The remaining five are indexes that own a fragmented
`RDB$INDEX_SEGMENTS` row, deleted through the same rejecting path — a
separate increment, with its own honest number.

### The gate learned to check the bytes, not just the survival
`gfix` clean and "the engine still opens it" prove the page structure
survived; neither proves the value went where it was meant to.
`serve-real-restored.sh` now reads the new descriptions back **through
the engine** and asserts that a field of the same rows which should NOT
have changed is intact. A mis-split shows there first.

Four unit tests, and the ones that matter are the refusals: a poke past
the head, an unfragmented record, and an over-long repack each leave the
record byte-identical.

392 unit tests; restored gate 8/8.

**Adversarial verification is in flight** — three lenses (MVCC, the bytes,
what else reaches the code) attacking this specifically, because it
writes into real databases and a prototype someone else validated is not
the same as this implementation being correct.

## 2026-08-01 — A write that relabelled the row it wrote

A fleet asked to design fragmented-record rewriting found, on the way, a
corruption reachable **today, on ordinary unfragmented rows**.

### Fixed
- **`patch_sys_row` poked at the wrong format's offsets and then
  relabelled the record.** It took `formats.iter().max_by_key(…)` — the
  relation's NEWEST format — and used that format's field offsets to poke
  an image it had decoded at *the record's own* format, then stamped the
  record with the newest format number.

  On a row written under an older format that lands the write on the
  wrong bytes AND relabels the row, so every later read decodes the whole
  thing at offsets it was never written with. **`gfix -v -full` calls the
  result clean** — the page structure is intact and only the values are
  wrong, which is the worst kind of damage this project can do.

  It needs a system relation carrying more than one format to fire, so it
  has been latent rather than absent. It has nothing to do with
  fragmentation; that is simply what the fleet was looking at when it
  saw it.

- **One gate could not be run at all.** `serve-real-comment.sh` sat at
  mode 644. Nothing failed: a runner counting DIFF lines sees a clean
  result, because "Permission denied" contains none, and a runner
  checking exit codes sees rc=126 with no explanation. Both readings are
  wrong in the safe-looking direction, which is the same class as a
  squatted port or an empty fixture. `qa/gate-selfcheck.sh` grows a
  seventh check for it; the gate itself passes 20/20 now that it can run.

### Recorded: the head-in-place rewrite is sound, and the count was not
The fleet's proposal — poke a fragmented record's HEAD in place, refuse
when the field lives in the tail — **survived its refutation on the
mechanism and failed on the arithmetic**, which is the useful outcome.

Verified independently by the refuter: the head is a byte-prefix of the
assembled image in 266/266 cases, every poke is head-resident (88/88 and
178/178), 155 index rows fit their existing slot with none needing
relocation, and a full column-by-column differential of all 650
`RDB$INDICES` rows against an untouched baseline is byte-identical
including tail-resident `RDB$SCHEMA_NAME`, with `gfix` clean. It also
completed the `COMMENT ON` half the original never validated end to end:
88 rows poked, comment text readable **through the engine**.

But "fixes all 180" is wrong twice over. The real total is **184**
fragmentation-caused refusals — 88 `COMMENT ON`, 92 `DROP INDEX`, and 4
more the original's model could not see — and the slice fixes **179**.
Five indexes each own a fragmented `RDB$INDEX_SEGMENTS` row, deleted
through the same rejecting path. That is the next increment, and it now
has an honest number attached.

388 unit tests; alter, comment, comment2, restored, syscat gates clean;
gate-selfcheck 7/7.

## 2026-08-01 — The same disease at the next call site

`catalog::relation_columns` is now memoised for system relations, the way
`system_relation_formats` was. After the format cache landed, a fleet's
profile put this function at **60.9% of the server's remaining CPU** —
an uncached full walk of `RDB$RELATION_FIELDS`, with 120 call sites and
`sqz::unpack` and `catalog::cstr` beneath it.

**The safety argument is the same one, and it was checked rather than
assumed to transfer.** Only system relations are cached. Every cached
call site asks for `RDB$RELATION_FIELDS`, `RDB$FIELDS`, `RDB$INDICES`,
`RDB$INDEX_SEGMENTS` or `RDB$DEPENDENCIES`, and what is cached is those
tables' OWN column definitions — rows written at database creation that
no DDL rewrites. A user relation's columns change under `ALTER TABLE`, so
the DDL call site that passes a user name (`ddl.rs:354`) bypasses the
cache entirely. The key carries the ODS major and the page size so two
attachments to different databases cannot share an entry.

**No speedup is quoted here.** This box has one core and a fleet was
running two investigations on it; a stopwatch reading under that load is
the error this project spent a day correcting, and the last figure taken
that way turned out to be half a stray process. What is verified is
correctness: 388 unit tests, and `serve-real-restored.sh`,
`serve-real-syscat.sh` and `serve-real-alter.sh` all at zero DIFFs — the
three gates that read catalogues and then write to them.

For the record, the measurement that motivated it was taken properly, by
the fleet, on a verified-quiet machine: 2.92 ms per statement at HEAD
against the engine's 0.95 ms, down from 19.6 ms before the format cache,
with server CPU at 730 ms per 200 statements against 3,810 ms.

## 2026-08-01 — The guard was standing on a false premise, and it was mine

Three edits to `opt`, and a cache. The stale-statistics grid goes from
**4 exact / 165 refused to 169/169 with zero refusals**; the fresh grid
stays 169/169.

### Fixed
- **A zero index statistic is the engine's SUBSTITUTION case, not a
  refusal.** fcopt returned *"stale index statistics … the engine's
  costing then depends on state this crate has not converted"*. That
  premise was false, and it was mine. The state is one constant:
  `Retrieval.cpp:1019-1026` substitutes
  `MAX(scratch.selectivity * DEFAULT_SELECTIVITY, minSelectivity)` with
  `DEFAULT_SELECTIVITY = 0.1`.

  It is per matched segment and geometric — `scratch.selectivity` is the
  running compound figure, so two matched segments give 0.1 then 0.01,
  not 0.1 twice. And for the LEADING segment the `MAX` is **dead code**:
  `scratch.selectivity` is still 1.0 there, so the expression is
  `MAX(0.1, MIN(1/cardinality, 0.1))` whose right operand cannot exceed
  0.1 by construction. The substituted leading figure is exactly 0.1 at
  every cardinality, and since this crate only ever matches segment 0,
  that is the entire conversion — one line.

- **The index-page term is restored, reversing a decision recorded two
  increments ago.** I had written it off as "under 0.1%, and it needs
  `irtd_itype` plumbing `ods` does not have". Both halves were wrong in
  the way that matters:

  * 0.13% is exactly what decides the cell at **(28, 500)**. A term being
    *small* is not a term being *inert*.
  * the `MAX(…, MINIMUM_CARDINALITY)` **floors it at 1.0** on every table
    measured, so the key length never reaches the answer — identical
    scores at key lengths 4, 8 and 12. The plumbing was never a
    prerequisite.

  Worth 9 of the 11 cells that otherwise missed.

- **The tie-break direction.** `InnerJoin.cpp:236` is
  `if (hashCost <= loopCost && …)`; fcopt had `<`. Ties are not rare —
  (5,8), (10,20), (15,40), (9,18), (12,28) are all exact — so the
  direction decides real cells. Worth the last 2.

### Fixed: 105,412 field decodes to answer `SELECT 1`
`system_relation_formats` is called **five times per statement** and was
uncached, each call scanning *two entire catalogues* and decoding every
field of every row.

The numbers here are a **fleet's measurement, not mine**, and are quoted
as such: a uprobe counted 105,412 field decodes for one `SELECT 1 FROM
RDB$DATABASE`, perf attributed 77% of server CPU to the function, a
micro-benchmark linking the crate put it at 2.9 ms per call, and an
A/B/A on a quieted machine took 200 statements from 3,926 ms to 569 ms
with server CPU down 81%. Four instruments, and they agree. I have NOT
re-measured independently: this box has one core and was running a fleet
throughout, and taking a timing figure under that load is the exact
mistake corrected below. The correctness of the cache does not depend on
the figure — that is 388 unit tests and 169/169 on both plan grids — but
the speedup is on their authority until I re-run it quiet.

**Only system relations are cached, and that is the whole safety
argument.** A user relation's format changes under `ALTER TABLE`, and two
call sites do pass a user name — caching those would serve a stale layout
and decode every later row at the wrong offsets. A system relation's
layout is fixed by the ODS for the life of the database, so a cached
answer cannot go stale. The key carries the ODS major and the page size
so two attachments to different databases cannot share an entry.

### Corrected: every timing number this session was taken on a stolen core
The box has **one core**, and a `cargo test` binary left running on
Jul 31 had been spinning at 100% for **14 hours 41 minutes**. It halved
every measurement taken since. It was mine; it is killed.

That retracts a claim made earlier today — "a second ~44 ms
per-statement stall remains, and it is not the socket". The waiting half
was **runqueue wait caused by that process**, not anything in fire-crab.
The real engine barely noticed the contention (337 ms against 161 ms)
because it needs 0.8 ms of CPU per statement, which is exactly why the
starvation looked fire-crab-specific. Syscalls, disk and the wire were
ruled out by measurement: 1,045 syscalls totalling 1.85 ms of 391 ms
wall, and two `openat` for the entire run.

### The gate lost a leniency
`qa/opt-plans.sh`'s stale phase passed on "zero wrong" however many cells
were REFUSED. That was the right rule while the crate declined to cost a
zero statistic and the wrong one now. The stale grid is held to the same
standard as the fresh one: every cell exact, nothing refused.

One property to keep in any future test matrix: the substitution's effect
is **not monotone in staleness**. Ten cells are HASH with one side stale
but a keyed loop with both stale, because the hashed side's selectivity
also prices the probe. One-sided staleness has to be in the matrix.

## 2026-08-01 — Sixty-three tables that did not exist

The fleet sent to plan fragment assembly refuted the assembly I had just
committed, and the correction found something far worse than the
optimizer symptom that started it.

### Fixed
- **Each piece is decoded with its OWN flags.** My first version joined
  the compressed bytes and unpacked once. `vio.cpp:1849` unpacks the
  head, then `:1861-1865` loops `while (rpb_incomplete) {
  DPM_fetch_fragment(); unpack(rpb, ...) }`, and `unpack`
  (vio.cpp:575-602) tests `rpb_not_packed` **on every call**. So
  NOT_PACKED is a property of the PIECE, not the record, and a chain can
  mix a raw head with a compressed tail. Joining first gives the same
  answer whenever every piece happens to be packed — which is what the
  one fixture I had contained — and on a mixed chain it refused the
  record and lost the row.

- **63 of 220 tables were unqueryable after an ordinary `gbak` backup and
  restore.** `catalog.rs` is where names are resolved, so a fragmented
  `RDB$RELATIONS` row means the table **does not exist** as far as
  fire-crab is concerned: `SELECT ... FROM <table>` answered *Dynamic SQL
  Error* on a database the engine reads perfectly. Measured before: 220
  tables, 157 queryable, 63 failed. After: **220 queryable, 0 failed.**

  The trap, and it is a good one: `SELECT COUNT(*) FROM RDB$RELATIONS`
  answered **220 correctly** the whole time. A gate that only diffs
  catalogue queries passes while a quarter of the schema is unreachable.
  The gate has to name a table in a `FROM` clause.

- **`CREATE INDEX` silently omitted fragmented rows** (`backfill_index`),
  writing an index the **real engine** then reads and finds nothing in —
  durable wrong state, not a bad plan. Also converted: `column_has_nulls`
  (so `SET NOT NULL` cannot succeed over a NULL hiding in a fragmented
  row) and `index_selectivity`.

- **A fragmented BACK version dropped the row entirely.** `tra.rs`'s MVCC
  walk did `let Some(back_data) = back.image() else { break }`, so a
  fragmented prior version broke the loop even when the primary was
  perfectly readable — and the delta path would then have applied against
  an image never fetched.

### The gate
New `qa/serve-real-fragment.sh` (12 checks). Making a record fragment on
purpose is most of the work, and two earlier attempts failed:

  1. **`LPAD('', 4000, 'x')` compresses away.** The record RLE collapses a
     run of equal bytes and the row fits after all. The payload is now
     `RPAD('', n, 'ab')` — "abab…" — which the codec cannot touch.
  2. **`PAGE_SIZE 4096` is not 4096.** Firebird 6 clamps silently to
     MIN_PAGE_SIZE (ods.h:228 = 8192), so an "8 KB row in a 4 KB page"
     experiment produces no fragments whatsoever. That one cost an hour
     of believing rows simply would not fragment.

The threshold is `page_size - 28 - 13` (dpm.epp:2383-2392), and the gate
asserts its own fixture fragments — 16 records — before it measures
anything, because a fragment gate whose fixture does not fragment is a
green run that proves nothing.

One boundary is asserted rather than fixed: fire-crab **refuses** to
write a row that would fragment, instead of half-writing one. That is a
cross-page store it does not do, and the gate pins the refusal so it
cannot quietly become a bad write.

388 unit tests.

## 2026-08-01 — The row that was nine bytes to the left

Fragment assembly. A record too large for one page is stored as a head
carrying `rhd_incomplete` plus continuation fragments, and fire-crab
could read none of them — which cost **seventeen of sixty-nine indexes**
on a 99-relation database, silently.

### Fixed
- **A fragmented record's payload was read from the wrong offset.**
  `rhdf` (ods.h:940-964) is nine bytes longer than `rhd`: it carries
  `rhdf_tra_high` @14 and a forward pointer, `rhdf_f_page` @16 and
  `rhdf_f_line` @20, so its data starts at **22**. fire-crab chose 13 or
  16 on `LONG_TRANUM` alone and never considered the third layout, so
  every fragment's payload began *on the pointer itself*. Measured on the
  live file: what fire-crab called payload started `81 81 81 | 27 10 00
  00 | 06 00` — padding, then page 4135, then line 6.

  It did not corrupt data, and the earlier record of this said otherwise:
  the RLE decoder *rejects* those bytes, so the row was dropped rather
  than mis-valued. Missing rows, not wrong ones.

- **`assembled_image` follows the chain.** Head and fragments are each
  RLE-compressed and their compressed forms **concatenate** — measured, a
  head unpacking to 828 bytes and its fragment to 754 give exactly 1582
  when joined and unpacked once, because the codec is a byte stream with
  no header of its own. So assembly joins first and unpacks last: one
  pass, and no chance of mis-splitting a run.

  The proof it recovers the right bytes: the first row it assembled
  decoded to `PK_BS2P_500` on table `BS2P_500` — the first entry on the
  list of seventeen missing indexes. After wiring it into `opt`'s four
  catalogue readers and the server's four record readers, all **69 of 69
  indexes are visible, 0 disagreements** with the engine.

- **A fabricated transaction id, caught by the fleet in code twenty
  minutes old.** My first version read `rhdf_tra_high` unconditionally
  for fragmented records. `Ods::getTraNum` (ods.cpp:157-169) reads it
  ONLY inside `if (rhd_flags & rhd_long_tranum)`, and picks the rhdf or
  rhde field by `rhd_incomplete` *inside* that test. On this fixture the
  bytes at 14 are `0x8181`, so every fragmented row would have claimed a
  transaction id 2^32 times too large — and MVCC visibility is decided on
  that number. A unit test now pins both halves of the rule.

### The design choice
`image()` now returns `None` for a fragmented record **deliberately**.
There are 41 callers; converting them all at once would be a flag day,
and handing back the head's piece would give every unconverted one a
short image whose later fields decode as missing or wrong — silently.
`None` preserves exactly what those callers did before (the mis-offset
payload happened to fail to unpack), so conversion is incremental and the
unconverted path is the safe one. Eight call sites are converted; the
rest keep skipping.

Six unit tests pin the layout, including that a chain pointing at
something without `rhd_fragment` is **refused** rather than splicing
another row's bytes onto this one.

386 unit tests.

## 2026-08-01 — A gate that read another run's log

`serve-real-index.sh` reported 33 DIFFs immediately after an optimizer
commit, where the same gate had reported 0 an hour earlier. Deciding
whether that was the commit took longer than the commit did.

It was not. The gate proves a statement did or did not use an index by
counting `"index scan:"` lines in the server's trace — at a **fixed
path**, `/tmp/fc-serve-index.log`. Two concurrent runs of the gate write
to the same file, and each then reads the other's index scans as its own,
so every negative assertion fires at once. The tell was in the output all
along:

```
DIFF a table with no index at all drove an index it has no business driving
```

which is not a thing that can happen.

The cause was mine — the gate was running concurrently with itself, and
earlier alongside a 338-statement optimizer gate and a fleet of twenty
agents. Cleanly, alone: **0 DIFFs, 359 OKs.**

### Fixed
- **`serve-real-index.sh` and `serve-real-carefulflush.sh` key their logs
  to the port.** Of 197 gates these are the only two that make assertions
  from a server log rather than merely redirecting it somewhere. The port
  already distinguishes concurrent runs; now the log follows it.

- **`qa/gate-selfcheck.sh` gained a sixth check** for the whole class: any
  gate that greps a `/tmp` log for an assertion must have every log path
  it assigns vary with the port. Teeth proven — reverting one gate makes
  it print `DIFF … serve-real-index.sh:LOG`, naming the file and the
  variable rather than just failing.

### What exonerated the commit
Three independent things, none of which needed a quiet machine:
- single-relation plans are **byte-identical** across the change (10
  statements, compared against a `HEAD~1` build of the optimizer);
- `loop_cost` and `hash_cost` have exactly two call sites, both inside
  the two-stream join block, and `choose_index` discards any plan that is
  not a one-element stream;
- the failing assertions were all *negative* ones, and one of them was
  impossible rather than merely wrong.

The third is the one worth keeping. **An impossible failure is evidence
about the instrument, not the subject** — and it was visible before any
of the rebuilding.

## 2026-08-01 — The grid had a hole in it

Four edits to `opt`'s join cost model, shipped as one increment because
each of them alone regresses a measured fixture — which is exactly why
four independent investigations of this had contradicted each other, each
having isolated one term and validated it on its own row counts.

### Fixed
- **`loop_cost` charged the row term twice.** The engine charges two
  terms and they are *not the same quantity*: `Retrieval.cpp:385` is
  `DEFAULT_INDEX_COST + selectivity * scratch.cardinality`, an index
  **page** count, and `Retrieval.cpp:1145` adds `cardinality *
  selectivity` against the **table's**. Reading both as the table's
  doubled a keyed loop's price and pushed the HASH/loop crossover out by
  a factor of two. The page term is dropped rather than converted — for a
  4-byte key at 8 KB pages it is `card/1359`, a coefficient of 1.0007
  against 1.0, and converting it needs `irtd_itype` plumbing `ods` does
  not have. That is in the roadmap, with the arithmetic.

- **The driver was free.** `InnerJoin.cpp:323` seeds `findBestOrder(0,
  ..., 0.0, 1.0)`, which *looks* like a zero — but `:377` calls
  `estimateCost(position = 0, ...)` under no guard and `:192` charges
  `loopCost = candidate->cost * cardinality` with `cardinality == 1.0`,
  and a bare natural scan's candidate cost is the stream's own row count.
  Comparing inner-side costs only cancels the driver's price: harmless
  when the sides are similar, wrong when they differ hundredfold — which
  is the shape a keyed join exists for.

- **Only one hash arrangement was priced.** fcopt costed "larger drives,
  smaller hashed" and nothing else. The engine reaches both through its
  two starting streams (`InnerJoin.cpp:318-323`), pricing the stream at
  `position` as the hashed one against the priors probing. `formRiver`'s
  swap (`:575-581`) is **post-decision** — it sits behind
  `equiMatches.hasData()`, which `:269-270` fills only after `hashCost <=
  loopCost` has already passed — so it renormalises the printed sides
  rather than restricting what gets costed.

- **A unique hashed side was over-charged.** `InnerJoin.cpp:210-211`
  caps `currentCardinality` at `MINIMUM_CARDINALITY` when the candidate
  is unique, so a unique hashed side contributes one row per probe
  however large the table is. Without it, hashing a large unique inner
  looked enormously expensive and fcopt preferred a loop where the engine
  hashes.

### The gate is the finding
`qa/opt-plans.sh`'s cost grid ran over table sizes `{0, 1, 5, 50, 500,
3000}` — and **that set has a hole from 5 to 50 that straddles the
engine's crossover**. A model can score 36/36 on it while being wrong at
every cardinality in between, and one did: against a widened set of
thirteen sizes `{0, 1, 2, 5, 8, 20, 30, 50, 120, 500, 900, 3000, 5000}`,
169 cells, the model this increment replaces scores **153/169 — and all
sixteen of its errors are in the 2-120 band the narrow set skipped**.

After the four edits: **169/169, zero refusals.** The grid in the gate is
now the widened one, in both its fresh and stale phases.

A grid that cannot fail is not a grid. Two claims about this cost model
were previously asserted twice and refuted twice, both times because the
evidence was a full score on a set too narrow to disagree.

### Not done, deliberately
- **The `DEFAULT_SELECTIVITY = 0.1` substitution is NOT in this
  increment**, though it is read, understood and quoted
  (`Retrieval.cpp:1019-1026`: a **value** test `selectivity <= 0`, per
  matched segment, and for the leading segment the `minSelectivity` floor
  is provably inert so the answer is exactly 0.1). Adding it to
  `index_selectivity` would make the stale-statistics guard *unreachable*
  as a side effect — which is the very step that was asserted twice and
  refuted twice. It goes in with the guard's removal, judged against the
  widened stale grid, as its own increment.

  That grid now exists as ground truth: on the 169 stale cells the engine
  answers every one, and fcopt today answers 4 and **refuses 165, with
  zero wrong**. The guard is load-bearing and measurably so.

- **None of this changes an executed plan.** A fleet established the
  mechanism by reading the code: `server.rs` discards any plan that is
  not a one-element `Access::Index | Access::Order` stream,
  `plan_join_bound` pushes a `TableScan` for every base side without
  calling `choose_index`, and there is no hash-join row source. This is
  plan-text fidelity — the crate's stated purpose, and a prerequisite for
  the keyed join — and the commit says so rather than implying otherwise.

## 2026-08-01 — Two ways of being slow, both measured

A fleet sent to settle three recorded gaps in `opt`'s cost model came
back having reordered its own list. Its relevance lens — an agent whose
only job was to ask "grant this finding is true; does it change any plan
fire-crab would execute differently?" — answered *no* for all three, and
then found something none of the four investigations had been looking
for. Both items below are live and user-visible; the cost-model work is
plan-text fidelity only, and is now scheduled behind them.

### Fixed
- **Taking the index cost more than ignoring it.** `records_at_in` built
  the relation's whole `sequence -> page` map — a walk of the file and a
  decode of every data page — and `records_for` called it with a
  **one-element slice per accepted record**. O(rows × pages), paid inside
  the loop. Measured on a 200,000-row / 26 MB database, the same
  statement with the index path against `FC_NO_INDEX=1`:

  | rows returned | index | scan |
  |---|---|---|
  | 99 | 100 ms | 157 ms |
  | 499 | 184 ms | 185 ms |
  | 999 | 283 ms | 149 ms |
  | 4999 | **1132 ms** | 152 ms |

  fire-crab was executing the retrieval it and the engine both chose and
  paying **7.4× the cost of ignoring it**. After hoisting the map to once
  per retrieval — the shape `dml_targets_at` already used — and replacing
  `records_for`'s linearly-scanned `Vec` dedup with a `HashSet`: 4999
  rows in **111 ms against 166 ms**, the index now faster at every size.
  A slower plan, never a wrong answer, and all three index gates stay at
  zero DIFFs.

- **Nagle was never turned off.** `grep set_nodelay crates/` returned
  nothing. The wire protocol is strictly request/response and a response
  is written in several pieces, so the kernel held each response tail
  waiting to coalesce while the client — with nothing to send until it
  had the whole answer — held its ACK under delayed-ACK. Neither side
  blocked on anything either could see; both waited on a timer. Measured:
  **200 sequential `SELECT 1 FROM RDB$DATABASE` took 17,092 ms through
  fire-crab against 293 ms through the real engine.** The engine sets
  `TCP_NODELAY` (`remote/inet.cpp:1039`); so does this now.

### Corrected
- **An earlier conclusion of this project's was right for the wrong
  reason.** "600 inserts in 38.4s with Forced Writes on vs 38.3s off —
  the sync was never the cost" still holds, but both numbers were
  dominated by ~85 ms per statement of delayed-ACK, not by the work
  either measurement was about. Every end-to-end timing this project has
  ever taken had that floor under it.

### Measured, not fixed
- **A second per-statement stall remains, and it is not the socket.**
  After `TCP_NODELAY` the same 200 statements take 8,689 ms — still 37×
  the engine. About 3.8 s of that is server CPU and the rest is waiting;
  forcing the *client* socket to `noDelay` changes nothing, and the cost
  barely scales with database size (2.3 MB → 8.9 s, 25 MB → 11.1 s), so
  it is a fixed ~44 ms per statement of something else. Named here rather
  than left as a good number.

New `qa/serve-real-idxcost.sh` (5 checks). It builds its own 200,000-row
database, because every existing gate runs on ~2.5 MB fixtures where this
pathology is invisible — they would have stayed green through all of it.
It asserts a **ratio** rather than a millisecond budget, so a loaded
machine cannot make it flaky; the defect it exists to catch was 7.4× and
the bound is 1.5×. And it uses the same three-way oracle as the rest of
the index work: the binary with the feature on, **the same binary** with
`FC_NO_INDEX=1`, and the real engine — so a row-set difference is the
index path's fault by construction, and here the comparison is a time as
well as a row set.

381 unit tests, 91 plan checks.

## 2026-08-01 — The batching swallowed the generators

A full sweep of all 191 gates — run to check the character-set work —
turned up one failure that predated it. `qa/serve-real-genrow.sh` had
been failing on seven of its eight checks, and a worktree build of HEAD
confirmed it: not a regression from that day's work, a regression from
the fetch-batching increment before it.

### Fixed
- **`NEXT VALUE FOR` in a select list answered NULL and advanced
  nothing.** When `op_fetch` began materialising every cursor through
  `branch_rows` — to bound the batch, which a 2300-row deadlock required
  — `branch_rows`'s `Plan::Project` arm destructured with `..` and
  dropped `gen_cols` on the floor. The streaming path that did the
  advance was simply never reached again.

  What made it hide: the special case for `SELECT NEXT VALUE FOR <seq>
  FROM RDB$DATABASE` has its own code path and went on working
  perfectly, so the feature looked alive from the outside.

  The advance now lives in one function, `advance_generators`, called
  from both paths. It previously existed as one copy and one omission,
  which is exactly the shape that broke. The two callers write into
  different coordinate systems — the streaming path into a decoded
  record at the synthetic `value_index`, the materialising path into an
  already-projected row at the column's output position — so the slot is
  a parameter, and that is the whole reason the function takes one.

- **The advance was persisted by a code path the fetch no longer
  reaches.** The batch path returns to the client before the single
  persistence site at the bottom of the handler, so even a correct
  advance would not have survived. `persist_generators` is now called
  from both, and writes the whole set atomically — a statement that
  advanced two sequences never persists one of them.

- **Both generator spellings were announced wrongly.** Probed with `SET
  SQLDA_DISPLAY ON`: `NEXT VALUE FOR S` describes as **NEXT_VALUE**,
  sqltype 580; `GEN_ID(S, 1)` describes as **GEN_ID**, sqltype 581 — the
  nullable form. fire-crab said GEN_ID/581 for both. A generator can
  never yield NULL either way; the engine simply announces the two
  differently, and the announcement is what a client builds its message
  from.

`qa/serve-real-genrow.sh` grows 8 → 14 checks. The new ones are the two
halves the old fixture could not reach: a **2500-row** generator SELECT,
past the ~2300 where a fetch must be split, which pins that the advance
happens at materialisation and happens ONCE rather than once per batch;
and a direct comparison of the **declared column**, which every existing
check was blind to because they compare values positionally and a wrong
name is invisible to them.

### Stated rather than hidden
- **A generator inside an EXPRESSION is still refused.** The engine
  answers `SELECT (NEXT VALUE FOR S) + 100` and `(NEXT VALUE FOR S) ||
  'x'`; fire-crab's select-list parser recognises the generator only as a
  whole item. An outage, not a wrong answer, and the gate asserts the
  refusal so it cannot quietly become one.

- **`name` and `alias` are two fields and fire-crab sets both to the
  alias.** Found while probing the above, and it is not
  generator-specific: for `SELECT X + 1 AS Y` the engine answers `name:
  ADD alias: Y`, for `UPPER('a') AS U` it answers `name: UPPER alias: U`,
  and for a plain `X AS Z` it answers `name: X alias: Z`. fire-crab
  answers the alias in both fields, for every aliased column. That is a
  projection-wide slice of its own; it is in the roadmap.

381 unit tests, 91 plan checks, 14 generator checks.

## 2026-08-01 — A CHAR(5) was twenty characters wide

A database created `DEFAULT CHARACTER SET UTF8` — the ordinary case —
stores a `CHAR(5)` in twenty bytes. fire-crab read only the byte half of
a text descriptor, and the comment where that assumption lived said so
out loud: *"byte length == character length here: charset NONE."* It was
true of every fixture and false of every real database.

### Fixed
- **A `CHAR` came back padded to its BYTE length.** `SELECT C5` returned
  twenty characters where the engine returns five — `'abc'` as `"abc"`
  plus seventeen blanks — and `OCTET_LENGTH` and `CHAR_LENGTH` answered
  `20`/`20` against the engine's `5`/`5`. On rows the **engine** had
  written. Every `CHAR` value in a UTF8 database was wrong on the wire.

- **The describe announced charset 0 for every text column.** The
  on-disk `sub_type` *is* the ttype — the character set in the low byte,
  the collation in the high one, probed: `CHAR(5) CHARACTER SET UTF8
  COLLATE UNICODE_CI` reads `772 = 0x0304`. Announcing zero told every
  client the column was `CHARACTER SET NONE`; node-firebird then widened
  the declared length four-fold, its own compensation for exactly that
  claim, and the value arrived at twenty characters.

- **An over-long text parameter was stored, and the engine could not
  read the row back.** Eleven characters fit in a `VARCHAR(10)`'s forty
  bytes, so the byte check passed. The engine refuses that parameter —
  *string right truncation, expected length 10, actual 11* — and when
  fire-crab wrote the row anyway, `SELECT` through the engine's own isql
  failed on the way **out**. A row the reference implementation cannot
  read is worse than any missing feature; the declared **character**
  width is now the first bound, with the byte bound kept behind it.

New `crates/ods/src/intl.rs` holds the character-set half of a
descriptor: the ttype split, the bytes-per-character table, the declared
character length, and the `CHAR` fit. The table is a claim about the
engine, so `qa/serve-real-charset.sh` checks it against
`RDB$CHARACTER_SETS` row by row — all 52 — before it checks anything
else, then compares reads, writes and accept/refuse across four sets
chosen for their widths (UTF8 4, UNICODE_FSS 3, WIN1252 and NONE 1), and
finishes by opening fire-crab's own database with the engine's isql and
with `gfix -v -full`.

### Guarded
- **The engine's silent 4× truncation is deliberately not copied.** A
  text value of exactly four times the declared character length is
  accepted and quietly cut down — `CHAR(5)` ← 20 characters stores
  `"abcde"`, reproducible at every width and independent of content. It
  is an engine buffer-sizing bug, and reproducing it would mean silently
  storing a value nobody asked for. fire-crab refuses, and the gate
  **asserts the divergence** rather than leaving it unsaid.

### Converted
- **A bare `?` as a whole predicate.** `WHERE ?`, `WHERE ? AND ID > 1`,
  `WHERE NOT (? OR ?)`. The engine describes it as `SQL_BOOLEAN` and
  answers it as ordinary three-valued logic, so it is exactly `TRUE = ?`
  with the `TRUE =` elided — a leaf the parser already built, with its
  describe, bind and NULL-is-UNKNOWN behaviour already probed. One
  `else` branch; nothing downstream needed to learn anything.
  `WHERE ? IS NULL`, `WHERE ? LIKE 'o%'`, `WHERE ? BETWEEN 1 AND 3` and
  `WHERE ? IN (1,2)` are different shapes the engine also answers and
  this parser covers none of — they keep refusing rather than being
  mis-read.

- **A number written as text, into every numeric column and every
  numeric filter.** The largest single hole in the parameter surface.
  Probed exhaustively — 54 spellings × 9 column types — and three of the
  rules are not what a hand-written parser would do:

  * `'1.999999'` goes into an `INTEGER` as 2 and is **refused** by a
    `SMALLINT`. The rounded result fits both; the *mantissa* (1999999) is
    range-checked before the rescale, and only the SMALLINT is too narrow
    for it. Same string, same rounded result, different answer per column.
  * a hex string is sized by its **digit count**, not its value.
    `'0x0000000000000001'` is one, and an `INTEGER` refuses it because
    sixteen digits is a BIGINT-shaped literal. The digits are then read
    as a **signed** integer at the *target's* width, so `'0xFFFF'` is −1
    in a SMALLINT and 65535 in an INTEGER.
  * the store side and the filter side **disagree with each other**.
    `'1.999999'` into a SMALLINT column is a conversion error, but
    `WHERE N_SM = ?` with the same string returns *no rows* — a filter
    asks a question, and "none" is an answer. And hex, which the store
    side takes, is a conversion error on the filter side.

  The filter comparison is **exact, not through a double**: the two
  BIGINTs `9223372036854775806` and `…807` are one single `f64`, and the
  engine picks a different row for each of those strings.

  Also reaching the filter side: text → `BOOLEAN` by the engine's name
  match (`'true'`, `'FALSE'`, `' True '`; `'t'` and `'1'` are errors),
  and text → `FLOAT`/`DOUBLE`.

### Stated rather than hidden
- **The engine's string→double is not correctly rounded.** It answers
  `100000000000000020` for `'99999999999999999'` where the nearest double
  is `100000000000000000` — one ulp high, and again for twenty nines.
  fire-crab is correctly rounded and therefore *more* accurate; copying a
  one-ulp error to match would make it less so. `qa/serve-real-textnum.sh`
  splits the check in two: twin agreement up to sixteen significant
  digits (the measured boundary — seventeen digits of `'12345678901234567'`
  agree, seventeen *nines* do not), and beyond it fire-crab is measured
  against the true nearest double instead of against the engine.

- **A non-text parameter against a TEXT column still refuses.** The
  engine does not render the value as text — it coerces the **column** to
  a number, per row: `WHERE S_VC = 5` matches `'5'`, `' 5'`, `'5.0'` and
  `'05'` alike, and *raises mid-scan* if any row holds a non-numeric
  string (adding one `'TRUE'` row makes the whole statement fail). That
  is a comparison rule rather than a conversion, it is in the roadmap,
  and the gate asserts the refusal so it cannot quietly become a wrong
  answer.

- **Transliteration is not implemented.** The engine converts a WIN1252
  column's bytes into the connection's character set on the way out;
  fire-crab passes the stored bytes through. Identical for ASCII content
  — which is what every fixture uses — and not for a high byte. It is a
  codepage-table job and `crates/ods/src/intl.rs` says so rather than
  pretending otherwise.

Two stale unit-test assertions were corrected rather than worked around:
both encoded fire-crab's *refusal* of a text parameter into a numeric
column as if it were the engine's behaviour. It never was.

381 unit tests, 91 plan checks, and two new behaviour gates —
`qa/serve-real-charset.sh` (18) and `qa/serve-real-textnum.sh` (6 over
~650 cases). `qa/gate-selfcheck.sh` caught a defect in the first of them
before any of this was committed: its second server start had no
liveness assertion, so a lost port would have produced a green run that
measured nothing.

## 2026-08-01 — The optimizer was reading the wrong selectivity

A fleet sent to teach `opt` to key an indexed inner join reported, first,
that it **already does** once statistics are fresh — correcting a premise
an earlier fleet had left me with and I had repeated. Then it found what
is actually wrong.

### Fixed
- **`index_selectivity` returned the WHOLE-INDEX figure where the engine
  uses the MATCHED SEGMENT's.** `RDB$INDICES.RDB$STATISTICS` is the
  statistic for the whole key; the engine costs a retrieval with
  `idx_rpt[j].idx_selectivity`, the figure for the segments the predicate
  actually matched. On `INDEX (K, B)` over 5000 rows with 10 distinct K
  those are **0.0002 and 0.1 — five hundred times apart**.

  It produced a plan the engine does not choose, today, with no
  contrivance:

  ```
  SELECT O.ID, I.ID FROM OUTR O JOIN INNR I ON I.K = O.K
  engine:  PLAN HASH ("I" NATURAL, "O" NATURAL)
  fcopt:   PLAN JOIN ("O" NATURAL, "I" INDEX (INNR_KB))
  ```

  A predicate is only ever matched against an index's leading segment
  here, so segment 0's figure is the one to read;
  `RDB$INDEX_SEGMENTS.RDB$STATISTICS` holds it per position, and the
  whole-index column stays as the fallback for an index whose segments
  carry nothing.

`qa/opt-plans.sh` grows to 91 checks with a fixture nothing else in it
had: 5000 rows and a **skewed** leading column, which is the only shape
that can tell the two readings apart. Four of them are the join plans
either side of the crossover.

### Also fixed: my own gate
`serve-real-carefulflush.sh` named `$srv2` in a trap it could reach
before the variable existed — under `set -u` that is a gate failing for
its own reasons. And a stray server from an interrupted run held the
port the async check needed, which the liveness assertion correctly
refused to measure around.

372 unit tests, 91 plan checks, 8 behaviour gates.

## 2026-08-01 — One cap was doing two jobs

`SELECT ... WHERE ID IN (SELECT ...)` refused as soon as the subquery
returned **65 distinct values**, on a statement the engine answers. A
fleet bisected it to exactly 64/65 and named the cause: not the
subquery, and not its desugaring into a literal list — the DNF group cap.

### Fixed
- **`DNF_MAX_GROUPS = 64` was bounding two different quantities.**
  `cross_dnf` is MULTIPLICATIVE — `(a OR b) AND (c OR d)` is a product,
  and a chain of them squares and cubes, so 64 is where that must stop.
  `concat_dnf` is ADDITIVE: `x IN (v1..vn)` grows by ONE per value, and
  65 values is an ordinary list rather than an explosion. They have
  separate bounds now, 64 and 4096.
- **The product is checked BEFORE it is built.** With a larger additive
  cap a branch can be thousands of groups wide, and multiplying first to
  refuse afterwards would allocate exactly the explosion the cap exists
  to prevent.

A 4000-value `IN` subquery answers in 0.15s — the union-of-bands
retrieval takes it in its stride. Whether it drives an index is `opt`'s
call, and `opt` refuses parenthesised predicates, so a literal `IN` list
scans; the gate asserts the answer rather than the path.

`qa/serve-real-index.sh` is 359 checks. 372 unit tests and 10 gates.

## 2026-08-01 — W3: platform I/O, and a rule my flush had got wrong

### Converted
- **The careful flush writes through `fire-crab-pio`.**
  `crates/wire` depends on it now, leaving `-lck` and `-evt` as the only
  subsystems the server never calls.

### Fixed by wiring it
- **Forced Writes is an OPEN MODE, not an fsync per write.** My flush
  synced every page unconditionally, which is *stricter* than the engine:
  `PIO_open` adds SYNC to the open mode when the header's Forced Writes
  flag is set, and does nothing per write when it is not. `pio` has held
  that rule — with the offset arithmetic and the retry count — since it
  was converted, with nothing calling it. The flush now opens with
  `plan_for_header(<the header's flags>)` and flushes at the end only
  when Forced Writes is off, which is what the engine leaves to the
  operating system.

### Measured
600 inserts in 38.4s with Forced Writes on and 38.3s with it off — the
sync was never the cost. The whole-file copy each statement makes is,
and that is a different slice. Recording it because the obvious
expectation (a per-page fsync is expensive) turned out not to be where
the time goes.

`qa/serve-real-carefulflush.sh` grows to 21 checks: the trace names which
open mode each flush ran in, a copy of the database has Forced Writes
turned off with `gfix -write async` and is written again, and `gfix`
validates both files. 372 unit tests and 11 gates.

## 2026-08-01 — Four conversions the engine makes and fire-crab refused

A fleet probing around the boolean parameter found four statements the
engine accepts and fire-crab rejected. Refusing what the engine takes is
the outage direction, so each was probed against the engine for the value
it STORES, not just for acceptance.

### Fixed
| parameter | column | the engine stores |
|---|---|---|
| `'true'` / `'FALSE'` / `' True '` | BOOLEAN | TRUE / FALSE — a NAME match, case-insensitive, blanks ignored |
| `'t'`, `'1'`, `'yes'`, `''` | BOOLEAN | **refused** — it is not a truthiness test |
| a boolean | VARCHAR / CHAR | `'1'` or `'0'`, not the word |
| an integer | VARCHAR / CHAR | its decimal digits, and **refused** rather than truncated when too long |

- `CAST(<boolean> AS VARCHAR)` renders **`TRUE`**, in capitals, while
  isql DISPLAYS the same column as `<true>`. Two renderings of one value,
  and only the cast's is a value the SQL surface can be asked about — so
  `Value::render`, which the dumpers share, keeps the lower-case form and
  the cast overrides it.

### Still refused, and now recorded rather than assumed
A bare boolean parameter as a whole predicate — `SELECT ... WHERE ?` —
which the engine answers. That is the predicate parser rather than a
conversion, and it is in the roadmap.

### A second gate with the same expired premise
`qa/serve-real-boolean.sh` also asserted "a boolean PARAMETER is refused
by both — this driver cannot encode one". Same driver update, same
expiry. It now asserts that the two servers AGREE, which is what it was
always for, and carries the seven conversions above.

372 unit tests and 11 gates.

## 2026-08-01 — A SELECT returning 2400 rows hung forever

Not a roadmap item. A fleet sent to design the index-driven join
measured the current one first, and reported that it could not: the
server stopped answering above about 2300 rows.

### Fixed
- **The fetch ignored the client's row count and answered every
  `op_fetch` with the WHOLE result.** Below ~2300 rows that is invisible —
  it all fits in the socket. Above it the server's write BLOCKS; the
  client, having read the batch it asked for, stops reading to send its
  next `op_fetch`; and neither side ever moves again.
- **A batch also has to be TERMINATED**, which is why bounding it alone
  was not enough — the first fix made *every* size hang. The client's
  decode loop runs while `count && status != 100`, so it needs one of the
  two to stop reading:

  | | |
  |---|---|
  | end of BATCH, rows still to come | `count = 0`, ordinary status |
  | end of CURSOR | `status = 100` |

- The cursor is materialised once and drained in batches. `Plan::Rows`
  was already "a materialised cursor, consumed by its fetch"; that is the
  general rule now rather than a special case.

### Two mistakes made fixing it, both caught by gates
- Materialised rows come back ALREADY PROJECTED, so their columns must
  be re-indexed positionally. Keeping the original field ids made every
  column read a record it no longer had, and **every value came back
  NULL** — eight gates said so at once.
- Materialising ran the retrieval *before* a parameterised statement's
  bands were built, so `WHERE ID = ?` quietly went back to scanning. The
  answers stayed right and only the coverage assertion noticed, which is
  exactly what it is for.

New `qa/serve-real-fetchbatch.sh` (17 checks) over a 6000-row fixture:
every shape that materialises differently, the rows either side of the
old cliff, and exact multiples of the batch size. It compares **digests**
— the first version pasted 6000 rows into a shell variable and reported
DIFFs that were its own truncation.

372 unit tests and 20 gates confirm nothing moved.

## 2026-08-01 — A gate's premise expired, and I reported it as a defect

`qa/serve-real-params.sh` asserted that a boolean PARAMETER is refused,
"as the engine refuses this driver's encoding". I found it failing, saw
fire-crab accepting where the gate expected a refusal, and recorded a
defect: *fire-crab accepts what the engine rejects*.

**That was inferred from the gate, not from the engine.** Asked directly,
the engine accepts it too, and the two databases come out byte-identical
— node-firebird 2.14.1 made boolean encoding metadata-directed, so a
BOOLEAN target now receives a real `blr_bool`. The premise was true when
it was written and had expired since.

Four failures, every one of them pointing at fire-crab, and none of them
fire-crab's. The gate now asks the engine rather than remembering what it
once answered, and its literal mirror script carries the row the
parameterised statement writes.

## 2026-08-01 — W2: the careful write order, called at last

`fire-crab-cch` has modelled the engine's precedence graph — content
before the reference to it — since it was converted, and
`qa/cch-crash-harness.sh` has gated it that whole time. **Nothing called
it.** The server flushed a modified database with one `fs::write` of the
whole file, which is correct when it completes and arbitrary when it does
not: a crash part-way through leaves whatever the operating system
happened to flush, in whatever order it chose.

### Converted
- **The DML flush writes PAGES, in precedence order.** `careful_plan`
  builds the graph from the before/after images, `flush` drains it, and
  each page is written at its offset and `sync_data`'d before the page
  that references it — an ordering that exists only in memory is not an
  ordering.
- `crates/wire` depends on `fire-crab-cch` for the first time. That
  leaves `-lck`, `-evt` and `-pio` as the subsystems the server still
  never calls.
- A file that GREW is still written whole: extending a file is its own
  careful-write question, and answering it by guessing would be worse
  than not answering it.

### Measured, not assumed
Five pages per statement instead of the whole file, and 1200 inserts in
74.1s against 79.1s before — so the per-page `sync_data` very nearly
cancels the smaller writes. **This slice does not buy speed.** It buys
the property the harness has been checking all along: every prefix of the
write sequence is a database the engine can open.

New `qa/serve-real-carefulflush.sh` (17 checks): the flush is ordered,
it touches only the pages that changed, the engine opens the result,
`gfix` validates it — and `FC_NO_CAREFUL` turns the ordering off so the
assertions can be seen to fail, the same trick `FC_NO_INDEX` earns its
keep with. 372 unit tests and 11 gates, including the ones that run
`gfix` and `gbak` over the written file.

## 2026-08-01 — W1p: a parameter's value arrives after the plan

### Converted
- **`WHERE ID = ?` reaches an index.** It could not before: a band needs
  a value, and the plan is built while the value is still a `?`. The plan
  now carries the two things `choose_index` cannot recover from a bound
  predicate — the table's name and the statement text `opt` reads — and
  the bands are built at EXECUTE, from the filter in which binding has
  already turned each `?` into a literal. Same function, same rules, one
  moment later.
- It matters because that is how a prepared-statement client asks almost
  everything. Equalities, ranges, two bounds from two parameters, and an
  `OR` of parameters all retrieve now; a parameter on an unindexed
  column still scans, and so does a NULL one.

### Found while widening the sweep, and NOT caused by this work
`qa/serve-real-params.sh` fails, and has been failing since before the
index programme began — bisected to R7 and earlier. fire-crab **accepts a
boolean parameter INSERT that the engine rejects**, so its table gains a
row the engine's has not, and the two counts diverge. It is in the
roadmap with the reproducer. The gate was never in any sweep here: I had
been running `serve-real-typedparams.sh` and assumed it covered the same
ground.

`qa/serve-real-index.sh` is 356 checks. 372 unit tests and 7 gates
confirm nothing moved.

## 2026-08-01 — W1o: the check that could not tell the difference

### Fixed
- **An INT128 key could be one byte too long.** The BCD compressor
  pushes the 4th byte of each cycle unconditionally; when the last
  3-digit group lands there and is a multiple of 256, that byte is a
  trailing `0x00` the engine's `makeBcdKey` does not write. About 2 in
  3000 random `NUMERIC(38,6)` values — which is why it took random
  full-range data to find, and why repeating digit patterns never did.

### Contained — the more important half
`entry_is_current` **cannot tell "this entry is stale" from "my encoder
disagrees with the engine"**, and it treated both as staleness. Every
encoder difference it met therefore became a MISSED ROW rather than a
wasted fetch: a scaled `DECIMAL`, a `FLOAT` segment, `i64::MIN`, and now
an INT128 one byte too long — four separate bugs, one failure mode.

The check has exactly two jobs: stop a moved row coming back twice, and
stop it appearing at its old key's position in a navigated walk. **The
first is already done by the record-number dedup.** So the check now runs
only when the walk IS the order. Outside navigation a differing key costs
a fetch and the ordinary predicate decides — the same contract the index
has everywhere else.

That does not excuse the encoder bugs, and all four are fixed. It means
the next one is a performance bug instead of a data-loss bug.

`qa/serve-real-index.sh` is 338 checks. 372 unit tests and 8 gates
confirm nothing moved.

## 2026-08-01 — W1n: three keys the engine never wrote

The fleet's full report named root causes my previous fix had only
softened. Two of these were corrupting the WRITE path as well.

### Fixed
- **A scaled value's key MULTIPLIED where the engine DIVIDES.**
  `MOV_get_double` divides by the power of ten; `raw * 10^-n` is a
  different double in the last ulp for about a third of the raws — 0.3,
  0.6, 0.7, 1.2, 1.4, 1.7 among them. So a `DECIMAL`/`NUMERIC` column
  produced keys the engine never wrote, and every row carrying such a
  value fell out of the index that held it — **in both directions**: our
  retrieval could not find them, and the engine could not find what
  fire-crab wrote.
- **A `FLOAT` column's value form was not accepted at all**, so
  `key_for` returned None for every candidate from an index holding one
  and the index answered the **empty set**. (`Value::Float` is kept
  apart from `Double` for printing; the key encoder only knew `Double`.)
  A single-segment FLOAT index scans, so this needed a compound index to
  surface.
- **`i64::MIN` now ABSTAINS at the source.** `int64_key` returns None for
  it, which makes the search key unbuildable (so the retrieval scans) and
  the candidate unjudgeable (so it is kept). The previous guard covered
  only the search key, so a row that merely *contained* `i64::MIN` in an
  indexed segment was still rejected by verification.

### Gated
The index gate carries the raws where multiply and divide disagree, a
compound index with a FLOAT segment, and a column holding `i64::MIN`.
The write gate — the one that asks the ENGINE — now writes scaled
DECIMAL keys through fire-crab and has the engine find them through its
own index, with `gfix` after.

`qa/serve-real-index.sh` is 332 checks, `qa/serve-real-descwrite.sh` 36.
372 unit tests and 7 gates confirm nothing moved.

## 2026-08-01 — W1m: fire-crab was corrupting descending indexes

The worst defect the fleets have found, and it has nothing to do with
retrieval — it is the WRITE path, and it predates every index slice.

### Fixed
- **A descending key is stored COMPLEMENTED, so plain byte order almost
  works.** It fails on exactly one shape: where one key is a byte PREFIX
  of another. Ordinary lexicographic comparison pads the shorter key
  with `0x00` and puts it FIRST; the engine pads it with `0xFF` and puts
  it LAST. `insert_index_entry` used the ordinary one, so every entry
  whose key prefixed or was prefixed by another went into the wrong
  place in the tree.

  fire-crab could not see the damage — it reads back what it wrote. The
  engine could:

  ```
  SELECT COUNT(*) FROM T WHERE D = 3    -> 0, on a table that holds it
  SELECT D FROM T ORDER BY D DESC       -> 2, 256, 257, 17, 16, 5, ...
  gfix -v -full                         -> Number of index page errors: 2
  ```

- `insert_index_entry` takes the index's direction now, and
  `node_cmp_desc` implements the engine's rule.

New `qa/serve-real-descwrite.sh` (29 checks). It asks fire-crab nothing:
fire-crab does the WRITING — over the value pairs where one encoded key
prefixes another, 16/256 and 17/257 — then the server stops and **the
engine** reads, with `SET PLAN ON` so the PLAN line proves an index was
used, and `gfix` finishes, since gfix is what named the corruption.

372 unit tests and 6 gates confirm nothing moved.

## 2026-07-31 — W1l: an entry the server cannot judge is not a stale one

The fleet's first hunter came back with four failures against the new
union-of-bands surface. Three of them were one mistake.

### Fixed
- **A key that cannot be rebuilt was read as "the entry is stale", which
  DROPS the row.** A candidate survives only if the fetched record still
  carries the entry's key — and that means rebuilding the key from the
  record. When the rebuild fails, the check has nothing to say, and it
  must therefore say nothing.

  It said plenty. A **FLOAT** column anywhere in an index made every
  retrieval over that index return the **empty set**. A scaled
  **DECIMAL** lost most of its values. And **`i64::MIN` came back**
  through this door after the search-key guard had closed the other one.
  The predicate above still decides and the record-number dedup still
  collapses duplicates, so keeping an unjudgeable candidate costs a
  comparison; dropping one costs a row.
- **Row order without an `ORDER BY` is not arbitrary — it is the
  engine's.** Its non-navigational retrieval ORs the branches into a
  record-number bitmap and returns rows in RECORD order; ours came back
  in band order, then key order within a band. With no `ORDER BY` that is
  an unordered result either way, until `FIRST 2` makes it a different
  **set of rows**. Candidates are sorted by record number now unless the
  walk *is* the order.
- **Navigation is restricted to key families the server can rebuild
  exactly.** Trusting a walk's order means trusting that its entries can
  be judged.

### And a regression I introduced fixing them
Deduplicating candidates when they are COLLECTED rather than when they
are ACCEPTED let a stale entry shadow the valid one: a record named first
by its stale entry was skipped as a duplicate when its current entry
arrived, and the row vanished. The moved-key checks caught it
immediately, which is what they are for.

`qa/serve-real-index.sh` grows to 322 checks. 371 unit tests and 7 gates
confirm nothing moved.

## 2026-07-31 — W1k: OR is a union of bands, and so is IN

### Converted
- **A disjunction retrieves through one band per branch.**
  `A = 1 OR A = 2` is two bands of one index; `A = 1 OR B = 2` is one
  band of each of two. `IN (...)` desugars to exactly that at parse
  time, which is where most of the value is.
- New `IndexAccess` — the access path for a retrieval is a *set* of
  bands, and the plan carries it. `choose_index` splits into a
  per-branch `pick_for_terms`.

### Guarded
Two rules, both of which decide correctness rather than speed:
- **Every branch must be servable, or the whole statement scans.** A
  partial union is a *missing set of rows*, not a slower answer. One
  branch on an unindexed column, or one shape no band can express, and
  the retrieval declines entirely.
- **Candidates are deduplicated ACROSS bands.** A row can satisfy two
  branches — most obviously when the branches use different indexes —
  and would otherwise be returned twice. The gate asks for it directly:
  the same branch twice, and `ID = 1 OR DEPT_ID = 1` where one row
  answers both.
- Navigation belongs to the single-band case only: a union of bands has
  no single order to inherit.

`qa/serve-real-index.sh` grows to 306 checks. 371 unit tests and the
write-path gates confirm nothing moved.

## 2026-07-31 — W1j: the wrong record, not the missing one

The adversarial fleet's full report arrived after the previous fix, and
corrected it. The deleted-row failure was real but the cause was not the
one I fixed.

### Fixed
- **`records().nth(slot)` is not the record at slot `n`.**
  `DataPage::records()` filters out RELEASED slots, so once a deleted
  row's version is garbage-collected — which any ordinary read does —
  the iterator shifts and every entry after the hole fetches **someone
  else's record**. That is worse than a missed row: a wrong record can
  satisfy the predicate and be returned, or written. `record(slot)`
  indexes the slot directly.
- The sequence→page mapping fixed in the previous increment was also
  wrong, and both were needed; only this one produced wrong ROWS.

### Gated where it could not be gated before
Both remaining reproducers need **the engine** to do the writing —
fire-crab performing the same statements does not produce either. So the
fixture now mutates through `isql` before any server starts: a delete
followed by a read that collects the dead version and releases its slot,
and a key that leaves and returns inside one engine transaction (which
leaves two live entries with the same key and record — what a stored
procedure touching a column twice produces).

`qa/serve-real-index.sh` grows to 306 checks. 371 unit tests and the
write-path gates confirm nothing moved.

### On the fleet
Six agents, ~17,000 statements, one report that named a root cause I had
guessed wrong. The three-way oracle is what did it: the second server is
the same binary with `FC_NO_INDEX=1`, so "index bug or SQL-surface
difference" was never a question anyone had to argue about.

## 2026-07-31 — W1i: four more the fleet found, and one capability withdrawn

### Fixed
- **A deleted row moved every later row out of reach.** A record number
  names its page by SEQUENCE, and the sequence is not the page's
  POSITION in the relation's page list — a freed page leaves a gap. The
  lookup read the wrong page, failed its own sanity check, and dropped
  the row: **one deleted row hid every key stored after it**. The mapping
  is a lookup now, not an index.
- **A key that leaves and comes back was returned twice.** The writer
  skips an entry it already holds, but only within the leaf page it
  descended to — so `K 20 → 25 → 20` can leave two identical entries in
  different pages, **both of them current**. Verification cannot separate
  those: same key, same record. One row per record, however many entries
  name it.

### Withdrawn
- **A DESCENDING index is no longer keyed at all**, and that is measured
  rather than cautious. Complementing the key reverses byte order, which
  the bounds could swap for — but it also destroys the PREFIX
  relationship variable-length keys rely on: with `'ab'` and `'abc'` in
  one descending text index, equality on `'ab'` found **nothing**, and
  equality on a descending integer index missed rows too. Two measured
  misses in one piece of arithmetic is enough. It scans until the layout
  has been read back off the engine's own index.

### How they were found
An adversarial fleet of six agents, each with its own strategy, ran
~17,000 statements through a three-way oracle: fire-crab with index
retrieval, **the same binary with `FC_NO_INDEX=1`**, and the real engine.
That middle server is what makes the method sharp — a difference between
it and the first is an index bug by construction, with no argument about
whether the SQL surface agrees with Firebird. Every failure above needed
a shape no fixture in this gate had: a page boundary, a freed page, a key
that returns, a value that extends another.

`qa/serve-real-index.sh` grows to 291 checks. 12 gates and 371 unit tests
confirm nothing moved.

## 2026-07-31 — i64::MIN: a key the engine builds through an overflow

### Fixed
- **`WHERE A = -9223372036854775808` returned nothing** where the engine
  returns its rows. With the index path switched off the same server
  answered correctly, which localised it immediately: the key, not the
  comparison. The engine's `make_int64_key` negates the value before
  choosing a scale factor, and negating `i64::MIN` overflows — so its
  scale-control choice differs from the arithmetically correct one and
  our key lands elsewhere in the tree.
- Retrieval refuses to key that one value and scans instead, which is the
  standing rule: a key that cannot be built exactly must not be used,
  because the failure is a missed row rather than a refusal.

### Named, not fixed
The WRITE path still stores our key for `i64::MIN`, so a row fire-crab
inserts with exactly that value carries an index entry the engine's own
lookups may not find. Closing it means reading the engine's actual key
bytes for that value. It is in the roadmap with the reproducer.

`qa/serve-real-index.sh` grows to 275 checks, with both BIGINT extremes
in the fixture — the largest keyed, the smallest asserted to scan.

## 2026-07-31 — W1h: a duplicate run that spans leaf pages lost 2306 of 2310 rows

Found by an adversarial fleet, not by a gate — and no gate here could
have found it.

### Fixed
- **The B-tree descent landed on the LAST interior node with the target
  key, not the first.** A non-leaf node's key is the LOWEST key of its
  child page, so when one value's duplicates span several leaf pages,
  *several* non-leaf nodes carry that same key. Advancing while
  `key <= target` walks past every earlier page that also holds it. The
  child that can contain the first occurrence is the last one whose key
  is **strictly less** than the target.

  ```
  2310 rows, all A = 1, PAGE_SIZE 4096:
  SELECT COUNT(*), MIN(ID) FROM H2310 WHERE A = 1
      -->  4 | 2307        the engine:  2310 | 1
  ```

  The rows were not filtered out — they never became candidates, so the
  predicate above never saw them. Aggregates, `FIRST`, `GROUP BY` and
  the DML target walk all inherited it.

### Why no gate caught it
Every fixture in `qa/serve-real-index.sh` was a handful of rows, and a
handful of rows is **one leaf page** — the page-boundary behaviour was
untestable by construction. The gate now carries a 6000-identical-key
run and asks eight questions across it. The same reasoning killed a
planned unit test: building such a tree in memory means letting the
writer split, which needs a page-inventory page, and a hand-built one
produced a tree the writer walked forever. The comment in `btr.rs` says
so, so the next person does not re-attempt it blindly.

`qa/serve-real-index.sh` grows to 271 checks. 9 gates and 371 unit tests
confirm nothing moved.

## 2026-07-31 — W1g: a compound index's leading segment, and text keys

### Converted
- **An equality on the LEADING SEGMENT of an ascending compound index.**
  A compound key stuffs its segments together, so `A = 1` on an `(A, B)`
  index names a contiguous BAND: the lower bound is the key of
  `(1, NULL, ...)` — which is exactly what the engine writes for that row,
  so it cannot miss the NULL-tailed ones — and the upper bound is that
  prefix's **exclusive successor** (`prefix_successor`: increment the
  last byte, dropping trailing `0xFF`s and carrying left).
- **Text equality**, on `VARCHAR` and `CHAR`, with an ASCII literal. The
  encoder strips trailing blanks on both sides, which is the same
  pad-insensitivity the comparison has, so a CHAR value and a VARCHAR
  literal meet at the same key.

### Guarded
- **The upper bound is the whole slice.** An INCLUSIVE bound at the
  prefix itself admits only the all-NULL-tail key and silently drops
  every row with a value in its trailing segments. Every compound check
  in the gate has rows on both sides of that line.
- A **range** on a compound leading segment still scans: `<= v` ends at
  the successor of v's band while `< v` ends at the band's start, and two
  rules for two adjacent operators is how a missed row ships.
- A **descending** compound index still scans: the complement covers the
  markers and the padding, so the successor would have to be computed
  before it, with the bounds swapped.
- A **non-ASCII** literal still scans: above `0x7F` a charset or
  collation decides the bytes, and a key that differs from the stored one
  does not refuse — it misses.

`qa/serve-real-index.sh` grows to 247 checks. 27 gates and 371 unit tests
confirm nothing moved.

## 2026-07-31 — W1f: a row that moved was returned twice

### Fixed
- **An index entry outlives the version that wrote it, and that is not
  merely a wasted fetch.** An UPDATE adds the new key and leaves the old
  one for garbage collection, so a record whose key changed is named by
  **both** entries. A range covering both fetched it twice — and the
  predicate cannot catch that, because the row genuinely matches. In a
  navigating retrieval it was worse: the row also appeared at the OLD
  key's position, so the order was wrong too.

  ```
  UPDATE T SET ID = 20 WHERE ID = 1;
  SELECT ID FROM T ORDER BY ID;   -- [20, 2, 20]   engine: [2, 20]
  ```

  This was live for two increments — ranges, then navigation — and no
  gate caught it, because none of them changed a key column and then
  asked a question whose range spanned both keys.
- **The fix is the engine's own rule**: `btr::lookup_range` returns
  `(key, record number)` pairs now, and a candidate is kept only when the
  fetched record STILL CARRIES that key (`IndexPick::entry_is_current`,
  which rebuilds the key from the record with the same encoder). That
  makes the earlier claim true rather than approximately true.

### Converted
- **`UPDATE`/`DELETE ... WHERE` retrieve through the index.** A write
  reads before it writes, and `collect_dml_targets` had been walking
  every page — it never appeared in any count of retrieval sites because
  it has its own scan rather than calling `for_each_record`.

`qa/serve-real-index.sh` grows to 200 checks, with a section that moves a
key to the far end of the tree and asks every question whose range spans
both places. 28 gates and 370 unit tests confirm nothing else moved.

## 2026-07-31 — A UTF8 database could not be written to at all

### Fixed
- **A text index on a UTF8 column is stamped `idx_metadata` (itype 4),
  not `idx_string`**, and `resolve_index_ops` did not list itype 4. It
  returns None for the WHOLE RELATION when any index carries an itype the
  write path cannot key, and the INSERT planner takes that with `?` — so
  on a UTF8 database, **the default character set in this project's own
  hands-on samples**, a table with a text index accepted no INSERT and no
  UPDATE whatsoever. The engine took both. Reads worked, which is exactly
  why it went unnoticed: every gate here builds its scratch database in
  the default NONE charset.
- `btw::index_key` had encoded itype 4 correctly all along
  (`INTL_string_to_key` for `ttype_metadata`: plain bytes, trailing
  spaces stripped, an empty value padding to `0x00` rather than the blank
  `idx_string` uses). The conversion was right; the accept-list was one
  name short.

New `qa/serve-real-utf8index.sh` (20 checks). Its decisive check is not
that fire-crab accepts the write: the server is stopped and **the engine
reads the file back through its own index**, with `SET PLAN ON` so the
PLAN line proves an index was used rather than a scan — a key written
differently from the engine's would find nothing there — and `gfix -v
-full` then validates the pages.

## 2026-07-31 — W1e: the foreign-key check stops scanning

### Converted
- **`fk_partner_has` drives the parent's own index.** "Does a parent row
  with this key exist" is an EXISTENCE test, and the referenced side
  always carries a unique index because SQL requires one. It had been
  answered by scanning the whole referenced relation **once per written
  row** — its own comment already said *the engine compares partner
  index keys*.
- **The whole key is known here, so a COMPOUND index is a point lookup**
  rather than a prefix range. This is the one place where a
  multi-segment key is the easy case, and the write path's encoder
  already stuffs compound keys byte-exactly.
- Same safety rule as every other retrieval: the index names candidates
  and the same pad-insensitive comparison still decides. A text key
  cannot be built byte-exactly yet, so it **scans** — and the gate
  asserts that it scans.

### Fixed
- **The roadmap's "30 `for_each_record` sites" was a remembered number,
  not a measurement.** There are 21, and most are catalog walks that are
  not query retrieval at all. The sites that matter are four, and two
  had never been named: this one, and `collect_dml_targets` — which
  walks every page for `UPDATE`/`DELETE ... WHERE` and never appeared in
  the count because it has its own scan rather than calling
  `for_each_record`.

`qa/serve-real-index.sh` grows to 186 checks, with an `fk lookup:` trace
line and assertions in both directions. A `both_refuse` helper joins it:
fire-crab has no constraint-violation TEXT of its own (a generic error
where the engine names the constraint and the offending key), which is a
pre-existing gap, so those checks assert that both sides refuse rather
than pretending the wording matches.

21 gates and 369 unit tests confirm nothing moved.

## 2026-07-31 — W1d: the sort an index makes unnecessary

`Access::Order` — the engine's navigation. An index walk already
delivers its rows in key order, so the sort above it re-establishes an
order that is already there.

### Converted
- **A navigating retrieval drops the `Sort`.** `ORDER BY <primary key>`
  walks the index and streams; `WHERE ID > 2 ORDER BY ID` bounds the
  same walk; `FIRST 3 ... ORDER BY ID` reads three rows' worth of the
  tree instead of sorting the relation.
- **An ORDER BY alone is now reason enough to use an index** — until
  now a predicate was required, so the commonest ordered query in the
  language could not reach one.
- **BOUNDS BEAT NAVIGATION.** When the predicate's index and the order's
  index differ, the bounded retrieval wins and the sort runs: reading a
  few records beats walking the whole relation to save a sort. When they
  are the *same* index you get both. That is opt's rule too.

### Guarded
Row order is part of the answer, and a sort dropped wrongly does not
lose rows — it returns the right rows in an order the engine did not
choose. So navigation is taken only where the index's order is **total
and identical** to the clause: one ascending key, no explicit NULLS
placement, a plain field, an ascending single-segment index that is
**unique**, and a **NOT NULL** column. Each exclusion is gated:

- a DESCENDING order (the walk goes the other way);
- a NON-UNIQUE index — duplicates come back in record-number order, which
  the engine has never promised;
- a **unique index on a NULLABLE column**, because an all-NULL key is
  exempt from uniqueness, so two rows can share the empty key and tie;
- two keys where the index has one; an explicit `NULLS LAST`; a column
  with no index.

The index-vs-scan-vs-engine equivalence checks now compare *sequences*
over navigated orders, which is what makes those exclusions checkable
rather than argued.

`qa/serve-real-index.sh` grows to 171 checks. 33 gates and 369 unit
tests confirm nothing moved.

## 2026-07-31 — W1c: the fold reads through a retrieval too

### Converted
- **A grouped query's leaf is chosen the same way** as a projection's.
  `Plan::Group` carries the access path, and both trees that build a
  fold (`branch_rows` and the emit) take it — so `GROUP BY` over an
  indexed `WHERE` looks up instead of scanning.
- **The prepare-time aggregate walk** — the fast path a lone `COUNT`,
  `SUM`, `MIN` or `MAX` takes — reads its candidates through the same
  leaf. It was the one retrieval site the previous slice named and left
  scanning, with the gate saying so.
- One function, `leaf_source`, now states "index or scan" for every site
  that builds a tree.

### Fixed
- **The aggregate's choice was made and never logged**, so the coverage
  check could not see it: the gate reported a scan for a statement that
  was using an index. A coverage assertion is only as good as what it
  can read, and an unlogged decision is invisible to it in exactly the
  same way as a decision never made.

### Guarded
- **A `HAVING` clause makes the whole statement scan**, because `opt`
  does not parse one and declines it — even though the `WHERE` beside it
  is the same indexable predicate that drives an index without the
  HAVING. That is the right way round: a component that cannot read the
  statement must not be asked to bless it. The retrieval inherits the
  optimizer's limits, and the gate asserts the scan so the day opt
  learns HAVING, the check notices.

`qa/serve-real-index.sh` grows to 146 checks. 29 gates and 369 unit
tests confirm nothing moved.

## 2026-07-31 — W1b: ranges, and the bound that was never asked for

### Converted
- **`btr::lookup_range`** — one descent, then a forward walk to the
  upper bound. Each bound is optional and carries its own inclusivity,
  so `>`, `>=`, `<`, `<=` and `BETWEEN` are one code path. `lookup_key`
  is now the degenerate case where both bounds are the same key,
  inclusive: the descent and the stop condition are the part that is
  easy to get subtly wrong, and there is one of each.
- **A conjunction NARROWS**, so several comparisons on one column
  combine into a single range: `ID >= 2 AND ID >= 4` starts at 4, and an
  equality beside a range collapses to a point.
- **A DESCENDING index is served by swapping the bounds.** Its keys are
  complemented, so the tree's byte order is the reverse of the value
  order — and `key_for` has already complemented the bytes, which makes
  the swap the whole adjustment.

### Fixed
- **Every range on a primary key was still scanning.** `opt` answers
  `Access::Order` — not `Access::Index` — when an index NAVIGATES the
  `ORDER BY`, and `SELECT ... WHERE ID > 3 ORDER BY ID` is exactly that.
  So the shape that most obviously wants an index was the one shape
  refusing it, while `WHERE DEPT_ID > 3 ORDER BY ID` used one, purely
  because its ORDER BY named a different index. Both answers mean "an
  index serves this"; the retrieval half is taken and the sort still
  runs above it.

### Guarded
- A column with NULLs under an upper-bounded range: NULLs are stored as
  a **zero-length key**, which sorts before every value, so the range
  sweeps them up as candidates and the predicate throws them out. A
  wasted fetch, never a wrong row — the same property the whole slice
  rests on, gated explicitly.

`qa/serve-real-index.sh` grows to 125 checks (17 of them ranges, plus
the index-vs-scan-vs-engine equivalence over a range, a range with NULLs
below it, and an empty one). 48 gates and 369 unit tests confirm nothing
moved.

## 2026-07-31 — W1: the first index-driven retrieval

Programme W begins. Every query here was a full scan; a converted
optimizer chose access paths that nothing executed. Both of those are
now less true.

### Converted
- **`btr::lookup_key`** — the retrieval half of `BTR_lookup`: descend to
  a key, collect the record numbers of the entries that equal it,
  following the sibling chain while duplicates continue. `ods` could
  walk a whole leaf level before this; it can now find a key.
- **The server asks `fire-crab-opt` for the access path.**
  `crates/wire/Cargo.toml` depends on it for the first time, and
  `plan_query` — the same converted cost model whose PLAN output is
  gated against the live engine — decides. When it answers NATURAL, this
  scans, whatever the predicate looks like.
- **`RowSource::IndexScan`**, a leaf beside `TableScan`. The tree above
  it is identical either way: the same `Filter`, the same `Sort`. An
  index narrows what is READ and never what is ANSWERED, which is what
  makes "the answers do not move" a property of the shape.
- The choice is made at PREPARE and carried on `Plan::Project`, which is
  where the engine makes it too.

### Fixed
- **Re-inserting a deleted key was refused**, against an engine that
  accepts it. Uniqueness was read from the index ENTRIES, and entries
  outlive their records — an UPDATE adds the new key and leaves the old,
  a DELETE removes nothing. The conflicting records are fetched and
  their keys recomputed now; only a live record that still carries the
  key is a duplicate. The cheap entry-level check still runs first and
  only its REJECTION is re-examined, so a duplicate this cannot disprove
  is still a duplicate.

### Guarded
- The mechanics are deliberately narrow — single-segment integer indexes
  at scale 0, against an integer literal — because a key this cannot
  build byte-exactly is not a refusal but a **missed row**, the one
  failure the predicate above cannot catch. Scaled numerics, text (a
  collation makes the key a collation key), compound prefixes, ranges,
  `IS NULL`, `OR` and parameters all scan.

New `qa/serve-real-index.sh` (90 checks) is gated twice: the answers
against the engine, and **the access path itself**, read from the
server's own log — because "wired in but never used" passes every
behaviour gate. It asserts an index for the shapes that have one and a
scan for the shapes that do not, runs a second server with the index
path switched off (`FC_NO_INDEX`) to prove the coverage checks can fail,
and interleaves DML so a stale entry has to be survived rather than
assumed away. 45 gates and 368 unit tests confirm nothing moved.

## 2026-07-31 — R7: the textual rewriting is gone

The end of Programme R. A view was answered by **rewriting the query
against its base table**; it is a **row source** now, like everything
else the tree reaches.

### Converted
- **A VIEW is planned, not expanded.** Its stored SELECT is planned on
  its own; the outer query resolves against that plan's DESCRIBE; its
  declared column names are laid over the body's, positionally. In a
  join it is a SIDE, which is R5a serving a second caller.
- **~870 lines deleted**: `expand_view`, `expand_view_join`,
  `qualify_idents`, `replace_qualified_col`, `mentions_bare`,
  `replace_table_ref`, `replace_idents` — and with them the laws they
  implemented by hand. The view's own WHERE going into a join step's ON
  when the side can be NULL-padded, and into the outer WHERE when it
  cannot, was an emulation of *the filter sits inside the inner plan,
  below the padding*. The tree gets that by construction.
- **The derived-table planner and the CTE planner became ONE
  function** (`plan_over_source`): a query over a bound name, whose
  source is either materialised rows or an inner plan. R6's recursive
  CTE, R4's derived table and R7's view all enter through it.
- **Three shapes the rewriting could not express now answer**: a view
  whose own body JOINs (there was no single table to rewrite to), a view
  under a RIGHT or FULL join, and a bare renamed column in a join.
- **GROUP BY over a derived table** — a refusal R4 recorded — answers:
  the fold above a materialised base is what a grouped join with no
  parts already is.
- **A derived table may name its own columns**: `(SELECT ...) X (A, B)`,
  probed against the engine. That is also how a renaming CTE keeps its
  names now, instead of the rewriting refusing it.
- Every CTE is materialised as a derived table; the INLINING pass is
  gone. A chain of CTEs is spliced into the next body in declaration
  order, so each inner query names only real relations.

### Fixed
- **`qa/serve-real-alias.sh` could not pass.** Its second-phase liveness
  check tested `$srv` — the first server's pid, cleared two lines
  earlier — so the gate exited 1 before phase 2 ever ran. Twelve checks
  had never executed. The mirror of a gate that cannot fail is a gate
  that cannot pass, and both report something untrue.
- **`ident_ok` accepts `3`**, so a derived table's column list would have
  taken a numeric literal as a column name. An unquoted identifier starts
  with a LETTER; a delimited one may be anything, and the callers that
  have already stripped the quotes cannot tell the two apart. New
  `bare_ident_ok` for the unquoted case. (The central fix breaks `"3"`,
  which the engine accepts — the trap is worth stating rather than
  papering over.)

44 gates and 366 unit tests are the safety net; four gates promoted
refusals to comparisons.

## 2026-07-31 — R6: WITH RECURSIVE, a fixpoint over the tree

The capability the whole row-source programme was built toward: the one
CTE shape that **cannot** be answered by rewriting text, because the name
it must resolve is its own.

### Converted
- **`WITH RECURSIVE` evaluates as a FIXPOINT.** The seed runs once; the
  recursive branch is then evaluated against the last level's rows until
  a round produces nothing; the accumulated rows are the CTE. The loop is
  a dozen lines — R5a is what made it expressible.
- **The hierarchy walk goes to the ORDINARY join planner.** `FROM ORG O
  JOIN C ON O.PARENT = C.ID` binds `C` to the rows in hand as a join
  side (`RowSource::Rows`), and nothing else about the join changes: not
  the ON, not the outer padding, not the qualifiers, not a grouping above
  it. The same binding serves the final query, so the CTE joined to a
  real table — and to *itself* — needed nothing of their own.
- **Aggregating the accumulated rows reuses the grouped join.**
  `SELECT COUNT(*) FROM C` is a fold over a materialised base, which is a
  `Plan::JoinGroup` with no parts; GROUP BY, HAVING and every aggregate
  arrived together.
- **A CTE may name its own columns** — `WITH RECURSIVE C(X, Y) AS ...` —
  where the seed supplies only the values.
- **`Plan::Scalar` is a row source** in `branch_rows`: a lone aggregate
  plans to a scalar, and `SELECT MIN(ID) FROM T` is an ordinary seed.
- `WITH RECURSIVE` on a body that never names itself is an **ordinary
  CTE** and takes the ordinary path — the keyword is a declaration, not a
  fact.

### Guarded
- **Two self-references answered.** `FROM C C1 JOIN C C2` is a fixpoint
  over a product; the engine rejects it, and binding both sides to the
  same rows produced a plausible answer instead. Now counted: exactly one
  reference in the recursive branch, which is the engine's rule.
- **`ORDER BY` inside a branch answered.** A union branch carries no sort
  of its own; the engine rejects it and this sorted the branch.
- Non-termination is bounded at **1024 levels**, the engine's own limit,
  so a runaway fixpoint raises rather than hangs.

Both wrong answers were found by PROBING, not by reasoning — each looked
entirely reasonable. The new gate therefore asserts the refusal *and*
asserts that the engine rejects the same statement, so it cannot drift
into enforcing a refusal the engine does not share.

New `qa/serve-real-recursive.sh` (43 checks). `qa/serve-real-cte.sh`
grows to 35 with its `WITH RECURSIVE` refusal promoted to a comparison.
23 planner gates and 365 unit tests confirm nothing moved.

## 2026-07-31 — R5a: a derived table as a side of a join

The prerequisite R6 turned out to need, and the refusal both R4 and R5
had recorded.

### Converted
- **A join side may now be a DERIVED TABLE.** `JoinSide`, `JoinPart` and
  `Plan::Join` carried a relation id and its formats; they carry a **row
  source** now, so a side is either a scan or an inner plan. On the left,
  on the right, on both, under an outer join, with the join grouped above
  it.
- **The execution half needed nothing.** `RowSource::NestedLoopJoin`
  already took a `RowSource` per side and never cared where the rows came
  from — that was R3's shape paying for itself. The work was all in
  planning: a derived side's columns and descriptors come from the inner
  plan's DESCRIBE rather than from a relation.
- **A materialised CTE can be a join side**, which was R5's stated
  refusal: the CTE's name is spliced in that position like any other,
  with the splices applied in descending offset order so an earlier one
  cannot move a later one.
- New `RowSource::PlanRows` — an inner plan as a leaf, evaluated when the
  tree is pulled rather than when it is built, so a plan is still a plan
  at prepare time.

### Fixed
- **`FROM (SELECT A, B FROM T) X JOIN ...` was read as a COMMA JOIN
  LIST.** `parse_from` tested `from_s.contains(',')` — and a derived
  table's own select list has commas in it. The depth-aware split was
  already there and already used two lines later; only the TEST was
  naive. It is the third clause-splitting bug this programme has found in
  the same shape: a keyword or separator inside a nested query is not
  this query's.
- `parse_table_ref` and the JOIN scan are paren-aware for the same
  reason.

`qa/serve-real-derived.sh` grows to 41 checks and `qa/serve-real-cte.sh`
to 35, with the CTE refusal promoted to three comparisons. 13 join and
subquery gates plus 363 unit tests confirm nothing moved.

## 2026-07-31 — R5: the materialised CTE

### Converted
- **A CTE body the inlining cannot rewrite is MATERIALISED** — because a
  CTE whose body cannot be inlined **is a derived table by another
  name**. `FROM C` becomes `FROM (<body>) C`, and R4's machinery plans it
  properly: inner query planned on its own, columns from its describe,
  rows as a leaf.
- So a CTE body that **GROUPS**, **stars**, or **JOINS** now answers.
  Those three were refusals one increment ago, and the fix is a rewrite
  of one FROM item — because the hard part was already built.
- **A grouped PLAN became a row source.** It could not be one before the
  fold was a node: materialising a grouped query meant repeating
  scan-filter-aggregate-sort by hand, so nothing did, and a grouped CTE
  or derived table had nowhere to get its rows. `branch_rows` now builds
  the same `TableScan → Filter → Aggregate → Sort` the emit path does.

### Guarded
- A CTE with an explicit **renaming** column list AND an unexpandable
  body refuses: a derived table carries the body's own names, so
  answering under the renamed ones would be wrong. The list is detected
  as explicit by DIFFERING from what the body itself names, which is the
  only signal available at that point.
- A materialised CTE as one **side of a join** still refuses — that needs
  derived tables in joins, a later slice, and it must keep refusing
  rather than half-work.

**The bug worth recording**: the rewrite spliced the body in by searching
for the CTE's name with `cur.find(table_s)` — and for a CTE named `C`
that found the **C inside `SELECT`**, producing `SELE(SELECT ...) CT
COUNT(*)`. The position has to come from the slice itself
(`table_s.as_ptr() - cur.as_ptr()`), since `split_query` returns
subslices of the text. A one-letter identifier is not an unusual name for
a CTE, and a text search for one is never safe.

`qa/serve-real-cte.sh` grows from 29 checks to 33; three of its refusals
become comparisons. 17 gates and 363 unit tests confirm nothing moved.

## 2026-07-31 — R4: derived tables

**The first capability the row-source tree unlocks**, and the reason it
could not be reached before is worth stating: every earlier "query over a
query" here worked by SUBSTITUTING A NAME. A view has a catalog entry; a
CTE has one written in the statement. Both could be expanded into the
FROM and re-planned. **A derived table has neither** — its columns exist
only because the inner query ANNOUNCES them, and its rows exist only
because something RAN it.

### Converted
- **`SELECT ... FROM (SELECT ...) X`**, with the outer projection, WHERE
  and ORDER BY resolved against a synthetic view built from the inner
  plan's **describe** — the same move the join makes with its combined
  row and the group makes with its folded one. The describe is the right
  source: if the outer query and the CLIENT disagree about a column's
  type, one of them is wrong.
- The inner plan's rows become a materialised leaf, with the outer WHERE
  and ORDER BY as nodes above it: `Rows → Filter → Sort`.
- Renamed and computed inner columns work, because they are exactly what
  an announcement is for; so do nested derived tables, FIRST/SKIP/
  DISTINCT above one, and a derived table as a row source for
  `INSERT ... SELECT`.

### Fixed
- **The clause splitter was not paren-aware.** It found the first
  `WHERE`/`GROUP BY`/`HAVING`/`ORDER BY` keyword ANYWHERE in the text, and
  a derived table puts one inside parentheses — so the outer statement
  was torn in half at the inner query's WHERE. `FROM` had been found at
  paren depth 0 since `SUBSTRING(S FROM 2)` needed it; now every clause
  keyword is. That change touches EVERY statement, which is why the new
  gate ends with subquery, grouped and `SUBSTRING` checks that have
  nothing to do with derived tables.

### Guarded
- A column the inner query did not project refuses rather than answering
  NULL; `GROUP BY` over a derived table refuses (the fold has to run
  above the leaf — a later slice); and a derived table with no alias
  refuses, because SQL requires the name.

`qa/serve-real-derived.sh` is new, 32 checks. 38 behaviour gates and 363
unit tests confirm nothing else moved.

## 2026-07-31 — R3: NestedLoopJoin is a node

### Converted
- **`RowSource::NestedLoopJoin`** — every left row against every right
  row, kept when the ON answers TRUE, with the KIND deciding what
  happens to a row that finds no partner. `join_rows` no longer folds:
  it **builds a left-deep tree** and pulls it.
- **Left-deep is the point.** `A JOIN B ... JOIN C ...` is `(A ⋈ B) ⋈ C`,
  so the second ON may name A or B and each step's kind applies to
  everything accumulated so far. The fold expressed that by carrying an
  accumulated width; the tree makes it **true by construction**, and the
  width is just where the right side's fields begin.
- **The WHERE is a `Filter` above the whole join, not inside a step** —
  a predicate pushed into a step would see a row before its outer
  padding existed. That was already true and is now structural.
- `TableScan` gained the stream's record **width**: a join side's rows
  are padded so the combined row's field offsets are the same for every
  row, matched or padded. The single-relation scans pass `None`.

The node's unit test decides the ON with a constant rather than
resolving one, because what has no analogue elsewhere is the KIND: with
a false ON an INNER join drops the row and a LEFT keeps it **padded to
the combined width** — which is the check that gives the width field a
reason to exist.

11 join gates green, 363 unit tests, no behaviour change.

## 2026-07-31 — R2: Aggregate is a node

### Converted
- **`RowSource::Aggregate`** — the engine's aggregated stream as a tree
  node: `input` folded into one row per distinct key, with HAVING
  filtering the FOLDED rows rather than the input ones. A query with no
  GROUP BY is the single global group, which is the same node with no
  keys.
- `group_output` now *builds* `TableScan → Filter → Aggregate` rather
  than spelling those three out, and both grouped emit paths build the
  full `… → Sort` above it. **The fold itself (`group_rows`) has exactly
  one caller now — the node.** Before this it had three.
- The grouped JOIN path composes the same nodes over a materialised
  leaf: `Rows(joined) → Aggregate → Sort`. That is the first place the
  tree is seen STACKING rather than replacing a single loop, and it is
  why the `Rows` leaf earned its place in R1.

**Where Sort sits is a claim, not a detail.** It goes ABOVE the
Aggregate, because a grouped query's ORDER BY keys are OUTPUT indexes
and the folded rows are aligned with `gitems`/`cols` — while a plain
projection's ORDER BY indexes the RECORD's fields, so there the Sort
goes BELOW the projection. Both facts were already true and each was
explained where it happened; the tree makes them structural.

No behaviour change, again the whole claim: 20 grouping-and-aggregate
gates and 363 unit tests, with the node's own unit test now folding
`Rows → Aggregate → Sort` over a fixture whose two keys have different
row counts.

## 2026-07-31 — R1: the row-source tree exists

The first increment of a PROGRAMME rather than a feature — see the new
[docs/roadmap.md](docs/roadmap.md), which says plainly where the project
stands: nine subsystems are converted, and **five of them
(`opt`, `cch`, `lck`, `evt`, `pio`) are not linked by the server at
all**. The optimizer picks access paths nothing executes; the lock
manager decodes a table it never enqueues into; every query is answered
by a full scan. Alongside that, the SQL layer answers views, CTEs and
constant subqueries by **rewriting SQL text**, where the engine builds a
tree of record sources.

### Converted
- **`RowSource`** — the engine's execution shape (`RecordSource`/rsb in
  `src/jrd/`) as a real tree: `TableScan`, `Filter`, `Sort`, and a
  materialised `Rows` leaf. The node set is deliberately the engine's,
  not a convenient one.
- The two places that hand-rolled scan-filter-sort — the ordinary fetch
  and `branch_rows` — now build a tree and pull it. **No behaviour
  change: that is the whole claim**, and 38 gates plus 363 unit tests are
  the proof.
- The sort stays INSIDE the tree, below the projection, because ORDER BY
  indexes the record's fields rather than the projection's. Both call
  sites had that right and each said so in its own words; now the tree
  says it once.

What is deliberately NOT here, named so the shape is not mistaken for
finished: `Aggregate`, `NestedLoopJoin`, `Union`, and an `IndexScan`
leaf — the last being what makes `fire-crab-opt`'s choices executable
instead of advisory.

The `Rows` leaf is not decoration: a derived table, a materialised CTE
and a recursive one all stand on it, and it is what lets the tree be
unit-tested without a database behind it — which is how the sort's
"orders by the key, not by the row order" check is written over a
fixture whose two fields disagree on every pair.

## 2026-07-31 — a `?` on the left of a comparison

### Converted
- **`WHERE ? < SALARY`.** A parameter bound on the LEFT of a comparison
  refused; only `SALARY > ?` worked. The engine describes the parameter
  from the OTHER side whichever way round it is written, so the leaf is
  now read from that side too: the sides SWAP and **the operator
  MIRRORS**.
- The mirroring is the whole point. Moving the operator instead of
  mirroring it — reading `? < S` as `S < ?` — answers a different set of
  rows and does it quietly, so the gate checks every ordering operator in
  both spellings, over a fixture where the two answers DIFFER.
- **A `?` is POSITIONAL**: its number is its place in the TEXT, not its
  place in the rewritten leaf. The slot is registered before the right
  side is parsed, so `WHERE ? < DP AND DP < ?` binds the client's two
  values in the order they were written.

`qa/serve-real-typedparams.sh` grows from 26 checks to 39, including a
left-side parameter beside a right-side one, two left-side ones, a text
column, and one in a DML WHERE with the table compared afterwards.

Probed and NOT converted, so it is not mistaken for covered: a `?` inside
an arithmetic operand (`WHERE SALARY > ? + 100`) and inside a CASE
condition still refuse — the expression parser has no parameter counter
to register a slot with, which is a different change from this one. A
lone `?` in a select list errors on BOTH servers, so that is agreement
rather than a gap.

## 2026-07-31 — one statement of "which side is which"

### Converted
- **A correlated `EXISTS` whose INNER table is aliased** — the refusal
  the previous increment named. `SELECT COUNT(*) FROM EMP E WHERE EXISTS
  (SELECT 1 FROM DEPT D WHERE D.ID = E.DEPT_ID)` is how the shape is
  normally written, and it refused while the SAME correlation worked
  through `IN`, through a scalar comparison and in the select list.

**The cause is worth more than the fix.** The EXISTS arm recovers the
outer column with a helper that carried its **own copy** of the
"which side of this equality is the inner one" rule — and that copy
compared a qualifier against the inner table's NAME only, never its
alias. The rule had been written three times: once in `eval_subquery`,
once in that helper, and once (extracted two increments ago) in
`split_correlation`. Two of the three learned about aliases; the third
did not, and it was the one that failed last.

The helper is now four lines that call `split_correlation`. A rule
stated twice is a rule that drifts; a rule stated three times drifts
twice, and the copies fail at different times, which is what makes the
symptom look like a different bug each time.

### Fixed
- `qa/gate-selfcheck.sh`'s squatter check conflated "the gate failed for
  the RIGHT reason" with "the gate failed" — a transient scratch-database
  failure inside the squatted gate read as the guard not firing. It now
  retries the setup once and reports the two cases differently.

`qa/serve-real-subqalias.sh` grows from 29 checks to 32; its two
refusals become comparisons, including the negated form and the shape
with an inner residual beside the correlation.

## 2026-07-31 — subqueries whose tables carry aliases

### Fixed
- **A rewrite reached into a nested query's SCOPE.** The pass that
  strips a table's qualifiers rewrote the WHOLE statement, including the
  text inside a subquery — and `(SELECT 1 FROM DEPT D WHERE D.ID =
  EMP.DEPT_ID)` names the OUTER table there on purpose. Stripping that
  qualifier left a bare `DEPT_ID`, which the inner table does not have
  (and in other shapes DOES have, meaning something else). A nested query
  is a different scope; the rewrite now copies such a span verbatim.
- **A subquery's own clauses may qualify by the INNER table's name or
  alias** (`SELECT D.ID FROM DEPT D WHERE D.ID > 1`) and its resolver
  looked those up unqualified. They come off AFTER the correlation split,
  which needs them to tell the two sides apart — an ordering the code now
  states, because reversing it silently changes which column the
  correlation names.
- Together these fix `IN`, `NOT IN`, a scalar subquery on the right of a
  comparison, and a subquery in the select list, in every combination of
  aliased and unaliased tables. That is how most people write them.

- **`NOT EXISTS` dropped the row whose key is NULL.** This one is a wrong
  answer, found by the new gate and PRE-EXISTING — unrelated to aliases,
  which is why both spellings failed. `NOT EXISTS` is a **two-valued**
  test on rows ("no inner row matches"), while the `NOT IN` it rewrites
  to is three-valued and answers UNKNOWN for a NULL left side. An outer
  key that is NULL matches nothing and therefore SATISFIES `NOT EXISTS`;
  fire-crab answered 0 where the engine answers 1. The rewrite now emits
  `(<key> IS NULL OR <key> NOT IN (...))`.
  - The code already handled the mirror case — inner NULLs are filtered
    out of the list — so half of the classic NOT IN / NOT EXISTS
    divergence was closed and the other half was not. A literal
    `NOT IN (SELECT ...)` still poisons on NULL, correctly, and the gate
    checks that too.

### Guarded
- A correlated `EXISTS` whose INNER table is aliased still refuses: the
  correlation split reads the alias, but something later in that one path
  resolves against the inner table's own name. It refuses rather than
  answering, the same correlation works through `IN`, through a scalar
  comparison and in the select list, and the gate names it as the next
  slice rather than leaving it to be rediscovered.

`qa/serve-real-subqalias.sh` is new, 29 checks, each shape run in its
unaliased spelling too — the aliases are the variable under test, so
everything else has to be identical.

## 2026-07-31 — the declared width of a numeric function

### Fixed
- **The engine announces a width PER FUNCTION, not BIGINT for every
  integer result.** fire-crab announced BIGINT throughout, so isql laid
  out a 20-wide column where the engine lays out 6. Probed with
  `SET SQLDA_DISPLAY ON`:
  - `SIGN` is **SHORT**, whatever its argument.
  - `CHAR_LENGTH`, `OCTET_LENGTH`, `POSITION` are **LONG**, always.
  - `MOD` keeps the **first operand's** own width.
  - `ABS` is **one step wider** than its source (SMALLINT→INTEGER,
    INTEGER→BIGINT).

### Corrected
- **The "standing deviation" the previous increment recorded was not
  one.** That gate softened a numeric check and blamed fire-crab's
  integer arithmetic for announcing BIGINT where the engine announces
  INTEGER. Probing it directly says otherwise: `ID + 1`, `S + S`,
  `ID * 2` and `ID + BG` all announce **INT64** on the engine too. The
  widening fire-crab does for arithmetic is exactly the engine's; the
  divergence was only ever in the FUNCTIONS. The softened check is
  restored in full.

`qa/serve-real-funcwidth.sh` grows from 32 checks to 48 and its fixture
gains SMALLINT and BIGINT columns, so a function's declared width can be
varied by its source.

**A note on how nearly this shipped unverified.** The new unit test did
not compile — `Wire` derived neither `Debug` nor `PartialEq`, which
`assert_eq!` needs — and `cargo build --release` still succeeded, because
the test module is `cfg(test)`. The greps that summarise "N tests passed"
matched nothing and printed an empty count, which reads like a pass at a
glance. This is the same silent-skip shape the playbook already records
for gates, in the unit-test path: a summary that can be EMPTY as well as
ZERO needs to distinguish the two.

## 2026-07-31 — the width of a text FUNCTION's result

### Fixed
- **A text function's result has a derived width, and fire-crab declared
  the catch-all 32765 for all of them.** The values agreed, so no driver
  twin could see it — but isql lays its columns out FROM THE DESCRIBE, so
  `SELECT UPPER(V) FROM T` printed a **32765-wide column** where the
  engine prints a 6-wide one, in the engine's own client.
- The rules, each probed with `SET SQLDA_DISPLAY ON`:
  - `UPPER`/`LOWER` keep the argument's FORM and width — so
    `UPPER(<CHAR(6)>)` is CHAR(6) and pads.
  - `TRIM` is VARYING at the argument's width.
  - `LEFT`/`RIGHT`/`REVERSE` take the **source's** width, not the count:
    `LEFT(V, 3)` over a VARCHAR(6) is VARYING(6).
  - `SUBSTRING` takes its literal FOR length, or the source's width when
    there is no FOR.
  - `LPAD`/`RPAD` take their pad length.
  - `a || b` is VARYING at the **sum** of the two widths.
- `REPLACE` is deliberately left unsized: its bound is some function of
  the search and replacement lengths, and one probe is not a law. It
  keeps the catch-all declaration and the gate says so.

`qa/serve-real-funcwidth.sh` is new, 32 checks, and it is the first gate
here to compare **isql's rendered output verbatim** — header and
separator included, because those lines ARE the width. A declared width
is not a value, so the usual driver twin cannot see it; the engine's own
tool can.

It also names a standing deviation rather than hiding it: fire-crab
computes integer arithmetic at full i64 and announces BIGINT where the
engine announces INTEGER, so an arithmetic column's isql layout differs
even though every value matches. That predates this increment, and the
gate's numeric check is a plain column with a comment explaining why.

## 2026-07-31 — the width and form of a text result

### Fixed
- **A conditional's text result is CHAR of its WIDEST branch, and is
  PADDED to it.** `CASE WHEN ... THEN 'other' ELSE 'isnull' END` answers
  `'other '`; fire-crab announced VARCHAR(32765) for every text
  expression and padded nothing, so it answered `'other'`. A wrong VALUE,
  not just a wrong describe. The previous increment found this and said
  so rather than encoding around it; this is the fix.
- The rules, probed with `SET SQLDA_DISPLAY ON`: a LITERAL is `CHAR(n)`;
  a conditional's WIDTH is the maximum over its branches; its FORM is
  VARYING if ANY branch is varying, else CHAR — and only a CHAR result
  pads. `COALESCE(NAME, 'zzzzzzzzzz')` is VARYING(10);
  `COALESCE('ab', 'cdef')` is CHAR(4).
- **The padding applies wherever the value is used, not only in a select
  list**: `CASE WHEN 1=1 THEN 'ab' ELSE 'abcdef' END || 'X'` answers
  `'ab    X'`. So it is applied where the node is RESOLVED, and the
  padded value then flows into concatenations, comparisons and sort keys
  by itself. The gate found that — the first attempt padded only the
  top-level projection.
- It is applied by wrapping in the CAST that already implements padding
  (`CAST(x AS CHAR(n))`), rather than by a second implementation of the
  same law.

**Three unit tests had encoded the old, unpadded values** —
`CASE ... 'pos'/'neg'/'zero'` asserting `"neg"`, `IIF(..., 'long',
'short')` asserting `"long"`. They were the bug, written down and
protected. Each is now the engine's own answer, with a note saying why.

`qa/serve-real-textwidth2.sh` is new, 30 checks, every one over branches
of DIFFERENT widths so the padding is visible in the string itself. The
shapes this driver cannot decode from the engine (a CHAR column, several
text columns in one row) are compared against isql instead.

## 2026-07-31 — DECODE, and EXISTS as a value

### Converted
- **`DECODE(<subject>, <search>, <result>, ..., [<default>])`** — it IS a
  simple CASE (the engine compiles it to the same node), so it desugars
  to the searched form the parser already builds, one `=` comparison per
  pair. An ODD number of arguments after the subject ends with a
  DEFAULT; an even number has none, and no match answers NULL.
- **`EXISTS(SELECT ...)` as a select-list value**, folded to TRUE or
  FALSE at prepare through the same subquery lifting the select list
  already uses — it asks only whether a row survives.

**The law worth probing**, because it is the one a converter inherits
wrongly: **Firebird's DECODE does not match a NULL subject to a NULL
search value.** Oracle's does. Here the comparison is `=` and `NULL =
NULL` is UNKNOWN, so a NULL subject matches nothing and takes the
default — which the simple-CASE desugar gives for free, and which a
desugar written to Oracle's semantics would have got wrong.

**The other law is about names, not values**: DECODE compiles to a CASE
and is still described as **DECODE**, while a simple CASE is described as
CASE. The gate puts both in one select list, which is the only place the
difference shows — and the naming applies only when the whole item is the
call, since `DECODE(...) + 1` is an ADD like any other expression.

### Found, not fixed
- **A conditional's TEXT result takes the width of its WIDEST branch and
  is padded to it.** `CASE WHEN ... THEN 'other' ELSE 'isnull' END`
  describes as `CHAR(6)` (sqltype 452, len 6 — confirmed with
  `SET SQLDA_DISPLAY`) and answers `'other '`; fire-crab announces a
  VARCHAR and does not pad. This is **pre-existing** and belongs to plain
  CASE as much as to DECODE — both differ identically — so the new gate
  uses branches of EQUAL width and says why, rather than quietly encoding
  a known-wrong expectation. It is the next slice.

### Guarded
- DECODE inside a WHERE refuses: the predicate tokenizer spans a CASE by
  its balancing END and has no rule for a DECODE call, so the desugar the
  select list gets never reaches it. Named rather than left unexplained.

`qa/serve-real-decode.sh` is new, 29 checks.

## 2026-07-31 — WITH: a view that lives in the statement

### Converted
- **Common table expressions** — `WITH C AS (SELECT ...) SELECT ... FROM
  C`. A CTE is a VIEW that lives in the STATEMENT rather than the
  catalog: the same source text, the same column names, the same
  substitution into the FROM. So it is not a new mechanism — it is the
  view expansion with a different place to look the name up, and
  everything that expansion learned over several increments arrives with
  it at once: an alias on the FROM item, RENAMED columns, the CTE's own
  WHERE ANDed into the outer one, and a CTE as a side of a JOIN.
- Two things are specific to CTEs and are parsed here: the **column
  list** (`WITH C (A, B) AS ...`) renames positionally, which is what a
  view does through `RDB$RELATION_FIELDS` but written very differently;
  and a CTE **shadows** a table of the same name for its statement.
- `FIRST`, `SKIP` and `DISTINCT` sit BETWEEN `SELECT` and the select
  list, so the expansion cannot read the projection past them. They come
  off before the rewrite and go back on after, in the engine's own order.

### Guarded
- **A CTE name left in the FROM refuses.** If a CTE's body is one the
  view expansion cannot rewrite (a GROUP BY inside, a `SELECT *`, a join),
  its name stays in the FROM — where it names no relation at all, so
  falling through would reach the fixed-answer fallback and reply 4242 to
  a query over real tables. `WITH RECURSIVE` refuses too: it is a
  fixpoint, not a substitution.

`qa/serve-real-cte.sh` is new, 29 checks. Each has a view-shaped twin
that already passed — which is the point of the framing, and the reason
this cost one function rather than a subsystem.

## 2026-07-31 — a correlated subquery in the select list

### Converted
- **`SELECT D.ID, (SELECT COUNT(*) FROM EMP E WHERE E.DEPT_ID = D.ID)
  FROM DEPT D`** — the refusal the previous increment recorded. A
  correlated subquery has no single value to fold into the text: it has
  one per outer row. So it is not folded, it is **precomputed as a
  LOOKUP TABLE** — the inner table is scanned once at prepare, its rows
  bucketed by the correlation column, each bucket folded into the one
  value that key answers, and each outer row then looks its own key up.
  A correlated aggregate IS a group keyed by the correlation column, so
  the fold is the same `compute_group` a GROUP BY runs.
- Covered: COUNT/MIN/MAX/SUM/AVG and a bare column; the inner table by
  name or alias; the equality either way round; a residual inner filter
  beside the correlation; several correlated items in one select list;
  an outer WHERE, an alias, and ORDER BY over the looked-up column.

**The law this turns on**: a key with NO matching inner rows is **not
always NULL**. `COUNT` answers 0 there and every other function answers
NULL — and both appear in the SAME ROW of one query, which is how the
fixture pins it: department 9 has no employees and answers `0` and
`<null>` side by side. A lookup defaulting to NULL is right for three of
the four functions and wrong for the one people use most.

### Fixed
- **The inner table's ALIAS is its qualifier.** `FROM EMP E ... WHERE
  E.DEPT_ID = D.ID` correlates through `E`, and the correlation split
  compared only the table NAME — so it found no correlation at all and
  every aliased correlated subquery refused, which is nearly all of them
  as people write them. This also widens the correlated EXISTS/IN path,
  which shares the split.
- **`SUM(E.SALARY)` parses as an EXPRESSION target**, not a column one —
  the dot stops it looking like an identifier — so the qualified
  spelling took a different path from `SUM(SALARY)` and refused while the
  bare one worked.

### Guarded
- A **non-equality** correlation (`WHERE E.SALARY > D.BUDGET`) refuses: a
  keyed table cannot express it, and the engine answers it by re-running
  the subquery per row. So does a GROUP BY inside the subquery.

`qa/serve-real-corrsubq.sh` is new, 27 checks. The two correlated
refusals `qa/serve-real-selectsubq.sh` recorded one increment ago are
promoted there from refusals to comparisons.

## 2026-07-31 — a subquery in the select list

### Converted
- **`SELECT ID, (SELECT COUNT(*) FROM D) FROM T`.** The WHERE clause has
  taken subqueries for many increments — lifted out of the text,
  evaluated, folded back in as ordinary tokens. The select list could not
  hold one at all. The conversion reuses that lifting: a subquery naming
  no outer column is a CONSTANT for the whole statement, so it is
  evaluated once and folded back into the query TEXT as the literal it
  computed, and the statement re-planned. Every select-list shape then
  works over it for free — an alias, arithmetic around it, a CASE, a
  CAST, COALESCE, a grouped query, ORDER BY, FIRST.
- Three laws, probed first: **no rows answers NULL**; **more than one row
  raises** "multiple rows in singleton select" (SQLSTATE 21000, the
  engine's own message, byte for byte); and the output column is named by
  the **subquery's own select item** — `(SELECT COUNT(*) ...)` describes
  as COUNT, `(SELECT ID ...)` as ID — not by the literal it folded to.

### Fixed
- **`SELECT 3 FROM T` refused.** An unquoted SQL identifier cannot start
  with a digit, but `ident_ok` accepted `"3"`, so a numeric literal in
  the select list was read as a COLUMN NAMED 3 and never found. `SELECT
  NULL` and `SELECT 'x'` worked, which is exactly what kept it hidden for
  so long — and a folded subquery lands precisely there, so the fold
  could not work until this did.
- **`SELECT -3` described as blank**; the engine names a negated LITERAL
  `CONSTANT` and only a negated column blank (probed). 

### Guarded
- A **correlated** subquery in the select list refuses. Its value differs
  per outer row, so folding it once for the statement would put one row's
  answer in every row — a wrong answer where a refusal is honest.

`qa/serve-real-selectsubq.sh` is new, 34 checks, comparing whole JSON
objects because half this increment is a naming law. The text-column case
is compared against isql rather than the twin: node-firebird cannot
decode the ENGINE's own answer for it.

## 2026-07-31 — an aggregate inside an expression

### Converted
- **`SUM(A) + 1`, `MAX(A) - MIN(A)`, `COUNT(*) * 2`, `CAST(SUM(A) AS
  VARCHAR(10))`, `CASE WHEN COUNT(*) > 2 THEN ...`.** The select list
  could hold an aggregate or an expression but never one INSIDE the
  other: an aggregate was a select-list ITEM while an expression is a
  TREE, and the tree had no leaf for a fold. Every such shape refused.
- The conversion is one idea: **an aggregate is a leaf with no value for
  a ROW, only for a GROUP.** Each one becomes a SLOT of the group row,
  and the surrounding expression is then an ordinary expression over that
  row — the same trick the join uses to run the ordinary expression
  resolver over a combined row. With no GROUP BY the query is the single
  global group, which is what makes `SELECT SUM(A) + 1 FROM T` one row.
- Two aggregates in one expression need two slots, and the second is a
  HIDDEN one appended past the output columns, so the group row is wider
  than the select list. A grouped KEY inside the expression
  (`DEPT_ID + SUM(SALARY)`) gets a slot too, though no output column
  selects it.

### Fixed
- **`ORDER BY` a COMPUTED output column** — by alias or by ordinal — used
  to refuse. A computed column has no field of its own to sort by, so its
  `field_id` is a placeholder and sorting by it would be wrong; the
  refusal was right *while nothing evaluated expression sort keys*, and
  wrong the moment the previous increment made `sort_rows` live. The key
  is now the column's OWN expression, on all three paths.
- A grouped `ORDER BY` reached its keys by pairing output columns with
  group-row slots, which cannot see a slot past the last output column —
  exactly the hidden slots this increment introduces. It indexes the
  group row directly now.

### Guarded
- `COUNT(DISTINCT c)` and an EXPRESSION argument (`SUM(A + 1)`) inside a
  folded aggregate refuse: their result type is not derived here, and a
  guessed type decodes as the wrong number rather than failing.

`qa/serve-real-aggexpr2.sh` is new, 45 checks. Its department 2 has one
employee, so `MAX - MIN` over it is 0 — the value a fold reading the
wrong slot is least likely to produce by accident — and its salaries do
not divide evenly by the row count, so `SUM/COUNT` shows the dialect-3
truncation (650/4 is 162, not 163).

**The bug worth naming**: a synthetic descriptor built for an aggregate's
slot defaulted its `offset` to 0, and `is_computed_fid` reads
`offset == 0 && length != 0` as "this is a COMPUTED column" — so every
expression naming that slot refused. It was invisible for MIN and MAX,
which clone the SOURCE column's descriptor and inherit its real offset,
and failed for SUM, AVG and COUNT, which build a fresh one. A field whose
zero value means something else is a field you cannot default.

## 2026-07-31 — the rest of the SELECT, over a join

### Converted
- **EXPRESSIONS in a join's select list.** The join had projections, a
  WHERE, ON predicates, chains, GROUP BY and aggregates — and a select
  list that took BARE COLUMNS AND NOTHING ELSE. `SELECT E.SALARY + 1
  FROM ... JOIN ...` refused, and so did every CASE, CAST, function,
  COALESCE, IIF and condition-as-value. The combined view (a join's rows
  seen as one synthetic relation) already existed for the ON resolver, so
  the ordinary `build_expr_col` runs over it unchanged.
- **`DISTINCT`, `FIRST`, `SKIP` and `ROWS` over a join**, including over
  a grouped join and a join through a view. `branch_rows` is what
  materialises rows for those wrappers and it knew Project, Union and
  ProcRows; teaching it Join and JoinGroup gave `INSERT ... SELECT` and
  `FOR SELECT` the same sources at the same time.
- **`ORDER BY <expression>` over a join** — arithmetic, a CASE, a
  function, an expression spanning both sides, alone or beside a column
  key, and composing with FIRST and DISTINCT.

### Fixed
- **An expression sort key was accepted and then IGNORED.** `sort_rows`
  — the sort that EVALUATES a key's expression — existed in this file
  with NO CALLERS. `Plan::Join`, `Plan::JoinGroup` and `Plan::Group` all
  sorted with `order_cmp`, which reads a key's FIELD and ignores its
  expression, so the moment the join accepted `ORDER BY E.SALARY + 0` it
  sorted by field 0 instead. Wiring the ORDER BY parser up without this
  would have turned a refusal into a wrong answer, which is the worse of
  the two.

None of these are join FEATURES: each is a capability the single-relation
path has had for increments and the join path never learned. That is the
failure shape this project keeps meeting, and it is why
`qa/serve-real-joinexpr.sh` (new, 46 checks) is organised by CAPABILITY
rather than by join shape — every check has a single-table twin, and
those twins are re-run in the same file so a fix on one path cannot
quietly break the other.

The fixture's lowest salary belongs to its highest id, so every
expression sort puts that row where the natural row order never would —
a sort that ignored the expression answers the id order, visibly.

## 2026-07-31 — a view's columns keep the view's names

### Fixed
- **A view with RENAMED columns answered under the BASE table's names.**
  `SELECT EID FROM VREN` returned the right value in a column called ID.
  Every value was right and every NAME was wrong — and a driver builds
  its row objects from those names, so `row.EID` was undefined. The
  sharpest case is a view that SWAPS two names (`SELECT NAME AS ID, ID AS
  NAME`): the values then land on each other's names, so `row.ID` is a
  number on one server and a string on the other. Rewriting a view's
  column to its base's is only half the job; the select list has to alias
  the view's name back on, because that name is the whole contract.
- **`SELECT E.ID FROM EMP E` refused.** The join resolver has always
  understood qualified names — it must, since that is the only way to say
  which side you mean — but the single-relation path never did. So
  qualifying a column in a one-table query, which is ordinary SQL and
  also what the view rewrite produces, was an error: in the select list,
  the WHERE, GROUP BY, HAVING and ORDER BY alike. A qualifier naming
  THIS relation is now stripped and the statement re-planned; one naming
  anything else is left alone, since a correlated subquery names its
  outer table that way.
- **An ALIAS on a joined column was dropped**, and that was not only a
  wrong name: `SELECT E.ID AS EMPID, D.ID AS DEPTID` produced two output
  columns both called ID, and a driver keying its rows by name kept one
  of them. Two columns asked for, one column delivered.
- **A grouped key now answers to BOTH names.** `SELECT DEPT_ID AS D2 ...
  GROUP BY DEPT_ID ORDER BY DEPT_ID` sorts by the key, which the engine
  allows. It looks exotic written by hand and is exactly what a renamed
  view produces once expanded.

### Converted
- **A view with renamed columns may now be a SIDE OF A JOIN** — the
  refusal `qa/serve-real-viewjoin.sh` recorded one increment ago. The
  reference is rewritten under its QUALIFIER (`V.DID` → `V.DEPT_ID`),
  which is what keeps two sides apart, and the select list aliases the
  view's name back on.

### Guarded
- **A BARE reference to a renamed view column inside a join refuses.**
  With more than one side in scope the same word can be this view's
  renamed column and another table's real one, and only the qualifier
  says which. The engine resolves it; guessing a side would be a wrong
  answer, so this is a refusal with a reason rather than a gap.

`qa/serve-real-viewrename.sh` is new, 46 checks. It compares the whole
JSON — KEYS included — because every bug in this increment was visible
only in the keys: the values were right throughout.

## 2026-07-31 — the gates that measured nothing

### Fixed
- **Eleven gates defaulted to port 3050 — the real engine's own.** Every
  differential here starts `fcwire` on a port, waits for the port to
  answer with `nc -z`, then runs its checks. But `nc` answers "SOMETHING
  is listening", which is not the question: when the port was already
  taken, fcwire exited at bind with `Address already in use` and `nc`
  succeeded anyway — against the OTHER server. Since the other server on
  a machine running these gates is the engine, a twin gate then compared
  **the engine with itself** and passed. Perfectly, every time.
- That is the worst failure a differential has — not a wrong answer but a
  green run that measured nothing — and it had already produced a wrong
  conclusion: yesterday's slice reported a "pre-existing VARCHAR
  length-metadata bug" in `qa/serve-real-{project,join}.sh`. There is no
  such bug. Both gates were talking to the engine, and the truncation was
  node-firebird mis-decoding the ENGINE's own answer, a limit this
  project had already documented. Run on their own ports, both are green.
- Each of the eleven now has its own default port, and **every one of the
  149 gates that starts a server now asserts the server is running**
  (`kill -0 $srv`) after the readiness probe, so a failed bind is fatal
  instead of invisible.
- **Five gates carried a `#!/bin/sh` shebang while using bash-only
  syntax**, so running them the way their own headers say failed at
  parse. Same lost coverage by another route.

### Converted
- **`qa/mktypesdb.sh`** builds the wiretypes scratch database, and
  `qa/serve-real-types.sh` runs for the first time — 10 checks green. It
  is the gate for the one thing only a typed client can see: that
  fire-crab describes and encodes each type in the engine's own wire form
  (SMALLINT natively rather than widened, scaled numerics as raw integers
  with the scale in the DESCRIBE, IEEE floats, raw temporal units,
  BOOLEAN as an XDR int slot). Like the join gates before `qa/mkjoindb.sh`,
  it had been unrunnable for want of a database that lived nowhere. Its
  values are picked against the canonicalisation rules the two sides
  force: SMALLINT at both extremes (a widened type still round-trips, so
  only the extremes prove the describe), BIGINT inside 2^53 (or the gate
  measures the driver), no scaled value ending in a zero decimal digit,
  floats exactly representable in binary, DATE including **1858-11-17**
  (the MJD epoch — the value an off-by-one in the day conversion cannot
  hide in), and no midnight time or 1970-01-01 timestamp, both of which
  the gate's formatter reads as type sentinels.

### Guarded
- **`qa/gate-selfcheck.sh`** is new: the gate that checks the gates. Five
  properties — no gate's own server defaults to the engine's port, every
  server start is guarded, default ports are distinct, every gate parses
  under its own shebang, and the one with teeth: it starts a squatter on
  a gate's port, runs that gate for real, and requires a non-zero exit
  with a spoken reason. A guard that is present and does not work looks
  exactly like a guard that works, until the day it matters.

## 2026-07-30 — a view as a side of a join

### Converted
- **A VIEW may now stand on either side of a JOIN** — the last gap in
  the FROM clause. A view standing alone was already expanded (its name
  swapped for its base table, its own WHERE ANDed into the outer one);
  with a second table present that rewrite is wrong twice over, and both
  corrections are the increment:
  - **Where the view's predicate goes depends on whether that side can be
    NULL-PADDED.** `DEPT D LEFT JOIN VEMP V ON V.DEPT_ID = D.ID` must keep
    every department. Push the view's `SALARY > 150` into the outer WHERE
    and the padded row — whose SALARY is NULL — is thrown away, and the
    LEFT join has quietly become an inner one. The predicate belongs in
    that step's ON, which filters the view's rows BEFORE the padding.
  - **An unaliased view still owns its name as a qualifier**: in
    `FROM VEMP JOIN DEPT ON VEMP.DEPT_ID = DEPT.ID` the ON says VEMP, so
    the base table takes the VIEW's name as its alias and the
    substitution happens in TABLE POSITION ONLY (`replace_table_ref`). A
    rewrite that also renamed the qualifier produced `EMP VEMP.DEPT_ID`.
- Both sides may be views, a view may appear in a three-table chain, in
  a CROSS join and in a comma list, and the rewritten query flows on into
  WHERE, GROUP BY, HAVING, ORDER BY and the aggregates unchanged.

### Guarded
- **A view the server cannot expand answered ZERO ROWS instead of
  refusing** whenever it was not the FIRST table of the FROM. A view is a
  relation with a relation id and no records of its own, so an
  unexpanded one scans its empty storage: `DEPT D RIGHT JOIN VEMP V`
  answered `COUNT = 0` where the engine answers 3, and a FULL join
  answered 4. The refusal guard checked only the base table; it now
  checks every side. This is the failure shape the project keeps
  meeting — the wrong answer that looks like a legitimate empty result.
- Three shapes refuse for stated reasons rather than by omission: a view
  with RENAMED columns (every reference would need rewriting, not the
  table name), a view over a JOIN (no single base table to become), and
  a RIGHT or FULL join with any view (it makes an EARLIER side nullable,
  so which side a predicate belongs to stops being a local question).

`qa/serve-real-viewjoin.sh` is new, 32 checks. Its fixture is built so
that department 3's only employee is BELOW the view's threshold — that
row is what tells the two predicate placements apart, and a fixture
where every department either qualifies or is empty would have passed
either way.

## 2026-07-30 — the values an UPDATE could compute but not store

### Fixed
- **`UPDATE T SET FLAG = (A > 5)` answered "expression type cannot be
  stored".** The SET path evaluates its expression per row and then maps
  the result to a wire value — and that mapping was a list of value
  shapes written before the expression surface learned booleans, the
  temporal types and INT128. Everything computed correctly and then had
  nowhere to go.
- A condition IS a value in Firebird, so filling a boolean column from
  one is the ordinary way to write it: `SET FLAG = (A > 5)`,
  `SET FLAG = NOT FLAG`, `SET FLAG = (A IS NULL)`, `SET FLAG = (S LIKE
  'a%')`. Dates and timestamps store from arithmetic and from a CAST the
  same way.

`qa/serve-real-setexpr.sh` grew from 26 checks to 35, and its fixture
gained a BOOLEAN and a DATE column — the two families it could not
exercise before. It compares the TABLE after every statement, read back
by the engine, which is what makes a wrongly encoded value visible at
all.

## 2026-07-30 — NATURAL JOIN: a condition made of names

### Converted
- **`NATURAL [LEFT|RIGHT|FULL [OUTER]] JOIN`** — the last shape the FROM
  clause refused. It has no ON: the condition is DERIVED from the column
  names the two sides share, one equality per shared name. Sharing
  nothing makes it a cross join (probed).
- **The shared columns become ONE column.** A bare `K` after a natural
  join is not ambiguous — it means the merged column — while `NR.K`
  still reaches the other side's copy, which is what the engine allows.
  `SELECT *` emits the pair once.
- **In an OUTER natural join the merged column shows whichever side has
  a value.** `NATURAL RIGHT JOIN` preserves the right, so a padded left
  would show NULL for a column the right has a value for; the engine
  shows the value, so the star projection builds those columns as a
  COALESCE of the two sources.

The FROM clause now answers every join shape the engine has except a
join over a VIEW: inner and the three outer kinds, chains of any length,
CROSS, comma lists, and NATURAL — with the ON generalised to a predicate
two increments ago.

`qa/serve-real-joinchain.sh` grew from 24 checks to 33, and
`qa/mkjoindb.sh` gained two tables built for this: they share K and G by
name, only one pair agrees on both, and a row whose shared columns are
NULL never joins — because NULL = NULL is UNKNOWN, which is the rule a
derived condition inherits rather than restates.

## 2026-07-30 — CROSS JOIN, comma lists, and where an item's ON can look

### Converted
- **`CROSS JOIN`** and **`FROM a, b, c`** — the two spellings of the same
  thing, and with the chain in place both are just a step whose ON keeps
  every pair. `FROM a, b WHERE a.k = b.k` is then the old-style join it
  has always been, computed the same way as the ON form.
- Either spelling composes with the rest of a chain: a CROSS before an
  ON-join, after one, and a comma item that is itself a join.

### Guarded
- **An item's ON may only name tables within that item.** `FROM A, B
  JOIN C ON C.x = A.x` is an error on the engine — the join binds
  tighter than the comma, so A is not in scope — and fire-crab answered
  it, having flattened the list into one chain where every later ON saw
  everything. Each step now carries the index of the first side visible
  to it, and a comma item's steps start at that item's own base.
- **`NATURAL JOIN` refuses.** It joins on every SHARED COLUMN NAME and
  then collapses those columns into one — a rule about names rather than
  a condition, and not one this server answers.

`qa/serve-real-joinchain.sh` grew from 15 checks to 24. One more of
`qa/serve-real-outerjoin.sh`'s checks changed verdict: its CROSS JOIN
case has now been a fixed scalar, then a refusal, and now a comparison —
the property it defends (never wrong rows) has not moved once.

## 2026-07-30 — a CHAIN of joins: three tables and more

### Converted
- **`FROM a JOIN b ON ... JOIN c ON ...`** — the FROM clause refused a
  second JOIN outright. It parses into one step per join now, and the
  rows are FOLDED: each step joins everything accumulated so far with
  the next table.
- **A step's ON may name any earlier table.** `A JOIN B ON ... JOIN C ON
  B.Y = C.Y` resolves the second condition against A, B and C together,
  which is what makes a chain different from two independent joins.
- **Each step's KIND applies to the accumulation**, so `LEFT JOIN` in
  the middle of a chain pads what came before it — and the padded rows'
  columns are NULL, so an INNER step after a LEFT one drops them again.
  Every kind combination has a different row count and the gate compares
  all of them.
- Projections, WHERE, GROUP BY/HAVING, ORDER BY and the aggregates all
  work over a chain, because they were already written against the
  combined row.

### Fixed
- **A side's offset in the combined row was the FIRST side's width**,
  not the sum of every previous one. Right for two tables and silently
  wrong for three: the third table's columns landed on top of the
  second's, so every three-table inner join returned no rows while the
  outer variants quietly padded.

`qa/serve-real-joinchain.sh` (15 checks) and `qa/mkjoindb.sh` gained a
REGION table whose row 50 no department references, so the chain's
second step has something of its own to drop. The gate's centre is a
table of row COUNTS: INNER/INNER, INNER/LEFT, LEFT/INNER, LEFT/LEFT and
a RIGHT second step all differ, and a mis-folded chain lands on the
wrong one.

## 2026-07-30 — the ON clause is a predicate, not a list of pairs

### Converted
- **`ON` beyond equality**: `ON A.K > C.K` (a theta join), `<>`, `>=`,
  an `AND` mixing operators, and an `OR` in the ON. All refused before.
- **`ON` over any column family** — NUMERIC, DATE, DOUBLE, BOOLEAN —
  where it accepted only INTEGER and TEXT keys.
- The ON is now resolved by the SAME code the WHERE clause uses and
  evaluated over the concatenated row, instead of being a list of
  `(left index, right index)` equality pairs. NULL semantics come out
  unchanged for free: a comparison with NULL is UNKNOWN, `matches`
  answers false, and an unmatched row is padded by an outer join exactly
  as before.

### Fixed
- **A join's evaluation errors were collected and dropped.** `join_rows`
  accumulated an error from the WHERE into a local and returned the rows
  it had computed anyway — a wrong answer with no error attached. It
  returns a `Result` now, and the ON's errors travel the same way.

### Guarded
- A `?` in an ON refuses: the parameter would have to bind before the
  join runs, and this server has no path for that.

`qa/serve-real-jointypes.sh` grew from 20 checks to 28, with the new
operators alongside the equi-join they generalise, and both halves of
the NULL-key rule — an inner join drops the row, an outer join pads it.

## 2026-07-30 — the other half of the condition/value duality

### Converted
- **`LIKE` as a VALUE** — `SELECT NAME LIKE 'a%'`, `NOT LIKE`, with
  `ESCAPE`, inside a `CASE` condition and under `AND`/`NOT`. It was the
  one predicate form the condition-as-a-value slice left out, because
  `RawCond`/`Cond2` had no LIKE leaf to put it in.
- **A CONDITION as a comparison SIDE** — `WHERE (ID > 2) = TRUE`,
  `(B = TRUE) = TRUE`, `(NAME LIKE 'a%') = TRUE`. If a predicate is a
  value, a comparison between two of them is just a comparison. The
  predicate tokenizer now looks past a parenthesised group: followed by
  a comparison operator it is an OPERAND and lexes as one expression;
  followed by anything else it stays the sub-predicate it always was.

### Fixed
- **`SELECT CASE ... ELSE LOWER(S) END` refused.** The bare trailing
  alias added two increments ago split it at the last space and read
  `END` as the alias, leaving a CASE with no END. The rule guarded
  keywords at the end of the HEAD (`NOT B`, `B AND C`) but not the TAIL,
  which is where this one is. Caught by an existing gate.

### Guarded
- `qa/serve-real-boolvalue.sh` now COUNTS the checks it ran and fails if
  fewer than expected. Adding this slice's checks with a mistyped helper
  name made eight of them vanish — a shell "command not found" does not
  touch the failure flag, so the gate reported success while doing less
  work than it claimed. A gate that can silently skip is a gate that can
  silently pass.

`qa/serve-real-boolvalue.sh` grew from 33 checks to 51.

## 2026-07-30 — aggregates and GROUP BY over a JOIN

### Converted
- **`SELECT SUM(E.SALARY) FROM EMP E JOIN DEPT D ON ...`** and the
  grouped form — `GROUP BY`, `HAVING`, `ORDER BY` over the groups, on an
  INNER or an OUTER join. Only a lone `COUNT(*)` worked before; every
  other aggregate shape refused.
- The fold is the SAME machinery a single relation's grouping uses.
  `group_output` split into a scan and a `group_rows` fold, and the
  select-list item rules (a bare column must be a group key, an
  expression item must BE one of the expression keys, an aggregate's
  output type follows its function and source) came out as
  `build_group_items`. Only the INPUT differs: `join_rows` produces what
  the scan produced there.
- **The combined view now carries QUALIFIED names too.** That is what
  lets a grouped join name `D.ID` when BOTH sides have an ID — the bare
  name is ambiguous and dropped, so only the qualified spelling can mean
  one of them. A qualified key describes by its column name with the
  qualifier dropped, as the engine does.
- Along the way: `GROUP BY D.ID` (a qualified key, which the group
  parser read as an expression), and `SUM(E.SALARY)` (a qualified
  aggregate argument, which the item parser read as an expression
  argument because a dotted name is not an identifier).

`qa/serve-real-joingroup.sh` (18 checks) runs against the same scratch
database, where the three employees with no department and the
department with no employees are what tell an inner fold from an outer
one: `GROUP BY D.ID` over a LEFT join has a NULL group of exactly those
three, and `COUNT(D.ID)` over it counts 97 where `COUNT(*)` counts 100.

Five of the gate's own first-draft checks were wrong rather than the
server: two selected two columns both titled COUNT (this driver keys a
row by name, so one clobbered the other), one grouped by a name that is
a column of BOTH tables, and two ordered the reference query by
something other than the key the data was grouped on. Worth recording
because each looked exactly like a server bug until read closely.

## 2026-07-30 — the join gates, restored and what they found

### Fixed
- **Five gates had no database to run against.** `qa/serve-real-{join,
  outerjoin,project,insert,syscat}.sh` were written against a "join
  scratch db" that existed in one workspace and nowhere else, so they had
  been failing for want of it. `qa/mkjoindb.sh` builds it from a script -
  DEPT with a department no employee references, EMP with NULL and
  DANGLING department keys, and CHAR/VARCHAR key tables with duplicates
  and NULLs - and gbak-restores the clean copy the gates want. A gate
  nobody can run is a gate that stops telling the truth.

### Converted
Everything below was found by those gates within minutes of their
running again.

- **`FROM EMP AS E`** — the keyword form of a table alias, which the FROM
  parser accepted only as `FROM EMP E`.
- **`ORDER BY E.ID`** — a QUALIFIED name as a sort key. The parser
  classified anything containing a dot as an expression, and a join's
  expression resolver is `|_| None`, so every aliased join with an
  ordered result refused.
- **A join whose WHERE names a NUMERIC, DATE, DOUBLE or BOOLEAN column.**
  The single-table resolver learned those families over several
  increments; the join resolver still classified its columns through
  `col_kind`, which answers Int or Text and nothing else. So a join was
  not "broken for NUMERIC columns" but broken for any QUERY whose WHERE
  mentioned one — and a NUMERIC salary in the new fixture hid a
  perfectly working join until the column was made an INTEGER to match
  what the gates expected.
- The same for a QUALIFIED such column (`WHERE A.D > DATE'2020-01-01'`),
  whose literal makes the term an expression comparison and so takes a
  different branch — one that resolves against a combined view holding
  only BARE names.

### Guarded
- `qa/serve-real-outerjoin.sh` asserted that a CROSS JOIN answers the
  fixed scalar 4242. A later increment made unplannable queries RAISE
  instead, on the grounds that a made-up row is worse than an error, so
  the check now asserts the refusal. Same property, different expression.

`qa/serve-real-jointypes.sh` (20 checks, twin servers) covers the typed
columns directly, deliberately dully: each check is a join that works
with a WHERE naming one column of one family, bare and qualified, so
what it measures is the ROUTING and not the comparison rules, which have
their own gates.

## 2026-07-30 — column aliases in the select list

### Converted
- **`SELECT NAME AS X`** and the bare form **`SELECT NAME X`**, on a
  plain column, an expression, an aggregate and a grouped column. A
  quoted alias keeps its case; an unquoted one folds up, the way every
  unquoted identifier does.
- **`ORDER BY <alias>`** and **`GROUP BY <alias>`** — the engine
  resolves an alias in both, and a real column of that name wins over
  one, which is what makes a shadowing alias harmless.
- Two items over the SAME column with different aliases are TWO output
  columns.

### Fixed
- **The alias was dropped for the item type where it is most often
  written.** A plain column described as its own name — the parser even
  said so in a comment — `SELECT NAME X` refused outright, and
  `SELECT COUNT(*) AS N` refused because the alias was split off AFTER
  the aggregate parser had already failed on the whole text. Expressions
  honoured their aliases, which is what made the gap easy to miss: the
  shape people reach for first was the shape that worked.

`qa/serve-real-colalias.sh` (30 checks, twin servers). Nothing in it
compares values — every check compares the KEYS of the returned objects,
which is what a driver builds from the describe.

Two traps, both caught by existing gates rather than the new one. A bare
trailing alias must not swallow an OPERAND: `NOT B` is one item whose
last token only looks like a name, and so is `B AND C`; the rule now
refuses to split when the head ends in an operator keyword. And
`TRUE`/`FALSE`/`UNKNOWN`/`NULL` look like identifiers but are LITERALS,
so they must not take the column path — aliased or not.

## 2026-07-30 — a CONDITION used as a VALUE

### Converted
- **`SELECT B AND C`, `SELECT ID > 2`** — in Firebird every predicate is
  also an expression of type BOOLEAN, so the two grammars this server
  keeps apart (the WHERE parser and the select-list expression parser)
  meet in the select list. Comparisons, `AND`/`OR`/`NOT`, `IS [NOT]
  NULL`, `BETWEEN`, `IN`, parenthesised and nested — as select-list
  items, as `ORDER BY` and `GROUP BY` keys, and anywhere else an
  expression goes.
- **The fold is Kleene's, and only a VALUE can show it.** `FALSE AND
  UNKNOWN` is FALSE and `TRUE OR UNKNOWN` is TRUE — a decided dominant
  value wins over the unknown one. A WHERE clause collapses false and
  unknown into "row excluded", so none of that is visible until the
  condition is a value; every check in the new gate reads the value.
- **`BETWEEN` and `IN` in the condition grammar**, desugared into
  comparisons the way the predicate grammar already does — so `CASE WHEN
  ID BETWEEN 2 AND 3` and `IIF(ID IN (1, 4), ...)` work now too.
- **A bare boolean column is a condition** there as well: `CASE WHEN B
  THEN ...`, `IIF(B, ...)`.
- Every boolean-valued expression describes as **BOOL** — `B AND C`,
  `ID > 2`, `NOT B`, `B IS NULL`, `ID BETWEEN 1 AND 2`, `ID IN (1, 2)`
  (probed). A bare column keeps its own name, which it does by never
  becoming a condition in the select list.

### Fixed
- **`CASE WHEN NAME THEN ...` answered 0 for every row.** The condition
  resolver built the comparison without the side typing the predicate
  resolver applies, so a Text-against-Bool comparison fell to
  `value_cmp`'s rendered-text last resort and quietly compared `"aa"`
  with `"true"`. The engine raises `Invalid usage of boolean
  expression`; both resolvers now run the same `cmp_sides` check, which
  also gives `CASE`/`IIF` conditions the temporal and approximate typing
  rules the WHERE clause already had.

`qa/serve-real-boolvalue.sh` (33 checks, twin servers). Its fixture has
one `(NULL, FALSE)` row and one `(TRUE, NULL)` row, one for each half of
the Kleene rule: an implementation that answered NULL whenever an operand
was NULL fails the first, and one that answered FALSE fails the second.

## 2026-07-30 — BOOLEAN, the type that is also a predicate

### Converted
- **Boolean literals as VALUES**: `INSERT ... VALUES (TRUE)`, `UPDATE
  SET B = FALSE`, `SELECT TRUE`. This was the gap keeping
  `qa/serve-real-params.sh` red for dozens of increments — the LITERAL,
  not the parameter.
- **Boolean columns as PREDICATES.** `WHERE B` is a complete WHERE
  clause; so are `WHERE B AND C`, `WHERE NOT B` and `WHERE (B OR C) AND
  ID > 1`. A bare column means `B = TRUE`, which is why the NULL rows
  drop — and drop under `NOT` as well.
- **`IS [NOT] TRUE|FALSE|UNKNOWN`.** `IS TRUE` and `IS FALSE` are
  TWO-valued (a NULL is simply not true), so they desugar to `=`. Their
  negations are NOT the negated comparison: `B IS NOT TRUE` RETURNS the
  NULL rows where `B <> TRUE` and `NOT (B = TRUE)` both drop them, so it
  desugars to the explicit `IS NULL OR <>`, exactly as `IS DISTINCT
  FROM` does. `IS UNKNOWN` is `IS NULL` by another name.
- Comparison against another boolean column, `IN`, a boolean answer from
  a subquery, `ORDER BY`, `GROUP BY`, and `MIN`/`MAX`/`COUNT` over one.

### Guarded
- **A number is not a boolean.** `B = 1` raises a conversion error on
  the engine, so it refuses here rather than answering. A string DOES
  convert (`B = 'TRUE'`, case-insensitively).
- A bare non-boolean column is not a predicate: `WHERE NAME` refuses on
  both servers.

### Fixed
- **Two gates that had been red for dozens of increments**, both for the
  same reason and neither of them fire-crab's fault beyond the missing
  literal. `qa/serve-real-params.sh` and `qa/serve-real-ddl.sh` each sent
  a JS `true` as a BOOLEAN parameter — an encoding node-firebird cannot
  produce, and one the REAL ENGINE rejects with `Conversion error from
  string "1"`. Their expectations asked fire-crab to out-do the engine.
  Both now pass a boolean LITERAL where the value is needed and assert
  the parameter's refusal on BOTH servers, which is what that fact
  actually is.

`qa/serve-real-boolean.sh` (46 checks, twin servers). Its centre is the
run of predicates that differ only on the NULL row — `IS TRUE`, `IS NOT
TRUE`, `<> TRUE`, `NOT (= TRUE)` — kept side by side so the difference
shows as a row count rather than an error.

## 2026-07-30 — `?` parameters over the temporal and approximate families

### Converted
- **A `?` against a DATE, TIME, TIMESTAMP, FLOAT or DOUBLE side.**
  `WHERE D = ?`, `WHERE DP > ?`, `BETWEEN ? AND ?`, a parameter against
  approximate arithmetic (`WHERE DP * 2 > ?`) and against an expression
  (`WHERE D + 1 > ?`), in a SELECT and in a DML.
- Two halves had to agree. The **describe** now announces the slot's own
  type — SQL_DATE, SQL_TIME, TIMESTAMP, DOUBLE — because the client
  builds its encoder from it, so a wrong announcement does not produce a
  wrong answer but a wrongly ENCODED message. The **bind** turns the
  arrived value into a literal EXPRESSION rather than one of the exact
  `Rhs` shapes, which a DATE or a DOUBLE is not; the bound term is then
  the same three-valued comparison a written-out literal produces, and
  the gate checks the two select the same rows.
- An exact value arriving for an approximate slot converts (a driver may
  send `1` where a DOUBLE was announced), and a NULL parameter is
  UNKNOWN rather than an error, as before.

### Guarded
- **A TIMESTAMP value for a TIME slot refuses.** The input BLR is
  VALUE-derived, not descriptor-derived: node-firebird sends any JS Date
  as `blr_timestamp` whatever the describe said. Against a DATE column
  that is harmless — a DATE reads as midnight against a TIMESTAMP — but
  against a TIME column the engine promotes the TIME with the CURRENT
  DATE (probed: every stored row then sorts above a 1970 timestamp), and
  reading the timestamp's time half instead would answer a different set
  of rows with no error anywhere. A driver that honours the announced
  descriptor and sends a real TIME binds normally.

`qa/serve-real-typedparams.sh` (26 checks, twin servers on identical
databases), which also runs each parameter form beside its written-out
literal on the same server: a bind that lands the value in the wrong
shape shows up there even when both servers agree with each other.

## 2026-07-30 — approximate ARITHMETIC, and the literal that makes one

### Converted
- **Arithmetic over FLOAT and DOUBLE**: `DP * 2`, `DP / 3`, `DP + N`,
  `I / DP`, nested and parenthesised, in a WHERE, under an aggregate, as
  a GROUP BY key, in ORDER BY, in a subquery's value and on the right of
  a SET. `Expr::Bin` had arms for integers, exact numerics and the
  temporal types and nothing for this family.
- **ONE approximate operand makes the whole result approximate** — the
  engine's descriptor promotion. `DP + N` is a DOUBLE, not a
  NUMERIC(9,2), and there is no scale to carry.
- **An EXPONENT makes a literal approximate**, whatever the digits look
  like: `1e3` is a DOUBLE 1000, not the integer, and `1.5e0` is a DOUBLE
  where a bare `1.5` is an exact NUMERIC. Both lexers learned it — the
  select list's character parser and the predicate tokenizer — because
  either one alone would make the same literal mean two things.

### Guarded
- **The engine RAISES on float division by zero and on overflow.** It
  does not answer an IEEE infinity or a NaN, so a value there would be a
  wrong answer rather than a lenient one: new `EvalErr::FloatDivideByZero`
  (`isc_exception_float_divide_by_zero`) and `EvalErr::FloatOverflow`
  (`isc_exception_float_overflow`), each with its own gds code. The
  integer divide-by-zero shares SQLSTATE 22012 but is a different code
  with different text, and the gate checks the two do not collapse into
  one.
- A NULL operand is still NULL, never a division error — the NULL check
  runs before the divisor is looked at.

`qa/serve-real-approxmath.sh` (39 checks, twin servers). Every arithmetic
result is concatenated into TEXT before comparing, so the check sees the
engine's own rendering: an exact 11.75 and an approximate
11.75000000000000 are the same number to a driver that decodes both into
a JS number, and the promotion is only visible in the digits.

## 2026-07-30 — CAST's target list, and how an approximate number PRINTS

### Converted
- **`CAST(<expr> AS <type>)` across the whole target list**: `NUMERIC(p,
  s)` / `DECIMAL(p, s)` (including a precision past 18, which stores and
  announces as INT128), `FLOAT` / `DOUBLE PRECISION`, `DATE`, `TIME` and
  `TIMESTAMP` — alongside the integer and CHAR/VARCHAR targets that were
  already there. Conversions in every direction the engine allows,
  nested, in a WHERE, and inside an aggregate.
- The rounding is the engine's: **HALF AWAY FROM ZERO**, at the declared
  scale. `CAST(12.55 AS NUMERIC(9,1))` is 12.6 and `-12.55` is `-12.6`;
  `CAST(2.5 AS INTEGER)` is 3 and `CAST(-2.5 AS INTEGER)` is -3.
  Truncation and banker's rounding each answer one of those differently
  and neither raises.

### Fixed
- **An approximate value printed as the wrong STRING.** The engine
  renders a DOUBLE at 16 significant digits and a FLOAT at 8, trailing
  zeros kept, scientific outside the fixed range — C's `%#.16g` /
  `%#.8g`. Rust's default float formatting prints the shortest
  round-tripping form, `1.5` where the engine writes
  `1.500000000000000`: the same number, a different string, and this
  text is what `CAST ... AS VARCHAR` and `||` both produce.
- **FLOAT needed its own `Value` variant to say so.** 1.5 is exactly
  representable at either width, so nothing about the NUMBER says which
  one stored it — only the column does. `Value::Float(f32)` now decodes
  from REAL; every arithmetic path asks `approx_of` for the f64 behind
  it, and only `render` cares which it was.

### Guarded
- A TIME does not CAST to a DATE or a TIMESTAMP: the engine fills the
  date from the CURRENT DATE, which this server does not do — the same
  reason the two do not compare.
- An unknown target (`CAST(I AS BLOB)`) refuses rather than falling back
  to another conversion.

`qa/serve-real-cast.sh` (53 checks, twin servers). Every check runs over
all three rows, one of which is the negative of another, because a
rounding rule that is right for the positive and wrong for the negative
is exactly what half-away-from-zero distinguishes.

`qa/diff-rows.sh` stopped SKIPPING float and double columns. It compares
the raw file's decoded text against isql's own — no wire protocol in
between — which makes it a second, independent oracle for the rendering
above, and it was the run that caught the FLOAT/DOUBLE digit difference
in the first place.

`qa/serve-real-approx.sh` lost its `CAST AS DOUBLE PRECISION` refusal
and gained two comparisons — the third refusal-list entry promoted this
way in four slices.

## 2026-07-30 — the wire server: FLOAT and DOUBLE PRECISION as operands

### Converted
- **Approximate numerics in a predicate**: every operator against an
  exact literal, against another column (exact or approximate),
  `IS [NOT] NULL`, `BETWEEN`, `IN`, unary minus and `ABS` — in a SELECT
  and in a DML.
- **Aggregates over them**: `SUM`/`AVG`/`MIN`/`MAX` over `DOUBLE
  PRECISION` and over `FLOAT`, global and grouped, in `HAVING`, and as a
  subquery's value. All describe as DOUBLE, which is what the engine
  announces for a FLOAT source too (probed).
- A new `ExprType::Approx` keeps the family apart from `Numeric`, which
  is EXACT and folds in i128. The two answer differently and must:
  `AVG(N)` truncates at the source's scale, `AVG(DP)` is 1.875.

### Fixed
- **Mixed comparisons fell to the RENDERED-TEXT last resort.** An
  approximate value has no exact `(raw, scale)` decomposition, so
  `num_cmp` declined every mixed pair and `value_cmp` compared the two
  by their printed form. Text ordering is not numeric ordering — `"1.5"`
  sorts after `"10"` — so the comparisons that looked right were right
  by luck. `value_cmp` now promotes the exact side to f64, the engine's
  own conversion.

### Guarded
- A string literal against an approximate side is CONVERTED at prepare
  (`DP > '1.25'`), and one that does not parse refuses — where the
  engine raises SQLSTATE 22018. Neither returns rows.
- `CAST(... AS DOUBLE PRECISION)` still refuses: the CAST target list
  holds only integer and text types, a separate surface.
- An approximate branch may not share a `CASE`/`COALESCE` describe with
  another family yet, and there is no approximate `?` parameter path.

`qa/serve-real-approx.sh` (46 checks, twin servers on identical
databases). Its values are chosen so text ordering and numeric ordering
DISAGREE — `DP < 10` with a 1.5 row in the table is the check that a
text compare cannot pass. `qa/serve-real-subqagg.sh` lost its
approximate-source REFUSAL pair and gained two comparisons instead: both
positions answer now, and the property being defended (a subquery and a
select list treat one expression the same way) is unchanged.

## 2026-07-30 — the wire server: a DATE/TIME/TIMESTAMP column in a WHERE

### Converted
- **Temporal columns in a predicate.** Every operator against a typed
  literal (`WHERE D > DATE'2021-01-01'`), `IS [NOT] NULL`, `BETWEEN`,
  `IN`, `LIKE`, in a SELECT and in a DML alike. Until now a temporal
  column refused the whole statement — `WHERE D IS NULL` included.
- The comparison RULES were already one layer down: the expression path
  compares `Value`s and `value_cmp` reads a DATE as MIDNIGHT against a
  TIMESTAMP, the engine's own conversion. What was missing was the ROUTE
  to them (the predicate resolver classified columns through `col_kind`,
  which answers Int or Text and nothing else) and the lexer's temporal
  literal: `DATE'...'` was two tokens, so the keyword became a column
  name and the WHERE refused. Both are now one token — as are the clock
  keywords `CURRENT_DATE`, `LOCALTIME`, `LOCALTIMESTAMP`.
- **A temporal answer from a subquery** — `WHERE D = (SELECT MAX(D) FROM
  T)`. A lifted subquery folds its value back into the token stream, and
  a DATE now folds back as a temporal LITERAL rather than not at all.

### Fixed
- **A string literal against a temporal column is CONVERTED, not
  text-compared.** `value_cmp`'s last resort compares two values by
  rendered text, and ISO date text happens to order like dates — so
  `D > '2021-01-01'` was right by accident while `D = '2021-6-15'` (which
  the engine accepts as the same date) compared unequal. The literal is
  now parsed at prepare, per the column's kind.

### Guarded
- `D > 'garbage'` and `D > 20200101` refuse at prepare where the engine
  raises SQLSTATE 22018 at run time. Both are an error to the client;
  what neither may do — and what the text fallback DID — is return a row
  set.
- **TIME against DATE or TIMESTAMP is refused.** The engine promotes a
  TIME to a TIMESTAMP using the CURRENT DATE; this server does not do
  that yet, and a render-compare of the two would have answered every
  row confidently and wrongly.

`qa/serve-real-temporalwhere.sh` (47 checks, twin servers on identical
databases). The fixture's row 1 carries a TIMESTAMP of 08:30 on its own
DATE, so `TS > D` returns it and `D = TS` does not — the case that
separates a real conversion from a text compare. `qa/serve-real-datemath.sh`
lost a refusal and gained two comparisons: `WHERE DATEADD(1 DAY TO D) >
DATE '2024-01-01'` was on its refusal list and is a comparison now.

## 2026-07-30 — the wire server: an aggregate inside a scalar subquery

### Converted
- **`WHERE AMT > (SELECT AVG(AMT) FROM T)`** — an aggregate as the value
  of a scalar subquery, in a SELECT and in a DML alike. AVG, and with it
  MIN/MAX over TEXT, `COUNT(DISTINCT col)`, `AVG(<expression>)` and any
  NUMERIC source's SCALE.
- The subquery no longer folds through the prepare-time integer helper
  (`Option<Option<i64>>`, which refused AVG outright and would have
  flattened `AVG(NUM)` from 11.30 to 11). It builds a **one-item,
  no-key GROUP** and runs the group machinery — because a scalar
  aggregate *is* one group of one item, this is the same code
  `SELECT AVG(NUM) FROM T` already ran, and the argument forms arrived
  with it rather than one at a time.

### Fixed
- **SUM/AVG silently DROPPED approximate values.** The exact fold asked
  `numeric_parts` for `(raw, scale)` and skipped anything that answered
  None — so a DOUBLE column contributed nothing and `AVG(D)` folded to
  NULL over a table full of numbers. The fold now promotes: one
  approximate input makes the whole fold approximate (carrying the exact
  rows that arrived before it), the way the engine's descriptor
  arithmetic does.

### Guarded
- An approximate source is refused in the SUBQUERY as well, because the
  top-level `SELECT AVG(D) FROM T` is refused: one expression cannot be
  legal in one position and illegal in the other. The gate checks both
  positions in a single case.
- `AVG(DISTINCT ...)` and `SUM(<text>)` refuse rather than fold.

The gate (`qa/serve-real-subqagg.sh`, 30 checks) is built around one
property: a subquery's value is a number nobody ever sees, so a wrong
average is not an error — it is a different SET OF ROWS. Each fixture
row is placed so the engine's answer and a plausible wrong one select
different rows: `AVG(AMT)` is 32/4 = 8 with the NULL row ignored and
32/5 = 6 with it counted, and a row sits between them; the average of 10
and 11 is 10 truncated and 11 rounded, and a row sits between those too.
`COUNT(*)` over a system relation is in the gate as well, since routing
subqueries through the group machinery must not lose the record-header
count those relations depend on.

## 2026-07-30 — the wire server: subqueries in a DML WHERE

### Converted
- **`UPDATE`/`DELETE ... WHERE <col> IN (SELECT ...)`**, `NOT IN`, and a
  scalar subquery on the right of a comparison
  (`WHERE ID = (SELECT MIN(UID) FROM U)`,
  `WHERE AMT < (SELECT MAX(N) FROM U)`).
- The predicate was never the missing piece - the SELECT path has
  answered these shapes for slices. What the DML planners lacked was the
  LIFTING pass in front of the parser: each subquery is evaluated once
  and folded back into the token stream as ordinary values before the
  predicate parser ever sees it. Both DML planners now run the same pass
  the SELECT path runs, which is why `IN`, `NOT IN` and the scalar forms
  all arrived together.

The gate (`qa/serve-real-dmlsubq.sh`, 17 checks) is mostly TABLE
comparisons on purpose: a DML returns no rows, so a subquery filter that
selects the wrong rows deletes the wrong rows and nothing in the reply
shows it. Every statement runs against both servers on identical
databases, and after each one both tables are compared - including the
subquery's own table, to prove it was only read.

## 2026-07-30 — the wire server: where NULL sits, and ORDER BY expressions

### Converted
- **`ORDER BY ... NULLS FIRST | LAST`.** The DEFAULT placement was
  already right and is worth naming: it is not "first" or "last" but
  LOW - NULLs sort below every value, so they come FIRST ascending and
  LAST descending. An explicit `NULLS FIRST`/`NULLS LAST` states a
  POSITION instead, and that position does NOT flip with the direction,
  so the four combinations are four different orders. A converter that
  reads the clause as "reverse the default" gets two of them wrong.
  Every ORDER BY key carries its own placement, including a UNION's
  ordinal form.
- **`IS [NOT] DISTINCT FROM`**, the null-safe comparison, desugared at
  parse time the way `BETWEEN` and `IN` already are, so every later
  stage sees shapes it knows:

  ```text
  A IS NOT DISTINCT FROM NULL  ==  A IS NULL
  A IS NOT DISTINCT FROM v     ==  A = v                    (v not null)
  A IS DISTINCT FROM v         ==  A IS NULL OR A <> v
  A IS NOT DISTINCT FROM B     ==  A = B OR (A IS NULL AND B IS NULL)
  ```

  The third line is the one worth stating: `NOT (A = v)` is a DIFFERENT
  predicate, because a NULL A makes the comparison UNKNOWN and drops the
  row - while the engine returns it. The gate keeps `<>` and `NOT (=)`
  beside the new operator to show the three apart.

### Converted (same slice, second half)
- **`ORDER BY <expression>`**: `ORDER BY AMT + 1`,
  `ORDER BY CASE WHEN AMT IS NULL THEN 1 ELSE 0 END`,
  `ORDER BY UPPER(NAME) NULLS LAST` - the key is computed per row, by the
  same parser and resolver the select list uses, so an expression that
  can be projected can also be sorted by. It carries the same direction
  and NULLS clauses a column key does.
- Every key's value is computed ONCE per row (a decorate-sort pass), not
  inside the comparator: an expression that raises mid-sort must fail the
  fetch the way it would fail a projection, and a comparator has nowhere
  to report that.

### Fixed
- The ORDER BY item parser matched on TOKEN COUNTS, which cannot work
  once items may be expressions: `AMT + 1` is three tokens and looks
  exactly like `ID NULLS LAST` to a shape match. It now strips the
  trailing `[ASC|DESC]` and `[NULLS FIRST|LAST]` clauses first and then
  decides what the head is - a bare identifier, an ordinal, or an
  expression. An expression it cannot resolve refuses the statement
  rather than sorting by something else.

The gate (`qa/serve-real-nulls.sh`, 25 checks) runs every statement
through the SAME driver against TWO servers - fire-crab and the live
engine - on identical databases: the two default orders, all four
explicit combinations, a second key with its own placement, a text
column, the ordinal form, both directions of the comparison against
values, NULLs and other columns, and a refusal for a NULLS position that
is neither FIRST nor LAST.

## 2026-07-30 — the wire server: DML with RETURNING

### Converted
- **`INSERT` / `UPDATE` / `DELETE ... RETURNING <columns>` over the
  wire.** The statement plans WITHOUT its clause - so every default,
  NOT NULL, CHECK, FK and index path stays exactly the one an unadorned
  write takes - and the clause wraps the result.
- **It is a CURSOR, not a singleton.** In Firebird 5 an UPDATE that
  touches three rows returns three; the statement is therefore typed
  `isc_info_sql_stmt_select` and its rows are fetched. That type is not
  cosmetic: node-firebird dispatches on it, fetching all rows for a
  select and exactly one for an exec_procedure, so announcing the DML
  type instead makes a client fetch nothing.
- **Which row each statement gives back** (probed): an INSERT returns
  the row as stored (defaults filled in), an UPDATE the row as it
  stands AFTER the update, a DELETE the row as it WAS.
- The DML runs at op_execute like every other write, and the rows it
  touched become the cursor the next fetch drains - once. A
  materialised cursor that re-emits its rows turns a driver's
  fetch-until-empty loop into duplicates.

### Guarded
- **`NEW.`/`OLD.` qualifiers are refused, because the engine refuses
  them.** They are the PSQL trigger contexts and do not exist in DSQL:
  `RETURNING NEW.ID` answers `Column unknown, "NEW"."ID"`. fire-crab
  accepted them at first - and so returned rows for a statement the
  engine rejects AND wrote a row the engine never wrote. The gate
  caught it because it compares the TABLE afterwards, not just the
  rows. A qualifier naming the target table (`RETURNING T.ID`) is fine
  and works on both.
- An expression in the list (`RETURNING AMT * 2`) is refused at PREPARE,
  so the write does not happen: running the DML and handing back an
  empty cursor is the worst possible outcome for this clause.

The gate (`qa/serve-real-returning.sh`, 14 checks) runs every statement
through the SAME driver against TWO servers - fire-crab and the live
engine - on two identical databases, and compares both the rows and the
resulting table.

## 2026-07-30 — fire-crab-opt slice 9: a unique lookup costs a fixed four

### Converted
- **The retrieval-cost law that decides join orders.**
  `Retrieval::getInversion` (Retrieval.cpp:371-384) prices a UNIQUE
  equality retrieval at a FIXED `DEFAULT_INDEX_COST * indexes + 1` = 4,
  with the comment "independent from a possibly outdated statistics",
  and a non-unique one at `index scan + cardinality * selectivity`.
  `IndexInfo` therefore grew a `unique` flag (`RDB$UNIQUE_FLAG`), and
  both the two-stream cost model and the chain's arrangement search now
  use it.
- **The consequence is counter-intuitive and it is the engine's**: on a
  database whose statistics are zero a unique lookup (4) costs MORE than
  a non-unique one (3), so the engine drives the stream whose inner
  lookup is NON-unique. Probed: with `A.BX` indexed and `B.ID` a primary
  key it plans `JOIN (B NATURAL, A INDEX (A_BX))` in BOTH SQL orders,
  while two symmetric indexes keep the SQL order - because
  `findJoinOrder` replaces its best arrangement only on a STRICTLY
  smaller cost (InnerJoin.cpp:366).
- **A chain drives from its FAR end** for the same reason: two
  non-unique lookups (3 + 3) beat two unique ones (4 + 4). Reaching that
  arrangement also needed the placement search fixed - it demanded the
  remaining streams in index order, which threw away every arrangement
  that reaches its neighbours in the opposite direction.

### Fixed
- **The refusal added in slice 8 is lifted**: a two-stream join with both
  keys indexed is planned again, now by cost rather than by keeping the
  SQL order. The refusal was the honest placeholder for exactly one
  slice.
- A shape from the probed cardinality BANDS no longer overrides the
  per-arrangement costing when it merely says "keep the SQL order". The
  bands were probed on databases with symmetric indexes, where that was
  always right; a real cost decision still wins, as it should.

### Guarded
- The stale-statistics refusal is untouched: a zero selectivity on a
  POPULATED index still refuses, because there the engine keeps costing
  with state this crate has not converted.

The gate grew a FIFTH database whose join sides are indexed
ASYMMETRICALLY - a primary key against a plain index - which is the shape
none of the other four had, and the one that exposed both of slice 8's
wrong answers and this slice's law. 87 checks.

## 2026-07-30 — fire-crab-opt slice 8: outer joins, and two wrong answers they exposed

### Converted
- **Outer joins in chains**, the frontier item this row named. An inner
  join can be reordered, so a chain of them FLATTENS into one
  `JOIN (a, b, c)` list; an outer join cannot, so it makes a plan NODE
  and the chain NESTS:
  `JOIN (JOIN (A NATURAL, B INDEX ...), C INDEX ...)`. The plan model
  grew a `PlanNode` for exactly that shape.
- Inside such a chain the INNER join at the head is still free to swap
  before the outer join wraps it - probed:
  `A JOIN B ON A.BX=B.ID LEFT JOIN C ON B.CX=C.ID` plans
  `JOIN (JOIN (B NATURAL, A INDEX (A_BX)), C INDEX (PK_C))`.

### Fixed
- **RIGHT JOIN was answered as if it were LEFT.** It is LEFT with the
  sides exchanged: the PRESERVED side drives, so `A RIGHT JOIN B ON
  A.BX = B.ID` plans `JOIN (B NATURAL, A INDEX (A_BX))` and fire-crab
  printed `JOIN (A NATURAL, B INDEX (PK_B))`. The ON clause needs no
  rewriting - `A.BX = B.ID` means the same either way round - which is
  what makes the engine's own parser-level rewrite sound.
- **FULL JOIN was answered as a single nested loop.** It is BOTH
  directions, and the engine prints both:
  `JOIN (JOIN (A NATURAL, B INDEX ...), JOIN (B NATURAL, A INDEX ...))`.
  A plan showing one half answers a different question.

### Guarded
- **A two-stream join whose BOTH keys are indexed is now REFUSED**
  instead of answered by keeping the SQL order. Probed: with `A.BX`
  indexed and `B.ID` a primary key the engine drives B in BOTH SQL
  orders - the choice is a property of the streams, decided by
  `StreamInfo::cheaperThan` (independence, then previousExpectedStreams,
  then baseCost; Optimizer.h:895) and by which arrangement costs less.
  That ordering is not converted, so the old answer was right only by
  accident. The refusal names the two indexes and the reason.
- RIGHT and FULL joins INSIDE a chain refuse: the nesting is converted,
  the direction-swap within a chain is not.

The gate grew from 68 to 78 checks: LEFT chains in three shapes,
inner-then-outer and outer-then-inner, RIGHT in both SQL orders, FULL in
two, an outer chain with a driving filter, and the two new refusals.

## 2026-07-30 — fire-crab-lck slice 5: the whole dump, and three offsets that hid in empty queues

### Converted
- **The rest of `fb_lock_print`.** Slice 4 matched the header and owner
  sections; this one adds `-l` (lock blocks with their keys), `-r` (the
  request blocks inside each owner) and `-h` (the history rings), so
  every switch - and `-a`, 1990 lines on a contended table - is
  byte-identical to the engine's tool on the same snapshot.
- **A lock's KEY is where its bytes become meaning**, and its shape
  depends on the SERIES: a page lock prints `space:page` (with the stored
  order reversed - the key holds the page number first), a relation lock
  `relation:instance`, a transaction or attachment lock one 64-bit
  number, a record-GC lock `page:line` packed in one key, an index-rescan
  lock `relation:index` packed in four bytes, and anything else either a
  plain number, `<none>`, or printable bytes with `<NNN>` escapes.
- **Two history rings, not one**: `lhb_history` under the title `History`
  and `shb_history` under `Event log` (print.cpp:885-886). The rings are
  circular and pre-allocated - operation 0 is an unused slot, skipped but
  still advancing the walk, and the walk ends when a next pointer returns
  to the head rather than at a null.

### Fixed
- **Three queue-field offsets from slice 4 were wrong, and every check
  passed anyway.** `offsetof(lrq, lrq_lbl_requests)`, `lrq_own_blocks`
  and `lrq_own_pending` were each shifted by one field - invisible
  because those queues (`Free requests`, `Blocks`, `Pending`) are EMPTY
  on a server with no contention, and an empty queue prints `*empty*`,
  which has no offset in it to be wrong about. Making the server contend
  - a second transaction taking `WAIT RESERVING ... FOR PROTECTED WRITE`
  while the first holds it - filled the pending queue and the dump
  disagreed by exactly eight bytes (91216 against 91224). The gate now
  creates that contention before comparing, so the offsets are held by
  something. Second slice in a row where a field that is usually empty
  turned out to be a field whose offset was never tested.
- **A series enum transcribed from a numbered listing was off by one**
  past `LCK_attachment`. `lck_t` starts at `LCK_database = 1`, so a
  series' value is its position - and every single-number key printed
  correctly regardless, so the error showed up on exactly ONE line in
  636: series 22's four-byte key, which the engine splits as `0004:0000`
  and fire-crab printed as `262144`.
- **A quirk reproduced rather than corrected**: `prt_request` writes
  `"AST: 0x%p"` and glibc's `%p` already emits `0x`, so the engine's real
  output is `AST: 0x0xeb781933e044`. fire-crab prints the double prefix
  too - the differential is the tool's text, not the text it meant.

### Guarded
- The AST line prints pointers into the server's address space. They are
  meaningless outside that process and match only because both readers
  read the same snapshot; the docs say so rather than implying otherwise.
- `-w` (the wait-for cycles) and `lbl_counts[LCK_max]` stay unconverted,
  and so does writing to the table.

## 2026-07-30 — fire-crab-lck slice 4: the shared lock table, in fb_lock_print's words

### Converted
- **The lock manager's other half.** Slices 1-3 converted the POLICY (the
  compatibility matrix, the queues, the verdicts) as an in-process model.
  This one converts the BYTES several processes share: the file the
  server maps as its lock table (`/tmp/firebird/fb_lock_<id>`), decoded
  from `src/lock/lock_proto.h` and printed in `fb_lock_print`'s own text
  (`src/lock/print.cpp`). `fclck dump <file> [-o]` produces the
  `LOCK_HEADER BLOCK` with its counters, the hash-length distribution,
  the four queues and an `OWNER BLOCK` per owner - **byte-identical to
  the engine's tool on the same snapshot**, tabs and column widths
  included.
- **Self-relative queues, and the offset the tool does not print.**
  Every pointer is a byte offset from the start of the table (`SRQ_PTR`,
  que.h:108) because each process maps the region elsewhere. A queue
  node sits INSIDE its block, so `prt_que` prints
  `srq_forward - offsetof(own, own_lhb_owners)` - the BLOCK. On a live
  table the queue held 78408 and the tool printed 78392: sixteen bytes,
  and without them a dump refers to nothing.
- Owner blocks with their three queues (granted, blocking, pending), the
  process block behind each owner, and the `Alive`/`Dead` check - the
  engine's `kill(pid, 0)` becomes a `/proc/<pid>` lookup, which answers
  the same question for the only processes this table can hold.

### Fixed
- **The counter run hid three wrong offsets behind zeros.** `lhb` has
  eleven `FB_UINT64` counters, then `lhb_operations[LCK_MAX_SERIES]`,
  then seven more. My first guesses for `Rejects`, `Blocks`,
  `Deadlock scans` and `Deadlocks` were all four wrong, and three still
  printed a plausible `0` on a quiet server. Only `Deadlock scans` -
  whose wrong offset read into the hash table - printed garbage and gave
  it away. A field that is usually zero is a field whose offset is
  usually untested.
- **A near-miss in a statistic is a real failure.** `lhb_hash` sits after
  `srq lhb_data[LCK_MAX_SERIES]`; with its offset wrong the distribution
  came out *nearly* right - 53 chains of length one where the engine
  counted 52 - with a maximum chain length of 131072, which is not a
  plausible bucket. Nobody reading the dump would have noticed the 53.

### Guarded
- The comparison is made on a SNAPSHOT (`cp` the file, then
  `fb_lock_print -f`), because reading live shared memory twice gives two
  different tables - `Enqs` and `Acquires` move between the readings.
- Queue walks are bounded by the table's own size and stop on a
  self-pointing node: a snapshot of live memory can catch a queue
  mid-update, and a dump must still terminate.
- `own_flags`'s offset depends on libc (`event_t` embeds a
  `pthread_mutex_t` and a `pthread_cond_t`), so a lock table is not
  portable across builds. `shm::EVENT_T_SIZE` is that assumption, alone
  and labelled.
- Lock blocks, request details, the history ring and the wait-for cycles
  (`-l`, `-r`, `-h`, `-w`) stay unconverted; writing to the table stays
  out entirely.

## 2026-07-30 — fire-crab-svc slice 2: gstat asks fire-crab for statistics

### Converted
- **A service ACTION, end to end.** `isc_action_svc_db_stats` with
  `isc_spb_sts_hdr_pages`: the engine's own `gstat`, pointed at
  fire-crab's service manager, now prints a database's header
  statistics that fire-crab computed from the file and streamed back —
  and the gate requires that text to be IDENTICAL to what the same
  `gstat` prints when it reads the file itself.
- **`gstat -h`'s report text** (`fire_crab_ods::header_report`, the
  conversion of `PPG_print_header`, ppg.cpp:56-287), which needed three
  details a converter can easily get backwards:
  - **`Flags` is the PAGE's flags** (`hdr_header.pag_flags`, usually 0),
    not `hdr_flags`. The interesting bits come out below as
    `Attributes`. Printing `hdr_flags` there gives 18 where gstat gives 0.
  - **The `Attributes` label is unconditional, its value is not**: the
    label goes out with no newline and only an existing attribute adds
    text and the line break, so a database with none leaves the line
    dangling. The gate keeps a `gfix -w async` database to cover exactly
    that.
  - **`Database dialect 1` means "no dialect information in the
    header"** — the absence IS the answer (ppg.cpp:81-87).
- **The header fields that report needs**, new in the ODS decoder: the
  implementation triple (`hdr_db_impl` through `DbImplementation`'s
  hardware/OS/compiler NAME TABLES — an index into a list, so the tables
  are part of the format), the creation date, the shadow count, the
  crypt plugin name, and the **variable header clumplets** after the
  fixed part (`hdr_data` at offset 148, `<type><length><data>` until
  `HDR_end`) where the sweep interval, the backup difference file and
  the replication sequence live.
- **The output stream, and the strangest law in this subsystem.**
  `isc_info_svc_line` returns the bytes up to and including the newline
  with **the newline replaced by a space** (svc.cpp:2404, comment and
  all), so a blank line arrives as a single space — `3e 01 00 20 01` —
  and "nothing" is reserved: a ZERO-length item is end-of-stream.
  `isc_info_svc_to_eof` returns the raw bytes, newlines intact. Both
  conventions were read off the live engine's wire with
  `fcsvc stats --raw` BEFORE being implemented, and the gate compares
  the engine's bytes with fire-crab's for the same poll.
- **The real `SpbStart` grammar**: a per-(action, tag) framing table
  (`ClumpletReader::getClumpletType`), because a start SPB mixes
  2-byte-length strings with bare 4-byte integers and nothing in the
  bytes says which is which. An unknown pair is refused rather than
  guessed — guessing a length turns the next tag into data.
- A service session is **stateful**: start, then poll until the stream
  ends. The server now holds that output per connection.

### Guarded
- **The engine's own validation, with the engine's own code.** `-h`
  combined with any other analysis is refused — *"option -h is
  incompatible with options -a, -d, -i, -r, -schema, -s and -t"*, gstat
  message 38, arriving as gds **336920614** (facility-coded, not an
  `isc_*` number). fire-crab converts the rule and refuses the same
  combinations with the same code; the check runs BEFORE fire-crab's own
  capability check, so a malformed request gets the engine's answer
  rather than "fire-crab cannot do that".
- Statistics fire-crab cannot compute (data pages, index pages, record
  versions, encryption, the log) are refused with `isc_wish_list`, and
  the gate requires the REAL server to PERFORM the same request — so the
  refusal is provably ours and not the request's. An empty section would
  have read as "this database has no data pages".
- The service timestamps fire-crab prints are UTC where the engine
  prints the server's local time. Stated in the code and in the docs
  rather than faked; the gate compares the report, not gstat's own
  timestamp lines.

## 2026-07-29 — fire-crab-pio slice 1: the floor, and the last planned row

### Converted
- **A NEW CRATE for `src/jrd/os/posix/unix.cpp`** — the `PIO_*` layer
  every page read and write passes through. Very little code, and
  everything above it assumes all of it:
  - `offset = page * page_size` (`seek_file`), ABSOLUTE, with no
    rebasing — because **Firebird 6 has no multi-file databases**.
    `jrd_file` is one descriptor: no chain, no `fil_min_page`, no
    `fil_max_page`, and `PageSpace` holds a single file. A converter
    carrying an older engine's file chain would subtract a base that no
    longer exists and place every page in the wrong spot. Converting the
    current engine means converting its absence.
  - `PIO_get_number_of_pages` = `file_size / page_size`, INTEGER
    division: a trailing partial page is invisible, not rounded up and
    not an error. Which is why a healthy database's length is a whole
    number of pages — a check fire-crab adds, since the division alone
    hides a truncation.
  - `openFile`'s three flags, and the finding that **Forced Writes is an
    OPEN MODE**: `SYNC` in the open flags, decided from
    `hdr_force_write` (header offset 22), not an fsync after each write.
    That is why changing it at runtime reopens the file, and why
    `PIO_force_write` FLUSHES FIRST when switching it on — the pages
    already in the OS cache were written under the old promise.
  - `PIO_extend`'s fallocate arithmetic, and `PIO_init_data`'s floor: it
    never writes below PAGE 8, which holds the header, the first PIP and
    the first pointer page. fire-crab refuses such a request instead of
    silently returning zero.
- **The lock law, which explains this project's own foundations.**
  `lockDatabaseFile` flocks the whole file — `LOCK_EX` when
  `getServerMode() == MODE_SUPER` — and reports a busy lock as
  `isc_already_opened`, the *"Database already opened with engine
  instance"* error this repository has now hit twice. fire-crab's readers
  take NO lock, which is exactly what lets every differential here read a
  database the server holds open; the gate proves both halves at once
  (BUSY while attached, and a successful read at the same moment).

### Guarded
- A page past the end of the file is an ERROR, never a zero-filled
  buffer. Zeros for a page that does not exist are indistinguishable,
  one layer up, from a page that legitimately holds zeros.
- O_DIRECT is reported but not applied: it requires every buffer, offset
  and length aligned to the device block size, which this reader does not
  guarantee. Stating the law without obeying it beats pretending.
- Shadowing, nbackup difference files, raw-device page counts (an ioctl,
  not `stat`) and the Windows half of the layer stay unconverted.

### Fixed (in the gate, before it could lie)
- The growth phase inserted its rows with a 4000-level recursive CTE.
  Firebird caps recursion at 1024, so the insert failed silently and the
  gate then "verified" a page count that had not moved — three identical
  checks wearing different labels. Now the generator cross-joins a
  500-level recursion, and the gate ASSERTS that the file grew
  (313 → 401 pages for 12 000 rows) before trusting the comparisons.

### Milestone
- With this row, **every subsystem in `docs/subsystem-map.md` has a
  converted first slice with a live differential**. That is breadth, not
  completeness: what remains is depth inside each row, and the frontier
  paragraph on each row says what.

## 2026-07-29 — fire-crab-svc slice 1: the engine's own fbsvcmgr, on both sides

### Converted
- **A NEW CRATE for `src/jrd/svc.cpp`** — the Services API, which is a
  second protocol living inside the first: a client attaches to the name
  `service_mgr` instead of a database, and from then on every request
  and every answer is a byte buffer of tagged items. No statements, no
  BLR, no rows. `gbak`, `gfix`, `gstat`, `nbackup`, `fbsvcmgr` and every
  driver's service class are all this one interface, so converting the
  buffers converts the tools.
- **The four grammars the same-looking bytes follow**
  (`ClumpletReader`'s kinds, ClumpletReader.cpp:262-310): the attach SPB
  is TAGGED with 1-byte lengths, the query's "send" items carry 2-byte
  lengths except the control codes which stand alone, the "receive"
  items are bare tags with no lengths and no terminator, and a start SPB
  is a state machine keyed by its action byte. Read a send buffer as an
  attach buffer and a length becomes a tag.
- **The two answer shapes, chosen per item.** Strings go through
  `INF_put_item` (`[tag][u16 LE len][bytes]`), numerics through
  `ADD_SPB_NUMERIC` (`[tag][4 bytes LE]`, no length at all). NOTHING in
  the bytes says which, so `item_is_numeric` carries that knowledge,
  read off which macro svc.cpp uses at each site.
- **The `isc_info_svc_svr_db_info` cluster**: a BARE opening tag
  (svc.cpp:1163 writes `*info++ = item`), then `isc_spb_num_att` and
  `isc_spb_num_db` as numerics, then a `isc_spb_dbname` string per
  database, closed by `isc_info_flag_end`. The old hand-rolled responder
  did not answer this item at all; `fbsvcmgr -info_svr_db_info` now
  works against fire-crab.
- **fire-crab's own service client** (`fcsvc`): op_connect with SRP
  (through `fire-crab-auth`), `op_crypt` Arc4, then op_service_attach /
  op_service_info / op_service_detach against a live server. A client
  that declares the wire-crypt stance ENABLED and then sends plaintext
  is refused by the default server with `isc_miss_wirecrypt` (335545065)
  — the declaration is a promise.

### Fixed
- **The truncation boundary was off by one, and the engine said so.**
  `INF_put_item`'s room test is `ptr + length + 4 >= end` — a `>=`, so
  the last byte of the client's buffer is never used and an n-byte
  answer needs n + 5. The first implementation used `>` and fit an
  answer the engine would have truncated. Caught by asking the LIVE
  server for its 35-byte version banner with a 39-byte buffer (it
  answers `isc_info_truncated`, `isc_info_end`) and a 40-byte one (it
  answers the string). The numeric path's `ck_space_for_numeric` really
  does use a strict `>`, one byte apart from the string path's; both are
  converted as written rather than unified.

### Guarded
- **A service ACTION is refused, where it used to be acknowledged.**
  `op_service_start` answered a clean `op_response` with the comment
  "acknowledge so the client does not desync" — but a clean response to
  a backup request means "done": the client then polls an empty output
  stream and reports a successful backup that never happened. Now
  `fbsvcmgr` prints *"feature is not supported"* (`isc_wish_list`) for
  `action_db_stats` against fire-crab and the real statistics against
  the engine, and the gate requires exactly that pair.
- **An unimplemented info item refuses the whole query**, because that
  is what the engine does: `query2`'s `default:` arm is
  `status << Arg::Gds(isc_wish_list)`, not a marker and not silence.
  Both servers refuse `isc_info_svc_get_license` with the same
  335544378. Skipping the item would be worse than either — the client
  would read the NEXT item's bytes as this item's answer.
- The actions themselves (gbak/gfix/gstat behind an SPB) and the
  `isc_info_svc_line`/`to_eof` output stream stay unconverted, as
  constants only.

### Fixed (the auth gate, from re-running it)
- `qa/auth-srp.sh` read the security database by copying the file and
  waiting for the user it had just written to APPEAR. Existence is not
  freshness: on a re-run the name already existed, so the copy returned
  the PREVIOUS run's row and the gate reported a verifier mismatch that
  was really a race (the engine writes the data page before it flips the
  TIP, and the security database is written by an attachment the engine
  caches). Now every user carries the run's pid, so existence does imply
  freshness, and after an ALTER the gate waits for the SALT to change -
  a signal that is not the answer being checked. Waiting for "the
  verifier matches" would have been a gate that agrees with itself.

## 2026-07-29 — fire-crab-auth slice 1: the engine's own verifiers as the oracle

### Converted
- **A NEW CRATE for `src/auth/SecureRemotePassword`** — and the split is
  the engine's own: `src/remote/` never authenticates, it CARRIES
  opaque blobs to a named plugin (`Srp256`, `Srp`, `Legacy_Auth`) and
  asks whether it is satisfied. So SRP and the from-scratch
  SHA-1/SHA-256/bignum/Arc4 under it moved out of `fire-crab-wire`
  into `fire-crab-auth`, where one implementation now serves four
  roles: CLIENT (fire-crab logs in to the engine), SERVER (`fcwire
  serve` accepts node-firebird, isql and the OO drivers), USER MANAGER
  (the verifier `CREATE USER` stores — new in this slice), and ORACLE
  (`fcauth`).
- **Both plugin variants.** `Algo::{Srp, Srp256}` parameterizes exactly
  what the engine parameterizes — the proof hash and nothing else
  (`RemotePasswordImpl<SHA>::makeProof`, srp.h:134). The scramble u,
  the user hash x and the session key K = SHA1(S) are SHA-1 in both
  (srp.h:91), so Arc4 is keyed by 20 bytes either way.
- **The verifier half.** `compute_verifier` is
  `RemotePassword::computeVerifier` (srp.cpp:103) — v = g^x mod N, the
  bytes `CREATE USER` writes into `plg$srp.plg$srp` beside a random
  salt — and `SrpVerifier::from_stored` is the engine's server path,
  which holds only `(salt, v)` and never a password.
- **The differential is the ENGINE'S OWN STORED BYTES.** The engine
  computed those verifiers; fire-crab recomputes them from the same
  password and must reproduce them exactly, through `ALTER USER`
  re-salting and all. Reading them needs no SQL and cannot use it:
  `databases.conf` ships the `security.db` alias with
  `RemoteAccess = false`, and a direct attach collides with the running
  server — so `fcauth stored` reads the security database with
  fire-crab's own ODS decoder, as BYTES (`OCTETS` columns, via the new
  `fire_crab_ods::field_bytes`).
- **The live handshake, alone.** `fcauth login` does op_connect →
  op_cond_accept → op_cont_auth against the real server and stops
  before attaching, so an `AUTH OK` means one thing only: the engine's
  own plugin recomputed our proof from its stored verifier and agreed.

### Fixed
- **Every number travels as `BigInteger::getText`, not as padded hex.**
  Our A was 256 hex digits where the engine's client (srp.cpp:110,
  `getText`) sends 255 — no leading zero. The number was right and the
  login worked, but the bytes were not what a real client sends. A, B
  and M are now all `hex_text`. Caught by the cross-implementation
  vectors: node-firebird's independent SRP agreed on the VALUE and
  disagreed on the digits.

### Guarded
- **The one-in-sixteen salt is hunted, not hoped for.** The salt is
  stored as 32 raw bytes and sent as `getText` (SrpServer.cpp:325), so
  one user in sixteen has a 63-character salt. The gate ALTERs a user
  until the engine hands out such a salt (9–11 tries in practice) and
  then shows that only the minimal form reproduces the stored verifier
  — the padded 64-character form and the raw bytes do not — and that a
  live login as that user still succeeds. Without the hunt the law is
  untested by construction.
- **The engine's refusals are recorded, not papered over.** A default
  `firebird.conf` serves `AuthServer = Srp256` only, so offering just
  `Srp` cannot reach a proof: the gate asserts the engine's own
  `isc_login_error` (335545106) at op_connect and pins the SHA-1
  variant's arithmetic by loopback and vectors instead. Editing the
  server's configuration to make the check pass would be a gate testing
  itself.
- Legacy_Auth (DES over an 8-character password), the ChaCha wire-crypt
  plugins, cleartext `isc_dpb_password` attach and identity MAPPING stay
  unconverted — the first would add a weak path for no differential
  value, the rest are separate subsystems.

## 2026-07-29 — fire-crab-evt slice 1: an event is a counter

### Converted
- **A NEW CRATE for `src/jrd/event.cpp`** — and the insight the whole
  surface follows from: an event is not a message but a COUNTER
  (`evnt_count`, event.h:105), while a client's interest carries the
  count it has already seen (`rint_count`). From that alone:
  delivery is COMMIT-TIME; ROLLBACK swallows posts because they were
  never counted; several posts of one name COALESCE into ONE delivery
  carrying the new counter (a client learns "it happened, and the
  counter is now N", never "here are three messages"); a fired
  interest comes DOWN until the client re-queues; and a fresh
  interest below the current count fires AT ONCE, which is exactly
  how a subscribing client learns its baseline.
- **The differential is SEMANTIC, and it uses the paper's own
  sample**: `samples/nodejs/events.js` prints those facts against a
  real server over a real auxiliary connection, `fcevt replay` prints
  them from the converted table, and the gate asserts they agree —
  matching on the counter DELTA, the invariant that survives a
  database's own history where absolute counters do not.

### Guarded
- The shared-memory arena (self-relative queues, process and session
  blocks, the watcher thread) and the wire delivery path (the
  auxiliary connection carrying op_event) are transport and stay
  unconverted; cross-process posting and the AST callback are named
  for later. Gate: `qa/evt-semantics.sh` (4 checks); 6 unit tests;
  287 workspace tests.

## 2026-07-29 — fire-crab-opt slice 7: the cost model closes, on fresh statistics

### The experiment that cracked it
- Slice 6 left a refusing band and a puzzle: the 6×6 grid's shape
  looked arbitrary. Running `SET STATISTICS` on every index and
  re-probing changed the WHOLE grid — and the new one is exactly what
  the engine's formulas predict. The bands were never the law; they
  were the formulas' behaviour on STALE statistics.

### Converted
- **Index selectivity from the catalog** (`RDB$INDICES.RDB$STATISTICS`
  — the number `SET STATISTICS` refreshes, 1/distinct-keys).
- **The cost arithmetic itself**: an indexed retrieval costs
  `DEFAULT_INDEX_COST` (3) plus `selectivity × cardinality` for the
  index scan and the same again for fetching the records
  (Retrieval.cpp:1147 and :384); a nested loop pays that per outer
  row (InnerJoin.cpp:192); a hash pays the inner's unfiltered scan,
  the hashing at MEMCOPY + HASHING (0.5 each), and per outer row a
  probe plus match copies (InnerJoin.cpp:229). The engine takes the
  cheapest of {loop either way, hash} — and `avoidHashJoin`
  (InnerJoin.cpp:217) removes the hash entirely when a side looks
  empty or single-rowed at prepare time, because the engine
  distrusts its own cardinality there.
- **With fresh statistics the model is EXACT: all 36 grid cells**,
  including the diagonal's hashes, both swap directions, and the
  tie-break where an EMPTY index looks cheaper than a one-row one.

### Guarded
- A ZERO selectivity on a POPULATED index means the statistics were
  never computed for the data present; the engine keeps costing with
  internal state this crate has not converted, so fcopt refuses and
  says so — `SET STATISTICS makes it plannable`. Gate phase 4 is the
  same grid left stale: 4 exact, 32 refused, ZERO wrong. Gate:
  `qa/opt-plans.sh` 67 → 68 checks across four databases; 281
  workspace tests.

## 2026-07-29 — fire-crab-opt slice 6: the cost model, as far as the engine's own formulas take it

### Converted
- **The engine's CARDINALITY ESTIMATE** — `DPM_cardinality`
  (dpm.epp:262), line for line: count the relation's data pages;
  walk to the first non-secondary page holding primaries and take
  its record count and compressed length; with exactly ONE data page
  the count is EXACT ("too imprecise to be useful, therefore rely on
  the record count"); otherwise
  `dataPages * (page_size - DPG_SIZE) / recordSize`, where
  recordSize rounds the average compressed record plus its header to
  ODS alignment and adds the slot and SPACE_FUDGE. Never below
  MINIMUM_CARDINALITY. It reproduces the engine's imprecision
  faithfully — 500 rows estimate as 628, 3000 as 3770 — which is the
  point: cost decisions are made on THESE numbers, not on true
  counts.
- **The join decision's cardinality BANDS**, mapped by probing a
  6×6 grid of table sizes against the live optimizer: a TINY driver
  (≤ 1) keeps SQL order — the engine is deliberately pessimistic
  about a relation that "looks empty during preparation"
  (InnerJoin.cpp:217) — a TINY inner side makes it SWAP, and once
  BOTH sides are large the HASH wins. **And hash joins have an order
  too**: the LARGER stream is listed first because it PROBES while
  the smaller is hashed into the table (probed — the plan text swaps
  with the sizes).
- **The band in between refuses**, naming both cardinalities: that is
  where `hashCost <= loopCost` turns on index retrieval costs from
  `Retrieval.cpp`, which this slice does not convert.

### Guarded
- Gate phase 3 is the whole 6×6 GRID, and its assertion is the
  property that matters for a partly-converted cost model: **29 of
  36 cells planned exactly, 7 refused, ZERO wrong**. Exactness where
  it knows, silence where it does not. Gate: `qa/opt-plans.sh` 66 →
  67 checks across three databases; 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 5: the cost boundary, measured and enforced

### The finding
- Slices 1-4 verified their rules on EMPTY tables, and the rules are
  right there. On a POPULATED database they are not: with 3000 rows
  against 5, the engine drives the SMALLER stream regardless of SQL
  order; with 3000 against 50 it abandons the nested loop for a HASH
  JOIN even though BOTH sides are indexed (3000 x 600 and 3000 x
  2500 likewise). fcopt would have printed a confident nested-loop
  plan where the engine hashes — a wrong answer the gate could not
  see, because every table in it was empty.

### Converted
- **The boundary is now MEASURED, not assumed.** `row_count` reads
  each joined stream's committed rows through
  `ods::count_primary_records`, and a join whose streams hold ANY
  rows is REFUSED with its cardinality in the message: the decision
  there belongs to a cost model this crate has not converted.
  Single-table access paths stay unconditional — verified structural
  at three thousand rows, including a predicate on a column with one
  distinct value still taking its index.
- **The gate grew a second phase on a populated database**: the
  single-table plans that must still match with data, and the
  populated joins where fcopt refuses — each refusal RECORDING the
  engine's own plan beside it, so the frontier is documented with
  evidence rather than asserted.

### Guarded
- Cost/selectivity arithmetic (cardinality-driven driver choice,
  hash-versus-loop) remains the crate's named frontier — now with
  probe data attached. Gate: `qa/opt-plans.sh` 58 → 66 checks across
  two databases; 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 4: equivalence classes

### Converted
- **The reordering slice 3 refused.** Every equi-join predicate
  feeds an EQUIVALENCE CLASS — `D.Z = B.UID` and `A.ID = B.UID` put
  A.ID, B.UID and D.Z in one class — and a stream is reachable when
  it has an index on a column of a class it SHARES WITH AN
  ALREADY-PLACED stream. The engine tries drivers in SQL order and
  keeps the rest in SQL order, which is exactly why an unindexable
  link ends up DRIVING: no arrangement starting anywhere else
  completes. Four probed shapes, all four now planned identically.
- **The order transfers through the class too**: `ORDER BY B.UID`
  navigates A's index on A.ID, because the class proves them equal.
- **One planner for all inner joins.** The two-stream swap turned
  out to be the same rule with n = 2, so plan_join now delegates to
  the general planner and keeps only what is genuinely its own: the
  HASH fallback (the general planner's "no arrangement" answer) and
  the OUTER-join case, whose preserved side cannot be reordered.
- Type families gate CLASS MEMBERSHIP now, not just the two-stream
  key: an equality across families proves nothing an index can use,
  so the VARCHAR = INTEGER join still hashes.

### Guarded
- Outer joins in chains, unions, subqueries, cost/selectivity.
  Gate: `qa/opt-plans.sh` 54 → 58 checks (the slice-3 refusal became
  five checks); 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 3: compound indexes and three-stream chains

### Converted
- **Compound-index matching, by the LEADING-SEGMENT rule**: an
  `(X, Y)` index serves a predicate on X (alone or with anything
  else) but NOT one on Y alone — probed, and the same prefix rule
  governs navigation: `ORDER BY X` and `ORDER BY X, Y` both ride
  the index, while `ORDER BY X, Z` and `ORDER BY Y` sort. Multi-
  column ORDER BY is therefore no longer refused outright — it is
  navigable exactly when it is an index PREFIX with matching
  directions.
- **Chains of three or more streams**: every stream after the first
  reaches its rows through an index on ITS side of ITS OWN ON
  clause, the driver keeping its filter/order access.

### Guarded — with the reason named
- The engine REORDERS a chain whose link is unindexed by deriving a
  new equality through an EQUIVALENCE CLASS (`D.Z = B.UID` and
  `A.ID = B.UID` give `D.Z = A.ID`, and it drove from D). This
  slice refuses that shape rather than guessing at a derivation it
  has not converted — the gate pins the refusal beside the engine's
  plan so the frontier is documented rather than implied. Outer
  joins inside chains likewise. Gate: `qa/opt-plans.sh` 42 → 54
  checks; 281 workspace tests.

## 2026-07-29 — fire-crab-opt slice 2: join plans, the swap, and the hash

### Converted
- **Two-stream join plans** — `PLAN JOIN (<driver>, <inner> INDEX
  (...))`, streams named by their ALIAS when the query gives one.
  The decision the engine makes and this slice now makes: the inner
  stream must reach its rows through the join key's index, so the
  optimizer **SWAPS the SQL order** when only the FIRST stream's key
  is indexed (`T A JOIN U B ON A.ID = B.UA` plans as
  `JOIN ("B" NATURAL, "A" INDEX (IDX_T_ID))`).
- **The hash fallback** (FB5+): when NEITHER key is indexed the
  engine hashes — `PLAN HASH ("A" NATURAL, "B" NATURAL)` — but an
  OUTER join keeps its nested loop, because the preserved side must
  drive and cannot be swapped away. Both probed, both converted.
- **Type families gate index use**: a `VARCHAR = INTEGER` join
  hashes even though one side is indexed. The bug this caught in
  passing is worth the note: catalog `RDB$FIELD_TYPE` codes and ODS
  DESCRIPTOR dtypes are DIFFERENT NUMBERINGS (37 means VARCHAR in
  one and nothing in the other), and mixing them made a VARCHAR look
  numeric.
- **The driving stream keeps its own access**: a WHERE filter gives
  it INDEX, a navigable ORDER BY gives it ORDER (and cancels the
  SORT), else NATURAL. A conjunct with BOTH sides qualified is the
  JOIN KEY, not a filter — the comma-join form carries its join
  predicate in the WHERE.

### Guarded
- Three-plus-stream chains, ORDER BY on the non-driving stream
  (which the engine answers through equivalence-class reasoning),
  unions and subqueries. Gate: `qa/opt-plans.sh` 31 → 42 checks;
  280 workspace tests.

## 2026-07-29 — fire-crab-opt slice 1: the optimizer's access paths, and oracle number five

### Converted
- **A NEW CRATE for the optimizer** — and with it, ORACLE NUMBER
  FIVE. `SET PLANONLY ON` makes the engine PREPARE a statement and
  print the plan it chose, without executing anything: a complete,
  textual, side-effect-free statement of the optimizer's decision.
  `fcopt plan <db> "<sql>"` prints the same line for the same
  statement, and the gate diffs them.
- **The rules, every one probe-found**: NATURAL when nothing is
  index-matchable — including the OR law (one unmatchable branch
  spoils the whole clause, while an AND keeps its matchable half);
  INDEX (a, b, ...) in INDEX-ID order for matchable conjuncts
  (`=`, ranges, BETWEEN, IS NULL, STARTING WITH, prefix LIKE — but
  not `<>`, IS NOT NULL or a leading-wildcard LIKE); ORDER \<idx\>
  — navigation instead of a sort — only when the ORDER BY column's
  index DIRECTION MATCHES (the engine took the descending twin for
  DESC and fell to a sort when none existed) and any predicate
  rides that same index; SORT (...) wrapping otherwise. The select
  list provably does not influence the plan.
- One parse law the gate taught immediately: **BETWEEN's `AND` is
  not a conjunction** — the naive split cut a predicate in half.

### Guarded
- Joins, unions, subqueries, multi-table FROMs, multi-column ORDER
  BY, compound-index matching — and COST/SELECTIVITY arithmetic
  explicitly: where the engine's choice depends on statistics
  rather than structure, this slice refuses rather than guesses.
  Gate: `qa/opt-plans.sh` (31 checks); 4 unit tests; 280 workspace
  tests.

## 2026-07-29 — fire-crab-exe slice 16: blr_recurse — the executor runs the recursions

### Converted
- **`blr_recurse`**, one slice after the compiler learned to emit
  it: the context, the secondary recursive-context byte, the ANCHOR
  branch (a real rse + map) and the STREAM-LESS recursive branch
  whose boolean and map read the recursion's own output by fid.
- **The fixpoint**: the anchor seeds the output, then each wave's
  rows are bound at the recursion's own context and fed through the
  recursive branch, breadth-first, until a wave yields nothing —
  with the engine's depth cap (1024) as an ERROR rather than a
  hang. Multi-column recursions work by construction (the maps are
  positional), and the recursion tower's framing law had to be
  learned the hard way: it is TWO rses deep and the inner one
  DOES close with its own end, unlike the union and window towers.
- **Over the wire**: recursive procedures now serve BLR-first —
  `SELECT * FROM <recursive proc>` and a multi-column recursion
  both node-verified against the engine (the source interpreter
  never learned WITH RECURSIVE at all).

### Guarded
- Gates: `qa/exe-run-blr.sh` 111 → 115, `qa/serve-real-exeproc.sh`
  10 → 12; psql 55, nofallback 54; 276 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 47: multi-column recursive ctes

### Converted
- **Multi-column recursive ctes** (flip seventy-one — the slice-45
  refusal): per-column anchor and recursive item lists, the outer
  select reading each column's fid, and column references
  resolving to their DECLARED POSITION in the cte's list rather
  than a fixed slot.
- **The unification law, refined by the probe: it is PER COLUMN.**
  A two-column recursion where one column steps (`N.ID + 1`) and
  the other rides plain (`N.AMT`) stores `cast(int64)` on the FIRST
  anchor item only — the sibling stays bare, both inside one map.
  Four appearances now (CASE, unions, single-column recursion, and
  here), each narrowing the rule: the promotion belongs to the
  COLUMN whose own branches disagree, not to the union.

### Guarded
- Outer ORDER BY over a recursion, undeclared cte columns. Gates:
  proc 274 → 278 (mixed stepping columns and a no-arithmetic
  two-column recursion pinned), view 128, exe 111, trig 48, field
  39; 74 dsql tests; 396 pins; 276 workspace tests.

## 2026-07-29 — fire-crab-blb slice 4: stream blobs, and a one-way differential

### Converted
- **Stream-blob creation** (`create_stream_blob`, `fcblb write ...
  0`): content rides RAW — no `[u16 length]` frames at all — with
  `rhd_stream_blob` set, `blh_count` 1 and `blh_max_segment` the
  whole length (a stream blob is "one segment" by bookkeeping).
  Level selection, page chunking and the record's bid are the
  shared path; only the framing differs.
- **A one-way differential, named as such.** Stream blobs arrive
  from the API's BPB (`isc_bpb_type_stream`), never from SQL — the
  probe confirmed the engine stores an SQL literal blob SEGMENTED
  (stream flag 0), so the engine cannot be made to WRITE one
  through isql. The gate therefore runs the direction that exists:
  fire-crab writes, the ENGINE reads every byte back (25 B, 8500 B
  and 120 KB, level 0 and level 1) — and the unframed content must
  not be mistaken for frames, which a segmented reader would turn
  into garbage. gfix and gbak still bless the file.

### Guarded
- The BPB parameter surface (requested type/charset
  transliteration) remains the crate's only named item. Gate:
  `qa/blb-levels.sh` 17 → 20 checks; blb-gc 5; 274 workspace tests.

## 2026-07-29 — fire-crab-exe slice 15: GEN_ID, with the persistence boundary drawn

### Converted
- **GEN_ID / NEXT VALUE FOR** (`blr_gen_id` 101 with a step
  expression, `blr_gen_id2` 210 with the sequence's own increment
  from RDB$GENERATORS): read-and-advance through an IN-MEMORY
  overlay — consecutive reads in one execution see each other's
  steps, the file is never written. The persistence boundary is
  drawn explicitly, in three places: fcexe documents itself as a
  non-persisting harness; the parsed Request carries a
  `uses_generators` flag; and the WIRE server excludes
  generator-writing requests from the BLR path, letting its
  persisting interpreter (the GenIdIncrement machinery) serve them
  — correctness over adoption.
- **The restart-paired gate protocol**: a generator-advancing body
  cannot use the standard check (each side's run steps the
  sequence), so the gate RESTARTS the sequence before each side —
  engine rows, restart, fcexe rows — and both count 2, 4, 6, 8, 10
  in lockstep.

### Guarded
- Gate: `qa/exe-run-blr.sh` → 111 checks (the GEN_ID refusal
  flipped to two restart-paired checks); serve-real exeproc 10,
  psql 55, genstep 11 intact; 274 workspace tests.

## 2026-07-29 — fire-crab-lck slice 3: knock events and lock timeouts

### Converted
- **Blocking-AST knocks as events**: a freshly parked request posts
  a knock to every owner standing in its way — deduplicated per
  (owner, lock), carrying the wanted mode — and `take_knocks`
  drains an owner's queue. The classic protocol is unit-pinned:
  holder reads the knock, downgrades, the waiter grants on the
  regrant sweep. The decision half of the AST is now consumable
  data; delivery remains transport.
- **Lock timeouts**: pending requests may carry a DEADLINE tick
  (`enqueue_deadline`), and `expire(now)` brings every overdue
  parked request down — leaving no trace, like a NO WAIT reject —
  returning who timed out where. The live differential is gate
  phase 5: A holds PW, B waits with `SET TRANSACTION WAIT LOCK
  TIMEOUT 2`, and the ENGINE expires the wait with "lock time-out
  on wait transaction" while A still holds — the same expiry the
  crate's unit test pins, deadline-less waiters unaffected.

### Guarded
- Series semantics and the cross-process dump differential remain.
  Gate: 5 phases; 13 unit tests; 272 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 46: the unification law converted, PLAN ORDER

### Converted
- **Union type-unification** (flip sixty-nine — the law the gate
  found in slice 44, converted): one arithmetic branch (`+`/`-`/`*`
  with an integer literal) types the union int64 — dialect-3
  integer arithmetic is width-independent, so the typing is
  CATALOG-FREE — and every PLAIN branch wraps in `cast(int64)`.
  The slice-44 named refusal flipped to a live check; a three-way
  union mixing `+ 5`, a plain column and `- 1` (with a parameter in
  a branch WHERE) pins the general shape.
- **PLAN (tbl ORDER idx)** (flip seventy): `blr_navigational`
  (0x8F) + ONE counted index name — no count byte, unlike
  blr_indices — and a probe-found engine rule: the plan is only
  legal beside a MATCHING ORDER BY ("index cannot be used in the
  specified plan" without it).

### Guarded
- DIVISION in union branches (scale-rule promotion), field-by-field
  branch arithmetic. Gates: proc 271 → 274, view 128, exe 110, trig
  48, field 39; 72 dsql tests; 395 pins; 272 workspace tests.

## 2026-07-29 — fire-crab-blb slice 3: blob GC and the blob crash workload

### Converted
- **The blob GC differential** (`qa/blb-gc.sh`): fcblb writes a
  level-0 and three level-1 blobs with their records; the ENGINE
  deletes two rows, commits, and runs its own garbage collector
  (`gfix -sweep`) over the fire-crab-written file. The dead rows'
  blobs die with them: validation silent, the survivors read in
  full through BOTH readers — and the TEETH count PIP free BITS,
  which rose by exactly the dead blobs' fifty pages. (A sweep that
  "worked" but freed nothing would pass a validity-only check; and
  the pip_used counter proved unreliable for this — the BITMAP is
  the allocation truth.)
- **The blob crash workload** (`fccch crash-matrix ... blob`): rows
  referencing fresh level-1 blobs written through fire-crab-blb's
  own path. Fourteen writes — header, NINE blob pages, data, pip,
  pointer, tip — with the blob-before-data edge finally carrying
  real weight: a record's bid never names a blob whose pages are
  not on disk. All fifteen careful prefixes engine-valid; the
  naive order breaks at twelve.

### Guarded
- Stream-blob creation and the bpb surface remain named. Crash
  harness now FOUR workloads; 270 workspace tests.

## 2026-07-29 — fire-crab-exe slice 14: EXECUTE PROCEDURE adopted, runtime errors surfaced

### Converted
- **EXECUTE PROCEDURE, BLR-first** — at BOTH wire sites: the
  OP_EXECUTE arm isql drives and the op_execute2 arm the OO clients
  drive (the second was found the honest way: the first gate run's
  node call died on it). Semantics are the engine's: a selectable
  body answers its FIRST suspended row, a non-suspending one its
  final output state — the executor runs the whole (read-only) body
  and the wire layer picks the row, observationally identical.
- **Runtime errors surface as SQL errors.** The BLR path now
  distinguishes three outcomes: OUTSIDE the surface (silent
  fallback to the interpreter, as before), ROWS, and RUNTIME error
  — divide-by-zero and overflow ship the engine's own vectors to
  the client instead of falling back. A body that fails must FAIL:
  an interpreter that answered rows there would mask the engine's
  behavior. The gate holds `SELECT * FROM PW8` (a divide-by-zero
  body) erroring on BOTH sides.
- Gate helper fix with a lesson attached: node-firebird returns an
  OBJECT for EXECUTE PROCEDURE, an array for SELECT — the gate's
  row printer assumed arrays and manufactured CONN_ERR.

### Guarded
- Gate: `qa/serve-real-exeproc.sh` 7 → 10 checks; regressions psql
  55, modifiers 41, nofallback 54; 270 workspace tests.

## 2026-07-29 — fire-crab-exe slice 13: the wire adoption

### Converted
- **The two paths meet.** `SELECT FROM <procedure>` over the wire
  now serves BLR-FIRST: the server reads the stored
  RDB$PROCEDURE_BLR — the same bytes fcdsql matches byte-for-byte
  and the engine itself executes — parses it in fire-crab-exe's
  surface, and takes the suspended rows straight from the
  message-1 sends. Anything outside the surface falls back to the
  source interpreter unchanged.
- **The payoff**: procedure bodies the interpreter NEVER learned
  now serve over the wire — running-SUM windows, RANK/DENSE_RANK,
  LAG, ROWS BETWEEN frames, correlated EXISTS, FULL JOINs,
  parameterized procedures — each answer node-fetched from fcwire
  and equal to the engine running the same procedure
  (`qa/serve-real-exeproc.sh`, 7 checks, green first run).
- exe's `execute` split into a value-typed core
  (`bind_and_execute` — what the server binds) and the CLI's
  string-parsing wrapper; `procedure_blr` moved to the library.

### Guarded
- EXECUTE PROCEDURE (ProcInvoke) stays on the interpreter — its
  first-suspended-row semantics ride a later slice. Regressions:
  psql 55, modifiers 41, nofallback 54, selectexpr 88, exe gate
  110; 270 workspace tests.

## 2026-07-29 — fire-crab-lck slice 2: teardown, lock data, the blocking set

### Converted
- **Owner teardown** (`purge_owner`): the engine's purge on detach —
  every granted and pending request comes down, each affected lock
  regranting FIFO. Live-verified (gate phase 4): A holds PW, B's
  WAIT reservation parks, A DETACHES WITHOUT COMMITTING — and B
  proceeds the moment the engine's purge fires, the same
  release-all-and-regrant the crate's unit test pins.
- **Lock data words** (`write_data`/`read_data`): `lbl_data` — the
  writer must HOLD the lock, anyone reads, an absent lock reads
  zero. The probe caught the mechanism live: a transaction lock
  carrying `Data: 134` in fb_lock_print on this very box.
- **The blocking set** (`blockers`): the owners whose granted,
  incompatible requests park a waiter — exactly who would receive
  the blocking AST; the decision is now data, the delivery stays
  transport.
- **A SuperServer finding re-scoped the roadmap**: fb_lock_print
  shows NO relation locks — relation arbitration is in-process, the
  shared table carries only cross-process series. The structural
  dump differential is bounded accordingly; reservations remain the
  relation-lock oracle.

### Guarded
- AST delivery, timeouts, series semantics. Gate grew phase 4
  (teardown-unblock); 11 unit tests; 267 workspace tests.

## 2026-07-29 — fire-crab-cch slice 2: the matrix learns indexes and deletes

### Converted
- **The indexed workload**: the crash matrix's inserts now maintain
  T's B-tree per row (the same `btw::insert_index_entry` path the
  wire server drives), so btree pages join the careful-write
  ensemble. The slice-1 matrix had ordered btree-after-data by
  PAGE-NUMBER LUCK; the edge is now law — an index entry names a
  record NUMBER, so the data page holding the record precedes the
  btree page holding the entry. Order: header → data → pip →
  pointer → btree → tip, every prefix engine-valid.
- **The delete workload**: version-chain stubs over the same pages —
  header → data → tip, three writes, and the TIP-last law shows its
  other face: every interrupted prefix answers the ORIGINAL rows,
  the full sequence zero, and the naive order makes rows VANISH
  EARLY (a premature commit flip). The file is never wrong, only
  ever behind — in both directions.
- **The gate caught a workload invalidity**: with an index on the
  table, the plain (un-indexed) insert workload's own END state is
  inconsistent — gfix flagged missing index entries at the full
  prefix. The gate now runs two scratch databases, and the finding
  is documented in it: an insert that skips index maintenance is
  not a valid operation on an indexed table.

### Guarded
- Page DEALLOCATION (the pip-freed-last chain) waits for a
  fire-crab operation that frees pages (sweep). Gate:
  `qa/cch-crash-harness.sh` — 3 workloads × (all-prefixes-valid +
  naive teeth); 267 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 45: recursive ctes

### Converted
- **WITH RECURSIVE** (flip sixty-eight — the transcript banked in
  slice 42, cashed at last): `blr_recurse` carries the context, the
  SECONDARY recursive-context byte (GEN_stuff_context emits both
  when CTX_recursive — the secondary claims the slot BELOW the
  recursion's), and the branch count; the ANCHOR branch is a real
  rse + map with the cte name riding the relation2 alias exactly
  like every inlined cte; the RECURSIVE branch is an rse with ZERO
  streams whose boolean and map read `fid(recurse ctx, 0)`; no
  terminator of its own — the wrapper rse's END closes it. Context
  law: secondary, recursion, anchor claim consecutive slots.
- **The unification law, third appearance**: a `+ 1` recursive item
  types int64 (dialect-3 integer ADD — width-independent, so
  CATALOG-FREE), and the anchor's bare field wraps in
  `cast(int64)`; the no-arithmetic recursion carries no casts. Both
  shapes pinned. Multiplication refuses — its promotion rule
  depends on operand rank.

### Guarded
- Multi-column recursive ctes, a plain cte beside a recursive one,
  outer WHERE over the recursion, `*` in the recursive item. Gate:
  `qa/dsql-proc-blr.sh` 267 → 271 (the slice-42 named refusal
  flipped); 70 dsql tests; 393 pins; 267 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 44: unions as quantified subqueries

### Converted
- **UNION ALL as a quantified subquery's stream** (flip sixty-seven
  — the banked transcript cashed): the union claims the subquery's
  reserved context slot (the slice-38 lookahead law in subquery
  clothing — the reservation must land before any branch stream
  numbers), branches carry rse + positional map at the following
  slots, and the comparison reads `fid(union ctx, 0)`. NOT IN
  negates to ansi_all + neq as everywhere; parameters ride branch
  WHEREs; three-branch unions hold.
- **A law the gate's own battery found**: expression branch items
  UNIFY the union's type — a `* 2` branch promotes to int64 and the
  engine wraps every plain branch in `cast(int64, ...)` — the
  CASE-unification law in union clothing. Named as a refusal with
  the transcript in the gate comment; the same catalog-typing
  boundary as NULLIF applies to FIELD-typed branches, so the
  convertible slice is literal/param-typed unification.

### Guarded
- The DISTINCT union form, EXISTS over a union, derived branches,
  expression branch items (above). Gate: `qa/dsql-proc-blr.sh`
  262 → 267; 68 dsql tests; 391 pins; 265 workspace tests.

## 2026-07-29 — fire-crab-dsql slice 43: the executor's frontier list, cleared

### Converted
- Five flips (sixty-two through sixty-six), every one a shape the
  EXECUTOR's two-arrow gate had named while its compiler half was
  missing: **STARTING [WITH]** (`blr_starting`; NOT keeps a real
  blr_not, like LIKE), **FIRST/SKIP (:param)** (a PARENTHESIZED
  parameter compiles to the bare parameter2 — and `FIRST :P` is a
  syntax error in the ENGINE too: the old refusal had been correct
  all along, only the parenthesized spelling was missing),
  **DISTINCT over a derived table** (the project's field translates
  through the derived list — one guard term fell), **FOR-less
  SUBSTRING** (the engine fills the length with INT MAX — probed
  literal 0x7FFFFFFF), and **expression select items in quantified
  subqueries** (the comparand wraps in `blr_derived_expr` over the
  subquery stream — the two-phase span parse, again).
- The 2-arg SUBSTRING flip reached the VIEW surface through the
  shared parser: the view gate's old refusal now compiles, and
  RDB$VIEW_BLR confirmed the same INT-MAX byte live.
- Every re-enabled EXECUTOR check went green on the first run —
  the frontier list worked exactly as designed: gate names gap,
  compiler slice clears it, executor check comes back by itself.

### Guarded
- Union-in-subquery stays named WITH its transcript (the wrapper's
  stream is a blr_union; the comparison reads fid(union ctx, 0)).
  General limit expressions, expression items in SCALAR subselects.
  NULLIF/IIF over field branches is documented as a MODEL BOUNDARY,
  not a gap: the unifying cast's target needs the field's catalog
  type, and this compiler is catalog-free by design. Gates:
  qa/dsql-proc-blr.sh 253 → 262, view 128 (one refusal flipped to
  a live check), exe 105 → 110; 66 dsql tests; 390 unit pins; 263
  workspace tests.

## 2026-07-29 — fire-crab-exe slice 12: the string functions

### Converted
- **UPPER / LOWER** (`blr_upcase`/`blr_lowcase`, unary),
  **CHAR_LENGTH / OCTET_LENGTH** (`blr_strlen` + the length-type
  byte the dsql side probed years of slices ago, read back),
  **SUBSTRING** (`blr_substring` — the 0-based start arriving as
  the reference compiler's unfolded `subtract(from, 1)`, exactly
  the tree the playbook says to match; negative start or length is
  a runtime error, past-the-end is empty, NULL propagates through
  all three operands) and **TRIM** (the where byte: both / leading
  / trailing over spaces).

### Guarded
- TRIM-by-character (spec 1) refuses; GEN_ID stays named — a
  SELECT that WRITES, against fcexe's read-only file model, is a
  design decision rather than a parse arm. One frontier swap:
  two-argument SUBSTRING (FROM without FOR) is a dsql-side gap.
  Gate: 98 → 105 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 11: simple CASE, cross-family casts, RANGE value bounds

### Converted
- **RANGE value bounds**: key arithmetic over the single sort key —
  the frame is the contiguous run of rows whose key lies within
  cur∓v along the traversal's own axis (PRECEDING subtracts along
  it, FOLLOWING adds, DESC flips the sign). A NULL current key
  frames its peer group alone, and NULL keys never qualify for a
  value edge (their comparisons are UNKNOWN). Ascending, DESC and
  CURRENT-to-FOLLOWING forms all hold against the engine.
- **Cross-family casts**: int→text renders plain decimal; text→int
  parses, a bad string raising the engine's conversion error. Width
  and range violations error as before — never silent.
- **The simple CASE** (`blr_decode`): an operand, counted condition
  values, counted results with the extra one as ELSE; a NULL
  operand matches nothing and takes the else (or NULL without one).

### Guarded
- GEN_ID and the built-in string functions (UPPER et al) are the
  new named frontier. Gate: 92 → 98 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 10: frame extents

### Converted
- **The v4 framed window** (`blr_window_win`): subcoded clauses —
  partition (the v3 layout under a tag), order, map, extent unit
  (RANGE 0 / ROWS 1), frame bounds (preceding 0 / following 1 /
  current row 2, values optional) — closing with its OWN `blr_end`
  where the v3 window leans on the rse's; a single bound implies
  CURRENT ROW as the second, the dsql-probed law read back. Both
  generations mix freely in one statement, and parse through one
  shared map/sort-key reader.
- **Execution**: every fold and every valued function now runs over
  a per-row FRAME SPAN — the default reproduces slice 8's peer
  semantics exactly (no order: the partition; order: unbounded
  through the current peers), ROWS frames offset by row position,
  and RANGE keeps its value-less peer forms. Sliding sums (`ROWS
  BETWEEN 1 PRECEDING AND CURRENT ROW` walking through a NULL),
  lookahead sums, CURRENT-to-UNBOUNDED tails, a framed LAST_VALUE
  and an explicit RANGE UNBOUNDED..CURRENT all hold against the
  engine row for row.

### Guarded
- RANGE frames with VALUE bounds (the key-arithmetic form) and
  cross-family casts remain named. Gate: 86 → 92 checks. 261
  workspace tests.

## 2026-07-29 — fire-crab-exe slice 9: conditionals and the valued window functions

### Converted
- **CAST** (`blr_cast` + a dsc): integer range checks ERROR rather
  than wrap, text width overflow is the engine's string-truncation
  error rather than a silent cut, NULL passes through; cross-family
  conversions refuse by name. **COALESCE** takes the first
  non-NULL. **blr_value_if** — the conditional the searched CASE
  compiles to under its unifying cast — where UNKNOWN takes the
  else branch.
- **The valued window functions**: LAG/LEAD (the row an offset
  ago/ahead in partition order, the third argument when the
  partition runs out — the canonicalized three-argument form the
  dsql side probed, read back), FIRST_VALUE, LAST_VALUE — the
  default RANGE frame's famous trap, engine-verified: it answers
  the CURRENT PEER GROUP's last value, not the partition's — and
  NTH_VALUE (the nth only if the frame reaches it).

### Guarded
- Frame extents (blr_window_win) and cross-family casts (int↔text)
  remain named. Two frontier swaps: NULLIF and IIF over FIELD
  branches are dsql-side guards (the unify-typing law needs the
  catalog). Gate: 78 → 86 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 8: windows — the last named refusal falls

### Converted
- **Windows** (`blr_window`): a window is an aggregate that KEEPS
  its rows — every source row survives, each window's context
  binding a slot-row of computed values the body reads by fid.
  Per window (`blr_partition_by`): whole-partition aggregates when
  the window has no ORDER; RUNNING aggregates over the default
  RANGE frame when it does — peers included, rows with equal sort
  keys sharing the value (the gate's running SUM walks straight
  through a NULL, which contributes nothing, exactly as the
  engine's does); and ROW_NUMBER / RANK / DENSE_RANK
  (`blr_agg_function`, counted name) by peer-group position. The
  remap fids after the partition keys are bookkeeping and parse
  away. Windows process in declaration order, each re-sorting the
  row set — the LAST window's order is the emission order, the
  engine's sort-per-window pipeline, and the multi-window check
  (a running SUM beside a partition COUNT) held.
- Like the union, the window consumes the rse's closing end itself
  — no clauses follow a window in this wrapper.

### Guarded
- Frame extents (`blr_window_win` — the v4 subcoded form) and
  CAST/CASE value verbs are the new frontier, named by fresh
  refusals. Gate: 70 → 78 checks. 261 workspace tests. With this,
  every refusal the executor's slice 1 declared has been flipped
  by a later slice — the roadmap ate itself in eight steps.

## 2026-07-29 — fire-crab-exe slice 7: subquery predicates, scalar subselects

### Converted
- **EXISTS / SINGULAR**: `blr_any` / `blr_unique` over one rse.
  Correlation cost NOTHING: the outer row's frames are already on
  the evaluation stack when the inner scan runs, so `U.UID = T.ID`
  resolves through the ordinary frame search - the design dividend
  of the binding model, third time paying.
- **Quantified comparisons**: `blr_ansi_any` / `blr_ansi_all` over
  a wrapper rse whose single STREAM is the subquery (the
  derived-table arm parses it) and whose boolean is the comparison.
  ANY: true beats unknown beats false; ALL the mirror; the empty
  set answers false/true. NOT IN's famous trap holds: one NULL in
  the subquery poisons every row to UNKNOWN, and the gate's
  `ID NOT IN (SELECT AMT FROM T)` answers EMPTY exactly as the
  engine does - the wrong-in-most-hand-rolled-executors case.
- **Scalar subselects**: `blr_via(singular-rse, value, else)` - one
  row binds and the value evaluates, none and the else (NULL) does,
  a second row is sing_err. `blr_derived_expr` (191) is a
  bookkeeping wrapper - stream ids, then the expression - parsing
  straight through.

### Guarded
- Windows are the last named refusal. Two checks swapped at the
  frontier (expression subquery items, union-in-subquery - both
  dsql-side guards). Gate: 63 → 70 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 6: UNION and the remaining simple booleans

### Converted
- **UNION**: `blr_union` standing in the stream slot — its own
  context, per-branch rse + positional map, branches concatenating
  in order onto slot-indexed union frames. Two byte-level laws:
  the opcode is 76 — `blr_eoc`'s — disambiguated purely by
  POSITION; and a union has NO terminator of its own — the branch
  count bounds it, and the next `blr_end` belongs to the OUTER rse
  (the first parse consumed one end too many and refused its own
  probe to learn this). The DISTINCT form needed nothing: it is
  the outer rse's `blr_project` over the union's fids, and the
  existing project machinery dedupes union frames unchanged.
- **The remaining simple booleans**: IN-list (`blr_in_list`,
  u16-counted, three-valued — no match beside a NULL comparand is
  UNKNOWN, not false), BETWEEN (3VL on both bounds), LIKE
  (character-based backtracking — the porting playbook's own
  pseudocode, executable at last) and STARTING WITH. `blr_text2`
  literals (charset-carrying) decode alongside.

### Guarded
- Windows and subquery predicates (EXISTS et al) remain named. One
  check swapped: STARTING WITH executes but fcdsql does not compile
  it yet — another cross-crate frontier the two-arrow gate named.
  Gate: 54 → 63 checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 5: join chains, index retrievals

### Converted
- **Join chains**: `blr_rs_stream` nests as a SOURCE of the outer
  rs_stream — the left-nested shape the dsql crate emits. Join
  sources went recursive (`JoinSource::Rel | Nested`), a nested
  join's bindings splice whole into the outer product, and an outer
  join over a chain pads EVERY context the nested side binds. A
  mixed chain — `T JOIN T LEFT JOIN U` — holds against the engine.
- **Index retrievals**: `PLAN (T INDEX (names))` executes as the
  real BitmapTableScan. The B-tree walk (`ods::walk_index_leaves`)
  yields record numbers; records fetch by number; and VISIBILITY IS
  DECIDED ON THE RECORD ITSELF — the index only says where records
  might be, the paper's own law about Firebird's index
  architecture, now executable. The index name resolves through
  RDB$INDICES to its 0-based index-root slot (the catalog's
  RDB$INDEX_ID is 1-based). `PLAN (T NATURAL)` runs the plain scan.

### Guarded
- Windows and UNION remain named refusals. Gate: 49 → 54 checks
  (three-stream chains, chain + WHERE, mixed LEFT chain, PLAN
  INDEX with a parameter, PLAN INDEX + ORDER, PLAN NATURAL). 261
  workspace tests.

## 2026-07-29 — fire-crab-exe slice 4: outer joins, derived tables

### Converted
- **Outer joins**: `blr_join_type` (80) with operands left/right/
  full (1/2/3, probed after a wrong first guess — the numbers live
  in blr.h, not intuition). A preserved-side row with no ON match
  emits once with the other side's frame an EMPTY row — and the
  binding model makes null-padding free: a field read off an empty
  frame answers NULL through the ordinary lookup, no special record
  needed. The anti-join (`WHERE B.UA IS NULL` over the padded side)
  and `COUNT(*)` over it hold against the engine.
- **Derived tables**: a nested rse standing in the stream slot. Its
  bindings pass straight through — the inner stream's context IS
  what outer references name — so the feature is one parser arm and
  ZERO executor code. Outer WHERE, ORDER BY and aggregates over
  derived tables compose as they always did.

### Guarded
- Windows, 3+-stream join chains (nested rs_stream), outer joins
  over more than two streams, explicit PLANs (blr_plan awaits the
  index-retrieval slice). One check swapped when phase A refused:
  DISTINCT-over-derived is a dsql-side guard, so its byte-pin
  cannot hold until the dsql crate flips it — the gate's two-arrow
  design surfaces cross-crate frontiers exactly. Gate: 41 → 49
  checks. 261 workspace tests.

## 2026-07-29 — fire-crab-exe slice 3: expressions, joins, DISTINCT

### Converted
- **Value expressions**: blr_add / subtract / multiply / divide /
  negate / concatenate — NULL propagates through every verb, integer
  division truncates toward zero, and divide-by-zero and overflow
  are runtime ERRORS, not wrong numbers.
- **Inner joins**: `blr_rs_stream` — the NestedLoopJoin — with
  aliased `blr_relation2` streams and the ON boolean evaluated over
  the joined frames. The executor's core generalized from
  single-frame rows to BINDINGS (one frame per joined stream), so
  the whole tower — filters, DISTINCT, sorts, aggregates, FIRST/
  SKIP — composes over joins with no per-feature work: COUNT(*)
  over a join ran the moment joins parsed.
- **DISTINCT**: `blr_project` as the rse clause it is — sort-based
  unique over the projected values, NULL grouping WITH NULL; the
  engine's null-first output order held unprompted (the nulls-low
  law reaching the project sort).

### Guarded
- LEFT/outer joins (blr_join_type refuses in the join clause loop),
  derived tables, windows. Gate: `qa/exe-run-blr.sh` 32 → 41
  checks (three refusals flipped; join+WHERE, aggregate-over-join,
  DISTINCT+ORDER, expression params). 262 workspace tests.

## 2026-07-29 — fire-crab-exe slice 2: parameters, aggregates, singular, FIRST/SKIP

### Converted
- **Three of slice 1's own refusals flipped** by the same gate
  machinery that installed them. INPUT PARAMETERS: message 0 binds
  up front from fcexe's CLI arguments (typed by the message slots),
  `blr_receive` is transparent to the synchronous looper, and
  `blr_parameter2` joins the value expressions. AGGREGATES:
  `blr_aggregate` as a stream with its own context — group-by keys
  fold rows with NULL grouping WITH NULL (set semantics), the map's
  verbs (count / count2 / total / average / min / max) carry the
  engine's empty-set rules: COUNT of nothing is 0 but SUM/AVG/MIN/
  MAX are NULL, a keyless aggregate of an empty set still yields ONE
  row, integer AVG truncates; outputs read `blr_fid`, and HAVING is
  just the outer rse's boolean evaluated over the aggregate frame.
  SINGULAR selects: a second row is a runtime ERROR (the engine's
  sing_err), never a truncation. FIRST/SKIP: rse clauses executed in
  the tower's order — sort, then skip, then first.
- The rse parser split into entry/body so `blr_singular` wraps and
  aggregate sources nest without double-consuming tags; frames now
  carry an optional relation (aggregate frames are slot-indexed,
  read by fid — a bare field over one refuses).

### Guarded
- Joins, value expressions, DISTINCT (blr_project) and windows
  remain named refusals. Gate: `qa/exe-run-blr.sh` grew 20 → 32
  checks (13 fresh incl. three flips; text CLI arguments quote on
  the SQL side — the engine parsed a bare `bb` as a column and
  fcexe was right first). 5 unit tests; 262 workspace tests.

## 2026-07-29 — fire-crab-blb slice 2: level-2 creation + wire adoption

### Converted
- **Level-2 blob creation.** The pointer-page layout was probed off
  the engine's own 36 MB level-2 blob before a byte was written:
  data pages keep the blob-wide lead page and their GLOBAL sequence;
  pointer pages are type 8 with `blp_pointers`, carry the blob-wide
  lead, SEQUENCE 0 (the engine writes 0 on every pointer page), and
  a `blp_length` counting the entry BYTES of their u32 data-page
  vectors; `blh_max_sequence` still counts data pages (last
  sequence). The gate writes an 18 MB blob through this path and
  the engine reads all eighteen million bytes back - gfix silent,
  gbak happy. "Level-3 does not exist" is now an explicit refusal.
- **Wire adoption.** The server's SEVEN blob call sites now read
  through `fire_crab_blb::read_blob_content` - op_open_blob /
  op_get_segment serve level-2 blobs no earlier reader could. Gate
  phase C: node-firebird fetches every fcblb-written blob over the
  wire (the 18 MB level 2 included) and the assembled content
  equals the source files. The pre-existing `qa/serve-real-blob.sh`
  differential stays green on the swapped reader.

### Guarded
- Blob GC, filters, stream creation, temporary blobs (unchanged
  refusals). Gate `qa/blb-levels.sh` grew to 17 checks; serve-real
  blob/show/nofallback regressions green; 260 workspace tests.

## 2026-07-29 — fire-crab-blb slice 1: blob storage, both directions

### Converted
- **A NEW CRATE for `src/jrd/blb.cpp`'s on-disk addressing.** `blh`
  headers and `blp` blob pages as typed codecs — every `ods.h`
  static_assert mirrored as a unit test, so a drifted offset fails
  before it mis-reads a byte. Reading at ALL THREE levels: 0
  (inline), 1 (page vector), 2 (pointer pages) — the gate's 36 MB
  engine-created blob is a genuine level 2, read byte-for-byte
  against the engine's own OCTET_LENGTH / SUBSTRING answers.
  Creation at levels 0 and 1 through fire-crab's own placement
  (`ods::insert_blob_slot` + the now-public `ods::allocate_page`),
  segment framing intact, plus the referencing record's `bid` laid
  into the image — and the ENGINE reads every fcblb-written blob
  back in full, `gfix -v -full -n` finds neither errors nor
  warnings, `gbak` backs the file up.
- **Three probe-settled laws**: `blh_max_sequence` is the LAST page
  sequence, not the count — ods.h's "Number of data pages" comment
  misleads, `blb.cpp:2377`'s `>` test decides, and the engine
  reading one page past a count-valued vector (then declaring the
  file corrupt) is how the law announced itself. `blh_length`
  counts payload with framing excluded (OCTET_LENGTH equals it at
  every level). And `rhd_blob`/`rhd_stream_blob` are 16/32 — a
  first-guess 8 made every real blob "not a blob".
- **Extensive companion documentation**:
  [docs/blob-conversion.md](docs/blob-conversion.md) — placement,
  the three levels, pinned layouts, framings, the probe log, the
  two-direction oracle design, scope table and roadmap.

### Guarded
- Level-2 CREATION (refuses past the level-1 vector ceiling), blob
  GC, blob filters, stream-blob creation, temporary blobs. 8 unit
  tests (offset pins, round-trips, zero-length segments, stream
  truncation, empty blobs, vector termination, ceiling math); gate
  `qa/blb-levels.sh` (15 checks, both directions, levels asserted
  0/0/null/0/1/2); 260 workspace tests.

## 2026-07-29 — fire-crab-lck slice 1: the lock table's policy

### Converted
- **A NEW CRATE for `src/lock/lock.cpp`** — the lock table that
  arbitrates every shared resource: modes (`LCK_none..LCK_EX`,
  values identical), the compatibility matrix (transcribed from
  `lock.cpp:150`), the `lbl_counts` + `lbl_state` single-aggregate
  grant probe (`lock.cpp:2228` — sound because granted sets are
  mutually compatible; the companion doc carries the argument),
  enqueue with WAIT / NO WAIT, convert (tested against everyone
  ELSE's aggregate, `lock.cpp:2535`), dequeue with the FIFO
  `post_pending` regrant, queue fairness (a late compatible arrival
  parks behind a blocked head — no starvation), and the wait-for
  deadlock scan with the scanning request as victim.
- **Two oracles.** The SOURCE pin: `fclck pin-source` re-parses the
  `compatibility[LCK_max][LCK_max]` initializer out of the vendored
  engine and diffs all 49 cells against the crate's constant — the
  transcription itself is under differential test. And the LIVE
  matrix: `SET TRANSACTION RESERVING` maps reservation modes onto
  LCK_SR/SW/PR/PW, so four fifo-held modes probed by four `NO WAIT`
  reservations give 16 engine-arbitrated cells, every one equal to
  `fclck compat` — including the famous SR-beside-PW COMPATIBLE
  (protected write excludes other writers, not MVCC readers). A
  live two-attachment cross-update then draws the engine's own
  SQLSTATE 40001 deadlock — the cycle the crate's scan denies.
- **Extensive companion documentation**:
  [docs/lock-manager-conversion.md](docs/lock-manager-conversion.md)
  — the two layers, the scope table, the matrix's meaning, the
  aggregate-soundness argument, the three verbs, FIFO fairness, the
  deadlock scan, both oracles, the probe log and the roadmap.

### Guarded
- The arena (shared memory, hash chains), blocking-AST delivery,
  lock data words, timeouts and series semantics ride later slices.
  8 unit tests; gate `qa/lck-reserving-matrix.sh` (source pin + 16
  live cells + live deadlock, all green first run — the embedded
  engine refuses a second attachment, so the gate drives the REAL
  server); 252 workspace tests.

## 2026-07-29 — fire-crab-cch slice 1: the careful-write precedence graph

### Converted
- **A NEW CRATE for the mechanism that replaces a write-ahead log.**
  `fire-crab-cch` converts cch.cpp's precedence graph: `CCH_fetch` /
  `CCH_mark`, `CCH_precedence`/`check_precedence` (the referenced
  page reaches disk before the page that references it; an edge that
  would close a cycle is not added — the window page is written
  immediately instead), `write_buffer`'s recursive higher-queue
  drain (what makes the graph load-bearing rather than advisory) and
  `clear_precedence`.
- **The crash-matrix differential**: `fccch crash-matrix` runs a
  relation-growing insert batch through fire-crab's own write path
  (header, TIP, PIP, pointer and data pages all change), flushes
  through the graph, and materializes every crash prefix. The ENGINE
  judges each one: `gfix -v -full -n` — no errors at any careful
  prefix; `isql` — exactly the pre-operation committed rows on every
  partial prefix (the TIP commit flip goes LAST, so the interrupted
  work is simply not there), all 122 on the full one.
- **The teeth**: the naive reverse order breaks at 5 of 8 prefixes —
  wrong-page-type corruption, file-shorter-than-expected read
  failures, and PHANTOM ROWS from the uncommitted insert (a
  readable, validating-adjacent file answering rows that were never
  committed — the class careful writes exist to prevent).
- **A rule the gate itself probed**: the PIP bit goes out AFTER the
  data page it allocates but BEFORE the pointer that names it. The
  draft had PIP last; a pointer-ahead-of-PIP prefix validated with
  page ERRORS. The right side's window shows only a benign orphan
  WARNING — space leaked, data never harmed, the artifact a real
  kill -9 can leave.

### Guarded
- 4 unit tests (chain drain order, cycle fallback, clean pages
  impose no order, prefixes grow the file like a disk); 244
  workspace tests; exe gate 20/20 intact.

## 2026-07-29 — fire-crab-exe slice 1: the BLR request executor

### Converted
- **A NEW CRATE, and the third direction of the same oracle.** The
  dsql crate PRODUCES the engine's bytes; the ods crate READS the
  engine's pages; `fire-crab-exe` now RUNS the bytes against the
  pages — `src/jrd/exe.cpp`'s statement looper over the
  `src/jrd/recsrc/` record sources. `fcexe <db> <proc>` reads
  `RDB$PROCEDURE_BLR` (the blob fcdsql matches byte-for-byte),
  parses the `FOR SELECT ... DO SUSPEND` wrapper — messages,
  INTERLEAVED declares+inits (the law the dsql side probed, read
  back), stall, labels, the for-loop, the twin sends with the EOF
  short — and executes it: FullTableScan (`visible_rows`, the
  VIO_get visibility rule) under FilteredStream (three-valued
  booleans: wide-integer numeric alignment, PAD-SPACE text, Kleene
  AND/OR) under SortedStream (blr_sort; **NULLs sort LOW — first
  ascending, last descending — probed against the live engine, the
  draft had it backwards**).
- **The loop closes**: SQL → (fcdsql, byte-checked at the catalog)
  BLR → (fcexe) rows `==` `SELECT * FROM <proc>` on the C++ engine.
  Gate: `qa/exe-run-blr.sh` — 15 checks each asserting BOTH arrows
  (fcdsql still matches the stored bytes, fcexe's rows match the
  engine's), plus 5 refusals.

### Guarded
- Input parameters (blr_receive), aggregates, joins, value
  expressions, the singular SELECT INTO shape — unknown verbs
  refuse, never guess. 240 workspace tests; all dsql/wire gates
  green.

## 2026-07-29 — fire-crab-wire: UPDATE OR INSERT

### Converted
- **`UPDATE OR INSERT INTO t (cols) VALUES (...) [MATCHING (cols)]`** —
  the engine's upsert, desugared at prepare into the UPDATE and INSERT
  plans the server already runs: try the update whose WHERE is the
  MATCHING columns, store when no row moved — the same execution plan
  `UpdateOrInsertNode` compiles. The MATCHING list defaults to the
  table's PRIMARY KEY columns, read from the catalog (multi-column
  keys included); the statement types as an INSERT, as the engine
  types it.
- **The engine's specific error where the key is missing**: a PK-less
  table without MATCHING refuses AT PREPARE with `isc_dsql_error` +
  `isc_primary_key_required` — `Primary key required on table
  "PUBLIC"."T"`, SQLSTATE 22000 — the one line that names what to
  fix, where the generic Dynamic SQL Error would hide it. (This came
  in as a user report: the upsert on a PK-less table "should work" —
  the engine itself requires MATCHING there, and now fire-crab says
  so in the engine's words.)

### Guarded
- `?` parameters (the two desugared plans would double-bind one
  client message), NULL matching values (the engine compares MATCHING
  with null-safe `blr_equiv`; a plain `=` would silently mis-match),
  RETURNING, a missing column list. Gate: `qa/serve-real-upsert.sh`
  (17 checks — the same script through fcwire and the C++ engine
  leaves two files the engine reads identically; gfix + gbak
  validate); 6 regression gates + 237 workspace tests green.

## 2026-07-29 — fire-crab-dsql slice 42: DISTINCT, PLAN INDEX, ROWS m TO n

### Converted
- **DISTINCT in body FOR SELECTs** (flip fifty-nine): `blr_project`
  over the select columns AFTER the boolean — the slice-6 view law
  landing at body numbering unchanged; multi-column and ORDER BY
  variants live-verified by the gate, never separately probed.
- **PLAN (tbl INDEX (names))** (flip sixty — a slice-41 refusal):
  `blr_indices` + a count + counted index names standing where
  `blr_sequential` stood; two-index plans battery-verified.
- **ROWS m TO n** (flip sixty-one): the legacy row limits desugar
  to UNFOLDED arithmetic — first = add(subtract(n, m), 1), skip =
  subtract(m, 1) — literal expression trees in the same rse slots
  OFFSET/FETCH fills.

### Guarded
- Recursive CTEs probed and named: WITH RECURSIVE = `blr_recurse`,
  a union-like whose anchor branch is an ordinary rse + map but
  whose RECURSIVE branch has ZERO streams — it reads the
  recursion's own context by fid. Transcript held. Also: ROWS n
  alone, ROWS with parameter bounds, DISTINCT in the singular
  form / over aggregates / over joins, empty index lists, PLAN
  JOIN. Gate: `qa/dsql-proc-blr.sh` grew to 253 checks (11
  fresh); 381 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 41: five doors - sort exprs, window exprs, OFFSET/FETCH, PLAN, params in HAVING

### Converted
- **Expression sort keys** (flip fifty-four): the raw expression in
  the sort clause — bare literals refuse (the engine reads them as
  POSITIONS, a wrong-bytes hazard closed at the same stroke).
- **Window passthrough expressions** (flip fifty-five): fields into
  the default window's map, the item rebuilt over the fids — the
  group-expression law in window clothing.
- **OFFSET/FETCH** (flip fifty-six): the standard spelling of SKIP
  and FIRST — the same rse clauses in the same probed order. PLAN,
  NATURAL, OFFSET, ROWS and ONLY joined the keyword list (PLAN was
  being slurped as a table ALIAS — the alias trap again).
- **PLAN (tbl NATURAL)** (flip fifty-seven): `blr_plan` +
  `blr_retrieve` + the stream re-emitted + `blr_sequential`, LAST
  in the rse after the sort. Other plan forms refuse.
- **Parameters in HAVING** (flip fifty-eight — a slice-9 refusal,
  thirty-two slices old, felled by the gate's own battery
  statement): parameters and variables pass through the aggregate
  boundary plainly.
- **HAVING without GROUP BY** — pinned: an aggregate with zero
  group keys, live through composition all along.

### Guarded
- ORDER BY positions, PLAN INDEX/ORDER/JOIN forms, OFFSET/FETCH
  with parameters. Gate: `qa/dsql-proc-blr.sh` grew to 243 checks
  (7 fresh); 369 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 40: item expressions, group-expr keys, multi-ctes

### Converted
- **Select-item expressions** (flip fifty-one): body FOR SELECT and
  SELECT INTO items are FULL value expressions at the stream
  context — parsed by the general val() (bare names resolve as
  COLUMNS there; the stream scope is set), plain columns keeping
  their shape for the aggregate/cursor paths.
- **GROUP BY expressions** (flip fifty-two — slice 39's transcript
  cashed): the group list takes the raw expression, the map carries
  its BARE fields, and select items REBUILD over the mapped fids —
  in SELECT-ITEM order, each item contributing its fields (deduped)
  or its aggregate verb, the slice-8 map law generalized. ORDER BY
  keys over aggregates rebuild the same way — the gate itself
  caught `ORDER BY SALARY / 1000` refusing and forced the fix.
- **Multiple ctes** (flip fifty-three): comma-separated WITH lists,
  each expanding once at its FROM reference — one pinned expanding
  inside a correlated subquery.

### Guarded
- Select items whose fields aren't group-key fields, non-aggregate
  expression ORDER keys, twice-referenced/unreferenced ctes,
  expression passthrough beside windows. Gate: `qa/dsql-proc-blr.sh`
  grew to 236 checks (5 fresh); 363 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 39: WITH ctes, expression INSERT..SELECT

### Converted
- **WITH ctes** (flip forty-nine): the engine INLINES a
  non-recursive cte as a DERIVED table — the cte name becomes the
  relation2 alias (`"W1" "PUBLIC"."U2"`), column aliases translate,
  inner WHERE inside, exactly the derived machinery by another
  syntax. The parser records the body's token SPAN at WITH and
  expands it at the FROM reference — one cte, referenced exactly
  once (recursion refuses because the expansion consumes the single
  use). Works in the singular SELECT INTO and FOR loops.
- **Expression INSERT..SELECT** (flip fifty — the FIFTIETH refusal
  to fall): source items are FULL value expressions at the source
  stream, via the same two-phase list parse every select uses.

### Probed, unconverted
- **GROUP BY expressions**: the expression rides the group list but
  the map carries the BARE fields, and select items are REBUILT
  over the mapped fids — a named refusal with its transcript.

### Guarded
- GROUP BY expressions, multiple ctes, twice-referenced ctes,
  unreferenced ctes, INSERT..SELECT over aggregates. Gate:
  `qa/dsql-proc-blr.sh` grew to 232 checks (6 fresh — a
  two-column cte, one correlated through EXISTS from the cte's
  derived stream); 360 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 38: body unions, INSERT..SELECT

### Converted
- **UNION in body FOR SELECTs** (flip forty-seven — slice 37's
  transcript cashed): `blr_union` claims the statement's FIRST
  slot — a lookahead reserves it before the branch streams number —
  with per-branch rses (each WHERE inside) and maps; a DISTINCT
  union appends `blr_project` over the union fids; duplicate select
  columns keep separate slots; INTO reads union fids. UNION ALL
  chains of any length; mixed ALL/distinct refuses.
- **INSERT ... SELECT** (flip forty-eight — a refusal named in
  slice 12, twenty-six slices ago): a marks(1, 4)-stamped FOR loop
  over the source rse storing one row per source row — the SOURCE
  stream numbers FIRST, the target claims the next slot. Plain and
  qualified source columns, a source WHERE, working in procedures,
  subroutines and triggers.

### Guarded
- Mixed ALL/distinct unions, unions beside every other structure
  (sorts, cursors, locks, aggregates, windows, joins, derived),
  INSERT..SELECT with expressions or aggregates. Gate:
  `qa/dsql-proc-blr.sh` grew to 226 checks (6 fresh — a
  three-branch union with aliases, INSERT..SELECT inside a
  subroutine), `qa/dsql-trig-blr.sh` holds 48 with the trigger
  INSERT..SELECT flipped; 353 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 37: derived-column aliases

### Converted
- **Derived-column aliases** (flip forty-six — slice 36's refusal,
  transcript in hand): `(SELECT UID AS X FROM U2) D` records an
  outer-to-inner name map, and every outer reference to `X` —
  qualified or bare, in select items, WHEREs, ORDER keys or
  correlated subqueries — TRANSLATES to the inner column at the
  shared context: `D.X` emits the underlying `UID`. One translation
  point in the field resolver; the three hardcoded bare-name parse
  sites now route through it (which also carries their join-refusal
  and gains the translation for free).

### Probed, unconverted
- **UNION in body FOR SELECTs**: `blr_union` claims the statement's
  FIRST slot with branch streams following and fid outputs — a
  named refusal with the transcript. **Named windows** (WINDOW W
  AS): the engine's own resolver rejected both probe placements —
  guarded as an engine-side blocker.

### Guarded
- UNION in bodies, named windows, derived expressions/stars. Gate:
  `qa/dsql-proc-blr.sh` grew to 220 checks (6 fresh — a two-alias
  derived pair, one under IN (SELECT), one correlated through
  EXISTS); 349 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 36: NTH_VALUE, derived tables in bodies

### Converted
- **NTH_VALUE** (flip forty-four): canonicalizes like its LAG/LEAD
  siblings — a FROM FIRST indicator (literal 0) appended as the
  third `blr_agg_function` argument.
- **Derived tables in body FOR SELECTs** (flip forty-five): the
  view convention at body numbering — the inner rse in the stream
  slot with alias text `"D" "PUBLIC"."U2"`, the inner WHERE inside
  it, the outer WHERE at the rse level, ONE shared context.
  Pass-through column lists only (a derived-column alias needs
  outer-to-inner name mapping — guarded with the transcript).
- **Derived tables in subqueries** — pinned: the shape was LIVE
  through composition since the subquery slice (stream_item always
  could return a derived stream), compiling byte-identical without
  a single covering test until now.

### Guarded
- Derived-column aliases, derived streams beside aggregates/
  windows/joins/cursors/locks, named windows (the WINDOW clause —
  the engine's own placement rules resisted the probe). Gate:
  `qa/dsql-proc-blr.sh` grew to 214 checks (6 fresh); 347 unit
  byte-pins.

## 2026-07-29 — fire-crab-dsql slice 35: windowed argument functions, frame extents

### Converted
- **LAG / LEAD / FIRST_VALUE / LAST_VALUE** (flip forty-two):
  argument-taking window functions under `blr_agg_function` — a
  counted name and true argument count. LAG and LEAD canonicalize
  to THREE arguments: the value, the offset (filled with literal 1
  when omitted), and the default (filled with blr_null) — probed
  against explicit-argument forms sharing one window.
- **Frame extents** (flip forty-three — slice 34's refusal): a
  framed window switches to the v4 `blr_window_win` verb with
  subcoded clauses — 1 partition (the v3 layout under a tag), 2
  order, 3 map, 4 extent unit (RANGE 0 / ROWS 1), 5 frame bound
  (frame number + bound code: 0 preceding / 1 following / 2
  current row), 6 frame value — and its OWN blr_end where the v3
  form leans on the shared rse end. UNBOUNDED is a bound sans
  value; a single-bound frame implies CURRENT ROW as frame two.
  v3 and v4 windows mix freely in one statement.

### Guarded
- NTH_VALUE, exclusion clauses, frames without an ORDER BY, named
  windows (the WINDOW clause). Gate: `qa/dsql-proc-blr.sh` grew to
  208 checks (7 fresh — among them LAST_VALUE over an
  UNBOUNDED-to-UNBOUNDED range and a mixed framed/unframed pair);
  343 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 34: window functions

### Converted
- **Window functions** (flip forty-one): `<fn> OVER ([PARTITION BY
  ...] [ORDER BY ...])` in FOR SELECT bodies — `blr_window` wraps
  the inner rse (its WHERE inside), then a window count and per
  window `blr_partition_by`: context, partition keys as source
  fields then REMAPPED as fids into the window's own map, a sort
  clause, the map. The laws: passthrough columns live in the
  DEFAULT (empty-spec) window beside empty-spec OVER () functions;
  each distinct (partition, order) spec gets its own window, in
  ENCOUNTER order, claiming the contexts after the stream; a
  window's map holds its items in select order with the partition
  keys appended; outputs read fids at per-window contexts. The
  aggregate verbs work windowed, and the named zero-argument
  functions (ROW_NUMBER, RANK, DENSE_RANK) ride
  `blr_agg_function` — a counted name and an argument count. The
  battery's RANK / DENSE_RANK / three-item multi-window /
  two-key-partition checks were never probed — green on the
  convention alone.

### Guarded
- Frame extents (ROWS/RANGE BETWEEN — the v4 `blr_window_win`
  verb), windows beside aggregates/GROUP BY/joins/statement ORDER
  BY, the singular form, named windows. Gate: `qa/dsql-proc-blr.sh`
  grew to 201 checks (7 fresh); 337 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 33: aggregates over joins, joined cursors

### Converted
- **Aggregates over joins** (flip thirty-nine — slice 32's own
  refusal): the join chain sits INSIDE the aggregate's inner rse
  with the WHERE after it, and the aggregate claims the slot after
  ALL the join streams (a joined COUNT put it at 2 over streams 0
  and 1) — the slice-8 next-slot law counting past a chain. GROUP
  BY with qualified keys, HAVING and ORDER BY ride the existing
  map machinery.
- **Joins in cursor declarations** (flip forty): BOTH streams carry
  the cursor pairing — `"CX" "A"` and `"CX" "B"` — the slice-31
  infection reaching the chain via the same cur stamp; each
  output's derived_expr wrap names its column's OWN stream (probed:
  `BF 01 00` then `BF 01 01`), and FETCH reads fields at per-stream
  contexts. Positioned DML on a joined cursor refuses (not
  updatable), as do aggregate joined cursors and WITH LOCK over
  chains.

### Guarded
- Aggregate cursors over joins, positioned DML on joined cursors,
  joins under AS CURSOR, subqueries in joined-cursor WHEREs (the
  scope refuses them). Gate: `qa/dsql-proc-blr.sh` grew to 194
  checks (6 fresh); 327 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 32: joins in body FOR SELECTs, packaged calls

### Converted
- **Joins in body FOR SELECTs** (flip thirty-seven): INNER/LEFT/
  RIGHT/FULL join chains compile in FOR SELECT and the singular
  SELECT INTO — the view's left-nested chain at body numbering, ON
  at the join level, WHERE at the rse level, join_type absent for
  INNER. The MERGE scope generalized to a RANGE of stream indexes:
  qualified names resolve across the chain, and BARE names refuse —
  the gate itself caught a bare column binding to the FIRST stream
  where the engine resolves through the catalog (a wrong-bytes
  hazard closed before it shipped). A three-stream chain and a FULL
  OUTER under the singular form pinned.
- **Packaged routine calls** (flip thirty-eight):
  `EXECUTE PROCEDURE PKG.P` = `blr_exec_proc2` (counted package +
  name, exec_proc-style u16 counts); `PKG.F(x)` in expressions =
  `blr_function2` (package, name, a count BYTE, the arguments) —
  compact verbs, not the invoke forms subroutines take.

### Guarded
- Aggregates over joins, joins under AS CURSOR, bare columns
  across a join, subqueries inside ON clauses, derived streams in
  chains. Gate: `qa/dsql-proc-blr.sh` grew to 188 checks (6
  fresh); 323 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 31: the cursor-alias infection, DISTINCT scalars

### Converted
- **Subqueries inside cursor rses** (flip thirty-five — slice 30's
  guarded law, converted with its transcript): every stream under a
  cursor's rse — subquery streams included — carries the cursor's
  concatenated alias: the cursor name paired with the stream's own
  alias (`"CX" "X"`) or its schema-qualified name
  (`"CX" "PUBLIC"."T"`). Implemented as a post-parse STAMP walking
  the boolean tree (the AS CURSOR name isn't known until after its
  WHERE parses), a `cur` slot on the stream, and one emission
  branch; relation3 takes the same string in its alias slot inside
  subroutines — DECLARE CURSOR, AS CURSOR, and cursor-in-subroutine
  all pinned. Found on the way: subselect's ON-clause guard
  (`outer` = None) also fired during declare sections — `outer`
  now sets before the declares.
- **DISTINCT aggregate scalars** (flip thirty-six): the dedicated
  verbs for COUNT/SUM/AVG, MIN/MAX folding DISTINCT away — the
  slice-10 law reaching the scalar-subselect surface.

### Guarded
- Quantified comparisons over aggregate output, derived tables in
  subqueries, subqueries in MERGE ON clauses. Gate:
  `qa/dsql-proc-blr.sh` grew to 182 checks (4 fresh + slice 30's
  refusal flipped); 314 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 30: aggregate scalar subselects

### Converted
- **Aggregate scalar subselects** (flip thirty-four — slice 29's
  refusal, transcript in hand): `(SELECT MAX(ID) FROM T [WHERE])`
  as a value compiles to `via(singular, rse1(aggregate at the NEXT
  slot over the inner rse — its WHERE INSIDE — zero group keys, a
  one-slot map), fid(agg, 0), null)`. The aggregate claims the slot
  after its stream, as everywhere; in a FOR's WHERE the subquery
  stream lands at 1 over the FOR's 0 with the aggregate at 2. All
  five verbs plus COUNT(*)/COUNT(col); works in assignments, WHERE
  comparisons, SET values, and inside subroutine bodies (battery).
- EXISTS inside subroutine bodies pinned by composition —
  relation3's empty alias slot on the subquery stream.

### Guarded
- Subqueries inside a CURSOR's rse — their streams INHERIT the
  cursor alias string (probed: the EXISTS stream carried
  `"CX" "PUBLIC"."T"`), a peculiar law left with its transcript;
  quantified comparisons over aggregate output; DISTINCT aggregate
  scalars. Gate: `qa/dsql-proc-blr.sh` grew to 178 checks (8
  fresh); 311 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 29: subqueries in bodies, aliased AS CURSOR

### Converted
- **Subqueries in body statements** (flip thirty-two — the second
  slice-7 refusal to fall in two slices): EXISTS/SINGULAR,
  IN (SELECT)/ANY/ALL and scalar subselects work in body WHEREs and
  assignments. The whole view-compiler subquery machinery carried
  over on TWO changes: the subquery stream takes the NEXT context
  id in the statement's numbering (`si + base` — the view formula
  was this law at base 1 all along), and the enclosing statement's
  stream stays visible to QUALIFIED names (a `host` slot in the
  field resolver — probed: an EXISTS correlated on the FOR's table
  by name). A scalar subselect in an assignment claims ctx 0.
- **Aliased AS CURSOR** (flip thirty-three): the cursor name pairs
  with the table ALIAS — `"CU" "E"` — the DECLARE CURSOR law; in a
  subroutine the same string rides relation3's alias slot (battery,
  by composition).

### Guarded
- Aggregate scalar subselects (`(SELECT MAX(..) ...)` — transcript
  in hand), joins/comma-FROM inside subqueries, subqueries in ON
  clauses. Gate: `qa/dsql-proc-blr.sh` grew to 170 checks (9
  fresh — among them NOT EXISTS, > ALL, IF (EXISTS ...) and
  back-to-back scalar subselects); 305 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 28: aliased streams, subroutines in triggers

### Converted
- **Aliased streams in body statements** (flip thirty — one of the
  OLDEST refusals, named in slice 7): `FOR SELECT ... FROM T E`,
  `DELETE FROM T E`, `UPDATE T E SET ...` all compile — relation2
  with the quoted alias at top level, relation3 with the alias in
  its always-present slot inside subroutines (the QV4 transcript),
  qualified references resolving through the one stream with the
  field machinery unchanged. Aliased aggregate sources with
  qualified group keys ride along.
- **Subroutines in trigger bodies** (flip thirty-one): DECLARE
  PROCEDURE/FUNCTION takes the same grouped-declare slot cursors do
  — the sub_decl machinery shared verbatim, sub calls working from
  trigger statements (a probe passed NEW.ID as a sub-function
  argument, resolved in the OUTER trigger scope).

### Guarded
- Aliased streams under AS CURSOR (the alias string's shape
  unprobed), aliased positioned DML, derived FOR streams. Gate:
  `qa/dsql-proc-blr.sh` grew to 161 checks (7 fresh + the slice-7
  alias refusal flipped to a check), `qa/dsql-trig-blr.sh` to 48;
  302 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 27: streams inside subroutines

### Converted
- **blr_relation3** (flip twenty-nine — slice 26's refusal, the
  transcript already in hand): inside a SUBROUTINE body every
  stream qualifies itself — counted schema `PUBLIC`, counted EMPTY
  package, the name, then the alias slot relation2 would carry (the
  quoted alias, a cursor's name string) or a counted empty when
  relation-plain, then the context. The layout read from the
  engine's own `RelationSourceNode::genBlr` — the mystery byte
  between schema and name was the empty package string. ONE
  emission switch (a `sub` flag on the stream, set at parse) turns
  the whole converted surface loose inside subroutines: INSERT,
  DELETE/UPDATE loops, singular SELECT INTO over aggregates,
  FOR SELECT, DECLAREd cursors, AS CURSOR loops with positioned
  DML, UPDATE OR INSERT and MERGE — the battery runs them all,
  most never probed in subroutine clothing.
- **Zero-argument sub-function calls** flipped with the gate's own
  find: `F()` compiles — the argument tag rides along with count 0
  where invoke_procedure omits its empty tags.

### Guarded
- Derived tables inside subroutines, nested subroutines, aliased
  FOR streams (top level and sub alike — the relation3-with-alias
  transcript is in hand). Gate: `qa/dsql-proc-blr.sh` grew to 155
  checks (8 fresh + slice 26's streams refusal flipped to a check);
  296 unit byte-pins.

## 2026-07-29 — fire-crab-dsql slice 26: subroutines, named ES parameters - and a latent fix

### Converted
- **DECLARE FUNCTION** (flip twenty-six): `blr_subfunc_decl` —
  counted name, type 0, a deterministic/aggregate flag byte,
  u16-counted parameter-name lists (the return slot an UNNAMED
  output), then the WHOLE inner body's BLR as a u32-counted blob —
  compiled by the same body machinery as top-level procedures on a
  fresh parser. RETURN <expr> = begin(assign the unnamed slot 0,
  the no-EOF send, blr_leave 0); function sends DROP the EOF
  assignment their message still declares. Calls are
  `blr_invoke_function` value expressions: id clause (4 sub, 3
  counted name), u16-counted arguments.
- **DECLARE PROCEDURE** (flip twenty-seven): `blr_subproc_decl`,
  same frame with a SELECTABLE flag (a SUSPEND anywhere inside);
  calls take `blr_invoke_procedure` with input values (tag 3) and
  output variables (tag 5). A void subroutine goes WITHOUT
  blr_stall where a top-level body keeps it.
- **Named EXECUTE STATEMENT parameters** (flip twenty-eight,
  slice 25's refusal): tag 12 with a counted name before each
  value; plus the modifiers ON EXTERNAL (5) / AS USER (6) /
  PASSWORD (7) / ROLE (14) — clause order from the engine's own
  genBlr; a modifier alone forces the FULL blr_exec_stmt form even
  on a parameterless literal.

### Fixed
- **The declare-section law, re-read**: a two-local probe showed
  procedure LOCALS group — declare, declare, init, init — NOT the
  per-variable interleave sixteen slices had assumed (outputs DO
  interleave; single-local bodies can't tell the difference, and no
  battery statement had two inited locals). The slice-21 "deferral"
  law was this grouping all along. A latent wrong-bytes path,
  closed with pins at top level, in sub-procedures and in
  sub-functions.

### Guarded
- Streams inside subroutine bodies (they emit blr_relation3 with an
  explicit schema — probed, unconverted), nested subroutines,
  zero-argument sub-function calls, RETURN outside functions,
  SUSPEND inside them, mixed named/unnamed ES parameters. Two more
  subroutine laws pinned on the way: a SUBROUTINE's inputs RESERVE
  variable slots (locals number past them — top-level bodies don't)
  — gate: `qa/dsql-proc-blr.sh` grew to 147 checks (12 fresh); 291
  unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 25: MERGE branch chains, parameterized EXECUTE STATEMENT, WITH LOCK

### Converted
- **Multi-branch MERGE** (flip twenty-three): branches of one kind
  form an if-else CHAIN in SQL order — each conditional branch
  `if(cond, action, <next>)` where the next if fills the else slot
  BY POSITION, the last conditional getting a bare end, an
  unconditional LAST branch filling the else directly. The rse
  boolean ORs kind-terms built from left-nested or-chains:
  `and(not(missing), or(c1, c2, ...))` matched /
  `and(missing, or-chain)` not-matched, each simplified to its bare
  missing-test when the kind has an unconditional branch. Contexts
  allocate BY KIND in branch order — every matched UPDATE claims a
  new-record slot, then every INSERT its store slot. A branch after
  its kind's unconditional one refuses (unreachable — one else slot).
- **Parameterized EXECUTE STATEMENT** (flip twenty-four):
  `('<sql>') (vals)` compiles the FULL `blr_exec_stmt` — tag-prefixed
  clauses in fixed order: 1 in-count, 2 out-count, 3 sql, 4 the FOR
  form's DO statement, 11 input values, 13 output variables,
  blr_end. The literal no-param forms keep their compact verbs
  (exec_sql / exec_into).
- **WITH LOCK** (flip twenty-five): `blr_writelock` between the
  stream and the boolean — in FOR SELECT, DECLAREd cursors and AS
  CURSOR loops alike; the battery drives locked cursors through
  positioned UPDATEs in both cursor forms.

### Guarded
- WITH LOCK over aggregates or beside ORDER BY (unprobed emission
  order), named EXECUTE STATEMENT parameters (`a := :v`), branches
  after an unconditional one. Gate: `qa/dsql-proc-blr.sh` grew to
  135 checks (12 fresh); 279 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 24: conditional MERGE, scroll fetch, RETURNING, EXECUTE STATEMENT

### Converted
- **WHEN [NOT] MATCHED AND <cond>**: the condition joins the rse
  boolean's branch term — `and(not(missing), cond)` /
  `and(missing, cond)`, bare cond for a matched-only merge — and
  wraps the branch action in `if(cond, action, bare end)` nested in
  its slot (flip twenty; slice 23's refusal in the gate flipped to
  a check).
- **SCROLL cursors + FETCH directions**: `blr_scrollable` before
  the dcl_cursor rse; `FETCH <dir> FROM c` is cursor_stmt sub-verb
  3 + a direction byte (0 next, 1 prior, 2 first, 3 last, 4
  absolute, 5 relative) + an offset value — `blr_null` unless
  ABSOLUTE/RELATIVE. NEXT works unscrolled; the rest demand SCROLL
  (flip twenty-one).
- **DML RETURNING ... INTO**: three different shapes for one clause
  — INSERT = `blr_store2` with a second returning begin at the
  store's context; UPDATE = `blr_modify2` under a SINGULAR rse,
  returning reading the NEW record; DELETE = NO erase2 at all — a
  begin holding the returning assigns then the PLAIN erase, under a
  singular rse. RETURNING makes the loops singular.
- **EXECUTE STATEMENT**: plain = `blr_exec_sql` + the sql literal;
  `[FOR] ... INTO` = `blr_exec_into` with u16 out-count, the sql,
  flag 1 (singleton) or flag 0 + the labeled loop's DO statement,
  then the variables LAST (flip twenty-two).

### Guarded
- Multiple same-kind MERGE branches (if-else chains, probed but
  unconverted), backward fetch on unscrolled cursors, RETURNING on
  positioned DML, RETURNING expressions, EXECUTE STATEMENT with
  expression sql / USING / external sources. Gate:
  `qa/dsql-proc-blr.sh` grew to 123 checks (13 fresh); 271 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 23: MERGE, AS CURSOR, cursors in triggers

### Converted
- **MERGE**: one probed sentence — `for(marks(1, 6), rse(join2(
  source@0, target@1, [LEFT], ON-boolean), [branch-union boolean]),
  if(<matched test>, ...))`, branching on `missing(dbkey(target))`.
  The join is LEFT only when a NOT MATCHED branch needs unmatched
  rows — matched-only merges compile an INNER join with NO rse
  boolean. The rse boolean ORs the branch conditions in canonical
  order (matched first); SQL branch order leaves NO trace. Branch
  contexts allocate UPDATE's new record first, then INSERT's store
  (update+insert = 2,3; anything-else+insert = 2). The UPDATE half
  is `blr_modify(target, new) + marks(1, 2)` (MARK_MERGE), DELETE is
  the positioned-erase shape with marks(1, 2), INSERT re-emits the
  TARGET stream — alias and all — under `blr_store`. Sources read
  ctx 0, target-org fields ctx 1; bare names refuse (catalog-free).
- **FOR SELECT ... [INTO ...] AS CURSOR name**: the ordinary labeled
  FOR loop whose relation2 alias carries the CURSOR NAME exactly
  like a DECLAREd cursor's — no dcl_cursor, no outputs section. The
  INTO clause becomes OPTIONAL; its assign-sources wrap in
  blr_derived_expr. WHERE CURRENT OF in the DO body targets the
  FOR's own context, in scope for the body only.
- **Cursors in TRIGGER bodies**: DECLARE CURSOR works in triggers —
  the declaration keeps its SOURCE slot among the grouped declares
  (the trigger flavor of the deferral law), numbering past OLD/NEW
  (probed at ctx 2). MERGE and AS CURSOR loops ride along.

### Guarded
- WHEN MATCHED AND <cond>, multiple same-kind MERGE branches,
  sub-select sources, bare names in MERGE scope; ORDER BY on an AS
  CURSOR loop; OPEN/FETCH/CLOSE against a FOR cursor; a FOR cursor
  named outside its loop. Gate: `qa/dsql-proc-blr.sh` grew to 110
  checks (12 fresh), `qa/dsql-trig-blr.sh` to 46 (4 fresh — among
  them a trigger MERGE and a trigger AS-CURSOR positioned update,
  neither probed directly); 261 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 22: cursors completed - aliases, aggregates, positioned DML

### Converted
- **WHEN SQLSTATE '<s>'**: handler code 8 + counted string — flip
  thirteen.
- **Handlers carrying handlers**: a handler's block body with its
  OWN WHEN nests `blr_block` again WITH its own error-handler
  section — the slice-20 refusal flipped (fourteen) by one probe.
- **Cursor table aliases + qualified columns**: with `FROM T A` the
  relation2 alias string becomes `"CX" "A"` — cursor name + table
  alias — replacing the schema-qualified table; qualified columns,
  WHERE and ORDER BY refs resolve through the one visible stream
  (flip fifteen).
- **AGGREGATE cursors**: `blr_aggregate` nests inside the
  dcl_cursor rse at ctx+1 — claiming a SECOND context slot (probed
  on a two-cursor body) — with the WHERE inside the inner rse,
  group_by + map as in FOR SELECT, and the outputs and
  fetch-sources as BARE `blr_fid` slots: no blr_derived_expr
  wrapper (flip sixteen). The engine itself demands AS names for
  aggregate columns — the parser requires them too.
- **Positioned DML**: `DELETE ... WHERE CURRENT OF` is `blr_erase`
  at the CURSOR's own context — no fresh slot — with
  `blr_marks(1, 1)` (MARK_POSITIONED) TRAILING the erase, where a
  DML loop's marks(1, 4) LEAD its rse. `UPDATE ... WHERE CURRENT
  OF` is `blr_modify` from the cursor's context to ONE fresh slot,
  marks(1, 1), then the assignments — SET sources read the
  cursor's context (probed: `SALARY = SALARY + 1`). The INTO-less
  `FETCH` that positions them carries an empty begin/end.

### Guarded
- DISTINCT aggregates, HAVING and ORDER BY in aggregate cursors;
  positioned DML against the wrong table or an aggregate cursor.
  Gate: `qa/dsql-proc-blr.sh` grew to 98 checks (11 fresh — among
  them a WHILE-driven sweep pairing FETCH INTO with a multi-column
  positioned UPDATE, never probed directly); 247 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 21: autonomous transactions and cursors

### Converted
- **IN AUTONOMOUS TRANSACTION DO**: `blr_auto_trans`, a sub-code
  byte (0), the statement — composing with blocks and POST_EVENT in
  the battery.
- **Multi-column MATCHING**: one `blr_equiv` per column, left-nested
  under `blr_and` (probed on two, batteried on a three-column upsert
  matching two).
- **WHEN SQLCODE <n>**: handler code 1 + i16 little-endian — flip
  twelve.
- **CURSORS**: `DECLARE name CURSOR FOR (SELECT ...)` is
  `blr_dcl_cursor` — u16 number, the rse whose relation2 alias
  carries the CURSOR NAME like a derived table's, u16 output count,
  `blr_derived_expr`-wrapped outputs. OPEN/CLOSE/FETCH are
  `blr_cursor_stmt` sub-verbs 0/1/2, fetch carrying its
  into-assignments. The battery drives a cursor through a WHILE loop
  guarded by ROW_COUNT.
- **A new ordering law, pinned three ways**: a variable's INIT is
  DEFERRED past cursor declarations that follow it — flushing before
  the next variable's declare or at the section end. Found by the
  gate (a cursor-after-variable battery statement), settled by two
  targeted probes.

### Guarded
- WHEN SQLSTATE (unprobed layout), qualified cursor columns,
  aggregate cursor selects. Gate: `qa/dsql-proc-blr.sh` grew to 87
  checks; 236 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 20: UPDATE OR INSERT and settled probes

### Converted
- **UPDATE OR INSERT**, from the shape slice 19 probed: a begin
  holding a marks-stamped modify-loop whose boolean is `blr_equiv`
  (0x2E — null-safe equality) on the MATCHING column, then
  `if(row_count = 0, store)`. Contexts allocated store, modify-new,
  rse-org IN THAT ORDER — the INSERT half claims its slot first.
  MATCHING is REQUIRED (the default needs the primary key — the
  catalog) and single-column (more are unprobed). The battery runs
  one with an expression VALUES (`:P1 * 10`).
- **CURRENT_CONNECTION / CURRENT_TRANSACTION**: internal_info(1) and
  (2) — the context-code family grows (5=ROW_COUNT, 6=trigger
  action).
- **Slice 19's named probes settled — flips ten and eleven**:
  MULTIPLE handlers per block emit one error-handler section per
  WHEN, sequential; a BLOCK as a handler's body nests blr_block
  AGAIN with no handler section of its own. Both pinned.

### Guarded
- UPDATE OR INSERT without MATCHING (a primary-key catalog lookup),
  multi-column MATCHING, handlers that carry their own handlers.
  Gate: `qa/dsql-proc-blr.sh` grew to 80 checks (6 fresh); 225 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 19: error handling

### Converted
- **WHEN handlers**: a BEGIN..END carrying WHEN becomes `blr_block`
  — a begin with the guarded statements, `blr_error_handler` with a
  u16 code count and the code, the handler STATEMENT, blr_end. Three
  code kinds probed: WHEN ANY = blr_default_code (4); WHEN EXCEPTION
  <name> = 9, 0, counted name; WHEN GDSCODE <name> = 0, counted
  UPPERCASED name. Handlers work in procedures and triggers alike.
- **The plain-block law confirmed**: a nested BEGIN..END WITHOUT
  handlers stays a DOUBLE begin in both body kinds — blr_block
  belongs to handler-carrying blocks only (a proc IF-block probe
  settled it).
- **ROW_COUNT**: blr_internal_info(5) — beside the trigger-action
  code 6, one family of context codes. The battery feeds it from
  UPDATE and DELETE and guards an EXCEPTION with it.
- **UPDATE OR INSERT probed**, not yet converted: a modify-loop plus
  a row_count-guarded store, with blr_equiv (0x2E — null-safe
  equality) for MATCHING. It holds a named refusal until the next
  slice.

### Guarded
- A BLOCK as a handler body (blr_block nests differently there),
  WHEN SQLCODE/SQLSTATE, multiple handlers per block, UPDATE OR
  INSERT. Gate: `qa/dsql-proc-blr.sh` grew to 73 checks (6 fresh:
  WHEN ANY DO EXIT, division guarded by a parameter, ROW_COUNT into
  IF/EXCEPTION); 220 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 18: domain validation, sequences, events

### Converted
- **The SEVENTH catalog store: domain validation.** A DOMAIN's CHECK
  lands in `RDB$FIELDS.RDB$VALIDATION_BLR` — and its shape DIFFERS
  from a table CHECK's system trigger: the RAW boolean, NOT negated,
  no abort wrapper, between blr_version5 and blr_eoc, with VALUE
  compiling to `blr_fid(0, 0)`. The same clause keyword, two stores,
  two shapes — routed by whether the clause speaks of VALUE.
- **Sequences, two verbs for one concept**: `GEN_ID(seq, inc)` is
  blr_gen_id (counted name + increment value) while
  `NEXT VALUE FOR seq` is blr_gen_id2 (the name alone) — the verb
  chosen by SYNTAX, not semantics.
- **POST_EVENT <value>;**: blr_post + the event-name value, a
  statement in either body kind (a conditional POST_EVENT under IF
  is in the battery).

### Guarded
- (nothing new — the surface grew cleanly.) Gates:
  `qa/dsql-field-blr.sh` grew to 39 checks (5 validations incl.
  VALUE IN (1,2,3) — integer items stay uncast even against a fid)
  and `qa/dsql-trig-blr.sh` to 42; 214 unit byte-pins across seven
  stores.

## 2026-07-28 — fire-crab-dsql slice 17: constraints and two more stores

### Converted
- **Domain defaults**: `RDB$FIELDS.RDB$DEFAULT_VALUE` — the same
  minimal frame as column defaults, read from the domain's catalog
  row (`compile_default` unchanged; the gate grew a domain section).
- **Expression indexes**: `RDB$INDICES.RDB$EXPRESSION_BLR` — a
  COMPUTED BY expression byte-shaped exactly like a computed
  column's (`compile_computed` unchanged; new gate section).
- **CHECK constraints**: the engine's OWN system triggers
  (RDB$TRIGGERS types 1 and 3 — byte-identical): begin, blr_if over
  the NEGATED condition — `CHECK (A < B)` stores blr_geq, the NOT
  fold reused — whose then-branch is blr_abort with blr_gds_code
  'check_constraint', a bare-end else, fields at CONTEXT 1 (the NEW
  record). `compile_check` handles the clause.

### Fixed
- **The CHECK battery exposed a LATENT VIEW-COMPILER GAP**: the
  engine CASTS non-integer IN-list items to the left side's CATALOG
  type — `S IN ('a','b')` stores blr_cast varying2(10) per item, the
  column's declared type, in views and CHECKs alike — and fire-crab
  had only ever pinned integer IN-lists, so a string IN-list would
  have emitted UNCAST bytes. Probed in both stores, then closed:
  integer literals and input parameters (both probed uncast) stay;
  everything else refuses. A refusal slot went into the view gate
  beside the fix.

### Guarded
- String and decimal IN-list items (catalog casts), CHECKs with
  string IN-lists. Gate: `qa/dsql-field-blr.sh` grew to 34 checks
  (12 fresh: 3 domains, 3 indexes, 5 CHECKs incl. BETWEEN and
  compound AND); 207 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 16: the fourth oracle — column BLR

### Converted
- **Oracle number four: column BLR.** A DEFAULT clause is stored
  verbatim in `RDB$RELATION_FIELDS.RDB$DEFAULT_VALUE`, a COMPUTED BY
  expression in `RDB$FIELDS.RDB$COMPUTED_BLR` — both with the
  SMALLEST wrapper of the four oracles: `blr_version5, the value,
  blr_eoc`.
- **Defaults are as narrow as the engine's own grammar**: literals
  (signs folding), NULL, and the niladic context functions —
  CURRENT_DATE 0xA0, CURRENT_TIME 0xA2, CURRENT_TIMESTAMP 0xA1, one
  verb each (`DEFAULT 3 + 4` is an ENGINE syntax error, so fcdsql
  refuses it too).
- **COMPUTED BY takes the whole converted expression surface** with
  the table's columns as bare fields at CONTEXT 0 — arithmetic,
  functions, concatenation, COALESCE, CAST, SUBSTRING, a
  cast-wrapped CASE — the stream is anonymous, so qualified names
  refuse.
- The context functions are Val variants now, usable everywhere the
  expression surface reaches.

### Guarded
- Non-grammar defaults, qualified names in computed expressions, and
  a CASE with FIELD branches in a computed — the engine compiles it,
  but its cast descriptor needs the CATALOG's column types, so the
  catalog-free line holds. New gate: `qa/dsql-field-blr.sh` — 22
  checks; 200 unit byte-pins across four oracles.

## 2026-07-28 — fire-crab-dsql slice 15: calls, exceptions, exit

### Converted
- **EXECUTE PROCEDURE**: `blr_exec_proc` — a counted name, u16 input
  count + values, u16 output count + blr_variable targets
  (`RETURNING_VALUES :v, ...`). Arg-less calls carry two zero words.
- **EXCEPTION <name>**: `blr_abort, 2, counted name`. **EXIT**:
  `blr_leave 0` — it leaves the WRAPPER's label, the same leave verb
  WHILE uses.
- **(FOR) SELECT inside TRIGGER bodies**: the stream takes the next
  context after OLD/NEW, labels share the numbering, and the DO body
  is any statement (no row-send — that is SUSPEND's, and SUSPEND is
  procedure-only).
- **The aggregate-context law GENERALISED**: the aggregate node takes
  stream ctx + 1 wherever the stream lands — probed at 1-over-0
  (slice 8), 3-over-2 (a trigger's singular aggregate select) and
  2-over-1 (an aggregate after a DML). The slice-14 refusal of
  aggregates at nonzero contexts fell to a probe — flip nine — and
  HAVING/ORDER-BY fids now carry the right context everywhere.

### Guarded
- (nothing new — the slice REMOVED a refusal). Gates:
  `qa/dsql-proc-blr.sh` grew to 67 checks, `qa/dsql-trig-blr.sh` to
  38 (12 fresh battery statements incl. RETURNING_VALUES into a
  local and EXCEPTION raised from a trigger); 189 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 14: general procedure bodies

### Converted
- **The statement surfaces UNIFIED**: procedure bodies now run the
  same statement machine as triggers — bodies mix FOR SELECT loops,
  singular SELECT INTOs (into locals too), DML, IF/WHILE and
  SUSPENDs freely, with FOR labels numbering alongside the WHILEs.
  Every prior single-statement shape re-emits byte-identically
  through the general machine (the 174 existing pins are the
  regression net that proved it).
- **Outputs ARE variables**: `R1 = 5;` assigns variable 0; locals
  continue the numbering (interleaved declare/init in procedures
  where triggers group). SUSPEND anywhere is the row send.
- **RETURNS is OPTIONAL**: a no-output procedure carries a ONE-SLOT
  message 1 — just the EOF short — and a flag-only final send
  (probed).
- **Name resolution split**: outside stream scopes a bare name
  resolves local variables FIRST, then input parameters (probed:
  `IF (I1 > 0)` compiles the message reference bare); inside
  selects, subqueries and DML WHEREs a bare name stays a COLUMN —
  variables need their colon — and `:name` reaches locals and
  outputs as blr_variable.

### Guarded
- SUSPEND without outputs, aggregate selects after stream-claiming
  statements (the aggregate-context law is probed only at 0). Gate:
  `qa/dsql-proc-blr.sh` grew to 59 checks (10 fresh multi-statement
  battery statements incl. two-SUSPEND bodies and IF THEN INSERT
  ELSE DELETE); 182 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 13: PSQL control

### Converted
- **DECLARE [VARIABLE]**: declares sit between the outer begin and
  label 0, each null-initialised UNLESS an initialiser replaces the
  null. With several variables, **triggers group ALL declares first,
  THEN the inits — where procedures interleave per variable** (both
  probed: read the bytes, not the symmetry). Bare names resolve to
  local variables FIRST; `v = expr;` assigns to blr_variable.
- **WHILE (c) DO stmt**: blr_label N, blr_loop, begin, blr_if(c,
  body, blr_leave N), end — labels number in ENCOUNTER order after
  the wrapper's 0; nested loops probed (outer 1, inner 2, leaves
  matching).
- **INSERTING / UPDATING / DELETING**: eql(blr_internal_info(literal
  6), literal 1/2/3) — so NOT INSERTING folds to neq through the
  ordinary inverse law, and the predicates compose under AND/OR
  (battery: UPDATING OR DELETING, UPDATING AND v > 100). Multi-event
  headers (BEFORE INSERT OR UPDATE OR DELETE) leave no trace like
  the rest of the header.

### Guarded
- Assignments to undeclared names, bare LEAVE (loop control beyond
  WHILE's own is unconverted). Gate: `qa/dsql-trig-blr.sh` grew to
  34 checks (8 fresh PSQL battery statements); 174 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 12: the DML verbs

### Converted
- **INSERT is `blr_store`(relation, assignments)** — no for-wrapper;
  the target claims the next context and assignments follow the
  column list's order. The list is REQUIRED (without it the mapping
  needs the catalog). VALUES read OLD/NEW freely.
- **DELETE is `blr_for` over a `blr_marks(1, 4)`-stamped rse, then
  `blr_erase(ctx)`** — blr_marks is the DSQL's loop stamp, probed on
  every UPDATE/DELETE and absent on store.
- **UPDATE is the same loop with `blr_modify(org, new,
  assignments)`** — and the NEW-record context is allocated BEFORE
  the rse stream's (probed: modify 3,2 with the rse at 3). SET
  targets write the new context; SET sources and the WHERE read the
  ORG stream (`SET UA = UA + 1` reads ctx 3, writes ctx 2 — pinned).
- Inside a DML's WHERE a bare name binds to the DML's own stream —
  the innermost-scope rule again (battery: `WHERE DEPT_ID =
  OLD.DEPT_ID AND SALARY = 0`, engine-agreed). Contexts keep
  counting across multiple DML statements (a two-DML trigger is in
  the battery); DML composes under IF.

### Guarded
- INSERT without a column list, column/value miscounts (an engine
  error), INSERT ... SELECT (unprobed). Gate: `qa/dsql-trig-blr.sh`
  grew to 24 checks (8 fresh DML battery statements); 166 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 11: the third oracle — triggers

### Converted
- **Oracle number three: `RDB$TRIGGER_BLR`.** A trigger body is
  compiled by the same DSQL and stored verbatim — with the leanest
  wrapper of the three oracles: blr_begin, blr_label 0, a DOUBLE
  blr_begin holding the statements, three ends, eoc. The HEADER
  (table, BEFORE/AFTER, event, POSITION) leaves NO trace — catalog
  data, like a view's select list.
- **OLD is CONTEXT 0, NEW is CONTEXT 1** — modelled as two
  pseudo-streams, so qualified fields resolve through the ordinary
  path and bare names refuse (ambiguous between the two records).
- **Statements**: `NEW.col = <value>;` is blr_assignment(value,
  field); `IF (cond) THEN stmt [ELSE stmt]` is blr_if — with a bare
  blr_end byte in a MISSING else slot (probed); a nested BEGIN..END
  block is a DOUBLE blr_begin (probed); statements concatenate. The
  whole converted expression surface rides on trigger fields — the
  battery runs UPPER, SUBSTRING, CHAR_LENGTH, a cast-wrapped CASE
  and IN lists against OLD/NEW columns.

### Guarded
- OLD targets (read-only in the engine), bare column names, empty
  bodies, database-level triggers (ON CONNECT — a different
  wrapper). New gate: `qa/dsql-trig-blr.sh` — 14 checks, all
  byte-identical on the first run; 158 unit byte-pins across three
  oracles.

## 2026-07-28 — fire-crab-dsql slice 10: SELECT INTO, FIRST/SKIP, DISTINCT aggregates

### Converted
- **The SINGULAR `SELECT ... INTO`** (no FOR): `blr_for` over
  `blr_singular(rse)` with NO label 1; the for's body holds only the
  assignments, and a trailing `SUSPEND;` compiles as a SIBLING send
  after the for — without it only the final EOF send remains (both
  probed). The whole rse surface (WHERE, aggregates, inputs) rides
  inside.
- **FIRST <n> / SKIP <n>**: rse sub-clauses carrying one value each;
  probed order stream, FIRST, SKIP, boolean, sort.
- **The DISTINCT aggregate verbs**: COUNT/SUM/AVG get dedicated
  verbs (agg_count_distinct 0x5E, agg_total_distinct 0x5F,
  agg_average_distinct 0x60) while **MIN(DISTINCT) and MAX(DISTINCT)
  FOLD to the plain verbs** — probed byte-identical. Two prior
  refusals became features (COUNT(DISTINCT), the bare SELECT INTO
  body) — flips seven and eight.

### Guarded
- `FIRST :param` without parens (an ENGINE syntax error),
  parenthesised FIRST expressions, FIRST/SKIP over aggregate streams
  or in the singular form (unprobed placements). Gate:
  `qa/dsql-proc-blr.sh` grew to 48 checks (11 fresh battery
  statements incl. singular+input+aggregate and a grouped
  COUNT(DISTINCT) with an input); 149 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 9: input parameters

### Converted
- **Input parameters are MESSAGE 0**: one dsc + null-flag blr_short
  per parameter and NO EOF slot (outputs' message 1 has one); the
  whole loop block sits under `blr_receive 0` — its begin's own
  blr_end doubles as the receive's end, and the final EOF send stays
  outside it (probed).
- **`:name` is a direct message reference**: blr_parameter2(0, 2i,
  2i+1) used STRAIGHT as a value — no variable is declared for
  inputs, unlike outputs. Inputs ride anywhere a value does in the
  FOR select: comparisons, arithmetic (`A + :I1`), IN lists,
  BETWEEN two inputs inside an aggregate's source WHERE — all in
  the battery, beside ORDER BY and GROUP BY.
- The slice-7 refusal of input parameters became this feature; its
  gate slot flipped to a positive check (an UNUSED input still
  shapes message 0 and the receive wrapper — checked
  differentially). The sixth refusal-to-feature flip.

### Guarded
- `:name` that misses the input list, inputs inside HAVING (they
  would cross the aggregate boundary — unprobed), and `:name`
  outside a procedure body refuse. Gate: `qa/dsql-proc-blr.sh` grew
  to 37 checks (7 fresh input battery statements); 138 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 8: aggregates and GROUP BY

### Converted
- **The aggregate is a STREAM**: `blr_aggregate` with its OWN context
  (1) wrapping the source rse (ctx 0) — and the WHERE stays the
  SOURCE rse's boolean, inside the aggregate. Then `blr_group_by`
  (count byte + keys — present even with ZERO keys) and `blr_map`.
- **The verbs**: agg_count (COUNT(*)), agg_count2 (COUNT(v) — counts
  non-null values, a DIFFERENT verb), agg_max/min/total/average.
  Arguments take full value expressions (`SUM(SALARY * 12)` in the
  battery).
- **Two order laws**: the group_by list follows the GROUP BY CLAUSE
  order while the map follows the SELECT-LIST order — probed to
  differ on one statement (`SELECT A, S ... GROUP BY S, A`).
- **Everything downstream speaks blr_fid(1, slot)**: the DO body's
  assignments, ORDER BY's sort keys, and HAVING — the OUTER rse's
  boolean — where a group-key column becomes its slot's fid and an
  aggregate call DEDUPS against the map: a structurally equal
  aggregate REUSES its select-list slot (probed: HAVING COUNT(*)
  beside SELECT COUNT(*) stores fid 1,1 — no third slot) while a
  fresh one APPENDS (HAVING COUNT(*) beside SELECT MAX adds slot 2).

### Guarded
- A plain column beside an aggregate without GROUP BY, GROUP BY
  without aggregates, select columns missing from GROUP BY,
  `COUNT(DISTINCT ...)` (the distinct agg verbs), non-grouped columns
  in HAVING, and LIKE/IN/subqueries over aggregate output refuse.
  Gate: `qa/dsql-proc-blr.sh` grew to 29 checks (10 fresh aggregate
  battery statements incl. a compound HAVING with AND); 134 unit
  byte-pins.

## 2026-07-28 — fire-crab-dsql slice 7: the second oracle — procedures and ORDER BY

### Converted
- **Oracle number two: `RDB$PROCEDURE_BLR`.** A procedure's
  `FOR SELECT ... DO SUSPEND` body holds what a view cannot — ORDER
  BY — and the engine stores its compiled BLR verbatim too.
  `compile_procedure` emits the WHOLE body byte-identically:
  blr_message 1 with 2n+1 dscs (each parameter's dsc FOLLOWED BY a
  null-flag blr_short, then one final blr_short — the EOF flag; the
  dsc encodings are the CAST ones, byte for byte), a blr_declare +
  NULL-init per parameter, blr_stall, two blr_labels, blr_for over
  the rse, field→variable assignments (INTO names pick the
  variables — an out-of-order INTO is in the battery), and twin
  blr_sends: each variable through blr_parameter2 (value slot 2i,
  null slot 2i+1), the EOF flag (parameter 2n) literal short 1
  inside the loop and 0 after it.
- **ORDER BY**: `blr_sort` after the rse's boolean — a count byte,
  then per key blr_ascending or blr_descending and the value. Mixed
  directions probed (DESC, ASC on one statement).
- **The context-base law**: procedure bodies number streams from
  CONTEXT 0 where view BLR numbers from 1 (probed: the FOR stream is
  `blr_relation 'T' 0`). One parser serves both — `P.base` is 1 for
  views, 0 for procedures. The body's WHERE reuses the whole
  converted expression surface (functions, CASE, IN — all at ctx 0).

### Guarded
- Input parameters (they add a second message), subqueries inside
  procedure bodies (contexts unprobed), aliased FOR streams,
  `ORDER BY <position>`, sort expressions, INTO names that miss the
  RETURNS list or miscount the columns, and multi-statement bodies
  all refuse. New gate: `qa/dsql-proc-blr.sh` — 17 checks, every
  battery statement fresh; 121 unit byte-pins across both oracles.

## 2026-07-28 — fire-crab-dsql slice 6: DISTINCT, scalar subselects, derived tables, UNION

### Converted
- **DISTINCT**: `blr_project` after the boolean — a count byte and
  the SELECT LIST's columns. The one place the select list leaves a
  trace in view BLR (everywhere else it compiles away).
- **Scalar subselects as values**: `blr_via(blr_singular(rse),
  value, blr_null)` — usable anywhere a value is: both comparison
  sides, inside arithmetic (`SALARY + (SELECT ...)`), beside other
  subquery predicates.
- **Derived tables**: an rse IN THE STREAM SLOT whose relation2
  alias text is `"ALIAS" "PUBLIC"."TABLE"` — the schema-qualified
  underlying table rides along in the alias (probed; a PLAIN alias
  stays short `"X"`). The whole derived table has ONE context,
  shared by inner and outer references. Rides anywhere a stream can
  (probed as a join's left side). Pass-through column lists only;
  the alias is required.
- **UNION [ALL]**: the statement rse's single stream is `blr_union`
  — its own context byte (1, claimed BEFORE any branch stream, which
  is why the compiler pre-scans for a top-level UNION), a branch
  count, then per branch an rse (branch WHERE inside) and a
  `blr_map` (u16 count, then u16-field-number/value pairs). The
  DISTINCT form appends `blr_project` over `blr_fid(1, 0..n)`;
  UNION ALL does not. Three-branch chains probed (contexts 2, 3, 4).

### Guarded
- Mixed `UNION`/`UNION ALL` chains (they bind by precedence rules
  not yet probed), column-count mismatches (an engine error),
  DISTINCT inside union branches, `DISTINCT *`, DISTINCT over
  expressions, alias-less derived tables and derived union branches
  all refuse. The slice-5 refusal of scalar subselects became a
  feature — its gate slot flipped to a positive check. Gate:
  `qa/dsql-view-blr.sh` grew to 127 checks (17 fresh slice-6 battery
  statements; 3 new refusal slots); 115 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 5: subquery predicates

### Converted
- **EXISTS / SINGULAR**: `blr_any` / `blr_unique` over ONE rse — the
  subquery's WHERE is that rse's boolean and its select list leaves
  no trace, exactly like a view's (`SELECT 1` ≡ `SELECT *`, probed).
  NOT keeps a REAL `blr_not` over both: no inverse verbs.
- **IN (SELECT ...) and the quantified comparisons**: `blr_ansi_any`
  / `blr_ansi_all` with a DOUBLE-NESTED rse — the outer rse's single
  STREAM IS the subquery's rse (which carries the subquery's own
  WHERE), and the quantified comparison is the OUTER rse's boolean.
  `= ANY` compiles byte-identical to IN; SOME to ANY; ALL keeps the
  WRITTEN comparison.
- **The negation law**: the quantifier FLIPS and the comparison
  INVERTS — `NOT IN` is ansi_all + neq, `NOT (A = ANY ...)` the
  same, `NOT (A > ALL ...)` is ansi_any + leq (all probed).
- **Scoping**: subquery streams JOIN the statement's context
  numbering (T=1, U2=2, a subquery's V3T takes 3 — probed) but stay
  INVISIBLE to outer bare names; inside a subquery a bare name binds
  to the subquery's OWN stream (innermost-scope-first; an outer
  reference must be qualified). Aliased subquery streams are
  blr_relation2. Subqueries compose: under AND/OR, inside CASE
  conditions, with expression left-hand sides.

### Guarded
- Scalar subselects as VALUES (`A = (SELECT ...)`), subqueries inside
  ON clauses (they would interleave the join chain's stream
  numbering), multi-stream subqueries and multi-column select lists
  refuse as unconverted. Gate: `qa/dsql-view-blr.sh` grew to 108
  checks (16 fresh slice-5 battery statements; 4 new refusal slots);
  101 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 4: CAST and the conditionals

### Converted
- **CAST**: `blr_cast` + a dsc, each target's layout probed:
  SMALLINT/INTEGER/BIGINT are dtype + scale; NUMERIC(p≤4) is SHORT
  but DECIMAL(p≤9) is ALWAYS LONG (SQL's "at least p"); p 10..=18 is
  INT64 and beyond refuses; VARCHAR/CHAR carry a charset word and a
  length word; DATE/TIME/TIMESTAMP are a bare dtype.
- **Searched CASE and IIF** (byte-identical sugar): ONE `blr_cast`
  over a `blr_value_if` chain — each further WHEN nests in the ELSE
  slot, a missing ELSE is `blr_null`. The cast's descriptor is the
  branches' UNIFIED type, law probed case by case: NULL branches are
  ignored; text branches take blr_text2 at the MAX length
  ('yes'/'no' → CHAR(3)); exact numerics take MAX integer digits +
  MIN scale and the dtype that FITS the total (≤4 short, ≤9 long,
  else int64) — so long(0) ∪ long(-1) WIDENS to int64 (9+1=10
  digits): `CASE ... THEN 1.5 ELSE 0 END` casts to int64 scale -1.
- **Simple CASE**: `blr_decode` — count byte, comparands, count byte,
  results; the ELSE is one extra result and its absence is unmarked.
  NO cast wrapper (probed). **COALESCE**: `blr_coalesce`, count byte
  + values, also wrapper-free — so field arguments are fine there.
- **NULLIF(a, b)**: `cast(value_if(a = b, NULL, a))` — the dsc comes
  from the BRANCHES (NULL and a); b NEVER shapes it (probed:
  NULLIF(1, 2.55) casts to long scale 0).

### Guarded
- A FIELD branch under a cast wrapper refuses — its descriptor lives
  in the catalog and this compiler never guesses one (COALESCE and
  decode take fields freely: no descriptor to compute). Single-arg
  COALESCE (an engine syntax error), FLOAT/NUMERIC(>18) casts,
  all-NULL branch lists and text/numeric mixtures refuse as unprobed.
  Gate: `qa/dsql-view-blr.sh` grew to 90 checks (24 fresh slice-4
  battery statements; 4 new refusal slots); 85 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 3: outer joins, chains, functions

### Converted
- **Outer joins**: `blr_join_type` follows the join's streams and
  precedes its ON boolean, carrying 1=LEFT, 2=RIGHT, 3=FULL — and is
  ABSENT for INNER (probed). `LEFT OUTER JOIN` compiles byte-identical
  to `LEFT JOIN`.
- **Join chains**: each ON binds to its LEFT, so the chain nests left —
  the second join's `blr_join` node holds the first join's node as its
  first stream slot (probed on a three-table chain), and a type byte
  sits only on its own node in a mixed inner/outer chain.
- **INT64 literals**: a literal past blr_long's 32 bits emits
  `blr_int64` (dtype 0x10, one scale byte, 8 little-endian bytes); the
  sign still folds into the literal.
- **The first built-in functions in compiled BLR**: `blr_upcase` /
  `blr_lowcase` (one operand); `blr_strlen` with its length-type byte
  (CHAR_LENGTH=1, OCTET_LENGTH=2 — probed, not assumed); `blr_substring`
  whose start is 0-BASED and compiled as `blr_subtract(<from>, 1)`
  UNFOLDED (probed: `FROM 1` stores subtract(1,1), not literal 0);
  `blr_trim` with a where byte (0=BOTH, 1=LEADING, 2=TRAILING) and a
  spec byte (0=spaces, 1=explicit <what>); a bare `TRIM('a' FROM s)`
  is BOTH. Functions compose (UPPER(TRIM(x)), functions inside ON).

### Fixed
- A hand-written expected pin for `A = -5000000000` was WRONG — the
  compiler was right and the pin invented. The engine probe settled
  it (the pinned bytes now come from RDB$VIEW_BLR, per the project
  rule: never pin what was not probed).

### Guarded
- An unknown name followed by `(` — a UDF or an unconverted built-in —
  refuses instead of falling back to a field read; `SUBSTRING` without
  `FOR` and `CROSS JOIN` refuse as unprobed layouts. Gate:
  `qa/dsql-view-blr.sh` grew to 62 checks (19 fresh slice-3 battery
  statements incl. UPPER-inside-ON and a NULL-hunting outer join);
  52 unit byte-pins.

## 2026-07-28 — fire-crab-dsql slice 2: expressions, IN, streams

### Converted
- **Value expressions** in the compiled BLR: blr_add / subtract /
  multiply / divide / negate / concatenate with the engine's
  precedence; a sign before a NUMERIC LITERAL folds into it (probed:
  `A = -1` stores the negative literal, no negate verb) while
  blr_negate survives before fields; parens reshape the tree.
- **IN lists**: FB5's dedicated `blr_in_list` (value, little-endian
  u16 count, values); `NOT IN` keeps a real blr_not — and the De
  Morgan folder treats InList like LIKE/MISSING.
- **Multi-stream RSEs**: comma-FROM lists emit streams side by side
  with 1-based contexts; `[INNER] JOIN ... ON` emits `blr_join`
  nesting like an rse with the ON clause as its own boolean
  sub-clause; aliases emit `blr_relation2` with the alias UPPERCASED
  IN DOUBLE QUOTES (probed: `FROM T x` stores `"X"`). Qualified
  fields resolve to their stream's context; a BARE field in a
  multi-stream statement refuses — the engine resolves those through
  the catalog, and this catalog-free compiler never guesses a
  context. Gate: `qa/dsql-view-blr.sh` grew to 41 checks (15 fresh
  slice-2 battery statements; LEFT JOIN and bare multi-stream fields
  hold refusal slots); 31 unit byte-pins.

## 2026-07-28 — fire-crab-dsql: SQL → BLR, first slice

### Converted
- **The `fire-crab-dsql` crate** — the beginning of `src/dsql/`'s
  conversion, with the purest oracle in the project: `CREATE VIEW`
  makes the ENGINE's DSQL compile the SELECT and store the BLR
  verbatim in `RDB$VIEW_BLR`, so fire-crab-dsql's output is compared
  BYTE FOR BYTE against the original compiler's for the identical
  statement. First slice: the view-shaped single-relation SELECT with
  WHERE booleans. Probed compilation laws, each pinned: the select
  list leaves NO trace (mapping is positional catalog data); NOT
  compiles away — inverse verbs for comparisons, De Morgan through
  AND/OR — surviving only over LIKE and MISSING; `NOT BETWEEN`
  expands to `lss OR gtr` while BETWEEN stays `blr_between`; IS NULL
  is `blr_missing`; decimal literals keep their written scale; text
  literals are `blr_text2` with charset and length words; AND/OR
  chains nest left. Gate: `qa/dsql-view-blr.sh`, 26 checks — a
  battery deliberately beyond the unit-test pins, plus refusals
  (ORDER BY, arithmetic values, IN, aggregates, joins) that must
  refuse rather than guess.

## 2026-07-28 — predicate-surface completion

### Converted
- **CASE inside WHERE**: the tokenizer lexes the `CASE .. END` span by
  balancing the KEYWORDS (nested CASEs nest, an 'end' inside a string
  literal is skipped) and hands it whole to the expression parser —
  searched, simple, and nested forms as filters.
- **`?` against expression sides**: `WHERE UPPER(S) = ?` claims its
  slot with a bind descriptor SYNTHESIZED from the expression's type;
  at execute the value substitutes as a literal and the term evaluates
  three-valued (`Term::ExprParam` → `ExprCond` at bind).
- **Expressions in JOIN predicates**: arithmetic, functions, CASE and
  column-vs-column over the combined row, through a synthetic
  single-relation view (bare unambiguous names; ambiguous names
  refuse rather than guess a side). Gate:
  `qa/serve-real-predfull.sh`, 20 checks (node-firebird drives the
  parameter phase); wherexpr/nofallback stale refusals flipped
  (36 / 54).

## 2026-07-28 — status-vector fidelity

### Fixed
- **The 22018 conversion error carries its offending string** as an
  `isc_arg_string` in the status vector (`EvalErr::ConversionError`
  gained a payload; the vector writer ships an XDR counted string) —
  isql now prints `conversion error from string "pear"` identically on
  both sides, closing the missing-argument placeholder difference.
- **DML errors gained a vector channel**: `execute_dml` returns
  `ExecErr { Text, Eval }`, and a per-row eval error in a DML's WHERE
  (`UPDATE ... WHERE A / 0 = 1`) answers the engine's own 22012 vector
  instead of a generic SQL error. The wherexpr/aggexpr gates' SQLSTATE
  workarounds flipped back to exact differential checks.

## 2026-07-28 — fallible predicates, expressions everywhere in WHERE

### Converted
- **Full expression comparison sides in WHERE**: `A + 1 > B`, column
  vs column, parenthesised sides, `(A + B) * 2 = 6`, arithmetic
  BETWEEN/IN bounds, CAST/COALESCE/NULLIF/IIF as predicate sides —
  a token-level precedence parser folds operator tokens back into
  expression trees; bare columns and literals keep the classic fast
  paths (parameters, exact numeric terms). Gate:
  `qa/serve-real-wherexpr.sh`, 35 checks.

### Fixed
- **`Predicate::matches` became FALLIBLE** — the architectural change
  under the feature. A per-row eval error (`WHERE A / 0 = 1`, a
  negative length from a column, a failed CAST) now PROPAGATES through
  every predicate consumer and reaches the client with the engine's
  own vector, mid-statement. The "no-raise fence" is gone: previously
  fenced shapes (runtime MOD divisors, column lengths, CAST, DATEADD
  in WHERE) are admitted; the wherefn gate's refusal entries moved to
  differential checks (51).

### Guarded
- Type fences remain (text under MOD/SIGN/ABS), as does the
  `?`-against-expression-side refusal and CASE-in-WHERE. Documented
  differences: some errors surface at EXECUTE in the engine vs first
  FETCH here (one leading blank in isql); a DML WHERE error answers a
  generic SQL error (text channel, not a vector).

## 2026-07-28 — temporal arithmetic

### Converted
- **`DATEADD` / `DATEDIFF`** (both syntaxes each) and the **native
  temporal operators** (`D + 7`, `7 + D`, `TS + 1`, `DATE − DATE`,
  `TS − TS`, `TIME − TIME`). Probed laws: month-end clamping, TIME
  wrapping midnight, DATE absorbing clock units by truncation,
  DATEDIFF's calendar-component YEAR/MONTH vs boundary-crossing clock
  units (signed), MILLISECOND at NUMERIC(18,1), TIME−TIME seconds at
  −4, TIMESTAMP differences as nanodays truncating to 9 exact digits,
  and numeric addends CVT-rounding (D + 0.5 moves a day). DATEDIFF is
  admitted to WHERE (it cannot raise); DATEADD refuses there (range
  errors are mid-cursor). Composes with EXTRACT, CASE, aggregates and
  GROUP BY expressions. Gate: `qa/serve-real-datemath.sh`, 40 checks.

## 2026-07-28 — GROUP BY expressions

### Converted
- **Expression grouping keys**: `GROUP BY UPPER(S)` /
  `EXTRACT(YEAR FROM D)` / `MOD(A, 2)` / `CASE ... END`, and
  `GROUP BY <ordinal>` naming an expression select item — each key
  computed per row into a synthetic value slot, bucketed like a field
  (NULL keys share a bucket). Select-list expressions match group keys
  STRUCTURALLY (parsed trees compare; column names case-insensitive,
  literals exact), so `GROUP BY upper( s )` matches `SELECT UPPER(S)`.
- **HAVING breadth**: expression aggregates (`HAVING SUM(A + ID) > 5`,
  `COUNT(NULLIF(A, 1))`, `SUM(IIF(...))`) fold as hidden items;
  NUMERIC aggregates compare through exact scale alignment
  (`HAVING AVG(N) > 0`, `SUM(N) > 0.10`); text MIN/MAX compare
  pad-trimmed (`HAVING MIN(S) = 'apple'`). Gate:
  `qa/serve-real-groupexpr.sh`, 30 checks; the aggexpr gate's HAVING
  refusal moved to its answered list (38 checks).

### Fixed
- The HAVING aggregate lexer scanned to the FIRST close paren, so a
  nested call (`COUNT(NULLIF(A, 1))`) broke the token; it scans to the
  MATCHING paren now.
- `GROUP BY` split its list on every comma, so `MOD(A, 2)`'s argument
  comma broke the key; top-level commas only now.

## 2026-07-28 — aggregates over expressions

### Converted
- **Expression arguments in every aggregate**: `SUM(A + ID)`,
  `AVG(N * 2)`, `MIN(UPPER(S))`, `MAX(S || '!')`,
  `COUNT(NULLIF(G, 1))`, `SUM(IIF(...))`, `SUM(CASE ... END)`,
  `MIN(EXTRACT(YEAR FROM D))` — evaluated per row before the fold,
  lone and grouped. The group fold became FALLIBLE: an eval error in
  the argument (`SUM(A / 0)`) aborts the fetch with the engine's own
  vector. SUM widens one step (probed: LONG → BIGINT, INT64-ranked →
  INT128 — `SUM(K)` and `SUM(A + ID)` both describe INT128); AVG keeps
  its width. Gate: `qa/serve-real-aggexpr.sh`, 37 checks.

### Fixed
- A lone aggregate's output column was headed `CONSTANT`; the engine
  names it by FUNCTION. `Plan::Scalar` now carries its header name
  (COUNT/MIN/MAX/SUM, GEN_ID for generator reads, CONSTANT for the
  bare-literal case) — the standing difference the previous slice
  documented.
- `GEN_ID(<missing generator>, 0)` answered NULL where the engine
  raises "generator is not defined" — caught by this slice's header
  probes; it now refuses.

### Guarded
- Expression aggregates in HAVING refuse (a later slice); the
  conversion error inside an aggregate raises with the matching
  SQLSTATE 22018 but without the engine's offending-string argument —
  a documented difference, not a silent one.

## 2026-07-28 — the aggregate surface beyond integers

### Converted
- **`AVG`** (SUM/COUNT with truncating-toward-zero division at the
  operand's scale — probed: AVG(1,2)=1, AVG(-3.00, 0.05)=-1.47),
  **MIN/MAX over text and temporal columns** (the column's own type and
  wire form on the wire), **SUM/AVG over scaled numerics** (the
  engine's NUMERIC(18,s) widening), and **`COUNT(DISTINCT col)`**
  (distinct non-NULLs, compared with the predicates' exact equality).
  All of it in lone aggregates, WHERE-filtered, GROUP BY buckets and
  HAVING (including hidden AVG items). Gate: `qa/serve-real-aggfn.sh`,
  36 checks.

### Fixed
- A value wider than its announced wire form now RAISES at emit on the
  plain-output path too (a group's SUM spilling past BIGINT would have
  encoded zero bytes).

### Guarded
- `SUM/AVG/MIN/MAX(DISTINCT ...)`, `AVG` over text, `SUM` over dates
  refuse at prepare. The lone COUNT/MIN/MAX/SUM fast path still headers
  its column `CONSTANT` where the engine names the function — made
  visible by this slice's header checks, kept for now (the COUNT(*)
  fast path is what system relations depend on), AVG routes through
  the group machinery and headers correctly.

## 2026-07-28 — the temporal expression surface

### Converted
- **`EXTRACT`**, temporal literals (`DATE '...'`, `TIME '...'`,
  `TIMESTAMP '...'`), the clock keywords (`CURRENT_DATE`, `LOCALTIME`,
  `LOCALTIMESTAMP`), and DATE/TIME/TIMESTAMP columns as expression
  operands — through conditionals, concatenation, arithmetic on
  extracted parts, and WHERE predicates. Probed conventions: WEEKDAY
  0 = Sunday, YEARDAY 0-based, ISO 8601 week, SECOND at NUMERIC(9,4),
  MILLISECOND at NUMERIC(9,1); wrong parts fail at prepare; DATE vs
  TIMESTAMP converts as midnight. Gate: `qa/serve-real-extract.sh`,
  42 checks.
- **`docs/porting-playbook.md`** — tips for the next agent porting to
  another language: the method (probe first, engine as oracle, refuse
  loudly, diversify fixtures, prove gates fail pre-fix), the core
  algorithms in language-agnostic pseudocode (expression pipeline and
  its emit invariant, dialect-3 scale arithmetic, three-valued logic,
  DNF predicates with the no-raise fence, civil-date math, LIKE), the
  traps that cost real time, and the porting order that worked.

### Guarded
- Mixed temporal kinds (or a temporal beside a number) in a
  conditional refuse at prepare — the wire form could not carry both.
  `CURRENT_TIME`/`CURRENT_TIMESTAMP` (TIME ZONE types) refuse; the
  clock capture happens at plan time, a documented divergence for
  prepare-once-execute-many clients.

## 2026-07-28 — CASE, and the conditional typing law

### Converted
- **CASE expressions**, searched and simple, with full boolean
  conditions (`OR`/`AND`/`NOT`/parenthesised groups, three-valued
  Kleene) — and `IIF` upgraded to the same condition grammar (the
  engine parses IIF into a searched CASE; both header as `CASE`). The
  simple form desugars to `=` conditions, so `WHEN NULL` never matches
  — the engine's rule, for free. Gate: `qa/serve-real-case.sh`,
  44 checks.
- **`docs/expression-surface.md`** — the converted expression subsystem
  documented against its engine sources (`parse.y` precedence,
  `ExprNodes.cpp` scale/promotion laws, `SysFunction.cpp`, CVT
  coercions, the IIF→CASE lowering), with every probed law and the
  refusal policy in one place.

### Fixed
- **The conditional typing law**: a conditional typed from its FIRST
  branch alone, so `COALESCE(A, 0.5)` — integer first, scaled second —
  announced scale 0 and the scaled branch's raw value could not decode
  (0.5 read as 0.05, or an overflow refusal). Probed: the engine
  announces scale −1 and prints `-7.0`. Two rules close it: any
  exact-numeric branch beside integer ones types the conditional
  Numeric at the branches' minimum scale, and every branch value is
  ALIGNED to the announced scale at emit (`value_of`). A latent bug in
  ALL the older conditionals, exposed by the new gate's mixed-scale
  branches.

## 2026-07-28 — the scalar-function surface

### Converted
- **Built-in scalar functions** in the select list, computed columns and
  everywhere expressions go: `UPPER`, `LOWER`, `CHAR_LENGTH` /
  `CHARACTER_LENGTH`, `OCTET_LENGTH`, `SUBSTRING (FROM/FOR)`, `TRIM`
  (sides, multi-character `<what>`), `LEFT`, `RIGHT`, `REPLACE`,
  `POSITION` (both syntaxes, optional start), `REVERSE`, `ABS`, `MOD`,
  `SIGN`, `LPAD`, `RPAD` — the parser's string intrinsics
  (`blr_upcase`, `blr_substring`, `blr_trim`, `blr_strlen`) plus the
  `SysFunction.cpp` table. Every semantic probed against the engine
  before implementation; a literal negative `SUBSTRING` length fails at
  PREPARE with the engine's own `isc_bad_substring_length` vector
  (`Plan::RefusedEval`). Gate: `qa/serve-real-functions.sh`, 80 checks.
- **Function calls in WHERE** — a call on either side of a comparison,
  under `IS [NOT] NULL`, as a `LIKE` subject, inside `BETWEEN`/`IN`,
  under `AND`/`OR`/`NOT`, in SELECT and DML alike; evaluated per row
  through the select-list expression machinery with the predicate
  surface's three-valued logic and pad-insensitive text compare. Gate:
  `qa/serve-real-wherefn.sh`, 51 checks.

### Fixed
- The query splitter took the FIRST `FROM` in the statement —
  `SUBSTRING(S FROM 2)` and `TRIM(x FROM y)` carry their own `FROM`
  inside the select list's parentheses and broke the split. The clause
  `FROM` is now the first at paren depth zero on a literal-masked copy,
  which also stops a `' FROM '` inside a string literal splitting the
  query (a latent bug the new tests pin).
- An un-aliased `IIF` output column was headed `IIF`; the engine parses
  IIF into a searched CASE and heads it `CASE`. Invisible until now
  because the conditionals gate compares with headings off.

### Guarded
- A WHERE term answers only true/false and cannot carry the engine's
  mid-cursor error, so any predicate expression whose per-row
  evaluation could RAISE (`MOD` by a non-literal or zero divisor, a
  length from a column, a text operand under a numeric function, `CAST`)
  refuses at prepare — never admitted to silently exclude a row the
  engine would have raised on.
- A malformed call (`UPPER()`, `TRIM(LEADING S)`) refuses at prepare via
  the `names_expr_call` guard — the conditionals' malformed-call rule
  extended to every function name — rather than being misread as a
  column name.

## 2026-07-27 — the query surface rounds out

### Converted
- Subqueries in WHERE: `IN` / `NOT IN` / `EXISTS` / `NOT EXISTS` /
  scalar, evaluated up front and folded into the outer predicate
  (a correlated `EXISTS` runs as a semi-join).
- PSQL execution: `EXECUTE PROCEDURE` interpreted from the stored
  source; DML inside bodies; selectable procedures (`SUSPEND`, a
  procedure as a row source); `FOR SELECT` cursor loops.
- `UPDATE ... SET col = <expression>`, evaluated per row against the
  pre-statement row (SQL's simultaneous assignment: `SET A = B, B = A`
  swaps).
- Views: `RDB$VIEW_SOURCE` expanded and re-planned against the base
  table (positional rename map from `RDB$RELATION_FIELDS`).
- `UNION` / `UNION ALL`; `INSERT ... SELECT` through one shared
  row-source path; result modifiers `FIRST` / `SKIP` / `DISTINCT` /
  `ROWS` in the engine's grammar order.
- Conditional expressions `COALESCE` / `NULLIF` / `IIF` — the three NULL
  rules probed and pinned.
- Transaction rollback, statement-level rollback, and `SAVEPOINT`
  (whose bug was the statement-TYPE code: clients dispatch on it).

### Fixed
- Per-handle statement state — the server had served one statement per
  connection, which made a second prepare clobber the first and
  libfbclient segfault in teardown (found by the firebird-qa tree run).
- Record images are `fmt_length` exactly, no 4-byte rounding — the
  engine BUGCHECKed (sqz.cpp:179) once an UPDATE packed a slack image.

### Guarded
- The fixed-answer fallback (4242) closed at the root: an unplannable
  query RAISES; `qa/serve-real-nofallback.sh` hunts the leak across
  every surface. Writing the gate found five leaks the per-surface
  gates had missed, one a real correctness bug (a qualified outer
  column in a correlated `EXISTS`).
- Refusals fail at PREPARE, not mid-cursor — mid-cursor refusals made
  clients report "request synchronization error" and drop the
  connection (which is what libfbclient segfaults on).

## 2026-07-25/26 — DDL breadth, triggers, INT128

### Converted
- Expression→BLR compiler: computed columns (`COMPUTED BY`) through
  CREATE/ALTER/DROP; CHECK constraints (the boolean layer, a negated
  De-Morgan trigger pair); user `CREATE TRIGGER` — all six events,
  `DECLARE VARIABLE`, `WHILE`, `EXCEPTION`, nested blocks, `WHEN`
  handlers (named, `GDSCODE`/`SQLCODE`, `ANY`), embedded
  UPDATE/DELETE — byte-exact BLR the engine then executes.
- FK referential actions: `CASCADE`, `SET NULL`, `SET DEFAULT`,
  multi-column keys; NO-ACTION partner checks enforced in the DML path;
  the FK-parent DML guard.
- INT128 end to end: declarations (`NUMERIC(19..38)`), expression
  results with the engine's dtype promotion rules, index keys
  (`idx_bcd` BCD encoding, PMAX 39), WHERE predicates over scaled
  NUMERIC/DECIMAL/INT128 with exact i128 scale alignment.
- Column DEFAULTs applied on fire-crab's own INSERT, session-dependent
  defaults (`USER`, `CURRENT_CONNECTION`, ...) evaluated per attachment.
- IDENTITY columns (both kinds, RESTART, SET GENERATED, DROP IDENTITY),
  column POSITION, GLOBAL TEMPORARY TABLEs, domain-typed columns with
  overrides, `COMMENT ON DATABASE`, GRANT/REVOKE on
  procedures/functions/sequences/exceptions.
- `op_drop_database`, database aliases via `databases.conf`,
  `op_disconnect`/`op_execute2`, real-width text describes, the SRP
  proof compared by value (an auth flake fixed).

## 2026-07-24 — the security catalog and the object zoo

### Converted
- GRANT / REVOKE with the engine's recomputed ACLs — including the full
  per-column ACL compiler ported from `grant.epp` (squeeze-and-reappend
  ordering), role membership with the admin option, and
  `REVOKE GRANT OPTION FOR`.
- CREATE / DROP / ALTER for sequences, exceptions, roles, domains;
  `COMMENT ON` across the object zoo (a text blob whose charset byte
  only a byte-compare could catch); `SET STATISTICS`; ALTER INDEX
  ACTIVE/INACTIVE with index selectivity written the way the engine
  computes it.
- FOREIGN KEY in CREATE TABLE and by ALTER (the gbak-restore blocker
  solved); named PRIMARY KEY / UNIQUE constraints; DROP CONSTRAINT with
  the engine's deferred index drop.
- `RDB$FIELD_LENGTH` is the BYTE length — a divergence found by the
  domain slice and then fixed everywhere, making fire-crab's
  `RDB$RUNTIME` blob byte-identical to the engine's.

## 2026-07-23 — ALTER TABLE, and the expression surface begins

### Converted
- ALTER TABLE ADD / DROP COLUMN / ALTER TYPE — catalog amendment via new
  format versions, the field-id hole, RLE-packed in-place updates;
  SET/DROP NOT NULL (the first constraint the engine enforces on a
  fire-crab-written file without a restore).
- Select-list expression surface: `/` and `||`, `CAST`, numeric
  operands, dialect-3 scale arithmetic (probed rules), decimal
  literals; `GEN_ID(name, step)` / `NEXT VALUE FOR` — a SELECT that
  writes; auto-id INSERTs; SHOW PROCEDURE source.

## 2026-07-22 — from first SELECT to the firebird-qa milestone

### Converted
- The wire SERVER grew from answering `SELECT COUNT(*)` to: projections,
  WHERE (three-valued), ORDER BY (engine NULL order), aggregates,
  GROUP BY, HAVING, INNER and OUTER equi-joins, native wire types,
  BLOB content over the blob ops, INT128 + DECFLOAT (decNumber-exact
  rendering), TIME ZONE types, system-table projections through
  formats computed the way `ini.epp` computes them.
- The write path: INSERT into real pages, UPDATE/DELETE version chains
  the engine's own sweep collects, page allocation, B-tree index
  maintenance with splits, multi-segment and DESCENDING keys, parameter
  binding with engine-CVT coercions, the LIKE/BETWEEN/IN predicate
  surface, CREATE TABLE the engine adopts, PK/NOT NULL/CREATE
  INDEX/DROP TABLE the engine enforces and navigates.
- The outside faces: the python firebird-driver, the Services API +
  `op_create`, MON$ virtual tables — **the official firebird-qa pytest
  suite bootstraps against fire-crab and tests pass**; `SHOW` over the
  legacy BLR request API (a request-execution subsystem beside DSQL),
  generator reads and writes.

## 2026-07-21 — the storage layer, bottom-up

### Converted
- ODS page structures (header, TIP, PIP, pointer, data pages) with a
  gstat differential across 123 real databases; record RLE compression
  round-tripped; full-row decoding through `RDB$FORMATS` (blob
  assembly included) against live SELECTs; B-tree leaf walks against
  live ORDER BY; the transaction system (TIP chain, delta
  back-versions, MVCC visibility) against a file frozen
  mid-uncommitted-work; GC/sweep prediction against `gfix -sweep`;
  BLR decoding against the engine's own printer; the wire protocol as
  a CLIENT — XDR, SRP-256 from scratch, Arc4 — logging in to the real
  engine and running SELECTs that match isql row-for-row.
