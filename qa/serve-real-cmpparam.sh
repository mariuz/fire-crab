#!/bin/bash
# THE COMPARISON-TYPING LAW - a `?` that is an operand of arithmetic
# (+ - * / unary minus) or of `||`, at any depth of bare arithmetic, on
# ONE side of a comparison whose OTHER side carries no `?`, is described
# as the other side's COMPLETE descriptor: dtype, scale, subtype, length,
# charset AND nullability (the engine's MAKE_desc of that side; the
# arithmetic sibling is ignored). `ID * ? = 2` -> LONG NOT NULL from the
# literal; `? + 1 = ID` -> LONG Nullable; `ID * ? = NM` -> LONG scale -2
# subtype 1; `ID * ? = 2.5` -> INT64 scale -1 (a decimal literal); `S ||
# ? = 'abx'` -> TEXT len 3 NONE; `SUM(ID) > ? + 1` -> INT64 Nullable.
# The same law inside a CASE/IIF CONDITION in every clause, and a BARE
# `?` on either side of that condition (`IIF(ID = ?, 1, 0)` -> LONG
# Nullable). Until this chunk the unparenthesised spellings died in the
# tokenizer (texpr_atom_bare had no Tok::Param arm), the parenthesised
# ones in resolve_proj_expr's catch-all, and a condition's `?` in
# resolve_raw_cond, which had no sink.
#
# NULLABILITY (L2) comes from the other side: a literal -> NOT NULL; a
# nullable column -> Nullable; a NOT NULL column -> NOT NULL; COUNT ->
# NOT NULL; SUM/AVG/MIN/MAX -> Nullable EVEN over a NOT NULL column.
#
# VALUES (L6, measured with TEXT binds): under `*` EXACTLY ONE operand is
# ROUNDED TO AN INTEGER (half away from zero) and the other keeps its
# fraction, and WHICH one is THE SIDE RULE the refuter's 96-cell matrix
# measured (12 siblings x {INT64, LONG} slot x {left, right}): the LEFT
# operand when the slot AND the sibling are both SHORT/LONG (scaled or
# not) - `NM = ? * ID` ['7.25'] -> none, `? * ID = CAST(9.0 AS
# NUMERIC(9,1))` ['2.5'] -> 3, while `NM = ID * ?` ['7.25'] -> 1 keeps;
# the RIGHT operand otherwise - an INT64 slot (`ID * ? = 6.0` ['2.5'] ->
# 2) or an INT64 sibling under a SHORT/LONG slot (`BI * ? = CAST(27.0 AS
# NUMERIC(9,1))` ['2.5'] -> 1, `? * BI = CAST(22.5 ..)` -> 1 keeps). A
# direct `?` sibling counts as the slot's width. A `/` divisor is rounded
# for EVERY exact slot, a dividend keeps; + and - keep the scale. (The
# first cut of this chunk rounded only the right operand under an INT64
# slot - a wrong answer in 22 of the 96 cells, and a DELETE that took the
# wrong row.)
#
# A BARE `?` THAT IS A WHOLE SIDE of a condition's comparison (`IIF(ID =
# ?, 1, 0)`, `IIF(? = 2.5, ..)`) or a negated one (`-? = ID`, `ID = -?`)
# is NEVER converted into its slot: the described slot only tells the
# client what to send, and the compare reads the client's value whole -
# `WHERE IIF(ID = ?, 1, 0) = 1` ['2.4'] -> none, `SELECT IIF(? = 2.5, 1,
# 0)` ['2.45'] -> 0;0;0, `-? = ID` ['-2.4'] -> none, `-? < 2` ['-1.5'] ->
# 1;2;3 (a negated text is a DOUBLE), and an unconvertible text or an
# integer against a TEXT slot raises *conversion error from string* on
# both (`IIF(ID = ?, 1, 0) = 1` ['0x2'], `IIF(S = ?, 1, 0) = 1` [2]) -
# exactly what the classic bare `ID = ?` already did. (The first cut cast
# the whole-side value INTO the slot and rounded it: 2 for ['2.4'].)
#
# THE PINS (sections 4b-4d): the `*` side rule is a 72-cell matrix - slot
# {INT64 literal, LONG NUMERIC(9,1), SHORT NUMERIC(4,1)} x sibling {ID,
# BI, 2, 5000000000, CAST(ID AS BIGINT), COUNT(*) in HAVING} x {? left, ?
# right} x {the engine's target, the OTHER reading's target}, every bind a
# fraction ('2.5', or '0.4' where 5000000000 * 2.5 would not fit the
# slot), so a mis-sided rounding is a DIFFERENT row set in every cell -
# the hit cell answers a row, the miss cell none, and swapping the rule
# swaps them. A whole-side `?` and `-?` are pinned in the select list,
# WHERE, ORDER BY, GROUP BY, SUM, HAVING, a derived table and DML, the
# DML through `dml_rb` (one transaction, read back, ROLLED BACK, so a
# binary that takes the wrong row cannot pollute the cells after it), and
# the execute-time conversion errors through `both_err` (both servers
# PREPARE - describe lines on both - and both RAISE at execute).
#
# THE SIBLING WIDTH (4e) is the side rule's second input and a scaled
# DECIMAL LITERAL is NARROW when its unscaled integer fits 32 bits (the
# BLR width, not the INT64 the projection announces), carried through a
# minus, COALESCE and ROUND, lost through IIF/NULLIF/ABS/arithmetic;
# CASE, a scalar subquery of a literal and MIN(1.5) siblings are refused.
# A SCALAR-SUBQUERY SLOT (4f) is sized from its projected column. A
# whole-side TEXT into a DOUBLE slot (4g) takes the compare grammar. A
# LONG-message -2147483648 under \`-?\` (4h) overflows like the engine. A
# -? / arithmetic ? as a simple-CASE WHEN value (4i) and inside a
# subquery body (4j) are refused at prepare, as the engine and the
# previous binary respectively do - never described and then failed.
#
# Typing does NOT pass through a function or COALESCE (the engine refuses
# ABS(ID * ?) = 2 with -804); a `?` on BOTH sides is an order-dependent
# engine rule this server refuses whole (recorded); IS NULL on a
# `?`-arithmetic is an SQL_NULL slot (refused, recorded).
#
# EVERY `both` CELL COMPARES THE VALUE *AND* THE WHOLE DESCRIBE (every
# input and output slot). Binds are chosen so a wrong or swapped slot is
# a DIFFERENT answer; fractions are bound as STRINGS because node-firebird
# sends a JS fraction as a DOUBLE message, which this server does not yet
# take into an exact slot (a pre-existing gap outside this chunk).
#
# Usage: qa/serve-real-cmpparam.sh [port]   (default 4383)
#
# ROUND 4 (2026-09-19): THE MULTIPLY'S SIBLING WIDTH IS A WHITELIST, NOT A
# TABLE ([mul_sibling_width]). Three refuter rounds each found a sibling
# shape whose BLR width an open-ended table got wrong - a scaled literal,
# ABS over a SHORT, a derived / CTE / view column carrying a literal - and
# every one was a WRONG ANSWER (rows mutated by UPDATE / DELETE / INSERT ..
# SELECT). The side rule now sizes only: a base-table column, an integer
# or scaled literal (under minuses), an explicit exact CAST, a direct `?`,
# COUNT / SUM / AVG and MIN / MAX over a base column in HAVING, and
# parentheses around those; EVERYTHING ELSE REFUSES AT PREPARE - the cells
# below labelled 'whitelist boundary' are shapes the previous committed
# binary refused too, recorded as eng_only with the engine's value. Six
# smaller classes landed with it (section 4k): a DATE / TIME whole side
# bound from node's blr_timestamp compares at the message's type, a
# whole-side text inside a subquery body reads by the compare grammar,
# SIGN / MOD evaluate over a DOUBLE, a simple CASE / DECODE THEN or ELSE
# value the DecodeNode cannot type refuses, a DML destination's `-?`
# negates in the message width, a correlated scalar slot carries its
# NUMERIC sub_type. Section 4l then PINS the whole round: every
# whitelisted shape in both operand orders (LONG and SHORT slots, the
# bind '1.4' whose rounding-vs-keeping is a different row set in every
# cell), every refused family as an eng_only 'boundary' cell carrying
# the engine's measured value and width (the fixture gains a view V and
# a table TS with SMALLINT / TIME / TIMESTAMP columns for them), the
# boundary in DML through the new dml_rb_eng_only (the engine's rows
# under rollback, this server's refusal at prepare), and X2-X7 in full.
#
# ROUND 5 (2026-09-19, refuter round 4's findings A-L; section 4m): two
# REGRESSIONS of round 4 are pinned as 'floor:' cells that the previous
# committed binary /tmp/fcwire-prev-c34c1c8 answers exactly like the
# engine - a DML destination's negation chain casts ONCE at the outermost
# minus by PARITY (`SET N = -(-?)` ['-2147483648'] stores the value; round
# 4 cast the inner -? first and overflowed), and a simple-CASE value that
# is a negation / multiply / divide / function OVER A TYPED ADD answers
# (raw_untyped_num: an Add/Sub is untyped only when BOTH operands are).
# With it: the multiply whitelist folds exactly ONE minus over a literal
# and refuses `? * -(-2147483648)` (the engine raises Integer overflow;
# round 4 sized it wide and rewrote every row); a `?` CASE subject with
# two or more WHENs, a TIME whole side inside a subquery body and the
# bare WITH TIME ZONE whole side refuse at prepare (each an eng_only
# 'design boundary' carrying the engine's value); CASE <col> WHEN ? in a
# body, a text past 38 digits and a text longer than a CHARACTER slot
# are spelled and answer; `? + ?` in a simple-CASE / COALESCE value
# refuses like the engine's -802; CAST(<zoned> AS TIMESTAMP / DATE /
# TIME) converts to the session zone; a sibling-typed arithmetic `?`
# takes the conditional's RESULT descriptor as its slot (INT64 beside
# 1.5: the RIGHT operand rounds - both binaries applied the LONG rule); a
# simple-CASE THEN / ELSE bare `?` compares at the MESSAGE's precision;
# the DML destination multiply takes the same side rule at the
# destination's width and SCALE (NUMERIC(18,1) = ? * 2 ['2.5'] stores
# 5.0, not 6); and a text whose digits plus the slot's scale exceed 18
# raises *numeric value is out of range* like the engine (text_col_num's
# Raise class; CAST(text AS exact) past 18 significant digits too). The
# fixture's TS gains C CHAR(4), N18 NUMERIC(18,1), N10 NUMERIC(10,2),
# N41 NUMERIC(4,1), TZ TIMESTAMP WITH TIME ZONE and TMZ TIME WITH TIME
# ZONE for them. Two more rolled-back helpers: dml_rb_both_refuse (both
# refuse at prepare) and dml_rb_eng_raises_fc_refuses (the engine
# prepares and raises at execute, this server refuses at prepare).
# STILL DIVERGENT and NOT pinned (a wrong answer cannot be a green cell):
# the parameter-free `SELECT - -2147483648` answers 2147483648 (engine:
# Integer overflow), SIGN / ABS / MOD over -SM at the SHORT minimum
# answer (engine: Integer overflow), the classic `NM = ?` with a 38-digit
# text answers none (engine: out of range), and `UPDATE T SET NM = ? *
# ABS(ID)` ['2.5'] stores 3 (engine 2.5) - all pre-existing on both
# binaries, recorded in the round-5 report.
#
# ROUND 6 (2026-09-19, STABILISATION; refuter round 5's findings S1-S12;
# section 4n): no new value law - every finding is either the previous
# committed binary's tree RESTORED where it was right, or a REFUSAL at
# prepare where nobody was right. Restored: a `?` dividend over a `?`
# divisor into a SCALE-0 exact destination (both cast into the
# destination; round 5 left the dividend raw and text binds failed at
# execute, `-? / ?` stored -3), an APPROXIMATE dividend over a `?`
# divisor (the divisor is not rounded: `NM = ABS(?) / ?` 3, `D / ?`
# 2.5), the simple-CASE bare `?` cast into the refined slot UNDER
# ARITHMETIC (`CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = 3` ['2.4'] row 2;
# the whole-side binding stays for the direct side and under unary
# minus), the INT64 OUTPUT describe of a conditional with a multiplied /
# divided branch `?` (a multiply / divide casts at the destination's
# width, an add at eight bytes), the LONG slot of a conditional compared
# with NULL, the INT128 cast rung of a simple-CASE `?` against an INT128
# column, the conversion error of CAST(<TIME WITH TIME ZONE> AS
# TIMESTAMP) whose instant crosses midnight (the engine rolls the date;
# which date it starts from is unmeasured), the message-width negation
# chain of a compare side under an operator (`-(-?) + 0 = -2147483648`
# [-2147483648] raises Integer overflow) and the signed int64
# accumulator of the scaled-slot overflow class ('-9223372036854775808'
# raises). Refused at prepare: a simple-CASE bare `?` against a side
# carrying a `?` (the previous binary prepared then failed), TRIM(?) with
# a bare `?` operand into a non-text slot (BOTH binaries PANICKED the
# server thread at execute; the eval now defaults the pad and never
# indexes past its arguments, and `UPDATE T SET S = TRIM(?)` answers),
# a TIME whole side inside ANY subquery body (a Refused inner plan is a
# refusal in corr_register, the one place every body with a `?` is
# planned), and a SCALED exact dividend over a `?` divisor (`NM = NM /
# ?`: the engine 2.42, round 5 2.41, the previous binary 2.9). The store
# overflow of an exact value carries the engine's *numeric value is out
# of range*. Still recorded, not pinned green (pre-existing on both
# binaries): `N = ABS(?) / ?` ['7.5', '2.5'] stores 2 (engine 3); a
# simple-CASE / IIF bare `?` against a DECFLOAT column keeps the LONG
# slot; `CASE ID WHEN 1 THEN ? ELSE 0 END = I1` ['2.44'] answers row 1
# (engine none - the cast rung, as before); `IIF(b.ID = 2, ?, 0) = 2`
# in a body answers none (engine 2); `CASE .. END || '' = '2.4'` answers
# none (engine 2, a VARYING(11) slot); the body twin `IIF(b.ID = 2, ? /
# 2, 0) = 2` [5] refuses (a `?` under an operator in a body is spelled
# back as a bare literal; the previous binary answered the int bind and
# answered NO ROW for the text bind); `CAST(TMZ AS TIMESTAMP)` over the
# named-zone row and `CAST(TIME '20:00:00 -12:00' AS TIMESTAMP)` (the
# engine's roll starts from the SESSION zone's date, measured: 2026-09-20
# 08:00 under UTC at 05:00) raise; `UPDATE T SET NM = ? / ?` ['300000',
# '2.5'] raises out of range at the LONG-width dividend cast where the
# engine stores 100000 (the previous binary stored 120000). The fixture's
# TS gains I1 INT128 and FL FLOAT.
#
# ROUND 7 (2026-09-19, THE SCOPE CUT; sections 4m / 4n RE-DERIVED from a
# three-way run - engine, the cut binary, /tmp/fcwire-prev-c34c1c8 - and
# audited cell by cell against the engine afterwards): FIVE FAMILIES of
# rounds 5-6 went BACK to the previous committed binary's tree, because
# each sat outside this chunk's scope and had produced a regression in
# rounds 5-6 - the DML destination router's `? * k` / `k / ?` side rule
# at the destination's width (R-K), the simple-CASE THEN / ELSE bare `?`
# bound whole (R-J: it is cast into the reconciled sibling slot again),
# the refinement of a conditional's branch from the comparison's other
# side (R-I), the zoned CAST evaluation (R-H: the conversion error is
# back) and the compare-side negation chain under an OPERATOR (R-S7).
# WHAT ANSWERS (sections 1-4l, the chunk's core, unchanged): a `?` under
# arithmetic on one side of a WHERE / HAVING comparison typed from the
# other side's full descriptor, the whitelisted multiply side rule, the
# divide / add / subtract value rungs, a `?` in a CASE / IIF CONDITION in
# every clause with the bare whole side kept whole (and the BARE negation
# chain still negating at the message width - `SET N = -(-?)` stores the
# 32-bit minimum, `SET BI = -?` / `-? = ID` overflow like the engine), the
# L2 nullability and subtype, the HAVING aggregate arms and every safety
# refusal of rounds 1-6. WHAT REFUSES BY DESIGN (eng_only / dml_rb_eng_only
# 'R7 scope cut: refuses', eng_raises_fc_refuses; each a shape the previous
# binary refused, answered WRONG for some measured bind, or prepared then
# failed): a whole side whose other side reads a WITH TIME ZONE column; a
# chain of 2+ minuses as a direct operand of an operator on a compare side
# (the engine prepares and raises Integer overflow at the 32-bit minimum,
# answers otherwise); a simple CASE whose bare `?` IS the side against a
# bare `?` or, beside a scale-0 exact sibling, a CAST(? ..) other side;
# a conditional's bare `?` branch against an INT128 / DECFLOAT side or a
# side reading a DOUBLE / FLOAT / INT128 / DECFLOAT column; the string
# functions the engine cannot type over a bare `?` (LEFT / RIGHT / REVERSE
# / LPAD / RPAD / CHAR_LENGTH / OCTET_LENGTH source, LPAD / RPAD pad,
# MOD(?, ?), SUBSTRING's FROM bound - the engine's -804); a numeric simple
# CASE's bare `?` under `||` in a select list or WHERE; TRIM(?) into a
# non-text slot. WHAT IS RECORDED PRE-EXISTING (`recorded` and
# `dml_rb_recorded`: the engine's AND this server's answer are both in the
# cell, this server's identical to the previous binary's, and the cell
# fails when either moves): the simple-CASE bare `?` cast into its slot
# (`CASE ID WHEN 2 THEN ? ELSE 0 END = 2` ['2.4'] answers row 2, the
# engine none; `> 2` answers none, the engine row 2), a conditional's
# arithmetic branch typed from its sibling (`IIF(ID = 2, ? * 2, 1.5) =
# 5.0` ['2.5'] none, the engine 2; the select list 6, the engine 5;
# `IIF(ID = 2, ?, 0) = 2.5` none, the engine 2), the DML destination side
# rule at the destination's width (`SET N18 = ? * 2` ['2.5'] stores 6,
# the engine 5.0; `2 * ?` 5 against 6.0; `SET NM = 2 / ?` 0.8 against
# 0.66; `NM = NM / ?` 2.9 against 2.42; `-? * 1` into N18 / N10 at the
# 4-byte minimum stores 2147483648 where the engine raises Integer
# overflow), CAST(<WITH TIME ZONE> AS TIMESTAMP / DATE / TIME) raising
# the conversion error where the engine converts to the session zone, and
# the fractional-divisor cells of round 6 (`NM = 7.5 / ?` ['2.5'] stores
# 3, the engine 2.5) now answering the previous binary's value where
# round 6 refused them. Kept from rounds 5-6: the scaled-slot overflow
# raise with its signed accumulator, the one-argument TRIM eval, the
# Refused inner plan in corr_register, the 22003 store text. 'floor:'
# cells are cells the previous binary answered exactly like the engine;
# teeth on /tmp/fcwire-prev-c34c1c8 (this round's audit run): 582 OK /
# 812 FAIL, sections 6 and 7 fully green, 0 red 'floor:' cells, and its
# 11 panics at the Trim eval caught by panic_free. The audit also made a
# LOST CONNECTION (a panic mid-statement, node's *Connection to Firebird
# server was lost*) print CONN_ERR instead of ERR in every runner, so it
# FAILS the cell it hits in every helper instead of reading as a refusal.
#
# ROUND 8 (2026-09-19, the scope-cut refuter's Q1-Q4; section 4o, every
# cell measured three-way - engine, this binary, /tmp/fcwire-prev-c34c1c8
# - before its helper was chosen): Q1 a negated `?` under chunk 45's
# scale-0 multiply rounding cast beside a SCALED 2/4-byte sibling
# (`IIF(ID = 2, -? * 1, N41)` [-32768] 32768, `IIF(ID = 2, -? * 1, NM)`
# ['-2147483648'] 2147483648) negates at the MESSAGE width again: that
# cast is an implicit slot cast and carries the stamp [Expr::Neg] looks
# through. Its '-32767.6' twin exposed the wider class behind it: the
# Int cast's coefficient gate at the SLOT's width (`CAST(.. AS INTEGER)`'s
# rule, new in this chunk) was applied to every implicit slot cast, and
# the engine reads an OPERAND of + - * /, unary minus or a function at
# the operator's own width - `SET N = ? + 1`, `SET N = -?`, `SET NM = ?
# * 1`, `SET N = MOD(?, 5)`, `IIF(ID = 2, ? * 1, N41)` bound a text with a
# long coefficient ('1.999999999999', '3276.75') raised *numeric value is
# out of range* where the engine and the previous binary answer; an
# operand's cast now reads the text as the previous binary did, while a
# VALUE position (a bare branch, a COALESCE / NULLIF argument, a `||`
# operand, the DML value) keeps the gate, which is the engine's there.
# Q2 an EXPONENT-spelled text cast to an exact NUMERIC (the compare-side
# rungs' `scaled` cast, a user CAST, a DML value) reads by the engine's
# own decompose - mantissa in the backing width, trailing fraction zeros
# forgiven only at the end of the text, rounding on the first dropped
# digit, an exponent of 3276 out of range - where it raised *Conversion
# error* on both binaries (INT128 backings and hex are left as they were,
# recorded). Q3 `? * ?` under a 2/4-byte slot multiplies in INT64 and
# raises *Integer overflow* past it, as the engine's int64 branch does.
# Q4 a bare `?` in a TEXT-reconciled COALESCE (the chunk's conditional
# branch shapes, the DML router, a nested COALESCE) raises *string right
# truncation* when its non-blank characters pass the slot, when the node
# is evaluated - a check only, the value is never converted. Two R7
# 'recorded' cells moved to the engine's answer with Q1 and are promoted
# (`SET N18 = -? * 1` / `SET N10 = -? * 1` [-2147483648] raise Integer
# overflow on both; both earlier binaries stored 2147483648). Floor
# counted from the measured run below.
#
# ROUND 9 (2026-09-19, the commit-gate refuter's findings; section 4p,
# every cell measured three-way - engine, this binary,
# /tmp/fcwire-prev-c34c1c8 - and its helper chosen from what they
# answered, never typed): P1 THE COEFFICIENT GATE IS STRUCTURAL. Round
# 5's `CAST(text AS INTEGER)` law (the digits must fit the target's
# width before rounding) reached an OPERAND through three routers in a
# row - the DML value router (round 7), its operands (round 8) and now
# MERGE (`MERGE .. SET N = ? + 1` ['4.999999999999'] raised where the
# engine and the previous binary store 6; the refuter's 86 shapes / 202
# cells) and the trigger view (`UPDATE <view> SET N = ? + 1`, whose
# generated `CAST(? AS INTEGER)` text re-planned as the statement's
# own). The Int arm now asks ONE predicate of the cast's stamp: a
# written CAST, an implicit cast at a VALUE position (the bare value, a
# COALESCE / NULLIF / IIF / CASE arm, a `||` operand, a LAG default) and
# a compare operand rung built at its operator's width keep the gate;
# every other implicit cast reads the text the previous binary's way.
# MERGE markers and the trigger view's generated casts are stamped from
# the same tree positions the DML router uses. The 'floor:' cells pin
# those routers' operands (every one fails on the round-8 cut, passes on
# the previous binary). P2 a plain decimal's trailing fraction zeros are
# forgiven only when they END the text: an exponent (`'1.00000e0'` into
# SMALLINT) or a trailing blank (`'2.00000000000 '` into INTEGER) keeps
# them, as the engine's decompose does. P3 a single `?` times a 4-byte
# exact operand multiplies in INT64 and raises *Integer overflow*. P4 a
# DOUBLE message into a TEXT-reconciled COALESCE is rendered the
# engine's way (float_to_text into the slot's BYTE width) and counted,
# and a text of exactly the CHAR slot's byte length takes the engine's
# fast path. P5 under an INT64 slot a multiply / divide reads its
# operand at INT128, and an operator rung reads a hex text signed at its
# width. The trigger view VT joins the fixture for P1. Recorded: an add's
# operand, which the engine reads at int64 and both binaries at int128
# (`MERGE .. SET BI = ? + 1` ['1.9999999999999999999'] stores 3), and a
# 17-digit hex under an int128 rung (the text grammar stops at 16).
#
# ROUND 10 (2026-09-19, BACK TO THE PREVIOUS BINARY BY CONSTRUCTION; no
# new law). Nine rounds showed one pattern: every value law this chunk
# put at an IMPLICIT position - a cast the statement did not write -
# regressed a shape somewhere else (round 9's refuter: a value arm beside
# a WIDER sibling, `UPDATE T SET N = IIF(ID = 1, ?, BI)` ['4.999999999999'],
# read at INT64 and stored 5 by the engine and the previous binary, raised
# here at the destination's LONG - 78 shapes, 304 cells). So the Int arm's
# coefficient gate now runs ONLY for a CAST the statement wrote and for a
# comparison operand rung (a shape the previous binary refused entirely);
# every implicit cast - a value position, an operand, a MERGE marker, a
# trigger view's generated cast, a LAG default, a computed column's own
# cast - reads the text EXACTLY as the previous binary's Int arm did, and
# the NUMERIC arm's exponent read likewise stays on written casts and
# compare rungs. The STORE path (a DML value, MERGE, the trigger view, a
# procedure argument) reads as the previous binary did too: the
# trailing-zero forgiveness had answered a text past the engine's 22-byte
# SMALLINT / NUMERIC(4,1) buffer. A compare rung keeps the forgiveness only
# where the zeros END the text (`? + 0 = N18` ['2.0000000000000000000 ']
# raises like the engine). A `?` in a CONDITION of a MERGE or trigger-view
# value (`MERGE .. SET N = IIF(? = 5, 1, 7)`) is refused at prepare, as the
# previous binary refused it - those paths re-plan generated text and
# rounded the `?` into the destination before the compare. And a statement
# that MIXES a comparison `?` the previous binary refused with an implicit
# integer cast over a `?` (`UPDATE T SET N = COALESCE(?, 0) WHERE ID * ? =
# 1`) is refused at prepare as well, since the implicit cast's
# previous-binary reading would otherwise be a NEW wrong answer in a
# statement the previous binary never planned. Where rounds 8-9 had the
# gate right and the previous binary wrong, the cell is now a 'recorded:
# pre-existing (round 10 ...)' cell carrying both values; every cell was
# re-measured three-way (scratchpad r10fx).
#
# ROUND 11 (2026-09-19; no new value law). Round 10's refuter found three
# families of NEW wrong answers, each in a statement the previous binary
# refused at prepare. W1: a NEGATION CHAIN over a `?` as a whole comparison
# side (`-? = -N`, `N = -(-?)`, `-? IN (..)`, `-? BETWEEN ..`, `IIF(-? =
# ..)`, `CASE WHEN -? = ..`, HAVING, the DML twins) read a 16+-digit text
# with a correctly rounded double where the engine's negate accumulates
# digit by digit - it now REFUSES at prepare in every router, as the
# previous binary did; a negated `?` that is an OPERAND of + - * / keeps
# its rung ('floor:' cells). W2: a whole-side text is classed the way the
# engine's compare classes it (int64 accumulator / int128 decompose /
# neither), and both operands are aligned to the finer scale in that
# width - the COLUMN's value too, row by row - raising *numeric value is
# out of range* exactly where the engine does (`IIF(ID = ?, 1, 0)` bound
# '1.' + 38 zeros answers row 1 and raises on row 2); the same law now
# carries a text LITERAL's compare, a subquery body's whole-side `?`, and
# an operator rung reads its end-running fraction zeros past i128. W3: the
# mixed-statement refusal marks every comparison `?` the previous binary
# refused (the parenthesised `(?) = ID` included) and every implicit
# NUMERIC / approximate cast and written NUMERIC cast over a `?` - a
# census, not a spot fix. And an IN list mixing a `?` item with a
# `?`-free one inside a condition refuses (the engine reads that `?` into
# its described slot first). Every cell that pinned a negated whole side
# is now an 'R11 refuses' cell (the previous binary refused each - the
# teeth run proves it); section 4r pins the rest (scratchpad r11).
#
# ROUND 12 (2026-09-19; NO new law - the caps). Eleven rounds of engine
# laws did not converge: every refuter found new wrong answers, almost all
# from exotic TEXT spellings or from one chunk-new `?` sharing a statement
# with an older reading. Round 12 caps what the chunk-new code accepts,
# driven by ONE mark on the slot's descriptor (PARAM_CHUNK_NEW: a `?`
# typed from the other side of a comparison, a `?` in a CASE / IIF
# condition, or a `?` compared with a side that itself carries one). K1: a
# statement carrying a chunk-new slot AND a classic one refuses at
# prepare. K2: a TEXT bound into a chunk-new NUMERIC slot must be canonical
# (^[+-]?[0-9]+(\.[0-9]*)?$ or ^[+-]?\.[0-9]+$, at most 18 significant
# digits, trailing fraction zeros counted) or it raises the engine's
# conversion error at EXECUTE - a recorded BOUNDARY, never a wrong answer
# (the new `boundary_err` helper; `both_err` where the engine raises too).
# K3: a chunk-new comparison whose `?` is read in DOUBLE refuses (an
# operand rung beside a DOUBLE slot or sibling, an approximate CAST or
# COALESCE in a condition); a bare `?` as the WHOLE side stays. K4: a TEXT
# slot beside a conditional's bare-`?` value arm in a chunk-new router, and
# a one-operand TRIM over a `?` in any conditional's arm (the previous
# binary panicked on every non-null bind), refuse. A chunk-new statement
# calling a QUALIFIED built-in (`b.IIF(..)`) refuses, as the engine does.
# The 40-byte text into a VARCHAR conditional arm keeps answering (the
# engine's byte fast path, measured over 46 compositions). Every cell the
# caps changed was re-derived from a three-way probe (scratchpad
# r12/rederive.json): 'R12 cap: <K>' where the previous binary refused (or
# panicked), 'R12 boundary: conversion error by design (K2)' for the rest;
# section 4s pins each cap and its controls.
set -u
FCWIRE="${FCWIRE:-$(dirname "$0")/../target/release/fcwire}"
ISQL="${ISQL:-isql}"
PORT="${1:-4383}"
REAL="${FC_REAL_PORT:-3050}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
D="/tmp/fbhandson"
ENG="$D/cmpparam-$PORT-eng.fdb"; FC="$D/cmpparam-$PORT-fc.fdb"
command -v node >/dev/null 2>&1 || { echo "SKIP node not found"; exit 0; }
node -e 'require("node-firebird")' 2>/dev/null || { echo "SKIP node-firebird not resolvable (NODE_PATH=/home/ubuntu/work)"; exit 0; }
mkdir -p "$D"; rm -f "$ENG" "$FC"
"$ISQL" -q -b -user "$U" -pas "$P" >/tmp/cmpparam-$PORT-build.log 2>&1 <<SQL
CREATE DATABASE '127.0.0.1/$REAL:$ENG' USER '$U' PASSWORD '$P' PAGE_SIZE 8192;
CREATE TABLE T (ID INTEGER, NM NUMERIC(9,2), N INTEGER, BI BIGINT, S VARCHAR(10), D DOUBLE PRECISION, DT DATE, NN INTEGER NOT NULL);
CREATE TABLE TS (ID INTEGER, SM SMALLINT, TM TIME, TSP TIMESTAMP, C CHAR(4), N18 NUMERIC(18,1), N10 NUMERIC(10,2), N41 NUMERIC(4,1), TZ TIMESTAMP WITH TIME ZONE, TMZ TIME WITH TIME ZONE, I1 INT128, FL FLOAT);
CREATE VIEW V AS SELECT ID, NM, N, BI, D, NN, 1.5 AS L, CAST(ID AS SMALLINT) AS SH FROM T;
CREATE VIEW VT AS SELECT ID, NM, N, BI FROM T;
COMMIT;
SET TERM ^ ;
CREATE TRIGGER VTU FOR VT BEFORE UPDATE AS
BEGIN UPDATE T SET NM = NEW.NM, N = NEW.N, BI = NEW.BI WHERE ID = OLD.ID; END^
CREATE TRIGGER VTI FOR VT BEFORE INSERT AS
BEGIN INSERT INTO T (ID, NM, N, BI, NN) VALUES (NEW.ID, NEW.NM, NEW.N, NEW.BI, 1); END^
SET TERM ; ^
COMMIT;
INSERT INTO T VALUES (1, 7.25, 3, 9, 'ab', 1.5, DATE '2024-01-10', 5);
INSERT INTO T VALUES (2, 1.00, 4, 8, 'cd', 2.5, DATE '2024-02-10', 6);
INSERT INTO T VALUES (3, 2.50, 4, 7, 'ef', 3.5, DATE '2024-03-10', 7);
INSERT INTO TS VALUES (1, 2, TIME '12:30:00', TIMESTAMP '2024-01-10 12:30:00', 'ab', 2.5, 2.5, 2.5, TIMESTAMP '2024-01-10 12:30:00 +03:00', TIME '12:30:00 +03:00', 2, 2.5);
INSERT INTO TS VALUES (2, -32768, TIME '01:02:03', TIMESTAMP '2024-02-10 00:00:00', 'cd', 3.5, 3.5, 3.5, TIMESTAMP '2024-02-10 00:00:00 +00:00', TIME '01:02:03 +00:00', 3, 0.1);
INSERT INTO TS VALUES (3, 3, TIME '12:30:00.0001', TIMESTAMP '2024-03-10 12:30:00.5', 'ab  ', 1.5, 1.5, 1.5, TIMESTAMP '2024-03-10 12:30:00.5 Europe/Bucharest', TIME '12:30:00.0001 Europe/Bucharest', -2147483648, 3.5);
COMMIT;
SQL
if grep -qi error /tmp/cmpparam-$PORT-build.log; then
    echo "FAIL building the fixture:"; sed 's/^/     /' /tmp/cmpparam-$PORT-build.log; exit 1
fi
[ -s "$ENG" ] || { echo "FAIL fixture not created"; exit 1; }
cp "$ENG" "$FC"; chmod 666 "$FC"

"$FCWIRE" serve "127.0.0.1:$PORT" "$U" "$P" >/tmp/fc-serve-cmpparam-$PORT.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -f "$ENG" "$FC"' EXIT
i=0; while [ $i -lt 20 ]; do
    kill -0 $srv 2>/dev/null || break
    ( exec 3<>"/dev/tcp/127.0.0.1/$PORT" ) 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
kill -0 $srv 2>/dev/null || { echo "FAIL fcwire is not running - port $PORT already in use?"; exit 1; }

fail=0
ran=0
# a connection that DIES mid-statement (node: *Connection to Firebird
# server was lost* / ECONNRESET / EPIPE) is a PANIC on the server side,
# never a refusal: it prints CONN_ERR, and every helper fails LOUDLY on
# CONN_ERR after `run` has retried it eight times
LOST='const lost=e=>/was lost|ECONNRESET|EPIPE|Connection is closed|socket hang up/i.test(String((e&&e.message)||e));'
q() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 20 node -e "$LOST"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
      if(e2){if(lost(e2)){console.log("CONN_ERR");process.exit(1);}console.log("ERR");db.detach();process.exit(0);}
      if(!r||!r.length){console.log("(none)");db.detach();process.exit(0);}
      console.log(r.map(x=>Object.values(x).join()).join(";"));db.detach();process.exit(0);
    });
  });' 2>/dev/null; }
run() { local n=0 r; while [ $n -lt 8 ]; do r=$(q "$1" "$2" "$3" "$4")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
# EVERY slot of the describe, input and output, on one line
dsc() { printf 'SET SQLDA_DISPLAY ON;\n%s;\n' "$2" \
    | timeout 25 "$ISQL" -q -b -user "$U" -pas "$P" "$1" 2>&1 | tr -d '\r' \
    | grep -aiE 'sqltype' | sed 's/^ *//' | tr -s ' ' | paste -sd'|'; }

# value AND describe must both match
both() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ] && [ "$fv" = ERR ]; then
        echo "FAIL $1 [VACUOUS: BOTH refuse - that is a both_refuse cell]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - the value agrees, the announcement does not)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# a statement that WRITES and returns nothing through node (an INSERT):
# both servers must accept it and announce the same slots; the row is
# then read back by a `both` cell
write() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE refused the write"; fail=1
    elif [ "$fv" = ERR ]; then echo "FAIL $1 - THIS server refused the write"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE of the write)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 (written on both)"; fi
}
# the VALUE is right and the ANNOUNCEMENT is not - recorded, and it says
# so when that stops being true
desc_differs() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 - the VALUE diverged, which this cell does not cover"
        echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" = "$fd" ]; then
        echo "FAIL $1 - THE DESCRIBE GAP IS CLOSED; promote this cell to \`both\`"; fail=1
    else echo "OK   $1 (recorded describe gap)"; fi
}
# the engine ANSWERS and this server refuses - a recorded boundary
eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = ERR ]; then echo "FAIL $1 - the ENGINE no longer answers; the boundary moved"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS SERVER NOW ANSWERS [$fv]; promote this cell"; fail=1
    else echo "OK   $1 (engine [$ev], this server refuses - recorded)"; fi
}
both_refuse() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" != ERR ]; then echo "FAIL $1 - the ENGINE answered [$ev]"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    else echo "OK   both refuse: $1"; fi
}
# both servers PREPARE the statement (describe lines on both, and equal)
# and both RAISE at execute - the engine's *conversion error from string*
# on a whole-side `?`; a refusal at prepare on either side is NOT that
both_err() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 - the ENGINE did not prepare it; that is a both_refuse cell"; fail=1
    elif [ "$ev" != ERR ]; then echo "FAIL $1 - the ENGINE answered [$ev]"; fail=1
    elif [ -z "$fd" ]; then
        echo "FAIL $1 - THIS server refused at PREPARE where the engine prepares and raises at execute"; fail=1
    elif [ "$fv" != ERR ]; then
        echo "FAIL $1 - THIS server ANSWERED [$fv] where the engine raises at execute"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE - both raise, the announcement differs)"
        echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 (both prepare, both raise at execute)"; fi
}
# a SELECT the ENGINE prepares (describe lines) and RAISES at execute while
# THIS server refuses it at PREPARE (no describe, an error): the allowed
# floor of round 7's scope cut - a 2+ minus chain under an operator on a
# compare side, which the previous binary refused too; it says so when the
# engine stops raising or this server starts preparing it
eng_raises_fc_refuses() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv ed fd
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 - the ENGINE did not prepare it; that is a both_refuse cell"; fail=1
    elif [ "$ev" != ERR ]; then echo "FAIL $1 - the ENGINE answered [$ev]; the boundary moved"; fail=1
    elif [ -n "$fd" ]; then echo "FAIL $1 - THIS server PREPARES it [$fd] (it answered or failed at execute: [$fv])"; fail=1
    elif [ "$fv" != ERR ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    else echo "OK   $1 (engine prepares and raises at execute, this server refuses at prepare)"; fi
}
# a DML statement and a read-back SELECT run in ONE transaction that is
# ROLLED BACK on both servers: the RETURNING rows, the read-back and the
# describe must all agree, and the fixture is untouched afterwards
# whatever either server did - a wrong row taken by the DML cannot leak
# into the cells after it
qtx() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" FC_RB="$5" timeout 25 node -e "$LOST"'
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      if(et){console.log("CONN_ERR");process.exit(1);}
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
        if(e2&&lost(e2)){console.log("CONN_ERR");process.exit(1);}
        const dml=e2?"ERR":fmt(r);
        tr.query(process.env.FC_RB,[],(e3,r2)=>{
          if(e3&&lost(e3)){console.log("CONN_ERR");process.exit(1);}
          const rb=e3?"ERR":fmt(r2);
          tr.rollback(()=>{console.log("dml="+dml+" rb="+rb);db.detach();process.exit(0);});
        });
      });
    });
  });' 2>/dev/null; }
runtx() { local n=0 r; while [ $n -lt 8 ]; do r=$(qtx "$1" "$2" "$3" "$4" "$5")
  case "$r" in *CONN_ERR*|"") n=$((n + 1)); sleep 0.3;; *) printf '%s' "$r"; return;; esac; done; echo CONN_ERR; }
dml_rb() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="${4:-SELECT ID, N FROM T ORDER BY ID}" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE refused the DML [$ev]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value - RETURNING rows or the read-back)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE of the DML)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev] (rolled back)"; fi
}
# dml_rb for a statement whose VALUE and read-back agree while its
# announcement carries a RECORDED describe gap (a scalar-subquery slot
# announced NOT NULL where the engine says Nullable): the rows must
# agree and the gap must still be there - it says so when it closes
dml_rb_desc_differs() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="${4:-SELECT ID, N FROM T ORDER BY ID}" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE refused the DML [$ev]"; fail=1
    elif [ -z "$ed" ] || [ -z "$fd" ]; then
        echo "FAIL $1 [a server printed no describe - the cell measured nothing]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (value - RETURNING rows or the read-back)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" = "$fd" ]; then
        echo "FAIL $1 - THE DESCRIBE GAP IS CLOSED; promote this cell to \`dml_rb\`"; fail=1
    else echo "OK   $1 [$ev] (rolled back; recorded describe gap)"; fi
}
# dml_rb for a statement BOTH servers must RAISE at execute inside the
# rolled-back transaction (the engine's *Integer overflow* on a negated
# `?` at the 32-bit minimum): both raise, the read-backs agree (the rows
# untouched), the describes agree - and nothing is committed on either
# server, so a binary that STORES instead of raising cannot pollute the
# cells after it (a `both_err` UPDATE / INSERT here auto-commits: on the
# previous binary it stored 2147483648 and inserted a fourth row, and
# the section 7 controls went red for that reason alone)
dml_rb_both_err() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="${4:-SELECT ID, N FROM T ORDER BY ID}" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not raise [$ev]"; fail=1
    elif [ -z "$ed" ]; then
        echo "FAIL $1 [the ENGINE printed no describe - the cell measured nothing]"; fail=1
    elif [ -z "$fd" ]; then
        echo "FAIL $1 - THIS server refused at PREPARE where the engine prepares and raises at execute"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then echo "FAIL $1 - THIS server did not raise [$fv]"; fail=1
    elif [ "${ev#*rb=}" != "${fv#*rb=}" ]; then
        echo "FAIL $1 (the read-back after the raise differs)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    elif [ "$ed" != "$fd" ]; then
        echo "FAIL $1 (DESCRIBE of the DML)"; echo "     eng=[$ed]"; echo "     fc =[$fd]"; fail=1
    else echo "OK   $1 [$ev] (both raise; rolled back)"; fi
}
# the server's stderr log is the ONE place a PANIC shows: a panicked
# connection thread closes its socket (node reads *Connection to Firebird
# server was lost*, which every cell above records as ERR - the same word
# as a refusal - and `run` retries a fresh connection that panics again)
# while the PROCESS survives, so an ERR alone cannot tell a refusal from a
# crash, and neither can CONN_ERR. This cell reads the log and the pid.
SRVLOG="/tmp/fc-serve-cmpparam-$PORT.log"
panic_free() {
    ran=$((ran + 1))
    local n
    if ! kill -0 $srv 2>/dev/null; then echo "FAIL $1 - THE SERVER PROCESS IS GONE"; fail=1; return; fi
    n=$(grep -ac 'panicked at' "$SRVLOG" 2>/dev/null); n=${n:-0}
    if [ "$n" -gt 0 ]; then
        echo "FAIL $1 - $n PANIC(S) in the server log: $(grep -a -m1 -A1 'panicked at' "$SRVLOG" | paste -sd' ')"; fail=1
    else echo "OK   $1 (no panic in the server log; the process is alive)"; fi
}
# both raise at execute inside a rolled-back transaction AND the error
# TEXT agrees line for line - the engine's *numeric value is out of
# range* on a store overflow (round 5 said *Dynamic SQL Error* there) and
# its *Integer overflow* on a negation chain; a connection that DIES
# mid-statement is named as such, never folded into ERR
qmsg() { FC_DB="$2" FC_PORT="$1" FC_Q="$3" FC_P="$4" timeout 25 node -e '
  process.on("uncaughtException",()=>{console.log("CONN_ERR");process.exit(1);});
  const F=require("node-firebird");
  const fmt=r=>(!r||!r.length)?"(none)":r.map(x=>Object.values(x).join()).join(";");
  F.attach({host:"127.0.0.1",port:+process.env.FC_PORT,database:process.env.FC_DB,user:"SYSDBA",password:"masterkey"},(e,db)=>{
    if(e){console.log("CONN_ERR");process.exit(1);}
    db.transaction(F.ISOLATION_READ_COMMITTED,(et,tr)=>{
      if(et){console.log("CONN_ERR");process.exit(1);}
      tr.query(process.env.FC_Q,JSON.parse(process.env.FC_P),(e2,r)=>{
        const out=e2?("ERR "+e2.message.replace(/\s+/g," ").trim()):("rows "+fmt(r));
        tr.rollback(()=>{console.log(out);db.detach();process.exit(0);});
      });
    });
  });' 2>/dev/null; }
err_msg() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv
    ev=$(qmsg "$REAL" "$ENG" "$2" "$js"); fv=$(qmsg "$PORT" "$FC" "$2" "$js")
    case "$fv" in *"server was lost"*|CONN_ERR|"")
        echo "FAIL $1 - THE CONNECTION DIED mid-statement on this server (a panic?) [$fv]"; fail=1; return;; esac
    if [ "${ev#ERR }" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not raise [$ev]"; fail=1
    elif [ "$ev" != "$fv" ]; then
        echo "FAIL $1 (the error TEXT differs)"; echo "     eng=[$ev]"; echo "     fc =[$fv]"; fail=1
    else echo "OK   $1 [$ev]"; fi
}
# ROUND 12, K2 - A RECORDED BOUNDARY, NEVER A WRONG ANSWER: a TEXT bound
# into a chunk-new NUMERIC slot that is off the canonical grammar
# (^[+-]?[0-9]+(\.[0-9]*)?$ or ^[+-]?\.[0-9]+$, at most 18 significant
# digits, trailing fraction zeros counted) raises the engine's *conversion
# error from string* at EXECUTE here, where the ENGINE answers it. Passes
# when the engine answers and this server PREPARES (describe lines) and
# then raises that conversion error; FAILS LOUDLY when this server answers
# a value (the cap is gone), refuses at prepare, raises anything else, or
# when the engine raises too (that is a both_err cell). DML runs inside the
# rolled-back transaction (qmsg), so nothing it does can leak.
boundary_err() {
    ran=$((ran + 1))
    local js="${3:-[]}" ev fv fd
    ev=$(qmsg "$REAL" "$ENG" "$2" "$js"); fv=$(qmsg "$PORT" "$FC" "$2" "$js")
    fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    case "$fv" in *"server was lost"*|CONN_ERR|"")
        echo "FAIL $1 - THE CONNECTION DIED on this server (a panic?) [$fv]"; fail=1; return;; esac
    case "$ev" in CONN_ERR|"") echo "FAIL $1 [the ENGINE cell never ran]"; fail=1; return;; esac
    if [ "${ev#ERR }" != "$ev" ]; then echo "FAIL $1 - the ENGINE raises too [$ev]; that is a both_err cell"; fail=1
    elif [ "${fv#ERR }" = "$fv" ]; then echo "FAIL $1 - THIS SERVER ANSWERED A VALUE [$fv] (engine [$ev]); the K2 cap is gone"; fail=1
    elif [ -z "$fd" ]; then echo "FAIL $1 - THIS server refused at PREPARE; the K2 boundary prepares and raises at execute [$fv]"; fail=1
    else case "$fv" in
        *[Cc]"onversion error from string"*) echo "OK   $1 (engine [$ev]; this server raises the conversion error by design)";;
        *) echo "FAIL $1 - THIS server raised something else [$fv] (engine [$ev])"; fail=1;;
    esac; fi
}
# a VALUE this server answers DIFFERENTLY from the engine, identically on
# the previous committed binary - a PRE-EXISTING divergence this chunk
# neither introduced nor touched (round 7, the scope cut): the engine's
# and this server's answers are both in the label; the cell FAILS when
# this server's answer moves (a new wrong answer is not the recorded one)
# and when it reaches the engine's (promote the cell to `both`)
recorded() {
    ran=$((ran + 1))
    local js="${3:-[]}" want="${4:-}" ev fv
    ev=$(run "$REAL" "$ENG" "$2" "$js"); fv=$(run "$PORT" "$FC" "$2" "$js")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES WITH THE ENGINE [$ev]; promote this cell to \`both\`"; fail=1
    elif [ "$fv" != "$want" ]; then
        echo "FAIL $1 - this server's answer MOVED (recorded [$want], now [$fv]; engine [$ev])"; fail=1
    else echo "OK   $1 (engine [$ev], this server [$fv] - recorded, unchanged)"; fi
}
# the same for a DML under rollback: the RETURNING rows and the read-back
# differ from the engine's exactly as recorded in the FIFTH argument (this
# server's measured `dml=.. rb=..`, the previous binary's rows); FAILS
# when they agree with the engine (promote to dml_rb) or MOVE (the audit
# of round 7 found the pin missing: the cell only asserted "differs")
dml_rb_recorded() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="${4:-SELECT ID, N FROM T ORDER BY ID}" want="${5:-}" ev fv
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ -z "$want" ]; then echo "FAIL $1 - the cell carries NO recorded rows (5th argument); measure them"; fail=1
    elif [ "$ev" = "$fv" ]; then echo "FAIL $1 - THIS SERVER NOW AGREES WITH THE ENGINE [$ev]; promote this cell to \`dml_rb\`"; fail=1
    elif [ "$fv" != "$want" ]; then
        echo "FAIL $1 - this server's rows MOVED (recorded [$want], now [$fv]; engine [$ev])"; fail=1
    else echo "OK   $1 (engine [$ev], this server [$fv] - recorded, unchanged)"; fi
}
# put the three fixture rows back on BOTH servers after the DML cells -
# REBUILT from nothing, so a binary that DELETED a fixture row (the first
# cut took row 2 on `DELETE .. WHERE -? = ID` ['-2.4']) does not carry
# that loss into every cell after this point and turn the controls red
reset_rows() {
    local s
    for s in "$REAL $ENG" "$PORT $FC"; do set -- $s
        run "$1" "$2" "DELETE FROM T" '[]' >/dev/null
        run "$1" "$2" "INSERT INTO T VALUES (1, 7.25, 3, 9, 'ab', 1.5, DATE '2024-01-10', 5)" '[]' >/dev/null
        run "$1" "$2" "INSERT INTO T VALUES (2, 1.00, 4, 8, 'cd', 2.5, DATE '2024-02-10', 6)" '[]' >/dev/null
        run "$1" "$2" "INSERT INTO T VALUES (3, 2.50, 4, 7, 'ef', 3.5, DATE '2024-03-10', 7)" '[]' >/dev/null
    done
}

# a DML the ENGINE answers - run under rollback, so its rows never leak
# - while THIS server refuses it at PREPARE: a recorded boundary (the
# `*` whitelist's, or a whole-side `?` in a DML's subquery body). It
# says so when the boundary moves either way
dml_rb_eng_only() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="${4:-SELECT ID, N FROM T ORDER BY ID}" ev fv fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ "${ev#dml=ERR}" != "$ev" ]; then echo "FAIL $1 - the ENGINE refused the DML [$ev]; the boundary moved"; fail=1
    elif [ -n "$fd" ]; then echo "FAIL $1 - THIS SERVER NOW PREPARES IT [$fd]; promote this cell to dml_rb"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then echo "FAIL $1 - THIS SERVER ANSWERED [$fv] where it refuses at prepare"; fail=1
    else echo "OK   $1 (engine [$ev] rolled back; this server refuses at prepare - recorded)"; fi
}

# a DML BOTH servers refuse at prepare (the engine's -802 on `? + ?` in a
# simple-CASE value), run inside the rolled-back transaction so a binary
# that ANSWERS it (the previous one changed row 2 here) cannot commit the
# wrong rows into the cells after it: both dml=ERR, neither describes,
# the read-backs agree
dml_rb_both_refuse() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="${4:-SELECT ID, N FROM T ORDER BY ID}" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ -n "$ed" ] || [ "${ev#dml=ERR}" = "$ev" ]; then echo "FAIL $1 - the ENGINE prepared it [$ev]; that is not a both-refuse cell"; fail=1
    elif [ -n "$fd" ]; then echo "FAIL $1 - THIS server PREPARES it [$fd] where the engine refuses"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    elif [ "${ev#*rb=}" != "${fv#*rb=}" ]; then
        echo "FAIL $1 (the read-back after the refusals differs)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   both refuse: $1 (rolled back)"; fi
}
# a DML the ENGINE prepares and RAISES at execute (Integer overflow on a
# second minus over the LONG minimum) while THIS server refuses it at
# PREPARE - the allowed floor, never an answer: the engine describes and
# raises, this server prints no describe, the read-backs agree (rows
# untouched on both), everything rolled back
dml_rb_eng_raises_fc_refuses() {
    ran=$((ran + 1))
    local js="${3:-[]}" rb="${4:-SELECT ID, N FROM T ORDER BY ID}" ev fv ed fd
    ev=$(runtx "$REAL" "$ENG" "$2" "$js" "$rb"); fv=$(runtx "$PORT" "$FC" "$2" "$js" "$rb")
    ed=$(dsc "127.0.0.1/$REAL:$ENG" "$2"); fd=$(dsc "127.0.0.1/$PORT:$FC" "$2")
    if [ "$ev" = CONN_ERR ] || [ "$fv" = CONN_ERR ]; then
        echo "FAIL $1 [CONN_ERR - the cell never ran]"; fail=1
    elif [ -z "$ed" ]; then echo "FAIL $1 - the ENGINE did not prepare it; that is a both-refuse cell"; fail=1
    elif [ "${ev#dml=ERR}" = "$ev" ]; then echo "FAIL $1 - the ENGINE did not raise [$ev]; the boundary moved"; fail=1
    elif [ -n "$fd" ]; then echo "FAIL $1 - THIS server PREPARES it [$fd] (it answered or failed at execute: [$fv])"; fail=1
    elif [ "${fv#dml=ERR}" = "$fv" ]; then echo "FAIL $1 - THIS server answered [$fv]"; fail=1
    elif [ "${ev#*rb=}" != "${fv#*rb=}" ]; then
        echo "FAIL $1 (the read-back differs)"; echo "     eng=[$ev] fc=[$fv]"; fail=1
    else echo "OK   $1 (engine prepares and raises, this server refuses at prepare; rolled back)"; fi
}

echo "-- 1. WHERE: a ? inside arithmetic, typed from the OTHER side (both spellings) --"
both "ID * ? = 2 - LONG NOT NULL from the literal"   "SELECT ID FROM T WHERE ID * ? = 2" '[2]'
both "(ID * ?) = 2 - the parenthesised spelling"     "SELECT ID FROM T WHERE (ID * ?) = 2" '[2]'
both "ID + ? > 3"                                    "SELECT ID FROM T WHERE ID + ? > 3" '[1]'
both "(ID + ?) > 3"                                  "SELECT ID FROM T WHERE (ID + ?) > 3" '[1]'
both "ID - ? = 0"                                    "SELECT ID FROM T WHERE ID - ? = 0" '[3]'
both "ID / ? = 1"                                    "SELECT ID FROM T WHERE ID / ? = 1" '[2]'
both "? + 1 = ID - LONG Nullable from the column"    "SELECT ID FROM T WHERE ? + 1 = ID" '[2]'
both "(? + 1) = ID"                                  "SELECT ID FROM T WHERE (? + 1) = ID" '[2]'
both "? * 2 = ID"                                    "SELECT ID FROM T WHERE ? * 2 = ID" '[1]'
both "? - 1 = ID"                                    "SELECT ID FROM T WHERE ? - 1 = ID" '[2]'
both "ID = ? - 1"                                    "SELECT ID FROM T WHERE ID = ? - 1" '[3]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID - unary minus"                         "SELECT ID FROM T WHERE -? = ID" '[-3]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): ID = -?"                                       "SELECT ID FROM T WHERE ID = -?" '[-2]'
# a WHOLE-SIDE `-?` keeps the client's value whole (a negated text is a
# DOUBLE) - the first cut rounded '-2.4' into the LONG slot and took row 2
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID ['-2.4'] -> none (the whole side is not converted)" "SELECT ID FROM T WHERE -? = ID" '["-2.4"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): ID = -? ['-2.5'] -> none"                      "SELECT ID FROM T WHERE ID = -?" '["-2.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? < 2 ['-1.5'] -> every row"                  "SELECT ID FROM T WHERE -? < 2" '["-1.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = NM ['-7.25'] -> 1"                        "SELECT ID FROM T WHERE -? = NM" '["-7.25"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = NM ['-7.245'] -> none"                    "SELECT ID FROM T WHERE -? = NM" '["-7.245"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): ID = -(-?) ['2.4'] -> none"                    "SELECT ID FROM T WHERE ID = -(-?)" '["2.4"]'
eng_raises_fc_refuses "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID ['1 2'] - the negate's DOUBLE grammar raises on both (prepared on both)" "SELECT ID FROM T WHERE -? = ID" '["1 2"]'
# ...while UNDER an operator the operator's rung converts (measured)
both "-? + 1 = ID ['-1.4'] -> 2 (rounded by the + rung)" "SELECT ID FROM T WHERE -? + 1 = ID" '["-1.4"]'
both "ID = -? * 1 ['-2.4'] -> 2"                     "SELECT ID FROM T WHERE ID = -? * 1" '["-2.4"]'
both "ID * ? * 2 = 4 - nested"                       "SELECT ID FROM T WHERE ID * ? * 2 = 4" '[2]'
both "(ID + ?) * 2 = 6 - nested"                     "SELECT ID FROM T WHERE (ID + ?) * 2 = 6" '[2]'
both "ID * ? + 1 = 4.0 - nested under a decimal"     "SELECT ID FROM T WHERE ID * ? + 1 = 4.0" '["2.5"]'
both "? + ? = ID - two ? on one side"                "SELECT ID FROM T WHERE ? + ? = ID" '[1,2]'
both "ID * ? = 2 AND N + ? = 5 - two terms"          "SELECT ID FROM T WHERE ID * ? = 2 AND N + ? = 5" '[1,1]'
both "(ID * ?) + (N * ?) = 8"                        "SELECT ID FROM T WHERE (ID * ?) + (N * ?) = 8" '[2,1]'
both "ID * ? = 2 OR N * ? = 8"                       "SELECT ID FROM T WHERE ID * ? = 2 OR N * ? = 8" '[2,2]'
eng_only "R12 cap: K1: ID * ? = 2 AND S = ? - beside a bare ?"        "SELECT ID FROM T WHERE ID * ? = 2 AND S = ?" '[1,"cd"]'
both "ID * ? = 3.0 AND ID * ? = 2 - two different slots" "SELECT ID FROM T WHERE ID * ? = 3.0 AND ID * ? = 2" '["2.5",2]'
both "ID * ? <> 2"                                   "SELECT ID FROM T WHERE ID * ? <> 2" '[2]'
both "NOT (ID * ? = 2)"                              "SELECT ID FROM T WHERE NOT (ID * ? = 2)" '[1]'
both "ID * ? = 2 OR ID = 3"                          "SELECT ID FROM T WHERE ID * ? = 2 OR ID = 3" '[2]'
both "ID * ? = NN - NOT NULL column"                 "SELECT ID FROM T WHERE ID * ? = NN" '[5]'
both "ID * ? = NM - LONG scale -2 subtype 1"         "SELECT ID FROM T WHERE ID * ? = NM" '["7.25"]'
eng_only "R12 cap: K3: ID * ? = D - DOUBLE column"                    "SELECT ID FROM T WHERE ID * ? = D" '["1.5"]'
both "ID * ? = BI - INT64 column"                    "SELECT ID FROM T WHERE ID * ? = BI" '[9]'
both "N + ? = BI"                                    "SELECT ID FROM T WHERE N + ? = BI" '[4]'
both "BI * ? = 18"                                   "SELECT ID FROM T WHERE BI * ? = 18" '[2]'
both "? + 1 > N * 2 - the other side's COMPUTED type" "SELECT ID FROM T WHERE ? + 1 > N * 2" '[7]'
both "NM * ? = 14.5 - INT64 scale -1 from the decimal literal" "SELECT ID FROM T WHERE NM * ? = 14.5" '[2]'
both "? * NM = 14.5"                                 "SELECT ID FROM T WHERE ? * NM = 14.5" '["5.8"]'
both "ID * ? = 2.50 - scale -2 from the spelling"    "SELECT ID FROM T WHERE ID * ? = 2.50" '["2.5"]'
both "ID * ? = 12345678901 - INT64 literal"          "SELECT ID FROM T WHERE ID * ? = 12345678901" '[12345678901]'
both "ID * ? = 100000000000"                         "SELECT ID FROM T WHERE ID * ? = 100000000000" '[50000000000]'
eng_only "R12 cap: K3: ID * ? = 1.5e0 - DOUBLE literal"               "SELECT ID FROM T WHERE ID * ? = 1.5e0" '["1.5"]'
both "ID * ? = -2"                                   "SELECT ID FROM T WHERE ID * ? = -2" '[-1]'
both "ID * ? = CAST(2 AS SMALLINT) - SHORT slot"     "SELECT ID FROM T WHERE ID * ? = CAST(2 AS SMALLINT)" '[2]'
boundary_err "R12 boundary: conversion error by design (K2): ID * ? = 1.123456789012345678 - scale -18"     "SELECT ID FROM T WHERE ID * ? = 1.123456789012345678" '["1.123456789012345678"]'
both "6.0 = ID * ? - the ? side on the right"        "SELECT ID FROM T WHERE 6.0 = ID * ?" '["2.5"]'
eng_only "R12 cap: K3: D * ? = 3"                                     "SELECT ID FROM T WHERE D * ? = 3" '["1.2"]'
both "S || ? = 'abx' - TEXT len 3 NONE NOT NULL"     "SELECT ID FROM T WHERE S || ? = 'abx'" '["x"]'
both "S || ? = 'abx' bound 'xy' - no row"            "SELECT ID FROM T WHERE S || ? = 'abx'" '["xy"]'
both "? || 'b' = S - VARYING 10 Nullable"            "SELECT ID FROM T WHERE ? || 'b' = S" '["a"]'
both "ID * ? IN (2, 6) - the reconciled list type"   "SELECT ID FROM T WHERE ID * ? IN (2, 6)" '[2]'
both "ID * ? BETWEEN 1 AND 2 - the lower bound"      "SELECT ID FROM T WHERE ID * ? BETWEEN 1 AND 2" '[1]'
both "ID IN (? + 1)"                                 "SELECT ID FROM T WHERE ID IN (? + 1)" '[1]'
both "COUNT(*) over WHERE ID * ? > 1"                "SELECT COUNT(*) AS C FROM T WHERE ID * ? > 1" '[2]'
# a CAST-typed ? on the left and a bare ? on the right: the bare one is
# typed from the CAST side (measured: refused on c34c1c8 - not a both-
# sides shape, since the CAST side carries a type of its own)
eng_only "R12 cap: K1: CAST(? AS INTEGER) = ?  - a typed ? beside a bare one" "SELECT ID FROM T WHERE CAST(? AS INTEGER) = ?" '[2,2]'

echo "-- 2. HAVING sides --"
both "SUM(ID) > ? + 1 - INT64 Nullable"              "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ? + 1" '[2]'
both "? + 1 < SUM(ID)"                               "SELECT N FROM T GROUP BY N HAVING ? + 1 < SUM(ID)" '[2]'
both "SUM(ID) > (? + 1)"                             "SELECT N FROM T GROUP BY N HAVING SUM(ID) > (? + 1)" '[2]'
both "SUM(ID) > (? * 2) + 1"                         "SELECT N FROM T GROUP BY N HAVING SUM(ID) > (? * 2) + 1" '[1]'
both "SUM(ID) * ? > 3 - LONG NOT NULL"               "SELECT N FROM T GROUP BY N HAVING SUM(ID) * ? > 3" '[2]'
both "SUM(ID) - ? = 0"                               "SELECT N FROM T GROUP BY N HAVING SUM(ID) - ? = 0" '[5]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? < SUM(ID)"                                  "SELECT N FROM T GROUP BY N HAVING -? < SUM(ID)" '[0]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? < SUM(ID) ['-4.5'] -> 4 (the whole side, not converted)" "SELECT N FROM T GROUP BY N HAVING -? < SUM(ID)" '["-4.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = SUM(ID) ['-4.5'] -> none"                 "SELECT N FROM T GROUP BY N HAVING -? = SUM(ID)" '["-4.5"]'
both "MAX(NM) = ? * MAX(ID) ['7.25'] -> none (LONG slot, LONG sibling: the LEFT rounds)" "SELECT N FROM T GROUP BY N HAVING MAX(NM) = ? * MAX(ID)" '["7.25"]'
both "COUNT(*) * ? = MAX(NM) ['1.25'] -> none (an INT64 sibling: the RIGHT rounds)" "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? = MAX(NM)" '["1.25"]'
both "COUNT(*) > ? + 1 - INT64 NOT NULL"             "SELECT N FROM T GROUP BY N HAVING COUNT(*) > ? + 1" '[0]'
both "COUNT(*) * ? >= 2"                             "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? >= 2" '[2]'
both "SUM(NM) > ? + 1 - INT64 scale -2 subtype 1"    "SELECT N FROM T GROUP BY N HAVING SUM(NM) > ? + 1" '[2]'
both "SUM(NM) + ? > 8"                               "SELECT N FROM T GROUP BY N HAVING SUM(NM) + ? > 8" '[1]'
both "MAX(NM) * ? > 10"                              "SELECT N FROM T GROUP BY N HAVING MAX(NM) * ? > 10" '[2]'
both "MAX(S) = ? || 'b' - VARYING 10"                "SELECT N FROM T GROUP BY N HAVING MAX(S) = ? || 'b'" '["a"]'
both "MAX(S) = 'e' || ?"                             "SELECT N FROM T GROUP BY N HAVING MAX(S) = 'e' || ?" '["f"]'
both "AVG(ID) > ? * 1.5 - INT64 scale 0"             "SELECT N FROM T GROUP BY N HAVING AVG(ID) > ? * 1.5" '[1]'
both "SUM(ID) > ? + 1.5 - INT64 scale 0"             "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ? + 1.5" '[2]'
both "SUM(ID) > ? + ?"                               "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ? + ?" '[1,3]'
both "MAX(NN) > ? + 1 - Nullable over a NOT NULL column" "SELECT N FROM T GROUP BY N HAVING MAX(NN) > ? + 1" '[5]'
both "SUM(ID) * ? > MAX(NM) - the aggregate's NUMERIC" "SELECT N FROM T GROUP BY N HAVING SUM(ID) * ? > MAX(NM)" '[3]'
both "? * 2 > SUM(ID) + 1"                           "SELECT N FROM T GROUP BY N HAVING ? * 2 > SUM(ID) + 1" '[3]'
eng_only "R12 cap: K3: MAX(D) * ? > 10"                               "SELECT N FROM T GROUP BY N HAVING MAX(D) * ? > 10" '[3]'
eng_only "R12 cap: K1: SUM(ID) > ? + 1 AND COUNT(*) > ? - two slots, two nullabilities"  "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ? + 1 AND COUNT(*) > ?" '[0,1]'
both "SUM(ID) BETWEEN ? + 1 AND 10"                  "SELECT N FROM T GROUP BY N HAVING SUM(ID) BETWEEN ? + 1 AND 10" '[3]'
eng_only "SUM(ID) > COALESCE(?, 0) + ? - a sibling-typed and a comparison-typed slot (round 10: refuses - a comparison `?` the previous binary refused MIXED with an implicit integer cast over a `?` (plan_unmixed); the previous binary refuses it too)" \
     "SELECT N FROM T GROUP BY N HAVING SUM(ID) > COALESCE(?, 0) + ?" '[null,4]'
eng_only "R12 cap: K1: NUMBERING: HAVING's slot before ORDER BY's"     "SELECT N, SUM(ID) AS SM FROM T GROUP BY N HAVING SUM(ID) > ? + 1 ORDER BY SUM(ID * CAST(? AS INTEGER))" '[0,-1]'
both "WHERE ID * ? > 1 GROUP BY N"                   "SELECT N, COUNT(*) AS C FROM T WHERE ID * ? > 1 GROUP BY N" '[2]'
both "HAVING N + ? > 4 - a group key with a ?"       "SELECT N FROM T GROUP BY N HAVING N + ? > 4" '[1]'
both "HAVING N * ? = 8"                              "SELECT N FROM T GROUP BY N HAVING N * ? = 8" '[2]'
both "HAVING ? + 1 > 4 - no column at all"           "SELECT N FROM T GROUP BY N HAVING ? + 1 > 4" '[4]'

echo "-- 3. a CASE / IIF CONDITION, in every clause --"
both "CASE WHEN ID = ? - LONG Nullable from ID"      "SELECT CASE WHEN ID = ? THEN 1 ELSE 0 END AS X FROM T" '[2]'
both "IIF(N = ?, 1, 0)"                              "SELECT IIF(N = ?, 1, 0) AS X FROM T" '[4]'
both "IIF(NN = ?, 1, 0) - NOT NULL from NN"          "SELECT IIF(NN = ?, 1, 0) AS X FROM T" '[6]'
both "IIF(? = ID, 1, 0) - the ? on the left"         "SELECT IIF(? = ID, 1, 0) AS X FROM T" '[3]'
both "IIF(? = 1, 1, 0) - NOT NULL from the literal"  "SELECT IIF(? = 1, 1, 0) AS X FROM T" '[1]'
both "IIF(S = ?, 1, 0) - VARYING 10 NONE"            "SELECT IIF(S = ?, 1, 0) AS X FROM T" '["cd"]'
both "IIF(S = ?, 1, 0) bound past the width"         "SELECT IIF(S = ?, 1, 0) AS X FROM T" '["abcdefghijkl"]'
both "IIF(NM = ?, 1, 0) - LONG scale -2 subtype 1"   "SELECT IIF(NM = ?, 1, 0) AS X FROM T" '["7.25"]'
both "IIF(BI = ?, 1, 0) - INT64"                     "SELECT IIF(BI = ?, 1, 0) AS X FROM T" '[8]'
both "IIF(D > ?, 1, 0) - DOUBLE"                     "SELECT IIF(D > ?, 1, 0) AS X FROM T" '["2.0"]'
both "IIF(DT = ?, 1, 0) - DATE"                      "SELECT IIF(DT = ?, 1, 0) AS X FROM T" '["2024-02-10"]'
both "IIF(ID <> ?, 1, 0)"                            "SELECT IIF(ID <> ?, 1, 0) AS X FROM T" '[2]'
both "IIF(NOT ID = ?, 1, 0)"                         "SELECT IIF(NOT ID = ?, 1, 0) AS X FROM T" '[2]'
both "IIF(ID = ? OR N = ?, 1, 0)"                    "SELECT IIF(ID = ? OR N = ?, 1, 0) AS X FROM T" '[3,4]'
both "IIF(NN = ? OR ID = ?, 1, 0) - NOT NULL then Nullable" "SELECT IIF(NN = ? OR ID = ?, 1, 0) AS X FROM T" '[5,3]'
both "IIF(ID = ? AND ? = 1, 1, 0)"                   "SELECT IIF(ID = ? AND ? = 1, 1, 0) AS X FROM T" '[2,1]'
both "IIF(ID BETWEEN ? AND 2, 1, 0)"                 "SELECT IIF(ID BETWEEN ? AND 2, 1, 0) AS X FROM T" '[2]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): IIF(ID IN (?, 2), 1, 0)"                       "SELECT IIF(ID IN (?, 2), 1, 0) AS X FROM T" '[3]'
both "IIF(ID IN (?, ?), 1, 0)"                       "SELECT IIF(ID IN (?, ?), 1, 0) AS X FROM T" '[1,3]'
both "IIF(ID * ? = 2, 'y', 'n') - arithmetic under the condition" "SELECT IIF(ID * ? = 2, 'y', 'n') AS X FROM T" '[2]'
both "CASE WHEN ID * ? = 2 THEN 'y' ELSE 'n' END"    "SELECT CASE WHEN ID * ? = 2 THEN 'y' ELSE 'n' END AS X FROM T" '[1]'
both "CASE WHEN ID > ? + 1 THEN ID ELSE 0 END"       "SELECT CASE WHEN ID > ? + 1 THEN ID ELSE 0 END AS X FROM T" '[1]'
both "IIF(ID + 1 = ?, 1, 0) - INT64 from the computed side" "SELECT IIF(ID + 1 = ?, 1, 0) AS X FROM T" '[3]'
both "IIF(ID = ? + 1, 1, 0)"                         "SELECT IIF(ID = ? + 1, 1, 0) AS X FROM T" '[1]'
both "IIF(NN > ? + 1, 1, 0)"                         "SELECT IIF(NN > ? + 1, 1, 0) AS X FROM T" '[5]'
both "IIF(NM * ? = 2, 1, 0) - LONG scale 0 from the literal" "SELECT IIF(NM * ? = 2, 1, 0) AS X FROM T" '[2]'
both "IIF(ID * ? = NM, 1, 0)"                        "SELECT IIF(ID * ? = NM, 1, 0) AS X FROM T" '["7.25"]'
eng_only "R12 cap: K1: NUMBERING: a select-list condition's slot before the WHERE's"  "SELECT IIF(ID = ?, 7, 0) AS X FROM T WHERE N = ?" '[2,4]'
both "NUMBERING: the select list's before the ORDER BY's" \
     "SELECT IIF(ID = ?, 1, 0) AS X FROM T ORDER BY IIF(N = ?, 0, 1), ID" '[2,4]'
both "WHERE IIF(ID = ?, 1, 0) = 1"                   "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1" '[2]'
# a WHOLE-SIDE condition `?` compares the client's value whole - the
# first cut cast it into the slot and rounded '2.4' to the 2 row
both "WHERE IIF(ID = ?, 1, 0) = 1 ['2.4'] -> none"   "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1" '["2.4"]'
both "WHERE IIF(ID = ?, 1, 0) = 1 [2.4] (a DOUBLE message) -> none" "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1" '[2.4]'
both "WHERE IIF(ID > ?, 1, 0) = 1 ['1.5'] -> 2;3"    "SELECT ID FROM T WHERE IIF(ID > ?, 1, 0) = 1" '["1.5"]'
both "WHERE IIF(NM = ?, 1, 0) = 1 ['7.245'] -> none" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["7.245"]'
both "WHERE IIF(BI = ?, 1, 0) = 1 ['8.5'] -> none"   "SELECT ID FROM T WHERE IIF(BI = ?, 1, 0) = 1" '["8.5"]'
both "SELECT IIF(? = 2.5, 1, 0) ['2.45'] -> 0;0;0"   "SELECT IIF(? = 2.5, 1, 0) AS X FROM T" '["2.45"]'
both "SELECT IIF(ID = ?, 1, 0) ['2.4'] -> 0;0;0"     "SELECT IIF(ID = ?, 1, 0) AS X FROM T" '["2.4"]'
# (the simple CASE's output nullability is the pre-existing gap recorded below)
desc_differs "SELECT CASE ID WHEN ? THEN 1 ELSE 0 END ['2.4'] -> 0;0;0" "SELECT CASE ID WHEN ? THEN 1 ELSE 0 END AS X FROM T" '["2.4"]'
both "ORDER BY IIF(ID = ?, 0, 1) ['2.4'] -> 1;2;3"   "SELECT ID FROM T ORDER BY IIF(ID = ?, 0, 1), ID" '["2.4"]'
both "SUM(IIF(ID = ?, 1, 0)) ['2.4'] -> 0"           "SELECT SUM(IIF(ID = ?, 1, 0)) AS X FROM T" '["2.4"]'
eng_only "IIF(ID = ?, ?, 0) = 7 ['1.4', '6.5'] -> none (round 10: refuses - a comparison `?` the previous binary refused MIXED with an implicit integer cast over a `?` (plan_unmixed); the previous binary refuses it too)" "SELECT ID FROM T WHERE IIF(ID = ?, ?, 0) = 7" '["1.4","6.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): IIF(-? = ID, 1, 0) ['-2.5'] -> 0;0;0"          "SELECT IIF(-? = ID, 1, 0) AS X FROM T" '["-2.5"]'
boundary_err "R12 boundary: conversion error by design (K2): IIF(ID = ?, 1, 0) = 1 ['1 2'] -> none (the compare grammar reads 12, no raise)" "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1" '["1 2"]'
both_err "IIF(ID = ?, 1, 0) = 1 ['0x2'] - conversion error from string on both (prepared on both)" "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1" '["0x2"]'
both_err "IIF(S = ?, 1, 0) = 1 [2] - an integer against the TEXT slot converts the column and raises on both (prepared on both)" "SELECT ID FROM T WHERE IIF(S = ?, 1, 0) = 1" '[2]'
both "IIF(? = '2', 1, 0) [2] -> 1;1;1 (the literal converts)" "SELECT IIF(? = '2', 1, 0) AS X FROM T" '[2]'
both "WHERE CASE WHEN N > ? THEN 1 ELSE 0 END = 1"   "SELECT ID FROM T WHERE CASE WHEN N > ? THEN 1 ELSE 0 END = 1" '[3]'
both "ORDER BY IIF(ID = ?, 0, 1)"                    "SELECT ID FROM T ORDER BY IIF(ID = ?, 0, 1), ID" '[3]'
both "GROUP BY IIF(ID = ?, 1, 0)"                    "SELECT COUNT(*) AS C FROM T GROUP BY IIF(ID = ?, 1, 0)" '[2]'
both "SUM(IIF(ID = ?, 1, 0))"                        "SELECT SUM(IIF(ID = ?, 1, 0)) AS X FROM T" '[2]'
both "HAVING SUM(IIF(ID = ?, 1, 0)) > 0"             "SELECT N FROM T GROUP BY N HAVING SUM(IIF(ID = ?, 1, 0)) > 0" '[2]'
both "nested in COALESCE"                            "SELECT COALESCE(IIF(ID = ?, N, NULL), 0) AS X FROM T" '[1]'
# a CAST-typed ? in the condition: refused on c34c1c8 too, because
# resolve_raw_cond had no sink for ANY parameter, cast or not
both "IIF(ID = CAST(? AS INTEGER), 1, 0)"            "SELECT IIF(ID = CAST(? AS INTEGER), 1, 0) AS X FROM T" '[2]'
both "ORDER BY IIF(ID = CAST(? AS INTEGER), 0, 1)"   "SELECT ID FROM T ORDER BY IIF(ID = CAST(? AS INTEGER), 0, 1), ID" '[2]'
# a condition ? beside a numeric branch ? is refused at prepare (round 10:
# the branch's implicit cast would read a text the previous binary's way
# - `IIF(ID = ?, ?, N)` ['2', '4.999999999999'] answered 3;5;4 where the
# engine raises - in a statement the previous binary never planned)
eng_only "IIF(ID = ?, ?, 0) - a condition slot and a branch slot (round 10: refuses - a comparison `?` the previous binary refused MIXED with an implicit integer cast over a `?` (plan_unmixed); the previous binary refuses it too)" \
     "SELECT IIF(ID = ?, ?, 0) AS X FROM T" '[2,77]'
eng_only "IIF(NN = ?, ?, 0) - the same (round 10: refuses - a comparison `?` the previous binary refused MIXED with an implicit integer cast over a `?` (plan_unmixed); the previous binary refuses it too)"  "SELECT IIF(NN = ?, ?, 0) AS X FROM T" '[6,77]'
# PRE-EXISTING (identical on c34c1c8): a text-branch IIF's OUTPUT width
# is announced 32765 where the engine says the sibling column's 10
eng_only "R12 cap: K1: IIF(ID = ?, S, ?) - the text output width"        "SELECT IIF(ID = ?, S, ?) AS X FROM T" '[2,"zz"]'
# PRE-EXISTING (identical on c34c1c8, and with no parameter at all): the
# engine announces a simple CASE's output Nullable, this server NOT NULL
desc_differs "CASE ID WHEN ? THEN 1 ELSE 0 END - the simple CASE's output nullability" \
     "SELECT CASE ID WHEN ? THEN 1 ELSE 0 END AS X FROM T" '[3]'
# the two DML statements: the row is written by ONE statement and read
# back on both servers (RETURNING, or a SELECT after an INSERT)
both "UPDATE SET N = IIF(ID = ?, 99, N)"             "UPDATE T SET N = IIF(ID = ?, 99, N) WHERE ID = 1 RETURNING N" '[1]'
both "UPDATE SET N = IIF(NN = ?, 98, N) - NOT NULL slot" "UPDATE T SET N = IIF(NN = ?, 98, N) WHERE ID = 2 RETURNING N" '[6]'
both "UPDATE SET S = IIF(S = ?, 'hit', S)"           "UPDATE T SET S = IIF(S = ?, 'hit', S) WHERE ID = 1 RETURNING S" '["ab"]'
both "UPDATE WHERE IIF(ID = ?, 1, 0) = 1"            "UPDATE T SET N = 97 WHERE IIF(ID = ?, 1, 0) = 1 RETURNING N" '[3]'
both "UPDATE SET N = IIF(ID = ?, 99, N) ['2.4'] - no row changes" "UPDATE T SET N = IIF(ID = ?, 99, N) WHERE ID = 2 RETURNING N" '["2.4"]'
both "UPDATE WHERE NM = ? * ID ['7.25'] - no row (the LEFT rounds)" "UPDATE T SET N = 94 WHERE NM = ? * ID RETURNING N" '["7.25"]'
dml_rb_eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): DELETE WHERE -? = ID ['-2.4'] - no row (rolled back: a binary that takes row 2 cannot pollute the cells after it)" "DELETE FROM T WHERE -? = ID RETURNING ID" '["-2.4"]'
both "UPDATE WHERE ID * ? = 2"                       "UPDATE T SET N = 96 WHERE ID * ? = 2 RETURNING N" '[2]'
both "UPDATE SET N = IIF(ID * ? = 3, 95, N)"         "UPDATE T SET N = IIF(ID * ? = 3, 95, N) WHERE ID = 3 RETURNING N" '[1]'
both "a NULL bound into the condition - the ELSE branch" "UPDATE T SET N = IIF(N = ?, 55, N) WHERE ID = 2 RETURNING N" '[null]'
write "INSERT VALUES (.., IIF(? = 1, 5, 6)) bound 1" "INSERT INTO T (ID, NN, N) VALUES (10, 1, IIF(? = 1, 5, 6))" '[1]'
both  "..reads back 5"                               "SELECT N FROM T WHERE ID = 10"
write "INSERT VALUES (.., IIF(? = 1, 5, 6)) bound 2" "INSERT INTO T (ID, NN, N) VALUES (11, 1, IIF(? = 1, 5, 6))" '[2]'
both  "..reads back 6"                               "SELECT N FROM T WHERE ID = 11"
write "INSERT VALUES (.., CASE WHEN ? > 1 THEN 5 ELSE 6 END)" "INSERT INTO T (ID, NN, N) VALUES (12, 1, CASE WHEN ? > 1 THEN 5 ELSE 6 END)" '[2]'
both  "..reads back 5"                               "SELECT N FROM T WHERE ID = 12"
both "DELETE WHERE IIF(ID = ?, 1, 0) = 1"            "DELETE FROM T WHERE IIF(ID = ?, 1, 0) = 1 RETURNING ID" '[12]'
both_refuse "INSERT VALUES (.., IIF(ID = ?, 5, 6)) - no column in a VALUES list (-206)" \
     "INSERT INTO T (ID, NN, N) VALUES (13, 1, IIF(ID = ?, 5, 6))" '[1]'
reset_rows
both "the fixture rows are back on both servers"     "SELECT ID, NM, N, BI, S, D, DT, NN FROM T ORDER BY ID"

echo "-- 4. VALUES (L6): what a text bind becomes in the described slot --"
both "ID * ? = 6.0 ['2.5'] - INT64 right operand ROUNDS to 3 -> 2"  "SELECT ID FROM T WHERE ID * ? = 6.0" '["2.5"]'
both "ID * ? = 3.0 ['2.5'] -> 1"                     "SELECT ID FROM T WHERE ID * ? = 3.0" '["2.5"]'
both "ID * ? = 2.0 ['1.5'] -> 1 (rounds to 2)"       "SELECT ID FROM T WHERE ID * ? = 2.0" '["1.5"]'
both "ID * ? = 4.0 ['1.5'] -> 2"                     "SELECT ID FROM T WHERE ID * ? = 4.0" '["1.5"]'
both "ID * ? = 2.5 ['2.5'] -> none"                  "SELECT ID FROM T WHERE ID * ? = 2.5" '["2.5"]'
both "ID * ? = -3.0 ['-2.5'] -> 1 (half away from zero)" "SELECT ID FROM T WHERE ID * ? = -3.0" '["-2.5"]'
both "ID * ? = 0.0 ['0.4'] -> every row"             "SELECT ID FROM T WHERE ID * ? = 0.0" '["0.4"]'
both "NM * ? = 21.75 ['2.5'] -> 1 (7.25 * 3)"        "SELECT ID FROM T WHERE NM * ? = 21.75" '["2.5"]'
both "NM * ? = 3.625 ['0.5'] -> none (rounds to 1)"  "SELECT ID FROM T WHERE NM * ? = 3.625" '["0.5"]'
both "? * NM = 3.625 ['0.5'] -> 1 (INT64 slot: the LEFT operand keeps the fraction)" "SELECT ID FROM T WHERE ? * NM = 3.625" '["0.5"]'
both "? * 2 = 2.4 ['1.2'] -> every row"              "SELECT ID FROM T WHERE ? * 2 = 2.4" '["1.2"]'
both "ID * ? = CAST(2.5 AS NUMERIC(9,1)) ['2.5'] -> 1 (LONG slot, LONG sibling: the RIGHT keeps)"  "SELECT ID FROM T WHERE ID * ? = CAST(2.5 AS NUMERIC(9,1))" '["2.5"]'
both "ID * ? = CAST(2.5 AS NUMERIC(4,1)) ['2.5'] -> 1 (SHORT slot, LONG sibling: the RIGHT keeps)" "SELECT ID FROM T WHERE ID * ? = CAST(2.5 AS NUMERIC(4,1))" '["2.5"]'
both "ID * ? = CAST(2.5 AS NUMERIC(18,1)) ['2.5'] -> none (an INT64 slot rounds the RIGHT)" "SELECT ID FROM T WHERE ID * ? = CAST(2.5 AS NUMERIC(18,1))" '["2.5"]'
both "ID * ? = NM ['7.25'] -> 1"                     "SELECT ID FROM T WHERE ID * ? = NM" '["7.25"]'
both "2 * ? = NM ['1.25'] -> 3"                      "SELECT ID FROM T WHERE 2 * ? = NM" '["1.25"]'
# THE SIDE RULE: under a SHORT/LONG slot beside a SHORT/LONG sibling the
# LEFT operand is the rounded one (the first cut kept it and answered 1 /
# 2 / 3 for the first three)
both "NM = ? * ID ['7.25'] -> none (the LEFT rounds to 7)" "SELECT ID FROM T WHERE NM = ? * ID" '["7.25"]'
both "NM = ? * ID ['0.5'] -> none (rounds to 1)"     "SELECT ID FROM T WHERE NM = ? * ID" '["0.5"]'
both "NM = ? * 2 ['1.25'] -> none"                   "SELECT ID FROM T WHERE NM = ? * 2" '["1.25"]'
both "? * ID = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] -> 3 (rounds to 3)" "SELECT ID FROM T WHERE ? * ID = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
both "? * ID = CAST(9.0 AS NUMERIC(4,1)) ['2.5'] -> 3 (a SHORT slot too)" "SELECT ID FROM T WHERE ? * ID = CAST(9.0 AS NUMERIC(4,1))" '["2.5"]'
both "? * 2 = CAST(6.0 AS NUMERIC(9,1)) ['2.5'] -> every row" "SELECT ID FROM T WHERE ? * 2 = CAST(6.0 AS NUMERIC(9,1))" '["2.5"]'
both "? * NM = CAST(7.25 AS NUMERIC(9,3)) ['0.5'] -> 1 (rounds to 1)" "SELECT ID FROM T WHERE ? * NM = CAST(7.25 AS NUMERIC(9,3))" '["0.5"]'
both "CAST(ID AS SMALLINT) * ? = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> 3 (the RIGHT keeps)" "SELECT ID FROM T WHERE CAST(ID AS SMALLINT) * ? = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
# ...and beside an INT64 SIBLING the RIGHT one rounds, the LEFT keeps
both "BI * ? = CAST(27.0 AS NUMERIC(9,1)) ['2.5'] -> 1 (BI is INT64: the RIGHT rounds)" "SELECT ID FROM T WHERE BI * ? = CAST(27.0 AS NUMERIC(9,1))" '["2.5"]'
both "BI * ? = CAST(22.5 AS NUMERIC(9,1)) ['2.5'] -> none" "SELECT ID FROM T WHERE BI * ? = CAST(22.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: (ID + 0) * ? = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] -> 3 (arithmetic widens to INT64)" "SELECT ID FROM T WHERE (ID + 0) * ? = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
both "CAST(ID AS BIGINT) * ? = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> none" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
both "BI * ? = CAST(27.0 AS NUMERIC(4,1)) ['2.5'] -> 1 (a SHORT slot)" "SELECT ID FROM T WHERE BI * ? = CAST(27.0 AS NUMERIC(4,1))" '["2.5"]'
both "? * BI = CAST(22.5 AS NUMERIC(9,1)) ['2.5'] -> 1 (the LEFT keeps)" "SELECT ID FROM T WHERE ? * BI = CAST(22.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: ? * (ID + 0) = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> 3" "SELECT ID FROM T WHERE ? * (ID + 0) = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
# a direct ? sibling counts as the slot's own width
both "? * ? = NM ['2.5', '1'] -> none (LONG: the LEFT rounds)" "SELECT ID FROM T WHERE ? * ? = NM" '["2.5","1"]'
both "? * ? = NM ['1', '2.5'] -> 3"                  "SELECT ID FROM T WHERE ? * ? = NM" '["1","2.5"]'
both "? * ? = 2.5 ['2.5', '1.4'] -> every row (INT64: the RIGHT rounds)" "SELECT ID FROM T WHERE ? * ? = 2.5" '["2.5","1.4"]'
both "? * ? = 2.5 ['1', '2.5'] -> none"              "SELECT ID FROM T WHERE ? * ? = 2.5" '["1","2.5"]'
both "? / ? = 2.5 ['2.5', '1.4'] -> every row (the divisor rounds)" "SELECT ID FROM T WHERE ? / ? = 2.5" '["2.5","1.4"]'
both "IIF(NM = ? * ID, 1, 0) ['7.25'] -> 0;0;0 (the same rule in a condition)" "SELECT IIF(NM = ? * ID, 1, 0) AS X FROM T" '["7.25"]'
both "ID / ? = 0.5 ['1.6'] -> 1 (a divisor rounds to 2)" "SELECT ID FROM T WHERE ID / ? = 0.5" '["1.6"]'
both "ID / ? = 0.5 ['1.4'] -> none (rounds to 1)"    "SELECT ID FROM T WHERE ID / ? = 0.5" '["1.4"]'
both "ID / ? = CAST(0.5 AS NUMERIC(9,1)) ['1.6'] -> 1 (a LONG divisor rounds too)" "SELECT ID FROM T WHERE ID / ? = CAST(0.5 AS NUMERIC(9,1))" '["1.6"]'
both "ID / ? = CAST(0.5 AS NUMERIC(9,1)) ['1.4'] -> none" "SELECT ID FROM T WHERE ID / ? = CAST(0.5 AS NUMERIC(9,1))" '["1.4"]'
both_refuse "ID / ? = 2.5 ['0.4'] - the divisor rounds to 0: divide by zero at execute on both" \
     "SELECT ID FROM T WHERE ID / ? = 2.5" '["0.4"]'
both "? / ID = 0.5 ['0.5'] -> 1 (a dividend keeps the fraction)" "SELECT ID FROM T WHERE ? / ID = 0.5" '["0.5"]'
eng_only "R12 cap: K3: ID * ? = D ['1.5'] -> 1 (a DOUBLE slot keeps it)" "SELECT ID FROM T WHERE ID * ? = D" '["1.5"]'
eng_only "R12 cap: K3: ID * ? = 1E0 ['0.5'] -> 2"                     "SELECT ID FROM T WHERE ID * ? = 1E0" '["0.5"]'
eng_only "R12 cap: K3: D * ? = 3 ['1.2'] -> 2 (a LONG slot beside a DOUBLE column)" "SELECT ID FROM T WHERE D * ? = 3" '["1.2"]'
both "NM + ? = 8.25 ['5.75'] -> 3 (+ keeps the scale)" "SELECT ID FROM T WHERE NM + ? = 8.25" '["5.75"]'
both "ID + ? = 2.5 ['1.5'] -> 1"                     "SELECT ID FROM T WHERE ID + ? = 2.5" '["1.5"]'
both "ID - ? = 0.5 ['0.5'] -> 1"                     "SELECT ID FROM T WHERE ID - ? = 0.5" '["0.5"]'
both "ID = 2.5 + ? ['-0.5'] -> 2 (a LONG slot from ID)" "SELECT ID FROM T WHERE ID = 2.5 + ?" '["-0.5"]'
both "ID + ? = 3 ['1.9'] -> 1 (a LONG slot rounds the text bind to 2)" "SELECT ID FROM T WHERE ID + ? = 3" '["1.9"]'
both "ID * ? = 2 ['2.5'] -> none"                    "SELECT ID FROM T WHERE ID * ? = 2" '["2.5"]'
both "ID * ? = 2 bound NULL into a NOT NULL slot -> none" "SELECT ID FROM T WHERE ID * ? = 2" '[null]'
both "ID * ? = 2 bound 1 -> 2"                       "SELECT ID FROM T WHERE ID * ? = 2" '[1]'


echo "-- 4b. THE \`*\` SIDE MATRIX: slot x sibling x side x {hit, miss} (every bind a fraction) --"
# Every cell below was measured on the engine; 'hit' is the target the
# engine's reading of the `?` reaches (a row), 'miss' is the target the
# OTHER reading would reach (none) - a rounding on the wrong side answers
# the miss cell and empties the hit cell. The first cut of this chunk did
# exactly that in the 24 LONG/SHORT cells marked (!).
# an INT64 slot (a decimal literal): the RIGHT operand rounds whatever the sibling
both "INT64 slot, sib ID, ? left KEEPS: ? * ID = 7.5 ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE ? * ID = 7.5" '["2.5"]'
both "INT64 slot, sib ID, ? left KEEPS: ? * ID = 9.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * ID = 9.0" '["2.5"]'
both "INT64 slot, sib ID, ? right ROUNDS: ID * ? = 9.0 ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE ID * ? = 9.0" '["2.5"]'
both "INT64 slot, sib ID, ? right ROUNDS: ID * ? = 7.5 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ID * ? = 7.5" '["2.5"]'
both "INT64 slot, sib BI, ? left KEEPS: ? * BI = 22.5 ['2.5'] -> 1 (hit)" "SELECT ID FROM T WHERE ? * BI = 22.5" '["2.5"]'
both "INT64 slot, sib BI, ? left KEEPS: ? * BI = 27.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * BI = 27.0" '["2.5"]'
both "INT64 slot, sib BI, ? right ROUNDS: BI * ? = 27.0 ['2.5'] -> 1 (hit)" "SELECT ID FROM T WHERE BI * ? = 27.0" '["2.5"]'
both "INT64 slot, sib BI, ? right ROUNDS: BI * ? = 22.5 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE BI * ? = 22.5" '["2.5"]'
both "INT64 slot, sib 2, ? left KEEPS: ? * 2 = 5.0 ['2.5'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE ? * 2 = 5.0" '["2.5"]'
both "INT64 slot, sib 2, ? left KEEPS: ? * 2 = 6.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * 2 = 6.0" '["2.5"]'
both "INT64 slot, sib 2, ? right ROUNDS: 2 * ? = 6.0 ['2.5'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE 2 * ? = 6.0" '["2.5"]'
both "INT64 slot, sib 2, ? right ROUNDS: 2 * ? = 5.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE 2 * ? = 5.0" '["2.5"]'
both "INT64 slot, sib CAST(ID AS BIGINT), ? left KEEPS: ? * CAST(ID AS BIGINT) = 7.5 ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE ? * CAST(ID AS BIGINT) = 7.5" '["2.5"]'
both "INT64 slot, sib CAST(ID AS BIGINT), ? left KEEPS: ? * CAST(ID AS BIGINT) = 9.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * CAST(ID AS BIGINT) = 9.0" '["2.5"]'
both "INT64 slot, sib CAST(ID AS BIGINT), ? right ROUNDS: CAST(ID AS BIGINT) * ? = 9.0 ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = 9.0" '["2.5"]'
both "INT64 slot, sib CAST(ID AS BIGINT), ? right ROUNDS: CAST(ID AS BIGINT) * ? = 7.5 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = 7.5" '["2.5"]'
both "INT64 slot, sib COUNT(*), ? left KEEPS: HAVING ? * COUNT(*) = 5.0 ['2.5'] -> 4 (hit)" "SELECT N FROM T GROUP BY N HAVING ? * COUNT(*) = 5.0" '["2.5"]'
both "INT64 slot, sib COUNT(*), ? left KEEPS: HAVING ? * COUNT(*) = 6.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT N FROM T GROUP BY N HAVING ? * COUNT(*) = 6.0" '["2.5"]'
both "INT64 slot, sib COUNT(*), ? right ROUNDS: HAVING COUNT(*) * ? = 6.0 ['2.5'] -> 4 (hit)" "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? = 6.0" '["2.5"]'
both "INT64 slot, sib COUNT(*), ? right ROUNDS: HAVING COUNT(*) * ? = 5.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? = 5.0" '["2.5"]'
both "INT64 slot, sib 5000000000, ? left KEEPS: ? * 5000000000 = 12500000000.0 ['2.5'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE ? * 5000000000 = 12500000000.0" '["2.5"]'
both "INT64 slot, sib 5000000000, ? left KEEPS: ? * 5000000000 = 15000000000.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * 5000000000 = 15000000000.0" '["2.5"]'
both "INT64 slot, sib 5000000000, ? right ROUNDS: 5000000000 * ? = 15000000000.0 ['2.5'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE 5000000000 * ? = 15000000000.0" '["2.5"]'
both "INT64 slot, sib 5000000000, ? right ROUNDS: 5000000000 * ? = 12500000000.0 ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE 5000000000 * ? = 12500000000.0" '["2.5"]'
# a LONG slot (NUMERIC(9,1)): the LEFT rounds beside a 4-byte sibling (ID, 2), the RIGHT beside an 8-byte one
both "LONG slot, sib ID, ? left ROUNDS: ? * ID = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] -> 3 (hit) (!)" "SELECT ID FROM T WHERE ? * ID = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib ID, ? left ROUNDS: ? * ID = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE ? * ID = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib ID, ? right KEEPS: ID * ? = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE ID * ? = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib ID, ? right KEEPS: ID * ? = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ID * ? = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib BI, ? left KEEPS: ? * BI = CAST(22.5 AS NUMERIC(9,1)) ['2.5'] -> 1 (hit)" "SELECT ID FROM T WHERE ? * BI = CAST(22.5 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib BI, ? left KEEPS: ? * BI = CAST(27.0 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * BI = CAST(27.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib BI, ? right ROUNDS: BI * ? = CAST(27.0 AS NUMERIC(9,1)) ['2.5'] -> 1 (hit) (!)" "SELECT ID FROM T WHERE BI * ? = CAST(27.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib BI, ? right ROUNDS: BI * ? = CAST(22.5 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE BI * ? = CAST(22.5 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib 2, ? left ROUNDS: ? * 2 = CAST(6.0 AS NUMERIC(9,1)) ['2.5'] -> 1;2;3 (hit) (!)" "SELECT ID FROM T WHERE ? * 2 = CAST(6.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib 2, ? left ROUNDS: ? * 2 = CAST(5.0 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE ? * 2 = CAST(5.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib 2, ? right KEEPS: 2 * ? = CAST(5.0 AS NUMERIC(9,1)) ['2.5'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE 2 * ? = CAST(5.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib 2, ? right KEEPS: 2 * ? = CAST(6.0 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE 2 * ? = CAST(6.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib CAST(ID AS BIGINT), ? left KEEPS: ? * CAST(ID AS BIGINT) = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE ? * CAST(ID AS BIGINT) = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib CAST(ID AS BIGINT), ? left KEEPS: ? * CAST(ID AS BIGINT) = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * CAST(ID AS BIGINT) = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib CAST(ID AS BIGINT), ? right ROUNDS: CAST(ID AS BIGINT) * ? = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] -> 3 (hit) (!)" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib CAST(ID AS BIGINT), ? right ROUNDS: CAST(ID AS BIGINT) * ? = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib COUNT(*), ? left KEEPS: HAVING ? * COUNT(*) = CAST(5.0 AS NUMERIC(9,1)) ['2.5'] -> 4 (hit)" "SELECT N FROM T GROUP BY N HAVING ? * COUNT(*) = CAST(5.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib COUNT(*), ? left KEEPS: HAVING ? * COUNT(*) = CAST(6.0 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT N FROM T GROUP BY N HAVING ? * COUNT(*) = CAST(6.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib COUNT(*), ? right ROUNDS: HAVING COUNT(*) * ? = CAST(6.0 AS NUMERIC(9,1)) ['2.5'] -> 4 (hit) (!)" "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? = CAST(6.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib COUNT(*), ? right ROUNDS: HAVING COUNT(*) * ? = CAST(5.0 AS NUMERIC(9,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? = CAST(5.0 AS NUMERIC(9,1))" '["2.5"]'
both "LONG slot, sib 5000000000, ? left KEEPS: ? * 5000000000 > CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE ? * 5000000000 > CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "LONG slot, sib 5000000000, ? left KEEPS: ? * 5000000000 = CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * 5000000000 = CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "LONG slot, sib 5000000000, ? right ROUNDS: 5000000000 * ? = CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> 1;2;3 (hit) (!)" "SELECT ID FROM T WHERE 5000000000 * ? = CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "LONG slot, sib 5000000000, ? right ROUNDS: 5000000000 * ? > CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE 5000000000 * ? > CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
# a SHORT slot (NUMERIC(4,1)): the same side rule as LONG
both "SHORT slot, sib ID, ? left ROUNDS: ? * ID = CAST(9.0 AS NUMERIC(4,1)) ['2.5'] -> 3 (hit) (!)" "SELECT ID FROM T WHERE ? * ID = CAST(9.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib ID, ? left ROUNDS: ? * ID = CAST(7.5 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE ? * ID = CAST(7.5 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib ID, ? right KEEPS: ID * ? = CAST(7.5 AS NUMERIC(4,1)) ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE ID * ? = CAST(7.5 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib ID, ? right KEEPS: ID * ? = CAST(9.0 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ID * ? = CAST(9.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib BI, ? left KEEPS: ? * BI = CAST(22.5 AS NUMERIC(4,1)) ['2.5'] -> 1 (hit)" "SELECT ID FROM T WHERE ? * BI = CAST(22.5 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib BI, ? left KEEPS: ? * BI = CAST(27.0 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * BI = CAST(27.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib BI, ? right ROUNDS: BI * ? = CAST(27.0 AS NUMERIC(4,1)) ['2.5'] -> 1 (hit) (!)" "SELECT ID FROM T WHERE BI * ? = CAST(27.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib BI, ? right ROUNDS: BI * ? = CAST(22.5 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE BI * ? = CAST(22.5 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib 2, ? left ROUNDS: ? * 2 = CAST(6.0 AS NUMERIC(4,1)) ['2.5'] -> 1;2;3 (hit) (!)" "SELECT ID FROM T WHERE ? * 2 = CAST(6.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib 2, ? left ROUNDS: ? * 2 = CAST(5.0 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE ? * 2 = CAST(5.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib 2, ? right KEEPS: 2 * ? = CAST(5.0 AS NUMERIC(4,1)) ['2.5'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE 2 * ? = CAST(5.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib 2, ? right KEEPS: 2 * ? = CAST(6.0 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE 2 * ? = CAST(6.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib CAST(ID AS BIGINT), ? left KEEPS: ? * CAST(ID AS BIGINT) = CAST(7.5 AS NUMERIC(4,1)) ['2.5'] -> 3 (hit)" "SELECT ID FROM T WHERE ? * CAST(ID AS BIGINT) = CAST(7.5 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib CAST(ID AS BIGINT), ? left KEEPS: ? * CAST(ID AS BIGINT) = CAST(9.0 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * CAST(ID AS BIGINT) = CAST(9.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib CAST(ID AS BIGINT), ? right ROUNDS: CAST(ID AS BIGINT) * ? = CAST(9.0 AS NUMERIC(4,1)) ['2.5'] -> 3 (hit) (!)" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = CAST(9.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib CAST(ID AS BIGINT), ? right ROUNDS: CAST(ID AS BIGINT) * ? = CAST(7.5 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = CAST(7.5 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib COUNT(*), ? left KEEPS: HAVING ? * COUNT(*) = CAST(5.0 AS NUMERIC(4,1)) ['2.5'] -> 4 (hit)" "SELECT N FROM T GROUP BY N HAVING ? * COUNT(*) = CAST(5.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib COUNT(*), ? left KEEPS: HAVING ? * COUNT(*) = CAST(6.0 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target)" "SELECT N FROM T GROUP BY N HAVING ? * COUNT(*) = CAST(6.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib COUNT(*), ? right ROUNDS: HAVING COUNT(*) * ? = CAST(6.0 AS NUMERIC(4,1)) ['2.5'] -> 4 (hit) (!)" "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? = CAST(6.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib COUNT(*), ? right ROUNDS: HAVING COUNT(*) * ? = CAST(5.0 AS NUMERIC(4,1)) ['2.5'] -> (none) (miss: the other reading's target) (!)" "SELECT N FROM T GROUP BY N HAVING COUNT(*) * ? = CAST(5.0 AS NUMERIC(4,1))" '["2.5"]'
both "SHORT slot, sib 5000000000, ? left KEEPS: ? * 5000000000 > CAST(0.0 AS NUMERIC(4,1)) ['0.4'] -> 1;2;3 (hit)" "SELECT ID FROM T WHERE ? * 5000000000 > CAST(0.0 AS NUMERIC(4,1))" '["0.4"]'
both "SHORT slot, sib 5000000000, ? left KEEPS: ? * 5000000000 = CAST(0.0 AS NUMERIC(4,1)) ['0.4'] -> (none) (miss: the other reading's target)" "SELECT ID FROM T WHERE ? * 5000000000 = CAST(0.0 AS NUMERIC(4,1))" '["0.4"]'
both "SHORT slot, sib 5000000000, ? right ROUNDS: 5000000000 * ? = CAST(0.0 AS NUMERIC(4,1)) ['0.4'] -> 1;2;3 (hit) (!)" "SELECT ID FROM T WHERE 5000000000 * ? = CAST(0.0 AS NUMERIC(4,1))" '["0.4"]'
both "SHORT slot, sib 5000000000, ? right ROUNDS: 5000000000 * ? > CAST(0.0 AS NUMERIC(4,1)) ['0.4'] -> (none) (miss: the other reading's target) (!)" "SELECT ID FROM T WHERE 5000000000 * ? > CAST(0.0 AS NUMERIC(4,1))" '["0.4"]'

echo "-- 4c. A WHOLE-SIDE bare ? in a condition keeps the client's value: every clause, fractional binds --"
# (rounded into the slot, each of these is a different answer - shown in the label)
both "select list IIF(ID > ?, 1, 0) ['1.5'] -> 0;1;1 (rounded to 2: 0;0;1)" "SELECT IIF(ID > ?, 1, 0) AS X FROM T" '["1.5"]'
both "select list IIF(? < ID, 1, 0) ['1.5'] -> 0;1;1 (the ? on the left)" "SELECT IIF(? < ID, 1, 0) AS X FROM T" '["1.5"]'
both "select list CASE WHEN ID = ? ['2.4'] -> 0;0;0 (rounded: 0;1;0)" "SELECT CASE WHEN ID = ? THEN 1 ELSE 0 END AS X FROM T" '["2.4"]'
both "select list CASE WHEN ID > ? ['1.5'] -> 0;1;1" "SELECT CASE WHEN ID > ? THEN 1 ELSE 0 END AS X FROM T" '["1.5"]'
both "select list IIF(NN = ?, 1, 0) ['5.5'] -> 0;0;0 (a NOT NULL slot; rounded to 6: 0;1;0)" "SELECT IIF(NN = ?, 1, 0) AS X FROM T" '["5.5"]'
both "select list IIF(? = 2, 1, 0) ['1.5'] -> 0;0;0 (a literal slot; rounded: 1;1;1)" "SELECT IIF(? = 2, 1, 0) AS X FROM T" '["1.5"]'
both "select list IIF(? = CAST(2.5 AS NUMERIC(9,1)), 1, 0) ['2.45'] -> 0;0;0 (LONG -1; rounded to 2.5: 1;1;1)" "SELECT IIF(? = CAST(2.5 AS NUMERIC(9,1)), 1, 0) AS X FROM T" '["2.45"]'
both "select list IIF(NM = ?, 1, 0) ['7.245'] -> 0;0;0 (LONG -2; rounded to 7.25: 1;0;0)" "SELECT IIF(NM = ?, 1, 0) AS X FROM T" '["7.245"]'
both "select list IIF(BI = ?, 1, 0) ['8.5'] -> 0;0;0 (INT64; rounded to 9: 1;0;0)" "SELECT IIF(BI = ?, 1, 0) AS X FROM T" '["8.5"]'
both "WHERE IIF(ID > ?, 1, 0) = 1 ['2.5'] -> 3 (rounded to 3: none)" "SELECT ID FROM T WHERE IIF(ID > ?, 1, 0) = 1" '["2.5"]'
both "WHERE IIF(ID = ?, 1, 0) = 1 ['2.5'] -> none (rounded to 3: 3)" "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1" '["2.5"]'
both "WHERE IIF(NN = ?, 1, 0) = 1 ['5.5'] -> none (rounded: 2)" "SELECT ID FROM T WHERE IIF(NN = ?, 1, 0) = 1" '["5.5"]'
both "WHERE IIF(? = 2, 1, 0) = 1 ['2.4'] -> none (rounded: every row)" "SELECT ID FROM T WHERE IIF(? = 2, 1, 0) = 1" '["2.4"]'
both "WHERE IIF(? = 2.5, 1, 0) = 1 ['2.45'] -> none (rounded: every row)" "SELECT ID FROM T WHERE IIF(? = 2.5, 1, 0) = 1" '["2.45"]'
both "WHERE CASE WHEN ID > ? .. = 1 ['1.5'] -> 2;3 (rounded: 3)" "SELECT ID FROM T WHERE CASE WHEN ID > ? THEN 1 ELSE 0 END = 1" '["1.5"]'
both "WHERE two conditions ['1.5', '2.5'] -> 2 (rounded: none)" "SELECT ID FROM T WHERE IIF(ID > ?, 1, 0) = 1 AND IIF(ID < ?, 1, 0) = 1" '["1.5","2.5"]'
both "ORDER BY IIF(ID > ?, 0, 1) ['1.5'] -> 2;3;1 (rounded: 3;1;2)" "SELECT ID FROM T ORDER BY IIF(ID > ?, 0, 1), ID" '["1.5"]'
both "ORDER BY CASE WHEN ID = ? ['2.4'] -> 3;2;1 (rounded: 2;3;1)" "SELECT ID FROM T ORDER BY CASE WHEN ID = ? THEN 0 ELSE 1 END, ID DESC" '["2.4"]'
both "GROUP BY IIF(ID = ?, 1, 0) ['2.4'] -> one group of 3 (rounded: 2;1)" "SELECT COUNT(*) AS C FROM T GROUP BY IIF(ID = ?, 1, 0)" '["2.4"]'
both "SUM(IIF(ID > ?, 1, 0)) ['1.5'] -> 2 (rounded: 1)" "SELECT SUM(IIF(ID > ?, 1, 0)) AS X FROM T" '["1.5"]'
both "HAVING SUM(IIF(ID = ?, 1, 0)) > 0 ['2.4'] -> none (rounded: 4)" "SELECT N FROM T GROUP BY N HAVING SUM(IIF(ID = ?, 1, 0)) > 0" '["2.4"]'
both "HAVING SUM(IIF(ID > ?, 1, 0)) = 2 ['1.5'] -> 4 (rounded: none)" "SELECT N FROM T GROUP BY N HAVING SUM(IIF(ID > ?, 1, 0)) = 2" '["1.5"]'
both "HAVING IIF(SUM(ID) = ?, 1, 0) = 1 ['4.5'] -> none (rounded to 5: 4)" "SELECT N FROM T GROUP BY N HAVING IIF(SUM(ID) = ?, 1, 0) = 1" '["4.5"]'
both "HAVING IIF(SUM(ID) > ?, 1, 0) = 1 ['4.5'] -> 4 (rounded to 5: none)" "SELECT N FROM T GROUP BY N HAVING IIF(SUM(ID) > ?, 1, 0) = 1" '["4.5"]'
both "derived table IIF(ID > ?, 1, 0) AS F .. WHERE F = 1 ['1.5'] -> 2;3 (rounded: 3)" "SELECT ID FROM (SELECT ID, IIF(ID > ?, 1, 0) AS F FROM T) d WHERE d.F = 1" '["1.5"]'
# the execute-time conversion errors: both PREPARE, both RAISE
both_err "select list IIF(ID = ?, 1, 0) ['abc'] - conversion error on both" "SELECT IIF(ID = ?, 1, 0) AS X FROM T" '["abc"]'
both_err "select list IIF(S = ?, 1, 0) [2] - the integer converts the TEXT column and raises" "SELECT IIF(S = ?, 1, 0) AS X FROM T" '[2]'
both_err "ORDER BY IIF(ID = ?, 0, 1) ['1e'] - conversion error on both" "SELECT ID FROM T ORDER BY IIF(ID = ?, 0, 1)" '["1e"]'
both_err "WHERE IIF(NM = ?, 1, 0) = 1 ['x.5'] - a NUMERIC slot, conversion error on both" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["x.5"]'
both_err "CONTROL: the classic bare ID = ? ['0x2'] raises the same way" "SELECT ID FROM T WHERE ID = ?" '["0x2"]'
# DML in a rolled-back transaction with a read-back (the fixture survives
# whatever a wrong binary would have written)
dml_rb "UPDATE SET N = IIF(ID > ?, 99, N) WHERE ID = 2 ['1.5'] -> 99 (rounded to 2: 4)" "UPDATE T SET N = IIF(ID > ?, 99, N) WHERE ID = 2 RETURNING N" '["1.5"]'
dml_rb "UPDATE SET N = IIF(ID = ?, 98, N) WHERE ID = 3 ['2.5'] -> 4 (rounded to 3: 98)" "UPDATE T SET N = IIF(ID = ?, 98, N) WHERE ID = 3 RETURNING N" '["2.5"]'
dml_rb "UPDATE WHERE IIF(ID = ?, 1, 0) = 1 ['2.4'] -> no row (rounded: row 2)" "UPDATE T SET N = 97 WHERE IIF(ID = ?, 1, 0) = 1 RETURNING N" '["2.4"]'
dml_rb "UPDATE WHERE IIF(ID > ?, 1, 0) = 1 AND ID = 2 ['1.5'] -> 96 (rounded: no row)" "UPDATE T SET N = 96 WHERE IIF(ID > ?, 1, 0) = 1 AND ID = 2 RETURNING N" '["1.5"]'
dml_rb "DELETE WHERE IIF(ID = ?, 1, 0) = 1 ['2.4'] -> no row (rounded: row 2 gone)" "DELETE FROM T WHERE IIF(ID = ?, 1, 0) = 1 RETURNING ID" '["2.4"]'
dml_rb "DELETE WHERE IIF(ID > ?, 1, 0) = 1 ['1.5'] -> rows 2 and 3 go, read-back 1 (rounded: only 3)" "DELETE FROM T WHERE IIF(ID > ?, 1, 0) = 1 RETURNING ID" '["1.5"]'
both "the fixture rows survived the rolled-back DML on both servers" "SELECT ID, N FROM T ORDER BY ID"

echo "-- 4d. -? AS A WHOLE SIDE keeps the client's value (a negated text is a DOUBLE) --"
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = 2 ['-2.4'] -> none (rounded: every row)" "SELECT ID FROM T WHERE -? = 2" '["-2.4"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = 2.5 ['-2.45'] -> none (INT64 -1 slot; rounded: every row)" "SELECT ID FROM T WHERE -? = 2.5" '["-2.45"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = BI ['-8.4'] -> none" "SELECT ID FROM T WHERE -? = BI" '["-8.4"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = NN ['-5.5'] -> none (a NOT NULL slot; rounded to 6: 2)" "SELECT ID FROM T WHERE -? = NN" '["-5.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = CAST(2 AS SMALLINT) ['-2.4'] -> none (a SHORT slot; rounded: every row)" "SELECT ID FROM T WHERE -? = CAST(2 AS SMALLINT)" '["-2.4"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): ID = -(?) ['-2.4'] -> none" "SELECT ID FROM T WHERE ID = -(?)" '["-2.4"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): ID > -? ['-1.5'] -> 2;3 (rounded to 2: 3)" "SELECT ID FROM T WHERE ID > -?" '["-1.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? < ID ['-1.5'] -> 2;3" "SELECT ID FROM T WHERE -? < ID" '["-1.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = 12345678901 ['-12345678901.4'] -> none (an INT64 literal slot; rounded: every row)" "SELECT ID FROM T WHERE -? = 12345678901" '["-12345678901.4"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): WHERE IIF(-? = ID, 1, 0) = 1 ['-2.4'] -> none" "SELECT ID FROM T WHERE IIF(-? = ID, 1, 0) = 1" '["-2.4"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): WHERE IIF(ID > -?, 1, 0) = 1 ['-1.5'] -> 2;3 (rounded: 3)" "SELECT ID FROM T WHERE IIF(ID > -?, 1, 0) = 1" '["-1.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): select list CASE WHEN -? > ID ['-2.5'] -> 1;1;0" "SELECT CASE WHEN -? > ID THEN 1 ELSE 0 END AS X FROM T" '["-2.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): select list CASE WHEN -? >= ID ['-2.5'] -> 1;1;0 (rounded to 3: 1;1;1)" "SELECT CASE WHEN -? >= ID THEN 1 ELSE 0 END AS X FROM T" '["-2.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): HAVING SUM(ID) > -? ['-4.5'] -> 4 (the aggregate on the left)" "SELECT N FROM T GROUP BY N HAVING SUM(ID) > -?" '["-4.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): HAVING -? = SUM(ID) ['-5'] -> 4 (an integer text)" "SELECT N FROM T GROUP BY N HAVING -? = SUM(ID)" '["-5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): HAVING -? = MAX(NM) ['-7.245'] -> none (rounded to 7.25: 3)" "SELECT N FROM T GROUP BY N HAVING -? = MAX(NM)" '["-7.245"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): HAVING -? <= SUM(ID) ['-4.5'] -> 4 (rounded to 5: none)" "SELECT N FROM T GROUP BY N HAVING -? <= SUM(ID)" '["-4.5"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): HAVING -? >= SUM(ID) ['-4.5'] -> 3 (rounded to 5: 3;4)" "SELECT N FROM T GROUP BY N HAVING -? >= SUM(ID)" '["-4.5"]'
eng_raises_fc_refuses "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID ['abc'] - conversion error on both (prepared on both)" "SELECT ID FROM T WHERE -? = ID" '["abc"]'
dml_rb_eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): UPDATE WHERE ID = -? ['-2.5'] -> no row (rounded to 3: row 3)" "UPDATE T SET N = 99 WHERE ID = -? RETURNING N" '["-2.5"]'
dml_rb_eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): UPDATE SET N = IIF(-? = ID, 95, N) WHERE ID = 2 ['-2.4'] -> 4 (rounded: 95)" "UPDATE T SET N = IIF(-? = ID, 95, N) WHERE ID = 2 RETURNING N" '["-2.4"]'
dml_rb_eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): DELETE WHERE -? = ID ['-2.4'] -> no row, read-back 1,2,3 (rounded: row 2 gone)" "DELETE FROM T WHERE -? = ID RETURNING ID" '["-2.4"]'
dml_rb_eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): DELETE WHERE -? = ID [-2] -> row 2 goes, read-back 1 and 3, then ROLLED BACK" "DELETE FROM T WHERE -? = ID RETURNING ID" '[-2]'
both "the fixture rows survived the rolled-back DML on both servers" "SELECT ID, N FROM T ORDER BY ID"

echo "-- 4e. THE SIBLING WIDTH OF A SCALED DECIMAL LITERAL under a LONG slot (the side rule's second input) --"
# Measured 2026-09-18 on the live engine (every cell below, both operand
# orders): under a SHORT/LONG slot the LEFT \`?\` ROUNDS when its sibling
# is NARROW (4 bytes) and the RIGHT rounds otherwise, and a scaled
# decimal literal is NARROW exactly when its unscaled integer fits 32
# bits (1.5, 1.0625, 214748364.7 narrow; 2147483648, 99999.99999,
# 214748364.8 wide) - the width the BLR literal takes, NOT the INT64 the
# projection describe announces for the same literal. The width carries
# through a unary minus, COALESCE and ROUND (narrow) and is LOST through
# IIF, NULLIF, ABS and arithmetic (8 bytes). A simple or searched CASE, a
# scalar subquery of a literal and MIN/MAX(1.5) also carry it on the
# engine; this server refuses those siblings (recorded below). The second
# cut of this chunk sized every decimal literal INT64 (result_width_bytes
# has no Dec arm) and rounded the wrong operand in every one of these.
# Every \`both\` cell is the HIT target of the engine's reading with the
# bind '2.5': a narrow sibling S has \`? * S = 3*S\` (the ? rounds to 3)
# and \`S * ? = 2.5*S\` (the ? keeps); a wide one the other way round. The
# OTHER reading's target is a different row set in every cell.
both "narrow 1.5: ? left ROUNDS: ? * 1.5 = CAST(4.5 AS NUMERIC(9,1)) ['2.5'] -> 1;2;3 (kept 3.75: none)" "SELECT ID FROM T WHERE ? * 1.5 = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
both "narrow 1.5: ? right KEEPS: 1.5 * ? = CAST(3.75 AS NUMERIC(9,2)) ['2.5'] -> 1;2;3 (rounded 4.5: none)" "SELECT ID FROM T WHERE 1.5 * ? = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
both "narrow 2.25 (2 digits): ? left ROUNDS: ? * 2.25 = CAST(6.75 AS NUMERIC(9,2)) -> 1;2;3 (kept 5.625: none)" "SELECT ID FROM T WHERE ? * 2.25 = CAST(6.75 AS NUMERIC(9,2))" '["2.5"]'
both "narrow 2.25: ? right KEEPS: 2.25 * ? = CAST(5.625 AS NUMERIC(9,3)) -> 1;2;3 (rounded 6.75: none)" "SELECT ID FROM T WHERE 2.25 * ? = CAST(5.625 AS NUMERIC(9,3))" '["2.5"]'
both "narrow 1.125 (3 digits): ? left ROUNDS: ? * 1.125 = CAST(3.375 AS NUMERIC(9,3)) -> 1;2;3 (kept 2.8125: none)" "SELECT ID FROM T WHERE ? * 1.125 = CAST(3.375 AS NUMERIC(9,3))" '["2.5"]'
both "narrow 1.125: ? right KEEPS: 1.125 * ? = CAST(2.8125 AS NUMERIC(9,4)) -> 1;2;3 (rounded 3.375: none)" "SELECT ID FROM T WHERE 1.125 * ? = CAST(2.8125 AS NUMERIC(9,4))" '["2.5"]'
both "narrow 1.0625 (4 digits): ? left ROUNDS: ? * 1.0625 = CAST(3.1875 AS NUMERIC(9,4)) -> 1;2;3 (kept 2.65625: none)" "SELECT ID FROM T WHERE ? * 1.0625 = CAST(3.1875 AS NUMERIC(9,4))" '["2.5"]'
both "narrow 1.0625: ? right KEEPS: 1.0625 * ? = CAST(2.65625 AS NUMERIC(9,5)) -> 1;2;3 (rounded 3.1875: none)" "SELECT ID FROM T WHERE 1.0625 * ? = CAST(2.65625 AS NUMERIC(9,5))" '["2.5"]'
both "narrow -1.5 (a negated literal): ? left ROUNDS: ? * -1.5 = CAST(-4.5 AS NUMERIC(9,1)) -> 1;2;3 (kept -3.75: none)" "SELECT ID FROM T WHERE ? * -1.5 = CAST(-4.5 AS NUMERIC(9,1))" '["2.5"]'
both "narrow -1.5: ? right KEEPS: -1.5 * ? = CAST(-3.75 AS NUMERIC(9,2)) -> 1;2;3 (rounded -4.5: none)" "SELECT ID FROM T WHERE -1.5 * ? = CAST(-3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: narrow COALESCE(1.5, 0): ? left ROUNDS: ? * COALESCE(1.5, 0) = CAST(4.5 AS NUMERIC(9,1)) -> 1;2;3 (kept 3.75: none)" "SELECT ID FROM T WHERE ? * COALESCE(1.5, 0) = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: narrow COALESCE(1.5, 0): ? right KEEPS: COALESCE(1.5, 0) * ? = CAST(3.75 AS NUMERIC(9,2)) -> 1;2;3 (rounded 4.5: none)" "SELECT ID FROM T WHERE COALESCE(1.5, 0) * ? = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: narrow ROUND(1.5) (= 2): ? left ROUNDS: ? * ROUND(1.5) = CAST(6.0 AS NUMERIC(9,1)) -> 1;2;3 (kept 5.0: none)" "SELECT ID FROM T WHERE ? * ROUND(1.5) = CAST(6.0 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: narrow ROUND(1.5): ? right KEEPS: ROUND(1.5) * ? = CAST(5.0 AS NUMERIC(9,1)) -> 1;2;3 (rounded 6.0: none)" "SELECT ID FROM T WHERE ROUND(1.5) * ? = CAST(5.0 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: narrow (SELECT b.ID ..) - a scalar subquery of a LONG column: ? left ROUNDS: ? * (SELECT b.ID .. = 2) = CAST(6.0 AS NUMERIC(9,1)) -> 1;2;3 (kept 5.0: none)" "SELECT ID FROM T WHERE ? * (SELECT b.ID FROM T b WHERE b.ID = 2) = CAST(6.0 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide IIF(NN = 5, 1.5, 2.5): ? left KEEPS: ? * IIF(..) = CAST(3.75 AS NUMERIC(9,2)) -> 1 (rounded 4.5/7.5: none)" "SELECT ID FROM T WHERE ? * IIF(NN = 5, 1.5, 2.5) = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide IIF(NN = 5, 1.5, 2.5): ? right ROUNDS: IIF(..) * ? = CAST(4.5 AS NUMERIC(9,1)) -> 1 (kept 3.75/6.25: none)" "SELECT ID FROM T WHERE IIF(NN = 5, 1.5, 2.5) * ? = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide NULLIF(1.5, 0): ? left KEEPS: ? * NULLIF(1.5, 0) = CAST(3.75 AS NUMERIC(9,2)) -> 1;2;3 (rounded 4.5: none)" "SELECT ID FROM T WHERE ? * NULLIF(1.5, 0) = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide NULLIF(1.5, 0): ? right ROUNDS: NULLIF(1.5, 0) * ? = CAST(4.5 AS NUMERIC(9,1)) -> 1;2;3 (kept 3.75: none)" "SELECT ID FROM T WHERE NULLIF(1.5, 0) * ? = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide ABS(1.5): ? left KEEPS: ? * ABS(1.5) = CAST(3.75 AS NUMERIC(9,2)) -> 1;2;3 (rounded 4.5: none)" "SELECT ID FROM T WHERE ? * ABS(1.5) = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide ABS(1.5): ? right ROUNDS: ABS(1.5) * ? = CAST(4.5 AS NUMERIC(9,1)) -> 1;2;3 (kept 3.75: none)" "SELECT ID FROM T WHERE ABS(1.5) * ? = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide (1.5 + 0) - arithmetic: ? left KEEPS: ? * (1.5 + 0) = CAST(3.75 AS NUMERIC(9,2)) -> 1;2;3 (rounded 4.5: none)" "SELECT ID FROM T WHERE ? * (1.5 + 0) = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "whitelist boundary (round 4, refused at prepare - the engine: wide (1.5 + 0): ? right ROUNDS: (1.5 + 0) * ? = CAST(4.5 AS NUMERIC(9,1)) -> 1;2;3 (kept 3.75: none)" "SELECT ID FROM T WHERE (1.5 + 0) * ? = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
# the 32-bit boundary of the unscaled integer, probed with '0.4' (rounded
# to 0 the product is 0; kept it is > 0)
both "wide 2147483648 (does not fit i32): ? left KEEPS: ? * 2147483648 > CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> 1;2;3 (rounded to 0: none)" "SELECT ID FROM T WHERE ? * 2147483648 > CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "wide 2147483648: ? right ROUNDS: 2147483648 * ? = CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> 1;2;3 (kept: none)" "SELECT ID FROM T WHERE 2147483648 * ? = CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "wide 99999.99999 (unscaled 9999999999): ? left KEEPS: ? * 99999.99999 > CAST(0.0 ..) ['0.4'] -> 1;2;3 (rounded to 0: none)" "SELECT ID FROM T WHERE ? * 99999.99999 > CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "wide 99999.99999: ? right ROUNDS: 99999.99999 * ? = CAST(0.0 ..) ['0.4'] -> 1;2;3 (kept: none)" "SELECT ID FROM T WHERE 99999.99999 * ? = CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "narrow 214748364.7 (unscaled 2147483647 = i32::MAX): ? left ROUNDS: ? * 214748364.7 = CAST(0.0 ..) ['0.4'] -> 1;2;3 (kept: none)" "SELECT ID FROM T WHERE ? * 214748364.7 = CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "narrow 214748364.7: ? right KEEPS: 214748364.7 * ? > CAST(0.0 ..) ['0.4'] -> 1;2;3 (rounded to 0: none)" "SELECT ID FROM T WHERE 214748364.7 * ? > CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "wide 214748364.8 (unscaled i32::MAX + 1): ? left KEEPS: ? * 214748364.8 > CAST(0.0 ..) ['0.4'] -> 1;2;3 (rounded to 0: none)" "SELECT ID FROM T WHERE ? * 214748364.8 > CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "wide 214748364.8: ? right ROUNDS: 214748364.8 * ? = CAST(0.0 ..) ['0.4'] -> 1;2;3 (kept: none)" "SELECT ID FROM T WHERE 214748364.8 * ? = CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "narrow 2147483647 (an unscaled i32::MAX): ? left ROUNDS: ? * 2147483647 = CAST(0.0 ..) ['0.4'] -> 1;2;3 (kept: none)" "SELECT ID FROM T WHERE ? * 2147483647 = CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "narrow 2147483647: ? right KEEPS: 2147483647 * ? > CAST(0.0 ..) ['0.4'] -> 1;2;3 (rounded to 0: none)" "SELECT ID FROM T WHERE 2147483647 * ? > CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
# the NM (LONG -2) slot, HAVING, an IIF condition, a nested multiply and
# the DML twins under rollback
both "NM slot, narrow 0.25: ? * 0.25 = NM ['28.5'] -> 1 (the ? rounds to 29: 7.25; kept 7.125: none)" "SELECT ID FROM T WHERE ? * 0.25 = NM" '["28.5"]'
both "NM slot, narrow 0.25: 0.25 * ? = NM ['28.5'] -> none (the ? keeps 7.125; rounded to 29: row 1)" "SELECT ID FROM T WHERE 0.25 * ? = NM" '["28.5"]'
both "NM slot, narrow 0.25: 0.25 * ? = NM ['29'] -> 1 (the integer text reaches 7.25 either way)" "SELECT ID FROM T WHERE 0.25 * ? = NM" '["29"]'
both "IIF(NM = ? * 0.25, 1, 0) = 1 ['28.5'] -> 1 (the condition's side rule; kept: none)" "SELECT ID FROM T WHERE IIF(NM = ? * 0.25, 1, 0) = 1" '["28.5"]'
both "HAVING ? * 1.5 = CAST(4.5 AS NUMERIC(9,1)) ['2.5'] -> 3 (kept 3.75: none)" "SELECT COUNT(*) AS C FROM T HAVING ? * 1.5 = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
both "HAVING MAX(NM) = ? * 0.25 ['28.5'] -> 1 (kept: none)" "SELECT ID FROM T GROUP BY ID HAVING MAX(NM) = ? * 0.25" '["28.5"]'
both "? * 1.5 * ID = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] -> 2 (the inner ? * 1.5 rounds the ?: 4.5 * 2; kept 3.75 * ID: none)" "SELECT ID FROM T WHERE ? * 1.5 * ID = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
both "CONTROL, an INT64 slot: ? * 1.5 = 3.75 ['2.5'] -> 1;2;3 (the RIGHT rounds under INT64 whatever the sibling; the ? keeps)" "SELECT ID FROM T WHERE ? * 1.5 = 3.75" '["2.5"]'
both "CONTROL, an INT64 slot: ? * 1.5 = 4.5 ['2.5'] -> none (the LONG reading's target)" "SELECT ID FROM T WHERE ? * 1.5 = 4.5" '["2.5"]'
dml_rb "UPDATE WHERE ? * 1.5 = CAST(4.5 AS NUMERIC(9,1)) ['2.5'] -> every row 99 (kept: no row)" "UPDATE T SET N = 99 WHERE ? * 1.5 = CAST(4.5 AS NUMERIC(9,1)) RETURNING N" '["2.5"]'
dml_rb "DELETE WHERE ? * 1.5 = CAST(4.5 AS NUMERIC(9,1)) ['2.5'] -> every row goes, read-back empty (kept: no row)" "DELETE FROM T WHERE ? * 1.5 = CAST(4.5 AS NUMERIC(9,1)) RETURNING ID" '["2.5"]'
both "the fixture rows survived the rolled-back DML on both servers" "SELECT ID, N FROM T ORDER BY ID"
# siblings whose width this server cannot tell apart from the other
# reading - a simple or searched CASE, a scalar subquery of a LITERAL and
# MIN(1.5) - are REFUSED (the engine: narrow for CASE NN WHEN, (SELECT
# 1.5 ..) and MIN(1.5); wide for the searched CASE)
eng_only "? * CASE NN WHEN 5 THEN 1.5 ELSE 2.5 END = CAST(4.5 ..) ['2.5'] - engine 1 (narrow), refused" "SELECT ID FROM T WHERE ? * CASE NN WHEN 5 THEN 1.5 ELSE 2.5 END = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "CASE NN WHEN 5 THEN 1.5 ELSE 2.5 END * ? = CAST(3.75 ..) ['2.5'] - engine 1, refused" "SELECT ID FROM T WHERE CASE NN WHEN 5 THEN 1.5 ELSE 2.5 END * ? = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "? * CASE WHEN NN = 5 THEN 1.5 ELSE 2.5 END = CAST(3.75 ..) ['2.5'] - engine 1 (wide), refused" "SELECT ID FROM T WHERE ? * CASE WHEN NN = 5 THEN 1.5 ELSE 2.5 END = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "CASE WHEN NN = 5 THEN 1.5 ELSE 2.5 END * ? = CAST(4.5 ..) ['2.5'] - engine 1, refused" "SELECT ID FROM T WHERE CASE WHEN NN = 5 THEN 1.5 ELSE 2.5 END * ? = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "? * (SELECT 1.5 FROM RDB\$DATABASE) = CAST(4.5 ..) ['2.5'] - engine 1;2;3 (narrow), refused" "SELECT ID FROM T WHERE ? * (SELECT 1.5 FROM RDB\$DATABASE) = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "(SELECT 1.5 FROM RDB\$DATABASE) * ? = CAST(3.75 ..) ['2.5'] - engine 1;2;3, refused" "SELECT ID FROM T WHERE (SELECT 1.5 FROM RDB\$DATABASE) * ? = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
eng_only "HAVING ? * MIN(1.5) = CAST(4.5 ..) ['2.5'] - engine 3 (narrow), refused" "SELECT COUNT(*) AS C FROM T HAVING ? * MIN(1.5) = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'

echo "-- 4f. A SCALAR-SUBQUERY SLOT is sized from its inner projected column (the side rule's first input) --"
# The slot descriptor of \`? * ID = (SELECT b.NM ..)\` is now built from
# the subquery's projected column - LONG -2 for a NUMERIC(9,2) column,
# SHORT for NUMERIC(4,1), INT64 for BIGINT - so the side rule reads the
# right width (the second cut announced INT64 for b.NM and let the LEFT
# \`?\` keep its fraction where the engine rounds it: 2 for ['1.25'], and
# an UPDATE took row 2). The value agrees in every cell; the announcement
# still says NOT NULL where the engine says Nullable - the pre-existing
# scalar-subquery nullability gap, recorded through desc_differs.
desc_differs "? * ID = (SELECT MIN(b.NM) FROM T b) ['0.5'] -> 1 (LONG -2 slot: the LEFT ? rounds to 1; kept 0.5 * 2 = 1.00: row 2)" "SELECT ID FROM T WHERE ? * ID = (SELECT MIN(b.NM) FROM T b)" '["0.5"]'
desc_differs "? * ID = (SELECT b.NM .. b.ID = 3) ['1.25'] -> none (the LEFT ? rounds to 1; kept 1.25 * 2 = 2.50: row 2)" "SELECT ID FROM T WHERE ? * ID = (SELECT b.NM FROM T b WHERE b.ID = 3)" '["1.25"]'
desc_differs "ID * ? = (SELECT b.NM .. b.ID = 3) ['1.25'] -> 2 (the RIGHT ? keeps 1.25; rounded: none)" "SELECT ID FROM T WHERE ID * ? = (SELECT b.NM FROM T b WHERE b.ID = 3)" '["1.25"]'
desc_differs "? * ID = (SELECT CAST(2.5 AS NUMERIC(4,1)) ..) ['1.25'] -> none (a SHORT slot: the LEFT rounds; kept: row 2)" "SELECT ID FROM T WHERE ? * ID = (SELECT CAST(2.5 AS NUMERIC(4,1)) FROM RDB\$DATABASE)" '["1.25"]'
desc_differs "CONTROL: the bare ? = (SELECT b.NM ..) ['2.5'] -> 1;2;3 (the pre-existing nullability gap alone)" "SELECT ID FROM T WHERE ? = (SELECT b.NM FROM T b WHERE b.ID = 3)" '["2.5"]'
dml_rb_desc_differs "UPDATE WHERE ? * ID = (SELECT b.NM .. b.ID = 3) ['1.25'] -> no row (kept: row 2 becomes 99)" "UPDATE T SET N = 99 WHERE ? * ID = (SELECT b.NM FROM T b WHERE b.ID = 3) RETURNING N" '["1.25"]'
both "the fixture rows survived the rolled-back DML on both servers" "SELECT ID, N FROM T ORDER BY ID"

echo "-- 4g. A WHOLE-SIDE TEXT BIND INTO A DOUBLE SLOT takes the compare grammar, not an evaluated CAST --"
# The engine's compare grammar reads '1 2' as 12, '0X2' as hex garbage,
# '- 2.5' and '1e400' as no-match, and raises only on '0x2' / '2.5x';
# the second cut kept CAST(? AS DOUBLE PRECISION) for a DOUBLE/REAL
# whole side and raised *conversion error* on the first four. The
# CLASSIC bare \`D = ?\` does NOT share the rung: it still raises on '1 2',
# '- 2.5' and '0X2' on both binaries (pre-existing, recorded as eng_only).
boundary_err "R12 boundary: conversion error by design (K2): IIF(D = ?, 1, 0) = 1 ['1 2'] -> none (the second cut raised)" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 1" '["1 2"]'
boundary_err "R12 boundary: conversion error by design (K2): IIF(D = ?, 1, 0) = 1 ['- 2.5'] -> none" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 1" '["- 2.5"]'
boundary_err "R12 boundary: conversion error by design (K2): IIF(D = ?, 1, 0) = 1 ['0X2'] -> none" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 1" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): IIF(D = ?, 1, 0) = 1 ['1e400'] -> none (the second cut raised numeric overflow)" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 1" '["1e400"]'
boundary_err "R12 boundary: conversion error by design (K2): IIF(D = ?, 1, 0) = 0 ['1 2'] -> 1;2;3" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 0" '["1 2"]'
both "IIF(D = ?, 1, 0) = 1 ['2.5'] -> 2 (control)" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 1" '["2.5"]'
boundary_err "R12 boundary: conversion error by design (K2): IIF(? = D, 1, 0) = 1 ['0X2'] -> none (the ? on the left)" "SELECT ID FROM T WHERE IIF(? = D, 1, 0) = 1" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): select list IIF(D = ?, 1, 0) ['0X2'] -> 0;0;0" "SELECT IIF(D = ?, 1, 0) AS X FROM T" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): ORDER BY IIF(D = ?, 0, 1) ['1 2'] -> 1;2;3" "SELECT ID FROM T ORDER BY IIF(D = ?, 0, 1), ID" '["1 2"]'
boundary_err "R12 boundary: conversion error by design (K2): HAVING IIF(MAX(D) = ?, 1, 0) = 1 ['1 2'] -> none" "SELECT N FROM T GROUP BY N HAVING IIF(MAX(D) = ?, 1, 0) = 1" '["1 2"]'
both_err "IIF(D = ?, 1, 0) = 1 ['0x2'] - conversion error on both" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 1" '["0x2"]'
both_err "IIF(D = ?, 1, 0) = 1 ['2.5x'] - conversion error on both" "SELECT ID FROM T WHERE IIF(D = ?, 1, 0) = 1" '["2.5x"]'
# a REAL whole side: the value agrees, FLOAT is announced DOUBLE (pre-existing)
boundary_err "R12 boundary: conversion error by design (K2): IIF(CAST(D AS FLOAT) = ?, 1, 0) = 1 ['1 2'] -> none (482 FLOAT announced 480 DOUBLE)" "SELECT ID FROM T WHERE IIF(CAST(D AS FLOAT) = ?, 1, 0) = 1" '["1 2"]'
# the classic bare twins
both "CLASSIC D = ? ['2.5'] -> 2" "SELECT ID FROM T WHERE D = ?" '["2.5"]'
both "CLASSIC D = ? ['1e400'] -> none on both" "SELECT ID FROM T WHERE D = ?" '["1e400"]'
both_err "CLASSIC D = ? ['0x2'] - raises on both" "SELECT ID FROM T WHERE D = ?" '["0x2"]'
both_err "CLASSIC D = ? ['2.5x'] - raises on both" "SELECT ID FROM T WHERE D = ?" '["2.5x"]'
eng_only "CLASSIC D = ? ['1 2'] - engine none, this server raises at execute (pre-existing, a separate rung)" "SELECT ID FROM T WHERE D = ?" '["1 2"]'
eng_only "CLASSIC D = ? ['- 2.5'] - engine none, this server raises (pre-existing)" "SELECT ID FROM T WHERE D = ?" '["- 2.5"]'
eng_only "CLASSIC D = ? ['0X2'] - engine none, this server raises (pre-existing)" "SELECT ID FROM T WHERE D = ?" '["0X2"]'

echo "-- 4h. -? OF THE 32-BIT MINIMUM negates in the MESSAGE width and overflows like the engine --"
# A LONG message value -2147483648 under \`-?\` raises *Integer overflow*
# on the engine (the negate runs in the client's 4-byte width); the
# second cut negated in i64 and answered no row. The same value in an
# INT64 slot (-? = BI) still arrives as a LONG message and overflows the
# same way; -2147483649 is an INT64 message and negates fine.
eng_raises_fc_refuses "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID [-2147483648] - Integer overflow on both (a LONG message)" "SELECT ID FROM T WHERE -? = ID" '[-2147483648]'
eng_raises_fc_refuses "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): ID = -? [-2147483648] - Integer overflow on both" "SELECT ID FROM T WHERE ID = -?" '[-2147483648]'
eng_raises_fc_refuses "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = BI [-2147483648] - an INT64 slot, still a LONG message: overflow on both" "SELECT ID FROM T WHERE -? = BI" '[-2147483648]'
eng_raises_fc_refuses "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): IIF(-? = ID, 1, 0) = 1 [-2147483648] - overflow on both" "SELECT ID FROM T WHERE IIF(-? = ID, 1, 0) = 1" '[-2147483648]'
both_err "CLASSIC ID = -CAST(? AS INTEGER) [-2147483648] - overflow on both (the previous binary answered no row)" "SELECT ID FROM T WHERE ID = -CAST(? AS INTEGER)" '[-2147483648]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID [-2147483647] -> none (control: one above the minimum)" "SELECT ID FROM T WHERE -? = ID" '[-2147483647]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = BI [-2147483649] -> none (an INT64 message negates)" "SELECT ID FROM T WHERE -? = BI" '[-2147483649]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID [2147483648] -> none (an INT64 message)" "SELECT ID FROM T WHERE -? = ID" '[2147483648]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): -? = ID ['-2147483648'] -> none (a TEXT bind takes the DOUBLE grammar, no overflow)" "SELECT ID FROM T WHERE -? = ID" '["-2147483648"]'
both "CLASSIC ID = -CAST(? AS INTEGER) [-2147483647] -> none (control)" "SELECT ID FROM T WHERE ID = -CAST(? AS INTEGER)" '[-2147483647]'
both "CLASSIC ID = -CAST(? AS BIGINT) [-2147483648] -> none (an 8-byte cast negates)" "SELECT ID FROM T WHERE ID = -CAST(? AS BIGINT)" '[-2147483648]'

echo "-- 4i. A -? OR ARITHMETIC ? AS A SIMPLE-CASE WHEN VALUE is refused like the engine (-804) --"
# The engine's DECODE cannot type a negated or computed parameter as a
# WHEN value (-804 Data type unknown); the second cut desugared \`CASE ID
# WHEN -?\` into \`ID = -?\` and answered. The bare \`?\` WHEN value and a
# CAST one are typed and answered on both.
both_refuse "CASE ID WHEN -? THEN 1 ELSE 0 END = 1 ['-2'] - the engine refuses (-804)" "SELECT ID FROM T WHERE CASE ID WHEN -? THEN 1 ELSE 0 END = 1" '["-2"]'
both_refuse "CASE ID WHEN ? + 1 THEN .. ['1'] - refused" "SELECT ID FROM T WHERE CASE ID WHEN ? + 1 THEN 1 ELSE 0 END = 1" '["1"]'
both_refuse "CASE -? WHEN 2 THEN .. ['-2'] - a negated CASE operand, refused" "SELECT ID FROM T WHERE CASE -? WHEN 2 THEN 1 ELSE 0 END = 1" '["-2"]'
both_refuse "select list CASE ID WHEN -? THEN .. ['-2'] - refused" "SELECT CASE ID WHEN -? THEN 1 ELSE 0 END AS X FROM T" '["-2"]'
both "CASE ID WHEN ? THEN 1 ELSE 0 END = 1 ['2'] -> 2 (control: the bare WHEN value)" "SELECT ID FROM T WHERE CASE ID WHEN ? THEN 1 ELSE 0 END = 1" '["2"]'
both "CASE ID WHEN ? THEN .. ['2.4'] -> none (a whole-side value, kept)" "SELECT ID FROM T WHERE CASE ID WHEN ? THEN 1 ELSE 0 END = 1" '["2.4"]'
both "CASE ID WHEN CAST(? AS INTEGER) THEN .. ['2'] -> 2 (control)" "SELECT ID FROM T WHERE CASE ID WHEN CAST(? AS INTEGER) THEN 1 ELSE 0 END = 1" '["2"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): CASE WHEN ID = -? THEN .. ['-2'] -> 2 (a searched CASE condition types -?)" "SELECT ID FROM T WHERE CASE WHEN ID = -? THEN 1 ELSE 0 END = 1" '["-2"]'

echo "-- 4j. A -? OR ARITHMETIC ? INSIDE A SUBQUERY BODY is refused at PREPARE, never described-then-failed --"
# The subquery text is re-planned per row with its \`?\` markers spelled
# back as literals, which cannot carry a rung under a minus or an
# operator; the second cut described these and failed at execute with
# *Dynamic SQL Error*. They are refused at prepare again (the previous
# binary's boundary); a whole-side bare \`?\` inside the body answers.
eng_only "EXISTS (.. AND -? = b.ID) ['-2'] - engine 2, refused at prepare" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T b WHERE b.ID = T.ID AND -? = b.ID)" '["-2"]'
eng_only "ID = (SELECT b.ID .. WHERE b.NM = ? * b.ID) ['2.5'] - engine none, refused" "SELECT ID FROM T WHERE ID = (SELECT b.ID FROM T b WHERE b.NM = ? * b.ID)" '["2.5"]'
eng_only "ID IN (SELECT b.ID .. WHERE ? * b.ID = CAST(9.0 ..)) ['2.5'] - engine 3, refused" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE ? * b.ID = CAST(9.0 AS NUMERIC(9,1)))" '["2.5"]'
eng_only "ID IN (SELECT b.ID .. WHERE -? = b.ID) ['-2.4'] - engine none, refused" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE -? = b.ID)" '["-2.4"]'
both "EXISTS (.. AND IIF(b.ID = ?, 1, 0) = 1) ['2'] -> 2 (control: a whole-side ? in the body)" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T b WHERE b.ID = T.ID AND IIF(b.ID = ?, 1, 0) = 1)" '["2"]'
both "EXISTS (.. AND IIF(b.ID = ?, 1, 0) = 1) ['2.4'] -> none (kept whole)" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T b WHERE b.ID = T.ID AND IIF(b.ID = ?, 1, 0) = 1)" '["2.4"]'
both "ID = (SELECT b.ID .. WHERE IIF(b.ID = ?, 1, 0) = 1) ['2'] -> 2" "SELECT ID FROM T WHERE ID = (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2"]'
both "ID IN (SELECT b.ID .. WHERE b.ID = ?) ['2'] -> 2 (control)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.ID = ?)" '["2"]'

echo "-- 4k. ROUND 4: THE MULTIPLY'S SIBLING WIDTH IS A WHITELIST; the six smaller classes (engine-measured 2026-09-19, scratchpad W/W2/X2-X7 matrices) --"
# the whitelist boundary: a function, a conditional, an arithmetic
# sibling, a subquery, a derived / view column refuse at PREPARE (the
# engine's values stated; the round-3 table answered the WRONG rows for
# the first two)
eng_only "whitelist boundary: ? * ABS(CAST(ID AS SMALLINT)) = CAST(3.0 AS NUMERIC(9,1)) ['1.4'] (engine 3: makeAbs SHORT -> LONG, narrow; the table read 8 and answered none)" "SELECT ID FROM T WHERE ? * ABS(CAST(ID AS SMALLINT)) = CAST(3.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "whitelist boundary: ? * d.L over (SELECT ID, 1.5 AS L FROM T) d = CAST(4.5 AS NUMERIC(9,1)) ['2.5'] (engine 1;2;3: the literal's blr_long through the alias; the table read the INT64 describe and answered none)" "SELECT d.ID FROM (SELECT ID, 1.5 AS L FROM T) d WHERE ? * d.L = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary: d.L * ? = CAST(4.5 AS NUMERIC(9,1)) ['2.5'] (engine none)" "SELECT d.ID FROM (SELECT ID, 1.5 AS L FROM T) d WHERE d.L * ? = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary: ? * SIGN(D) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (engine none: SIGN is SHORT, narrow)" "SELECT ID FROM T WHERE ? * SIGN(D) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
eng_only "whitelist boundary: ? * MOD(D, 2) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (engine 2: MOD is INT64, wide)" "SELECT ID FROM T WHERE ? * MOD(D, 2) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
eng_only "whitelist boundary: ? * COALESCE(ID, 0) = CAST(9.0 AS NUMERIC(9,1)) ['2.5'] (engine 3)" "SELECT ID FROM T WHERE ? * COALESCE(ID, 0) = CAST(9.0 AS NUMERIC(9,1))" '["2.5"]'
eng_only "whitelist boundary: HAVING ? * MIN(CAST(ID AS SMALLINT)) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (engine none: MIN over an expression)" "SELECT ID FROM T GROUP BY ID HAVING ? * MIN(CAST(ID AS SMALLINT)) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
# ... while every whitelisted shape answers by its measured width
both "whitelist (a): ? * CAST(ID AS SMALLINT) = CAST(3.0 AS NUMERIC(9,1)) ['1.4'] -> 3 (a SHORT cast is narrow: the left rounds)" "SELECT ID FROM T WHERE ? * CAST(ID AS SMALLINT) = CAST(3.0 AS NUMERIC(9,1))" '["1.4"]'
both "whitelist (c): ? * -1.5 = CAST(-4.5 AS NUMERIC(9,1)) ['2.5'] -> 1;2;3 (a negated literal keeps its blr_long)" "SELECT ID FROM T WHERE ? * -1.5 = CAST(-4.5 AS NUMERIC(9,1))" '["2.5"]'
both "whitelist (c): ? * 214748364.7 <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> none (2147483647 fits i32: narrow)" "SELECT ID FROM T WHERE ? * 214748364.7 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "whitelist (c): ? * 214748364.8 <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> 1;2;3 (2147483648 does not: wide)" "SELECT ID FROM T WHERE ? * 214748364.8 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "whitelist (d): ? * CAST(1.5 AS NUMERIC(18,1)) = CAST(3.75 AS NUMERIC(9,2)) ['2.5'] -> 1;2;3 (an INT64 cast: the right keeps.. the left keeps)" "SELECT ID FROM T WHERE ? * CAST(1.5 AS NUMERIC(18,1)) = CAST(3.75 AS NUMERIC(9,2))" '["2.5"]'
both "whitelist (f): HAVING ? * AVG(ID) = CAST(7.5 AS NUMERIC(9,1)) ['2.5'] -> 3 (AVG is 8 bytes: the left keeps)" "SELECT ID FROM T GROUP BY ID HAVING ? * AVG(ID) = CAST(7.5 AS NUMERIC(9,1))" '["2.5"]'
both "whitelist (f): HAVING ? * MAX(NM) = CAST(7.5 AS NUMERIC(9,2)) ['2.5'] -> 3 (MAX over a LONG column: the left rounds)" "SELECT ID FROM T GROUP BY ID HAVING ? * MAX(NM) = CAST(7.5 AS NUMERIC(9,2))" '["2.5"]'
both "whitelist (g): ? * (1.5) = CAST(4.5 AS NUMERIC(9,1)) ['2.5'] -> 1;2;3" "SELECT ID FROM T WHERE ? * (1.5) = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]'
# X2: a DATE whole side bound from node's blr_timestamp compares at
# TIMESTAMP (a DATE at midnight), never through a truncating CAST
both "X2 IIF(DT = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> none (the cast answered 1)" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 IIF(DT = ?, 1, 0) = 0 ['2024-01-10 12:30:00'] -> 1;2;3" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 0" '["2024-01-10 12:30:00"]'
both "X2 IIF(DT < ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 1" "SELECT ID FROM T WHERE IIF(DT < ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 IIF(? > DT, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 1" "SELECT ID FROM T WHERE IIF(? > DT, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 IIF(DT = ?, 1, 0) = 1 ['2024-01-10 00:00:00'] -> 1 (midnight agrees either way)" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10 00:00:00"]'
both "X2 SUM(IIF(DT = ?, 1, 0)) ['2024-01-10 12:30:00'] -> 0" "SELECT SUM(IIF(DT = ?, 1, 0)) AS X FROM T" '["2024-01-10 12:30:00"]'
dml_rb "X2 DELETE FROM T WHERE IIF(DT = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> deletes nothing (the cast deleted row 1)" "DELETE FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
dml_rb "X2 UPDATE T SET N = 99 WHERE IIF(DT < ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> row 1" "UPDATE T SET N = 99 WHERE IIF(DT < ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
# X3: a whole-side text inside a subquery body reads by the compare
# grammar (it used to prepare, then fail at execute)
boundary_err "R12 boundary: conversion error by design (K2): X3 ID IN (SELECT b.ID .. IIF(b.ID = ?, 1, 0) = 1) ['0X2'] -> none (hex garbage: orders-high)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 ID IN (SELECT b.ID .. IIF(b.ID < ?, 1, 0) = 1) ['0X2'] -> 1;2;3" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID < ?, 1, 0) = 1)" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 ID IN (SELECT b.ID .. IIF(b.ID = ?, 1, 0) = 1) ['1e400'] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["1e400"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 ID IN (SELECT b.ID .. IIF(b.ID < ?, 1, 0) = 1) ['2.0000000000000000001'] -> 1;2 (19 decimals kept)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID < ?, 1, 0) = 1)" '["2.0000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 ID IN (SELECT b.ID .. IIF(b.D = ?, 1, 0) = 1) ['1 2'] -> none (12)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["1 2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 ID IN (SELECT b.ID .. IIF(b.D = ?, 1, 0) = 1) ['2 .5'] -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["2 .5"]'
both "X3 ID IN (SELECT b.ID .. b.ID IN (?, 3)) ['0X2'] -> 3 (an IN-list element reads the same way)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.ID IN (?, 3))" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 EXISTS (.. IIF(b.D = ?, 1, 0) = 1) ['1 2'] -> none" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T b WHERE b.ID = T.ID AND IIF(b.D = ?, 1, 0) = 1)" '["1 2"]'
both_err "X3 ID IN (SELECT b.ID .. IIF(b.ID = ?, 1, 0) = 1) ['abc'] (conversion error from string on both)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["abc"]'
both_err "X3 ID IN (SELECT b.ID .. IIF(b.ID = ?, 1, 0) = 1) ['0x2'] (a lowercase hex raises on both)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["0x2"]'
both_err "X3 ID IN (SELECT b.ID .. IIF(b.ID = ?, 1, 0) = 1) ['2 -- x'] (a comment inside the text raises on both)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2 -- x"]'
# X4: SIGN and MOD evaluate over an approximate operand (they prepared
# and failed at execute on both binaries before)
both "X4 SELECT SIGN(D) AS X FROM T -> 1;1;1 (SHORT)" "SELECT SIGN(D) AS X FROM T ORDER BY ID"
both "X4 SELECT SIGN(D - 2.5) AS X FROM T -> -1;0;1" "SELECT SIGN(D - 2.5) AS X FROM T ORDER BY ID"
both "X4 SELECT MOD(D, 2) AS X FROM T -> 0;1;0 (the double rounds half away from zero first)" "SELECT MOD(D, 2) AS X FROM T ORDER BY ID"
both "X4 SELECT MOD(NM, D) AS X FROM T -> 1;1;3" "SELECT MOD(NM, D) AS X FROM T ORDER BY ID"
both "X4 SELECT MOD(-D, 2) AS X FROM T -> 0;-1;0" "SELECT MOD(-D, 2) AS X FROM T ORDER BY ID"
both "X4 WHERE 1 * SIGN(D) <> CAST(0.0 AS NUMERIC(9,1)) -> 1;2;3" "SELECT ID FROM T WHERE 1 * SIGN(D) <> CAST(0.0 AS NUMERIC(9,1))"
both_err "X4 SELECT MOD(1e19, 7) (numeric value is out of range on both)" "SELECT MOD(1e19, 7) AS X FROM RDB\$DATABASE"
# X5: a simple CASE / DECODE THEN or ELSE value the engine's DecodeNode
# cannot type refuses on both; a typed one and an add / subtract answer
both_refuse "X5 CASE ID WHEN ? THEN -? ELSE 0 END = -2 ['2', '2']" "SELECT ID FROM T WHERE CASE ID WHEN ? THEN -? ELSE 0 END = -2" '["2", "2"]'
both_refuse "X5 CASE ID WHEN 2 THEN ? * 2 ELSE 0 END = 4 ['2']" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? * 2 ELSE 0 END = 4" '["2"]'
both_refuse "X5 CASE ID WHEN 2 THEN 0 ELSE -? END = -2 ['2']" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN 0 ELSE -? END = -2" '["2"]'
both_refuse "X5 CASE ID WHEN 2 THEN CAST(-? AS INTEGER) ELSE 0 END = -2 ['2']" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN CAST(-? AS INTEGER) ELSE 0 END = -2" '["2"]'
both_refuse "X5 COALESCE(CASE ID WHEN 2 THEN -? END, 0) = -2 ['2']" "SELECT ID FROM T WHERE COALESCE(CASE ID WHEN 2 THEN -? END, 0) = -2" '["2"]'
both_refuse "X5 SELECT CASE ID WHEN 2 THEN -? ELSE 0 END AS X FROM T ['2']" "SELECT CASE ID WHEN 2 THEN -? ELSE 0 END AS X FROM T ORDER BY ID" '["2"]'
both_refuse "X5 IIF(ID = 2, CAST(-? AS INTEGER), 0) = -2 ['2'] (a searched branch under a CAST refuses too)" "SELECT ID FROM T WHERE IIF(ID = 2, CAST(-? AS INTEGER), 0) = -2" '["2"]'
both_refuse "X5 IIF(ID = 2, ABS(-?), 0) = 2 ['2']" "SELECT ID FROM T WHERE IIF(ID = 2, ABS(-?), 0) = 2" '["2"]'
both "X5 CASE ID WHEN 2 THEN -CAST(? AS INTEGER) ELSE 0 END = -2 ['2'] -> 2 (a typed ? negates)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -CAST(? AS INTEGER) ELSE 0 END = -2" '["2"]'
both "X5 CASE ID WHEN 2 THEN NULLIF(-?, 0) ELSE 0 END = -2 ['2'] -> 2 (comparison-typed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN NULLIF(-?, 0) ELSE 0 END = -2" '["2"]'
desc_differs "X5 IIF(ID = 2, ? + 1, 0) = 3 ['2'] -> 2 (a searched branch types -? and ? + 1 from its sibling; the branch slot's NOT NULL flag is the recorded gap)" "SELECT ID FROM T WHERE IIF(ID = 2, ? + 1, 0) = 3" '["2"]'
# X6: a DML destination's -? negates in the MESSAGE width (a 4-byte
# blr_long -2147483648 overflows into a BIGINT destination too)
dml_rb_both_err "X6 UPDATE T SET BI = -? WHERE ID = 1 [-2147483648] (Integer overflow on both; the cast-then-negate stored 2147483648)" "UPDATE T SET BI = -? WHERE ID = 1" '[-2147483648]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb_both_err "X6 INSERT INTO T (ID, NN, BI) VALUES (9, 1, -?) [-2147483648] (Integer overflow on both)" "INSERT INTO T (ID, NN, BI) VALUES (9, 1, -?)" '[-2147483648]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb_both_err "X6 UPDATE T SET D = -? WHERE ID = 1 [-2147483648] (a DOUBLE destination overflows too)" "UPDATE T SET D = -? WHERE ID = 1" '[-2147483648]' "SELECT ID, D FROM T ORDER BY ID"
dml_rb "X6 UPDATE T SET BI = -? WHERE ID = 1 [-2147483647] -> 1,2147483647 (the next value negates)" "UPDATE T SET BI = -? WHERE ID = 1" '[-2147483647]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb "X6 UPDATE T SET BI = -? WHERE ID = 1 [-2147483649] -> 1,2147483649 (an 8-byte message negates)" "UPDATE T SET BI = -? WHERE ID = 1" '[-2147483649]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb "X6 UPDATE T SET N = -? WHERE ID = 1 ['1.5'] -> 1,-2 (a text negates by the double grammar, then rounds)" "UPDATE T SET N = -? WHERE ID = 1" '["1.5"]'
dml_rb "X6 UPDATE T SET NM = -? WHERE ID = 1 ['1.25'] -> 1,-1.25" "UPDATE T SET NM = -? WHERE ID = 1" '["1.25"]' "SELECT ID, NM FROM T ORDER BY ID"
# X7: a correlated scalar-subquery slot carries its column's NUMERIC family
both "X7 ? * ID = (SELECT b.NM FROM T b WHERE b.ID = T.ID + 1) ['1.25'] -> 1 (496 LONG scale -2 SUBTYPE 1 on both)" "SELECT ID FROM T WHERE ? * ID = (SELECT b.NM FROM T b WHERE b.ID = T.ID + 1)" '["1.25"]'
both "X7 ID * ? = (SELECT b.NM FROM T b WHERE b.ID = T.ID + 1) ['1.25'] -> 2" "SELECT ID FROM T WHERE ID * ? = (SELECT b.NM FROM T b WHERE b.ID = T.ID + 1)" '["1.25"]'
both "X7 ? = (SELECT CAST(b.NM AS DECIMAL(9,2)) FROM T b WHERE b.ID = T.ID + 1) ['1.00'] -> 1 (SUBTYPE 2)" "SELECT ID FROM T WHERE ? = (SELECT CAST(b.NM AS DECIMAL(9,2)) FROM T b WHERE b.ID = T.ID + 1)" '["1.00"]'

echo "-- 4l. ROUND 4 PINS: every whitelisted sibling shape in BOTH operand orders, every refused family with the engine's value, and the six classes in full (engine-measured 2026-09-19, scratchpad gx4-wl/gx4-bd/gx4-x.out, three-way against /tmp/fcwire-prev-c34c1c8 which refused every ?-in-arithmetic cell here) --"
# THE WHITELIST, one hit cell per shape and order under a LONG slot with
# the bind '1.4' (rounds to 1, keeps 1.4 - a different row set in every
# cell): a NARROW sibling (<= 4 bytes) makes the LEFT ? round and the
# RIGHT keep, a WIDE one (8 bytes) the other way round. The label names
# the other reading's target; SHORT-slot twins for the base column, the
# literals and the direct ?.
# (a) a base-table column at its stored width
both "4l(a) ID narrow, ? left ROUNDS: ? * ID = CAST(2.0 AS NUMERIC(9,1)) ['1.4'] -> 2 (kept 1.4*ID: none)" "SELECT ID FROM T WHERE ? * ID = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) ID narrow, ? right KEEPS: ID * ? = CAST(2.8 AS NUMERIC(9,1)) ['1.4'] -> 2 (rounded 1*ID: none)" "SELECT ID FROM T WHERE ID * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) ID under a SHORT slot, ? left ROUNDS: ? * ID = CAST(2.0 AS NUMERIC(4,1)) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * ID = CAST(2.0 AS NUMERIC(4,1))" '["1.4"]'
both "4l(a) ID under a SHORT slot, ? right KEEPS: ID * ? = CAST(2.8 AS NUMERIC(4,1)) ['1.4'] -> 2" "SELECT ID FROM T WHERE ID * ? = CAST(2.8 AS NUMERIC(4,1))" '["1.4"]'
both "4l(a) NM narrow (scaled LONG), ? left ROUNDS: ? * NM = CAST(7.25 AS NUMERIC(9,3)) ['0.5'] -> 1 (0.5 rounds to 1; kept 3.625: none)" "SELECT ID FROM T WHERE ? * NM = CAST(7.25 AS NUMERIC(9,3))" '["0.5"]'
both "4l(a) NM narrow, ? right KEEPS: NM * ? = CAST(3.625 AS NUMERIC(9,3)) ['0.5'] -> 1 (rounded 7.25: none)" "SELECT ID FROM T WHERE NM * ? = CAST(3.625 AS NUMERIC(9,3))" '["0.5"]'
both "4l(a) N narrow, ? left ROUNDS: ? * N = CAST(3.0 AS NUMERIC(9,1)) ['1.4'] -> 1 (kept 4.2: none)" "SELECT ID FROM T WHERE ? * N = CAST(3.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) N narrow, ? right KEEPS: N * ? = CAST(4.2 AS NUMERIC(9,1)) ['1.4'] -> 1" "SELECT ID FROM T WHERE N * ? = CAST(4.2 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) NN (NOT NULL) narrow, ? left ROUNDS: ? * NN = CAST(5.0 AS NUMERIC(9,1)) ['1.4'] -> 1" "SELECT ID FROM T WHERE ? * NN = CAST(5.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) NN narrow, ? right KEEPS: NN * ? = CAST(7.0 AS NUMERIC(9,1)) ['1.4'] -> 1" "SELECT ID FROM T WHERE NN * ? = CAST(7.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) BI wide, ? left KEEPS: ? * BI = CAST(11.2 AS NUMERIC(9,1)) ['1.4'] -> 2 (rounded 1*BI: none)" "SELECT ID FROM T WHERE ? * BI = CAST(11.2 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) BI wide, ? right ROUNDS: BI * ? = CAST(8.0 AS NUMERIC(9,1)) ['1.4'] -> 2 (kept 11.2: none)" "SELECT ID FROM T WHERE BI * ? = CAST(8.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) BI under a SHORT slot, ? left KEEPS: ? * BI = CAST(11.2 AS NUMERIC(4,1)) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * BI = CAST(11.2 AS NUMERIC(4,1))" '["1.4"]'
both "4l(a) BI under a SHORT slot, ? right ROUNDS: BI * ? = CAST(8.0 AS NUMERIC(4,1)) ['1.4'] -> 2" "SELECT ID FROM T WHERE BI * ? = CAST(8.0 AS NUMERIC(4,1))" '["1.4"]'
both "4l(a) SM (SMALLINT column) narrow, ? left ROUNDS: ? * SM = CAST(3.0 AS NUMERIC(9,1)) ['1.4'] -> 3 (kept 4.2: none)" "SELECT ID FROM TS WHERE ? * SM = CAST(3.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) SM narrow, ? right KEEPS: SM * ? = CAST(4.2 AS NUMERIC(9,1)) ['1.4'] -> 3" "SELECT ID FROM TS WHERE SM * ? = CAST(4.2 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) a JOIN side's column a.ID narrow, ? left ROUNDS -> 2" "SELECT a.ID FROM T a JOIN T b ON a.ID = b.ID WHERE ? * a.ID = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) a JOIN side's column b.BI wide, ? right ROUNDS: b.BI * ? = CAST(8.0 ..) -> 2" "SELECT a.ID FROM T a JOIN T b ON a.ID = b.ID WHERE b.BI * ? = CAST(8.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) a JOIN side's column b.BI wide, ? left KEEPS: ? * b.BI = CAST(11.2 ..) -> 2" "SELECT a.ID FROM T a JOIN T b ON a.ID = b.ID WHERE ? * b.BI = CAST(11.2 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) a GROUP BY key in HAVING, ID narrow, ? left ROUNDS -> 2" "SELECT ID FROM T GROUP BY ID HAVING ? * ID = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) a GROUP BY key in HAVING, ID narrow, ? right KEEPS -> 2" "SELECT ID FROM T GROUP BY ID HAVING ID * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(a) a GROUP BY key in HAVING, BI wide, ? left KEEPS: ? * BI = CAST(11.2 ..) -> 8" "SELECT BI FROM T GROUP BY BI HAVING ? * BI = CAST(11.2 AS NUMERIC(9,1))" '["1.4"]'
# (b) an integer literal: 4 bytes when it fits i32, else 8
both "4l(b) 2 narrow, ? left ROUNDS: ? * 2 = CAST(2.0 AS NUMERIC(9,1)) ['1.4'] -> 1;2;3 (kept 2.8: none)" "SELECT ID FROM T WHERE ? * 2 = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(b) 2 narrow, ? right KEEPS: 2 * ? = CAST(2.8 AS NUMERIC(9,1)) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE 2 * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(b) 2 under a SHORT slot, ? left ROUNDS -> 1;2;3" "SELECT ID FROM T WHERE ? * 2 = CAST(2.0 AS NUMERIC(4,1))" '["1.4"]'
both "4l(b) 2 under a SHORT slot, ? right KEEPS -> 1;2;3" "SELECT ID FROM T WHERE 2 * ? = CAST(2.8 AS NUMERIC(4,1))" '["1.4"]'
both "4l(b) 2147483647 narrow (fits i32), ? left ROUNDS to 0: ? * 2147483647 <> 0.0 ['0.4'] -> none" "SELECT ID FROM T WHERE ? * 2147483647 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(b) 2147483647 narrow, ? right KEEPS: 2147483647 * ? <> 0.0 ['0.4'] -> 1;2;3" "SELECT ID FROM T WHERE 2147483647 * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(b) 2147483648 wide (past i32), ? left KEEPS: ? * 2147483648 <> 0.0 ['0.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * 2147483648 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(b) 2147483648 wide, ? right ROUNDS to 0: 2147483648 * ? <> 0.0 ['0.4'] -> none" "SELECT ID FROM T WHERE 2147483648 * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(b) 5000000000 under an INT64 slot, ? left KEEPS: = CAST(2000000000.0 AS NUMERIC(18,1)) ['0.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * 5000000000 = CAST(2000000000.0 AS NUMERIC(18,1))" '["0.4"]'
both "4l(b) -2 narrow (a negated literal), ? left ROUNDS: ? * -2 = CAST(-2.0 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * -2 = CAST(-2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(b) -2 narrow, ? right KEEPS: -2 * ? = CAST(-2.8 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE -2 * ? = CAST(-2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(b) -3000000000 wide under an INT64 slot, ? left KEEPS -> 1;2;3" "SELECT ID FROM T WHERE ? * -3000000000 = CAST(-1200000000.0 AS NUMERIC(18,1))" '["0.4"]'
# (c) a scaled decimal literal: 4 bytes when its UNSCALED integer fits
# i32 (the BLR blr_long, not the INT64 the projection describes)
both "4l(c) 1.5 narrow, ? left ROUNDS: ? * 1.5 = CAST(1.5 AS NUMERIC(9,1)) ['1.4'] -> 1;2;3 (kept 2.1: none)" "SELECT ID FROM T WHERE ? * 1.5 = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(c) 1.5 narrow, ? right KEEPS: 1.5 * ? = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE 1.5 * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
both "4l(c) 1.5 under a SHORT slot, ? left ROUNDS -> 1;2;3" "SELECT ID FROM T WHERE ? * 1.5 = CAST(1.5 AS NUMERIC(4,1))" '["1.4"]'
both "4l(c) 1.5 under a SHORT slot, ? right KEEPS -> 1;2;3" "SELECT ID FROM T WHERE 1.5 * ? = CAST(2.1 AS NUMERIC(4,2))" '["1.4"]'
both "4l(c) 0.25 narrow against the NM slot, ? left ROUNDS: ? * 0.25 = NM ['28.5'] -> 1 (29 * 0.25)" "SELECT ID FROM T WHERE ? * 0.25 = NM" '["28.5"]'
both "4l(c) 0.25 narrow, ? right KEEPS: 0.25 * ? = NM ['29'] -> 1" "SELECT ID FROM T WHERE 0.25 * ? = NM" '["29"]'
both "4l(c) 1.50000 (five decimals, unscaled 150000) narrow, ? left ROUNDS -> 1;2;3" "SELECT ID FROM T WHERE ? * 1.50000 = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(c) -1.5 narrow (under a minus), ? left ROUNDS: ? * -1.5 = CAST(-1.5 ..) -> 1;2;3" "SELECT ID FROM T WHERE ? * -1.5 = CAST(-1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(c) -1.5 narrow, ? right KEEPS: -1.5 * ? = CAST(-2.1 AS NUMERIC(9,2)) -> 1;2;3" "SELECT ID FROM T WHERE -1.5 * ? = CAST(-2.1 AS NUMERIC(9,2))" '["1.4"]'
both "4l(c) - -1.5 (two minuses) narrow, ? left ROUNDS -> 1;2;3" "SELECT ID FROM T WHERE ? * - -1.5 = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(c) -(1.5) narrow, ? right KEEPS -> 1;2;3" "SELECT ID FROM T WHERE -(1.5) * ? = CAST(-2.1 AS NUMERIC(9,2))" '["1.4"]'
both "4l(c) 214748364.7 narrow (unscaled 2147483647), ? right KEEPS: <> 0.0 ['0.4'] -> 1;2;3" "SELECT ID FROM T WHERE 214748364.7 * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(c) 214748364.8 wide (unscaled 2147483648), ? right ROUNDS to 0: <> 0.0 ['0.4'] -> none" "SELECT ID FROM T WHERE 214748364.8 * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(c) -214748364.8 NARROW (the signed value fits i32), ? left ROUNDS to 0 -> none" "SELECT ID FROM T WHERE ? * -214748364.8 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(c) -214748364.8 narrow, ? right KEEPS -> 1;2;3" "SELECT ID FROM T WHERE -214748364.8 * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(c) 99999.99999 wide (unscaled 9999999999), ? left KEEPS -> 1;2;3" "SELECT ID FROM T WHERE ? * 99999.99999 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(c) 99999.99999 wide, ? right ROUNDS to 0 -> none" "SELECT ID FROM T WHERE 99999.99999 * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "4l(c) -99999.99999 wide, ? left KEEPS -> 1;2;3" "SELECT ID FROM T WHERE ? * -99999.99999 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
# (d) an explicit CAST to an exact type, at the target's width
both "4l(d) CAST(ID AS SMALLINT) narrow, ? left ROUNDS -> 2" "SELECT ID FROM T WHERE ? * CAST(ID AS SMALLINT) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(ID AS SMALLINT) narrow, ? right KEEPS -> 2" "SELECT ID FROM T WHERE CAST(ID AS SMALLINT) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(NM AS INTEGER) narrow, ? left ROUNDS: = CAST(7.0 ..) -> 1" "SELECT ID FROM T WHERE ? * CAST(NM AS INTEGER) = CAST(7.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(NM AS INTEGER) narrow, ? right KEEPS: = CAST(9.8 ..) -> 1" "SELECT ID FROM T WHERE CAST(NM AS INTEGER) * ? = CAST(9.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(ID AS BIGINT) wide, ? left KEEPS: = CAST(2.8 ..) -> 2" "SELECT ID FROM T WHERE ? * CAST(ID AS BIGINT) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(ID AS BIGINT) wide, ? right ROUNDS: = CAST(2.0 ..) -> 2" "SELECT ID FROM T WHERE CAST(ID AS BIGINT) * ? = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(1.5 AS NUMERIC(9,1)) narrow, ? left ROUNDS -> 1;2;3" "SELECT ID FROM T WHERE ? * CAST(1.5 AS NUMERIC(9,1)) = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(1.5 AS NUMERIC(9,1)) narrow, ? right KEEPS -> 1;2;3" "SELECT ID FROM T WHERE CAST(1.5 AS NUMERIC(9,1)) * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
both "4l(d) CAST(1.5 AS NUMERIC(18,1)) wide, ? left KEEPS: = CAST(2.1 AS NUMERIC(9,2)) -> 1;2;3" "SELECT ID FROM T WHERE ? * CAST(1.5 AS NUMERIC(18,1)) = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
both "4l(d) CAST(1.5 AS NUMERIC(18,1)) wide, ? right ROUNDS: = CAST(1.5 ..) -> 1;2;3" "SELECT ID FROM T WHERE CAST(1.5 AS NUMERIC(18,1)) * ? = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(1.5 AS NUMERIC(4,1)) narrow (SHORT), ? left ROUNDS -> 1;2;3" "SELECT ID FROM T WHERE ? * CAST(1.5 AS NUMERIC(4,1)) = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(d) CAST(2 AS SMALLINT) narrow, ? right KEEPS -> 1;2;3" "SELECT ID FROM T WHERE CAST(2 AS SMALLINT) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
# (e) another direct ?, at the slot's own width
both "4l(e) ? * ? under a LONG slot: the LEFT rounds: = CAST(6.0 ..) ['2.5', '2'] -> 1;2;3 (3 * 2)" "SELECT ID FROM T WHERE ? * ? = CAST(6.0 AS NUMERIC(9,1))" '["2.5", "2"]'
both "4l(e) ? * ? under a LONG slot: the RIGHT keeps: = CAST(5.0 ..) ['2', '2.5'] -> 1;2;3 (2 * 2.5)" "SELECT ID FROM T WHERE ? * ? = CAST(5.0 AS NUMERIC(9,1))" '["2", "2.5"]'
both "4l(e) ? * ? <> 0.0 ['0.4', '1'] -> none (the left rounds to 0)" "SELECT ID FROM T WHERE ? * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4", "1"]'
both "4l(e) ? * ? <> 0.0 ['1', '0.4'] -> 1;2;3 (the right keeps)" "SELECT ID FROM T WHERE ? * ? <> CAST(0.0 AS NUMERIC(9,1))" '["1", "0.4"]'
both "4l(e) ? * ? under a SHORT slot: = CAST(6.0 AS NUMERIC(4,1)) ['2.5', '2'] -> 1;2;3" "SELECT ID FROM T WHERE ? * ? = CAST(6.0 AS NUMERIC(4,1))" '["2.5", "2"]'
both "4l(e) ? * ? under an INT64 slot: the RIGHT rounds: = 5.0 ['2.5', '2'] -> 1;2;3" "SELECT ID FROM T WHERE ? * ? = 5.0" '["2.5", "2"]'
# (f) HAVING folds: COUNT / SUM / AVG are 8 bytes, MIN / MAX over a base
# column take the column's width
both "4l(f) HAVING COUNT(*) wide, ? left KEEPS: ? * COUNT(*) = CAST(1.4 ..) -> 1;2;3" "SELECT ID FROM T GROUP BY ID HAVING ? * COUNT(*) = CAST(1.4 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING COUNT(*) wide, ? right ROUNDS: COUNT(*) * ? = CAST(1.0 ..) -> 1;2;3" "SELECT ID FROM T GROUP BY ID HAVING COUNT(*) * ? = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING COUNT(ID) wide, ? left KEEPS -> 1;2;3" "SELECT ID FROM T GROUP BY ID HAVING ? * COUNT(ID) = CAST(1.4 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING COUNT(DISTINCT ID) wide, ? right ROUNDS -> 1;2;3" "SELECT ID FROM T GROUP BY ID HAVING COUNT(DISTINCT ID) * ? = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING SUM(ID) wide, ? left KEEPS: = CAST(2.8 ..) -> 2" "SELECT ID FROM T GROUP BY ID HAVING ? * SUM(ID) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING SUM(ID) wide, ? right ROUNDS: = CAST(2.0 ..) -> 2" "SELECT ID FROM T GROUP BY ID HAVING SUM(ID) * ? = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING AVG(ID) wide, ? right ROUNDS -> 2" "SELECT ID FROM T GROUP BY ID HAVING AVG(ID) * ? = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING SUM(NM) wide, ? left KEEPS: = CAST(3.5 AS NUMERIC(9,2)) -> 3" "SELECT ID FROM T GROUP BY ID HAVING ? * SUM(NM) = CAST(3.5 AS NUMERIC(9,2))" '["1.4"]'
both "4l(f) HAVING MIN(ID) narrow, ? left ROUNDS: = CAST(2.0 ..) -> 2" "SELECT ID FROM T GROUP BY ID HAVING ? * MIN(ID) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING MIN(ID) narrow, ? right KEEPS: = CAST(2.8 ..) -> 2" "SELECT ID FROM T GROUP BY ID HAVING MIN(ID) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING MAX(NM) narrow, ? left ROUNDS: = CAST(2.5 AS NUMERIC(9,2)) -> 3" "SELECT ID FROM T GROUP BY ID HAVING ? * MAX(NM) = CAST(2.5 AS NUMERIC(9,2))" '["1.4"]'
both "4l(f) HAVING MAX(NM) narrow, ? right KEEPS: = CAST(3.5 AS NUMERIC(9,2)) -> 3" "SELECT ID FROM T GROUP BY ID HAVING MAX(NM) * ? = CAST(3.5 AS NUMERIC(9,2))" '["1.4"]'
both "4l(f) HAVING MIN(BI) wide, ? left KEEPS: = CAST(11.2 ..) -> 2" "SELECT ID FROM T GROUP BY ID HAVING ? * MIN(BI) = CAST(11.2 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING MIN(BI) wide, ? right ROUNDS: = CAST(8.0 ..) -> 2" "SELECT ID FROM T GROUP BY ID HAVING MIN(BI) * ? = CAST(8.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING MIN(SM) narrow (SHORT column), ? left ROUNDS: = CAST(3.0 ..) -> 3" "SELECT ID FROM TS GROUP BY ID HAVING ? * MIN(SM) = CAST(3.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(f) HAVING MAX(N) narrow, ? right KEEPS: = CAST(4.2 ..) -> 1" "SELECT ID FROM T GROUP BY ID HAVING MAX(N) * ? = CAST(4.2 AS NUMERIC(9,1))" '["1.4"]'
# (g) parentheses around a listed shape
both "4l(g) ? * (2) -> 1;2;3" "SELECT ID FROM T WHERE ? * (2) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(g) ? * (ID) -> 2" "SELECT ID FROM T WHERE ? * (ID) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(g) (2) * ? -> 1;2;3" "SELECT ID FROM T WHERE (2) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
both "4l(g) ? * (BI) wide -> 2" "SELECT ID FROM T WHERE ? * (BI) = CAST(11.2 AS NUMERIC(9,1))" '["1.4"]'
both "4l(g) ((1.5)) * ? -> 1;2;3" "SELECT ID FROM T WHERE ((1.5)) * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
both "4l(g) ? * (-1.5) -> 1;2;3" "SELECT ID FROM T WHERE ? * (-1.5) = CAST(-1.5 AS NUMERIC(9,1))" '["1.4"]'
both "4l(g) ? * (CAST(ID AS SMALLINT)) -> 2" "SELECT ID FROM T WHERE ? * (CAST(ID AS SMALLINT)) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l(g) HAVING ? * (MIN(ID)) -> 2" "SELECT ID FROM T GROUP BY ID HAVING ? * (MIN(ID)) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
# (g) BOUNDARY: a parenthesised COLUMN as the LEFT operand of the `*`
# refuses on both binaries (a parse boundary, not the width helper's:
# `(2) * ?` and `? * (ID)` answer) - recorded with the engine's value
eng_only "4l(g) boundary: (ID) * ? = CAST(2.8 ..) ['1.4'] (engine 2; a parenthesised column before the * is a parse boundary on both binaries)" "SELECT ID FROM T WHERE (ID) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l(g) boundary: (BI) * ? = CAST(8.0 ..) ['1.4'] (engine 2)" "SELECT ID FROM T WHERE (BI) * ? = CAST(8.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l(g) boundary: ((ID)) * ? = CAST(2.8 ..) ['1.4'] (engine 2)" "SELECT ID FROM T WHERE ((ID)) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l(g) boundary: NN > 0 AND (ID) * ? = CAST(2.8 ..) ['1.4'] (engine 2)" "SELECT ID FROM T WHERE NN > 0 AND (ID) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l(g) boundary: IIF((ID) * ? = CAST(2.8 ..), 1, 0) = 1 ['1.4'] (engine 2)" "SELECT ID FROM T WHERE IIF((ID) * ? = CAST(2.8 AS NUMERIC(9,1)), 1, 0) = 1" '["1.4"]'
# an APPROXIMATE sibling is never sized: the node is DOUBLE and no
# operand rounds (the approximate rung, unchanged by the whitelist)
eng_only "R12 cap: K3: 4l approx: ? * 1.5e0 = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> none (a DOUBLE compare, 1.4 * 1.5 is not 2.1 exactly)" "SELECT ID FROM T WHERE ? * 1.5e0 = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "R12 cap: K3: 4l approx: 1.5e0 * ? = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> none" "SELECT ID FROM T WHERE 1.5e0 * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "R12 cap: K3: 4l approx: ? * CAST(1.5 AS DOUBLE PRECISION) = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> none" "SELECT ID FROM T WHERE ? * CAST(1.5 AS DOUBLE PRECISION) = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "R12 cap: K3: 4l approx: ? * PI() > CAST(4.0 AS NUMERIC(9,1)) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * PI() > CAST(4.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "R12 cap: K3: 4l approx: ? * D = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> none" "SELECT ID FROM T WHERE ? * D = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
# the whitelist in DML, under rollback
dml_rb "4l DML: UPDATE T SET N = 99 WHERE ? * BI = CAST(11.2 AS NUMERIC(9,1)) ['1.4'] -> row 2 (the left keeps beside BI)" "UPDATE T SET N = 99 WHERE ? * BI = CAST(11.2 AS NUMERIC(9,1))" '["1.4"]'
dml_rb "4l DML: DELETE FROM T WHERE CAST(ID AS SMALLINT) * ? = CAST(2.8 AS NUMERIC(9,1)) ['1.4'] -> row 2 gone (the right keeps beside a SHORT cast)" "DELETE FROM T WHERE CAST(ID AS SMALLINT) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
dml_rb "4l DML: UPDATE T SET N = 99 WHERE ? * ? = CAST(6.0 AS NUMERIC(9,1)) ['2.5', '2'] -> every row (the left rounds to 3)" "UPDATE T SET N = 99 WHERE ? * ? = CAST(6.0 AS NUMERIC(9,1))" '["2.5", "2"]'
dml_rb "4l DML: INSERT INTO T (ID, NN) SELECT ID + 10, 1 FROM T WHERE ? * 1.5 = CAST(1.5 AS NUMERIC(9,1)) ['1.4'] -> 11;12;13 inserted (the left rounds to 1)" "INSERT INTO T (ID, NN) SELECT ID + 10, 1 FROM T WHERE ? * 1.5 = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]' "SELECT ID FROM T ORDER BY ID"
both "4l fixture survived the DML cells" "SELECT ID, N FROM T ORDER BY ID"
# THE BOUNDARY: every family OFF the whitelist refuses at PREPARE on
# this binary (and refused on the previous committed one) while the
# engine answers - each cell carries the engine's value so a future
# promotion has its expectation; the widths named are the engine's
# measured ones (gx4-bd.out), NOT what the round-3 table assumed
eng_only "4l boundary ABS(ID) (engine INT64, wide): ? * ABS(ID) = CAST(2.8 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * ABS(ID) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary ABS(ID): ABS(ID) * ? = CAST(2.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ABS(ID) * ? = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary ABS(SM) (makeAbs SHORT -> LONG, narrow): ? * ABS(SM) = CAST(3.0 ..) ['1.4'] -> 3" "SELECT ID FROM TS WHERE ? * ABS(SM) = CAST(3.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary SIGN(ID) (SHORT, narrow): ? * SIGN(ID) = CAST(1.0 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * SIGN(ID) = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary SIGN(ID): SIGN(ID) * ? = CAST(1.4 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE SIGN(ID) * ? = CAST(1.4 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary SIGN(D): SIGN(D) * ? <> 0.0 ['0.4'] -> 1;2;3" "SELECT ID FROM T WHERE SIGN(D) * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
eng_only "4l boundary MOD(ID, 2) (narrow): ? * MOD(ID, 2) = CAST(1.0 ..) ['1.4'] -> 1;3" "SELECT ID FROM T WHERE ? * MOD(ID, 2) = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary MOD(D, 2) (INT64, wide): MOD(D, 2) * ? <> 0.0 ['0.4'] -> none" "SELECT ID FROM T WHERE MOD(D, 2) * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
eng_only "4l boundary ROUND(NM, 1) (narrow): ? * ROUND(NM, 1) = CAST(1.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * ROUND(NM, 1) = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary ROUND(1.5) (narrow): ROUND(1.5) * ? = CAST(2.8 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ROUND(1.5) * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary TRUNC(1.5) (narrow): ? * TRUNC(1.5) = CAST(1.0 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * TRUNC(1.5) = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary COALESCE(1.5, 0) (narrow): ? * COALESCE(1.5, 0) = CAST(1.5 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * COALESCE(1.5, 0) = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary COALESCE(NM, 0) (narrow): COALESCE(NM, 0) * ? = CAST(1.4 AS NUMERIC(9,2)) ['1.4'] -> 2" "SELECT ID FROM T WHERE COALESCE(NM, 0) * ? = CAST(1.4 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary NULLIF(ID, 0) (wide): ? * NULLIF(ID, 0) = CAST(2.8 ..) ['1.4'] -> none" "SELECT ID FROM T WHERE ? * NULLIF(ID, 0) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary NULLIF(1.5, 0) (wide): NULLIF(1.5, 0) * ? = CAST(1.5 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE NULLIF(1.5, 0) * ? = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary IIF(NN = 5, 1, 2) (wide): ? * IIF(..) = CAST(1.4 ..) ['1.4'] -> none" "SELECT ID FROM T WHERE ? * IIF(NN = 5, 1, 2) = CAST(1.4 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary IIF(NN = 5, 1.5, 2.5) (wide): IIF(..) * ? = CAST(1.5 ..) ['1.4'] -> 1" "SELECT ID FROM T WHERE IIF(NN = 5, 1.5, 2.5) * ? = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary searched CASE (wide): ? * CASE WHEN NN = 5 THEN 1 ELSE 2 END = CAST(1.4 ..) ['1.4'] -> none" "SELECT ID FROM T WHERE ? * CASE WHEN NN = 5 THEN 1 ELSE 2 END = CAST(1.4 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary searched CASE with literals (wide): CASE WHEN NN = 5 THEN 1.5 ELSE 2.5 END * ? = CAST(1.5 ..) ['1.4'] -> 1" "SELECT ID FROM T WHERE CASE WHEN NN = 5 THEN 1.5 ELSE 2.5 END * ? = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary simple CASE (narrow): ? * CASE NN WHEN 5 THEN 1 ELSE 2 END = CAST(1.0 ..) ['1.4'] -> 1" "SELECT ID FROM T WHERE ? * CASE NN WHEN 5 THEN 1 ELSE 2 END = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary DECODE (narrow): ? * DECODE(NN, 5, 1, 2) = CAST(1.0 ..) ['1.4'] -> 1" "SELECT ID FROM T WHERE ? * DECODE(NN, 5, 1, 2) = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary arithmetic (ID + 0) (wide): ? * (ID + 0) = CAST(2.8 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * (ID + 0) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary arithmetic (ID * 1) (wide): (ID * 1) * ? = CAST(2.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE (ID * 1) * ? = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary arithmetic (1.5 + 0) (wide): ? * (1.5 + 0) = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * (1.5 + 0) = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary scalar subquery (SELECT b.ID .. = 2) (narrow): ? * (..) = CAST(2.0 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * (SELECT b.ID FROM T b WHERE b.ID = 2) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary scalar subquery (SELECT 1.5 FROM RDB\$DATABASE) (narrow): (..) * ? = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE (SELECT 1.5 FROM RDB\$DATABASE) * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary correlated scalar subquery (narrow): ? * (SELECT b.ID .. b.ID = T.ID) = CAST(2.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * (SELECT b.ID FROM T b WHERE b.ID = T.ID) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary derived column d.L over 1.5 (narrow through the alias): ? * d.L = CAST(1.5 ..) ['1.4'] -> 1;2;3" "SELECT d.ID FROM (SELECT ID, 1.5 AS L FROM T) d WHERE ? * d.L = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary derived column d.L: d.L * ? = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> 1;2;3" "SELECT d.ID FROM (SELECT ID, 1.5 AS L FROM T) d WHERE d.L * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary derived column d.ID (a base column through the alias, narrow): ? * d.ID = CAST(2.0 ..) ['1.4'] -> 2" "SELECT d.ID FROM (SELECT ID, 1.5 AS L FROM T) d WHERE ? * d.ID = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary derived column d.NM (narrow): d.NM * ? = CAST(1.4 AS NUMERIC(9,2)) ['1.4'] -> 2" "SELECT d.ID FROM (SELECT ID, NM FROM T) d WHERE d.NM * ? = CAST(1.4 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary UNION column d.L (narrow: every branch narrow): ? * d.L <> 0.0 ['0.4'] -> none" "SELECT d.ID FROM (SELECT ID, 1.5 AS L FROM T UNION ALL SELECT ID, 2.5 FROM T) d WHERE ? * d.L <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
eng_only "4l boundary CTE column q.L (narrow): ? * q.L = CAST(1.5 ..) ['1.4'] -> 1;2;3" "WITH q AS (SELECT ID, 1.5 AS L FROM T) SELECT ID FROM q WHERE ? * q.L = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary CTE column q.L: q.L * ? = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> 1;2;3" "WITH q AS (SELECT ID, 1.5 AS L FROM T) SELECT ID FROM q WHERE q.L * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary CTE column q.ID (narrow): ? * q.ID = CAST(2.0 ..) ['1.4'] -> 2" "WITH q AS (SELECT ID, 1.5 AS L FROM T) SELECT ID FROM q WHERE ? * q.ID = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary view column V.L over 1.5 (narrow): ? * V.L = CAST(1.5 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM V WHERE ? * V.L = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary view column V.L: V.L * ? = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> 1;2;3" "SELECT ID FROM V WHERE V.L * ? = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary view column L unqualified: ? * L = CAST(1.5 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM V WHERE ? * L = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary view column V.ID (a base column through the view, narrow): ? * V.ID = CAST(2.0 ..) ['1.4'] -> 2" "SELECT ID FROM V WHERE ? * V.ID = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary view column V.SH over CAST(ID AS SMALLINT) (narrow): V.SH * ? = CAST(2.8 ..) ['1.4'] -> 2" "SELECT ID FROM V WHERE V.SH * ? = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary view column V.NM (narrow): V.NM * ? = CAST(1.4 AS NUMERIC(9,2)) ['1.4'] -> 2" "SELECT ID FROM V WHERE V.NM * ? = CAST(1.4 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary view column V.BI (wide): ? * V.BI = CAST(11.2 ..) ['1.4'] -> 2" "SELECT ID FROM V WHERE ? * V.BI = CAST(11.2 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary EXTRACT(MONTH FROM DT) (narrow; this server's parse takes DT for a table): ? * EXTRACT(..) = CAST(2.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * EXTRACT(MONTH FROM DT) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary CHAR_LENGTH(S) (narrow): ? * CHAR_LENGTH(S) = CAST(2.0 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * CHAR_LENGTH(S) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary CEIL(ID) (wide): ? * CEIL(ID) = CAST(2.8 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * CEIL(ID) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary FLOOR(NM) (wide): FLOOR(NM) * ? = CAST(1.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE FLOOR(NM) * ? = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary MAXVALUE(1.5, 2) (narrow): ? * MAXVALUE(1.5, 2) = CAST(2.0 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * MAXVALUE(1.5, 2) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary BIT_LENGTH(S) (narrow): ? * BIT_LENGTH(S) = CAST(16.0 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * BIT_LENGTH(S) = CAST(16.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary HAVING MIN(1.5) (narrow): ? * MIN(1.5) = CAST(1.5 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T GROUP BY ID HAVING ? * MIN(1.5) = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary HAVING MAX(ID + 0) (wide): ? * MAX(ID + 0) = CAST(2.8 ..) ['1.4'] -> 2" "SELECT ID FROM T GROUP BY ID HAVING ? * MAX(ID + 0) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary HAVING MIN(d.L) over a derived column (narrow): ? * MIN(d.L) = CAST(1.5 ..) ['1.4'] -> 1;2;3" "SELECT d.ID FROM (SELECT ID, 1.5 AS L FROM T) d GROUP BY d.ID HAVING ? * MIN(d.L) = CAST(1.5 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary HAVING (COUNT(*) + 0) arithmetic over a fold (wide): ? * (COUNT(*) + 0) = CAST(1.4 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T GROUP BY ID HAVING ? * (COUNT(*) + 0) = CAST(1.4 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary CAST(1.5 AS DECFLOAT(16)): ? * (..) = CAST(2.1 AS NUMERIC(9,2)) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * CAST(1.5 AS DECFLOAT(16)) = CAST(2.1 AS NUMERIC(9,2))" '["1.4"]'
eng_only "4l boundary CAST(2 AS INT128): ? * (..) = CAST(2.8 ..) ['1.4'] -> 1;2;3" "SELECT ID FROM T WHERE ? * CAST(2 AS INT128) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary ? * ABS(?) (a function over the other ?): = CAST(2.0 ..) ['1.4', '1.4'] -> none (engine: a DOUBLE slot for the second)" "SELECT ID FROM T WHERE ? * ABS(?) = CAST(2.0 AS NUMERIC(9,1))" '["1.4", "1.4"]'
eng_only "4l boundary a NEGATED column -ID: ? * -ID = CAST(-2.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * -ID = CAST(-2.0 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary -ID * ? = CAST(-2.8 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE -ID * ? = CAST(-2.8 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary ? * -BI = CAST(-11.2 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * -BI = CAST(-11.2 AS NUMERIC(9,1))" '["1.4"]'
eng_only "4l boundary ? * -CAST(ID AS SMALLINT) = CAST(-2.0 ..) ['1.4'] -> 2" "SELECT ID FROM T WHERE ? * -CAST(ID AS SMALLINT) = CAST(-2.0 AS NUMERIC(9,1))" '["1.4"]'
# the boundary in DML: the engine's rows under rollback, this server
# refuses at prepare (the round-3 table mutated the WRONG rows here)
dml_rb_eng_only "4l boundary DML: UPDATE T SET N = 99 WHERE ? * ABS(ID) = CAST(2.8 ..) ['1.4'] (engine: row 2)" "UPDATE T SET N = 99 WHERE ? * ABS(ID) = CAST(2.8 AS NUMERIC(9,1))" '["1.4"]'
dml_rb_eng_only "4l boundary DML: INSERT INTO T (ID, NN) SELECT d.ID + 10, 1 FROM (SELECT ID, 1.5 AS L FROM T) d WHERE ? * d.L = CAST(4.5 ..) ['2.5'] (engine: 11;12;13 inserted; the table inserted none)" "INSERT INTO T (ID, NN) SELECT d.ID + 10, 1 FROM (SELECT ID, 1.5 AS L FROM T) d WHERE ? * d.L = CAST(4.5 AS NUMERIC(9,1))" '["2.5"]' "SELECT ID FROM T ORDER BY ID"
dml_rb_eng_only "4l boundary DML: UPDATE T SET N = 99 WHERE ? * MOD(ID, 2) = CAST(1.0 ..) ['1.4'] (engine: rows 1 and 3)" "UPDATE T SET N = 99 WHERE ? * MOD(ID, 2) = CAST(1.0 AS NUMERIC(9,1))" '["1.4"]'
both "4l fixture survived the boundary DML cells" "SELECT ID, N FROM T ORDER BY ID"
# X2 IN FULL: a DATE / TIME / TIMESTAMP whole side bound from node's
# blr_timestamp message compares at the MESSAGE's type (a DATE at
# midnight, a TIME with the session date), never through a truncating
# CAST into the slot - every spelling node parses arrives that way
both "X2 DT = ? ['2024-01-10'] (a date-only string is midnight) -> 1" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10"]'
both "X2 DT = ? ['2024-01-10 00:00:00.5'] -> 1 (node sends whole seconds: the message is midnight)" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10 00:00:00.5"]'
both "X2 DT = ? ['2024-01-10 12:30'] -> none" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10 12:30"]'
both "X2 DT = ? ['2024-01-10T12:30:00'] -> none" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10T12:30:00"]'
both "X2 DT = ? ['2024-01-10 12:30:00.5'] -> none" "SELECT ID FROM T WHERE IIF(DT = ?, 1, 0) = 1" '["2024-01-10 12:30:00.5"]'
both "X2 IIF(DT <> ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 1;2;3 (the cast said 2;3)" "SELECT ID FROM T WHERE IIF(DT <> ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 IIF(DT >= ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 2;3 (the cast said 1;2;3)" "SELECT ID FROM T WHERE IIF(DT >= ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 IIF(? = DT, 1, 0) = 1 ['2024-01-10 12:30:00'] -> none (the ? on the left)" "SELECT ID FROM T WHERE IIF(? = DT, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 IIF(? <= DT, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 2;3" "SELECT ID FROM T WHERE IIF(? <= DT, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 SELECT IIF(DT = ?, 1, 0) AS X ['2024-01-10 12:30:00'] -> 0;0;0 (select list)" "SELECT IIF(DT = ?, 1, 0) AS X FROM T ORDER BY ID" '["2024-01-10 12:30:00"]'
both "X2 SELECT IIF(DT = ?, 1, 0) AS X ['2024-01-10 00:00:00'] -> 1;0;0" "SELECT IIF(DT = ?, 1, 0) AS X FROM T ORDER BY ID" '["2024-01-10 00:00:00"]'
both "X2 HAVING IIF(MIN(DT) = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> none" "SELECT ID FROM T GROUP BY ID HAVING IIF(MIN(DT) = ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 HAVING IIF(MIN(DT) = ?, 1, 0) = 1 ['2024-01-10 00:00:00'] -> 1" "SELECT ID FROM T GROUP BY ID HAVING IIF(MIN(DT) = ?, 1, 0) = 1" '["2024-01-10 00:00:00"]'
both "X2 CASE WHEN DT = ? THEN 1 ELSE 0 END = 1 ['2024-01-10 12:30:00'] -> none" "SELECT ID FROM T WHERE CASE WHEN DT = ? THEN 1 ELSE 0 END = 1" '["2024-01-10 12:30:00"]'
both "X2 CASE DT WHEN ? THEN 1 ELSE 0 END = 1 ['2024-01-10 12:30:00'] -> none (the simple form too)" "SELECT ID FROM T WHERE CASE DT WHEN ? THEN 1 ELSE 0 END = 1" '["2024-01-10 12:30:00"]'
both "X2 CASE DT WHEN ? THEN 1 ELSE 0 END = 1 ['2024-01-10 00:00:00'] -> 1" "SELECT ID FROM T WHERE CASE DT WHEN ? THEN 1 ELSE 0 END = 1" '["2024-01-10 00:00:00"]'
both "X2 control: classic DT = ? ['2024-01-10 12:30:00'] -> none (already agreed)" "SELECT ID FROM T WHERE DT = ?" '["2024-01-10 12:30:00"]'
both "X2 control: classic DT < ? ['2024-01-10 12:30:00'] -> 1" "SELECT ID FROM T WHERE DT < ?" '["2024-01-10 12:30:00"]'
both "X2 TIME slot: IIF(TM = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> none (a TIME promotes to TIMESTAMP with TODAY's date: never 2024)" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 TIME slot: IIF(TM = ?, 1, 0) = 1 ['2024-01-10 00:00:00'] -> none" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["2024-01-10 00:00:00"]'
both "X2 TIME slot: IIF(TM > ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 1;2;3 (today is after 2024-01-10; the cast said 3)" "SELECT ID FROM TS WHERE IIF(TM > ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 TIME slot: IIF(TM < ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> none (the cast said 2)" "SELECT ID FROM TS WHERE IIF(TM < ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 TIME slot: IIF(TM <> ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 1;2;3" "SELECT ID FROM TS WHERE IIF(TM <> ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 TIME slot: IIF(TM = ?, 1, 0) = 1 ['2024-01-10 12:30:00.0001'] -> none" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["2024-01-10 12:30:00.0001"]'
both "X2 TIME slot: IIF(TM = ?, 1, 0) = 1 ['12:30:00 +03:00'] -> none" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00 +03:00"]'
both "X2 TIME slot: IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> 1 (node parses a time-only string onto today's date: the promoted TIME matches)" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]'
both "X2 TIME slot: IIF(TM > ?, 1, 0) = 1 ['12:30:00'] -> 3" "SELECT ID FROM TS WHERE IIF(TM > ?, 1, 0) = 1" '["12:30:00"]'
both "X2 TIME slot: SELECT IIF(TM = ?, 1, 0) AS X ['2024-01-10 12:30:00'] -> 0;0;0" "SELECT IIF(TM = ?, 1, 0) AS X FROM TS ORDER BY ID" '["2024-01-10 12:30:00"]'
both "X2 TIMESTAMP slot: IIF(TSP = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> 1 (the message's own type)" "SELECT ID FROM TS WHERE IIF(TSP = ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
both "X2 TIMESTAMP slot: IIF(TSP = ?, 1, 0) = 1 ['2024-02-10 00:00:00'] -> 2" "SELECT ID FROM TS WHERE IIF(TSP = ?, 1, 0) = 1" '["2024-02-10 00:00:00"]'
both "X2 TIMESTAMP slot: IIF(TSP = ?, 1, 0) = 1 ['2024-02-10'] -> 2" "SELECT ID FROM TS WHERE IIF(TSP = ?, 1, 0) = 1" '["2024-02-10"]'
both "X2 TIMESTAMP slot: IIF(TSP < ?, 1, 0) = 1 ['2024-02-10 00:00:00'] -> 1" "SELECT ID FROM TS WHERE IIF(TSP < ?, 1, 0) = 1" '["2024-02-10 00:00:00"]'
both "X2 TIMESTAMP slot: IIF(TSP = ?, 1, 0) = 1 ['2024-03-10 12:30:00.5'] -> none (node sends whole seconds)" "SELECT ID FROM TS WHERE IIF(TSP = ?, 1, 0) = 1" '["2024-03-10 12:30:00.5"]'
both "X2 control: a SHORT whole side IIF(SM = ?, 1, 0) = 1 ['2'] -> 1" "SELECT ID FROM TS WHERE IIF(SM = ?, 1, 0) = 1" '["2"]'
dml_rb "X2 UPDATE T SET N = IIF(DT = ?, 99, N) ['2024-01-10 12:30:00'] -> unchanged (the cast set row 1)" "UPDATE T SET N = IIF(DT = ?, 99, N)" '["2024-01-10 12:30:00"]'
dml_rb "X2 UPDATE TS SET ID = 99 WHERE IIF(TM = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> unchanged (the cast set row 1)" "UPDATE TS SET ID = 99 WHERE IIF(TM = ?, 1, 0) = 1" '["2024-01-10 12:30:00"]' "SELECT ID FROM TS ORDER BY ID"
dml_rb "X2 UPDATE TS SET ID = 99 WHERE IIF(TSP = ?, 1, 0) = 1 ['2024-02-10 00:00:00'] -> row 2" "UPDATE TS SET ID = 99 WHERE IIF(TSP = ?, 1, 0) = 1" '["2024-02-10 00:00:00"]' "SELECT ID FROM TS ORDER BY ID"
# X3 IN FULL: the three spelling classes of a whole-side text inside a
# subquery body - the NUMERIC class reads as the compare grammar's
# number, the NO-MATCH class answers no row, the CONVERSION-ERROR class
# raises at execute on both (the same class as the engine); IN, EXISTS
# and scalar bodies, every slot type
both "X3 numeric '+2' into b.ID -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["+2"]'
both "X3 numeric '2.' into b.ID -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2."]'
boundary_err "R12 boundary: conversion error by design (K2): X3 numeric '2e0' into b.ID -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2e0"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 numeric ' 2 ' into b.ID -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '[" 2 "]'
boundary_err "R12 boundary: conversion error by design (K2): X3 numeric '25e-1' into b.D -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["25e-1"]'
both "X3 numeric '1.000' into b.NM -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.NM = ?, 1, 0) = 1)" '["1.000"]'
both "X3 numeric '8' into b.BI -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.BI = ?, 1, 0) = 1)" '["8"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '0XG' into b.ID -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["0XG"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '- 2' into b.ID -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["- 2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '1 2' into b.ID -> none (12)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["1 2"]'
both "X3 no-match '2.4' into b.ID -> none (a whole side is never rounded)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2.4"]'
both "X3 no-match '2.5' into b.ID -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2.5"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '2.0000000000000000001' into b.ID -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2.0000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '- 2.5' into b.D -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["- 2.5"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '0X2' into b.D -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '1e400' into b.D -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["1e400"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '0X2' into b.NM -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.NM = ?, 1, 0) = 1)" '["0X2"]'
both "X3 no-match '1.001' into b.NM -> none (a third decimal is kept whole)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.NM = ?, 1, 0) = 1)" '["1.001"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 no-match '0X2' into b.BI -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.BI = ?, 1, 0) = 1)" '["0X2"]'
both "X3 text slot: a quote inside the text into b.S ['a'b'] -> none (spelled back escaped)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" "[\"a'b\"]"
both "X3 text slot: 'cd' into b.S -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["cd"]'
both "X3 date slot: '2024-02-10' into b.DT -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.DT = ?, 1, 0) = 1)" '["2024-02-10"]'
both "X3 date slot: '2024-02-10 12:30:00' into b.DT -> none (X2's law inside the body)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.DT = ?, 1, 0) = 1)" '["2024-02-10 12:30:00"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 scalar body: ID = (SELECT b.ID .. AND IIF(b.D = ?, 1, 0) = 1) ['1 2'] -> none" "SELECT ID FROM T WHERE ID = (SELECT b.ID FROM T b WHERE b.ID = T.ID AND IIF(b.D = ?, 1, 0) = 1)" '["1 2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 scalar body: ID = (SELECT MAX(b.ID) .. IIF(b.D = ?, 1, 0) = 1) ['2 .5'] -> 2" "SELECT ID FROM T WHERE ID = (SELECT MAX(b.ID) FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["2 .5"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 EXISTS body: '0X2' into b.ID -> none" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T b WHERE b.ID = T.ID AND IIF(b.ID = ?, 1, 0) = 1)" '["0X2"]'
boundary_err "R12 boundary: conversion error by design (K2): X3 EXISTS body: '2 .5' into b.D -> 2" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T b WHERE b.ID = T.ID AND IIF(b.D = ?, 1, 0) = 1)" '["2 .5"]'
both_err "X3 conversion error: '' into b.ID (both prepare, both raise at execute)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '[""]'
both_err "X3 conversion error: a trailing quote into b.ID [2']" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" "[\"2'\"]"
both_err "X3 conversion error: two quotes into b.ID [2'']" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" "[\"2''\"]"
both_err "X3 conversion error: a block comment into b.ID ['2 /* x */']" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["2 /* x */"]'
both_err "X3 conversion error: 'abc' into b.D" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["abc"]'
both_err "X3 conversion error: '' into b.D" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '[""]'
both_err "X3 conversion error: '0x2' into b.D" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["0x2"]'
both_err "X3 conversion error: '2.5x' into b.D" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["2.5x"]'
both_err "X3 conversion error: an INTEGER bind into the TEXT slot b.S [2]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '[2]'
both_err "X3 conversion error in an EXISTS body: 'abc' into b.ID" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM T b WHERE b.ID = T.ID AND IIF(b.ID = ?, 1, 0) = 1)" '["abc"]'
dml_rb_eng_only "X3 DML: UPDATE T SET N = 99 WHERE ID IN (SELECT b.ID .. IIF(b.D = ?, 1, 0) = 1) ['2 .5'] (engine row 2; a whole-side ? in a DML's subquery body is refused at prepare on both binaries - recorded)" "UPDATE T SET N = 99 WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["2 .5"]'
# X4 IN FULL: SIGN and MOD over an approximate operand, every spelling,
# parameter-free (they prepared and failed at execute on both binaries)
both "X4 SIGN(-D) -> -1;-1;-1" "SELECT SIGN(-D) AS X FROM T ORDER BY ID"
both "X4 SIGN(D * 1) -> 1;1;1" "SELECT SIGN(D * 1) AS X FROM T ORDER BY ID"
both "X4 SIGN(CAST(D AS FLOAT)) -> 1;1;1" "SELECT SIGN(CAST(D AS FLOAT)) AS X FROM T ORDER BY ID"
both "X4 SIGN(1.5e0) -> 1" "SELECT SIGN(1.5e0) AS X FROM RDB\$DATABASE"
both "X4 SIGN(0e0) -> 0" "SELECT SIGN(0e0) AS X FROM RDB\$DATABASE"
both "X4 SIGN(PI()) -> 1" "SELECT SIGN(PI()) AS X FROM RDB\$DATABASE"
both "X4 COALESCE(SIGN(D), 0) -> 1;1;1" "SELECT COALESCE(SIGN(D), 0) AS X FROM T ORDER BY ID"
both "X4 MOD(D, 2.5) -> 2;0;1 (both operands rounded first: 2 mod 3, 3 mod 3, 4 mod 3)" "SELECT MOD(D, 2.5) AS X FROM T ORDER BY ID"
both "X4 MOD(2, D) -> 0;2;2 (LONG: the double divisor rounds to 2, 3, 4)" "SELECT MOD(2, D) AS X FROM T ORDER BY ID"
both "X4 MOD(BI, D) -> 1;2;3" "SELECT MOD(BI, D) AS X FROM T ORDER BY ID"
both "X4 WHERE 1 * MOD(D, 2) <> CAST(0.0 AS NUMERIC(9,1)) -> 2" "SELECT ID FROM T WHERE 1 * MOD(D, 2) <> CAST(0.0 AS NUMERIC(9,1))"
both "X4 WHERE SIGN(D) * 1 = CAST(1.0 AS NUMERIC(9,1)) -> 1;2;3" "SELECT ID FROM T WHERE SIGN(D) * 1 = CAST(1.0 AS NUMERIC(9,1))"
both "X4 WHERE MOD(D, 2) * 1 = 1 -> 2" "SELECT ID FROM T WHERE MOD(D, 2) * 1 = 1"
both_err "X4 MOD(D, 0) (Integer divide by zero on both)" "SELECT MOD(D, 0) AS X FROM T ORDER BY ID"
# X5 IN FULL: a simple CASE / DECODE THEN or ELSE value that is a
# negation or a multiply over a ? refuses on both (the engine's -804);
# a bare, CAST or added ? answers; the searched CASE / IIF twins answer
# (their branch slot's NOT NULL flag is the recorded gap)
both_refuse "X5 CASE ID WHEN ? THEN ? * 2 ELSE 0 END = 4 ['2', '2']" "SELECT ID FROM T WHERE CASE ID WHEN ? THEN ? * 2 ELSE 0 END = 4" '["2", "2"]'
both_refuse "X5 CASE ID WHEN ? THEN 0 ELSE -? END = -2 ['2', '2']" "SELECT ID FROM T WHERE CASE ID WHEN ? THEN 0 ELSE -? END = -2" '["2", "2"]'
both_refuse "X5 DECODE(ID, 2, -?) = -2 ['2']" "SELECT ID FROM T WHERE DECODE(ID, 2, -?) = -2" '["2"]'
both_refuse "X5 DECODE(ID, 2, 0, -?) = -2 ['2'] (the default value)" "SELECT ID FROM T WHERE DECODE(ID, 2, 0, -?) = -2" '["2"]'
both_refuse "X5 CASE ID WHEN 2 THEN -? ELSE ? END = -2 ['2', '2']" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -? ELSE ? END = -2" '["2", "2"]'
both_refuse "X5 CASE ID WHEN 2 THEN COALESCE(-?, 0) ELSE 0 END = -2 ['2']" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN COALESCE(-?, 0) ELSE 0 END = -2" '["2"]'
both_refuse "X5 SELECT CASE ID WHEN 2 THEN ? * 2 ELSE 0 END AS X ['2'] (the previous binary answered 0;4;0 - a refusal replacing a wrong answer)" "SELECT CASE ID WHEN 2 THEN ? * 2 ELSE 0 END AS X FROM T ORDER BY ID" '["2"]'
both_refuse "X5 UPDATE T SET N = 99 WHERE CASE ID WHEN ? THEN -? ELSE 0 END = -2 ['2', '2'] (refused at prepare on both: nothing mutated)" "UPDATE T SET N = 99 WHERE CASE ID WHEN ? THEN -? ELSE 0 END = -2" '["2", "2"]'
both "X5 control: CASE ID WHEN 2 THEN ? ELSE 0 END = 2 ['2'] -> 2 (a bare THEN ? answers)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '["2"]'
both "X5 control: CASE ID WHEN 2 THEN CAST(? AS INTEGER) ELSE 0 END = 2 ['2'] -> 2" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN CAST(? AS INTEGER) ELSE 0 END = 2" '["2"]'
desc_differs "X5 control: CASE ID WHEN 2 THEN ? + 1 ELSE 0 END = 3 ['2'] -> 2 (the engine types an ADDED ? INT64 in a DECODE branch, this server LONG - value agrees, recorded)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? + 1 ELSE 0 END = 3" '["2"]'
desc_differs "X5 searched control: IIF(ID = 2, -?, 0) = -2 ['2'] -> 2 (NOT NULL flag recorded)" "SELECT ID FROM T WHERE IIF(ID = 2, -?, 0) = -2" '["2"]'
desc_differs "X5 searched control: CASE WHEN ID = 2 THEN -? ELSE 0 END = -2 ['2'] -> 2" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN -? ELSE 0 END = -2" '["2"]'
desc_differs "X5 searched control: CASE WHEN ID = 2 THEN 0 ELSE -? END = -2 ['2'] -> 1;3" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN 0 ELSE -? END = -2" '["2"]'
desc_differs "X5 searched control: IIF(ID = 2, ? * 2, 0) = 4 ['2'] -> 2" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 0) = 4" '["2"]'
desc_differs "X5 searched control: CASE WHEN ID = 2 THEN ? * 2 ELSE 0 END = 4 ['2'] -> 2" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN ? * 2 ELSE 0 END = 4" '["2"]'
desc_differs "X5 searched control: SELECT IIF(ID = 2, -?, 0) AS X ['2'] -> 0;-2;0" "SELECT IIF(ID = 2, -?, 0) AS X FROM T ORDER BY ID" '["2"]'
# X6: the INTEGER destination and a VALUES row raise the same way
dml_rb_both_err "X6 control: UPDATE T SET N = -? WHERE ID = 1 [-2147483648] (Integer overflow on both, rows unchanged)" "UPDATE T SET N = -? WHERE ID = 1" '[-2147483648]'
dml_rb_both_err "X6 INSERT INTO T (ID, NN, N) VALUES (9, 1, -?) [-2147483648] (Integer overflow on both, no row)" "INSERT INTO T (ID, NN, N) VALUES (9, 1, -?)" '[-2147483648]'
# X7 IN FULL: the correlated scalar slot's family and width, every
# shape, and the DML twins under rollback
both "X7 ? * ID = (SELECT MAX(b.NM) .. b.ID > T.ID) ['0.5'] -> none (LONG -2 st1 on both)" "SELECT ID FROM T WHERE ? * ID = (SELECT MAX(b.NM) FROM T b WHERE b.ID > T.ID)" '["0.5"]'
both "X7 ID * ? = (SELECT MAX(b.NM) .. b.ID > T.ID) ['1.25'] -> 2" "SELECT ID FROM T WHERE ID * ? = (SELECT MAX(b.NM) FROM T b WHERE b.ID > T.ID)" '["1.25"]'
both "X7 ? * 1.5 = (SELECT CAST(4.5 AS NUMERIC(9,1)) .. b.ID = T.ID) ['2.5'] -> 1;2;3 (LONG -1 st1)" "SELECT ID FROM T WHERE ? * 1.5 = (SELECT CAST(4.5 AS NUMERIC(9,1)) FROM T b WHERE b.ID = T.ID)" '["2.5"]'
both "X7 1.5 * ? = (SELECT CAST(4.5 AS NUMERIC(9,1)) .. b.ID = T.ID) ['2.5'] -> none" "SELECT ID FROM T WHERE 1.5 * ? = (SELECT CAST(4.5 AS NUMERIC(9,1)) FROM T b WHERE b.ID = T.ID)" '["2.5"]'
both "X7 ? * ID = (SELECT b.NM .. b.ID = 9) ['1.25'] -> none (an empty subquery)" "SELECT ID FROM T WHERE ? * ID = (SELECT b.NM FROM T b WHERE b.ID = 9)" '["1.25"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): X7 -? = (SELECT b.NM .. b.ID = 9) ['1'] -> none" "SELECT ID FROM T WHERE -? = (SELECT b.NM FROM T b WHERE b.ID = 9)" '["1"]'
eng_only "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): X7 -? = (SELECT b.NM .. b.ID = T.ID + 1) ['-1'] -> 1" "SELECT ID FROM T WHERE -? = (SELECT b.NM FROM T b WHERE b.ID = T.ID + 1)" '["-1"]'
both "X7 ? * ID = (SELECT b.BI ..) ['4.0'] -> none (an INT64 slot: the RIGHT rounds)" "SELECT ID FROM T WHERE ? * ID = (SELECT b.BI FROM T b WHERE b.ID = T.ID + 1)" '["4.0"]'
both "X7 ? * ID = (SELECT CAST(b.NM AS NUMERIC(18,2)) ..) ['1.25'] -> 2 (INT64 -2 st1: the left keeps)" "SELECT ID FROM T WHERE ? * ID = (SELECT CAST(b.NM AS NUMERIC(18,2)) FROM T b WHERE b.ID = T.ID + 1)" '["1.25"]'
both "X7 ? * ID = (SELECT CAST(b.NM AS DECIMAL(9,2)) ..) ['1.25'] -> 1 (SUBTYPE 2)" "SELECT ID FROM T WHERE ? * ID = (SELECT CAST(b.NM AS DECIMAL(9,2)) FROM T b WHERE b.ID = T.ID + 1)" '["1.25"]'
eng_only "X7 through a view: SELECT ID FROM V WHERE ? * ID = (SELECT b.NM .. b.ID = 3) ['1.25'] (engine none; a view column is off the whitelist)" "SELECT ID FROM V WHERE ? * ID = (SELECT b.NM FROM T b WHERE b.ID = 3)" '["1.25"]'
dml_rb "X7 UPDATE T SET N = 99 WHERE ? * ID = (SELECT b.NM .. b.ID = T.ID + 1) ['1.25'] -> row 1" "UPDATE T SET N = 99 WHERE ? * ID = (SELECT b.NM FROM T b WHERE b.ID = T.ID + 1)" '["1.25"]'
dml_rb "X7 DELETE FROM T WHERE ID * ? = (SELECT b.NM .. b.ID = T.ID + 1) ['1.25'] -> row 2 gone" "DELETE FROM T WHERE ID * ? = (SELECT b.NM FROM T b WHERE b.ID = T.ID + 1)" '["1.25"]'
both "4l fixture survived the X cells" "SELECT ID, N, BI FROM T ORDER BY ID"

echo "-- 4m. ROUND 5 PINS (refuter round 4, findings A-L; engine-measured 2026-09-19 three-way against /tmp/fcwire-prev-c34c1c8, scratchpad g5/sel.out g5/sel2.out g5/dml.out) --"
# 'floor:' cells are the two REGRESSIONS of round 4 - the previous
# committed binary answered them exactly like the engine and so must every
# binary after it; they are green on /tmp/fcwire-prev-c34c1c8 too.
# A: the DESTINATION CAST sits on the OUTERMOST negation chain only - the
# chain's PARITY is folded (even = the bind itself, odd = one negation) and
# ONE CAST(<parity-applied ?> AS dest) is built; round 4 cast the inner -?
# first and -('-2147483648') = +2147483648 overflowed INTEGER before the
# outer minus. The single -? of a LONG message at the 4-byte minimum still
# overflows (X6 stays), and so does the odd chain whose value does not fit.
dml_rb "floor: A UPDATE T SET N = -(-?) WHERE ID = 1 ['-2147483648'] -> 1,-2147483648 (round 4 raised out of range: the inner -? was cast first)" "UPDATE T SET N = -(-?) WHERE ID = 1" '["-2147483648"]'
dml_rb "floor: A UPDATE T SET NM = -(-?) WHERE ID = 1 ['-21474836.48'] -> 1,-21474836.48" "UPDATE T SET NM = -(-?) WHERE ID = 1" '["-21474836.48"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "floor: A UPDATE TS SET SM = -(-?) WHERE ID = 1 [-32768] (a LONG message) -> 1,-32768" "UPDATE TS SET SM = -(-?) WHERE ID = 1" '[-32768]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "floor: A UPDATE TS SET SM = -(-?) WHERE ID = 1 ['-32768'] -> 1,-32768" "UPDATE TS SET SM = -(-?) WHERE ID = 1" '["-32768"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "floor: A UPDATE TS SET N41 = -(-?) WHERE ID = 1 ['-3276.8'] -> 1,-3276.8 (a NUMERIC(4,1) destination)" "UPDATE TS SET N41 = -(-?) WHERE ID = 1" '["-3276.8"]' "SELECT ID, N41 FROM TS ORDER BY ID"
dml_rb "floor: A UPDATE T SET N = -(-?) + 0 WHERE ID = 1 ['-2147483648'] -> 1,-2147483648" "UPDATE T SET N = -(-?) + 0 WHERE ID = 1" '["-2147483648"]'
dml_rb "floor: A INSERT INTO T (ID, NN, N) VALUES (9, 1, -(-?)) ['-2147483648'] -> 9,-2147483648" "INSERT INTO T (ID, NN, N) VALUES (9, 1, -(-?))" '["-2147483648"]'
dml_rb "floor: A UPDATE T SET N = -(-?) WHERE ID = 1 ['-3'] -> 1,-3" "UPDATE T SET N = -(-?) WHERE ID = 1" '["-3"]'
dml_rb "floor: A UPDATE T SET N = -(-(-?)) WHERE ID = 1 ['3'] -> 1,-3 (odd parity: one negation)" "UPDATE T SET N = -(-(-?)) WHERE ID = 1" '["3"]'
dml_rb "floor: A UPDATE T SET N = -(-?) WHERE ID = 1 ['1.5'] -> 1,2 (even parity: the text itself, rounded into the LONG slot)" "UPDATE T SET N = -(-?) WHERE ID = 1" '["1.5"]'
dml_rb_both_err "A control: UPDATE T SET N = -(-?) WHERE ID = 1 [-2147483648] (a LONG message negated on i32: Integer overflow on both - the previous binary STORED the value)" "UPDATE T SET N = -(-?) WHERE ID = 1" '[-2147483648]'
dml_rb_both_err "A control: UPDATE T SET BI = -(-?) WHERE ID = 1 [-2147483648] (Integer overflow on both; the previous binary stored -2147483648)" "UPDATE T SET BI = -(-?) WHERE ID = 1" '[-2147483648]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb_both_err "A control: UPDATE T SET N = -(-(-?)) WHERE ID = 1 ['-2147483648'] (+2147483648 does not fit INTEGER: out of range on both)" "UPDATE T SET N = -(-(-?)) WHERE ID = 1" '["-2147483648"]'
dml_rb_both_err "A control: UPDATE T SET BI = -(-?) WHERE ID = 1 ['-9223372036854775808'] (out of range on both)" "UPDATE T SET BI = -(-?) WHERE ID = 1" '["-9223372036854775808"]' "SELECT ID, BI FROM T ORDER BY ID"
# B: in raw_untyped_num an Add/Sub is untyped ONLY when BOTH operands are
# untyped - a negation, multiply, divide or function OVER a typed add is
# typable (the engine's DecodeNode types `? + 1` INT64 and evaluates
# above it); round 4 descended into every Bin and refused. The engine's
# describe of that ? is INT64 (INT128 under a multiply, DOUBLE beside
# 1.5) where this server says LONG - the recorded pre-existing gap, so
# these are desc_differs; the ELSE BI twin agrees whole.
both "floor: B CASE ID WHEN 2 THEN -(? + 1) ELSE BI END = -3 [2] -> 2 (an INT64 sibling: value AND describe agree on all three)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -(? + 1) ELSE BI END = -3" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END = -3 [2] -> 2 (round 4 refused; INT64-vs-LONG recorded)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END = -3" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN -(? - 1) ELSE 0 END = -1 [2] -> 2" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -(? - 1) ELSE 0 END = -1" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN -(1 + ?) ELSE 0 END = -3 [2] -> 2" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -(1 + ?) ELSE 0 END = -3" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN 0 ELSE -(? + 1) END = -3 [2] -> 1;3 (the ELSE value)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN 0 ELSE -(? + 1) END = -3" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN (? + 1) * 1 ELSE 0 END = 3 [2] -> 2 (engine INT128)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN (? + 1) * 1 ELSE 0 END = 3" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN (? + 1) / 1 ELSE 0 END = 3 [2] -> 2" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN (? + 1) / 1 ELSE 0 END = 3" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN (? + 1) * 2 ELSE 0 END = 6 [2] -> 2" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN (? + 1) * 2 ELSE 0 END = 6" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN 2 * (? + 1) ELSE 0 END = 6 [2] -> 2" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN 2 * (? + 1) ELSE 0 END = 6" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN -(? + 1.5) ELSE 0 END = -3.5 [2] -> 2 (engine DOUBLE)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -(? + 1.5) ELSE 0 END = -3.5" '[2]'
desc_differs "floor: B CASE ID WHEN 2 THEN ABS(? + 1) ELSE 0 END = 3 [2] -> 2 (a function over the typed add; engine INT64 NOT NULL)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ABS(? + 1) ELSE 0 END = 3" '[2]'
desc_differs "floor: B select list CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END AS X [2] -> 0;-3;0" "SELECT CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END AS X FROM T ORDER BY ID" '[2]'
dml_rb_desc_differs "floor: B UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END = -3 [2] -> row 2" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END = -3" '[2]'
dml_rb_desc_differs "floor: B DELETE FROM T WHERE CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END = -3 [2] -> row 2 gone" "DELETE FROM T WHERE CASE ID WHEN 2 THEN -(? + 1) ELSE 0 END = -3" '[2]'
dml_rb_desc_differs "floor: B UPDATE T SET N = CASE ID WHEN 2 THEN -(? + 1) ELSE N END [2] -> 2,-3" "UPDATE T SET N = CASE ID WHEN 2 THEN -(? + 1) ELSE N END" '[2]'
dml_rb_desc_differs "floor: B UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN (? + 1) * 1 ELSE 0 END = 3 [2] -> row 2" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN (? + 1) * 1 ELSE 0 END = 3" '[2]'
eng_only "B design boundary: DECODE(ID, 2, -(? + 1), 0) = -3 [2] (engine 2; the DECODE spelling of a computed result value is refused on both binaries)" "SELECT ID FROM T WHERE DECODE(ID, 2, -(? + 1), 0) = -3" '[2]'
both_refuse "B control: CASE ID WHEN 2 THEN CAST(? + 1 AS INTEGER) ELSE 0 END = 3 [2] (engine -804; the previous binary answered 2 - a refusal replacing a wrong answer)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN CAST(? + 1 AS INTEGER) ELSE 0 END = 3" '[2]'
both_refuse "B control: CASE ID WHEN 2 THEN -(? * 2) ELSE 0 END = -4 [2] (engine -802: a multiply over a bare ? is untyped; the previous binary answered 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -(? * 2) ELSE 0 END = -4" '[2]'
# C: mul_sibling_width folds exactly ONE minus over a literal (the
# parser's negative-literal rule: -2147483648 is a LONG); a further minus
# whose negation does not fit i32 returns None and the `*` refuses at
# prepare - the engine keeps the LONG descriptor and raises Integer
# overflow at execute, round 4 sized it WIDE by the signed value and
# answered (the UPDATE twin rewrote every row, the DELETE twin emptied T).
both_refuse "C ? * -(-2147483648) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] - the engine raises Integer overflow at execute, this server refuses at prepare (round 4 answered 1;2;3; the previous binary refused)" "SELECT ID FROM T WHERE ? * -(-2147483648) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both_refuse "C -(-2147483648) * ? <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (engine Integer overflow; refused)" "SELECT ID FROM T WHERE -(-2147483648) * ? <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both_refuse "C ? * - -2147483648 <> CAST(0.0 AS NUMERIC(4,1)) ['0.4'] (a SHORT slot; engine Integer overflow; refused)" "SELECT ID FROM T WHERE ? * - -2147483648 <> CAST(0.0 AS NUMERIC(4,1))" '["0.4"]'
both_refuse "C ? * -(-(-2147483648)) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (three minuses: the second already overflows on the engine; refused)" "SELECT ID FROM T WHERE ? * -(-(-2147483648)) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both_refuse "C ? * -(-214748364.8) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (the scaled LONG minimum under two minuses: engine Integer overflow; refused)" "SELECT ID FROM T WHERE ? * -(-214748364.8) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
dml_rb_eng_raises_fc_refuses "C UPDATE T SET N = 99 WHERE ? * -(-2147483648) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (engine Integer overflow, rows untouched; round 4 rewrote every row)" "UPDATE T SET N = 99 WHERE ? * -(-2147483648) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
dml_rb_eng_raises_fc_refuses "C DELETE FROM T WHERE ? * - -2147483648 <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] (engine Integer overflow; round 4 emptied the table)" "DELETE FROM T WHERE ? * - -2147483648 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "C control: ? * -2147483648 <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> none (ONE minus: the parser's negative LONG literal, narrow - the left ? rounds to 0)" "SELECT ID FROM T WHERE ? * -2147483648 <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "C control: ? * -(-2147483647) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> none (the second negation fits i32: narrow)" "SELECT ID FROM T WHERE ? * -(-2147483647) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "C control: ? * -(-3000000000) <> CAST(0.0 AS NUMERIC(9,1)) ['0.4'] -> 1;2;3 (an INT64 literal under two minuses: wide, the left keeps)" "SELECT ID FROM T WHERE ? * -(-3000000000) <> CAST(0.0 AS NUMERIC(9,1))" '["0.4"]'
both "C control: ? * -(-2) = CAST(2.0 AS NUMERIC(9,1)) ['1.4'] -> 1;2;3 (narrow: the left rounds to 1)" "SELECT ID FROM T WHERE ? * -(-2) = CAST(2.0 AS NUMERIC(9,1))" '["1.4"]'
desc_differs "C record: SELECT -2147483648 AS X FROM RDB\$DATABASE -> -2147483648 (the engine describes the single-minus minimum 496 LONG, this server 580 INT64 - pre-existing)" "SELECT -2147483648 AS X FROM RDB\$DATABASE"
# D: a simple CASE whose SUBJECT carries a ? is refused at prepare when it
# has more than one WHEN - parse_case_tail clones the subject into every
# WHEN and each clone was numbered as its own slot (round 4 described ONE ?
# as TWO and failed at execute with the client's one bind); the previous
# binary refused every ? subject. The single-WHEN form answers.
eng_only "D design boundary: CASE ? WHEN 2 THEN 1 WHEN 3 THEN 2 ELSE 0 END = 2 [3] (engine 1;2;3; a ? subject with two WHENs is refused at prepare - round 4 described the one ? as TWO slots)" "SELECT ID FROM T WHERE CASE ? WHEN 2 THEN 1 WHEN 3 THEN 2 ELSE 0 END = 2" '[3]'
eng_only "D design boundary: CASE ? WHEN 2 THEN 1 WHEN ID THEN 2 ELSE 0 END = 2 [3] (engine 3)" "SELECT ID FROM T WHERE CASE ? WHEN 2 THEN 1 WHEN ID THEN 2 ELSE 0 END = 2" '[3]'
eng_only "D design boundary: CASE ? WHEN ID THEN 1 WHEN N THEN 2 ELSE 0 END = 2 [4] (engine 2;3)" "SELECT ID FROM T WHERE CASE ? WHEN ID THEN 1 WHEN N THEN 2 ELSE 0 END = 2" '[4]'
eng_only "D design boundary: CASE ? WHEN 2 THEN 1 WHEN 2 THEN 2 ELSE 0 END = 1 [3] (engine none)" "SELECT ID FROM T WHERE CASE ? WHEN 2 THEN 1 WHEN 2 THEN 2 ELSE 0 END = 1" '[3]'
eng_only "D design boundary: SELECT CASE ? WHEN 2 THEN 'a' WHEN 3 THEN 'b' ELSE 'c' END AS X FROM T [3] (engine b;b;b)" "SELECT CASE ? WHEN 2 THEN 'a' WHEN 3 THEN 'b' ELSE 'c' END AS X FROM T" '[3]'
eng_only "D design boundary: DECODE(?, 2, 1, 3, 2, 0) = 2 [3] (engine 1;2;3; the pre-existing DECODE refusal)" "SELECT ID FROM T WHERE DECODE(?, 2, 1, 3, 2, 0) = 2" '[3]'
dml_rb_eng_only "D design boundary DML: UPDATE T SET N = 99 WHERE CASE ? WHEN 2 THEN 1 WHEN 3 THEN 2 ELSE 0 END = 2 [3] (engine: every row 99, rolled back; refused at prepare)" "UPDATE T SET N = 99 WHERE CASE ? WHEN 2 THEN 1 WHEN 3 THEN 2 ELSE 0 END = 2" '[3]'
dml_rb_eng_only "D design boundary DML: UPDATE T SET N = CASE ? WHEN 2 THEN 1 WHEN 3 THEN 2 ELSE 0 END [3] (engine: every N 2)" "UPDATE T SET N = CASE ? WHEN 2 THEN 1 WHEN 3 THEN 2 ELSE 0 END" '[3]'
desc_differs "D control: CASE ? WHEN 2 THEN 1 ELSE 0 END = 1 [2] -> 1;2;3 (ONE WHEN answers - the previous binary refused; the subject slot's NOT NULL flag is a recorded gap)" "SELECT ID FROM T WHERE CASE ? WHEN 2 THEN 1 ELSE 0 END = 1" '[2]'
desc_differs "D control: CASE ? WHEN 2 THEN 1 ELSE 0 END = 1 ['2.4'] -> none (the subject is a whole side: the fraction is kept)" "SELECT ID FROM T WHERE CASE ? WHEN 2 THEN 1 ELSE 0 END = 1" '["2.4"]'
dml_rb_desc_differs "D control DML: UPDATE T SET N = 99 WHERE CASE ? WHEN 2 THEN 1 ELSE 0 END = 1 [2] -> every row 99" "UPDATE T SET N = 99 WHERE CASE ? WHEN 2 THEN 1 ELSE 0 END = 1" '[2]'
# E: a TIME whole side INSIDE a subquery body is refused at prepare (the
# previous binary's floor) - round 4 described it and failed at execute:
# the CorrSub bind had no spelling for node's blr_timestamp message into a
# TIME slot. The outer whole side and the TIMESTAMP / DATE bodies answer.
eng_only "E design boundary: ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1) ['12:30:00'] (engine 1; a TIME whole side inside a body is refused at prepare - round 4 described it and failed at execute; the previous binary refused)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1)" '["12:30:00"]'
eng_only "E design boundary: ID IN (SELECT .. IIF(b.TM > ?, 1, 0) = 1) ['01:02:03'] (engine 1;3)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM > ?, 1, 0) = 1)" '["01:02:03"]'
eng_only "E design boundary: EXISTS (.. IIF(b.TM = ?, 1, 0) = 1) ['12:30:00'] (engine 1)" "SELECT ID FROM TS WHERE EXISTS (SELECT 1 FROM TS b WHERE b.ID = TS.ID AND IIF(b.TM = ?, 1, 0) = 1)" '["12:30:00"]'
eng_only "E design boundary: ID = (SELECT .. IIF(b.TM = ?, 1, 0) = 1) ['12:30:00'] (engine 1)" "SELECT ID FROM TS WHERE ID = (SELECT b.ID FROM TS b WHERE b.ID = TS.ID AND IIF(b.TM = ?, 1, 0) = 1)" '["12:30:00"]'
eng_only "E design boundary: ID IN (SELECT .. IIF(b.TM = ?, 1, 0) = 1) ['2024-01-10 12:30:00'] (engine none)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1)" '["2024-01-10 12:30:00"]'
eng_only "E design boundary: ID IN (SELECT .. IIF(CAST(b.TSP AS TIME) = ?, 1, 0) = 1) ['12:30:00'] (engine 1)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(CAST(b.TSP AS TIME) = ?, 1, 0) = 1)" '["12:30:00"]'
dml_rb_eng_only "E design boundary DML: UPDATE TS SET SM = 99 WHERE ID IN (SELECT .. IIF(b.TM = ?, 1, 0) = 1) ['12:30:00'] (engine row 1; refused at prepare)" "UPDATE TS SET SM = 99 WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1)" '["12:30:00"]' "SELECT ID, SM FROM TS ORDER BY ID"
both "E control: the outer IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> 1 (bind_whole_side_temporal)" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]'
both "E control: TM = CAST(? AS TIME) ['12:30:00'] -> 1" "SELECT ID FROM TS WHERE TM = CAST(? AS TIME)" '["12:30:00"]'
both "E control: ID IN (SELECT .. IIF(b.TSP = ?, 1, 0) = 1) ['2024-01-10 12:30:00'] -> 1 (a TIMESTAMP slot inside the body answers)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TSP = ?, 1, 0) = 1)" '["2024-01-10 12:30:00"]'
dml_rb "E control DML: UPDATE TS SET SM = 99 WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> row 1" "UPDATE TS SET SM = 99 WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]' "SELECT ID, SM FROM TS ORDER BY ID"
# PRE-EXISTING on BOTH binaries, recorded (NOT a refusal): the CLASSIC
# bare TIME compare prepares and FAILS AT EXECUTE with Dynamic SQL Error
# - the Term bind has no spelling for a blr_timestamp message into a TIME
# slot either. These cells say so when that changes.
eng_only "E PRE-EXISTING (both binaries): classic TM = ? ['12:30:00'] (engine 1) - this server PREPARES and fails at execute; recorded, not a refusal" "SELECT ID FROM TS WHERE TM = ?" '["12:30:00"]'
eng_only "E PRE-EXISTING: classic TM > ? ['01:02:03'] (engine 1;3) - prepare-then-fail on both binaries" "SELECT ID FROM TS WHERE TM > ?" '["01:02:03"]'
eng_only "E PRE-EXISTING: classic TM BETWEEN ? AND ? ['01:00:00', '13:00:00'] (engine 1;2;3) - prepare-then-fail" "SELECT ID FROM TS WHERE TM BETWEEN ? AND ?" '["01:00:00","13:00:00"]'
eng_only "E PRE-EXISTING: classic ? = TM ['12:30:00'] (engine 1) - prepare-then-fail" "SELECT ID FROM TS WHERE ? = TM" '["12:30:00"]'
eng_only "E PRE-EXISTING: ID IN (SELECT b.ID FROM TS b WHERE b.TM = ?) ['12:30:00'] (engine 1) - the bare body compare, prepare-then-fail" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE b.TM = ?)" '["12:30:00"]'
eng_only "E PRE-EXISTING: classic CAST(TSP AS TIME) = ? ['12:30:00'] (engine 1) - prepare-then-fail" "SELECT ID FROM TS WHERE CAST(TSP AS TIME) = ?" '["12:30:00"]'
# F: three subquery-body spellings that round 4 described and failed at
# execute now answer: CASE <col> WHEN ? in a body is a compare side of
# <col>; a text past 38 digits / 38 decimals is the double class (f64,
# clamped); a text into a CHARACTER whole side is spelled at the TEXT's
# own length instead of CAST to the slot's (string right truncation).
boundary_err "R12 boundary: conversion error by design (K2): F CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1 in an IN body ['2.0000000000000000001'] -> none (round 4 failed at execute)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["2.0000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): F CASE b.ID WHEN ? ['1e400'] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["1e400"]'
boundary_err "R12 boundary: conversion error by design (K2): F CASE b.ID WHEN ? ['2.00000000000000000000000000000000000001'] -> 2 (38 decimals: the exact class)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["2.00000000000000000000000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): F CASE b.ID WHEN ? ['2.000000000000000000000000000000000000001'] -> 2 (39 decimals: the double class)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["2.000000000000000000000000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): F CASE b.ID WHEN ? [39 nines] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F CASE b.ID WHEN ? [38 nines] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["99999999999999999999999999999999999999"]'
both "F CASE b.ID WHEN ? ['2'] -> 2 (control)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["2"]'
both "F CASE b.ID WHEN ? ['2.4'] -> none (a whole side keeps its fraction)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["2.4"]'
both_err "F CASE b.ID WHEN ? ['abc'] (conversion error from string on both)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["abc"]'
eng_only "F design boundary: DECODE(b.ID, ?, 1, 0) = 1 in a body ['2'] (engine 2; the DECODE spelling is refused on both binaries)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE DECODE(b.ID, ?, 1, 0) = 1)" '["2"]'
boundary_err "R12 boundary: conversion error by design (K2): F IIF(b.ID = ?, 1, 0) = 1 in an IN body [39 nines] -> none (a 39-digit text is the double class; round 4 failed at execute)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F IIF(b.NM = ?, 1, 0) = 1 [39 nines] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.NM = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F IIF(b.D = ?, 1, 0) = 1 [39 nines] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.D = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F IIF(b.BI = ?, 1, 0) = 1 [39 nines] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.BI = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F IIF(b.SM = ?, 1, 0) = 1 on TS [39 nines] -> none (a SHORT slot)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.SM = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F scalar body ID = (SELECT .. IIF(b.ID = ?, 1, 0) = 1) [39 nines] -> none" "SELECT ID FROM T WHERE ID = (SELECT b.ID FROM T b WHERE b.ID = T.ID AND IIF(b.ID = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F ID = ANY (SELECT .. IIF(b.ID = ?, 1, 0) = 1) [39 nines] -> none" "SELECT ID FROM T WHERE ID = ANY (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F ID > ALL (SELECT .. IIF(b.ID = ?, 1, 0) = 1) [39 nines] -> 1;2;3 (an empty ALL)" "SELECT ID FROM T WHERE ID > ALL (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): F IIF(b.ID < ?, 1, 0) = 1 [39 nines] -> 1;2;3" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID < ?, 1, 0) = 1)" '["999999999999999999999999999999999999999"]'
both "F IIF(b.S = ?, 1, 0) = 1 in an IN body ['abcdefghijklmnopqrstu'] -> none (a 21-char text into VARCHAR(10): round 4 raised string right truncation)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["abcdefghijklmnopqrstu"]'
both "F IIF(b.S = ?, 1, 0) = 1 ['ab          x'] -> none (13 chars)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["ab          x"]'
both "F IIF(b.S = ?, 1, 0) = 1 ['2.0000000000000000001'] -> none (a numeric text into the text slot)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["2.0000000000000000001"]'
both "F IIF(b.S = ?, 1, 0) = 1 [38 nines] -> none" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["99999999999999999999999999999999999999"]'
both "F IIF(b.S < ?, 1, 0) = 1 ['abcdefghijklmnopqrstu'] -> 1 (the long text compares whole: 'ab' < 'abc..')" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S < ?, 1, 0) = 1)" '["abcdefghijklmnopqrstu"]'
both "F IIF(b.S = ?, 1, 0) = 1 ['cd'] -> 2 (control)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["cd"]'
both "F IIF(b.S = ?, 1, 0) = 1 ['ab '] -> 1 (a trailing blank is padding on a text compare)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["ab "]'
both "F IIF(b.C = ?, 1, 0) = 1 on CHAR(4) ['2024-01-10'] -> none (a 10-char text into CHAR(4); round 4 raised truncation)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.C = ?, 1, 0) = 1)" '["2024-01-10"]'
both "F IIF(b.C = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> none" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.C = ?, 1, 0) = 1)" '["2024-01-10 12:30:00"]'
both "F IIF(b.C = ?, 1, 0) = 1 ['ab'] -> 1;3" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.C = ?, 1, 0) = 1)" '["ab"]'
both "F IIF(b.C = ?, 1, 0) = 1 ['ab   '] -> 1;3 (five chars, blank-padded compare)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.C = ?, 1, 0) = 1)" '["ab   "]'
both "F control: the outer IIF(S = ?, 1, 0) = 1 ['abcdefghijklmnopqrstu'] -> none" "SELECT ID FROM T WHERE IIF(S = ?, 1, 0) = 1" '["abcdefghijklmnopqrstu"]'
dml_rb_eng_only "F design boundary DML: UPDATE T SET N = 99 WHERE ID IN (SELECT .. CASE b.ID WHEN ? ..) ['2.00000000000000000000000000000000000001'] (engine row 2; a whole-side ? in a DML's subquery body is refused at prepare on both binaries - recorded)" "UPDATE T SET N = 99 WHERE ID IN (SELECT b.ID FROM T b WHERE CASE b.ID WHEN ? THEN 1 ELSE 0 END = 1)" '["2.00000000000000000000000000000000000001"]'
dml_rb_eng_only "F design boundary DML: UPDATE T SET N = 99 WHERE ID IN (SELECT .. IIF(b.S = ?, 1, 0) = 1) ['abcdefghijklmnopqrstu'] (engine: no row)" "UPDATE T SET N = 99 WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.S = ?, 1, 0) = 1)" '["abcdefghijklmnopqrstu"]'
# G: with B's rule an Add/Sub whose BOTH operands are untyped is untypable
# in a simple-CASE / DECODE / COALESCE value - the engine's -802 (the
# previous binary answered: a refusal replacing a wrong answer); the
# searched IIF / CASE WHEN twins type both from the sibling and answer.
both_refuse "G CASE ID WHEN 2 THEN ? + ? ELSE 0 END = 4 [2,2] (engine -802: both operands untyped; the previous binary answered 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? + ? ELSE 0 END = 4" '[2,2]'
both_refuse "G CASE ID WHEN 2 THEN ? + ? ELSE 1.5 END = 4.0 ['2', '2'] (engine -802)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? + ? ELSE 1.5 END = 4.0" '["2","2"]'
both_refuse "G COALESCE(? + ?, 0) = 4 [2,2] (engine -802; the previous binary answered 1;2;3)" "SELECT ID FROM T WHERE COALESCE(? + ?, 0) = 4" '[2,2]'
both_refuse "G CASE ID WHEN 2 THEN ABS(? + ?) ELSE 0 END = 4 [2,2] (a function over the untyped add)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ABS(? + ?) ELSE 0 END = 4" '[2,2]'
both_refuse "G CASE ID WHEN 2 THEN -? - ? ELSE 0 END = -4 [2,2]" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN -? - ? ELSE 0 END = -4" '[2,2]'
both_refuse "G CASE ID WHEN 2 THEN ? - ? ELSE 0 END = 0 [2,2]" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? - ? ELSE 0 END = 0" '[2,2]'
both_refuse "G CASE ID WHEN 2 THEN (? + 1) || 'x' ELSE 'y' END = '3x' [2] (the engine refuses the concatenation too)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN (? + 1) || 'x' ELSE 'y' END = '3x'" '[2]'
dml_rb_both_refuse "G UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? + ? ELSE 0 END = 4 [2,2] (refused at prepare on both, nothing mutated; the previous binary changed row 2)" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? + ? ELSE 0 END = 4" '[2,2]'
dml_rb_both_refuse "G UPDATE T SET N = 99 WHERE COALESCE(? + ?, 0) = 4 [2,2] (the previous binary rewrote every row)" "UPDATE T SET N = 99 WHERE COALESCE(? + ?, 0) = 4" '[2,2]'
desc_differs "G control: IIF(ID = 2, ? + ?, 0) = 4 [2,2] -> 2 (a searched branch types both from the sibling; the NOT NULL flags are the recorded gap)" "SELECT ID FROM T WHERE IIF(ID = 2, ? + ?, 0) = 4" '[2,2]'
desc_differs "G control: CASE WHEN ID = 2 THEN ? + ? ELSE 0 END = 4 [2,2] -> 2" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN ? + ? ELSE 0 END = 4" '[2,2]'
both "G control: ? + ? = 4 [2,2] -> 1;2;3 (comparison-typed, both slots NOT NULL on both)" "SELECT ID FROM T WHERE ? + ? = 4" '[2,2]'
desc_differs "G control: COALESCE(? + 1, 0) = 3 [2] -> 1;2;3 (one typed operand answers; INT64-vs-LONG recorded)" "SELECT ID FROM T WHERE COALESCE(? + 1, 0) = 3" '[2]'
desc_differs "G control: COALESCE(1 + ?, 0) = 3 [2] -> 1;2;3" "SELECT ID FROM T WHERE COALESCE(1 + ?, 0) = 3" '[2]'
# H: CAST(<WITH TIME ZONE> AS TIMESTAMP / DATE / TIME) converts to the
# session zone (12:30 +03:00 -> 09:30) - both binaries used to render the
# zoned text and fail to re-parse it, and the whole side over it prepared
# then failed. A NAMED zone in a TIME WITH TIME ZONE still fails at
# execute on both (recorded); the bare zoned whole side is refused.
recorded "R7 recorded: pre-existing - H SELECT CAST(TZ AS TIMESTAMP) AS X FROM TS -> 09:30:00 / 00:00:00 / 10:30:00.5 (converted to the session zone; both binaries used to raise Conversion error) (engine [2024-01-10T09:30:00.000Z;2024-02-10T00:0], this server raises at execute; prev prepared then Conversion error from string '20)" "SELECT CAST(TZ AS TIMESTAMP) AS X FROM TS ORDER BY ID" '[]' "ERR"
recorded "R7 recorded: pre-existing - H SELECT CAST(TZ AS DATE) AS X FROM TS -> 2024-01-10;2024-02-10;2024-03-10 (engine [2024-01-10T00:00:00.000Z;2024-02-10T00:0], this server raises at execute; prev prepared then Conversion error from string '20)" "SELECT CAST(TZ AS DATE) AS X FROM TS ORDER BY ID" '[]' "ERR"
recorded "R7 recorded: pre-existing - H SELECT CAST(TZ AS TIME) AS X FROM TS -> 09:30:00;00:00:00;10:30:00.5 (engine [1970-01-01T09:30:00.000Z;1970-01-01T00:0], this server raises at execute; prev prepared then Conversion error from string '20)" "SELECT CAST(TZ AS TIME) AS X FROM TS ORDER BY ID" '[]' "ERR"
recorded "R7 recorded: pre-existing - H SELECT CAST(TMZ AS TIME) AS X FROM TS WHERE ID < 3 -> 09:30:00;01:02:03 (offset zones convert) (engine [1970-01-01T09:30:00.000Z;1970-01-01T01:0], this server raises at execute; prev prepared then Conversion error from string '12)" "SELECT CAST(TMZ AS TIME) AS X FROM TS WHERE ID < 3 ORDER BY ID" '[]' "ERR"
eng_only "R7 scope cut: refuses - H IIF(CAST(TZ AS TIMESTAMP) = ?, 1, 0) = 1 ['2024-01-10 09:30:00'] -> 1 (round 4 failed at execute) (engine [1]; prev refused)" "SELECT ID FROM TS WHERE IIF(CAST(TZ AS TIMESTAMP) = ?, 1, 0) = 1" '["2024-01-10 09:30:00"]'
eng_only "R7 scope cut: refuses - H IIF(CAST(TZ AS TIMESTAMP) = ?, 1, 0) = 1 ['2024-01-10 12:30:00'] -> none (the zoned wall time does not match) (engine [(none)]; prev refused)" "SELECT ID FROM TS WHERE IIF(CAST(TZ AS TIMESTAMP) = ?, 1, 0) = 1" '["2024-01-10 12:30:00"]'
recorded "R7 recorded: pre-existing - H classic CAST(TZ AS TIMESTAMP) = ? ['2024-01-10 09:30:00'] -> 1 (the previous binary failed at execute) (engine [1], this server raises at execute; prev prepared then Conversion error from string '20)" "SELECT ID FROM TS WHERE CAST(TZ AS TIMESTAMP) = ?" '["2024-01-10 09:30:00"]' "ERR"
eng_only "R7 scope cut: refuses - H IIF(CAST(TZ AS DATE) = ?, 1, 0) = 1 ['2024-02-10'] -> 2 (engine [2]; prev refused)" "SELECT ID FROM TS WHERE IIF(CAST(TZ AS DATE) = ?, 1, 0) = 1" '["2024-02-10"]'
recorded "R7 recorded: pre-existing - H parameter-free WHERE CAST(TZ AS TIMESTAMP) = TIMESTAMP '2024-01-10 09:30:00' -> 1 (engine [1], this server raises at execute; prev prepared then Conversion error from string '20)" "SELECT ID FROM TS WHERE CAST(TZ AS TIMESTAMP) = TIMESTAMP '2024-01-10 09:30:00'" '[]' "ERR"
dml_rb_eng_only "R7 scope cut: refuses - H UPDATE TS SET SM = 99 WHERE IIF(CAST(TZ AS TIMESTAMP) = ?, 1, 0) = 1 ['2024-01-10 09:30:00'] -> row 1 (engine rb 1,99,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,; prev refused)" "UPDATE TS SET SM = 99 WHERE IIF(CAST(TZ AS TIMESTAMP) = ?, 1, 0) = 1" '["2024-01-10 09:30:00"]' "SELECT ID, SM FROM TS ORDER BY ID"
eng_only "H design boundary: IIF(TZ = ?, 1, 0) = 1 ['2024-01-10 09:30:00'] (engine 1; a WITH TIME ZONE whole side is refused on both binaries)" "SELECT ID FROM TS WHERE IIF(TZ = ?, 1, 0) = 1" '["2024-01-10 09:30:00"]'
eng_only "H design boundary: IIF(TMZ = ?, 1, 0) = 1 ['09:30:00'] (engine 1; refused)" "SELECT ID FROM TS WHERE IIF(TMZ = ?, 1, 0) = 1" '["09:30:00"]'
eng_only "H PRE-EXISTING (both binaries): SELECT CAST(TMZ AS TIME) FROM TS over the NAMED-zone row 3 (engine 09:30:00;01:02:03;09:30:00) - this server fails at execute on 'Europe/Bucharest' in a TIME WITH TIME ZONE; recorded, not a refusal" "SELECT CAST(TMZ AS TIME) AS X FROM TS ORDER BY ID"
eng_only "H PRE-EXISTING: SELECT CAST(TMZ AS TIMESTAMP) FROM TS (engine today at 09:30:00 / 01:02:03 / 09:30:00) - fails at execute on the named zone" "SELECT CAST(TMZ AS TIMESTAMP) AS X FROM TS ORDER BY ID"
# I: an arithmetic ? typed from a SIBLING BRANCH takes the conditional's
# RESULT descriptor as its slot (INT64 -1 beside 1.5, the engine's
# describe) and the side rule reads THAT width: under INT64 the RIGHT
# operand rounds and the ? keeps 2.5 - both binaries applied the LONG rule
# (the left ? rounded to 3) and answered the other row set. The branch
# slot's NOT NULL flag is the recorded IIF gap, hence desc_differs.
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 2, 1.5) = 5.0 ['2.5'] -> 2 (an INT64 -1 slot from the 1.5 sibling: the RIGHT rounds, the ? keeps 2.5; both binaries answered none) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 5.0" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, 2 * ?, 1.5) = 5.0 ['2.5'] -> none (the ? rounds to 3; the previous binary answered 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, 2 * ?, 1.5) = 5.0" '["2.5"]' "2"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, 2 * ?, 1.5) = 6.0 ['2.5'] -> 2 (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, 2 * ?, 1.5) = 6.0" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 2, CAST(1.5 AS NUMERIC(9,1))) = 5.0 ['2.5'] -> 2 (580 INT64 -1 st1 on both; the previous binary said LONG) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, CAST(1.5 AS NUMERIC(9,1))) = 5.0" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 2, 1.5) = 4.8 ['2.4'] -> 2 (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 4.8" '["2.4"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 2, 1.5) = 4.0 ['2.4'] -> none (the previous binary answered 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 4.0" '["2.4"]' "2"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 2, 1.5) <> 0.0 ['0.4'] -> 1;2;3 (the previous binary lost row 2) (engine [1;2;3], this server [1;3]; prev 1;3)" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) <> 0.0" '["0.4"]' "1;3"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 1.5, 0.0) = 3.75 ['2.5'] -> 2 (the ? described INT64 -2 on both: result scale minus the literal's) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 1.5, 0.0) = 3.75" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 1.5, 0.0) = 4.5 ['2.5'] -> none (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 1.5, 0.0) = 4.5" '["2.5"]' "2"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? / 2, 1.5) = 1.25 ['2.5'] -> 2 (scale -2) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? / 2, 1.5) = 1.25" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? / 4, 0.0) = 0.625 ['2.5'] -> 2 (scale -3) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? / 4, 0.0) = 0.625" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, 2 / ?, 0.0) = 0.6 ['2.5'] -> 2 (the divisor rounds to 3) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, 2 / ?, 0.0) = 0.6" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * BI, 1.5) = 20.0 ['2.5'] -> 2 (a column sibling under the INT64 result) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * BI, 1.5) = 20.0" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, -? * 2, 1.5) = -5.0 ['2.5'] -> 2 (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, -? * 2, 1.5) = -5.0" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I CASE WHEN ID = 2 THEN ? * 2 ELSE 1.5 END = 5.0 ['2.5'] -> 2 (the searched CASE twin) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN ? * 2 ELSE 1.5 END = 5.0" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I NULLIF(? * 2, 1.5) = 5.0 ['2.5'] -> 1;2;3 (NULLIF's slot is Nullable on both: value and describe agree) (engine [1;2;3], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE NULLIF(? * 2, 1.5) = 5.0" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 2, NM) = 5.1 ['2.55'] -> 2 (an INT64 -2 st1 slot from the NM sibling; the previous binary said LONG and answered none) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, NM) = 5.1" '["2.55"]' "(none)"
both "I IIF(ID = 2, ? * 2, BI) = 5 ['2.5'] -> none (an INT64 scale-0 result: the ? is typed at scale 0 and rounds)" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, BI) = 5" '["2.5"]'
recorded "R7 recorded: pre-existing - I select list IIF(ID = 2, ? * 2, 1.5) AS X ['2.5'] -> 1.5;5;1.5 (the previous binary printed 6) (engine [1.5;5;1.5], this server [1.5;6;1.5]; prev 1.5;6;1.5)" "SELECT IIF(ID = 2, ? * 2, 1.5) AS X FROM T ORDER BY ID" '["2.5"]' "1.5;6;1.5"
recorded "R7 recorded: pre-existing - I select list IIF(ID = 2, ? * 2, 1.5) AS X ['2.4'] -> 1.5;4.8;1.5 (engine [1.5;4.8;1.5], this server [1.5;4;1.5]; prev 1.5;4;1.5)" "SELECT IIF(ID = 2, ? * 2, 1.5) AS X FROM T ORDER BY ID" '["2.4"]' "1.5;4;1.5"
recorded "R7 recorded: pre-existing - I select list IIF(ID = 2, ? * 2, 1.5) AS X [2.44] (a DOUBLE message) -> 1.5;4.8;1.5 (engine [1.5;4.8;1.5], this server [1.5;4;1.5]; prev 1.5;4;1.5)" "SELECT IIF(ID = 2, ? * 2, 1.5) AS X FROM T ORDER BY ID" '[2.44]' "1.5;4;1.5"
recorded "R7 recorded: pre-existing - I IIF(ID = 2, ? * 2, 1.5) = 5.0 [2.5] (a DOUBLE message) -> 2 (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 5.0" '[2.5]' "(none)"
recorded "R7 recorded: pre-existing - I bare branch IIF(ID = 2, ?, 0) = 2.5 ['2.5'] -> 2 (the slot is the INT64 -1 compare side; the previous binary said LONG and answered none) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = 2.5" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - I bare branch IIF(ID = 2, ?, 0) = 2.0 ['2.4'] -> none (the previous binary answered 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = 2.0" '["2.4"]' "2"
recorded "R7 recorded: pre-existing - I bare branch IIF(ID = 2, ?, 1.5) = 2.55 ['2.55'] -> 2 (scale -2 from the compare side) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 1.5) = 2.55" '["2.55"]' "(none)"
desc_differs "I bare branch IIF(ID = 2, ?, CAST(1.5 AS NUMERIC(4,1))) = 2.5 ['2.5'] -> 2 (580 INT64 -1 st1; the previous binary said SHORT)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, CAST(1.5 AS NUMERIC(4,1))) = 2.5" '["2.5"]'
desc_differs "I control: IIF(ID = 2, ? * 2, 0) = 6 ['2.5'] -> 2 (a LONG result: the LEFT ? rounds to 3 - chunk 45 stays)" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 0) = 6" '["2.5"]'
desc_differs "I control: IIF(ID = 2, ? * 2, 0) = 5 ['2.5'] -> none" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 0) = 5" '["2.5"]'
dml_rb_recorded "R7 recorded: pre-existing - I UPDATE T SET N = 99 WHERE IIF(ID = 2, ? * 2, 1.5) = 5.0 ['2.5'] -> row 2 (the previous binary touched nothing) (engine ok => 1,3,ab,7.25,9,2024-01-10T00:00:00. rb 1,3,ab,7.25,9;2,99,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,7.25,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,7.25,9,2024-01-10T00:00:00.000Z;2,4,cd)" "UPDATE T SET N = 99 WHERE IIF(ID = 2, ? * 2, 1.5) = 5.0" '["2.5"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,4;3,4'
dml_rb_recorded "R7 recorded: pre-existing - I UPDATE T SET N = 99 WHERE IIF(ID = 2, 2 * ?, 1.5) = 5.0 ['2.5'] -> no row (the previous binary took row 2) (engine ok => 1,3,ab,7.25,9,2024-01-10T00:00:00. rb 1,3,ab,7.25,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,7.25,9;2,99,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,7.25,9,2024-01-10T00:00:00.000Z;2,99,c)" "UPDATE T SET N = 99 WHERE IIF(ID = 2, 2 * ?, 1.5) = 5.0" '["2.5"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,99;3,4'
# J: a simple-CASE THEN / ELSE bare ? is compared at the MESSAGE's own
# precision (the DecodeNode types no parameter): the text '2.4' stays
# 2.4 - both binaries rounded it into the described LONG and answered
# row 2. The searched IIF twin is typed and keeps its rounding.
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN ? ELSE 0 END = 2 ['2.4'] -> none (the message compares whole; both binaries answered 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '["2.4"]' "2"
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN ? ELSE 0 END = 2.4 ['2.4'] -> 2 (580 INT64 -1 on both) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2.4" '["2.4"]' "(none)"
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN ? ELSE 0 END > 2 ['2.4'] -> 2 (both binaries answered none) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END > 2" '["2.4"]' "(none)"
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN ? ELSE 0 END = ID ['2.4'] -> none (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ID" '["2.4"]' "2"
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN ? ELSE 1.5 END = 2.5 ['2.51'] -> none (an INT64 -1 describe, the value still whole) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END = 2.5" '["2.51"]' "2"
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN ? ELSE 1.5 END > 2.5 ['2.51'] -> 2 (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END > 2.5" '["2.51"]' "(none)"
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN ? ELSE 0 END = 2 [2.4] (a DOUBLE message) -> none (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '[2.4]' "2"
recorded "R7 recorded: pre-existing - J CASE ID WHEN 2 THEN 0 ELSE ? END = 2 ['2.4'] -> none (the ELSE value; the previous binary answered 1;3) (engine [(none)], this server [1;3]; prev 1;3)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN 0 ELSE ? END = 2" '["2.4"]' "1;3"
both "J select list CASE ID WHEN 2 THEN ? ELSE 0 END AS X ['2.4'] -> 0;2;0 (the OUTPUT is the described LONG)" "SELECT CASE ID WHEN 2 THEN ? ELSE 0 END AS X FROM T ORDER BY ID" '["2.4"]'
both "J select list CASE ID WHEN 2 THEN ? ELSE 1.5 END AS X ['2.51'] -> 1.5;2.5;1.5" "SELECT CASE ID WHEN 2 THEN ? ELSE 1.5 END AS X FROM T ORDER BY ID" '["2.51"]'
desc_differs "R7 floor: J CASE ID WHEN 2 THEN ? ELSE NM END = 2.50 ['2.5'] -> 2;3 (580 INT64 -2 st1 on both) -> 2;3 (describe gap recorded; prev 2;3)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE NM END = 2.50" '["2.5"]'
both "J control: CASE ID WHEN 2 THEN ? ELSE 0 END = 2 [2] -> 2" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '[2]'
both_err "J CASE ID WHEN 2 THEN ? ELSE 0 END = 2 ['abc'] (conversion error from string on both)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '["abc"]'
eng_only "J design boundary: DECODE(ID, 2, ?, 0) = 2 ['2.4'] (engine none; the DECODE spelling is refused on both binaries)" "SELECT ID FROM T WHERE DECODE(ID, 2, ?, 0) = 2" '["2.4"]'
desc_differs "J control: the searched IIF(ID = 2, ?, 0) = 2 ['2.4'] -> 2 (typed from the sibling, rounds; the NOT NULL flag recorded)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = 2" '["2.4"]'
both "J control: COALESCE(?, 0) = 2 ['2.4'] -> 1;2;3" "SELECT ID FROM T WHERE COALESCE(?, 0) = 2" '["2.4"]'
dml_rb_recorded "R7 recorded: pre-existing - J UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2 ['2.4'] -> no row (the previous binary took row 2) (engine ok => 1,3,ab,7.25,9,2024-01-10T00:00:00. rb 1,3,ab,7.25,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,7.25,9;2,99,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,7.25,9,2024-01-10T00:00:00.000Z;2,99,c)" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '["2.4"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,99;3,4'
dml_rb_recorded "R7 recorded: pre-existing - J UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END > 2 ['2.4'] -> row 2 (the previous binary touched nothing) (engine ok => 1,3,ab,7.25,9,2024-01-10T00:00:00. rb 1,3,ab,7.25,9;2,99,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,7.25,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,7.25,9,2024-01-10T00:00:00.000Z;2,4,cd)" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END > 2" '["2.4"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,4;3,4'
# K: the DML destination's multiply takes the SAME side rule as the
# comparison (resolve_dest_param_expr's Bin arm: slot = the destination's
# width, sibling via mul_sibling_width) - a LONG / SHORT destination with
# a narrow sibling rounds the LEFT ? (chunk 45 stays), an INT64 destination
# rounds the RIGHT operand and the ? keeps its fraction to the
# destination's SCALE; a 4-byte message under -? negates on i32 before
# the multiply. Both binaries rounded the ? at scale 0 (6 for 5.0) and
# stored 2147483648 where the engine raises.
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = ? * 2 WHERE ID = 1 ['2.5'] -> 1,5.0 (a NUMERIC(18,1) destination: the RIGHT operand rounds, the ? keeps; both binaries stored 6) (engine ok => 1,2,5,2.5,2.5,ab  ,2.5;2,-32768,3. rb 1,2,5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; this server rb 1,2,6,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; prev ok/1,2,6,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,c)" "UPDATE TS SET N18 = ? * 2 WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,6;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = -? * 1 WHERE ID = 1 ['2.5'] -> 1,-2.5 (both binaries stored -3) (engine ok => 1,2,-2.5,2.5,2.5,ab  ,2.5;2,-32768 rb 1,2,-2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,; this server rb 1,2,-3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.; prev ok/1,2,-3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,)" "UPDATE TS SET N18 = -? * 1 WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,-3;2,3.5;3,1.5'
dml_rb_both_err "R8 promoted (was R7 recorded): K UPDATE TS SET N18 = -? * 1 WHERE ID = 1 [-2147483648] - Integer overflow on both (the scale-0 multiply rounding cast is looked through to the 4-byte message now, round 8 Q1; both earlier binaries stored 2147483648)" "UPDATE TS SET N18 = -? * 1 WHERE ID = 1" '[-2147483648]' "SELECT ID, N18 FROM TS ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N10 = ? * 2 WHERE ID = 1 [2.5] (a DOUBLE message) -> 1,5.00 (engine ok => 1,2,2.5,5,2.5,ab  ,2.5;2,-32768,3. rb 1,2,2.5,5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; this server rb 1,2,2.5,6,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; prev ok/1,2,2.5,6,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,c)" "UPDATE TS SET N10 = ? * 2 WHERE ID = 1" '[2.5]' "SELECT ID, N10 FROM TS ORDER BY ID" 'dml=(none) rb=1,6;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N10 = ? * 2 WHERE ID = 1 ['2.5'] -> 1,5.00 (engine ok => 1,2,2.5,5,2.5,ab  ,2.5;2,-32768,3. rb 1,2,2.5,5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; this server rb 1,2,2.5,6,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; prev ok/1,2,2.5,6,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,c)" "UPDATE TS SET N10 = ? * 2 WHERE ID = 1" '["2.5"]' "SELECT ID, N10 FROM TS ORDER BY ID" 'dml=(none) rb=1,6;2,3.5;3,1.5'
dml_rb_both_err "R8 promoted (was R7 recorded): K UPDATE TS SET N10 = -? * 1 WHERE ID = 1 [-2147483648] - Integer overflow on both (the scale-0 multiply rounding cast is looked through to the 4-byte message now, round 8 Q1; both earlier binaries stored 2147483648)" "UPDATE TS SET N10 = -? * 1 WHERE ID = 1" '[-2147483648]' "SELECT ID, N10 FROM TS ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = ? * 2 WHERE ID = 1 ['-3276.8'] -> 1,-6553.6 (both binaries stored -6554) (engine ok => 1,2,-6553.6,2.5,2.5,ab  ,2.5;2,-32 rb 1,2,-6553.6,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3; this server rb 1,2,-6554,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3; prev ok/1,2,-6554,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3)" "UPDATE TS SET N18 = ? * 2 WHERE ID = 1" '["-3276.8"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,-6554;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = ? * 2 WHERE ID = 1 ['-21474836.48'] -> 1,-42949673.0 (the ? is typed at the destination's scale -1: -21474836.5 * 2) (engine ok => 1,2,-42949673,2.5,2.5,ab  ,2.5;2,- rb 1,2,-42949673,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5; this server rb 1,2,-42949672,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5; prev ok/1,2,-42949672,2.5,2.5,ab  ,2.5;2,-32768,3.5,3)" "UPDATE TS SET N18 = ? * 2 WHERE ID = 1" '["-21474836.48"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,-42949672;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = 2 * ? WHERE ID = 1 ['2.5'] -> 1,6.0 (the RIGHT ? rounds to 3; both binaries stored 5) (engine ok => 1,2,6,2.5,2.5,ab  ,2.5;2,-32768,3. rb 1,2,6,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; this server rb 1,2,5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; prev ok/1,2,5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,c)" "UPDATE TS SET N18 = 2 * ? WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,5;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = ? * 1.5 WHERE ID = 1 ['2.5'] -> 1,3.8 (2.5 * 2: the literal rounds) (engine ok => 1,2,3.8,2.5,2.5,ab  ,2.5;2,-32768, rb 1,2,3.8,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,4.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,4.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N18 = ? * 1.5 WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,4.5;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = 1.5 * ? WHERE ID = 1 ['2.5'] -> 1,4.5 (1.5 * 3) (engine ok => 1,2,4.5,2.5,2.5,ab  ,2.5;2,-32768, rb 1,2,4.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,3.8,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,3.8,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N18 = 1.5 * ? WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,3.8;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = ? * ? WHERE ID = 1 ['2.5', '1'] -> 1,2.5 (a direct ? sibling: the right rounds) (engine ok => 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768, rb 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; prev ok/1,2,3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,c)" "UPDATE TS SET N18 = ? * ? WHERE ID = 1" '["2.5","1"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,3;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = ? * ? WHERE ID = 1 ['1', '2.5'] -> 1,3.0 (engine ok => 1,2,3,2.5,2.5,ab  ,2.5;2,-32768,3. rb 1,2,3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; this server rb 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N18 = ? * ? WHERE ID = 1" '["1","2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,2.5;2,3.5;3,1.5'
dml_rb "K UPDATE TS SET N18 = ? / 2 WHERE ID = 1 ['2.5'] -> 1,1.2" "UPDATE TS SET N18 = ? / 2 WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET N18 = 2 / ? WHERE ID = 1 ['2.5'] -> 1,0.6 (the divisor rounds to 3; both binaries stored 0.8) (engine ok => 1,2,0.6,2.5,2.5,ab  ,2.5;2,-32768, rb 1,2,0.6,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,0.8,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,0.8,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N18 = 2 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,0.8;2,3.5;3,1.5'
dml_rb "K UPDATE TS SET N18 = ? + 1 WHERE ID = 1 ['2.55'] -> 1,3.6" "UPDATE TS SET N18 = ? + 1 WHERE ID = 1" '["2.55"]' "SELECT ID, N18 FROM TS ORDER BY ID"
dml_rb "K UPDATE TS SET N18 = ? * 2 WHERE ID = 1 [-2147483648] -> 1,-4294967296.0" "UPDATE TS SET N18 = ? * 2 WHERE ID = 1" '[-2147483648]' "SELECT ID, N18 FROM TS ORDER BY ID"
dml_rb_both_err "K UPDATE TS SET N18 = -? WHERE ID = 1 [-2147483648] (the bare -?: Integer overflow on both)" "UPDATE TS SET N18 = -? WHERE ID = 1" '[-2147483648]' "SELECT ID, N18 FROM TS ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - K INSERT INTO TS (ID, N18) VALUES (9, ? * 2) ['2.5'] -> 9,5.0 (engine ok => 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768, rb 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "INSERT INTO TS (ID, N18) VALUES (9, ? * 2)" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,2.5;2,3.5;3,1.5;9,6'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE T SET NM = ? * BI WHERE ID = 1 ['2.5'] -> 1,22.50 (an INT64 sibling under a LONG destination: the RIGHT rounds, the ? keeps; both binaries stored 27) (engine ok => 1,3,ab,22.5,9,2024-01-10T00:00:00. rb 1,3,ab,22.5,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,27,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,27,9,2024-01-10T00:00:00.000Z;2,4,cd,1)" "UPDATE T SET NM = ? * BI WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,27;2,1;3,2.5'
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE T SET NM = BI * ? WHERE ID = 1 ['2.5'] -> 1,27.00 (both binaries stored 22.5) (engine ok => 1,3,ab,27,9,2024-01-10T00:00:00.00 rb 1,3,ab,27,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,22.5,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,22.5,9,2024-01-10T00:00:00.000Z;2,4,cd)" "UPDATE T SET NM = BI * ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,22.5;2,1;3,2.5'
dml_rb "K chunk 45 stays: UPDATE T SET N = ? * 2 WHERE ID = 1 ['2.5'] -> 1,6 (a LONG destination, a narrow sibling: the LEFT ? rounds)" "UPDATE T SET N = ? * 2 WHERE ID = 1" '["2.5"]'
dml_rb "K chunk 45 stays: UPDATE T SET NM = ? * 2 WHERE ID = 1 ['2.5'] -> 1,6.00" "UPDATE T SET NM = ? * 2 WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "K chunk 45 stays: UPDATE T SET NM = 2 * ? WHERE ID = 1 ['2.5'] -> 1,5.00" "UPDATE T SET NM = 2 * ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "K chunk 45 stays: UPDATE TS SET N41 = ? * 2 WHERE ID = 1 ['2.5'] -> 1,6.0 (a SHORT destination)" "UPDATE TS SET N41 = ? * 2 WHERE ID = 1" '["2.5"]' "SELECT ID, N41 FROM TS ORDER BY ID"
dml_rb "K chunk 45 stays: UPDATE TS SET N41 = 2 * ? WHERE ID = 1 ['2.5'] -> 1,5.0" "UPDATE TS SET N41 = 2 * ? WHERE ID = 1" '["2.5"]' "SELECT ID, N41 FROM TS ORDER BY ID"
dml_rb "K UPDATE T SET BI = ? * 2 WHERE ID = 1 ['2.5'] -> 1,6 (a scale-0 INT64 destination: the ? is typed at scale 0 and rounds to 3)" "UPDATE T SET BI = ? * 2 WHERE ID = 1" '["2.5"]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - K UPDATE TS SET SM = ? + 1 WHERE ID = 1 [-32769] -> 1,-32768 (the add runs on the message and only the SUM is range-checked; both binaries raised) (engine ok => 1,-32768,2.5,2.5,2.5,ab  ,2.5;2,-3 rb 1,-32768,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;; this server rb 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev prepared then Arithmetic exception, numeric ov)" "UPDATE TS SET SM = ? + 1 WHERE ID = 1" '[-32769]' "SELECT ID, SM FROM TS ORDER BY ID" 'dml=ERR rb=1,2;2,-32768;3,3'
dml_rb_both_err "K UPDATE TS SET SM = ? + 1 WHERE ID = 1 [32767] (the sum 32768 is out of range on both)" "UPDATE TS SET SM = ? + 1 WHERE ID = 1" '[32767]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "K UPDATE TS SET SM = ? * 1 WHERE ID = 1 [-32769] (out of range on both)" "UPDATE TS SET SM = ? * 1 WHERE ID = 1" '[-32769]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_eng_only "K UPDATE T SET S = ? * 2 WHERE ID = 1 ['2.5'] (engine stores '5.0000000'; a TEXT destination for ? * k is refused at prepare - the previous binary prepared it and failed at execute)" "UPDATE T SET S = ? * 2 WHERE ID = 1" '["2.5"]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_eng_only "K UPDATE T SET S = ? * 2 WHERE ID = 1 [-2147483648] (engine stores '-4.295e+09'; refused at prepare)" "UPDATE T SET S = ? * 2 WHERE ID = 1" '[-2147483648]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "K control: UPDATE T SET N = ? * 2 WHERE ID = 1 ['1.6'] -> 1,4" "UPDATE T SET N = ? * 2 WHERE ID = 1" '["1.6"]'
dml_rb "K control: UPDATE T SET NM = ? + 0 WHERE ID = 1 ['1.115'] -> 1,1.12" "UPDATE T SET NM = ? + 0 WHERE ID = 1" '["1.115"]' "SELECT ID, NM FROM T ORDER BY ID"
# L: text_col_num's Raise class - a text whose integer digits plus the
# slot's scale exceed 18 into a SCALED slot raises *numeric value is out
# of range* at execute (the engine converts at the slot's scale into
# INT64), and CAST(text AS exact) of more than 18 significant digits
# raises the same; round 4 answered none / 2. A scale-0 slot compares
# in INT128 and answers none (control).
both_err "L IIF(NM = ?, 1, 0) = 1 [38 nines] (out of range on both: a scaled LONG slot converts the text at scale -2 into INT64; round 4 answered none)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["99999999999999999999999999999999999999"]'
both_err "L IIF(NM = ?, 1, 0) = 1 ['9223372036854775807'] (out of range on both)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["9223372036854775807"]'
both_err "L IIF(NM = ?, 1, 0) = 1 [37 nines]" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["9999999999999999999999999999999999999"]'
both_err "L IIF(NM = ?, 1, 0) = 1 ['99999999999999999'] (17 integer digits + scale 2 = 19: out of range)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["99999999999999999"]'
both "L IIF(NM = ?, 1, 0) = 1 ['9999999999999999'] -> none (16 + 2 = 18 fits)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["9999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): L IIF(NM = ?, 1, 0) = 1 ['92233720368547758.08'] -> none (exactly INT64::MAX at scale -2 fits)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["92233720368547758.08"]'
both_err "L IIF(NM = ?, 1, 0) = 1 ['92233720368547759.0'] (one past INT64::MAX at scale -2: out of range)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["92233720368547759.0"]'
both_err "L IIF(NM = ?, 1, 0) = 1 ['-99999999999999999'] (the negative side raises too)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["-99999999999999999"]'
both "L control: IIF(NM = ?, 1, 0) = 1 ['7.250'] -> 1" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["7.250"]'
both_err "L IIF(NM < ?, 1, 0) = 1 ['9223372036854775807'] (the operator does not matter)" "SELECT ID FROM T WHERE IIF(NM < ?, 1, 0) = 1" '["9223372036854775807"]'
both_err "L IIF(N41 = ?, 1, 0) = 1 ['922337203685477581'] (a NUMERIC(4,1) slot: 18 digits + scale 1 = 19)" "SELECT ID FROM TS WHERE IIF(N41 = ?, 1, 0) = 1" '["922337203685477581"]'
boundary_err "R12 boundary: conversion error by design (K2): L IIF(N41 = ?, 1, 0) = 1 ['922337203685477580.7'] -> none (fits INT64 at scale -1)" "SELECT ID FROM TS WHERE IIF(N41 = ?, 1, 0) = 1" '["922337203685477580.7"]'
boundary_err "R12 boundary: conversion error by design (K2): L control: IIF(ID = ?, 1, 0) = 1 [38 nines] -> none (a scale-0 LONG slot compares in INT128: no raise)" "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1" '["99999999999999999999999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): L control: IIF(BI = ?, 1, 0) = 1 [38 nines] -> none" "SELECT ID FROM T WHERE IIF(BI = ?, 1, 0) = 1" '["99999999999999999999999999999999999999"]'
both_err "L subquery body: ID IN (SELECT .. IIF(b.NM = ?, 1, 0) = 1) [38 nines] (out of range on both)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.NM = ?, 1, 0) = 1)" '["99999999999999999999999999999999999999"]'
dml_rb_both_err "L UPDATE T SET N = 99 WHERE IIF(NM = ?, 1, 0) = 1 [38 nines] (out of range on both, rows untouched)" "UPDATE T SET N = 99 WHERE IIF(NM = ?, 1, 0) = 1" '["99999999999999999999999999999999999999"]'
both_err "L ID = CAST(? AS INTEGER) ['2.0000000000000000001'] (out of range on both: more than 18 significant digits; both binaries answered 2)" "SELECT ID FROM T WHERE ID = CAST(? AS INTEGER)" '["2.0000000000000000001"]'
both_err "L ID = CAST(? AS INTEGER) ['2.4999999999999999999']" "SELECT ID FROM T WHERE ID = CAST(? AS INTEGER)" '["2.4999999999999999999"]'
both_err "L ID = CAST(? AS BIGINT) ['2.0000000000000000001']" "SELECT ID FROM T WHERE ID = CAST(? AS BIGINT)" '["2.0000000000000000001"]'
both_err "L ID IN (SELECT .. b.ID = CAST(? AS INTEGER)) ['2.0000000000000000001'] (in a body)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.ID = CAST(? AS INTEGER))" '["2.0000000000000000001"]'
both_err "L SELECT CAST(? AS INTEGER) FROM RDB\$DATABASE ['2.0000000000000000001']" "SELECT CAST(? AS INTEGER) AS X FROM RDB\$DATABASE" '["2.0000000000000000001"]'
both_err "L parameter-free CAST('2.0000000000000000001' AS INTEGER) (out of range on both)" "SELECT CAST('2.0000000000000000001' AS INTEGER) AS X FROM RDB\$DATABASE"
both_err "L parameter-free CAST('922337203685477580.75' AS BIGINT) (the previous binary answered 922337203685477600)" "SELECT CAST('922337203685477580.75' AS BIGINT) AS X FROM RDB\$DATABASE"
both "L control: CAST('2.5' AS INTEGER) -> 3" "SELECT CAST('2.5' AS INTEGER) AS X FROM RDB\$DATABASE"
both "L control: CAST('2.0000000000000000000' AS INTEGER) -> 2 (the zeros are not significant)" "SELECT CAST('2.0000000000000000000' AS INTEGER) AS X FROM RDB\$DATABASE"
both "L control: CAST('1e3' AS INTEGER) -> 1000" "SELECT CAST('1e3' AS INTEGER) AS X FROM RDB\$DATABASE"
both "L control: ID = CAST(? AS INTEGER) ['2.000000000000000000'] -> 2" "SELECT ID FROM T WHERE ID = CAST(? AS INTEGER)" '["2.000000000000000000"]'
both "L control: ID = CAST(? AS INTEGER) ['2.5'] -> 3" "SELECT ID FROM T WHERE ID = CAST(? AS INTEGER)" '["2.5"]'
dml_rb_both_err "L UPDATE T SET N = 99 WHERE ID = CAST(? AS INTEGER) ['2.0000000000000000001'] (out of range on both; the previous binary took row 2)" "UPDATE T SET N = 99 WHERE ID = CAST(? AS INTEGER)" '["2.0000000000000000001"]'
dml_rb "L control: UPDATE T SET N = 99 WHERE ID = CAST(? AS INTEGER) ['2.5'] -> row 3" "UPDATE T SET N = 99 WHERE ID = CAST(? AS INTEGER)" '["2.5"]'
both_err "L MOD(-9223372036854775807e0, 2) (out of range on both: approx_to_int64 rejects the 2^63 boundary; the previous binary failed with Dynamic SQL Error)" "SELECT MOD(-9223372036854775807e0, 2) AS X FROM RDB\$DATABASE"
both "L control: MOD(-9223372036854775e0, 2) -> 0" "SELECT MOD(-9223372036854775e0, 2) AS X FROM RDB\$DATABASE"
both "L control: SIGN(-SM) over the rows without the SHORT minimum -> -1;-1" "SELECT SIGN(-SM) AS X FROM TS WHERE ID <> 2 ORDER BY ID"
both "4m fixture survived the round-5 DML cells (T)" "SELECT ID, N, NM, BI, S FROM T ORDER BY ID"
both "4m fixture survived the round-5 DML cells (TS)" "SELECT ID, SM, N18, N10, N41 FROM TS ORDER BY ID"

echo "-- 4n. ROUND 6 STABILISATION PINS (refuter round 5, findings S1-S12; engine-measured 2026-09-19 three-way against /tmp/fcwire-prev-c34c1c8, scratchpad fix6.out fix6b.out fix6c.out; the helper of every cell was chosen from what the engine and this server answered, never typed) --"
# 'stabilised: refuses' cells are refusals BY DESIGN carrying the
# engine's value; 'prev' names the previous committed binary's answer.
# Recorded here and NOT pinned (a value differs on both binaries, no
# helper carries that): UPDATE T SET N = ABS(?) / ? ['7.5', '2.5']
# stores 2 (engine 3); CASE ID WHEN 1 THEN ? ELSE 0 END = I1 ['2.44']
# -> 1 (engine none); .. = DF ['2.5'] -> none (engine 1); the body
# IIF(b.ID = 2, ?, 0) = 2 ['2.4'] -> none (engine 2); CASE .. END || ''
# = '2.4' -> none (engine 2); IIF(ID = 2, -(-?), 0) = -2147483648
# [-2147483648] raises Integer overflow on both (the previous binary
# answered row 2) but the engine describes that branch `?` NOT NULL
# where this server says Nullable - the recorded NOT NULL-flag class, no
# helper carries a both-raise with a describe gap.
dml_rb "R6 floor: UPDATE T SET N = ? / ? WHERE ID = 1 ['5','2'] -> rb 1,2;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? WHERE ID = 1" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / ? WHERE ID = 1 ['7.5','2.5'] -> rb 1,2;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = -? / ? WHERE ID = 1 ['5','2'] -> rb 1,-2;2,4;3,4 (prev agreed)" "UPDATE T SET N = -? / ? WHERE ID = 1" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / -? WHERE ID = 1 ['5','2'] -> rb 1,-2;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / -? WHERE ID = 1" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = (? / ?) * 2 WHERE ID = 1 ['5','2'] -> rb 1,4;2,4;3,4 (prev agreed)" "UPDATE T SET N = (? / ?) * 2 WHERE ID = 1" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / ? / ? WHERE ID = 1 ['5','2','5'] -> rb 1,0;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? / ? WHERE ID = 1" '["5","2","5"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET BI = ? / ? WHERE ID = 1 ['5','2'] -> rb 1,2;2,8;3,7 (prev agreed)" "UPDATE T SET BI = ? / ? WHERE ID = 1" '["5","2"]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE TS SET SM = ? / ? WHERE ID = 1 ['5','2'] -> rb 1,2;2,-32768;3,3 (prev agreed)" "UPDATE TS SET SM = ? / ? WHERE ID = 1" '["5","2"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = IIF(ID = 1, ? / ?, 0) WHERE ID = 1 ['5','2'] -> rb 1,2;2,4;3,4 (prev agreed)" "UPDATE T SET N = IIF(ID = 1, ? / ?, 0) WHERE ID = 1" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = IIF(ID = 1, ? / ?, N) WHERE ID = 1 ['5','2'] -> rb 1,2;2,4;3,4 (prev agreed)" "UPDATE T SET N = IIF(ID = 1, ? / ?, N) WHERE ID = 1" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: INSERT INTO T (ID, NN, N) VALUES (9, 1, ? / ?) ['5','2'] -> rb 1,3;2,4;3,4;9,2 (prev agreed)" "INSERT INTO T (ID, NN, N) VALUES (9, 1, ? / ?)" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / ? WHERE ID = 1 RETURNING N ['5','2'] -> dml 2 rb 1,2;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? WHERE ID = 1 RETURNING N" '["5","2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / ? WHERE ID = 1 ['5',null] -> rb 1,;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? WHERE ID = 1" '["5",null]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / ? WHERE ID = 1 [5,2] -> rb 1,2;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? WHERE ID = 1" '[5,2]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / ? WHERE ID = 1 [2.5,2.5] -> rb 1,1;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? WHERE ID = 1" '[2.5,2.5]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = ? / ? WHERE ID = 1 ['2.5','2.5'] -> rb 1,1;2,4;3,4 (prev agreed)" "UPDATE T SET N = ? / ? WHERE ID = 1" '["2.5","2.5"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET N = -? / ? WHERE ID = 1 ['-2.5','-2.5'] -> rb 1,-1;2,4;3,4 (prev agreed)" "UPDATE T SET N = -? / ? WHERE ID = 1" '["-2.5","-2.5"]' "SELECT ID, N FROM T ORDER BY ID"
desc_differs "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ? / ?, 0) = 2 ['5','2'] -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, ? / ?, 0) = 2" '["5","2"]'
desc_differs "R6 floor: SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN ? / ? ELSE 0 END = 2 ['5','2'] -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN ? / ? ELSE 0 END = 2" '["5","2"]'
both "R6 floor: SELECT ID FROM T WHERE NULLIF(? / ?, 0) = 2 ['5','2'] -> 1;2;3 (prev agreed)" "SELECT ID FROM T WHERE NULLIF(? / ?, 0) = 2" '["5","2"]'
desc_differs "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, -? / ?, 0) = -2 ['5','2'] -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, -? / ?, 0) = -2" '["5","2"]'
desc_differs "R6 floor: SELECT IIF(ID = 2, ? / ?, 0) AS X FROM T ORDER BY ID ['5','2'] -> 0;2;0 (describe gap recorded; prev 0;2;0)" "SELECT IIF(ID = 2, ? / ?, 0) AS X FROM T ORDER BY ID" '["5","2"]'
desc_differs "R6 floor: SELECT IIF(ID = 2, -? / ?, 0) AS X FROM T ORDER BY ID ['5','2'] -> 0;-2;0 (describe gap recorded; prev 0;-2;0)" "SELECT IIF(ID = 2, -? / ?, 0) AS X FROM T ORDER BY ID" '["5","2"]'
desc_differs "R6 floor: SELECT IIF(ID = 2, -? / ?, 0) AS X FROM T ORDER BY ID [5,2] -> 0;-2;0 (describe gap recorded; prev 0;-2;0)" "SELECT IIF(ID = 2, -? / ?, 0) AS X FROM T ORDER BY ID" '[5,2]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = 2, ? / 2, 0) = 2) [5] (engine [2]; prev 2)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = 2, ? / 2, 0) = 2)" '[5]'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE TS SET N18 = ? / ? WHERE ID = 1 ['2.5','1.5'] -> rb 1,1.3;2,3.5;3,1.5 (prev rb 1,1.7;2,3.5;3,1.5) (engine ok => 1,2,1.3,2.5,2.5,ab  ,2.5;2,-32768, rb 1,2,1.3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,1.7,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,1.7,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N18 = ? / ? WHERE ID = 1" '["2.5","1.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,1.7;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE TS SET N18 = 2 / ? WHERE ID = 1 ['2.5'] -> rb 1,0.6;2,3.5;3,1.5 (prev rb 1,0.8;2,3.5;3,1.5) (engine ok => 1,2,0.6,2.5,2.5,ab  ,2.5;2,-32768, rb 1,2,0.6,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,0.8,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,0.8,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N18 = 2 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,0.8;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE T SET NM = 2 / ? WHERE ID = 1 ['2.5'] -> rb 1,0.66;2,1;3,2.5 (prev rb 1,0.8;2,1;3,2.5) (engine ok => 1,3,ab,0.66,9,2024-01-10T00:00:00. rb 1,3,ab,0.66,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,0.8,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,0.8,9,2024-01-10T00:00:00.000Z;2,4,cd,)" "UPDATE T SET NM = 2 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,0.8;2,1;3,2.5'
dml_rb "R6 floor: UPDATE T SET N = 10 / ? WHERE ID = 1 ['2.5'] -> rb 1,3;2,4;3,4 (prev agreed)" "UPDATE T SET N = 10 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - UPDATE TS SET N18 = 3 / ? WHERE ID = 1 ['2.5'] -> rb 1,1;2,3.5;3,1.5 (prev rb 1,1.2;2,3.5;3,1.5) (engine ok => 1,2,1,2.5,2.5,ab  ,2.5;2,-32768,3. rb 1,2,1,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1.5; this server rb 1,2,1.2,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,1.2,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N18 = 3 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,1.2;2,3.5;3,1.5'
dml_rb "R6 floor: UPDATE T SET NM = ? / 2 WHERE ID = 1 ['1.115'] -> rb 1,0.56;2,1;3,2.5 (prev agreed)" "UPDATE T SET NM = ? / 2 WHERE ID = 1" '["1.115"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE TS SET N18 = ? / 2 WHERE ID = 1 ['2.5'] -> rb 1,1.2;2,3.5;3,1.5 (prev agreed)" "UPDATE TS SET N18 = ? / 2 WHERE ID = 1" '["2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE IIF(ID = 2, 2 / ?, 0.0) = 0.6 ['2.5'] -> 2 (describe gap recorded; prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, 2 / ?, 0.0) = 0.6" '["2.5"]' "(none)"
dml_rb_desc_differs "R6 floor: UPDATE T SET NM = ABS(?) / ? WHERE ID = 1 ['7.5','2.5'] -> rb 1,3;2,1;3,2.5 (prev agreed)" "UPDATE T SET NM = ABS(?) / ? WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_desc_differs "R6 floor: UPDATE T SET NM = ABS(?) / ? WHERE ID = 1 [7.5,2.5] -> rb 1,3;2,1;3,2.5 (prev agreed)" "UPDATE T SET NM = ABS(?) / ? WHERE ID = 1" '[7.5,2.5]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET NM = D / ? WHERE ID = 1 ['0.6'] -> rb 1,2.5;2,1;3,2.5 (prev agreed)" "UPDATE T SET NM = D / ? WHERE ID = 1" '["0.6"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET NM = CAST(? AS DOUBLE PRECISION) / ? WHERE ID = 1 ['7.5','2.5'] -> rb 1,3;2,1;3,2.5 (prev agreed)" "UPDATE T SET NM = CAST(? AS DOUBLE PRECISION) / ? WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE T SET NM = 7.5e0 / ? WHERE ID = 1 ['2.5'] -> rb 1,3;2,1;3,2.5 (prev agreed)" "UPDATE T SET NM = 7.5e0 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_desc_differs "R6 floor: UPDATE T SET NM = SQRT(?) / ? WHERE ID = 1 ['6.25','2.5'] -> rb 1,1;2,1;3,2.5 (prev agreed)" "UPDATE T SET NM = SQRT(?) / ? WHERE ID = 1" '["6.25","2.5"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "R6 floor: UPDATE TS SET N18 = FL / ? WHERE ID = 1 ['0.6'] -> rb 1,4.2;2,3.5;3,1.5 (prev agreed)" "UPDATE TS SET N18 = FL / ? WHERE ID = 1" '["0.6"]' "SELECT ID, N18 FROM TS ORDER BY ID"
dml_rb_desc_differs "R6 floor: UPDATE TS SET N18 = ABS(?) / ? WHERE ID = 1 ['7.5','2.5'] -> rb 1,3;2,3.5;3,1.5 (prev agreed)" "UPDATE TS SET N18 = ABS(?) / ? WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, N18 FROM TS ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing (round 6 refused; the cut answers the previous binary's value) - UPDATE T SET NM = 7.5 / ? WHERE ID = 1 ['2.5'] (engine 1,3,ab,2.5,9; prev stored 3) (engine ok => 1,3,ab,2.5,9,2024-01-10T00:00:00.0 rb 1,3,ab,2.5,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,3,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,3,9,2024-01-10T00:00:00.000Z;2,4,cd,1,)" "UPDATE T SET NM = 7.5 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,1;3,2.5'
dml_rb_recorded "R7 recorded: pre-existing (round 6 refused; the cut answers the previous binary's value) - UPDATE T SET NM = NM / ? WHERE ID = 1 ['2.5'] (engine 1,3,ab,2.42,9; prev stored 2.9) (engine ok => 1,3,ab,2.42,9,2024-01-10T00:00:00. rb 1,3,ab,2.42,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,2.9,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,2.9,9,2024-01-10T00:00:00.000Z;2,4,cd,)" "UPDATE T SET NM = NM / ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,2.9;2,1;3,2.5'
dml_rb_recorded "R7 recorded: pre-existing (round 6 refused; the cut answers the previous binary's value) - UPDATE T SET NM = (? + 1) / ? WHERE ID = 1 ['2.5','2.5'] (engine 1,3,ab,1.17,9; prev stored 1.4) (engine ok => 1,3,ab,1.17,9,2024-01-10T00:00:00. rb 1,3,ab,1.17,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,1.4,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,1.4,9,2024-01-10T00:00:00.000Z;2,4,cd,)" "UPDATE T SET NM = (? + 1) / ? WHERE ID = 1" '["2.5","2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,1.4;2,1;3,2.5'
recorded "R7 recorded: pre-existing (round 6 refused; the cut answers the previous binary's value) - SELECT IIF(ID = 2, (? + 1) / ?, 0.0) AS X FROM T ORDER BY ID ['2.5','2.5'] (engine [0;1.16;0]; prev 0;1.4;0) (engine [0;1.16;0], this server [0;1.4;0]; prev 0;1.4;0)" "SELECT IIF(ID = 2, (? + 1) / ?, 0.0) AS X FROM T ORDER BY ID" '["2.5","2.5"]' "0;1.4;0"
both "R6 floor: SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = 3 ['2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = 3" '["2.4"]'
both "R6 floor: SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = 3 [2.4] -> 2 (prev agreed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = 3" '[2.4]'
both "R6 floor: SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 1 = 2 ['2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 1 = 2" '["2.4"]'
both "R6 floor: SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 2 = 4 ['2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 2 = 4" '["2.4"]'
both "R6 floor: SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END - 1 = 1 ['2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END - 1 = 1" '["2.4"]'
both "R6 floor: SELECT ID FROM T WHERE 1 + CASE ID WHEN 2 THEN ? ELSE 0 END = 3 ['2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE 1 + CASE ID WHEN 2 THEN ? ELSE 0 END = 3" '["2.4"]'
both "R6 floor: SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + ID = 4 ['2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + ID = 4" '["2.4"]'
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE -CASE ID WHEN 2 THEN ? ELSE 0 END = -2 ['2.4'] -> (none) (prev 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE -CASE ID WHEN 2 THEN ? ELSE 0 END = -2" '["2.4"]' "2"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE -CASE ID WHEN 2 THEN ? ELSE 0 END = -2.4 ['2.4'] -> 2 (prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE -CASE ID WHEN 2 THEN ? ELSE 0 END = -2.4" '["2.4"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 1 = 2.4 ['2.4'] -> 2 (prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 1 = 2.4" '["2.4"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1.0 = 3.4 ['2.4'] -> 2 (prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1.0 = 3.4" '["2.4"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE -(-CASE ID WHEN 2 THEN ? ELSE 0 END) = 2 ['2.4'] -> (none) (prev 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE -(-CASE ID WHEN 2 THEN ? ELSE 0 END) = 2" '["2.4"]' "2"
dml_rb "R6 floor: UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = 3 ['2.4'] -> rb 1,3;2,99;3,4 (prev agreed)" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = 3" '["2.4"]' "SELECT ID, N FROM T ORDER BY ID"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2 ['2.4'] -> (none) (prev 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '["2.4"]' "2"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2.4 ['2.4'] -> 2 (prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2.4" '["2.4"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END > 2 ['2.4'] -> 2 (prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END > 2" '["2.4"]' "(none)"
desc_differs "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = 2 ['2.4'] -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = 2" '["2.4"]'
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) + 0 = 5.08 ['2.54'] -> 2 (describe gap recorded; prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) + 0 = 5.08" '["2.54"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 5.08 ['2.54'] -> 2 (describe gap recorded; prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 5.08" '["2.54"]' "(none)"
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ? ['2.4','2.4'] (engine [2]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ?" '["2.4","2.4"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ? ['2.4','2'] (engine [(none)]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ?" '["2.4","2"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ? [2.4,2.4] (engine [2]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ?" '[2.4,2.4]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ? [2,2] (engine [2]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ?" '[2,2]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE ? = CASE ID WHEN 2 THEN ? ELSE 0 END ['2.4','2.4'] (engine [2]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE ? = CASE ID WHEN 2 THEN ? ELSE 0 END" '["2.4","2.4"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = CAST(? AS INTEGER) ['2.4','2.4'] (engine [(none)]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = CAST(? AS INTEGER)" '["2.4","2.4"]'
eng_only "R12 cap: K1: R6 SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = ? ['2.4','2.4'] -> (none) (prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = ?" '["2.4","2.4"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END = ? ['2.4','2.4'] (engine [2]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END = ?" '["2.4","2.4"]'
both "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = CAST(? AS INTEGER) ['2.4','2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = CAST(? AS INTEGER)" '["2.4","2.4"]'
dml_rb_eng_only "R6 stabilised: refuses - UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ? ['2.4','2.4'] (engine 1,3;2,99;3,4; prev prepared then Dynamic SQL Error => 1,3,a)" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ?" '["2.4","2.4"]' "SELECT ID, N FROM T ORDER BY ID"
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 0) = 3 [2] (engine [(none)]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 0) = 3" '[2]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN TRIM(?) ELSE 0 END = 3 ['2'] (engine [(none)]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN TRIM(?) ELSE 0 END = 3" '["2"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE COALESCE(TRIM(?), 0) = 3 [2] (engine [(none)]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE COALESCE(TRIM(?), 0) = 3" '[2]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE NULLIF(TRIM(?), 0) = 3 [2] (engine [(none)]; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE NULLIF(TRIM(?), 0) = 3" '[2]'
eng_only "R12 cap: K4: R6 SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 'a') = 'b' ['b '] -> 2 (describe gap recorded; prev PANICKED)" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 'a') = 'b'" '["b "]'
eng_only "R12 cap: K4: R6 SELECT ID FROM T WHERE COALESCE(TRIM(?), 'a') = 'b' ['b '] -> 1;2;3 (describe gap recorded; prev PANICKED)" "SELECT ID FROM T WHERE COALESCE(TRIM(?), 'a') = 'b'" '["b "]'
eng_only "R12 cap: K4: R6 SELECT IIF(ID = 2, TRIM(?), 'a') AS X FROM T ORDER BY ID ['b '] -> a;b;a (describe gap recorded; prev PANICKED)" "SELECT IIF(ID = 2, TRIM(?), 'a') AS X FROM T ORDER BY ID" '["b "]'
both "R6 SELECT ID FROM T WHERE IIF(ID = 2, TRIM(CAST(? AS VARCHAR(10))), 'a') = 'b' ['b '] -> 2 (prev PANICKED)" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(CAST(? AS VARCHAR(10))), 'a') = 'b'" '["b "]'
eng_only "R12 cap: K4: R6 SELECT ID FROM T WHERE IIF(ID = 2, TRIM(LEADING FROM ?), 'a') = 'b' [' b'] -> 2 (describe gap recorded; prev PANICKED)" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(LEADING FROM ?), 'a') = 'b'" '[" b"]'
dml_rb "R6 UPDATE T SET S = TRIM(?) WHERE ID = 1 [' ab '] -> rb 1,ab;2,cd;3,ef (prev PANICKED)" "UPDATE T SET S = TRIM(?) WHERE ID = 1" '[" ab "]' "SELECT ID, S FROM T ORDER BY ID"
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE TRIM(?) = 'b' ['b '] (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE TRIM(?) = 'b'" '["b "]'
panic_free "R6 S5: no connection thread PANICKED on TRIM(?) with a bare ? operand under IIF / CASE / COALESCE / NULLIF (both earlier binaries panicked at the Trim eval, index out of bounds with one argument; a panic reads as ERR in the cells above, so this cell reads the server log)"
eng_only "R7 scope cut: refuses - S5 IIF(ID = 2, TRIM(?), 0) = 3 [2] (a bare ? under TRIM into a LONG slot refuses at prepare; the engine answers none for this bind; prev prepared then failed)" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 0) = 3" '[2]'
desc_differs "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, UPPER(?), 'a') = 'B' ['b'] -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, UPPER(?), 'a') = 'B'" '["b"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = ?,... ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = ?, 1, 0) = 1)" '["12:30:00"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE ID = (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE x.ID = TS.ID A... ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE ID = (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE x.ID = TS.ID AND IIF(x.TM = ?, 1, 0) = 1)" '["12:30:00"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE EXISTS (SELECT 1 FROM (SELECT ID, TM FROM TS) x WHERE x.ID = TS.ID AN... ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE EXISTS (SELECT 1 FROM (SELECT ID, TM FROM TS) x WHERE x.ID = TS.ID AND IIF(x.TM = ?, 1, 0) = 1)" '["12:30:00"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE ID = ANY (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM =... ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE ID = ANY (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = ?, 1, 0) = 1)" '["12:30:00"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1 UNION SELE... ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1 UNION SELECT 99 FROM RDB\$DATABASE)" '["12:30:00"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1 UNION ALL ... ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1 UNION ALL SELECT 99 FROM RDB\$DATABASE)" '["12:30:00"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS WHERE IIF(TM = ?, 1, 0... ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS WHERE IIF(TM = ?, 1, 0) = 1) x)" '["12:30:00"]'
eng_only "R6 stabilised: refuses at prepare - WITH c AS (SELECT ID, TM FROM TS) SELECT ID FROM TS WHERE ID IN (SELECT c.ID FROM c WHERE IIF... ['12:30:00'] (engine [1]; prev refused)" "WITH c AS (SELECT ID, TM FROM TS) SELECT ID FROM TS WHERE ID IN (SELECT c.ID FROM c WHERE IIF(c.TM = ?, 1, 0) = 1)" '["12:30:00"]'
both "R6 SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, DT FROM T) x WHERE IIF(x.DT = ?, ... ['2024-01-10'] -> 1 (prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, DT FROM T) x WHERE IIF(x.DT = ?, 1, 0) = 1)" '["2024-01-10"]'
both "R6 SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TSP FROM TS) x WHERE IIF(x.TSP = ... ['2024-01-10 12:30:00'] -> 1 (prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TSP FROM TS) x WHERE IIF(x.TSP = ?, 1, 0) = 1)" '["2024-01-10 12:30:00"]'
both "R6 SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = CA... ['12:30:00'] -> 1 (prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = CAST(? AS TIME), 1, 0) = 1)" '["12:30:00"]'
both "R6 SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> 1 (prev refused)" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]'
both "R6 SELECT DISTINCT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> 1 (prev refused)" "SELECT DISTINCT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]'
both "R6 SELECT FIRST 2 ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> 1 (prev refused)" "SELECT FIRST 2 ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]'
both "R6 WITH c AS (SELECT ID, TM FROM TS) SELECT ID FROM c WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> 1 (prev refused)" "WITH c AS (SELECT ID, TM FROM TS) SELECT ID FROM c WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]'
both "R6 SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1 ORDER BY ID ['12:30:00'] -> 1 (prev refused)" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1 ORDER BY ID" '["12:30:00"]'
both "R6 SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1 UNION SELECT 99 FROM RDB\$DATABASE ['12:30:00'] -> 1;99 (prev refused)" "SELECT ID FROM TS WHERE IIF(TM = ?, 1, 0) = 1 UNION SELECT 99 FROM RDB\$DATABASE" '["12:30:00"]'
both "R6 SELECT ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = ?, 1, 0) = 1 ['12:30:00'] -> 1 (prev refused)" "SELECT ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = ?, 1, 0) = 1" '["12:30:00"]'
both "R6 SELECT ID, (SELECT COUNT(*) FROM T) AS C FROM TS WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> 1,3 (prev refused)" "SELECT ID, (SELECT COUNT(*) FROM T) AS C FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]'
dml_rb "R6 INSERT INTO TS (ID, TM) SELECT ID + 10, TM FROM TS WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> rb four rows, 11 inserted with TM 12:30 (prev refused)" "INSERT INTO TS (ID, TM) SELECT ID + 10, TM FROM TS WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]' "SELECT ID, TM FROM TS ORDER BY ID"
dml_rb "R6 UPDATE TS SET SM = 99 WHERE IIF(TM = ?, 1, 0) = 1 ['12:30:00'] -> rb 1,99;2,-32768;3,3 (prev refused)" "UPDATE TS SET SM = 99 WHERE IIF(TM = ?, 1, 0) = 1" '["12:30:00"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_eng_only "R6 stabilised: refuses - UPDATE TS SET SM = 99 WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM ... ['12:30:00'] (engine 1,99;2,-32768;3,3; prev refused)" "UPDATE TS SET SM = 99 WHERE ID IN (SELECT x.ID FROM (SELECT ID, TM FROM TS) x WHERE IIF(x.TM = ?, 1, 0) = 1)" '["12:30:00"]' "SELECT ID, SM FROM TS ORDER BY ID"
eng_raises_fc_refuses "R7 scope cut: refuses (the engine prepares and raises Integer overflow) - SELECT ID FROM T WHERE -(-?) + 0 = -2147483648 [-2147483648] (Integer overflow.The result of an in on both; prev refused) (engine [ERR Integer overflow.The result of an intege]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = -2147483648" '[-2147483648]'
eng_raises_fc_refuses "R7 scope cut: refuses (the engine prepares and raises Integer overflow) - SELECT ID FROM T WHERE -(-?) * 1 = -2147483648 [-2147483648] (Integer overflow.The result of an in on both; prev refused) (engine [ERR Integer overflow.The result of an intege]; prev refused)" "SELECT ID FROM T WHERE -(-?) * 1 = -2147483648" '[-2147483648]'
eng_raises_fc_refuses "R7 scope cut: refuses (the engine prepares and raises Integer overflow) - SELECT ID FROM T WHERE -(-(-?)) + 0 = -2147483648 [-2147483648] (Integer overflow.The result of an in on both; prev refused) (engine [ERR Integer overflow.The result of an intege]; prev refused)" "SELECT ID FROM T WHERE -(-(-?)) + 0 = -2147483648" '[-2147483648]'
eng_raises_fc_refuses "R7 scope cut: refuses (the engine prepares and raises Integer overflow) - SELECT ID FROM T WHERE -(-(-?)) * 1 = -2147483648 [-2147483648] (Integer overflow.The result of an in on both; prev refused) (engine [ERR Integer overflow.The result of an intege]; prev refused)" "SELECT ID FROM T WHERE -(-(-?)) * 1 = -2147483648" '[-2147483648]'
eng_raises_fc_refuses "R11 refuses (a negated whole side / a mixed IN list; the previous binary refused): R6 SELECT ID FROM T WHERE -(-?) = -2147483648 [-2147483648] (Integer overflow.The result of an in on both; prev refused)" "SELECT ID FROM T WHERE -(-?) = -2147483648" '[-2147483648]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 0 = -2147483648 ['-2147483648'] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = -2147483648" '["-2147483648"]'
both_err "R6 SELECT ID FROM T WHERE -? + 0 = 2147483648 [-2147483648] (Integer overflow.The result of an in on both; prev refused)" "SELECT ID FROM T WHERE -? + 0 = 2147483648" '[-2147483648]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 0 = 3 [3] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = 3" '[3]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) * 2 = 6 [3] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) * 2 = 6" '[3]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 0 = 3 ['3'] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = 3" '["3"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 1 = 4.5 ['3.5'] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 1 = 4.5" '["3.5"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) * 1 = NM ['7.25'] -> (none) (prev refused) (engine [(none)]; prev refused)" "SELECT ID FROM T WHERE -(-?) * 1 = NM" '["7.25"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 0 = 3.5 ['3.5'] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = 3.5" '["3.5"]'
both_err "R6 SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1 ['-9223372036854775808'] (Arithmetic exception, numeric overfl on both; prev refused)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["-9223372036854775808"]'
both_err "R6 SELECT ID FROM TS WHERE IIF(N41 = ?, 1, 0) = 1 ['-9223372036854775808'] (Arithmetic exception, numeric overfl on both; prev refused)" "SELECT ID FROM TS WHERE IIF(N41 = ?, 1, 0) = 1" '["-9223372036854775808"]'
both_err "R6 SELECT ID FROM TS WHERE IIF(N18 = ?, 1, 0) = 1 ['-9223372036854775808'] (Arithmetic exception, numeric overfl on both; prev refused)" "SELECT ID FROM TS WHERE IIF(N18 = ?, 1, 0) = 1" '["-9223372036854775808"]'
both_err "R6 SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.NM = ?, 1, 0) = 1) ['-9223372036854775808'] (Arithmetic exception, numeric overfl on both; prev refused)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.NM = ?, 1, 0) = 1)" '["-9223372036854775808"]'
dml_rb_both_err "R6 UPDATE T SET N = 99 WHERE IIF(NM = ?, 1, 0) = 1 ['-9223372036854775808'] (Arithmetic exception, numeric overflow,  on both; prev refused)" "UPDATE T SET N = 99 WHERE IIF(NM = ?, 1, 0) = 1" '["-9223372036854775808"]' "SELECT ID, N FROM T ORDER BY ID"
both_err "R6 SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1 ['9223372036854775807'] (Arithmetic exception, numeric overfl on both; prev refused)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["9223372036854775807"]'
boundary_err "R12 boundary: conversion error by design (K2): R6 SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1 ['-92233720368547758.08'] -> (none) (prev refused)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["-92233720368547758.08"]'
both_err "R6 SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1 ['-99999999999999999'] (Arithmetic exception, numeric overfl on both; prev refused)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["-99999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R6 SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1 ['-92233720368547758.07'] -> (none) (prev refused)" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1" '["-92233720368547758.07"]'
eng_only "R6 stabilised: raises at execute (restored) - SELECT CAST(TIME '01:30:00 +03:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE (engine [2026-09-18T22:30:00.000Z]; prev prepared then Conversion error from stri)" "SELECT CAST(TIME '01:30:00 +03:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE"
eng_only "R6 stabilised: raises at execute (restored) - SELECT CAST(TIME '23:30:00 -03:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE (engine [2026-09-20T02:30:00.000Z]; prev prepared then Conversion error from stri)" "SELECT CAST(TIME '23:30:00 -03:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE"
eng_only "R6 stabilised: raises at execute (restored) - SELECT CAST(CAST(TIME '01:30:00 +03:00' AS TIMESTAMP) AS DATE) AS X FROM RDB\$DATABASE (engine [2026-09-18T00:00:00.000Z]; prev prepared then Conversion error from stri)" "SELECT CAST(CAST(TIME '01:30:00 +03:00' AS TIMESTAMP) AS DATE) AS X FROM RDB\$DATABASE"
recorded "R7 recorded: pre-existing - SELECT CAST(TIME '12:30:00 +03:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE -> 2026-09-19T09:30:00.000Z (prev prepared then Conversion error from stri) (engine [2026-09-19T09:30:00.000Z], this server raises at execute; prev prepared then Conversion error from string '12)" "SELECT CAST(TIME '12:30:00 +03:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE" '[]' "ERR"
recorded "R7 recorded: pre-existing - SELECT CAST(TIME '01:30:00 +03:00' AS TIME) AS X FROM RDB\$DATABASE -> 1970-01-01T22:30:00.000Z (prev prepared then Conversion error from stri) (engine [1970-01-01T22:30:00.000Z], this server raises at execute; prev prepared then Conversion error from string '01)" "SELECT CAST(TIME '01:30:00 +03:00' AS TIME) AS X FROM RDB\$DATABASE" '[]' "ERR"
recorded "R7 recorded: pre-existing - SELECT CAST(TMZ AS TIMESTAMP) AS X FROM TS WHERE ID < 3 ORDER BY ID -> 2026-09-19T09:30:00.000Z;2026-09-19T01:0 (prev prepared then Conversion error from stri) (engine [2026-09-19T09:30:00.000Z;2026-09-19T01:0], this server raises at execute; prev prepared then Conversion error from string '12)" "SELECT CAST(TMZ AS TIMESTAMP) AS X FROM TS WHERE ID < 3 ORDER BY ID" '[]' "ERR"
recorded "R7 recorded: pre-existing - SELECT CAST(TMZ AS TIME) AS X FROM TS WHERE ID < 3 ORDER BY ID -> 1970-01-01T09:30:00.000Z;1970-01-01T01:0 (prev prepared then Conversion error from stri) (engine [1970-01-01T09:30:00.000Z;1970-01-01T01:0], this server raises at execute; prev prepared then Conversion error from string '12)" "SELECT CAST(TMZ AS TIME) AS X FROM TS WHERE ID < 3 ORDER BY ID" '[]' "ERR"
eng_only "R7 scope cut: refuses - SELECT ID FROM TS WHERE CASE ID WHEN 1 THEN ? ELSE 0 END = I1 ['2.5'] -> (none) (prev (none)) (engine [(none)]; prev (none))" "SELECT ID FROM TS WHERE CASE ID WHEN 1 THEN ? ELSE 0 END = I1" '["2.5"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM TS WHERE CASE ID WHEN 1 THEN ? ELSE 0 END = I1 [2.5] -> (none) (prev (none)) (engine [(none)]; prev (none))" "SELECT ID FROM TS WHERE CASE ID WHEN 1 THEN ? ELSE 0 END = I1" '[2.5]'
eng_only "R7 scope cut: refuses - SELECT ID FROM TS WHERE CASE ID WHEN 1 THEN ? ELSE 0 END = I1 ['2'] -> 1 (prev 1) (engine [1]; prev 1)" "SELECT ID FROM TS WHERE CASE ID WHEN 1 THEN ? ELSE 0 END = I1" '["2"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM TS WHERE IIF(ID = 1, ?, 0) = I1 ['2.5'] -> (none) (prev (none)) (engine [(none)]; prev (none))" "SELECT ID FROM TS WHERE IIF(ID = 1, ?, 0) = I1" '["2.5"]'
both "R6 floor: SELECT IIF(ID = 2, ? * 2, NM) AS X FROM T ORDER BY ID ['2.5'] -> 7.25;6;2.5 (prev agreed)" "SELECT IIF(ID = 2, ? * 2, NM) AS X FROM T ORDER BY ID" '["2.5"]'
both "R6 floor: SELECT CASE WHEN ID = 2 THEN ? * 2 ELSE NM END AS X FROM T ORDER BY ID ['2.5'] -> 7.25;6;2.5 (prev agreed)" "SELECT CASE WHEN ID = 2 THEN ? * 2 ELSE NM END AS X FROM T ORDER BY ID" '["2.5"]'
both "R6 floor: SELECT IIF(ID = 2, 2 * ?, NM) AS X FROM T ORDER BY ID ['2.5'] -> 7.25;5;2.5 (prev agreed)" "SELECT IIF(ID = 2, 2 * ?, NM) AS X FROM T ORDER BY ID" '["2.5"]'
desc_differs "R6 floor: SELECT IIF(ID = 2, ? * 2, CAST(1.5 AS NUMERIC(9,1))) AS X FROM T ORDER BY ID ['2.5'] -> 1.5;6;1.5 (describe gap recorded; prev 1.5;6;1.5)" "SELECT IIF(ID = 2, ? * 2, CAST(1.5 AS NUMERIC(9,1))) AS X FROM T ORDER BY ID" '["2.5"]'
desc_differs "R6 floor: SELECT IIF(ID = 2, ? * 2, CAST(2 AS NUMERIC(4,1))) AS X FROM T ORDER BY ID ['2.5'] -> 2;6;2 (describe gap recorded; prev 2;6;2)" "SELECT IIF(ID = 2, ? * 2, CAST(2 AS NUMERIC(4,1))) AS X FROM T ORDER BY ID" '["2.5"]'
desc_differs "R6 floor: SELECT NULLIF(? * 2, NM) AS X FROM T ORDER BY ID ['2.5'] -> 6;6;6 (describe gap recorded; prev 6;6;6)" "SELECT NULLIF(? * 2, NM) AS X FROM T ORDER BY ID" '["2.5"]'
desc_differs "R6 floor: SELECT IIF(ID = 2, ? / ?, 0) AS X FROM T ORDER BY ID [5,2] -> 0;2;0 (describe gap recorded; prev 0;2;0)" "SELECT IIF(ID = 2, ? / ?, 0) AS X FROM T ORDER BY ID" '[5,2]'
desc_differs "R6 floor: SELECT IIF(ID = 2, 2 / ?, 0) AS X FROM T ORDER BY ID [2] -> 0;1;0 (describe gap recorded; prev 0;1;0)" "SELECT IIF(ID = 2, 2 / ?, 0) AS X FROM T ORDER BY ID" '[2]'
desc_differs "R6 floor: SELECT CASE WHEN ID = 2 THEN 2 / ? ELSE 0 END AS X FROM T ORDER BY ID [2] -> 0;1;0 (describe gap recorded; prev 0;1;0)" "SELECT CASE WHEN ID = 2 THEN 2 / ? ELSE 0 END AS X FROM T ORDER BY ID" '[2]'
desc_differs "R7 floor: SELECT IIF(ID = 2, (? + 1) / ?, 0.0) AS X FROM T ORDER BY ID [5,2] (engine [0;3;0]; prev 0;3;0) -> 0;3;0 (describe gap recorded; prev 0;3;0)" "SELECT IIF(ID = 2, (? + 1) / ?, 0.0) AS X FROM T ORDER BY ID" '[5,2]'
both "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = NULL ['2.5'] -> (none) (prev agreed)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = NULL" '["2.5"]'
both "R6 floor: SELECT ID FROM T WHERE NULLIF(?, 0) = NULL ['2.5'] -> (none) (prev agreed)" "SELECT ID FROM T WHERE NULLIF(?, 0) = NULL" '["2.5"]'
both "R6 floor: SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = NULL ['2.5'] -> (none) (prev agreed)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = NULL" '["2.5"]'
both "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) > NULL ['2.5'] -> (none) (prev agreed)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) > NULL" '["2.5"]'
desc_differs "R7 floor: SELECT ID FROM T WHERE IIF(ID = 2, ? + 1, NM) = 3.5 ['2.5'] -> 2 (prev 2) -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, ? + 1, NM) = 3.5" '["2.5"]'
both "R6 floor: SELECT IIF(ID = 2, ? + 1, NM) AS X FROM T ORDER BY ID ['2.5'] -> 7.25;3.5;2.5 (prev agreed)" "SELECT IIF(ID = 2, ? + 1, NM) AS X FROM T ORDER BY ID" '["2.5"]'
both "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, NM) = 5 ['2.5'] -> (none) (prev agreed)" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, NM) = 5" '["2.5"]'
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 5.0 ['2.5'] -> 2 (describe gap recorded; prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ? * 2, 1.5) = 5.0" '["2.5"]' "(none)"
dml_rb_both_err "R6 floor: UPDATE T SET NM = -? + 0 WHERE ID = 1 ['-2147483648'] (Arithmetic exception, numeric overflow,  on both; prev prepared then Arithmetic exception, nume)" "UPDATE T SET NM = -? + 0 WHERE ID = 1" '["-2147483648"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE TS SET SM = -? + 0 WHERE ID = 1 ['-2147483648'] (Arithmetic exception, numeric overflow,  on both; prev prepared then Arithmetic exception, nume)" "UPDATE TS SET SM = -? + 0 WHERE ID = 1" '["-2147483648"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE T SET NM = +? + 0 WHERE ID = 1 ['-2147483648'] (Arithmetic exception, numeric overflow,  on both; prev prepared then Arithmetic exception, nume)" "UPDATE T SET NM = +? + 0 WHERE ID = 1" '["-2147483648"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE TS SET SM = +? + 0 WHERE ID = 1 [-2147483648] (Arithmetic exception, numeric overflow,  on both; prev prepared then Arithmetic exception, nume)" "UPDATE TS SET SM = +? + 0 WHERE ID = 1" '[-2147483648]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE T SET NM = -(+?) + 0 WHERE ID = 1 ['-2147483648'] (Arithmetic exception, numeric overflow,  on both; prev prepared then Arithmetic exception, nume)" "UPDATE T SET NM = -(+?) + 0 WHERE ID = 1" '["-2147483648"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE TS SET SM = ? + 1 WHERE ID = 1 [32767] (Arithmetic exception, numeric overflow,  on both; prev prepared then Dynamic SQL Error => 1,2,2)" "UPDATE TS SET SM = ? + 1 WHERE ID = 1" '[32767]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE TS SET SM = ? + 0 WHERE ID = 1 [-32769] (Arithmetic exception, numeric overflow,  on both; prev prepared then Arithmetic exception, nume)" "UPDATE TS SET SM = ? + 0 WHERE ID = 1" '[-32769]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE T SET N = ? + 1 WHERE ID = 1 [2147483647] (Arithmetic exception, numeric overflow,  on both; prev prepared then Dynamic SQL Error => 1,3,a)" "UPDATE T SET N = ? + 1 WHERE ID = 1" '[2147483647]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - UPDATE TS SET SM = ? + 1 WHERE ID = 1 [-32769] -> rb 1,-32768;2,-32768;3,3 (prev prepared then failed) (engine ok => 1,-32768,2.5,2.5,2.5,ab  ,2.5;2,-3 rb 1,-32768,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;; this server rb 1,2,2.5,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev prepared then Arithmetic exception, numeric ov)" "UPDATE TS SET SM = ? + 1 WHERE ID = 1" '[-32769]' "SELECT ID, SM FROM TS ORDER BY ID" 'dml=ERR rb=1,2;2,-32768;3,3'
both "R6 SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID, NM FROM T) x WHERE IIF(x.NM = ?, 1... ['7.25'] -> 1 (prev refused)" "SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID, NM FROM T) x WHERE IIF(x.NM = ?, 1, 0) = 1)" '["7.25"]'
both "R6 floor: SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID FROM T WHERE ID > ?) x) [1] -> 2;3 (prev agreed)" "SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID FROM T WHERE ID > ?) x)" '[1]'
both "R6 floor: SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID, S FROM T) x WHERE x.S = ?) ['cd'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID, S FROM T) x WHERE x.S = ?)" '["cd"]'
both "R6 floor: SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM (SELECT ID FROM T) x WHERE x.ID = T.ID AND x.ID ... [2] -> 2 (prev agreed)" "SELECT ID FROM T WHERE EXISTS (SELECT 1 FROM (SELECT ID FROM T) x WHERE x.ID = T.ID AND x.ID = ?)" '[2]'
both "R6 floor: SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.ID = ? UNION SELECT 99 FROM RDB\$DA... [2] -> 2 (prev agreed)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.ID = ? UNION SELECT 99 FROM RDB\$DATABASE)" '[2]'
both "R6 SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1 UNION ALL SE... [2] -> 2 (prev refused)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1 UNION ALL SELECT 99 FROM RDB\$DATABASE)" '[2]'
both "R6 SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID, NM FROM T WHERE IIF(NM = ?, 1, 0) ... ['7.25'] -> 1 (prev refused)" "SELECT ID FROM T WHERE ID IN (SELECT x.ID FROM (SELECT ID, NM FROM T WHERE IIF(NM = ?, 1, 0) = 1) x)" '["7.25"]'
both "R6 SELECT ID FROM T WHERE ID = (SELECT x.ID FROM (SELECT ID, NM FROM T) x WHERE x.ID = T.ID AND ... ['7.25'] -> 1 (prev refused)" "SELECT ID FROM T WHERE ID = (SELECT x.ID FROM (SELECT ID, NM FROM T) x WHERE x.ID = T.ID AND IIF(x.NM = ?, 1, 0) = 1)" '["7.25"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1) ['12:30:00'] (engine [1]; prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TM = ?, 1, 0) = 1)" '["12:30:00"]'
both "R6 SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TSP = ?, 1, 0) = 1) ['2024-01-10 12:30:00'] -> 1 (prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.TSP = ?, 1, 0) = 1)" '["2024-01-10 12:30:00"]'
both_refuse "R6 SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.DT = ?, 1, 0) = 1 UNION SELE... ['2024-01-10','2024-02-10'] (prev refused)" "SELECT ID FROM TS WHERE ID IN (SELECT b.ID FROM TS b WHERE IIF(b.DT = ?, 1, 0) = 1 UNION SELECT b.ID FROM T b WHERE IIF(b.DT = ?, 1, 0) = 1)" '["2024-01-10","2024-02-10"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = 2, ? / 2, 0) = 2) ['5'] (engine [2]; prev (none))" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = 2, ? / 2, 0) = 2)" '["5"]'
eng_only "R6 stabilised: refuses at prepare - SELECT ID FROM T WHERE CAST(? AS INTEGER) = CASE ID WHEN 2 THEN ? ELSE 0 END ['2.4','2.4'] (engine [(none)]; prev 2)" "SELECT ID FROM T WHERE CAST(? AS INTEGER) = CASE ID WHEN 2 THEN ? ELSE 0 END" '["2.4","2.4"]'
eng_only "R12 cap: K1: R7 answers (prev prepared then failed): SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = ? ['2.4','3'] (engine [2]; prev prepared then Dynamic SQL Error) -> 2 (prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END + 1 = ?" '["2.4","3"]'
eng_only "R12 cap: K1: R6 SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? + 1 ELSE 0 END = ? [2,3] -> 2 (describe gap recorded; prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? + 1 ELSE 0 END = ?" '[2,3]'
eng_only "R12 cap: K1: R6 SELECT ID FROM T WHERE COALESCE(?, 0) = ? ['2','2'] -> 1;2;3 (prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE COALESCE(?, 0) = ?" '["2","2"]'
eng_only "R12 cap: K1: R6 SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN ? ELSE 0 END = ? ['2.4','2.4'] -> (none) (prev prepared then Dynamic SQL Error)" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN ? ELSE 0 END = ?" '["2.4","2.4"]'
both_refuse "R6 SELECT ID FROM T WHERE ID * ? = ? [1,2] (prev refused)" "SELECT ID FROM T WHERE ID * ? = ?" '[1,2]'
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = 2.5 ['2.5'] -> 2 (describe gap recorded; prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = 2.5" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) + 0 = 2.5 ['2.5'] -> 2 (describe gap recorded; prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) + 0 = 2.5" '["2.5"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE IIF(ID = 2, ?, 1.5) = 2.55 ['2.55'] -> 2 (describe gap recorded; prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 1.5) = 2.55" '["2.55"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END = 2.5 ['2.51'] -> (none) (prev 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END = 2.5" '["2.51"]' "2"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END > 2.5 ['2.51'] -> 2 (prev (none)) (engine [2], this server [(none)]; prev (none))" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 1.5 END > 2.5" '["2.51"]' "(none)"
recorded "R7 recorded: pre-existing - SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ID ['2.4'] -> (none) (prev 2) (engine [(none)], this server [2]; prev 2)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = ID" '["2.4"]' "2"
both "R6 floor: SELECT CASE ID WHEN 2 THEN ? ELSE 0 END AS X FROM T ORDER BY ID ['2.4'] -> 0;2;0 (prev agreed)" "SELECT CASE ID WHEN 2 THEN ? ELSE 0 END AS X FROM T ORDER BY ID" '["2.4"]'
both "R6 floor: SELECT ID FROM T WHERE -CASE ID WHEN 2 THEN ? ELSE 0 END + 0 = -2 ['2.4'] -> 2 (prev agreed)" "SELECT ID FROM T WHERE -CASE ID WHEN 2 THEN ? ELSE 0 END + 0 = -2" '["2.4"]'
dml_rb "R6 floor: UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 1 = 2 ['2.4'] -> rb 1,3;2,99;3,4 (prev agreed)" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END * 1 = 2" '["2.4"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2 ['2.4'] -> rb 1,3;2,4;3,4 (prev rb 1,3;2,99;3,4) (engine ok => 1,3,ab,7.25,9,2024-01-10T00:00:00. rb 1,3,ab,7.25,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,7.25,9;2,99,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,7.25,9,2024-01-10T00:00:00.000Z;2,99,c)" "UPDATE T SET N = 99 WHERE CASE ID WHEN 2 THEN ? ELSE 0 END = 2" '["2.4"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,99;3,4'
both "R6 SELECT ID FROM T WHERE -? * 1 = NM ['7.25'] -> (none) (prev refused)" "SELECT ID FROM T WHERE -? * 1 = NM" '["7.25"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) * 1 = NM [7.25] -> (none) (prev refused) (engine [(none)]; prev refused)" "SELECT ID FROM T WHERE -(-?) * 1 = NM" '[7.25]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 0 = NM ['7.25'] -> 1 (prev refused) (engine [1]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = NM" '["7.25"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) / 1 = NM ['7.25'] -> 1 (prev refused) (engine [1]; prev refused)" "SELECT ID FROM T WHERE -(-?) / 1 = NM" '["7.25"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE 1 * -(-?) = NM ['7.25'] -> 1 (prev refused) (engine [1]; prev refused)" "SELECT ID FROM T WHERE 1 * -(-?) = NM" '["7.25"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 0 = -2147483649 [-2147483649] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = -2147483649" '[-2147483649]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) * 1 = 3 ['3'] -> 1;2;3 (prev refused) (engine [1;2;3]; prev refused)" "SELECT ID FROM T WHERE -(-?) * 1 = 3" '["3"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) + 0 = D ['1.5'] -> 1 (prev refused) (engine [1]; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = D" '["1.5"]'
eng_only "R7 scope cut: refuses - SELECT ID FROM T WHERE -(-?) - 0 = BI ['9'] -> 1 (prev refused) (engine [1]; prev refused)" "SELECT ID FROM T WHERE -(-?) - 0 = BI" '["9"]'
eng_only "R12 cap: K4: R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 'a') = 'b' [null] -> (none) (describe gap recorded; prev (none))" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 'a') = 'b'" '[null]'
eng_only "R12 cap: K4: R6 SELECT ID FROM T WHERE CASE ID WHEN 2 THEN TRIM(?) ELSE 'a' END = 'b' ['b '] -> 2 (describe gap recorded; prev PANICKED)" "SELECT ID FROM T WHERE CASE ID WHEN 2 THEN TRIM(?) ELSE 'a' END = 'b'" '["b "]'
eng_only "R12 cap: K4: R6 SELECT ID FROM T WHERE NULLIF(TRIM(?), 'a') = 'b' ['b '] -> 1;2;3 (prev PANICKED)" "SELECT ID FROM T WHERE NULLIF(TRIM(?), 'a') = 'b'" '["b "]'
desc_differs "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, TRIM(' ' FROM ?), 'a') = 'b' ['b '] -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(' ' FROM ?), 'a') = 'b'" '["b "]'
eng_only "R12 cap: K4: R6 SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?) || 'x', 'a') = 'bx' ['b '] -> 2 (describe gap recorded; prev PANICKED)" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?) || 'x', 'a') = 'bx'" '["b "]'
dml_rb "R6 floor: UPDATE T SET S = TRIM(?) WHERE ID = 1 [null] -> rb 1,;2,cd;3,ef (prev agreed)" "UPDATE T SET S = TRIM(?) WHERE ID = 1" '[null]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "R6 UPDATE T SET S = TRIM(LEADING FROM ?) WHERE ID = 1 [' ab '] -> rb 1,ab ;2,cd;3,ef (prev PANICKED)" "UPDATE T SET S = TRIM(LEADING FROM ?) WHERE ID = 1" '[" ab "]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "R6 UPDATE T SET S = TRIM(?) || 'x' WHERE ID = 1 [' ab '] -> rb 1,abx;2,cd;3,ef (prev PANICKED)" "UPDATE T SET S = TRIM(?) || 'x' WHERE ID = 1" '[" ab "]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_eng_only "R6 stabilised: refuses - UPDATE T SET N = TRIM(?) WHERE ID = 1 [' 5 '] (engine 1,5,ab,7.25,9; prev PANICKED)" "UPDATE T SET N = TRIM(?) WHERE ID = 1" '[" 5 "]' "SELECT ID, N FROM T ORDER BY ID"
eng_only "R6 stabilised: raises at execute (restored) - SELECT CAST(TMZ AS TIMESTAMP) AS X FROM TS ORDER BY ID (engine [2026-09-19T09:30:00.000Z;2026-09-19T01:02:03]; prev prepared then Conversion error from stri)" "SELECT CAST(TMZ AS TIMESTAMP) AS X FROM TS ORDER BY ID"
eng_only "R6 stabilised: raises at execute (restored) - SELECT CAST(TIME '20:00:00 -12:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE (engine [2026-09-20T08:00:00.000Z]; prev prepared then Conversion error from stri)" "SELECT CAST(TIME '20:00:00 -12:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE"
recorded "R7 recorded: pre-existing - SELECT CAST(TIME '00:30:00 +00:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE -> 2026-09-19T00:30:00.000Z (prev prepared then Conversion error from stri) (engine [2026-09-19T00:30:00.000Z], this server raises at execute; prev prepared then Conversion error from string '00)" "SELECT CAST(TIME '00:30:00 +00:00' AS TIMESTAMP) AS X FROM RDB\$DATABASE" '[]' "ERR"
recorded "R7 recorded: pre-existing - SELECT CAST(TZ AS TIMESTAMP) AS X FROM TS ORDER BY ID -> 2024-01-10T09:30:00.000Z;2024-02-10T00:0 (prev prepared then Conversion error from stri) (engine [2024-01-10T09:30:00.000Z;2024-02-10T00:0], this server raises at execute; prev prepared then Conversion error from string '20)" "SELECT CAST(TZ AS TIMESTAMP) AS X FROM TS ORDER BY ID" '[]' "ERR"
both_err "R6 floor: SELECT CAST(TIME '01:30:00 +03:00' AS DATE) AS X FROM RDB\$DATABASE (Conversion error from string '01:30: on both; prev prepared then Conversion error from stri)" "SELECT CAST(TIME '01:30:00 +03:00' AS DATE) AS X FROM RDB\$DATABASE"
both "R6 floor: SELECT IIF(ID = 2, ? / ?, NM) AS X FROM T ORDER BY ID ['5','2'] -> 7.25;2.5;2.5 (prev agreed)" "SELECT IIF(ID = 2, ? / ?, NM) AS X FROM T ORDER BY ID" '["5","2"]'
recorded "R7 recorded: pre-existing - SELECT IIF(ID = 2, ? * BI, NM) AS X FROM T ORDER BY ID ['2.5'] -> 7.25;20;2.5 (prev 7.25;24;2.5) (engine [7.25;20;2.5], this server [7.25;24;2.5]; prev 7.25;24;2.5)" "SELECT IIF(ID = 2, ? * BI, NM) AS X FROM T ORDER BY ID" '["2.5"]' "7.25;24;2.5"
recorded "R7 recorded: pre-existing - SELECT IIF(ID = 2, ? * 2, 1.5) AS X FROM T ORDER BY ID ['2.5'] -> 1.5;5;1.5 (describe gap recorded; prev 1.5;6;1.5) (engine [1.5;5;1.5], this server [1.5;6;1.5]; prev 1.5;6;1.5)" "SELECT IIF(ID = 2, ? * 2, 1.5) AS X FROM T ORDER BY ID" '["2.5"]' "1.5;6;1.5"
desc_differs "R6 floor: SELECT IIF(ID = 2, ? / 2, 1.5) AS X FROM T ORDER BY ID ['2.5'] -> 1.5;1.2;1.5 (describe gap recorded; prev 1.5;1.2;1.5)" "SELECT IIF(ID = 2, ? / 2, 1.5) AS X FROM T ORDER BY ID" '["2.5"]'
both_refuse "R6 SELECT COALESCE(? * 2, NM) AS X FROM T ORDER BY ID ['2.5'] (prev refused)" "SELECT COALESCE(? * 2, NM) AS X FROM T ORDER BY ID" '["2.5"]'
both "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) IS DISTINCT FROM NULL ['2.5'] -> 1;2;3 (prev agreed)" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) IS DISTINCT FROM NULL" '["2.5"]'
both "R6 floor: SELECT ID FROM T WHERE COALESCE(?, NM) = NULL ['2.5'] -> (none) (prev agreed)" "SELECT ID FROM T WHERE COALESCE(?, NM) = NULL" '["2.5"]'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE T SET NM = ID / ? WHERE ID = 1 ['2.5'] -> rb 1,0.33;2,1;3,2.5 (prev rb 1,0.4;2,1;3,2.5) (engine ok => 1,3,ab,0.33,9,2024-01-10T00:00:00. rb 1,3,ab,0.33,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,0.4,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,0.4,9,2024-01-10T00:00:00.000Z;2,4,cd,)" "UPDATE T SET NM = ID / ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,0.4;2,1;3,2.5'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE T SET NM = CAST(? AS INTEGER) / ? WHERE ID = 1 ['7','2.5'] -> rb 1,2.33;2,1;3,2.5 (prev rb 1,2.8;2,1;3,2.5) (engine ok => 1,3,ab,2.33,9,2024-01-10T00:00:00. rb 1,3,ab,2.33,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,2.8,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,2.8,9,2024-01-10T00:00:00.000Z;2,4,cd,)" "UPDATE T SET NM = CAST(? AS INTEGER) / ? WHERE ID = 1" '["7","2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,2.8;2,1;3,2.5'
dml_rb_recorded "R7 recorded: pre-existing (round 6 refused; the cut answers the previous binary's value) - UPDATE T SET NM = 2.5 / ? WHERE ID = 1 ['2.5'] (engine 1,3,ab,0.83,9; prev stored 1) (engine ok => 1,3,ab,0.83,9,2024-01-10T00:00:00. rb 1,3,ab,0.83,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,1,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,1,9,2024-01-10T00:00:00.000Z;2,4,cd,1,)" "UPDATE T SET NM = 2.5 / ? WHERE ID = 1" '["2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,1;2,1;3,2.5'
dml_rb_recorded "R7 recorded: pre-existing (round 6 refused; the cut answers the previous binary's value) - UPDATE T SET NM = COALESCE(?, 0) / ? WHERE ID = 1 ['7.5','2.5'] (engine 1,3,ab,2.66,9; prev stored 3.2) (engine ok => 1,3,ab,2.66,9,2024-01-10T00:00:00. rb 1,3,ab,2.66,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,3.2,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,3.2,9,2024-01-10T00:00:00.000Z;2,4,cd,)" "UPDATE T SET NM = COALESCE(?, 0) / ? WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,3.2;2,1;3,2.5'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE T SET NM = ? / ? / 2 WHERE ID = 1 ['7.5','2.5'] -> rb 1,1.25;2,1;3,2.5 (prev rb 1,1.5;2,1;3,2.5) (engine ok => 1,3,ab,1.25,9,2024-01-10T00:00:00. rb 1,3,ab,1.25,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,1.5,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,1.5,9,2024-01-10T00:00:00.000Z;2,4,cd,)" "UPDATE T SET NM = ? / ? / 2 WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,1.5;2,1;3,2.5'
dml_rb "R6 floor: UPDATE T SET D = ? / ? WHERE ID = 1 ['7.5','2.5'] -> rb 1,3;2,2.5;3,3.5 (prev agreed)" "UPDATE T SET D = ? / ? WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, D FROM T ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - UPDATE TS SET N18 = ? / ? WHERE ID = 1 ['-2.5','1.5'] -> rb 1,-1.3;2,3.5;3,1.5 (prev rb 1,-1.7;2,3.5;3,1.5) (engine ok => 1,2,-1.3,2.5,2.5,ab  ,2.5;2,-32768 rb 1,2,-1.3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,; this server rb 1,2,-1.7,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,; prev ok/1,2,-1.7,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.)" "UPDATE TS SET N18 = ? / ? WHERE ID = 1" '["-2.5","1.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,-1.7;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE TS SET N18 = ? / -? WHERE ID = 1 ['2.5','1.5'] -> rb 1,-1.3;2,3.5;3,1.5 (prev rb 1,-1.7;2,3.5;3,1.5) (engine ok => 1,2,-1.3,2.5,2.5,ab  ,2.5;2,-32768 rb 1,2,-1.3,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,; this server rb 1,2,-1.7,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,; prev ok/1,2,-1.7,2.5,2.5,ab  ,2.5;2,-32768,3.5,3.5,3.)" "UPDATE TS SET N18 = ? / -? WHERE ID = 1" '["2.5","1.5"]' "SELECT ID, N18 FROM TS ORDER BY ID" 'dml=(none) rb=1,-1.7;2,3.5;3,1.5'
desc_differs "R6 floor: SELECT ID FROM T WHERE IIF(ID = 2, ABS(?) / ?, 0.0) = 3.0 ['7.5','2.5'] -> 2 (describe gap recorded; prev 2)" "SELECT ID FROM T WHERE IIF(ID = 2, ABS(?) / ?, 0.0) = 3.0" '["7.5","2.5"]'
dml_rb_both_err "R6 floor: UPDATE T SET N = ? WHERE ID = 1 [2147483648] (Arithmetic exception, numeric overflow,  on both; prev prepared then Dynamic SQL Error => 1,3,a)" "UPDATE T SET N = ? WHERE ID = 1" '[2147483648]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE T SET NM = ? * 2 WHERE ID = 1 ['30000000'] (Arithmetic exception, numeric overflow,  on both; prev prepared then Dynamic SQL Error => 1,3,a)" "UPDATE T SET NM = ? * 2 WHERE ID = 1" '["30000000"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE TS SET SM = ? WHERE ID = 1 ['40000'] (Arithmetic exception, numeric overflow,  on both; prev prepared then Dynamic SQL Error => 1,2,2)" "UPDATE TS SET SM = ? WHERE ID = 1" '["40000"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R6 floor: UPDATE T SET N = COALESCE(?, 0) WHERE ID = 1 [2147483648] (Arithmetic exception, numeric overflow,  on both; prev prepared then Arithmetic exception, nume)" "UPDATE T SET N = COALESCE(?, 0) WHERE ID = 1" '[2147483648]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_recorded "R7 recorded: pre-existing - UPDATE TS SET N41 = ? / ? WHERE ID = 1 ['2.5', '1.5'] -> 1,1.3 (a SHORT destination: the dividend at the doubled scale in the destination's width; prev 1.7) (engine ok => 1,2,2.5,2.5,1.3,ab  ,2.5;2,-32768, rb 1,2,2.5,2.5,1.3,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; this server rb 1,2,2.5,2.5,1.7,ab  ,2.5;2,-32768,3.5,3.5,3.5,cd  ,3.5;3,3,1; prev ok/1,2,2.5,2.5,1.7,ab  ,2.5;2,-32768,3.5,3.5,3.5)" "UPDATE TS SET N41 = ? / ? WHERE ID = 1" '["2.5","1.5"]' "SELECT ID, N41 FROM TS ORDER BY ID" 'dml=(none) rb=1,1.7;2,3.5;3,1.5'
dml_rb_recorded "R7 recorded: pre-existing - UPDATE T SET NM = ? / ? WHERE ID = 1 ['7.5', '2.5'] -> 1,2.5 (7.5 at -4 over the rounded 3; prev 3) (engine ok => 1,3,ab,2.5,9,2024-01-10T00:00:00.0 rb 1,3,ab,2.5,9;2,4,cd,1,8;3,4,ef,2.5,7; this server rb 1,3,ab,3,9;2,4,cd,1,8;3,4,ef,2.5,7; prev ok/1,3,ab,3,9,2024-01-10T00:00:00.000Z;2,4,cd,1,)" "UPDATE T SET NM = ? / ? WHERE ID = 1" '["7.5","2.5"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,1;3,2.5'
both "4n fixture survived the round-6 DML cells (T)" "SELECT ID, N, NM, BI, S FROM T ORDER BY ID"
both "4n fixture survived the round-6 DML cells (TS)" "SELECT ID, SM, N18, N10, N41, I1 FROM TS ORDER BY ID"

# S12: the error TEXT of a store overflow and of an Integer overflow
err_msg "R6 floor: S12 UPDATE T SET NM = -? + 0 WHERE ID = 1 ['-2147483648'] raises the engine's *numeric value is out of range* (round 5 said Dynamic SQL Error; prev agreed)" "UPDATE T SET NM = -? + 0 WHERE ID = 1" '["-2147483648"]'
err_msg "R6 S12 UPDATE TS SET SM = -? + 0 WHERE ID = 1 ['-2147483648'] raises *numeric value is out of range* (prev Dynamic SQL Error)" "UPDATE TS SET SM = -? + 0 WHERE ID = 1" '["-2147483648"]'
err_msg "R6 S12 UPDATE TS SET SM = ? + 1 WHERE ID = 1 [32767] raises *numeric value is out of range* (prev Dynamic SQL Error)" "UPDATE TS SET SM = ? + 1 WHERE ID = 1" '[32767]'
err_msg "R6 S12 UPDATE T SET N = ? + 1 WHERE ID = 1 [2147483647] raises *numeric value is out of range* (prev Dynamic SQL Error)" "UPDATE T SET N = ? + 1 WHERE ID = 1" '[2147483647]'
eng_raises_fc_refuses "R7 scope cut: refuses - S7 -(-?) + 0 = -2147483648 [-2147483648] (a 2+ minus chain under an operator on a compare side; the engine prepares and raises Integer overflow; prev refused)" "SELECT ID FROM T WHERE -(-?) + 0 = -2147483648" '[-2147483648]'
panic_free "R6 section 4n ran without a server panic"

echo "-- 4o. ROUND 8 PINS (the scope-cut refuter's Q1-Q4; three-way measured 2026-09-19 against /tmp/fcwire-prev-c34c1c8, scratchpad r8/final-*.out) --"
# Q1: a negated `?` under the scale-0 multiply rounding cast negates at
# the MESSAGE width ('floor:' - the previous binary answers each like the
# engine; the cut raised Integer overflow)
both "R8 Q1 floor: IIF(ID = 2, -? * 1, N41) [-32768] -> 2.5;32768;1.5" "SELECT IIF(ID = 2, -? * 1, N41) AS X FROM TS ORDER BY ID" '[-32768]'
both "R8 Q1 floor: IIF(ID = 2, -? * 1, N41) ['-32768'] -> 2.5;32768;1.5" "SELECT IIF(ID = 2, -? * 1, N41) AS X FROM TS ORDER BY ID" '["-32768"]'
both "R8 Q1 floor: IIF(ID = 2, -? * 1, N41) ['-32768.0']" "SELECT IIF(ID = 2, -? * 1, N41) AS X FROM TS ORDER BY ID" '["-32768.0"]'
both "R8 Q1 floor: IIF(ID = 2, -? * 1, N41) [' -32768']" "SELECT IIF(ID = 2, -? * 1, N41) AS X FROM TS ORDER BY ID" '[" -32768"]'
both "R8 Q1 floor: IIF(ID = 2, -? * 1, N41) ['-32767.6'] -> 32768 (the operand reads the text at its own width)" "SELECT IIF(ID = 2, -? * 1, N41) AS X FROM TS ORDER BY ID" '["-32767.6"]'
both "R8 Q1 floor: IIF(ID = 2, -? * 2, N41) [-32768] -> 2.5;65536;1.5" "SELECT IIF(ID = 2, -? * 2, N41) AS X FROM TS ORDER BY ID" '[-32768]'
both "R8 Q1 control: IIF(ID = 2, -? * 1, N41) [-32767] -> 32767" "SELECT IIF(ID = 2, -? * 1, N41) AS X FROM TS ORDER BY ID" '[-32767]'
desc_differs "R8 Q1 floor: WHERE IIF(ID = 2, -? * 1, N41) = 32768 [-32768] -> 2 (the SHORT-vs-LONG describe gap is pre-existing, shared with prev)" "SELECT ID FROM TS WHERE IIF(ID = 2, -? * 1, N41) = 32768 ORDER BY ID" '[-32768]'
desc_differs "R8 Q1 floor: WHERE IIF(ID = 2, -? * 1, N41) = 32768 ['-32768'] -> 2" "SELECT ID FROM TS WHERE IIF(ID = 2, -? * 1, N41) = 32768 ORDER BY ID" '["-32768"]'
dml_rb_desc_differs "R8 Q1 floor: UPDATE TS SET SM = 99 WHERE IIF(ID = 2, -? * 1, N41) = 32768 [-32768] -> row 2" "UPDATE TS SET SM = 99 WHERE IIF(ID = 2, -? * 1, N41) = 32768" '[-32768]' "SELECT ID, SM FROM TS ORDER BY ID"
both "R8 Q1 floor: IIF(ID = 2, -? * 1, NM) ['-2147483648'] -> 7.25;2147483648;2.5" "SELECT IIF(ID = 2, -? * 1, NM) AS X FROM T ORDER BY ID" '["-2147483648"]'
both "R8 Q1 floor: IIF(ID = 2, -? * 2, NM) ['-2147483648'] -> 7.25;4294967296;2.5" "SELECT IIF(ID = 2, -? * 2, NM) AS X FROM T ORDER BY ID" '["-2147483648"]'
both "R8 Q1 floor: CASE WHEN ID = 2 THEN -? * 1 ELSE NM END ['-2147483648']" "SELECT CASE WHEN ID = 2 THEN -? * 1 ELSE NM END AS X FROM T ORDER BY ID" '["-2147483648"]'
desc_differs "R8 Q1 floor: NULLIF(-? * 1, NM) ['-2147483648'] -> 2147483648 x3 (the output scale gap is pre-existing)" "SELECT NULLIF(-? * 1, NM) AS X FROM T ORDER BY ID" '["-2147483648"]'
desc_differs "R8 Q1 floor: WHERE IIF(ID = 2, -? * 1, NM) = 2147483648 ['-2147483648'] -> 2" "SELECT ID FROM T WHERE IIF(ID = 2, -? * 1, NM) = 2147483648 ORDER BY ID" '["-2147483648"]'
dml_rb_desc_differs "R8 Q1 floor: UPDATE T SET N = 99 WHERE IIF(ID = 2, -? * 1, NM) = 2147483648 ['-2147483648'] -> row 2" "UPDATE T SET N = 99 WHERE IIF(ID = 2, -? * 1, NM) = 2147483648" '["-2147483648"]' "SELECT ID, N FROM T ORDER BY ID"
both_err "R8 Q1: IIF(ID = 2, -? * 1, NM) [-2147483648] - the 4-byte message minimum still overflows (Integer overflow on both)" "SELECT IIF(ID = 2, -? * 1, NM) AS X FROM T ORDER BY ID" '[-2147483648]'
dml_rb "R8 Q1 floor: UPDATE T SET NM = -? * 2 WHERE ID = 1 ['1.25'] -> 1,-2 (chunk 45's rule stands)" "UPDATE T SET NM = -? * 2 WHERE ID = 1" '["1.25"]' "SELECT ID, NM FROM T ORDER BY ID"
# ...and the operand class its '-32767.6' twin exposed: an implicit slot
# cast that is a direct OPERAND reads a long-coefficient text at the
# operator's width ('floor:' - the previous binary answers like the engine)
dml_rb "R8 Q1 floor: UPDATE T SET N = ? + 1 WHERE ID = 1 ['1.999999999999'] -> 1,3" "UPDATE T SET N = ? + 1 WHERE ID = 1" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE T SET N = -? WHERE ID = 1 ['-1.999999999999'] -> 1,2" "UPDATE T SET N = -? WHERE ID = 1" '["-1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE T SET N = 1 - ? WHERE ID = 1 ['1.999999999999'] -> 1,-1" "UPDATE T SET N = 1 - ? WHERE ID = 1" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE T SET N = ? / 1 WHERE ID = 1 ['1.999999999999'] -> 1,2" "UPDATE T SET N = ? / 1 WHERE ID = 1" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE T SET N = MOD(?, 5) WHERE ID = 1 ['1.999999999999'] -> 1,2" "UPDATE T SET N = MOD(?, 5) WHERE ID = 1" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE T SET NM = ? * 1 WHERE ID = 1 ['1.999999999999'] -> 1,2" "UPDATE T SET NM = ? * 1 WHERE ID = 1" '["1.999999999999"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE T SET NM = -? * 1 WHERE ID = 1 ['-1.999999999999'] -> 1,2" "UPDATE T SET NM = -? * 1 WHERE ID = 1" '["-1.999999999999"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE TS SET SM = ? + 0 WHERE ID = 1 ['1.999999'] -> 1,2" "UPDATE TS SET SM = ? + 0 WHERE ID = 1" '["1.999999"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "R8 Q1 floor: UPDATE TS SET N41 = ? * 1 WHERE ID = 1 ['2.00001'] -> 1,2" "UPDATE TS SET N41 = ? * 1 WHERE ID = 1" '["2.00001"]' "SELECT ID, N41 FROM TS ORDER BY ID"
dml_rb_desc_differs "R8 Q1 floor: UPDATE T SET N = ABS(?) WHERE ID = 1 ['-1.999999999999'] -> 1,2 (the DOUBLE-vs-LONG describe gap is pre-existing)" "UPDATE T SET N = ABS(?) WHERE ID = 1" '["-1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
both "R8 Q1 floor: IIF(ID = 2, ? * 1, N41) ['3276.75'] -> 2.5;3277;1.5" "SELECT IIF(ID = 2, ? * 1, N41) AS X FROM TS ORDER BY ID" '["3276.75"]'
both "R8 Q1 floor: IIF(ID = 2, ? * 1, N41) ['2.00001'] -> 2.5;2;1.5" "SELECT IIF(ID = 2, ? * 1, N41) AS X FROM TS ORDER BY ID" '["2.00001"]'
both "R8 Q1 floor: IIF(ID = 2, -? * 1, N41) ['-2.00001'] -> 2.5;2;1.5" "SELECT IIF(ID = 2, -? * 1, N41) AS X FROM TS ORDER BY ID" '["-2.00001"]'
both "R8 Q1 floor: IIF(ID = 2, ? * 1, NM) ['214748364.75'] -> 7.25;214748365;2.5" "SELECT IIF(ID = 2, ? * 1, NM) AS X FROM T ORDER BY ID" '["214748364.75"]'
both "R8 Q1 floor: IIF(ID = 2, ? + 1, N) ['1.999999999999'] -> 3;3;4" "SELECT IIF(ID = 2, ? + 1, N) AS X FROM T ORDER BY ID" '["1.999999999999"]'
both "R8 Q1 floor: IIF(ID = 2, ? * 1, SM) ['1.999999'] -> 2;2;3" "SELECT IIF(ID = 2, ? * 1, SM) AS X FROM TS ORDER BY ID" '["1.999999"]'
both "R8 Q1 floor: IIF(ID = 2, ? / 1, N) ['1.999999999999'] -> 3;2;4" "SELECT IIF(ID = 2, ? / 1, N) AS X FROM T ORDER BY ID" '["1.999999999999"]'
# ...and a VALUE position READS THE TEXT AS THE PREVIOUS BINARY DID (round
# 10). Rounds 8-9 kept the slot-width gate here, right for these six but
# wrong beside a WIDER sibling (`SET N = IIF(ID = 1, ?, BI)`, where the
# engine reads at INT64 and stores 5 - the round-9 refuter's 78 shapes),
# so the implicit position no longer carries the law: the previous
# binary's wrong answer is back, recorded with the engine's raise
# (measured three-way 2026-09-19, scratchpad r10fx/fail18.out)
recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q1 IIF(ID = 2, ?, N) ['1.999999999999'] - engine raises out of range; this server and the previous binary answer 3;2;4" "SELECT IIF(ID = 2, ?, N) AS X FROM T ORDER BY ID" '["1.999999999999"]' '3;2;4'
recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q1 COALESCE(?, N) ['1.999999999999'] - engine raises out of range; this server and the previous binary answer 2;2;2" "SELECT COALESCE(?, N) AS X FROM T ORDER BY ID" '["1.999999999999"]' '2;2;2'
recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q1 WHERE IIF(ID = 2, ?, N) = 2 ['1.999999999999'] - engine raises out of range; this server and the previous binary answer 2" "SELECT ID FROM T WHERE IIF(ID = 2, ?, N) = 2 ORDER BY ID" '["1.999999999999"]' '2'
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q1 UPDATE T SET N = IIF(ID = 1, ?, N) WHERE ID = 1 ['1.999999999999'] - engine raises out of range; this server and the previous binary store 2" "UPDATE T SET N = IIF(ID = 1, ?, N) WHERE ID = 1" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,2;2,4;3,4'
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q1 UPDATE T SET N = ? || '' WHERE ID = 1 ['1.999999999999'] - engine raises out of range; this server and the previous binary store 2" "UPDATE T SET N = ? || '' WHERE ID = 1" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,2;2,4;3,4'
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q1 UPDATE T SET N = COALESCE(?, 0) WHERE ID = 1 ['1.999999999999'] - engine raises out of range; this server and the previous binary store 2" "UPDATE T SET N = COALESCE(?, 0) WHERE ID = 1" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,2;2,4;3,4'

# Q2: an exponent spelling into an exact NUMERIC - the parameter-free CAST
both "R8 Q2: CAST('2.5e0' AS NUMERIC(9,2)) -> 2.5" "SELECT CAST('2.5e0' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('1e-40' AS NUMERIC(9,2)) -> 0" "SELECT CAST('1e-40' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('2.555e0' AS NUMERIC(9,2)) -> 2.56" "SELECT CAST('2.555e0' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('-2.555e0' AS NUMERIC(9,2)) -> -2.56" "SELECT CAST('-2.555e0' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('2.545e0' AS NUMERIC(9,2)) -> 2.55" "SELECT CAST('2.545e0' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST(' 25e-1 ' AS NUMERIC(9,2)) -> 2.5" "SELECT CAST(' 25e-1 ' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('3e2' AS NUMERIC(9,2)) -> 300" "SELECT CAST('3e2' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('1e-400' AS NUMERIC(9,2)) -> 0" "SELECT CAST('1e-400' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('5e-3' AS NUMERIC(9,2)) -> 0.01" "SELECT CAST('5e-3' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('4.99e-3' AS NUMERIC(9,2)) -> 0" "SELECT CAST('4.99e-3' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('2147483647e-2' AS NUMERIC(9,2)) -> 21474836.47" "SELECT CAST('2147483647e-2' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('-2147483648e-2' AS NUMERIC(9,2)) -> -21474836.48" "SELECT CAST('-2147483648e-2' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('0.0000000001e10' AS NUMERIC(9,2)) -> 1" "SELECT CAST('0.0000000001e10' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('+.5e1' AS NUMERIC(9,2)) -> 5" "SELECT CAST('+.5e1' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('3276.7e0' AS NUMERIC(4,1)) -> 3276.7" "SELECT CAST('3276.7e0' AS NUMERIC(4,1)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('-3276.8e0' AS NUMERIC(4,1)) -> -3276.8" "SELECT CAST('-3276.8e0' AS NUMERIC(4,1)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('2.5e0' AS NUMERIC(18,1)) -> 2.5" "SELECT CAST('2.5e0' AS NUMERIC(18,1)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('1.23456e2' AS DECIMAL(4,1)) -> 123.5" "SELECT CAST('1.23456e2' AS DECIMAL(4,1)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('2.5e0' AS NUMERIC(9,0)) -> 3" "SELECT CAST('2.5e0' AS NUMERIC(9,0)) AS X FROM RDB\$DATABASE"
both "R8 Q2: CAST('1.23456e2' AS DECIMAL(18,4)) -> 123.456" "SELECT CAST('1.23456e2' AS DECIMAL(18,4)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('3e20' AS NUMERIC(9,2)) - out of range on both" "SELECT CAST('3e20' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('1e400' AS NUMERIC(9,2)) - out of range" "SELECT CAST('1e400' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('1e-3276' AS NUMERIC(9,2)) - the exponent limit" "SELECT CAST('1e-3276' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('2147483648e-2' AS NUMERIC(9,2)) - the mantissa past the backing" "SELECT CAST('2147483648e-2' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('2.50000000000e0' AS NUMERIC(9,2)) - fraction zeros are forgiven only at the END" "SELECT CAST('2.50000000000e0' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('100000000000e-10' AS NUMERIC(9,2)) - integer zeros are never dropped" "SELECT CAST('100000000000e-10' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('3276.8e0' AS NUMERIC(4,1)) - the SHORT backing" "SELECT CAST('3276.8e0' AS NUMERIC(4,1)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2: CAST('1e18' AS NUMERIC(18,1)) - the INT64 backing" "SELECT CAST('1e18' AS NUMERIC(18,1)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2 control: CAST('1e' AS NUMERIC(9,2)) - conversion error on both" "SELECT CAST('1e' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2 control: CAST('2.5 e0' AS NUMERIC(9,2))" "SELECT CAST('2.5 e0' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
both_err "R8 Q2 control: CAST('1e+-1' AS NUMERIC(9,2))" "SELECT CAST('1e+-1' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE"
recorded "R8 Q2 recorded: pre-existing - CAST('2.5e0' AS NUMERIC(38,2)) (an INT128 backing; the engine 2.5, both binaries Conversion error)" "SELECT CAST('2.5e0' AS NUMERIC(38,2)) AS X FROM RDB\$DATABASE" '[]' 'ERR'
recorded "R8 Q2 recorded: pre-existing - CAST('0x10' AS NUMERIC(9,2)) (a hex text; the engine 16, both binaries Conversion error)" "SELECT CAST('0x10' AS NUMERIC(9,2)) AS X FROM RDB\$DATABASE" '[]' 'ERR'
# ...under the compare-side rung (prev refused every one; the cut prepared then raised)
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? + 0 = NM ['2.5e0'] -> 3" "SELECT ID FROM T WHERE ? + 0 = NM ORDER BY ID" '["2.5e0"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? + 0 = NM ['1e0'] -> 2" "SELECT ID FROM T WHERE ? + 0 = NM ORDER BY ID" '["1e0"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? + 0 = NM ['3e2'] -> none" "SELECT ID FROM T WHERE ? + 0 = NM ORDER BY ID" '["3e2"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? + 0 = NM ['1e-40'] -> none" "SELECT ID FROM T WHERE ? + 0 = NM ORDER BY ID" '["1e-40"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: NM = ? + 0 ['25e-1'] -> 3" "SELECT ID FROM T WHERE NM = ? + 0 ORDER BY ID" '["25e-1"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? / 1 = NM ['0.25e1'] -> 3" "SELECT ID FROM T WHERE ? / 1 = NM ORDER BY ID" '["0.25e1"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? * 1.5 = 3.0 ['2e0'] -> 1;2;3" "SELECT ID FROM T WHERE ? * 1.5 = 3.0 ORDER BY ID" '["2e0"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? * 1 = N18 ['1e0'] -> none" "SELECT ID FROM TS WHERE ? * 1 = N18 ORDER BY ID" '["1e0"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? * 1 = N18 ['2.5E0'] -> 1" "SELECT ID FROM TS WHERE ? * 1 = N18 ORDER BY ID" '["2.5E0"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? + 0 = N41 ['250e-2'] -> 1" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["250e-2"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: IIF(? + 0 = NM, 1, 0) = 1 ['2.5e+0'] -> 3" "SELECT ID FROM T WHERE IIF(? + 0 = NM, 1, 0) = 1 ORDER BY ID" '["2.5e+0"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: ? + 0 = NM ['7.25e0'] -> 1" "SELECT ID FROM T WHERE ? + 0 = NM ORDER BY ID" '["7.25e0"]'
both_err "R8 Q2: ? + 0 = NM ['1e'] - conversion error on both" "SELECT ID FROM T WHERE ? + 0 = NM ORDER BY ID" '["1e"]'
boundary_err "R12 boundary: conversion error by design (K2): R8 Q2: UPDATE T SET N = 99 WHERE ? + 0 = NM ['2.5e0'] -> row 3" "UPDATE T SET N = 99 WHERE ? + 0 = NM" '["2.5e0"]' "SELECT ID, N FROM T ORDER BY ID"
both "R8 Q2: CAST(? AS NUMERIC(9,2)) = NM ['2.5e0'] -> 3 (both binaries raised)" "SELECT ID FROM T WHERE CAST(? AS NUMERIC(9,2)) = NM ORDER BY ID" '["2.5e0"]'
# (the exponent read is a written CAST's and a compare rung's; an OPERAND
# keeps the previous binary's conversion error - round 10)
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q2 UPDATE T SET NM = ? + 0 WHERE ID = 1 ['2.5e0'] - engine stores 2.5; this server and the previous binary fail (conversion error)" "UPDATE T SET NM = ? + 0 WHERE ID = 1" '["2.5e0"]' "SELECT ID, NM FROM T ORDER BY ID" 'dml=ERR rb=1,7.25;2,1;3,2.5'
dml_rb "R8 Q2: UPDATE T SET NM = CAST(? AS NUMERIC(9,2)) WHERE ID = 1 ['2.555e0'] -> 1,2.56" "UPDATE T SET NM = CAST(? AS NUMERIC(9,2)) WHERE ID = 1" '["2.555e0"]' "SELECT ID, NM FROM T ORDER BY ID"
recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R8 Q2 IIF(ID = 2, ? + 0, NM) ['25e-1'] - engine 7.25;2.5;2.5; this server and the previous binary fail (conversion error)" "SELECT IIF(ID = 2, ? + 0, NM) AS X FROM T ORDER BY ID" '["25e-1"]' 'ERR'

# Q3: `? * ?` under a 2/4-byte slot multiplies in INT64
both_err "R8 Q3: ? * ? = 4 [3037000500, 3037000500] - Integer overflow on both" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '[3037000500, 3037000500]'
both_err "R8 Q3: ? * ? = 4 [100000000000, 100000000000]" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '[100000000000, 100000000000]'
both_err "R8 Q3: ? * ? = 4 ['3037000500', '3037000500'] - a text bind the same" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '["3037000500", "3037000500"]'
both_err "R8 Q3: ? * ? = 4 [-3037000500, 3037000500]" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '[-3037000500, 3037000500]'
both "R8 Q3: ? * ? = 4 [3037000499, 3037000499] -> none (the last product that fits)" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '[3037000499, 3037000499]'
both "R8 Q3: ? * ? = 4 [2, 2] -> 1;2;3" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '[2, 2]'
both "R8 Q3: ? * ? = 4 ['3000000000', '3000000000'] -> none" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '["3000000000", "3000000000"]'
both "R8 Q3: ? * ? = 4 [null, 3037000500] -> none" "SELECT ID FROM T WHERE ? * ? = 4 ORDER BY ID" '[null, 3037000500]'
both_err "R8 Q3: N = ? * ? [3037000500, 3037000500]" "SELECT ID FROM T WHERE N = ? * ? ORDER BY ID" '[3037000500, 3037000500]'
both_err "R8 Q3: ? * ? = NM [30370005, 30370005] - the product at scale -4" "SELECT ID FROM T WHERE ? * ? = NM ORDER BY ID" '[30370005, 30370005]'
both "R8 Q3: ? * ? = NM ['1', '2.5'] -> 3 (the side rule stands)" "SELECT ID FROM T WHERE ? * ? = NM ORDER BY ID" '["1", "2.5"]'
both_err "R8 Q3: ? * ? = SM [3037000500, 3037000500] - a SHORT slot" "SELECT ID FROM TS WHERE ? * ? = SM ORDER BY ID" '[3037000500, 3037000500]'
both "R8 Q3: ? * ? = BI [3037000500, 3037000500] -> none (an INT64 slot: the int128 branch)" "SELECT ID FROM T WHERE ? * ? = BI ORDER BY ID" '[3037000500, 3037000500]'
both_err "R8 Q3: -? * ? = 4 [3037000500, 3037000500]" "SELECT ID FROM T WHERE -? * ? = 4 ORDER BY ID" '[3037000500, 3037000500]'
both_err "R8 Q3: ? * ? * 2 = 4 [3037000500, 3037000500]" "SELECT ID FROM T WHERE ? * ? * 2 = 4 ORDER BY ID" '[3037000500, 3037000500]'
both_err "R8 Q3: IIF(? * ? = 4, 1, 0) = 1 [3037000500, 3037000500]" "SELECT ID FROM T WHERE IIF(? * ? = 4, 1, 0) = 1 ORDER BY ID" '[3037000500, 3037000500]'
dml_rb_both_err "R8 Q3: UPDATE T SET N = 99 WHERE ? * ? = 4 [3037000500, 3037000500]" "UPDATE T SET N = 99 WHERE ? * ? = 4" '[3037000500, 3037000500]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R8 Q3: DELETE FROM T WHERE ? * ? = 4 [3037000500, 3037000500]" "DELETE FROM T WHERE ? * ? = 4" '[3037000500, 3037000500]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R8 Q3: UPDATE T SET N = 99 WHERE ? * ? = 4 [2, 2] -> every row" "UPDATE T SET N = 99 WHERE ? * ? = 4" '[2, 2]' "SELECT ID, N FROM T ORDER BY ID"

# Q4: a bare `?` in a TEXT-reconciled COALESCE checks its length when evaluated
both_err "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ['2.5'] - string right truncation on both" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '["2.5"]'
both_err "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ['2.5  ']" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '["2.5  "]'
both_err "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 [' 2'] - a leading blank counts" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '[" 2"]'
both_err "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ['cd']" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '["cd"]'
both_err "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 [25] - an integer message as its digits" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '[25]'
both "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ['2'] -> 2" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '["2"]'
both "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ['2 '] -> 2 (trailing blanks fit)" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '["2 "]'
both "R8 Q4: IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 [2] -> 2" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '[2]'
both "R8 Q4: IIF(ID = 99, COALESCE(?, 'x'), 0) = 2 ['2.5'] -> none (never evaluated, never raised)" "SELECT ID FROM T WHERE IIF(ID = 99, COALESCE(?, 'x'), 0) = 2 ORDER BY ID" '["2.5"]'
both_err "R8 Q4: CASE WHEN ID = 2 THEN COALESCE(?, 'x') ELSE 0 END = 2 ['2.5']" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN COALESCE(?, 'x') ELSE 0 END = 2 ORDER BY ID" '["2.5"]'
both_err "R8 Q4: NULLIF(COALESCE(?, 'x'), 'q') = 2 ['2.5']" "SELECT ID FROM T WHERE NULLIF(COALESCE(?, 'x'), 'q') = 2 ORDER BY ID" '["2.5"]'
both_err "R8 Q4: IIF(ID = 2, COALESCE(?, S), 0) = 2 ['2.500000000'] - a VARCHAR(10) sibling" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 0) = 2 ORDER BY ID" '["2.500000000"]'
both "R8 Q4: IIF(ID = 2, COALESCE(?, S), 0) = 2 ['2.50000000  '] -> none" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 0) = 2 ORDER BY ID" '["2.50000000  "]'
both_err "R8 Q4: IIF(ID = 2, COALESCE(?, 'xy'), 'q') = 'cd' ['cde']" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xy'), 'q') = 'cd' ORDER BY ID" '["cde"]'
dml_rb_both_err "R8 Q4: UPDATE T SET N = 99 WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ['2.5']" "UPDATE T SET N = 99 WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2" '["2.5"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R8 Q4: UPDATE T SET N = 99 WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 ['2'] -> row 2" "UPDATE T SET N = 99 WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2" '["2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R8 Q4: UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1 ['abc'] (the previous binary stored abc)" "UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1" '["abc"]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "R8 Q4 floor: UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1 ['a'] -> 1,a" "UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1" '["a"]' "SELECT ID, S FROM T ORDER BY ID"
recorded "R8 Q4 recorded: pre-existing - COALESCE(?, 'x') = 'x' ['abc'] -> none (the top-level COALESCE of the projection router carries no check; the engine string right truncation; prev none)" "SELECT ID FROM T WHERE COALESCE(?, 'x') = 'x' ORDER BY ID" '["abc"]' '(none)'
both "4o fixture survived the round-8 DML cells (T)" "SELECT ID, N, NM, BI, S FROM T ORDER BY ID"
both "4o fixture survived the round-8 DML cells (TS)" "SELECT ID, SM, N18, N10, N41, I1 FROM TS ORDER BY ID"
panic_free "R8 section 4o ran without a server panic"

echo "-- 4p. ROUND 9 PINS (the commit-gate refuter's findings; P1 the structural coefficient gate across MERGE / the trigger view / the census routers, P2-P5; three-way measured 2026-09-19 against /tmp/fcwire-prev-c34c1c8, scratchpad r9fix/gatespec.out) --"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = ? + 1 [4.999999999999] -> 6" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? + 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = 1 + ? [214748364.75] -> 214748366" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = 1 + ?" '["214748364.75"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = ? - 1 [-2.4999999999999] -> -3" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? - 1" '["-2.4999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = ? * 1 [4.999999999999] -> 5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? * 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = ? * 2 [4.999999999999] -> 10" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? * 2" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = 2 * ? [4.999999999999] -> 10" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = 2 * ?" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = ? / 1 [4.999999999999] -> 5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? / 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = -? [4.999999999999] -> -5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = -?" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = -(-?) [4.999999999999] -> 5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = -(-?)" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = -? * 2 [4.999999999999] -> -10" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = -? * 2" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = ? + 0 [4.999999999999] -> 5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? + 0" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = MOD(?, 7) [4.999999999999] -> 5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = MOD(?, 7)" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N = ABS(?) [4.999999999999] -> 5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ABS(?)" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET SM = ? + 1 ['1.999999'] -> 3 (a SMALLINT slot)" "MERGE INTO TS USING RDB\$DATABASE ON TS.ID = 1 WHEN MATCHED THEN UPDATE SET SM = ? + 1" '["1.999999"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET SM = -? ['-4.999999'] -> 5" "MERGE INTO TS USING RDB\$DATABASE ON TS.ID = 1 WHEN MATCHED THEN UPDATE SET SM = -?" '["-4.999999"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET BI = ? * 1 ['1.9999999999999999999'] -> 2 (an INT64 slot, the int128 multiply)" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET BI = ? * 1" '["1.9999999999999999999"]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET NM = ? * 2 ['4.999999999999'] -> 10 (chunk 45's scale-0 cast)" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET NM = ? * 2" '["4.999999999999"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET NM = -? * 2 ['-2.4999999999999'] -> 4" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET NM = -? * 2" '["-2.4999999999999"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN MATCHED UPDATE SET N41 = ? * 2 ['327.675'] -> 656 (a NUMERIC(4,1) slot)" "MERGE INTO TS USING RDB\$DATABASE ON TS.ID = 1 WHEN MATCHED THEN UPDATE SET N41 = ? * 2" '["327.675"]' "SELECT ID, N41 FROM TS ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN NOT MATCHED INSERT (ID, N, NN) VALUES (9, ? + 1, 1) ['4.999999999999'] -> 9,6" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 99 WHEN NOT MATCHED THEN INSERT (ID, N, NN) VALUES (9, ? + 1, 1)" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN NOT MATCHED INSERT (ID, SM) VALUES (9, ? + 1) ['1.999999'] -> 9,3" "MERGE INTO TS USING RDB\$DATABASE ON TS.ID = 99 WHEN NOT MATCHED THEN INSERT (ID, SM) VALUES (9, ? + 1)" '["1.999999"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "floor: R9 P1 MERGE WHEN NOT MATCHED INSERT (ID, NM, NN) VALUES (9, ? * 2, 1) ['4.999999999999'] -> 9,10" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 99 WHEN NOT MATCHED THEN INSERT (ID, NM, NN) VALUES (9, ? * 2, 1)" '["4.999999999999"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE USING (SELECT ..) S WHEN MATCHED UPDATE SET N = ? + 1 ['4.999999999999'] -> 6" "MERGE INTO T USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON T.ID = S.K WHEN MATCHED THEN UPDATE SET N = ? + 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 MERGE USING (SELECT ..) S WHEN MATCHED UPDATE SET N = -? ['4.999999999999'] -> -5" "MERGE INTO T USING (SELECT 1 AS K FROM RDB\$DATABASE) S ON T.ID = S.K WHEN MATCHED THEN UPDATE SET N = -?" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P1 MERGE SET N = ? ['1.999999999999'] (a MERGE value marker) - engine raises out of range; this server and the previous binary store 2" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ?" '["1.999999999999"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,2;2,4;3,4'
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P1 MERGE SET N = COALESCE(?, 0) ['4.999999999999'] (a COALESCE value arm) - engine raises out of range; this server and the previous binary store 5" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = COALESCE(?, 0)" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,5;2,4;3,4'
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P1 MERGE SET N = COALESCE(?, 0) + 1 ['4.999999999999'] (the arm, not the add) - engine raises out of range; this server and the previous binary store 6" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = COALESCE(?, 0) + 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,6;2,4;3,4'
dml_rb "R9 P1 control MERGE SET N = ? ['2']" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ?" '["2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R9 P1 control MERGE SET N = ? + 1 ['2']" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ? + 1" '["2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_recorded "R9 P1 recorded MERGE SET BI = ? + 1 ['1.9999999999999999999'] (engine reads an add at int64; both binaries at int128)" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET BI = ? + 1" '["1.9999999999999999999"]' "SELECT ID, BI FROM T ORDER BY ID" 'dml=(none) rb=1,3;2,8;3,7'
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = ? + 1 ['4.999999999999']" "UPDATE VT SET N = ? + 1 WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = -? ['4.999999999999']" "UPDATE VT SET N = -? WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = ? * 1 ['4.999999999999']" "UPDATE VT SET N = ? * 1 WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = 2 * ? ['4.999999999999']" "UPDATE VT SET N = 2 * ? WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = -(-?) ['4.999999999999']" "UPDATE VT SET N = -(-?) WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = IIF(ID = 1, ? + 1, N) ['4.999999999999']" "UPDATE VT SET N = IIF(ID = 1, ? + 1, N) WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = (SELECT MAX(N) FROM T WHERE ID = 1) + ? ['4.999999999999']" "UPDATE VT SET N = (SELECT MAX(N) FROM T WHERE ID = 1) + ? WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R9 P1 UPDATE <trigger view> SET N = COALESCE(? + 1, 0) ['4.999999999999']" "UPDATE VT SET N = COALESCE(? + 1, 0) WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET BI = ? * 1 ['1.9999999999999999999'] -> 2" "UPDATE VT SET BI = ? * 1 WHERE ID = 1" '["1.9999999999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R9 P1 UPDATE <trigger view> SET NM = ? * 2 ['4.999999999999'] -> 10 (the scale-0 twin text)" "UPDATE VT SET NM = ? * 2 WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R9 P1 UPDATE <trigger view> SET NM = -? * 2 ['4.999999999999'] -> -10" "UPDATE VT SET NM = -? * 2 WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 INSERT INTO <trigger view> (ID, N) VALUES (9, ? + 1) ['4.999999999999'] -> 9,6" "INSERT INTO VT (ID, N) VALUES (9, ? + 1)" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = ? + 1, BI = ? (two generated casts, text order)" "UPDATE VT SET N = ? + 1, BI = ? WHERE ID = 1" '["4.999999999999", "4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb "floor: R9 P1 UPDATE <trigger view> SET N = ? + 1 WHERE ID = ? (a WHERE ? after the generated one)" "UPDATE VT SET N = ? + 1 WHERE ID = ?" '["4.999999999999", "1"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P1 UPDATE <trigger view> SET N = ? ['4.999999999999'] (a generated value cast) - engine raises out of range; this server and the previous binary store 5" "UPDATE VT SET N = ? WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID" 'dml=(none) rb=1,5,7.25,9;2,4,1,8;3,4,2.5,7'
dml_rb_both_err "R9 P1 control UPDATE <trigger view> SET N = CAST(? AS INTEGER) + 1 ['4.999999999999'] (the statement's own CAST keeps the gate)" "UPDATE VT SET N = CAST(? AS INTEGER) + 1 WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P1 UPDATE <trigger view> SET N = NULLIF(?, 0) ['4.999999999999'] - engine raises out of range; this server and the previous binary store 5" "UPDATE VT SET N = NULLIF(?, 0) WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID" 'dml=(none) rb=1,5,7.25,9;2,4,1,8;3,4,2.5,7'
dml_rb "R9 P1 control UPDATE <trigger view> SET N = ? + 1 ['2']" "UPDATE VT SET N = ? + 1 WHERE ID = 1" '["2"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_recorded "R9 P1 recorded UPDATE <trigger view> SET BI = ? + 1 ['1.9999999999999999999'] (engine reads an add at int64; both binaries at int128)" "UPDATE VT SET BI = ? + 1 WHERE ID = 1" '["1.9999999999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID" 'dml=(none) rb=1,3,7.25,3;2,4,1,8;3,4,2.5,7'
dml_rb "floor: R9 P1 census UPDATE SET N = ? + 1 ['4.999999999999'] (the DML router, round 8's repair)" "UPDATE T SET N = ? + 1 WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 census INSERT VALUES (9, ? + 1, 1) ['4.999999999999']" "INSERT INTO T (ID, N, NN) VALUES (9, ? + 1, 1)" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 census UPDATE OR INSERT .. VALUES (1, ? + 1, 5) ['4.999999999999']" "UPDATE OR INSERT INTO T (ID, N, NN) VALUES (1, ? + 1, 5) MATCHING (ID)" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R9 P1 census UPDATE .. RETURNING N, SET N = ? + 1 ['4.999999999999']" "UPDATE T SET N = ? + 1 WHERE ID = 1 RETURNING N" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P1 census LAG(N, 1, '4.999999999999') (an implicit cast of the default) - engine raises out of range; this server and the previous binary answer 5;3;4" "SELECT LAG(N, 1, '4.999999999999') OVER (ORDER BY ID) FROM T" '[]' '5;3;4'
both_err "R9 P1 census compare rung ? + 1 = N ['1.9999999999999999999'] (an OPERATOR read keeps the gate at its width)" "SELECT ID FROM T WHERE ? + 1 = N" '["1.9999999999999999999"]'
both "R9 P1 census compare rung ? + 1 = N ['4.999999999999']" "SELECT ID FROM T WHERE ? + 1 = N" '["4.999999999999"]'
both "R9 P1 census select list IIF(ID = 2, ? + 1, N) ['4.999999999999']" "SELECT IIF(ID = 2, ? + 1, N) FROM T" '["4.999999999999"]'
dml_rb_both_err "R9 P2 UPDATE T SET N = ? WHERE ID = 1 [\"2.00000000000e0\"]" "UPDATE T SET N = ? WHERE ID = 1" '["2.00000000000e0"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE T SET N = ? WHERE ID = 1 [\"2.00000000000 \"]" "UPDATE T SET N = ? WHERE ID = 1" '["2.00000000000 "]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE T SET N = ? WHERE ID = 1 [\"20000000000e-10\"]" "UPDATE T SET N = ? WHERE ID = 1" '["20000000000e-10"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE T SET N = ? WHERE ID = 1 [\"2.00000000000E+0\"]" "UPDATE T SET N = ? WHERE ID = 1" '["2.00000000000E+0"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE TS SET SM = ? WHERE ID = 1 [\"1.00000e0\"]" "UPDATE TS SET SM = ? WHERE ID = 1" '["1.00000e0"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE TS SET SM = ? WHERE ID = 1 [\"1.00000 \"]" "UPDATE TS SET SM = ? WHERE ID = 1" '["1.00000 "]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE TS SET SM = ? WHERE ID = 1 [\"32767.0e0\"]" "UPDATE TS SET SM = ? WHERE ID = 1" '["32767.0e0"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE T SET BI = ? WHERE ID = 1 [\"2.0000000000000000000e0\"]" "UPDATE T SET BI = ? WHERE ID = 1" '["2.0000000000000000000e0"]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE T SET BI = ? WHERE ID = 1 [\"2.0000000000000000000 \"]" "UPDATE T SET BI = ? WHERE ID = 1" '["2.0000000000000000000 "]' "SELECT ID, BI FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE T SET NM = ? WHERE ID = 1 [\"2.50000000000e0\"]" "UPDATE T SET NM = ? WHERE ID = 1" '["2.50000000000e0"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 INSERT INTO T (ID, N, NN) VALUES (9, ?, 1) [\"2.00000000000e0\"]" "INSERT INTO T (ID, N, NN) VALUES (9, ?, 1)" '["2.00000000000e0"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R9 P2 UPDATE T SET N = CAST(? AS VARCHAR(40)) WHERE ID = 1 [\"2.00000000000e0\"]" "UPDATE T SET N = CAST(? AS VARCHAR(40)) WHERE ID = 1" '["2.00000000000e0"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P2 MERGE .. SET N = ? [\"2.00000000000e0\"] - engine raises out of range; this server and the previous binary store 2" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = ?" '["2.00000000000e0"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=(none) rb=1,2;2,4;3,4'
# (the STORE path reads as the previous binary did - round 10: the
# trailing-zero forgiveness had answered a text past the engine's 22-byte
# SMALLINT buffer, `SET SM = ?` ['1.000000000000000000000'] wrote 1)
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P2 UPDATE T SET N = ? WHERE ID = 1 [\"2.00000000000\"] - engine stores 2; this server and the previous binary fail" "UPDATE T SET N = ? WHERE ID = 1" '["2.00000000000"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=ERR rb=1,3;2,4;3,4'
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P2 UPDATE T SET N = ? WHERE ID = 1 [\" 2.00000000000\"] - engine stores 2; this server and the previous binary fail" "UPDATE T SET N = ? WHERE ID = 1" '[" 2.00000000000"]' "SELECT ID, N FROM T ORDER BY ID" 'dml=ERR rb=1,3;2,4;3,4'
dml_rb "R9 P2 UPDATE TS SET SM = ? WHERE ID = 1 [\"1.0e0\"]" "UPDATE TS SET SM = ? WHERE ID = 1" '["1.0e0"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "R9 P2 UPDATE TS SET SM = ? WHERE ID = 1 [\"3.2767e4\"]" "UPDATE TS SET SM = ? WHERE ID = 1" '["3.2767e4"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb "R9 P2 UPDATE T SET NM = ? WHERE ID = 1 [\"2.5000000e0\"]" "UPDATE T SET NM = ? WHERE ID = 1" '["2.5000000e0"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P2 UPDATE T SET BI = ? WHERE ID = 1 [\"2.0000000000000000000\"] - engine stores 2; this server and the previous binary fail" "UPDATE T SET BI = ? WHERE ID = 1" '["2.0000000000000000000"]' "SELECT ID, BI FROM T ORDER BY ID" 'dml=ERR rb=1,9;2,8;3,7'
dml_rb_both_refuse "R9 P2 UPDATE T SET N = '2.00000000000e0' (a literal)" "UPDATE T SET N = '2.00000000000e0' WHERE ID = 1" '[]' "SELECT ID, N FROM T ORDER BY ID"
both_err "R9 P2 SELECT ID FROM T WHERE ? + 1 = N [\"3.00000000000000000000e0\"]" "SELECT ID FROM T WHERE ? + 1 = N" '["3.00000000000000000000e0"]'
both_err "R9 P2 SELECT ID FROM T WHERE N = ? - 1 [\"3.00000000000000000000e0\"]" "SELECT ID FROM T WHERE N = ? - 1" '["3.00000000000000000000e0"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P2 SELECT ID FROM T WHERE ? + 1 = N [\"3.00000000000000000000\"]" "SELECT ID FROM T WHERE ? + 1 = N" '["3.00000000000000000000"]'
both_err "R9 P2 SELECT CAST(? AS INTEGER) FROM RDB\$DATABASE [\"2.00000000000e0\"]" "SELECT CAST(? AS INTEGER) FROM RDB\$DATABASE" '["2.00000000000e0"]'
both_err "R9 P2 SELECT CAST('2.00000000000e0' AS INTEGER) FROM RDB\$DATABASE []" "SELECT CAST('2.00000000000e0' AS INTEGER) FROM RDB\$DATABASE" '[]'
recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P2 SELECT ID FROM T WHERE IIF(ID = 2, ?, N) = 2 [\"2.00000000000e0\"] - engine raises out of range; this server and the previous binary answer 2" "SELECT ID FROM T WHERE IIF(ID = 2, ?, N) = 2" '["2.00000000000e0"]' '2'
recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R9 P2 SELECT LAG(N, 1, '2.00000000000e0') OVER (ORDER BY ID) FROM T [] - engine raises out of range; this server and the previous binary answer 2;3;4" "SELECT LAG(N, 1, '2.00000000000e0') OVER (ORDER BY ID) FROM T" '[]' '2;3;4'
both "R9 P2 SELECT CAST(? AS INTEGER) FROM RDB\$DATABASE [\"2.00000000000\"]" "SELECT CAST(? AS INTEGER) FROM RDB\$DATABASE" '["2.00000000000"]'
both_err "R9 P3 ? * N = 12 [\"4611686018427387904\"]" "SELECT ID FROM T WHERE ? * N = 12" '["4611686018427387904"]'
both_err "R9 P3 ? * N = 12 [4611686018427387904]" "SELECT ID FROM T WHERE ? * N = 12" '[4611686018427387904]'
both_err "R9 P3 N * ? = 12 [\"9223372036854775807\"]" "SELECT ID FROM T WHERE N * ? = 12" '["9223372036854775807"]'
both_err "R9 P3 ID * ? = 4 [4000000000000000000]" "SELECT ID FROM T WHERE ID * ? = 4" '[4000000000000000000]'
both_err "R9 P3 ? * ID = 4 [\"-9223372036854775808\"]" "SELECT ID FROM T WHERE ? * ID = 4" '["-9223372036854775808"]'
both_err "R9 P3 ? * NM = 1 [4000000000000000000]" "SELECT ID FROM T WHERE ? * NM = 1" '[4000000000000000000]'
both_err "R9 P3 NM * ? = 1 [\"4000000000000000000\"]" "SELECT ID FROM T WHERE NM * ? = 1" '["4000000000000000000"]'
both_err "R9 P3 -? * N = -12 [\"4611686018427387904\"]" "SELECT ID FROM T WHERE -? * N = -12" '["4611686018427387904"]'
both_err "R9 P3 IIF(? * N = 12, 1, 0) = 1 [\"4611686018427387904\"]" "SELECT ID FROM T WHERE IIF(? * N = 12, 1, 0) = 1" '["4611686018427387904"]'
both "R9 P3 ? * N = 12 [4]" "SELECT ID FROM T WHERE ? * N = 12" '[4]'
both "R9 P3 ? * N = 12 [3037000500]" "SELECT ID FROM T WHERE ? * N = 12" '[3037000500]'
both "R9 P3 ? * N = 12 [\"2.5\"]" "SELECT ID FROM T WHERE ? * N = 12" '["2.5"]'
both "R9 P3 ? * BI = 18 [2]" "SELECT ID FROM T WHERE ? * BI = 18" '[2]'
both "R9 P3 ? * BI = 18 [4000000000000000000]" "SELECT ID FROM T WHERE ? * BI = 18" '[4000000000000000000]'
both "R9 P3 ? * N = 12 [null]" "SELECT ID FROM T WHERE ? * N = 12" '[null]'
both_err "R9 P3 ? * SM = 4 ['4611686018427387904'] (a SMALLINT sibling)" "SELECT ID FROM TS WHERE ? * SM = 4" '["4611686018427387904"]'
dml_rb_both_err "R9 P3 UPDATE .. WHERE ? * N = 12 ['4611686018427387904']" "UPDATE T SET S = 'z' WHERE ? * N = 12" '["4611686018427387904"]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P3 DELETE .. WHERE ID * ? = 4 ['9223372036854775807']" "DELETE FROM T WHERE ID * ? = 4" '["9223372036854775807"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R9 P3 DELETE .. WHERE ID * ? = 4 [2]" "DELETE FROM T WHERE ID * ? = 4" '[2]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1 [2.5]" "UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1" '[2.5]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1 [-2.5]" "UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1" '[-2.5]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1 [0.1]" "UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1" '[0.1]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1 [-2.5]" "UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1" '[-2.5]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 INSERT INTO T (ID, S, NN) VALUES (9, COALESCE(?, 'x'), 1) [2.5]" "INSERT INTO T (ID, S, NN) VALUES (9, COALESCE(?, 'x'), 1)" '[2.5]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET N = 99 WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 [2.5]" "UPDATE T SET N = 99 WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2" '[2.5]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R9 P4 UPDATE T SET S = COALESCE(?, S) WHERE ID = 1 [2.5]" "UPDATE T SET S = COALESCE(?, S) WHERE ID = 1" '[2.5]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "R9 P4 UPDATE T SET S = COALESCE(?, S) WHERE ID = 1 [-2.5]" "UPDATE T SET S = COALESCE(?, S) WHERE ID = 1" '[-2.5]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET S = COALESCE(?, 'xxxxxxxxxxxxxxxxxxxxxx') WHERE ID = 1 [2.5]" "UPDATE T SET S = COALESCE(?, 'xxxxxxxxxxxxxxxxxxxxxx') WHERE ID = 1" '[2.5]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "R9 P4 UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1 [\"abcdefghij  \"]" "UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1" '["abcdefghij  "]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "R9 P4 UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1 [\"abcdefghijkl\"]" "UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1" '["abcdefghijkl"]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1 [\"abcdefghij \"]" "UPDATE T SET S = COALESCE(?, 'xyz') WHERE ID = 1" '["abcdefghij "]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_both_err "R9 P4 UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1 [25]" "UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1" '[25]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb "R9 P4 UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1 [\"2\"]" "UPDATE T SET S = COALESCE(?, 'x') WHERE ID = 1" '["2"]' "SELECT ID, S FROM T ORDER BY ID"
both_err "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2.5 [2.5]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2.5" '[2.5]'
both_err "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2.5 [123.456]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2.5" '[123.456]'
both_err "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2 [1.25]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 0) = 2" '[1.25]'
both "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = '2.5000000' [2.5]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = '2.5000000'" '[2.5]'
both "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = '2.5' [2.5]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = '2.5'" '[2.5]'
both "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xxxxxxxxxxxxxxxxxxxxxx'), 'q') = '2.500000000000000' [2.5]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xxxxxxxxxxxxxxxxxxxxxx'), 'q') = '2.500000000000000'" '[2.5]'
both "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc' [\"abcdefghijkl\"]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc'" '["abcdefghijkl"]'
both "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc' [\"abcdefghij  \"]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc'" '["abcdefghij  "]'
both_err "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc' [\"abcdefghij \"]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc'" '["abcdefghij "]'
both_err "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc' [\"abcdefghijklm\"]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'xyz'), 'q') = 'abc'" '["abcdefghijklm"]'
both "R9 P4 SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN COALESCE(?, 'x') ELSE 'q' END = 'q' [\"\\u00e9\\u00e9\"]" "SELECT ID FROM T WHERE CASE WHEN ID = 2 THEN COALESCE(?, 'x') ELSE 'q' END = 'q'" '["\u00e9\u00e9"]'
both "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 'q') = 'x' [\"\\u00e9\\u00e9\"]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 'q') = 'x'" '["\u00e9\u00e9"]'
both_err "R9 P4 SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 'q') = 'x' [\"\\u00e9\\u00e9\\u00e9\"]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, 'x'), 'q') = 'x'" '["\u00e9\u00e9\u00e9"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE BI = ? * 1 [\"8.9999999999999999999\"]" "SELECT ID FROM T WHERE BI = ? * 1" '["8.9999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? * 1 = BI [\"8.9999999999999999999\"]" "SELECT ID FROM T WHERE ? * 1 = BI" '["8.9999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? / 1 = BI [\"8.9999999999999999999\"]" "SELECT ID FROM T WHERE ? / 1 = BI" '["8.9999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? * 2 = BI [\"2.49999999999999999999\"]" "SELECT ID FROM T WHERE ? * 2 = BI" '["2.49999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE BI = ? * 2 - 9 [\"8.9999999999999999999\"]" "SELECT ID FROM T WHERE BI = ? * 2 - 9" '["8.9999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? * 1 = BI [\"9223372036854775808\"]" "SELECT ID FROM T WHERE ? * 1 = BI" '["9223372036854775808"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? * 1 = BI [\"3e20\"]" "SELECT ID FROM T WHERE ? * 1 = BI" '["3e20"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? * 1.5 = 3.0 [\"300000000000000000000\"]" "SELECT ID FROM T WHERE ? * 1.5 = 3.0" '["300000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? * 1.5 = 3.0 [\"3e20\"]" "SELECT ID FROM T WHERE ? * 1.5 = 3.0" '["3e20"]'
both "R9 P5 SELECT ID FROM T WHERE ? * 1.5 = 3.0 [\"2\"]" "SELECT ID FROM T WHERE ? * 1.5 = 3.0" '["2"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? * BI = 18 [\"1.9999999999999999999\"]" "SELECT ID FROM T WHERE ? * BI = 18" '["1.9999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? / BI = 1 [\"8.9999999999999999999\"]" "SELECT ID FROM T WHERE ? / BI = 1" '["8.9999999999999999999"]'
both_err "R9 P5 SELECT ID FROM T WHERE ? + 0 = BI [\"8.9999999999999999999\"]" "SELECT ID FROM T WHERE ? + 0 = BI" '["8.9999999999999999999"]'
both "R9 P5 SELECT ID FROM T WHERE ? * 1 = BI [9]" "SELECT ID FROM T WHERE ? * 1 = BI" '[9]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM TS WHERE ? * 1 = N18 [\"3e20\"]" "SELECT ID FROM TS WHERE ? * 1 = N18" '["3e20"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM TS WHERE ? * 1 = N18 [\"2.49999999999999999999\"]" "SELECT ID FROM TS WHERE ? * 1 = N18" '["2.49999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM TS WHERE ? * 1 = N18 [\"300000000000000000000\"]" "SELECT ID FROM TS WHERE ? * 1 = N18" '["300000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM TS WHERE ? * 1 = N18 [\"25e-1\"]" "SELECT ID FROM TS WHERE ? * 1 = N18" '["25e-1"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM TS WHERE ? * ? = N18 [\"9223372036854775807\", \"1\"]" "SELECT ID FROM TS WHERE ? * ? = N18" '["9223372036854775807", "1"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM TS WHERE ? * ? = N10 [\"-9223372036854775808\", \"-1\"]" "SELECT ID FROM TS WHERE ? * ? = N10" '["-9223372036854775808", "-1"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? + 0 = NM [\"0x10\"]" "SELECT ID FROM T WHERE ? + 0 = NM" '["0x10"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM TS WHERE ? * 1 = N18 [\"0x10\"]" "SELECT ID FROM TS WHERE ? * 1 = N18" '["0x10"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? + 0 = N [\"0xFFFFFFFFFFFFFFFF\"]" "SELECT ID FROM T WHERE ? + 0 = N" '["0xFFFFFFFFFFFFFFFF"]'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 SELECT ID FROM T WHERE ? + 0 = N [\"0x8000000000000000\"]" "SELECT ID FROM T WHERE ? + 0 = N" '["0x8000000000000000"]'
recorded "R9 P5 SELECT ID FROM TS WHERE ? * 1 = N18 [\"0x10000000000000000\"]" "SELECT ID FROM TS WHERE ? * 1 = N18" '["0x10000000000000000"]' 'ERR'
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 UPDATE .. WHERE ? * 1 = BI ['8.9999999999999999999']" "UPDATE T SET S = 'z' WHERE ? * 1 = BI" '["8.9999999999999999999"]' "SELECT ID, S FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): R9 P5 DELETE .. WHERE ? / 1 = BI ['8.9999999999999999999']" "DELETE FROM T WHERE ? / 1 = BI" '["8.9999999999999999999"]' "SELECT ID, N FROM T ORDER BY ID"

echo "-- 4q. ROUND 10 PINS (back to the previous binary by construction; every helper chosen from the three-way measurement against /tmp/fcwire-prev-c34c1c8, scratchpad r10fx/pin10.out) --"
# V3: a `?` in a CONDITION of a MERGE or trigger-view value is refused at
# prepare, as the previous binary refused it (the re-planned text rounded
# it into the destination: MERGE stored 1 for ['4.6'] where the engine
# stores 7); NULLIF, which the previous binary answered, still answers
dml_rb_eng_only "R10 V3 MERGE .. SET N = IIF(? = 5, 1, 7) ['4.6'] (round 10: refuses; engine 7)" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = IIF(? = 5, 1, 7)" '["4.6"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_only "R10 V3 MERGE .. SET N = CASE WHEN ? + 1 > 5 THEN 1 ELSE 7 END ['4.2'] (round 10: refuses; engine 7)" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = CASE WHEN ? + 1 > 5 THEN 1 ELSE 7 END" '["4.2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_only "R10 V3 UPDATE <trigger view> SET N = IIF(? = 5, 1, 7) ['4.6'] (round 10: refuses; engine 7)" "UPDATE VT SET N = IIF(? = 5, 1, 7) WHERE ID = 1" '["4.6"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_eng_raises_fc_refuses "R10 V3 UPDATE <trigger view> SET BI = CASE WHEN ? + 1 > 5 THEN 1 ELSE 7 END ['1.9999999999999999999'] (round 10: refuses; the engine raises, round 9 stored 7)" "UPDATE VT SET BI = CASE WHEN ? + 1 > 5 THEN 1 ELSE 7 END WHERE ID = 1" '["1.9999999999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R10 V3 control MERGE .. SET N = NULLIF(5, ?) ['5'] (NULLIF is not a condition; the describe gap is the previous binary's)" "MERGE INTO T USING RDB\$DATABASE ON T.ID = 1 WHEN MATCHED THEN UPDATE SET N = NULLIF(5, ?)" '["5"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R10 V3 control UPDATE <trigger view> SET N = NULLIF(5, ?) ['4']" "UPDATE VT SET N = NULLIF(5, ?) WHERE ID = 1" '["4"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
# A STATEMENT MIXING a comparison `?` the previous binary refused with an
# implicit integer cast over a `?` is refused at prepare: the cast's
# previous-binary reading would be a NEW wrong answer there (measured:
# ['4.999999999999', '1'] stored 5 where the engine raises)
dml_rb_eng_raises_fc_refuses "R10 mixed UPDATE T SET N = COALESCE(?, 0) WHERE ID * ? = 1 ['4.999999999999', '1'] (round 10: refuses; the engine raises)" "UPDATE T SET N = COALESCE(?, 0) WHERE ID * ? = 1" '["4.999999999999","1"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_only "R10 mixed UPDATE T SET N = COALESCE(?, 0) WHERE ID * ? = 1 ['2', '1'] (round 10: refuses; engine 2)" "UPDATE T SET N = COALESCE(?, 0) WHERE ID * ? = 1" '["2","1"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_raises_fc_refuses "R10 mixed UPDATE T SET N = IIF(? = 5, ?, 7) ['5', '4.999999999999'] (round 10: refuses; the engine raises)" "UPDATE T SET N = IIF(? = 5, ?, 7) WHERE ID = 1" '["5","4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
eng_raises_fc_refuses "R10 mixed SELECT IIF(ID = ?, ?, N) ['2', '4.999999999999'] (round 10: refuses; the engine raises)" "SELECT IIF(ID = ?, ?, N) AS X FROM T ORDER BY ID" '["2","4.999999999999"]'
dml_rb "floor: R10 mixed control UPDATE T SET N = COALESCE(?, 0) WHERE ID = ? ['2', '1'] (the classic WHERE ? - the previous binary's statement)" "UPDATE T SET N = COALESCE(?, 0) WHERE ID = ?" '["2","1"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_only "R12 cap: K1: R10 mixed control UPDATE T SET N = ? WHERE ID * ? = 1 ['2', '1'] (a bare value is the store path, not an implicit cast)" "UPDATE T SET N = ? WHERE ID * ? = 1" '["2","1"]' "SELECT ID, N FROM T ORDER BY ID"
# V2: a compare rung forgives trailing fraction zeros only when they END
# the text; the store path reads as the previous binary did
both_err "R10 V2 ? - 0 = NM ['7.2500000000000000000 '] (a trailing blank stops the zero run)" "SELECT ID FROM T WHERE ? - 0 = NM ORDER BY ID" '["7.2500000000000000000 "]'
boundary_err "R12 boundary: conversion error by design (K2): R10 V2 ? - 0 = NM ['7.2500000000000000000'] -> 1" "SELECT ID FROM T WHERE ? - 0 = NM ORDER BY ID" '["7.2500000000000000000"]'
both_err "R10 V2 ? + 0 = N ['3.0000000000000000000 ']" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '["3.0000000000000000000 "]'
boundary_err "R12 boundary: conversion error by design (K2): R10 V2 ? + 0 = SM ['1.000000000000000000000'] -> none (a compare rung reads at int64, never the 22-byte SMALLINT buffer)" "SELECT ID FROM TS WHERE ? + 0 = SM ORDER BY ID" '["1.000000000000000000000"]'
dml_rb_both_err "R10 V2 UPDATE TS SET SM = ? ['1.000000000000000000000'] (past the 22-byte buffer: both raise; round 9 wrote 1)" "UPDATE TS SET SM = ? WHERE ID = 1" '["1.000000000000000000000"]' "SELECT ID, SM FROM TS ORDER BY ID"
dml_rb_recorded "recorded: pre-existing (round 10 - the previous binary's reading is back): R10 V2 UPDATE TS SET SM = ? ['1.00000000000000000000'] - engine stores 1; this server and the previous binary fail" "UPDATE TS SET SM = ? WHERE ID = 1" '["1.00000000000000000000"]' "SELECT ID, SM FROM TS ORDER BY ID" 'dml=ERR rb=1,2;2,-32768;3,3'
# V1: the gate is a WRITTEN cast's (the DML router's too), and a value arm
# beside a WIDER sibling reads as the engine and the previous binary do
dml_rb_both_err "R10 V1 UPDATE T SET N = CAST(? AS INTEGER) + 1 ['4.999999999999'] (the written cast reads the text; both raise)" "UPDATE T SET N = CAST(? AS INTEGER) + 1 WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "R10 V1 UPDATE T SET N = CAST(? AS INTEGER) + 1 ['2'] -> 3" "UPDATE T SET N = CAST(? AS INTEGER) + 1 WHERE ID = 1" '["2"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R10 V1 UPDATE T SET N = IIF(ID = 1, ?, BI) ['4.999999999999'] -> 5 (round 9's regression; the INT64 announcement is the previous binary's gap)" "UPDATE T SET N = IIF(ID = 1, ?, BI) WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R10 V1 UPDATE T SET N = IIF(ID = 1, ?, D) ['214748364.75'] -> 214748365" "UPDATE T SET N = IIF(ID = 1, ?, D) WHERE ID = 1" '["214748364.75"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_desc_differs "floor: R10 V1 UPDATE <trigger view> SET N = COALESCE(?, 0e0) ['4.999999999999'] -> 5" "UPDATE VT SET N = COALESCE(?, 0e0) WHERE ID = 1" '["4.999999999999"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"

echo "-- 4r. ROUND 11 PINS (a negated whole side refuses; the engine's alignment raise; the mixed-statement census; every helper chosen from the three-way measurement against /tmp/fcwire-prev-c34c1c8, scratchpad r11/pin11.out) --"
# W1: a negation chain over a `?` as a WHOLE comparison side refuses at
# prepare, as the previous binary refused every one - the engine's negate
# reads a text with its own digit-accumulating double (16 nines match the
# 4 rows, 18 do not), which no law here models
eng_only "R11 W1 -? = -N ['3.9999999999999999'] (round 11: refuses; the engine's accumulating double)" "SELECT ID FROM T WHERE -? = -N ORDER BY ID" '["3.9999999999999999"]'
eng_only "R11 W1 -? = -N ['3.999999999999999999'] (round 11: refuses)" "SELECT ID FROM T WHERE -? = -N ORDER BY ID" '["3.999999999999999999"]'
eng_only "R11 W1 N = -(-?) ['3.9999999999999999'] (round 11: refuses)" "SELECT ID FROM T WHERE N = -(-?) ORDER BY ID" '["3.9999999999999999"]'
eng_only "R11 W1 -? IN (-3, -4) ['3.5'] (round 11: refuses)" "SELECT ID FROM T WHERE -? IN (-3, -4) ORDER BY ID" '["3.5"]'
eng_only "R11 W1 -? BETWEEN -N AND -N ['4'] (round 11: refuses)" "SELECT ID FROM T WHERE -? BETWEEN -N AND -N ORDER BY ID" '["4"]'
eng_only "R11 W1 IIF(-? = -N, 1, 0) ['3.9999999999999999'] (round 11: refuses)" "SELECT IIF(-? = -N, 1, 0) FROM T ORDER BY ID" '["3.9999999999999999"]'
eng_only "R11 W1 CASE WHEN -? = -ID THEN 1 ELSE 0 END ['2'] (round 11: refuses)" "SELECT CASE WHEN -? = -ID THEN 1 ELSE 0 END FROM T ORDER BY ID" '["2"]'
eng_only "R11 W1 HAVING -? = -SUM(ID) ['6'] (round 11: refuses)" "SELECT SUM(ID) FROM T HAVING -? = -SUM(ID)" '["6"]'
dml_rb_eng_only "R11 W1 DELETE FROM T WHERE -? = -N ['3.9999999999999999'] (round 11: refuses; engine deletes rows 2 and 3, rolled back)" "DELETE FROM T WHERE -? = -N" '["3.9999999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_only "R11 W1 UPDATE T SET S = ? WHERE -? = -N ['hit', '3.9999999999999999'] (round 11: refuses)" "UPDATE T SET S = ? WHERE -? = -N" '["hit","3.9999999999999999"]' "SELECT ID, S FROM T ORDER BY ID"
# ...while a negated `?` that is an OPERAND of + - * / keeps round 4's
# operand rung (measured right on every bind by round 10's refuter)
both "floor: R11 W1 kept operand ID = -? * -1 ['2'] -> 2" "SELECT ID FROM T WHERE ID = -? * -1 ORDER BY ID" '["2"]'
both "floor: R11 W1 kept operand ID = -? * -1 ['2.4'] -> 2 (the operator's rung rounds)" "SELECT ID FROM T WHERE ID = -? * -1 ORDER BY ID" '["2.4"]'
both "floor: R11 W1 kept operand 0 - ? = -ID ['3'] -> 3" "SELECT ID FROM T WHERE 0 - ? = -ID ORDER BY ID" '["3"]'
both "floor: R11 W1 kept operand ? * -1 = -ID ['1'] -> 1" "SELECT ID FROM T WHERE ? * -1 = -ID ORDER BY ID" '["1"]'
both "floor: R11 W1 kept operand -? + 0 = -N ['4'] -> 2;3" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["4"]'
# W2: a whole-side text is classed as the engine's compare classes it
# (int64 accumulator / int128 decompose / neither) and BOTH operands align
# to the finer scale in that width - the column's value too, row by row
both_err "R11 W2 IIF(ID = ?, 1, 0) ['1.'+38 zeros] (int128 at -38: row 2 leaves int128)" "SELECT IIF(ID = ?, 1, 0) FROM T ORDER BY ID" '["1.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): R11 W2 IIF(ID = ?, 1, 0) .. WHERE ID = 1 ['1.'+38 zeros] -> 1 (row 1 fits)" "SELECT IIF(ID = ?, 1, 0) FROM T WHERE ID = 1" '["1.00000000000000000000000000000000000000"]'
both_err "R11 W2 IIF(N = ?, 1, 0) ['0.5'+18 zeros] (int64 at -19)" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["0.5000000000000000000"]'
both_err "R11 W2 WHERE IIF(NM = ?, 1, 0) = 1 ['0.5'+18 zeros]" "SELECT ID FROM T WHERE IIF(NM = ?, 1, 0) = 1 ORDER BY ID" '["0.5000000000000000000"]'
both_err "R11 W2 (?) = ID ['0.5'+18 zeros]" "SELECT ID FROM T WHERE (?) = ID ORDER BY ID" '["0.5000000000000000000"]'
both_err "R11 W2 IIF(NM = ?, 1, 0) ['1'+38 zeros+'e0'] (the text's own alignment leaves int128)" "SELECT IIF(NM = ?, 1, 0) FROM T ORDER BY ID" '["100000000000000000000000000000000000000e0"]'
boundary_err "R12 boundary: conversion error by design (K2): R11 W2 IIF(N = ?, 1, 0) ['1'+38 zeros+'e0'] -> 0;0;0 (a scale-0 slot: no alignment)" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["100000000000000000000000000000000000000e0"]'
boundary_err "R12 boundary: conversion error by design (K2): R11 W2 control IIF(ID = ?, 1, 0) ['2.'+38 zeros] -> 0;1;0 (its last zero dropped: int128 at -37)" "SELECT IIF(ID = ?, 1, 0) FROM T ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): R11 W2 control IIF(ID = ?, 1, 0) ['1.'+37 zeros] -> 1;0;0" "SELECT IIF(ID = ?, 1, 0) FROM T ORDER BY ID" '["1.0000000000000000000000000000000000000"]'
both_err "R11 W2 WHERE CASE N WHEN ? THEN 1 ELSE 0 END = 1 ['0.5'+18 zeros]" "SELECT ID FROM T WHERE CASE N WHEN ? THEN 1 ELSE 0 END = 1 ORDER BY ID" '["0.5000000000000000000"]'
both_err "R11 W2 subquery body IIF(b.N = ?, 1, 0) = 1 ['0.5'+18 zeros] (the body's literal carries the raise)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.N = ?, 1, 0) = 1) ORDER BY ID" '["0.5000000000000000000"]'
both_err "R11 W2 subquery body IIF(b.ID = ?, 1, 0) = 1 ['1.'+38 zeros] (a constant text past int64; row 2 raises)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1) ORDER BY ID" '["1.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): R11 W2 subquery body control IIF(b.ID = ?, 1, 0) = 1 ['2.'+38 zeros] -> 2" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.ID = ?, 1, 0) = 1) ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
both_err "R11 W2 subquery body b.N = ? ['0.'+38 ones] (the previous binary failed Dynamic SQL Error; the engine raises)" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.N = ?) ORDER BY ID" '["0.11111111111111111111111111111111111111"]'
boundary_err "R12 boundary: conversion error by design (K2): R11 W2 ? + 0 = ID ['2.'+38 zeros] -> 2 (an operator rung: end-running fraction zeros never count)" "SELECT ID FROM T WHERE ? + 0 = ID ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): R11 W2 ID * ? = 2 ['1.'+38 zeros] -> 2" "SELECT ID FROM T WHERE ID * ? = 2 ORDER BY ID" '["1.00000000000000000000000000000000000000"]'
dml_rb_both_err "R11 W2 UPDATE T SET N = N WHERE IIF(ID = ?, 1, 0) = 1 ['1.'+38 zeros]" "UPDATE T SET N = N WHERE IIF(ID = ?, 1, 0) = 1" '["1.00000000000000000000000000000000000000"]' "SELECT ID, N FROM T ORDER BY ID"
# the LITERAL twin: an exact expression against a text literal aligns the
# same way (the previous binary answered 0;0;0 / no row)
both_err "R11 W2 literal IIF(NM = '0.5'+18 zeros, 1, 0) (was 0;0;0 on the previous binary)" "SELECT IIF(NM = '0.5000000000000000000', 1, 0) FROM T ORDER BY ID" '[]'
both_err "R11 W2 literal WHERE N + 0 = '0.5'+18 zeros (was no row on the previous binary)" "SELECT ID FROM T WHERE N + 0 = '0.5000000000000000000' ORDER BY ID" '[]'
both "R11 W2 literal control IIF(NM = '2.50', 1, 0) -> 0;0;1" "SELECT IIF(NM = '2.50', 1, 0) FROM T ORDER BY ID" '[]'
# an IN list mixing a `?` item with a `?`-free one refuses at prepare: the
# engine reads that `?` INTO its described slot (SM = 2 for '1.5'), which no
# law here models; an all-`?` list and BETWEEN compare whole
eng_only "R11 IIF(SM IN (?, 7), 1, 0) ['1.5'] (round 11: refuses; the engine rounds into SMALLINT: 1;0;0)" "SELECT IIF(SM IN (?, 7), 1, 0) FROM TS ORDER BY ID" '["1.5"]'
both "R11 IIF(SM IN (?, ?), 1, 0) ['1.5', '7'] -> 0;0;0 (an all-? list compares whole)" "SELECT IIF(SM IN (?, ?), 1, 0) FROM TS ORDER BY ID" '["1.5","7"]'
both "R11 IIF(SM BETWEEN ? AND 7, 1, 0) ['1.5'] -> 1;0;1" "SELECT IIF(SM BETWEEN ? AND 7, 1, 0) FROM TS ORDER BY ID" '["1.5"]'
recorded "recorded: pre-existing (the previous binary's WHERE IN): SM IN (?, 7) ['1.5'] - engine 1 (rounded into SMALLINT), this server and the previous binary (none)" "SELECT ID FROM TS WHERE SM IN (?, 7) ORDER BY ID" '["1.5"]' "(none)"
# W3: THE MIXED-STATEMENT CENSUS - every comparison `?` the previous binary
# refused is marked (the parenthesised `(?) = ID` included) and every
# implicit NUMERIC / approximate cast and written NUMERIC cast over a `?`
dml_rb_eng_raises_fc_refuses "R11 W3 UPDATE T SET N = COALESCE(?, 0) WHERE (?) = ID ['4.999999999999', '1'] (round 11: refuses; the engine raises)" "UPDATE T SET N = COALESCE(?, 0) WHERE (?) = ID" '["4.999999999999","1"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_only "R11 W3 UPDATE T SET N = COALESCE(?, 0) WHERE (?) = ID ['2', '1'] (round 11: refuses; engine 2)" "UPDATE T SET N = COALESCE(?, 0) WHERE (?) = ID" '["2","1"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_eng_only "R11 W3 UPDATE <trigger view> SET N = ? WHERE (?) = ID ['2', '1'] (round 11: refuses; engine 2)" "UPDATE VT SET N = ? WHERE (?) = ID" '["2","1"]' "SELECT ID, N, NM, BI FROM T ORDER BY ID"
dml_rb_eng_raises_fc_refuses "R11 W3 UPDATE T SET NM = IIF(ID = 1, ?, 0) WHERE ID * ? = 1 ['2.00000000000 ', '1'] (round 11: refuses; the engine raises)" "UPDATE T SET NM = IIF(ID = 1, ?, 0) WHERE ID * ? = 1" '["2.00000000000 ","1"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_eng_only "R11 W3 UPDATE T SET NM = ? + 0 WHERE ID * ? = 1 ['4.999999999999', '1'] (round 11: refuses; engine 5.00, round 10 prepared then failed)" "UPDATE T SET NM = ? + 0 WHERE ID * ? = 1" '["4.999999999999","1"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb_eng_raises_fc_refuses "R11 W3 UPDATE T SET NM = CAST(? AS NUMERIC(9,2)) WHERE ID * ? = 1 ['2.00000000000 ', '1'] (round 11: refuses; a written NUMERIC cast)" "UPDATE T SET NM = CAST(? AS NUMERIC(9,2)) WHERE ID * ? = 1" '["2.00000000000 ","1"]' "SELECT ID, NM FROM T ORDER BY ID"
eng_raises_fc_refuses "R11 W3 SELECT COALESCE(?, NM) .. WHERE ID * ? = 1 ['2.00000000000 ', '1'] (round 11: refuses; the engine raises)" "SELECT COALESCE(?, NM) FROM T WHERE ID * ? = 1" '["2.00000000000 ","1"]'
eng_raises_fc_refuses "R11 W3 SELECT COALESCE(?, N) .. WHERE (?) = ID ['4.999999999999', '1'] (round 11: refuses; the engine raises)" "SELECT COALESCE(?, N) FROM T WHERE (?) = ID" '["4.999999999999","1"]'
dml_rb "floor: R11 W3 control UPDATE T SET N = COALESCE(?, 0) WHERE ? = ID ['2', '1'] (the bare ? = ID the previous binary answered)" "UPDATE T SET N = COALESCE(?, 0) WHERE ? = ID" '["2","1"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb "floor: R11 W3 control UPDATE T SET NM = IIF(ID = 1, ?, 0) WHERE ID = ? ['2', '1']" "UPDATE T SET NM = IIF(ID = 1, ?, 0) WHERE ID = ?" '["2","1"]' "SELECT ID, NM FROM T ORDER BY ID"
dml_rb "floor: R11 W3 control UPDATE T SET NM = ? + 0 WHERE ID IN (?, ?) ['4', '1', '2']" "UPDATE T SET NM = ? + 0 WHERE ID IN (?, ?)" '["4","1","2"]' "SELECT ID, NM FROM T ORDER BY ID"

echo "-- 4s. ROUND 12 PINS (the caps: K1 a chunk-new slot beside a classic one refuses; K2 a text off the canonical grammar into a chunk-new numeric slot raises the conversion error at execute - a boundary, never an answer; K3 a chunk-new operand read in DOUBLE refuses; K4 a text-slot conditional arm / a one-operand TRIM over a ? refuses; QB a qualified built-in; every helper chosen from the three-way measurement against /tmp/fcwire-prev-c34c1c8, scratchpad r12/sec4s.py) --"
both_err "R12 K2 IIF(N = ?, 1, 0) [1.0000000000..42 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["1.000000000000000000000000000000000000001 "]'
both_err "R12 K2 IIF(N = ?, 1, 0) [ 1.000000000..42 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '[" 1.000000000000000000000000000000000000001"]'
both_err "R12 K2 IIF(N = ?, 1, 0) [2.0000000000..41 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["2.00000000000000000000000000000000000000 "]'
both_err "R12 K2 IIF(N = ?, 1, 0) [200000000000..42 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["20000000000000000000000000000000000000000 "]'
both_err "R12 K2 IIF(N = ?, 1, 0) [0.9999999999..44 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["0.99999999999999999999999999999999999999999 "]'
both_err "R12 K2 IIF(N = ?, 1, 0) [100000000000..42 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["100000000000000000000000000000000000000.5 "]'
both_err "R12 K2 IIF(N = ?, 1, 0) [1.0000000000..44 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["1.000000000000000000000000000000000000001e0 "]'
both_err "R12 K2 IIF(N = ?, 1, 0) [-1.000000000..43 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["-1.000000000000000000000000000000000000001 "]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [2.0000000000..40 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [1.0000000000..41 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["1.000000000000000000000000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [ 2.000000000..41 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '[" 2.00000000000000000000000000000000000000"]'
both_err "R12 K2 IIF(N = ?, 1, 0) [0.5000000000..21 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["0.5000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [1.9999999999..21 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["1.9999999999999999999"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [ 2..2 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '[" 2"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [2 ..2 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["2 "]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [2e0..3 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["2e0"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [1E0..3 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["1E0"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 IIF(N = ?, 1, 0) [+2.0e0..6 chars]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["+2.0e0"]'
both_err "R12 K2 WHERE (?) = N [1.0000000000..42 chars]" "SELECT ID FROM T WHERE (?) = N ORDER BY ID" '["1.000000000000000000000000000000000000001 "]'
both_err "R12 K2 body IIF(b.N = ?) [1.0000000000..42 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.N = ?, 1, 0) = 1) ORDER BY ID" '["1.000000000000000000000000000000000000001 "]'
dml_rb_both_err "R12 K2 DELETE WHERE (?) = N [1.0000000000..42 chars]" "DELETE FROM T WHERE (?) = N" '["1.000000000000000000000000000000000000001 "]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R12 K2 UPDATE WHERE IIF(N = ?) [1.0000000000..42 chars]" "UPDATE T SET S = 'x' WHERE IIF(N = ?, 1, 0) = 1" '["1.000000000000000000000000000000000000001 "]' "SELECT ID, S FROM T ORDER BY ID"
both_err "R12 K2 WHERE (?) = N [ 1.000000000..42 chars]" "SELECT ID FROM T WHERE (?) = N ORDER BY ID" '[" 1.000000000000000000000000000000000000001"]'
both_err "R12 K2 body IIF(b.N = ?) [ 1.000000000..42 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.N = ?, 1, 0) = 1) ORDER BY ID" '[" 1.000000000000000000000000000000000000001"]'
dml_rb_both_err "R12 K2 DELETE WHERE (?) = N [ 1.000000000..42 chars]" "DELETE FROM T WHERE (?) = N" '[" 1.000000000000000000000000000000000000001"]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R12 K2 UPDATE WHERE IIF(N = ?) [ 1.000000000..42 chars]" "UPDATE T SET S = 'x' WHERE IIF(N = ?, 1, 0) = 1" '[" 1.000000000000000000000000000000000000001"]' "SELECT ID, S FROM T ORDER BY ID"
both_err "R12 K2 WHERE (?) = N [2.0000000000..41 chars]" "SELECT ID FROM T WHERE (?) = N ORDER BY ID" '["2.00000000000000000000000000000000000000 "]'
both_err "R12 K2 body IIF(b.N = ?) [2.0000000000..41 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.N = ?, 1, 0) = 1) ORDER BY ID" '["2.00000000000000000000000000000000000000 "]'
dml_rb_both_err "R12 K2 DELETE WHERE (?) = N [2.0000000000..41 chars]" "DELETE FROM T WHERE (?) = N" '["2.00000000000000000000000000000000000000 "]' "SELECT ID, N FROM T ORDER BY ID"
dml_rb_both_err "R12 K2 UPDATE WHERE IIF(N = ?) [2.0000000000..41 chars]" "UPDATE T SET S = 'x' WHERE IIF(N = ?, 1, 0) = 1" '["2.00000000000000000000000000000000000000 "]' "SELECT ID, S FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): K2 WHERE (?) = N [2.0000000000..40 chars]" "SELECT ID FROM T WHERE (?) = N ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 CASE N WHEN ? [2.0000000000..40 chars]" "SELECT CASE N WHEN ? THEN 1 ELSE 0 END FROM T ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 body IIF(b.N = ?) [2.0000000000..40 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.N = ?, 1, 0) = 1) ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 DELETE WHERE (?) = N [2.0000000000..40 chars]" "DELETE FROM T WHERE (?) = N" '["2.00000000000000000000000000000000000000"]' "SELECT ID, N FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): K2 UPDATE WHERE IIF(N = ?) [2.0000000000..40 chars]" "UPDATE T SET S = 'x' WHERE IIF(N = ?, 1, 0) = 1" '["2.00000000000000000000000000000000000000"]' "SELECT ID, S FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): K2 WHERE (?) = N [1.0000000000..41 chars]" "SELECT ID FROM T WHERE (?) = N ORDER BY ID" '["1.000000000000000000000000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 CASE N WHEN ? [1.0000000000..41 chars]" "SELECT CASE N WHEN ? THEN 1 ELSE 0 END FROM T ORDER BY ID" '["1.000000000000000000000000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 body IIF(b.N = ?) [1.0000000000..41 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.N = ?, 1, 0) = 1) ORDER BY ID" '["1.000000000000000000000000000000000000001"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 DELETE WHERE (?) = N [1.0000000000..41 chars]" "DELETE FROM T WHERE (?) = N" '["1.000000000000000000000000000000000000001"]' "SELECT ID, N FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): K2 UPDATE WHERE IIF(N = ?) [1.0000000000..41 chars]" "UPDATE T SET S = 'x' WHERE IIF(N = ?, 1, 0) = 1" '["1.000000000000000000000000000000000000001"]' "SELECT ID, S FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): K2 WHERE (?) = N [ 2.000000000..41 chars]" "SELECT ID FROM T WHERE (?) = N ORDER BY ID" '[" 2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 CASE N WHEN ? [ 2.000000000..41 chars]" "SELECT CASE N WHEN ? THEN 1 ELSE 0 END FROM T ORDER BY ID" '[" 2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 body IIF(b.N = ?) [ 2.000000000..41 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE IIF(b.N = ?, 1, 0) = 1) ORDER BY ID" '[" 2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 DELETE WHERE (?) = N [ 2.000000000..41 chars]" "DELETE FROM T WHERE (?) = N" '[" 2.00000000000000000000000000000000000000"]' "SELECT ID, N FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): K2 UPDATE WHERE IIF(N = ?) [ 2.000000000..41 chars]" "UPDATE T SET S = 'x' WHERE IIF(N = ?, 1, 0) = 1" '[" 2.00000000000000000000000000000000000000"]' "SELECT ID, S FROM T ORDER BY ID"
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ? + 0 = N41 [2.0000000000..40 chars]" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung -? + 0 = -N [2.0000000000..40 chars]" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ID * ? = NM [2.0000000000..40 chars]" "SELECT ID FROM T WHERE ID * ? = NM ORDER BY ID" '["2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ? + 0 = N41 [2.0000000000..41 chars]" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["2.000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung -? + 0 = -N [2.0000000000..41 chars]" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["2.000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ID * ? = NM [2.0000000000..41 chars]" "SELECT ID FROM T WHERE ID * ? = NM ORDER BY ID" '["2.000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ? + 0 = N41 [0.5000000000..43 chars]" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["0.50000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung -? + 0 = -N [0.5000000000..43 chars]" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["0.50000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ID * ? = NM [0.5000000000..43 chars]" "SELECT ID FROM T WHERE ID * ? = NM ORDER BY ID" '["0.50000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ? + 0 = N41 [1.5000000000..41 chars]" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["1.500000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung -? + 0 = -N [1.5000000000..41 chars]" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["1.500000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ID * ? = NM [1.5000000000..41 chars]" "SELECT ID FROM T WHERE ID * ? = NM ORDER BY ID" '["1.500000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ? + 0 = N41 [-2.000000000..41 chars]" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["-2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung -? + 0 = -N [-2.000000000..41 chars]" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["-2.00000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ID * ? = NM [-2.000000000..41 chars]" "SELECT ID FROM T WHERE ID * ? = NM ORDER BY ID" '["-2.00000000000000000000000000000000000000"]'
both_err "R12 K2 rung ? + 0 = N41 [1.0000000000..54 chars]" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["1.0000000000000000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung -? + 0 = -N [1.0000000000..54 chars]" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["1.0000000000000000000000000000000000000000000000000000"]'
both_err "R12 K2 rung ID * ? = NM [1.0000000000..54 chars]" "SELECT ID FROM T WHERE ID * ? = NM ORDER BY ID" '["1.0000000000000000000000000000000000000000000000000000"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ? + 0 = N41 [1e-400..6 chars]" "SELECT ID FROM TS WHERE ? + 0 = N41 ORDER BY ID" '["1e-400"]'
both_err "R12 K2 rung -? + 0 = -N [1e-400..6 chars]" "SELECT ID FROM T WHERE -? + 0 = -N ORDER BY ID" '["1e-400"]'
boundary_err "R12 boundary: conversion error by design (K2): K2 rung ID * ? = NM [1e-400..6 chars]" "SELECT ID FROM T WHERE ID * ? = NM ORDER BY ID" '["1e-400"]'
both_err "R12 body cap: classic b.N = ? [1.0000000000..42 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.N = ?) ORDER BY ID" '["1.000000000000000000000000000000000000001 "]'
both_err "R12 body cap: classic b.N = ? [200000000000..42 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.N = ?) ORDER BY ID" '["20000000000000000000000000000000000000000 "]'
both "R12 body cap: classic b.N = ? [2 ..2 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.N = ?) ORDER BY ID" '["2 "]'
both "R12 body cap: classic b.N = ? [1e0..3 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.N = ?) ORDER BY ID" '["1e0"]'
both "R12 body cap: classic b.N = ? [1.0000000000..41 chars]" "SELECT ID FROM T WHERE ID IN (SELECT b.ID FROM T b WHERE b.N = ?) ORDER BY ID" '["1.000000000000000000000000000000000000001"]'
both "R12 K2 control IIF(N = ?, 1, 0) [4]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["4"]'
both "R12 K2 control ? + 0 = N [4]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '["4"]'
both "R12 K2 control IIF(N = ?, 1, 0) [4.0]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["4.0"]'
both "R12 K2 control ? + 0 = N [4.0]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '["4.0"]'
both "R12 K2 control IIF(N = ?, 1, 0) [+3]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["+3"]'
both "R12 K2 control ? + 0 = N [+3]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '["+3"]'
both "R12 K2 control IIF(N = ?, 1, 0) [-1]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["-1"]'
both "R12 K2 control ? + 0 = N [-1]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '["-1"]'
both "R12 K2 control IIF(N = ?, 1, 0) [.5]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '[".5"]'
both "R12 K2 control ? + 0 = N [.5]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '[".5"]'
both "R12 K2 control IIF(N = ?, 1, 0) [3.]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["3."]'
both "R12 K2 control ? + 0 = N [3.]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '["3."]'
both "R12 K2 control IIF(N = ?, 1, 0) [0.999999999999999999]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '["0.999999999999999999"]'
both "R12 K2 control ? + 0 = N [0.999999999999999999]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '["0.999999999999999999"]'
both "R12 K2 control IIF(N = ?, 1, 0) [2]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '[2]'
both "R12 K2 control ? + 0 = N [2]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '[2]'
both "R12 K2 control IIF(N = ?, 1, 0) [3.0]" "SELECT IIF(N = ?, 1, 0) FROM T ORDER BY ID" '[3.0]'
both "R12 K2 control ? + 0 = N [3.0]" "SELECT ID FROM T WHERE ? + 0 = N ORDER BY ID" '[3.0]'
eng_only "R12 K1 SELECT ID FROM T WHERE ID * ? = 1 AND N = ? ORDER BY ID" "SELECT ID FROM T WHERE ID * ? = 1 AND N = ? ORDER BY ID" '["1", "3"]'
eng_only "R12 K1 SELECT ID FROM TS WHERE ID * ? = 1 AND SM IN (?, 7) ORDER BY ID" "SELECT ID FROM TS WHERE ID * ? = 1 AND SM IN (?, 7) ORDER BY ID" '["1", "0.5000000000000000000"]'
eng_raises_fc_refuses "R12 K1 SELECT IIF(ID = ?, 1, 0), COALESCE(?, S) FROM T ORDER BY ID" "SELECT IIF(ID = ?, 1, 0), COALESCE(?, S) FROM T ORDER BY ID" '[2, "xxxxxxxxxxx"]'
eng_only "R12 K1 SELECT IIF(ID = ?, S, ?) AS X FROM T ORDER BY ID" "SELECT IIF(ID = ?, S, ?) AS X FROM T ORDER BY ID" '[2, "xx"]'
eng_raises_fc_refuses "R12 K1 SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = ? ORDER BY ID" "SELECT ID FROM T WHERE IIF(ID = 2, ?, 0) = ? ORDER BY ID" '["0.9999999999999999", "2.4"]'
eng_only "R12 K1 SELECT ID FROM T WHERE COALESCE(?, 0) = ? ORDER BY ID" "SELECT ID FROM T WHERE COALESCE(?, 0) = ? ORDER BY ID" '["2", "2"]'
eng_only "R12 K1 SELECT ID FROM T WHERE CAST(? AS INTEGER) = ? ORDER BY ID" "SELECT ID FROM T WHERE CAST(? AS INTEGER) = ? ORDER BY ID" '["2", "2"]'
eng_only "R12 K1 SELECT N FROM T GROUP BY N HAVING SUM(ID) > ? + 1 AND COUNT(*) > ?" "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ? + 1 AND COUNT(*) > ?" '[0, "1"]'
eng_only "R12 K1 SELECT IIF(ID = ?, 7, 0) AS X FROM T WHERE N = ? ORDER BY ID" "SELECT IIF(ID = ?, 7, 0) AS X FROM T WHERE N = ? ORDER BY ID" '[2, 4]'
dml_rb_eng_only "R12 K1 UPDATE .. WHERE ID * ? = 1 AND N = ?" "UPDATE T SET S = 'x' WHERE ID * ? = 1 AND N = ?" '["1", "3"]' "SELECT ID, S FROM T ORDER BY ID"
dml_rb_eng_raises_fc_refuses "R12 K1 UPDATE T SET N = COALESCE(?, 0) WHERE (?) = ID" "UPDATE T SET N = COALESCE(?, 0) WHERE (?) = ID" '["4.999999999999", "1"]' "SELECT ID, N FROM T ORDER BY ID"
both "R12 K1 control SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1 AND ID * ? = 1 ORDER BY I" "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = 1 AND ID * ? = 1 ORDER BY ID" '["1", "1"]'
both "R12 K1 control SELECT IIF(ID = ? OR N = ?, 1, 0) AS X FROM T ORDER BY ID" "SELECT IIF(ID = ? OR N = ?, 1, 0) AS X FROM T ORDER BY ID" '[1, 4]'
both "R12 K1 control SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = ? ORDER BY ID" "SELECT ID FROM T WHERE IIF(ID = ?, 1, 0) = ? ORDER BY ID" '[2, 1]'
both "R12 K1 control SELECT ID FROM T WHERE ? = ID AND N = ? ORDER BY ID" "SELECT ID FROM T WHERE ? = ID AND N = ? ORDER BY ID" '["1", "3"]'
eng_only "R12 K3 SELECT 1 FROM RDB\$DATABASE WHERE ? * 1e0 = 1" "SELECT 1 FROM RDB\$DATABASE WHERE ? * 1e0 = 1" '["0.9999999999999999"]'
eng_only "R12 K3 SELECT 1 FROM RDB\$DATABASE WHERE ? + 0 = 1e0" "SELECT 1 FROM RDB\$DATABASE WHERE ? + 0 = 1e0" '["0.99999999999999999"]'
eng_only "R12 K3 SELECT ID FROM T WHERE ? * D = 1.5 ORDER BY ID" "SELECT ID FROM T WHERE ? * D = 1.5 ORDER BY ID" '["1.5"]'
eng_only "R12 K3 SELECT ID FROM T WHERE ? + D = 2.5 ORDER BY ID" "SELECT ID FROM T WHERE ? + D = 2.5 ORDER BY ID" '["1"]'
eng_only "R12 K3 SELECT ID FROM TS WHERE ? * 1 = FL + 0.9 ORDER BY ID" "SELECT ID FROM TS WHERE ? * 1 = FL + 0.9 ORDER BY ID" '["1"]'
eng_only "R12 K3 SELECT IIF(CAST(? AS DOUBLE PRECISION) = 1, 1, 0) FROM RDB\$DATABASE" "SELECT IIF(CAST(? AS DOUBLE PRECISION) = 1, 1, 0) FROM RDB\$DATABASE" '["1"]'
eng_only "R12 K3 SELECT IIF(CAST(? AS FLOAT) = 1, 1, 0) FROM RDB\$DATABASE" "SELECT IIF(CAST(? AS FLOAT) = 1, 1, 0) FROM RDB\$DATABASE" '["1"]'
eng_only "R12 K3 SELECT IIF(COALESCE(?, D) = 1.5, 1, 0) FROM T ORDER BY ID" "SELECT IIF(COALESCE(?, D) = 1.5, 1, 0) FROM T ORDER BY ID" '["1.5"]'
eng_only "R12 K3 SELECT ID FROM T WHERE ? * PI() > 3 ORDER BY ID" "SELECT ID FROM T WHERE ? * PI() > 3 ORDER BY ID" '["1"]'
eng_only "R12 K3 SELECT ID FROM T WHERE ID * ? = 1E0 ORDER BY ID" "SELECT ID FROM T WHERE ID * ? = 1E0 ORDER BY ID" '["1"]'
dml_rb_eng_only "R12 K3 DELETE FROM T WHERE ? + 0e0 = ID" "DELETE FROM T WHERE ? + 0e0 = ID" '["0.99999999999999999"]' "SELECT ID, N FROM T ORDER BY ID"
both "R12 K3 control (whole side) SELECT IIF(D = ?, 1, 0) FROM T ORDER BY ID" "SELECT IIF(D = ?, 1, 0) FROM T ORDER BY ID" '["1.5"]'
both "R12 K3 control (whole side) SELECT ID FROM T WHERE (?) = D ORDER BY ID" "SELECT ID FROM T WHERE (?) = D ORDER BY ID" '["2.5"]'
both "R12 K3 control (whole side) SELECT IIF(? = 1e0, 1, 0) FROM RDB\$DATABASE" "SELECT IIF(? = 1e0, 1, 0) FROM RDB\$DATABASE" '["0.9999999999999999"]'
desc_differs "R12 (recorded describe gap: the CASE-operand nullability the gate records elsewhere) K3 control (whole side) SELECT CASE D WHEN ? THEN 1 ELSE 0 END FROM T ORDER BY ID" "SELECT CASE D WHEN ? THEN 1 ELSE 0 END FROM T ORDER BY ID" '["1.5"]'
eng_only "R12 K4 SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 'a') = 'b' ORDER BY ID" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(?), 'a') = 'b' ORDER BY ID" '["b "]'
eng_only "R12 K4 SELECT ID FROM T WHERE COALESCE(TRIM(?), 'a') = 'b' ORDER BY ID" "SELECT ID FROM T WHERE COALESCE(TRIM(?), 'a') = 'b' ORDER BY ID" '["bbbb"]'
eng_only "R12 K4 SELECT IIF(ID = 2, TRIM(?), 'a') AS X FROM T ORDER BY ID" "SELECT IIF(ID = 2, TRIM(?), 'a') AS X FROM T ORDER BY ID" '["b"]'
eng_only "R12 K4 SELECT ID FROM T WHERE NULLIF(TRIM(LEADING FROM ?), 'a') = 'b' ORDER B" "SELECT ID FROM T WHERE NULLIF(TRIM(LEADING FROM ?), 'a') = 'b' ORDER BY ID" '["b"]'
eng_only "R12 K4 SELECT IIF(COALESCE(?, S) = 'cd', 1, 0) FROM T ORDER BY ID" "SELECT IIF(COALESCE(?, S) = 'cd', 1, 0) FROM T ORDER BY ID" '["cd"]'
# RE-MEASURED 2026-09-20 and RE-RECORDED: this was an `eng_only` cell
# saying the engine ANSWERS it.  It does not - the engine PREPARES it and
# then RAISES at execute, gdscode 335544321 *Arithmetic exception, numeric
# overflow, or string truncation / string right truncation* (the CASE
# reconciles UPPER(?) with the one-character 'q' arm).  This server
# refuses at PREPARE, gdscode 335544569, and so does the previous
# committed binary /tmp/fcwire-prev-0e5a8f4 - byte for byte, so the
# re-recording is not this session's change.  Reproduced standalone on an
# idle box against the live engine before touching the cell.
eng_raises_fc_refuses "R12 K4 SELECT CASE WHEN IIF(ID = 2, UPPER(?), 'q') = 'CD' THEN 1 ELSE 0 END F - the engine prepares and raises 22003, this server refuses at prepare" "SELECT CASE WHEN IIF(ID = 2, UPPER(?), 'q') = 'CD' THEN 1 ELSE 0 END FROM T ORDER BY ID" '["cd"]'
dml_rb_eng_only "R12 K4 UPDATE T SET S = COALESCE(TRIM(?), 'q')" "UPDATE T SET S = COALESCE(TRIM(?), 'q') WHERE ID = 1" '["b"]' "SELECT ID, S FROM T ORDER BY ID"
desc_differs "R12 (recorded describe gap, shared with prev) K4 control SELECT ID FROM T WHERE IIF(ID = 2, TRIM(' ' FROM ?), 'a') = 'b' ORDER  [b ..2]" "SELECT ID FROM T WHERE IIF(ID = 2, TRIM(' ' FROM ?), 'a') = 'b' ORDER BY ID" '["b "]'
dml_rb "R12 K4 control UPDATE T SET S = TRIM(?) WHERE ID = 1 [ ab ..4]" "UPDATE T SET S = TRIM(?) WHERE ID = 1" '[" ab "]' "SELECT ID, S FROM T ORDER BY ID"
desc_differs "R12 (recorded describe gap, shared with prev) K4 control SELECT ID FROM T WHERE IIF(ID = 2, UPPER(?), 'a') = 'B' ORDER BY ID [b..1]" "SELECT ID FROM T WHERE IIF(ID = 2, UPPER(?), 'a') = 'B' ORDER BY ID" '["b"]'
both "R12 K4 control SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = 'cd' ORDER B [xxxxxx..40]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = 'cd' ORDER BY ID" '["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]'
both "R12 K4 control SELECT IIF(ID = 2, COALESCE(?, S), 'q') AS X FROM T ORDER BY ID [xxxxxx..39]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = 'xxxxxxxxxx' ORDER BY ID" '["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\u00e9"]'
both "R12 K4 control SELECT IIF(ID = 2, COALESCE(?, S), 'q') AS X FROM T ORDER BY ID [cd    ..40]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = 'xxxxxxxxxx' ORDER BY ID" '["cd                                      "]'
both_err "R12 text fit: 40 bytes whose first 10 characters overflow the slot [éééé..]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = 'xxxxxxxxxx' ORDER BY ID" '["\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9"]'
both_err "R12 text fit: 40 bytes whose first 10 characters overflow the slot [éxxx..]" "SELECT ID FROM T WHERE IIF(ID = 2, COALESCE(?, S), 'q') = 'xxxxxxxxxx' ORDER BY ID" '["\u00e9xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]'
both_refuse "R12 QB b.IIF(ID = ?, 1, 0) (the engine: Function unknown)" "SELECT ID FROM T b WHERE b.IIF(ID = ?, 1, 0) = 1 ORDER BY ID" '["1"]'
both "R12 QB control: b.ID = ?" "SELECT ID FROM T b WHERE b.ID = ? ORDER BY ID" '["1"]'

echo "-- 5. NULLABILITY and SUBTYPE of a comparison-typed ? (L2) --"
both "COUNT(*) > ? - NOT NULL"                       "SELECT COUNT(*) FROM T HAVING COUNT(*) > ?" '[2]'
both "COUNT(ID) > ? - NOT NULL"                      "SELECT N FROM T GROUP BY N HAVING COUNT(ID) > ?" '[1]'
both "MAX(NN) > ? - Nullable over a NOT NULL column" "SELECT COUNT(*) FROM T HAVING MAX(NN) > ?" '[6]'
both "MIN(NN) > ? - Nullable"                        "SELECT N FROM T GROUP BY N HAVING MIN(NN) > ?" '[5]'
both "SUM(NN) > ? - Nullable"                        "SELECT N FROM T GROUP BY N HAVING SUM(NN) > ?" '[5]'
both "NM * 2 > ? - subtype 1 from the NUMERIC arithmetic" "SELECT ID FROM T WHERE NM * 2 > ?" '["14.4"]'
both "NM + 0.5 > ? - subtype 1"                      "SELECT ID FROM T WHERE NM + 0.5 > ?" '["7.5"]'
both "SUM(NM) + 1 > ? - subtype 1"                   "SELECT N FROM T GROUP BY N HAVING SUM(NM) + 1 > ?" '["8.2"]'
both "WHERE NN > ? + 1 - NOT NULL"                   "SELECT ID FROM T WHERE NN > ? + 1" '[5]'
both "WHERE NN > ? - NOT NULL"                       "SELECT ID FROM T WHERE NN > ?" '[5]'
both "HAVING N > ? - Nullable from the key"          "SELECT N FROM T GROUP BY N HAVING N > ?" '[3]'
both "WHERE NM > ? - LONG scale -2 subtype 1"        "SELECT ID FROM T WHERE NM > ?" '["7.2"]'

echo "-- 6. CONTROLS: shapes the engine itself refuses --"
both_refuse "ABS(ID * ?) = 2 - typing does not pass a function"     "SELECT ID FROM T WHERE ABS(ID * ?) = 2" '[1]'
both_refuse "COALESCE(ID * ?, 0) = 2 - nor a COALESCE"              "SELECT ID FROM T WHERE COALESCE(ID * ?, 0) = 2" '[1]'
both_refuse "SELECT ID * ? - uncompared"                            "SELECT ID * ? FROM T" '[1]'
both_refuse "SUM(ID * ?) - uncompared under an aggregate"           "SELECT SUM(ID * ?) FROM T" '[1]'
both_refuse "DT + ? = DATE '2024-01-12' - date arithmetic"          "SELECT ID FROM T WHERE DT + ? = DATE '2024-01-12'" '[2]'
both_refuse "DT - ? = DATE '2024-01-08' - the engine prepares it, then fails at execute" \
     "SELECT ID FROM T WHERE DT - ? = DATE '2024-01-08'" '[2]'
both_refuse "? * 2 = ? * 3 - both sides"                            "SELECT ID FROM T WHERE ? * 2 = ? * 3" '[3,2]'
both_refuse "ID * ? = ? - both sides"                               "SELECT ID FROM T WHERE ID * ? = ?" '[1,2]'
both_refuse "? = ID * ? - both sides"                               "SELECT ID FROM T WHERE ? = ID * ?" '[2,1]'
both_refuse "N + ? = ID * ? - both sides"                           "SELECT ID FROM T WHERE N + ? = ID * ?" '[0,2]'
both_refuse "ID / ? = BI / ? - both sides"                          "SELECT ID FROM T WHERE ID / ? = BI / ?" '[1,9]'
both_refuse "-? = -? - both sides"                                  "SELECT ID FROM T WHERE -? = -?" '[1,1]'
both_refuse "? = ? - bare both sides (-804)"                        "SELECT ID FROM T WHERE ? = ?" '[1,1]'
both_refuse "IIF(ID = ?, ?, ?) - all-parameter branches (-804)"     "SELECT IIF(ID = ?, ?, ?) AS X FROM T" '[2,7,8]'
both_refuse "CASE WHEN ID = ? THEN ? ELSE ? END (-804)"             "SELECT CASE WHEN ID = ? THEN ? ELSE ? END AS X FROM T" '[2,7,8]'
both_refuse "ID * ? = S ['ab'] - a VARYING slot: conversion error at execute on the engine" \
     "SELECT ID FROM T WHERE ID * ? = S" '["ab"]'
both_refuse "SUM(ID) * ? > ? - both sides in HAVING"                "SELECT N FROM T GROUP BY N HAVING SUM(ID) * ? > ?" '[1,2]'

echo "-- 7. CONTROLS: what already worked --"
both "WHERE ID = ? - a bare ?"                       "SELECT ID FROM T WHERE ID = ?" '[2]'
both "WHERE ? = ID"                                  "SELECT ID FROM T WHERE ? = ID" '[2]'
both "WHERE S = ?"                                   "SELECT ID FROM T WHERE S = ?" '["cd"]'
both "WHERE ID = ? OR N = ?"                         "SELECT ID FROM T WHERE ID = ? OR N = ?" '[1,3]'
both "CAST(? AS INTEGER) * 2 = ID"                   "SELECT ID FROM T WHERE CAST(? AS INTEGER) * 2 = ID" '[1]'
both "? = ID * 2 - the parser's ?-first leaf"        "SELECT ID FROM T WHERE ? = ID * 2" '[4]'
both "ID * 2 = ?"                                    "SELECT ID FROM T WHERE ID * 2 = ?" '[4]'
both "CAST(? AS NUMERIC(18,1)) * ID = 2.5"           "SELECT ID FROM T WHERE CAST(? AS NUMERIC(18,1)) * ID = 2.5" '["2.5"]'
both "ID * CAST(? AS NUMERIC(9,1)) = 2.5"            "SELECT ID FROM T WHERE ID * CAST(? AS NUMERIC(9,1)) = 2.5" '["2.5"]'
both "? = 2.5 - a bare ? against a decimal"          "SELECT ID FROM T WHERE ? = 2.5" '["2.5"]'
both "ID BETWEEN ? AND 2"                            "SELECT ID FROM T WHERE ID BETWEEN ? AND 2" '[2]'
both "ID IN (?, 3)"                                  "SELECT ID FROM T WHERE ID IN (?, 3)" '[1]'
both "HAVING SUM(ID) > ?"                            "SELECT N FROM T GROUP BY N HAVING SUM(ID) > ?" '[3]'
both "HAVING SUM(ID) + 1 > ?"                        "SELECT N FROM T GROUP BY N HAVING SUM(ID) + 1 > ?" '[5]'
both "HAVING SUM(ID) > CAST(? AS INTEGER) + 1"       "SELECT N FROM T GROUP BY N HAVING SUM(ID) > CAST(? AS INTEGER) + 1" '[2]'
both "WHERE ID * 2 = 4 - no parameter"               "SELECT ID FROM T WHERE ID * 2 = 4"
both "IIF(ID = 2, 1, 0) - no parameter"              "SELECT IIF(ID = 2, 1, 0) AS X FROM T"
both "HAVING SUM(ID) > 3 - no parameter"             "SELECT N FROM T GROUP BY N HAVING SUM(ID) > 3"
# PRE-EXISTING, recorded before this chunk (evidence row 79): the IIF's
# NOT NULL announcement beside a NOT NULL sibling
desc_differs "IIF(ID IS NULL, ?, 0) - the sibling-typed branch's NOT NULL" "SELECT IIF(ID IS NULL, ?, 0) AS X FROM T" '[9]'

echo "-- 8. RECORDED: the engine answers, this server refuses --"
# a `?` on BOTH sides is an order-dependent engine rule (ID * ? = N + ?
# answers, N + ? = ID * ? refuses): refused whole rather than guessed
eng_only "ID * ? = N + ? - both sides (INT64 / INT128 slots)"  "SELECT ID FROM T WHERE ID * ? = N + ?" '[2,0]'
eng_only "ID * ? = 2 + ? - both sides"                         "SELECT ID FROM T WHERE ID * ? = 2 + ?" '[2,0]'
eng_only "? + 1 = ? + 2 - both sides, no column"               "SELECT ID FROM T WHERE ? + 1 = ? + 2" '[1,0]'
eng_only "? + 1 = ID + ? - both sides"                         "SELECT ID FROM T WHERE ? + 1 = ID + ?" '[1,0]'
# IS NULL / = NULL on a ?-arithmetic describes an SQL_NULL slot (32766)
eng_only "ID * ? IS NULL - an SQL_NULL slot"                   "SELECT ID FROM T WHERE ID * ? IS NULL" '[null]'
eng_only "ID * ? IS NOT NULL"                                  "SELECT ID FROM T WHERE ID * ? IS NOT NULL" '[1]'
eng_only "ID * ? = NULL"                                       "SELECT ID FROM T WHERE ID * ? = NULL" '[1]'
eng_only "IIF(? IS NULL, 1, 0) - an SQL_NULL slot in a condition" "SELECT IIF(? IS NULL, 1, 0) AS X FROM T" '[1]'
eng_only "IIF(NULL = ?, 1, 0)"                                 "SELECT IIF(NULL = ?, 1, 0) AS X FROM T" '[1]'
# PRE-EXISTING (L7): pure arithmetic over a group key in HAVING refuses
# with NO parameter, so its ? twins refuse for that reason - while
# `HAVING N + ? > 4` above answers because its ? enters the fold block
eng_only "HAVING N + 1 > 4 - no parameter, the pre-existing refusal" "SELECT N FROM T GROUP BY N HAVING N + 1 > 4"
eng_only "HAVING N + 1 > ? - refuses for the same reason"      "SELECT N FROM T GROUP BY N HAVING N + 1 > ?" '[4]'
eng_only "HAVING N * 2 > ?"                                    "SELECT N FROM T GROUP BY N HAVING N * 2 > ?" '[7]'
# date arithmetic under an aggregate: the engine types the ? DATE
eng_only "HAVING MAX(DT) > ? + 1 - a DATE slot"                "SELECT N FROM T GROUP BY N HAVING MAX(DT) > ? + 1" '["2024-02-10"]'
# other-side descriptors this server does not synthesise for arithmetic
# RE-MEASURED 2026-09-20 and RE-RECORDED: recorded as `eng_only`, but the
# ENGINE REFUSES this one too - *Dynamic SQL Error, Expression evaluation
# not supported, Invalid data type for multiplication*, gdscode 335544569,
# the SAME gdscode this server gives.  Identical on the previous committed
# binary, and reproduced standalone against the live engine.
both_refuse "ID * ? = '2' - a TEXT len 1 slot: the ENGINE refuses it too (invalid data type for multiplication)" "SELECT ID FROM T WHERE ID * ? = '2'" '["2"]'
eng_only "ID * ? = CAST(2.5 AS DECFLOAT) - a DECFLOAT slot"    "SELECT ID FROM T WHERE ID * ? = CAST(2.5 AS DECFLOAT)" '["1.25"]'
eng_only "ID * ? = 2 * 1.5 - an INT128 scale -1 slot"          "SELECT ID FROM T WHERE ID * ? = 2 * 1.5" '["1.5"]'
eng_only "ID * ? > ALL (SELECT 1 FROM RDB\$DATABASE) - a quantified side" "SELECT ID FROM T WHERE ID * ? > ALL (SELECT 1 FROM RDB\$DATABASE)" '[1]'
# IN / BETWEEN with a DECIMAL list or bound (the reconciled INT64 scale)
eng_only "ID * ? IN (2, 3.5) - the reconciled list type"       "SELECT ID FROM T WHERE ID * ? IN (2, 3.5)" '[1]'
eng_only "ID * ? BETWEEN 1.5 AND 2 - a decimal lower bound"    "SELECT ID FROM T WHERE ID * ? BETWEEN 1.5 AND 2" '[1]'
# a bare ? as the TESTED side, or under a pattern, inside a condition
eng_only "IIF(? BETWEEN 1 AND 2, 1, 0)"                        "SELECT IIF(? BETWEEN 1 AND 2, 1, 0) AS X FROM T" '[2]'
eng_only "IIF(? IN (1, 2), 1, 0)"                              "SELECT IIF(? IN (1, 2), 1, 0) AS X FROM T" '[2]'
eng_only "IIF(S LIKE ?, 1, 0)"                                 "SELECT IIF(S LIKE ?, 1, 0) AS X FROM T" '["c%"]'
eng_only "IIF(? LIKE 'a%', 1, 0)"                              "SELECT IIF(? LIKE 'a%', 1, 0) AS X FROM T" '["ab"]'
eng_only "IIF(S STARTING WITH ?, 1, 0)"                        "SELECT IIF(S STARTING WITH ?, 1, 0) AS X FROM T" '["e"]'

panic_free "R6 the whole gate ran without a server panic; the process is alive at the end"
kill $srv 2>/dev/null; wait $srv 2>/dev/null; trap - EXIT
rm -f "$ENG" "$FC"
echo "ran $ran checks"
# THE FLOOR IS COUNTED FROM A MEASURED RUN, never typed. It catches what
# a pass/fail tally cannot: cells SILENTLY DISAPPEARING - an early
# `exit`, a helper renamed, a `node` that stopped resolving. (Round 10:
# 1685 + the 23 section-4q pins = 1708, measured - run3 on the 15:59:20
# binary ran 1708 checks, 1708 OK. Round 11: 1708 + the 50 section-4r
# pins = 1758, measured - run3 on the 19:23:16 binary ran 1758 checks,
# 1758 OK. Round 12: 1758 + the 136 section-4s pins = 1894, measured -
# run3 on the 21:22:25 binary ran 1894 checks, 1894 OK, exit 0.)
if [ "$ran" -lt 1894 ]; then
    echo "FAIL only $ran checks ran; 1894 were measured - cells went missing"; fail=1
fi
exit $fail
