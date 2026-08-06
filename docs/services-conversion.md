# Converting the Services manager: `src/jrd/svc.cpp` → `fire-crab-svc`

The paper's companion chapter is [services-api.md](../../../services-api.md);
this file is the conversion record.

## A second protocol inside the first

A Services client attaches to the name `service_mgr` instead of a database.
After that there are no statements, no BLR and no rows — every request and every
answer is a byte buffer of tagged items. `gbak`, `gfix`, `gstat`, `nbackup`,
`fbsvcmgr` and every driver's "service" class are all this one interface, which
is why converting the buffers converts the tools: the engine's own `fbsvcmgr`
drives fire-crab's service manager in `qa/svc-info.sh` with nothing of
fire-crab's in the reading path.

## One buffer shape, four grammars

The trap of this subsystem is that the same-looking bytes mean different things
depending on which buffer they are in. `ClumpletReader` carries a `kind` for
exactly this reason (`src/common/classes/ClumpletReader.cpp:262-310`), and
reading a buffer under the wrong one turns a length into a tag:

| buffer | `ClumpletReader` kind | shape |
|---|---|---|
| attach SPB | `SpbAttach` | TAGGED, then `[tag][u8 len][data]` |
| query "send" items | `SpbSendItems` | `[tag][u16 LE len][data]`, control tags bare |
| query "receive" items | `SpbReceiveItems` | bare `[tag]`, nothing else |
| start SPB | `SpbStart` | a state machine keyed by the action byte |

*Tagged* means the buffer opens with `isc_spb_version` (2) followed by a version
byte — or with `isc_spb_version1` (1), which IS the tag and has no version byte
after it (`getBufferTag`, line 240).

Here is the real thing. `fbsvcmgr` attaching to fire-crab, captured with
`FC_SRV_TRACE=1` and re-parsed by `fcsvc parse attach` in the gate on every run
rather than frozen into the test:

```
0202                              isc_spb_version, version 2
7600                              isc_spb_utf8_filename, ZERO bytes (a flag)
1c06 "SYSDBA"                     isc_spb_user_name
3a04 00000000                     isc_spb_dummy_packet_interval = 0
6e04 f5b90f00                     isc_spb_process_id
701a "/opt/firebird/bin/fbsvcmgr" isc_spb_process_name
7723 "LI-T6.0.0.2076 ..."         isc_spb_client_version
```

Two things to notice. There is **no password clumplet** — the credentials went
through SRP, and the SPB carries only the login; a server that demands
`isc_spb_password` here refuses every modern client. And the identification tags
are the SPB's own codes (`process_id` = 110, `process_name` = 112,
`client_version` = 119), *not* the DPB codes with the same names (71, 74, 80).

The query buffers from the same capture:

```
send = 4004000100000001   isc_info_svc_timeout, u16 length 4, value 1, isc_info_end
recv = 3732               isc_info_svc_server_version, isc_info_svc_svr_db_info
```

The send buffer's `04 00` is a *two-byte* length; read as one byte, the next
item's first data byte becomes a tag and the buffer dissolves into nonsense. The
receive buffer has no lengths and no terminator at all.

## Two answer shapes, chosen per item

Neither of which is the request's shape:

* **string items** — `INF_put_item` (`src/jrd/inf.cpp`):
  `[tag][u16 LE len][bytes]`
* **numeric items** — `ADD_SPB_NUMERIC` (`ibase.h:1093`): `[tag][4 bytes LE]`,
  with **no length prefix at all**

Nothing in the bytes says which. A decoder must know from the item code, so
`item_is_numeric` is that knowledge — read off which macro `svc.cpp` uses at
each site: `isc_info_svc_version`, `capabilities`, `running`, `stdin`,
`get_licensed_users`, and inside the `svr_db_info` cluster `isc_spb_num_att` and
`isc_spb_num_db`. Everything else is a string.

`isc_info_svc_svr_db_info` is a **cluster**, and its opening tag is bare
(`*info++ = item`, svc.cpp:1163):

```
[50][isc_spb_num_att][n][isc_spb_num_db][m][isc_spb_dbname][len][path]...[127]
```

closed by `isc_info_flag_end` (127). A decoder that treats every non-numeric
item as a string reads `num_att`'s tag as a length word here.

## Truncation is part of the contract, and the boundary is off by one

`INF_put_item` reserves room before writing:

```c
if ((ptr + length + (inserting ? 3 : 4) >= end) || (length > MAX_USHORT))
{
    if (ptr < end) *ptr++ = isc_info_truncated;
    if (ptr < end && !inserting) *ptr++ = isc_info_end;
    return NULL;
}
```

Four bytes of overhead — tag, two length bytes, and one held back for
`isc_info_end` — and the comparison is `>=`, so **the last byte of the client's
buffer is never used**: an answer of n bytes needs n + 5, not n + 4. The
numeric path's `ck_space_for_numeric` uses a strict `>` on `1 + sizeof(ULONG)`,
so the two rules differ by a byte. Both are converted as written rather than
unified, which cost this slice one bug: the first version used `>` for strings
and fit an answer the engine would have truncated.

The gate measures this on the live engine instead of asserting a constant. The
real server's version banner is 35 bytes; asked with a 39-byte buffer it answers
`02 01` — `isc_info_truncated`, `isc_info_end` — and asked with 40 it answers
the whole string. fire-crab's encoder then has to break at the same place for
its own (37-byte) banner: truncated at 41, whole at 42.

A partial answer that *looks* whole is the failure this rule prevents: a client
reading a string cut short has no way to know, which is why the engine spends a
byte on saying so.

## "Not implemented" is itself a converted behaviour

`query2`'s `default:` arm is `status << Arg::Gds(isc_wish_list)` — an error in
the status vector. Not a marker in the buffer, and *not* silence. So:

* an info item fire-crab does not serve refuses the whole query with
  `isc_wish_list` (335544378), and the gate checks that the REAL server refuses
  the same item with the same code;
* a service **action** fire-crab cannot perform — backup, restore, sweep,
  add-user — is refused outright. That replaced an acknowledgement: the server
  once answered `op_service_start` with a clean `op_response`, and a clean
  response to a backup request means "done", so the client polled an empty
  output stream and reported a backup that never happened. `fbsvcmgr` now
  prints *"feature is not supported"* for those, and the actions fire-crab DOES
  perform (`db_stats` for the header report, below) stream real output.

Skipping an unknown item would be worse than either error: the client would
read the *next* item's bytes as this item's answer.

## What the gate proves (`qa/svc-info.sh`, 19 checks)

1. **Our decoder against the engine's client, same real server.** `fcsvc info`
   and `fbsvcmgr` ask the live service manager for the same items; every decoded
   value must be identical, including the numerics (where a string reading would
   swallow the next item) and the `svr_db_info` cluster.
2. **The engine's client against our server.** `fbsvcmgr` — a C++ tool with the
   engine's own decoder — reads fire-crab's answers, cluster included. Then our
   own client reads the same server and must agree with `fbsvcmgr` about it: two
   independent decoders, one buffer.
3. **The truncation boundary**, measured on the engine and required of
   fire-crab, offline and over the wire.
4. **The grammars**, from bytes captured in the same run: `fbsvcmgr`'s real
   attach SPB and query buffers, plus the teeth — the same bytes read under
   another grammar must NOT produce the same items.
5. **The refusals**: `isc_wish_list` from both servers for an unimplemented
   item; an action refused by fire-crab and performed by the engine.

## Actions: `db_stats`, and what an action's answer really is

An action is not a query. `op_service_start` hands the manager an SPB naming
what to do; the answer is a TEXT STREAM the client then polls with
`isc_info_svc_line` or `isc_info_svc_to_eof`. So a service session is
stateful — start, then poll until the stream ends — and a converted service
manager has to hold that state per connection.

`isc_action_svc_db_stats` with `isc_spb_sts_hdr_pages` is converted, which
means `gstat` — the engine's own C++ tool — can ask fire-crab for a database's
header statistics and print them:

```
$ gstat -user SYSDBA -password masterkey localhost/4231:/tmp/x.fdb -h
```

The report itself is `fire_crab_ods::header_report`, the conversion of
`PPG_print_header` (`src/utilities/gstat/ppg.cpp:56-287`), and the gate
requires the text to be **identical** to what the same `gstat` prints when it
reads the file itself. Three details in that text are easy to get wrong:

* **`Flags` is the PAGE's flags, not the header's.** `ppg.cpp:58` prints
  `header->hdr_header.pag_flags` — a `pag` field, usually 0 — while the
  interesting bits (`hdr_force_write` and friends) come out further down as
  `Attributes`. A converter that prints `hdr_flags` on the `Flags` line gets
  18 where gstat gets 0.
* **The `Attributes` label is printed unconditionally; its value is not.**
  The label goes out with no newline, and only if some attribute exists does
  the text and the line break follow (`ppg.cpp:102-217`). A database with no
  attributes therefore ends that line dangling, and the next thing in the
  stream is the blank line before `Variable header data`. The gate keeps a
  `gfix -w async` database around purely to cover that case.
* **`Database dialect 1` means "no dialect information".** A dialect-1
  database has no dialect bit in its header, so the absence is the answer
  (`ppg.cpp:81-87`) — it is not unknown.

The report also needs fields fire-crab had not decoded before: the
implementation triple (`hdr_db_impl`, printed through
`DbImplementation`'s hardware/OS/compiler NAME TABLES — index-into-a-list, so
the tables are part of the format), the creation date, the shadow count, and
the **variable header clumplets** after the fixed part (`hdr_data` at offset
148: `<type><length><data>` until `HDR_end`), which is where the sweep
interval, the backup difference file and the replication sequence live.

## The output stream, and the strangest law in this subsystem

`isc_info_svc_line` and `isc_info_svc_to_eof` read the same bytes and disagree
about newlines, on purpose (`svc.cpp:2404`):

> If returning a line of information, replace all new line characters with a
> space. This will ensure that the output is consistent when returning a line
> or to eof.

So a LINE is the bytes up to and including its newline, with **the newline
turned into a space** — which makes a blank line arrive as a single space,
`3e 01 00 20 01` on the wire. And "nothing" is reserved: a **zero-length**
item, `3e 00 00 01`, is how the stream says it is finished. `to_eof` returns
the raw bytes, newlines intact, chunked by the client's buffer length.

Both conventions were read off the live engine's wire with
`fcsvc stats --raw` before being implemented, and the gate compares the real
server's bytes with fire-crab's for the same poll. Guessing here is
unnecessary and would have been wrong: "a blank line is an empty item" is the
natural guess, and it collides with end-of-stream.

## Validation belongs to the service, not the client

`gstat -h` combined with `-d` is refused — *"option -h is incompatible with
options -a, -d, -i, -r, -schema, -s and -t"* — and the refusal comes from the
SERVER: gstat message 38, arriving as gds **336920614**, a facility-coded
number rather than one of the `isc_*` codes. fire-crab converts the rule
(`stats_options_conflict`) and answers the same combination with the same
code, which the gate checks in both directions for three combinations.

The ordering matters and is deliberate: the conflict check runs BEFORE
fire-crab's own capability check, so a malformed request gets the engine's
answer rather than "fire-crab cannot do that".

## Not everything a utility does is a service

Worth checking before any of the frontier below is built: **a switch on a
utility is not evidence that the utility used a service to deliver it.**
`gfix -write sync|async` is the case that proved it. It looks like a
maintenance action, it is documented alongside ones that are, and it goes
through no service manager at all — gfix ATTACHES to the database, carrying
the mode in the DPB as `isc_dpb_force_write` (tag 24, consts_pub.h:59), and
detaches. What it asks for is one bit in the header page,
`hdr_force_write` (ods.h:724), and it is honoured at attach
(`qa/serve-real-forcewrite.sh`).

The failure mode is quiet, which is why it is written here: a server that
implemented the SPB action and not the DPB item would pass every service
gate and leave the switch doing nothing. So for each item below, the first
question is not "how is this action shaped" but **"does the tool send an
action at all?"**

For gfix the engine's own source answers it, and the answer is *none of
them do*: `src/alice/exe.cpp:211-344` builds ONE DPB and attaches with it,
and every switch is an item in it — `isc_dpb_sweep`, `isc_dpb_verify`,
`isc_dpb_sweep_interval`, `isc_dpb_set_page_buffers`, `isc_dpb_force_write`,
`isc_dpb_no_reserve`, `isc_dpb_set_db_readonly`, `isc_dpb_shutdown`,
`isc_dpb_online`, `isc_dpb_set_db_sql_dialect`, `isc_dpb_set_db_replica`,
`isc_dpb_parallel_workers`, `isc_dpb_nolinger`. The whole utility is an
attach with `isc_dpb_gfix_attach` set, and `EXE_action` (exe.cpp:71) is its
only path — there is no service branch to take.

The switch table (aliceswi.h:162-294) does carry an `isc_spb_prp_*` code
per switch, which is the trap: nothing in `src/alice/` ever reads that
field. It is the SAME PROPERTY reachable two ways, and the other way
belongs to a different client — `fbsvcmgr action_properties
prp_page_buffers ...` (fbsvcmgr.cpp:470-478) sends the SPB. So both are
worth having and **neither substitutes for the other**: the SPB action
alone leaves gfix silently doing nothing, and the DPB items alone leave
fbsvcmgr unanswered.

That also says where the work is: most of those items are **one field of
the header page**, which is why `gstat -h` is the oracle for all of them.

One more thing that only shows up if you read `buildDpb` (exe.cpp:207-344)
rather than assuming: it is a single **else-if chain**, so gfix puts
exactly ONE item in the dpb. Several switches on one command line collapse
to whichever the chain reaches first — `-buffers 700 -housekeeping 999`
sets the sweep interval and leaves the buffers alone, from either argv
order — and the dropped ones are dropped silently, rc=0. The dpb has no
such rule, and `fbsvcmgr` can ask for several properties in one request,
so a server should apply everything it is sent; it just never sees more
than one from gfix.

## Frontier

* **The remaining actions**: `gbak`'s backup and restore, `gfix`'s repair and
  sweep, user management. Each is a whole utility behind an SPB. `db_stats` is
  done for the header report (below); its data-page, index and record-version
  analyses need the page walks `fcstat census` already does offline.
* **`isc_info_svc_data_not_ready`** — the marker for "the action is still
  running, ask again". fire-crab computes its whole answer inside
  `op_service_start`, so its stream is complete before the first poll and the
  marker never arises; a long-running action would need it.
* **The `isc_info_length` prefix** on a query whose first item is
  `isc_info_length`, and `isc_info_svc_timeout` as a *response* item.
* `isc_info_svc_limbo_trans` (the real server answers it as an empty string
  item), `isc_info_svc_get_users`, `isc_info_svc_get_config`.
* The `SpbStart` per-action grammar: the state machine in
  `ClumpletReader.cpp:304+` that gives each action its own tag shapes.
