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
