import Foundation
import Testing
@testable import DarwinPackager

@Suite struct BundleTests {

    let temporary = try! TemporaryDirectory()

    @Test func readsThePortableKeys() throws {
        let bundle = try FixtureBundle().read(in: temporary.url)
        #expect(bundle.identifier == "org.pureswift.example")
        #expect(bundle.executable == "ExampleApp")
        #expect(bundle.languages == ["en", "es"])
        #expect(bundle.developmentRegion == "en")
        #expect(bundle.abiVersion == 1)
        #expect(bundle.capabilities == ["bluetooth"])
        #expect(bundle.contracts.count == 2)
        #expect(bundle.contracts[1] == .init(name: "org.pureswift.bluetooth.CentralDelegate", version: 1, kind: "callback"))
        #expect(bundle.platforms?["ios"]?.minimum == "15.0")
        #expect(bundle.platforms?["android"]?.minimum == nil)
        #expect(bundle.displayNameKey == "app.name")
        #expect(bundle.apple.category == "public.app-category.developer-tools")
        #expect(bundle.slice(for: .macos) != nil)
        #expect(bundle.wasm != nil)
        #expect(try bundle.manifestStrings("es")?["app.name"] == "Ejemplo")
        #expect(try bundle.manifestStrings("fr") == nil)
    }

    @Test func requiresTheABIVersion() throws {
        #expect(throws: PackagerError.self) {
            try FixtureBundle().with(["RTABIVersion": nil]).read(in: temporary.url)
        }
    }

    @Test func verifiesAnUntouchedBundle() throws {
        let bundle = try FixtureBundle().read(in: temporary.url)
        #expect(try bundle.verify() == [])
    }

    @Test func findsAChangedFile() throws {
        let bundle = try FixtureBundle().read(in: temporary.url)
        try Data("changed".utf8).write(to: bundle.url.appendingPathComponent("lib/macos/libapp.a"))
        let diagnostics = try bundle.verify()
        #expect(diagnostics.count == 1)
        #expect(diagnostics.hasErrors)
        #expect(diagnostics[0].message.contains("lib/macos/libapp.a doesn't match"))
    }

    @Test func findsAddedAndMissingFiles() throws {
        let bundle = try FixtureBundle().read(in: temporary.url)
        try Data("extra".utf8).write(to: bundle.url.appendingPathComponent("extra.txt"))
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("wasm32/App.wasm"))
        let messages = try bundle.verify().map(\.message)
        #expect(messages.contains { $0.contains("wasm32/App.wasm is listed") })
        #expect(messages.contains { $0.contains("extra.txt isn't listed") })
    }

    @Test func requiresCodeResources() throws {
        let bundle = try FixtureBundle().read(in: temporary.url)
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("_CodeSignature"))
        #expect(try bundle.verify().hasErrors)
    }

    @Test func parsesStringsFiles() throws {
        let strings = try StringsFile.parse(Data("""
            /* A comment. */
            "a" = "One \\"quoted\\" word";
            "b" = "Line\\nbreak";
            """.utf8))
        #expect(strings == ["a": "One \"quoted\" word", "b": "Line\nbreak"])
        let text = StringsFile.text(strings)
        #expect(text == "\"a\" = \"One \\\"quoted\\\" word\";\n\"b\" = \"Line\\nbreak\";\n")
        #expect(try StringsFile.parse(Data(text.utf8)) == strings)
    }

    @Test func comparesVersions() {
        #expect(OSVersion("15.0")! == OSVersion("15")!)
        #expect(OSVersion("15.0")! < OSVersion("15.0.1")!)
        #expect(OSVersion("9.3")! < OSVersion("10.0")!)
        #expect(OSVersion("abc") == nil)
        #expect(OSVersion("1.2.3.4") == nil)
    }

    /// The real bundle from `guest.py bundle`, when it's been built.
    static let exampleBundle = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-coleman-Developer-AppRuntime/e83a241e-b790-4b61-8444-2bb3d453495c/scratchpad/bundle/org.pureswift.example.app")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: exampleBundle.path)))
    func verifiesExampleApp() throws {
        let bundle = try UniversalBundle(url: Self.exampleBundle)
        #expect(bundle.identifier == "org.pureswift.example")
        #expect(try bundle.verify() == [])
        // ExampleApp uses AppRuntime's example contracts, which only its
        // test host implements.
        let diagnostics = Compatibility(platform: .macos).check(bundle)
        #expect(diagnostics.map(\.message).allSatisfy { $0.contains("org.pureswift.example.") })
        #expect(!Compatibility(platform: .macos, allowsMissingContracts: true).check(bundle).hasErrors)
    }
}
