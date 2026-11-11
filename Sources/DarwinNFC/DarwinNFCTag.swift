#if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
import CoreNFC
import DarwinHost
import DynamicNFC
import Foundation

/// The `NFCTag` contract over a tag a CoreNFC session detected.
///
/// Operations need the reader's active session and this tag connected
/// (`DarwinNFCReader.connect`); without them they report `tagNotConnected`.
/// Every operation reports exactly once through the reader's delegate, on
/// the main thread.
///
/// `transceive` by technology:
/// - ISO 7816: the bytes are an APDU (`NFCISO7816APDU(data:)`); the response
///   is the data followed by SW1 SW2.
/// - MIFARE: `sendMiFareCommand`, a native command; CoreNFC adds the CRC.
/// - FeliCa: `sendFeliCaCommand`, a command packet; CoreNFC adds the length
///   byte and the CRC.
/// - ISO 15693: byte 0 is the request flags, byte 1 the command code, and
///   the rest its parameters (`sendRequest`); the response is the response
///   flags byte followed by the data.
/// - NDEF-only sessions: `notAvailableInNDEFSession`.
public final class DarwinNFCTag: DynamicNFC.NFCTag {

    /// What CoreNFC detected.
    enum Kind {
        /// From an `NFCTagReaderSession`.
        case tag(CoreNFC.NFCTag)
        /// From an `NFCNDEFReaderSession`.
        case ndef(any NFCNDEFTag)

        /// The CoreNFC object, for identity.
        var object: AnyObject {
            switch self {
            case .tag(.feliCa(let tag)): tag
            case .tag(.iso7816(let tag)): tag
            case .tag(.iso15693(let tag)): tag
            case .tag(.miFare(let tag)): tag
            case .tag(let tag): tag as AnyObject
            case .ndef(let tag): tag
            }
        }

        /// Every CoreNFC tag type is an `NFCNDEFTag`.
        var ndefTag: (any NFCNDEFTag)? {
            switch self {
            case .tag(.feliCa(let tag)): tag
            case .tag(.iso7816(let tag)): tag
            case .tag(.iso15693(let tag)): tag
            case .tag(.miFare(let tag)): tag
            case .tag: nil
            case .ndef(let tag): tag
            }
        }
    }

    let kind: Kind

    /// The reader keeps its tags; a tag doesn't keep its reader.
    private(set) weak var reader: DarwinNFCReader?

    init(kind: Kind, reader: DarwinNFCReader) {
        self.kind = kind
        self.reader = reader
    }

    public func type() -> Int32 {
        let type: DynamicNFC.NFCTagType
        switch kind {
        case .tag(.feliCa): type = .feliCa
        case .tag(.iso7816): type = .iso7816
        case .tag(.iso15693): type = .iso15693
        case .tag(.miFare): type = .miFare
        case .tag: type = .unknown
        case .ndef: type = .ndef
        }
        return type.rawValue
    }

    public func identifier() -> [UInt8] {
        switch kind {
        case .tag(.feliCa(let tag)): [UInt8](tag.currentIDm)
        case .tag(.iso7816(let tag)): [UInt8](tag.identifier)
        case .tag(.iso15693(let tag)): [UInt8](tag.identifier)
        case .tag(.miFare(let tag)): [UInt8](tag.identifier)
        case .tag, .ndef: []
        }
    }

    public func isAvailable() -> Bool {
        kind.ndefTag?.isAvailable ?? false
    }

    public func historicalBytes() -> [UInt8]? {
        switch kind {
        case .tag(.iso7816(let tag)): tag.historicalBytes.map { [UInt8]($0) }
        case .tag(.miFare(let tag)): tag.historicalBytes.map { [UInt8]($0) }
        default: nil
        }
    }

    public func selectedApplicationIdentifier() -> String? {
        guard case .tag(.iso7816(let tag)) = kind else {
            return nil
        }
        return tag.initialSelectedAID
    }

    /// CoreNFC doesn't report a limit. These are the documented or
    /// conventional ones: a short APDU (261) for ISO 7816, 253 for MIFARE
    /// (as Android's NfcA), 254 for a FeliCa packet, 256 for an ISO 15693
    /// frame, and 0 in NDEF-only sessions.
    public func maximumTransceiveLength() -> Int32 {
        switch kind {
        case .tag(.iso7816): 261
        case .tag(.miFare): 253
        case .tag(.feliCa): 254
        case .tag(.iso15693): 256
        case .tag, .ndef: 0
        }
    }

    // MARK: NDEF

    public func queryNDEFStatus() {
        guard let (reader, tag) = connected(else: { $0.didQueryNDEF($1, tag: $2, status: 0, capacity: 0, error: $3) }) else {
            return
        }
        tag.queryNDEFStatus { status, capacity, error in
            onMain {
                let code = NFCErrorMapping.code(for: error, operation: "queryNDEFStatus")
                let ndefStatus = code == 0 ? Self.ndefStatus(status) : .notSupported
                reader.call {
                    $0.didQueryNDEF(reader, tag: self, status: ndefStatus.rawValue, capacity: Int32(clamping: capacity), error: code)
                }
            }
        }
    }

    /// An empty tag reads as a nil message without an error.
    public func readNDEF() {
        guard let (reader, tag) = connected(else: { $0.didReadNDEF($1, tag: $2, message: nil, error: $3) }) else {
            return
        }
        tag.readNDEF { message, error in
            onMain {
                let nsError = error as NSError?
                let isEmpty = nsError?.domain == NFCErrorMapping.domain && nsError?.code == 403  // zeroLengthMessage
                let code = isEmpty ? 0 : NFCErrorMapping.code(for: error, operation: "readNDEF")
                let result = code == 0 ? message.map(DarwinNDEFMessage.init) : nil
                reader.call { $0.didReadNDEF(reader, tag: self, message: result, error: code) }
            }
        }
    }

    /// A message without records is an invalid parameter: CoreNFC can't
    /// write one.
    public func writeNDEF(_ message: any NDEFMessage) {
        guard let (reader, tag) = connected(else: { $0.didWriteNDEF($1, tag: $2, error: $3) }) else {
            return
        }
        let records = DarwinNDEFMessage.copy(of: message).recordList
        guard !records.isEmpty else {
            AppHost.logger.error("NFCTag.writeNDEF: a message needs at least one record")
            return reader.later { $0.didWriteNDEF(reader, tag: self, error: NFCError.invalidParameter.rawValue) }
        }
        tag.writeNDEF(NFCNDEFMessage(records: records.map(\.corePayload))) { error in
            onMain {
                let code = NFCErrorMapping.code(for: error, operation: "writeNDEF")
                reader.call { $0.didWriteNDEF(reader, tag: self, error: code) }
            }
        }
    }

    public func writeLock() {
        guard let (reader, tag) = connected(else: { $0.didLock($1, tag: $2, error: $3) }) else {
            return
        }
        tag.writeLock { error in
            onMain {
                let code = NFCErrorMapping.code(for: error, operation: "writeLock")
                reader.call { $0.didLock(reader, tag: self, error: code) }
            }
        }
    }

    // MARK: Raw commands

    public func transceive(_ data: [UInt8]) {
        let fail: (any NFCReaderDelegate, DarwinNFCReader, DarwinNFCTag, Int32) -> Void = {
            $0.didTransceive($1, tag: $2, response: [], error: $3)
        }
        if case .ndef = kind, let reader {
            return reader.later { fail($0, reader, self, NFCError.notAvailableInNDEFSession.rawValue) }
        }
        guard let (reader, _) = connected(else: fail) else {
            return
        }
        func finish(_ response: [UInt8], _ error: (any Error)?) {
            onMain {
                let code = NFCErrorMapping.code(for: error, operation: "transceive")
                reader.call { $0.didTransceive(reader, tag: self, response: code == 0 ? response : [], error: code) }
            }
        }
        func invalid(_ message: String) {
            AppHost.logger.error("NFCTag.transceive: \(message, privacy: .public)")
            reader.later { fail($0, reader, self, NFCError.invalidParameter.rawValue) }
        }
        switch kind {
        case .tag(.iso7816(let tag)):
            guard let apdu = NFCISO7816APDU(data: Data(data)) else {
                return invalid("not an ISO 7816 APDU")
            }
            tag.sendCommand(apdu: apdu) { response, sw1, sw2, error in
                finish([UInt8](response) + [sw1, sw2], error)
            }
        case .tag(.miFare(let tag)):
            tag.sendMiFareCommand(commandPacket: Data(data)) { response, error in
                finish([UInt8](response), error)
            }
        case .tag(.feliCa(let tag)):
            tag.sendFeliCaCommand(commandPacket: Data(data)) { response, error in
                finish([UInt8](response), error)
            }
        case .tag(.iso15693(let tag)):
            guard data.count >= 2 else {
                return invalid("an ISO 15693 request needs the flags and a command code")
            }
            let parameters = data.count > 2 ? Data(data[2...]) : nil
            tag.sendRequest(requestFlags: Int(data[0]), commandCode: Int(data[1]), data: parameters) { result in
                switch result {
                case .success(let (flags, response)):
                    finish([flags.rawValue] + [UInt8](response ?? Data()), nil)
                case .failure(let error):
                    finish([], error)
                }
            }
        case .tag, .ndef:
            reader.later { fail($0, reader, self, NFCError.unknown.rawValue) }
        }
    }

    // MARK: Helpers

    /// The reader and the CoreNFC tag when this tag is connected. Otherwise
    /// reports `tagNotConnected` through `report` on the next main-queue
    /// turn and returns nil.
    private func connected(
        else report: @escaping (any NFCReaderDelegate, DarwinNFCReader, DarwinNFCTag, Int32) -> Void
    ) -> (DarwinNFCReader, any NFCNDEFTag)? {
        guard let reader else {
            AppHost.logger.error("NFCTag: the reader is gone; the operation can't report")
            return nil
        }
        guard reader.isConnected(self), let tag = kind.ndefTag else {
            reader.later { report($0, reader, self, NFCError.tagNotConnected.rawValue) }
            return nil
        }
        return (reader, tag)
    }

    static func ndefStatus(_ status: NFCNDEFStatus) -> NDEFStatus {
        switch status {
        case .notSupported: .notSupported
        case .readWrite: .readWrite
        case .readOnly: .readOnly
        @unknown default: .notSupported
        }
    }
}

// MARK: - NFCNDEFPayload conversions

extension DarwinNDEFRecord {

    convenience init(_ payload: NFCNDEFPayload) {
        self.init(
            format: NDEFTypeNameFormat(rawValue: Int32(payload.typeNameFormat.rawValue)) ?? .unknown,
            type: [UInt8](payload.type),
            identifier: [UInt8](payload.identifier),
            payload: [UInt8](payload.payload)
        )
    }

    var corePayload: NFCNDEFPayload {
        NFCNDEFPayload(
            format: NFCTypeNameFormat(rawValue: UInt8(truncatingIfNeeded: format.rawValue)) ?? .unknown,
            type: Data(recordType),
            identifier: Data(recordIdentifier),
            payload: Data(recordPayload)
        )
    }
}

extension DarwinNDEFMessage {

    convenience init(_ message: NFCNDEFMessage) {
        self.init(message.records.map(DarwinNDEFRecord.init))
    }
}
#endif
