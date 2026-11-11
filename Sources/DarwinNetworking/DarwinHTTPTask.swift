import DynamicNetworking
import Foundation

/// `HTTPTask` over a `URLSessionTask`, or a task that fails as soon as it's
/// resumed because it couldn't be made (an invalid URL, an invalidated
/// session).
///
/// The task keeps its guest delegate until it completes. Once resumed or
/// cancelled, its session's `SessionDelegate` keeps the task until then too,
/// so the guest may drop it. A task the guest drops without resuming is
/// cancelled.
public final class DarwinHTTPTask: HTTPTask {

    /// Nil for a task that never reached URLSession.
    let task: URLSessionTask?

    /// Routes URLSession's callbacks for `task` back here.
    private weak var owner: SessionDelegate?

    /// Why a task without `task` fails.
    private let failure: NetworkError

    /// The request a task without `task` was made with.
    private let request: (any HTTPRequest)?

    private let identifierValue: Int64

    /// Until `didComplete`.
    private(set) var delegate: (any HTTPTaskDelegate)?

    /// The state of a task without `task`.
    private var ownState = HTTPTaskState.suspended

    private var ownPriority = URLSessionTask.defaultPriority

    /// One wrapper per `URLResponse`, so the guest sees one object for it.
    private var wrappedResponse: DarwinHTTPResponse?

    init(task: URLSessionTask, owner: SessionDelegate, delegate: any HTTPTaskDelegate) {
        self.task = task
        self.owner = owner
        self.failure = .unknown
        self.request = nil
        self.identifierValue = Int64(task.taskIdentifier)
        self.delegate = delegate
    }

    /// A task that completes with `failure` when it's resumed.
    init(failing failure: NetworkError, request: any HTTPRequest, identifier: Int64, delegate: any HTTPTaskDelegate) {
        self.task = nil
        self.failure = failure
        self.request = request
        self.identifierValue = identifier
        self.delegate = delegate
    }

    deinit {
        if let task, task.state == .suspended {
            task.cancel()
        }
    }

    public func identifier() -> Int64 {
        identifierValue
    }

    public func resume() {
        guard let task else {
            guard ownState == .suspended else { return }
            ownState = .running
            DispatchQueue.main.async { [self] in
                complete(error: failure.rawValue, message: "The task couldn't start: \(failure)")
            }
            return
        }
        owner?.track(self)
        task.resume()
    }

    public func cancel() {
        guard let task else {
            guard ownState == .suspended || ownState == .running else { return }
            ownState = .canceling
            DispatchQueue.main.async { [self] in
                complete(error: NetworkError.cancelled.rawValue, message: "cancelled")
            }
            return
        }
        guard task.state == .suspended || task.state == .running else { return }
        owner?.track(self)
        task.cancel()
    }

    public func state() -> Int32 {
        guard let task else {
            return ownState.rawValue
        }
        // `URLSessionTask.State` has the contract's raw values.
        return Int32(task.state.rawValue)
    }

    public func originalRequest() -> any HTTPRequest {
        if let original = task?.originalRequest {
            return DarwinHTTPRequest(original)
        }
        return request!
    }

    public func currentRequest() -> (any HTTPRequest)? {
        guard let task else {
            return request
        }
        return task.currentRequest.map(DarwinHTTPRequest.init)
    }

    public func response() -> (any HTTPResponse)? {
        task?.response.map(wrap)
    }

    public func countOfBytesSent() -> Int64 {
        task?.countOfBytesSent ?? 0
    }

    public func countOfBytesReceived() -> Int64 {
        task?.countOfBytesReceived ?? 0
    }

    public func countOfBytesExpectedToSend() -> Int64 {
        task?.countOfBytesExpectedToSend ?? NSURLSessionTransferSizeUnknown
    }

    public func countOfBytesExpectedToReceive() -> Int64 {
        task?.countOfBytesExpectedToReceive ?? NSURLSessionTransferSizeUnknown
    }

    public func setPriority(_ priority: Float) {
        let priority = min(max(priority, 0), 1)
        if let task {
            task.priority = priority
        } else {
            ownPriority = priority
        }
    }

    public func priority() -> Float {
        task?.priority ?? ownPriority
    }

    // MARK: Delivery

    /// The guest's object for `response`.
    func wrap(_ response: URLResponse) -> DarwinHTTPResponse {
        if let wrapped = wrappedResponse, wrapped.response === response {
            return wrapped
        }
        let wrapped = DarwinHTTPResponse(response)
        wrappedResponse = wrapped
        return wrapped
    }

    /// Tells the delegate the task is done and lets it go. Later calls do
    /// nothing.
    func complete(error: Int32, message: String?) {
        guard let delegate else { return }
        self.delegate = nil
        if task == nil {
            ownState = .completed
        }
        autoreleasepool {
            delegate.didComplete(self, error: error, message: message)
        }
    }
}
