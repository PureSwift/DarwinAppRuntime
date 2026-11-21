#if canImport(AppKit)
import AppKit
import DynamicFiles
import DynamicText
import Foundation
import RuntimeHost
import RuntimeText
import Testing
@testable import DarwinText

/// What a guest's text heard, in order.
final class TextDelegate: TextStorageDelegate {

    var edits: [(location: Int32, removed: Int32, inserted: Int32, length: Int32)] = []
    var selections: [Range<Int32>] = []
    var modified: [Bool] = []
    var undo: [(canUndo: Bool, canRedo: Bool)] = []

    /// Called from `didEdit`, as a guest's handler would.
    var onEdit: (() -> Void)?

    func didEdit(_ location: Int32, removed: Int32, inserted: Int32, length: Int32) {
        edits.append((location, removed, inserted, length))
        onEdit?()
    }

    func didChangeSelection(_ location: Int32, length: Int32) {
        selections.append(location ..< location + length)
    }

    func didChangeModified(_ modified: Bool) {
        self.modified.append(modified)
    }

    func didChangeUndo(_ canUndo: Bool, canRedo: Bool) {
        undo.append((canUndo, canRedo))
    }
}

/// What one operation's callback heard.
final class TextAnswer: TextCallback {

    var completed = false
    var loaded: (encoding: String, lineEnding: Int32, byteOrderMark: Bool)?
    var failure: (code: Int32, file: Int32)?
    var answered: Bool { completed || loaded != nil || failure != nil }

    func didComplete() { completed = true }
    func didLoad(_ encoding: String, lineEnding: Int32, byteOrderMark: Bool) { loaded = (encoding, lineEnding, byteOrderMark) }
    func didFind(_ location: Int32, length: Int32) { }
    func didReplace(_ count: Int32) { }
    func didFail(_ code: Int32, file: Int32) { failure = (code, file) }
}

/// `HostTextStorage` over this module's text views, an `NSTextView` each,
/// as the guest uses it. They share `HostTextStorage`'s platform, so one
/// test at a time.
@Suite("Text views", .serialized)
@MainActor
struct TextViewTests {

    let directory: URL

    init() throws {
        HostTextStorage.reset()
        HostTextStorage.platform = DarwinTextPlatform()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DarwinTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try HostFiles.configure(HostFiles.Configuration(directories: [.caches: directory.path]))
    }

    func make() -> (HostTextStorage, TextDelegate, TextViewEngine) {
        let delegate = TextDelegate()
        let storage = HostTextStorage.make(delegate)
        return (storage, delegate, storage.engine as! TextViewEngine)
    }

    func answer(_ call: (TextAnswer) -> Void) async throws -> TextAnswer {
        let answer = TextAnswer()
        call(answer)
        let deadline = Date().addingTimeInterval(5)
        while !answer.answered {
            guard Date() < deadline else {
                Issue.record("no answer")
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return answer
    }

    @Test func holdsTheTextInATextView() {
        let (storage, delegate, engine) = make()
        storage.setText("one\r\ntwo\nthree")
        // One edit of everything, with `\n` only, unmodified.
        #expect(delegate.edits.count == 1)
        #expect(delegate.edits.last.map { [$0.location, $0.removed, $0.inserted, $0.length] } == [0, 0, 13, 13])
        #expect(engine.view.string == "one\ntwo\nthree")
        #expect(storage.length() == 13)
        #expect(storage.lineCount() == 3)
        #expect(storage.line(5) == 1)
        #expect(storage.lineStart(2) == 8)
        #expect(storage.lineStart(3) == -1)
        #expect(storage.substring(4, length: 3) == "two")
        #expect(!storage.isModified)
    }

    @Test func editsUndoesAndRedoes() async throws {
        let (storage, delegate, engine) = make()
        storage.setText("Hello world")
        storage.setSelection(11, length: 0)
        storage.replace(6, length: 5, text: "there")
        #expect(engine.view.string == "Hello there")
        #expect(delegate.edits.last.map { [$0.location, $0.removed, $0.inserted] } == [6, 5, 5])
        // A caret after what was replaced moves with the text.
        #expect(engine.selection == 11 ..< 11)
        #expect(delegate.modified == [true])
        // The undo group closes at the end of this turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(delegate.undo.last?.canUndo == true)
        storage.undo()
        #expect(engine.view.string == "Hello world")
        #expect(delegate.undo.last.map { [$0.canUndo, $0.canRedo] } == [false, true])
        storage.redo()
        #expect(engine.view.string == "Hello there")
        // A new text empties the history.
        storage.setText("Fresh")
        #expect(delegate.undo.last.map { [$0.canUndo, $0.canRedo] } == [false, false])
        #expect(!storage.isModified)
    }

    @Test func hearsTheUser() async throws {
        let (storage, delegate, engine) = make()
        storage.setText("ab")
        storage.setSelection(1, length: 0)
        let before = delegate.edits.count
        // Typing, as the keyboard would.
        engine.view.insertText("X", replacementRange: engine.view.selectedRange())
        #expect(engine.view.string == "aXb")
        #expect(delegate.edits.count == before + 1)
        #expect(delegate.edits.last.map { [$0.location, $0.removed, $0.inserted] } == [1, 0, 1])
        #expect(delegate.selections.last == 2 ..< 2)
        #expect(storage.isModified)
        // A paste with Windows line breaks goes in with `\n`.
        engine.view.insertText("1\r\n2\r3", replacementRange: NSRange(location: 3, length: 0))
        #expect(engine.view.string == "aXb1\n2\n3")
    }

    @Test func undoesTheUsersTypingInRuns() {
        let (storage, delegate, engine) = make()
        storage.setText("Hello")
        storage.setSelection(5, length: 0)
        // A run of keystrokes is one step.
        for key in [",", " ", "y", "o", "u"] {
            engine.view.insertText(key, replacementRange: engine.view.selectedRange())
        }
        #expect(engine.view.string == "Hello, you")
        #expect(delegate.undo.last.map { [$0.canUndo, $0.canRedo] } == [true, false])
        // The guest's edit is a step of its own.
        storage.replace(0, length: 5, text: "Hi")
        #expect(engine.view.string == "Hi, you")
        storage.undo()
        #expect(engine.view.string == "Hello, you")
        storage.undo()
        #expect(engine.view.string == "Hello")
        // The caret is put back where it was.
        #expect(engine.selection == 5 ..< 5)
        #expect(delegate.undo.last.map { [$0.canUndo, $0.canRedo] } == [false, true])
        storage.redo()
        #expect(engine.view.string == "Hello, you")
        // Deleting is a step too.
        engine.view.setSelectedRange(NSRange(location: 10, length: 0))
        engine.view.deleteBackward(nil)
        #expect(engine.view.string == "Hello, yo")
        storage.undo()
        #expect(engine.view.string == "Hello, you")
    }

    @Test func letsTheGuestEditFromItsHandler() {
        let (storage, delegate, engine) = make()
        storage.setText("")
        var added = false
        delegate.onEdit = {
            guard !added else { return }
            added = true
            // What a guest's `onEdit` might do: the storage has finished.
            storage.replace(storage.length(), length: 0, text: "!")
        }
        storage.replace(0, length: 0, text: "Hi")
        #expect(engine.view.string == "Hi!")
    }

    @Test func readsAndWritesOtherEncodings() async throws {
        #expect(HostTextStorage.supportsEncoding("Shift_JIS"))
        #expect(HostTextStorage.supportsEncoding("utf-8"))
        #expect(!HostTextStorage.supportsEncoding("x-no-such-encoding"))
        let text = "日本語のテキスト\r\n二行目"
        try text.data(using: .shiftJIS)!.write(to: directory.appendingPathComponent("japanese.txt"))
        let (storage, _, engine) = make()
        let loaded = try await answer { storage.load(FileDirectory.caches.rawValue, path: "japanese.txt", encoding: "shift_jis", callback: $0) }
        #expect(loaded.loaded?.encoding == "shift_jis")
        #expect(loaded.loaded?.lineEnding == LineEnding.crlf.rawValue)
        #expect(engine.view.string == "日本語のテキスト\n二行目")
        storage.replace(0, length: 3, text: "日本")
        let saved = try await answer {
            storage.save(FileDirectory.caches.rawValue, path: "saved.txt", encoding: "shift_jis",
                         lineEnding: LineEnding.crlf.rawValue, byteOrderMark: false, callback: $0)
        }
        #expect(saved.completed)
        let written = try Data(contentsOf: directory.appendingPathComponent("saved.txt"))
        #expect(String(data: written, encoding: .shiftJIS) == "日本のテキスト\r\n二行目")
        // A character Shift JIS doesn't have isn't written.
        storage.setText("emoji 😀")
        let refused = try await answer {
            storage.save(FileDirectory.caches.rawValue, path: "emoji.txt", encoding: "shift_jis",
                         lineEnding: 0, byteOrderMark: false, callback: $0)
        }
        #expect(refused.failure?.code == TextError.Code.unencodable.rawValue)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("emoji.txt").path))
    }

    @Test func findsAndRevealsInTheView() async throws {
        let (storage, _, engine) = make()
        storage.setText("colour and colour")
        storage.reveal(11, length: 6)
        storage.setSelection(0, length: 0)
        let replaced = TextAnswer()
        storage.replaceAll("colour", with: "color", options: 0, callback: replaced)
        #expect(engine.view.string == "color and color")
        // One step.
        try await Task.sleep(nanoseconds: 50_000_000)
        storage.undo()
        #expect(engine.view.string == "colour and colour")
    }
}
#endif
