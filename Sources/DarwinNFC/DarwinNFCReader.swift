#if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
import CoreNFC
import DarwinHost
import DynamicNFC
import Foundation
@preconcurrency import UIKit

/// The `NFCReader` contract over CoreNFC's reader sessions.
///
/// `begin` picks the session by the requested tag types:
/// - `.ndef` alone: an `NFCNDEFReaderSession` in read-write mode (its
///   delegate implements `didDetectTags`). No `TAG` entitlement format is
///   needed, but tags have no UID and no raw commands.
/// - any of `.iso14443`, `.iso15693`, `.iso18092`: an `NFCTagReaderSession`
///   polling for them. `.ndef` combined with them is an invalid parameter.
///
/// Sessions run on the main queue, so CoreNFC's delegate callbacks arrive on
/// the main thread; tag completion handlers hop there if they don't.
///
/// A reader runs one session at a time. After `didInvalidate`, `begin` may
/// start another; the contract tells guests to make a new reader, and both
/// work.
///
/// Errors map with `NFCErrorMapping`. Failures found before CoreNFC is
/// involved (a second `begin`, an unknown tag, a call without a
/// connection) are reported on the next main-queue turn, never inside the
/// guest's call.
public final class DarwinNFCReader: NFCReader {

    /// Kept strongly (`HostRuntime.md` §5).
    let delegate: any NFCReaderDelegate

    /// CoreNFC holds its delegate weakly; this reader holds it.
    private lazy var sessionDelegate = SessionDelegate(reader: self)

    private(set) var session: NFCReaderSession?

    private var active = false

    /// `invalidate` was called: CoreNFC then reports "user canceled", which
    /// the contract reports as success.
    private var invalidatedByApp = false

    /// One wrapper per CoreNFC tag object, for the session's lifetime
    /// (`HostRuntime.md` §5, identity).
    private var tags: [ObjectIdentifier: DarwinNFCTag] = [:]

    private(set) weak var connectedTag: DarwinNFCTag?

    init(delegate: any NFCReaderDelegate) {
        self.delegate = delegate
    }

    deinit {
        session?.invalidate()
    }

    public static func availability() -> Int32 {
        (NFCReaderSession.readingAvailable ? NFCAvailability.available : .unsupported).rawValue
    }

    public static func make(_ delegate: any NFCReaderDelegate) -> DarwinNFCReader {
        DarwinNFCReader(delegate: delegate)
    }

    public func begin(_ tagTypes: Int32, alertMessage: String?) {
        guard !active else {
            return fail(.systemBusy, "begin: this reader's session is already active")
        }
        guard NFCReaderSession.readingAvailable else {
            return fail(.unsupported, "begin: this device can't read NFC tags")
        }
        let types = NFCTagTypes(rawValue: tagTypes)
        let known: NFCTagTypes = [.ndef, .iso14443, .iso15693, .iso18092]
        if !types.subtracting(known).isEmpty {
            AppHost.logger.warning("NFCReader.begin: unknown tag types \(tagTypes, privacy: .public) ignored")
        }
        let session: NFCReaderSession
        if types.contains(.ndef) {
            guard types.intersection(known) == .ndef else {
                return fail(.invalidParameter, "begin: .ndef can't be combined with other tag types")
            }
            session = NFCNDEFReaderSession(delegate: sessionDelegate, queue: .main, invalidateAfterFirstRead: false)
        } else {
            var polling: NFCTagReaderSession.PollingOption = []
            if types.contains(.iso14443) { polling.insert(.iso14443) }
            if types.contains(.iso15693) { polling.insert(.iso15693) }
            if types.contains(.iso18092) { polling.insert(.iso18092) }
            guard !polling.isEmpty else {
                return fail(.invalidParameter, "begin: no tag types")
            }
            guard let tagSession = NFCTagReaderSession(pollingOption: polling, delegate: sessionDelegate, queue: .main) else {
                return fail(.unsupported, "begin: CoreNFC refused the tag reader session")
            }
            session = tagSession
        }
        if let alertMessage {
            session.alertMessage = alertMessage
        }
        self.session = session
        active = true
        invalidatedByApp = false
        tags = [:]
        connectedTag = nil
        session.begin()
    }

    public func setAlertMessage(_ message: String) {
        session?.alertMessage = message
    }

    public func restartPolling() {
        connectedTag = nil
        switch session {
        case let session as NFCTagReaderSession:
            session.restartPolling()
        case let session as NFCNDEFReaderSession:
            session.restartPolling()
        default:
            AppHost.logger.warning("NFCReader.restartPolling: no active session")
        }
    }

    public func connect(_ tag: any DynamicNFC.NFCTag) {
        guard let own = DarwinNFC.host(tag, as: DarwinNFCTag.self), own.reader === self else {
            AppHost.logger.error("NFCReader.connect: the tag wasn't detected by this reader")
            return later { $0.didConnect(self, tag: tag, error: NFCError.invalidParameter.rawValue) }
        }
        let completion: @Sendable ((any Error)?) -> Void = { [self] error in
            onMain {
                let code = NFCErrorMapping.code(for: error, operation: "connect")
                if code == 0 {
                    self.connectedTag = own
                }
                self.call { $0.didConnect(self, tag: own, error: code) }
            }
        }
        switch (session, own.kind) {
        case let (session as NFCTagReaderSession, .tag(coreTag)):
            session.connect(to: coreTag, completionHandler: completion)
        case let (session as NFCNDEFReaderSession, .ndef(ndefTag)):
            session.connect(to: ndefTag, completionHandler: completion)
        default:
            later { $0.didConnect(self, tag: own, error: NFCError.tagNotConnected.rawValue) }
        }
    }

    public func invalidate(_ errorMessage: String?) {
        guard active, let session else { return }
        invalidatedByApp = true
        if let errorMessage {
            session.invalidate(errorMessage: errorMessage)
        } else {
            session.invalidate()
        }
    }

    public func isActive() -> Bool {
        active
    }

    // MARK: Session events

    fileprivate func sessionDidBecomeActive(_ session: NFCReaderSession) {
        guard session === self.session else { return }
        call { $0.didBecomeActive(self) }
    }

    fileprivate func session(_ session: NFCReaderSession, didDetect detected: [DarwinNFCTag.Kind]) {
        guard session === self.session else { return }
        connectedTag = nil
        let wrapped = detected.map { kind -> DarwinNFCTag in
            let key = ObjectIdentifier(kind.object)
            if let existing = tags[key] {
                return existing
            }
            let tag = DarwinNFCTag(kind: kind, reader: self)
            tags[key] = tag
            return tag
        }
        call { $0.didDetect(self, tags: wrapped) }
    }

    fileprivate func session(_ session: NFCReaderSession, didInvalidateWith error: any Error) {
        guard session === self.session else { return }
        let nsError = error as NSError
        let code: Int32
        let isNormalEnd = nsError.domain == NFCErrorMapping.domain
            // firstNDEFTagRead, or userCanceled after `invalidate`.
            && (nsError.code == 204 || (invalidatedByApp && nsError.code == 200))
        if isNormalEnd {
            code = 0
        } else {
            let inBackground = UIApplication.shared.applicationState != .active
            code = NFCErrorMapping.code(for: error, operation: "session", inBackground: inBackground)
        }
        finish(code, message: code == 0 ? nil : nsError.localizedDescription)
    }

    // MARK: Delivery

    /// Ends the session and tells the delegate.
    private func finish(_ code: Int32, message: String?) {
        active = false
        session = nil
        connectedTag = nil
        call { $0.didInvalidate(self, error: code, message: message) }
    }

    /// A failure found before CoreNFC is involved: the session never
    /// started, so it ends on the next main-queue turn.
    private func fail(_ error: NFCError, _ message: String) {
        AppHost.logger.error("NFCReader.\(message, privacy: .public)")
        DispatchQueue.main.async { [self] in
            call { $0.didInvalidate(self, error: error.rawValue, message: message) }
        }
    }

    /// One host→guest call.
    func call(_ body: (any NFCReaderDelegate) -> Void) {
        autoreleasepool {
            body(delegate)
        }
    }

    /// A host→guest call on the next main-queue turn.
    func later(_ body: @escaping (any NFCReaderDelegate) -> Void) {
        DispatchQueue.main.async { [self] in
            call(body)
        }
    }

    /// Whether a tag operation on `tag` may go ahead: the session is active
    /// and `tag` is the connected tag.
    func isConnected(_ tag: DarwinNFCTag) -> Bool {
        active && connectedTag === tag
    }
}

/// Runs `body` on the main thread: now if already there.
func onMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread {
        body()
    } else {
        DispatchQueue.main.async(execute: body)
    }
}

/// CoreNFC's session delegates, forwarding to the reader. Both session
/// kinds use it.
private final class SessionDelegate: NSObject, NFCTagReaderSessionDelegate, NFCNDEFReaderSessionDelegate {

    unowned let reader: DarwinNFCReader

    init(reader: DarwinNFCReader) {
        self.reader = reader
    }

    // MARK: NFCTagReaderSessionDelegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        reader.sessionDidBecomeActive(session)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [CoreNFC.NFCTag]) {
        reader.session(session, didDetect: tags.map(DarwinNFCTag.Kind.tag))
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: any Error) {
        reader.session(session, didInvalidateWith: error)
    }

    // MARK: NFCNDEFReaderSessionDelegate

    func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {
        reader.sessionDidBecomeActive(session)
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [any NFCNDEFTag]) {
        reader.session(session, didDetect: tags.map(DarwinNFCTag.Kind.ndef))
    }

    /// Not called: implementing `didDetect tags` makes the session
    /// read-write, and CoreNFC then reports tags instead of messages.
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) { }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: any Error) {
        reader.session(session, didInvalidateWith: error)
    }
}
#endif
