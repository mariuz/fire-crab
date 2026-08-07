//! fire-crab-svc - the Services manager, converted from `src/jrd/svc.cpp`
//! (`Service::query2`, the SPB handling) with the buffer grammars from
//! `src/common/classes/ClumpletReader.cpp` and the two response encoders
//! from `src/jrd/inf.cpp` / `ibase.h`.
//!
//! # What the Services API actually is
//!
//! It is a second protocol living inside the first. A client attaches to
//! the name `service_mgr` instead of a database, and from then on every
//! request and every answer is a BYTE BUFFER of tagged items: no
//! statements, no BLR, no rows. `gbak`, `gfix`, `gstat`, `fbsvcmgr`,
//! `nbackup` and every driver's "service" class are all this one
//! interface - which is why converting the buffers converts the tools.
//!
//! # One buffer format, four grammars
//!
//! The single trap of this subsystem: the *same* byte-string shape means
//! different things depending on which buffer it is. `ClumpletReader`
//! carries a `kind` for exactly this reason, and getting it wrong reads
//! a length as a tag:
//!
//! | buffer | grammar | shape |
//! |---|---|---|
//! | attach SPB | [`Grammar::SpbAttach`] | TAGGED, then `[tag][u8 len][data]` |
//! | query "send" items | [`Grammar::SpbSendItems`] | `[tag][u16 LE len][data]`, control tags bare |
//! | query "receive" items | [`Grammar::SpbReceiveItems`] | bare `[tag]`, no length at all |
//! | start SPB (an action) | [`Grammar::SpbStart`] | per-action state machine |
//!
//! *Tagged* means the buffer opens with `isc_spb_version` (2) followed by
//! the version byte, or with `isc_spb_version1` (1) standing alone
//! (`ClumpletReader::getBufferTag`, line 240).
//!
//! And the RESPONSE has two shapes, chosen per item, neither of which is
//! the request's shape:
//!
//! * string items - `INF_put_item` (inf.cpp): `[tag][u16 LE len][bytes]`
//! * numeric items - `ADD_SPB_NUMERIC` (ibase.h:1093): `[tag][4 bytes LE]`
//!   with NO length prefix at all
//!
//! A decoder must therefore know each item's type from the item code;
//! there is nothing in the bytes to tell it. [`item_is_numeric`] is that
//! knowledge, converted from which macro svc.cpp uses at each site.
//!
//! # Truncation is part of the contract
//!
//! `INF_put_item` needs `length + 4` bytes of room - the tag, the two
//! length bytes, the data, and one byte kept in reserve for
//! `isc_info_end`. When it does not have them it writes
//! `isc_info_truncated` (2) followed by `isc_info_end` (1) and stops.
//! A server that instead writes as much as fits produces a buffer whose
//! reader cannot tell it is incomplete. [`InfoResponse`] enforces the
//! reserve.

pub mod client;

/// The client private key `a` the oracle uses. Fixed, so a captured
/// handshake is reproducible - which is right for an oracle and wrong
/// for a client (see `fire_crab_wire::login`, which takes randomness
/// from its caller).
pub const SRP_A: &[u8] = &[0x2bu8; 128];

/// SPB tags (`consts_pub.h:303-338`; the ones aliased to `isc_dpb_*`
/// carry their DPB values).
pub mod spb {
    pub const VERSION1: u8 = 1;
    pub const CURRENT_VERSION: u8 = 2;
    /// `isc_spb_version` - the tag that says "a version byte follows"
    pub const VERSION: u8 = CURRENT_VERSION;
    pub const VERSION3: u8 = 3;

    pub const USER_NAME: u8 = 28; // = isc_dpb_user_name
    pub const SYS_USER_NAME: u8 = 19;
    pub const PASSWORD: u8 = 29; // = isc_dpb_password
    pub const PASSWORD_ENC: u8 = 30;
    pub const CONNECT_TIMEOUT: u8 = 57; // = isc_dpb_connect_timeout
    pub const DUMMY_PACKET_INTERVAL: u8 = 58;
    pub const SQL_ROLE_NAME: u8 = 60;

    pub const COMMAND_LINE: u8 = 105;
    pub const DBNAME: u8 = 106;
    pub const VERBOSE: u8 = 107;
    pub const OPTIONS: u8 = 108;
    pub const ADDRESS_PATH: u8 = 109;
    pub const PROCESS_ID: u8 = 110;
    pub const TRUSTED_AUTH: u8 = 111;
    pub const PROCESS_NAME: u8 = 112;
    pub const TRUSTED_ROLE: u8 = 113;
    pub const VERBINT: u8 = 114;
    pub const AUTH_BLOCK: u8 = 115;
    pub const AUTH_PLUGIN_NAME: u8 = 116;
    pub const AUTH_PLUGIN_LIST: u8 = 117;
    pub const UTF8_FILENAME: u8 = 118;
    pub const CLIENT_VERSION: u8 = 119;
    pub const REMOTE_PROTOCOL: u8 = 120;
    pub const HOST_NAME: u8 = 121;
    pub const OS_USER: u8 = 122;
    pub const CONFIG: u8 = 123;
    pub const EXPECTED_DB: u8 = 124;

    /// Inside an `isc_info_svc_svr_db_info` cluster (consts_pub.h:612).
    pub const NUM_ATT: u8 = 5;
    pub const NUM_DB: u8 = 6;
}

/// Service info items (`consts_pub.h:375-394`) and the generic info
/// codes they share with every other info buffer (`inf_pub.h:32-37`).
pub mod info {
    pub const END: u8 = 1;
    pub const TRUNCATED: u8 = 2;
    pub const ERROR: u8 = 3;
    pub const DATA_NOT_READY: u8 = 4;
    pub const LENGTH: u8 = 126;
    pub const FLAG_END: u8 = 127;

    pub const SVR_DB_INFO: u8 = 50;
    pub const GET_LICENSE: u8 = 51;
    pub const GET_LICENSE_MASK: u8 = 52;
    pub const GET_CONFIG: u8 = 53;
    pub const VERSION: u8 = 54;
    pub const SERVER_VERSION: u8 = 55;
    pub const IMPLEMENTATION: u8 = 56;
    pub const CAPABILITIES: u8 = 57;
    pub const USER_DBPATH: u8 = 58;
    pub const GET_ENV: u8 = 59;
    pub const GET_ENV_LOCK: u8 = 60;
    pub const GET_ENV_MSG: u8 = 61;
    pub const LINE: u8 = 62;
    pub const TO_EOF: u8 = 63;
    pub const TIMEOUT: u8 = 64;
    pub const GET_LICENSED_USERS: u8 = 65;
    pub const LIMBO_TRANS: u8 = 66;
    pub const RUNNING: u8 = 67;
    pub const GET_USERS: u8 = 68;
    pub const STDIN: u8 = 78;
}

/// Service actions (`consts_pub.h:344-369`). Only the ones fire-crab
/// answers are named here; the rest are refused by number, which is the
/// honest thing to do with an action whose semantics are a backup.
pub mod action {
    pub const BACKUP: u8 = 1;
    pub const RESTORE: u8 = 2;
    pub const REPAIR: u8 = 3;
    pub const ADD_USER: u8 = 4;
    pub const DELETE_USER: u8 = 5;
    pub const MODIFY_USER: u8 = 6;
    pub const DISPLAY_USER: u8 = 7;
    pub const PROPERTIES: u8 = 8;
    pub const DB_STATS: u8 = 11;
    pub const GET_FB_LOG: u8 = 12;
    pub const NBAK: u8 = 20;
    pub const NREST: u8 = 21;
    pub const TRACE_START: u8 = 22;
    pub const VALIDATE: u8 = 30;
    pub const LAST: u8 = 32;
}

/// `isc_spb_sts_*` (consts_pub.h:619-630): what a `db_stats` action is
/// asked to report. The low bits are an OPTIONS bitmask; `sts_table` and
/// `sts_schema` are string clumplets, not bits.
pub mod sts {
    pub const DATA_PAGES: u32 = 0x01;
    pub const DB_LOG: u32 = 0x02;
    pub const HDR_PAGES: u32 = 0x04;
    pub const IDX_PAGES: u32 = 0x08;
    pub const SYS_RELATIONS: u32 = 0x10;
    pub const RECORD_VERSIONS: u32 = 0x20;
    pub const NOCREATION: u32 = 0x80;
    pub const ENCRYPTION: u32 = 0x100;
    /// string clumplets, not bits
    pub const TABLE: u8 = 64;
    pub const SCHEMA: u8 = 65;
}

/// Statistics-option validation, enforced by the SERVICE and not by the
/// client: `isc_spb_sts_hdr_pages` may not be combined with any other
/// analysis. The engine answers the combination with gstat message 38 -
/// *"option -h is incompatible with options -a, -d, -i, -r, -schema, -s
/// and -t"* - as gds 336920614, which is a facility-coded message, not one
/// of the isc_* codes.
///
/// Probed both ways against the live server: `data` alone runs, `hdr data`
/// and `hdr versions` are refused with that exact code.
pub const GSTAT_HDR_INCOMPATIBLE: i32 = 336920614;

/// Whether an options bitmask breaks the rule above.
pub fn stats_options_conflict(options: u32) -> bool {
    let others = sts::DATA_PAGES
        | sts::DB_LOG
        | sts::IDX_PAGES
        | sts::SYS_RELATIONS
        | sts::RECORD_VERSIONS
        | sts::ENCRYPTION;
    options & sts::HDR_PAGES != 0 && options & others != 0
}

/// How one clumplet is framed (`ClumpletReader::ClumpletType`, with the
/// sizes from `getClumpletSize`). A start SPB mixes all of these in one
/// buffer, keyed by (action, tag) - there is no self-describing length.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClumpletType {
    /// 1-byte length (the attach SPB's form)
    Traditional,
    /// 2-byte LE length - "used in SPB for long strings"
    StringSpb,
    /// no length, 4 bytes of data
    IntSpb,
    /// no length, 8 bytes
    BigIntSpb,
    /// no length, 1 byte
    ByteSpb,
    /// tag only
    Single,
}

impl ClumpletType {
    fn length_bytes(self) -> usize {
        match self {
            ClumpletType::Traditional => 1,
            ClumpletType::StringSpb => 2,
            _ => 0,
        }
    }
    fn fixed_data(self) -> usize {
        match self {
            ClumpletType::IntSpb => 4,
            ClumpletType::BigIntSpb => 8,
            ClumpletType::ByteSpb => 1,
            _ => 0,
        }
    }
}

/// The (action, tag) -> framing table for a start SPB
/// (`ClumpletReader::getClumpletType`, the `SpbStart` arm).
///
/// Only the actions fire-crab parses are described. An unknown pair is
/// refused rather than guessed: guessing a length turns the next tag into
/// data and the rest of the buffer into nonsense.
pub fn start_clumplet_type(action: u8, tag: u8) -> Option<ClumpletType> {
    use ClumpletType::*;
    match action {
        action::DB_STATS => match tag {
            spb::DBNAME | spb::COMMAND_LINE | sts::TABLE | sts::SCHEMA => Some(StringSpb),
            spb::OPTIONS => Some(IntSpb),
            _ => None,
        },
        action::BACKUP | action::RESTORE => match tag {
            spb::DBNAME | bkp::FILE | bkp::SKIP_DATA | bkp::INCLUDE_DATA => Some(StringSpb),
            spb::OPTIONS | spb::VERBINT | bkp::FACTOR | bkp::LENGTH | bkp::PARALLEL => {
                Some(IntSpb)
            }
            spb::VERBOSE => Some(Single),
            _ => None,
        },
        action::REPAIR | action::VALIDATE => match tag {
            spb::DBNAME => Some(StringSpb),
            spb::OPTIONS => Some(IntSpb),
            _ => None,
        },
        // the engine's own framing table (ClumpletReader.cpp:440-457):
        // strings for the file names and the GUID, ints for the level
        // and the history knobs, a bare tag for clean_history
        action::NBAK | action::NREST => match tag {
            nbk::FILE | nbk::DIRECT | spb::DBNAME | nbk::GUID => Some(StringSpb),
            nbk::LEVEL | spb::OPTIONS | nbk::KEEP_DAYS | nbk::KEEP_ROWS => Some(IntSpb),
            nbk::CLEAN_HISTORY => Some(Single),
            _ => None,
        },
        action::GET_FB_LOG => None,
        _ => None,
    }
}

/// `isc_spb_bkp_*` - the gbak actions' own tags (consts_pub.h:425+).
pub mod bkp {
    pub const FILE: u8 = 5;
    pub const FACTOR: u8 = 6;
    pub const LENGTH: u8 = 7;
    pub const SKIP_DATA: u8 = 8;
    pub const INCLUDE_DATA: u8 = 9;
    pub const PARALLEL: u8 = 21;
}

/// `isc_spb_nbk_*` - the nbackup action's own tags (consts_pub.h:642-651).
pub mod nbk {
    pub const LEVEL: u8 = 5;
    pub const FILE: u8 = 6;
    pub const DIRECT: u8 = 7;
    pub const GUID: u8 = 8;
    pub const CLEAN_HISTORY: u8 = 9;
    pub const KEEP_DAYS: u8 = 10;
    pub const KEEP_ROWS: u8 = 11;
    /// `isc_spb_nbk_no_triggers` - an OPTIONS bit, not a tag
    pub const OPT_NO_TRIGGERS: u32 = 0x01;
    /// `isc_spb_nbk_inplace` - restore onto an existing database
    pub const OPT_INPLACE: u32 = 0x02;
    pub const OPT_SEQUENCE: u32 = 0x04;
}

/// Build the start SPB for `db_stats` on one database - what `gstat`
/// through a service manager sends.
pub fn build_start_db_stats(db: &str, options: u32) -> Vec<u8> {
    let mut v = vec![action::DB_STATS];
    v.push(spb::DBNAME);
    v.extend_from_slice(&(db.len() as u16).to_le_bytes());
    v.extend_from_slice(db.as_bytes());
    v.push(spb::OPTIONS);
    v.extend_from_slice(&options.to_le_bytes());
    v
}

/// Which grammar a buffer follows (`ClumpletReader::Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Grammar {
    /// The attach SPB: tagged, traditional-DPB clumplets (1-byte length).
    SpbAttach,
    /// The "send" half of a query: 2-byte-length clumplets, except the
    /// control codes, which stand alone (ClumpletReader.cpp:286-299).
    SpbSendItems,
    /// The "receive" half of a query: bare tags.
    SpbReceiveItems,
    /// A start SPB. The action byte comes first and decides the shape of
    /// what follows; this slice parses the action and refuses the rest.
    SpbStart,
}

/// One tag with its data (empty for bare tags).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Clumplet {
    pub tag: u8,
    pub data: Vec<u8>,
}

impl Clumplet {
    /// The data as a string, trailing NULs dropped (clients pad).
    pub fn text(&self) -> String {
        let end = self
            .data
            .iter()
            .position(|b| *b == 0)
            .unwrap_or(self.data.len());
        String::from_utf8_lossy(&self.data[..end]).into_owned()
    }
    /// The data as the 4-byte little-endian number Firebird writes for
    /// numeric parameters (shorter data is zero-extended, as
    /// `gds__vax_integer` reads it).
    pub fn number(&self) -> u64 {
        let mut v = 0u64;
        for (i, b) in self.data.iter().take(8).enumerate() {
            v |= (*b as u64) << (8 * i);
        }
        v
    }
}

/// A parsed buffer: the version tag (for the tagged grammars) and its
/// clumplets in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Buffer {
    pub version: Option<u8>,
    pub items: Vec<Clumplet>,
}

impl Buffer {
    pub fn first(&self, tag: u8) -> Option<&Clumplet> {
        self.items.iter().find(|c| c.tag == tag)
    }
    pub fn text(&self, tag: u8) -> Option<String> {
        self.first(tag).map(|c| c.text())
    }
    pub fn number(&self, tag: u8) -> Option<u64> {
        self.first(tag).map(|c| c.number())
    }
    /// The tags in order - what a differential compares.
    pub fn tags(&self) -> Vec<u8> {
        self.items.iter().map(|c| c.tag).collect()
    }
}

/// Whether a tag stands alone inside a "send items" buffer
/// (ClumpletReader.cpp:286-299: the control codes are `SingleTpb`,
/// everything else is `StringSpb`).
fn send_item_is_bare(tag: u8) -> bool {
    matches!(
        tag,
        info::END | info::TRUNCATED | info::ERROR | info::DATA_NOT_READY | info::LENGTH | info::FLAG_END
    )
}

/// Parse a service buffer under the given grammar.
///
/// Malformed input is REFUSED with the reason rather than salvaged:
/// `ClumpletReader::invalid_structure` raises, and a service buffer that
/// half-parses is a request nobody made.
pub fn parse(grammar: Grammar, buf: &[u8]) -> Result<Buffer, String> {
    let mut at = 0usize;
    let mut version = None;

    if grammar == Grammar::SpbAttach {
        // getBufferTag (ClumpletReader.cpp:240): isc_spb_version means a
        // version byte follows; isc_spb_version1 IS the tag.
        match buf.first() {
            None => return Err("empty buffer".into()),
            Some(&spb::VERSION) => {
                if buf.len() < 2 {
                    return Err("buffer too short: isc_spb_version with no version".into());
                }
                version = Some(buf[1]);
                at = 2;
            }
            Some(&spb::VERSION1) => {
                version = Some(spb::VERSION1);
                at = 1;
            }
            Some(t) => return Err(format!("unknown SPB buffer tag {}", t)),
        }
    }

    let mut items = Vec::new();
    while at < buf.len() {
        let tag = buf[at];
        at += 1;
        match grammar {
            Grammar::SpbReceiveItems => {
                // bare tags; nothing follows any of them
                items.push(Clumplet { tag, data: vec![] });
            }
            Grammar::SpbStart => {
                // the FIRST byte is the action, and it decides how every
                // later tag in this buffer is framed
                if items.is_empty() {
                    items.push(Clumplet { tag, data: vec![] });
                    continue;
                }
                let action = items[0].tag;
                let kind = start_clumplet_type(action, tag).ok_or_else(|| {
                    format!("action {} has no framing for tag {}", action, tag)
                })?;
                let mut len = kind.fixed_data();
                match kind.length_bytes() {
                    1 => {
                        len = *buf
                            .get(at)
                            .ok_or_else(|| format!("clumplet {} has no length byte", tag))?
                            as usize;
                        at += 1;
                    }
                    2 => {
                        if at + 2 > buf.len() {
                            return Err(format!("clumplet {} has no length word", tag));
                        }
                        len = u16::from_le_bytes([buf[at], buf[at + 1]]) as usize;
                        at += 2;
                    }
                    _ => {}
                }
                let end = at + len;
                if end > buf.len() {
                    return Err(format!(
                        "clumplet {} claims {} bytes, {} remain",
                        tag,
                        len,
                        buf.len() - at
                    ));
                }
                items.push(Clumplet {
                    tag,
                    data: buf[at..end].to_vec(),
                });
                at = end;
            }
            Grammar::SpbAttach => {
                let len = *buf
                    .get(at)
                    .ok_or_else(|| format!("clumplet {} has no length byte", tag))?
                    as usize;
                at += 1;
                let end = at + len;
                if end > buf.len() {
                    return Err(format!(
                        "clumplet {} claims {} bytes, {} remain",
                        tag,
                        len,
                        buf.len() - at
                    ));
                }
                items.push(Clumplet {
                    tag,
                    data: buf[at..end].to_vec(),
                });
                at = end;
            }
            Grammar::SpbSendItems => {
                if send_item_is_bare(tag) {
                    items.push(Clumplet { tag, data: vec![] });
                    continue;
                }
                if at + 2 > buf.len() {
                    return Err(format!("send item {} has no length word", tag));
                }
                let len = u16::from_le_bytes([buf[at], buf[at + 1]]) as usize;
                at += 2;
                let end = at + len;
                if end > buf.len() {
                    return Err(format!(
                        "send item {} claims {} bytes, {} remain",
                        tag,
                        len,
                        buf.len() - at
                    ));
                }
                items.push(Clumplet {
                    tag,
                    data: buf[at..end].to_vec(),
                });
                at = end;
            }
        }
    }
    Ok(Buffer { version, items })
}

/// Whether an item's ANSWER is a bare 4-byte number rather than a
/// length-prefixed string - i.e. whether svc.cpp writes it with
/// `ADD_SPB_NUMERIC` (ibase.h:1093) or `INF_put_item` (inf.cpp).
///
/// Nothing in the response bytes distinguishes the two, so a decoder
/// that guesses reads a length as data. Inside an
/// `isc_info_svc_svr_db_info` cluster the same rule applies to
/// `isc_spb_num_att` / `isc_spb_num_db` (numeric) and `isc_spb_dbname`
/// (string).
pub fn item_is_numeric(tag: u8) -> bool {
    matches!(
        tag,
        info::VERSION
            | info::CAPABILITIES
            | info::RUNNING
            | info::STDIN
            | info::GET_LICENSED_USERS
            | spb::NUM_ATT
            | spb::NUM_DB
    )
}

/// A response buffer under construction, with the engine's room rules.
pub struct InfoResponse {
    buf: Vec<u8>,
    limit: usize,
    truncated: bool,
}

impl InfoResponse {
    /// `limit` is the client's buffer length: the engine writes nothing
    /// past it.
    pub fn new(limit: usize) -> InfoResponse {
        InfoResponse {
            buf: Vec::new(),
            limit,
            truncated: false,
        }
    }

    /// `INF_put_item` (inf.cpp): a string item needs `len + 5` bytes of
    /// buffer - the test is `ptr + length + 4 >= end`, i.e. tag, two
    /// length bytes, the data, one byte held back for `isc_info_end`, and
    /// the comparison is `>=`, so the last byte of the buffer is never
    /// used. Probed against the live engine with a 35-byte answer: buffer
    /// 39 truncates, buffer 40 fits. Without them it writes
    /// `isc_info_truncated`, `isc_info_end`, and stops accepting.
    pub fn string(&mut self, tag: u8, data: &[u8]) -> &mut Self {
        if self.truncated {
            return self;
        }
        if self.buf.len() + data.len() + 4 >= self.limit || data.len() > u16::MAX as usize {
            self.truncate();
            return self;
        }
        self.buf.push(tag);
        self.buf
            .extend_from_slice(&(data.len() as u16).to_le_bytes());
        self.buf.extend_from_slice(data);
        self
    }

    /// `ADD_SPB_NUMERIC`: four little-endian bytes, no length prefix.
    /// `ck_space_for_numeric` (svc.cpp) tests `info + 1 + 4 > end` - a
    /// STRICT `>`, unlike the string path's `>=`. The two differ by one
    /// byte, and both are converted as written rather than unified.
    pub fn numeric(&mut self, tag: u8, value: u32) -> &mut Self {
        if self.truncated {
            return self;
        }
        if self.buf.len() + 5 > self.limit {
            self.truncate();
            return self;
        }
        self.buf.push(tag);
        self.buf.extend_from_slice(&value.to_le_bytes());
        self
    }

    /// A bare marker (`isc_info_flag_end` closes a cluster).
    pub fn marker(&mut self, tag: u8) -> &mut Self {
        if !self.truncated && self.buf.len() + 2 <= self.limit {
            self.buf.push(tag);
        }
        self
    }

    fn truncate(&mut self) {
        self.truncated = true;
        if self.buf.len() < self.limit {
            self.buf.push(info::TRUNCATED);
        }
        if self.buf.len() < self.limit {
            self.buf.push(info::END);
        }
    }

    pub fn was_truncated(&self) -> bool {
        self.truncated
    }

    /// Close with `isc_info_end` (already written on truncation).
    pub fn finish(mut self) -> Vec<u8> {
        if !self.truncated {
            self.buf.push(info::END);
        }
        self.buf
    }
}

/// The output stream of a running action - what `isc_info_svc_line` and
/// `isc_info_svc_to_eof` read from (`Service::get`, svc.cpp:2360-2430).
///
/// The two items differ in ONE documented way, and it is a strange one:
///
/// > If returning a line of information, replace all new line characters
/// > with a space. This will ensure that the output is consistent when
/// > returning a line or to eof. — svc.cpp:2404
///
/// So `isc_info_svc_line` returns the bytes up to and including the
/// newline, with the newline itself REPLACED BY A SPACE, and stops there.
/// An empty line therefore comes back as a single space, not as nothing -
/// and "nothing" is reserved: a ZERO-length item is how the stream says it
/// is finished. Both were read off the wire from the live engine
/// (`fcsvc stats --raw`), which is the only way to be sure of a convention
/// like this.
pub struct Output {
    text: Vec<u8>,
    at: usize,
}

impl Output {
    pub fn new(text: impl Into<Vec<u8>>) -> Output {
        Output {
            text: text.into(),
            at: 0,
        }
    }

    /// `isc_info_svc_line`: one line, its newline turned into a space.
    /// Empty when the stream is exhausted.
    pub fn next_line(&mut self) -> Vec<u8> {
        if self.at >= self.text.len() {
            return Vec::new();
        }
        let mut out = Vec::new();
        while self.at < self.text.len() {
            let ch = self.text[self.at];
            self.at += 1;
            if ch == b'\n' {
                out.push(b' ');
                break;
            }
            out.push(ch);
        }
        out
    }

    /// `isc_info_svc_to_eof`: as much as fits, raw - newlines survive.
    pub fn to_eof(&mut self, limit: usize) -> Vec<u8> {
        let end = (self.at + limit).min(self.text.len());
        let out = self.text[self.at..end].to_vec();
        self.at = end;
        out
    }

    pub fn finished(&self) -> bool {
        self.at >= self.text.len()
    }

    pub fn remaining(&self) -> usize {
        self.text.len().saturating_sub(self.at)
    }
}

/// Answer a poll of a running action's output. `item` is
/// `isc_info_svc_line` or `isc_info_svc_to_eof`; anything else is not this
/// function's business.
///
/// The buffer length bounds the answer the same way every other info item
/// is bounded, so a `to_eof` of a long report comes back in several polls.
/// Answer a poll whose receive items are the OUTPUT-STREAM family -
/// `isc_info_svc_line` / `to_eof`, optionally with `isc_info_svc_stdin`
/// alongside, which is exactly how nbackup's client polls (measured:
/// recv = 3e 4e). `stdin` answers a numeric 0 - "the server wants no
/// stdin" (svc.cpp:1337-1348, ADD_SPB_NUMERIC(info, 0)) - and a client
/// that is told anything else waits to send input the action will never
/// read.
pub fn answer_output_items(recv: &[u8], out: &mut Output, buffer_length: usize) -> Vec<u8> {
    let mut r = InfoResponse::new(buffer_length);
    let room = buffer_length.saturating_sub(5);
    for &item in recv {
        match item {
            info::LINE => {
                let line = out.next_line();
                r.string(item, &line);
            }
            info::TO_EOF => {
                let chunk = out.to_eof(room);
                r.string(item, &chunk);
            }
            info::STDIN => {
                r.numeric(item, 0);
            }
            1 => break, // isc_info_end in the request
            _ => {}
        }
    }
    r.finish()
}

pub fn answer_output(item: u8, out: &mut Output, buffer_length: usize) -> Vec<u8> {
    let mut r = InfoResponse::new(buffer_length);
    // room for the tag, the length word and isc_info_end
    let room = buffer_length.saturating_sub(5);
    let chunk = match item {
        info::TO_EOF => out.to_eof(room),
        _ => {
            let line = out.next_line();
            if line.len() > room {
                // a line longer than the buffer: the engine's own answer
                // is a truncated item, which InfoResponse produces
                line
            } else {
                line
            }
        }
    };
    r.string(item, &chunk);
    r.finish()
}

/// What a service manager knows about itself - the values svc.cpp reads
/// from `FB_VERSION`, the config and `JRD_enum_attachments`.
#[derive(Clone, Debug)]
pub struct ServerInfo {
    pub server_version: String,
    pub implementation: String,
    /// the security database in use (`isc_info_svc_user_dbpath`)
    pub security_db: String,
    /// $FIREBIRD and $FIREBIRD_LOCK
    pub root: String,
    pub lock_dir: String,
    pub msg_dir: String,
    /// the service manager's own version (`SERVICE_VERSION`)
    pub service_version: u32,
    pub capabilities: u32,
    /// attachments / databases / database names, as
    /// `isc_info_svc_svr_db_info` reports them
    pub attachments: u32,
    pub databases: Vec<String>,
}

impl ServerInfo {
    /// Answer a "receive items" buffer, honoring the client's buffer
    /// length exactly as `Service::query2` does.
    ///
    /// An item this server does not implement REFUSES THE WHOLE QUERY,
    /// because that is what the engine does: `query2`'s `default:` arm is
    /// `status << Arg::Gds(isc_wish_list)` (svc.cpp), an error status, not
    /// a marker in the buffer. Skipping the item silently would be worse
    /// than either - the client would read the NEXT item's bytes as this
    /// item's answer.
    pub fn answer(&self, items: &[u8], buffer_length: usize) -> Result<Vec<u8>, QueryError> {
        let mut out = InfoResponse::new(buffer_length);
        for &it in items {
            if it == info::END {
                break;
            }
            match it {
                info::SERVER_VERSION => {
                    out.string(it, self.server_version.as_bytes());
                }
                info::IMPLEMENTATION => {
                    out.string(it, self.implementation.as_bytes());
                }
                info::USER_DBPATH => {
                    out.string(it, self.security_db.as_bytes());
                }
                info::GET_ENV => {
                    out.string(it, self.root.as_bytes());
                }
                info::GET_ENV_LOCK => {
                    out.string(it, self.lock_dir.as_bytes());
                }
                info::GET_ENV_MSG => {
                    out.string(it, self.msg_dir.as_bytes());
                }
                info::VERSION => {
                    out.numeric(it, self.service_version);
                }
                info::CAPABILITIES => {
                    out.numeric(it, self.capabilities);
                }
                // no asynchronous action can be running: fire-crab starts
                // none (see the refusal in the server's op_service_start)
                info::RUNNING => {
                    out.numeric(it, 0);
                }
                info::STDIN => {
                    out.numeric(it, 0);
                }
                // the cluster: [item][num_att][num_db][dbname...][flag_end]
                info::SVR_DB_INFO => {
                    out.marker(it);
                    out.numeric(spb::NUM_ATT, self.attachments);
                    out.numeric(spb::NUM_DB, self.databases.len() as u32);
                    for db in &self.databases {
                        out.string(spb::DBNAME, db.as_bytes());
                    }
                    out.marker(info::FLAG_END);
                }
                _ => return Err(QueryError::Unsupported(it)),
            }
        }
        Ok(out.finish())
    }
}

/// Why a query was refused. The engine answers all of these with
/// `isc_wish_list` in the status vector.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueryError {
    /// an info item this service manager does not implement
    Unsupported(u8),
}

impl std::fmt::Display for QueryError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            QueryError::Unsupported(i) => {
                write!(f, "service info item {} is not implemented", i)
            }
        }
    }
}

/// One decoded answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answer {
    Text(u8, String),
    Number(u8, u64),
    /// a bare marker: `isc_info_end`, `isc_info_flag_end`,
    /// `isc_info_truncated`, `isc_info_error`
    Marker(u8),
}

/// Decode a service response buffer, using [`item_is_numeric`] to know
/// each item's shape.
///
/// Stops at `isc_info_end`. A `isc_info_truncated` is returned as a
/// marker rather than swallowed - a caller that ignores it is reading a
/// partial answer as a complete one.
pub fn decode(buf: &[u8]) -> Result<Vec<Answer>, String> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at < buf.len() {
        let tag = buf[at];
        at += 1;
        match tag {
            info::END => break,
            // isc_info_svc_svr_db_info opens its cluster as a BARE tag
            // (svc.cpp:1163 writes `*info++ = item` and no length), so a
            // decoder that treats every non-numeric item as a string
            // reads num_att's tag as a length word.
            info::TRUNCATED
            | info::ERROR
            | info::DATA_NOT_READY
            | info::FLAG_END
            | info::SVR_DB_INFO => {
                out.push(Answer::Marker(tag));
            }
            t if item_is_numeric(t) => {
                if at + 4 > buf.len() {
                    return Err(format!("item {} is numeric but only {} bytes remain", t, buf.len() - at));
                }
                let v = u32::from_le_bytes([buf[at], buf[at + 1], buf[at + 2], buf[at + 3]]);
                at += 4;
                out.push(Answer::Number(t, v as u64));
            }
            t => {
                if at + 2 > buf.len() {
                    return Err(format!("item {} has no length word", t));
                }
                let len = u16::from_le_bytes([buf[at], buf[at + 1]]) as usize;
                at += 2;
                if at + len > buf.len() {
                    return Err(format!(
                        "item {} claims {} bytes, {} remain",
                        t,
                        len,
                        buf.len() - at
                    ));
                }
                out.push(Answer::Text(
                    t,
                    String::from_utf8_lossy(&buf[at..at + len]).into_owned(),
                ));
                at += len;
            }
        }
    }
    Ok(out)
}

/// Build the "receive items" buffer for a query: bare tags.
pub fn receive_items(items: &[u8]) -> Vec<u8> {
    items.to_vec()
}

/// Build a "send items" buffer setting the query timeout, the one send
/// item a client normally uses (`isc_info_svc_timeout`, 2-byte length -
/// the shape fbsvcmgr's own buffer has).
pub fn send_items_timeout(seconds: u32) -> Vec<u8> {
    let mut v = vec![info::TIMEOUT];
    v.extend_from_slice(&4u16.to_le_bytes());
    v.extend_from_slice(&seconds.to_le_bytes());
    v.push(info::END);
    v
}

/// The attach SPB a client sends: tagged version 2, then the credentials
/// and identification clumplets (the shape captured from fbsvcmgr).
pub fn attach_spb(user: &str, password: &str, process: &str, client_version: &str) -> Vec<u8> {
    let mut v = vec![spb::VERSION, spb::CURRENT_VERSION];
    let mut put = |tag: u8, data: &[u8]| {
        v.push(tag);
        v.push(data.len() as u8);
        v.extend_from_slice(data);
    };
    put(spb::UTF8_FILENAME, &[]);
    put(spb::USER_NAME, user.as_bytes());
    if !password.is_empty() {
        put(spb::PASSWORD, password.as_bytes());
    }
    put(spb::PROCESS_NAME, process.as_bytes());
    put(spb::CLIENT_VERSION, client_version.as_bytes());
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The nbackup actions' framing (ClumpletReader.cpp:440-457), and
    /// the poll shape its client uses: line + stdin TOGETHER, the stdin
    /// answered numeric 0 - a server that refuses the pair fails an
    /// action that already succeeded.
    #[test]
    fn nbackup_framing_and_the_line_stdin_poll() {
        assert_eq!(
            start_clumplet_type(action::NBAK, nbk::FILE),
            Some(ClumpletType::StringSpb)
        );
        assert_eq!(
            start_clumplet_type(action::NBAK, nbk::LEVEL),
            Some(ClumpletType::IntSpb)
        );
        assert_eq!(
            start_clumplet_type(action::NREST, spb::DBNAME),
            Some(ClumpletType::StringSpb)
        );
        assert_eq!(start_clumplet_type(action::NBAK, 99), None);

        // a start SPB the way fbsvcmgr builds one: action, level 0,
        // dbname, nbk_file
        let mut v = vec![action::NBAK, nbk::LEVEL];
        v.extend_from_slice(&0u32.to_le_bytes());
        v.push(spb::DBNAME);
        v.extend_from_slice(&2u16.to_le_bytes());
        v.extend_from_slice(b"db");
        v.push(nbk::FILE);
        v.extend_from_slice(&3u16.to_le_bytes());
        v.extend_from_slice(b"nbk");
        let b = parse(Grammar::SpbStart, &v).unwrap();
        assert_eq!(b.number(nbk::LEVEL), Some(0));
        assert_eq!(b.text(spb::DBNAME).as_deref(), Some("db"));
        assert_eq!(b.text(nbk::FILE).as_deref(), Some("nbk"));

        // the poll: recv = [line, stdin] answers a line item AND a
        // numeric-0 stdin item, then isc_info_end
        let mut out = Output::new("hello\nworld\n");
        let ans = answer_output_items(&[info::LINE, info::STDIN], &mut out, 512);
        assert_eq!(ans[0], info::LINE);
        let len = u16::from_le_bytes([ans[1], ans[2]]) as usize;
        assert_eq!(&ans[3..3 + len], b"hello ");
        assert_eq!(ans[3 + len], info::STDIN);
        assert_eq!(&ans[4 + len..8 + len], &0u32.to_le_bytes());
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// The attach SPB `fbsvcmgr` really sends, captured off the wire by
    /// `FC_SRV_TRACE` while the engine's own tool attached to fcwire's
    /// service manager.
    const FBSVCMGR_SPB: &str = concat!(
        "0202",                                     // isc_spb_version, version 2
        "7600",                                     // utf8_filename, no data
        "1c06", "535953444241",                     // user_name "SYSDBA"
        "3a04", "00000000",                         // dummy_packet_interval 0
        "6e04", "f5b90f00",                         // process_id
        "701a", "2f6f70742f66697265626972642f62696e2f66627376636d6772", // process_name
        "7723", "4c492d54362e302e302e3230373620466972656269726420362e302066643833663033"
    );

    #[test]
    fn parses_the_real_fbsvcmgr_attach_spb() {
        let b = parse(Grammar::SpbAttach, &hex(FBSVCMGR_SPB)).expect("real SPB");
        assert_eq!(b.version, Some(spb::CURRENT_VERSION));
        assert_eq!(
            b.tags(),
            vec![
                spb::UTF8_FILENAME,
                spb::USER_NAME,
                spb::DUMMY_PACKET_INTERVAL,
                spb::PROCESS_ID,
                spb::PROCESS_NAME,
                spb::CLIENT_VERSION,
            ]
        );
        assert_eq!(b.text(spb::USER_NAME).as_deref(), Some("SYSDBA"));
        assert_eq!(b.number(spb::DUMMY_PACKET_INTERVAL), Some(0));
        assert_eq!(b.number(spb::PROCESS_ID), Some(0x000fb9f5));
        assert_eq!(
            b.text(spb::PROCESS_NAME).as_deref(),
            Some("/opt/firebird/bin/fbsvcmgr")
        );
        assert_eq!(
            b.text(spb::CLIENT_VERSION).as_deref(),
            Some("LI-T6.0.0.2076 Firebird 6.0 fd83f03")
        );
        // NO password clumplet: the credentials went through SRP, and the
        // SPB carries only the login. A server that requires
        // isc_spb_password here refuses every modern client.
        assert!(b.first(spb::PASSWORD).is_none());
        // the process id is the tag's own code (110), not the DPB's (71)
        assert_eq!(spb::PROCESS_ID, 110);
    }

    #[test]
    fn attach_spb_round_trip() {
        let spb = attach_spb("SYSDBA", "masterkey", "/usr/bin/fcsvc", "fire-crab");
        let b = parse(Grammar::SpbAttach, &spb).expect("our own SPB must parse");
        assert_eq!(b.version, Some(spb::CURRENT_VERSION));
        assert_eq!(b.text(spb::USER_NAME).as_deref(), Some("SYSDBA"));
        assert_eq!(b.text(spb::PASSWORD).as_deref(), Some("masterkey"));
        assert_eq!(b.text(spb::CLIENT_VERSION).as_deref(), Some("fire-crab"));
        // isc_spb_utf8_filename carries no data - a flag, not a value
        assert_eq!(b.first(spb::UTF8_FILENAME).map(|c| c.data.len()), Some(0));
    }

    #[test]
    fn version1_spb_is_its_own_tag() {
        // getBufferTag: isc_spb_version1 IS the tag, with no version byte
        let b = parse(Grammar::SpbAttach, &[spb::VERSION1, spb::USER_NAME, 3, b'A', b'B', b'C'])
            .expect("version1 form");
        assert_eq!(b.version, Some(spb::VERSION1));
        assert_eq!(b.text(spb::USER_NAME).as_deref(), Some("ABC"));
    }

    #[test]
    fn malformed_spb_is_refused_not_salvaged() {
        assert!(parse(Grammar::SpbAttach, &[]).is_err());
        assert!(parse(Grammar::SpbAttach, &[spb::VERSION]).is_err()); // no version
        assert!(parse(Grammar::SpbAttach, &[9, 9, 9]).is_err()); // unknown buffer tag
        // a clumplet longer than the buffer
        assert!(parse(
            Grammar::SpbAttach,
            &[spb::VERSION, spb::CURRENT_VERSION, spb::USER_NAME, 10, b'A']
        )
        .is_err());
    }

    #[test]
    fn send_items_use_a_two_byte_length_and_bare_control_codes() {
        // captured from fbsvcmgr: 40 0400 01000000 01 - timeout 1 second
        // then isc_info_end. A one-byte-length reading sees tag 64,
        // length 4, data 00 01 00 00, then tag 0 - nonsense.
        let buf = hex("4004000100000001");
        let b = parse(Grammar::SpbSendItems, &buf).expect("real send buffer");
        assert_eq!(b.tags(), vec![info::TIMEOUT, info::END]);
        assert_eq!(b.first(info::TIMEOUT).unwrap().number(), 1);
        assert_eq!(send_items_timeout(1), buf);
    }

    #[test]
    fn receive_items_are_bare_tags() {
        // captured from fbsvcmgr: 37 32 - server_version, svr_db_info,
        // with no terminator at all
        let b = parse(Grammar::SpbReceiveItems, &hex("3732")).unwrap();
        assert_eq!(b.tags(), vec![info::SERVER_VERSION, info::SVR_DB_INFO]);
        assert!(b.items.iter().all(|c| c.data.is_empty()));
    }

    #[test]
    fn a_start_spb_is_framed_by_its_action() {
        // the action byte decides how every later tag is framed - a start
        // SPB mixes 2-byte-length strings with bare 4-byte integers, and
        // nothing in the bytes says which is which
        let spb = build_start_db_stats("/tmp/x.fdb", sts::HDR_PAGES);
        let b = parse(Grammar::SpbStart, &spb).expect("our own start SPB");
        assert_eq!(b.items[0].tag, action::DB_STATS);
        assert_eq!(b.text(spb::DBNAME).as_deref(), Some("/tmp/x.fdb"));
        assert_eq!(b.number(spb::OPTIONS), Some(sts::HDR_PAGES as u64));
        // isc_spb_dbname is a StringSpb (2-byte length), isc_spb_options an
        // IntSpb (no length at all)
        assert_eq!(
            start_clumplet_type(action::DB_STATS, spb::DBNAME),
            Some(ClumpletType::StringSpb)
        );
        assert_eq!(
            start_clumplet_type(action::DB_STATS, spb::OPTIONS),
            Some(ClumpletType::IntSpb)
        );
        // a tag this action has no framing for is REFUSED, not guessed:
        // guessing a length turns the next tag into data
        assert_eq!(start_clumplet_type(action::DB_STATS, spb::PASSWORD), None);
        assert!(parse(
            Grammar::SpbStart,
            &[action::DB_STATS, spb::PASSWORD, 3, b'a', b'b', b'c']
        )
        .is_err());
        // and an action we do not parse at all
        assert!(parse(Grammar::SpbStart, &[action::ADD_USER, spb::USER_NAME, 1, b'x']).is_err());
    }

    fn server() -> ServerInfo {
        ServerInfo {
            server_version: "LI-V6.0.0.2076 Firebird 6.0 fire-crab".into(),
            implementation: "Firebird/Linux/ARM64".into(),
            security_db: "/opt/firebird/security6.fdb".into(),
            root: "/opt/firebird/".into(),
            lock_dir: "/tmp/firebird/".into(),
            msg_dir: "/opt/firebird/".into(),
            service_version: 2,
            capabilities: 0,
            attachments: 0,
            databases: vec![],
        }
    }

    #[test]
    fn string_items_carry_a_two_byte_length_numerics_do_not() {
        let out = server().answer(&[info::SERVER_VERSION, info::RUNNING], 16384).unwrap();
        assert_eq!(out[0], info::SERVER_VERSION);
        let n = u16::from_le_bytes([out[1], out[2]]) as usize;
        assert!(String::from_utf8_lossy(&out[3..3 + n]).starts_with("LI-V"));
        let rest = &out[3 + n..];
        assert_eq!(rest[0], info::RUNNING);
        // four bytes, NO length prefix
        assert_eq!(
            u32::from_le_bytes([rest[1], rest[2], rest[3], rest[4]]),
            0
        );
        assert_eq!(rest[5], info::END);
    }

    #[test]
    fn svr_db_info_is_a_cluster_closed_by_flag_end() {
        let mut s = server();
        s.attachments = 3;
        s.databases = vec!["/tmp/a.fdb".into(), "/tmp/b.fdb".into()];
        let out = s.answer(&[info::SVR_DB_INFO], 16384).unwrap();
        let got = decode(&out).unwrap();
        assert_eq!(
            got,
            vec![
                Answer::Marker(info::SVR_DB_INFO),
                Answer::Number(spb::NUM_ATT, 3),
                Answer::Number(spb::NUM_DB, 2),
                Answer::Text(spb::DBNAME, "/tmp/a.fdb".into()),
                Answer::Text(spb::DBNAME, "/tmp/b.fdb".into()),
                Answer::Marker(info::FLAG_END),
            ]
        );
    }

    #[test]
    fn hdr_statistics_may_not_be_combined_with_another_analysis() {
        // the engine enforces this in the SERVICE, with gstat message 38
        // (gds 336920614) - probed live: `data` alone runs, `hdr data` and
        // `hdr versions` are refused
        assert!(stats_options_conflict(sts::HDR_PAGES | sts::DATA_PAGES));
        assert!(stats_options_conflict(sts::HDR_PAGES | sts::RECORD_VERSIONS));
        assert!(stats_options_conflict(sts::HDR_PAGES | sts::IDX_PAGES));
        // each alone is fine
        assert!(!stats_options_conflict(sts::HDR_PAGES));
        assert!(!stats_options_conflict(sts::DATA_PAGES | sts::IDX_PAGES));
        // nocreation is a MODIFIER of the header report, not an analysis
        assert!(!stats_options_conflict(sts::HDR_PAGES | sts::NOCREATION));
    }

    #[test]
    fn a_line_ends_with_a_space_where_its_newline_was() {
        // svc.cpp:2404 - "replace all new line characters with a space" -
        // so an EMPTY line is a single space, and a zero-length item is
        // reserved for end-of-stream. Both pinned off the live engine's
        // wire bytes (3e 0100 20 01 for a blank line, 3e 0000 01 at EOF).
        let mut o = Output::new("a\n\nbc\n");
        assert_eq!(o.next_line(), b"a ");
        assert_eq!(o.next_line(), b" ");
        assert_eq!(o.next_line(), b"bc ");
        assert!(o.finished());
        assert_eq!(o.next_line(), b"");
        // the framing the engine sends: [tag][u16 len][text][isc_info_end]
        let mut o = Output::new("x\n");
        let buf = answer_output(info::LINE, &mut o, 8192);
        assert_eq!(buf, vec![info::LINE, 2, 0, b'x', b' ', info::END]);
        let end = answer_output(info::LINE, &mut o, 8192);
        assert_eq!(end, vec![info::LINE, 0, 0, info::END]);
    }

    #[test]
    fn to_eof_keeps_the_newlines_and_chunks_by_buffer() {
        // the same stream read the other way: raw bytes, newlines intact -
        // which is why the LINE path has to substitute a space, or the two
        // readings would disagree about the text
        let mut o = Output::new("one\ntwo\n");
        let all = o.to_eof(8192);
        assert_eq!(all, b"one\ntwo\n");
        assert!(o.finished());
        // a small buffer splits the stream across polls
        let mut o = Output::new("abcdefghij");
        let a = answer_output(info::TO_EOF, &mut o, 10); // 10 - 5 = 5 bytes
        assert_eq!(a, vec![info::TO_EOF, 5, 0, b'a', b'b', b'c', b'd', b'e', info::END]);
        assert_eq!(o.remaining(), 5);
        let b = answer_output(info::TO_EOF, &mut o, 10);
        assert_eq!(&b[3..8], b"fghij");
        assert!(o.finished());
    }

    #[test]
    fn a_short_buffer_says_truncated_and_stops() {
        // INF_put_item needs len + 4 bytes: the tag, two length bytes,
        // the data, and one byte held for isc_info_end. Anything less
        // must yield isc_info_truncated + isc_info_end, NOT a partial
        // string a reader would take for complete.
        let s = server();
        let full = s.answer(&[info::SERVER_VERSION], 16384).unwrap();
        let short = s.answer(&[info::SERVER_VERSION], 10).unwrap();
        assert!(full.len() > 10);
        assert_eq!(short, vec![info::TRUNCATED, info::END]);
        let got = decode(&short).unwrap();
        assert_eq!(got, vec![Answer::Marker(info::TRUNCATED)]);
        // The boundary, probed against the live engine: with a 35-byte
        // answer, buffer 39 truncated and buffer 40 fit. So len + 4 is
        // NOT enough (the test is `>=`) and len + 5 is - the last byte of
        // the buffer is never written.
        let n = s.server_version.len();
        assert_eq!(
            s.answer(&[info::SERVER_VERSION], n + 4).unwrap(),
            vec![info::TRUNCATED, info::END]
        );
        let exact = s.answer(&[info::SERVER_VERSION], n + 5).unwrap();
        assert_eq!(exact[0], info::SERVER_VERSION);
        assert_eq!(exact.len(), n + 4);
        assert_eq!(*exact.last().unwrap(), info::END);
    }

    #[test]
    fn an_unimplemented_item_refuses_the_whole_query() {
        // svc.cpp's query2 `default:` arm raises isc_wish_list; it does
        // not skip the item and it does not answer a marker. Skipping
        // would make the client read the NEXT item's bytes as this one's.
        assert_eq!(
            server().answer(&[info::GET_LICENSE, info::VERSION], 16384),
            Err(QueryError::Unsupported(info::GET_LICENSE))
        );
        // and a query of only implemented items still answers
        assert!(server().answer(&[info::VERSION], 16384).is_ok());
    }

    #[test]
    fn decode_refuses_a_truncated_tail() {
        // a length word that runs past the buffer is a lie, not a value
        assert!(decode(&[info::SERVER_VERSION, 10, 0, b'a']).is_err());
        assert!(decode(&[info::RUNNING, 0, 0]).is_err());
    }

    #[test]
    fn round_trip_every_answered_item() {
        let mut s = server();
        s.attachments = 1;
        s.databases = vec!["/x.fdb".into()];
        let items = [
            info::SERVER_VERSION,
            info::IMPLEMENTATION,
            info::USER_DBPATH,
            info::GET_ENV,
            info::GET_ENV_LOCK,
            info::GET_ENV_MSG,
            info::VERSION,
            info::CAPABILITIES,
            info::RUNNING,
            info::STDIN,
        ];
        let got = decode(&s.answer(&items, 16384).unwrap()).unwrap();
        assert_eq!(got.len(), items.len());
        for (a, it) in got.iter().zip(items.iter()) {
            match a {
                Answer::Text(t, _) | Answer::Number(t, _) => assert_eq!(t, it),
                Answer::Marker(t) => panic!("item {} answered with a marker {}", it, t),
            }
        }
    }
}
