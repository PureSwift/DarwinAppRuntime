import DynamicText
import Foundation
import RuntimeText

/// `HostTextStorage`'s platform: a text view per text, and the encodings
/// Foundation has beyond the five every host reads and writes.
final class DarwinTextPlatform: TextPlatform {

    func makeEngine(for storage: HostTextStorage) -> any TextEngine {
        TextViewEngine(storage: storage)
    }

    /// TextKit lays out only what's shown, so long texts open; a phone has
    /// less memory to hold them in than a Mac.
    var maximumLength: Int {
        #if os(macOS)
        64 << 20
        #else
        16 << 20
        #endif
    }

    func supportsEncoding(_ name: String) -> Bool {
        TextEncodings.encoding(name) != nil
    }

    var extraEncodings: TextCoding.Extra? {
        TextEncodings.extra
    }
}

/// Encodings by IANA name, through Core Foundation's table.
enum TextEncodings {

    static func encoding(_ name: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// Bytes that aren't valid in the encoding, and a character it lacks,
    /// are refused rather than replaced: a save would destroy them.
    static let extra = TextCoding.Extra(
        decode: { bytes, name in
            guard let encoding = encoding(name) else { return nil }
            return String(bytes: bytes, encoding: encoding)
        },
        encode: { text, name in
            guard let encoding = encoding(name), let data = text.data(using: encoding, allowLossyConversion: false) else {
                return nil
            }
            return Array(data)
        }
    )
}
