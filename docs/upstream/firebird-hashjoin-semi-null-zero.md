# Upstream issue draft — Firebird: a semi-join `IN` / `EXISTS` misses a match on `0` when a `NULL` precedes it

**Status:** REPORTED 2026-10-03 as a comment on the existing upstream issue **[FirebirdSQL/firebird#9158](https://github.com/FirebirdSQL/firebird/issues/9158)** ("Incorrect result HASH SEMI JOIN with UUID key") — the same SEMI-join first-candidate defect, there triggered by random UUID hash collisions; this report adds a deterministic two-row INTEGER trigger (NULL and 0 share a key) and notes that 6.0 has no `SubQueryConversion` gate. Comment: <https://github.com/FirebirdSQL/firebird/issues/9158#issuecomment-5965771034> (text: [`firebird-9158-comment.md`](firebird-9158-comment.md)). Related: [#7769](https://github.com/FirebirdSQL/firebird/issues/7769). The draft below was kept as the full write-up.
**Target:** <https://github.com/FirebirdSQL/firebird/issues>
**Repro script:** [`firebird-hashjoin-semi-null-zero.sql`](firebird-hashjoin-semi-null-zero.sql) (self-contained; creates and drops its own database)

---

## Title

Wrong result: `WHERE x IN (SELECT ...)` / correlated `EXISTS` loses a `0` match when a `NULL` precedes it in the hash-joined stream (NULL and 0 get the same hash key)

## Environment

- Server: Firebird 6.0.0 (`RDB$GET_CONTEXT('SYSTEM','ENGINE_VERSION')` = `6.0.0`), isql `LI-T6.0.0.2179 Firebird 6.0 1c9d56b`
- Source inspected: `master` at `84f30a54c6` (2026-09-23)
- Linux x86-64, SuperServer, default configuration

## Minimal reproduction

```sql
CREATE TABLE T (ID INTEGER, N INTEGER);
COMMIT;
INSERT INTO T VALUES (1, NULL);   -- the NULL must come first
INSERT INTO T VALUES (2, 0);
COMMIT;

SET PLAN ON;
SELECT ID FROM T WHERE N IN (SELECT N FROM T);
-- PLAN HASH ("PUBLIC"."T" NATURAL, "PUBLIC"."T" NATURAL)
-- Expected: ID = 2      Actual: no rows

SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T T2 WHERE T2.N = T.N);
-- PLAN HASH ("PUBLIC"."T" NATURAL, "T2" NATURAL)
-- Expected: ID = 2      Actual: no rows
```

Row 2 has `N = 0`, and `0` is in the subquery's result, so row 2 must qualify.

## The engine contradicts itself

The same predicate evaluated any other way gives the correct answer:

| Statement | Result |
|---|---|
| `SELECT ID, IIF(N IN (SELECT N FROM T), 'TRUE', 'NOT TRUE') FROM T` | row 2 → **TRUE** |
| `... WHERE N IN (SELECT N FROM T) OR 1 = 0` (no semi-join rewrite) | **2** |
| `... WHERE N IN (SELECT N FROM T ORDER BY N DESC)` (0 streamed before NULL) | **2** |
| `... WHERE N IN (SELECT COALESCE(N, -1) FROM T)` (no NULL in the set) | **2** |
| after `UPDATE T SET N = 5 WHERE ID = 2`: `... WHERE N IN (SELECT N FROM T)` | **2** |

Only the value `0` is affected, and only when a `NULL` precedes it in the inner stream. It reproduces for `INTEGER`, `NUMERIC` and `DOUBLE PRECISION` columns, and for `= ANY (...)`.

## Analysis

From `src/jrd/recsrc/HashJoin.cpp`:

1. **NULL and 0 share a key.** `HashJoin::computeHash` starts with `memset(keyBuffer, 0, sub.totalKeyLength)`. When a key expression evaluates to NULL (`EVL_expr` returns `nullptr`), nothing is written, so the key bytes stay all-zero. That's byte-identical to the key of a numeric `0`, which the code also normalises to all-zero bytes for floating-point zero. The two rows land in the same hash slot.
2. **A semi-join offers only the first candidate.** In `HashJoin::internalGetRecord`, for `JoinType::SEMI` the first collision fetched sets `irsb_mustread`, and the leader advances to its next record. Only that one candidate reaches the residual join condition (`N = N`). Here the candidate is the NULL row, `0 = NULL` is UNKNOWN, and the leader row is rejected. The genuine `0` behind it is never examined.

An INNER hash join is not affected in the same way, because it keeps iterating collisions until the residual succeeds.

Possible directions (for the maintainers to judge):

- Give NULL its own key encoding, for example a null-indicator byte per key segment, so NULL never collides with a real value. For equality joins a NULL key can never match, so NULL inner rows could also be left out of the hash table entirely, and a NULL leader key could skip the probe.
- Or, for SEMI and ANTI joins, keep iterating the collision list until the residual condition is TRUE, instead of stopping at the first hash match. That would also protect against genuine 32-bit hash collisions between different values, which (by the same reading, unverified) could lose a match the same way.

## Workaround

Defeat the semi-join rewrite (`... OR 1 = 0`), exclude NULLs from the subquery (`WHERE N IS NOT NULL` / `COALESCE`), or rewrite as a join.

## How it was found

The fire-crab differential suite (a Rust re-implementation of the engine checked statement-by-statement against a live Firebird 6 server) answered row 2. The engine's answer was traced to the hash semi-join described above. It's pinned in fire-crab as a recorded divergence (`qa/serve-real-nanrow.sh`, section 6) that will fail when the engine is fixed.
