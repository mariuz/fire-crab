-- Firebird 6.0: a WHERE IN-subquery misses a 0 when a NULL precedes it
-- in the subquery result (HashJoin SEMI: NULL and 0 share a hash key).
--
-- Run:   isql -q -user SYSDBA -pas masterkey -i firebird-hashjoin-semi-null-zero.sql
-- Edit the CREATE DATABASE path/credentials for your server first.

CREATE DATABASE 'localhost:/tmp/hashjoin_semi_null_zero.fdb'
  USER 'SYSDBA' PASSWORD 'masterkey';

CREATE TABLE T (ID INTEGER, N INTEGER);
COMMIT;
INSERT INTO T VALUES (1, NULL);   -- the NULL must come first in storage order
INSERT INTO T VALUES (2, 0);
COMMIT;

SET PLAN ON;

-- BUG: expected one row (ID = 2), because row 2's N = 0 is in the set.
--      Actual: no rows.  Plan: HASH ("T" NATURAL, "T" NATURAL)
SELECT ID FROM T WHERE N IN (SELECT N FROM T);

-- BUG, same cause: the correlated EXISTS is planned as the same HASH
-- semi-join.  Expected ID = 2.  Actual: no rows.
SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T T2 WHERE T2.N = T.N);

SET PLAN OFF;

-- The engine itself says the predicate is TRUE for row 2:
SELECT ID, IIF(N IN (SELECT N FROM T), 'TRUE', 'NOT TRUE') AS R FROM T;

-- Each of these returns ID = 2, as expected:
SELECT ID FROM T WHERE N IN (SELECT N FROM T) OR 1 = 0;               -- no semi-join rewrite
SELECT ID FROM T WHERE N IN (SELECT N FROM T ORDER BY N DESC);        -- 0 before the NULL
SELECT ID FROM T WHERE N IN (SELECT COALESCE(N, -1) FROM T);          -- no NULL in the set

-- A non-zero value behind the NULL is found (only 0 collides with NULL):
UPDATE T SET N = 5 WHERE ID = 2;
SELECT ID FROM T WHERE N IN (SELECT N FROM T);                        -- returns 2
ROLLBACK;

DROP DATABASE;
