import DynamicWebKit
import Foundation
import Testing
import WebKit
@testable import DarwinWebKit

@Suite("Web conversions")
struct WebConversionTests {

    @Test func remoteURLs() {
        #expect(WebConversions.isRemote(URL(string: "https://example.com")!))
        #expect(WebConversions.isRemote(URL(string: "HTTP://example.com")!))
        #expect(WebConversions.isRemote(URL(string: "wss://example.com/socket")!))
        #expect(!WebConversions.isRemote(URL(string: "about:blank")!))
        #expect(!WebConversions.isRemote(URL(string: "data:text/html,hi")!))
        #expect(!WebConversions.isRemote(URL(fileURLWithPath: "/tmp/a.html")))
    }

    @Test func loadableURLs() {
        #expect(WebConversions.loadableURL("https://swift.org/") != nil)
        #expect(WebConversions.loadableURL("about:blank") != nil)
        #expect(WebConversions.loadableURL("not a url") == nil)
        #expect(WebConversions.loadableURL("swift.org") == nil, "no scheme")
        #expect(WebConversions.loadableURL("file:///etc/hosts") == nil, "files come from loadResource")
    }

    @Test func resourcesStayInTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("help"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<title>Help</title>".utf8).write(to: root.appendingPathComponent("help/index.html"))
        try Data("secret".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("outside-\(root.lastPathComponent)"))

        #expect(WebConversions.resource("help/index.html", in: root)?.lastPathComponent == "index.html")
        #expect(WebConversions.resource("help/./index.html", in: root) != nil)
        #expect(WebConversions.resource("help/missing.html", in: root) == nil)
        #expect(WebConversions.resource("help", in: root) == nil, "a directory")
        #expect(WebConversions.resource("", in: root) == nil)
        #expect(WebConversions.resource("/etc/hosts", in: root) == nil)
        #expect(WebConversions.resource("../outside-\(root.lastPathComponent)", in: root) == nil)
        #expect(WebConversions.resource("help/../../outside-\(root.lastPathComponent)", in: root) == nil)
    }

    @Test func navigationKinds() {
        #expect(WebConversions.kind(.linkActivated) == .linkActivated)
        #expect(WebConversions.kind(.formSubmitted) == .formSubmitted)
        #expect(WebConversions.kind(.formResubmitted) == .formSubmitted)
        #expect(WebConversions.kind(.backForward) == .backForward)
        #expect(WebConversions.kind(.reload) == .reload)
        #expect(WebConversions.kind(.other) == .other)
    }

    @Test func failures() {
        func code(_ domain: String, _ code: Int) -> WebError.Code? {
            WebConversions.failure(NSError(domain: domain, code: code))
        }
        #expect(code(NSURLErrorDomain, NSURLErrorCancelled) == nil, "replaced by another navigation")
        #expect(code("WebKitErrorDomain", 102) == nil, "refused by a policy")
        #expect(code(NSURLErrorDomain, NSURLErrorNotConnectedToInternet) == .network)
        #expect(code(NSURLErrorDomain, NSURLErrorCannotFindHost) == .network)
        #expect(code(NSURLErrorDomain, NSURLErrorTimedOut) == .timedOut)
        #expect(code(NSURLErrorDomain, NSURLErrorServerCertificateUntrusted) == .security)
        #expect(code(NSURLErrorDomain, NSURLErrorAppTransportSecurityRequiresSecureConnection) == .security)
        #expect(code(NSURLErrorDomain, NSURLErrorUnsupportedURL) == .badURL)
        #expect(code(NSURLErrorDomain, NSURLErrorFileDoesNotExist) == .badURL)
        #expect(code("WebKitErrorDomain", 101) == .badURL)
        #expect(code(NSURLErrorDomain, NSURLErrorBadServerResponse) == .unknown)
        #expect(code("SomeDomain", 1) == .unknown)
    }

    @Test func scriptValuesAsJSON() {
        #expect(WebConversions.json(NSNumber(value: 2)) == "2")
        #expect(WebConversions.json(NSNumber(value: 2.5)) == "2.5")
        #expect(WebConversions.json(NSNumber(value: true)) == "true")
        #expect(WebConversions.json("Example") == "\"Example\"")
        #expect(WebConversions.json("a/b") == "\"a/b\"", "slashes stay")
        #expect(WebConversions.json(NSNull()) == "null")
        #expect(WebConversions.json([1, "a", NSNull()] as [Any]) == "[1,\"a\",null]")
        #expect(WebConversions.json(["b": 1, "a": [true]] as [String: Any]) == "{\"a\":[true],\"b\":1}")
        #expect(WebConversions.json(Date(timeIntervalSince1970: 0)) == "\"1970-01-01T00:00:00.000Z\"")
        #expect(WebConversions.json(NSNumber(value: Double.nan)) == nil)
        #expect(WebConversions.json(nil) == nil)
    }

    @Test func scriptOutcomes() {
        #expect(WebConversions.scriptOutcome(NSNumber(value: 1), nil) == ("1", nil))
        let unsupported = NSError(domain: WKError.errorDomain, code: WKError.javaScriptResultTypeIsUnsupported.rawValue)
        #expect(WebConversions.scriptOutcome(nil, unsupported) == (nil, nil), "undefined")
        let exception = NSError(domain: WKError.errorDomain, code: WKError.javaScriptExceptionOccurred.rawValue,
                                userInfo: ["WKJavaScriptExceptionMessage": "TypeError: x is null"])
        #expect(WebConversions.scriptOutcome(nil, exception) == (nil, "TypeError: x is null"))
        let other = NSError(domain: "SomeDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Broken"])
        #expect(WebConversions.scriptOutcome(nil, other) == (nil, "Broken"))
    }
}
