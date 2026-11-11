import DarwinHost
import DynamicNFC
import Foundation

/// The `NDEFRecord` contract: one record as plain bytes, on every platform.
///
/// CoreNFC's `NFCNDEFPayload` exists only on iOS, so the host keeps its own
/// model and converts at the edge (`NFCConversions.swift`). The well-known
/// URI and text records follow the NFC Forum RTDs.
public final class DarwinNDEFRecord: NDEFRecord {

    let format: NDEFTypeNameFormat

    let recordType: [UInt8]

    let recordIdentifier: [UInt8]

    let recordPayload: [UInt8]

    /// The type and identifier hold at most 255 bytes, since their lengths
    /// are one byte in the encoding; longer ones are cut and logged.
    init(format: NDEFTypeNameFormat, type: [UInt8], identifier: [UInt8], payload: [UInt8]) {
        self.format = format
        self.recordType = Self.limited(type, "type")
        self.recordIdentifier = Self.limited(identifier, "identifier")
        self.recordPayload = payload
    }

    /// An unknown `format` is logged and recorded as `unknown`.
    public static func make(format: Int32, type: [UInt8], identifier: [UInt8], payload: [UInt8]) -> DarwinNDEFRecord {
        let typeNameFormat = NDEFTypeNameFormat(rawValue: format) ?? {
            AppHost.logger.error("NDEFRecord.make: unknown type name format \(format, privacy: .public); using unknown")
            return .unknown
        }()
        return DarwinNDEFRecord(format: typeNameFormat, type: type, identifier: identifier, payload: payload)
    }

    /// Nil unless `uri` has a scheme (RFC 3986) and no spaces or control
    /// characters. The longest matching URI prefix is abbreviated to its
    /// code.
    public static func makeURI(_ uri: String) -> DarwinNDEFRecord? {
        guard isValidURI(uri) else {
            return nil
        }
        var code = 0
        var prefixLength = 0
        for (index, prefix) in uriPrefixes.enumerated() where prefix.count > prefixLength && uri.hasPrefix(prefix) {
            code = index
            prefixLength = prefix.count
        }
        let rest = uri.dropFirst(prefixLength)
        return DarwinNDEFRecord(
            format: .wellKnown,
            type: uriType,
            identifier: [],
            payload: [UInt8(code)] + Array(rest.utf8)
        )
    }

    /// UTF-8 text. A language code longer than the 63 bytes the status byte
    /// can count is cut and logged.
    public static func makeText(_ text: String, locale: String) -> DarwinNDEFRecord {
        var language = Array(locale.utf8)
        if language.count > 63 {
            AppHost.logger.error("NDEFRecord.makeText: language code longer than 63 bytes; cut")
            language = Array(language.prefix(63))
        }
        return DarwinNDEFRecord(
            format: .wellKnown,
            type: textType,
            identifier: [],
            payload: [UInt8(language.count)] + language + Array(text.utf8)
        )
    }

    /// A copy of any `NDEFRecord`: this module's own, or one the guest
    /// implemented, read through the protocol.
    static func copy(of record: any NDEFRecord) -> DarwinNDEFRecord {
        if let own = DarwinNFC.host(record, as: DarwinNDEFRecord.self) {
            return own
        }
        return make(
            format: record.typeNameFormat(),
            type: record.type(),
            identifier: record.identifier(),
            payload: record.payload()
        )
    }

    public func typeNameFormat() -> Int32 {
        format.rawValue
    }

    public func type() -> [UInt8] {
        recordType
    }

    public func identifier() -> [UInt8] {
        recordIdentifier
    }

    public func payload() -> [UInt8] {
        recordPayload
    }

    public func uri() -> String? {
        guard format == .wellKnown, recordType == Self.uriType,
              let code = recordPayload.first, Int(code) < Self.uriPrefixes.count,
              let rest = String(bytes: recordPayload.dropFirst(), encoding: .utf8) else {
            return nil
        }
        return Self.uriPrefixes[Int(code)] + rest
    }

    /// UTF-8 or UTF-16 text; UTF-16 is big-endian unless it starts with a
    /// byte order mark.
    public func text() -> String? {
        guard format == .wellKnown, recordType == Self.textType, let status = recordPayload.first else {
            return nil
        }
        let languageLength = Int(status & 0x3F)
        guard recordPayload.count >= 1 + languageLength else {
            return nil
        }
        let bytes = Array(recordPayload.dropFirst(1 + languageLength))
        guard status & 0x80 != 0 else {
            return String(bytes: bytes, encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian)
        }
        return String(bytes: bytes, encoding: .utf16BigEndian)
    }

    /// The language code of a well-known text record.
    var textLanguage: String? {
        guard format == .wellKnown, recordType == Self.textType, let status = recordPayload.first else {
            return nil
        }
        let languageLength = Int(status & 0x3F)
        guard recordPayload.count >= 1 + languageLength else {
            return nil
        }
        return String(bytes: recordPayload[1 ..< 1 + languageLength], encoding: .ascii)
    }

    // MARK: Well-known types

    /// "U"
    static let uriType: [UInt8] = [0x55]

    /// "T"
    static let textType: [UInt8] = [0x54]

    /// The NFC Forum URI RTD's abbreviations, indexed by code.
    static let uriPrefixes = [
        "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
        "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://", "nfs://",
        "ftp://", "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:",
        "sips:", "tftp:", "btspp://", "btl2cap://", "btgoep://", "tcpobex://", "irdaobex://",
        "file://", "urn:epc:id:", "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:",
        "urn:nfc:",
    ]

    /// A scheme (a letter, then letters, digits, `+`, `-` or `.`) before the
    /// first colon, and no spaces or control characters anywhere.
    static func isValidURI(_ uri: String) -> Bool {
        guard let colon = uri.firstIndex(of: ":") else {
            return false
        }
        let scheme = uri[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else {
            return false
        }
        return !uri.unicodeScalars.contains { scalar in
            scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
        }
    }

    private static func limited(_ bytes: [UInt8], _ field: StaticString) -> [UInt8] {
        guard bytes.count > 255 else {
            return bytes
        }
        AppHost.logger.error("NDEFRecord: \(String(describing: field), privacy: .public) longer than 255 bytes; cut")
        return Array(bytes.prefix(255))
    }
}

/// The `NDEFMessage` contract: an ordered list of `DarwinNDEFRecord`s.
public final class DarwinNDEFMessage: NDEFMessage {

    let recordList: [DarwinNDEFRecord]

    init(_ records: [DarwinNDEFRecord]) {
        self.recordList = records
    }

    public static func make(_ records: [any NDEFRecord]) -> DarwinNDEFMessage {
        DarwinNDEFMessage(records.map(DarwinNDEFRecord.copy(of:)))
    }

    /// A copy of any `NDEFMessage`, as `copy(of:)` does for records.
    static func copy(of message: any NDEFMessage) -> DarwinNDEFMessage {
        if let own = DarwinNFC.host(message, as: DarwinNDEFMessage.self) {
            return own
        }
        return make(message.records())
    }

    public func records() -> [any NDEFRecord] {
        recordList
    }

    public func length() -> Int32 {
        Int32(clamping: encoded().count)
    }

    /// The message in the NFC Forum NDEF encoding, unchunked. An empty
    /// message is one empty record (`D0 00 00`), as NFC Forum tags store it.
    func encoded() -> [UInt8] {
        let records = recordList.isEmpty
            ? [DarwinNDEFRecord(format: .empty, type: [], identifier: [], payload: [])]
            : recordList
        var bytes = [UInt8]()
        for (index, record) in records.enumerated() {
            let short = record.recordPayload.count < 256
            var header = UInt8(truncatingIfNeeded: record.format.rawValue) & 0x07
            if index == 0 { header |= 0x80 }                   // MB
            if index == records.count - 1 { header |= 0x40 }   // ME
            if short { header |= 0x10 }                        // SR
            if !record.recordIdentifier.isEmpty { header |= 0x08 }  // IL
            bytes.append(header)
            bytes.append(UInt8(record.recordType.count))
            if short {
                bytes.append(UInt8(record.recordPayload.count))
            } else {
                let length = UInt32(clamping: record.recordPayload.count)
                bytes += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }
            }
            if !record.recordIdentifier.isEmpty {
                bytes.append(UInt8(record.recordIdentifier.count))
            }
            bytes += record.recordType + record.recordIdentifier + record.recordPayload
        }
        return bytes
    }

    /// Decodes an unchunked NDEF message; nil if `bytes` isn't one.
    static func decode(_ bytes: [UInt8]) -> DarwinNDEFMessage? {
        var records = [DarwinNDEFRecord]()
        var index = 0
        func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, index + count <= bytes.count else { return nil }
            defer { index += count }
            return bytes[index ..< index + count]
        }
        while index < bytes.count {
            guard let header = take(1)?.first, header & 0x20 == 0,  // CF: chunks aren't supported
                  let typeLength = take(1)?.first else {
                return nil
            }
            let payloadLength: Int
            if header & 0x10 != 0 {
                guard let length = take(1)?.first else { return nil }
                payloadLength = Int(length)
            } else {
                guard let length = take(4) else { return nil }
                payloadLength = length.reduce(0) { $0 << 8 | Int($1) }
            }
            var identifierLength = 0
            if header & 0x08 != 0 {
                guard let length = take(1)?.first else { return nil }
                identifierLength = Int(length)
            }
            guard let type = take(Int(typeLength)),
                  let identifier = take(identifierLength),
                  let payload = take(payloadLength) else {
                return nil
            }
            let format = NDEFTypeNameFormat(rawValue: Int32(header & 0x07)) ?? .unknown
            records.append(DarwinNDEFRecord(format: format, type: Array(type), identifier: Array(identifier), payload: Array(payload)))
            if header & 0x40 != 0 {
                break
            }
        }
        guard index == bytes.count else {
            return nil
        }
        // One empty record is the empty message.
        if records.count == 1, records[0].format == .empty, records[0].recordPayload.isEmpty {
            records = []
        }
        return DarwinNDEFMessage(records)
    }
}
