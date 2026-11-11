import DynamicNFC
import DynamicRuntime
import Foundation
import Testing
@testable import DarwinNFC

/// Records what a module registers.
final class RecordingRegistrar: ContractRegistrar {

    var registered: [ContractDescriptor] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        registered.append(descriptor)
    }
}

/// A record the guest implemented itself.
final class GuestRecord: NDEFRecord {
    static func make(format: Int32, type: [UInt8], identifier: [UInt8], payload: [UInt8]) -> GuestRecord { GuestRecord() }
    static func makeURI(_ uri: String) -> GuestRecord? { nil }
    static func makeText(_ text: String, locale: String) -> GuestRecord { GuestRecord() }
    func typeNameFormat() -> Int32 { NDEFTypeNameFormat.media.rawValue }
    func type() -> [UInt8] { Array("text/plain".utf8) }
    func identifier() -> [UInt8] { [7] }
    func payload() -> [UInt8] { Array("hi".utf8) }
    func uri() -> String? { nil }
    func text() -> String? { nil }
}

@Suite struct DarwinNFCTests {

    // MARK: Module

    @Test func contractsListEverything() {
        let names = DarwinNFC.contracts.map(\.name)
        #expect(names == [
            NFCReaderProxy.descriptor.name, NFCReaderDelegateProxy.descriptor.name, NFCTagProxy.descriptor.name,
            NDEFMessageProxy.descriptor.name, NDEFRecordProxy.descriptor.name,
        ], "on every platform, so apps that use NFC start without it")
    }

    @Test func registration() {
        let registrar = RecordingRegistrar()
        DarwinNFC.register(in: registrar)
        if DarwinNFC.isSupported {
            #expect(Set(registrar.registered) == Set(DarwinNFC.contracts))
        } else {
            #expect(registrar.registered.isEmpty, "rt_class returns 0 for every NFC contract")
        }
    }

    @Test func permission() throws {
        let providers = DarwinNFC.permissionProviders()
        let nfc = try #require(providers[Capability("nfc")])
        #expect(providers.count == 1)
        if !DarwinNFC.isSupported {
            #expect(nfc.status() == .unavailable)
        }
        var answers: [PermissionStatus] = []
        nfc.request { answers.append($0) }
        #expect(answers == [nfc.status()], "no prompt: answers at once")
    }

    // MARK: Records

    @Test func rawRecord() {
        let record = DarwinNDEFRecord.make(
            format: NDEFTypeNameFormat.media.rawValue,
            type: Array("text/plain".utf8),
            identifier: [1, 2],
            payload: [3, 4, 5]
        )
        #expect(record.typeNameFormat() == NDEFTypeNameFormat.media.rawValue)
        #expect(record.type() == Array("text/plain".utf8))
        #expect(record.identifier() == [1, 2])
        #expect(record.payload() == [3, 4, 5])
        #expect(record.uri() == nil)
        #expect(record.text() == nil)

        let unknown = DarwinNDEFRecord.make(format: 9, type: [], identifier: [], payload: [])
        #expect(unknown.typeNameFormat() == NDEFTypeNameFormat.unknown.rawValue)

        let long = DarwinNDEFRecord.make(format: 4, type: Array(repeating: 0x61, count: 300), identifier: [], payload: [])
        #expect(long.type().count == 255, "a type length is one byte")
    }

    @Test(arguments: [
        ("https://www.apple.com", UInt8(0x02), "apple.com"),
        ("http://example.com/a?b=c", 0x03, "example.com/a?b=c"),
        ("tel:+15551234567", 0x05, "+15551234567"),
        ("mailto:someone@example.com", 0x06, "someone@example.com"),
        ("urn:nfc:wkt:U", 0x23, "wkt:U"),
        ("urn:isbn:0451450523", 0x13, "isbn:0451450523"),
        ("myapp://open/item", 0x00, "myapp://open/item"),
    ])
    func uriRecord(_ uri: String, _ code: UInt8, _ rest: String) throws {
        let record = try #require(DarwinNDEFRecord.makeURI(uri))
        #expect(record.typeNameFormat() == NDEFTypeNameFormat.wellKnown.rawValue)
        #expect(record.type() == Array("U".utf8))
        #expect(record.payload() == [code] + Array(rest.utf8), "the longest prefix is abbreviated")
        #expect(record.uri() == uri)
        #expect(record.text() == nil)
    }

    @Test(arguments: ["", "no scheme", "1http://example.com", "http://exa mple.com", "https://example.com/\n", ":empty"])
    func invalidURI(_ uri: String) {
        #expect(DarwinNDEFRecord.makeURI(uri) == nil)
    }

    @Test func uriWithReservedCode() {
        let record = DarwinNDEFRecord.make(format: 1, type: Array("U".utf8), identifier: [], payload: [0x24] + Array("x".utf8))
        #expect(record.uri() == nil)
    }

    @Test func textRecord() {
        let record = DarwinNDEFRecord.makeText("Grüße", locale: "de")
        #expect(record.type() == Array("T".utf8))
        #expect(record.payload() == [2] + Array("de".utf8) + Array("Grüße".utf8))
        #expect(record.text() == "Grüße")
        #expect(record.textLanguage == "de")
        #expect(record.uri() == nil)
    }

    @Test func utf16TextRecord() {
        // Status: UTF-16 (bit 7), language length 2.
        let header: [UInt8] = [0x82] + Array("en".utf8)
        let bigEndian = DarwinNDEFRecord.make(format: 1, type: Array("T".utf8), identifier: [], payload: header + [0x00, 0x68, 0x00, 0x69])
        #expect(bigEndian.text() == "hi")
        let marked = DarwinNDEFRecord.make(format: 1, type: Array("T".utf8), identifier: [], payload: header + [0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])
        #expect(marked.text() == "hi", "a byte order mark says little-endian")
        let truncated = DarwinNDEFRecord.make(format: 1, type: Array("T".utf8), identifier: [], payload: [0x05, 0x65])
        #expect(truncated.text() == nil)
    }

    // MARK: Messages

    @Test func messageCopiesRecords() {
        let own = DarwinNDEFRecord.makeText("hello", locale: "en")
        let message = DarwinNDEFMessage.make([own, GuestRecord()])
        let records = message.records()
        #expect(records.count == 2)
        #expect(records[0] === own, "this module's own records are kept")
        #expect(records[1] is DarwinNDEFRecord, "others are copied through the protocol")
        #expect(records[1].typeNameFormat() == NDEFTypeNameFormat.media.rawValue)
        #expect(records[1].identifier() == [7])
        #expect(records[1].payload() == Array("hi".utf8))
    }

    @Test func encoding() throws {
        let uri = try #require(DarwinNDEFRecord.makeURI("https://www.apple.com"))
        let message = DarwinNDEFMessage.make([uri])
        // MB ME SR, TNF 1; type length 1; payload length 10; "U"; code 2; "apple.com".
        #expect(message.encoded() == [0xD1, 0x01, 0x0A, 0x55, 0x02] + Array("apple.com".utf8))
        #expect(message.length() == 14)

        let empty = DarwinNDEFMessage.make([])
        #expect(empty.encoded() == [0xD0, 0x00, 0x00], "one empty record")
        #expect(empty.length() == 3)
    }

    @Test func encodingFlags() throws {
        let first = DarwinNDEFRecord.make(format: 2, type: Array("a/b".utf8), identifier: [9], payload: Array(repeating: 1, count: 300))
        let second = DarwinNDEFRecord.makeText("x", locale: "en")
        let message = DarwinNDEFMessage.make([first, second])
        let bytes = message.encoded()
        #expect(bytes[0] == UInt8(0x80 | 0x08 | 0x02), "MB, IL, no SR for a 300-byte payload, TNF 2")
        #expect(Array(bytes[2...5]) == [0, 0, 0x01, 0x2C], "a four-byte payload length")
        #expect(bytes[6] == 1, "identifier length")
        // Header, type length, payload length, identifier length, type,
        // identifier, payload.
        let firstLength: Int = 1 + 1 + 4 + 1 + 3 + 1 + 300
        let secondHeader = bytes[firstLength]
        #expect(secondHeader == UInt8(0x40 | 0x10 | 0x01), "ME, SR, TNF 1")
        #expect(message.length() == Int32(bytes.count))

        let decoded = try #require(DarwinNDEFMessage.decode(bytes))
        #expect(decoded.recordList.count == 2)
        #expect(decoded.recordList[0].identifier() == [9])
        #expect(decoded.recordList[0].payload().count == 300)
        #expect(decoded.recordList[1].text() == "x")
        #expect(decoded.encoded() == bytes)
    }

    @Test func decoding() {
        #expect(DarwinNDEFMessage.decode([0xD0, 0x00, 0x00])?.recordList.isEmpty == true)
        #expect(DarwinNDEFMessage.decode([0xD1, 0x01, 0x05, 0x55]) == nil, "truncated")
        #expect(DarwinNDEFMessage.decode([0xF1, 0x01, 0x01, 0x55, 0x00]) == nil, "chunked")
        #expect(DarwinNDEFMessage.decode([0xD1, 0x01, 0x01, 0x55, 0x00, 0xFF]) == nil, "bytes after the last record")
    }

    // MARK: Errors

    @Test func errorCodes() {
        #expect(NFCErrorMapping.code(1) == .unsupported)
        #expect(NFCErrorMapping.code(2) == .missingDeclaration)
        #expect(NFCErrorMapping.code(6) == .disabled)
        #expect(NFCErrorMapping.code(100) == .tagConnectionLost)
        #expect(NFCErrorMapping.code(102) == .transceiveFailed)
        #expect(NFCErrorMapping.code(104) == .tagNotConnected)
        #expect(NFCErrorMapping.code(200) == .userCancelled)
        #expect(NFCErrorMapping.code(201) == .sessionTimeout)
        #expect(NFCErrorMapping.code(202) == nil)
        #expect(NFCErrorMapping.code(202, inBackground: true) == .appInBackground)
        #expect(NFCErrorMapping.code(203) == .systemBusy)
        #expect(NFCErrorMapping.code(400) == .tagReadOnly)
        #expect(NFCErrorMapping.code(402) == .capacityExceeded)
        #expect(NFCErrorMapping.code(500) == nil)
    }

    @Test func errorValues() {
        let domain = NFCErrorMapping.domain
        #expect(NFCErrorMapping.code(for: nil, operation: "test") == 0)
        #expect(NFCErrorMapping.code(for: NSError(domain: domain, code: 200), operation: "test") == NFCError.userCancelled.rawValue)
        #expect(NFCErrorMapping.code(for: NSError(domain: domain, code: 202), operation: "test") == NFCError.unknown.rawValue)
        #expect(NFCErrorMapping.code(for: NSError(domain: domain, code: 202), operation: "test", inBackground: true) == NFCError.appInBackground.rawValue)
        #expect(NFCErrorMapping.code(for: NSError(domain: NSPOSIXErrorDomain, code: 1), operation: "test") == NFCError.unknown.rawValue)
    }
}
