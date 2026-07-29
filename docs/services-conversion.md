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
* a service **action** — backup, restore, sweep, stats, add-user — is refused
  outright. This slice changed that from an acknowledgement: the old server
  answered `op_service_start` with a clean `op_response`, and a clean response
  to a backup request means "done". The client then polled an empty output
  stream and reported a successful backup that never happened. `fbsvcmgr` now
  prints *"feature is not supported"* for `action_db_stats` against fire-crab
  and the real statistics against the engine, which is the honest pair.

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

## Frontier

* **Actions**, which is where the rest of this subsystem lives: `gbak`'s backup
  and restore, `gfix`'s repair, `gstat`'s statistics, user management. Each is a
  whole utility behind an SPB; `fcstat` already answers gstat's questions
  offline, so `isc_action_svc_db_stats` is the natural first one.
* **The output stream** (`isc_info_svc_line` / `isc_info_svc_to_eof` with
  `isc_info_data_not_ready` and the `isc_info_length` prefix) — the framing an
  action's progress text arrives in. Converted only as constants so far.
* `isc_info_svc_limbo_trans` (the real server answers it as an empty string
  item), `isc_info_svc_get_users`, `isc_info_svc_get_config`.
* The `SpbStart` per-action grammar: the state machine in
  `ClumpletReader.cpp:304+` that gives each action its own tag shapes.
