import Foundation

/// Answers a test session's requests without a network. Each test sets a
/// handler for its URL path before starting a task.
final class MockURLProtocol: URLProtocol {

    /// Handlers by URL path. Set on the main thread before a task starts;
    /// read on URLSession's loading thread.
    nonisolated(unsafe) static var handlers: [String: (MockURLProtocol) -> Void] = [:]

    /// Requests that reached the protocol, by path.
    nonisolated(unsafe) static var started: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.started.append(path)
        guard let handler = Self.handlers[path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        handler(self)
    }

    override func stopLoading() { }

    // MARK: Answers

    /// The request body, whether URLSession passed it as data or a stream.
    var requestBody: [UInt8] {
        if let body = request.httpBody {
            return [UInt8](body)
        }
        guard let stream = request.httpBodyStream else {
            return []
        }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        return bytes
    }

    func respond(status: Int, headers: [String: String] = [:], chunks: [[UInt8]]) {
        client?.urlProtocol(self, didReceive: response(status: status, headers: headers), cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: Data(chunk))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Sends one chunk at a time, `interval` seconds apart, from the loading
    /// thread's run loop, so URLSession delivers them separately.
    func stream(status: Int, chunks: [[UInt8]], interval: TimeInterval) {
        client?.urlProtocol(self, didReceive: response(status: status, headers: [:]), cacheStoragePolicy: .notAllowed)
        var remaining = chunks
        let timer = Timer(timeInterval: interval, repeats: true) { [self] timer in
            guard !remaining.isEmpty else {
                timer.invalidate()
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didLoad: Data(remaining.removeFirst()))
        }
        RunLoop.current.add(timer, forMode: .common)
    }

    private func response(status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func redirect(to location: String, status: Int = 302) {
        let url = URL(string: location, relativeTo: request.url)!.absoluteURL
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
        var newRequest = request
        newRequest.url = url
        client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: response)
        // If the delegate refuses the redirect, the redirect is the response.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    func challenge(method: String, realm: String, previousFailureCount: Int = 0, answer: @escaping (URLCredential?) -> Void) {
        let space = URLProtectionSpace(
            host: request.url!.host!,
            port: 443,
            protocol: "https",
            realm: realm,
            authenticationMethod: method
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender(answer)
        )
        client?.urlProtocol(self, didReceive: challenge)
    }
}

/// Passes the answer to a challenge from `MockURLProtocol` to its handler.
final class ChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {

    let answer: (URLCredential?) -> Void

    init(_ answer: @escaping (URLCredential?) -> Void) {
        self.answer = answer
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        answer(credential)
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        answer(nil)
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        answer(nil)
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        answer(nil)
    }

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        answer(nil)
    }
}
