import DarwinHost
import DynamicWebKit
import Foundation
import Testing
@testable import DarwinWebKit

/// Records a page's delegate calls.
final class RecordingWebDelegate: WebContentDelegate {

    var events: [String] = []

    /// Answers `shouldNavigate`.
    var allows: (String) -> Bool = { _ in true }

    func shouldNavigate(_ content: any WebContent, url: String, kind: Int32, isMainFrame: Bool) -> Bool {
        events.append("ask \(url) kind \(kind)\(isMainFrame ? "" : " subframe")")
        return allows(url)
    }

    func didChangeURL(_ content: any WebContent, url: String?) {
        events.append("url \(url ?? "nil")")
    }

    func didChangeTitle(_ content: any WebContent, title: String) {
        events.append("title \(title)")
    }

    func didChangeLoading(_ content: any WebContent, isLoading: Bool, progress: Double) {
        events.append(isLoading ? "loading" : "loaded \(progress)")
    }

    func didChangeHistory(_ content: any WebContent, canGoBack: Bool, canGoForward: Bool) {
        events.append("history \(canGoBack) \(canGoForward)")
    }

    func didFinishNavigation(_ content: any WebContent) {
        events.append("finish")
    }

    func didFailNavigation(_ content: any WebContent, error: Int32, message: String) {
        events.append("fail \(error)")
    }

    func didEvaluateJavaScript(_ content: any WebContent, request: Int32, result: String?, error: String?) {
        events.append("script \(request) \(result ?? "nil") \(error ?? "nil")")
    }

    /// Answers each message that waits for a reply, by its number.
    var onMessage: ((_ content: any WebContent, _ name: String, _ body: String?, _ reply: Int32) -> Void)?

    /// Answers each request in the app's schemes.
    var onTask: ((_ content: any WebContent, _ task: Int32, _ url: String, _ method: String, _ headers: [String], _ body: [UInt8]?) -> Void)?

    func didReceiveMessage(_ content: any WebContent, name: String, body: String?, reply: Int32) {
        events.append("message \(name) \(body ?? "undefined")\(reply == 0 ? "" : " reply")")
        onMessage?(content, name, body, reply)
    }

    func startURLSchemeTask(_ content: any WebContent, task: Int32, url: String, method: String, headers: [String], body: [UInt8]?) {
        events.append("task \(task) \(method) \(url)")
        onTask?(content, task, url, method, headers, body)
    }

    func stopURLSchemeTask(_ content: any WebContent, task: Int32) {
        events.append("stop task \(task)")
    }

    /// Waits up to ten seconds for an event that starts with `prefix`.
    @MainActor
    func wait(for prefix: String, after count: Int = 0) async throws {
        for _ in 0..<1000 {
            if events.dropFirst(count).contains(where: { $0.hasPrefix(prefix) }) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("no '\(prefix)' in \(events)")
    }
}

/// A real `WKWebView` (`Contracts/WebKit.md`): the delegate's order, scripts,
/// navigations, and the rules without the `network` capability. Nothing
/// here reaches the network.
@MainActor
@Suite("Web content", .serialized)
struct WebContentTests {

    init() {
        DarwinPermissions.declared = []
    }

    static let html = """
        <title>Hello</title>
        <a id="here" href="#two">Two</a>
        <a id="away" href="https://example.com/">Away</a>
        """

    func loaded() async throws -> (DarwinWebContent, RecordingWebDelegate) {
        let delegate = RecordingWebDelegate()
        let page = DarwinWebContent.make(delegate)
        page.loadHTML(Self.html, baseURL: nil)
        try await delegate.wait(for: "finish")
        return (page, delegate)
    }

    @Test func identifiersFindLivePages() throws {
        let delegate = RecordingWebDelegate()
        var first: DarwinWebContent? = DarwinWebContent.make(delegate)
        let second = DarwinWebContent.make(delegate)
        let id = try #require(first).identifier()
        #expect(id > 0 && id != second.identifier())
        #expect(DarwinWebContent.page(id) === first)
        first = nil
        #expect(DarwinWebContent.page(id) == nil)
        #expect(delegate.events.isEmpty, "a new page has nothing to report")
    }

    @Test func loadingHTMLReportsInOrder() async throws {
        let (page, delegate) = try await loaded()
        // The title may come after `finish`: WebKit sets it a little later.
        try await delegate.wait(for: "title Hello")
        let events = delegate.events.filter { !$0.hasPrefix("title") }
        #expect(events.first == "loading", "\(events)")
        #expect(events.contains("url about:blank"))
        #expect(events.suffix(2) == ["loaded 1.0", "finish"], "\(events)")
        #expect(events.filter { $0 == "finish" }.count == 1)
        #expect(!events.contains { $0.hasPrefix("ask") }, "the guest's own load isn't asked about")
        _ = page
    }

    @Test func scriptsAnswerInJSON() async throws {
        let (page, delegate) = try await loaded()
        let start = delegate.events.count
        page.evaluateJavaScript("1 + 1", request: 1)
        page.evaluateJavaScript("document.title", request: 2)
        page.evaluateJavaScript("({b: [1, 'a', null], a: true})", request: 3)
        page.evaluateJavaScript("undefined", request: 4)
        page.evaluateJavaScript("throw new Error('nope')", request: 5)
        try await delegate.wait(for: "script 5", after: start)
        let scripts = delegate.events.dropFirst(start).filter { $0.hasPrefix("script") }
        #expect(scripts.prefix(4) == [
            "script 1 2 nil",
            "script 2 \"Hello\" nil",
            "script 3 {\"a\":true,\"b\":[1,\"a\",null]} nil",
            "script 4 nil nil",
        ])
        #expect(scripts.last?.hasPrefix("script 5 nil ") == true)
        #expect(scripts.last?.contains("nope") == true, "\(scripts)")
    }

    @Test func thePageAsksBeforeNavigating() async throws {
        let (page, delegate) = try await loaded()
        delegate.allows = { _ in false }
        var start = delegate.events.count
        page.evaluateJavaScript("document.getElementById('here').click()", request: 1)
        try await delegate.wait(for: "script 1", after: start)
        #expect(delegate.events.dropFirst(start).contains { $0.hasPrefix("ask about:blank#two kind ") })
        #expect(!delegate.events.dropFirst(start).contains("url about:blank#two"), "refused")

        delegate.allows = { _ in true }
        start = delegate.events.count
        page.evaluateJavaScript("document.getElementById('here').click()", request: 2)
        try await delegate.wait(for: "url about:blank#two", after: start)
    }

    @Test func remoteLoadsNeedTheNetworkCapability() async throws {
        let (page, delegate) = try await loaded()
        var start = delegate.events.count
        page.load("https://example.com/")
        #expect(Array(delegate.events.dropFirst(start)) == ["fail 7"], "not started")

        // A link to the network from the page: refused without asking.
        start = delegate.events.count
        page.evaluateJavaScript("document.getElementById('away').click()", request: 1)
        try await delegate.wait(for: "fail 7", after: start)
        #expect(!delegate.events.dropFirst(start).contains { $0.hasPrefix("ask") })
    }

    @Test func badURLs() {
        let delegate = RecordingWebDelegate()
        let page = DarwinWebContent.make(delegate)
        page.load("not a url")
        page.load("file:///etc/hosts")
        page.loadResource("../secret")
        #expect(delegate.events == ["fail 5", "fail 5", "fail 5"])
    }

    @Test func resourcesLoadFromTheBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("help"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<title>Help</title>".utf8).write(to: root.appendingPathComponent("help/index.html"))
        let resources = DarwinWebContent.resources
        DarwinWebContent.resources = { root }
        defer { DarwinWebContent.resources = resources }

        let delegate = RecordingWebDelegate()
        let page = DarwinWebContent.make(delegate)
        page.loadResource("help/index.html")
        try await delegate.wait(for: "title Help")
        #expect(delegate.events.contains { $0.hasPrefix("url file://") && $0.hasSuffix("help/index.html") })
        page.loadResource("help/missing.html")
        #expect(delegate.events.last == "fail 5")
    }
}

// MARK: - Scripts and schemes

extension WebContentTests {

    @Test func saysWhatItDoes() {
        #expect(WebFeatures(rawValue: DarwinWebContent.features()) == [.userScripts, .scriptMessages, .messageReplies, .urlSchemes])
    }

    @Test func runsUserScriptsAndPassesOnMessages() async throws {
        let delegate = RecordingWebDelegate()
        delegate.onMessage = { content, name, body, reply in
            guard reply != 0 else { return }
            if body == "0" {
                content.replyToMessage(reply, result: nil, error: "no zeros")
            } else {
                content.replyToMessage(reply, result: #"{"echo":\#(body ?? "null")}"#, error: nil)
            }
        }
        let page = DarwinWebContent.make(delegate, dataStore: 0, options: 0, schemes: [])
        page.addUserScript("window.webkit.messageHandlers.note.postMessage({ early: true })", atDocumentStart: true, mainFrameOnly: true)
        page.addMessageHandler("note", replies: false)
        page.addMessageHandler("ask", replies: true)
        page.addMessageHandler("ask", replies: false)
        page.loadHTML("""
            <script>
            const ask = (n) => window.webkit.messageHandlers.ask.postMessage(n)
                .then(v => JSON.stringify(v), e => 'rejected ' + e.message);
            Promise.all([ask(5), ask(0)]).then(r => { document.title = r.join(' | '); });
            </script>
            """, baseURL: nil)
        try await delegate.wait(for: #"title {"echo":5} | rejected no zeros"#)
        #expect(delegate.events.contains(#"message note {"early":true}"#), "the user script ran before the page's own")
        #expect(delegate.events.contains("message ask 5 reply"))
        // Answering again, or a number never given, does nothing.
        page.replyToMessage(1, result: "1", error: nil)
        page.replyToMessage(99, result: "1", error: nil)

        page.removeMessageHandler("ask")
        page.removeAllUserScripts()
        delegate.events.removeAll()
        page.loadHTML("<script>document.title = String(window.webkit.messageHandlers.ask === undefined)</script>", baseURL: nil)
        try await delegate.wait(for: "title true")
        #expect(!delegate.events.contains { $0.hasPrefix("message") }, "no user script, no handler")
    }

    @Test func repliesThatArentJSONOrUndefined() async throws {
        let delegate = RecordingWebDelegate()
        var answers = ["{ not json", nil]
        delegate.onMessage = { content, _, _, reply in
            content.replyToMessage(reply, result: answers.removeFirst(), error: nil)
        }
        let page = DarwinWebContent.make(delegate, dataStore: 0, options: 0, schemes: [])
        page.addMessageHandler("ask", replies: true)
        page.loadHTML("""
            <script>
            const ask = () => window.webkit.messageHandlers.ask.postMessage(1)
                .then(v => v === undefined ? 'undefined' : JSON.stringify(v), e => 'rejected ' + e.message);
            ask().then(a => ask().then(b => { document.title = a + ' | ' + b; }));
            </script>
            """, baseURL: nil)
        // Nil resolves the promise to `undefined`, as the contract says.
        try await delegate.wait(for: "title rejected the reply isn't JSON | undefined")
    }

    @Test func servesAPageFromAnAppScheme() async throws {
        let delegate = RecordingWebDelegate()
        delegate.onTask = { content, task, url, method, headers, body in
            switch url {
            case "test-darwin-app:/index.html":
                content.finishURLSchemeTask(task, status: 200, contentType: "text/html", headers: [],
                                            body: Array("<title>App</title><script>fetch('test-darwin-app:/data', { method: 'POST', body: 'hi' }).then(r => r.text().then(t => { document.title = r.status + ' ' + r.headers.get('x-answer') + ' ' + t; }))</script>".utf8))
            case "test-darwin-app:/data":
                #expect(method == "POST")
                #expect(body == Array("hi".utf8))
                content.finishURLSchemeTask(task, status: 201, contentType: "text/plain",
                                            headers: ["X-Answer", "yes", "Access-Control-Allow-Origin", "*", "Access-Control-Expose-Headers", "X-Answer"],
                                            body: Array("stored".utf8))
            default:
                content.failURLSchemeTask(task, error: WebError.Code.notPermitted.rawValue, message: "not for you")
            }
        }
        let page = DarwinWebContent.make(delegate, dataStore: 0, options: 0, schemes: ["Test-Darwin-App", "https"])
        page.load("test-darwin-app:/index.html")
        try await delegate.wait(for: "title 201 yes stored")
        #expect(delegate.events.contains("url test-darwin-app:/index.html"))
        #expect(delegate.events.contains("task 1 GET test-darwin-app:/index.html"))
        #expect(delegate.events.contains("task 2 POST test-darwin-app:/data"))

        let start = delegate.events.count
        page.load("test-darwin-app:/forbidden")
        try await delegate.wait(for: "fail", after: start)
        #expect(delegate.events.dropFirst(start).contains("fail \(WebError.Code.notPermitted.rawValue)"), "\(delegate.events)")
        // A task answered already, or never asked, is let be.
        page.finishURLSchemeTask(1, status: 200, contentType: nil, headers: [], body: [])
        page.failURLSchemeTask(99, error: 0, message: "")
    }
}
