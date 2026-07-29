# The Lock Manager Conversion (`fire-crab-lck`)

The conversion of `src/lock/lock.cpp` — the lock table that arbitrates
every shared resource in a Firebird installation — with its policy
held against two oracles: the engine's **own source** (the
compatibility matrix, re-parsed and diffed cell-by-cell) and the
engine's **live behavior** (table reservations and deadlocks produced
by a real server and compared decision-for-decision).

This document is the deep companion to the `fire-crab-lck` crate: what
the engine's structure is, exactly which parts slice 1 converts, why
the oracles are trustworthy, what the first probes taught, and what
rides the next slices.

* [Two layers: the Lock object and the lock table](#two-layers)
* [What slice 1 converts, and what it deliberately does not](#scope)
* [The compatibility matrix, and its famous cell](#matrix)
* [The granted-state aggregate, and why it is sound](#aggregate)
* [Enqueue, convert, dequeue: the three verbs](#verbs)
* [FIFO fairness: the pending queue blocks late arrivals](#fifo)
* [The deadlock scan](#deadlock)
* [The oracles](#oracles)
* [Probe log](#probes)
* [Roadmap](#roadmap)

<a name="two-layers"></a>
## Two layers: the Lock object and the lock table

The engine splits locking across two layers (the paper's
lock-manager chapter walks both):

- **`jrd/lck.cpp` — the Lock object layer.** Typed handles the rest
  of the engine holds: a relation lock, an attachment lock, the
  database lock, a page lock in Classic. This layer knows what the
  36 lock *series* mean.
- **`src/lock/lock.cpp` — the lock table.** A shared-memory arena of
  owner blocks (`own`), lock blocks (`lbl`) and request blocks
  (`lrq`), plus the algorithms over them: grant, wait, convert,
  release-and-regrant, deadlock scan, blocking-AST posting. This
  layer treats series and key as opaque bytes.

`fire-crab-lck` converts the **table's policy**. The arena — shared
memory mapping, hash chains, the free-block lists, the history
buffer, cross-process AST signalling — is transport: mechanically
substantial, but the part that can be wrong in *interesting* ways is
the policy, and the policy is what an oracle can judge. The crate's
`LockTable` is the same structure single-arena and in-process:
`BTreeMap<(series, key), LockBlock>`, each block holding granted
requests with per-mode counts and a FIFO pending queue.

<a name="scope"></a>
## What slice 1 converts, and what it deliberately does not

Converted, with the engine's own shapes:

| Engine | Crate | Notes |
|---|---|---|
| `LCK_none..LCK_EX` (`lock_proto.h:69-76`) | `Mode` enum | identical numeric values |
| `compatibility[LCK_max][LCK_max]` (`lock.cpp:150`) | `COMPATIBILITY` | transcribed cell-for-cell, pinned by `fclck pin-source` |
| `lbl_counts` + `lbl_state` | `LockBlock::counts` + `state()` | the single-aggregate grant test, `lock.cpp:2228` |
| enqueue (grant / wait / no-wait reject) | `LockTable::enqueue` | the pending queue also blocks late compatible arrivals — FIFO fairness |
| convert (`lock.cpp:2535`) | `LockTable::convert` | tested against the aggregate *excluding the converter's own contribution* |
| dequeue + `post_pending` regrant | `LockTable::dequeue` | walks the queue in order, stops at the first still-blocked head |
| the deadlock scan | `deadlock_from` | wait-for edges: a pending request waits for every incompatible granted holder; a cycle back to the requester denies the request |

Deliberately not converted in slice 1:

- **The shared-memory arena** (`SRQ` self-relative queues, hash
  slots, block recycling, `bcb_syncPrecedence`-style mutexes) — the
  transport under the policy.
- **Blocking ASTs** — the knock that crosses a process boundary when
  a holder must downgrade. The *decision* of who blocks whom is
  converted; the *delivery* is not.
- **Lock data words** (`lbl_data` / `LCK_write_data`) — a side
  channel some series use (e.g. the nbackup state lock in the
  paper's case study).
- **Timeouts** — a waiting verdict is returned to the caller;
  slice 1 has no clock.
- **Series semantics** — which of the 36 series a lock belongs to is
  opaque here, exactly as it is to the engine's own table.

<a name="matrix"></a>
## The compatibility matrix, and its famous cell

```text
           none  null   SR    PR    SW    PW    EX
   none     +     +     +     +     +     +     +
   null     +     +     +     +     +     +     +
   SR       +     +     +     +     +     +     -
   PR       +     +     +     +     -     -     -
   SW       +     +     +     -     +     -     -
   PW       +     +     +     -     -     -     -
   EX       +     +     -     -     -     -     -
```

The names read as promises about *others*, and two cells carry most
of the meaning:

- **SR + PW = compatible.** "Protected write" means *no other
  writers* — it does not mean no readers. A PW holder tolerates
  shared readers because MVCC isolates them: readers read committed
  record versions, and the writer's uncommitted work is invisible to
  them. This is the cell that makes Firebird's table reservations
  gentler than they sound, and the live gate proves it: a
  transaction holding `RESERVING T FOR PROTECTED WRITE` lets a
  `SHARED READ` reservation through without a murmur.
- **PR + SW = conflict.** "Protected read" means *nobody may write
  while I read* — a stronger claim than SR makes. Any writer, even a
  shared one, violates it.

`null` deserves its own note: it conflicts with nothing and exists to
**keep a name**. An owner holding LCK_null retains its registration
on the lock — and its right to be told (via AST, in later slices)
when someone wants the resource exclusively — without excluding
anyone. The engine uses null locks as existence-interest markers on
metadata objects.

<a name="aggregate"></a>
## The granted-state aggregate, and why it is sound

The engine never loops over holders to answer a request. Each lock
block maintains `lbl_counts[mode]` and a single `lbl_state` — the
highest granted mode — and the grant test is one probe:
`compatibility[requested][lbl_state]` (`lock.cpp:2228`).

At first sight this looks unsound, because matrix rows are **not
monotone** in the numeric mode order: SW (4) tolerates SW but not
PR (3), so "test against the highest" could in principle miss a
conflict with a *lower* granted mode. The saving invariant is that
the granted set is always **mutually compatible** — every pair of
granted modes passed the matrix when granted. Work through the only
dangerous shape: for the aggregate to hide a PR from an SW request,
the block would need PR granted *alongside* something numerically
higher that SW tolerates — but everything ≥ SW conflicts with PR, so
such a set can never be granted in the first place. The aggregate is
exactly as strong as the full scan *given the invariant the grant
path itself maintains*.

The crate keeps the same counts and the same single-probe test rather
than a per-holder scan, so its decisions flow from the engine's own
data structure — if the reasoning above were wrong, the live matrix
gate would say so.

<a name="verbs"></a>
## Enqueue, convert, dequeue: the three verbs

**Enqueue** (`LCK_lock`): probe the aggregate; grant and count, or —
if the caller waits — join the pending queue (after the deadlock scan
clears the wait), or — NO WAIT — reject leaving no trace. The
engine's error for the last is the one every Firebird user has met:
`lock conflict on no wait transaction`.

**Convert** (`LCK_convert`): a holder changes mode *in place*. The
test runs against the aggregate **excluding the converter's own
contribution** (`lock.cpp:2535` recomputes the state without the
requesting lrq): an SR holder beside another SR can convert to PW —
the other SR is compatible with PW — but the second SR cannot *also*
become a writer afterwards. A failed NO WAIT convert leaves the old
grant standing; nothing is lost by asking.

**Dequeue** (`LCK_release`): drop the grant, then run the engine's
`post_pending` sweep — walk the pending queue **in arrival order**,
granting while the head is compatible with the (recomputed)
aggregate, stopping at the first still-blocked request. Requests
behind a blocked head stay parked even if they would fit.

<a name="fifo"></a>
## FIFO fairness: the pending queue blocks late arrivals

The pending queue is not only for waiters — it also gates *new*
requests. A late arrival that is compatible with every granted holder
is still refused (or parked) if it is incompatible with someone
already waiting: granting it would starve the queue. The crate's
`fifo_blocks_late_compatible_requests_behind_the_queue` test pins the
canonical shape — SW granted, PR waiting, a second SW arrives: the
second SW would ride happily beside the first, but the waiting PR
blocks it. Without this rule a stream of readers could hold a writer
off forever (or vice versa); with it, the queue drains in order.

<a name="deadlock"></a>
## The deadlock scan

An owner with a pending request **waits for** every owner whose
granted, incompatible request sits on the same lock. Those edges form
the wait-for graph; the engine walks it (with visited marks and a
depth bound) when a request is about to wait, and if the walk leads
back to the requester, the request is denied with the deadlock error
instead of parking forever — the *scanning* request is the victim.

The crate's `deadlock_from` is the same walk: DFS over
pending→granted edges, cycle test against the starting owner, the
denied request withdrawn without a trace. The two-owner cycle — A
holds T1 and waits for T2, B holds T2 and asks for T1 — is pinned in
a unit test, and phase 3 of the gate reproduces it against the live
server with two fifo-fed attachments cross-updating two tables: the
engine's scan (which runs on a ~10-second cadence, `DeadlockTimeout`)
denies one of them with SQLSTATE 40001 `deadlock`, the same cycle the
crate denies synchronously with `Verdict::Deadlock`.

<a name="oracles"></a>
## The oracles

**The source pin.** `fclck pin-source <lock.cpp>` re-parses the
`compatibility[LCK_max][LCK_max]` initializer out of the vendored
engine source — tokenizing `true`/`false` between the declaration and
its closing brace — and diffs all 49 cells against the crate's
constant. A transcription slip (the recurring hazard of this project;
see the porting playbook) cannot survive the gate.

**The live matrix.** `SET TRANSACTION RESERVING <table> FOR <mode>`
acquires the relation lock *at transaction start* in exactly the
mode the words say (`tra.cpp`: shared read = LCK_SR, shared write =
LCK_SW, protected read = LCK_PR, protected write = LCK_PW). That
makes the lock table observable from SQL: session A holds a mode
through a fifo-fed `isql` attachment; session B probes all four modes
with `NO WAIT`; the engine answers silence or `lock conflict on no
wait transaction`, and every cell must equal `fclck compat B A`.
Sixteen live cells, engine-arbitrated — including SR-beside-PW
passing silently in both directions.

One environmental subtlety: the two attachments must share a lock
table, which the embedded engine here refuses (`Database already
opened with engine instance, incompatible`) — so the gate drives the
**real server** (`fbguard`/`firebird` on localhost), creating its
scratch database through the server so file ownership lands with the
server's user.

**The live deadlock.** Phase 3 above — the engine's own scan denying
a genuine cross-update cycle, matching the crate's verdict on the
same shape.

<a name="probes"></a>
## Probe log

- **SR/PW both ways, live**: holding PW, an SR `NO WAIT` reservation
  passes; holding SR, a PW reservation passes. The matrix's
  signature cell confirmed against the running engine before a line
  of the table was written.
- **Embedded refuses a second attachment** — the probe that
  redirected the whole gate through the real server (above).
- **The engine's deadlock latency** is the documented
  `DeadlockTimeout` cadence: the cross-update denial arrived ~10s
  after the cycle closed, inside the gate's 25s window.

<a name="slice2"></a>
## Slice 2: teardown, lock data, the blocking set

Three of the roadmap's six items landed, and one was re-scoped by a
live finding.

**Owner teardown** (`purge_owner`): every granted and pending
request the owner holds comes down, each affected lock regranting
its queue FIFO — the engine's purge on detach. The live
differential is phase 4 of the gate: A holds PROTECTED WRITE, B's
WAIT reservation parks behind it, A *detaches without committing* —
and B proceeds the moment the engine's purge releases A's locks,
exactly the release-all-and-regrant the crate's unit test pins.

**Lock data words** (`write_data`/`read_data`): the `lbl_data` side
channel — writing requires HOLDING the lock, anyone reads, an
absent lock reads zero. The probe found one live: a transaction
lock (series 4, `LCK_tra`) carrying `Data: 134` in this box's
`fb_lock_print` output — the mechanism in the wild, not just in the
nbackup case study.

**The blocking set** (`blockers`): the owners whose granted,
incompatible requests stand between a parked request and its grant —
exactly who would receive the blocking AST when delivery exists.
The decision layer is now data; the transport stays out.

**The re-scope**: fb_lock_print on this SuperServer shows NO
series-2 relation locks — relation arbitration lives in-process,
and the shared table carries only the cross-process series
(idx_rescan, dsql_cache, tra, attachment, monitor...). A structural
diff of relation locks against the dump is therefore not observable
here; the RESERVATION behavior (phases 2–4) remains the
relation-lock oracle, and the dump remains useful for the series
that do appear.

<a name="roadmap"></a>
## Roadmap

1. **AST delivery modeling** — surface `blockers` at wait time as
   an event the caller consumes.
2. **Timeouts** — `Waiting` verdicts with a deadline, and the lock
   timeout error distinct from the deadlock error.
3. **Series semantics** — bring `jrd/lck.cpp`'s typed layer over,
   so fire-crab's wire server can arbitrate two of ITS OWN
   attachments through this table.
4. **Cross-process-series dump differential** — the series that DO
   live in the shared table, compared structurally.
