import Foundation

/// Foundation formatters shared by every contract object with the same
/// configuration (`HostRuntime.md` §5.1: cached per locale and style).
///
/// Making a formatter loads ICU data and is slow; using one is fast. A key
/// holds the whole configuration, so a cached formatter is never changed
/// after it is made. The cache empties when the user's locale or time zone
/// changes, since formatters for "the user's" settings captured the old
/// ones, and when it grows past `limit`.
///
/// Main thread only, like the contracts.
enum FormatterCache {

    /// Entries kept before the cache starts over.
    static let limit = 64

    nonisolated(unsafe) private static var entries: [AnyHashable: AnyObject] = [:]

    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    /// The cached formatter for `key`, made with `make` if there's none.
    static func formatter<Key: Hashable, Formatter: AnyObject>(
        for key: Key,
        make: () -> Formatter
    ) -> Formatter {
        observeChanges()
        if let cached = entries[AnyHashable(key)] as? Formatter {
            return cached
        }
        if entries.count >= limit {
            entries.removeAll(keepingCapacity: true)
        }
        let formatter = make()
        entries[AnyHashable(key)] = formatter
        return formatter
    }

    static var count: Int {
        entries.count
    }

    static func removeAll() {
        entries.removeAll()
    }

    private static func observeChanges() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                FormatterCache.removeAll()
            })
        }
    }
}

/// Conversions between the contracts' BCP 47 identifiers and Foundation's.
enum LocaleIdentifiers {

    /// The locale for a BCP 47 identifier; nil is the user's.
    static func locale(_ identifier: String?) -> Locale {
        guard let identifier else {
            return .autoupdatingCurrent
        }
        return Locale(identifier: identifier)
    }

    /// The BCP 47 identifier of `locale`, for example `en-US` for `en_US`.
    static func bcp47(_ locale: Locale) -> String {
        if #available(iOS 16, macOS 13, *) {
            // `autoupdatingCurrent` answers in Foundation's form; a fixed
            // copy converts.
            return Locale(identifier: locale.identifier).identifier(.bcp47)
        }
        return Locale.canonicalLanguageIdentifier(from: locale.identifier)
    }

    /// The locale for `identifier` if Foundation knows its language and
    /// region; nil for an empty or made-up identifier.
    ///
    /// `Locale(identifier:)` accepts any string, so this checks the parts
    /// against ISO 639 and ISO 3166 (or a UN M.49 area such as `419`).
    static func knownLocale(_ identifier: String) -> Locale? {
        let locale = Locale(identifier: identifier)
        guard let language = languageCode(locale), Locale.isoLanguageCodes.contains(language) else {
            return nil
        }
        if let region = regionCode(locale) {
            let isArea = region.count == 3 && region.allSatisfy(\.isASCII) && region.allSatisfy(\.isNumber)
            guard isArea || Locale.isoRegionCodes.contains(region) else {
                return nil
            }
        }
        return locale
    }

    static func languageCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.language.languageCode?.identifier
        }
        return locale.languageCode
    }

    /// The region the identifier names; nil when it names none.
    static func regionCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.region?.identifier
        }
        return locale.regionCode
    }

    static func currencyCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) {
            return locale.currency?.identifier
        }
        return locale.currencyCode
    }
}
