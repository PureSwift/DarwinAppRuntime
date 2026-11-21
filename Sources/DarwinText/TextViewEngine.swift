import DynamicText
import Foundation
import RuntimeText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One text: a platform text view, `UITextView` or `NSTextView`, whose
/// storage is the text. It lives as long as the guest's `TextStorage`, on
/// screen or not; a `TextEditor` node shows `view` while it names it.
///
/// - Every change to the storage is heard from its delegate, whoever made
///   it, and reported once the storage has finished processing it, so the
///   guest can edit again from its handler.
/// - The engine keeps the undo history itself, in `history`: the user's
///   typing and the guest's edits, each with the text it removed. The text
///   views' own undo isn't used, since UIKit's doesn't stay on a history
///   it's given. Typing in a run is one step.
/// - Pasted and typed `\r\n` and `\r` become `\n` before they go in.
///
/// Main thread only.
final class TextViewEngine: NSObject, TextEngine {

    private(set) weak var storage: HostTextStorage?

    let view: EditorTextView

    /// The text's undo history. Each step is a group of its own.
    let history = UndoManager()

    /// Edits the storage has processed and the guest hasn't heard of.
    private var pending: [(location: Int, removed: Int, inserted: Int)] = []

    /// A change about to be made, from the view's or the engine's own
    /// call: exactly what it replaces, which the storage's report, widened
    /// by the attributes it fixes, doesn't say.
    private struct Expected {
        var location: Int
        var removed: String
        var inserted: String
        var byUser: Bool
        var selectionBefore: Range<Int>
    }

    private var expected: Expected?

    /// While the guest's own edit is applied: the view's callbacks about it
    /// aren't the user's.
    private var isGuestEditing = false

    /// While an undo or a redo, or a new text, is applied: not recorded.
    private var isApplyingHistory = false

    /// The user's latest step, while typing can still extend it.
    private var typing: TextChange?

    /// Reports focus while a node shows the view.
    var onFocus: ((Bool) -> Void)?

    #if canImport(AppKit)
    /// The text view's scroll view, which is what's shown.
    let scrollView: NSScrollView
    #else
    /// What the text view registers its own undo with, which is nothing.
    let ignored: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()
    #endif

    init(storage: HostTextStorage) {
        self.storage = storage
        #if canImport(UIKit)
        view = EditorTextView(frame: .zero)
        #else
        scrollView = EditorTextView.scrollableTextView()
        view = scrollView.documentView as! EditorTextView
        #endif
        super.init()
        history.groupsByEvent = false
        view.engine = self
        configure()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(self, selector: #selector(undoChanged), name: name, object: history)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configure() {
        #if canImport(UIKit)
        view.textStorage.delegate = self
        view.delegate = self
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        #else
        view.textStorage?.delegate = self
        view.delegate = self
        view.isRichText = false
        view.importsGraphics = false
        // The engine keeps the history; the menu's Undo reaches it through
        // the delegate.
        view.allowsUndo = false
        view.usesFindBar = false
        view.drawsBackground = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        view.font = .preferredFont(forTextStyle: .body)
        #endif
    }

    // MARK: Reading

    private var string: NSString {
        #if canImport(UIKit)
        view.textStorage.string as NSString
        #else
        (view.textStorage?.string ?? "") as NSString
        #endif
    }

    var length: Int {
        string.length
    }

    func text(in range: Range<Int>) -> String {
        string.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    var lineCount: Int {
        TextLines.count(in: string)
    }

    func line(at location: Int) -> Int {
        TextLines.line(at: location, in: string)
    }

    func lineStart(_ line: Int) -> Int? {
        TextLines.start(of: line, in: string)
    }

    // MARK: Changing

    /// The text's attributes: the view's font and color.
    private var attributes: [NSAttributedString.Key: Any] {
        view.typingAttributes
    }

    func setText(_ text: String) {
        let new = NSAttributedString(string: text, attributes: attributes)
        isApplyingHistory = true
        #if canImport(UIKit)
        view.textStorage.setAttributedString(new)
        #else
        view.textStorage?.setAttributedString(new)
        #endif
        isApplyingHistory = false
        forgetHistory()
        flush()
    }

    func replace(_ range: Range<Int>, with text: String) {
        expected = Expected(location: range.lowerBound, removed: self.text(in: range), inserted: text,
                            byUser: false, selectionBefore: selection)
        isGuestEditing = true
        apply(range, text)
        isGuestEditing = false
        flush()
    }

    /// Puts `text` in place of `range`, as the platform's own edit, so the
    /// keyboard keeps up.
    private func apply(_ range: Range<Int>, _ text: String) {
        #if canImport(UIKit)
        if let start = view.position(from: view.beginningOfDocument, offset: range.lowerBound),
           let end = view.position(from: start, offset: range.count),
           let textRange = view.textRange(from: start, to: end) {
            view.replace(textRange, withText: text)
        }
        #else
        let nsRange = NSRange(location: range.lowerBound, length: range.count)
        if view.shouldChangeText(in: nsRange, replacementString: text) {
            view.textStorage?.replaceCharacters(in: nsRange, with: NSAttributedString(string: text, attributes: attributes))
            view.didChangeText()
        }
        #endif
    }

    var selection: Range<Int> {
        get {
            #if canImport(UIKit)
            let range = view.selectedRange
            #else
            let range = view.selectedRange()
            #endif
            return range.location ..< range.location + range.length
        }
        set {
            let range = NSRange(location: newValue.lowerBound, length: newValue.count)
            #if canImport(UIKit)
            view.selectedRange = range
            #else
            view.setSelectedRange(range)
            #endif
        }
    }

    func undo() {
        if history.canUndo {
            history.undo()
        }
        finishHistory()
    }

    func redo() {
        if history.canRedo {
            history.redo()
        }
        finishHistory()
    }

    func reveal(_ range: Range<Int>) {
        view.scrollRangeToVisible(NSRange(location: range.lowerBound, length: range.count))
    }

    // MARK: History

    /// A step on the history: undoing it puts back what it removed.
    private func record(_ change: TextChange) {
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { engine in
            engine.revert(change)
        }
        history.endUndoGrouping()
    }

    /// Undoes a step, and puts its opposite on the other side of the
    /// history, as `UndoManager` does with what's registered while it undoes.
    private func revert(_ change: TextChange) {
        typing = nil
        let after = selection
        isApplyingHistory = true
        apply(change.location ..< change.location + change.inserted.utf16.count, change.removed)
        isApplyingHistory = false
        selection = change.selectionBefore
        let opposite = TextChange(location: change.location, removed: change.inserted, inserted: change.removed, selectionBefore: after)
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { engine in
            engine.revert(opposite)
        }
        history.endUndoGrouping()
    }

    private func finishHistory() {
        flush()
        storage?.selectionChanged()
        undoChanged()
    }

    private func forgetHistory() {
        history.removeAllActions()
        typing = nil
        undoChanged()
    }

    /// A change the storage processed, from the user or the guest.
    private func remember(_ expected: Expected) {
        // Typing on from where the last keystroke left off is the same step.
        if expected.byUser, expected.removed.isEmpty, let typing, typing.removed.isEmpty || typing.extendsTyping,
           expected.location == typing.location + typing.inserted.utf16.count, !expected.inserted.contains("\n") {
            typing.inserted += expected.inserted
            typing.extendsTyping = true
            return
        }
        let change = TextChange(location: expected.location, removed: expected.removed, inserted: expected.inserted,
                                selectionBefore: expected.selectionBefore)
        typing = expected.byUser && !expected.inserted.contains("\n") ? change : nil
        record(change)
    }

    // MARK: Reporting

    /// Tells the guest of what the storage has processed.
    func flush() {
        let edits = pending
        pending = []
        for edit in edits {
            storage?.edited(at: edit.location, removed: edit.removed, inserted: edit.inserted)
        }
    }

    fileprivate func processed(_ range: NSRange, changeInLength delta: Int) {
        let exact = expected.flatMap { $0.inserted.utf16.count - $0.removed.utf16.count == delta ? $0 : nil }
        expected = nil
        if let exact {
            pending.append((exact.location, exact.removed.utf16.count, exact.inserted.utf16.count))
        } else {
            pending.append((range.location, range.length - delta, range.length))
        }
        if !isApplyingHistory {
            if let exact {
                remember(exact)
            } else {
                // Something changed the text in a way this can't undo
                // exactly: the history before it no longer applies.
                forgetHistory()
            }
        }
        // A change from somewhere that doesn't say when it's done is told on
        // the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.flush()
        }
    }

    @objc private func undoChanged() {
        storage?.undoChanged(canUndo: history.canUndo, canRedo: history.canRedo)
    }

    fileprivate func selectionMoved() {
        flush()
        storage?.selectionChanged()
    }

    fileprivate func focusChanged(_ focused: Bool) {
        onFocus?(focused)
    }

    /// The view is about to change `range` to `text`: the user's edit,
    /// unless the guest's or the history's is being applied.
    fileprivate func willChange(_ range: NSRange, to text: String) {
        guard !isGuestEditing, !isApplyingHistory else { return }
        let range = range.location ..< range.location + range.length
        expected = Expected(location: range.lowerBound, removed: self.text(in: range), inserted: text,
                            byUser: true, selectionBefore: selection)
    }

    /// What the user puts in, with its line breaks as the text holds them,
    /// or `nil` when it needs no change.
    fileprivate static func normalized(_ text: String) -> String? {
        guard text.utf8.contains(0x0D) else { return nil }
        return TextCoding.normalizingLineBreaks(text).text
    }

    /// Puts in what the user typed or pasted, with `\n` for its line breaks,
    /// as the user's own edit.
    fileprivate func insertNormalized(_ text: String, in range: NSRange) {
        #if canImport(UIKit)
        if let start = view.position(from: view.beginningOfDocument, offset: range.location),
           let end = view.position(from: start, offset: range.length),
           let textRange = view.textRange(from: start, to: end) {
            view.replace(textRange, withText: text)
        }
        #else
        view.insertText(text, replacementRange: range)
        #endif
    }
}

/// One step of a text's history: `removed` at `location` became
/// `inserted`. A class, so typing can extend the latest step.
final class TextChange {

    let location: Int

    let removed: String

    var inserted: String

    /// The selection to put back when it's undone.
    let selectionBefore: Range<Int>

    /// Whether it's grown by typing.
    var extendsTyping = false

    init(location: Int, removed: String, inserted: String, selectionBefore: Range<Int>) {
        self.location = location
        self.removed = removed
        self.inserted = inserted
        self.selectionBefore = selectionBefore
    }
}

// MARK: The storage

#if canImport(UIKit)
typealias TextEditActions = NSTextStorage.EditActions
#else
typealias TextEditActions = NSTextStorageEditActions
#endif

extension TextViewEngine: NSTextStorageDelegate {

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: TextEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        processed(editedRange, changeInLength: delta)
    }
}

// MARK: The view

#if canImport(UIKit)

/// A text view that registers no undo of its own, and says when it gains
/// and loses the keyboard.
final class EditorTextView: UITextView {

    weak var engine: TextViewEngine?

    override var undoManager: UndoManager? {
        engine?.ignored
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            engine?.focusChanged(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            engine?.focusChanged(false)
        }
        return resigned
    }
}

extension TextViewEngine: UITextViewDelegate {

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let normalized = Self.normalized(text) else {
            willChange(range, to: text)
            return true
        }
        insertNormalized(normalized, in: range)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        flush()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionMoved()
    }
}

#else

/// A text view that says when it gains and loses the keyboard.
final class EditorTextView: NSTextView {

    weak var engine: TextViewEngine?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            engine?.focusChanged(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            engine?.focusChanged(false)
        }
        return resigned
    }
}

extension TextViewEngine: NSTextViewDelegate {

    /// The engine's history, for the menu's Undo and Redo.
    func undoManager(for view: NSTextView) -> UndoManager? {
        history
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text else { return true }
        guard let normalized = Self.normalized(text) else {
            willChange(range, to: text)
            return true
        }
        insertNormalized(normalized, in: range)
        return false
    }

    func textDidChange(_ notification: Notification) {
        flush()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionMoved()
    }
}

#endif

/// Lines in a text that holds `\n` only, counted from 0.
enum TextLines {

    static func count(in string: NSString) -> Int {
        var count = 1
        for index in 0 ..< string.length where string.character(at: index) == 0x0A {
            count += 1
        }
        return count
    }

    static func line(at location: Int, in string: NSString) -> Int {
        var line = 0
        for index in 0 ..< min(max(location, 0), string.length) where string.character(at: index) == 0x0A {
            line += 1
        }
        return line
    }

    static func start(of line: Int, in string: NSString) -> Int? {
        guard line >= 0 else { return nil }
        if line == 0 { return 0 }
        var seen = 0
        for index in 0 ..< string.length where string.character(at: index) == 0x0A {
            seen += 1
            if seen == line { return index + 1 }
        }
        return nil
    }
}
