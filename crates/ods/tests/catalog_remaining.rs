//! Slice 6 against a live fresh database: the remaining catalog rows
//! this code stores, decoded back and compared with what 6.0.0.2182
//! stores for the same create (`/tmp/s6probe.fdb`, read 2026-11-20;
//! the ACL and blob-header bytes scanned straight off that file).

use fire_crab_ods::catalog_format::{create_system_storage, format_skeleton};
use fire_crab_ods::catalog_index::store_system_indexes;
use fire_crab_ods::catalog_init::SYS_RELATIONS;
use fire_crab_ods::catalog_remaining::{
    store_remaining_catalog, ADDITIONAL_GRANTS, ADMIN_ROLE, DEFAULT_PUBLICATION, INTL_FIRST_CLASS,
};
use fire_crab_ods::catalog_rows::{
    ddl_acl, grant_relation_acl, nonrelation_acl, read_all_rows, role_acl, store_core_catalog,
    INTL_CLASSES_RESERVED,
};
use fire_crab_ods::catalog_runtime::store_runtime_blobs;
use fire_crab_ods::data::DataPage;
use fire_crab_ods::format::{max_recs_per_dp, read_blob_content, Value};
use fire_crab_ods::pointer::relation_data_pages;
use fire_crab_ods::{page_at, Image};

const PS: usize = 8192;

fn fresh_remaining() -> Image {
    let bytes = format_skeleton(PS, &[7u8; 16], (61318, 450070090));
    let mut file = Image::from_bytes(&bytes, PS);
    create_system_storage(&mut file, PS).unwrap();
    let mut alloc = store_core_catalog(&mut file, PS, "SYSDBA").unwrap();
    store_system_indexes(&mut file, PS).unwrap();
    store_runtime_blobs(&mut file, PS).unwrap();
    store_remaining_catalog(&mut file, PS, "SYSDBA", &mut alloc).unwrap();
    file
}

fn col(rel_id: u16, name: &str) -> usize {
    SYS_RELATIONS
        .iter()
        .find(|r| r.id == rel_id)
        .unwrap()
        .fields
        .iter()
        .position(|f| f.name == name)
        .unwrap()
}

fn text(v: &Value) -> Option<&str> {
    match v {
        Value::Text(s) => Some(s.trim_end()),
        Value::Null => None,
        v => panic!("expected text, got {v:?}"),
    }
}

fn int(v: &Value) -> Option<i64> {
    match v {
        Value::Int(n) => Some(*n),
        Value::Null => None,
        v => panic!("expected int, got {v:?}"),
    }
}

fn blob(v: &Value) -> Option<(u16, u64)> {
    match v {
        Value::Blob(rel, num) => Some((*rel, *num)),
        Value::Null => None,
        v => panic!("expected blob, got {v:?}"),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn blob_text(file: &Image, rel: u16, num: u64) -> String {
    String::from_utf8(read_blob_content(file, PS, rel, num).unwrap()).unwrap()
}

fn blob_hex(file: &Image, rel: u16, num: u64) -> String {
    hex(&read_blob_content(file, PS, rel, num).unwrap())
}

/// The raw slot bytes (the blh) behind a blob id, for subtype/charset
/// checks - the payload readers never show the header.
fn blob_slot(file: &Image, relation: u16, recno: u64) -> Vec<u8> {
    let recs = max_recs_per_dp(PS);
    let dp_no = relation_data_pages(file, PS, relation)[(recno / recs) as usize];
    let dp = DataPage::decode(page_at(file, PS, dp_no).unwrap()).unwrap();
    dp.slot_bytes((recno % recs) as u16).unwrap().to_vec()
}

fn blob_header(slot: &[u8]) -> (u16, u8) {
    (u16::from_le_bytes([slot[24], slot[25]]), slot[26])
}

/// All 298 `RDB$TYPES` rows off the fresh 2182 file, in file order.
const WANT_TYPES: &[(&str, i64, &str)] = &[
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
    ("RDB$FUNCTION_TYPE", 0, "VALUE"),
    ("RDB$FUNCTION_TYPE", 1, "BOOLEAN"),
    ("RDB$MECHANISM", 0, "BY_VALUE"),
    ("RDB$MECHANISM", 1, "BY_REFERENCE"),
    ("RDB$MECHANISM", 2, "BY_VMS_DESCRIPTOR"),
    ("RDB$MECHANISM", 3, "BY_ISC_DESCRIPTOR"),
    ("RDB$MECHANISM", 4, "BY_SCALAR_ARRAY_DESCRIPTOR"),
    ("RDB$MECHANISM", 5, "BY_REFERENCE_WITH_NULL"),
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
    ("RDB$TRANSACTION_STATE", 1, "LIMBO"),
    ("RDB$TRANSACTION_STATE", 2, "COMMITTED"),
    ("RDB$TRANSACTION_STATE", 3, "ROLLED_BACK"),
    ("RDB$SYSTEM_FLAG", 0, "USER"),
    ("RDB$SYSTEM_FLAG", 1, "SYSTEM"),
    ("RDB$SYSTEM_FLAG", 2, "QLI"),
    ("RDB$SYSTEM_FLAG", 3, "CHECK_CONSTRAINT"),
    ("RDB$SYSTEM_FLAG", 4, "REFERENTIAL_CONSTRAINT"),
    ("RDB$SYSTEM_FLAG", 5, "VIEW_CHECK"),
    ("RDB$SYSTEM_FLAG", 6, "IDENTITY_GENERATOR"),
    ("RDB$RELATION_TYPE", 0, "PERSISTENT"),
    ("RDB$RELATION_TYPE", 1, "VIEW"),
    ("RDB$RELATION_TYPE", 2, "EXTERNAL"),
    ("RDB$RELATION_TYPE", 3, "VIRTUAL"),
    ("RDB$RELATION_TYPE", 4, "GLOBAL_TEMPORARY_PRESERVE"),
    ("RDB$RELATION_TYPE", 5, "GLOBAL_TEMPORARY_DELETE"),
    ("RDB$PROCEDURE_TYPE", 0, "LEGACY"),
    ("RDB$PROCEDURE_TYPE", 1, "SELECTABLE"),
    ("RDB$PROCEDURE_TYPE", 2, "EXECUTABLE"),
    ("RDB$PARAMETER_MECHANISM", 0, "NORMAL"),
    ("RDB$PARAMETER_MECHANISM", 1, "TYPE OF"),
    ("MON$STATE", 0, "IDLE"),
    ("MON$STATE", 1, "ACTIVE"),
    ("MON$STATE", 2, "STALLED"),
    ("MON$SHUTDOWN_MODE", 0, "ONLINE"),
    ("MON$SHUTDOWN_MODE", 1, "MULTI_USER_SHUTDOWN"),
    ("MON$SHUTDOWN_MODE", 2, "SINGLE_USER_SHUTDOWN"),
    ("MON$SHUTDOWN_MODE", 3, "FULL_SHUTDOWN"),
    ("MON$ISOLATION_MODE", 0, "CONSISTENCY"),
    ("MON$ISOLATION_MODE", 1, "CONCURRENCY"),
    ("MON$ISOLATION_MODE", 2, "READ_COMMITTED_VERSION"),
    ("MON$ISOLATION_MODE", 3, "READ_COMMITTED_NO_VERSION"),
    ("MON$ISOLATION_MODE", 4, "READ_COMMITTED_READ_CONSISTENCY"),
    ("MON$BACKUP_STATE", 0, "NORMAL"),
    ("MON$BACKUP_STATE", 1, "STALLED"),
    ("MON$BACKUP_STATE", 2, "MERGE"),
    ("MON$STAT_GROUP", 0, "DATABASE"),
    ("MON$STAT_GROUP", 1, "ATTACHMENT"),
    ("MON$STAT_GROUP", 2, "TRANSACTION"),
    ("MON$STAT_GROUP", 3, "STATEMENT"),
    ("MON$STAT_GROUP", 4, "CALL"),
    ("RDB$IDENTITY_TYPE", 0, "ALWAYS"),
    ("RDB$IDENTITY_TYPE", 1, "BY DEFAULT"),
    ("RDB$PARAMETER_TYPE", 0, "INPUT"),
    ("RDB$PARAMETER_TYPE", 1, "OUTPUT"),
    ("RDB$TRIGGER_INACTIVE", 0, "ACTIVE"),
    ("RDB$TRIGGER_INACTIVE", 1, "INACTIVE"),
    ("RDB$INDEX_INACTIVE", 0, "ACTIVE"),
    ("RDB$INDEX_INACTIVE", 1, "INACTIVE"),
    ("RDB$UNIQUE_FLAG", 0, "NON_UNIQUE"),
    ("RDB$UNIQUE_FLAG", 1, "UNIQUE"),
    ("RDB$GRANT_OPTION", 0, "NONE"),
    ("RDB$GRANT_OPTION", 1, "GRANT_OPTION"),
    ("RDB$GRANT_OPTION", 2, "ADMIN_OPTION"),
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
    ("RDB$PRIVATE_FLAG", 0, "PUBLIC"),
    ("RDB$PRIVATE_FLAG", 1, "PRIVATE"),
    ("RDB$LEGACY_FLAG", 0, "NEW_STYLE"),
    ("RDB$LEGACY_FLAG", 1, "LEGACY_STYLE"),
    ("RDB$DETERMINISTIC_FLAG", 0, "NON_DETERMINISTIC"),
    ("RDB$DETERMINISTIC_FLAG", 1, "DETERMINISTIC"),
    ("RDB$AGGREGATE_FLAG", 0, "STANDARD"),
    ("RDB$AGGREGATE_FLAG", 1, "AGGREGATE"),
    ("RDB$MAP_TO_TYPE", 0, "USER"),
    ("RDB$MAP_TO_TYPE", 1, "ROLE"),
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
    ("MON$CRYPT_STATE", 0, "NOT ENCRYPTED"),
    ("MON$CRYPT_STATE", 1, "ENCRYPTED"),
    ("MON$CRYPT_STATE", 2, "DECRYPT IN PROGRESS"),
    ("MON$CRYPT_STATE", 3, "ENCRYPT IN PROGRESS"),
    ("MON$REPLICA_MODE", 0, "NONE"),
    ("MON$REPLICA_MODE", 1, "READ-ONLY"),
    ("MON$REPLICA_MODE", 2, "READ-WRITE"),
    ("RDB$CHARACTER_SET_NAME", 0, "NONE"),
    ("RDB$CHARACTER_SET_NAME", 1, "OCTETS"),
    ("RDB$CHARACTER_SET_NAME", 2, "ASCII"),
    ("RDB$CHARACTER_SET_NAME", 3, "UNICODE_FSS"),
    ("RDB$CHARACTER_SET_NAME", 4, "UTF8"),
    ("RDB$CHARACTER_SET_NAME", 5, "SJIS_0208"),
    ("RDB$CHARACTER_SET_NAME", 6, "EUCJ_0208"),
    ("RDB$CHARACTER_SET_NAME", 10, "DOS437"),
    ("RDB$CHARACTER_SET_NAME", 11, "DOS850"),
    ("RDB$CHARACTER_SET_NAME", 12, "DOS865"),
    ("RDB$CHARACTER_SET_NAME", 21, "ISO8859_1"),
    ("RDB$CHARACTER_SET_NAME", 22, "ISO8859_2"),
    ("RDB$CHARACTER_SET_NAME", 23, "ISO8859_3"),
    ("RDB$CHARACTER_SET_NAME", 34, "ISO8859_4"),
    ("RDB$CHARACTER_SET_NAME", 35, "ISO8859_5"),
    ("RDB$CHARACTER_SET_NAME", 36, "ISO8859_6"),
    ("RDB$CHARACTER_SET_NAME", 37, "ISO8859_7"),
    ("RDB$CHARACTER_SET_NAME", 38, "ISO8859_8"),
    ("RDB$CHARACTER_SET_NAME", 39, "ISO8859_9"),
    ("RDB$CHARACTER_SET_NAME", 40, "ISO8859_13"),
    ("RDB$CHARACTER_SET_NAME", 45, "DOS852"),
    ("RDB$CHARACTER_SET_NAME", 46, "DOS857"),
    ("RDB$CHARACTER_SET_NAME", 13, "DOS860"),
    ("RDB$CHARACTER_SET_NAME", 47, "DOS861"),
    ("RDB$CHARACTER_SET_NAME", 14, "DOS863"),
    ("RDB$CHARACTER_SET_NAME", 50, "CYRL"),
    ("RDB$CHARACTER_SET_NAME", 9, "DOS737"),
    ("RDB$CHARACTER_SET_NAME", 15, "DOS775"),
    ("RDB$CHARACTER_SET_NAME", 16, "DOS858"),
    ("RDB$CHARACTER_SET_NAME", 17, "DOS862"),
    ("RDB$CHARACTER_SET_NAME", 18, "DOS864"),
    ("RDB$CHARACTER_SET_NAME", 48, "DOS866"),
    ("RDB$CHARACTER_SET_NAME", 49, "DOS869"),
    ("RDB$CHARACTER_SET_NAME", 51, "WIN1250"),
    ("RDB$CHARACTER_SET_NAME", 52, "WIN1251"),
    ("RDB$CHARACTER_SET_NAME", 53, "WIN1252"),
    ("RDB$CHARACTER_SET_NAME", 54, "WIN1253"),
    ("RDB$CHARACTER_SET_NAME", 55, "WIN1254"),
    ("RDB$CHARACTER_SET_NAME", 19, "NEXT"),
    ("RDB$CHARACTER_SET_NAME", 58, "WIN1255"),
    ("RDB$CHARACTER_SET_NAME", 59, "WIN1256"),
    ("RDB$CHARACTER_SET_NAME", 60, "WIN1257"),
    ("RDB$CHARACTER_SET_NAME", 44, "KSC_5601"),
    ("RDB$CHARACTER_SET_NAME", 56, "BIG_5"),
    ("RDB$CHARACTER_SET_NAME", 57, "GB_2312"),
    ("RDB$CHARACTER_SET_NAME", 63, "KOI8R"),
    ("RDB$CHARACTER_SET_NAME", 64, "KOI8U"),
    ("RDB$CHARACTER_SET_NAME", 65, "WIN1258"),
    ("RDB$CHARACTER_SET_NAME", 66, "TIS620"),
    ("RDB$CHARACTER_SET_NAME", 67, "GBK"),
    ("RDB$CHARACTER_SET_NAME", 68, "CP943C"),
    ("RDB$CHARACTER_SET_NAME", 69, "GB18030"),
    ("RDB$CHARACTER_SET_NAME", 1, "BINARY"),
    ("RDB$CHARACTER_SET_NAME", 2, "USASCII"),
    ("RDB$CHARACTER_SET_NAME", 2, "ASCII7"),
    ("RDB$CHARACTER_SET_NAME", 3, "UTF_FSS"),
    ("RDB$CHARACTER_SET_NAME", 3, "SQL_TEXT"),
    ("RDB$CHARACTER_SET_NAME", 4, "UTF-8"),
    ("RDB$CHARACTER_SET_NAME", 5, "SJIS"),
    ("RDB$CHARACTER_SET_NAME", 6, "EUCJ"),
    ("RDB$CHARACTER_SET_NAME", 10, "DOS_437"),
    ("RDB$CHARACTER_SET_NAME", 11, "DOS_850"),
    ("RDB$CHARACTER_SET_NAME", 12, "DOS_865"),
    ("RDB$CHARACTER_SET_NAME", 21, "ISO88591"),
    ("RDB$CHARACTER_SET_NAME", 21, "LATIN1"),
    ("RDB$CHARACTER_SET_NAME", 21, "ANSI"),
    ("RDB$CHARACTER_SET_NAME", 22, "ISO88592"),
    ("RDB$CHARACTER_SET_NAME", 22, "LATIN2"),
    ("RDB$CHARACTER_SET_NAME", 22, "ISO-8859-2"),
    ("RDB$CHARACTER_SET_NAME", 23, "ISO88593"),
    ("RDB$CHARACTER_SET_NAME", 23, "LATIN3"),
    ("RDB$CHARACTER_SET_NAME", 23, "ISO-8859-3"),
    ("RDB$CHARACTER_SET_NAME", 34, "ISO88594"),
    ("RDB$CHARACTER_SET_NAME", 34, "LATIN4"),
    ("RDB$CHARACTER_SET_NAME", 34, "ISO-8859-4"),
    ("RDB$CHARACTER_SET_NAME", 35, "ISO88595"),
    ("RDB$CHARACTER_SET_NAME", 35, "ISO-8859-5"),
    ("RDB$CHARACTER_SET_NAME", 36, "ISO88596"),
    ("RDB$CHARACTER_SET_NAME", 36, "ISO-8859-6"),
    ("RDB$CHARACTER_SET_NAME", 37, "ISO88597"),
    ("RDB$CHARACTER_SET_NAME", 37, "ISO-8859-7"),
    ("RDB$CHARACTER_SET_NAME", 38, "ISO88598"),
    ("RDB$CHARACTER_SET_NAME", 38, "ISO-8859-8"),
    ("RDB$CHARACTER_SET_NAME", 39, "ISO88599"),
    ("RDB$CHARACTER_SET_NAME", 39, "LATIN5"),
    ("RDB$CHARACTER_SET_NAME", 39, "ISO-8859-9"),
    ("RDB$CHARACTER_SET_NAME", 40, "ISO885913"),
    ("RDB$CHARACTER_SET_NAME", 40, "LATIN7"),
    ("RDB$CHARACTER_SET_NAME", 40, "ISO-8859-13"),
    ("RDB$CHARACTER_SET_NAME", 45, "DOS_852"),
    ("RDB$CHARACTER_SET_NAME", 46, "DOS_857"),
    ("RDB$CHARACTER_SET_NAME", 13, "DOS_860"),
    ("RDB$CHARACTER_SET_NAME", 47, "DOS_861"),
    ("RDB$CHARACTER_SET_NAME", 14, "DOS_863"),
    ("RDB$CHARACTER_SET_NAME", 9, "DOS_737"),
    ("RDB$CHARACTER_SET_NAME", 15, "DOS_775"),
    ("RDB$CHARACTER_SET_NAME", 16, "DOS_858"),
    ("RDB$CHARACTER_SET_NAME", 17, "DOS_862"),
    ("RDB$CHARACTER_SET_NAME", 18, "DOS_864"),
    ("RDB$CHARACTER_SET_NAME", 48, "DOS_866"),
    ("RDB$CHARACTER_SET_NAME", 49, "DOS_869"),
    ("RDB$CHARACTER_SET_NAME", 51, "WIN_1250"),
    ("RDB$CHARACTER_SET_NAME", 52, "WIN_1251"),
    ("RDB$CHARACTER_SET_NAME", 53, "WIN_1252"),
    ("RDB$CHARACTER_SET_NAME", 54, "WIN_1253"),
    ("RDB$CHARACTER_SET_NAME", 55, "WIN_1254"),
    ("RDB$CHARACTER_SET_NAME", 58, "WIN_1255"),
    ("RDB$CHARACTER_SET_NAME", 59, "WIN_1256"),
    ("RDB$CHARACTER_SET_NAME", 60, "WIN_1257"),
    ("RDB$CHARACTER_SET_NAME", 65, "WIN_1258"),
    ("RDB$CHARACTER_SET_NAME", 44, "KSC5601"),
    ("RDB$CHARACTER_SET_NAME", 44, "DOS_949"),
    ("RDB$CHARACTER_SET_NAME", 44, "WIN_949"),
    ("RDB$CHARACTER_SET_NAME", 56, "BIG5"),
    ("RDB$CHARACTER_SET_NAME", 56, "DOS_950"),
    ("RDB$CHARACTER_SET_NAME", 56, "WIN_950"),
    ("RDB$CHARACTER_SET_NAME", 57, "GB2312"),
    ("RDB$CHARACTER_SET_NAME", 57, "DOS_936"),
    ("RDB$CHARACTER_SET_NAME", 57, "WIN_936"),
];

/// All 52 `RDB$CHARACTER_SETS` rows: (name, id, max bytes, class).
const WANT_CHARSETS: &[(&str, i64, i64, &str)] = &[
    ("NONE", 0, 1, "SQL$250"),
    ("OCTETS", 1, 1, "SQL$251"),
    ("ASCII", 2, 1, "SQL$252"),
    ("UNICODE_FSS", 3, 3, "SQL$253"),
    ("UTF8", 4, 4, "SQL$254"),
    ("SJIS_0208", 5, 2, "SQL$255"),
    ("EUCJ_0208", 6, 2, "SQL$256"),
    ("DOS437", 10, 1, "SQL$257"),
    ("DOS850", 11, 1, "SQL$258"),
    ("DOS865", 12, 1, "SQL$259"),
    ("ISO8859_1", 21, 1, "SQL$260"),
    ("ISO8859_2", 22, 1, "SQL$261"),
    ("ISO8859_3", 23, 1, "SQL$262"),
    ("ISO8859_4", 34, 1, "SQL$263"),
    ("ISO8859_5", 35, 1, "SQL$264"),
    ("ISO8859_6", 36, 1, "SQL$265"),
    ("ISO8859_7", 37, 1, "SQL$266"),
    ("ISO8859_8", 38, 1, "SQL$267"),
    ("ISO8859_9", 39, 1, "SQL$268"),
    ("ISO8859_13", 40, 1, "SQL$269"),
    ("DOS852", 45, 1, "SQL$270"),
    ("DOS857", 46, 1, "SQL$271"),
    ("DOS860", 13, 1, "SQL$272"),
    ("DOS861", 47, 1, "SQL$273"),
    ("DOS863", 14, 1, "SQL$274"),
    ("CYRL", 50, 1, "SQL$275"),
    ("DOS737", 9, 1, "SQL$276"),
    ("DOS775", 15, 1, "SQL$277"),
    ("DOS858", 16, 1, "SQL$278"),
    ("DOS862", 17, 1, "SQL$279"),
    ("DOS864", 18, 1, "SQL$280"),
    ("DOS866", 48, 1, "SQL$281"),
    ("DOS869", 49, 1, "SQL$282"),
    ("WIN1250", 51, 1, "SQL$283"),
    ("WIN1251", 52, 1, "SQL$284"),
    ("WIN1252", 53, 1, "SQL$285"),
    ("WIN1253", 54, 1, "SQL$286"),
    ("WIN1254", 55, 1, "SQL$287"),
    ("NEXT", 19, 1, "SQL$288"),
    ("WIN1255", 58, 1, "SQL$289"),
    ("WIN1256", 59, 1, "SQL$290"),
    ("WIN1257", 60, 1, "SQL$291"),
    ("KSC_5601", 44, 2, "SQL$292"),
    ("BIG_5", 56, 2, "SQL$293"),
    ("GB_2312", 57, 2, "SQL$294"),
    ("KOI8R", 63, 1, "SQL$295"),
    ("KOI8U", 64, 1, "SQL$296"),
    ("WIN1258", 65, 1, "SQL$297"),
    ("TIS620", 66, 1, "SQL$298"),
    ("GBK", 67, 2, "SQL$299"),
    ("CP943C", 68, 2, "SQL$300"),
    ("GB18030", 69, 4, "SQL$301"),
];

/// All 149 `RDB$COLLATIONS` rows: (name, charset, id, attrs, base, specific, class).
const WANT_COLLATIONS: &[(&str, i64, i64, i64, Option<&str>, Option<&str>, &str)] = &[
    ("NONE", 0, 0, 1, None, None, "SQL$302"),
    ("OCTETS", 1, 0, 1, None, None, "SQL$303"),
    ("ASCII", 2, 0, 1, None, None, "SQL$304"),
    ("UNICODE_FSS", 3, 0, 1, None, None, "SQL$305"),
    ("UTF8", 4, 0, 1, None, None, "SQL$306"),
    ("UCS_BASIC", 4, 1, 1, None, None, "SQL$307"),
    ("UNICODE", 4, 2, 1, None, Some("COLL-VERSION=153.121;ICU-VERSION=74.2"), "SQL$308"),
    ("UNICODE_CI", 4, 3, 3, Some("UNICODE"), Some("COLL-VERSION=153.121;ICU-VERSION=74.2"), "SQL$309"),
    ("UNICODE_CI_AI", 4, 4, 7, Some("UNICODE"), Some("COLL-VERSION=153.121;ICU-VERSION=74.2"), "SQL$310"),
    ("SJIS_0208", 5, 0, 1, None, None, "SQL$311"),
    ("EUCJ_0208", 6, 0, 1, None, None, "SQL$312"),
    ("DOS437", 10, 0, 1, None, None, "SQL$313"),
    ("PDOX_ASCII", 10, 1, 1, None, None, "SQL$314"),
    ("PDOX_INTL", 10, 2, 1, None, None, "SQL$315"),
    ("PDOX_SWEDFIN", 10, 3, 1, None, None, "SQL$316"),
    ("DB_DEU437", 10, 4, 1, None, None, "SQL$317"),
    ("DB_ESP437", 10, 5, 1, None, None, "SQL$318"),
    ("DB_FIN437", 10, 6, 1, None, None, "SQL$319"),
    ("DB_FRA437", 10, 7, 1, None, None, "SQL$320"),
    ("DB_ITA437", 10, 8, 1, None, None, "SQL$321"),
    ("DB_NLD437", 10, 9, 1, None, None, "SQL$322"),
    ("DB_SVE437", 10, 10, 1, None, None, "SQL$323"),
    ("DB_UK437", 10, 11, 1, None, None, "SQL$324"),
    ("DB_US437", 10, 12, 1, None, None, "SQL$325"),
    ("DOS850", 11, 0, 1, None, None, "SQL$326"),
    ("DB_FRC850", 11, 1, 1, None, None, "SQL$327"),
    ("DB_DEU850", 11, 2, 1, None, None, "SQL$328"),
    ("DB_ESP850", 11, 3, 1, None, None, "SQL$329"),
    ("DB_FRA850", 11, 4, 1, None, None, "SQL$330"),
    ("DB_ITA850", 11, 5, 1, None, None, "SQL$331"),
    ("DB_NLD850", 11, 6, 1, None, None, "SQL$332"),
    ("DB_PTB850", 11, 7, 1, None, None, "SQL$333"),
    ("DB_SVE850", 11, 8, 1, None, None, "SQL$334"),
    ("DB_UK850", 11, 9, 1, None, None, "SQL$335"),
    ("DB_US850", 11, 10, 1, None, None, "SQL$336"),
    ("DOS865", 12, 0, 1, None, None, "SQL$337"),
    ("PDOX_NORDAN4", 12, 1, 1, None, None, "SQL$338"),
    ("DB_DAN865", 12, 2, 1, None, None, "SQL$339"),
    ("DB_NOR865", 12, 3, 1, None, None, "SQL$340"),
    ("ISO8859_1", 21, 0, 1, None, None, "SQL$341"),
    ("DA_DA", 21, 1, 1, None, None, "SQL$342"),
    ("DU_NL", 21, 2, 1, None, None, "SQL$343"),
    ("FI_FI", 21, 3, 1, None, None, "SQL$344"),
    ("FR_FR", 21, 4, 1, None, None, "SQL$345"),
    ("FR_CA", 21, 5, 1, None, None, "SQL$346"),
    ("DE_DE", 21, 6, 1, None, None, "SQL$347"),
    ("IS_IS", 21, 7, 1, None, None, "SQL$348"),
    ("IT_IT", 21, 8, 1, None, None, "SQL$349"),
    ("NO_NO", 21, 9, 1, None, None, "SQL$350"),
    ("ES_ES", 21, 10, 1, None, Some("DISABLE-COMPRESSIONS=1;SPECIALS-FIRST=1"), "SQL$351"),
    ("SV_SV", 21, 11, 1, None, None, "SQL$352"),
    ("EN_UK", 21, 12, 1, None, None, "SQL$353"),
    ("EN_US", 21, 14, 1, None, None, "SQL$354"),
    ("PT_PT", 21, 15, 1, None, None, "SQL$355"),
    ("PT_BR", 21, 16, 7, None, None, "SQL$356"),
    ("ES_ES_CI_AI", 21, 17, 7, None, Some("DISABLE-COMPRESSIONS=1;SPECIALS-FIRST=1"), "SQL$357"),
    ("FR_FR_CI_AI", 21, 18, 7, Some("FR_FR"), Some("SPECIALS-FIRST=1"), "SQL$358"),
    ("FR_CA_CI_AI", 21, 19, 7, Some("FR_CA"), Some("SPECIALS-FIRST=1"), "SQL$359"),
    ("ISO8859_2", 22, 0, 1, None, None, "SQL$360"),
    ("CS_CZ", 22, 1, 1, None, None, "SQL$361"),
    ("ISO_HUN", 22, 2, 1, None, None, "SQL$362"),
    ("ISO_PLK", 22, 3, 1, None, None, "SQL$363"),
    ("ISO8859_3", 23, 0, 1, None, None, "SQL$364"),
    ("ISO8859_4", 34, 0, 1, None, None, "SQL$365"),
    ("ISO8859_5", 35, 0, 1, None, None, "SQL$366"),
    ("ISO8859_6", 36, 0, 1, None, None, "SQL$367"),
    ("ISO8859_7", 37, 0, 1, None, None, "SQL$368"),
    ("ISO8859_8", 38, 0, 1, None, None, "SQL$369"),
    ("ISO8859_9", 39, 0, 1, None, None, "SQL$370"),
    ("ISO8859_13", 40, 0, 1, None, None, "SQL$371"),
    ("LT_LT", 40, 1, 1, None, None, "SQL$372"),
    ("DOS852", 45, 0, 1, None, None, "SQL$373"),
    ("DB_CSY", 45, 1, 1, None, None, "SQL$374"),
    ("DB_PLK", 45, 2, 1, None, None, "SQL$375"),
    ("DB_SLO", 45, 4, 1, None, None, "SQL$376"),
    ("PDOX_CSY", 45, 5, 1, None, None, "SQL$377"),
    ("PDOX_PLK", 45, 6, 1, None, None, "SQL$378"),
    ("PDOX_HUN", 45, 7, 1, None, None, "SQL$379"),
    ("PDOX_SLO", 45, 8, 1, None, None, "SQL$380"),
    ("DOS857", 46, 0, 1, None, None, "SQL$381"),
    ("DB_TRK", 46, 1, 1, None, None, "SQL$382"),
    ("DOS860", 13, 0, 1, None, None, "SQL$383"),
    ("DB_PTG860", 13, 1, 1, None, None, "SQL$384"),
    ("DOS861", 47, 0, 1, None, None, "SQL$385"),
    ("PDOX_ISL", 47, 1, 1, None, None, "SQL$386"),
    ("DOS863", 14, 0, 1, None, None, "SQL$387"),
    ("DB_FRC863", 14, 1, 1, None, None, "SQL$388"),
    ("CYRL", 50, 0, 1, None, None, "SQL$389"),
    ("DB_RUS", 50, 1, 1, None, None, "SQL$390"),
    ("PDOX_CYRL", 50, 2, 1, None, None, "SQL$391"),
    ("DOS737", 9, 0, 1, None, None, "SQL$392"),
    ("DOS775", 15, 0, 1, None, None, "SQL$393"),
    ("DOS858", 16, 0, 1, None, None, "SQL$394"),
    ("DOS862", 17, 0, 1, None, None, "SQL$395"),
    ("DOS864", 18, 0, 1, None, None, "SQL$396"),
    ("DOS866", 48, 0, 1, None, None, "SQL$397"),
    ("DOS869", 49, 0, 1, None, None, "SQL$398"),
    ("WIN1250", 51, 0, 1, None, None, "SQL$399"),
    ("PXW_CSY", 51, 1, 1, None, None, "SQL$400"),
    ("PXW_HUNDC", 51, 2, 1, None, None, "SQL$401"),
    ("PXW_PLK", 51, 3, 1, None, None, "SQL$402"),
    ("PXW_SLOV", 51, 4, 1, None, None, "SQL$403"),
    ("PXW_HUN", 51, 5, 1, None, None, "SQL$404"),
    ("BS_BA", 51, 6, 1, None, None, "SQL$405"),
    ("WIN_CZ", 51, 7, 3, None, None, "SQL$406"),
    ("WIN_CZ_CI_AI", 51, 8, 7, None, None, "SQL$407"),
    ("WIN1251", 52, 0, 1, None, None, "SQL$408"),
    ("PXW_CYRL", 52, 1, 1, None, None, "SQL$409"),
    ("WIN1251_UA", 52, 2, 1, None, None, "SQL$410"),
    ("WIN1252", 53, 0, 1, None, None, "SQL$411"),
    ("PXW_INTL", 53, 1, 1, None, None, "SQL$412"),
    ("PXW_INTL850", 53, 2, 1, None, None, "SQL$413"),
    ("PXW_NORDAN4", 53, 3, 1, None, None, "SQL$414"),
    ("PXW_SPAN", 53, 4, 1, None, None, "SQL$415"),
    ("PXW_SWEDFIN", 53, 5, 1, None, None, "SQL$416"),
    ("WIN_PTBR", 53, 6, 7, None, None, "SQL$417"),
    ("WIN1253", 54, 0, 1, None, None, "SQL$418"),
    ("PXW_GREEK", 54, 1, 1, None, None, "SQL$419"),
    ("WIN1254", 55, 0, 1, None, None, "SQL$420"),
    ("PXW_TURK", 55, 1, 1, None, None, "SQL$421"),
    ("NEXT", 19, 0, 1, None, None, "SQL$422"),
    ("NXT_US", 19, 1, 1, None, None, "SQL$423"),
    ("NXT_DEU", 19, 2, 1, None, None, "SQL$424"),
    ("NXT_FRA", 19, 3, 1, None, None, "SQL$425"),
    ("NXT_ITA", 19, 4, 1, None, None, "SQL$426"),
    ("NXT_ESP", 19, 5, 1, None, None, "SQL$427"),
    ("WIN1255", 58, 0, 1, None, None, "SQL$428"),
    ("WIN1256", 59, 0, 1, None, None, "SQL$429"),
    ("WIN1257", 60, 0, 1, None, None, "SQL$430"),
    ("WIN1257_EE", 60, 1, 1, None, None, "SQL$431"),
    ("WIN1257_LT", 60, 2, 1, None, None, "SQL$432"),
    ("WIN1257_LV", 60, 3, 1, None, None, "SQL$433"),
    ("KSC_5601", 44, 0, 1, None, None, "SQL$434"),
    ("KSC_DICTIONARY", 44, 1, 1, None, None, "SQL$435"),
    ("BIG_5", 56, 0, 1, None, None, "SQL$436"),
    ("GB_2312", 57, 0, 1, None, None, "SQL$437"),
    ("KOI8R", 63, 0, 1, None, None, "SQL$438"),
    ("KOI8R_RU", 63, 1, 1, None, None, "SQL$439"),
    ("KOI8U", 64, 0, 1, None, None, "SQL$440"),
    ("KOI8U_UA", 64, 1, 1, None, None, "SQL$441"),
    ("WIN1258", 65, 0, 1, None, None, "SQL$442"),
    ("TIS620", 66, 0, 1, None, None, "SQL$443"),
    ("TIS620_UNICODE", 66, 1, 1, None, Some("COLL-VERSION=153.121;ICU-VERSION=74.2"), "SQL$444"),
    ("GBK", 67, 0, 1, None, None, "SQL$445"),
    ("GBK_UNICODE", 67, 1, 1, None, Some("COLL-VERSION=153.121;ICU-VERSION=74.2"), "SQL$446"),
    ("CP943C", 68, 0, 1, None, None, "SQL$447"),
    ("CP943C_UNICODE", 68, 1, 1, None, Some("COLL-VERSION=153.121;ICU-VERSION=74.2"), "SQL$448"),
    ("GB18030", 69, 0, 1, None, None, "SQL$449"),
    ("GB18030_UNICODE", 69, 1, 1, None, Some("COLL-VERSION=153.121;ICU-VERSION=74.2"), "SQL$450"),
];

const WANT_PACKAGES: &[(&str, &str, i64)] = &[
    ("RDB$TIME_ZONE_UTIL", "SQL$464", 1),
    ("RDB$PROFILER", "SQL$465", 2),
    ("RDB$BLOB_UTIL", "SQL$466", 3),
    ("RDB$SQL", "SQL$467", 4),
];

const WANT_PROCEDURES: &[(&str, &str, i64, i64, i64, i64)] = &[
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", 1, 3, 5, 1),
    ("RDB$PROFILER", "CANCEL_SESSION", 2, 1, 0, 2),
    ("RDB$PROFILER", "DISCARD", 3, 1, 0, 2),
    ("RDB$PROFILER", "FINISH_SESSION", 4, 2, 0, 2),
    ("RDB$PROFILER", "FLUSH", 5, 1, 0, 2),
    ("RDB$PROFILER", "PAUSE_SESSION", 6, 2, 0, 2),
    ("RDB$PROFILER", "RESUME_SESSION", 7, 1, 0, 2),
    ("RDB$PROFILER", "SET_FLUSH_INTERVAL", 8, 2, 0, 2),
    ("RDB$BLOB_UTIL", "CANCEL_BLOB", 9, 1, 0, 2),
    ("RDB$BLOB_UTIL", "CLOSE_HANDLE", 10, 1, 0, 2),
    ("RDB$SQL", "EXPLAIN", 11, 1, 13, 1),
    ("RDB$SQL", "PARSE_UNQUALIFIED_NAMES", 12, 1, 1, 1),
];

const WANT_PROC_PARAMS: &[(&str, &str, &str, i64, i64, &str, i64, Option<&str>, Option<&str>)] = &[
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$TIME_ZONE_NAME", 0, 0, "RDB$TIME_ZONE_NAME", 1, None, None),
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$FROM_TIMESTAMP", 1, 0, "RDB$TIMESTAMP_TZ", 1, None, None),
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$TO_TIMESTAMP", 2, 0, "RDB$TIMESTAMP_TZ", 1, None, None),
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$START_TIMESTAMP", 0, 1, "RDB$TIMESTAMP_TZ", 1, None, None),
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$END_TIMESTAMP", 1, 1, "RDB$TIMESTAMP_TZ", 1, None, None),
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$ZONE_OFFSET", 2, 1, "RDB$TIME_ZONE_OFFSET", 1, None, None),
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$DST_OFFSET", 3, 1, "RDB$TIME_ZONE_OFFSET", 1, None, None),
    ("RDB$TIME_ZONE_UTIL", "TRANSITIONS", "RDB$EFFECTIVE_OFFSET", 4, 1, "RDB$TIME_ZONE_OFFSET", 1, None, None),
    ("RDB$PROFILER", "CANCEL_SESSION", "ATTACHMENT_ID", 0, 0, "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "DISCARD", "ATTACHMENT_ID", 0, 0, "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "FINISH_SESSION", "FLUSH", 0, 0, "RDB$BOOLEAN", 1, Some("default true"), Some("051517014c")),
    ("RDB$PROFILER", "FINISH_SESSION", "ATTACHMENT_ID", 1, 0, "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "FLUSH", "ATTACHMENT_ID", 0, 0, "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "PAUSE_SESSION", "FLUSH", 0, 0, "RDB$BOOLEAN", 1, Some("default false"), Some("051517004c")),
    ("RDB$PROFILER", "PAUSE_SESSION", "ATTACHMENT_ID", 1, 0, "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "RESUME_SESSION", "ATTACHMENT_ID", 0, 0, "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "SET_FLUSH_INTERVAL", "FLUSH_INTERVAL", 0, 0, "RDB$SECONDS_INTERVAL", 1, None, None),
    ("RDB$PROFILER", "SET_FLUSH_INTERVAL", "ATTACHMENT_ID", 1, 0, "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$BLOB_UTIL", "CANCEL_BLOB", "BLOB", 0, 0, "RDB$BLOB", 1, None, None),
    ("RDB$BLOB_UTIL", "CLOSE_HANDLE", "HANDLE", 0, 0, "RDB$BLOB_UTIL_HANDLE", 1, None, None),
    ("RDB$SQL", "EXPLAIN", "SQL", 0, 0, "RDB$DESCRIPTION", 1, None, None),
    ("RDB$SQL", "EXPLAIN", "PLAN_LINE", 0, 1, "RDB$INTEGER", 1, None, None),
    ("RDB$SQL", "EXPLAIN", "RECORD_SOURCE_ID", 1, 1, "RDB$GENERATOR_VALUE", 1, None, None),
    ("RDB$SQL", "EXPLAIN", "PARENT_RECORD_SOURCE_ID", 2, 1, "RDB$GENERATOR_VALUE", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "LEVEL", 3, 1, "RDB$INTEGER", 1, None, None),
    ("RDB$SQL", "EXPLAIN", "OBJECT_TYPE", 4, 1, "RDB$OBJECT_TYPE", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "SCHEMA_NAME", 5, 1, "RDB$SCHEMA_NAME", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "PACKAGE_NAME", 6, 1, "RDB$PACKAGE_NAME", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "OBJECT_NAME", 7, 1, "RDB$RELATION_NAME", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "ALIAS", 8, 1, "RDB$SHORT_DESCRIPTION", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "CARDINALITY", 9, 1, "RDB$STATISTICS", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "RECORD_LENGTH", 10, 1, "RDB$INTEGER", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "KEY_LENGTH", 11, 1, "RDB$INTEGER", 0, None, None),
    ("RDB$SQL", "EXPLAIN", "ACCESS_PATH", 12, 1, "RDB$DESCRIPTION", 1, None, None),
    ("RDB$SQL", "PARSE_UNQUALIFIED_NAMES", "NAMES", 0, 0, "RDB$TEXT_MAX", 0, None, None),
    ("RDB$SQL", "PARSE_UNQUALIFIED_NAMES", "NAME", 0, 1, "RDB$RELATION_NAME", 1, None, None),
];

const WANT_FUNCTIONS: &[(&str, &str, i64)] = &[
    ("RDB$TIME_ZONE_UTIL", "DATABASE_VERSION", 1),
    ("RDB$PROFILER", "START_SESSION", 2),
    ("RDB$BLOB_UTIL", "IS_WRITABLE", 3),
    ("RDB$BLOB_UTIL", "NEW_BLOB", 4),
    ("RDB$BLOB_UTIL", "OPEN_BLOB", 5),
    ("RDB$BLOB_UTIL", "SEEK", 6),
    ("RDB$BLOB_UTIL", "READ_DATA", 7),
];

const WANT_FUNC_ARGS: &[(&str, &str, i64, Option<&str>, &str, i64, Option<&str>, Option<&str>)] = &[
    ("RDB$TIME_ZONE_UTIL", "DATABASE_VERSION", 0, None, "RDB$DBTZ_VERSION", 1, None, None),
    ("RDB$PROFILER", "START_SESSION", 0, None, "RDB$PROFILE_SESSION_ID", 1, None, None),
    ("RDB$PROFILER", "START_SESSION", 1, Some("DESCRIPTION"), "RDB$SHORT_DESCRIPTION", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "START_SESSION", 2, Some("FLUSH_INTERVAL"), "RDB$SECONDS_INTERVAL", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "START_SESSION", 3, Some("ATTACHMENT_ID"), "RDB$ATTACHMENT_ID", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "START_SESSION", 4, Some("PLUGIN_NAME"), "RDB$FILE_NAME2", 0, Some("default null"), Some("052d4c")),
    ("RDB$PROFILER", "START_SESSION", 5, Some("PLUGIN_OPTIONS"), "RDB$SHORT_DESCRIPTION", 0, Some("default null"), Some("052d4c")),
    ("RDB$BLOB_UTIL", "IS_WRITABLE", 0, None, "RDB$BOOLEAN", 1, None, None),
    ("RDB$BLOB_UTIL", "IS_WRITABLE", 1, Some("BLOB"), "RDB$BLOB", 1, None, None),
    ("RDB$BLOB_UTIL", "NEW_BLOB", 0, None, "RDB$BLOB", 1, None, None),
    ("RDB$BLOB_UTIL", "NEW_BLOB", 1, Some("SEGMENTED"), "RDB$BOOLEAN", 1, None, None),
    ("RDB$BLOB_UTIL", "NEW_BLOB", 2, Some("TEMP_STORAGE"), "RDB$BOOLEAN", 1, None, None),
    ("RDB$BLOB_UTIL", "OPEN_BLOB", 0, None, "RDB$BLOB_UTIL_HANDLE", 1, None, None),
    ("RDB$BLOB_UTIL", "OPEN_BLOB", 1, Some("BLOB"), "RDB$BLOB", 1, None, None),
    ("RDB$BLOB_UTIL", "SEEK", 0, None, "RDB$INTEGER", 1, None, None),
    ("RDB$BLOB_UTIL", "SEEK", 1, Some("HANDLE"), "RDB$BLOB_UTIL_HANDLE", 1, None, None),
    ("RDB$BLOB_UTIL", "SEEK", 2, Some("MODE"), "RDB$INTEGER", 1, None, None),
    ("RDB$BLOB_UTIL", "SEEK", 3, Some("OFFSET"), "RDB$INTEGER", 1, None, None),
    ("RDB$BLOB_UTIL", "READ_DATA", 0, None, "RDB$VARBINARY_MAX", 0, None, None),
    ("RDB$BLOB_UTIL", "READ_DATA", 1, Some("HANDLE"), "RDB$BLOB_UTIL_HANDLE", 1, None, None),
    ("RDB$BLOB_UTIL", "READ_DATA", 2, Some("LENGTH"), "RDB$INTEGER", 0, None, None),
];

const WANT_CONSTANTS: &[(&str, &str, &str, &str, &str)] = &[
    ("RDB$BLOB_UTIL", "FROM_BEGIN", "RDB$INTEGER", "0", "0515070000004c"),
    ("RDB$BLOB_UTIL", "FROM_CURRENT", "RDB$INTEGER", "1", "0515070001004c"),
    ("RDB$BLOB_UTIL", "FROM_END", "RDB$INTEGER", "2", "0515070002004c"),
];

/// The 26 DDL class rows in file order (15 grant objects then `SQL$DATABASE`).
const WANT_DDL_CLASSES: &[&str] = &[
    "SQL$D22PUBLIC",
    "SQL$D22SYSTEM",
    "SQL$D23PUBLIC",
    "SQL$D23SYSTEM",
    "SQL$D24PUBLIC",
    "SQL$D24SYSTEM",
    "SQL$D25PUBLIC",
    "SQL$D25SYSTEM",
    "SQL$D26PUBLIC",
    "SQL$D26SYSTEM",
    "SQL$D27PUBLIC",
    "SQL$D27SYSTEM",
    "SQL$D28PUBLIC",
    "SQL$D28SYSTEM",
    "SQL$D29PUBLIC",
    "SQL$D29SYSTEM",
    "SQL$D30",
    "SQL$D31PUBLIC",
    "SQL$D31SYSTEM",
    "SQL$D32PUBLIC",
    "SQL$D32SYSTEM",
    "SQL$D33",
    "SQL$D34",
    "SQL$D36",
    "SQL$D39",
    "SQL$DATABASE",
];

#[test]
fn types_match_oracle() {
    let file = fresh_remaining();
    let rows = read_all_rows(&file, PS, 11);
    assert_eq!(rows.len(), WANT_TYPES.len(), "RDB$TYPES row count");
    let (c_field, c_type, c_name, c_desc, c_flag) =
        (col(11, "RDB$FIELD_NAME"), col(11, "RDB$TYPE"), col(11, "RDB$TYPE_NAME"), col(11, "RDB$DESCRIPTION"), col(11, "RDB$SYSTEM_FLAG"));
    for (row, (field, value, name)) in rows.iter().zip(WANT_TYPES) {
        assert_eq!(text(&row[c_field]).unwrap(), *field);
        assert_eq!(int(&row[c_type]).unwrap(), *value);
        assert_eq!(text(&row[c_name]).unwrap(), *name);
        assert!(row[c_desc] == Value::Null, "TYPES description stays NULL");
        assert_eq!(int(&row[c_flag]).unwrap(), 1);
    }
}

#[test]
fn charsets_match_oracle() {
    let file = fresh_remaining();
    let rows = read_all_rows(&file, PS, 28);
    assert_eq!(rows.len(), WANT_CHARSETS.len(), "RDB$CHARACTER_SETS row count");
    for (row, (name, id, max_bytes, class)) in rows.iter().zip(WANT_CHARSETS) {
        assert_eq!(text(&row[col(28, "RDB$CHARACTER_SET_NAME")]).unwrap(), *name);
        assert_eq!(int(&row[col(28, "RDB$CHARACTER_SET_ID")]).unwrap(), *id);
        assert_eq!(int(&row[col(28, "RDB$BYTES_PER_CHARACTER")]).unwrap(), *max_bytes);
        assert_eq!(text(&row[col(28, "RDB$SECURITY_CLASS")]).unwrap(), *class);
        assert_eq!(text(&row[col(28, "RDB$SCHEMA_NAME")]).unwrap(), "SYSTEM");
        assert_eq!(text(&row[col(28, "RDB$OWNER_NAME")]).unwrap(), "SYSDBA");
        assert_eq!(text(&row[col(28, "RDB$DEFAULT_COLLATE_NAME")]).unwrap(), *name);
        assert_eq!(text(&row[col(28, "RDB$DEFAULT_COLLATE_SCHEMA_NAME")]).unwrap(), "SYSTEM");
        assert_eq!(int(&row[col(28, "RDB$SYSTEM_FLAG")]).unwrap(), 1);
        for c in ["RDB$FORM_OF_USE", "RDB$NUMBER_OF_CHARACTERS", "RDB$DESCRIPTION", "RDB$FUNCTION_NAME"] {
            assert!(row[col(28, c)] == Value::Null, "{c} stays NULL");
        }
    }
    // the intl replay opens at SQL$250
    assert!(WANT_CHARSETS[0].3 == "SQL$250");
    assert_eq!(INTL_FIRST_CLASS, 250);
    assert_eq!(INTL_CLASSES_RESERVED, 201);
}

#[test]
fn collations_match_oracle() {
    let file = fresh_remaining();
    let rows = read_all_rows(&file, PS, 29);
    assert_eq!(rows.len(), WANT_COLLATIONS.len(), "RDB$COLLATIONS row count");
    for (row, (name, cs, id, attrs, base, specific, class)) in rows.iter().zip(WANT_COLLATIONS) {
        assert_eq!(text(&row[col(29, "RDB$COLLATION_NAME")]).unwrap(), *name);
        assert_eq!(int(&row[col(29, "RDB$CHARACTER_SET_ID")]).unwrap(), *cs);
        assert_eq!(int(&row[col(29, "RDB$COLLATION_ID")]).unwrap(), *id);
        assert_eq!(int(&row[col(29, "RDB$COLLATION_ATTRIBUTES")]).unwrap(), *attrs);
        assert_eq!(text(&row[col(29, "RDB$BASE_COLLATION_NAME")]), *base);
        assert_eq!(text(&row[col(29, "RDB$SECURITY_CLASS")]).unwrap(), *class);
        assert_eq!(text(&row[col(29, "RDB$SCHEMA_NAME")]).unwrap(), "SYSTEM");
        assert_eq!(text(&row[col(29, "RDB$OWNER_NAME")]).unwrap(), "SYSDBA");
        assert_eq!(int(&row[col(29, "RDB$SYSTEM_FLAG")]).unwrap(), 1);
        match (blob(&row[col(29, "RDB$SPECIFIC_ATTRIBUTES")]), specific) {
            (None, None) => {}
            (Some((r, n)), Some(want)) => {
                assert_eq!(r, 29);
                assert_eq!(blob_text(&file, r, n), *want);
                assert_eq!(blob_header(&blob_slot(&file, r, n)), (1, 4), "specific attrs are metadata text");
            }
            (got, want) => panic!("specific attrs for {name}: got {got:?}, want {want:?}"),
        }
    }
}

#[test]
fn packages_match_oracle() {
    let file = fresh_remaining();
    let pkgs = read_all_rows(&file, PS, 42);
    assert_eq!(pkgs.len(), WANT_PACKAGES.len());
    for (row, (name, class, id)) in pkgs.iter().zip(WANT_PACKAGES) {
        assert_eq!(text(&row[col(42, "RDB$PACKAGE_NAME")]).unwrap(), *name);
        assert_eq!(text(&row[col(42, "RDB$SECURITY_CLASS")]).unwrap(), *class);
        assert_eq!(int(&row[col(42, "RDB$PACKAGE_ID")]).unwrap(), *id);
        assert_eq!(text(&row[col(42, "RDB$SCHEMA_NAME")]).unwrap(), "SYSTEM");
        assert_eq!(text(&row[col(42, "RDB$OWNER_NAME")]).unwrap(), "SYSDBA");
        assert_eq!(int(&row[col(42, "RDB$SYSTEM_FLAG")]).unwrap(), 1);
        assert_eq!(int(&row[col(42, "RDB$VALID_BODY_FLAG")]).unwrap(), 1);
    }
    let procs = read_all_rows(&file, PS, 26);
    assert_eq!(procs.len(), WANT_PROCEDURES.len());
    for (row, (pkg, name, id, inputs, outputs, ptype)) in procs.iter().zip(WANT_PROCEDURES) {
        assert_eq!(text(&row[col(26, "RDB$PACKAGE_NAME")]).unwrap(), *pkg);
        assert_eq!(text(&row[col(26, "RDB$PROCEDURE_NAME")]).unwrap(), *name);
        assert_eq!(int(&row[col(26, "RDB$PROCEDURE_ID")]).unwrap(), *id);
        assert_eq!(int(&row[col(26, "RDB$PROCEDURE_INPUTS")]).unwrap(), *inputs);
        assert_eq!(int(&row[col(26, "RDB$PROCEDURE_OUTPUTS")]).unwrap(), *outputs);
        assert_eq!(int(&row[col(26, "RDB$PROCEDURE_TYPE")]).unwrap(), *ptype);
        assert_eq!(text(&row[col(26, "RDB$SCHEMA_NAME")]).unwrap(), "SYSTEM");
        assert_eq!(text(&row[col(26, "RDB$OWNER_NAME")]).unwrap(), "SYSDBA");
        assert_eq!(int(&row[col(26, "RDB$SYSTEM_FLAG")]).unwrap(), 1);
        assert_eq!(int(&row[col(26, "RDB$PRIVATE_FLAG")]).unwrap(), 0);
        assert_eq!(int(&row[col(26, "RDB$VALID_BLR")]).unwrap(), 1);
        assert_eq!(text(&row[col(26, "RDB$ENGINE_NAME")]).unwrap(), "SYSTEM");
    }
    let params = read_all_rows(&file, PS, 27);
    assert_eq!(params.len(), WANT_PROC_PARAMS.len());
    for (row, (pkg, proc, name, num, ptype, source, null_flag, src, val)) in params.iter().zip(WANT_PROC_PARAMS) {
        assert_eq!(text(&row[col(27, "RDB$PACKAGE_NAME")]).unwrap(), *pkg);
        assert_eq!(text(&row[col(27, "RDB$PROCEDURE_NAME")]).unwrap(), *proc);
        assert_eq!(text(&row[col(27, "RDB$PARAMETER_NAME")]).unwrap(), *name);
        assert_eq!(int(&row[col(27, "RDB$PARAMETER_NUMBER")]).unwrap(), *num);
        assert_eq!(int(&row[col(27, "RDB$PARAMETER_TYPE")]).unwrap(), *ptype);
        assert_eq!(text(&row[col(27, "RDB$FIELD_SOURCE")]).unwrap(), *source);
        assert_eq!(int(&row[col(27, "RDB$NULL_FLAG")]).unwrap(), *null_flag);
        assert_eq!(int(&row[col(27, "RDB$PARAMETER_MECHANISM")]).unwrap(), 0);
        assert_eq!(text(&row[col(27, "RDB$FIELD_SOURCE_SCHEMA_NAME")]).unwrap(), "SYSTEM");
        match (blob(&row[col(27, "RDB$DEFAULT_SOURCE")]), src) {
            (None, None) => {}
            (Some((r, n)), Some(want)) => {
                assert_eq!(blob_text(&file, r, n), *want);
                assert_eq!(blob_header(&blob_slot(&file, r, n)), (1, 4));
            }
            (got, want) => panic!("default source for {proc}.{name}: got {got:?}, want {want:?}"),
        }
        match (blob(&row[col(27, "RDB$DEFAULT_VALUE")]), val) {
            (None, None) => {}
            (Some((r, n)), Some(want)) => {
                assert_eq!(blob_hex(&file, r, n), *want);
                assert_eq!(blob_header(&blob_slot(&file, r, n)), (2, 1));
            }
            (got, want) => panic!("default value for {proc}.{name}: got {got:?}, want {want:?}"),
        }
    }
    let funs = read_all_rows(&file, PS, 14);
    assert_eq!(funs.len(), WANT_FUNCTIONS.len());
    for (row, (pkg, name, id)) in funs.iter().zip(WANT_FUNCTIONS) {
        assert_eq!(text(&row[col(14, "RDB$PACKAGE_NAME")]).unwrap(), *pkg);
        assert_eq!(text(&row[col(14, "RDB$FUNCTION_NAME")]).unwrap(), *name);
        assert_eq!(int(&row[col(14, "RDB$FUNCTION_ID")]).unwrap(), *id);
        assert_eq!(text(&row[col(14, "RDB$SCHEMA_NAME")]).unwrap(), "SYSTEM");
        assert_eq!(text(&row[col(14, "RDB$OWNER_NAME")]).unwrap(), "SYSDBA");
        assert_eq!(int(&row[col(14, "RDB$SYSTEM_FLAG")]).unwrap(), 1);
        assert_eq!(int(&row[col(14, "RDB$RETURN_ARGUMENT")]).unwrap(), 0);
        assert_eq!(int(&row[col(14, "RDB$PRIVATE_FLAG")]).unwrap(), 0);
        assert_eq!(int(&row[col(14, "RDB$VALID_BLR")]).unwrap(), 1);
        assert_eq!(text(&row[col(14, "RDB$ENGINE_NAME")]).unwrap(), "SYSTEM");
    }
    let args = read_all_rows(&file, PS, 15);
    assert_eq!(args.len(), WANT_FUNC_ARGS.len());
    for (row, (pkg, fun, pos, name, source, null_flag, src, val)) in args.iter().zip(WANT_FUNC_ARGS) {
        assert_eq!(text(&row[col(15, "RDB$PACKAGE_NAME")]).unwrap(), *pkg);
        assert_eq!(text(&row[col(15, "RDB$FUNCTION_NAME")]).unwrap(), *fun);
        assert_eq!(int(&row[col(15, "RDB$ARGUMENT_POSITION")]).unwrap(), *pos);
        assert_eq!(text(&row[col(15, "RDB$ARGUMENT_NAME")]), *name);
        assert_eq!(text(&row[col(15, "RDB$FIELD_SOURCE")]).unwrap(), *source);
        assert_eq!(int(&row[col(15, "RDB$NULL_FLAG")]).unwrap(), *null_flag);
        match (blob(&row[col(15, "RDB$DEFAULT_SOURCE")]), src) {
            (None, None) => {}
            (Some((r, n)), Some(want)) => assert_eq!(blob_text(&file, r, n), *want),
            (got, want) => panic!("default source for {fun} arg {pos}: got {got:?}, want {want:?}"),
        }
        match (blob(&row[col(15, "RDB$DEFAULT_VALUE")]), val) {
            (None, None) => {}
            (Some((r, n)), Some(want)) => assert_eq!(blob_hex(&file, r, n), *want),
            (got, want) => panic!("default value for {fun} arg {pos}: got {got:?}, want {want:?}"),
        }
    }
    let consts = read_all_rows(&file, PS, 59);
    assert_eq!(consts.len(), WANT_CONSTANTS.len());
    for (row, (pkg, name, source, vsrc, vblr)) in consts.iter().zip(WANT_CONSTANTS) {
        assert_eq!(text(&row[col(59, "RDB$PACKAGE_NAME")]).unwrap(), *pkg);
        assert_eq!(text(&row[col(59, "RDB$CONSTANT_NAME")]).unwrap(), *name);
        assert_eq!(text(&row[col(59, "RDB$FIELD_SOURCE")]).unwrap(), *source);
        assert_eq!(int(&row[col(59, "RDB$PRIVATE_FLAG")]).unwrap(), 0);
        assert_eq!(text(&row[col(59, "RDB$SCHEMA_NAME")]).unwrap(), "SYSTEM");
        let (r, n) = blob(&row[col(59, "RDB$CONSTANT_SOURCE")]).unwrap();
        assert_eq!(blob_text(&file, r, n), *vsrc);
        assert_eq!(blob_header(&blob_slot(&file, r, n)), (1, 4));
        let (r, n) = blob(&row[col(59, "RDB$CONSTANT_BLR")]).unwrap();
        assert_eq!(blob_hex(&file, r, n), *vblr);
        assert_eq!(blob_header(&blob_slot(&file, r, n)), (2, 1));
    }
}

#[test]
fn publication_and_role_match_oracle() {
    let file = fresh_remaining();
    let pubs = read_all_rows(&file, PS, 51);
    assert_eq!(pubs.len(), 1);
    assert_eq!(text(&pubs[0][col(51, "RDB$PUBLICATION_NAME")]).unwrap(), DEFAULT_PUBLICATION);
    assert_eq!(text(&pubs[0][col(51, "RDB$OWNER_NAME")]).unwrap(), "SYSDBA");
    assert_eq!(int(&pubs[0][col(51, "RDB$SYSTEM_FLAG")]).unwrap(), 1);
    assert_eq!(int(&pubs[0][col(51, "RDB$ACTIVE_FLAG")]).unwrap(), 0);
    assert_eq!(int(&pubs[0][col(51, "RDB$AUTO_ENABLE")]).unwrap(), 0);
    let roles = read_all_rows(&file, PS, 31);
    assert_eq!(roles.len(), 1);
    assert_eq!(text(&roles[0][col(31, "RDB$ROLE_NAME")]).unwrap(), ADMIN_ROLE);
    assert_eq!(text(&roles[0][col(31, "RDB$OWNER_NAME")]).unwrap(), "SYSDBA");
    assert_eq!(text(&roles[0][col(31, "RDB$SECURITY_CLASS")]).unwrap(), "SQL$468");
    assert_eq!(int(&roles[0][col(31, "RDB$SYSTEM_FLAG")]).unwrap(), 1);
    assert!(roles[0][col(31, "RDB$DESCRIPTION")] == Value::Null);
    // the 0xff mask: the decoder maps each byte to U+00FF
    match &roles[0][col(31, "RDB$SYSTEM_PRIVILEGES")] {
        Value::Text(s) => assert_eq!(s, &"\u{ff}".repeat(8)),
        v => panic!("expected privilege mask text, got {v:?}"),
    }
}

#[test]
fn privilege_inventory() {
    let file = fresh_remaining();
    let rows = read_all_rows(&file, PS, 18);
    // 1244 on the oracle, whose owner (MARIUZ) takes a second role
    // grant beside SYSDBA's; this pipeline's owner IS SYSDBA.
    assert_eq!(rows.len(), 1243, "RDB$USER_PRIVILEGES total");
    let (c_user, c_priv, c_grant, c_obj, c_field, c_ut, c_ot, c_schema, c_grantor) = (
        col(18, "RDB$USER"),
        col(18, "RDB$PRIVILEGE"),
        col(18, "RDB$GRANT_OPTION"),
        col(18, "RDB$RELATION_NAME"),
        col(18, "RDB$FIELD_NAME"),
        col(18, "RDB$USER_TYPE"),
        col(18, "RDB$OBJECT_TYPE"),
        col(18, "RDB$RELATION_SCHEMA_NAME"),
        col(18, "RDB$GRANTOR"),
    );
    let count = |ot: i64, priv_c: &str| {
        rows.iter()
            .filter(|r| int(&r[c_ot]).unwrap() == ot && text(&r[c_priv]).unwrap() == priv_c)
            .count()
    };
    assert_eq!(count(11, "G"), 104, "charset USAGE grants");
    assert_eq!(count(17, "G"), 298, "collation USAGE grants");
    assert_eq!(count(18, "X"), 8, "package EXECUTE grants");
    assert_eq!(count(18, "U"), 8, "package USAGE grants");
    // DDL: 15 objects times CLO (38 is schemas, not a DDL object)
    let ddl: Vec<_> =
        rows.iter().filter(|r| matches!(int(&r[c_ot]).unwrap(), 22..=34 | 36 | 39)).collect();
    assert_eq!(ddl.len(), 45);
    for r in &ddl {
        assert_eq!(text(&r[c_user]).unwrap(), "SYSDBA");
        assert_eq!(int(&r[c_grant]).unwrap(), 0);
        assert_eq!(int(&r[c_ut]).unwrap(), 8);
        assert!(r[c_field] == Value::Null);
    }
    // the additional grants: SIUDR per privilege-user, user_type 20
    for (user, rel_name) in ADDITIONAL_GRANTS {
        for priv_c in ["S", "I", "U", "D", "R"] {
            let hits: Vec<_> = rows
                .iter()
                .filter(|r| {
                    text(&r[c_user]).unwrap() == *user
                        && text(&r[c_obj]).unwrap() == *rel_name
                        && text(&r[c_priv]).unwrap() == priv_c
                })
                .collect();
            assert_eq!(hits.len(), 1, "{user}/{rel_name}/{priv_c}");
            assert_eq!(int(&hits[0][c_grant]).unwrap(), 0);
            assert_eq!(int(&hits[0][c_ut]).unwrap(), 20);
            assert_eq!(int(&hits[0][c_ot]).unwrap(), 0);
            assert_eq!(text(&hits[0][c_schema]).unwrap(), "SYSTEM");
        }
    }
    // the role membership: owner SYSDBA means SYSDBA alone
    let members: Vec<_> = rows.iter().filter(|r| int(&r[c_ot]).unwrap() == 13).collect();
    assert_eq!(members.len(), 1);
    assert_eq!(text(&members[0][c_user]).unwrap(), "SYSDBA");
    assert_eq!(text(&members[0][c_priv]).unwrap(), "M");
    assert_eq!(int(&members[0][c_grant]).unwrap(), 2);
    assert_eq!(text(&members[0][c_field]).unwrap(), "D");
    assert_eq!(text(&members[0][c_obj]).unwrap(), ADMIN_ROLE);
    assert!(members[0][c_schema] == Value::Null);
    assert!(members[0][c_grantor] == Value::Null);
}

#[test]
fn class_numbering_and_acl_bytes() {
    let file = fresh_remaining();
    let rows = read_all_rows(&file, PS, 9);
    assert_eq!(rows.len(), 554, "RDB$SECURITY_CLASSES total");
    let (c_name, c_acl) = (col(9, "RDB$SECURITY_CLASS"), col(9, "RDB$ACL"));
    let names: Vec<String> = rows.iter().map(|r| text(&r[c_name]).unwrap().to_string()).collect();
    for n in 1..=468u32 {
        assert!(names.contains(&format!("SQL${n}")), "SQL${n} present");
    }
    for n in 1..=60u32 {
        assert!(names.contains(&format!("SQL$DEFAULT{n}")), "SQL$DEFAULT{n} present");
    }
    let ddl_names: Vec<String> =
        names.iter().filter(|n| n.starts_with("SQL$D") && !n.starts_with("SQL$DEFAULT")).cloned().collect();
    assert_eq!(ddl_names, WANT_DDL_CLASSES, "DDL classes in file order");
    let acl_of = |name: &str| {
        let row = rows.iter().find(|r| text(&r[c_name]).unwrap() == name).unwrap();
        let (rel, num) = blob(&row[c_acl]).unwrap();
        assert_eq!(rel, 9);
        let slot = blob_slot(&file, rel, num);
        assert_eq!(blob_header(&slot), (3, 1), "{name} ACL blob header");
        read_blob_content(&file, PS, rel, num).unwrap()
    };
    assert_eq!(acl_of("SQL$250"), nonrelation_acl("SYSDBA", false));
    assert_eq!(acl_of("SQL$450"), nonrelation_acl("SYSDBA", false));
    assert_eq!(acl_of("SQL$464"), nonrelation_acl("SYSDBA", true));
    assert_eq!(acl_of("SQL$468"), role_acl("SYSDBA"));
    assert_eq!(acl_of("SQL$D22PUBLIC"), ddl_acl("SYSDBA"));
    assert_eq!(acl_of("SQL$D30"), ddl_acl("SYSDBA"));
    assert_eq!(acl_of("SQL$DATABASE"), ddl_acl("SYSDBA"));
    // the GRANT_privileges recomputations
    assert_eq!(acl_of("SQL$12"), grant_relation_acl("SYSDBA", "3"));
    assert_eq!(acl_of("SQL$DEFAULT12"), grant_relation_acl("SYSDBA", "3"));
    assert_eq!(acl_of("SQL$33"), grant_relation_acl("SYSDBA", "4"));
    assert_eq!(acl_of("SQL$DEFAULT33"), grant_relation_acl("SYSDBA", "4"));
    assert_eq!(acl_of("SQL$48"), grant_relation_acl("SYSDBA", "22"));
    assert_eq!(acl_of("SQL$DEFAULT48"), grant_relation_acl("SYSDBA", "22"));
}

#[test]
fn acl_builders_match_engine_bytes() {
    // the oracle's MARIUZ bytes with the owner swapped (both 6 chars)
    assert_eq!(hex(&role_acl("SYSDBA")), "0201030653595344424100020106030c0000");
    assert_eq!(
        hex(&grant_relation_acl("SYSDBA", "3")),
        "020103065359534442410002060103070908040a00010f01330002070908040a00010002040000"
    );
    assert_eq!(
        hex(&grant_relation_acl("SYSDBA", "22")),
        "020103065359534442410002060103070908040a00010f0232320002070908040a00010002040000"
    );
}

#[test]
fn generator_end_values() {
    let file = fresh_remaining();
    let want = [13, 468, 60, 12, 0, 0, 0, 0, 0, 0, 7, 0, 4, 128];
    for (id, value) in want.iter().enumerate() {
        assert_eq!(fire_crab_ods::gen::read(&file, PS, id as i64), *value, "generator {id}");
    }
}

#[test]
fn admin_role_grants_pair_when_owner_differs() {
    let bytes = format_skeleton(PS, &[7u8; 16], (61318, 450070090));
    let mut file = Image::from_bytes(&bytes, PS);
    create_system_storage(&mut file, PS).unwrap();
    let mut alloc = store_core_catalog(&mut file, PS, "MARIUZ").unwrap();
    store_system_indexes(&mut file, PS).unwrap();
    store_runtime_blobs(&mut file, PS).unwrap();
    store_remaining_catalog(&mut file, PS, "MARIUZ", &mut alloc).unwrap();
    let rows = read_all_rows(&file, PS, 18);
    let members: Vec<_> =
        rows.iter().filter(|r| int(&r[col(18, "RDB$OBJECT_TYPE")]).unwrap() == 13).collect();
    assert_eq!(members.len(), 2);
    assert_eq!(text(&members[0][col(18, "RDB$USER")]).unwrap(), "SYSDBA");
    assert_eq!(text(&members[1][col(18, "RDB$USER")]).unwrap(), "MARIUZ");
}

