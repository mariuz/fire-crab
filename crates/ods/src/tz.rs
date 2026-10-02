//! Time-zone ids, converted from `TimeZoneUtil` (src/common/
//! TimeZoneUtil.cpp) and the generated zone list (src/common/
//! TimeZones.h, tzdata 2026c). Two id families:
//!
//!   - OFFSET zones: id <= 2878 (`isOffset`, TimeZoneUtil.cpp:1157);
//!     displacement minutes = id - 1439 (ONE_DAY = 24*60 - 1,
//!     TimeZoneUtil.cpp:301 - NOT 1440, an off-by-one the render
//!     differential caught immediately), formatted +HH:MM
//!     (TimeZoneUtil.cpp:565-573). Fully convertible - local time =
//!     UTC + displacement.
//!   - NAMED zones: ids count DOWN from 65535 (GMT); the name is
//!     `BUILTIN_TIME_ZONE_LIST[65535 - id]`. Converting these needs
//!     the IANA tzdata rules (the engine links ICU) - fire-crab knows
//!     the NAMES but not the rules, so only GMT (displacement 0) is
//!     converted; other named zones must be rendered visibly
//!     unconverted, never silently wrong.
//!
//! THE RULES NOW COME FROM THE HOST'S TZif FILES ([displacement_at]):
//! the IANA compiled zoneinfo (`$TZDIR`, else /usr/share/zoneinfo -
//! RFC 8536), which is the same tzdata the engine's ICU carries in its
//! own format. UTC -> local is a lookup (one instant has one offset)
//! ([displacement_at]); local -> UTC, where a wall time can fall in a gap
//! or an overlap, resolves both as the engine does ([wall_displacement]).
//! A zone with no file stays unconverted, as before. A TIME WITH TIME
//! ZONE in a region is neither: the engine dates it by a reference day
//! this crate does not model, and its callers refuse.

/// `BUILTIN_TIME_ZONE_LIST` (TimeZones.h): index i = zone id 65535 - i.
const TIME_ZONE_LIST: &[&str] = &[
    "GMT", "ACT", "AET", "AGT",
    "ART", "AST", "Africa/Abidjan", "Africa/Accra",
    "Africa/Addis_Ababa", "Africa/Algiers", "Africa/Asmara", "Africa/Asmera",
    "Africa/Bamako", "Africa/Bangui", "Africa/Banjul", "Africa/Bissau",
    "Africa/Blantyre", "Africa/Brazzaville", "Africa/Bujumbura", "Africa/Cairo",
    "Africa/Casablanca", "Africa/Ceuta", "Africa/Conakry", "Africa/Dakar",
    "Africa/Dar_es_Salaam", "Africa/Djibouti", "Africa/Douala", "Africa/El_Aaiun",
    "Africa/Freetown", "Africa/Gaborone", "Africa/Harare", "Africa/Johannesburg",
    "Africa/Juba", "Africa/Kampala", "Africa/Khartoum", "Africa/Kigali",
    "Africa/Kinshasa", "Africa/Lagos", "Africa/Libreville", "Africa/Lome",
    "Africa/Luanda", "Africa/Lubumbashi", "Africa/Lusaka", "Africa/Malabo",
    "Africa/Maputo", "Africa/Maseru", "Africa/Mbabane", "Africa/Mogadishu",
    "Africa/Monrovia", "Africa/Nairobi", "Africa/Ndjamena", "Africa/Niamey",
    "Africa/Nouakchott", "Africa/Ouagadougou", "Africa/Porto-Novo", "Africa/Sao_Tome",
    "Africa/Timbuktu", "Africa/Tripoli", "Africa/Tunis", "Africa/Windhoek",
    "America/Adak", "America/Anchorage", "America/Anguilla", "America/Antigua",
    "America/Araguaina", "America/Argentina/Buenos_Aires", "America/Argentina/Catamarca", "America/Argentina/ComodRivadavia",
    "America/Argentina/Cordoba", "America/Argentina/Jujuy", "America/Argentina/La_Rioja", "America/Argentina/Mendoza",
    "America/Argentina/Rio_Gallegos", "America/Argentina/Salta", "America/Argentina/San_Juan", "America/Argentina/San_Luis",
    "America/Argentina/Tucuman", "America/Argentina/Ushuaia", "America/Aruba", "America/Asuncion",
    "America/Atikokan", "America/Atka", "America/Bahia", "America/Bahia_Banderas",
    "America/Barbados", "America/Belem", "America/Belize", "America/Blanc-Sablon",
    "America/Boa_Vista", "America/Bogota", "America/Boise", "America/Buenos_Aires",
    "America/Cambridge_Bay", "America/Campo_Grande", "America/Cancun", "America/Caracas",
    "America/Catamarca", "America/Cayenne", "America/Cayman", "America/Chicago",
    "America/Chihuahua", "America/Coral_Harbour", "America/Cordoba", "America/Costa_Rica",
    "America/Creston", "America/Cuiaba", "America/Curacao", "America/Danmarkshavn",
    "America/Dawson", "America/Dawson_Creek", "America/Denver", "America/Detroit",
    "America/Dominica", "America/Edmonton", "America/Eirunepe", "America/El_Salvador",
    "America/Ensenada", "America/Fort_Nelson", "America/Fort_Wayne", "America/Fortaleza",
    "America/Glace_Bay", "America/Godthab", "America/Goose_Bay", "America/Grand_Turk",
    "America/Grenada", "America/Guadeloupe", "America/Guatemala", "America/Guayaquil",
    "America/Guyana", "America/Halifax", "America/Havana", "America/Hermosillo",
    "America/Indiana/Indianapolis", "America/Indiana/Knox", "America/Indiana/Marengo", "America/Indiana/Petersburg",
    "America/Indiana/Tell_City", "America/Indiana/Vevay", "America/Indiana/Vincennes", "America/Indiana/Winamac",
    "America/Indianapolis", "America/Inuvik", "America/Iqaluit", "America/Jamaica",
    "America/Jujuy", "America/Juneau", "America/Kentucky/Louisville", "America/Kentucky/Monticello",
    "America/Knox_IN", "America/Kralendijk", "America/La_Paz", "America/Lima",
    "America/Los_Angeles", "America/Louisville", "America/Lower_Princes", "America/Maceio",
    "America/Managua", "America/Manaus", "America/Marigot", "America/Martinique",
    "America/Matamoros", "America/Mazatlan", "America/Mendoza", "America/Menominee",
    "America/Merida", "America/Metlakatla", "America/Mexico_City", "America/Miquelon",
    "America/Moncton", "America/Monterrey", "America/Montevideo", "America/Montreal",
    "America/Montserrat", "America/Nassau", "America/New_York", "America/Nipigon",
    "America/Nome", "America/Noronha", "America/North_Dakota/Beulah", "America/North_Dakota/Center",
    "America/North_Dakota/New_Salem", "America/Ojinaga", "America/Panama", "America/Pangnirtung",
    "America/Paramaribo", "America/Phoenix", "America/Port-au-Prince", "America/Port_of_Spain",
    "America/Porto_Acre", "America/Porto_Velho", "America/Puerto_Rico", "America/Punta_Arenas",
    "America/Rainy_River", "America/Rankin_Inlet", "America/Recife", "America/Regina",
    "America/Resolute", "America/Rio_Branco", "America/Rosario", "America/Santa_Isabel",
    "America/Santarem", "America/Santiago", "America/Santo_Domingo", "America/Sao_Paulo",
    "America/Scoresbysund", "America/Shiprock", "America/Sitka", "America/St_Barthelemy",
    "America/St_Johns", "America/St_Kitts", "America/St_Lucia", "America/St_Thomas",
    "America/St_Vincent", "America/Swift_Current", "America/Tegucigalpa", "America/Thule",
    "America/Thunder_Bay", "America/Tijuana", "America/Toronto", "America/Tortola",
    "America/Vancouver", "America/Virgin", "America/Whitehorse", "America/Winnipeg",
    "America/Yakutat", "America/Yellowknife", "Antarctica/Casey", "Antarctica/Davis",
    "Antarctica/DumontDUrville", "Antarctica/Macquarie", "Antarctica/Mawson", "Antarctica/McMurdo",
    "Antarctica/Palmer", "Antarctica/Rothera", "Antarctica/South_Pole", "Antarctica/Syowa",
    "Antarctica/Troll", "Antarctica/Vostok", "Arctic/Longyearbyen", "Asia/Aden",
    "Asia/Almaty", "Asia/Amman", "Asia/Anadyr", "Asia/Aqtau",
    "Asia/Aqtobe", "Asia/Ashgabat", "Asia/Ashkhabad", "Asia/Atyrau",
    "Asia/Baghdad", "Asia/Bahrain", "Asia/Baku", "Asia/Bangkok",
    "Asia/Barnaul", "Asia/Beirut", "Asia/Bishkek", "Asia/Brunei",
    "Asia/Calcutta", "Asia/Chita", "Asia/Choibalsan", "Asia/Chongqing",
    "Asia/Chungking", "Asia/Colombo", "Asia/Dacca", "Asia/Damascus",
    "Asia/Dhaka", "Asia/Dili", "Asia/Dubai", "Asia/Dushanbe",
    "Asia/Famagusta", "Asia/Gaza", "Asia/Harbin", "Asia/Hebron",
    "Asia/Ho_Chi_Minh", "Asia/Hong_Kong", "Asia/Hovd", "Asia/Irkutsk",
    "Asia/Istanbul", "Asia/Jakarta", "Asia/Jayapura", "Asia/Jerusalem",
    "Asia/Kabul", "Asia/Kamchatka", "Asia/Karachi", "Asia/Kashgar",
    "Asia/Kathmandu", "Asia/Katmandu", "Asia/Khandyga", "Asia/Kolkata",
    "Asia/Krasnoyarsk", "Asia/Kuala_Lumpur", "Asia/Kuching", "Asia/Kuwait",
    "Asia/Macao", "Asia/Macau", "Asia/Magadan", "Asia/Makassar",
    "Asia/Manila", "Asia/Muscat", "Asia/Nicosia", "Asia/Novokuznetsk",
    "Asia/Novosibirsk", "Asia/Omsk", "Asia/Oral", "Asia/Phnom_Penh",
    "Asia/Pontianak", "Asia/Pyongyang", "Asia/Qatar", "Asia/Qyzylorda",
    "Asia/Rangoon", "Asia/Riyadh", "Asia/Saigon", "Asia/Sakhalin",
    "Asia/Samarkand", "Asia/Seoul", "Asia/Shanghai", "Asia/Singapore",
    "Asia/Srednekolymsk", "Asia/Taipei", "Asia/Tashkent", "Asia/Tbilisi",
    "Asia/Tehran", "Asia/Tel_Aviv", "Asia/Thimbu", "Asia/Thimphu",
    "Asia/Tokyo", "Asia/Tomsk", "Asia/Ujung_Pandang", "Asia/Ulaanbaatar",
    "Asia/Ulan_Bator", "Asia/Urumqi", "Asia/Ust-Nera", "Asia/Vientiane",
    "Asia/Vladivostok", "Asia/Yakutsk", "Asia/Yangon", "Asia/Yekaterinburg",
    "Asia/Yerevan", "Atlantic/Azores", "Atlantic/Bermuda", "Atlantic/Canary",
    "Atlantic/Cape_Verde", "Atlantic/Faeroe", "Atlantic/Faroe", "Atlantic/Jan_Mayen",
    "Atlantic/Madeira", "Atlantic/Reykjavik", "Atlantic/South_Georgia", "Atlantic/St_Helena",
    "Atlantic/Stanley", "Australia/ACT", "Australia/Adelaide", "Australia/Brisbane",
    "Australia/Broken_Hill", "Australia/Canberra", "Australia/Currie", "Australia/Darwin",
    "Australia/Eucla", "Australia/Hobart", "Australia/LHI", "Australia/Lindeman",
    "Australia/Lord_Howe", "Australia/Melbourne", "Australia/NSW", "Australia/North",
    "Australia/Perth", "Australia/Queensland", "Australia/South", "Australia/Sydney",
    "Australia/Tasmania", "Australia/Victoria", "Australia/West", "Australia/Yancowinna",
    "BET", "BST", "Brazil/Acre", "Brazil/DeNoronha",
    "Brazil/East", "Brazil/West", "CAT", "CET",
    "CNT", "CST", "CST6CDT", "CTT",
    "Canada/Atlantic", "Canada/Central", "Canada/East-Saskatchewan", "Canada/Eastern",
    "Canada/Mountain", "Canada/Newfoundland", "Canada/Pacific", "Canada/Saskatchewan",
    "Canada/Yukon", "Chile/Continental", "Chile/EasterIsland", "Cuba",
    "EAT", "ECT", "EET", "EST",
    "EST5EDT", "Egypt", "Eire", "Etc/GMT",
    "Etc/GMT+0", "Etc/GMT+1", "Etc/GMT+10", "Etc/GMT+11",
    "Etc/GMT+12", "Etc/GMT+2", "Etc/GMT+3", "Etc/GMT+4",
    "Etc/GMT+5", "Etc/GMT+6", "Etc/GMT+7", "Etc/GMT+8",
    "Etc/GMT+9", "Etc/GMT-0", "Etc/GMT-1", "Etc/GMT-10",
    "Etc/GMT-11", "Etc/GMT-12", "Etc/GMT-13", "Etc/GMT-14",
    "Etc/GMT-2", "Etc/GMT-3", "Etc/GMT-4", "Etc/GMT-5",
    "Etc/GMT-6", "Etc/GMT-7", "Etc/GMT-8", "Etc/GMT-9",
    "Etc/GMT0", "Etc/Greenwich", "Etc/UCT", "Etc/UTC",
    "Etc/Universal", "Etc/Zulu", "Europe/Amsterdam", "Europe/Andorra",
    "Europe/Astrakhan", "Europe/Athens", "Europe/Belfast", "Europe/Belgrade",
    "Europe/Berlin", "Europe/Bratislava", "Europe/Brussels", "Europe/Bucharest",
    "Europe/Budapest", "Europe/Busingen", "Europe/Chisinau", "Europe/Copenhagen",
    "Europe/Dublin", "Europe/Gibraltar", "Europe/Guernsey", "Europe/Helsinki",
    "Europe/Isle_of_Man", "Europe/Istanbul", "Europe/Jersey", "Europe/Kaliningrad",
    "Europe/Kiev", "Europe/Kirov", "Europe/Lisbon", "Europe/Ljubljana",
    "Europe/London", "Europe/Luxembourg", "Europe/Madrid", "Europe/Malta",
    "Europe/Mariehamn", "Europe/Minsk", "Europe/Monaco", "Europe/Moscow",
    "Europe/Nicosia", "Europe/Oslo", "Europe/Paris", "Europe/Podgorica",
    "Europe/Prague", "Europe/Riga", "Europe/Rome", "Europe/Samara",
    "Europe/San_Marino", "Europe/Sarajevo", "Europe/Saratov", "Europe/Simferopol",
    "Europe/Skopje", "Europe/Sofia", "Europe/Stockholm", "Europe/Tallinn",
    "Europe/Tirane", "Europe/Tiraspol", "Europe/Ulyanovsk", "Europe/Uzhgorod",
    "Europe/Vaduz", "Europe/Vatican", "Europe/Vienna", "Europe/Vilnius",
    "Europe/Volgograd", "Europe/Warsaw", "Europe/Zagreb", "Europe/Zaporozhye",
    "Europe/Zurich", "Factory", "GB", "GB-Eire",
    "GMT+0", "GMT-0", "GMT0", "Greenwich",
    "HST", "Hongkong", "IET", "IST",
    "Iceland", "Indian/Antananarivo", "Indian/Chagos", "Indian/Christmas",
    "Indian/Cocos", "Indian/Comoro", "Indian/Kerguelen", "Indian/Mahe",
    "Indian/Maldives", "Indian/Mauritius", "Indian/Mayotte", "Indian/Reunion",
    "Iran", "Israel", "JST", "Jamaica",
    "Japan", "Kwajalein", "Libya", "MET",
    "MIT", "MST", "MST7MDT", "Mexico/BajaNorte",
    "Mexico/BajaSur", "Mexico/General", "NET", "NST",
    "NZ", "NZ-CHAT", "Navajo", "PLT",
    "PNT", "PRC", "PRT", "PST",
    "PST8PDT", "Pacific/Apia", "Pacific/Auckland", "Pacific/Bougainville",
    "Pacific/Chatham", "Pacific/Chuuk", "Pacific/Easter", "Pacific/Efate",
    "Pacific/Enderbury", "Pacific/Fakaofo", "Pacific/Fiji", "Pacific/Funafuti",
    "Pacific/Galapagos", "Pacific/Gambier", "Pacific/Guadalcanal", "Pacific/Guam",
    "Pacific/Honolulu", "Pacific/Johnston", "Pacific/Kiritimati", "Pacific/Kosrae",
    "Pacific/Kwajalein", "Pacific/Majuro", "Pacific/Marquesas", "Pacific/Midway",
    "Pacific/Nauru", "Pacific/Niue", "Pacific/Norfolk", "Pacific/Noumea",
    "Pacific/Pago_Pago", "Pacific/Palau", "Pacific/Pitcairn", "Pacific/Pohnpei",
    "Pacific/Ponape", "Pacific/Port_Moresby", "Pacific/Rarotonga", "Pacific/Saipan",
    "Pacific/Samoa", "Pacific/Tahiti", "Pacific/Tarawa", "Pacific/Tongatapu",
    "Pacific/Truk", "Pacific/Wake", "Pacific/Wallis", "Pacific/Yap",
    "Poland", "Portugal", "ROC", "ROK",
    "SST", "Singapore", "SystemV/AST4", "SystemV/AST4ADT",
    "SystemV/CST6", "SystemV/CST6CDT", "SystemV/EST5", "SystemV/EST5EDT",
    "SystemV/HST10", "SystemV/MST7", "SystemV/MST7MDT", "SystemV/PST8",
    "SystemV/PST8PDT", "SystemV/YST9", "SystemV/YST9YDT", "Turkey",
    "UCT", "US/Alaska", "US/Aleutian", "US/Arizona",
    "US/Central", "US/East-Indiana", "US/Eastern", "US/Hawaii",
    "US/Indiana-Starke", "US/Michigan", "US/Mountain", "US/Pacific",
    "US/Pacific-New", "US/Samoa", "UTC", "Universal",
    "VST", "W-SU", "WET", "Zulu",
    "America/Nuuk", "Asia/Qostanay", "Pacific/Kanton", "Europe/Kyiv",
    "America/Ciudad_Juarez",];

/// The displacement in minutes of a zone whose conversion rules are
/// known without tzdata: offset zones, and GMT itself.
pub fn displacement(zone: u16) -> Option<i32> {
    if zone <= 2878 {
        Some(zone as i32 - 1439)
    } else if zone == 65535 {
        Some(0) // GMT
    } else {
        // the UTC-equivalent NAMED zones: their displacement is 0 by
        // definition, no tzdata rules needed (the fixed Etc/GMT+N
        // offsets ride along - tzdata's sign convention is INVERTED,
        // Etc/GMT+5 is UTC-5)
        match zone_text(zone).as_str() {
            "UTC" | "UCT" | "Universal" | "Zulu" | "GMT" | "GMT0" | "GMT+0" | "GMT-0"
            | "Greenwich" | "Etc/UTC" | "Etc/UCT" | "Etc/Universal" | "Etc/Zulu"
            | "Etc/GMT" | "Etc/GMT0" | "Etc/GMT+0" | "Etc/GMT-0" | "Etc/Greenwich" => Some(0),
            n => match n.strip_prefix("Etc/GMT+") {
                Some(h) => h.parse::<i32>().ok().filter(|h| *h <= 12).map(|h| -h * 60),
                None => n
                    .strip_prefix("Etc/GMT-")
                    .and_then(|h| h.parse::<i32>().ok())
                    .filter(|h| *h <= 14)
                    .map(|h| h * 60),
            },
        }
    }
}

/// The zone's textual form: `+HH:MM`/`-HH:MM` for offset zones, the
/// region name for named ones (TimeZoneUtil::format).
/// The id of a named zone (the engine's TimeZoneUtil numbering: 65535
/// minus its position in the list); None for a name not in the table.
pub fn zone_id(name: &str) -> Option<u16> {
    TIME_ZONE_LIST.iter().position(|n| n.eq_ignore_ascii_case(name)).map(|i| (65535 - i) as u16)
}

pub fn zone_text(zone: u16) -> String {
    if zone <= 2878 {
        let d = zone as i32 - 1439;
        format!("{}{:02}:{:02}", if d < 0 { "-" } else { "+" }, d.abs() / 60, d.abs() % 60)
    } else {
        match TIME_ZONE_LIST.get(65535 - zone as usize) {
            Some(name) => (*name).to_string(),
            None => format!("<tz {}>", zone),
        }
    }
}

/// The displacement in minutes of `zone` AT the UTC instant `date` (MJD
/// day) + `utc` (1/10000 s units). An offset zone or a UTC equivalent
/// answers [displacement] without looking; a named zone answers from its
/// TZif rules. None = no rules for this zone on this host.
pub fn displacement_at(zone: u16, date: i32, utc: u32) -> Option<i32> {
    if let Some(d) = displacement(zone) {
        return Some(d);
    }
    let secs = (date as i64 - 40587) * 86400 + (utc / 10_000) as i64;
    let rules = zone_rules(zone)?;
    // ICU's offsets are milliseconds and TimeZoneUtil divides them into
    // minutes (truncating); an LMT offset carries seconds
    Some(rules.offset_at(secs) / 60)
}

/// The displacement in minutes that places the WALL time `date` + `wall`
/// of `zone` on the UTC line - the local -> UTC direction. A wall time
/// is ambiguous twice a year, and the engine's answer (measured against
/// Europe/Bucharest, 2026) is ICU's default in both cases:
///
///   * a GAP (03:00-03:59 on 2026-03-29 does not exist) takes the offset
///     in force BEFORE the transition: 03:30 is 01:30 UTC, later than
///     04:00's 01:00 UTC;
///   * an OVERLAP (03:00-03:59 on 2026-10-25 happens twice) is the FIRST
///     occurrence: 03:30 is 00:30 UTC, at +03:00.
///
/// Offsets are compared in whole minutes, as [displacement_at] answers
/// them (1900 in Bucharest is LMT +01:44:24, and the engine places 12:00
/// at 10:16 UTC). None = no rules for this zone on this host.
pub fn wall_displacement(zone: u16, date: i32, wall: u32) -> Option<i32> {
    if let Some(d) = displacement(zone) {
        return Some(d);
    }
    let rules = zone_rules(zone)?;
    let w = (date as i64 - 40587) * 86400 + (wall / 10_000) as i64;
    let at = |u: i64| rules.offset_at(u) / 60;
    // the offsets a day either side: no zone moves twice inside 52 hours,
    // and no offset is wider than 26
    const SPAN: i64 = 26 * 3600;
    let (early, late) = (at(w - SPAN), at(w + SPAN));
    let fits = |o: i32| at(w - o as i64 * 60) == o;
    Some(match (fits(early), fits(late)) {
        // one offset, or an overlap: the earlier instant is the larger
        // offset's, which is the one in force before a fall-back
        (true, true) => early.max(late),
        (true, false) => early,
        (false, true) => late,
        // the gap: the offset before the transition
        (false, false) => early,
    })
}

/// The day a TIME WITH TIME ZONE in a named zone is placed on: 2020-01-01
/// (MJD 58849). Measured: in September the engine answers Bucharest
/// +02:00, New York -05:00 and Sydney +11:00 for a TIME - January's
/// offsets, on both hemispheres - and Sao Paulo -03:00, which rules out
/// any January before Brazil dropped DST in 2019.
pub const TIME_TZ_BASE_DATE: i32 = 58849;

/// A TIME WITH TIME ZONE's displacement: an offset zone's, or a region's
/// on [TIME_TZ_BASE_DATE] at that UTC time.
pub fn time_displacement(zone: u16, utc: u32) -> Option<i32> {
    displacement_at(zone, TIME_TZ_BASE_DATE, utc)
}

/// The local -> UTC twin of [time_displacement], for a zoneless TIME.
pub fn time_wall_displacement(zone: u16, wall: u32) -> Option<i32> {
    wall_displacement(zone, TIME_TZ_BASE_DATE, wall)
}

/// One zone's compiled rules: the transition instants, the local-time
/// type each one starts, and the POSIX footer that governs every
/// instant after the last listed transition.
struct Rules {
    at: Vec<i64>,
    idx: Vec<u8>,
    /// (UT offset seconds, is DST)
    types: Vec<(i32, bool)>,
    footer: Option<Posix>,
}

impl Rules {
    fn offset_at(&self, t: i64) -> i32 {
        if let Some(last) = self.at.last() {
            if t >= *last {
                if let Some(f) = &self.footer {
                    return f.offset_at(t);
                }
            }
        }
        match self.at.partition_point(|&a| a <= t) {
            // before the first transition: the first NON-DST type
            // (RFC 8536 3.2), else type 0
            0 => self
                .types
                .iter()
                .find(|t| !t.1)
                .or(self.types.first())
                .map(|t| t.0)
                .or_else(|| self.footer.as_ref().map(|f| f.offset_at(t)))
                .unwrap_or(0),
            n => self.types.get(self.idx[n - 1] as usize).map(|t| t.0).unwrap_or(0),
        }
    }
}

fn zone_rules(zone: u16) -> Option<std::sync::Arc<Rules>> {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};
    static CACHE: OnceLock<Mutex<HashMap<u16, Option<Arc<Rules>>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(r) = cache.lock().ok()?.get(&zone) {
        return r.clone();
    }
    let name = TIME_ZONE_LIST.get(65535usize.checked_sub(zone as usize)?)?;
    let dir = std::env::var("TZDIR")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/usr/share/zoneinfo".to_string());
    // a zone name is a path under the directory - refuse anything that
    // could step outside it
    let rules = if name.contains("..") || name.starts_with('/') {
        None
    } else {
        std::fs::read(std::path::Path::new(&dir).join(name))
            .ok()
            .and_then(|b| parse_tzif(&b))
            .map(Arc::new)
    };
    cache.lock().ok()?.insert(zone, rules.clone());
    rules
}

/// RFC 8536: a v1 header and 32-bit body, then (v2+) a second header, a
/// 64-bit body and the newline-framed POSIX TZ footer. Only the v2 body
/// is read when there is one - the v1 body cannot represent instants
/// past 2038.
fn parse_tzif(b: &[u8]) -> Option<Rules> {
    struct Hdr {
        isutcnt: usize,
        isstdcnt: usize,
        leapcnt: usize,
        timecnt: usize,
        typecnt: usize,
        charcnt: usize,
    }
    fn hdr(b: &[u8]) -> Option<(u8, Hdr)> {
        if b.get(0..4)? != b"TZif" {
            return None;
        }
        let n = |i: usize| -> Option<usize> {
            Some(u32::from_be_bytes(b.get(20 + 4 * i..24 + 4 * i)?.try_into().ok()?) as usize)
        };
        Some((
            *b.get(4)?,
            Hdr { isutcnt: n(0)?, isstdcnt: n(1)?, leapcnt: n(2)?, timecnt: n(3)?, typecnt: n(4)?, charcnt: n(5)? },
        ))
    }
    fn body_len(h: &Hdr, tsz: usize) -> usize {
        h.timecnt * tsz + h.timecnt + h.typecnt * 6 + h.charcnt + h.leapcnt * (tsz + 4) + h.isstdcnt + h.isutcnt
    }
    let (ver, h1) = hdr(b)?;
    let (b, h, tsz) = if ver >= b'2' {
        let rest = b.get(44 + body_len(&h1, 4)..)?;
        let (_, h2) = hdr(rest)?;
        (&rest[44..], h2, 8usize)
    } else {
        (&b[44..], h1, 4usize)
    };
    let mut p = 0usize;
    let mut at = Vec::with_capacity(h.timecnt);
    for _ in 0..h.timecnt {
        let v = b.get(p..p + tsz)?;
        at.push(if tsz == 8 {
            i64::from_be_bytes(v.try_into().ok()?)
        } else {
            i32::from_be_bytes(v.try_into().ok()?) as i64
        });
        p += tsz;
    }
    let idx = b.get(p..p + h.timecnt)?.to_vec();
    p += h.timecnt;
    let mut types = Vec::with_capacity(h.typecnt);
    for _ in 0..h.typecnt {
        let t = b.get(p..p + 6)?;
        types.push((i32::from_be_bytes(t[0..4].try_into().ok()?), t[4] != 0));
        p += 6;
    }
    if idx.iter().any(|&i| i as usize >= types.len()) {
        return None;
    }
    let footer = if tsz == 8 {
        let rest = b.get(p + body_len(&Hdr { timecnt: 0, typecnt: 0, ..h }, 8)..)?;
        std::str::from_utf8(rest)
            .ok()
            .and_then(|s| s.strip_prefix('\n'))
            .and_then(|s| s.split('\n').next())
            .and_then(Posix::parse)
    } else {
        None
    };
    Some(Rules { at, idx, types, footer })
}

/// A POSIX TZ string (the TZif footer): `std offset [dst [offset]
/// [,start[/time],end[/time]]]`, offsets WEST-positive as POSIX writes
/// them, the rule times in the RFC 8536 extended range (-167..167 h).
struct Posix {
    std: i32,
    dst: Option<(i32, PosixRule, i32, PosixRule, i32)>,
}

#[derive(Clone, Copy)]
enum PosixRule {
    /// `Jn`: day 1..365, February 29 never counted
    Julian1(u16),
    /// `n`: day 0..365, February 29 counted
    Julian0(u16),
    /// `Mm.w.d`: day d (0 = Sunday) of week w (5 = last) of month m
    Month(u8, u8, u8),
}

impl Posix {
    fn parse(s: &str) -> Option<Posix> {
        let b = s.as_bytes();
        let mut i = 0usize;
        let name = |i: &mut usize| -> Option<()> {
            if b.get(*i) == Some(&b'<') {
                *i += b[*i..].iter().position(|&c| c == b'>')? + 1;
            } else {
                let st = *i;
                while b.get(*i).is_some_and(|c| c.is_ascii_alphabetic()) {
                    *i += 1;
                }
                if *i - st < 3 {
                    return None;
                }
            }
            Some(())
        };
        // [+-]hh[:mm[:ss]] as seconds
        let hms = |i: &mut usize| -> Option<i32> {
            let neg = match b.get(*i) {
                Some(b'-') => { *i += 1; true }
                Some(b'+') => { *i += 1; false }
                _ => false,
            };
            let mut parts = [0i32; 3];
            for (k, part) in parts.iter_mut().enumerate() {
                if k > 0 {
                    if b.get(*i) != Some(&b':') {
                        break;
                    }
                    *i += 1;
                }
                let st = *i;
                while b.get(*i).is_some_and(|c| c.is_ascii_digit()) {
                    *i += 1;
                }
                *part = std::str::from_utf8(&b[st..*i]).ok()?.parse().ok()?;
            }
            let v = parts[0] * 3600 + parts[1] * 60 + parts[2];
            Some(if neg { -v } else { v })
        };
        name(&mut i)?;
        let std = -hms(&mut i)?;
        if i == b.len() {
            return Some(Posix { std, dst: None });
        }
        name(&mut i)?;
        let dst_off = if b.get(i).is_some_and(|c| *c == b'+' || *c == b'-' || c.is_ascii_digit()) {
            -hms(&mut i)?
        } else {
            std + 3600
        };
        let rule = |i: &mut usize| -> Option<(PosixRule, i32)> {
            if b.get(*i) != Some(&b',') {
                return None;
            }
            *i += 1;
            let num = |i: &mut usize| -> Option<u16> {
                let st = *i;
                while b.get(*i).is_some_and(|c| c.is_ascii_digit()) {
                    *i += 1;
                }
                std::str::from_utf8(&b[st..*i]).ok()?.parse().ok()
            };
            let r = match b.get(*i)? {
                b'J' => { *i += 1; PosixRule::Julian1(num(i)?) }
                b'M' => {
                    *i += 1;
                    let m = num(i)?;
                    (b.get(*i) == Some(&b'.')).then_some(())?;
                    *i += 1;
                    let w = num(i)?;
                    (b.get(*i) == Some(&b'.')).then_some(())?;
                    *i += 1;
                    let d = num(i)?;
                    if !(1..=12).contains(&m) || !(1..=5).contains(&w) || d > 6 {
                        return None;
                    }
                    PosixRule::Month(m as u8, w as u8, d as u8)
                }
                _ => PosixRule::Julian0(num(i)?),
            };
            let time = if b.get(*i) == Some(&b'/') {
                *i += 1;
                hms(i)?
            } else {
                7200
            };
            Some((r, time))
        };
        // a DST name with no rule: tzcode's default is the US rule of
        // 1987; no zone in the list compiles to that - treat as no DST
        let Some((r1, t1)) = rule(&mut i) else {
            return Some(Posix { std, dst: None });
        };
        let (r2, t2) = rule(&mut i)?;
        Some(Posix { std, dst: Some((dst_off, r1, t1, r2, t2)) })
    }

    fn offset_at(&self, t: i64) -> i32 {
        let Some((dst, r1, t1, r2, t2)) = self.dst else {
            return self.std;
        };
        let year = civil_year(t.div_euclid(86400));
        // the transition instants in UTC: the start is written in
        // STANDARD local time, the end in DAYLIGHT local time
        let start = rule_day(year, r1) * 86400 + t1 as i64 - self.std as i64;
        let end = rule_day(year, r2) * 86400 + t2 as i64 - dst as i64;
        let in_dst = if start < end {
            t >= start && t < end
        } else {
            // southern hemisphere: DST spans the new year
            !(t >= end && t < start)
        };
        if in_dst { dst } else { self.std }
    }
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// days_from_civil).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn civil_year(days: i64) -> i64 {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    yoe + era * 400 + if m <= 2 { 1 } else { 0 }
}

/// The day (since the epoch) a POSIX rule names in `year`.
fn rule_day(year: i64, r: PosixRule) -> i64 {
    let jan1 = days_from_civil(year, 1, 1);
    match r {
        PosixRule::Julian0(n) => jan1 + n as i64,
        PosixRule::Julian1(n) => {
            let n = n as i64;
            jan1 + n - 1 + if is_leap(year) && n >= 60 { 1 } else { 0 }
        }
        PosixRule::Month(m, w, d) => {
            let first = days_from_civil(year, m as i64, 1);
            // 1970-01-01 was a Thursday (4)
            let wd_first = (first + 4).rem_euclid(7);
            let mut day = first + (d as i64 - wd_first).rem_euclid(7) + (w as i64 - 1) * 7;
            let next = if m == 12 { days_from_civil(year + 1, 1, 1) } else { days_from_civil(year, m as i64 + 1, 1) };
            while day >= next {
                day -= 7;
            }
            day
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_map_like_time_zone_util() {
        assert_eq!(zone_text(65535), "GMT");
        assert_eq!(displacement(65535), Some(0));
        // offset zones: displacement = id - 1439 (ONE_DAY = 24*60 - 1)
        assert_eq!(zone_text(1439), "+00:00");
        assert_eq!(zone_text(1439 + 120), "+02:00");
        assert_eq!(zone_text(1439 - 330), "-05:30");
        assert_eq!(displacement(1439 + 120), Some(120));
        // a named zone from the generated list - convertible? no.
        assert_eq!(displacement(65534), None); // ACT
        assert_eq!(zone_text(65534), "ACT");
        assert!(TIME_ZONE_LIST.contains(&"Europe/Bucharest"));
    }

    #[test]
    fn posix_footers_decide_the_dst_edges() {
        let eu = Posix::parse("EET-2EEST,M3.5.0/3,M10.5.0/4").unwrap();
        let at = |y, m, d, hh: i64, mm: i64| days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60;
        // 2026: last Sunday of March is the 29th, of October the 25th;
        // the switches are 01:00 UTC both ways
        assert_eq!(eu.offset_at(at(2026, 3, 29, 0, 59)), 7200);
        assert_eq!(eu.offset_at(at(2026, 3, 29, 1, 0)), 10800);
        assert_eq!(eu.offset_at(at(2026, 10, 25, 0, 59)), 10800);
        assert_eq!(eu.offset_at(at(2026, 10, 25, 1, 0)), 7200);
        assert_eq!(eu.offset_at(at(2026, 9, 23, 22, 41)), 10800);
        // southern hemisphere: DST across the new year
        let nz = Posix::parse("NZST-12NZDT,M9.5.0,M4.1.0/3").unwrap();
        assert_eq!(nz.offset_at(at(2026, 1, 15, 0, 0)), 13 * 3600);
        assert_eq!(nz.offset_at(at(2026, 6, 15, 0, 0)), 12 * 3600);
        // no DST, a bracketed name, a west-positive offset
        assert_eq!(Posix::parse("<-03>3").unwrap().offset_at(0), -3 * 3600);
        assert_eq!(Posix::parse("EST5EDT,M3.2.0,M11.1.0").unwrap().offset_at(at(2026, 7, 1, 12, 0)), -4 * 3600);
        assert_eq!(civil_year(days_from_civil(2024, 12, 31)), 2024);
        assert_eq!(civil_year(days_from_civil(2025, 1, 1)), 2025);
    }

    #[test]
    fn host_tzif_converts_a_named_zone() {
        // skipped on a host without the zone's file: the rule is then
        // "unconverted", which the None arm of the callers carries
        let Some(z) = zone_id("Europe/Bucharest") else { return };
        let mjd = |y, m, d| (days_from_civil(y, m, d) + 40587) as i32;
        if zone_rules(z).is_none() {
            return;
        }
        assert_eq!(displacement_at(z, mjd(2026, 9, 23), 22 * 36_000_000), Some(180));
        assert_eq!(displacement_at(z, mjd(2026, 1, 15), 0), Some(120));
        assert_eq!(displacement_at(z, mjd(1999, 12, 31), 0), Some(120));
        assert_eq!(displacement_at(z, mjd(2100, 7, 1), 0), Some(180)); // the footer
        // the UTC equivalents never read a file
        assert_eq!(displacement_at(zone_id("UTC").unwrap(), 0, 0), Some(0));
    }

    #[test]
    fn a_wall_time_resolves_as_the_engine_does() {
        let Some(z) = zone_id("Europe/Bucharest") else { return };
        if zone_rules(z).is_none() {
            return;
        }
        let mjd = |y, m, d| (days_from_civil(y, m, d) + 40587) as i32;
        let hms = |h: u32, m: u32, s: u32| (h * 3600 + m * 60 + s) * 10_000;
        let w = |y, mo, d, h, m, s| wall_displacement(z, mjd(y, mo, d), hms(h, m, s));
        // every cell measured against the engine (Firebird 6)
        assert_eq!(w(2026, 3, 29, 2, 59, 59), Some(120));
        assert_eq!(w(2026, 3, 29, 3, 0, 0), Some(120)); // the gap: before's
        assert_eq!(w(2026, 3, 29, 3, 59, 59), Some(120));
        assert_eq!(w(2026, 3, 29, 4, 0, 0), Some(180));
        assert_eq!(w(2026, 3, 29, 0, 30, 0), Some(120));
        assert_eq!(w(2026, 10, 25, 2, 59, 59), Some(180));
        assert_eq!(w(2026, 10, 25, 3, 0, 0), Some(180)); // the overlap: first
        assert_eq!(w(2026, 10, 25, 3, 59, 59), Some(180));
        assert_eq!(w(2026, 10, 25, 4, 0, 0), Some(120));
        assert_eq!(w(1900, 1, 1, 12, 0, 0), Some(104)); // LMT, in minutes
        assert_eq!(w(2100, 7, 1, 12, 0, 0), Some(180));
    }
}
