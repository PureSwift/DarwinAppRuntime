import DynamicNetworking
import DynamicRuntime
import Foundation
import Testing
@testable import DarwinNetworking

/// The URLSession-backed contracts against `MockURLProtocol`, on the main
/// thread, where URLSession delivers callbacks. Serialized: the mock's
/// handlers are shared.
@MainActor
@Suite(.serialized) struct DarwinHTTPSessionTests {

    init() {
        MockURLProtocol.handlers = [:]
        MockURLProtocol.started = []
    }

    func makeSession(_ configure: (DarwinHTTPSessionConfiguration) -> Void = { _ in }) -> DarwinHTTPSession {
        let configuration = DarwinHTTPSessionConfiguration.makeEphemeral()
        configuration.urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        configuration.setTimeoutForRequest(5)
        configure(configuration)
        return DarwinHTTPSession.make(configuration)
    }

    func request(_ path: String) throws -> DarwinHTTPRequest {
        try #require(DarwinHTTPRequest.make(url: "https://example.com\(path)"))
    }

    /// Runs a task to completion.
    @discardableResult
    func run(_ task: any HTTPTask, _ delegate: RecordingTaskDelegate) async -> RecordingTaskDelegate {
        task.resume()
        await delegate.completion()
        return delegate
    }

    /// Waits up to five seconds for `condition`, letting the main queue run.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func roundTrip() async throws {
        MockURLProtocol.handlers["/echo"] = { loader in
            let request = loader.request
            loader.respond(
                status: 201,
                headers: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "X-Method": request.httpMethod ?? "",
                    "X-Echo": request.value(forHTTPHeaderField: "X-Test") ?? "",
                    "X-Extra": request.value(forHTTPHeaderField: "X-Extra") ?? "",
                ],
                chunks: [loader.requestBody]
            )
        }
        let session = makeSession { $0.setAdditionalHeader("X-Extra", value: "session") }
        let request = try request("/echo")
        request.setMethod("PUT")
        request.setHeader("X-Test", value: "hello")
        request.setBody(Array("payload".utf8))
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(request, delegate: delegate)
        #expect(task.state() == HTTPTaskState.suspended.rawValue)
        await run(task, delegate)

        #expect(delegate.error == 0)
        #expect(delegate.message == nil)
        let response = try #require(delegate.response)
        #expect(response.statusCode() == 201)
        #expect(response.url() == "https://example.com/echo")
        #expect(response.header("x-method") == "PUT", "lookup is case-insensitive")
        #expect(response.header("X-Echo") == "hello")
        #expect(response.header("X-Extra") == "session")
        #expect(response.headerNames().contains("X-Method"))
        #expect(response.mimeType() == "text/plain")
        #expect(delegate.body == Array("payload".utf8))
        #expect(delegate.events.first == "response")
        #expect(delegate.events.last == "complete 0")

        #expect(task.state() == HTTPTaskState.completed.rawValue)
        #expect(task.originalRequest().method() == "PUT")
        #expect(task.response() === response, "one wrapper per response")
        #expect(task.countOfBytesReceived() == Int64("payload".utf8.count))
    }

    @Test func uploadReportsProgress() async throws {
        MockURLProtocol.handlers["/upload"] = { loader in
            loader.respond(status: 200, chunks: [Array("\(loader.requestBody.count)".utf8)])
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        await run(session.uploadTask(try request("/upload"), body: [UInt8](repeating: 7, count: 100), delegate: delegate), delegate)
        #expect(delegate.error == 0)
        #expect(delegate.body == Array("100".utf8))
    }

    /// URLSession coalesces small chunks that arrive close together.
    static let chunks: [[UInt8]] = [
        [UInt8](repeating: 1, count: 8192), [UInt8](repeating: 2, count: 8192), [3],
    ]

    @Test func streamsChunks() async throws {
        MockURLProtocol.handlers["/chunks"] = { loader in
            loader.stream(status: 200, chunks: Self.chunks, interval: 0.1)
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        await run(session.dataTask(try request("/chunks"), delegate: delegate), delegate)
        #expect(delegate.error == 0)
        #expect(delegate.chunks == Self.chunks)
        #expect(delegate.events == ["response", "data", "data", "data", "complete 0"])
    }

    @Test func followsAnAllowedRedirect() async throws {
        MockURLProtocol.handlers["/old"] = { $0.redirect(to: "/new") }
        MockURLProtocol.handlers["/new"] = { $0.respond(status: 200, chunks: [[42]]) }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(try request("/old"), delegate: delegate)
        await run(task, delegate)
        #expect(delegate.error == 0)
        #expect(delegate.redirects.map(\.status) == [302])
        #expect(delegate.redirects.map(\.url) == ["https://example.com/new"])
        #expect(delegate.response?.statusCode() == 200)
        #expect(delegate.response?.url() == "https://example.com/new")
        #expect(delegate.body == [42])
        #expect(task.currentRequest()?.url() == "https://example.com/new")
        #expect(task.originalRequest().url() == "https://example.com/old")
    }

    @Test func refusedRedirectCompletesWithTheRedirect() async throws {
        MockURLProtocol.handlers["/old"] = { $0.redirect(to: "/new") }
        MockURLProtocol.handlers["/new"] = { $0.respond(status: 200, chunks: [[42]]) }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.followsRedirects = false
        await run(session.dataTask(try request("/old"), delegate: delegate), delegate)
        #expect(delegate.redirects.count == 1)
        #expect(delegate.error == 0)
        #expect(delegate.response?.statusCode() == 302)
        #expect(!MockURLProtocol.started.contains("/new"))
    }

    @Test func answersAChallengeWithACredential() async throws {
        MockURLProtocol.handlers["/private"] = { loader in
            loader.challenge(method: NSURLAuthenticationMethodHTTPBasic, realm: "test") { credential in
                if let credential, credential.user == "user", credential.password == "secret" {
                    loader.respond(status: 200, chunks: [Array("welcome".utf8)])
                } else {
                    loader.respond(status: 401, chunks: [])
                }
            }
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.credential = {
            DarwinHTTPCredential.make(user: "user", password: "secret", persistence: HTTPCredentialPersistence.none.rawValue)
        }
        await run(session.dataTask(try request("/private"), delegate: delegate), delegate)
        #expect(delegate.challenges.count == 1)
        #expect(delegate.challenges.first?.method == HTTPAuthenticationMethod.basic.rawValue)
        #expect(delegate.challenges.first?.host == "example.com")
        #expect(delegate.challenges.first?.realm == "test")
        #expect(delegate.challenges.first?.previousFailureCount == 0)
        #expect(delegate.response?.statusCode() == 200)
        #expect(delegate.body == Array("welcome".utf8))
    }

    @Test func noCredentialUsesTheDefaultHandling() async throws {
        MockURLProtocol.handlers["/private"] = { loader in
            loader.challenge(method: NSURLAuthenticationMethodHTTPDigest, realm: "test") { credential in
                loader.respond(status: credential == nil ? 401 : 200, chunks: [])
            }
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        await run(session.dataTask(try request("/private"), delegate: delegate), delegate)
        #expect(delegate.challenges.first?.method == HTTPAuthenticationMethod.digest.rawValue)
        #expect(delegate.response?.statusCode() == 401)
    }

    @Test func mapsFailures() async throws {
        MockURLProtocol.handlers["/slow"] = { $0.fail(URLError(.timedOut)) }
        MockURLProtocol.handlers["/plain"] = { $0.fail(URLError(.appTransportSecurityRequiresSecureConnection)) }
        MockURLProtocol.handlers["/odd"] = { $0.fail(NSError(domain: "Odd", code: 7)) }
        let session = makeSession()
        let expected: [(String, NetworkError)] = [
            ("/slow", .timedOut), ("/plain", .insecureConnectionNotAllowed), ("/odd", .unknown),
        ]
        for (path, error) in expected {
            let delegate = RecordingTaskDelegate()
            await run(session.dataTask(try request(path), delegate: delegate), delegate)
            #expect(delegate.error == error.rawValue, "\(path)")
            #expect(delegate.message != nil)
            #expect(delegate.response == nil)
        }
    }

    @Test func errorTable() {
        func code(_ error: Error) -> NetworkError {
            NetworkError(urlSessionError: error)
        }
        #expect(code(URLError(.cancelled)) == .cancelled)
        #expect(code(URLError(.unsupportedURL)) == .invalidURL)
        #expect(code(URLError(.dnsLookupFailed)) == .cannotFindHost)
        #expect(code(URLError(.cannotConnectToHost)) == .cannotConnectToHost)
        #expect(code(URLError(.networkConnectionLost)) == .connectionLost)
        #expect(code(URLError(.notConnectedToInternet)) == .notConnectedToInternet)
        #expect(code(URLError(.dataNotAllowed)) == .networkAccessNotAllowed)
        #expect(code(URLError(.secureConnectionFailed)) == .secureConnectionFailed)
        #expect(code(URLError(.serverCertificateHasUnknownRoot)) == .serverCertificateUntrusted)
        #expect(code(URLError(.httpTooManyRedirects)) == .tooManyRedirects)
        #expect(code(URLError(.badServerResponse)) == .badServerResponse)
        #expect(code(URLError(.userAuthenticationRequired)) == .userAuthenticationRequired)
        #expect(code(URLError(.resourceUnavailable)) == .resourceUnavailable)
        #expect(code(URLError(.cannotLoadFromNetwork)) == .resourceUnavailable)
        #expect(code(URLError(.backgroundSessionWasDisconnected)) == .unknown)
        #expect(code(CocoaError(.fileNoSuchFile)) == .unknown)
    }

    @Test func refusingTheResponseCancels() async throws {
        MockURLProtocol.handlers["/big"] = { $0.respond(status: 200, chunks: [[1], [2]]) }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        delegate.allowsResponse = false
        await run(session.dataTask(try request("/big"), delegate: delegate), delegate)
        #expect(delegate.error == NetworkError.cancelled.rawValue)
        #expect(delegate.chunks.isEmpty)
    }

    @Test func cancellation() async throws {
        MockURLProtocol.handlers["/hold"] = { _ in }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(try request("/hold"), delegate: delegate)
        task.resume()
        await waitUntil { MockURLProtocol.started.contains("/hold") }
        #expect(task.state() == HTTPTaskState.running.rawValue)
        task.cancel()
        await delegate.completion()
        #expect(delegate.error == NetworkError.cancelled.rawValue)
        #expect(delegate.events == ["complete 2"])
        #expect(task.state() == HTTPTaskState.completed.rawValue)
    }

    @Test func cancellingBeforeResume() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let task = session.dataTask(try request("/never"), delegate: delegate)
        task.cancel()
        await delegate.completion()
        #expect(delegate.error == NetworkError.cancelled.rawValue)
        #expect(MockURLProtocol.started.isEmpty)
    }

    @Test func invalidateAndCancelReleasesTheDelegates() async throws {
        MockURLProtocol.handlers["/hold"] = { _ in }
        let session = makeSession()
        weak let sessionDelegate = session.urlSession.delegate as? SessionDelegate
        weak var taskDelegate: RecordingTaskDelegate?
        do {
            let delegate = RecordingTaskDelegate()
            taskDelegate = delegate
            session.dataTask(try request("/hold"), delegate: delegate).resume()
            await waitUntil { MockURLProtocol.started.contains("/hold") }
            session.invalidateAndCancel()
            await delegate.completion()
            #expect(delegate.error == NetworkError.cancelled.rawValue)
        }
        await waitUntil { taskDelegate == nil && sessionDelegate == nil }
        #expect(taskDelegate == nil, "the task let its delegate go")
        #expect(sessionDelegate == nil, "URLSession let its delegate go")

        // New tasks fail.
        let late = RecordingTaskDelegate()
        let task = session.dataTask(try request("/hold"), delegate: late)
        #expect(task.identifier() < 0)
        await run(task, late)
        #expect(late.error == NetworkError.sessionInvalidated.rawValue)
    }

    @Test func finishTasksAndInvalidateLetsRunningTasksFinish() async throws {
        MockURLProtocol.handlers["/slow"] = { $0.respond(status: 200, chunks: [[1]]) }
        let session = makeSession()
        weak let sessionDelegate = session.urlSession.delegate as? SessionDelegate
        let delegate = RecordingTaskDelegate()
        session.dataTask(try request("/slow"), delegate: delegate).resume()
        session.finishTasksAndInvalidate()
        await delegate.completion()
        #expect(delegate.error == 0)
        #expect(delegate.body == [1])
        await waitUntil { sessionDelegate == nil }
        #expect(sessionDelegate == nil)
    }

    @Test func releasingTheSessionInvalidatesIt() async throws {
        weak var sessionDelegate: SessionDelegate?
        do {
            let session = makeSession()
            sessionDelegate = session.urlSession.delegate as? SessionDelegate
            #expect(sessionDelegate != nil)
        }
        await waitUntil { sessionDelegate == nil }
        #expect(sessionDelegate == nil)
    }

    @Test func invalidURLFailsOnResume() async throws {
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        let request = GuestRequest(url: "ftp://example.com/file")
        let task = session.dataTask(request, delegate: delegate)
        await run(task, delegate)
        #expect(delegate.error == NetworkError.invalidURL.rawValue)
        #expect(task.originalRequest() === request)
    }

    @Test func guestImplementedRequest() async throws {
        MockURLProtocol.handlers["/echo"] = { loader in
            loader.respond(status: 200, headers: ["X-Method": loader.request.httpMethod ?? ""], chunks: [loader.requestBody])
        }
        let session = makeSession()
        let delegate = RecordingTaskDelegate()
        await run(session.dataTask(GuestRequest(url: "https://example.com/echo"), delegate: delegate), delegate)
        #expect(delegate.response?.header("X-Method") == "POST")
        #expect(delegate.body == [1, 2, 3])
    }

    @Test func sharedSessionIgnoresInvalidation() {
        let shared = DarwinHTTPSession.shared()
        #expect(DarwinHTTPSession.shared() === shared)
        shared.invalidateAndCancel()
        #expect(!shared.isInvalidated)
    }
}

/// A request the guest implemented itself, read through the protocol.
final class GuestRequest: HTTPRequest {
    let urlValue: String
    init(url: String) { urlValue = url }
    static func make(url: String) -> GuestRequest? { GuestRequest(url: url) }
    func url() -> String { urlValue }
    func setMethod(_ method: String) { }
    func method() -> String { "POST" }
    func setHeader(_ name: String, value: String?) { }
    func header(_ name: String) -> String? { name == "Content-Type" ? "application/octet-stream" : nil }
    func headerNames() -> [String] { ["Content-Type"] }
    func setBody(_ body: [UInt8]?) { }
    func body() -> [UInt8]? { [1, 2, 3] }
    func setTimeout(_ seconds: Double) { }
    func timeout() -> Double { 0 }
    func setCachePolicy(_ policy: Int32) { }
    func cachePolicy() -> Int32 { 0 }
}

/// The value contracts, without a session.
@Suite struct DarwinNetworkingValueTests {

    @Test func requestDefaults() throws {
        #expect(DarwinHTTPRequest.make(url: "ftp://example.com") == nil)
        #expect(DarwinHTTPRequest.make(url: "/relative") == nil)
        #expect(DarwinHTTPRequest.make(url: "http://") == nil)
        let request = try #require(DarwinHTTPRequest.make(url: "HTTPS://example.com/a"))
        #expect(request.method() == "GET")
        #expect(request.body() == nil)
        #expect(request.timeout() == 0)
        #expect(request.cachePolicy() == HTTPCachePolicy.useProtocolCachePolicy.rawValue)
        #expect(request.headerNames().isEmpty)
    }

    @Test func requestHeadersAndSessionDefaults() throws {
        let request = try #require(DarwinHTTPRequest.make(url: "https://example.com"))
        request.setHeader("Accept", value: "a")
        request.setHeader("accept", value: "b")
        #expect(request.header("ACCEPT") == "b", "replaces, case-insensitively")
        request.setHeader("Accept", value: nil)
        #expect(request.header("Accept") == nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .returnCacheDataDontLoad
        var urlRequest = request.urlRequest(in: configuration)
        #expect(urlRequest.timeoutInterval == 12)
        #expect(urlRequest.cachePolicy == .returnCacheDataDontLoad)

        request.setTimeout(3)
        request.setCachePolicy(HTTPCachePolicy.reloadIgnoringLocalCacheData.rawValue)
        urlRequest = request.urlRequest(in: configuration)
        #expect(urlRequest.timeoutInterval == 3)
        #expect(urlRequest.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.cachePolicy() == HTTPCachePolicy.reloadIgnoringLocalCacheData.rawValue)
    }

    @Test func configuration() {
        let configuration = DarwinHTTPSessionConfiguration.makeDefault()
        #expect(configuration.timeoutForRequest() == 60)
        configuration.setTimeoutForRequest(5)
        configuration.setTimeoutForResource(50)
        configuration.setAllowsCellularAccess(false)
        configuration.setAllowsExpensiveNetworkAccess(false)
        configuration.setAllowsConstrainedNetworkAccess(false)
        configuration.setWaitsForConnectivity(true)
        configuration.setShouldSetCookies(false)
        configuration.setCachePolicy(HTTPCachePolicy.returnCacheDataElseLoad.rawValue)
        configuration.setMaximumConnectionsPerHost(2)
        configuration.setAdditionalHeader("X-A", value: "1")
        configuration.setAdditionalHeader("x-a", value: "2")
        configuration.setAdditionalHeader("X-B", value: "3")
        configuration.setAdditionalHeader("X-B", value: nil)

        let settings = configuration.urlSessionConfiguration
        #expect(configuration.timeoutForRequest() == 5)
        #expect(configuration.timeoutForResource() == 50)
        #expect(!settings.allowsCellularAccess)
        #expect(!settings.allowsExpensiveNetworkAccess)
        #expect(!settings.allowsConstrainedNetworkAccess)
        #expect(settings.waitsForConnectivity)
        #expect(!settings.httpShouldSetCookies)
        #expect(settings.requestCachePolicy == .returnCacheDataElseLoad)
        #expect(settings.httpMaximumConnectionsPerHost == 2)
        #expect(settings.httpAdditionalHeaders?.count == 1)
        #expect(settings.httpAdditionalHeaders?["x-a"] as? String == "2")
    }

    @Test @MainActor func sessionCopiesItsConfiguration() {
        let configuration = DarwinHTTPSessionConfiguration.makeEphemeral()
        configuration.setTimeoutForRequest(7)
        let session = DarwinHTTPSession.make(configuration)
        configuration.setTimeoutForRequest(9)
        #expect(session.configuration().timeoutForRequest() == 7)
        session.invalidateAndCancel()
    }

    @Test func credential() {
        let credential = DarwinHTTPCredential.make(user: "u", password: "p", persistence: HTTPCredentialPersistence.forSession.rawValue)
        #expect(credential.user() == "u")
        #expect(credential.persistence() == HTTPCredentialPersistence.forSession.rawValue)
        #expect(credential.credential.password == "p")
        #expect(credential.credential.persistence == .forSession)
        #expect(DarwinHTTPCredential.make(user: "u", password: "p", persistence: 99).persistence() == 0)
    }

    @Test func url() throws {
        let url = try #require(DarwinURL.parse("HTTPS://me@example.com:8443/a/b%20c?x=1&y=a+b&x=%C3%A9#top"))
        #expect(url.scheme() == "https")
        #expect(url.user() == "me")
        #expect(url.host() == "example.com")
        #expect(url.port() == 8443)
        #expect(url.path() == "/a/b%20c")
        #expect(url.query() == "x=1&y=a+b&x=%C3%A9")
        #expect(url.fragment() == "top")
        #expect(url.queryValues("x") == ["1", "é"])
        #expect(url.queryValues("y") == ["a b"])
        #expect(url.queryValues("z").isEmpty)

        #expect(DarwinURL.parse("relative/path") == nil)
        #expect(DarwinURL.parse("https://example.com")?.path() == "/")
        #expect(DarwinURL.parse("https://example.com")?.port() == -1)

        let base = try #require(DarwinURL.parse("https://example.com/a/b/c"))
        #expect(base.resolve("../d?q")?.absoluteString() == "https://example.com/a/d?q")
        #expect(base.resolve("//other.org/x")?.absoluteString() == "https://other.org/x")
        #expect(DarwinURL.encodeQueryValue("a b&c=d/é") == "a%20b%26c%3Dd%2F%C3%A9")
    }
}

/// `DarwinNetworking` as a `HostModule`.
@Suite struct DarwinNetworkingModuleTests {

    static let names = [
        "org.pureswift.network.HTTPSession",
        "org.pureswift.network.HTTPSessionConfiguration",
        "org.pureswift.network.HTTPRequest",
        "org.pureswift.network.HTTPResponse",
        "org.pureswift.network.HTTPTask",
        "org.pureswift.network.HTTPTaskDelegate",
        "org.pureswift.network.HTTPCredential",
        "org.pureswift.network.URL",
    ]

    @Test func listsEveryContract() {
        #expect(Set(DarwinNetworking.contracts.map(\.name)) == Set(Self.names))
        #expect(DarwinNetworking.contracts.count == Self.names.count)
        #expect(DarwinNetworking.contracts.first { $0.name == "org.pureswift.network.HTTPTaskDelegate" }?.kind == .callback)
        #expect(DarwinNetworking.isUsed(by: ["org.pureswift.network.HTTPSession"]))
        #expect(DarwinNetworking.permissionProviders().isEmpty)
    }

    @Test func registersImplementationsAndTheCallback() {
        let registrar = RecordingRegistrar()
        DarwinNetworking.register(in: registrar)
        #expect(Set(registrar.registered.map(\.name)) == Set(Self.names))
        #expect(registrar.registered.count == Self.names.count)
        for (name, implemented) in registrar.registered {
            #expect(implemented == (name != "org.pureswift.network.HTTPTaskDelegate"), "\(name)")
        }
    }
}
