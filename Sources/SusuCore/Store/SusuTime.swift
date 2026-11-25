import Foundation

/// ISO-8601 UTC text with millisecond precision, `2026-11-13T09:05:01.123Z` (spec 5.2).
/// Hand-written (no formatters): fast, thread-safe, and byte-identical to SQLite's
/// `strftime('%Y-%m-%dT%H:%M:%fZ','now')`, so text comparison equals time comparison.
public enum SusuTime {
    public static func string(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let days = floorDiv(ms, 86_400_000)
        let msOfDay = Int(ms - days * 86_400_000)
        let (y, m, d) = civil(fromDays: days)
        let h = msOfDay / 3_600_000
        let mi = msOfDay / 60_000 % 60
        let s = msOfDay / 1000 % 60
        let milli = msOfDay % 1000
        return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2) + "T" + pad(h, 2) + ":" + pad(mi, 2) + ":"
            + pad(s, 2) + "." + pad(milli, 3) + "Z"
    }

    /// Parses `YYYY-MM-DDTHH:MM:SSZ` or `YYYY-MM-DDTHH:MM:SS.fffZ` (extra fraction digits ignored).
    public static func date(_ string: String) -> Date? {
        let b = Array(string.utf8)
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58, b.last == 90
        else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                guard b[i] >= 48, b[i] <= 57 else { return nil }
                v = v * 10 + Int(b[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2) else { return nil }
        var milli = 0
        if b[19] == 46 {
            var scale = 100
            var i = 20
            while i < b.count - 1, scale > 0 {
                guard b[i] >= 48, b[i] <= 57 else { return nil }
                milli += Int(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        } else if b[19] != 90 { return nil }
        let days = Int64(daysFromCivil(y, mo, d))
        let ms = days * 86_400_000 + Int64(h * 3_600_000 + mi * 60_000 + s * 1000 + milli)
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    // Howard Hinnant's civil-calendar algorithms.
    private static func civil(fromDays z0: Int64) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = Int(doy - (153 * mp + 2) / 5 + 1)
        let m = Int(mp < 10 ? mp + 3 : mp - 9)
        let y = Int(yoe + era * 400) + (m <= 2 ? 1 : 0)
        return (y, m, d)
    }

    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
