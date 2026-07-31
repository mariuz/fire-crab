# Roadmap: from converted models to a working engine

Every increment so far has answered the same question — *what does the
engine do here?* — and answered it with a differential. That has produced
a server whose SQL surface agrees with Firebird across 150+ gates, and,
alongside it, nine converted subsystems with their own oracles.

This document is about the two things that are **not** more SQL surface.

## Where the project actually stands

The subsystem map's rows fall into three states, and the difference
matters more than the row count:

| state | rows | what it means |
|---|---|---|
| **done** | on-disk structures, record decode + RLE, PIP, pointer/data pages, B-tree decode, TIP/MVCC, GC/sweep, BLR decode | converted and held against an oracle; the server depends on them |
| **converted, wired** | `ods`, `blb`, `auth`, `svc`, `exe`, `dsql` | the running server links and uses them |
| **converted, NOT wired** | `opt`, `cch`, `lck`, `evt`, `pio` | a real conversion of a real law, with a gate — that the server never calls |

That last row is the honest headline. `crates/wire/Cargo.toml` does not
depend on `fire-crab-opt`, `-cch`, `-lck`, `-evt` or `-pio`. The
optimizer chooses access paths that nothing executes. The lock manager
decodes a lock table it never enqueues into. The page cache models a
careful-write graph the read path does not go through.

And inside the SQL layer there is a second structural gap: the server
answers views, CTEs and constant subqueries by **rewriting SQL text and
re-planning it**, where the engine builds a tree of record sources. That
approach has worked far better than it has any right to — but it is why
a CTE body that GROUPs refuses, why `FROM (SELECT ...)` does not exist,
why `WITH RECURSIVE` cannot work, and why a qualifier-stripping pass had
to be taught not to reach inside a subquery.

## The two programmes

### Programme R — the engine's execution shape

Replace textual rewriting with the engine's own structure: a tree of row
sources (`RecordSource`/rsb in `src/jrd/`), built by the planner and
pulled by the fetch.

- **R1 — the tree exists.** A `RowSource` with `TableScan`, `Filter` and
  `Sort`, and the simplest plan executing through it. No behaviour
  change; the gates are the proof. *(this increment)*
- **R2 — Aggregate and Group** become nodes rather than a separate plan.
- **R3 — NestedLoopJoin**, inner and outer, replacing `join_rows`.
- **R4 — derived tables**: `FROM (SELECT ...)`, the first capability the
  tree unlocks that the rewriting could not reach.
- **R5 — a materialised CTE**, which retires the "CTE body must be a
  single-table projection" refusal.
- **R6 — `WITH RECURSIVE`**, a fixpoint over the tree.
- **R7 — retire the textual view/CTE rewriting** and the qualifier
  passes that exist only to serve it.

### Programme W — wire the converted subsystems in

Each of these is "the model exists and is right; make the server use
it", which is a different risk profile from converting something new:
the oracle already exists, so the gate is *behaviour must not change*
plus *the subsystem is now on the path*.

- **W1 — index-driven retrieval.** The largest by impact: today every
  query is a full scan (30 `for_each_record` sites, zero B-tree
  navigation). `ods::btr` already decodes index pages and `opt` already
  picks the access path the engine picks. Wire them: equality lookup
  first, then ranges, then ORDER BY via navigation, then index-driven
  joins.
- **W2 — the page cache in the read path** (`cch`), then the write path
  with its careful-write precedence.
- **W3 — platform I/O** (`pio`) under the cache, instead of the server
  mapping bytes itself.
- **W4 — the lock manager participating** (`lck`): enqueue, dequeue,
  AST callbacks. This is what makes concurrent attachments correct
  rather than accidentally correct.
- **W5 — event delivery** (`evt`): the shared-memory arena, the watcher,
  and the wire path.
- **W6 — depth in `exe` and `svc`**: the request lifecycle, cursors and
  exceptions; then gbak/gfix/nbackup as services.

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
