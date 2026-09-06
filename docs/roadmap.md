# Roadmap

*Live document. The narrative of how every closed item got closed is in
`docs/roadmap-history.md` (frozen 2026-08-20) and in the commit and gate
named beside it.*

fire-crab, 2026-08-20: a Rust conversion of the Firebird 6 engine —
123k lines across 14 crates (`ods` 22.7k, `dsql` 12k, `burp` 5.1k,
`exe`, `opt`, `lck`, `svc`, `auth`, `cch`, `pio`, `blb`, `evt`,
`fcstat`, and the `wire` server at 67k). The server answers real SQL
over the real wire protocol, and every answer is held DIFFERENTIALLY
against the live FB6 engine: 289 gates under `qa/`, of which the 264
`serve-real-*` sweeps are green (8,627 checks at the last full sweep
before the growth chunk; +32 with it).
The rule that produced all of it still holds: *what does the engine do
here?* — measured, then converted, then gated in both directions
(the engine reads what fire-crab writes, fire-crab reads what the
engine writes). Where the answer is not known, the server REFUSES;
it never guesses.

## Done

One line each; the gate is the proof.

| programme | what it means | pinned by |
|---|---|---|
| gbak (21 slices) | fc's backup writer and restore carry everything FB6 produces except an index expression the restore cannot evaluate (refused whole) and multi-file shapes FB6 no longer makes; both directions, with execution | `serve-real-gbak` 58, `gbakrestore` 39, `gbakse` 12, `gbakverbose` 14 |
| nbackup (A–D) | level-0 + level-N chains, restore with the engine's "Wrong order" refusal, `BEGIN/END BACKUP` with the `.delta` overlay — every cell cross-implementation | `serve-real-nbackup` 25 |
| programme R (R1–R8) | the row-source tree replaced textual rewriting: views, CTEs, derived tables, `WITH RECURSIVE`, the fetch PULLS the tree, `FIRST n` stops the scan | `serve-real-derived`, `recursive`, `cte`, `view` |
| W1 optimizer | the converted cost model chooses the executed plan: equality/range/compound-prefix/text-key index bands, ORDER BY navigation, the FK check, DML targets, index-driven joins, every equi-join HASH family, resumable join cursors | `opt-plans` 112, `opt-grid`, `serve-real-index` 346, `joinchain`, `leftjoinindex` |
| W2 page cache | a page-addressed `ods::Image` (`Vec<Arc<[u8]>>`), per-page fetch, Arc-identity flush diff — a write costs O(pages) end to end | `cch-crash-harness`, `serve-real-carefulflush` |
| W3 pio | the file is written in the open mode the header's Forced Writes flag calls for | `pio-layout`, `serve-real-forcedwrites` |
| W4 lck | row-level waits on the owning transaction's lock, deadlock denied by the wait-for scan with `isc_deadlock`, lock timeout | `lck-reserving-matrix`, `serve-real-concurrency` 20 |
| W5 evt | `POST_EVENT` delivered over the auxiliary connection | `evt-semantics`, `serve-real-eventdelivery` |
| W6 exe/svc | PSQL interpreter (procedures, triggers, cursors, handlers, autonomous blocks, `EXECUTE STATEMENT`), gfix's DPB channel, limbo, validation with all sixteen counters | `serve-real-psql`, `cursors`, `limbo`, `validate`, `gfixsweep` |
| W7 metadata cache | columns, check predicates and the optimizer GATE memoised per epoch | `serve-real-statementcache` |
| savepoint is a transaction | a savepoint is a nested transaction id; `ROLLBACK TO` marks it dead | `serve-real-savepointtx` |
| snapshot isolation | `parse_tpb`, a stable `Snapshot { limit, active }` per concurrency transaction | `serve-real-snapshot`, `autonomous`, `consistency` |
| cost model + stale statistics | the stale region measured and matched, the filtered-driver term included | `opt-stale` |
| transliteration + collation | eight codepage tables generated from the live engine, carriers, the assignment matrix, case law, PXW_INTL keys | `serve-real-xlit` 58, `collate` 16, `textcolcmp` 359 |
| generator SET is deferred | `tra_gen_ids` cache + dfw postings per savepoint; no compensating record | `serve-real-gencomp` 22 |
| packaged procedures + functions | a package qualifier resolves down the search path; a packaged FUNCTION runs in a select list and a selectable PROCEDURE in the FROM, bare or `PUBLIC.`/`SCHEMA.`-qualified, beside a same-named plain routine; `RDB$PROFILER` native no-ops with the engine's arity | `serve-real-pkgproc` 20, `serve-real-callpkg` 9 |
| fragmenting store | records larger than a page chain the engine's way; UPDATE/DELETE of a fragmented head | `serve-real-fragstore` 13 |
| UNIQUE is walk-order | enforcement row-at-a-time in RECNO order, 23000 byte-exact; the sub-9-byte RHDF corruption found and fixed with it | `serve-real-uniqueorder` |
| external sort | runs to disk past a budget, stable merge; ORDER BY / GROUP BY / DISTINCT; the hash-join build side in a spilling row store; ORDER BY fetches stream from the merge | `serve-real-bigsort` 12 |
| MERGE | per-source-row desugar into the audited DML planners; first branch wins; dup-target raise; `NOT MATCHED BY SOURCE` orphan pass; `RETURNING` cursor | `serve-real-merge` 30 |
| blob writes + RETAIN | temp blobs over the wire materialised at the store; COMMIT/ROLLBACK RETAIN keep the transaction with its snapshot | `serve-real-blobwrite` 8, `retain` 8 |
| transactional DDL | catalog rows under the user transaction's id, undo by state + journaled residue, deferred drops; first-updater-wins on a relation with the engine's vector; owner-only schema visibility | `serve-real-ddltx` 32 |
| the file grows the engine's way | pointer-page chain, PIP chain, SCN pages at every `pagesPerSCN·N`, TIP chain — each crossed by fc and read by the engine (count, `gfix -v -full`, a write of its own on the new structure, a level-1 nbackup over fc's late pages), and the reverse | `serve-real-growth` 32 |
| LATERAL is an ordinary source | a LATERAL materialises before anything above it runs, so DISTINCT / FIRST / SKIP / ROWS, an outer WHERE or ORDER BY, a derived table over it and COUNT/SUM/GROUP BY/HAVING over that derived table all work; the fetch batch is honoured (it hung any flow-control-honouring client past ~2340 rows); the comma form carries the inner column's nullability, the LEFT form is always nullable | `serve-real-lateral` 36 |
| a literal is bytes in the attachment's charset | statement text is decoded by `lc_ctype` instead of `from_utf8_lossy`, so a lone `0xE9` under a NONE attachment is data; a literal's charset tags the value, the CAST source and the store; and a byte carrier yields its TAG to the other operand but never its BYTES | `serve-real-litcs` 60+ |
| one per-connection object id space | a compiled BLR request and a prepared statement are different KINDS over ONE client-side id space (fbclient's `port_objects` is a single untagged union array); minting them from separate counters collided at id 5 and KILLED THE CONNECTION | `serve-real-objid` 14 |
| a folded subquery carries its column's charset | a select-list scalar subquery is erased at prepare - its value is spliced back into the statement TEXT and re-planned - so the spliced literal was typed like any literal, in the ATTACHMENT's charset, and the inner column's set was lost the moment the subquery became an OPERAND. Now spliced as `CAST(x'..' AS VARCHAR(n) CHARACTER SET <set>)` | `serve-real-subqdesc` 70 |
| a window is a value and composes | each window call is LIFTED out of its expression, folded as its own column, and replaced by a reference to it - so `ROW_NUMBER() OVER (...) + 1`, COALESCE/CASE/CAST/function/concat over a window, and two windows in one expression all work; plus PERCENT_RANK and CUME_DIST | `serve-real-window` 139 |
| a NULL side is NULL however spelled | `IS [NOT] DISTINCT FROM` desugared to IS NULL only for a BARE NULL token, so a parenthesised or CAST NULL fell through to a value comparison and came back EXACTLY INVERTED | `serve-real-nulls` 40 |
| a correlated subquery answers per row or refuses | only EQUALITY pairs counted as a correlation; anything else was re-evaluated as UNCORRELATED and folded to ONE verdict for every row, so the anti-join idiom answered every row and the running-count idiom answered 0 | `serve-real-nulls` 40 |
| a bare NULL branch contributes nothing | `makeFromList` ignores a NULL argument for unification and falls back to CHAR(1) NONE only when EVERY argument is NULL; fire-crab typed a bare NULL as INT64 and let it WIN, announcing a VARCHAR(10) UTF8 as len 32765 charset NONE | `serve-real-branchtype` 69 |
| the output format travels with the row | the singleton path (`op_execute2`, how an INSERT ... RETURNING is answered) emitted with NO OutFmt, so a CHAR result was written in the value's own bytes while the describe announced the attachment's - under -ch UTF8 `RETURNING 'ok'` announced len 8, wrote 2, and KILLED THE CONNECTION | `serve-real-returningexpr` 33 |
| a MERGE's DELETE branch has no NEW record | `RETURNING NEW.<col>` over a deleted row is NULL, PER ROW (a mixed merge answers the update branch's values and the delete branch's NULLs in one result); and the describe follows a three-way rule - every branch deletes = the null constant, some branch deletes = named CONSTANT with the column's type, none deletes = the column itself | `serve-real-returnold` 59 |
| a text blob is delivered in the attachment's charset | the engine transliterates blob content on the way out and ANNOUNCES the attachment's charset; fc announced the STORAGE charset and shipped the stored bytes, handing a UTF8 client invalid UTF-8. Both halves had to move together - announcing the attachment's charset while framing the stored bytes is worse than the self-consistent original | `serve-real-blobexpr` 53 |
| a record is read through the format it was WRITTEN under | `ALTER TABLE` mints a format and rewrites no row, so a maintained table holds several shapes at once. fc upgraded the image it PATCHED and read the raw before-image with the NEWEST descriptors everywhere else - SET expressions' old values, BEFORE/AFTER trigger OLD, the FK parent check, RETURNING OLD and the old index key. `UPDATE T SET B = B+1` after one `ALTER ... TYPE BIGINT` returned 0/0 for a stored 1/7 and COMMITTED (NULL, NULL) over the row: silent destruction of committed data, no error. The upgrade also DROPPED any field whose descriptor changed - the byte-copy law one step too far, where ALTER TYPE only ever widens and the value converts | `serve-real-stalefmt` 43 |
| an unqualified column in a body's nested DML is that STATEMENT'S own | a bare name is a column of the table the nested statement targets, resolved per row; `OLD.`/`NEW.` are the fired row. `TrigCtx::read` was `if context == 1 { new } else { old }`, so CTX_PLAIN read the FIRED row and the fold baked it in as a constant: `DELETE FROM LG WHERE ID = OLD.ID` rendered `WHERE 2 = 2` and emptied the table, `SET V = V + 1` wrote the fired row's value over every row, `WHERE V > 1000` never consulted the target. Plain INTEGER reaches all three. Second half: a value the fold could not SPELL fell through to the bare NAME, so `SET AMT = NEW.AMT` became `SET AMT = AMT` - stores nothing, reports success; DOUBLE and FLOAT now render in shortest-round-trip exponent form (measured bit-exact against the engine), INT128/DECFLOAT/blob refuse | `serve-real-psqlrowref` 21 |
| one law, one encoding: the row contexts | the substitution that writes row values into a body's statement TEXT had its OWN numbering - 1 for NEW, **2** for OLD - which worked only while the reader was `if context == 1 { new } else { old }`. Tightening that reader (the row above) turned every `OLD.` on the TEXT path into a refusal: a body query's WHERE (`SELECT ... WHERE K = OLD.ID INTO :M`) and a store whose values were kept as written (a CASE, a concatenation). A 361-gate sweep stayed GREEN through it - nothing covered that path. Now 0/1 everywhere, with the coverage that was missing. Also here: a body's `INSERT INTO T VALUES (...)` with NO column list parsed the table name as `T VALUES` and made the whole trigger unrunnable, so every statement on its table refused | `serve-real-psqlrowref` 27 |
| a record missing a field carries that FORMAT'S STORED DEFAULT | `ALTER TABLE T ADD B INTEGER DEFAULT 7 NOT NULL` rewrites no row - the value goes into the FORMAT, and every record behind it reads 7 from there. fc's format parser stopped at the descriptors, with a comment calling the trailing section ignorable "as are defaults by the engine's readers of old rows"; the second clause was false. Every historical row read NULL for the new column: SELECT wrong, `INSERT ... SELECT` PERSISTING the wrong value, and `UPDATE T SET <anything else>` answering a false 23000 for a NOT NULL column it never touched. Layout read off engine-built blobs (BLOBDUMP): after the descriptors, `u16 default_count`, then per default `u16 field_index` + a 12-byte descriptor + that many value bytes; the default's descriptor is ITS OWN (a VARCHAR(5) field is VARYING 22 while its default is TEXT 2), so the value CONVERTS. A NULLABLE `ADD ... DEFAULT` writes NO entry, which is the discriminating case | `serve-real-fmtdefault` 24 |
| DML through a VIEW acts on what the view stands for | a view has a relation id and NO records, so `UPDATE V ...` / `DELETE FROM V ...` planned as a walk of the view's storage were SILENT NO-OPS ("Records affected: 0", base untouched) and `INSERT INTO V` a bare Dynamic SQL Error. The engine's laws, measured: a NATURALLY UPDATABLE view (one plain relation; no join, DISTINCT, GROUP BY, aggregate, UNION, FIRST/SKIP/ROWS, ORDER BY, window or derived table - ORDER BY alone makes it read-only; a subquery in its WHERE is fine) forwards INSERT/UPDATE/DELETE to its base table with the view's column renames (RDB$BASE_FIELD) applied and its WHERE ANDed in, recursively through a view over a view; RETURNING answers the base row but DESCRIBES the view (name, `table: V`, nullable, an expression column typed from its expression). Any other shape is `cannot update read-only view` (bare 335544362 + the quoted name) at PREPARE; assigning an EXPRESSION column is `attempted update of read-only column <unknown>` (bare 335544359 + the literal `<unknown>`). WITH CHECK OPTION is the engine's system triggers CHECK_n (RDB$SYSTEM_FLAG 5, BLR only, a GLOBAL name sequence read from RDB$TRIGGERS: type 3 update, type 1 insert): the new row must SATISFY the view's WHERE - NULL is a violation, unlike a table CHECK - each level of a chain testing its OWN where, outer first; the vector is 335544558 with an EMPTY constraint name, the VIEW's name and the `At trigger` stack item. A view with a USER trigger for the event runs ONLY its triggers - no base write even when naturally updatable; the count is the number of view rows, OLD/NEW are view rows, a BEFORE trigger's `NEW.x` shows in RETURNING, a multi-action type counts per event, and the CHECK fires before the trigger. An INSERT through a view that supplies the identity value itself still DRAWS the base's generator (the same statement on the table does not). MERGE, UPDATE OR INSERT, INSERT ... SELECT and PSQL bodies inherit because they re-plan text. The rewrite is a single-pass simultaneous rename (a swapping view `(A, ID) AS SELECT ID, A` is right); a hidden base column named in the statement, a base-qualified reference, or an ambiguous view-qualified reference inside a subquery over the base REFUSE rather than answer wrong (the engine's -206 has no fc vector); a body fc cannot parse is Unplannable - never the typed read-only vector, and never the silent no-op again (every planner refuses a view it did not rewrite). Two reviews of 3 and 2 agents VERIFIED every finding by running it - four HIGHs (hidden columns leaking through the rename, subquery scope, a view over a trigger view bypassing the guard, CHECK OPTION passing NULL) and the resolver's fall-through to the old no-op were all caught that way. Recorded, not mirrored: the engine's RETURNING through a CHECK OPTION view answers zeros/no row (its trigger does the write) | `serve-real-viewdml` 61; `serve-real-overriding` 11b flipped from a recorded refusal to twin equalities |
| a correlated subquery is evaluated per OUTER ROW, and names resolve innermost-first | fire-crab folded EVERY subquery at PLAN time - a constant, an IN-list semi-join, or a per-key Lookup table built from ONE `=` leaf - and the fold's scoping was wrong twice: `strip_inner` stripped the BASE TABLE NAME as an inner qualifier even when the inner FROM was aliased, so `(SELECT MAX(x.A) FROM T x WHERE x.ID < T.ID)` became `MAX(A) WHERE ID < ID` and answered NULL for every row, 0 rows in a WHERE, and `DELETE FROM T t WHERE t.A < (SELECT MAX(x.A) FROM T x WHERE x.ID <> t.ID)` deleted 2 of the engine's 4; and split_correlation classified a BARE name both tables have as the OUTER column where the engine binds it innermost-first (`EXISTS (SELECT 1 FROM D WHERE D.ID = ID)`: 2 rows vs 6). `strip_dml_alias` erased `t.` inside subqueries before planning. The engine's law (SubQueryNode::execute opens the inner cursor once per outer row; pass2 marks a subquery with no outer reference invariant; findPossibleJoins turns a correlated EXISTS/IN over an inner join into a semi-join) is about SCOPE: innermost-first, alias-exclusive, whatever the inner relations cannot supply is the enclosing row's. Now: the equality fast paths keep their semi-join/Lookup shape with the scoping fixed, and everything else is `Expr::CorrSub` - the outer references replaced by typed literals per outer row, the inner statement planned and run under a thread-local database scope (the LATERAL mechanism generalised to an expression), memoised per literal tuple per execute epoch; it works in the projection, WHERE (scalar, EXISTS, IN, ANY/SOME/ALL with the three-valued laws), SET, RETURNING, ORDER BY, HAVING, JOIN ON, inside CASE/COALESCE, two levels deep, over a view or a derived table. Reviews (3 + 2 agents, every finding executed) caught before shipping: `RETURNING (... NEW.ID ...)` stripped to a bare name and bound to the inner table; text outer values rendered as bare literals losing the column's charset; MERGE's SET never reaching the lift (a pre-existing wrong write in the same family); EXISTS/IN materialising and memoising every inner row (5000 rows: 12.5 s and 420 MB); an aggregate outer running its per-row subqueries at PREPARE and again at fetch; stand-in describes for FLOAT/DECFLOAT/TZ/INT128/CHAR NONE; a nested CorrSub describing INT64 for LONG; the equality Lookup answering stale rows on a cached handle; then, in the second round, a MERGE whose source table also appears unaliased inside the subquery (the source row substituted into the subquery's own FROM), RETURNING subqueries over the target reading the statement's OWN write (the engine reads the pre-statement image, all or nothing), and three pre-existing wrongs of the equality fast path - EXISTS over an aggregate inner (one row always: TRUE), FIRST 0 / SKIP n ignored, text keys bucketed byte-exactly where the predicate pads and transliterates; and in the third, the aggregate-EXISTS fold answering TRUE without planning the inner (an unknown column or a conversion error inside it swallowed, an UPDATE/DELETE with that WHERE touching every row). Cost: ~1 ms per outer row for the general path (engine: a cursor open per row, ~0.2 ms). A fourth round found the INVARIANT PASS missing from three folds: a lone aggregate's WHERE (`SELECT MAX(V) FROM E WHERE E.TID = 3 AND 1/(3-3) > 0` answered NULL over the zero rows TID = 3 selects, so `EXISTS` over it read TRUE and an UPDATE / DELETE with that WHERE wrote every row where the engine raises 22012 and writes nothing - the law: a conjunct with no column reference is evaluated ONCE, empty scan included) and the two prepare-time subquery folds (`EXISTS (SELECT 1 FROM T0 WHERE 1/0 > 0)` over an empty T0 folded to FALSE); and `CAST(NULL AS BOOLEAN)` planning nowhere, which the new stand-in probe turned from an answer into a refusal (BOOLEAN is a cast target now - text reads `true`/`false` trimmed, anything else 22018 naming the source; a stand-in the grammar cannot spell skips the probe instead of refusing). Followed the engine on two stages while there: an eval-shaped raise on a SELECT arrives at the first FETCH, not op_execute (isql prints `Records affected: 0` after it), and a failed UPDATE / DELETE reports the rows it touched before the raise. Recorded, not answered: `EXISTS (SELECT DISTINCT MAX(V) ...)` refuses per row (DISTINCT over a lone aggregate does not plan); `WHERE ID = 1 OR 1/0 > 0` raises before the row the engine had already delivered; a text-vs-integer constant conjunct (`'x' = 1`) refuses where the engine's 22018 raises | `serve-real-corrsub` 27; nulls ran_boundary x2, subqval refuses x2, corrsubq refuses x1 flipped to equalities |
| a quoted identifier is a NAME, decided at the boundary | the engine folds an unquoted word to upper case in the LEXER (`Parser.cpp` yylexAux) and takes a double-quoted one as its exact bytes, so after the boundary there is ONE kind of name and every catalog compare is exact: `"a"` beside `A` are two columns, `"tq"` beside `TQ` two tables, `"Order"`/`"Key"`/`"select"`/`"Mixed Col"` ordinary names, and the describe announces the stored spelling. fire-crab stripped the quotes at every parse site and compared case-insensitively at ~95 column lookups and ~30 relation matches, uppercased DDL names on the way to the catalog, folded the metadata-cache keys, and had NO `"` arm in the predicate tokenizer: `UPDATE TQ SET "a" = 5` wrote column A, `SELECT ID, X FROM "tq"` read TQ, `UPDATE "Order" SET "value" = 'x' WHERE "Key" = 1` updated nothing at all, a select list naming `"Mixed Col"` or a WHERE naming `"a"` refused. Now `canon_ident` canonicalises at the parse boundary (quoted exact with `""` unescaped, bare folded), `render_canon_ref` re-quotes every canonical name written back into SQL text, and the compare is `==` from the tokenizers and resolvers through the join sides, view rewrite, correlated-subquery scope, PSQL bodies and BLR field lookup to the ods writers and gbak. Two parts, reviewed between them by three agents each, and the four laws the reviews bought: a case-insensitive FALLBACK left for unconverted callers turns refusals into wrong WRITES (`UPDATE "order"` found `"Order"`); an exact matcher on one side of a boundary with a raw spelling on the other is a regression generator (`CREATE INDEX ix ON t (dept)` stopped working); every internal RE-RENDER must re-quote, because a canonical `a` printed bare re-parses as `A` (UPDATE OR INSERT, INSERT ... SELECT and MERGE's INSERT each wrote the folded twin); and a CATALOG name must never be split like a parsed reference (a column named `"x.y"` described as `y`) | `serve-real-quotedname` 26 |
| a derived table is a source, and a source answers its OWN columns | a join side that is a derived table or view was read as BASE RECORDS at the side's own column positions - output column i became base field i - so `JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID` answered `J1.A` for `d.S`, `COUNT(*)` under `d.S = 'g1'` answered 0 for the engine's 2, and because the same side feeds semi-joins and DML row sources, `INSERT INTO TQ (ID, A) SELECT t.ID + 10, d.S FROM ...` PERSISTED the wrong column's values. It is invisible whenever the derived list is the base's columns in base order, which is every case the existing join, view, derived and 123-check index gates wrote. TWO ORDERS, ONE NUMBER: the repair is a per-output-column map to the base field it projects, built TOTAL or not at all - a list carrying an expression, a literal or a scalar subquery has no map and that side is materialised instead, because an optimisation that cannot express a case must DECLINE it rather than approximate it. Three consequences, each a general shape: the same confusion lived one layer up in the describe's NOT NULL flag, where an output position was tested against the base's not-null FIELD IDS - not cosmetic, since this server announces output columns nullable precisely because libfbclient ignores the null indicator on a NOT NULL column and renders the raw buffer, so a NULL reached the client as 0; making that pass correct exposed its neighbour, the LATERAL nullability pass that 'only ever clears bits', safe only while the pass beside it was wrong; and declining the flatten also dropped the side's hash key, degrading the join from an index probe to a per-driver scan, so a side that cannot be read as base records is now materialised ONCE and hashed on its own column - 5000x5000, the declining shape went 3.18s -> 0.007s, FASTER than the original wrong-but-indexed path. A guard added so a joined view could not fall through to scanning its own empty storage asked 'is any relation of this NAME a view' where it had to ask 'is the relation this side RESOLVES to a view': it over-fired on a plain table shadowed by a same-named view in another schema, and inside `UPDATE ... WHERE ID IN (SELECT ... JOIN ...)` an over-refusal lost the write. Root cause of that one was `view_of` walking PAST a name-matching row that carried no view source while `resolve_relation` takes the FIRST - the server disagreeing with itself about what one name meant | `serve-real-joinderived` 25 |

## Stale claims retired

- "`hdr_next_transaction` is stored one display slot apart (fc: last assigned, engine: next to assign)" — FALSE, read off tra.cpp `bump_transaction_id` on 2026-08-20: both store the highest id assigned. The one-slot difference was fc's OIT sitting AT the first interesting id where the engine's `--oldest` puts it one below — and that was a LIVE bug: the engine's sweep over an fc-written file resurrected 200 rolled-back rows (`serve-real-undo`). Fixed in `update_oldest`; `serve-real-oldesttx` asserts the same triple on both sides now.

- "Every check below was a DIFF before that arm existed" (`qa/serve-real-fkaction.sh` section 16) — FALSE, measured 2026-09-03 on a binary with only `value_cmp`'s mixed arm reverted: 20 of section 16's 37 checks were a DIFF, 17 were not, and four of those seventeen are 16f's CONTRASTS, which exist to stay put. The header now carries the per-subsection split.
- "`ORDER BY`, `GROUP BY`, `SELECT DISTINCT` … now answer what the engine answers" (`value_cmp`'s doc block) — FALSE for `GROUP BY` and `SELECT DISTINCT` with the grouped column in the select list, which is the ordinary way both are written: they answered `0.07; 7.00` where the engine answers `7.00; 700.00`. The COMPARISON was the engine's; the RENDERING was a separate defect, now fixed ("A RECORD IS PRESENTED THROUGH THE FORMAT THAT DESCRIBES IT NOW").
- "`MIN`/`MAX`, `PERCENTILE_DISC` … already agreed with the engine on this fixture and still do" (roadmap) — true only of a fixture where nothing PROJECTS the altered column, and the paragraph dropped that qualifier. On one that does, `MIN` answered `-0.02` for the engine's `-2.00` and `SUM` `19.09` for `27.01`.
- "`CURRENT_TRANSACTION` … where the old justification does hold and was verified" (roadmap) — half of that justification is false and the word "verified" was attached to the false half. It refuses, but NOT "with the engine's own reason".
- "a count of `RDB$INDEX_INACTIVE` in a restored copy reads 0 even on a restore that FAILED" (roadmap) — does not reproduce: a reviewer re-running the same shape read 3. The conclusion (the count is not a signal) stands; the stated measurement did not.
- "with an INDEX on that column, a probe loses the old-format rows" (`value_cmp`'s doc block, roadmap) — too broad: measured 2026-09-03, it depends on the index's age relative to the FORMATS the table has minted, not on the column.
- "it is the index's AGE relative to the `ALTER` that decides" (`value_cmp`'s doc block, roadmap, the correction offered for the line above) — ALSO too narrow, and retired the same day it was written: it holds only for a table with exactly one `ALTER`. Measured 2026-09-03 on a table with two, an index minted BETWEEN them - younger than the first ALTER - loses the rows written under the format the second one minted (`WHERE N = 7` answers `2, 3` for the engine's `2, 3, 5`). The law is per FORMAT: an index does not name a row written under a format minted after the index.
- "a conversion that does not fit the target's backing width … is a floor, not a path" / "not reachable through an engine-accepted ALTER" (`present_field`'s doc block, roadmap "At the extremes") — FALSE, measured 2026-09-03: `BIGINT` holding `9e17`, `ALTER … TYPE NUMERIC(18,4)` is accepted by the engine, and the engine then answers `22003 numeric value is out of range` where fire-crab answers a number off by `10^4` and folds it into `SUM` and `WHERE`. The engine's third answer - RAISE - is the one the code does not implement.
- "A foreign key on a DIFFERENT index of the same parent … is always enforced" (`qa/serve-real-fkaction.sh` section 13) — FALSE, measured on the engine 2026-09-03: with two foreign keys on the same UNIQUE index, the SECOND one is not enforced and the engine deletes the parent, leaving an orphan. The law is one check per referenced index, so an FK on another index is enforced only if it is that index's first.
- "An `ON DELETE` body carries no such guard … so a DELETE always fires" (`fk_action_fires`'s doc block) — FALSE, and refuted by the function's own first branch: an OLD key with a NULL component finds no child row and fires nothing. Measured 2026-09-03, parent `(10, NULL)`, child `(10, NULL)`, `ON DELETE CASCADE`: both servers refuse with `23000` and the child is untouched.
- "**Every consumer** of `value_cmp` … no consumer moved away from the engine" (roadmap heading and closing line) — an absolute over a set this page says is not reachable here: `cmp_value_keys` cannot be measured on this box, because `gbak -b` through this server refuses any engine-created database. Scope corrected to the consumers a client can reach.

An audit of the history file (2026-08-20) found fifteen places where a
paragraph says "still to do" and a later paragraph, higher up, closed
it. Recorded here once so nobody re-opens them:

- W2 "per-page fetch still to do / the image is one contiguous `&[u8]`" — done (Inc500–502, page-addressed `Image`).
- W4 "only LOCK TIMEOUT is read as plain WAIT" — done (`parse_tpb`, `isc_tpb_lock_timeout`).
- W6 "snapshot isolation is not converted; the gate asserts the divergence" — done (`serve-real-autonomous` asserts agreement).
- W6 "the gbak writer refuses sequences, views, triggers, procedures, UNIQUE/FK/CHECK" — all done (the gbak programme).
- W4 "what still needs an image: `ROLLBACK TO` a mark" — done (savepoint is a transaction). DDL remains (item B below).
- W4 "what is left is granularity — writers serialise on the database" — done (steps 2 and 3 beneath it).
- W1 "param'd DML WHERE needs a defer field" — done (`Plan::Update`/`Delete` grew it, `serve-real-pdml`).
- R "a date inner key still scans" — a temporal key hashes.
- W1 "`Infinity`/`NaN` text specials deliberately left to 22018" — converted.
- W1 "DECFLOAT in arithmetic still refused" — arrived.
- savepoint section "a writing window burns a transaction id the engine does not" — measured false on 2026-08-20: 1,000 `SAVEPOINT`s in one transaction leave `Next transaction` where it was. Only a transaction burns an id.
- W6 "CHECK stays int-only" — closed (text/NULL/BIGINT comparisons compile).
- W1 "still to do: index-driven joins, text keys, compound prefixes, parameters" — all done; only "a statement `opt` cannot parse (a `HAVING`) scans" survives (item I).
- W2 "fire-crab has no statement cache: the next item" — in, 36 lines above the claim.
- W1 "`records_for` rebuilds `page_sequence_map` per call" — `ProbedSide` derives it once at open for the cursor path; the probe path is item I.
- R "`NestedLoopJoin` still materialises for RIGHT/FULL" — the cursor streams the mirror; the index PROBE and the HASH still decline for RIGHT/FULL (genuinely open, item I).

## What the engine has that fire-crab does not

Ranked. Each line carries where the gap is visible.

### A. Hard growth walls in fire-crab-written files — DONE (2026-08-20)

Closed as one slice, `qa/serve-real-growth.sh` (32). What was here:
one PIP (`"first PIP exhausted"`, ~510 MB), one pointer page per
relation (`"pointer page full"`, ~13 MB per table), one TIP
(`"transaction id beyond the TIP chain"`, 32,688 ids), and SCN
stamping that knew page 2 only with 2,043 slots where the engine reads
2,041 — so page 2041 of a 16 MB file went out as DATA, and an engine
`nbackup -B 1` over fc's late pages would have missed them (the
engine's increment reads the SCN SLOTS, nbackup.cpp:1462). All four
now follow the engine's own allocator; see "The growth chunk" below.

### B. Transactional DDL — DONE (2026-08-20, slices 1 + 2)

**Done (`qa/serve-real-ddltx.sh` 22):** a DDL statement's catalog rows
are written under the transaction's own id (`Image::ddl_tx` —
`allocate_committed_tx` answers it; the engine's DdlNodes.epp STOREs
under the user transaction), so ROLLBACK, ROLLBACK TO SAVEPOINT and a
failing autonomous block undo DDL by TRANSACTION STATE. The catalog
readers (`catalog_image`, `OwnTx::catalog`) step past a DEAD or LIMBO
version — a rolled-back DROP gives its table back — and the unique-key
liveness test (`btw::recno_is_live`) is MVCC-aware, so a dead row never
blocks a key. What no state takes back is journaled per undo window
and undone by hand (`DdlResidue`: a created relation's whole storage,
a created index's tree + root slot, tx-0 `RDB$PAGES` rows — the eager
form of dpm.epp's MRK_rollback resolution); what COMMIT owns is
deferred to it (`DdlDeferred`: a dropped relation's pages, a dropped
index's `irt_drop` — dfw.epp delete_relation / ods.h:456). The image
fallback, the savepoint's write-side hold and the autonomous refusal
are gone; `op_prepare` on a DDL transaction is allowed unless a DROP
is pending (its page release is COMMIT's, and limbo may outlive this
process's journal).

**Slice 2 DONE (2026-08-20, `serve-real-ddltx` 22 → 32, zero
recorded boundaries):** the write-side hold for a DDL transaction is
gone. In its place, the engine's FIRST-UPDATER-WINS on a relation
(`ddl::relation_head_owner`: the `RDB$RELATIONS` head version's
transaction when ACTIVE — an ALTER's new version, a DROP's stub, a
CREATE's first row): an ALTER or DROP of a relation another active
transaction holds a version of refuses AT ONCE, no wait even under WAIT
(measured 60–100 ms against a 3 s hold), with the engine's own vector —
`isc_no_meta_update` / `<VERB> TABLE @1 failed` / `isc_random`
"newVersion: table N is used by transaction M" (a DROP: "table id=N busy
in another thread - operation failed"). DML, reads and index DDL are
unaffected (CacheVector.h: a different cache element). Per-transaction
SCHEMA VISIBILITY: a thread-local reader view (`tra::ReaderViewGuard`,
set per request from the attachment's own ids and refreshed whenever
they change — an adopted id, an autonomous block opened or closed, an
undo) makes `catalog_image` owner-only, so another transaction's
uncommitted CREATE TABLE is "unknown" to name resolution, while a DDL
statement and the unique-key liveness test read WIDE (a second CREATE
of the name says "already exists", as measured). The shared metadata
cache is bypassed by an attachment with uncommitted DDL and invalidated
when such a transaction commits.

**Still recorded:** `RDB$FORMATS` is written at statement time here, at
COMMIT there (DFW `makeFormat`; measured 0 before / 1 after). A limbo DDL
transaction resolved by `gfix -commit` after a restart leaves its
residue un-released (orphan pages, as the engine's own lazy markers do
until reclaimed). An uncommitted table is "unknown" here with fc's
generic unknown-table refusal where the engine spells −204 (the
pre-existing vector boundary). Inside a PSQL body the reader view is the
enclosing transaction's; an autonomous block sees the outer's
uncommitted tables where the engine's separate transaction would not.
`ddl_undo`/`image_undo` and the `restore_db` path survive as dead code
to delete.

### C. Wire surface — blob writes + RETAIN DONE (2026-08-20)

**Done:** `op_create_blob`/`op_create_blob2`, `op_put_segment`,
`op_batch_segments`, `op_cancel_blob`, a `blr_quad` parameter, and the
store that MATERIALISES a temporary blob into the relation's pages
(blb.cpp `blb::move`; levels 0–2 through `crates/blb`) — a driver's
`INSERT … VALUES (?)` with a Buffer works and the engine reads the
result (`serve-real-blobwrite` 8). `COMMIT RETAIN` / `ROLLBACK RETAIN`
as SQL and as `op_commit_retaining` (50) / `op_rollback_retaining`
(86): the transaction keeps its handle, snapshot (seeing its own
retained commits — `tra_commit_sub_trans`), cursors, statements,
generator cache and temp blobs; savepoints die; a retain without work
burns no id (`serve-real-retain` 8). `isc_invalid_savepoint` spelled.

**op_info_blob / op_seek_blob DONE (2026-08-21, `serve-real-blobinfo`
50):** the client is `qa/c/blobinfo.c` against libfbclient (node has
neither op). `isc_blob_info` answers num_segments / max_segment /
total_length / type on the read and the write handle; `isc_seek_blob`
is stream-only (`isc_bad_segstr_type`), clamped to [0, length] in all
three modes (`BLB_lseek`); `op_get_segment` on a SEGMENTED blob now
packs whole segments into the client's buffer, one frame each, and
answers resp_object 1 for a partial segment (server.cpp `get_segment`)
— the client sees the segments it wrote, not one run. Measured on the
way: the engine's stream-blob header counts the PUTS (5 × 10 bytes:
count 5, max 10 — this crate wrote 1 / 50), `isc_bpb_type` is tag 3
(fc read tag 1, so every stream bpb was taken as segmented), and
libfbclient describes an SQL_BLOB parameter as `blr_blob2` (17), which
the parameter parser now binds. **Inline blobs are NOT sent** (FB6
`op_inline_blob`, protocol 19: a blob up to `max_inline_blob_size` rides
with the fetch, framed by max_segment, and the client then answers
info / seek / get_segment from its cache); the gate disables inlining
through the DPB so both servers answer the ops over the wire — a
default client reads the same bytes either way, in differently sized
frames for a stream blob. **`op_inline_blob` DONE (2026-08-21,
`serve-real-blobinfo` 103):** a client that declares
`p_sqldata_inline_blob_size` (protocol 19) gets each row's blobs ahead of
the row — the same 8 id bytes the row carries, the info `isc_blob_info`
would answer, the content framed per segment (a stream blob in
max_segment pieces) — when the framed length fits; the client then serves
info / seek / get_segment from its copy (the gate's inline pass: wire
opens fall away, the answers are the engine's line for line).

**Still absent:** nothing on the protocol list; see the array tails. `op_info_transaction` answers only `isc_info_tra_id`. A text blob
is stored in the database charset (UTF8) with no bpb transliteration.

### D. Converted, not wired — MERGE executor DONE (2026-08-20)

**Done:** `Plan::Merge` (`serve-real-merge` 17): a table or derived-table
source, `ON`, `WHEN MATCHED [AND c] THEN UPDATE SET … | DELETE`, `WHEN NOT
MATCHED [AND c] THEN INSERT`, several branches per kind — the first whose
condition holds in declaration order, or nothing (MergeNode::genBlr's
if-else chain) — and `isc_merge_dup_update` (21000) when two source rows
reach one target, the statement undone. Desugared per source row at
execute into the audited UPDATE/DELETE/INSERT planners; the pairs are
read first against the statement's starting state, as the engine's one
join cursor does. **Tails DONE (2026-08-21, `serve-real-merge` 30):**
`WHEN NOT MATCHED BY SOURCE [AND c] THEN UPDATE | DELETE` — the join
turns FULL; every target row no pair reached gets its own pass, read from
the same starting state, identified by its primary key or (PK-less) by
every column, identical rows as one identity (they take the same branch,
as the engine's do); a source reference inside such a clause refuses at
prepare (the engine: 42S22 Column unknown, probed — NOT a NULL). `RETURNING`
wraps the plan like any DML's (a multi-row cursor: the after-image per
moved row, the old row for a DELETE branch, the BY SOURCE pass included);
the target is named by its ALIAS when it has one (`T.V` is unknown,
`tg.V` answers — probed), `NEW.` is that same image, a bare name both
sides carry refuses (the engine's 42702 ambiguous). The qualifier strip
[`unqualify_dml`] skips MERGE: two tables through aliases make its 2-part
references the norm. **Still absent:** `RETURNING OLD.x` / the source's
columns in RETURNING / an expression there (refused at prepare), `PLAN` /
`ORDER BY`, `OVERRIDING`, parameters inside a MERGE, the failed
statement's partial `Records affected` (the engine reports the rows it
moved before the raise; fc reports 0), a trigger-bearing target
(refused by the per-row planners at execute, not at prepare).
Scrollable cursors: `dsql` emits `blr_scrollable`, and `op_fetch_scroll`
is answered (2026-08-21, see the slice list).

### E. DDL without planners

This section has largely closed. Planners now exist and are
differentially gated for `CREATE/ALTER/DROP VIEW`, `RECREATE <anything>`,
`ALTER/DROP TRIGGER`, `CREATE OR ALTER TRIGGER`, `ALTER PROCEDURE`,
`CREATE OR ALTER PROCEDURE`, `CREATE/ALTER/DROP FUNCTION`,
`CREATE/DROP PACKAGE` + `CREATE PACKAGE BODY`, `CREATE/DROP COLLATION`,
`CREATE/ALTER/DROP MAPPING`, and the full `CREATE TABLE` column-type set
(BLOB, DECFLOAT, `TIME/TIMESTAMP WITH TIME ZONE`, NCHAR, arrays, and the
`COLLATE` / `CHARACTER SET` clauses). DROP-dependency enforcement (views,
procedures, FK/PK back-references) refuses with the engine's exact vector.

Still `Plan::Refused` (generic Dynamic SQL Error at prepare): `CREATE/
ALTER/DROP USER` (the security database's PLG$SRP, a separate database,
not this catalog), `CREATE SHADOW` (a physical shadow file beside its
RDB$FILES row), `ALTER DATABASE` beyond `BEGIN/END BACKUP`, and `CREATE
ROLE … SET SYSTEM PRIVILEGES`. The first two are outside fc's
pure-catalog model by nature. Gates historically built their procedures
with the ENGINE, which is why the interpreter was well covered before the
DDL was.

### F. DML and PSQL gaps

**TIME/TIMESTAMP WITH TIME ZONE values in DML DONE (2026-08-25,
`serve-real-tzdml` 8):** fc could CREATE tz columns and read
engine-written rows; every tz VALUE refused. Now: zone-tailed
literals (`TIMESTAMP '... +02:00'`, `TIME '... UTC'`) parse
(`split_zone_tail`/`resolve_zone_tail` beside the CVT grammar,
BARE-digit offset fields — the engine 22009s every inner-sign
spelling, and `'-+2:00'` briefly stored a SIGN-FLIPPED instant
before review), the wall clock converts local→UTC by
`tz::displacement` (offset zones id = minutes+1439 and the UTC
family; NAMED zones with tzdata rules REFUSE — fc carries the
id↔name table, tzdata 2026c names, no rules, and a wrong instant is
worse than a refusal), and the stored form (UTC halves + USHORT
zone id) flows through new `RawExpr::TimeTzLit/TsTzLit` and
`WireParam::TimeTz/TimestampTz` into destination-aware
`encode_wire_value` arms: tz column verbatim, zoneless value into a
tz column takes the SESSION zone permanently (measured), tz value
into a zone-less column converts to session wall, text with a zone
tail everywhere the CVT grammar takes one. WHERE/ORDER BY compare
by UTC INSTANT across spellings (`temporal_kind` types the tz
dtypes; `value_cmp` mixed tz/plain arms read the zoneless side as a
session instant; `session_zone_id` is cached — it read
/etc/timezone per row). The 22009 vectors ride PREPARE_REFUSAL
verbatim (`Invalid time zone region/offset`), the DML branch now
clears+consumes it (and refreshes USER_FNS with it — a stale map
briefly called fresh functions unknown). The 16-agent review's
other catches, all fixed live-verified: the engine's 22008
`value exceeds the range for valid timestamps` at READ of a stored
instant past 0001..9999 (both servers ACCEPT the insert — the wall
clock was in range; fc used to serve the row); tz-column
SUBTRACTION (UTC-instant difference, TIME pairs at scale -4,
tz-minus-plain via session — fc answered NULL and silently emptied
filters); CAST of a zone-tailed STRING to plain temporals
session-converts (fc raised an affirmative 22018); CAST/concat of a
ruleless named-zone VALUE refuses (fc's own render is the
visibly-unconverted `<tz ...>` — it leaked as output);
INSERT..SELECT carries tz values via new psql_literal arms.
GROUP BY/DISTINCT/UNION over tz keys REFUSE (`plan_tz_dedup`): the
engine's tie representative is an unstable internal-sort artifact —
it flipped between largest- and smallest-zone-id under a WHERE
during review — and a wrong representative is a wrong answer.
Boundaries recorded: ruled named zones in DML, TIME-TZ into
TIMESTAMP (the 2020-01-01 base-date re-anchor law), CREATE INDEX on
tz columns, tz parameters, no-space zone tails, EXECUTE BLOCK tz
literals (all clean refusals). *(`EXTRACT`/`AT TIME ZONE` were on
that list until the slice below closed them.)*

**AT TIME ZONE, the time-zone EXTRACT parts and SET TIME ZONE DONE
(2026-08-26, `serve-real-attimezone` 49):** `<value> AT TIME ZONE
<zone>` and `<value> AT LOCAL` — a left-chaining postfix operator in
both front-ends (`expr_at_tz`, `texpr_at_tz`) — CONVERT AND THEN
RE-LABEL, the engine's own shape (AtNode::execute, ExprNodes.cpp:
3368: `MOV_move` to the WITH TIME ZONE type normalises to a UTC
instant, then only the zone id is overwritten). So a ZONELESS
operand is a wall time in the SESSION zone (12:00 under a UTC
session is 14:00 +02:00, 11:00 +02:00 under a +03:00 one — the
standard's reading, the opposite of PostgreSQL's re-anchoring) and a
ZONED one keeps its instant. The result is always a WITH TIME ZONE
value of the operand's family, described 32754/12 and 32756/8, named
`AT`, nullable iff either operand is; the zone is any expression,
evaluated per row, and a bad one raises the engine's 22009 at
EXECUTE. `EXTRACT` gains `TIMEZONE_HOUR`/`TIMEZONE_MINUTE`, SIGNED on
BOTH parts (`-03:30` gives −3 and −30), answering the SESSION
offset for a zoneless operand; its ordinary parts now read a zoned
value's LOCAL wall clock where they used to refuse. `SET TIME ZONE
'<zone>' | LOCAL` sets the session zone (`Plan::SetTimeZone`,
reported `isc_info_sql_stmt_ddl` as the engine reports every
session-management statement) and the zoneless clocks
(LOCALTIME/LOCALTIMESTAMP/CURRENT_DATE) move with it.
Four pre-existing divergences fell out with it: EXTRACT announced
BIGINT where the engine announces SMALLINT (and INTEGER at scale
−4/−1 for SECOND/MILLISECOND) — top level AND under every wrapper; a
WITH TIME ZONE column named out of a DERIVED TABLE or CTE decoded as
a BIGINT and answered **0** (`desc_of_projcol` had no tz arm);
COALESCE announced nullable always (the engine's list rule is
"nullable if ANY argument is"); and `expr_reads` — the walker that
decides whether a term is row-dependent — had a catch-all that
judged `<column> AT TIME ZONE '…'` row-INDEPENDENT, evaluated it
against an empty row and SILENTLY DROPPED EVERY ROW of a WHERE.
Boundaries: a ruled region still refuses everywhere (no tzdata
rules) and `TIMEZONE_NAME` refuses (ICU-rendered). *(The
isql-autocommit boundary recorded here — a `stmt_ddl` statement
committing the caller's pending DML — is CLOSED by the slice below.)*

**REAL PER-TRANSACTION WIRE HANDLES — DONE 2026-08-26
(`serve-real-txhandle` 10).** One attachment may hold several
transactions, and every op that carries a transaction handle names
WHICH one it means. fire-crab answered one fixed handle for all of
them and threw the incoming handle away, so a commit of one committed
them all: isql's autocommit of a DDL statement committed the user's
pending DML and the ROLLBACK that followed restored nothing, and two
explicit transactions on one attachment both survived when only one
was committed. **A rollback that does not roll back was the last
known wrong-answer class in this server.**
The model is a CONTEXT SWITCH: `Database` still holds ONE
transaction's state in its own fields, every other open transaction
is parked in a `TxSlot`, and `switch_tx` swaps them so the whole body
of the server keeps reading one transaction out of the fields it
always did — only the switch points know there are others. What is
per transaction: its id and nested ids, undo windows, snapshot,
generator cache, temp blobs, deferred DDL, TPB settings, savepoint
names, the 2PC limbo bit — and, after review, **its lock owner**.
`op_transaction` allocates the LOWEST FREE handle (the client indexes
its objects by handle, so they must stay small and dense — a
monotonic counter that climbed away was rejected outright, and the
protocol's object field is only sixteen bits); `op_commit` /
`op_rollback` resolve the named handle and free the slot, the
retaining forms keep it, and a handle that names nothing is
`isc_bad_trans_handle`. `SET TRANSACTION` executed with handle 0
opens one and the response carries the new handle. Statement handles
now step over live transaction handles.
Two corruption classes the review caught, both fixed and gated:
ending one transaction released the WHOLE attachment's locks, so a
concurrent `gfix -sweep` read a still-live sibling as abandoned and
backed its committed rows out; and temp-blob ids restarted at 2 in
every transaction while `op_put_segment` carries no handle, so a
segment landed in the sibling's blob. The earlier attempt at this
change died on `op_inline_blob`, which stamps the transaction the
client caches the blob under — it carries the live handle now.
Recorded: two transactions of ONE attachment do not conflict with
each other (they share no lock arbitration), and fetches bind to the
transaction live at fetch time (`op_fetch` carries no handle).

**BINARY LITERALS AND THE OCTETS LAWS — DONE 2026-08-26
(`serve-real-octets` 32).** `x'…'` is not a string with a funny
spelling: it is CHAR(n) CHARACTER SET OCTETS, and OCTETS is the one
character set whose *space* is a NUL byte. Getting the literal in was
half a day's parsing; the other half was that every string law bends
around that pad byte, and fire-crab had them all on the blank —
including for OCTETS **columns**, which is where the wrong answers
were:

* a `CHAR(4) CHARACTER SET OCTETS` holding `x'6162'` reads back
  `61620000`. fire-crab wrote `61622020`, so its file and the
  engine's disagreed byte-for-byte on data the engine could read.
* comparison pads the shorter side with 0x00 as soon as EITHER side
  is binary, and transliterates neither (`CVT2_compare`,
  cvt2.cpp:438): `x'4100' = 'A'` is TRUE where `x'4120' = 'A'` is
  FALSE. Both sides now wrap in `Expr::OctKey`, the byte-string twin
  of the collation key — the same trick, for the one charset whose
  padding rule the ordinary compare cannot express.
* `UPPER`/`LOWER` over OCTETS are IDENTITY. The binary texttype
  installs `internal_str_copy` for both directions
  (intl_builtin.cpp:1025) where NONE and ASCII, which share
  `FAMILY_INTERNAL`, upcase the ASCII range.
* `TRIM`'s default character is the charset's space — one 0x00 — so a
  0x20 survives a `TRIM` and a 0x00 does not. `LPAD`/`RPAD` fill with
  the same byte. The default form now carries ONE argument through
  the raw tree and resolution fills the pad in, where the descriptors
  are; a written-out character is still used as written.
* **`LIKE` over a binary left operand has no wildcards at all.** The
  wildcard bytes are `%` and `_` converted FROM UNICODE into the left
  operand's charset (Collation.cpp:1025), and the binary charset's
  converter is a UTF-16 byte dump (intl_builtin.cpp:926), so each
  arrives as `{0x00,0x25}` / `{0x00,0x5F}`; the matcher reads the
  first byte only, and its `sql_match_any &&` guard (evl_string.h:352)
  reads a zero as "no wildcard". What is left is a literal byte match
  over the FULL padded value — a `CHAR(4)` holding `61620000` matches
  `x'61620000'` and NOT `x'6162'`. A CHAR left operand keeps its
  wildcards even when the pattern is binary, and `SIMILAR TO`, a
  different engine entirely, keeps them for binary too.
* the result charset ABSORBS: one OCTETS operand makes the whole
  concatenation, CASE, COALESCE or MIN binary
  (`getResultTextType`, DataTypeUtil.cpp:59, now `cs_join`'s rule) —
  and a high byte then travels as ONE octet instead of its UTF-8
  pair, which also fixed a spurious string-truncation raise.

An OCTETS column now takes the EXPRESSION predicate path, the way a
temporal one does, because that is where these laws live. A binary
LIKE/STARTING pattern travels as `Rhs::Oct` so the LEFT operand can
decide whether its bytes are a value or a text pattern. The store
path carries the charset too (`expr_value_to_wireparam`), or
`x'41FF'` landed as its UTF-8 three bytes. `REPLACE` gained the
describe width the engine computes (source + how much longer the
replacement is, once per possible occurrence) — it was announcing
32765 for every call. Boundaries, both recorded and refused rather
than answered: a LIKE pattern that is not a literal (a parameter or
an expression) against a binary side, and `CAST(… AS … CHARACTER SET
…)`, which the slice below closed.

**THE CHARACTER-SET CAST — DONE 2026-08-26 (`serve-real-cscast`
40).** `CAST(<v> AS CHAR|VARCHAR(n) CHARACTER SET <cs>)` is how a
value crosses between character sets, and it was refused in every
set. Now it converts, with the three error classes the engine
separates — and the separation is the feature: which one a value
earns says *where it came from*.

* **to a byte carrier** (NONE, OCTETS) the OCTETS travel, whatever
  they are: a UTF8 `'café'` cast to NONE is its five UTF-8 bytes, a
  WIN1252 one its four codepage bytes.
* **from a byte carrier into a real set** the bytes must SPELL that
  set or it is `isc_malformed_string` (22000): `x'41FF'` into UTF8, or
  any byte past 0x7F into ASCII. A single-byte destination has an
  image for every octet, so `x'8182'` into WIN1252 answers.
* **between two real sets** the CHARACTERS travel and one with no
  image is `isc_transliteration_failed` (22018) — the *other* vector
  for the same bytes. Out of a BLOB source that failure carries no
  arithmetic-exception wrapper where its truncation does (measured,
  and now a vector of its own).
* transliteration comes **before** the width: five untranslatable
  characters into a `VARCHAR(2)` is the 22018, never the 22001.
* the width is counted in CHARACTERS OF THE TARGET, and the overflow
  that may silently drop is the target set's **pad**: `x'41202020'`
  into a `VARCHAR(2) CHARACTER SET OCTETS` raises where `x'41000000'`
  fits, because OCTETS pads with a NUL. A CHAR target fills with the
  same byte.

The result is a first-class value OF that set, so the OCTETS laws of
the slice above apply to it: `CAST('A' AS CHAR(2) CHARACTER SET
OCTETS) = x'4100'` is TRUE, its LIKE has no wildcards, and one such
operand makes a whole concatenation binary. Three seams had to learn
the same lesson, and each was a wrong answer before it: the STORE
path now binds a value with its own character set (a cast to NONE
landed as the UTF-8 of the characters it had decoded to), the
out-capacity check counts the bytes the EMIT will actually ship (a
tabled destination ships one byte per character, so a WIN1252 result
whose UTF-8 spelling is longer than the slot still fits), and
`OCTET_LENGTH` reads any expression's own set rather than only a
column's.

Refusals kept honest: a character set the engine has that fire-crab
carries no table for (UNICODE_FSS, the DOS pages, the multibyte
pages), a `COLLATE` naming anything but the set's own collation (its
ordering is a different answer, not a different spelling), a quoted
name in the wrong case (`"win1252"` is undefined — the engine matches
a quoted name as written), a zero or over-long width (the engine's
-842 / -204 name the number, this refusal is generic), and the two
places the BLR compiler would have to carry a charset'd cast
descriptor: a PSQL body and a VIEW body. An undefined character set
NAME answers the engine's own -204 vector, `CHARACTER SET
"PUBLIC"."NOSUCH" is not defined`.

Recorded beside it, found while gating and NOT this slice's: isql's
`CONNECT '<host>/<port>:<db>' USER 'SYSDBA' PASSWORD '...'` is rejected
by this server's auth. The client passes the login through **with its
quotes** (`'SYSDBA'`), the engine dequotes it and this server's identity
check is exact — so the gate reaches a UTF8 attachment through
`isql -ch UTF8` instead. Every gate that connects the ordinary way (the
connection string as isql's argument) is unaffected, which is why this
went unseen.

**BLOB OPERANDS IN EXPRESSIONS — DONE 2026-08-26
(`serve-real-blobexpr` 26).** A blob column was an operand of nothing:
every predicate and every text function over one refused, which is a
large part of what people actually do with a text blob. It is a TEXT
OPERAND now — the engine filters the blob to a string and runs the
ordinary text law over it, and so does this server
(`Expr::BlobText`, which carries the column's own CHARACTER SET so a
WIN1252 or NONE blob's high bytes survive the read):

* the comparison family (`=`, `<>`, ordering, `BETWEEN`, `IN`), `LIKE`
  with an `ESCAPE`, `STARTING WITH`, `SIMILAR TO`, a blob against
  another blob, and a blob operand inside a JOIN's `ON` or a `CASE`
  condition — all by CONTENT, which is what the engine compares.
* the LENGTHS answer a **BIGINT** over a blob where they answer an
  INTEGER over a string (`CHAR_LENGTH(<blob>)` describes INT64).
* **a blob operand makes the whole expression a BLOB** — concatenation,
  `UPPER`/`LOWER`/`TRIM`/`SUBSTRING`/`LEFT`/`RIGHT`/`REPLACE`/`LPAD`,
  and a conditional with a blob branch. The result's text type is the
  operands' joined one, the FIRST real charset winning (`S || B` is
  UTF8 from S, `W || B` WIN1252 from W, `B || W` UTF8 from B), and ONE
  binary blob operand makes the whole result binary with no charset at
  all. The value is MINTED as a temp blob through the LIST path
  (`Expr::BlobOf`); the id is this server's own, the content is the
  engine's.
* `ORDER BY` / `GROUP BY` / `DISTINCT` over a blob key the **BLOB ID**,
  not the content — four rows spelling `zzz, aaa, zzz, mmm` come out in
  ID order and group into FOUR groups (measured). Both servers answer
  that, which the gate pins: a server that keyed the content would
  answer `2,4,1,3` and three groups.

**And a pre-existing DDL bug fell out of it: fire-crab ignored the
database's DEFAULT CHARACTER SET.** In a `DEFAULT CHARACTER SET UTF8`
database a plain `VARCHAR(10)` is charset 4 and FORTY bytes to the
engine; this server wrote charset 0 and ten. Every text and text-blob
column it created in such a database had the wrong charset in its
catalog row, the wrong byte length in its format, and a describe
(`charset: 0 SYSTEM.NONE`) the engine disagreed with column by column
— and a non-ASCII literal stored into one landed as mangled carrier
bytes. `apply_db_charset` now resolves the default at CREATE TABLE,
CREATE DOMAIN, ALTER TABLE ADD, ALTER COLUMN TYPE and ALTER DOMAIN
TYPE, exactly where the engine resolves it; an explicit `CHARACTER SET
NONE` still means NONE (the parser now keeps "declared none" and "NONE"
apart). Verified end to end: the engine reads an fc-created UTF8 table
with the same describe, the same OCTET_LENGTH/CHAR_LENGTH and the same
values, `gfix -v -full` clean.

Boundaries, recorded and refused: `MIN`/`MAX` over a blob (the engine
compares CONTENT and answers the winning row's stored id), a blob in
arithmetic, a blob-valued SCALAR SUBQUERY, a blob-valued expression
inside a DERIVED TABLE, and — the next slice — every blob VALUE in
DML: `INSERT ... SELECT` of a blob column, an `UPDATE` whose `SET`
reads one, and `CAST(<v> AS BLOB)`.

**BLOB VALUES IN DML AND `CAST(<v> AS BLOB)` — DONE 2026-08-26
(`serve-real-blobexpr` 30).** The other half of the slice above: a blob
column could be READ by an expression and never WRITTEN by one. Now a
blob column takes ANY value as a blob, under the engine's own two laws.
An expression that answered another blob is COPIED, never shared
(`BLB_move`, blb.cpp:1183 — aliasing would leave two versions pointing
at one id, and the collector frees a collected version's blobs BY ID),
and the DESTINATION's subtype and character set decide the new blob's
(blb.cpp:1262), not the source's. A SCALAR stores its RENDERING (probed:
42 lands `'42'`, 3.14 `'3.14'`, a DATE its ISO day, a TIMESTAMP its full
`…10:20:30.0000`, TRUE the word in capitals) — the same spellings a CAST
to text produces, gathered in `wireparam_text`. `CAST(<v> AS BLOB
[SUB_TYPE TEXT|BINARY|<n>] [CHARACTER SET <cs>] [SEGMENT SIZE <n>])`
names the blob's own type, a `CHARACTER SET` clause promoting the
spelling to TEXT exactly as in a column declaration, `SEGMENT SIZE`
deciding nothing, a user sub_type refusing (`isc_nofilter`). The value
is minted through the LIST path, so a statement that MINTS AND STORES
inside ONE op — `INSERT … SELECT <blob expression>` — needed
`flush_minted_blobs`: the mint context is drained at the TOP of the next
op, too late for a store in the middle of this one. **A charset bug fell
out beside it:** `store_blob_param` hard-coded a text blob's charset to
UTF8, so a blob copied or created into a WIN1252 or NONE column was
labelled UTF8 in its header and read back through the wrong table.
Boundaries recorded: a blob-valued SCALAR SUBQUERY as the source (the
pre-existing scalar-subquery gap) and `RETURNING <expression>` (a
general RETURNING limit — a bare `RETURNING B` answers).

**A SUBQUERY AS A VALUE IN DML — AND THE STATEMENT CACHE'S FIRST LAW —
DONE 2026-08-26 (`serve-real-subqval` 33).** The read side has answered
subqueries for many increments; the WRITE side refused every one, so the
value a statement stored could never be looked up. `INSERT … VALUES (…,
(SELECT …))` and `UPDATE … SET <col> = (SELECT …)` serve now:

* an UNCORRELATED subquery is a CONSTANT for the statement — answered
  once by `eval_subquery` and folded back in as the literal it computed
  (`fold_dml_subqueries`), which hands the whole existing value surface
  to it for free: the item alone, arithmetic around it, a CAST, a
  COALESCE, several in one list, a source that is a VIEW or a DERIVED
  TABLE, the `FIRST 1 … ORDER BY` idiom, the TARGET table read at its
  own starting state, and a MERGE's `UPDATE SET`.
* an UPDATE's SET may CORRELATE to the target row (`SET N = (SELECT
  SUM(V) FROM P WHERE P.ID = D.ID)`): the same LOOKUP TABLE a correlated
  select-list item builds, keyed by the outer column, with the engine's
  absent-key law (COUNT 0, every other function NULL).
* the singleton laws travel with it: NO ROW is NULL (not an empty
  result, not a skipped assignment) and MORE THAN ONE ROW is
  `isc_sing_select_err` 21000. A raise is carried BESIDE the folded text
  and surfaced only once the rest of the statement has parsed — folding
  happens before the SET list is read, and a statement this server
  cannot parse must keep its generic syntax refusal (`SET N = (SELECT …)
  FROM D` is the engine's -104, not a runtime raise).
* the fold spells every type it can spell exactly: INTEGER, NUMERIC,
  VARCHAR (quotes doubled), DATE/TIME/TIMESTAMP as typed literals, and
  DOUBLE as a cast over its SHORTEST ROUND-TRIPPING text (the engine's
  16-digit display does not always name the same f64).

**A CLAUSE-SPLIT BUG fell out of it:** the statement's own `WHERE` is
the one at PAREN DEPTH ZERO. A SET value's subquery carries a WHERE of
its own, and `find_word` took the first one — cutting the SET list in
half, so the assignment lost its closing paren and the whole statement
refused (`find_word_depth0` now, as every other clause split already
used).

**AND THE REAL FIND: A FOLDED SUBQUERY IS NOT A PLAN THE STATEMENT CACHE
MAY KEEP** — a PRE-EXISTING silent wrong answer in the READ path, older
than this slice. The cache is keyed by (schema, text), so everything a
plan holds must be derivable from those two; a folded subquery is a
value read from ROWS. Measured before the fix:

```sql
SELECT COUNT(*) FROM D WHERE ID IN (SELECT ID FROM P);   -- 1
INSERT INTO P VALUES (2, 200); COMMIT;
SELECT COUNT(*) FROM D WHERE ID IN (SELECT ID FROM P);   -- 1; the engine says 2
```

The outer rows were read fresh every time and only the folded inner list
was frozen, so the query looked alive while answering from the first
preparation. The same held for a select-list subquery
(`SELECT (SELECT MAX(V) FROM P)` answered 100 for ever) and would have
held for every DML fold this slice adds. Fixed by a thread-local
`PLAN_READ_ROWS`, set inside `eval_subquery` and `build_correlated_lookup`
— the two places planning reads rows — cleared before each top-level
plan and read after it by the new `stmc::DbStatements::plan_if`, which
builds the plan and then declines to KEEP it. A FLAG rather than a scan
of the text, because a VIEW BODY can carry the subquery a statement's
own text does not show (gated). The stmc module's own question — *what
did the planner READ that the schema does not decide?* — now has a
mechanism behind it. The unfiltered `COUNT(*)`/`MAX` folds it warned
about were already per-execute; re-measured clean.

Boundaries recorded: a CORRELATED subquery inside a larger expression
(the lookup would have to be spliced into a tree the expression parser
has already refused), a correlated subquery in an INSERT's value list
(no outer row to name), a correlated BARE COLUMN whose source holds two
rows for one key (the lookup is built for every key at prepare, where
the engine raises only if that key is reached), a `?` inside a subquery,
and a blob-valued subquery (the blob boundary above). And one that is
inherent to folding at all: the fold reads at PREPARE, where the engine
reads at EXECUTE — a client that prepares under one transaction and
executes under another (isql does exactly that) takes the prepare-time
visibility. The plan is no longer KEPT, so every execution re-prepares
and the window is one op wide rather than for ever; closing it entirely
means executing the subquery as a row source, which is the nested
`blr_rse` the engine compiles.

**`RETURNING <EXPRESSION>` — DONE 2026-08-26
(`serve-real-returningexpr` 24).** The other direction of a DML value:
the RETURNING list took plain column references only, so `RETURNING ID +
1`, `RETURNING UPPER(S) AS U`, `RETURNING CAST(B AS VARCHAR(30))` and
even `RETURNING 1` refused. Any value expression serves now, built by
the SELECT LIST'S OWN `build_expr_col`, so the type, the width, the
charset and the un-aliased name are decided in one place and cannot
drift from the projection's: `MULTIPLY`, `ADD`, `CONCATENATION`, `CAST`,
`CASE`, `""` for a unary minus. Every family measured against the engine
over the written row — arithmetic, concatenation, CAST, COALESCE, CASE,
temporal arithmetic, the text functions, a BLOB-valued expression
(minted through the LIST path, as in a projection), a constant, a
literal keyword, a qualified column — for INSERT, UPDATE (the NEW row),
DELETE (the row as it WAS) and UPDATE OR INSERT, over the cursor path
AND the type-8 singleton path a driver takes for `INSERT ... RETURNING`.

The spelled/expression split is made on the TEXT and not by trying the
column route first: a quoted `RETURNING "id"` must stay `Column unknown`
(the engine's exact compare), where an expression resolver — which folds
case like every other resolver here — would have answered it. That
decision needed the select list's own literal rules with it: an unquoted
identifier CANNOT START WITH A DIGIT (`RETURNING 1` had been looked up
as a column named "1" and refused, while `'lit'` always worked because
it is not spelled like a name), and `NULL`/`TRUE`/`FALSE`/`UNKNOWN` and
the clock keywords look exactly like names and are values.

TWO PRE-EXISTING DESCRIBE DIVERGENCES fell out of it, both measured:
**every RETURNING column is nullable**, even one the table declares NOT
NULL (`RETURNING ID` over `ID INTEGER NOT NULL` describes Nullable where
the same column in a SELECT does not) — this server passed the column's
own flag through; and **a bare NULL literal describes as CHAR(1)
CHARACTER SET NONE**, in a select list as much as in a RETURNING, where
this server announced INT64. The second is a describe-only fix:
`Expr::type_of` still answers Int for a NULL, which is the arithmetic
default an all-NULL conditional leans on.

Boundaries recorded: an expression over a COMPUTED column (these rows
are decoded from the STORED image, where a computed column's descriptor
sits over the null flags — the bare column already refused for that
reason, and `RETURNING CC + 0` now refuses with it), an aggregate, a
subquery and a parameter. *(A MERGE's RETURNING was on that list until
the slice below took it.)*

**A `?` INSIDE A DML VALUE EXPRESSION — DONE 2026-08-26
(`serve-real-dmlparamexpr` 25).** A parameter standing ALONE has always
worked; one inside an expression refused — `INSERT ... VALUES (? + 1)`,
`UPDATE ... SET N = ? * 2`, `SET S = 'x' || ?`, `SET N = CAST(? AS
INTEGER)` — which is most of what a prepared statement does with
arithmetic. The feature is really the TYPE the parameter is described
with, and the engine's rule is not the obvious one. Read off its own
input SQLDA (`SET SQLDA_DISPLAY ON` prints the input message even for a
statement isql cannot then execute):

* **the DESTINATION COLUMN types the parameter**, whatever operators
  stand between them: `SET NM = ? * 2` over a `NUMERIC(9,2)` describes
  the parameter as that NUMERIC (LONG scale −2 subtype 1), NOT as the
  literal 2's INTEGER; `SET D = ? + 1` is a DATE; `SET S = SUBSTRING(?
  FROM 1 FOR 2)` is S's VARCHAR(20); `-?`, `(? + 1) * 2 - 3` and a CASE
  branch take it too. That is `PASS1_set_parameter_type` pushing the
  assignment's destination down the tree.
* a **CAST** types its own operand instead (`CAST(? AS VARCHAR(5))` is
  VARYING(5)), and **COALESCE** types its parameter from its OTHER
  ARGUMENTS and only from them — `SET NM = COALESCE(?, 0)` is a plain
  INTEGER where `SET NM = CASE WHEN … THEN ? ELSE 0 END` is NM's
  NUMERIC (CoalesceNode makes the descriptor itself; CaseNode and
  ValueIfNode pass down what they were given). Measured both ways.
* the slots are numbered in SOURCE order: the SET list left to right,
  then the WHERE.

`resolve_dest_param_expr` is that law; `InsVal::ParamExpr` carries the
numbered raw tree until the target column is known (a VALUES list is
parsed before the target list is resolved); `Plan::Insert.param_exprs`
binds and evaluates at execute, and an UPDATE's `SetVal::Expr` is bound
once before the row loop (a `Cow`, borrowed when parameterless). Both
sides re-check that the BOUND tree still types, because a `?` types None
at prepare and the eval fallthrough would otherwise store a silent NULL.

**A PRE-EXISTING DESCRIBE DIVERGENCE fell out of it: A PARAMETER
INHERITS THE NULLABILITY OF THE COLUMN THAT TYPES IT.** `WHERE ID = ?`
over an `ID INTEGER NOT NULL` announces the parameter NOT NULL; `SET V =
?` over a nullable column announces it nullable; a parameter typed by a
CAST or a COALESCE — by no column at all — is nullable. This server
announced EVERY parameter not-nullable, in both describe shapes
(`append_bind_section` and `answer_prepare`'s bind vars), which was
right by accident wherever the column happened to be NOT NULL and wrong
everywhere else. The engine derives it from the metadata — `DSC_nullable`
is explicitly "not stored" (dsc_pub.h:39) — so this server does the same
where the formats are BUILT: `stamp_param_nullability` writes the
catalog's NOT NULL onto the descriptors in the metadata cache
(`relation_meta`, `select_formats`, and the DELETE planner's own read),
and every consumer that types a `?` by copying a column's descriptor —
the predicate resolver, the SET list, the value list — inherits it. A
gate found the first draft of this (parameters made nullable
unconditionally): `serve-real-notnulldesc` pins exactly the NOT NULL
comparison. **And a second, smaller
one:** `raw_has_param` had no CASE arm, so `CASE WHEN … THEN ? END`
looked parameterless, took the ordinary resolver and refused — while
IIF, the same shape, answered. The asymmetry is what found it.

Boundaries recorded: a parameter in a CASE/IIF CONDITION (typed from the
other side of the compare — a different rule and its own slice), a
COALESCE whose arguments are ALL parameters (the engine's −804), a
parameter expression into a BLOB column, and a bare `?` in a select list
(−804 on the engine too, generic here).

**THE MERGE TAILS: PARAMETERS AND RETURNING EXPRESSIONS — DONE
2026-08-26 (`serve-real-mergeparam` 26).** Section D's executor has been
wired since the MERGE slice; these were its two recorded refusals.

A MERGE executes by DESUGARING each source row into ordinary
INSERT/UPDATE/DELETE statements built as TEXT, so a `?` could not ride
through as a slot — by the time the per-row statement is planned its
position in the original text is gone, and `plan_merge` refused the
moment the statement carried one. Each `?` becomes a numbered
`FC$P<n>` marker at prepare instead (text order, which is the order the
engine's input SQLDA is in), typed there, and written as its bound
literal at execute by `merge_subst`, beside the source row's own values.
The typing follows the slice above: a marker in a SET or an INSERT value
list takes its DESTINATION COLUMN's descriptor, one compared in the ON
clause or a branch's AND takes the column it is compared with, and
anything else — a parameter in the USING query, one compared with the
SOURCE, one standing outside a comparison — keeps the refusal.

`RETURNING <expression>` over a MERGE now goes through the select
list's own builder like every other RETURNING, with the TWO-CONTEXT rule
kept: the target's alias (or `NEW.`) qualifies a column and is stripped
before resolution, a BARE name the SOURCE also carries stays the
engine's 42702 rather than a silent pick, and a name the writer
qualified with the target is exempt from that check. A source column
inside the expression refuses — this path reads the target's
after-image, and the source is not in it.

Found while gating it: the INSERT ... SELECT re-render refused a DOUBLE
value ("a selected value cannot be written as a literal"), which a
MERGE branch carrying a double-bound parameter reaches — it renders
through `dml_subq_literal` now, the cast-over-shortest-round-trip form.

Still absent in D: `RETURNING OLD.x` and the source's columns in
RETURNING, `OVERRIDING`, `PLAN` / `ORDER BY`, the failed statement's
partial `Records affected` (the engine reports the rows it moved before
the raise; fc reports 0), and a trigger-bearing target (refused by the
per-row planners at execute, not at prepare).

**AN ICU COLLATION DECIDES THE ANSWER, AND THIS SERVER REFUSES RATHER
THAN ANSWERING BY BYTES — DONE 2026-08-27 (`serve-real-icucoll` 25).**
The roadmap's own line "collation-aware ordering (server keys binary)"
understated it: this was a SILENT WRONG-ANSWER class, and a broad one.
Firebird's `UNICODE`, `UNICODE_CI` and the language-specific collations
are ICU-backed — their order is the Unicode Collation Algorithm's, where
`'apple' < 'Ápple' < 'banana'`, and under CI `'apple' = 'APPLE'`. This
server compared and ordered the BYTES. Measured over one six-row
fixture: `ORDER BY <ci col>` answered 5,2,1,6,3,4 where the engine
answers 1,5,4,6,2,3; `WHERE CI = 'APPLE'` found ONE row where the engine
finds two; `GROUP BY CI` made SIX groups where the engine makes four;
`DISTINCT`, `MIN`/`MAX`, a join keyed on such a column and an
index-driven range were all wrong the same way.

There is no honest way to answer them here: the UCA's order is a table
this server does not have (and these crates carry no dependencies), so
every site where a collation decides now asks
`coll::keyable_ttype` — true for a charset's DEFAULT collation (byte
order: `UCS_BASIC` for UTF8) and for `PXW_INTL`, the one real collation
converted — and REFUSES when the answer is false. The sites: ORDER BY (a
column key and an EXPRESSION key, since the collation travels into the
result), the whole comparison family through `param_or_typed_term`, a
column-vs-column comparison through `resolve_expr_term` (which is what a
JOIN's ON is), GROUP BY in all three group planners, DISTINCT and a
distinct UNION (over the projection's own ttype — a text ProjCol's
`sub_type` IS the ttype), and MIN/MAX/COUNT DISTINCT.

**MIN/MAX refuses over `PXW_INTL` too**, which is not an ICU collation:
the fold ([compute_group]) compares plain values with no collation in
reach, and it answered `MIN(W)` = 'APPLE' where the engine answers
'apple'. Keying the fold is a slice of its own.

What is untouched: SELECTING such a column (bytes in, bytes out —
nothing is decided), its LENGTHS and CASTS, the whole default-collation
surface, and every PXW_INTL comparison and ordering, which keys as
before.

**...AND THEN IT ANSWERED THEM: THE ICU COLLATIONS, FROM THE UCA ITSELF
— DONE 2026-08-27 (`serve-real-icucoll` 25 refusals → 61 checks).** The
refusal above was honest but small; the table it lacked is a published
one, and there is a Rust implementation of it. **`icu_collator` is now
the ONE dependency in this workspace** (in `fire-crab-ods`; the release
binary grew 8.53 MB → 9.91 MB, all of it baked UCA data). It buys a
thing no amount of conversion can: the Unicode Collation Algorithm's own
order.

TWO LAWS, probed off the live engine over `apple/APPLE/Ápple/ápple` in
three columns:

1. **A SORT IS FULL STRENGTH whatever the column's collation is.**
   `ORDER BY <UNICODE>`, `ORDER BY <UNICODE_CI>` and
   `ORDER BY <UNICODE_CI_AI>` all answered `1 2 4 3`. A CI collation
   makes an EQUALITY loose; it does not make a SORT unstable. So an
   ordering key rides as `coll::TTYPE_UTF8_UNICODE` — not a fudge, a
   statement of that law.
2. **EQUALITY AND GROUPING READ THE COLLATION'S OWN STRENGTH.**
   `= 'APPLE'` took one row under UNICODE, two under UNICODE_CI, four
   under UNICODE_CI_AI.

Both are the same sort key cut at a different level, so one builder
answers both: `coll::icu_key(text, strength)` over a cached
`CollatorBorrowed` per strength, keyed through the existing
`Expr::CollKey` carrier (UCA key bytes are never zero, so a `0x00`
terminator makes a PREFIX key compare right and keeps the key out of
reach of the blank-stripping every text compare here does). Trailing
blanks are the pad and are not keyed (`texttype_pad_option`); a LEADING
blank is a real collation element (`' apple' < 'app le'`, measured —
the root table's non-ignorable variable weighting, which is ICU4X's
default).

WHAT NOW ANSWERS: ORDER BY (a column key, an ORDINAL, an EXPRESSION key,
DESC, NULLS FIRST/LAST, inside a derived table, under FIRST/SKIP and
under a JOIN), the whole comparison family (`=`, `<>`, the four ranges,
BETWEEN, an IN list, NOT IN, inside a CASE, through a derived table's
own name), the SEMI-JOIN rewrites (`IN (SELECT …)`, `= ANY`, correlated
`EXISTS`/`NOT EXISTS`, `NOT IN (SELECT …)`), a scalar subquery on the
other side, and UPDATE/DELETE `WHERE`.

TWO SILENT WRONG ANSWERS FELL OUT ON THE WAY, both pre-existing:

* **A semi-join's values travel as HASH KEYS** (`Rhs::StrKey`, the
  strict grammar's spelling) and that arm compared BYTES — so
  `CI IN (SELECT …)` answered ONE row where the literal
  `CI IN ('APPLE')` beside it answered two. The key arm now takes the
  collation like the literal one.
* **The BLR executor compares values, not descriptors**, and text values
  do not carry their collation — so a procedure body's
  `SELECT COUNT(*) … WHERE CI = 'APPLE'` answered 1 where the same
  statement typed at the prompt answered 2. `blr_reads_collated_relation`
  now stands the fast path aside for ANY non-default collation,
  PXW_INTL included, and the SOURCE interpreter re-plans the statement
  through the descriptor-aware planner. **The question is asked the way
  round that PROVES an answer**: the COLLATED RELATION SET is read from
  the catalog first (one walk per generation, memoised), and an empty
  set — every database in this suite but two — answers without decoding
  a byte. The first draft asked it of the BLR's own relation names and
  treated anything it could not resolve as collated; the sweep caught
  it refusing every recursive CTE in a procedure body (the recursion's
  name is no relation) and, through the decode-failure arm, every
  WINDOW one (`serve-real-exeproc`, `serve-real-funcbody`). Only a
  database that HAS a collation now pays for an undecodable body.

WHAT STILL REFUSES, each for a measured reason: `LIKE` / `STARTING WITH`
/ `CONTAINING` / `SIMILAR TO` (they match through the collation's own
MATCHER prefix by prefix, and a UCA key is not built prefix-wise — the
key of 'app' is no prefix of the key of 'apple'; measured,
`CI STARTING WITH 'APP'` takes 'apple' too); `GROUP BY` / `DISTINCT` /
a distinct UNION (not the COUNT — the surviving SPELLING, which follows
the engine's own sort's internal order and no rule this server could
reproduce. Measured three ways: over {apple, APPLE} `GROUP BY CI` kept
whichever was inserted SECOND — 'APPLE' one way round, 'apple' the
other; over four spellings {aPPle, APPLE, apple, ApPlE} it kept 'apple',
which is neither the first nor the last record, and stayed on 'apple'
after that row was deleted and re-inserted LAST; and `SELECT DISTINCT`
answers a different survivor from `GROUP BY` over the same rows);
`MIN`/`MAX`/`COUNT(DISTINCT)` (the fold, as before, PXW included); an
EXPRESSION over such a column inside a comparison (`UPPER(ci) =` — the
collation travels into a result there is no key for, so `cmp_sides`
refuses it rather than comparing bytes, which is what it silently did
before); a JOIN keyed on one; two DIFFERENT collations meeting in one
comparison; and an explicit `COLLATE` clause.

**...AND THEN THE FOLD AND THE GROUP KEYED IT TOO — DONE 2026-08-27
(`serve-real-icucoll` 61 → 74 checks).** Three of the refusals above
turned out to be two different questions wearing one coat, and only one
of them is unanswerable.

**THE FOLD.** `MIN`/`MAX` pick by the collation's ORDER and
`COUNT(DISTINCT)` buckets by its EQUALITY — and both read the
collation's OWN strength, not the full-strength order a SORT uses.
Measured: `MIN(<UNICODE_CI col>)` over {APPLE, apple} answered whichever
row came FIRST, both ways round — so to the fold the two are EQUAL and
`compute_group`'s keep-unless-strictly-less rule decides, where a sort
would have answered 'apple' either way. New `AggSrc::CollField(fid,
ttype)` carries the ttype into the fold (`agg_field_src` builds it at
all four planner sites, `agg_src_fid` reads through it), and a new
`fold_cmp` runs `coll_value_cmp` — PXW_INTL through its converted key
tables, the ICU family through `coll::icu_key`. **This closes the
PXW_INTL fold too**, which had answered `MIN(W)` = 'APPLE' where the
engine answers 'apple'. What still refuses is what has no key: a
tailored/narrow ICU collation, and an EXPRESSION source that READS a
collated column (`MIN(UPPER(ci))` carries the collation into a result
there is no key for — that one was a SILENT byte fold before, since the
old check looked only at `AggSrc::Field`).

**THE GROUP.** A collation that never calls two DIFFERENT strings equal
asks no "which spelling survives" question at all — so `UNICODE` (and
`PXW_INTL`, and every charset default) now GROUPs and DEDUPLICATEs,
while `UNICODE_CI`/`UNICODE_CI_AI` keep refusing for the reason above.
`coll_groupable_ttype` draws that line; the octets-only masks became
TTYPE masks (`coll_key_mask`, `coll_cols`, `rows_equal`,
`distinct_rows`, `group_rows`), so a group's buckets AND its ORDER come
from the collation.

TWO MORE PRE-EXISTING DEFECTS FELL OUT:

* **`coll_key_mask` read the PROJECTION**, matching `ProjCol::field_id`
  against a key's field id — but in a GROUPED plan a ProjCol's
  `field_id` is its OUTPUT SLOT, not a record field. `GROUP BY <col>`
  looked up key field 1 among output slots 0 and 1 and took slot 1, the
  COUNT, whose ttype is 0. It reads the RECORD descriptors now, and
  `Plan::JoinGroup` carries the mask from PLAN time because execute has
  the joined rows but not their descriptors.
* **A grouped ORDER BY was parsed with NO descriptors** (`&[]`), so a
  key over a collated group key came back `coll: 0` and sorted the
  groups by BYTES — `GROUP BY <PXW col> ORDER BY 1` answered byte order
  where the engine answers 'ae', 'ä', 'apple', 'APPLE', … The new
  `stamp_group_order_coll` stamps those keys from the group row's SLOT
  descriptors, in all three grouped planners.

**...AND THE COLLATION A STATEMENT WRITES FOR ITSELF — DONE 2026-08-27
(`serve-real-collclause` 30).** `COLLATE <name>` on an OPERAND, which is
what lets a statement ask a COLLATED column for the BYTE answer
(`CI COLLATE UCS_BASIC`) and an UNCOLLATED one for a collation's — the
half of the collation story that is not in the DDL.

Two grammars needed it, because a `COLLATE` can be written on either
side of the same statement: the TOKEN one (predicates) and the
CHARACTER one (the select list and the DML value surface). In both it is
a POSTFIX ON THE ATOM, the tightest binding SQL gives it — `A || B
COLLATE X` collates B. It resolves to `Expr::Collate(inner, ttype)`, an
IDENTITY at eval (a projected `S COLLATE X` answers S) that the
deciding sites read: `cmp_sides` wraps BOTH sides in `Expr::CollKey` of
that ttype, an ORDER key takes it instead of the operand's own
(`OrderKey::coll_explicit` keeps a grouped re-stamp off it), and
`agg_expr_src` folds `MIN/MAX/COUNT(DISTINCT)(<col> COLLATE <name>)`
into `AggSrc::CollField`. `UCS_BASIC` and a charset's own name resolve
to the ttype with collation byte ZERO - both order by the codepoint,
which over every charset here IS the stored byte order - so every site
downstream reads them as "no collation decides this".

DESCRIBE: the engine builds a CastNode for the clause, so the column is
named **CAST** (name and alias) and describes as its OPERAND — same
type, same width, same charset (`strip_collate_target` reads the
aggregate describe through it, which also stopped `MIN(S COLLATE X)`
inheriting the pre-existing "MIN over a TEXT expression" refusal).

THREE ERROR VECTORS, byte for byte: a name that is no collation of the
operand's charset is -204 / SQLSTATE 22021 `COLLATION "PUBLIC"."NOSUCH"
for CHARACTER SET "SYSTEM"."UTF8" is not defined`; a REAL collation of
ANOTHER charset answers the same with `"SYSTEM"` as its schema (a
collation belongs to ONE charset, and the name IS a built-in), told
apart by reading `RDB$COLLATIONS` (new `ods::ddl::collation_lookup`,
reached through the new `PLAN_IMAGE` thread-local — the same shape
`USER_FNS` uses, since the resolver is far from any `db`); and a
`COLLATE` on a non-TEXT operand is -204 / HY004 `Data type unknown` +
`Invalid use of CHARACTER SET or COLLATE`, which the engine answers
BEFORE it ever looks the name up.

REFUSED: `GROUP BY` / `DISTINCT` under a written collation. Grouping
keys off the RECORD descriptors here and a synthetic expression slot
carries no ttype, so the buckets AND the group order would be the
bytes' (measured: four groups where the engine makes three). A
statement-wide `EXPLICIT_COLL_SEEN` flag refuses them — a FLAG rather
than a walk of the resolved tree, because a walk that misses one
container variant misses a wrong answer and this cannot; the cost is
over-refusal (a `COLLATE` in the WHERE of a grouped query refuses it
too), and a GLOBAL aggregate is exempt since it buckets nothing. Also
refused: a collation with no table here, and a `COLLATE` on a literal
beside a collated column (the engine has a precedence rule between
them — measured that a column's CI beats a literal's explicit
`COLLATE UNICODE` — but not one this server has pinned).

**...AND THE LAST COLLATION REFUSAL: TWO COLLATIONS IN ONE COMPARISON —
DONE 2026-08-27 (`serve-real-icucoll` 74 → 77).** A JOIN keyed on a
collated column, and a column-vs-column comparison generally, were the
last shapes refused outright. **The engine does not raise on mixed
collations: it compares under `MAX(t1, t2)`, the numerically larger
TTYPE** (`INTL_compare`, `src/jrd/intl.cpp:380`, marked "YYY" in the
engine's own source with the comment that SQL II would have wanted the
collation written explicitly). A ttype is `(collation << 8) | charset`,
so within one character set that is the higher COLLATION id — read off
the source AFTER six probes had suggested the same shape, which is the
right order to trust them in.

`cmp_sides` now keys both sides at `MAX(t1, t2)` when the two bare
columns disagree, and the same rule already covered the one-sided case
(a literal or a plain column adopts the collated one's). ACROSS two
character sets the engine transliterates the other side first, which
this comparison does not do — refused. `resolve_expr_term`'s early
guard, which had refused any comparison reading a collated column
before `cmp_sides` ever saw it, now steps aside for a COMPARISON and
keeps refusing for `LIKE`/`STARTING WITH`/`CONTAINING`/`SIMILAR TO`,
which match through the collation's own matcher. And the fallback guard
that catches an EXPRESSION over a collated column widened from ICU-only
to ANY declared collation: `PXW_INTL` expands `ä` to `ae`, so its
compare is not the bytes' either, and `UPPER(<PXW col>) = 'x'` had been
answering by bytes.

**...AND THE PATTERN FAMILY, WHICH READS A DIFFERENT FORM ENTIRELY —
DONE 2026-08-27 (`serve-real-icucoll` 77 → 88).** `LIKE` and
`STARTING WITH` were refused on the grounds that a UCA sort key is not
built prefix-wise. True, and beside the point: **the engine does not
match patterns with the sort key at all.** It converts BOTH the value
and the pattern to the collation's CANONICAL FORM and runs the ordinary
matcher over that (`CanonicalConverter`, jrd/intl_classes.h:112 →
`TextType::canonical`), and for the ICU family that conversion is six
lines (`Utf16Collation::normalize`, common/unicode_util.cpp:2077):

* `UNICODE` has neither attribute, so **the canonical form IS the
  string** — its `LIKE` is the plain code-point match every uncollated
  column already got, and lifting the refusal was the whole change;
* `UNICODE_CI` UPPER-CASES (ICU's `u_strToUpper` at the root locale =
  Unicode's full uppercase, so `ß` becomes `SS`);
* `UNICODE_CI_AI` upper-cases and then transliterates by a rule the
  engine spells out in full (unicode_util.cpp:326):
  `::NFD; ::[:Nonspacing Mark:] Remove; ::NFC;` plus `Ð>D Ø>O Ŀ>L Ł>L`,
  the four letters whose accent is not a combining mark (CORE-4136).

New `coll::icu_canonical` implements exactly that — `icu_normalizer`
and `icu_properties` became direct dependencies for the NFD/NFC and the
Nonspacing-Mark test, both already in the graph under `icu_collator`,
so nothing new was downloaded or linked. New `Expr::CollCanon(inner,
ttype)` canonicalises the VALUE per row while the PATTERN is
canonicalised ONCE at prepare, which is what makes this cheap; the
ESCAPE character is canonicalised too, and one that canonicalises to
more than a single character (an upper-cased `ß`) refuses. Both the
bare form (`ci LIKE 'A%'`) and the written one (`s COLLATE UNICODE_CI
LIKE 'A%'`) take it.

STILL REFUSED: a `?` pattern (no value at prepare, and canonicalising
at bind is its own slice), `SIMILAR TO` (its pattern is a grammar, and
canonicalising a character class is not the same operation), and
`CONTAINING` — which is not a collation limit at all: this server has
never implemented it.

**...AND `CONTAINING`, WHICH THIS SERVER HAD NEVER IMPLEMENTED AT ALL —
DONE 2026-08-27 (`serve-real-containing` 28, new).** The collation
chunks kept recording it as a refusal beside `LIKE`; reading the engine
showed it is not a collation limit at all — `CONTAINING` appeared in
one keyword list here and nowhere else, for ANY character set.

THE LAW, from the matcher's own type: `ContainsMatcher<UCHAR,
UpcaseConverter<>>` for a direct collation (Collation.cpp:1075) and
`CanonicalConverter<UpcaseConverter<>>` for one with a canonical form
(:527). So **CONTAINING upper-cases FIRST — on every character set,
whatever the column's collation — then canonicalises, then searches for
a substring**, which is why it is the one predicate that folds case
everywhere. Its sibling `STARTING WITH` takes `NullStrConverter` for a
direct collation (no conversion at all: case-SENSITIVE) and the
canonical converter WITHOUT the upcase for the rest — the difference
the new gate exists to hold still.

Implemented as a DESUGAR onto the machinery the pattern chunk just
built: `x CONTAINING p` becomes
`CollCanon(x, ttype, upcase) LIKE '%' || escaped(upcase_canon(p)) || '%'
ESCAPE '\'`, with the pattern's own `%`, `_` and backslash escaped
first — CONTAINING has NO wildcards (measured: `S CONTAINING '%'` takes
only the row holding a literal per-cent). `Expr::CollCanon` gained the
upcase flag; new `upcase_cs` folds by the CHARACTER SET's own law
(OCTETS has none, a tabled single-byte set has its table, everything
else takes `intl::simple_case`).

Measured and pinned: an EMPTY pattern matches every non-NULL row; NULL
on either side is UNKNOWN negated or not (`Term::Never` both ways); an
INTEGER operand renders to its decimal text; a CHAR operand's padding
is irrelevant (a substring test, not a comparison); `NOT CONTAINING`
needed the keyword added to the two NOT-lookahead lists, since it lexes
as an Ident like STARTING and SIMILAR.

REFUSED: under `PXW_INTL` — a NARROW collation's canonical is its own
table, which this server has not converted, and upper-casing alone
would be a guess about what that table says; a `?` or binary pattern;
and CONTAINING (or STARTING WITH) as a boolean VALUE in the SELECT
list, which is a different grammar that knows only LIKE — a
pre-existing gap this predicate inherits rather than one it adds.

**...AND THE LAST THREE PREDICATES THAT WERE NOT ALSO VALUES — DONE
2026-08-27 (`serve-real-containing` 28 → 33).** In Firebird a predicate
is a BOOLEAN expression, usable anywhere a value is. This server has
TWO expression grammars — a TOKEN one for predicates and a CHARACTER
one for the select list and the DML value surface — and the character
one's condition parser knew only `LIKE`. So the same test answered in a
`WHERE` and refused in a `CASE`.

Probed which predicates could already be values: comparisons, `LIKE`,
`BETWEEN`, `IN`, `IS NULL`, `AND`/`OR`, `EXISTS` and `IS DISTINCT FROM`
all could; exactly three could not — `STARTING WITH`, `CONTAINING` and
`SIMILAR TO`. All three parse there now (each keyword lexes as an
Ident, so each is matched by text, and each takes a LITERAL pattern
only — the restriction `LIKE` already had on that side; `read_quoted`
declines a `?` or an expression pattern rather than mis-reading it).

`Cond2` gained `Starting` and `Similar`, mirroring `Term::ExprStarting`
and `Term::ExprSimilar` exactly — render, then the prefix test or the
prepare-compiled regex. `CONTAINING` needed no variant: it desugars to
`Cond2::Like` through the SAME `containing_term` the predicate path
uses, so the upcase-then-canonical rule has one implementation rather
than two. Each keeps its collation law as a value: `starting_canon`
canonicalises both sides under an ICU collation and refuses a collation
with no canonical form here, and `SIMILAR TO` refuses a collated
operand as it does in a `WHERE`.

**A BEFORE TRIGGER THAT DRAWS A GENERATOR — DONE 2026-08-28
(`serve-real-triggen` 15, new).** The classic Firebird auto-increment
(`IF (NEW.ID IS NULL) THEN NEW.ID = GEN_ID(G, 1)`) refused at CREATE
TRIGGER, and a table carrying such a trigger then refused every INSERT.
Both halves are done.

THE BLR: `ods::expr::Expr` gained `GenId { name, step }` and
`GenId2 { name }`, emitting `blr_gen_id` (a COUNTED name then the step
as an ordinary expression) and `blr_gen_id2` (the counted name ALONE).
`NEXT VALUE FOR` is a DIFFERENT VERB, not sugar for `GEN_ID(g, 1)`
(probed both ways), and it advances by the SEQUENCE'S OWN increment -
the `step.unwrap_or(incr)` rule the DML draw path already followed. The
engine reads back what this server writes, byte for byte.

THE RUN, and the reason it needed a design at all: a draw is a PAGE
WRITE, and a trigger fires inside a statement that is already holding
the working copy of that page - the comment at [trig_body_pure] has said
so since the trigger chunk. So the draw belongs to the CALLER, and the
body runs TWICE around it ([PsqlFrame::gen]): pass one RECORDS what it
would draw (every draw answering 0, over a COPY of the row), the caller
performs exactly those draws through the same `gen_bump_through_cache`
the statement's own `NEXT VALUE FOR` columns take, and pass two REPLAYS
the values in order. All six firing sites carry a drawer now.

Two passes are sound because a runnable body is otherwise PURE and both
start from the same row - and the design was chosen for the two cases
that decide it:

* a CONDITIONAL draw consumes nothing when its branch is skipped (an
  INSERT that supplies its own ID leaves the generator alone - measured
  against the engine, and the case a "pre-draw the values" design gets
  WRONG);
* a body that RAISES after drawing still consumes the value, because
  pass one's recorded draws are performed even though its outcome is
  discarded. The generator is not transactional, and that is what the
  engine does.

REFUSED, at prepare: a body whose CONTROL FLOW would read a value a draw
produced ([body_draw_decides_flow]), since pass one answers 0 for every
draw and the two passes could then take different branches. The check is
ORDER-AWARE - the classic trigger reads `NEW.ID` BEFORE anything assigns
it and passes, while `NEW.ID = GEN_ID(G,1); IF (NEW.ID > 100) ...`
refuses, and so does a loop whose condition reads what its own body
draws. Also refused: a draw in a DEFERRED (database-touching) body, and
a draw in a computed column or a CHECK.

GATE LESSON worth keeping: the ENGINE side of a `refuses` check RUNS the
statement, and **a generator draw is not transactional** - so a refused
trigger must not share a sequence with anything the gate compares, or
the two files drift by one and every later check DIFFs.

**THE ROW CONTEXTS OF `RETURNING` — DONE 2026-08-28
(`serve-real-returnold` 25, new).** This one started as a WRONG LAW in
this file's own source: "`NEW.`/`OLD.` do NOT exist in DSQL - they are
the PSQL trigger contexts, and the engine answers `Column unknown,
"NEW"."ID"`". That was probed on an INSERT, where it is true, and
generalised to all DML, where it is not.

**An UPDATE has TWO rows and names them**: `OLD.<col>` is the
before-image, `NEW.<col>` the after-image, and a BARE name is NEW
(measured: `RETURNING OLD.N, NEW.N, N` over `SET N = N + 1` answers
10, 11, 11). An INSERT and a DELETE have ONE row and no contexts at all
- there the engine's -206 stands.

The before-image is APPENDED to each returned row at `width` (the
`Affected` collector has carried `old_images` since the trigger chunk),
and an `OLD.` reference resolves there: as a plain column it becomes an
expression column over `Expr::Col(width + fid)` described exactly as the
column it names, and INSIDE an expression it is rewritten to a synthetic
`OLD$<col>` first (`rewrite_old_refs`, which walks the MASKED text so
`RETURNING 'OLD.N' AS L, OLD.N` keeps its string literal). `NEW.` comes
off entirely - that image is the row this route already read.

RECORDED BOUNDARIES: `INSERT`/`DELETE` with either qualifier refuse on
both servers, but the engine's is `-206 Column unknown "NEW"."ID"` and
this server has no -206 machinery, so the gate asserts BOTH REFUSE
without comparing vectors and says so in its own output. `RETURNING *`
is not implemented here at all, so `OLD.*` rides on it. And an ALIASED
DML TARGET (`UPDATE T t SET ...`) is refused by the planner outright -
the alias-as-qualifier support is wired (`dml_target_alias`) but
unreachable until that lands, and the gate pins the refusal so it cannot
be mistaken for this chunk's doing.

TWO CLEANUPS the ICU chunks recorded, done here: `stamp` and
`order_key_ttype` were the same rule written twice (unified — the
shared one also handles the negative-sentinel sub_type the other read
as a huge u16), and `coll_groupable_ttype`'s PXW_INTL clause was
already covered by `keyable_ttype`.

WHAT IS NOT CLAIMED: only the three ROOT collations over UTF8
(`UNICODE` = tertiary, `UNICODE_CI` = secondary, `UNICODE_CI_AI` =
primary, by their fixed built-in ids 2/3/4). A language-TAILORED
collation (`DE_DE`, `ES_ES_CI_AI`) is a tailoring of the root table and
would need its locale threaded through; an ICU collation over a NARROW
charset would need its byte-carrier values decoded to real text first.
Both keep refusing. An INDEX over a collated column is still not used
for retrieval (its itype is unknown to the index-op reader) and an
INSERT into a table carrying one still refuses — pre-existing, and the
reason the gate's fixture has no index.

**COMPILING A TEXT BODY — DONE 2026-08-29 (`serve-real-trigtext` 14 →
16).** The asymmetry the two slices before this one left: a body that
builds a string RAN here but could not be CREATED here, and creating
triggers is what a client does. `CREATE TRIGGER` refused every body
carrying a text literal, on a comment that had gone stale — "the
emitter's shape for `blr_literal blr_text` has never been held against
the engine's".

It has now. Probed out of engine-written TRIGGER BLR, not reasoned
about: a literal is `blr_literal blr_text2 <charset u16> <len u16>
<bytes>` with charset NONE (which is what `ods` had emitted all along,
gold-pinned from a CHECK), and a concatenation is `blr_concatenate`
(39) in prefix form. `Expr::Concat` carries it, `||` lexes and parses
BELOW `+ -` (the engine's precedence, so `'a' || 1 + 2` is `'a' || 3`),
and the gate compares fire-crab's stored bytes with the engine's for a
literal, a concatenation, and a three-way join over a CHAR column: all
byte-identical, and the ENGINE RUNS what this server compiled.

The column gate moved with it. A trigger body's references were INT-ONLY
— a plain SMALLINT/INTEGER/BIGINT — which is why a text body refused
even once the value shapes were right; `body_col_class` takes the
integer family and TEXT now, and still refuses a scaled numeric, a date
or a blob, so a body naming one is interpreted or refused rather than
stored under BLR nobody has held against the engine's.

Adding a variant to the shared `Expr` enum surfaced TWELVE exhaustive
matches across `ods` and `wire`, each answered with what a
CONCATENATION IS in that context rather than a copied default: it has no
integer rank (so the INT-ONLY surfaces keep refusing one), it IS text
whatever its operands are, it walks both sides like the arithmetic
nodes, and it evaluates with NULL-on-either-side-is-NULL.

AND THE DECLARATION WITH IT (same day, `serve-real-trigtext` 16 → 15
checks — one boundary became part of a comparison). A body may DECLARE
the variable it builds its message in: `DECLARE VARIABLE S VARCHAR(60)`
in a UTF8 database is `03 <id u16> 26 0400 F000` — `blr_varying2`,
charset 4, 240 = 60 x 4 BYTES — and a `CHAR(5)` is `03 <id u16> 0F 0400
1400`, `blr_text2` over 20. `DeclType` carries the two shapes where a
single dtype byte used to, the length is written in BYTES from the
database's default charset, and the engine's ONE dependency row on the
CHARACTER SET (object type 17, whatever the count of such variables) is
written beside it. Both compile byte-identically.

A parser trap worth keeping: `VARCHAR(60)` is ONE word to
`split_whitespace`, so the four-word arm that matched the integer names
also matched it and returned before the text arm was ever reached. The
arms are one now, with the length split off inside.

**THE MONITORING TABLES, AND THE ALL-NULL ROW — DONE 2026-08-29
(`serve-real-monitoring` 10, new).** `MON$` queries were answered by ONE
ALL-NULL ROW whatever they asked. `SELECT COUNT(*) FROM
MON$ATTACHMENTS` answered NULL — which COUNT never does — under a column
called `C0` rather than the name the query gave it. The relation was
never consulted at all: a `MON$` prefix short-circuited to
`Plan::VirtualEmpty { ncols }`, with the column count taken from the
top-level commas rather than a parse.

They are REAL CATALOG RELATIONS (`MON$DATABASE` is relation 33 with 28
fields), so they go down the ORDINARY path now and are described from
the catalog like anything else. `MON$DATABASE` is COMPUTED — one row of
what this server knows for certain about the file, read through the same
`HeaderPage` decoder gstat and gfix use. Every other `MON$` table scans
its own empty storage and answers NO ROWS, with the right shape and the
right names.

TWO FAST PATHS HAD TO LEARN THE SAME WORD. A computed relation has no
record headers, so `StreamCursor::open` (which walks data pages) and the
`COUNT(*)` fast path (which counts headers without decoding) both
DECLINE for one and leave it to the materialising scan — the count
answered 0 where the scan answers 1 until it did.

AND THE HEADER IS DECODED, NOT INDEXED. The first cut read the offsets
by hand and had ODS at **-32754** and the sweep interval at nonsense:
`ods_major` strips a flag bit, `page_buffers` sits where the guess put
`oldest_transaction`, and the sweep interval is not a field at all but a
CLUMPLET in the variable header, defaulting to 20000 when absent.
`HeaderPage` knew all of it.

WHAT IS LEFT NULL, deliberately: `MON$PAGE_BUFFERS` (the engine's
RUNTIME cache size, and this server's cache is not that), `MON$OWNER`,
`MON$FILE_ID`, `MON$CREATION_DATE`, `MON$NEXT_STATEMENT`. Each would be
a guess, and a guess in a monitoring table is an answer nobody can act
on.

**AND THEN `MON$ATTACHMENTS` (same day, `serve-real-monitoring` 10 →
13).** The divergence above, closed for the table an operator actually
opens: one row per live attachment, from a registry each session keeps
on the file's `DbGate` — added at the attach, removed wherever the
session ends, which is the same pair of places `ON DISCONNECT` fires
from. It answers who attached, the file they opened, the PEER address
(which only the server can know), the protocol, the state and whether
the wire is encrypted; and the gate holds the property that matters -
**the count follows the connections**, 1 then 2 then 1 as a second
session opens and goes.

The columns a CLIENT sends in its DPB - its process id and name, its
host, its OS user, its library version - are not retained by this
server, so they answer NULL rather than a guess, and the gate asserts
that too.

**AND `MON$TRANSACTIONS` WITH IT (`serve-real-monitoring` 13 → 17).**
Every attachment's live transactions, published by the sessions that own
them. A `SNAPSHOT` transaction reports mode 1 and ACTIVE on BOTH
servers, which is the comparison that can be made — and every
transaction joins an attachment this server also names.

WHICH ONE IS ACTIVE MOVES WITH THE STATEMENT, which is why the publish
is once per REQUEST rather than only where a transaction starts or ends:
a client may prepare on one handle and execute on another (isql does),
so a flag written at `SET TRANSACTION` is stale by the time anybody
asks. It named the snapshot transaction idle and isql's spare one
active, exactly backwards from the engine, until the refresh moved to
the top of the op loop.

A DIVERGENCE IN WHAT THE SERVERS DO, not in what they report, recorded
and gated: the engine's default read committed is READ CONSISTENCY (mode
4) and this server reads the latest committed version (mode 2). Each
answers what it actually does — which is the point of the column.

**AND `MON$STATEMENTS` CLOSES IT (`serve-real-monitoring` 17 → 19).**
What each attachment has prepared, with the one it is working on marked
ACTIVE and its text as a COMPUTED BLOB - the machinery `LIST()` brought.
The comparison this allows is the strongest on the surface: **the
statement a server reports as running IS the query asking**, so both
must answer the same TEXT. They do.

A REAL DEFECT FELL OUT OF IT, and it was not in the monitoring code. A
computed blob carries relation 0 and lives in the mint context until the
op ends, so the blob reader - which reads out of the FILE - refused it,
and `CAST(<a computed blob> AS VARCHAR(n))` answered NO ROWS AT ALL
where the engine answers the text. Silently: no error, no row, nothing
to act on. `blob_text_of` serves relation 0 from the mint now, which
fixes the same shape for `CAST(LIST(x) AS VARCHAR(n))`.

The gate compares the TEXT and not the blob's ID: a computed blob is
minted from this server's own range (`0:40000001`) where the engine
hands out `0:1`, and neither number is a fact about the statement.

THE SURFACE IS NOW: `MON$DATABASE`, `MON$ATTACHMENTS`,
`MON$TRANSACTIONS` and `MON$STATEMENTS` answered from live state, and
every remaining `MON$` table honestly empty with the right shape and
names - `MON$CALL_STACK` and the statistics tables among them, each
asserted at 0 rather than NULL.
An empty relation of the right shape is something a client can read —
the all-NULL row was not. The one thing that row bought, a firebird-qa
bootstrap whose projection uses `COUNT(DISTINCT ...)` and `IIF(...)`,
is a REFUSAL now: the honest answer to a query this server cannot read.

**A BODY CONDITION THE PLANNER ANSWERS — DONE 2026-08-29
(`serve-real-trigtext` 10 → 14, `serve-real-ddltrigger`'s recorded
policy refusal became a comparison).** The other half of the body
grammar. Values were freed in the text slice; a CONDITION was still the
arithmetic `Cond` — so `IF (UPPER(NEW.V) = 'AB')`, `IF (NEW.V LIKE
'a%')`, `IF (NEW.V IS NULL)` and above all `IF
(RDB$GET_CONTEXT('DDL_TRIGGER', 'OBJECT_NAME') = 'X')` were outside it.
That last one is how ANY DDL policy is written, so the chunk that made
DDL triggers fire could not run the trigger anybody would actually
write; the statement refused instead, honestly but uselessly.

Same mechanism as the values, and the same reason it is right: when the
arithmetic parse declines, the CONDITION TEXT is kept as written and the
frame substituted into it, then the ORDINARY planner answers it —
`SELECT COUNT(*) FROM RDB$DATABASE WHERE (<cond>)`, which is 1 for TRUE
and 0 for FALSE **or UNKNOWN**. That is exactly `IF`'s own three-valued
rule: only TRUE takes the branch (measured: `WHERE (NULL = 1)` counts
0), and the gate runs every test over a NULL to hold it there.

A `WHILE` takes the same path, so a loop may be driven by a test the
planner answers. Nothing that parsed before changes: the raw form is
kept only where the arithmetic parse declines, and a body carrying one
cannot be COMPILED to BLR (`body_has_uninterpretable_blr`), exactly as a
body carrying a text literal or a raw-values `INSERT` could not.

**WRITING A DDL TRIGGER — DONE 2026-08-28 (`serve-real-ddltrigger` 13
→ 14).** The other half, and the last piece of the trigger taxonomy:
`CREATE TRIGGER ... BEFORE ANY DDL STATEMENT`, `AFTER CREATE TABLE OR
DROP TABLE`, a single event with a `POSITION` — all compiled HERE, with
the catalog row, the BLR and the debug info the engine's BYTE FOR BYTE,
after which the ENGINE RUNS what this server compiled.

`CREATE TRIGGER` now has THREE shapes and one parser: a relation trigger
names its table (`FOR TBL BEFORE INSERT`), a database trigger names an
event after `ON`, and a DDL trigger names DDL VERBS after `BEFORE` or
`AFTER` with no `ON` at all. With no `FOR`, the head starts at whichever
keyword comes first — `ON`, `ACTIVE`, `INACTIVE`, `BEFORE` or `AFTER` —
which is what tells the last two apart.

The type is the family, the after-bit and a BIT PER EVENT, so an `OR`
list is a bitwise OR and `ANY DDL STATEMENT` is every bit at once:
`AFTER CREATE TABLE OR DROP TABLE` is 16395 = `16384 | 1 | (1 << 1) |
(1 << 3)`, which fire-crab and the engine now write identically.

**DDL TRIGGERS — DONE 2026-08-28 (`serve-real-ddltrigger` 13, new).**
The third trigger class, and the one a schema is POLICED with: `BEFORE
ANY DDL STATEMENT` to audit or forbid, `AFTER CREATE TABLE` to react,
with a context namespace of its own — `RDB$GET_CONTEXT('DDL_TRIGGER',
'DDL_EVENT' | 'OBJECT_NAME' | 'SQL_TEXT')`. This server read them from
the catalog and IGNORED them, so a database that forbids `DROP TABLE`
let one through.

HOW A TRIGGER'S TYPE SAYS WHAT IT IS (`jrd/constants.h`:362, then
measured against the engine's own rows): `RDB$TRIGGER_TYPE >> 13 & 3` is
the FAMILY — 0 a relation's DML trigger, 1 a database trigger, 2 a DDL
trigger — and a DDL trigger's type is `TRIGGER_TYPE_DDL | (AFTER ? 1 :
0) | (1 << event)` for EVERY event it names, so one trigger may fire for
many. `AFTER CREATE TABLE` is 16387 = `16384 | 1 | (1 << 1)`; `BEFORE
ANY DDL STATEMENT` is 9223372036854767614, every event bit with the
family bits and the after-bit cleared and the family put back.

THE REFUSAL THAT MATTERS: a DDL statement whose event this server cannot
NAME, in a file that carries a DDL trigger, refuses rather than running
unwatched. A trigger that did not fire is a policy that did not run, and
nothing else would say so. The same rule catches a body this server
cannot RUN — a policy written as `IF (RDB$GET_CONTEXT('DDL_TRIGGER',
'OBJECT_NAME') = 'X')` is outside the body-condition grammar, so the
statement it would police refuses (recorded, and gated).

TWO DEFECTS THE GATE FOUND, both already-learned laws in a new place:

1. **The engine WRAPS every DDL failure**, its triggers' raises
   included: `unsuccessful metadata update` / `-DROP VIEW
   "PUBLIC"."VG" failed` / then the exception. This server answered the
   exception alone. `EvalErr::DdlFailed` carries the wrapper, and
   `ddl_verb_gds` the per-verb message (`sqlerr.h`; the code is
   `0x14000000 | (13 << 16) | <number>`).
2. **A DDL statement whose triggers write needs a `Nested` window** —
   the same law the DML-trigger chunk learned. Their rows are installed
   by statements of their own, which dropping a working copy cannot take
   back: the audit row of a REFUSED `DROP VIEW` survived here where the
   engine has none.

RECORDED BOUNDARY: this server does not COMPILE a DDL trigger yet, so
the gate's triggers are made by the engine on both files and what is
under test is FIRING them — the same order the database-trigger pair
went in.

**A TRIGGER BODY THAT BUILDS A STRING — DONE 2026-08-28
(`serve-real-trigtext` 10, new).** Writing a message is the commonest
thing a PSQL body does — an audit row saying what changed, a log line
carrying the key — and every one of them refused: a body's values were
parsed into an ARITHMETIC grammar (`+ - * /` over integers) and a
concatenation is not in it. `INSERT INTO LOG VALUES (NEW.ID, 'set to '
|| NEW.A)` was outside the surface, and so was the two-step form that
builds the string in a variable first.

THE FIX IS NOT A BIGGER EXPRESSION GRAMMAR. A body's own statement is
already rendered back to SQL and run by the ORDINARY planner, which
knows the whole value grammar — so when a value will not fit the
arithmetic form, `TrigStmt::Store` keeps the VALUES TEXT AS WRITTEN and
substitutes the frame into it (`subst_body_query`: `:var`, `NEW.<col>`,
`OLD.<col>`). Concatenation arrives with everything else the planner can
do — the gate pins `UPPER`, `CASE`, `CAST` and `SUBSTRING` in a body's
`VALUES` — and nothing that parsed before takes the new path, because
the raw form is kept only when the arithmetic parse declines.
`DynPart::Row` does the same for the two-step form, where the string is
built in a variable first.

THE LAW THAT COST A WRONG ANSWER: **trailing blanks belong to a value
and not to a statement.** A CHAR variable holding a whole statement is
padded to its declared width and that padding is no part of the SQL
(probed long ago: a CHAR(40) holding a SELECT runs) — but a
CONCATENATION keeps every blank: measured, `'[' || <a CHAR(6) holding
'ab'> || ']'` is `[ab    ]` on the engine. One renderer served both and
trimmed for both, so the first cut of this slice answered `[ab]`. It
trims only where the whole value IS the statement now, and the gate
reads every row back inside `<>` so a trailing blank is visible.

A SECOND, smaller one: a substituted NEGATIVE number has to be
PARENTHESISED. `'set to ' || NEW.A` over `A = -3` became `'set to ' ||
-3`, where the leading minus reads as an operator and the statement
refuses; `(-3)` is the same value in every position.

RECORDED BOUNDARY: this server will not COMPILE such a body to BLR — it
has no probed byte shape for a text expression — so `CREATE TRIGGER`
refuses to STORE one, exactly as it already refused a body carrying a
text literal. The gate's triggers are made by the engine on both files;
what is under test is RUNNING them. (`serve-real-dbtrigger`'s recorded
concatenation refusal became an answer and is now compared.)

**WRITING A DATABASE TRIGGER — DONE 2026-08-28 (`serve-real-dbtrigger`
10 → 12).** The other half of the entry below: `CREATE TRIGGER ... ON
CONNECT` (and its four siblings) compiles HERE now, and its catalog row,
BLR and debug info are the engine's BYTE FOR BYTE — after which the
ENGINE RUNS what this server compiled, which is the check that matters.

`CREATE TRIGGER` has two shapes: a relation trigger names its table
(`FOR TBL BEFORE INSERT`), a database trigger names an EVENT (`ON
CONNECT`, `ON TRANSACTION COMMIT`). The row is written with
`RDB$RELATION_NAME` left NULL — `sys_insert` starts every field NULL, so
it is simply not written — and its name must be unique across ALL
triggers rather than within one relation's.

THREE DEFECTS, each measured against the engine's own bytes:

1. **The header keywords were searched for in the WHOLE statement.** A
   body carrying `NEXT VALUE FOR S` has a `FOR` of its own, and the
   parser took that as the relation clause and read the trigger's name
   as everything before it. The search is bounded to the header — the
   text before `AS` — which is what it always meant.
2. **The relation contexts start at 0, not 2.** A relation trigger's 0
   and 1 are OLD and NEW, so its first `blr_store` takes context 2; a
   database trigger has neither row and its first store takes 0. The BLR
   differed from the engine's in exactly that byte, in every place it
   appeared.
3. **A generator the body draws is a DEPENDENCY** (`RDB$DEPENDENCIES`,
   object type 14). The engine writes one; this server wrote the
   relation and column rows and not that one. Fixed for relation
   triggers too, which had the same gap.

A database trigger's body is validated with no relation to check names
against, so `NEW.`/`OLD.` in one refuses — the engine's rule — while the
OTHER tables it names are checked against their own catalogs exactly as a
relation trigger's are.

A FOURTH DEFECT came out of the sweep rather than the gate, and it is
the one worth remembering: **the ON CONNECT refusal has to REPLACE the
attach's reply, not follow it.** Answering the attach first and then
sending the exception told the client its attach had SUCCEEDED, so it
went on to send a statement, got the exception as THAT statement's
failure, and then a broken connection (`08006`) when this end hung up.
The gate had passed on it — the message was there, in the right order,
with the right stack item — and only a run under load, where the client
retried, showed the extra line.

TWO QA-HARNESS BUGS were found by the same sweep and are worth recording
because both read exactly like regressions. Six gates all wrote
`/tmp/fbhandson/q.sql`, so a parallel run had one overwriting another's
script — the failure looked like a package's function vanishing. And
`serve-real-idxcost` compares an index plan's milliseconds against a
scan's: four gates at once made the index side look 2x SLOWER, though it
passes alone at the same load average. It is SERIAL now. The scratch
names were swept for others; `q.sql` was the only one shared.

**DATABASE TRIGGERS — DONE 2026-08-28 (`serve-real-dbtrigger` 10,
new).** The trigger class that belongs to the ATTACHMENT rather than to
a table: `ON CONNECT` (8192), `ON DISCONNECT` (8193) and `ON
TRANSACTION START`/`COMMIT`/`ROLLBACK` (8194/8195/8196). This server
read them from the catalog and IGNORED them, so a database configured
with an `ON CONNECT` trigger behaved through fire-crab as though it had
none — silently, which is the outcome this project does not allow.

They fire where NO STATEMENT IS RUNNING, so nothing is holding a working
copy and there is nothing to publish: the bodies go down the ordinary
path with the database already in reach. There is no row either, so the
frame carries no `TrigCtx` and a body naming `NEW.`/`OLD.` refuses.

THE LAWS, measured first:

- `ON CONNECT` fires once per attachment, BEFORE the client's first
  transaction, in a transaction OF ITS OWN — and an internal transaction
  fires nothing itself, so no `tx-start` row appears for it.
- **That transaction has to be COMMITTED.** Work left under an id
  nothing commits is invisible to every later reader, which is exactly
  how this first behaved: the body ran, wrote its row, and the row was
  never there.
- `ON TRANSACTION COMMIT` and `ROLLBACK` fire INSIDE the transaction
  that is ending, which is visible: a ROLLBACK body's own rows GO BACK
  WITH THE ROLLBACK while the generator it drew from HAS moved, a draw
  not being transactional. (It is why Firebird's own documentation tells
  you to write rollback auditing in an autonomous transaction.)
- An `ON CONNECT` that RAISES REFUSES THE ATTACH, with the body's own
  message — the trigger is a gate, not a notification.
- `ON DISCONNECT` fires at the detach AND at every other way a session
  ends (a closed socket, a failed read); a body that audits
  disconnections must not be able to miss one by crashing the client.

A DEFECT IN THE RENDERER CAME OUT OF IT. A body's own statement is
rendered back to SQL, and a generator draw had no rendering at all
("rendering it into a statement's text would draw twice") — so the
CANONICAL database trigger, `INSERT INTO LOG VALUES (NEXT VALUE FOR S,
...)`, refused. The fold runs FIRST and answers wherever the frame can
draw (a BEFORE trigger's replay pass), so that arm is only reached when
the draw belongs to the NESTED STATEMENT, where rendering it as itself
draws exactly once, down the ordinary path.

THE GATE ITSELF NEEDED A DIFFERENT CLIENT. isql does not issue the same
ops to both servers — it opened two transactions against the engine
where it opened one against this server for the same script — and that
client-behaviour difference drowned the thing under test. The acting
connection is the node driver, which makes exactly the same calls to
both: one attach, one transaction, the log read back over the SAME
connection.

RECORDED BOUNDARIES: `CREATE TRIGGER ... ON CONNECT` refuses cleanly
(nothing is stored — checked), so the gate's triggers are made by the
engine on both files; whether a file carries database triggers at all is
read ONCE at the attach, so one another attachment creates afterwards is
not seen until this one reconnects; and a body expression has no
CONCATENATION, so `'sum=' || :N` refuses rather than storing something
else.

**A TRIGGER BODY THAT LOOPS, AND ONE THAT CALLS — DONE 2026-08-28
(`serve-real-trigloop` 12, new).** The rest of the surface the chunk
below opened: `FOR SELECT ... INTO ... DO`, a declared CURSOR with
`OPEN`/`FETCH`/`CLOSE`, and `EXECUTE PROCEDURE` in both its forms
(arguments, and `RETURNING_VALUES`).

THE LAW THAT DECIDES IT, probed first: **a loop takes its rows when it
starts.** A `FOR SELECT` over a table whose own loop body INSERTS into
that same table still walks only the rows that were there when it
opened — measured on a two-row table inserting one row per iteration:
the loop runs TWICE and leaves four rows. A cursor behaves the same
between its `OPEN` and its `CLOSE`. This server's `ForSelect` already
materialised its rows through `branch_rows` before the loop, so it
inherits the engine's answer; an implementation that re-read the table
per iteration would not terminate on the engine's own fixture.

Three things were missing rather than wrong. A loop's and a cursor's
query substituted VARIABLES but not the ROW — the same defect
`SELECT INTO` had — so `FOR SELECT ... WHERE K = NEW.K` could not be
planned; both go through `subst_body_query` now, with an empty bind list
because their variables were already marked by the parser. Trigger
frames were built with an EMPTY cursor map (only procedures ever
populated one from their header), so `OPEN CU` in a trigger body had no
cursor to find — `trig_cursor_states` reads the trigger's own header the
same way. And `trig_body_inlineable` was widened to let these run.

A REAL DEFECT CAME OUT OF IT, in the stack item this project has pinned
since the trigger chunk. The engine's first `RDB$DEBUG_INFO` source
entry is the DECLARATION SECTION when a body has one and the body's
`BEGIN` when it does not (measured, entry by entry: a trigger declaring
`V` on its own line has entries at the DECLARE's line, then `BEGIN`'s,
then each statement's). This server anchored on `BEGIN` either way, so
every stack item from a body whose header sits on a line of ITS OWN was
**one line short** — `line: 7` where the engine says `line: 8`. It was
invisible for as long as every gated trigger wrote `AS DECLARE ...
BEGIN` on one line, where the two are the same line. `anchor_base`
measures from whichever point the engine anchored on.

RECORDED BOUNDARIES: `EXECUTE STATEMENT` in such a body (it builds its
statement at runtime, where the prepare-time walk can see no table name
to judge, and the self-write refusal below depends on that walk) and an
autonomous block (a transaction of its own around a published working
copy, never measured).

**A TRIGGER BODY THAT READS AND WRITES THE DATABASE — DONE 2026-08-28
(`serve-real-trigdb` 24, new; `serve-real-trigfire` two boundaries
became answers).** The classic triggers work now: an AUDIT trigger that
writes another table from a `BEFORE` body, and a LOOKUP trigger that
reads one to decide a column. Until this, a body that touched the
database at all made every `INSERT`, `UPDATE` and `DELETE` against its
table refuse — a table with an audit trigger could not be written.

THE MECHANISM IS ONE LINE OF REASONING. A trigger fires inside a
statement that is holding its working copy of the file, and a body's own
statement goes down the ORDINARY path — taking a copy and installing it.
Two writers cloning the same base both install a whole image and the
second silently drops the first's rows, which is why such a body was
refused. So the statement PUBLISHES its copy around the body
(`fire_triggers_published`) and takes a fresh one after. Publishing is
not a concession to the mechanism: it is what puts the body's read on
exactly the file the engine shows it.

WHAT THE ENGINE SHOWS IT, all measured first:

- A `BEFORE` body reads its own table WITHOUT the row being written and
  WITH every earlier row of the same statement. Under an `INSERT ...
  SELECT` of three rows the per-row `SELECT COUNT(*)` answers 0, 1, 2 —
  so the body can be run neither after the statement (3, 3, 3) nor
  before it. The AFTER-the-statement ordering is what this server used
  to do for the one body shape it could defer, and it is gone with the
  whole `deferred` path.
- An `AFTER` body reads the table WITH the row.
- A `BEFORE UPDATE` body reads the sum BEFORE this row's update; a
  `BEFORE DELETE` body still counts the row it is about to remove.
- A statement that fails takes the body's writes with it, however far
  the body got: a trigger that logged a row whose own `INSERT` then
  violates a `CHECK` leaves the log EMPTY.
- A body's write fires the triggers of what it writes, and those fire on.

THREE THINGS HAD TO CHANGE UNDERNEATH, each found by the gate:

1. **The window kind.** A statement whose writes are installed as it
   goes cannot be undone by dropping a copy. It takes a
   `WindowKind::Nested` window — undone by killing the id its rows carry
   — exactly as a row-by-row statement already did.
2. **The transaction id is adopted AT THE PUBLISH.** A statement
   reserves an id in its copy and adopts it only when it installs, which
   is what makes a failed statement burn nothing. Un-adopted, the rows
   it has written are another transaction's uncommitted work to every
   reader — including this body. An `AFTER INSERT` body did not count
   the row it fired for, an `AFTER UPDATE` body read the value before
   the update, and a `BEFORE DELETE` body's `AFTER` twin still saw the
   row: three wrong answers from one missing line.
3. **The rows are written AS THEY ARE READ.** The `UPDATE` and `DELETE`
   arms read and validate every row, then write them all. That is
   invisible until a body reads the table: all three bodies then see the
   same state, where the engine's answer walks. The write walk's body is
   now `write_updated_row`, called either from the walk or from inside
   the scan loop — same function, same order, different moment — and the
   gate pins it with a log table read WITH NO `ORDER BY`, so the
   physical order of the rows the bodies wrote is compared too.

TWO PRE-EXISTING DEFECTS SURFACED BESIDE IT. `:VAR` was accepted only in
the embedded-DML positions (`colon_clean`), never in a plain PSQL one —
so `IF (:M IS NOT NULL)` refused the whole body, which is how a lookup
trigger is written; both forms resolve to the same slot now. And a body
query was planned as raw text, so `SELECT MULT FROM RATE WHERE K =
NEW.K` could not be planned at all; `subst_body_query` writes the
frame's values in as literals, the same substitution the body's own DML
already made.

The status vector gained a law too: a `CHECK` constraint's vector
already ENDS in an `isc_stack_trace` item, and a body whose write
violates it CONTINUES that item rather than adding a second — the whole
stack is one element with newlines in it, which is why isql prints a `-`
before the first line and nothing before the rest.

RECORDED BOUNDARIES: a body that WRITES THE TABLE IT FIRES FOR (the
engine recurses to `Statement::MAX_CLONES` = 1000 and answers 54001;
each level here is a whole executor frame, so it refuses rather than
answering by crashing — a cross-table cycle is caught at depth 16), a
cursor / `FOR SELECT` / `EXECUTE STATEMENT` / autonomous block in such a
body, and a body that DRAWS A GENERATOR beside one that needs the
database (the draw belongs to the caller, which has handed its working
copy back).

**THE STAR IN `RETURNING`, AN ALIASED DML TARGET, AND A MERGE'S THIRD
ROW — DONE 2026-08-28 (`serve-real-returnold` 25 → 52).** The three
boundaries the entry above recorded, closed together, because they are
one question: WHICH ROWS does a DML statement have to name, and what may
name them.

`RETURNING *` answers now, and so does every qualified star: `T.*` (the
target's own name), `NEW.*`, `OLD.*`, an alias's `x.*`, and `OLD.*,
NEW.*` together in that order. A qualified star may share the list with
ordinary columns; a BARE one may not — the engine's grammar takes `*` as
a whole production, so a comma beside it is -104, and the gate pins that
both servers refuse it. `StarCtx::{New,Old,Source}` says which image a
star expands over and `returning_star` does the expanding, against the
same descriptors the plain column route already had.

An ALIASED TARGET (`UPDATE T x SET x.N = ... RETURNING x.N`) is a text
pass, `strip_dml_alias`, and two mistakes are worth keeping: it first
scanned from offset 0, which found the TABLE name `T` before the alias
`t` and stripped that (`dml_target_alias` returns the alias's byte
OFFSET now, not just its text), and it was applied to INSERT as well,
where it made this server ACCEPT `INSERT INTO T t (...)` that the engine
answers -104 — restricted to UPDATE and DELETE, MERGE excluded, and the
gate holds a check for each. A string that merely SPELLS the alias, and
an identifier that merely begins with it, are left alone. The one shape
the pass may not take is a nested FROM re-declaring the SAME alias for
another table: rewriting through it would answer the wrong rows, so it
refuses.

A MERGE has THREE rows to name — the target's after-image, its
before-image, and the SOURCE row — and the engine names all three.
`Affected` carries the third in a new `src_rows`, parallel to
`old_images`, and a returned row is built in three blocks: the image at
0, the before-image at `width` (an inserted row leaves it NULL rather
than erroring), the source row at `2 * width`. The DESCRIBE of a source
column names the SOURCE's table, not the target's — the source
`ProjCol`'s relation is kept rather than blanked, which was a real
defect found by the gate. RECORDED BOUNDARY: a BARE `*` in a MERGE names
BOTH contexts and the engine proves it by raising 42702 on the column
they share; this server has only the target's columns to expand with and
no 42702 to answer with, so it refuses.

**FIRING USER TRIGGERS ON THIS SERVER'S OWN DML — DONE 2026-08-27
(`serve-real-trigfire` 16, then 22).** `serve-real-trigger` has covered
CREATE TRIGGER for a long time — the PSQL-to-BLR compile, the catalog
rows, the debug blob, with the ENGINE executing what this server wrote.
The other half was missing: this server never FIRED one, so **any** user
trigger on a table made every INSERT, UPDATE and DELETE against it
refuse (the coarse `user_trigger` flag in `check_predicates_uncached`).
A table with an audit or a compute-a-column trigger could not be written
at all.

It fires them now, and the runnable surface is exactly the one CREATE
TRIGGER compiles: assignments over `NEW.`/`OLD.`, variables, literals,
integer arithmetic, IF, WHILE, EXCEPTION, and blocks with their WHEN
handlers. Measured against the engine: a BEFORE trigger COMPUTES a
column and what it assigns to `NEW.<col>` is what gets stored (over a
client's value too); several fire in RDB$TRIGGER_SEQUENCE order, each
seeing the last one's result; a BEFORE UPDATE body reads OLD and NEW and
a BEFORE DELETE one reads OLD; an INACTIVE trigger does not fire; an
AFTER trigger fires with the row written and NEW read-only there.

**An EXCEPTION inside a body stops the statement with the ENGINE'S OWN
vector**, stack item included: `At trigger "PUBLIC"."T_BI3" line: 1,
col: 82`. That line and column count the ORIGINAL `CREATE TRIGGER` text,
not the stored source — so they are read back from the `RDB$DEBUG_INFO`
blob this server already writes (`debug_info_anchor` takes its first
source entry, the body's BEGIN, and the interpreter's own offset does
the rest). The exception's NUMBER and MESSAGE are resolved at PREPARE
(`TrigDef::excs`): a trigger fires while the statement holds the working
copy of the file, with no catalog in reach.

Two mechanisms, one seam: `PsqlFrame` grew a `TrigCtx` (the relation's
columns, the OLD and NEW rows, and whether NEW is writable), which is
what turned `Expr::Field` and `TrigTarget::Field` from
`PsqlStop::Unsupported` into the trigger contexts they always described.

**AND THE OTHER HALF: AN AFTER TRIGGER MAY TOUCH THE DATABASE — DONE
2026-08-27 (same gate).** The most common trigger of all - `AFTER INSERT
... INSERT INTO LOG ...` - was still refused, because a trigger fires
while the statement holds its working copy and a nested write would be
lost under it. An AFTER trigger has nothing left to decide, so such a
body now runs DEFERRED: after the statement's own writes are applied,
with the database in reach, and still inside the statement's undo window
(`fire_deferred_triggers`, called from `execute_dml_collecting` between
the inner run and the unwind) - so a raise takes the whole statement
back, its own rows included. The rows come from the `Affected` collector
the statement already fills for RETURNING, extended with `old_images` so
a deferred AFTER UPDATE body reads a real OLD.

Boundaries recorded, both stated rather than guessed: a BEFORE trigger
whose body touches the database keeps the refusal (it must decide what
gets stored, and by the time the database is free the row is already
there), and a deferred body that NAMES THE TABLE IT FIRES FOR refuses -
by then that table holds every row the statement wrote, where the
engine's per-row firing would have shown it a prefix. A multi-event
trigger (`BEFORE INSERT OR UPDATE`) refuses whole: its composed type
carries the INSERTING/UPDATING/DELETING predicates with it.

`serve-real-trigger` and `serve-real-trigger2` unrecorded their
"fire-crab REFUSES its own DML on a user-trigger table" boundaries, and
`serve-real-fkguard` its two (a USER trigger no longer refuses the
statement; the FK ACTION triggers it exists for still do).

**UNIVERSAL (MULTI-EVENT) TRIGGERS — DONE 2026-08-27 (same gate, 25).**
`BEFORE INSERT OR UPDATE [OR DELETE]` packs up to three actions into one
trigger type, and the slice above refused every one of them. Three small
pieces, small because the machinery around them now exists:

* the COMPOSED TYPE is decoded rather than special-cased. This server
  already spells it for SHOW (`trigger_type_words`: bit 0 is BEFORE,
  then three action slots carrying 1 INSERT / 2 UPDATE / 3 DELETE), so
  `dml_trigger_events` reads the same arithmetic the other way - and a
  single-event trigger is simply the one-slot case, so the six original
  types needed no arm of their own.
* `INSERTING` / `UPDATING` / `DELETING` take SYNTHETIC VARIABLE SLOTS
  appended to the body's name list (`TRIG_ACTION_NAMES`), so the
  ordinary name resolution turns them into `Expr::Variable`s and
  `trig_frame_vars` fills the three with 1/0 for the action actually
  firing. No parser surgery at all.
* a BARE ACTION PREDICATE is a condition: `IF (INSERTING) THEN ...`.
  That path is restricted to exactly those three names - an integer
  expression standing where a condition belongs is not a Firebird
  boolean, and accepting one would let this server COMPILE a trigger the
  engine refuses.

**THE ACTION PREDICATE IS A NODE, NOT A TRICK — DONE 2026-08-27
(`serve-real-trigger`, TR5).** The synthetic slots above answer
INSERTING/UPDATING/DELETING while a body RUNS, and that is all they can
do: the same parser feeds CREATE TRIGGER, where a predicate resolved as
a plain name would have been emitted as an ordinary FIELD REFERENCE -
wrong BLR, written into the catalog with no error to show for it. (Two
probes corrected the record here: this server's CREATE TRIGGER has
handled the COMPOSED TYPE for a long time - `BEFORE INSERT OR UPDATE =
17`, the triple 113, written order preserved - and the boundary recorded
above, "CREATE for a universal trigger still refuses", was measuring a
malformed probe: an isql script with no `SET TERM`, so the body's
semicolon split the statement into a -104 on BOTH servers.)

`ods::expr::Expr::TriggerAction` is the engine's own half of the
predicate: `parse.y`'s `trigger_action_predicate` builds
`blr_eql(blr_internal_info(<const 6 = INFO_TYPE_TRIGGER_ACTION>),
<const 1|2|3>)`, so the node emits `blr_internal_info` followed by the
info type as an ordinary long literal, and the literal beside it says
which action was asked about. One representation now serves both paths -
the interpreter answers it from `TrigCtx.action`, the compiler emits it -
and `serve-real-trigger` pins the bytes: a universal trigger's BLR and
debug info come back byte-for-byte identical to the engine's, the
composed type with them.

Adding a variant to that shared enum surfaced fifteen exhaustive matches
across `ods` and `wire`; each carries an arm saying what a trigger
action IS in that context (no column reference, not text, never inside a
domain CHECK) rather than a copied default. The WRITE side needed nothing: an index whose type is not
`PXW_INTL` was already unmaintainable here, so an INSERT that would
break a `UNIQUE` CI index refuses instead of storing a duplicate the
engine rejects (measured), and an FK over a CI key refuses rather than
accepting a case-variant parent.

**AGGREGATES IN EXPRESSIONS DONE (2026-08-25,
`serve-real-statexpr` 8):** the statistical/ordered-set family
(VAR_*/STDDEV_*, CORR/COVAR_*/REGR_*, PERCENTILE_CONT/DISC) and
SUM/AVG-over-expressions now serve in every position the engine does:
select-list arithmetic and wrappers (`STDDEV_SAMP(N)*2`,
`ROUND(VAR_POP(N),2)`, `CAST/COALESCE/CASE/NULLIF/unary minus`,
`SUM(N)*AVG(N)` → INT128:-4 subtype 1, `CORR(N,B)*100`,
`SUM(A+B)*2`), HAVING (bare and expression LHS — `SUM(N)*2 > 10`,
`STDDEV_POP(N)*2 > 3`, percentiles), and ORDER BY (bare aggregates,
aggregate expressions, aliases of both). The machinery was already
half-built: `RawExpr::Agg` leaves + slot substitution existed for
the five plain functions over bare columns; the slice factored
`resolve_agg_src` out of the bare select-item arm, taught
`agg_result_desc` the family's descriptors (DOUBLE; REGR_COUNT
BIGINT; PERCENTILE_DISC = the order column's), extended the WHERE
tokenizer's aggregate lexing to the whole family (with the `WITHIN
GROUP` tail swallowed, in both the token- and char-level parsers),
gave `texpr`/`parse_leaf` aggregate expression leaves, rebuilt
HAVING's `resolve_having` around a parallel `slot_descs` and an
expression route over the extracted `synth_group_view`, and hung an
aggregate-expression resolver on the grouped `parse_order_by_expr`.
DESCRIBE follows the engine's measured dsc rules: family expressions
NOT nullable yet NULL-capable on the wire (isql renders that NULL
`0.000...`; PERCENTILE stays nullable; COALESCE nullability is
ALL-branches), SQLDA name = top operator, CASE text at literal
length. THE FOLD FIX the wrap exposed: VAR/STDDEV of an empty/all-
NULL group (and the SAMPLE forms over one row) are NULL, not 0.0 —
invisible in bare renders for years, `COALESCE(VAR_SAMP(..), -1)`
told the truth. The 16-agent adversarial review caught 8 more, all
fixed + live-verified: the DOUBLE-describe coercion must run BEFORE
`value_of`'s exact-contract guards (a `COALESCE(D, 1.5)` branch
value 22003'd mid-fetch where the engine converts — reachable on
PLAIN rows too); **`ORDER BY X` where X aliases `0 - SUM(N)`
silently sorted by the bare SUM slot (pre-existing wrong order,
now the alias sorts by its expression)**; **exact-vs-DOUBLE
comparisons and the f64 folds converted scaled values by MULTIPLY
where the engine's CVT divides — `WHERE N = 35.8e0` picked the
WRONG ROWS silently (pre-existing), and VAR/STDDEV's last digit
drifted**; HAVING's Pair/Percentile route now runs the operand
gates (a text CORR fed the numeric fold silently) and
PERCENTILE_DISC compares text orders as text; MIN/MAX-over-
expression and SUM/AVG slots carry the NUMERIC sub_type; DOUBLE
describes never leak subtype 1. Boundaries recorded: LIST in
expressions (computed-blob concat), DISTINCT inside the family
(engine -104 Token unknown), aggregates in WHERE (engine's specific
-104 vs fc generic), windows/NTILE in expressions, family
expressions over GROUP-BY-expression keys, derived tables/views/
INSERT..SELECT wrapping family expressions (clean refusals), the
engine's 42702 ambiguous-ORDER-BY refusal that fc still serves, and
bare MIN/MAX over CAST announcing INT64 where the engine keeps LONG
(both pre-existing describe/refusal-shape divergences, candidates).

**DOMAIN CHECK constraints DONE (2026-08-25,
`serve-real-domaincheck` 6):** the silent-wrong class closed — fc used
to WRITE rows the engine refuses (RDB$VALIDATION_* had no consumer).
Three legs. (1) ENFORCEMENT: `domain_check_predicates` joins each
column's RDB$FIELD_SOURCE to RDB$FIELDS.RDB$VALIDATION_SOURCE and
re-parses `NOT (<cond>)` through the WHERE machinery with the `VALUE`
token text-substituted by the bare column name — so engine-built
BETWEEN/IN/LIKE/function checks all enforce; `validate_row_fields`
runs at INSERT and UPDATE on the FINAL row image in the engine's
measured order (table CHECK triggers first, then per-field in FIELD
order, domain check then NOT NULL — one walk, earliest field wins),
over EVERY validated column (an UPDATE re-validates untouched
columns; measured). Violations are byte-exact `isc_not_valid` 23000
(`validation error for column "S"."T"."C", value "v"`): NULL renders
`*** null ***`, text raw, scaled with its scale, DATE ISO — and
TIMESTAMP in the LEGACY `07-JUN-2019 8:09:10.5000` form (measured;
unlike every other render). FALSE fails, UNKNOWN passes. (2) CREATE
DOMAIN ... CHECK compiles the engine's stored form — the bare
POSITIVE boolean `blr_version5 <cond> blr_eoc`, `VALUE` = `blr_fid
0,0,0` (new `Expr::DomainValue`), a written NOT normalized into
inverted comparisons (`Cond::normalized`), IS NOT NULL keeping
`blr_not blr_missing` — dump-pinned in
`domain_checks_compile_to_engine_validation_blr`; source verbatim;
the ENGINE enforces fc-written checks (via the RSR 7 runtime segment
create_table already emits). (3) ALTER DOMAIN ADD [CONSTRAINT] CHECK
/ DROP CONSTRAINT: compile-at-execute (the domain's type read off the
live file), the second ADD refuses with the engine's three-item
vector (`ALTER DOMAIN @1 failed` 336397278 + dyn 160 336068768, the
message text carrying its own quotes), DROP nulls both columns
(no-op when none), no re-scan of existing rows, and
`update_relation_runtime` for every table using the domain so the
engine picks the change up. Boundaries: fc's DDL compile surface is
the table-CHECK surface (int + NONE-charset text comparisons,
AND/OR/NOT/IS NULL) — anything wider refuses the WHOLE statement
(never a domain without its rule) where the engine creates;
CAST(x AS domain) and PSQL vars over checked domains keep refusing
(engine: 42000 `validation error for CAST/variable`); a repeated
ALTER cycle used to hit a catalog page-full refusal — CLOSED
2026-08-25 by SQZ pack-on-write: every record fc stores (INSERT,
UPDATE, fragment pieces, restore rows) is RLE-packed when smaller
(the engine's sqz.cpp `m_allowUnpacked` law), the FILL pad to
RHDF_SIZE lands on EVERY store — raw records included (dpm.epp:471
"It is critical that the record be padded": the engine's `fragment()`
writes an rhdf header into the old slot assuming it; the 3-lens
review proved a short fc slot page-corrupts a plain engine UPDATE) —
while every RE-STORE site trims the all-zero tail back to fmt_length
(`trim_fill_tail`; re-packing the pad makes a record that unpacks
past fmt_length — engine BUGCHECK 179, the wire UPDATE path's
measured trim law now shared by `patch_sys_row` and the sweep's
promotion), a new version a FULL page cannot take whole FRAGMENTS in
place of refusing (dpm.epp `DPM_update` → `store_big_record`: head
in the fixed slot, tail elsewhere), and a fragmented catalog row
stays patchable — a poke past the head falls back to a whole-row
update whose back version is the old head CLONED, forward pointer
and all, so the old tail pieces follow it (`push_back_version`
already accepted an `rhd_incomplete` head). 24 drop/add cycles on 8K
now run clean where 3 used to die at "no room on page 112";
`serve-real-sqzpack` 9 checks — the cycles differentially, packed
USER rows written by fc and read byte-for-byte by the ENGINE, gfix
-v -full silent, a gbak round trip. Known-safe leak: a collected
fragmented back version's tail pieces are skipped by gc
(`chains_skipped`), never freed — space, not correctness. The review
also caught `insert_record_as` sizing `find_space` by the raw image
while writing the padded record — every insert clipped the
transaction id of the record stored just below it; the spot is now
found for the built record's true length. The first full sweep then
caught the last member of the class: `build_insert_image` /
`upgrade_image` sized fresh images by a LIVE SAMPLE record — whose
assembled length includes the engine's FILL pad — so every insert
into a table with padded rows built the pad INTO the image, and the
now-packed store unpacked past fmt_length (live BUGCHECK 179 in the
nbackup/ddltx/growth gates). Images are now built at fmt_length
exactly (met.epp's last-descriptor law; the sample only
sanity-checks), the pad living solely at the record layer.
serve-real-grow's growth threshold relaxed to +1 page: packed small
rows fill ~6x denser, exactly as the engine stores them.

**Catalog blob GC — DONE 2026-08-25.** The other half of the
page-pressure class: a catalog patch that REPLACES or NULLs a blob
field (the `RDB$RUNTIME` summary every ALTER rewrites, an ALTER
DOMAIN's validation pair, a re-granted `RDB$ACL`, a re-COMMENTed
`RDB$DESCRIPTION`) leaked the superseded blob forever — 2 slots per
ALTER-DOMAIN cycle on `RDB$FIELDS`, one runtime per cycle on
`RDB$RELATIONS`, and fc's sweep skips blob-bearing relations, so
nothing ever reclaimed them. Now: `patch_sys_row` (and the five
hand-rolled `RDB$RUNTIME` poke sites) captures the old id before the
overwrite, keeps anything the final image still names (the engine's
going-minus-staying diff, blb.cpp:424 — identity is the id, a blob
that moved fields is kept), and the free rides as DEFERRED work
(`DdlDeferred::FreeBlob`) applied at COMMIT with the other dfw.epp
phases; the settled path (tools, restore) frees on the spot. **The
law the hard way: blob and referencing version go TOGETHER.** The
first cut freed the slot while back/dead row versions still named the
id — the ENGINE's own version GC (a gbak attach's cooperative purge)
later collected the stale version and freed the id's NEW occupant
(gbak died on a live `RDB$RUNTIME`: "BLOB not found"). So every free
is paired with `PurgeRowChain` — the engine's `purge` narrowed to the
patched row: back chain freed (fragmented members' tails included),
head's back pointer zeroed; and a ROLLED-BACK statement's own minted
blobs deliberately STAY beside the dead versions that name them (the
engine's sweep collects both together — gated). The 3-lens review
confirmed four more: the commit guard was TIP-blind to READ-ONLY
snapshot transactions (fc reserves ids at first write — a reader has
no TIP entry; now any other live attachment holds the frees back),
the autonomous-block epilogue applied frees unguarded mid-outer-
transaction (they ride to the outer commit now), `free_blob` resolved
recnos through the zero-compacted page list where ids are
dpg_sequence-positional (resolved by the page's own sequence now),
and `op_prepare` refused every superseding DDL (the pending-DROP
guard now ignores free/purge entries). `serve-real-blobgc` 18 checks:
40 cycles with gstat "Blobs:" flat at/below the engine's own lazy
trail, rollback keeps the old check and the engine's sweep reclaims
the mints, GRANT/REVOKE + COMMENT churn at engine parity, snapshot
re-read under a concurrent COMMENT still answers the old value.
Remaining recorded: blobs superseded via delete-then-recreate (ALTER
VIEW/PROCEDURE/TRIGGER/FUNCTION, DROP TABLE stubs) still leak with
their dead rows — engine-collectable, same law.

**Blob-aware sweeping — DONE 2026-08-25.** The last leak dimension.
fire-crab's sweep SKIPPED any relation whose pages carry blob records
("the blob walk is its own slice"), so a user table with a blob
column never got version GC at all and the catalog's own blob
relations kept every back version forever. Now every collected
version takes its blobs with it, under the engine's law
(`BLB_garbage_collect`, blb.cpp:424): going = the removed versions'
blob ids, staying = the survivors', identity is the `(relation,
recno)` id, and only the difference is freed. All four arms carry it
— a rolled-back INSERT (everything goes), a PROMOTION (the dead
head's ids minus the promoted image's and every deeper member's), an
EXPUNGE (the whole chain, nothing stays), a live head's HISTORY (the
chain's minus the head's). A relation with no blob slots keeps the
old fast path; anything the walk cannot read whole — an unresolvable
format, an unreadable member — leaves the chain UNTOUCHED (never
free blind, unit-pinned).
Three laws the review pinned, each a corruption class: `rhd_delta`
says "the PRIOR version is differences only" (ods.h:1012), so the
flag that decides how a member is stored sits on the version IN
FRONT of it — reading it off the member itself handed raw delta
streams to the field decoder on every engine-written chain (garbage
blob ids, and a garbage id can name a LIVE blob); a blob id naming a
FOREIGN relation is IGNORED, never freed (blb.cpp:474's own guard —
such ids occur in real user data); and a version's own format number
is the only one that may decode it (a near-enough system format lays
the blob fields at the wrong offsets — freeing blind by another
name). `free_slot` no longer panics on a pointer past the file.
`serve-real-blobsweep` 18 checks: the same churn on twin databases,
each server sweeping its own file to the SAME survivors (records,
versions 0, live blob count, blob pages) with every row and a
level-1 blob's bytes identical — plus fire-crab sweeping the
ENGINE's own file, whose wide rows (`PAD CHAR(400)`, so the engine's
difference stream beats the record — measured: 0 delta versions
without it, 5 with) carry the delta chains fc's own writer never
produces. `serve-real-gfixsweep`'s recorded boundary ("the blob
relation is left whole") became the equality it always promised.
The 13-agent adversarial review caught 8 real defects, all fixed and
live-verified: two CRITICAL silent-wrongs — a case-blind
RDB$FIELD_SOURCE join bound the WRONG domain's check when `"dm2"`
and `DM2` coexist (fixed EXACT in domain checks, `not_null_fids` and
both domain-default joins — the same latent class), and the engine's
LOSSY source transliteration (`'né'` stored as `'n??'` while the
BLR keeps the real bytes) made fc enforce a wrong rule (a `?` inside
a string literal of a stored check source now refuses that table's
DML); a standalone TIME message renders PADDED (`08:09:10.5000` —
only TIMESTAMP is legacy-unpadded); `CHECK (...) DEFAULT` clause
order refuses (engine -104s it; `CHECK (...) NOT NULL` is legal both
sides); a multibyte byte-boundary panic in the CHECK splitter; a
SOURCE-without-BLR row is now SKIPPED (the engine enforces only from
the BLR's runtime segment); the duplicate-constraint test moved
BEFORE the new check's compile (an out-of-surface second ADD gets
the engine vector); and — pre-existing, review-surfaced — `ALTER
TABLE ADD <col> <domain>` used to write the UNRESOLVED zero-typed
column under a fresh carrier (length-0 garbage the engine chokes
on): it now resolves the domain like create_table, points
RDB$FIELD_SOURCE at it, mints no carrier, and the engine enforces
the domain's check on the added column (NOT NULL domains refuse —
the re-scan story is unproven). Two review findings stand as
designed fail-safes: one unevaluatable domain check refuses ALL DML
on tables using it (the table-check law), and fc's refusal SHAPES
for out-of-surface DDL stay generic.
`serve-real-scaledarith` 6):** `+`/`-`/`*`/`/`/unary-minus over
`Value::Scaled`/`Int128` with Firebird's scale rules (mirror of the wire
server's `numeric_bin`), and an assignment coerces its source to the
target's declared scale (rounds half-away into an INTEGER slot, rescales
into a finer NUMERIC, raises 22003 past the slot width). Observable via
INTEGER-signature routines whose bodies use decimal literals (`RETURN
A*1.5`). Boundary: an intermediate that overflows i64 raises 22003
"numeric value is out of range" where the engine may say "Integer
overflow" (both 22003) — fc's i128 numeric model, consistent with the
server's own `numeric_bin`.

**SQL COMMENTS accepted everywhere DONE (2026-08-25,
`serve-real-comments` 7):** `/* ... */` and `-- to end of line` in any
statement, as the engine's lexer treats them - whitespace. fire-crab
refused a comment ANYWHERE outside a PSQL body (`SELECT 1 /* c */` was a
generic 42000), which kept every real-world script off the server.
`strip_sql_comments` was rewritten as a POSITION-PRESERVING blanker -
every comment byte becomes one space, so byte length and every offset
(the error line/col mapping included) match the original; quote-aware
for `'` strings and `"` identifiers with doubled-quote escapes; block
comments unnested (the first `*/` closes, and the engine -104s the
leftover of a "nested" one); a comment separates tokens
(`SELECT/*t*/2`); unterminated blanks to the end - and applied at the
FOUR statement entries: the three wire decode sites (op_exec_immediate,
op_exec_immediate2, op_prepare) and PSQL's EXECUTE STATEMENT dynamic
text. The PSQL body parser's own two strip calls became the same
function, which also retired its latent Latin-1 mangling of non-ASCII
bodies (the old byte-through-`as char` copy). Commented DDL now
compiles and the ENGINE runs what fc stored - procedures, triggers,
views, CHECK constraints (re-parsed at every DML from stored source)
and COMPUTED columns, value- and vector-exact. Boundaries (recorded): a
routine/view/check created THROUGH fc's wire stores its RDB$SOURCE with
the comments BLANKED to spaces - same length, same line/col coordinates
- where the engine stores them verbatim (fc's RDB$DEFAULT_SOURCE was
already re-rendered, the precedent; gbak-carried and engine-built
sources keep their comments, and EVERY stored-source re-parser now
strips at read time - the adversarial review caught the three that did
not (the view re-plan, computed columns and the CHECK predicate parser
read engine-built sources raw: a '--' comment there parsed as DOUBLE
NEGATION, a '/*' refused DML the engine serves - all three fixed and
gated on an engine-built file), plus two more port misses fixed: an
UNTERMINATED block comment was silently swallowed where the engine
-104s (the entries now pass the original through and refuse), and
block-comment NEWLINES were blanked where the engine counts lines
through a comment (the 'At ... line:' frames kept their numbers only by
luck). The nested-comment and comment-split-operator refusals wear
fc's generic vector where the engine spells -104. Pre-existing gaps the
review surfaced for the candidate list: q'{...}' alternative quoting
(refused entirely), the doubled-quote identifier rendering (fc shows
a""b where the engine undoubles), and DOMAIN CHECK validation — the
latter CLOSED by the 2026-08-25 domain-check slice above.

**Constant EXPRESSIONS in INSERT ... VALUES - and the boolean wire fix -
DONE (2026-08-24, `serve-real-insertexpr` 8):** the engine accepts any
value expression in a VALUES list; fire-crab's was a fixed set of token
shapes, so `1e3`, `1+2`, `'A'||'B'`, `(5)`, `UPPER('x')`, `CAST('55' AS
INTEGER)`, `DATE '..' + 1`, `2.5 * 2`, `1 > 0`, `COALESCE(NULL, 3.25)` -
fourteen of sixteen probed engine-accepted forms - refused. The VALUES
list now splits at TEXT level (the paren- and quote-aware
`split_set_list`); the staged token shapes keep their arms (a parameter,
DEFAULT, the generators, a blob-bound string), and ANY other item parses
as an expression, resolves WITH NO COLUMNS, evaluates at plan (the query
side's own clock rule) and stages as `InsVal::Wire` through
`value_to_wireparam` - FACTORED OUT of the UPDATE expression tier, which
now calls the same mapping, so the two DML halves cannot drift. Folded
CASE/COALESCE/IIF/ABS/SQRT/TRIM, mixed `'a' || 5`, negative parens,
scaled and DOUBLE arithmetic, boolean comparisons and temporal
arithmetic all store what the engine stores, the engine reads fc's rows
line for line, and a NULL-answering fold stores NULL. **Found on the
way, fixed: the BOOLEAN WIRE ENCODING sent a big-endian int (value byte
LAST) where XDR opaque puts the value byte FIRST - every boolean OUTPUT
column read `<false>` at isql/libfbclient, `SELECT TRUE` included, while
WHERE and CAST were right; the engine read fc's STORED booleans
correctly all along (the writes were fine), and the patched node
driver's metadata-directed decode masked it in the node gates. The old
unit pin asserted the wrong form and was corrected; both dedicated
boolean gates and the sweep stay green.** An adversarial review (three lenses, live-verified) plus the author's
probes caught and fixed SEVEN more divergences: an UNTYPED fold whose
eval answered NULL (`'5' + 1` - the engine's "Strings cannot be added")
would have stored a silent NULL row - the INSERT arm refuses it, the
UPDATE expression tier gained the same type gate, and a `CASE ... ELSE
NULL END` stays typeable (an explicit NULL branch is now TRANSPARENT in
the conditional type, the engine's rule); TIME ± n arrived (the amount
is SECONDS, fraction kept, wrapping at midnight), DATE + TIME composes a
timestamp, and a TIMESTAMP ± n keeps the day FRACTION (TS + 0.25 shifts
six hours - fc's whole-day rounding there was a pre-existing wrong
answer in queries too); `TRUE || ''` spells TRUE; a DOUBLE fold into a
NUMERIC lands the .xx5 edge with the CVT epsilon (1.005e0 is 1.01); an
exact fold with extra fraction digits ROUNDS on the first dropped digit
half-away (the engine's adjustForScale - 1.005 into a NUMERIC(9,2) is
1.01, 1.0049 is 1.00; every wire parameter shares the rule); scaled and
approximate folds RENDER into text columns ('2.50', the 16-digit
double); a bare TRUE/FALSE literal into a text column spells TRUE/FALSE
(the '1'/'0' stays the client-bound-parameter rule); and a TRAILING
COMMA in a VALUES or SET list refuses (-104 there; the splitter's
dropped empty tail had it silently executing - the UPDATE side had that
hole before the slice). The stale `SELECT TM + 1` refusal pin in
serve-real-datemath was retired for a differential.
Boundaries (recorded): a
scalar-SUBQUERY value refuses (the engine answers it); a RAISING fold
(`1/0`) refuses at plan where the engine raises its typed 22012 at
execute, and an overflow/truncation fold the same way - the INSERT
vector family; a `?` inside an expression refuses (engine 07002); hex
literals and SQL COMMENTS inside a statement are pre-existing lexer
gaps (fc refuses `SELECT 64 /* c */` too - a comment-stripping slice is
a candidate); a blob-valued expression into a BLOB column refuses (the
plain string form works).

**Temporal values in DML - and the engine's WHOLE string-to-datetime
grammar - DONE (2026-08-24, `serve-real-temporaldml` 16):** until this
slice fire-crab could not put a DATE/TIME/TIMESTAMP value into a column
through its own wire in ANY form - typed literal, string, CAST,
CURRENT_DATE, every one refused, and every temporal fixture had to be
engine-built - while its text-to-temporal conversion knew ISO forms only.
The encoder side had been complete all along (WireParam::Date/Time/
Timestamp, record encode, index keys, wire parameters, column defaults);
the holes were the two DML literal parsers and the grammar. Now: INSERT
... VALUES takes temporal literals, strings, folded CAST constants, the
clocks (CURRENT_DATE, and CURRENT_TIME / CURRENT_TIMESTAMP - WITH TIME
ZONE values landing session-local through the zone's own displacement)
and LOCALTIME / LOCALTIMESTAMP, via new InsVal variants and a VALUES arm
that resolves a constant expression and accepts a temporal result; UPDATE
SET's string tier converts through the same encoder arm and its
expression tier gained the TZ clocks; INSERT ... SELECT carries temporal
columns (its per-row re-render now spells them as typed literals, value
exact); and `string_to_datetime` is CVT_string_to_datetime (cvt.cpp:677)
ported arm for arm - the three date components in any order decided by
the first token's shape (a 4-digit lead Y-M-D, a leading English month
M-D-Y, a middle one D-M-Y, a `.` separator D-M-Y, else M-D-Y), one
CONSISTENT separator from `/ - .` or whitespace, month names by
>=3-letter prefix, 2-digit years slid into the 50-year window, a missing
year defaulting to the current one, the specials NOW / TODAY / TOMORROW /
YESTERDAY (string coercion only - a typed literal refuses them, probed),
minutes-required times with at most 4 fraction digits, impossible dates
by round-trip, years 1..9999 - pinned by a 60-assertion unit battery of
measured vectors and shared by every consumer: DML strings, CAST from
text, and a text literal against a temporal column in a WHERE (so
`WHERE D = 'TODAY'` and `WHERE D = '15-JAN-2020'` now match, and a
date-only string compares against a TIMESTAMP as midnight). The
cross-type lattice is the engine's: TIMESTAMP truncates into DATE/TIME, a
DATE is midnight of a TIMESTAMP, a TIME lands dated TODAY (a new encode
arm); TIME-into-DATE and DATE-into-TIME refuse. `tz::displacement`
learned the UTC-family named zones (Etc/UTC = 0) and the fixed Etc/GMT+N
offsets (tzdata's inverted sign), which is what lets the session-zone
clocks convert - and un-bracketed TZ rendering ride along. Boundaries
(recorded): a bad string refuses with fc's GENERIC vector at INSERT where
the engine spells 22018 with the string (the shape every fc INSERT
conversion has - 'abc' into an INTEGER is the same; the CAST path is
typed); a trailing TIMEZONE in a string refuses where the engine converts
it (and junk after a fraction draws the engine's 22009 invalid-zone, fc's
22018); TIME/TIMESTAMP WITH TIME ZONE columns still take no DML values;
`DEFAULT DATE '...'` on a column refuses at CREATE TABLE (the string and
CURRENT_DATE default forms work and fill value-exact) and its BLR remains
undecodable at INSERT; a PSQL BODY's own INSERT of a temporal (an
EXECUTE BLOCK or procedure statement, literal or variable) refuses - the
body statement parser is the second parser the column-less-INSERT note
already records - all pre-existing. The clocks FOLD AT PLAN (the
query side's own model - CURRENT_DATE resolves to a literal): a PREPARED
INSERT re-executed across midnight keeps its plan-time clock where the
engine reads the clock per execute - the same recorded shape fc's
SELECT CURRENT_DATE already has under the statement cache.

**The LIST aggregate - and the first COMPUTED BLOB - DONE (2026-08-24,
`serve-real-list` 33):** `LIST([DISTINCT] arg [, separator])`, the
string-concatenation aggregate whose result is a TEXT BLOB the server itself
CREATES - the "computed-blob result fc cannot emit" that had blocked it. The
fold renders each non-null value to text (`Value::render`; a blob argument by
CONTENT through the blobcast reader; TRUE/FALSE for booleans; a CHAR column
padded to its declared CHARACTER count in the plain fold but to its full BYTE
image under DISTINCT - both measured) and mints a temp blob through a
thread-local mint context the connection loop arms per op and drains into
`Database::temp_blobs` at the top of the next op, ids floored at 0x40000000
so a client's own op_create_blob ids never collide; the row carries the
relation-0 id, and op_open_blob2 / op_info_blob / op_get_segment already
resolve those through temp_blobs, so the whole read side came free - the
segment structure byte-exact (each value and each separator its OWN segment,
an empty piece writing none, type 0 segmented, the engine's counts). The
separator (default `,`) is evaluated PER ROW and appended before each value
after the first; a NULL separator at any append - or a NULL constant - marks
the WHOLE result NULL (aggPass: dsc_dtype = 0); DISTINCT sorts and dedupes
the values, its separator evaluated with the group's last row current
(measured). The describe: BLOB sub_type 1, Nullable, named LIST, charset =
the ARGUMENT's (a text column its own, a text expression the first text
column it references, a bare literal or numeric NONE - all measured).
WITHIN A GROUP the tie order is the engine's grouping sort, which compares
its WHOLE sort record (sort.cpp `quick(n, j, m_longs)` runs over every
native ULONG of [diddled keys][per-field null flags][referenced fields in
field order]): fc reproduces the measured grain - ties follow the OTHER
REFERENCED fields in field order (a field referenced only in the WHERE
included, an unreferenced one excluded), a NULL in a referenced field sinks
its row, a VARYING value compares by its count word first ('b','c','aa') and
then by 4-byte words whose LAST byte dominates ('ba','ca','ab'), an INTEGER
value as one UNSIGNED word (1, 256, -5) - while over a JOIN the join's
delivery order holds (measured; fc's join row order already matches), and a
DERIVED table, CTE, UNION source or VIEW flattens into the SAME record (a
bound fold with no join parts tie-orders; a real join's does not). An
adversarial review (three lenses, every finding verified against the live
engine) and the author's own probes caught SEVEN real divergences
pre-commit, all fixed: the tie extension first sorted by ALL fields where
the engine sorts by REFERENCED ones; CHAR padding was byte- where the plain
fold is character-count; the NULL flags, unsigned-int words and vary count
word of the tie grain; the derived/CTE/UNION/view fold left in delivery
order; `LIST(DISTINCT <blob>)` deduped by CONTENT where the engine keys the
DESCRIPTOR (equal content never dedupes, id order) - now refused;
`LIST(DISTINCT <collated>)` deduped binary where the engine dedupes by the
collation key - now refused; and the segment split was 65535 where
BLB_put_data splits at 32768. Boundaries (recorded): LIST inside an
EXPRESSION (`CHAR_LENGTH(LIST(..))`, a HAVING comparison), in a scalar
SUBQUERY or a DERIVED-table projection, the window OVER () form, and
`INSERT ... SELECT LIST(..)` refuse where the engine answers; the malformed
shapes (three arguments, `LIST(*)`) refuse with fc's generic vector where
the engine spells -104; the tie order's word-granular corners
(multi-text-field packing, a derived source's own WHERE fields, a reordered
or computed derived projection, a collated or blob-id tie field) are
unpinned; a blob id opened after its transaction ends degrades to the empty
blob rather than the engine's invalid-id error.

**The ordered-set aggregates PERCENTILE_CONT / PERCENTILE_DISC DONE
(2026-08-24, `serve-real-percentile` 6):** the inverse-distribution
aggregates `PERCENTILE_x(fraction) WITHIN GROUP (ORDER BY expr [ASC|DESC])`
- fc's first WITHIN GROUP form. Each collects the non-null ORDER BY values,
sorts them, then PERCENTILE_CONT interpolates between the two bracketing the
rank 1 + fraction*(n-1) and answers a DOUBLE (the rank and each
interpolation term fused into multiply-adds to match the engine's
`-ffp-contract=fast` to the last bit), while PERCENTILE_DISC picks the value
at 1-based position ceil(fraction*n) (at least 1), KEEPING its exact type
(its `make()` copies the ORDER BY descriptor - a NUMERIC(9,2) result stays
LONG scale -2 sub_type 1, a scaled expression keeps sub_type 1, a VARCHAR
VARYING). Both are nullable - NULL over an empty / all-null group and for a
NULL fraction; a NULL ORDER BY value drops from the set; DESC reverses. The
WITHIN GROUP clause is parsed by `parse_percentile_item`, carried through new
`AggTarget::Percentile` / `AggSrc::Percentile`, folded in `compute_group`
(`percentile_result`). An out-of-range non-null fraction raises the engine's
DSQL error ("... in the range [0, 1]", primary "Dynamic SQL Error" via a new
`EvalErr::DsqlDomain`). An adversarial review found three byte-exactness
defects, all fixed: the interpolation missed the FMA contraction (now
`mul_add`); a scaled-NUMERIC EXPRESSION order described sub_type 0 not 1; and
a NULL fraction erred instead of answering NULL. Boundaries (recorded): a
DECFLOAT / INT128 ORDER BY; PERCENTILE_CONT over a NON-numeric ORDER BY (the
engine oddly answers NULL, fc refuses); more than one sort item; the FILTER
form and a percentile inside an expression. MODE is not an engine function;
LIST arrived in the next slice (the computed blob with it).

**The two-argument statistical aggregates CORR / COVAR / REGR family DONE
(2026-08-24, `serve-real-statagg2` 8):** the linear-correlation, covariance
and linear-regression aggregates - CORR, COVAR_POP, COVAR_SAMP, REGR_SLOPE,
REGR_INTERCEPT, REGR_COUNT, REGR_R2, REGR_AVGX, REGR_AVGY, REGR_SXX,
REGR_SYY, REGR_SXY. Each folds n and the five paired sums (Sx / Sxx / Sy /
Syy / Sxy) over the rows where BOTH arguments are non-null (the FIRST SQL
argument is Y, the SECOND X, per the standard and the engine's CorrAggNode /
RegrAggNode), then answers from the engine's closed formula (`stat2_result`)
folded in f64 in the SAME operation order so the DOUBLE bits match - over
DOUBLE, INTEGER and NUMERIC operands, whole-table and grouped, with the
FILTER (WHERE ...) form. The result is DOUBLE (BIGINT for REGR_COUNT), and
the engine DESCRIBES every one NOT nullable though they CAN be NULL at run
time (an empty or single-row group, a zero variance) - a NULL travels on a
not-nullable column and renders as 0; fc matches both. New plumbing:
`AggTarget::Pair` / `AggSrc::Pair`, `split_top_comma2`, and the four
duplicated inline aggregate-name matches folded into `AggFn::name()`. An
adversarial review (each dimension verified against the live engine) found
three byte-exactness defects, all fixed: a scaled-NUMERIC operand converted
by multiply-by-reciprocal (raw * 0.01) where the engine's CVT DIVIDES (raw /
100.0) - now `exact_to_f64`; and REGR_INTERCEPT's `avgY - slope*avgX`, which
the engine compiles as a fused multiply-add - now `mul_add`, so the last bit
agrees. Boundaries (recorded): a DECFLOAT / INT128 operand (decimal128
domain, fc refuses); these folds inside an EXPRESSION (CASE / COALESCE / a
comparison / a scalar subquery / a window OVER) refuse, the same
top-level-select-item limit VAR / STDDEV carry. MODE is not an engine
function (probed -104); PERCENTILE_CONT / PERCENTILE_DISC (ordered-set) and
LIST (a computed-BLOB result) followed as their own slices - both done.

**The EXACT-rounding family CEIL / CEILING / FLOOR / ROUND / TRUNC DONE
(2026-08-24, `serve-real-rounding` 28):** the last of the common numeric
SysFns, and the first EXACT-numeric ones whose result FORM (dtype width,
scale and NUMERIC sub_type) the engine DERIVES from the operand - the piece
that had blocked them. CEIL / CEILING / FLOOR promote the operand's storage
one dtype step (SMALLINT -> INTEGER, INTEGER / BIGINT -> BIGINT, INT128
stays), scale 0, sub_type 0, the way makeCeilFloor's makeLong / makeInt64 /
makeInt128 do. ROUND / TRUNC copy the operand descriptor (dtype AND sub_type
kept); a one-argument call forces scale 0, a two-argument call keeps the
operand scale and rounds to n decimal places (ROUND(3.14159,2) is INT64
scale -5, value 3.14000; ROUND(1234.5,-2) is scale -1, 1200.0). A literal
NULL operand answers INTEGER (makeLong). An APPROXIMATE operand answers
DOUBLE: CEIL / FLOOR are exact on the double, ROUND follows evlRound's CVT
(d * 10^-s, add 0.5 + eps with eps = 1e-14 double / 1e-5 float, truncate) so
the .x05 binary-representation cases land the decimal way (ROUND(1.005e0,2)
= 1.01), TRUNC follows evlTrunc's modf; CEIL / FLOOR / TRUNC additionally
string-convert a TEXT operand to DOUBLE (CEIL('3.2') = 4.0), while ROUND
refuses text. ROUND rounds half AWAY from zero, TRUNC toward zero; the exact
arithmetic is in i128 (`rounded_q` + `RndMode`), so a NUMERIC(30) operand
keeps its INT128 result. A non-integer places argument is accepted (rounded
to a whole count, as MOV_get_long does). The describe was threaded through
`result_width_bytes`, `result_scale`, `numeric_subtype` and `rank_of`, with
a polymorphic `type_of`. An adversarial review (3 dimensions, each verified
against the live engine) found FOUR defects, all fixed and re-verified: the
double .x05 rounding (evlRound's eps), a non-integer places argument, a
BIGINT round-up raising integer- rather than numeric-overflow, and CEILING
folding its column name to CEIL (a distinct `SysFn::Ceiling`). Boundaries
(recorded): a DECFLOAT / INT128 operand (engine computes it in the
decimal128 domain), ROUND(text) and wrong-arity messages (fc refuses
generically), and a FLOAT operand (engine keeps FLOAT; fc widens to DOUBLE,
its general approximate-EXPRESSION policy). With this the common
numeric-function surface (transcendental + bitwise + exact-rounding) is
complete.

**The DOUBLE-precision math cluster DONE (2026-08-24, `serve-real-math`
39):** the transcendental built-ins that answer a 64-bit float join the
SysFn machinery - SQRT, POWER, EXP, LN, LOG10, LOG(base,x), PI() (a
zero-argument constant, needing an empty-parens parse), the trig SIN / COS
/ TAN / COT / ASIN / ACOS / ATAN / ATAN2, and the hyperbolic SINH / COSH /
TANH. Each folds its operands to f64 (`fn_f64`, `exact_to_f64` for exact
operands) and calls Rust libm, which on this glibc host answers bit-for-bit
what the engine's C libm answers - the 17-digit DOUBLE matches to the last
place over literals, INTEGER / NUMERIC / DOUBLE columns, nesting and a WHERE
predicate; result DOUBLE (sqltype 480, `ExprType::Approx`), NULL propagates.
The domain / range / overflow errors match byte for byte: SQRT of a
negative, LN / LOG10 / LOG-value <= 0, LOG base <= 0, ASIN / ACOS outside
[-1,1], COT(0) raise `expression_eval_err` with the function name
(`EvalErr::MathDomain`); POWER(0, negative) -> `sysf_invalid_zeropowneg`
and POWER(negative, non-integral) -> `sysf_invalid_negpowfp` (an
APPROXIMATE exponent counts as non-integral, mirroring evlPower's
`!isExact()`); an infinite result raises float overflow - EXP / POWER the
plain `exception_float_overflow` (22003), SINH / COSH the NAMED
`sysf_fp_overflow` ("... in built-in function @1") via a new
`EvalErr::MathOverflow`; a TEXT operand converts to double by the numeric
grammar (SQRT('4') = 2.0), raising 22018 with the raw string when it is not
a number. **A DOUBLE-store bug fixed beside them:** `encode_wire_value`'s
WireParam::Int -> DOUBLE/REAL arm was guarded `if ws == 0`, so a fractional
literal (2.5 arrives as Int(25, ws=-1)) refused and the INSERT silently
stored NO row (found pre-existing on clean HEAD, `SELECT` of any stored
DOUBLE returned only the NULL rows); it now converts the whole magnitude
with `exact_to_f64`, byte-exact vs the engine for DOUBLE and FLOAT. An
adversarial review (4 dimensions, each verified against the live engine)
confirmed six defects - the POWER domains, the two overflow vectors and the
text operand, all fixed - plus a sixth kept as a **boundary: a DECFLOAT or
INT128 operand**, which the engine computes in the decimal128 domain to a
34-digit DECFLOAT, is REFUSED (fc's decfloat module is add/sub/mul/div/round
only - no decimal128 transcendentals; a separate slice). The exact-rounding
family CEIL / CEILING / FLOOR / ROUND / TRUNC is also a separate slice (its
result scale, integer width and NUMERIC sub-type the engine derives from the
operand - `int_func_form` carries neither scale nor sub-type yet).

**More SysFn scalar functions DONE (2026-08-24): ASCII_VAL(s)
(`serve-real-asciival` 3, the SMALLINT first-byte code), HASH(s)
(`serve-real-hash` 3, the engine's default WeakHashContext - a 64-bit
ELF-style rolling hash, ported byte-for-byte), and a text BLOB's CHARACTER
SET now reaching the catalog + describe (fixed `serve-real-blobfilter`).**
Boundaries: ASCII_CHAR(128..255) and OVERLAY need fc's byte-carrier
CHAR-width handling; the DOUBLE math functions (POWER / SQRT / LOG / ROUND /
CEIL / FLOOR / TRUNC) need f64 arithmetic the executor lacks.

**Bitwise functions BIN_AND / BIN_OR / BIN_XOR / BIN_NOT / BIN_SHL / BIN_SHR
DONE (2026-08-24, `serve-real-bitwise` 6):** the bitwise built-ins in the
SysFn scalar machinery - AND/OR/XOR variadic (2+), NOT unary, the shifts
arithmetic (sign-preserving). Integer in, integer out, folded in i128 so a
wide operand keeps its magnitude. The result TYPE follows the engine off the
expression's NumRank (AND/OR/XOR/NOT floor at INTEGER, the shifts at BIGINT,
either widening to INT128), so the describe matches byte for byte over
literals and columns. An adversarial review caught two INT128 defects (an
i64-truncating fold and a BIGINT-capped describe) plus a shift case it missed
- all fixed. Boundaries: a scaled-NUMERIC / text / NUMERIC(p,0) operand
refuses (fc generic vs the engine's "must be integral types"); a call inside
a PSQL body refuses at CREATE (query surface only). The DOUBLE-valued math
functions (POWER / SQRT / LOG / PI / ROUND / CEIL / FLOOR / TRUNC) stay
refused - the executor has no f64 arithmetic.

**NUMERIC in a FUNCTION signature DONE (2026-08-23, `serve-real-numfunc`
6):** a plain function with a NUMERIC(p,s) param and/or return now loads,
describes from its return descriptor (exact dtype/scale, `RDB$FIELD_SUB_TYPE
1`), binds a scaled/integer/text argument to the parameter's scale
(rescaling half-away, raising 22003 past the width, 22018 on a bad text),
computes through the exe scaled arithmetic, and coerces the result to the
return. `load_function` gate relaxed to `is_numeric_col`; `dsc_to_meta`
now writes sub_type 1 for a scaled param; `run_function` coerces its
result to the return scale (the source-interpreter fallback did not).
Boundaries (recorded): NUMERIC(19-38)/INT128 in a signature — the CREATE
FUNCTION DDL refuses it; DOUBLE/approx — the executor has no f64
arithmetic. NUMERIC in a PROCEDURE signature is a follow-up
(`load_procedure` unchanged; needs the proc output-column describe path).

**NUMERIC in a PROCEDURE signature DONE (2026-08-23, `serve-real-numproc`
8):** the follow-up above — a stored procedure with NUMERIC(p,s) params
and/or RETURNS columns now loads, over both the selectable path
(`SELECT ... FROM P(...)`) and `EXECUTE PROCEDURE`. The describe path
(`proc_out_col` → `wire_for`) already emitted the exact dtype/scale/subtype,
and `bind_proc_args` already rescaled a numeric argument to the parameter's
scale (22003 past width); the two missing pieces were the `load_procedure`
gate (relaxed to admit `is_numeric_col`, like `load_function`) and a
decimal literal in the call arguments — `parse_call_args` read NULL /
integer / `'text'` / `?` but a bare `10.55` fell through and refused the
whole statement. It now parses a decimal literal through the engine's
`text_number` grammar to a `Value::Scaled` (an over-i64 mantissa to
`Value::Int128`); a scientific literal with a positive exponent (`1.5e2`
= 150, which the engine accepts as an argument) folds the exponent into
the mantissa at scale 0, and a hex literal is not taken here.
Verified over numeric-literal / text / negative args, INT→NUMERIC, a
NUMERIC SUSPEND loop, division widening the scale, EXECUTE PROCEDURE, the
22003-past-width vector, and the subtype-1 describe — the ENGINE runs the
BLR fc stored. Boundaries carried from the function slice: NUMERIC(19-38)
/ INT128 in a signature refuses at the CREATE DDL; DOUBLE/approx has no
exe f64 arithmetic.

  `parse_call_args` is shared by every procedure-call site, so an
  adversarial review flagged that the new decimal arm also carries a
  decimal literal into an EXISTING INTEGER/TEXT-parameter procedure —
  where fc used to refuse the whole statement at prepare, and where the
  engine's CVT actually answers. Rather than restore the refusal, the
  binding now MATCHES the engine: `bind_proc_args` rounds an exact-numeric
  argument half-away into an INTEGER parameter (22003 past its width) and
  renders it into a text parameter (`render_exact` — `|scale|` fractional
  digits, trailing zeros kept, a leading `0`, no point at scale 0 — then
  CHAR-padded), and `proc_blr_offset` counts a `<=9`-digit-mantissa decimal
  literal as a LONG so the non-selectable-procedure `-104` offset stays
  byte-exact. So `SELECT * FROM PI(1.5)` now answers `2` and `PT(1.50)`
  answers `1.50`, as they do on the engine.

**Raising a user EXCEPTION from a FUNCTION body DONE (2026-08-23,
`serve-real-fnexc` 5).** A procedure body already raised a named exception
byte-for-byte — the shared PSQL source interpreter (`run_body_source`)
builds the engine's own vector (number, quoted name, message) — but a
FUNCTION hit the same `EXCEPTION E_NEG` and the select-list caller
collapsed EVERY error from the source fallback to `EvalErr::Unsupported`
(a generic "Dynamic SQL Error"), discarding the `ProcErr`'s status. The
caller now surfaces that status (`e.status.unwrap_or(Unsupported)`), so a
raise from a function answers exactly what it answers from a procedure;
only a genuine "cannot run this body" (status `None`) stays Unsupported.
A one-line change. Catching a raise inside a function (a `WHEN ANY` block)
already worked — it happens inside the interpreter before the result
returns. As with every fc raise, the per-level `At function` stack frame
is omitted (the recorded fc-wide boundary; the exception identity is
byte-exact). Boundary still refused at CREATE (dsql does not
compile it): `EXCEPTION <name> <message-override>`. (`WHEN EXCEPTION
<name> DO` handlers DO compile and run — see the next entry.)

**PSQL exception handlers, multi-condition compile DONE (2026-08-23,
`serve-real-whenexc` 5).** A `BEGIN..END` block with `WHEN ... DO` handlers
was already interpreted (the source interpreter's block AST carries a
`Vec<HandlerCond>` per handler and splits the `WHEN` list on the comma) and
single-condition handlers compiled fine — so `WHEN EXCEPTION <name>`,
`WHEN GDSCODE`, `WHEN SQLCODE`, `WHEN ANY` and nested handlers all worked
in procedures and functions (the fnexc entry's "only WHEN ANY compiles"
note was wrong and is corrected above). The one lag was in the dsql
COMPILER: it read a single condition per `WHEN` and emitted a hard-coded
`blr_error_handler` code-count of 1, so a MULTI-CONDITION handler
(`WHEN EXCEPTION A, EXCEPTION B DO`) refused at CREATE. dsql now parses the
comma list and emits the real count with each code in order; the ENGINE
runs the BLR fc stored (a handler mixing `EXCEPTION` and `GDSCODE` catches
both). Gate serve-real-whenexc, 5 checks, byte-for-byte incl the
engine-runs-fc's-BLR check. An adversarial review caught a real
create-then-run inconsistency: `WHEN ANY` may also appear INSIDE a comma
list (`WHEN ANY, EXCEPTION E`), which the engine accepts and runs as a
catch-all — dsql compiled it (the engine even ran the BLR) but fc's own
source interpreter refused it at fetch, so fc stored a procedure it could
not itself run. The interpreter now treats `ANY` anywhere in the list as
catch-all (an empty condition list), matching the engine (a raise of an
exception NOT in the explicit list is still caught). Boundary still refused at CREATE: a user-function
CALL in a body statement (`R = F(A)` — the body's expression surface is
arithmetic-only, a separate pre-existing gap).

**Re-raise `EXCEPTION;` inside a handler DONE (2026-08-23,
`serve-real-reraise` 7).** A bare `EXCEPTION;` re-raises the caught
exception, identity intact. The source interpreter already had the node,
but the dsql compiler required a name after `EXCEPTION` and refused a bare
one. Probed from the engine's stored BLR, a re-raise is `blr_abort, 5`
(condition 5 = blr_raise, no name) where a named raise is `blr_abort, 2,
len, name`; dsql now emits it and the ENGINE runs the BLR fc stored. Two
engine semantics — each a create-then-run trap the moment CREATE started
accepting the statement — were probed and matched: (1) a re-raise with
NOTHING live (at the top of a body, or after a handler completed) is a
NO-OP, not an error — the interpreter's `Reraise` None arm now returns
`Ok(())`; (2) `f.caught` is CLEARED after a handler body, never restored to
an outer level, so a re-raise reached after a NESTED inner handler no-ops
rather than re-raising the outer exception (probed: PN_AFTER answers 99),
while a re-raise BEFORE any inner block still re-raises the outer one. The
old code did the opposite (restored the outer) and its comment wrongly
claimed the engine refuses a bare `EXCEPTION;` at compile — both corrected.
A follow-up closed the trigger side too: `serve-real-trigreraise`
(4 checks). A TRIGGER re-raise compiles through the server's OWN BLR
emitter (`emit_trigger_stmt`, not dsql); `Reraise` was removed from both
the `body_has_uninterpretable_blr` refusal list and the emitter's
interpreted-only group, and a new arm emits `blr_abort, 5` with the same
savepoint bracket a named raise takes in a handler-bearing block. fc does
not itself execute user triggers (it refuses DML on a triggered table),
so the check is compile parity plus the ENGINE firing fc's stored trigger
BLR: a good INSERT succeeds, a bad one re-raises `E_NEG`, one row kept; a
top-level `EXCEPTION;` (unbracketed) no-ops. The exception surface —
raise, catch (all condition kinds, single/multi/nested/ANY-in-list),
re-raise — is now closed for procedures, functions AND triggers.

**EXCEPTION `<name>` `'<literal>'` message override DONE (2026-08-23,
`serve-real-excmsg` 5).** A raise may override the exception's catalog
message with a literal. Probed from the engine's stored BLR: a plain named
raise is `blr_abort, 2, name`; an override is `blr_abort, 6, name` then a
`blr_literal blr_text2` (charset 0, u16 length). Both the dsql compiler and
the server's trigger emitter emit it; the source interpreter uses the
literal in the raised vector (`message.unwrap_or(catalog_message)`), and the
ENGINE runs the BLR fc stored — procedures, functions, a trigger fired on
INSERT, and a doubled-quote message. Boundaries (recorded): an EXPRESSION
(`'v='||A`) or `USING` message refuses (the body expression surface is
arithmetic-only; the engine accepts them, fc will not guess); a message
past fc's ~32000-byte string-literal cap refuses (pre-existing, below the
engine's, so the u16 length field never overflows); a NON-ASCII message
renders mojibake in fc's OWN execution — a pre-existing fc-wide
exception-message encoding issue a plain catalog message shares, and fc
stores the correct bytes so the engine reads it right. The last body-PSQL gap — a
user-function call in a statement — is closed next.

**A bare PLAIN user-function call in a body DONE (2026-08-23,
`serve-real-bodyfn` 8).** `R = DBL(A)`, `RETURN F(A) + 1`. A plain call
compiles to `blr_function` (0x64) — counted name, a u8 arg count, the
arguments (probed from `RDB$FUNCTION_BLR`; distinct from the packaged
`blr_function2`). exe gained `blr_function` (an empty package resolves the
plain function, the slot a bare sibling takes, so its existing recursive
executor runs it); dsql binds a bare name against the catalog's plain
functions (passed from the server via `compile_*_with_funcs`), and a
function's own signature is added so a RECURSIVE self-call resolves.
Verified: call / nested (`DBL(DBL(A))`) / multi-arg / IF-condition /
recursion (`FACT`), fc running its own and the ENGINE running fc's BLR;
arity-mismatch and unknown-name refuse on both. Several create-then-run / create-mismatch
issues were probed against the binary and fixed: a body that BOTH calls a
function AND draws a GENERATOR is REFUSED at CREATE — the call needs exe,
exe declines a generator, and the source interpreter cannot call a
function, so fc refuses rather than store BLR it could not run (a clean
boundary, not a create-then-run split; the engine accepts it, a deliberate
divergence); an adversarial review then CONFIRMED a further one — `ALTER`
and `CREATE OR ALTER PROCEDURE` compiled the body with no catalog
(`&None`), so a function call refused there while a plain `CREATE` accepted
it; `plan_alter_procedure` now threads the db through. A RECREATE that
changes a function's arity uses the new signature for a self-call, and
`function_self_sig` masks string literals when counting the arity. Boundary: recursion past fc's depth guard (48) refuses where the
engine goes ~1000 then 54001 — the recorded stand-in the function-call
slices carry.

**ALTER FUNCTION / CREATE OR ALTER FUNCTION DONE (2026-08-23,
`serve-real-alterfunc` 6).** fc had `plan_alter_procedure` but no function
equivalent, so both refused entirely while the engine accepts them.
`plan_alter_function` mirrors the procedure planner — rewrite the head to
CREATE, compile via `plan_create_function` (WITH the catalog, so a body
function call resolves), repackage as `Plan::AlterFunction` /
`CreateOrAlterFunction`; the execution drops the function and restores it
with the same `RDB$FUNCTION_ID` preserved (`function_id_plain`), a CREATE
OR ALTER of a new name just creates. The failed-DDL vector is byte-exact
(`ALTER FUNCTION @1 failed` 336397261 / `Function @1 not found` 336068649).
Verified: ALTER then CREATE OR ALTER an existing function, CREATE OR ALTER
a new one, a body that calls another function, a recursive CREATE OR
ALTER, and the not-found vector; the ENGINE runs fc's altered functions.
Boundary carried from the body-call slice: a CREATE OR ALTER whose body
BOTH calls a function AND draws a generator refuses at compile (`exe_can_run`
fires through this path too). CREATE / RECREATE FUNCTION unaffected. An adversarial review
caught a real high-severity bug: `drop_function` (shared with DROP FUNCTION)
found the plain function package-aware but DELETED by name alone, so ALTER
(or DROP) of a plain `F` clobbered a coexisting packaged `PKG.F`'s catalog
rows. `drop_function`'s deletes are now package-aware (plain rows only),
fixing the ALTER path AND the pre-existing DROP FUNCTION bug. The same
package-blind pattern was then found and fixed in `drop_procedure` /
`procedure_id` (a targeted bug hunt): ALTER / DROP of a plain procedure had
likewise clobbered a coexisting packaged member; both are now plain-only
(gate `serve-real-plainpkgdrop`, covering procedures and functions).

**COMMENT ON PROCEDURE / FUNCTION DONE (2026-08-23, `serve-real-commentroutine`
6).** COMMENT ON handled TABLE/COLUMN/INDEX/SEQUENCE/EXCEPTION/ROLE/DOMAIN/
DATABASE but not a routine; both refused while the engine accepts them. The
planner's kind list and the ods `CommentTarget` gain Procedure/Function,
writing (or clearing on `IS NULL`) the PLAIN routine's RDB$DESCRIPTION - the
plain row only (RDB$PACKAGE_NAME NULL), never a packaged member of the same
bare name (verified: the comment lands on plain F, the member stays NULL).
The gbak-restore path already mapped routine descriptions, so a comment
survives a round-trip. Boundary (shared by ALL comment targets, pre-existing):
the not-found vector is fc's generic refusal, not the engine's byte-exact one.

**DEFAULT parameters on a PROCEDURE DONE (2026-08-23, `serve-real-procdefault`
7).** `A INTEGER DEFAULT 5`, `A INTEGER = 7`, `A VARCHAR(5) DEFAULT 'hi'`,
`DEFAULT -3`. dsql parses a LITERAL default (integer optionally signed,
string, NULL) in the input list, keeping the exact `DEFAULT`/`=` form;
`proc_default_of` turns it into the stored RDB$DEFAULT_SOURCE (verbatim) and
RDB$DEFAULT_VALUE BLR (the column-default helpers - byte-exact vs the engine:
`05 15 08 00 <i32> 4c` for an int, `blr_text2` for a string); load_procedure
decodes RDB$DEFAULT_VALUE into ProcParam.default, and `with_proc_defaults`
fills an omitted TRAILING argument at every call path (selectable,
run_body_source, try_procedure_blr) before the arity check, the value flowing
through bind coercion (an int default into a NUMERIC parameter rescales; a
NULL default fills NULL). Defaults must be trailing (a plain parameter after a
defaulted one refuses, as the engine does); a call missing a REQUIRED
parameter gives the byte-exact `Parameter mismatch`.

**CONTEXT / keyword parameter defaults DONE (2026-08-24,
`serve-real-ctxdefault` 9).** `DEFAULT CURRENT_USER` / `USER` /
`CURRENT_ROLE` / `CURRENT_CONNECTION` / `CURRENT_DATE` / `CURRENT_TIME` /
`CURRENT_TIMESTAMP` - resolved PER CALL, not a fixed literal. dsql's default
parser takes the keyword, `proc_default_of` stores the engine's own keyword
BLR (byte-identical incl the date/time forms) + verbatim source; a
`ProcParam` carries the UNEVALUATED context form (`default_ctx`) apart from a
literal value, and `with_proc_defaults(ctx)` resolves it per call from the
session (`eval_ctx_default`: the login upper-cased, role NONE, the
attachment id, the clock) wherever a ctx is in reach - the source path
(EXECUTE PROCEDURE, a selectable procedure at execute) and the select-list
function fill. The ctx-less BLR fast paths leave a context default short so
the call falls to the source path; the selectable-procedure PLAN path accepts
a context-default shortfall for the execute-time fill. `required` counts
inputs with neither a literal nor a context default. Verified byte-for-byte
incl the catalog + BLR, fc serving the login/role forms, provided-arg-wins,
the byte-exact missing-required vector, the ENGINE running fc's file, and the
literal->context->literal mix; a three-lens adversarial review found no
defects. Boundaries (recorded): a DATE/TIME/TIMESTAMP-typed routine BODY is
not one fc's arithmetic source interpreter runs (a pre-existing gap,
orthogonal), so fc stores those context defaults and the ENGINE reads them
but fc does not itself serve the fill; CURRENT_CONNECTION is self-referential
(fc's own attach id); a PSQL BODY call omitting a context-defaulted argument
refuses (exe has no context opcode); CURRENT_TRANSACTION and the LOCAL* forms
refuse at CREATE.

**DEFAULT parameters on a FUNCTION DONE (2026-08-24, `serve-real-funcdefault`
11).** The same literal defaults, now on `RDB$FUNCTION_ARGUMENTS`: the dsql
func refusal is gone, `plan_create_function` stores RDB$DEFAULT_SOURCE /
RDB$DEFAULT_VALUE (the same helpers), `load_function` reads it back, and -
because a function in a select list is arity-checked at query-compile, not at
runtime - `user_function_sigs` now reports the REQUIRED arity (inputs without
a default) as a 3-tuple `(Descriptor, arg-names, required)`, so the
`RawExpr::UserFn` check relaxes to `args.len() ∈ [required, params.len()]`
and `try_function_blr` fills the omitted tail with `with_proc_defaults`. A
missing required argument is the byte-exact `Parameter <n> has no default
value`, a surplus is `wrong number of arguments`. A `> i32` default refuses
at CREATE (as on the procedure/column paths). Removing the dsql refusal also
let a PACKAGE member parse a default, so the package writers were reconciled
with the engine's rule that a default lives on the header DECLARATION, never
in the body DEFINITION of a previously declared member: `create_package_body`
refuses ANY body-member default - procedure or function, encodable or not
(the source presence rides `proc_param_of` / `fn_arg_of` through a sentinel
so a `> i32` body default cannot slip past) - with the engine's byte-exact
DYN `dyn_defvaldecl_package_{proc,func}` vector (SQLERR 336397295 "CREATE
PACKAGE BODY @1 failed" then DYN 336068875/336068898 "...previously declared
packaged {procedure,function} @1.@2"); and `plan_create_package` refuses a
HEADER declaration carrying a default rather than store a catalog it cannot
preserve. An adversarial-review workflow found three real defects pre-commit
(the packaged-header wrong-catalog, the `> i32` body-default split, the
packaged-body accept-where-engine-rejects) - all fixed and gated. Boundaries
(recorded): packaged routine parameter defaults (header storage + preserving
the default across the body re-write, both of which the live engine does) and
non-literal / context defaults still refuse.

**Packaged routine HEADER parameter defaults DONE (2026-08-24,
`serve-real-pkgdefault` 7).** A DEFAULT on a packaged routine's HEADER
declaration - the canonical place the engine keeps it (a body default is the
-607 error, already refused). `plan_create_package`'s conv/fnarg header
closures now carry the literal default (the function return never gets one),
an un-encodable `> i32` refuses the CREATE, and create_package's declaration
writers store `RDB$DEFAULT_SOURCE/VALUE`. `create_package_body` PRESERVES it
across the member re-write: the body re-declares members without a default,
the re-write deletes and recreates each member's parameter rows, so new
`carried_member_defaults` reads the header's stored defaults (package-aware,
by parameter name) and re-applies them onto the fresh rows. The fill paths
need nothing new - an external call (a packaged function in a select list or
a body, a packaged procedure via EXECUTE PROCEDURE) resolves the default
through the same catalog-driven, package-aware machinery a plain routine
uses. Verified byte-for-byte incl the defaults surviving in BOTH catalogs,
cross-member scoping (a same-named parameter on another member is not
polluted), and all call forms. Boundary (recorded): a package body member's
UNQUALIFIED sibling call cannot omit the sibling's defaulted tail - the
header's required arity is not reliably visible at body-COMPILE (fc's
plan-time catalog is stale for same-connection DDL, and a header-only
declaration has no BLR for load_function); an external call fills fine.

**Omitted-default body function calls DONE (2026-08-24, `serve-real-bodydefault`
6).** `RETURN FA(X)` where `FA(B, A DEFAULT 5)` now works from inside a
routine body, as it already did in a select list. The engine LATE-BINDS - it
stores `blr_function` with only the arguments passed (a 1-arg call for
`FA(X)`) and fills the defaulted tail from the callee's catalog at run time,
NOT inlining the default at compile time - so fc matches on both sides: dsql
carries `plain_funcs` as `(name, total, required)` and relaxes the body-call
arity to `[required, total]`, emitting a short call whose BLR is
byte-IDENTICAL to the engine's; and exe's `Expr::Function` reads the callee's
input arity from its parsed BLR (message 0, two slots per param) and, when
the call passed fewer, fills the trailing args from
`RDB$FUNCTION_ARGUMENTS.RDB$DEFAULT_VALUE` (`function_arg_defaults` +
`parse_default_expr`, reusing the literal/blr_null parser), coerced like a
passed arg. So fc SERVES the same answer and the ENGINE runs fc's file
identically. Verified byte-for-byte incl the all-defaulted (0-arg),
zero-input, nested-call, string- and two-default edges, and a procedure body.
A three-lens adversarial review found no defects. Boundaries (recorded): a
wrong-arity body call refuses GENERICALLY (Dynamic SQL Error) vs the engine's
07001 Parameter mismatch (the pre-existing shape for all body-call arity
failures, fail-safe); a function omitting its OWN defaulted argument in a
recursive self-call refuses (self-sig required == total).

**The IF statement (blr_if) in exe DONE (2026-08-23, `serve-real-psqlif`
5):** the executor could not convert an IF, so a body combining IF/ELSE
control flow with an exe-only feature (a NUMERIC computation, a function
call, recursion) fell to the source path and refused. exe now runs blr_if
(condition, then, optional else — a missing else is a bare blr_end; a NULL
condition takes the else, as the engine does). This unlocks recursive
functions (`FACT` = IF base case + a sibling call), IF-guarded NUMERIC
bodies, and IF inside a FOR loop with LEAVE. A clean review (no defects).
Boundary: fc refuses recursion past its guard (48) where the engine
handles ~1000 then raises 54001 — the source interpreter's
`psql_depth_guard` stand-in, unchanged.

**WHILE loops (blr_loop / blr_continue_loop) in exe DONE (2026-08-23,
`serve-real-psqlwhile` 5):** exe could not convert a loop, so a WHILE body
combining loop control with an exe-only feature (a NUMERIC accumulator, a
function call) fell to the source path and refused. exe now runs blr_loop
and blr_continue_loop: a blr_label folds into the loop (or FOR) it wraps so
LEAVE ends it and CONTINUE moves to the next iteration; a FOR SELECT
loop's CONTINUE goes to the next row, not out of the loop (`Stmt::For`
gained an optional label). Verified over WHILE+NUMERIC, WHILE+CONTINUE,
nested WHILE with a labelled LEAVE/CONTINUE to an OUTER loop (3 levels),
and a WHILE whose body calls a function — a clean review (no defects), and
`serve-real-loopctl` now runs its bare/labelled control procedures through
exe. Boundary: an infinite loop hangs, as it does on the engine (no
iteration cap, consistent with the source interpreter).

**Function calls inside a body (blr_function2) DONE (2026-08-23,
`serve-real-fncall` 7):** exe gained the function-invoke verb, so a body
that calls another user function - a packaged sibling (`QUAD = DBL(DBL(A))`),
or a qualified `PK.F(x)` from any function/procedure - runs through the
executor instead of refusing. exe fetches the callee's BLR (function_blr)
and runs it recursively; each argument is coerced to the callee's
parameter (numeric rescale + width → 22003, CHAR padding / VARCHAR width),
and the result is coerced to the callee's return scale. A depth guard (64,
safe on the 2 MiB connection-thread stack) turns a runaway recursion
(`RETURN PK.F(N+1)`) into a clean error, never a crash. Boundaries: a
nested callee that draws a GENERATOR refuses (its advance cannot persist
through exe); a recursive/IF-controlled body refuses (exe does not convert
the IF statement); a plain function calling another plain function by a
BARE name still refuses at CREATE (dsql). An adversarial review confirmed
three defects in the first cut - uncoerced args, a lost generator advance,
and a too-high depth guard - all fixed here.

**Packaged functions via exe DONE (2026-08-23, `serve-real-pkgfunc` 6):**
`function_blr` is now package-aware (a dotted `PKG.F` resolves the
packaged member's BLR, a bare name the plain function — the two stay
distinct), so packaged functions run through the exe executor and get its
full scalar surface (NUMERIC params/returns, scaled arithmetic, a NUMERIC
literal, UPPER/CASE) instead of the arithmetic-only source path — closing
the previous slice's packaged-numeric boundary. Boundary: a packaged
member whose body CALLS A SIBLING (blr_function2) still refuses (exe has
no blr_function2; a clean refusal, the engine answers) — needs
blr_function2 in exe.

Other gaps: an explicit `PLAN` (WITH LOCK / FOR UPDATE / OPTIMIZE are
done); a `?` inside any PSQL query (loop, cursor, `EXECUTE STATEMENT`,
`SELECT INTO` — `server.rs:47089`); `GEN_ID` inside an autonomous body;
`INSERT … VALUES` without a column list in PSQL (probed 2026-08-24: needs
BOTH the dsql compiler AND the wire-local `parse_trig_block` interpreter
taught, each with the target's non-computed columns threaded in from the
catalog — dsql alone stores correct BLR but `run_body_source` still refuses,
a create/serve split, so it is a two-parser slice); `EXECUTE BLOCK` with
input parameters (RETURNS is done; not cleanly isql-gateable — isql passes no
input SQLDA); `EXECUTE STATEMENT` with `USING` / `ON EXTERNAL` / `AS USER`
(the dynamic operand and POSITIONAL + NAMED parameters are done); PSQL
literals held as i32 (`serve-real-psqlerrors`); the BLR compiler narrower
than the interpreter (a bare `EXCEPTION;` in a `CREATE TRIGGER` body refuses,
`server.rs:12764`); a read inside a PSQL body is read-committed regardless of
the transaction's snapshot. (Corrected 2026-08-24: `IF (c) THEN CONTINUE` /
`THEN LEAVE` — bare control as an IF then-branch — ALREADY WORK, an earlier
stale claim.)

Not features (the engine's own `-104`, fc refuses too — an error-text
parity gap only): `INTERSECT`/`EXCEPT`, `WITH TIES`, `PERCENT`,
`MIN … KEEP`. Confirmed WORKING (were listed as gaps): the named
`WINDOW` clause, `= ANY`/`= ALL` over a text subquery, a bare/grouped
aggregate over a comma join, `RDB$SET_CONTEXT`/`RDB$GET_CONTEXT`, a
selectable packaged procedure with arguments.

### G. Absent subsystems — the external sort, slice 1 DONE (2026-08-20)

**Done (`serve-real-bigsort` 12):** `crates/wire/src/extsort.rs`, the
engine's `sort.cpp` shape - rows buffered to `FC_SORT_MEMORY` (64 MiB,
`TempCacheLimit`'s default), the buffer sorted STABLY by the same
comparator as before and written as a run under `FC_TEMP_DIR` (unlinked
on creation), the runs merged with ties broken by run then position -
so the order is the comparator's, ties in record order, identical
spilled or not. Wired into the `Sort` row source, `group_rows` and
`distinct_rows` (which was quadratic). Not copied, on purpose: the
engine's quicksort over diddled keys and its seek-ordered merge tree -
measured, its tie order past one 128 KB run is an artefact no gate pins.
**Slices 2–3 DONE (2026-08-20):** the hash-join build side lives in a
`RowStore` (the engine's RecordBuffer over a TempSpace: rows to the
budget in RAM, then an unlinked file, fetched by offset; the hash table
keeps offsets only) — a 300k-row build side spills to 18 MB and answers
byte-identically; an `ORDER BY` fetch streams through `SortedCursor`
(the scan drained into the external sort at open, each fetch pulled
from the merge — the result is never a `Vec`); the `Sort` row source
pulls its merge and honours `Flow::Stop`, so `FIRST n` after a sort
stops the delivery (the runs are still written whole, as the engine's
are). **Slices 4–6 DONE (2026-08-21):** an ORDER BY over a JOIN fetch
streams (`serve-real-joinorder` 12: the join cursor hands back its
COMBINED rows unprojected, the external sort takes them at open, each
fetch pulls from the merge and projects — spills at a 64 KB budget in
the gate); the RIGHT/FULL last part is HASHED by the ON's equi-key by
row index (`build_join_probe` now yields the key for RIGHT/FULL, never an
index; `index_hash` / `mirror_candidates` serve the cursor's mirror
phase, the streaming `for_each` arm and `join_step` alike — 4000×4000
RIGHT/FULL equi-join 2.2 s → 0.37 s, same rows; the side itself is still
a RAM `Vec`, its mirror bitmap needs it whole); `backfill_index` builds
the tree WHOLE from the sorted keys (`btw::build_index_bulk`, the
engine's `fast_load`: leaves in sequence, each level above, the top page
into the existing root — a 300k-row CREATE INDEX 41 s → 0.6 s, `gfix -v
-full` clean, the engine navigates and inserts into the result). **Bug
found on the way, fixed:** the insert path compared the interior page's
DEGENERATE first node (empty key) under the DESCENDING rule, where an
empty key is the GREATEST — once the root had split, every key of a
descending index descended the leftmost child and a propagated split key
landed before the degenerate node: a 300k-row descending index had 52
validation errors and a lookup missed rows. The degenerate node is
−∞ by position now, both directions. **Still open:** no merge join;
the RIGHT/FULL side in RAM.


- **External sort + TempSpace** (`sort.cpp`): every sort, DISTINCT, GROUP BY and hash build lives in RAM (`server.rs:31046 sort_rows`) — a scalability ceiling, not only a feature.
- **MON$** (`Monitoring.cpp`): answered as `Plan::VirtualEmpty` (`server.rs:27032`).
- **Trace API** (`jrd/trace/`, 15 files), **replication** (`jrd/replication/`, 15 files): nothing beyond a constant and a header field.
- **UDR / external engines / external data sources / external tables** at runtime: declarations ride gbak; nothing executes.
- **CryptoManager**: an encrypted database cannot be read (flag decode only).
- **Batch / BulkInsert**, **arrays** (`RDB$FIELD_DIMENSIONS`, gbak refuses them), **blob filters** and **blob level 2** (`blb/src/lib.rs:330`).
- **User management** (gsec, `SEC$`, `CREATE USER`, `Mapping.cpp`).
- **Background and cooperative GC**: only `gfix -sweep` collects; nothing collects during a scan.
- **Shadow maintenance** in the running server (the restore writes the mirror; `CREATE SHADOW` does not exist).
- **Services**: `REPAIR`, `VALIDATE`, `PROPERTIES`, the four user actions, `TRACE_START`, `GET_FB_LOG` refused by number (`svc/src/lib.rs:141`); gstat's data/index/record-version reports refuse with `isc_wish_list` (`server.rs:2998`).
- **sys-packages**: `RDB$BLOB_UTIL`, `RDB$TIME_ZONE_UTIL` absent; `RDB$PROFILER` members are native no-ops.

### H. Recorded divergences kept on purpose

Each is asserted by its gate so a change shows:

- the engine stores a text value of exactly 4× the declared length, silently truncated (a buffer-sizing defect); fc refuses (`serve-real-charset`);
- the engine's string→double is not correctly rounded; fc is (`serve-real-textnum` compares to 16 digits);
- a codepage hole transliterates to U+0000 on the engine; fc keeps the C1 carrier so every table stays a bijection (`serve-real-xlit`);
- a rolled-back writer pins fc's OIT; a read-only transaction burns no id here (`serve-real-oldesttx`, gstat-only);
- a conditional's text result is VARYING here, padded CHAR of the widest branch there; aggregates in a scalar subquery describe BIGINT (`serve-real-decode`, `qualname`);
- generator draws on a DML that fails on row k: the engine draws k, fc draws all (`serve-real-genwrite`);
- bitmap AND is a residual filter here, two bitmaps there; a WHERE on a LEFT join's inner side flips the engine's driver and cannot flip fc's (rows equal, plan differs);
- `i64::MIN` is keyed under zero's key, matching an engine defect; a WIN1252 `ƒ` UPPER raises 22018 as the engine's does.

### I. Stragglers in W1 / R / W7

Compound DESCENDING indexes scan; `fk_partner_has` with a text key
scans; a temporal/double scalar fold arrives as `Tok::FnExpr` and the
outer scans; the WHERE tokeniser cannot spell `-(9223372036854775808)`;
a statement `opt` cannot parse (`HAVING`) scans; `index_itype` stamps
`idx_string` regardless of charset (metadata divergence, no wrong
answer); RIGHT/FULL decline the inner index probe and the hash; probed
join sides must be plain tables; only an ORDER BY still materialises a
join; the `records_for` probe path rebuilds `page_sequence_map` per
outer row. W7: the triggers a statement gathers and the per-statement
clone of the cached check predicates (~127 µs) sit outside the cache.

## The growth chunk: the file grows the engine's way (done)

Laws pinned from `pag.cpp:430-700` (`PAG_allocate_pages`),
`tra.cpp:566-615` (`TRA_extend_tip`, called from `TRA_start` when
`number % transPerTIP == 0`), `dpm.epp:3146` (`extend_relation`) and
`DPM_pages`, then measured on live files:

1. **Pointer-page chain** (`ods::dml::extend_relation`). A full last
   pointer page chains a new one: `ppg_sequence` + 1, `ppg_eof` MOVED,
   `ppg_next` linked, `dpg_sequence = pp_sequence · dp_per_pp + slot`,
   and an `RDB$PAGES (relation, pag_pointer, sequence, page)` row for
   every relation but `RDB$PAGES` itself — the row `DPM_scan_pages`
   needs, without which the engine never reads the second page. The
   FIRST pointer page never uses its last slot (dpm.epp:3195 —
   `ppg_count < dp_per_pp - 1` for sequence 0).
2. **PIP chain + SCN pages** (`ods::dml::allocate_page`). PIP *n* lives
   at `n·pagesPerPIP − 1`, minted all-free when the previous PIP hands
   out its last bit; every multiple of `pagesPerSCN` (= `pagesPerPIP /
   32` = 2,041 at 8K, ods.cpp:63) is formatted as an SCN page and
   stepped over. `pip_used` is a HIGH-WATER mark (`PAG_last_page` sizes
   the file by it; `PAG_release_page` never lowers it — fc used to
   decrement it), `pip_min` = last bit + 1, `pip_extent` lowered on a
   release that frees a whole extent byte. `stamp_page_scns` stamps
   each page's era on the SCN page that OWNS it, slot `page %
   pagesPerSCN`, and an SCN page's own slot 0 carries its own era.
3. **TIP chain** (`ods::dml::ensure_tip_for`). The first id of a TIP's
   range mints it: zeroed page, prior `tip_next` linked, `RDB$PAGES (0,
   pag_transactions, sequence, page)` — a fresh engine database carries
   `(0, 287, 0, 3)` for TIP 0, so the row is the engine's own.

**Measured on the way.** `pip_used` on an engine file is NOT the
allocation mark either — `ensureDiskSpace` raises it to the size the
engine pre-extended the file to (a 64,000-row fixture read 65,312 with
1,300 bits still free); the gate sizes the PIP cell off the free bits.
The engine allocates data pages in aligned 8-page EXTENTS once a
pointer page holds 8; fc allocates one page at a time — same rows,
different page numbers, both readers indifferent (recorded, not
gated). A `SAVEPOINT` burns no id. And a silent no-op fell out of the
probing: `DECLARE I INTEGER = 0;` dropped its initialiser, so a `WHILE
(I < N)` body ran ZERO times and reported success — fixed
(`declared_var_inits`, initialisers run as the assignments they are;
one this server cannot read refuses the body).

**Residual, recorded:** `tip_chain_pages`, `extend_relation` and
`relation_data_pages` find their pages by scanning every page's type
byte — O(pages) per write, ~6 ms per INSERT on a 65k-page image. The
engine keeps these in `RDB$PAGES`-fed vectors; a per-database cache of
pointer-page and TIP page numbers is the next step when it dominates.

## Next, in order

- **RE-EXECUTING A PREPARED STATEMENT DONE (2026-08-30,
  `serve-real-reexec` NEW, 15):** a second execute of a prepared handle
  answered **ZERO ROWS**, silently. A FETCH MUTATES THE LIVE PLAN - it
  materialises into `Plan::Rows`, drains those rows as it delivers them,
  and (since the cursor-exhaustion fix) marks the plan spent when the
  cursor finishes - so the plan a second execute would run is the
  wreckage of the first run. `OP_EXECUTE` clears the cursor maps and
  never rebuilds the plan.
  I INTRODUCED HALF OF THIS. The cursor-exhaustion commit justified the
  spent-marking with "safe across re-execute because `plan` is
  reassigned then". It is not, and I asserted the property instead of
  testing it - the exact mirror-image error the paper section written
  minutes earlier had described. Bisected: a plain scan's second run was
  3 rows before that commit and 0 after. `SELECT COUNT(*)` was ALREADY 0
  beforehand, because its materialised row had been drained, so the
  other half is long-standing.
  Fixed by recording the PRISTINE prepared plan per statement handle and
  restoring it on every execute - in BOTH `OP_EXECUTE` and
  `OP_EXECUTE2`, which is easy to miss since the two handlers open
  identically. Dropped on re-prepare of the same handle and on
  DROP-mode free.
  WHY NO GATE COULD SEE IT: **isql RE-PREPARES every statement text**, so
  it never reuses a prepared handle and cannot reach a second execute.
  All 355 gates went through isql or a node client with no statement
  cache. An entire class of defect sat behind that door with no key. The
  new gate uses node-firebird with `statementCacheSize` and runs every
  plan shape THREE times; its header says why it must not be
  "simplified" onto isql.
  THIS IS THE SECOND DEFECT IN A ROW that survived because the probe
  used a client which cannot exercise the path - the 500-row duplication
  was invisible to node-firebird for the opposite reason. The pattern is
  worth more than either fix: **when a defect is about a protocol
  SEQUENCE, the client is part of the experiment.**
  Found by an audit of the fetch/cursor state machine that was
  commissioned precisely because two silent defects had just been found
  in it; its first predicted case was this one.

- **A CURSOR IS CONSUMED BY ITS FETCH DONE (2026-08-30,
  `serve-real-fetchdup` NEW, 17):** **ANY result of 500 rows or more was
  delivered TWICE.** Not a window, not a join, not a sort: a plain
  `SELECT ID FROM T` with no WHERE and no ORDER BY. Row 1 came back
  twice and so did row 600; 1200 rows where the engine sends 600.
  TWO SEPARATE PATHS, and the first fix caught only one.
  (a) `emit_rows` walks the WHOLE plan and ignores the count the client
  asked for, but only `Plan::Rows` was emptied afterwards - so a
  STREAMING plan was re-walked from the start on the next op_fetch.
  (b) The resumable-cursor route REMOVES the cursor when it reports
  end-of-cursor, which loses the difference between "never started" and
  "already drained". fbclient sends one more op_fetch after the end
  status - it does so from 500 rows up - and, finding no cursor, the
  server opened a FRESH one and served the entire result again.
  A JOIN was already safe because it sets `keep_on_done` and therefore
  RESUMES an exhausted cursor. That asymmetry is the tell: a self-join
  agreed while the plain scan did not.
  Both now mark the plan spent on completion, so the extra fetch drains
  nothing and repeats the end-of-cursor status. Safe across re-execute
  because `plan` is reassigned then - keeping the CURSOR instead would
  have broken re-execution, since nothing removes cursors on execute.
  WHY NOTHING CAUGHT IT, and it is the same reason the windowed
  six-fold duplication hid: under ONE fetch the answer is correct, and
  one fetch is every hand-written test in the suite. It is wrong only
  from the SECOND fetch on. PRE-EXISTING - reproduced on the binary two
  commits back, so it predates the window work entirely.
  A METHOD ERROR WORTH RECORDING: I saw this duplication days-of-work
  earlier, checked it with node-firebird, got the correct row count, and
  concluded it was an isql rendering artifact. **node-firebird does not
  send the extra op_fetch, so it cannot observe this defect at all.**
  Verifying with a client that does not exercise the path is not
  verification. What settled it was counting occurrences of SPECIFIC
  rows rather than lines, then instrumenting the server to count fetch
  invocations: 499 rows is one fetch, 500 is two.
  The first fix was also verified too narrowly - only on `FIRST n`
  shapes, which are served by the path it changed - and the gate written
  afterwards caught the plain scan immediately. Write the gate before
  declaring the fix done.

- **THE NULLABLE BIT THROUGH A VIEW AND A GROUPED JOIN DONE
  (2026-08-30, `serve-real-nullbit` NEW, 27):** two describe defects,
  and in this server a describe defect of this kind is a VALUE defect -
  the announced bit decides whether a value's bytes go on the wire.
  (1) **EVERY COLUMN OF A VIEW IS NULLABLE**, whatever its body says.
  `plan_view` took the body's columns verbatim (`output_cols_of` is a
  clone) and touched `sql_type` NOWHERE, so a view over a NOT NULL
  column announced NOT NULL. The engine's rule is UNCONDITIONAL -
  measured over a plain NOT NULL column, a DOMAIN-typed one, an
  expression, through a WHERE, view-over-view, aliased, and nested in a
  derived table - and it agrees with the catalogue, where a view's
  RDB$RELATION_FIELDS row carries no RDB$NULL_FLAG at all.
  (2) **A GROUPED JOIN WAS NEVER MARKED AT ALL.** The grouped branch of
  the join planner returns ~230 lines BEFORE the only
  `mark_not_null_join` call, so a NOT NULL key came back Nullable while
  the same query WITHOUT the join was correct. No nested source is
  needed; plain base tables show it.
  MEASUREMENT REFUTED THE REPORT, and that is the main lesson. The brief
  named four "lost bit" shapes - a CAST through a derived table, `N + 0`,
  a derived joined to a base table, and the CTE form. ALL FOUR AGREE
  with the engine today. No fix was written for them; they are gated as
  CONTROLS instead, so a future change that breaks them is caught. A
  read-only code analysis had traced a plausible mechanism for them and
  it did not survive contact with the engine.
  TWO SELF-INFLICTED ERRORS, both caught by the gate's own fences rather
  than by the sweep. Passing the grouped columns straight to
  `mark_not_null_join` is wrong: a grouped column's `field_id` indexes
  the GROUP ROW, not the joined record, so the side lookup is
  meaningless - right for an INNER join by luck and wrong for an OUTER
  one, which is precisely the shape that would have shipped a wrong bit.
  The fix builds a probe from `gitems`, where a plain key's fid IS a
  combined-record id. Expression keys then needed the same treatment,
  carried as `key_exprs` so the marker can evaluate them against the
  join's own predicate.
  THE INTERACTION, gated: `<view> JOIN <base>` agreed BEFORE either fix
  and still agrees, because the join side discards a column's bit at the
  boundary - a fix that made the side CARRY the bit without fixing the
  view would have broken it.

- **A WINDOWED RESULT LARGER THAN ONE FETCH BATCH DONE (2026-08-30,
  `serve-real-winbatch` NEW, 15):** a bare top-level `SELECT ID,
  ROW_NUMBER() OVER (ORDER BY ID) FROM T` over 5000 rows came back **SIX
  TIMES OVER** - 30000 rows, row 1 at line offsets 2, 5002, 10002,
  15002, 20002 and 25002, five of the six blocks byte-identical. No
  error. And node-firebird, which honours the protocol's flow control,
  HUNG and never returned.
  `branch_rows` answers None for a windowed Project, so the plan was
  never materialised into `Plan::Rows` and control fell PAST the
  batching code to a path that ignores the client's requested batch size
  and re-emits the whole result every time it is asked. Under ONE batch
  the answer is correct - which is every hand-written test, including
  all 83 checks the window gate had - so it is wrong only from the
  SECOND fetch onwards. That is why a 353-gate suite never saw it, and
  why the new gate builds 5000 rows on purpose and asserts the
  MULTIPLICITY of individual rows: a row-count check alone passes the
  broken server on its first batch.
  Fixed by materialising a windowed projection in the fetch path BEFORE
  the generic `branch_rows` attempt, through the SAME fold the streaming
  emit path uses (`fold_project_windows`) rather than a second copy. The
  order is load-bearing and is why it is a shared function: scan with an
  EMPTY sort key, fold each window over its whole partition, and only
  THEN sort. A window folds over the partition, so a per-batch fold
  would be wrong exactly past the first batch boundary, and
  ROW_NUMBER's tie order is pinned to SCAN order, which a pre-sort would
  move.
  Found by a workflow sent to investigate something else entirely (the
  nested prepare-then-fail cluster), which is a fair argument for
  probing the paths ADJACENT to a defect and not only the defect.

- **`sqlerr` GATE COLLISION REPAIRED (2026-08-30):** eleven DDL gates
  compiled their `sqlerr` helper to ONE shared path,
  `/tmp/fbhandson/sqlerr`. Under `-j 4` a gate recompiling it while
  another executed it gets `Permission denied` (ETXTBSY), which surfaces
  as a DIFF whose two sides are IDENTICAL but for the isql line number
  that reported it - a failure that looks like a real divergence and is
  not. Each gate now compiles to `sqlerr-<gate>`; all eleven pass when
  run concurrently, which is the condition that produced it.

- **WINDOW FRAMES OVER A NULL KEY, AND LAG/LEAD'S DEFAULT DONE
  (2026-08-30, `serve-real-window` 83 -> 119):** two silent wrong-answer
  classes, both with a byte-identical SQLDA.
  **THE EXPLICIT RANGE FRAME WAS A VALUE FILTER**, and it got the NULL
  ordering key wrong twice over: `keyi(ri)?` dropped every NULL-key row
  from every OTHER row's frame even when that side's bound was
  UNBOUNDED, and the `None =>` arm hard-wired a NULL-key row's own frame
  to its NULL peers without ever consulting the bounds. The reported
  symptom was two offset shapes; the real extent is wider - `RANGE
  BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`, the whole
  partition BY DEFINITION, answered 2,2,7,7,7,7,7,7,7 over a nine-row
  partition with a two-row NULL peer group where every row is 9, and the
  SUMs were corrupted with the counts (200 vs 30 at one row), so this was
  wrong DATA and not a miscount.
  Now a POSITION INTERVAL over the sorted partition, which is how the
  IMPLICIT frame arm always worked - and that asymmetry is what localised
  it: `OVER (ORDER BY K)` agreed while the semantically identical `RANGE
  BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` did not. Both are gated
  now so the two paths cannot drift.
  The measured laws: UNBOUNDED IS ABSOLUTE (the partition edge, whatever
  the NULLness - there is no NULL/non-NULL barrier); a NULL key never
  satisfies a VALUE bound of a non-NULL row; an OFFSET bound on a NULL
  CURRENT key degenerates BY SIDE to that row's peer group while an
  UNBOUNDED bound on the same row does NOT (proved side-based by `RANGE
  BETWEEN 1 FOLLOWING AND 3 FOLLOWING` giving a NULL row its whole peer
  group, neither 0 rows nor 1); peers are equality on the ORDER BY tuple
  with NULL not distinct from NULL; CURRENT ROW under RANGE reaches
  through the LAST peer.
  **LAG/LEAD'S DEFAULT WAS NEVER CAST** to argument #1's type - it was
  handed to the evaluator raw and the announced descriptor was stamped
  onto whatever the literal happened to be, so the client read the
  MANTISSA: `LAG(<INTEGER>, 1, 2.5)` answered **25** where the engine
  answers 3, `LAG(<NUMERIC(9,2)>, 1, 7)` answered 0.07 for 7.00, and
  `LAG(<INTEGER>, 1, '12')` answered 0 for 12. Not in the original hunt;
  found by the measurement pass. Ordinary CAST semantics now apply
  (`cast_target_of_col` rebuilds the argument's own type as a target),
  and the default never widens the result - `LAG(K, 1, CAST(9 AS
  BIGINT))` still describes LONG len 4.
  Closes hunt findings 4 and 20 and this new one.
  NOT ATTEMPTED HERE, and the natural next chunk: the **28
  PREPARE-THEN-FAIL** shapes the measurement pass found - a window inside
  a CTE, a derived table, a UNION branch, a view body or an INSERT ...
  SELECT source PREPAREs with a byte-identical correct SQLDA and then
  dies, and in the UNION ALL case DELIVERS NINE CORRECT ROWS before
  failing mid-stream. Those are protocol violations rather than
  boundaries: the client has been told the statement is valid and has
  cached its description. The real fix is to make `branch_rows_res`
  window-aware (fold before sort, mirroring emit's Project arm) and must
  ship with a full SQLDA re-diff of the nested shapes; it also re-routes
  the batch-fetch and scrollable-cursor paths, which are unprobed. A
  cheaper way-station - refusing them at PREPARE - is honest but refuses
  shapes the engine answers, so it is only defensible as a step on the
  way.

- **A GROUPED SELECT LIST'S EXPRESSIONS GET THE ORDINARY NULLABLE RULE
  DONE (2026-08-30, `serve-real-groupconst` 11 -> 29):** `plan_group`
  had a nullability pass covering only the plain group KEYS, so every
  grouped EXPRESSION kept the bit `build_expr_col_from` stamped and came
  back Nullable - `SELECT 1 FROM T GROUP BY 1` and `SELECT <NOT NULL> +
  1 FROM T GROUP BY 1` both, while a grouped plain FIELD was already
  right. Every Project and Join site calls `mark_not_null_cols`; this
  one never did. Reported as the "all-literal temporal difference" half
  of a temporal finding, and not temporal at all - two non-temporal
  controls are what identified it.
  TWO LAYERS. An expression column takes `expr_nullable` directly. An
  expression GROUP KEY cannot: `build_group_items` builds its column
  through `build_expr_col` and then deliberately CLEARS `expr`, so the
  output column reads plainly from the group row's synthetic slot - the
  expression survives only in `key_exprs`, indexed past `synth_base`.
  THE REGRESSION THIS CAUSED, and it was not cosmetic. The statistical
  folds answer 0 rather than NULL and the engine describes them NOT
  NULL; marking them Nullable made `VAR_SAMP(N) + 1` over an empty set
  answer **<null>** where the engine answers 0.0, because the announced
  bit decides whether the bytes are shipped at all. Caught by
  `serve-real-statexpr` in the sweep.
  THE FIRST GUARD WAS ALSO WRONG: it skipped expressions reading a slot
  past `synth_base`, on the assumption that is where folds live.
  `GItem::Agg` carries no field id at all - a fold's slot is POSITIONAL,
  its index in `gitems` - so it can sit BELOW `synth_base` and
  `VAR_SAMP(N) + 1` went straight through. `synth_base` is the base for
  expression KEYS, which is not the same thing as "everything
  synthetic". The guard now tests the actual fold positions.
  Closes the Nullable half of hunt finding 25.

- **THE TEMPORAL CLUSTER DONE (2026-08-29, `serve-real-temporal2` 69):**
  five defects, two of them the worst kind - a value that LOOKS right.
  **DATEADD OVER A ZONED OPERAND ANSWERED A PLAUSIBLE LIE.** `eval`'s
  DateAdd arm decomposed Date/Time/Timestamp and sent everything else to
  `_ => Ok(Value::Null)` under the comment "type-checked away" - but
  `type_of` accepts EVERY TKind, the zoned ones included. The NULL then
  travelled under a NOT NULL describe: the encoder omitted the bytes and
  the client decoded their absence as `1858-11-16 00:01:00.0000 -23:59`,
  the Modified Julian Day epoch with zone id 0. It reads as a timestamp
  rather than as a missing value, which is exactly why it survived -
  EVERY DATEADD over a TIMESTAMP WITH TIME ZONE answered it, for every
  part and every amount. DATEDIFF over a zoned pair answered a constant
  0 from the same omission.
  THE LAWS, measured: DATEADD's result is the operand's own type, the
  arithmetic runs on the STORED UTC halves under ordinary zoneless
  calendar rules, and the zone id rides through UNCHANGED. DATEDIFF
  measures the UTC INSTANT and never the wall clock - the same wall
  clock under different offsets is NONZERO (-3 HOUR between +02:00 and
  +05:00) while the same instant under different zones is 0, which is
  the pair of checks that distinguishes the two models. The decisive
  evidence for DATEADD is on a RULED zone, where the models differ:
  `DATEADD(DAY, 1, '2024-03-30 12:00 Europe/Berlin')` is 03-31 13:00,
  twenty-four hours of INSTANT across the DST step, which local-field
  arithmetic cannot produce. (fire-crab refuses ruled-zone literals, so
  that one is the engine's measurement alone; every fixed-offset probe
  passes under either hypothesis and the implementation follows the
  measured law. Recorded as such.)
  The part-legality corollaries had to land in the SAME change: a TIME
  WITH TIME ZONE takes only the clock parts, exactly as a zoneless TIME
  does, and without widening those tests the new arms would have
  answered a WRONG VALUE for `DATEADD(DAY, .., <ttz>)` rather than the
  NULL they used to - a strictly worse outcome.
  **THE SHAPE OF A TEMPORAL DIFFERENCE.** `result_scale` already knew
  it; the width, the rank and the sub_type did not. `DATE - DATE`
  announced INT64 len 8 for a 4-byte LONG, and both scaled differences
  announced sub_type 0 where the engine says NUMERIC's 1. The width
  error CASCADED - `rank_of` found no numeric rank on either operand,
  fell to its `(None, None)` default of Long, Sub widened to I64, and
  `* 2` promoted to INT128 where the engine stays INT64. All four now
  read ONE classifier (`temporal_diff_shape`) so they cannot drift apart
  again.
  **A TEMPORAL RENDERED AS TEXT HAS A NATURAL WIDTH** - DATE 10, TIME
  13, TIMESTAMP 25 - where every implicit conversion fell into the 32765
  catch-all. It contributes a WIDTH but NO CHARSET; the text operand
  alone decides that. Mid-fix, adding it as a trailing catch-all fixed
  the LITERALS and left every COLUMN at 32765, because a temporal column
  has its own earlier `Expr::Col` arm - so the test is now the FIRST
  thing `text_form` does. The string functions then split, and not the
  way one would guess: UPPER, LOWER, TRIM and SUBSTRING over a temporal
  announce charset ASCII (re-announced as the attachment's under a real
  one), while LEFT, RIGHT, REVERSE, LPAD and REPLACE announce NONE and
  STAY NONE under UTF8. Both families are gated, since the rule is not
  uniform and the second was already right.
  Closes hunt findings 7, 8, 23, 24, 26 and the sub_type half of 25.
  SPLIT OUT DELIBERATELY: the Nullable half of finding 25 is NOT
  temporal. `SELECT 1 FROM T GROUP BY 1` and `SELECT ID+1 FROM T GROUP
  BY 1` are Nullable here and not on the engine, while a grouped plain
  FIELD is correct on both - `plan_group` never calls
  `mark_not_null_cols`, unlike every Project and Join site. That moves
  the describe of EVERY grouped statement and wants its own change and
  its own sweep.

- **CONCATENATING ACROSS CHARACTER SETS DONE (2026-08-29,
  `serve-real-concatcs` 44):** `eval` joins two rendered strings and has
  no descriptors to convert against, so an operand whose charset
  differed from the result's was spliced in as it stood. A `String`
  means different things per charset here - a byte carrier's octets ride
  one char per byte, a UTF8 column's are real characters - so this was
  not a rounding difference.
  **THE WORST OF IT WAS NOT A WRONG ANSWER.** `<NONE> || <WIN1252>`
  carried the NONE octets as chars U+0073.. U+009F.., announced the
  result WIN1252, and the emit path then tried to TRANSLITERATE those
  chars into WIN1252 - where U+009F has no image, WIN1252 mapping 0x9F
  to U+0178. It failed MID-ROW, after bytes were already on the wire:
  SQLSTATE 08006 and a DROPPED CONNECTION. The gate therefore asserts
  the session answers a SECOND question afterwards, not merely that the
  bytes agree.
  THE LAW (probed): a byte carrier is BYTES; a conversion to or from one
  is a BYTE COPY, never a transliteration. `transcode_text` already
  implemented exactly that - carrier source to tabled destination
  re-spells each octet, a carrier destination copies bytes - and nothing
  called it from the concatenation path. Each operand whose charset is
  STATICALLY KNOWN is now converted to the result's set before joining,
  through the synthetic text CAST that invokes it.
  Also fixed: a BYTE-CARRIER RESULT counts BYTES, not characters.
  `<UTF8 VARCHAR(32)> || <OCTETS VARCHAR(32)>` is 160 bytes on the
  engine (32x4 + 32) where summing characters announced 64 - and an
  announced width that disagrees with the shipped bytes is the same wire
  desync as above. (`cs_join` itself was already right: OCTETS absorbs
  from either side, NONE is weakest, ASCII yields to all but NONE.)
  TWO REGRESSIONS CAUGHT BEFORE SHIPPING, both by adjacent gates rather
  than by the sweep summary. The second is the more instructive: the
  wrap fired for CATALOG columns, which carry UNICODE_FSS, and
  `transcode_text` implements byte carriers, the tabled single-byte sets
  and UTF8 - nothing else. A carrier source into UNICODE_FSS falls
  through to `decode_text`, which answers None for an untabled set and
  raises `Malformed string`, so `RDB$FUNCTION_NAME || RDB$MODULE_NAME`
  became an ERROR where the engine answers (`serve-real-blobfilter`).
  The wrap is now restricted to destinations `transcode_text` actually
  implements - the same predicate `cast_source_charset` already uses.
  What pointed at the cause: `TRIM(<same col>) || TRIM(<same col>)`
  worked while two DIFFERENT columns failed, which ruled out the TRIM
  and the CAST and left the charset PAIR. It was then confirmed as ours
  by rebuilding the committed binary and re-running the query - the same
  check that had earlier established the gbakverbose flake was NOT ours.
  And the first: the first cut wrapped BLOB operands too. A
  blob concatenation's result type is found by WALKING for a `BlobText`
  node, and that walk does not descend through a CAST - so the wrapper
  HID the blob and a binary one described as a text blob, sub_type 1
  charset UTF8 where the engine says 0. `serve-real-blobexpr` caught it;
  blob concatenations are now left alone.
  DIVERGENCES (recorded, and ASSERTED in the gate as known-different so
  that FIXING them trips it): a **`<NONE column> || <literal>`** still
  splices the carrier's octets as UTF-8, because a literal's charset is
  the ATTACHMENT's and the join is therefore the attachment sentinel -
  no static conversion is possible, and the eval path has no attachment
  at all. Fixing it needs the conversion DEFERRED to emission. Note
  `<OCTETS> || <literal>` is CORRECT, since OCTETS absorbs and the join
  is statically known. Second: **`CAST(<literal> AS ... CHARACTER SET
  WIN1252)` under a NONE attachment** - the engine byte-copies the
  literal's octets where this transliterates; under UTF8 it agrees. Both
  answer with the wrong bytes rather than refusing.
  Closes hunt findings 11 and 12, and the column half of 10; the literal
  halves of 10 and 30 remain, precisely characterised above.

- **A NARROWING NUMERIC CAST RAISES 22003 DONE (2026-08-29,
  `serve-real-castint` 42 -> 58):** `CAST(<value> AS NUMERIC(p,s))`
  checked only the i64 edge, so a value that overflowed a NARROWER
  target wrapped silently: `CAST(123456789012.34 AS NUMERIC(9,2))`
  answered **19428925.30** - the raw scaled integer taken modulo 2^32 -
  where the engine raises `numeric value is out of range`. A plausible
  wrong number, which is the worst kind. The INTEGER family already had
  the check; the SCALED family did not.
  THE LAW, and it is not the obvious one: the engine checks the TARGET'S
  STORAGE WIDTH, **not the declared precision**. It ACCEPTS
  `CAST(15000000.00 AS NUMERIC(9,2))` although nine digits at scale 2
  top out at 9999999.99, and refuses only past the 4-byte slot. The
  boundaries land exactly on the integer limits, probed in both
  directions: 327.67 / 327.68 for a 2-byte NUMERIC(4,2), 21474836.47 /
  21474836.48 for a 4-byte NUMERIC(9,2), 922337203685477.5807 / ...5808
  for an 8-byte NUMERIC(18,4). Guessing "precision" here would have
  refused a pile of statements the engine answers.
  The vector matters too: this raises `EvalErr::NumericOutOfRange`
  (`isc_arith_except` + `numeric value is out of range`), the pair a cast
  to an INTEGER target already used - not `IntegerOverflow`, which is the
  same SQLSTATE 22003 with a different message and was what a first cut
  emitted.
  Closes hunt finding 9.

- **A SCALAR SUBQUERY ANSWERS UNDER ITS INNER COLUMN'S DESCRIPTION DONE
  (2026-08-29, `serve-real-subqdesc` 40):** a whole-item
  `(SELECT <col> FROM T WHERE ...)` is folded here by EXECUTING the
  subquery at plan time and splicing its value back as a literal. The
  fold is fine; the describe was then taken FROM THAT LITERAL - from the
  row that happened to be read. The inner plan was already computed at
  the fold site and thrown away unless it folded to a `Plan::Scalar`,
  which a plain-column subquery never does (the code said so in a
  comment three lines below). Five defects from that one cause:
  (1) **THE DESCRIBE DEPENDED ON THE DATA** - `(SELECT <BIGINT>)`
  announced LONG len 4 for a small stored value and INT64 len 8 for a
  large one. A protocol violation on its own, since a client caches what
  PREPARE told it, and the one law here no value comparison can catch:
  both describes render the right number.
  (2) a SMALLINT came back LONG; (3) a NUMERIC lost its scale and family
  code and was widened to INT64; (4) a subquery matching NO ROWS
  described as TEXT(1) CHARACTER SET NONE, the literal being the word
  NULL; (5) TEXT lost its CHARACTER SET and that CORRUPTED THE VALUE -
  under a NONE attachment a WIN1252 column shipped the UTF-8 spelling
  C3 A9 under a describe saying CHARACTER SET NONE, which the client
  re-expanded to C3 83 C2 A9.
  Fixed by not discarding the inner plan: `ScalarTy::from_col` takes the
  inner ProjCol's whole announced shape. `ScalarTy` gained `scale`,
  `sub_type` and `oct_length` - three fields could not express
  `(SELECT MAX(<NUMERIC(9,2)>))`, which is LONG len 4 scale -2 sub_type
  1 (probed; the DECIMAL twin is 2). That is not cosmetic:
  `ProjCol::value_of` raises IntegerOverflow when a value's scale is
  FINER than the announced one, so a carrier defaulting to scale 0 over
  a `Scaled(raw, -2)` would turn a working query into an ERROR rather
  than a wrong number.
  MEASURED FIRST, as the plan required: the engine describes a subquery
  EXACTLY as its inner column - CHAR(10) UTF8 stays 452 TEXT len 40 like
  the bare column, VARCHAR stays 448, OCTETS stays charset 1, WIN1252
  keeps charset 53 under a NONE attachment and rescales to the
  attachment under UTF8. The decisive probe was the value BYTES under
  each attachment: under UTF8 and WIN1252 fire-crab's bytes were ALREADY
  correct and only the padding width was wrong, which is what proved the
  fold's value round trip is clean and the whole defect was the lost
  description. (One of the three analysis passes had speculated the text
  was mangled on the round trip; the probe refuted it.)
  ALSO FIXED, found while testing the above: **`SELECT NULL X`** - a bare
  NULL with a bare, no-AS alias - was refused. `split_alias` treats a
  trailing NULL in the head as the tail of an `IS NULL` (which must keep
  refusing, since a projected boolean is not answered correctly here); a
  head that IS exactly NULL is the literal. It surfaced through this
  construct because a no-row subquery with a bare alias folds to
  precisely `NULL X`.
  AND: **any select item CARRYING a subquery is nullable**, not just a
  whole-item one. `(SELECT <col> ...) + 1` folds to two constants and
  described NOT NULL where the engine says Nullable - the subquery might
  have matched no row - and `EXISTS(<sub>)` is BOOLEAN Nullable on the
  engine too. The law already lived at the whole-item patch site; it now
  covers every item containing a marker.
  This closes hunt findings 3, 16, 17, 18, 19 and 31.

- **`serve-real-gbakverbose` REPAIRED (2026-08-29):** it had broken two
  consecutive sweeps and passed on every retry, which is the most
  dangerous shape a gate can have - it trains you to wave the failure
  through. Reproduced 1-in-3 STANDALONE on an idle box, which ruled out
  both load and the change under test, and then diagnosed to TWO real
  defects in the gate itself.
  (1) Its fixture was created with a BARE PATH, so the EMBEDDED engine
  made the file as the invoking user, while every consumer reached it
  through `localhost:service_mgr` - a service running as the `firebird`
  user. That mixed-mode access intermittently lost the race with the
  embedded process still releasing the file and answered `I/O error
  during "open" operation`, surfacing as `both -v backups run (rc)` want
  0/0 got 1/0 - THE ENGINE'S OWN gbak failing, on a gate whose subject is
  fire-crab. Now created through the server, the same law the rest of the
  suite follows.
  (2) The stream comparison was newline-based, and the engine's verbose
  service output does not merely re-chunk mid-line (known since
  2026-08-28) - it sometimes CUTS A RECORD OFF MID-WORD. A captured
  failing run held `gbak: writing privile`, which the `writing privilege`
  filter did not match, so the fragment survived and misaligned every
  line after it. The comparison now splits the stream on its own `gbak:`
  record marker rather than on newlines, and the privilege filter matches
  the truncated prefix. Privilege records are excluded by design (the
  engine writes them, fire-crab does not), so excluding their fragments
  weakens nothing.
  10 consecutive clean standalone runs after the fix, where before it
  failed 1-in-3.

- **BRANCH RECONCILIATION BEYOND UNION DONE (2026-08-29,
  `serve-real-branchtype` 51):** a UNION describes one column per
  position and decodes every branch's value under it - and so does a
  CASE, a COALESCE, an IIF, a DECODE and the anchor/recursive pair of a
  recursive CTE. The law has two halves: the description is RECONCILED
  from every branch, and every branch's VALUE is then brought to it.
  fire-crab had the first half and not the second, which is the worst
  possible split - the describe looks right, a row comes back, and the
  number in it is wrong.
  **THE FLAGSHIP:** `SUM(CASE WHEN <false> THEN CAST(1.50 AS
  NUMERIC(9,2)) ELSE 100 END)` answered **2.00** where the engine
  answers 200.00. The integer branch handed back a raw 100 where the
  announced scale of -2 wanted 10000, so every row contributed 1.00.
  `SUM(CASE WHEN ... THEN <amount> ELSE 0 END)` is a workhorse idiom and
  it was returning money short by a factor of 100. What hid it: the
  DIRECT projection of the same conditional is CORRECT on both servers,
  because the encoder renders the value's own scale - the defect only
  appears once an aggregate or a `CAST` to text CONSUMES the datum, so a
  value-only check of the expression sees nothing. Fixed by
  `align_conditional`, which wraps a scaled conditional in the CAST that
  already implements rounding, at the same single resolution point
  `pad_conditional` uses - so the aggregate's source, the cast's source
  and the select list are all covered at once, and `eval` (which has no
  descriptors to reconcile against) is left alone.
  Same law, four more places:
  (a) a conditional's **sub_type** is the MAX family code of its
  branches; CASE had no arm in `numeric_subtype` at all and announced 0
  for every one. NULLIF instead takes its **FIRST** operand's alone -
  its value IS that operand.
  (b) **MIN/MAX describe what their SOURCE describes**, expression
  sources included. Reading `MAX(ID+0)` is INT64 as "an expression
  source stays the fold's INT64" was the wrong lesson: `ID+0` is itself
  INT64, the arithmetic having widened it before the fold saw it, while
  `MAX(CASE ... <INTEGER> ... END)` is a 4-byte LONG.
  (c) **an 8-byte NUMERIC RANKS as I64** - what makes SUM widen it to
  INT128 and a multiplication around it promote. `CastTarget::Numeric`
  mapped everything below 16 bytes to Long, so neither fired (probed:
  `SUM(CAST(1.5 AS NUMERIC(18,4)))` is INT128 where the NUMERIC(9,2)
  one stays INT64).
  (d) a **UNION of TEXT branches** takes the widest length, VARYING wins
  over the fixed form, and the charset follows the concatenation join
  (a real charset beats a literal's attachment sentinel and beats NONE;
  of two reals the FIRST branch's wins). This was a gap in the union
  chunk two commits back: that reconciliation compared type, scale and
  sub_type but NOT length, so two CHAR branches looked identical, kept
  the first branch's width, and `'a' UNION ALL 'bb'` announced one
  character and died mid-cursor with a 22001. The width is maxed in
  CHARACTERS, not the branches' own units - a plain column carries its
  width in the bytes of ITS OWN charset, so the same six-character union
  is 6 bytes under WIN1252 and 24 under UTF8.
  BOUNDARY (recorded, gated): a **recursive CTE whose recursive member
  answers at a different SCALE from the anchor** now REFUSES. It used to
  answer **15** - the raw of 1.5 read as a scale-0 integer - and 15 then
  failed the loop's own `X < 3` guard, truncating the result set as
  well. The engine keeps the recursion in FULL PRECISION and renders
  only at the anchor's description (`SELECT 1 UNION ALL SELECT X + 0.5`
  answers 1, 2, 2, 3, 3 - the values 1, 1.5, 2.0, 2.5, 3.0 each rounded
  at output), which needs two column sets this planner does not carry.
  The first version of the check compared the announced TYPE too and
  refused the ordinary integer generator, since `X + 1` widens to INT64
  against a LONG anchor while the values are identical - caught before
  commit; only the SCALE is compared.
  KNOWN DIVERGENCE (recorded, not gated): a **simple CASE (`CASE x WHEN
  ...`) and DECODE are announced NOT NULL where the engine says
  Nullable**, even with an ELSE - a searched CASE with an ELSE correctly
  is not. Both lower to the same `Expr::Case` node as a searched one, so
  telling them apart needs a flag on it and a dozen match sites updated.
  The VALUES are identical; this is the describe's nullable bit alone.
  Found by a 12-agent differential hunt across six SQL surfaces, which
  confirmed 37 wrong answers and 26 refusal boundaries in all; this
  entry closes the branch-reconciliation cluster. The rest are listed
  under "What the hunt found" below.

- **THE DESCRIBE OF A COMPUTED COLUMN DONE (2026-08-29,
  `serve-real-exprshape` 54):** four wrong-answer classes, all of them
  live and none of them a refusal, in the description a projected
  expression travels under.
  (1) A **computed length** on `SUBSTRING`/`LPAD`/`RPAD` had no static
  width and fell into the catch-all that announces the maximum — and
  `CHARACTER SET NONE` with it, so a UTF8 `straße` shipped one byte per
  character and rendered `stra\xDF`. The engine's fallbacks, probed:
  `SUBSTRING` keeps the SOURCE's own width (it can only shrink its
  source — `FOR 5+0`, `FOR ID` and a computed `FROM` all describe the
  column's own 80 bytes where `FOR 5` describes 20), while a PAD can
  grow past its source and falls back to the widest VARCHAR the charset
  admits: 65533 bytes for NONE/WIN1252, 65532 for UTF8. The cap is on
  the CHARACTER count (`MAX_VARCHAR_BYTES / bytes-per-char`, applied in
  `resolve_text_cs` where the charset is finally known), which is what
  puts the byte width on the engine's multiple.
  (2) A **UNION took the first branch's description** and let the other
  branches ride it: `SELECT CAST(1.50 AS NUMERIC(9,2)) UNION ALL SELECT
  100` answered **1.00**, and the error propagated into `SUM` over the
  union and into the row count of a `UNION DISTINCT`. The engine's rule,
  probed: **the widest branch wins on each axis independently** - type up
  the ladder SHORT < LONG < INT64 < INT128 (`SMALLINT UNION INTEGER` is
  LONG whichever comes first, `NUMERIC(9,2) UNION NUMERIC(30,4)` is
  INT128), scale the widest, and ONE approximate branch makes the whole
  column a DOUBLE whatever the exact branches carried. Every branch's
  value is then converted to that column (`union_coerce_value`).
  (3) The union's **sub_type** is reconciled by a different rule — the
  MAX of the family codes (0 int, 1 NUMERIC, 2 DECIMAL), regardless of
  branch order and independent of whether anything else needed
  reconciling: an INTEGER beside a `NUMERIC(9,0)` agrees on type AND
  scale and still announces sub_type 1.
  (4) Found by the gate written for (3), with no union in sight: **every
  fold dropped its source's family.** `SUM`/`AVG`/`MIN`/`MAX` over a
  NUMERIC answer sub_type 1 and over a DECIMAL 2, grouped or not and
  through a wrapping expression (`SUM(N92*2)` is INT128 scale -2 sub_type
  1); fc announced 0 for all of them. `MIN`/`MAX` keep the source's
  WIDTH too — they select an existing value rather than accumulating one,
  so `MIN` over a `NUMERIC(9,2)` stays a 4-byte LONG where `SUM` widens
  to INT64.
  Also fixed alongside: **`ORDER BY` an output alias that shadows a base
  column** sorted by the table's column instead of the projection.
  THE TRAP, and it is not in the arithmetic: the ANNOUNCED type and the
  WIRE FORM THE ENCODER WRITES are two pieces of state and must move
  together. A first attempt set `sql_type` and `length` and left `wire`
  alone — it answered **6442450944.66** for 1.50, the 4-byte value
  landing in the high half of an 8-byte slot (1.5 × 2^32). The quiet
  version of the same trap: an approximate union announces scale 0, so
  an exact branch that skipped conversion handed the encoder a scaled
  integer it cannot read as a float and the column answered **0.0**.
  `wire`/`sql_type`/`length` are now set in one place ([exact_numeric_form]).
  BOUNDARY (recorded, gated): a number beside TEXT, which the engine
  reconciles by RENDERING the number, refuses — that needs the value
  side to render digit-for-digit as the engine does. The gate asserts
  the engine ANSWERS it, so the boundary cannot rot into a vacuous pass.
  A FIRST, TOO-CONSERVATIVE VERSION of this fix refused every union whose
  branches differed in wire type, which broke `SELECT X UNION ALL SELECT
  X+1` — caught by `serve-real-describe` in the sweep, three checks. A
  refusal where the engine answers is a regression, not a safe default;
  the sweep was killed and the ladder implemented rather than shipping
  it.
  The gate also stopped being flaky the honest way: its `CREATE DATABASE`
  raced with the previous run's file being closed by the engine, so it
  now DROPs through the engine before unlinking and retries the create —
  an intermittent "FAIL create" is otherwise indistinguishable from a
  real one.

- **PSQL functions run through the BLR executor — the full scalar surface
  DONE (2026-08-23, `serve-real-funcbody` 5):** a plain function's body was
  interpreted by an arithmetic-only path (a `RETURN` could only do
  `+ - * /`); now it runs through the existing `crates/exe` BLR executor,
  which reads `UPPER`/`LOWER`/`SUBSTRING`/`CAST`/`COALESCE`/`DECODE`/the
  searched `CASE`/a scalar subquery/concatenation/`IF`/`WHILE`. `exe`
  gained `blr_leave` (verb 18: a function's `RETURN` is assign-var0, send
  message 1, then leave the body wrapper) via an `Exec.leaving` unwind, and
  `exe::function_blr` (the mirror of `procedure_blr`, plain functions only).
  `try_function_blr` (the mirror of `try_procedure_blr`) runs it and pulls
  the one output from message 1; a divide-by-zero raises 22012 and a bad
  `CAST` 22018 (before, any function runtime error was a generic refusal).
  Boundaries (recorded): a PACKAGED function's rich body and a function that
  calls another user function (`blr_function2`, no executor support) fall to
  the source path and may refuse; NUMERIC in a function SIGNATURE is a
  separate pre-existing gap (`load_function` refuses it, so such a function
  is `-804` regardless); fc omits the engine's `-At function ... line/col`
  stack frame on a runtime error.

- **CREATE PACKAGE BODY: a member that calls a sibling unqualified DONE
  (2026-08-22, `serve-real-pkgsibling` 8):** inside a package body a bare
  `DBL(...)` names sibling member DBL, compiled to `blr_function2` with THIS
  package - byte-identical to the qualified `PK.DBL(...)` (probed against
  the engine's RDB$FUNCTION_BLR). Before, the standalone per-member compile
  refused the sibling call, so `CREATE PACKAGE BODY` fell through storing a
  NULL body source - which made EVERY function in the package unknown
  (-804) in later queries. Now the body compiles, its BLR is byte-exact,
  and the engine runs fc's stored file for every member (the sibling-caller
  included). The DSQL compiler gained a package context (name + sibling
  FUNCTION signatures); a sibling call binds only to a FUNCTION and only at
  the declared arity, so a wrong-arity call or a bare call to a sibling
  PROCEDURE refuses on both (an adversarial review caught both). Also fixed:
  a packaged function call columns by its BARE member name (DBL, not
  PK.DBL), the engine's describe. Boundary (recorded): fc INTERPRETS bodies
  from source and cannot yet run a user-function call from an interpreted
  body, so a member that calls a sibling, queried through fc's OWN wire,
  refuses (fc stores byte-exact BLR, so the engine runs it) - a broader gap
  that holds for a plain function calling another function too.

- **Statistical aggregates VAR_POP / VAR_SAMP / STDDEV_POP / STDDEV_SAMP
  DONE (2026-08-22, `serve-real-statagg` 4):** a DOUBLE fold over the
  non-null values, the naive sum-of-squares the engine uses
  (`Sxx - Sx*Sx/n` over n or n-1, folded in f64) so the DOUBLE bits match
  byte-for-byte over INTEGER, NUMERIC(9,2) and expression sources,
  whole-table and grouped. Unlike SUM/AVG they are NOT nullable and NEVER
  NULL: an empty, single-row or all-NULL group is 0, not NULL (probed
  against FB6 - the describe carries no Nullable flag, like COUNT;
  VAR_SAMP over one row and any fold over none are 0, not a divide by
  zero). New `AggFn` variants computed only in `compute_group`; every
  fast/scalar/subquery path declines to it. Boundaries (recorded, the
  engine answers them, fc refuses cleanly): the OVER (window) form, a
  HAVING comparison, a scalar subquery, DISTINCT - top-level select items
  only for now; and a DOUBLE-column source is moot because fc cannot yet
  INSERT into a DOUBLE column (a separate DML gap). No `VARIANCE`/`STDDEV`
  synonym (FB6 has neither - probed -804).

- **NTILE(n) window function DONE (2026-08-22, `serve-real-ntile` 3):**
  the ordered partition split into n buckets as equally as it divides
  (the first `size % n` buckets get one extra row), each row its 1-based
  bucket - byte-identical to the engine across bucket counts and with
  PARTITION BY, an INT64 named NTILE. Joins the RankFn machinery
  (ROW_NUMBER / RANK / DENSE_RANK). Boundary: an expression bucket count.
  (Probed the same day and left: LIST/GROUP_CONCAT needed a COMPUTED BLOB
  result - since arrived with the LIST slice, though `CAST(x AS BLOB)` still refuses; CORR/regr and
  PERCENTILE_CONT/DISC ordered-set aggregates; NTILE done, LAG/LEAD with
  offset+default already worked.)
- **EXECUTE STATEMENT positional + named parameters DONE (2026-08-22,
  `serve-real-execstmt` 4):** the `(sql) (v1, ...)` head binds its `?`
  placeholders, and the `(a := v, ...)` head its `:name` placeholders, at
  run time - the values evaluated in the frame and substituted as SQL
  literals (a placeholder inside the statement's own string literal left
  alone; a repeated `:name` filled each time), which answers the engine's
  rows for the common types; the BLR is byte-for-byte the engine's.
  Boundary: USING / ON EXTERNAL / AS USER.
- **Dynamic EXECUTE STATEMENT operand DONE (2026-08-22,
  `serve-real-execstmt` 4):** the SQL operand may now be any expression -
  a `||` concatenation of literals and variables, or a bare variable -
  not just a literal. dsql parses it as a Val and each form
  (blr_exec_sql / blr_exec_into / blr_exec_stmt) emits the expression
  byte-for-byte with the engine; the interpreter already rendered the
  operand. Boundary: a parameter head `(sql)(vals)` and the USING / ON
  EXTERNAL / AS USER modifiers are still a later slice.
- **Cross-type procedure inputs DONE (2026-08-22, `serve-real-crosstype`
  3):** the engine's CVT for a procedure argument whose literal type
  differs from the parameter's - a text into an INTEGER (spaces trimmed,
  leftover text a 22018 "conversion error from string"), an integer into
  a text parameter (rendered decimal, then the width/CHAR-padding, an
  over-long value a 22018 too). One place, bind_proc_args, so every call
  path (EXECUTE PROCEDURE, a selectable FROM, the BLR fast path) converts
  the same. fc's proc parameters are only INTEGER/TEXT, so those are the
  pairs.
- **Row-locking / optimizer clauses DONE (2026-08-22, `serve-real-rowlock`
  5):** `FOR UPDATE [OF ...]`, `WITH LOCK [SKIP LOCKED]` and `OPTIMIZE FOR
  ...` are stripped before planning - this single-snapshot server does not
  act on them and their rows are the plain query's. FOR UPDATE / OPTIMIZE
  are lenient (taken over a view, CTE, join or aggregate); WITH LOCK is
  valid only over a single physical table with no aggregate (the engine's
  -104 otherwise), so fc leaves it in - and thus refuses - in every other
  shape rather than answer a row the engine never returns. (An explicit
  `PLAN (...)` is still refused: an invalid plan is an engine error, so it
  cannot be blindly stripped.)
- **Selectable EXECUTE BLOCK RETURNS DONE (2026-08-22,
  `serve-real-execblock` 5):** `EXECUTE BLOCK RETURNS (...) AS ... SUSPEND
  ... END` runs as a statement whose SUSPENDed rows are the result set -
  an anonymous selectable procedure. The output metadata is recovered by
  compiling a synthesized `CREATE PROCEDURE` (which also validates the
  body); the body is interpreted by the same run_body_source plain
  EXECUTE BLOCK uses, and the rows are served through Plan::ProcRows. The
  columns describe with an empty table/owner, the engine's shape, and an
  in-body error carries `At block line: L, col: C`. Boundary: input
  parameters (a client message) are not taken; a block naming an
  unresolvable object (an undefined EXCEPTION) refuses on both.
- **PSQL loop control CONTINUE / bare LEAVE DONE (2026-08-22,
  `serve-real-loopctl` 7):** `CONTINUE` (next iteration) and bare `LEAVE`
  (end the innermost loop) now COMPILE in fc's own dsql - a loop-label
  stack in the body parser gives each a blr_leave / blr_continue_loop
  (197) over the enclosing loop's label, byte-for-byte with the engine
  (pin test QW_LC) - and the interpreter runs them (every WHILE / FOR
  SELECT / FOR EXECUTE loop catches PsqlStop::Continue). Works in WHILE,
  FOR SELECT and nested loops; the engine runs the BLR fc stored. Before,
  fc could interpret a bare LEAVE it read from an engine-built procedure
  but its compiler refused both. LABELLED `LEAVE lbl` / `CONTINUE lbl`
  followed (same day): a `<name>:` prefix names a loop, an OUTER one
  included, resolved to that loop's label number - byte-for-byte with the
  engine (pin TOL), and the interpreter propagates a labelled jump to the
  matching loop. Boundary: CONTINUE/LEAVE outside every loop refuse.
- **SQL-standard OFFSET / FETCH DONE (2026-08-22, `serve-real-offsetfetch`
  16):** `OFFSET <n> ROW|ROWS` and `FETCH {FIRST|NEXT} [<n>] ROW|ROWS
  ONLY`, alone or combined (OFFSET then FETCH -> skip then take), beside
  the native FIRST/SKIP/`ROWS n [TO m]`. Parsed in `strip_modifiers` as a
  trailing clause, mapping to the same skip/take as the native forms;
  literal counts only (like FIRST/SKIP). The native `ROWS n [TO m]` scan
  is skipped when OFFSET/FETCH is present, since `FETCH NEXT 2 ROWS ONLY`
  contains the word ROWS. Composes with DISTINCT and inside a derived
  table. `WITH TIES` and `... PERCENT` are not this engine's syntax (both
  -104) and stay refused.
- **Dead-code cleanup DONE (2026-08-21):** `Database::image_undo` /
  `ddl_undo` were never set once DDL became the transaction's, so
  `restore_db`, the image branch of `undo_window` / `rollback_now`
  (`TxEnd::RolledBackImage`), `snapshot_db`, the per-transaction and
  per-savepoint image snapshots, `UndoWindow::base`, and the autonomous
  block's page carve-out (`auto_pages` — an O(file) page compare on every
  autonomous commit, read by nobody) are gone. Every undo is by
  transaction state; the write side is released between requests
  unconditionally. The gates that pinned the image path pin the state
  path now (`serve-real-autonomous` counts commits, not carve-outs).
- **Merge join — a non-gap, recorded (2026-08-21):** the engine plans
  one only when a to-be-hashed river exceeds `HashJoin::maxCapacity()`
  AND the join is INNER (Optimizer.cpp `useMergeJoin = hashOverflow &&
  INNER`; "MERGE JOIN does not support other join types yet"); fc's
  hash build side spills to a `RowStore` past its budget instead, so the
  overflow case is answered without a second join algorithm.
- **RIGHT/FULL side in a `RowStore` DONE (2026-08-21):** the join
  cursor streams the preserved side into a `RowStore` (RAM to the sort
  budget, an unlinked file past it), hashed by row index on the way;
  the mirror's bitmap and candidates address rows by index through
  their offsets (`serve-real-joinorder` 15 pins a spill at a 64 KB
  budget). The materialising paths (`join_step`, the `for_each` arm)
  still hold the side as a `Vec` — they materialise everything anyway.
- **`op_fetch_scroll` DONE (2026-08-21, `serve-real-scroll` 49):** a
  statement executed with `CURSOR_TYPE_SCROLLABLE` buffers its result at
  the first fetch (the engine's BufferedStream) and answers NEXT / PRIOR
  / FIRST / LAST / ABSOLUTE / RELATIVE with Cursor.cpp's rules (BOS / EOS
  parking, absolute from either end, relative 0 re-reads); NEXT/PRIOR
  deliver the client's batch, the positioned ops one row; a scroll op on
  a plain cursor answers `isc_invalid_fetch_option` naming the option.
  The client is `qa/c/scroll.cpp` over the OO API (its own prefetch and
  relative re-positioning included). `blr_scrollable` in `dsql` was
  already there.
- **The batch API DONE (2026-08-21, `serve-real-batch` 22):**
  `op_batch_create` / `msg` / `exec` / `rls` / `cancel` / `sync` — a
  prepared DML statement's input messages queued (each in op_execute's
  packed message form) and run in one round trip through the ordinary
  DML path (one statement undo per message); the completion state
  (`op_batch_cs`) carries a count per message under `TAG_RECORD_COUNTS`,
  `EXECUTE_FAILED` and the failure's vector up to `TAG_DETAILED_ERRORS`
  (64), and the run stops at the first failure unless `TAG_MULTIERROR`.
  Laws probed: the parameters block is WIDE-tagged (u32 lengths); a
  second `createBatch` supersedes the open one. Client `qa/c/batch.cpp`
  (OO API). Blobs inside a batch and `op_info_batch` followed the same
  day (below).
- **Blob parameters in UPDATE … SET DONE (2026-08-21,
  `serve-real-blobupdate` 64, client `qa/c/blobupdate.c`):** a blr_quad
  parameter at an UPDATE's SET (and UPDATE OR INSERT's update half) goes
  through `store_blob_param`, blb::move's three cases probed live: a
  TEMPORARY id is materialised into the relation (the first matched row;
  every further row gets a COPY — no two records share a blob), the
  ALL-ZERO quad stores an EMPTY blob (not NULL — INSERT too, probed), a
  PERMANENT id is COPIED with the target column's sub_type/charset unless
  it is the row's own id echoed back (kept, blb.cpp:1059). A stale temp
  id (its transaction ended) is `invalid BLOB ID`. Also in:
  `OCTET_LENGTH` over a BLOB column (BIGINT, from the stored header),
  `UPDATE OR INSERT` with parameters (the update half's slot map), a
  per-statement reset of materialised temp ids on failure. Before this,
  an UPDATE with a blob parameter was silently wrong (the raw temp id
  landed in the record). Boundaries: MERGE's UPDATE branch with a blob
  source value; `SET blob = <expression>`; `OCTET_LENGTH` of the blob
  inside the writing statement's RETURNING; a blob id bound to a
  non-BLOB column refuses (the engine converts).
- **Blobs inside a batch DONE (2026-08-21, `serve-real-batchblob` 52,
  client `qa/c/batchblob.cpp`):** `op_batch_blob_stream` decoded as a
  per-statement state machine mirroring protocol.cpp `xdr_blob_stream`
  (the 16-byte header as xdr_quad + two big-endian u32s, a header that
  would straddle packets held back and counted in the next packet's
  length, bpb and data raw, a segment length as a 4-byte xdr_u_short,
  alignment padding never on the wire) into closed temp blobs;
  `op_batch_set_bpb` (the default is STREAM — `initBlobParameters`);
  `op_batch_regblob` (a batch id over an existing blob, which the store
  then copies); `op_info_batch` (blob alignment 4, header 16, buffer
  size — the client asks before its first blob packet). At execute each
  message's blob field is re-spelled as the message comes up; an unknown
  id ends the execute with `isc_dsql_error` / `-104` /
  `isc_batch_blob_id`, the messages before it stored and kept (probed).
  Policies BLOB_ID_ENGINE / BLOB_ID_USER / BLOB_STREAM, appendBlobData,
  per-blob bpb, a 5000-byte blob, all line for line with the engine.
- **`op_ping` / `op_transact` DONE (2026-08-21, `serve-real-transact`
  8, client `qa/c/transact.cpp`):** ping is a bare op answered clean;
  transactRequest compiles the BLR through the SHOW-request parser, runs
  it with message 0 pre-filled from the input (the engine memcpy's it in
  BEFORE the start — a `blr_receive` would stall the request), and
  answers the first message 1 the program sent. Wire quirk recorded: the
  BLR travels TWICE in op_transact (`xdr_trrq_blr` and then the MAP macro
  over the same field). A BLR the parser refuses is `isc_invalid_blr`
  (offset 0 — the parser keeps no offset).
- **The auth tail DONE (2026-08-21, `serve-real-wirecrypt` 15):**
  ChaCha64 / ChaCha / Arc4 on offer (server-generated IVs announced in
  the accept keys as `TAG_PLUGIN_SPECIFIC`; key = SHA-256 of the SRP
  session key; `FC_WIRE_CRYPT` narrows the offer) — a default libfbclient
  now talks ChaCha64 to fire-crab, so every gate runs over it; wire
  COMPRESSION (`pflag_compress` echoed on the accept, one zlib stream
  each way below the encryption: a hand-written inflater for what
  arrives, stored deflate blocks for what leaves; `FC_WIRE_COMPRESS=0`
  declines); Legacy_Auth (the client's DES crypt of the password under
  "9z", checked through the C library's `crypt`; no session key, the wire
  stays clear; a wrong password is `isc_login`). The engine takes neither
  a Legacy_Auth client (its `AuthServer` is Srp256) nor compression (its
  `WireCompression` is off) — those cells are fc-only, recorded.
- **ARRAYS DONE (2026-08-21, `serve-real-arrays` 16, client
  `qa/c/arrays.c`):** `<type> [l:u, …]` at CREATE TABLE (RDB$FIELDS
  RDB$DIMENSIONS + RDB$FIELD_DIMENSIONS rows, the record field
  `dtype_array` 18 = an 8-byte array-blob id, described SQL_ARRAY); the
  array blob as `store_array` writes it (a stream blob: InternalArrayDesc
  16 + 24/dim, then the elements row-major); op_put_slice over a zero id
  makes a temp array the row's store materialises like a temp blob;
  op_get_slice reads the stored blob through the header's strides, the
  slice named by the SDL `gen_sdl` emits (element struct, relation,
  field, a do-loop per dimension, the scalar's variables) and the
  elements xdr'd by type. Laws probed: a temp array cannot be read before
  its row is stored (`invalid BLOB ID`); unset elements of a partial put
  are zero; out-of-bounds subscripts are `isc_ss_out_of_bounds`, a short
  buffer `isc_out_of_bounds`. The engine reads fc's arrays, including a
  table fc's own DDL created. **Recorded boundaries:** element types
  SMALLINT/INTEGER/BIGINT/FLOAT/DOUBLE/DATE/TIME/TIMESTAMP only (text and
  NUMERIC elements refuse; arrays of domains refuse); an SDL whose
  element type differs from the stored one refuses (`isc_invalid_sdl`)
  where the engine converts; ARRAY columns only at CREATE TABLE (ALTER
  ADD refuses); `isc_array_lookup_bounds` (the client's catalog query
  through `system.rdb$sql.parse_unqualified_names`) is outside fc's SQL
  surface — clients must build their descriptors. (All lifted the same
  day — see ARRAY TAILS below.)
- **ARRAY TAILS DONE (2026-08-21, `serve-real-arrays` 34):** CHAR and
  NUMERIC/DECIMAL elements (the catalog rows carry the scale; an SDL
  `blr_text` element carries its length word); element CONVERSION on
  get and put (`convert_element`: scaled ints, float/double, rounding
  half away from zero; an element the SDL type cannot hold is the
  engine's `isc_arith_except`); `ALTER TABLE … ADD <type> [l:u]` writes
  the RDB$FIELD_DIMENSIONS rows, and an UPDATE now re-lays a record
  stored in an OLDER format into the newest one instead of refusing
  (`upgrade_image`, field by field by id — the first ALTER ADD + UPDATE
  of an old row fc answers); `isc_array_lookup_bounds` runs over the
  wire: `system.rdb$sql.parse_unqualified_names(rdb$get_context(
  'SYSTEM','SEARCH_PATH'))` folds at prepare (`rewrite_system_sql`:
  the SEARCH_PATH / CURRENT_USER / CURRENT_SCHEMA / ENGINE_VERSION
  context to literals, the function to a `UNION ALL` derived table
  of names), and a WINDOW over a derived table / CTE plans
  (`plan_win_item` shared with the Project path; `Plan::Derived`
  folds after the WHERE and before the sort; `OVER ()` with no order
  numbers the scan order and ranks every row 1). The singleton inline
  blob path was already covered by `op_inline_blob` (the remaining
  `OP_SQL_RESPONSE` site is a scalar path with no blob).
- **`op_info_transaction` DONE (2026-08-21, `serve-real-trainfo` 36,
  client `qa/c/trainfo.c`):** every item — `tra_id`, the oldest
  interesting / snapshot / active counters (4-byte, obeying id ≥ oat ≥
  ost ≥ oit on both servers), isolation (consistency 1, concurrency 2,
  read committed 3 + the READ CONSISTENCY option 2 for every flavour),
  access (the new `Tpb.read_only`), lock_timeout (−1 wait / 0 no wait /
  N), `fb_info_tra_dbpath` (the attach string, answered FIRST whenever
  asked — probed), `fb_info_tra_snapshot_number` (0 when read committed);
  answers in request order, repeats repeated, an unknown item
  `isc_info_error`, overflow `isc_info_truncated`;
  `isc_tpb_at_snapshot_number` refused with the engine's "base snapshot
  number does not exist".
- **ARRAYS OF DOMAINS DONE (2026-08-21, `serve-real-arrays` 43):**
  `CREATE DOMAIN DA AS INTEGER [1:3]` writes the dimension rows on the
  domain; a column of it is the array (`DomainType.dims`, read back from
  RDB$FIELD_DIMENSIONS); `isc_array_lookup_bounds` resolves through the
  field source. Found on the way: a DOMAIN's NOT NULL was never enforced
  at INSERT (fc read only RDB$RELATION_FIELDS.RDB$NULL_FLAG; the engine
  keeps a domain's on RDB$FIELDS) — `not_null_fids` now follows the
  field source.
- **BLOB COLUMNS + BLOB FILTERS DONE (2026-08-21, `serve-real-blobfilter`
  95, client `qa/c/blobcol.c` printing status vectors raw):**
  until this slice fc's OWN DDL had no BLOB type at all (every blob table
  in the gates was an engine-built fixture) and no literal could land in
  a blob column. Now `BLOB [SUB_TYPE {n|TEXT|BINARY}] [SEGMENT SIZE n]
  [CHARACTER SET cs]` (type 261, SEGMENT_LENGTH 80 unless declared, the
  text blob's charset — also what DESCRIBE announces in sqlscale);
  string (sub_type 1) and `_octets` (sub_type 0) literals stored as blobs
  at INSERT and UPDATE (`store_blob_literal`; an UPDATE matching no row
  stores and raises nothing); the engine's filter law (`isc_nofilter
  from, to`: TEXT into a user sub_type refuses, binary lands anywhere; a
  bpb on open needs no filter for same/same, to binary, or binary to
  text); `DECLARE FILTER` / `DROP FILTER` (RDB$FILTERS row + security
  class) with the engine's vectors — duplicate name, duplicate
  (input, output) pair = the unique violation on RDB$INDEX_17, missing
  name; `BLOB SUB_TYPE 2` refused at CREATE TABLE with the nested −204
  vector; `IS [NOT] NULL` over a BLOB/ARRAY column. General fixes found
  on the way: DESCRIBE never announced NOT NULL (every column was 497 —
  now a plain base column reads its flag: 496); a blob's negative
  sub_type went through the text-charset convention (−5 described as
  charset 3, length 24, and the row message was 24 bytes wide).
  **Recorded boundaries:** CAST(<blob> AS VARCHAR) is outside the
  expression engine; the internal system-sub_type filters (BLR/ACL/… →
  text) are not mirrored; a text-blob DOMAIN's charset does not reach the
  descriptor; NOT NULL through expressions / join sides still describes
  nullable.
- **CAST(<blob> AS …) DONE (2026-08-21, `serve-real-blobcast` 21):** the
  evaluator carries no database, so the connection loop arms a per-op
  image (`BLOB_CTX`, an Arc clone) and `Expr::BlobText(fid)` —
  produced when a CAST's operand is a plain BLOB column — materialises
  the blob at evaluation: text and binary blobs cast to their bytes, the
  text truncation vector when they do not fit, `isc_nofilter(st, 1)` for
  a user sub_type, a numeric target converts the text; works in WHERE /
  UPPER / LIKE / `||` / ORDER BY, and `expr_reads` decodes the blob
  column only when read. **Boundaries:** `<blob> || 'x'` (a BLOB
  result), CHAR_LENGTH(<blob>) and `WHERE <blob> = 'x'` without a CAST
  stay refused; a temp blob of the running transaction is not readable
  by an expression; CAST(x AS CHAR(n)) describes 448 on fc for ANY
  operand (the engine 452) — the fixed-text wire form is its own slice.
- **NOT NULL IN DESCRIBE DONE (2026-08-21, `serve-real-notnulldesc`
  27):** the nullable bit now travels the engine's way (probed):
  `expr_nullable` — an expression is nullable only when an input is
  (arithmetic, negation, CAST, `||`, the string/date functions, CASE/IIF
  by their branches); COALESCE, NULLIF, a boolean, a parameter, a
  subquery and NULL always; `mark_not_null_join` — INNER keeps both
  sides, LEFT/FULL null the right side, RIGHT/FULL everything before;
  a GROUP BY key keeps its column's bit; a derived table / CTE copies
  the inner's; a UNION is nullable when any branch is. Unknown shapes
  stay nullable (the bit is only ever cleared when certain).
  **Boundary found:** `CURRENT_TIMESTAMP` in a select list refuses
  (`CURRENT_DATE` answers).
- **CURRENT_TIME / CURRENT_TIMESTAMP DONE (2026-08-21,
  `serve-real-currenttime` 8):** TIME / TIMESTAMP WITH TIME ZONE
  (32756/8, 32754/12) in the session zone (the server's OS zone —
  `/etc/timezone`, `TZ` — through `tz::zone_id`), optional precision
  (`CURRENT_TIME` defaults to 0 fractional digits, `CURRENT_TIMESTAMP`
  to 3, probed), never nullable; `TKind::TimeTz/TimestampTz`,
  `Expr::TimeTzLit/TsTzLit`. Also `mark_not_null_cols` no longer skips
  a table without NOT NULL columns (a literal over RDB$DATABASE is
  not-nullable too).
- **INTEGER WIDTHS DONE (2026-08-21, `serve-real-intwidth` 7):**
  `result_width_bytes` now follows the engine — an integer literal is
  LONG when it fits 32 bits (BIGINT beyond), negation keeps, CASE / IIF /
  COALESCE take their widest branch, NULLIF its FIRST argument's type
  (probed); arithmetic stays BIGINT. The wire form follows the describe.
- **CHAR TRAVELS AS CHAR (2026-08-21, `serve-real-charform` 8,
  `serve-real-charset` 43):** until this slice every CHAR column and every
  fixed-text expression described as VARYING (448) — a client saw
  CHAR(5) as VARCHAR(5). Now `Wire::Text`: a CHAR column, a text
  literal, CAST AS CHAR, UPPER/LOWER of a CHAR, CASE/COALESCE/IIF of
  CHARs describe 452 at the engine's width (a UTF8 CHAR(3) is 12
  bytes); TRIM, `||`, SUBSTRING and VARCHAR stay 448 (`text_form`
  already knew — the flag was dropped at the describe). The row carries
  the FORM THE CLIENT DECLARED in its blr (`OutSlot.fixed`, at the
  client's declared byte length — the engine serves a CHAR fetched as
  VARCHAR and back); a fixed slot is space-padded, no length word. Input
  binds keep the even form by design (see `nullable`).
- **RDB$SET_CONTEXT / RDB$GET_CONTEXT DONE (2026-08-21,
  `serve-real-context` 61):** the attachment's USER_SESSION /
  USER_TRANSACTION variables (a thread-local per connection; the
  transaction map empties at COMMIT / ROLLBACK, not RETAINING);
  SET_CONTEXT answers 0 new / 1 existed, a NULL value deletes;
  GET_CONTEXT is VARCHAR(255) nullable, NULL for an unknown name; SYSTEM
  answers the session's facts at evaluation (and is read-only); any other
  namespace is `isc_ctx_namespace_invalid`; the select list evaluates
  RIGHT-TO-LEFT when a SET_CONTEXT is in it (probed — `SET(K, v),
  GET(K)` reads the old value). Until this slice fc folded every
  non-SYSTEM GET_CONTEXT to NULL at prepare — a silent wrong answer.
  `rewrite_system_sql` now folds only inside `PARSE_UNQUALIFIED_NAMES(`.
  Boundary: the functions inside a PSQL body (the dsql crate) are not
  this slice.
- **DESCRIBE IN THE ATTACHMENT CHARSET (2026-08-21, found by
  `serve-real-outblr` 32 through node-firebird 2.11):** a plain column of
  a REAL charset (anything but NONE / OCTETS — ASCII included) is
  described in the ATTACHMENT's charset at chars × its bytes per char
  (WIN1252 CHAR(5) under UTF8 is len 20 charset 4; a UTF8 CHAR(3) under
  WIN1252 is 3 charset 53; NONE keeps its bytes — probed with `isql -ch`).
  fc always announced the column's own charset; VARCHAR hid it (clients
  read the counted length), CHAR exposed it (2.11 derives the char count
  from the declared width). `resolve_text_cs` now carries the rule.
- **CREATE / DROP VIEW DONE (2026-08-21, `serve-real-createview` 4 — the
  ENGINE opens fc's file and runs fc's BLR):** `CREATE VIEW <name>
  [(cols)] AS <select>` plans the SELECT at prepare: a plain column
  reuses its base relation's RDB$FIELD_SOURCE with RDB$BASE_FIELD and
  RDB$VIEW_CONTEXT; an expression column gets an auto-domain RDB$<n> of
  its type (precision by storage width) carrying the expression's BLR
  over the VIEW's streams in RDB$COMPUTED_BLR (no source — probed;
  `dsql::compile_view_columns`); the FROM items are the contexts (1.. in
  order, the alias quoted or `"PUBLIC"."T"`); `RDB$VIEW_BLR` is the dsql
  crate's RSE (its select-list scanner now skips expression items,
  aggregates still refuse); dbkey 8 bytes per context, a security class
  and a default class written on the row at INSERT (a later patch of a
  full system page has no room for a new version — measured on the fifth
  view of one transaction); `DROP VIEW` removes the relation, its fields,
  its own auto-domains, view relations, formats, class and privileges,
  with the engine's vectors (duplicate name, missing / not-a-view: the
  nested −607 with the VIEW verbs). **Boundaries:** WITH CHECK OPTION,
  UNION views, derived tables / CTEs in the FROM, an expression outside
  the dsql crate's surface, `ALTER VIEW`.
- **ALTER / DROP TRIGGER, CREATE OR ALTER TRIGGER / PROCEDURE, ALTER
  PROCEDURE DONE (2026-08-21, `serve-real-altertrigger` 3):** `ALTER
  TRIGGER` edits the active flag / position in place, or redefines (an
  event clause or a body — through the CREATE planner over the stored
  relation, unspoken attributes kept); `CREATE OR ALTER TRIGGER` keeps an
  existing trigger's sequence and flag unless the statement says
  (probed); `DROP TRIGGER` removes the row and its dependency rows;
  `ALTER PROCEDURE` / `CREATE OR ALTER PROCEDURE` replace the row keeping
  `RDB$PROCEDURE_ID` (`create_procedure_with_id`); the engine's
  missing-object vectors (336397271/273/266 + 336068755/748), the name
  checked before the body. `UserTriggerDef.inactive`.
- **BLOB IDS ON THE WIRE ARE xdr_quad (2026-08-21):** every quad crossing
  the wire (rows, inline blobs, op_create_blob's answer, parameters,
  op_open_blob / slices, batch regblob and the batch blob stream's
  headers) now carries the ISC_QUAD's two memory words big-endian; fc
  sent and read the file's little-endian bytes, which every echoing
  client round-tripped and isql rendered as `c000000:a000000` for the
  engine's `c:1e6`. All nine blob/array/batch gates green after the
  switch.
- **NEXT**: the tail of the auth/restore-only DDL — `CREATE USER` (the
  security database's PLG$SRP, not this catalog); `CREATE SHADOW` (a
  physical shadow file beside its RDB$FILES row); and collation-aware
  ordering (this server keys binary). Both are outside fc's pure-catalog
  model (a separate database / a physical file), so the DDL group is
  effectively complete for the catalog cases.
  (`PACKAGE` headers + BODY DONE 2026-08-22: CREATE/DROP PACKAGE write
  RDB$PACKAGES + declaration members + params, byte-for-byte; a
  `declaration` flag on the procedure/function writers omits the BLR
  columns. CREATE PACKAGE BODY compiles each member's full body (a
  BEGIN/END-depth splitter finds the PROCEDURE/FUNCTION boundaries),
  fills its BLR/TYPE/VALID_BLR keeping the member id and rewriting the
  params over fresh domains, leaves the member SOURCE null, and stamps
  RDB$PACKAGES with the body source + VALID_BODY_FLAG. A second body or a
  body with no header refuses with the engine's vector; the engine runs
  the BLR fc stored. serve-real-package 7. INVOKING packaged routines
  from a query DONE 2026-08-22: a packaged FUNCTION resolves in a select
  list and a selectable PROCEDURE in the FROM clause - bare, `PUBLIC.`-
  and `SCHEMA.`-qualified, over literals / table columns / nested calls -
  with the engine's arity, -804 (unknown function), -204 "Procedure
  unknown" (unknown selectable procedure in a FROM call) and -204 "Table
  unknown" (an unknown relation in the FROM or in any subquery / derived
  table / IN-EXISTS body) vectors;
  load_function became package-aware like load_procedure, and a packaged
  member coexists with a same-named plain routine (function AND procedure).
  serve-real-callpkg 9.) (`MAPPING`
  and `COLLATION` DONE 2026-08-22: CREATE/ALTER/DROP MAPPING →
  RDB$AUTH_MAPPING and CREATE/DROP COLLATION → RDB$COLLATIONS, both
  byte-for-byte with the engine's catalog and vectors — serve-real-mapping
  5, serve-real-collation 5. The collation SPEC's ICU version is copied
  from the base collation; ids count down from 126 per charset. GLOBAL
  mapping and FROM EXTERNAL collation refuse.) (`DROP TABLE` dependency
  enforcement is now complete for the common cases: views, procedures, and
  FK/PK back-references all block with the engine's exact vector and count.
  serve-real-dropdeps 7 — FK/PK is checked first and wins over a view; the
  count is views-else-procedures. One boundary remains: a table referenced
  ONLY by a trigger on another table, which is DFW-internal category
  precedence.) The common `CREATE TABLE` column types are now all in: BLOB,
  NUMERIC, DECFLOAT, `TIME/TIMESTAMP WITH TIME ZONE`, `CHARACTER SET` /
  NCHAR / `COLLATE`, and arrays (single- and multi-dimension; the multi-dim
  fix was a `[]`-aware column-list splitter — serve-real-arrays 46, which
  now round-trips a 2-D array through fc's own CREATE TABLE). (Non-default `COLLATE`
  DONE 2026-08-21 for the built-in UTF8 family: the collation rides the
  ttype high byte, RDB$COLLATION_ID written on both the field and
  relation-field rows; serve-real-charsetddl grew two COLLATE columns.
  Boundaries: a language collation needs the full RDB$COLLATIONS lookup,
  and collation-aware ORDER BY / index keys stay binary — later slices.) (`DROP TABLE`
  view-dependency enforcement DONE 2026-08-21: a view over a table blocks
  its DROP with the engine's "there are N dependencies" vector, N = distinct
  dependent views from RDB$VIEW_RELATIONS — which is exactly the engine's
  count whenever any view exists. The engine defers to COMMIT and fc refuses
  at execute, but isql auto-commits so they read identically.
  serve-real-dropdeps 5. Boundaries: procedure-only and FK/PK-parent drops
  are refused by the engine, dropped by fc.) (`CREATE TABLE` `CHARACTER SET` / NCHAR
  columns DONE 2026-08-21, single-byte and multibyte UTF8: catalog +
  describe + record layout matched, a UTF8 value inserted through fc stores
  at the right width and the engine reads it back; serve-real-charsetddl 7.
  The descriptor sub_type is the ttype the read path already keys on, the
  catalog RDB$FIELD_SUB_TYPE a separate 0.) (`CREATE TABLE` with DECFLOAT / DECFLOAT(16|34) and
  `TIME/TIMESTAMP WITH TIME ZONE` DONE 2026-08-21: catalog + describe +
  record layout matched, the engine writes tz values into fc's own table
  and both read them back; serve-real-coltypes 7. BLOB, NUMERIC, BOOLEAN,
  INT128 were already in. Separate value-parser gaps left: a WITH TIME
  ZONE literal and a scientific `1E10` DECFLOAT literal in an INSERT.)
  (`RECREATE` DONE 2026-08-21: `RECREATE TABLE/VIEW/PROCEDURE/EXCEPTION/
  SEQUENCE/FUNCTION` = drop-if-exists then create, the CREATE planned at
  prepare so a bad definition preserves the old object; `Plan::Recreate(Box<Plan>)`,
  `plan_recreate` rewrites to CREATE and wraps, exec drops-then-creates.
  serve-real-recreate 5 checks. `ALTER VIEW` DONE 2026-08-21: replaces a
  view keeping its relation id — ods `alter_view` drops and repopulates with
  a `forced_id`; missing-view vector matched. serve-real-alterview 5 checks.
  Boundary carried by both: this server's DROP TABLE does not enforce
  dependencies.) (`CREATE FUNCTION`
  DONE 2026-08-21: CREATE/DROP FUNCTION write the catalog and BLR, and a
  PSQL function is CALLED from a select list — `F(<expr>)` resolves only
  against the catalog, describes as the RETURN domain, and evaluates per
  row by materialising the statement's rows at the first fetch, each call
  run through `run_function`. `RETURN <text>` is a new `TrigStmt::ReturnText`;
  an unknown `NAME(` is -804, the wrong arity `fun_param_mismatch`. Gate
  serve-real-createfunction, 7 checks. Boundary: a long blob-returning
  session under wire encryption accumulates op_inline_blob packets past
  the client's cache — pre-existing, unrelated to functions — so the gate
  checks the catalog query by query in fresh attachments. A distinct
  per-transaction handle scheme (the engine's model, which would let one
  session carry the catalog blobs beside the calls) was tried and reverted:
  it fixed that case but desynced the SQLDA_DISPLAY request path under
  crypt; deferred.) Full sweep 2026-08-21 after the UPDATE-format change:
  259 gates, 8246 checks, 0 DIFF. MERGE `RETURNING` / `NOT MATCHED BY
  SOURCE`, `op_info_blob` / `op_seek_blob`, the ordered JOIN fetch
  streaming, the RIGHT/FULL hash, the bulk index build, the cleanup — all
  done 2026-08-21.
- **D, the MERGE executor** — the BLR is already compiled and tested;
  only the executor is missing.
- **G, the external sort** — every sort and hash build is bounded by
  RAM today; after the growth walls this is the next scalability
  ceiling a real database reaches.

## A RECORD IS PRESENTED THROUGH THE FORMAT THAT DESCRIBES IT NOW (2026-09-03) - decoding under the right format and rendering under the wrong scale is half a law

**`ALTER TABLE T ALTER c TYPE <scaled>` mints a format and rewrites NOT
ONE ROW, so every row written before it read back off by the scale
factor.** The stored data was right; the wire projection was not.

```sql
CREATE TABLE M6 (ID INTEGER, N INTEGER);
INSERT INTO M6 VALUES (1,700);  INSERT INTO M6 VALUES (2,7);   COMMIT;
ALTER TABLE M6 ALTER N TYPE NUMERIC(9,2);                      COMMIT;
INSERT INTO M6 VALUES (3,7.00); INSERT INTO M6 VALUES (4,700.00);
```

| `SELECT ID, N FROM M6 ORDER BY ID` | engine | before | after |
|---|---|---|---|
| 1 (written BEFORE the ALTER) | `700.00` | `7.00` | **`700.00`** |
| 2 (written BEFORE the ALTER) | `7.00` | `0.07` | **`7.00`** |
| 3 (written after) | `7.00` | `7.00` | `7.00` |
| 4 (written after) | `700.00` | `700.00` | `700.00` |

An exact numeric is stored as a MANTISSA and its DESCRIPTOR carries the
scale, so `700` under `INTEGER` and `70000` under `NUMERIC(9,2)` are the
same number. The wire ships the raw mantissa and the client divides by
`10^|scale|` from the describe, so handing a reader the old mantissa
under the new descriptor divides by 100 instead of converting.

**The engine does both halves.** It reads each field through the
record's OWN format and `MOV_move`s it into the format the request was
compiled against (jrd/vio.cpp). This server did the first half already -
that is the `qa/serve-real-stalefmt.sh` law - and not the second.

### What it cost beyond the digits: ROWS

With the mixed-numeric comparison arm in place (the entry below),
`GROUP BY` and `SELECT DISTINCT` correctly collapse an old-format row
with a new-format one, and then project the group's representative,
which is the FIRST row seen - the old-format one. So the engine's row
left the answer entirely:

```
SELECT DISTINCT N FROM M6 ORDER BY 1
  engine:  7.00; 700.00
  before:  0.07; 7.00        <- 700.00 is GONE
  after:   7.00; 700.00

SELECT N, COUNT(*) FROM M6 GROUP BY N ORDER BY 1
  engine:  7.00|2; 700.00|2
  before:  0.07|2; 7.00|2    <- both keys wrong, the 700.00 group gone
  after:   7.00|2; 700.00|2
```

### The fix, and where it sits

`present_field` / `present_through` (`crates/wire/src/server.rs`)
convert a decoded value into the descriptor the relation carries NOW,
and they are called from the TWO places every read walk passes through:
`ReadView::values` (the materialising scan, the streaming cursor, the
index-driven retrieval and the by-recno fetch all call it) and
`decode_stored` (the DML walks). The MERGE identity builder, which
decodes a target row under its own format to write key literals, calls
it too.

`relay_image` (`crates/ods/src/format.rs`) is the same law for the
LOGICAL BACKUP, which reads BYTES rather than values: it re-lays a
record stored under an older format into the newest one before the XDR
encoder reads it, and answers `None` - refusing the backup - for a shape
it cannot carry rather than writing a wrong number.

### The rounding rule, measured rather than chosen

The narrowing direction is reachable. The engine accepts an ALTER that
keeps the integral digits and DROPS decimals - `NUMERIC(9,2)` ->
`NUMERIC(18,1)`, `-> INTEGER` and `-> BIGINT` are all accepted; it
refuses `NUMERIC(9,2)` -> `NUMERIC(9,4)` with *"New scale specified for
column N must be at most 2"*, and `NUMERIC(18,2)` -> `DOUBLE PRECISION`
with *"Conversion from base type BIGINT to DOUBLE PRECISION is not
supported"*. Reading the old rows back through the narrower column, the
engine ROUNDS HALF AWAY FROM ZERO:

| stored | `-> INTEGER` | | stored | `-> NUMERIC(18,1)` |
|---|---|---|---|---|
| `7.55` | `8` | | `7.55` | `7.6` |
| `7.45` | `7` | | `7.45` | `7.5` |
| `7.50` | `8` | | `7.05` | `7.1` |
| `8.50` | `9` (banker's would say 8) | | `-7.55` | `-7.6` |
| `-7.55` | `-8` | | `-7.45` | `-7.5` |
| `-7.50` | `-8` | | `-7.05` | `-7.1` |
| `-0.51` | `-1` | | | |
| `0.49` | `0` | | | |

fire-crab now answers every one of those.

### At the extremes - and the claim here that was FALSE

A conversion whose result does not fit the target's backing width is
DECLINED: `present_field` answers `None` and the value is left exactly
as decoded - not saturated, not zeroed, and no panic. `relay_image` does
the same and refuses the backup rather than writing the number. It is
asserted directly in the unit tests (`i64::MAX` at scale 0 into scale
-2, `i128::MAX` into scale -4).

**This paragraph used to end "It is a floor, not a path" - no
engine-accepted ALTER was found that reaches it. That is FALSE**, broken
by a reviewer and re-measured here on 2026-09-03. The engine will not
let the declared INTEGRAL DIGITS grow, but it will let the PRECISION
grow, and the precision is what decides whether the rescaled mantissa
still fits:

```
CREATE TABLE OV (ID INTEGER, N BIGINT);
INSERT INTO OV VALUES (1, 900000000000000000);  INSERT INTO OV VALUES (2, 7);
ALTER TABLE OV ALTER N TYPE NUMERIC(18,4);   -- the engine ACCEPTS this
INSERT INTO OV VALUES (3, 1.5);

SELECT ID, N FROM OV ORDER BY ID
  fire-crab: ID 1|N 90000000000000.0000  ID 2|N 7.0000  ID 3|N 1.5000
  engine   : SQLSTATE = 22003, arithmetic exception, numeric overflow,
             or string truncation / -numeric value is out of range
SELECT SUM(N) FROM OV        fire-crab: 90000000000008.5000   engine: 22003
SELECT ID FROM OV WHERE N>0  fire-crab: 1, 2, 3               engine: 22003
```

`9e17 x 10^4` does not fit `i64`, `present_field` answers `None`, and
the raw mantissa ships under the new scale - silently off by `10^4`, and
folded into `SUM` and `WHERE`. There are THREE answers here, not two -
convert, decline, or RAISE - and the engine takes the third. NOT FIXED
this round: it is entry F2 of "RECORDED, NOT REPAIRED" below, and the
unit test that pins the floor asserts the current behaviour, not the
engine's.

### Every path that renders a decoded value against a column descriptor

Measured on `qa/serve-real-scalefmt.sh`'s fixtures against a binary with
only this fix reverted (**rc=1, 25 OK / 32 DIFF** there; **rc=0, 57 OK /
0 DIFF** here). Both counts were taken while the gate carried 57 checks;
section H gained a range probe later on 2026-09-03 and the gate is 59
now, so the two comparisons are 57-check numbers and are not re-taken.

| path | verdict |
|---|---|
| SELECT projection (materialising scan, streaming cursor) | WAS WRONG, fixed |
| `GROUP BY`, `SELECT DISTINCT` (missing rows) | WAS WRONG, fixed |
| aggregates - `SUM`, `MIN`, `MAX`, `AVG`, `PERCENTILE_DISC` | WAS WRONG, fixed |
| windows - `RANK`, `DENSE_RANK`, `LAG`, `COUNT OVER`, `SUM OVER` | WAS WRONG, fixed |
| materialised sort keys (`ORDER BY`, both directions) | WAS WRONG, fixed |
| index-driven reads (the retrieval's fetch) | WAS WRONG, fixed |
| `CAST` of the column to text | WAS WRONG, fixed |
| the DML walk's own row (`UPDATE`/`DELETE` `WHERE`, `SET`) | WAS WRONG, fixed |
| a MERGE target's key literals | WAS WRONG, fixed |
| the LOGICAL BACKUP's bytes | WAS WRONG, fixed (see below) |
| `LIST` per group | content was already the engine's; blob id renders differently (pre-existing, pinned) |
| `RETURNING OLD` / `NEW` | already right - `upgrade_image` re-lays the row first |
| an AFTER DELETE trigger's `OLD` | already right, measured |
| arithmetic over the column (`N + 1`, `N * 2`) | already right - the expression path aligns operands by the DESCRIPTOR's scale, which is exactly the conversion the projection was missing |
| `INSERT ... SELECT` into a scaled target | already right - the store coerces |
| `WHERE` against a literal (`N = 7`, `N = 700.00`) | already right - `num_cmp` aligned |
| an INDEX that PREDATES the ALTER | STILL WRONG - the key encoding, not the projection; see the bullet above |
| the `.fbk`'s COLUMN DEFINITION | STILL WRONG - see below |

### The logical backup: what was fixed, and what was found and NOT fixed

**Fixed.** The backup read every record's bytes at the CURRENT format's
offsets. Measured 2026-09-03 - `INTEGER` rows `700` and `7`, then
`ALTER ... TYPE BIGINT`, then two more rows; fire-crab's own backup
restored by the REAL `gbak -c` and read back BY THE ENGINE:

```
before:  ID 1|N 0   ID 2|N 0   ID 3|N 7   ID 4|N 700
after:   ID 1|N 700 ID 2|N 7   ID 3|N 7   ID 4|N 700   <- the engine's own answer
```

**A NEW REFUSAL, deliberately.** `relay_image` answers `None` - which
refuses the WHOLE backup, the same fail-closed law the rest of this
surface follows - for a field the old format never had (its value lives
in the newest format's stored DEFAULT section, which it does not read)
and for a type change outside the exact-numeric family. What that
replaces is worse than a refusal. Measured 2026-09-03, `ALTER TABLE AC
ADD DFT INTEGER DEFAULT 99 NOT NULL` over a populated table:

```
before:  the backup SUCCEEDS, and the real `gbak -c` then answers, per
         pre-ALTER row,
           gbak: ERROR:validation error for column "PUBLIC"."AC"."DFT",
                 value "*** null ***"
           gbak: ERROR:warning -- record could not be restored
         The restored database is SHORT TWO ROWS and nothing says so.
after:   the backup REFUSES ("feature is not supported", the wish-list
         answer every unsupported shape on this surface gives).
the engine's own backup of the same file:  all three rows, with the
         format's stored `99` in the added column.
```

Carrying that case rather than refusing it means reading the format's
DEFAULT section and encoding those values at the new descriptors - a
feature, not a fix, and not attempted here. No gate in `qa/` backs up a
table with an added column either.

**Found here, NOT fixed, HIGH, PRE-EXISTING and independent of any
ALTER: fire-crab's logical backup loses a scaled column's SCALE.** In a
burp field record, **att 9 is `RDB$FIELD_SUB_TYPE` and att 11 is
`RDB$FIELD_SCALE`**; this writer has them swapped, and `read_backup` has
the mirror of the same confusion. Parsed out of the ENGINE's own `.fbk`
for a nine-column table, 2026-09-03:

```
DECIMAL(9,3)        (9,2) (11,-3) (44,9)
NUMERIC(4,1)        (9,1) (11,-1) (44,4)
BLOB SUB_TYPE 1     (9,1) (11,0)
INTEGER/CHAR/VARCHAR(9,0) (11,0) (44,0)
```

The consequence, measured on a table that was **never ALTERed**: a
`NUMERIC(9,2)` holding `700.00` comes back out of a real `gbak -c` as an
INTEGER holding `70000`, and a `DECIMAL(9,3)` holding `4.567` as `4567`.
Not fixed here: writing 9/11/44 correctly needs the NUMERIC-vs-DECIMAL
marker and the declared PRECISION, and the ODS descriptor carries
neither - it is a catalog read this writer does not do, plus the
matching change in `read_backup` and in the restore's column builder. A
half fix (writer only) was built and measured and made the file
disagree with this server's own reader, so it was reverted. **No gate
in `qa/` backs up a scaled column** (`grep -c NUMERIC` over the four
gbak gates: 0, 0, 0, 0), which is why it survived. `qa/serve-real-scalefmt.sh`
section F now pins it, on an ALTERed table AND on one that never was.

### Two boundaries re-confirmed here, recorded and not fixed

- **`gbak -b` through this server refuses any ENGINE-created database**
  with `gbak: ERROR:Dynamic SQL Error`, on a plain single-table file with
  no ALTER and nothing exotic. Re-measured 2026-09-03 on three such
  files; the `.fbk` is never written. It is the CLIENT-side `gbak -b`
  path (the one that compiles BLR requests), not the SERVICE backup that
  the four gbak gates and section F above drive - those work. A reviewer
  recorded it in the previous round as the reason `cmp_value_keys` (the
  raw-BLR request sort) could not be measured directly, and that stands:
  it still cannot be, here.
- **A negative `INT128` rendered by node-firebird is a CLIENT artifact,
  not this server's answer.** It prints `2^128 - |v|`; `isql` reads the
  same value correctly off this server. Recorded so the next reviewer
  does not chase it.

### Why no gate saw any of this

`qa/serve-real-stalefmt.sh` is precisely the gate for old-format rows,
and every `ALTER` in its fixture PRESERVES the scale (`INTEGER` ->
`BIGINT`, `NUMERIC(9,2)` -> `NUMERIC(18,2)`), so the one thing that can
go wrong here cannot happen there. Of the gates that contain an
`ALTER ... TYPE`, none contained a `GROUP BY` or a `DISTINCT`, and none
compared a PROJECTED value of the altered column. `qa/serve-real-scalefmt.sh`
is the gate for that, and its header says so.

### The gate

`qa/serve-real-scalefmt.sh`, 59 checks, rc 0 (57 when the reverted-binary
comparisons below were taken; section H's range probe is the difference).
Sections A (the
projection), B (`DISTINCT`, `GROUP BY`, the aggregates, the windows, the
sort keys, `UNION`, `PERCENTILE_DISC`, `LIST`), C (an index created
AFTER the ALTER), D (the narrowing direction and its rounding), E (the
INT128 backings, `RETURNING`, the SET expression, an AFTER DELETE
trigger's `OLD`, a MERGE key, a self join), F (the logical backup
round trip through the real `gbak -c`, the recorded scale loss, the
ADDED-column refusal, each with the ENGINE's own backup of the same
file beside it), H (an index older than the format the row was written
under - two equality probes and a range probe, both answers pinned) and
G (`LIST`'s blob id, both answers pinned).

**Non-vacuity, measured:** on a binary built from this tree with only
`present_field` and `relay_image` reverted, the gate is **rc=1, 25 OK /
32 DIFF**.

**And the two 2026-09-03 fixes are independent, which changes what each
gate is evidence of.** On a binary that keeps this fix and reverts only
`value_cmp`'s mixed arm, `qa/serve-real-scalefmt.sh` is **57 OK / 0
DIFF** (the 57-check version) - with the projection fixed a stale row
presents at the same
KIND and scale as a fresh one, so no mixed pair reaches `value_cmp`
through the format path at all. The arm's own evidence is the
foreign-key path, where a child column and a parent key are DECLARED at
different scales and nothing converts them: the same arm-reverted binary
runs `qa/serve-real-fkaction.sh` at **rc=1, 189 OK / 20 DIFF**.

## RECORDED, NOT REPAIRED: THE NEXT CHUNK (2026-09-03)

**The projection law - a record is presented through the format that
describes it now - is CONVERTED for the wire read paths and for the
logical backup, and is NOT yet converted for the PSQL execution path,
for the restore reader, or for any type change that is not a change of
scale.** That sentence is the whole of what a future reader needs from
this section: everything below is either that same law on a path the
fix above did not reach, or a neighbouring format defect found on the
way to it, and together they are one coherent next chunk.

**Nothing below is fixed.** Every entry was measured on 2026-09-03
against Firebird 6 at `127.0.0.1/3050`, on a fixture built BY THE ENGINE
and copied byte-identically to both servers, unless the entry says
otherwise. F1 through F7 were found by a reviewer; each was re-run here
before being written down, and where it was not, the entry says so.

### F1 - HIGH, WRONG ANSWER, PRE-EXISTING. A selectable PSQL procedure or function reads every record at the NEWEST format's descriptors

`crates/exe/src/lib.rs:2691` (`scan_relation`, the newest-format pick at
`:2697`) and its index-driven twin `:2557` (`scan_relation_bitmap`,
picks at `:2577`, `:2598`, `:2648`). Entered from
`crates/wire/src/server.rs:79272` (`try_procedure_blr`) and `:79404`
(`try_function_blr`), which run a compiled body through
`fire_crab_exe::bind_and_execute` FIRST and fall back to the source
interpreter only for a body exe cannot carry.

`crates/exe` is a live WIRE path. The report that landed the round above
listed it among "diagnostics and the standalone BLR runner" and said it
was not in the wire path; that was wrong about this crate, and the two
entry points named above are where a client reaches it. It takes one
descriptor list - the newest format's - for records
of every format, and `VisibleRow::format` (the field this chunk ADDED,
whose doc comment says a caller that goes back to `image` must lay its
fields at THAT format's offsets) is never consulted there.

It loses THREE things, and all three were re-measured here. Client and
procedure over the same file, in the same second:

```
JX: (1,700),(2,7) as INTEGER, ALTER N TYPE NUMERIC(9,2), then (3,7.00)
  SELECT N FROM JX ORDER BY ID        crab 700.00, 7.00, 7.00   = engine
  SELECT O FROM PJX  (the procedure)  crab   7.00, 0.07, 7.00
                                      engine 700.00, 7.00, 7.00   <- SCALE

OFS: (11,22) as two INTEGERs, ALTER A TYPE BIGINT, then (33,44)
  SELECT A, B FROM OFS                crab 11|22, 33|44         = engine
  SELECT X, Y FROM POF (the procedure) crab  0|0,  33|44
                                      engine 11|22, 33|44        <- OFFSETS:
    the pre-ALTER image is shorter than the new format's extent and BOTH
    its fields come back 0 - a row silently zeroed, not mis-scaled

ADF: (1,7), ALTER TABLE ADF ADD DFT INTEGER DEFAULT 99 NOT NULL, then (2,8,5)
  SELECT ID, DFT FROM ADF             crab 1|99, 2|5            = engine
  SELECT I, DD FROM PADF (procedure)  crab 1|<null>, 2|5
                                      engine 1|99, 2|5      <- the format's
    DEFAULT SECTION: a NULL in a NOT NULL column

A PSQL FUNCTION is the same path, and it reaches an ordinary select list:
  SELECT FN2(1) A, FN2(2) B FROM RDB$DATABASE
                                      crab A 7.00 | B 0.07
                                      engine A 700.00 | B 7.00
```

**What is NEW is the split, not the defect**: before this chunk the
client SELECT and the procedure were consistently wrong; now the same
query answers `700.00` through a client and `7.00` through a procedure
over the same file. The reviewer measured every row above byte-identical
on a `523b0da` binary.

**Why no gate and no reviewer saw it: the divergence is body-shape
dependent.** A body exe declines falls back to the source interpreter,
which goes through `ReadView::values` -> `present_through` and is right.
The reviewer's boundary table, on one table, one value and one output
type so that only the body text varies (their measurement, not re-taken
here): `FOR SELECT N ... INTO :O`, `FOR SELECT N+0 ...`, a two-column
`FOR SELECT`, a singleton `SELECT ... INTO`, `O = (SELECT ...)` and
`EXECUTE PROCEDURE` of any of them are all WRONG; a body with a text
`CAST`, a `CAST` back to the same numeric, a declared CURSOR with
`OPEN`/`FETCH`, or any body that also writes (exe declines) is RIGHT. So
"I tested a procedure" is not evidence either way.

**No wrong write follows from it**, measured by the reviewer:
`INSERT INTO t SELECT ... FROM <proc>`, `INSERT ... (SELECT FN1() ...)`
and `UPDATE t SET c = FN2(1)` all refuse with `42000 Dynamic SQL Error`
(separate pre-existing gaps), and a selectable procedure that writes
falls to the source interpreter and writes the right value.

### F2 - MEDIUM-HIGH, WRONG ANSWER (silent), PRE-EXISTING. The rescale overflow is reachable, and the engine RAISES where fire-crab answers a number

`crates/wire/src/server.rs:36143` (`present_field`; the declining
`i64::try_from(n).ok()?` at the end of it). The full reproducer and the
measured answers are in "At the extremes - and the claim here that was
FALSE" above; in one line: `BIGINT` holding `9e17`,
`ALTER ... TYPE NUMERIC(18,4)` which the engine ACCEPTS, and the engine
then answers `22003 numeric value is out of range` where fire-crab
answers `90000000000000.0000` and folds it into `SUM` and `WHERE`. The
`INT128` floor is reachable through the same door
(`NUMERIC(34,0)` -> `NUMERIC(38,10)`, the reviewer's fixture).

Pre-existing: the declining fallback and the pre-fix behaviour coincide,
so a `523b0da` binary answers the same (the reviewer measured it). What
this chunk introduced is the CLAIM that it is unreachable, and that
claim is retired above. **The unit test that pins the floor asserts the
current behaviour, not the engine's** - whoever converts this should
expect to change that test rather than keep it.

### F3 - MEDIUM, WRONG ANSWER, PRE-EXISTING. `DATE` -> `TIMESTAMP` is an engine-accepted ALTER the fix's guard excludes, and the old row projects as the epoch

`is_exact_dtype` (`crates/wire/src/server.rs:36074`) makes `present_field`
answer `None` the moment either side is not
`SHORT | LONG | INT64 | INT128`, so a `DATE` value is handed to a
`TIMESTAMP` wire slot and `encode_row_body`'s `Wire::Timestamp` arm
reads `(0, 0)` for it. Measured here:

```
DT: (1, DATE'2020-03-04'), ALTER H TYPE TIMESTAMP, then (2, TIMESTAMP'2021-05-06 01:02:03')
  SELECT ID, H FROM DT     crab   1|1858-11-17 00:00:00.0000  2|2021-05-06 01:02:03.0000
                           engine 1|2020-03-04 00:00:00.0000  2|2021-05-06 01:02:03.0000
  EXTRACT(HOUR FROM H) WHERE ID=1     crab <null>   engine 0
  EXTRACT(YEAR FROM H) WHERE ID=1     crab 2020     engine 2020   <- the STORED
                                                       value is intact
```

Purely the projection through the new descriptor - the class this chunk
closed, in a type direction it did not cover. The engine's ALTER matrix
is wider than the round above recorded: `CHAR(4)`->`CHAR(10)`,
`VARCHAR(4)`->`VARCHAR(10)`, `VARCHAR(4)`->`CHAR(20)`,
`INTEGER`->`VARCHAR(20)`, `DATE`->`TIMESTAMP` and `BIGINT`->`NUMERIC(20,4)`
are all ACCEPTED (a character column will not go back to a numeric one).
The reviewer measured that it is SELF-HEALING - an `UPDATE` that touches
the row re-lays it through `upgrade_image` and both servers then read
`2020-03-04` - so there is no wrong write, and no `SELECT`-only reader
is ever told.

### F4 - MEDIUM, WRONG ANSWER, PRE-EXISTING. `CHAR(n)` -> `CHAR(m)`: an old-format row presents at the OLD width

Same guard, same class; the text arm of `decode_field`
(`crates/ods/src/format.rs:464`) fits the value to the STORED
descriptor's char length and nothing re-pads it to the newest. Measured
here on `CW`: `(1,'ab')` under `CHAR(4)`, `ALTER B TYPE CHAR(10)`, then
`(2,'wxyz')`:

```
SELECT ID, CHAR_LENGTH(B) L, OCTET_LENGTH(B) O    crab   1|4|4    2|10|10
                                                  engine 1|10|10  2|10|10
SELECT ID, CHAR_LENGTH(B || 'X') L                crab   1|5      2|11
                                                  engine 1|11     2|11
```

A bare `SELECT B` AGREES, because the wire pads the fixed slot to the
width the describe announced - which is exactly why a row-comparison
gate cannot see this and why the shapes above are the ones to pin when
it is converted. `VARCHAR(4)` -> `VARCHAR(10)` is fine: the varying
length travels with the value.

### F6 - HIGH, WRONG WRITE (silent), PRE-EXISTING. fire-crab's `action_restore` of the ENGINE's own valid `.fbk` writes a nonsense POSITIVE `RDB$FIELD_SCALE` and values off by a power of ten

`crates/burp/src/lib.rs:4752` (`read_backup`, which reads the scale out
of att 9 - `RDB$FIELD_SUB_TYPE` on an engine-written file) and
`restore_column_def` (`crates/wire/src/server.rs:6384`). This is the
MIRROR of the att-9 / att-11 swap recorded on the WRITER side above, and
it is worse than a mirror: the writer's swap loses a scale in a file
fire-crab produced, while this corrupts a file the ENGINE produced.
Measured here, `B3 NUMERIC(18,4)` on a table that was never ALTERed,
backed up by the REAL `gbak -b`:

```
the ENGINE restoring that .fbk (gbak -c):
  ID 1|N 700.0000   ID 2|N 7.0000   ID 4|N -2.5000   ID 5|N 3.1416
fire-crab restoring the SAME .fbk (fbsvcmgr action_restore):
  ID 1|N 70000000   ID 2|N 700000   ID 4|N -250000   ID 5|N 314160

the restored column's catalog, read by the ENGINE out of each file:
  engine's restore     RDB$FIELD_TYPE 16  SCALE -4  SUB_TYPE 1  PRECISION 18
  fire-crab's restore  RDB$FIELD_TYPE 16  SCALE  1  SUB_TYPE 0  PRECISION  0
```

A POSITIVE scale is not a shape the engine ever writes. **Pre-existence:
the reader's code is byte-identical at `523b0da`** - this chunk's diff
adds only a comment in that hunk - but the restore was NOT re-run on a
baseline binary, here or by the reviewer, so pre-existence is code-read
rather than binary-confirmed.

**The BACKUP direction is right** and was confirmed across three formats
including a narrowing that rounds; only the declared scale is lost there
(the writer's half, recorded above). Whoever converts this must change
BOTH halves in one step - the writer, the reader, and
`restore_column_def`'s `precision: Some(0)` - because a writer-only fix
ships a file this server's own reader disagrees with, which is why the
half fix built above was reverted.

### F7 - MEDIUM, WRONG ANSWER, PRE-EXISTING. A `COMPUTED BY` column re-derives its type instead of keeping the declared one

Not about old formats at all - the POST-ALTER row diverges too, which is
why it is here rather than in the list above. Measured:

```
CP (A INTEGER, B INTEGER, S COMPUTED BY (A+B)); (100,200); ALTER A TYPE NUMERIC(9,2); (3.5,4)
  SELECT A, B, S FROM CP ORDER BY B
    crab   3.50|4|S 7.50     100.00|200|S 300.00
    engine 3.50|4|S 8        100.00|200|S 300
```

The engine keeps `S`'s declared `INTEGER` from `CREATE` time and rounds
`7.5` to `8`; fire-crab re-derives `NUMERIC(9,2)` from the operands.

### And one neighbouring WRONG WRITE, found on the way: fire-crab's logical backup silently drops a column-level `DEFAULT`

**HIGH, WRONG WRITE (silent), PRE-EXISTING, no gate covers it.** The
relation-field writer in `crates/burp/src/lib.rs` (the `rec::FIELD`
record at `:774`) emits atts 1, 48, 2, 13, 8, 10, 9, 11, 22, 24, 34, 38,
35 and 42/43 - and **no att 15 / att 39**, which are
`RDB$DEFAULT_VALUE` / `RDB$DEFAULT_SOURCE`. The GLOBAL-field (domain),
argument and procedure-parameter writers all do emit them (`:555`,
`:557`). Byte-identical at `523b0da`: pre-existing, and this chunk's only
touches near it are comments. Measured here, fire-crab's own
`action_backup` -> the REAL `gbak -c` -> read by the ENGINE:

```
CREATE DOMAIN DOM_I AS INTEGER DEFAULT 7;
CREATE TABLE T (A INTEGER, B INTEGER DEFAULT 42, C VARCHAR(8) DEFAULT 'hi', E DOM_I);
INSERT INTO T (A) VALUES (1);

RDB$RELATION_FIELDS.RDB$DEFAULT_SOURCE, T.A/B/C/E
  original       <NO DEFAULT> | DEFAULT 42 | DEFAULT 'hi' | <NO DEFAULT>
  restored copy  <NO DEFAULT> | <NO DEFAULT> | <NO DEFAULT> | <NO DEFAULT>
INSERT INTO T (A) VALUES (2)  - the row that follows
  original       A 2 | B 42     | C hi     | E 7
  restored copy  A 2 | B <null> | C <null> | E 7   <- the DOMAIN default
                                                      survives, the column
                                                      ones are gone
```

**Why no gate saw it:** `qa/serve-real-gbak.sh` has two default checks
and they cover a DOMAIN default (`CREATE DOMAIN D_POS AS INTEGER DEFAULT
7`, `:661`) and PSQL argument/parameter defaults (`:384`). No gate
declares a column-level `DEFAULT` in a `CREATE TABLE` and backs it up.

**Why it is this chunk's business, measured here:** the chunk that makes
`ON DELETE SET DEFAULT` run is the chunk that makes this matter. On a
copy restored from fire-crab's own backup, the action writes NULL where
the original writes the declared default:

```
GP (ID PK), GD (X, B INTEGER DEFAULT 10, FK B -> GP(ID) ON DELETE SET DEFAULT)
rows GP(1), GP(10), GD(100, 1);  then DELETE FROM GP WHERE ID = 1
  original file  NP 1 | X 100 | B 10       <- the declared default
  restored copy  NP 1 | X 100 | B <null>   <- SET DEFAULT wrote NULL
```

The `SET DEFAULT` rule itself survives the round trip
(`RDB$REF_CONSTRAINTS` reads `SET DEFAULT` in the restored copy); it is
only the default that is gone. Same category as the two entries above -
newly VISIBLE, not newly wrong.

### Operational notes for whoever picks this up

- **A gate that hardcodes its fixture names cannot be run concurrently
  with itself.** `qa/serve-real-scalefmt.sh` builds
  `/tmp/fbhandson/fc-scalefmt-*.fdb` and deletes them on EXIT, so two
  runs on DIFFERENT ports destroy each other: a reviewer's first run
  produced twenty-odd bogus DIFFs of the form `08001 ... No such file or
  directory` purely because another session was running the same gate.
  The port argument does not isolate the fixtures, and most gates in
  `qa/` have the same shape.
- **That gate renders an engine-side connection failure as a content
  DIFF.** The same reviewer saw nine DIFFs carrying
  `SQLSTATE 08001 ... Permission denied` verbatim in the `want:` column.
  It fails loudly rather than silently, so it is not dangerous, but it
  costs a re-run to tell a fault from a result - the same class as the
  `gbakverbose` re-chunking caveat recorded elsewhere.
- **`qa/serve-real-fkaction.sh` leaked its server on every run until
  2026-09-03**, when a `for srv in ...` loop that shadowed the pid
  variable was renamed and the trap made a `cleanup` function on
  `EXIT INT TERM HUP`. That leak is the mechanism behind two incidents in
  one session, including a cleanup filter that tested the wrong field and
  killed a server belonging to somebody else. Kill by PID from
  `ps -eo pid,args`, and check the field you are matching on; never
  `pkill` on a port - it matches your own shell.
- **This chunk touches NINE paths, not the six an earlier report
  listed:** `crates/burp/src/lib.rs`, `crates/ods/src/ddl.rs`,
  `crates/ods/src/format.rs`, `crates/ods/src/tra.rs`,
  `crates/wire/src/server.rs`, `docs/roadmap.md`,
  `qa/serve-real-fkguard.sh` (modified), plus the untracked
  `qa/serve-real-fkaction.sh` and `qa/serve-real-scalefmt.sh`. Staging by
  name from the six-path list drops `crates/ods/src/ddl.rs`, which holds
  `num_default_blr` and `RefAction::from_rule` that the rest of the chunk
  calls, and the tree would not build.
- A stray gitignored `$A` (an FDB from 11 Aug) sits in the repo root,
  untouched and not part of this work.

## A MIXED EXACT-NUMERIC PAIR IS ONE KEY (2026-09-03) - one missing comparison arm cost a whole foreign key

**HIGH, SILENT WRONG WRITE, closed.** `value_cmp` - the comparison every
consumer without a more specific rule falls back on - had arms for
`(Int, Int)`, for `(Scaled, Scaled)` at any two scales and for
`(Int128, Int128)`, and **none for the kinds MIXED**. `Int` is scale 0,
`Scaled` is an i64 mantissa at a scale, `Int128` is the wide one; they
are three storage shapes of ONE domain, and a pair drawn from two of
them fell past every arm to the tail `a.render().cmp(&b.render())`,
where `"7"` and `"7.00"` are different strings.

Firebird accepts a foreign key whose child column differs from the
parent key in SCALE, and a `SET DEFAULT` literal is stored at the
LITERAL's own scale. Both put such a pair in front of the comparison,
so one missing arm produced **an orphan on the parent side and a
refusal on the child side of one schema**:

```sql
-- PARENT SIDE, measured 2026-09-03, before the fix
CREATE TABLE NP (ID NUMERIC(9,2) NOT NULL PRIMARY KEY);
CREATE TABLE NC (X INTEGER, B NUMERIC(9,2) DEFAULT 7 REFERENCES NP ON DELETE SET DEFAULT);
INSERT INTO NP VALUES (7.00);  INSERT INTO NC VALUES (100, 7.00);
DELETE FROM NP WHERE ID = 7.00;
  fire-crab: performs it.  The ENGINE then reads NPAR 0 | ORPH 1 out of fire-crab's file
  the engine: SQLSTATE 23000, refuses.  Its own file: NPAR 1 | ORPH 0
```

`fk_action_leaves_old_key` read "not equal" as *the action cleared the
key*, waived the refusal, and the action then bound `7`, which stores
as `7.00` - the key just deleted.

```sql
-- CHILD SIDE, the same missing arm, no referential action anywhere
CREATE TABLE AP (ID INTEGER NOT NULL PRIMARY KEY);
CREATE TABLE AC (X INTEGER, B NUMERIC(9,2), CONSTRAINT AK FOREIGN KEY (B) REFERENCES AP);
INSERT INTO AP VALUES (7);  INSERT INTO AC VALUES (1, 7);
  fire-crab: 23000 ... -Foreign key reference target does not exist ("B" = 7.00)
  the engine: accepted
```

### The fix

`value_cmp` keeps its equal-scale fast paths and sends **every other
exact-numeric pair** - cross-format and cross-KIND alike - to `num_cmp`,
which was already the server's i128 alignment and was already what the
majority of consumers called FIRST. So the two places a mixed exact
pair can be compared now give one answer by construction; it used to be
two implementations, one of which had no mixed case at all. Unit tests
pin every mixed pair in both directions, the equal-values-at-different-
scales case, and the identity `value_cmp == num_cmp` over all nine
kind pairs.

### Before and after, measured

| | before | after |
|---|---|---|
| the two symptoms above, `NUMERIC(9,2)` / `(18,2)` / `(20,2)` / `ON UPDATE` | 6 SAME, 15 DIFF | **18 SAME, 3 DIFF** |
| the FK key-move probes plus a compound key crossing scales | 7 SAME, 3 DIFF | **10 SAME, 0 DIFF** |
| `qa/serve-real-fkaction.sh` (209 checks) | rc=1, 186 OK / 23 DIFF | **rc=0, 209 OK** |

The three DIFFs that remain in the first row are refusal TEXT with the
rows identical, and all three are pre-existing and recorded below.

### The consumers of `value_cmp`, and what the fix did to the ones that could be measured

This heading read "Every consumer of `value_cmp`" until 2026-09-03, and
the paragraph that closes the section read "no consumer of `value_cmp`
moved away from the engine". Both were an absolute over a set this page
itself says is not fully reachable here: `cmp_value_keys` is named three
paragraphs below as the one consumer NOT measured directly, and it
CANNOT be measured on this box, because `gbak -b` through this server
refuses any engine-created database (recorded above). The corrected
scope is the one that was actually measured, and it is stated per
consumer below.

`value_cmp` is shared, so each consumer was ENUMERATED, and every one
that could be reached from a client was then MEASURED - a fixture built
BY THE ENGINE where one column holds both shapes (`ALTER TABLE MX ALTER
N TYPE NUMERIC(9,2)` after two rows were inserted as `INTEGER`), read by
both servers, with nothing projecting that column so that a separate
rendering defect could not confound the comparison.

**Unchanged, because they call `num_cmp` FIRST and it already aligned:**
`Term::NumCmp` (WHERE against a numeric literal), `fold_cmp`
(`MIN`/`MAX` and the aggregate folds), `Cond2::Cmp` (PSQL conditions),
`Expr::NullIf`, `corr_quantified` (`= ANY` / `= ALL`). Measured SAME
before and after, and SAME as the engine both times.

**Unchanged, because the pair is routed away before this comparison:**
the hash JOIN and the index-probe hash - `join_key` buckets by a key
FAMILY and `desc_family` hashes only when both sides share one, so a
cross-scale join is not hashed at all: it falls to the full scan and
the ON decides (which goes through `num_cmp`). The index BAND takes
only scale-0 values and scans otherwise. `octets_value_cmp`'s fallback
belongs to a text column's ttype. All three measured identical before
and after, on the same fixture.

**Changed, and every changed answer became the ENGINE's:**

| consumer | before | after | the engine |
|---|---|---|---|
| `ORDER BY` DESC (`order_cmp`) | ids 3,1,4,5,2 | **1,3,4,2,5** | 1,3,4,2,5 |
| `GROUP BY` (group counts) | 1,1,1,1,1 | **1,2,2** | 1,2,2 |
| `SELECT DISTINCT` (group count) | 5 | **3** | 3 |
| `LIST` per group | 1 / 2 / 3 / 4 / 5 | **1,3 / 2,5 / 4** | 1,3 / 2,5 / 4 |
| `COUNT(*) OVER (PARTITION BY N)` | all 1 | **2,2,2,1,2** | 2,2,2,1,2 |
| `DENSE_RANK() OVER (ORDER BY N)` | 4,1,5,3,2 | **3,1,3,2,1** | 3,1,3,2,1 |
| `RANK() OVER (ORDER BY N)` | 4,1,5,3,2 | **4,1,4,3,1** | 4,1,4,3,1 |
| `LAG() OVER (PARTITION BY N ...)` | all NULL | **null,null,1,null,2** | same |
| the five FK comparisons | the two symptoms above | parity | - |

Ascending `ORDER BY`, `MIN`/`MAX`, `UNION`'s set equality, `EXISTS`,
`IN`, `NOT IN`, `PERCENTILE_DISC` and `COUNT(DISTINCT)` answered the
same before and after the arm - **and on THIS fixture, which is one
where nothing PROJECTS the altered column, they also answered what the
engine answers. That qualifier was load-bearing and this paragraph used
to drop it.** On a fixture that does project it - eleven rows, a
negative one, and a median landing on an old-format row - three of them
did not:

| | fire-crab, before this round's fix | the engine |
|---|---|---|
| `SELECT MIN(N), MAX(N) FROM MX` | `-0.02 \| 7.01` | `-2.00 \| 7.01` |
| `SELECT SUM(N) FROM MX` | `19.09` | `27.01` |
| `PERCENTILE_DISC(0.5) ... ORDER BY N` | `0.03` | `3.00` |

Found by a reviewer, who measured it identical on a binary with only
the arm reverted; re-measured here on 2026-09-03 against a binary with
only the PROJECTION fix reverted, which answers those same three wrong
values while the current binary answers the engine's - so it was the
projection all along and not this arm. `SUM` is the useful one, because
it shows the defect was not
"just rendering" - the sum of the raw mantissas
(`7+3+700+400+300+701+0-2+0-200 = 1909`) printed at scale -2. It was
the PROJECTION defect recorded below, and **that is fixed as of
2026-09-03**: all three now answer the engine's values
(`qa/serve-real-scalefmt.sh` B4, B11, and the same three queries
measured directly, `after: -2.00 | 7.01`, `27.01`, `3.00`).

Across the whole probe: **12 SAME / 12 DIFF before, 19 SAME / 5 DIFF
after**, and no consumer measured here moved away from the engine. That
is the whole of what is claimed: it is a statement about the consumers
listed above, all of which a client can reach, and NOT about
`cmp_value_keys`, which no measurement on this box reaches at all.

**Two probe numbers appear in this repository and they are not the same
measurement.** This paragraph's **12 SAME / 12 DIFF -> 19 SAME / 5
DIFF** was taken against a binary built from THIS tree with only
`value_cmp`'s mixed arm reverted. `value_cmp`'s own doc block records
**11 SAME / 13 DIFF -> 17 SAME / 7 DIFF on `79c4720`**, which is a
reviewer's measurement against the PREVIOUS COMMIT's binary - a
different baseline, carrying whatever else that commit lacked. Neither
was re-taken on 2026-09-03; both are labelled where they stand, and a
reader who finds both is looking at two questions, not two answers to
one.

`cmp_value_keys` (the raw-BLR request
sort, which `gbak` and the API clients drive) is the one consumer NOT
measured directly: it sorts whatever a compiled BLR request names, and
the requests this server actually serves sort system-table columns,
which have one format each. It is the same `value_cmp`, so a mixed
pair there would move the same way as everywhere above; the `gbak`
gates (58 + 39 + 14 + 12 checks, rc 0) exercise the path.

### And a decimal literal DEFAULT can now be created at all

`NUMERIC(9,2) DEFAULT 7.00` and `DEFAULT 7.0` - which the engine
accepts - failed the whole `CREATE TABLE` with a bare
`Dynamic SQL Error`, on every column type, because the default parser
only took an integer literal. So `DEFAULT 7`, the scale-0 spelling that
was the corrupting one, was **the only decimal default fire-crab could
write**. The engine stores a decimal default as the same
`blr_literal blr_long` with the LITERAL's scale in the (signed) scale
byte, read back out of its catalog as hex:

```
NUMERIC(9,2) DEFAULT 7.00        05 15 08 FE BC020000 4C     (700,  -2)
NUMERIC(9,2) DEFAULT 7.0         05 15 08 FF 46000000 4C     (70,   -1)
NUMERIC(9,2) DEFAULT -7.25       05 15 08 FE 2BFDFFFF 4C     (-725, -2)
NUMERIC(9,4) DEFAULT 123456.7890 05 15 08 FC D2029649 4C     (1234567890, -4)
```

`num_default_blr` writes exactly that and `int_default_blr` is now the
scale-0 call of it, so nothing an integer default writes moved. The
ENGINE reads the same `RDB$DEFAULT_SOURCE` and the same
`RDB$DEFAULT_VALUE` bytes out of fire-crab's file as out of its own
(gate 16g). **Still refused, and each is the refusal it already gave:**
an exponent literal (`DEFAULT 1.5e2`), and a mantissa too wide for
`blr_long` (`DEFAULT 12345678901.2345`, which the engine writes as
`blr_int64`).

### The gate

`qa/serve-real-fkaction.sh` grows from 172 checks to **209**, rc 0.
Section 16 is new (37 checks): the parent-side `SET DEFAULT` shape and
the child-side cross-scale shape on `NUMERIC(9,2)`, `NUMERIC(18,2)` and
`NUMERIC(20,2)` (each paired with its own scale-0 type - `INTEGER`,
`BIGINT`, `INT128` - because the engine refuses a partner index segment
of a different WIDTH); the `ON UPDATE SET DEFAULT` spelling; the
orders/lines shape with no referential action anywhere; a compound key
crossing scales on one segment; the contrasts that must NOT move (two
SCALED sides, a `DOUBLE PRECISION` key, and a default that is a
DIFFERENT live key); and the decimal-default DDL with its catalog bytes
pinned in both files. Every shape has the ENGINE read both files back
and COUNT the dangling children. Non-vacuity: **186 OK / 23 DIFF on the
previous round's binary, 102 OK / 107 DIFF on `79c4720`.**

Section 14e's `efiles` was also repaired: it printed `COALESCE('set',
'-')` over a row set already filtered to `RDB$FOREIGN_KEY IS NOT NULL`
- a constant dressed as a measurement, which hid the very difference
the check exists for. It now READS the column, over an unfiltered row
set, and shows it: the ENGINE clears the deferred-drop leftover's
`RDB$FOREIGN_KEY` (`fk=null`) where fire-crab leaves it `fk=set`.

### Recorded here, still open

- **~~MEDIUM, WRONG ANSWER~~ - CLOSED 2026-09-03 by the round below.**
  An old-format row of a column whose SCALE was altered was returned
  through the NEW format's scale: the engine reads `7.00` for both rows
  of an `INTEGER` -> `NUMERIC(9,2)` fixture and fire-crab read `0.07`
  for the old one. The stored VALUE was always right - `WHERE N = 7`
  picked that row in both servers - so it was the projection. See "A
  RECORD IS PRESENTED THROUGH THE FORMAT THAT DESCRIBES IT NOW".
- **MEDIUM, MISSING ROWS, PRE-EXISTING, STILL OPEN - an INDEX OLDER
  THAN THE FORMAT A ROW WAS WRITTEN UNDER does not name that row.**
  This entry has now been narrowed twice, and the second narrowing was
  itself too narrow. It first said an index over a scale-altered column
  loses the old-format rows, flatly; then that "it is the index's AGE
  relative to the ALTER that decides", which holds only when the table
  has had exactly ONE `ALTER`. The law is per FORMAT: an index entry is
  keyed at the scale its row carried when the entry was MADE, and a
  probe builds ONE key, so an index misses every row written under a
  format MINTED AFTER IT. Measured 2026-09-03, three fixtures,
  `INTEGER` -> `NUMERIC(9,2)` [-> `NUMERIC(18,4)`], rows written on both
  sides of every ALTER:
  - index created BEFORE the only ALTER (`IW`): `WHERE N = 7` answers
    `2` where the engine answers `2, 3`; `WHERE N = 700` answers `1` for
    the engine's `1, 4`; and a RANGE probe loses the same rows -
    `WHERE N > 0` answers `1, 2` for the engine's `1, 2, 3, 4`, as does
    `BETWEEN 1 AND 1000`.
  - index created AFTER a first ALTER and BEFORE a second (`IX3`):
    `WHERE N = 7` answers `2, 3` where the engine answers `2, 3, 5`, and
    `WHERE N > 0` answers `1, 2, 3, 4` for the engine's `1, 2, 3, 4, 5`.
    **This is the shape that corrects the wording**: the index is
    YOUNGER than the ALTER and still loses the rows written under the
    format minted after it. The projection and `ORDER BY N` over the
    same table are the engine's answers.
  - index created after BOTH ALTERs (`IX4`): `= 7`, `> 0`, the
    projection and an `ORDER BY` are all the engine's answers. (On the
    single-ALTER fixture, an index created after the ALTER - before or
    after the later inserts - is likewise the engine's answer on `= 7`,
    `= 700`, `> 0`, an `ORDER BY` and an indexed self-join.)

  Identical on a binary with the projection fix reverted, so it is the
  index KEY ENCODING and not the projection. The `IW` shapes, the two
  equality probes and now the range probe, are pinned with both answers
  in `qa/serve-real-scalefmt.sh` section H; that fixture has one ALTER,
  so `IX3`/`IX4` live here rather than in the gate.
- **MEDIUM, REFUSAL TEXT, PRE-EXISTING - an INT128-backed key loses the
  `-Problematic key value` line.** `NUMERIC(20,2)`, `NUMERIC(19,2)` and
  a plain `INT128` primary key all refuse with the constraint and table
  named and that line ABSENT, where the engine prints it;
  `NUMERIC(18,2)` (i64-backed) prints it. Byte-identical on the
  previous round's binary for an ordinary no-rule child with no actions
  anywhere, so it is not this chunk's. Gate 16a/16b pin BOTH answers.
- **MEDIUM, REFUSAL TEXT, PRE-EXISTING - a `DOUBLE PRECISION` key
  renders as `("ID" = 7e0)` where the engine writes
  `("ID" = 7.000000000000000)`, and a `CHAR(5)` key renders PADDED,
  `("ID" = 'AB ')` against the engine's `("ID" = 'AB')`.** Same family
  as the `DATE`/`TIMESTAMP` rendering below; rows identical in every
  case. Gate 16f pins both answers for the `DOUBLE` one.
- **MEDIUM, REFUSAL TEXT, PRE-EXISTING - a `SET DEFAULT` whose default
  is `CURRENT_TRANSACTION` refuses with `42000 Dynamic SQL Error` where
  the engine answers `23000 ... -Foreign key reference target does not
  exist ... -At trigger`.** Both refuse and both files hold the same
  rows, so the wider acceptance in `fk_action_leaves_old_key` is safe -
  but the comment there claimed, as "verified", that it refuses "with
  the engine's own reason", and it does not. Byte-identical on
  `79c4720`; the comment is corrected.

## A DECISION, NOT A CHASE: FIRE-CRAB CHECKS EVERY FOREIGN-KEY PARTNERSHIP (2026-09-03)

**DECISION. On a parent `DELETE` or `UPDATE`, fire-crab checks EVERY
dependent foreign key on every referenced index, and refuses if ANY of
them still holds the key. The engine checks exactly ONE per referenced
index. This is a deliberate, documented divergence, and it is not a
defect to be closed in a later round.**

The round below spent itself proving the engine's selector. It is now
genuinely proven, and the proof is the reason to stop reproducing it.

### What the engine does, measured

For each REFERENCED (parent) index the engine performs its master-side
check on the FIRST row of `RDB$INDICES`, in PHYSICAL RECORD ORDER, whose
`RDB$FOREIGN_KEY` names that index. Every partnership behind it on that
index goes unchecked, and the parent row is deleted with those children
still pointing at it. Measured directly against Firebird 6 at
`127.0.0.1/3050`, 2026-09-03:

```sql
CREATE TABLE QP (ID INTEGER NOT NULL PRIMARY KEY);
CREATE TABLE Q1 (X INTEGER, B INTEGER REFERENCES QP);   -- EMPTY, physically first
CREATE TABLE Q2 (X INTEGER, B INTEGER REFERENCES QP);   -- holds the key
INSERT INTO QP VALUES (1);  INSERT INTO Q2 VALUES (200, 1);
DELETE FROM QP WHERE ID = 1;
  engine:  parent rows = 0   Q2 rows = 1   Q2.B = 1      <- A DANGLING REFERENCE
```

`gfix -v -full` calls that file clean. Every other candidate was ruled
out by its own shape: not "the first partnership whose rule ACTS" (the
shape above with a cascading `Q3` behind), not by constraint or index
NAME (`FZ` declared first and empty, `FA` holding), not by child
RELATION ID (`R1` lowest and holding, `KR2` added first), not by child
INDEX ID, and not per parent TABLE (`MP (ID PK, U UNIQUE)`: a clean
partnership on the PK says nothing about the UNIQUE, and the engine
refuses there - that one is a real defect and it stays closed).

### The shape that proves the selector - and the one that does not

**What decides between PHYSICAL `RDB$INDICES` order and CREATION order
is a freed catalog slot, not a `gbak` round trip:**

```sql
CREATE TABLE RP (ID INTEGER NOT NULL PRIMARY KEY);
CREATE TABLE JUNK (A INTEGER);  CREATE INDEX J1 ON JUNK (A);  COMMIT;
CREATE TABLE RB (X INTEGER, B INTEGER, CONSTRAINT FB FOREIGN KEY (B) REFERENCES RP);
COMMIT;  DROP TABLE JUNK;  COMMIT;      -- frees an earlier RDB$INDICES slot
CREATE TABLE RA (X INTEGER, B INTEGER, CONSTRAINT FA FOREIGN KEY (B) REFERENCES RP);
```

`FB` is created BEFORE `FA`, the engine puts `FA`'s row into `JUNK`'s
freed slot, and in the engine's own file the physical order is
`RDB$PRIMARY1, FA, FB`. Creation order says ask `FB`; physical order
says ask `FA`. Both directions measured on the engine's file: with `RA`
holding the key it REFUSES naming `FA`; with `RB` holding the key it
PERFORMS the delete and leaves `RB` dangling. Physical order, both
times.

**THE CLAIM THAT THE `gbak` FLIP IS "the shape that decides it, and the
only one that can" IS FALSE AND IS WITHDRAWN** - from the entry below,
from `fk_check_parent_row`'s doc block and from
`qa/serve-real-fkaction.sh`. A reviewer ran `gbak -c -v`, whose own log
prints the order the restore CREATES the indexes in:

```
gbak:    activating and creating deferred index "PUBLIC"."FC"
gbak:    activating and creating deferred index "PUBLIC"."FB"
gbak:    activating and creating deferred index "PUBLIC"."FA"
```

`FC, FB, FA` - identical to the restored file's physical order. The flip
separates physical order from `RDB$RELATION_CONSTRAINTS` and
`RDB$REF_CONSTRAINTS`, which do not move, and from nothing else. It
cannot tell physical order from creation order, which is the very class
of error the round below was pilloried for. The measurement is real; the
conclusion drawn from it was not supported by it.

### Why fire-crab diverges instead of reproducing it

1. **Reproducing it would make foreign-key ENFORCEMENT depend on the
   engine's physical catalog record PLACEMENT.** The engine reuses a
   freed `RDB$INDICES` slot; fire-crab appends. So whether a foreign key
   is enforced at all would turn on the schema's DELETION HISTORY - an
   ordinary `DROP TABLE` of an unrelated table is enough, and so is a
   `DROP CONSTRAINT` followed by a re-`ADD`. That is not a law about
   foreign keys; it is a law about where a catalog row happened to land.
2. **Three rounds have chased that selector and each shipped a NEW
   silent wrong write** - three for three. A parent row deleted that the
   engine keeps, an orphan behind it, and `gfix -v -full` clean each
   time.
3. **What is being reproduced is referential corruption.** The engine's
   answer in the `QP`/`Q1`/`Q2` shape LEAVES A DANGLING CHILD ROW. This
   project's standing rule applies: a conversion that cannot express a
   case declines it rather than approximating it, and a refusal is
   enormously better than a silent wrong write.

### THE EXACT CONSEQUENCE

**fire-crab REFUSES some parent `DELETE`s and `UPDATE`s that the engine
PERFORMS** - `SQLSTATE 23000`, naming the first partnership in
`RDB$INDICES` row order that still holds the key. What the engine left
behind is **not one thing**, and only the first of these two is this
decision's own consequence:

- **Where the ENGINE'S SELECTOR is what differs** - a partnership
  BEHIND the physically first one on the same index still holds the key
  - the engine performs the statement and **its own file is left
  holding a dangling child row**. Measured on every such shape, with
  the ENGINE reading both files back and counting the orphans in each
  (`qa/serve-real-fkaction.sh` sections 13 and 14).
- **Where ANOTHER PARTNERSHIP'S ACTION has already cleared the very
  rows** this one probes, **the engine's file is CLEAN** and fire-crab
  refuses a statement whose engine result was correct. Measured
  2026-09-03: one child column carrying two foreign keys to one parent
  index, `W1` with no rule and `W2` `ON DELETE SET NULL`, has the
  engine null the column and delete the parent with `ORPH 0` in its
  file, while fire-crab refuses naming `W1`; with an `ON DELETE
  CASCADE` sibling instead, the engine deletes both rows, again
  `ORPH 0`. That is an **over-refusal**, not a divergence in this
  decision's favour - it is the "the check does not see what ANOTHER
  partnership's action left behind" bullet under "Recorded, still
  open", it is present on `79c4720`, and the fix that closes it is
  named there.

**The other direction is NOT ruled out, and the superset argument this
entry used to give for ruling it out does not hold.** What is true, and
is all the walk itself buys, is narrower: **asking every partnership
rather than one cannot introduce an acceptance**, because the walk
refuses whenever any partnership answers. But the check is not only a
set of partnerships, and two paths do accept where the engine refuses:

1. **A `BEFORE UPDATE` trigger that writes `NEW.<key>`.** It moves the
   referenced key without the statement's SET list naming it, and the
   parent-side partnership list is narrowed BY that SET list before the
   check runs (`plan_update`'s `touched` filter, `server.rs`, which
   narrows `fk_refs` and `fk_children` alike). Measured 2026-09-03 on a
   no-rule partnership: `UPDATE TP SET Z = 9 WHERE ID = 1` under a
   trigger writing `NEW.ID = 55` is performed by fire-crab, and the
   ENGINE reads `ORPH 1` back out of fire-crab's file where it reads
   `ORPH 0` out of its own. Byte-identical on `79c4720`; it has its own
   bullet under "Recorded, still open".
2. **A partly-NULL key on an OPAQUE partnership**, accepted on the
   last-resort path deliberately - the wide question that path asks
   cannot be asked about a NULL. Behaviour-identical to `79c4720`;
   reasoned, not run.

A **third was closed on 2026-09-03**, and it is why this section was
rewritten: `value_cmp` had no arm for two exact numerics of DIFFERENT
kinds, so a child column at scale 0 against a parent key at scale 2
never matched and the parent deleted out from under a live child (see
"A MIXED EXACT-NUMERIC PAIR" above). A superset of partnerships each
asked a too-narrow question is not a superset of refusals - which is
why the superset argument was the wrong SHAPE of argument, not merely
too broadly scoped.

The divergence itself is invisible on a schema where each parent index
has one dependent foreign key, which is the ordinary case; it appears
only where a parent index carries SEVERAL, and only when a partnership
other than the physically first one holds the key.

### What was kept from the rounds that chased the selector

Two things, both correct and both engine-faithful, and neither is about
the selector:

- **The check reads the child AFTER the action has run.** An acting
  partnership is not waived; it is judged on what its action WROTE. Only
  `SET DEFAULT` can write the old key straight back, and there the
  engine refuses: `SC.B INTEGER DEFAULT 7 REFERENCES SP ON DELETE SET
  DEFAULT` with a child row `B = 7` answers `-Problematic key value is
  ("ID" = 7)` on `DELETE FROM SP WHERE ID = 7`.
- **The NULL laws on both sides.** A key is unreferenceable only when
  EVERY column of it is NULL (the master side probes the child's index,
  where a NULL is a storable key); an action fires only when some
  comparison is TRUE; and "did the key change" is `IS DISTINCT FROM`, so
  two NULLs are ONE key.

### The two silent wrong writes this round closed

Both were shipped by the round below and both were found by a reviewer.

- **HIGH, SILENT WRONG WRITE, NEW in the round below - `SET DEFAULT`
  whose default is NOT a literal waived the check.** `default_as_value`
  answered `None` for everything but a literal, `fk_action_leaves_old_key`
  read that as "the action cleared the key", and the refusal was skipped
  - while `default_wire_param`, which the action actually binds, happily
  evaluates `CURRENT_USER`, `CURRENT_DATE`, `CURRENT_TIME`,
  `CURRENT_TIMESTAMP`, `CURRENT_ROLE` and `CURRENT_CONNECTION`. So the
  action wrote the key straight back and nothing refused. Measured:
  `B VARCHAR(31) DEFAULT CURRENT_USER` with a child row `'SYSDBA'` had
  `DELETE FROM SPU WHERE ID = 'SYSDBA'` performed by fire-crab and
  refused by the engine; `DATE DEFAULT CURRENT_DATE` and the
  `ON UPDATE SET DEFAULT` spelling were the same. The doc comment that
  justified the gap - "[fk_action_stmts] refuses the whole statement on
  the same default a moment later" - was false for every form the server
  CAN evaluate. `default_as_value` now evaluates every form
  `default_wire_param` does, a test ties the two together so they cannot
  drift, and `CURRENT_TRANSACTION` is the one remaining `None`. **Half of
  the old justification holds there and half does not, and the word
  "verified" used to be attached to the half that does not.** What is
  true and was measured: `fk_action_stmts` refuses the whole statement a
  moment later, so no wrong write comes of it and the rows agree with the
  engine's. What is NOT true: that it refuses "with the engine's own
  reason". It refuses `42000 Dynamic SQL Error` where the engine answers
  `23000 ... -At trigger`; both files hold `NP 1 | CB 99999` afterwards.
  Byte-identical on `79c4720`, so the message gap is pre-existing, and it
  is recorded as a refusal-text defect below.
- **HIGH, SILENT WRONG WRITE, NEW in the round below - `DROP CONSTRAINT`
  and re-`ADD` put a different row first, and only the first row was
  asked.** fire-crab places the re-added index row before the live one
  and leaves the deferred-drop leftover's `RDB$FOREIGN_KEY` set; the
  engine appends and clears it. Either half alone flips which row is
  "first", so an empty child became the enforcement and the parent
  DELETE went through with the real child left dangling. This is
  subsumed rather than patched: with every partnership asked, the layout
  decides nothing. **The layout difference itself is real and stays
  open** - `qa/serve-real-fkaction.sh` 14e pins both files' layouts so it
  cannot drift unnoticed.

### The safe direction, hunted - and WHAT THE HUNT ACTUALLY COVERED

The claim "fire-crab can only ever refuse more, never less" is a claim
about a direction, so it was attacked rather than asserted. Every
several-children shape that could be built was run through both servers
on their own files and then read back BY THE ENGINE from both:
`Q1`/`Q2`/`Q3`; two children over two referenced indexes and the
`ORD`/`LINES`/`PAYMENTS` business schema; the freed-slot shape in both
directions; the eight-child one-rule-each matrix; the `gbak`-restored
file whose physical order is reversed; `DROP CONSTRAINT` + re-`ADD`; a
deferred-drop leftover shadowing a live partner; the non-firing-action
partner in front, empty and holding; and `SET DEFAULT` writing the key
back on both the DELETE and the UPDATE side. **Within that space no
counter-example was found**: in every shape where the two servers
differ there, fire-crab refuses and the ENGINE's file is the one
holding the dangling row.

**That space is SEVERAL CHILDREN OF ONE PARENT INDEX, and it is not the
whole question.** Every shape above varies WHICH PARTNERSHIPS ARE
ASKED. None of them varies what "holds the key" MEANS, or whether the
partnership list reaches the check at all - and both of those produced
counter-examples once a reviewer looked there:

- **the key comparison itself.** `value_cmp` had no arm for two exact
  numerics of different KINDS, so an `INTEGER` child column against a
  `NUMERIC(9,2)` parent key was never matched at all. FOUND by a
  reviewer, FIXED 2026-09-03 ("A MIXED EXACT-NUMERIC PAIR" above). No
  several-children shape could have found it: it needs two TYPES.
- **the partnership list.** A `BEFORE UPDATE` trigger moving the key
  escapes the SET-list narrowing before the walk begins. Found by a
  reviewer; pre-existing, still open.

**The three whole-file detectors this round leaned on could not have
found either**, and that is worth writing down next to the hunt:
`gfix -v -full` calls a file with a dangling child row CLEAN (it
validates page structure, not referential agreement); a count of
`RDB$INDEX_INACTIVE` in a restored copy is not evidence either way -
it read **0** on the failed restore measured here and a reviewer
re-running the same shape read **3** on theirs, so the count depends on
how far the restore got and says nothing on its own; and a per-shape
orphan query only sees the shapes it was written for. The one detector
that did fire is **`gbak`'s own restore, by what it PRINTS**: a restore
rebuilds and ACTIVATES every foreign-key index through the engine, and
on a violated one it did not bring the index online - it emitted

```
gbak:cannot commit index "PUBLIC"."INTEG_3"
gbak: ERROR:violation of FOREIGN KEY constraint "INTEG_3" on table "PUBLIC"."TC"
gbak: ERROR:    Problematic key value is ("B" = 1)
gbak: ERROR:Database is not online due to failure to activate one or more indices.
```

Measured 2026-09-03 on a file fire-crab had just corrupted through the
BEFORE-trigger path: `gfix -v -full` rc=0 and silent, the restored
copy `INACTIVE 0` and `ORPH 1`, the restore itself rc=2 with the five
`gbak: ERROR` lines above. **Assert the printed error, not the exit
code alone** - a reviewer recorded one restore that printed
`Problematic key value is ("ORDID" = 1.00)` and still exited 0, so the
code is not by itself the signal, and an inactive-index count is not a
signal at all.

### The gate

`qa/serve-real-fkaction.sh` grows from 118 checks to **172**, rc 0.
(The round ABOVE takes it to **209** and repairs 14e's `efiles`, which
printed a constant where it claimed to read `RDB$FOREIGN_KEY`.)
Fourteen checks stopped being parity comparisons, and every one of them
became a LOUDER assertion rather than a quieter one - a gate that
quietly stops comparing is worse than one that fails. Each diverging
shape now asserts THREE things where it asserted one: fire-crab's own
answer against a recorded expectation, the ENGINE's own answer against
its own, and the DIRECTION (`crab-refuses|engine-performs`) computed
from the two answers, so neither server can change its mind unnoticed.
Where rows are at stake a fourth and fifth follow, with the ENGINE
reading both files: fire-crab's with no dangling child in it, the
engine's with the one it left. Section 14 adds the `QP`/`Q1`/`Q2`
measurement, the freed-slot shape in both directions with both files'
physical `RDB$INDICES` order pinned, and both of the reviewers'
reproducers. Non-vacuity: **133 OK / 39 DIFF on the previous round's
binary, 86 OK / 86 DIFF on `79c4720`.**

### Recorded, still open

- **MEDIUM, REFUSAL TEXT, PRE-EXISTING - the refusal names the wrong
  constraint and the wrong key when a parent has SEVERAL referenced
  indexes.** The engine's outer loop is over the PARENT's indexes and
  fire-crab's is over child index rows, so with `OP (ID PK, U UNIQUE)`
  where the UNIQUE takes index slot 1, both servers refuse and both
  leave the same rows, but the engine names `KOB`/`("U" = 10)` and
  fire-crab names `KOA`/`("ID" = 1)`. The `UPDATE` spelling and the
  mirror shape diverge identically. Byte-identical on `79c4720`. Rows
  are the same in every case: a message defect, not a write defect.
- **MEDIUM, REFUSAL TEXT, PRE-EXISTING - a DATE, TIME or TIMESTAMP key
  is rendered with its type word in the refusal.** `-Problematic key
  value is ("ID" = DATE '2020-01-02')` where the engine writes
  `("ID" = '2020-01-02')`, and `TIMESTAMP '...'` likewise. Byte-identical
  on the previous round's binary for a plain no-rule child, so it is not
  this chunk's; it became easy to see here because the `SET DEFAULT`
  fix made a DATE-keyed refusal reachable.
- **MEDIUM, WRONG WRITE (silent), PRE-EXISTING - a `BEFORE` TRIGGER THAT
  MOVES THE REFERENCED KEY BYPASSES BOTH THE CHECK AND THE ACTION.**
  `fk_children` is narrowed to partnerships whose key columns the
  statement's SET LIST names, and a `BEFORE UPDATE` trigger writing
  `NEW.<key>` is invisible to that filter. Byte-identical on `79c4720`;
  the narrowing is only sound if taken AFTER the BEFORE triggers have
  patched the row. Nothing in any gate holds it.
- **MEDIUM, OVER-REFUSAL, PRE-EXISTING (narrowed, not closed) - the
  check does not see what ANOTHER partnership's action left behind.**
  `fk_action_leaves_old_key` is asked about the checked partnership's own
  action only, so when a different partnership's action clears the very
  rows this one probes, fire-crab still refuses: one child column
  carrying two FKs to one parent index, `W1` (no rule) and `W2`
  (`ON DELETE SET NULL`), has the engine perform the DELETE with the
  child nulled and fire-crab refuse. `79c4720` refuses too. **This round
  makes it WIDER, measured, not guessed:** the same shape with the
  `SET NULL` constraint declared FIRST used to agree (the clearing
  partnership was the one asked, so nothing behind it was), and now
  refuses as well; so does the spelling where a second child's
  `ON DELETE CASCADE` deletes the very rows the first partnership
  probes. Direction unchanged - a refusal, never an orphan, and
  `gfix -v -full` clean on fire-crab's file in all three. The fix is to
  ask [fk_action_leaves_old_key] of every partnership that rewrites the
  same child rows rather than only of the one being checked, and it is
  the natural next piece of work here.
- **LOW, REFUSAL, PRE-EXISTING - `ORDER BY RDB$DB_KEY` is a
  `Dynamic SQL Error`.** It costs nothing but the ability to read a
  relation in physical record order through fire-crab itself, which is
  why every placement measurement in the round above is taken by the
  ENGINE reading fire-crab's file. Byte-identical on `79c4720`.
- **LOW, REFUSAL WITH AN INCOMPLETE VECTOR, PRE-EXISTING - a master-side
  FK refusal raised inside a PSQL body carries no `-At procedure`
  frame.** Byte-identical on the baseline, and it is GENERAL, not
  specific to the guard path: a plain CHECK, a NOT NULL and a child-side
  FK failure inside a procedure all lose the frame too, and so does a
  cascade failing inside one. The `InTrigger` arm of `wrap_at_procedure`
  added by the round below, and its comment claiming the frame is
  emitted, are therefore unreachable in practice - the comment is
  wrong and the roadmap bullet below that scopes this to "the path where
  the refusal comes from the GUARD" is too narrow.
- **A PARTLY-NULL KEY ON AN OPAQUE PARTNERSHIP IS ACCEPTED, and that is
  a decision.** Unchanged by this round: the wide question ("does some
  row hold every one of these values in ANY column?") cannot be asked
  about a NULL, so a partly-NULL key keeps the older, wider ACCEPTANCE
  on the last-resort path rather than a guess in either direction.
  Behaviour-identical to `79c4720`. Reasoned, not run.
- **`fk_actions_runnable` does not catch an unresolvable index row on a
  RESTRICT-only parent.** The comment on the old selector claimed such a
  shape "refuses at prepare instead"; `fk_actions_runnable` is only
  consulted when a flag-4 action trigger of the statement's kind exists,
  and a parent whose partnerships are all `RESTRICT`/`NO ACTION` has
  none. Under the decision above this no longer changes WHICH
  partnership is asked - all of them are - so what remains is that an
  index row this server cannot resolve into a partnership at all is
  simply not asked. Reasoned, not run: a reviewer could not construct an
  index row that names a parent index and still fails to resolve.
- **NO SCHEMA SUPPORT, so `parent_index` and the parent-row lookup
  keying on the BARE index name is a LATENT hazard.** Index names are
  per-schema in FB6 and the engine will happily create two `IXP` indexes
  in different schemas; fire-crab rejects `CREATE SCHEMA` outright, so
  the shape is unreachable through its own DDL today.
- **A FUSED DOC COMMENT AT `user_triggers` / `db_triggers`,
  PRE-EXISTING** - the two doc blocks run together with the function
  between them missing. Identical at `79c4720`.

---

## ONE DEPENDENT FOREIGN KEY PER REFERENCED INDEX (2026-09-03) - the round that corrected a law written on evidence that could not support it

**SUPERSEDED IN PART BY THE ROUND ABOVE.** The law recorded here is the
ENGINE's and it is correct. What is withdrawn is (a) that the `gbak`
flip decides it - it cannot separate physical order from creation order
- and (b) that fire-crab reproduces it. fire-crab now checks EVERY
partnership, by decision; the entry above says why and what it costs.

A METHODOLOGY FAILURE FIRST, A CODING ONE SECOND. The round below
replaced a recorded observation ("the engine acts on only the FIRST
foreign key on a parent-row DELETE") with a sharper-sounding law ("the
RESTRICT walk stops at the first partner whose rule for THIS statement
kind acts") and presented seven measured shapes, `PA`-`PH`, as proof.
All seven measurements are real and all seven still hold. **Not one of
them could distinguish the two laws**: in every one the deciding partner
is `partner[0]`, or `partner[1]` behind an empty `partner[0]`, so both
candidates answer them identically. A probe set that every candidate
passes has measured nothing, and the law went into a doc comment, into
this file, and into the code as "measured", "not an accident of this
server's loop", "recorded as a decision".

Both reviewers found the same shape independently, and it is a SILENT
WRONG WRITE: a parent row deleted that the engine keeps, an orphan left
behind, `gfix -v -full` clean, and a file that will not restore with its
indexes active.

**THE RULE FOR THIS PROJECT, stated so the next round cannot repeat it:
before encoding a law, write down the candidate laws and construct the
shape whose ANSWER DIFFERS between them. Probes are designed to
DISTINGUISH, not to confirm.**

### The law, and the shapes that decide it

**For each REFERENCED (parent) index the engine performs its master-side
check on exactly ONE dependent foreign key - the FIRST row of
`RDB$INDICES`, in PHYSICAL RECORD ORDER, whose `RDB$FOREIGN_KEY` names
that index. Every partnership behind it on the same index goes
unchecked. Every acting partnership on EVERY index still fires its
action, and the check reads the child AFTER the action has run.**

Measured 2026-09-03 against Firebird 6 at `127.0.0.1/3050`. Each shape
below rules out one candidate; the candidates were: "the first partner
whose rule acts", "the first by constraint/index NAME", "the first by
child RELATION ID", "the first CREATED", "the first in
`RDB$RELATION_CONSTRAINTS`", "one per parent TABLE", and the one that
survived.

- **Not "the first that acts".** `QP (ID PK)` with three no-rule
  children declared `Q1` (EMPTY), `Q2` (holds key 1), `Q3`
  (`ON DELETE CASCADE`, holds a row). "First that acts" checks `Q1`,
  then `Q2`, and REFUSES. The engine DELETES - `NP 0`, `Q3` cascaded
  away, `Q2` left dangling. Only `Q1` was ever asked.
- **Not by NAME.** The same three named `FZ` (declared first, EMPTY),
  `FA` (holds the key), `FM` (cascade). `FA` sorts first; the engine
  DELETES, so it asked `FZ`.
- **Not by RELATION ID.** Tables `R1`, `R2`, `R3` created in that order
  (ids 129, 130, 131), constraints then added `KR2`, `KR1`, `KR3`. `R1`
  has the lowest id and holds the key, `R2` is empty; the engine
  DELETES, so it asked `KR2`.
- ~~**PHYSICAL `RDB$INDICES` ORDER, not creation order and not the
  constraint catalogs - the shape that DECIDES it, and the only one
  that can.**~~ **THE MEASUREMENT STANDS; "THE SHAPE THAT DECIDES IT,
  AND THE ONLY ONE THAT CAN" IS FALSE AND IS WITHDRAWN** - see the
  round above, which disproved it with `gbak -c -v` and replaced it
  with a shape that does decide. `FA` (declared first, HOLDS the key),
  `FB`, `FC` (both empty), all no-rule. As created, `RDB$INDICES` is
  physically `FA, FB, FC` and `DELETE FROM QP WHERE ID = 1` is REFUSED
  naming `FA`. A `gbak` backup and restore of that same database
  REVERSES `RDB$INDICES` to `FC, FB, FA` while
  `RDB$RELATION_CONSTRAINTS` and `RDB$REF_CONSTRAINTS` keep their
  original order (`RDB$DB_KEY` read out of both files, unchanged). Same
  schema, same rows, same statement - and the restored file DELETES the
  parent, leaving `FA`'s child dangling. What that separates is the
  physical order of `RDB$INDICES` from the two CONSTRAINT CATALOGS, and
  nothing else: `gbak -c -v`'s own log prints the order the restore
  CREATES the indexes in - `FC`, `FB`, `FA` - which is the restored
  file's physical order, so creation order moved with it and the flip
  cannot tell the two apart.
- **PER INDEX, not per parent TABLE.** `MP (ID PK, U UNIQUE)`, `MA`
  referencing `MP(ID)` (physically first, EMPTY), `MB` referencing
  `MP(U)` (holds the key). The engine REFUSES, naming `MB` on
  `("U" = 10)`. This is the wrong write: ending a walk at `MA` deleted
  the parent row and orphaned `MB`'s.
- **An index ROW, not a constraint.** `DC1`'s constraint dropped while
  its row still references the parent leaves `RDB$TEMP_DEPEND_129_0` in
  `RDB$INDICES`, physically ahead of the live `DK2`. The engine picks
  the leftover: `violation of FOREIGN KEY constraint "***unknown***"`.

### An action is a WRITE, not a waiver

The selected partnership is not skipped when it carries an action. The
engine's action is an AFTER trigger on the parent and the master-side
check reads the child once it has run, so a `CASCADE` or a `SET NULL`
passes because nothing is left to find. `SET DEFAULT` is the one rule
that can write the key straight back, and there the engine REFUSES:
`SC.B INTEGER DEFAULT 7 REFERENCES SP ON DELETE SET DEFAULT`, child row
`B = 7`, `DELETE FROM SP WHERE ID = 7` answers
`23000 / -Foreign key references are present for the record /
-Problematic key value is ("ID" = 7)`, the action having written 7 over
7. The `ON UPDATE SET DEFAULT` spelling behaves identically, and a
default that is a DIFFERENT key clears it and the DELETE goes through.
`fk_action_leaves_old_key` is that reading. **CLASSIFICATION: WRONG
WRITE (silent), NEW - the previous round's `if acts && fires { return
Ok(()) }` deleted that parent row.**

### The defects closed

- **A. HIGH, SILENT WRONG WRITE, NEW - an action on one key skipped the
  check on another.** `fk_check_parent_row`'s two `return Ok(())` ended
  the walk over ALL partnerships, including partnerships on a DIFFERENT
  referenced index. A parent with a PRIMARY KEY and a UNIQUE, an
  `ON DELETE CASCADE` child on the first and a plain child on the
  second: fire-crab deleted the parent, cascaded the first child away
  and orphaned the second; the engine refuses. Reproduced on an ordinary
  business schema (`ORD(ONUM UNIQUE, INVNO UNIQUE)`, `LINES` cascading,
  `PAYMENTS` restricting), on the UPDATE spelling, and with no NULL
  anywhere. `gfix -v -full` rc=0 on the file; `gbak` refuses to bring
  the restored copy online. On `79c4720` the same statements are refused
  and the two files AGREE, so this was NEW.
- **B. HIGH - the recorded law was false and asserted as measured.**
  Corrected in three places at once, because on this project the
  comments carry the law: `fk_check_parent_row`'s doc block, the
  withdrawn bullet in the round below, and the code. The doc block now
  carries the candidate laws, the shape that separates each of them, and
  a note of which shapes CANNOT decide it. The walk is gone:
  `fk_checked_partnerships` names the partnerships the check asks, one
  per `FkPartner::parent_index`, in list order - and
  `fk_partners_uncached` builds that list by walking `RDB$INDICES` in
  physical record order, which is the engine's own selector.
  **SUPERSEDED by the round above: `fk_checked_partnerships` is gone
  and fire-crab now asks EVERY partnership, deliberately. The law
  recorded here is still the ENGINE's, and it was proved by a shape
  this round did not have.**
  **CLASSIFICATION of the behaviour B caused on its own: OVER-REFUSAL,
  PRE-EXISTING (`79c4720` refuses the same shapes, differing only in the
  message). What blocked was the false law.**
- **C. MEDIUM, OVER-REFUSAL, NEW - a partly-NULL key rewritten with its
  own values.** The "did the key change" test required
  `!matches!(n, Value::Null)`, so a NULL component equal on both sides
  made the key look CHANGED; reachable only because the round below
  widened the OLD-key guard from `any(NULL)` to `all(NULL)`. Every SET
  list that so much as NAMED a column of a partly-NULL key refused, and
  took the row's other columns down with it - an ORM's whole-row
  `SET U1 = 10, U2 = NULL, X = 1` lost the `X = 1`. The test is now
  `IS DISTINCT FROM` (`fk_key_moved`): two NULLs are ONE key. It is not
  the same question as `fk_action_fires`, and the pair that separates
  them is `(10, 20) -> (10, NULL)`, which MOVES the key (so the check
  runs) and fires NOTHING (so the statement is refused).
- **AND THE SAME LAW ON THE CHILD SIDE - an UPDATE that leaves the key
  equal is not checked at all.** The engine checks a foreign key while
  maintaining the INDEX, and an unchanged key never touches the index,
  so a row already holding a key with no parent may be rewritten with
  that same key and the engine says nothing. Reachable, and it cost a
  parent DELETE: `B INTEGER DEFAULT 7 REFERENCES PZ ON DELETE SET
  DEFAULT` with a child row `B = 7`, on an index whose CHECKED
  partnership is a different, empty one. The action writes 7 over 7 -
  unchanged, unchecked - and the engine deletes the parent, leaving the
  child dangling. The contrast that pins it: the same shape with
  `DEFAULT 77` really moves the key and IS refused,
  `-Foreign key reference target does not exist ... ("B" = 77) -At
  trigger "PUBLIC"."CHECK_2"`. `fk_check_child_row` now takes the OLD
  row on an UPDATE and skips a partnership whose key did not move.
  **CLASSIFICATION: OVER-REFUSAL, introduced by the actions chunk** (on
  `79c4720` the whole parent DELETE was refused, so the two files
  agreed). It is what the eight-child matrix on a `gbak`-restored file
  was still diverging on after A and B were closed.

Gate: `qa/serve-real-fkaction.sh` grows from 78 checks to **118**, all
of section 13. Every shape above is in it, each annotated with the
candidate it rules out - the two-key wrong write and its UPDATE and
business-schema spellings, the `Q1`/`Q2`/`Q3` shape, the name and
relation-id and deferred-drop discriminators, the `gbak` physical-order
flip that decides it (built, refused, backed up, restored, and then
PERFORMED, with the two catalogs' orders printed on either side), the
eight-child one-rule-each matrix, both `SET DEFAULT`-writes-the-key-back
spellings with their clearing contrast, the child-side unchanged-key
pair, and C's four shapes. It is 118 OK / rc=0 on this tree, **95 OK /
23 DIFF on the previous round's binary** - every DIFF in section 13 -
and 43 OK / 75 DIFF on the `79c4720` binary.
`qa/serve-real-fkguard.sh`'s "SET NULL parent
DELETE" check ran a DELETE that matched no row (the preceding statement
had moved the key), so the path it named was never exercised; it now
puts a child row back on the moved key and deletes that, and the check
says so.

### Recorded, still open

- **MEDIUM, WRONG WRITE (silent), PRE-EXISTING - A `BEFORE` TRIGGER THAT
  MOVES THE REFERENCED KEY BYPASSES BOTH THE CHECK AND THE ACTION.**
  `crates/wire/src/server.rs` narrows `fk_children` to partnerships
  whose key columns the statement's SET LIST names, and a
  `BEFORE UPDATE` trigger writing `NEW.<key>` is invisible to that
  filter, so the partnership is dropped before either the check or the
  action can see it. With
  `CREATE TRIGGER T1 FOR P1 BEFORE UPDATE AS BEGIN NEW.U = NEW.U + 1000;
  END`, `UPDATE P1 SET X = 999` moves `U` from 10 to 1010: under no rule
  the engine REFUSES (a child holds 10) and fire-crab performs it; under
  `ON UPDATE CASCADE` the engine moves the child to 1010 and fire-crab
  leaves it DANGLING at 10. **Byte-identical on the `79c4720` binary**,
  and the narrowing predates the actions chunk unchanged. The narrowing
  is only sound if it is taken AFTER the BEFORE triggers have patched
  the row. Nothing in any gate holds it.
- **LOW, REFUSAL WITH AN INCOMPLETE VECTOR, PRE-EXISTING - a master-side
  FK refusal raised inside a PSQL body carries no `-At procedure`
  frame.** `EXECUTE PROCEDURE PR3(11)` where the body's UPDATE meets a
  no-rule master-side refusal answers the right `23000` and the right
  key, but the engine adds `-At procedure "PUBLIC"."PR3" line: 1,
  col: 43` and this server adds nothing; the DELETE spelling is the
  same. Byte-identical on the baseline. It is the path where the refusal
  comes from the GUARD rather than from a nested statement - the round
  below fixed the duplicated dash on frames that were present, not a
  frame that is never emitted.
- **A PARTLY-NULL KEY ON AN OPAQUE PARTNERSHIP IS ACCEPTED, and that is
  a decision.** `fk_check_parent_row`'s opaque branch asks
  `fk_partner_could_carry` only when every key column is non-NULL: the
  wide question ("does some row hold every one of these values in ANY
  column?") cannot be asked about a NULL, because no column "holds" one.
  A partly-NULL key therefore keeps the older, wider ACCEPTANCE there
  rather than a guess in either direction. This is behaviour-identical
  to `79c4720` for that shape (the old `any(NULL)` guard skipped it
  too), it reaches only a descriptor this server could not read at all,
  and it is stated here because the round below's `row_carries_key_at`
  bullet says the master side matches NULLs - which is true of the exact
  path and not of this last-resort one. Reasoned, not run: an opaque
  partnership with a partly-NULL multi-column key was not constructed.
- **A FUSED DOC COMMENT AT `user_triggers` / `db_triggers`,
  PRE-EXISTING** - the two doc blocks run together with the function
  between them missing. Identical at `79c4720`; the same family as the
  dangling half-sentence the round below restored, and left alone here
  so that this round's diff stays on its own subject.

## A REFERENTIAL ACTION FIRES ONLY WHEN ITS COMPARISON IS TRUE (2026-09-03) - the referential-actions fix round

The round that closed the one class this project will not ship. The
chunk that made fire-crab PERFORM referential actions (`ON DELETE` /
`ON UPDATE` CASCADE, SET NULL, SET DEFAULT) instead of refusing the
parent's DML is right in every shape three reviewers measured but one,
and that one turned a REFUSAL into a SILENT WRONG WRITE: before it, the
two servers' files AGREED on the shape and only the message differed;
after it they held different data and `gfix -v -full` called the file
clean.

- **A NEW KEY OF NULL PERFORMED THE ACTION INSTEAD OF REFUSING.**
  `crates/wire/src/server.rs` `fk_check_parent_row` and
  `fk_action_stmts` both guarded the OLD key against NULL (correct,
  MATCH SIMPLE) and neither guarded the NEW one, so
  `UPDATE P SET U = NULL` on a nullable referenced UNIQUE column with a
  child present CASCADED - the child key became NULL, or the column's
  DEFAULT under `SET DEFAULT`, which is the worst of the three because
  the row then holds a plausible, non-null, referentially valid value
  the engine never wrote. **CLASSIFICATION: WRONG WRITE (silent),
  introduced by the actions chunk.** The engine, measured 2026-09-03 on
  all four update rules with one child row present, REFUSES every one of
  them: `23000 / violation of FOREIGN KEY constraint ... / -Foreign key
  references are present for the record / -Problematic key value is
  ("U" = 10)`.
- **THE LAW IS NOT "a NULL new key refuses" - it is the engine's own
  trigger guard.** The synthesised `ON UPDATE` body is
  `IF (OLD.k1 <> NEW.k1 [OR OLD.k2 <> NEW.k2 ...])` (which
  `qa/serve-real-fkcascade.sh` already compares byte for byte), and `<>`
  against a NULL is UNKNOWN, not TRUE. So **an action fires exactly when
  SOME key column's NEW value is non-NULL and DIFFERS from its OLD one**;
  otherwise the statement falls to the master-side check, which refuses
  if any child still references the old key. On a two-column key the
  difference is decidable and was measured: the engine PERFORMS
  `SET U1 = 11, U2 = NULL` and `SET U1 = NULL, U2 = 21` (one comparison
  is TRUE, and the cascade carries the NULL into the child) and REFUSES
  `SET U1 = 10, U2 = NULL` and `SET U1 = NULL, U2 = NULL` (none is). A
  blanket "any NULL in the new key refuses" would have been its own
  regression on the first two. `fk_action_fires` is that one predicate,
  used by the check and by the statement builder so they cannot drift.
- ~~**A NON-FIRING ACTION PARTNER IS A RESTRICT PARTNER - and still ends
  the several-children walk.**~~ **THIS BULLET WAS FALSE AND IS
  WITHDRAWN.** Half of it stands: a partnership whose action does not
  fire IS checked exactly as a no-rule partnership is (`W1`, and the
  observation still holds). The other half - "an acting partner ends the
  walk" - was never measured. Every shape offered for it (`PA`-`PH`,
  `W2`, `W4`) has the deciding partner at `partner[0]`, or at
  `partner[1]` behind an empty `partner[0]`, so not one of them can tell
  that law from the engine's. The engine's law is per REFERENCED INDEX
  and is written out in the round below, together with the shapes that
  DECIDE it and the ones that cannot. The difference is a silent wrong
  write, and it was found by two reviewers, not by this bullet.
- **A PARTLY-NULL PARENT KEY IS STILL REFERENCEABLE** - the same
  asymmetry on the `ON DELETE` side, found by looking for it.
  `fk_check_parent_row` skipped a partnership when ANY key column was
  NULL; the engine skips only when EVERY one is. The two sides are not
  the same law: the CHILD side is MATCH SIMPLE (a NULL component
  references nothing, which is how such a child row gets in), while the
  MASTER side probes the child's INDEX, where a NULL is a storable key.
  Measured on `UNIQUE (U1, U2)`: parent `(10, NULL)` with child
  `(10, NULL)` REFUSES a DELETE, under no rule and under
  `ON DELETE CASCADE` / `SET NULL` alike (the action's `WHERE child.k =
  OLD.k` matches nothing, so the child survives and the check refuses);
  parent `(NULL, 20)` with child `(NULL, 20)` REFUSES; parent
  `(10, NULL)` with child `(NULL, NULL)`, and an all-NULL parent key,
  SUCCEED. **CLASSIFICATION: WRONG WRITE (silent), PRE-EXISTING - the
  no-rule spelling diverges identically on `79c4720` - but the actions
  chunk made it reachable through two more spellings, where it was a
  refusal before.** `row_carries_key_at` now takes which SIDE is asking;
  the child side is byte-for-byte what it was.
- **THE DEPTH CEILING IS REACHED BY ROW DATA, NOT BY SCHEMA, AND IT IS
  NOW THE ENGINE'S.** `MAX_FK_ACTION_DEPTH` was 16 with a doc comment
  justifying it as a stack guard, which reads as a property of the
  schema. It is not: ONE table with ONE self-referencing
  `ON DELETE CASCADE` - an org chart, a folder tree, a bill of materials
  - hit it on the seventeenth GENERATION OF ROWS, and the refusal
  reached the client as a bare `Dynamic SQL Error` because
  `ExecErr::Text` has no vector. The engine's own bound was bisected one
  generation at a time: a chain of **1001** rows cascades away whole,
  **1002** refuses with `SQLSTATE 54001 / Too many concurrent executions
  of the same request` (`isc_req_max_clones_exceeded`) and writes
  NOTHING. The limit is now 1001 - the same boundary expressed in this
  counter, which reaches N for a chain of N - and the refusal answers
  the engine's own status code. Verified at 1000/1001/1002 through both
  servers; a 1001-deep cascade completes in under a second on a
  connection thread's 16 MiB stack, and depth does not accumulate per
  ROW (1000 parents cascading one level each is depth 1). What still
  differs at 1002 is only the tail: the engine appends its 1000
  `At trigger` frames and this server appends none.
- **ONE EXTRA `-` ON THE ENCLOSING FRAME IS GONE.** A cascade that fails
  inside a PSQL body shipped the enclosing `At procedure` / `At trigger`
  frame as its OWN `isc_stack_trace` item, and isql prints a dash before
  each item; the engine ships the whole trace as ONE item with the
  frames on separate lines. `wrap_at_procedure` now continues the
  `EvalErr::InTrigger` string (`outer`) instead of wrapping it, and the
  emitter folds an inner `AtProcedure`'s own frames into the same
  string - which is the other half of the same defect, seen when a
  child's USER trigger raises inside the cascade. Four shapes now
  byte-identical, three controls with no FK anywhere unchanged.
- **THREE COMMENTS STATED THE REMOVED REFUSAL AS CURRENT LAW.**
  `check_predicates`' own doc comment (which also had a dangling
  half-sentence, pre-existing), `DmlGuard`'s doc, and the two comments
  above `plan_delete`'s `check_predicates` call. On this project the
  comments carry the law, and a reader auditing severity from them got
  the opposite of what the function does.

Gate: `qa/serve-real-fkaction.sh` grows from 27 checks to **78** - the
four update rules against a NULL new key (answer AND the engine reading
both files), the same four with NO children, which must keep succeeding,
a child whose own key is NULL, eight multi-column shapes that pin the
`OR` guard, the three several-children walk shapes, seven partly-NULL
parent-key shapes across `ON DELETE`, and the depth boundary at 1001 and
1002 with a non-leak check behind it. It is 78 OK / rc=0 on this tree
and 29 OK / 49 DIFF on the `79c4720` binary. (The round below takes it
to 118 and adds the section that decides the several-children law.)

### Recorded, still open

- **A NON-ASCII COLUMN `DEFAULT` IS DOUBLE-ENCODED, and it is the
  ceiling on `SET DEFAULT`'s correctness.** `CREATE TABLE PLAIN (A
  INTEGER, D VARCHAR(20) DEFAULT 'déf-ß')` then `INSERT INTO PLAIN (A)
  VALUES (1)` stores `dÃ©f-Ã` - 11 octets where the engine writes 7 -
  with NO error: the stored default's UTF-8 bytes are decoded as Latin-1
  and re-encoded. **CLASSIFICATION: WRONG WRITE (silent), PRE-EXISTING -
  byte-identical on `79c4720`, on a plain table with no foreign key
  anywhere.** It matters here because `fk_child_default` reads the same
  defaults, so `SET DEFAULT` is correct exactly as far as the shared
  default reader is; through the FK path the corruption is CAUGHT
  (the mojibake value has no parent row) and surfaces as a spurious
  refusal rather than a silent write, which is the only reason the
  action measurements did not see it - every one of them used an ASCII
  default. The KEY path is genuinely right: a non-ASCII text key moved
  by `ON UPDATE CASCADE` is byte-for-byte the engine's, which is what
  the parameter design bought.
- **THE `CHECK_<n>` COUNTER RUNS IN THE OPPOSITE ORDER when one `CREATE
  TABLE` carries both a referential action and a CHECK.** For
  `CREATE TABLE CU (A INTEGER, B INTEGER DEFAULT 9 REFERENCES PU ON
  DELETE SET DEFAULT, CONSTRAINT CK_U CHECK (B < 5))` the engine draws
  the FK ACTION trigger on the PARENT first (`CHECK_1 PU type 6 sysflag
  4`, then the child's two CHECK triggers); fire-crab draws the child's
  CHECK triggers first and the action trigger last. **CLASSIFICATION:
  WRONG WRITE (catalog, silent), PRE-EXISTING - identical on
  `79c4720`.** Newly VISIBLE, not newly wrong: before the actions chunk
  the parent's DML was refused outright, so the names never reached a
  user; now they appear in every failure vector as `-At trigger
  "PUBLIC"."CHECK_<n>"`. It is the same family as `79c4720` itself ("A
  generated name comes from a COUNTER, drawn in the order the engine
  walks the statement") and is a residual gap in exactly that law.
  `qa/serve-real-fkcascade.sh`'s tables carry no CHECK constraint, so no
  gate holds it.
- **A MULTIBYTE LITERAL IN A `WHERE` SILENTLY MATCHES NOTHING.**
  `UPDATE T2 SET V = 5 WHERE K = 'sör'` on `K VARCHAR(10) NOT NULL
  PRIMARY KEY` holding `'sör'` is a silent no-op with no diagnostic; the
  engine performs it. **PRE-EXISTING** (identical on `79c4720`, on a
  plain table with no foreign key), and the worst class. Unrelated to
  the actions chunk but nothing holds it.
- **A DUPLICATE UNDER A `COLLATE UNICODE_CI` PRIMARY KEY IS ACCEPTED.**
  fire-crab writes `'ABC'` next to `'abc'`; the engine refuses with
  `violation of PRIMARY or UNIQUE KEY constraint`. The same blindness
  refuses a VALID FK insert (`'ABC'` referencing a parent `'abc'`) with
  `Foreign key reference target does not exist`. **WRONG WRITE (silent),
  PRE-EXISTING** - reproduced with no foreign key present at all and
  identically on `79c4720`. It silently writes a duplicate into a unique
  index and deserves its own chunk.
- **`ON UPDATE`/`ON DELETE RESTRICT`, `UPDATE ... ORDER BY` / `... ROWS`,
  `CREATE TRIGGER` with a bodyless-column-list `INSERT` or the `ACTIVE`
  keyword, `NUMERIC(9,2) DEFAULT 3.25`, `DEFAULT (3+4)`, and DDL parse
  rejections generally answer a bare `Dynamic SQL Error` where the
  engine gives `-SQL error code = -104 / -Token unknown - ...`.**
  All PRE-EXISTING and confirmed against `79c4720`; each is why an
  adversarial probe of the action machinery cannot be written entirely
  in fire-crab's own DDL.
- **BLOB-ID NUMBERING within a page differs from the engine's** (`80:2`
  vs `80:1`), reproducible with two plain INSERTs into a table with no
  FK - PRE-EXISTING, cosmetic.
- **The FK INDEX of an unnamed inline `REFERENCES` is named after the
  constraint (`INTEG_<n>`) instead of `RDB$FOREIGN<n>`** - already
  recorded under the metadata-name-counter round, independently
  reproduced twice more this round.

## The metadata name counters (2026-09-02) - the fix round

Every name the engine invents - a new relation's id, an auto-domain
`RDB$<n>`, `RDB$PRIMARY<n>` / `RDB$<n>` for an unnamed index, `INTEG_<n>`
for an unnamed constraint, an identity column's implicit generator -
comes from a system GENERATOR (`RDB$RELATIONS`, `RDB$INDEX_NAME`,
`RDB$CONSTRAINT_NAME`, `RDB$FIELD_NAME`, `RDB$GENERATOR_NAME`), and a
generator only ever moves forward. fire-crab derived the same names by
scanning the catalog for the highest one in use and adding one, so after
the first DROP the two servers named every later object differently -
and on a file both write, fire-crab handed out the very number the
engine's counter was about to issue. The counters are now the source
(`crates/ods/src/ddl.rs` `draw_from_counter`). What the review round
closed on top of that:

- **A COMMIT WHOSE DISK WRITE FAILS NOW REPORTS AN ERROR.** `crates/wire/src/server.rs` `end_transaction` traced the commit's own `Err` under `FC_SRV_TRACE` and returned `()`, so the wire answered a clean `op_response`: a transaction whose flush failed was reported COMMITTED and everything it did was lost with nothing on disk - measured on a file whose write permission was removed AFTER the attachment opened (`INSERT` + `COMMIT` and `CREATE TABLE` + `COMMIT`, both silent, both absent when the ENGINE read the file). It now returns `Result` and both wire callers answer `isc_io_error("write", <file>)` + the reason as `isc_random` (`respond_write_failed`). This is the invariant the whole chunk is about: a statement either does what it says and reports success, or reports an error.
- **`INTEG_<n>` NAMES ARE DRAWN IN TWO PASSES** (superseding this chunk's own first answer, which was "one strict declaration order", which in turn superseded "every NOT NULL first, then every key"). The law, measured on the engine 2026-09-03: **every COLUMN-LEVEL (inline) constraint first - the columns in declaration order and, within one column, its clauses in written order - then every TABLE-LEVEL clause, in declaration order.** `(A INTEGER, UNIQUE (A), B INTEGER UNIQUE)` is the decisive shape: `B`'s inline UNIQUE is written LAST and numbered FIRST, which no single-pass text order can produce. `(A INTEGER CHECK (A > 0), B INTEGER NOT NULL, CHECK (B < 100), C INTEGER UNIQUE)` shows it again with CHECKs, and `(A INTEGER UNIQUE NOT NULL, ...)` vs `(A INTEGER NOT NULL UNIQUE, ...)` shows that WITHIN one column it is plain text order. A column-level PRIMARY KEY implies its NOT NULL and the implied row is numbered just BEFORE the key, wherever the explicit `NOT NULL` is written (`A INTEGER PRIMARY KEY NOT NULL` is NOT NULL then PRIMARY KEY). Under either superseded rule `INTEG_4` named a different constraint on the two servers' copies of one file. `TableConstraint::cols_before` - one number that conflated "which pass" with "which column" and carried no within-column position at all - is replaced by `ConstraintPlace::{Inline { col, at }, Table { decl }}` beside `ColumnDef::not_null_at`, and `constraint_steps` sorts pass 1 by `(col, at)` and pass 2 by `decl` (eight shapes plus eight edge shapes measured against the engine through 127.0.0.1/3050, both files read back BY the engine, byte-identical).
- **THE LAW COVERS FOREIGN KEYS TOO - a FK is numbered WHERE IT IS WRITTEN, not last** (measured 2026-09-03, same method). A FOREIGN KEY is the fourth KIND of constraint, not a fourth thing that comes after everything else: `(A INTEGER, B INTEGER, FOREIGN KEY (A) REFERENCES P, UNIQUE (B))` is FOREIGN KEY then UNIQUE and the same pair swapped in the text is swapped in the answer, `(..., FOREIGN KEY (A) REFERENCES P, CHECK (B > 0))` is FOREIGN KEY then CHECK, and an INLINE `REFERENCES` is a PASS-1 clause - `(A INTEGER, UNIQUE (A), B INTEGER REFERENCES P)` numbers the FK FIRST though it is written LAST, the same inversion as `(A INTEGER, UNIQUE (A), B INTEGER UNIQUE)`. The foreign keys travel in their OWN vector, so vector order alone cannot say which of two table-level clauses of DIFFERENT kinds came first; `ConstraintPlace::Table` therefore carries an explicit `decl` rank (the item's index in the column list) that both vectors are merged on. `ForeignKeyDef` carries a `place` like `TableConstraint` does, `ConstraintStep::Fk(i)` puts the FK in the walk, and `create_table` writes the FK row FROM that walk instead of from a trailing loop. The engine writes an FK's backing INDEX in the same place (`(..., FOREIGN KEY (A) REFERENCES P, UNIQUE (B))` gives the FK index id 1 and the UNIQUE index id 2), and it applies the partner lookup in that order too - a self-referencing `(A INTEGER NOT NULL, B INTEGER, FOREIGN KEY (B) REFERENCES SELF (A), PRIMARY KEY (A))` is REFUSED by the engine and accepted when the PRIMARY KEY is written first, which fire-crab now reproduces.
- **A COLUMN-LEVEL `REFERENCES` now parses** (`B INTEGER REFERENCES P`, `A INTEGER REFERENCES P`, `B INTEGER REFERENCES P (ID)`, with `CONSTRAINT <name>`, with `ON DELETE`/`ON UPDATE` actions, and with a NOT NULL / key / CHECK clause written after it). It was refused outright with a bare `Dynamic SQL Error` - `parse_fk_clause` demanded a literal `FOREIGN KEY` prefix, so the fourth kind of column-level constraint had no parse path at all. It desugars the way an inline CHECK does: `inline_references_span` finds the clause in the masked item text and it is cut in the SAME rewrite as the inline CHECKs (offsets on the ORIGINAL item text, so a column carrying both, in either order, keeps both), then `parse_inline_references` builds a `ForeignKeyDef` on the column being declared, sharing `parse_references_tail` with the table-level clause so the "no column list means the parent's PRIMARY KEY" rule is not restated.
- **AN INLINE `CHECK` NO LONGER SWALLOWS THE REST OF ITS COLUMN, AND IS FOUND ON ANY COLUMN.** The inline-CHECK split took `item[at..]` as the whole check clause, so `A INTEGER CHECK (A > 0) NOT NULL` and `... NOT NULL UNIQUE` - which the engine accepts - were refused whole with a bare `Dynamic SQL Error`; and it measured `at` in the item's TRIMMED text while slicing the UNTRIMMED one, so an inline CHECK was only ever recognised on the FIRST column of the list (`(A INTEGER, B INTEGER CHECK (B > 0))` was refused; a NAMED inline CHECK and a second CHECK on one column likewise). The split now runs on the trimmed item, ends each clause at its own closing parenthesis, takes every clause rather than the first, and keeps a `CONSTRAINT <name>` prefix with the clause it belongs to. All six spellings measured identical to the engine.
- **A DROPPED FK CONSTRAINT NO LONGER MAKES THE PARENT UN-WRITABLE.** `ALTER TABLE ... DROP CONSTRAINT <fk>` leaves a segment-less `RDB$TEMP_DEPEND_<rel>_<n>` index on BOTH servers; `fk_partners_uncached` returned `None` for the WHOLE table on it, so every `INSERT` into the parent refused at prepare, for ever. One unusable index row is now skipped instead.
- **`DROP INDEX X` THEN `CREATE INDEX X` WORKS.** The reported cause (a back version seen by `index_name_taken`) is NOT the mechanism: the trace says `duplicate key in unique index`. `DROP INDEX` renames the `RDB$INDICES` row, an index entry outlives the version that wrote it, and the unique check asked only whether the record the conflicting entry names is still LIVE - which it is, under its new name. `btw::insert_index_entry_checked` now takes the caller's test of whether that record STILL BUILDS the key (the engine's own duplicate scan, idx.cpp), and `maintain_indexes` rebuilds it with the code that built the key being inserted; a caller that cannot rebuild one answers "still keyed", so a genuine duplicate still refuses.

Gate: `qa/serve-real-ddlsequence.sh` (25 checks) now compares relation
IDS, every `RDB$RELATION_CONSTRAINTS` row and the column each NOT NULL
names, the auto-domain `RDB$FIELD_SOURCE` of every user column, the user
generators, and THE FIVE COUNTERS through `GEN_ID` - and makes a
commit's write fail on purpose. It failed 1 of 13 checks on the
pre-change binary before, and fails 8 of 25 now.

### Recorded, still open

- **A FAILED DDL STATEMENT REWINDS THE COUNTERS; THE ENGINE KEEPS THE NUMBERS IT CONSUMED.** `draw_from_counter`'s `gen::write` lands in the statement's work image, which a failed statement discards. Measured: two domains, two all-domain tables, then a `CREATE TABLE PC (ID INTEGER, N NOSUCHDOMAIN)` that fails on every server - the engine's failed statement consumes one relation id and one auto-domain name (the next table is id 131 with `RDB$2`, counters ending 137/32), fire-crab consumes none (id 130, `RDB$1`, 136/31). Not a collision risk (a drawn run steps over anything already in the catalog) but a systematic divergence in exactly the quantity this chunk makes authoritative, so "a fire-crab-built database is name-identical to the engine's" holds only for statements that all succeed.
- **`ALTER TABLE ... ADD <col> INTEGER NOT NULL` is refused on an EMPTY table the engine accepts** (pre-existing, twinned).
- **`CREATE INDEX` on a column added by `ALTER TABLE ... ADD` is refused when the table HOLDS ROWS** (pre-existing, identical at HEAD; re-measured 2026-09-03). This was previously recorded as a cascade of the entry above, which it is not - it needs neither `NOT NULL` nor an integer type, only rows: `CREATE TABLE QN (ID INTEGER)` + one row, `ALTER TABLE QN ADD S VARCHAR(5)` (accepted), then `CREATE INDEX QNIX ON QN (S)` -> `42000 Dynamic SQL Error`, where the same three statements on an EMPTY table are all accepted and the engine accepts every one of them either way.
- **`RDB$TEMP_DEPEND_<rel>_<id>` rows accumulate** where the engine eventually removes them (reusing the dropped index's name removes the engine's at once). After one DROP INDEX the two files agree exactly; over a script with several, fire-crab keeps every stub. `qa/serve-real-ddlsequence.sh` excludes them from its index comparison for this reason.
- **A VARCHAR projected through a fire-crab-created VIEW DESCRIBES too wide** (pre-existing, twinned on the pre-change binary; values identical). `CREATE VIEW V3 AS SELECT ID, A + 1 AS AP1, B FROM T1` over `B VARCHAR(20)` in a UTF8 database: `RDB$FIELDS` agrees exactly (length 80, character length 20, charset 4) but the ENGINE reading fire-crab's file renders the column 80 characters wide against 20 on its own, so the stored view FORMAT descriptor is missing the bytes-per-character factor. `CHAR_LENGTH` and `OCTET_LENGTH` of the same values are 1 on both files - the data is right and only the description is wide.
- **The unnamed FOREIGN KEY index is named after its constraint instead of `RDB$FOREIGN<n>`**, so fire-crab draws NO index number for it and the shared `RDB$INDEX_NAME` counter is left one behind the engine's for every generated index name afterwards (a DIFFERENT counter from the `INTEG_<n>` one, which now matches on every measured shape; `qa/serve-real-key.sh`'s FK-shape check therefore compares the constraint names and leaves the index names out); `DROP TABLE` leaks an identity column's implicit generator; an identity PRIMARY KEY gets an extra NOT NULL constraint row the engine does not write.

## AN EXACT KEY, AND A NAME THAT ENDS IN A BLANK (2026-09-03) - the sixth fix round

The round that makes round five's two new checks precise. Both of them
worked; both also refused things the engine takes, and one of those was
severe in ordinary schemas. Nothing else was started.

### A. HIGH, over-refusal - the parent-side check after a dropped constraint is now EXACT

`crates/wire/src/server.rs` `fk_partners_uncached` (the parent arm),
`index_root_key_fids`, `row_carries_key_at`, `fk_check_parent_row`.

Round five stopped fire-crab DELETING a parent row the engine keeps
after `ALTER TABLE <child> DROP CONSTRAINT <fk>`. Because the drop takes
the `RDB$INDEX_SEGMENTS` rows with it, that fix could not say WHICH
child columns had keyed on the parent and asked the widest sound
question instead - "does some child row hold this key's values in ANY
column". Sound, and far too wide to ship. The most ordinary child table
anyone writes lost two of three parent rows, measured on both servers,
one row in the child:

```
CREATE TABLE P (ID INTEGER NOT NULL PRIMARY KEY, T VARCHAR(10))
CREATE TABLE ORD (OID INTEGER, STATUS INTEGER, QTY INTEGER, PID INTEGER,
                  CONSTRAINT FKO FOREIGN KEY (PID) REFERENCES P)
INSERT P (1,'a'),(2,'b'),(3,'c');  INSERT ORD (100, 2, 3, 1);  ALTER TABLE ORD DROP CONSTRAINT FKO

                             BEFORE fc                       AFTER fc   engine
DELETE FROM P WHERE ID = 2   ERR ***unknown*** (STATUS = 2)   OK         OK
DELETE FROM P WHERE ID = 3   ERR ***unknown*** (QTY = 3)      OK         OK
DELETE FROM P WHERE ID = 1   ERR ***unknown***                ERR        ERR
SELECT COUNT(*) AS NP FROM P 3                                1          1
```

**Where the key columns actually are.** `deferred_drop_index`
(`crates/ods/src/ddl.rs`) - and the engine's own deferred drop - deletes
the segment ROWS and moves the index-root slot to `irt_drop` **keeping
its root page and its per-segment descriptors**. Those descriptors are
what the surviving B-tree is keyed on, which is exactly why the ENGINE
goes on refusing a genuinely referenced key from a constraint whose
catalog rows are gone: it enforces from that tree. So the parent arm now
reads the child's key field ids straight off the descriptor -
`RDB$INDICES.RDB$INDEX_ID - 1` is the slot, `btw::index_segments` reads
it - and the parent-side test is the ordinary exact one,
`row_carries_key_at` on THOSE columns, resolved through the same
`fk_partner_lookup` B-tree probe every other partnership uses. A slot is
never re-used while its root page stands (`allocate_index_slot` takes
the first slot with NO root page, a deferred drop keeps its own), and an
id two rows of one relation claim is not trusted.

`row_could_carry_key`, the wide test, survives as the LAST RESORT only -
reached when the descriptor cannot be read at all, where the choice is
between it and no check. It was not reached on any measured shape.

Both halves that were already right are kept, and asserted: the CHILD
arm still skips the segment-less row, so an orphan `INSERT` into the
dropped-constraint child is still accepted (the engine accepts it too),
and a genuinely referenced parent key is still refused with the engine's
own `Violation of FOREIGN KEY constraint "***unknown***"`.

**23 FK cases / 212 statements, each on its own pair of databases, fire-
crab and the engine statement for statement** (the round-5 reviewer's
corpus, reconstructed and re-run): **2 DIFFs, both the recorded
FIRST-FK-WINS engine quirk** (`F9_two_fks_one_dropped`: with one FK
dropped and one live, fire-crab refuses on the live FK where the engine
accepts and orphans the child - fire-crab is STRICTER and correct, and
must not be "fixed"). Every over-refusal the reviewer measured is gone:
the `STATUS`/`QTY` shape, a `VARCHAR` holding the key's digits, a
`DOUBLE` holding the same magnitude, a pad-different `CHAR`, an unrelated
`INTEGER` column holding the key. Every refusal that was right is kept:
the referenced key after the drop, the key UPDATE, the compound-key
shape, drop-then-re-add, `ON DELETE CASCADE` then dropped.

### B. MEDIUM, over-refusal - a delimited name's TRAILING BLANKS are not part of it

`crates/wire/src/server.rs`, the `"` arm of `stmt_name_too_long`.

The engine strips trailing blanks BEFORE applying the 63-character
limit, so a 64-character delimited name whose last character is a blank
is a legal 63-character name there - and both servers already store such
a name trimmed (`CREATE TABLE "AB  "` is reachable afterwards as `AB` on
either), so the check was refusing a name its own writer would have
written correctly. It never reached the gbak restore path (a backup
carries the already-trimmed 63), which is why every gate stayed green.

The scan now counts up to the LAST NON-BLANK character. 18 shapes, each
on a fresh pair of databases, after:

```
"<63> "                      fc OK   eng OK      "<64> "                    fc ERR  eng ERR
"<63><37 blanks>"            fc OK   eng OK      "<31> <32>" (internal)     fc ERR  eng ERR
column "<63> "               fc OK   eng OK      column "<64> "             fc ERR  eng ERR
"<60>  <1>" (blank run, 63)  fc OK   eng OK      "<61>  <1>" (64)           fc ERR  eng ERR
"<62>""<blank>" (dq, 63)     fc OK   eng OK      "<63>""<blank>" (dq, 64)   fc ERR  eng ERR
"<62><TAB>" (63)             fc OK   eng OK      "<63><TAB>" (64)           fc ERR  eng ERR
```

A trailing TAB is NOT stripped by either server - measured, not assumed.

**And a name of nothing but blanks is not a name.** Trimming the
trailing blanks cannot be allowed to trim the whole identifier away:
before this, `CREATE TABLE "<80 blanks>" (A INTEGER)` was written, the
engine read the relation back as `[               ]` and `gfix -v -full`
then reported 2 database page warnings on the file. Both servers now
refuse every blank-only delimited name at every length; only the message
text differs, and that is recorded below.

### Recorded, still open - what this chunk did NOT start

Everything the round-5 list carries is still open and still true, with
one entry replaced (the opaque residual). New:

- **LOW (residual of THIS round's own fix A, disclosed) - the last-resort
  wide scan.** `crates/wire/src/server.rs` `fk_partner_could_carry`. When
  a deferred-drop index's index-root descriptor cannot be read - no root
  page, a zero key count, an unreadable page - the parent-side check
  falls back to "does some child row hold this key in ANY column", which
  can refuse a parent DELETE the engine takes. It was not reached on any
  measured shape (23 FK cases / 212 statements, the `dropconstraint`,
  `fk*` and `key` gates), and it is preferred to the alternative, which
  is no check and a deleted row. Closing it means deciding what a
  descriptor this server cannot read should mean, which is a question
  about `btw`, not about DML.

- **ENGINE OBSERVATION, corrected and sharpened - what actually ENDS the
  engine's enforcement of a dropped constraint is the next WRITE TO THE
  CHILD.** Round 5 recorded that the engine "eventually" clears
  `RDB$FOREIGN_KEY` on the deferred-drop row and stops enforcing, while
  fire-crab never clears it, so fire-crab's window is permanent. The
  trigger is now measured exactly - it is not time, and it is not a
  sweep:

  ```
  ... DROP CONSTRAINT FKX, then on the ENGINE:
  RDB$TEMP_DEPEND_129_0 | CX | fk=RDB$PRIMARY1 | ina=4     <- still enforcing
  INSERT INTO CX VALUES (8, 2)                             <- ONE write to the child
  RDB$TEMP_DEPEND_129_0 | CX | fk=NULL         | ina=4     <- cleared
  DELETE FROM P WHERE ID = 1    OK on the engine, and CX still holds B = 1
  ```

  So after any write to the dropped-constraint child, the engine deletes
  a referenced parent row and LEAVES THE CHILD ORPHANED, while fire-crab
  goes on refusing. Measured as 5 statement divergences over 8 further FK
  cases (`Z3_row_inserted_AFTER_the_drop_still_references`,
  `Z5_child_key_UPDATED_after_the_drop`); fire-crab is the STRICTER side
  in every one, exactly as with the first-FK-wins quirk, and this is NOT
  a divergence to "fix". It is also unchanged by round 6's fix: the exact
  test is a strict subset of the wide one it replaces, so no shape that
  round 5 accepted can be newly refused.

- **LOW (message, PRE-EXISTING, unchanged this round) - the engine's
  `Name longer than database column size` is not reproduced on the fourth
  call site.** `crates/wire/src/server.rs` `run_dyn_statement` returns
  `PsqlStop::Unsupported`. Both servers REFUSE, so no wrong write; only
  the diagnostic is lost:

  ```
  EXECUTE BLOCK AS BEGIN EXECUTE STATEMENT 'CREATE TABLE <63 x G> (A INTEGER)'; END
      fc OK    eng OK
  EXECUTE BLOCK AS BEGIN EXECUTE STATEMENT 'CREATE TABLE <64 x K> (A INTEGER)'; END
      fc ERR "Dynamic SQL Error"
      eng ERR "... -104, Name longer than database column size, At line 1, column 14,
               At block line: 1, col: 24"
  ```

- **LOW (over-acceptance, PRE-EXISTING) - a bare CR ends a `--` comment
  on the engine, not in the scanner.** `crates/wire/src/server.rs`, the
  `--` arm of `stmt_name_too_long` scans `while b[i] != '\n'`, while the
  same function's own `step!` macro treats a lone `\r` as a line break -
  which is how it gets the engine's `(line, column)` right. So the two
  halves disagree about what CR means:

  ```
  SELECT 1 AS N FROM RDB$DATABASE WHERE 1 = 1 -- c\rAND <64 x K> = 1
      fc  ROWS [{"N":1}]   (the whole tail eaten as comment)
      eng ERR -104 Name longer than database column size, At line 2, column 5
  ```

  No wrong WRITE is reachable through it: `entry_strip_comments` has the
  same blind spot and turns the DDL shapes into refusals instead
  (`CREATE TABLE CRT (A INTEGER, -- c\rB INTEGER)` - fc ERR, eng OK, a
  pre-existing over-refusal). Both halves are rooted in the comment
  stripper, not in the length check.

- **LOW (message, NEW in round 5) - an exotic divergence at 64
  supplementary-plane characters.** Same accept/refuse split, same code
  and column, different text:

  ```
  CREATE TABLE "<63 x U+1F600>" (A INTEGER)   fc OK   eng OK
  CREATE TABLE "<64 x U+1F600>" (A INTEGER)   fc ERR "-104 Name longer than database column size,
                                                      At line 1, column 14"
                                              eng ERR "-104 Token size exceeds limit,
                                                      At line 1, column 14"
  ```

- **LOW (message, NEW in round 6) - a blank-only delimited name is
  refused with the wrong text.** fire-crab answers `-104 Name longer than
  database column size`; the engine answers `-104 Zero length identifiers
  not permitted`. Same code, same accept/refuse split on every shape
  measured (`"   "`, `"  "` as a column name, 80 blanks); only the text
  differs. An EMPTY delimited run (`""`) is left to the generic
  `Dynamic SQL Error` it already had - the engine refuses that one too.

- **LOW (over-refusal, PRE-EXISTING, length-independent) - a delimited
  CONSTRAINT, INDEX or DOMAIN name containing a blank is refused
  outright.** Nothing to do with the limit - measured at THREE characters,
  each on its own pair of databases:

  ```
  CREATE TABLE "AB  " (A INTEGER)                                fc OK   eng OK
  INSERT INTO AB VALUES (1)                                      fc OK   eng OK
  CREATE TABLE SPC3 ("CD " INTEGER)                              fc OK   eng OK
  CREATE INDEX "IX1 " ON SPC3 (CD)                               fc ERR  eng OK
  CREATE DOMAIN "DM1 " AS INTEGER                                fc ERR  eng OK
  CREATE TABLE SPC4 (A INTEGER, CONSTRAINT "CN1 " CHECK (A > 0)) fc ERR  eng OK
  ```

  Table and column names take a blank on both servers; those three paths
  do not. It is the quoted-name parser on those paths, not
  `stmt_name_too_long`, and it is the one DIFF left in the 18-shape
  trailing-blank sweep.

## A NAME MUST FIT, AND A DROPPED CONSTRAINT HAS TWO SIDES (2026-09-03) - the fifth fix round

The round that closes what the fourth one broke. Two regressions this
chunk itself caused, two neighbours small enough to fix beside them, and
everything else recorded rather than started. Every finding below was
reproduced first, on the unmodified tree, and re-measured after.

- **AN IDENTIFIER MAY BE 63 CHARACTERS AND NO MORE - on every naming path, counted in CHARACTERS.** `crates/wire/src/server.rs:55888` `stmt_name_too_long` (the refusal's vector at `:13992` `respond_name_too_long`, `GDS_DYN_NAME_LONGER` = DYN 159 = 336068767), called beside `has_unknown_space` at the three places a statement's text arrives (`op_prepare` and both `op_exec_immediate` sites) and in `run_dyn_statement` for a PSQL `EXECUTE STATEMENT`. `grep -n "Name longer than\|MAX_IDENT\|> 63"` over `server.rs` and `ddl.rs` used to find **no length check anywhere**: fire-crab wrote the object with its name silently CUT to 63.

  **CLASSIFICATION: WRONG WRITE (silent), HIGH.** Mostly PRE-EXISTING - table names, column names and table-level constraint names all wrote truncated at HEAD `b80c5e6` - but **two spellings were NEW in round 4**, `A INTEGER CONSTRAINT <64+> CHECK (A > 0)` and `A INTEGER CONSTRAINT <64+> REFERENCES P`, which HEAD refused outright and round 4 taught `constraint_prefix_start` to parse without a length check.

  **THE BOUNDARY, MEASURED (2026-09-03, engine at `127.0.0.1/3050`, 30 naming paths x two lengths).** At 63 both servers accept, at 64 the engine answers `-104` / `Name longer than database column size`, on: table, column, domain, index, generator, sequence, view, exception, trigger, procedure, table-level `PRIMARY KEY` / `UNIQUE` / `FOREIGN KEY` / `CHECK` constraint names, the INLINE `CONSTRAINT <n> CHECK` / `REFERENCES` / `UNIQUE` ones, `ALTER TABLE ADD CONSTRAINT`, `ALTER TABLE ADD <column>`, and the QUOTED spelling of each. It is not a DDL rule but a LEXICAL one - `SELECT <64> FROM T`, `SELECT A AS <64> FROM T`, `FROM <64>`, `FROM T "<64>"` and `INSERT INTO T (<64>)` take the same refusal - which is why ONE check at the text boundary closes all thirty paths at once rather than 118 `canon_ident` call sites. **The limit counts CHARACTERS, not bytes**: a quoted name of 63 `Ä` is 126 bytes and accepted by both, 64 of them refused by both, so a byte test would have refused names the engine takes.

  **WHAT IT COST.** Two names differing only past character 63 became ONE catalog row, and the database could not be restored:

  ```
  CREATE TABLE CT (A INTEGER CONSTRAINT <62K>A1 CHECK (A > 0),
                   B INTEGER CONSTRAINT <62K>A2 CHECK (B > 0))
  fire-crab: OK        gfix -v -full: rc=0        gbak backup: rc=0
  gbak restore: rc=1
    gbak: ERROR:violation of PRIMARY or UNIQUE KEY constraint "RDB$INDEX_69"
          on table "SYSTEM"."RDB$RELATION_CONSTRAINTS"
  ```

  Five tables declared with distinct 64-character names became one row in `RDB$RELATIONS` (`TOTAL 5 / DISTINCT_NAMES 1`), with `gfix -v -full` rc=0 on every one of them.

  **The message is the engine's, byte for byte**, including the position - the same isql output from both servers on five shapes, one of them spanning three lines:

  ```
  Statement failed, SQLSTATE = 42000
  Dynamic SQL Error
  -SQL error code = -104
  -Name longer than database column size
  -At line 1, column 14
  ```

- **A SEGMENT-LESS DEFERRED-DROP INDEX ROW IS NOT THE SAME ANSWER ON THE TWO SIDES.** `crates/wire/src/server.rs:13128` `fk_partners_uncached`, the parent arm; `FkPartner::opaque`; `:13459` `fk_partner_could_carry` / `:13476` `row_could_carry_key`; `:13488` `fk_check_parent_row`.

  **CLASSIFICATION: a REFUSAL that round 4 turned into a WRONG WRITE, HIGH. NEW in this chunk** - and it went in undisclosed, in a hunk (`server.rs:13225`, "ONE UNUSABLE INDEX ROW IS SKIPPED, NOT FATAL TO THE TABLE") that appears in none of round 4's per-defect sections, none of its "files changed" list and nowhere in this file. That is how it survived a whole review round; it is written down now.

  `ALTER TABLE <child> DROP CONSTRAINT <fk>` leaves the child's index row behind as `RDB$TEMP_DEPEND_<rel>_<n>`, `RDB$INDEX_INACTIVE = 4`, `RDB$SEGMENT_COUNT` intact, its `RDB$INDEX_SEGMENTS` rows deleted, and `RDB$FOREIGN_KEY` **still naming the parent's unique index**. Both servers write exactly that row - the two catalogs are identical after the drop - and **the engine goes on enforcing from it**. Round 4 made the row skippable so the CHILD's own DML would stop refusing (right, and measured); the same skip on the PARENT side deleted a row the engine keeps:

  ```
  CREATE TABLE P (ID INTEGER NOT NULL PRIMARY KEY)
  CREATE TABLE CX (A INTEGER, B INTEGER, CONSTRAINT FKX FOREIGN KEY (B) REFERENCES P)
  INSERT P(1),(2),(3); INSERT CX(40,1); DELETE FROM P WHERE ID=2
  ALTER TABLE CX DROP CONSTRAINT FKX
  DELETE FROM P WHERE ID = 1

  HEAD b80c5e6  ERR Dynamic SQL Error                   -> parent row survives (wrong reason)
  round 4       OK                                      -> PARENT ROW DELETED
  engine        ERR Violation of FOREIGN KEY constraint "***unknown***" on table "PUBLIC"."CX"
                                                        -> parent row survives
  ```

  The two directions now have their own answers, which one flag could not carry. The child arm still skips the row (an orphan `INSERT INTO CX` is accepted by both servers). The parent arm keeps it as an **opaque** partnership: it refuses, with the engine's own vector and its own name for a constraint whose row is gone. Since the catalog no longer records WHICH of the child's columns keyed on the parent, the parent-side test widens from "does a child row hold this key in THESE columns" to "does some child row hold every one of the key's values in ANY of its columns" - **sound** (the real key columns are among "any", so a genuine reference is never missed) and, on the whole reproducer, statement-for-statement identical to the engine:

  ```
                            fire-crab   engine
  DELETE FROM P WHERE ID=3    OK          OK       <- no child carries 3
  DELETE FROM P WHERE ID=1    ERR ***unknown***    <- CX(40,1) carries 1
  UPDATE P SET ID=9 WHERE ID=1 ERR ***unknown***
  INSERT INTO CX VALUES (41,999) OK        OK      <- the child is free of it
  INSERT P(7); DELETE FROM P WHERE ID=7  OK  OK
  SELECT COUNT(*) FROM P       1           1
  SELECT COUNT(*) FROM CX      2           2
  ```

  Its residual is recorded below rather than claimed away.

- **`ON UPDATE`/`ON DELETE RESTRICT` IS REFUSED.** `crates/wire/src/server.rs:22207` `parse_ref_actions`. **CLASSIFICATION: OVER-ACCEPTANCE, HIGH.** Pre-existing on the table-level form, newly reachable inline (HEAD refused every inline referential action). `RESTRICT` is the value Firebird **stores** in `RDB$REF_CONSTRAINTS` for an omitted clause; it is not a word its parser accepts - `ON DELETE RESTRICT` is `-104 Token unknown - RESTRICT` on the engine, in all five spellings measured (inline, table-level, named, both events, `ALTER TABLE ADD CONSTRAINT`). Because fire-crab accepted it, every later `INTEG_<n>` on that database shifted by one against the engine's, so it was a NAMING divergence as well as a syntax one - the subject of this whole chunk. After the fix the five `RESTRICT` statements refuse on both servers and `RDB$REF_CONSTRAINTS` reads IDENTICAL on the two files, `INTEG_3`/`INTEG_4`/`INTEG_5` alike. The catalog direction is untouched: `restore_ref_action` still maps a stored `RESTRICT` back to `RefAction::Restrict`.

- **`DROP TABLE` TAKES ITS CONSTRAINTS' TRIGGERS AND PARTNER ROWS WITH IT.** `crates/ods/src/ddl.rs:7919`, inside `drop_table` (`:7832`). **CLASSIFICATION: WRONG WRITE (silent), HIGH. PRE-EXISTING, byte-identical at HEAD.** `drop_table` deleted ten catalog tables' rows and never touched `RDB$REF_CONSTRAINTS`, `RDB$TRIGGERS` or `RDB$DEPENDENCIES`, so dropping a child left the FK's referential row, the action triggers (which sit on the PARENT, not on the table being dropped), the CHECK constraint's own trigger pair, and every one of their dependency rows:

  ```
  CREATE TABLE PP (ID INTEGER NOT NULL PRIMARY KEY);
  CREATE TABLE CH4 (X INTEGER, CONSTRAINT FK4 FOREIGN KEY (X) REFERENCES PP ON DELETE CASCADE);
  CREATE TABLE CH5 (X INTEGER, CONSTRAINT FK5 FOREIGN KEY (X) REFERENCES PP);
  CREATE TABLE CH6 (X INTEGER NOT NULL, Y INTEGER, CONSTRAINT CKC CHECK (Y > 0),
                    CONSTRAINT FK6 FOREIGN KEY (X) REFERENCES PP ON UPDATE CASCADE ON DELETE SET NULL);
  DROP TABLE CH4; DROP TABLE CH5; DROP TABLE CH6;

  engine leaves: nothing
  fire-crab left: 3 RDB$REF_CONSTRAINTS rows (FK4/FK5/FK6), 5 triggers
                  (CHECK_1/4/5 on PP, CHECK_2/3 on the dropped CH6), 11 dependency rows
  gfix -v -full  rc=0        gbak -b  rc=0
  gbak -c        gbak: ERROR:Name of Referential Constraint not defined in constraints table.
                 rc=1
  ```

  Worse than an unrestorable backup: the orphan action trigger RE-ATTACHES BY NAME to a table of the same name created afterwards, and breaks `DELETE` on it. `ALTER TABLE ... DROP CONSTRAINT` learned all of this in round 4; the same walk is now in `DROP TABLE`, with one difference the NOT NULL rows force - a NOT NULL constraint's `RDB$CHECK_CONSTRAINTS` row holds its COLUMN name where a CHECK or FK row holds a TRIGGER name, so only names that really are triggers are followed (otherwise a column called `ID` would take every dependency row of that name with it). After the fix the catalog the engine reads from fire-crab's file is IDENTICAL to the engine's own, `gbak -b` rc=0, `gbak -c` **rc=0**, `gfix -v -full` rc=0.

Gate: `qa/serve-real-key.sh` grows from **79 checks to 163**, all green.
Added: the 63/64 boundary on 26 naming paths plus the quoted and the
non-ASCII spellings of each, every 64-character one asserted to carry
the engine's own `-104 Name longer than database column size` and not
merely to fail; three COLLISION shapes (constraint, column and table
names differing only past character 63); a pair of 63-character names
differing in their LAST character, asserted to be TWO relations in the
catalog the engine reads back, so the check cannot round down; and a
`gbak` backup AND **RESTORE** of the long-name database - the restore is
the assertion, because the collided file backed up rc=0 and only died on
the way back in. Plus the deferred-drop sequence in its own database:
the child's orphan INSERT accepted after the drop, an unreferenced
parent row deleted, a referenced one refused with `***unknown***`, the
parent key UPDATE refused, a non-key UPDATE still accepted, the
surviving row COUNTED by the engine on fire-crab's own file, and the
engine reproducing both answers on that file.

### Recorded, still open - what this chunk did NOT start

- **HIGH (refusal, PRE-EXISTING, identical at HEAD, THIS IS THE NEXT CHUNK) - a referential ACTION makes the parent's matching DML impossible.** `crates/wire/src/server.rs:30131` (`check_predicates(db, table, &columns, descs, DmlGuard::Delete)?` in the DELETE planner) and `:29977` (the UPDATE one). fire-crab WRITES the flag-4 action trigger correctly and cannot PLAN around it, so the statement is refused at PREPARE with a bare `Dynamic SQL Error`. The affected set is completely regular and wider than the round-4 entry said: **every action that synthesises a trigger poisons its own event, for every row.** Measured 2026-09-03, one child table per run, both servers on their own file, `CH (X INTEGER, Y INTEGER REFERENCES PP <action>)` with `PP` holding ID 1 (referenced) and 2 (NOT referenced):

  ```
  action                  statement                          fire-crab              engine
  ON DELETE CASCADE       DELETE FROM PP WHERE ID = 2        ERR Dynamic SQL Error  OK
  ON DELETE SET NULL      DELETE FROM PP WHERE ID = 2        ERR Dynamic SQL Error  OK
  ON DELETE SET DEFAULT   DELETE FROM PP WHERE ID = 2        ERR Dynamic SQL Error  OK
  ON UPDATE CASCADE       UPDATE PP SET ID = 5 WHERE ID = 1  ERR Dynamic SQL Error  OK
  ON UPDATE SET NULL      UPDATE PP SET ID = 5 WHERE ID = 1  ERR Dynamic SQL Error  OK
  ON UPDATE SET DEFAULT   UPDATE PP SET ID = 5 WHERE ID = 1  ERR Dynamic SQL Error  OK
  every action            UPDATE PP SET T = 'zzz' WHERE ID=1 OK                     OK
  ```

  ID=2 has NO children, and its DELETE is refused anyway - the guard is on the trigger's existence, not on the rows. Two things the previous wording got wrong and this one fixes: `ON DELETE SET DEFAULT`, `ON UPDATE SET NULL` and `ON UPDATE SET DEFAULT` were not named, and "entirely UNDELETABLE" overstates it in one direction (a NON-key UPDATE on the parent still works under an `ON DELETE` action) and understates it in another (an `ON UPDATE` action poisons the key UPDATE, not the DELETE). DML on the CHILD is untouched throughout, and no row is ever written wrong: this is a refusal, not a wrong write. Reproducer, cold: create the two tables above, insert the two parent rows and one child row, run the statement in the table's own column. Closing it means fire-crab RUNNING a referential-action trigger - the DML planner admitting the flag-4 triggers it currently refuses to plan around, and a gate that asserts the ACTION and not only the catalog. `qa/serve-real-fkcascade.sh` misses it today because it only checks that fire-crab WRITES the triggers and that the ENGINE runs them, never that fire-crab does.

- **HIGH (refusal, PRE-EXISTING, identical at HEAD) - fire-crab's `gbak` restore fails on an ORDINARY ENGINE BACKUP when a table with a PRIMARY KEY was created after an FK child, and blames an I/O error.** `crates/wire/src/server.rs:6299` (`std::fs::remove_file(&db)` - no half-restored databases, so the target is deleted too). Reproducer, cold - three statements, an engine backup, a restore through fire-crab's service manager:

  ```
  CREATE DATABASE '<src>' ...;
  CREATE TABLE PI (ID INTEGER NOT NULL PRIMARY KEY);  COMMIT;
  CREATE TABLE C1 (X INTEGER REFERENCES PI);          COMMIT;
  CREATE TABLE PZ (ID INTEGER NOT NULL PRIMARY KEY);  -- a KEYED table AFTER the FK child
  gbak -b -user SYSDBA -pas masterkey 127.0.0.1/3050:<src> <fbk>        rc=0
  fbsvcmgr 127.0.0.1/<fc port>:service_mgr ... action_restore bkp_file <fbk> dbname <tgt>
    I/O error during "<Missing arg #1 - possibly status vector overflow>" operation
    for file "<Missing arg #2 - possibly status vector overflow>"
    (and <tgt> does not exist afterwards)
  gbak -c of the SAME fbk through the ENGINE                            rc=0, 2564096 bytes
  ```

  Bisected by the reviewer: it needs a keyed table created AFTER at least one FK child (the same statement with `CREATE TABLE PZ (ID INTEGER)` restores fine); any number of FK children with no later keyed table restores fine at n = 8, 12, 14, 16, 20, and 12 PK-only tables restore fine - it is the INTERLEAVING, not a count. The real reason is `duplicate key in unique index`, readable only with `FC_SRV_TRACE=1`; the operator is told about an I/O error on an unnamed file.

- **MEDIUM (over-acceptance, PRE-EXISTING, identical at HEAD) - the duplicate-key-set law is `CREATE TABLE` only.** `crates/ods/src/ddl.rs:3788` - the `SAME_KEY_COLUMNS_MSG` check sits inside `create_table`'s constraints loop and `alter_table_add_*` never sees it. Reproducer, cold:

  ```
  CREATE TABLE PM (A INTEGER NOT NULL, B INTEGER NOT NULL, CONSTRAINT U1 UNIQUE (A, B))  fc OK  eng OK
  ALTER TABLE PM ADD CONSTRAINT U2 UNIQUE (A, B)   fc OK  eng ERR ALTER TABLE "PUBLIC"."PM" failed
  ALTER TABLE PM ADD CONSTRAINT U3 UNIQUE (B, A)   fc OK  eng ERR   (the SET, not the order)
  CREATE TABLE PZ (A INTEGER NOT NULL PRIMARY KEY) fc OK  eng OK
  ALTER TABLE PZ ADD CONSTRAINT UZ UNIQUE (A)      fc OK  eng ERR
  ```

  The consequence is benign for now - the extra `RC|`/`IDX|` rows back up and restore rc=0/rc=0 with `gfix` clean - so it is an incomplete fix rather than a live hazard.

- **MEDIUM (over-refusal HAZARD, design, NEW in round 4, no misfire measured) - the gbak-restore FK path inherits `check_partner_compatible`.** `crates/wire/src/server.rs:5775` -> `crates/ods/src/ddl.rs:6849` `alter_table_add_foreign_key_carried` -> `write_foreign_key_full` -> `:7011` `check_partner_compatible`. There is no restore-specific bypass: the restore runs the check written for `CREATE TABLE`, and `column_key_class` answers `None` (a refusal) for ANY reason a column cannot be resolved - a missing relation, a missing name, a missing format, a `descs.get(fid)` out of range - not only for an incompatible type. A false refusal there lands in the failure mode above: the whole restore aborts, the target is deleted, and the operator is shown the mangled I/O error. 28 legitimate FK varieties in six groups were measured restoring rc=0, so nothing misfires today; the safety margin is accidental, `crates/burp/src/lib.rs:4642` admitting only field types `7|8|16|14|37|261`, so six of `key_class`'s ten non-text classes cannot reach the check from a restore at all. Cheapest containment: a `validate: false` on the carried path (the FK was already accepted by the engine that wrote the backup), or at minimum one restore-side gate case.

- **CLOSED IN ROUND 6 (was: MEDIUM, residual of THIS round's own fix B) - an opaque partnership can over-refuse a parent DELETE.** `crates/wire/src/server.rs` `row_could_carry_key`. As written this round, the parent-side check after a `DROP CONSTRAINT` asked whether ANY column of any child row held the key's values, because the catalog no longer said which columns had keyed on the parent. It never missed a real reference, and it refused far more than the entry admitted: measured by the round-5 reviewer, the ordinary `ORD (OID, STATUS, QTY, PID)` shape with ONE child row made two of three parent rows undeletable (`STATUS = 2` protected `ID = 2`, `QTY = 3` protected `ID = 3`), and the match crossed type boundaries - a `VARCHAR` holding `'2'` and a `DOUBLE` holding `2.0` both counted as references to `ID = 2`. Two corrections to what this entry originally said: the operator's escape was **not** permanence - `gfix -sweep` does not clear the state (`RDB$FOREIGN_KEY` still names the parent's index afterwards) but a full backup/restore cycle does, and the `RDB$TEMP_DEPEND` row is gone from the restored file - though THROUGH FIRE-CRAB that escape does not exist, because its own backup is fail-closed on exactly this state (`crates/burp/src/lib.rs:1735`, `index <name> is inactive - a state this backup cannot say`, reaching the client as `feature is not supported`), so only the real engine can perform it; and "an unrelated child column happens to hold the same value" reads as a corner case when small-integer status and quantity columns make it the norm. **Round 6 closed it** by reading the dropped index's key columns off the index-root SEGMENT DESCRIPTORS, which the deferred drop keeps along with the tree the engine itself enforces from, so the parent-side test is the ordinary exact one again. What is left is the LOW residual recorded in the round-6 section: the wide scan survives only for a descriptor this server cannot read at all.

- **LOW (refusal/naming, PRE-EXISTING, identical at HEAD) - the two-pass constraint-naming law is not applied on the gbak-restore path.** `crates/wire/src/server.rs:5775` calls `create_table(&cols, &[], &[])` and lets it draw fresh `INTEG_<n>` numbers for the columns' NOT NULL rows, then restores the carried keys afterwards, so a restored database's constraint names are neither the source's nor the engine's restore's. One engine-made `.fbk` restored three ways:

  ```
  ENGINE's own restore        working tree / HEAD
  RC|PP|INTEG_1|NOT NULL      RC|PP|INTEG_1|NOT NULL
  RC|PP|INTEG_2|PRIMARY KEY   RC|PP|INTEG_2|NOT NULL
  RC|PP|INTEG_3|NOT NULL      RC|PP|INTEG_3|PRIMARY KEY
  CC|INTEG_3|UX               CC|INTEG_2|UX
  ```

  Since the point of rounds 3, 4 and 5 is that these names must match the engine's, the restore path is the one place the law is still not enforced.

- **LOW (over-acceptance, PRE-EXISTING) - a reserved word is still accepted as a constraint NAME in one spelling.** `crates/wire/src/server.rs:55638` `canon_ident` asks only whether a bare word spells an identifier. Re-measured 2026-09-03 and NARROWER than round 4 recorded: `CREATE TABLE RW1 (A INTEGER, CONSTRAINT CHECK (A > 0))` is now refused by BOTH servers, while `CREATE TABLE RW2 (A INTEGER, CONSTRAINT CONSTRAINT CHECK (A > 0))` is still `fc OK` against the engine's `-104 Token unknown - line 1, column 41, CONSTRAINT`. 3 of 10,668 fuzzed statements in round 4. Closing it wants a reserved-word list the parser does not have.

- **LOW (over-acceptance, PRE-EXISTING, identical at HEAD) - a non-numeric string DEFAULT on a numeric column is accepted when NOT NULL or PRIMARY KEY is present.** Measured 2026-09-03:

  ```
  CREATE TABLE M6 (A INTEGER DEFAULT 'abc' NOT NULL)     fc OK   eng ERR Conversion error from string "abc"
  INSERT INTO M6 (A) VALUES (1)                          fc OK   (M6 does not exist on the engine)
  CREATE TABLE M7 (A INTEGER DEFAULT 'abc' PRIMARY KEY)  fc OK   eng ERR ... Conversion error from string "abc"
  CREATE TABLE M8 (A INTEGER DEFAULT 'abc')              fc OK   eng OK
  ```

  The engine only EVALUATES the default when NOT NULL or a key forces it, so the divergence is exactly that combination; with no key clause both accept. Not a charset artifact (pure-ASCII `'abc'` and `'7'` behave the same) and the file itself restores cleanly - an over-acceptance, not a corruption.

- **LOW (over-refusal, PRE-EXISTING, identical at HEAD, WIDER than round 4 recorded) - an inline `CHECK` comparing a NUMERIC column to ANY string literal is refused.** Round 4 recorded this as being about DOMAIN-typed or `CHARACTER SET` columns; the surface is a plain `INTEGER` column against any string literal, `'7'` included. Measured 2026-09-03:

  ```
  CREATE TABLE I01 (A INTEGER CHECK (A <> 'CONSTRAINT'))  fc ERR Dynamic SQL Error   eng OK
  CREATE TABLE I02 (A INTEGER CHECK (A <> 'xyz'))         fc ERR                     eng OK
  CREATE TABLE I03 (A INTEGER CHECK (A <> '7'))           fc ERR                     eng OK
  CREATE TABLE I04 (A INTEGER CHECK (A <> 7))             fc OK                      eng OK
  ```

  `mask_literals` is doing its job - on a `VARCHAR` column all 15 keyword-bearing literals agree, `'CONSTRAINT'`, `'CHECK'`, `'REFERENCES'`, `'NOT NULL'` and `'PRIMARY KEY'` among them - so this is the CHECK type-checker alone.

- **ENGINE OBSERVATION, environment hazard, NOT re-verified here on purpose - deeply nested parentheses KILL the Firebird server process.** `CREATE TABLE T (A INTEGER CHECK ((((...20000 deep...A>0...))))` takes the shared engine down outright; the client sees `Connection to Firebird server was lost` and then `Connection is closed`, and every other run on the box loses its engine until someone restarts the service. Reported by a round-4 reviewer, who took `127.0.0.1:3050` down doing it and restarted it (`sudo systemctl restart firebird.service`). fire-crab refuses the same input cleanly and stays up. Deliberately NOT re-run to confirm, because confirming it means taking the shared engine down again; it is recorded so that the next person to fuzz nesting depth against the engine knows what they are looking at and does not read it as a fire-crab defect.
- **ENGINE OBSERVATION, no fire-crab involvement - Firebird 6 checks only the FIRST foreign key on a parent-row DELETE.** A pure-engine reproducer:

  ```sql
  CREATE TABLE PP (ID INTEGER NOT NULL PRIMARY KEY);
  CREATE TABLE K1 (X INTEGER, CONSTRAINT F1 FOREIGN KEY (X) REFERENCES PP);
  CREATE TABLE K2 (X INTEGER, CONSTRAINT F2 FOREIGN KEY (X) REFERENCES PP);
  INSERT INTO PP VALUES (1),(2);  INSERT INTO K1 VALUES (1);  INSERT INTO K2 VALUES (2);
  DELETE FROM PP WHERE ID = 1 -> violation of FOREIGN KEY constraint "F1" on table "PUBLIC"."K1"
  DELETE FROM PP WHERE ID = 2 -> ACCEPTED, leaving K2 holding an orphan
  ```

  With only `K2` present the engine refuses correctly, so it is the first-FK-wins shape and not a missing check. fire-crab is STRICTER here. The consequence for this project: any "engine on fire-crab's file" differential of a parent DELETE with more than one child FK compares against an engine that is under-enforcing, and reads as a fire-crab over-refusal. **Do not "fix" fire-crab to match it.**

- **QA hygiene, structural - `qa/serve-real-key.sh` uses fixed, non-port-scoped scratch paths** (`$D/fc-key-work.fdb`, `$D/fc-key-ref.fdb`, and now `$D/fc-key-name.fdb` and `$D/fc-key-defer.fdb`), so a leftover `fcwire` holding the same path can silently rewrite a concurrent run's file. A reviewer saw exactly that signature once - `rc=1 OK=67`, failures degenerating into `Table unknown` for tables the same run had just created - with a stray server from a previous session alive, and could not reproduce it in three later runs. Not a defect; it is why "kill only your own fcwire, by pid" is a standing rule for this repo.

## A foreign key must FIT before it is written (2026-09-03) - the fourth fix round

The round that made an inline `REFERENCES` parse routed it into an FK
writer that had never checked whether the key it was writing could
exist, so on those shapes **a refusal became a wrong write** - the one
direction a conversion must never move. This round closes that, and the
panic the multi-span clause rewrite shipped with. Every finding below
was reproduced first, on the unmodified tree, and re-measured after.

- **NO INPUT PANICS THE CONNECTION THREAD ANY MORE.** `crates/wire/src/server.rs`, the merged clause rewrite in the CREATE TABLE item loop. `constraint_prefix_start` walks BACKWARDS from a clause keyword for a `CONSTRAINT <name>` prefix with no regard for a span already claimed, so it could answer a start lying INSIDE an earlier span; the rewrite then sliced `item[prev..start]` with `prev > start` and panicked (`byte range starts at 36 but ends at 23`). The client saw a DROPPED TCP CONNECTION rather than an SQL error and lost its transaction. Four shapes, all NEW relative to HEAD, which refused all four cleanly: `(A INTEGER CHECK (A > 0 CONSTRAINT C) CHECK (A < 9))`, `(A INTEGER CONSTRAINT C1 CHECK (A > 0 CONSTRAINT C2) CHECK (A < 9))`, `(A INTEGER CHECK (A > 0 CONSTRAINT C) REFERENCES P)`, `(A INTEGER REFERENCES CONSTRAINT N CHECK (A > 0))` - and the first two carry no `REFERENCES` at all, so the hazard came in with the multi-span inline-CHECK rewrite and the REFERENCES span doubled it. Two guards, both needed: a prefix that reaches BEHIND the previous clause's end is a `CONSTRAINT` keyword standing inside that clause (which the engine answers `-104 Token unknown - CONSTRAINT`) and REFUSES the statement, and the rewrite loop itself refuses rather than slices whenever a span still starts before the previous one ended. `constraint_prefix_start` also checks its slice is on a character boundary. A `debug_assert` would not have done: the release binary is what serves. Fuzzed afterwards with 10,668 malformed column items (CONSTRAINT prefixes, nested parens, overlapping CHECK/REFERENCES clauses, unbalanced parens, reserved words as names, two and three clauses per column): 0 panics, 0 lost connections, every statement answered.
- **A FOREIGN KEY WHOSE COLUMN COUNT DOES NOT FIT IS REFUSED, BEFORE ANYTHING IS WRITTEN.** `crates/ods/src/ddl.rs` `check_partner_compatible`, called from `write_foreign_key_full` ahead of `create_index`. `find_partner_key` took the parent's PRIMARY KEY without comparing segment counts, on the empty-list and the explicit-list path alike, so `PC (X INTEGER NOT NULL, Y INTEGER NOT NULL, PRIMARY KEY (X, Y))` accepted `CREATE TABLE T2 (A INTEGER, B INTEGER REFERENCES PC)`: a ONE-segment FK index bound to a TWO-column key, which fire-crab did not enforce, which the ENGINE reading the same file DID enforce (so the two servers disagreed about the file's rows), and whose `gbak -c` failed with `cannot commit index ... Database is not online due to failure to activate one or more indices`. The reverse arity was worse - rc=2 with no rows at all. Table-level pre-existing, inline newly reachable. The refusal now carries the engine's own vector: `unsuccessful metadata update / <VERB> @1 failed / SQL error code = -607 / Invalid command / FOREIGN KEY column count does not match PRIMARY KEY`.
- **A TYPE-INCOMPATIBLE FOREIGN KEY IS REFUSED.** Same site. The partner was matched by name and column list and never by type, so `CREATE TABLE CH (A BIGINT REFERENCES P)` over an INTEGER key was written, `INSERT INTO CH VALUES (1)` was accepted for a value that IS in P, the ENGINE reading fire-crab's own file called that row an orphan, `gfix -v -full` returned rc=0 so nothing warned anyone, and `gbak -c` refused the restore. The refusal now carries `isc_partner_idx_incompat_type` with the 1-based number of the first segment that does not fit, as the engine does (`Partner index segment no 1 has incompatible data type`).

  **THE COMPATIBILITY RULE, MEASURED (2026-09-03, engine at 127.0.0.1/3050, 24 x 24 type pairs plus precision, charset, collation and domain probes).** Two columns may be the two ends of one foreign key exactly when they fall in the same INDEX-KEY CLASS - which is the same partition the key ENCODING draws, and the reason it is a partition at all: two columns can share one index only if their keys are built the same way. The classes:

  | class | types |
  |---|---|
  | small exact / float | SMALLINT, INTEGER, FLOAT, DOUBLE PRECISION, NUMERIC/DECIMAL of precision <= 9 (any scale) |
  | int64 | BIGINT, NUMERIC/DECIMAL of precision 10..18 |
  | int128 | INT128, NUMERIC/DECIMAL of precision 19..38 |
  | DATE / TIME / TIMESTAMP | three separate classes |
  | TIME WITH TIME ZONE / TIMESTAMP WITH TIME ZONE | two more, each apart from its unzoned twin |
  | BOOLEAN | its own |
  | DECFLOAT | DECFLOAT(16) and DECFLOAT(34) TOGETHER - the one pair of different dtypes that share a class |
  | text | CHAR and VARCHAR alike, keyed on the TTYPE (character set AND collation) |
  | none | BLOB, ARRAY - no key at all, refused by both servers |

  What follows from it, each measured rather than reasoned: `SMALLINT REFERENCES <INTEGER key>` is accepted by BOTH servers, `INTEGER` onto `BIGINT` is refused, and so is `NUMERIC(9,0)` onto `NUMERIC(10,0)` - the boundary is the PRECISION, because the precision picks the storage type, while the SCALE never matters. A string's declared LENGTH never matters (`VARCHAR(80)` keys against `CHAR(5)`) and neither does CHAR vs VARCHAR, but the CHARACTER SET does (NONE, OCTETS and WIN1252 are three classes) and so does the COLLATION (`UTF8` and `UTF8 COLLATE UNICODE` are two). A DOMAIN behaves exactly as its base type, on either side. On a compound key the message names the FIRST segment that does not fit (`no 2` for a second-column mismatch).
- **`NO ACTION` IS STORED AS `NO ACTION`.** `RefAction::NoAction` is now its own variant with its own `rule()`; `RefAction::synthesises_trigger()` replaces the `!= Restrict` tests, so it still generates no trigger. A comment in `crates/ods/src/ddl.rs` stated the collapse to `RESTRICT` as a LAW; the engine contradicts it (`INTEG_6 -> INTEG_2 U=NO ACTION D=NO ACTION` on the engine's file against `U=RESTRICT D=RESTRICT` on fire-crab's) and the comment is deleted. A wrong law written down is worse than none. This was a silent wrong write that survived gbak, and the ONLY divergence among the eighty FK shapes both servers fully accept. `restore_ref_action` maps the rule back to itself so a backup taken from a NO ACTION key restores to one.
- **AN FK ACTION TRIGGER IS LINKED TO ITS CONSTRAINT, AND A DROP TAKES IT WITH IT.** `store_fk_trigger` wrote the `CHECK_<n>` row into `RDB$TRIGGERS` and stopped; the engine also writes the `RDB$CHECK_CONSTRAINTS` row tying that trigger to the FK's constraint name (one row per trigger, both carrying the FK's name). Without it, `ALTER TABLE CH DROP CONSTRAINT INTEG_3` removed the constraint from both catalogs and left the unreferenced `AFTER DELETE` trigger alive and still cascading, so `DELETE FROM P` silently deleted a child row the engine's own database keeps (`CHILD_ROWS_LEFT 0` against `1`, `ORPHAN_TRG CHECK_1`, `gfix -v -full` rc=0). The link row is written now, and `alter_table_drop_constraint`'s FOREIGN KEY arm follows it: the triggers, their dependency rows and the link rows go, and the PARENT's `RDB$RUNTIME` is rebuilt (the trigger sits on the parent, not on the table the ALTER names).
- **TWO KEYS OVER ONE SET OF COLUMNS ARE REFUSED** - DYN 126, `Same set of columns cannot be used in more than one PRIMARY KEY and/or UNIQUE constraint definition`. It is the SET and not the order (`UNIQUE (A,B)` beside `UNIQUE (B,A)` is refused; `UNIQUE (A)` beside `UNIQUE (A,B)` is fine), and a column-level key counts. fire-crab wrote both constraints and both indexes.
- **A `DEFAULT` MUST PRECEDE EVERY CONSTRAINT CLAUSE ON ITS COLUMN.** The engine's grammar is `<name> <type> [DEFAULT <v>] [<constraint> ...]`, and `A INTEGER UNIQUE DEFAULT 7` is a `-104 Token unknown - DEFAULT` for NOT NULL, UNIQUE, PRIMARY KEY, CHECK and REFERENCES alike. The clause splits cut the constraints OUT of the item, so by the time the column parser runs the order is gone - it is checked while both are still in one string, and a `SET DEFAULT` referential action or a DEFAULT inside a CHECK condition (both inside a claimed span) is not mistaken for one. The laxity was pre-existing on `UNIQUE`/`NOT NULL`; the CHECK and REFERENCES spellings were newly reachable.
- **AN EVENT MAY BE NAMED ONCE.** `parse_ref_actions` looped and let the LAST clause win, so `REFERENCES P ON DELETE CASCADE ON DELETE SET NULL` recorded `D=SET NULL` for a table the engine refuses with `-104 Token unknown - DELETE`.
- **A COLUMN MAY CARRY TWO INLINE `REFERENCES`.** `A INTEGER REFERENCES P REFERENCES Q` is accepted by the engine and writes two foreign keys. The CHECK split always collected a Vec; the REFERENCES one returned a single Option and left the second clause in the residual, where the column parser choked.
- **AN INLINE `CHECK` SEES ONLY THE COLUMNS DECLARED SO FAR.** `(A INTEGER CHECK (B > 0), B INTEGER)` is `-206 Column unknown "B"` on the engine, while the same condition written as a TABLE-level CHECK is accepted - it is resolved once the whole column list is read. fire-crab accepted both.

Gate: `qa/serve-real-key.sh` grows from 45 checks to **79**, all green. Added:
the four panic shapes, each asserted to return a clean SQL error AND to
leave the connection alive (a second statement on the SAME connection
must still answer - a gate that looked only at the first answer would
have called the panic a refusal and passed); six arity/type refusals,
each with the ENGINE's own refusal for the same statement beside it;
`NO ACTION` and both-action round trips through `RDB$REF_CONSTRAINTS`;
two inline `REFERENCES` on one column; a SMALLINT child onto an INTEGER
key (the pair BOTH servers accept); an unfiltered `CCALL|` /`SYSTRG|`
comparison of every `RDB$CHECK_CONSTRAINTS` row and every system trigger
(the old `CC|` check filtered `WHERE R.RDB$RELATION_NAME IN ($TBLS)`, and
an FK's action trigger sits on the PARENT relation, so it was filtered
out - which is why nothing caught the missing link row); and a
drop-then-cascade behaviour check that asserts the child row the engine
keeps is still there and no unreferenced system trigger survived.

### Recorded, still open - the FOREIGN KEY neighbourhood

- **HIGH (refusal, PRE-EXISTING, identical at HEAD, its own chunk) - `ON DELETE CASCADE` / `SET NULL` / `ON UPDATE CASCADE` declared in `CREATE TABLE` make the parent table entirely UNDELETABLE.** The action trigger fire-crab writes is refused at PREPARE (`crates/wire/src/server.rs` `check_predicates(..., DmlGuard::Delete)` in the DELETE planner, and the UPDATE one beside it), so EVERY `DELETE` on the parent fails with a bare `Dynamic SQL Error` - including deleting a row with no children at all. Both spellings, inline and table-level. Measured, one child table per run, both servers on their own file:

  ```
  ### CHILD: CREATE TABLE CH (A INTEGER, B INTEGER REFERENCES PP ON DELETE CASCADE)
  --- fire-crab ---
  INSERT INTO PP VALUES (1, 'one')              -> OK
  INSERT INTO PP VALUES (2, 'two')              -> OK
  INSERT INTO CH VALUES (10, 1)                 -> OK
  DELETE FROM PP WHERE ID = 2                   -> ERR [335544569] Dynamic SQL Error   <-- ID=2 has NO children
  DELETE FROM PP WHERE ID = 1                   -> ERR [335544569] Dynamic SQL Error
  SELECT A, B FROM CH                           -> ROWS [{"A":10,"B":1}]
  --- engine ---
  DELETE FROM PP WHERE ID = 2                   -> OK
  DELETE FROM PP WHERE ID = 1                   -> OK          (child row cascaded away)

  ### inline ON DELETE SET NULL
  fc : DELETE FROM PP WHERE ID = 1  -> ERR [335544569] Dynamic SQL Error   / CH still {"A":10,"B":1}
  eng: DELETE FROM PP WHERE ID = 1  -> OK                                  / CH now  10 | <null>
  ### inline ON UPDATE CASCADE
  fc : UPDATE PP SET ID = 5 WHERE ID = 1 -> ERR [335544569] Dynamic SQL Error / CH still B=1, PP still ID=1
  eng: UPDATE PP SET ID = 5 WHERE ID = 1 -> OK                               / CH now B=5, PP now ID=5
  ```

  A HEAD build answers byte-identically on the table-level spelling, so it is not a regression - but it is reachable through one MORE syntax now, and it is a refusal, not a wrong write. `qa/serve-real-fkcascade.sh` misses it because it only checks that fire-crab WRITES the triggers and that the ENGINE runs them, never that fire-crab does. Fixing it means fire-crab RUNNING a referential-action trigger, which is a chunk of its own: the DML planner has to admit the flag-4 triggers it currently refuses to plan around, and the gate has to assert the ACTION and not only the catalog.
- **MEDIUM (refusal, pre-existing) - an inline `REFERENCES` still does not parse in `ALTER TABLE ... ADD <column>`**, nor do an inline `UNIQUE`, `NOT NULL` or `CHECK` there; the engine accepts all four. A gap in the new feature's reach, not a regression - and `ALTER TABLE ADD` does NOT panic on the overlapping-span shapes, so that hazard was confined to `CREATE TABLE`.
- **MEDIUM (refusal, pre-existing) - `CONSTRAINT <name> NOT NULL` written inline is refused** (`CREATE TABLE T (A INTEGER CONSTRAINT NN1 NOT NULL, B INTEGER)`); no `REFERENCES` involved. `parse_column_def` has no arm for a named NOT NULL, and the whole statement refuses.
- **MEDIUM (refusal, pre-existing) - an inline `CHECK` is refused on a DOMAIN-typed or `CHARACTER SET` column** (`(A DOM1 CHECK (A > 0))`, `(A VARCHAR(10) CHARACTER SET UTF8 CHECK (A <> 'z'))`). `check_cond_typechecks`' field-rank closure answers `None` for any column with a domain, and its text path wants the plain NONE-charset shape. The COLLATE placement is not the cause - the same column without a CHECK is fine on both servers.
- **MEDIUM (refusal, pre-existing, NOT constraint-related) - the CREATE TABLE body splitter is blind to literals and quoted identifiers.** The column-list `close` scan and the top-level-comma item split both walk the RAW statement counting `(`/`)`/`[`/`]`/`,` with no `mask_literals`, though the inner split code that consumes their output is meticulous about masking. `(A VARCHAR(20) CHECK (A <> 'x)y'))`, `(A VARCHAR(20) DEFAULT 'x,y', B INTEGER)`, `("A,B" INTEGER, C INTEGER)` all refuse where the engine accepts. A comma or paren INSIDE a clause's parens is safe (depth >= 1); it is depth-0 literals and quoted names that tear.
- **LOW (refusal, pre-existing) - `CHECK (A IN (1, 2))` is refused** in both the inline and the table-level form; the CHECK condition surface has no `IN`. Nothing to do with the splitter - the comma sits at depth 1 and the item survives intact.
- **LOW (over-acceptance, pre-existing) - a reserved word is accepted as a constraint NAME.** `CONSTRAINT CHECK (A > 0)`, `CONSTRAINT REFERENCES P` and `REFERENCES P CONSTRAINT CONSTRAINT CHECK (A > 0)` are written where the engine answers `-104 Token unknown`. `canon_ident` asks only whether a bare word spells an identifier; closing it wants a reserved-word list the parser does not have.
- **LOW (error text, pre-existing) - a duplicate CONSTRAINT/INDEX name inside `CREATE TABLE` is reported as a duplicate TABLE.** `CREATE TABLE D2 (A INTEGER, CONSTRAINT K UNIQUE (A))` beside an existing `K` answers `CREATE TABLE "PUBLIC"."D2" failed / Table "PUBLIC"."D2" already exists` where the engine says `Index "PUBLIC"."K" already exists` (SQLSTATE 42S11). `respond_ddl_meta` keys on the words "already exists" in the writer's message and renders the plan's own object name. Both refuse; only the reason is wrong.
- **RECORDED, unchanged - the `INTEG_<n>` counter drift after a FAILED statement now has a wider trigger set.** The engine keeps the numbers a failed DDL statement consumed and fire-crab rewinds them (already recorded above), and every refusal this round ADDS is another statement on which the two counters part company. It is not a collision risk, and a gbak round trip heals the pure counter cases, but "a fire-crab-built database is name-identical to the engine's" continues to hold only for statements that all succeed.

## Found while converting quoted identifiers (2026-09-02) - still open

- ~~**HIGH (data destruction, pre-existing, no gate)**~~ **RE-CLASSIFIED AND HALF FIXED 2026-09-04** (`qa/serve-real-attach.sh`, 18 checks; 9 failed on the pre-change binary, 5 fail now, all five the client-driven restore below). **THE "DATA DESTRUCTION" HALF WAS NOT A DEFECT AND HAS BEEN WITHDRAWN.** The entry read "the old database is gone and the new one was never written", which is true and is ALSO what the ENGINE does: measured 2026-09-03 against 127.0.0.1/3050 with a byte-corrupted (not truncated) backup, `gbak -r -rep` drops the target FIRST, and a failure part-way leaves the file present at its original 2564096 bytes with `SELECT COUNT(*) FROM KEEPME` answering `-204 Table unknown`, while gbak reports `string truncated / Exiting before completion due to errors`. That is `-rep`'s own semantics and must not be "fixed"; `qa/serve-real-attach.sh` asserts it deliberately so nobody does. (Measuring note: a TRUNCATED backup makes gbak HANG instead - corrupt bytes in the middle and keep the length.) **The SIGSEGV WAS real and is FIXED.** Mechanism: `build_db_info` SKIPPED SILENTLY any info item it did not implement, so gbak's `isc_version()` request (`isc_info_firebird_version` 103, `isc_info_implementation` 11, `fb_info_implementation` 114) came back carrying only 103; libfbclient's `isc_version` sets its `implementations` pointer only from item 11 or 114, leaves it NULL, and dereferences it - `Segmentation fault (core dumped)`, rc=139, the verbose output stopping at `backup version is 12`. A hole in a reply is not something a client can tell from an answer, so the fix is general: items 11 and 114 are answered in the engine's own cluster shape, and any item this server does not serve now answers `isc_info_error` + `isc_infunk` exactly as the engine answers an item it does not know (probed with item 200). `frb_info_att_charset` (101) was implemented in the same pass because isql asks for it and an error there made isql print "Pre IB V6 server only speaks SQL dialect 1".
- **DONE 2026-09-06 - THE EMPLOYEE SAMPLE'S PROCEDURES RUN THROUGH fire-crab, ALL TEN, AS THE ENGINE RUNS THEM.** `execute procedure dept_budget '600'` (6110000.00), `sub_tot_budget`, `org_chart` (21 rows), `mail_label`, `show_langs`, `all_langs` (186 rows), `get_emp_proj`, `add_emp_proj`, `ship_order` (its four exceptions, line and column) and `delete_employee` - a 49-statement probe set with SQLDA displays, errors and rollbacks diffs to ZERO lines against the engine over its own restore; the read kit of the previous entry now differs only on the view `RDB$DBKEY_LENGTH`. The research pass overturned the previous entry's diagnosis: the sample's bodies are NOT outside the source interpreter - they never reach it. Every procedure call runs the stored BLR through `fire-crab-exe` first (`try_procedure_blr`), and that executor covered all of them but for four narrow gaps, each measured on the engine before it was closed. **(1) The paren-less call.** `EXECUTE PROCEDURE dept_budget :rdno RETURNING_VALUES :sumb` has no parentheses, and the body parser's name/argument split only knew the parenthesised spelling, so the whole body was refused (the source path is where DEPT_BUDGET lands: `blr_exec_proc` is outside the executor). The first token is the name, the rest the arguments. **(2) Scaled folds.** The executor's SUM and AVG folded integers only, so `SUM(budget)` over DECIMAL(12,2) rows skipped every row and answered NULL beside a correct MIN/MAX. The folds now carry `(raw, scale)` through `exe_numeric_bin`, and AVG divides at the SOURCE scale truncating toward zero - the engine's rule (AVG of 1.01, 1.02, 1.02 is 1.01; of their negatives -1.01; `AVG(budget)` under department 000 is 1166666.66). **(3) COMPUTED BY in a compiled body.** `blr_field` read the column's slot from the decoded record, which a computed column does not have, so ORG_CHART's `FULL_NAME` was NULL for every manager. The executor now looks the column up (`RDB$RELATION_FIELDS` -> `RDB$FIELD_SOURCE` -> `RDB$FIELDS.RDB$COMPUTED_BLR`), parses the stored expression (`parse_value_blr`: version byte, one expression) and evaluates it over the row with context 0 bound to the relation - the engine's own numbering; an expression outside the executor's surface is an Err, which sends the body to the source interpreter rather than answering NULL. **(4) FOR SELECT over a procedure with arguments.** ALL_LANGS loops `FOR SELECT languages FROM show_langs(:code, :grade, :country)`; the engine compiles it as `blr_procedure` inside an rse, which the executor does not run, and the source interpreter's loop read its rows through `branch_rows`, which has no procedure source. `psql_plan_rows` runs a `Plan::ProcSelect` the way the client path does - BLR first, source otherwise, projected by `picks` - for FOR SELECT and SELECT INTO alike. **AND A LATENT DIFFERENCE THE DESIGN FLAGGED, CLOSED:** the engine's EXECUTE PROCEDURE sends the inputs, receives ONE output message and unwinds the request, so a body's statements after its first SUSPEND never run (probed: an UPDATE after the first SUSPEND is visible after `SELECT * FROM p` and not after `EXECUTE PROCEDURE p`); fire-crab ran every body to the end and took the first row. Both paths now stop: the executor halts at the first `blr_stall` that FOLLOWS a send (the procedure prologue stalls once before the body, waiting for the first receive - halting there answered NULL for every EXECUTE PROCEDURE until the condition was narrowed), and the source interpreter's SUSPEND exits the body under the same `first_only` flag, which every caller now states (the dynamic-string EXECUTE PROCEDURE and both ProcInvoke paths true, the SELECT, modifier and anonymous-block paths false). **NEW GATE `qa/serve-real-procsample.sh`** (11 checks, isql on both sides over separate copies of an engine-built fixture): the paren-less recursion, the leaf suspending twice under SELECT, the CHAR(3) bind refusal, SUM/AVG/MIN/MAX INTO with the SQLDA scale, NULLs over no rows, the computed column, FOR SELECT over a procedure with arguments, the first-SUSPEND stop under EXECUTE against the run-to-end under SELECT, and the DSQL AVG. Gates: exeproc, callproc, numproc, createproc, procdefault, procdescribe, the package family, the psql family, cursors, selectinto, exceptions, the trigger family, computed, the aggregate family, describe, union, arrays, gbak, attach, restored, and the 13 database-argument gates - 0 DIFF; 77 + 4 + 161 + 344 unit tests. **Left open, recorded:** the recursion ceiling (fire-crab refuses at depth 48, the engine raises isc 335544663 at 1001 activations); a FOR SELECT materialises its rows before the loop; a body compiled BY fire-crab still refuses `FROM p(args)` in its FROM (`stream_item` takes a table only) and the paren-less spelling (the DSQL parser wants the parentheses) - the restored sample carries the engine's BLR and needs neither.
- **DONE 2026-09-06 - THE RESTORED EMPLOYEE DATABASE IS USABLE THROUGH fire-crab.** The previous two entries left a file the ENGINE could use; this one makes fire-crab itself answer over it. A read kit (`fcread.sql`: every sample table, the arrays, the views, the literal-labelled union of counts, `IS NULL` on blob and array columns, `USER`/`CURRENT_USER`/`CURRENT_ROLE`, `set sqlda_display` over system CHAR columns) and a write kit (`w.sql`: inserts through `CHECK_3`/`CHECK_25`, the salary UPDATE whose trigger `SAVE_SALARY_CHANGE` inserts `user` into `SALARY_HISTORY`, a department DELETE) now diff to the engine over its own restore except for one line each (below). What it took, each measured on the engine before it was written: **array element access** `LANGUAGE_REQ[1]` describes as the element type, Nullable, under the column's name and table; NULL array or subscript answers NULL; out of range raises `isc_ss_out_of_bounds` (335545028, three numbers) per row and a wrong dimension count `isc_invalid_dimension`; the slot arithmetic already included the two bytes `array_shape` counts, so the first version read blanks. **Boolean projection items** and **N-branch UNION ALL of counts and labelled literals** (a Group branch is a union member; the union text width is the widest branch, VARYING if any). **UNION NAMING, re-measured on 35 shapes** against the earlier three-shape rule: the engine (`PASS1_union`) maps the column onto the first item when the reconciled descriptor is EQUIVALENT to that item's own (dtype, length, scale, sub_type) and onto a CAST otherwise; the map names by KIND (`DsqlMapNode::setParameterName`): a field keeps field/alias/relation/binding alias, an AS keeps only the alias, a literal is CONSTANT and an aggregate its own name, any other expression is nameless; under the cast only a field's or alias's name survives, as the alias, field empty (`X | X+1` → ""/X, `X+1 | X` → ""/"", `1 | X` → CONSTANT/CONSTANT, `X | B(igint)` → ""/X, `B | X` → B/B/T, `'a' | 'bb'` → ""/"", `COUNT(*) AS K | B` → ""/K). A bare NULL branch has no say in the type (`DataTypeUtil::makeFromList` skips it): `X UNION ALL NULL` is X/X/T, formerly a refusal. `qa/serve-real-union.sh` check 4 pinned the OLD refusal of an aggregate branch and now pins the engine's answer. **CHECK constraints with subselects** (`CHECK_25`: `EXISTS (SELECT ... FROM employee WHERE ...)`) - `check_predicates` lifts subqueries the way a WHERE does. **PSQL numeric comparison and scaled arithmetic** in trigger bodies (`old.salary <> new.salary`, `(new.salary - old.salary) / old.salary` at the engine's scale rules: +/- at the wider scale, * summed, / as `A*10^(2|sb|)/B` at `sa+sb`). **`USER` / `CURRENT_USER` / `CURRENT_ROLE`** as select items (VARYING 252 UTF8, named USER/ROLE, no relation - there is no `SESSION_USER` in Firebird) and inside a trigger's rendered INSERT (the body parser reads `user` as a field; the renderer had quoted it into a column). **System CHAR column widths**: `RDB$FIELD_SUB_TYPE` on a text domain is the TEXT SUBTYPE, not a charset; the descriptor's sub_type is `charset | collation << 8` read from `RDB$COLLATION_ID`/`RDB$CHARACTER_SET_ID` (`sysfmt.rs`, `catalog_field_list`). **THE ONE READ LEFT** is `execute procedure dept_budget '600'`: the procedure body uses singleton `SELECT ... INTO`, aggregate `INTO`, `FOR SELECT ... INTO` with scaled arithmetic, `EXECUTE PROCEDURE ... RETURNING_VALUES` and recursion, none of which the PSQL interpreter has (bisected with `fc_t1..fc_t5`) - **THE NEXT CHUNK.** **THE ONE WRITE LEFT is the engine's, not ours - AN ENGINE DEFECT, reproduced without gbak:** `delete from department where dept_no = '600'` is REFUSED by fire-crab (`INTEG_28`, two employees and two sub-departments reference it) and by the shipped `employee.fdb` (`INTEG_17`, the self-referencing partner, which comes first in that file's `RDB$INDEX_41` order), but ALLOWED by the engine over its own restored copy, where `RDB$INDEX_41` orders the partners `PROJ_DEPT_BUDGET`, `EMPLOYEE`, `DEPARTMENT` and only the first is checked (`623`, which `PROJ_DEPT_BUDGET` references, IS refused). Fresh database, three child tables `C1`/`C2`/`C3` referencing `P`, one row each: the engine (LI-T6.0.0.2076, fd83f03) refuses the delete and the key update of the parent row `C1` references and ALLOWS those of the rows `C2` and `C3` reference; fire-crab, restored from that database's backup, refuses all six. So Firebird 6 at this snapshot enforces only the FIRST foreign-key partner of a parent index on DELETE and on key UPDATE, and which partner is first is the catalogue row order - a restore reorders it. fire-crab walks every partner in `RDB$INDEX_41` order (the constraint it names is the first that fails, so on its own restore it names `INTEG_28` where the shipped file names `INTEG_17`; both are right). Gates: `describe` 110, `union` 27, `arrays`, `syscat`/`insert`/`groupby` (database-argument), the trigger/check/domain/psql/gbak/attach/restored families, 0 DIFF; 161 + 344 unit tests.
- **DONE 2026-09-06 - THE RESTORED DATABASE'S SECURITY CLASSES AND DEPENDENCIES ARE THE ENGINE'S TOO.** Two of the three catalog-only differences the employee restore left are closed; what remains is the view's `RDB$DBKEY_LENGTH` (16 here - gbak's own "adjusting views dbkey length" pass computed and MODIFIED it, and the engine answers that count 2 in SQL - against the engine's 0, whose mechanism is not pinned). **SECURITY CLASSES (`dfw_grant`).** The measurement that made this a defect and not a diff: on the engine's restore a non-SYSDBA user is refused `no permission for USAGE access to GENERATOR EMP_NO_GEN`; on the row-only restore the same user READ the generator - the engine treats a class with no `RDB$SECURITY_CLASSES` row as unchecked, so the restored database was MORE permissive than the original. gbak's backup carries class NAMES on the object rows and no class rows; the engine recompiles every class from the restored `RDB$USER_PRIVILEGES` (vio.cpp rel_priv -> `dfw_grant` -> `GRANT_privileges`, grant.epp:89). Now: a stored privilege row posts `GrantPrivileges{name, type}` (one run per object however many rows posted it); at commit the class ACL is compiled through the GRANT compiler this server already had (`recompute_acls` / `build_object_acl`), the class row CREATED when the object only names it, and a relation without `RDB$DEFAULT_CLASS` given `SQL$DEFAULT<n>` (byte-identical to its own class until field grants restrict it - measured). An object row stored WITHOUT a class draws `SQL$<n>` from the RDB$SECURITY_CLASS generator and posts the same task (`set_security_class`) - the backup names no class for its 71 system-named domains. A privilege stored with a NULL grantor gets the current user (`beforeInsertUserPrivilege`, SystemTriggers.epp:1221). Result: 141 object ACLs byte-identical (every table, default class, procedure, generator, exception, domain), privilege rows identical, the test user's session identical. **DEPENDENCIES (`MET_get_dependencies`).** gbak backs none up; the engine derives them compiling each object's BLR with `csb_get_dependencies`. This server does the same from the BLR the rows carry: `ods::blr::decode` - converted from the engine's own print table (blp.h) - now walks EVERY verb the printer knows (the special atoms too: `blr_abort`'s condition, error handlers, join, union/recurse, map, cursor_stmt, exec_stmt's tags, derived_expr, window, sub-routine declarations, dcl_local_table, outer_map, and the FB6 `blr_invoke_function` / `blr_invoke_procedure` / `blr_select_procedure` / `table_value_fun` / `for_range` / `invoke_agg_function` tag lists, the `blr_flags` header, the descriptor NAME forms `blr_domain_name*` / `blr_column_name*` / `blr_not_nullable`) and emits the events the engine's `PAR_dependency` / `addDependency` sites fire: a stream on a relation or procedure (the NULL-field row), a field of a bound context (contexts 0 and 1 of a trigger are its relation, as `PAR_blr` binds them - which is why a trigger's own columns give field rows and no relation row), a procedure called (and its named arguments), a generator drawn (system ones dropped), an exception raised or handled, a user function (never a system function or a sub-routine), a domain or column named in a descriptor, an explicit collation. `StoreDependencies{kind, name}` is posted by a stored procedure (5), trigger (2) or view (1, plus its columns' base fields as `PAR_make_field` records them); rows are deduplicated on (name, type, field) and inserted in the engine's pop order. Result: the 157 rows of the engine's restore, IDENTICAL (dependent, depended-on, field, both types, both schemas) - and the engine now refuses `DROP EXCEPTION UNKNOWN_EMP_ID` on the fire-crab file exactly as on its own. **Two laws.** A grammar table copied from the printer is the honest one: it is what the engine uses to render its own BLR, and an atom read one byte wide desynchronises everything after it - the walk consumed every procedure, trigger and view of the sample to its `blr_eoc`. And "readable" has a third half: catalog diff, gfix and SELECT all passed a database that let the wrong user in.
- **DONE 2026-09-06 - THE EMPLOYEE SAMPLE RESTORES THROUGH fire-crab, AND WHAT IT LEAVES IS THE ENGINE'S OWN RESTORE.** `gbak -c -v employee.fbk 127.0.0.1/<fc>:...` runs all 523 verbose lines to `adjusting the ONLINE and FORCED WRITES flags`, exit 0, no server refusal, and the real engine then reads the file: `gfix -v -full` clean; `isql -x` extracts DDL IDENTICAL to the engine's own restore of the same backup (83 domains with defaults and CHECKs, 11 tables, the view, 22 procedures with 69 parameters, 4 user triggers, 5 exceptions, 2 generators, 14 foreign keys, 68 check constraints, both array columns, every privilege); every read agrees (row counts, the INTEGER and VARCHAR arrays element by element, the text blobs, the COMPUTED columns, `GET_EMP_PROJ`, `DEPT_BUDGET`, `ORG_CHART`, the view, generator values); and every WRITE agrees - a trigger-assigned key, a domain validation refusal, two CHECK refusals naming the same constraint triggers, the salary-history trigger's row, the customer generator, and the generator values AFTER the failed statements, which is the check that found the last defect. **Three catalog-only differences remain and are the next chunk:** `RDB$DEPENDENCIES` is 0 here and 157 there (the engine builds them compiling the BLR at `dfw_create_procedure` / `_trigger` / `_relation` with `dfw_arg_check_blr`; fire-crab populates them nowhere), `RDB$SECURITY_CLASSES` is 554 against 678 (the `SQL$<n>` and `SQL$DEFAULT<n>` classes `dfw_grant` computes from the restored `RDB$USER_PRIVILEGES` rows - a non-SYSDBA user would notice), and the view's `RDB$DBKEY_LENGTH` is the 16 gbak's own "adjusting views dbkey length" pass computed here against the engine's 0 (the engine answers the same count query 2 when asked in SQL afterwards; the mechanism behind its 0 is not pinned). **Fourteen walls, in gbak's order, each a fact about the engine:** a blob in a legacy message decodes as a DSQL blob parameter does (`quad_wire` then `decode_blob_id`; the old arm kept 16 bits of the wrong word), and the store MATERIALISES the temp blob into the target relation before the row (`blb::move` from `EXE_assignment`, blb.cpp:1264 - the target column's sub_type and CS_BINARY win); `RDB$FIELD_DIMENSIONS` and `RDB$VIEW_RELATIONS` are rows; a VIEW gets a format and no pages (`create_view_storage`); a blob or array field FELL OUT of `catalog_field_list` because `field_type_to_dtype` did not map 261 and reported the domain row missing (JOB's `RDB$3`); a generator's id is drawn AT STORE TIME from the master generator and its slot zeroed (vio.cpp:4652 `set_metadata_id`, `dfw_set_generator`), and its VALUE arrives as `<declared int64 var> = gen_id3(<gen>, <value>)` - `blr_dcl_variable` in the header and `blr_variable` as a target, a draw not a read; an exception's number, a procedure's and a function's id come the same way from the system generators named for them (`METADATA_IDS`); procedures, functions and triggers are their SOURCE here (this server re-parses `RDB$PROCEDURE_SOURCE` / `RDB$TRIGGER_SOURCE`) so their rows are storable; a BATCH translates only `blr_blob2` parameters through its blob map - an array's `SQL_QUAD` id from `op_put_slice` passes untouched (DsqlBatch `m_blobMeta`; `PSlot::Blob` is now distinct from `PSlot::Quad`); a VARYING array element crosses the wire as `xdr_datum`'s CSTRING form (`SDL_info` types `blr_varying2` dtype_cstring, length + sizeof(USHORT)) and lands in a 17-byte `vary` slot; **a BIGINT message field decoded to NULL** - every `RDB$TRIGGER_TYPE` (the extract showed `ACTIVE AFTER` with no event and lost every CHECK constraint) and `RDB$INITIAL_VALUE`; the engine created the target WITHOUT the PUBLIC-schema DDL grants gbak is about to store (`ini.epp:577/819`), so `remove_public_schema_grants` follows `remove_public_schema`; **gbak stores `RDB$COMPUTED_BLR` / `RDB$VALIDATION_BLR` only after every relation exists, by a MODIFY of `RDB$FIELDS` (`update_global_field`)**, because the BLR names tables - so a table's format and `RDB$RUNTIME` are built without them, and the engine's `dfw modify_field` re-versions every dependent table (`FieldChanged`: a new format when the layout changed - the three computed-column tables end at `RDB$FORMAT` 2 in the engine's restore for exactly this reason - else a summary refresh); triggers arrive after the table AND its data, and the engine loads a table's triggers from the summary's `RSR_trigger_name` entries, so a summary without them is a table whose triggers never fire (`RefreshRuntime` at the trigger's commit); the summary must carry `RSR_dimensions` / `RSR_array_desc` or DSQL answers "scalar operator used on field which is not an array" over a correct catalog; and **same-position triggers fire in the summary's order, which is two passes** - user triggers, then CHECK / FOREIGN KEY constraint triggers, each `SORTED BY RDB$TRIGGER_SEQUENCE` (DdlNodes.epp:9190-9250) - so `SET_EMP_NO` runs before `CHECK_3` and a row that fails its check still draws the generator; lexical order put CHECK_3 first and read 147 where the engine reads 148. **Laws this reinforced:** a catalog diff, a clean gfix and a successful SELECT are three checks of the same half - the WRITE side (triggers, validation, generators after failure) is where the last two defects lived; `cast(blob as varchar octets)` flattens a SEGMENTED summary blob and cannot be parsed by tag; the 13 DB-argument gates fed a port number fail with `CONN_ERR` on every check and look exactly like a regression. **fire-crab SQL gaps met on the way (not restore defects):** array subscripts in a SELECT list (`language_req[1]`), an 11-way `UNION ALL` of `count(*)` rows, and a JOIN whose ON carries `IS NOT DISTINCT FROM`.
- ~~**MEDIUM (missing conversion, no gate green) - a CLIENT-DRIVEN `gbak -c` / `gbak -r` restore into fire-crab is not implemented.**~~ **DONE 2026-09-05 - `qa/serve-real-attach.sh` 18/18.** `gbak -c` and `gbak -r -rep` over the wire run to `finishing, closing, and going home`, exit 0, no errors, and the database they leave is the engine's own restore of the same backup: schema, domains, relation and columns, the primary-key index (id 1, unique, active, selectivity 0.5), both constraints, five privileges, the rows the engine reads back by key and a duplicate it refuses with its own vector, four of five system name counters at the engine's values (RDB$SECURITY_CLASS differs by one - the schema-class draw this server's create path skips), `gfix -v -full` clean. **The last seven defects, every one invisible to a check that was passing:** gbak's batch buffer size of ZERO means the hard limit (DsqlBatch.cpp:117) and answering it back as zero failed libfbclient's own guard; `blr_double` in a message is a big-endian IEEE double with NO scale byte in its descriptor; a bare declared variable name must fold to upper like every other bare identifier; `FIRST (1)` is `FIRST 1`; `x = gen_id(G, 0)` is a read, not a draw; `SET GENERATOR SYSTEM.X` names its schema; and a body's `EXECUTE STATEMENT 'SET ...'` is an immediate statement, not a query. The narrative of the whole chunk is below; what it was sized as, and what it turned out to be, differ in a way worth reading. **THE EXECUTOR, `blr_modify`, `blr_store` AND THE CREATE DPB LANDED 2026-09-04/05; the blocker was then the CATALOG-WRITE STACK for `RDB$RELATIONS`.** **Where it stops, measured 2026-09-05:** the restore writes the PUBLIC schema, both domains, and COMMITS ITS METADATA, then stops at `restoring table "PUBLIC"."SRC"` with `a BLR store into RDB$RELATIONS needs the deferred work a row alone does not do`. What it wrote is IDENTICAL to the engine's own restore of the same backup - the schema row (PUBLIC, system flag 0, owner SYSDBA, beside SYSTEM) and both domains (`RDB$1` type 8 length 4, `RDB$2` type 37 length 20). **THE CREATE DPB IS NOW HONOURED.** `create_database_file` took a PATH and nothing else: it does not synthesise a database, it has the engine make one, and the consequence nobody had drawn was that the client's create DPB was dropped entirely - every target came out 8192-byte pages with a full standard catalog. `isc_dpb_page_size` is honoured (a 16384-page source now restores as 16384), and so is `isc_dpb_gbak_restore_has_schema` (107): it means *do not create the PUBLIC schema, I am about to store it myself*, the engine skips the store at `ini.epp:819`, and fire-crab - which cannot skip what it does not create - REMOVES the row afterwards, which leaves the same database. The index entry stays behind as it does everywhere here (a conflicting entry counts only while its record still builds that key), so the name is storable again immediately, which is exactly what the restore then does. New `ddl::delete_system_row`, the third thin public face on the catalog writers. **THE FLAG IS GATED BY `isc_dpb_gbak_attach` (59), and reading it as a bare tag was a defect** (fixed 2026-09-05): the engine acts on 107 only inside `if (options.dpb_gbak_attach)` (jrd.cpp:2977-2982), and that is set only by tag 59 carrying a NON-EMPTY string (jrd.cpp:7224-7229). So 107 alone does nothing in real Firebird, and a server that honoured it alone would hand any client a database missing its PUBLIC schema. No gate could have caught this - the only client that sends 107 also sends 59, so the behaviour differs only for a client nobody has written. **Still not reproduced, and it WILL collide the same way further in - fire-crab removes ONE row where the engine skips about FORTY-THREE.** Skipping the `ini.epp:819` block skips four things, not one: the `RDB$SCHEMAS` row, the `RDB$SECURITY_CLASSES` row `SQL$<n>` it draws for it, and TWO `RDB$USER_PRIVILEGES` rows (privilege `G`, object PUBLIC, object type 38 - one to the owner WITH GRANT OPTION, one to user PUBLIC). And `ini.epp:577` skips, for each of the ten schema-scoped DDL object types, three `RDB$USER_PRIVILEGES` rows (`ALL_DDL_PRIVILEGES` = `CLO`, objects `SQL$TABLES`, `SQL$VIEWS`, ...) and one `RDB$SECURITY_CLASSES` row (`SQL$D22PUBLIC` ... `SQL$D32PUBLIC`) - thirty privileges and ten classes. `RDB$TYPES` is NOT affected (it has no schema column). The restore stores its own of all of these, so each is a duplicate waiting to happen. `vio.cpp:3355`/`4131` use the flag's ABSENCE to drive a legacy search-system-schema fixup fire-crab has never had. **THE RELATION-STORAGE MACHINERY IS WRITTEN AND NOT YET TRUSTED (2026-09-05).** `ddl::create_relation_storage` builds a relation's storage at commit out of the catalog as it then stands: it assigns the id and format the client leaves NULL, lays the format out from the column rows that arrive AFTER the relation's own, allocates the pointer and index-root pages, and writes the `RDB$PAGES`, `RDB$FORMATS`, `RDB$FIELD_ID` and `RDB$RUNTIME` that name them. Driven through gbak it leaves a catalog ROW-FOR-ROW IDENTICAL to the engine's own restore of the same backup - relation id 128, format 1, two field rows with matching ids, positions and sources - differing only in `RDB$DBKEY_LENGTH` and the content behind the runtime blob id. **And the engine answered `-204 Table unknown` for the result - because THE ROW WAS WRONG in a way that diff could not show.** `RDB$EXTERNAL_FILE` came out an EMPTY STRING where it must be NULL, and a relation whose external file is not null is an EXTERNAL TABLE. **The claim that the catalog was row-for-row identical was itself the error**: the columns compared were the ones that looked structural - id, format, field count, type, flags, owner, schema - and `RDB$EXTERNAL_FILE` was not among them, while an empty string and a NULL print alike in most renderings. What found it was not a wider diff against the engine but a diff against a table THIS SERVER CREATES ITSELF and the engine reads without complaint, in the same file: two differences, one of them the whole answer. **ROOT CAUSE, FIXED 2026-09-05:** `blr_parameter2` carries a value index AND a null-indicator short the client sets to -1. Read as an assignment TARGET fire-crab used both; read as a SOURCE it took the value slot and discarded the indicator, under a comment asserting it was "unused when read as a source". The value slot of a NULL parameter holds whatever was in the buffer - an empty string for text, zero for a number - so EVERY NULL a client sent became one of those. **AND THE -204 ITSELF HAD A SECOND CAUSE, FIXED 2026-09-05: A ROW IS KEYED WHEN IT IS WRITTEN.** `insert_system_row` keys a record into every index as it writes it; `patch_system_row` does NOT re-key. So a relation stored with a NULL `RDB$RELATION_ID` and patched afterwards kept the `RDB$INDEX_1` entry built when its id was null - and RDB$INDEX_1 is the index ON `RDB$RELATION_ID`. Resolving a table name is TWO probes with two different keys: name to id on (schema, package, name), which succeeded, then id back to the relation (`WITH REL.RDB$RELATION_ID EQ getId()` in `jrd_rel::scan`), which the stale entry made miss. **A relation whose every catalog column reads correctly and whose id index says otherwise is answered exactly like one that was never there.** The engine has the same two probes and never has the problem, because `beforeInsertRelation` assigns the id BEFORE the record is written (and asserts the client did not supply one). fire-crab now stamps it into the values before the insert, via the new `ddl::next_free_relation_id`. **AND THE INDICATOR TEST WAS WRONG TOO, FIXED 2026-09-05 - THE ONE THAT FINISHED IT.** The engine's test for a parameter's null flag is `if (MOV_get_long(tdbb, desc, 0))` - a TRUTH TEST, not a comparison against -1 (`ParameterNode::execute`). GPRE writes the flag from `X.FIELD.NULL = TRUE`, which is **1**; this server writes **-1** on the way out, as an SQL indicator does, and read the indicator on the way in looking for -1. So it accepted EVERY one of gbak's nulls as a value. **The "misaligned decoder" this was blamed on does not exist**, and the evidence ruling it out was already in hand: the connection never desynchronised, so the decoder consumed exactly the right byte count, so the widths were right. A stream that stays in sync cannot be misaligned. **WITH THAT, `gbak -c` THROUGH fire-crab BUILDS A REAL TABLE.** It writes the schema, both domains, the relation and its columns, and the ENGINE reads the result: `SHOW TABLE SRC` gives `ID INTEGER Not Null` / `T VARCHAR(20) CHARACTER SET SYSTEM.NONE Nullable`, which is what the engine's OWN restore of the same backup produces column for column, nullability and charset included, with `gfix -v -full` clean. The engine's copy additionally carries `CONSTRAINT INTEG_2: Primary key (ID)`; the restore now stops at `restoring index "PUBLIC"."RDB$PRIMARY1"`. **`RDB$RELATIONS` and `RDB$RELATION_FIELDS` are on the storable list** - not because a catalog diff says they look right, which is the check that was wrong twice, but because the engine reads the object. **`RDB$INDICES` / `RDB$INDEX_SEGMENTS` / `RDB$RELATION_CONSTRAINTS` LANDED 2026-09-05.** `ddl::create_index_storage` is `create_relation_storage`'s sibling and the same shape - the segment rows arrive after the index's own, so the b-tree is built at commit out of the catalog. It allocates the index-root slot, stamps the `RDB$INDEX_ID` that names it, keys every existing row in and writes the selectivity. A PRIMARY KEY is not visible on the `RDB$INDICES` row at all (the engine records it only in `RDB$RELATION_CONSTRAINTS`), so the build asks there before setting `irt_primary`. Measured: the index gbak restores is IDENTICAL to the engine's own on EVERY column - `RDB$PRIMARY1` on SRC, id 1, unique, one segment, inactive 0 - with `gfix -v -full` clean. **A TIMING DIVERGENCE, RECORDED DELIBERATELY:** `RDB$INDEX_INACTIVE` is not a copy of the source index's state - gbak stores EVERY index as **3**, `DEFERRED_ACTIVE` (restore.epp:97), a primary key included, because the coercion at restore.epp:6843 turns an active index into a deferred one unconditionally. Storing that row posts the engine NO work: `indexDfw` returns without posting when `RDB$INDEX_ID` is null. The engine builds much later, when the restore's tail modifies the 3 back to 0 after the data is loaded (`SystemTriggers::afterUpdateIndex`). fire-crab builds at the store's commit instead, which is safe HERE because its DML keys every written row into whatever indexes the relation's root already carries (`resolve_index_ops`) - an index built empty before the load ends up holding the same entries. What must not outlive the build is the FLAG: a 3 says "not built yet" about an index that is, so the build clears it. A correction with it: the catalog relations' ids were HARDCODED (31, 4, 23) where this module resolves them by NAME everywhere else, and a walk over the wrong relation finds nothing and reports the row missing. ~~**AND THE TABLE THE RESTORE BUILDS IS READ-ONLY TO THE ENGINE**~~ **FIXED 2026-09-05: `RDB$FIELD_TYPE` IS THE BLR CODE, NOT THE dsc DTYPE.** The two are different numbering schemes that OVERLAP, which is what let it survive every check: BLR 8 is a LONG and dsc 8 is a SHORT, BLR 37 is a VARYING and dsc 37 is nothing. `catalog_field_list` handed the catalog's value to `compute_format_mixed` unmapped, so a restored relation's format described its INTEGER as a SHORT and its VARCHAR as an unknown type - and, the VARYING arm never firing, without the two bytes a varying's length prefix needs. The mapping already existed one screen away (`field_type_to_dtype`). **WHY FOUR CHECKS PASSED OVER A BROKEN OBJECT:** every catalog COLUMN agreed with a table fire-crab creates itself, because the wrongness was inside the format DESCRIPTOR BLOB, which a column diff cannot see; `SHOW TABLE` printed the right types, because SHOW reads `RDB$FIELDS` and not the descriptor; `SELECT` answered, because there were no rows to decode; `gfix -v -full` was clean, because the page structure was intact. The check that found it was `SET BLOB ALL` on the descriptor, against the same table created the working way. **NOW the engine INSERTs, commits and reads back by key, and the restored PRIMARY KEY refuses a duplicate with the engine's own vector naming the index fire-crab built.** **NEXT: the data load** (gbak reports `could not start batch when restoring table ... trying old way`, then falls back to a `blr_store` into a USER relation, which refuses). **Three silent failures were found getting there, each worth keeping:** a NULL relation id READS AS ZERO (`relation_row` takes it from a fixed offset without consulting the null bitmap), and relation 0 is `RDB$PAGES`, which has an index root - so the "does it already have storage" guard matched every time and the task did nothing while reporting success. The PUBLISHED IMAGE CARRIES NO DEFERRED LIST - a work copy clones the Image whole, so anything left on `work.ddl_deferred` is dropped at `install_dirty` and must be moved onto the attachment to survive to the commit that runs it. And the catalog must be READ WIDE, because this work runs at commit but BEFORE the TIP flip, so the rows it exists to read are still uncommitted. **AND THE PREMISE WAS WRONG, which is where the next attempt should start:** in Firebird 6 `dfw_create_relation` is nearly EMPTY - phases 1-6 return "call me again", phase 7 only commits a metadata-cache version. The page allocation moved to a STORE-TIME pseudo-trigger (`SystemTriggers::afterInsertRelation`, gated on `isRWGbak()`, calling `DPM_create_relation`), and the format, `RDB$FORMAT` and `RDB$RUNTIME` moved into the metadata-cache SCAN that `dfw_commit_relation` forces at phase 3. `beforeInsertRelation` assigns the relation id and ASSERTS the client did not supply one. So the engine builds pages EAGERLY and defers only the DESCRIPTION - the opposite split from the one built here. **`blr_store`'s allow-list is the honest boundary and it is by NAME**: `RDB$SCHEMAS` and `RDB$FIELDS`, because for both the row IS the object. The engine posts `dfw_create_field` for a domain, but that task only registers DEPENDENCIES (dfw.epp:3090) - no page, no object - and fire-crab populates `RDB$DEPENDENCIES` nowhere, so that gap is one this server already has everywhere. `RDB$RELATIONS` is the line: its store posts `dfw_create_relation`, and a row without it is a catalog entry for a table the file cannot hold. **Where it stops, measured:** the restore runs the whole metadata path - both `RDB$DATABASE` modifies, the security-class generator draw, and the `STORE X IN RDB$SCHEMAS` - and that store is refused by its own unique index with `duplicate key`. It builds the RIGHT row (PUBLIC, owner SYSDBA, security class `SQL$470` where the engine's own restore drew `SQL$469` - one generator, both drawing). The engine never hits this because gbak passes `isc_dpb_gbak_restore_has_schema` (DPB tag 107) at create and the engine then SKIPS creating the PUBLIC schema, precisely because the restore is about to store it (`ini.epp:817`, `restore.epp:1030`). fire-crab's `create_database_file` shells out to real `isql` and ignores the DPB, so the target always has PUBLIC. **That is the next thing to fix, and it is the entry two below this one.** **A SILENT WRONG ANSWER WAS FOUND AND FIXED GETTING HERE:** `op_start_and_send` / `op_start_send_and_receive` delivered the client's message and answered SUCCESS without RESUMING the request. `EXE_send` ends by resuming (exe.cpp:967); every program this server had run before ends in a `blr_send`, so the following op_receive pumped the body anyway and the omission was invisible. A GPRE `STORE` has no send - nothing follows to pump it - so its body never ran and the client was told it had. gbak narrated a whole metadata restore and committed a database with ZERO user relations. **What executes now:** `blr_gen_id3` (231, a generator named with its SCHEMA and an explicit-step FLAG), `blr_literal blr_int64` (eight LE bytes, which is how a generator step travels), a generator DRAW in a send (a page write, so it happens before the evaluation rather than inside `eval_blr_val`, which every read path shares and which holds the database immutably; a generator nested in an expression REFUSES rather than quietly reading), `blr_handler` as a real ERROR BOUNDARY (it swallows an unwind carrying label 0, which is why GPRE emits it only where the source wrote `ON_ERROR`), and `blr_store` into a system relation whose row is the whole object. **`blr_store` REFUSES BY NAME everything but `RDB$SCHEMAS`**: a row in `RDB$RELATIONS` or `RDB$FIELDS` is a catalog entry, not a usable relation - the pointer page, the format blob and the `RDB$PAGES` rows come from the engine's deferred work (`DFW_post_work`), and storing only the row leaves a database whose catalog describes tables the file cannot hold. A blob column refuses too: the client writes the segments separately and names the id here, so a row stored without it has lost a column while reporting success. **Measured after that slice: gbak now runs the request that stopped it AND the one after it** - the trace reads `op_compile / op_start_and_receive / op_receive / op_send / op_send / op_receive / op_release`, and the `RDB$DATABASE` row fire-crab wrote is IDENTICAL to the engine's on every column after restoring the same backup both ways, with `gfix -v -full` clean. It now dies at `STORE X IN RDB$SCHEMAS` - 283 bytes of `blr_message 0` (fifteen descriptors), `blr_receive 0`, `blr_store blr_relation "RDB$SCHEMAS"`, assignments - which is the next slice and needs the catalog-write stack below.**The executor is done and is now the ONLY one**: `BlrMachine` is an explicit frame stack mirroring `EXE_looper`'s trampoline, `isc_transact_request` drives it too, and the old recursive materialising executor is deleted. The inbound `op_send` arm (opcode 25 travels in BOTH directions) is what un-parks a request. `blr_modify` writes through a new `ddl::patch_system_row`, refuses a USER relation (it would bypass the ordinary planner's constraints, triggers, indexes and referential actions) and refuses a row its OLD tuple does not uniquely identify (this for-loop carries values, not an address). No write token is held across a packet - see the risk note below, which is now MEASURED rather than open. Once the attach stopped lying (below), gbak op_creates the target, starts its transaction, reads the catalog, and then dies at `op_compile` of the request GPRE built for `FOR (RDB$DATABASE) ... MODIFY` - 170 bytes whose body is `blr_label / blr_loop / blr_select / blr_receive / blr_leave / blr_handler / blr_modify`. gbak reports `ERROR:Dynamic SQL Error`, rc=1; the empty shell IS created and is a real database (`gfix -v -full` clean) holding no user table. fire-crab's restore has always been the SERVICE path only (`isc_action_svc_restore`, `qa/serve-real-gbakrestore.sh`), and `fbsvcmgr ... action_restore` into a fresh path still restores the rows and passes `gfix -v -full`.
  **What landed.** The GRAMMAR now covers the legacy write verbs and the co-routine that drives them - `blr_store` (15), `blr_modify` (10), `blr_erase` (5), `blr_label` (17), `blr_loop` (9), `blr_leave` (18), `blr_select` (13), `blr_handler` (11) - with `blr_receive` keeping the message number a `blr_select` dispatches on, and `blr_marks` (217, `PAR_marks`: verb + a LENGTH byte that must be 1, 2 or 4 + that many bytes, par.cpp:735) skipped at the four sites the engine peeks for one. `blr_marks` is not decoration: gbak's DATA store request carries `blr_marks 1 0x10` (MARK_BULK_INSERT, restore.epp:14520), so a parser without it cannot READ the row-writing request. The 170 bytes are captured off the wire and pinned as a unit test, which corrected the hand-decode this work started from: **the trailing `blr_send` is a SIBLING of the `blr_for`, not the last statement of its body** (gpre/cmp.cpp:989-999). `blr_assignment` as a STATEMENT now builds a real target - it used to parse both operands and yield `Nop`, harmless only while nothing this executor could run was able to write.
  **PARSING FURTHER THAN YOU CAN EXECUTE IS GATED.** `blr_stmt_runnable` refuses at `op_compile` any program carrying a verb `exec_blr_request` cannot run - it materialises every output message up front from an IMMUTABLE database, so it can neither suspend at a `blr_select` nor write. Without the gate such a request would compile, run, write nothing and answer SUCCESS, which is the one failure a client has no way to tell from an answer. The refusal is byte-for-byte the one that stood before the grammar grew. **The gate has TWO callers, `op_compile` and `op_transact` (`isc_transact_request`): narrow it when the executor lands, never delete it.**
  **THE EXECUTOR'S CONTRACT, measured (exe.cpp).** `EXE_send` drives the request forward until `req_operation == req_receive` (`isc_req_sync` + "Request expected to receive but need to send" if it finds `req_send`), then picks the `blr_select` branch by LINEAR SCAN on the client's message number (exe.cpp:936-947); no match is a BARE `isc_req_sync`. `EXE_receive` is the mirror (forward until `req_send`; "Request expected to send but need to receive"), a wrong number is "Request got wrong message" and a wrong length is `isc_port_len(given, expected)`. A `blr_send`'s assignments are evaluated at RECEIVE time, not at start (exe.cpp:762-771). The engine holds NO C++ stack across a suspension: `EXE_looper` is a trampoline over `(req_operation, req_next, req_message, req_flags, req_label)`, so the conversion is an explicit frame stack, not a recursive interpreter.
  **Three corrections to earlier readings of this request.** `blr_handler` is an ERROR HANDLER, not a transparent wrapper - it swallows ANY unwind whose `req_label` is 0, the error unwind included (StmtNodes.cpp:6793-6810), which means a FAILING modify is silently absorbed by gbak. `blr_leave 0` does NOT leave the FOR: the label encloses only the loop, so leaving it falls out of the for-BODY and makes `ForNode` fetch the NEXT record (StmtNodes.cpp:6337-6350). And a system-table write is permitted only for a GBAK attachment (`protect_system_table_delupd`, vio.cpp:6945-6974) - a rule fire-crab does not have and must not acquire accidentally.
  **WHAT GBAK ASKS FOR NEXT, and it is why closing this one request moves NO gate check.** The next wall is twelve lines away in `restore.epp`: `att_database_dfl_charset` is the SAME program with a 22-character name (156 bytes), then `att_database_linger` (message 1 is `blr_long`), `att_database_sql_security` (`blr_short`), and `att_database_description`, which modifies a BLOB column and additionally needs `op_create_blob2` / `op_put_segment` / `op_close_blob`. Then the metadata record stream opens with `STORE X IN RDB$SCHEMAS` (restore.epp:8685) - a DIFFERENT and much smaller shape (`blr_message 0 / blr_receive 0 / blr_store <rel> <ctx> / assignments`; no for, no select, no loop; driven by ONE `op_start_send_and_receive` PER ROW, because `activate_request` kills the previous incarnation) - but it needs the whole CATALOG-WRITE stack: `sysfmt` format 0, `ddl::maintain_indexes` (the system relations DO carry indexes, idx.h:64-76), and the DFW equivalent (`Image::ddl_deferred` + `apply_ddl_deferred` at commit). **A `blr_store` into `RDB$RELATIONS` that writes only the row leaves a relation with no pointer page, no format blob and no `RDB$PAGES` rows.** So the executor and enough of the catalog-store surface have to land TOGETHER to turn one check green; splitting them produces an ungateable half.
  **What is NOT on the critical path: user table rows.** With the version banner fixed (below) gbak scrapes `/P20`, gets `>= 16`, and restores DATA through the IBatch path fire-crab already implements (`serve-real-batch` 22, `batchblob` 52). The hand-built `blr_bulk_insert` / `blr_relation3` store request is only reached if `createBatch` fails and gbak falls back (restore.epp:14194-14203).
  **Build it on `collect_dml_targets`** (`crates/wire/src/server.rs`), which already returns `(page, slot, format_no, image)` and is `&Database`-only, and which carries the limbo law (`EvalErr::RecInLimbo`) a hand-rolled walker would drop. `for_each_record` yields values with no address and is the wrong walker for a writable FOR. Note `RDB$DATABASE` has NO indexes and NO system triggers (idx.h has no `rel_database` entry), so the whole `IDX_modify` and trigger layer is out of scope for the FIRST request; its writable format is `sysfmt::system_relation_formats(..., "RDB$DATABASE")` at FORMAT 0, because `Database::relation_meta` reads `RDB$FORMATS` only and is deliberately not given the sysfmt fallback - the `Plan::*` machinery is STRUCTURALLY UNREACHABLE for a system relation. The precedents to copy are `ddl::patch_sys_row` and `ddl::database_default_charset`.
  **Four constraints the executor must respect.** `release_write_side` runs at the TOP of every op-loop iteration ("BETWEEN REQUESTS, THE DATABASE IS NOT HELD"), so a frame CANNOT hold a write token across `op_send`; use per-resumption `work_copy_with_tx` -> `install_dirty` -> `adopt_tx`, the shape `fire_triggers_published` already uses. The new `op_send` arm must NOT call `switch_named_tx`: the engine pins `req_transaction` at start (`TRA_attach_request`) and `p_data_transaction` is stale garbage the client never sets for `op_send`. `send_request_batch` IGNORES the requested message number when its queue has data, and changing that drain behaviour regresses `serve-real-show` / `showdb`. And `BStmt::For` materialises the cartesian product from the PUBLISHED image, so a resumed loop iterates a start-time snapshot while its own modify publishes underneath it - invisible for one-row `RDB$DATABASE`, not for the restore-tail loops (restore.epp:12105-12294), where the engine keeps a live cursor.
  ~~**Still unread, and the riskiest unknown:**~~ **SETTLED 2026-09-04.** The write side is ONE RECURSIVE MUTEX PER DATABASE FILE PER PROCESS (`cch::pool::SharedImage.write`, a `ThreadId`-owned `WriteState` behind a `Condvar`), acquired only by `Database::take_write_side` and held in `Database.write`. Readers never take it - they clone an `Arc` snapshot - so what it blocks is other attachments' WRITES, *including their commits and rollbacks*, for `FC_WRITE_WAIT` (default 60s) before they fail with `lock conflict: another attachment is writing this database`. There is no deadlock detection, and the code says why: the write side is not a lock the lock table knows about, which is why `with_conflict_wait` drops it FIRST before waiting on a row. A suspended request blocked on `read_int` while holding it would stall every other writer for a minute with nothing able to see the cycle - which is exactly what `release_write_side` at the top of every op-loop iteration exists to prevent. **So a resumable request must re-acquire per resumption and carry no token, and the one that landed carries none.**
  **Grammar gaps for the requests AFTER this one**, recorded so they are not rediscovered: gbak's hand-built `store_blr_gen_id` uses `blr_dcl_variable` (3); `fix_security_class_name` uses `blr_gen_id3` (231) where fire-crab knows only 101; the `blr_store` arm demands `blr_relation` (74) and rejects `blr_relation3` (148), `blr_rid` (75), `blr_store2` (19), `blr_store3` (213) and `blr_bulk_insert` (33); and the legacy count-form rse (a `blr_for` with no `blr_rse` verb, par.cpp:1322) is unhandled but latent, since GPRE always emits `blr_rse`.
  **BLR HAS THREE DISJOINT OPCODE NAMESPACES** - descriptor, value, statement - that REUSE numbers: 41 is `blr_parameter2` AND `blr_cstring2`; 19 is `blr_store2` AND `blr_domain_name2`. fire-crab keeps them apart already. **Any implementation that builds ONE 256-entry table is wrong.**
- ~~**MEDIUM (wrong message format, pre-existing, could desync the connection)**~~ **FIXED 2026-09-04** - `op_start_and_send` read the client's message NUMBER and threw it away, decoding every body as message 0. Harmless while every request this server ran sent message 0, and fatal the moment one does not: the bytes after the header are laid out per THAT message's descriptors and the shapes differ in LENGTH (gbak's request declares message 1 as `cstring(253)` - a 4-byte length, n bytes, padded to 4 - and message 2 as a flat 4-byte `short`). Decoding one as the other does not answer wrongly; it leaves the wrong number of bytes in the buffer and the next read lands in the middle of the following packet. Found by reading the engine's own handler against this one, not by a gate - no gate could see it, because no gate sends a message other than 0.
- ~~**LOW (parser accepted what the engine refuses, pre-existing)**~~ **FIXED 2026-09-04** - the BLR parse skipped byte 0 without looking at it, where `PAR_blr` accepts only `blr_version4` (4) or `blr_version5` (5) and answers `isc_wroblrver2` otherwise (par.cpp:645-673); and it stopped at the end of the statement without requiring `blr_eoc`, where the engine reads exactly ONE node and then insists on the terminator (par.cpp:214-217, `end_of_command`). The second is the one that mattered: a program fire-crab had MIS-READ - stopping early inside a verb decoded with the wrong operand count - was indistinguishable from one it had read correctly. One hand-built test fixture had to be CORRECTED rather than accommodated; it ended without `blr_eoc`, asserting that this server accepts a shape no client sends.
- **MEDIUM (divergence, pre-existing, no gate) - `create_database_file` shells out to the real `isql` and returns early if the path already holds a decodable header.** Two consequences nobody had named. gbak's DPB is IGNORED (`isc_dpb_page_size`, `isc_dpb_overwrite`, `isc_dpb_no_db_triggers`, `isc_dpb_shutdown`): the file is always 8192-byte pages. And an `op_create_database` over a path that already holds a database does NOT overwrite it, so **`gbak -r` restores into the OLD database rather than a fresh one**. "`gbak -c` into a fresh path" and "`gbak -r -rep` over an existing one" are therefore NOT the same test even once the requests execute - which is worth knowing before reading `qa/serve-real-attach.sh`'s two groups of red checks as one defect.
- **LOW (leak, pre-existing) - a compiled BLR request is never reclaimed except by `op_release`,** which drops the slot with no unwind; nothing removes slots on commit, rollback or detach. gbak releases requests while they are stalled mid-loop, and it never releases `reqHandleDflCharSetSchema` at all - its release list covers only `req_handle2..5` (restore.epp:11317-11320). So one slot leaks per connection for the life of a restore. Harmless at today's scale and a real leak once a frame holds a half-applied write.
- ~~**MEDIUM (attach lies, pre-existing)**~~ **FIXED 2026-09-04** (`qa/serve-real-attach.sh`) - `op_attach` to a database file it could not open answered SUCCESS (a `None` from `load_database` fell through to the fixed-answer path); the first statement then failed with `HY000 invalid transaction handle`. It now answers the engine's own status vector AT ATTACH TIME, and the three engine failures are told apart by DOING what the engine does - open the file, then read from it - so the classification is two rules, not four: an `open` that fails is `isc_io_error / "open" / <path> / isc_io_open_err / <strerror>` (a missing path, a missing DIRECTORY, and a file with no read permission all land here, differing only in the `isc_arg_interpreted` text); a file that opens and fails to READ is the same vector with `"read"` / `isc_io_read_err` (a directory, `Is a directory`); a file that opens and reads and still has no decodable header is `isc_bad_db_format / <path>`. Verified argument for argument against 127.0.0.1/3050 with the raw `ISC_STATUS` vector, all six cases. `op_create_database`, which legitimately names a path that does not exist yet, is told apart by ORDER rather than by an exemption: it runs `create_database_file` FIRST and answers its own error when that fails, so by the time the refusal is reached it has a real database. Consequence closed: `gbak -c` / `gbak -r` into a FRESH path no longer report `database ... already exists` about a file that is not there, and the target is created (the restore itself is the entry above).
- **MEDIUM (refusal, pre-existing)** - `CREATE INDEX` is refused on a table whose rows were written BEFORE an `ALTER TABLE ... ALTER COLUMN ... TYPE`.
- **LOW (pre-existing)** - the service-manager backup's I/O error is sent without its two string arguments, so the client prints `I/O error during "<Missing arg #1 ...>" operation for file "<Missing arg #2 ...>"` where the engine names the operation and the path (the failure IS reported and no partial file is left). `COALESCE` over a system CHAR metadata column refuses with `22000 Malformed string`. A VARCHAR through a fire-crab-created VIEW describes 80 characters wide where the engine says 20 (values identical).
- **LOW (pre-existing, verified identical on HEAD)** - fire-crab resolves a relation NAME POSITIONALLY: the first `RDB$RELATIONS` row carrying that name decides, for `resolve_relation`, `relation_schema` and now `view_of` alike. The engine resolves an unqualified name through the schema search path and a qualified one in the schema written. On a database where `CREATE VIEW S2.T` runs BEFORE `CREATE TABLE T`, both `SELECT ... FROM T` and `SELECT ... FROM PUBLIC.T` refuse on fire-crab (measured 4-way: engine answers, HEAD and the current tree both refuse identically). Making the three resolvers agree with each other was this chunk's fix; making them agree with the ENGINE needs a schema search path and is its own chunk.
- ~~**HIGH (silent wrong answers AND wrong writes, pre-existing)**~~ **FIXED 2026-09-02** (`qa/serve-real-joinderived.sh`, 25 checks; see "Found while converting a joined derived table" below) - a DERIVED TABLE or VIEW on the right of a JOIN reads the base relation's fields by OUTPUT POSITION instead of by the derived column's own field: `SELECT t.ID, d.S FROM TQ t JOIN (SELECT ID, G AS S FROM J1) d ON d.ID = t.ID` answers J1.A (base field 1) where the engine answers J1.G, `COUNT(*)` with `d.S = 'g1'` answers 0 for the engine's 2, and `INSERT INTO TQ (ID, A) SELECT t.ID+10, d.S FROM ... JOIN (SELECT ID, ID AS S FROM J1) d ...` PERSISTS the wrong column's values. Same through a view (`CREATE VIEW VS (ID, S) AS SELECT ID, G FROM J1`). `crates/wire/src/server.rs` build_flatten (~35107), set on a derived side by plan_join_bound (~35558) and consumed at ~35195 and frozen_probe_rows (~47869). Reproduced on the pre-change binary.
- **RETRACTED (2026-09-02) - the reported "silent metadata loss" does NOT reproduce.** The claim was that after a `CREATE INDEX` through fire-crab every later `CREATE TABLE` / `CREATE VIEW` reported success and wrote nothing. Re-run on the same binary, by hand and through `qa/serve-real-ddlsequence.sh`: the relation is written and the ENGINE reads it. The likely cause of the report is an environment artefact - the STICKY BIT on `/tmp/fbhandson` (`chmod 1777`) blocks fire-crab's rename-over of an engine-owned scratch file (`ending the transaction: Permission denied`) and produces a pile of DIFFs indistinguishable from a silent-write defect; `chmod 0777` makes them vanish on the same binary. The gate written for the phantom found a real defect instead (the generated-name counters), which is now fixed.
- **LOW** - `ALTER TABLE ... DROP <column>` leaves ORPHAN CHECK constraints pointing at the dropped column (the engine drops the dependents); and the quoted form of that DROP now SUCCEEDS where the engine raises, so a refusal became a divergent metadata write. `DROP TABLE <view>` succeeds where the engine refuses. System metadata columns describe as UNICODE_FSS where the engine says UTF8. `qa/serve-real-gbakverbose.sh` is non-deterministic: about one run in three the ENGINE's own verbose stream tears a line (`gbak:g privile table ...`), and the gate truncates its diff to 400 characters so the cause is invisible in the log.
- **LOW (refusals, quoted names)** - a quoted spelling of an UNQUOTED alias (`UPDATE TQ t SET "T"."a" = 5`) refuses where the engine accepts (the SELECT path handles it); a column name containing a doubled quote refuses in a JOIN's select list only; a quoted all-caps-keyword column refuses in a PSQL body's nested UPDATE/DELETE at CREATE time (the MERGE half is fixed); an engine-created procedure whose body assigns to a quoted keyword-named column refuses at EXECUTE.
Part 2 (relations, aliases, DDL storage, internal re-renders) closed the wrong writes the reviews found: `resolve_relation` is exact (`"Tq"` is -204), a FROM alias is a name (`FROM TQ "t"` binds `t`), every internal re-render goes through `render_canon_ref` (UPDATE OR INSERT, INSERT ... SELECT, MERGE, view DML, PSQL bodies, the optimizer probes), DDL stores canonical names (`CREATE TABLE "tq"` beside TQ, `CREATE VIEW vemp (eid, ename)` stores EID/ENAME, `CREATE INDEX ix ON t (dept)` folds again), the ods writers compare exactly (fc's gbak RESTORE keeps `"Order"` and TQ beside `"tq"`), the BLR executor and TrigCtx resolve fields exactly (an engine-created trigger naming `NEW."a"`, a procedure `RETURNS ("a" INTEGER, A INTEGER)`), and a grouped join key's describe name is split only on a side key ("x.y" is announced whole). Still open after Part 2:

- **LOW (refusals, pre-existing)** - `UPDATE ... SET <col> = DEFAULT` refuses (no DEFAULT arm in plan_update's SET parser; the engine writes the default); a trigger body assigning TEXT to a NEW column (`NEW.LOG = 'bi:' || NEW.A`) refuses at CREATE TRIGGER, so an engine-created trigger with such a body makes every INSERT/UPDATE on its table refuse; a quoted alias in UPDATE/DELETE (`UPDATE TQ "t" SET "t"."a" = ...`); a quoted alias inside a VIEW's own FROM.
- **LOW (wrong answer, pre-existing, not identifier-related)** - a select list whose duplicate names make ORDER BY ambiguous (`SELECT ID, ID FROM TQ ORDER BY ID`, `"a" AS "A", A ... ORDER BY A`) answers rows where the engine raises 42702; `LIST()` blob ids display as 0:40000001 where the engine shows 0:1.
- **LOW (error vector)** - no -206 Column unknown vector anywhere (generic 42000); a DML target that is no relation (`UPDATE "Tq" ...`) answers the generic 42000 where the engine spells -204 "Tq" (a SELECT's FROM spells it right).
- **LOW (boundary)** - the dsql lexer now reads a delimited identifier exactly, but a quoted name spelled like an all-caps keyword (`"SELECT"`) inside a compiled body is read as the keyword; a constraint name with a blank (`CONSTRAINT "c x"`) refuses; `"x.y"` qualified in a JOIN select list (`k."x.y"`) refuses (a quoted part holding a dot has no joined spelling).
- **LOW (refusal, NAMED CAUSE)** - a quoted column whose canonical spelling IS an all-caps keyword (`"ORDER"`, `"WHERE"`, `"SET"`, `"GROUP"`, `"AND"`, `"VALUES"`, `"MATCHING"`, `"VALUE"`, `"FROM"`) refuses at `CREATE PROCEDURE` / `CREATE TRIGGER` when the BODY names it in a nested `UPDATE` / `DELETE` / `INSERT`, though every direct (non-PSQL) statement over the same column now answers: `crates/dsql/src/lib.rs:813` `Tok::Ident(String)` carries no QUOTED flag, so `is_keyword` (:2733) reads the delimited `"ORDER"` the lexer produced (:934) as the ORDER keyword and the body does not compile. Closing it means threading the flag through every `Tok::Ident` match in the dsql parser (~50 sites) - its own change, not this one's. The MERGE half of the same family IS closed: `plan_merge` masks quoted names before its keyword searches now, so `SET t."ORDER" = u."ORDER"` and `INSERT (ID, "VALUES")` work.
- **LOW (silent rename on RESTORE, pre-existing, out of this chunk's object kinds)** - fc's gbak RESTORE renames a quoted lower-case DOMAIN and SEQUENCE: `"d1"` becomes `D1`, `"s1"` becomes `S1`, and `RDB$RELATION_FIELDS.RDB$FIELD_SOURCE` follows, so the restored database is not the backed-up one (relations, columns and index names DO survive now). `crates/ods/src/ddl.rs` `create_domain` ~1653 and `create_sequence` ~7980 still `to_ascii_uppercase()` the name they are handed. Identical on the pre-change binary; domains and generators are out of this chunk by spec, but a RESTORE that renames belongs on this list.
- **LOW (refusal, error text only)** - an ALIASED `UPDATE`/`DELETE` that qualifies a column with the TARGET RELATION NAME (`DELETE FROM TQ t WHERE TQ."a" = 1`, `UPDATE "Order" o SET "Order"."value" = 'q'`, `RETURNING TQ.ID`, `RETURNING TQ.*`, `PUBLIC.TQ."a"`) now REFUSES generically - an alias replaces the relation name, and fc has no -206 vector to spell the engine's `Column unknown "TQ"."a"`. It used to strip the qualifier and WRITE.
- **LOW (over-refusal)** - a QUOTED DML target beside its folded twin, aliased, with the twin named unaliased inside a subquery: `DELETE FROM "tq" q WHERE EXISTS (SELECT 1 FROM TQ WHERE TQ.ID = 99)` refuses where the engine answers 0 rows. `strip_dml_alias` searches for the target name in the UPPERCASED, literal-masked shadow of the statement, where `"tq"` is masked out and the twin `TQ` is not, so the subquery's own qualifier looks like the outer target's. Pre-existing (it refuses on the Part-2 binary too); a refusal, never a wrong write.
- **LOW (refusal replacing a corrupt write, NEW)** - `CREATE VIEW <schema>.<name> AS ...` now refuses (`plan_create_view`'s `canon_ident` sees no single identifier in `public.vpub`) where the engine creates the view. HEAD accepted the statement and wrote a relation literally named `PUBLIC.VPUB` that no SQL could name - so this is a refusal replacing a corrupt write, but the engine's answer is still not reproduced.
- **LOW (refusals, pre-existing, not identifier-related)** - `ALTER TABLE t ALTER <col> TYPE ...` followed by `ADD CONSTRAINT ... UNIQUE (<col>)` refuses when the altered column is the table's LAST one (altering a middle column succeeds; reproduces with all-unquoted names); fc's gbak restore drops a named PRIMARY KEY constraint's NAME (`PK1` becomes `INTEG_2`; the engine keeps `PK1`); `RETURNING OLD."a" AS <alias>` and `UPDATE OR INSERT ... RETURNING OLD./NEW.` refuse (an alias on an OLD./NEW. item refuses even unquoted); PSQL `UPDATE ... RETURNING <col> INTO :var` refuses with an entirely unquoted body; a quoted CTE name still folds (`WITH "c" AS (...) SELECT ... FROM "c"` is -204 Table unknown "c" - `lookup_view` folds CTE names); `EXECUTE BLOCK RETURNS ("a" INTEGER)` refuses.

- **HIGH (data corruption on BACKUP, pre-existing, NOT identifier-related)** - fc's gbak backup of a table after `ALTER TABLE ... ALTER <col> POSITION` crosses column VALUES: `crates/burp/src/lib.rs` zips the position-sorted column names (relation_columns, sorted by RDB$FIELD_POSITION) with the field-id-ordered descriptors by index, so the engine restoring fc's fbk reads Z=100, W='10', z='w1' for a row written as z=10, Z=100, W='w1'. RDB$FIELD_ID is permuted too. A table without ALTER POSITION round-trips; a table with a DROPPED column refuses the whole backup (fail-closed). Reproduced on the pre-change binary. Own chunk: pair names and descriptors by RDB$FIELD_ID, never by index.
- **LOW (plan)** - an index on a quoted column is not chosen for a single quoted predicate (natural scan; the two-predicate path finds it); rows right.
- **LOW (refusals)** - `NEXT VALUE FOR "seq"` / `GEN_ID("seq", n)` with a quoted lower-case generator (generators, procedures, functions, packages, exceptions, domains, collations, charsets, roles keep folding - out of this chunk); a quoted alias in UPDATE/DELETE; CTE names/columns quoted; NATURAL JOIN / USING with quoted names; `"a "` trailing-blank names; non-ASCII quoted names in a WHERE or under -ch NONE; `"x.y"` in a JOIN select list; EXECUTE BLOCK bodies with quoted names; `SELECT "" FROM T` lacks the engine's -104 text; HAVING `?` vs COUNT described Nullable.

## Found while converting a joined derived table (2026-09-02) - still open

THE LAW THIS CHUNK CLOSED: a derived table, a view, a CTE and a LATERAL
side each have their OWN columns, and an OUTPUT POSITION IS NEVER A BASE
FIELD ID. `FlatSrc::out_map` (server.rs:35218 `build_flatten`) carries
the mapping for the VALUES, `ProbeKey::out_pos` for the HASH keys, and
`JoinSide::base_fids` (`side_base_fids`, read by `mark_not_null_join`)
for the DESCRIBE's NOT NULL - where the mapping is unknown the side
announces nothing, which is the safe direction and what the engine does
for a derived column it cannot trace to a fixed one. A LAYER OVER A
LAYER COMPOSES rather than gives up: a derived table over a derived
table plans as a `Plan::Derived` whose columns number themselves by the
inner side's OUTPUT positions - a third order - and `side_base_fids`
resolves the inner side's mapping and reads it at that position, so a
plain read of a NOT NULL base column two layers down keeps its flag.

AND A NAME IS NOT A RELATION. `RDB$RELATIONS` is keyed by (schema,
name), so `PUBLIC.T` a TABLE and `S2.T` a VIEW can both exist; the
"is this side a view?" guard that turns an un-re-plannable joined view
into a refusal must ask about THE RELATION THE NAME RESOLVES TO.
`view_of` now stops at the FIRST row carrying the name - the same row
`fire_crab_ods::resolve_relation` and `relation_schema` pick, over the
same walk order (`decides_relation` states the rule and is unit-tested)
- where it used to walk past a non-view row of that name and keep
looking, which made it "is ANY relation of this name a view" and refused
a join against the plain table, losing the write of an
`UPDATE ... WHERE ID IN (SELECT ... JOIN PUBLIC.T ...)`.

**THE PERFORMANCE TRADE, MEASURED AND CLOSED.** Refusing the flatten -
which one expression column must do, since the map has to be total - had
also dropped the ON's equi-keys, so the step fell past the O(N+M) hash
all the way to a per-driver-row scan of the whole side. Hashing needs
NOTHING from the base: the rows it groups are the side's own. The two
decisions are now separate (`JoinAccess`, server.rs:35309), and a
materialised side is hashed by its own output column. 5000x5000
`SELECT COUNT(*) FROM BIG b JOIN (...) d ON d.ID = b.ID`, release
binaries, TCP on both sides, three runs each, with the process's own
attach cost (0.367 s, measured by `SELECT 1 FROM RDB$DATABASE` on the
same server) subtracted to leave the join work:

| derived side | before | after | engine |
|---|---|---|---|
| `(SELECT ID, K, S FROM BIG)` identity - still flattened, index-probed | 0.066 s | 0.067 s | 0.085 s total |
| `(SELECT K AS KK, ID FROM BIG)` renamed - still flattened, mapped | 0.066 s | 0.065 s | " |
| plain table inner (control) | 0.066 s | 0.065 s | " |
| `(SELECT ID, K, 7 AS L FROM BIG)` expression - NOT flattened | **3.182 s** | **0.007 s** | " |

The unflattenable side is now the FASTEST of the four (one hash build
beats 5000 index probes), the trace says `[srv] join hash: side=D` where
it said `join natural`, and no flattened shape moved. There is no
remaining perf trade in the join itself.

**THE ~15 ms PER-ATTACH DELTA, SETTLED: IT IS CODE PLACEMENT, NOT WORK.**
Two reviewers measured this binary ~15 ms slower per ATTACH than HEAD and
than the pre-fix-round tree, with no SQL issued at all. Reproduced
(node-firebird attach+detach only, 25 interleaved rounds against three
servers on an empty database each: 315.9 / 301.3 / 302.9 ms) and then
attributed:

- `perf record` on the server during attaches: **99% of an attach's CPU
  is SRP-6a modular exponentiation** - `fire_crab_auth::crypto::BigUint`
  `rem` 44%, `sub` 20%, and glibc `malloc`/`free` 32% underneath them.
  `fire_crab_ods::catalog::list_relations` is 0.03%. Nothing this chunk
  touched runs at attach.
- `crates/auth` is byte-identical in all three trees, and `BigUint::rem`
  and `::sub` disassemble instruction-for-instruction identically in all
  three binaries - only their ADDRESSES differ (rem at 0x4a2110 in HEAD,
  0x4a2c0c pre-fix, 0x4a2edc here).
- `perf stat` over the same 21 attaches: **instructions 119.915e9 here vs
  120.105e9 for HEAD** (this binary retires FEWER) and **branch-misses
  123.09M vs 123.87M** (fewer again), against **cycles 21.49e9 vs
  20.66e9** (+4%). Same work, same predictions, more cycles: a
  front-end/alignment effect on one hot loop.
- Decisive: rebuilding BOTH trees with `-Cllvm-args=-align-all-functions=6`
  (every function on a 64-byte boundary) collapses the gap to nothing -
  HEAD 314.6 / 315.1 / 315.0 ms against this tree's 314.9 / 314.9 /
  315.2 ms over three interleaved rounds, where the same two trees
  unaligned measure 304.8 and 315.7. Forcing alignment makes HEAD SLOWER,
  which is the honest reading: HEAD's placement of that loop is lucky,
  this one's is not, and neither is a property of the source.

So there is no regression to fix in this chunk. The real finding the
profile exposes is recorded below: an attach costs ~300 ms of server CPU,
essentially all of it in a hand-rolled bignum.

Everything below reproduces BYTE-IDENTICALLY on the pre-change binary
(HEAD 99190b1 and the in-flight tree alike) unless marked NEW; none is a
wrong answer this chunk introduced.

- **HIGH (attach cost, pre-existing, identical on HEAD)** - an ATTACH costs ~300 ms of SERVER CPU with no SQL issued, and 99% of it is SRP-6a `modpow` in `crates/auth/src/crypto.rs`: `BigUint::rem` (crypto.rs:295) is BINARY LONG DIVISION, one shift-compare-subtract per BIT, and `modpow` (crypto.rs:312) calls it after every squaring and every multiply - about 3000 `rem`s of a 4096-bit value per handshake, each `sub` allocating a fresh `Vec<u32>` (glibc `malloc`/`free` are 32% of the profile on their own). The engine's own attach on the same host is far cheaper. This is what makes a 4% code-placement wobble worth 15 ms; fixing it is a Montgomery/Barrett reduction and an in-place `sub`, in its own chunk with its own gate, and it must not be done casually - it is the authentication path.
- **MEDIUM (refusal replacing a silent wrong answer, NEW behaviour, pre-existing cause)** - a joined VIEW whose stored body cannot be RE-PLANNED now REFUSES instead of answering ZERO ROWS. `plan_view` (server.rs:37379) re-plans a view from its SOURCE, so a `SELECT *` body re-expands to the base's CURRENT columns while the catalog froze the view's own, and the length guard at server.rs:37419 declines. In a lone FROM that already refused; in a JOIN the side builder fell through to `resolve_relation`, and a view IS a relation with an id and NO RECORDS OF ITS OWN, so the side scanned empty storage. Measured on `CREATE VIEW VSTAR AS SELECT * FROM STARB` after `ALTER TABLE STARB ADD C3 INTEGER`: `SELECT t.ID, v.A FROM TQ t JOIN VSTAR v ON v.ID = t.ID` answered 0 rows (engine: 3), `COUNT(*)` answered 0 (engine: 3), and the LEFT form answered `A <null>` three times where the engine answers 11/22/33. The fall-through is closed at server.rs:35860; the underlying REFUSAL - `plan_view` cannot re-plan a `SELECT *` body whose base has changed - is untouched and still diverges from the engine, which answers the view's frozen columns.
- **LOW (refusal, the one-user-schema boundary, pre-existing)** - a relation in a SECOND user schema is unreachable: with `PUBLIC.T` and `S2.T` both present, `SELECT ID, A FROM S2.T` and `... JOIN S2.T y ON ...` answer `42S02 / -204 / Table unknown / "S2"."T"` where the engine reads S2's relation. `relation_schema` (server.rs) resolves a NAME to the FIRST catalog row that carries it and `relation_qualifier_ok` then compares the written qualifier against that one schema, so only the first row of a name is ever reachable. Byte-identical on HEAD and on the pre-fix-round tree; it is the one-user-schema boundary, not this chunk. What this chunk DID fix in the same fixture: a lone `SELECT ID, A FROM T` (and `PUBLIC.T`) over the plain table refused on HEAD and on the pre-fix tree and now answers the engine's rows, because `view_of` no longer walks past the table row to find the S2 view's source.
- **LOW (describe)** - a LITERAL column of a derived side (`(SELECT ID, V, 7 AS L FROM K1) d`, projecting `d.L`) is announced Nullable where the engine announces it fixed. The outer `ProjCol` for `d.L` is a PLAIN COLUMN READ of the side, so `mark_not_null_join` (server.rs:44977) asks `side_base_fids` for its base field and correctly gets `None` - an expression has none. Announcing it would mean carrying the INNER query's own announced nullability per side column, the way `mark_not_null_lateral` (server.rs:44901) does for a lateral. Nullable is the safe direction; it is a describe-only divergence.
- **LOW (refusals, LATERAL)** - only `LEFT JOIN LATERAL (<sub>) x ON TRUE` and the comma form parse (`parse_lateral_from`, server.rs:34893): `ON 1=1` refuses where the engine answers, and `CROSS`/`INNER`/`RIGHT`/`FULL JOIN LATERAL` are unwritten. An aggregate applied DIRECTLY to a lateral join also refuses (recorded under the lateral chunk).
- **LOW (refusals, joined derived/view shapes)** - a derived side whose select list holds a WINDOW FUNCTION (`(SELECT ID, ROW_NUMBER() OVER (ORDER BY ID) AS R FROM J1)`) in a join; `SELECT d.*` (a qualified star over a derived or view alias) in a join; `JOIN ... USING (ID)` with a derived side, INNER and LEFT alike; a UNION of two joined-derived SELECTs; a CTE referenced inside an EXISTS subquery.
- **LOW (refusals, DML over a joined derived source)** - `MERGE INTO ... USING (<derived table containing a JOIN>)`; a CTE inside DML (`INSERT ... WITH ... SELECT`, `DELETE ... WHERE ID IN (WITH ...)`, `MERGE ... USING (WITH ...)`); `UPDATE`/`DELETE` on a VIEW whose WHERE holds a subquery that joins a derived table. Each refuses at prepare and WRITES NOTHING - verified byte-identical target state.
- **LOW (error vector)** - naming a column a derived table or view does not have (in the select list, the ON, the WHERE or an `INSERT ... SELECT`) answers the generic `42000 Dynamic SQL Error` where the engine spells `42S22 / -206 / Column unknown / "D"."NOPE" / At line 1, column N`; a runtime conversion or truncation under `INSERT ... SELECT` raises `42000` at EXECUTE where the engine raises `22018` / `22001` with detail. Both reproduce for a plain non-join statement, so they are the server's error surface, not this chunk's.
- **LOW (cosmetic)** - a failed `UPDATE ... RETURNING` omits the engine's trailing `Records affected: 0` line; the printed BLOB id after an `INSERT ... SELECT` of blobs differs (`93:2` vs `93:1`) with identical contents - blob-id allocation order, in flattened and materialised shapes alike.

## Found while converting correlated subqueries (2026-09-02) - still open

Every item reproduced by a reviewer on the pre-change binary too unless marked NEW; none answers wrongly where it used to answer right.

- **MEDIUM (wrong answer / wrong write, pre-existing)** - an OR whose LEFT branch is INDEXABLE beside an invariant that raises: `WHERE ID > 0 OR 1/0 > 0` on a PK column raises 22012 on the engine (it evaluates the invariant up front when the left branch is an index path) and answers all rows / UPDATEs / DELETEs on fc (a 64000-row `DELETE ... WHERE ID > 0 OR 1/0 > 0` deletes everything). On a table WITHOUT an index the engine evaluates the OR per row left-to-right and fc agrees. The invariant fold added for the correlated chunk covers AND conjuncts and lone invariants, not an OR whose other branch drives an index.
- **MEDIUM (wrong answer, pre-existing)** - a constant-LHS IN-list short-circuits: `WHERE 1 IN (1, 1/0)` answers all rows, the engine raises 22012 (it materialises the list; a column-LHS `ID IN (1, 1/0)` raises on both).
- **MEDIUM (engine-shape, recorded)** - `ALL` over a subquery the engine finds EMPTY through a filter (`A > ALL (SELECT V FROM E WHERE 1 = 0)`) answers 0 rows on the engine and every row on fc (the SQL-standard answer); over an empty TABLE the engine answers every row and fc agrees. The engine's answer depends on how the emptiness arises.
- **MEDIUM (engine-shape, recorded)** - a nested correlated scalar inside EXISTS (`EXISTS (SELECT 1 FROM E WHERE E.TID = T.ID AND E.V = (SELECT MAX(V) FROM E e2 WHERE e2.TID = T.ID))`): the engine's hash semi-join evaluates the nested scalar once and answers 1 row; the same predicate under `OR FALSE` / as a projection column answers 1,2,5 on the engine, which is what fc answers. Plan-dependent on the engine.
- **LOW (count only, NEW)** - a failed `UPDATE/DELETE ... WHERE ID = 1 OR 1/0 > 0` on an indexed column reports 1 (2 for `ID IN (1,2) OR ...`) in isc_info_sql_records where the engine reports 0 (it raises before touching a row on an index path). The data is identical (both undo the statement); the "rows written before the raise" progress counter was measured on a table without an index.
- **LOW (refusals)** - HAVING with a constant conjunct (`HAVING 1 = 1 AND COUNT(*) > 1`), `IS [NOT] TRUE/FALSE/UNKNOWN`, `(1/0 > 0) IS NULL`, a derived table / CTE whose WHERE raises; `CAST(? AS BOOLEAN)` in a WHERE, boolean expressions in a select list / CASE / COALESCE; a `?` inside arithmetic in an invariant (`1/? > 0`) or inside an uncorrelated subquery; `EXISTS (SELECT DISTINCT MAX(V) ...)` (DISTINCT over a lone aggregate does not plan); failed MERGE / INSERT ... SELECT counts; a projection subquery that raises per row delivers row 1 before raising where the engine (ORDER BY) raises first; `CAST(A AS VARCHAR(1))` raises 22018 where the engine says 22001.

## Found while converting DML through a VIEW (2026-09-01/02) - still open

Every item below was REPRODUCED by a reviewer on a plain-table twin (or
on the HEAD binary), so none is a regression of the view chunk; they are
the base planner's own, surfaced because the view rewrite renders
statements the gates had never written.

- **HIGH (silent wrong write, plain table)** - a correlated scalar
  subquery with an ALIASED FROM in a SET value loses its correlation:
  `UPDATE T SET A = (SELECT MAX(x.A) FROM T x WHERE x.ID < T.ID) WHERE
  ID = 3 RETURNING ID, A` writes NULL (engine 3|20). The view form now
  renders the correlation correctly and is REFUSED by the same planner.
  Related: `UPDATE T t SET S = (SELECT NM FROM D WHERE D.ID = t.ID)` -
  `strip_dml_alias` drops `t.` inside the subquery, which then binds to
  D (21000 "multiple rows in singleton select"; with a one-row D it
  would write the wrong value silently). The view target keeps the
  qualifier; a table target still strips it.
- **HIGH (silent wrong answer, SELECT side)** - a correlated scalar
  subquery in the PROJECTION answers ZERO ROWS: `SELECT ID, A, (SELECT A
  FROM D WHERE D.ID = T.ID) FROM T WHERE ID = 2` -> no row (engine
  `2|20|222`); the same over a view. A trigger-view statement carrying
  such a subquery is refused rather than run through it.
- **HIGH (silent wrong write, plain table)** - a quoted lower-case
  column `"a"` on a table that also has `A` is written to A: `UPDATE TQ
  SET "a" = 5 ... RETURNING ID, "a", A` -> fc `1|1|5` (engine `1|5|100`);
  `INSERT INTO TQ (ID, "a") VALUES (3, 3)` lands in A. Same family: a
  quoted lower-case VIEW `"v"` beside `V` folds onto the same memo and
  catalog match. Case folding of quoted identifiers across the catalog.
- **MEDIUM (wrong value, bound params)** - a `?` inside SET arithmetic
  is bound as the client's own value type, not coerced to the DESCRIBED
  type: node-firebird sends 1.25 as a double for `SET A = ? * 2` and fc
  answers 3 where the engine (INPUT described `LONG scale -2`) answers 2;
  `SET N = ? * 2` -> 2.5 vs 2. Identical through a trigger view.
- **MEDIUM (reservation)** - a SELECT over a VIEW under SNAPSHOT TABLE
  STABILITY does not reserve the base table (a concurrent NO WAIT writer
  succeeds; engine raises 40001). A trigger-view statement inherits it.
  INSERT ... SELECT / MERGE through a natural view DO reserve the base
  now (`view_base_rel`).
- **MEDIUM (DDL refusal)** - `CREATE VIEW ... WITH CHECK OPTION` is
  refused (`plan_create_view`, "a later slice"): the CHECK OPTION
  runtime works only over an engine-built catalog (the CHECK_n system
  triggers). Creating them means writing two RDB$TRIGGERS rows with
  BLR the engine would accept.
- **MEDIUM (refusal)** - `MERGE INTO <trigger-backed view>`: merge_exec
  probes the target with a base DELETE plan and a `Plan::ViewTrig`
  fails it. UPDATE OR INSERT through the same view works.
- **LOW (refusals, SELECT planner)** - through a trigger view the
  statement's SET/WHERE become a SELECT, so the SELECT planner's gaps
  apply: `CAST(? AS BOOLEAN)`, `UPPER(?)` / `ABS(?)` over a param,
  `CASE WHEN ? > 0 ...`, `INSERT ... SELECT ?, ? FROM RDB$DATABASE`,
  `WHERE ID IN (SELECT ...)` / `EXISTS (...)` over a VIEW, `EXECUTE
  BLOCK (X INTEGER = ?)`. Each refuses at prepare; the table twins of
  the param shapes refuse too.
- **LOW (refusals, trigger bodies)** - `COALESCE` in a NEW assignment,
  NUMERIC arithmetic in a NEW assignment (`NEW.N = NEW.N + 1`),
  `EXCEPTION E 'msg' || expr`, and self-recursive DML are "not
  inlineable" - a view whose engine-created trigger has one makes every
  statement through it refuse.
- **LOW (error shapes)** - the engine's `-206 Column unknown`, `-804`,
  `22001 string right truncation`, `22018`, `22003` all answer a bare
  Dynamic SQL Error; `UPDATE VJ ... WHERE NOPE = 1` gets the read-only
  view vector where the engine reports -206 first; fbclient's
  `isc_dsql_execute` + `isc_dsql_fetch` over a RETURNING statement gets
  -504 (isql and node use paths that work); a text param's INPUT
  describe under a WIN1252 attachment names the column's charset where
  the engine names the attachment's; the engine reports `select=N` in
  isc_info_sql_records for every DML.
- **LOW (recorded boundaries of the view chunk itself)** - a hidden base
  column or base-qualified reference in a view statement refuses (no
  -206 vector); `RETURNING OLD.<expression column>` refuses (engine
  answers); a view-qualified reference inside a subquery over the base
  refuses (ambiguous); a body fc cannot parse (a CTE, a scalar subquery
  the RETURNING planner cannot evaluate) refuses generically where the
  engine says read-only or answers; a trigger view whose CHECK OPTION
  WHERE names a column outside its column list refuses at prepare; the
  engine's RETURNING through a CHECK OPTION view answers zeros/no row
  (its trigger does the write) and fc answers the real values - a BOUND
  line, not mirrored.

## Found by the THIRD hunt (2026-09-01)

FIXED the same day: `OCTET_LENGTH`/`CHAR_LENGTH` over a blob EXPRESSION
(announced LONG len 4 where the engine says INT64 len 8 - the narrower,
riskier direction), and `MIN`/`MAX` over a blob, which compared blob IDs
and answered EXACTLY THE WRONG ROW (over 'zzz','mmm','aaa' the engine
answers zzz/aaa, fire-crab answered aaa/zzz) - now a clean refusal.

STILL OPEN:

- ~~**HIGH (wrong answer + describe)** — a text BLOB in a non-attachment charset~~ **DONE 2026-09-01**. Original report:
  the attachment's is delivered UNTRANSLATED and announced in its STORAGE
  charset. Over a `BLOB SUB_TYPE TEXT CHARACTER SET WIN1252` holding
  `636166E9`, under `-ch UTF8`: the engine announces `charset: 4
  SYSTEM.UTF8` and ships `caf` + `C3 A9`; fire-crab announces `charset: 53
  SYSTEM.WIN1252` and ships the raw `E9`, which is not valid UTF-8 for the
  client that asked for UTF8. A VARCHAR WIN1252 column in the SAME ROW is
  transliterated correctly by both, so this is blob-specific rather than a
  general charset gap. Under `-ch WIN1252` the two agree, so a
  single-attachment test sees nothing. The describe direction is the
  dangerous one: it names a charset whose bytes are not what gets written.

- **MEDIUM (refusal)** — `CREATE VIEW` selecting a BLOB column is refused;
  a view over VARCHAR columns in the same script succeeds.

- **REPORTED BUT DID NOT REPRODUCE** — "a blob grown by two `UPDATE ... ||`
  appends cannot be read at all". Measured on a clean fixture built exactly
  as described (empty blob, two 4000-char appends, both twins built through
  the engine): BOTH servers answer `OCTET_LENGTH` 8000, and a single-write
  control agrees too. No independent refutation ran on this one, and my own
  check does not reproduce it, so it is NOT being fixed. The mechanism the
  reporter located is worth keeping in case a fixture that actually creates
  a pointer-page HOLE reproduces it: `relation_data_pages()`
  (crates/ods/src/pointer.rs) flattens `PointerPage::data_pages()`, which
  SKIPS zero (unallocated) slots - its own unit test asserts
  `[200,0,201] -> [200,201]` - while `blob_slot()` (crates/blb/src/lib.rs)
  indexes that compacted vector with `recno / max_recs_per_dp`, and
  Firebird numbers records by the pointer-page slot index INCLUDING holes.
  One hole would shift every blob after it. Reproducing that needs an
  allocation history with a freed page, which a fresh two-append fixture
  does not have.

- **REPORTED BUT DID NOT REPRODUCE** - "the `op_execute2` procedure emit
  passes no OutFmt, so an EXECUTE PROCEDURE output parameter whose charset
  differs from the attachment's is written at its STORED width while the
  describe announces the attachment's, and the connection desynchronises
  (08006)". This is the exact law that WAS true one line below, for the
  INSERT ... RETURNING singleton (`serve-real-returningexpr`), which is why
  it read as obvious. Measured on the pre-change binary: `CHAR(3)` UTF8 and
  `CHAR(5)` WIN1252 output parameters under `-ch UTF8`, `-ch WIN1252` and
  `-ch NONE` - all six answer IDENTICALLY to the engine, with the format
  and without it. The change was written from the code reading BEFORE the
  measurement and has been REVERTED, with the measurement recorded at the
  call site so the next reader does not re-derive it. A sibling site
  sharing a shape is a place to LOOK, not a defect.

- **RESOLVED, and it was not what the bullet said.** The measured symptom
  (`INSERT INTO LG VALUES (1,1)` in an engine-created trigger body making
  the triggering UPDATE answer 42000) is real and its cause is confirmed:
  the body parser at server.rs:19264 requires the COLUMN LIST, takes
  `text.find('(')` - VALUES' own paren - and reads the table name as `LG
  VALUES`. Still open as a PARSE-SURFACE gap; the engine accepts the
  positional form.
  But hunting it found something far worse in the same machinery, now
  fixed: see `serve-real-psqlrowref` in Done. Nested DML in a body was
  never missing - it was WRONG, and the ordinary audit-trigger text
  `DELETE FROM LG WHERE ID = OLD.ID` emptied the log table.

- **OPEN (gap, same gate)** - `UPDATE OR INSERT ... RETURNING OLD.<col>`
  and `RETURNING NEW.<col>` refuse with 42000 where the engine answers;
  the BARE `RETURNING <col>` form is correct. The OLD./NEW. contexts landed
  for UPDATE and MERGE (`serve-real-returnold`) and were never wired to
  UPDATE OR INSERT's update half.

## Found by the SECOND hunt (2026-08-31) - still open

- ~~**HIGH (wrong answer)** — `MERGE ... DELETE ... RETURNING NEW.<col>`~~ **DONE 2026-09-01**, with the describe half. Original report:

  ```
  MERGE INTO T USING (SELECT 2 AS K FROM RDB$DATABASE) S ON T.ID=S.K
    WHEN MATCHED THEN DELETE RETURNING T.ID, OLD.V, NEW.V;
      engine    2 | 20 | <null>          fire-crab   2 | 20 | 20
  MERGE ... DELETE RETURNING NEW.ID, NEW.D;
      engine    <null> | <null>          fire-crab   2 | 42
  ```

  The whole NEW record is wrong, not one column. `OLD.*` is correct
  everywhere, and a plain `DELETE ... RETURNING <col>` is correct on both
  (the engine DOES answer the deleted values there) - so the rule is
  specifically that `NEW.` has nothing to read on a delete branch.

  WHY IT IS NOT A ONE-LINE FIX: the delete path pushes the deleted row as
  the AFTER image ON PURPOSE - "a DELETE's `images` ARE the old rows; the
  parallel slot keeps every consumer's indexing uniform"
  (server.rs, the delete arm of execute_dml_collecting) - and
  `wrap_returning` resolves `NEW.<col>` to that same after-image. In a
  MIXED merge (some rows updated, some deleted) the distinction is
  PER ROW: measured, the update-branch row agrees and only the
  delete-branch row diverges. So it needs per-row branch provenance in
  `Affected`, not a plan-time decision.

- **MEDIUM (describe)** — the same shape's describe: `NEW.<col>` over a
  MERGE DELETE branch is announced as the base column (`496 LONG len 4`,
  table T) where the engine folds it to a constant (`452 TEXT len 1
  charset NONE`, no table). fire-crab announces the WIDER field, so a
  client laying out its buffer from the describe mis-parses.

- **MEDIUM (refusal)** — `ROWS` and `ORDER BY` on searched `UPDATE` /
  `DELETE` are not supported at all, with or without RETURNING. A widely
  used Firebird extension; the largest single gap that hunt found.

## Found by the FIRST hunt (2026-08-31) - still open

A six-surface differential hunt, run because the recorded backlog held no
wrong answers left, found these. Two were fixed the same day (the
correlated-subquery fold and the parenthesised-NULL inversion); what
follows survived refutation and is NOT yet implemented.

- ~~**HIGH (describe)** — an untyped NULL branch poisons the unified type of~~ **DONE 2026-08-31.** Original report:
  CASE / COALESCE / IIF / NULLIF. fire-crab types a bare NULL as INT64 and
  lets it win: `CASE WHEN 1=0 THEN NULL ELSE <VARCHAR(10) UTF8> END` is
  announced `448 VARYING len 32765 charset 0 NONE` where the engine says
  `len 40 charset 4 UTF8` - an 819x width inflation on a per-row wire
  buffer AND a lost character set. `COALESCE(NULL, <INTEGER>)` is
  announced INT64 len 8 where the engine says LONG len 4. The VALUES
  agree (checked as bytes), so this is describe-only - but a client sizes
  its buffer from the describe. The engine's rule: the other branch's
  type wins, and with nothing to unify against a bare NULL is CHAR(1)
  NONE (`SELECT NULL FROM RDB$DATABASE` already agrees on both).

  THE ENGINE'S RULE, from primary source - `DataTypeUtilBase::makeFromList`
  (jrd/DataTypeUtil.cpp:99), which COALESCE (ExprNodes.cpp:3927), CASE
  (:5062) and LIST (:611) all call:

  ```cpp
  allNulls &= arg->isNull();
  // Ignore NULL and parameter value from walking.
  if (arg->isNull() || arg->isUnknown())
  {
      nullable = true;
      continue;
  }
  ...
  if (allNulls)
      result->makeNullString();
  ```

  So a NULL argument is IGNORED for unification and only forces nullable;
  when EVERY argument is NULL the result is `makeNullString()` - CHAR(1)
  NONE, which is what fire-crab already answers for a standalone
  `SELECT NULL`.

  WHERE FIRE-CRAB DIVERGES, all three in server.rs: `result_width_bytes`
  takes a plain `max` over branches for `Expr::Coalesce` (:15209) and
  `Expr::Case` (:15212), so a NULL branch contributes the 8-byte default
  and WINS against a LONG's 4; and `type_of` has `Expr::Null =>
  Some(ExprType::Int)` (:58019). The TEXT width path ALREADY implements
  the law for Coalesce (:15670, filtering `Expr::Null` with the
  makeFromList citation in its comment) - it was simply never applied to
  CASE or to the numeric width. `rank_of` also already does it
  (`Expr::Null => None, // takes the sibling's rank`, :58562). So this is
  one law applied consistently, not a new mechanism.
- **MEDIUM (describe)** — COUNT(*) inside a CORRELATED scalar subquery is
  announced `496 LONG len 4` where the engine says `580 INT64 len 8`.
  This is the NARROWER, riskier direction. The non-correlated form agrees
  on both, so it is specific to the correlated rewrite.
- **REFUSAL** — a quantified predicate (ALL / ANY / SOME) is usable only
  as a bare top-level WHERE conjunct; as a select-list value, under NOT,
  under IS NOT TRUE or under OR it refuses. The engine answers all of
  them. (Compare the window chunk: the same "a predicate is a value"
  shape, one layer over.)

## THE RECORDED BACKLOG IS STALE - RE-MEASURE BEFORE PLANNING (2026-08-31)

Re-measuring 15 recorded findings against the current binary found EIGHT
already fixed by later chunks, including both TIMESTAMP WITH TIME ZONE
HIGH items (DATEADD returning a zeroed buffer, DATEDIFF always 0) and the
narrowing-CAST HIGH (now raises 22003 exactly where the engine does).
Planning a chunk from the list below without re-measuring would have
spent it on defects that no longer exist.

What was still live, all of it REFUSALS rather than wrong answers:
PERCENT_RANK, CUME_DIST and windows nested in expressions (all three
fixed 2026-08-31); and BIT_LENGTH, ASCII_CHAR, OVERLAY and CAST AS
BOOLEAN, which remain - four unimplemented scalar functions, the
next coherent slice.

## What the hunt found (2026-08-29)

A 12-agent differential hunt probed six SQL surfaces against the live
engine with twin databases, each finding then re-run from scratch by an
independent verifier told to REFUTE it. It confirmed 37 wrong answers
and 26 refusal boundaries. The branch-reconciliation cluster (8 of them)
is fixed above; what follows is the rest, ranked, as the standing
backlog. A `wrong answer` means BOTH servers answer and differ - the
prize. A `refusal` means fire-crab errors where the engine answers: a
recorded boundary under this project's law, not a defect, and ranked
below every wrong answer.

### Confirmed WRONG ANSWERS still open

- **HIGH** (scalar subqueries) — Scalar subquery over a CHAR/VARCHAR column drops the column's CHARACTER SET: a WIN1252 value comes back double-encoded (Ã©Ã  instead of éà) and CHAR pads to the wrong width
- **HIGH** (window functions) — RANGE BETWEEN UNBOUNDED PRECEDING AND <offset> FOLLOWING excludes the NULL ordering-key peer group from every later row's frame
- **HIGH** (date/time arithmetic) — DATEADD on any TIMESTAMP WITH TIME ZONE returns a fixed zeroed buffer (1858-11-16 00:01:00.0000 -23:59) for every part
- **HIGH** (date/time arithmetic) — DATEDIFF between two TIMESTAMP WITH TIME ZONE values always returns 0
- **HIGH** (the CAST matrix and string functions a) — CAST to a narrower NUMERIC silently wraps modulo 2^32 / 2^16 instead of raising 22003 "numeric value is out of range"
- **HIGH** (the CAST matrix and string functions a) — Implicit CHARACTER SET NONE widening decodes NONE bytes as Latin-1 instead of treating them transparently, corrupting concatenation, REPLACE, POSITION and equality
- **HIGH** (the CAST matrix and string functions a) — UTF8 -> OCTETS implicit conversion transliterates to Latin-1 instead of taking raw storage bytes, and announces len 64 where the engine announces 160
- **HIGH** (the CAST matrix and string functions a) — NONE || WIN1252 resolves the NONE bytes through Latin-1 instead of WIN1252 (0x9F becomes U+009F, not U+0178)
- **MEDIUM** (scalar subqueries) — Scalar subquery describes from the executed VALUE, not the inner column: SMALLINT and small BIGINT both come back LONG, a large BIGINT comes back INT64 — the same statement describes differently depending on the data
- **MEDIUM** (scalar subqueries) — Scalar subquery over NUMERIC/DECIMAL announces sub_type 0, erasing the NUMERIC(1) vs DECIMAL(2) discriminator, and widens the storage type
- **MEDIUM** (scalar subqueries) — Scalar subquery that matches no rows describes as TEXT(1) CHARACTER SET NONE instead of the inner column's SMALLINT
- **MEDIUM** (scalar subqueries) — Subquery-bearing select-list expressions lose the Nullable flag and propagate the non-nullable claim through arithmetic, CHAR_LENGTH and CASE
- **MEDIUM** (window functions) — RANGE BETWEEN <offset> PRECEDING AND UNBOUNDED FOLLOWING gives a NULL ordering-key row only its own peer group instead of the tail of the partition
- **MEDIUM** (common table expressions) — A CTE whose name shadows a real table and self-references is answered with PostgreSQL-style scoping; the engine refuses it as cyclic
- **MEDIUM** (common table expressions) — String expression over a CTE/derived literal column is described with charset 255 CS_dynamic where the engine says charset 0 SYSTEM.NONE
- **MEDIUM** (date/time arithmetic) — DATE - DATE describes as INT64 len 8 where the engine says LONG len 4, and the wrong width cascades to INT128 in further arithmetic
- **MEDIUM** (date/time arithmetic) — TIME - TIME describes as INT64 subtype 0 len 8 where the engine says LONG subtype 1 (NUMERIC) len 4
- **MEDIUM** (date/time arithmetic) — TIMESTAMP - TIMESTAMP describes sub_type 0 where the engine says 1 (NUMERIC), and marks the all-literal form Nullable where the engine does not
- **MEDIUM** (date/time arithmetic) — Implicit temporal-to-string conversion in concatenation describes VARCHAR(32765) instead of the natural width (DATE 10, TIME 13, TIMESTAMP 25)
- **MEDIUM** (the CAST matrix and string functions a) — ASCII_VAL over a non-ASCII character returns the code point where the engine raises 22018 "Cannot transliterate character between character sets"
- **MEDIUM** (the CAST matrix and string functions a) — LPAD/RPAD with a non-literal length argument announces double the engine's maximum length (65532), above the 32765-byte VARCHAR limit
- **LOW** (CASE / COALESCE / NULLIF / IIF / DECOD) — CAST of a literal to CHARACTER SET WIN1252 transliterates where the engine byte-copies, so a CASE branch carrying it ships 1 byte instead of 2
- **LOW** (scalar subqueries) — EXISTS in the select list describes non-nullable and names the column CONSTANT instead of BOOL
- **LOW** (scalar subqueries) — Derived table + GROUP BY: fire-crab marks the grouping column Nullable where the engine keeps the base primary key's NOT NULL
- **LOW** (scalar subqueries) — Scalar aggregate subquery inside a derived table reports RDB$FIELD_NAME 'MAX' where the engine leaves it blank
- **LOW** (common table expressions) — Any expression over a CTE (or derived-table) column is announced Nullable; the engine announces it NOT NULL
- **LOW** (common table expressions) — Recursive CTE tree walk is emitted breadth-first; Firebird emits it depth-first
- **LOW** (common table expressions) — Recursive-CTE columns leak the anchor expression's node kind into the describe `name:` field (CONSTANT); the engine leaves it empty
- **LOW** (date/time arithmetic) — UNION DISTINCT with a CAST branch blanks the field name and table origin in the describe
- **LOW** (LATERAL) — an OUTER column that is NOT NULL, used inside the lateral subquery's own expression (`FROM NN a, LATERAL (SELECT a.W * 2 AS Z FROM RDB$DATABASE) x`), is announced Nullable; the engine announces it fixed. Mechanism: the describe stand-in renders every outer reference as `CAST(NULL AS <type>)`, which is nullable by construction, so `inner_cols` cannot see that the outer column was fixed. Fixing it needs a NOT NULL stand-in of the same type and WIDTH per type (a bare literal would move the described width of text expressions), not a one-line change. The divergence is in the SAFE direction - a bit announced set that is never used - unlike announcing NOT NULL where a NULL can arrive, which desynchronises the wire

### A REGRESSION THAT CHUNK CAUSED, found and fixed 2026-08-31

Making a literal type in the attachment's charset also retyped the
LITERAL A SCALAR SUBQUERY IS FOLDED INTO. Measured against the binary
from before that chunk (df5520e), on `OCTET_LENGTH((SELECT <col>))`:

| via a scalar subquery | pre-chunk | after the chunk | engine |
|---|---|---|---|
| a WIN1252 column | 27, every attachment | 27 / 27 / 10 | 10 |
| a UTF8 column | **5 - correct** | **4 / 5 / 4** | 5 |

The WIN1252 half was already broken; the UTF8 half WORKED and the chunk
broke it, and the 358-gate sweep stayed green because no gate covered a
subquery used as an OPERAND rather than as a whole select item. Fixed by
splicing a charset-carrying literal; `serve-real-subqdesc` 40 -> 70 now
covers the operand shapes under all three attachments.

### The charset cluster (hunt findings 10, 11, 12, 30) - DONE (2026-08-31)

Implemented as "a literal is bytes in the attachment's charset, and a
byte carrier is never transliterated". The roadmap framed this as a
CONCATENATION problem; re-measuring against the engine showed the concat
symptom is DOWNSTREAM of the literal's charset, and that the same miss
also corrupted data at rest and inverted a truncation check. What the
implementation actually needed, in the order the measurements forced:

- `stmt_text_decode` at the three statement entry points (op_prepare and
  both exec_immediate forms) - `from_utf8_lossy` destroyed a lone `0xE9`
  into U+FFFD BEFORE the tokenizer saw the literal.
- the `TfCs::Att` arm in `expr_value_charset` and in
  `cast_source_charset` - the width machinery already carried the
  attachment sentinel; only the VALUE side was guessing UTF-8. Two paths
  disagreed about one value: `OCTET_LENGTH(N||'')` answered 7 while the
  CAST of the same expression shipped 9 bytes.
- resolving the sentinel in `recode_concat`, which is what routes a
  carrier operand through `transcode_text` - that function already
  implemented the byte-copy law correctly and was simply never reached.
- the literal's charset on the STORE path (`InsVal::Str`), the same law
  `wire_text_param` already applied to a wire parameter.
- `respond_malformed_statement`, the engine's DSQL `-104` vector, for
  statement bytes that are not a string in a multi-byte attachment.
  fire-crab had been ACCEPTING those and storing U+FFFD.
- the EMIT path and its capacity check, together: the emit's byte-carrier
  branch tested a POSITIVE ttype only, so it never fired for a literal or
  any expression (whose charset travels as a negative sentinel). The
  capacity check's own comment said "the condition is the EMIT's own" -
  changing one without the other raised a 22001 on a value the engine
  returns. Both now read the same resolved `src_id`.
- `recode_conditional`, the byte-copy law for CASE / COALESCE / IIF,
  which the concat recoder cannot cover. Branches wrap individually,
  because WHICH branch runs is a runtime choice.
- the INSERT blob-literal path, whose comment recorded the old assumption
  in as many words ("a carrier stores the client's bytes verbatim - the
  UTF-8 the SQL text arrived as"). A literal into a UTF8 text blob stored
  SEVEN bytes where the engine stores five.
- `answer_prepare`'s NAME items: an identifier travels in the
  attachment's charset like any other text, so a quoted alias came back
  doubled (`ăî` announced as `ÄÃ®`).

Two gates recorded these divergences as `known_diff` - a check that FAILS
when a recorded divergence starts agreeing, so that fixing it trips the
gate instead of passing silently. Both fired and are ordinary assertions
now. That convention is worth keeping: a recorded divergence nobody
re-checks is just a bug with better manners.

The old text is kept below for the record.

### The charset cluster, as originally recorded

All four reproduce, and probing them established ONE law that explains
every case: **NONE and OCTETS are BYTE CARRIERS. A conversion to or from
one is a BYTE COPY - never a transliteration through Latin-1.** The
carrier machinery (`intl::carrier_decode` / `carrier_encode`) already
exists and is correct; it is the concatenation and emit paths that do
not reach for it.

Measured, under a NONE attachment, over a NONE column holding
`73 74 72 61 C3 9F 65`:

- `N || ''` - the engine passes the NONE bytes through unchanged;
  fire-crab decodes them as Latin-1 and re-encodes to UTF-8, shipping
  `73 74 72 61 C3 83 C2 9F 65`. The emit path HAS a byte-carrier branch,
  but it is gated on `c.sub_type` being a positive ttype, and an
  EXPRESSION carries its charset as a negative sentinel - so the branch
  never fires for a concatenation.
- `U || O` (UTF8 with OCTETS) - the engine answers OCTETS len 160
  (32*4 + 32) and takes the UTF8 operand's RAW STORAGE bytes `C3 9F`;
  fire-crab announces len 64 and transliterates to `DF`. Note OCTETS
  DOMINATES here, where NONE yields.
- `N || W` - the engine concatenates the raw NONE bytes and the raw
  WIN1252 bytes; fire-crab returns an essentially EMPTY value, which is
  worse than the reported "wrong bytes" and needs its own diagnosis.
- `CAST('<multi-byte>' AS VARCHAR(4) CHARACTER SET WIN1252)` - under a
  NONE attachment the literal arrives as raw bytes and the engine
  BYTE-COPIES them; fire-crab transliterates.

The reason this is a chunk and not a patch: the result of `N || W` is
the two operands' OWN stored bytes concatenated, so the conversion is
PER OPERAND at concat time, not a single fix-up at emit. That is the
shape the implementation has to take.

### Refusal boundaries recorded (fire-crab refuses, the engine answers)

- medium — REFUSAL: scalar subquery over FLOAT, DOUBLE PRECISION, DATE, TIME, TIMESTAMP or DECFLOAT fails to prepare
- medium — A CTE containing a window function PREPAREs with a byte-identical correct SQLDA, then fails at EXECUTE
- low — Introducer-prefixed literal (_WIN1252 'x') is refused, in a CASE branch and on its own
- low — REFUSAL: a scalar subquery as the LEFT operand of a comparison in WHERE fails to prepare
- low — REFUSAL: a CORRELATED EXISTS / NOT EXISTS used as a select-list value fails to prepare
- low — Multiple-row scalar subquery: fire-crab raises SQLSTATE 21000 at PREPARE, the engine emits the output SQLDA first and raises the identical error at fetch
- ~~low — PERCENT_RANK() and CUME_DIST() are not implemented~~ **DONE 2026-08-31**: both answer, defined over the PEER GROUP (ties share a value) and described as DOUBLE
- low — RANGE frames whose bounds are keyword-only (UNBOUNDED / CURRENT ROW) fail to parse, though the semantically identical default frame works
- low — RANGE offset frames are refused unless the ORDER BY key is a scale-0 integer
- ~~low — A window function nested inside any expression~~ **DONE 2026-08-31**: calls are lifted out and folded as their own columns. Note the two traps: the `OVER` of `COALESCE(SUM(V) OVER (...), 0)` sits at paren DEPTH 1, so a depth-0 search silently declines it; and `split_alias` accepts a bare alias only if the head ends with `)` or PARSES, which a head containing OVER does not - so `... + 1 AS R` worked while `... + 1 R` refused
- low — Window functions cannot be combined with GROUP BY, SELECT DISTINCT, or a frame clause on an ORDER BY-less window
- low — Windowed LIST() and non-constant LAG/LEAD offsets are refused
- low — REFUSAL: window function with OVER (ORDER BY ...) inside a CTE or derived table prepares, then fails at fetch
- low — REFUSAL: a CTE cannot be referenced from a subquery, a union branch of the main query, or a scalar subselect
- low — REFUSAL: forward reference to a CTE declared later in the same WITH list
- low — REFUSAL: CTE over a UNION mixing a UTF8 VARCHAR column with a longer literal fails to prepare, and with no diagnostic detail lines
- low — REFUSAL: a recursive CTE with more than one recursive member
- low — Arithmetic between a TIMESTAMP WITH TIME ZONE and a number is refused at prepare time
- low — CAST from TIME, or from TIMESTAMP WITH TIME ZONE, to DATE/TIMESTAMP is refused with a conversion error (includes CAST(CURRENT_TIMESTAMP AS DATE))
- low — LOCALTIME(n) and LOCALTIMESTAMP(n) with an explicit precision are rejected at prepare
- low — A bare NULL literal as either DATEDIFF operand is rejected, and the FROM/TO form misparses it as a table reference
- low — OVERLAY is not parsed: fire-crab reports "Table unknown" on the FROM keyword inside OVERLAY
- low — BIT_LENGTH is unknown to fire-crab (CHAR_LENGTH and OCTET_LENGTH work)
- low — ASCII_CHAR is unknown to fire-crab
- low — CAST(... AS BOOLEAN) is unsupported
- low — The _CHARSET introducer on a literal (_WIN1252 X'809F', _UTF8 '€') is unsupported
- **LOW, NEW (2026-08-31, measured)** — a CATALOG character column is announced `charset: 3 SYSTEM.UNICODE_FSS` where the engine announces `charset: 4 SYSTEM.UTF8` (`SELECT RDB$CHARACTER_SET_NAME FROM RDB$CHARACTER_SETS`, same len 252, same type). Verified PRE-EXISTING: the binary from before the literal-charset chunk (df5520e) announces it the same way, so it is not a regression from that work. Found while gating the object-id fix; `serve-real-objid` deliberately does NOT compare that describe, and says so, rather than encoding an unrelated bug as its own pass/fail
- ~~**HIGH** — CONNECTION KILL~~ **FIXED 2026-08-31** (`serve-real-objid`): with `SET SQLDA_DISPLAY ON`, a CHARACTER-typed result as the THIRD statement of a connection kills fire-crab's connection - `SQLSTATE 08006`, `-send_packet/send` - and EVERY later statement on it returns 08006. Bisected: position 1 or 2 is fine, three character statements in a row are fine, four integer statements are fine, a character COLUMN triggers it as well as a literal, and with SQLDA_DISPLAY off it never fires. Traced: on the first character-typed result fbclient opens a SECOND transaction and walks `RDB$CHARACTER_SETS` through the LEGACY BLR request API (`op_compile`, then `op_start_and_receive` and 53 `op_receive`) to resolve the charset NAME for the describe. That walk SUCCEEDS, and my first hypothesis - that it left state behind, or that the ChaCha64 cipher was involved - was WRONG on both counts: the failure reproduces identically over a CLEARTEXT connection, and the legacy path's every write goes through the encrypting writer. THE ACTUAL MECHANISM: fire-crab minted BLR request ids from their own counter starting at `BLR_REQ_HANDLE = 5` while statements ran 3, 4, 5, ... A compiled request and a prepared statement are different KINDS of object sharing ONE client-side id space - fbclient keeps a single untagged-union `port_objects` array (remote.h:1356) and the engine allocates every id by scanning that one array (`rem_port::get_id`, remote.h:1600), so the engine can never collide. When the walk's request took id 5 while the third statement held id 5, the compile response overwrote `port_objects[5]`, and the next `op_execute` failed the client's own typed-handle check INSIDE its encoder - `xdr_sql_blr` writes the input-BLR length (protocol.cpp:1910) and only then looks the statement up (:1922), so the CLIENT abandoned a half-written packet. Hence `send_packet/send`: the failing write is the client's, not the server's. The rule was never "position 3" - it is "the first op_compile lands on an id a live statement holds", which is why prepending `SHOW TABLES` (which burns a request id) moved the failure to position 4. FIXED by minting requests from the statement counter, which already stepped over live transaction handles for exactly this reason. NOTE FOR ANY GATE: a charset or describe gate is by nature a stream of character-typed statements, so this can poison a whole run and a diff-counter can read the dead tail as agreement - put describe checks in their own connections, one statement each (`serve-real-litcs` does)
- low — REFUSAL: an aggregate applied DIRECTLY to a lateral join (`SELECT COUNT(*) FROM T a, LATERAL (...) l`) refuses at prepare. `plan_lateral` delegates to the join planner and keeps only a `Plan::Join`; an aggregate makes that a `Plan::JoinGroup`, whose grouping columns index the COMBINED joined record, so the lateral cannot simply be substituted underneath it. The same query written with an explicit derived table IS served, which is what makes this a boundary rather than a hole

## How these slices are gated

A slice that wires an engine mechanism in needs two gates of different
kinds: a **coverage** check that the mechanism was REACHED (the page
exists at the predicted number, the counter is non-zero, the lock was
enqueued) — because "wired in but never used" passes every behaviour
gate — and the existing behaviour gates, unchanged, as the floor. A
gate that cannot fail is not a weaker check; it is a source of false
confidence. And before believing a gate that fails is a regression,
run the OLD binary: a server that improved past a recorded refusal
reads exactly like one that broke.

**THE THIRTEEN GATES NOBODY WAS RUNNING — WIRED IN 2026-08-28.** Their
`$1` is a prepared DATABASE rather than a port, and the runner had
nothing to give them, so in every sweep each printed a usage line and
exited 1: `join`, `outerjoin`, `project`, `insert`, `syscat`,
`joinchain`, `joingroup`, `orderagg`, `groupby`, `having`, `query`,
`where` and `types` — **171 checks over the core query surface** (joins,
grouping, HAVING, projection, the system catalogue, the type matrix)
that nothing was watching. They pass, so nothing had rotted; but a gate
nobody runs is a gate that has stopped telling the truth. The runner
builds the two fixtures once (`qa/mkjoindb.sh`, `qa/mktypesdb.sh`) and
hands each gate its OWN COPY, because they write.

**AND THE SUMMARY WAS BLIND TO THEM.** It counted DIFF and FAIL LINES,
so a gate that dies without printing one was invisible — which is
exactly how thirteen gates could fail in every sweep while the summary
said 0. A non-zero `rc` is now counted and reported beside them.

**RUNNING THEM ALL: `qa/sweep.sh`.** The suite is 340 gates and was
45-60 minutes serially, which is long enough that it stops being run.
A gate is mostly WAITING — on its own `fcwire`, on the engine at 3050,
on fsync — so it is latency-bound before it is CPU-bound, and a few at
once shortens the wall clock well past the core count: **1659s at -j 4,
340 gates, 9321 checks, 0 DIFF**. What makes it safe is that a gate
already takes its port as `$1` and builds its own scratch databases, so
each gets a private one. Three things it must get right, each learned
by getting it wrong: the log keeps the SERIAL `=== gate` / `--- rc=`
format and buffers each gate whole, because every habit built around a
sweep greps for those; gates that MEASURE TIME or contention run alone
afterwards, since a parallel sweep makes a loaded box and such a gate
starts reporting the load instead of the server; and `$1` is a PORT for
327 gates but a DATABASE PATH for 13, which does not error — it fails
eleven checks with an I/O error naming a file called "20676".

Ordering the slow gates first (`qa/sweep-times.txt`, kept in the repo)
measured NO gain here — 1659s either way. At -j 4 this two-core box is
saturated, so the wall clock is total work over parallelism and no
schedule changes total work; the ordering is kept because it costs
nothing and does pay on a wider box or a filtered run. The remaining
lever is the slow gates themselves: `textcolcmp` alone is 291s of the
1659.

Those 13 database-path gates (`join`, `groupby`, `having`, `query`,
`project`, `where`, `insert`, `syscat`, `types`, `outerjoin`,
`joinchain`, `joingroup`, `orderagg`) have never run in ANY sweep,
serial or parallel. Wiring their fixtures in is real uncovered surface.
