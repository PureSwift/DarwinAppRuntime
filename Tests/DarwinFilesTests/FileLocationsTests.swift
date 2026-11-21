import DynamicFiles
import Foundation
import Testing
@testable import DarwinFiles

/// Where the directories are, in a sandbox and out of one.
@Suite("File locations")
struct FileLocationsTests {

    @Test func aSandboxUsesTheContainer() {
        let locations = FileLocations(
            home: "/Containers/App/Data",
            temporary: "/Containers/App/Data/tmp/",
            resources: "/Apps/Example.app",
            sandboxed: true,
            identifier: "com.example.notes"
        )
        #expect(locations.directories == [
            .documents: "/Containers/App/Data/Documents",
            .data: "/Containers/App/Data/Library/Application Support",
            .caches: "/Containers/App/Data/Library/Caches",
            .temporary: "/Containers/App/Data/tmp",
            .bundle: "/Apps/Example.app",
        ])
        #expect(locations.stores == "/Containers/App/Data/Library/Stores", "in no file directory")
        #expect(locations.host == "/Containers/App/Data/Library/Host", "in no file directory")
    }

    @Test func withoutASandboxEachIsTheAppsOwn() {
        let locations = FileLocations(
            home: "/Users/someone/",
            temporary: "/var/folders/xy/T/",
            resources: "/Apps/Example.app/Contents/Resources/",
            sandboxed: false,
            identifier: "com.example.notes"
        )
        #expect(locations.directories == [
            .documents: "/Users/someone/Library/Application Support/com.example.notes/Documents",
            .data: "/Users/someone/Library/Application Support/com.example.notes/Data",
            .caches: "/Users/someone/Library/Caches/com.example.notes",
            .temporary: "/var/folders/xy/T/com.example.notes",
            .bundle: "/Apps/Example.app/Contents/Resources",
        ], "not the user's Documents, and not the shared temporary directory, which is emptied")
        #expect(locations.stores == "/Users/someone/Library/Application Support/com.example.notes/Stores")
        #expect(locations.host == "/Users/someone/Library/Application Support/com.example.notes/Host")
    }

    @Test func noResourcesNoBundle() {
        let locations = FileLocations(home: "/h", temporary: "/t", resources: nil, sandboxed: true, identifier: "a")
        #expect(locations.directories[.bundle] == nil)
        #expect(locations.directories.count == 4)
    }

    @Test func thisProcess() throws {
        let directories = FileLocations.current(bundle: .main).directories
        let documents = try #require(directories[.documents])
        let temporary = try #require(directories[.temporary])
        #expect(documents.hasPrefix("/") && !documents.hasSuffix("/"))
        #if os(macOS)
        // The test runner has no sandbox.
        #expect(documents != NSHomeDirectory() + "/Documents")
        #expect(temporary.hasPrefix(NSTemporaryDirectory()) && temporary.count > NSTemporaryDirectory().count)
        #endif
    }
}
