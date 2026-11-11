import DynamicNetworking
import DynamicRuntime
import Foundation
import RuntimeABI
import Testing

/// Records one task's events, as a guest delegate would see them.
final class RecordingTaskDelegate: HTTPTaskDelegate {

    var events: [String] = []

    var chunks: [[UInt8]] = []

    var body: [UInt8] {
        chunks.flatMap { $0 }
    }

    var response: (any HTTPResponse)?

    var error: Int32?

    var message: String?

    var challenges: [(method: Int32, host: String, realm: String?, previousFailureCount: Int32)] = []

    var redirects: [(status: Int32, url: String)] = []

    /// The answer to `willPerformRedirect`.
    var followsRedirects = true

    /// The answer to `didReceiveChallenge`.
    var credential: (() -> (any HTTPCredential)?)?

    /// The answer to `didReceiveResponse`.
    var allowsResponse = true

    private var continuation: CheckedContinuation<Void, Never>?

    var isComplete: Bool {
        error != nil
    }

    /// Returns once `didComplete` has been called.
    func completion() async {
        if isComplete { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func willPerformRedirect(_ task: any HTTPTask, response: any HTTPResponse, newRequest: any HTTPRequest) -> Bool {
        events.append("redirect")
        redirects.append((response.statusCode(), newRequest.url()))
        return followsRedirects
    }

    func didReceiveChallenge(_ task: any HTTPTask, method: Int32, host: String, realm: String?, previousFailureCount: Int32) -> (any HTTPCredential)? {
        events.append("challenge")
        challenges.append((method, host, realm, previousFailureCount))
        return credential?()
    }

    func didReceiveResponse(_ task: any HTTPTask, response: any HTTPResponse) -> Bool {
        events.append("response")
        self.response = response
        return allowsResponse
    }

    func didReceiveData(_ task: any HTTPTask, data: [UInt8]) {
        events.append("data")
        chunks.append(data)
    }

    func didSendBodyData(_ task: any HTTPTask, bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        events.append("sent \(totalBytesSent)/\(totalBytesExpectedToSend)")
    }

    func taskIsWaitingForConnectivity(_ task: any HTTPTask) {
        events.append("waiting")
    }

    func didComplete(_ task: any HTTPTask, error: Int32, message: String?) {
        #expect(Thread.isMainThread)
        events.append("complete \(error)")
        self.error = error
        self.message = message
        continuation?.resume()
        continuation = nil
    }
}

/// Records what a module registers.
final class RecordingRegistrar: ContractRegistrar {

    var registered: [(name: String, implemented: Bool)] = []

    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        // `statics != nil` needs typed-throws runtime support (macOS 15).
        let implemented: Bool
        if case .some = statics {
            implemented = true
        } else {
            implemented = false
        }
        registered.append((descriptor.name, implemented))
    }
}
