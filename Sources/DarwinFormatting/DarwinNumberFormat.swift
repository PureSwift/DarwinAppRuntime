import DarwinHost
import DynamicFormatting
import Foundation

/// The `NumberFormat` contract over `NumberFormatter`.
///
/// Each object holds its settings; the formatter for a set of settings comes
/// from `FormatterCache`, so objects with the same locale, style and options
/// share one.
///
/// `NumberStyle.compact` has no `NumberFormatter` style. It formats with
/// `FloatingPointFormatStyle`'s compact-name notation ("1.2K") and parses
/// like `decimal`, since Foundation has no compact parser.
public final class DarwinNumberFormat: NumberFormat {

    /// Everything that shapes the formatter. Nil options keep the style's
    /// defaults.
    struct Settings: Hashable {
        var locale: String?
        var style: NumberStyle
        var minimumFractionDigits: Int?
        var maximumFractionDigits: Int?
        var usesGrouping: Bool?
        var currencyCode: String?
    }

    private(set) var settings: Settings

    init(_ settings: Settings) {
        self.settings = settings
    }

    public static func make(locale: String?, style: Int32) -> DarwinNumberFormat {
        let numberStyle = NumberStyle(rawValue: style) ?? {
            AppHost.logger.error("NumberFormat.make: unknown style \(style, privacy: .public); using decimal")
            return .decimal
        }()
        return DarwinNumberFormat(Settings(locale: locale, style: numberStyle))
    }

    /// Raises the maximum if it was set lower.
    public func setMinimumFractionDigits(_ digits: Int32) {
        let minimum = max(0, Int(digits))
        settings.minimumFractionDigits = minimum
        if let maximum = settings.maximumFractionDigits, maximum < minimum {
            settings.maximumFractionDigits = minimum
        }
    }

    /// Lowers the minimum if it was set higher.
    public func setMaximumFractionDigits(_ digits: Int32) {
        let maximum = max(0, Int(digits))
        settings.maximumFractionDigits = maximum
        if let minimum = settings.minimumFractionDigits, minimum > maximum {
            settings.minimumFractionDigits = maximum
        }
    }

    public func setUsesGrouping(_ grouping: Bool) {
        settings.usesGrouping = grouping
    }

    public func setCurrencyCode(_ code: String?) {
        settings.currencyCode = code
    }

    public func format(_ value: Double) -> String {
        if settings.style == .compact {
            return value.formatted(compactStyle)
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public func formatInteger(_ value: Int64) -> String {
        if settings.style == .compact {
            // Compact output is rounded, so a Double's precision is enough.
            return Double(value).formatted(compactStyle)
        }
        // `NSNumber` goes through a Double; `NSDecimalNumber` stays exact.
        return formatter.string(from: NSDecimalNumber(value: value)) ?? String(value)
    }

    public func parse(_ string: String) -> Double {
        formatter.number(from: string)?.doubleValue ?? .nan
    }

    // MARK: Formatters

    /// The cached formatter for the current settings. Compact uses a decimal
    /// formatter, for parsing.
    var formatter: NumberFormatter {
        var key = settings
        if key.style == .compact {
            key.style = .decimal
        }
        return FormatterCache.formatter(for: key) {
            Self.makeFormatter(key)
        }
    }

    static func makeFormatter(_ settings: Settings) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = LocaleIdentifiers.locale(settings.locale)
        formatter.numberStyle = numberStyle(settings.style)
        if let code = settings.currencyCode {
            formatter.currencyCode = code
        }
        if let minimum = settings.minimumFractionDigits {
            formatter.minimumFractionDigits = minimum
            formatter.maximumFractionDigits = max(formatter.maximumFractionDigits, minimum)
        }
        if let maximum = settings.maximumFractionDigits {
            formatter.maximumFractionDigits = maximum
            formatter.minimumFractionDigits = min(formatter.minimumFractionDigits, maximum)
        }
        if let grouping = settings.usesGrouping {
            formatter.usesGroupingSeparator = grouping
        }
        return formatter
    }

    static func numberStyle(_ style: NumberStyle) -> NumberFormatter.Style {
        switch style {
        case .decimal, .compact: .decimal
        case .percent: .percent
        case .currency: .currency
        case .scientific: .scientific
        case .spellOut: .spellOut
        case .ordinal: .ordinal
        }
    }

    private var compactStyle: FloatingPointFormatStyle<Double> {
        var style = FloatingPointFormatStyle<Double>(locale: LocaleIdentifiers.locale(settings.locale))
            .notation(.compactName)
        switch (settings.minimumFractionDigits, settings.maximumFractionDigits) {
        case (nil, nil):
            break
        case let (minimum?, nil):
            style = style.precision(.fractionLength(minimum...))
        case let (minimum, maximum?):
            style = style.precision(.fractionLength((minimum ?? 0)...maximum))
        }
        if settings.usesGrouping == false {
            style = style.grouping(.never)
        }
        return style
    }
}
