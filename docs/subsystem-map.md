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
| `src/dsql/` (SQL → BLR) | grammar-and-parser.md, dsql docs | `fire-crab-dsql` | **thirteen slices converted + differential-tested against THREE of the engine's own oracles** — the view-shaped SELECT compiles to BYTE-IDENTICAL BLR, verified against `RDB$VIEW_BLR` (the artifact the engine's DSQL itself stores for the same statement). Covered: WHERE booleans (AND/OR/NOT with the engine's De-Morgan folding, comparisons, IS NULL, BETWEEN, LIKE), VALUE EXPRESSIONS (add/subtract/multiply/divide/negate/concatenate — a sign before a numeric literal folds into it), IN lists (blr_in_list + u16 count; NOT IN keeps blr_not), MULTI-STREAM RSEs (comma-FROM and INNER JOIN ... ON as a nested blr_join), aliases (blr_relation2, the alias UPPERCASED IN DOUBLE QUOTES), qualified fields by context (bare fields in multi-stream refuse — catalog-free), OUTER JOINS (blr_join_type 1/2/3 after the streams; absent for INNER), JOIN CHAINS (left-nested: each join node holds the previous as its first stream slot), INT64 literals (blr_int64), and the first BUILT-IN FUNCTIONS: UPPER/LOWER, CHAR_LENGTH/OCTET_LENGTH (blr_strlen + length-type byte), SUBSTRING (0-based start compiled as an UNFOLDED subtract(from,1)), TRIM (where + spec bytes) — an unknown name before `(` refuses, never a field — and CAST (blr_cast + probed dsc layouts: NUMERIC(p≤4) short but DECIMAL(p≤9) always long) with the CONDITIONALS: searched CASE/IIF = ONE blr_cast over a blr_value_if chain typed by the probed unification law (max int-digits + min scale, dtype that fits — long⁰∪long⁻¹ widens to int64), simple CASE = blr_decode, COALESCE = blr_coalesce (both wrapper-free), NULLIF = cast(value_if(a=b, NULL, a)) typed from its branches only; field branches under a cast wrapper refuse — and the SUBQUERY PREDICATES: EXISTS = blr_any over one rse (subquery WHERE = its boolean, select list traceless), SINGULAR = blr_unique, IN (SELECT)/ANY/SOME/ALL = blr_ansi_any/_all with a double-nested rse (the outer rse's single stream IS the subquery's rse; the comparison is the outer rse's boolean); negation flips the quantifier and inverts the comparison (NOT IN = ansi_all+neq); subquery streams join the context numbering but stay invisible to outer bare names — plus DISTINCT (blr_project: the one place the select list leaves a trace), scalar subselects (blr_via(blr_singular(rse), value, null)), derived tables (an rse in the stream slot, alias text `"X" "PUBLIC"."T"`, ONE shared context), and UNION [ALL] (blr_union stream with per-branch rse + blr_map; distinct form adds blr_project over blr_fid) (qa/dsql-view-blr.sh, 127 checks incl. refusals). Slice 7 opened oracle number two — `RDB$PROCEDURE_BLR`: `compile_procedure` emits a whole `FOR SELECT ... DO SUSPEND` body byte-identically (message with dsc+null-flag pairs and the EOF short, declares with NULL-inits, stall, labels, blr_for whose stream is CONTEXT 0 — procedures number from 0, views from 1 — ORDER BY as blr_sort asc/desc after the boolean, twin sends via blr_parameter2), unlocking what views cannot hold — and AGGREGATES + GROUP BY: blr_aggregate as a STREAM with its own context over the source rse (WHERE stays the source's boolean), blr_group_by in clause order vs blr_map in select-list order (probed to differ), agg verbs 0x53–0x57/0x5D, HAVING as the outer rse's boolean over blr_fid slots (equal aggregates REUSE their map slot, fresh ones append), ORDER BY sorting fids — and INPUT PARAMETERS: message 0 (dsc + null-flag pairs, no EOF slot), the loop under blr_receive 0, `:name` compiling to blr_parameter2(0, 2i, 2i+1) straight as a value anywhere in the FOR select — plus the SINGULAR `SELECT INTO` (blr_for over blr_singular, no label 1, SUSPEND a sibling send), FIRST/SKIP (rse sub-clauses between streams and boolean), and the DISTINCT aggregate verbs (COUNT/SUM/AVG dedicated; MIN/MAX fold to plain) (qa/dsql-proc-blr.sh, 48 checks incl. refusals). Slice 11 opened oracle number three — `RDB$TRIGGER_BLR`: compile_trigger emits whole trigger bodies byte-identically (the leanest wrapper: begin, label 0, DOUBLE begin, statements, three ends; OLD=ctx 0, NEW=ctx 1 as pseudo-streams; assignments, IF with a bare blr_end for a missing ELSE, nested blocks as double begins; the header leaves no BLR trace) — and THE DML VERBS: INSERT = blr_store(relation, assignments, column list required), DELETE = blr_for over a marks(1,4)-stamped rse + blr_erase, UPDATE = the same loop + blr_modify(org, new) with the new-record context allocated BEFORE the rse stream's; SET targets write new, sources and WHERE read org — and PSQL CONTROL: DECLARE [VARIABLE] with initialisers (triggers group declares-then-inits; procedures interleave — both probed), local-variable reads/assignments (blr_variable), WHILE = label N + blr_loop + if(cond, body, blr_leave N) with encounter-ordered labels, INSERTING/UPDATING/DELETING = eql(blr_internal_info(6), 1/2/3) composing under NOT/AND/OR (qa/dsql-trig-blr.sh, 34 checks incl. refusals). The interpreted SQL surface inside `fire-crab-wire::server` (expressions, functions, CASE, predicates, DML, DDL, PSQL) remains its own path, documented source-by-source in [expression-surface.md](expression-surface.md); the two meet as this crate grows toward full statement compilation |
| `src/jrd/exe.cpp`, rse execution | query-optimizer-and-execution.md, request-lifecycle-code-trace.md | `fire-crab-exe` | planned |
| optimizer | query-optimizer-and-execution.md | `fire-crab-opt` | planned — differential via RDB$SQL.EXPLAIN output on identical statistics |

## Phase 5 — the outside faces

| C++ source | Paper document | Crate | Status |
|---|---|---|---|
| wire protocol `src/remote/` + SRP `src/auth/SecureRemotePassword/` | firebird-wire-protocol.md, security-architecture.md | `fire-crab-wire` | **fire-crab logs in** — XDR framing, op_connect negotiation, SRP-256 authentication (from-scratch SHA-1/SHA-256/bignum-modpow, proof M pinned to the reference), Arc4 wire encryption, op_attach/op_detach, all over real TCP. Differentials: negotiated version matches the reference clients (qa/diff-wire.sh); the engine records the attachment as Srp256/Arc4 and rejects wrong credentials with isc_login (qa/diff-login.sh). **The statement pipeline works**: op_transaction, op_allocate_statement, op_prepare_statement, op_execute, op_fetch, op_free_statement, op_commit, over the encrypted channel; a single-BIGINT query round-trips and its decoded value matches isql (qa/diff-query.sh). General multi-column, multi-row SELECTs (integer + text) now match isql row-for-row (qa/diff-wire-select.sh). **Framing correction:** this is a wire *client* of the C++ engine - it validates the wire codec (XDR, SRP-256, message/BLR formats) against the real server, and is the groundwork every op the server side needs. firebird-qa drives a *server*, so the suite becomes applicable only once the SERVER half is converted (accept, server-side SRP, op dispatch into the engine). That is the honest next milestone; the client proves the protocol understanding it will be built on. |
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
