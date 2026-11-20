//! Slice 6: the remaining catalog rows `INI_format` stores - types,
//! character sets and collations, system packages, the default
//! publication, the admin role, the DDL security classes and the
//! additional system-privilege grants (ini.epp:845-956, 1420-1468,
//! 1781-1966, 1968+) - plus the `DPM_gen_id` end values and the index
//! maintenance slice 5's contract requires ([maintain_row]).
//!
//! Pipeline position: after `store_system_indexes` and
//! `store_runtime_blobs`. Every row this slice inserts is keyed into
//! the covering trees as it is stored, the engine's `IDX_store` half;
//! running it before the index builds fails on the missing roots.
//!
//! Class numbering replays the engine exactly: `RDB$CHARACTER_SETS`
//! and `RDB$COLLATIONS` take the `SQL$250..450` range slice 4
//! reserved (`INTL_CLASSES_RESERVED`, asserted, not trusted),
//! packages take `464..467`, the admin role `468`, and the DDL
//! classes keep their unnumbered `SQL$D<object>[<schema>]` names.
//! `RDB$DATABASE` already carries `SQL$DATABASE` via slice 4's fold,
//! so the `DdlSecurity::store` patch has nothing to do.
//!
//! Every value is pinned twice: against the engine source that
//! computes it and against a live fresh database (6.0.0.2182,
//! `/tmp/s6probe.fdb`, read 2026-11-20). Where the two disagreed the
//! file won and the source reading is noted; where they agree only
//! one citation is given.
//!
//! Two folds keep this slice self-contained:
//!
//! - collation `RDB$SPECIFIC_ATTRIBUTES` are stored as pinned
//!   literals. The engine resolves them through the live ICU module
//!   at create time (`setupCollationAttributes`, IntlManager.cpp:732)
//!   - 7 rows carry `COLL-VERSION`/`ICU-VERSION` strings the static
//!   `defaultCollations` table does not have (NULL there). The pinned
//!   strings are the reference build's (ICU 74.2).
//! - the three `GRANT_privileges` recomputations (ini.epp:942-956)
//!   were written final where the classes were stored (slice 4's
//!   third fold): the recompute's page is full by the time this
//!   slice runs, so no rewrite could land them. This slice stores
//!   only the 15 privilege rows; the recomputed bytes are pinned by
//!   its class test.

use crate::catalog_format::descriptors_for;
use crate::catalog_index::maintain_row;
use crate::catalog_rows::{
    ddl_acl, encode_image, nonrelation_acl, priv_cells, rel_by_name, rel_col, role_acl, Cell, Priv,
    SecurityAlloc, INTL_CLASSES_RESERVED,
};
use crate::data::DataPage;
use crate::dml;
use crate::format::{decode_record, max_recs_per_dp, Descriptor};
use crate::Image;

/// (field, value, name): the `types[]` array `INI_format` stores
/// into `RDB$TYPES` first (ini.epp:856-871), i.e. `types.h` with every
/// macro resolved plus the 27 `SystemPrivileges.h` rows spliced where
/// the `#include` sits (before `MON$CRYPT_STATE`). `blr_blob` is 261,
/// an `(unsigned short)`, not a byte (blr.h:56). Verified row for row
/// against the fresh 2182 file before porting.
pub const SYS_TYPES: &[(&str, i64, &str)] = &[
    // --- RDB$FIELD_TYPE ---
    ("RDB$FIELD_TYPE", 14, "TEXT"),
    ("RDB$FIELD_TYPE", 7, "SHORT"),
    ("RDB$FIELD_TYPE", 8, "LONG"),
    ("RDB$FIELD_TYPE", 9, "QUAD"),
    ("RDB$FIELD_TYPE", 10, "FLOAT"),
    ("RDB$FIELD_TYPE", 27, "DOUBLE"),
    ("RDB$FIELD_TYPE", 35, "TIMESTAMP"),
    ("RDB$FIELD_TYPE", 37, "VARYING"),
    ("RDB$FIELD_TYPE", 261, "BLOB"),
    ("RDB$FIELD_TYPE", 40, "CSTRING"),
    ("RDB$FIELD_TYPE", 45, "BLOB_ID"),
    ("RDB$FIELD_TYPE", 12, "DATE"),
    ("RDB$FIELD_TYPE", 13, "TIME"),
    ("RDB$FIELD_TYPE", 16, "INT64"),
    ("RDB$FIELD_TYPE", 23, "BOOLEAN"),
    ("RDB$FIELD_TYPE", 24, "DECFLOAT(16)"),
    ("RDB$FIELD_TYPE", 25, "DECFLOAT(34)"),
    ("RDB$FIELD_TYPE", 29, "TIMESTAMP WITH TIME ZONE"),
    ("RDB$FIELD_TYPE", 28, "TIME WITH TIME ZONE"),
    ("RDB$FIELD_TYPE", 26, "INT128"),
    // --- RDB$FIELD_SUB_TYPE ---
    ("RDB$FIELD_SUB_TYPE", 0, "BINARY"),
    ("RDB$FIELD_SUB_TYPE", 1, "TEXT"),
    ("RDB$FIELD_SUB_TYPE", 2, "BLR"),
    ("RDB$FIELD_SUB_TYPE", 3, "ACL"),
    ("RDB$FIELD_SUB_TYPE", 4, "RANGES"),
    ("RDB$FIELD_SUB_TYPE", 5, "SUMMARY"),
    ("RDB$FIELD_SUB_TYPE", 6, "FORMAT"),
    ("RDB$FIELD_SUB_TYPE", 7, "TRANSACTION_DESCRIPTION"),
    ("RDB$FIELD_SUB_TYPE", 8, "EXTERNAL_FILE_DESCRIPTION"),
    ("RDB$FIELD_SUB_TYPE", 9, "DEBUG_INFORMATION"),
    // --- RDB$FUNCTION_TYPE ---
    ("RDB$FUNCTION_TYPE", 0, "VALUE"),
    ("RDB$FUNCTION_TYPE", 1, "BOOLEAN"),
    // --- RDB$MECHANISM ---
    ("RDB$MECHANISM", 0, "BY_VALUE"),
    ("RDB$MECHANISM", 1, "BY_REFERENCE"),
    ("RDB$MECHANISM", 2, "BY_VMS_DESCRIPTOR"),
    ("RDB$MECHANISM", 3, "BY_ISC_DESCRIPTOR"),
    ("RDB$MECHANISM", 4, "BY_SCALAR_ARRAY_DESCRIPTOR"),
    ("RDB$MECHANISM", 5, "BY_REFERENCE_WITH_NULL"),
    // --- RDB$TRIGGER_TYPE ---
    ("RDB$TRIGGER_TYPE", 1, "PRE_STORE"),
    ("RDB$TRIGGER_TYPE", 2, "POST_STORE"),
    ("RDB$TRIGGER_TYPE", 3, "PRE_MODIFY"),
    ("RDB$TRIGGER_TYPE", 4, "POST_MODIFY"),
    ("RDB$TRIGGER_TYPE", 5, "PRE_ERASE"),
    ("RDB$TRIGGER_TYPE", 6, "POST_ERASE"),
    ("RDB$TRIGGER_TYPE", 8192, "CONNECT"),
    ("RDB$TRIGGER_TYPE", 8193, "DISCONNECT"),
    ("RDB$TRIGGER_TYPE", 8194, "TRANSACTION_START"),
    ("RDB$TRIGGER_TYPE", 8195, "TRANSACTION_COMMIT"),
    ("RDB$TRIGGER_TYPE", 8196, "TRANSACTION_ROLLBACK"),
    // --- RDB$OBJECT_TYPE ---
    ("RDB$OBJECT_TYPE", 0, "RELATION"),
    ("RDB$OBJECT_TYPE", 1, "VIEW"),
    ("RDB$OBJECT_TYPE", 2, "TRIGGER"),
    ("RDB$OBJECT_TYPE", 3, "COMPUTED_FIELD"),
    ("RDB$OBJECT_TYPE", 4, "VALIDATION"),
    ("RDB$OBJECT_TYPE", 5, "PROCEDURE"),
    ("RDB$OBJECT_TYPE", 6, "INDEX_EXPRESSION"),
    ("RDB$OBJECT_TYPE", 7, "EXCEPTION"),
    ("RDB$OBJECT_TYPE", 8, "USER"),
    ("RDB$OBJECT_TYPE", 9, "FIELD"),
    ("RDB$OBJECT_TYPE", 10, "INDEX"),
    ("RDB$OBJECT_TYPE", 11, "CHARACTER_SET"),
    ("RDB$OBJECT_TYPE", 12, "USER_GROUP"),
    ("RDB$OBJECT_TYPE", 13, "ROLE"),
    ("RDB$OBJECT_TYPE", 14, "GENERATOR"),
    ("RDB$OBJECT_TYPE", 15, "UDF"),
    ("RDB$OBJECT_TYPE", 16, "BLOB_FILTER"),
    ("RDB$OBJECT_TYPE", 17, "COLLATION"),
    ("RDB$OBJECT_TYPE", 18, "PACKAGE"),
    ("RDB$OBJECT_TYPE", 19, "PACKAGE BODY"),
    ("RDB$OBJECT_TYPE", 37, "INDEX_CONDITION"),
    ("RDB$OBJECT_TYPE", 38, "SCHEMA"),
    // --- RDB$TRANSACTION_STATE ---
    ("RDB$TRANSACTION_STATE", 1, "LIMBO"),
    ("RDB$TRANSACTION_STATE", 2, "COMMITTED"),
    ("RDB$TRANSACTION_STATE", 3, "ROLLED_BACK"),
    // --- RDB$SYSTEM_FLAG ---
    ("RDB$SYSTEM_FLAG", 0, "USER"),
    ("RDB$SYSTEM_FLAG", 1, "SYSTEM"),
    ("RDB$SYSTEM_FLAG", 2, "QLI"),
    ("RDB$SYSTEM_FLAG", 3, "CHECK_CONSTRAINT"),
    ("RDB$SYSTEM_FLAG", 4, "REFERENTIAL_CONSTRAINT"),
    ("RDB$SYSTEM_FLAG", 5, "VIEW_CHECK"),
    ("RDB$SYSTEM_FLAG", 6, "IDENTITY_GENERATOR"),
    // --- RDB$RELATION_TYPE ---
    ("RDB$RELATION_TYPE", 0, "PERSISTENT"),
    ("RDB$RELATION_TYPE", 1, "VIEW"),
    ("RDB$RELATION_TYPE", 2, "EXTERNAL"),
    ("RDB$RELATION_TYPE", 3, "VIRTUAL"),
    ("RDB$RELATION_TYPE", 4, "GLOBAL_TEMPORARY_PRESERVE"),
    ("RDB$RELATION_TYPE", 5, "GLOBAL_TEMPORARY_DELETE"),
    // --- RDB$PROCEDURE_TYPE ---
    ("RDB$PROCEDURE_TYPE", 0, "LEGACY"),
    ("RDB$PROCEDURE_TYPE", 1, "SELECTABLE"),
    ("RDB$PROCEDURE_TYPE", 2, "EXECUTABLE"),
    // --- RDB$PARAMETER_MECHANISM ---
    ("RDB$PARAMETER_MECHANISM", 0, "NORMAL"),
    ("RDB$PARAMETER_MECHANISM", 1, "TYPE OF"),
    // --- MON$STATE ---
    ("MON$STATE", 0, "IDLE"),
    ("MON$STATE", 1, "ACTIVE"),
    ("MON$STATE", 2, "STALLED"),
    // --- MON$SHUTDOWN_MODE ---
    ("MON$SHUTDOWN_MODE", 0, "ONLINE"),
    ("MON$SHUTDOWN_MODE", 1, "MULTI_USER_SHUTDOWN"),
    ("MON$SHUTDOWN_MODE", 2, "SINGLE_USER_SHUTDOWN"),
    ("MON$SHUTDOWN_MODE", 3, "FULL_SHUTDOWN"),
    // --- MON$ISOLATION_MODE ---
    ("MON$ISOLATION_MODE", 0, "CONSISTENCY"),
    ("MON$ISOLATION_MODE", 1, "CONCURRENCY"),
    ("MON$ISOLATION_MODE", 2, "READ_COMMITTED_VERSION"),
    ("MON$ISOLATION_MODE", 3, "READ_COMMITTED_NO_VERSION"),
    ("MON$ISOLATION_MODE", 4, "READ_COMMITTED_READ_CONSISTENCY"),
    // --- MON$BACKUP_STATE ---
    ("MON$BACKUP_STATE", 0, "NORMAL"),
    ("MON$BACKUP_STATE", 1, "STALLED"),
    ("MON$BACKUP_STATE", 2, "MERGE"),
    // --- MON$STAT_GROUP ---
    ("MON$STAT_GROUP", 0, "DATABASE"),
    ("MON$STAT_GROUP", 1, "ATTACHMENT"),
    ("MON$STAT_GROUP", 2, "TRANSACTION"),
    ("MON$STAT_GROUP", 3, "STATEMENT"),
    ("MON$STAT_GROUP", 4, "CALL"),
    // --- RDB$IDENTITY_TYPE ---
    ("RDB$IDENTITY_TYPE", 0, "ALWAYS"),
    ("RDB$IDENTITY_TYPE", 1, "BY DEFAULT"),
    // --- RDB$PARAMETER_TYPE ---
    ("RDB$PARAMETER_TYPE", 0, "INPUT"),
    ("RDB$PARAMETER_TYPE", 1, "OUTPUT"),
    // --- RDB$TRIGGER_INACTIVE ---
    ("RDB$TRIGGER_INACTIVE", 0, "ACTIVE"),
    ("RDB$TRIGGER_INACTIVE", 1, "INACTIVE"),
    // --- RDB$INDEX_INACTIVE ---
    ("RDB$INDEX_INACTIVE", 0, "ACTIVE"),
    ("RDB$INDEX_INACTIVE", 1, "INACTIVE"),
    // --- RDB$UNIQUE_FLAG ---
    ("RDB$UNIQUE_FLAG", 0, "NON_UNIQUE"),
    ("RDB$UNIQUE_FLAG", 1, "UNIQUE"),
    // --- RDB$GRANT_OPTION ---
    ("RDB$GRANT_OPTION", 0, "NONE"),
    ("RDB$GRANT_OPTION", 1, "GRANT_OPTION"),
    ("RDB$GRANT_OPTION", 2, "ADMIN_OPTION"),
    // --- RDB$PAGE_TYPE ---
    ("RDB$PAGE_TYPE", 1, "HEADER"),
    ("RDB$PAGE_TYPE", 2, "PAGE_INVENTORY"),
    ("RDB$PAGE_TYPE", 3, "TRANSACTION_INVENTORY"),
    ("RDB$PAGE_TYPE", 4, "POINTER"),
    ("RDB$PAGE_TYPE", 5, "DATA"),
    ("RDB$PAGE_TYPE", 6, "INDEX_ROOT"),
    ("RDB$PAGE_TYPE", 7, "INDEX_BUCKET"),
    ("RDB$PAGE_TYPE", 8, "BLOB"),
    ("RDB$PAGE_TYPE", 9, "GENERATOR"),
    ("RDB$PAGE_TYPE", 10, "SCN_INVENTORY"),
    // --- RDB$PRIVATE_FLAG ---
    ("RDB$PRIVATE_FLAG", 0, "PUBLIC"),
    ("RDB$PRIVATE_FLAG", 1, "PRIVATE"),
    // --- RDB$LEGACY_FLAG ---
    ("RDB$LEGACY_FLAG", 0, "NEW_STYLE"),
    ("RDB$LEGACY_FLAG", 1, "LEGACY_STYLE"),
    // --- RDB$DETERMINISTIC_FLAG ---
    ("RDB$DETERMINISTIC_FLAG", 0, "NON_DETERMINISTIC"),
    ("RDB$DETERMINISTIC_FLAG", 1, "DETERMINISTIC"),
    // --- RDB$AGGREGATE_FLAG ---
    ("RDB$AGGREGATE_FLAG", 0, "STANDARD"),
    ("RDB$AGGREGATE_FLAG", 1, "AGGREGATE"),
    // --- RDB$MAP_TO_TYPE ---
    ("RDB$MAP_TO_TYPE", 0, "USER"),
    ("RDB$MAP_TO_TYPE", 1, "ROLE"),
    // --- RDB$SYSTEM_PRIVILEGES ---
    ("RDB$SYSTEM_PRIVILEGES", 1, "USER_MANAGEMENT"),
    ("RDB$SYSTEM_PRIVILEGES", 2, "READ_RAW_PAGES"),
    ("RDB$SYSTEM_PRIVILEGES", 3, "CREATE_USER_TYPES"),
    ("RDB$SYSTEM_PRIVILEGES", 4, "USE_NBACKUP_UTILITY"),
    ("RDB$SYSTEM_PRIVILEGES", 5, "CHANGE_SHUTDOWN_MODE"),
    ("RDB$SYSTEM_PRIVILEGES", 6, "TRACE_ANY_ATTACHMENT"),
    ("RDB$SYSTEM_PRIVILEGES", 7, "MONITOR_ANY_ATTACHMENT"),
    ("RDB$SYSTEM_PRIVILEGES", 8, "ACCESS_SHUTDOWN_DATABASE"),
    ("RDB$SYSTEM_PRIVILEGES", 9, "CREATE_DATABASE"),
    ("RDB$SYSTEM_PRIVILEGES", 10, "DROP_DATABASE"),
    ("RDB$SYSTEM_PRIVILEGES", 11, "USE_GBAK_UTILITY"),
    ("RDB$SYSTEM_PRIVILEGES", 12, "USE_GSTAT_UTILITY"),
    ("RDB$SYSTEM_PRIVILEGES", 13, "USE_GFIX_UTILITY"),
    ("RDB$SYSTEM_PRIVILEGES", 14, "IGNORE_DB_TRIGGERS"),
    ("RDB$SYSTEM_PRIVILEGES", 15, "CHANGE_HEADER_SETTINGS"),
    ("RDB$SYSTEM_PRIVILEGES", 16, "SELECT_ANY_OBJECT_IN_DATABASE"),
    ("RDB$SYSTEM_PRIVILEGES", 17, "ACCESS_ANY_OBJECT_IN_DATABASE"),
    ("RDB$SYSTEM_PRIVILEGES", 18, "MODIFY_ANY_OBJECT_IN_DATABASE"),
    ("RDB$SYSTEM_PRIVILEGES", 19, "CHANGE_MAPPING_RULES"),
    ("RDB$SYSTEM_PRIVILEGES", 20, "USE_GRANTED_BY_CLAUSE"),
    ("RDB$SYSTEM_PRIVILEGES", 21, "GRANT_REVOKE_ON_ANY_OBJECT"),
    ("RDB$SYSTEM_PRIVILEGES", 22, "GRANT_REVOKE_ANY_DDL_RIGHT"),
    ("RDB$SYSTEM_PRIVILEGES", 23, "CREATE_PRIVILEGED_ROLES"),
    ("RDB$SYSTEM_PRIVILEGES", 24, "GET_DBCRYPT_INFO"),
    ("RDB$SYSTEM_PRIVILEGES", 25, "MODIFY_EXT_CONN_POOL"),
    ("RDB$SYSTEM_PRIVILEGES", 26, "REPLICATE_INTO_DATABASE"),
    ("RDB$SYSTEM_PRIVILEGES", 27, "PROFILE_ANY_ATTACHMENT"),
    // --- MON$CRYPT_STATE ---
    ("MON$CRYPT_STATE", 0, "NOT ENCRYPTED"),
    ("MON$CRYPT_STATE", 1, "ENCRYPTED"),
    ("MON$CRYPT_STATE", 2, "DECRYPT IN PROGRESS"),
    ("MON$CRYPT_STATE", 3, "ENCRYPT IN PROGRESS"),
    // --- MON$REPLICA_MODE ---
    ("MON$REPLICA_MODE", 0, "NONE"),
    ("MON$REPLICA_MODE", 1, "READ-ONLY"),
    ("MON$REPLICA_MODE", 2, "READ-WRITE"),
];

/// (name, id, max bytes): `IntlManager::defaultCharSets`
/// (IntlManager.cpp:105), the `RDB$CHARACTER_SETS` rows
/// `store_intlnames` writes (ini.epp:1788-1820) and the middle third
/// of the `RDB$TYPES` stores (ini.epp:873-888). The `UTF16`/`UTF32`
/// rows are `#ifdef`'d out upstream and absent here too.
pub const SYS_CHARSETS: &[(&str, i64, i64)] = &[
    ("NONE", 0, 1),
    ("OCTETS", 1, 1),
    ("ASCII", 2, 1),
    ("UNICODE_FSS", 3, 3),
    ("UTF8", 4, 4),
    ("SJIS_0208", 5, 2),
    ("EUCJ_0208", 6, 2),
    ("DOS437", 10, 1),
    ("DOS850", 11, 1),
    ("DOS865", 12, 1),
    ("ISO8859_1", 21, 1),
    ("ISO8859_2", 22, 1),
    ("ISO8859_3", 23, 1),
    ("ISO8859_4", 34, 1),
    ("ISO8859_5", 35, 1),
    ("ISO8859_6", 36, 1),
    ("ISO8859_7", 37, 1),
    ("ISO8859_8", 38, 1),
    ("ISO8859_9", 39, 1),
    ("ISO8859_13", 40, 1),
    ("DOS852", 45, 1),
    ("DOS857", 46, 1),
    ("DOS860", 13, 1),
    ("DOS861", 47, 1),
    ("DOS863", 14, 1),
    ("CYRL", 50, 1),
    ("DOS737", 9, 1),
    ("DOS775", 15, 1),
    ("DOS858", 16, 1),
    ("DOS862", 17, 1),
    ("DOS864", 18, 1),
    ("DOS866", 48, 1),
    ("DOS869", 49, 1),
    ("WIN1250", 51, 1),
    ("WIN1251", 52, 1),
    ("WIN1252", 53, 1),
    ("WIN1253", 54, 1),
    ("WIN1254", 55, 1),
    ("NEXT", 19, 1),
    ("WIN1255", 58, 1),
    ("WIN1256", 59, 1),
    ("WIN1257", 60, 1),
    ("KSC_5601", 44, 2),
    ("BIG_5", 56, 2),
    ("GB_2312", 57, 2),
    ("KOI8R", 63, 1),
    ("KOI8U", 64, 1),
    ("WIN1258", 65, 1),
    ("TIS620", 66, 1),
    ("GBK", 67, 2),
    ("CP943C", 68, 2),
    ("GB18030", 69, 4),
];

/// (alias, charset id): `IntlManager::defaultCharSetAliases`
/// (IntlManager.cpp:166), the last `RDB$TYPES` stores
/// (ini.epp:890-904). Aliases get `RDB$TYPES` rows only - no
/// `RDB$CHARACTER_SETS` row, class or privilege.
pub const SYS_CHARSET_ALIASES: &[(&str, i64)] = &[
    ("BINARY", 1),
    ("USASCII", 2),
    ("ASCII7", 2),
    ("UTF_FSS", 3),
    ("SQL_TEXT", 3),
    ("UTF-8", 4),
    ("SJIS", 5),
    ("EUCJ", 6),
    ("DOS_437", 10),
    ("DOS_850", 11),
    ("DOS_865", 12),
    ("ISO88591", 21),
    ("LATIN1", 21),
    ("ANSI", 21),
    ("ISO88592", 22),
    ("LATIN2", 22),
    ("ISO-8859-2", 22),
    ("ISO88593", 23),
    ("LATIN3", 23),
    ("ISO-8859-3", 23),
    ("ISO88594", 34),
    ("LATIN4", 34),
    ("ISO-8859-4", 34),
    ("ISO88595", 35),
    ("ISO-8859-5", 35),
    ("ISO88596", 36),
    ("ISO-8859-6", 36),
    ("ISO88597", 37),
    ("ISO-8859-7", 37),
    ("ISO88598", 38),
    ("ISO-8859-8", 38),
    ("ISO88599", 39),
    ("LATIN5", 39),
    ("ISO-8859-9", 39),
    ("ISO885913", 40),
    ("LATIN7", 40),
    ("ISO-8859-13", 40),
    ("DOS_852", 45),
    ("DOS_857", 46),
    ("DOS_860", 13),
    ("DOS_861", 47),
    ("DOS_863", 14),
    ("DOS_737", 9),
    ("DOS_775", 15),
    ("DOS_858", 16),
    ("DOS_862", 17),
    ("DOS_864", 18),
    ("DOS_866", 48),
    ("DOS_869", 49),
    ("WIN_1250", 51),
    ("WIN_1251", 52),
    ("WIN_1252", 53),
    ("WIN_1253", 54),
    ("WIN_1254", 55),
    ("WIN_1255", 58),
    ("WIN_1256", 59),
    ("WIN_1257", 60),
    ("WIN_1258", 65),
    ("KSC5601", 44),
    ("DOS_949", 44),
    ("WIN_949", 44),
    ("BIG5", 56),
    ("DOS_950", 56),
    ("WIN_950", 56),
    ("GB2312", 57),
    ("DOS_936", 57),
    ("WIN_936", 57),
];

/// One `IntlManager::defaultCollations` entry
/// (IntlManager.cpp:242) with the `RDB$SPECIFIC_ATTRIBUTES` string
/// the engine actually stored: the table literal where the file
/// agrees (4 rows), the ICU-resolved string where
/// `setupCollationAttributes` (IntlManager.cpp:732) computed one
/// (7 rows, marked - the reference ICU is 74.2, collation version
/// 153.121). Storing the computed strings is the slice's one
/// intl fold: resolving them needs the live ICU module.
pub struct SysCollation {
    pub name: &'static str,
    pub cs_id: i64,
    pub coll_id: i64,
    pub attrs: i64,
    pub base: Option<&'static str>,
    pub specific: Option<&'static str>,
}

pub const SYS_COLLATIONS: &[SysCollation] = &[
    SysCollation { name: "NONE", cs_id: 0, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "OCTETS", cs_id: 1, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ASCII", cs_id: 2, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "UNICODE_FSS", cs_id: 3, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "UTF8", cs_id: 4, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "UCS_BASIC", cs_id: 4, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "UNICODE", cs_id: 4, coll_id: 2, attrs: 1, base: None, specific: Some("COLL-VERSION=153.121;ICU-VERSION=74.2") }, // ICU-resolved (table NULL)
    SysCollation { name: "UNICODE_CI", cs_id: 4, coll_id: 3, attrs: 3, base: Some("UNICODE"), specific: Some("COLL-VERSION=153.121;ICU-VERSION=74.2") }, // ICU-resolved (table NULL)
    SysCollation { name: "UNICODE_CI_AI", cs_id: 4, coll_id: 4, attrs: 7, base: Some("UNICODE"), specific: Some("COLL-VERSION=153.121;ICU-VERSION=74.2") }, // ICU-resolved (table NULL)
    SysCollation { name: "SJIS_0208", cs_id: 5, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "EUCJ_0208", cs_id: 6, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS437", cs_id: 10, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_ASCII", cs_id: 10, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_INTL", cs_id: 10, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_SWEDFIN", cs_id: 10, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_DEU437", cs_id: 10, coll_id: 4, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_ESP437", cs_id: 10, coll_id: 5, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_FIN437", cs_id: 10, coll_id: 6, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_FRA437", cs_id: 10, coll_id: 7, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_ITA437", cs_id: 10, coll_id: 8, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_NLD437", cs_id: 10, coll_id: 9, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_SVE437", cs_id: 10, coll_id: 10, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_UK437", cs_id: 10, coll_id: 11, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_US437", cs_id: 10, coll_id: 12, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS850", cs_id: 11, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_FRC850", cs_id: 11, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_DEU850", cs_id: 11, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_ESP850", cs_id: 11, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_FRA850", cs_id: 11, coll_id: 4, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_ITA850", cs_id: 11, coll_id: 5, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_NLD850", cs_id: 11, coll_id: 6, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_PTB850", cs_id: 11, coll_id: 7, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_SVE850", cs_id: 11, coll_id: 8, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_UK850", cs_id: 11, coll_id: 9, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_US850", cs_id: 11, coll_id: 10, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS865", cs_id: 12, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_NORDAN4", cs_id: 12, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_DAN865", cs_id: 12, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_NOR865", cs_id: 12, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_1", cs_id: 21, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DA_DA", cs_id: 21, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DU_NL", cs_id: 21, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "FI_FI", cs_id: 21, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "FR_FR", cs_id: 21, coll_id: 4, attrs: 1, base: None, specific: None },
    SysCollation { name: "FR_CA", cs_id: 21, coll_id: 5, attrs: 1, base: None, specific: None },
    SysCollation { name: "DE_DE", cs_id: 21, coll_id: 6, attrs: 1, base: None, specific: None },
    SysCollation { name: "IS_IS", cs_id: 21, coll_id: 7, attrs: 1, base: None, specific: None },
    SysCollation { name: "IT_IT", cs_id: 21, coll_id: 8, attrs: 1, base: None, specific: None },
    SysCollation { name: "NO_NO", cs_id: 21, coll_id: 9, attrs: 1, base: None, specific: None },
    SysCollation { name: "ES_ES", cs_id: 21, coll_id: 10, attrs: 1, base: None, specific: Some("DISABLE-COMPRESSIONS=1;SPECIALS-FIRST=1") },
    SysCollation { name: "SV_SV", cs_id: 21, coll_id: 11, attrs: 1, base: None, specific: None },
    SysCollation { name: "EN_UK", cs_id: 21, coll_id: 12, attrs: 1, base: None, specific: None },
    SysCollation { name: "EN_US", cs_id: 21, coll_id: 14, attrs: 1, base: None, specific: None },
    SysCollation { name: "PT_PT", cs_id: 21, coll_id: 15, attrs: 1, base: None, specific: None },
    SysCollation { name: "PT_BR", cs_id: 21, coll_id: 16, attrs: 7, base: None, specific: None },
    SysCollation { name: "ES_ES_CI_AI", cs_id: 21, coll_id: 17, attrs: 7, base: None, specific: Some("DISABLE-COMPRESSIONS=1;SPECIALS-FIRST=1") },
    SysCollation { name: "FR_FR_CI_AI", cs_id: 21, coll_id: 18, attrs: 7, base: Some("FR_FR"), specific: Some("SPECIALS-FIRST=1") },
    SysCollation { name: "FR_CA_CI_AI", cs_id: 21, coll_id: 19, attrs: 7, base: Some("FR_CA"), specific: Some("SPECIALS-FIRST=1") },
    SysCollation { name: "ISO8859_2", cs_id: 22, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "CS_CZ", cs_id: 22, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO_HUN", cs_id: 22, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO_PLK", cs_id: 22, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_3", cs_id: 23, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_4", cs_id: 34, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_5", cs_id: 35, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_6", cs_id: 36, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_7", cs_id: 37, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_8", cs_id: 38, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_9", cs_id: 39, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "ISO8859_13", cs_id: 40, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "LT_LT", cs_id: 40, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS852", cs_id: 45, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_CSY", cs_id: 45, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_PLK", cs_id: 45, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_SLO", cs_id: 45, coll_id: 4, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_CSY", cs_id: 45, coll_id: 5, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_PLK", cs_id: 45, coll_id: 6, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_HUN", cs_id: 45, coll_id: 7, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_SLO", cs_id: 45, coll_id: 8, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS857", cs_id: 46, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_TRK", cs_id: 46, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS860", cs_id: 13, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_PTG860", cs_id: 13, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS861", cs_id: 47, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_ISL", cs_id: 47, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS863", cs_id: 14, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_FRC863", cs_id: 14, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "CYRL", cs_id: 50, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DB_RUS", cs_id: 50, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "PDOX_CYRL", cs_id: 50, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS737", cs_id: 9, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS775", cs_id: 15, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS858", cs_id: 16, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS862", cs_id: 17, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS864", cs_id: 18, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS866", cs_id: 48, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "DOS869", cs_id: 49, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1250", cs_id: 51, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_CSY", cs_id: 51, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_HUNDC", cs_id: 51, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_PLK", cs_id: 51, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_SLOV", cs_id: 51, coll_id: 4, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_HUN", cs_id: 51, coll_id: 5, attrs: 1, base: None, specific: None },
    SysCollation { name: "BS_BA", cs_id: 51, coll_id: 6, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN_CZ", cs_id: 51, coll_id: 7, attrs: 3, base: None, specific: None },
    SysCollation { name: "WIN_CZ_CI_AI", cs_id: 51, coll_id: 8, attrs: 7, base: None, specific: None },
    SysCollation { name: "WIN1251", cs_id: 52, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_CYRL", cs_id: 52, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1251_UA", cs_id: 52, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1252", cs_id: 53, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_INTL", cs_id: 53, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_INTL850", cs_id: 53, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_NORDAN4", cs_id: 53, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_SPAN", cs_id: 53, coll_id: 4, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_SWEDFIN", cs_id: 53, coll_id: 5, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN_PTBR", cs_id: 53, coll_id: 6, attrs: 7, base: None, specific: None },
    SysCollation { name: "WIN1253", cs_id: 54, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_GREEK", cs_id: 54, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1254", cs_id: 55, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "PXW_TURK", cs_id: 55, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "NEXT", cs_id: 19, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "NXT_US", cs_id: 19, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "NXT_DEU", cs_id: 19, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "NXT_FRA", cs_id: 19, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "NXT_ITA", cs_id: 19, coll_id: 4, attrs: 1, base: None, specific: None },
    SysCollation { name: "NXT_ESP", cs_id: 19, coll_id: 5, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1255", cs_id: 58, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1256", cs_id: 59, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1257", cs_id: 60, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1257_EE", cs_id: 60, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1257_LT", cs_id: 60, coll_id: 2, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1257_LV", cs_id: 60, coll_id: 3, attrs: 1, base: None, specific: None },
    SysCollation { name: "KSC_5601", cs_id: 44, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "KSC_DICTIONARY", cs_id: 44, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "BIG_5", cs_id: 56, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "GB_2312", cs_id: 57, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "KOI8R", cs_id: 63, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "KOI8R_RU", cs_id: 63, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "KOI8U", cs_id: 64, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "KOI8U_UA", cs_id: 64, coll_id: 1, attrs: 1, base: None, specific: None },
    SysCollation { name: "WIN1258", cs_id: 65, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "TIS620", cs_id: 66, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "TIS620_UNICODE", cs_id: 66, coll_id: 1, attrs: 1, base: None, specific: Some("COLL-VERSION=153.121;ICU-VERSION=74.2") }, // ICU-resolved (table NULL)
    SysCollation { name: "GBK", cs_id: 67, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "GBK_UNICODE", cs_id: 67, coll_id: 1, attrs: 1, base: None, specific: Some("COLL-VERSION=153.121;ICU-VERSION=74.2") }, // ICU-resolved (table NULL)
    SysCollation { name: "CP943C", cs_id: 68, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "CP943C_UNICODE", cs_id: 68, coll_id: 1, attrs: 1, base: None, specific: Some("COLL-VERSION=153.121;ICU-VERSION=74.2") }, // ICU-resolved (table NULL)
    SysCollation { name: "GB18030", cs_id: 69, coll_id: 0, attrs: 1, base: None, specific: None },
    SysCollation { name: "GB18030_UNICODE", cs_id: 69, coll_id: 1, attrs: 1, base: None, specific: Some("COLL-VERSION=153.121;ICU-VERSION=74.2") }, // ICU-resolved (table NULL)
];

/// A system routine parameter: the `SystemProcedureParameter` /
/// `SystemFunctionParameter` triple (name, global field, nullable)
/// plus the optional default (inner text and inner BLR - the store
/// wraps them as `store_packages` does). `NULL_FLAG` stores
/// `!nullable` (ini.epp).
pub struct SysParam {
    pub name: &'static str,
    pub source: &'static str,
    pub nullable: bool,
    pub default_text: Option<&'static str>,
    pub default_blr: Option<&'static [u8]>,
}

/// A system procedure: `prc_selectable` (1) or `prc_executable` (2)
/// (constants.h:263) with its input and output parameters in
/// `PARAMETER_NUMBER` order.
pub struct SysProcedure {
    pub name: &'static str,
    pub prc_type: i64,
    pub inputs: &'static [SysParam],
    pub outputs: &'static [SysParam],
}

/// A system function: return type plus the position-1..n parameters
/// (`ARGUMENT_NAME` NULL on position 0, the return slot).
pub struct SysFunction {
    pub name: &'static str,
    pub ret_source: &'static str,
    pub ret_nullable: bool,
    pub params: &'static [SysParam],
}

/// A system constant: the value source verbatim plus the inner value
/// BLR (`blr_version5`..`blr_eoc` wrapped at store).
pub struct SysConstant {
    pub name: &'static str,
    pub source: &'static str,
    pub value_source: &'static str,
    pub value_blr: &'static [u8],
}

/// A system package in `SystemPackage::get()` order
/// (SystemPackages.cpp:41-44): `RDB$PACKAGES` id is the 1-based
/// position, procedures and functions take `RDB$PROCEDURES` /
/// `RDB$FUNCTIONS` generator ids in walk order.
pub struct SysPackage {
    pub name: &'static str,
    pub procedures: &'static [SysProcedure],
    pub functions: &'static [SysFunction],
    pub constants: &'static [SysConstant],
}

pub const SYS_PACKAGES: &[SysPackage] = &[
    SysPackage { name: "RDB$TIME_ZONE_UTIL",
        procedures: &[
            SysProcedure { name: "TRANSITIONS", prc_type: 1,
                inputs: &[
                    SysParam { name: "RDB$TIME_ZONE_NAME", source: "RDB$TIME_ZONE_NAME", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "RDB$FROM_TIMESTAMP", source: "RDB$TIMESTAMP_TZ", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "RDB$TO_TIMESTAMP", source: "RDB$TIMESTAMP_TZ", nullable: false,
                        default_text: None, default_blr: None },
                ],
                outputs: &[
                    SysParam { name: "RDB$START_TIMESTAMP", source: "RDB$TIMESTAMP_TZ", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "RDB$END_TIMESTAMP", source: "RDB$TIMESTAMP_TZ", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "RDB$ZONE_OFFSET", source: "RDB$TIME_ZONE_OFFSET", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "RDB$DST_OFFSET", source: "RDB$TIME_ZONE_OFFSET", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "RDB$EFFECTIVE_OFFSET", source: "RDB$TIME_ZONE_OFFSET", nullable: false,
                        default_text: None, default_blr: None },
                ],
            },
        ],
        functions: &[
            SysFunction { name: "DATABASE_VERSION", ret_source: "RDB$DBTZ_VERSION", ret_nullable: false,
                params: &[
                ],
            },
        ],
        constants: &[
        ],
    },
    SysPackage { name: "RDB$PROFILER",
        procedures: &[
            SysProcedure { name: "CANCEL_SESSION", prc_type: 2,
                inputs: &[
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
                outputs: &[
                ],
            },
            SysProcedure { name: "DISCARD", prc_type: 2,
                inputs: &[
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
                outputs: &[
                ],
            },
            SysProcedure { name: "FINISH_SESSION", prc_type: 2,
                inputs: &[
                    SysParam { name: "FLUSH", source: "RDB$BOOLEAN", nullable: false,
                        default_text: Some("true"), default_blr: Some(&[0x15, 0x17, 0x01]) },
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
                outputs: &[
                ],
            },
            SysProcedure { name: "FLUSH", prc_type: 2,
                inputs: &[
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
                outputs: &[
                ],
            },
            SysProcedure { name: "PAUSE_SESSION", prc_type: 2,
                inputs: &[
                    SysParam { name: "FLUSH", source: "RDB$BOOLEAN", nullable: false,
                        default_text: Some("false"), default_blr: Some(&[0x15, 0x17, 0x00]) },
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
                outputs: &[
                ],
            },
            SysProcedure { name: "RESUME_SESSION", prc_type: 2,
                inputs: &[
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
                outputs: &[
                ],
            },
            SysProcedure { name: "SET_FLUSH_INTERVAL", prc_type: 2,
                inputs: &[
                    SysParam { name: "FLUSH_INTERVAL", source: "RDB$SECONDS_INTERVAL", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
                outputs: &[
                ],
            },
        ],
        functions: &[
            SysFunction { name: "START_SESSION", ret_source: "RDB$PROFILE_SESSION_ID", ret_nullable: false,
                params: &[
                    SysParam { name: "DESCRIPTION", source: "RDB$SHORT_DESCRIPTION", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                    SysParam { name: "FLUSH_INTERVAL", source: "RDB$SECONDS_INTERVAL", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                    SysParam { name: "ATTACHMENT_ID", source: "RDB$ATTACHMENT_ID", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                    SysParam { name: "PLUGIN_NAME", source: "RDB$FILE_NAME2", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                    SysParam { name: "PLUGIN_OPTIONS", source: "RDB$SHORT_DESCRIPTION", nullable: true,
                        default_text: Some("null"), default_blr: Some(&[0x2d]) },
                ],
            },
        ],
        constants: &[
        ],
    },
    SysPackage { name: "RDB$BLOB_UTIL",
        procedures: &[
            SysProcedure { name: "CANCEL_BLOB", prc_type: 2,
                inputs: &[
                    SysParam { name: "BLOB", source: "RDB$BLOB", nullable: false,
                        default_text: None, default_blr: None },
                ],
                outputs: &[
                ],
            },
            SysProcedure { name: "CLOSE_HANDLE", prc_type: 2,
                inputs: &[
                    SysParam { name: "HANDLE", source: "RDB$BLOB_UTIL_HANDLE", nullable: false,
                        default_text: None, default_blr: None },
                ],
                outputs: &[
                ],
            },
        ],
        functions: &[
            SysFunction { name: "IS_WRITABLE", ret_source: "RDB$BOOLEAN", ret_nullable: false,
                params: &[
                    SysParam { name: "BLOB", source: "RDB$BLOB", nullable: false,
                        default_text: None, default_blr: None },
                ],
            },
            SysFunction { name: "NEW_BLOB", ret_source: "RDB$BLOB", ret_nullable: false,
                params: &[
                    SysParam { name: "SEGMENTED", source: "RDB$BOOLEAN", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "TEMP_STORAGE", source: "RDB$BOOLEAN", nullable: false,
                        default_text: None, default_blr: None },
                ],
            },
            SysFunction { name: "OPEN_BLOB", ret_source: "RDB$BLOB_UTIL_HANDLE", ret_nullable: false,
                params: &[
                    SysParam { name: "BLOB", source: "RDB$BLOB", nullable: false,
                        default_text: None, default_blr: None },
                ],
            },
            SysFunction { name: "SEEK", ret_source: "RDB$INTEGER", ret_nullable: false,
                params: &[
                    SysParam { name: "HANDLE", source: "RDB$BLOB_UTIL_HANDLE", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "MODE", source: "RDB$INTEGER", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "OFFSET", source: "RDB$INTEGER", nullable: false,
                        default_text: None, default_blr: None },
                ],
            },
            SysFunction { name: "READ_DATA", ret_source: "RDB$VARBINARY_MAX", ret_nullable: true,
                params: &[
                    SysParam { name: "HANDLE", source: "RDB$BLOB_UTIL_HANDLE", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "LENGTH", source: "RDB$INTEGER", nullable: true,
                        default_text: None, default_blr: None },
                ],
            },
        ],
        constants: &[
            SysConstant { name: "FROM_BEGIN", source: "RDB$INTEGER", value_source: "0", value_blr: &[0x15, 0x07, 0x00, 0x00, 0x00] },
            SysConstant { name: "FROM_CURRENT", source: "RDB$INTEGER", value_source: "1", value_blr: &[0x15, 0x07, 0x00, 0x01, 0x00] },
            SysConstant { name: "FROM_END", source: "RDB$INTEGER", value_source: "2", value_blr: &[0x15, 0x07, 0x00, 0x02, 0x00] },
        ],
    },
    SysPackage { name: "RDB$SQL",
        procedures: &[
            SysProcedure { name: "EXPLAIN", prc_type: 1,
                inputs: &[
                    SysParam { name: "SQL", source: "RDB$DESCRIPTION", nullable: false,
                        default_text: None, default_blr: None },
                ],
                outputs: &[
                    SysParam { name: "PLAN_LINE", source: "RDB$INTEGER", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "RECORD_SOURCE_ID", source: "RDB$GENERATOR_VALUE", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "PARENT_RECORD_SOURCE_ID", source: "RDB$GENERATOR_VALUE", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "LEVEL", source: "RDB$INTEGER", nullable: false,
                        default_text: None, default_blr: None },
                    SysParam { name: "OBJECT_TYPE", source: "RDB$OBJECT_TYPE", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "SCHEMA_NAME", source: "RDB$SCHEMA_NAME", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "PACKAGE_NAME", source: "RDB$PACKAGE_NAME", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "OBJECT_NAME", source: "RDB$RELATION_NAME", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "ALIAS", source: "RDB$SHORT_DESCRIPTION", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "CARDINALITY", source: "RDB$STATISTICS", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "RECORD_LENGTH", source: "RDB$INTEGER", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "KEY_LENGTH", source: "RDB$INTEGER", nullable: true,
                        default_text: None, default_blr: None },
                    SysParam { name: "ACCESS_PATH", source: "RDB$DESCRIPTION", nullable: false,
                        default_text: None, default_blr: None },
                ],
            },
            SysProcedure { name: "PARSE_UNQUALIFIED_NAMES", prc_type: 1,
                inputs: &[
                    SysParam { name: "NAMES", source: "RDB$TEXT_MAX", nullable: true,
                        default_text: None, default_blr: None },
                ],
                outputs: &[
                    SysParam { name: "NAME", source: "RDB$RELATION_NAME", nullable: false,
                        default_text: None, default_blr: None },
                ],
            },
        ],
        functions: &[
        ],
        constants: &[
        ],
    },
];

// ---------------------------------------------------------------------------
// Small tables
// ---------------------------------------------------------------------------

/// (object type, DDL security name, schema-bound): `isDdlObject` +
/// `getDdlSecurityName` (obj.h:120-200) in the `DdlSecurity::store`
/// loop order (`obj_database + 1 .. obj_type_MAX`, ini.epp:565).
/// `obj_tablespace` (35), `obj_index_condition` (37) and `obj_schema`
/// (38) are not DDL objects; `obj_database` (21) is skipped by the
/// loop and lands separately as `SQL$DATABASE`.
pub const DDL_OBJECTS: &[(i64, &str, bool)] = &[
    (22, "SQL$TABLES", true),
    (23, "SQL$VIEWS", true),
    (24, "SQL$PROCEDURES", true),
    (25, "SQL$FUNCTIONS", true),
    (26, "SQL$PACKAGES", true),
    (27, "SQL$GENERATORS", true),
    (28, "SQL$DOMAINS", true),
    (29, "SQL$EXCEPTIONS", true),
    (30, "SQL$ROLES", false),
    (31, "SQL$CHARSETS", true),
    (32, "SQL$COLLATIONS", true),
    (33, "SQL$FILTERS", false),
    (34, "SQL$JOBS", false),
    (36, "SQL$TABLESPACES", false),
    (39, "SQL$SCHEMAS", false),
];

/// The DDL privilege letters `storeGrant` loops over, in loop order
/// (`ALL_DDL_PRIVILEGES`, dyn.h:39).
pub const DDL_PRIVILEGES: &str = "CLO";

/// The package privilege letters `storePrivileges` loops over, in
/// loop order (`SYSTEM_PACKAGE_PRIVILEGES`, dyn.h:40).
pub const PACKAGE_PRIVILEGES: &str = "XU";

/// (privilege-user, relation) for the three additional `storeGrant` +
/// `GRANT_privileges` pairs, in `INI_format` order (ini.epp:941-956).
/// The users are decimal system-privilege numbers (`USE_NBACKUP_UTILITY`
/// = 4, `CREATE_USER_TYPES` = 3, `GRANT_REVOKE_ANY_DDL_RIGHT` = 22,
/// SystemPrivileges.h) with `RDB$USER_TYPE = obj_privilege` (20).
pub const ADDITIONAL_GRANTS: &[(&str, &str)] = &[
    ("4", "RDB$BACKUP_HISTORY"),
    ("3", "RDB$TYPES"),
    ("22", "RDB$DB_CREATORS"),
];

/// The all-privileges letters for relations, in `storeGrant` loop
/// order (`ALL_PRIVILEGES`, dyn.h:35).
pub const RELATION_PRIVILEGES: &str = "SIUDR";

/// The first `SQL$n` class of the intl range: `store_intlnames`
/// consumes `250..=450`, the gap slice 4 reserved.
pub const INTL_FIRST_CLASS: u32 = 250;

/// The system role `store_admin_role` stores (constants.h:94).
pub const ADMIN_ROLE: &str = "RDB$ADMIN";

/// The default publication `store_default_pub` stores (constants.h:167).
pub const DEFAULT_PUBLICATION: &str = "RDB$DEFAULT";

/// The owner's system-privilege mask: 8 `0xff` bytes
/// (`INI_owner_privileges`, ini.epp:1182-1185). Not valid UTF-8, so it
/// stores through `Cell::Raw`, never `Cell::Text`.
pub const OWNER_PRIVILEGES: [u8; 8] = [0xff; 8];

// ---------------------------------------------------------------------------
// Row writers
// ---------------------------------------------------------------------------

fn col(rel_id: u16, name: &str) -> usize {
    rel_col(rel_id, name)
}

/// Insert one row and key it into every covering tree - the unit
/// every slice-6 store is built from (the `IDX_store` half slice 5's
/// contract requires). The recno comes from the insert's (page,
/// slot) via the page's `dpg_sequence`, as the backfill computes it.
fn store_row(
    file: &mut Image,
    page_size: usize,
    rel_id: u16,
    image: &[u8],
    descs: &[Descriptor],
) -> Result<(), String> {
    let outcome = dml::insert_record_system(file, page_size, rel_id, 0, image)?;
    let page = crate::page_at(file, page_size, outcome.page_no).ok_or("inserted page range")?;
    let dp = DataPage::decode(page).ok_or("inserted page decode")?;
    let recno = dp.sequence as u64 * max_recs_per_dp(page_size) + u64::from(outcome.slot);
    let values = decode_record(image, descs);
    maintain_row(file, page_size, rel_id, recno, &values, descs)?;
    Ok(())
}

/// One `RDB$USER_PRIVILEGES` row, keyed into the covering trees -
/// slice 4's writer plus the maintenance the post-build position
/// needs.
fn store_priv_maintained(file: &mut Image, page_size: usize, p: &Priv) -> Result<(), String> {
    let rel = rel_by_name("RDB$USER_PRIVILEGES");
    let descs = descriptors_for(rel);
    let image = encode_image(&descs, &priv_cells(rel, p));
    store_row(file, page_size, 18, &image, &descs)
}

/// One `RDB$SECURITY_CLASSES` row, keyed into `RDB$INDEX_7` - slice
/// 4's `store_class` plus the maintenance the post-build position
/// needs. ACL blobs: subtype 3, charset 1, as slice 4 probed.
fn store_class(file: &mut Image, page_size: usize, name: &str, acl: &[u8]) -> Result<(), String> {
    let num = dml::insert_blob(file, page_size, 9, &[acl.to_vec()], 3)?;
    let rel = rel_by_name("RDB$SECURITY_CLASSES");
    let descs = descriptors_for(rel);
    let image = encode_image(
        &descs,
        &[
            (col(9, "RDB$SECURITY_CLASS"), Cell::Text(name)),
            (col(9, "RDB$ACL"), Cell::BlobId(9, num)),
        ],
    );
    store_row(file, page_size, 9, &image, &descs)
}

/// The 298 `RDB$TYPES` rows: the `types[]` array, then the character
/// sets, then the aliases (ini.epp:856-904). No classes, no
/// privileges, `RDB$DESCRIPTION` NULL throughout, system flag 1.
pub fn store_types(file: &mut Image, page_size: usize) -> Result<(), String> {
    let rel = rel_by_name("RDB$TYPES");
    let descs = descriptors_for(rel);
    let (c_field, c_type, c_name, c_flag) =
        (col(11, "RDB$FIELD_NAME"), col(11, "RDB$TYPE"), col(11, "RDB$TYPE_NAME"), col(11, "RDB$SYSTEM_FLAG"));
    let mut rows: Vec<(&str, i64, &str)> = Vec::with_capacity(298);
    rows.extend(SYS_TYPES.iter().copied());
    for (name, id, _) in SYS_CHARSETS {
        rows.push(("RDB$CHARACTER_SET_NAME", *id, name));
    }
    for (alias, id) in SYS_CHARSET_ALIASES {
        rows.push(("RDB$CHARACTER_SET_NAME", *id, alias));
    }
    for (field, value, name) in rows {
        let image = encode_image(
            &descs,
            &[
                (c_field, Cell::Text(field)),
                (c_type, Cell::Int(value)),
                (c_name, Cell::Text(name)),
                (c_flag, Cell::Int(1)),
            ],
        );
        store_row(file, page_size, 11, &image, &descs)?;
    }
    Ok(())
}

/// `store_intlnames` (ini.epp:1781-1878): the 52 character sets and
/// 149 collations with their `SQL$250..450` classes and USAGE grants.
/// The class numbers are explicit - this is the replay of the range
/// slice 4 reserved, and the count assert is the reservation check.
/// Fails unless the generators are stored first (`alloc` past 463:
/// 60 relations + 187 fields + 2 schemas + the 201 reserved + 13
/// generators), so the packages that follow start at 464.
pub fn store_intl(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &SecurityAlloc,
) -> Result<(), String> {
    assert_eq!(alloc.sec_current(), 463, "intl replay needs the generators stored first");
    let mut n = 0u32;
    let rel = rel_by_name("RDB$CHARACTER_SETS");
    let descs = descriptors_for(rel);
    for (name, id, max_bytes) in SYS_CHARSETS {
        let class = format!("SQL${}", INTL_FIRST_CLASS + n);
        store_class(file, page_size, &class, &nonrelation_acl(owner, false))?;
        let image = encode_image(
            &descs,
            &[
                (col(28, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                (col(28, "RDB$CHARACTER_SET_NAME"), Cell::Text(name)),
                (col(28, "RDB$DEFAULT_COLLATE_SCHEMA_NAME"), Cell::Text("SYSTEM")),
                (col(28, "RDB$DEFAULT_COLLATE_NAME"), Cell::Text(name)),
                (col(28, "RDB$CHARACTER_SET_ID"), Cell::Int(*id)),
                (col(28, "RDB$BYTES_PER_CHARACTER"), Cell::Int(*max_bytes)),
                (col(28, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
                (col(28, "RDB$OWNER_NAME"), Cell::Text(owner)),
                (col(28, "RDB$SECURITY_CLASS"), Cell::Text(&class)),
            ],
        );
        store_row(file, page_size, 28, &image, &descs)?;
        for (user, grant) in [(owner, 1), ("PUBLIC", 0)] {
            store_priv_maintained(
                file,
                page_size,
                &Priv { user, schema: Some("SYSTEM"), object: name, priv_c: "G", grant, user_type: 8, obj_type: 11, grantor: None, field: None },
            )?;
        }
        n += 1;
    }
    let rel = rel_by_name("RDB$COLLATIONS");
    let descs = descriptors_for(rel);
    for c in SYS_COLLATIONS {
        let class = format!("SQL${}", INTL_FIRST_CLASS + n);
        store_class(file, page_size, &class, &nonrelation_acl(owner, false))?;
        let mut cells = vec![
            (col(29, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
            (col(29, "RDB$COLLATION_NAME"), Cell::Text(c.name)),
            (col(29, "RDB$CHARACTER_SET_ID"), Cell::Int(c.cs_id)),
            (col(29, "RDB$COLLATION_ID"), Cell::Int(c.coll_id)),
            (col(29, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
            (col(29, "RDB$OWNER_NAME"), Cell::Text(owner)),
            (col(29, "RDB$SECURITY_CLASS"), Cell::Text(&class)),
            (col(29, "RDB$COLLATION_ATTRIBUTES"), Cell::Int(c.attrs)),
        ];
        if let Some(base) = c.base {
            cells.push((col(29, "RDB$BASE_COLLATION_NAME"), Cell::Text(base)));
        }
        if let Some(specific) = c.specific {
            let num = dml::insert_blob_cs(file, page_size, 29, &[specific.as_bytes().to_vec()], 1, 4)?;
            cells.push((col(29, "RDB$SPECIFIC_ATTRIBUTES"), Cell::BlobId(29, num)));
        }
        let image = encode_image(&descs, &cells);
        store_row(file, page_size, 29, &image, &descs)?;
        for (user, grant) in [(owner, 1), ("PUBLIC", 0)] {
            store_priv_maintained(
                file,
                page_size,
                &Priv { user, schema: Some("SYSTEM"), object: c.name, priv_c: "G", grant, user_type: 8, obj_type: 17, grantor: None, field: None },
            )?;
        }
        n += 1;
    }
    assert_eq!(n, INTL_CLASSES_RESERVED, "intl replay must consume exactly the reservation");
    Ok(())
}

/// A default (source, BLR) blob pair for a routine parameter: the
/// source is `"default " + text` (metadata text, subtype 1 charset
/// 4) and the value is `blr_version5 + inner + blr_eoc` (binary,
/// subtype 2 charset 1), as `store_packages` lays them down
/// (ini.epp:2038-2058, 2114-2134).
fn store_default_blobs(
    file: &mut Image,
    page_size: usize,
    rel_id: u16,
    text: &str,
    inner_blr: &[u8],
) -> Result<(u64, u64), String> {
    let source = format!("default {text}");
    let src_num = dml::insert_blob_cs(file, page_size, rel_id, &[source.as_bytes().to_vec()], 1, 4)?;
    let mut blr = Vec::with_capacity(inner_blr.len() + 2);
    blr.push(5); // blr_version5
    blr.extend_from_slice(inner_blr);
    blr.push(76); // blr_eoc
    let val_num = dml::insert_blob(file, page_size, rel_id, &[blr], 2)?;
    Ok((src_num, val_num))
}

/// `store_packages` (ini.epp:1968+): the 4 system packages with their
/// procedures, functions, arguments and constants, classes
/// `SQL$464..467` and `XU` privileges. Returns the consumed
/// `RDB$PACKAGES` / `RDB$PROCEDURES` / `RDB$FUNCTIONS` generator ids
/// for the end-value store.
pub fn store_packages(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &mut SecurityAlloc,
) -> Result<(i64, i64, i64), String> {
    let mut pkg_id = 0i64;
    let mut proc_id = 0i64;
    let mut func_id = 0i64;
    for (i, pkg) in SYS_PACKAGES.iter().enumerate() {
        let sec = alloc.next_sec();
        assert_eq!(sec, format!("SQL${}", 464 + i), "package classes must follow the intl replay");
        store_class(file, page_size, &sec, &nonrelation_acl(owner, true))?;
        pkg_id += 1;
        let image = encode_image(
            &descriptors_for(rel_by_name("RDB$PACKAGES")),
            &[
                (col(42, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                (col(42, "RDB$PACKAGE_NAME"), Cell::Text(pkg.name)),
                (col(42, "RDB$OWNER_NAME"), Cell::Text(owner)),
                (col(42, "RDB$SECURITY_CLASS"), Cell::Text(&sec)),
                (col(42, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
                (col(42, "RDB$VALID_BODY_FLAG"), Cell::Int(1)),
                (col(42, "RDB$PACKAGE_ID"), Cell::Int(pkg_id)),
            ],
        );
        store_row(file, page_size, 42, &image, &descriptors_for(rel_by_name("RDB$PACKAGES")))?;
        for (user, grant) in [(owner, 1), ("PUBLIC", 0)] {
            for priv_c in ["X", "U"] {
                assert!(PACKAGE_PRIVILEGES.contains(priv_c));
                store_priv_maintained(
                    file,
                    page_size,
                    &Priv { user, schema: Some("SYSTEM"), object: pkg.name, priv_c, grant, user_type: 8, obj_type: 18, grantor: None, field: None },
                )?;
            }
        }
        for proc in pkg.procedures {
            proc_id += 1;
            let image = encode_image(
                &descriptors_for(rel_by_name("RDB$PROCEDURES")),
                &[
                    (col(26, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                    (col(26, "RDB$PACKAGE_NAME"), Cell::Text(pkg.name)),
                    (col(26, "RDB$PROCEDURE_NAME"), Cell::Text(proc.name)),
                    (col(26, "RDB$OWNER_NAME"), Cell::Text(owner)),
                    (col(26, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
                    (col(26, "RDB$PROCEDURE_ID"), Cell::Int(proc_id)),
                    (col(26, "RDB$PROCEDURE_INPUTS"), Cell::Int(proc.inputs.len() as i64)),
                    (col(26, "RDB$PROCEDURE_OUTPUTS"), Cell::Int(proc.outputs.len() as i64)),
                    (col(26, "RDB$PROCEDURE_TYPE"), Cell::Int(proc.prc_type)),
                    (col(26, "RDB$PRIVATE_FLAG"), Cell::Int(0)),
                    (col(26, "RDB$VALID_BLR"), Cell::Int(1)),
                    (col(26, "RDB$ENGINE_NAME"), Cell::Text("SYSTEM")),
                ],
            );
            store_row(file, page_size, 26, &image, &descriptors_for(rel_by_name("RDB$PROCEDURES")))?;
            for (ptype, params) in [(0, proc.inputs), (1, proc.outputs)] {
                for (num, p) in params.iter().enumerate() {
                    let mut cells = vec![
                        (col(27, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                        (col(27, "RDB$PACKAGE_NAME"), Cell::Text(pkg.name)),
                        (col(27, "RDB$PROCEDURE_NAME"), Cell::Text(proc.name)),
                        (col(27, "RDB$PARAMETER_NAME"), Cell::Text(p.name)),
                        (col(27, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
                        (col(27, "RDB$PARAMETER_NUMBER"), Cell::Int(num as i64)),
                        (col(27, "RDB$PARAMETER_TYPE"), Cell::Int(ptype)),
                        (col(27, "RDB$PARAMETER_MECHANISM"), Cell::Int(0)),
                        (col(27, "RDB$NULL_FLAG"), Cell::Int(i64::from(!p.nullable))),
                        (col(27, "RDB$FIELD_SOURCE_SCHEMA_NAME"), Cell::Text("SYSTEM")),
                        (col(27, "RDB$FIELD_SOURCE"), Cell::Text(p.source)),
                    ];
                    if let (Some(text), Some(blr)) = (p.default_text, p.default_blr) {
                        let (src_num, val_num) = store_default_blobs(file, page_size, 27, text, blr)?;
                        cells.push((col(27, "RDB$DEFAULT_SOURCE"), Cell::BlobId(27, src_num)));
                        cells.push((col(27, "RDB$DEFAULT_VALUE"), Cell::BlobId(27, val_num)));
                    }
                    let image = encode_image(&descriptors_for(rel_by_name("RDB$PROCEDURE_PARAMETERS")), &cells);
                    store_row(file, page_size, 27, &image, &descriptors_for(rel_by_name("RDB$PROCEDURE_PARAMETERS")))?;
                }
            }
        }
        for fun in pkg.functions {
            func_id += 1;
            let image = encode_image(
                &descriptors_for(rel_by_name("RDB$FUNCTIONS")),
                &[
                    (col(14, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                    (col(14, "RDB$PACKAGE_NAME"), Cell::Text(pkg.name)),
                    (col(14, "RDB$FUNCTION_NAME"), Cell::Text(fun.name)),
                    (col(14, "RDB$OWNER_NAME"), Cell::Text(owner)),
                    (col(14, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
                    (col(14, "RDB$FUNCTION_ID"), Cell::Int(func_id)),
                    (col(14, "RDB$RETURN_ARGUMENT"), Cell::Int(0)),
                    (col(14, "RDB$PRIVATE_FLAG"), Cell::Int(0)),
                    (col(14, "RDB$VALID_BLR"), Cell::Int(1)),
                    (col(14, "RDB$ENGINE_NAME"), Cell::Text("SYSTEM")),
                ],
            );
            store_row(file, page_size, 14, &image, &descriptors_for(rel_by_name("RDB$FUNCTIONS")))?;
            let mut args: Vec<(Option<&str>, &str, bool, Option<&str>, Option<&[u8]>)> =
                vec![(None, fun.ret_source, fun.ret_nullable, None, None)];
            for p in fun.params {
                args.push((Some(p.name), p.source, p.nullable, p.default_text, p.default_blr));
            }
            for (pos, (name, source, nullable, text, blr)) in args.iter().enumerate() {
                let mut cells = vec![
                    (col(15, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                    (col(15, "RDB$PACKAGE_NAME"), Cell::Text(pkg.name)),
                    (col(15, "RDB$FUNCTION_NAME"), Cell::Text(fun.name)),
                    (col(15, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
                    (col(15, "RDB$ARGUMENT_POSITION"), Cell::Int(pos as i64)),
                    (col(15, "RDB$NULL_FLAG"), Cell::Int(i64::from(!nullable))),
                    (col(15, "RDB$FIELD_SOURCE_SCHEMA_NAME"), Cell::Text("SYSTEM")),
                    (col(15, "RDB$FIELD_SOURCE"), Cell::Text(source)),
                ];
                if let Some(name) = name {
                    cells.push((col(15, "RDB$ARGUMENT_NAME"), Cell::Text(name)));
                }
                if let (Some(text), Some(blr)) = (text, blr) {
                    let (src_num, val_num) = store_default_blobs(file, page_size, 15, text, blr)?;
                    cells.push((col(15, "RDB$DEFAULT_SOURCE"), Cell::BlobId(15, src_num)));
                    cells.push((col(15, "RDB$DEFAULT_VALUE"), Cell::BlobId(15, val_num)));
                }
                let image = encode_image(&descriptors_for(rel_by_name("RDB$FUNCTION_ARGUMENTS")), &cells);
                store_row(file, page_size, 15, &image, &descriptors_for(rel_by_name("RDB$FUNCTION_ARGUMENTS")))?;
            }
        }
        for c in pkg.constants {
            let src_num =
                dml::insert_blob_cs(file, page_size, 59, &[c.value_source.as_bytes().to_vec()], 1, 4)?;
            let mut blr = Vec::with_capacity(c.value_blr.len() + 2);
            blr.push(5);
            blr.extend_from_slice(c.value_blr);
            blr.push(76);
            let blr_num = dml::insert_blob(file, page_size, 59, &[blr], 2)?;
            let image = encode_image(
                &descriptors_for(rel_by_name("RDB$CONSTANTS")),
                &[
                    (col(59, "RDB$CONSTANT_NAME"), Cell::Text(c.name)),
                    (col(59, "RDB$PACKAGE_NAME"), Cell::Text(pkg.name)),
                    (col(59, "RDB$FIELD_SOURCE"), Cell::Text(c.source)),
                    (col(59, "RDB$FIELD_SOURCE_SCHEMA_NAME"), Cell::Text("SYSTEM")),
                    (col(59, "RDB$PRIVATE_FLAG"), Cell::Int(0)),
                    (col(59, "RDB$CONSTANT_BLR"), Cell::BlobId(59, blr_num)),
                    (col(59, "RDB$CONSTANT_SOURCE"), Cell::BlobId(59, src_num)),
                    (col(59, "RDB$SCHEMA_NAME"), Cell::Text("SYSTEM")),
                ],
            );
            store_row(file, page_size, 59, &image, &descriptors_for(rel_by_name("RDB$CONSTANTS")))?;
        }
    }
    Ok((pkg_id, proc_id, func_id))
}

/// `store_default_pub` (ini.epp:1442-1468): the single
/// `RDB$PUBLICATIONS` row. No class, no privileges.
pub fn store_publication(file: &mut Image, page_size: usize, owner: &str) -> Result<(), String> {
    let image = encode_image(
        &descriptors_for(rel_by_name("RDB$PUBLICATIONS")),
        &[
            (col(51, "RDB$PUBLICATION_NAME"), Cell::Text(DEFAULT_PUBLICATION)),
            (col(51, "RDB$OWNER_NAME"), Cell::Text(owner)),
            (col(51, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
            (col(51, "RDB$ACTIVE_FLAG"), Cell::Int(0)),
            (col(51, "RDB$AUTO_ENABLE"), Cell::Int(0)),
        ],
    );
    store_row(file, page_size, 51, &image, &descriptors_for(rel_by_name("RDB$PUBLICATIONS")))
}

/// `store_admin_role` (ini.epp:1420-1440): the `RDB$ADMIN` role with
/// class `SQL$468` and the `M` membership grants - to `SYSDBA` and,
/// unless the owner is `SYSDBA`, to the owner too, each with admin
/// option and the default-role `D` flag (`RoleSecurity`,
/// ini.epp:478-531).
pub fn store_admin_role(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &mut SecurityAlloc,
) -> Result<(), String> {
    let sec = alloc.next_sec();
    assert_eq!(sec, "SQL$468", "the admin role takes class 468");
    store_class(file, page_size, &sec, &role_acl(owner))?;
    let image = encode_image(
        &descriptors_for(rel_by_name("RDB$ROLES")),
        &[
            (col(31, "RDB$ROLE_NAME"), Cell::Text(ADMIN_ROLE)),
            (col(31, "RDB$OWNER_NAME"), Cell::Text(owner)),
            (col(31, "RDB$SECURITY_CLASS"), Cell::Text(&sec)),
            (col(31, "RDB$SYSTEM_FLAG"), Cell::Int(1)),
            (col(31, "RDB$SYSTEM_PRIVILEGES"), Cell::Raw(&OWNER_PRIVILEGES)),
        ],
    );
    store_row(file, page_size, 31, &image, &descriptors_for(rel_by_name("RDB$ROLES")))?;
    let mut users = vec!["SYSDBA"];
    if owner != "SYSDBA" {
        users.push(owner);
    }
    for user in users {
        store_priv_maintained(
            file,
            page_size,
            &Priv { user, schema: None, object: ADMIN_ROLE, priv_c: "M", grant: 2, user_type: 8, obj_type: 13, grantor: None, field: Some("D") },
        )?;
    }
    Ok(())
}

/// `DdlSecurity::store` (ini.epp:564-616): the `CLO` grants per DDL
/// object plus the `SQL$D<object>[<schema>]` classes and
/// `SQL$DATABASE`, all carrying the DDL ACL. Schema-bound objects
/// grant to `PUBLIC`-schema names with the owner as grantor and take
/// two classes; the rest grant unqualified and take one. No
/// generator is consumed (`addSecurityClass`, not
/// `storeSecurityClass`). The `RDB$DATABASE` patch at the end is a
/// no-op here: slice 4's fold already wrote `SQL$DATABASE`.
pub fn store_ddl_security(file: &mut Image, page_size: usize, owner: &str) -> Result<(), String> {
    for (obj, name, use_schema) in DDL_OBJECTS {
        for priv_c in ["C", "L", "O"] {
            assert!(DDL_PRIVILEGES.contains(priv_c));
            store_priv_maintained(
                file,
                page_size,
                &Priv {
                    user: owner,
                    schema: if *use_schema { Some("PUBLIC") } else { None },
                    object: name,
                    priv_c,
                    grant: 0,
                    user_type: 8,
                    obj_type: *obj,
                    grantor: if *use_schema { Some(owner) } else { None },
                    field: None,
                },
            )?;
        }
        if *use_schema {
            store_class(file, page_size, &format!("SQL$D{obj}PUBLIC"), &ddl_acl(owner))?;
            store_class(file, page_size, &format!("SQL$D{obj}SYSTEM"), &ddl_acl(owner))?;
        } else {
            store_class(file, page_size, &format!("SQL$D{obj}"), &ddl_acl(owner))?;
        }
    }
    store_class(file, page_size, "SQL$DATABASE", &ddl_acl(owner))?;
    Ok(())
}

/// The three additional `storeGrant` pairs (ini.epp:941-956):
/// `SIUDR` rows for the privilege-users on `RDB$BACKUP_HISTORY`,
/// `RDB$TYPES` and `RDB$DB_CREATORS`. The `GRANT_privileges` halves
/// need no replay: the 6 recomputed class ACLs were written final
/// where the classes were stored (slice 4's third fold - the
/// recompute's page is full by the time this runs).
pub fn store_additional_grants(file: &mut Image, page_size: usize) -> Result<(), String> {
    for (user, rel_name) in ADDITIONAL_GRANTS {
        for priv_c in ["S", "I", "U", "D", "R"] {
            assert!(RELATION_PRIVILEGES.contains(priv_c));
            store_priv_maintained(
                file,
                page_size,
                &Priv { user, schema: Some("SYSTEM"), object: rel_name, priv_c, grant: 0, user_type: 20, obj_type: 0, grantor: None, field: None },
            )?;
        }
    }
    Ok(())
}

/// The `DPM_gen_id` end values `INI_format` leaves behind: the hidden
/// generator (13 = the `generators[]` count, ini.epp:916), the class
/// and default counters straight off the allocator, and the
/// package/procedure/function ids the package store consumed.
/// Slot 13 (`RDB$RELATIONS` = 128) came with slice 5's skeleton and
/// is re-asserted, not rewritten.
pub fn store_generator_values(
    file: &mut Image,
    page_size: usize,
    alloc: &SecurityAlloc,
    proc_ids: i64,
    func_ids: i64,
    pkg_ids: i64,
) -> Result<(), String> {
    assert_eq!(crate::gen::read(file, page_size, 13), 128, "slice 5 owns RDB$RELATIONS = 128");
    assert_eq!(alloc.sec_current(), 468, "class counter must end at 468");
    assert_eq!(alloc.dflt_current(), 60, "default counter must end at 60");
    assert_eq!((pkg_ids, proc_ids, func_ids), (4, 12, 7), "package-tree generator consumption");
    crate::gen::write(file, page_size, 0, crate::catalog_rows::SYS_GENERATORS.len() as i64)?;
    crate::gen::write(file, page_size, 1, alloc.sec_current() as i64)?;
    crate::gen::write(file, page_size, 2, alloc.dflt_current() as i64)?;
    crate::gen::write(file, page_size, 3, proc_ids)?;
    crate::gen::write(file, page_size, 10, func_ids)?;
    crate::gen::write(file, page_size, 12, pkg_ids)?;
    Ok(())
}

/// The whole slice: types, intl, packages, publication, admin role,
/// DDL security, additional grants, generator end values - 298 + 52
/// + 149 + 4 + 12 + 36 + 7 + 21 + 3 + 1 + 1 rows, 232 security
/// classes, 480 privilege rows.
pub fn store_remaining_catalog(
    file: &mut Image,
    page_size: usize,
    owner: &str,
    alloc: &mut SecurityAlloc,
) -> Result<(), String> {
    store_types(file, page_size)?;
    store_intl(file, page_size, owner, alloc)?;
    let (pkg_ids, proc_ids, func_ids) = store_packages(file, page_size, owner, alloc)?;
    store_publication(file, page_size, owner)?;
    store_admin_role(file, page_size, owner, alloc)?;
    store_ddl_security(file, page_size, owner)?;
    store_additional_grants(file, page_size)?;
    store_generator_values(file, page_size, alloc, proc_ids, func_ids, pkg_ids)?;
    Ok(())
}

