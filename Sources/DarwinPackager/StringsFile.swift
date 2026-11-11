import Foundation

/// `.strings` files: `"key" = "value";`.
public enum StringsFile {

    /// Reads a `.strings` file, in UTF-8 or UTF-16.
    public static func read(_ url: URL) throws -> [String: String] {
        try parse(Data(contentsOf: url), name: url.path)
    }

    public static func parse(_ data: Data, name: String = "strings") throws -> [String: String] {
        if data.isEmpty {
            return [:]
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw PackagerError("\(name) is not a valid .strings file: \(error.localizedDescription)")
        }
        guard let strings = plist as? [String: String] else {
            throw PackagerError("\(name) is not a valid .strings file: it isn't a table of strings")
        }
        return strings
    }

    /// The file's text, keys sorted, in UTF-8.
    public static func text(_ strings: [String: String]) -> String {
        strings.keys.sorted().map { "\"\(escape($0))\" = \"\(escape(strings[$0]!))\";\n" }.joined()
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
