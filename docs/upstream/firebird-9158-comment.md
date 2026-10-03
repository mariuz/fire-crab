A deterministic, two-row reproduction of the same SEMI-join defect, on plain `INTEGER` keys and with default settings on Firebird 6.0. It's caused by a second, non-random key collision: a `NULL` key and a `0` key always hash to the same value.

**Environment:** Firebird 6.0.0 (`LI-T6.0.0.2179`, source `master` @ `84f30a54c6`), default `firebird.conf`. In this 6.0 source I can't find a `SubQueryConversion` setting: `RseNode::processPossibleJoins` converts `IN`/`EXISTS` without a config check, so on 6.0 this is reachable out of the box.

```sql
CREATE TABLE T (ID INTEGER, N INTEGER);
COMMIT;
INSERT INTO T VALUES (1, NULL);   -- the NULL must come first
INSERT INTO T VALUES (2, 0);
COMMIT;

SET PLAN ON;
SELECT ID FROM T WHERE N IN (SELECT N FROM T);
-- PLAN HASH ("PUBLIC"."T" NATURAL, "PUBLIC"."T" NATURAL)
-- expected: 2    actual: no rows

SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T T2 WHERE T2.N = T.N);
-- PLAN HASH ("PUBLIC"."T" NATURAL, "T2" NATURAL)
-- expected: 2    actual: no rows
```

The engine gives the right answer for the same predicate any other way:

- `SELECT ID, IIF(N IN (SELECT N FROM T), 'TRUE', 'NOT TRUE') FROM T` → row 2 is `TRUE`
- `... WHERE N IN (SELECT N FROM T) OR 1 = 0` (no semi-join) → `2`
- `... WHERE N IN (SELECT N FROM T ORDER BY N DESC)` (the `0` streamed before the `NULL`) → `2`
- `... WHERE N IN (SELECT COALESCE(N, -1) FROM T)` (no `NULL`) → `2`
- with row 2 holding `5` instead of `0` → `2` (only `0` collides with `NULL`)

It also reproduces on `NUMERIC` and `DOUBLE PRECISION` columns and with `= ANY (...)`.

**Why `NULL` and `0` collide:** `HashJoin::computeHash()` starts with `memset(keyBuffer, 0, sub.totalKeyLength)`. When a key expression evaluates to `NULL` (`EVL_expr()` returns `nullptr`), nothing is written, so the key stays all-zero bytes. That's identical to a numeric `0`, whose key is also all-zero (and floating-point zero is explicitly normalised to `+0`). The `NULL` row and the `0` row therefore always share a hash. The semi-join's first-candidate-only iteration, analysed above, then offers only the `NULL` row to the residual `N = N`, which is not TRUE, and the matching `0` behind it is never examined.

The SEMI iteration fix discussed here should cover this case too. Separately, encoding `NULL` distinctly in the key (or keeping `NULL` keys out of the hash table for equality joins, cf. #7769) would remove this collision at the source.

Found with the fire-crab differential test suite, which runs the same statements against a live Firebird 6 server and a re-implementation and flags any difference.
