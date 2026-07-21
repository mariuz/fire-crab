# Conversion methodology

How fire-crab converts Firebird's C++ to Rust, written down as it is done —
including the decisions that could have gone the other way.

## 1. Why bottom-up from the storage layer

Conversions of large systems fail at the *validation* step, not the writing
step. So the ordering criterion is: **convert first what can be tested against
the live C++ engine with the least machinery.**

The on-disk structure is the best possible start:

- The C++ engine mass-produces test vectors: every `.fdb` file is one, and the
  companion paper's hands-on samples generate dozens with known content.
- The reference implementation ships its own oracle (`gstat`, and `MON$`
  queries for the same values through SQL).
- The layouts are *pinned in the C++ source itself* by `static_assert`s
  (`src/jrd/ods.h:258` onward) — a machine-checked spec to mirror.
- Nothing above it (cache, transactions, execution) can be converted honestly
  before the bytes they operate on can be read.

The sequence within the storage layer: generic page header → database header →
TIP → **(next)** PIP → pointer pages → data pages and the record walk → index
(B-tree) pages → blob pages. Each step unlocks a new differential test against
the engine (e.g. the record walk diffs against `SELECT` output; the B-tree walk
against index scans).

## 2. The C++-to-Rust mapping rules

Rule set used so far, to be extended as new constructs appear:

| C++ construct | Rust conversion | Why |
|---|---|---|
| `struct pag` overlay-cast onto a buffer | explicit little-endian field reads (`u16_at`/`u32_at`/`u64_at`) at documented offsets | no `unsafe`, no alignment traps, endianness explicit; the offsets are pinned by tests instead of by the cast |
| `static_assert(offsetof(...))` | a unit test decoding a synthetic buffer with a distinct value at every offset | same guarantee, and it also catches transposed *reads*, which offsetof cannot |
| `USHORT`/`ULONG`/`FB_UINT64`/`SCHAR` | `u16`/`u32`/`u64`/`i8` | exact width, no platform variance |
| enum-like `inline constexpr` families (`pag_*`, `tra_*`) | a real `enum` with `from_byte` returning `Option` | invalid bytes become `None`, not UB; `name()` replaces scattered switch statements |
| functions returning `0` for errors (`Compressor::unpack`) | `Option`/`Result` | the C++ convention loses the error site; keep the *behaviour* (reject truncated streams) but not the convention |
| pointer arithmetic over buffers | slice indexing and `chunks_exact` | bounds become checked; the optimizer removes what it can prove |

Two rules about fidelity:

- **Convert behaviour, not style.** `sqz::unpack` accepts exactly the streams
  `Compressor::unpack` accepts, including the Firebird 4+ `-1`/`-2` extended
  run forms and the truncated-stream error path — but it returns
  `Option<Vec<u8>>`, not a zero with an out-parameter.
- **Cite the source.** Every module and non-obvious constant carries the
  C++ file:line it came from. When the engine changes, `grep` finds what to
  re-verify.

## 3. The validation ladder

Each converted unit climbs as many rungs as its nature allows:

1. **Layout tests** — synthetic buffers, one distinct value per field
   (mirrors of the C++ `static_assert`s).
2. **Round-trip tests** — where the unit has both directions (sqz pack/unpack),
   including pseudorandom data and malformed-input rejection.
3. **Real-artifact tests** — decode actual files the C++ engine wrote.
4. **Differential tests** — compare output field-for-field against the C++
   engine's own tooling on the same artifact (`qa/diff-gstat.sh`; currently
   123 databases, zero diffs).
5. **Conformance suite** — the
   [firebird-qa](https://github.com/FirebirdSQL/firebird-qa) pytest suite,
   which drives a *server*; applicable only once fire-crab exposes the wire
   protocol or an embedded API. Tracked in
   [qa-and-benchmarks.md](qa-and-benchmarks.md); not claimable today, and the
   docs say so rather than gesturing at it.

## 4. What the first slice taught (kept honest)

- **The engine's own asserts are the best spec.** Mirroring
  `ods.h`'s `static_assert` block as decode tests caught an off-by-two on the
  first attempt at `hdr_ods_minor` before any real file was read.
- **Benchmarks lie by default.** The first census benchmark reported
  "2 TB/s" — it spans 8 KB per page but *reads one byte of it*. The metric was
  changed to pages/s and the caveat written into the tool. Similarly, `fcstat
  header` originally read the whole file to decode one page and lost the
  wall-clock comparison to `gstat` for a silly reason; tools being compared
  must do comparable work.
- **The paper-first workflow works.** Reading the companion
  [on-disk-structure document](https://github.com/mariuz/conceptual-architecture-for-firebird-paper/blob/master/on-disk-structure.md)
  before `ods.h` meant the C++ read like an implementation of something already
  understood, not a puzzle. This is the intended loop for every subsystem:
  paper document → hands-on sample outputs as expected values → C++ source →
  Rust conversion → differential test.

## 5. Ground rules going up the stack

Decisions made now to avoid re-litigating them per subsystem:

- **`unsafe` policy**: none in decoding paths. If a hot path ever justifies an
  overlay read, it goes behind a safe API with the checked implementation kept
  as the differential reference.
- **No async runtime** in the engine core. Firebird's threading model
  (per-attachment workers, cooperative scheduling in `tdbb`) is explicit; the
  conversion keeps it explicit with `std` threads until measurement — not
  fashion — argues otherwise.
- **Dependencies**: the core crates stay dependency-free as long as possible;
  every crate pulled in is a supply-chain and audit cost the C++ engine does
  not have.
- **Compatibility target**: ODS 14 (Firebird 6) little-endian only, matching
  modern Firebird's own support matrix. Older ODS versions are explicitly out
  of scope until the current one is complete.
