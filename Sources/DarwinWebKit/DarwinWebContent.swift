import DarwinHost
import DynamicRuntime
import DynamicWebKit
import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The `WebContent` contract over `WKWebView` (`HostRuntime.md` §5.2,
/// AppRuntime's `Contracts/WebKit.md`).
///
/// The web view is made in `make` and loads whether it's on screen or not;
/// `WebContentView` puts it where a `WebView` node names the page. The
/// delegate hears every change in the order the contract gives:
///
/// - a load: `didChangeLoading(true, …)` as it goes, then on success
///   `didChangeLoading(false, 1)` and `didFinishNavigation`, or on failure
///   `didFailNavigation` and `didChangeLoading(false, 1)`;
/// - `didChangeURL`, `didChangeTitle` and `didChangeHistory` from key-value
///   observing, when they change.
///
/// `shouldNavigate` is asked from `decidePolicyFor`, except for the
/// navigation the guest itself just started. Without the `network`
/// capability, remote loads fail with `notPermitted` and a content rule
/// list blocks remote subresources.
///
/// It runs the app's user scripts (`WKUserScript`), passes on its script
/// messages (`WKScriptMessageHandler`, and `WKScriptMessageHandlerWithReply`
/// for replies) and its URL schemes' requests (`WKURLSchemeHandler`, set on
/// the configuration the web view is made with). Every call is on the main
/// thread.
public final class DarwinWebContent: NSObject, WebContent {

    let delegate: any WebContentDelegate

    let id: Int32

    let webView: WKWebView

    /// The URL of the navigation the guest started last, which isn't asked
    /// about.
    private var ownNavigation: URL?

    /// Whether the guest heard that the page is loading, and how far.
    private(set) var reportedLoading = false

    private var reportedProgress: Double = 0

    private var reportedURL: String?

    private var reportedTitle = ""

    private var reportedHistory = (back: false, forward: false)

    private var observations: [NSKeyValueObservation] = []

    /// Whether the page may load: without `network`, not before the rule
    /// list that blocks remote subresources is in place.
    private var isReady = false

    private var pending: [() -> Void] = []

    // MARK: Scripts and schemes

    /// Whether each handler replies, by name: WebKit takes a name once.
    private var messageHandlers: [String: Bool] = [:]

    /// The user content controller holds its handlers; this doesn't hold
    /// the page.
    private lazy var messages = MessageRelay(page: self)

    /// Replies the page awaits, by the number the guest has for each.
    private var replies: [Int32: (Any?, String?) -> Void] = [:]

    private var nextReply: Int32 = 1

    /// Requests in the app's schemes not yet answered or stopped, likewise.
    private var tasks: [Int32: any WKURLSchemeTask] = [:]

    private var taskNumbers: [ObjectIdentifier: Int32] = [:]

    private var nextTask: Int32 = 1

    init(delegate: any WebContentDelegate, id: Int32, schemes: [String] = []) {
        self.delegate = delegate
        self.id = id
        let configuration = WKWebViewConfiguration()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        // WebKit takes a scheme's handler only before the view is made.
        let schemeRelay = SchemeRelay()
        for scheme in Set(schemes.map { $0.lowercased() }).sorted() {
            guard !WKWebView.handlesURLScheme(scheme) else {
                AppHost.logger.warning("web: \(scheme, privacy: .public) can't be an app's scheme")
                continue
            }
            configuration.setURLSchemeHandler(schemeRelay, forURLScheme: scheme)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        schemeRelay.page = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
        if Self.allowsNetwork {
            isReady = true
        } else {
            NetworkBlocker.whenReady { [weak self] rules in
                guard let self else { return }
                if let rules {
                    self.webView.configuration.userContentController.add(rules)
                }
                self.isReady = true
                let pending = self.pending
                self.pending = []
                pending.forEach { $0() }
            }
        }
    }

    deinit {
        for reply in replies.values {
            reply(nil, "the page went away")
        }
        for task in tasks.values {
            task.didFailWithError(Self.error(.cancelled, "the page went away"))
        }
        observations.forEach { $0.invalidate() }
        let webView = self.webView
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        Self.live[id] = nil
    }

    // MARK: Pages

    private final class Weak {
        weak var content: DarwinWebContent?
        init(_ content: DarwinWebContent) {
            self.content = content
        }
    }

    private static var live: [Int32: Weak] = [:]

    private static var nextID: Int32 = 0

    /// The live page with this identifier: what a `WebView` node shows.
    static func page(_ identifier: Int32) -> DarwinWebContent? {
        live[identifier]?.content
    }

    /// Whether the app declares `network`, which remote content needs.
    static var allowsNetwork: Bool {
        DarwinPermissions.declared.contains(.network)
    }

    /// Where `loadResource` finds files: the app's resources.
    nonisolated(unsafe) static var resources: () -> URL? = { DarwinBundle.bundle.resourceURL }

    // MARK: WebContent

    public static func make(_ delegate: any WebContentDelegate) -> DarwinWebContent {
        make(delegate, dataStore: 0, options: 0, schemes: [])
    }

    /// The default store and no options, as `features()` offers no others,
    /// answering `schemes`. A scheme WebKit loads itself is left to it.
    public static func make(_ delegate: any WebContentDelegate, dataStore: Int32, options: Int32, schemes: [String]) -> DarwinWebContent {
        nextID &+= 1
        if nextID <= 0 {
            nextID = 1
        }
        let content = DarwinWebContent(delegate: delegate, id: nextID, schemes: schemes)
        live[content.id] = Weak(content)
        return content
    }

    /// What this host does beyond loading a page: what an app talks to its
    /// pages with. None of a browser's or a mail reader's features yet.
    public static func features() -> Int32 {
        WebFeatures([.userScripts, .scriptMessages, .messageReplies, .urlSchemes]).rawValue
    }

    public func identifier() -> Int32 {
        id
    }

    public func load(_ text: String) {
        guard let url = WebConversions.loadableURL(text) else {
            delegate.didFailNavigation(self, error: WebError.Code.badURL.rawValue, message: "Not a URL that can be loaded: \(text)")
            return
        }
        guard Self.allowsNetwork || !WebConversions.isRemote(url) else {
            delegate.didFailNavigation(self, error: WebError.Code.notPermitted.rawValue, message: Self.notPermitted(url))
            return
        }
        perform {
            self.ownNavigation = url
            self.webView.load(URLRequest(url: url))
        }
    }

    public func loadHTML(_ html: String, baseURL: String?) {
        let base = baseURL.flatMap(URL.init(string:))
        perform {
            self.ownNavigation = base ?? URL(string: "about:blank")
            self.webView.loadHTMLString(html, baseURL: base)
        }
    }

    public func loadResource(_ path: String) {
        guard let resources = Self.resources(), let url = WebConversions.resource(path, in: resources) else {
            delegate.didFailNavigation(self, error: WebError.Code.badURL.rawValue, message: "No resource at \(path)")
            return
        }
        perform {
            self.ownNavigation = url
            self.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    public func reload() {
        perform {
            self.ownNavigation = self.webView.url
            self.webView.reload()
        }
    }

    public func stopLoading() {
        perform {
            self.webView.stopLoading()
        }
    }

    public func goBack() {
        perform {
            guard let item = self.webView.backForwardList.backItem else { return }
            self.ownNavigation = item.url
            self.webView.goBack()
        }
    }

    public func goForward() {
        perform {
            guard let item = self.webView.backForwardList.forwardItem else { return }
            self.ownNavigation = item.url
            self.webView.goForward()
        }
    }

    public func evaluateJavaScript(_ script: String, request: Int32) {
        perform {
            self.evaluate(script, request: request)
        }
    }

    /// The result goes nowhere if the guest released the page meanwhile.
    private func evaluate(_ script: String, request: Int32) {
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            let outcome = WebConversions.scriptOutcome(value, error)
            self.delegate.didEvaluateJavaScript(self, request: request, result: outcome.result, error: outcome.error)
        }
    }

    // MARK: State

    /// Runs `body` now, or once remote subresources are blocked.
    private func perform(_ body: @escaping () -> Void) {
        if isReady {
            body()
        } else {
            pending.append(body)
        }
    }

    private func observe() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in self?.urlChanged() },
            webView.observe(\.title) { [weak self] _, _ in self?.titleChanged() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.loadingChanged() },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.progressChanged() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.historyChanged() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.historyChanged() },
        ]
    }

    private func urlChanged() {
        let url = webView.url?.absoluteString
        guard url != reportedURL else { return }
        reportedURL = url
        delegate.didChangeURL(self, url: url)
    }

    private func titleChanged() {
        let title = webView.title ?? ""
        guard title != reportedTitle else { return }
        reportedTitle = title
        delegate.didChangeTitle(self, title: title)
    }

    private func historyChanged() {
        let history = (back: webView.canGoBack, forward: webView.canGoForward)
        guard history != reportedHistory else { return }
        reportedHistory = history
        delegate.didChangeHistory(self, canGoBack: history.back, canGoForward: history.forward)
    }

    private func loadingChanged() {
        if webView.isLoading {
            reportLoading(progress: webView.estimatedProgress)
        } else {
            // WebKit clears `isLoading` just before it calls `didFinish` or
            // `didFail`, which report the end in the contract's order. A
            // load that ends without either (stopped, or replaced) ends
            // here.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.webView.isLoading else { return }
                self.reportLoaded()
            }
        }
    }

    private func progressChanged() {
        guard webView.isLoading else { return }
        reportLoading(progress: webView.estimatedProgress)
    }

    private func reportLoading(progress: Double) {
        let progress = min(max(progress, 0), 1)
        guard !reportedLoading || progress != reportedProgress else { return }
        reportedLoading = true
        reportedProgress = progress
        delegate.didChangeLoading(self, isLoading: true, progress: progress)
    }

    private func reportLoaded() {
        guard reportedLoading else { return }
        reportedLoading = false
        reportedProgress = 1
        delegate.didChangeLoading(self, isLoading: false, progress: 1)
    }

    fileprivate func finished() {
        ownNavigation = nil
        urlChanged()
        titleChanged()
        reportLoaded()
        delegate.didFinishNavigation(self)
    }

    fileprivate func failed(_ error: Error) {
        guard let code = WebConversions.failure(error) else {
            return
        }
        delegate.didFailNavigation(self, error: code.rawValue, message: error.localizedDescription)
        reportLoaded()
    }

    static func notPermitted(_ url: URL) -> String {
        "\(url.absoluteString) is remote, and the app doesn't declare the network capability"
    }
}

// MARK: - WKNavigationDelegate

// MARK: - Scripts and schemes

extension DarwinWebContent {

    public func addUserScript(_ source: String, atDocumentStart: Bool, mainFrameOnly: Bool) {
        let script = WKUserScript(source: source, injectionTime: atDocumentStart ? .atDocumentStart : .atDocumentEnd, forMainFrameOnly: mainFrameOnly)
        webView.configuration.userContentController.addUserScript(script)
    }

    public func removeAllUserScripts() {
        webView.configuration.userContentController.removeAllUserScripts()
    }

    public func addMessageHandler(_ name: String, replies: Bool) {
        // A name has one handler: WebKit raises an exception for a second.
        guard messageHandlers[name] == nil else { return }
        messageHandlers[name] = replies
        let controller = webView.configuration.userContentController
        if replies {
            controller.addScriptMessageHandler(messages, contentWorld: .page, name: name)
        } else {
            controller.add(messages, contentWorld: .page, name: name)
        }
    }

    public func removeMessageHandler(_ name: String) {
        guard messageHandlers.removeValue(forKey: name) != nil else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: name, contentWorld: .page)
    }

    public func replyToMessage(_ reply: Int32, result: String?, error: String?) {
        guard let handler = replies.removeValue(forKey: reply) else { return }
        if let error {
            return handler(nil, error)
        }
        guard let result else {
            return handler(nil, nil)
        }
        guard let value = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: .fragmentsAllowed) else {
            return handler(nil, "the reply isn't JSON")
        }
        handler(value, nil)
    }

    public func finishURLSchemeTask(_ task: Int32, status: Int32, contentType: String?, headers: [String], body: [UInt8]) {
        guard let schemeTask = takeTask(task), let url = schemeTask.request.url else { return }
        var fields: [String: String] = [:]
        for index in stride(from: 0, to: headers.count - 1, by: 2) {
            let name = headers[index]
            let value = headers[index + 1]
            fields[name] = fields[name].map { "\($0), \(value)" } ?? value
        }
        if let contentType, !fields.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            fields["Content-Type"] = contentType
        }
        guard let response = HTTPURLResponse(url: url, statusCode: Int(status), httpVersion: "HTTP/1.1", headerFields: fields) else {
            return schemeTask.didFailWithError(Self.error(.unknown, "status \(status) isn't one"))
        }
        schemeTask.didReceive(response)
        schemeTask.didReceive(Data(body))
        schemeTask.didFinish()
    }

    public func failURLSchemeTask(_ task: Int32, error: Int32, message: String) {
        takeTask(task)?.didFailWithError(Self.error(WebError.Code(rawValue: error) ?? .unknown, message))
    }

    /// What a page sees for a failed request, which a failed navigation
    /// reports as its code (`WebConversions.failure`).
    static func error(_ code: WebError.Code, _ message: String) -> NSError {
        NSError(domain: WebConversions.errorDomain, code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: message])
    }

    fileprivate func received(_ message: WKScriptMessage, reply: ((Any?, String?) -> Void)?) {
        var number: Int32 = 0
        if let reply {
            number = nextReply
            nextReply = nextReply == .max ? 1 : nextReply + 1
            replies[number] = reply
        }
        delegate.didReceiveMessage(self, name: message.name, body: WebConversions.json(message.body), reply: number)
    }

    fileprivate func start(_ task: any WKURLSchemeTask) {
        let number = nextTask
        nextTask = nextTask == .max ? 1 : nextTask + 1
        tasks[number] = task
        taskNumbers[ObjectIdentifier(task)] = number
        let request = task.request
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        delegate.startURLSchemeTask(self, task: number, url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "GET",
                                    headers: headers, body: request.httpBody.map { [UInt8]($0) })
    }

    fileprivate func stop(_ task: any WKURLSchemeTask) {
        guard let number = taskNumbers.removeValue(forKey: ObjectIdentifier(task)) else { return }
        tasks[number] = nil
        delegate.stopURLSchemeTask(self, task: number)
    }

    /// A task still wanted, which may be answered once.
    @discardableResult
    private func takeTask(_ number: Int32) -> (any WKURLSchemeTask)? {
        guard let task = tasks.removeValue(forKey: number) else { return nil }
        taskNumbers[ObjectIdentifier(task)] = nil
        return task
    }
}

/// The page's script message handler. WebKit's user content controller
/// holds it; it doesn't hold the page.
private final class MessageRelay: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {

    weak var page: DarwinWebContent?

    init(page: DarwinWebContent) {
        self.page = page
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        page?.received(message, reply: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let page else {
            return replyHandler(nil, "the page went away")
        }
        page.received(message, reply: replyHandler)
    }
}

/// The page's URL scheme handler, which the web view's configuration holds.
private final class SchemeRelay: NSObject, WKURLSchemeHandler {

    weak var page: DarwinWebContent?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let page else {
            return urlSchemeTask.didFailWithError(DarwinWebContent.error(.cancelled, "the page went away"))
        }
        page.start(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        page?.stop(urlSchemeTask)
    }
}

extension DarwinWebContent: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let url = action.request.url
        if isMainFrame, let own = ownNavigation, let url, Self.same(own, url) {
            ownNavigation = nil
            decisionHandler(.allow)
            return
        }
        if let url, WebConversions.isRemote(url), !Self.allowsNetwork {
            decisionHandler(.cancel)
            if isMainFrame {
                delegate.didFailNavigation(self, error: WebError.Code.notPermitted.rawValue, message: Self.notPermitted(url))
            }
            return
        }
        let allowed = delegate.shouldNavigate(
            self, url: url?.absoluteString ?? "",
            kind: WebConversions.kind(action.navigationType).rawValue,
            isMainFrame: isMainFrame
        )
        decisionHandler(allowed ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// The web content process ended: show the page again.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil {
            ownNavigation = webView.url
            webView.reload()
        }
    }

    /// The same page, ignoring a fragment WebKit adds or drops.
    static func same(_ a: URL, _ b: URL) -> Bool {
        if a.absoluteString == b.absoluteString {
            return true
        }
        return a.absoluteString.split(separator: "#", maxSplits: 1).first == b.absoluteString.split(separator: "#", maxSplits: 1).first
    }
}

// MARK: - WKUIDelegate

extension DarwinWebContent: WKUIDelegate {

    /// New windows load in this page; `decidePolicyFor` already asked.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url {
            ownNavigation = url
            webView.load(action.request)
        }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        WebDialogs.alert(message, in: webView) { completionHandler() }
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        WebDialogs.confirm(message, in: webView, completion: completionHandler)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        WebDialogs.prompt(prompt, defaultText: defaultText, in: webView, completion: completionHandler)
    }

    /// Pages get no camera or microphone.
    @available(iOS 15, macOS 12, *)
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

// MARK: - Blocking the network

/// The content rule list that keeps a page off the network when the app
/// doesn't declare `network`: every `http`, `https`, `ws` and `wss` load.
enum NetworkBlocker {

    static let identifier = "org.pureswift.web.no-network"

    static let rules = #"[{"trigger":{"url-filter":"^(https?|wss?)://"},"action":{"type":"block"}}]"#

    private static var compiled: WKContentRuleList?

    private static var waiting: [(WKContentRuleList?) -> Void] = []

    /// Calls `body` with the compiled list, at once when it's ready. If it
    /// can't be compiled, `body` gets `nil`; main-frame loads are still
    /// refused.
    static func whenReady(_ body: @escaping (WKContentRuleList?) -> Void) {
        if let compiled {
            body(compiled)
            return
        }
        waiting.append(body)
        guard waiting.count == 1 else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, error in
            DispatchQueue.main.async {
                if let error {
                    AppHost.logger.error("Remote loads can't be blocked: \(String(describing: error), privacy: .public)")
                }
                compiled = list
                let waiting = self.waiting
                self.waiting = []
                waiting.forEach { $0(list) }
            }
        }
    }
}

// MARK: - Dialogs

/// `alert`, `confirm` and `prompt`, shown over the window the page is in.
/// A page that isn't on screen gets the answer a dismissed dialog gives.
enum WebDialogs {

    #if os(iOS)
    private static func presenter(for view: UIView) -> UIViewController? {
        var controller = view.window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    static func alert(_ message: String, in view: UIView, completion: @escaping () -> Void) {
        guard let presenter = presenter(for: view) else { return completion() }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
        presenter.present(alert, animated: true)
    }

    static func confirm(_ message: String, in view: UIView, completion: @escaping (Bool) -> Void) {
        guard let presenter = presenter(for: view) else { return completion(false) }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
        presenter.present(alert, animated: true)
    }

    static func prompt(_ message: String, defaultText: String?, in view: UIView, completion: @escaping (String?) -> Void) {
        guard let presenter = presenter(for: view) else { return completion(nil) }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text ?? "")
        })
        presenter.present(alert, animated: true)
    }
    #elseif os(macOS)
    private static func run(_ alert: NSAlert, in view: NSView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = view.window else { return completion(.cancel) }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    static func alert(_ message: String, in view: NSView, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        run(alert, in: view) { _ in completion() }
    }

    static func confirm(_ message: String, in view: NSView, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        run(alert, in: view) { completion($0 == .alertFirstButtonReturn) }
    }

    static func prompt(_ message: String, defaultText: String?, in view: NSView, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        run(alert, in: view) { completion($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    #endif
}
