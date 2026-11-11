import DarwinHost
import DynamicFormatting
import Foundation

/// The `DateFormat` contract over `DateFormatter` and
/// `RelativeDateTimeFormatter`.
///
/// A new object uses the medium date and time styles, like
/// `java.text.DateFormat.getDateTimeInstance()`. Each object holds its
/// settings; the formatter for a set of settings comes from
/// `FormatterCache`.
public final class DarwinDateFormat: DateFormat {

    /// What overrides the styles.
    enum Pattern: Hashable {
        /// A fixed TR35 pattern, used as is.
        case fixed(String)
        /// Skeleton fields, localized with
        /// `setLocalizedDateFormatFromTemplate`.
        case template(String)
    }

    /// Everything that shapes the formatter.
    struct Settings: Hashable {
        var locale: String?
        /// An IANA identifier Foundation knows; nil for the user's.
        var timeZone: String?
        var dateStyle: DateStyle = .medium
        var timeStyle: DateStyle = .medium
        var pattern: Pattern?
    }

    private(set) var settings: Settings

    init(_ settings: Settings) {
        self.settings = settings
    }

    /// An unknown `timeZone` is logged and replaced by the user's.
    public static func make(locale: String?, timeZone: String?) -> DarwinDateFormat {
        var zone = timeZone
        if let timeZone, TimeZone(identifier: timeZone) == nil {
            AppHost.logger.error("DateFormat.make: unknown time zone \(timeZone, privacy: .public); using the user's")
            zone = nil
        }
        return DarwinDateFormat(Settings(locale: locale, timeZone: zone))
    }

    public func setDateStyle(_ style: Int32) {
        guard let style = Self.style(style, method: "setDateStyle") else { return }
        settings.dateStyle = style
    }

    public func setTimeStyle(_ style: Int32) {
        guard let style = Self.style(style, method: "setTimeStyle") else { return }
        settings.timeStyle = style
    }

    public func setPattern(_ pattern: String?) {
        settings.pattern = pattern.map(Pattern.fixed)
    }

    public func setTemplate(_ template: String) {
        settings.pattern = .template(template)
    }

    public func format(_ milliseconds: Int64) -> String {
        formatter.string(from: Self.date(milliseconds))
    }

    public func parse(_ string: String) -> Int64 {
        guard let date = formatter.date(from: string) else {
            return .min
        }
        return Self.milliseconds(date)
    }

    public func formatRelative(_ milliseconds: Int64, reference: Int64) -> String {
        relativeFormatter.localizedString(for: Self.date(milliseconds), relativeTo: Self.date(reference))
    }

    // MARK: Formatters

    var formatter: DateFormatter {
        let settings = settings
        return FormatterCache.formatter(for: settings) {
            Self.makeFormatter(settings)
        }
    }

    static func makeFormatter(_ settings: Settings) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = LocaleIdentifiers.locale(settings.locale)
        formatter.timeZone = timeZone(settings.timeZone)
        switch settings.pattern {
        case .fixed(let pattern):
            formatter.dateFormat = pattern
        case .template(let template):
            formatter.setLocalizedDateFormatFromTemplate(template)
        case nil:
            formatter.dateStyle = dateFormatterStyle(settings.dateStyle)
            formatter.timeStyle = dateFormatterStyle(settings.timeStyle)
        }
        return formatter
    }

    private struct RelativeKey: Hashable {
        let locale: String?
        let timeZone: String?
    }

    var relativeFormatter: RelativeDateTimeFormatter {
        let key = RelativeKey(locale: settings.locale, timeZone: settings.timeZone)
        return FormatterCache.formatter(for: key) {
            let formatter = RelativeDateTimeFormatter()
            let locale = LocaleIdentifiers.locale(key.locale)
            var calendar = locale.calendar
            calendar.timeZone = Self.timeZone(key.timeZone)
            formatter.locale = locale
            formatter.calendar = calendar
            return formatter
        }
    }

    // MARK: Conversions

    static func dateFormatterStyle(_ style: DateStyle) -> DateFormatter.Style {
        switch style {
        case .none: .none
        case .short: .short
        case .medium: .medium
        case .long: .long
        case .full: .full
        }
    }

    static func timeZone(_ identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func style(_ raw: Int32, method: String) -> DateStyle? {
        guard let style = DateStyle(rawValue: raw) else {
            AppHost.logger.error("DateFormat.\(method, privacy: .public): unknown style \(raw, privacy: .public); ignored")
            return nil
        }
        return style
    }
}
