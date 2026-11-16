import DynamicFiles
import Foundation
import RuntimeHost
import Testing
@testable import DarwinFiles

/// Records one operation's answer, and where it came.
final class RecordingCallback: FileCallback {

    var answer: String?

    var onMainThread = false

    private func record(_ answer: String) {
        self.answer = answer
        onMainThread = Thread.isMainThread
    }

    func didComplete() {
        record("complete")
    }

    func didRead(_ data: [UInt8]) {
        record("read \(String(decoding: data, as: UTF8.self))")
    }

    func didList(_ names: [String]) {
        record("list \(names)")
    }

    func didGetAttributes(kind: Int32, size: Int64, modified: Int64) {
        record("attributes \(kind) \(size)")
    }

    func didFail(_ error: Int32) {
        record("fail \(error)")
    }
}

/// The module over real directories: `HostFiles` is AppRuntime's, tested
/// there; this checks what the Darwin host gives it.
@MainActor
@Suite("Files", .serialized)
struct DarwinFilesTests {

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        let root = root.path
        try FileManager.default.createDirectory(atPath: root + "/bundle/levels", withIntermediateDirectories: true)
        try Data("level one".utf8).write(to: URL(fileURLWithPath: root + "/bundle/levels/1.map"))
        try FileManager.default.createDirectory(atPath: root + "/tmp", withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: root + "/tmp/last-run"))
        DarwinFiles.directories = {
            [
                .documents: root + "/Documents",
                .data: root + "/Data",
                .caches: root + "/Caches",
                .temporary: root + "/tmp",
                .bundle: root + "/bundle",
            ]
        }
        DarwinFiles.configure()
    }

    func path(_ relative: String) -> String {
        root.path + "/" + relative
    }

    /// Runs one operation and waits for its answer.
    func answer(_ operation: (HostFiles, RecordingCallback) -> Void) async throws -> RecordingCallback {
        let callback = RecordingCallback()
        operation(HostFiles.shared(), callback)
        for _ in 0..<500 where callback.answer == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return callback
    }

    @Test func moduleListsItsContracts() {
        #expect(DarwinFiles.contracts.map(\.name) == ["org.pureswift.files.Files", "org.pureswift.files.FileCallback"])
    }

    @Test func configuringMakesTheDirectoriesAndEmptiesTemporary() throws {
        var isDirectory: ObjCBool = false
        for name in ["Documents", "Data", "Caches", "tmp"] {
            #expect(FileManager.default.fileExists(atPath: path(name), isDirectory: &isDirectory) && isDirectory.boolValue, "\(name)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: path("tmp")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: path("bundle/levels/1.map")), "the bundle is left alone")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func answersComeOnTheMainThread() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let write = try await answer { files, callback in
            files.write(FileDirectory.documents.rawValue, path: "saves/slot1.sav", data: Array("saved".utf8), mode: 0, callback: callback)
        }
        #expect(write.answer == "complete")
        #expect(write.onMainThread)
        #expect(FileManager.default.contents(atPath: path("Documents/saves/slot1.sav")) == Data("saved".utf8))

        let read = try await answer { files, callback in
            files.read(FileDirectory.bundle.rawValue, path: "levels/1.map", offset: 0, length: -1, callback: callback)
        }
        #expect(read.answer == "read level one")
        #expect(read.onMainThread)
    }

    @Test func theBundleIsReadOnly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let write = try await answer { files, callback in
            files.write(FileDirectory.bundle.rawValue, path: "levels/2.map", data: [1], mode: 0, callback: callback)
        }
        #expect(write.answer == "fail \(FileError.readOnly.rawValue)")
        #expect(!FileManager.default.fileExists(atPath: path("bundle/levels/2.map")))

        let copy = try await answer { files, callback in
            files.copy(FileDirectory.bundle.rawValue, path: "levels/1.map", toDirectory: FileDirectory.caches.rawValue, toPath: "1.map", callback: callback)
        }
        #expect(copy.answer == "complete", "copies out of it work")
        #expect(FileManager.default.contents(atPath: path("Caches/1.map")) == Data("level one".utf8))
    }
}
