/// A problem `validate` or `package` found.
public struct Diagnostic: Equatable, Hashable, Sendable, CustomStringConvertible {

    public enum Severity: String, Equatable, Hashable, Sendable {

        /// Packaging stops.
        case error

        /// Packaging goes on; the app may lack something.
        case warning
    }

    public var severity: Severity

    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }

    public static func error(_ message: String) -> Diagnostic {
        Diagnostic(.error, message)
    }

    public static func warning(_ message: String) -> Diagnostic {
        Diagnostic(.warning, message)
    }

    public var description: String {
        "\(severity.rawValue): \(message)"
    }
}

public extension Array where Element == Diagnostic {

    var errors: [Diagnostic] {
        filter { $0.severity == .error }
    }

    var hasErrors: Bool {
        contains { $0.severity == .error }
    }
}

/// Why packaging stopped.
public struct PackagerError: Error, Equatable, CustomStringConvertible {

    public var message: String

    /// The diagnostics behind the error, when it comes from a check.
    public var diagnostics: [Diagnostic]

    public init(_ message: String, diagnostics: [Diagnostic] = []) {
        self.message = message
        self.diagnostics = diagnostics
    }

    public var description: String {
        message
    }

    /// Throws when `diagnostics` has errors.
    static func check(_ diagnostics: [Diagnostic], _ step: String) throws(PackagerError) {
        let errors = diagnostics.errors
        guard !errors.isEmpty else {
            return
        }
        throw PackagerError("\(step) failed with \(errors.count) error\(errors.count == 1 ? "" : "s")", diagnostics: diagnostics)
    }
}

/// A dotted version, such as `15.0` or `12.4.1`, compared numerically.
public struct OSVersion: Comparable, Hashable, Sendable, CustomStringConvertible {

    public var components: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else {
            return nil
        }
        var components = [Int]()
        for part in parts {
            guard let value = Int(part), value >= 0 else {
                return nil
            }
            components.append(value)
        }
        self.components = components
    }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    public static func == (lhs: OSVersion, rhs: OSVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        hasher.combine(trimmed)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
