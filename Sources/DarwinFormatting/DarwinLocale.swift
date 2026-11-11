import DynamicFormatting
import Foundation

/// The `LocaleInfo` contract over `Locale` and `TimeZone`.
///
/// `current()` follows the user's settings as they change
/// (`Locale.autoupdatingCurrent`). The time zone is always the user's, also
/// for a locale made with `make(identifier:)`: a locale doesn't carry one.
public final class DarwinLocale: LocaleInfo {

    let locale: Locale

    init(_ locale: Locale) {
        self.locale = locale
    }

    public static func current() -> DarwinLocale {
        DarwinLocale(.autoupdatingCurrent)
    }

    /// Nil for an identifier whose language or region Foundation doesn't
    /// know.
    public static func make(identifier: String) -> DarwinLocale? {
        LocaleIdentifiers.knownLocale(identifier).map(DarwinLocale.init)
    }

    public func identifier() -> String {
        LocaleIdentifiers.bcp47(locale)
    }

    public func languageCode() -> String? {
        LocaleIdentifiers.languageCode(locale)
    }

    public func regionCode() -> String? {
        LocaleIdentifiers.regionCode(locale)
    }

    public static func preferredLanguages() -> [String] {
        Locale.preferredLanguages
    }

    public func decimalSeparator() -> String {
        locale.decimalSeparator ?? "."
    }

    public func groupingSeparator() -> String {
        locale.groupingSeparator ?? ","
    }

    public func currencyCode() -> String? {
        LocaleIdentifiers.currencyCode(locale)
    }

    /// Whether the locale's preferred hour format (the `j` skeleton) is
    /// 0–23 or 1–24 rather than 1–12 or 0–11.
    public func uses24HourClock() -> Bool {
        let format = FormatterCache.formatter(for: HourFormatKey(locale: locale.identifier)) {
            HourFormat(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "")
        }
        return format.uses24Hours
    }

    public func timeZoneIdentifier() -> String {
        TimeZone.autoupdatingCurrent.identifier
    }

    public func timeZoneOffset(_ milliseconds: Int64) -> Int32 {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return Int32(TimeZone.autoupdatingCurrent.secondsFromGMT(for: date))
    }
}

private struct HourFormatKey: Hashable {
    let locale: String
}

/// A locale's hour pattern, cached as an object.
final class HourFormat {

    let uses24Hours: Bool

    init(_ pattern: String) {
        self.uses24Hours = Self.uses24Hours(pattern)
    }

    /// Whether a TR35 pattern uses `H` or `k`, outside quoted literals such
    /// as `'Uhr'`.
    static func uses24Hours(_ pattern: String) -> Bool {
        var quoted = false
        for character in pattern {
            if character == "'" {
                quoted.toggle()
            } else if !quoted, character == "H" || character == "k" {
                return true
            }
        }
        return false
    }
}
