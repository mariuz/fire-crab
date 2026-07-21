# fire-crab 🔥🦀

An incremental conversion of the [Firebird](https://github.com/FirebirdSQL/firebird)
database engine from C++ to Rust — started bottom-up from the storage layer,
tested differentially against the real engine from the first commit.

## What this is (and is not)

Firebird's engine is on the order of a million lines of C++ with thirty years
of accumulated correctness. **fire-crab is not a rewrite announcement** — it is
a methodical conversion experiment with three rules:

1. **Every converted piece must be verifiable against the C++ engine today** —
   not "when the project is finished". The first slice decodes real database
   files written by Firebird 6 and is diffed field-for-field against `gstat`
   on every database we can generate.
2. **The C++ source is the specification.** Every Rust struct, constant and
   algorithm carries a pointer to the file and line it was converted from, and
   the C++ `static_assert`s that pin on-disk layouts are mirrored as Rust
   tests.
3. **Documented as it happens.** The conversion steps, the decisions, and the
   dead ends live in [docs/methodology.md](docs/methodology.md); the map from
   engine subsystems to conversion status lives in
   [docs/subsystem-map.md](docs/subsystem-map.md).

The project grew out of
[a conceptual-architecture paper on Firebird](https://github.com/mariuz/conceptual-architecture-for-firebird-paper)
whose 43 subsystem documents (each with verified hands-on samples in five
languages) serve as the conversion's guidebook: each subsystem document tells
the converter what the C++ is *doing* before they read a line of it.

## Status

| Area | Crate | Status |
|---|---|---|
| ODS page structures (header, generic page, TIP) | `fire-crab-ods` | **converted + differential-tested** |
| Record RLE compression (`sqz.cpp`, incl. FB4 extended runs) | `fire-crab-ods` | **converted + round-trip-tested** |
| Page-type census / `gstat`-style tool | `fcstat` | **working** |
| PIP, pointer pages, data pages + record-version walk | `fire-crab-ods` | **converted + differential-tested vs live SELECT** |
| Record field decoding (RDB$FORMATS bootstrap, blob assembly) | `fire-crab-ods::format` | **converted + full-row differential vs live SELECT** |
| B-tree index pages + node encoding (`btn.h`) | `fire-crab-ods::btr` | **converted + index-order differential vs live ORDER BY** |
| Transaction system: TIP chain, delta versions, MVCC visibility (`tra.cpp`/`vio.cpp`) | `fire-crab-ods::tra` | **converted + committed-only-visibility differential vs live SELECT** |
| Garbage-collection / sweep analysis (`vio.cpp`) | `fire-crab-ods::gc` | **converted + prediction differential vs live `gfix -sweep`** |
| BLR intermediate language (`par.cpp`, `blp.h`) | `fire-crab-ods::blr` | **converted + verb-token differential vs the engine's own BLR printer** |
| Wire protocol - client: login + general SELECT (`src/remote/`, `src/auth/`) | `fire-crab-wire` | **fire-crab runs multi-column, multi-row SELECTs** matching isql row-for-row (integer + text). Validates the wire codec against the real C++ server |
| Wire protocol - server: accept + SRP-256 + attach + statement pipeline | `fire-crab-wire::server` | **a real third-party client (node-firebird) authenticates, arms Arc4 wire encryption, attaches and runs a query end-to-end against fire-crab**; the C++ `isql` authenticates and attaches too (see below) |
| Real query execution: `SELECT COUNT(*) FROM <table>` from pages | `fire-crab-wire::server` + `fire-crab-ods::catalog` | **the server answers a real query from the database file** - resolves the table name through `RDB$RELATIONS` and counts committed records from the data pages; over the wire, node-firebird's count matches isql exactly on user and system tables |
| Everything else | — | see [docs/subsystem-map.md](docs/subsystem-map.md) |

**On the firebird-qa milestone, precisely.** firebird-qa drives a *server*,
so the suite only becomes applicable once fire-crab can *accept* connections,
not just make them. Both halves now exist:

- **Client** (`fire-crab-wire`): connects to the running C++ engine; every
  query is checked against isql. This validated the wire codec (XDR, SRP-256,
  the message/BLR formats) end-to-end against the real server first.
- **Server** (`fire-crab-wire::server`): accepts TCP connections and speaks
  the same protocol the C++ `src/remote/` server does. **node-firebird - an
  independent, third-party client library with no fire-crab code in it -
  negotiates protocol 20, authenticates via the server half of SRP-256
  (no password on the wire), arms Arc4 wire encryption with the derived
  session key, attaches, and drives the full statement pipeline
  (transaction → allocate → prepare → execute → fetch), decoding the
  returned value correctly.** The C++ `isql` client authenticates via
  SRP-256 and attaches as well, then drives its richer post-attach ops
  (op_cancel, op_info_database) until it reaches op_exec_immediate.

The server now answers a **real query** from the database file the client
attaches to: `SELECT COUNT(*) FROM <table>` resolves the table name through
`RDB$RELATIONS` (read straight from its data pages by `fire-crab-ods::catalog`)
and counts the committed records - and over the encrypted wire, node-firebird's
result matches isql exactly on every user and system table tested. This is the
first op dispatched into the converted `ods` engine internals rather than
answered by a constant; other statement shapes still fall back to the fixed
value. Widening the SQL surface (projections, real column types, WHERE) is the
work that continues from here - but the fixed answer is no longer fixed. The
protocol server it runs on is proven against a genuine client.

Current QA state: `fcstat header` output is **byte-identical on the compared
fields with `gstat -h` across 123 real Firebird 6 databases** (every scratch
database generated by the paper's hands-on samples), and the record walk now decodes **full rows from raw pages** — RDB$FORMATS
bootstrap (the system format hardcoded, exactly like the engine's own
bootstrap), blob-id resolution through the record-number formulas, segmented
blob assembly, descriptor-driven field decode — **matching live
`SELECT` output value-for-value** on every compared column of every table
tested, from 0 to 200,000 rows. See
[docs/qa-and-benchmarks.md](docs/qa-and-benchmarks.md) for the numbers and the
honest caveats attached to them.

## Quick start

```sh
cargo test                                   # layout + round-trip tests
cargo build --release
./target/release/fcstat header  /path/to/db.fdb
./target/release/fcstat census  /path/to/db.fdb
./target/release/fcstat tip     /path/to/db.fdb

# differential QA against the C++ engine's gstat:
GSTAT=/opt/firebird/bin/gstat qa/diff-gstat.sh /path/to/*.fdb

# C++-vs-Rust timing on the same file:
GSTAT=/opt/firebird/bin/gstat bench/compare.sh /path/to/db.fdb
```

## Layout

- `crates/ods` — the conversion itself, one module per converted C++ unit,
  each headed by a comment naming its source (`ods.h`, `sqz.cpp`, `tra.h`).
- `crates/fcstat` — the inspector tool that makes the conversion observable.
- `qa/` — differential testing against the C++ engine (and the plan for
  adopting the [firebird-qa](https://github.com/FirebirdSQL/firebird-qa)
  suite once a wire-protocol milestone makes it applicable).
- `bench/` — C++-vs-Rust measurements with their caveats attached.
- `docs/` — methodology, subsystem map, QA strategy.

## License

The conversion follows the code it converts: Initial Developer's Public
License (IDPL), compatible with Firebird's IPL/IDPL licensing.
