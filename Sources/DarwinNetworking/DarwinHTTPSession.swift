import DarwinHost
import DynamicNetworking
import Foundation

/// `HTTPSession` over one `URLSession`.
///
/// The URLSession's delegate is a `SessionDelegate`, which routes each
/// task's callbacks to its `DarwinHTTPTask` and from there to the guest's
/// delegate. Callbacks arrive on the main `OperationQueue`, the only thread
/// the guest is entered from.
///
/// A URLSession keeps its delegate until it's invalidated, so the session
/// is invalidated when the contract session ends: by
/// `finishTasksAndInvalidate()`, `invalidateAndCancel()`, or, if the guest
/// calls neither, when it releases the session (running tasks still finish).
public final class DarwinHTTPSession: HTTPSession {

    let urlSession: URLSession

    /// The settings tasks are made with, read once.
    private let settings: URLSessionConfiguration

    /// The process-wide session, which ignores invalidation as
    /// `URLSession.shared` does.
    private let isShared: Bool

    private(set) var isInvalidated = false

    /// Identifiers for tasks that never reach URLSession, which numbers its
    /// own from 0 up.
    private var nextFailedIdentifier: Int64 = -1

    init(configuration: URLSessionConfiguration, isShared: Bool = false) {
        self.urlSession = URLSession(configuration: configuration, delegate: SessionDelegate(), delegateQueue: .main)
        self.settings = urlSession.configuration
        self.isShared = isShared
    }

    deinit {
        if !isInvalidated {
            urlSession.finishTasksAndInvalidate()
        }
    }

    nonisolated(unsafe) private static var sharedSession: DarwinHTTPSession?

    public static func shared() -> DarwinHTTPSession {
        if let sharedSession {
            return sharedSession
        }
        let session = DarwinHTTPSession(configuration: .default, isShared: true)
        sharedSession = session
        return session
    }

    public static func make(_ configuration: any HTTPSessionConfiguration) -> DarwinHTTPSession {
        DarwinHTTPSession(configuration: DarwinHTTPSessionConfiguration.urlSessionConfiguration(for: configuration))
    }

    public func configuration() -> any HTTPSessionConfiguration {
        DarwinHTTPSessionConfiguration(urlSession.configuration)
    }

    public func dataTask(_ request: any HTTPRequest, delegate: any HTTPTaskDelegate) -> any HTTPTask {
        makeTask(request, delegate: delegate) { urlSession.dataTask(with: $0) }
    }

    public func uploadTask(_ request: any HTTPRequest, body: [UInt8], delegate: any HTTPTaskDelegate) -> any HTTPTask {
        makeTask(request, delegate: delegate) { urlSession.uploadTask(with: $0, from: Data(body)) }
    }

    public func finishTasksAndInvalidate() {
        guard invalidate() else { return }
        urlSession.finishTasksAndInvalidate()
    }

    public func invalidateAndCancel() {
        guard invalidate() else { return }
        urlSession.invalidateAndCancel()
    }

    public func removeAllCookies() {
        settings.httpCookieStorage?.removeCookies(since: .distantPast)
    }

    public func removeAllCachedResponses() {
        settings.urlCache?.removeAllCachedResponses()
    }

    // MARK: Tasks

    private func makeTask(
        _ request: any HTTPRequest,
        delegate: any HTTPTaskDelegate,
        _ make: (URLRequest) -> URLSessionTask
    ) -> DarwinHTTPTask {
        // URLSession raises an exception for a task made after invalidation.
        guard !isInvalidated, let owner = urlSession.delegate as? SessionDelegate else {
            return failedTask(.sessionInvalidated, request: request, delegate: delegate)
        }
        guard let urlRequest = DarwinHTTPRequest.urlRequest(for: request, in: settings) else {
            return failedTask(.invalidURL, request: request, delegate: delegate)
        }
        return DarwinHTTPTask(task: make(urlRequest), owner: owner, delegate: delegate)
    }

    private func failedTask(_ failure: NetworkError, request: any HTTPRequest, delegate: any HTTPTaskDelegate) -> DarwinHTTPTask {
        let identifier = nextFailedIdentifier
        nextFailedIdentifier -= 1
        return DarwinHTTPTask(failing: failure, request: request, identifier: identifier, delegate: delegate)
    }

    /// Marks the session invalidated. False for the shared session, or one
    /// already invalidated.
    private func invalidate() -> Bool {
        if isShared {
            AppHost.logger.notice("The shared HTTPSession can't be invalidated; ignoring")
            return false
        }
        guard !isInvalidated else { return false }
        isInvalidated = true
        return true
    }
}

/// The URLSession delegate behind one `DarwinHTTPSession`: forwards each
/// task's events to its `DarwinHTTPTask`'s guest delegate, on the main
/// thread, and answers URLSession's questions with the guest's replies.
///
/// It keeps every task that has been resumed or cancelled until the task
/// completes. URLSession keeps it until the session is invalidated.
final class SessionDelegate: NSObject, URLSessionDataDelegate {

    /// Running tasks by `taskIdentifier`.
    private var tasks: [Int: DarwinHTTPTask] = [:]

    func track(_ task: DarwinHTTPTask) {
        guard let urlTask = task.task else { return }
        tasks[urlTask.taskIdentifier] = task
    }

    /// The task and its guest delegate, if it hasn't completed yet.
    private func route(_ task: URLSessionTask) -> (DarwinHTTPTask, any HTTPTaskDelegate)? {
        guard let owner = tasks[task.taskIdentifier], let delegate = owner.delegate else {
            return nil
        }
        return (owner, delegate)
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let (owner, delegate) = route(task) else {
            completionHandler(request)
            return
        }
        let newRequest = DarwinHTTPRequest(request)
        let follow = autoreleasepool {
            delegate.willPerformRedirect(owner, response: owner.wrap(response), newRequest: newRequest)
        }
        // The guest may have changed the new request, such as its headers.
        completionHandler(follow ? newRequest.request : nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        // Server trust and client certificates stay with the host.
        guard let method = HTTPAuthenticationMethod(space), let (owner, delegate) = route(task) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let answer = autoreleasepool {
            delegate.didReceiveChallenge(
                owner,
                method: method.rawValue,
                host: space.host,
                realm: space.realm,
                previousFailureCount: Int32(clamping: challenge.previousFailureCount)
            )
        }
        guard let answer else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let credential = DarwinNetworking.host(answer, as: DarwinHTTPCredential.self) else {
            // Its password can't be read: the contract makes it write-only.
            AppHost.logger.error("HTTPTaskDelegate.didReceiveChallenge returned a credential this host didn't make; using the default handling")
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, credential.credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let (owner, delegate) = route(task) else { return }
        autoreleasepool {
            delegate.didSendBodyData(
                owner,
                bytesSent: bytesSent,
                totalBytesSent: totalBytesSent,
                totalBytesExpectedToSend: totalBytesExpectedToSend
            )
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let (owner, delegate) = route(task) else { return }
        autoreleasepool {
            delegate.taskIsWaitingForConnectivity(owner)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let owner = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        guard let error else {
            owner.complete(error: 0, message: nil)
            return
        }
        let code = NetworkError(urlSessionError: error)
        NetworkError.report(error, code: code, url: task.originalRequest?.url)
        owner.complete(error: code.rawValue, message: error.localizedDescription)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let (owner, delegate) = route(dataTask) else {
            completionHandler(.allow)
            return
        }
        let allow = autoreleasepool {
            delegate.didReceiveResponse(owner, response: owner.wrap(response))
        }
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let (owner, delegate) = route(dataTask) else { return }
        autoreleasepool {
            delegate.didReceiveData(owner, data: [UInt8](data))
        }
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        // Every task has completed by now; complete any left so no guest
        // delegate waits forever.
        let left = tasks
        tasks = [:]
        for task in left.values {
            task.complete(error: NetworkError.sessionInvalidated.rawValue, message: "The session was invalidated")
        }
        if let error {
            AppHost.logger.error("HTTPSession invalidated with an error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension HTTPAuthenticationMethod {

    /// The method the guest is asked about, or nil for challenges the host
    /// answers itself (server trust, client certificates).
    init?(_ space: URLProtectionSpace) {
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodClientCertificate:
            return nil
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodDefault:
            self = space.isProxy() ? .proxyBasic : .basic
        case NSURLAuthenticationMethodHTTPDigest:
            self = .digest
        default:
            // NTLM, Negotiate, HTML forms.
            self = .other
        }
    }
}
