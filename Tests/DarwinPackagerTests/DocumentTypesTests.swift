import Foundation
import Testing
@testable import DarwinPackager

/// The app's document types and the `userFiles` capability, as Apple's
/// keys and entitlements.
@Suite struct DocumentTypesTests {

    let temporary = try! TemporaryDirectory()

    static var documentTypes: [[String: Any]] { [
        ["Name": "Image", "NameKey": "type.image", "Types": ["image/*"], "Role": "viewer"],
        ["Name": "Text", "Types": ["text/plain", ".md", ".gpx", "application/x-example-notes"], "Role": "editor"],
    ] }

    func fixture() -> FixtureBundle {
        var fixture = FixtureBundle().with([
            "RTCapabilities": ["bluetooth", "userFiles"],
            "RTDocumentTypes": Self.documentTypes,
        ])
        fixture.files["resources/en.lproj/Manifest.strings"] = Data("""
            "app.name" = "Example";
            "perm.bluetooth" = "Looks for beacons.";
            "type.image" = "Image";
            """.utf8)
        fixture.files["resources/es.lproj/Manifest.strings"] = Data("""
            "app.name" = "Ejemplo";
            "perm.bluetooth" = "Busca balizas.";
            "type.image" = "Imagen";
            """.utf8)
        return fixture
    }

    func translator(_ fixture: FixtureBundle, _ platform: ApplePlatform) throws -> InfoPlistTranslator {
        let bundle = try fixture.read(in: temporary.url)
        return InfoPlistTranslator(bundle: bundle, platform: platform, deploymentTarget: platform.hostMinimum)
    }

    @Test func theBundleReadsItsDocumentTypes() throws {
        let bundle = try fixture().read(in: temporary.url)
        #expect(bundle.documentTypes == [
            DocumentTypeEntry(name: "Image", nameKey: "type.image", types: ["image/*"], role: "viewer"),
            DocumentTypeEntry(name: "Text", types: ["text/plain", ".md", ".gpx", "application/x-example-notes"], role: "editor"),
        ])
    }

    @Test func documentTypesBecomeBundleDocumentTypes() throws {
        let info = try translator(fixture(), .ios).infoPlist(sdk: nil)
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.count == 2)
        #expect(types[0]["CFBundleTypeName"] as? String == "Image")
        #expect(types[0]["CFBundleTypeRole"] as? String == "Viewer")
        #expect(types[0]["LSHandlerRank"] as? String == "Alternate")
        #expect(types[0]["LSItemContentTypes"] as? [String] == ["public.image"])
        #expect(types[1]["CFBundleTypeRole"] as? String == "Editor")
        let text = try #require(types[1]["LSItemContentTypes"] as? [String])
        #expect(text.first == "public.plain-text")
        #expect(text.contains("org.pureswift.example.type.application-x-example-notes"))
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true, "opened where it is, on iOS")
    }

    @Test func aTypeTheSystemDoesntKnowIsImported() throws {
        let info = try translator(fixture(), .macos).infoPlist(sdk: nil)
        #expect(info["LSSupportsOpeningDocumentsInPlace"] == nil, "iOS only")
        let imported = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let notes = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "org.pureswift.example.type.application-x-example-notes" })
        #expect(notes["UTTypeDescription"] as? String == "Text")
        #expect(notes["UTTypeConformsTo"] as? [String] == ["public.data"])
        #expect(notes["UTTypeTagSpecification"] as? [String: [String]] == ["public.mime-type": ["application/x-example-notes"]])
        #expect(!imported.contains { $0["UTTypeIdentifier"] as? String == "public.plain-text" }, "a known type isn't declared")
    }

    @Test func wireTypesBecomeTypeIdentifiers() {
        func identifier(_ wire: String) -> String {
            DocumentTypes.contentType(wire, bundleIdentifier: "org.example", name: "X").identifier
        }
        #expect(identifier("image/png") == "public.png")
        #expect(identifier("IMAGE/PNG") == "public.png")
        #expect(identifier("audio/*") == "public.audio")
        #expect(identifier("video/*") == "public.movie")
        #expect(identifier("chemical/*") == "public.data", "a group the system doesn't have: any data")
        #expect(identifier(".pdf") == "com.adobe.pdf")
        #expect(identifier(".x-notes") == "org.example.type.x-notes")
        #expect(DocumentTypes.contentType(".x-notes", bundleIdentifier: "org.example", name: "X").declaration?["UTTypeTagSpecification"] as? [String: [String]]
            == ["public.filename-extension": ["x-notes"]])
        #expect(DocumentTypes.sanitized("application/vnd.example+json") == "application-vnd.example-json")
    }

    @Test func documentTypeNamesAreLocalized() throws {
        let strings = try translator(fixture(), .ios).infoPlistStrings()
        #expect(strings["es"]?["Image"] == "Imagen", "keyed by the development language's name")
        #expect(strings["en"]?["Image"] == "Image")
        #expect(strings["es"]?["Text"] == nil, "not localized")
    }

    @Test func aMissingNameIsAnError() throws {
        var fixture = fixture()
        fixture.files["resources/es.lproj/Manifest.strings"] = Data("""
            "app.name" = "Ejemplo";
            "perm.bluetooth" = "Busca balizas.";
            """.utf8)
        let translator = try translator(fixture, .ios)
        #expect {
            try translator.infoPlistStrings()
        } throws: {
            ($0 as? PackagerError)?.message == "resources/es.lproj/Manifest.strings has no 'type.image', the name of the document type 'Image'"
        }
    }

    @Test func noDocumentTypesNoKeys() throws {
        let info = try translator(FixtureBundle(), .ios).infoPlist(sdk: nil)
        #expect(info["CFBundleDocumentTypes"] == nil)
        #expect(info["LSSupportsOpeningDocumentsInPlace"] == nil)
        #expect(info["UTImportedTypeDeclarations"] == nil)
    }

    @Test func userFilesEntitlesTheSandbox() throws {
        let bundle = try fixture().read(in: temporary.url)
        let macos = Entitlements.forCapabilities(bundle, platform: .macos, configuration: .release)
        #expect(macos["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(macos["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
        #expect(Entitlements.forCapabilities(bundle, platform: .ios, configuration: .release).isEmpty, "nothing on iOS")
        #expect(Capabilities.rules["userFiles"]?.needsUsage == false, "it prompts for nothing")
    }
}
