# Subsystem map: C++ engine → paper document → Rust conversion

The conversion's chart. Each row links the C++ source directory, the
companion-paper document that explains it (the recommended reading *before*
the source), the planned crate, and the status. Order within phases is the
planned conversion order; the criterion is always "what can be
differential-tested next with the least new machinery" (see
[methodology.md](methodology.md)).

Paper document links are relative to
[conceptual-architecture-for-firebird-paper](https://github.com/mariuz/conceptual-architecture-for-firebird-paper).

## Phase 1 — storage, bottom-up (in progress)

| C++ source | Paper document | Crate / module | Status |
|---|---|---|---|
| `src/jrd/ods.h` (pag, header_page, tx_inv_page) | on-disk-structure.md | `fire-crab-ods` {pages, header, tip} | **done** — differential vs gstat, 123 dbs |
| `src/jrd/sqz.cpp` (record RLE) | on-disk-structure.md § records | `fire-crab-ods::sqz` | **done** — round-trip incl. FB4 forms |
| `src/jrd/ods.h` (page_inv_page / PIP) | on-disk-structure.md | `fire-crab-ods::pip` | **done** — bitmap + capacity formula tested |
| `src/jrd/ods.h` (pointer_page, data_page, rhd/rhde + flags) | on-disk-structure.md, transactions-and-concurrency.md | `fire-crab-ods::{pointer,data}` | **done** — record walk diffs vs live SELECT COUNT(*) (qa/diff-select.sh), 0 to 200k rows OK |
| record field decode via RDB$FORMATS | on-disk-structure.md, metadata-cache.md, catalog-bootstrap.md | `fire-crab-ods::format` | **done** — descriptors, null bitmap, dtype decode, blob-id resolution + level 0/1 segmented blob assembly, hardcoded system format for the bootstrap; full-row differential vs live SELECT (qa/diff-rows.sh) |
| `src/jrd/btr.cpp`, `btn.h` / index_root_page + btree_page + node encoding | indexing-and-full-text-search.md | `fire-crab-ods::btr` | **done** — leaf-level walk with prefix decompression; index-order differential vs live ORDER BY (qa/diff-index.sh), identical order at 200k rows through a multi-level tree |
| `src/jrd/blb.cpp` / blob_page | blob-handling.md | `fire-crab-blb` | planned |

## Phase 2 — the transaction system

| C++ source | Paper document | Crate | Status |
|---|---|---|---|
| `src/jrd/tra.cpp` TIP chain, `vio.cpp` version rules, `sqz.cpp` deltas | transactions-and-concurrency.md | `fire-crab-ods::tra` | **done** — TIP-chain state lookup, delta back-version reconstruction (Difference::apply), committed-only MVCC visibility walk; differential vs live SELECT on a file frozen mid-uncommitted-work (qa/diff-mvcc.sh) |
| `src/jrd/vio.cpp` GC/sweep (VIO_chase_record_version, cannotGC vio.cpp:1663) | garbage-collection-and-sweep.md | `fire-crab-ods::gc` | **done** — classifies collectable versions (expunge path + back-chain path) against the oldest-snapshot threshold; prediction differential vs live `gfix -sweep` (qa/diff-sweep.sh), predicted removal == actual removal, 210 versions across both paths |
| `src/lock/lock.cpp` | lock-manager.md | `fire-crab-lck` | planned |

## Phase 3 — cache and physical I/O

| C++ source | Paper document | Crate | Status |
|---|---|---|---|
| `src/jrd/cch.cpp` (page cache, latching) | page-cache-coherency.md, careful-writes-and-crash-safety.md | `fire-crab-cch` | planned — careful-writes precedence is THE correctness gate; crash-harness differential (kill mid-write, compare recovery) |
| `src/jrd/pag.cpp`, `src/jrd/pio_unix.cpp` | on-disk-structure.md | `fire-crab-pio` | planned |

## Phase 4 — language: BLR, DSQL, the executor

| C++ source | Paper document | Crate | Status |
|---|---|---|---|
| BLR decode (`par.cpp` structure, `blp.h` + gds.cpp operand table) | blr-intermediate-language.md | `fire-crab-ods::blr` | **done** — operand-atom walker + verb table (171 verbs) converted from the engine's own printer; verb-token differential vs isql `SET BLOB ALL` (qa/diff-blr.sh), every decodable blob matches token-for-token, unknown verbs reported not guessed |
| `src/dsql/` (SQL → BLR) | grammar-and-parser.md, dsql docs | `fire-crab-dsql` | planned |
| `src/jrd/exe.cpp`, rse execution | query-optimizer-and-execution.md, request-lifecycle-code-trace.md | `fire-crab-exe` | planned |
| optimizer | query-optimizer-and-execution.md | `fire-crab-opt` | planned — differential via RDB$SQL.EXPLAIN output on identical statistics |

## Phase 5 — the outside faces

| C++ source | Paper document | Crate | Status |
|---|---|---|---|
| wire protocol `src/remote/` + SRP `src/auth/SecureRemotePassword/` | firebird-wire-protocol.md, security-architecture.md | `fire-crab-wire` | **fire-crab logs in** — XDR framing, op_connect negotiation, SRP-256 authentication (from-scratch SHA-1/SHA-256/bignum-modpow, proof M pinned to the reference), Arc4 wire encryption, op_attach/op_detach, all over real TCP. Differentials: negotiated version matches the reference clients (qa/diff-wire.sh); the engine records the attachment as Srp256/Arc4 and rejects wrong credentials with isc_login (qa/diff-login.sh). **The statement pipeline works**: op_transaction, op_allocate_statement, op_prepare_statement, op_execute, op_fetch, op_free_statement, op_commit, over the encrypted channel; a single-BIGINT query round-trips and its decoded value matches isql (qa/diff-query.sh). This is the firebird-qa entry threshold. The pipeline is pinned to protocol 13's message format for now (login still negotiates 20); broadening to more column types and statement kinds, and running the pytest suite itself, is the ongoing work. |
| services (`src/jrd/svc.cpp`) | services-api.md | `fire-crab-svc` | planned |
| events (`src/jrd/event.cpp`) | firebird-events.md | `fire-crab-evt` | planned |
| security (`src/auth/`) | security-architecture.md | `fire-crab-auth` | planned — Srp reference implementations exist in three languages in the paper's samples |

## Reference material per row

For every subsystem above, the paper repo also carries **verified hands-on
samples in five languages** (C++ OO-API, fb-cpp, node-firebird, rsfbclient,
fbintf) whose outputs are known-good expected values for differential tests —
e.g. the blr samples' byte dumps, the transactions samples' conflict error
chains, and the on-disk samples' header/census values used by this repo's QA
today.
